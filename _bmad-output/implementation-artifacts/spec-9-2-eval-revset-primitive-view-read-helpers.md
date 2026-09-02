---
title: 'Story 9.2: `eval_revset` generic read primitive + `View` read helpers'
type: 'feature'
created: '2026-09-02'
status: 'in-progress'
baseline_revision: 'e5c0120c01023e0238adce29eadf3d75b1a9e82c'
review_loop_iteration: 0
followup_review_recommended: false
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
    location: >-
      crates/zanshin-ffi/ (no file touched), schemas/envelope.fbs (unchanged), crates/zanshin-mcp/
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

## Design Notes

**Scope: `zanshin-jj` only — this is derived, not assumed.** Four independent signals select the crate-level reading. (1) epics.md:477 binds the `.fbs` → `extern "C"` → Dart → MCP chain to "each **verb**"; 9.2 delivers no verb. (2) ADR-0003 §5 states both halves as `zanshin-jj` API shape. (3) Story 9.1, the immediate predecessor in this epic, shipped `zanshin-jj`-only and made a required `extern "C"` signature an explicit *Block If*. (4) Decisively: `Stream<Commit>` has no wire representation — the FFI boundary is snapshot-only (`zanshin_graph_slice` returns a materialized `Vec<Row>`), so surfacing `eval_revset` faithfully would have to `try_collect`, contradicting the story's own core constraint. The GUI is not blocked meanwhile: `zanshin_graph_slice` already accepts a caller-supplied revset. FFI/MCP exposure — including the still-open ADR-0003 question of whether MCP gets the raw joker or only named views — is recorded as deferred.

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
</content>
</invoke>
