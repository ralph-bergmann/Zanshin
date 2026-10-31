// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../zs_strings.dart';
import 'zs_control.dart';
import 'zs_control_core.dart';
import 'zs_focus_ring.dart';
import 'zs_lerp_builder.dart';

/// A link, one of two kinds (DS components/controls/Link.{d.ts,jsx,prompt.md}; controls.css:91-97; base.css:14-17):
/// inline — `--accent-live-text`, the live copy, so it keeps its colour in an inactive window; a 1 px underline 2 px
/// below on hover; `--text` while pressed — or [quiet] — `--text-dim` → `--text`, never underlined. [external] adds
/// " ↗". The text takes the surrounding type; the colour fades on `--dur-hover`.
///
/// Focus is the ring with radius `--radius-kbd`; the cursor is the arrow (Zanshin opens no href in a browser tab of
/// its own). A Tab stop; ↩ and Space follow it. VoiceOver: a link named [label], "opens in browser" when external.
class ZsLink extends StatelessWidget implements ZsControl {
  /// A link reading [label].
  const ZsLink({
    required this.label,
    this.onPressed,
    this.quiet = false,
    this.external = false,
    this.statesController,
    this.identifier,
    super.key,
  });

  /// The link's text.
  final String label;

  /// Runs on activation; null disables the link.
  final VoidCallback? onPressed;

  /// Whether it is the quiet kind (footers, utilities).
  final bool quiet;

  /// Whether it opens outside Zanshin.
  final bool external;

  /// A states controller; the catalogue forces states through it.
  final WidgetStatesController? statesController;

  @override
  final String? identifier;

  /// `text-underline-offset:2px` (DS components/base.css:16).
  static const double _underlineOffset = 2;

  @override
  Widget build(BuildContext context) => ZsControlCore(
    identifier: identifier,
    statesController: statesController,
    onActivate: onPressed,
    enabled: onPressed != null,
    semantics: SemanticsProperties(link: true, label: external ? zsStrings(context).linkOpensInBrowser(label) : label),
    ring: ZsRingPlacement.outside,
    ringRadius: ZsMetrics.of(context).radiusKbd,
    builder: (context, status) {
      final ZsColors colors = ZsColors.of(context);
      final ZsMotion motion = ZsMotion.of(context);
      final Color rest = quiet ? colors.textDim : colors.accentLiveText;
      final Color target = status.pressed || (quiet && status.hovered) ? colors.text : rest;
      final bool underline = !quiet && status.hovered;
      return ZsLerpBuilder<Color>(
        value: target,
        lerp: (a, b, t) => Color.lerp(a, b, t)!,
        duration: status.pressed ? motion.durInstant : motion.durHover,
        curve: motion.easeState,
        builder: (context, color, _) {
          final TextStyle style = DefaultTextStyle.of(context).style.copyWith(color: color);
          return CustomPaint(
            foregroundPainter: underline ? _UnderlinePainter(color: color, offset: _underlineOffset) : null,
            child: Text(external ? '$label ↗' : label, style: style, softWrap: false),
          );
        },
      );
    },
  );
}

/// A 1 px underline [offset] below the text's baseline box (`text-decoration-thickness:1px`).
class _UnderlinePainter extends CustomPainter {
  _UnderlinePainter({required this.color, required this.offset});

  final Color color;
  final double offset;

  @override
  void paint(Canvas canvas, Size size) {
    final double y = size.height - offset / 2;
    canvas.drawRect(Rect.fromLTWH(0, y - .5, size.width, 1), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_UnderlinePainter oldDelegate) => oldDelegate.color != color || oldDelegate.offset != offset;
}
