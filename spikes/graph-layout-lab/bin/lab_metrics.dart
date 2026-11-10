import 'dart:io';

import 'package:zanshin_core/src/graph_layout/layout_request.dart';

import '../lib/data.dart';
import '../lib/scene.dart';

/// Prints the lab's metrics for every data set under `<data dir>`, in both modes, with and without stacks:
/// the numbers to compare before and after a rule change. [rules] as in `lab_layout.dart`:
/// missing = the defaults, empty = all off.
///
/// usage: dart --packages=<repo>/.dart_tool/package_config.json run bin/lab_metrics.dart <data dir> [rules]
void main(List<String> a) {
  final Set<String> rules = a.length > 1 ? a[1].split(',').where((r) => r.isNotEmpty).toSet() : defaultRules();
  final names = [
    for (final FileSystemEntity f in Directory(a[0]).listSync())
      if (f.path.endsWith('.json') && !f.path.endsWith('.meta.json')) f.uri.pathSegments.last.replaceAll('.json', ''),
  ]..sort();
  for (final String name in names) {
    final d = LabData.load(a[0], name);
    for (final stacks in [true, false]) {
      for (final LayoutMode mode in LayoutMode.values) {
        final Map<String, Object?> scene = buildScene(d, lab: true, mode: mode, stacks: stacks, rules: rules);
        stdout.writeln('$name ${mode.name}${stacks ? '' : ', no stacks'}: ${scene['metrics']}');
      }
    }
  }
}
