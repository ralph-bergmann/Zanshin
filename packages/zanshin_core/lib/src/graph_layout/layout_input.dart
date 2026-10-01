// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'layout_request.dart';

/// A `direct` parent in [LayoutInput.parKind] (docs/graph-layout.md §2).
const parentDirect = 0;

/// An `indirect` parent in [LayoutInput.parKind].
const parentIndirect = 1;

/// A `missing` parent in [LayoutInput.parKind]; its [LayoutInput.parIdx] is −1.
const parentMissing = 2;

/// 2^53: every integer of an input lies in [−2^53, 2^53] (docs/graph-layout.md §1).
const maxSafeInt = 9007199254740992;

/// |utcOffsetMin| ≤ one day (docs/graph-layout.md §2 V4).
const maxUtcOffsetMin = 1440;

/// The layout engine's input (docs/graph-layout.md §2) as flat typed arrays (§8.3): per node its
/// timestamp, root flag and priority class, and every parent — `missing` ones included — in CSR
/// form. `now_ms` is not part of it: no shipped mode reads it (§12).
final class LayoutInput {
  /// An input of `ts.length` nodes; [validateLayoutInput] checks the values.
  LayoutInput({
    required this.utcOffsetMin,
    required this.ts,
    required this.hasTs,
    required this.isRoot,
    required this.priority,
    required this.parStart,
    required this.parIdx,
    required this.parKind,
  }) : n = ts.length;

  /// The viewer's fixed UTC offset in minutes for calendar days (D7); read by `free` only.
  final int utcOffsetMin;

  /// The node count.
  final int n;

  /// Each node's committer timestamp in epoch ms; meaningful only where [hasTs] is 1.
  final Int64List ts;

  /// 1 where the node has a timestamp, 0 where it has none (`ts_ms` null).
  final Uint8List hasTs;

  /// 1 for the repository's root commit.
  final Uint8List isRoot;

  /// Each node's ordering class (§11.2), 0 ≤ priority < 2^31; lower packs further left.
  final Int32List priority;

  /// Node i's parents are `parStart[i] ..< parStart[i + 1]`, in jj's stream order (n + 1 entries).
  final Int32List parStart;

  /// Each parent's target node index, −1 for a `missing` parent.
  final Int32List parIdx;

  /// Each parent's kind: [parentDirect], [parentIndirect] or [parentMissing].
  final Uint8List parKind;
}

/// Checks [input] against docs/graph-layout.md §2 V1–V4 and throws a [LayoutContractException]
/// naming the first rule it breaks: V4 for the offset, then per node in index order V4 for its
/// timestamp and priority and V1, V2, V3 for each parent in order.
void validateLayoutInput(LayoutInput input) {
  final int n = input.n;
  final int offset = input.utcOffsetMin;
  if (offset < -maxUtcOffsetMin || offset > maxUtcOffsetMin) {
    throw LayoutContractException('V4', 'utcOffsetMin $offset is not within ±$maxUtcOffsetMin');
  }
  final Int64List ts = input.ts;
  final Uint8List hasTs = input.hasTs;
  final Int32List priority = input.priority;
  final Int32List parStart = input.parStart;
  final Int32List parIdx = input.parIdx;
  final Uint8List parKind = input.parKind;
  // V3: seen[idx] == i + 1 ⇔ node i already has a parent with target idx.
  final seen = Int32List(n);
  for (var i = 0; i < n; i++) {
    if (hasTs[i] != 0 && (ts[i] > maxSafeInt || ts[i] < -maxSafeInt)) {
      throw LayoutContractException('V4', 'node $i: timestamp ${ts[i]} is not within ±2^53');
    }
    // An Int32List cannot hold 2^31 or more: such a class wraps to a negative value.
    if (priority[i] < 0) {
      throw LayoutContractException('V4', 'node $i: priority ${priority[i]} is not within [0, 2^31)');
    }
    for (int k = parStart[i]; k < parStart[i + 1]; k++) {
      final int idx = parIdx[k];
      final int kind = parKind[k];
      if (kind > parentMissing) {
        throw LayoutContractException('V1', 'node $i: parent $k has the unknown kind $kind');
      }
      if ((idx == -1) != (kind == parentMissing)) {
        throw LayoutContractException('V1', 'node $i: parent $k has target $idx with kind $kind');
      }
      if (idx == -1) {
        continue;
      }
      if (idx <= i || idx >= n) {
        throw LayoutContractException('V2', 'node $i: parent target $idx is not in ($i, $n)');
      }
      if (seen[idx] == i + 1) {
        throw LayoutContractException('V3', 'node $i: parent target $idx is repeated');
      }
      seen[idx] = i + 1;
    }
  }
}
