// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';

import 'remote_sync.dart';

final _log = Logger('zanshin.sync');

/// Runs a fetch or push with the project's dot on syncing (`ProjectSession.syncing`).
typedef SyncRun = Future<T> Function<T>(Future<T> Function() run);

/// A commit check jj lets a flag override (`push.rs:188-202` @ v0.46.0).
enum PushAllow {
  /// `--allow-empty-description`.
  emptyDescription('--allow-empty-description'), // l10n-ignore: jj flag

  /// `--allow-private`.
  private('--allow-private'), // l10n-ignore: jj flag

  /// `--allow-conflicts`.
  conflicts('--allow-conflicts'); // l10n-ignore: jj flag

  const PushAllow(this.flag);

  /// The flag.
  final String flag;

  /// The flag for [reason], or null when no flag overrides it (no author and/or committer).
  static PushAllow? of(PushRejectReason reason) => switch (reason) {
    PushRejectReason.noDescription => emptyDescription,
    PushRejectReason.private => private,
    PushRejectReason.conflicts => conflicts,
    PushRejectReason.noAuthor => null,
  };
}

/// A row of the Push sheet: a bookmark or tag by name.
typedef PushRowKey = ({PushRefKind kind, String name});

/// A refusal with the remote whose plan reports it (the remote a fix-it acts on).
typedef PushRemoteRefusal = ({PushRefusal refusal, String remote});

/// Where the Push sheet is.
enum PushSheetPhase {
  /// The plans load.
  loading,

  /// The user chooses.
  ready,

  /// The push runs.
  pushing,

  /// The push failed in part; the sheet shows what happened.
  done,
}

/// The change row's target: the change `id` and how the command names it, `rev` (`@`, else the short id).
typedef PushChangeTarget = ({String id, String rev});

/// The Push sheet's state (Story 11.8 item 7; DS components/push/PushDialog.prompt.md): exactly the parameters of
/// `jj git push`, from 9.20's dry-run plans — nothing is derived app-side and nothing pushes before [push].
///
/// - **Remotes:** chips for every remote; the default ones ([RemoteSync.pushRemotes]) need no flag, any other choice
///   names each chosen remote with `--remote`.
/// - **Rows** are the union of the dry runs bare, `--tracked`, `--all` and `--deleted` for the chosen remotes, keyed by
///   kind and name, in plan order. The mode's plan is its selection: a row it pushes is ticked, one it skips shows
///   "skipped" with jj's reason and hint and never changes the command — unless the skip is a commit check the user
///   allowed, which the flag then sends. A hand toggle switches to the custom mode with the ticked set; a row is
///   tickable by hand only while naming it is not refused on any chosen remote ([PushRef.explicitRefusal]) and every
///   reason jj refuses its commit for is allowed.
/// - **Change row:** the selection, else @: `--change <rev>`, or `--named <name>=<rev>` once the generated name is
///   edited; ticking it switches to the custom mode. It is checked like a named ref, by its own dry run.
/// - **Allow chips** set a flag for every commit; it is written while a sent ref or the ticked change needs it.
/// - **Check:** every command is dry-run as it stands ("Checked with --dry-run"); its failure disables Push.
/// - **Push** runs the command; a full success closes the sheet and reports through `onPushed`, a partial one stays as
///   [PushSheetPhase.done] until [done]. A refusal before the network keeps the sheet ready with jj's text.
class PushSheetModel extends ChangeNotifier {
  /// The sheet over [_sync]; [change] is the change row's target (none without one), `syncing` runs the push with the
  /// project's dot on syncing, [onPushed] hears the push's result when the sheet finishes.
  PushSheetModel({required this._sync, required this.onPushed, this.change, this._syncing});

  final RemoteSync _sync;
  final SyncRun? _syncing;

  /// The change row's target.
  final PushChangeTarget? change;

  /// Hears a push that finished: at once after a full success, else at [done].
  final ValueChanged<GitPushResult> onPushed;

  static const _modes = <PushMode>[PushMode.bare, PushMode.tracked, PushMode.all, PushMode.deleted];

  var _remoteNames = const <String>[];
  var _defaults = const <String>[];
  var _chosen = const <String>[];
  var _config = const PushConfig();
  final _plans = <PushMode, GitPushResult>{};
  var _rows = const <PushRowKey>[];
  ZanshinFfiException? _planError;
  GitPushResult? _changePlan;
  ZanshinFfiException? _changeError;
  PushMode _mode = PushMode.bare;
  final _custom = <PushRowKey>{};
  var _changeOn = false;
  String? _name;
  final _allow = <PushAllow>{};
  PushSheetPhase _phase = PushSheetPhase.loading;
  double? _progress;
  GitPushResult? _result;
  ZanshinFfiException? _pushError;
  var _closing = false;
  var _disposed = false;
  var _planSerial = 0;
  var _checkSerial = 0;
  PushRequest? _checked;
  GitPushResult? _checkResult;
  String? _checkError;
  PushRowKey? _fixing;
  ({PushRowKey key, String text})? _fixError;

  /// Every remote's name.
  List<String> get remoteNames => _remoteNames;

  /// The remotes `jj git push` uses without `--remote`.
  List<String> get defaultRemotes => _defaults;

  /// The chosen remotes.
  List<String> get chosen => _chosen;

  /// `git.sign-on-push` and `revsets.git-push`.
  PushConfig get config => _config;

  /// Where the sheet is.
  PushSheetPhase get phase => _phase;

  /// The mode.
  PushMode get mode => _mode;

  /// The rows, in plan order.
  List<PushRowKey> get rows => _rows;

  /// Why the plans could not be read.
  ZanshinFfiException? get planError => _planError;

  /// Why the change's plan could not be read (a bad generated name, for instance).
  ZanshinFfiException? get changeError => _changeError;

  /// The push's progress in `[0, 1]`, null while unknown.
  double? get progress => _progress;

  /// The result of a push that failed in part.
  GitPushResult? get result => _result;

  /// A refusal of the last push before the network.
  ZanshinFfiException? get pushError => _pushError;

  /// Whether the sheet leaves; the host keeps it until its exit ends.
  bool get closing => _closing;

  /// The allowed commit checks.
  Set<PushAllow> get allowed => Set<PushAllow>.unmodifiable(_allow);

  /// Whether the change row is ticked.
  bool get changeOn => _changeOn;

  /// The change's bookmark name jj generates (`templates.git_push_bookmark`), from its dry run.
  String? get generatedName => _changePlan?.createdBookmarks.firstOrNull?.name;

  /// The change row's name: the typed one, else the generated one.
  String get changeName => _name ?? generatedName ?? '';

  /// Whether the user typed a name of their own.
  bool get named => _name != null && _name != generatedName;

  /// The row whose fix-it runs; null while none does.
  PushRowKey? get fixing => _fixing;

  /// jj's text for [key]'s failed fix-it; null when its last one did not fail.
  String? fixErrorOf(PushRowKey key) => _fixError?.key == key ? _fixError?.text : null;

  bool get _busy => _phase != PushSheetPhase.ready || _fixing != null;

  List<String>? get _remotesArg => setEquals(_chosen.toSet(), _defaults.toSet()) ? null : _chosen;

  /// Reads the remotes and the config, then the plans.
  Future<void> load() async {
    try {
      _remoteNames = await _sync.remoteNames();
      _defaults = await _sync.pushRemotes();
      _config = await _sync.pushConfig();
    } on ZanshinFfiException catch (error) {
      _log.warning('reading the push remotes failed: ${error.code}');
      _planError = error;
      _phase = PushSheetPhase.ready;
      _notify();
      return;
    }
    // A default no remote carries (the implicit `origin`, say) stays: the plan passes no `--remote` and shows jj's
    // refusal, as the CLI's bare `jj git push` would.
    _chosen = _defaults.isEmpty || _defaults.any((name) => !_remoteNames.contains(name))
        ? _defaults
        : <String>[
            for (final String name in _remoteNames)
              if (_defaults.contains(name)) name,
          ];
    await _replan();
  }

  /// Reads the remotes again ([load]) after they changed elsewhere; nothing while the sheet is busy or leaves.
  Future<void> reloadRemotes() => _busy || _closing ? Future<void>.value() : load();

  /// Chooses [remote] in or out; the last chosen remote stays.
  void toggleRemote(String remote) {
    if (_busy) {
      return;
    }
    final bool on = _chosen.contains(remote);
    if (on && _chosen.length == 1) {
      return;
    }
    _chosen = <String>[
      for (final String name in _remoteNames)
        if (name == remote ? !on : _chosen.contains(name)) name,
    ];
    unawaited(_replan());
  }

  Future<void> _replan() async {
    final int serial = ++_planSerial;
    _phase = PushSheetPhase.loading;
    _fixError = null;
    _notify();
    final plans = <PushMode, GitPushResult>{};
    ZanshinFfiException? planError;
    GitPushResult? changePlan;
    ZanshinFfiException? changeError;
    // No chosen remote but the defaults: jj resolves them and refuses when none exists.
    if (_chosen.isNotEmpty || _remotesArg == null) {
      final base = PushRequest(remotes: _remotesArg, dryRun: true);
      try {
        final List<GitPushResult> results = await Future.wait(<Future<GitPushResult>>[
          for (final PushMode mode in _modes) _sync.push(base.inMode(mode)).result,
        ]);
        for (var i = 0; i < _modes.length; i++) {
          plans[_modes[i]] = results[i];
        }
      } on ZanshinFfiException catch (error) {
        _log.warning('planning the push failed: ${error.code}');
        planError = error;
      }
      final PushChangeTarget? target = change;
      if (target != null) {
        try {
          changePlan = await _sync
              .push(
                PushRequest(remotes: _remotesArg, mode: PushMode.custom, changes: <String>[target.rev], dryRun: true),
              )
              .result;
        } on ZanshinFfiException catch (error) {
          changeError = error;
        }
      }
    }
    if (serial != _planSerial || _disposed) {
      return;
    }
    _plans
      ..clear()
      ..addAll(plans);
    _planError = planError;
    _changePlan = changePlan;
    _changeError = changeError;
    final seen = <PushRowKey>{};
    _rows = <PushRowKey>[
      for (final PushMode mode in _modes)
        for (final PushRemote remote in _plans[mode]?.remotes ?? const <PushRemote>[])
          for (final PushRef ref in remote.refs)
            if (seen.add((kind: ref.kind, name: ref.name))) (kind: ref.kind, name: ref.name),
    ];
    _custom.removeWhere((key) => !seen.contains(key));
    _checked = null;
    _phase = PushSheetPhase.ready;
    _changed();
  }

  // ---- rows ----

  Iterable<PushRef> _refsIn(GitPushResult? plan, PushRowKey key, {String? remote}) sync* {
    for (final PushRemote r in plan?.remotes ?? const <PushRemote>[]) {
      if (remote == null || r.name == remote) {
        yield* r.refs.where((ref) => ref.kind == key.kind && ref.name == key.name);
      }
    }
  }

  Iterable<PushRef> _allRefs(PushRowKey key) sync* {
    for (final PushMode mode in _modes) {
      yield* _refsIn(_plans[mode], key);
    }
  }

  /// [key]'s row on [remote]: the current mode's plan first, else any plan's; null when no plan moves it there.
  PushRef? refOn(PushRowKey key, String remote) {
    final PushRef? own = _mode == PushMode.custom ? null : _refsIn(_plans[_mode], key, remote: remote).firstOrNull;
    return own ?? _modes.map((mode) => _refsIn(_plans[mode], key, remote: remote).firstOrNull).nonNulls.firstOrNull;
  }

  /// The skip refusal of [key] on [remote] in the current bulk mode, when its plan skips it.
  PushRefusal? skippedOn(PushRowKey key, String remote) {
    if (_mode == PushMode.custom) {
      return null;
    }
    final PushRef? ref = _refsIn(_plans[_mode], key, remote: remote).firstOrNull;
    return ref != null && ref.path != PushPath.push && !sent(key) ? ref.refusal : null;
  }

  /// The commit check's rejection of [key], when one plan reports it.
  PushCommitRejection? rejectionOf(PushRowKey key) => _allRefs(key).map((ref) => ref.rejection).nonNulls.firstOrNull;

  /// Why naming [key] by hand is refused on a chosen remote, with that remote; null when it is not.
  PushRemoteRefusal? explicitRefusalOf(PushRowKey key) {
    for (final PushMode mode in _modes) {
      for (final PushRemote remote in _plans[mode]?.remotes ?? const <PushRemote>[]) {
        for (final PushRef ref in remote.refs) {
          if (ref.kind == key.kind && ref.name == key.name && ref.explicitRefusal != null) {
            return (refusal: ref.explicitRefusal!, remote: remote.name);
          }
        }
      }
    }
    return null;
  }

  bool _allows(PushCommitRejection? rejection) =>
      rejection == null || rejection.reasonKinds.every((reason) => _allow.contains(PushAllow.of(reason)));

  /// Whether [key] can be ticked by hand.
  bool tickable(PushRowKey key) => explicitRefusalOf(key) == null && _allows(rejectionOf(key));

  /// Whether [key] is sent: ticked by hand, or pushed by the current mode's plan (a skip for an allowed commit check
  /// included).
  bool sent(PushRowKey key) {
    if (_mode == PushMode.custom) {
      return _custom.contains(key);
    }
    return _refsIn(_plans[_mode], key).any(
      (ref) => ref.path == PushPath.push || (ref.rejection != null && _allows(ref.rejection)),
    );
  }

  /// Ticks or unticks [key] by hand: the mode turns custom with what was ticked.
  void toggle(PushRowKey key) {
    if (_busy || (!sent(key) && !tickable(key))) {
      return;
    }
    _toCustom();
    if (!_custom.remove(key)) {
      _custom.add(key);
    }
    _changed();
  }

  void _toCustom() {
    if (_mode == PushMode.custom) {
      return;
    }
    final ticked = <PushRowKey>[
      for (final PushRowKey key in _rows)
        if (sent(key) && tickable(key)) key,
    ];
    _mode = PushMode.custom;
    _custom
      ..clear()
      ..addAll(ticked);
  }

  /// Chooses a bulk [mode] (or the bare push); the change row unticks, as the modes exclude it.
  void setMode(PushMode mode) {
    if (_busy || mode == PushMode.custom) {
      return;
    }
    _mode = mode;
    _custom.clear();
    _changeOn = false;
    _changed();
  }

  // ---- change ----

  Iterable<PushRef> get _changeRefs sync* {
    for (final PushRemote remote in _changePlan?.remotes ?? const <PushRemote>[]) {
      yield* remote.refs;
    }
  }

  /// The change's commit rejection.
  PushCommitRejection? get changeRejection => _changeRefs.map((ref) => ref.rejection).nonNulls.firstOrNull;

  /// Why naming the change is refused, beyond its commit check (jj's text); null when it is not.
  String? get changeRefusal {
    final ZanshinFfiException? error = _changeError;
    if (error != null) {
      return error.context ?? error.code;
    }
    return _changeRefs.map((ref) => ref.explicitRefusal?.message).nonNulls.firstOrNull;
  }

  /// Whether the change row can be ticked.
  bool get changeTickable => change != null && changeRefusal == null && _allows(changeRejection);

  /// Ticks or unticks the change row; ticking it turns the mode custom.
  void setChange(bool on) {
    if (_busy || (on && !changeTickable)) {
      return;
    }
    if (on) {
      _toCustom();
    }
    _changeOn = on;
    _changed();
  }

  /// The name typed into the change row.
  void setName(String name) {
    // The generated name typed back stays generated, so a re-plan cannot turn it into `--named`.
    _name = name == generatedName ? null : name;
    _changed();
  }

  // ---- allow ----

  /// Allows or disallows [allow] for every commit.
  void setAllow(PushAllow allow, bool on) {
    if (_busy) {
      return;
    }
    if (on) {
      _allow.add(allow);
    } else {
      _allow.remove(allow);
    }
    _changed();
  }

  // ---- fix-its (Story 11.22) ----

  /// [key]'s Track fix-it: `jj bookmark track <symbol>`, then the sheet re-plans.
  Future<void> track(PushRowKey key, String symbol) => _fix(key, () => _sync.track(<String>[symbol]));

  /// [key]'s Fetch fix-it: `jj git fetch` with the default remotes, then the sheet re-plans.
  Future<void> fetchAndReplan(PushRowKey key) => _fix(key, () async {
    final NetworkOperation<GitFetchResult> fetch = _sync.fetch();
    final SyncRun? syncing = _syncing;
    await (syncing == null ? fetch.result : syncing(() => fetch.result));
  });

  Future<void> _fix(PushRowKey key, Future<void> Function() run) async {
    if (_busy) {
      return;
    }
    _fixing = key;
    _fixError = null;
    _notify();
    try {
      await run();
    } on Object catch (error) {
      // The sheet runs fix-its unawaited: every failure lands on the row, none escapes to the zone.
      final String text = error is ZanshinFfiException ? error.context ?? error.code : '$error';
      _log.warning('a push fix-it failed: ${error is ZanshinFfiException ? error.code : error.runtimeType}');
      _fixError = (key: key, text: text);
      return;
    } finally {
      _fixing = null;
      _notify();
    }
    if (!_disposed) {
      await _replan();
    }
  }

  // ---- the command ----

  /// The push the sheet would run.
  PushRequest get request {
    final Set<PushAllow> needed = <PushAllow>{
      for (final PushRowKey key in _rows)
        if (sent(key)) ...?rejectionOf(key)?.reasonKinds.map(PushAllow.of).nonNulls,
      if (_changeOn) ...?changeRejection?.reasonKinds.map(PushAllow.of).nonNulls,
    }.intersection(_allow);
    final PushChangeTarget? target = change;
    final bool withChange = _changeOn && target != null;
    return PushRequest(
      remotes: _remotesArg,
      mode: _mode,
      bookmarks: <String>[
        if (_mode == PushMode.custom)
          for (final PushRowKey key in _rows)
            if (key.kind == PushRefKind.bookmark && _custom.contains(key)) key.name,
      ],
      tags: <String>[
        if (_mode == PushMode.custom)
          for (final PushRowKey key in _rows)
            if (key.kind == PushRefKind.tag && _custom.contains(key)) key.name,
      ],
      changes: <String>[if (withChange && !named) target.rev],
      named: <String>[if (withChange && named) '${changeName.trim()}=${target.rev}'],
      allowEmptyDescription: needed.contains(PushAllow.emptyDescription),
      allowPrivate: needed.contains(PushAllow.private),
      allowConflicts: needed.contains(PushAllow.conflicts),
    );
  }

  /// Whether nothing would be sent.
  bool get empty => _chosen.isEmpty || (!_rows.any(sent) && !_changeOn);

  /// Whether the current command's dry run is still out.
  bool get checking => _phase == PushSheetPhase.ready && !empty && _checked != request.asDryRun;

  /// The current command's dry-run failure, jj's text; null when it passed or still runs.
  String? get checkError => _checked == request.asDryRun ? _checkError : null;

  /// The chosen remotes the current command sends nothing to, from its dry run (I4); empty with one remote.
  List<String> get emptyRemotes {
    final GitPushResult? result = _checked == request.asDryRun ? _checkResult : null;
    if (result == null || _chosen.length < 2) {
      return const <String>[];
    }
    final empty = <String>[
      for (final PushRemote remote in result.remotes)
        if (!remote.refs.any((ref) => ref.path == PushPath.push)) remote.name,
    ];
    // With nothing to push anywhere jj pushes nothing and fails nowhere.
    return empty.length == result.remotes.length ? const <String>[] : empty;
  }

  /// Whether Push may run: ready, something to send, and the command's dry run passed.
  bool get canPush => !_busy && !empty && _checked == request.asDryRun && _checkError == null;

  void _changed() {
    _recheck();
    _notify();
  }

  void _recheck() {
    if (_phase != PushSheetPhase.ready || empty) {
      return;
    }
    final PushRequest dry = request.asDryRun;
    if (dry == _checked) {
      return;
    }
    final int serial = ++_checkSerial;
    unawaited(() async {
      GitPushResult? result;
      String? error;
      try {
        result = await _sync.push(dry).result;
        final PushFailure? failure = result.failure;
        if (failure != null) {
          error = <String>[failure.message, ?failure.hint].join('\n');
        }
      } on ZanshinFfiException catch (e) {
        error = e.context ?? e.code;
      }
      if (serial != _checkSerial || _disposed) {
        return;
      }
      _checked = dry;
      _checkResult = result;
      _checkError = error;
      _notify();
    }());
  }

  // ---- push ----

  /// Runs the command. A full success finishes the sheet; a partial one shows [PushSheetPhase.done]; a refusal before
  /// the network keeps it ready with [pushError].
  Future<void> push() async {
    if (!canPush) {
      return;
    }
    final PushRequest run = request.asPush;
    _phase = PushSheetPhase.pushing;
    _progress = null;
    _pushError = null;
    _notify();
    final GitPushResult result;
    StreamSubscription<ProgressEvent>? progress;
    try {
      final NetworkOperation<GitPushResult> operation = _sync.push(run);
      progress = operation.progress.listen((event) {
        _progress = event.progress;
        _notify();
      });
      final SyncRun? syncing = _syncing;
      result = await (syncing == null ? operation.result : syncing(() => operation.result));
    } on ZanshinFfiException catch (error) {
      _log.warning('the push failed: ${error.code}');
      _pushError = error;
      _phase = PushSheetPhase.ready;
      _notify();
      return;
    } finally {
      unawaited(progress?.cancel());
    }
    if (result.failure == null) {
      _finish(result);
      return;
    }
    _result = result;
    _phase = PushSheetPhase.done;
    _notify();
  }

  /// Done: closes the sheet after a partial push and reports it.
  void done() {
    final GitPushResult? result = _result;
    if (_phase == PushSheetPhase.done && result != null) {
      _finish(result);
    }
  }

  void _finish(GitPushResult result) {
    onPushed(result);
    _closing = true;
    _notify();
  }

  /// Cancel and Esc: closes the sheet, except while the push runs.
  void cancel() {
    if (_phase == PushSheetPhase.pushing) {
      return;
    }
    if (_phase == PushSheetPhase.done) {
      done();
      return;
    }
    _closing = true;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
