// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// A pane whose pick boxes show on demand (Story 10.42; design calm-study.css:21-23): while the pointer is over it or
/// the keyboard moved focus inside it, every [InspectorCheck] below shows; otherwise only the picked and half-picked
/// ones do. Focus a click left inside counts again only after the next key. Each pane is its own scope, so hovering one reveals only its boxes.
class InspectorCheckReveal extends StatefulWidget {
  /// The scope over [child].
  const InspectorCheckReveal({required this.child, super.key});

  /// The pane.
  final Widget child;

  /// Whether the scope above [context] is revealed (Story 10.43): its on-demand controls show. Outside any scope they
  /// always show, as an [InspectorCheck] does.
  static bool revealedOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_RevealScope>()?.revealed ?? true;

  @override
  State<InspectorCheckReveal> createState() => _InspectorCheckRevealState();
}

class _InspectorCheckRevealState extends State<InspectorCheckReveal> {
  var _hovered = false;
  var _focusInside = false;
  // Focus reveals only when the keyboard put it there (Ralph, 2026-11-15): a click in the pane keeps focus inside, and
  // the boxes would stay after the pointer leaves. Flutter's highlight mode cannot tell, it counts a mouse as keyboard.
  var _keyboard = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent && !_keyboard) {
      setState(() => _keyboard = true);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) {
      if (_keyboard) {
        setState(() => _keyboard = false);
      }
    },
    child: MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        // Only listens: focus anywhere below reports here, the scope itself never takes it.
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        onFocusChange: (inside) => setState(() => _focusInside = inside),
        child: _RevealScope(
          revealed: _hovered || (_focusInside && _keyboard) || InspectorChecksShown.of(context),
          child: widget.child,
        ),
      ),
    ),
  );
}

class _RevealScope extends InheritedWidget {
  const _RevealScope({required this.revealed, required super.child});

  final bool revealed;

  @override
  bool updateShouldNotify(_RevealScope oldWidget) => revealed != oldWidget.revealed;
}

/// Forces every [InspectorCheckReveal] below revealed — for the catalogue, where Marionette cannot hover.
class InspectorChecksShown extends InheritedWidget {
  /// Shows every pick box in [child].
  const InspectorChecksShown({required super.child, super.key});

  /// Whether one sits above [context].
  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<InspectorChecksShown>() != null;

  @override
  bool updateShouldNotify(InspectorChecksShown oldWidget) => false;
}

/// One pick box: shown while its [InspectorCheckReveal] is revealed or its [value] is not `false` (picked or
/// half-picked). Hidden, only its opacity changes: it keeps its size, focus, semantics and hit target, so no row shifts
/// and VoiceOver and Tab still reach it. Outside any scope it always shows.
class InspectorCheck extends StatelessWidget {
  /// The wrapper of [child], the box of [value].
  const InspectorCheck({required this.value, required this.child, super.key});

  /// The box's value: picked, not picked, or null for half-picked.
  final bool? value;

  /// The box.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final _RevealScope? scope = context.dependOnInheritedWidgetOfExactType<_RevealScope>();
    return AnimatedOpacity(
      opacity: scope == null || scope.revealed || value != false ? 1 : 0,
      duration: ZsMotion.of(context).durHover,
      alwaysIncludeSemantics: true,
      child: child,
    );
  }
}
