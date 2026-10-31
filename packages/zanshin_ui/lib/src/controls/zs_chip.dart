// SPDX-License-Identifier: MIT

import 'dart:ui' show PathMetric;

import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/zs_appearance.dart';
import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../design/zs_type.dart';
import '../icons/zanshin_icon.dart';
import '../zs_strings.dart';
import 'zs_control.dart';
import 'zs_control_core.dart';
import 'zs_control_text.dart';
import 'zs_focus_ring.dart';
import 'zs_lerp_builder.dart';

/// A chip's kind (DS components/controls/Chip.d.ts).
enum ZsChipKind {
  /// On/off ("Aa", match case): on is `--accent-soft` with `--accent-text`.
  toggle,

  /// The "~" negation: on is red, because it removes matches.
  not,

  /// A value with its own ✕.
  filter,

  /// A dashed "+ …" pill that adds a rule.
  add,
}

/// A chip's size (DS components/controls/Chip.d.ts).
enum ZsChipSize {
  /// 26 (`--control-sm`), radius `--radius-chip`, padding 0 10.
  md,

  /// 22 (`--control-xs`), radius `--radius-sm`, padding 0 8, `--fs-id`.
  sm,
}

typedef _ChipLook = ({Color fill, Color text, Color edge});

_ChipLook _lerpChip(_ChipLook a, _ChipLook b, double t) => (
  fill: Color.lerp(a.fill, b.fill, t)!,
  text: Color.lerp(a.text, b.text, t)!,
  edge: Color.lerp(a.edge, b.edge, t)!,
);

const _clear = Color(0x00000000);

/// A small pressable token for rule building and filters (DS components/controls/Chip.{d.ts,jsx,prompt.md};
/// controls.css:69-89): 26 (sm 22), padding 0 10, gap 5, radius `--radius-chip`, 500 `--fs-md` (mono `--fs-id`) in
/// `--text-muted`.
///
/// Neutral: `--fl-hover` → hover `--fl-on` → pressed `--fl-press`, the label `--text` from hover on. On states are
/// tinted: toggle `--accent-soft` with `--accent-text` → `--accent-soft-hi` → `--accent-ring`; not `--rem-bg` with
/// `--rem` → `--rem-bg-hover` → `--rem-bg-press`; on hover and press the label turns `--text`. Add: a dashed
/// `--border-strong` pill, padding 0 10 0 8 with a `+`, turning solid with `--fl-hover` (pressed `--fl-on`). Filter:
/// `--fl-on`, `--text`, padding 0 3 0 9, gap 4, the value at most 220 wide, and a 20 px ✕ (radius `--radius-tag`,
/// `--text-dim` → hover `--fl-on` / `--text`, pressed `--fl-press`). Under increased contrast every chip but add has a
/// 1 px `--border-strong` edge, a toggle that is on an `--accent-line` one (DS tokens/contrast.css:23, :26).
///
/// A Tab stop each (the ring outside, the ✕'s inside); Space / ↩ toggle; the filter chip's ✕ is its own Tab stop and
/// Delete / Backspace on the chip remove it. VoiceOver: toggle and not are buttons with a toggled state; filter
/// reads its value, its ✕ "Remove ‹label›".
class ZsChip extends StatelessWidget implements ZsControl {
  /// A chip labelled [label].
  const ZsChip({
    required this.label,
    this.kind = ZsChipKind.toggle,
    this.on = false,
    this.onChanged,
    this.onPressed,
    this.onRemove,
    this.mono = false,
    this.icon,
    this.size = ZsChipSize.md,
    this.statesController,
    this.identifier,
    super.key,
  });

  /// The chip's text.
  final String label;

  /// Toggle, not, filter or add.
  final ZsChipKind kind;

  /// Whether a toggle or not chip is on.
  final bool on;

  /// A toggle or not chip's new state; null disables it.
  final ValueChanged<bool>? onChanged;

  /// An add chip's action.
  final VoidCallback? onPressed;

  /// A filter chip's ✕, and Delete / Backspace on it.
  final VoidCallback? onRemove;

  /// Whether the label is JetBrains Mono.
  final bool mono;

  /// A `ZI` glyph before the label (sm).
  final String? icon;

  /// md or sm.
  final ZsChipSize size;

  /// A states controller; the catalogue forces states through it.
  final WidgetStatesController? statesController;

  @override
  final String? identifier;

  /// A filter chip's value is at most this wide (DS components/controls/controls.css:85).
  static const double _maxLabel = 220;

  bool get _toggle => kind == ZsChipKind.toggle || kind == ZsChipKind.not;

  _ChipLook _look(ZsColors c, ZsControlStatus s, {required bool contrast}) {
    final bool hover = s.hovered;
    final bool press = s.pressed;
    final Color edge = contrast && kind != ZsChipKind.add
        ? (kind == ZsChipKind.toggle && on ? c.accentLine : c.borderStrong)
        : _clear;
    if (kind == ZsChipKind.toggle && on) {
      return (
        fill: press ? c.accentRing : (hover ? c.accentSoftHi : c.accentSoft),
        text: hover || press ? c.text : c.accentText,
        edge: edge,
      );
    }
    if (kind == ZsChipKind.not && on) {
      return (
        fill: press ? c.remBgPress : (hover ? c.remBgHover : c.remBg),
        text: hover || press ? c.text : c.rem,
        edge: edge,
      );
    }
    if (kind == ZsChipKind.add) {
      return (
        fill: press ? c.flOn : (hover ? c.flHover : _clear),
        text: hover || press ? c.text : c.textMuted,
        edge: c.borderStrong,
      );
    }
    if (kind == ZsChipKind.filter) {
      return (fill: c.flOn, text: c.text, edge: edge);
    }
    return (
      fill: press ? c.flPress : (hover ? c.flOn : c.flHover),
      text: hover || press ? c.text : c.textMuted,
      edge: edge,
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = ZsMetrics.of(context);
    final small = size == ZsChipSize.sm;
    final double radius = kind == ZsChipKind.add ? metrics.radiusPill : (small ? metrics.radiusSm : metrics.radiusChip);
    final VoidCallback? activate = switch (kind) {
      ZsChipKind.toggle || ZsChipKind.not => onChanged == null ? null : () => onChanged!(!on),
      ZsChipKind.add => onPressed,
      ZsChipKind.filter => null,
    };
    final VoidCallback? remove = onRemove;
    return ZsControlCore(
      identifier: identifier,
      statesController: statesController,
      onActivate: activate,
      enabled: kind == ZsChipKind.filter || activate != null,
      selected: _toggle && on,
      activateOnKeys: kind != ZsChipKind.filter,
      shortcuts: kind == ZsChipKind.filter && remove != null
          ? <ShortcutActivator, Intent>{
              const SingleActivator(LogicalKeyboardKey.backspace): VoidCallbackIntent(remove),
              const SingleActivator(LogicalKeyboardKey.delete): VoidCallbackIntent(remove),
            }
          : null,
      actions: kind == ZsChipKind.filter ? <Type, Action<Intent>>{VoidCallbackIntent: VoidCallbackAction()} : null,
      semantics: SemanticsProperties(
        button: kind == ZsChipKind.filter ? null : true,
        toggled: _toggle ? on : null,
        label: label,
      ),
      excludeChildSemantics: kind != ZsChipKind.filter,
      ring: ZsRingPlacement.outside,
      ringRadius: radius,
      builder: (context, status) {
        final ZsColors colors = ZsColors.of(context);
        final ZsMotion motion = ZsMotion.of(context);
        final bool contrast = ZsAppearance.of(context).increasedContrast;
        final bool dashed = kind == ZsChipKind.add && !status.hovered && !status.pressed;
        final TextStyle style = mono
            ? zsMono(ZsType.fsId)
            : zsSans(small ? ZsType.fsId : ZsType.fsMd, weight: FontWeight.w500);
        final EdgeInsets padding = switch (kind) {
          ZsChipKind.filter => const EdgeInsets.fromLTRB(9, 0, 3, 0),
          ZsChipKind.add => const EdgeInsets.fromLTRB(8, 0, 10, 0),
          _ => EdgeInsets.symmetric(horizontal: small ? 8 : 10),
        };
        final String? glyph = kind == ZsChipKind.add ? ZI.plus : icon;
        return ZsLerpBuilder<_ChipLook>(
          value: _look(colors, status, contrast: contrast),
          lerp: _lerpChip,
          duration: status.pressed ? motion.durInstant : motion.durHover,
          curve: motion.easeState,
          builder: (context, look, _) => CustomPaint(
            painter: _ChipPainter(look: look, radius: radius, dashed: dashed),
            child: SizedBox(
              height: small ? metrics.controlXs : metrics.controlSm,
              child: Padding(
                padding: padding,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: kind == ZsChipKind.filter ? 4 : 5,
                  children: <Widget>[
                    if (glyph != null)
                      ZanshinIcon(
                        glyph,
                        size: kind == ZsChipKind.add ? ZsIconSize.xs : ZsIconSize.sm,
                        color: look.text,
                      ),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: kind == ZsChipKind.filter ? _maxLabel : double.infinity),
                      child: ExcludeSemantics(
                        child: Text(
                          label,
                          style: style.copyWith(color: look.text),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    if (kind == ZsChipKind.filter) _RemoveButton(label: label, onPressed: remove),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ChipPainter extends CustomPainter {
  _ChipPainter({required this.look, required this.radius, required this.dashed});

  final _ChipLook look;
  final double radius;
  final bool dashed;

  /// A 1 px dashed border's dash and gap.
  static const double _dash = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius.clamp(0, size.height / 2)));
    canvas.drawRRect(rrect, Paint()..color = look.fill);
    if (look.edge.a == 0) {
      return;
    }
    if (!dashed) {
      canvas.drawDRRect(rrect, rrect.deflate(1), Paint()..color = look.edge);
      return;
    }
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = look.edge;
    for (final PathMetric metric in (Path()..addRRect(rrect.deflate(.5))).computeMetrics()) {
      for (double d = 0; d < metric.length; d += _dash * 2) {
        canvas.drawPath(metric.extractPath(d, d + _dash), line);
      }
    }
  }

  @override
  bool shouldRepaint(_ChipPainter oldDelegate) =>
      oldDelegate.look != look || oldDelegate.radius != radius || oldDelegate.dashed != dashed;
}

/// The filter chip's ✕ (DS components/controls/controls.css:86-88): 20 px, radius `--radius-tag`, an xs close mark.
class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  /// `width:20px;height:20px` (DS components/controls/controls.css:86).
  static const double _side = 20;

  @override
  Widget build(BuildContext context) {
    final double radius = ZsMetrics.of(context).radiusTag;
    return ZsControlCore(
      onActivate: onPressed,
      enabled: onPressed != null,
      semantics: SemanticsProperties(button: true, label: zsStrings(context).chipRemove(label)),
      ring: ZsRingPlacement.inside,
      ringRadius: radius,
      builder: (context, status) {
        final ZsColors colors = ZsColors.of(context);
        final ZsMotion motion = ZsMotion.of(context);
        final bool lit = status.hovered || status.pressed;
        return ZsLerpBuilder<(Color, Color)>(
          value: (
            status.pressed ? colors.flPress : (status.hovered ? colors.flOn : _clear),
            lit ? colors.text : colors.textDim,
          ),
          lerp: (a, b, t) => (Color.lerp(a.$1, b.$1, t)!, Color.lerp(a.$2, b.$2, t)!),
          duration: status.pressed ? motion.durInstant : motion.durHover,
          curve: motion.easeState,
          builder: (context, look, _) => DecoratedBox(
            decoration: BoxDecoration(color: look.$1, borderRadius: BorderRadius.circular(radius)),
            child: SizedBox.square(
              dimension: _side,
              child: Center(
                child: ZanshinIcon(ZI.close, size: ZsIconSize.xs, color: look.$2),
              ),
            ),
          ),
        );
      },
    );
  }
}
