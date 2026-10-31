// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/zs_appearance.dart';
import '../design/zs_metrics.dart';
import '../zs_strings.dart';
import 'zs_focus_ring.dart';
import 'zs_tooltip.dart';

/// What a control shows at the moment: its [WidgetState]s as the core keeps them (or as a forced
/// `WidgetStatesController` says), plus busy and the inactive window.
@immutable
class ZsControlStatus {
  /// A status of [states].
  const ZsControlStatus({required this.states, this.busy = false, this.inactive = false});

  /// The states; a forced `focused` counts as focus-visible.
  final Set<WidgetState> states;

  /// Whether the control runs (a spinner shows, presses are ignored).
  final bool busy;

  /// Whether the window is not key.
  final bool inactive;

  /// The pointer is over the control (never in an inactive window).
  bool get hovered => states.contains(WidgetState.hovered);

  /// The pointer or ↩ / Space is down on the control.
  bool get pressed => states.contains(WidgetState.pressed);

  /// The control has keyboard focus: the ring shows.
  bool get focusVisible => states.contains(WidgetState.focused);

  /// The control is disabled, with or without a reason.
  bool get disabled => states.contains(WidgetState.disabled);

  /// The control is on (a toggled switch, a checked box, the chosen segment).
  bool get selected => states.contains(WidgetState.selected);

  /// The control is invalid.
  bool get error => states.contains(WidgetState.error);
}

/// The one state core every Zs control takes its states from (story 11.11 item 1; RC §4): a
/// `FocusableActionDetector`, a `WidgetStatesController`, a `MouseRegion` and one `Semantics` node, about the 40
/// lines Material's `WidgetStateMixin` would be, but in the widgets layer.
///
/// **States** (DS readme.md:116-145):
/// - hovered from the detector's hover highlight, dropped in an inactive window and while busy;
/// - pressed from the pointer's down to its up or cancel, and from ↩ / Space down to up — set at once (the press is
///   instant, DS components/base.css:43);
/// - focused only when focus is visible. macOS's highlight mode is always "traditional", so the core never takes
///   focus on a pointer press, and focus that arrives comes from the keyboard (`:focus-visible`, RC §4);
/// - disabled, selected and error from the widget, set when they change.
/// The core only adds and removes what changes, so a [statesController] the caller forces (the catalogue's state
/// matrix) wins until a real event changes that state.
///
/// **Disabled with a reason** (DS components/base.css:33-40; readme.md:136): the control at `--disabled-opacity`,
/// wrapped in `ZsTooltip(message: reason)` around `IgnorePointer` and `ExcludeFocus`: the wrapper keeps the hover
/// for the tooltip, the control takes no pointer, no key and is no Tab stop; its own semantics node reads enabled
/// false with the reason as hint, "dimmed" for VoiceOver.
///
/// **Busy:** activation is ignored, the cursor is `progress` and the semantics value reads "busy" (Claude's proposal,
/// Story 11.11: the DS's `aria-busy`).
///
/// **Semantics:** one container node with [identifier], the control's [semantics], enabled, the reason as hint, the
/// text of an enclosing `ZsTooltip` as tooltip (unless it repeats the label or hint), and a tap action that
/// activates; the painted child's own semantics are excluded unless [excludeChildSemantics] is false.
class ZsControlCore extends StatefulWidget {
  /// Builds a control from its [ZsControlStatus].
  const ZsControlCore({
    required this.builder,
    required this.semantics,
    this.onActivate,
    this.enabled = true,
    this.disabledReason,
    this.busy = false,
    this.selected = false,
    this.error = false,
    this.focusNode,
    this.statesController,
    this.shortcuts,
    this.actions,
    this.activateOnKeys = true,
    this.activateOnTap = true,
    this.cursor = SystemMouseCursors.basic,
    this.ring,
    this.ringRadius = 0,
    this.identifier,
    this.excludeChildSemantics = true,
    this.dimWhenDisabled = true,
    super.key,
  });

  /// Builds the painted control for the current status.
  final Widget Function(BuildContext context, ZsControlStatus status) builder;

  /// The control's role, label, value and flags; the core adds enabled, the reason, the tooltip and the tap.
  final SemanticsProperties semantics;

  /// Runs on a click, on ↩ / Space and on VoiceOver's press; null for a control nothing activates.
  final VoidCallback? onActivate;

  /// Whether the control takes input at all.
  final bool enabled;

  /// Why the control is disabled; implies disabled.
  final String? disabledReason;

  /// Whether the control runs.
  final bool busy;

  /// Whether the control is on.
  final bool selected;

  /// Whether the control is invalid.
  final bool error;

  /// The control's focus node; the core keeps its own when null.
  final FocusNode? focusNode;

  /// The caller's states controller; the core keeps its own when null.
  final WidgetStatesController? statesController;

  /// Shortcuts besides ↩ and Space.
  final Map<ShortcutActivator, Intent>? shortcuts;

  /// Actions for [shortcuts].
  final Map<Type, Action<Intent>>? actions;

  /// Whether ↩ and Space activate (and show the press while held).
  final bool activateOnKeys;

  /// Whether a click activates; false for a control that acts on the press itself (the select).
  final bool activateOnTap;

  /// The cursor over the control; `progress` replaces it while busy.
  final MouseCursor cursor;

  /// Where the focus ring sits, or null when the control draws its own (the slider) or none (text entry).
  final ZsRingPlacement? ring;

  /// The control's corner radius, for the ring.
  final double ringRadius;

  /// The node's `Semantics(identifier:)`.
  final String? identifier;

  /// Whether the painted child's semantics are dropped, so the label is not read twice.
  final bool excludeChildSemantics;

  /// Whether the core lays `--disabled-opacity` over a disabled control; false for a control that dims only a part.
  final bool dimWhenDisabled;

  @override
  State<ZsControlCore> createState() => _ZsControlCoreState();
}

class _ZsControlCoreState extends State<ZsControlCore> {
  WidgetStatesController? _ownStates;
  FocusNode? _ownFocus;

  var _hovering = false;
  var _keyDown = false;
  var _inactive = false;

  WidgetStatesController get _states => widget.statesController ?? (_ownStates ??= WidgetStatesController());

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'ZsControlCore'));

  bool get _disabled => !widget.enabled || widget.disabledReason != null;

  bool get _interactive => !_disabled && !widget.busy;

  @override
  void initState() {
    super.initState();
    _states.addListener(_changed);
    _seed();
  }

  /// Adds the states the widget drives to a new controller, keeping whatever it was forced to.
  void _seed() {
    if (_disabled) {
      _states.update(WidgetState.disabled, true);
    }
    if (widget.selected) {
      _states.update(WidgetState.selected, true);
    }
    if (widget.error) {
      _states.update(WidgetState.error, true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool inactive = ZsAppearance.of(context).inactive;
    if (inactive != _inactive) {
      _inactive = inactive;
      _syncHover();
    }
  }

  @override
  void didUpdateWidget(ZsControlCore oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.statesController != widget.statesController) {
      (oldWidget.statesController ?? _ownStates)?.removeListener(_changed);
      _states.addListener(_changed);
      _seed();
    }
    final bool wasDisabled = !oldWidget.enabled || oldWidget.disabledReason != null;
    if (wasDisabled != _disabled) {
      _states.update(WidgetState.disabled, _disabled);
      if (_disabled) {
        _keyDown = false;
        _states
          ..update(WidgetState.pressed, false)
          ..update(WidgetState.hovered, false);
      }
    }
    if (oldWidget.selected != widget.selected) {
      _states.update(WidgetState.selected, widget.selected);
    }
    if (oldWidget.error != widget.error) {
      _states.update(WidgetState.error, widget.error);
    }
    if (oldWidget.busy != widget.busy) {
      _syncHover();
    }
  }

  @override
  void dispose() {
    _states.removeListener(_changed);
    _ownStates?.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  void _syncHover() => _states.update(WidgetState.hovered, _hovering && !_inactive && _interactive);

  void _handleHover(bool hovering) {
    _hovering = hovering;
    _syncHover();
  }

  void _handleFocusHighlight(bool visible) => _states.update(WidgetState.focused, visible);

  /// A key press whose activation moved focus away (a menu, a select's list, a sheet) never sees its key-up here:
  /// the press ends with the focus.
  void _handleFocusChange(bool focused) {
    if (!focused && _keyDown) {
      _keyDown = false;
      _states.update(WidgetState.pressed, false);
    }
  }

  void _activate() {
    if (_interactive) {
      widget.onActivate?.call();
    }
  }

  void _pointerDown(PointerDownEvent event) {
    if (_interactive && event.buttons & kPrimaryButton != 0) {
      _states.update(WidgetState.pressed, true);
    }
  }

  void _pointerUp(PointerEvent event) {
    // The pointer's hit path outlives a control removed mid-press (the inspector's edge closing during a drag).
    if (mounted && !_keyDown) {
      _states.update(WidgetState.pressed, false);
    }
  }

  static bool _isActivationKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.space;

  /// ⌘, ⌃ or ⌥ is held: ⌘↩ belongs to the sheet around a control (the destructive confirm), not to the control.
  static bool get _modified {
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    return keyboard.isMetaPressed || keyboard.isControlPressed || keyboard.isAltPressed;
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!widget.activateOnKeys || !_focus.hasPrimaryFocus || !_isActivationKey(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      return _keyDown ? _release() : KeyEventResult.ignored;
    }
    if (!_interactive || _modified) {
      return KeyEventResult.ignored;
    }
    return event is KeyDownEvent ? _press() : KeyEventResult.handled;
  }

  KeyEventResult _press() {
    _keyDown = true;
    _states.update(WidgetState.pressed, true);
    _activate();
    return KeyEventResult.handled;
  }

  KeyEventResult _release() {
    _keyDown = false;
    _states.update(WidgetState.pressed, false);
    return KeyEventResult.handled;
  }

  String? _tooltip(String? label, String? hint) {
    final String? text = ZsTooltip.semanticsOf(context);
    return text == null || text == label || text == hint ? null : text;
  }

  @override
  Widget build(BuildContext context) {
    final String? reason = widget.disabledReason;
    final SemanticsProperties s = widget.semantics;
    final status = ZsControlStatus(
      states: Set<WidgetState>.of(_states.value),
      busy: widget.busy,
      inactive: _inactive,
    );
    Widget visual = widget.builder(context, status);
    final ZsRingPlacement? ring = widget.ring;
    if (ring != null) {
      visual = ZsFocusRing(
        visible: status.focusVisible,
        placement: ring,
        radius: widget.ringRadius,
        child: visual,
      );
    }
    if (_disabled && widget.dimWhenDisabled) {
      visual = Opacity(opacity: ZsMetrics.of(context).disabledOpacity, child: visual);
    }
    if (widget.excludeChildSemantics) {
      visual = ExcludeSemantics(child: visual);
    }
    final String? hint = reason ?? s.hint;
    Widget control = Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onKeyEvent: _handleKey,
      child: FocusableActionDetector(
        enabled: !_disabled,
        focusNode: _focus,
        shortcuts: widget.shortcuts,
        actions: widget.actions,
        mouseCursor: widget.busy ? SystemMouseCursors.progress : widget.cursor,
        onShowHoverHighlight: _handleHover,
        onShowFocusHighlight: _handleFocusHighlight,
        onFocusChange: _handleFocusChange,
        child: Listener(
          onPointerDown: _pointerDown,
          onPointerUp: _pointerUp,
          onPointerCancel: _pointerUp,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: widget.onActivate == null || !widget.activateOnTap ? null : _activate,
            child: visual,
          ),
        ),
      ),
    );
    control = Semantics(
      container: true,
      identifier: widget.identifier,
      enabled: !_disabled,
      label: s.label,
      value: widget.busy ? zsStrings(context).busyValue : s.value,
      hint: hint,
      tooltip: _tooltip(s.label, hint),
      button: s.button,
      link: s.link,
      toggled: s.toggled,
      checked: s.checked,
      mixed: s.mixed,
      selected: s.selected,
      inMutuallyExclusiveGroup: s.inMutuallyExclusiveGroup,
      slider: s.slider,
      textField: s.textField,
      readOnly: s.readOnly,
      expanded: s.expanded,
      header: s.header,
      increasedValue: s.increasedValue,
      decreasedValue: s.decreasedValue,
      onIncrease: _disabled ? null : s.onIncrease,
      onDecrease: _disabled ? null : s.onDecrease,
      onTap: _interactive ? (s.onTap ?? (widget.onActivate == null ? null : _activate)) : null,
      child: control,
    );
    if (reason != null) {
      control = ZsTooltip(
        message: reason,
        child: IgnorePointer(child: ExcludeFocus(child: control)),
      );
    }
    return control;
  }
}
