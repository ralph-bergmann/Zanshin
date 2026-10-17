// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show AccentSource;
import 'package:zanshin_shell/zanshin_shell.dart' show ScrollerStyle, ShellTheme;
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_root.dart';

const _shell = ShellTheme(
  brightness: Brightness.dark,
  accentColor: Color(0xFF0A84FF),
  appleAccentColor: 4,
  reduceMotion: true,
  reduceTransparency: true,
  increaseContrast: true,
  scrollerStyle: ScrollerStyle.legacy,
  jumpToClickedSpot: true,
);

void main() {
  group('ZsAppearance.fromShell', () {
    test('takes the family and the three accessibility flags from the shell', () {
      final appearance = ZsAppearance.fromShell(
        theme: ZsTheme.paper,
        accentSource: AccentSource.followMacOS,
        shell: _shell,
      );
      expect(appearance.theme, ZsTheme.paper);
      expect(appearance.family, ZsAccentFamily.blue);
      expect(appearance.increasedContrast, isTrue);
      expect(appearance.reduceMotion, isTrue);
      expect(appearance.reduceTransparency, isTrue);
      expect(appearance.inactive, isFalse);
    });

    test('without a shell: the moon and no flags', () {
      final appearance = ZsAppearance.fromShell(
        theme: ZsTheme.night,
        accentSource: AccentSource.followMacOS,
        shell: null,
      );
      expect(appearance, const ZsAppearance());
    });

    test('Zanshin as the accent source keeps the moon whatever macOS reports', () {
      expect(
        ZsAppearance.fromShell(theme: ZsTheme.night, accentSource: AccentSource.zanshin, shell: _shell).family,
        ZsAccentFamily.multicolor,
      );
    });
  });

  group('ZsShellScope', () {
    testWidgets('ZsRoot installs it; the scroller style and the paging behaviour read through it', (tester) async {
      late BuildContext inner;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ZsRoot(
            appearance: const ZsAppearance(),
            shellTheme: _shell,
            child: Builder(
              builder: (context) {
                inner = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(ZsShellScope.maybeOf(inner), _shell);
      expect(ZsShellScope.alwaysShowsScrollBars(inner), isTrue);
      expect(ZsShellScope.jumpsToClickedSpot(inner), isTrue);
    });

    testWidgets('without a shell: overlay bars and paging', (tester) async {
      late BuildContext inner;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ZsRoot(
            appearance: const ZsAppearance(),
            child: Builder(
              builder: (context) {
                inner = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(ZsShellScope.maybeOf(inner), isNull);
      expect(ZsShellScope.alwaysShowsScrollBars(inner), isFalse);
      expect(ZsShellScope.jumpsToClickedSpot(inner), isFalse);
    });

    testWidgets('an inner root without a shell keeps the outer one\'s report; its own report wins', (tester) async {
      late BuildContext single;
      late BuildContext nested;
      late BuildContext own;
      Widget probe(void Function(BuildContext) keep) => Builder(
        builder: (context) {
          keep(context);
          return const SizedBox();
        },
      );
      const other = ShellTheme(brightness: Brightness.light, accentColor: Color(0xFFFF453A), appleAccentColor: 0);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: <Widget>[
              ZsRoot(appearance: const ZsAppearance(), shellTheme: _shell, child: probe((c) => single = c)),
              ZsRoot(
                appearance: const ZsAppearance(),
                shellTheme: _shell,
                child: Column(
                  children: <Widget>[
                    ZsRoot(appearance: const ZsAppearance(), child: probe((c) => nested = c)),
                    ZsRoot(appearance: const ZsAppearance(), shellTheme: other, child: probe((c) => own = c)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      expect(ZsShellScope.maybeOf(nested), _shell);
      expect(ZsShellScope.alwaysShowsScrollBars(nested), isTrue);
      expect(ZsShellScope.jumpsToClickedSpot(nested), isTrue);
      expect(DefaultSelectionStyle.of(nested).selectionColor, DefaultSelectionStyle.of(single).selectionColor);
      expect(ZsShellScope.maybeOf(own), other);
      expect(ZsShellScope.jumpsToClickedSpot(own), isFalse);
    });
  });
}
