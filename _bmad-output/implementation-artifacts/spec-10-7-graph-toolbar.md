---
title: "Story 10.7 — Graph controls in the floating top bar — the count, View options (Layout, Detailed cards, Group stacks, Card width), New change"
type: 'feature'
created: '2026-10-31'
status: 'done'
baseline_revision: '40e32014f0f89b76b8b9d7d07b39e9cf50f7b7f2'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** The floating top bar's VIEW and ACTION slots are empty islands: there is no count, no View options popover (Layout, Detailed cards, Group stacks, Card width), no New change, and the graph preferences are not persisted. Open items I1 (the counter's `|all()|`) and I2 (popover calm hold) name 10.7.

**Approach:** Build epics.md Story 10.7 (`_bmad-output/planning-artifacts/epics.md:9584-9712`; the 2026-10-14 and 2026-10-16 notes win over items 1–9) as slot widgets over `GraphViewModel`, a `GraphPreferences` binding to `zanshin_settings`, and a Widgetbook use case that hosts them in the floating shell over the fake graph. Mounting in the project window is 10.12's (it mounts the graph).

## Boundaries & Constraints

**Always:**
- **Count** (2026-10-14 item 6; DS chrome.jsx:83, kit.css:59-60, :210): 12 px sans (kit.css:59), tabular figures, `--text-dim`, padding 0 6 0 2; the number bold (600) in `--text-muted`. N = `layout.shownCount`, M = `layout.totalCount` (`|all()|`, 4.10's `all_count`). N < M → "**N** of M"; otherwise "**M** changes"; M null → "**N** changes"; no layout → nothing. Tooltip "N of M changes shown" (M known). One `Text.rich`.
- **VIEW content**, in order: the count, `ZsIslandSeparator`, the View options `ZsIconButton(ZI.viewOptions, label "View options", active while open)`. Leave room for 10.21's search and 10.19's legend (they come before the count). At window width (`MediaQuery.sizeOf`) ≤ 1040 the count and its separator are not built.
- **View options popover** (2026-10-14/16 notes; DS chrome.jsx:87-98, kit.css:62 `.zk-pop-r`): `ZsPopover(width 340, label "View options")`, its top 14 below the button, its right edge 5 right of the button's right edge, clamped 8 inside the window; header "Graph view"; rows: Layout `ZsSegmented` Free | Compact (tooltips "Rows follow commit time" / "Rows = dependency depth"), Detailed cards `ZsSwitch`, Group stacks `ZsSwitch` (row tooltip "Collapse linear runs of changes into one stack card"), Card width `ZsSlider(160–400, step 10, unit "px", width 120)`; `ZsPopoverSeparator`; `ZsOptionLink("Appearance, diffs and more", action "Settings…")`, no shortcut, its `onPressed` a nullable widget parameter (null → disabled; 11.7 passes `openOrActivate` on General, as 11.5's Settings… row). Open/close on the button; outside press and Esc close it; Esc is consumed inside the popover (focus moves into it on open, back to the button on close) and never reaches the graph. Exit animation via `ZsPopover.closing`/`onClosed`.
- **Calm hold (I2):** while the popover is open (including its exit) it holds `ShellScope.maybeOf(context)?.openSurface()`; released on close and on dispose.
- **Rows' effects:** Layout → `model.setMode` (re-centres @, one layout request); Group stacks → new `model.setStacks(bool)` (sets `GraphRequest.stacks`, one request, keeps the anchor — no re-centre); Detailed cards and Card width → `GraphViewOptions` only, no layout request (rows/columns are independent of card size; the viewport keeps its anchor). Every change persists app-globally.
- **Persistence:** new `GraphSettings` sub-model in `zanshin_settings` under `AppSettings.graph`: `layout` (enum `GraphLayoutSetting { free, compact }`, default free), `detailedCards` true, `groupStacks` true, `cardWidth` 240. `GraphPreferences` (app) over `SettingsStore`: exposes `options` (`GraphViewOptions` incl. layout) and `groupStacks`, setters write through `store.update` (a failed write logged by the store, swallowed like `FloatingShellViewModel`), clamps width to 160–400 and snaps to 10.
- `GraphViewModel.init` gains `mode` and `stacks` parameters so the stored preferences go into the first request (calling a setter before `init` must stay unnecessary).
- **New change** (2026-10-14/16 notes; DS chrome.jsx:105, kit.css:211): `ZsButton(variant primary, size lg, icon ZI.plus, label "New change")` in a `ZsTooltip("jj new — start a new change on top of @")`; at window width ≤ 920 `iconOnly`. Press → `model.run(GraphNew(parents: [@'s key]))`; disabled while `!model.actionsEnabled`, without `GraphActions`, or without @ in the layout. The view model already moves a selected @ to the born change and reveals it.
- Only Zs controls; strings in `app/lib/l10n/app_en.arb` (plurals via ICU), `jj new` marked `// l10n-ignore:` only if it sits in Dart; no hard-coded UI strings. Semantics come from the Zs controls.

**Never:** the search field (10.21), the gap legend (10.19), Fetch/Push (11.8), the Settings window (11.7), menu-bar items ⌘1/⌘2/⌘N (11.13), the born card's grow/rise animation and its reduce-motion fade (10.20 owns graph animations), mounting the graph or controls in `HomePage` (10.12), a lane-order control, advanced pass-through parameters, any Rust/FFI change, golden tests.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Filtered | shown 12, total 340 | "**12** of 340", tooltip "12 of 340 changes shown" | — |
| All shown | shown 340, total 340 | "**340** changes" | — |
| Total unknown | shown 12, total null | "**12** changes" | — |
| Narrow | width 1040 | no count, no separator; button stays | — |
| Layout | Free → Compact | one request, mode compact, re-centre on @, stored compact | — |
| Group stacks | on → off | one request with `stacks: false`, no re-centre, stored | — |
| Card width | slider to 300 | options width 300, no request, stored 300 | — |
| Esc | popover open, a card selected | popover closes, selection unchanged | — |
| New change | @ = k, actions fake | fake gets one `GraphNew(parents:[k])` | no @ / busy → disabled |
| Narrow action | width 920 | New change icon only, tooltip still there | — |
| Settings write fails | store write throws | value kept in memory, no crash | logged by store |

</intent-contract>

## Code Map

- `_bmad-output/planning-artifacts/epics.md:9584-9712` -- Story 10.7; the notes at :9591-9631 (2026-10-14) and :9633-9650 (2026-10-16) win; witnesses :9622-9629, :9645-9650.
- `app/lib/src/features/shell/top_bar.dart:34-101` -- `ShellTopBar` slots `view` (wrapped in `ZsIsland` here — give it the content only) and `newChange` (its own island: the lg primary button); slots must report intrinsic widths (no `LayoutBuilder`; `floating_shell.dart:47-58` "What a slot must bring").
- `app/lib/src/features/shell/floating_shell.dart:61-110` -- `FloatingShell(graph:, view:, newChange:, atPill:, staleNotice:)`.
- `app/lib/src/features/shell/shell_scope.dart:44-47` -- `ShellScope.maybeOf(context)?.openSurface()` → `CalmHold` (`calm_controller.dart:34-50,102,119`).
- `app/lib/src/features/projects/project_capsule.dart:90-120` -- the calm-hold pattern to copy (`_opened`/`_closed`/dispose); test `app/test/features/projects/project_capsule_test.dart:~480-501` asserts `controller.calm.held`.
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart:262-360` -- `RawMenuAnchor` + `TapRegion` + `CustomSingleChildLayout` + closing/onClosed pattern; build the popover anchor the same way (the popover is menu material, not glass, so it may mount through the overlay from inside the island).
- `packages/zanshin_ui/lib/src/controls/zs_popover.dart:25-76,121-215` -- `ZsPopover`, `ZsPopoverHeader`, `ZsOptionRow`, `ZsPopoverSeparator`, `ZsOptionLink` (disabled when `onPressed` null); catalogue example `app/widgetbook/folders/controls.dart:1165-1212`.
- `packages/zanshin_ui/lib/src/controls/`: `zs_segmented.dart:23-120`, `zs_switch.dart:33-65`, `zs_slider.dart:43-108`, `zs_button.dart:23-170` (`ZsButton` primary/lg/icon/iconOnly), `:295-365` (`ZsIconButton` `active`), `zs_tooltip.dart`; `materials/zs_glass.dart:177` `ZsIslandSeparator`; `ZI.viewOptions`, `ZI.plus`.
- `app/lib/src/features/graph/graph_view_model.dart:147-191,327-345,698-707` -- `_mode`, `init`, `setMode`/`setLaneOrder` (pattern for `setStacks` without `_recentre`), `_build` (add `stacks:`); `shown`/`total` :244-248; `actionsEnabled` :292; `run` :410; `_succeeded` moves selection for `GraphNew` :534-549.
- `app/lib/src/features/graph/graph_ports.dart:13-90,181-200` -- `GraphRequest.stacks`, `GraphNew(parents:)`, `GraphActions`.
- `app/lib/src/features/graph/graph_layout.dart:268-271,317-360` -- `shownCount`, `totalCount`; `GraphViewOptions` (layout, laneOrder, detailedCards, cardWidth).
- `crates/zanshin-jj/src/topology.rs:43,230` / `packages/zanshin_core/lib/src/ffi/graph.dart:375` -- 4.10 already ships `all_count` → I1 settled (10.12 maps it to `totalCount`).
- `packages/zanshin_settings/lib/src/model/app_settings.dart`, `layout_settings.dart` (sibling pattern), `zanshin_settings.dart` (exports); regenerate with `dart run build_runner build -d` in the package; tests in `packages/zanshin_settings/test/model/`.
- `app/lib/src/features/shell/floating_shell_view_model.dart:65-75` -- store write + `onError<FileSystemException>` pattern; `app/lib/src/features/projects/project_registry.dart` -- a class over `SettingsStore`.
- `app/widgetbook/folders/graph.dart:241-344` -- `_ViewModelDemo` (FakeGraphSource over the recordings); `app/widgetbook/folders/shell.dart` (`FloatingShellDemo`, width knob via `FittedBox`+`SizedBox` — override `MediaQuery.size` with the knob width so the 1040/920 rules show); `app/widgetbook/demo_projects_fakes.dart:229` -- a temp-file `SettingsStore`.
- Tests: `app/test/features/graph/graph_view_test.dart:66-120` (`_Host`, `_Actions` fake, `wrap`), `graph_view_model_test.dart`, `app/test/helpers/scripted_graph_source.dart`, `app/test/features/shell/top_bar_test.dart`; `app/test/widgetbook/catalogue_smoke_test.dart`.
- DS (read-only): `_bmad-output/implementation-artifacts/design_system/ui_kits/desktop/chrome.jsx:80-106`, `kit.css:59-62,210-211`, `components/surfaces/surfaces.css:6`.
- Open items: `_bmad-output/implementation-artifacts/deferred-work.md` sections "Surfaced 2026-09-26 while researching the commit-graph view…" (I1) and "Surfaced in Story 11.3 (bmad-build-auto, 2026-10-18)" (I2).

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_settings/lib/src/model/graph_settings.dart` (new, + generated `.freezed.dart`/`.g.dart`), `app_settings.dart` (+ regenerated), `zanshin_settings.dart` -- `GraphSettings`, `GraphLayoutSetting`, `AppSettings.graph`; test: defaults, JSON round-trip, an old file without `graph` loads defaults.
- `app/lib/src/features/graph/graph_view_model.dart` -- `init(…, mode, stacks)`, `stacks` getter, `setStacks` (no re-centre), `_build` sends `stacks`.
- `app/lib/src/features/graph/graph_preferences.dart` (new) -- `GraphPreferences` (ChangeNotifier or ValueListenable over the store) with `options`, `groupStacks`, `setLayout`, `setDetailedCards`, `setGroupStacks`, `setCardWidth`, and `bind(GraphViewModel)`/apply helpers so a change goes to both store and model.
- `app/lib/src/features/graph/graph_controls.dart` (new) -- `GraphCount`, `GraphViewControls` (VIEW content: count, separator, View options anchor + popover with calm hold), `NewChangeButton`.
- `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`) -- count (plural), tooltip, "View options", "Graph view", row labels/tooltips, "Appearance, diffs and more", "Settings…" (reuse `settingsEllipsis`), "New change", its tooltip.
- `app/widgetbook/folders/graph.dart` -- a "Floating shell" use case (window width knob, MediaQuery override): `FloatingShell` with `GraphView`, the controls, the @ pill and a demo `GraphActions` fake that answers `GraphNew` with a born id; preferences on a temp-file store.
- Tests: `app/test/features/graph/graph_controls_test.dart` (new) -- the matrix rows; popover holds calm while open and releases on close/dispose; Esc in the popover leaves the selection; each row's request count (Layout 1 + re-centre reveal, Group stacks 1 without reveal, Detailed/width 0) and the stored values; restored preferences go into the first request; only Zs controls in the tree (no `material_ui` widget types); New change disabled cases; 1040/920 rules. `graph_view_model_test.dart` -- `setStacks`, `init(mode, stacks)`. Catalogue smoke test pumps the new use case.
- `_bmad-output/planning-artifacts/epics.md` -- a dated "Built 2026-10-31" note under Story 10.7 (what shipped; handed to 10.12, 10.19, 10.20, 10.21, 11.7, 11.13); `deferred-work.md` -- resolution sub-bullets on I1 and I2.

**Acceptance Criteria:**
- Given the catalogue's floating-shell use case at 1440, when it builds, then the VIEW island shows the count, a separator and the View options button, and ACTION shows "New change".
- Given the popover open in a shell, when calm scrolling is reported, then `calm.held` is true and no calm phase starts; after closing (or unmounting) `held` is false.
- Given stored preferences compact / stacks off / width 300, when a model is created through `GraphPreferences`, then its first request has mode compact and `stacks: false` and the view options width 300.
- Given every graph control in the capsule and the popover, then each is a Zs control and no `material_ui` widget is in the tree.

## Spec Change Log

## Review Triage Log

### 2026-10-31 — Review pass
- verdicts: 22 findings — high 0, medium 0, low 16, false 6, maybe-false 0 (the reviewed diff excludes generated `.freezed.dart`/`.g.dart`/`app_localizations*.dart`, the epic context and this spec)
- findings:
  - `[low]` `[patch]` (verification-gap) the popover's 8 px window clamp has no test — added a short-window test asserting it stays inside the bottom edge.
  - `[low]` `[reject]` (verification-gap other) one store change flipping Layout and Group stacks at once sends two layout requests (setMode then setStacks queue) — only another writer changes both at once (the UI and 11.13 change one at a time); the final state is right; a combined setter adds public surface.
  - `[false]` `[reject]` (intent) I1's real data path: no production layout carries `|all()|` — no production `GraphSource` exists yet; 10.12 adopts it and its scope lists `|all()|` (epics.md:10272); the counter reads `totalCount`, so I1 is settled.
  - `[false]` `[reject]` (intent) nothing mounts the controls in `HomePage` — the graph itself is not mounted until 10.12 ("where the graph mounts in the shell"); the controls are slot widgets hosted in the catalogue's floating shell.
  - `[false]` `[reject]` (intent) witnesses not exercised: born-card grow / reduce-motion fade, ⌘1/⌘2, Settings on General, gap legend — owned by 10.20, 11.13, 11.7/11.12 and 10.19 (each story's own scope), recorded in the Built note.
  - `[false]` `[reject]` (intent) Detailed / Card width issue zero requests against the witness's "exactly one" — follows the epic's technical decision (rows independent of card size, `GraphRequest` has no size field); Design Notes record it.
  - `[low]` `[reject]` (blind) two layout requests for one outside change — same as the verification-gap other finding.
  - `[low]` `[reject]` (blind) deleting the temp settings folder can race a queued write (catalogue dispose, test teardown) — temp folder only, catalogue/test code; awaiting the store queue adds async teardown plumbing.
  - `[low]` `[reject]` (blind) no thousands separator in the count — the design prints raw numbers (DS chrome.jsx:83); cosmetic.
  - `[low]` `[reject]` (blind) `GraphPreferences.model` is never released — a disposed `GraphViewModel` ignores `setMode`/`setStacks` (`_requestLayout` returns on `_disposed`); one preferences object per host today.
  - `[false]` `[reject]` (blind) view options run ahead of the landed layout — the canvas never reads `options.layout` (graph_canvas.dart:497 compares the `GraphLayout` object); mode comes from the landed layout.
  - `[low]` `[reject]` (blind) a press during the exit animation is dropped — same as `ZsMenuAnchor`'s house pattern; the exit lasts `durExit`; a reopen-while-closing branch adds complexity.
  - `[low]` `[patch]` (blind) the popover clamp is untested — grouped with the verification-gap finding; same test.
  - `[low]` `[patch]` (blind) New change "disabled while stale" untested — added a stale-refusal test.
  - `[low]` `[reject]` (blind) an outside tap leaves focus nowhere — same as `ZsMenuAnchor` (outside tap closes without refocus); the tap usually lands on the graph, whose press takes focus.
  - `[low]` `[reject]` (blind) bold weight set twice (`fwSemibold` + `FontVariation.weight(600)`) — the house pattern (project_capsule.dart:233-234); cosmetic.
  - `[low]` `[reject]` (blind) a stored width another writer set is not snapped in the store — `options` and the slider read it snapped; only display matters.
  - `[low]` `[patch]` (edge) a non-finite stored card width (hand-edited `1e400`) throws in `snapCardWidth` on every build — non-finite falls back to 240; unit test added.
  - `[low]` `[patch]` (edge) `totalCount` < `shownCount` (a revset naming hidden commits) reads fewer changes than shown — M is `max(total, shown)`; test row added.
  - `[low]` `[reject]` (edge) a press during the exit is dropped — same as the blind finding.
  - `[low]` `[reject]` (edge) the global `_rigs` list is not cleaned when a test body throws — only after a failing test; test hygiene.
  - `[false]` `[reject]` (edge) the catalogue demo's write into a deleted folder — grouped with the blind temp-folder finding; a failed write is logged and swallowed by design, no crash.

## Design Notes

- "Each popover row issues exactly one layout request" (witness :9626) is read with the epic's technical decision "a layout is requested once per operation, never on resize": `GraphRequest` has no card-size field, so Detailed and Card width issue none and the viewport keeps its anchor; Layout and Group stacks issue one each.
- I1 is settled, not fixed: 4.10 already returns `all_count`, and `GraphLayout.totalCount` carries it.
- The "Appearance, diffs and more" row ships disabled until 11.7 passes its action (the 11.5 Project menu precedent); 11.7's scope already names "View options" as an opener.

## Verification

**Commands:**
- `dart run build_runner build -d` in `packages/zanshin_settings` -- generated files committed, no diff on rerun.
- `flutter test` in `packages/zanshin_settings` and `app` -- green.
- `dart analyze --fatal-infos` in `packages/zanshin_settings` and `app` -- no issues.
- `dart format --set-exit-if-changed .` in both (width from the shared `formatter.page_width`) -- clean.

**Verification notes (2026-10-31; gate rule of the story loop: no `cargo make test`/`test-full`/`coverage`):**
- `packages/zanshin_settings`: `flutter test` 37 passed; `dart analyze --fatal-infos` no issues; `dart format --set-exit-if-changed .` 0 changed; `dart run build_runner build -d` wrote 0 outputs (generated files current).
- `app`: `flutter test test/features/graph test/features/shell test/widgetbook` 815 passed after the review patches (824 incl. `project_capsule_test` before them); `flutter test test/l10n test/app test/features/app test/features/home test/features/bootstrap test/features/window` 177 passed; `test/features/projects` 222 passed, 5 failed — all in `worker_project_repos_test.dart`, which stop on "XDG_CONFIG_HOME is not pinned … run via cargo make" (need the gate's environment; untouched by this story); `dart analyze --fatal-infos` no issues; `dart format --set-exit-if-changed .` 0 changed.
- No Rust, FFI or schema change: no cargo checks, no codegen, no parity oracle.
- Marionette (implementation run): the catalogue's Graph › Floating shell › Controls in night and paper — count, separator, View options, gold New change, the popover right-aligned under its button, Compact re-lays out, Detailed off shows compact cards; the 1040/920 widths only in widget tests.

## Auto Run Result

Status: done. Commit `9288bd0e7531703a901b9e6c431c90997c355928` (code), plus the docs commit that carries this spec.

**Summary.** The graph's controls for the floating top bar's slots: the count, the View options popover and New change, the persisted View options, and a catalogue use case hosting them in `FloatingShell` over the fake graph. Mounting in the project window comes with the graph in 10.12.

**Files.**
- `app/lib/src/features/graph/graph_controls.dart` (new) -- `GraphCount`, `GraphViewControls`, `GraphViewOptionsButton` (RawMenuAnchor + `ZsPopover`, calm hold, Esc consumed), `NewChangeButton`.
- `app/lib/src/features/graph/graph_preferences.dart` (new) -- `GraphPreferences` over `AppSettings.graph`, binds a model.
- `app/lib/src/features/graph/graph_view_model.dart` -- `init(mode:, stacks:)`, `stacks`, `setStacks`, `hasActions`; the request sends `stacks`.
- `packages/zanshin_settings/lib/src/model/graph_settings.dart` (new, + generated), `app_settings.dart` (+ generated), `zanshin_settings.dart` -- `GraphSettings`, `GraphLayoutSetting`, `AppSettings.graph`.
- `app/lib/l10n/app_en.arb` (+ regenerated localizations) -- the controls' strings.
- `app/widgetbook/folders/graph.dart` -- Graph › Floating shell › Controls (width knob also sets the window width).
- Tests: `app/test/features/graph/graph_controls_test.dart` (new, 31), `graph_view_model_test.dart`, `graph_harness.dart` (`totalCount`), `app/test/widgetbook/catalogue_smoke_test.dart`, `packages/zanshin_settings/test/model/app_settings_test.dart`, `settings_store_test.dart`.
- Docs: epics.md "Built 2026-10-31" note under 10.7; deferred-work.md resolution bullets on I1 and I2; sprint-status 10-7 done; epic-10-context.md recompiled.

**Open items.**
- I1 — rejected as no longer applying (settled): 4.10 already ships `all_count` (`crates/zanshin-jj/src/topology.rs:43,230`; `packages/zanshin_core/lib/src/ffi/graph.dart:375`), `GraphLayout.totalCount` carries it and the count uses it; the real source mapping is 10.12's (its scope lists `|all()|`).
- I2 — fixed (commit 9288bd0e): Story 10.7's part — the View options popover holds the shell's calm while open, its exit included, released on close and on dispose; tests "holds calm while open…" and "releases calm when unmounted while open". The rest of I2 stays with 10.21 and 11.8.

**Review.** 22 findings: 4 low patched (non-finite stored width, `total < shown`, popover clamp test, stale-disabled test), 18 rejected with reasons in the triage log (6 false, 12 low), 0 deferred. Patched by verdict: high 0, medium 0, low 4 → follow-up review not recommended.

**Residual risks.** Two layout requests if one store change flips Layout and Group stacks together (only another writer can); the Card width slider writes the store on every step of a drag (≤ 24 writes); at ≤ 920 px the icon-only New change nests `ZsButton`'s own label tooltip inside its `jj new` tooltip (not checked which shows); the full gate runs at the loop's end.
