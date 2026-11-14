// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const _encoder = JsonEncoder.withIndent('  ');

/// Writes [json] to [file], indented, through `<file>.tmp` and a rename; creates the folder first.
Future<void> writeJsonFile(File file, Map<String, Object?> json) async {
  final tmp = File(p.setExtension(file.path, '.json.tmp'));
  await file.parent.create(recursive: true);
  await tmp.writeAsString('${_encoder.convert(json)}\n', flush: true);
  // WHY: rename is atomic on POSIX — a crash mid-write never leaves a half-written file behind.
  await tmp.rename(file.path);
}
