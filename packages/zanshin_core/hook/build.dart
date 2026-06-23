// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // Coverage: `cargo make coverage` drops a `coverage.on` marker in this package root.
    // The Dart hooks-runner scrubs the build-hook environment, so a marker FILE is the only
    // reliable trigger; when present, the cdylib is built with LLVM source-based
    // instrumentation so `dart test` measures it. Normal builds (no marker) are unaffected.
    final coverage = File.fromUri(input.packageRoot.resolve('coverage.on')).existsSync();
    await RustBuilder(
      assetName: 'src/ffi/bindings.dart',
      cratePath: '../../crates/zanshin-ffi',
      extraCargoEnvironmentVariables: coverage
          ? const <String, String>{'RUSTFLAGS': '-C instrument-coverage'}
          : const <String, String>{},
    ).run(input: input, output: output);
  });
}
