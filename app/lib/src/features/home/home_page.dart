// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:inject_flutter/inject_flutter.dart';
import 'package:zanshin_shell/zanshin_shell.dart';

import '../shell/floating_shell.dart';
import '../shell/floating_shell_view_model.dart';

part 'home_page.factory.dart';

/// The project window's content: the floating shell (Story 11.3).
///
/// Every slot stays empty until its story fills it (Claude's proposal). Two stand-ins hold the place of 11.4: the
/// bar's row is a `WindowDragArea`, so the window moves by it, and the canvas is the shell's `--canvas-base` fill.
@immutable
class HomePage extends StatelessWidget {
  @assistedInject
  const HomePage({
    required this.viewModelFactory,
    @assisted super.key,
  });

  /// Binds the shell's view model to this page.
  final ViewModelFactory<FloatingShellViewModel> viewModelFactory;

  @override
  Widget build(BuildContext context) => viewModelFactory(
    builder: (context, vm, _) => FloatingShell(
      controller: vm.shell,
      // An opaque target, so a press in the bar's row moves the window and never reaches the graph below.
      barRow: const WindowDragArea(child: ColoredBox(color: Color(0x00000000))),
    ),
  );
}
