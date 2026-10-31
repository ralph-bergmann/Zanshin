// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
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
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

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

  /// Headline of the main window when the app's boot failed; the error text follows.
  ///
  /// In en, this message translates to:
  /// **'Zanshin could not start.'**
  String get bootFailed;

  /// Splash status line while the settings load.
  ///
  /// In en, this message translates to:
  /// **'Loading settings…'**
  String get bootLoadingSettings;

  /// Splash status line while the login shell's environment is read.
  ///
  /// In en, this message translates to:
  /// **'Reading the shell environment…'**
  String get bootReadingShell;

  /// Splash status line while the first window starts.
  ///
  /// In en, this message translates to:
  /// **'Starting Zanshin…'**
  String get bootStarting;

  /// Tagline under the logo on the splash card, in capitals.
  ///
  /// In en, this message translates to:
  /// **'JUJUTSU CLIENT'**
  String get splashTagline;

  /// The app's version line (splash footer, Projects sidebar).
  ///
  /// In en, this message translates to:
  /// **'{version} · Build {build}'**
  String versionBuild(String version, String build);

  /// The jj-lib version line in the Projects sidebar; jj-lib is the library's name.
  ///
  /// In en, this message translates to:
  /// **'jj-lib {version}'**
  String jjLibVersion(String version);

  /// Title of the Projects window (window title and header), and its sidebar navigation row.
  ///
  /// In en, this message translates to:
  /// **'Projects'**
  String get projectsTitle;

  /// Tooltip of the Settings… row in the Projects sidebar: Command-comma opens the tab shown last.
  ///
  /// In en, this message translates to:
  /// **'Settings — ⌘, (the tab shown last)'**
  String get projectsSettingsTooltip;

  /// Opens the Settings window (Projects sidebar row, Project menu item).
  ///
  /// In en, this message translates to:
  /// **'Settings…'**
  String get settingsEllipsis;

  /// Placeholder of the Projects window's search field.
  ///
  /// In en, this message translates to:
  /// **'Search projects, paths…'**
  String get projectsSearchPlaceholder;

  /// Button that adds a directory to the Projects list.
  ///
  /// In en, this message translates to:
  /// **'Add directory'**
  String get projectsAddDirectory;

  /// Confirm button of the folder picker opened by Add directory.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get projectsAddPrompt;

  /// Button that opens the clone form in the Projects window.
  ///
  /// In en, this message translates to:
  /// **'Clone…'**
  String get projectsClone;

  /// Button and name field that create a new group in the Projects list.
  ///
  /// In en, this message translates to:
  /// **'New group'**
  String get projectsNewGroup;

  /// Notice when an added folder does not exist.
  ///
  /// In en, this message translates to:
  /// **'{path} does not exist.'**
  String projectsPathMissing(String path);

  /// Notice title when converting a Git repository to jj failed.
  ///
  /// In en, this message translates to:
  /// **'Conversion failed'**
  String get projectsConversionFailed;

  /// Notice title when creating a jj repository failed.
  ///
  /// In en, this message translates to:
  /// **'Creating a repository failed'**
  String get projectsInitFailed;

  /// Notice title when a clone failed.
  ///
  /// In en, this message translates to:
  /// **'Clone failed'**
  String get projectsCloneFailed;

  /// Notice title when a project could not be opened.
  ///
  /// In en, this message translates to:
  /// **'Could not open {name}'**
  String projectsOpenFailed(String name);

  /// Notice title over the warnings of a conversion that succeeded.
  ///
  /// In en, this message translates to:
  /// **'Converted {name}'**
  String projectsConverted(String name);

  /// Notice title over the warnings of a repository creation that succeeded.
  ///
  /// In en, this message translates to:
  /// **'Created a repository in {name}'**
  String projectsCreated(String name);

  /// Notice title over the warnings of a clone that succeeded.
  ///
  /// In en, this message translates to:
  /// **'Cloned {name}'**
  String projectsCloned(String name);

  /// Notice title over the warnings of an open that succeeded.
  ///
  /// In en, this message translates to:
  /// **'Opened {name}'**
  String projectsOpened(String name);

  /// Confirmation title before a group is deleted.
  ///
  /// In en, this message translates to:
  /// **'Delete the group {name}?'**
  String deleteGroupTitle(String name);

  /// Row menu item and confirm button that delete a group.
  ///
  /// In en, this message translates to:
  /// **'Delete group'**
  String get deleteGroup;

  /// Confirmation body before a group is deleted.
  ///
  /// In en, this message translates to:
  /// **'Its projects and groups take its place; nothing leaves the list.'**
  String get deleteGroupBody;

  /// Confirmation title before a project is removed from the list.
  ///
  /// In en, this message translates to:
  /// **'Remove {name} from the list?'**
  String removeProjectTitle(String name);

  /// Confirm button that removes a project from the list.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get removeProjectConfirm;

  /// Confirmation body before a project is removed; the path is shown in monospace.
  ///
  /// In en, this message translates to:
  /// **'{path} stays on disk; only the list forgets it.'**
  String removeProjectBody(String path);

  /// Placeholder and name of the clone form's URL field.
  ///
  /// In en, this message translates to:
  /// **'Repository URL'**
  String get cloneUrl;

  /// Placeholder and name of the clone form's destination field.
  ///
  /// In en, this message translates to:
  /// **'Destination'**
  String get cloneDestination;

  /// Clone form button that picks the destination's parent folder.
  ///
  /// In en, this message translates to:
  /// **'Choose…'**
  String get cloneChoose;

  /// Confirm button of the folder picker for the clone destination.
  ///
  /// In en, this message translates to:
  /// **'Choose'**
  String get cloneChoosePrompt;

  /// Clone form button that closes the form.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cloneCancel;

  /// Clone form button that runs the clone, and its tooltip title.
  ///
  /// In en, this message translates to:
  /// **'Clone'**
  String get cloneSubmit;

  /// Offer to convert a Git repository; jj is the version control system's name.
  ///
  /// In en, this message translates to:
  /// **'Convert {name} to a jj repository?'**
  String convertTitle(String name);

  /// Confirm button of the convert offer.
  ///
  /// In en, this message translates to:
  /// **'Convert'**
  String get convertConfirm;

  /// Body of the convert offer; the path is shown in monospace.
  ///
  /// In en, this message translates to:
  /// **'{path} stays a Git repository; jj joins it and shares its working copy.'**
  String convertBody(String path);

  /// Body of the convert offer for a folder inside a Git repository; the paths are shown in monospace.
  ///
  /// In en, this message translates to:
  /// **'{inside} lies inside the Git repository at {path}. It stays a Git repository; jj joins it and shares its working copy.'**
  String convertBodyInside(String inside, String path);

  /// Offer to create a jj repository in a plain folder.
  ///
  /// In en, this message translates to:
  /// **'Create a jj repository in {name}?'**
  String initTitle(String name);

  /// Confirm button of the create offer.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get initConfirm;

  /// Body of the create offer; the path is shown in monospace, .jj is a folder name.
  ///
  /// In en, this message translates to:
  /// **'{path} becomes a jj repository, its Git store inside .jj.'**
  String initBody(String path);

  /// Offer to add the jj repository around a chosen folder.
  ///
  /// In en, this message translates to:
  /// **'Add the enclosing repository {name}?'**
  String enclosingTitle(String name);

  /// Confirm button of the enclosing-repository offer.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get enclosingConfirm;

  /// Body of the enclosing-repository offer; the paths are shown in monospace.
  ///
  /// In en, this message translates to:
  /// **'{inside} lies inside the jj repository at {path}.'**
  String enclosingBody(String inside, String path);

  /// Caption over the jj identity in the Projects sidebar footer (shown in capitals).
  ///
  /// In en, this message translates to:
  /// **'Identity'**
  String get identityCaption;

  /// Link that opens the identity settings.
  ///
  /// In en, this message translates to:
  /// **'Set identity…'**
  String get setIdentity;

  /// Button that dismisses the notice under the Projects header.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get noticeDismiss;

  /// Hint shown while a folder is dragged over the Projects window.
  ///
  /// In en, this message translates to:
  /// **'Drop to add directory'**
  String get dropToAddDirectory;

  /// VoiceOver name of the projects tree.
  ///
  /// In en, this message translates to:
  /// **'Projects'**
  String get treeLabel;

  /// The projects tree with no projects.
  ///
  /// In en, this message translates to:
  /// **'No projects yet. Add a directory or drop a folder here.'**
  String get treeEmpty;

  /// The projects tree when the search matches nothing.
  ///
  /// In en, this message translates to:
  /// **'No projects match “{query}”'**
  String treeNoResults(String query);

  /// Drag ghost while no valid drop place is under the pointer.
  ///
  /// In en, this message translates to:
  /// **'Drop between rows or on a group'**
  String get treeDropHint;

  /// Drag ghost for a drop at the top level of the list.
  ///
  /// In en, this message translates to:
  /// **'To the top level'**
  String get treeTopLevel;

  /// Drag ghost for a drop into a group.
  ///
  /// In en, this message translates to:
  /// **'Into {name}'**
  String treeInto(String name);

  /// Name of the field that renames a group.
  ///
  /// In en, this message translates to:
  /// **'Rename group'**
  String get renameGroup;

  /// Placeholder of the group name field.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get groupNamePlaceholder;

  /// A group row's count: its projects, then its own groups when it holds any.
  ///
  /// In en, this message translates to:
  /// **'{projects}{groups, plural, =0{} =1{ · 1 group} other{ · {groups} groups}}'**
  String groupCount(int projects, int groups);

  /// Marks the open project: a project row's VoiceOver value and its badge (shown in capitals).
  ///
  /// In en, this message translates to:
  /// **'open'**
  String get projectOpen;

  /// Project row menu item that opens the project.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get menuOpen;

  /// Project row menu item that shows the folder in Finder.
  ///
  /// In en, this message translates to:
  /// **'Reveal in Finder'**
  String get menuRevealInFinder;

  /// Project row menu item that removes the project from the list.
  ///
  /// In en, this message translates to:
  /// **'Remove from list'**
  String get menuRemoveFromList;

  /// Group row menu item that renames the group.
  ///
  /// In en, this message translates to:
  /// **'Rename…'**
  String get menuRename;

  /// Row menu submenu that moves the row into a group.
  ///
  /// In en, this message translates to:
  /// **'Move to group'**
  String get menuMoveToGroup;

  /// Move to group submenu item for the top level of the list.
  ///
  /// In en, this message translates to:
  /// **'Top level'**
  String get menuTopLevel;

  /// Move to group submenu item that moves the row into a new group.
  ///
  /// In en, this message translates to:
  /// **'New group…'**
  String get menuNewGroup;

  /// Tooltip of a row's menu button.
  ///
  /// In en, this message translates to:
  /// **'More…'**
  String get moreTooltip;

  /// VoiceOver name of a row's menu button.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get moreLabel;

  /// Project status: no uncommitted changes.
  ///
  /// In en, this message translates to:
  /// **'clean'**
  String get statusClean;

  /// Project status: the working copy has changes.
  ///
  /// In en, this message translates to:
  /// **'uncommitted changes'**
  String get statusDirty;

  /// Project status: the working copy has a conflict.
  ///
  /// In en, this message translates to:
  /// **'conflict'**
  String get statusConflict;

  /// Project status: the project's folder is gone.
  ///
  /// In en, this message translates to:
  /// **'path missing'**
  String get statusMissing;

  /// Project status: jj's working copy is stale.
  ///
  /// In en, this message translates to:
  /// **'working copy is stale'**
  String get statusStale;

  /// Project status: local commits not on the remote.
  ///
  /// In en, this message translates to:
  /// **'ahead of remote'**
  String get statusAhead;

  /// Project status: remote commits not fetched.
  ///
  /// In en, this message translates to:
  /// **'behind remote'**
  String get statusBehind;

  /// Project status: local and remote have both moved.
  ///
  /// In en, this message translates to:
  /// **'diverged'**
  String get statusDiverged;

  /// When a project was last opened: under a minute ago.
  ///
  /// In en, this message translates to:
  /// **'now'**
  String get lastOpenedNow;

  /// When a project was last opened: minutes ago, abbreviated.
  ///
  /// In en, this message translates to:
  /// **'{n}m ago'**
  String lastOpenedMinutes(int n);

  /// When a project was last opened: hours ago, abbreviated.
  ///
  /// In en, this message translates to:
  /// **'{n}h ago'**
  String lastOpenedHours(int n);

  /// When a project was last opened: the calendar day before.
  ///
  /// In en, this message translates to:
  /// **'yesterday'**
  String get lastOpenedYesterday;

  /// When a project was last opened: days ago, abbreviated.
  ///
  /// In en, this message translates to:
  /// **'{n}d ago'**
  String lastOpenedDays(int n);

  /// When a project was last opened: weeks ago, abbreviated.
  ///
  /// In en, this message translates to:
  /// **'{n}w ago'**
  String lastOpenedWeeks(int n);

  /// When a project was last opened: months ago, abbreviated.
  ///
  /// In en, this message translates to:
  /// **'{n}mo ago'**
  String lastOpenedMonths(int n);

  /// When a project was last opened: years ago, abbreviated.
  ///
  /// In en, this message translates to:
  /// **'{n}y ago'**
  String lastOpenedYears(int n);

  /// Project menu heading over the recent projects.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get capsuleRecent;

  /// Project menu item that opens the Projects window.
  ///
  /// In en, this message translates to:
  /// **'All Projects…'**
  String get capsuleAllProjects;

  /// Project menu item that opens the project's settings.
  ///
  /// In en, this message translates to:
  /// **'Project Settings…'**
  String get capsuleProjectSettings;

  /// VoiceOver name of the Project menu.
  ///
  /// In en, this message translates to:
  /// **'Project'**
  String get capsuleMenuLabel;

  /// VoiceOver name of the rail of panel buttons.
  ///
  /// In en, this message translates to:
  /// **'Panels'**
  String get railLabel;

  /// VoiceOver name of the top bar's view island.
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get topBarView;

  /// VoiceOver name of the pinned panel's resize edge.
  ///
  /// In en, this message translates to:
  /// **'Panel width'**
  String get panelWidth;

  /// Button that closes the pinned panel.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get panelClose;

  /// Caption when the commit graph failed to load; code is the error code.
  ///
  /// In en, this message translates to:
  /// **'The graph could not be loaded ({code}).'**
  String graphLoadFailed(String code);

  /// Button that loads the graph again.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get graphRetry;

  /// Caption when the graph's revset matches nothing; revset is jj's term.
  ///
  /// In en, this message translates to:
  /// **'No changes match this revset.'**
  String get graphEmpty;

  /// The stale-working-copy notice's sentence; stale is jj's term.
  ///
  /// In en, this message translates to:
  /// **'Working copy is stale'**
  String get staleTitle;

  /// Button that updates the stale working copy.
  ///
  /// In en, this message translates to:
  /// **'Update working copy'**
  String get staleUpdate;

  /// Button that copies the jj command to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy — {command}'**
  String staleCopy(String command);

  /// Day label for today.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get dayToday;

  /// Day label for yesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get dayYesterday;

  /// A card's commit time: under a minute ago.
  ///
  /// In en, this message translates to:
  /// **'now'**
  String get relativeNow;

  /// A card's commit time: minutes ago, abbreviated.
  ///
  /// In en, this message translates to:
  /// **'{n}m'**
  String relativeMinutes(int n);

  /// A card's commit time: hours ago, abbreviated.
  ///
  /// In en, this message translates to:
  /// **'{n}h'**
  String relativeHours(int n);

  /// A card's commit time: days ago, abbreviated.
  ///
  /// In en, this message translates to:
  /// **'{n}d'**
  String relativeDays(int n);

  /// A card's commit time as VoiceOver speaks it: minutes ago.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{1 minute ago} other{{n} minutes ago}}'**
  String spokenMinutesAgo(int n);

  /// A card's commit time as VoiceOver speaks it: hours ago.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{1 hour ago} other{{n} hours ago}}'**
  String spokenHoursAgo(int n);

  /// A card's commit time as VoiceOver speaks it: days ago.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{1 day ago} other{{n} days ago}}'**
  String spokenDaysAgo(int n);

  /// VoiceOver: the card is our workspace's working copy.
  ///
  /// In en, this message translates to:
  /// **'Working copy'**
  String get cardWorkingCopy;

  /// VoiceOver: the card is the working copy of our workspace, named.
  ///
  /// In en, this message translates to:
  /// **'Working copy of {name}'**
  String cardWorkingCopyOf(String name);

  /// VoiceOver: the card is the working copy of other workspaces (comma-separated names).
  ///
  /// In en, this message translates to:
  /// **'working copy of {names}'**
  String cardOtherWorkingCopy(String names);

  /// VoiceOver: the commit is immutable.
  ///
  /// In en, this message translates to:
  /// **'Immutable'**
  String get cardImmutable;

  /// VoiceOver: the commit has no description.
  ///
  /// In en, this message translates to:
  /// **'no description'**
  String get cardNoDescription;

  /// The commit changes no files (card flag and VoiceOver).
  ///
  /// In en, this message translates to:
  /// **'empty'**
  String get cardEmpty;

  /// VoiceOver: the commit has a conflict.
  ///
  /// In en, this message translates to:
  /// **'conflict'**
  String get cardConflict;

  /// VoiceOver: the commit is a merge.
  ///
  /// In en, this message translates to:
  /// **'merge'**
  String get cardMerge;

  /// VoiceOver: the commit is hidden.
  ///
  /// In en, this message translates to:
  /// **'hidden'**
  String get cardHidden;

  /// VoiceOver: the change is divergent.
  ///
  /// In en, this message translates to:
  /// **'divergent'**
  String get cardDivergent;

  /// VoiceOver custom action that opens a card's menu.
  ///
  /// In en, this message translates to:
  /// **'Actions'**
  String get cardActions;

  /// VoiceOver custom action that adds a bookmark to a card.
  ///
  /// In en, this message translates to:
  /// **'Add bookmark'**
  String get cardAddBookmark;

  /// VoiceOver custom action listing a card's bookmarks (comma-separated).
  ///
  /// In en, this message translates to:
  /// **'Bookmarks: {names}'**
  String cardBookmarks(String names);

  /// Tooltip over a card's ••• affordance.
  ///
  /// In en, this message translates to:
  /// **'Actions (or right-click the card)'**
  String get cardActionsTooltip;

  /// The eyebrow of an immutable change's hover card (shown in caps).
  ///
  /// In en, this message translates to:
  /// **'Immutable'**
  String get peekImmutable;

  /// The hover card's hint line on a mutable change; 'jj edit' is jj's command.
  ///
  /// In en, this message translates to:
  /// **'Click: details · Double-click: jj edit'**
  String get peekHintMutable;

  /// The hover card's hint line on an immutable change.
  ///
  /// In en, this message translates to:
  /// **'Click: details'**
  String get peekHintImmutable;

  /// The hover card's hint line on the working copy (@).
  ///
  /// In en, this message translates to:
  /// **'Working copy (@) · Click for details'**
  String get peekHintWorkingCopy;

  /// The @ pill's label: it scrolls to the working copy.
  ///
  /// In en, this message translates to:
  /// **'Working copy'**
  String get atPillLabel;

  /// Tooltip of the @ pill.
  ///
  /// In en, this message translates to:
  /// **'Scroll to the working copy'**
  String get atPillTooltip;

  /// VoiceOver label of the @ pill: where the working copy lies (up, down, left, right).
  ///
  /// In en, this message translates to:
  /// **'{direction, select, up{Working copy, above} down{Working copy, below} left{Working copy, left} other{Working copy, right}}'**
  String atPillSemantics(String direction);
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
