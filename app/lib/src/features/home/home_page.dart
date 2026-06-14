// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:inject_annotation/inject_annotation.dart';

import '../../ffi/zanshin_version.dart';
import '../shell/app_shell.dart';

part 'home_page.factory.dart';

@immutable
class HomePage extends StatelessWidget {
  @assistedInject
  const HomePage({
    required this.zanshinFfiVersion,
    @assisted super.key,
  });

  final ZanshinFfiVersion zanshinFfiVersion;

  @override
  Widget build(BuildContext context) => const AppShell();
}
