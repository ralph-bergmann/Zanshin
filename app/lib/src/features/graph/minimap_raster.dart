// SPDX-License-Identifier: MIT

import 'dart:math' as math;
import 'dart:typed_data';

// No `dart:ui` here: [rasterMinimap] runs inside `Isolate.run` (Story 10.16).

/// The minimap raster's input (Story 10.16): the laid-out nodes' plane centres, the edges' polylines in plane
/// coordinates, the linear map from plane to device pixels and the four colours — typed arrays only, so it crosses to
/// another isolate as one copy.
class MinimapRasterInput {
  /// An input for a raster of [width] × [height] device pixels.
  MinimapRasterInput({
    required this.nodeXs,
    required this.nodeYs,
    required this.nodeStacks,
    required this.edgeStarts,
    required this.edgePoints,
    required this.ax,
    required this.bx,
    required this.ay,
    required this.by,
    required this.dpr,
    required this.width,
    required this.height,
    required this.outNode,
    required this.outEdge,
    required this.inNode,
    required this.inEdge,
  }) : assert(nodeXs.length == nodeYs.length && nodeXs.length == nodeStacks.length),
       assert(edgeStarts.isNotEmpty);

  /// Each node's centre x, in plane coordinates.
  final Float64List nodeXs;

  /// Each node's centre y, in plane coordinates.
  final Float64List nodeYs;

  /// 1 where the node is a collapsed stack (a ring), else 0 (a disc).
  final Uint8List nodeStacks;

  /// The polyline CSR offsets (E + 1, in points).
  final Int32List edgeStarts;

  /// Every polyline's points as x, y pairs, in plane coordinates.
  final Float64List edgePoints;

  /// Device x = [ax] + [bx] · plane x.
  final double ax;

  /// Device x = [ax] + [bx] · plane x.
  final double bx;

  /// Device y = [ay] + [by] · plane y.
  final double ay;

  /// Device y = [ay] + [by] · plane y.
  final double by;

  /// Device pixels per CSS pixel: the stamps' sizes are CSS px.
  final double dpr;

  /// The raster's width in device pixels.
  final int width;

  /// The raster's height in device pixels.
  final int height;

  /// The out layer's node colour, 0xAARRGGBB (`--text-faint`).
  final int outNode;

  /// The out layer's edge colour, 0xAARRGGBB (`--text-faint`).
  final int outEdge;

  /// The in layer's node colour, 0xAARRGGBB (`--text`).
  final int inNode;

  /// The in layer's edge colour, 0xAARRGGBB (`--text-muted`).
  final int inEdge;
}

/// A node disc's radius (DS ui_kits/desktop/kit.css:162, `r 2`).
const double minimapNodeRadius = 2;

/// A stack ring's radius and stroke (graph-view.jsx:513, `r 2.6`; kit.css:161, stroke 1.2).
const minimapRingRadius = 2.6;

/// A stack ring's stroke width.
const minimapRingStroke = 1.2;

/// An edge dot's diameter (kit.css:159, `stroke-width:1.5` with round caps).
const minimapEdgeDot = 1.5;

/// The dot spacing of every edge, direct and indirect alike (kit.css:159, `stroke-dasharray:0 3`; one spacing since
/// design sync #22).
const double minimapEdgeStep = 3;

/// Both raster layers of [input], one after the other, each `width · height · 4` bytes of RGBA with premultiplied
/// alpha (the form `decodeImageFromPixels` reads `rgba8888` in): first the out layer (nodes in [MinimapRasterInput.outNode],
/// edges in [MinimapRasterInput.outEdge]), then the in layer. Each pixel's coverage is the max over its stamps; a node
/// composites over an edge. O(n + total edge length in device px + pixels).
Uint8List rasterMinimap(MinimapRasterInput input) {
  final int w = input.width;
  final int h = input.height;
  final int area = w * h;
  final out = Uint8List(area * 8);
  if (area == 0) {
    return out;
  }
  final edges = Float32List(area);
  final nodes = Float32List(area);
  final double dpr = input.dpr;

  final double dotR = minimapEdgeDot / 2 * dpr;
  final double step = minimapEdgeStep * dpr;
  final Float64List p = input.edgePoints;
  for (var e = 0; e + 1 < input.edgeStarts.length; e++) {
    final int end = input.edgeStarts[e + 1];
    for (int q = input.edgeStarts[e] + 1; q < end; q++) {
      _dots(
        edges,
        w,
        h,
        input.ax + input.bx * p[2 * q - 2],
        input.ay + input.by * p[2 * q - 1],
        input.ax + input.bx * p[2 * q],
        input.ay + input.by * p[2 * q + 1],
        step,
        dotR,
      );
    }
  }

  final double r = minimapNodeRadius * dpr;
  final double ring = minimapRingRadius * dpr;
  final double stroke = minimapRingStroke * dpr;
  for (var i = 0; i < input.nodeXs.length; i++) {
    final double x = input.ax + input.bx * input.nodeXs[i];
    final double y = input.ay + input.by * input.nodeYs[i];
    if (y < -ring - stroke - 1 || y > h + ring + stroke + 1) {
      continue;
    }
    if (input.nodeStacks[i] != 0) {
      _ring(nodes, w, h, x, y, ring, stroke);
    } else {
      _disc(nodes, w, h, x, y, r);
    }
  }

  _compose(out, 0, edges, nodes, input.outEdge, input.outNode);
  _compose(out, area * 4, edges, nodes, input.inEdge, input.inNode);
  return out;
}

/// Stamps the dots of the segment ([x0], [y0]) → ([x1], [y1]) into [cov]: one where its major axis crosses a multiple of
/// [step]. The grid is the raster's own, shared by every edge, so lines that run together put their dots on the same
/// spots and read as one line, not a denser one (design sync #22).
void _dots(Float32List cov, int w, int h, double x0, double y0, double x1, double y1, double step, double r) {
  final double dx = x1 - x0;
  final double dy = y1 - y0;
  final bool vertical = dy.abs() >= dx.abs();
  final a0 = vertical ? y0 : x0;
  final a1 = vertical ? y1 : x1;
  if (a0 == a1) {
    return;
  }
  // Story 10.31: a raster may cover only a window of the content; the dots off it are not stamped.
  final double reach = r + 1;
  if (math.max(y0, y1) < -reach || math.min(y0, y1) > h + reach) {
    return;
  }
  final double limit = (vertical ? h : w) + reach;
  final int last = (math.min(math.max(a0, a1), limit) / step).floor();
  for (int k = (math.max(math.min(a0, a1), -reach) / step).ceil(); k <= last; k++) {
    final double t = (k * step - a0) / (a1 - a0);
    _disc(cov, w, h, x0 + dx * t, y0 + dy * t, r);
  }
}

/// Stamps an anti-aliased disc of radius [r] at ([cx], [cy]) into [cov] (max per pixel).
void _disc(Float32List cov, int w, int h, double cx, double cy, double r) {
  final int x0 = math.max(0, (cx - r - 1).floor());
  final int x1 = math.min(w - 1, (cx + r + 1).ceil());
  final int y0 = math.max(0, (cy - r - 1).floor());
  final int y1 = math.min(h - 1, (cy + r + 1).ceil());
  for (var y = y0; y <= y1; y++) {
    final double dy = y + .5 - cy;
    for (var x = x0; x <= x1; x++) {
      final double dx = x + .5 - cx;
      final double c = (r + .5 - math.sqrt(dx * dx + dy * dy)).clamp(0, 1);
      final int k = y * w + x;
      if (c > cov[k]) {
        cov[k] = c;
      }
    }
  }
}

/// Stamps an anti-aliased ring of radius [r] and [stroke] at ([cx], [cy]) into [cov] (max per pixel).
void _ring(Float32List cov, int w, int h, double cx, double cy, double r, double stroke) {
  final double outer = r + stroke / 2;
  final int x0 = math.max(0, (cx - outer - 1).floor());
  final int x1 = math.min(w - 1, (cx + outer + 1).ceil());
  final int y0 = math.max(0, (cy - outer - 1).floor());
  final int y1 = math.min(h - 1, (cy + outer + 1).ceil());
  for (var y = y0; y <= y1; y++) {
    final double dy = y + .5 - cy;
    for (var x = x0; x <= x1; x++) {
      final double dx = x + .5 - cx;
      final double c = (stroke / 2 + .5 - (math.sqrt(dx * dx + dy * dy) - r).abs()).clamp(0, 1);
      final int k = y * w + x;
      if (c > cov[k]) {
        cov[k] = c;
      }
    }
  }
}

/// Writes one layer at [offset]: the node colour at its coverage over the edge colour at its coverage, premultiplied.
void _compose(Uint8List out, int offset, Float32List edges, Float32List nodes, int edgeColor, int nodeColor) {
  final double ea = (edgeColor >>> 24 & 0xff) / 255;
  final double er = (edgeColor >>> 16 & 0xff) / 255;
  final double eg = (edgeColor >>> 8 & 0xff) / 255;
  final double eb = (edgeColor & 0xff) / 255;
  final double na = (nodeColor >>> 24 & 0xff) / 255;
  final double nr = (nodeColor >>> 16 & 0xff) / 255;
  final double ng = (nodeColor >>> 8 & 0xff) / 255;
  final double nb = (nodeColor & 0xff) / 255;
  for (var k = 0; k < edges.length; k++) {
    final double e = edges[k] * ea;
    final double n = nodes[k] * na;
    if (e == 0 && n == 0) {
      continue;
    }
    final double rest = e * (1 - n);
    final int o = offset + 4 * k;
    out[o] = ((nr * n + er * rest) * 255).round();
    out[o + 1] = ((ng * n + eg * rest) * 255).round();
    out[o + 2] = ((nb * n + eb * rest) * 255).round();
    out[o + 3] = ((n + rest) * 255).round();
  }
}
