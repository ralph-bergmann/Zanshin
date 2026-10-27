// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import '../ffi/graph.dart' show GraphTopologyView, TopologyRef, TopologyWorkingCopy;
import '../worker/responses.dart' show ZanshinFfiException;
import 'layout_input.dart';

/// The layout engine's input (docs/graph-layout.md §2, §13) built from the graph [topology] of
/// `zanshin_graph_topology` (Story 4.10, read through Story 4.12's view), in O(n + E) with stamp
/// arrays and no maps:
/// - nodes in the topology's order; a node is a root iff the topology flags it, and has a
///   timestamp iff the topology carries timestamps and the node is not the root (the worker loads
///   them for every request since Story 4.14: both vertical models are laid out);
/// - each node's parents are its edges in stream order: a Missing edge stays a `missing` parent,
///   and Direct / Indirect edges keep ONE parent per target, at the position of its first
///   occurrence, `direct` if any edge to that target is direct (§2's repeated-target rule);
/// - the priority classes follow §11.2's anchors rule over the topology's anchors;
/// - [utcOffsetMin] is passed through (both modes read it: `free`'s day buckets, every node's day
///   key).
///
/// Values are copied verbatim — never repaired, never rejected: a target outside the node range is
/// copied as it is (and never used as an index), so the engine's validation names the rule it
/// breaks. Throws `ffi.unknown` [ZanshinFfiException] for an edge-kind byte that is no edge kind or
/// an anchor node outside the node range, as [GraphTopologyView] does for corrupt buffers.
LayoutInput buildLayoutInput(GraphTopologyView topology, {required int utcOffsetMin}) {
  final int n = topology.nodeCount;
  final Uint8List flags = topology.flags;
  final Int64List? timestamps = topology.timestamps;
  final Uint32List edgeStarts = topology.edgeStarts;
  final Int32List edgeTargets = topology.edgeTargets;
  final Int8List edgeKinds = topology.edgeKinds;

  final ts = Int64List(n);
  final hasTs = Uint8List(n);
  final isRoot = Uint8List(n);
  for (var i = 0; i < n; i++) {
    if (flags[i] & GraphTopologyView.flagRoot != 0) {
      isRoot[i] = 1;
    } else if (timestamps != null) {
      ts[i] = timestamps[i];
      hasTs[i] = 1;
    }
  }

  // Repeated targets: stamp[t] == i + 1 ⇔ node i already kept a parent with target t, at index
  // at[t] of the parent arrays.
  final int edgeTotal = edgeStarts[n];
  final parStart = Int32List(n + 1);
  final parIdx = Int32List(edgeTotal);
  final parKind = Uint8List(edgeTotal);
  final stamp = Int32List(n);
  final at = Int32List(n);
  var k = 0;
  for (var i = 0; i < n; i++) {
    parStart[i] = k;
    for (int e = edgeStarts[i]; e < edgeStarts[i + 1]; e++) {
      final int kind = edgeKinds[e];
      if (kind < parentDirect || kind > parentMissing) {
        throw ZanshinFfiException('ffi.unknown', 'GraphTopology.edge_kind[$e] is $kind');
      }
      final int target = edgeTargets[e];
      if (kind != parentMissing && target >= 0 && target < n) {
        if (stamp[target] == i + 1) {
          if (kind == parentDirect) {
            parKind[at[target]] = parentDirect;
          }
          continue;
        }
        stamp[target] = i + 1;
        at[target] = k;
      }
      parIdx[k] = target;
      parKind[k] = kind;
      k++;
    }
  }
  parStart[n] = k;

  return LayoutInput(
    utcOffsetMin: utcOffsetMin,
    ts: ts,
    hasTs: hasTs,
    isRoot: isRoot,
    priority: _priorities(topology, parStart, parIdx, parKind),
    parStart: parStart,
    parIdx: Int32List.sublistView(parIdx, 0, k),
    parKind: Uint8List.sublistView(parKind, 0, k),
  );
}

/// docs/graph-layout.md §11.2: with A anchors every node starts in class A; for k = 0 … A − 1,
/// each node of anchor k (ascending) and its first-parent chain take class k, up to the first
/// node already in a class ≤ k. The first parent is the first non-missing parent after the
/// repeated-target rule (it may be indirect); a chain stops at a target outside the node range.
/// Each node changes class at most once, so this is O(n + E).
Int32List _priorities(GraphTopologyView topology, Int32List parStart, Int32List parIdx, Uint8List parKind) {
  final int n = topology.nodeCount;
  final int anchorCount = topology.anchorCount;
  final Uint32List anchorStarts = topology.anchorStarts;
  final Uint32List anchorNodes = topology.anchorNodesFlat;
  final priority = Int32List(n)..fillRange(0, n, anchorCount);
  for (var a = 0; a < anchorCount; a++) {
    for (int s = anchorStarts[a]; s < anchorStarts[a + 1]; s++) {
      final int node = anchorNodes[s];
      if (node >= n) {
        throw ZanshinFfiException('ffi.unknown', 'GraphTopology.anchor_node[$s] is $node, beyond $n nodes');
      }
      var cur = node;
      while (cur >= 0 && cur < n && priority[cur] > a) {
        priority[cur] = a;
        var next = -1;
        for (int p = parStart[cur]; p < parStart[cur + 1]; p++) {
          if (parKind[p] != parentMissing) {
            next = parIdx[p];
            break;
          }
        }
        cur = next;
      }
    }
  }
  return priority;
}

/// The stack request of docs/graph-layout.md §4.8 (Story 4.13) for the engine input
/// [buildLayoutInput] builds from [topology], in O(n + refs + working copies + keys):
/// - `immutable` from the topology's immutable flag, `parentCount` from its `parent_count`;
/// - `hasRef` iff a bookmark entry (local or remote) or a tag points at the node;
/// - `workingCopy` [workingCopyThis] for this workspace's `@` (its flag), else [workingCopyOther] if
///   another workspace's working copy is the node, else [workingCopyNone];
/// - each key of [expandedKeys], [collapsedKeys] and [keepOpenKeys] resolved by Story 10.1's key
///   rule: a change id names its node that is neither hidden nor divergent, a commit id names its
///   node only when that node is hidden or divergent; a key that names nothing is dropped.
///
/// The id lookups are built only when a list is not empty. Throws `ffi.unknown`
/// [ZanshinFfiException] for a corrupt ref or working-copy entry (a missing name, or a node outside
/// the node range), as [GraphTopologyView] does.
StackInput buildStackInput(
  GraphTopologyView topology, {
  required List<String> expandedKeys,
  required List<String> collapsedKeys,
  required List<String> keepOpenKeys,
}) {
  final int n = topology.nodeCount;
  final Uint8List flags = topology.flags;
  final Uint32List parentCounts = topology.parentCounts;
  final immutable = Uint8List(n);
  final parentCount = Int32List(n);
  final hasRef = Uint8List(n);
  final workingCopy = Uint8List(n);
  for (var i = 0; i < n; i++) {
    if (flags[i] & GraphTopologyView.flagImmutable != 0) {
      immutable[i] = 1;
    }
    parentCount[i] = parentCounts[i];
    if (flags[i] & GraphTopologyView.flagWorkingCopy != 0) {
      workingCopy[i] = workingCopyThis;
    }
  }
  for (final TopologyRef ref in topology.refs) {
    if (ref.node < 0 || ref.node >= n) {
      throw ZanshinFfiException(
        'ffi.unknown',
        'GraphTopology.refs entry ${ref.name} is node ${ref.node}, beyond $n nodes',
      );
    }
    hasRef[ref.node] = 1;
  }
  for (final TopologyWorkingCopy copy in topology.workingCopies) {
    if (copy.node < 0 || copy.node >= n) {
      throw ZanshinFfiException(
        'ffi.unknown',
        'GraphTopology.working_copies entry ${copy.workspace} is node ${copy.node}, beyond $n nodes',
      );
    }
    if (workingCopy[copy.node] == workingCopyNone) {
      workingCopy[copy.node] = workingCopyOther;
    }
  }
  return StackInput(
    immutable: immutable,
    parentCount: parentCount,
    hasRef: hasRef,
    workingCopy: workingCopy,
    expandedNodes: _resolveKeys(topology, expandedKeys),
    collapsedNodes: _resolveKeys(topology, collapsedKeys),
    keepOpenNodes: _resolveKeys(topology, keepOpenKeys),
  );
}

/// The nodes [keys] name by Story 10.1's key rule (see [buildStackInput]); unresolved keys dropped.
Int32List _resolveKeys(GraphTopologyView topology, List<String> keys) {
  final nodes = <int>[];
  for (final key in keys) {
    final int node = _resolveKey(topology, key);
    if (node >= 0) {
      nodes.add(node);
    }
  }
  return Int32List.fromList(nodes);
}

int _resolveKey(GraphTopologyView topology, String key) {
  for (final int i in topology.indicesOfChangeId(key)) {
    if (!topology.isHidden(i) && !topology.isDivergent(i)) {
      return i;
    }
  }
  final int? i = topology.indexOfCommitId(key);
  if (i != null && (topology.isHidden(i) || topology.isDivergent(i))) {
    return i;
  }
  return -1;
}
