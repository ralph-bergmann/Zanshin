// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import 'shell_controller.dart';
import 'shell_toast.dart';

/// The floating shell's settings side (Story 11.3): owns the [ShellController], seeded from the stored `layout`
/// widths and Settings › General's "Hide controls", follows "Hide controls" live, and writes the remembered widths
/// back.
///
/// A width is written once per committed change — a drag's release, a reset, a key step — through a trailing
/// debounce of [writeDelay], so a run of key steps writes once; a pending write is flushed in a microtask on dispose.
/// A narrow window never writes: only the remembered width the user set is stored, never the effective one.
@inject
class FloatingShellViewModel extends ChangeNotifier {
  /// A view model over [_settings].
  FloatingShellViewModel(this._settings) {
    final AppSettings settings = _settings.value;
    shell = ShellController(
      panelWidth: settings.layout.panelWidth,
      inspectorWidth: settings.layout.inspectorWidth,
      hideControls: settings.general.hideControls,
      onPanelWidthCommitted: (width) => _schedule(panel: width),
      onInspectorWidthCommitted: (width) => _schedule(inspector: width),
    );
    _settings.addListener(_settingsChanged);
  }

  /// The trailing debounce of a width write (Claude's proposal).
  static const writeDelay = Duration(milliseconds: 400);

  final SettingsStore _settings;

  /// The shell's controller.
  late final ShellController shell;

  /// The window's toast queue (Story 10.23).
  final toasts = ShellToasts();

  Timer? _write;
  double? _panel;
  double? _inspector;

  void _settingsChanged() => shell.hideControls = _settings.value.general.hideControls;

  void _schedule({double? panel, double? inspector}) {
    _panel = panel ?? _panel;
    _inspector = inspector ?? _inspector;
    _write?.cancel();
    _write = Timer(writeDelay, _flush);
  }

  void _flush() {
    _write?.cancel();
    _write = null;
    final double? panel = _panel;
    final double? inspector = _inspector;
    _panel = null;
    _inspector = null;
    if (panel == null && inspector == null) {
      return;
    }
    unawaited(
      _settings
          .update(
            (s) => s.copyWith.layout(
              panelWidth: panel ?? s.layout.panelWidth,
              inspectorWidth: inspector ?? s.layout.inspectorWidth,
            ),
          )
          // The store logs a failed write; the width stays in memory for this session.
          .onError<FileSystemException>((_, _) {}),
    );
  }

  @override
  void dispose() {
    // A microtask, not now: the view model goes while its widget tree unmounts, and the store's listeners (the app's
    // view model) must not rebuild while the tree is locked.
    _write?.cancel();
    scheduleMicrotask(_flush);
    _settings.removeListener(_settingsChanged);
    shell.dispose();
    toasts.dispose();
    super.dispose();
  }
}
