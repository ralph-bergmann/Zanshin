import 'input.dart';
import 'layout.dart';

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
  out.write(']}\n');
  return out.toString();
}

/// The bench digest of SPEC §8.4.
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
