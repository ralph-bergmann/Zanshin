---
title: 'Story-loop leftovers 2026-11-01: stack arrow keys, calm ends on a hold, failed opens show Projects, pending-stack test'
type: 'feature'
created: '2026-11-01'
status: 'done'
baseline_revision: 'cb46d3218fca6a9600250207d32eb39b6673945e'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      A Project menu Recent row whose path is now a Git repository, a plain folder or inside a repository, or whose open is refused, still shows nothing.
    evidence: |-
      `HomePage._openRecent` reports only `ProjectOpenFailed` and `ProjectNotARepo(pathNotFound)` (the intent's "on a failure" plus the missing path); the Projects window offers convert / init for the others. Pre-existing: before this run the Recent row ignored every outcome. A registered jj entry only turns into one of these when its `.jj` is removed outside Zanshin.
    location: >-
      app/lib/src/features/home/home_page.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** Four items Ralph decided after the story loop 10.7 10.8 10.17 10.21 10.23 5.8 (console session 2026-11-01): commit stacks have no keyboard collapse; a surface hold taken during a calm phase leaves the chrome faded; a failed open from the Project menu's Recent or from reopen-last at launch shows nothing; no test renders a pending folded member dimming its stack card.

**Approach:** (1) ← / → in the graph follow the macOS outline convention for stacks; (2) `CalmController.hold()` ends a running phase; (3) the session carries a failed open made outside Projects (`failedOpen`), the Recent row hands its failure (or missing folder) there and opens Projects, reopen-last hands its failure there, and the Projects window shows it with its existing notice; (4) one canvas test.

## Boundaries & Constraints

**Always:** reuse the existing paths — `GraphCardController.onCollapseStack` / `onExpandStack` (the bracket button's and Enter's), the Projects window's `_handle` notice and copy (`projectsOpenFailed`, `projectsPathMissing`); the open project stays on a failed Recent open.

**Never:** new design, toast or l10n strings; arrow bindings beyond stacks; touching any finished story's spec beyond the 10.17 `deferred:` item's `resolved:`; the full gate (`cargo make test`).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| ← on member | focus on a member of an expanded run | the run collapses (one request), focus on its stack card | — |
| → on stack | focus on a collapsed stack card | it expands (one request), nothing selected | — |
| other arrows | ← on a stack card, → on a member, ←/→ on a card outside any run | nothing; key ignored | — |
| hold mid-phase | calm phase running, `hold()` | phase is `CalmPhase.rest` at once, its wait cancelled; counting blocked until release | — |
| Recent fails | Recent row, open throws | Projects opens with "Could not open ‹name›" + context + warnings; current project stays | — |
| Recent missing | Recent row, path gone | Projects opens with "‹path› does not exist." | — |
| Recent opens | Recent row, open succeeds | no Projects, nothing reported | — |
| Reopen fails | stored project, open throws at launch | Projects (shown since none open) shows the failure notice | a missing stored folder reports nothing (unchanged) |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_view.dart` -- `_onKey` (Esc/Enter/Space only before); `_focusChanged` already moves a folded focus key to its stack card.
- `app/lib/src/features/graph/graph_canvas.dart:426-462` -- `_runOfKey`, `_expandStack`, `_collapseStackOf` (no-op unless the key's run is expanded) wired as `cards.onExpandStack` / `onCollapseStack`; `:773` maps `pendingKeys` through `placeOfKey`.
- `app/lib/src/features/graph/graph_layout.dart:295-327` -- `runOf`, `stackNodeOf`, `isStackNode`, `isFolded`, `placeOfKey`.
- `app/lib/src/features/shell/calm_controller.dart` -- `hold()`, `_end()`, class doc rule.
- Hold takers (all through `hold()`): `shell_controller.dart` `openSurface` (Project capsule, 10.7 graph controls, 10.21 search), `startItemDrag`, `edgeDragStarted`, flyout and preview holds — all run from event handlers or listeners, never from build, so the synchronous notify is safe.
- `app/lib/src/features/projects/project_session.dart` -- `openReport`/`takeOpenReport` pattern (10.23) mirrored as `failedOpen`/`reportFailedOpen`/`takeFailedOpen`; `reopenLast`.
- `app/lib/src/features/projects/projects_window.dart` -- `_handle(outcome, path, placement)` renders the notice; `initState` subscribes.
- `app/lib/src/features/home/home_page.dart` -- `_place` → `ProjectCapsule.onOpen`; `AppWindowActionsScope.maybeOf(context)?.openProjects()`.
- `app/lib/src/features/window/app_window_coordinator.dart` -- unchanged: a failed reopen leaves no project open, so `_shown` already shows Projects.

## Tasks & Acceptance

**Execution:**
- [x] `app/lib/src/features/graph/graph_view.dart` -- ← / → branch in `_onKey` -- item 1.
- [x] `app/test/features/graph/graph_stacks_test.dart` -- → / ← on stack, ← / → on member, arrows on a plain card; pending folded member dims its stack card -- items 1, 4.
- [x] `app/lib/src/features/shell/calm_controller.dart` + `app/test/features/shell/calm_controller_test.dart` -- `hold()` calls `_end()`, doc rule replaced, test pins the new rule -- item 2.
- [x] `app/lib/src/features/projects/project_session.dart` -- `ProjectFailedOpen`, `failedOpen`, `reportFailedOpen`, `takeFailedOpen`; `reopenLast` reports a `ProjectOpenFailed` -- item 3.
- [x] `app/lib/src/features/projects/projects_window.dart` -- listens to `failedOpen` and takes it post-frame on mount, through `_handle` -- item 3.
- [x] `app/lib/src/features/home/home_page.dart` -- `_openRecent`: failure or missing path → `reportFailedOpen` + `openProjects` -- item 3.
- [x] tests: `project_session_test.dart`, `projects_window_test.dart`, `home_page_test.dart`, `app_window_coordinator_test.dart` -- item 3, both entry points.

**Acceptance Criteria:**
- Given the graph has keyboard focus, when ← / → are pressed, then the matrix rows "← on member", "→ on stack", "other arrows" hold.
- Given a calm phase is running, when any surface hold is taken (e.g. the Project menu opens by keyboard), then the chrome is at rest at once and the menu opens at full opacity.
- Given a failed open from the Project menu's Recent or from reopen-last, when it fails, then the Projects window shows the same notice an open from Projects shows.
- Given a stack whose folded member is pending, when the canvas paints, then the stack card is at `disabledOpacity`.

## Spec Change Log

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 20 findings — high 0, medium 1, low 13, false 6, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) a failed Recent open with no actions scope stays pending and shows stale later — `_openRecent` reports only `when windows != null`.
  - `[low]` `[reject]` (blind) `reportFailedOpen` accepts any outcome — both callers pass only a failure or a missing path; a type split adds surface for no reachable harm.
  - `[low]` `[defer]` (blind) Recent ignores Git / plain-folder / inside-repo / refused outcomes — pre-existing (the row ignored every outcome) and outside "on a failure"; deferred in frontmatter and the ledger.
  - `[false]` `[reject]` (blind) the `_failedOpen` listener re-enters on take without a null guard — the re-entry takes null and does nothing; no bad outcome.
  - `[medium]` `[patch]` (blind) ←/→ do nothing after a press (pointer focus hides the focus card) — the arrow branch reveals the focus card first as Enter does; test added.
  - `[low]` `[reject]` (blind) ←/→ ignore modifiers — Enter/Space ignore them too; a modifier guard is new branching for an unrequested binding.
  - `[low]` `[patch]` (blind) `_onKey`'s doc comment omits ←/→ — updated.
  - `[low]` `[patch]` (blind) `hold()` outside a phase zeroes the counted sum — `_end()` only while calm; test added.
  - `[low]` `[reject]` (blind) no shell-level test of a menu opening at full opacity mid-phase — every taker goes through `hold()`, the shell fades by `calm.value`, and the unit test pins `rest` at the hold.
  - `[false]` `[reject]` (blind) ← on a member of a collapsed run would collapse again — the branch checks `stackNodeOf(run) == null` and `_collapseStackOf` guards the same.
  - `[false]` `[reject]` (blind) the spec is marked finished before review — status was `in-review` at review time, as the workflow sets it.
  - `[low]` `[patch]` (edge) arrows after a pointer press — same entry as the blind medium; same fix.
  - `[low]` `[reject]` (edge) modifier arrows swallowed — as the blind row.
  - `[low]` `[defer]` (edge) Recent non-failure outcomes give no feedback — as the blind row.
  - `[low]` `[patch]` (edge) stale pending report without a scope — as the blind row.
  - `[false]` `[reject]` (edge) `takeFailedOpen` after the session's dispose — the session lives for the app; the window removes its listener on dispose and the post-frame call checks `mounted`.
  - `[false]` `[reject]` (edge) two reports before a take drop the earlier — at launch Projects shows and takes the reopen failure before a Recent row exists (no project is open); last-wins is the intended one-notice shape.
  - `[low]` `[patch]` (verification-gap, other) a hold zeroes a sub-threshold sum — as the blind row.
  - `[low]` `[reject]` (verification-gap, other) no single test runs reopen failure through to the rendered notice — the two halves are tested at the notifier contract (coordinator test + projects window mount test); an end-to-end rig needs the real Projects content in the coordinator test.
  - `[false]` `[reject]` (intent-alignment) item 4's test sits in `graph_stacks_test.dart`, not `graph_view_test.dart` — the intent asks for "a one-case canvas test"; the location was context.

## Design Notes

- Item 3's missing-path case ("keeps today's handling of `ProjectNotARepo(pathNotFound)` as the Projects window does"): read as the Projects window's own handling — the `projectsPathMissing` notice — so the Recent row shows Projects with it too; the registry still marks the entry missing (session, unchanged). Reopen-last's missing folder stays silent (the intent names failures; Projects shows anyway since nothing opened).
- `failedOpen` is a `ValueNotifier` taken once (as 10.23's `openReport`): a Projects window already open hears it at once, one opened by the report takes it after its first frame.

## Verification

**Commands:**
- `flutter test` (app/) -- expected: all pass; the 5 `worker_project_repos_test.dart` real-worker cases need `XDG_CONFIG_HOME` pinned (cargo make sets it) and pass with it.
- `dart analyze lib test` (app/) -- expected: no issues.
- `dart format --set-exit-if-changed lib test` (app/) -- expected: exit 0.

**Verification notes (2026-11-01, gate rule: no `cargo make test`):**
- `flutter test` (app/, whole suite, before the review patches): 1397 passed, 5 failed — the `worker_project_repos_test.dart` real-worker cases refuse to run without `XDG_CONFIG_HOME=<repo>/target/test-xdg-config`; rerun with it: 33/33 passed (failing identically on the clean baseline without it).
- After the review patches: `flutter test test/features/graph` 545 passed; `test/features/shell` + `graph_view_test.dart` 138 passed; `projects_window_test.dart` + `test/features/home` 91 passed; `project_session_test.dart` + `test/features/window` 99 passed.
- `dart analyze lib test`: no issues. `dart format --set-exit-if-changed lib test`: exit 0.
- No Rust, FFI or schema touched: no cargo checks apply. Not done: a Marionette check in the running app.

## Auto Run Result

Status: done

1. Keyboard collapse/expand for stacks — fixed (cc4065b077ee3137f119ce366a3945913b943f07): ← on a focused member of an expanded run collapses it (focus moves to the stack card), → on a focused stack card expands it; anything else ignored; after a press the focus card is revealed first, as Enter does.
2. Calm phase ends on a hold — fixed (cc4065b077ee3137f119ce366a3945913b943f07): `CalmController.hold()` ends a running phase at once (doc rule replaced, test pins `CalmPhase.rest`); a hold outside a phase keeps the counted sum. Callers (capsule, graph controls, search, item drag, edge drag, flyout, preview) all take holds from event handlers or listeners, so the synchronous notify is safe; their suites pass.
3. Failed opens outside Projects — fixed (cc4065b077ee3137f119ce366a3945913b943f07): `ProjectSession.failedOpen` (`reportFailedOpen` / `takeFailedOpen`); the Recent row reports a failure or a missing folder and opens Projects (the open project stays); `reopenLast` reports a failure; the Projects window shows it through its existing `_handle` notice, live or after its first frame.
4. Pending folded member dims its stack card — fixed (cc4065b077ee3137f119ce366a3945913b943f07): canvas test in `graph_stacks_test.dart`.

Files: `app/lib/src/features/graph/graph_view.dart` (←/→), `app/lib/src/features/shell/calm_controller.dart` (hold ends a phase), `app/lib/src/features/projects/project_session.dart` (failedOpen), `app/lib/src/features/projects/projects_window.dart` (shows it), `app/lib/src/features/home/home_page.dart` (Recent reports + opens Projects); tests in `graph_stacks_test.dart`, `calm_controller_test.dart`, `project_session_test.dart`, `projects_window_test.dart`, `home_page_test.dart`, `app_window_coordinator_test.dart`.

Review: 20 findings — 4 patch entries (1 medium: arrows after a press; 3 low: hold zeroed a sub-threshold sum, stale report without a scope, stale `_onKey` doc), 1 deferred (Recent non-failure outcomes, low), rest rejected with reasons in the triage log. Follow-up review recommended: false (one medium patched, covered by a new test).

Residual risks: no end-to-end test from a failed reopen to the rendered notice (the two halves are tested at the notifier); not checked in the running app.
