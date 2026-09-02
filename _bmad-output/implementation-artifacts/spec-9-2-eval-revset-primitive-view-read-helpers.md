---
title: 'Story 9.2: `eval_revset` generic read primitive + `View` read helpers'
type: 'feature'
created: '2026-09-02'
status: 'done'
baseline_revision: 'e5c0120c01023e0238adce29eadf3d75b1a9e82c'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      `eval_revset` and the three `View` listings stop at the `zanshin-jj` API; no FFI
      (`.fbs` → `extern "C"` → Dart) or MCP surfacing was added.
    evidence: |-
      Derived, not assumed — the four signals in the spec's Design Notes: epics.md:477 binds the
      surfacing chain to "each verb" and 9.2 delivers none; ADR-0003 §5 states both halves as
      `zanshin-jj` API shape; Story 9.1 set the in-epic precedent; and decisively, `Stream<Commit>`
      has no wire representation — the FFI boundary is snapshot-only (`zanshin_graph_slice` returns
      a materialized `Vec<Row>`), so a faithful surfacing would have to `try_collect`, contradicting
      this story's core constraint. The GUI is not blocked meanwhile: `zanshin_graph_slice` already
      accepts a caller-supplied revset. The still-open ADR-0003 question — whether MCP gets the raw
      revset joker or only named views — is part of what is deferred here.
      Whoever surfaces these will also need error codes: `eval_revset` reuses the already-reserved
      `jj.revset_parse_error` / `jj.revset_resolution_error`, but the three `View` listings return
      the NEW `ViewError` and have no `<domain>.<reason>` code or envelope mapping yet.
    location: >-
      crates/zanshin-ffi/ (no file touched), schemas/envelope.fbs (unchanged), crates/zanshin-mcp/
    severity: low
  - summary: >-
      `builtin_log()` is absent from Zanshin's builtin config layer, so a user who pastes it into
      `eval_revset` — where it works in their CLI — gets a `RevsetError::ParseError`.
    evidence: |-
      Already recorded against Story 9.0a (`spec-9-0a-…md`, severity medium): `config.rs`'s
      `BUILTIN_CONFIG_TOML` is documented as verbatim from `cli/src/config/revsets.toml` at
      v0.42.0, while v0.44.0 sets `log = "builtin_log()"` and adds the alias. Cross-referenced
      here because 9.2 raises the stakes: `eval_revset` is the primitive whose whole purpose is
      passing an arbitrary user-typed revset through (FR-JJ-17), so it is exactly where a user
      pastes an alias that their own CLI honours. The denoted default set is still identical, so
      nothing renders wrongly today.
    location: >-
      crates/zanshin-jj/src/config.rs:74-105 (BUILTIN_CONFIG_TOML)
    severity: medium
  - summary: >-
      Neither `list_tags` nor `list_bookmarks` excludes jj's `git` pseudo-remote, so in a
      git-backed repo they may list every local ref a second time under `remote_name = "git"`.
    evidence: |-
      `list_tags` mirrors `list_bookmarks`' filter exactly (`is_present() && is_tracked()`), which
      is deliberate — but neither skips `REMOTE_NAME_FOR_LOCAL_GIT_REPO`, while jj's own revset
      parse context does (`revset.rs` sets `default_ignored_remote: Some("git")`). Whether such
      rows actually appear depends on the tracking state jj gives `git`-remote refs, which the
      committed fixtures cannot show: they carry no remote refs at all, and the in-test helpers
      only construct named remotes. Settling it needs a colocated-repo fixture and a read of the
      CLI's own handling; the root cause predates 9.2 (it is `list_bookmarks`' filter, shipped in
      2.8), so fixing it belongs with a bookmark/tag story, not here.
    location: >-
      crates/zanshin-jj/src/view.rs (list_tags remote loop), crates/zanshin-jj/src/bookmarks.rs:97
    severity: medium
  - summary: >-
      Parent-commit reads inside `eval_revset`'s streaming loop are synchronous
      (`store.get_commit`), so they are not pipelined the way the commit stream itself is.
    evidence: |-
      `change_from_commit` reads each parent with the blocking `store.get_commit` — inherited
      verbatim from `get_change`, where it was the only shape available — while the commit stream
      around it uses `RevsetStreamExt::commits`' `.buffered(store.concurrency())` and `walk_graph`
      uses `store.get_commit_async`. Correct, just not pipelined: a walk pays one serialized parent
      read per row. Making it async ripples into `get_change`, and perf gates are deferred to the
      release phase per project-context, so this is a recorded observation rather than a defect.
    location: >-
      crates/zanshin-jj/src/change.rs (change_from_commit parent loop)
    severity: low
---

<intent-contract>

## Intent

**Problem:** `zanshin-jj`'s only public revset read, `resolve_revset` (`revset.rs:72`), `try_collect`s the whole set into `Vec<ChangeId>` — the exact anti-pattern ADR-0003 §5 forbids for the read joker, and it yields bare ids rather than commits. Meanwhile `View` data other than bookmarks (tags, heads, per-workspace working-copy commits) has no public reader at all: `commit_meta.rs:132-148` reads all four off the view but only as per-row `jj log` decoration, so a caller wanting "the tags" must route through a revset.

**Approach:** Add `Repo::eval_revset(revset, visit)` — a lazy, cancellable walk over the existing parse→resolve→evaluate path that hands the caller one `Change` per commit through a visitor and never collects, mirroring `Repo::walk_graph`'s proven shape (`graph.rs:159-219`); and a new `crates/zanshin-jj/src/view.rs` with three direct `View` listings (`list_tags`, `list_heads`, `list_working_copies`) modelled on `bookmarks.rs`. Both are `zanshin-jj`-only; nothing crosses FFI in this story.

## Boundaries & Constraints

**Always:**
- CLI **observable behavior** at tag `v0.44.0` is the oracle (NFR-R-2). Read prior art with `git -C ../jj show v0.44.0:<path>`; jj-lib is vendored at `~/.cargo/registry/src/*/jj-lib-0.44.0/`.
- No `jj_lib` type in a public position (`lib.rs:5-28`, enforced by `tests/api_stability.rs` + the `test-jj-adapter-hygiene` Makefile gate). Every jj-lib failure is flattened to an opaque `String`.
- `#![deny(missing_docs)]` (`lib.rs:3`) — every `pub`/`pub(crate)` item needs a doc comment.
- Re-resolve to head per call (ADR-0002); nothing cached across calls. Config is re-read per call (`config::load`), never cached.
- The commit stream is driven item-by-item into `visit`. `ControlFlow::Break` stops it and yields `Ok(Break)`; exhaustion yields `Ok(Continue)`.
- The full gate is the definition of done: `cargo make test` green (clippy pedantic `-D warnings`, rustfmt, `cargo deny`, coverage ratchet). `revset.rs` and `change.rs` sit at a **100.00** baseline — every line added there must be exercised. `view.rs` is a NEW file → ≥ 80.00 `new_file_floor_pct`.
- Commit on `main` with `--no-gpg-sign`; never edit git config.

**Block If:**
- Reusing the existing `Change` struct proves infeasible — e.g. `change_from_commit` cannot be extracted from `get_change` without changing `get_change`'s observable behavior. Minting a *third* commit-shaped public struct is a surface decision beyond this story.
- A new `extern "C"` signature or a `schemas/envelope.fbs` edit turns out to be required. Neither should be: this story adds no FFI file, so `cargo make codegen` must not run and no generated file may drift.
- The coverage ratchet regresses on a file this story did not touch and the drop is not recoverable by testing code this story added.

**Never:**
- **No FFI, Dart or MCP surfacing.** epics.md:477 scopes the full surfacing chain to "each **verb**"; 9.2 delivers no verb, ADR-0003 §5 frames both halves as `zanshin-jj` API, and Story 9.1 set the in-epic precedent. See Design Notes; record the surfacing as deferred.
- No `try_collect`/`collect` over the commit stream, and no `limit`/`start`/`count` parameter — `ControlFlow::Break` *is* the limit (ADR-0002, and `zanshin-graph` already settled return-all-vs-window).
- No `IdPrefixContext::disambiguate_within` index — `Change` carries no prefix lengths, so the plain resolver suffices (verified: `id_prefix.rs:161-189` falls through to the repo index when no disambiguation is set).
- Do not change `resolve_revset`'s or `list_bookmarks`' shipped contracts, and do not fold either into the new code.
- Do not regenerate fixtures. Do not repoint `JJ_CONFIG` (only `tests/config_user_layer.rs` may).
- Do not lower `coverage-baseline.txt` or add an `exclude_prefix`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Walk, happy | `eval_revset("all()")` on `tiny-3-commits` | one `Change` per commit, children before parents (jj-lib `Revset::stream()` contract), `Ok(Continue)` | No error expected |
| Walk, early stop | visitor returns `Break` on the first item, `all()` on `medium-1k-commits` | exactly **one** `Change` constructed, `Ok(Break)` | No error expected |
| Walk, empty set | `eval_revset("none()")` | visitor never called, `Ok(Continue)` | No error expected |
| Walk, divergent change | revset covering a divergent change's visible commits | each commit is its own row; every such row has `divergent == true` | No error expected |
| Stage 1 — parse | `"bogus_function()"` | no walk, no `load_at_head` I/O | `RevsetError::ParseError` |
| Stage 2 — resolution | `"nonexistent-bookmark"` | no walk | `RevsetError::ResolutionError` |
| Stage 3 — evaluation/backend | corrupt repo (`.jj/repo` store unreadable) | no walk | `RevsetError::JjLibError` |
| Config fault | malformed `.jj/repo/config.toml`, or `revset-aliases` not a table | no walk; never a silent fall-back to builtins | `RevsetError::Config` |
| Alias override | repo config overrides `revset-aliases."trunk()"` | the override decides the denoted set (proves effective-config reads, not Rust constants) | No error expected |
| Mid-walk failure | a per-item stream/store failure after N visits | the N already-visited rows are **not** retracted — caller discards partial output on `Err` (same contract as `walk_graph`, `repo.rs:240-241`) | `RevsetError::JjLibError` |
| Tags, local | `set_tag("v1", [commit])` | one row, `TagKind::Local`, `target` = that commit's change id | No error expected |
| Tags, tracked remote | remote tag with `RemoteRefState::Tracked` | one `TagKind::Remote { remote_name }` row **in addition to** any local row | No error expected |
| Tags, untracked remote | remote tag with `RemoteRefState::New` | skipped (mirrors `bookmarks.rs:98`) | No error expected |
| Tags, conflicted target | tag pointing at ≥ 2 commits | first added id's change id (listing scope only, mirrors `bookmarks.rs:87`) | No error expected |
| Tags, none | `tiny-3-commits` untouched | `Ok(vec![])` — absence is an empty list, never an error | No error expected |
| Heads | any fixture | `Vec<CommitId>` sorted by hex — jj's `View::heads()` is an **unordered** `HashSet`, so the sort is ours and is the determinism guarantee | No error expected |
| Working copies, single | `tiny-3-commits` | one row: default workspace name + its wc commit id | No error expected |
| Working copies, multi | after `test_helpers::add_workspace("second")` | two rows in `BTreeMap` order (lexicographic by workspace name — jj-lib's own ordering, preserved) | No error expected |
| View backend failure | `load_at_head` or a store read fails | — | `ViewError::Backend` |

</intent-contract>

## Code Map

Every anchor below was read and verified against the working tree at baseline `e5c0120`.

**Extend — `eval_revset`**
- `crates/zanshin-jj/src/revset.rs` — the whole 3-stage path already exists and is reused unchanged: `parse_revset` `:109` (loads config + builds the alias map), `parse_revset_with` `:122`, `resolve_expression` `:202` (Story 9.1's split-out), `evaluate_revset` `:220` → `Box<dyn Revset + 'r>`. `RevsetError` `:31` already carries `ParseError`/`ResolutionError`/`JjLibError`/`Config` — **no new variant, no new error code** (see Design Notes). `resolve_revset` `:72-96` is the `try_collect` this story supersedes but must NOT change. Baseline **100.00**.
- `crates/zanshin-jj/src/graph.rs:159-219` `walk_graph` — the model to copy: config-once → parse (before any I/O) → `load_at_head` → `evaluate_revset` → `pollster::block_on(async { … })` drive loop with `visit(...).is_break()`. `fn jj<E: Display>` `:75-77` is the local error converter. The lifetime problem (`Revset` borrows the repo) is solved by *never returning the stream*: `readonly` stays a local and items leave through the visitor.
- `crates/zanshin-jj/src/change.rs` — `Change` `:74-108` is the crate's existing typed commit value and the item type to reuse. `get_change` `:145-232` steps 4-8 (parents → signatures/timestamps → conflict state → anonymity) plus the `divergent` computation are what `change_from_commit` extracts. Baseline **100.00**.
- `crates/zanshin-jj/src/repo.rs:256-264` `walk_graph` — the public method shape and doc-comment style to mirror; `:159-172` `list_bookmarks` for the listing style.

**New — `View` helpers**
- `crates/zanshin-jj/src/view.rs` (NEW) — `list_tags` / `list_heads` / `list_working_copies` + `Tag`, `TagKind`, `WorkingCopy`, `ViewError`. `crates/zanshin-jj/src/bookmarks.rs` is the template end to end: `load_at_head` → `view()`/`store()` `:71-73`, the `to_change` closure `:76-79`, local-then-remote iteration with the `is_present() && is_tracked()` filter `:97-100`, `added_ids().next()` for conflicted targets `:87`, terminal sort `:112`.
- jj-lib `View` at 0.44 (`~/.cargo/registry/src/*/jj-lib-0.44.0/src/view.rs`): `local_tags()` `:390`, `all_remote_tags()` `:431`, `heads() -> &HashSet<CommitId>` `:86`, `wc_commit_ids() -> &BTreeMap<WorkspaceNameBuf, CommitId>` `:64`.
- jj-lib `RevsetStreamExt::commits(store)` (`revset.rs:3443-3465`) — `Stream<Result<CommitId,_>>` → `Stream<Result<Commit,_>>` with `.buffered(store.concurrency())`. The CLI uses exactly this at `v0.44.0:cli/src/commands/log.rs:341`.

**Prior art (read-only, at the tag)**
- `v0.44.0:cli/src/commands/log.rs:333-342` — `.take(limit)` applied to the id stream *before* `.commits(store)`, so a bounded query never hydrates commits it will not show. Our `Break` sits in the same position.
- `v0.44.0:cli/src/commands/tag/list.rs:137,190` and `cli/src/commit_ref_list.rs:64-121` — `jj tag list` reads `view.tags()` through the same `collect_items` helper as `jj bookmark list`. Its extra "hide a tracked remote whose target equals the local one" filter is a **display** default; see Design Notes for why we do not adopt it.
- `v0.44.0:cli/src/commands/workspace/list.rs:74` — iterates `view.wc_commit_ids()` directly, relying on the `BTreeMap` order.

**Registration / gates**
- `crates/zanshin-jj/src/lib.rs:30-43` module list (add `view`), `:45-57` re-exports (add the four new public types).
- `crates/zanshin-jj/tests/api_stability.rs` — `:12-77` type aliases (bump the count comment at `:12-13`), `:82-122` `sample_*()` field-naming constructors, `:124-232` `api_surface_resolves()`. Note `:172-173`: a visitor-generic **method** cannot be `fn`-pointer-pinned, so `eval_revset` is pinned by fixture tests like `walk_graph`, and that must be stated in the same comment style.
- `crates/test-helpers/src/lib.rs:289-309` `set_remote_bookmark` — the exact template for a new `set_remote_tag` over `MutableRepo::set_remote_tag` (jj-lib `repo.rs:1871`). `test-helpers` is coverage-excluded (`coverage-baseline.txt:11`).
- `coverage-baseline.txt` — commit the auto-raise if it rises.

**Tests**
- `crates/zanshin-jj/tests/revset.rs` — extend; `:17-27` `pin_env()`, `:50-111` independent jj-lib oracles, `:559` `write_repo_config`, the `// ── AC-N ──` section style.
- `crates/zanshin-jj/tests/graph.rs:38-53` `collect_nodes` / `collect_nodes_with` — the collector-plus-`ControlFlow` assertion helper an `eval_revset` test module should copy.
- `crates/zanshin-jj/tests/view.rs` (NEW) — `tests/bookmarks.rs` is the model for fixture-built ref state.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/change.rs` -- extract `pub(crate) fn change_from_commit(repo_dyn, store, view, &jj_lib Commit) -> Result<Change, String>` (steps 4-8 of `get_change` + the `resolve_change_id` divergence probe) and have `get_change` call it -- one construction site for `Change`, so no third commit shape is minted and both callers keep the file at its 100.00 baseline. The `String` error is the backend reason; each caller wraps it in its own error type, which keeps the helper's single failure mode honest and avoids an unreachable `NotFound` arm.
- `crates/zanshin-jj/src/revset.rs` -- add `pub(crate) fn eval_revset(repo, revset, visit)` following `walk_graph`'s five phases: `config::load` → `build_aliases_map` → `parse_revset_with` (before any I/O) → `load_at_head` → `evaluate_revset` → drive `set.stream().commits(store)` in `pollster::block_on`, constructing each `Change` via `change_from_commit` and stopping on `Break` -- reuses the verified 3-stage path verbatim so the error taxonomy needs no new plumbing.
- `crates/zanshin-jj/src/view.rs` (NEW) -- `Tag`/`TagKind`/`WorkingCopy`/`ViewError` plus `list_tags` (local + tracked-remote, sorted name-then-kind), `list_heads` (sorted by hex), `list_working_copies` (`BTreeMap` order preserved) -- one module for the reads that come straight off the `View`, mirroring `bookmarks.rs` so the crate has one listing idiom.
- `crates/zanshin-jj/src/repo.rs` -- add the four public facades `eval_revset`, `list_tags`, `list_heads`, `list_working_copies`, doc-commented in `walk_graph`/`list_bookmarks` style incl. `# Errors` -- `Repo` methods keep the streaming read next to `walk_graph` and the listings next to `list_bookmarks`.
- `crates/zanshin-jj/src/lib.rs` -- declare `pub(crate) mod view;` and re-export `Tag`, `TagKind`, `WorkingCopy`, `ViewError` -- the only public-surface growth in this story.
- `crates/test-helpers/src/lib.rs` -- add `set_remote_tag(workspace_root, name, remote, target, tracked)` mirroring `set_remote_bookmark` -- without it the tracked/untracked remote-tag rows of the I/O matrix are untestable (the fixtures carry no remote refs, and regenerating them is forbidden).
- `crates/zanshin-jj/tests/api_stability.rs` -- register the four new types (aliases + a `sample_*` field-naming constructor per struct), the `ViewError::Backend` variant, and a comment recording that `eval_revset` is visitor-generic and therefore pinned by fixture tests -- that file's job is to break on surface drift.
- `crates/zanshin-jj/tests/revset.rs` and `crates/zanshin-jj/tests/view.rs` (NEW) -- cover every I/O matrix row, using a `collect_changes`/`collect_changes_with` helper in the `tests/graph.rs:38-53` shape -- integration tests are the right level: all four entry points are public, and `revset.rs`/`change.rs` must stay at 100.00.

**Acceptance Criteria:**
- Given the workspace after this change, when `cargo make test` runs, then it passes end to end with no baseline lowered and no `exclude_prefix` added; `crates/zanshin-jj/src/view.rs` reports ≥ 80.00 % line coverage and `revset.rs` + `change.rs` hold at 100.00 %.
- Given `all()` over `medium-1k-commits`, when the visitor returns `Break` on the first item, then exactly one `Change` was constructed and the call returns `Ok(Break)` — the observable proof that the walk is per-item and the set is never materialized.
- Given `eval_revset`, when the three revset fault classes are triggered in turn, then they surface as three distinguishable outcomes — `ParseError`, `ResolutionError`, and `JjLibError` — with the parse fault raised before any `load_at_head` I/O.
- Given `zanshin-jj`'s public API compared against the pre-change surface, then the only additions are the four `Repo` methods and the four re-exported types, every one of them is pinned in `tests/api_stability.rs`, no `jj_lib` type appears in any public position, and `test-jj-adapter-hygiene` passes.
- Given no FFI source file was touched, when `git status --porcelain` is read after the run, then `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart`, the flatc outputs and `schemas/envelope.fbs` are all unchanged, and `cargo make codegen` was never run.
- Given `docs/rust-error-codes.md`, when it is read, then it is unchanged — `jj.revset_parse_error` and `jj.revset_resolution_error` (`:54-55`) already name the Epic 9 `eval_revset` joker as a reuser, and this story emits no new code.
- Given a second workspace added to a fixture, when `list_working_copies` runs, then it returns the view half of `jj workspace list` (name → commit id) and no workspace *path*, leaving `WorkspaceStore::get_workspace_path` to Story 9.7.

## Spec Change Log

## Review Triage Log

### 2026-09-03 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 15: (high 0, medium 3, low 12)
- defer: 3: (high 0, medium 2, low 1)
- reject: 11: (high 0, medium 0, low 11)
- addressed_findings:
  - `[medium]` `[patch]` The shipped signature contradicted three canonical documents and none had been reconciled: `docs/adr/0003-…md` §5, `epics.md:5529` and `project-context.md:179` all specify `eval_revset(&str) -> Stream<Commit>`, while the code ships a visitor. project-context.md's own rule makes such an inconsistency "a bug to fix, not a choice to make silently", so all three plus `epic-9-context.md` gained an as-built note (the ADR as a new `## Implementation notes` section, leaving its Decision text intact) recording the visitor shape, the borrow reason, and that laziness / no-collect / mid-walk cancellation are all preserved.
  - `[medium]` `[patch]` `change_from_commit`'s doc claimed divergence was re-derived "without repeating the probe" — the opposite of what the code does. The extraction deleted `get_change`'s free `targets.is_divergent()` and replaced it with a second `resolve_change_id`, so every `get_change` call now pays two index probes. Documented honestly, with the reason the second (index-only) probe is worth one construction site for `Change`.
  - `[medium]` `[patch]` No test could distinguish a remote tag row that reports the REMOTE ref's target from one that wrongly reuses the local tag's: every remote-tag test pointed both at the same commit, and the only remote-without-local case was untracked, so it produced no row at all. Added `tags_remote_row_reports_the_remote_refs_own_target` with genuinely differing targets — the ordinary state after a local retag or a fetch that moved the remote.
  - `[low]` `[patch]` The committed spec file ended with stray `</content>` / `</invoke>` lines — authoring-harness markup that leaked into a tracked artifact. Removed.
  - `[low]` `[patch]` `change_from_commit` took `store` and `view` as parameters although `jj_lib::repo::Repo` exposes both (`repo.rs:124,130`), which permitted a call mixing a view from one head resolution with a repo from another. Both are now derived from `repo_dyn`, making that unrepresentable and dropping two arguments (plus the now-unused `Arc` import and two dead locals).
  - `[low]` `[patch]` The laziness claim overstated what is bounded: `RevsetStreamExt::commits` applies `.buffered(store.concurrency())`, so a `Break` may leave several commit loads dispatched. Reworded on both `revset::eval_revset` and `Repo::eval_revset` to promise one `Change` per visited row and I/O bounded by a constant rather than by the set.
  - `[low]` `[patch]` Neither doc said that rows are NOT deduplicated by change id — `resolve_revset` dedups, `eval_revset` emits one row per commit, and every downstream consumer will key on change id. Stated explicitly on both, cross-referencing the divergent-row behaviour.
  - `[low]` `[patch]` `list_tags`' documented "or a store read failed" `ViewError::Backend` had no test: the three `*_on_corrupt_repo_*` tests only exercise `load_at_head`. Added `tags_store_read_failure_returns_backend_error`, removing exactly the tagged commit's loose object.
  - `[low]` `[patch]` `TagKind`'s declared secondary sort key (remotes by `remote_name`) was never exercised, and no test covered a tracked remote tag without a local counterpart. Added `tags_remote_only_rows_sort_by_remote_name` covering both.
  - `[low]` `[patch]` The mid-stream `Break` case — visitor continuing N times then stopping, i.e. ordinary GUI paging — was untested; callers only ever passed `1` or `usize::MAX`. Added `eval_revset_break_after_several_items_stops_exactly_there`.
  - `[low]` `[patch]` `eval_revset("")` had no documented behaviour and no test, on a primitive whose entire purpose is passing an arbitrary caller string through. Added `eval_revset_empty_expression_is_a_parse_error`, pinning it as a stage-1 fault with no walk.
  - `[low]` `[patch]` `heads_equal_the_view_oracle_and_are_sorted_by_hex` compared the result against a sorted copy of ITSELF, so dropping the sort would only have failed on the runs where the `HashSet` happened to iterate out of order. The expected order is now built from the independent oracle.
  - `[low]` `[patch]` `eval_revset_row_matches_get_change_for_the_same_change` claimed to prove "the reuse of `Change` is genuine, not a look-alike", but after the extraction both sides run the same constructor, so a regression inside it moves both sides together. Comment corrected to state what it actually pins, pointing at `tests/change.rs` for the field derivations.
  - `[low]` `[patch]` `sample_tag`'s doc comment in `tests/api_stability.rs` claimed to name `WorkingCopy` fields as well; it constructs only `Tag`.
  - `[low]` `[patch]` The Design Notes cited "Story 9.1 shipped `zanshin-jj`-only" as a scope signal. That overstates — 9.1 edited `zanshin-ffi`, ran `cargo make codegen` and committed the regenerated header and bindings; it added no new `extern "C"` *signature*. Replaced with three stronger signals drawn from the intent's own text (9.2's placement under `### Precursors`, its missing `[M]`/`[R]` tag, and "extends 2.5" pointing at a Rust-caller story), and extended the FFI deferred entry to record that the `View` listings' `ViewError` still has no `<domain>.<reason>` code.

Notes on the two categories that stayed empty. **No `intent_gap`:** the intent-alignment audit enumerated four readings and confirmed the diff implements a determinate one, supplying two signals the spec had not cited (Precursors placement, no `[M]`/`[R]` tag) plus "extends 2.5" — all admissible scope authority from the intent itself. **No `bad_spec`:** every patch is additive; re-deriving from an amended spec would reproduce byte-identical `view.rs`/`revset.rs` Rust, so a loopback's entire yield would have been these doc and test edits (the same reasoning Story 9.1 recorded).

The patches were applied directly rather than delegated back to the implementation subagent — Story 9.1's Process note records that re-engaging it in a loop that cannot block on its result clobbered files.

## Design Notes

**Scope: `zanshin-jj` only — this is derived, not assumed.** Six independent signals select the crate-level reading. (1) epics.md:477 binds the `.fbs` → `extern "C"` → Dart → MCP chain to "each **verb**"; 9.2 delivers no verb. (2) ADR-0003 §5 states both halves as `zanshin-jj` API shape. (3) In epics.md, 9.2 sits under `### Precursors` (:5517) with 9.0/9.0a/9.1 — *not* under Tier A/B/C, where the verbs live. (4) It carries no `[M]`/`[R]` tag, while every Tier story does. (5) The intent's own "extends 2.5" points at Story 2.5, which is framed "As a **Rust caller**…" with all of its acceptance at `resolve_revset` + `tests/revset.rs`. (6) Decisively: `Stream<Commit>` has no wire representation — the FFI boundary is snapshot-only (`zanshin_graph_slice` returns a materialized `Vec<Row>`), so surfacing `eval_revset` faithfully would have to `try_collect`, contradicting the story's own core constraint. The GUI is not blocked meanwhile: `zanshin_graph_slice` already accepts a caller-supplied revset. FFI/MCP exposure — including the still-open ADR-0003 question of whether MCP gets the raw joker or only named views — is recorded as deferred.

*Correction (review pass):* an earlier version of this note cited "Story 9.1 shipped `zanshin-jj`-only" as a signal. That overstates: 9.1 did edit `crates/zanshin-ffi/src/{envelope.rs,repo.rs}`, ran `cargo make codegen`, and committed the regenerated header and bindings. The accurate — and still supporting — statement is that 9.1 added no new `extern "C"` **signature**. Signals (3)-(5) replace it and are stronger, coming from the intent's own text.

**The shipped signature deviates from ADR-0003's literal wording, and the canonical docs were reconciled.** ADR-0003 §5, epics.md:5529 and project-context.md all write `eval_revset(&str) -> Stream<Commit>`. What is buildable is a visitor, for the borrow reason above. Per project-context.md's own rule ("when a rule here conflicts with epics.md, raise it — an inconsistency is a bug to fix, not a choice to make silently"), all three plus `epic-9-context.md` were amended with an as-built note rather than left contradicting the code.

**The visitor is the stream.** `Revset::evaluate` returns `Box<dyn Revset + 'index>` borrowing the repo, so a stream cannot be returned from a function that also owns the `ReadonlyRepo`. `walk_graph` solved this by inverting control, and that inversion *is* the ADR-0002 property the epic asks for: lazy, never collected, cancellable mid-walk. Copy it rather than reaching for a self-referential struct or the CLI's `RevsetExpressionEvaluator<'repo>` (which works only because the CLI's caller owns the repo borrow).

**Reuse `Change`; do not mint a third commit shape.** The crate already has two: `Change` (`change.rs:74`, full metadata for one change) and `CommitMeta` (`commit_meta.rs:55`, `jj log`-parity *display* decoration — prefix lengths, per-row bookmark/tag refs, an immutability probe). `CommitMeta` is the wrong currency here: it exists to render a log row and its `LogMetaIndex` costs a prefix index plus an immutable-set evaluation per call, which `eval_revset` has no use for. `Change` is what a caller asking "which commits does this revset denote" wants. Reusing it costs one extraction in `change.rs` and keeps the public vocabulary at two shapes.

**Ordering is the raw revset order, not `jj log`'s.** `Revset::stream()` promises topological order, children before parents. `walk_graph` additionally applies `TopoGroupedGraph` + `prioritize_branch` to match `jj log`'s printed order. `eval_revset` deliberately does neither — it is the freedom primitive, and log parity is `walk_graph`'s job. Say so in the doc comment so the two are not confused.

**The error taxonomy is preserved by reuse, not by extension.** The three stages already map to `ParseError` / `ResolutionError` / `JjLibError` (evaluation shares the catch-all with backend faults), and `docs/rust-error-codes.md:54-55` pre-authorizes exactly two codes for this story, naming it. Adding a distinct `EvaluationError` would be an extension, not preservation, and would strand an unused envelope constant since nothing here crosses FFI. Keep the split as shipped; what this story must prove is that the *new* path yields all three distinctly rather than collapsing into `JjLibError`.

**Identity currency differs by kind, on purpose.** Tags mirror `Bookmark.target` and carry a `ChangeId` — both are named refs and 2.8 set that contract. Heads and working copies carry `CommitId`, because that is literally what `View::heads()` and `View::wc_commit_ids()` hold: heads are graph heads, and two divergent commits of one change can both be heads, so collapsing to a change id would fabricate duplicates. `Status.working_copy_change_id` already offers the change-id form for the current workspace.

**`list_tags` lists tracked remotes unconditionally.** The CLI's `jj tag list` hides a tracked remote whose target equals the local one (`commit_ref_list.rs:89-91`). That is a display default, and `commit_meta.rs:228-229` already records the project's split: the filtered view is the per-row decoration's job, "the unfiltered view is `list_bookmarks`' job". Mirroring `list_bookmarks` keeps the two named-ref listings identical and honours "the backend classifies and offers, the UI decides". Document the divergence at the function.

## Verification

**Commands:**
- `cargo make test` -- expected: green end to end (tests + clippy `-D warnings` + rustfmt + `cargo deny` + coverage ratchet). The single gate; run it unpiped and capture the exit code.
- `git -C ../jj show v0.44.0:cli/src/commit_ref_list.rs` -- expected: confirms the tag/bookmark listing filters before trusting the anchors above.
- `git status --porcelain` -- expected: after the run, only intended files; no generated file (`zanshin_ffi.h`, `bindings.dart`, flatc outputs, `schemas/envelope.fbs`) appears; `coverage-baseline.txt` appears only if the ratchet raised it.

**Manual checks (if no CLI):**
- Diff the crate's `pub` items: confirm the additions are exactly the four `Repo` methods plus `Tag`/`TagKind`/`WorkingCopy`/`ViewError`, and that no `jj_lib` type leaked into a public signature.

## Auto Run Result

Status: done
Commits: `9d58e6ca5ff2329a505d4b9a8f28457432113339` (the primitive + the `View` listings),
`0aecf67` (the mid-walk store-failure test) and the review-patch commit, all on `main`, baseline
`e5c0120c01023e0238adce29eadf3d75b1a9e82c`.

**Summary.** `Repo::eval_revset` is ADR-0003 §5's generic read joker: a lazy walk over the shipped
parse→resolve→evaluate path that hands the caller one `Change` per commit and never collects the
set. It ships as a **visitor** — `eval_revset(&str, impl FnMut(Change) -> ControlFlow<()>)` — not
as the returned `Stream<Commit>` the ADR's wording asks for, because `Revset::evaluate` borrows
the `ReadonlyRepo` that the call itself loads (ADR-0002 reload-per-operation), so a stream cannot
outlive the function that owns it. That is the same inversion `Repo::walk_graph` already uses, and
every property the ADR actually asks for survives it: lazy `Box<dyn Revset>`, no `try_collect`,
cancellable mid-walk via `ControlFlow::Break`, which *is* the limit (there is no `limit`/`start`/
`count` parameter). All four canonical documents that stated the stream signature were reconciled
rather than left contradicting the code.

The item type is the crate's **existing** `Change`: steps 5-9 of `get_change` moved into
`change::change_from_commit`, so there is one construction site and no third commit shape.
`CommitMeta` was deliberately not reused — it is `jj log` *display* decoration whose `LogMetaIndex`
costs a prefix index and an immutable-set evaluation per call, which this primitive has no use for.

The new `view.rs` adds the direct `View` reads: `list_tags`, `list_heads`, `list_working_copies`
(bookmarks already shipped in 2.8). Three deliberate decisions are worth carrying forward. Tags
carry a `ChangeId` like `Bookmark.target`, but heads and working copies carry `CommitId`, because
that is what the view holds and because two divergent commits of one change can both be heads —
collapsing to change ids would fabricate duplicates. `list_heads` sorts by hex: jj's `View::heads()`
is an unordered `HashSet`, so the ordering is Zanshin's guarantee, not jj's. And `list_tags` does
NOT apply the CLI's "hide a synced tracked remote" filter — that is a display default, and the
project's split puts the filtered view in `CommitMeta::tags` and the unfiltered one here, exactly
as `list_bookmarks` already does.

The three-stage error taxonomy is preserved by **reuse, not extension**: parse and resolution keep
their distinct variants, evaluation continues to share `JjLibError` with backend faults, and
`docs/rust-error-codes.md` is untouched because it already reserves exactly those two revset codes
for this story by name. What the tests prove is that the *new* path yields all three distinctly
instead of collapsing them.

**Scope.** `zanshin-jj` only — no `.fbs`, no `extern "C"`, no Dart, no MCP. Six signals select that
reading (see Design Notes); the decisive one is that a `Stream` has no wire representation, so a
faithful surfacing would have to `try_collect` and contradict the story's own constraint. The GUI
is not blocked meanwhile: `zanshin_graph_slice` already takes a caller-supplied revset.

**Files changed.**
- `crates/zanshin-jj/src/revset.rs` — `eval_revset`, driving `set.stream().commits(store)` through
  the visitor inside `pollster::block_on`.
- `crates/zanshin-jj/src/change.rs` — `change_from_commit` extracted from `get_change`; takes only
  `(repo_dyn, commit)`, deriving `store`/`view` from the repo so a mixed-snapshot call is
  unrepresentable.
- `crates/zanshin-jj/src/view.rs` — the three `View` listings plus `Tag`/`TagKind`/`WorkingCopy`/
  `ViewError`.
- `crates/zanshin-jj/src/repo.rs`, `src/lib.rs` — the four public facades and re-exports.
- `crates/test-helpers/src/lib.rs` — `set_remote_tag`, mirroring `set_remote_bookmark`.
- `docs/adr/0003-…md` (new `## Implementation notes`), `_bmad-output/planning-artifacts/epics.md`,
  `_bmad-output/project-context.md`, `_bmad-output/implementation-artifacts/epic-9-context.md` —
  as-built notes for the visitor signature.
- Tests: 13 `eval_revset` rows in `tests/revset.rs`, 15 in the new `tests/view.rs`, and the four
  new types plus the three listings pinned in `tests/api_stability.rs`.

**Review findings.** 15 patched (0 high, 3 medium, 12 low), 3 deferred (2 medium, 1 low), 11
rejected. No `intent_gap` and no `bad_spec` — see the Triage Log for why each stayed empty.

**Follow-up review recommended:** true. Patched this pass: high 0, medium 3, low 12 →
score `3×3 + 1×12 = 21`, at or above the threshold of 5. Note for whoever acts on it: the yield is
likely to be small. The three mediums were a doc/code contradiction, a misleading doc sentence and
one genuinely missing test, all now closed; the remaining low-severity space is test shape and
wording. Per this run's instructions no optional extra pass was started.

**Verification performed.** `cargo make test` run to completion twice, unpiped with the exit code
captured — after implementation (`GATE_EXIT=0`, `Build Done in 314.48 seconds`) and again after the
review patches (`GATE_EXIT=0`, `Build Done in 285.78 seconds`). It covers `cargo test --workspace`,
clippy pedantic `-D warnings`, rustfmt, `flutter test` + `dart analyze`/`format`, `cargo deny`
(`advisories ok, bans ok`), the coverage ratchet (`coverage-check: OK — coverage held at 99.04%
(5584/5638 lines)`, so `coverage-baseline.txt` was neither raised nor lowered by the patches) and
`extern-coverage: OK`. `git diff` against the FFI header, `bindings.dart`, the flatc outputs,
`schemas/envelope.fbs` and `docs/rust-error-codes.md` is empty — `cargo make codegen` was never run.
The CLI prior art was re-read at the pin (`git -C ../jj show v0.44.0:cli/src/commit_ref_list.rs`)
and the `include_synced_remotes` / inclusion-predicate anchors confirmed before relying on them.
Every I/O matrix row was audited against a test that actually appears in the run output; the one row
the implementation had left uncovered — "mid-walk failure" — was closed rather than deferred, by
removing a single loose object so `N ≥ 1` rows are visited before the failure (`Buffered` preserves
output order, so the position is fixed, not racy).

**Residual risks.**
- Two tests depend on git's loose-object layout under `.jj/repo/store/git/objects/` and on the
  store not having cached the commit. Both carry a "re-verify at the next pin bump" comment; the
  layout itself is git's and stable, but where jj surfaces the failure is not contractual.
- `eval_revset` emits one row per COMMIT and does not deduplicate by change id, unlike
  `resolve_revset`. Now documented on both the free function and the facade, but it is a real trap
  for a consumer that keys rows by change id.
- `get_change` now performs a second, index-only `resolve_change_id` (the divergence probe moved
  into the shared constructor). Documented at the site; the alternative would put the D4 rule back
  at every call site.
- The `View` listings' `ViewError` has no `<domain>.<reason>` code yet, because nothing crosses
  FFI. Recorded in the deferred list so the surfacing story does not miss it.
- Whether jj's `git` pseudo-remote can produce duplicate rows in `list_tags`/`list_bookmarks` could
  not be settled from the committed fixtures (they carry no remote refs). Deferred with the
  evidence needed to close it.
