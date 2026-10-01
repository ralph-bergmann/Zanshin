import 'input.dart';
import 'layout.dart';
import 'stacks.dart';

/// The canonical output JSON of SPEC §3: fixed key order, no whitespace, one trailing newline.
String encodeOutput(LayoutResult r) {
  final out = StringBuffer()
    ..write('{"mode":"')
    ..write(r.mode.name)
    ..write('","order":"')
    ..write(r.order.name)
    ..write('","unit":')
    ..write(r.unit)
    ..write(',"rows":')
    ..write(r.rows)
    ..write(',"lanes":')
    ..write(r.lanes)
    ..write(',"nodes":[');
  for (var i = 0; i < r.row.length; i++) {
    if (i > 0) out.write(',');
    if (r.lane[i] < 0) {
      out.write('null'); // a hidden stack member (SPEC §3, amended 2026-10-01)
      continue;
    }
    out
      ..write('{"row":')
      ..write(r.row[i])
      ..write(',"lane":')
      ..write(r.lane[i])
      ..write(',"col":')
      ..write(r.col[i])
      ..write('}');
  }
  out.write('],"edges":[');
  for (var e = 0; e < r.edgeFrom.length; e++) {
    if (e > 0) out.write(',');
    out
      ..write('{"from":')
      ..write(r.edgeFrom[e])
      ..write(',"to":')
      ..write(r.edgeTo[e])
      ..write(',"kind":"')
      ..write(kindNames[r.edgeKind[e]])
      ..write('","route":"')
      ..write(routeNames[r.edgeRoute[e]])
      ..write('","blocked":')
      ..write(r.edgeBlocked[e] != 0 ? 'true' : 'false')
      ..write('}');
  }
  out.write('],"buckets":[');
  for (var b = 0; b < r.bucketKind.length; b++) {
    if (b > 0) out.write(',');
    out
      ..write('{"kind":"')
      ..write(bucketKindNames[r.bucketKind[b]])
      ..write('","value":')
      ..write(r.bucketValue[b])
      ..write(',"start":')
      ..write(r.bucketStart[b])
      ..write(',"end":')
      ..write(r.bucketEnd[b])
      ..write('}');
  }
  out.write(']');
  final runStart = r.runStart, runMembers = r.runMembers, runState = r.runState, runNode = r.runNode;
  if (runStart != null && runMembers != null && runState != null && runNode != null) {
    // SPEC §3, amended 2026-10-01 (Story 4.13): the runs after the buckets.
    out.write(',"runs":[');
    for (var k = 0; k + 1 < runStart.length; k++) {
      if (k > 0) out.write(',');
      out.write('{"members":[');
      for (var j = runStart[k]; j < runStart[k + 1]; j++) {
        if (j > runStart[k]) out.write(',');
        out.write(runMembers[j]);
      }
      out
        ..write('],"state":"')
        ..write(runStateNames[runState[k]])
        ..write('","node":')
        ..write(runNode[k] < 0 ? 'null' : runNode[k])
        ..write('}');
    }
    out.write(']');
  }
  out.write('}\n');
  return out.toString();
}

/// The bench digest of SPEC §8.4; with stacks over the n + S node entries, a hidden member
/// counting as row = col = lane = −1 (SPEC §6, amended 2026-10-01).
int digest(LayoutResult r) {
  const p = 1000000007;
  var d = 0;
  for (var i = 0; i < r.row.length; i++) {
    d = (31 * d + 7 * r.row[i] + 3 * r.col[i] + r.lane[i]) % p;
  }
  for (var e = 0; e < r.edgeRoute.length; e++) {
    d = (31 * d + r.edgeRoute[e] + 4 * r.edgeBlocked[e]) % p;
  }
  for (var b = 0; b < r.bucketStart.length; b++) {
    d = (31 * d + r.bucketStart[b] + 3 * r.bucketEnd[b]) % p;
  }
  return d;
}
