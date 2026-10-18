// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:ui' show PathMetric;

import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Material, MaterialType, TextField;

import '../design/zs_appearance.dart';
import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../design/zs_type.dart';
import '../icons/zanshin_icon.dart';
import 'zs_control.dart';
import 'zs_control_core.dart';
import 'zs_control_text.dart';
import 'zs_field_list.dart';
import 'zs_focus_ring.dart';
import 'zs_kbd.dart';
import 'zs_lerp_builder.dart';
import 'zs_menu.dart';
import 'zs_text_rung.dart';
import 'zs_tooltip.dart';

/// A text controller that draws the selected glyphs in `--selection-text` (decision 16.10; DS readme.md:175-179),
/// as macOS draws them in `selectedTextColor`: every selected glyph — dim, faint and mono included — reads in
/// `--text` on the highlight.
///
/// It recolours only while the field may compose, that is while it has focus and is not read-only; a read-only text
/// keeps its colours (known debt, decision 16.10). An input method's composing range keeps Flutter's underline.
class ZsTextEditingController extends TextEditingController {
  /// A controller starting with [text].
  ZsTextEditingController({super.text});

  @override
  TextSpan buildTextSpan({required BuildContext context, required bool withComposing, TextStyle? style}) {
    final TextSelection selection = value.selection;
    final bool composing = value.isComposingRangeValid && !value.composing.isCollapsed;
    if (!withComposing || composing || !selection.isValid || selection.isCollapsed || selection.end > text.length) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final Color selected = ZsColors.of(context).selectionText;
    return TextSpan(
      style: style,
      children: <InlineSpan>[
        TextSpan(text: selection.textBefore(text)),
        TextSpan(
          text: selection.textInside(text),
          style: TextStyle(color: selected),
        ),
        TextSpan(text: selection.textAfter(text)),
      ],
    );
  }
}

/// A text field's size (DS components/forms/TextField.d.ts; forms.css:100-102).
enum ZsTextFieldSize {
  /// 30 high, `--fs-control`: settings.
  sm,

  /// 36 high, `--fs-base` semibold: the composer's summary.
  md,

  /// 36 high, `--fs-lg` semibold: the describe summary.
  lg,
}

typedef _WellLook = ({Color fill, Color border, Color halo});

_WellLook _lerpWell(_WellLook a, _WellLook b, double t) => (
  fill: Color.lerp(a.fill, b.fill, t)!,
  border: Color.lerp(a.border, b.border, t)!,
  halo: Color.lerp(a.halo, b.halo, t)!,
);

const _clear = Color(0x00000000);

/// Paints a field's well: its halo (`0 0 0 3px`), its fill and its 1 px border, solid or dashed.
class _WellPainter extends CustomPainter {
  _WellPainter({required this.look, required this.radius, required this.halo, this.dashed = false});

  final _WellLook look;
  final double radius;
  final double halo;
  final bool dashed;

  /// A 1 px dashed border's dash and gap.
  static const double _dash = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    if (look.halo.a > 0) {
      canvas.drawDRRect(rrect.inflate(halo), rrect, Paint()..color = look.halo);
    }
    canvas.drawRRect(rrect, Paint()..color = look.fill);
    if (look.border.a == 0) {
      return;
    }
    if (!dashed) {
      canvas.drawDRRect(rrect, rrect.deflate(1), Paint()..color = look.border);
      return;
    }
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = look.border;
    final outline = Path()..addRRect(rrect.deflate(.5));
    for (final PathMetric metric in outline.computeMetrics()) {
      for (double d = 0; d < metric.length; d += _dash * 2) {
        canvas.drawPath(metric.extractPath(d, d + _dash), line);
      }
    }
  }

  @override
  bool shouldRepaint(_WellPainter oldDelegate) =>
      oldDelegate.look != look ||
      oldDelegate.radius != radius ||
      oldDelegate.halo != halo ||
      oldDelegate.dashed != dashed;
}

/// Routes ↑ ↓ Home End ↩ to an attached field list and Esc to [onEscape]; true from [onEscape] handles the key.
KeyEventResult _fieldKeys(KeyEvent event, ZsFieldListController? list, bool Function() onEscape) {
  if (event is KeyUpEvent) {
    return KeyEventResult.ignored;
  }
  final LogicalKeyboardKey key = event.logicalKey;
  if (list != null && list.attached) {
    if (key == LogicalKeyboardKey.arrowDown) {
      list.next();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      list.previous();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      list.first();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      list.last();
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) && list.activate()) {
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      list.detach();
      return KeyEventResult.handled;
    }
  }
  if (key == LogicalKeyboardKey.escape && event is KeyDownEvent && onEscape()) {
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}

/// The text context menu (DS components/forms/TextField.prompt.md:11): a Zs menu at the pointer with Undo · Redo —
/// Cut · Copy · Paste — Select all, the shortcuts in the right column, no icons, each enabled per the field's state.
/// Focus stays in the field; the menu takes the pointer only.
///
/// Claude's proposal (Story 11.11): the text menu is built with the control library rather than left to later.
Widget _textContextMenu(BuildContext context, EditableTextState state, UndoHistoryController undo) {
  void run(VoidCallback action) {
    action();
    state.hideToolbar();
  }

  const SelectionChangedCause cause = SelectionChangedCause.toolbar;
  final String text = state.textEditingValue.text;
  final TextSelection selection = state.textEditingValue.selection;
  final entries = <ZsMenuEntry>[
    ZsMenuItem(
      label: 'Undo',
      shortcut: '⌘Z',
      enabled: !state.widget.readOnly && undo.value.canUndo,
      onSelected: () => run(undo.undo),
    ),
    ZsMenuItem(
      label: 'Redo',
      shortcut: '⇧⌘Z',
      enabled: !state.widget.readOnly && undo.value.canRedo,
      onSelected: () => run(undo.redo),
    ),
    const ZsMenuSeparator(),
    ZsMenuItem(
      label: 'Cut',
      shortcut: '⌘X',
      enabled: state.cutEnabled,
      onSelected: () => run(() => state.cutSelection(cause)),
    ),
    ZsMenuItem(
      label: 'Copy',
      shortcut: '⌘C',
      enabled: state.copyEnabled,
      onSelected: () => run(() => state.copySelection(cause)),
    ),
    ZsMenuItem(
      label: 'Paste',
      shortcut: '⌘V',
      enabled: state.pasteEnabled,
      onSelected: () => run(() => unawaited(state.pasteText(cause))),
    ),
    const ZsMenuSeparator(),
    ZsMenuItem(
      label: 'Select all',
      shortcut: '⌘A',
      // Flutter follows the native macOS text menu, which has no Select all (`selectAllEnabled` is false there); the
      // DS's menu has it, enabled while not everything is selected.
      enabled: text.isNotEmpty && !(selection.start == 0 && selection.end == text.length),
      onSelected: () => run(() => state.selectAll(cause)),
    ),
  ];
  // The selection overlay lays the menu out in global coordinates (the toolbar's follower undoes the field's
  // offset), as material's desktop toolbar relies on.
  return CustomSingleChildLayout(
    delegate: _AtPointLayout(state.contextMenuAnchors.primaryAnchor),
    child: TextFieldTapRegion(
      child: ZsMenuPanel(
        entries: entries,
        takeFocus: false,
        onActivated: (item) => item.onSelected?.call(),
        onDismiss: state.hideToolbar,
      ),
    ),
  );
}

/// Places a menu with its top left at a point, clamped 8 inside the overlay.
class _AtPointLayout extends SingleChildLayoutDelegate {
  _AtPointLayout(this.at);

  final Offset at;

  static const double _margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    at.dx.clamp(_margin, (size.width - _margin - childSize.width).clamp(_margin, double.infinity)),
    at.dy.clamp(_margin, (size.height - _margin - childSize.height).clamp(_margin, double.infinity)),
  );

  @override
  bool shouldRelayout(_AtPointLayout oldDelegate) => oldDelegate.at != at;
}

/// The inset text field (DS components/forms/TextField.{d.ts,jsx,prompt.md}; forms.css:91-109): material_ui's
/// `TextField` without a decoration inside a painted well — `--field-bg`, a 1 px `--fl-border`, radius `--radius-md`.
///
/// | state | edge | halo |
/// |---|---|---|
/// | rest | `--fl-border` | — |
/// | hover | `--border-strong` | — |
/// | focus (any focus — text entry is the exception to keyboard-only rings) | `--accent-line` | 3 px `--accent-ring` |
/// | error | `--error` | focused: `--error-ring` |
/// | read-only | dashed `--fl-border`, no fill, `--text-muted`, still selectable | — |
/// | inactive window | `--fl-border` | none, and no caret (DS tokens/inactive.css:19-22) |
///
/// Sizes: sm 30 / `--fs-control`, md 36 / `--fs-base` 600, lg 36 / `--fs-lg` 600, padding 0 10; [multiline] is the
/// details area (padding 8 10, `--fs-base`, line height 1.5, at least 62 high); [mono] sets JetBrains Mono at
/// `--fs-md`. The placeholder is `--text-faint`. An [error] message sits 5 below in `--fs-sm` `--rem` with the alert
/// mark. Colours fade on `--dur-hover`; nothing moves. The cursor is the I-beam, read-only included.
///
/// Selection: the macOS highlight from the window root, the selected glyphs in `--selection-text`
/// ([ZsTextEditingController]). The context menu is a Zs menu ([contextMenu]). With a [fieldList] attached, ↑ ↓
/// Home End ↩ go to the list and the first Esc detaches it.
class ZsTextField extends StatefulWidget implements ZsControl {
  /// A field editing [controller]'s text.
  const ZsTextField({
    this.controller,
    this.focusNode,
    this.size = ZsTextFieldSize.sm,
    this.multiline = false,
    this.mono = false,
    this.error,
    this.readOnly = false,
    this.placeholder,
    this.label,
    this.disabledReason,
    this.enabled = true,
    this.fieldList,
    this.contextMenu = true,
    this.onChanged,
    this.onSubmitted,
    this.statesController,
    this.identifier,
    super.key,
  });

  /// The text; the field keeps its own when null.
  final ZsTextEditingController? controller;

  /// The field's focus node; the field keeps its own when null.
  final FocusNode? focusNode;

  /// sm, md or lg.
  final ZsTextFieldSize size;

  /// Whether the field is the multi-line area.
  final bool multiline;

  /// Whether the text is JetBrains Mono (revsets, config values).
  final bool mono;

  /// The field is invalid; a non-empty message shows below it and is its description.
  final String? error;

  /// Whether the text can only be read and selected.
  final bool readOnly;

  /// The hint shown while the field is empty.
  final String? placeholder;

  /// The field's accessible name (its row's label); the [placeholder] when null.
  final String? label;

  /// Why the field is disabled.
  final String? disabledReason;

  /// Whether the field takes input.
  final bool enabled;

  /// The field-attached list its keys drive while attached.
  final ZsFieldListController? fieldList;

  /// Whether a secondary click opens the Zs text menu.
  final bool contextMenu;

  /// Called on every edit.
  final ValueChanged<String>? onChanged;

  /// Called on ↩ (single line).
  final ValueChanged<String>? onSubmitted;

  /// A states controller; the catalogue forces hover and focus through it (they add to the real ones).
  final WidgetStatesController? statesController;

  @override
  final String? identifier;

  /// The message line's gap and inset (DS components/forms/forms.css:106-107).
  static const double _messageGap = 5;

  @override
  State<ZsTextField> createState() => _ZsTextFieldState();
}

class _ZsTextFieldState extends State<ZsTextField> {
  ZsTextEditingController? _ownController;
  FocusNode? _ownFocus;
  final _undo = UndoHistoryController();
  var _hovered = false;

  ZsTextEditingController get _controller => widget.controller ?? (_ownController ??= ZsTextEditingController());

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'ZsTextField'));

  bool get _disabled => !widget.enabled || widget.disabledReason != null;

  Set<WidgetState> get _forced => widget.statesController?.value ?? const <WidgetState>{};

  @override
  void initState() {
    super.initState();
    _focus.addListener(_changed);
    _controller.addListener(_changed);
    widget.statesController?.addListener(_changed);
  }

  @override
  void didUpdateWidget(ZsTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.statesController != widget.statesController) {
      oldWidget.statesController?.removeListener(_changed);
      widget.statesController?.addListener(_changed);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownFocus)?.removeListener(_changed);
      _focus.addListener(_changed);
    }
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _ownController)?.removeListener(_changed);
      _controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_changed);
    _controller.removeListener(_changed);
    widget.statesController?.removeListener(_changed);
    _ownController?.dispose();
    _ownFocus?.dispose();
    _undo.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  _WellLook _look(ZsColors c, {required bool inactive}) {
    final bool focused = (_focus.hasFocus || _forced.contains(WidgetState.focused)) && !inactive;
    final bool hovered = _hovered || _forced.contains(WidgetState.hovered);
    final invalid = widget.error != null;
    if (widget.readOnly) {
      return (fill: _clear, border: c.flBorder, halo: _clear);
    }
    if (invalid) {
      return (fill: c.fieldBg, border: c.error, halo: focused ? c.errorRing : _clear);
    }
    if (focused) {
      return (fill: c.fieldBg, border: c.accentLine, halo: c.accentRing);
    }
    return (fill: c.fieldBg, border: hovered && !inactive && !_disabled ? c.borderStrong : c.flBorder, halo: _clear);
  }

  TextStyle _style(ZsColors colors) {
    final Color color = widget.readOnly ? colors.textMuted : colors.text;
    if (widget.mono) {
      return zsMono(ZsType.fsMd, height: ZsType.lhUi).copyWith(color: color);
    }
    if (widget.multiline) {
      return zsSans(ZsType.fsBase, height: ZsType.lhUi).copyWith(color: color);
    }
    return switch (widget.size) {
      ZsTextFieldSize.sm => zsSans(ZsType.fsControl, height: ZsType.lhSnug).copyWith(color: color),
      ZsTextFieldSize.md => zsSans(
        ZsType.fsBase,
        weight: FontWeight.w600,
        height: ZsType.lhSnug,
      ).copyWith(color: color),
      ZsTextFieldSize.lg => zsSans(ZsType.fsLg, weight: FontWeight.w600, height: ZsType.lhSnug).copyWith(color: color),
    };
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final bool inactive = ZsAppearance.of(context).inactive;
    final TextStyle style = _style(colors);
    final String? placeholder = widget.placeholder;
    final Widget input = Stack(
      alignment: widget.multiline ? AlignmentDirectional.topStart : AlignmentDirectional.centerStart,
      children: <Widget>[
        if (placeholder != null && _controller.text.isEmpty)
          ExcludeSemantics(
            child: Text(placeholder, style: style.copyWith(color: colors.textFaint), maxLines: 1, softWrap: false),
          ),
        Material(
          type: MaterialType.transparency,
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            undoController: _undo,
            decoration: null,
            style: style,
            readOnly: widget.readOnly,
            enabled: !_disabled,
            cursorColor: inactive ? _clear : (widget.error != null ? colors.error : colors.accentLine),
            maxLines: widget.multiline ? null : 1,
            minLines: widget.multiline ? 2 : null,
            keyboardType: widget.multiline ? TextInputType.multiline : TextInputType.text,
            onChanged: widget.onChanged,
            onSubmitted: widget.onSubmitted,
            contextMenuBuilder: widget.contextMenu ? (context, state) => _textContextMenu(context, state, _undo) : null,
          ),
        ),
      ],
    );
    final double height = widget.size == ZsTextFieldSize.sm ? metrics.controlMd : metrics.controlLg;
    final Widget well = ZsLerpBuilder<_WellLook>(
      value: _look(colors, inactive: inactive),
      lerp: _lerpWell,
      duration: motion.durHover,
      curve: motion.easeState,
      builder: (context, look, child) => CustomPaint(
        painter: _WellPainter(look: look, radius: metrics.radiusMd, halo: metrics.fieldHalo, dashed: widget.readOnly),
        child: child,
      ),
      child: widget.multiline
          ? ConstrainedBox(
              // `min-height:62px`, `padding:8px 10px` (DS components/forms/forms.css:103).
              constraints: const BoxConstraints(minHeight: 62),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), child: input),
            )
          : SizedBox(
              height: height,
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: input),
            ),
    );
    Widget field = MouseRegion(
      cursor: _disabled ? SystemMouseCursors.basic : SystemMouseCursors.text,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        excludeFromSemantics: true,
        onTap: _disabled ? null : _focus.requestFocus,
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          onKeyEvent: (node, event) => _fieldKeys(event, widget.fieldList, () => false),
          child: well,
        ),
      ),
    );
    final String? error = widget.error;
    if (error != null && error.isNotEmpty) {
      field = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: ZsTextField._messageGap,
        children: <Widget>[
          field,
          ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.only(left: 1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 5,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: ZanshinIcon(ZI.alert, size: ZsIconSize.sm, color: colors.rem),
                  ),
                  Expanded(
                    child: Text(
                      error,
                      style: zsSans(ZsType.fsSm, height: ZsType.lhSnug).copyWith(color: colors.rem),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    final String? reason = widget.disabledReason;
    // The text field's own node carries the text-field, enabled and read-only flags; this adds the name, the
    // identifier and the description without overlapping them.
    field = Semantics(
      identifier: widget.identifier,
      // Without a row label the placeholder names the field, as the search field's does.
      label: widget.label ?? widget.placeholder,
      hint: reason ?? (error != null && error.isNotEmpty ? error : null),
      child: field,
    );
    if (_disabled) {
      field = Opacity(opacity: metrics.disabledOpacity, child: field);
    }
    if (reason != null) {
      field = ZsTooltip(
        message: reason,
        child: IgnorePointer(child: ExcludeFocus(child: field)),
      );
    }
    return field;
  }
}

typedef _SearchLook = ({Color fill, Color border, Color halo, Color placeholder});

_SearchLook _lerpSearch(_SearchLook a, _SearchLook b, double t) => (
  fill: Color.lerp(a.fill, b.fill, t)!,
  border: Color.lerp(a.border, b.border, t)!,
  halo: Color.lerp(a.halo, b.halo, t)!,
  placeholder: Color.lerp(a.placeholder, b.placeholder, t)!,
);

/// The list search field (DS components/forms/SearchField.{d.ts,jsx,prompt.md}; forms.css:58-69): 30 high, radius
/// `--radius-btn`, padding 0 5 0 9, gap 7; a named exception to the well — a quiet `--fl-hover` fill (hover `--fl-on`)
/// with a transparent edge, as NSSearchField. Focus is text entry's: an `--accent-line` edge with a 3 px
/// `--accent-ring` halo. The search mark is md `--text-dim`, the text `--fs-control`, the placeholder `--text-faint`
/// stepping up to dim on hover (decision 16.41). Under increased contrast the edge is `--border-strong` (DS
/// tokens/contrast.css:24); in an inactive window it is transparent, with no halo and no caret.
///
/// With a query a 20 px ✕ (an xs close mark, `--text-faint` → hover `--fl-on` / `--text`, pressed `--fl-press`, the
/// ring inside, named "Clear") replaces the [shortcutLabel] key cap, which shows only while the field is empty and
/// unfocused. Esc clears; Esc on an empty field leaves it. With a [fieldList] attached, ↑ ↓ Home End ↩ go to the list
/// and the first Esc detaches it.
class ZsSearchField extends StatefulWidget implements ZsControl {
  /// A search field.
  const ZsSearchField({
    this.controller,
    this.focusNode,
    this.placeholder = 'Search',
    this.label,
    this.shortcutLabel,
    this.onChanged,
    this.onClear,
    this.fieldList,
    this.statesController,
    this.identifier,
    super.key,
  });

  /// The query; the field keeps its own when null.
  final ZsTextEditingController? controller;

  /// The field's focus node.
  final FocusNode? focusNode;

  /// The placeholder, also the default name.
  final String placeholder;

  /// The accessible name; the placeholder when null.
  final String? label;

  /// The key cap shown while the field is empty and unfocused ("/").
  final String? shortcutLabel;

  /// Called on every edit.
  final ValueChanged<String>? onChanged;

  /// Called after the ✕ or Esc cleared the query.
  final VoidCallback? onClear;

  /// The field-attached list its keys drive while attached.
  final ZsFieldListController? fieldList;

  /// A states controller; the catalogue forces hover and focus through it (they add to the real ones).
  final WidgetStatesController? statesController;

  @override
  final String? identifier;

  @override
  State<ZsSearchField> createState() => _ZsSearchFieldState();
}

class _ZsSearchFieldState extends State<ZsSearchField> {
  ZsTextEditingController? _ownController;
  FocusNode? _ownFocus;
  final _undo = UndoHistoryController();
  var _hovered = false;

  ZsTextEditingController get _controller => widget.controller ?? (_ownController ??= ZsTextEditingController());

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'ZsSearchField'));

  Set<WidgetState> get _forced => widget.statesController?.value ?? const <WidgetState>{};

  @override
  void initState() {
    super.initState();
    _focus.addListener(_changed);
    _controller.addListener(_changed);
    widget.statesController?.addListener(_changed);
  }

  @override
  void didUpdateWidget(ZsSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.statesController != widget.statesController) {
      oldWidget.statesController?.removeListener(_changed);
      widget.statesController?.addListener(_changed);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownFocus)?.removeListener(_changed);
      _focus.addListener(_changed);
    }
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _ownController)?.removeListener(_changed);
      _controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_changed);
    _controller.removeListener(_changed);
    widget.statesController?.removeListener(_changed);
    _ownController?.dispose();
    _ownFocus?.dispose();
    _undo.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  void _clearQuery({required bool refocus}) {
    _controller.clear();
    widget.onChanged?.call('');
    widget.onClear?.call();
    if (refocus) {
      _focus.requestFocus();
    }
  }

  bool _escape() {
    if (_controller.text.isNotEmpty) {
      _clearQuery(refocus: false);
    } else {
      _focus.unfocus();
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final appearance = ZsAppearance.of(context);
    final bool inactive = appearance.inactive;
    final bool hasFocus = _focus.hasFocus || _forced.contains(WidgetState.focused);
    final bool focused = hasFocus && !inactive;
    final bool hover = (_hovered || _forced.contains(WidgetState.hovered)) && !inactive;
    final _SearchLook look = (
      fill: !focused && hover ? colors.flOn : colors.flHover,
      border: focused ? colors.accentLine : (appearance.increasedContrast && !inactive ? colors.borderStrong : _clear),
      halo: focused ? colors.accentRing : _clear,
      placeholder: ZsTextRung.of(colors, hovered: hover).faint,
    );
    final bool query = _controller.text.isNotEmpty;
    final String? shortcut = widget.shortcutLabel;
    final TextStyle style = zsSans(ZsType.fsControl, height: ZsType.lhSnug).copyWith(color: colors.text);
    return Semantics(
      identifier: widget.identifier,
      label: widget.label ?? widget.placeholder,
      child: MouseRegion(
        cursor: SystemMouseCursors.text,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          excludeFromSemantics: true,
          onTap: _focus.requestFocus,
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            includeSemantics: false,
            onKeyEvent: (node, event) => _fieldKeys(event, widget.fieldList, _escape),
            child: ZsLerpBuilder<_SearchLook>(
              value: look,
              lerp: _lerpSearch,
              duration: motion.durHover,
              curve: motion.easeState,
              builder: (context, look, _) => CustomPaint(
                painter: _WellPainter(
                  look: (fill: look.fill, border: look.border, halo: look.halo),
                  radius: metrics.radiusBtn,
                  halo: metrics.fieldHalo,
                ),
                child: SizedBox(
                  height: metrics.controlMd,
                  child: Padding(
                    // `padding:0 5px 0 9px` inside the 1 px edge (DS components/forms/forms.css:61).
                    padding: const EdgeInsets.fromLTRB(10, 0, 6, 0),
                    child: Row(
                      spacing: 7,
                      children: <Widget>[
                        ExcludeSemantics(
                          child: ZanshinIcon(ZI.search, size: ZsIconSize.md, color: colors.textDim),
                        ),
                        Expanded(
                          child: Stack(
                            alignment: AlignmentDirectional.centerStart,
                            children: <Widget>[
                              if (!query)
                                ExcludeSemantics(
                                  child: Text(
                                    widget.placeholder,
                                    style: style.copyWith(color: look.placeholder),
                                    maxLines: 1,
                                    softWrap: false,
                                  ),
                                ),
                              Material(
                                type: MaterialType.transparency,
                                child: TextField(
                                  controller: _controller,
                                  focusNode: _focus,
                                  undoController: _undo,
                                  decoration: null,
                                  style: style,
                                  cursorColor: inactive ? _clear : colors.accentLine,
                                  onChanged: widget.onChanged,
                                  contextMenuBuilder: (context, state) => _textContextMenu(context, state, _undo),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (query)
                          _ClearButton(onPressed: () => _clearQuery(refocus: true))
                        else if (shortcut != null && !hasFocus)
                          Padding(padding: const EdgeInsets.only(right: 3), child: ZsKbd(shortcut)),
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

/// The search field's ✕ (DS components/forms/forms.css:66-68): 20 px, round, an xs close mark.
class _ClearButton extends StatelessWidget {
  const _ClearButton({required this.onPressed});

  final VoidCallback onPressed;

  /// `width:20px;height:20px` (DS components/forms/forms.css:66).
  static const double _side = 20;

  @override
  Widget build(BuildContext context) => ZsControlCore(
    onActivate: onPressed,
    semantics: const SemanticsProperties(button: true, label: 'Clear'),
    ring: ZsRingPlacement.inside,
    ringRadius: _side / 2,
    builder: (context, status) {
      final ZsColors colors = ZsColors.of(context);
      final ZsMotion motion = ZsMotion.of(context);
      final bool lit = status.hovered || status.pressed;
      return ZsLerpBuilder<(Color, Color)>(
        value: (
          status.pressed ? colors.flPress : (status.hovered ? colors.flOn : _clear),
          lit ? colors.text : colors.textFaint,
        ),
        lerp: (a, b, t) => (Color.lerp(a.$1, b.$1, t)!, Color.lerp(a.$2, b.$2, t)!),
        duration: status.pressed ? motion.durInstant : motion.durHover,
        curve: motion.easeState,
        builder: (context, look, _) => DecoratedBox(
          decoration: BoxDecoration(color: look.$1, shape: BoxShape.circle),
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
