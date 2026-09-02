// SPDX-License-Identifier: MIT

import 'package:inject_annotation/inject_annotation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zanshin_core/zanshin_core.dart';

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
