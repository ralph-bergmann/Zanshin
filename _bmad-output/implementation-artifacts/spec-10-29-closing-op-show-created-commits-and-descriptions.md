---
title: 'Story 10.29 closing run — op view: created commits without copy records, description diffs'
type: 'bugfix'
created: '2026-11-02'
status: 'done'
baseline_revision: 'cedb5dbca285ff27d2baf801004e9a929bc5e02f'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      RepoHandle.interdiff (zanshin_interdiff, the evolog -p / jj interdiff paths view of Story 9.6) carries no JJ-COMMIT-DESCRIPTION block.
    evidence: |-
      jj evolog -p and jj interdiff print the block through show_inter_diff (cli/src/diff_util.rs @ v0.46.0); InterdiffView returns changed paths only. Pre-existing; diff(interdiff: true) now has the block, the paths-only verb does not.
    location: >-
      packages/zanshin_core/lib/src/worker/handle.dart RepoHandle.interdiff; crates/zanshin-jj Repo::interdiff
    severity: low
---

<intent-contract>

## Intent

**Problem:** The operation view (Story 10.29) diverges from `jj op show --patch` in two deferred items: (1) a created commit (no predecessors) is read with `diff(revision:)`, which adds parent→commit copy records, where the CLI's `show_change_diff` → `show_inter_diff(&[], commit)` uses `CopyRecords::default()` (a rename shows as rename, the CLI shows delete + add); (2) `show_inter_diff` prints a `JJ-COMMIT-DESCRIPTION` diff block (from-description → to-description) before the files, which the view never shows — a body-only describe shows identical `+`/`−` lines and "No file changes". Both decided by Ralph 2026-10-23: behave like the CLI.

**Approach:** Backend: `show_inter_diff` becomes complete in `Repo::diff`'s inter-diff forms — (a) a new `DiffRevisions::Created(String)` (wire: `DiffRequest.interdiff` together with `revision`, formerly refused) = `show_inter_diff` with no predecessors: the commit's parent tree against its tree, no copy records, description `""` → its description; (b) both inter-diff forms (`Interdiff`, `Created`) fill a new `RevisionDiff.description: Option<FileDiff>` (wire: `Diff.description`, appended) — the description diff as a pseudo-file `JJ-COMMIT-DESCRIPTION`, `None` when the descriptions are equal (`show_diff_bytes` skips unchanged contents). UI: `_diffOf` reads created commits through `diff(revision:, interdiff: true)`; the model keeps the summary read's `description` and the view renders it above the files in 10.24's `InspectorDiffView` (path `JJ-COMMIT-DESCRIPTION`).

## Boundaries & Constraints

**Always:**
- Description diff as the CLI's: from = first predecessor's description (`predecessors.get(..1)`; `Interdiff`'s `from`), `""` for `Created`; to = the commit's; ignores `paths` (the matcher never applies to it); hunks computed with the call's `context` / `whitespace` by the same `hunks_of`, no language, no sections; `kind` Modified; it keeps its hunks in `summary` reads (it is not a file; documented). `FromTo` / `Revision` set `description: None` (`jj diff` has no such block).
- `Created`: `revision` must resolve to exactly one commit (`resolve_single_rev`, hidden commit ids resolve); `commit_ids [it]`, `from_commit_id None`; unmatched-paths warning over its parent tree and tree.
- Wire: `revision` + `interdiff` = `Created`; `revision` + `from`/`to` (with or without `interdiff`) stays refused "revision cannot be used with from or to"; `interdiff` with none of the three stays refused (interdiff's wording). `cargo make codegen`, generated files committed; `docs/ffi-abi.md` updated.
- Abandoned commits keep `diff(revision:)` (the CLI's `show_patch`, with copy records, no description block).
- The view shows the description block whenever `description != null`, also when the commit has no file changes (then above the "No file changes" note).

**Never:** a description editor in the view; changing `jj interdiff`'s (`Interdiff`) tree semantics; a new FFI verb.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Created with rename | op created C renaming a→b | `diff(revision: C, interdiff: true)`; files: a Removed + b Added (no Renamed); description block `+` its lines | — |
| Body-only describe | X rewritten from P, same tree, body edited | files empty; description block shows the changed body line(s) | — |
| Same description | rewrite without describe | `description == null`, no block | — |
| Created, empty description | new commit, no description | `description == null` | — |
| Created, bad revision | revision resolves to 0 / >1 commits | `jj.revset_resolution_error` | in place, as today |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/hunks.rs:149-199` -- `DiffRevisions` (add `Created(String)`), `RevisionDiff` (add `description`); `diff` at :261-370 (new arm next to `Interdiff` at :337; `texts` match at :279; description built after `files`); `hunks_of` :605, `totals` :554, `fingerprint` :563 to reuse for the description `FileDiff`. Unit tests in `mod tests` :706.
- CLI reference: `git -C ../jj show v0.46.0:cli/src/diff_util.rs` `show_inter_diff` (description merge, `DUMMY_DESCRIPTION_PATH`, `CopyRecords::default()`), `show_diff_bytes` (skip unchanged); `cli/src/commands/operation/diff.rs` `show_change_diff`; `cli/src/commands/interdiff.rs` (interdiff prints the block too).
- `crates/zanshin-jj/src/repo.rs:~4421-4465` -- `Repo::diff` doc: name `Created` and `description`.
- `crates/zanshin-jj/tests/it/diff.rs` -- interdiff cases (add Created + description cases); `tests/it/api_stability.rs:1843` -- `RevisionDiff` literal gains `description`.
- `schemas/envelope.fbs:380` `DiffRequest` doc, `:3188` `table Diff` -- append `description: FileDiff;`.
- `crates/zanshin-ffi/src/diff.rs:40-64` `read_diff_request` (revision+interdiff → Created), `:151` `diff_to_envelope` (write description), unit tests `:250+` (`diff_from_wire`, literals); `crates/zanshin-ffi/tests/it/diff_ffi.rs:118` `assert_wire_is`.
- `docs/ffi-abi.md` -- `zanshin_diff` section.
- `packages/zanshin_core/lib/src/ffi/diff.dart:168` `Diff` (+`description`), its decoder and `:200-241` request doc; `lib/src/worker/handle.dart:1648`, `commands.dart:2334-2363` docs; `test/worker/diff_test.dart` -- cdylib witness (created commit + description).
- `app/lib/src/features/undo_timeline/operation_changes.dart:255-267` `_diffOf` (created → `revision:` + `interdiff: true`), model `_files` holds `description`; `_Files` :647 renders it above the file rows.
- `app/test/features/undo_timeline/operation_changes_test.dart`, `app/test/helpers/fake_undo_timeline.dart` -- created-commit request expectation, description block tests.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/hunks.rs`, `repo.rs` -- `Created` arm + `description` (both inter-diff arms) -- items 1 and 2.
- `crates/zanshin-jj/tests/it/diff.rs`, `api_stability.rs` -- Created: rename → Removed+Added, parent-tree diff, commit_ids; description: body edit, equal → None, created empty → None, created with text → added lines, ignores paths, kept in summary; FromTo/Revision → None.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/diff.rs`, `tests/it/diff_ffi.rs`, `docs/ffi-abi.md` -- wire + mapping + tests; `cargo make codegen`, commit output.
- `packages/zanshin_core` Dart -- `Diff.description` decode + docs + witness test.
- `operation_changes.dart` + tests -- created read, description block.

**Acceptance Criteria:**
- Given a created commit in the operation view, when it is selected, then the source saw `diff(revision: <id>, interdiff: true, …)` and no `from`/`to`.
- Given a rewritten or created commit whose description changed, when selected, then a `JJ-COMMIT-DESCRIPTION` diff block renders above its files (also with no file changes); with equal descriptions, none renders.

## Spec Change Log

## Review Triage Log

### 2026-11-02 — Review pass
- verdicts: 16 findings — high 0, medium 0, low 13, false 3, maybe-false 0
- findings:
  - `[low]` `[patch]` (verification-gap) the description block's use of the call's `context` is untested — added a `context: Some(0)` run in `an_interdiff_shows_a_changed_description` (only the Added lines remain).
  - `[false]` `[reject]` (edge) a whitespace-only description change under `-w` gives a block with no hunks — the CLI does the same: `show_diff_bytes` skips only exact-equal contents, then prints the git header with whatever hunks remain; files behave alike.
  - `[low]` `[reject]` (edge) the view then renders an empty diff block — same outcome as a file with no hunks under `-w`, matches the CLI's bare header; rare.
  - `[low]` `[reject]` (intent) `summaryOf` is unchanged, a body-only describe still shows identical `+`/`−` first lines — the ledger and Ralph's decision ask for the description diff above the files, which is shown; the summary lines are `commit_summary`'s first line as in the CLI.
  - `[low]` `[reject]` (intent) no app-level test shows a rename split into two rows — the app reads through a fake source (call shape pinned); the split itself is a backend property, tested in zanshin-jj.
  - `[low]` `[reject]` (intent) created commits now also get a description block — that is `show_inter_diff(&[], commit)`, CLI parity by design.
  - `[low]` `[reject]` (blind/intent) summary reads keep the description hunks where the CLI's summary formats print none — a spec'd GUI data shape (the view's file list comes from the summary read), documented in rustdoc, envelope.fbs and ffi-abi.md; summary formats are terminal rendering.
  - `[low]` `[defer]` (blind) `RepoHandle.interdiff` (evolog -p / jj interdiff paths view) has no description block — pre-existing, outside the two items; mirrored into deferred-work.md.
  - `[low]` `[reject]` (blind) the block is recomputed on per-file reads and discarded — one small in-memory text diff per read, negligible.
  - `[low]` `[reject]` (blind) `assert_wire_is` checks only the description's hunk count — the block goes through the same `file_offset` as every file, whose fields the round-trip tests check fully.
  - `[low]` `[reject]` (blind) `Created`'s multi-commit and hidden-id resolution untested — the same `resolve` closure (`single_commit`) as `Interdiff` / `FromTo`, tested there.
  - `[low]` `[reject]` (blind) no merge/root-commit `Created` test — `rebase_to_dest_parent(&[], c)` is `MergedTree::merge` of `c.parent_tree` with no diffs, i.e. the parent tree; root's parent tree is empty; no added branch.
  - `[low]` `[patch]` (blind) the abandoned test does not pin `interdiff: false` — now asserts every call is `revision: A`, `interdiff == false`, no from/to.
  - `[low]` `[reject]` (blind) no widget test for a rewritten commit with a changed description and files — the block placement is one branch (`?description` above the file rows), covered by the created-commit test.
  - `[false]` `[reject]` (blind) generated files missing from the reviewed diff — excluded from the review diff on purpose; `cargo make codegen` re-run left the tree unchanged.
  - `[false]` `[reject]` (blind) the raw `JJ-COMMIT-DESCRIPTION` label reads like a file — it is the CLI's own pseudo-file path, kept as jj's words.

## Design Notes

`revision` + `interdiff` was refused only because `jj interdiff` has no `-r`; reusing it for "inter-diff with no predecessors" adds no wire field and reads naturally (one commit, nothing to diff from). The description travels as a `FileDiff` so 10.24's hunk view renders it unchanged — the CLI too prints it as a pseudo-file.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it diff::` and `api_stability::`; `cargo test -p zanshin-jj --lib hunks` -- pass
- `cargo test -p zanshin-ffi diff` -- pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`; `cargo fmt --all --check` -- clean
- `cargo make codegen` -- generated files committed
- `cargo test -p zanshin-parity --test oracle -- diff` -- pass (no verb's CLI behavior changed beyond the new form)
- `packages/zanshin_core`: `dart test test/worker/diff_test.dart`, `dart analyze --fatal-infos`, `dart format --set-exit-if-changed .` -- pass
- `app`: `flutter test test/features/undo_timeline`, `dart analyze --fatal-infos`, `dart format --set-exit-if-changed lib test widgetbook` -- pass

**Verification notes (2026-11-02, targeted checks only — gate rule of the story loop):**
- `cargo test -p zanshin-jj --test it -- diff:: api_stability::` — 83 passed (after the review patches); `cargo test -p zanshin-jj --lib hunks` — 10 passed.
- `cargo test -p zanshin-ffi diff` — 10 + 16 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean.
- `cargo make codegen` — re-run, no further change; generated envelopes, header and bindings committed.
- `cargo test -p zanshin-parity --test oracle -- diff` — 11 passed.
- packages/zanshin_core: `dart test test/worker/diff_test.dart` 12 passed; analyze + format clean.
- app: `flutter test test/features/undo_timeline` 46 passed (after the patches); analyze + format clean.
- Not run (gate rule): full gate, coverage. Not done: Marionette visual check.

## Auto Run Result

Status: done

**Summary.** The operation view now matches `jj op show --patch`'s `show_change_diff` for both deferred items. A created commit reads `diff(revision:, interdiff: true)` — new `DiffRevisions::Created` (`show_inter_diff` with no predecessors: parent tree against tree, no copy records), wire `DiffRequest.revision` + `interdiff` (formerly refused). Both inter-diff forms return the CLI's `JJ-COMMIT-DESCRIPTION` block as `RevisionDiff.description` / `Diff.description` (first predecessor's or `""` against the commit's description; absent when equal); the view renders it in 10.24's `InspectorDiffView` above the files (also above "No file changes"). Abandoned commits keep `diff(revision:)` (`show_patch`).

**Files changed.**
- `crates/zanshin-jj/src/hunks.rs`, `repo.rs` — `Created` arm, `description` field and its builder, `range_trees` helper (clippy length).
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/diff.rs`, generated envelopes / header / bindings, `docs/ffi-abi.md` — wire mapping and field.
- `packages/zanshin_core/lib/src/ffi/diff.dart`, `worker/handle.dart`, `worker/commands.dart` — `Diff.description` decode + docs.
- `app/lib/src/features/undo_timeline/operation_changes.dart` — `_diffOf` routing, description block.
- tests: `crates/zanshin-jj/tests/it/{diff,api_stability}.rs`, `crates/zanshin-ffi/tests/it/diff_ffi.rs`, `packages/zanshin_core/test/worker/diff_test.dart`, `app/test/features/undo_timeline/operation_changes_test.dart`, `app/test/helpers/fake_undo_timeline.dart`.

**Review.** 16 findings: 2 patched (low: description context test, abandoned `interdiff: false` pin), 1 deferred (low, pre-existing: `RepoHandle.interdiff` has no description block — mirrored into deferred-work.md), 13 rejected with reasons in the triage log. Follow-up review: false (patched 0 high, 0 medium, 2 low).

**Items.**
1. Created commit carries copy records — fixed (commit cc7256839d2348faedbbf916ce3c3df151818203).
2. Description changes beyond the first line not shown — fixed (commit cc7256839d2348faedbbf916ce3c3df151818203).

**Residual risks.** `DiffReader::description` / `range_trees` are covered by integration tests only — watch the coverage ratchet at the loop's final gate; no running-app (Marionette) check of the description block.
