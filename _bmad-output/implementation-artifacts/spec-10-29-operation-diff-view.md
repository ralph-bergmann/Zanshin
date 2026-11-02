---
title: 'Story 10.29 — Operation diff view: Show changes in the Undo Timeline'
type: 'feature'
created: '2026-11-02'
status: 'done'
baseline_revision: '5f8b409fff7a7d2c88c7d9e822ba600d5bc5567e'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      A created commit's diff in the operation view carries copy records, where jj op show --patch shows none.
    evidence: |-
      show_change_diff sends a created commit through show_inter_diff with no predecessors and CopyRecords::default() (cli/src/diff_util.rs:628 @ v0.46.0); the view reads diff(revision:), which adds parent->commit copy records, so a rename shows as a rename instead of delete + add. Needs a backend inter-diff with no predecessors.
    location: >-
      app/lib/src/features/undo_timeline/operation_changes.dart _diffOf
    severity: low
  - summary: >-
      Description changes beyond the first line are not shown in the operation view.
    evidence: |-
      jj op show --patch prints a JJ-COMMIT-DESCRIPTION diff block per rewritten commit (show_inter_diff); the view shows only the first description line in the + / − summaries, so a describe that edits the body shows identical lines and "No file changes".
    location: >-
      app/lib/src/features/undo_timeline/operation_changes.dart summaryOf
    severity: low
  - summary: >-
      A large operation may render slowly in the operation view.
    evidence: |-
      Unmeasured. The view is a non-lazy ListView rebuilt on every notify, and the summaries come from one show read that also computes fileChanges for every referenced commit; a big rebase can list hundreds of commits under the default revsets.op-diff-changes-in. Settle by timing Show changes on a large rebase operation.
    location: >-
      app/lib/src/features/undo_timeline/operation_changes.dart _readSummaries, OperationChangesView.build
    severity: medium (unverified)
  - summary: >-
      The operation view has not been compared in the running catalogue.
    evidence: |-
      Unattended run: widget tests only, no Marionette check; the DS has no card for it. The Widgetbook use case "Show changes" is ready for the check.
    location: >-
      app/widgetbook/folders/undo_timeline.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** 11.9's Undo Timeline shows "Show changes" (`jj op show <id>`) disabled ("Not available yet"): no view renders `RepoHandle.opShow` (deferred-work I1). And `jj op show --patch`'s per-commit diff of a rewritten commit is an INTER-diff (the first predecessor rebased onto the new commit's parents, `show_change_diff` → `show_inter_diff`, `cli/src/commands/operation/diff.rs:845` @ v0.46.0) — the bridge's only hunked diff (`RepoHandle.diff`) has no such form, and `RepoHandle.interdiff` returns paths without hunks.

**Approach:** Backend: `RepoHandle.diff` gains `interdiff: true` — the `--from` / `--to` form read as `jj interdiff` does (from rebased onto to's parents in memory, no copy records), with hunks. UI: Show changes is enabled on every row (the newest too); it swaps the pinned panel's list for an operation-changes view that reads `opShow` once and lists what `jj op show` lists — changed commits (`+` new / `−` predecessors or abandoned), the elided count, changed working copies, local bookmarks and tags, remote bookmarks and tags — with the selected commit's files and focused-file diff in 10.24's components (no Viewed). Esc or Back returns to the list.

## Boundaries & Constraints

**Always:**
- Per commit, the diff is the CLI's: created (no predecessors) or abandoned → `diff(revision: <commit id>)`; rewritten → `diff(from: <first predecessor>, to: <commit id>, interdiff: true)`. Full commit ids (hidden ones resolve).
- Exactly one `opShow(operation: <12-hex id>)` per open; `showChangesIn` null (the effective `revsets.op-diff-changes-in`).
- Any refusal (opShow, a commit's summary or file diff) shows jj's text (`context ?? code`) in place; `OpShow.diff == null` (merge operation) and `OpDiff.commits == null` (warnings shown verbatim) are explained in place.
- Commit summaries: change id (8) · commit id (8) · first description line or jj's `(no description set)`, from one `show` read of every referenced commit; a refused read falls back to the commit id alone. Section headings and markers are jj's own words (l10n-ignore); Zanshin's strings via the ARB.
- Unified / Side by side is `general.diffLayout` (10.24's shared preference), written and followed.
- Backend: `interdiff` with `revision` is `jj.invalid_input` before the snapshot; with neither `from` nor `to` it is refused "at least one of `from` or `to` is required" (interdiff's wording).

**Never:** Restoring single commits from the view; an operation-to-operation picker; Viewed marks; composing jj commands; a description pseudo-file diff (the CLI's `JJ-COMMIT-DESCRIPTION` block — the `+`/`−` summaries carry the description).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Rewrite | op rewrote X (pred P) | rows `+ X…`, `− P…`; X selected; files of `diff(from:P,to:X,interdiff)` summary; first file's hunks | — |
| Abandon | op abandoned A | row `− A…`; files of `diff(revision:A)` | — |
| Merge op | `OpShow.diff == null` | note "This operation merges several operations; jj shows no changes for it." | — |
| Unresolved changes-in | `commits == null` | the warnings' messages verbatim; ref sections still shown | — |
| opShow refused | `ZanshinFfiException` | its `context ?? code` in place of the view body | logged |
| Commit diff refused | e.g. `jj.jj_lib_error` | text in place of the files / diff block | logged |
| Esc / Back | view open | list returns, focus back in the panel | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/hunks.rs:133-173,250-341` -- `DiffOptions` / `DiffRevisions` / `diff`: add `Interdiff { from, to }` arm; `rebase_to_dest_parent(repo, [from], &to)` like `commit_views.rs:671`; empty `CopyRecords`; `commit_ids [to]`, `from_commit_id Some(from)`.
- `crates/zanshin-jj/src/repo.rs:4421-4461` -- `Repo::diff` doc: name the new arm.
- `crates/zanshin-jj/tests/it/diff.rs` -- integration tests of `Repo::diff` (add interdiff cases).
- `schemas/envelope.fbs:376` -- `DiffRequest`: add `interdiff: bool` (last field); `cargo make codegen`.
- `crates/zanshin-ffi/src/diff.rs:40-64` -- `read_diff_request`: map `interdiff`; unit tests ~:560-630.
- `packages/zanshin_core/lib/src/worker/{handle,commands,isolate}.dart`, `lib/src/ffi/diff.dart` (request builder) -- thread `interdiff` through `RepoHandle.diff`; `test/worker/diff_test.dart` or `test/ffi/diff_test.dart` -- a cdylib witness.
- `app/lib/src/features/undo_timeline/undo_timeline_view.dart:324-401` -- `_buttons`: Show changes enabled on every row; `UndoTimelinePanel` -> stateful, holds the open view.
- `app/lib/src/features/undo_timeline/operation_changes.dart` (new) -- `OperationChangesSource` port + `RepoOperationChangesSource`, `OperationChangesModel`, `OperationChangesView`.
- `app/lib/src/features/graph/inspector_diff.dart:69-224` -- `InspectorDiffView`: `onViewedChanged` nullable → no Viewed toggle.
- `app/lib/src/features/graph/graph_inspector.dart:1818-1920` -- `_FileRow` → public `InspectorFileRow` (reuse).
- `app/lib/src/features/home/home_page.dart:92-98,216-278` -- `_UndoTimelineHost` passes the source and `vm.settings`.
- `app/lib/l10n/app_en.arb:954-990` -- drop `undoTimelineShowLater`, add the view's strings; `flutter gen-l10n`.
- `app/widgetbook/folders/undo_timeline.dart` -- demo source + a use case for the open view.
- `app/test/features/undo_timeline/` -- view/model tests; `app/test/helpers/fake_undo_timeline.dart` -- fake changes source.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/hunks.rs`, `repo.rs`, `tests/it/diff.rs` -- Interdiff arm + tests (rebased commit: interdiff shows only its own change; equals `interdiff`'s paths; both-absent refusal).
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/diff.rs` -- wire field + mapping + unit tests; run codegen, commit generated files.
- zanshin_core Dart files -- `interdiff` parameter + test.
- `inspector_diff.dart`, `graph_inspector.dart` -- optional Viewed; public file row.
- `operation_changes.dart` -- port, model (one opShow; summaries; selection; focus; layout), view (header with Back + `jj op show <id>`, sections, files, diff, Esc).
- `undo_timeline_view.dart`, `home_page.dart`, ARB + gen-l10n, widgetbook -- wiring.
- tests -- model + widget tests for the matrix rows and the ACs.

**Acceptance Criteria:**
- Given a row, when Show changes is pressed, then the panel shows the operation's view and the source saw exactly one `opShow` for that 12-hex id.
- Given a rewritten commit, when it is selected, then its files come from an interdiff read and its focused file renders through `InspectorDiffView`/`InspectorDiffHunk` in the shared layout, with no Viewed control.
- Given the view, when Esc is pressed or Back activated, then the operation list shows again.
- Given a refusal, then jj's text shows where the content would be.

## Spec Change Log

## Review Triage Log

### 2026-11-02 — Review pass
- verdicts: 30 findings — high 0, medium 2, low 19, false 5, maybe-false 4
- findings:
  - `[medium]` `[patch]` (verification-gap) a created commit's diff path is untested — added a created-commit test (revision read, interdiff false, only a `+` line).
  - `[low]` `[patch]` (verification-gap) interdiff's parent-tree unmatched-paths check untested — added Rust cases (path only in `to`'s parent: no warning; path nowhere: warns).
  - `[low]` `[patch]` (verification-gap) panel reset on a repository switch untested — added a re-pump widget test.
  - `[low]` `[defer]` (blind) a created commit reads `diff(revision:)` with copy records, where `jj op show -p` uses `show_inter_diff` without them (a rename shows as rename, the CLI shows delete + add) — needs a backend inter-diff with no predecessors; rare (a created commit with content and a rename).
  - `[low]` `[patch]` (blind) the both-absent text is called "`jj interdiff`'s wording", but jj prints clap's text — test comment corrected to `Repo::interdiff`'s wording.
  - `[low]` `[reject]` (blind) summaries use 8 chars, not `shortest(8)`, and no bookmarks/labels/`templates.commit_summary` — the GUI renders structured data, the template is terminal rendering (project rule: terminal UX is not replicated).
  - `[low]` `[reject]` (blind) `−` (U+2212) instead of jj's ASCII `-` — rendering, matches 10.24's hunk counts.
  - `[false]` `[reject]` (blind) the unresolved changes-in hint line may be missing — `op_diff.rs:202` puts "(Use --show-changes-in=all() to see all changes)" into the warning message, which the view shows verbatim.
  - `[low]` `[defer]` (blind) description changes beyond the first line are invisible (the CLI's `JJ-COMMIT-DESCRIPTION` block) — intent asks for the file diff; mirrored for a follow-up.
  - `[maybe-false]` `[defer]` (blind) large operations may be slow: non-lazy ListView, `show` computes fileChanges for every referenced commit — unmeasured; would be medium; settle by timing `jj op show` of a large rebase in the app.
  - `[low]` `[patch]` (blind) the interdiff arm computes parent trees even without paths — now only when `paths` is non-empty.
  - `[low]` `[patch]` (blind) widgetbook leaks a temp dir — deleted in dispose.
  - `[low]` `[reject]` (blind) the catalogue's Show changes demo has a no-op Back — catalogue-only, the real path is tested.
  - `[maybe-false]` `[reject]` (blind) commit order vs jj's `TopoGroupedGraph` unpinned — the bridge returns revset order; if wrong only low (row order); settle with an oracle case.
  - `[low]` `[patch]` (blind) tests missing for working-copy, remote tracked/untracked, conflicted targets — added model tests; root row / ↩ / elided-in-view stay untested (covered by shared code paths).
  - `[low]` `[reject]` (blind) `_load` reads by the 12-hex prefix — what the spec asks and the CLI shows; a 12-hex collision among op ids is negligible.
  - `[false]` `[reject]` (blind) setLayout swallows only FileSystemException — the same contract as 10.24's `InspectorViewModel.setLayout`; the store throws only that.
  - `[low]` `[defer]` (edge) duplicate of the created-commit copy-records finding — same entry as above.
  - `[medium]` `[patch]` (edge) select/focus callbacks run after dispose, starting reads (and a closed handle's StateError) — `_disposed` guards added, `_serial` bumped in dispose; test added.
  - `[low]` `[patch]` (edge) same root cause: StateError from a closed handle in an unawaited read — fixed by the same guards.
  - `[low]` `[reject]` (edge) a 12-hex op-id prefix collision — as above.
  - `[maybe-false]` `[defer]` (edge) one very large `show` read — same entry as the large-operation finding.
  - `[low]` `[reject]` (edge) names needing quoting (as_symbol) render unquoted in headings — rare names, heading rendering only.
  - `[low]` `[patch]` (edge) didUpdateWidget ignores a changed SettingsStore — compared too.
  - `[low]` `[patch]` (edge) widgetbook temp dir — same fix as above.
  - `[false]` `[reject]` (edge) a refused summary read shows no text — the spec's Always rule says it falls back to the commit id alone; that is the designed behavior.
  - `[low]` `[defer]` (edge) claim: created commits are not CLI parity — same entry as the copy-records finding.
  - `[false]` `[reject]` (intent) the change is UI+bridge although tagged [UI] — the CLI-parity rule makes the inter-diff backend part of the story; no defect.
  - `[false]` `[reject]` (intent) only leaf components of 10.24 are reused — the scope names the file list, hunks, layout toggle and preference, all reused.
  - `[maybe-false]` `[reject]` (intent) no running-app (Marionette) check and I1 not marked resolved in the ledger — I1 is marked resolved at commit; the visual check is recorded as not done (Auto Run Result).

## Design Notes

Placement (Claude's proposal; the DS has no op-show design): the view replaces the list inside the Undo Timeline's pinned panel (its scroll area), header = Back button + the operation's first line + `jj op show <id>` in mono. Selecting a commit row (click, ↩) loads its files; the first file is focused, like 10.24.

The `interdiff` flag reuses `DiffRequest` rather than adding a verb: same payload (`Diff`), same pins; `with_verb(cli_command::DIFF)` keeps `diff`'s config scope (the CLI would resolve `--when.commands` for `interdiff` — negligible).

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it diff::` / `cargo test -p zanshin-ffi diff` -- pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` -- clean
- `cargo make codegen` -- generated files committed
- `cargo test -p zanshin-parity --test oracle` -- pass
- `flutter test` (app, packages/zanshin_core), `dart analyze --fatal-infos`, `dart format --set-exit-if-changed` -- pass

**Verification notes (2026-11-02, targeted checks only — gate rule of the story loop):**
- `cargo test -p zanshin-jj --test it diff::` — 41 passed (after the review patches).
- `cargo test -p zanshin-ffi diff` — 10 + 16 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean.
- `cargo make codegen` — re-run, output unchanged against the tree (header, bindings, both generated envelopes committed).
- `cargo test -p zanshin-parity --test oracle` — 506 passed (before the patches); `-- diff` subset 11 passed after them.
- app: `dart analyze --fatal-infos` clean, `dart format --set-exit-if-changed` clean; `flutter test test/features/undo_timeline test/features/graph/inspector_diff_test.dart test/features/home` — 79 passed; `test/features/graph/graph_inspector_test.dart` passed. The implementer's full app run (pinned env): 1808 passed, 1 failed — `graph_ports_test.dart` "a describe through the handle fires exactly one more layout request", untouched by this story, passes alone (load flake); the loop's final gate re-runs it.
- packages/zanshin_core: `dart test test/worker/diff_test.dart` 11 passed (full suite 1190 passed in the implementer's run); analyze + format clean.
- packages/zanshin_ui: `flutter test` 441 passed; analyze + format clean.
- Not done: the Marionette visual check (deferred, Low).

## Auto Run Result

Status: done

**Summary.** Show changes in the Undo Timeline is enabled on every row (the newest too) and swaps the pinned panel's list for an operation view: one `opShow(<12-hex>)` per open; jj's sections (changed commits with `+` new / `−` predecessors or abandoned and the elided line, changed working copies, local bookmarks and tags, remote bookmarks and tags with tracked/untracked); the selected commit's files (10.24's file row) and focused-file diff (10.24's `InspectorDiffView`/hunks, shared Unified / Side by side preference, no Viewed); refusals show jj's text in place; Esc or Back returns. The per-commit diff follows `show_change_diff`: rewritten commits read the new `RepoHandle.diff(interdiff: true)` (`jj interdiff` with hunks — `DiffRevisions::Interdiff` in zanshin-jj, `DiffRequest.interdiff` on the wire), created/abandoned ones `diff(revision:)`.

**Files changed.**
- `crates/zanshin-jj/src/hunks.rs`, `repo.rs` — the Interdiff arm (in-memory rebase, no copy records, parent trees in the unmatched-paths check when paths are given) and the both-absent refusal.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/diff.rs`, generated envelopes / header / bindings, `docs/ffi-abi.md` — the wire field and its mapping.
- `packages/zanshin_core/lib/src/{ffi/diff.dart,worker/handle.dart,worker/commands.dart,worker/isolate.dart}` — `interdiff` threaded through.
- `app/lib/src/features/undo_timeline/operation_changes.dart` (new) — port, model, view.
- `app/lib/src/features/undo_timeline/undo_timeline_view.dart` — stateful panel, Show changes enabled.
- `app/lib/src/features/graph/inspector_diff.dart`, `graph_inspector.dart` — optional Viewed; public `InspectorFileRow`.
- `app/lib/src/features/home/home_page.dart` — wiring (source + settings).
- `app/lib/l10n/*` — four strings, `undoTimelineShowLater` removed.
- `app/widgetbook/folders/undo_timeline.dart` — "Show changes" use case.
- `packages/zanshin_ui/lib/src/controls/zs_scroll_area.dart` — the bar reads the newest attached position (both primary scroll views are attached for one frame when the panel swaps views).
- tests: `crates/zanshin-jj/tests/it/diff.rs`, `crates/zanshin-ffi/tests/it/diff_ffi.rs`, `packages/zanshin_core/test/worker/diff_test.dart`, `app/test/features/undo_timeline/{operation_changes_test,undo_timeline_view_test}.dart`, `app/test/features/graph/inspector_diff_test.dart`, `app/test/helpers/fake_undo_timeline.dart`.

**Review.** 30 findings: 12 patched (2 medium: created-commit test, reads after dispose; 10 low), 4 deferred (copy records of created commits, description body diff, large-operation speed unverified, Marionette check — all mirrored into deferred-work.md "Surfaced in Story 10.29"), 14 rejected with reasons in the triage log. Follow-up review: false (no high patched; one medium patch is a test, the other is covered by a test).

**Items.**
- I1 (Show changes stays disabled) — fixed (commit b3fc3c4c670ab3ca89dbdcda96690636c8fe2ae9).

**Residual risks.** `show` of hidden commit ids is relied on for the summaries (jj resolves commit ids visibility-blind; the fallback is the bare id); the full app suite has one pre-existing timing flake; no running-app check.
