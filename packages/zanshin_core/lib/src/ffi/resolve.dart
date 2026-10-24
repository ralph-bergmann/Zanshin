// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of Story 9.17's `resolve`: the models
// (`ResolveTool`, `ResolvedFile`, `ResolveList`, `ConflictedFile`,
// `ConflictHunk`), the `resolveList` / `resolve` adapters and the
// `ResolveList` decoder. `resolve` answers the shared `MutationResult`,
// decoded through `mutate.dart`. `dart:ffi` stays inside `ffi/` — only the
// worker isolate calls the adapters.

// ── Models ───────────────────────────────────────────────────────────────────

/// What `resolve` resolves with (mirrors `zanshin_jj::ResolveTool`).
sealed class ResolveTool {
  const ResolveTool();
}

/// `--tool :ours`: each conflict takes side 1.
final class ResolveOurs extends ResolveTool {
  const ResolveOurs();
}

/// `--tool :theirs`: each conflict takes side 2.
final class ResolveTheirs extends ResolveTool {
  const ResolveTheirs();
}

/// The GUI merge editor's output: each file's resolved content. The files are
/// the paths — each a conflict at the revision, each listed once.
final class ResolveFiles extends ResolveTool {
  const ResolveFiles(this.files);

  /// The resolved files.
  final List<ResolvedFile> files;
}

/// One file the GUI merge editor resolved (mirrors `zanshin_jj::ResolvedFile`).
final class ResolvedFile {
  const ResolvedFile({required this.path, required this.content});

  /// The repo-relative path, in jj's internal `/`-separated form (what
  /// [ConflictedFile.path] reports).
  final String path;

  /// The resolved content, written as is.
  final Uint8List content;
}

/// One merge hunk of a file conflict (mirrors `zanshin_jj::ConflictHunk`).
final class ConflictHunk {
  const ConflictHunk({required this.terms});

  /// The hunk's terms in jj's `Merge` order — side 1, base 1, side 2, … — for
  /// a conflicting hunk; one term, the text every side shares, for a resolved
  /// one.
  final List<Uint8List> terms;
}

/// One conflicted path of `resolveList` (mirrors `zanshin_jj::ConflictedFile`).
final class ConflictedFile {
  const ConflictedFile({
    required this.path,
    required this.description,
    required this.numSides,
    required this.unresolvable,
    required this.labels,
    required this.hunks,
  });

  /// The repo-relative path, in jj's internal `/`-separated form.
  final String path;

  /// The CLI's `--list` description of the simplified conflict, e.g.
  /// `2-sided conflict`.
  final String description;

  /// The simplified conflict's number of sides.
  final int numSides;

  /// Why `resolve` would refuse this conflict (`jj.conflict_not_resolvable`'s
  /// text); `null` = it can take it.
  final String? unresolvable;

  /// A file conflict's simplified labels, one per term; empty = unlabeled, and
  /// for a conflict that is not a file conflict.
  final List<String> labels;

  /// A file conflict's merge hunks; empty for any other conflict.
  final List<ConflictHunk> hunks;
}

/// `resolveList`'s answer (mirrors `zanshin_jj::ResolveList`).
final class ResolveList {
  const ResolveList({required this.files, this.warnings = const []});

  /// The matched conflicts, in tree order.
  final List<ConflictedFile> files;

  /// The call's warnings (`jj.paths_unmatched`, the snapshot's); empty when
  /// there were none.
  final List<ZanshinWarning> warnings;
}

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_resolve_list` with the raw `u64` handle and a
/// `ResolveListRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes (Story 9.17) — the CLI's `jj resolve --list`.
///
/// [revision] is `-r` (`null`: `@`), [paths] repo-relative prefixes (empty:
/// every conflict).
Uint8List zanshinResolveList(int rawHandle, {String? revision, List<String> paths = const []}) {
  rejectInteriorNul(revision, 'revision');
  rejectInteriorNuls(paths, 'paths');
  final Uint8List request = fbs.ResolveListRequestObjectBuilder(
    kind: fbs.RequestKind.ResolveList,
    revision: revision,
    paths: paths,
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_resolve_list(rawHandle, ptr, len));
}

/// Reject an interior NUL in [revision], a path of [paths] or of [tool]'s
/// files.
void rejectResolveNuls(String? revision, List<String> paths, ResolveTool tool) {
  rejectInteriorNul(revision, 'revision');
  rejectInteriorNuls(paths, 'paths');
  if (tool case ResolveFiles(:final files)) {
    rejectInteriorNuls([for (final ResolvedFile file in files) file.path], 'files');
  }
}

/// Call `zanshin_resolve` with the raw `u64` handle and a `ResolveRequest`
/// request buffer, and return the FlatBuffers `Envelope` bytes (Story 9.17) —
/// the CLI's `jj resolve`.
///
/// [revision] is `-r` (`null`: `@`), [paths] repo-relative prefixes (empty:
/// every conflict; not with [ResolveFiles]), [tool] what resolves them.
Uint8List zanshinResolve(int rawHandle, {required ResolveTool tool, String? revision, List<String> paths = const []}) {
  rejectResolveNuls(revision, paths, tool);
  final Uint8List request = fbs.ResolveRequestObjectBuilder(
    kind: fbs.RequestKind.Resolve,
    revision: revision,
    paths: paths,
    tool: switch (tool) {
      ResolveOurs() => fbs.ResolveTool.Ours,
      ResolveTheirs() => fbs.ResolveTool.Theirs,
      ResolveFiles() => fbs.ResolveTool.Files,
    },
    files: [
      if (tool case ResolveFiles(:final files))
        for (final ResolvedFile file in files) fbs.ResolvedFileObjectBuilder(path: file.path, content: file.content),
    ],
  ).toBytes();
  return callWithRequest(request, (ptr, len) => zanshin_resolve(rawHandle, ptr, len));
}

// ── Decoder ──────────────────────────────────────────────────────────────────

/// Decode a `ResolveList` `Envelope` buffer into a [ResolveList].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.resolveList`.
@visibleForTesting
ResolveList decodeResolveListEnvelope(Uint8List bytes) => decodeResolveListEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
ResolveList decodeResolveListEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.ResolveList) {
    throw ZanshinFfiException('ffi.unknown', 'expected ResolveList payload, got ${env.dataType}');
  }
  return ResolveList(
    files: [
      for (final fbs.ConflictedFile file in payload.files ?? const <fbs.ConflictedFile>[])
        ConflictedFile(
          path: file.path ?? '',
          description: file.description ?? '',
          numSides: file.numSides,
          unresolvable: file.unresolvable,
          labels: file.labels ?? const [],
          hunks: [
            for (final fbs.ConflictHunk hunk in file.hunks ?? const <fbs.ConflictHunk>[])
              ConflictHunk(
                terms: [
                  for (final fbs.ConflictTerm term in hunk.terms ?? const <fbs.ConflictTerm>[])
                    Uint8List.fromList(term.content ?? const []),
                ],
              ),
          ],
        ),
    ],
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}
