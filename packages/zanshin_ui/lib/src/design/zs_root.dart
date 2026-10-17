// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show AnimatedTheme, ThemeData;
import 'package:zanshin_shell/zanshin_shell.dart' show ScrollerStyle, ShellTheme;

import 'zs_app_theme.dart';
import 'zs_appearance.dart';
import 'zs_colors.dart';
import 'zs_type.dart';

/// The root scope of every window: resolves the effective [ZsAppearance] and installs the ambient defaults.
///
/// Below it sit the appearance scope, the token theme ([ZsAppTheme.build], with `ZsColors` and `ZsElevation`),
/// animated so a theme or accent-family switch fades through the extensions' `lerp` (a colour fade, so Reduce
/// motion keeps it), a `MediaQuery` whose `disableAnimations` and `highContrast` are the appearance's reduce motion
/// and increased contrast (Flutter's macOS embedder reports neither), the body role in `--text` as the default text
/// style, `--text` as the icon colour, the text selection and a scroll configuration without Material's glow or
/// stretch. Without it a `MaterialApp` child falls back to the 48 px
/// debug text style. A [ZsAppearanceOverride] above it replaces parts of [appearance].
///
/// Under the appearance scope it installs [ZsShellScope] with the shell's last report, which the scroll area reads
/// for the scroller style and the track-click behaviour (Story 11.11). An inner root without a [shellTheme] keeps the
/// outer one's.
class ZsRoot extends StatelessWidget {
  /// Installs the token scope for [appearance] above [child].
  const ZsRoot({required this.appearance, required this.child, this.shellTheme, super.key});

  /// The appearance the window shows, before any [ZsAppearanceOverride].
  final ZsAppearance appearance;

  /// The shell's last report, for the text-selection colours and [ZsShellScope]; null until the platform answered
  /// (or without one), and then the enclosing root's report applies.
  final ShellTheme? shellTheme;

  /// The window's content.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ZsAppearance effective = ZsAppearanceOverride.maybeOf(context)?.applyTo(appearance) ?? appearance;
    final ThemeData theme = ZsAppTheme.build(effective);
    final ZsColors colors = theme.extension<ZsColors>() ?? ZsColors.resolve(effective);
    final MediaQueryData media = MediaQuery.maybeOf(context) ?? MediaQueryData.fromView(View.of(context));
    final ShellTheme? shell = shellTheme ?? ZsShellScope.maybeOf(context);
    return ZsAppearanceScope(
      appearance: effective,
      child: ZsShellScope(
        shellTheme: shell,
        child: AnimatedTheme(
          data: theme,
          child: MediaQuery(
            data: media.copyWith(disableAnimations: effective.reduceMotion, highContrast: effective.increasedContrast),
            child: DefaultTextStyle(
              style: ZsType.body.copyWith(color: colors.text),
              child: IconTheme(
                data: IconThemeData(color: colors.text),
                child: DefaultSelectionStyle(
                  selectionColor: _selectionColor(effective, colors, shell),
                  cursorColor: colors.accentLine,
                  child: ScrollConfiguration(behavior: const _ZsScrollBehavior(), child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The macOS highlight in the appearance that matches the theme (night → darkAqua, paper → aqua), the unemphasized
  /// one in an inactive window; `--accent-select` / `--select-inactive` without a system value (DS readme.md:175-177).
  Color _selectionColor(ZsAppearance appearance, ZsColors colors, ShellTheme? shell) {
    final night = appearance.theme == ZsTheme.night;
    if (appearance.inactive) {
      final Color? system = night
          ? shell?.unemphasizedSelectedTextBackgroundDark
          : shell?.unemphasizedSelectedTextBackgroundLight;
      return system ?? colors.selectInactive;
    }
    final Color? system = night ? shell?.selectedTextBackgroundDark : shell?.selectedTextBackgroundLight;
    return system ?? colors.accentSelect;
  }
}

/// Provides the shell's last report below a [ZsRoot]: the scroll area reads `ShellTheme.scrollerStyle` and
/// `ShellTheme.jumpToClickedSpot` from it at the moment it needs them.
///
/// Claude's proposal (Story 11.11): a scope of its own, so the controls never reach for the platform channel.
class ZsShellScope extends InheritedWidget {
  /// Provides [shellTheme] to [child].
  const ZsShellScope({required this.shellTheme, required super.child, super.key});

  /// The shell's last report, or null until the platform answered (or without one).
  final ShellTheme? shellTheme;

  /// The nearest report, or null.
  static ShellTheme? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ZsShellScope>()?.shellTheme;

  /// Whether scroll bars always show: "Show scroll bars: Always", the legacy scroller style.
  static bool alwaysShowsScrollBars(BuildContext context) => maybeOf(context)?.scrollerStyle == ScrollerStyle.legacy;

  /// Whether a press in a scroll bar's track jumps to the spot clicked (`AppleScrollerPagingBehavior`).
  static bool jumpsToClickedSpot(BuildContext context) => maybeOf(context)?.jumpToClickedSpot ?? false;

  @override
  bool updateShouldNotify(ZsShellScope oldWidget) => shellTheme != oldWidget.shellTheme;
}

/// The widgets layer's scrolling without an overscroll indicator: no Material glow or stretch.
class _ZsScrollBehavior extends ScrollBehavior {
  const _ZsScrollBehavior();

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}
