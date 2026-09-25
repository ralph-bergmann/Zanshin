// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'mutate.dart' show SkippedPath;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of Story 9.4's four `jj file` READ verbs: the
// adapters (list/show/annotate/search), their models, and their decoders.
// `dart:ffi` stays inside `ffi/` — only the worker isolate calls these adapters.
//
// All four cross a FlatBuffers REQUEST buffer rather than C strings: each is a
// composite whose `revision` must be distinguishably ABSENT (null), which is what
// applies the CLI's own `@` default instead of one this layer invented.

// ── Argument guards ──────────────────────────────────────────────────────────

/// Guard [revision] and every entry of [paths] against an interior NUL.
void _rejectPathNuls(String? revision, List<String> paths) {
  rejectInteriorNul(revision, 'revision');
  rejectInteriorNuls(paths, 'paths');
}

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_file_list` with the raw `u64` handle and a `FileListRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes.
///
/// A `null` [revision] is the wire form of "the user did not supply it", which
/// applies the CLI's own `-r` default `@` — the working-copy commit the pre-verb
/// snapshot has just brought up to date (Story 9.26). [paths] entries are repo-relative
/// PREFIXES; an empty list means all paths, and an empty-STRING entry is the
/// repository root, which prefixes everything.
Uint8List zanshinFileList(int rawHandle, {String? revision, List<String> paths = const <String>[]}) {
  _rejectPathNuls(revision, paths);
  final Uint8List request = fbs.FileListRequestObjectBuilder(
    kind: fbs.RequestKind.FileList,
    revision: revision,
    paths: paths,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_file_list(rawHandle, ptr, len));
}

/// Call `zanshin_file_show` with the raw `u64` handle and a `FileShowRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes.
///
/// [paths] is required at the call site, mirroring the CLI's `required` FILESETS
/// argument, and may NOT be empty either — an empty list surfaces as
/// `jj.invalid_input`.
Uint8List zanshinFileShow(int rawHandle, {required List<String> paths, String? revision}) {
  _rejectPathNuls(revision, paths);
  final Uint8List request = fbs.FileShowRequestObjectBuilder(
    kind: fbs.RequestKind.FileShow,
    revision: revision,
    paths: paths,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_file_show(rawHandle, ptr, len));
}

/// Call `zanshin_file_annotate` with the raw `u64` handle and a
/// `FileAnnotateRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes.
///
/// [path] is a single PLAIN repo-relative path, not a prefix and not a fileset. It
/// is required on the wire too: a `FileAnnotateRequest` whose `path` field is absent
/// is refused with `jj.invalid_input`, mirroring the CLI's required positional
/// argument.
Uint8List zanshinFileAnnotate(int rawHandle, {required String path, String? revision}) {
  rejectInteriorNul(revision, 'revision');
  rejectInteriorNul(path, 'path');
  final Uint8List request = fbs.FileAnnotateRequestObjectBuilder(
    kind: fbs.RequestKind.FileAnnotate,
    revision: revision,
    path: path,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_file_annotate(rawHandle, ptr, len));
}

/// Call `zanshin_file_search` with the raw `u64` handle and a `FileSearchRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes.
///
/// [pattern] is jj's own `kind:pattern` string-pattern syntax, passed through
/// verbatim; a bare pattern defaults to kind `regex`. [nameOnly] stops a file's
/// scan at its first match.
///
/// [pattern] is required on the wire too: a `FileSearchRequest` whose `pattern`
/// field is absent is refused with `jj.invalid_input`, mirroring the CLI's
/// `required = true`. An explicitly EMPTY pattern is a value, not an absence — it is
/// the empty regex, which matches every line, exactly as `jj file search -p ""`.
Uint8List zanshinFileSearch(
  int rawHandle, {
  required String pattern,
  String? revision,
  List<String> paths = const <String>[],
  bool nameOnly = false,
}) {
  _rejectPathNuls(revision, paths);
  rejectInteriorNul(pattern, 'pattern');
  final Uint8List request = fbs.FileSearchRequestObjectBuilder(
    kind: fbs.RequestKind.FileSearch,
    revision: revision,
    pattern: pattern,
    paths: paths,
    nameOnly: nameOnly,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_file_search(rawHandle, ptr, len));
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

  /// Number of sides of the simplified merge: `1` for a resolved entry, `>= 2`
  /// for a conflict — jj's `Merge.num_sides()` is `values.length / 2 + 1`, so the
  /// smallest conflict has two sides.
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
  const FileContents({required this.files, required this.skipped, this.warnings = const []});

  /// One entry per rendered file, in jj's own tree order.
  final List<ShownFile> files;

  /// Paths that are not renderable as file content: a symlink, a Git submodule,
  /// an unreadable blob, and the two cases the CLI panics on rather than reports
  /// (`"Path '…' is absent."`, `"Path '…' is a directory."`). A skipped path does
  /// not fail the call.
  final List<SkippedPath> skipped;

  /// The call's warnings (Story 9.32), in the CLI's print order; empty when
  /// there were none.
  final List<ZanshinWarning> warnings;
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

/// The result of `fileSearch` (mirrors `zanshin_jj::FileSearch`).
final class FileSearch {
  const FileSearch({required this.matches, required this.skipped, this.warnings = const []});

  /// One entry per matching line, in jj's own tree order then line order.
  final List<SearchMatch> matches;

  /// Paths whose blob could NOT be read. Carries `AccessDenied` and nothing
  /// else — the only case `jj file search` warns about. Symlinks, Git
  /// submodules and non-file conflicts are skipped SILENTLY and never appear
  /// here, the exact opposite of [FileContents.skipped]. An unreadable blob
  /// does not fail the call; without this list "nothing matched" and "a blob
  /// was unreadable" would be indistinguishable.
  final List<SkippedPath> skipped;

  /// The call's warnings (Story 9.32), in the CLI's print order; empty when
  /// there were none.
  final List<ZanshinWarning> warnings;
}

// ── Decoder ──────────────────────────────────────────────────────────────────

/// Decode a `FileList` `Envelope` buffer into a `List<FileEntry>` that also
/// carries the call's warnings.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.fileList`.
@visibleForTesting
WarnedList<FileEntry> decodeFileListEnvelope(Uint8List bytes) => _decodeFileListEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WarnedList<FileEntry> decodeFileListEnvelopeInternal(Uint8List bytes) => _decodeFileListEnvelope(bytes);

WarnedList<FileEntry> _decodeFileListEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.FileList) {
    throw ZanshinFfiException('ffi.unknown', 'expected FileList payload, got ${env.dataType}');
  }
  final List<ZanshinWarning> warnings = decodeEnvelopeWarningsInternal(env);
  final List<fbs.FileEntry>? entries = payload.entries;
  if (entries == null) {
    return WarnedList(const [], warnings);
  }
  return WarnedList(
    List.generate(entries.length, (i) {
      final fbs.FileEntry e = entries[i];
      return FileEntry(
        path: e.path ?? '',
        fileType: _mapFileType(e.fileType),
        executable: e.executable,
        conflictSideCount: e.conflictSideCount,
      );
    }),
    warnings,
  );
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
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

/// Decode a `FileAnnotation` `Envelope` buffer into a `List<AnnotationLine>`
/// that also carries the call's warnings.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.fileAnnotate`.
@visibleForTesting
WarnedList<AnnotationLine> decodeFileAnnotationEnvelope(Uint8List bytes) => _decodeFileAnnotationEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WarnedList<AnnotationLine> decodeFileAnnotationEnvelopeInternal(Uint8List bytes) =>
    _decodeFileAnnotationEnvelope(bytes);

WarnedList<AnnotationLine> _decodeFileAnnotationEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.FileAnnotation) {
    throw ZanshinFfiException('ffi.unknown', 'expected FileAnnotation payload, got ${env.dataType}');
  }
  return WarnedList(
    payload.lines
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
        const [],
    decodeEnvelopeWarningsInternal(env),
  );
}

/// Decode a `FileSearch` `Envelope` buffer into a [FileSearch].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.fileSearch`.
@visibleForTesting
FileSearch decodeFileSearchEnvelope(Uint8List bytes) => _decodeFileSearchEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
FileSearch decodeFileSearchEnvelopeInternal(Uint8List bytes) => _decodeFileSearchEnvelope(bytes);

FileSearch _decodeFileSearchEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.FileSearch) {
    throw ZanshinFfiException('ffi.unknown', 'expected FileSearch payload, got ${env.dataType}');
  }
  return FileSearch(
    matches:
        payload.matches
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
        const [],
    skipped: payload.skipped?.map((s) => SkippedPath(path: s.path ?? '', reason: s.reason ?? '')).toList() ?? const [],
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

/// Parse [bytes] as an `Envelope` and throw [ZanshinFfiException] when it is not ok.
fbs.Envelope _okEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
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
