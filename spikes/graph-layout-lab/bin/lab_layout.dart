import 'dart:convert';
import 'dart:io';

import 'package:zanshin_core/src/graph_layout/layout_request.dart';

import '../lib/data.dart';
import '../lib/scene.dart';

/// Lays one data set out and prints what the page draws, as JSON.
///
/// usage: lab_layout.dart <data dir> <data set> <lab|app> <free|compact> <stacks: 1|0> [rule ids, comma-separated]
/// Without the last argument the rules' defaults apply; an empty one switches every rule off.
/// Run it with the workspace's packages: `dart --packages=<repo>/.dart_tool/package_config.json run bin/lab_layout.dart …`
void main(List<String> a) {
  if (a.length < 5) {
    stderr.writeln('usage: lab_layout.dart <data dir> <data set> <lab|app> <free|compact> <1|0> [rules]');
    exitCode = 2;
    return;
  }
  final scene = buildScene(
    LabData.load(a[0], a[1]),
    lab: a[2] == 'lab',
    mode: a[3] == 'compact' ? LayoutMode.compact : LayoutMode.free,
    stacks: a[4] == '1',
    rules: a.length > 5 ? a[5].split(',').toSet() : defaultRules(),
  );
  stdout.write(jsonEncode(scene));
}
