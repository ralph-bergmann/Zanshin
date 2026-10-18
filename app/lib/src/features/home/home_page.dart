// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:inject_flutter/inject_flutter.dart';
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../shell/floating_shell.dart';
import '../shell/floating_shell_view_model.dart';

part 'home_page.factory.dart';

/// The project window's content: the floating shell (Story 11.3) on the window canvas, `ZsCanvas` (Story 11.4).
///
/// Every slot stays empty until its story fills it (Claude's proposal). The bar's row is the window's drag region
/// (design question (a), decision (g); Story 11.4): from the window's top edge down to the content top, the part the
/// islands leave empty moves the window on a drag and runs the system's titlebar action on a double-click.
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
      canvas: const ZsCanvas(),
      // An opaque target, so a press in the bar's row moves the window and never reaches the graph below.
      barRow: const WindowDragArea(child: ColoredBox(color: Color(0x00000000))),
    ),
  );
}
