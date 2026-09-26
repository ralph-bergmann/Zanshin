import 'dart:typed_data';

/// Windowed-sifting constants (SPEC §4.6).
const int siftWindow = 8; // K
const int siftRounds = 4; // R
const int siftBudget = 2000000; // BUDGET

/// The `optimized` lane order (SPEC §4.6): an integer cost model over horizontals and verticals,
/// evaluated incrementally one adjacent-column swap at a time.
///
/// cost(π) = 400·X + 4·Len + Disp. Horizontal h joins lanes [hA] and [hB] at tick [hLevel];
/// the verticals of lane ℓ are `vStart[ℓ] ..< vStart[ℓ + 1]`, with [vLo] and [vHi] each sorted.
final class LaneSifter {
  LaneSifter({
    required this.laneCount,
    required this.hA,
    required this.hB,
    required this.hLevel,
    required this.vStart,
    required this.vLo,
    required this.vHi,
  }) : pos = Int32List(laneCount),
       inv = Int32List(laneCount),
       incStart = Int32List(laneCount + 1),
       incOther = Int32List(2 * hA.length),
       incLevel = Int64List(2 * hA.length) {
    for (var l = 0; l < laneCount; l++) {
      pos[l] = l;
      inv[l] = l;
    }
    // Horizontals incident to each lane (CSR), ascending by horizontal index; each incidence
    // stores the horizontal's other endpoint lane and its level.
    final hCount = hA.length;
    for (var h = 0; h < hCount; h++) {
      incStart[hA[h] + 1]++;
      incStart[hB[h] + 1]++;
    }
    for (var l = 0; l < laneCount; l++) {
      incStart[l + 1] += incStart[l];
    }
    final cursor = Int32List.fromList(incStart);
    for (var h = 0; h < hCount; h++) {
      final a = hA[h], b = hB[h], level = hLevel[h];
      var s = cursor[a]++;
      incOther[s] = b;
      incLevel[s] = level;
      s = cursor[b]++;
      incOther[s] = a;
      incLevel[s] = level;
    }
  }

  final int laneCount;
  final Int32List hA;
  final Int32List hB;
  final Int64List hLevel;
  final Int32List vStart;
  final Int64List vLo;
  final Int64List vHi;

  /// π: lane → column.
  final Int32List pos;

  /// π⁻¹: column → lane.
  final Int32List inv;

  /// Per lane ℓ, its incident horizontals are `incStart[ℓ] ..< incStart[ℓ + 1]`.
  final Int32List incStart;

  /// Per incidence: the horizontal's other endpoint lane, and its level.
  final Int32List incOther;
  final Int64List incLevel;

  /// h(ℓ): the number of horizontals with an endpoint in lane ℓ.
  @pragma('vm:prefer-inline') // the Rust twin is #[inline] too
  int h(int lane) => incStart[lane + 1] - incStart[lane];

  /// m(ℓ, λ) = #{lo < λ} − #{hi ≤ λ} over lane ℓ's verticals.
  @pragma('vm:prefer-inline')
  int m(int lane, int level) {
    final vLo = this.vLo, vHi = this.vHi;
    final start = vStart[lane], end = vStart[lane + 1];
    var lo = start, hi = end;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (vLo[mid] < level) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final below = lo - start;
    lo = start;
    hi = end;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (vHi[mid] <= level) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return below - (lo - start);
  }

  /// Cost change of swapping columns k (lane P) and k + 1 (lane Q); π itself is unchanged.
  int swapDelta(int k) {
    final p = inv[k], q = inv[k + 1];
    final incStart = this.incStart, incOther = this.incOther, incLevel = this.incLevel, pos = this.pos;
    var dx = 0, dlen = 0;
    // The other endpoint's column is never k or k + 1 (those are P and Q themselves).
    for (var s = incStart[p]; s < incStart[p + 1]; s++) {
      final o = incOther[s];
      if (o == q) continue;
      final mq = m(q, incLevel[s]);
      if (pos[o] > k + 1) {
        dx -= mq;
        dlen -= 1;
      } else {
        dx += mq;
        dlen += 1;
      }
    }
    for (var s = incStart[q]; s < incStart[q + 1]; s++) {
      final o = incOther[s];
      if (o == p) continue;
      final mp = m(p, incLevel[s]);
      if (pos[o] < k) {
        dx -= mp;
        dlen -= 1;
      } else {
        dx += mp;
        dlen += 1;
      }
    }
    final ddisp = (k + 1 - p).abs() + (k - q).abs() - (k - p).abs() - (k + 1 - q).abs();
    return 400 * dx + 4 * dlen + ddisp;
  }

  /// Swaps the lanes in columns k and k + 1.
  void swapColumns(int k) {
    final p = inv[k], q = inv[k + 1];
    inv[k] = q;
    inv[k + 1] = p;
    pos[q] = k;
    pos[p] = k + 1;
  }

  /// Moves the lane in column [from] to column [to], shifting the columns in between.
  void moveColumn(int from, int to) {
    if (to > from) {
      for (var k = from; k < to; k++) {
        swapColumns(k);
      }
    } else {
      for (var k = from - 1; k >= to; k--) {
        swapColumns(k);
      }
    }
  }

  /// The windowed sifting search; leaves the result in [pos] / [inv].
  void run() {
    final lanes = laneCount;
    if (lanes <= 2) return;
    final siftOrder = Int32List(lanes - 1);
    for (var l = 1; l < lanes; l++) {
      siftOrder[l - 1] = l;
    }
    siftOrder.sort((a, b) {
      final ha = h(a), hb = h(b);
      if (ha != hb) return hb - ha;
      return a - b;
    });

    var spent = 0;
    for (var round = 0; round < siftRounds; round++) {
      var moved = false;
      for (final a in siftOrder) {
        final c = pos[a];
        final lo = c - siftWindow > 1 ? c - siftWindow : 1;
        final hi = c + siftWindow < lanes - 1 ? c + siftWindow : lanes - 1;
        final ha = h(a);
        var work = 0;
        for (var column = lo; column <= hi; column++) {
          final b = inv[column];
          if (b != a) work += ha + h(b);
        }
        if (spent + work > siftBudget) return;
        spent += work;

        // d* = argmin (D(d), |d − c|, d); d = c has D = 0.
        var bestD = 0, bestDist = 0, bestCol = c;
        var d = 0;
        for (var k = c; k < hi; k++) {
          d += swapDelta(k);
          swapColumns(k);
          final column = k + 1, dist = column - c;
          if (d < bestD || (d == bestD && (dist < bestDist || (dist == bestDist && column < bestCol)))) {
            bestD = d;
            bestDist = dist;
            bestCol = column;
          }
        }
        for (var k = hi - 1; k >= c; k--) {
          swapColumns(k);
        }
        d = 0;
        for (var k = c - 1; k >= lo; k--) {
          d += swapDelta(k);
          swapColumns(k);
          final column = k, dist = c - column;
          if (d < bestD || (d == bestD && (dist < bestDist || (dist == bestDist && column < bestCol)))) {
            bestD = d;
            bestDist = dist;
            bestCol = column;
          }
        }
        for (var k = lo; k < c; k++) {
          swapColumns(k);
        }
        if (bestD < 0) {
          moveColumn(c, bestCol);
          moved = true;
        }
      }
      if (!moved) return;
    }
  }
}
