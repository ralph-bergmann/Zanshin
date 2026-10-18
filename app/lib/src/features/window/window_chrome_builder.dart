// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_shell/zanshin_shell.dart';

final _log = Logger('zanshin.window');

/// Builds its window root with the window's chrome report: full screen and the standard window buttons' block, as
/// `zanshin_shell` measures them for this widget's Flutter view (Story 11.4).
///
/// The report is null until the shell answered, off macOS and when the watch failed; the token layer then takes the
/// DS reference geometry. On macOS it listens to the shell's changes for its view first, then watches the view, and
/// rebuilds only for a changed report; leaving the tree cancels the subscription and unwatches the view, and a late
/// answer is dropped. One builder per window root: 11.12's per-window roots reuse it.
class WindowChromeBuilder extends StatefulWidget {
  /// Hands the window's chrome report to [builder].
  const WindowChromeBuilder({required this.builder, super.key});

  /// Builds the window root from the report, null while there is none.
  final Widget Function(BuildContext context, WindowChrome? chrome) builder;

  @override
  State<WindowChromeBuilder> createState() => _WindowChromeBuilderState();
}

class _WindowChromeBuilderState extends State<WindowChromeBuilder> {
  int? _viewId;
  StreamSubscription<WindowChromeChange>? _changes;
  WindowChrome? _chrome;

  static bool get _onMacOS => !kIsWeb && Platform.isMacOS;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final int viewId = View.of(context).viewId;
    if (viewId == _viewId) {
      return;
    }
    _stop();
    _viewId = viewId;
    _chrome = null;
    if (!_onMacOS) {
      return;
    }
    _changes = ZanshinShell.onWindowChromeChanged
        .where((change) => change.viewId == viewId)
        .listen((change) => _apply(viewId, change.chrome));
    unawaited(
      ZanshinShell.watchWindowChrome(viewId).then(
        (chrome) => _apply(viewId, chrome),
        onError: (Object error, StackTrace stackTrace) {
          _log.warning('The chrome of window view $viewId could not be watched', error, stackTrace);
        },
      ),
    );
  }

  /// Applies [chrome] for [viewId] unless this state left the tree, watches another view now or has it already.
  void _apply(int viewId, WindowChrome chrome) {
    if (!mounted || viewId != _viewId || chrome == _chrome) {
      return;
    }
    _log.fine('Window view $viewId reports $chrome');
    setState(() => _chrome = chrome);
  }

  /// Stops following the current view.
  void _stop() {
    unawaited(_changes?.cancel());
    _changes = null;
    final int? viewId = _viewId;
    if (viewId == null || !_onMacOS) {
      return;
    }
    unawaited(
      ZanshinShell.unwatchWindowChrome(viewId).catchError((Object error, StackTrace stackTrace) {
        _log.warning('The chrome of window view $viewId could not be unwatched', error, stackTrace);
      }),
    );
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _chrome);
}
