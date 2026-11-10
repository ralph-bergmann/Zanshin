import 'package:zanshin_core/src/graph_layout/router.dart';

import 'scene.dart';

/// Counts what the page shows as numbers, the same way for the lab and for the app's layout.
/// Marks every line that passes behind a card ([LabLine.behind]) and every card with a free cell
/// nearer to its lines ([LabCard.nearer]).
///
/// - `columns`: the columns in use.
/// - `bends`: the corners of all lines.
/// - `crossings`: a vertical and a horizontal run of two lines that cross.
/// - `siblings`: the crossings of two lines that leave one card or reach one card.
/// - `overlaps`: two runs of different lines that lie on top of each other.
/// - `sideways`: the columns between parent and child, summed over all lines.
/// - `behind`: lines that pass behind a card that is not their parent or child.
/// - `nearer`: cards whose lines all leave to one side while a free cell lies nearer to them.
Map<String, int> measure(List<LabCard> cards, List<LabLine> lines, RouteMetrics m) {
  final double h = m.height;
  final double colW = m.width + m.gapX;
  final double pitch = h + m.gapY;

  var columnCount = 0;
  for (final LabCard card in cards) {
    if (card.col >= columnCount) {
      columnCount = card.col + 1;
    }
  }
  final columns = List.generate(columnCount, (_) => <LabCard>[]);
  for (final LabCard card in cards) {
    columns[card.col].add(card);
  }
  for (final List<LabCard> column in columns) {
    column.sort((a, b) => a.y.compareTo(b.y));
  }

  /// Whether column [col] has a card other than [a] and [b] between the pixel rows [top] and [bottom].
  bool taken(int col, double top, double bottom, int a, int b) {
    if (col < 0 || col >= columnCount) {
      return false;
    }
    for (final LabCard card in columns[col]) {
      if (card.y >= bottom) {
        break;
      }
      if (card.y + h > top && card.node != a && card.node != b) {
        return true;
      }
    }
    return false;
  }

  var bends = 0;
  var behind = 0;
  final horizontals = <_Run>[];
  final verticals = <_Run>[];
  for (var k = 0; k < lines.length; k++) {
    final LabLine line = lines[k];
    final List<double> p = line.pts;
    bends += p.length ~/ 2 - 2;
    for (var q = 0; q + 3 < p.length; q += 2) {
      final double x0 = p[q];
      final double y0 = p[q + 1];
      final double x1 = p[q + 2];
      final double y1 = p[q + 3];
      if (x0 == x1) {
        final double top = y0 < y1 ? y0 : y1;
        final double bottom = y0 < y1 ? y1 : y0;
        verticals.add(_Run(k, x0, top, bottom));
        // Inside a column's cards, not in the gutter next to it.
        final int col = ((x0 - m.pad) / colW).floor();
        if (x0 - m.pad - col * colW < m.width && taken(col, top, bottom, line.from, line.to)) {
          line.behind = true;
        }
      } else {
        final double left = x0 < x1 ? x0 : x1;
        final double right = x0 < x1 ? x1 : x0;
        horizontals.add(_Run(k, y0, left, right));
        final int firstCol = ((left - m.pad + m.gapX) / colW).floor();
        final int lastCol = ((right - m.pad) / colW).floor();
        for (int col = firstCol < 0 ? 0 : firstCol; col <= lastCol && !line.behind; col++) {
          final double cardLeft = m.pad + col * colW;
          if (cardLeft < right && cardLeft + m.width > left && taken(col, y0, y0, line.from, line.to)) {
            line.behind = true;
          }
        }
      }
    }
    if (line.behind) {
      behind++;
    }
  }

  // Crossings: per vertical run, the horizontal runs between its ends.
  int byPlace(_Run a, _Run b) => a.at != b.at ? a.at.compareTo(b.at) : a.from.compareTo(b.from);
  horizontals.sort(byPlace);
  verticals.sort(byPlace);
  // Overlaps: two runs of different lines on one x or one y that share a stretch.
  var overlaps = 0;
  for (final List<_Run> runs in [horizontals, verticals]) {
    for (var i = 0; i < runs.length; i++) {
      for (int j = i + 1; j < runs.length && runs[j].at == runs[i].at && runs[j].from < runs[i].to; j++) {
        if (runs[j].line != runs[i].line) {
          overlaps++;
        }
      }
    }
  }
  var crossings = 0;
  var siblings = 0;
  for (final _Run v in verticals) {
    var lo = 0;
    var hi = horizontals.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (horizontals[mid].at <= v.from) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (var k = lo; k < horizontals.length && horizontals[k].at < v.to; k++) {
      final _Run r = horizontals[k];
      if (r.line != v.line && r.from < v.at && v.at < r.to) {
        crossings++;
        if (lines[r.line].from == lines[v.line].from || lines[r.line].to == lines[v.line].to) {
          siblings++;
        }
      }
    }
  }

  // Cards with a free cell nearer to their lines.
  final cardOf = <int, LabCard>{for (final LabCard card in cards) card.node: card};
  final least = <int, int>{};
  final most = <int, int>{};
  void note(int node, int col) {
    least[node] = least.containsKey(node) && least[node]! < col ? least[node]! : col;
    most[node] = most.containsKey(node) && most[node]! > col ? most[node]! : col;
  }

  for (final LabLine line in lines) {
    note(line.from, cardOf[line.to]!.col);
    note(line.to, cardOf[line.from]!.col);
  }
  // Sideways: how many columns all lines cross on their way from parent to child.
  var sideways = 0;
  for (final LabLine line in lines) {
    sideways += (cardOf[line.from]!.col - cardOf[line.to]!.col).abs();
  }
  var nearer = 0;
  for (final LabCard card in cards) {
    final int? lo = least[card.node];
    final int? hi = most[card.node];
    if (lo == null || hi == null) {
      continue;
    }
    // A cell is free when no card of that column is less than a pitch away.
    bool cellFree(int col) => !taken(col, card.y - pitch + h, card.y + pitch, card.node, card.node);
    var found = false;
    for (int col = card.col + 1; col < lo && !found; col++) {
      found = cellFree(col);
    }
    for (int col = hi + 1; col < card.col && !found; col++) {
      found = cellFree(col);
    }
    if (found) {
      card.nearer = true;
      nearer++;
    }
  }

  return {
    'columns': columnCount,
    'bends': bends,
    'crossings': crossings,
    'siblings': siblings,
    'overlaps': overlaps,
    'sideways': sideways,
    'behind': behind,
    'nearer': nearer,
  };
}

/// A vertical run ([at] = x, [from] < [to] = its y's) or a horizontal one ([at] = y, [from] < [to] = its x's).
final class _Run {
  _Run(this.line, this.at, this.from, this.to);

  final int line;
  final double at;
  final double from;
  final double to;
}
