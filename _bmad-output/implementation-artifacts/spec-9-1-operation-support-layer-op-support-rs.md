---
title: 'Story 9.1: Operation-support layer (zanshin-jj/src/op_support.rs)'
type: 'feature'
created: '2026-09-02'
status: 'done'
baseline_revision: 'a35f15846761e4ca430876102ee5671dba79f5a8'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['oversized']
deferred:
  - summary: >-
      `describe`, `edit` and `new_change` still call bare `rebase_descendants()`, which
      passes `none()` as the immutable set, where the CLI always passes the resolved one.
    evidence: |-
      Only `abandon` was switched to `rebase_descendants_with_options(&resolved_immutable, …)`,
      because that is the call Story 9.0a flagged. The CLI's `rebase_mutable_descendants`
      (`cli_util.rs:2927`) runs at transaction finish for EVERY command. The divergence has no
      observable consequence today: the immutable set is `::(immutable_heads() | root())` and so
      is ancestor-closed, which means a target that passes `check_rewritable` provably has no
      immutable descendants. The residual case is the one the CLI's own comment names — a
      `jj git fetch` updating immutable commits between `tx.base_repo()` and `tx.repo()`. Worth a
      single consistent policy when the Tier C verbs land rather than three more ad-hoc call sites.
    location: >-
      crates/zanshin-jj/src/mutate.rs (describe/edit/new_change `rebase_descendants()` calls)
    severity: low
  - summary: >-
      `MutateError::Immutable` carries a raw commit hex, while every other identity in this
      crate's mutation API is a `ChangeId`.
    evidence: |-
      The GUI calls `describe(changeId)` and, on refusal, gets back a commit hex it must resolve
      separately to map onto the change it just submitted. The CLI reports the commit id
      (`{commit_id:.12}`), so this is CLI-faithful, and the offender is always one of the caller's
      own targets — but the crate's public convention at the API boundary is change ids. Decide
      when the GUI actually consumes the code; changing the variant's shape later ripples into
      the FFI `context` contract.
    location: >-
      crates/zanshin-jj/src/mutate.rs (MutateError::Immutable)
    severity: low
  - summary: >-
      `describe` and `abandon` report the root commit as `jj.invalid_input`, where the jj CLI
      reports it as immutable.
    evidence: |-
      Their explicit root guards run BEFORE the new immutability guard, deliberately: those guards
      exist to pre-empt jj-lib's internal `assert!` (a process crash, not an error), and moving the
      immutability guard ahead of them would make those lines unreachable — dropping `mutate.rs`
      below its coverage baseline while also changing a shipped error code. `edit`, which never had
      such a guard, does report root as `jj.immutable`. Both refuse and neither writes an op-log
      entry, so the observable outcome matches the CLI; only the code differs, and only for root.
    location: >-
      crates/zanshin-jj/src/mutate.rs (describe/abandon root guards)
    severity: low
  - summary: >-
      `op_support.rs`'s inline tests are the first code to mutate the process environment inside
      the `zanshin-jj` LIB test binary.
    evidence: |-
      Every other `JJ_CONFIG`/`GIT_CONFIG_GLOBAL` pin lives in a `tests/` binary where all tests
      share it. `set_var` is `unsafe` precisely because it races a concurrent `getenv` in another
      thread. Verified not to be an acute problem today: the only other env reader in that binary
      is `config.rs`'s `ConfigEnv::from_env`, and `config.rs`'s own inline tests construct
      `ConfigEnv` explicitly instead of calling it. It is a latent hazard for the next inline test
      that reads the environment. Moving these tests to `tests/` is not an option — they exercise
      `pub(crate)` items, which integration tests cannot see.
    location: >-
      crates/zanshin-jj/src/op_support.rs (inline `#[cfg(test)]` ENV_GUARD)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Every thick jj verb (Tier C: squash/split/rebase/duplicate/revert/…) needs four pieces of orchestration that live in jj-cli's `cli_util` and are absent from jj-lib: the immutable-heads rewritability guard, insert-location resolution for `-A`/`-B`/`--onto`, description combination with trailers, and the selected-tree plumbing that the CLI drives from an interactive hunk selector. Without a shared layer each verb would re-port them, and today the shipped mutations (`describe`/`edit`/`abandon`) rewrite immutable commits where jj refuses — the parity gap Story 9.0a deferred here.

**Approach:** Add `crates/zanshin-jj/src/op_support.rs`, an entirely `pub(crate)` layer re-porting those four pieces at v0.44.0 CLI parity, reusing jj-lib wherever it already exposes the primitive (`restore_tree`, `CommitWithSelection`, `trailer::*`, `rebase_descendants_with_options`). Wire only the guard into the three existing rewriting verbs, which closes the 9.0a gap and gives the layer a real consumer; the other three helpers ship tested-but-unwired because their consumers are Tier C by design.

## Boundaries & Constraints

**Always:**
- CLI **observable behavior** at tag `v0.44.0` is the oracle (NFR-R-2): same preconditions, same refusals, same op-log effect. Read prior art with `git -C ../jj show v0.44.0:<path>`.
- `op_support` is `pub(crate)`. No `jj_lib` type may appear in a public position (`lib.rs:17-28`, enforced by `tests/api_stability.rs` + the `test-jj-adapter-hygiene` gate). Nothing new is re-exported from `lib.rs`.
- Every `pub`/`pub(crate)` item needs a doc comment — `#![deny(missing_docs)]` at `lib.rs:3`.
- No `panic!` on a caller-reachable path: the CLI's two `panic!`s in `compute_commit_location` become `Result` errors.
- The full gate is the definition of done: `cargo make test` green (clippy pedantic `-D warnings`, rustfmt, `cargo deny`, coverage ratchet). `op_support.rs` is a NEW file → must clear the 80.00 % `new_file_floor_pct`.
- Commit on `main` with `--no-gpg-sign`; never edit git config.

**Block If:**
- A new `extern "C"` signature turns out to be required (it should not be — a new error *code* is a string, not a signature change). That would pull `cargo make codegen` + `bindings.dart` into scope.
- The coverage ratchet regresses on a file this story did not touch and the drop is not recoverable by testing code this story added.

**Never:**
- Do not port the CLI's terminal UX: no `$EDITOR` buffer (`combine_messages_for_editing`'s `JJ: `-comment scratch text), no `DiffEditor`/`MergeEditor` subprocess spawning, no `Ui` warnings/prompts. Interactive verbs take a GUI-supplied tree id (ADR-0003).
- Do not port jj's **template engine**. `templates.commit_trailers` rendering is out of scope; the trailer helper takes already-materialized `Trailer` values. Do not add `templates.commit_trailers` to `BUILTIN_CONFIG_TOML` — `config.rs:71-73` forbids advertising a default we do not honour.
- Do not implement any Tier C verb, and do not add an `--ignore-immutable` parameter to any verb's public signature.
- Do not lower `coverage-baseline.txt` or add an `exclude_prefix`.
- Do not reorder the existing root-commit guards in `mutate.rs` (see Design Notes).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Guard passes | `check_rewritable` over commits disjoint from `::(immutable_heads() \| root())` | `Ok(())` | No error expected |
| Guard refuses | a target inside the immutable set | Refusal naming the **first** offender only (CLI takes `try_next`, never a list) | `MutateError::Immutable { commit_id }` → `jj.immutable` |
| Verb refuses | `Repo::describe`/`edit`/`abandon` on a tagged (∴ immutable) commit | No mutation, **no op-log entry** | `MutateError::Immutable` |
| Root commit | `describe`/`abandon` on root | Refused as today — `InvalidInput`, message unchanged | `jj.invalid_input` (pre-existing) |
| Location `-A` only | `insert_after = [a]` | parents `[a]`, children = all direct children of `a` | — |
| Location `-B` only | `insert_before = [b]` | parents = `b`'s parents, order-preserving + deduped; children `[b]` | — |
| Location `-A` + `-B` | both given | parents `a`, children `b` — taken verbatim, no revset evaluation | — |
| Location `--onto` | `destination = [d]` | parents `[d]`, children `[]` | — |
| Location conflict | `destination` together with `-A`/`-B` | Refusal (CLI `panic!`s; a library must not) | `MutateError::InvalidInput` |
| Location empty | none of the three given | Refusal | `MutateError::InvalidInput` |
| Location loop | children would be ancestors of parents | `Refusing to create a loop: commit <hash> would be both an ancestor and a descendant of the <commit_type>` | `MutateError::InvalidInput` |
| No parents | resolved parent set is empty | `No revisions found to use as parent` | `MutateError::InvalidInput` |
| Combine, one non-empty | sources `["", "x"]`, dest `""` | `Some("x")` | No error expected |
| Combine, none non-empty | all empty | `Some("")` | No error expected |
| Combine, ambiguous | ≥ 2 non-empty descriptions | `None` — caller/GUI must decide | No error expected |
| Trailers onto prose | description without a trailer block | one blank line opens a new paragraph, then `key: value` lines | — |
| Trailers onto trailers | description already ending in a trailer block | appended directly, **no** blank line inserted | — |
| Trailer dedup | new trailer equal (key **and** value) to an existing one | skipped | — |
| Selected tree, paths | `before`/`after` trees + a matcher | jj-lib `restore_tree` result — the CLI's `DiffSelector::NonInteractive` behavior exactly | Backend error → `MutateError::Backend` |
| Selected tree, GUI id | a hex tree id supplied by the caller | re-hydrated `MergedTree` via `MergedTree::new(store, Merge::resolved(id), ConflictLabels::unlabeled())` | malformed/unknown id → `MutateError::InvalidInput` / `Backend` |

</intent-contract>

## Code Map

Everything below was verified against jj-cli at `v0.44.0` and the vendored `jj-lib-0.44.0`.

**New file**
- `crates/zanshin-jj/src/op_support.rs` -- the whole layer, `pub(crate)`. Four sections; inline `#[cfg(test)] mod tests` is **mandatory** for the three unwired helpers, because `pub(crate)` items are invisible to `tests/` (integration tests link the crate as an external lib). `test-helpers` is a dev-dependency (`Cargo.toml:23`), so inline tests may extract fixtures.

**Prior art (read-only, at the tag)**
- `cli/src/cli_util.rs:2002` `check_rewritable` → `:2011` `check_rewritable_expr` (the ~35-line body is the thing to port); `:1118` `resolve_immutable_expression`; `:2927` `rebase_mutable_descendants`; `:3551` `compute_commit_location`; `:3641` `ensure_no_commit_loop`; `:3494`/`:3508` `DiffSelector` + `select`.
- `cli/src/description_util.rs:299` `try_combine_messages`; `:392` `add_trailers_with_template` (the append/dedup rule at `:396-416`).
- `cli/src/revset_util.rs:194` `parse_immutable_heads_expression` — already mirrored by us.

**Already present — reuse, do not rebuild**
- `crates/zanshin-jj/src/revset.rs:288-294` `immutable_expression(repo, aliases_map)` → `::(immutable_heads() | root())`. **Half the guard already exists**; it is currently used only by `graph.rs`.
- `crates/zanshin-jj/src/revset.rs:195-207` `evaluate_revset(&dyn Repo, expr)`. `MutableRepo` implements `jj_lib::repo::Repo` (`jj-lib-0.44.0/src/repo.rs:2108`), so it already works mid-transaction. It *discards* the resolved expression — extract a `resolve_expression` helper here (see Execution) rather than duplicating three lines in `op_support`.
- `crates/zanshin-jj/src/config.rs:99` — `immutable_heads()`, `builtin_immutable_heads()`, `immutable()`, `mutable()` are all in `BUILTIN_CONFIG_TOML`, layered so user/repo/workspace config overrides by (name, arity). **No new config plumbing.**
- `crates/zanshin-jj/src/graph.rs:169-176` — the canonical per-operation idiom: `config::load(repo)` → `build_aliases_map` → `immutable_expression`. Copy it.
- jj-lib: `rewrite::restore_tree` (`rewrite.rs:133`), `rewrite::CommitWithSelection` (`:1259`), `merge::Diff::new`, `merged_tree::MergedTree::new` (`merged_tree.rs:90`), `conflict_labels::ConflictLabels::unlabeled` (`conflict_labels.rs:31`), `trailer::{Trailer, parse_description_trailers, parse_trailers}`.

**Wiring targets**
- `crates/zanshin-jj/src/mutate.rs:184` `describe`, `:298` `edit`, `:337` `abandon` -- take the immutable expression as a new parameter and run the guard. `:379-385` is the `RevsetExpression::none()` placeholder its own `// WHY:` names as the pre-0.44-preserving stand-in — replace it with the resolved set (CLI `rebase_mutable_descendants`).
- `crates/zanshin-jj/src/mutate.rs:53-100` `MutateError` -- new `Immutable { commit_id: String }` variant.
- `crates/zanshin-jj/src/repo.rs:282/316/334` `Repo::describe`/`edit`/`abandon` -- build the expression from `&self` **before** `self.workspace_mut()`; `immutable_expression` returns an owned `Arc`, so the `&self` borrow ends cleanly. `Repo::new_change` (`:300`) is deliberately **not** wired.
- `crates/zanshin-ffi/src/envelope.rs` + `crates/zanshin-ffi/src/repo.rs:77-100` `map_mutate_err` -- new arm; `:922-963` shows the per-variant inline mapper test to match.
- `docs/rust-error-codes.md:58` region -- add the `jj.immutable` row in the established 4-column format.
- `coverage-baseline.txt` -- commit the auto-raise if it rises.

**Tests**
- `crates/zanshin-jj/tests/op_support.rs` (new) -- guard behavior **through the public verbs**. `crates/zanshin-jj/tests/mutate.rs:17-24` is the model for `pin_env()` and `:50-100` for the `oracle_layout()` by-description commit discovery.
- **Fixture caveat:** `tiny-3-commits` has no remote bookmarks and no tags, so `trunk()` degenerates to `root()` and the immutable set is exactly `::root()`. A non-root immutable commit must be constructed in-test — `test_helpers::set_tag` is the lever (`tags()` is a term of `builtin_immutable_heads()`). Never regenerate fixtures. Do **not** repoint `JJ_CONFIG`; `tests/config_user_layer.rs` is the only file allowed to.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/revset.rs` -- extract `pub(crate) fn resolve_expression(&dyn Repo, &Arc<UserRevsetExpression>) -> Result<Arc<ResolvedRevsetExpression>, RevsetError>` from `evaluate_revset`'s body and have `evaluate_revset` call it -- the guard needs the *resolved* expression (that is what `rebase_descendants_with_options` takes); extracting keeps the file DRY and every line stays exercised, so its 100.00 % baseline holds.
- `crates/zanshin-jj/src/op_support.rs` -- **§1 guard:** `resolve_immutable(repo_dyn, aliases-derived expr)` mirroring `cli_util.rs:1118`, plus `check_rewritable(repo_dyn, &immutable, &[CommitId])` mirroring `:2011` — intersect, evaluate, take the first offender, refuse -- this is the piece 9.0a deferred to this story.
- `crates/zanshin-jj/src/op_support.rs` -- **§2 location:** `compute_commit_location(repo_dyn, destination, insert_after, insert_before, commit_type)` over already-resolved `CommitId` slices, returning `(parents, children)`, with the CLI's post-checks (`check_rewritable` on children, loop check, empty-parents refusal) -- callers resolve their own revsets, keeping this layer free of parse concerns and unit-testable.
- `crates/zanshin-jj/src/op_support.rs` -- **§3 descriptions:** `try_combine_messages(sources: &[&str], destination: &str) -> Option<String>` and `apply_trailers(description, &[Trailer]) -> String` -- pure string functions, so they carry the file's coverage cheaply and need no repo.
- `crates/zanshin-jj/src/op_support.rs` -- **§4 selection:** a `SelectedTree` wrapper with a path/matcher constructor (over jj-lib `restore_tree`) and a GUI-tree-id constructor, plus assembly into jj-lib's `CommitWithSelection` -- the seam that replaces `DiffSelector`, whose downstream consumers (`squash_commits`) already exist in jj-lib.
- `crates/zanshin-jj/src/mutate.rs` -- add the `Immutable` variant; thread the immutable expression into `describe`/`edit`/`abandon`; run the guard after the existing root check; replace the `none()` placeholder at `:384` -- closes the CLI-parity gap on the shipped verbs.
- `crates/zanshin-jj/src/repo.rs` -- build the expression before `workspace_mut()` in the three facades -- the borrow split is the one real design constraint here.
- `crates/zanshin-ffi/src/{envelope.rs,repo.rs}` -- register `jj.immutable` and map the new variant, with the matching inline mapper unit test -- an unmapped variant would not compile, and an untested arm would drop `repo.rs` coverage.
- `docs/rust-error-codes.md` -- add the `jj.immutable` row -- mandatory for any new code.
- `crates/zanshin-jj/src/op_support.rs` (inline `#[cfg(test)]`) and `crates/zanshin-jj/tests/op_support.rs` -- cover the I/O matrix; inline for the three `pub(crate)`-only helpers, integration for the guard via the public verbs.

**Acceptance Criteria:**
- Given the workspace after this change, when `cargo make test` runs, then it passes end to end with no baseline lowered and no `exclude_prefix` added, and `crates/zanshin-jj/src/op_support.rs` reports ≥ 80.00 % line coverage.
- Given a fixture repo with a tag placed on a non-root commit, when `Repo::describe`, `Repo::edit`, or `Repo::abandon` targets that commit, then the call returns `MutateError::Immutable` naming it, and `jj op log` shows no new operation.
- Given the same repo, when those verbs target a commit outside the immutable set, then they succeed exactly as before this story.
- Given a repo whose config overrides `revset-aliases."immutable_heads()"`, when the guard runs, then the override decides the immutable set (the builtin is replaced, not merged) — proving the guard reads the effective config rather than a Rust constant.
- Given `zanshin-jj`'s public API, when compared against the pre-change surface, then `MutateError` is the only public item that changed, no `jj_lib` type appears in any public position, and every variant it gained is pinned in `tests/api_stability.rs` (that file's job is to break on surface drift, so it is EXTENDED, not left untouched — corrected during review, see the Triage Log).
- Given no `extern "C"` **signature** changed, when the FFI surface is checked, then the ABI is unchanged. Regeneration is still required whenever a wrapper's doc comment changes, because cbindgen/ffigen lift those comments into `zanshin_ffi.h` and `bindings.dart` — so this story runs `cargo make codegen` and commits both generated files (corrected during review; the original wording conflated ABI stability with generated-file staleness).
- Given `docs/rust-error-codes.md`, when it is read, then `jj.immutable` is registered with its emission site, and the entry for `jj.invalid_input` still describes the root-commit refusal it continues to serve.

## Spec Change Log

## Review Triage Log

### 2026-09-02 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 9: (high 0, medium 4, low 5)
- defer: 4: (high 0, medium 0, low 4)
- reject: 7: (high 0, medium 2, low 5)
- addressed_findings:
  - `[medium]` `[patch]` The shipped FFI contract was stale and, for `zanshin_edit`, factually wrong: it still said `jj.jj_lib_error` "includes attempting to edit the root commit", which this very change had moved to `jj.immutable`, contradicting the row added to `docs/rust-error-codes.md`. None of the three verbs' `# Errors` lists mentioned the new codes. Corrected at the source, then `cargo make codegen` was run and `zanshin_ffi.h` + `bindings.dart` committed, plus the Dart worker's own code lists in `handle.dart` and `isolate.dart`. This supersedes AC #6's literal wording, which had conflated "no `extern "C"` signature changed" with "no regeneration needed" — the ABI is indeed unchanged, but cbindgen/ffigen lift doc comments, so the generated contract the GUI reads was drifting. Triaged `patch` rather than `bad_spec` deliberately: re-deriving from an amended spec would reproduce byte-identical `op_support.rs`/`mutate.rs`/`repo.rs`, so the loopback's entire yield would have been these comment edits.
  - `[medium]` `[patch]` A config fault reported the wrong code. The guard made `describe`/`edit`/`abandon` read the repo's jj config for the first time, and a malformed config or an unparseable/unresolvable `immutable_heads()` alias funnelled into `MutateError::Backend` → `jj.jj_lib_error` ("unclassified"). The repo already registers `jj.config_error` for exactly this fault (Story 4.9) and the CLI classifies it the same way (`cli_util.rs:1139`). Added `MutateError::Config`, routed the config/parse/resolve failures through it, mapped it to the EXISTING `JJ_CONFIG_ERROR` constant, extended that code's registry row with the new emission site, and pinned it at three levels (crate, envelope, mapper).
  - `[medium]` `[patch]` The one shipped error code this story knowingly changed — `edit(root)` moving from `jj.jj_lib_error` to `jj.immutable` — was asserted in three doc sites and observed by no test. Added `edit_root_commit_returns_immutable`.
  - `[medium]` `[patch]` `jj.immutable` never crossed the FFI boundary in a test; its only coverage was the in-module mapper unit test, while every other mutation code is pinned end-to-end in `repo_write_ffi.rs`. Added envelope-level rows for both new codes, asserting `ok = false`, the code, the hex commit id in `context`, and that a refused `describe` really did not write.
  - `[low]` `[patch]` `tests/api_stability.rs` pins each public `MutateError` variant with a per-story comment; the two new variants were absent, so the pin test could not catch a later rename. Added both.
  - `[low]` `[patch]` `apply_trailers` takes caller-built `Trailer`s and an arbitrary `&str` where the CLI's inputs are always normalized. Documented the three resulting preconditions (newline-terminated description, no embedded newlines in key/value, no intra-list dedup) rather than adding validation, which would diverge from the verbatim port NFR-R-2 pins.
  - `[low]` `[patch]` `compute_commit_location` takes raw slices where the CLI gets an `IndexSet` of existing commits from `resolve_revsets_ordered`. Documented the input contract (resolved, existing, deduplicated; absence is `None`, never `Some(&[])`).
  - `[low]` `[patch]` `abandon_names_the_first_immutable_target_even_when_several_are` pinned `Commit 3` on the basis of reverse-topological stream order, which jj-lib does not promise — an upstream index change would have turned it red with no behaviour regression. Relaxed to assert membership in the immutable target set plus exactly-one-offender, and renamed accordingly.
  - `[low]` `[patch]` `abandon` rebound its `immutable` parameter (`&Arc<UserRevsetExpression>`) to the resolved set under the same name, ~30 lines from the `rebase_descendants_with_options` call where the base-repo-vs-mutable-repo distinction matters; renamed to `resolved_immutable`. Two new `InvalidInput` messages reused the CLI's internal *panic* text and leaked Rust parameter names to a GUI; reworded to name the user-facing flags, leaving the CLI's genuinely user-facing strings verbatim.

## Design Notes

**Immutability is ancestor-closed, and that changes what the wiring is for.** The set is `::(immutable_heads() | root())` — closed under ancestors by construction. So if a target is *mutable*, none of its descendants can be immutable (an immutable descendant would drag the target into the set). Consequence: once `check_rewritable` passes on the targets, swapping `RevsetExpression::none()` for the real set at `mutate.rs:384` cannot change the outcome of that rebase. The substantive fix for the 9.0a gap is therefore the **target guard**, not the rebase argument; the rebase argument is still changed for CLI parity and because the CLI's own comment names a case the algebra does not cover (`jj git fetch` updating immutable commits between base and tip — which is why `rebase_mutable_descendants` resolves against `tx.base_repo()`, not `tx.repo()`; mirror that).

**Guard placement: after the root check, not before.** The CLI checks rewritability before `start_transaction()` and reports root as *immutable*. We keep our existing explicit root guards first. Two reasons: they exist to pre-empt jj-lib's internal `assert!` (a process crash, not an error), and moving the guard ahead of them would make those lines unreachable — dropping `mutate.rs` below its 96.04 % baseline while also changing a shipped error code. Net effect: root still refuses via `jj.invalid_input`, non-root immutable commits refuse via `jj.immutable`. Both refuse, neither writes an op-log entry, so observable behavior matches the CLI; only the code differs for root. Record that as a deferred nit rather than "fixing" it here.

**Running the guard inside the transaction is equivalent.** The CLI runs it against the read-only repo before opening a transaction; our mutations already hold a transaction when they resolve targets. Evaluating against `tx.repo()` *before any mutation* sees identical content, and dropping the transaction on refusal writes nothing. This keeps the change surgical instead of restructuring `resolve_commit`.

**`try_combine_messages` returning `None` is a feature, not a gap.** The CLI's fallback for the ambiguous case is `combine_messages_for_editing` — a `JJ: `-commented `$EDITOR` buffer. That is exactly the terminal UX ADR-0003 replaces. Return `None` and let the caller (ultimately the GUI) decide; "the backend classifies and offers, the UI decides."

**Trailer blank-line rule (port verbatim, `description_util.rs:396-416`):** insert the paragraph break *only* when the existing description has no trailer block and the new trailer list is non-empty; dedup by full `Trailer` equality against `parse_description_trailers` of the existing description. Note the two jj-lib parsers differ on purpose — `parse_description_trailers` is lenient over a whole message, `parse_trailers` is strict over a trailer-only paragraph.

**`compute_commit_location`'s `-B` parent computation must preserve order.** The CLI deliberately avoids `RevsetExpression::parents` and instead unions `parent_ids()` with a dedup, "to persist the order of parents specified in `before_commits`". Reproduce that; do not substitute the revset form.

## Verification

**Commands:**
- `cargo make test` -- expected: green end to end (tests + clippy `-D warnings` + rustfmt + `cargo deny` + coverage ratchet). This is the single gate; run it unpiped and capture the exit code.
- `git -C ../jj show v0.44.0:cli/src/cli_util.rs` -- expected: the prior art the port is checked against; confirm line anchors before trusting them.
- `git status --porcelain` -- expected: after the run, only intended files; `coverage-baseline.txt` appears only if the ratchet raised it.

**Manual checks (if no CLI):**
- Diff the crate's `pub` items: confirm `MutateError` is the only public item that changed and that no `jj_lib` type leaked into a public signature.

## Auto Run Result

Status: done
Commits: `1dd962c32585057c248f01acdf87451c02cba1d6` (the layer + guard wiring) and
`66057e708a3d203e034b4de074dfc8e059c740f2` (review patches), both on `main`, baseline
`a35f15846761e4ca430876102ee5671dba79f5a8`.

**Summary.** `crates/zanshin-jj/src/op_support.rs` re-ports, at jj-cli `v0.44.0` parity, the four
pieces of rewrite orchestration that live in `cli_util` and are absent from jj-lib: the
immutable-heads rewritability guard, insert-location resolution for `-A`/`-B`/`--onto`, description
combination with trailers, and the selected-tree seam that replaces the interactive `DiffSelector`.
The whole module is `pub(crate)` — no `jj_lib` type may sit in a public position (FR-JJ-16) — so
`lib.rs` gains a module declaration and no re-export.

Section 1 is wired into `describe`/`edit`/`abandon`, closing the CLI-parity gap Story 9.0a deferred
here: those verbs rewrote immutable commits where jj refuses. Sections 2-4 ship tested-but-unwired
behind a documented `#[allow(dead_code)]`; their consumers are Tier C verbs by the epic's own
sequencing, which is why this story "blocks Tier C".

Two design findings are worth carrying forward. First, the immutable set is
`::(immutable_heads() | root())` and therefore **ancestor-closed**: a target that passes
`check_rewritable` provably has no immutable descendants. So the substantive fix for the 9.0a gap is
the target guard, not the `rebase_descendants_with_options` argument — the latter was still changed
on `abandon` for CLI parity and for the `jj git fetch` case the CLI's own comment names (hence
resolving against `tx.base_repo()`). Second, `try_combine_messages` returning `None` on ambiguity is
deliberate: the CLI's fallback is a `JJ: `-commented `$EDITOR` buffer, exactly the terminal UX
ADR-0003 replaces, so the backend classifies and the UI decides.

**Files changed.**
- `crates/zanshin-jj/src/op_support.rs` — the layer, inline tests included.
- `crates/zanshin-jj/src/mutate.rs` — `MutateError::{Immutable, Config}`, the `cfg()` classifier, the
  guard threaded into the three rewriting verbs, and `abandon`'s `RevsetExpression::none()`
  placeholder replaced with the resolved immutable set.
- `crates/zanshin-jj/src/repo.rs` — the three facades build the expression from `&self` before
  `workspace_mut()`; that borrow split was the story's one real design constraint.
- `crates/zanshin-jj/src/revset.rs` — `resolve_expression` extracted from `evaluate_revset`, so the
  guard reaches the *resolved* expression without duplicating symbol resolution.
- `crates/zanshin-ffi/src/{envelope.rs,repo.rs}` — the `jj.immutable` constant, both new mapper arms,
  their unit tests, and the corrected/extended `# Errors` contracts.
- `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart` —
  regenerated via `cargo make codegen`.
- `packages/zanshin_core/lib/src/worker/{handle,isolate}.dart` — the Dart-facing code lists.
- `docs/rust-error-codes.md` — the `jj.immutable` row; `jj.config_error` gained its new emission site.
- Tests: `crates/zanshin-jj/tests/op_support.rs` (13 integration rows), 26 inline rows in
  `op_support.rs`, 2 new envelope rows in `crates/zanshin-ffi/tests/repo_write_ffi.rs`, and the new
  variants pinned in `tests/api_stability.rs`.

**Review findings.** 9 patched (0 high, 4 medium, 5 low), 4 deferred (all low — see frontmatter),
7 rejected. No `intent_gap` and no `bad_spec`: the implementation matched the spec and every patch
was additive. Two patches deliberately superseded the literal wording of ACs #5 and #6, both of
which had read a test's and a generator's purpose backwards; the ACs were corrected in place rather
than looped back, because re-derivation would have reproduced byte-identical code.

**Follow-up review recommended:** true. Patched this pass: high 0, medium 4, low 5 →
score `3×4 + 1×5 = 17`, at or above the threshold of 5. Note for whoever acts on it: the remaining
yield is likely documentation and test-shape polish rather than defects — the guard's behaviour is
pinned at three levels (crate, envelope, mapper), and the ancestor-closure argument above bounds
what the remaining `none()` call sites can affect.

**Verification performed.** `cargo make test` run to completion unpiped with the exit code captured,
green on the final state: `GATE_EXIT=0`, `Build Done in 287.92 seconds`. It covers
`cargo test --workspace`, clippy pedantic `-D warnings`, rustfmt, `flutter test` +
`dart analyze`/`format`, `cargo deny` (`advisories ok, bans ok`), and the coverage ratchet:
`coverage-check: OK — coverage held at 99.06% (5480/5532 lines)` — held, so `coverage-baseline.txt`
was neither raised nor lowered and is in neither commit. Two earlier gate runs were red and were
fixed rather than worked around: two inline assertions still matched the pre-rewording refusal text,
and one rustfmt violation. Every new test was confirmed present in the run output rather than
assumed, and the I/O matrix was audited row by row against tests that actually executed.

**Process note.** The review patches were first delegated back to the implementation subagent, which
then ran concurrently with this session and clobbered several files (duplicate helpers and two
duplicated test pairs). Ownership was reclaimed, the duplicates were collapsed, and the final state
was re-verified from scratch. The lesson for future runs: re-engaging a subagent asynchronously in a
loop that cannot block on its result is unsafe — apply the patches directly instead.

**Residual risks.**
- `edit(root)` changed its shipped error code from `jj.jj_lib_error` to `jj.immutable`. Closer to the
  CLI, now tested, and recorded in the registry — but a user-visible change beyond the spec's
  literal wording.
- Sections 2-4 have no production caller, so their contracts are pinned only by their own tests. The
  documented preconditions on `apply_trailers` and `compute_commit_location` are prose, not
  enforcement — deliberately, since validation would diverge from the verbatim port.
- `templates.commit_trailers` rendering is NOT implemented (it needs jj's template engine), so a user
  who configures it is silently ignored. The key was deliberately kept out of `BUILTIN_CONFIG_TOML`
  so the builtin layer does not advertise a default this crate does not honour.
- The interactive half of the selected-tree seam cannot be validated from this repo — it needs the
  Flutter diff editor to supply a tree id. Only the apply half is tested, as the epic anticipated.
