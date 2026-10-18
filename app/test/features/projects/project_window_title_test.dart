// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member

import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/projects/project_window_title.dart';

void main() {
  late bool windowingWasEnabled;

  setUp(() {
    // The machine-global `flutter config --enable-windowing` decides this at compile time; pin it.
    windowingWasEnabled = isWindowingEnabled;
    isWindowingEnabled = true;
  });

  tearDown(() {
    isWindowingEnabled = windowingWasEnabled;
  });

  WindowController window() {
    final controller = WindowController(
      size: const Size(800, 600),
      title: 'Zanshin',
      delegate: WindowControllerDelegate(),
    );
    addTearDown(controller.destroy);
    return controller;
  }

  Widget titled(WindowController controller, String title) => WindowScope(
    controller: controller,
    child: ProjectWindowTitle(title: title, child: const SizedBox.shrink()),
  );

  testWidgets("the window takes the project's name, and the next name when the project changes", (tester) async {
    final WindowController controller = window();
    final titles = <String>[];
    controller.addListener(() => titles.add(controller.title));

    await tester.pumpWidget(titled(controller, 'zanshin'));
    expect(controller.title, 'zanshin');

    await tester.pumpWidget(titled(controller, 'jj'));
    expect(controller.title, 'jj');

    await tester.pumpWidget(titled(controller, 'jj'));
    expect(titles, <String>['zanshin', 'jj'], reason: 'an unchanged title is not set again');
  });

  testWidgets('without a window it does nothing', (tester) async {
    await tester.pumpWidget(const ProjectWindowTitle(title: 'zanshin', child: SizedBox.shrink()));
    expect(tester.takeException(), isNull);

    isWindowingEnabled = false;
    await tester.pumpWidget(const ProjectWindowTitle(title: 'other', child: SizedBox.shrink()));
    expect(tester.takeException(), isNull);
  });
}
