// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import 'shell_controller.dart';

/// The rail's hover preview of [item] (epics.md Story 11.3 item 5; DS components/surfaces/Callout.prompt.md;
/// surfaces.css:16-22): the callout on the one menu material with its arrow on the left, entering and leaving as
/// [ZsSurfaceMotion.callout].
///
/// Its header (padding 11 14 8, gap 8) holds the item's icon at md in `--text-muted`, the label 13/600 and the count
/// in mono `--fs-sm` `--text-dim` at the end; the body is the item's preview, 8 above the bottom. The preview is
/// hover-only and not announced (DS Callout.prompt.md:11): VoiceOver never reads it — the pinned panel is. The shell
/// places it (left 76, its arrow tip on the button's centre, 290 wide) and keeps it mounted for its exit.
class RailPreview extends StatelessWidget {
  /// The preview of [item]; [closing] while it leaves.
  const RailPreview({required this.item, required this.closing, super.key});

  /// The previewed item.
  final ShellRailItem item;

  /// Whether the preview is leaving.
  final bool closing;

  /// The header's padding, `padding:11px 14px 8px` (DS components/surfaces/surfaces.css:19).
  static const _header = EdgeInsets.fromLTRB(14, 11, 14, 8);

  /// The body's bottom padding, `padding:0 0 8px` (DS components/surfaces/surfaces.css:22).
  static const _body = EdgeInsets.only(bottom: 8);

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final String? count = item.count;
    return ExcludeSemantics(
      child: ZsSurfaceTransition(
        motion: ZsSurfaceMotion.callout,
        closing: closing,
        child: ZsMenuMaterial(
          arrow: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: _header,
                child: Row(
                  spacing: metrics.space2,
                  children: <Widget>[
                    ZanshinIcon(item.icon, size: ZsIconSize.md, color: colors.textMuted),
                    Expanded(
                      child: Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        // `font-size:var(--fs-base);font-weight:600` (DS components/surfaces/surfaces.css:19).
                        style: ZsType.body.copyWith(
                          fontSize: ZsType.fsBase,
                          fontWeight: FontWeight.w600,
                          fontVariations: const <FontVariation>[FontVariation.weight(600)],
                          height: ZsType.lhSnug,
                          color: colors.text,
                        ),
                      ),
                    ),
                    if (count != null)
                      // `font:var(--fs-sm) var(--font-mono)` in `--text-dim` (DS components/surfaces/surfaces.css:21).
                      Text(
                        count,
                        style: ZsType.id.copyWith(fontSize: ZsType.fsSm, color: colors.textDim),
                      ),
                  ],
                ),
              ),
              Flexible(
                child: Padding(padding: _body, child: item.preview),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
