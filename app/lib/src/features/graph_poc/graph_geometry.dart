// SPDX-License-Identifier: MIT

import 'dart:ui';

import 'graph_data.dart';

// Geometry is a pure function of the data: fixed row height and lane width.
// Layout, paint, scroll extents and "scroll to commit" (row * rowHeight) all
// derive pixels from here — no widget is ever measured.
const double rowHeight = 56;
const double laneWidth = 240;
const double cardWidth = 200;
const double cardHeight = 40;

const lanePalette = <Color>[
  Color(0xFF4FC3F7),
  Color(0xFFFFB74D),
  Color(0xFF81C784),
  Color(0xFFE57373),
  Color(0xFFBA68C8),
  Color(0xFFFFF176),
];

Color laneColor(int colorIndex) => lanePalette[colorIndex % lanePalette.length];

/// Total scrollable content, known before a single child is built.
Size contentSize(CommitGraphData graph) => Size(graph.laneCount * laneWidth, graph.rows.length * rowHeight);

/// Horizontal center of a lane (where its edges run).
double laneCenterX(int lane) => (lane + 0.5) * laneWidth;

/// Card bounds in content coordinates: centered in its lane column and row.
Rect cardRect(int row, int lane) => Rect.fromLTWH(
  lane * laneWidth + (laneWidth - cardWidth) / 2,
  row * rowHeight + (rowHeight - cardHeight) / 2,
  cardWidth,
  cardHeight,
);
