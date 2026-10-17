---
title: 'Story 11.14 — The zanshin_ui package: tokens, materials and the DS icons leave app/'
type: 'refactor'
created: '2026-10-17'
status: 'done'
baseline_revision: 'c7bd851e1637d9cca0b6c56c07d248bd664bb467'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The gate-plan rules list each Dart package's dependents by hand, and nothing checks them against the pubspecs, so a new path dependency (11.11 adding one to zanshin_ui, say) makes the gate under-plan without an error.
    evidence: |-
      Review pass 2026-10-17 (blind hunter): crates/xtask/src/tasks/gate_plan.rs RULES hard-codes the dependents of zanshin_settings, the three shell packages and zanshin_ui; the inline test every_package_zanshin_ui_depends_on_plans_zanshin_ui_and_the_app hard-codes the same four paths. Pre-existing since d81ebd9 (the change-aware gate); this story only added one more package to it.
    location: >-
      crates/xtask/src/tasks/gate_plan.rs
    severity: medium
    resolved: >-
      2026-10-17 — fixed (spec-11-14-closing-gate-rules-and-font-licences, commit cc8f353): the inline test a_flutter_package_plans_itself_and_every_package_depending_on_it derives each workspace member's dependents from the pubspecs and checks every package rule against them; a changed member pubspec now plans every step.
  - summary: >-
      The OFL texts of Inter, JetBrains Mono and Shippori Mincho may not reach the shipped app's licence notices, which may fall short of the OFL's redistribution terms.
    evidence: |-
      Unverified (review pass 2026-10-17, blind hunter): the debug bundle's NOTICES.Z holds no OFL text; the OFL.txt files sit next to the fonts but no LICENSE file or LicenseRegistry entry brings them into the notices. Pre-existing before the move. To settle: check whether the OFL is satisfied by the licence fields inside the TTFs' name tables, or whether the app must carry the texts (a LICENSE file in packages/zanshin_ui, which flutter_tools collects, or LicenseRegistry.addLicense).
    location: >-
      packages/zanshin_ui/assets/fonts/
    severity: medium (unverified)
    resolved: >-
      2026-10-17 — fixed (spec-11-14-closing-gate-rules-and-font-licences, commit 4795404): the TTF name tables fall short of OFL §2, so zanshin_ui's pubspec lists the three OFL.txt under flutter: licenses: and an app test checks the bundle's NOTICES.Z holds each verbatim.
---

<intent-contract>

## Intent

**Problem:** 11.1 and 11.2 put the token layer, the materials and the DS icons inside the app (`app/lib/src/shared/{design,materials,widgets}`), so nothing stops them from importing `features/`, a feature-only change reruns their tests, and 11.11's controls and every later importer would make the move dearer (Ralph's decision 2026-10-17, superseding 11.1's design question (a)).

**Approach:** Move them, their tests, the three DS fonts and the SVG icons with their transformer into a new Flutter workspace package `packages/zanshin_ui` that the app consumes only through `package:zanshin_ui/zanshin_ui.dart`; keep `IconModule` (DI) in the app; give the gate a `UI` step group. A pure move: behaviour, visuals, public names and doc comments stay — only import, asset and font paths change.

## Boundaries & Constraints

**Always:**
- epics.md Story 11.14 (`_bmad-output/planning-artifacts/epics.md:13067-13125`) is the requirement; its items 1–6, non-goals and witnesses apply as written. Claude's proposals there are accepted defaults.
- Move files with `git mv` so history follows. Code is moved, not rewritten: the only edits in moved files are import paths, the `IconModule` split, `IconRegistry.load`'s `packageName`, the `ZsType` family constants, and doc comments or test paths that name a moved location.
- `packages/zanshin_ui/pubspec.yaml`: `resolution: workspace`, the SDK/Flutter constraints of `packages/zanshin_settings/pubspec.yaml`; dependencies exactly `flutter`, `material_ui`, `vector_graphics`, `zanshin_settings`, `zanshin_shell` (path deps); dev dependencies `flutter_lints`, `flutter_test`, `vector_graphics_compiler`. `analysis_options.yaml` = `include: ../../linter/flutter.yaml` + `analyzer: exclude: [build/**]`.
- The package's `lib/` imports no `flutter_test`, no `inject_*`, no `zanshin_core`, nothing under `app/`; Material types only from `material_ui`.
- SPDX first line on every new `.dart` file; page width 120; `dart analyze --fatal-infos --fatal-warnings` and `dart format` clean in both `app/` and `packages/zanshin_ui/`.
- `cargo make test` / `test-full` runs from the main session only, never from a subagent (gate runs inside subagents get killed).

**Never:**
- No behaviour, visual, token-value or API-name change; no refactor beyond paths. No new export beyond what `app/` uses today.
- Not split into several packages; `app/widgetbook/` is not created or moved; `shared/theme/`, `shared/widgets/commit_tags.dart`, `shared/data/` stay in the app; the Lottie files and `Zanshin.ttf` stay in the app; the mock UI's `'monospace'` literals stay; `AccentSource` and `ShellTheme` stay where they are.
- No edits under `_bmad-output/implementation-artifacts/design/` or `design_system/`; no `coverage-baseline.txt` lowering or `exclude_prefix`.
- Never hand-edit `app/lib/main.inject.dart`; regenerate it.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| App boot, icons | debug app; `IconRegistry.load()` | every `ZI.all` glyph resolves from `packages/zanshin_ui/assets/icons/svg/<name>.svg` (precompiled) | a missing glyph fails the boot as today |
| App tests, icons | `flutter test` in `app/`; `setUpIconRegistry()` | the real registry loads from the dependency's transformed assets; bootstrap tests pass | — |
| Package tests, icons | `flutter test` in `packages/zanshin_ui/` | the registry loads (flutter_test strips the `packages/zanshin_ui/` prefix for the root package's own assets) | — |
| Fonts at runtime | `ZsType.sansFamily` etc. | `'packages/zanshin_ui/Inter'`, `'packages/zanshin_ui/JetBrainsMono'`, `'packages/zanshin_ui/ShipporiMincho'` — the families a dependency's fonts register under | — |
| Mono fallback / CSS shorthand | `ZsType.id`, `ZsType.toCss()` | `fontFamilyFallback: [sansFamily]` and `fontFamily == monoFamily` still pick mono; the `fontSans`/`fontMono`/`fontKanji` CSS stacks are unchanged, so the DS parity test stays green | — |
| Transformer refuses package assets | proof build or package test fails on the moved SVGs | fallback: SVGs back to `app/assets/icons/svg/`, `IconRegistry.load` without `packageName` (the app's bundle), the DS parity test reads `../../app/assets/icons/svg`; recorded in `deferred:` | stop the move of the SVGs only; everything else proceeds |
| Gate plan | changed path `packages/zanshin_ui/…` / `app/lib/…` / `…/design_system/…` / `packages/zanshin_settings/…` | UI + APP / APP only / UI only / SETTINGS + UI + APP | — |

</intent-contract>

## Code Map

- `_bmad-output/planning-artifacts/epics.md:13067-13125` -- Story 11.14 (scope items 1–6, non-goals, witnesses). `:12841-12923` 11.11 (consumes the package next).
- `app/lib/src/shared/design/` (10 files: `zs_accents`, `zs_app_theme`, `zs_appearance`, `zs_colors`, `zs_elevation`, `zs_metrics`, `zs_motion`, `zs_root`, `zs_type`, `zs_values`) → `packages/zanshin_ui/lib/src/design/`. Internal imports are relative and keep working. `zs_appearance.dart:6-7` imports `zanshin_settings` (`AccentSource`) and `zanshin_shell` (`ShellTheme`); `zs_root.dart:5` `zanshin_shell`.
- `app/lib/src/shared/design/zs_type.dart:16-23` -- `sansFamily`/`monoFamily`/`kanjiFamily` = `'Inter'`/`'JetBrainsMono'`/`'ShipporiMincho'` → prefix `packages/zanshin_ui/`; doc `(app/pubspec.yaml)` → `(packages/zanshin_ui/pubspec.yaml)`. `:28-42` `fontSans`/`fontMono`/`fontKanji` are CSS stacks compared with the DS — do NOT touch. `:229` fallback, `:318` `== monoFamily` keep working unchanged.
- `app/lib/src/shared/materials/` (6 files) → `packages/zanshin_ui/lib/src/materials/`. `zs_surface.dart:14` doc names the folder `shared/materials/` → `materials/`.
- `app/lib/src/shared/widgets/zanshin_icon.dart` (`ZanshinIcon`, `RenderZanshinIcon`, `ZI`, `ZsIconSize` lives in `zs_metrics.dart`) and `icon_registry.dart` (`IconRegistry`, `IconRegistryScope`, `IconModule` :48-60) → `packages/zanshin_ui/lib/src/icons/`. `icon_registry.dart:17-22` `load()`: `AssetBytesLoader('assets/icons/svg/$name.svg')` → add `packageName: 'zanshin_ui'` (vector_graphics 1.2.3 `loader.dart:78` builds `packages/<pkg>/<asset>`). `:4` `inject_annotation` import leaves with `IconModule`.
- `app/lib/main.dart:24,77,110,122` -- imports `icon_registry.dart`, uses `IconRegistry.load`, `IconModule(registry:)`, lists `IconModule` in `@Component`. `app/lib/main.inject.dart:31,40,56,138-148` -- generated by inject_generator (`dart run build_runner build --delete-conflicting-outputs` in `app/`; 11.1 last regenerated it). It imports types from their declaring library (`package:zanshin_settings/src/…` today).
- Importers to repoint to `package:zanshin_ui/zanshin_ui.dart`: `app/lib/src/features/{commits/commit_card,commits/commit_detail,commits/diff_block,shell/app_shell,shell/main_nav_rail,shell/window_title_bar,projects/home_dialog,history/history_column,branches/branches_panel}.dart` (ZI, ZanshinIcon, ZsIconSize); `app/lib/src/shared/widgets/commit_tags.dart:5,7`; `features/bootstrap/{zanshin_bootstrap:11,boot_window_host:15,128,boot_failure:5-7}.dart`; `features/app/{zanshin_app:13-15,zanshin_app_view_model:12}.dart` (ZsAppTheme, ZsAppearance, ZsRoot, ZsTheme, ZsAccentFamily).
- Bare family literals → `ZsType`: `app/lib/src/features/bootstrap/splash_card_render.dart:38,45,52,58,66,74` (the splash: version/build lines, status, 残心, watermark, tagline; keep the `const`s), `app/lib/main2.dart:186,338`. `'monospace'` literals stay.
- App tests: `app/test/features/bootstrap/zanshin_bootstrap_test.dart:15-17,20,562` (`'JetBrainsMono'` → `ZsType.monoFamily`); `app/test/features/app/{zanshin_app_test:12-15,zanshin_app_view_model_test:9}.dart`; `app/test/helpers/icon_registry.dart:4` (stays in the app, import repointed).
- Moving tests: `app/test/shared/design/*` (incl. `css_token_reader.dart:24-25` `dsRoot` `../_bmad-output/…` + doc "relative to `app/`"; `ds_parity_test.dart:64-65` `_appIcons = 'assets/icons/svg'` stays valid; `zs_tokens_test.dart:184-185,188` family expectations, `:192` `FontLoader('Inter')`), `app/test/shared/materials/*`, `app/test/shared/widgets/zanshin_icon_test.dart`, `app/test/assets/shippori_subset_test.dart`, helpers `app/test/helpers/zs_host.dart`, `material_paints.dart` → `packages/zanshin_ui/test/{design,materials,icons,assets,helpers}/` (shared/widgets → icons, mirroring `lib/src/icons/`).
- `app/pubspec.yaml:30-31,46-48,55-74` -- `vector_graphics`, `vector_graphics_compiler`, the SVG asset + transformer, fonts Inter/JetBrainsMono/ShipporiMincho (Zanshin + Lottie stay). Asset folders `app/assets/fonts/{Inter,JetBrains_Mono,Shippori_Mincho}/` (TTFs + OFL/README/SUBSET) and `app/assets/icons/svg/` (59 tracked files incl. the `workstream` leftover).
- Pattern to copy: `packages/zanshin_settings/{pubspec.yaml,analysis_options.yaml}`; export style of `packages/zanshin_core/lib/zanshin_core.dart` (`export 'src/…' show …`).
- `Makefile.toml:47-80` (`[tasks.test]` flow), `:222-239` (`test-settings*`), `:425-435` (`gate-test-settings*`) -- template for `test-ui*`.
- `crates/xtask/src/tasks/gate_plan.rs:40-65` `ALL_STEPS`; `:79-92` step groups; `:129-133` the `design_system/` rule (APP today); `:206-230` package rules; tests `a_flutter_package_plans_itself_and_every_package_depending_on_it`, `docs_need_nothing_except_the_ones_tests_read` (expects APP for DS files), `every_grouped_step_is_a_gate_step_with_a_wrapper_in_the_test_flow`. `crates/xtask/` is excluded from coverage (`coverage-baseline.txt:10`).
- Flutter SDK facts (`~/development/sdks/flutter`): `flutter_tools/lib/src/asset.dart:495-502` dependency assets go through `_parseAssets` with transformers; `:1024` dependency fonts register as `packages/<pkg>/<family>`; `:1487-1491` asset keys `packages/<pkg>/…`; `build_system/targets/assets.dart:142` transformers run `dart run <transformer>` in the ROOT project dir (so the app may still need `vector_graphics_compiler`); `flutter_test/lib/src/_binding_io.dart:31-70` the test asset mock retries a `packages/<APP_NAME>/` key without the prefix.

## Tasks & Acceptance

**Execution:**
- Before any move: build the baseline debug app (`flutter build macos --debug` in `app/`, PATH incl. `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`), launch it like LaunchServices does (`open -n -a app/build/macos/Build/Products/Debug/zanshin.app --stdout <scratch>/out.log --stderr <scratch>/err.log`; or `flutter run -d macos --debug` detached via `nohup … &` writing a log), read the Dart VM service URI from the log, `mcp__marionette__connect` (ws form of the URI) and `take_screenshots` of the splash if it still shows and of the main window; save them under the scratchpad; quit the app (`osascript -e 'quit app "zanshin"'`). Never use the Bash tool's `run_in_background`; poll with a script that sleeps (a bare foreground `sleep` is blocked).
- `packages/zanshin_ui/pubspec.yaml`, `analysis_options.yaml` -- create (Boundaries); the `flutter:` section declares `assets: - path: assets/icons/svg/ transformers: - package: vector_graphics_compiler`; the three font families join it when the fonts move (below). No `.gitignore` (the root one covers `build/`, `.dart_tool/`).
- PROOF FIRST, before any code moves: `git mv app/assets/icons/svg packages/zanshin_ui/assets/icons/svg`; add `zanshin_ui` (path) to `app/pubspec.yaml` and drop its SVG asset entry; `flutter pub get` at the root; temporarily give the app's `IconRegistry.load` `packageName: 'zanshin_ui'` and add a scratch package test that decodes one glyph with `vg.loadPicture(AssetBytesLoader('assets/icons/svg/check.svg', packageName: 'zanshin_ui'), null)`. Then (a) `flutter build macos --debug` in `app/` succeeds and its bundle holds `flutter_assets/packages/zanshin_ui/assets/icons/svg/check.svg` in precompiled form, (b) `flutter test test/features/bootstrap` in `app/` passes (real registry), (c) the scratch test passes in `packages/zanshin_ui/`. If any fails because of the transformer on package assets, apply the matrix fallback and add a `deferred:` item; otherwise delete the scratch test and continue.
- `git mv app/lib/src/shared/design/* packages/zanshin_ui/lib/src/design/`, `git mv app/lib/src/shared/materials/* packages/zanshin_ui/lib/src/materials/`, `git mv app/lib/src/shared/widgets/{zanshin_icon,icon_registry}.dart packages/zanshin_ui/lib/src/icons/`, `git mv app/assets/fonts/{Inter,JetBrains_Mono,Shippori_Mincho} packages/zanshin_ui/assets/fonts/` -- the move; in the same step the three font family declarations move from `app/pubspec.yaml:61-72` to the package's `flutter: fonts:` with the same assets and weights.
- `packages/zanshin_ui/lib/src/icons/icon_registry.dart` -- drop `IconModule` and the `inject_annotation` import; `load()` passes `packageName: 'zanshin_ui'`.
- `app/lib/src/features/bootstrap/icon_module.dart` -- new: `IconModule` verbatim (doc, `@module`, `@provides @singleton`), importing `inject_annotation` and `package:zanshin_ui/zanshin_ui.dart`.
- `packages/zanshin_ui/lib/src/design/zs_type.dart` -- the three family constants carry `packages/zanshin_ui/`; doc path; nothing else (the CSS stacks stay).
- `packages/zanshin_ui/lib/src/materials/zs_surface.dart` -- the folder doc path only.
- `packages/zanshin_ui/lib/zanshin_ui.dart` -- SPDX, library doc, `export 'src/…' show …` for exactly the names `app/` uses today: `ZsAccentFamily`, `ZsAppTheme`, `ZsAppearance`, `ZsColors`, `ZsElevation`, `ZsMotion`, `ZsRoot`, `ZsTheme`, `ZsType`, `ZsIconSize`, `ZI`, `ZanshinIcon`, `IconRegistry`, `IconRegistryScope` (from whichever file declares each; `dart analyze` in `app/` proves the list complete).
- Every importer in the Code Map, `app/lib/main.dart`, `app/lib/main2.dart`, `splash_card_render.dart`, the app tests and `app/test/helpers/icon_registry.dart` -- import `package:zanshin_ui/zanshin_ui.dart` (main.dart also `src/features/bootstrap/icon_module.dart`); family literals → `ZsType` constants; `zanshin_bootstrap_test.dart:562` → `ZsType.monoFamily`.
- `app/lib/main.inject.dart` -- regenerate with `dart run build_runner build --delete-conflicting-outputs` in `app/`; keep only the diff that follows the `IconModule`/`IconRegistry` move (revert any unrelated regeneration noise).
- `git mv` the tests and helpers to `packages/zanshin_ui/test/…` (Code Map); repoint `package:zanshin/src/shared/{design,materials,widgets}/` → `package:zanshin_ui/src/{design,materials,icons}/`; `css_token_reader.dart` `dsRoot = '../../_bmad-output/implementation-artifacts/design_system'` and its doc "relative to `packages/zanshin_ui/`"; `zs_tokens_test.dart` family expectations → the prefixed values, `FontLoader(ZsType.sansFamily)`; copy `app/test/helpers/icon_registry.dart` to `packages/zanshin_ui/test/helpers/icon_registry.dart` (package imports).
- `app/pubspec.yaml` -- ends with `zanshin_ui: path: ../packages/zanshin_ui` and without the SVG asset entry, the three font families and `vector_graphics` (with their comments); remove `vector_graphics_compiler` too, unless the debug build or `flutter test` in `app/` then fails in the transformer (it runs from the root project) — then keep it with a `# WHY:` comment saying so.
- `Makefile.toml` -- `test-ui` (`flutter test`), `test-ui-analyze`, `test-ui-format` (private, cwd `packages/zanshin_ui`, like `test-settings*`), `gate-test-ui*` wrappers, and the three wrappers in `[tasks.test]` after `gate-test-settings-format`.
- `crates/xtask/src/tasks/gate_plan.rs` -- the three steps in `ALL_STEPS` after `test-settings-format`; `const UI`; rule `Prefix("packages/zanshin_ui/")` "zanshin_ui" → `[UI, APP]` (before `app/`); settings → `[SETTINGS, UI, APP]`, shell_pi → `[SHELL_PI, SHELL_MACOS, SHELL, UI, APP]`, shell_macos → `[SHELL_MACOS, SHELL, UI, APP]`, shell → `[SHELL, UI, APP]`; the `design_system/` rule → "read by zanshin_ui's DS parity test", `[UI]`; inline tests updated and extended for the new rules (below).
- Leave the tree free of empty `app/lib/src/shared/{design,materials}`, `app/test/shared/`, `app/test/assets/` folders.

**Acceptance Criteria:**
- Given the change, when `git ls-files app/lib/src/shared` runs, then no `design/`, `materials/`, `widgets/zanshin_icon.dart` or `widgets/icon_registry.dart` remains, and `git grep -l "package:zanshin_ui/src/" -- app` lists only the generated `app/lib/main.inject.dart`.
- Given `packages/zanshin_ui/pubspec.yaml`, when read, then it names neither `zanshin_core`, nor an `inject_*` package, nor a path into `app/`, and `git grep -n "flutter_test\|inject_" -- packages/zanshin_ui/lib` finds nothing.
- Given `flutter test` in `packages/zanshin_ui/`, when it runs, then every moved test passes, including the DS parity test (tokens over 576 appearances and the icon set check) and the zanshin_icon test that loads every `ZI.all` glyph through `IconRegistry.load()`; `flutter test` in `app/` passes, including the bootstrap tests that load the real registry.
- Given `ZsType`, when its roles are read, then `ZsType.sansFamily`/`monoFamily`/`kanjiFamily` equal `'packages/zanshin_ui/Inter'`/`'…/JetBrainsMono'`/`'…/ShipporiMincho'`, the mono roles fall back to the prefixed Inter, and the variable-font weight test still measures a wider 600 line.
- Given `flutter build macos --debug` in `app/`, when it succeeds, then the bundle's `FontManifest.json` lists the three `packages/zanshin_ui/` families with their TTFs, the `packages/zanshin_ui/assets/icons/svg/*.svg` assets are present in precompiled (non-XML) form, and the app's own `Zanshin` font and Lottie files are still there.
- Given the debug app launched before and after the move, when the main window (and the splash, if it is captured) is screenshotted via Marionette, then the icons and the Inter / JetBrains Mono / Shippori 残心 text look the same; if no screenshot can be taken from this seat, the bundle check above stands in and the visual comparison is listed as a manual check for Ralph in the Auto Run Result.
- Given `gate_plan.rs`' inline tests, when `cargo test -p xtask` runs, then `plan_for` yields for `packages/zanshin_ui/lib/a.dart` exactly `test-flutter test-dart-analyze test-dart-format test-ui test-ui-analyze test-ui-format` in gate order, for `app/lib/a.dart` only the three APP steps, for `_bmad-output/implementation-artifacts/design_system/tokens/colors.css` and its `readme.md` only the three UI steps, and the settings and three shell rules include UI; every new step has a wrapper in `[tasks.test]`.
- Given the change, when `cargo make test-full` runs unpiped from the main session, then it exits 0 with `coverage-baseline.txt` not lowered.

## Spec Change Log

## Review Triage Log

### 2026-10-17 — Review pass
- verdicts: 24 findings — high 0, medium 4, low 14, false 5, maybe-false 1
- findings:
  - `[medium]` `[patch]` (blind 1) Nothing checks the `ZsType` family constants against the families the app registers; a typo or a pubspec rename would silently fall back to the system font — patched with the verification-gap finding: `app/test/assets/font_manifest_test.dart` reads `FontManifest.json` through `rootBundle`, asserts the three `ZsType` families, loads each font file and pins Shippori's weights 500/600.
  - `[low]` `[patch]` (blind 2) The `ZsType` docs still say "the pubspec family" and give no reason for the prefix — patched: "registered family" wording, the pubspec names in the docs, and a `// WHY:` on the prefix (a dependency's fonts register as `packages/zanshin_ui/<family>`; the package's own tests register them unprefixed).
  - `[low]` `[reject]` (blind 3) The package name is typed in four places (three font constants, `packageName`) — renaming the package is rare, the new manifest test and the app's bootstrap test (real registry) catch a mismatch, and a shared constant is a refactor beyond paths.
  - `[low]` `[patch]` (blind 4) The library doc of `lib/zanshin_ui.dart` promises the glass materials, which it does not export — patched: the doc says the package holds them and the materials join the exports with their first user.
  - `[low]` `[patch]` (blind 5) Nothing says the app's build resolves `vector_graphics_compiler` only through the workspace — patched: a `# WHY:` on the package's dev dependency (flutter_tools runs the transformer from the app's directory).
  - `[low]` `[patch]` (blind 6) The package's `setUpIconRegistry` copy relies on flutter_test's prefix retry without saying so and still says "The app's icon registry" — patched: "The real icon registry" and a `// WHY:` on the retry.
  - `[false]` `[reject]` (blind 7) `deferred-work.md:776` sends new icons to `app/assets/icons/svg/` — the entry is marked SUPERSEDED by 11.1 item 11, which copied every DS icon (the DS parity test checks the set), so it is no open instruction.
  - `[low]` `[patch]` (blind 8) The moved `SUBSET.txt` still says "the weights the app declares" and its git-history pointer omits the old folder — patched: "the zanshin_ui pubspec declares", and the history pointer names `app/assets/fonts/Shippori_Mincho/` and the move.
  - `[low]` `[patch]` (blind 9) `epic-11-context.md` keeps "Until 11.14 lands…" and "Once the fonts and SVGs are package assets…" — patched: both state the current fact; the Stories list marks 11.14 done.
  - `[low]` `[patch]` (blind 10) The context's "Moves are moves" rule forbids the doc-path edits the spec allows — patched: doc comments that name a moved location follow it.
  - `[low]` `[patch]` (blind 11) The context says the package never depends on `inject_*`, while `zanshin_settings` brings `inject_annotation` transitively — patched: "depends directly only on…", the transitive dependency named.
  - `[medium]` `[defer]` (blind 12) The gate-plan rules list each package's dependents by hand, unchecked against the pubspecs — pre-existing since `d81ebd9`; deferred and mirrored in deferred-work.md.
  - `[maybe-false]` `[defer]` (blind 13) The fonts' OFL texts are not in the bundle's NOTICES — pre-existing; if true medium; settle whether the TTFs' name-table licence fields satisfy the OFL; deferred (unverified) and mirrored.
  - `[low]` `[patch]` (blind 14) `sprint-status.yaml` still lists 11-14 as backlog — patched at finalize: done, with its summary.
  - `[low]` `[patch]` (blind 15) The package pubspec lacks the `# WHY:` on `material_ui` its sibling carries — patched.
  - `[medium]` `[patch]` (verification-gap 1) No test ties `ZsType`'s renamed families to the bundled families; the bootstrap test now compares the constant with itself — grouped with blind 1; patched there.
  - `[medium]` `[patch]` (intent a) The run-time surface (font registration, dependency asset keys, the transformer for dependency assets) is reached by no regression test — grouped with blind 1; the font half is patched there; the icon half is the app's bootstrap test, which loads the real registry from the dependency's precompiled assets.
  - `[low]` `[reject]` (intent b) "Never `zanshin_core`/`inject_*`" is checked once, not guarded by a test — the package cannot import the app by construction, a new dependency shows in review, and the guard would be a new pubspec-parsing test.
  - `[false]` `[reject]` (intent c) The generated `main.inject.dart` imports `package:zanshin_ui/src/` — the only achievable reading: `IconModule` must stay in the app (item 3) and inject_generator imports the declaring library, as it already does for `zanshin_settings/src` and `zanshin_core/src`; the story's own enforcement (`implementation_imports`) excludes `*.inject.dart` (Design Notes).
  - `[false]` `[reject]` (intent d) The export list leaves the materials out — item 1 says the list grows with what the app consumes; the app uses no material yet.
  - `[false]` `[reject]` (intent e) Tests sit in `test/{design,materials,icons}`, not `test/shared/…` — project-context.md says tests mirror `lib/src/`, which `icons/` does.
  - `[false]` `[reject]` (intent f) The gate-plan CLI never ran against a real tree — it did after the green run: a scratch file in `packages/zanshin_ui/lib/` planned the six APP+UI steps, one in `app/lib/` the three APP steps, none after removal (Verification below).
  - `[low]` `[patch]` (intent g) The `ZsType` docs and the copied helper's doc drift in meaning — grouped with blind 2 and blind 6; patched there.
  - `[low]` `[patch]` (intent h) `sprint-status.yaml` still says backlog — grouped with blind 14; patched at finalize.
  - (edge-case hunter: no findings.)

## Design Notes

**Why `main.inject.dart` may import `src/`.** inject_generator imports each type from its declaring library — it already writes `package:zanshin_settings/src/settings_module.dart` and `package:zanshin_core/src/…` — and `app/analysis_options.yaml` excludes `*.inject.dart`, so `implementation_imports` (the rule the witness leans on) never applies to it. The witness "no file in `app/` imports `package:zanshin_ui/src/`" is read as "no hand-written file"; the generated one is the named exception.

**Why fonts carry the prefix in the constant, not `package:`.** Flutter registers a dependency's fonts as `packages/zanshin_ui/<family>`; a `TextStyle(package:)` only prepends that string, and `fontFamilyFallback` entries and the `== monoFamily` comparison would need it too. Putting the prefix in the three constants keeps every role, the fallback and the comparison working with no other edit (Claude's proposal in the story).

**Why package tests still find the icons.** In `flutter test` inside the package, its own assets are keyed without the prefix, but flutter_test's asset mock retries `packages/<APP_NAME>/…` keys without the prefix (`_binding_io.dart:56-63`), so `IconRegistry.load()` with `packageName: 'zanshin_ui'` loads in both the package's and the app's tests.

## Verification

**Commands:**
- `flutter pub get` (repo root) -- resolves the workspace with the new member.
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `app/` and in `packages/zanshin_ui/` -- clean.
- `flutter test` in `packages/zanshin_ui/` and in `app/` -- all pass.
- `cargo test -p xtask` -- the gate-plan tests pass.
- `flutter build macos --debug` in `app/` -- succeeds; inspect `app/build/macos/Build/Products/Debug/zanshin.app/Contents/Frameworks/App.framework/Resources/flutter_assets/{FontManifest.json,packages/zanshin_ui/}` as the acceptance criterion says.
- `cargo make test-full` (repo root, unpiped, main session; PATH with the Flutter and cargo SDK bins, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset). It runs ~18 min, past the Bash tool's 10-min cap: start it detached with `nohup … > <scratch>/gate.log 2>&1; echo EXIT=$? >> <scratch>/gate.log &` inside a foreground command and poll the log with a sleeping script until the `EXIT=` line -- expected `EXIT=0`.
- After the green run: create a scratch untracked file `packages/zanshin_ui/lib/zz_probe.dart`, run `cargo run -q -p xtask -- gate-plan --workspace-root .`, expect the UI and APP steps listed; delete the file and rerun gate-plan.

**Manual checks (if no CLI):**
- Ralph: the before/after screenshots (or, if none could be taken, a launch of the debug app) show the same icons, Inter and JetBrains Mono text and the splash's 残心.

## Auto Run Result

Status: done (2026-10-17). Blocking condition: none.

**Summary.** The design-system layer left the app. `packages/zanshin_ui` is a new Flutter member of the pub workspace that holds 11.1's tokens (`lib/src/design/`), 11.2's materials (`lib/src/materials/`), `ZanshinIcon`/`ZI`/`IconRegistry`/`IconRegistryScope` (`lib/src/icons/`), the Inter, JetBrains Mono and Shippori Mincho fonts and the 59 SVG icons with their `vector_graphics_compiler` transformer. Everything moved with `git mv`; the only edits inside moved files are import paths, `IconModule` leaving `icon_registry.dart`, `IconRegistry.load`'s `packageName: 'zanshin_ui'`, the three `ZsType` family constants (`packages/zanshin_ui/…`) with their docs, and doc/test paths that name a moved location. The proof came first: with the SVGs moved, a debug build bundled them precompiled under `packages/zanshin_ui/`, the app's bootstrap tests loaded the real registry and a scratch package test decoded a glyph — no fallback was needed. The app imports only `package:zanshin_ui/zanshin_ui.dart` (14 exported names, exactly what `app/` uses); `IconModule` stays in the app; the splash and `main2.dart` use the `ZsType` constants; the app's pubspec lost the fonts, the SVG entry, `vector_graphics` and `vector_graphics_compiler` (the transformer resolves through the workspace). The gate has `test-ui`, `test-ui-analyze`, `test-ui-format` and a `UI` group in `gate_plan.rs`.

**Files changed** (paths relative to the repo root):
- `packages/zanshin_ui/{pubspec.yaml,analysis_options.yaml,lib/zanshin_ui.dart}` -- the new package and its export list.
- `packages/zanshin_ui/lib/src/{design,materials,icons}/` -- moved from `app/lib/src/shared/{design,materials,widgets}/`; `zs_type.dart` (prefixed families, docs), `icon_registry.dart` (`packageName`, no `IconModule`), `zs_surface.dart` (folder doc).
- `packages/zanshin_ui/assets/{fonts/{Inter,JetBrains_Mono,Shippori_Mincho},icons/svg}/` -- moved from `app/assets/`; `SUBSET.txt` names the new declaring pubspec and the old folder.
- `packages/zanshin_ui/test/{design,materials,icons,assets,helpers}/` -- the moved tests and helpers (`zs_host`, `material_paints`) plus a copy of `setUpIconRegistry`; `dsRoot` and the font expectations follow.
- `app/lib/src/features/bootstrap/icon_module.dart` -- `IconModule`, unchanged, now in the app.
- `app/lib/main.dart`, `main.inject.dart` (regenerated), `main2.dart`, `src/features/**` (15 files besides `icon_module.dart`), `src/shared/widgets/commit_tags.dart` -- the barrel import; family literals → `ZsType`.
- `app/test/features/{app,bootstrap}/…`, `app/test/helpers/icon_registry.dart` -- barrel import; the splash test expects `ZsType.monoFamily`.
- `app/test/assets/font_manifest_test.dart` -- new (review patch): the `ZsType` families against the bundle's `FontManifest.json`.
- `app/pubspec.yaml` -- `zanshin_ui` in, fonts/SVG/`vector_graphics`/`vector_graphics_compiler` out.
- `Makefile.toml`, `crates/xtask/src/tasks/gate_plan.rs` -- the UI gate steps and rules with inline tests.
- Tracking: this spec, `epic-11-context.md` (recompiled for 11.14, review corrections), `sprint-status.yaml` (11-14 done), `deferred-work.md` ("Surfaced in Story 11.14", 2 items).

**Review findings.** 24 findings (high 0, medium 4, low 14, false 5, maybe-false 1); edge-case hunter: none. Patched: one medium entry (blind 1 + verification-gap 1 + intent a: the app's `FontManifest.json` test) and 11 low entries (`ZsType` docs and a WHY on the prefix; the library doc's materials; WHY comments on `material_ui` and on the workspace-resolved `vector_graphics_compiler`; the package helper's doc and WHY; `SUBSET.txt`; three `epic-11-context.md` corrections; sprint-status). Deferred (mirrored): the hand-kept gate dependency rules (medium, pre-existing since `d81ebd9`); the fonts' OFL texts missing from the bundle's notices (medium, unverified, pre-existing). Rejected: the package name in four places (rare rename, tests catch a mismatch, a shared constant is a refactor beyond paths); no test guarding the pubspec's dependency list (by construction the package cannot import the app; a new dependency shows in review); and 5 false findings (the superseded icon entry in deferred-work.md; the generated `main.inject.dart` `src/` import, the only achievable reading; the export list per item 1; tests mirroring `lib/src/` per project-context; the gate-plan probe, which did run).

**Follow-up review recommendation:** false — this first pass patched 1 medium and 0 high entries (11 low); no named unverified risk calls for another pass.

**Verification.**
- Proof before the move (implementation subagent): `flutter build macos --debug` bundled `packages/zanshin_ui/assets/icons/svg/check.svg` precompiled, byte-identical to the baseline's; `flutter test test/features/bootstrap` in `app/` and a scratch glyph test in the package passed.
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `app/` and `packages/zanshin_ui/` -- clean, before and after the review patches.
- `flutter test` -- package 141 passed (DS parity test incl. the icon set, every `ZI.all` glyph through `IconRegistry.load()`, the weight-axis and Shippori subset tests); app 64 passed, 65 with the new manifest test.
- `flutter build macos --debug` -- `FontManifest.json` lists `packages/zanshin_ui/{Inter,JetBrainsMono,ShipporiMincho}` (Shippori 500/600) beside the app's `Zanshin` font; all 59 package SVGs are precompiled (binary, not XML); the Lottie files are still there.
- Visual before/after (Flutter inspector screenshots over the VM service; Marionette could not connect — the app runs marionette_flutter 0.6.0, the MCP 0.7.0): the splash differs only in 674 of 523k pixels, all in the animated progress rail and pulsing status dot — 残心, the wordmark, the tagline and the JetBrains Mono version line are pixel-identical; the main window differs in 3 of 1M pixels inside the accent toggle. The main window shows the Yaru test page at boot, so no DS icon is on screen there; the icons are covered by the bundle check and the tests.
- `cargo make test-full` (main session, unpiped via a detached log) -- `EXIT=0` in 668 s, every step; coverage held at 99.49 %, extern-coverage OK, `coverage-baseline.txt` unchanged. After the review patches `cargo make test` planned the 6 APP+UI steps and passed (`EXIT=0`).
- Gate-plan probe after the green run: a scratch `packages/zanshin_ui/lib/zz_probe.dart` planned `test-flutter test-dart-analyze test-dart-format test-ui test-ui-analyze test-ui-format`; a scratch `app/lib/zz_probe.dart` planned only the three APP steps; with both removed, no step.
- Matrix audit: app boot/app tests (bootstrap tests load the real registry from the dependency's assets), package tests (zanshin_icon test), fonts at runtime (manifest test, token test), mono fallback/CSS (token test, DS parity test), gate plan (the three inline gate-plan tests, ran in coverage); the fallback row did not apply — the proof passed.

**Residual risks.**
- The visual check is Flutter's own render, not a capture of the real window chrome; Ralph may want one look at a real launch (splash 残心, Inter/JetBrains Mono).
- build_runner warns that the `IconRegistry` binding is used by no component entry point; the module is unchanged by this story, so the warning predates it.
