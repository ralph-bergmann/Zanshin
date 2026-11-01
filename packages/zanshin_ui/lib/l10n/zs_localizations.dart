// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'zs_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of ZsLocalizations
/// returned by `ZsLocalizations.of(context)`.
///
/// Applications need to include `ZsLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/zs_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: ZsLocalizations.localizationsDelegates,
///   supportedLocales: ZsLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the ZsLocalizations.supportedLocales
/// property.
abstract class ZsLocalizations {
  ZsLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static ZsLocalizations? of(BuildContext context) {
    return Localizations.of<ZsLocalizations>(context, ZsLocalizations);
  }

  static const LocalizationsDelegate<ZsLocalizations> delegate = _ZsLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// Text-field context menu item that undoes the last edit.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get textMenuUndo;

  /// Text-field context menu item that redoes the last undone edit.
  ///
  /// In en, this message translates to:
  /// **'Redo'**
  String get textMenuRedo;

  /// Text-field context menu item that cuts the selection.
  ///
  /// In en, this message translates to:
  /// **'Cut'**
  String get textMenuCut;

  /// Text-field context menu item that copies the selection.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get textMenuCopy;

  /// Text-field context menu item that pastes the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get textMenuPaste;

  /// Text-field context menu item that selects the whole text.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get textMenuSelectAll;

  /// Default placeholder and accessible name of a search field.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get searchPlaceholder;

  /// VoiceOver label of the search field's clear (x) button.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get searchClear;

  /// VoiceOver label of a chip's remove button.
  ///
  /// In en, this message translates to:
  /// **'Remove {label}'**
  String chipRemove(String label);

  /// Default label of a confirmation dialog's cancel button.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get confirmCancel;

  /// Default label of a select's entry for a custom value.
  ///
  /// In en, this message translates to:
  /// **'Custom…'**
  String get selectCustom;

  /// VoiceOver value of a control or spinner while it is busy.
  ///
  /// In en, this message translates to:
  /// **'busy'**
  String get busyValue;

  /// Footer hint of a destructive confirmation dialog: Command-Return confirms.
  ///
  /// In en, this message translates to:
  /// **'⌘↩ confirms'**
  String get confirmShortcutHint;

  /// VoiceOver label of a link that opens an external page.
  ///
  /// In en, this message translates to:
  /// **'{label}, opens in browser'**
  String linkOpensInBrowser(String label);

  /// VoiceOver value of a progress bar without a known fraction.
  ///
  /// In en, this message translates to:
  /// **'in progress'**
  String get progressIndeterminate;

  /// VoiceOver label of a toast's close (x) button.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get toastDismiss;

  /// VoiceOver value of a panel resize edge: the panel width in points.
  ///
  /// In en, this message translates to:
  /// **'{number} points'**
  String resizePoints(double number);
}

class _ZsLocalizationsDelegate extends LocalizationsDelegate<ZsLocalizations> {
  const _ZsLocalizationsDelegate();

  @override
  Future<ZsLocalizations> load(Locale locale) {
    return SynchronousFuture<ZsLocalizations>(lookupZsLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_ZsLocalizationsDelegate old) => false;
}

ZsLocalizations lookupZsLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return ZsLocalizationsEn();
  }

  throw FlutterError(
    'ZsLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
