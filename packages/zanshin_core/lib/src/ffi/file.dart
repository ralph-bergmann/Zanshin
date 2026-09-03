// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'ffi_buffer.dart';
import 'mutate.dart' show SkippedPath;

// This file owns the Dart half of Story 9.4's four `jj file` READ verbs: the
// adapters (list/show/annotate/search), their models, and their decoders.
// `dart:ffi` stays inside `ffi/` — only the worker isolate calls these adapters.
//
// All four cross a FlatBuffers REQUEST buffer rather than C strings: each is a
// composite whose `revision` must be distinguishably ABSENT (null), which is what
// applies the CLI's own `@` default instead of one this layer invented.

// ── Request-buffer helpers ───────────────────────────────────────────────────

/// Copy [bytes] into a `malloc`-allocated `Pointer<Uint8>`, invoke [fn] with the
/// pointer and byte length, and free the pointer afterward.
///
/// Same ownership discipline as `mutate.dart`'s identical helper (AR-P-5 inbound
/// rule): Rust only borrows the buffer for the duration of the call.
T _withRequestBytes<T>(Uint8List bytes, T Function(ffi.Pointer<ffi.Uint8>, int) fn) {
  final ffi.Pointer<ffi.Uint8> ptr = malloc.allocate<ffi.Uint8>(bytes.length);
  ptr.asTypedList(bytes.length).setAll(0, bytes);
  try {
    return fn(ptr, bytes.length);
  } finally {
    malloc.free(ptr);
  }
}

/// Reject an interior NUL in a caller-supplied string.
///
/// A FlatBuffers string is length-prefixed, so a NUL would survive the wire — and
/// then land in a jj change id, path or search pattern, where it can only produce a
/// confusing downstream failure.
void _rejectInteriorNul(String? value, String name) {
  if (value != null && value.codeUnits.contains(0)) {
    throw ArgumentError.value(value, name, 'must not contain an interior NUL (U+0000)');
  }
}

/// Guard [revision] and every entry of [paths] against an interior NUL.
void _rejectPathNuls(String? revision, List<String> paths) {
  _rejectInteriorNul(revision, 'revision');
  for (final path in paths) {
    _rejectInteriorNul(path, 'paths');
  }
}

/// Invoke [call] with the request bytes and copy the returned envelope out of the
/// token before freeing it.
Uint8List _callWithRequest(
  Uint8List request,
  ffi.Pointer<ZanshinBuf> Function(ffi.Pointer<ffi.Uint8>, int) call,
) => _withRequestBytes(request, (ptr, len) {
  final ffi.Pointer<ZanshinBuf> token = call(ptr, len);
  final buf = FfiBuffer.fromToken(token);
  try {
    return Uint8List.fromList(buf.bytes);
  } finally {
    buf.dispose();
  }
});

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_file_list` with the raw `u64` handle and a `FileListRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes.
///
/// A `null` [revision] is the wire form of "the user did not supply it", which
/// applies the CLI's own `-r` default `@` — the LAST-SNAPSHOTTED working-copy
/// commit, since Zanshin never snapshots. [paths] entries are repo-relative
/// PREFIXES; an empty list means all paths, and an empty-STRING entry is the
/// repository root, which prefixes everything.
Uint8List zanshinFileList(int rawHandle, {String? revision, List<String> paths = const <String>[]}) {
  _rejectPathNuls(revision, paths);
  final Uint8List request = fbs.FileListRequestObjectBuilder(revision: revision, paths: paths).toBytes();
  return _callWithRequest(request, (ptr, len) => zanshin_file_list(rawHandle, ptr, len));
}

/// Call `zanshin_file_show` with the raw `u64` handle and a `FileShowRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes.
///
/// [paths] may NOT be empty — the CLI marks its FILESETS argument `required`, and
/// an empty list surfaces as `jj.invalid_input`.
Uint8List zanshinFileShow(int rawHandle, {String? revision, List<String> paths = const <String>[]}) {
  _rejectPathNuls(revision, paths);
  final Uint8List request = fbs.FileShowRequestObjectBuilder(revision: revision, paths: paths).toBytes();
  return _callWithRequest(request, (ptr, len) => zanshin_file_show(rawHandle, ptr, len));
}

/// Call `zanshin_file_annotate` with the raw `u64` handle and a
/// `FileAnnotateRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes.
///
/// [path] is a single PLAIN repo-relative path, not a prefix and not a fileset.
Uint8List zanshinFileAnnotate(int rawHandle, {required String path, String? revision}) {
  _rejectInteriorNul(revision, 'revision');
  _rejectInteriorNul(path, 'path');
  final Uint8List request = fbs.FileAnnotateRequestObjectBuilder(revision: revision, path: path).toBytes();
  return _callWithRequest(request, (ptr, len) => zanshin_file_annotate(rawHandle, ptr, len));
}

/// Call `zanshin_file_search` with the raw `u64` handle and a `FileSearchRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes.
///
/// [pattern] is jj's own `kind:pattern` string-pattern syntax, passed through
/// verbatim; a bare pattern defaults to kind `regex`. [nameOnly] stops a file's
/// scan at its first match.
Uint8List zanshinFileSearch(
  int rawHandle, {
  required String pattern,
  String? revision,
  List<String> paths = const <String>[],
  bool nameOnly = false,
}) {
  _rejectPathNuls(revision, paths);
  _rejectInteriorNul(pattern, 'pattern');
  final Uint8List request = fbs.FileSearchRequestObjectBuilder(
    revision: revision,
    pattern: pattern,
    paths: paths,
    nameOnly: nameOnly,
  ).toBytes();
  return _callWithRequest(request, (ptr, len) => zanshin_file_search(rawHandle, ptr, len));
}

// ── Dart models ──────────────────────────────────────────────────────────────

/// What a tree entry IS (mirrors `zanshin_jj::FileType`).
enum FileType {
  /// A regular file.
  file,

  /// A symbolic link.
  symlink,

  /// A directory. Unreachable through [zanshinFileList] — jj recurses into
  /// subtrees rather than yielding them — but modelled so the mapping is total.
  tree,

  /// A Git submodule.
  gitSubmodule,

  /// An unresolved conflict. A subtree that conflicts with a non-tree arrives as
  /// ONE such entry and is not descended into — render it as an opaque conflict,
  /// not an empty directory.
  conflict,
}

/// One entry of a revision's tree (mirrors `zanshin_jj::FileEntry`).
final class FileEntry {
  const FileEntry({
    required this.path,
    required this.fileType,
    required this.executable,
    required this.conflictSideCount,
  });

  /// Repo-relative path in jj's internal (`/`-separated) form.
  final String path;

  /// What the entry is.
  final FileType fileType;

  /// The executable bit; `false` for a symlink, a submodule, and a conflict whose
  /// sides disagree about it.
  final bool executable;

  /// Number of sides of the simplified merge: `1` for a resolved entry, `>= 3`
  /// for a conflict.
  final int conflictSideCount;
}

/// One file's content as `jj file show` would print it (mirrors
/// `zanshin_jj::ShownFile`).
final class ShownFile {
  const ShownFile({required this.path, required this.content, required this.conflict});

  /// Repo-relative path in jj's internal (`/`-separated) form.
  final String path;

  /// The file's raw bytes. NOT guaranteed UTF-8 — a tracked file may be binary.
  /// For a conflicted path this is the materialized merge, with markers in the
  /// style the repo's effective `ui.conflict-marker-style` selects.
  final Uint8List content;

  /// Whether [content] is a materialized conflict rather than a resolved file.
  final bool conflict;
}

/// The result of `fileShow` (mirrors `zanshin_jj::FileContents`).
final class FileContents {
  const FileContents({required this.files, required this.skipped});

  /// One entry per rendered file, in jj's own tree order.
  final List<ShownFile> files;

  /// Paths that exist but are not renderable as file content (a symlink, a Git
  /// submodule, an unreadable blob). A skipped path does not fail the call.
  final List<SkippedPath> skipped;
}

/// One annotated line of a file (mirrors `zanshin_jj::AnnotationLine`).
final class AnnotationLine {
  const AnnotationLine({
    required this.commitId,
    required this.changeId,
    required this.originalLineNumber,
    required this.content,
    required this.originFound,
  });

  /// Hex commit id of the commit the line originates from.
  final String commitId;

  /// That commit's change id, reverse-hex.
  final String changeId;

  /// 1-BASED line number the line had in [commitId]'s version of the file.
  final int originalLineNumber;

  /// The raw line, newline included when the source line had one.
  final Uint8List content;

  /// `false` when the search stopped at the domain boundary and [commitId] is
  /// only where it stopped. There is deliberately no `lineNumber` field: a line's
  /// own number is its 1-based index in the returned list.
  final bool originFound;
}

/// One matching line of `fileSearch` (mirrors `zanshin_jj::SearchMatch`).
final class SearchMatch {
  const SearchMatch({
    required this.path,
    required this.lineNumber,
    required this.content,
    required this.conflictSide,
  });

  /// Repo-relative path in jj's internal (`/`-separated) form.
  final String path;

  /// 1-based line number within the searched content. For a conflicted path the
  /// count restarts at each side.
  final int lineNumber;

  /// The raw matching line, newline included when the source line had one.
  final Uint8List content;

  /// 0-based index of the conflict side this line came from, or `null` for a
  /// resolved file — null-for-absence.
  final int? conflictSide;
}

// ── Decoder ──────────────────────────────────────────────────────────────────

/// Decode a `FileList` `Envelope` buffer into a `List<FileEntry>`.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.fileList`.
@visibleForTesting
List<FileEntry> decodeFileListEnvelope(Uint8List bytes) => _decodeFileListEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
List<FileEntry> decodeFileListEnvelopeInternal(Uint8List bytes) => _decodeFileListEnvelope(bytes);

List<FileEntry> _decodeFileListEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.FileList) {
    throw ZanshinFfiException('ffi.unknown', 'expected FileList payload, got ${env.dataType}');
  }
  final List<fbs.FileEntry>? entries = payload.entries;
  if (entries == null) {
    return const [];
  }
  return List.generate(entries.length, (i) {
    final fbs.FileEntry e = entries[i];
    return FileEntry(
      path: e.path ?? '',
      fileType: _mapFileType(e.fileType),
      executable: e.executable,
      conflictSideCount: e.conflictSideCount,
    );
  });
}

/// Decode a `FileContents` `Envelope` buffer into a [FileContents].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.fileShow`.
@visibleForTesting
FileContents decodeFileContentsEnvelope(Uint8List bytes) => _decodeFileContentsEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
FileContents decodeFileContentsEnvelopeInternal(Uint8List bytes) => _decodeFileContentsEnvelope(bytes);

FileContents _decodeFileContentsEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.FileContents) {
    throw ZanshinFfiException('ffi.unknown', 'expected FileContents payload, got ${env.dataType}');
  }
  return FileContents(
    files:
        payload.files
            ?.map((f) => ShownFile(path: f.path ?? '', content: _bytes(f.content), conflict: f.conflict))
            .toList() ??
        const [],
    skipped: payload.skipped?.map((s) => SkippedPath(path: s.path ?? '', reason: s.reason ?? '')).toList() ?? const [],
  );
}

/// Decode a `FileAnnotation` `Envelope` buffer into a `List<AnnotationLine>`.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.fileAnnotate`.
@visibleForTesting
List<AnnotationLine> decodeFileAnnotationEnvelope(Uint8List bytes) => _decodeFileAnnotationEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
List<AnnotationLine> decodeFileAnnotationEnvelopeInternal(Uint8List bytes) => _decodeFileAnnotationEnvelope(bytes);

List<AnnotationLine> _decodeFileAnnotationEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.FileAnnotation) {
    throw ZanshinFfiException('ffi.unknown', 'expected FileAnnotation payload, got ${env.dataType}');
  }
  return payload.lines
          ?.map(
            (l) => AnnotationLine(
              commitId: l.commitId ?? '',
              changeId: l.changeId ?? '',
              originalLineNumber: l.originalLineNumber,
              content: _bytes(l.content),
              originFound: l.originFound,
            ),
          )
          .toList() ??
      const [];
}

/// Decode a `FileSearch` `Envelope` buffer into a `List<SearchMatch>`.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.fileSearch`.
@visibleForTesting
List<SearchMatch> decodeFileSearchEnvelope(Uint8List bytes) => _decodeFileSearchEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
List<SearchMatch> decodeFileSearchEnvelopeInternal(Uint8List bytes) => _decodeFileSearchEnvelope(bytes);

List<SearchMatch> _decodeFileSearchEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.FileSearch) {
    throw ZanshinFfiException('ffi.unknown', 'expected FileSearch payload, got ${env.dataType}');
  }
  return payload.matches
          ?.map(
            (m) => SearchMatch(
              path: m.path ?? '',
              lineNumber: m.lineNumber,
              content: _bytes(m.content),
              // Presence pair, not a sentinel: `conflictSide` is meaningful only
              // when `hasConflictSide` is set, so absence stays null.
              conflictSide: m.hasConflictSide ? m.conflictSide : null,
            ),
          )
          .toList() ??
      const [];
}

/// Parse [bytes] as an `Envelope` and throw [ZanshinFfiException] when it is not ok.
fbs.Envelope _okEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    final fbs.FfiError? e = env.error;
    throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
  }
  return env;
}

/// Copy a generated `[ubyte]` accessor's view into an owned [Uint8List]; an absent
/// vector is an empty file, not a crash.
Uint8List _bytes(List<int>? raw) => raw == null ? Uint8List(0) : Uint8List.fromList(raw);

FileType _mapFileType(fbs.FileType kind) => switch (kind) {
  fbs.FileType.File => FileType.file,
  fbs.FileType.Symlink => FileType.symlink,
  fbs.FileType.Tree => FileType.tree,
  fbs.FileType.GitSubmodule => FileType.gitSubmodule,
  fbs.FileType.Conflict => FileType.conflict,
};
