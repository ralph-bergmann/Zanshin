// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

/// Animates a control's painted values toward [value] over [duration] on [curve], interpolating with [lerp]; a new
/// target starts from the value on screen, as a CSS transition does. [value] needs value equality (a record).
///
/// The controls run their colours through one of these on `--dur-hover` (`--dur-instant` while pressed, DS
/// components/base.css:43) and their geometry through another on a movement token, never one token for both (DS
/// readme.md:139).
class ZsLerpBuilder<T extends Object> extends StatelessWidget {
  /// Animates toward [value].
  const ZsLerpBuilder({
    required this.value,
    required this.lerp,
    required this.duration,
    required this.builder,
    this.curve = Curves.linear,
    this.child,
    super.key,
  });

  /// The target.
  final T value;

  /// Interpolates two values.
  final T Function(T a, T b, double t) lerp;

  /// How long a change takes; zero jumps.
  final Duration duration;

  /// The curve of a change.
  final Curve curve;

  /// Builds from the value on screen.
  final Widget Function(BuildContext context, T value, Widget? child) builder;

  /// Passed through to [builder].
  final Widget? child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<T>(
    tween: _LerpTween<T>(end: value, lerp: lerp),
    duration: duration,
    curve: curve,
    builder: builder,
    child: child,
  );
}

class _LerpTween<T extends Object> extends Tween<T> {
  _LerpTween({required super.end, required this._lerp});

  final T Function(T a, T b, double t) _lerp;

  @override
  T lerp(double t) => _lerp(begin ?? end!, end ?? begin!, t);
}
