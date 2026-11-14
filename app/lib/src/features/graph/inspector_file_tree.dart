// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:zanshin_core/zanshin_core.dart' show FileChange;

/// One visible row of the inspector's file list (Story 10.39): a file or, in the tree, a folder.
@immutable
sealed class InspectorListRow {
  const InspectorListRow({required this.depth});

  /// The folders above it in the tree; 0 in the flat list.
  final int depth;

  /// The repo path it stands for: the file's, or the folder's.
  String get path;
}

/// A file's row.
final class InspectorFileListRow extends InspectorListRow {
  /// The row of [file] at [depth].
  const InspectorFileListRow(this.file, {super.depth = 0});

  /// The file.
  final FileChange file;

  @override
  String get path => file.path;
}

/// A folder's row in the tree: [name] is its own segment, or the joined chain of folders that hold only one folder
/// each (`packages/logic_designer/lib/src`); [path] is the deepest one's.
final class InspectorFolderListRow extends InspectorListRow {
  /// The row of the folder at [path].
  const InspectorFolderListRow({
    required this.path,
    required this.name,
    required this.files,
    required this.open,
    required super.depth,
  });

  @override
  final String path;

  /// What the row shows.
  final String name;

  /// Every file below it, at any depth.
  final List<FileChange> files;

  /// Whether its children show.
  final bool open;
}

/// [files] as the flat list shows them: jj's order.
List<InspectorListRow> inspectorFlatRows(List<FileChange> files) => <InspectorListRow>[
  for (final FileChange file in files) InspectorFileListRow(file),
];

/// [files] as the tree shows them: at each level the folders sorted by name, then the files by name; a folder whose
/// only child is one folder joins with it; the rows below a folder in [collapsed] (by path) are left out.
List<InspectorListRow> inspectorTreeRows(List<FileChange> files, Set<String> collapsed) {
  final root = _Folder('', '');
  for (final file in files) {
    final List<String> segments = file.path.split('/');
    var node = root;
    for (var i = 0; i < segments.length - 1; i++) {
      final String path = segments.sublist(0, i + 1).join('/');
      node = node.folders.putIfAbsent(segments[i], () => _Folder(segments[i], path));
    }
    node.files.add(file);
  }
  final rows = <InspectorListRow>[];
  void walk(_Folder folder, int depth) {
    final List<_Folder> folders = folder.folders.values.map(_joined).toList()..sort((a, b) => _byName(a.name, b.name));
    for (final child in folders) {
      final bool open = !collapsed.contains(child.path);
      rows.add(
        InspectorFolderListRow(
          path: child.path,
          name: child.name,
          files: child.allFiles,
          open: open,
          depth: depth,
        ),
      );
      if (open) {
        walk(child, depth + 1);
      }
    }
    final own = <FileChange>[...folder.files]..sort((a, b) => _byName(_nameOf(a.path), _nameOf(b.path)));
    rows.addAll(<InspectorListRow>[for (final FileChange file in own) InspectorFileListRow(file, depth: depth)]);
  }

  walk(root, 0);
  return rows;
}

String _nameOf(String path) => path.substring(path.lastIndexOf('/') + 1);

/// By name, ignoring case first, as Finder sorts.
int _byName(String a, String b) {
  final int folded = a.toLowerCase().compareTo(b.toLowerCase());
  return folded != 0 ? folded : a.compareTo(b);
}

/// [folder] with its chain of single-folder children joined into one.
_Folder _joined(_Folder folder) {
  var joined = folder;
  while (joined.files.isEmpty && joined.folders.length == 1) {
    final _Folder child = joined.folders.values.single;
    joined = _Folder('${joined.name}/${child.name}', child.path)
      ..folders.addAll(child.folders)
      ..files.addAll(child.files);
  }
  return joined;
}

class _Folder {
  _Folder(this.name, this.path);

  final String name;
  final String path;
  final folders = <String, _Folder>{};
  final files = <FileChange>[];

  List<FileChange> get allFiles => <FileChange>[
    ...files,
    for (final _Folder child in folders.values) ...child.allFiles,
  ];
}
