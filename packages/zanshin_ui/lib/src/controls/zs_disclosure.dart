// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../design/zs_type.dart';
import '../icons/zanshin_icon.dart';
import 'zs_control.dart';
import 'zs_control_core.dart';
import 'zs_control_text.dart';
import 'zs_focus_ring.dart';
import 'zs_lerp_builder.dart';
import 'zs_text_rung.dart';

/// A disclosure row that opens a section (DS components/controls/Disclosure.{d.ts,jsx,prompt.md};
/// controls.css:99-109): a 30 px header, padding 0 8 0 6, gap 6, radius `--radius-md`, 600 `--fs-md` in
/// `--text-muted` — hover `--fl-hover` with `--text`, pressed `--fl-on` — with an sm chevron in `--text-dim` that turns
/// 90° on `--dur-expand` / `--ease-glide`, the label, and a mono [meta] in `--text-faint` at the end (stepping up a
/// rung on the fill). The body's height follows on `--dur-expand` / glide (it jumps under reduce motion) while its
/// opacity fades on `--dur-panel` / `--ease-state`; it is clipped while it moves, and a closed body is hidden from
/// VoiceOver.
///
/// The ring sits inside the header. Space / ↩ toggle, → opens, ← closes. VoiceOver: a button, expanded or collapsed.
/// [open] makes it controlled; otherwise it starts at [initiallyOpen].
class ZsDisclosure extends StatefulWidget implements ZsControl {
  /// A disclosure labelled [label] over [child].
  const ZsDisclosure({
    required this.label,
    required this.child,
    this.open,
    this.initiallyOpen = false,
    this.onToggle,
    this.meta,
    this.statesController,
    this.identifier,
    super.key,
  });

  /// The header's label.
  final String label;

  /// The section.
  final Widget child;

  /// Whether the section is open; null leaves it to the disclosure.
  final bool? open;

  /// The first state when [open] is null.
  final bool initiallyOpen;

  /// Called with the new state.
  final ValueChanged<bool>? onToggle;

  /// A count at the end of the header, mono.
  final String? meta;

  /// A states controller; the catalogue forces states through it.
  final WidgetStatesController? statesController;

  @override
  final String? identifier;

  /// `min-height:30px` (DS components/controls/controls.css:101).
  static const double _header = 30;

  @override
  State<ZsDisclosure> createState() => _ZsDisclosureState();
}

class _ZsDisclosureState extends State<ZsDisclosure> {
  late bool _own = widget.initiallyOpen;

  bool get _open => widget.open ?? _own;

  void _set(bool open) {
    if (open == _open) {
      return;
    }
    setState(() => _own = open);
    widget.onToggle?.call(open);
  }

  @override
  Widget build(BuildContext context) {
    final metrics = ZsMetrics.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final bool open = _open;
    final Widget header = ZsControlCore(
      identifier: widget.identifier,
      statesController: widget.statesController,
      onActivate: () => _set(!open),
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.arrowRight): VoidCallbackIntent(() => _set(true)),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): VoidCallbackIntent(() => _set(false)),
      },
      actions: <Type, Action<Intent>>{VoidCallbackIntent: VoidCallbackAction()},
      semantics: SemanticsProperties(button: true, expanded: open, label: widget.label, value: widget.meta),
      ring: ZsRingPlacement.inside,
      ringRadius: metrics.radiusMd,
      builder: (context, status) {
        final ZsColors colors = ZsColors.of(context);
        final rung = ZsTextRung.of(colors, hovered: status.hovered, raised: status.pressed);
        final bool lit = status.hovered || status.pressed;
        const clear = Color(0x00000000);
        final String? meta = widget.meta;
        return ZsLerpBuilder<(Color, Color)>(
          value: (
            status.pressed ? colors.flOn : (status.hovered ? colors.flHover : clear),
            lit ? colors.text : colors.textMuted,
          ),
          lerp: (a, b, t) => (Color.lerp(a.$1, b.$1, t)!, Color.lerp(a.$2, b.$2, t)!),
          duration: status.pressed ? motion.durInstant : motion.durHover,
          curve: motion.easeState,
          builder: (context, look, _) => DecoratedBox(
            decoration: BoxDecoration(color: look.$1, borderRadius: BorderRadius.circular(metrics.radiusMd)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: ZsDisclosure._header),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 0, 8, 0),
                child: Row(
                  spacing: 6,
                  children: <Widget>[
                    ZsLerpBuilder<double>(
                      value: open ? 1 : 0,
                      lerp: (a, b, t) => a + (b - a) * t,
                      duration: motion.durExpand,
                      curve: motion.easeGlide,
                      builder: (context, turn, child) => Transform.rotate(angle: turn * math.pi / 2, child: child),
                      child: ZanshinIcon(ZI.chevronRight, size: ZsIconSize.sm, color: colors.textDim),
                    ),
                    Expanded(
                      child: Text(
                        widget.label,
                        style: zsSans(
                          ZsType.fsMd,
                          weight: FontWeight.w600,
                          height: ZsType.lhSnug,
                        ).copyWith(color: look.$2),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (meta != null) Text(meta, style: zsMono(ZsType.fsSm).copyWith(color: rung.faint)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        header,
        ExcludeSemantics(
          excluding: !open,
          child: ZsLerpBuilder<double>(
            value: open ? 1 : 0,
            lerp: (a, b, t) => a + (b - a) * t,
            duration: motion.durPanel,
            curve: motion.easeState,
            builder: (context, opacity, child) => Opacity(opacity: opacity, child: child),
            child: ZsLerpBuilder<double>(
              value: open ? 1 : 0,
              lerp: (a, b, t) => a + (b - a) * t,
              duration: motion.durExpand,
              curve: motion.easeGlide,
              builder: (context, height, child) => ClipRect(
                child: Align(alignment: Alignment.topCenter, heightFactor: height, child: child),
              ),
              child: ExcludeFocus(excluding: !open, child: widget.child),
            ),
          ),
        ),
      ],
    );
  }
}
