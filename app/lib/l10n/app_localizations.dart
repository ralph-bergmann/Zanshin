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

  /// The top bar's count while the graph shows fewer than all changes; shown is the bold number of changes shown, total the number of all changes.
  ///
  /// In en, this message translates to:
  /// **'{shown} of {total}'**
  String graphCountFiltered(String shown, int total);

  /// The top bar's count while the graph shows every change (or before the total is known); number is the bold count.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{number} change} other{{number} changes}}'**
  String graphCountAll(int count, String number);

  /// Tooltip of the top bar's count: changes shown out of all changes.
  ///
  /// In en, this message translates to:
  /// **'{total, plural, =1{{shown} of 1 change shown} other{{shown} of {total} changes shown}}'**
  String graphCountTooltip(int shown, int total);

  /// The top bar's button (and its popover's VoiceOver name) with the graph's view options.
  ///
  /// In en, this message translates to:
  /// **'View options'**
  String get graphViewOptions;

  /// Heading of the View options popover (shown in caps).
  ///
  /// In en, this message translates to:
  /// **'Graph view'**
  String get graphViewTitle;

  /// View options row: the graph's layout mode.
  ///
  /// In en, this message translates to:
  /// **'Layout'**
  String get graphLayout;

  /// Layout segment: rows follow commit time.
  ///
  /// In en, this message translates to:
  /// **'Free'**
  String get graphLayoutFree;

  /// Tooltip of the Free layout segment.
  ///
  /// In en, this message translates to:
  /// **'Rows follow commit time'**
  String get graphLayoutFreeTooltip;

  /// Layout segment: rows are the dependency depth.
  ///
  /// In en, this message translates to:
  /// **'Compact'**
  String get graphLayoutCompact;

  /// Tooltip of the Compact layout segment.
  ///
  /// In en, this message translates to:
  /// **'Rows = dependency depth'**
  String get graphLayoutCompactTooltip;

  /// View options row: detailed (taller) commit cards.
  ///
  /// In en, this message translates to:
  /// **'Detailed cards'**
  String get graphDetailedCards;

  /// View options row: group linear runs of changes into stack cards.
  ///
  /// In en, this message translates to:
  /// **'Group stacks'**
  String get graphGroupStacks;

  /// Tooltip of the Group stacks row.
  ///
  /// In en, this message translates to:
  /// **'Collapse linear runs of changes into one stack card'**
  String get graphGroupStacksTooltip;

  /// A stack card's VoiceOver label: its member count, its newest member's subject and its change-id range (newest‥oldest).
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{1 change} other{{n} changes}}, {subject}, {range}'**
  String stackLabel(int n, String subject, String range);

  /// The hint at the bottom of a stack card's member list.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{Click to expand 1 change} other{Click to expand {n} changes}}'**
  String stackExpandHint(int n);

  /// Tooltip of the button on an expanded run's bracket that folds it back into a stack card.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{Collapse 1 change into a stack} other{Collapse {n} changes into a stack}}'**
  String stackCollapseTooltip(int n);

  /// View options row: the commit cards' width.
  ///
  /// In en, this message translates to:
  /// **'Card width'**
  String get graphCardWidth;

  /// Unit after the card width readout (pixels).
  ///
  /// In en, this message translates to:
  /// **'px'**
  String get graphCardWidthUnit;

  /// View options popover's last row: opens Settings on the General tab.
  ///
  /// In en, this message translates to:
  /// **'Appearance, diffs and more'**
  String get graphMoreSettings;

  /// VoiceOver name of the graph search field (a combobox).
  ///
  /// In en, this message translates to:
  /// **'Search the graph'**
  String get graphSearchLabel;

  /// VoiceOver name of the search field's pill and of its menu.
  ///
  /// In en, this message translates to:
  /// **'Search menu'**
  String get graphSearchMenu;

  /// VoiceOver name of the search field's suggestion list.
  ///
  /// In en, this message translates to:
  /// **'Suggestions'**
  String get graphSearchSuggestions;

  /// The graph search field's placeholder while it searches every scope.
  ///
  /// In en, this message translates to:
  /// **'Search changes, bookmarks, authors, files…'**
  String get graphSearchPlaceholder;

  /// The graph search field's placeholder in a narrow window.
  ///
  /// In en, this message translates to:
  /// **'Search…'**
  String get graphSearchPlaceholderShort;

  /// A search scope's label (pill, menu rows, more rows).
  ///
  /// In en, this message translates to:
  /// **'{scope, select, change{Change} bookmark{Bookmark} author{Author} file{File} description{Description} other{Any}}'**
  String graphSearchScope(String scope);

  /// A search scope in lower-case plural ("Recent changes", "Narrows the search to files").
  ///
  /// In en, this message translates to:
  /// **'{scope, select, change{changes} bookmark{bookmarks} author{authors} file{files} description{descriptions} other{results}}'**
  String graphSearchScopePlural(String scope);

  /// The heading of a suggestion group.
  ///
  /// In en, this message translates to:
  /// **'{scope, select, change{Changes} bookmark{Bookmarks} author{Authors} file{Files} description{Descriptions} other{Results}}'**
  String graphSearchScopeGroup(String scope);

  /// The search field's placeholder in a scope.
  ///
  /// In en, this message translates to:
  /// **'{scope, select, change{Change ID, commit ID or description} bookmark{Bookmark name} author{Author name} file{Path, folder or glob} description{Text in descriptions} other{Search changes, bookmarks, authors, files…}}'**
  String graphSearchScopePlaceholder(String scope);

  /// The search field's placeholder in a scope, in a narrow window.
  ///
  /// In en, this message translates to:
  /// **'{scope, select, change{Change ID or hash} bookmark{Bookmark name} author{Author name} file{Path or glob} description{Text} other{Search…}}'**
  String graphSearchScopePlaceholderShort(String scope);

  /// The menu's Change row: what it searches.
  ///
  /// In en, this message translates to:
  /// **'change ID · commit ID · description'**
  String get graphSearchChangeDetail;

  /// The menu's Bookmark row: what it searches.
  ///
  /// In en, this message translates to:
  /// **'name'**
  String get graphSearchBookmarkDetail;

  /// Tooltip of the search field's ✕: it shows the default search again; name is jj's command (jj log).
  ///
  /// In en, this message translates to:
  /// **'Back to the default search — {name}'**
  String graphSearchBackToDefault(String name);

  /// The search field's ✕ while it only holds a draft, and Recent's Clear action.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get graphSearchClear;

  /// Tag on the menu row of the default search.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get graphSearchDefaultTag;

  /// The menu's jj log row while revsets.log is jj's builtin.
  ///
  /// In en, this message translates to:
  /// **'Your mutable changes plus trunk context'**
  String get graphSearchLogDetail;

  /// The menu's all() row.
  ///
  /// In en, this message translates to:
  /// **'Every visible commit, incl. immutable history'**
  String get graphSearchAllDetail;

  /// Menu heading over the scopes that select a change.
  ///
  /// In en, this message translates to:
  /// **'Go to'**
  String get graphSearchGoTo;

  /// The note beside the Go to heading.
  ///
  /// In en, this message translates to:
  /// **'selects a change · graph stays'**
  String get graphSearchGoToHint;

  /// Menu heading over the scopes that redraw the graph.
  ///
  /// In en, this message translates to:
  /// **'Filter by'**
  String get graphSearchFilterBy;

  /// The note beside the Filter by heading.
  ///
  /// In en, this message translates to:
  /// **'redraws the graph'**
  String get graphSearchFilterByHint;

  /// The menu's last row: opens the jj log Configurations window.
  ///
  /// In en, this message translates to:
  /// **'Edit Configurations…'**
  String get graphSearchEditConfigurations;

  /// The menu's jj log row while the effective revsets.log fails; message is jj's.
  ///
  /// In en, this message translates to:
  /// **'Fails: {message}'**
  String graphSearchBroken(String message);

  /// Heading of the recent searches in Any.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get graphSearchRecent;

  /// Heading of the recent searches in a scope; scope is graphSearchScopePlural.
  ///
  /// In en, this message translates to:
  /// **'Recent {scope}'**
  String graphSearchRecentIn(String scope);

  /// A suggestion row that narrows the search to one scope.
  ///
  /// In en, this message translates to:
  /// **'{count} more in {scope}'**
  String graphSearchMore(int count, String scope);

  /// Note over matches found in other scopes; scope is lower-case singular.
  ///
  /// In en, this message translates to:
  /// **'No {scope} matches “{query}” — found elsewhere:'**
  String graphSearchFallback(String scope, String query);

  /// The suggestions' empty text in Any.
  ///
  /// In en, this message translates to:
  /// **'Nothing matches “{query}”.'**
  String graphSearchNothing(String query);

  /// The suggestions' empty text in a single scope.
  ///
  /// In en, this message translates to:
  /// **'Nothing matches “{query}” — in any scope.'**
  String graphSearchNothingAnywhere(String query);

  /// Tag on a suggestion whose change the graph does not show.
  ///
  /// In en, this message translates to:
  /// **'not in view'**
  String get graphSearchNotInView;

  /// Tag on the author row of the user (followed by jj's mine()).
  ///
  /// In en, this message translates to:
  /// **'you'**
  String get graphSearchYou;

  /// A suggestion row: filter by authors whose name contains the value (value is quoted).
  ///
  /// In en, this message translates to:
  /// **'Authors containing {value}'**
  String graphSearchAuthorsContaining(String value);

  /// A suggestion row: filter by descriptions containing the value (value is quoted).
  ///
  /// In en, this message translates to:
  /// **'Descriptions containing {value}'**
  String graphSearchDescriptionsContaining(String value);

  /// A typed value quoted in a message (curly quotes: messages only).
  ///
  /// In en, this message translates to:
  /// **'“{value}”'**
  String graphSearchQuoted(String value);

  /// A filter row's count; number is the formatted count.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 change} other{{number} changes}}'**
  String graphSearchCount(int count, String number);

  /// A filter row's count when it reached the cap.
  ///
  /// In en, this message translates to:
  /// **'{number}+ changes'**
  String graphSearchCountCapped(String number);

  /// Footer of a more row; scope is graphSearchScopePlural.
  ///
  /// In en, this message translates to:
  /// **'Narrows the search to {scope}'**
  String graphSearchNarrows(String scope);

  /// Footer of a go-to row whose change is shown.
  ///
  /// In en, this message translates to:
  /// **'Selects the change — the graph stays as it is'**
  String get graphSearchSelects;

  /// Footer of a go-to row whose change is not shown; all is jj's all().
  ///
  /// In en, this message translates to:
  /// **'Not in this view — switches to {all} and selects it'**
  String graphSearchSwitches(String all);

  /// Footer key label: Enter shows (a scope, or a change beyond the view).
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get graphSearchKeyShow;

  /// Footer key label: Enter selects the change.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get graphSearchKeySelect;

  /// Footer key label: Enter filters the graph.
  ///
  /// In en, this message translates to:
  /// **'Filter'**
  String get graphSearchKeyFilter;

  /// Tooltip of the search pill while a scope is typed in; scope is graphSearchScope.
  ///
  /// In en, this message translates to:
  /// **'Search in: {scope}'**
  String graphSearchSearchIn(String scope);

  /// Tooltip of the search pill while a variant shows; name is jj's.
  ///
  /// In en, this message translates to:
  /// **'Showing {name}'**
  String graphSearchShowing(String name);

  /// Tooltip of the search pill at the default search; name is jj's command.
  ///
  /// In en, this message translates to:
  /// **'Default search: {name}'**
  String graphSearchDefault(String name);

  /// The top bar's primary button: runs jj new on the working copy.
  ///
  /// In en, this message translates to:
  /// **'New change'**
  String get newChange;

  /// Tooltip of the New change button; 'jj new' is jj's command, @ the working copy.
  ///
  /// In en, this message translates to:
  /// **'jj new — start a new change on top of @'**
  String get newChangeTooltip;

  /// VoiceOver name of the inspector panel showing the selected change.
  ///
  /// In en, this message translates to:
  /// **'Change details'**
  String get inspectorLabel;

  /// VoiceOver name of the inspector's resize edge.
  ///
  /// In en, this message translates to:
  /// **'Inspector width'**
  String get inspectorWidth;

  /// The inspector's close button; Esc also closes it.
  ///
  /// In en, this message translates to:
  /// **'Close (Esc)'**
  String get inspectorClose;

  /// Inspector header flag: the change is the working copy (@ is jj's symbol).
  ///
  /// In en, this message translates to:
  /// **'@ Working copy'**
  String get inspectorFlagWorkingCopy;

  /// Inspector header flag (and its tooltip): the change is immutable.
  ///
  /// In en, this message translates to:
  /// **'Immutable'**
  String get inspectorFlagImmutable;

  /// Inspector header flag: the change changes no files.
  ///
  /// In en, this message translates to:
  /// **'Empty'**
  String get inspectorFlagEmpty;

  /// Inspector header flag: the change has two or more parents.
  ///
  /// In en, this message translates to:
  /// **'Merge'**
  String get inspectorFlagMerge;

  /// Inspector header flag: the change has a conflict.
  ///
  /// In en, this message translates to:
  /// **'Conflict'**
  String get inspectorFlagConflict;

  /// The title of an undescribed mutable change; a click opens the describe form.
  ///
  /// In en, this message translates to:
  /// **'Describe this change…'**
  String get inspectorDescribePlaceholder;

  /// The title of an undescribed immutable change.
  ///
  /// In en, this message translates to:
  /// **'(no description set)'**
  String get inspectorNoDescription;

  /// VoiceOver hint of the inspector's title on a mutable change: activating it opens the describe form.
  ///
  /// In en, this message translates to:
  /// **'Edit description'**
  String get inspectorDescribeHint;

  /// Describe form: the description's first line.
  ///
  /// In en, this message translates to:
  /// **'Summary'**
  String get inspectorSummary;

  /// Describe form: the rest of the description.
  ///
  /// In en, this message translates to:
  /// **'Details (optional)'**
  String get inspectorDetails;

  /// Describe form: closes the form, keeping the draft.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get inspectorCancel;

  /// Describe form: runs jj describe with the summary and details.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get inspectorSave;

  /// Inspector meta line: the word before the parents' short ids.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{parent} other{parents}}'**
  String inspectorParents(int count);

  /// Inspector action on an immutable change: jj new on it.
  ///
  /// In en, this message translates to:
  /// **'New change on top'**
  String get inspectorNewOnTop;

  /// Inspector action: jj edit, moving the working copy to the change.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get inspectorEdit;

  /// Inspector action: jj squash -r, folding the change into its parent.
  ///
  /// In en, this message translates to:
  /// **'Squash into parent'**
  String get inspectorSquash;

  /// Why Squash into parent is disabled when jj would run it: it ships with a later feature.
  ///
  /// In en, this message translates to:
  /// **'Comes with the commit composer'**
  String get inspectorSquashLater;

  /// Inspector action: jj abandon, with no confirmation.
  ///
  /// In en, this message translates to:
  /// **'Abandon'**
  String get inspectorAbandon;

  /// Why the inspector's actions are disabled while another jj action runs.
  ///
  /// In en, this message translates to:
  /// **'Another action is running'**
  String get inspectorBusy;

  /// Heading of the inspector's file list.
  ///
  /// In en, this message translates to:
  /// **'Changes'**
  String get inspectorChanges;

  /// The number of changed files beside the Changes heading.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 file} other{{count} files}}'**
  String inspectorFileCount(int count);

  /// File list of an empty working copy.
  ///
  /// In en, this message translates to:
  /// **'No changes yet — whatever you edit in your editor lands here.'**
  String get inspectorEmptyWorkingCopy;

  /// File list of a merge that changes nothing itself.
  ///
  /// In en, this message translates to:
  /// **'A merge — no changes of its own.'**
  String get inspectorEmptyMerge;

  /// File list of the root commit.
  ///
  /// In en, this message translates to:
  /// **'The root of all history.'**
  String get inspectorEmptyRoot;

  /// File list of any other empty change.
  ///
  /// In en, this message translates to:
  /// **'This change has no file changes.'**
  String get inspectorEmpty;

  /// Bookmark chip state: the local bookmark is not in sync with a remote.
  ///
  /// In en, this message translates to:
  /// **'local'**
  String get inspectorBookmarkLocal;

  /// Bookmark chip state: a remote-tracking bookmark.
  ///
  /// In en, this message translates to:
  /// **'remote'**
  String get inspectorBookmarkRemote;
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
