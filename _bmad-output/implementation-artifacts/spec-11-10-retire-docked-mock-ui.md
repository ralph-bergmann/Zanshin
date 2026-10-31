---
title: 'Story 11.10: Retire the docked mock UI — mock shell, nav rail, status bar, MockCommit/MockProject widgets, ZanshinColors'
type: 'chore'
created: '2026-10-30'
status: 'done'
baseline_revision: '8bd1c34b8e3c048eab8b53a2d4ea4ef79ca38072'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The DS's app-icon bundle prescribes solid layer fills over white-stroked open paths, which Icon Composer renders as filled crescents.
    evidence: |-
      design_system/assets/app-icon/Zanshin-NamiIndigo.icon/icon.json gives each wave layer "fill": {"solid": ...} over Wave-*.svg drawn stroke="#ffffff"; an xcrun actool render of that showed three crescents. The app bundle strokes each layer in its gold with "fill" : "none" instead (Spec Change Log). A DS re-sync would bring the crescents back.
    location: >-
      _bmad-output/implementation-artifacts/design_system/assets/app-icon/Zanshin-NamiIndigo.icon/icon.json
    severity: low
    resolved: >-
      2026-10-31 — fixed (console session, design-artifacts): the DS bundle is byte-equal to the app's (stroked waves, no layer fill), its README explains it; the DS artifact is republished.
---

<intent-contract>

## Intent

**Problem:** The app still carries the docked mock UI of an earlier design (mock shell, nav rail, status bar, title bar with Fetch/Pull/Push, history/branch panels, mock commit card/detail/diff, the mock Projects dialog, `MockCommit`/`MockProject`, `ZanshinColors`/`context.zc`), the unused `Zanshin.ttf` icon font, the `workstream` glyph, the Yaru dependency with its Ubuntu fonts, and the POC hosts `main2/3/4.dart` + `features/graph_poc/`. None of it is reachable from the running app; it drags Yaru's fonts into the bundle without their licence (I9) and keeps a tolerated leftover in the icon set check.

**Approach:** Delete it all (epics.md Story 11.10 items 1–6 and its 2026-10-16 note), drop `yaru` from `app/pubspec.yaml` (the window root uses only the token theme), re-author the app icon with the DS's three wave layers in Icon Composer's format, and add the optional catalogue parity test (every `_ds_manifest.json` component has a use case or is listed as owned by an open story).

## Boundaries & Constraints

**Always:** `material_ui` stays (hosted pub.dev `^1.1.0`, lock 1.8.0) — it hosts `MaterialApp`, overlays, localisations and token extensions. Keep `ZanshinIcon`/`ZI`, `tree_drop.dart`, the floating shell (`features/shell/{floating_shell,rail,…}`), the boot/splash/window controllers, `app/widgetbook/main.dart`. The token theme of `ZanshinWindowRoot` is unchanged on macOS. Tests that read a file outside their package get that path in `crates/xtask/src/tasks/gate_plan.rs`.

**Never:** No new demo host `main*.dart`. No change to the boot flow. No Dock check (Ralph's). Do not touch `stuff/` notes. Do not lower coverage or add excludes. No full gate in this run (story-loop gate rule): targeted checks only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Built bundle fonts | `flutter test` asset bundle | `FontManifest.json` has no `packages/yaru/*`, no family containing `Ubuntu`, no `Zanshin` family | test fails naming the family |
| Icon set check | `ZI.all`, app SVGs, DS glyphs | one set, no leftover tolerated | mismatch names the glyph |
| Manifest parity | `_ds_manifest.json` component names | every name is covered by an existing catalogue use-case path, owned by an open story (id listed), or has a no-use-case reason; the three lists are disjoint and their union equals the manifest | test names the unlisted / stale / unknown-path entry |
| App icon bundle | `app/macos/Runner/NamiIndigo.icon` | three layers Wave-Top/Mid/Bottom, files byte-equal to the DS's, solid fills gold-200/400/600 | test names the layer |

</intent-contract>

## Code Map

- `app/lib/src/features/shell/{app_shell,main_nav_rail,status_bar,window_title_bar}.dart` -- mock chrome (I3, I5 `NavPanel.workstream`, `ZI.workstream` users) -- delete.
- `app/lib/src/features/history/history_column.dart`, `branches/branches_panel.dart`, `commits/{commit_card,commit_detail,diff_block}.dart`, `shared/widgets/commit_tags.dart`, `projects/home_dialog.dart`, `shared/data/mock_data.dart` -- mock panels/data (I4) -- delete. 10.8 models its inspector on `commit_detail.dart`/`diff_block.dart`: read them at `8bd1c34b8e3c048eab8b53a2d4ea4ef79ca38072` (epics.md:9765-9767 gets a dated note).
- `app/lib/src/shared/theme/zanshin_colors.dart` (`context.zc` force-unwrap, I1) and `zanshin_icons.dart` (old font `IconData`, unused) -- delete; `app/assets/fonts/zanshin_icons/Zanshin.ttf` + pubspec `fonts:` family `Zanshin` (`app/pubspec.yaml:60-63`) -- delete.
- `app/lib/main2.dart`, `main3.dart`, `main4.dart`, `app/lib/src/features/graph_poc/*`, `app/test/features/graph_poc/commit_graph_view_test.dart` -- POC hosts (I2) -- delete.
- `app/lib/src/features/app/zanshin_app.dart:25-68` -- commented-out mock theme (`ZanshinColors`) -- delete; the Yaru `_Example` page is already gone (11.12).
- `app/lib/src/features/window/zanshin_window_root.dart:9,54-64,119-121` -- the only `package:yaru` import in `app/lib` (Linux `YaruTheme` branch, `yaruLight/yaruDark` fallbacks) -- drop the Linux branch (macOS-only app), make `lightTheme`/`darkTheme` required non-null. `vm.selectedMode` stays used by `setThemeMode`/`effectiveMode`.
- `app/pubspec.yaml:27-28` -- `yaru: path: ../../yaru.dart` -- delete; run `flutter pub get` at the workspace root (`pubspec.lock` drops yaru + yaru_window*; `app/macos/Flutter/GeneratedPluginRegistrant.swift` regenerates if plugins drop). `flutter_svg` is already absent (I8/I9).
- `packages/zanshin_ui/lib/src/icons/zanshin_icon.dart:210-212,275` -- `ZI.workstream` + its `all` entry -- delete; `packages/zanshin_ui/assets/icons/svg/workstream.svg` -- delete (I6).
- `packages/zanshin_ui/test/design/ds_parity_test.dart:67-68,93-94` -- `_leftover` tolerance -- remove so the check demands exactly the `glyphs.json` set.
- `app/test/assets/font_manifest_test.dart` -- add the "no Ubuntu / Yaru / Zanshin font" test (I9).
- `app/macos/Runner/NamiIndigo.icon/{icon.json,Assets/waves.svg}` -- one `waves.svg` layer; DS bundle `_bmad-output/implementation-artifacts/design_system/assets/app-icon/Zanshin-NamiIndigo.icon/` has `Wave-Top/Mid/Bottom.svg` with a hand-written schema (README.txt: fills #f4cf80, #dca85b, #b58346) -- re-author in Icon Composer's schema (keep the existing gradient/group/platform keys; three layers with `"fill": {"solid": "srgb:…"}`), copy the three SVGs, delete `waves.svg`; folder reference in pbxproj is unchanged (I7). Validate with `xcrun actool`.
- `app/test/macos/runner_chrome_assets_test.dart` -- add the icon bundle test (layers, byte-equal SVGs, fills = `ZsColors` `--gold-200/400/600` within 1/255).
- `app/test/widgetbook/` -- new `ds_manifest_parity_test.dart` (I10); use-case paths as `catalogue_smoke_test.dart:20-25` builds them (Widgetbook slug: spaces → `-`, lowercase).
- `crates/xtask/src/tasks/gate_plan.rs:140-144` + its test at `:981-986` -- the `design_system/` rule plans UI only; the app tests now read the manifest and the icon bundle -> plan `[UI, APP]`.

## Tasks & Acceptance

**Execution:**
- Delete every file in the first four Code Map bullets, the `Zanshin.ttf` font + pubspec family, and the commented code in `zanshin_app.dart`.
- `zanshin_window_root.dart` -- remove `dart:io`/`foundation` Linux branch and the Yaru import/fallbacks; update its doc comment.
- `app/pubspec.yaml` -- drop `yaru`; `flutter pub get`; commit the lock and any regenerated registrant.
- `zanshin_icon.dart`, `workstream.svg`, `ds_parity_test.dart` -- remove the workstream glyph and the leftover.
- `font_manifest_test.dart` -- add the no-Ubuntu/no-Yaru/no-`Zanshin` family test.
- `NamiIndigo.icon` + `runner_chrome_assets_test.dart` -- three-layer bundle and its test.
- `ds_manifest_parity_test.dart` -- three explicit maps: `covered` (name → use-case path), `openStories` (name → story id: AtPill 10.6, PeekCard 10.6, DiffHunk/DiffView 10.24, FileRow 10.8, GraphEnd 10.19, StackCard 10.17, DropMenu 10.10, Toast 10.23, PushDialog 11.8, SearchScopes/SearchDollar/GraphSearch/SearchMenu/SearchPopover/SearchGroup/SearchRow/SearchMatch/SearchTag/SearchAvatar 10.21, RevsetDialog 10.22, ImmutablePage/SettingsGroup/SettingsPage/SettingsRow 11.7, CalloutText 10.14), `noUseCase` (Wordmark: path drawn only inside the splash card; TrafficLights: macOS's native buttons) -- union = manifest names, disjoint, every covered path exists.
- `gate_plan.rs` -- `design_system/` → `Need::Groups(&[UI, APP])`, reason names the app tests; update the test.
- `epics.md:9765-9767` -- dated note that 11.10 removed the mock models and where to read them.

**Acceptance Criteria:**
- Given the change, when grepping `app/lib` and `app/test`, then there is no `MockProject`, `MockCommit`, `context.zc`, `ZanshinColors`, `AppShell`, `MainNavRail`, `StatusBar`, `WindowTitleBar`; `app/lib` and `app/assets` contain no `workstream`; no file imports `package:yaru`; `app/pubspec.yaml` has neither `yaru` nor `flutter_svg` nor the `Zanshin` font family; `app/lib` holds no `main*.dart` besides `main.dart`.
- Given the app package, when `flutter test`, `dart analyze --fatal-infos --fatal-warnings` and `dart format --set-exit-if-changed` run in `app/` and `packages/zanshin_ui/`, then all pass, including the four tests of the I/O matrix.
- Given `crates/xtask`, when `cargo test -p xtask`, clippy and fmt run, then they pass.

## Spec Change Log

### 2026-10-30 — Step-03 verification: the icon's layer fills
- **Finding:** the I/O row "App icon bundle" (DS SVGs byte-equal + solid layer fills) compiles (`xcrun actool`), but Icon Composer paints a layer's solid fill over the region each open stroke path encloses: the rendered `.icns` showed three filled crescents instead of three waves.
- **Amended (implementation, not the intent-contract):** each layer SVG is the DS geometry with its stroke coloured `#f4cf80` / `#dca85b` / `#b58346` (the DS file strokes `#ffffff` for a fill to tint), and every layer has `"fill" : "none"`, as the old one-layer bundle did. The test checks the SVG equals the DS file with only the stroke colour swapped to the `--gold-200/400/600` token, and the fill is `none`.
- **Known-bad state avoided:** an app icon whose waves render as solid crescents.
- **KEEP:** the three layers in order, the existing gradient/group/platform keys, no stray file in `Assets/`, the actool render check.

## Review Triage Log

### 2026-10-30 — Review pass
- verdicts: 24 findings — high 0, medium 0, low 15, false 7, maybe-false 2
- findings:
  - `[low]` `[patch]` blind: the Epic 10 house rule (epics.md:8242, also :537, :8427) still points open stories at `graph_poc/`, `main4.dart`, `commit_graph_view_test.dart` — dated note at the house rule naming revision `8bd1c34b8e3c048eab8b53a2d4ea4ef79ca38072`.
  - `[low]` `[patch]` blind: epics.md:9765 "stay for Ralph to retire" contradicts the new 10.8 note — sentence rewritten.
  - `[false]` `[reject]` blind: story bookkeeping (sprint-status, deferred-work, spec commit) missing from the diff — the diff was staged before finalization; the closing commit carries the spec, sprint-status and deferred-work.
  - `[low]` `[defer]` blind: the DS app-icon bundle (`design_system/assets/app-icon/Zanshin-NamiIndigo.icon/icon.json`, README.txt) still prescribes solid fills over white-stroked open paths, which Icon Composer renders as crescents — the DS is changed only through the design-artifacts flow; deferred and mirrored.
  - `[low]` `[reject]` blind: the icon test maps the layers to `--gold-200/400/600` by hand instead of reading the DS icon.json — the tokens are the colour source of truth and equal the DS README values; the DS icon.json is not an Icon Composer file to read from.
  - `[low]` `[reject]` blind: the icon test skips the gradient and group settings — unchanged pre-existing values (the old bundle's display-p3 gradient = #1d2540 → #131831); pinning them adds colour-space conversion for no observed defect.
  - `[low]` `[patch]` blind: the three new SVGs lack a final newline (`.editorconfig`) — newline added.
  - `[low]` `[reject]` blind: `stuff/zanshin_icons/` (the retired font's sources, incl. `workstream`) remains — `stuff/` is Ralph's notes folder (gate: "notes"), outside the witnesses (`app/lib`, `app/assets`); the spec's Never keeps it untouched.
  - `[low]` `[reject]` blind: `_openStories` can go stale when a story closes — done keys leave sprint-status (hand-curated), so no reliable machine check exists; the story that builds a component edits the map (the test names the entry).
  - `[low]` `[reject]` blind: `_covered` checks path existence, not that the use case renders the component — per-use-case widget probing is new machinery; mappings were verified by reading the builders (Code Map, research table).
  - `[low]` `[reject]` blind: no AssetManifest check for `packages/yaru/` — yaru is gone from `pubspec.lock`, so no package can contribute its assets; the font test covers the licence-relevant part.
  - `[low]` `[patch]` blind: the `ZanshinWindowRoot` doc comment line overruns the 120-column wrap — re-wrapped.
  - `[low]` `[reject]` blind: `_WindowMaterialApp` / `_keyed` are single-caller wrappers now — harmless structure, inlining is refactoring beyond the story.
  - `[low]` `[reject]` blind: epics.md:13167 cites `app/assets/icons/svg/workstream.svg` for the deleted `packages/zanshin_ui/assets/icons/svg/workstream.svg` — cosmetic in Ralph's planning note; the Auto Run Result names the real path.
  - `[low]` `[patch]` edge: a Finder `.DS_Store` in `NamiIndigo.icon/Assets` would fail the exact file list — dot-files ignored.
  - `[low]` `[reject]` edge: duplicate names in `_ds_manifest.json` would collapse into the set — the manifest is generated per component export; a guard adds a check for a case never observed.
  - `[false]` `[reject]` intent: the I1–I10 record, deferrals and verification results are not in the diff — written at finalization (this section and `## Auto Run Result`).
  - `[false]` `[reject]` intent: the icon contract row (byte-equal + solid fills) contradicts the implementation — recorded deviation in the Spec Change Log with the actool render as evidence; the intent ("three gold waves") is met.
  - `[maybe-false]` `[reject]` intent: I9 is checked on the test bundle, not the built `.app` — both bundles' FontManifest come from the same pubspec font declarations; settling it needs a `flutter build macos` (if true only low).
  - `[maybe-false]` `[reject]` intent: I10's ids are never checked to be open — same as the blind finding above; if true only low.
  - `[false]` `[reject]` intent: "boots into the floating shell" has no test — `app/test/features/app/zanshin_app_test.dart:210` ("the home is HomePage over the floating shell") still runs and passed.
  - `[false]` `[reject]` intent: item 5 (DI regenerated) not evidenced — no DI type referenced a deleted file; `dart analyze --fatal-infos --fatal-warnings` passed on `app`, and the generated files compile unchanged.
  - `[false]` `[reject]` verification-gap: no gaps found (no finding to act on).
  - `[false]` `[reject]` intent: Workstream remnant in `rail.dart:10` comment ("Workstreams is dropped") — it documents the decision, not a remnant; the witness is the lowercase glyph name.

## Design Notes

The Linux `YaruTheme` branch is dead weight: Zanshin is a macOS app (CLAUDE.md, project-context) and no Linux runner exists. With it gone, `material_ui` is the only Material library; it already resolves from pub.dev (hosted), so the fork's `material_ui` bookmark question (I8) is moot.

The parity test's third list (`noUseCase`) exists because two manifest entries can never be a catalogue use case without new scope: the wordmark is a path inside the splash card (boot is a non-goal) and the traffic lights are native.

## Verification

**Commands:**
- `flutter pub get` (repo root) -- expected: resolves without yaru.
- `flutter test` in `app/` and `packages/zanshin_ui/` -- expected: all pass.
- `dart analyze --fatal-infos --fatal-warnings` in `app/` and `packages/zanshin_ui/` -- expected: no issues.
- `dart format --set-exit-if-changed .` in `app/` and `packages/zanshin_ui/` -- expected: exit 0.
- `cargo test -p xtask`, `cargo clippy -p xtask --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: pass.
- `xcrun actool` compile of `NamiIndigo.icon` into a scratch dir -- expected: an `Assets.car` and no error.
- `git grep` witnesses of the first AC -- expected: no hits.

**Verification notes (2026-10-30, story-loop gate rule: no full gate):**
- `flutter pub get` (root) -- resolved; `pubspec.lock` drops yaru, yaru_window*, window_manager, screen_retriever*; `GeneratedPluginRegistrant.swift` regenerated.
- `cargo make --allow-private test-flutter` (the app suite with the gate's pinned env) -- `+1085: All tests passed!`. (A bare `flutter test` in `app/` fails 5 pre-existing `worker_project_repos_test.dart` cases that need the gate's `XDG_CONFIG_HOME`.) After the review patches: the five touched/new test files re-run, `+32: All tests passed!`.
- `flutter test` in `packages/zanshin_ui` -- `+425: All tests passed!`.
- `dart analyze --fatal-infos --fatal-warnings app packages/zanshin_ui` -- No issues found (after the patches too).
- `dart format --set-exit-if-changed` on both -- 0 changed (after the patches).
- `cargo test -p xtask` -- 26 passed; `cargo clippy -p xtask --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean.
- `xcrun actool NamiIndigo.icon --compile <scratch> --platform macosx --app-icon NamiIndigo` -- `Assets.car` + `NamiIndigo.icns`, no error; `sips` render shows three gold stroked waves on the indigo gradient (the first, solid-fill version rendered crescents; Spec Change Log).
- Witness greps (`MockProject|MockCommit|context.zc|ZanshinColors|AppShell|MainNavRail|StatusBar|WindowTitleBar|package:yaru|workstream|flutter_svg|family: Zanshin` over `app/lib app/test app/assets app/pubspec.yaml`) -- no hits; `app/lib` holds only `main.dart` (+ its generated `main.inject.dart`).
- Not run: the full gate (`cargo make test`, coverage) -- the loop runs it once at its end; no Marionette check (no visible UI changed; the removed code was unreachable).

## Auto Run Result

Status: done. Commits: `9a7f3c64af86b341dc7d2174d10298f768b0136f` (code, tests, lock, icon, gate plan) and the docs commit that carries this spec.

**Summary.** The docked mock UI, `ZanshinColors`/`context.zc`, the `Zanshin.ttf` icon font, `ZI.workstream` + its SVG, the POC hosts `main2/3/4.dart` + `features/graph_poc/`, the `yaru` dependency and `ZanshinWindowRoot`'s Linux `YaruTheme` branch are gone. The app icon has the DS's three Nami wave layers. New tests: no Yaru/Ubuntu/`Zanshin` font in the bundle, the icon bundle's layers, and the DS-manifest catalogue parity test.

**Files.**
- Deleted (app): `features/shell/{app_shell,main_nav_rail,status_bar,window_title_bar}.dart`, `history/history_column.dart`, `branches/branches_panel.dart`, `commits/{commit_card,commit_detail,diff_block}.dart`, `projects/home_dialog.dart`, `shared/{data/mock_data,theme/zanshin_colors,theme/zanshin_icons,widgets/commit_tags}.dart`, `assets/fonts/zanshin_icons/Zanshin.ttf`, `main2.dart`, `main3.dart`, `main4.dart`, `features/graph_poc/*` + its test, `NamiIndigo.icon/Assets/waves.svg`.
- Deleted (zanshin_ui): `assets/icons/svg/workstream.svg`.
- `app/lib/src/features/app/zanshin_app.dart` -- commented mock theme removed.
- `app/lib/src/features/window/zanshin_window_root.dart` -- Linux Yaru branch and fallbacks removed; themes non-null.
- `app/pubspec.yaml`, `pubspec.lock`, `app/macos/Flutter/GeneratedPluginRegistrant.swift` -- yaru and the `Zanshin` font family dropped.
- `packages/zanshin_ui/lib/src/icons/zanshin_icon.dart`, `test/design/ds_parity_test.dart` -- `ZI.workstream` and the tolerated leftover removed.
- `app/macos/Runner/NamiIndigo.icon/{icon.json,Assets/Wave-{Top,Mid,Bottom}.svg}` -- three stroked layers, `"fill" : "none"`.
- `app/test/assets/font_manifest_test.dart`, `app/test/macos/runner_chrome_assets_test.dart`, `app/test/widgetbook/ds_manifest_parity_test.dart` (new) -- the tests above.
- `crates/xtask/src/tasks/gate_plan.rs` -- `design_system/` plans `[UI, APP]`.
- `_bmad-output/planning-artifacts/epics.md` -- dated notes at the Epic 10 house rule and Story 10.8 (removed files readable at `8bd1c34b8e3c048eab8b53a2d4ea4ef79ca38072`).

**Items I1–I10.**
- **I1** fixed (`9a7f3c6`): the mock UI and `ZanshinColors`/`context.zc` are deleted; the Yaru `_Example` test page was already gone (Story 11.12), its leftover commented theme code is removed.
- **I2** fixed (`9a7f3c6`): `main2.dart`, `main3.dart`, `main4.dart` and `features/graph_poc/` (+ test) removed; the demo host stays the Widgetbook Graph folder.
- **I3** fixed (`9a7f3c6`): `main_nav_rail.dart`, `status_bar.dart`, `window_title_bar.dart` deleted; Pull stays settled by epics.md Story 11.10's 2026-10-16 note (no pull verb in jj v0.46.0, nothing replaces the button).
- **I4** fixed (`9a7f3c6`): the mock panels incl. `commit_detail.dart` and `diff_block.dart` deleted; 10.8 reads them from git history (dated note at epics.md Story 10.8 and the Epic 10 house rule).
- **I5** fixed (`9a7f3c6`): the Workstream remnants (`NavPanel.workstream`, the "Workstreams" side panel with `jj workstream new`) went with the mock files; `app/lib`/`app/assets` hold no `workstream`.
- **I6** fixed (`9a7f3c6`): `ZI.workstream` and `packages/zanshin_ui/assets/icons/svg/workstream.svg` removed (the story text's `app/assets/...` path is stale); the icon set check tolerates no leftover.
- **I7** fixed (`9a7f3c6`): the bundle re-authored in Icon Composer's schema with Wave-Top/Mid/Bottom stroked `#f4cf80`/`#dca85b`/`#b58346`; compiled with actool and rendered. Deviation: no solid layer fills (they render crescents) -- the DS bundle's own fills are deferred. The Dock check is Ralph's.
- **I8** fixed (`9a7f3c6`): `yaru` removed from `app/pubspec.yaml`, no file imports it; `material_ui` resolves from pub.dev (hosted `^1.1.0`, locked 1.8.0), so the fork-bookmark question is moot.
- **I9** fixed (`9a7f3c6`): Yaru and its fonts are retired; `font_manifest_test.dart` verifies the bundle's `FontManifest.json` lists no `packages/yaru/*`, no `Ubuntu` and no `Zanshin` family (checked on the test bundle; both bundles come from the same pubspec declarations).
- **I10** fixed (`9a7f3c6`): `app/test/widgetbook/ds_manifest_parity_test.dart` -- 52 components mapped to catalogue use cases, 26 to their open stories (10.6, 10.8, 10.10, 10.14, 10.17, 10.19, 10.21, 10.22, 10.23, 10.24, 11.7, 11.8), Wordmark and TrafficLights with a reason; union = manifest, disjoint, every path exists.

**Review findings.** 24 findings (high 0, medium 0, low 15, false 7, maybe-false 2). Patched 5 low: the Epic 10 house-rule note, the 10.8 sentence, SVG final newlines, dot-files ignored in the icon test, the doc-comment wrap. Deferred 1 low: the DS icon bundle's solid fills (mirrored in deferred-work.md "Surfaced in Story 11.10"). Rejected (reasons in the Review Triage Log): bookkeeping not in the diff (done at finalization), hand-mapped icon colours (tokens are the source), gradient/group not pinned, `stuff/zanshin_icons/` (notes folder), staleness of `_openStories` and `_covered`, AssetManifest check, single-caller wrappers, the story text's stale path, duplicate manifest names, the I1–I10 record, the icon contract deviation (logged), test-bundle vs `.app` FontManifest, the boot witness, DI regeneration, the verification-gap "none", the `rail.dart` comment.

**Follow-up review recommendation:** false (patched: 5 low, 0 medium, 0 high).

**Residual risks.** The full gate has not run (the loop runs it): this change touches `crates/xtask/` and `pubspec.lock`, so the gate plans everything. The new icon is checked by an actool render only, not in the Dock. `_openStories` must be edited by each story that builds one of its components (the test names the entry).
