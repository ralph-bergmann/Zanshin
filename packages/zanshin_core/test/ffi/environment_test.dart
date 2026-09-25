// SPDX-License-Identifier: MIT

// Story 9.36's `zanshin_environment_adopt` adapter against the REAL compiled
// cdylib — which is what credits the extern fn in the coverage ratchet's guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// ONLY REFUSED requests here: dart_test.yaml runs every zanshin_core test file
// in ONE process against ONE cdylib, so an installed environment would replace
// the one every later file reads — the pinned JJ_CONFIG and XDG_CONFIG_HOME
// included. A refused request installs nothing; the successful install lives in
// its own cargo test process (crates/zanshin-ffi/tests/environment_ffi.rs).

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/environment.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// Throws the `jj.invalid_input` refusal naming [context].
Matcher _refusedWith(String context) => throwsA(
  isA<ZanshinFfiException>()
      .having((e) => e.code, 'code', 'jj.invalid_input')
      .having((e) => e.context, 'context', context),
);

void main() {
  group('zanshin_environment_adopt (real cdylib, refusals only)', () {
    test('an absent or an empty environment is refused', () {
      expect(
        () => decodeEnvironmentAdoptEnvelopeInternal(zanshinEnvironmentAdopt(null)),
        _refusedWith('variables is required'),
      );
      expect(
        () => decodeEnvironmentAdoptEnvelopeInternal(zanshinEnvironmentAdopt(const [])),
        _refusedWith('variables is required'),
      );
    });

    test('a variable with an empty name is refused', () {
      final List<EnvironmentVariable> variables = [
        (name: Uint8List.fromList('PATH'.codeUnits), value: Uint8List.fromList('/bin'.codeUnits)),
        (name: Uint8List(0), value: Uint8List.fromList('x'.codeUnits)),
      ];

      expect(
        () => decodeEnvironmentAdoptEnvelopeInternal(zanshinEnvironmentAdopt(variables)),
        _refusedWith('variables[1].name is required'),
      );
    });
  });

  test('an ok envelope decodes to nothing', () {
    expect(
      () => decodeEnvironmentAdoptEnvelopeInternal(fbs.EnvelopeObjectBuilder(ok: true).toBytes()),
      returnsNormally,
    );
  });
}
