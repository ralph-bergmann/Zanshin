// SPDX-License-Identifier: MIT

import 'package:material_ui/material_ui.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';

/// The main window's content when the boot failed: a headline and the
/// selectable error text on the app's own background. No retry — ⌘Q quits as
/// usual.
///
/// Themed by the persisted [ThemeMode], which is [ThemeMode.system] when the
/// boot did not get as far as reading the settings. Like every window root it
/// sits on the token theme and `ZsRoot` — Multicolor, without a shell report,
/// since the boot never got that far (Claude's proposal, Story 11.1).
class BootFailure extends StatelessWidget {
  const BootFailure({required this.error, required this.mode, super.key});

  /// Whatever the boot threw; an `Error` as much as an `Exception`.
  final Object error;

  /// The persisted theme choice.
  final ThemeMode mode;

  @override
  Widget build(BuildContext context) => MaterialApp(
    localizationsDelegates: zanshinLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: ZsAppTheme.build(const ZsAppearance(theme: ZsTheme.paper)),
    darkTheme: ZsAppTheme.build(const ZsAppearance()),
    themeMode: mode,
    builder: (context, child) => ZsRoot(
      appearance: ZsAppearance(theme: ZsTheme.of(Theme.of(context).brightness)),
      child: child ?? const SizedBox.shrink(),
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                Text(context.l10n.bootFailed),
                SelectableText('$error'),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
