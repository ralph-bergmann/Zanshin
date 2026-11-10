import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/router.dart';

import 'scene.dart';

/// The lab's lines (README, steps 1 and 3): one line per parent → child pair, in pixels.
///
/// A line runs in its branch's column: a fork line (to a first parent) climbs the child's column, a
/// merge line the parent's. With [dodge], it turns into the gutter next to that column before the
/// first card in its way and stays there up to the child. Without it the line runs through cards.
///
/// The horizontal run sits right above the parent (fork) or right below the child (merge). With
/// [freeLevels] it moves away from there, as little as it must, to a level where it passes no card;
/// a merge line whose parent's column is taken turns right away if the child's column lets it.
/// With [spread] (and [freeLevels]) the runs that pass side by side between the same cards are put
/// in the order in which they do not cross, and share that room evenly.
///
/// Without [ports] every line leaves the centre of its parent's top edge and enters the centre of
/// its child's bottom edge, and the lines of one card to one side lie on one level. With [ports]
/// the app's rule applies (docs/graph-layout.md §14.3): the line that runs straight keeps the
/// centre, the others fan out, and every line gets a track of its own.
///
/// With [bendAtParent] (and [freeLevels]) a merge line whose parent's branch goes on bends at the
/// parent, if the child's column is free down to there. With [noOverlap] (and [spread]) two lines
/// of neighbouring cards of one column cross somewhere else instead of sharing a stretch of it.
/// With [fewerCrossings] (and [bendAtParent]) a merge line whose child's column is taken bends at
/// the parent too and climbs the gutter next to the child's column, if it then crosses fewer lines.
/// With [columnOrder] (and [fewerCrossings]) it does so too wherever the lines of its parent's top
/// edge would else leave in another order than the columns they go to. With [tightFans] (and
/// [ports]) the lines of one card to one side come closer than 6 px where the room does not hold
/// them all, instead of lying on one level. With [tieBreak] (and [ports]) two lines of different
/// cards that run straight on one x do not share it: one gives up the centre of its card edge.
///
/// The metrics count what still passes behind a card.
List<LabLine> labLines(
  GraphGridView grid,
  List<LabCard?> cardOf,
  RouteMetrics m, {
  required bool dodge,
  required bool freeLevels,
  required bool spread,
  required bool ports,
  required bool bendAtParent,
  required bool noOverlap,
  required bool fewerCrossings,
  required bool columnOrder,
  required bool tightFans,
  required bool tieBreak,
}) {
  final double h = m.height;
  final double colW = m.width + m.gapX;
  final double lift = 0.4 * m.gapY; // how far a horizontal run sits from the card it belongs to
  const clear = 8.0; // how far a horizontal run stays from any other card

  // Per column its cards, top first.
  final columns = <List<LabCard>>[];
  for (final LabCard? card in cardOf) {
    if (card == null) {
      continue;
    }
    while (columns.length <= card.col) {
      columns.add(<LabCard>[]);
    }
    columns[card.col].add(card);
  }
  for (final List<LabCard> column in columns) {
    column.sort((a, b) => a.y.compareTo(b.y));
  }

  /// The first card of column [col] that a line climbing from [from] up to [to] (pixels, from > to)
  /// meets, other than the line's own cards [p] and [c].
  LabCard? blocker(int col, double from, double to, int p, int c) {
    final List<LabCard> column = columns[col];
    for (int k = column.length - 1; k >= 0; k--) {
      final LabCard card = column[k];
      if (card.y >= from || card.node == p || card.node == c) {
        continue;
      }
      return card.y + h > to ? card : null;
    }
    return null;
  }

  /// The level nearest to [start], between [start] and [end] (pixels, either order), at which a
  /// horizontal run over the columns [c0] … [c1] passes no card but [p] and [c]; null without one.
  ///
  /// shortcut: scans every card of each column per step; a binary search per column would do if a
  /// measurement ever shows it.
  double? freeLevel(int c0, int c1, double start, double end, int p, int c) {
    final bool down = end > start;
    var level = start;
    for (var moved = true; moved;) {
      moved = false;
      for (var col = c0; col <= c1 && col < columns.length; col++) {
        for (final LabCard card in columns[col]) {
          if (card.node != p && card.node != c && card.y - clear < level && level < card.y + h + clear) {
            level = down ? card.y + h + clear : card.y - clear;
            moved = true;
          }
        }
      }
      if (down ? level > end : level < end) {
        return null;
      }
    }
    return level;
  }

  /// The free band around [level] for a run over the columns [c0] … [c1]: from the nearest card
  /// above it to the nearest card below it, no further than [lo] and [hi] (pixels, lo < hi).
  (double, double) band(int c0, int c1, double level, double lo, double hi, int p, int c) {
    var top = lo;
    var bottom = hi;
    for (var col = c0; col <= c1 && col < columns.length; col++) {
      for (final LabCard card in columns[col]) {
        if (card.node == p || card.node == c) {
          continue;
        }
        if (card.y + h <= level && card.y + h > top) {
          top = card.y + h;
        }
        if (card.y >= level && card.y < bottom) {
          bottom = card.y;
        }
      }
    }
    return (top, bottom);
  }

  double centre(int col) => m.pad + col * colW + m.width / 2;

  /// The x of the gutter next to column [col] on [side] (−1 left, 1 right).
  double gutter(int col, int side) => m.pad + (side > 0 ? col : col - 1) * colW + m.width + m.gapX / 2;

  final lines = <LabLine>[];
  final gutterRuns = <_GutterRun>[];
  final levelRuns = <_LevelRun>[];
  final detours = <_Detour>[];
  // The cards whose branch goes on: a first-parent child sits in their column.
  final goesOn = <int>{
    for (var k = 0; k < grid.edgeCount; k++)
      if ((k == 0 || grid.edgeTos[k - 1] != grid.edgeTos[k]) &&
          cardOf[grid.edgeFroms[k]]!.col == cardOf[grid.edgeTos[k]]!.col)
        grid.edgeFroms[k],
  };
  for (var k = 0; k < grid.edgeCount; k++) {
    final int p = grid.edgeFroms[k];
    final int c = grid.edgeTos[k];
    final LabCard parent = cardOf[p]!;
    final LabCard child = cardOf[c]!;
    final first = k == 0 || grid.edgeTos[k - 1] != c;
    final double ax = centre(parent.col);
    final double ay = parent.y;
    final double bx = centre(child.col);
    final double by = child.y + h;
    final double above = ay - lift; // the run right above the parent
    final double below = by + lift; // the run right below the child
    final List<double> pts;

    /// The line's end once a card blocks column [col]: through the gutter on [side], from [turn] up.
    List<double> around(int col, int side, double turn) {
      final double gx = gutter(col, side);
      gutterRuns.add(_GutterRun(lines.length, 2 * col + side, below, turn));
      return [gx, turn, gx, below, bx, below, bx, by];
    }

    /// A free level for a run over the columns [c0] … [c1] in the room between [upper] and [lower],
    /// the edges of the cards above and below it (pixels): the one nearest to [wish] on its way [up]
    /// or down, else the nearest on the other side. It keeps [clear] from both edges, so a run may
    /// come nearer to its own card than [lift] where nothing else is free. Null without one.
    double? seek(int c0, int c1, double wish, double upper, double lower, {required bool up}) {
      final double first = upper + clear;
      final double last = lower - clear;
      if (first > last) {
        return null;
      }
      final double start = wish < first ? first : (wish > last ? last : wish);
      return freeLevel(c0, c1, start, up ? first : last, p, c) ?? freeLevel(c0, c1, start, up ? last : first, p, c);
    }

    if (parent.col == child.col) {
      final LabCard? card = dodge ? blocker(parent.col, ay, by, p, c) : null;
      pts = card == null
          ? [ax, ay, bx, by]
          : [ax, ay, ax, card.y + h + lift, ...around(parent.col, 1, card.y + h + lift)];
    } else if (first) {
      final int side = parent.col > child.col ? 1 : -1;
      var level = above;
      (double, double)? free; // the run's band, once a free level is found
      if (freeLevels) {
        // The run may climb the parent's column up to that column's next card, and no higher than the child.
        final LabCard? next = blocker(parent.col, ay, double.negativeInfinity, p, c);
        final double upper = next == null || next.y + h < by ? by : next.y + h;
        final int c0 = child.col > parent.col ? parent.col + 1 : child.col;
        final int c1 = child.col > parent.col ? child.col : parent.col - 1;
        final double? found = seek(c0, c1, above, upper, ay, up: true);
        if (found != null) {
          level = found;
          free = band(c0, c1, level, upper, ay, p, c);
        }
      }
      final LabCard? card = dodge ? blocker(child.col, level, by, p, c) : null;
      if (card == null) {
        pts = [ax, ay, ax, level, bx, level, bx, by];
        if (free != null) {
          levelRuns.add(_LevelRun(lines.length, p, c, ax, bx, level, free.$1, free.$2, merge: false, lift: lift));
        }
      } else if (card.y + h + lift > level) {
        // The card reaches down to the horizontal run: the column cannot be entered at all.
        pts = [ax, ay, ax, level, ...around(child.col, side, level)];
      } else {
        pts = [ax, ay, ax, level, bx, level, bx, card.y + h + lift, ...around(child.col, side, card.y + h + lift)];
      }
    } else {
      final int side = child.col > parent.col ? 1 : -1;
      final LabCard? card = dodge ? blocker(parent.col, ay, below, p, c) : null;
      double? level;
      if (freeLevels) {
        // The run may sit anywhere between the card that blocks the parent's column and the child's
        // column's next card below the child.
        LabCard? under;
        for (final LabCard o in columns[child.col]) {
          if (o.y > child.y && o.node != p) {
            under = o;
            break;
          }
        }
        final double upper = card == null ? by : card.y + h;
        final double lower = under == null || under.y > ay ? ay : under.y;
        final int c0 = (child.col > parent.col ? parent.col : child.col) + 1;
        final int c1 = (child.col > parent.col ? child.col : parent.col) - 1;
        // A merge line bends at its child, and its long stretch climbs the parent's column: the
        // branch that ends there. With [bendAtParent], where the parent's branch goes on and the
        // child's column is free down to the parent, the line bends at the parent like a fork line
        // and climbs the child's column instead. So every line of the parent's top edge bends at the
        // card, and their tracks and ports follow the order of their children.
        final bool atParent = bendAtParent && goesOn.contains(p) && (under == null || under.y > ay);
        // Where the child's column is taken, the line can bend at the parent all the same and climb
        // the gutter next to the child's column. Whether it does is decided below, once every line
        // has its usual shape: only if that saves crossings ([fewerCrossings]).
        if (fewerCrossings && bendAtParent && goesOn.contains(p) && !atParent) {
          final double? at = seek(c0, c1, ay - lift, upper, ay, up: true);
          // Only where the line climbs the gutter past at least one row of cards: between two
          // neighbouring rows the detour would be a zigzag. Its run stays below the gutter's top.
          if (at != null && at - below >= h + m.gapY) {
            final (double top, double hi) = band(c0, c1, at, upper, ay, p, c);
            final double lo = top > below + clear ? top : below + clear;
            final double gx = gutter(child.col, -side);
            detours.add(
              _Detour(
                [ax, ay, ax, at, gx, at, gx, below, bx, below, bx, by],
                _LevelRun(lines.length, p, c, ax, gx, at, lo, hi, merge: false, lift: lift),
                _GutterRun(lines.length, 2 * child.col - side, below, at),
              ),
            );
          }
        }
        level = atParent
            ? seek(c0, c1, lower - lift, upper, lower, up: true)
            : seek(c0, c1, upper + lift, upper, lower, up: false);
        // Above `below` the line climbs further up the parent's column than [card] was looked for.
        if (level != null && level < below && blocker(parent.col, ay, level, p, c) != null) {
          level = null;
        }
        if (level != null) {
          final (double lo, double hi) = band(c0, c1, level, upper, lower, p, c);
          levelRuns.add(_LevelRun(lines.length, p, c, ax, bx, level, lo, hi, merge: !atParent, lift: lift));
        }
      }
      if (level != null) {
        pts = [ax, ay, ax, level, bx, level, bx, by];
      } else {
        pts = card == null
            ? [ax, ay, ax, below, bx, below, bx, by]
            : [ax, ay, ax, card.y + h + lift, ...around(parent.col, side, card.y + h + lift)];
      }
    }
    lines.add(LabLine(edge: k, from: p, to: c, pts: pts, dashed: grid.edgeKinds[k] == GraphGridView.edgeKindIndirect));
  }

  // A line takes its detour through the gutter if it then crosses fewer lines; on a tie it keeps
  // its usual shape, which has two bends less. Counted on the shapes before tracks and ports.
  //
  // shortcut: compares the line with every other line; an index of the runs would do if a
  // measurement ever shows it.
  int crossings(List<double> p, int self) {
    var count = 0;
    for (var o = 0; o < lines.length; o++) {
      if (o == self) {
        continue;
      }
      final List<double> q = lines[o].pts;
      for (var i = 0; i + 3 < p.length; i += 2) {
        for (var j = 0; j + 3 < q.length; j += 2) {
          // One run upright, the other level: they cross if each passes strictly through the other.
          final bool upright = p[i] == p[i + 2];
          if (upright == (q[j] == q[j + 2])) {
            continue;
          }
          final List<double> v = upright ? p : q;
          final List<double> w = upright ? q : p;
          final int a = upright ? i : j;
          final int b = upright ? j : i;
          final double top = v[a + 1] < v[a + 3] ? v[a + 1] : v[a + 3];
          final double bottom = v[a + 1] < v[a + 3] ? v[a + 3] : v[a + 1];
          final double left = w[b] < w[b + 2] ? w[b] : w[b + 2];
          final double right = w[b] < w[b + 2] ? w[b + 2] : w[b];
          if (left < v[a] && v[a] < right && top < w[b + 1] && w[b + 1] < bottom) {
            count++;
          }
        }
      }
    }
    return count;
  }

  void take(_Detour detour) {
    final int i = detour.run.line;
    lines[i].pts
      ..clear()
      ..addAll(detour.pts);
    levelRuns
      ..removeWhere((r) => r.line == i)
      ..add(detour.run);
    gutterRuns
      ..removeWhere((r) => r.line == i)
      ..add(detour.gutter);
  }

  final open = <_Detour>[]; // the detours not taken
  for (final _Detour detour in detours) {
    final int i = detour.run.line;
    if (crossings(detour.pts, i) < crossings(lines[i].pts, i)) {
      take(detour);
    } else {
      open.add(detour);
    }
  }

  if (columnOrder) {
    // The ports of a card edge follow how far each line runs straight: the longest innermost. So a
    // line is out of column order if a line of its card to the same side goes to a nearer column
    // but turns nearer to the card. Such a line takes its detour whatever it crosses; that changes
    // where it turns, so the pass repeats until nothing moves.
    final exits = <int, List<int>>{};
    for (var i = 0; i < lines.length; i++) {
      (exits[lines[i].from] ??= []).add(i);
    }
    bool outOfOrder(int i) {
      final int col = cardOf[lines[i].from]!.col;
      final int far = cardOf[lines[i].to]!.col - col;
      return exits[lines[i].from]!.any((j) {
        final int near = cardOf[lines[j].to]!.col - col;
        return near.sign == far.sign && near.abs() < far.abs() && lines[j].pts[3] > lines[i].pts[3];
      });
    }

    for (var moved = true; moved;) {
      moved = false;
      for (final _Detour detour in [...open]) {
        if (outOfOrder(detour.run.line)) {
          take(detour);
          open.remove(detour);
          moved = true;
        }
      }
    }
  }

  if (spread) {
    // Clusters: runs that pass side by side through each other's band.
    //
    // shortcut: compares every pair of runs; an index by level would do if a measurement ever shows it.
    final int n = levelRuns.length;
    final root = List<int>.generate(n, (i) => i);
    int find(int x) {
      while (root[x] != x) {
        x = root[x] = root[root[x]];
      }
      return x;
    }

    for (var i = 0; i < n; i++) {
      final _LevelRun a = levelRuns[i];
      for (int j = i + 1; j < n; j++) {
        final _LevelRun b = levelRuns[j];
        if (a.left < b.right &&
            b.left < a.right &&
            ((a.lo < b.level && b.level < a.hi) || (b.lo < a.level && a.level < b.hi))) {
          root[find(i)] = find(j);
        }
      }
    }
    final clusters = <int, List<_LevelRun>>{};
    for (var i = 0; i < n; i++) {
      (clusters[find(i)] ??= []).add(levelRuns[i]);
    }

    // Two runs that leave one card, or reach one card, on the same side: with ports they get tracks
    // 6 px apart, without ports one level.
    bool siblings(_LevelRun a, _LevelRun b) => (a.up > a.down) == (b.up > b.down) && (a.from == b.from || a.to == b.to);
    final double track = ports ? 6 : 0;

    for (final List<_LevelRun> cluster in clusters.values) {
      // A run's line goes down at its parent's end and up at its child's end. So run a must lie
      // above run b if a spans b's parent end or b spans a's child end: else the two cross. Order
      // the cluster by that; where nothing decides, the run that wants to sit higher comes first.
      // With [noOverlap], a run that enters a column where another leaves it lies above that one
      // too: else the two lines share a stretch of that column, which hides a crossing.
      bool above(_LevelRun a, _LevelRun b) =>
          (a.left < b.down && b.down < a.right) || (b.left < a.up && a.up < b.right) || (noOverlap && a.up == b.down);
      final List<_LevelRun> rest = [...cluster]
        ..sort((a, b) => a.wish != b.wish ? a.wish.compareTo(b.wish) : a.line.compareTo(b.line));
      final order = <_LevelRun>[];
      while (rest.isNotEmpty) {
        // The first run that no other remaining run must lie above; a pair that crosses either way
        // decides nothing. In a cycle the run that wants to sit highest goes first.
        final _LevelRun next = rest.firstWhere(
          (a) => !rest.any((b) => !identical(a, b) && above(b, a) && !above(a, b)),
          orElse: () => rest.first,
        );
        rest.remove(next);
        order.add(next);
      }

      // Two runs keep a distance only where they pass side by side through bands that overlap.
      bool meet(_LevelRun a, _LevelRun b) => a.left < b.right && b.left < a.right && a.lo < b.hi && b.lo < a.hi;
      // A run's even share of its band: the band over the runs it meets, plus one. At most [lift].
      final share = <double>[
        for (final _LevelRun a in order)
          () {
            final int others = order.where((b) => !identical(a, b) && meet(a, b) && !siblings(a, b)).length;
            final double even = (a.hi - a.lo) / (others + 2);
            return even < lift ? even : lift;
          }(),
      ];
      // A fan with more lines than its room holds at 6 px: with [tightFans] its lines share that
      // room evenly instead of lying on one level. The room of a line and the lines of its fan
      // above it ends at the lowest of their band tops; all of them come as close as it needs.
      final tight = List<double>.filled(order.length, track);
      if (tightFans && track > 0) {
        for (var k = 0; k < order.length; k++) {
          final _LevelRun run = order[k];
          final List<int> fan = [
            for (var j = 0; j < k; j++)
              if (siblings(order[j], run) && meet(order[j], run)) j,
            k,
          ];
          var top = run.lo;
          for (final int j in fan) {
            top = order[j].lo > top ? order[j].lo : top;
          }
          final double room = run.hi - top - 2;
          if (room > 0 && (fan.length - 1) * track + share[k] > room) {
            for (final int j in fan) {
              tight[j] = room / fan.length < tight[j] ? room / fan.length : tight[j];
            }
          }
        }
        for (var k = 0; k < order.length; k++) {
          share[k] = tight[k] < share[k] ? tight[k] : share[k];
        }
      }
      double sep(int j, int k) => siblings(order[j], order[k])
          ? (tight[j] < tight[k] ? tight[j] : tight[k])
          : (share[j] < share[k] ? share[j] : share[k]);

      // Every run sits where it wants to, unless the order pushes it: first down, then back up.
      final levels = <double>[];
      for (var k = 0; k < order.length; k++) {
        final _LevelRun run = order[k];
        var y = run.wish > run.lo + share[k] ? run.wish : run.lo + share[k];
        for (var j = 0; j < k; j++) {
          if (meet(order[j], run) && levels[j] + sep(j, k) > y) {
            y = levels[j] + sep(j, k);
          }
        }
        levels.add(y);
      }
      for (int k = order.length - 1; k >= 0; k--) {
        final _LevelRun run = order[k];
        var y = levels[k] < run.hi - share[k] ? levels[k] : run.hi - share[k];
        for (int j = k + 1; j < order.length; j++) {
          if (meet(run, order[j]) && levels[j] - sep(k, j) < y) {
            y = levels[j] - sep(k, j);
          }
        }
        // Whatever the pushes did, a run never leaves its band: there it passes no card.
        if (run.hi - run.lo > 4) {
          y = y < run.lo + 2 ? run.lo + 2 : (y > run.hi - 2 ? run.hi - 2 : y);
        }
        levels[k] = y;
        // The horizontal run is the 2nd and 3rd point of a line with two bends.
        lines[run.line].pts[3] = lines[run.line].pts[5] = y;
      }
    }
  }

  if (ports) {
    // Per card edge: one line sits at the centre; of several, the one that stays straight longest
    // does, if it runs at least a row gap before it turns, else the centre stays free. The others
    // fan out to the side they turn to, the one that turns nearest to the card outermost.
    final exits = <int, List<int>>{};
    final entries = <int, List<int>>{};
    for (var i = 0; i < lines.length; i++) {
      (exits[lines[i].from] ??= []).add(i);
      (entries[lines[i].to] ??= []).add(i);
    }
    final double fanMax = m.width / 2 - 18;
    double fan(int k, int count) {
      final double step = count < 2 ? 16 : ((fanMax - 24) / (count - 1) < 16 ? (fanMax - 24) / (count - 1) : 16);
      if (step >= 8) {
        return 24 + k * step;
      }
      final int most = (fanMax - 24) ~/ 8; // the overflow shares the outermost port
      return 24 + (k < most ? k : most) * 8;
    }

    // The lines that gave up the centre of a card edge to a line of another card ([tieBreak]).
    final off = <(int, bool)>{};
    void place(List<int> edge, {required bool exit}) {
      if (edge.length < 2 && !off.contains((edge.first, exit))) {
        return;
      }
      double reach(int i) {
        final List<double> p = lines[i].pts;
        return p.length == 4 ? double.infinity : (exit ? p[1] - p[3] : p[p.length - 3] - p[p.length - 1]);
      }

      bool toRight(int i) {
        final List<double> p = lines[i].pts;
        return p.length == 4 || (exit ? p[4] > p[2] : p[p.length - 6] > p[p.length - 4]);
      }

      // Lines that turn on one level share it: with [columnOrder] the nearer column sits further in.
      int away(int i) => columnOrder ? (cardOf[lines[i].to]!.col - cardOf[lines[i].from]!.col).abs() : 0;
      edge.sort(
        (a, b) => reach(a) != reach(b)
            ? reach(b).compareTo(reach(a))
            : (away(a) != away(b) ? away(a).compareTo(away(b)) : a.compareTo(b)),
      );
      final int middle = reach(edge.first) >= m.gapY && !off.contains((edge.first, exit)) ? edge.first : -1;
      for (final right in [false, true]) {
        final List<int> side = [
          for (final int i in edge)
            if (i != middle && toRight(i) == right) i,
        ];
        for (var k = 0; k < side.length; k++) {
          final List<double> p = lines[side[k]].pts;
          final double shift = (right ? 1 : -1) * fan(k, side.length);
          if (p.length == 4) {
            continue; // a straight line through a card (only without `dodge`): it keeps the centre
          }
          if (exit) {
            p[0] += shift;
            p[2] += shift;
          } else {
            p[p.length - 4] += shift;
            p[p.length - 2] += shift;
          }
        }
      }
    }

    exits.values.forEach((edge) => place(edge, exit: true));
    entries.values.forEach((edge) => place(edge, exit: false));

    // The engine's column tie-break (docs/graph-layout.md §14, Ports): two lines of different cards
    // never share an x where they run straight from their card edges. The one that stays straight
    // longer keeps its port; the other gives up the centre and joins its side's fan. That moves
    // ports, so the pass repeats until nothing moves (at most 8 times, as in the engine).
    //
    // shortcut: a loser that is not at the centre stays where it is; the engine moves it one fan
    // slot further out. No data set has such a pair.
    if (tieBreak) {
      for (var pass = 0; pass < 8; pass++) {
        // Per x, the straight stretches at card edges: top, bottom, line, whether it is the exit.
        final byX = <double, List<(double, double, int, bool)>>{};
        for (var i = 0; i < lines.length; i++) {
          final List<double> p = lines[i].pts;
          (byX[p[0]] ??= []).add((p[3], p[1], i, true));
          if (p.length > 4) {
            (byX[p[p.length - 2]] ??= []).add((p.last, p[p.length - 3], i, false));
          }
        }
        final losers = <(int, bool)>{};
        for (final List<(double, double, int, bool)> stretches in byX.values) {
          // Top first: a stretch only meets the ones that start before it ends (the main branch's
          // column holds thousands that never meet).
          stretches.sort((a, b) => a.$1.compareTo(b.$1));
          for (var a = 0; a < stretches.length; a++) {
            final (double top, double bottom, int line, bool exit) = stretches[a];
            for (int b = a + 1; b < stretches.length && stretches[b].$1 < bottom; b++) {
              final (double top2, double bottom2, int line2, bool exit2) = stretches[b];
              if (line == line2 || top >= bottom2) {
                continue;
              }
              final bool first = bottom - top != bottom2 - top2 ? bottom - top < bottom2 - top2 : line > line2;
              final (int, bool) loser = first ? (line, exit) : (line2, exit2);
              if (lines[loser.$1].pts.length > 4 && !off.contains(loser)) {
                losers.add(loser);
              }
            }
          }
        }
        if (losers.isEmpty) {
          break;
        }
        off.addAll(losers);
        for (final (int i, bool exit) in losers) {
          final List<int> edge = exit ? exits[lines[i].from]! : entries[lines[i].to]!;
          // Back to the centre, then place the edge's lines again.
          for (final int j in edge) {
            final List<double> p = lines[j].pts;
            final double x = centre(cardOf[exit ? lines[j].from : lines[j].to]!.col);
            if (p.length > 4 && exit) {
              p[0] = p[2] = x;
            } else if (p.length > 4) {
              p[p.length - 4] = p[p.length - 2] = x;
            }
          }
          place(edge, exit: exit);
        }
      }
    }
  }

  // Lines that share a gutter over the same stretch sit 6 px apart: 0, +6, −6, +12, …
  gutterRuns.sort((a, b) => a.gutter != b.gutter ? a.gutter.compareTo(b.gutter) : a.top.compareTo(b.top));
  final taken = <List<_GutterRun>>[];
  int? current;
  for (final _GutterRun run in gutterRuns) {
    if (run.gutter != current) {
      current = run.gutter;
      taken.clear();
    }
    var slot = 0;
    while (slot < taken.length && taken[slot].any((o) => o.top < run.bottom && run.top < o.bottom)) {
      slot++;
    }
    if (slot == taken.length) {
      taken.add(<_GutterRun>[]);
    }
    taken[slot].add(run);
    final double shift = (slot.isOdd ? 6.0 : -6.0) * ((slot + 1) ~/ 2);
    final List<double> pts = lines[run.line].pts;
    // The gutter's two points are the 4th and 3rd from the end ([around]).
    pts[pts.length - 8] += shift;
    pts[pts.length - 6] += shift;
  }
  return lines;
}

/// The horizontal run of a line with two bends, from card [from] up to card [to]: on [level],
/// between the x of its parent's end [down] and of its child's end [up], free between [lo] and [hi]
/// (pixels). [wish] is where it sits when nothing is in its way: [lift] below the band's top for a
/// merge run, above its bottom for a fork run, or in the middle of a narrow band.
final class _LevelRun {
  _LevelRun(
    this.line,
    this.from,
    this.to,
    this.down,
    this.up,
    this.level,
    this.lo,
    this.hi, {
    required bool merge,
    required double lift,
  }) : wish = merge
           ? lo + (lift < (hi - lo) / 2 ? lift : (hi - lo) / 2)
           : hi - (lift < (hi - lo) / 2 ? lift : (hi - lo) / 2);

  final int line;
  final int from;
  final int to;
  final double down;
  final double up;
  final double level;
  final double lo;
  final double hi;
  final double wish;

  double get left => down < up ? down : up;
  double get right => down < up ? up : down;
}

/// Another shape for a merge line: it bends at its parent, runs to the gutter next to its child's
/// column and climbs there. [pts] are its points, [run] and [gutter] its two stretches.
final class _Detour {
  _Detour(this.pts, this.run, this.gutter);

  final List<double> pts;
  final _LevelRun run;
  final _GutterRun gutter;
}

/// One line's stretch in a gutter: [top] < [bottom] in pixels; [gutter] is 2·column ± 1.
final class _GutterRun {
  _GutterRun(this.line, this.gutter, this.top, this.bottom);

  final int line;
  final int gutter;
  final double top;
  final double bottom;
}
