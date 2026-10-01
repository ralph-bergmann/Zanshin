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

/// The stack facts of a §2 input (amended 2026-10-01, Story 4.13) as [parseSpecInput] reads them
/// with `stacks: true`: per node its key and the four facts of a [StackInput].
final class SpecStackFacts {
  SpecStackFacts._(int n)
    : keys = List.filled(n, ''),
      immutable = Uint8List(n),
      parentCount = Int32List(n),
      hasRef = Uint8List(n),
      workingCopy = Uint8List(n);

  /// Every node's `key`, pairwise distinct.
  final List<String> keys;

  /// `immutable` per node (0 or 1).
  final Uint8List immutable;

  /// `parent_count` per node.
  final Int32List parentCount;

  /// `has_ref` per node (0 or 1).
  final Uint8List hasRef;

  /// `working_copy` per node as a [StackInput.workingCopy] code.
  final Uint8List workingCopy;

  final Map<String, int> _index = {};
  var _self = -1;

  /// Reads node [i]'s facts from [node]: all five required, keys distinct, at most one `"this"`.
  void _read(int i, Map<String, Object?> node) {
    final Object? key = node['key'];
    if (key is! String) {
      throw SpecInputError('node $i: V5: "key" must be a string');
    }
    final int? earlier = _index[key];
    if (earlier != null) {
      throw SpecInputError('node $i: V5: key "$key" is also node $earlier\'s');
    }
    _index[key] = i;
    keys[i] = key;
    final Object? imm = node['immutable'];
    if (imm is! bool) {
      throw SpecInputError('node $i: V5: "immutable" must be a boolean');
    }
    immutable[i] = imm ? 1 : 0;
    final Object? count = node['parent_count'];
    if (count is! int || count < 0 || count >= 0x80000000) {
      throw SpecInputError('node $i: V5: "parent_count" must be an integer in [0, 2^31)');
    }
    parentCount[i] = count;
    final Object? ref = node['has_ref'];
    if (ref is! bool) {
      throw SpecInputError('node $i: V5: "has_ref" must be a boolean');
    }
    hasRef[i] = ref ? 1 : 0;
    final Object? wc = node['working_copy'];
    if (wc == null && !node.containsKey('working_copy')) {
      throw SpecInputError('node $i: V5: missing "working_copy"');
    }
    workingCopy[i] = switch (wc) {
      null => workingCopyNone,
      'other' => workingCopyOther,
      'this' => workingCopyThis,
      _ => throw SpecInputError('node $i: V5: "working_copy" must be "this", "other" or null'),
    };
    if (wc == 'this') {
      if (_self >= 0) {
        throw SpecInputError('node $i: V5: node $_self is "this" working copy too');
      }
      _self = i;
    }
  }
}

/// Parses the §2 input [bytes] — any valid JSON: whitespace, key order, unknown keys, duplicate
/// keys (the last wins); no byte-order mark — then validates it with [validateLayoutInput].
/// Returns the engine input, the file's `now_ms`, which no shipped mode reads, and with [stacks]
/// (Story 4.13) the nodes' stack facts, which are then required. Throws [SpecInputError] for
/// malformed JSON and malformed facts and `LayoutContractException` for V1–V4.
({LayoutInput input, int nowMs, SpecStackFacts? facts}) parseSpecInput(Uint8List bytes, {bool stacks = false}) {
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
  final SpecStackFacts? facts = stacks ? SpecStackFacts._(n) : null;
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
    facts?._read(i, node);
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
  return (input: input, nowMs: nowMs, facts: facts);
}

int _topInt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (!_isSafeInt(value)) {
    throw SpecInputError('top level: "$key" must be an integer within ±2^53');
  }
  return value! as int;
}

bool _isSafeInt(Object? value) => value is int && value <= maxSafeInt && value >= -maxSafeInt;

/// Parses the stack request file [bytes] (§2, amended 2026-10-01: `{"expanded":[…],
/// "collapsed":[…],"keep_open":[…]}`, three required arrays of strings) against the [facts] of
/// its input: each key resolves to the node whose key equals it, an unknown key is dropped.
/// Throws [SpecInputError].
StackInput parseSpecStackRequest(Uint8List bytes, SpecStackFacts facts) {
  final Object? doc;
  try {
    doc = _decoder.convert(bytes);
  } on FormatException catch (e) {
    throw SpecInputError('stack request: invalid JSON: ${e.message}');
  }
  if (doc is! Map<String, Object?>) {
    throw SpecInputError('stack request: expected an object');
  }
  final Map<String, Object?> request = doc;
  Int32List resolve(String field) {
    final Object? list = request[field];
    if (list is! List<Object?>) {
      throw SpecInputError('stack request: "$field" must be an array of strings');
    }
    final nodes = <int>[];
    for (final Object? key in list) {
      if (key is! String) {
        throw SpecInputError('stack request: "$field" must be an array of strings');
      }
      final int? node = facts._index[key];
      if (node != null) {
        nodes.add(node);
      }
    }
    return Int32List.fromList(nodes);
  }

  return StackInput(
    immutable: facts.immutable,
    parentCount: facts.parentCount,
    hasRef: facts.hasRef,
    workingCopy: facts.workingCopy,
    expandedNodes: resolve('expanded'),
    collapsedNodes: resolve('collapsed'),
    keepOpenNodes: resolve('keep_open'),
  );
}

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
  // With stacks the node arrays hold n + S entries, a hidden member as null (§3, amended).
  for (var i = 0; i < grid.nodeRows.length; i++) {
    if (i > 0) {
      out.write(',');
    }
    if (grid.isHidden(i)) {
      out.write('null');
      continue;
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
  out.write(']');
  final Int32List? runStarts = grid.runStarts;
  final Int32List? runMembers = grid.runMembers;
  final Uint8List? runStates = grid.runStates;
  final Int32List? runNodes = grid.runNodes;
  if (runStarts != null && runMembers != null && runStates != null && runNodes != null) {
    out.write(',"runs":[');
    for (var k = 0; k < grid.runCount; k++) {
      if (k > 0) {
        out.write(',');
      }
      out.write('{"members":[');
      for (int j = runStarts[k]; j < runStarts[k + 1]; j++) {
        if (j > runStarts[k]) {
          out.write(',');
        }
        out.write(runMembers[j]);
      }
      out
        ..write('],"state":"')
        ..write(runStates[k] == GraphGridView.runCollapsed ? 'collapsed' : 'expanded')
        ..write('","node":')
        ..write(runNodes[k] < 0 ? 'null' : runNodes[k])
        ..write('}');
    }
    out.write(']');
  }
  out.write('}\n');
  return out.toString();
}

/// The bench digest of §8.4 over [grid].
int specDigest(GraphGridView grid) {
  const p = 1000000007;
  var d = 0;
  // With stacks over the n + S node entries, a hidden member's −1s included (§6, amended).
  for (var i = 0; i < grid.nodeRows.length; i++) {
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

/// A hand-built input with stack facts (Story 4.13), through the §2 JSON and [parseSpecInput]:
/// [parents], [priority] and [ts] as in [specGraph], the last node the root, keys `n<i>`;
/// [counts] overrides a node's `parent_count` (default: its parent entries), [refs] carry
/// `has_ref`, [self] is this workspace's `@`, [others] are other workspaces' working copies,
/// [immutable] the immutable nodes.
({LayoutInput input, SpecStackFacts facts}) specStackGraph(
  List<List<Object?>> parents, {
  Map<int, int> counts = const {},
  Set<int> refs = const {},
  int? self,
  Set<int> others = const {},
  Set<int> immutable = const {},
  List<int>? priority,
  List<int?>? ts,
  int offset = 0,
}) {
  final int n = parents.length;
  final List<Map<String, Object?>> nodes = [
    for (var i = 0; i < n; i++)
      {
        'id': 'n$i',
        'ts_ms': ts?[i],
        'is_root': i == n - 1,
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
        'key': 'n$i',
        'immutable': immutable.contains(i),
        'parent_count': counts[i] ?? parents[i].length,
        'has_ref': refs.contains(i),
        'working_copy': i == self ? 'this' : (others.contains(i) ? 'other' : null),
      },
  ];
  final ({LayoutInput input, int nowMs, SpecStackFacts? facts}) parsed = parseSpecInput(
    utf8.encode(jsonEncode({'now_ms': 0, 'utc_offset_min': offset, 'nodes': nodes})),
    stacks: true,
  );
  return (input: parsed.input, facts: parsed.facts!);
}

/// The stack request over [facts] naming the keys `n<i>` of [expanded], [collapsed] and
/// [keepOpen], plus the [unknown] keys in every list.
StackInput specStackRequest(
  SpecStackFacts facts, {
  List<int> expanded = const [],
  List<int> collapsed = const [],
  List<int> keepOpen = const [],
  List<String> unknown = const [],
}) => parseSpecStackRequest(
  utf8.encode(
    jsonEncode({
      'expanded': [for (final i in expanded) 'n$i', ...unknown],
      'collapsed': [for (final i in collapsed) 'n$i', ...unknown],
      'keep_open': [for (final i in keepOpen) 'n$i', ...unknown],
    }),
  ),
  facts,
);

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
