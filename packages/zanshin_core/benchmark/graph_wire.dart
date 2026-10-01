// SPDX-License-Identifier: MIT

// Story 4.12: the graph topology wire, Dart side.
//
// Part 1: the two layout comparisons the `GraphTopology` schema was decided by,
// built with `fb.Builder` — OQ 2, the commit/change id columns as `[string]`
// (option (a)) vs fixed-stride `[ubyte]` (option (b)), and the node flags as one
// packed `[ubyte]` vs six `[bool]` vectors. Per layout it prints the finished
// bytes, the build time and the FIRST-ACCESS time: every id read as a `String`
// (every flag read) from a fresh `BufferContext`. It runs on synthetic ids
// (n = 1,002, 10,002 and 100,000) and, for each repo directory given as an
// argument, on that repo's real ids and flags.
//
// Part 2 (per repo directory, real worker isolate + real cdylib): the chosen
// wire — `RepoHandle.graphTopology(all(), anchors: defaultGraphAnchors)` with
// timestamps off and on: the call total (FFI call, the one copy, the transfer,
// the view), the envelope bytes, the view construction alone, a full pass over
// every node (ids, flags, edges), the id → index lookup build and the view's
// copied-vector count.
//
// Prints numbers only (min / median of 21 runs after 5 warm-up runs); asserts
// nothing. Run from `packages/zanshin_core` with the env of `Makefile.toml`'s
// `[tasks.test-core]` (plus `ZANSHIN_LOG=error` to keep the console quiet):
//
// ```sh
// dart run benchmark/graph_wire.dart [<repo dir> ...]
// ```

import 'dart:math';
import 'dart:typed_data';

import 'package:flat_buffers/flat_buffers.dart' as fb;
import 'package:zanshin_core/src/ffi/graph.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';

const _warmup = 5;
const _runs = 21;

Future<void> main(List<String> args) async {
  for (final n in const [1002, 10002, 100000]) {
    final rng = Random(4012);
    _benchLayouts(
      'synthetic $n',
      _Ids(
        commitBytes: Uint8List.fromList([for (var i = 0; i < n * 20; i++) rng.nextInt(256)]),
        commitStride: 20,
        changeBytes: Uint8List.fromList([for (var i = 0; i < n * 16; i++) rng.nextInt(256)]),
        changeStride: 16,
        flags: Uint8List.fromList([for (var i = 0; i < n; i++) rng.nextInt(64)]),
      ),
    );
  }
  for (final dir in args) {
    await _benchRepo(dir);
  }
}

// ── Timing ───────────────────────────────────────────────────────────────────

/// `(min, median)` in microseconds over [_runs] timed runs after [_warmup].
(int, int) _measure(void Function() f) => _measureWith(() {}, (_) => f());

/// [_measure] with an untimed per-run [setup] whose result [f] receives.
(int, int) _measureWith<S>(S Function() setup, void Function(S) f) {
  for (var i = 0; i < _warmup; i++) {
    f(setup());
  }
  final samples = <int>[];
  for (var i = 0; i < _runs; i++) {
    final S state = setup();
    final sw = Stopwatch()..start();
    f(state);
    samples.add(sw.elapsedMicroseconds);
  }
  samples.sort();
  return (samples.first, samples[samples.length ~/ 2]);
}

/// [_measure] for an asynchronous [f].
Future<(int, int)> _measureAsync(Future<void> Function() f) async {
  for (var i = 0; i < _warmup; i++) {
    await f();
  }
  final samples = <int>[];
  for (var i = 0; i < _runs; i++) {
    final sw = Stopwatch()..start();
    await f();
    samples.add(sw.elapsedMicroseconds);
  }
  samples.sort();
  return (samples.first, samples[samples.length ~/ 2]);
}

void _report(String store, String what, (int, int) t) {
  final (min, med) = t;
  print('[$store] $what: min $min µs / med $med µs');
}

void _reportBytes(String store, String what, int bytes, int n) {
  print('[$store] $what: $bytes B (${n == 0 ? 0 : bytes ~/ n} B/node)');
}

// ── Part 1: the layout comparisons ───────────────────────────────────────────

/// The raw id columns (one stride each) and the packed flags of n nodes.
final class _Ids {
  _Ids({
    required this.commitBytes,
    required this.commitStride,
    required this.changeBytes,
    required this.changeStride,
    required this.flags,
  });

  final Uint8List commitBytes;
  final int commitStride;
  final Uint8List changeBytes;
  final int changeStride;
  final Uint8List flags;

  int get n => flags.length;
}

void _benchLayouts(String store, _Ids ids) {
  final int n = ids.n;
  final List<String> commitIds = [
    for (var i = 0; i < n; i++) _format(ids.commitBytes, i * ids.commitStride, ids.commitStride, _hexDigits),
  ];
  final List<String> changeIds = [
    for (var i = 0; i < n; i++) _format(ids.changeBytes, i * ids.changeStride, ids.changeStride, _reverseHexDigits),
  ];

  final Uint8List a = _idsAsStrings(commitIds, changeIds);
  final Uint8List b = _idsAsStrideBytes(ids);
  _reportBytes(store, 'OQ 2 (a) ids as [string]', a.length, n);
  _reportBytes(store, 'OQ 2 (b) ids as stride [ubyte]', b.length, n);
  _report(store, 'OQ 2 (a) ids as [string] build', _measure(() => _idsAsStrings(commitIds, changeIds)));
  _report(store, 'OQ 2 (b) ids as stride [ubyte] build', _measure(() => _idsAsStrideBytes(ids)));
  _report(store, 'OQ 2 (a) first access, generated StringReader', _measure(() => _readStrings(a, ascii: false)));
  _report(store, 'OQ 2 (a) first access, ASCII-optimised StringReader', _measure(() => _readStrings(a, ascii: true)));
  _report(store, 'OQ 2 (b) first access, typed view + formatting', _measure(() => _readStrideBytes(b)));

  final Uint8List packed = _flagsPacked(ids.flags);
  final Uint8List bools = _flagsAsBools(ids.flags);
  _reportBytes(store, 'flags packed [ubyte]', packed.length, n);
  _reportBytes(store, 'flags six [bool]', bools.length, n);
  _report(store, 'flags packed [ubyte] build', _measure(() => _flagsPacked(ids.flags)));
  _report(store, 'flags six [bool] build', _measure(() => _flagsAsBools(ids.flags)));
  _report(store, 'flags packed [ubyte] first access', _measure(() => _readFlagsPacked(packed)));
  _report(store, 'flags six [bool] first access', _measure(() => _readFlagsAsBools(bools)));
}

/// Option (a): two `[string]` columns.
Uint8List _idsAsStrings(List<String> commitIds, List<String> changeIds) {
  final b = fb.Builder(initialSize: 64 + commitIds.length * 100);
  final int commit = b.writeList([for (final id in commitIds) b.writeString(id)]);
  final int change = b.writeList([for (final id in changeIds) b.writeString(id)]);
  b
    ..startTable(2)
    ..addOffset(0, commit)
    ..addOffset(1, change);
  b.finish(b.endTable());
  return b.buffer;
}

/// Option (b): two `n × stride` `[ubyte]` columns plus the strides.
Uint8List _idsAsStrideBytes(_Ids ids) {
  final b = fb.Builder(initialSize: 64 + ids.commitBytes.length + ids.changeBytes.length);
  final int commit = b.writeListUint8(ids.commitBytes);
  final int change = b.writeListUint8(ids.changeBytes);
  b
    ..startTable(4)
    ..addOffset(0, commit)
    ..addOffset(1, change)
    ..addUint8(2, ids.commitStride)
    ..addUint8(3, ids.changeStride);
  b.finish(b.endTable());
  return b.buffer;
}

/// Reads every id of both `[string]` columns, as the generated accessors would.
int _readStrings(Uint8List bytes, {required bool ascii}) {
  final bc = fb.BufferContext.fromBytes(bytes);
  final int root = bc.derefObject(0);
  final reader = fb.ListReader<String>(fb.StringReader(asciiOptimization: ascii));
  final List<String> commit = reader.vTableGet(bc, root, 4, const []);
  final List<String> change = reader.vTableGet(bc, root, 6, const []);
  var total = 0;
  for (var i = 0; i < commit.length; i++) {
    total += commit[i].length + change[i].length;
  }
  return total;
}

/// Reads every id of both stride columns: the vector located by hand, a typed
/// view over it, each id formatted on access — what `GraphTopologyView` does.
int _readStrideBytes(Uint8List bytes) {
  final bc = fb.BufferContext.fromBytes(bytes);
  final int root = bc.derefObject(0);
  final Uint8List commit = _uint8Vector(bytes, bc, root, 4);
  final Uint8List change = _uint8Vector(bytes, bc, root, 6);
  final int commitStride = const fb.Uint8Reader().vTableGet(bc, root, 8, 0);
  final int changeStride = const fb.Uint8Reader().vTableGet(bc, root, 10, 0);
  final int n = commitStride == 0 ? 0 : commit.length ~/ commitStride;
  var total = 0;
  for (var i = 0; i < n; i++) {
    total +=
        _format(commit, i * commitStride, commitStride, _hexDigits).length +
        _format(change, i * changeStride, changeStride, _reverseHexDigits).length;
  }
  return total;
}

/// The view's id formatter: two digits per byte, high nibble first.
String _format(Uint8List bytes, int start, int stride, Uint8List digits) {
  final codes = Uint8List(stride * 2);
  for (var i = 0; i < stride; i++) {
    final int byte = bytes[start + i];
    codes[2 * i] = digits[byte >> 4];
    codes[2 * i + 1] = digits[byte & 0x0f];
  }
  return String.fromCharCodes(codes);
}

final _hexDigits = Uint8List.fromList('0123456789abcdef'.codeUnits);
final _reverseHexDigits = Uint8List.fromList('zyxwvutsrqponmlk'.codeUnits);

/// The six flags packed into one byte per node.
Uint8List _flagsPacked(Uint8List flags) {
  final b = fb.Builder(initialSize: 64 + flags.length);
  final int v = b.writeListUint8(flags);
  b
    ..startTable(1)
    ..addOffset(0, v);
  b.finish(b.endTable());
  return b.buffer;
}

/// The six flags as six `[bool]` vectors.
Uint8List _flagsAsBools(Uint8List flags) {
  final b = fb.Builder(initialSize: 64 + 6 * flags.length);
  final List<int> offsets = [
    for (var bit = 0; bit < 6; bit++) b.writeListBool([for (final f in flags) f & (1 << bit) != 0]),
  ];
  b.startTable(6);
  for (var i = 0; i < 6; i++) {
    b.addOffset(i, offsets[i]);
  }
  b.finish(b.endTable());
  return b.buffer;
}

int _readFlagsPacked(Uint8List bytes) {
  final bc = fb.BufferContext.fromBytes(bytes);
  final Uint8List flags = _uint8Vector(bytes, bc, bc.derefObject(0), 4);
  var set = 0;
  for (var i = 0; i < flags.length; i++) {
    final int f = flags[i];
    for (var bit = 0; bit < 6; bit++) {
      if (f & (1 << bit) != 0) {
        set++;
      }
    }
  }
  return set;
}

int _readFlagsAsBools(Uint8List bytes) {
  final bc = fb.BufferContext.fromBytes(bytes);
  final int root = bc.derefObject(0);
  final List<Uint8List> columns = [for (var i = 0; i < 6; i++) _uint8Vector(bytes, bc, root, 4 + 2 * i)];
  var set = 0;
  for (var node = 0; node < columns.first.length; node++) {
    for (final column in columns) {
      if (column[node] != 0) {
        set++;
      }
    }
  }
  return set;
}

/// A `[ubyte]`/`[bool]` vector of the table at [table], located by hand: a
/// view over [bytes], never a copy (a byte vector is always aligned).
Uint8List _uint8Vector(Uint8List bytes, fb.BufferContext bc, int table, int vtableOffset) {
  final int pos = const _VectorPosition().vTableGet(bc, table, vtableOffset, -1);
  final int length = bc.buffer.getUint32(pos, Endian.little);
  return bytes.buffer.asUint8List(bytes.offsetInBytes + pos + 4, length);
}

/// Reads a vector field as the absolute position of its length prefix.
final class _VectorPosition extends fb.Reader<int> {
  const _VectorPosition();

  @override
  int get size => 4;

  @override
  int read(fb.BufferContext bc, int offset) => bc.derefObject(offset);
}

// ── Part 2: the chosen wire on a real repo ───────────────────────────────────

Future<void> _benchRepo(String dir) async {
  final store = dir;
  final ZanshinWorker worker = await ZanshinWorker.start();
  try {
    final RepoHandle handle = await worker.openRepo(dir);
    late GraphTopologyView view;
    for (final withTimestamps in const [false, true]) {
      final label = withTimestamps ? 'timestamps on' : 'timestamps off';
      _report(
        store,
        'graphTopology call total, $label',
        await _measureAsync(() async {
          view = await handle.graphTopology(
            revset: 'all()',
            anchors: defaultGraphAnchors,
            withTimestamps: withTimestamps,
          );
        }),
      );
      final Uint8List bytes = view.bytes;
      _reportBytes(store, 'GraphTopology envelope, $label', bytes.length, view.nodeCount);
      // WHY ignore: the count is a test/measurement hook by design (no production reader);
      // this measurement script lives in benchmark/, which the lint does not treat as a test.
      // ignore: invalid_use_of_visible_for_testing_member
      print('[$store] copiedVectorCount, $label: ${view.copiedVectorCount}');
      _report(store, 'view construction, $label', _measure(() => GraphTopologyView.fromEnvelope(bytes)));
      _report(store, 'full pass over every node (ids, flags, edges), $label', _measure(() => _fullPass(view)));
      _report(
        store,
        'lookup build (commit id + change id), $label',
        _measureWith(() => GraphTopologyView.fromEnvelope(bytes), (fresh) {
          fresh
            ..indexOfCommitId('')
            ..indicesOfChangeId('');
        }),
      );
    }
    _benchLayouts(store, _realIds(view));
    await handle.close();
  } finally {
    await worker.close();
  }
}

/// Reads every node's ids, flags and edges once.
int _fullPass(GraphTopologyView view) {
  var total = 0;
  for (var i = 0; i < view.nodeCount; i++) {
    total += view.commitId(i).length + view.changeId(i).length;
    if (view.isWorkingCopy(i) || view.isImmutable(i) || view.isHidden(i) || view.isDivergent(i) || view.isRoot(i)) {
      total++;
    }
    for (int e = view.edgeStart(i); e < view.edgeEnd(i); e++) {
      total += (view.edgeTarget(e) ?? 0) + view.edgeKind(e).index;
    }
  }
  return total;
}

/// The view's real id columns and flags, re-encoded from the formatted ids.
_Ids _realIds(GraphTopologyView view) {
  final int n = view.nodeCount;
  final int commitStride = n == 0 ? 0 : view.commitId(0).length ~/ 2;
  final int changeStride = n == 0 ? 0 : view.changeId(0).length ~/ 2;
  final commitBytes = Uint8List(n * commitStride);
  final changeBytes = Uint8List(n * changeStride);
  for (var i = 0; i < n; i++) {
    _parse(view.commitId(i), _hexDigits, commitBytes, i * commitStride);
    _parse(view.changeId(i), _reverseHexDigits, changeBytes, i * changeStride);
  }
  return _Ids(
    commitBytes: commitBytes,
    commitStride: commitStride,
    changeBytes: changeBytes,
    changeStride: changeStride,
    flags: Uint8List.fromList(view.flags),
  );
}

/// Writes the bytes of the formatted id [id] (alphabet [digits]) at [start].
void _parse(String id, Uint8List digits, Uint8List out, int start) {
  for (var k = 0; k < id.length ~/ 2; k++) {
    out[start + k] = digits.indexOf(id.codeUnitAt(2 * k)) << 4 | digits.indexOf(id.codeUnitAt(2 * k + 1));
  }
}
