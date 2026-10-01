// SPDX-License-Identifier: MIT

// docs/graph-layout.md's JSON forms for the product engine's tests and its CLI (Story 4.11): the
// §2 input parser and canonical writer, the §3 canonical output of a grid, the §8.4 digest and
// the goldens' FNV-1a 64 hash. Ported from the spike's Dart reference
// (spikes/graph-layout-ab/dart/lib/src/input.dart, output.dart). The engine itself reads no JSON.

import 'dart:convert';
import 'dart:typed_data';

import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/layout_input.dart';

/// Input JSON the parser refuses before it builds the typed arrays: not JSON, a wrong type, a
/// missing field, or a value the typed arrays cannot hold (an integer beyond ±2^53, a priority
/// outside [0, 2^31)). The remaining V1–V4 checks are [validateLayoutInput]'s
/// `LayoutContractException`.
final class SpecInputError implements Exception {
  /// An error described by [message].
  SpecInputError(this.message);

  /// What is wrong, naming the node.
  final String message;

  @override
  String toString() => message;
}

final Converter<List<int>, Object?> _decoder = const Utf8Decoder().fuse(const JsonDecoder());

/// Parses the §2 input [bytes] — any valid JSON: whitespace, key order, unknown keys, duplicate
/// keys (the last wins); no byte-order mark — then validates it with [validateLayoutInput].
/// Returns the engine input and the file's `now_ms`, which no shipped mode reads. Throws
/// [SpecInputError] for malformed JSON and `LayoutContractException` for V1–V4.
({LayoutInput input, int nowMs}) parseSpecInput(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    throw SpecInputError('invalid JSON: leading byte order mark');
  }
  final Object? doc;
  try {
    doc = _decoder.convert(bytes);
  } on FormatException catch (e) {
    throw SpecInputError('invalid JSON: ${e.message}');
  }
  if (doc is! Map<String, Object?>) {
    throw SpecInputError('top level: expected an object');
  }
  final int nowMs = _topInt(doc, 'now_ms');
  final int utcOffsetMin = _topInt(doc, 'utc_offset_min');
  final Object? nodes = doc['nodes'];
  if (nodes is! List<Object?>) {
    throw SpecInputError('top level: "nodes" must be an array');
  }
  final int n = nodes.length;
  var total = 0;
  for (var i = 0; i < n; i++) {
    final Object? node = nodes[i];
    if (node is! Map<String, Object?>) {
      throw SpecInputError('node $i: expected an object');
    }
    final Object? parents = node['parents'];
    if (parents is! List<Object?>) {
      throw SpecInputError('node $i: "parents" must be an array');
    }
    total += parents.length;
  }

  final ts = Int64List(n);
  final hasTs = Uint8List(n);
  final isRoot = Uint8List(n);
  final priority = Int32List(n);
  final parStart = Int32List(n + 1);
  final parIdx = Int32List(total);
  final parKind = Uint8List(total);
  var k = 0;
  for (var i = 0; i < n; i++) {
    final node = nodes[i]! as Map<String, Object?>;
    final Object? tsValue = node['ts_ms'];
    if (tsValue != null) {
      if (!_isSafeInt(tsValue)) {
        throw SpecInputError('node $i: "ts_ms" must be an integer within ±2^53 or null');
      }
      ts[i] = tsValue as int;
      hasTs[i] = 1;
    } else if (!node.containsKey('ts_ms')) {
      throw SpecInputError('node $i: missing "ts_ms"');
    }
    final Object? root = node['is_root'];
    if (root is! bool) {
      throw SpecInputError('node $i: "is_root" must be a boolean');
    }
    isRoot[i] = root ? 1 : 0;
    final Object? prio = node['priority'];
    if (prio is! int || prio < 0 || prio >= 0x80000000) {
      throw SpecInputError('node $i: "priority" must be an integer in [0, 2^31)');
    }
    priority[i] = prio;
    parStart[i] = k;
    for (final parent in node['parents']! as List<Object?>) {
      if (parent is! Map<String, Object?>) {
        throw SpecInputError('node $i: every parent must be an object');
      }
      parKind[k] = switch (parent['kind']) {
        'direct' => parentDirect,
        'indirect' => parentIndirect,
        'missing' => parentMissing,
        _ => throw SpecInputError('node $i: parent "kind" must be "direct", "indirect" or "missing"'),
      };
      final Object? idx = parent['idx'];
      if (idx == null) {
        if (!parent.containsKey('idx')) {
          throw SpecInputError('node $i: parent without "idx"');
        }
        parIdx[k] = -1;
      } else if (idx is! int || idx < 0 || idx > 0x7FFFFFFF) {
        throw SpecInputError('node $i: parent "idx" must be a node index or null');
      } else {
        parIdx[k] = idx;
      }
      k++;
    }
  }
  parStart[n] = k;
  final input = LayoutInput(
    utcOffsetMin: utcOffsetMin,
    ts: ts,
    hasTs: hasTs,
    isRoot: isRoot,
    priority: priority,
    parStart: parStart,
    parIdx: parIdx,
    parKind: parKind,
  );
  validateLayoutInput(input);
  return (input: input, nowMs: nowMs);
}

int _topInt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (!_isSafeInt(value)) {
    throw SpecInputError('top level: "$key" must be an integer within ±2^53');
  }
  return value! as int;
}

bool _isSafeInt(Object? value) => value is int && value <= maxSafeInt && value >= -maxSafeInt;

const _parentKinds = <String>['direct', 'indirect', 'missing'];

/// The §2 canonical form of [input] (keys in the SPEC's order, no whitespace, one trailing
/// newline), with [nowMs] and the node [ids] the engine input does not carry.
String canonicalInput(LayoutInput input, {required int nowMs, required List<String> ids}) {
  final out = StringBuffer()
    ..write('{"now_ms":')
    ..write(nowMs)
    ..write(',"utc_offset_min":')
    ..write(input.utcOffsetMin)
    ..write(',"nodes":[');
  for (var i = 0; i < input.n; i++) {
    if (i > 0) {
      out.write(',');
    }
    out
      ..write('{"id":')
      ..write(jsonEncode(ids[i]))
      ..write(',"ts_ms":')
      ..write(input.hasTs[i] != 0 ? input.ts[i] : 'null')
      ..write(',"is_root":')
      ..write(input.isRoot[i] != 0)
      ..write(',"priority":')
      ..write(input.priority[i])
      ..write(',"parents":[');
    for (int k = input.parStart[i]; k < input.parStart[i + 1]; k++) {
      if (k > input.parStart[i]) {
        out.write(',');
      }
      final int idx = input.parIdx[k];
      out
        ..write('{"idx":')
        ..write(idx < 0 ? 'null' : idx)
        ..write(',"kind":"')
        ..write(_parentKinds[input.parKind[k]])
        ..write('"}');
    }
    out.write(']}');
  }
  out.write(']}\n');
  return out.toString();
}

const _edgeKinds = <String>['direct', 'indirect'];
const _routes = <String>['straight', 'merge', 'branch_off'];
const _bucketKinds = <String>['root', 'age', 'day'];

/// The §3 canonical output of [grid]: fixed key order, no whitespace, one trailing newline.
String canonicalOutput(GraphGridView grid) {
  final out = StringBuffer()
    ..write('{"mode":"')
    ..write(grid.mode.name)
    ..write('","order":"')
    ..write(grid.order.name)
    ..write('","unit":')
    ..write(grid.unit)
    ..write(',"rows":')
    ..write(grid.rows)
    ..write(',"lanes":')
    ..write(grid.lanes)
    ..write(',"nodes":[');
  for (var i = 0; i < grid.nodeCount; i++) {
    if (i > 0) {
      out.write(',');
    }
    out
      ..write('{"row":')
      ..write(grid.nodeRows[i])
      ..write(',"lane":')
      ..write(grid.nodeLanes[i])
      ..write(',"col":')
      ..write(grid.nodeCols[i])
      ..write('}');
  }
  out.write('],"edges":[');
  for (var e = 0; e < grid.edgeCount; e++) {
    if (e > 0) {
      out.write(',');
    }
    out
      ..write('{"from":')
      ..write(grid.edgeFroms[e])
      ..write(',"to":')
      ..write(grid.edgeTos[e])
      ..write(',"kind":"')
      ..write(_edgeKinds[grid.edgeKinds[e]])
      ..write('","route":"')
      ..write(_routes[grid.edgeRoutes[e]])
      ..write('","blocked":')
      ..write(grid.edgeBlocked[e] != 0)
      ..write('}');
  }
  out.write('],"buckets":[');
  for (var b = 0; b < grid.bucketCount; b++) {
    if (b > 0) {
      out.write(',');
    }
    out
      ..write('{"kind":"')
      ..write(_bucketKinds[grid.bucketKinds[b]])
      ..write('","value":')
      ..write(grid.bucketValues[b])
      ..write(',"start":')
      ..write(grid.bucketStarts[b])
      ..write(',"end":')
      ..write(grid.bucketEnds[b])
      ..write('}');
  }
  out.write(']}\n');
  return out.toString();
}

/// The bench digest of §8.4 over [grid].
int specDigest(GraphGridView grid) {
  const p = 1000000007;
  var d = 0;
  for (var i = 0; i < grid.nodeCount; i++) {
    d = (31 * d + 7 * grid.nodeRows[i] + 3 * grid.nodeCols[i] + grid.nodeLanes[i]) % p;
  }
  for (var e = 0; e < grid.edgeCount; e++) {
    d = (31 * d + grid.edgeRoutes[e] + 4 * grid.edgeBlocked[e]) % p;
  }
  for (var b = 0; b < grid.bucketCount; b++) {
    d = (31 * d + grid.bucketStarts[b] + 3 * grid.bucketEnds[b]) % p;
  }
  return d;
}

/// An `indirect` parent in [specGraph]'s parent lists (a plain int is `direct`, null `missing`).
final class Ind {
  /// An indirect parent with target [idx].
  const Ind(this.idx);

  /// The target node index.
  final int idx;
}

/// A hand-built input, through the §2 JSON and [parseSpecInput]: [parents] lists every node's
/// parents children-first (an int is `direct`, an [Ind] `indirect`, null `missing`); [priority]
/// defaults to 0, [ts] to null, [offset] is `utc_offset_min`.
LayoutInput specGraph(
  List<List<Object?>> parents, {
  List<int>? priority,
  List<int?>? ts,
  Set<int> roots = const {},
  int offset = 0,
}) {
  final List<Map<String, Object?>> nodes = [
    for (var i = 0; i < parents.length; i++)
      {
        'id': 'n$i',
        'ts_ms': ts?[i],
        'is_root': roots.contains(i),
        'priority': priority?[i] ?? 0,
        'parents': [
          for (final Object? p in parents[i])
            switch (p) {
              null => {'idx': null, 'kind': 'missing'},
              Ind(:final int idx) => {'idx': idx, 'kind': 'indirect'},
              final int idx => {'idx': idx, 'kind': 'direct'},
              _ => throw ArgumentError.value(p, 'parents'),
            },
        ],
      },
  ];
  return parseSpecInput(utf8.encode(jsonEncode({'now_ms': 0, 'utc_offset_min': offset, 'nodes': nodes}))).input;
}

/// FNV-1a 64 of [bytes] (offset basis 0xcbf29ce484222325, prime 0x100000001b3) as 16 lowercase
/// hex digits — the goldens' hash (tools/goldens.mjs).
String fnv1a64Hex(List<int> bytes) {
  // Dart's 64-bit ints wrap on overflow, which is exactly the hash's arithmetic modulo 2^64.
  var h = 0xcbf29ce484222325;
  for (final b in bytes) {
    h = (h ^ b) * 0x100000001b3;
  }
  return (h >>> 32).toRadixString(16).padLeft(8, '0') + (h & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
}
