// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

import '../design/zs_motion.dart';

/// The DS's entrances and exits of the surfaces that float for a moment (DS components/base.css:52-62; tokens/
/// motion.css:14-32). One curve per phase drives the fade and the transform together, as a CSS keyframe's timing
/// function does; an entrance always starts from its start state and an exit always from rest, as a replaced CSS
/// animation does.
///
/// | motion | in | out | origin |
/// |---|---|---|---|
/// | [menu] | `--dur-menu`, glide, from scale .97 | `--dur-exit`, exit, fade | top left |
/// | [popover] | `--dur-pop`, glide, from dy −4, scale .98 | `--dur-exit`, exit, to dy −2, scale .99 | top right |
/// | [callout] | `--dur-pop`, glide, from dx −4 | `--dur-exit`, exit, fade | — |
/// | [sheet] | `--dur-dialog`, glide, from dy 8, scale .985 | `--dur-exit-lg`, exit, to dy 4, scale .99 | centre |
///
/// Reduce motion works by property (decision 16.4): every distance, and every scale step away from 1, is ×
/// `--motion` (0 under reduce motion), so the surface only fades; the durations stay.
///
/// The drop menu takes [menu], as the epics' design update lists it among the command menus.
enum ZsSurfaceMotion {
  /// The context, project, drop and text menus (DS components/menus/menus.css:6-7; base.css:54, :60).
  menu,

  /// The popover (DS components/surfaces/surfaces.css:9, :57; base.css:53, :61). The search menu and the search
  /// popover take it too, with `origin: Alignment.topLeft` (DS components/search/search.css:41; surfaces.css:57).
  popover,

  /// The callout (DS components/surfaces/surfaces.css:16, :58; base.css:56, :60).
  callout,

  /// The modal sheet (DS components/surfaces/surfaces.css:30, :60; base.css:57, :62).
  sheet;

  Duration _enterDuration(ZsMotion motion) => switch (this) {
    menu => motion.durMenu,
    popover || callout => motion.durPop,
    sheet => motion.durDialog,
  };

  Duration _exitDuration(ZsMotion motion) => switch (this) {
    menu || popover || callout => motion.durExit,
    sheet => motion.durExitLg,
  };

  /// The entrance's start state for the `--motion` factor [m] (DS components/base.css:53-57).
  _Pose _from(double m) => switch (this) {
    menu => _Pose(scale: 1 - .03 * m),
    popover => _Pose(dy: -4 * m, scale: 1 - .02 * m),
    callout => _Pose(dx: -4 * m),
    sheet => _Pose(dy: 8 * m, scale: 1 - .015 * m),
  };

  /// The exit's end state for the `--motion` factor [m] (DS components/base.css:60-62).
  _Pose _to(double m) => switch (this) {
    menu || callout => const _Pose(),
    popover => _Pose(dy: -2 * m, scale: 1 - .01 * m),
    sheet => _Pose(dy: 4 * m, scale: 1 - .01 * m),
  };

  /// The `transform-origin` (DS components/menus/menus.css:6; components/surfaces/surfaces.css:9; CSS's default
  /// centre otherwise).
  Alignment get _origin => switch (this) {
    menu => Alignment.topLeft,
    popover => Alignment.topRight,
    callout || sheet => Alignment.center,
  };
}

/// Plays [motion]'s entrance when it mounts and its exit while [closing] (see [ZsSurfaceMotion]); [onClosed] runs
/// once each time an exit completes, so the parent can unmount the surface then (11.11's Presence).
///
/// It fades through a `FadeTransition`: wrap only opaque materials (the menu material, the sheet), never glass — an
/// opacity above a `BackdropFilter` drops the blur for the whole fade (deferred-work, Story 11.2). The surface takes
/// no pointer and no focus while it closes, so no key reaches a leaving surface (DS
/// components/surfaces/surfaces.css:57-59).
class ZsSurfaceTransition extends StatefulWidget {
  /// Animates [child] in and out as [motion].
  const ZsSurfaceTransition({
    required this.motion,
    required this.child,
    this.closing = false,
    this.onClosed,
    this.origin,
    super.key,
  });

  /// Which surface's entrance and exit to play.
  final ZsSurfaceMotion motion;

  /// Whether the surface is leaving; turning it back to false restarts the entrance.
  final bool closing;

  /// Runs once when an exit completes; never after the transition is disposed.
  final VoidCallback? onClosed;

  /// The transform origin, when [motion]'s does not fit (a submenu flipped to the left grows from its top right, DS
  /// components/menus/menus.css:13).
  final Alignment? origin;

  /// The surface.
  final Widget child;

  @override
  State<ZsSurfaceTransition> createState() => _ZsSurfaceTransitionState();
}

class _ZsSurfaceTransitionState extends State<ZsSurfaceTransition> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this)..addListener(_onTick);

  /// The entrance runs the controller forward on the glide curve.
  late final CurvedAnimation _enter;

  /// The exit runs it back from 1 on the exit curve, flipped so the value is the remaining opacity.
  late final CurvedAnimation _exit;

  var _started = false;

  /// Whether the running exit has reported [ZsSurfaceTransition.onClosed].
  var _reported = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      final ZsMotion motion = ZsMotion.of(context);
      _enter = CurvedAnimation(parent: _controller, curve: motion.easeGlide);
      _exit = CurvedAnimation(parent: _controller, curve: motion.easeExit.flipped);
      _run();
    }
  }

  @override
  void didUpdateWidget(ZsSurfaceTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.closing != oldWidget.closing) {
      _run();
    }
  }

  void _run() {
    final ZsMotion motion = ZsMotion.of(context);
    if (widget.closing) {
      _reported = false;
      _controller
        ..reverseDuration = widget.motion._exitDuration(motion)
        ..reverse(from: 1);
    } else {
      _controller
        ..duration = widget.motion._enterDuration(motion)
        ..forward(from: 0);
    }
  }

  // On the frame the exit reaches its end, rather than on the next one, where the controller reports dismissed.
  void _onTick() {
    if (widget.closing && !_reported && _controller.value == 0) {
      _reported = true;
      widget.onClosed?.call();
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _exit.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double m = ZsMotion.of(context).motion;
    final bool closing = widget.closing;
    final _Pose pose = closing ? widget.motion._to(m) : widget.motion._from(m);
    final CurvedAnimation progress = closing ? _exit : _enter;
    return IgnorePointer(
      ignoring: closing,
      child: ExcludeFocus(
        excluding: closing,
        child: FadeTransition(
          opacity: progress,
          child: MatrixTransition(
            animation: progress,
            alignment: widget.origin ?? widget.motion._origin,
            onTransform: (value) => pose.at(1 - value),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// A keyframe's transform `translate(dx, dy) scale(scale)` (DS components/base.css:53-62).
@immutable
class _Pose {
  const _Pose({this.dx = 0, this.dy = 0, this.scale = 1});

  final double dx;
  final double dy;
  final double scale;

  /// The transform [amount] of the way from rest (0) to this pose (1), each function interpolated on its own, as
  /// CSS interpolates a transform list against `none`.
  Matrix4 at(double amount) {
    final double s = 1 - (1 - scale) * amount;
    return Matrix4.diagonal3Values(s, s, 1)..setTranslationRaw(dx * amount, dy * amount, 0);
  }
}
