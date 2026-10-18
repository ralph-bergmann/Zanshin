// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import 'boot_failure.dart';

/// The app's version and build number, as the splash's footer shows them.
typedef SplashVersion = ({String version, String build});

/// How long a boot may take before the splash window appears at all.
const splashIndicatorDelay = Duration(milliseconds: 250);

/// Once shown, the splash stays at least this long. Well past the point where
/// it would only blink: it is held long enough to be looked at while the card
/// is being worked on.
const splashIndicatorMinShow = Duration(seconds: 3);

/// Fade-out of the splash window once the main window is up.
const splashFadeOut = Duration(milliseconds: 200);

final _log = Logger('zanshin.bootstrap');

/// The kind of window the boot opens first (Story 11.12 item 7).
enum BootWindowKind {
  /// The project window (`BootWindowHost.openMain`), also for the failure page.
  project,

  /// The Projects window (`BootWindowHost.openProjects`): nothing to reopen.
  projects,
}

/// What `ZanshinBootSequence.startApp` hands the boot: the first window's [content] in a window of [kind], and
/// [onShown], which the sequence runs once that window is up and a splash, if there was one, is gone.
@immutable
class BootFirstWindow {
  /// The first window showing [content].
  const BootFirstWindow({required this.content, this.kind = BootWindowKind.project, this.onShown});

  /// The window's content, built before `runWidget` with its DI root in place.
  final Widget content;

  /// Which window shows [content].
  final BootWindowKind kind;

  /// Runs after the window was presented; null for nothing.
  final Future<void> Function()? onShown;
}

/// The windows [ZanshinBootSequence] drives.
///
/// Deliberately free of any windowing type: the real implementation is the
/// only place that touches `runWidget` and the macOS window controllers, which
/// a widget test cannot reach, so the sequencing is tested against a fake.
abstract interface class BootWindowHost {
  /// Shows the splash window, whose card follows [status] and [version] for as
  /// long as it is up. Called at most once, and only for a boot that outlasts
  /// [splashIndicatorDelay].
  Future<void> openSplash({
    required ValueListenable<String> status,
    required ValueListenable<SplashVersion?> version,
  });

  /// Opens the app's main window showing [content].
  Future<void> openMain(Widget content);

  /// Opens the Projects window showing [content], the first window when no project can open (Story 11.12 item 7).
  Future<void> openProjects(Widget content);

  /// Fades the splash out over [fade] and destroys it. Called only after
  /// [openSplash], and only once.
  Future<void> dismissSplash(Duration fade);
}

/// Runs the asynchronous boot and opens the app's windows around it.
///
/// The boot (`openSettings` alongside `adoptShellEnvironment` and `loadIcons` → `startApp`)
/// starts before any window exists and races [splashIndicatorDelay]:
///
/// * the boot wins — the first app window is the first and only window, no
///   splash object is ever created;
/// * the timer wins — the splash window comes up and the first app window
///   follows at `max(boot end, delay + `[splashIndicatorMinShow]`)`, after which
///   the splash fades out.
///
/// The first app window is what `startApp` decided ([BootFirstWindow]): the
/// project window, or the Projects window when nothing can reopen; a failed
/// boot shows the failure page in the project window. Once it is up (and the
/// splash gone) its `onShown` runs.
///
/// Waiting out the minimum with the *window* is what the single-window splash
/// used to do with opacity: back then the finished app was already mounted
/// behind an opaque splash, now it would pop up around a 560×320 card.
///
/// Timing is driven by [Timer]s alone, never by reading a clock, so the fake
/// time of a widget test controls it fully.
class ZanshinBootSequence {
  ZanshinBootSequence({
    required this.host,
    required this.openSettings,
    required this.adoptShellEnvironment,
    required this.loadIcons,
    required this.startApp,
  });

  /// The window layer this sequence drives.
  final BootWindowHost host;

  /// First boot step: the persisted settings, needed by the DI graph and by
  /// the failure page's theme.
  final Future<SettingsStore> Function() openSettings;

  /// Runs alongside [openSettings]: adopts the login shell's environment, so
  /// that no repo is ever opened without it (Story 9.36). [startApp] waits for
  /// it; a throw fails the boot like a settings failure.
  final Future<void> Function() adoptShellEnvironment;

  /// Runs alongside [openSettings]: decodes every icon once (decision 16.32),
  /// so no icon pops in a frame late. [startApp] waits for it; a throw fails
  /// the boot like a settings failure.
  final Future<IconRegistry> Function() loadIcons;

  /// Second boot step: builds the DI graph over the loaded settings and icons,
  /// starts the worker and returns the first window.
  final Future<BootFirstWindow> Function(SettingsStore settings, IconRegistry icons) startApp;

  final _done = Completer<void>();

  /// What the boot is doing right now, for the splash's status line. Never
  /// disposed: the sequence outlives every splash it feeds.
  final _status = ValueNotifier<String>('');

  /// The app's version and build for the splash's footer; null until read.
  final _version = ValueNotifier<SplashVersion?>(null);

  Timer? _delayTimer;

  /// The native splash window while it is coming up; awaited before the main
  /// window opens so the two can never cross. Already complete while there is
  /// no splash.
  var _splashOpening = Future<void>.value();

  /// Persisted theme choice; `system` until [openSettings] answered — which
  /// follows the platform brightness either way.
  ThemeMode _persistedMode = ThemeMode.system;

  /// The first window of the finished app, or the failure page. Set before
  /// [_bootFinished], which gates every read.
  late BootFirstWindow _first;

  var _splashShown = false;
  var _minShowElapsed = false;
  var _bootFinished = false;
  var _mainOpened = false;

  /// What the boot is doing right now; the splash's status line.
  ValueListenable<String> get status => _status;

  /// The app's version and build, or null while they are unknown.
  ValueListenable<SplashVersion?> get version => _version;

  /// Records a boot step: to the log, and to the splash's status line.
  void log(String message) {
    _log.info(message);
    _status.value = message;
  }

  /// Starts the boot; completes once the first app window is up and a splash,
  /// if there was one, is gone (the window's `onShown` may still run).
  Future<void> run() {
    _delayTimer = Timer(splashIndicatorDelay, _showSplash);
    unawaited(_boot());
    return _done.future;
  }

  Future<void> _boot() async {
    BootFirstWindow first;
    try {
      first = await _load();
    } catch (error, stackTrace) {
      // Process-level boundary: a failed boot may surface as an Error (FFI,
      // isolate spawn), so this deliberately catches everything.
      _log.severe('App boot failed', error, stackTrace);
      first = BootFirstWindow(
        content: BootFailure(error: error, mode: _persistedMode),
      );
    }
    _first = first;
    _bootFinished = true;
    _openMainWhenDue();
  }

  /// The boot steps; the persisted mode is known before the app starts, in
  /// time for a failure in the last one. The login shell's environment is read
  /// and the icons are decoded while the settings load, so their time is
  /// hidden behind theirs.
  ///
  /// The status lines are English (decision 16.9); the wording is Claude's
  /// proposal (Story 11.1).
  Future<BootFirstWindow> _load() async {
    log('Loading settings…');
    var shellPending = true;
    // `ignore` only keeps an early failure from counting as unhandled while
    // the settings load: the awaits below still throw it.
    final Future<void> shellEnvironment = adoptShellEnvironment().whenComplete(() => shellPending = false)..ignore();
    final Future<IconRegistry> icons = loadIcons()..ignore();
    final SettingsStore settings = await openSettings();
    _persistedMode = settings.value.appearance.themeMode;
    if (shellPending) {
      log('Reading the shell environment…');
    }
    await shellEnvironment;
    final IconRegistry registry = await icons;
    log('Starting Zanshin…');
    return startApp(settings, registry);
  }

  /// [splashIndicatorDelay] elapsed and the boot is still running.
  void _showSplash() {
    _splashShown = true;
    // Never cancelled: once the splash is up it is this timer that releases
    // the main window.
    Timer(splashIndicatorMinShow, _onMinShowElapsed);
    unawaited(_readVersion());
    _splashOpening = host.openSplash(status: status, version: version);
  }

  /// The splash's version line, read only once a splash is actually coming up.
  /// Guarded: without the platform channel (a widget test) the footer just
  /// stays empty, and the boot goes on.
  Future<void> _readVersion() async {
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      _version.value = (version: info.version, build: info.buildNumber);
    } catch (error, stackTrace) {
      _log.warning('The app version could not be read', error, stackTrace);
    }
  }

  void _onMinShowElapsed() {
    _minShowElapsed = true;
    _openMainWhenDue();
  }

  /// Opens the first app window once the boot is done *and* a shown splash has
  /// had its minimum. Called from both ends of that race; the later one wins.
  void _openMainWhenDue() {
    if (!_bootFinished || _mainOpened || (_splashShown && !_minShowElapsed)) {
      return;
    }
    _mainOpened = true;
    _delayTimer?.cancel();
    unawaited(_openMain());
  }

  Future<void> _openMain() async {
    try {
      await _splashOpening;
      final BootFirstWindow first = _first;
      switch (first.kind) {
        case BootWindowKind.project:
          await host.openMain(first.content);
        case BootWindowKind.projects:
          await host.openProjects(first.content);
      }
      if (_splashShown) {
        // The cross-fade is opacity, so it keeps its duration under Reduce
        // motion too (decision 16.4).
        await host.dismissSplash(splashFadeOut);
      }
      final Future<void> Function()? onShown = first.onShown;
      if (onShown != null) {
        unawaited(_runOnShown(onShown));
      }
    } catch (error, stackTrace) {
      // Same blanket catch as _boot, and for a harder reason: `main` awaits
      // [run], and AppKit no longer quits on the last closed window, so a host
      // that threw would leave the process alive with no window and no way out.
      _log.severe('Opening the app window failed', error, stackTrace);
    } finally {
      if (!_done.isCompleted) {
        _done.complete();
      }
    }
  }

  /// Runs the first window's [onShown] apart from [run], which completes once the window is up; its failure is
  /// logged, the window stays.
  Future<void> _runOnShown(Future<void> Function() onShown) async {
    try {
      await onShown();
    } catch (error, stackTrace) {
      _log.severe('Following up the first window failed', error, stackTrace);
    }
  }
}
