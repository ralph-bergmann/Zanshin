import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zanshin_core/src/graph_layout/layout_input.dart';

import '../../../packages/zanshin_core/test/graph_layout/support/spec_json.dart';

/// One data set of `tools/replica.sh`: the layout input and, per node, what its card shows.
final class LabData {
  LabData(this.input, this.meta);

  /// Reads `<dataDir>/<name>.json` and its `.meta.json` sidecar.
  factory LabData.load(String dataDir, String name) {
    final LayoutInput input = parseSpecInput(File('$dataDir/$name.json').readAsBytesSync()).input;
    final Object? sidecar = jsonDecode(File('$dataDir/$name.meta.json').readAsStringSync());
    final List<Object?> nodes = (sidecar! as Map<String, Object?>)['nodes']! as List<Object?>;
    return LabData(input, [for (final Object? node in nodes) node! as Map<String, Object?>]);
  }

  final LayoutInput input;

  /// The sidecar's entry of every node: `description`, `author`, `change_id`, `bookmarks`, …
  final List<Map<String, Object?>> meta;

  /// The stack request the app starts with: every run is collapsed.
  StackInput stackInput() {
    final int n = input.n;
    final immutable = Uint8List(n);
    final parentCount = Int32List(n);
    final hasRef = Uint8List(n);
    final workingCopy = Uint8List(n);
    for (var i = 0; i < n; i++) {
      final Map<String, Object?> m = meta[i];
      immutable[i] = m['immutable'] == true ? 1 : 0;
      parentCount[i] = input.parStart[i + 1] - input.parStart[i];
      hasRef[i] = (m['bookmarks']! as List).isNotEmpty || (m['tags']! as List).isNotEmpty ? 1 : 0;
      workingCopy[i] = m['working_copy'] == true
          ? workingCopyThis
          : ((m['working_copies']! as List).isNotEmpty ? workingCopyOther : workingCopyNone);
    }
    return StackInput(
      immutable: immutable,
      parentCount: parentCount,
      hasRef: hasRef,
      workingCopy: workingCopy,
      expandedNodes: Int32List(0),
      collapsedNodes: Int32List(0),
      keepOpenNodes: Int32List(0),
    );
  }
}
