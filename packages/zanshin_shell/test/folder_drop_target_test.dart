// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

import 'zanshin_shell_test.dart' show RecordingPlatform;

void main() {
  late RecordingPlatform platform;
  final log = <String>[];

  setUp(() {
    log.clear();
    platform = RecordingPlatform();
    ZanshinShellPlatform.instance = platform;
  });

  tearDown(() => platform.close());

  Widget harness(Widget child) => Directionality(textDirection: TextDirection.ltr, child: child);

  group('registration', () {
    testWidgets('the first target of a view enables drops and the last one disables them', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(
        harness(
          Column(
            children: [
              _RecordingTarget(name: 'a', log: log, child: const SizedBox(height: 50)),
              _RecordingTarget(name: 'b', log: log, child: const SizedBox(height: 50)),
            ],
          ),
        ),
      );
      expect(platform.calls, ['setFolderDragHandler:set', 'enableFolderDrops:$viewId']);

      await tester.pumpWidget(
        harness(
          Column(
            children: [
              _RecordingTarget(name: 'a', log: log, child: const SizedBox(height: 50)),
            ],
          ),
        ),
      );
      expect(platform.calls, ['setFolderDragHandler:set', 'enableFolderDrops:$viewId']);

      await tester.pumpWidget(harness(const SizedBox.shrink()));
      expect(platform.calls, [
        'setFolderDragHandler:set',
        'enableFolderDrops:$viewId',
        'disableFolderDrops:$viewId',
        'setFolderDragHandler:null',
      ]);
    });

    testWidgets('a failing enable is reported, not thrown into the tree', (tester) async {
      platform.enableError = PlatformException(code: 'unknown-view');
      await tester.pumpWidget(harness(_RecordingTarget(name: 'a', log: log)));
      await tester.pump();
      expect(
        tester.takeException(),
        isA<PlatformException>().having((error) => error.code, 'code', 'unknown-view'),
      );
    });
  });
}

/// A [FolderDropTarget] that logs its callbacks as `name:callback …` entries.
class _RecordingTarget extends StatelessWidget {
  // ignore: unused_element_parameter
  const _RecordingTarget({required this.name, required this.log, this.accepts = true, this.child});

  final String name;
  final List<String> log;
  final bool accepts;
  final Widget? child;

  @override
  Widget build(BuildContext context) => FolderDropTarget(
    onDragUpdate: (details) {
      log.add('$name:update ${details.localPosition}');
      return accepts;
    },
    onDragExit: () => log.add('$name:exit'),
    onDrop: (details) => log.add('$name:drop ${details.paths} ${details.localPosition} ${details.globalPosition}'),
    child: child ?? const SizedBox.expand(),
  );
}
