---
title: "Story 10.5 — Graph view model and repository wiring: ports, reload per operation, anchoring, re-centring on @, states, the stale notice, one \"now\""
type: 'feature'
created: '2026-10-30'
status: 'done'
baseline_revision: '8bf86fb515db4a3b8d0f523213245e2f3daaa889'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The view model use case and the stale notice were not checked visually (Marionette) in the running catalogue.
    evidence: |-
      The unattended run cannot hold a `flutter run -d macos -t widgetbook/main.dart` session; widget tests cover the notice, the view's insets, centring, anchoring, calm reports and states, and the smoke test pumps both use cases.
    location: >-
      app/widgetbook/folders/graph.dart
    severity: low
    resolved: >-
      2026-10-31 — fixed (console session, Marionette; spec-fix-10-2-10-5-review, commit 20b5b0d): the notice matches stale.card.html; the View model use case lost its model on every knob change (Widgetbook keys a use case on its route) and now keeps it.
  - summary: >-
      The empty and failed-load captions are Claude's proposal for design question (d); the DS has no design for them.
    evidence: |-
      `GraphView` centres "No changes match this revset." or "The graph could not be loaded (<code>)." with a quiet Retry; loading shows nothing; `degraded` and the warnings are not shown (10.23, design question (e)).
    location: >-
      app/lib/src/features/graph/graph_view.dart
    severity: low
    resolved: >-
      2026-10-31 — accepted (Ralph): the captions stay as proposed.
  - summary: >-
      The stale notice's three jj messages and hint commands are Dart copies of the CLI's text at v0.46.0 that no oracle or pin-bump step keeps in step.
    evidence: |-
      `GraphStale.fromContext` composes them from `cli_util.rs:3040-3075` @ v0.46.0; the parity oracle runs verbs, not this text, and the pin-bump steps do not name it. The error's `hints` (Story 9.56) carry jj's hint verbatim but not the message.
    location: >-
      app/lib/src/features/graph/graph_view_model.dart (GraphStale.fromContext)
    severity: low
    resolved: >-
      2026-10-31 — fixed (spec-fix-10-2-10-5-review, commit 20b5b0d): the Rust error carries jj's message (PreconditionError::message), Dart shows it (GraphStale.fromError); an oracle test checks the `stale` cause.
  - summary: >-
      Parts of epics 10.5 item 14 are handed on, not built: @'s off-screen direction (10.6's pill), the inspector's scroll for a covered selection and the inspector witnesses (10.8), and the plane's extra margins (dropped as Claude's proposal).
    evidence: |-
      Recorded only in the epics.md "Built 2026-10-30" note under Story 10.5; 10.6 item 6 and 10.8 read them as 10.5's. The top inset 60/68 and collapse witnesses are 11.3's shell (done there).
    location: >-
      app/lib/src/features/graph/graph_view.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** The graph (10.1–10.4) runs only on static recorded layouts inside the catalogue. Nothing requests layouts, reloads on jj operations, keeps the view anchored across swaps, re-centres on @, survives selection, reports load/revset/stale states, or owns the clock the cards and the day axis read. The stale-working-copy notice and its 9.23 action do not exist.

**Approach:** Build epics.md Story 10.5 (`_bmad-output/planning-artifacts/epics.md:9148-9328`, with its 2026-09-27/28/30, 2026-10-14 and 2026-10-16 notes) on fake ports: `GraphSource`/`GraphActions` ports and `GraphRequest`, a `GraphViewModel` (coalesced reloads, scroll precedence, selection, states, stale, one "now"), a `GraphView` widget that binds it to the viewport composition (moved from the catalogue into `lib`) with the shell's insets and calm reporting, the `StaleNotice`, a real `RepoGraphSource` over `ProjectRepo` (layout still recorded until 10.12), and the catalogue use case. Settles the dispatch's open items I1–I7.

## Boundaries & Constraints

**Always:**
- **Ports** (`graph_ports.dart`): `GraphRequest` (immutable, `==`): `revset`, `mode` (`GraphMode`, default free), `order` (`GraphLaneOrder`, default compact), `prioritize`, `shortPrefixes`, `anchors`, `utcOffsetMin`, `stacks` (false), `expandedKeys`/`collapsedKeys`/`keepOpenKeys` (empty); no card W/H, no "now". `GraphSource`: `Future<GraphLoad> layout(GraphRequest)` (`GraphLoad` = layout + warnings + `Precondition?`), `Stream<RepoEvent> get events`, `Future<LogDefaults> logDefaults()`, `Future<StaleRecovery> updateStale()`. `GraphActions`: `Future<GraphActionResult> run(GraphAction)` (`GraphAction(verb, {ids, parameters})`; sealed result `GraphActionDone` | `GraphActionRefused(reason)`); no real implementation (10.9).
- **Request pre-fill:** `revset` = `logDefaults().log` (the "jj log" preset) until `setRevset`; `prioritize` = `.logGraphPrioritize`, `shortPrefixes` = `.shortPrefixes`, `anchors` = zanshin_core's `defaultGraphAnchors` — passed explicitly; `utcOffsetMin` from the clock's local offset at issue time; `keepOpenKeys` = the selection plus a pending explicit reveal key.
- **Reload:** on every `OpHeadsChangedEvent` of the source, on `reload()` (10.9 calls it after a mutation; `run` calls it after `GraphActionDone`), on `retry()`, on `configChanged()` (item 16: re-read `logDefaults`, a request still on the old `log` follows the new one, no re-centre), and — only while stale — on `WorkingCopyHeartbeatEvent`. At most one request in flight plus one queued; the queued one is built from the state when it starts (latest wins); a result whose request was superseded by a queued one is dropped.
- **Scroll precedence** (item 6), resolved when a layout lands, as one `GraphReveal` handed to the viewport together with the layout (same relayout): (1) an explicit reveal (`reveal(key)`, `setRevset(.., reveal:)`, `scrollToWorkingCopy()`, `scrollToSelection()`), (2) the re-centre on @ of the first layout and after `setRevset`/`setMode`/`setLaneOrder` (jump, no animation), (3) the viewport's anchor. Pending (1)/(2) survive a superseded request and are cleared once a layout lands (never re-armed). An absent key falls back to the anchor (10.1). Explicit reveals while no request is pending apply at once. `scrollToSelection` without a selection does nothing; neither scroll target changes the selection.
- **Anchor node** (design question (a), Claude's proposal accepted in the epic): the viewport keeps `anchorKey` = the selection only while its card meets the viewport; otherwise the visible node nearest the centre. Vanished anchor (b, Claude's proposal): the offsets stay (10.1's behaviour, clamped). External ops moving @ (f, Claude's proposal): the anchor holds; the view does not follow @.
- **Selection** keyed by node key; `null` when a landed layout lacks the key.
- **States:** `loading` (no layout yet, a request in flight); empty (`shownCount == 0`, not an error); `revsetError` (`jj.revset_parse_error`/`jj.revset_resolution_error`: keep the last layout, expose the exception); `error` (any other failure, last layout kept, `retry()`); `stale` (`jj.stale_working_copy`, see below); `degraded` (a `WatchErrorEvent`'s message); `warnings` and `lastPrecondition` of the last landed load; `shown`/`total` from the layout's `shownCount`/`totalCount`. A successful load clears revsetError, error and stale.
- **Stale** (2026-10-16 item 9): project-level `GraphStale` parsed from the context `<cause>\n<wc_op>\n<repo_op>`: cause `stale` → message "The working copy is stale (not updated since operation <wc12>).", command `jj workspace update-stale`; `sibling_operation` → "The repo was loaded at operation <repo12>, which seems to be a sibling of the working copy's operation <wc12>", command `jj op integrate <wc12>`; `operation_not_found` → "Could not read working copy's operation.", command `jj workspace update-stale` (cli_util.rs:3040-3075 @ v0.46.0; `<x12>` = the first 12 hex). The last layout stays; cold start has none. `updateStale()`: busy while it runs, keeps the `StaleRecovery` as `lastStaleRecovery`, then reloads; a failure is kept as `staleUpdateError` and logged (code only); no Undo is offered.
- **`StaleNotice`** (DS components/overlays/StaleNotice.{prompt.md,jsx}, overlays.css:62-68): `ZsIsland` pill 44 high, the `conflict` icon in `--warn`, "Working copy is stale" (`--text` 500), "·" (`--text-faint`), the command mono `--text-muted`; with an update action: a quiet md `ZsButton` "Update working copy" (icon `fetch`, tooltip = `jj workspace update-stale`, `busy`); without one: an icon-only Copy button (tooltip "Copy — <command>") that writes the command to the clipboard. jj's cause message is the sentence's tooltip and in the semantics label (Claude's proposal). Role status (`Semantics(liveRegion: true)`), a Tab stop. The action is offered for every cause (9.23's `update-stale` recovers all three). The shell's slot positions and fades it.
- **One "now"** (I7, item 12): the view model owns `now` (`ValueListenable<int>`, epoch ms): set fresh on every landed layout and on `refreshNow()`, and ticked on each minute boundary (a timer aligned to the next minute, so local midnight at any whole-minute offset is hit on time). `GraphView` copies it into its `GraphCardController.now`, calls `refreshNow()` when its window turns active (`ZsAppearance.inactive` true → false), and rebuilds the day-axis painter only when the local day of `now` at the layout's `utcOffsetMinutes` changes.
- **Insets and calm** (I3): `GraphView` takes `ShellScope.insetsOf(context)` when inside a shell (else its `insets` parameter) as the viewport's `EdgeInsets(left, top, right, bottom)`; the day labels follow the left inset. It reports canvas mouse pans (`|dx| + |dy|` per move, a new `onUserPan` on `GraphViewport`) and fling glides (per axis, `ScrollUpdateNotification`s without `dragDetails` that follow ones with `dragDetails`, until that axis's `ScrollEndNotification`) through `ShellScope.maybeOf(context)?.reportUserScroll`. Wheel and trackpad pans stay the shell's (no double count); programmatic scrolls are never reported.
- **Handle** (I4): the app's source is `RepoGraphSource(ProjectRepo repo, {required layout})` over `ProjectSession.repo`; `ProjectRepo` gains `Stream<RepoEvent> get events` (the worker's events of its handle). `layout` is a passed function (recordings or a fake until 10.12).
- **Bridge (I1/I2):** the barrel already exports `RepoHandle`, `OpenedRepoHandle`, `CreatedRepoHandle`, `Precondition`, `ZanshinFfiException`; add `LogDefaults` and `defaultGraphAnchors`.

**Never:** any layout computation or Rust/FFI change (our workspace name on the wire is 10.12's, as the epic allows); a refresh policy for plain file edits (design question (c) stays Ralph's); the @ off-screen direction for the pill (10.6), the inspector's covered-selection scroll (10.8), the result/error toasts and where warnings show (10.23), stacks toggles (10.17), the previous layout for transitions (10.20), real actions (10.9); wiring the graph into `HomePage` (10.12's real-repo host); touching `graph_poc/`, `main2/3/4.dart`, `features/commits/`; golden tests.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| First load | fake defaults `log='L'`, `prioritize='P'`, `shortPrefixes='S'` | request revset L, P, S, anchors `['trunk()','present(@)']`; @ centred, no animation | — |
| Burst | 3 events while a load runs | exactly one more request; the in-flight result dropped | — |
| Own snapshot | the source emits one event during the first layout call only | 2 requests total, then quiet | — |
| Revset error | `jj.revset_parse_error` after a layout | layout kept, `revsetError` set, no retry state | cleared on next success |
| Empty | layout with 0 nodes | empty state, not error | — |
| Other error | `jj.io_error` | `error` set, last layout kept; `retry()` requests once | — |
| Stale at open | logDefaults ok, layout throws stale `sibling_operation\n<wc>\n<repo>` | no layout, `stale` with `jj op integrate <wc12>` | heartbeat → reload; success clears |
| Update stale | `updateStale()` | busy, then `lastStaleRecovery`, one reload | failure → `staleUpdateError`, still stale |
| Switch + reveal | `setRevset('all()', reveal: 'k')` | the landed layout carries a reveal of `k`, not @ | `k` absent → anchor |
| Width change | new metrics right after load | no request, no reveal of @ | — |
| Edit moves @ | an event after `jj edit` | reload without a reveal | — |
| Selection | selected key absent in new layout | `selected == null` | — |
| Watch error | `WatchErrorEvent('x')` | `degraded == 'x'` | — |
| Config changed | `configChanged()` | logDefaults re-read, exactly one request, no reveal | — |
| Midnight | now 23:59:30 local | the next tick at 00:00:00 updates `now` | — |

</intent-contract>

## Code Map

- `_bmad-output/planning-artifacts/epics.md:9148-9328` -- Story 10.5 and its notes; witnesses :9186-9192, :9217-9226, :9314-9328.
- `packages/zanshin_core/lib/zanshin_core.dart` -- barrel; `LogDefaults` in `src/ffi/log_defaults.dart:36`; `defaultGraphAnchors` in `src/ffi/graph.dart:67`. `RepoHandle.logDefaults` (`src/worker/handle.dart:416`), `.workspaceUpdateStale` (:2303), `.describe` (:529). Events: `src/worker/events.dart` (`OpHeadsChangedEvent`, `WorkingCopyHeartbeatEvent`, `WatchErrorEvent`). `ZanshinFfiException` (`src/worker/responses.dart:102`: `code`, `context`, `warnings`, `precondition`, `hints`, `revsetError`). `StaleRecovery` (`src/ffi/workspace.dart:205`).
- `app/lib/src/features/projects/project_repos.dart:45-58` -- `ProjectRepo` (add `events`); `worker_project_repos.dart:75-89` (`_WorkerProjectRepo.changes` filters `worker.events` by `handleId` — `events` is the unfiltered-by-kind version); fakes `app/test/helpers/fake_projects.dart:107` (`FakeProjectRepo`) and `app/widgetbook/demo_projects_fakes.dart:145` (`_DemoRepo`).
- `app/lib/src/features/projects/project_session.dart:136-137,438-459` -- `repo` (the handle 10.5 reads) and `_refresh` (I5: readings per op-heads event, coalesced 1+1).
- `app/lib/src/features/shell/shell_scope.dart:27,38,46` -- `insetsOf`, `of`, `maybeOf`; `shell_controller.dart` `reportUserScroll(double)`; `calm_controller.dart` (30 px threshold, 650 ms); `graph_insets.dart`; `floating_shell.dart:118,210-220,346-360` (the `staleNotice` slot positioned and faded by the shell; the shell's own wheel/trackpad counting).
- `app/lib/src/features/graph/graph_viewport.dart:30-58` -- `GraphViewport` (add `onUserPan`); `graph_viewport_render.dart:44-91` (`GraphReveal` by identity, `GraphViewportController`), :366-422 (layout pass: anchor then reveal), :441-472 (`_applyAnchor`, `_recordAnchor` — gate `anchorKey` on visibility here), :496 pan handlers (`_updatePan`).
- `app/lib/src/features/graph/graph_layout.dart:174-307` -- `GraphLayout` (`nodeCount`, `keyOf`, `indexOfKey`, `workingCopyIndex`, `shownCount`, `totalCount`, `utcOffsetMinutes`), `GraphMode`, `GraphLaneOrder`, `GraphViewOptions`.
- `app/lib/src/features/graph/graph_card.dart:17-65` -- `GraphCardController` (`now`, `selected`, `hovered`); `day_axis.dart` (`GraphDayAxisPainter(axis, theme, nowMs, utcOffsetMinutes)`); `graph_edges.dart` (`GraphRouteCache`, `GraphEdgePainter`, `GraphEdgeHighlight`).
- `app/widgetbook/folders/graph.dart:162-302` -- `_GraphDemo`/`_GraphDemoState`: the composition (rows, axis, route cache, edges, cards, minute tick) that moves into `lib` as `GraphCanvas`; `recordedLayout(sample, options)` :126 — recordings exist for `design-default`, `design-all`, `design-cli-default`, `medium-narrow` × `free|compact` × `compact|greedy`.
- `app/test/widgetbook/catalogue_smoke_test.dart` -- must pump the new use case; `app/test/features/projects/worker_project_repos_test.dart:275-300` -- real-worker test pattern (`ZanshinWorker.start()`, `worker.initRepo(path, backend: 0)`, temp dirs).
- `packages/zanshin_ui`: `ZsIsland`, `ZsButton` (`variant: quiet`, `size: md`, `icon`, `busy`, `iconOnly`), `ZsTooltip`, `ZanshinIcon`, `ZsColors` (`warn`, `text`, `textFaint`, `textMuted`), `ZsType`.
- Open items: `_bmad-output/implementation-artifacts/deferred-work.md` (I1 Story 9.33 section, I2 Story 9.35 section, I3/I4/I5 "Surfaced in Story 11.3/11.5", I6 "Surfaced in Story 9.23", I7 "Surfaced in Story 10.2").

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_core/lib/zanshin_core.dart` -- export `LogDefaults` and `defaultGraphAnchors`.
- `app/lib/src/features/projects/project_repos.dart`, `worker_project_repos.dart`, `app/test/helpers/fake_projects.dart`, `app/widgetbook/demo_projects_fakes.dart` -- `ProjectRepo.events`.
- `app/lib/src/features/graph/graph_ports.dart` (new) -- `GraphRequest`, `GraphLoad`, `GraphSource`, `GraphAction`, `GraphActionResult`, `GraphActions`, `RepoGraphSource`.
- `app/lib/src/features/graph/graph_view_model.dart` (new) -- `@inject GraphViewModel` with `init(GraphSource, {GraphActions? actions, DateTime Function()? clock})`, `GraphStale`, the behaviour above; `dispose` cancels the subscription and timers.
- `app/lib/src/features/graph/graph_viewport.dart`, `graph_viewport_render.dart` -- `onUserPan`; `anchorKey` only while its card meets the viewport.
- `app/lib/src/features/graph/graph_canvas.dart` (new) -- the composition moved from `_GraphDemo` (layout, options, insets, `now`, cards controller, reveal, anchorKey, `onUserPan`), its per-layout caches, the day-axis painter keyed by local day, fling reporting.
- `app/lib/src/features/graph/graph_view.dart` (new) -- binds a `GraphViewModel`: insets from `ShellScope` (or a parameter), calm reports, selection ↔ card controller, `now` sync, focus refresh, a centred empty / error (with a quiet Retry button) caption in the visible area (Claude's proposal for design question (d)); `staleNotice(...)` builder for the shell slot.
- `app/lib/src/features/graph/stale_notice.dart` (new) -- `StaleNotice`.
- `app/widgetbook/folders/graph.dart`, `app/widgetbook/graph/fake_graph_source.dart` (new) -- Recording/Scale use `GraphCanvas`; new "Viewport / View model" use case on a `FakeGraphSource` over the recordings (`jj log` → `design-default`, `all()` → `design-all`) with knobs revset, layout, lane order, card width, detailed, insets, stale cause; the notice shown over it; a "Stale notice" use case with both variants.
- Tests (new): `app/test/features/graph/graph_view_model_test.dart` (the matrix and witnesses on fake ports, `fake_async`), `graph_view_test.dart` (insets from a `ShellScope`, pan/fling reports, now sync, selection, centring in one relayout), `stale_notice_test.dart`, `graph_ports_test.dart` (real worker: a `describe` through the handle → exactly one new layout request; `RepoGraphSource` events filtered by handle); update `catalogue_smoke_test.dart`, `graph_anchor_test.dart` (visible-only anchor key).
- I5 measurement (temporary script/test, not committed): a temp repo open through the worker, readings on every op-heads event as `ProjectSession` does, a burst of ≥ 30 CLI `jj describe`/`jj new` with file edits; count `divergent()` changes and concurrent operations afterwards. Debounce the view model's event reloads and `ProjectSession._refresh` (trailing, Claude's proposal 150 ms) only if @ diverges; record the numbers.
- `_bmad-output/planning-artifacts/epics.md` -- a dated "Built 2026-10-30" note under Story 10.5 reconciling items 1, 13–15 (I3, I4) and naming what went to 10.6/10.8/10.12/10.23; `deferred-work.md` -- "Resolved in Story 10.5" sub-bullets on I1–I7.

**Acceptance Criteria:**
- Given the fake source, when the view model initialises, then the first request passes `prioritize` and `shortPrefixes` from `logDefaults` and `anchors` from `defaultGraphAnchors`, and the first layout carries a non-animated reveal of @.
- Given a selected card visible on screen, when a reload adds a head, then the selected card keeps its screen position; given it scrolled off screen, when a reload adds a head, then the centre card keeps its position instead.
- Given `GraphView` inside a `ShellScope` whose insets change (pin, edge drag), when it rebuilds, then no card moves on screen and the viewport's insets equal the scope's.
- Given `GraphView` in a shell, when the user pans the canvas 40 px with the mouse, then the shell controller received ≥ 30 px of user scroll and calm turned on; when a reveal scrolls programmatically, then nothing is reported.
- Given a revset switch with @ present, when its layout lands, then @ is centred in that same relayout; when a card-width change or an event-driven reload follows, then no further centring happens.
- Given `jj.stale_working_copy` for each of the three causes, when `GraphView` and its notice build, then the notice shows "Working copy is stale" and the cause's command, its tooltip carries jj's message, it offers "Update working copy", and content requests (the cards) still render the last layout.
- Given the real worker, a temp repo and a `RepoGraphSource` with a counting fake layout, when `describe` runs through the handle, then exactly one new layout request follows.
- Given the catalogue, when every Graph use case is pumped, then none throws.

## Spec Change Log

## Review Triage Log

### 2026-10-30 — Review pass
- verdicts: 37 findings — high 0, medium 0, low 24, false 12, maybe-false 1 (blind 13, edge 11, verification-gap 4, intent-alignment 9)
- findings:
  - `[low]` `[reject]` (blind #1) A layout or `logDefaults` that throws anything but `ZanshinFfiException` escapes `unawaited(_run())` with no error state. Every source call answers through the worker, which throws only `ZanshinFfiException`; the one other throw, a closed handle's `StateError`, needs a host that keeps a model on a closed handle, and 10.12's host owns that lifecycle. The fix is a new catch branch with an invented error code.
  - `[false]` `[reject]` (blind #2) "`revsetError` has no UI and no owner." The epic's 2026-10-14 note names the owner: 10.21 shows the revset error in the search field (10.7 design question (c)); 10.5 exposes it.
  - `[low]` `[patch]` (blind #3) The on-screen check of the anchor key used the whole viewport, so a selection covered by the inspector or the rail still anchored. Patched: the check uses the unobscured area (inside the insets); a test shows a covered selection gives way to the centre node. The centre fallback's full-viewport centre is 10.1's pre-existing rule.
  - `[false]` `[reject]` (blind #4) "`fake_async` became a direct dev dependency without a refreshed `pubspec.lock`." The workspace keeps one lock at the repo root, and pub marks only the root package's own dev dependencies as direct; `flutter pub get` leaves the lock unchanged, so it already records `fake_async` correctly.
  - `[low]` `[reject]` (blind #5, grouped with edge #7) A null or short stale context gives a sentence without an op id. The Rust side always emits the three lines (docs/rust-error-codes.md, `jj.stale_working_copy`); a malformed context is not reachable.
  - `[low]` `[defer]` (blind #6) The three jj messages are Dart copies of cli_util.rs at v0.46.0 that no oracle or pin-bump step keeps in step. Deferred (frontmatter, deferred-work.md "Surfaced in Story 10.5"): the fix edits the pin-bump steps in project-context.md (agent context).
  - `[low]` `[reject]` (blind #7, grouped with edge #5) No guard against calls before `init` or a second `init`. A call before `init` fails loudly (`LateInitializationError`); a host calls `init` once through `ViewModelFactory`'s `init:`.
  - `[low]` `[patch]` (blind #8, grouped with edge #2 and verification-gap other #1) A model disposed while `logDefaults()` is pending still called `layout` once. Patched: `_run` returns after that await when disposed; a test witnesses it.
  - `[low]` `[reject]` (blind #9) A reveal registered during an in-flight request is not in that request's `keepOpenKeys`. Without stacks (10.17) the key changes nothing; 10.17 owns the stack-opening reveal.
  - `[false]` `[reject]` (blind #10, grouped with edge #9) "A pan pinned at an extent still counts toward calm." The epic's item 15 defines the count as the pointer's movement ("A canvas pan adds the pointer's movement"), which is what is reported.
  - `[false]` `[reject]` (blind #11) "The sibling notice names one command and runs another; Copy never appears." The notice shows the command of jj's hint for the cause, and "Update working copy" runs `jj workspace update-stale`, which recovers all three causes (cli_util.rs:681-682, :751-763 @ v0.46.0); the DS's StaleNotice.jsx shows the action in place of Copy. Both are the spec's stated rules.
  - `[low]` `[patch]` (blind #12) The "every kind" ports test showed only an op-heads event. Patched: a working-copy heartbeat of the handle is shown arriving through `RepoGraphSource.events`. The 600 ms settle window was not seen to flake in any run (not acted on).
  - `[false]` `[reject]` (blind #13) "deferred-work says 10.5 reads `ShellScope.insetsOf`, the code does not." The line cited is the original follow-up; the "Resolved in Story 10.5 (I3)" note says the view takes the scope's `GraphInsets`. `insetsOf` asserts a scope, and the view also runs outside a shell, so it reads the scope directly.
  - `[low]` `[patch]` (verification-gap #1) The GraphView-level anchor test could not tell the selection from the centre card (every card shifted by one pitch). Patched: the reload moves the centre card's column but not the selected one's, and the selected card's position is asserted.
  - `[low]` `[patch]` (verification-gap #2) Nothing witnessed that GraphCanvas rebuilds the day-axis painter at local midnight. Patched: a GraphView test crosses midnight on the model's minute tick and checks the painter's new "now"; a same-day tick keeps it.
  - `[low]` `[patch]` (verification-gap other #1) Grouped with blind #8; patched there.
  - `[low]` `[patch]` (verification-gap other #2) The real-worker test compared the request's revset with the pass-through under test. Patched: it compares with `repo.handle.logDefaults()`.
  - `[low]` `[reject]` (edge #1) Grouped with blind #1.
  - `[low]` `[patch]` (edge #2) Grouped with blind #8; patched there.
  - `[maybe-false]` `[reject]` (edge #3) Continuous external activity during every layout call could drop every result. The epic decides the drop rule (item 3); it would need an operation landing in every layout window without pause, which the I5 bursts (4–21 events over 3–7 s) did not starve. If true it would be low.
  - `[low]` `[reject]` (edge #4) An error on the worker's event stream is unhandled. The worker's events are a broadcast of decoded events that carries no errors; a guard would handle an unseen case.
  - `[low]` `[reject]` (edge #5) Grouped with blind #7.
  - `[low]` `[reject]` (edge #6) "Update working copy" turns active again before the reload clears the stale state. A second press runs `update-stale` on a fresh working copy, which reports "not stale" and changes nothing; keeping busy across the reload adds state.
  - `[low]` `[reject]` (edge #7) Grouped with blind #5.
  - `[low]` `[patch]` (edge #8) After an empty layout, a revset error still showed "No changes match this revset." Patched: the empty caption shows only without a revset error.
  - `[false]` `[reject]` (edge #9) Grouped with blind #10.
  - `[false]` `[reject]` (edge #10) "A scrollable nested in a card is read as a graph fling." Cards are render boxes without scrollables; a depth filter would drop the 2D viewport's own second axis.
  - `[low]` `[reject]` (edge #11) A reveal started during a fling glide could be counted as user scrolling. A reveal while the canvas still glides is rare; the fix needs per-activity state the notifications do not carry.
  - `[false]` `[reject]` (intent #1) "I4: no app code builds `RepoGraphSource` from `ProjectSession`." The epic's 2026-10-16 note makes the real-repo host 10.12's; I4 asks to reconcile the text to the session's handle, which the adapter and the epics note do.
  - `[false]` `[reject]` (intent #2) "The notice is not placed in the shell's slot; Copy and Update are exclusive." `GraphView.staleNotice(model)` is the slot's content for 10.12's host; Copy versus Update follows the DS (StaleNotice.jsx).
  - `[low]` `[reject]` (intent #3) I5 measured the `ProjectSession` reading, not 10.5's reloads, which do no snapshot until 10.12. The reading is the same snapshotting call shape 10.12's topology call makes; the numbers and the reasoning are recorded in deferred-work.md I5.
  - `[false]` `[reject]` (intent #4) "Snapshot-loop and stale-exit witnesses run only on the fake." The epic's witnesses are "view-model unit tests on fake ports" plus one real-cdylib test, which exists.
  - `[low]` `[defer]` (intent #5, grouped with intent #8) Parts of item 14 handed on (@'s direction to 10.6, the inspector scroll and witnesses to 10.8, the dropped plane margins) were recorded only in the epics note. Deferred (frontmatter, deferred-work.md "Surfaced in Story 10.5"); the top-inset and collapse witnesses are 11.3's shell.
  - `[false]` `[reject]` (intent #6) "Wheel and 650 ms calm witnesses are not exercised." They belong to 11.3's `CalmController` and shell, witnessed there; I3 asks 10.5 for pans and flings only.
  - `[false]` `[reject]` (intent #7) "I7 asks to freeze now per reload; the diff ticks per minute." I7 also asks for one "now" for the cards' minute tick and the axis; the axis is frozen per day and refreshed on reload, focus and midnight.
  - `[low]` `[defer]` (intent #8) Grouped with intent #5.
  - `[low]` `[patch]` (intent #9) The deferred-work section's two items were not in the spec's `deferred:` list. Patched: the frontmatter lists them (bookkeeping).

## Design Notes

- **Why `GraphCanvas` moves into `lib`.** `GraphView` needs the same composition the catalogue built (rows, axis, route cache, edges, cards) plus reveal/anchor/insets; one widget serves both, and item 11's per-layout structures live there, built outside the build phase as 10.4 left them. Their 100k cost is not re-measured (10.4's numbers stand).
- **Insets = the visible rect.** The viewport's `EdgeInsets` are the shell's `GraphInsets` as they are; the design's extra plane padding (+4/+2/+12) is dropped so the unobscured area the viewport centres in equals the visible rect exactly (Claude's proposal).
- **Heartbeat only while stale.** A checkout heartbeat fires on any jj activity, our own reads included; outside the stale state it would double every reload, so it only lifts a stale state (the epic's exit rule).
- **One now, minute ticks.** Cards need minute resolution; the axis only the day. A minute-aligned timer gives both, and midnight lands exactly; reload and window focus refresh it at once.

## Verification

Gate rule for this run: no `cargo make test` / `test-full` / `coverage`.

**Commands:**
- `flutter test test/features/graph test/features/projects test/features/shell test/features/home test/widgetbook` (in `app`, with `JJ_CONFIG`, `GIT_CONFIG_GLOBAL`, `XDG_CONFIG_HOME` pinned as Makefile.toml's test-flutter does) -- expected: all pass.
- `dart analyze --fatal-infos app packages/zanshin_core` -- expected: no issues.
- `dart format --set-exit-if-changed app packages/zanshin_core` -- expected: exit 0.
- `flutter test` / `dart test` for `packages/zanshin_core` only if more than the barrel changed.

**Manual checks (if no CLI):**
- Best-effort Marionette check of "Graph / Viewport / View model" and "Stale notice"; record the outcome or why it could not run.

**Verification notes (2026-10-30):**
- After implementation: `flutter test --reporter=failures-only test/features/graph test/features/projects test/features/shell test/features/home test/widgetbook` (app, Makefile.toml test-flutter env pins: JJ_CONFIG, GIT_CONFIG_GLOBAL, XDG_CONFIG_HOME, JJ_USER/EMAIL/OP_*): 907 passed. After the review patches: 910 passed.
- `dart analyze --fatal-infos app packages/zanshin_core`: no issues (both rounds).
- `dart format --set-exit-if-changed app packages/zanshin_core`: 0 changed (both rounds).
- `dart run build_runner build --only-check` (implementer): generated code unchanged (nothing in the DI component consumes `GraphViewModel` yet).
- `packages/zanshin_core` tests not run: only its barrel changed. No Rust, FFI, schema or jj verb changed: no cargo test, clippy, codegen or parity oracle applies. No full gate, per this run's gate rule.
- I5 measurement (temporary test, deleted): see Auto Run Result.
- Marionette check: not run — the unattended synchronous run cannot hold `flutter run -d macos -t widgetbook/main.dart`. Deferred (frontmatter, deferred-work.md "Surfaced in Story 10.5").

## Auto Run Result

Status: done. Code commit `5d5548c0cf25dd9ae0804464e030d0ce7d8a8e82`, plus the follow-up commit that carries this spec, `deferred-work.md`, `epics.md` and `sprint-status.yaml`.

**Items from the dispatch:**
- **I1** (barrel lacks `RepoHandle` / `CreatedRepoHandle` / `Precondition`): **rejected — no longer applies.** The barrel already exported them (and `OpenedRepoHandle`); 10.5 adds what it consumes besides, `LogDefaults` and `defaultGraphAnchors` (`5d5548c0cf25dd9ae0804464e030d0ce7d8a8e82`). deferred-work.md carries a "Resolved in Story 10.5" note.
- **I2** (barrel lacks `ZanshinFfiException`): **rejected — no longer applies.** Already exported; `GraphViewModel` now reads it and `Precondition`. Note in deferred-work.md.
- **I3** (calm and insets shape): **fixed in `5d5548c0cf25dd9ae0804464e030d0ce7d8a8e82`.** `GraphView` takes the `ShellScope`'s `GraphInsets` as the viewport's insets and reports canvas mouse pans (`GraphViewport.onUserPan`) and fling glides through `ShellScope.maybeOf(context)?.reportUserScroll`; the view model publishes no calm. Epics 10.5 items 14–15 reconciled in its "Built 2026-10-30" note. Minimap scrolling is 10.16's.
- **I4** (handle from `ProjectSession.repo.handle`): **fixed in `5d5548c0cf25dd9ae0804464e030d0ce7d8a8e82`.** `RepoGraphSource(ProjectRepo, {layout})` over the session's repo, `ProjectRepo.events` added; epics item 1 reconciled. Mounting `GraphView` in `HomePage` is 10.12's real-repo host.
- **I5** (burst of CLI commands vs readings): **fixed (measured, no debounce needed).** A temporary test opened a Git-backed temp repo through `WorkerProjectRepos`, read it on every op-heads event as `ProjectSession._refresh` does, and ran alternating `jj describe -m` / `jj new` with a file edit before each: 40, 40 and 80 commands (3.7 s, 3.4 s, 7.1 s), 15 / 4 / 21 events and readings (none failed), 82 / 82 / 162 operations, 0 concurrent or `reconcile` operations, 0 `divergent()` changes. Neither the readings nor 10.5's reloads are debounced. Recorded in deferred-work.md I5 and the epics note.
- **I6** (StaleNotice action): **partly done in `5d5548c0cf25dd9ae0804464e030d0ce7d8a8e82`.** `StaleNotice` with "Update working copy" (quiet md button, `jj workspace update-stale` tooltip, busy), `GraphViewModel.updateStale()` (keeps `lastStaleRecovery`, reloads; a failure kept as `staleUpdateError`, no Undo), `GraphView.staleNotice(model)` for the shell slot. Left: the result toast and the failure's error toast with Retry are 10.23's (no toast host exists yet); the app mounts the notice with 10.12's host.
- **I7** (one "now", focus and midnight): **fixed in `5d5548c0cf25dd9ae0804464e030d0ce7d8a8e82`.** `GraphViewModel.now` fresh on every landed layout and on `refreshNow()` (window turning active), ticked on each minute boundary (midnight on time); `GraphView` copies it into the cards; `GraphCanvas` rebuilds the day axis only when the local day changes (witnessed across midnight).
- **Design question (c)** (file-edit refresh policy): **not done — Ralph's decision**, recorded as still open under the existing deferred-work item.

**Summary.** Epics Story 10.5 on fake ports: `GraphRequest` (pre-filled from `logDefaults`, anchors from zanshin_core), `GraphSource` / `GraphActions` ports, `GraphViewModel` (coalesced reloads on op heads, `reload`/`retry`/`configChanged`, heartbeat only while stale; scroll precedence landed as one `GraphReveal` with its layout; selection survival; loading, empty, revset error, error with retry, stale with jj's cause message and hint command, degraded; warnings and precondition; one "now"), `GraphCanvas` (the catalogue composition moved into `lib`), `GraphView`, `StaleNotice`, `RepoGraphSource`; the viewport anchors on the selection only while it is visible inside the insets.

**Files:**
- `packages/zanshin_core/lib/zanshin_core.dart`: exports `LogDefaults`, `defaultGraphAnchors`.
- `app/lib/src/features/projects/project_repos.dart`, `worker_project_repos.dart`: `ProjectRepo.events`.
- `app/lib/src/features/graph/graph_ports.dart`, `graph_view_model.dart`, `graph_canvas.dart`, `graph_view.dart`, `stale_notice.dart` (new).
- `app/lib/src/features/graph/graph_viewport.dart`, `graph_viewport_render.dart`: `onUserPan`; visible-only anchor key.
- `app/widgetbook/folders/graph.dart`, `app/widgetbook/graph/fake_graph_source.dart`, `app/widgetbook/demo_projects_fakes.dart`: `GraphCanvas` in Recording/Scale, "Viewport / View model", "Stale notice / Variants".
- Tests: `graph_view_model_test.dart`, `graph_view_test.dart`, `stale_notice_test.dart`, `graph_ports_test.dart` (real worker), `test/helpers/scripted_graph_source.dart` (new); `graph_anchor_test.dart`, `catalogue_smoke_test.dart`, `test/helpers/fake_projects.dart`; `app/pubspec.yaml` (`fake_async` dev dependency).
- `epics.md` (Story 10.5 "Built 2026-10-30" note), `deferred-work.md`, `sprint-status.yaml`.

**Review.** 37 findings: 0 high, 0 medium, 24 low, 12 false, 1 maybe-false.
- Patched, 8 entries (all low): the anchor's on-screen check uses the area inside the insets; no layout call after dispose; the empty caption yields to a revset error; tests that tell the selection anchor from the centre anchor at the `GraphView` level, cross midnight at the canvas, show a heartbeat through `RepoGraphSource.events`, and compare with `repo.handle.logDefaults()`; the spec's `deferred:` list mirrors deferred-work.
- Deferred, 2 (low), mirrored to deferred-work.md: the CLI message copies vs pin bumps; the handed-on parts of item 14 (10.6, 10.8). Plus the Marionette check and the captions proposal from the implementation.
- Rejected, each with its reason in the Review Triage Log: non-FFI throws, init guards, malformed stale context, keepOpenKeys during a request, event-stream errors, busy across the reload, a reveal during a glide, starvation under continuous activity (maybe-false), the I5 path, and 12 false.
- Follow-up review recommended: **false** — first pass, no high or medium entry was patched.

**Residual risks:**
- Nobody has looked at the view model use case or the notice on screen (deferred Marionette check).
- The real-worker tests rely on the watcher folding one operation into one event within 600 ms; green on every run here, not stress-tested.
- The app shows no graph yet: `GraphView` is mounted by 10.12's host, so stale/now/anchor behaviour is proven on fakes and widget tests only.
