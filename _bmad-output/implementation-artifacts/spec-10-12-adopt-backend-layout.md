---
title: 'Story 10.12 — Adopt the backend layout: the real GraphSource, the graph mounted in the project window, the reload button'
type: 'feature'
created: '2026-11-01'
status: 'done'
baseline_revision: '51bd5b1054c899df2b89fbec64e1d22de216af35'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      No test drives RepoGraphSource.layout into a LayoutContractException, so its conversion to the ffi.unknown caption is checked only as a function.
    evidence: |-
      layoutContractFailure is unit-tested in repo_graph_source_test.dart; the catch at the call site needs a RepoHandle that throws, which a healthy backend never does (verification-gap review).
    location: >-
      app/lib/src/features/graph/graph_ports.dart (RepoGraphSource.layout)
    severity: low
  - summary: >-
      The Reload island and the peek's description, commit id and loading bar are not checked in the catalogue against the DS (PeekCard, the bar's ACTION group).
    evidence: |-
      Widget tests cover structure and text only; the Marionette check did not run in the unattended loop.
    location: >-
      app/lib/src/features/graph/graph_controls.dart (GraphReloadIsland), app/lib/src/features/graph/graph_peek.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** The graph still runs only on recorded layouts and fake ports: `RepoGraphSource` takes its layout and content as injected functions, no `GraphLayout` reads 4.12's topology view and 4.11's grid, and `HomePage` mounts no graph. So the project window shows an empty shell; the controls, inspector, search, toasts, menu bar graph items (11.13) and the Undo Timeline's runner (11.9) reach no running app, and there is no in-window reload button.

**Approach:** Add `BackendGraphLayout` (a lazy `GraphLayout` over `GraphTopologyView` + `GraphGridView`), make `RepoGraphSource` call `RepoHandle.graphLayout` and `commitContents`, and mount the whole graph in the project window through one per-repository host in `HomePage` that also publishes it to the menu bar, hands the runner to the Undo Timeline, and adds a Reload button to the bar's ACTION group. Plus the small owed pieces: barrel exports, peek description/commit id/loading look, debug relayout on reassemble, the ⌘F hand-over to the menu, and fixture-based checks and measurements.

## Boundaries & Constraints

**Always:**
- The view never lays out: rows, columns, edges, buckets and runs come from the grid; ids, flags, refs, working copies, counts and the operation id from the topology. No painter or card-geometry change.
- Every request parameter is passed through from `GraphRequest` (FR-JJ-17); nothing defaulted silently. Content is read at the layout's `operationId` with the topology's `extraOperationIds`.
- Keys follow 10.1's rule: change id, or the commit id when the node is hidden or divergent; a stack node's key is `graphStackKey(<oldest member key>)`; stack facts as `RecordedGraphLayout.fromSpec` derives them (newest member's timestamp, parent count 1, immutable iff every member is).
- `GraphLayout.version` stays unique across every implementation (one shared counter).
- The app imports only `package:zanshin_core/zanshin_core.dart`; the topology's own `GraphEdgeKind` stays unexported (it clashes with the app's) — detect a Missing edge by `edgeTarget(e) == null`.
- One graph object set per open `ProjectRepo`: recreated when the repository changes, disposed on unmount/close; the menu binding is cleared before its model is disposed.
- UI strings through the ARB (`app/lib/l10n/app_en.arb`, then `flutter gen-l10n`); controls from `zanshin_ui` only; no new icon glyph (the icon set mirrors the DS, `ds_parity_test.dart`).
- Real-cdylib tests use in-test repos or extracted `test-fixtures/repos/*.tar.zst` copies in temp dirs; never Ralph's repositories. Widget tests with worker I/O wrap it in `tester.runAsync`.

**Never:**
- No Rust, FFI-schema or layout-engine change (4.10–4.16 are delivered). No new jj verb.
- No timer, no file watcher (refresh = window focus, Reload button, ⌘R).
- No edit of `design/` or `design_system/`.
- No change to the immutable reason (I7 waits for 11.7's term order).
- No full gate (`cargo make test` / `test-full` / `coverage`) in this run — targeted checks only (see Verification).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Layout | `GraphRequest` (mode, order, stacks, key sets, revset, prioritize, shortPrefixes, anchors, utcOffsetMin) | `GraphLoad(BackendGraphLayout, warnings: topology.warnings, precondition: handle.lastPrecondition)` | `ZanshinFfiException` passes through (revset errors, stale) |
| Contract violation | topology breaks a layout input rule | the model shows its error caption with Retry | `LayoutContractException` rethrown as `ZanshinFfiException('ffi.unknown', '<rule>: <message>')` |
| Content page | `operationId`, ids of the shown layout | map id → `GraphCommitContent` (subject = first line, full `description`, author, `empty ?? false`, conflict, committer ms) | failure propagates; `GraphContent` asks again on the next settle or landed layout |
| Content without op id | `operationId == null` (a recording) | empty map, no call | — |
| Hidden / divergent node | flags set | key = commit id; `changeOffsetOf` non-null only then | — |
| Collapsed run | grid v4 | members `rowOf`/`colOf` −1, `isFolded`; stack node at index ≥ n | — |
| Two workspaces on @'s commit | topology working copies of @ > 1 | `workspaceName` null (all names shown) | shortcut comment |
| Reload button | pressed, also twice while a reload runs | one `GraphViewModel.reload()` + one `ProjectSession.refresh()` per press, coalesced to one run + one queued each | disabled when no repo open |
| Repo closed / switched | `session.repo` changes | old model unbound from the menu, disposed; a new set built for the new repo | — |

</intent-contract>

## Code Map

- `packages/zanshin_core/lib/zanshin_core.dart` -- barrel. Add `src/graph_layout/graph_grid_view.dart show GraphGridView`, `src/graph_layout/layout_request.dart show LaneOrder, LayoutContractException, LayoutMode, defaultLaneOrder, defaultLayoutBudget, defaultLayoutMode`, `src/ffi/commit_contents.dart show CommitContent` (I4; `writeGraphGrid` is `@internal`, never exported). If a test pins the export list, update it.
- `packages/zanshin_core/lib/src/ffi/graph.dart:222-579` -- `GraphTopologyView`: `commitId/changeId(i)`, `*PrefixLength(i)`, `isWorkingCopy/isImmutable/isHidden/isDivergent/isRoot`, `changeOffset`, `parentCount`, `edgeStart/edgeEnd/edgeTarget`, `timestamp`, `refsOf` (filter `TopologyRefKind.bookmark`), `workingCopiesOf`, `allCount`, `operationId`, `extraOperationIds`, `warnings`, `indexOfCommitId`, `indicesOfChangeId`.
- `packages/zanshin_core/lib/src/graph_layout/graph_grid_view.dart:136-452` -- `GraphGridView`: `mode`, `unit`, `rows`, `lanes` (= colCount), `nodeCount` (n), `stackCount` (S), node arrays n+S (`nodeRows`, `nodeCols`), edges (`edgeFroms` parent, `edgeTos` child, ordered by child; kinds 0/1; routes 0 straight/1 merge/2 branch-off), buckets (`bucketValues/Starts/Ends`), runs (`runCount`, `nodeRuns`, `runNodes` (−1 expanded), `runStarts`, `runMembers`).
- `packages/zanshin_core/lib/src/worker/handle.dart:256` `graphLayout(...)`, `:442` `commitContents(...)`, `:105` `lastPrecondition`, `:417` `logDefaults`.
- `packages/zanshin_core/lib/src/ffi/commit_contents.dart:62` -- `CommitContent` (authorName/Email, committerTimestampMillis, description FULL, conflict, `empty` nullable).
- `app/lib/src/features/graph/graph_layout.dart` -- abstract `GraphLayout`; `GraphCommitContent` (add `description`, default `''`); add `int commitIdPrefixLengthOf(int node) => 0` (default) and a shared `nextGraphLayoutVersion()` counter.
- `app/lib/src/features/graph/recorded_graph_layout.dart` -- reference for every accessor; its CSR block (lines 102-126) is the edge index to share; `fromSpec` (137-283) is the stack-fact reference; switch its `_nextVersion` to the shared counter.
- `app/lib/src/features/graph/graph_ports.dart:730-756` -- `RepoGraphSource` (make real; drop the function params); `:786-822` `RepoGraphSearchSource` (`_content`, `_userEmail` stay functions — the host passes `source.content` and the identity read); `RepoGraphActions`, `RepoGraphDetails` (wire as they are).
- `app/lib/src/features/graph/graph_view_model.dart:194` `init`, `:483` `reload` (coalesced, `_requestLayout` 792-843 re-reads `logDefaults` every request, so the focus reload already re-reads config — I12's "configChanged on focus"), catches only `ZanshinFfiException`.
- `app/lib/src/features/graph/graph_content.dart` -- cache keyed by commit id; failures cached nothing (I9/I10).
- `app/lib/src/features/graph/graph_peek.dart` -- add description (DS `.zs-peek-desc`: `--fs-md`, line-height 1.45, `--text-dim`, pre-line) below the subject, the commit id in the meta row after the change id (`.zs-peek-dim`: `--text-faint` mono, `max(prefix, 8)` hex), and a loading look while a non-root node's content is null (one static skeleton bar in the subject's place, colours as `graph_card_render.dart`'s skeleton). DS ref `_bmad-output/implementation-artifacts/design_system/components/overlays/PeekCard.jsx`, `overlays.css:25-39`.
- `app/lib/src/features/graph/graph_card.dart:200-300` `GraphCardData` -- add `commitId` (null for stack nodes) and `commitPrefixLength`, filled from the layout.
- `app/lib/src/features/graph/graph_view.dart` -- add `reassemble()` → `widget.model.reload()` (item 6; reassemble runs only in debug).
- `app/lib/src/features/graph/graph_search_field.dart:1679-1720` `GraphSearchShortcuts` -- drop ⌘F (the menu's Edit › Find is the only ⌘F, I15), keep `/`; update its tests.
- `app/lib/src/features/graph/graph_toasts.dart:19` `GraphToasts(model, toasts)`; `graph_inspector.dart:35` `InspectorViewModel(graph:, details:)`; `graph_preferences.dart:57` `init(model, source, actions:, stackStore:, revset:)`; `graph_search_controller.dart:35` `GraphSearchController(model:, source:, store:)`; `graph_search_store.dart:27` `ProjectSearchStore(store, path)`; `graph_stack_store.dart:13` `ProjectStackStore(store, path)`; `graph_controls.dart` `GraphViewControls`, `NewChangeButton`.
- `app/widgetbook/folders/graph.dart:452-578` `_ShellControlsDemo` -- the exact composition to mirror in the host (FloatingShell slots graph/view/newChange/inspector/atPill/toast, `ListenableBuilder` over model + toasts + preferences); add the Reload island here too so the catalogue shows it.
- `app/lib/src/features/home/home_page.dart` -- `HomePage` (assisted-inject: `viewModelFactory`, `projects`); `_UndoTimelineHost` (pattern for a per-repo host; gains `actions:`); `_OnWindowActive` (session refresh on focus).
- `app/lib/src/features/shell/floating_shell_view_model.dart` -- owns `_settings` (`SettingsStore`) and `toasts`; expose `SettingsStore get settings`.
- `app/lib/src/features/shell/app_menu.dart:39-51` `GraphMenuBinding(model:, preferences:, focusSearch:)`; `:91` `AppMenuModel.graph` (`ValueNotifier`); `:440-452` Reload already runs `refresh()` + `graph.value?.model.reload()`.
- `app/lib/src/features/shell/top_bar.dart:96` -- ACTION group = `syncGroup` island + `newChange`.
- `app/lib/src/features/projects/projects_environment.dart:28` `identity({workspaceRoot})` → `.email` (null when unset/empty) — the host's `userEmail`.
- `app/lib/main.dart:195`, `main.inject.dart`, `home/home_page.factory.dart` -- DI; regenerate with `dart run build_runner build -d` in `app/` after `HomePage`'s constructor changes.
- `app/test/features/home/home_page_test.dart:102`, `app/test/features/app/zanshin_app_test.dart:45` -- construct `HomePage` directly; need the new params (fakes: `test/helpers/fake_projects.dart` `FakeProjectRepo`, `test/helpers/fake_projects_environment.dart`).
- `app/test/features/graph/graph_ports_test.dart` -- constructs `RepoGraphSource` with functions; adapt.
- `app/lib/src/features/graph/layout_invariants.dart:53` `checkLayoutInvariants`, `:311` `checkRoutes` -- the hard-invariant check and route report for real layouts.
- `packages/zanshin_core/test/worker/graph_layout_test.dart:465-476` -- fixture extraction pattern (`tar -xf ../../test-fixtures/repos/<f>.tar.zst -C tmp`); from `app/` the path is `../test-fixtures/repos/`.
- `packages/zanshin_core/benchmark/graph_layout_occupancy.dart` -- existing worker benchmark (60-id page, loose + `git gc`-packed `large-10k`); model for the new measurement script.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_core/lib/zanshin_core.dart` -- add the exports named in the Code Map -- I4 and item 4: the app names `LayoutMode`, `LaneOrder`, `GraphGridView`, `CommitContent`, `LayoutContractException`.
- `app/lib/src/features/graph/graph_layout.dart` -- `GraphCommitContent.description` (full text, default `''`); `commitIdPrefixLengthOf` default 0; `nextGraphLayoutVersion()`; a shared edge-index helper (parent ranges, child ranges, child-edge slots from child/parent arrays and n) moved out of `RecordedGraphLayout` -- one CSR for both implementations.
- `app/lib/src/features/graph/recorded_graph_layout.dart` -- use the shared counter and helper; behaviour unchanged.
- `app/lib/src/features/graph/backend_graph_layout.dart` (new) -- `BackendGraphLayout(topology, grid, {required utcOffsetMinutes})`: every accessor per the I/O matrix and Boundaries; root and @ found by one flags scan; `indexOfKey` via a lazily built map (or the topology's lookups) plus stack keys; refs = bookmark entries as `GraphRef(name, remote:, synced:, conflicted:)`; `workingCopiesOf` = workspace names; `workspaceName` = the single working copy on @'s node, else null (`shortcut:` comment); `totalCount` = `allCount`; `operationId` = topology's; `commitIdPrefixLengthOf` from the topology; `contentOf` null; runs from the grid; `extraOperationIds` exposed for the source.
- `app/lib/src/features/graph/graph_ports.dart` -- `RepoGraphSource(repo)`: `layout` maps the request (`GraphMode`→`LayoutMode`, `GraphLaneOrder`→`LaneOrder`, key sets → lists) onto `handle.graphLayout`, wraps `LayoutContractException`, returns the `GraphLoad`; remembers the last layout's `operationId → extraOperationIds`; `content` calls `commitContents` and maps `CommitContent` (subject = text before the first `\n`). Update doc comments that say "until 10.12".
- `app/lib/src/features/graph/graph_card.dart`, `graph_peek.dart`, `graph_canvas.dart` (only if `_peekLayer` must pass more) -- I11 per the Code Map; the root keeps `root()` and no loading look.
- `app/lib/src/features/graph/graph_view.dart` -- debug relayout on `reassemble` (item 6).
- `app/lib/src/features/graph/graph_search_field.dart` -- `GraphSearchShortcuts` without ⌘F (I15); doc comment says the menu owns ⌘F.
- `app/lib/src/features/shell/floating_shell_view_model.dart` -- `settings` getter.
- `app/lib/src/features/home/project_graph_host.dart` (new) -- per-repository host: on `session.repo` (and `session.current.path`) builds `RepoGraphSource`, `GraphViewModel`, `GraphPreferences(settings)` + `init(model, source, actions: RepoGraphActions(repo), stackStore: ProjectStackStore(settings, root), revset: search.revset)`, `GraphSearchController(model:, source: RepoGraphSearchSource(repo, userEmail: () => environment.identity(workspaceRoot: root).then((i) => i.email), content: source.content), store: ProjectSearchStore(settings, root))`, `InspectorViewModel(graph: model, details: RepoGraphDetails(repo))`, `GraphToasts(model, shellToasts)`; publishes `appMenu.graph.value = GraphMenuBinding(model:, preferences:, focusSearch: () => search.focusField())`, clears it (only if still its own binding) before disposing; gives its builder the slot widgets (graph, view, reload island, newChange, inspector, atPill, staleNotice) and the model, or nulls without a repo -- I6, I8, I12, I13, I15, I16.
- `app/lib/src/features/home/home_page.dart` -- `HomePage` gains `required ProjectsEnvironment environment` and `required AppMenuModel appMenu`; composes `ProjectGraphHost` → `_UndoTimelineHost(actions: model)` → `GraphSearchShortcuts` (when a search exists) → `FloatingShell` with the host's slots; `_UndoTimelineHost` passes `actions:` to `undoTimelineRailItem` (I16). Reload island: a `ZsIsland` with a ghost `ZsButton(label: menuReload)` in a `ZsTooltip('Reload (⌘R)')`, identifier `graph.reload`, `onPressed: () { projects.refresh(); model.reload(); }`, null without a repo (I1, I2; Claude's proposal: the DS has no reload glyph). Update the class doc.
- `app/lib/l10n/app_en.arb` -- the reload tooltip string (description says it is the bar's Reload); `flutter gen-l10n`.
- `app/lib/main.inject.dart`, `app/lib/src/features/home/home_page.factory.dart` -- regenerate (`dart run build_runner build -d` in `app/`).
- `app/widgetbook/folders/graph.dart` -- the Reload island in `_ShellControlsDemo`'s `syncGroup`; drop the "until 10.12" comment.
- `app/test/features/graph/backend_graph_layout_test.dart` (new, real cdylib) -- on extracted `tiny-3-commits` and `medium-1k-commits` (and `large-10k-commits` for the default revset + `all()` in one mode if it stays under ~60 s): for the default revset and `all()`, both modes, stacks off and on: `checkLayoutInvariants` empty; keys/rows/cols/edges equal the grid and topology (spot checks + counts: `nodeCount == n + S`, `edgeCount == E`, `shownCount == n`, `totalCount == allCount`, `operationId == topology.operationId` (I14)); Free ↔ Compact changes no column (4.14 I8); a `RouteMetrics` change re-runs only the router (no layout request — covered in the model test below); route report counts printed and recorded in Verification notes. Unit cases on a hand-made in-test repo: a hidden/divergent key, a Missing parent → `elidedOf`, bookmarks → `refsOf`, a collapsed run's stack facts.
- `app/test/features/graph/repo_graph_source_test.dart` (new, real cdylib, in-test repo) -- request mapping (mode, order, stacks keys) reaches the worker (layouts differ as expected); `content` maps every field incl. `description` and subject; null op id → empty map, no call; a `LayoutContractException` becomes `ZanshinFfiException('ffi.unknown')` (inject via a fake handle if a real one cannot produce it, else unit-test the wrap function); `RepoGraphSearchSource.files()`, `bookmarks()`, `revsetCounts` on the same repo (I12).
- `app/test/features/graph/graph_real_repo_test.dart` (new widget test, real cdylib, `tester.runAsync`) -- `GraphView` + `GraphViewModel` over `RepoGraphSource` on an in-test repo: a `describe` through the handle reloads and the anchored node keeps its place; a double-click `edit` moves @ (and the gold lineage); `setRevset('all()')` shows more nodes and the right shown/total -- the story's witnesses.
- `app/test/features/graph/graph_content_test.dart` -- a failed page is asked again once a new layout lands / a load follows (I10's settle).
- `app/test/features/graph/graph_peek_test.dart` (or existing peek tests) -- description below the subject, commit id in the meta row, loading bar while content is null, none for the root.
- `app/test/features/home/home_page_test.dart`, `app/test/features/app/zanshin_app_test.dart` -- new params; with a `FakeProjectRepo` open: the graph mounts, `appMenu.graph.value` is set and cleared on close/switch, the Undo Timeline gets actions, the Reload button runs one `refresh()` and one `reload()` (twice while in flight → one queued), disabled without a repo. Use a fake `GraphSource`-compatible repo only where the real worker is not needed.
- `app/test/features/graph/graph_search_field_test.dart` (or wherever `GraphSearchShortcuts` is tested) -- ⌘F no longer handled there, `/` still focuses.
- `packages/zanshin_core/benchmark/graph_content_page.dart` (new) -- I3 / item 7 and the measured witness: on extracted `medium-1k-commits` and `large-10k-commits` (loose and `git gc`-packed copies): `graphLayout` latency for `free` and `compact` (default revset and `all()`), and `commitContents` pages of 20 / 60 / 150 / 300 ids (merges included where the fixture has them); with a changed-path index too if a `jj` CLI at v0.46.0 is on PATH (`jj debug index-changed-paths` on the temp copy only), else say so. Prints numbers only; run it once, record the numbers; tune 10.11's buffer only if a page exceeds one frame budget per ~viewport of ids (decide from the numbers; Pages stay uncapped).

**Acceptance Criteria:**
- Given an open project in the app, when the project window shows, then its graph is a real layout of the effective `revsets.log` (cards, edges, @ lineage), the VIEW controls, New change, search, inspector on selection, @ pill, stale notice and toasts work, and View/Change/Go/Undo/Find menu items are enabled per their rules.
- Given the window, when the Reload button is pressed, then `ProjectSession.refresh()` and `GraphViewModel.reload()` each run once (a second press while in flight queues one), and without an open project the button is disabled.
- Given the Undo Timeline rail panel with a graph mounted, when Undo/Redo/Restore is pressed, then it runs through the graph's model (not the disabled "Available once the commit graph is shown").
- Given ⌘F in the project window, when pressed, then only the menu's Edit › Find handles it and focuses the graph search; `/` still focuses it from the graph.
- Given a hovered card whose content is loading, when the peek shows, then it shows a loading bar instead of an empty subject; once loaded it shows subject, description body, change id, commit id, author and date.
- Given a real layout of any committed fixture in either mode, with or without stacks, then the hard invariants hold and a Free ↔ Compact switch keeps every column.
- Given a debug build, when hot-reloaded, then the graph requests its layout again.

## Spec Change Log

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 42 findings — high 0, medium 6, low 24, false 12, maybe-false 0
- findings:
  - `false` `reject` (blind) Tags dropped from `refsOf` — `GraphLayout.refsOf` is documented as jj's `bookmarks()`, and the card (10.3) draws bookmarks only; tags are no ref of this accessor.
  - `low` `patch` (blind) A CRLF description keeps a `\r` in the subject — jj's `first_line()` uses Rust `lines()`; fix: one trailing `\r` stripped in `graphCommitContentOf`.
  - `low` `reject` (blind) `empty ?? false` turns "unknown" into "not empty" — the documented choice (spec matrix); a nullable `empty` would ripple through the card renderer for a rare merge-outside-index case.
  - `medium` `patch` (blind) `_extraOperationIds..clear()` keeps only the last reply's extras — a reply the model drops as superseded overwrites the shown layout's; fix: per-operation set, extras added, never cleared; `at_operation()` content test added.
  - `low` `patch` (blind) `BackendGraphLayout.extraOperationIds` has no reader — deleted.
  - `low` `reject` (blind) The whole shell rebuilds on every model notification — the catalogue's composition does the same, GraphView rebuilds on the model anyway; per-slot listening adds complexity without a measured cost.
  - `false` `reject` (blind) The menu binding is published during `initState` — `AppMenuModel.graph`'s only listener `_graphChanged` schedules a microtask (`_changed`), no `setState` during build.
  - `false` `reject` (blind) Session-refresh coalescing untested — `ProjectSession.refresh` coalesces itself and is tested so (`project_session_test.dart:418-430`); the host only has to call it once per press.
  - `low` `patch` (blind) `routeGraph(...) as RouteGeometry` casts a `FutureOr` in `graph_real_repo_test.dart` — awaited instead.
  - `low` `reject` (blind) `large-10k` runs in the app suite — the spec's choice while it stays under ~60 s (measured ~30 s); its route reports are the "recorded" witness.
  - `false` `reject` (blind) Fixture paths depend on the working directory — `flutter test`/`dart test` always run from the package root, as zanshin_core's existing fixture tests do.
  - `low` `patch` (blind) ⌘F works only through the menu; no test proves Edit › Find reaches the search (the catalogue part: no menu bar there, accepted) — binding test added (grouped with the verification-gap row).
  - `low` `patch` (blind) A layout contract break is not logged — the caption shows only the code; logged where it is caught.
  - `low` `reject` (blind) Stack-run mapping silent on bad data — the grid is the engine's own output read through a validated view; a guard for impossible data adds branches.
  - `low` `reject` (blind) `FakeProjectRepo.handle` throws `ffi.invalid_handle` — the home tests check composition; graph rendering is tested on real layouts in the graph tests.
  - `low` `patch` (blind) Broken doc reflow in `undo_timeline_view.dart` — reflowed.
  - `medium` `patch` (edge) A dropped reply overwrites the shown layout's extras — same fix as the blind row.
  - `low` `patch` (edge) Two layouts at one operation with different `at_operation()`s share one entry — fixed by the same union of extras (passing more operations only loads more).
  - `low` `reject` (edge) The peek shows a permanent loading bar for failed content — the card's skeleton behaves the same; a failed page is asked again on the next settle or landed layout (I10).
  - `false` `reject` (edge) A collapsed stack shows no elided marker — matches the recorded stack facts of 10.17 (`RecordedGraphLayout.fromSpec`: one parent, not elided), the spec's rule.
  - `medium` `patch` (edge) `GraphSearchShortcuts` appears only with a search, so `FloatingShell` remounts on project open/close — `search` made nullable and always wrapped.
  - `medium` `patch` (edge) `ProjectGraphHost.build` switches between a bare builder call and a `ListenableBuilder` — always the `ListenableBuilder`.
  - `false` `reject` (edge) `didUpdateWidget` ignores changed `appMenu`/`settings`/`environment` — `HomePage` passes DI singletons; they never change for one host.
  - `low` `patch` (edge) CRLF subject — same fix as the blind row.
  - `medium` `patch` (verification-gap) Edit › Find's binding to the search is untested — test added: `appMenu.graph.value!.focusSearch!()` focuses the field.
  - `low` `patch` (verification-gap) The peek's commit id through `GraphCardData.of` is untested — assertions added on a real layout and a stack node.
  - `medium` `patch` (verification-gap) `extraOperationIds` from `at_operation()` never verified — `at_operation` content test added (grouped with the extras fix).
  - `low` `patch` (verification-gap) `kindOf` and the bucket accessors not compared to the grid — `_expectMirrors` compares them.
  - `low` `defer` (verification-gap) The `LayoutContractException` catch at the `layout()` call site is untested — only a fake `RepoHandle` could throw it; a healthy backend never does.
  - `false` `reject` (intent) Item 5's `--dart-define` host in `main.dart` — the 2026-10-16 note retires the define once 11.5's project switching lands; it has, so the graph mounts through `ProjectSession`.
  - `low` `reject` (intent) Our workspace name is not on the wire — only a commit shared by several workspaces differs (every name shows there, as jj prints them); the fix is a Rust and schema change for a rare cosmetic case.
  - `false` `reject` (intent) Accessor growth and peek changes against the non-goal "painter or card changes" — I11 of the intent asks for the peek's description and commit id.
  - `low` `reject` (intent) Item 7 measured on fixtures, not the real 1.4k repo — recorded as partly done under Auto Run Result (that copy is not known to this run).
  - `low` `reject` (intent) Event → paint not measured, only the layout round trip — recorded as partly done under Auto Run Result.
  - `low` `reject` (intent) The 10.1–10.4 witness suites are not re-run on real layouts — the invariants, mirroring and column checks run on real fixtures; recorded as partly done.
  - `low` `patch` (intent) Item 6 (relayout on reassemble) untested — reassemble test added.
  - `false` `reject` (intent) The session side of Reload asserted only as "read again" — see the coalescing row: the session coalesces itself.
  - `false` `reject` (intent) I5, I7, I9, I10 answered by reasoning — the intent allows settle, reject or defer with the reason.
  - `false` `reject` (intent) R4 (deferred mirror, Auto Run Result) not visible in the diff — done at finalize in `_bmad-output`.
  - `low` `reject` (intent) `_openInBrowser` made detached, outside the stated scope — it fixes `process_spawn_guard_test.dart`, red at HEAD; kept.
  - `false` `reject` (intent) `files()` drops `revision: '@'` — a bug fix: the handle takes a change id there, `'@'` always failed.
  - `low` `reject` (intent) The fake handle's error type changed — same as the blind row.

## Design Notes

- **Why a dedicated `BackendGraphLayout` and not a conversion to `RecordedGraphLayout`:** 4.12's point is a lazy view — no per-node strings or objects up front at 10k–100k nodes. Ids are formatted on access; only `indexOfKey`'s map is built, on first use.
- **Workspace name without a Rust change:** jj's `working_copies()` is empty with one workspace, so the name only matters with several; the single working copy on @'s commit is ours, and the ambiguous case shows every name, as jj does.
- **Item status (open deferred-work items handed to 10.12):** I9 — the real source never leaves an id out (`commitContents` returns every requested id or throws), so the case goes to I10's path; I10 — the real failure modes are a pinned operation gone (`jj.operation_not_found`, followed by the op-heads reload that re-pins) and store I/O (`jj.jj_lib_error`); a failed page is asked again on the next settle, on any landed layout (Reload, ⌘R, window focus), no timer by Ralph's refresh rule; I7 — the term order is 11.7's (its Immutable commits page), so the port and the cached reason stay for 11.7; I5 — needs a profile-mode window in front for vsync, which an unattended run cannot hold.
- **Reload look:** the DS has no reload glyph and the icon set must equal the DS's, so the button is a ghost text button "Reload" with the ⌘R tooltip in the ACTION group's sync island (Claude's proposal; Fetch/Push join that island in their own story).

## Verification

**Commands:**
- `dart run build_runner build -d` (in `app/`) -- regenerates the DI; no diff after a second run.
- `flutter gen-l10n` (in `app/`) -- after the ARB edit.
- `flutter test` (in `app/`) -- all pass, including the new real-cdylib tests.
- `flutter test` / `dart test` (in `packages/zanshin_core`) -- the barrel/export tests pass.
- `dart analyze --fatal-infos` in `app/` and `packages/zanshin_core` -- clean.
- `dart format --set-exit-if-changed --line-length 120 .` per touched Dart package (use the package's configured width) -- clean.
- `dart run benchmark/graph_content_page.dart` (in `packages/zanshin_core`, env as `Makefile.toml` `[tasks.test-core]`) -- numbers recorded below.

**Manual checks (if no CLI):**
- If a Widgetbook/Marionette run is feasible unattended, check "Floating shell / Controls" (Reload island) and a peek against `PeekCard`; otherwise record "not run" here.

**Verification notes (2026-11-01, targeted checks per the loop's gate rule; no `cargo make test`):**
- `dart run build_runner build -d` (app), twice: second run no further diff (only `main.inject.dart` regenerated). `flutter gen-l10n` (app): ok.
- `dart analyze --fatal-infos --fatal-warnings` (app) and `dart analyze --fatal-infos` (zanshin_core): no issues, after the review patches.
- `dart format --output=none --set-exit-if-changed .` (app, zanshin_core): 0 changed.
- `flutter test` (app, test-flutter env): 1508 passed, after the review patches. `dart test` (zanshin_core, test-core env): 1184 passed.
- No Rust, schema or jj-verb change: no cargo, codegen or parity-oracle run needed.
- Route reports of every real fixture layout (tiny n 5/6, medium n 1002/1030, large n 10002 free; default revset and `all()`, both modes, stacks off/on): behindCard 0, explained 0, collinear 0, directFallbacks 0, overfullGutters 0, overfullClusters 0. Hard invariants: none violated. Free ↔ Compact: no column changed.
- Benchmark `packages/zanshin_core/benchmark/graph_content_page.dart` (median ms of 5 after 1 warm-up; jj 0.46.0 on PATH, changed-path index built on temp copies only; each fixture has one merge):

  | Fixture | Store | graphLayout (log / all(), free / compact) | Pages 20 / 60 / 150 / 300 ids |
  |---|---|---|---|
  | medium-1k | loose | 123–126 | 0.5 / 0.6 / 5.6 / 10.4 |
  | medium-1k | packed | 7.6–8.2 | 0.3 / 0.3 / 0.9 / 1.6 |
  | medium-1k | packed + changed-paths | 7.7–8.4 | 0.3 / 0.3 / 0.9 / 1.5 |
  | large-10k | loose | 1234–1262 | 0.8 / 0.9 / 5.0 / 8.9 |
  | large-10k | packed | 64.0–69.9 | 0.8 / 0.9 / 1.5 / 2.2 |
  | large-10k | packed + changed-paths | 65.1–71.3 | 0.8 / 0.9 / 1.5 / 2.2 |

  Every page stays under one 16.7 ms frame, so 10.11's buffer is not tuned. graphLayout is the worker round trip (topology + layout), not event-to-paint.
- Marionette/Widgetbook visual check: not run (unattended loop) — deferred.

## Auto Run Result

Status: done. Blocking condition: none.

**Summary.** The graph runs on real data and lives in the project window: `BackendGraphLayout` (a lazy `GraphLayout` over 4.12's topology view and 4.11's grid, stacks included), a real `RepoGraphSource` (`graphLayout` + `commitContents` with the topology's extra operations), and `ProjectGraphHost`, which mounts graph, VIEW controls, search, inspector, New change, @ pill, stale notice and toasts per open repository, publishes the graph to the menu bar, gives the Undo Timeline its runner, and puts Reload in the bar's ACTION group. Plus barrel exports, the peek's description / commit id / loading bar, menu-only ⌘F, debug relayout on reassemble, and a content-page benchmark.

**Files changed.**
- `packages/zanshin_core/lib/zanshin_core.dart` — exports `CommitContent`, `GraphGridView`, `LayoutMode`, `LaneOrder`, `LayoutContractException`, the layout defaults.
- `packages/zanshin_core/benchmark/graph_content_page.dart` — new: layout and content-page latencies on fixtures (loose, packed, changed-path index).
- `app/lib/src/features/graph/backend_graph_layout.dart` — new: the worker layout behind `GraphLayout`'s accessors.
- `app/lib/src/features/graph/graph_layout.dart` — `GraphCommitContent.description`, `commitIdPrefixLengthOf`, shared version counter, shared `GraphEdgeIndex`.
- `app/lib/src/features/graph/recorded_graph_layout.dart` — uses the shared counter and edge index.
- `app/lib/src/features/graph/graph_ports.dart` — real `RepoGraphSource`, contract-break mapping and log, CRLF-safe subject, `files()` bug fix (no `revision: '@'`).
- `app/lib/src/features/graph/graph_card.dart`, `graph_peek.dart` — commit id, description body, loading bar.
- `app/lib/src/features/graph/graph_view.dart` — relayout on `reassemble`.
- `app/lib/src/features/graph/graph_search_field.dart` — `GraphSearchShortcuts`: `/` only, nullable search.
- `app/lib/src/features/graph/graph_controls.dart` — `GraphReloadIsland`.
- `app/lib/src/features/home/project_graph_host.dart` — new: per-repository graph host.
- `app/lib/src/features/home/home_page.dart` — composes the host, Undo Timeline runner, shortcuts and shell; new `environment` / `appMenu` params.
- `app/lib/src/features/shell/floating_shell_view_model.dart` — `settings` getter.
- `app/lib/src/features/shell/app_menu.dart` — `_openInBrowser` detached (fixes `process_spawn_guard_test.dart`, red at HEAD).
- `app/lib/src/features/undo_timeline/undo_timeline_view.dart` — doc comment.
- `app/lib/l10n/*`, `app/lib/main.inject.dart` — reload tooltip string, regenerated DI.
- `app/widgetbook/folders/graph.dart` — Reload island in the shell demo.
- Tests: new `backend_graph_layout_test.dart`, `repo_graph_source_test.dart`, `graph_real_repo_test.dart`, `home/project_graph_host_test.dart`; updated `graph_ports_test`, `graph_content_test`, `graph_peek_test`, `graph_search_field_test`, `graph_view_test`, `home_page_test`, `zanshin_app_test`, `helpers/fake_projects.dart`.

**Handed-over items (deferred-work.md).**
- I1 — fixed: Reload in the bar's ACTION group (ghost "Reload", tooltip "Reload (⌘R)"; the DS has no reload glyph), runs `GraphViewModel.reload()`, coalesced.
- I2 — fixed: the same press runs `ProjectSession.refresh()` (coalesced by the session).
- I3 — partly done: measured on medium-1k and large-10k, loose and packed, with and without a changed-path index; no tuning needed (every page < 1 frame). Left: the copy of the real 1.4k repo (its location is not known to this run) — a merge-heavy real history is still unmeasured.
- I4 — fixed: the barrel exports the layout's public types (`writeGraphGrid` stays internal).
- I5 — not done: profile-mode frame times need a profile build in front of the screen (no vsync for a covered window); an unattended run cannot hold one. Left for an attended run.
- I6 / I13 — fixed: `GraphToasts(model, vm.toasts)` lives in the project window's graph host and is disposed with the model.
- I7 — not done: the reason needs 11.7's term order of `immutable_heads()`; the port and the cached reason stay for 11.7.
- I8 — fixed: `RepoGraphActions(repo)` is the model's runner in the project window (the oracle sample stays 10.15's).
- I9 — rejected: the real source never leaves an id out — `commitContents` returns every requested id or throws; the throw is I10's path.
- I10 — settled: real failure modes are a pinned operation gone (`jj.operation_not_found`, followed by the op-heads reload that re-pins) and store I/O (`jj.jj_lib_error`); a failed page is asked again on the next settle or any landed layout (Reload, ⌘R, window focus) — tested; no timer by Ralph's refresh rule.
- I11 — fixed: peek shows the description body, the commit id (max(prefix, 8) hex) and a loading bar while content loads.
- I12 — fixed: `RepoGraphSearchSource`, `ProjectSearchStore`, `GraphSearchShortcuts` and `user.email` (via `ProjectsEnvironment.identity`) are wired in the project window; the config re-read on focus is the focus reload (every request re-reads `logDefaults`); the repo search source is tested on a real repo (which found and fixed the `files()` bug).
- I14 — fixed: the backend layout carries the topology's `operation_id` (tested), so the search's counts and lookups run.
- I15 — fixed: the project window publishes `GraphMenuBinding` (cleared on close/switch); `GraphSearchShortcuts` no longer handles ⌘F, so the menu's Edit › Find is the only ⌘F (tested end to end).
- I16 — fixed: the mounted `GraphViewModel` is the Undo Timeline's `actions:`.

**Story items not fully met.** Item 5's `--dart-define` host is superseded (11.5's project switching exists; the graph mounts through `ProjectSession`). The workspace name stays off the wire (Dart-side: the single working copy on @'s commit; null when several share it). The 10.1–10.4 witness suites still run on recordings; on real layouts the invariants, accessor mirroring and column stability are checked. Event → paint is not measured, only the worker round trip.

**Review.** 42 findings — high 0, medium 6, low 24, false 12. Patched: 6 medium, 10 low (extras per operation with an `at_operation()` test; no remount on project open/close (host and shortcuts); Edit › Find test; CRLF subject; dead getter; contract log; awaited router; card-data, edge-kind and bucket assertions; reassemble test; doc reflow). Deferred: 2 (contract catch untested at the call site; Marionette check) — mirrored into deferred-work.md. Rejected: the rest, each with its reason in the triage log.

**Follow-up review: recommended (true).** Six medium findings were patched, among them the window's composition (host and shortcut wrappers) and the extra-operations bookkeeping; the mounted window has not been exercised in a running app (no Marionette run), so a follow-up should check the project window with a real repository.

**Residual risks.** The full gate has not run (the loop runs it). The extra-operations map grows for the session (marked `shortcut:`). The whole shell rebuilds on every graph-model notification, as the catalogue does.
