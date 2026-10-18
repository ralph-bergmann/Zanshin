// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp, Theme, ThemeMode;
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show AccentSource;
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import 'appearance_addon.dart';
import 'folders/controls.dart';
import 'folders/icons.dart';
import 'folders/materials.dart';
import 'folders/windows.dart';

final _log = Logger('zanshin.catalogue');

/// The catalogue's tree: Controls, Materials, Windows and Icons (no Graph folder yet; Story 11.11 deferred item 3).
final catalogueDirectories = <WidgetbookNode>[
  controlsFolder,
  materialsFolder,
  windowsFolder,
  iconsFolder,
];

/// Every use case's path (`controls/switch/state-matrix`: the names joined by `/`, spaces as `-`, lower case).
Set<String> get catalogueUseCasePaths => WidgetbookRoot(
  children: catalogueDirectories,
).leaves.whereType<WidgetbookUseCase>().map((useCase) => useCase.path).toSet();

/// The review catalogue's window content (decision 16.29): a strip of `--window-hd-h` the window is dragged by (the
/// traffic lights sit there) over Widgetbook 3.25.0, which shows the use cases at [initialRoute], and after each
/// [ZanshinCatalogueState.open] at the route given.
///
/// The live shell theme (`ZanshinShell.getTheme` / `onThemeChanged`) reaches every use case through [ZsShellScope]
/// and [catalogueAppBuilder].
class ZanshinCatalogue extends StatefulWidget {
  /// The catalogue, first at [initialRoute].
  const ZanshinCatalogue({this.initialRoute = '/', super.key});

  /// The route Widgetbook starts at (`/?path=controls/switch/state-matrix&appearance={theme:paper}`).
  final String initialRoute;

  @override
  State<ZanshinCatalogue> createState() => ZanshinCatalogueState();
}

/// The catalogue's state; [open] is what the Marionette extension `zanshinCatalogue.open` calls.
class ZanshinCatalogueState extends State<ZanshinCatalogue> {
  late String _route = widget.initialRoute;

  /// Counts the opens, so opening the route already shown starts afresh too (after a reviewer moved on in it).
  var _opened = 0;
  ShellTheme? _shell;
  StreamSubscription<ShellTheme>? _changes;

  /// The route Widgetbook was last opened at.
  String get route => _route;

  /// Shows [route] — a fresh Widgetbook, so its path and query groups are read again (Widgetbook 3 changes routes
  /// only through internal API).
  void open(String route) => setState(() {
    _route = route;
    _opened++;
  });

  @override
  void initState() {
    super.initState();
    _changes = ZanshinShell.onThemeChanged.listen(_apply);
    unawaited(
      ZanshinShell.getTheme().then(_apply).catchError((Object error, StackTrace stackTrace) {
        _log.warning('The shell theme could not be read for the catalogue', error, stackTrace);
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  void _apply(ShellTheme theme) {
    if (mounted && theme != _shell) {
      setState(() => _shell = theme);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ShellTheme? shell = _shell;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ZsShellScope(
        shellTheme: shell,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ZsRoot(
              appearance: _appearance(shell),
              child: Builder(
                builder: (context) => ZsWindowFill(
                  child: WindowDragArea(child: SizedBox(height: ZsMetrics.of(context).windowHdH)),
                ),
              ),
            ),
            Expanded(
              child: Widgetbook(
                key: ValueKey<(int, String)>((_opened, _route)),
                initialRoute: _route,
                directories: catalogueDirectories,
                addons: catalogueAddons(),
                appBuilder: catalogueAppBuilder,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The catalogue's addons: the Zanshin appearance first, then Widgetbook's own.
List<WidgetbookAddon> catalogueAddons() => <WidgetbookAddon>[
  AppearanceAddon(),
  TextScaleAddon(),
  InspectorAddon(),
  // GridAddon(),
  ZoomAddon(),
  AlignmentAddon(),
  // WHY: the semantics debugger is how a reviewer reads a control's VoiceOver tree in the catalogue; the addon is
  // marked experimental in Widgetbook 3.25.0 (story 11.11, decision 16.29).
  // ignore: experimental_member_use
  SemanticsAddon(),
  // WHY: slows every animation down, the review tool for the motion tokens; experimental in Widgetbook 3.25.0.
  // ignore: experimental_member_use
  TimeDilationAddon(),
];

/// What the app's windows show — the token theme for both modes, the shell's mode, the accent family following
/// macOS — around each use case ([child], which the addons wrap).
Widget catalogueAppBuilder(BuildContext context, Widget child) {
  final ShellTheme? shell = ZsShellScope.maybeOf(context);
  final ZsAppearance appearance = _appearance(shell);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ZsAppTheme.build(appearance.copyWith(theme: ZsTheme.paper)),
    darkTheme: ZsAppTheme.build(appearance.copyWith(theme: ZsTheme.night)),
    themeMode: switch (shell?.brightness) {
      null => ThemeMode.system,
      Brightness.dark => ThemeMode.dark,
      Brightness.light => ThemeMode.light,
    },
    builder: (context, home) => ZsRoot(
      appearance: appearance.copyWith(theme: ZsTheme.of(Theme.of(context).brightness)),
      shellTheme: shell,
      child: home ?? const SizedBox.shrink(),
    ),
    home: child,
  );
}

ZsAppearance _appearance(ShellTheme? shell) => ZsAppearance.fromShell(
  theme: shell?.brightness == Brightness.light ? ZsTheme.paper : ZsTheme.night,
  accentSource: AccentSource.followMacOS,
  shell: shell,
);
