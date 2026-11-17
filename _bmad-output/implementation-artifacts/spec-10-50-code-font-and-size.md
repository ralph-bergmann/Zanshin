---
title: 'Story 10.50 — Code font and size: a font and a point size for code, apart from the zoom'
type: 'feature'
created: '2026-11-17'
status: 'done'
baseline_revision: 'fec9b30bd66094f8a6f2dd36ef1611dee195ea56'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The config file editor now draws in the code style (11 pt × 1.65 by default) while the design system still gives it 12/19.5.
    evidence: |-
      config_file_page.dart `_editor` takes CodeStyleScope as epic Story 10.50 item 5 asks; DS settings.css:104 still reads --fs-md/19.5px. A DS change goes through the design-artifacts skill in a console session.
    location: >-
      app/lib/src/features/settings/config_file_page.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** The code in the diffs is fixed at `ZsType.code` (11 px JetBrains Mono, `packages/zanshin_ui/lib/src/design/zs_type.dart:256`); it stays too small even with the app zoom, and its font cannot be chosen. Flutter on macOS uses installed fonts by name but cannot list them and falls back silently on a missing one (deferred-work item I1).

**Approach:** The runner lists the installed fixed-pitch families over a new `zanshin/fonts` method channel; two app settings hold the code font family and the code size in points; one place derives the code style from them, and the code blocks (inspector diff, operation view diff, config file editor) take it from an inherited scope instead of `ZsType.code`. Settings › General › Diffs gets "Code font" and "Code size" rows after Layout (design `Inspector Extras Study.html` §5).

## Boundaries & Constraints

**Always:**
- Channel `zanshin/fonts`, method `monospacedFamilies`: the families of `NSFontManager.shared.availableFontFamilies` whose regular face is fixed pitch, sorted case-insensitively. The filter is a static function the XCTest calls (keeps Menlo, drops Helvetica). The class lives beside `MenuStateChannel` in `WindowingBootstrap.swift` (no new Xcode file) and is started in `WindowingBootstrap.start()`.
- Settings in `GeneralSettings` (`packages/zanshin_settings`): `String? codeFont` (null = the built-in JetBrains Mono) and `@Default(11) int codeSize` (points). Old files without the keys load the defaults.
- The derived code style is `ZsType.code` with: family = the saved family, or `ZsType.monoFamily` when none is saved or the saved one is not in the runner's list; `fontFamilyFallback` = `[ZsType.monoFamily, ZsType.sansFamily]`; `fontSize` = the code size clamped to 6…72 (a hand-edited file must not draw invisible or huge text); `height` stays 1.65. While the list is unknown (not read yet, or the channel failed), the saved family is used as is.
- The app zoom multiplies the size through the existing `WindowZoomBox` (11 pt at 125 % = 13.75 px); no zoom code changes.
- A missing saved family keeps the setting (nothing is written); the font comes back once installed and read again.
- The list is read when the app starts (`ZanshinApplication.start`) and when the Settings window opens (`SettingsViewModel.init`).
- Strings go through `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`); "JetBrains Mono" is a placeholder value marked `// l10n-ignore`.

**Never:**
- No change to change ids, bookmark and tag chips, the composer's command line, gap and fold rows, toasts, notes (`InspectorDiffView._note`, operation view `_Text`) or any other mono UI text.
- No keyboard shortcut for the code size; no weight, ligature or line-height setting; no DS change.
- No edit to `ZsType.code` itself (the scope falls back to it where no window root is above, e.g. tests and the catalogue).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Defaults | no `codeFont`, `codeSize` 11 | code draws `ZsType.monoFamily` at 11, height 1.65 | none |
| Font picked | `codeFont: "Menlo"`, Menlo in list | code family `Menlo`, fallbacks JetBrains Mono then Inter | none |
| Font gone | `codeFont: "Gone Mono"`, list read without it | code family `ZsType.monoFamily`; select shows "Gone Mono (not installed) — using JetBrains Mono"; setting unchanged | none |
| List unknown | channel throws / not read yet | saved family used as is; select lists built-in + saved family | `PlatformException`/`MissingPluginException` caught, list stays null |
| Size 14 | `codeSize: 14` | diff text 14, number column measured at 14 (wider) | none |
| Size off list | hand-edited `codeSize: 17` | select shows "17 pt" added in order | none |
| Size absurd | hand-edited `codeSize: 0` / `500` | drawn at 6 / 72 | clamp |

</intent-contract>

## Code Map

- `app/macos/Runner/WindowingBootstrap.swift:12-41` -- `WindowingBootstrap.start()` creates the channels; `MenuStateChannel` `:79-164` is the pattern (channel + static testable function). Add `FontsChannel` here.
- `app/macos/RunnerTests/RunnerTests.swift` -- XCTests, `@testable import zanshin`; add the filter test. Run with `cargo make --allow-private test-runner` (`Makefile.toml:180`).
- `packages/zanshin_settings/lib/src/model/general_settings.dart:44-75` -- add `codeFont`, `codeSize` after `fileMasks`; regenerate `.freezed.dart`/`.g.dart` (`dart run build_runner build` in the package). Tests: `test/model/app_settings_test.dart` (defaults, round trip, missing keys), `test/settings_store_test.dart:16-26` (`_darkJson` gains `"codeFont": null, "codeSize": 11` after `fileMasks`).
- `packages/zanshin_ui/lib/src/design/zs_type.dart:24, 256-265` -- `monoFamily` (bundled `packages/zanshin_ui/JetBrainsMono`), `sansFamily`, `code` (read only).
- New `app/lib/src/features/window/code_font.dart` -- `InstalledCodeFonts` (`@inject @singleton`, `ChangeNotifier`, `families` null until read, `refresh()` over `MethodChannel('zanshin/fonts')`, a `.withReader` constructor for tests), `codeTextStyle(GeneralSettings, List<String>?)`, `codeFontMissing(...)`, `CodeStyleScope` (InheritedWidget, `of(context)` → `ZsType.code` without a scope).
- `app/lib/src/features/window/zanshin_app_view_model.dart:21-24` -- add `InstalledCodeFonts` ctor param, listen to it, `codeStyle` getter. Test `app/test/features/window/zanshin_app_view_model_test.dart:40, 89, 153` construct it.
- `app/lib/src/features/window/zanshin_window_root.dart:88` -- wrap `ZsRoot` (inside `WindowZoomBox`) in `CodeStyleScope(style: vm.codeStyle)`.
- `app/lib/src/app/zanshin_application.dart:24, 39-44` -- inject `InstalledCodeFonts`, `unawaited(fonts.refresh())` in `start()`.
- `app/lib/src/features/settings/settings_view_model.dart:331-337` -- `required this.codeFonts`; `init()` refreshes and listens, `dispose()` stops. Construction sites: `app/lib/src/app/app_module.dart:76-81`, `app/test/helpers/settings_rig.dart:93`, `app/widgetbook/folders/windows.dart:732`.
- `app/lib/src/features/settings/general_tab.dart:171-188` -- add the two rows after Layout (`ZsSelect<String?>` and `ZsSelect<int>`, the `_diffNumberRow` off-list pattern `:304-336`).
- `app/lib/src/features/graph/inspector_diff.dart` -- `_noNewline` `:352`, `_lineText` `:365` (take a `TextStyle code` instead of `ZsType.code`), number measurement `:1682-1688`, `_number` `:1972`, call sites `:2383, 2393, 2405, 2461-2465` in `_unified`/`_sideBySide` (read `CodeStyleScope.of(context)` there). Leave `_note` `:1293` and gap/fold rows.
- `app/lib/src/features/settings/config_file_page.dart:194-198, 391-399, 518-627` -- `_editorStyle`/`_strut`/`_lineHeight` derive from the scope's code style (`StrutStyle.fromTextStyle(..., forceStrutHeight: true)`); the gutter is `max(44, digit width + 10)` so large sizes do not clip numbers. Test `app/test/features/settings/config_file_page_test.dart`.
- `app/lib/src/features/undo_timeline/operation_changes.dart:1006, 1051` -- uses `InspectorDiffView`, so it follows without change.
- `app/lib/l10n/app_en.arb` near `settingsDiffLayout` (`:2019-2056`) -- new strings.
- Codegen: `dart run build_runner build --delete-conflicting-outputs` in `app` (updates `main.inject.dart`, `test/helpers/test_component.inject.dart`).
- Tests: `app/test/features/graph/inspector_diff_test.dart:478-500` (`view` helper), `app/test/features/settings/settings_window_test.dart:246-260` (`pumpGeneral`, `pick`), new `app/test/features/window/code_font_test.dart`.

## Tasks & Acceptance

**Execution:**
- `app/macos/Runner/WindowingBootstrap.swift` -- `FontsChannel` + `static func monospacedFamilies(of:)`; start it in `start()`.
- `app/macos/RunnerTests/RunnerTests.swift` -- `testFontsChannelKeepsFixedPitchFamiliesOnly`: `["Helvetica", "Menlo"]` → `["Menlo"]`.
- `packages/zanshin_settings/lib/src/model/general_settings.dart` (+ generated, tests) -- the two settings.
- `app/lib/src/features/window/code_font.dart` -- fonts holder, derivation, scope.
- `app/lib/src/features/window/zanshin_app_view_model.dart`, `zanshin_window_root.dart`, `app/lib/src/app/zanshin_application.dart` -- derive and provide the style; read at start.
- `app/lib/src/features/settings/settings_view_model.dart`, `general_tab.dart`, `app_module.dart`, `settings_rig.dart`, `widgetbook/folders/windows.dart` -- the rows and the read on open.
- `app/lib/src/features/graph/inspector_diff.dart`, `app/lib/src/features/settings/config_file_page.dart` -- take the scope's style.
- `app/lib/l10n/app_en.arb` + `flutter gen-l10n` -- strings.
- Tests: `code_font_test.dart` (derivation matrix, `refresh` sorted list / failure keeps null / notifies), `zanshin_app_view_model_test.dart` (style follows store and list), `inspector_diff_test.dart` (size 14: text 14 px, number column wider than at 11; Menlo family; no-newline marker), `settings_window_test.dart` (rows after Layout, picks write `codeFont`/`codeSize`, missing label, size labels), `config_file_page_test.dart` (editor and gutter use the scope's size).

**Acceptance Criteria:**
- Given code size 14 under a `CodeStyleScope`, when the inspector diff draws, then line text is 14 px, the number column is wider than at 11, and the gap rows keep their size.
- Given code font Menlo, when the diff and the config file editor draw, then they use family `Menlo`; text outside the scope (ids, chips) keeps its own style.
- Given a saved family not in the runner's list, when the app's code style is derived, then it draws `ZsType.monoFamily` and the Code font select shows "<name> (not installed) — using JetBrains Mono", and `settings.json` keeps the family.
- Given the Settings General tab, when it shows, then Code font and Code size sit right after Layout, with "JetBrains Mono · built in" first and "11 pt · default" for 11.
- Given the runner filter, when XCTest runs it on Helvetica and Menlo, then only Menlo stays.

## Spec Change Log

## Review Triage Log

### 2026-11-17 — Review pass
- verdicts: 25 findings — high 0, medium 6, low 14, false 5, maybe-false 0
- findings:
  - `[medium]` `[patch]` (verification-gap) nothing tests that the window root installs `CodeStyleScope` from the saved settings; every other test builds its own scope — patched: `zanshin_window_root_test.dart` checks the root's scope at `codeSize` 14 and after a store update to 12.
  - `[low]` `[patch]` (verification-gap) the Code font row's redraw when the font list arrives late is masked by `_load`'s notify — patched: `SettingsRig.codeFontReader`; a test releases a `Completer` reader after the window settled and the row lists the families and marks the saved one.
  - `[low]` `[patch]` (verification-gap) the Dart half of `zanshin/fonts` (channel and method name) is never exercised — patched: `code_font_test.dart` mocks `zanshin/fonts`, checks the method `monospacedFamilies` and that `InstalledCodeFonts().refresh()` fills the sorted list.
  - `[false]` `[reject]` (verification-gap, other) the missing-family branch is redundant because the fallback list draws JetBrains Mono anyway — no bad outcome is claimed; the branch is what the epic asks (a missing family draws JetBrains Mono and the label says so), and the drawn glyphs are the same either way.
  - `[medium]` `[patch]` (edge) the font enumeration runs on the main thread at boot — measured 1.4 s cold, about 260 ms warm, for 202 families on this Mac — patched: the handler answers from a serial background queue, the filter uses CoreText (`CTFontManagerCopyAvailableFontFamilyNames` without "."-names; a family counts when its default face resolves to itself with `.traitMonoSpace`), measured the same 10 families as the NSFontManager filter, about 125 ms warm off the main thread; the XCTest still keeps Menlo and drops Helvetica.
  - `[false]` `[reject]` (edge) two overlapping `refresh()` calls can complete out of order — the handler answers on one serial queue (kept serial on purpose when the work moved off the main thread), so the replies keep the order of the calls and an older list cannot land after a newer one.
  - `[low]` `[patch]` (edge) a hand-edited `codeSize` of 0 or 500 shows "0 pt"/"500 pt" while the code draws at 6/72 — patched: the select's value and added option are the clamped size; a test saves 500 and sees "72 pt" with the store keeping 500.
  - `[low]` `[reject]` (edge) a hand-edited `codeFont` differing from the installed name only by case is marked not installed — the font is picked from the runner's list, never typed; only a hand edit with the wrong case meets it, and the label then says what happens.
  - `[low]` `[defer]` (edge) the config file editor's default moves from the DS's 12/19.5 to the code style (11 / 1.65) — intended by the epic (item 5, "Diffs and the config file") but the DS (`settings.css:104`) still says 12/19.5; a DS sync goes through the `design-artifacts` skill in a console session. Deferred.
  - `[low]` `[patch]` (blind) the Code size select shows a size the app does not draw — same root cause as the edge row; patched with it (clamped value).
  - `[low]` `[patch]` (blind) "JetBrains Mono" can show twice when it is also installed on the Mac — patched: an installed "JetBrains Mono" is left out of the options unless it is the saved family; two tests (shown once; saved shows as itself).
  - `[low]` `[reject]` (blind) the missing-family swap keeps a font installed after start replaced until Settings opens — the epic's rule: the font "comes back after the next start"; Settings' open re-reads it sooner.
  - `[low]` `[reject]` (blind) the family list is sorted three times — negligible cost on about ten names; each sort serves its own place (the runner's answer, the stored list's change check, the saved family's place).
  - `[medium]` `[patch]` (blind) no Dart test pins the channel name and method — same as the verification-gap row; patched with it (mock-channel test).
  - `[medium]` `[patch]` (blind) no test checks that `ZanshinWindowRoot` installs the scope — same as the verification-gap row; patched with it (window-root test).
  - `[medium]` `[patch]` (blind) the enumeration runs on the main thread at boot, unmeasured — same as the edge row; patched with it (serial background queue, CoreText).
  - `[low]` `[reject]` (blind) `codeFontMissing` compares case-sensitively — same reason as the edge row.
  - `[low]` `[reject]` (blind) the built-in font's name is a literal in the view, apart from `ZsType.monoFamily` — the bundled family name (`packages/zanshin_ui/JetBrainsMono`) is not a display name; the label is one l10n-ignored literal, and a font swap would be a DS change touching both anyway.
  - `[low]` `[defer]` (blind) the config file editor changes for users who change nothing, and the DS still says 12/19.5 — same as the edge row; deferred.
  - `[low]` `[reject]` (blind) the widgetbook catalogue cannot show the setting taking effect — the Marionette check runs in the real app (temp home, the runner answers the channel, the window root installs the scope); a catalogue use case adds nothing the app check lacks.
  - `[false]` `[reject]` (intent) the ledger surfaces (deferred-work.md, sprint-status.yaml) are not in the diff — they are written at finalization in the same commit as the spec.
  - `[medium]` `[patch]` (intent) the tests exercise injected scopes, not the window-root wiring or the channel round trip — same as the verification-gap rows; patched with the window-root and mock-channel tests (rows above). The 125 % witness holds by construction (the scope sits inside `WindowZoomBox`); the Marionette check is the console session's.
  - `[false]` `[reject]` (intent) the config editor's default changes — not a divergence: the epic lists the config file page's editor among the code blocks; the DS row above is deferred.
  - `[false]` `[reject]` (intent) additions the intent does not ask for (clamp, off-list entries, 240 px cap, unknown-list rule, config gutter) — each keeps a stated rule working (a hand-edited file, a missing font, a large size); none changes a specified behavior.
  - `[low]` `[patch]` (intent) JetBrains Mono twice when installed — same as the blind row; patched with it.

## Design Notes

The scope sits inside each window root's `WindowZoomBox`, so every window (project, Settings, Undo Timeline's operation view in the project window) gets the same style from one getter, `ZanshinAppViewModel.codeStyle`. Line numbers are measured with the same style, so the column grows with the size. The config file editor moves from 12 px / 19.5 to the code style (11 px / 1.65 at the default), as the epic's scope item 5 and the study's hint ("Diffs and the config file") ask.

## Verification

**Commands:**
- `flutter test` in `packages/zanshin_settings`, `dart analyze`, `dart format --set-exit-if-changed .` -- pass.
- `flutter test test/features/window test/features/graph/inspector_diff_test.dart test/features/settings test/features/undo_timeline test/widgetbook` in `app`, `dart analyze`, `dart format --set-exit-if-changed lib test widgetbook` -- pass.
- `cargo make --allow-private test-runner` -- XCTests pass.

## Auto Run Result

Status: done (commit `6b421a4029d12de66b86160c09735ae5228dbe4f`).

**Summary.** The runner lists the installed fixed-pitch families over `zanshin/fonts` (`monospacedFamilies`); `general.codeFont` (null = built-in JetBrains Mono) and `general.codeSize` (pt, default 11) hold the choice; `codeTextStyle` derives the code style and every window root provides it through `CodeStyleScope` inside its zoom box. The inspector diff (lines, line numbers and their measured column, no-newline marker, both layouts), the operation view's diff (through `InspectorDiffView`) and the config file editor (its gutter widens to fit) read it instead of `ZsType.code`. Settings › General › Diffs shows Code font and Code size right after Layout; a saved family missing from the list draws JetBrains Mono and reads "<name> (not installed) — using JetBrains Mono" without being rewritten. The list is read at app start and when the Settings window opens.

**Items.**
- I1 — fixed (`6b421a4029d12de66b86160c09735ae5228dbe4f`): code size in points apart from the zoom (zoom multiplies it), font picker from the runner's list, a missing font falls back to JetBrains Mono and says so.

**Files changed.**
- `app/macos/Runner/WindowingBootstrap.swift` — `FontsChannel` (serial background queue, CoreText filter), started in `start()`.
- `app/macos/RunnerTests/RunnerTests.swift` — filter keeps Menlo, drops Helvetica.
- `packages/zanshin_settings/lib/src/model/general_settings.dart` (+ generated, tests) — `codeFont`, `codeSize`.
- `app/lib/src/features/window/code_font.dart` — `InstalledCodeFonts`, `codeTextStyle`, `codeFontMissing`, size limits and choices, `CodeStyleScope`.
- `app/lib/src/features/window/zanshin_app_view_model.dart`, `zanshin_window_root.dart`, `app/lib/src/app/zanshin_application.dart` — derive, provide, read at start.
- `app/lib/src/features/settings/settings_view_model.dart`, `general_tab.dart`, `app/lib/src/app/app_module.dart` — the rows and the read on open.
- `app/lib/src/features/graph/inspector_diff.dart`, `app/lib/src/features/settings/config_file_page.dart` — take the scope's style.
- `app/lib/l10n/app_en.arb` (+ gen-l10n), `app/lib/main.inject.dart`, `app/test/helpers/test_component.inject.dart` — strings, DI codegen.
- Tests: `code_font_test.dart` (new), `zanshin_app_view_model_test.dart`, `zanshin_window_root_test.dart`, `inspector_diff_test.dart`, `settings_window_test.dart`, `config_file_page_test.dart`, `settings_rig.dart`; `app/widgetbook/folders/windows.dart` constructs the view model.

**Review.** 25 findings (medium 6, low 14, false 5). Patched: window-root scope test, late font-list redraw test, mock-channel test, font enumeration off the main thread (measured 1.4 s cold on main before), clamped size label, JetBrains Mono shown once. Deferred (mirrored in deferred-work.md): the config editor's DS sync (12/19.5 → code style). Rejected with reasons in the triage log: case-insensitive family match, missing-family staleness until Settings opens (the epic's rule), repeated sorts, the built-in name literal, the catalogue not showing the setting, the redundant-branch note, out-of-order replies (serial queue), ledger surfaces, the intended config editor change, the unasked-for guards.

**Follow-up review: recommended** — three medium entries were patched (counts: medium 3, low 3). The named unverified risk: the runner's channel handler (serial queue, CoreText default-face check) runs only in the app; the XCTest covers the static filter, and the Dart test a mocked channel, so the round trip in the running app is checked first by the console session's Marionette run.

**Verification (targeted, per the run's gate rule — no full gate).**
- `packages/zanshin_settings`: `flutter test` 64 pass; `dart analyze` clean; `dart format --set-exit-if-changed .` 0 changed.
- `app`: `flutter test test/features/window test/features/graph/inspector_diff_test.dart test/features/settings test/features/undo_timeline test/widgetbook test/l10n test/architecture test/app` — 1016 pass; `dart analyze` clean; `dart format --set-exit-if-changed lib test widgetbook` 0 changed.
- `cargo make --allow-private test-runner` — 8 XCTests pass, the font filter included.
- Earlier, the implementer's full `app` `flutter test` showed 6 failures in `worker_project_repos_test.dart` / `remote_sync_test.dart` that need the gate's pinned environment ("XDG_CONFIG_HOME is not pinned … run via `cargo make test-app`"); not touched by this change, left to the loop's final gate.

**Residual risks.**
- The filter now uses CoreText (`CTFontManagerCopyAvailableFontFamilyNames`, default face `.traitMonoSpace`) instead of the spec's `NSFontManager` wording, for thread safety off the main thread; on this Mac both give the same 10 families. Variable fonts list under their family name (Ralph's Monaspace shows as "Monaspace Argon Var"); SF Mono is not a system-installed family here, so it is not listed.
- The config file editor draws smaller by default (11 / 1.65 instead of 12 / 19.5), as the epic asks; the DS sync is deferred.
- No visual check in the running app; the Marionette check against the study is the console session's.
