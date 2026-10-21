// SPDX-License-Identifier: MIT

// Decode-contract tests for [decodeGitFetchResultEnvelope] (Story 9.30) using
// synthetic FlatBuffers buffers built via the generated `*ObjectBuilder`s. No
// real cdylib required. A real fetch spawns git, which the Dart VM's child
// reaping races (see test/worker/mutate_test.dart's `gitFetch` note), so the
// success path is witnessed in Rust and through the FFI tests instead.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/fetch.dart';
import 'package:zanshin_core/src/ffi/git.dart' show GitRefUpdate;
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('decodeGitFetchResultEnvelope decode contract (Story 9.30)', () {
    Uint8List fetchResult({
      fbs.MutationResultObjectBuilder? mutation,
      List<String>? remotes = const ['origin', 'up'],
      List<String>? hints = const [],
      List<String>? failedRefNames = const [],
      List<fbs.GitRefUpdateObjectBuilder>? changedBookmarks = const [],
      List<fbs.GitRefUpdateObjectBuilder>? changedTags = const [],
      int? numRewritten,
      List<fbs.WarningObjectBuilder>? warnings,
    }) => fbs.EnvelopeObjectBuilder(
      ok: true,
      dataType: fbs.PayloadTypeId.GitFetchResult,
      data: fbs.GitFetchResultObjectBuilder(
        mutation: mutation ?? fbs.MutationResultObjectBuilder(newOpId: 'op', workingCopyChangeId: 'wc'),
        remotes: remotes,
        hints: hints,
        failedRefNames: failedRefNames,
        changedBookmarks: changedBookmarks,
        changedTags: changedTags,
        numRewritten: numRewritten,
      ),
      warnings: warnings,
    ).toBytes();

    test('decodes every field and the envelope warnings', () {
      final GitFetchResult result = decodeGitFetchResultEnvelope(
        fetchResult(
          mutation: fbs.MutationResultObjectBuilder(
            newOpId: 'op',
            newChangeIds: const [],
            abandonedChangeIds: const ['zz'],
            workingCopyChangeId: 'wc',
          ),
          remotes: const ['up'],
          hints: const ['Fetching from the only existing remote: up'],
          failedRefNames: const ['refs/remotes/git/x'],
          changedBookmarks: [
            fbs.GitRefUpdateObjectBuilder(
              name: 'main',
              remote: 'up',
              kind: fbs.GitRefUpdateKind.Updated,
              tracked: true,
            ),
          ],
          changedTags: [fbs.GitRefUpdateObjectBuilder(name: 'v1', remote: 'up', kind: fbs.GitRefUpdateKind.New)],
          numRewritten: 3,
          warnings: [
            fbs.WarningObjectBuilder(code: ZanshinWarningCode.gitImportFailed, message: 'Failed to import'),
          ],
        ),
      );
      expect(result.mutation.newOpId, 'op');
      expect(result.mutation.abandonedChangeIds, ['zz']);
      expect(result.mutation.workingCopyChangeId, 'wc');
      expect(result.mutation.warnings, isEmpty, reason: 'the nested result carries none of its own');
      expect(result.remotes, ['up']);
      expect(result.hints, ['Fetching from the only existing remote: up']);
      expect(result.failedRefNames, ['refs/remotes/git/x']);
      String describe(GitRefUpdate u) => '${u.name}@${u.remote} ${u.kind.name} tracked=${u.tracked}';
      expect(result.changedBookmarks.map(describe), ['main@up updated tracked=true']);
      expect(result.changedTags.map(describe), ['v1@up created tracked=false']);
      expect(result.numRewritten, 3);
      expect(result.warnings.map((w) => w.code), [ZanshinWarningCode.gitImportFailed]);
    });

    test('an absent vector or mutation is refused, not defaulted', () {
      Matcher unknown(String field) => throwsA(
        isA<ZanshinFfiException>()
            .having((e) => e.code, 'code', 'ffi.unknown')
            .having((e) => e.context, 'context', contains(field)),
      );
      expect(() => decodeGitFetchResultEnvelope(fetchResult(remotes: null)), unknown('remotes'));
      expect(() => decodeGitFetchResultEnvelope(fetchResult(hints: null)), unknown('hints'));
      expect(() => decodeGitFetchResultEnvelope(fetchResult(failedRefNames: null)), unknown('failed_ref_names'));
      expect(() => decodeGitFetchResultEnvelope(fetchResult(changedBookmarks: null)), unknown('changed_bookmarks'));
      expect(() => decodeGitFetchResultEnvelope(fetchResult(changedTags: null)), unknown('changed_tags'));
      final Uint8List noMutation = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.GitFetchResult,
        data: fbs.GitFetchResultObjectBuilder(
          remotes: const [],
          hints: const [],
          failedRefNames: const [],
          changedBookmarks: const [],
          changedTags: const [],
        ),
      ).toBytes();
      expect(() => decodeGitFetchResultEnvelope(noMutation), unknown('mutation'));
    });

    // Story 9.56: a reserved remote name's refusal keeps jj-lib's text as context and carries
    // the CLI's rename hint as `hints`.
    test("a reserved remote's refusal carries the rename hint", () {
      final Uint8List error = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(
          code: 'jj.invalid_input',
          context: "Git remote named 'git' is reserved for local Git repository",
          hints: ['Run `jj git remote rename` to give a different name.'],
        ),
      ).toBytes();
      expect(
        () => decodeGitFetchResultEnvelope(error),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.context, 'context', "Git remote named 'git' is reserved for local Git repository")
              .having((e) => e.hints, 'hints', ['Run `jj git remote rename` to give a different name.']),
        ),
      );
    });

    test('throws the error envelope with its warnings, and ffi.unknown on a wrong payload', () {
      final Uint8List error = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'jj.invalid_input', context: 'No git remotes to fetch from'),
        warnings: [
          fbs.WarningObjectBuilder(
            code: ZanshinWarningCode.fetchRemotesUnmatched,
            message: 'No matching remotes for names: origin',
          ),
        ],
      ).toBytes();
      expect(
        () => decodeGitFetchResultEnvelope(error),
        throwsA(
          isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input').having(
            (e) => e.warnings.map((w) => w.code),
            'warnings',
            [ZanshinWarningCode.fetchRemotesUnmatched],
          ),
        ),
      );
      final Uint8List wrong = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.MutationResult,
        data: fbs.MutationResultObjectBuilder(newOpId: 'op'),
      ).toBytes();
      expect(
        () => decodeGitFetchResultEnvelope(wrong),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });
  });

  group('zanshinGitFetch request encoding (Story 9.30)', () {
    // A request Rust verifies and routes reaches the handle check: with handle 0
    // every argument shape answers `ffi.invalid_handle`, never
    // `ffi.invalid_argument` (a mis-built or mis-tagged buffer).
    test('every argument shape builds a request the real cdylib accepts', () {
      for (final (FetchRemotes remotes, FetchRefs refs) in [
        (const DefaultFetchRemotes(), const DefaultFetchRefs()),
        (const NamedFetchRemotes(['origin', 'up*']), const PatternFetchRefs(branches: ['feat*'], tags: ['v1'])),
        (const AllFetchRemotes(), const TrackedFetchRefs()),
      ]) {
        expect(
          () => decodeGitFetchResultEnvelope(zanshinGitFetch(0, remotes: remotes, refs: refs)),
          throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
        );
      }
    });
  });

  group('gitFetchRequestBytes (Story 9.30)', () {
    // Each sealed variant lands in its mode with its own lists; a list the mode
    // does not read stays absent.
    test('every variant carries its mode, lists, kind and cancel token', () {
      fbs.GitFetchRequest decode(FetchRemotes remotes, FetchRefs refs) =>
          fbs.GitFetchRequest(gitFetchRequestBytes(remotes: remotes, refs: refs, cancelToken: 42));

      final fbs.GitFetchRequest defaults = decode(const DefaultFetchRemotes(), const DefaultFetchRefs());
      expect(defaults.kind, fbs.RequestKind.GitFetch);
      expect(defaults.cancelToken, 42);
      expect(defaults.remotesMode, fbs.FetchRemotesMode.Default);
      expect(defaults.refsMode, fbs.FetchRefsMode.Default);
      expect([defaults.remotes, defaults.branches, defaults.tags], [null, null, null]);

      final fbs.GitFetchRequest named = decode(
        const NamedFetchRemotes(['origin', 'up*']),
        const PatternFetchRefs(branches: ['feat*'], tags: ['v1', 'v2']),
      );
      expect(named.kind, fbs.RequestKind.GitFetch);
      expect(named.cancelToken, 42);
      expect(named.remotesMode, fbs.FetchRemotesMode.Named);
      expect(named.remotes, ['origin', 'up*']);
      expect(named.refsMode, fbs.FetchRefsMode.Patterns);
      expect(named.branches, ['feat*']);
      expect(named.tags, ['v1', 'v2']);

      final fbs.GitFetchRequest all = decode(const AllFetchRemotes(), const TrackedFetchRefs());
      expect(all.kind, fbs.RequestKind.GitFetch);
      expect(all.cancelToken, 42);
      expect(all.remotesMode, fbs.FetchRemotesMode.All);
      expect(all.refsMode, fbs.FetchRefsMode.Tracked);
      expect([all.remotes, all.branches, all.tags], [null, null, null]);

      final fbs.GitFetchRequest emptyPatterns = decode(const DefaultFetchRemotes(), const PatternFetchRefs());
      expect(emptyPatterns.refsMode, fbs.FetchRefsMode.Patterns);
      expect([emptyPatterns.branches, emptyPatterns.tags], [isEmpty, isEmpty]);
    });
  });
}
