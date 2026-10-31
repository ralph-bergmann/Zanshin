// SPDX-License-Identifier: MIT

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';

import '../l10n/zs_localizations.dart';

/// The package's strings (Story 11.16): the window root's [ZsLocalizations], or — for a control pumped without the
/// delegate (unit tests, the catalogue) — the instance for the platform's locales.
ZsLocalizations zsStrings(BuildContext context) =>
    ZsLocalizations.of(context) ??
    lookupZsLocalizations(
      basicLocaleListResolution(PlatformDispatcher.instance.locales, ZsLocalizations.supportedLocales),
    );
