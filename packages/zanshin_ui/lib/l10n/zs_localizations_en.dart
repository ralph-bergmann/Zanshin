// ignore_for_file: deprecated_member_use

// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'zs_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class ZsLocalizationsEn extends ZsLocalizations {
  ZsLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get textMenuUndo => 'Undo';

  @override
  String get textMenuRedo => 'Redo';

  @override
  String get textMenuCut => 'Cut';

  @override
  String get textMenuCopy => 'Copy';

  @override
  String get textMenuPaste => 'Paste';

  @override
  String get textMenuSelectAll => 'Select all';

  @override
  String get searchPlaceholder => 'Search';

  @override
  String get searchClear => 'Clear';

  @override
  String chipRemove(String label) {
    return 'Remove $label';
  }

  @override
  String get confirmCancel => 'Cancel';

  @override
  String get selectCustom => 'Custom…';

  @override
  String get busyValue => 'busy';

  @override
  String get confirmShortcutHint => '⌘↩ confirms';

  @override
  String linkOpensInBrowser(String label) {
    return '$label, opens in browser';
  }

  @override
  String get progressIndeterminate => 'in progress';

  @override
  String get toastDismiss => 'Dismiss';

  @override
  String resizePoints(double number) {
    final intl.NumberFormat numberNumberFormat = intl.NumberFormat.decimalPattern(localeName);
    final String numberString = numberNumberFormat.format(number);

    return '$numberString points';
  }
}
