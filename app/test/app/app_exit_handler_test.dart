// SPDX-License-Identifier: MIT

import 'dart:ui' show AppExitResponse;

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/app/app_exit_handler.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin_core/zanshin_core.dart';

/// A worker that only counts its closes; nothing else of it is reached.
class _Worker implements ZanshinWorker {
  var closes = 0;

  @override
  Future<void> close() async => closes++;

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a quit the close guards refuse is cancelled before the worker closes', () async {
    var closes = 0;

    final AppExitResponse response = await answerExitRequest(
      mayQuit: () async => false,
      closeWorker: () async => closes++,
    );

    expect(response, AppExitResponse.cancel);
    expect(closes, 0);
  });

  test('a quit the close guards allow closes the worker, then exits', () async {
    final steps = <String>[];

    final AppExitResponse response = await answerExitRequest(
      mayQuit: () async {
        steps.add('guards');
        return true;
      },
      closeWorker: () async => steps.add('close'),
    );

    expect(response, AppExitResponse.exit);
    expect(steps, <String>['guards', 'close']);
  });

  testWidgets(
    "⌘Q reaches the handler's one listener, started twice: the guards once, the worker only when they allow it",
    (
      tester,
    ) async {
      var allow = false;
      var asked = 0;
      final windows = AppWindows(exitProcess: () async {})
        ..addCloseGuard(() async {
          asked++;
          return allow;
        });
      final worker = _Worker();
      AppExitHandler(windows, worker)
        ..start()
        ..start();

      expect(await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
      expect((asked, worker.closes), (1, 0), reason: 'refused: cancelled, the worker untouched');

      allow = true;
      expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
      expect((asked, worker.closes), (2, 1), reason: 'allowed: the worker closes once, then the exit');
    },
  );
}
