// SPDX-License-Identifier: MIT

import 'dart:ui' show FontFeature, FontVariation, FontWeight;

import 'package:flutter/painting.dart' show TextStyle;

import '../design/zs_type.dart';

// The text styles the controls write as CSS shorthands that no `ZsType` role names (a size or weight other than the
// role's); built from the roles so the families, the half-leading and the variable `wght` axis stay right.

/// [style] at [weight], on both the `fontWeight` and the variable fonts' `wght` axis.
TextStyle zsWeighted(TextStyle style, FontWeight weight) =>
    style.copyWith(fontWeight: weight, fontVariations: <FontVariation>[FontVariation.weight(weight.value.toDouble())]);

/// Inter at [size] and [weight], line height [height] (CSS `font: <weight> <size>/<height> var(--font-sans)`).
TextStyle zsSans(double size, {FontWeight weight = FontWeight.w400, double height = 1}) =>
    zsWeighted(ZsType.body, weight).copyWith(fontSize: size, height: height);

/// JetBrains Mono at [size] and [weight], line height [height], with tabular figures
/// (`font-variant-numeric: tabular-nums`).
TextStyle zsMono(double size, {FontWeight weight = FontWeight.w400, double height = 1}) =>
    zsWeighted(ZsType.id, weight).copyWith(
      fontSize: size,
      height: height,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
