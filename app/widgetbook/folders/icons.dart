// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// The "Icons" folder: every DS glyph by name, at the six sizes and in the text ladder and the semantic colours.
final iconsFolder = WidgetbookFolder(
  name: 'Icons',
  children: <WidgetbookNode>[
    WidgetbookComponent(
      name: 'Glyphs',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(name: 'Sizes', builder: (context) => const _Glyphs(colours: false)),
        WidgetbookUseCase(name: 'Colours', builder: (context) => const _Glyphs(colours: true)),
      ],
    ),
  ],
);

class _Glyphs extends StatelessWidget {
  const _Glyphs({required this.colours});

  /// Whether each glyph shows in the colours (at md) rather than at the sizes.
  final bool colours;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final ladder = <Color>[
      colors.text,
      colors.textMuted,
      colors.textDim,
      colors.textFaint,
      colors.accentText,
      colors.rem,
      colors.add,
      colors.warn,
      colors.gold,
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: <Widget>[
          for (final String name in ZI.all)
            SizedBox(
              width: colours ? 220 : 180,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: colors.border),
                  borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusMd),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 8,
                    children: <Widget>[
                      Text(name, style: ZsType.meta.copyWith(color: colors.textDim)),
                      Row(
                        spacing: 8,
                        children: <Widget>[
                          if (colours)
                            for (final Color color in ladder) ZanshinIcon(name, size: ZsIconSize.md, color: color)
                          else
                            for (final ZsIconSize size in ZsIconSize.values) ZanshinIcon(name, size: size),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
