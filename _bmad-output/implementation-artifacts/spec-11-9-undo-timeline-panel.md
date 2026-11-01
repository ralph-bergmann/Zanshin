---
title: 'Story 11.9 — Undo Timeline panel [UI/bridge]'
type: 'feature'
created: '2026-11-01'
status: 'done'
baseline_revision: '0f4f706bf4d5205183c4fa8c157e264a86544a8a'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The Undo Timeline in the project window has no runner yet; Undo, Redo and Restore to here show disabled until 10.12 mounts the graph's GraphViewModel.
    evidence: |-
      HomePage's _UndoTimelineHost builds undoTimelineRailItem without actions:; the runner is GraphViewModel, not in HomePage until 10.12.
    location: >-
      app/lib/src/features/home/home_page.dart
    severity: medium
  - summary: >-
      Show changes (jj op show <id>) stays disabled; no view renders RepoHandle.opShow yet.
    evidence: |-
      The row shows the button with its command; an operation-diff view is a story of its own.
    location: >-
      app/lib/src/features/undo_timeline/undo_timeline_view.dart
    severity: low
  - summary: >-
      A log of exactly a multiple of 50 operations costs one extra opLog read at the end.
    evidence: |-
      opLog has no count or offset; loadMore asks for 50 more once and finds none.
    location: >-
      app/lib/src/features/undo_timeline/undo_timeline_model.dart
    severity: low
  - summary: >-
      A disabled timeline action reads "Another action is running" also while the runner reports a stale working copy.
    evidence: |-
      UndoTimelineActions exposes actionsEnabled only; the panel's stale note normally shows first since opLog refuses too.
    location: >-
      app/lib/src/features/undo_timeline/undo_timeline_model.dart
    severity: low
  - summary: >-
      The Undo Timeline use cases are not yet checked visually in the catalogue against the DS Callout card and the kit's panel.
    evidence: |-
      Widget tests cover structure, colours and opacity; the Marionette check (zanshinCatalogue.open on undo-timeline/undo-timeline/*) did not run in this unattended run.
    location: >-
      app/widgetbook/folders/undo_timeline.dart
    severity: medium
---

<intent-contract>

## Intent

**Problem:** The rail has no Undo Timeline: the project window cannot preview or pin the operation log, and nothing but ⌘Z / the toast undoes — never an operation that is not Zanshin's own, never a restore to an older operation (epics.md Story 11.9, its 2026-10-16 design update; decision 16.7).

**Approach:** A new feature `app/lib/src/features/undo_timeline/` supplies the rail item "Undo Timeline" (icon `undo`): a hover preview of the 3 newest operations and a pinned, lazily built, paged timeline over the shipped `RepoHandle.opLog(limit:)`, reloading on `OpHeadsChangedEvent`. Its actions run through 10.9's runner (`GraphViewModel`): Undo on the newest row (`jj undo`), Redo (`jj redo`, while the runner holds Zanshin's own undo), Restore to here (`jj op restore <id>`, 9.12); Show changes (`jj op show <id>`) shows disabled with its command. Settles deferred item I1 (no duration in the row).

## Boundaries & Constraints

**Always:**
- jj's observable behaviour: `jj undo` / `jj redo` / `jj op restore` called with the CLI's defaults; refusals reach the toast verbatim through the runner's published outcome (10.23's `GraphToasts`); every undo from the timeline ends in "Undid ‹action› · Redo" (decision 16.46) because it is a `GraphUndo` the runner publishes.
- Commands are real v0.46.0 text, shell-quoted through `graph_ports.dart`'s `_jj`; operation ids shown and passed as jj's 12-hex short id (`format_short_operation_id`).
- Rows: a dot (the newest = current operation in `--accent-line`, decision 16.43; others `--text-faint`); line 1 the description's first line; when the operation has an `args` tag, a mono line with its value (Claude's proposal, prototype defect 76); last line the relative time (`lastOpenedLabel`) and, when present, the workspace name; snapshot rows dimmed to .55. Preview rows: "description · when" on one line (DS kit.css:69-72, `.zk-op`).
- Undo is disabled with a reason when the head is the root operation or its parent is (`Operation.rootOp`; 9.21 item 2), while the runner is busy or stale, and when no runner is passed. Disabled buttons keep their tooltip naming the full command (decisions 16.39, 16.44).
- `opLog` refusing `jj.stale_working_copy` → panel and preview show "Working copy is stale", no Retry (item 7, decision 16.28); while stale the list also reloads on `WorkingCopyHeartbeatEvent`.
- New strings in `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n` output committed); jj's own words marked `// l10n-ignore:`.
- VoiceOver: each row one semantics node (description, time, workspace); buttons are Zs controls with labels; the list is the panel's scroll area.

**Never:**
- No header count (design question (b): none until a cheap count exists). No operation graph (rows stay linear, newest first). No `op abandon`, no `op revert`.
- No Rust, FFI or `.fbs` change (I1 settled without a field). No new runner beside `GraphViewModel`; the timeline never calls `undo`/`redo`/`opRestore` on the handle itself.
- No duplicate toast: the timeline shows no toast of its own.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Preview | 5 ops | 3 newest "description · when" | — |
| Paging | 1,000 ops, page 50 | first load `opLog(limit: 50)`; scrolling near the end loads `limit: 100`, …; rows off screen not built | a failed page keeps the rows shown |
| Undo newest | head op H, runner idle | `runner.undoOperation(H)` once → `GraphUndo(GraphLoggedOperation(H))`, run only while H is still the head | refusal: runner publishes it (toast); head moved: `GraphActionDisabled(foreignOperation)`, list reloads on the event |
| Root parent | head's parent `rootOp` (after `jj op abandon ..@-`), or head is root | Undo disabled with reason | — |
| Restore | row R (not newest, not root) | `runner.restoreOperation(R short id)` → `jj op restore <id>`; toast "Restored to operation: ‹id›" with Undo | refusal via runner |
| Redo | runner `redoable != null` | Redo enabled, runs `runner.redoLast()`; else disabled, tooltip `jj redo` | — |
| No runner | project window before 10.12 | all actions disabled, tooltips name the command | — |
| Stale | `opLog` throws `jj.stale_working_copy` | "Working copy is stale" in panel and preview, no Retry | other errors: the error's context, last rows kept |
| Live | `OpHeadsChangedEvent` | reloads with the current limit | — |

</intent-contract>

## Code Map

- `app/lib/src/features/shell/shell_controller.dart:13-42` -- `ShellRailItem` (id/label/icon/count/preview/panel); add `scrolls` (bool, default false): the panel is its own scroll view.
- `app/lib/src/features/shell/pinned_panel.dart:243-249` -- body = `ZsScrollArea` over `SingleChildScrollView(controller: _scroll)`; with `item.scrolls` put `PrimaryScrollController(controller: _scroll, child: item.panel)` instead (the panel's `ListView.builder(primary: true)` adds the bottom 10 itself). Flyout uses the same widget.
- `app/lib/src/features/shell/rail_preview.dart` -- preview body slot; `ExcludeSemantics` already.
- `app/lib/src/features/home/home_page.dart:62-69` -- `FloatingShell(... railItems:)` not passed yet; add the Undo Timeline item while `projects.repo != null`, from a stateful host that keeps one timeline model per `ProjectRepo` (recreate on repo change, dispose on unmount). No runner here until 10.12 mounts the graph's `GraphViewModel` (hand-off).
- `app/lib/src/features/projects/project_repos.dart:45-61` -- `ProjectRepo.handle` (`opLog(limit:)`), `events` (`RepoEvent` incl. `OpHeadsChangedEvent`, `WorkingCopyHeartbeatEvent`); `isStale(error)` at :168.
- `packages/zanshin_core/lib/src/ffi/op_log.dart:132-192` -- `Operation` (id forward hex, parentIds, timestampMillis, tzOffsetMinutes, description, rootOp, isSnapshot, workspaceName, tags) / `OperationTag`; already exported from `zanshin_core.dart:67-82` (bridge part item 6 is done; `MutationResult` exported :66).
- `packages/zanshin_core/lib/src/worker/handle.dart:298` -- `opLog({int limit = -1})` returns `WarnedList<Operation>` newest first; snapshots first, refuses stale.
- `app/lib/src/features/graph/graph_ports.dart:163-175, 428-455, 593-663` -- sealed `GraphAction` (`command`, `pendingKeys`), `GraphUndo(of)` / `GraphRedo(of)`, `_jj` quoting, `RepoGraphActions.run` exhaustive switch (:612-646). Add `GraphLoggedOperation(id, description, {args})` (command = args tag value ?? description; not runnable: `run` throws `ArgumentError`) and `GraphOpRestore(operation)` (command `jj op restore <operation>`, run → `handle.opRestore(operation)`).
- `app/lib/src/features/graph/graph_view_model.dart:371-389, 514-583, 630-685` -- `hasActions`, `actionsEnabled`, `undoable`/`redoable`, `run`, `undoLast`, `redoLast`, `_execute(expectHead:)`, `_succeeded` (sets `_redoable` after a `GraphUndo`). Add `undoOperation(GraphLoggedOperation head)` = `_execute(GraphUndo(head), expectHead: head.id)` and `restoreOperation(String operation)` = `_execute(GraphOpRestore(operation))`; make the class implement the new `UndoTimelineActions`.
- `app/lib/src/features/graph/graph_toasts.dart:226-279` -- `_text` exhaustive switch: add `GraphOpRestore` ("Restored to operation: " jj's text + mono id) and `GraphLoggedOperation` (never an outcome's own action: empty span). `GraphUndo(of: logged)` already reads "Undid ‹of.command›".
- `app/lib/src/features/shell/app_menu.dart:182-204` -- `actionName` exhaustive switch: `GraphLoggedOperation` → its `command`; `GraphOpRestore` → new ARB `menuRestoreOperation(id)` ("Restore to {operation}").
- `app/lib/src/features/projects/relative_time.dart:10` -- `lastOpenedLabel(strings, at, now)` for "when".
- `packages/zanshin_ui/lib/src/controls/zs_button.dart:121-135` (`ZsButton` label/onPressed/icon/disabledReason/identifier), `zs_tooltip.dart:53-61` (`ZsTooltip(message, cmd:)`), `zs_scroll_area.dart`, `ZI.undo` (`icons/zanshin_icon.dart:204`), `ZsColors`/`ZsType` (`ZsType.command` mono, `ZsType.fsSm`).
- `app/widgetbook/catalogue.dart:27-33` -- folder list; `app/widgetbook/folders/shell.dart:96-113` keeps its demo rows (unchanged).
- Tests: `app/test/helpers/shell_host.dart`, `app/test/features/shell/pinned_panel_test.dart`, `app/test/features/graph/graph_view_model_test.dart` / `graph_ports_test.dart` / `graph_toasts_test.dart` / `app/test/features/shell/app_menu_test.dart` (fakes for `GraphActions` live there), `app/test/helpers/icon_registry.dart` (icons in `setUpAll`), `app/test/l10n/hard_coded_strings_test.dart` guard.
- I1 evidence: the CLI row is `format_operation` (id, user, workspace, time range, description, attributes; `cli/src/config/templates.toml:438-449` @ v0.46.0); the DS row is `cmd · when` only (`design_system/ui_kits/desktop/chrome.jsx:133`, kit.css:69-72) and epics.md item 2 names description + relative time — no duration, no user.

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/graph/graph_ports.dart` -- add `GraphLoggedOperation` and `GraphOpRestore` to the sealed hierarchy and to `RepoGraphActions.run` -- the timeline's verbs through the one runner.
- `app/lib/src/features/graph/graph_view_model.dart` -- `undoOperation`, `restoreOperation`; implement `UndoTimelineActions` -- reuse busy/stale/expect-head/outcome/redo state.
- `app/lib/src/features/graph/graph_toasts.dart`, `app/lib/src/features/shell/app_menu.dart` -- cover the two new actions in their switches.
- `app/lib/src/features/undo_timeline/undo_timeline_model.dart` -- `UndoTimelineSource` port (`Future<List<Operation>> opLog({required int limit})`, `Stream<RepoEvent> events`) + `RepoUndoTimelineSource(ProjectRepo)`; `UndoTimelineActions` interface (`Listenable`; `actionsEnabled`, `redoable`, `undoOperation`, `redoLast`, `restoreOperation`); `UndoTimelineModel` (ChangeNotifier: `operations`, `loading`, `stale`, `error`, `loadMore()`, page size 50, at most one load in flight plus one queued, event reload, a clock and a minute tick for "when", `dispose` cancels both) -- the logic.
- `app/lib/src/features/undo_timeline/undo_timeline_view.dart` -- `UndoTimelinePreview`, `UndoTimelinePanel` (lazy `ListView.builder(primary: true)`, `loadMore` near the end, rows + actions; newest row shows Undo/Redo always, other rows show Restore to here and Show changes on hover or focus within), `undoTimelineRailItem(...)` building the `ShellRailItem` (`id: 'undo'`, `scrolls: true`, no count); identifiers `undo-timeline-row-<n>`, `undo-timeline-undo`, `-redo`, `-restore-<n>`, `-show-<n>`.
- `app/lib/src/features/shell/shell_controller.dart`, `pinned_panel.dart` -- `scrolls` flag.
- `app/lib/src/features/home/home_page.dart` -- mount the rail item per open repo (no runner).
- `app/lib/l10n/app_en.arb` (+ generated) -- labels, reasons, stale text, row semantics.
- `app/widgetbook/folders/undo_timeline.dart` + `catalogue.dart` -- "Undo Timeline" use cases over a fake source and fake actions: Preview, Panel, Panel 1,000 ops, Root parent, Stale, No runner.
- `app/test/features/undo_timeline/undo_timeline_model_test.dart`, `undo_timeline_view_test.dart`; extend graph view model / ports / toasts / app menu / pinned panel tests -- the witnesses below.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- I1 outcome in its section; new deferrals under "Surfaced in Story 11.9".

**Acceptance Criteria:**
- Given a fake source with 5 operations, when the preview shows, then it lists the 3 newest descriptions with their relative times, and no count.
- Given 1,000 operations, when the panel is pinned and scrolled to the end, then `opLog` was called with growing limits (50, 100, …) and no row beyond the viewport's cache extent is built.
- Given the newest operation is current, then its dot paints `accentLine` and snapshot rows are at .55 opacity.
- Given a fake runner, when Undo on the newest row is pressed, then `undoOperation` is called once with that operation; given `GraphViewModel` over a fake `GraphActions`, `undoOperation(head)` runs `GraphUndo(GraphLoggedOperation)` → `undo()` once, publishes "Undid ‹description›" with Redo, and a refusal is published with jj's error.
- Given the head's parent is the root operation, then Undo is disabled with a reason.
- Given an `OpHeadsChangedEvent`, then the list reloads once.
- Given any disabled action, then its tooltip shows the full jj command with the operation id (`jj op restore 1a2b3c4d5e6f`, `jj op show 1a2b3c4d5e6f`, `jj redo`, `jj undo`).
- Given `opLog` refuses stale, then panel and preview show "Working copy is stale" without a Retry.
- Given the pinned panel's edge is dragged, then the width stays 240–440 and is shared with Bookmarks (11.3's existing model; a test that the Undo Timeline panel uses the shared width).
- Given the catalogue, when the Undo Timeline use cases are opened via Marionette `zanshinCatalogue.open`, then they render matching the DS callout/panel cards (visual check recorded).

## Spec Change Log

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 30 findings — high 1, medium 7, low 14, false 5, maybe-false 3
- findings:
  - `[high]` `[patch]` (blind) persistent read error re-reads `opLog` every frame (rebuilt last rows post `loadMore`, guard passes) — patched: `loadMore` is a no-op while `error != null`; bounded-reads view test.
  - `[medium]` `[patch]` (blind) `jj undo` on an undo-head undoes the operation it restored to (`undo.rs:55,106-118`), toast named the undo itself — patched: `undoOperation(head, of)` names the target looked up from the log.
  - `[low]` `[reject]` (blind) Undo disabled on a root parent though jj allows it — the epics.md 2026-10-16 design update (9.21 item 2) decides this UI guard; jj's own behaviour is unchanged when it runs.
  - `[low]` `[reject]` (blind) merge / cross-workspace heads not pre-checked — jj's refusal reaches the toast through the runner; a pre-check would add branches for a rare case.
  - `[medium]` `[patch]` (blind) Redo only for Zanshin's own undo, `jj redo` works after any undo (`redo.rs:108-129`) — patched: Redo also enabled when the head (redo prefix followed) is an undo operation, via `redoOperation(head, of)`.
  - `[low]` `[patch]` (blind) `_UndoTimelineHost` lacks `didUpdateWidget` — patched.
  - `[medium]` `[patch]` (blind) the HomePage host is untested — patched: home_page_test opens/closes/switches projects and asserts the rail item.
  - `[false]` `[reject]` (blind) passing `railItems:` drops other rail items — HomePage passed none before this change; Bookmarks (10.14) is backlog.
  - `[low]` `[reject]` (blind) restore toast hard-coded and without jj's operation summary — the prefix is jj's text (l10n-ignore); the summary is terminal decoration of the same operation.
  - `[false]` `[reject]` (blind) Restore passes the short id to the verb — intended (spec Always: the id shown is the id run; jj refuses an ambiguous prefix verbatim).
  - `[low]` `[reject]` (blind) VoiceOver row label omits args/snapshot/current — description, time and workspace identify the row; the newest row's Undo/Redo name the current operation.
  - `[low]` `[patch]` (blind) snapshot opacity dims the row's buttons — patched: opacity on dot and texts only.
  - `[false]` `[reject]` (blind) Show changes is a dead control — spec decision (disabled with its command), deferred with a follow-up.
  - `[maybe-false]` `[reject]` (blind) `GraphLoggedOperation` is a non-verb in the sealed hierarchy — the spec's chosen design; would be low at most (one `throw` arm, one empty-span arm).
  - `[low]` `[patch]` (blind) view paths untested (error note after rows, root head reason, keyboard path, preview error) — patched: error-note and root-head tests; keyboard path and preview error not added (covered by the shared row code).
  - `[medium]` `[patch]` (edge) same loop as above — patched (same fix).
  - `[low]` `[patch]` (edge) a non-jj read failure shows an empty panel with no message — patched: wrapped as `ffi.unknown` so the note shows; model test.
  - `[low]` `[reject]` (edge) a failed reload while a bigger page is queued drops the page — rare; the next scroll near the end asks again.
  - `[low]` `[patch]` (edge) the root row shows a blank description and an epoch time — patched: `root()` as jj's op log shows it, no time.
  - `[low]` `[patch]` (edge) host keeps the old session's listener — patched (same as didUpdateWidget).
  - `[medium]` `[defer]` (edge) the catalogue visual check AC is unchecked — deferred (already in deferred-work "Surfaced in Story 11.9"); the unattended run has no Marionette session.
  - `[low]` `[patch]` (edge) non-FFI errors show no context — patched (same as the empty-panel fix).
  - `[medium]` `[patch]` (verification-gap) host untested — patched (same as above).
  - `[low]` `[patch]` (verification-gap) root row's Restore exclusion unasserted — patched: hover + semantics assertions.
  - `[low]` `[patch]` (verification-gap) generic catch untested — patched (model test).
  - `[maybe-false]` `[reject]` (intent) I1's CLI-parity reading not engaged — `lasted …` is terminal rendering of the op-log entry (no repo-side effect); the item itself made the field conditional on the timeline's design; would be low.
  - `[false]` `[reject]` (intent) `## Auto Run Result` missing — written at finalize.
  - `[medium]` `[defer]` (intent) actions run only against fakes; the project window has no runner — deferred hand-off to 10.12 (already in deferred-work).
  - `[false]` `[reject]` (intent) bridge part (item 6) untouched — `Operation`, `OperationTag`, `RestoreWhat`, `MutationResult` were already exported (`zanshin_core.dart:66-82`).
  - `[maybe-false]` `[reject]` (intent) visual conformance unchecked — same as the deferred visual check; counted there.

## Design Notes

**Why the runner is `GraphViewModel` and the project window passes none yet.** 10.9's runner owns busy, stale, the expect-head check, the outcome stream the toast shows and Zanshin's undo/redo state; a second runner would race it. It lives in the graph's view model, which 10.12 mounts in the project window. Until then `HomePage` passes no runner: the timeline reads and updates live, its actions show disabled with their commands (Claude's proposal; hand-off recorded for 10.12).

**Undo of any head.** `GraphUndo.of` names what was undone; for an operation from the log that is `GraphLoggedOperation`, whose `command` is the `args` tag (a CLI operation's command line) or else the description — so the toast reads "Undid jj describe -m wip" or "Undid new empty commit", and Redo/⌘Z follow from the runner's existing `_redoable`/`_undoable`.

**Paging** re-reads from the head with a larger limit (the bridge has no offset); keys are op ids so rows keep identity.

**I1:** settled without a field — the timeline's row shows no duration (DS and epics item 2); no other consumer wants it.

## Verification

**Commands:**
- `flutter test` in `app/` (targeted: `test/features/undo_timeline`, `test/features/graph`, `test/features/shell`, `test/features/home`, `test/l10n`) -- expected: pass
- `dart analyze --fatal-infos --fatal-warnings` in `app/` -- expected: no issues
- `dart format --set-exit-if-changed lib test widgetbook` in `app/` -- expected: no changes
- `flutter gen-l10n` in `app/` -- expected: generated files committed, no diff after

**Manual checks (if no CLI):**
- Run the catalogue, open each Undo Timeline use case through Marionette `zanshinCatalogue.open`, screenshot, compare with DS `components/surfaces/surfaces.card.html` (Callout "Undo Timeline") and the kit's panel; record in verification notes.

**Verification notes (2026-11-01, gate rule of the story loop: targeted checks only, no `cargo make test`):**
- `flutter test test/features/undo_timeline test/features/graph test/features/shell test/features/home test/l10n test/widgetbook test/app` in `app/` — 1119 tests, all passed (after the review patches; 1056 before them on a narrower set).
- `dart analyze --fatal-infos --fatal-warnings` in `app/` — no issues.
- `dart format --set-exit-if-changed lib test widgetbook` in `app/` — 0 changed.
- `flutter gen-l10n` in `app/` — regenerated, no further diff; generated files committed.
- No Rust, FFI or schema change: no cargo test, clippy, codegen or parity oracle needed.
- Marionette visual check in the catalogue — NOT run (unattended run without a running catalogue); deferred.

## Auto Run Result

Status: done

**Summary.** The rail's Undo Timeline: `UndoTimelineModel` reads the op log in pages of 50 (re-read from the head), reloads on `OpHeadsChangedEvent` (and the heartbeat while stale), stops paging on an error; the hover preview lists the 3 newest "description · when" (no count); the pinned panel is a lazy list (accent dot on the current operation, `args` tag line, time · workspace, snapshots at .55, `root()` for the root). Actions go through 10.9's runner (`GraphViewModel`): Undo on the newest row names what `jj undo` really undoes (the undo stack is followed), Redo is offered whenever `jj redo` would act (Zanshin's own undo or an undo-operation head), Restore to here runs `jj op restore <12-hex>`; Show changes shows disabled with `jj op show <id>`. The project window mounts it per open repository without a runner until 10.12 (hand-off).

**Items.**
- I1 — rejected (settled, no field): the Undo Timeline's row shows no duration — the DS row is `cmd · when` (`design_system/ui_kits/desktop/chrome.jsx:133`, kit.css:69-72) and epics.md item 2 names description + relative time; the CLI's ", lasted …" is the op-log entry's terminal rendering, not a repo-side effect, and the item made the field conditional on this design. Ledger entry marked resolved in deferred-work.md (commit of this spec).

**Files changed** (code commit 4f0c20a5b6dc64304dcf899003bfbdf824fe114f):
- `app/lib/src/features/undo_timeline/undo_timeline_model.dart` — source port, actions interface, model, op helpers (short id, args tag, undo/redo targets).
- `app/lib/src/features/undo_timeline/undo_timeline_view.dart` — rail item, preview, panel, rows and actions.
- `app/lib/src/features/graph/graph_ports.dart` — `GraphLoggedOperation`, `GraphOpRestore`, `jjOpShowCommand`.
- `app/lib/src/features/graph/graph_view_model.dart` — implements `UndoTimelineActions`: `undoOperation`, `redoOperation`, `restoreOperation`.
- `app/lib/src/features/graph/graph_toasts.dart`, `app/lib/src/features/shell/app_menu.dart` — the new actions in toasts and menu names.
- `app/lib/src/features/shell/shell_controller.dart`, `pinned_panel.dart` — `ShellRailItem.scrolls` (a panel that is its own scroll view).
- `app/lib/src/features/home/home_page.dart` — `_UndoTimelineHost`, one model per open repository.
- `app/lib/l10n/*` — new strings + generated files.
- `app/widgetbook/folders/undo_timeline.dart`, `catalogue.dart` — "Undo Timeline" use cases.
- Tests: `app/test/features/undo_timeline/*`, `app/test/helpers/fake_undo_timeline.dart`, `fake_projects.dart`, and extensions to graph view model / ports / toasts, app menu, pinned panel, home page and catalogue smoke tests.

**Review.** 30 findings (high 1, medium 7, low 14, false 5, maybe-false 3). Patched: the read retry loop (high); undo-stack naming, `jj redo` parity, the untested HomePage host (medium); non-jj failure message, root row `root()`, snapshot opacity on buttons, `didUpdateWidget`, missing view tests (low). Deferred: catalogue visual check, the runner hand-off to 10.12 (plus the three implementation deferrals in frontmatter). Rejected with reasons in the triage log: root-parent guard vs CLI (epics design decision), merge/cross-workspace pre-checks, restore toast summary, short id to the verb, VoiceOver label extras, Show changes dead control, `GraphLoggedOperation` design, queued-page drop, railItems drop (false), I1 parity reading, Auto Run Result/bridge (false).

**Follow-up review recommended: true** — one `high` was patched (the read loop), and the `jj undo`/`jj redo` stack targeting (`undoTarget`/`redoTarget`) was added during review and is checked only by unit and widget tests against fakes, never against a real repository's undo/redo descriptions. Patched counts: high 1, medium 3, low 6 (grouped entries).

**Residual risks.** No runner in the real project window until 10.12 (actions disabled there); the visual DS comparison has not been made; the full gate (`cargo make test`) runs at the end of the story loop.
