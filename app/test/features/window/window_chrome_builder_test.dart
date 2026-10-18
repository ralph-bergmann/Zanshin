// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:zanshin/src/features/window/window_chrome_builder.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

import '../../helpers/recording_shell.dart';

const _block = WindowChrome(trafficLights: Rect.fromLTWH(19, 19, 60, 14));

void main() {
  late RecordingShell shell;
  late List<LogRecord> logs;

  setUp(() {
    ZanshinShellPlatform.instance = shell = RecordingShell();
    logs = <LogRecord>[];
    final Level level = Logger.root.level;
    Logger.root.level = Level.ALL;
    final StreamSubscription<LogRecord> subscription = Logger.root.onRecord.listen(logs.add);
    addTearDown(() async {
      Logger.root.level = level;
      await subscription.cancel();
      await shell.close();
    });
  });

  /// The builder over a probe that records every report it is built with.
  Future<List<WindowChrome?>> pumpBuilder(WidgetTester tester) async {
    final reports = <WindowChrome?>[];
    await tester.pumpWidget(
      WindowChromeBuilder(
        builder: (context, chrome) {
          reports.add(chrome);
          return const SizedBox.shrink();
        },
      ),
    );
    return reports;
  }

  testWidgets("the builder listens first, then watches its view and builds with the shell's answer", (tester) async {
    shell.chromeAnswer = Completer<WindowChrome>();
    final List<WindowChrome?> reports = await pumpBuilder(tester);
    final int viewId = tester.view.viewId;

    expect(shell.calls, <String>['watchWindowChrome:$viewId']);
    expect(shell.chromeChanges.hasListener, isTrue, reason: 'no change between the answer and the listen is lost');
    expect(reports, <WindowChrome?>[null], reason: 'no report before the answer: the reference geometry');

    shell.chromeAnswer!.complete(_block);
    await tester.pumpAndSettle();

    expect(reports.last, _block);
    expect(
      logs.where((record) => record.loggerName == 'zanshin.window' && record.level == Level.FINE),
      hasLength(1),
    );
  });

  testWidgets('changes for its view rebuild it; another view, or the same report again, change nothing', (
    tester,
  ) async {
    shell.chrome = _block;
    final List<WindowChrome?> reports = await pumpBuilder(tester);
    await tester.pumpAndSettle();
    final int viewId = tester.view.viewId;
    expect(reports.last, _block);
    final int builds = reports.length;

    shell.chromeChanges.add((viewId: viewId + 1, chrome: const WindowChrome(fullScreen: true)));
    await tester.pumpAndSettle();
    shell.chromeChanges.add((viewId: viewId, chrome: _block));
    await tester.pumpAndSettle();
    expect(reports, hasLength(builds), reason: 'a foreign view and an equal report do not rebuild');

    shell.chromeChanges.add((viewId: viewId, chrome: const WindowChrome(fullScreen: true)));
    await tester.pumpAndSettle();
    expect(reports.last, const WindowChrome(fullScreen: true));

    shell.chromeChanges.add((viewId: viewId, chrome: _block));
    await tester.pumpAndSettle();
    expect(reports.last, _block, reason: 'after full screen the block is back');
  });

  testWidgets('leaving the tree cancels the stream and unwatches the view; a late answer is dropped', (tester) async {
    shell.chromeAnswer = Completer<WindowChrome>();
    final List<WindowChrome?> reports = await pumpBuilder(tester);
    final int viewId = tester.view.viewId;

    await tester.pumpWidget(const SizedBox.shrink());

    expect(shell.calls, <String>['watchWindowChrome:$viewId', 'unwatchWindowChrome:$viewId']);
    expect(shell.chromeChanges.hasListener, isFalse);
    shell.chromeAnswer!.complete(_block);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(reports, <WindowChrome?>[null]);
  });

  testWidgets('a failed watch is logged at warning and leaves the report null', (tester) async {
    shell.chromeAnswer = Completer<WindowChrome>();
    final List<WindowChrome?> reports = await pumpBuilder(tester);
    shell.chromeAnswer!.completeError(PlatformException(code: 'unknown-view', message: 'no Flutter view with id 0'));
    await tester.pumpAndSettle();

    expect(reports.toSet(), <WindowChrome?>{null});
    final LogRecord warning = logs.singleWhere((record) => record.level == Level.WARNING);
    expect(warning.loggerName, 'zanshin.window');
    expect(warning.error, isA<PlatformException>().having((error) => error.code, 'code', 'unknown-view'));
  });
}
