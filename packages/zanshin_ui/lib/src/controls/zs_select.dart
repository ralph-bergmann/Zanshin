// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kPrimaryButton;
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
import 'zs_menu.dart';

/// One entry of a [ZsSelect]'s list.
sealed class ZsSelectEntry<T> {
  const ZsSelectEntry();
}

/// A value the select can show.
final class ZsSelectOption<T> extends ZsSelectEntry<T> {
  /// An option for [value] labelled [label].
  const ZsSelectOption({required this.value, required this.label, this.text, this.mono = false, this.enabled = true});

  /// The value.
  final T value;

  /// What the trigger and the row show.
  final String label;

  /// What typeahead matches, when it differs from [label].
  final String? text;

  /// Whether the label is JetBrains Mono.
  final bool mono;

  /// Whether it can be chosen; a disabled row shows at .4 and is skipped.
  final bool enabled;
}

/// A hairline between groups of options.
final class ZsSelectSeparator<T> extends ZsSelectEntry<T> {
  /// A separator.
  const ZsSelectSeparator();
}

/// A caps heading over a group of options.
final class ZsSelectHeader<T> extends ZsSelectEntry<T> {
  /// A heading reading [label].
  const ZsSelectHeader(this.label);

  /// The heading.
  final String label;
}

/// The last row, "Custom…": it calls `ZsSelect.onCustom` instead of choosing a value.
final class ZsSelectCustom<T> extends ZsSelectEntry<T> {
  /// A custom row labelled [label].
  const ZsSelectCustom({this.label = 'Custom…'});

  /// The row's label.
  final String label;
}

/// Where a select's list opens (DS components/forms/Select.d.ts).
enum ZsSelectPlacement {
  /// Over the trigger, the chosen row on it: picking a value (the macOS pop-up button).
  over,

  /// Below the trigger, its width: a pull-down that runs commands.
  below,
}

typedef _TriggerLook = ({Color fill, Color veil, Color border});

_TriggerLook _lerpTrigger(_TriggerLook a, _TriggerLook b, double t) => (
  fill: Color.lerp(a.fill, b.fill, t)!,
  veil: Color.lerp(a.veil, b.veil, t)!,
  border: Color.lerp(a.border, b.border, t)!,
);

/// The pop-up button for settings with a handful of fixed choices (DS components/forms/Select.{d.ts,jsx,prompt.md};
/// forms.css:111-119).
///
/// **Trigger:** 30 high, at least 170 wide, padding 0 5 0 10, gap 8, the field's well (`--field-bg`, a 1 px
/// `--fl-border`, hover and open `--border-strong`, pressed `--fl-hover` laid over it), radius `--radius-md`, the
/// value at `--fs-control` (mono: `--fs-md`), the double chevron sm `--text-dim`. Focus is the outside ring — it is a
/// button, not text entry.
///
/// **List:** the menu's rows with a radio check on the chosen one. Over the trigger (`Select.jsx:33-46`, `:74`): the
/// chosen row lies centred on the trigger, its text at the trigger's text x (left −29), at least the trigger + 40 and
/// at most 360 wide; at most the window − 16 high, scrolled so the chosen row stays at the trigger; then the whole
/// list shifts to stay 8 px inside the window on both axes. Below: 4 under the trigger, its width. It grows out of
/// the chosen row (`--dur-menu`, glide; only fades under reduce motion) and fades out on `--dur-exit`.
///
/// **Input:** a press opens it with the keyboard highlight on the chosen row (Space, ↩, ↑, ↓ too); press – drag –
/// release picks the row under the pointer in one gesture (after more than 4 px or 300 ms); a click on the open
/// trigger closes it (Claude's proposal, Story 11.11); then the menu's keys, typeahead on `text`; picking blinks the
/// row, refocuses the trigger and calls [onChanged]; Esc closes and refocuses the trigger; a click outside closes it
/// without refocusing. VoiceOver: a button named "‹label›: ‹value›", expanded while open; the list a menu of radio
/// rows.
class ZsSelect<T> extends StatefulWidget implements ZsControl {
  /// A select over [options] showing [value].
  const ZsSelect({
    required this.options,
    required this.value,
    required this.onChanged,
    this.label,
    this.mono = false,
    this.placement = ZsSelectPlacement.over,
    this.onCustom,
    this.disabledReason,
    this.focusNode,
    this.statesController,
    this.identifier,
    super.key,
  });

  /// The list's entries.
  final List<ZsSelectEntry<T>> options;

  /// The chosen value.
  final T value;

  /// Called with a newly chosen value; null disables the select.
  final ValueChanged<T>? onChanged;

  /// The setting's name.
  final String? label;

  /// Whether every value is JetBrains Mono (bookmarks, remotes).
  final bool mono;

  /// Over (pick a value) or below (a pull-down).
  final ZsSelectPlacement placement;

  /// Runs for the "Custom…" row.
  final VoidCallback? onCustom;

  /// Why the select is disabled.
  final String? disabledReason;

  /// The trigger's focus node.
  final FocusNode? focusNode;

  /// A states controller; the catalogue forces states through it.
  final WidgetStatesController? statesController;

  @override
  final String? identifier;

  /// `min-width:170px` (DS components/forms/forms.css:112).
  static const double _minWidth = 170;

  /// The list's extra width over the trigger, its widest, and its left offset (DS components/forms/Select.jsx:7-8,
  /// :45, :74).
  static const double _extraWidth = 40;
  static const double _maxWidth = 360;
  static const double _left = 29;

  /// The window margin, and the gap of a pull-down (DS components/forms/Select.jsx:8, :39).
  static const double _margin = 8;
  static const double _below = 4;

  /// A drag past this many pixels, or a press held this long, makes the release pick (DS
  /// components/forms/Select.jsx:54).
  static const double _dragSlop = 4;
  static const _holdPick = Duration(milliseconds: 300);

  /// The menu's row, gap, separator, header and inset heights, for the geometry before layout (DS
  /// components/menus/menus.css:6, :13-15, :33).
  static const double _row = 28;
  static const double _gap = 1;
  static const double _separator = 9;
  static const double _inset = 6;

  @override
  State<ZsSelect<T>> createState() => _ZsSelectState<T>();
}

class _ZsSelectState<T> extends State<ZsSelect<T>> {
  final _menu = MenuController();
  final _panel = GlobalKey<ZsMenuPanelState>();
  FocusNode? _ownFocus;
  var _rowKeys = <GlobalKey>[];
  var _closing = false;
  var _refocus = false;
  VoidCallback? _hide;

  /// The list's scroll position, new for every opening so its first offset brings the chosen row to the trigger.
  ScrollController? _scroll;
  var _openings = 0;
  var _scrollOpening = -1;
  PointerDownEvent? _press;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'ZsSelect'));

  bool get _enabled => widget.onChanged != null && widget.disabledReason == null;

  @override
  void dispose() {
    _scroll?.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  ScrollController _scrollFor(double offset) {
    if (_scrollOpening != _openings) {
      _scroll?.dispose();
      _scroll = ScrollController(initialScrollOffset: offset);
      _scrollOpening = _openings;
    }
    return _scroll!;
  }

  ZsSelectOption<T>? get _current {
    for (final ZsSelectEntry<T> entry in widget.options) {
      if (entry is ZsSelectOption<T> && entry.value == widget.value) {
        return entry;
      }
    }
    return null;
  }

  List<ZsMenuEntry> get _entries => <ZsMenuEntry>[
    for (final ZsSelectEntry<T> entry in widget.options)
      switch (entry) {
        ZsSelectOption<T>() => ZsMenuItem(
          label: entry.label,
          text: entry.text,
          mono: widget.mono || entry.mono,
          enabled: entry.enabled,
          checked: entry.value == widget.value,
          radio: true,
          onSelected: () {
            if (entry.value != widget.value) {
              widget.onChanged?.call(entry.value);
            }
          },
        ),
        ZsSelectSeparator<T>() => const ZsMenuSeparator(),
        ZsSelectHeader<T>(:final String label) => ZsMenuHeader(label),
        ZsSelectCustom<T>(:final String label) => ZsMenuItem(label: label, onSelected: widget.onCustom),
      },
  ];

  int get _chosenIndex =>
      widget.options.indexWhere((entry) => entry is ZsSelectOption<T> && entry.value == widget.value);

  /// The list's content height and the chosen row's top inside it, from the menu's fixed geometry.
  (double, double) _geometry() {
    double y = ZsSelect._inset;
    double rowTop = ZsSelect._inset;
    final int chosen = _chosenIndex;
    for (var i = 0; i < widget.options.length; i++) {
      if (i > 0) {
        y += ZsSelect._gap;
      }
      if (i == chosen) {
        rowTop = y;
      }
      y += switch (widget.options[i]) {
        ZsSelectOption<T>() || ZsSelectCustom<T>() => ZsSelect._row,
        ZsSelectSeparator<T>() => ZsSelect._separator,
        // The caps line (`--type-caps`, 10.5 × 1.2) with `padding:7px … 3px` (the first 3 on top).
        ZsSelectHeader<T>() => (i == 0 ? 3 : 7) + 3 + ZsType.capsLabel.fontSize! * ZsType.capsLabel.height!,
      };
    }
    return (y + ZsSelect._inset, rowTop);
  }

  void _open() {
    if (!_enabled || _menu.isOpen) {
      return;
    }
    _rowKeys = <GlobalKey>[for (var i = 0; i < widget.options.length; i++) GlobalKey()];
    _openings++;
    _menu.open();
  }

  void _close({required bool refocus}) {
    if (!_menu.isOpen) {
      return;
    }
    _refocus = refocus;
    _menu.close();
  }

  void _picked(ZsMenuItem item) {
    if (_focus.context?.mounted ?? false) {
      _focus.requestFocus();
    }
    item.onSelected?.call();
    _close(refocus: false);
  }

  void _pointerDown(PointerDownEvent event) {
    if (!_enabled || event.buttons & kPrimaryButton == 0) {
      return;
    }
    if (_menu.isOpen) {
      _close(refocus: false);
      return;
    }
    _press = event;
    _open();
  }

  void _pointerUp(PointerUpEvent event) {
    final PointerDownEvent? press = _press;
    _press = null;
    if (press == null || !_menu.isOpen) {
      return;
    }
    final bool moved =
        (event.position - press.position).distance > ZsSelect._dragSlop ||
        event.timeStamp - press.timeStamp > ZsSelect._holdPick;
    if (!moved) {
      return;
    }
    for (var i = 0; i < _rowKeys.length; i++) {
      final row = _rowKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (row != null && row.hasSize && (row.localToGlobal(Offset.zero) & row.size).contains(event.position)) {
        _panel.currentState?.activateEntry(i);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final metrics = ZsMetrics.of(context);
    final ZsSelectOption<T>? current = _current;
    final String? label = widget.label;
    final String valueText = current?.text ?? current?.label ?? '—';
    return RawMenuAnchor(
      controller: _menu,
      consumeOutsideTaps: true,
      onOpenRequested: (position, show) {
        _hide = null;
        setState(() => _closing = false);
        show();
      },
      onCloseRequested: (hide) {
        if (_closing) {
          return;
        }
        _hide = hide;
        setState(() => _closing = true);
      },
      onClose: () {
        if (_refocus && (_focus.context?.mounted ?? false)) {
          _focus.requestFocus();
        }
        _refocus = false;
        setState(() {});
      },
      overlayBuilder: _list,
      builder: (context, controller, child) => Listener(
        onPointerDown: _pointerDown,
        onPointerUp: _pointerUp,
        child: ZsControlCore(
          identifier: widget.identifier,
          focusNode: _focus,
          statesController: widget.statesController,
          onActivate: _open,
          activateOnTap: false,
          enabled: widget.onChanged != null,
          disabledReason: widget.disabledReason,
          shortcuts: <ShortcutActivator, Intent>{
            const SingleActivator(LogicalKeyboardKey.arrowDown): VoidCallbackIntent(_open),
            const SingleActivator(LogicalKeyboardKey.arrowUp): VoidCallbackIntent(_open),
          },
          actions: <Type, Action<Intent>>{VoidCallbackIntent: VoidCallbackAction()},
          semantics: SemanticsProperties(
            button: true,
            label: label == null ? valueText : '$label: $valueText',
            expanded: _menu.isOpen,
          ),
          ring: ZsRingPlacement.outside,
          ringRadius: metrics.radiusMd,
          builder: (context, status) => _trigger(context, status, current),
        ),
      ),
    );
  }

  Widget _trigger(BuildContext context, ZsControlStatus status, ZsSelectOption<T>? current) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final bool open = _menu.isOpen && !_closing;
    const clear = Color(0x00000000);
    final _TriggerLook look = (
      fill: colors.fieldBg,
      veil: status.pressed ? colors.flHover : clear,
      border: status.hovered || open ? colors.borderStrong : colors.flBorder,
    );
    final bool mono = widget.mono || (current?.mono ?? false);
    final TextStyle style = mono
        ? zsMono(ZsType.fsMd, height: ZsType.lhSnug).copyWith(color: colors.text)
        : zsSans(ZsType.fsControl, height: ZsType.lhSnug).copyWith(color: colors.text);
    return ZsLerpBuilder<_TriggerLook>(
      value: look,
      lerp: _lerpTrigger,
      duration: status.pressed ? motion.durInstant : motion.durHover,
      curve: motion.easeState,
      builder: (context, look, _) => CustomPaint(
        painter: _TriggerPainter(look: look, radius: metrics.radiusMd),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: ZsSelect._minWidth),
          child: SizedBox(
            height: metrics.controlMd,
            child: Padding(
              // `padding:0 5px 0 10px` inside the 1 px edge (DS components/forms/forms.css:112).
              padding: const EdgeInsets.fromLTRB(11, 0, 6, 0),
              // `justify-content:space-between`: the chevron keeps to the right edge (forms.css:112).
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                spacing: 8,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      current?.label ?? '—',
                      style: style,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ZanshinIcon(ZI.updown, size: ZsIconSize.sm, color: colors.textDim),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _list(BuildContext context, RawMenuOverlayInfo info) {
    final Rect trigger = info.anchorRect;
    final Size window = info.overlaySize;
    final over = widget.placement == ZsSelectPlacement.over;
    final (double content, double rowTop) = _geometry();
    final double maxHeight = math.max(0, window.height - 2 * ZsSelect._margin);
    final double height = math.min(content, maxHeight);
    double top;
    var scroll = 0.0;
    if (over) {
      top = trigger.top - rowTop + ((trigger.height - ZsSelect._row) / 2).roundToDouble() - 1;
      if (top < ZsSelect._margin) {
        final double under = ZsSelect._margin - top;
        top += under;
        if (content > maxHeight) {
          scroll = math.min(under, content - height);
        }
      }
      if (top + height > window.height - ZsSelect._margin) {
        top -= top + height - (window.height - ZsSelect._margin);
      }
    } else {
      top = trigger.bottom + ZsSelect._below;
      if (top + height > window.height - ZsSelect._margin) {
        top = math.max(ZsSelect._margin, window.height - ZsSelect._margin - height);
      }
    }
    final double minWidth = math.min(
      ZsSelect._maxWidth,
      over ? trigger.width + ZsSelect._extraWidth : trigger.width,
    );
    final double left = over ? trigger.left - ZsSelect._left : trigger.left;
    final int chosen = _chosenIndex;
    final double originY = over ? (rowTop - scroll + ZsSelect._row / 2) : 0;
    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _ListLayout(Offset(left, top)),
        child: TapRegion(
          groupId: info.tapRegionGroupId,
          // A root anchor closes only its submenus on an outside tap; the list closes itself, without refocusing.
          onTapOutside: (_) => _close(refocus: false),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: height),
            child: ZsMenuPanel(
              key: _panel,
              entries: _entries,
              rowKeys: _rowKeys,
              highlight: chosen >= 0 ? chosen : null,
              minWidth: minWidth,
              maxWidth: math.max(minWidth, ZsSelect._maxWidth),
              scrollController: _scrollFor(scroll),
              origin: over
                  ? Alignment(-1 + 2 * ZsSelect._left / minWidth, -1 + 2 * originY / math.max(1, height))
                  : Alignment.topLeft,
              closing: _closing,
              onClosed: () {
                final VoidCallback? hide = _hide;
                _hide = null;
                hide?.call();
              },
              onActivated: _picked,
              onDismiss: () => _close(refocus: true),
            ),
          ),
        ),
      ),
    );
  }
}

/// Places the list at its computed top left, shifted to stay 8 inside the window on both axes.
class _ListLayout extends SingleChildLayoutDelegate {
  _ListLayout(this.at);

  final Offset at;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const double m = ZsSelect._margin;
    return Offset(
      math.max(m, math.min(at.dx, size.width - m - childSize.width)),
      math.max(m, math.min(at.dy, size.height - m - childSize.height)),
    );
  }

  @override
  bool shouldRelayout(_ListLayout oldDelegate) => oldDelegate.at != at;
}

class _TriggerPainter extends CustomPainter {
  _TriggerPainter({required this.look, required this.radius});

  final _TriggerLook look;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    canvas.drawRRect(rrect, Paint()..color = look.fill);
    if (look.veil.a > 0) {
      canvas.drawRRect(rrect, Paint()..color = look.veil);
    }
    canvas.drawDRRect(rrect, rrect.deflate(1), Paint()..color = look.border);
  }

  @override
  bool shouldRepaint(_TriggerPainter oldDelegate) => oldDelegate.look != look || oldDelegate.radius != radius;
}
