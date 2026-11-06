// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show AccentSource;
import 'package:zanshin_shell/zanshin_shell.dart' show ShellTheme;

import 'zs_accents.dart';

/// The design-system sync the token layer mirrors: the DS downloaded 2026-10-29 is "synced through #15"
/// (DS readme.md:22). It rises when the DS records #16.
const dsSyncedThrough = 15;

/// The two themes (decision 16.11; DS tokens/colors.css:9, :79). `[data-theme="light"]` is an alias of paper.
enum ZsTheme {
  /// The indigo night, the default.
  night(Brightness.dark),

  /// The warm paper.
  paper(Brightness.light);

  const ZsTheme(this.brightness);

  /// The Material brightness this theme maps to.
  final Brightness brightness;

  /// Night for [Brightness.dark], paper for [Brightness.light].
  static ZsTheme of(Brightness brightness) => switch (brightness) {
    Brightness.dark => night,
    Brightness.light => paper,
  };
}

/// How much air rows and graph cards get (DS tokens/spacing.css, `data-density`; Story 11.20): never how big.
enum ZsDensity {
  /// The DS spacing everywhere else in the system (the default).
  compact,

  /// Rows +3, cards 44 / 68, gaps 62 × 54.
  balanced,

  /// Rows +6, cards 48 / 74, gaps 68 × 60.
  comfy,
}

/// The accent families of the accent role (decision 16.2; DS tokens/accents.css:2-26): Multicolor is Zanshin's own
/// moon, the eight named ones follow a named macOS accent.
enum ZsAccentFamily {
  /// Zanshin's moon: macOS Multicolor, or the Settings choice "Zanshin".
  multicolor,

  /// macOS Blue (`AppleAccentColor` 4).
  blue,

  /// macOS Purple (5).
  purple,

  /// macOS Pink (6).
  pink,

  /// macOS Red (0).
  red,

  /// macOS Orange (1).
  orange,

  /// macOS Yellow (2).
  yellow,

  /// macOS Green (3).
  green,

  /// macOS Graphite (−1).
  graphite;

  /// The family the app shows for the Settings choice [source] and the shell's report [shell].
  ///
  /// "Zanshin", or no report yet, gives Multicolor. Otherwise the detection order of DS readme.md:181 (V1 §4): a
  /// present `AppleAccentColor` names the family; with the key absent, a reported colour equal to Zanshin's own app
  /// accent (`--accent-native`) is Multicolor, and any other colour is an iMac's "This Mac" colour, mapped by hue
  /// ([fromHue]).
  static ZsAccentFamily resolve({required AccentSource source, required ShellTheme? shell}) {
    if (source == AccentSource.zanshin || shell == null) {
      return multicolor;
    }
    final ZsAccentFamily? named = fromAppleAccentColor(shell.appleAccentColor);
    if (named != null) {
      return named;
    }
    if (shell.accentColor == ZsAccents.native) {
      return multicolor;
    }
    return fromHue(shell.accentColor);
  }

  /// The family macOS's `AppleAccentColor` value names, or null when it is absent.
  ///
  /// Claude's proposal (Story 11.1): a value outside −1…6 is treated as absent, so the colour rules decide.
  static ZsAccentFamily? fromAppleAccentColor(int? value) => switch (value) {
    -1 => graphite,
    0 => red,
    1 => orange,
    2 => yellow,
    3 => green,
    4 => blue,
    5 => purple,
    6 => pink,
    _ => null,
  };

  /// The "This Mac" mapping (DS tokens/accents.css:8-10; DS readme.md:181): [color] in OKLCH; chroma under .03 is
  /// Graphite (the silver iMac), otherwise the band of the nearest macOS hue anchor — red 9.5–38.5, orange –70.5,
  /// yellow –113, green –198, blue –292, purple –341.5, pink –9.5 (degrees). The only colour-space maths in the
  /// token layer.
  static ZsAccentFamily fromHue(Color color) {
    final (:double chroma, :double hue) = _oklch(color);
    if (chroma < .03) {
      return graphite;
    }
    if (hue >= 9.5 && hue < 38.5) {
      return red;
    }
    if (hue >= 38.5 && hue < 70.5) {
      return orange;
    }
    if (hue >= 70.5 && hue < 113) {
      return yellow;
    }
    if (hue >= 113 && hue < 198) {
      return green;
    }
    if (hue >= 198 && hue < 292) {
      return blue;
    }
    if (hue >= 292 && hue < 341.5) {
      return purple;
    }
    return pink;
  }

  /// OKLCH chroma and hue (degrees, 0–360) of an sRGB [color] (Björn Ottosson's Oklab).
  static ({double chroma, double hue}) _oklch(Color color) {
    double linear(double c) => c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    double cbrt(double x) => math.pow(x, 1 / 3).toDouble();
    final double r = linear(color.r);
    final double g = linear(color.g);
    final double b = linear(color.b);
    final double l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    final double m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    final double s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    final double a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
    final double bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
    final double hue = math.atan2(bb, a) * 180 / math.pi;
    return (chroma: math.sqrt(a * a + bb * bb), hue: hue < 0 ? hue + 360 : hue);
  }
}

/// Everything the token layer resolves over: the two axes (theme × accent family) and the deltas on top of them
/// (DS readme.md:183; tokens/contrast.css, inactive.css, transparency.css, motion.css, spacing.css:52).
///
/// Window roots install it through `ZsRoot`; [ZsAppearance.of] reads the nearest one.
@immutable
class ZsAppearance {
  /// Creates an appearance; every delta is off by default.
  const ZsAppearance({
    this.theme = ZsTheme.night,
    this.family = ZsAccentFamily.multicolor,
    this.increasedContrast = false,
    this.reduceMotion = false,
    this.reduceTransparency = false,
    this.inactive = false,
    this.fullScreen = false,
    this.trafficLights,
    this.density = ZsDensity.compact,
  });

  /// The nearest installed appearance, or the default one (night, Multicolor, no delta) outside any window root.
  factory ZsAppearance.of(BuildContext context) => maybeOf(context) ?? const ZsAppearance();

  /// What a window shows for [theme], the Settings choice [accentSource] and the shell's report [shell]: the family
  /// from [ZsAccentFamily.resolve] (decision 16.2) and the shell's three accessibility flags (all off until the shell
  /// answered). Full screen and the traffic-light block come from the window's chrome report, which the window root
  /// copies in (Story 11.4); the key status stays false until 11.12 drives it.
  ///
  /// Claude's proposal (Story 11.11): one derivation for the app's view model and the catalogue.
  factory ZsAppearance.fromShell({
    required ZsTheme theme,
    required AccentSource accentSource,
    required ShellTheme? shell,
  }) => ZsAppearance(
    theme: theme,
    family: ZsAccentFamily.resolve(source: accentSource, shell: shell),
    increasedContrast: shell?.increaseContrast ?? false,
    reduceMotion: shell?.reduceMotion ?? false,
    reduceTransparency: shell?.reduceTransparency ?? false,
  );

  /// Night or paper.
  final ZsTheme theme;

  /// The accent family the accent role shows.
  final ZsAccentFamily family;

  /// macOS Increase contrast (DS tokens/contrast.css).
  final bool increasedContrast;

  /// macOS Reduce motion (DS tokens/motion.css:69-71).
  final bool reduceMotion;

  /// macOS Reduce transparency (DS tokens/transparency.css).
  final bool reduceTransparency;

  /// Whether the window is not key (DS tokens/inactive.css).
  ///
  /// Claude's proposal (Story 11.1): false until 11.12 drives the key status per window.
  final bool inactive;

  /// Whether the window is in full screen (DS tokens/spacing.css:52).
  ///
  /// Claude's proposal (Story 11.1): part of the appearance, so the metrics resolve it like the other deltas; the
  /// window's chrome report drives it (Story 11.4).
  final bool fullScreen;

  /// The system's traffic-light block as the shell measured it, in the window's logical pixels with the origin top
  /// left (DS tokens/spacing.css:25-30); null before the window's chrome report, off macOS and in full screen, and
  /// then the metrics take the reference geometry.
  final Rect? trafficLights;

  /// The Settings density (DS tokens/spacing.css, `data-density`): the row step, card heights and graph gaps.
  final ZsDensity density;

  /// The nearest installed appearance, or null outside any window root.
  static ZsAppearance? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ZsAppearanceScope>()?.appearance;

  /// Returns a copy with the given values replaced.
  ZsAppearance copyWith({
    ZsTheme? theme,
    ZsAccentFamily? family,
    bool? increasedContrast,
    bool? reduceMotion,
    bool? reduceTransparency,
    bool? inactive,
    bool? fullScreen,
    Rect? trafficLights,
    ZsDensity? density,
  }) => ZsAppearance(
    theme: theme ?? this.theme,
    family: family ?? this.family,
    increasedContrast: increasedContrast ?? this.increasedContrast,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    reduceTransparency: reduceTransparency ?? this.reduceTransparency,
    inactive: inactive ?? this.inactive,
    fullScreen: fullScreen ?? this.fullScreen,
    trafficLights: trafficLights ?? this.trafficLights,
    density: density ?? this.density,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZsAppearance &&
          other.theme == theme &&
          other.family == family &&
          other.increasedContrast == increasedContrast &&
          other.reduceMotion == reduceMotion &&
          other.reduceTransparency == reduceTransparency &&
          other.inactive == inactive &&
          other.fullScreen == fullScreen &&
          other.trafficLights == trafficLights &&
          other.density == density;

  @override
  int get hashCode => Object.hash(
    theme,
    family,
    increasedContrast,
    reduceMotion,
    reduceTransparency,
    inactive,
    fullScreen,
    trafficLights,
    density,
  );

  @override
  String toString() =>
      'ZsAppearance(${theme.name}, ${family.name}, increasedContrast: $increasedContrast, reduceMotion: '
      '$reduceMotion, reduceTransparency: $reduceTransparency, inactive: $inactive, fullScreen: $fullScreen, '
      'trafficLights: $trafficLights, density: ${density.name})';
}

/// Installs the effective [ZsAppearance] for a subtree; `ZsRoot` places it at every window root.
class ZsAppearanceScope extends InheritedWidget {
  /// Installs [appearance] for [child].
  const ZsAppearanceScope({required this.appearance, required super.child, super.key});

  /// The appearance below this scope.
  final ZsAppearance appearance;

  @override
  bool updateShouldNotify(ZsAppearanceScope oldWidget) => appearance != oldWidget.appearance;
}

/// Overrides parts of the appearance a window root resolves, for tests and the catalogue's Appearance addon (11.11);
/// the app itself never offers an in-app switch for the system settings. Place it above a `ZsRoot`.
class ZsAppearanceOverride extends InheritedWidget {
  /// Overrides every non-null value for the window roots below.
  const ZsAppearanceOverride({
    required super.child,
    this.theme,
    this.family,
    this.increasedContrast,
    this.reduceMotion,
    this.reduceTransparency,
    this.inactive,
    this.fullScreen,
    super.key,
  });

  /// Replaces [ZsAppearance.theme] when set.
  final ZsTheme? theme;

  /// Replaces [ZsAppearance.family] when set.
  final ZsAccentFamily? family;

  /// Replaces [ZsAppearance.increasedContrast] when set.
  final bool? increasedContrast;

  /// Replaces [ZsAppearance.reduceMotion] when set.
  final bool? reduceMotion;

  /// Replaces [ZsAppearance.reduceTransparency] when set.
  final bool? reduceTransparency;

  /// Replaces [ZsAppearance.inactive] when set.
  final bool? inactive;

  /// Replaces [ZsAppearance.fullScreen] when set.
  final bool? fullScreen;

  /// The nearest override, or null.
  static ZsAppearanceOverride? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ZsAppearanceOverride>();

  /// [base] with every value this override sets replaced.
  ZsAppearance applyTo(ZsAppearance base) => base.copyWith(
    theme: theme,
    family: family,
    increasedContrast: increasedContrast,
    reduceMotion: reduceMotion,
    reduceTransparency: reduceTransparency,
    inactive: inactive,
    fullScreen: fullScreen,
  );

  @override
  bool updateShouldNotify(ZsAppearanceOverride oldWidget) =>
      theme != oldWidget.theme ||
      family != oldWidget.family ||
      increasedContrast != oldWidget.increasedContrast ||
      reduceMotion != oldWidget.reduceMotion ||
      reduceTransparency != oldWidget.reduceTransparency ||
      inactive != oldWidget.inactive ||
      fullScreen != oldWidget.fullScreen;
}
