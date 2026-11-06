// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show RemotePollSetting;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../graph/graph_ports.dart';
import '../graph/graph_view_model.dart';
import '../shell/shell_toast.dart';
import 'push_sheet_model.dart';
import 'remote_sync.dart';

final _log = Logger('zanshin.sync');

/// The poll's interval for [setting]; null for Off.
Duration? remotePollInterval(RemotePollSetting setting) => switch (setting) {
  RemotePollSetting.off => null,
  RemotePollSetting.fiveMinutes => const Duration(minutes: 5),
  RemotePollSetting.fifteenMinutes => const Duration(minutes: 15),
};

/// One open repository's sync (Story 11.8): Fetch, the Push sheet's open state, the remote-change poll and its badge,
/// over [RemoteSync].
///
/// - **Fetch** runs `jj git fetch` with the CLI's default remotes (no remote passed; 9.30). While it runs it is
///   [fetching] with its [fetchProgress] and the project's dot reads syncing ([SyncRun]); its result shows in the
///   toast — "Nothing changed." when it changed nothing — and clears the badge; a failure shows jj's text with Retry
///   and changes nothing else. A stale working copy's refusal shows no toast (the stale notice is that surface).
/// - **Enable rules:** Fetch while the default fetch remotes are not empty, Push while the repository has a remote;
///   both never while the working copy is stale ([GraphViewModel.stale]) or a fetch runs.
/// - **Poll** (read-only; 9.24): every [remotePollInterval] of the project's setting, and on [poll] (the app turned
///   active), each default fetch remote's `remoteChanges`. The [badge] counts the bookmark changes (tags excluded); a
///   failed tick is silent and leaves it; ticks never overlap; nothing polls and no badge shows while the working copy
///   is stale or the setting is Off.
/// - **Push:** [openPush] opens the sheet ([pushSheet]); its result shows in the toast with Undo while recorded, through
///   [GraphViewModel.undoOperation] (the undo's own toast carries jj's warning and Redo).
class SyncModel extends ChangeNotifier {
  /// The sync of [_sync] beside [_graph]'s view model, toasting into [_toasts]; `pollSetting` reads the project's
  /// interval and `pollChanged` says when it may have changed; `changeTarget` is the Push sheet's change row.
  SyncModel({
    required this._sync,
    required this._graph,
    required this._toasts,
    required this._pollSetting,
    this._pollChanged,
    this._changeTarget,
    this._syncing,
  }) {
    _stale = _graph.stale != null;
    _graph.addListener(_graphChanged);
    _pollChanged?.addListener(_schedule);
    _schedule();
    unawaited(_loadRemotes());
  }

  final RemoteSync _sync;
  final GraphViewModel _graph;
  final ShellToasts _toasts;
  final RemotePollSetting Function() _pollSetting;
  final Listenable? _pollChanged;
  final PushChangeTarget? Function()? _changeTarget;
  final SyncRun? _syncing;

  var _fetchRemotes = const <String>[];
  var _pushRemotes = const <String>[];
  var _remoteNames = const <String>[];
  var _fetching = false;
  double? _fetchProgress;
  var _changes = const <String, List<String>>{};
  var _polling = false;
  Timer? _timer;
  Duration? _interval;
  var _stale = false;
  PushSheetModel? _push;
  ShellToastEntry? _shown;
  var _disposed = false;

  /// The default fetch remotes, in remote-name order.
  List<String> get fetchRemotes => _fetchRemotes;

  /// The default push remotes.
  List<String> get pushRemotes => _pushRemotes;

  /// Whether the working copy is stale.
  bool get stale => _stale;

  /// Whether a fetch runs.
  bool get fetching => _fetching;

  /// The running fetch's completion in `[0, 1]`, null while unknown.
  double? get fetchProgress => _fetchProgress;

  /// Whether Fetch may run.
  bool get canFetch => !_stale && !_fetching && _push == null && _fetchRemotes.isNotEmpty;

  /// Whether Push may open its sheet.
  bool get canPush => !_stale && !_fetching && _push == null && _remoteNames.isNotEmpty;

  /// Whether the repository has a remote at all.
  bool get hasRemote => _remoteNames.isNotEmpty;

  /// The bookmark changes the last poll found, per remote; empty while stale or while the poll is Off.
  Map<String, List<String>> get remoteChanges =>
      _stale || remotePollInterval(_pollSetting()) == null ? const <String, List<String>>{} : _changes;

  /// Bumped by each fetch: a poll that began before it drops its result.
  var _fetches = 0;

  /// The badge: the number of changed bookmarks, null for none.
  int? get badge {
    final int count = remoteChanges.values.fold(0, (sum, names) => sum + names.length);
    return count == 0 ? null : count;
  }

  /// The open Push sheet's model.
  PushSheetModel? get pushSheet => _push;

  void _graphChanged() {
    final stale = _graph.stale != null;
    if (stale != _stale) {
      _stale = stale;
      _notify();
    }
  }

  Future<void> _loadRemotes() async {
    _fetchRemotes = await _read('git fetch remotes', _sync.fetchRemotes);
    _pushRemotes = await _read('git push remotes', _sync.pushRemotes);
    _remoteNames = await _read('remotes', _sync.remoteNames);
    // A remote no longer fetched keeps no poll findings.
    _changes = <String, List<String>>{
      for (final MapEntry<String, List<String>> entry in _changes.entries)
        if (_fetchRemotes.contains(entry.key)) entry.key: entry.value,
    };
    _notify();
  }

  /// Reads the remotes again (View › Reload, a Settings remote verb), and so does an open, idle Push sheet.
  Future<void> reloadRemotes() async {
    await _loadRemotes();
    await _push?.reloadRemotes();
  }

  /// [read]'s names; none when it fails (`jj.not_a_git_repo`, a closed handle).
  Future<List<String>> _read(String what, Future<List<String>> Function() read) async {
    try {
      return await read();
    } on ZanshinFfiException catch (error) {
      _log.fine('reading the $what failed: ${error.code}');
      return const <String>[];
    }
  }

  // ---- fetch ----

  /// `jj git fetch` with the default remotes.
  Future<void> fetch() async {
    if (_disposed || !canFetch) {
      return;
    }
    _fetches++;
    _fetching = true;
    _fetchProgress = null;
    _notify();
    StreamSubscription<ProgressEvent>? progress;
    try {
      final NetworkOperation<GitFetchResult> operation = _sync.fetch();
      progress = operation.progress.listen((event) {
        _fetchProgress = event.progress;
        _notify();
      });
      final SyncRun? syncing = _syncing;
      final GitFetchResult result = await (syncing == null ? operation.result : syncing(() => operation.result));
      _changes = const <String, List<String>>{};
      _show(_fetchedEntry(result));
    } on ZanshinFfiException catch (error) {
      _log.warning('the fetch failed: ${error.code}');
      if (error.code != 'jj.stale_working_copy') {
        _show(_fetchFailedEntry(error));
      }
    } finally {
      unawaited(progress?.cancel());
      _fetching = false;
      _fetchProgress = null;
      _notify();
    }
  }

  ShellToastEntry _fetchedEntry(GitFetchResult result) => ShellToastEntry(
    tone: result.warnings.isEmpty ? ZsToastTone.success : ZsToastTone.warn,
    build: (context, dismiss) {
      final bool nothing =
          result.changedBookmarks.isEmpty &&
          result.changedTags.isEmpty &&
          result.mutation.abandonedChangeIds.isEmpty &&
          result.numRewritten == 0;
      final InlineSpan text = TextSpan(
        text: nothing
            ? 'Nothing changed.' // l10n-ignore: jj's text
            : context.l10n.toastFetched(result.changedBookmarks.length, result.remotes.join(', ')),
      );
      return ZsToast(
        tone: result.warnings.isEmpty ? ZsToastTone.success : ZsToastTone.warn,
        message: toastWithWarnings(ZsColors.of(context), text, result.warnings),
        onDismiss: dismiss,
        identifier: 'sync-toast',
      );
    },
  );

  ShellToastEntry _fetchFailedEntry(ZanshinFfiException error) => ShellToastEntry(
    tone: ZsToastTone.error,
    build: (context, dismiss) => ZsToast(
      tone: ZsToastTone.error,
      message: TextSpan(text: error.context ?? error.code),
      actions: <ZsToastAction>[
        ZsToastAction(
          label: context.l10n.toastRetry,
          tooltip: 'jj git fetch', // l10n-ignore: jj command
          identifier: 'sync-toast-retry',
          onPressed: () {
            dismiss();
            unawaited(fetch());
          },
        ),
      ],
      onDismiss: dismiss,
      identifier: 'sync-toast',
    ),
  );

  // ---- poll ----

  void _schedule() {
    final Duration? interval = remotePollInterval(_pollSetting());
    if (interval == _interval && (interval == null || _timer != null)) {
      return;
    }
    _interval = interval;
    _timer?.cancel();
    _timer = interval == null ? null : Timer.periodic(interval, (_) => unawaited(poll()));
  }

  /// One read-only poll of the default fetch remotes (a tick, or the app turned active): skipped while Off, stale, a
  /// fetch runs or another poll runs; a failure is silent and leaves the badge.
  Future<void> poll() async {
    if (_disposed || _stale || _fetching || _polling || remotePollInterval(_pollSetting()) == null) {
      return;
    }
    _polling = true;
    final int fetches = _fetches;
    try {
      final List<String> remotes = _fetchRemotes.isEmpty ? await _sync.fetchRemotes() : _fetchRemotes;
      final found = <String, List<String>>{};
      for (final remote in remotes) {
        final List<RemoteRefChange> changes = await _sync.remoteChanges(remote).result;
        final names = <String>[
          for (final RemoteRefChange change in changes)
            if (change.kind == RemoteRefKind.bookmark) change.name,
        ];
        if (names.isNotEmpty) {
          found[remote] = names;
        }
      }
      // A fetch since the poll began made its findings stale.
      if (!_disposed && fetches == _fetches) {
        _changes = found;
        _notify();
      }
    } on ZanshinFfiException catch (error) {
      // Silent (Ralph, 2026-10-21): an unconfirmed credential prompt fails the tick; the next one tries again.
      _log.fine('the remote poll failed: ${error.code}');
    } finally {
      _polling = false;
    }
  }

  // ---- push ----

  /// Opens the Push sheet; nothing pushes before its Push.
  void openPush() {
    if (!canPush) {
      return;
    }
    final model = PushSheetModel(sync: _sync, change: _changeTarget?.call(), syncing: _syncing, onPushed: _pushed);
    _push = model;
    unawaited(model.load());
    _notify();
  }

  /// The sheet's exit ended: it is gone.
  void pushSheetClosed() {
    _push?.dispose();
    _push = null;
    _notify();
  }

  void _pushed(GitPushResult result) {
    if (result.failure != null && !result.recorded) {
      return;
    }
    _show(_pushedEntry(result));
  }

  ShellToastEntry _pushedEntry(GitPushResult result) {
    final names = <String>[];
    final remotes = <String>[];
    for (final PushRemote remote in result.remotes) {
      for (final PushRef ref in remote.refs) {
        if (ref.status == PushRefStatus.pushed) {
          if (!names.contains(ref.name)) {
            names.add(ref.name);
          }
          if (!remotes.contains(remote.name)) {
            remotes.add(remote.name);
          }
        }
      }
    }
    final bool undo = result.recorded;
    return ShellToastEntry(
      tone: result.warnings.isEmpty ? ZsToastTone.success : ZsToastTone.warn,
      build: (context, dismiss) {
        final AppLocalizations strings = context.l10n;
        final ZsColors colors = ZsColors.of(context);
        final InlineSpan text = result.nothingChanged || names.isEmpty
            ? const TextSpan(text: 'Nothing changed.') // l10n-ignore: jj's text
            : toastSpan(strings.toastPushed(toastSlot(0), remotes.join(', ')), <InlineSpan>[
                toastList(strings, <InlineSpan>[for (final String name in names) toastMono(colors, name)]),
              ]);
        return ZsToast(
          tone: result.warnings.isEmpty ? ZsToastTone.success : ZsToastTone.warn,
          message: toastWithWarnings(colors, text, result.warnings),
          actions: <ZsToastAction>[
            if (undo)
              ZsToastAction(
                label: strings.toastUndo,
                tooltip: 'jj undo', // l10n-ignore: jj command
                identifier: 'sync-toast-undo',
                onPressed: () {
                  dismiss();
                  unawaited(_undo(result));
                },
              ),
          ],
          onDismiss: dismiss,
          identifier: 'sync-toast',
        );
      },
    );
  }

  /// `jj undo` of the push while it is still the op-log head; else the warn toast says nothing happened.
  Future<void> _undo(GitPushResult result) async {
    if (_disposed) {
      return;
    }
    final GraphActionResult undone = await _graph.undoOperation(
      result.newOpId,
      GraphLoggedOperation(result.newOpId, result.description ?? ''),
    );
    if (undone is GraphActionDisabled && undone.reason == GraphDisabledReason.foreignOperation && !_disposed) {
      _show(
        ShellToastEntry(
          tone: ZsToastTone.warn,
          build: (context, dismiss) => ZsToast(
            tone: ZsToastTone.warn,
            message: TextSpan(text: context.l10n.toastNothingUndone),
            onDismiss: dismiss,
            identifier: 'sync-toast',
          ),
        ),
      );
    }
  }

  void _show(ShellToastEntry entry) {
    if (!_disposed) {
      _toasts.show(_shown = entry);
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _graph.removeListener(_graphChanged);
    _pollChanged?.removeListener(_schedule);
    _push?.dispose();
    final ShellToastEntry? shown = _shown;
    if (shown != null) {
      // Its Retry or Undo would run on a disposed model.
      _toasts.dismiss(shown);
    }
    super.dispose();
  }
}
