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

  group('dispatch', () {
    bool send(FolderDragEvent event) => platform.folderDragHandler!(event);

    /// `outer` covers (0, 0)–(400, 300); `inner` sits inside it at (100, 100)–(300, 200).
    Widget nested({bool innerAccepts = true, bool withInner = true}) => harness(
      Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            width: 400,
            height: 300,
            child: _RecordingTarget(
              name: 'outer',
              log: log,
              child: Padding(
                padding: const EdgeInsets.all(100),
                child: withInner ? _RecordingTarget(name: 'inner', log: log, accepts: innerAccepts) : null,
              ),
            ),
          ),
        ],
      ),
    );

    testWidgets('enter and updates go to the innermost target with local positions', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      expect(send(FolderDragEntered(viewId: viewId, position: const Offset(150, 120), paths: const ['/a'])), isTrue);
      expect(send(FolderDragUpdated(viewId: viewId, position: const Offset(160, 130))), isTrue);
      expect(log, ['inner:update Offset(50.0, 20.0)', 'inner:update Offset(60.0, 30.0)']);
    });

    testWidgets('moving to another target exits the old one first', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      send(FolderDragEntered(viewId: viewId, position: const Offset(150, 120), paths: const ['/a']));
      send(FolderDragUpdated(viewId: viewId, position: const Offset(20, 20)));
      expect(log, ['inner:update Offset(50.0, 20.0)', 'inner:exit', 'outer:update Offset(20.0, 20.0)']);
    });

    testWidgets('leaving every target exits and rejects', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      send(FolderDragEntered(viewId: viewId, position: const Offset(20, 20), paths: const ['/a']));
      expect(send(FolderDragUpdated(viewId: viewId, position: const Offset(600, 500))), isFalse);
      expect(log, ['outer:update Offset(20.0, 20.0)', 'outer:exit']);
    });

    testWidgets('an exited drag ends the visit', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      send(FolderDragEntered(viewId: viewId, position: const Offset(20, 20), paths: const ['/a']));
      send(FolderDragExited(viewId: viewId));
      expect(log, ['outer:update Offset(20.0, 20.0)', 'outer:exit']);
    });

    testWidgets('a new enter exits the target of an unfinished drag', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      send(FolderDragEntered(viewId: viewId, position: const Offset(150, 120), paths: const ['/a']));
      send(FolderDragEntered(viewId: viewId, position: const Offset(20, 20), paths: const ['/a']));
      expect(log, ['inner:update Offset(50.0, 20.0)', 'inner:exit', 'outer:update Offset(20.0, 20.0)']);
    });

    testWidgets('a drop asks the target once more, then drops without an exit', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      send(FolderDragEntered(viewId: viewId, position: const Offset(150, 120), paths: const ['/a', '/b']));
      expect(
        send(FolderDropped(viewId: viewId, position: const Offset(155, 125), paths: const ['/a', '/b'])),
        isTrue,
      );
      expect(log, [
        'inner:update Offset(50.0, 20.0)',
        'inner:update Offset(55.0, 25.0)',
        'inner:drop [/a, /b] Offset(55.0, 25.0) Offset(155.0, 125.0)',
      ]);
    });

    testWidgets('a drop without an enter is still evaluated', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      expect(send(FolderDropped(viewId: viewId, position: const Offset(20, 20), paths: const ['/x'])), isTrue);
      expect(log, ['outer:update Offset(20.0, 20.0)', 'outer:drop [/x] Offset(20.0, 20.0) Offset(20.0, 20.0)']);
    });

    testWidgets('a rejected drop exits instead and never asks an outer target', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested(innerAccepts: false));
      expect(send(FolderDragEntered(viewId: viewId, position: const Offset(150, 120), paths: const ['/a'])), isFalse);
      expect(send(FolderDropped(viewId: viewId, position: const Offset(150, 120), paths: const ['/a'])), isFalse);
      expect(log, ['inner:update Offset(50.0, 20.0)', 'inner:update Offset(50.0, 20.0)', 'inner:exit']);
    });

    testWidgets('a target without onDragUpdate accepts everywhere', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(
        harness(
          FolderDropTarget(onDrop: (details) => log.add('drop ${details.paths}'), child: const SizedBox.expand()),
        ),
      );
      expect(send(FolderDragEntered(viewId: viewId, position: const Offset(10, 10), paths: const ['/a'])), isTrue);
      expect(send(FolderDropped(viewId: viewId, position: const Offset(10, 10), paths: const ['/a'])), isTrue);
      expect(log, ['drop [/a]']);
    });

    testWidgets('local positions follow transforms', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(
        harness(
          Align(
            alignment: Alignment.topLeft,
            child: Transform.translate(
              offset: const Offset(50, 50),
              child: Transform.scale(
                scale: 2,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 100,
                  height: 100,
                  child: _RecordingTarget(name: 'scaled', log: log),
                ),
              ),
            ),
          ),
        ),
      );
      send(FolderDragEntered(viewId: viewId, position: const Offset(70, 90), paths: const ['/a']));
      expect(log, ['scaled:update Offset(10.0, 20.0)']);
    });

    testWidgets('a target outside the scroll viewport is not hit', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(
        harness(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              height: 100,
              child: ListView(
                children: [
                  SizedBox(
                    height: 100,
                    child: _RecordingTarget(name: 'visible', log: log),
                  ),
                  SizedBox(
                    height: 100,
                    child: _RecordingTarget(name: 'cached', log: log),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      // `cached` is laid out below the 100 px viewport, where (10, 150) would hit it without clipping.
      expect(send(FolderDragEntered(viewId: viewId, position: const Offset(10, 150), paths: const ['/a'])), isFalse);
      expect(send(FolderDragUpdated(viewId: viewId, position: const Offset(10, 50))), isTrue);
      expect(log, ['visible:update Offset(10.0, 50.0)']);
    });

    testWidgets('a target removed mid-drag gets no further callbacks', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      send(FolderDragEntered(viewId: viewId, position: const Offset(150, 120), paths: const ['/a']));
      await tester.pumpWidget(nested(withInner: false));
      send(FolderDragUpdated(viewId: viewId, position: const Offset(20, 20)));
      expect(log, ['inner:update Offset(50.0, 20.0)', 'outer:update Offset(20.0, 20.0)']);
    });

    testWidgets('events for another view do nothing', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      expect(
        send(FolderDragEntered(viewId: viewId + 1, position: const Offset(150, 120), paths: const ['/a'])),
        isFalse,
      );
      expect(send(FolderDropped(viewId: viewId + 1, position: const Offset(150, 120), paths: const ['/a'])), isFalse);
      expect(log, isEmpty);
    });

    testWidgets('an exception in a callback is reported and rejects', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(
        harness(
          FolderDropTarget(
            onDragUpdate: (_) => throw StateError('boom'),
            onDrop: (_) {},
            child: const SizedBox.expand(),
          ),
        ),
      );
      expect(send(FolderDragEntered(viewId: viewId, position: const Offset(10, 10), paths: const ['/a'])), isFalse);
      expect(tester.takeException(), isA<StateError>());
    });
  });
}

/// A [FolderDropTarget] that logs its callbacks as `name:callback …` entries.
class _RecordingTarget extends StatelessWidget {
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
