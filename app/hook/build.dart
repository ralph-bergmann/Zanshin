// SPDX-License-Identifier: MIT

import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await const RustBuilder(
      assetName: 'src/ffi/bindings.dart',
      cratePath: '../crates/zanshin-ffi',
    ).run(input: input, output: output);
  });
}
