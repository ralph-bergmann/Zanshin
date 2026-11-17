// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// The installed fixed-pitch font families, which the runner lists over `zanshin/fonts`: Flutter uses
/// an installed font by name but cannot list them, and it falls back silently on a missing one.
@inject
@singleton
class InstalledCodeFonts extends ChangeNotifier {
  /// Reads the families from the runner.
  InstalledCodeFonts() : _read = _readFromRunner;

  /// Reads the families with [_read], for tests.
  @visibleForTesting
  InstalledCodeFonts.withReader(this._read);

  static const _channel = MethodChannel('zanshin/fonts');

  final Future<List<String>?> Function() _read;
  List<String>? _families;

  /// The families sorted case-insensitively; null while they are unknown (not read yet, or the runner failed).
  List<String>? get families => _families;

  /// Reads the families again; a failed read keeps what is known.
  Future<void> refresh() async {
    final List<String>? read;
    try {
      read = await _read();
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
    if (read == null) {
      return;
    }
    final List<String> sorted = [...read]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (listEquals(sorted, _families)) {
      return;
    }
    _families = sorted;
    notifyListeners();
  }

  static Future<List<String>?> _readFromRunner() => _channel.invokeListMethod<String>('monospacedFamilies');
}

/// The smallest and the largest code size drawn: a hand-edited settings file must not draw invisible or huge text.
const codeSizeMin = 6;

/// See [codeSizeMin].
const codeSizeMax = 72;

/// The code sizes Settings offers, in points (design `Inspector Extras Study.html` §5).
const codeSizeChoices = <int>[9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24];

/// Whether the saved code font [family] is known to be missing: [installed] was read and lacks it.
bool codeFontMissing(String? family, List<String>? installed) =>
    family != null && installed != null && !installed.contains(family);

/// The style of code (diffs and the config file editor) for the Settings [general] and the [installed] families:
/// [ZsType.code] in the saved family at the saved size. A missing family draws [ZsType.monoFamily]; while [installed]
/// is unknown the saved family is used as is.
TextStyle codeTextStyle(GeneralSettings general, List<String>? installed) {
  final String? saved = general.codeFont;
  return ZsType.code.copyWith(
    fontFamily: saved == null || codeFontMissing(saved, installed) ? ZsType.monoFamily : saved,
    fontFamilyFallback: const [ZsType.monoFamily, ZsType.sansFamily],
    fontSize: general.codeSize.clamp(codeSizeMin, codeSizeMax).toDouble(),
  );
}

/// Provides the code style to the code blocks below it; each window root installs one inside its zoom.
class CodeStyleScope extends InheritedWidget {
  /// Provides [style] to [child].
  const CodeStyleScope({required this.style, required super.child, super.key});

  /// The style of code.
  final TextStyle style;

  /// The nearest scope's style, or [ZsType.code] without a scope (tests, the catalogue).
  static TextStyle of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CodeStyleScope>()?.style ?? ZsType.code;

  @override
  bool updateShouldNotify(CodeStyleScope oldWidget) => style != oldWidget.style;
}
