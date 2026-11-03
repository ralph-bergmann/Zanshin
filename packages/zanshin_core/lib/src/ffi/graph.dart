// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:flat_buffers/flat_buffers.dart' as fb;
import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'ffi_buffer.dart';
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of the GraphTopology wire contract (Story 4.12):
// the `zanshin_graph_topology` FFI adapter, the editable pre-fills, and
// [GraphTopologyView], a lazy typed-data view over the envelope bytes.
// `dart:ffi` stays inside `ffi/` — only the worker isolate calls the adapter.

// ── Pre-fills ─────────────────────────────────────────────────────────────────

/// The CLI-default branch-prioritisation revset, pre-filled by
/// `RepoHandle.graphTopology` and editable by the caller (FR-JJ-17).
///
/// Mirrors `zanshin_jj::DEFAULT_GRAPH_PRIORITIZE` — `jj log`'s
/// `revsets.log-graph-prioritize` default. `'none()'` is the canonical
/// "no prioritisation" value; a blank expression is a `jj.revset_parse_error`.
///
/// This is the BUILTIN default. The user's config may override it — prefer
/// `RepoHandle.logDefaults()` (Story 4.9), whose `logGraphPrioritize` is the
/// effective value their own CLI would apply.
const defaultGraphPrioritize = 'present(@)';

/// The CLI-default log revset (`revsets.log`) — the commits `jj log` shows
/// without `-r`. Mirrors `zanshin_jj::DEFAULT_LOG_REVSET`.
///
/// A pre-fill for the caller's `revset` of `RepoHandle.graphTopology`, never
/// applied silently (FR-JJ-17); the UI passes `revset` explicitly.
///
/// This is the BUILTIN default. The user's config may override it — prefer
/// `RepoHandle.logDefaults()` (Story 4.9), whose `log` is the effective value
/// their own CLI would apply.
const defaultLogRevset = 'present(@) | ancestors(immutable_heads().., 2) | trunk()';

/// The CLI-default shortest-prefix disambiguation set, pre-filled by
/// `RepoHandle.graphTopology` and editable by the caller (FR-JJ-17).
///
/// The CLI's `revsets.short-prefixes` falls back to `revsets.log`, so this is the
/// same expression as [defaultLogRevset]. An EMPTY string DISABLES disambiguation
/// (full-index prefix lengths) — the CLI's toggle semantic, deliberately unlike
/// [defaultGraphPrioritize], where a blank expression is a parse error.
///
/// This is the BUILTIN default. The user's config may override it — prefer
/// `RepoHandle.logDefaults()` (Story 4.9), whose `shortPrefixes` is the
/// effective value their own CLI would apply (it follows `revsets.log` when
/// `revsets.short-prefixes` is unset).
const String defaultShortPrefixes = defaultLogRevset;

/// The editable pre-fill for `RepoHandle.graphTopology`'s required `anchors`
/// (Story 4.10): an ordered list of revsets whose selected nodes feed the layout
/// engine's priority rule (Story 4.11) — the trunk chain first, then `@`'s.
///
/// Rust has no default for `anchors` (FR-JJ-17), and nothing applies this list
/// on its own: a caller passes it explicitly, and may edit it. `trunk()` follows
/// the user's `[revset-aliases]` (Story 4.9).
const defaultGraphAnchors = ['trunk()', 'present(@)'];

// ── FFI adapter ───────────────────────────────────────────────────────────────

/// Call `zanshin_graph_topology` with the raw `u64` handle and a
/// `GraphTopologyRequest` request buffer, and return the native envelope
/// WITHOUT copying it: the caller reads [FfiBuffer.bytes] (a view over Rust's
/// allocation) and must [FfiBuffer.dispose] it.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). Every argument is a caller pass-through (FR-JJ-17).
///
/// Throws [ArgumentError] if [revset], [prioritize], [shortPrefixes] or an
/// entry of [anchors] contains an interior U+0000 (the direct-caller backstop;
/// `ZanshinWorker.graphTopology` guards the calling side).
FfiBuffer zanshinGraphTopology(
  int rawHandle, {
  required String revset,
  required String prioritize,
  required String shortPrefixes,
  required List<String> anchors,
  required bool withTimestamps,
}) {
  rejectInteriorNul(revset, 'revset');
  rejectInteriorNul(prioritize, 'prioritize');
  rejectInteriorNul(shortPrefixes, 'shortPrefixes');
  rejectInteriorNuls(anchors, 'anchors');
  final Uint8List request = fbs.GraphTopologyRequestObjectBuilder(
    kind: fbs.RequestKind.GraphTopology,
    revset: revset,
    prioritize: prioritize,
    shortPrefixes: shortPrefixes,
    anchors: anchors,
    withTimestamps: withTimestamps,
  ).toBytes();
  return withRequestBytes(request, (ptr, len) => FfiBuffer.fromToken(zanshin_graph_topology(rawHandle, ptr, len)));
}

// ── Dart models ───────────────────────────────────────────────────────────────

/// How a graph edge's target was classified by jj's revset-graph stream
/// (mirrors `zanshin_jj::GraphEdgeKind` and the wire's `GraphEdgeKind`).
enum GraphEdgeKind {
  /// The parent is in the revset.
  direct,

  /// The direct parent was elided from the revset; the edge points at the
  /// closest in-set ancestor. Renderers may draw it dashed.
  indirect,

  /// The edge leads outside the revset; it has no target node. Renderers may
  /// draw it as a stub.
  missing,
}

/// Whether a [TopologyRef] is a bookmark or a tag.
enum TopologyRefKind {
  /// A bookmark entry.
  bookmark,

  /// A tag entry.
  tag,
}

/// One bookmark or tag entry of a graph topology node (mirrors
/// `zanshin_jj::CommitRef`, plus the node it belongs to).
///
/// The CLI renders [name], then `@remote` for a remote entry, then `??` when
/// [conflicted] or `*` when a local entry is not [synced]. Which glyph (if any)
/// is drawn is the UI's decision.
final class TopologyRef {
  const TopologyRef({
    required this.node,
    required this.kind,
    required this.name,
    required this.remote,
    required this.synced,
    required this.conflicted,
    required this.tracked,
  });

  /// The node index this entry belongs to.
  final int node;

  /// Bookmark or tag.
  final TopologyRefKind kind;

  /// Bookmark or tag name.
  final String name;

  /// The remote this entry belongs to; `null` for the local entry.
  final String? remote;

  /// Local entry: every tracking remote agrees with the local target. Remote
  /// entry: the remote is tracked AND agrees with the local target.
  final bool synced;

  /// This entry's ref target is a conflict (more than one added commit).
  final bool conflicted;

  /// The CLI's `tracked` keyword: a remote entry whose remote ref is tracked;
  /// always `false` for the local entry.
  final bool tracked;
}

/// One workspace whose working-copy commit is a graph topology node.
final class TopologyWorkingCopy {
  const TopologyWorkingCopy({required this.node, required this.workspace});

  /// The node index.
  final int node;

  /// The workspace name.
  final String workspace;
}

// ── The lazy view ─────────────────────────────────────────────────────────────

// Field indices of `table GraphTopology` (schemas/envelope.fbs) whose scalar
// vectors this view locates by hand; a field's vtable offset is 4 + 2 × index.
const _commitIdsField = 2;
const _changeIdsField = 3;
const _flagsField = 6;
const _changeOffsetField = 7;
const _changeIdPrefixLenField = 8;
const _commitIdPrefixLenField = 9;
const _parentCountField = 10;
const _edgeStartField = 11;
const _edgeTargetField = 12;
const _edgeKindField = 13;
const _timestampsField = 14;
const _anchorStartField = 17;
const _anchorNodeField = 18;

/// `Envelope.data`'s vtable offset (fields `ok`, `error`, `data_type`, `data`).
const _envelopeDataVTableOffset = 10;

final _hexDigits = Uint8List.fromList('0123456789abcdef'.codeUnits);
final _reverseHexDigits = Uint8List.fromList('zyxwvutsrqponmlk'.codeUnits);

/// The whole revset's index-only graph topology at one operation (Story 4.12),
/// read lazily from the `zanshin_graph_topology` envelope bytes.
///
/// Every per-node and per-edge accessor is O(1): the scalar vectors are
/// typed-data views over [bytes] (a vector that is not aligned for its element
/// size is copied — that one vector only; see [copiedVectorCount]), and no
/// per-node object is allocated up front. Ids are formatted on access (commit
/// ids as lowercase hex, change ids as jj reverse-hex); the id → index lookups
/// are built on their first use. Absence reads as `null`: a node's
/// [changeOffset] without its presence bit, a Missing edge's [edgeTarget], and
/// every [timestamp] when none were requested (and always the root's).
///
/// Nodes are in `jj log` order (children before parents, `prioritize` first);
/// node `i`'s edges are `edgeStart(i) <= e < edgeEnd(i)`, in jj's stream order,
/// repeated targets kept. Card content is `RepoHandle.commitContents` at
/// [operationId].
///
/// A view over native memory (an `FfiBuffer`'s bytes) is valid only while that
/// `FfiBuffer` lives; the views `ZanshinWorker.graphTopology` returns own their
/// bytes (materialized from a `TransferableTypedData`).
final class GraphTopologyView {
  GraphTopologyView._({
    required this.bytes,
    required this.operationId,
    required this.extraOperationIds,
    required this.allCount,
    required this.warnings,
    required this._copiedVectorCount,
    required this._wireRefs,
    required this._wireWorkingCopies,
    required this._commitIds,
    required int commitIdStride,
    required this._changeIds,
    required int changeIdStride,
    required Uint8List flags,
    required this._changeOffsets,
    required this._changeIdPrefixLengths,
    required this._commitIdPrefixLengths,
    required Uint32List parentCounts,
    required Uint32List edgeStarts,
    required Int32List edgeTargets,
    required Int8List edgeKinds,
    required Int64List? timestamps,
    required Uint32List anchorStarts,
    required Uint32List anchorNodesFlat,
  }) : _commitIdStride = commitIdStride,
       _changeIdStride = changeIdStride,
       _flags = flags,
       _parentCounts = parentCounts,
       _edgeStarts = edgeStarts,
       _edgeTargets = edgeTargets,
       _edgeKinds = edgeKinds,
       _timestamps = timestamps,
       _anchorStarts = anchorStarts,
       _anchorNodes = anchorNodesFlat,
       nodeCount = flags.length,
       flags = flags.asUnmodifiableView(),
       parentCounts = parentCounts.asUnmodifiableView(),
       edgeStarts = edgeStarts.asUnmodifiableView(),
       edgeTargets = edgeTargets.asUnmodifiableView(),
       edgeKinds = edgeKinds.asUnmodifiableView(),
       timestamps = timestamps?.asUnmodifiableView(),
       anchorStarts = anchorStarts.asUnmodifiableView(),
       anchorNodesFlat = anchorNodesFlat.asUnmodifiableView(),
       _commitScratch = Uint8List(2 * commitIdStride),
       _changeScratch = Uint8List(2 * changeIdStride);

  /// Decode a `GraphTopology` `Envelope`: the error arm throws its
  /// [ZanshinFfiException] (with the call's precondition and warnings); a
  /// missing or wrong-length structurally required vector, a missing
  /// `operation_id`, `refs` or `working_copies`, or a payload other than
  /// `GraphTopology` throws `ffi.unknown`. Each vector is checked in O(1)
  /// (presence, length, bounds); the values are read on access. Little-endian
  /// host assumed (macOS).
  factory GraphTopologyView.fromEnvelope(Uint8List bytes) {
    final env = fbs.Envelope(bytes);
    if (!env.ok) {
      throw decodeEnvelopeErrorInternal(env);
    }
    final Object? payload = env.data;
    if (payload is! fbs.GraphTopology) {
      throw ZanshinFfiException('ffi.unknown', 'expected GraphTopology payload, got ${env.dataType}');
    }
    final String operationId = payload.operationId ?? (throw _missing('operation_id'));
    final List<fbs.TopologyRef> wireRefs = payload.refs ?? (throw _missing('refs'));
    final List<fbs.TopologyWorkingCopy> wireWorkingCopies = payload.workingCopies ?? (throw _missing('working_copies'));
    final List<String> extraOperationIds = payload.extraOperationIds ?? (throw _missing('extra_operation_ids'));
    final vectors = _Vectors(bytes);
    final Uint8List flags = vectors.uint8(_flagsField, 'flags');
    final int n = flags.length;
    final int commitIdStride = payload.commitIdStride;
    final int changeIdStride = payload.changeIdStride;
    if (n > 0 && (commitIdStride == 0 || changeIdStride == 0)) {
      throw const ZanshinFfiException('ffi.unknown', 'GraphTopology has nodes but a zero id stride');
    }
    final Uint8List commitIds = vectors.uint8(_commitIdsField, 'commit_ids', n * commitIdStride);
    final Uint8List changeIds = vectors.uint8(_changeIdsField, 'change_ids', n * changeIdStride);
    final Uint32List changeOffsets = vectors.uint32(_changeOffsetField, 'change_offset', n);
    final Uint8List changePrefix = vectors.uint8(_changeIdPrefixLenField, 'change_id_prefix_len', n);
    final Uint8List commitPrefix = vectors.uint8(_commitIdPrefixLenField, 'commit_id_prefix_len', n);
    final Uint32List parentCounts = vectors.uint32(_parentCountField, 'parent_count', n);
    final Uint32List edgeStarts = vectors.uint32(_edgeStartField, 'edge_start', n + 1);
    final int edgeCount = edgeStarts[n];
    final Int32List edgeTargets = vectors.int32(_edgeTargetField, 'edge_target', edgeCount);
    final Int8List edgeKinds = vectors.int8(_edgeKindField, 'edge_kind', edgeCount);
    final Int64List? timestamps = vectors.int64OrNull(_timestampsField, 'timestamps', n);
    final Uint32List anchorStarts = vectors.uint32(_anchorStartField, 'anchor_start');
    if (anchorStarts.isEmpty) {
      throw const ZanshinFfiException(
        'ffi.unknown',
        'GraphTopology.anchor_start is empty, expected anchors + 1 entries',
      );
    }
    final Uint32List anchorNodes = vectors.uint32(_anchorNodeField, 'anchor_node', anchorStarts.last);
    return GraphTopologyView._(
      bytes: bytes.asUnmodifiableView(),
      operationId: operationId,
      extraOperationIds: List.unmodifiable(extraOperationIds),
      allCount: payload.allCount,
      warnings: decodeEnvelopeWarningsInternal(env),
      copiedVectorCount: vectors.copied,
      wireRefs: wireRefs,
      wireWorkingCopies: wireWorkingCopies,
      commitIds: commitIds,
      commitIdStride: commitIdStride,
      changeIds: changeIds,
      changeIdStride: changeIdStride,
      flags: flags,
      changeOffsets: changeOffsets,
      changeIdPrefixLengths: changePrefix,
      commitIdPrefixLengths: commitPrefix,
      parentCounts: parentCounts,
      edgeStarts: edgeStarts,
      edgeTargets: edgeTargets,
      edgeKinds: edgeKinds,
      timestamps: timestamps,
      anchorStarts: anchorStarts,
      anchorNodesFlat: anchorNodes,
    );
  }

  /// Flag bit: this workspace's `@`.
  static const int flagWorkingCopy = 1 << 0;

  /// Flag bit: contained in `::(immutable_heads() | root())`.
  static const int flagImmutable = 1 << 1;

  /// Flag bit: the commit is not visible.
  static const int flagHidden = 1 << 2;

  /// Flag bit: the change id resolves to more than one visible commit.
  static const int flagDivergent = 1 << 3;

  /// Flag bit: the repository's root commit.
  static const int flagRoot = 1 << 4;

  /// Flag bit: [changeOffset] is present.
  static const int flagHasChangeOffset = 1 << 5;

  /// The envelope bytes every view reads, unmodifiable.
  final Uint8List bytes;

  /// The full hex id of the operation the call loaded (after its own pre-verb
  /// snapshot); pass it to `RepoHandle.commitContents` for card content.
  final String operationId;

  /// The operations the revset's `at_operation()`s brought in (full hex), in
  /// order; empty without them. Pass them to `RepoHandle.commitContents` with
  /// [operationId]: their commits may be outside that operation's index.
  final List<String> extraOperationIds;

  /// `|all()|` — the VISIBLE commits only, so a revset naming hidden commits
  /// can yield more nodes than this.
  final int allCount;

  /// The call's warnings (Story 9.32), in the CLI's print order; empty when
  /// there were none.
  final List<ZanshinWarning> warnings;

  /// The number of nodes, n.
  final int nodeCount;

  /// How many scalar vectors were copied because they were not aligned for
  /// their element size in [bytes]; 0 for a buffer that starts aligned.
  @visibleForTesting
  int get copiedVectorCount => _copiedVectorCount;

  /// One flags byte per node (see the `flag*` bit constants), unmodifiable.
  final Uint8List flags;

  /// One parent count per node — the commit's real parent count, Missing
  /// parents included (0 for the root), unmodifiable.
  final Uint32List parentCounts;

  /// The edges' CSR offsets: n + 1 entries, unmodifiable.
  final Uint32List edgeStarts;

  /// One target slot per edge, −1 for a Missing edge, unmodifiable.
  final Int32List edgeTargets;

  /// One `GraphEdgeKind` value per edge (0 direct, 1 indirect, 2 missing),
  /// unmodifiable.
  final Int8List edgeKinds;

  /// One committer timestamp (epoch ms) per node, the root's slot 0;
  /// `null` when none were requested. Unmodifiable.
  final Int64List? timestamps;

  /// The anchors' CSR offsets: anchors + 1 entries, unmodifiable.
  final Uint32List anchorStarts;

  /// Every anchor's node indices, concatenated (see [anchorStarts]),
  /// unmodifiable.
  final Uint32List anchorNodesFlat;

  final int _copiedVectorCount;
  final List<fbs.TopologyRef> _wireRefs;
  final List<fbs.TopologyWorkingCopy> _wireWorkingCopies;
  final Uint8List _commitIds;
  final int _commitIdStride;
  final Uint8List _changeIds;
  final int _changeIdStride;
  final Uint8List _flags;
  final Uint32List _changeOffsets;
  final Uint8List _changeIdPrefixLengths;
  final Uint8List _commitIdPrefixLengths;
  final Uint32List _parentCounts;
  final Uint32List _edgeStarts;
  final Int32List _edgeTargets;
  final Int8List _edgeKinds;
  final Int64List? _timestamps;
  final Uint32List _anchorStarts;
  final Uint32List _anchorNodes;
  final Uint8List _commitScratch;
  final Uint8List _changeScratch;

  /// Node [i]'s full commit id, lowercase hex.
  String commitId(int i) => _format(_commitIds, i, _commitIdStride, _hexDigits, _commitScratch);

  /// Node [i]'s change id in jj reverse-hex (`z` = 0 … `k` = 15). Divergent
  /// commits share it.
  String changeId(int i) => _format(_changeIds, i, _changeIdStride, _reverseHexDigits, _changeScratch);

  /// The shortest unique prefix length of [commitId], in hex digits.
  int commitIdPrefixLength(int i) => _commitIdPrefixLengths[i];

  /// The shortest unique prefix length of [changeId], in hex digits.
  int changeIdPrefixLength(int i) => _changeIdPrefixLengths[i];

  /// This workspace's `@`.
  bool isWorkingCopy(int i) => _flags[i] & flagWorkingCopy != 0;

  /// Contained in `::(immutable_heads() | root())`.
  bool isImmutable(int i) => _flags[i] & flagImmutable != 0;

  /// The commit is not visible (reachable only when the revset names it).
  bool isHidden(int i) => _flags[i] & flagHidden != 0;

  /// The change id resolves to more than one visible commit.
  bool isDivergent(int i) => _flags[i] & flagDivergent != 0;

  /// The repository's root commit.
  bool isRoot(int i) => _flags[i] & flagRoot != 0;

  /// Node [i]'s index among the commits sharing its change id, or `null` when
  /// jj-lib yields none. The CLI renders it only for hidden/divergent commits.
  int? changeOffset(int i) => _flags[i] & flagHasChangeOffset != 0 ? _changeOffsets[i] : null;

  /// The commit's real parent count, Missing parents included.
  int parentCount(int i) => _parentCounts[i];

  /// The first edge index of node [i].
  int edgeStart(int i) => _edgeStarts[i];

  /// One past the last edge index of node [i].
  int edgeEnd(int i) => _edgeStarts[i + 1];

  /// Edge [e]'s target node index, or `null` for a Missing edge.
  int? edgeTarget(int e) => edgeKind(e) == GraphEdgeKind.missing ? null : _edgeTargets[e];

  /// How jj classified edge [e]. Throws `ffi.unknown` for a byte that is no
  /// `GraphEdgeKind`.
  GraphEdgeKind edgeKind(int e) => switch (_edgeKinds[e]) {
    0 => GraphEdgeKind.direct,
    1 => GraphEdgeKind.indirect,
    2 => GraphEdgeKind.missing,
    final int other => throw ZanshinFfiException('ffi.unknown', 'GraphTopology.edge_kind[$e] is $other'),
  };

  /// Whether the call requested the committer timestamps.
  bool get hasTimestamps => _timestamps != null;

  /// Node [i]'s committer timestamp (epoch ms), or `null` when none were
  /// requested — and always for the root, which carries none.
  int? timestamp(int i) {
    final bool root = isRoot(i);
    final Int64List? all = _timestamps;
    return all == null || root ? null : all[i];
  }

  /// Every bookmark and tag entry, sorted by node; per node its bookmarks,
  /// then its tags. Built on first access.
  late final List<TopologyRef> refs = List.unmodifiable(_wireRefs.map(_mapRef));

  /// Node [i]'s bookmarks then tags.
  List<TopologyRef> refsOf(int i) {
    RangeError.checkValidIndex(i, this, 'i', nodeCount);
    final List<TopologyRef> all = refs;
    return all.sublist(
      _lowerBound(all.length, (k) => all[k].node, i),
      _lowerBound(all.length, (k) => all[k].node, i + 1),
    );
  }

  /// Every workspace working copy, sorted by node. Built on first access.
  late final List<TopologyWorkingCopy> workingCopies = List.unmodifiable(_wireWorkingCopies.map(_mapWorkingCopy));

  /// The workspaces whose working-copy commit node [i] is.
  List<TopologyWorkingCopy> workingCopiesOf(int i) {
    RangeError.checkValidIndex(i, this, 'i', nodeCount);
    final List<TopologyWorkingCopy> all = workingCopies;
    return all.sublist(
      _lowerBound(all.length, (k) => all[k].node, i),
      _lowerBound(all.length, (k) => all[k].node, i + 1),
    );
  }

  /// The number of anchors the call was given.
  int get anchorCount => _anchorStarts.length - 1;

  /// Anchor [a]'s node indices, ascending (= `jj log` order), unmodifiable.
  Uint32List anchorNodes(int a) =>
      Uint32List.sublistView(_anchorNodes, _anchorStarts[a], _anchorStarts[a + 1]).asUnmodifiableView();

  /// The node index of the commit with the full hex id [commitId], or `null`.
  /// The lookup is built on the first call.
  int? indexOfCommitId(String commitId) => _commitIndex[commitId];

  /// The node indices of the commits with the reverse-hex change id [changeId]
  /// — several for a divergent change — ascending; `[]` when there is none.
  /// The lookup is built on the first call.
  List<int> indicesOfChangeId(String changeId) => switch (_changeIndex[changeId]) {
    null => const [],
    final int index => List.unmodifiable([index]),
    final List<int> indices => List.unmodifiable(indices),
    _ => throw StateError('unreachable change-index entry'),
  };

  late final Map<String, int> _commitIndex = {for (var i = 0; i < nodeCount; i++) commitId(i): i};

  // An `int` for a change id one node carries, a `List<int>` for several.
  late final Map<String, Object> _changeIndex = _buildChangeIndex();

  Map<String, Object> _buildChangeIndex() {
    final index = <String, Object>{};
    for (var i = 0; i < nodeCount; i++) {
      final String id = changeId(i);
      index[id] = switch (index[id]) {
        null => i,
        final int first => [first, i],
        final List<int> more => more..add(i),
        _ => throw StateError('unreachable change-index entry'),
      };
    }
    return index;
  }

  String _format(Uint8List column, int i, int stride, Uint8List digits, Uint8List scratch) {
    RangeError.checkValidIndex(i, this, 'i', nodeCount);
    final int start = i * stride;
    for (var k = 0; k < stride; k++) {
      final int byte = column[start + k];
      scratch[2 * k] = digits[byte >> 4];
      scratch[2 * k + 1] = digits[byte & 0x0f];
    }
    return String.fromCharCodes(scratch);
  }
}

/// The first index in `[0, length)` whose node is `>= node` (the list is sorted
/// by node).
int _lowerBound(int length, int Function(int) nodeAt, int node) {
  var lo = 0;
  var hi = length;
  while (lo < hi) {
    final int mid = (lo + hi) >> 1;
    if (nodeAt(mid) < node) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

TopologyRef _mapRef(fbs.TopologyRef r) => TopologyRef(
  node: r.node,
  kind: switch (r.kind) {
    fbs.TopologyRefKind.Bookmark => TopologyRefKind.bookmark,
    fbs.TopologyRefKind.Tag => TopologyRefKind.tag,
  },
  name: r.name ?? (throw _missing('refs[].name')),
  remote: r.remote, // absent for the local entry
  synced: r.synced,
  conflicted: r.conflicted,
  tracked: r.tracked,
);

TopologyWorkingCopy _mapWorkingCopy(fbs.TopologyWorkingCopy w) =>
    TopologyWorkingCopy(node: w.node, workspace: w.workspace ?? (throw _missing('working_copies[].workspace')));

/// A structurally required field Rust always writes is absent: a malformed
/// buffer, not a modellable state — never a `?? ''` / `?? []` coercion.
ZanshinFfiException _missing(String field) => ZanshinFfiException('ffi.unknown', 'GraphTopology is missing its $field');

/// Locates the payload's scalar vectors by hand and hands out typed-data views.
final class _Vectors {
  _Vectors(this._bytes) : _bc = fb.BufferContext.fromBytes(_bytes) {
    final int envelope = _bc.derefObject(0);
    _table =
        const _TablePosition().vTableGetNullable(_bc, envelope, _envelopeDataVTableOffset) ??
        (throw _missing('payload table'));
  }

  final Uint8List _bytes;
  final fb.BufferContext _bc;
  late final int _table;

  /// Vectors copied because they were misaligned.
  var copied = 0;

  /// `(start, length)` of vector field [index], or `null` when it is absent.
  (int, int)? _locate(int index, String name, int elementSize, int? expected) {
    final int? pos = const _VectorPosition().vTableGetNullable(_bc, _table, 4 + 2 * index);
    if (pos == null) {
      return null;
    }
    final int length = _bc.buffer.getUint32(pos, Endian.little);
    if (expected != null && length != expected) {
      throw ZanshinFfiException('ffi.unknown', 'GraphTopology.$name has $length entries, expected $expected');
    }
    final int start = pos + 4;
    if (start + length * elementSize > _bytes.lengthInBytes) {
      throw ZanshinFfiException('ffi.unknown', 'GraphTopology.$name runs past the end of the buffer');
    }
    return (start, length);
  }

  (int, int) _required(int index, String name, int elementSize, int? expected) =>
      _locate(index, name, elementSize, expected) ?? (throw _missing(name));

  /// The buffer and absolute offset of a vector of [elementSize]-byte
  /// elements: [_bytes]' own buffer when the vector is aligned there, else a
  /// copy of that vector alone (offset 0).
  (ByteBuffer, int) _aligned(int start, int length, int elementSize) {
    final int absolute = _bytes.offsetInBytes + start;
    if (absolute % elementSize == 0) {
      return (_bytes.buffer, absolute);
    }
    copied++;
    return (Uint8List.fromList(Uint8List.sublistView(_bytes, start, start + length * elementSize)).buffer, 0);
  }

  Uint8List uint8(int index, String name, [int? expected]) {
    final (int start, int length) = _required(index, name, 1, expected);
    return Uint8List.sublistView(_bytes, start, start + length);
  }

  Int8List int8(int index, String name, int expected) {
    final (int start, int length) = _required(index, name, 1, expected);
    return Int8List.sublistView(_bytes, start, start + length);
  }

  Uint32List uint32(int index, String name, [int? expected]) {
    final (int start, int length) = _required(index, name, 4, expected);
    final (ByteBuffer buffer, int offset) = _aligned(start, length, 4);
    return buffer.asUint32List(offset, length);
  }

  Int32List int32(int index, String name, int expected) {
    final (int start, int length) = _required(index, name, 4, expected);
    final (ByteBuffer buffer, int offset) = _aligned(start, length, 4);
    return buffer.asInt32List(offset, length);
  }

  Int64List? int64OrNull(int index, String name, int expected) {
    final (int, int)? location = _locate(index, name, 8, expected);
    if (location == null) {
      return null;
    }
    final (int start, int length) = location;
    final (ByteBuffer buffer, int offset) = _aligned(start, length, 8);
    return buffer.asInt64List(offset, length);
  }
}

/// Reads a table-valued field as the table's absolute position.
final class _TablePosition extends fb.TableReader<int> {
  const _TablePosition();

  @override
  int createObject(fb.BufferContext bc, int offset) => offset;
}

/// Reads a vector-valued field as the absolute position of its length prefix.
final class _VectorPosition extends fb.Reader<int> {
  const _VectorPosition();

  @override
  int get size => 4;

  @override
  int read(fb.BufferContext bc, int offset) => bc.derefObject(offset);
}
