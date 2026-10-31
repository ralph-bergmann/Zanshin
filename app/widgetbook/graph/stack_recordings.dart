// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'package:zanshin/src/features/graph/graph_ports.dart';

import 'graph_stack_recordings.g.dart';

/// One run of a stack recording: its members' keys (oldest first) and its state there.
typedef _Run = ({List<String> members, bool expanded});

final _runs = <String, List<_Run>>{};

/// The runs of the stack recording [name], in run order, parsed once.
List<_Run> _runsOf(String name) => _runs.putIfAbsent(name, () {
  final (String input, String output, _) = graphStackRecordings[name]!;
  final nodes = (jsonDecode(input) as Map<String, Object?>)['nodes']! as List<Object?>;
  String keyOf(int i) {
    final node = nodes[i]! as Map<String, Object?>;
    return (node['key'] ?? node['id'])! as String;
  }

  final runs = (jsonDecode(output) as Map<String, Object?>)['runs']! as List<Object?>;
  return <_Run>[
    for (final Map<String, Object?> run in runs.cast<Map<String, Object?>>())
      (
        members: <String>[for (final Object? m in run['members']! as List<Object?>) keyOf(m! as int)],
        expanded: run['state'] == 'expanded',
      ),
  ];
});

/// The stack recording of [sample] (`design-default` or `design-all`) in [request]'s mode whose run states match what
/// the engine computes for [request] (docs/graph-layout.md §4.8 step 3): a run with a key in `keepOpenKeys` is
/// expanded; else its oldest member's key in `expandedKeys` expands it and in `collapsedKeys` collapses it; else it
/// keeps the default recording's state. Without an exact match, the recording with the fewest mismatching runs. Null
/// when [request] groups no stacks or [sample] has no stack recordings: the ungrouped recording answers.
// shortcut: recorded states only (the default, all expanded, each run flipped alone), lane order compact whatever
// the request asks; deeper combinations take the nearest state until 10.12 brings the engine.
String? stackRecordingFor(String sample, GraphRequest request) {
  final String? defaults = graphStackDefaults['$sample ${request.mode.name}'];
  if (!request.stacks || defaults == null) {
    return null;
  }
  final wanted = <bool>[
    for (final _Run run in _runsOf(defaults))
      run.members.any(request.keepOpenKeys.contains) ||
          request.expandedKeys.contains(run.members.first) ||
          (!request.collapsedKeys.contains(run.members.first) && run.expanded),
  ];
  final prefix = '$sample ${request.mode.name} ';
  String? best;
  int fewest = wanted.length + 1;
  for (final String name in graphStackRecordings.keys) {
    if (!name.startsWith(prefix)) {
      continue;
    }
    final List<_Run> runs = _runsOf(name);
    var mismatches = 0;
    for (var r = 0; r < runs.length; r++) {
      if (runs[r].expanded != wanted[r]) {
        mismatches++;
      }
    }
    if (mismatches < fewest) {
      fewest = mismatches;
      best = name;
    }
  }
  return best;
}
