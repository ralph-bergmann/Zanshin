import 'dart:io';

import 'package:zanshin_core/src/graph_layout/layout_request.dart';

import '../lib/data.dart';
import '../lib/scene.dart';

/// Prints the lab's and the product's metrics for every data set under `<data dir>`, in both modes, with and without
/// stacks: the numbers to compare before and after a rule change. [rules] as in `lab_layout.dart`: missing = the
/// defaults, empty = all off. The rules apply to the lab's lines; the product's are the product's.
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
        final what = '$name ${mode.name}${stacks ? '' : ', no stacks'}';
        final Map<String, Object?> lab = buildScene(d, lab: true, mode: mode, stacks: stacks, rules: rules);
        final Map<String, Object?> product = buildScene(d, lab: false, mode: mode, stacks: stacks, rules: rules);
        stdout
          ..writeln('$what: ${lab['metrics']}')
          ..writeln('$what, product: ${product['metrics']}');
      }
    }
  }
}
