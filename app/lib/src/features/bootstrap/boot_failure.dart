// SPDX-License-Identifier: MIT

import 'package:material_ui/material_ui.dart';
import 'package:yaru/yaru.dart';

/// The main window's content when the boot failed: a headline and the
/// selectable error text on the app's own background. No retry — ⌘Q quits as
/// usual.
///
/// Themed by the persisted [ThemeMode], which is [ThemeMode.system] when the
/// boot did not get as far as reading the settings.
class BootFailure extends StatelessWidget {
  const BootFailure({required this.error, required this.mode, super.key});

  /// Whatever the boot threw; an `Error` as much as an `Exception`.
  final Object error;

  /// The persisted theme choice.
  final ThemeMode mode;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: yaruLight,
    darkTheme: yaruDark,
    themeMode: mode,
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              const Text('Zanshin could not start.'),
              SelectableText('$error'),
            ],
          ),
        ),
      ),
    ),
  );
}
