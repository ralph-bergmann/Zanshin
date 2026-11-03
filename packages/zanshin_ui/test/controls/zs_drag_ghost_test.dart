// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_drag_ghost.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/icons/zanshin_icon.dart';
import 'package:zanshin_ui/src/materials/zs_surface.dart';

import '../helpers/icon_registry.dart';
import '../helpers/zs_host.dart';

const _dot = Color(0xFF33AA55);

Widget _ghost(ZsDragGhost ghost, {ZsAppearance appearance = const ZsAppearance()}) =>
    zsHost(ghost, appearance: appearance, icons: true);

ZsSurface _surfaceAround(WidgetTester tester, String text) =>
    tester.widget<ZsSurface>(find.ancestor(of: find.text(text), matching: find.byType(ZsSurface)).first);

void main() {
  setUpIconRegistry();
  const ZsColors night = ZsColors.night;

  testWidgets('a project: the 34 px chip with its dot, at most 280 wide', (tester) async {
    await tester.pumpWidget(
      _ghost(const ZsDragGhost(kind: ZsDragGhostKind.project, label: 'dotfiles', dot: _dot, target: 'Into Backend')),
    );
    final ZsSurface chip = _surfaceAround(tester, 'dotfiles');
    expect(tester.getSize(find.byWidget(chip)).height, ZsDragGhost.height);
    expect(chip.fill, night.cardSolidHi);
    expect(chip.border, night.accentLine);
    expect(find.byType(ZanshinIcon), findsNothing);
    expect(
      find.byWidgetPredicate((w) => w is DecoratedBox && (w.decoration as BoxDecoration).color == _dot),
      findsOneWidget,
    );
    // Upright (Reduce motion), so the edges are not tilted.
    await tester.pumpWidget(
      _ghost(
        const ZsDragGhost(kind: ZsDragGhostKind.project, label: 'no dot'),
        appearance: const ZsAppearance(reduceMotion: true),
      ),
    );
    expect(
      tester.getTopLeft(find.text('no dot')).dx - tester.getTopLeft(find.byType(ZsSurface)).dx,
      ZsSurface.borderWidth + 12,
      reason: 'without a dot the label starts at the 12 px padding inside the border, no gap before it',
    );
    await tester.pumpWidget(_ghost(ZsDragGhost(kind: ZsDragGhostKind.project, label: 'x' * 200)));
    expect(tester.getSize(find.byType(ZsSurface)).width, lessThanOrEqualTo(ZsDragGhost.maxWidth));
  });

  testWidgets('a group: the folder glyph instead of a dot', (tester) async {
    await tester.pumpWidget(_ghost(const ZsDragGhost(kind: ZsDragGhostKind.group, label: 'Work', dot: _dot)));
    expect(tester.widget<ZanshinIcon>(find.byType(ZanshinIcon)).name, ZI.folder);
    expect(
      find.byWidgetPredicate((w) => w is DecoratedBox && (w.decoration as BoxDecoration).color == _dot),
      findsNothing,
    );
  });

  testWidgets('a target: --accent-line border and --text; a hint: --tooltip-border and --text-dim', (tester) async {
    await tester.pumpWidget(
      _ghost(const ZsDragGhost(kind: ZsDragGhostKind.project, label: 'a', target: 'To the top level', hint: 'h')),
    );
    expect(find.text('h'), findsNothing);
    expect(_surfaceAround(tester, 'To the top level').border, night.accentLine);
    expect(_surfaceAround(tester, 'To the top level').fill, night.tooltipBg);
    expect(tester.widget<Text>(find.text('To the top level')).style?.color, night.text);
    expect(
      tester.getTopLeft(find.text('To the top level')).dy - tester.getBottomLeft(find.text('a')).dy,
      greaterThan(8),
    );

    await tester.pumpWidget(
      _ghost(const ZsDragGhost(kind: ZsDragGhostKind.project, label: 'a', hint: 'Drop between rows or on a group')),
    );
    expect(_surfaceAround(tester, 'Drop between rows or on a group').border, night.tooltipBorder);
    expect(tester.widget<Text>(find.text('Drop between rows or on a group')).style?.color, night.textDim);
  });

  testWidgets('without a target or a hint there are no words', (tester) async {
    await tester.pumpWidget(_ghost(const ZsDragGhost(kind: ZsDragGhostKind.group, label: 'Work')));
    expect(find.byType(ZsSurface), findsOneWidget);
  });

  testWidgets('tilted −1.5° at full motion, upright under Reduce motion', (tester) async {
    Matrix4 tilt() => tester.widget<Transform>(find.byType(Transform).first).transform;
    await tester.pumpWidget(_ghost(const ZsDragGhost(kind: ZsDragGhostKind.group, label: 'Work')));
    expect(tilt(), isNot(Matrix4.identity()));
    expect(tilt(), Matrix4.rotationZ(ZsDragGhost.tilt));
    await tester.pumpWidget(
      _ghost(
        const ZsDragGhost(kind: ZsDragGhostKind.group, label: 'Work'),
        appearance: const ZsAppearance(reduceMotion: true),
      ),
    );
    expect(tilt(), Matrix4.identity());
  });

  testWidgets('a change (Story 10.10): @ badge, the id bold to its prefix and max(prefix, 8) long, the subject', (
    tester,
  ) async {
    await tester.pumpWidget(
      _ghost(
        const ZsDragGhost(
          kind: ZsDragGhostKind.change,
          label: 'Fix the parser',
          changeId: 'ovknlmrowxyzqpst',
          prefix: 3,
          workingCopy: true,
          command: 'jj rebase -s ovknlmro -o vruxwmqv',
        ),
      ),
    );
    expect(find.text('@'), findsOneWidget);
    expect(find.text('Fix the parser'), findsOneWidget);
    final RichText id = tester.widget<RichText>(
      find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'ovknlmro'),
    );
    TextSpan? bold;
    id.text.visitChildren((span) {
      if (span is TextSpan && span.text == 'ovk') {
        bold = span;
      }
      return bold == null;
    });
    expect(bold?.style?.fontWeight, FontWeight.w600);
    // The command words: mono, --accent-line border, --text.
    final Finder words = find.text('jj rebase -s ovknlmro -o vruxwmqv');
    expect(_surfaceAround(tester, 'jj rebase -s ovknlmro -o vruxwmqv').border, night.accentLine);
    expect(tester.widget<Text>(words).style?.fontFamily, contains('JetBrainsMono'));
    expect(tester.widget<Text>(words).style?.color, night.text);
  });

  testWidgets('a bookmark: the 28 px pill with the glyph and the mono name; a hint as words', (tester) async {
    await tester.pumpWidget(
      _ghost(const ZsDragGhost(kind: ZsDragGhostKind.bookmark, label: 'main', hint: 'Drop on the change it should')),
    );
    expect(tester.widget<ZanshinIcon>(find.byType(ZanshinIcon)).name, ZI.bookmark);
    expect(tester.getSize(find.byWidget(_surfaceAround(tester, 'main'))).height, ZsDragGhost.bookmarkHeight);
    expect(tester.widget<Text>(find.text('main')).style?.fontWeight, FontWeight.w600);
    expect(_surfaceAround(tester, 'Drop on the change it should').border, night.tooltipBorder);
  });

  testWidgets('a warning: a --warn sans line under the command, in the same words box; hidden with the words', (
    tester,
  ) async {
    const ghost = ZsDragGhost(
      kind: ZsDragGhostKind.bookmark,
      label: 'main',
      command: 'jj x',
      warning: 'Moves main back',
    );
    await tester.pumpWidget(_ghost(ghost));
    final Finder warning = find.text('Moves main back');
    expect(tester.widget<Text>(warning).style?.color, night.warn);
    expect(tester.widget<Text>(warning).style?.fontFamily, isNot(contains('JetBrainsMono')));
    expect(_surfaceAround(tester, 'Moves main back'), same(_surfaceAround(tester, 'jj x')));
    expect(tester.getTopLeft(warning).dy, greaterThanOrEqualTo(tester.getBottomLeft(find.text('jj x')).dy));
    await tester.pumpWidget(
      _ghost(
        const ZsDragGhost(
          kind: ZsDragGhostKind.bookmark,
          label: 'main',
          command: 'jj x',
          warning: 'Moves main back',
          hideWords: true,
        ),
      ),
    );
    expect(warning, findsNothing);
  });

  testWidgets('hideWords drops the words; muted fades the ghost to .3', (tester) async {
    await tester.pumpWidget(
      _ghost(const ZsDragGhost(kind: ZsDragGhostKind.bookmark, label: 'main', command: 'jj x', hideWords: true)),
    );
    expect(find.text('jj x'), findsNothing);
    expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 1);
    await tester.pumpWidget(_ghost(const ZsDragGhost(kind: ZsDragGhostKind.bookmark, label: 'main', muted: true)));
    expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, ZsDragGhost.mutedOpacity);
  });

  testWidgets('hidden from VoiceOver and takes no pointer', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_ghost(const ZsDragGhost(kind: ZsDragGhostKind.group, label: 'Work', hint: 'h')));
    expect(find.bySemanticsLabel('Work'), findsNothing);
    expect(find.bySemanticsLabel('h'), findsNothing);
    expect(find.byType(IgnorePointer), findsWidgets);
    handle.dispose();
  });
}
