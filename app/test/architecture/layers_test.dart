// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the app's layers (Story 11.24): nothing under `lib/src/features/` imports `lib/src/app/` (the app's frame:
/// the boot, the window coordinator, the menu bar), and the feature folders import each other without a cycle,
/// directly or through others. A file's feature is its first folder under `lib/src/features/`. It reads every `import`
/// and `export` of `lib/src/**/*.dart`; `package:zanshin/…` and relative URIs resolve to `lib/…`.
void main() {
  group('the rule', () {
    test('reports a feature file importing the frame, by a relative or a package URI', () {
      expect(
        layerViolations(<String, List<String>>{
          'lib/src/features/home/home_page.dart': <String>[
            '../../app/menu/app_menu.dart',
            'package:flutter/widgets.dart',
          ],
          'lib/src/features/graph/view.dart': <String>['package:zanshin/src/app/boot/host.dart'],
          'lib/src/features/loose.dart': <String>['../app/menu/app_menu.dart'],
          'lib/src/app/menu/app_menu.dart': <String>['../../features/home/home_page.dart'],
        }),
        <Matcher>[
          allOf(contains('lib/src/features/graph/view.dart'), contains('lib/src/app/boot/host.dart')),
          allOf(contains('lib/src/features/home/home_page.dart'), contains('lib/src/app/menu/app_menu.dart')),
          allOf(contains('lib/src/features/loose.dart'), contains('lib/src/app/menu/app_menu.dart')),
        ],
      );
    });

    test('reports two feature folders importing each other once, naming both and a file per edge', () {
      final List<String> found = layerViolations(<String, List<String>>{
        'lib/src/features/a/a.dart': <String>['../b/b.dart'],
        'lib/src/features/b/b.dart': <String>['package:zanshin/src/features/a/a.dart'],
        'lib/src/features/b/c.dart': <String>['../a/a.dart'],
      });
      expect(found, hasLength(1));
      expect(found.single, contains('a → b (lib/src/features/a/a.dart)'));
      expect(found.single, contains('b → a (lib/src/features/b/b.dart)'));
    });

    test('reports a longer cycle through other folders; chains and imports within a folder pass', () {
      expect(
        layerViolations(<String, List<String>>{
          'lib/src/features/a/a.dart': <String>['../b/b.dart'],
          'lib/src/features/b/b.dart': <String>['../c/c.dart'],
          'lib/src/features/c/c.dart': <String>['../a/a.dart', 'c2.dart'],
        }),
        <Matcher>[allOf(contains('a, b, c'), contains('c → a (lib/src/features/c/c.dart)'))],
      );
      expect(
        layerViolations(<String, List<String>>{
          'lib/src/features/a/a.dart': <String>['../b/b.dart', 'a2.dart', '../../l10n/strings.dart'],
          'lib/src/features/a/sub/a3.dart': <String>['../a.dart'],
          'lib/src/features/b/b.dart': <String>['../c/c.dart', '../../links.dart'],
          'lib/src/app/menu/menu.dart': <String>['../../features/a/a.dart'],
        }),
        isEmpty,
      );
    });
  });

  test('app/lib/src keeps its layers', () {
    final List<File> files =
        Directory('lib/src')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    expect(files, isNotEmpty, reason: 'run from app/');
    final imports = <String, List<String>>{
      for (final File file in files)
        file.path: <String>[
          for (final RegExpMatch match in _directive.allMatches(file.readAsStringSync())) match[1]!,
        ],
    };
    final Iterable<String> relative = imports.values.expand((uris) => uris).where((uri) => uri.startsWith('../'));
    expect(relative, isNotEmpty, reason: 'the scan reads the imports');
    expect(layerViolations(imports), isEmpty);
  });
}

/// An `import` or `export` directive; group 1 is its URI.
final _directive = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);

/// The layer violations among [imports] (each file under `lib/`, `lib/…`, with its import and export URIs): one per
/// feature file's import of `lib/src/app/`, and one per cycle between feature folders, naming its folders and, for
/// each import between them, the folders and the first file (by path) that makes it.
List<String> layerViolations(Map<String, List<String>> imports) {
  final violations = <String>[];
  // Feature → the features it imports → the first file that does.
  final edges = <String, Map<String, String>>{};
  for (final String file in imports.keys.toList()..sort()) {
    // A file directly in `features/` belongs to no folder, but the frame rule holds for it too.
    if (!file.startsWith('lib/src/features/')) {
      continue;
    }
    final String? from = _featureOf(file);
    for (final String uri in imports[file]!) {
      final String? target = _resolve(file, uri);
      if (target == null) {
        continue;
      }
      if (target.startsWith('lib/src/app/')) {
        violations.add("$file imports $target: a feature never imports the app's frame");
      }
      final String? to = _featureOf(target);
      if (from != null && to != null && to != from) {
        edges.putIfAbsent(from, () => <String, String>{}).putIfAbsent(to, () => file);
      }
    }
  }
  final List<String> features = edges.keys.toList()..sort();
  final reachable = <String, Set<String>>{
    for (final String feature in features) feature: _reachable(edges, feature),
  };
  // Folders that reach each other lie on one cycle.
  final inCycle = <String>{};
  for (final feature in features) {
    if (inCycle.contains(feature) || !reachable[feature]!.contains(feature)) {
      continue;
    }
    final cycle = <String>[
      for (final String other in features)
        if (reachable[feature]!.contains(other) && reachable[other]!.contains(feature)) other,
    ];
    inCycle.addAll(cycle);
    final links = <String>[
      for (final String a in cycle)
        for (final String b in cycle)
          if (edges[a]![b] case final String file) '$a → $b ($file)',
    ];
    violations.add('the features ${cycle.join(', ')} import each other: ${links.join('; ')}');
  }
  return violations;
}

/// The features reachable from [start] through [edges], [start] itself only on a way back to it.
Set<String> _reachable(Map<String, Map<String, String>> edges, String start) {
  final seen = <String>{};
  final todo = <String>[start];
  while (todo.isNotEmpty) {
    for (final String next in edges[todo.removeLast()]?.keys ?? const <String>[]) {
      if (seen.add(next)) {
        todo.add(next);
      }
    }
  }
  return seen;
}

/// The first folder of [path] under `lib/src/features/`, or null outside it.
String? _featureOf(String path) {
  const features = 'lib/src/features/';
  if (!path.startsWith(features)) {
    return null;
  }
  final List<String> rest = path.substring(features.length).split('/');
  return rest.length > 1 ? rest.first : null;
}

/// [uri] imported by [file] as a path under `lib/`, or null for another package's or the SDK's.
String? _resolve(String file, String uri) {
  const own = 'package:zanshin/';
  if (uri.startsWith(own)) {
    return 'lib/${uri.substring(own.length)}';
  }
  return Uri.parse(uri).hasScheme ? null : Uri(path: file).resolve(uri).path;
}
