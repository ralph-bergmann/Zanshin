---
title: 'Story 11.1 — Design-system foundation: tokens, app theme, shell accessibility, SVG icons, fonts, DS parity'
type: 'feature'
created: '2026-10-17'
status: 'done'
baseline_revision: '8f1323c9c56ff0fe1ee6a2dd8f5c703a9dc71350'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: 'A real Multicolor Mac resolves to the Blue accent family until Story 11.4 adds the Runner AccentColor asset.'
    evidence: 'Without NSAccentColorName, controlAccentColor at Multicolor is Blue #007AFF (RC research :190), so the "equals Zanshin''s app accent #4757a1" rule never matches; app/macos/Runner/Assets.xcassets holds only Contents.json; epics.md Story 11.1 item 1 assigns --accent-native to 11.4.'
    location: 'app/lib/src/shared/design/zs_appearance.dart (accent detection)'
    severity: medium
    resolved: >-
      2026-10-18 — fixed (spec-11-4-window-chrome-floating-layout, commit fdd9817): the runner ships the AccentColor colour set (#4757a1, dark #5162ad) and sets ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME, so the built Info.plist names NSAccentColorName = AccentColor.
  - summary: 'The inactive-window and full-screen deltas are resolved by the token layer but nothing drives them yet.'
    evidence: 'ZsAppearance.inactive and fullScreen default to false; 11.12 drives key status per window, 11.4 owns full screen (epics.md Story 11.1 item 7, DS tokens/spacing.css:52).'
    location: 'app/lib/src/shared/design/zs_appearance.dart'
    severity: low
    resolved: >-
      2026-10-19 — fixed (spec-11-12-window-foundation-dialog-windows, commit 0dbd2fb): ActiveWindowTracker drives ZsAppearance.inactive in every window root; full screen came with 11.4 (commit fdd9817).
  - summary: 'The Swift side of the extended ShellTheme has no automated test, and cargo make test never compiles it.'
    evidence: 'packages/zanshin_shell_macos/macos/zanshin_shell_macos/Package.swift has no test target; Makefile.toml has no xcodebuild/flutter build task in test; only the Dart decoding is tested.'
    location: 'packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/ZanshinShellPlugin.swift'
    severity: medium
  - summary: 'AppleScrollerPagingBehavior has no change notification, so ShellTheme carries a value that is only refreshed on the next emitted change.'
    evidence: 'No NSNotification exists for the "Click in the scroll bar to" preference; the plugin re-reads UserDefaults on every emit.'
    location: 'packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/ZanshinShellPlugin.swift'
    severity: low
    resolved: >-
      2026-10-18 — fixed (spec-11-11-zs-control-library-widgetbook, commit ff1ccc6): the shell plugin re-emits the theme on didBecomeActive, so the value is fresh for every track press.
  - summary: >-
      The Multicolor check compares the reported aqua accent with #4757a1 exactly, so an off-by-one channel from 11.4's AccentColor asset would show the Blue family.
    evidence: |-
      Unverified (review pass 2026-10-17, blind + edge-case hunters): zs_appearance.dart:79 uses `shell.accentColor == ZsAccents.native`; the shell packs `controlAccentColor.usingColorSpace(.sRGB)` rounded to 8 bits. Settle it on a Mac with 11.4's colorset: does Multicolor report exactly 0xFF4757A1 (an sRGB colorset should; a Display-P3 one may not)?
    location: >-
      app/lib/src/shared/design/zs_appearance.dart:79
    severity: medium (unverified)
  - summary: >-
      The live half of the reduce-motion, contrast and accent witnesses ("toggling updates the running app") is verified only against a fake shell.
    evidence: |-
      Review pass 2026-10-17 (intent-alignment auditor): zanshin_app_test.dart and zanshin_shell_macos_test.dart drive the RecordingShell fake and a mocked MethodChannel; ZanshinShellPlugin.swift's new observers (NSWorkspace accessibilityDisplayOptionsDidChange, systemColorsDidChange, preferredScrollerStyleDidChange) and the splash feed in ZanshinWindowHost run only in the real app. Pre-existing: there is no Swift test target and the host is not unit-testable (needs a live engine).
    location: >-
      packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/ZanshinShellPlugin.swift:47-66
    severity: medium
---

<intent-contract>

## Intent

**Problem:** The app has none of the design system's values: the legacy `ZanshinColors` holds the docked mock's palette and is never registered, the running theme is Yaru with the macOS accent as primary, icons are 37 hand-made SVGs through `flutter_svg`, ~44 MB of unused/oversized fonts ship, and macOS never reports Reduce motion, Reduce transparency or Increase contrast to Flutter, so every reduce-motion rule is inert. Every Epic 10/11 surface (and 10.1's `GraphTheme`) needs one token source.

**Approach:** Turn every custom property of the DS downloaded 2026-10-16 (`DS tokens/*.css`, DS synced through #9) into Dart once — `ZsColors`/`ZsElevation` ThemeExtensions resolved over theme × accent family plus the contrast/transparency/inactive deltas, `ZsType`/`ZsMetrics`/`ZsMotion` — guarded by a DS parity test (tokens and icons) inside `cargo make test`; extend `zanshin_shell` with the accessibility, accent and selection state; rebuild the app theme and a per-window root scope on the tokens; move icons to the DS's 58 SVGs precompiled by `vector_graphics_compiler` and held in a boot-time `IconRegistry`; subset Shippori Mincho to 残心; English splash lines.

## Boundaries & Constraints

**Always:**
- Epics.md Story 11.1 (epics.md:11691-11854) is the requirement; its "Design update 2026-10-16" block (:11694-11761) supersedes the older items it names. Decisions 16.1–16.47 (epics.md:11529-11618) apply. DS = `_bmad-output/implementation-artifacts/design_system/`; tokens/CSS win over DS prose.
- Every value is the DS's fixed hex/rgba/px/ms as written — no colour-space conversion, no tolerance (only em → px and the shadow σ converter compute). Names follow the CSS (`--card-solid-hi` → `cardSolidHi`); each group's doc cites its `DS <file>:<line>`; `dsSyncedThrough = 9`.
- `of(context)` falls back (colours/elevation → night; metrics/motion → the standard/full set) and never force-unwraps.
- Material types (`ThemeData`, `ThemeExtension`, `Theme`, `MaterialApp`, `ThemeMode`) come only from `package:material_ui`; widgets-layer code imports `package:flutter/widgets.dart` (+ rendering/painting/`dart:ui`).
- New shell fields follow "null for absence": an absent `AppleAccentColor` is `null`; absent new map keys decode to the constructor defaults.
- SPDX first line on every new `.dart`; `dart format` page width 120; `dart analyze --fatal-infos --fatal-warnings` clean in every touched package.
- Mark every default the story leaves open as "Claude's proposal" in a doc comment where it lives (see Design Notes).

**Never:**
- No glass/menu/dialog materials (11.2), no Zs controls or their cursors/witnesses (11.11), no window chrome/canvas painting/vibrancy or AccentColor asset (11.4), no per-window key-status wiring (11.12), no Settings row (11.7).
- Do not delete or change `ZanshinColors`, `context.zc`, the mock widgets, `zanshin_icons.dart`/`Zanshin.ttf`, Lottie, the Yaru test page home, the Linux `YaruTheme` branch's theming (adapt only its call if a signature changes) or the `main2/3/4.dart` POC hosts (11.10 retires them) — only the edits listed below touch the mock (icon renames + size tokens).
- Never edit anything under `design/` or `design_system/`. No golden tests. No oklch math except the "This Mac" hue mapping.
- No density tokens (the DS has none).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Accent: setting Zanshin | `accentSource: zanshin`, any `ShellTheme` | family = multicolor (moon) | — |
| Accent: named key | follow macOS, `appleAccentColor` −1/0/1/2/3/4/5/6 | graphite/red/orange/yellow/green/blue/purple/pink (4 → blue) | — |
| Accent: Multicolor | follow macOS, key `null`, `accentColor` == `#4757a1` (`--accent-native`) | multicolor | — |
| Accent: "This Mac" | key `null`, `accentColor` iMac orange `#F7821B` | orange (OKLCH hue band 38.5–70.5, DS tokens/accents.css:8-10) | chroma < .03 → graphite |
| Accent: unknown key | key `9` | treated as absent → colour rules | — |
| Accent: no shell yet | `ShellTheme` null | multicolor | — |
| Parity: changed token | a DS value differs from the token layer | test fails, message names `--token`, both values, the appearance | — |
| Parity: added / removed token | CSS has a name the layer lacks / vice versa | fails naming the token | — |
| Parity: `@media` drift | a `@media` copy differs from its attribute twin | fails naming the token | — |
| Icon parity | changed / added / removed glyph; a `ZI` value equal to a retired alias; `<style>`; `rx` > half the shorter side | fails naming the glyph (or the `ZI` constant) | — |
| Shell decode | map without the new keys | defaults (`false`, `null`, `ScrollerStyle.overlay`) | absent `appleAccentColor` → `null` |

</intent-contract>

## Code Map

Paths under `app/lib/src/features/` are abbreviated `F/`.

- `_bmad-output/planning-artifacts/epics.md:11691-11854` -- Story 11.1 (read the 2026-10-16 block first); `:11529-11618` decisions 16.x; `:7982-8037` Epic 10 house rules (Theme, Tests, Design-system sync).
- `DS tokens/` -- the source. `styles.css:1-11` import order (fonts, colors, accents, states, typography, spacing, effects, motion, transparency, contrast, inactive). Night/paper: `colors.css:9-77`/`:79-111`, `states.css:7-74`/`:75-100`, `effects.css:4-49`/`:50-61` (radii, shadows, blurs, `--z-*`); families `accents.css:28-51` (+ derived `:53-54`, `--accent-native(-dark)` `:57`); deltas `transparency.css:9-10`, `contrast.css:21-22`, `inactive.css:17-18`, `:26-27`, `motion.css:71`, `spacing.css:52`; `@media` twins `transparency.css:11-14`, `contrast.css:27-34`, `inactive.css:28-31`, `motion.css:70`; theme-independent `typography.css:6-39`, `spacing.css:6-49`, `motion.css:12-68`. Component rules (`.zs-…` selectors: `contrast.css:23-26`, `inactive.css:20-22`) declare no custom properties → ignored (11.11). `fonts.css` has only `@font-face`. Comments contain token-like text (`contrast.css:13`) → strip comments first. Counts: 856 declarations, 365 names.
- `DS assets/icons/glyphs.json` -- 58 names (`:3-60`), 9 retired aliases (`:62-72`: download→fetch, stacked-on→arrow-up, add→plus, check-bold→check, dash-bold→minus, more-bold→more, grip-dots→grip, arrow-left→chevron-left, edit→describe). `DS assets/icons/ui/*.svg` -- 58 one-line files: root `<svg … viewBox="0 0 16 16" xmlns:c2pa="http://c2pa.org/manifest">` + `<metadata><c2pa:manifest>…</metadata>` + one `<g fill="none" stroke="currentColor" …>`; no trailing newline; after the strip all pass the lint (colours `currentColor`/`none`; ≤ 2 decimals; `move-only` rx 1.25 on a 2.5 side → the rx check is inclusive ≤).
- `DS readme.md` -- `:106` cursor, `:147-181` accent (Follow macOS · Zanshin, "This Mac" hue anchors `:181`), `:175-179` text selection, `:350-353` icon rules + sizes; `DS ui_kits/desktop/kit.css` pairs `--type-inspector-title` with `--tracking-title`; components pair `--type-dialog-title`/`--tracking-dialog` and `--type-caps`/`--tracking-caps`.
- `app/lib/src/shared/widgets/zanshin_icon.dart:8-26` -- `ZanshinIcon` (flutter_svg; `IconTheme`→`Theme`→`Colors.white` fallback); `:29-67` `ZI` snake_case. Call sites (all in the unreachable mock): `F/commits/commit_detail.dart:79,165-169 (ZI.arrowLeft :169),187,224`; `F/shell/window_title_bar.dart:70-74,110,140-152,180`; `F/history/history_column.dart:63`; `F/branches/branches_panel.dart:50,75,300,330`; `F/commits/diff_block.dart:99,106,138,168,189`; `F/commits/commit_card.dart:118,186,306,314`; `F/shell/app_shell.dart:171,203,211,225` (workstream :203,:211); `F/shell/main_nav_rail.dart:47-78` (no colour; `IconTheme` at :116-119); `F/projects/home_dialog.dart:126-128,238,290,318,336-337,368 (ZI.download),397,486,516`; `app/lib/src/shared/widgets/commit_tags.dart:39,65`. `ZI.edit` has no caller.
- `app/assets/icons/svg/` -- 37 snake_case files (33 have a DS twin, `arrow_left`/`download`/`edit` are aliases, `workstream.svg` has none and stays).
- `app/pubspec.yaml:17` `flutter_svg ^2.3.0`; `:50-71` assets (`:53` icons dir) + fonts. Root `pubspec.lock:1093-1116` already locks `vector_graphics 1.2.3`, `vector_graphics_codec 1.1.13`, `vector_graphics_compiler 1.3.0` (in the pub cache). API: `parseWithoutOptimizers(String xml, {…, bool warningsAsErrors})` (`vector_graphics_compiler-1.3.0/lib/vector_graphics_compiler.dart:38`; `<metadata>` throws under it, `parser.dart:777-785`); `vg.loadPicture(BytesLoader, BuildContext?)` (`vector_graphics-1.2.3/lib/src/vector_graphics.dart:679`), `AssetBytesLoader` (`loader.dart:47`).
- `app/assets/fonts/` -- referenced: Inter variable, JetBrainsMono variable, `Shippori_Mincho/ShipporiMincho-Medium.ttf` (8.7 MB, w500) + `-SemiBold.ttf` (8.6 MB, w600); unreferenced: `Inter-Italic-…`, `JetBrainsMono-Italic-…`, Shippori Regular/Bold/ExtraBold. Only `F/bootstrap/splash_card_render.dart:57-71,107,459-460` uses Shippori (残, 心); `:76-77` is the `FontVariation.weight` pattern. No fonttools installed; `uv`/`uvx` at `/opt/homebrew/bin`.
- `F/app/zanshin_app.dart:76-121` -- build: Linux `YaruTheme` `:82-92` (keeps Yaru), macOS Yaru builder with `shellTheme.accentColor` primary `:107-119`; `:124-149` `_ExampleHome` MaterialApp (Yaru test page stays home).
- `F/app/zanshin_app_view_model.dart:22-60,83-90` -- shell subscription; `:38-45` `effectiveMode`.
- `F/bootstrap/boot_failure.dart:21-41` -- its own MaterialApp on `yaruLight/yaruDark`.
- `F/bootstrap/zanshin_bootstrap.dart:69-90` -- ctor (`openSettings`, `adoptShellEnvironment`, `startApp(SettingsStore)`); `:159-173` `_load` with German lines `:160,:168,:171`; `:232-236` `_splashFade` (zero under the platform flag).
- `F/bootstrap/splash_card.dart:46-54` -- `MediaQuery.fromView` + `animate: !disableAnimationsOf`.
- `F/bootstrap/boot_window_host.dart:42-58,88-95` -- `openSplash`, `openMain`, `_present` → `runWidget(WindowManager(…))` (not unit-testable).
- `app/lib/main.dart:70-75,102-123` -- boot wiring, `_startApp`, `MainComponent`; `app/lib/main.inject.dart` generated (tracked) — regenerate, never hand-edit.
- `packages/zanshin_settings/lib/src/settings_module.dart:13-25` -- the `SettingsModule(store:)` pattern; `lib/src/model/appearance_settings.dart:13-16` (freezed + json; `build.yaml` sets the header; regenerate with build_runner).
- `packages/zanshin_shell_platform_interface/lib/src/shell_theme.dart:8-35` -- `ShellTheme{brightness, accentColor}`, hand-written `==`/`hashCode`/`toString`; `lib/src/zanshin_shell_platform.dart:42-45`.
- `packages/zanshin_shell_macos/lib/zanshin_shell_macos.dart:17-52` -- MethodChannel `zanshin_shell`, `_themeFromMap` `:37-43` (strict casts).
- `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/ZanshinShellPlugin.swift` -- observers `:36-45`, `deinit` `:48-50`, emit `:60-62`, `currentTheme()` `:92-112` (accent under `NSApp.effectiveAppearance`), UserDefaults precedent `:157-158`.
- `packages/zanshin_shell/lib/zanshin_shell.dart:3-4` -- `show ShellTheme, WindowAppearance` (add new public types).
- Tests: `packages/zanshin_shell/test/zanshin_shell_test.dart:11-72` (`RecordingPlatform`), `packages/zanshin_shell_platform_interface/test/zanshin_shell_platform_test.dart:18-53`, `packages/zanshin_shell_macos/test/zanshin_shell_macos_test.dart:19-81`, `app/test/features/app/zanshin_app_view_model_test.dart:14-57` (`RecordingShell` + `ZanshinShellPlatform.instance = shell`), `app/test/features/bootstrap/zanshin_bootstrap_test.dart` (German strings `:396-397,434,443,476,487,491,513,519,522,544,552,565,592`; reduce-motion `:320,547,568,588`; `FakeBootWindowHost` `:30-72`). `flutter test` runs with cwd `app/` (`Makefile.toml:96-112`); package tasks `:150-220`.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_settings/lib/src/model/appearance_settings.dart` (+ regenerated `.freezed.dart`/`.g.dart`, barrel export, `test/model/`) -- add `enum AccentSource { followMacOS, zanshin }` and `@Default(AccentSource.followMacOS) AccentSource accentSource`; regenerate with `dart run build_runner build --delete-conflicting-outputs` in the package; test that JSON without the key decodes to `followMacOS` and `zanshin` round-trips -- the Settings choice of decision 16.2 (11.7 builds the row).
- `packages/zanshin_shell_platform_interface/lib/src/shell_theme.dart` (+ `zanshin_shell_platform.dart` doc, its test) -- add `int? appleAccentColor`, `bool reduceMotion`, `bool reduceTransparency`, `bool increaseContrast`, `Color? selectedTextBackgroundDark/Light`, `Color? unemphasizedSelectedTextBackgroundDark/Light`, `ScrollerStyle scrollerStyle` (`enum ScrollerStyle { legacy, overlay }`, default overlay), `bool jumpToClickedSpot`, all optional with defaults; `accentColor` is now documented as resolved in aqua (its only consumer, the Yaru primary, goes); extend `==`/`hashCode`/`toString` -- the state item 7 adds; existing const constructions keep compiling.
- `packages/zanshin_shell_macos/lib/zanshin_shell_macos.dart` (+ test) -- decode the new keys tolerantly (absent → default/null; colours as ARGB ints like `accentColor`) -- witness for the transport.
- `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/ZanshinShellPlugin.swift` -- send the new keys: `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion/…ReduceTransparency/…IncreaseContrast`; `UserDefaults.standard.object(forKey: "AppleAccentColor") as? Int` (omit when absent); `controlAccentColor` resolved under `NSAppearance(named: .aqua)`; `selectedTextBackgroundColor` and `unemphasizedSelectedTextBackgroundColor` resolved under `.darkAqua` and `.aqua`; `NSScroller.preferredScrollerStyle`; `UserDefaults` bool `AppleScrollerPagingBehavior`. Also emit on `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` (on `NSWorkspace.shared.notificationCenter`), `NSColor.systemColorsDidChangeNotification` and `NSScroller.preferredScrollerStyleDidChangeNotification` (`NotificationCenter.default`); remove every observer in `deinit` -- the embedder reports none of this.
- `packages/zanshin_shell/lib/zanshin_shell.dart` (+ `test/zanshin_shell_test.dart` fake) -- export `ScrollerStyle`.
- `app/lib/src/shared/design/zs_appearance.dart` -- `dsSyncedThrough = 9`; `ZsTheme {night, paper}`; `ZsAccentFamily {multicolor, blue, purple, pink, red, orange, yellow, green, graphite}`; immutable `ZsAppearance` (theme, family, increasedContrast, reduceMotion, reduceTransparency, inactive, fullScreen; defaults night/multicolor/false) with `maybeOf/of(context)` from the scope `ZsRoot` installs; `ZsAppearanceOverride` InheritedWidget (nullable fields, applied over a base appearance; used only by tests and 11.11's addon); the accent detection of the I/O matrix (sRGB → OKLCH only for the hue mapping) -- the axes and deltas of item 2.
- `app/lib/src/shared/design/zs_values.dart` -- composite token types with `==`, `hashCode`, `lerp`: `ZsShadow` (dx, dy, blur, spread, color, inset) and a converter of a shadow list to `BoxShadow`s that drops inset parts (exposed separately for 11.2) and sets `blurRadius = max(0, (blur / 2 − 0.5) / 0.57735)`; gradient parts for `--canvas` (radial 115%×85% at 10%/−12% + linear 165deg, stops) and `--fl-sheen` (180deg, band ending at 46 px); the glass filter (`blur(Npx) saturate(x)`; `none` → null) -- composites keep their parts (item 1).
- `app/lib/src/shared/design/zs_colors.dart` + `zs_accents.dart` -- `ZsColors extends ThemeExtension<ZsColors>`: every theme-dependent colour/gradient token of colors.css, states.css and accents.css, aliases included; `night`, `paper`, `resolve(ZsAppearance)` (theme → family + derived → transparency → contrast → inactive → inactive×contrast), field-wise `lerp` (across families too), `of(context)` ?? night, and `toCss()` (`'--name' → value`) for the parity test; `zs_accents.dart` holds the 8 named families × night/paper × 11 tokens and `--accent-native(-dark)`; multicolor is colors.css's moon set -- items 1–2.
- `app/lib/src/shared/design/zs_elevation.dart` -- `ZsElevation` ThemeExtension: every shadow/ring (effects.css:24-34, :50-60; states.css thumb + tooltip shadows) and glass/scrim blur (effects.css:36-38, `none` under contrast/transparency), resolved like `ZsColors` (rings follow the family/inactive), `night/paper/resolve/lerp/of/toCss`; paper uses umber -- item 5.
- `app/lib/src/shared/design/zs_type.dart` -- `ZsType` const: font stacks, `--fs-*`, `--fw-*`, `--lh-*`, `--tracking-*` (em) and the 12 roles as `TextStyle`s: pubspec family names (`Inter`, `JetBrainsMono`), `fontWeight` + `FontVariation.weight`, `fontSize`, `height` + `TextLeadingDistribution.even`, `letterSpacing` = em × size for inspector-title (`--tracking-title`), dialog-title (`--tracking-dialog`) and caps (`--tracking-caps`), 0 otherwise (Claude's proposal from the DS's pairings); mono roles `fontFamilyFallback: ['Inter']`; no colour; a `caps(String)` helper that upper-cases; `toCss()`; `ShipporiMincho` named for 残心 only -- items 3, 10.
- `app/lib/src/shared/design/zs_metrics.dart` -- `ZsMetrics`: spacing, control heights, `enum ZsIconSize {xs 10, sm 12, md 14, lg 16, bar 17, rail 19}`, traffic-light/chrome geometry (calc values evaluated: first-x 91, bar-y 4, top 60, left 76), window header 52, inspector/panel ranges, graph-min-w, resize hit, minimap, card + graph defaults, radii (effects.css:7-22), focus/interaction (states.css:18-26: focus-w 2, offsets 2/−2/3, settle 3, halo 3, disabled .4), scroll widths, `--z-*`; `standard`; `of(context)` applies increased contrast (focus-w 3) and full screen (spacing.css:52); `toCss()` -- item 4.
- `app/lib/src/shared/design/zs_motion.dart` -- `ZsMotion`: the five curves (`Cubic` per motion.css:14-18; linear), `motion` factor, fades, movement, waits/holds, calm scrolling; `full` and `reduced` (motion 0 and `--dur-nudge/toggle/expand/move/flip` 0, every other value unchanged); `of(context)` is `reduced` iff `MediaQuery.maybeDisableAnimationsOf(context) == true`; `toCss()` -- item 6, decision 16.4.
- `app/lib/src/shared/design/zs_app_theme.dart` -- `ZsAppTheme.build(ZsAppearance)` → `ThemeData`: brightness (night dark, paper light), colorScheme from tokens (primary `--accent`, onPrimary `--accent-ink`, surface `--card-solid`, onSurface `--text`, error `--error`), scaffold `--canvas-base`, fontFamily `Inter`, textTheme from the roles, `NoSplash.splashFactory`, hover `--fl-hover`, highlight `--fl-on`, focus `--focus-ring`, `mouseCursor` = `SystemMouseCursors.basic` in every Material component theme that has one, extensions `[ZsColors, ZsElevation]` resolved -- item 9 (no Yaru builder, no macOS-accent primary).
- `app/lib/src/shared/design/zs_root.dart` -- `ZsRoot` root-scope widget (every window root): applies `ZsAppearanceOverride`, installs the effective `ZsAppearance` scope, `Theme(ZsAppTheme.build(effective))`, `MediaQuery` copy with `disableAnimations = reduceMotion`, `DefaultTextStyle` (body role, `--text`), `IconTheme` (`--text`), `DefaultSelectionStyle` (shell `selectedTextBackground` for the theme — dark for night, light for paper — and the unemphasized one when inactive; fallback `--accent-select`/`--select-inactive`; cursor `--accent-line`), a `ScrollConfiguration` without Material glow/stretch -- items 7, 14.
- `app/assets/icons/svg/` -- copy all 58 `DS assets/icons/ui/*.svg` with `<metadata>…</metadata>` and ` xmlns:c2pa="…"` removed, kebab-case names, bytes otherwise unchanged (no added newline); delete the 36 other old files; keep `workstream.svg` -- item 11.
- `app/pubspec.yaml` (+ root `pubspec.lock` via `flutter pub get`) -- asset entry `- path: assets/icons/svg/` with `transformers: - package: vector_graphics_compiler`; add `vector_graphics` (dependency) and `vector_graphics_compiler` (dev_dependency) at the locked versions; remove `flutter_svg` -- item 11.
- `app/lib/src/shared/widgets/icon_registry.dart` -- `IconRegistry` (`static Future<IconRegistry> load()` loads every `ZI.all` name in parallel via `vg.loadPicture(AssetBytesLoader('assets/icons/svg/<name>.svg'), null)`; lookup by name), `IconRegistryScope` InheritedWidget (`maybeOf`), `IconModule({required this.registry})` `@module` with `@provides @singleton` -- item 11 runtime.
- `app/lib/src/shared/widgets/zanshin_icon.dart` -- `ZI`: camelCase constants for the 58 DS names → kebab-case file names, plus `workstream` (named leftover until 11.10), and `static const all`; no `arrowLeft`/`download`/`edit`. `ZanshinIcon(String name, {required ZsIconSize size, Color? color})` becomes a leaf `RenderObjectWidget`: colour = `color` ?? `IconTheme.of(context).color` ?? `ZsColors.of(context).text`; paints synchronously the registry's picture scaled 16 → size inside `saveLayer` with `ColorFilter.mode(colour, BlendMode.srcIn)`; no registry or an unknown name paints nothing (debug assert on an unknown name); no Material import -- item 11.
- `F/commits/commit_detail.dart`, `F/commits/commit_card.dart`, `F/commits/diff_block.dart`, `F/shell/window_title_bar.dart`, `F/shell/app_shell.dart`, `F/shell/main_nav_rail.dart`, `F/history/history_column.dart`, `F/branches/branches_panel.dart`, `F/projects/home_dialog.dart`, `app/lib/src/shared/widgets/commit_tags.dart` (lines in the Code Map) -- `ZI.arrowLeft` → `ZI.chevronLeft`, `ZI.download` → `ZI.fetch`; sizes → tokens 10→xs, 11/12→sm, 13/14→md, 16→lg, 17→bar, ≥ 19→rail (Claude's proposal; 11.10 deletes these files); size parameters of their private helpers (`_MetaRow`, `_HeaderBtn`, …) become `ZsIconSize` -- keeps the build green and the set check whole.
- `F/app/zanshin_app_view_model.dart` -- `ZsAppearance get appearance` from the effective mode, `accentSource` × `shellTheme` (I/O matrix) and the shell flags (inactive/fullScreen false) -- the app's appearance source.
- `F/app/zanshin_app.dart` -- macOS path: `theme`/`darkTheme` = `ZsAppTheme.build` for paper/night with the VM's family and flags, `MaterialApp.builder` wraps the child in `ZsRoot` whose theme follows the MaterialApp's resolved brightness (so the first frame before the shell answers follows the system too); drop `createYaru*Theme`; `_ExampleHome`/Yaru test page stays home; the Linux branch keeps its Yaru theme -- item 9.
- `F/bootstrap/boot_failure.dart` -- token theme for both modes + `ZsRoot` (multicolor, no shell) -- every window root uses the root scope.
- `F/bootstrap/zanshin_bootstrap.dart` -- status lines `Loading settings…`, `Reading the shell environment…`, `Starting Zanshin…`; new `loadIcons` (`Future<IconRegistry> Function()`) runs alongside `openSettings` and fails the boot like it; `startApp(SettingsStore settings, IconRegistry icons)`; `_splashFade` always `splashFadeOut` (the cross-fade is opacity) -- items 11, 13.
- `F/bootstrap/splash_card.dart` -- `reduceMotion` (`ValueListenable<bool>`) overrides `disableAnimations` in its `MediaQuery.fromView` data, so the Nami swell stops while the cross-fade keeps its duration -- items 7, 13.
- `F/bootstrap/boot_window_host.dart` -- `ZanshinWindowHost({required windows, required ValueListenable<IconRegistry?> icons})`: `_present` wraps `WindowManager` in a `ValueListenableBuilder` → `IconRegistryScope` (above all windows); `openSplash` feeds `SplashCard.reduceMotion` from `ZanshinShell.getTheme()`/`onThemeChanged` -- the scope placement of item 11.
- `app/lib/main.dart` (+ regenerated `main.inject.dart` via `dart run build_runner build --delete-conflicting-outputs` in `app/`) -- a `ValueNotifier<IconRegistry?>` shared by the host and `loadIcons`; `_startApp(settings, icons)` passes `IconModule(registry: icons)`; `IconModule` in `MainComponent` -- DI like `SettingsModule(store:)`.
- `app/assets/fonts/Shippori_Mincho/ShipporiMincho-Medium.ttf`, `-SemiBold.ttf` -- subset in place to U+5FC3, U+6B8B with `uvx --from fonttools pyftsubset` (family name kept); record the exact command and fonttools version in `app/assets/fonts/Shippori_Mincho/SUBSET.txt`; delete `Inter-Italic-…`, `JetBrainsMono-Italic-…`, Shippori Regular/Bold/ExtraBold -- item 10 (~17 MB + ~27 MB less).
- `app/test/shared/design/css_token_reader.dart` + `ds_parity_test.dart` -- the parity test of item 12 (model in Design Notes): comparison functions return named mismatches; the test asserts none over every appearance combination of the real DS and runs the negative cases on in-memory copies; the icon check (bytes after the same strip; glyphs.json names = app files = `ZI.all` values, minus `workstream`; no `ZI` value is a retired alias; lint via `parseWithoutOptimizers(xml, warningsAsErrors: true)` + no `class`/`style`/`id`/`transform`/`filter`/`<style>`, colours only `currentColor`/`none`, ≤ 2 decimals, `rx`/`ry` ≤ half the shorter side) with its negatives on synthetic inputs -- item 12, decision 16.33.
- `app/test/shared/design/zs_tokens_test.dart` -- `of()` fallbacks, lerp midpoints (colour, shadow, two families), 11 tokens per family, `--proj-stale` in both themes, type roles + the Inter weight axis (load `assets/fonts/Inter/…ttf` with `FontLoader`), shadow converter, motion full/reduced, metrics contrast/full screen, the accent matrix -- witnesses.
- `app/test/shared/design/zs_root_test.dart` -- the appearance override witness, ambient defaults (not the debug text style), selection colour from the shell vs fallback and unemphasized when inactive.
- `app/test/helpers/icon_registry.dart` + `app/test/shared/widgets/zanshin_icon_test.dart` -- shared `setUpAll` loader; first-pump paint after `tester.runAsync` load; unknown name paints nothing.
- `app/test/features/app/zanshin_app_test.dart` (new; reuse the `RecordingShell` pattern) + update `zanshin_app_view_model_test.dart` -- theme per mode, extensions on the app theme, live reduce-motion override, accent cases.
- `app/test/features/bootstrap/zanshin_bootstrap_test.dart` -- English lines, `loadIcons` in parallel and its failure, fade keeps `splashFadeOut` under reduce motion, `SplashCard` with `reduceMotion` true does not animate.
- `app/test/assets/shippori_subset_test.dart` -- parse both TTFs' `cmap` (formats 4/12): exactly U+5FC3 and U+6B8B are mapped.

**Acceptance Criteria:**
- Given the DS downloaded 2026-10-16 and the new token layer, when `flutter test` runs `ds_parity_test.dart`, then every custom property of every DS token file matches for all 2 themes × 9 families × contrast × transparency × inactive combinations, the theme-independent groups under reduce motion and full screen, and every icon, and the test passes.
- Given a CSS fixture whose inactive × increased-contrast rule uses `:is()` (inactive.css:26-27), when the reader resolves paper + inactive + increased contrast, then `--accent-line` is `#26242c` (a naive extractor yields `#e7e9f2`).
- Given no extension registered, when `ZsColors.of`/`ZsElevation.of` run, then they return `night`; given night and paper (and two accent families), when lerped at .5, then a colour and a shadow are the midpoint.
- Given the type roles, when inspected, then each has the DS's size, weight (with `FontVariation.weight`), height (even leading) and letter spacing; when an Inter line is laid out at 600 and at 400 with the real font loaded, then the 600 line is wider.
- Given `0 14px 36px -12px`, when converted, then σ = 18, `blurRadius` ≈ 30.3 and spread −12.
- Given the token layer, when the families and themes are listed, then every family has 11 accent tokens per theme and `--proj-stale` exists in night and paper.
- Given `ZanshinApp` with a fake shell reporting `reduceMotion: true`, when pumped, then `MediaQuery.disableAnimationsOf` below the app root is true, `ZsMotion.of` has `motion` 0 and the five movement durations 0 with every fade unchanged; when the shell then reports false, the running app flips back.
- Given settings light, dark and system (shell dark), when pumped, then the app shows paper, night and night, and the app theme carries `ZsColors` and `ZsElevation`; given the I/O-matrix shells (key 4; key absent + `#4757a1`; key absent + `#F7821B`; setting Zanshin), then the accent tokens are Blue, moon, Orange and moon.
- Given `ZsAppearanceOverride(paper, graphite, increasedContrast, reduceMotion)` and no native plugin, when a probe below `ZsRoot` reads the extensions, then they equal that appearance's resolution and `MediaQuery.disableAnimations` is true.
- Given the registry loaded in `tester.runAsync`, when a `ZanshinIcon` is pumped once, then the first frame paints the glyph.
- Given the boot sequence, when it runs, then its status lines are English; given reduce motion, when the main window opens, then the splash still fades over `splashFadeOut`, and when the splash card is pumped with `reduceMotion` true, then its loader does not animate.
- Given the subset fonts, when their `cmap` tables are parsed, then each maps exactly the two code points.
- Given a shell map with every new key, and one without them, when `ZanshinShellMacOS` decodes them, then the fields carry the sent values, and the defaults (`appleAccentColor` null) respectively.
- Given a settings file without `accentSource`, when it is decoded, then the source is `followMacOS`.
- Given the change, when `cargo make test` runs unpiped from the main session, then it passes, and `flutter build macos --debug` in `app/` compiles the plugin's Swift.

## Spec Change Log

## Review Triage Log

### 2026-10-17 — Review pass
- verdicts: 54 findings — high 0, medium 2, low 38, false 11, maybe-false 3
- findings:
  - `[medium]` `[defer]` (intent A) The shell's native half (Swift observers, live toggle) is exercised only through a mocked channel and the `RecordingShell` fake — pre-existing: no Swift test target and the host needs a live engine; deferred as "the live half of the witnesses is verified only against a fake shell" (mirrored).
  - `[medium]` `[reject]` (intent B) On a real Mac, Multicolor resolves to Blue until an AccentColor asset exists — out of scope by the intent itself (`--accent-native` is "for 11.4's AccentColor asset"); already deferred at planning (item 1).
  - `[low]` `[reject]` (intent C) `ShellTheme` carries no window key status — the intent hands it to 11.12 ("11.12 drives it per window"); `inactive` exists on `ZsAppearance`; deferred at planning (item 2).
  - `[low]` `[reject]` (intent D) `IconRegistryScope` above `WindowManager` and the DI binding are untested/unconsumed — `ZanshinWindowHost` is not unit-testable by design (live engine, runtime smoke check) and no reachable widget draws an icon before 11.3; a test seam would add public surface.
  - `[low]` `[reject]` (intent E) The splash's shell → reduce-motion feed is untested and the fade test's platform flag is now inert — same seam as D; the fade test still pins the unconditional `splashFadeOut`.
  - `[low]` `[reject]` (intent F) `BootFailure`'s root gets no shell and the splash has no `ZsRoot` — the failure page is static (nothing to animate), and the splash keeps its own always-dark root with its own `disableAnimations` override (item 13).
  - `[low]` `[reject]` (intent G) The unemphasized selection for an unfocused field is not implemented, only for an inactive window — no text field exists before 11.11, and a root scope cannot see per-field focus; the field control (11.11, `buildTextSpan`) owns it.
  - `[false]` `[reject]` (intent H) `ZanshinIcon`'s fallback goes through `ZsColors.of` → `Theme` — the last fallback is the `--text` token read from the token extension, not a Material colour; no Material `IconTheme`/`Theme.iconTheme`/`Colors` value is read.
  - `[low]` `[patch]` (intent I) The parity surface: `light`/descendant alternatives skipped and letter spacing outside the CSS shorthand are the spec's model, but the icon lint skipped `workstream.svg` although only the set check tolerates it — patched: the lint now runs over every app file (`workstream.svg` passes).
  - `[false]` `[reject]` (intent J) Cursor policy has no witness and no I-beam/progress/resize surface — the intent moved the cursor witness to 11.11; those cursors belong to controls and resize edges.
  - `[false]` `[reject]` (intent K) The Yaru test page stays home under "no visible control is Material/Yaru-styled" — both sentences are the intent's; replacing the home is 11.3/11.10.
  - `[false]` `[reject]` (intent L) Smaller reading choices (caps helper, aqua/darkAqua, primary = `--accent`, manual 残心 check) — each matches the intent (DS readme.md:175 names aqua/darkAqua; item 3's caps helper; the 残心 check is "by eye" in the intent).
  - `[low]` `[patch]` (intent M) The deferred-work mirror reworded one summary and dropped line numbers — patched: deferred-work.md's four planning entries now carry the spec's summaries verbatim and file:line evidence; spec and mirror land in one commit at finalize.
  - `[low]` `[patch]` (blind 1) `ZsRoot`'s plain `Theme` hides MaterialApp's `AnimatedTheme`, so theme/accent switches snap and the lerps never run — patched: `AnimatedTheme` (default duration; a colour fade, kept under reduce motion).
  - `[low]` `[patch]` (blind 2) Unmapped `ColorScheme` roles keep Material defaults, the comment claims otherwise, and `ThemeData.iconTheme` is unset — patched: `iconTheme: IconThemeData(color: --text)` and the comment corrected; mapping the remaining roles rejected as in edge 12.
  - `[low]` `[patch]` (blind 3) `RenderZanshinIcon` draws from the top-left when forced into a larger box — patched: the token square is centred in `size`.
  - `[low]` `[reject]` (blind 4) The 16-unit grid is hard-coded and the lint does not check the root/viewBox — the DS mandates the 16 grid (readme.md:350, :352) and byte equality pins every file; a root check guards a change the DS forbids.
  - `[low]` `[reject]` (blind 5) The registry's delivery path is untested and a missing registry paints nothing silently — as intent D; "no registry paints nothing" is the spec'd behaviour.
  - `[maybe-false]` `[defer]` (blind 6) The exact Multicolor colour match may miss 11.4's asset by one channel — if true medium; settle on a Mac with the colorset (deferred, unverified, mirrored).
  - `[maybe-false]` `[reject]` (blind 7) Under Increase contrast the selection colours may differ from native fields (named aqua/darkAqua vs high-contrast appearances) — if true only low (a slightly different highlight shade in one mode); settle by resolving under `.accessibilityHighContrastAqua/DarkAqua` on a Mac.
  - `[low]` `[patch]` (blind 8) The plugin now emits identical `ShellTheme`s on several notifications and each rebuilds the app — patched: `_applyShellTheme` returns early when the report is unchanged.
  - `[low]` `[reject]` (blind 9) The CSS reader silently drops a rule whose every selector it skips — no such rule exists in the DS (every token rule has a compound alternative); a fail-loud guard is new complexity for an undemonstrated state.
  - `[low]` `[patch]` (blind 10) No test covers the first frame before the shell answers — patched: `zanshin_app_test.dart` pumps `system` with `getTheme` pending and expects paper.
  - `[low]` `[patch]` (blind 11) The splash's shell subscription can leak, starts late and its notifier is never disposed — patched the leak (subscribe after `SplashWindowController.create`); the late start (getTheme answers within a frame) and the app-lifetime notifier rejected as negligible.
  - `[low]` `[reject]` (blind 12) No status line while the icons load — 59 precompiled glyphs decode in milliseconds; the story names three status lines.
  - `[low]` `[reject]` (blind 13) `ZsElevation.copyWith` cannot clear a blur to `none` — no caller; `resolve` never uses `copyWith` for blurs; a sentinel is new API.
  - `[low]` `[patch]` (blind 14) `ZsRoot` passes reduce motion but not increased contrast to `MediaQuery` — patched: `highContrast: effective.increasedContrast` (asserted in zs_root_test).
  - `[low]` `[patch]` (verification-gap 1) The window root's first-frame theme source and the shell's selection hand-off are unverified — patched: two `zanshin_app_test.dart` cases (pending shell → paper; `selectedTextBackgroundDark` reaches `DefaultSelectionStyle`).
  - `[low]` `[reject]` (verification-gap 2) The shell → splash reduce-motion feed in `ZanshinWindowHost` has no test — as intent E: the host needs a live engine and the seam would add public surface; the code path is six lines, reviewed.
  - `[low]` `[patch]` (verification-gap 3) The icon paint test never checks the 16 → size scale or the translate — patched: ordered translate/saveLayer/scale/drawPicture pattern for `rail` and `xs`, a re-pump with another token, a centred tight 24 × 24 box.
  - `[low]` `[patch]` (verification-gap 4) `ZsAppTheme.build`'s non-colour settings are unasserted — patched: new `zs_app_theme_test.dart` (NoSplash, `--canvas-base`, `bodyMedium`, `iconTheme`, 21 component cursors) for night and paper.
  - `[low]` `[patch]` (verification-gap 5) `BootFailure`'s token theme and root scope are unverified — patched: its test asserts `ZsColors.paper` and a non-null `ZsAppearance` below the page.
  - `[low]` `[patch]` (verification-gap other 1) `sizedByParent` keeps a stale size when a mounted icon's token changes — patched: `performLayout` sets `size = computeDryLayout(constraints)`.
  - `[false]` `[reject]` (verification-gap other 2) `SplashCard` replaces the platform flag instead of combining it — the macOS embedder never sets `disableAnimations` and Linux is a non-goal (project-context: macOS-only), so no reported value is overridden.
  - `[low]` `[reject]` (verification-gap other 3) `ZsElevation.copyWith` cannot express `none` — as blind 13.
  - `[low]` `[reject]` (verification-gap other 4) Nothing in the DI graph reads the `IconRegistry` — as intent D; the module is the intent's DI entry (`SettingsModule(store:)` pattern) for the first injected consumer.
  - `[low]` `[patch]` (edge 1) `sizedByParent` stale layout — as verification-gap other 1.
  - `[low]` `[patch]` (edge 2) Glyph off-centre in a forced box — as blind 3.
  - `[low]` `[reject]` (edge 3) Hard-coded 16 grid — as blind 4.
  - `[false]` `[reject]` (edge 4) No registered shell platform makes `openSplash` throw — `ZanshinShellMacOS` registers as the dartPluginClass before `main` on macOS, the only platform.
  - `[low]` `[patch]` (edge 5) The subscription starts before `create` and leaks if it throws — as blind 11.
  - `[low]` `[reject]` (edge 6) An `onThemeChanged` before the first `getTheme` answer can be overwritten — needs a system change inside one channel round trip; the fix adds state; the view model has the same pre-existing pattern.
  - `[low]` `[reject]` (edge 7) The loader may animate for its first frames under Reduce motion — `getTheme` answers within a frame; a fix reorders the boot.
  - `[false]` `[reject]` (edge 8) `ZsRoot` forces an OS-reported Reduce motion off — the macOS embedder never reports it, so nothing is forced off on the only platform.
  - `[false]` `[reject]` (edge 9) The splash card no longer honours the view's `disableAnimations` — as verification-gap other 2.
  - `[maybe-false]` `[defer]` (edge 10) Exact Multicolor match — as blind 6.
  - `[false]` `[reject]` (edge 11) `fromHue` can return NaN → pink for out-of-range colours — shell colours are 8-bit sRGB `Color(int)` in [0, 1] and the LMS rows have non-negative coefficients, so `cbrt` never sees a negative.
  - `[low]` `[reject]` (edge 12) Unset `ColorScheme` roles leak Material colours into the Yaru test page — the home is the placeholder 11.3/11.10 replace and the Zs controls read tokens, not `ColorScheme`; mapping the roles is a set of new design choices.
  - `[low]` `[patch]` (edge 13) `ThemeData.iconTheme` unset — as blind 2.
  - `[low]` `[reject]` (edge 14) `copyWith` cannot clear a blur — as blind 13.
  - `[false]` `[reject]` (edge 15) `toBoxShadow` on an inset part paints it in release — `boxShadows` filters inset parts; a direct call on one is a programming error the debug assert reports.
  - `[low]` `[patch]` (edge 16) Theme switches snap — as blind 1.
  - `[low]` `[reject]` (edge 17) The reader never matches `[data-accent="multicolor"]` or a bare `[data-theme]` — the DS defines Multicolor as no attribute (accents.css:7) and has no bare theme rule.
  - `[false]` `[reject]` (edge 18) `ZanshinIcon` reads the nearest `IconTheme`'s data instead of `IconTheme.of` — `IconTheme.of` always returns a concrete colour (the fallback), so the spec's "else `--text`" needs the nearest `IconTheme`'s own data; the code implements the spec's chain.

## Design Notes

**Parity model (test-only, `css_token_reader.dart`).** Strip comments; split rules (inside `@media` blocks too); keep only `--*` declarations. A selector list is alternatives; an alternative maps to conditions {theme, accent, contrast, transparency, window, motion, fullscreen} — `:root` = none, `[data-accent]` = any named family, `:is(a,b)` flattened (its specificity = its max arg). All attributes sit on one root element (the DS's own convention, accents.css:6, inactive.css:12), so alternatives with a descendant combinator never match and are skipped; `light` alternatives duplicate paper and are skipped. Resolve an appearance by cascading matching rules by specificity (number of simple selectors), then styles.css import order, then line; then resolve `var()` against that map and evaluate `calc()` (+, −, /). `@media (prefers-…)` rules are not applied: each must equal its attribute twin (feature → attribute), else the token is named. Values are parsed into the token layer's own types and compared with `==` (RGB 8-bit exact, alpha = the CSS decimal); key sets must match per appearance, so an added or removed token fails by name.

**Delta order** mirrors that cascade: theme → family (+ `[data-accent]` derived) → transparency → contrast (contrast wins the scrim) → inactive → inactive × contrast.

**Claude's proposals** (mark them in code): `AccentSource`/`accentSource` naming; `fullScreen` in `ZsAppearance` (driven by 11.4); key status left to 11.12 (`inactive` defaults false); `ShellTheme.accentColor` re-documented as aqua instead of a second field; role letter spacing from the DS's pairings; icon size mapping for mock call sites; `IconRegistryScope` above `WindowManager`; `BootFailure` on the token theme; unknown `AppleAccentColor` values treated as absent.

**Example** — the converter: `blur 36` → σ 18 → `BoxShadow(offset: Offset(0, 14), blurRadius: (18 - .5) / .57735, spread: -12, color: …)` ≈ 30.31.

## Verification

**Commands:**
- `dart run build_runner build --delete-conflicting-outputs` (in `packages/zanshin_settings`, then `app/`) -- expected: regenerated files only; never hand-edit them.
- `flutter build macos --debug` (in `app/`) -- expected: success; compiles the plugin Swift the gate never builds.
- `cargo make test` (repo root, unpiped, main session) -- expected: exit 0 (flutter test incl. parity, every package's analyze/format, cargo, coverage unchanged).

**Manual checks (if no CLI):**
- Ralph, by eye: the splash renders 残心 unchanged with the subset font; toggling macOS Reduce motion, Increase contrast and the accent updates the running app.

## Auto Run Result

Status: done (2026-10-17). Blocking condition: none.

**Summary.** The DS downloaded 2026-10-16 (synced through #9) is now one Dart token layer: `ZsColors` and `ZsElevation` ThemeExtensions resolved over theme × accent family with the transparency → contrast → inactive deltas, `ZsType`/`ZsMetrics`/`ZsMotion` (reduce motion by property), `ZsAppTheme` (no Yaru builder, NoSplash, arrow cursors, token text theme) and the per-window `ZsRoot` (animated token theme, `disableAnimations`/`highContrast` from the shell, ambient text/icon/selection/scroll defaults), with `ZsAppearanceOverride` for tests and 11.11. A DS parity test in `cargo make test` resolves the CSS for 576 appearances and checks the 58 icons byte for byte plus a file-rule lint. `zanshin_shell` reports reduce motion/transparency, increase contrast, `AppleAccentColor`, the aqua accent, the selection colours and the scroller style/paging; Settings gains `accentSource`. Icons are the DS's 58 SVGs precompiled by `vector_graphics_compiler`, decoded once at boot into an `IconRegistry` and painted by a leaf `RenderZanshinIcon` at size tokens. Shippori Mincho is subset to 残心 (~17 MB less) and five unused font files are gone (~27 MB). Splash status lines are English and the cross-fade survives reduce motion.

**Files changed** (paths under `app/` unless noted):
- `lib/src/shared/design/zs_appearance.dart` -- themes, accent families, `ZsAppearance`, the scope and override, the accent detection ("This Mac" hue mapping), `dsSyncedThrough`.
- `lib/src/shared/design/zs_values.dart` -- shadow parts + σ converter, gradient parts, glass filter.
- `lib/src/shared/design/zs_colors.dart`, `zs_accents.dart` -- every colour/gradient token, the 8 named families, `resolve`/`lerp`/`of`/`toCss`.
- `lib/src/shared/design/zs_elevation.dart` -- shadows, rings, blurs.
- `lib/src/shared/design/zs_type.dart`, `zs_metrics.dart`, `zs_motion.dart` -- type roles, metrics (`ZsIconSize`), motion.
- `lib/src/shared/design/zs_app_theme.dart`, `zs_root.dart` -- the app theme and the window root scope.
- `lib/src/shared/widgets/icon_registry.dart`, `zanshin_icon.dart` -- registry/scope/DI module; `ZI` (kebab-case, `all`) and the render box.
- `assets/icons/svg/` -- 58 stripped DS glyphs (36 old files deleted, `workstream.svg` kept); `pubspec.yaml`, root `pubspec.lock` -- vector_graphics + transformer, flutter_svg removed.
- `assets/fonts/` -- Shippori subset (`Shippori_Mincho/SUBSET.txt` records the command), italics and unused weights deleted.
- `lib/src/features/app/zanshin_app.dart`, `zanshin_app_view_model.dart` -- token themes + `ZsRoot`; `appearance`; unchanged reports skip.
- `lib/src/features/bootstrap/{zanshin_bootstrap,boot_failure,boot_window_host,splash_card}.dart`, `lib/main.dart`, `lib/main.inject.dart` -- `loadIcons`, English lines, fade, token failure page, icon scope above `WindowManager`, splash reduce-motion feed, `IconModule`.
- Mock call sites (`features/{commits,shell,history,branches,projects}/…`, `shared/widgets/commit_tags.dart`) -- size tokens and DS names.
- `packages/zanshin_shell_platform_interface`, `zanshin_shell_macos` (Dart + Swift), `zanshin_shell` -- the extended `ShellTheme`, decoding, observers, export.
- `packages/zanshin_settings` -- `AccentSource` (+ regenerated freezed/json, tests).
- Tests: `test/shared/design/{css_token_reader,ds_parity_test,zs_tokens_test,zs_root_test,zs_app_theme_test}.dart`, `test/shared/widgets/zanshin_icon_test.dart`, `test/features/app/zanshin_app_test.dart`, `test/assets/shippori_subset_test.dart`, `test/helpers/{icon_registry,recording_shell}.dart`, updated bootstrap and view-model tests.
- Tracking: this spec, `epic-11-context.md`, `deferred-work.md` ("Surfaced in Story 11.1"), `sprint-status.yaml` (11-1 done).

**Review findings.** 54 findings (high 0, medium 2, low 38, false 11, maybe-false 3). Patched (all low): `AnimatedTheme` in `ZsRoot`; `highContrast` in its `MediaQuery`; `ThemeData.iconTheme` + corrected comment; `RenderZanshinIcon` layout without `sizedByParent` and centred in a forced box; unchanged shell reports skip; splash subscription after `create`; tests for the first frame before the shell answers, the selection hand-off, the icon scale/translate/re-size/centring, `ZsAppTheme`'s non-colour settings and cursors, `BootFailure`'s token root; the icon lint over every file; the deferred-work mirror aligned verbatim with file:line. Deferred: the exact Multicolor match (medium, unverified) and the fake-shell-only live witnesses (medium), plus the four planning items. Rejected, with reasons in the triage log: out of scope by the intent (AccentColor asset → 11.4, key status → 11.12), the untestable host seam (D, E, verification-gap 2, other 4), unfocused-field selection (11.11), Material `ColorScheme` role mapping, the hard-coded 16 grid, the reader's skipped-rule guard, the icons status line, `copyWith` blurs, splash first-frame/race edges, and the 11 false findings.

**Follow-up review recommendation:** false — this first pass patched 0 high and 0 medium entries (13 low entry groups); no named unverified risk calls for another pass.

**Verification.**
- `dart run build_runner build --delete-conflicting-outputs` in `packages/zanshin_settings` and `app/` -- no drift (inject_generator warns that the `IconRegistry` binding has no consumer yet, expected).
- `flutter build macos --debug` in `app/` -- built, before and after the review patches (compiles the plugin Swift).
- `cargo make test` (unpiped, main session, after the patches) -- exit 0: app 120 tests, zanshin_core 787, shell/pi/macos/settings suites, every analyze/format, cargo test/clippy/fmt/deny/hygiene, coverage held at 99.49 % with extern-coverage OK (baseline unchanged). Note: the gate's coverage step needs the default rustup home (`~/.rustup`, which has `llvm-tools`); exporting `RUSTUP_HOME=~/development/sdks/rustup` as in `.zshrc` makes it fail on a missing `llvm-profdata`.
- Matrix audit: every I/O-matrix row has a passing test (accent cases in `zs_tokens_test`/`zanshin_app_test`/view-model test; parity and icon negatives in `ds_parity_test`; shell decode in `zanshin_shell_macos_test`).

**Residual risks.**
- Manual, for Ralph: the splash's 残心 with the subset font, and live toggling of Reduce motion, Increase contrast and the accent on a real Mac (the native emit path has no automated test).
- On a real Multicolor Mac the accent shows Blue until 11.4 adds the AccentColor asset.
- `IconRegistryScope` reaches windows only through `ZanshinWindowHost` (no unit test); no reachable widget draws an icon before 11.3.
- The home is still the Yaru test page; Material `ColorScheme` roles other than the accent/surface/error keep Material's defaults there.
