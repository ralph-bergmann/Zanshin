---
title: 'Rebuild the splash window content from the Zanshin design'
type: 'feature'
created: '2026-09-12'
status: 'done'
baseline_revision: '6969807afcb56b4ee4abe57d3569c222a4e5950b'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/implementation-artifacts/design/assets/SPLASH-SPEC.md'
  - '{project-root}/_bmad-output/implementation-artifacts/design/assets/zanshin-splash.svg'
  - '{project-root}/_bmad-output/implementation-artifacts/design/Zanshin Splash Screen v2.html'
warnings: ['oversized']
deferred:
  - summary: >-
      The painted splash card carries no semantics and ignores the system text size.
    evidence: |-
      The kanji lock-up, the ZANSHIN wordmark and the tagline are canvas paint with no
      Semantics node, so a screen reader gets no app identity from the splash; the status
      line has no `liveRegion: true`, so its changes are never announced; both footer
      lines are RichText at a fixed 11.5/12 px, i.e. TextScaler.noScaling. The previous
      Lottie card had no semantics either — nothing regressed — but this is the first
      splash carrying text worth announcing, and the card's fixed 560x320 grid means
      honouring text scaling is a design decision, not a mechanical change.
    location: >-
      app/lib/src/features/bootstrap/splash_card.dart
    severity: medium
  - summary: >-
      Nothing regression-tests the painted design; the only pixel check is a one-time screenshot.
    evidence: |-
      About 600 of splash_card_render.dart's 678 lines (gradients, light edge, ornament,
      grain, watermark, lock-up, wordmark, tagline, divider, rail, runner, border) carry
      no assertion. The design was verified once by eye against zanshin-splash.svg and
      that capture is committed as evidence, not as a gate, so a mistranscribed constant
      ships green from here on. The repo has no golden-test infrastructure, and goldens
      over three custom fonts plus a soft-light blend are the fragile kind — standing
      them up is a project-level decision.
    location: >-
      app/lib/src/features/bootstrap/splash_card_render.dart
    severity: medium
---

<intent-contract>

## Intent

**Problem:** The splash window shows a placeholder — a 320×320 dark square with the Lottie
loader — while a finished splash design exists (560×320 card: layered indigo gradients, wave
ornament, kanji watermark, 残心 + ZANSHIN lock-up, tagline, footer with version and a live
status line, animated progress runner). The splash also shows no boot progress at all.

**Approach:** Replace `SplashCard`'s body with a single slotted `RenderBox` that paints the
whole design on its `Canvas` and carries exactly two widget children — the footer version and
the status line — so both can update while the card is on screen. Feed the status line from a
new `ValueListenable<String>` on `ZanshinBootSequence` (`log(...)` per boot step) and the
version from `package_info_plus`.

## Boundaries & Constraints

**Always:**
- Card is 560×320 logical px, radius 14, always dark; `splashWindowSize`/`splashCardRadius`
  in `splash_card.dart` are the single source for the native window size.
- Geometry, colours, paths and timings come from `SPLASH-SPEC.md` + `zanshin-splash.svg`;
  the HTML supplies the grain parameters (layer `.5` × rect `.32` ≈ `0.16`, soft-light) and
  the two keyframes (runner 2.1 s `Cubic(.65,.05,.35,.95)`, dot 1.85 s `Curves.easeInOut`).
- Everything except the two slot children is painted directly in the render box — no
  `Column`/`Row`/`Stack` of widgets for the design.
- "Reduce motion" (`MediaQuery.disableAnimationsOf`) freezes the runner at a fixed phase and
  pins the dot to full opacity; with it on, no ticker runs and no repaint is scheduled.
- The card never waits for the grain tile: paint without it until the image resolved.
- SPDX first line on every new/edited Dart file; `dart analyze --fatal-infos
  --fatal-warnings` and `dart format` (page width 120) clean; `cargo make test` green.
- `git commit --no-gpg-sign`; add files by explicit path (never `git add .`).

**Block If:**
- The design sources contradict each other on a load-bearing value in a way that changes the
  visible result and neither can be preferred (SVG wins on coordinates, HTML on animation and
  grain, SPLASH-SPEC on colour tokens — so this should not trigger).
- Visual verification is impossible by *both* the marionette route and the temporary
  `runApp(SplashCard(...))` route (Plan B).

**Never:**
- No new splash dependency beyond `package_info_plus`; `lottie` and both
  `assets/lottie/*.json` stay (they remain in-app loaders).
- No day/night switching on the splash, no theme lookup.
- No change to the windowing/AppKit seams (`SplashWindowController`, `AppWindows`,
  `WindowingBootstrap.swift`) and no edits to their comments.
- No committed variant of `main.dart` other than the windowing boot path.
- No fabricated boot steps — only the two that exist (`openSettings`, `startApp`).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Card layout | `SplashCard` mounted | render box is 560×320; version child at x = 36, status child right edge at x = 524, both alphabetic baseline y = 276 | No error expected |
| Status update | status listenable changes to `'starte App…'` | status slot rebuilds, stays right-aligned at x = 524 | No error expected |
| Empty status | initial status `''` | card paints; dot sits 11 px left of the (zero-width) status box | No error expected |
| Boot steps | `ZanshinBootSequence.run()` with both steps completing | `status` emits `'lade Settings…'` then `'starte App…'` in that order | failure path keeps the last status |
| Reduce motion | `accessibilityFeatures.disableAnimations = true` | runner frozen, dot at full opacity, `transientCallbackCount == 0` | No error expected |
| Version unavailable | `PackageInfo.fromPlatform()` throws (e.g. widget test) | version slot stays empty, boot continues | warning logged, never rethrown |
| Grain tile missing/slow | asset not yet decoded | card paints all layers except the grain | failure logged once, no retry |

</intent-contract>

## Code Map

- `app/lib/src/features/bootstrap/splash_card.dart` -- REPLACE body. Holds
  `splashWindowSize` (→ `Size(560, 320)`) and `splashCardRadius` (→ `14`), both read by
  `boot_window_host.dart:42`. Today: `StatelessWidget` with `MediaQuery.fromView(view:
  View.of(context))` + `DecoratedBox` + `Lottie.asset`. Keep the `MediaQuery.fromView`
  wrapper (a window provides only the `View`, and the existing reduced-motion tests drive
  `platformDispatcher.accessibilityFeaturesTestValue` through it).
- `app/lib/src/features/bootstrap/splash_card_render.dart` -- NEW. Slot enum + the
  `RenderBox` (`SlottedContainerRenderObjectMixin<_, RenderBox>`), all design tokens and
  all painting; owns the `Ticker` created from the `TickerProvider` handed in.
- `app/lib/src/features/bootstrap/zanshin_bootstrap.dart` -- `splashAnimationAsset` (l. 14)
  and `splashAnimationSize` (l. 17) are only used by the old splash body → delete both, and
  the loader-swap doc comment above them. `splashIndicatorMinShow` (l. 23) → 5 s.
  `BootWindowHost.openSplash()` (l. 38) gains the two listenables. `_load()` (l. 126) gets
  the two `log(...)` calls. Class doc at l. 61 mentions "320×320 card" → 560×320.
- `app/lib/src/features/bootstrap/boot_window_host.dart:41-47` -- `openSplash` forwards the
  listenables into `SplashCard`; `windows.capture((_) => const SplashCard())` loses `const`.
- `app/test/features/bootstrap/zanshin_bootstrap_test.dart` -- `FakeBootWindowHost.openSplash`
  (l. 44) must match the new signature. Timing tests at l. 128/146/149/162/202/209 hard-code
  500/1500/3000 ms and are **already red** (Ralph moved the constants in `047fee7` without
  touching the tests) → drive them off `splashIndicatorDelay`/`splashIndicatorMinShow`.
  Lottie assertions at l. 292-315 replace with the new card tests.
- `app/pubspec.yaml` -- `version: 0.1.0` → `2026.9.1+1`; add `package_info_plus`; register
  the three font families; add `assets/images/grain_128.png`. `app/macos/Runner/Info.plist`
  already uses `$(FLUTTER_BUILD_NAME)`/`$(FLUTTER_BUILD_NUMBER)` (l. 19-22) — no change.
  `app/macos/Flutter/GeneratedPluginRegistrant.swift` is tracked and regenerates on the next
  macOS build → commit the added plugin line.
- `app/assets/fonts/{Inter,JetBrains_Mono,Shippori_Mincho}/` -- on disk:
  `Inter-VariableFont_opsz,wght.ttf`, `JetBrainsMono-VariableFont_wght.ttf`,
  `ShipporiMincho-{Regular,Medium,SemiBold,Bold,ExtraBold}.ttf` (+ `OFL.txt`, `README.txt`,
  `.DS_Store` — never register those).
- `app/macos/Runner/WindowingBootstrap.swift:130-145` -- read-only evidence: `configure`
  takes the content size from Dart and sets `hasShadow = true`, so the design's outer
  `boxShadow` is the native window shadow — do **not** paint it inside the card.
- `linter/rules.yaml` -- page width 120; `prefer_int_literals`, `require_trailing_commas`,
  `specify_nonobvious_local_variable_types`, `avoid_redundant_argument_values`,
  `discarded_futures`, `sort_constructors_first` all apply to the new files.

## Tasks & Acceptance

**Execution:**
- `app/tool/gen_grain_tile.dart` -- NEW: pure-Dart generator that writes a deterministic
  128×128 8-bit greyscale noise PNG (seeded `Random`, `ZLibCodec` + CRC32, no new package
  dependency) -- the grain cannot be computed per frame in Dart and must be a committed tile.
- `app/assets/images/grain_128.png` -- NEW: the generated tile, committed.
- `app/pubspec.yaml` -- set `version: 2026.9.1+1`, add `package_info_plus` (latest stable via
  `flutter pub add`), register font families `Inter` / `JetBrainsMono` / `ShipporiMincho`
  (Medium w500, SemiBold w600), add the grain asset -- the card needs the real families and
  a version to show.
- `app/lib/src/features/bootstrap/splash_card_render.dart` -- NEW: design tokens + the
  slotted render box: sizes to 560×320, positions the two children on the spec baselines,
  paints the four gradients (elliptical radials reproduced with `ui.Gradient.radial` + a
  scale matrix, not a circular approximation), the grain (`ImageShader`, `TileMode.repeated`,
  soft-light at 0.16 via `saveLayer`), the wave ornament, the kanji watermark, the lock-up,
  the wordmark strokes with the gold shader, the tagline, the divider, the status dot, the
  progress rail + runner, the top light edge and the inner gold border; drives runner and
  dot from one `Ticker` -- one render pass keeps the design one coherent artifact.
- `app/lib/src/features/bootstrap/splash_card.dart` -- rewrite: `splashWindowSize` =
  `Size(560, 320)`, `splashCardRadius` = `14`; `SplashCard` becomes a `StatefulWidget`
  (`SingleTickerProviderStateMixin`) taking `status` and `version` listenables, resolving the
  grain image once, and building the slotted widget with the two styled `Text` children
  (`ValueListenableBuilder` each) -- the ticker needs a vsync and the image a state.
- `app/lib/src/features/bootstrap/zanshin_bootstrap.dart` -- drop the Lottie constants, set
  `splashIndicatorMinShow` to 5 s, add the `SplashVersion` record typedef, the `status` /
  `version` listenables with `log(...)`, the guarded `PackageInfo.fromPlatform()` load, the
  two step logs in `_load()`, and the widened `openSplash` -- the splash has to be told what
  the boot is doing.
- `app/lib/src/features/bootstrap/boot_window_host.dart` -- forward the two listenables into
  `SplashCard` -- the host is the only place that builds the splash content.
- `app/test/features/bootstrap/zanshin_bootstrap_test.dart` -- update the fake host, express
  the timing tests through the constants, and add the I/O-matrix cases (layout, status
  update, boot-step order, reduce-motion) -- the suite is currently red and must cover the
  new seams.

**Acceptance Criteria:**
- Given the app boots slowly, when the splash window appears, then it is 560×320 with radius
  14 and shows the designed card (lock-up centred with 残心 left of the ZANSHIN wordmark,
  "JUJUTSU CLIENT" centred beneath, divider at y = 253, version bottom-left, pulsing dot +
  status bottom-right, runner sweeping the bottom edge) — verified against
  `zanshin-splash.svg` on a screenshot of the running app, committed to
  `_bmad-output/implementation-artifacts/design/splash-flutter-screenshot.png`.
- Given the boot runs, when each step starts, then the status line shows that step's German
  text, and the version line reads `<version> · Build <build>` with the version part in
  `#E7DCC4` and the build part in `#8792B4`.
- Given `cargo make test`, when it runs unpiped to completion, then it passes (`flutter
  test`, `dart analyze --fatal-infos --fatal-warnings`, `dart format` included).
- Given the repo after the change, when the working tree is inspected, then it is clean, the
  committed `main.dart` is the windowing boot path, and `lottie` plus both Lottie assets are
  still present.

## Spec Change Log

## Review Triage Log

### 2026-09-12 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 10: (high 0, medium 2, low 8)
- defer: 2: (high 0, medium 2, low 0)
- reject: 24: (high 0, medium 6, low 18)
- addressed_findings:
  - `[medium]` `[patch]` The dot-placement assertion used an empty status, where `_statusLeft`
    equals its initialiser — deleting the layout line kept the test green. Added a dot
    assertion with a non-empty status, measured from the status text's own width.
  - `[medium]` `[patch]` `set animate` was never exercised: both reduce-motion measurements
    remounted the card, so the mid-life accessibility path went through `createRenderObject`.
    Added an in-place toggle case.
  - `[low]` `[patch]` `splashIndicatorMinShow`'s doc comment still justified the old value
    ("so it never just blinks"); it now says the 5 s hold is the deliberate dev setting.
  - `[low]` `[patch]` Both footer lines could wrap off the design's baseline grid; they now
    carry `maxLines: 1` / `softWrap: false` / ellipsis, matching the HTML's `white-space: nowrap`.
  - `[low]` `[patch]` The render box disposed its `TextPainter`s but leaked every cached
    `ui.Shader` (four background gradients, grain, runner, wordmark); they are disposed now,
    including the ones dropped on cache invalidation.
  - `[low]` `[patch]` The grain generator's doc implied it reproduces `feTurbulence` and
    promised byte-identical reruns; it now states the white-noise simplification and scopes
    reproducibility to a given Dart SDK.
  - `[low]` `[patch]` The render file cited the design sources by unresolvable names; the
    repo-relative `_bmad-output/implementation-artifacts/design/…` paths replace them.
  - `[low]` `[patch]` The deleted "stays dark under a light platform brightness" test left the
    always-dark invariant unverified; restored against the painted card.
  - `[low]` `[patch]` The version line's display format (two spans, `#E7DCC4` + `#8792B4`) was
    unasserted; the footer-grid test now checks both spans.
  - `[low]` `[patch]` The committed `grain_128.png` was unverifiable and could drift from its
    generator; a new test pins its bytes against `grainTilePng()` and decodes it at 128×128.

## Design Notes

**Slot layout.** Two slots (`version`, `status`), children are `RenderBox`es with
`BoxParentData`. Lay out each with loose constraints (max width 488 = 560 − 2·36), then place
`version` at `(36, 276 − baseline)` and `status` at `(524 − width, 276 − baseline)` using
`child.getDistanceToBaseline(TextBaseline.alphabetic)` (fall back to `size.height` when
null, so an empty status still lands sanely). Remember the status child's left edge during
layout: the dot's centre is `statusLeft − 11` (HTML `gap: 8` + 3 px radius) at y = 272.

**Lock-up centring.** The SVG's `x = 117` / `translate(229 104)` follow from centring
`kanjiWidth + 20 + 562·0.38` on x = 280; measure the kanji with a `TextPainter` and centre
the group instead of hard-coding 117, so a font-metric difference cannot push the group
off-centre. Kanji baseline y = 141, wordmark box y = 104…142.

**Ticker.** The render box creates its ticker from the injected `TickerProvider`, starts it
in `attach`, stops it in `detach`, disposes it in `dispose` (the render object's element
unmounts before `State.dispose`, so `SingleTickerProviderStateMixin`'s assert holds). With
`animate == false` the ticker is never started and `_elapsed` stays at a fixed phase.

**Caching.** Build the wordmark `Path`, the gold shader and the four `TextPainter`s
(watermark ×2, lock-up, tagline) lazily and keep them in fields — `paint` runs 60×/s while
the ticker is alive.

## Verification

**Commands:**

`flutter`, `dart`, `cargo` and `cargo make` are on the PATH of a foreground shell. A
*backgrounded* shell needs them exported first: `export SDK_PATH=$HOME/development/sdks;
export CARGO_HOME=$SDK_PATH/cargo; export RUSTUP_HOME=$SDK_PATH/rustup; export
FLUTTER_ROOT=$SDK_PATH/flutter; export PATH=$FLUTTER_ROOT/bin:$CARGO_HOME/bin:$PATH`.

- `dart run tool/gen_grain_tile.dart` (in `app/`) -- expected: writes
  `assets/images/grain_128.png`, 128×128, ~16 KB or less.
- `flutter pub get` (in `app/`) -- expected: resolves with `package_info_plus`.
- `flutter test test/features/bootstrap/zanshin_bootstrap_test.dart` (in `app/`) -- expected:
  all tests pass.
- `cargo make test` (repo root, unpiped, timeout ≥ 600 s) -- expected: the whole gate passes,
  coverage ratchet included (Rust-only, so unaffected by this story).

**Manual checks (if no CLI):**
- Run `flutter run -d macos --debug` from `app/`, screenshot the splash through the
  `marionette` MCP (or Plan B: a temporary `runApp(SplashCard(...))` in `main.dart`, reverted
  afterwards), read the PNG and compare it against `zanshin-splash.svg` element by element;
  fix deviations, then commit the screenshot next to the design assets and kill the
  `flutter run` process.

## Auto Run Result

Status: done
Blocking condition: none

**What was implemented.** The splash window now shows the designed 560×320 card instead of the
320×320 Lottie placeholder. One slotted `RenderBox` paints the whole design in a single pass —
four stacked gradients (the three radials as true ellipses via `ui.Gradient.radial` plus a scale
matrix), the 1-px top light edge, the wave ornament, the grain tile in a soft-light layer at
0.16, the vertical kanji watermark, the 残心 + ZANSHIN lock-up (kanji measured with a
`TextPainter`, the group centred, the wordmark stroked from the spec's unit paths under a gold
shader), the tagline, the footer divider, the status dot, the progress rail with its animated
runner, and the inner gold hairline. Only the two footer texts are widgets, in the render box's
`version` and `status` slots, placed on the design's baseline grid (x = 36 / right edge x = 524,
alphabetic baseline y = 276). One `Ticker` drives the runner (2.1 s, `Cubic(.65,.05,.35,.95)`)
and the dot's pulse (1.85 s, `easeInOut`); under "reduce motion" no ticker starts and no frame is
scheduled. `ZanshinBootSequence` gained the two listenables that feed the card — a German status
line per boot step and the version from `package_info_plus` — and holds the splash for 5 s so the
card can be looked at during development.

**Files changed**
- `app/lib/src/features/bootstrap/splash_card_render.dart` — new: design tokens, the slotted
  widget and the render box that paints the card and owns the ticker.
- `app/lib/src/features/bootstrap/splash_card.dart` — the card's public widget: 560×320 / radius
  14, the ticker provider, the grain image, and the two `ValueListenableBuilder` slot children.
- `app/lib/src/features/bootstrap/zanshin_bootstrap.dart` — `status`/`version` listenables,
  `log()`, the guarded `PackageInfo` read, the widened `openSplash`, 5 s minimum show; Lottie
  constants dropped.
- `app/lib/src/features/bootstrap/boot_window_host.dart` — forwards both listenables into the card.
- `app/tool/gen_grain_tile.dart` + `app/assets/images/grain_128.png` — new: the committed grain
  tile and the dependency-free generator that writes it.
- `app/pubspec.yaml`, `pubspec.lock`, `app/macos/Flutter/GeneratedPluginRegistrant.swift` —
  `version: 2026.9.1+1`, `package_info_plus`, the three font families, the grain asset.
- `app/test/features/bootstrap/zanshin_bootstrap_test.dart` — timing tests expressed through the
  constants (they were red since `047fee7`), plus the card's layout, status, version, dot,
  reduce-motion and brightness cases.
- `app/test/features/bootstrap/splash_grain_tile_test.dart` — new: the committed tile matches its
  generator and decodes at 128×128 through the bundle.
- `_bmad-output/implementation-artifacts/design/splash-flutter-screenshot.png` — the capture the
  design was checked against.

**Review findings.** 36 findings over four layers, deduplicated: 10 patched (2 medium, 8 low),
2 deferred (both medium, mirrored into `deferred-work.md`), 24 rejected. No intent gap and no
spec repair loop. The patches closed a vacuous dot assertion, an untested `set animate` path, the
deleted always-dark test, the unasserted version format, an unverifiable committed binary, leaked
shader handles, wrapping footer lines, and three stale or overstated comments.

**Follow-up review recommendation:** `true` — patched findings 0 high, 2 medium, 8 low, score
3 × 2 + 1 × 8 = 14 ≥ 5.

**Verification.** `cargo make test` run unpiped to completion twice (before and after the review
patches): green both times — 35 app widget tests, all other Dart suites, `dart analyze
--fatal-infos --fatal-warnings` and `dart format` clean, Rust tests pass, coverage ratchet held at
99.27 % (9059/9126) with the baseline unchanged. Every row of the I/O matrix is covered by a test
that ran and passed. Visually, the running app's splash was captured through the VM service's
inspector screenshot extension (`screencapture` has no screen-recording permission and marionette
errored) and compared against `zanshin-splash.svg`: the lock-up, tagline, divider, footer, dot and
runner all land on the design's coordinates, and sampled pixels match the design's colours exactly
(runner `#F4CF80`, divider `#FFFFFF` @ 8 %).

**Residual risks.**
- The painted design has no regression test; a mistranscribed constant would ship green (deferred
  above, with the screenshot as the current evidence).
- `splash_grain_tile_test.dart`'s byte-equality assertion goes red on a Dart SDK bump that changes
  `Random`'s sequence; the test names the fix (re-run the generator, commit the tile).
- `_readVersion`'s mapping from `PackageInfo` into the `SplashVersion` record is exercised only
  through its failure path (no package-info channel in a widget test); a transposition of the two
  fields would only show on a real run.
- The 5 s minimum show is a deliberate development setting, not a shipping value.
