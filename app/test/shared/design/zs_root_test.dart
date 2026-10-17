// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zanshin/src/shared/design/zs_appearance.dart';
import 'package:zanshin/src/shared/design/zs_colors.dart';
import 'package:zanshin/src/shared/design/zs_elevation.dart';
import 'package:zanshin/src/shared/design/zs_metrics.dart';
import 'package:zanshin/src/shared/design/zs_motion.dart';
import 'package:zanshin/src/shared/design/zs_root.dart';
import 'package:zanshin/src/shared/design/zs_type.dart';
import 'package:zanshin_shell/zanshin_shell.dart' show ShellTheme;

const _shell = ShellTheme(
  brightness: Brightness.dark,
  accentColor: Color(0xFF007AFF),
  selectedTextBackgroundDark: Color(0xFF3F638B),
  selectedTextBackgroundLight: Color(0xFFB3D7FF),
  unemphasizedSelectedTextBackgroundDark: Color(0xFF464646),
  unemphasizedSelectedTextBackgroundLight: Color(0xFFDCDCDC),
);

/// Pumps [root] (with whatever sits above it) and returns a context below the root.
Future<BuildContext> _probe(WidgetTester tester, Widget Function(Widget probe) root) async {
  late BuildContext probe;
  await tester.pumpWidget(
    root(
      Builder(
        builder: (context) {
          probe = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return probe;
}

void main() {
  testWidgets('an appearance override reaches the extensions and the reduce-motion flag without the native plugin', (
    tester,
  ) async {
    final BuildContext probe = await _probe(
      tester,
      (child) => ZsAppearanceOverride(
        theme: ZsTheme.paper,
        family: ZsAccentFamily.graphite,
        increasedContrast: true,
        reduceMotion: true,
        child: ZsRoot(appearance: const ZsAppearance(), child: child),
      ),
    );
    const expected = ZsAppearance(
      theme: ZsTheme.paper,
      family: ZsAccentFamily.graphite,
      increasedContrast: true,
      reduceMotion: true,
    );
    expect(ZsAppearance.of(probe), expected);
    expect(Theme.of(probe).extension<ZsColors>(), ZsColors.resolve(expected));
    expect(Theme.of(probe).extension<ZsElevation>(), ZsElevation.resolve(expected));
    expect(ZsColors.of(probe).accent, const Color(0xFF636363), reason: 'Graphite on paper');
    expect(ZsColors.of(probe).border, const Color(0xFF8F877F), reason: 'paper under increased contrast');
    expect(Theme.of(probe).brightness, Brightness.light);
    expect(MediaQuery.disableAnimationsOf(probe), isTrue);
    expect(MediaQuery.highContrastOf(probe), isTrue);
    expect(ZsMotion.of(probe), ZsMotion.reduced);
    expect(ZsMetrics.of(probe).focusW, 3);
  });

  testWidgets('the root installs the ambient defaults instead of the debug text style', (tester) async {
    final BuildContext probe = await _probe(
      tester,
      (child) => MaterialApp(
        builder: (context, navigator) => ZsRoot(appearance: const ZsAppearance(), child: navigator!),
        home: child,
      ),
    );
    final TextStyle text = DefaultTextStyle.of(probe).style;
    expect(text.fontFamily, ZsType.sansFamily);
    expect(text.fontSize, 13);
    expect(text.height, 1.55);
    expect(text.color, ZsColors.night.text);
    expect(IconTheme.of(probe).color, ZsColors.night.text);
    expect(DefaultSelectionStyle.of(probe).cursorColor, ZsColors.night.accentLine);
    expect(MediaQuery.disableAnimationsOf(probe), isFalse);
    expect(MediaQuery.highContrastOf(probe), isFalse);
    expect(ScrollConfiguration.of(probe), isNot(isA<MaterialScrollBehavior>()));
  });

  testWidgets('the selection takes the shell colour of the theme, and the unemphasized one when inactive', (
    tester,
  ) async {
    Future<Color?> selection(ZsAppearance appearance, {ShellTheme? shell}) async {
      final BuildContext probe = await _probe(
        tester,
        (child) => ZsRoot(appearance: appearance, shellTheme: shell, child: child),
      );
      return DefaultSelectionStyle.of(probe).selectionColor;
    }

    expect(await selection(const ZsAppearance(), shell: _shell), const Color(0xFF3F638B));
    expect(await selection(const ZsAppearance(theme: ZsTheme.paper), shell: _shell), const Color(0xFFB3D7FF));
    expect(await selection(const ZsAppearance(inactive: true), shell: _shell), const Color(0xFF464646));
    expect(
      await selection(const ZsAppearance(theme: ZsTheme.paper, inactive: true), shell: _shell),
      const Color(0xFFDCDCDC),
    );
  });

  testWidgets('without a shell colour the selection falls back to --accent-select and --select-inactive', (
    tester,
  ) async {
    Future<Color?> selection(ZsAppearance appearance) async {
      final BuildContext probe = await _probe(tester, (child) => ZsRoot(appearance: appearance, child: child));
      return DefaultSelectionStyle.of(probe).selectionColor;
    }

    expect(await selection(const ZsAppearance()), ZsColors.night.accentSelect);
    expect(
      await selection(const ZsAppearance(family: ZsAccentFamily.blue)),
      const Color.fromRGBO(103, 175, 253, 0.34),
    );
    expect(await selection(const ZsAppearance(inactive: true)), ZsColors.night.selectInactive);
    expect(await selection(const ZsAppearance(theme: ZsTheme.paper, inactive: true)), ZsColors.paper.selectInactive);
  });
}
