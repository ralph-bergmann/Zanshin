// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';

/// Keeps a layer mounted while its exit plays (DS components/controls/Presence.jsx:5-16): while [open] it builds
/// [builder] with `closing: false`; when [open] turns false it keeps building it with `closing: true` for [exit],
/// then unmounts it. Opening again within the exit cancels it, and the child stays mounted.
///
/// [exit] comes from the motion tokens — `--dur-exit` for menus, popovers, callouts, select lists and tooltips,
/// `--dur-exit-lg` for sheets and toasts (DS Presence.prompt.md) — never a literal 120.
class ZsPresence extends StatefulWidget {
  /// Shows [builder] while [open] and for [exit] after it.
  const ZsPresence({required this.open, required this.exit, required this.builder, super.key});

  /// Whether the layer is wanted.
  final bool open;

  /// How long the layer stays mounted after [open] turned false.
  final Duration exit;

  /// Builds the layer; `closing` is true while it leaves.
  final Widget Function(BuildContext context, bool closing) builder;

  @override
  State<ZsPresence> createState() => _ZsPresenceState();
}

class _ZsPresenceState extends State<ZsPresence> {
  late bool _mounted = widget.open;
  var _closing = false;
  Timer? _timer;

  @override
  void didUpdateWidget(ZsPresence oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open == oldWidget.open) {
      return;
    }
    _timer?.cancel();
    _timer = null;
    if (widget.open) {
      _mounted = true;
      _closing = false;
    } else if (_mounted) {
      _closing = true;
      _timer = Timer(widget.exit, _unmount);
    }
  }

  void _unmount() {
    if (!mounted) {
      return;
    }
    setState(() {
      _mounted = false;
      _closing = false;
      _timer = null;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _mounted ? widget.builder(context, _closing) : const SizedBox.shrink();
}
