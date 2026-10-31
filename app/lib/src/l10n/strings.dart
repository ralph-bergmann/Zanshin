// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/app_localizations.dart';

export '../../l10n/app_localizations.dart' show AppLocalizations;

/// The localization delegates every window's `MaterialApp` registers (Story 11.16): the app's and `zanshin_ui`'s
/// strings. Not `AppLocalizations.localizationsDelegates`, whose `GlobalMaterialLocalizations` is
/// `package:flutter/material`'s, not `material_ui`'s.
const zanshinLocalizationsDelegates = <LocalizationsDelegate<Object>>[
  AppLocalizations.delegate,
  ZsLocalizations.delegate,
];

/// The app's strings in a widget tree.
extension AppStrings on BuildContext {
  /// The window root's [AppLocalizations], or — for a widget pumped without the delegate (unit tests, the catalogue)
  /// — [platformStrings].
  AppLocalizations get l10n => AppLocalizations.of(this) ?? platformStrings();
}

/// The app's strings for the platform's locales, for text needed without a `BuildContext` (the splash, native window
/// titles). One instance per resolved locale, so painters that compare their strings see no change between builds.
AppLocalizations platformStrings() {
  final Locale locale = basicLocaleListResolution(
    PlatformDispatcher.instance.locales,
    AppLocalizations.supportedLocales,
  );
  return _platformStrings.putIfAbsent(locale, () => lookupAppLocalizations(locale));
}

final _platformStrings = <Locale, AppLocalizations>{};

/// Loads `intl`'s date data once, before the first `DateFormat` (Story 11.16): no window registers flutter's
/// `GlobalMaterialLocalizations`, which would load it.
void ensureDateFormatting() {
  if (!_dateFormattingLoaded) {
    _dateFormattingLoaded = true;
    // The data is in place when the call returns; its Future only reports that.
    unawaited(initializeDateFormatting());
  }
}

var _dateFormattingLoaded = false;

/// A placeholder value for [slotSpans]: pass `slot(i)` for the message's i-th styled placeholder.
String slot(int index) => String.fromCharCode(_slotBase + index);

const _slotBase = 0xE000;

/// [message], formatted with [slot]s for its styled placeholders, as spans: each `slot(i)` becomes `values[i]`, the
/// text around them a span in [style].
List<InlineSpan> slotSpans(String message, List<InlineSpan> values, {TextStyle? style}) {
  final spans = <InlineSpan>[];
  var start = 0;
  for (var i = 0; i < message.length; i++) {
    final int index = message.codeUnitAt(i) - _slotBase;
    if (index >= 0 && index < values.length) {
      if (i > start) {
        spans.add(TextSpan(text: message.substring(start, i), style: style));
      }
      spans.add(values[index]);
      start = i + 1;
    }
  }
  if (start < message.length) {
    spans.add(TextSpan(text: message.substring(start), style: style));
  }
  return spans;
}
