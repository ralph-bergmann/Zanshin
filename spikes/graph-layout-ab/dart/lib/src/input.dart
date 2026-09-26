import 'dart:convert';
import 'dart:typed_data';

/// Edge kinds, as stored in [LayoutInput.parKind] (SPEC §2).
const int kindDirect = 0;
const int kindIndirect = 1;
const int kindMissing = 2;
const List<String> kindNames = ['direct', 'indirect', 'missing'];

/// 2^53: every integer in input and output lies in [−2^53, 2^53] (SPEC §1).
const int maxSafeInt = 9007199254740992;

/// |utc_offset_min| ≤ one day (SPEC §2 V4, clarified during diff).
const int maxUtcOffsetMin = 1440;

/// Invalid input (SPEC §2 V1–V4, or malformed JSON). The CLI maps it to exit code 2.
final class InputError implements Exception {
  InputError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The parsed input as flat arrays (SPEC §8.3): per node ts / is_root / priority,
/// and all parents (including `missing`) in CSR form.
final class LayoutInput {
  LayoutInput({
    required this.nowMs,
    required this.utcOffsetMin,
    required this.ts,
    required this.hasTs,
    required this.isRoot,
    required this.priority,
    required this.parStart,
    required this.parIdx,
    required this.parKind,
  }) : n = ts.length;

  final int nowMs;
  final int utcOffsetMin;

  /// Node count.
  final int n;

  /// `ts_ms`; only meaningful where [hasTs] is 1.
  final Int64List ts;
  final Uint8List hasTs;
  final Uint8List isRoot;
  final Int32List priority;

  /// Parents of node i are `parStart[i] ..< parStart[i + 1]`, in stream order.
  final Int32List parStart;

  /// Target node index, or −1 for a `missing` parent.
  final Int32List parIdx;
  final Uint8List parKind;
}

final Converter<List<int>, Object?> _decoder = const Utf8Decoder().fuse(const JsonDecoder());

/// Parses and validates the input JSON (SPEC §2). Throws [InputError].
///
/// Error messages are only built on failure, so the (timed) happy path does no string work.
LayoutInput parseInput(Uint8List bytes) {
  // A UTF-8 byte order mark is not part of a JSON text (RFC 8259 §8.1). The fused decoder skips
  // it, serde_json and JSON.parse reject it: SPEC §2 (clarified during diff) rejects it too.
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    throw InputError('invalid JSON: leading byte order mark');
  }
  final Object? doc;
  try {
    doc = _decoder.convert(bytes);
  } on FormatException catch (e) {
    throw InputError('invalid JSON: ${e.message}');
  }
  if (doc is! Map<String, Object?>) throw InputError('top level: expected an object');
  final nowMs = _topInt(doc, 'now_ms');
  final utcOffsetMin = _topInt(doc, 'utc_offset_min');
  // V4 (clarified during diff): a real UTC offset, so `utc_offset_min · 60000` cannot overflow.
  if (utcOffsetMin < -maxUtcOffsetMin || utcOffsetMin > maxUtcOffsetMin) {
    throw InputError('top level: V4: "utc_offset_min" must lie within ±$maxUtcOffsetMin');
  }
  final nodes = doc['nodes'];
  if (nodes is! List<Object?>) throw InputError('top level: "nodes" must be an array');
  final n = nodes.length;

  // Pass 1: shapes and the parent total, so the CSR arrays are allocated once.
  var total = 0;
  for (var i = 0; i < n; i++) {
    final node = nodes[i];
    if (node is! Map<String, Object?>) throw InputError('node $i: expected an object');
    final parents = node['parents'];
    if (parents is! List<Object?>) throw InputError('node $i: "parents" must be an array');
    total += parents.length;
  }

  final ts = Int64List(n);
  final hasTs = Uint8List(n);
  final isRoot = Uint8List(n);
  final priority = Int32List(n);
  final parStart = Int32List(n + 1);
  final parIdx = Int32List(total);
  final parKind = Uint8List(total);
  // V3: seen[idx] == i + 1 ⇔ node i already has a parent with this idx.
  final seen = Int32List(n);

  var k = 0;
  for (var i = 0; i < n; i++) {
    final node = nodes[i] as Map<String, Object?>;

    final tsValue = node['ts_ms'];
    if (tsValue != null) {
      if (!_isSafeInt(tsValue)) throw InputError('node $i: "ts_ms" must be an integer within ±2^53 or null');
      ts[i] = tsValue as int;
      hasTs[i] = 1;
    } else if (!node.containsKey('ts_ms')) {
      throw InputError('node $i: missing "ts_ms"');
    }

    final root = node['is_root'];
    if (root is! bool) throw InputError('node $i: "is_root" must be a boolean');
    isRoot[i] = root ? 1 : 0;

    final prio = node['priority'];
    if (prio is! int || prio < 0 || prio >= 0x80000000) {
      throw InputError('node $i: "priority" must be an integer in [0, 2^31)');
    }
    priority[i] = prio;

    parStart[i] = k;
    for (final parent in node['parents'] as List<Object?>) {
      if (parent is! Map<String, Object?>) throw InputError('node $i: every parent must be an object');
      final kind = switch (parent['kind']) {
        'direct' => kindDirect,
        'indirect' => kindIndirect,
        'missing' => kindMissing,
        _ => throw InputError('node $i: parent "kind" must be "direct", "indirect" or "missing"'),
      };
      final idx = parent['idx'];
      if (idx == null) {
        if (!parent.containsKey('idx')) throw InputError('node $i: parent without "idx"');
        if (kind != kindMissing) throw InputError('node $i: V1: a null idx requires kind "missing"');
        parIdx[k] = -1;
      } else {
        if (idx is! int) throw InputError('node $i: parent "idx" must be an integer or null');
        if (kind == kindMissing) throw InputError('node $i: V1: kind "missing" requires a null idx');
        if (idx <= i || idx >= n) throw InputError('node $i: V2: parent idx $idx not in ($i, $n)');
        if (seen[idx] == i + 1) throw InputError('node $i: V3: duplicate parent idx $idx');
        seen[idx] = i + 1;
        parIdx[k] = idx;
      }
      parKind[k] = kind;
      k++;
    }
  }
  parStart[n] = k;

  return LayoutInput(
    nowMs: nowMs,
    utcOffsetMin: utcOffsetMin,
    ts: ts,
    hasTs: hasTs,
    isRoot: isRoot,
    priority: priority,
    parStart: parStart,
    parIdx: parIdx,
    parKind: parKind,
  );
}

int _topInt(Map<String, Object?> map, String key) {
  final value = map[key];
  if (!_isSafeInt(value)) throw InputError('top level: "$key" must be an integer within ±2^53');
  return value as int;
}

bool _isSafeInt(Object? value) => value is int && value <= maxSafeInt && value >= -maxSafeInt;
