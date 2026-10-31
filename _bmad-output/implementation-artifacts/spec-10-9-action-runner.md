---
title: 'Story 10.9 — Action runner'
type: 'feature'
created: '2026-10-31'
status: 'done'
baseline_revision: '37102ab40f2b22453e10f8b9283b6586a33af804'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: [oversized]
deferred:
  - summary: >-
      The runner has no actions for commit, split, rebase and duplicate, though their backend verbs exist.
    evidence: |-
      GraphAction covers edit, describe, new, abandon, revert, squash, bookmark create/delete/move/rename, undo, redo; RepoHandle.commit/split/rebase/duplicate have no subtype and no selection/anchor rule. Their triggers are 10.10 (drops) and 10.25 (composer).
    location: >-
      app/lib/src/features/graph/graph_ports.dart
    severity: medium
  - summary: >-
      Revert does not select the new change while the inspector is open.
    evidence: |-
      The 2026-10-26 note's rule needs 10.8's inspector state; GraphViewModel._succeeded keeps the selection, the outcome carries the born id.
    location: >-
      app/lib/src/features/graph/graph_view_model.dart
    severity: low
  - summary: >-
      The real action port is not wired into the app, and the commands are not checked through the parity oracle.
    evidence: |-
      RepoGraphActions is constructed only in tests (like RepoGraphSource, wired by 10.12); command strings are checked against literals, not parsed by jj.
    location: >-
      app/lib/src/features/graph/graph_ports.dart
    severity: low
  - summary: >-
      No test pins a pending card's opacity while a focus dim is also active.
    evidence: |-
      GraphCanvas.opacityOf multiplies disabledOpacity by the focus-dim factor; graph_view_test.dart checks the pending fade and the hover dim only one at a time, so replacing the product with either factor passes.
    location: >-
      app/lib/src/features/graph/graph_canvas.dart:524
    severity: low
    resolved: >-
      2026-10-31 — fixed (spec-10-9-closing-pending-opacity-under-focus-dim, commit 92e84d36): a test pins the pending fade times the focus dim.
---

<intent-contract>

## Intent

**Problem:** Every graph affordance (double-click today; the inspector 10.8, card menu 10.15, drops 10.10, toast 10.23 and Change menu 11.13 next) needs one path to a jj verb, but `GraphActions` is a stringly test-only port with no real implementation, no pending state, no outcome facts, no undo guard and no in-flight guard (a second double-click starts a second `jj edit`, deferred-work I2).

**Approach:** Make `GraphAction` a sealed family of typed verbs (each knows its full shell-quoted `command`, the cards it makes pending and its anchor), make the port a thin `RepoHandle` adapter (`RepoGraphActions`) returning `MutationResult`, and put the runner logic in `GraphViewModel.run`: one action at a time, pending keys, anchored reload, selection/reveal per verb from the `MutationResult`, a published outcome (refusal / warnings / op hints / label) for 10.23 and 11.13, and an undo/redo guard on the op-log head. Export `MutationResult`, `FinishFacts`, `GitExportFailure` from `zanshin_core`.

## Boundaries & Constraints

**Always:**
- CLI parity: the runner never composes verbs, never guesses a target (callers pass it; `actionTarget` = selection else @ for 11.13), never confirms `abandon`, passes CLI parameters through with the CLI's defaults as constructor defaults, never passes `--ignore-working-copy` or `allowCrossWorkspace`. Refusals are jj's `ZanshinFfiException`, published verbatim (code, context, hints, warnings) — no invented text.
- One jj call at a time: while an action runs (or the project is stale) `run` calls nothing and returns `GraphActionDisabled` with the reason (`busy` / `stale`); `GraphView` sets `GraphCardController.actionsEnabled` to `model.actionsEnabled`.
- Undo only for Zanshin's own latest operation while it is the op-log head (`headOpId()` = `opLog(limit: 1)`), and never when the action wrote no operation (`newOpId` == the head read just before it ran). `updateStale()` drops it. Redo only for the latest own undo while it is the head.
- Commands are real jj v0.46.0 commands, one per action, with the change ids, POSIX shell-quoted; a bookmark name with glob metacharacters (`*?[`) is printed as `exact:<quoted name>`.
- Strings: no new UI text in this story (the surfaces are later stories); `command` strings are jj's words (`// l10n-ignore: jj command`).

**Never:** UI surfaces (menus 10.15, inspector/squash-message form 10.8, toast 10.23, Change menu and ⌘Z 11.13, drop ghost 10.10, composer 10.25); `commit`/`split` (10.25), `rebase`/`duplicate` (10.10's drop rows); queueing a second action; a toast for refusals here; any Rust/FFI schema change.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Edit | `GraphEdit(b)` | port `run` once, then exactly one layout request; no selection change, no anchor, no reveal | — |
| New on selected parent | selected `a`, `GraphNew(parents:[a])` → result `newChangeIds:[n]` | anchor hint `a` during the reload; `n` selected; reveal `n` with `GraphRevealAlignment.covered` | — |
| New, parent not selected | selection `x` | selection stays `x`; reveal `n` covered | — |
| Abandon | `GraphAbandon([s])`, `s` selected | selection cleared; anchor hint = `s`'s first shown parent | — |
| Squash `-r s` / `--from s --into t` | `s` selected, result `abandonedChangeIds:[s]` | selection moves to the destination (t, or `s`'s first parent for `-r`); anchor = destination; flash = destination | — |
| Revert | `GraphRevert(r)` | calls `revert(revisions:[r], insertBefore:['@'])`, no description; anchor `r`; born = new id; reveal covered | — |
| Refusal | port throws `jj.immutable` | `GraphActionRefused(error)`; `outcome` holds the error verbatim; no reload unless the code is `jj.stale_working_copy` (then reload → stale state) | caught, logged at warning |
| Warnings | result warnings `[jj.identity_missing]` | published on the outcome | — |
| Pending | port future unresolved | `pendingKeys` = the action's keys, `actionsEnabled` false; cleared after | — |
| Second double-click while running | `edit(b)` twice before the first completes | one port call; second returns `GraphActionDisabled(busy)` | — |
| Stale | `stale != null` | every `run`/`undoLast` returns `GraphActionDisabled(stale)`, port untouched | — |
| Undo current | own outcome, head == its `newOpId` | `undoLast()` runs `GraphUndo(of: action)`; outcome flagged as an undo of that action; redo offered | — |
| Undo after foreign op | head ≠ `newOpId` (checked on demand and on each `OpHeadsChangedEvent` after the run) | nothing called; `undoable` becomes null | — |
| No-op verb | `newOpId` == head before the run (edit of @) | outcome not undoable | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_ports.dart` -- `GraphAction` (stringly, :130-143), `GraphActionResult` Done/Refused (:146-163), `GraphActions.run` (:166-169), `RepoGraphSource` (:173) = the adapter pattern to copy for `RepoGraphActions(ProjectRepo)`.
- `app/lib/src/features/graph/graph_view_model.dart` -- `init(actions:)` :169, `edit` :271 (I2: no busy flag), `run` :374 (reload on done), `_explicit` reveal :152/:413/:501 (make it carry a `GraphRevealAlignment`), `_land` :489 (clear the anchor hint here), `_onEvent` :395, `updateStale` :353, `_selected`/`select` :313.
- `app/lib/src/features/graph/graph_view.dart` -- `_cards` :75, `_modelChanged` :208 (sync `actionsEnabled`, pending), `GraphCanvas(...)` :247 (pass pending + anchor hint).
- `app/lib/src/features/graph/graph_canvas.dart` -- `GraphViewport(... opacityOf: :512, anchorKey: cards.selected.value :513)`: anchor = `anchorHint ?? selection`; pending nodes multiply opacity by `GraphMetrics`/theme `disabledOpacity` (the render card reads `_metrics.disabledOpacity`, graph_card_render.dart:881).
- `app/lib/src/features/graph/graph_card.dart` -- `GraphCardController.actionsEnabled` :81 (exists; render already greys affordances).
- `app/lib/src/features/graph/graph_layout.dart` -- `parentEdges`/`parentOf` (:221, :230) for "first shown parent"; `workingCopyIndex`, `keyOf`, `changeIdOf`.
- `packages/zanshin_core/lib/src/worker/handle.dart` -- verbs by symbol: `describe`, `newChange(parents, insertAfter:, insertBefore:)`, `edit`, `abandon`, `undo`, `redo`, `squash(revision, from, into, paths, message, useDestinationMessage, keepEmptied, editedDescription, trees)`, `revert(revisions, onto, insertAfter, insertBefore)`, `bookmarkCreate(names, revision:)`, `bookmarkDelete(names)` (patterns), `bookmarkMove(names, from:, to:, allowBackwards:)` (exact names), `bookmarkRename(old, new, overwriteExisting:)`, `opLog(limit:)` → `WarnedList<Operation>` (`Operation.id`).
- `packages/zanshin_core/lib/src/ffi/mutate.dart` -- `MutationResult` :184 (newOpId, newChangeIds, abandonedChangeIds, workingCopyChangeId, finish, warnings). `lib/src/ffi/precondition.dart` `FinishFacts` :35; `lib/src/ffi/git.dart` `GitExportFailure` :234.
- `packages/zanshin_core/lib/zanshin_core.dart` -- barrel; add `MutationResult` (mutate.dart), `FinishFacts` (precondition.dart show list :80), `GitExportFailure` (git.dart show list).
- `app/test/features/graph/graph_view_model_test.dart` -- fake `_Actions` :579 and run/edit tests :494-523 to rewrite; `graph_view_test.dart` `_Actions` :95.
- `app/test/features/projects/worker_project_repos_test.dart` -- real-worker test pattern (XDG guard; runs only under `cargo make --allow-private test-flutter`) for the one real-cdylib witness.
- `_bmad-output/planning-artifacts/epics.md` :9963 -- 10.9 item 1's stale `handle.dart:NNN` citations (I1) → re-point to symbol names.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_core/lib/zanshin_core.dart` -- export `MutationResult`, `FinishFacts`, `GitExportFailure` -- item 9, the bridge part.
- `app/lib/src/features/graph/graph_ports.dart` -- replace the stringly `GraphAction` with a sealed family: `GraphEdit`, `GraphDescribe(id, description)`, `GraphNew({parents, insertAfter, insertBefore})`, `GraphAbandon(ids)`, `GraphRevert(id)` (`-B @`), `GraphSquash({revision, from, into, paths, message, useDestinationMessage, keepEmptied, editedDescription})`, `GraphBookmarkCreate(names, {revision})`, `GraphBookmarkDelete(names)`, `GraphBookmarkMove(names, {from, to, allowBackwards})`, `GraphBookmarkRename(old, new, {overwriteExisting})`, `GraphUndo(of)`, `GraphRedo(of)`; each with `command` and `pendingKeys`. Port becomes `GraphActions { Future<MutationResult> run(GraphAction); Future<String> headOpId(); }`; add `RepoGraphActions(ProjectRepo)` mapping each subtype to its handle call. Replace `GraphActionResult` with `GraphActionDone(GraphOutcome)` / `GraphActionRefused(ZanshinFfiException)` / `GraphActionDisabled(GraphDisabledReason {busy, stale, nothingToUndo, foreignOperation})`; add `GraphOutcome` (action, result or error, undoable, anchor, flash ids, born ids, warnings).
- `app/lib/src/features/graph/graph_view_model.dart` -- runner per the matrix: `run`, `undoLast`, `redoLast`, `actionsEnabled`, `pendingKeys`, `anchorHint`, `outcome` (ValueListenable, latest incl. refusals), `undoable`/`redoable` (current own outcome, head-checked), `actionTarget`; `edit` goes through `run` (I2); head check on `OpHeadsChangedEvent` while an undoable/redoable outcome exists; `updateStale` drops it.
- `app/lib/src/features/graph/graph_view.dart`, `graph_canvas.dart` -- wire `actionsEnabled`, pending opacity (Claude's proposal for 10.3 design question (e): a pending card paints at `--disabled-opacity`), and `anchorKey: model.anchorHint ?? selection`.
- `app/test/features/graph/graph_ports_test.dart` -- every action's `command` (ids present, quoting, `exact:` for glob names) and `RepoGraphActions` mapping via a fake handle if one exists, else covered by the real-worker test.
- `app/test/features/graph/graph_view_model_test.dart` -- one test per matrix row (fake port with completers + fake `MutationResult`s); exactly one reload per success.
- `app/test/features/graph/graph_view_test.dart` -- update the fake; two quick double-clicks → one `edit` call; pending card greyed / `actionsEnabled` false while running.
- `app/test/features/projects/worker_project_repos_test.dart` (or a sibling real-worker test) -- `GraphEdit` through `RepoGraphActions` + `GraphViewModel.run` moves @ in a temp repo, followed by a layout request.
- `_bmad-output/planning-artifacts/epics.md` -- I1: 10.9 item 1 cites symbols (`RepoHandle.edit` …) instead of line numbers.

**Acceptance Criteria:**
- Given the stale state or a running action, when any trigger calls `run`/`undoLast`/`redoLast`, then the port is not called and the result is `GraphActionDisabled` with the reason.
- Given a published own outcome, when a foreign operation lands (head ≠ `newOpId`), then `undoable` is null and `undoLast` calls nothing.
- Given the app-facing barrel, when the app imports `MutationResult`/`FinishFacts`, then it compiles through `package:zanshin_core/zanshin_core.dart` only.
- Given every action subtype, when its `command` is read, then it is one valid jj v0.46.0 command carrying the change ids, shell-quoted.

## Spec Change Log

## Review Triage Log

### 2026-10-31 — Review pass
- verdicts: 33 findings — high 0, medium 9, low 9, false 15, maybe-false 0 (intent-auditor divergences counted as findings)
- findings:
  - `[medium]` `[patch]` B1 non-FFI throw leaves the runner busy forever — `_execute` now clears the run state on any other throw and rethrows; test added.
  - `[false]` `[reject]` B2a abandon clears an unrelated selection — the 2026-10-14 note (GV:782) says after abandon nothing is selected.
  - `[low]` `[reject]` B2b abandon of a change and its parent anchors on a vanished card — the viewport falls back to the centre node; a multi-abandon trigger does not exist yet; fix adds a loop over the layout.
  - `[false]` `[reject]` B3 revert bakes in `-B @` — the 2026-10-26 note defines the verb exactly as `jj revert -r <change> -B @` (SYNC:105).
  - `[low]` `[reject]` B4 epics.md item 1 backlog line still lists squash/move/-A as backlog — the 2026-10-14 note already supersedes item 1's list; I1 asked only for the citations.
  - `[low]` `[reject]` B5 pendingKeys ignore an implicit @ — cosmetic for a sub-second state; the triggers that land later pass explicit ids; fix needs the layout in the action.
  - `[false]` `[reject]` B6 snapshot in headOpId drops the undo after file edits — item 7 prescribes exactly this: check with `opLog(limit: 1)`, which snapshots first; on any mismatch drop the affordance.
  - `[low]` `[patch]` B7 a word starting with `=` is not zsh-safe — `_shellSafe` excludes a leading `=`; test added.
  - `[medium]` `[patch]` B8 RepoGraphActions mapping witnessed only for edit/undo — real-repo cases added (bookmark delete exact, revert, new -A/-B, redo).
  - `[false]` `[reject]` B9 spec not in the diff — excluded on purpose; it exists at spec-10-9-action-runner.md.
  - `[false]` `[reject]` B10a dispose during a run — `_notify`, `_publish` and `_requestLayout` all guard `_disposed`.
  - `[false]` `[reject]` B10b unchecked `as GraphUndo` in redoLast — `_redoable` is assigned only in the `GraphUndo` branch of `_succeeded`.
  - `[false]` `[reject]` B10c new -B does not move the selection — the new change's parent is the target's parent, not the selected target (GV:719 "when its parent was").
  - `[medium]` `[patch]` E1 non-FFI throw (same root as B1) — fixed with B1.
  - `[medium]` `[patch]` E2 `.first` on an empty op log throws StateError — covered by B1's fix (state cleared, error surfaces); jj's op log always has the root op.
  - `[false]` `[reject]` E3 abandon clears an unrelated selection — as B2a.
  - `[false]` `[reject]` E4 snapshot op drops the undo — as B6.
  - `[low]` `[reject]` E5 an undo that writes no operation drops the offer — an undo restoring an equal view is rare and the old outcome's head check would drop it anyway.
  - `[low]` `[reject]` E6 GraphSquash allows clap-conflicting combinations — callers (10.8/10.15) build one form; asserts add guards for an unreached case.
  - `[low]` `[patch]` E7 leading `=` (as B7) — fixed with B7.
  - `[false]` `[reject]` E8 no label field on the outcome — the label is the action (verb + ids) the outcome carries; its words are 10.23/11.13's localized text.
  - `[false]` `[reject]` E9 the anchor is not on the action — anchors need the layout; the outcome publishes it as `anchor`.
  - `[false]` `[reject]` E10 a refused undo still reads the head — the head read is the guard itself (item 7).
  - `[medium]` `[patch]` G1 RepoGraphActions mapping untested (as B8) — fixed with B8.
  - `[medium]` `[patch]` G2 canvas use of anchorHint untested — widget test asserts the viewport's anchorKey equals the hint while an action runs.
  - `[medium]` `[patch]` G3 squash default targets and new -A selection untested — model tests added.
  - `[medium]` `[patch]` G-other non-FFI throw (as B1) — fixed with B1.
  - `[low]` `[defer]` A1 the real port is not wired into the app — no production GraphViewModel exists before 10.12 (RepoGraphSource is likewise unwired); deferred.
  - `[false]` `[reject]` A2 no visible refusal/warning text — the 2026-10-14 note routes every non-composer refusal and warning to 10.23's toast; the runner publishes them.
  - `[false]` `[reject]` A3 no disabled-reason text — `GraphDisabledReason` is the reason; its words belong to the surfaces (10.15/11.13), and the stale notice already names `jj workspace update-stale`.
  - `[medium]` `[defer]` A4 commit/split/rebase/duplicate absent — their triggers are 10.10/10.25; deferred.
  - `[false]` `[reject]` A5 squash editor flow absent — the Save flow is 10.8's form; the runner passes `message`/`editedDescription` through.
  - `[low]` `[defer]` A6 revert inspector selection and the oracle check of commands — deferred to 10.8 / 10.15.
- note: the real-repo tests added for B8 found a further bug, fixed in the same patch round: `RepoHandle.revert` takes change ids only, so `insertBefore: ['@']` was refused `jj.change_not_found`; `RepoGraphActions` now reads @'s change id via `status()` and passes it (the command still shows `-B @`). The epics.md 2026-10-26 note's `insertBefore: ['@']` is the call's meaning, not its literal argument.

### 2026-10-31 — Review pass (follow-up)
- verdicts: 33 findings — high 0, medium 4, low 19, false 10, maybe-false 0 (intent-auditor divergences counted as findings)
- findings:
  - `[false]` `[reject]` B1 abandon clears an unrelated selection — carried: the 2026-10-14 note (GV:782) says after abandon nothing is selected.
  - `[low]` `[reject]` B2 a multi-abandon anchors on a vanished card — carried: the viewport falls back to the centre node; no multi-abandon trigger exists yet.
  - `[low]` `[reject]` B3 a failed head read is published as a refusal of the verb — the error is jj's verbatim op-log refusal and the verb did not run; a rare path, and the fix restructures `_execute`'s error handling.
  - `[low]` `[reject]` B4 `_checkHead` / `status()`→`revert()` can interleave with other jj calls — only a foreign jj process can land between two worker calls; rare, and closing it needs a worker-side revert-before-@.
  - `[false]` `[reject]` B5a the per-event head read drops the undo after file edits — carried (B6): item 7 prescribes exactly this check.
  - `[low]` `[reject]` B5b `_checkHead`'s error branch untested — a log-and-return branch; no user-visible effect.
  - `[low]` `[reject]` B6 pendingKeys/flash miss an implicit @ — carried (B5): cosmetic for a sub-second state.
  - `[false]` `[reject]` B7 `new -B` does not move the selection — carried (B10c): the new change's parent is the target's parent.
  - `[false]` `[reject]` B8 disabled results are not published on `outcome` — a `GraphActionDisabled` is returned to the calling surface, which owns its words; no jj outcome exists to publish.
  - `[false]` `[reject]` B9 dispose mid-run — carried (B10a): `_notify`, `_publish`, `_requestLayout` guard `_disposed`.
  - `[low]` `[reject]` B10 the @-less revert path is untested — only a forgotten workspace has no @, and the handle then refuses the empty location (no silent default).
  - `[low]` `[defer]` B11 pending fade combined with the focus dim untested — grouped with V2.
  - `[low]` `[reject]` B12 `GraphSquash` has no `trees` — the GUI-tree (interactive) squash is 10.8's form, not a CLI parameter.
  - `[low]` `[reject]` B13 no model test for a bookmark move's flash / `new -B`'s anchor — both are one-line plan arms beside tested siblings.
  - `[medium]` `[patch]` V1 RepoGraphActions mapping never executed for describe, abandon, squash, bookmark create/move/rename — real-repo tests added (describe, abandon, squash `-r -m -k`, bookmark create `-r` / move of `f*` beside `foo` / rename).
  - `[low]` `[defer]` V2 pending opacity × focus dim unpinned — deferred (the layer's own disposition), mirrored into deferred-work.md.
  - `[medium]` `[patch]` E1 bookmark names with `]`, `{`, `}` or `\` are sent as globs — jj-core `is_glob_char` @ v0.46.0 counts `?*[]{}\`; `_exactPattern` now uses that set; pattern test added (`{a,b}`, `x]`).
  - `[low]` `[patch]` E2 `GraphNew()` with no target is refused by the handle — `RepoGraphActions` resolves @ via `status()` (as revert does), the CLI's default parent; real-repo test added.
  - `[low]` `[reject]` E3 a foreign op between the head read and the verb makes a no-write verb undoable — a narrow window; closing it needs the worker to return the pre-call head.
  - `[low]` `[reject]` E4 multi-abandon anchor — carried, as B2.
  - `[low]` `[reject]` E5 @ moves between `status()` and `revert()` — as B4.
  - `[low]` `[reject]` E6 `_checkHead` skipped while running leaves a stale undo offer — `undoLast` re-checks the head on demand before calling anything.
  - `[medium]` `[patch]` E7 claim: glob-like names beyond `*?[` break "one valid command" — fixed with E1.
  - `[false]` `[reject]` E8 no label field — carried: the outcome's action is the label.
  - `[false]` `[reject]` E9 revert passes a resolved @ id, not `'@'` — carried: the handle takes change ids only (prior pass note).
  - `[false]` `[reject]` I1 revert literal vs semantic — as E9.
  - `[low]` `[reject]` I2 the no-op test starts without a prior undoable — the keep-previous branch is one assignment-free path.
  - `[false]` `[reject]` I3 abandon clears the selection unconditionally — as B1.
  - `[low]` `[defer]` I4 commands not checked through the oracle — carried (A6), already deferred to 10.15.
  - `[medium]` `[patch]` I5 describe/abandon/squash/bookmark verbs not run against a real repo — fixed with V1.
  - `[low]` `[reject]` I6 `_checkHead` reads the head while stale — the read fails and is caught and logged.
  - `[false]` `[reject]` I7 the anchor hint is set before the port call — deliberate (Design Notes: set at run start, cleared in `_land`).
  - `[low]` `[reject]` I8 two jj calls per action — already recorded as a residual risk.
- note: the first squash test (empty @ squashed with `-k -m`) failed against jj itself: jj squashes nothing and sets no message from an empty kept source (squash.rs `squash_commits` → `None`), the CLI's behaviour; the test now gives @ a file first.

## Design Notes

- Anchor: the viewport records `anchorKey`'s position each layout pass and re-applies it on the next layout (graph_viewport_render.dart `_recordAnchor`/`_applyAnchor`); setting `anchorHint` when the run starts and clearing it in `_land` anchors the reload on the hinted card.
- Born-change reveal uses the existing reveal precedence (an explicit reveal landing with the layout), with `GraphRevealAlignment.covered` = "only when off-screen" (design answer (a)).
- Revert's "select the new change only while the inspector is open" needs 10.8's inspector state: deferred to 10.8; the outcome carries the born id it needs.

## Verification

**Commands:**
- `flutter test test/features/graph` (in `app/`) -- expected: all pass
- `dart analyze --fatal-infos` (in `app/` and `packages/zanshin_core/`) -- expected: no issues
- `dart format --set-exit-if-changed lib test` (in `app/`, `packages/zanshin_core/`) -- expected: exit 0
- `flutter test test/l10n/hard_coded_strings_test.dart` (in `app/`) -- expected: pass
- `cargo make --allow-private test-flutter` -- expected: the real-worker edit test passes (only if the real-worker test is added there)

**Verification notes (gate rule of this story-loop run: no `cargo make test` / `test-full` / `coverage`):**
- `flutter test test/features/graph test/l10n/hard_coded_strings_test.dart` (app/) -- 351 passed, after the review patches (342 before them).
- `dart analyze --fatal-infos` -- no issues in `app/` and `packages/zanshin_core/`.
- `dart format --set-exit-if-changed lib test` -- exit 0 in `app/` and `packages/zanshin_core/`.
- `cargo make --allow-private test-flutter` (run by the implementer) -- 1172 passed on the last run; one earlier run failed once in `projects_window_test.dart` ("Story 11.15 closing — focus New group…", untouched by this story), passing alone and on the rerun (flaky).
- No Rust, FFI or schema change: no cargo test / clippy / codegen / parity oracle needed. The Marionette catalogue check was not run (unattended).
- Follow-up review (2026-10-31): `cargo make --allow-private test-flutter` -- 1177 passed (one run before the squash test fix failed on that test only, see the triage note); `dart analyze --fatal-infos` (app/) -- no issues; `dart format --set-exit-if-changed lib test` (app/) -- exit 0. No Rust, FFI or zanshin_core change.

## Auto Run Result

Status: done

**Summary.** `GraphAction` is a sealed family of typed jj verbs (edit, describe, new with -A/-B, abandon, revert `-B @`, squash, bookmark create/delete/move/rename, undo, redo), each with its full POSIX-shell-quoted jj v0.46.0 `command` and its pending cards. `RepoGraphActions(ProjectRepo)` maps them onto `RepoHandle`; `GraphViewModel.run` / `undoLast` / `redoLast` is the one runner: one action at a time (busy/stale → `GraphActionDisabled`, port untouched), pending cards at `--disabled-opacity` (Claude's proposal for 10.3 design question (e)), the reload anchored on the planned card, selection and covered reveal per verb from the `MutationResult`, every outcome (refusals verbatim, warnings, anchor, flash, born) published for 10.23/11.13/10.20, and undo/redo only while the op-log head is Zanshin's own operation (no-op verbs and `updateStale` never offer one). `zanshin_core` exports `MutationResult`, `FinishFacts`, `GitExportFailure`.

**Files.**
- `packages/zanshin_core/lib/zanshin_core.dart` -- barrel exports (the bridge part).
- `app/lib/src/features/graph/graph_ports.dart` -- sealed actions, commands, the port, `RepoGraphActions`, result and outcome types.
- `app/lib/src/features/graph/graph_view_model.dart` -- the runner state machine; `edit` through `run`.
- `app/lib/src/features/graph/graph_view.dart`, `graph_canvas.dart` -- `actionsEnabled`, pending opacity, anchor hint.
- `app/test/features/graph/graph_ports_test.dart`, `graph_view_model_test.dart`, `graph_view_test.dart` -- command forms, every matrix row, real-repo mapping (edit/undo/redo, bookmark delete exact, revert, new -A/-B), widget pending/anchor/double-click witnesses.
- `_bmad-output/planning-artifacts/epics.md` -- I1 citations re-pointed to `RepoHandle` symbols.

**Review.** 33 findings: 7 patch entries applied (B1/E1/E2/G-other busy-forever on a non-FFI throw; B7/E7 zsh `=`; B8/G1 real-repo mapping tests; G2 anchor widget test; G3 squash-default/new -A tests), which also surfaced and fixed the revert `@` bug; 3 deferred (commit/split/rebase/duplicate → 10.10/10.25; revert's inspector selection → 10.8; app wiring 10.12 and oracle check 10.15), mirrored into deferred-work.md; 23 rejected with reasons in the triage log.

**Follow-up review recommended:** true -- 2+ medium entries were patched (patched counts: high 0, medium 4 entries, low 1 entry); the unverified risk is the late revert-mapping fix (`status()` read before `revert`) and the error-path `rethrow`, which only the patch round's own tests cover.

**Items.**
- I1 -- fixed (4d32de6a48262ead5ea44cbfff2792799066f5ab): epics.md 10.9 item 1 now cites `RepoHandle.edit`, `.describe`, `.newChange`, `.abandon`, `.bookmarkCreate`, `.bookmarkDelete`, `.undo` instead of line numbers. 10.8's part (`handle.dart:690` for `show`) stays open as asked.
- I2 -- fixed (4d32de6a48262ead5ea44cbfff2792799066f5ab): overlapping actions are refused (`GraphActionDisabled(busy)`, no port call); a model test and a widget test show two quick double-clicks run one `edit`.

**Follow-up review (2026-10-31).** 33 findings: 3 patch entries applied (medium: bookmark glob set now jj-core's `?*[]{}\`; medium: real-repo mapping tests for describe, abandon, squash, bookmark create/move/rename; low: `GraphNew()` resolves @ like the CLI default); 1 new deferral (pending × focus-dim opacity test, mirrored into deferred-work.md), 1 carried deferral (oracle check); 28 rejected with reasons in the triage log. Files: `app/lib/src/features/graph/graph_ports.dart` (glob set, `_newOnAt`), `app/test/features/graph/graph_ports_test.dart` (tests). Follow-up review recommended: false -- follow-up pass patched no high (patched counts: high 0, medium 2 entries, low 1 entry).

**Residual risks.** One extra `opLog(limit: 1)` (snapshotting) per action and per op-heads event while an undo/redo is offered; a watcher op-heads event after an own action adds a second, unanchored reload; the runner is not reachable from the running app until 10.12 wires `RepoGraphActions`.
