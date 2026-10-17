// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/widgets.dart';

import '../design/zs_appearance.dart';
import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../design/zs_type.dart';
import '../icons/zanshin_icon.dart';
import 'zs_control.dart';
import 'zs_control_text.dart';
import 'zs_lerp_builder.dart';

/// The keyboard row of a field-attached list (DS readme.md:137-138; rule 4): focus stays in the field, ↑ ↓ move
/// the keyboard row, ↩ activates it. A `ZsTextField` or `ZsSearchField` given this controller routes ↑ ↓ Home End ↩
/// to it while it is [attached]; the first Esc detaches it.
///
/// ↑ ↓ wrap, as the menus do (Claude's proposal, Story 11.11); Home and End go to the first and the last enabled
/// row; disabled rows are skipped. 10.21 builds its lists on it.
class ZsFieldListController extends ChangeNotifier {
  var _count = 0;
  bool Function(int index) _enabled = _always;
  ValueChanged<int>? _onActivate;
  var _active = -1;
  var _attached = false;

  static bool _always(int index) => true;

  /// Whether a list is attached to the field.
  bool get attached => _attached;

  /// The keyboard row, or −1.
  int get active => _active;

  /// Attaches a list of [count] rows; [enabled] tells which can be the keyboard row, [onActivate] runs on ↩.
  /// [active] starts the keyboard row there (else on none).
  void attach({required int count, bool Function(int index)? enabled, ValueChanged<int>? onActivate, int active = -1}) {
    _attached = true;
    _count = count;
    _enabled = enabled ?? _always;
    _onActivate = onActivate;
    _active = active;
    notifyListeners();
  }

  /// Detaches the list: the field's keys are its own again.
  void detach() {
    if (!_attached) {
      return;
    }
    _attached = false;
    _active = -1;
    notifyListeners();
  }

  void _moveTo(int index) {
    if (index != _active) {
      _active = index;
      notifyListeners();
    }
  }

  int _step(int from, int direction) {
    for (var k = 1; k <= _count; k++) {
      final int j = ((from + direction * k) % _count + _count) % _count;
      if (_enabled(j)) {
        return j;
      }
    }
    // No row is enabled: stay where it was, or on none when it was on none.
    return from >= 0 && from < _count ? from : -1;
  }

  /// ↓: the next enabled row, wrapping.
  void next() {
    if (_count > 0) {
      _moveTo(_step(_active, 1));
    }
  }

  /// ↑: the previous enabled row, wrapping (from none, the last).
  void previous() {
    if (_count > 0) {
      _moveTo(_step(_active < 0 ? _count : _active, -1));
    }
  }

  /// Home: the first enabled row.
  void first() {
    if (_count > 0) {
      _moveTo(_step(-1, 1));
    }
  }

  /// End: the last enabled row.
  void last() {
    if (_count > 0) {
      _moveTo(_step(_count, -1));
    }
  }

  /// ↩: runs the keyboard row; false when there is none.
  bool activate() {
    if (_active < 0 || !_enabled(_active)) {
      return false;
    }
    _onActivate?.call(_active);
    return true;
  }
}

typedef _RowLook = ({Color fill, Color icon, Color edge});

_RowLook _lerpRow(_RowLook a, _RowLook b, double t) => (
  fill: Color.lerp(a.fill, b.fill, t)!,
  icon: Color.lerp(a.icon, b.icon, t)!,
  edge: Color.lerp(a.edge, b.edge, t)!,
);

/// A row of a field-attached list (DS readme.md:137-138; components/search/search.css:56-62): at least 34 high, a 20
/// px icon column, the content and an end column, gap 10, padding 0 10, radius `--radius-md`, `--fs-base` in
/// `--text-muted`.
///
/// The keyboard row ([active]) is `--accent-soft` with its icon in `--accent-text`, plus a 1 px `--accent-line` edge
/// under increased contrast (DS tokens/contrast.css:26); hover is `--fl-hover` and never moves the keyboard row;
/// pressed `--fl-on`. What the list [shown] is carries a check in `--accent-text`, never a fill. A [danger] row's
/// text and icon are `--rem`. It takes no focus — focus stays in the field.
class ZsFieldListRow extends StatefulWidget implements ZsControl {
  /// A row showing [child].
  const ZsFieldListRow({
    required this.child,
    this.active = false,
    this.shown = false,
    this.danger = false,
    this.icon,
    this.onPressed,
    this.semanticLabel,
    this.identifier,
    super.key,
  });

  /// The row's content.
  final Widget child;

  /// Whether this is the keyboard row.
  final bool active;

  /// Whether this is what the list shows: a check at the end.
  final bool shown;

  /// Whether the row is destructive.
  final bool danger;

  /// A `ZI` glyph in the icon column.
  final String? icon;

  /// Runs on a click.
  final VoidCallback? onPressed;

  /// What VoiceOver reads for the row.
  final String? semanticLabel;

  @override
  final String? identifier;

  /// `min-height:34px` and the icon column (DS components/search/search.css:56).
  static const double _minHeight = 34;
  static const double _iconColumn = 20;

  @override
  State<ZsFieldListRow> createState() => _ZsFieldListRowState();
}

class _ZsFieldListRowState extends State<ZsFieldListRow> {
  var _hovered = false;
  var _pressed = false;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final appearance = ZsAppearance.of(context);
    const clear = Color(0x00000000);
    final bool hover = _hovered && !appearance.inactive;
    final Color fill = widget.active ? colors.accentSoft : (_pressed ? colors.flOn : (hover ? colors.flHover : clear));
    final Color rest = widget.danger ? colors.rem : colors.textDim;
    final _RowLook target = (
      fill: fill,
      icon: widget.active && !widget.danger ? colors.accentText : rest,
      edge: widget.active && appearance.increasedContrast ? colors.accentLine : clear,
    );
    final String? glyph = widget.icon;
    final Color text = widget.danger ? colors.rem : colors.textMuted;
    return Semantics(
      container: true,
      identifier: widget.identifier,
      button: true,
      selected: widget.active,
      checked: widget.shown ? true : null,
      label: widget.semanticLabel,
      onTap: widget.onPressed,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Listener(
          onPointerDown: (event) {
            if (event.buttons & kPrimaryButton != 0) {
              setState(() => _pressed = true);
            }
          },
          onPointerUp: (_) => setState(() => _pressed = false),
          onPointerCancel: (_) => setState(() => _pressed = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: widget.onPressed,
            child: ZsLerpBuilder<_RowLook>(
              value: target,
              lerp: _lerpRow,
              duration: _pressed ? motion.durInstant : motion.durHover,
              curve: motion.easeState,
              builder: (context, look, _) => CustomPaint(
                painter: _RowPainter(look: look, radius: ZsMetrics.of(context).radiusMd),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: ZsFieldListRow._minHeight),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      spacing: 10,
                      children: <Widget>[
                        SizedBox(
                          width: ZsFieldListRow._iconColumn,
                          child: glyph == null
                              ? null
                              : Center(
                                  child: ZanshinIcon(glyph, size: ZsIconSize.md, color: look.icon),
                                ),
                        ),
                        Expanded(
                          child: DefaultTextStyle.merge(
                            style: zsSans(ZsType.fsBase, height: ZsType.lhSnug).copyWith(color: text),
                            child: widget.child,
                          ),
                        ),
                        if (widget.shown) ZanshinIcon(ZI.check, size: ZsIconSize.md, color: colors.accentText),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RowPainter extends CustomPainter {
  _RowPainter({required this.look, required this.radius});

  final _RowLook look;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    canvas.drawRRect(rrect, Paint()..color = look.fill);
    if (look.edge.a > 0) {
      canvas.drawDRRect(rrect, rrect.deflate(1), Paint()..color = look.edge);
    }
  }

  @override
  bool shouldRepaint(_RowPainter oldDelegate) => oldDelegate.look != look || oldDelegate.radius != radius;
}
