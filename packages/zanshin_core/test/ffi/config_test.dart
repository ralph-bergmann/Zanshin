// SPDX-License-Identifier: MIT

// Wire-shape, decoder and guard tests for Story 9.28's config-surface adapters,
// using synthetic FlatBuffers buffers built via the generated `*ObjectBuilder`s.
// No real cdylib required — these pin every payload decoder (null for absence
// included), the precondition on `ConfigSetResult`, error envelopes and the
// adapters' NUL backstop, mirroring crates/zanshin-ffi/src/config.rs.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/config.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/worker/responses.dart';

Uint8List ok(fbs.PayloadTypeId type, Object? data, {fbs.PreconditionObjectBuilder? precondition}) =>
    fbs.EnvelopeObjectBuilder(ok: true, dataType: type, data: data, precondition: precondition).toBytes();

void main() {
  test('ConfigScope maps onto the wire enum', () {
    expect(ConfigScope.values.map((s) => s.wire), [
      fbs.ConfigScope.User,
      fbs.ConfigScope.Repo,
      fbs.ConfigScope.Workspace,
    ]);
  });

  test('list decodes every source and a null path', () {
    final List<ConfigEntry> rows = decodeConfigListEnvelope(
      ok(
        fbs.PayloadTypeId.ConfigListResult,
        fbs.ConfigListResultObjectBuilder(
          entries: [
            for (final s in fbs.ConfigValueSource.values)
              fbs.ConfigEntryObjectBuilder(name: 'a.b', value: '1', source: s, path: '/f', overridden: true),
            fbs.ConfigEntryObjectBuilder(name: 'x', value: '"y"', source: fbs.ConfigValueSource.EnvBase),
          ],
        ),
      ),
    );
    expect(rows.take(7).map((r) => r.source), ConfigValueSource.values);
    expect(rows.first.path, '/f');
    expect(rows.first.overridden, isTrue);
    expect(rows.last.path, isNull, reason: 'null for absence');
    expect(rows.last.overridden, isFalse);
  });

  test('get / path / unset / file text / gc decode their payloads', () {
    expect(
      decodeConfigGetEnvelopeInternal(
        ok(fbs.PayloadTypeId.ConfigGetResult, fbs.ConfigGetResultObjectBuilder(value: 'A B')),
      ).value,
      'A B',
    );
    expect(
      decodeConfigPathEnvelopeInternal(
        ok(fbs.PayloadTypeId.ConfigPathResult, fbs.ConfigPathResultObjectBuilder(paths: ['/a', '/b'])),
      ),
      ['/a', '/b'],
    );
    expect(
      decodeConfigUnsetEnvelopeInternal(
        ok(fbs.PayloadTypeId.ConfigUnsetResult, fbs.ConfigUnsetResultObjectBuilder(path: '/f')),
      ).path,
      '/f',
    );
    final ConfigFileText text = decodeConfigFileTextEnvelopeInternal(
      ok(fbs.PayloadTypeId.ConfigFileText, fbs.ConfigFileTextObjectBuilder(path: '/f', text: 'a = 1\n')),
    );
    expect((text.path, text.text), ('/f', 'a = 1\n'));
    final List<MissingRepoConfig> missing = decodeConfigGcListEnvelopeInternal(
      ok(
        fbs.PayloadTypeId.ConfigGcList,
        fbs.ConfigGcListObjectBuilder(
          missing: [
            fbs.MissingRepoConfigObjectBuilder(configDir: '/c', repoPath: '/r'),
            fbs.MissingRepoConfigObjectBuilder(configDir: '/w', repoPath: '/r/.jj', kind: fbs.ConfigGcKind.Workspace),
          ],
        ),
      ),
    );
    expect((missing.first.configDir, missing.first.repoPath, missing.first.kind), ('/c', '/r', ConfigGcKind.repo));
    expect((missing.last.configDir, missing.last.kind), ('/w', ConfigGcKind.workspace));
    final ConfigGcResult gc = decodeConfigGcResultEnvelopeInternal(
      ok(
        fbs.PayloadTypeId.ConfigGcResult,
        fbs.ConfigGcResultObjectBuilder(
          deleted: ['/d'],
          failed: [fbs.ConfigGcFailureObjectBuilder(configDir: '/f', reason: 'why')],
        ),
      ),
    );
    expect(gc.deleted, ['/d']);
    expect((gc.failed.single.configDir, gc.failed.single.reason), ('/f', 'why'));
    expect(decodeConfigFileWriteEnvelopeInternal(ok(fbs.PayloadTypeId.NONE, null)).warnings, isEmpty);
  });

  test('set carries the working-copy author and the precondition, both null for absence', () {
    final ConfigSetResult withFacts = decodeConfigSetEnvelope(
      ok(
        fbs.PayloadTypeId.ConfigSetResult,
        fbs.ConfigSetResultObjectBuilder(
          path: '/f',
          workingCopyAuthor: fbs.WorkingCopyAuthorObjectBuilder(name: 'A', email: 'a@x'),
        ),
        precondition: fbs.PreconditionObjectBuilder(wasSnapshotTaken: true),
      ),
    );
    expect(withFacts.path, '/f');
    expect((withFacts.workingCopyAuthor!.name, withFacts.workingCopyAuthor!.email), ('A', 'a@x'));
    expect(withFacts.precondition!.wasSnapshotTaken, isTrue);

    final ConfigSetResult bare = decodeConfigSetEnvelope(
      ok(fbs.PayloadTypeId.ConfigSetResult, fbs.ConfigSetResultObjectBuilder(path: '/f')),
    );
    expect(bare.workingCopyAuthor, isNull);
    expect(bare.precondition, isNull);
  });

  test('an error envelope and a wrong payload throw ZanshinFfiException', () {
    final Uint8List error = fbs.EnvelopeObjectBuilder(
      ok: false,
      error: fbs.FfiErrorObjectBuilder(code: 'jj.config_unrecognized_file', context: '/a'),
    ).toBytes();
    expect(
      () => decodeConfigSetEnvelope(error),
      throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.config_unrecognized_file')),
    );
    expect(
      () => decodeConfigGetEnvelopeInternal(
        ok(fbs.PayloadTypeId.ConfigPathResult, fbs.ConfigPathResultObjectBuilder(paths: [])),
      ),
      throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
    );
  });

  test('the adapters reject an interior NUL before crossing FFI', () {
    for (final call in <void Function()>[
      () => zanshinConfigList(name: 'a\u0000'),
      () => zanshinConfigGet('a\u0000'),
      () => zanshinConfigPath(ConfigScope.repo, workspaceRoot: '/a\u0000'),
      () => zanshinConfigSet(const ConfigScopeTarget(ConfigScope.user), 'a', 'b\u0000'),
      () => zanshinConfigUnset(const ConfigFileTarget('/\u0000'), 'a'),
      () => zanshinConfigFileRead(const ConfigFileTarget('/\u0000')),
      () => zanshinConfigFileWrite('/f', 'a\u0000'),
      () => zanshinConfigGcDelete(['/\u0000']),
    ]) {
      expect(call, throwsArgumentError);
    }
  });
}
