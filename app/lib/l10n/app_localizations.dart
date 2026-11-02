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

  /// Tooltip of the top bar's Reload button (the View menu's Reload, its shortcut): reads the project and the graph again.
  ///
  /// In en, this message translates to:
  /// **'Reload (⌘R)'**
  String get graphReloadTooltip;

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

  /// VoiceOver label of the minimap: the whole graph in miniature beside the graph, with the visible part marked.
  ///
  /// In en, this message translates to:
  /// **'Minimap'**
  String get graphMinimap;

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

  /// The hover card's eyebrow once the reason is known: the caps label, then jj's revset term verbatim.
  ///
  /// In en, this message translates to:
  /// **'{label} · {reason}'**
  String peekImmutableReason(String label, String reason);

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

  /// Label beside an end stub under a card whose parent is outside the revset; shown after a tilde ("~ elided"), as jj's log says.
  ///
  /// In en, this message translates to:
  /// **'elided'**
  String get gapElided;

  /// Title of the gap callout on a dashed edge: the revset skips commits between the two changes.
  ///
  /// In en, this message translates to:
  /// **'Commits hidden between these changes'**
  String get gapTitleIndirect;

  /// Title of the gap callout when the change's only parent is hidden and is itself a merge.
  ///
  /// In en, this message translates to:
  /// **'A hidden merge sits below this change'**
  String get gapTitleHiddenMerge;

  /// Title of the gap callout on an end stub: a parent has no ancestor in the revset.
  ///
  /// In en, this message translates to:
  /// **'History continues outside this revset'**
  String get gapTitleMissing;

  /// Gap callout, the middle line of the chain on a dashed edge.
  ///
  /// In en, this message translates to:
  /// **'Hidden commits'**
  String get gapHiddenCommits;

  /// Gap callout, the middle line of the chain on an end stub.
  ///
  /// In en, this message translates to:
  /// **'Older history not shown'**
  String get gapOlderHistory;

  /// Gap callout: beside the id of a parent the revset does not include.
  ///
  /// In en, this message translates to:
  /// **'parent, not in revset'**
  String get gapParentNotInRevset;

  /// Gap callout description on a dashed edge.
  ///
  /// In en, this message translates to:
  /// **'The dashed edge skips commits the revset doesn\'t include and links to the nearest visible ancestor.'**
  String get gapDescIndirect;

  /// Gap callout description on a hidden merge.
  ///
  /// In en, this message translates to:
  /// **'The only parent is hidden and is itself a merge, so the gap leads to two visible ancestors.'**
  String get gapDescHiddenMerge;

  /// Gap callout description on an end stub.
  ///
  /// In en, this message translates to:
  /// **'No ancestor reached through this parent is part of the current revset.'**
  String get gapDescMissing;

  /// Gap callout button: switches the graph to the revset and centres on the gap's hidden commits.
  ///
  /// In en, this message translates to:
  /// **'Show in {revset}'**
  String gapShowIn(String revset);

  /// Hint beside the gap callout's button.
  ///
  /// In en, this message translates to:
  /// **'switches revset · centers here'**
  String get gapShowInHint;

  /// The top bar's gap legend chip: how many gaps the revset leaves in the history.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{1 gap} other{{n} gaps}}'**
  String gapCount(int n);

  /// Title of the gap legend popover.
  ///
  /// In en, this message translates to:
  /// **'This revset hides part of the history'**
  String get gapLegendTitle;

  /// Gap legend row name: a solid edge.
  ///
  /// In en, this message translates to:
  /// **'Solid'**
  String get gapLegendSolid;

  /// Gap legend: what a solid edge means.
  ///
  /// In en, this message translates to:
  /// **'direct parent'**
  String get gapLegendSolidText;

  /// Gap legend row name: a dashed edge.
  ///
  /// In en, this message translates to:
  /// **'Dashed'**
  String get gapLegendDashed;

  /// Gap legend: what a dashed edge means.
  ///
  /// In en, this message translates to:
  /// **'commits in between are hidden'**
  String get gapLegendDashedText;

  /// Gap legend row name: an end stub.
  ///
  /// In en, this message translates to:
  /// **'End'**
  String get gapLegendEnd;

  /// Gap legend: what an end stub means.
  ///
  /// In en, this message translates to:
  /// **'older history isn\'t in the revset'**
  String get gapLegendEndText;

  /// Gap legend: how many times a kind occurs.
  ///
  /// In en, this message translates to:
  /// **'{n}×'**
  String gapLegendTimes(int n);

  /// Gap legend's closing line.
  ///
  /// In en, this message translates to:
  /// **'Stacks never span a gap. Hover a marker for details.'**
  String get gapLegendNote;

  /// Gap legend button: switches the graph to the revset.
  ///
  /// In en, this message translates to:
  /// **'Show {revset}'**
  String gapLegendShow(String revset);

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

  /// Tooltip over an inspector id (change, commit or parent); the full id shows below it.
  ///
  /// In en, this message translates to:
  /// **'Click to copy'**
  String get inspectorCopyId;

  /// Shown briefly after a click copied an inspector id to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get inspectorIdCopied;

  /// Accessibility hint of an inspector id: activating it copies the full id.
  ///
  /// In en, this message translates to:
  /// **'Copies the full id'**
  String get inspectorCopyIdHint;

  /// Announced to assistive tech when the clipboard write failed and a popover shows the id as selectable text.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t copy. Select the id to copy it.'**
  String get inspectorIdCopyFailed;

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

  /// The Immutable flag's tooltip once the reason is known; the reason is jj's revset term, verbatim.
  ///
  /// In en, this message translates to:
  /// **'Immutable · {reason}'**
  String inspectorFlagImmutableReason(String reason);

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

  /// The describe form in squash mode: runs jj squash with the combined description as edited.
  ///
  /// In en, this message translates to:
  /// **'Squash'**
  String get inspectorSquashConfirm;

  /// The Changes header's checkbox: checks every file for the composer.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get inspectorSelectAll;

  /// The Changes header's checkbox while every file is checked: unchecks them all.
  ///
  /// In en, this message translates to:
  /// **'Deselect all'**
  String get inspectorDeselectAll;

  /// Composer on the working copy: runs jj commit with the checked files.
  ///
  /// In en, this message translates to:
  /// **'Commit'**
  String get inspectorCommit;

  /// Composer on another change: runs jj split with the checked files.
  ///
  /// In en, this message translates to:
  /// **'Split'**
  String get inspectorSplit;

  /// Composer on the working copy: the placeholder of the new commit's first line.
  ///
  /// In en, this message translates to:
  /// **'Summary of what you did'**
  String get inspectorComposerSummaryAt;

  /// Composer on another change: the placeholder of the selected part's first line.
  ///
  /// In en, this message translates to:
  /// **'Summary of the selected changes'**
  String get inspectorComposerSummarySplit;

  /// Composer result preview on the working copy: the new @ that keeps the unchecked files.
  ///
  /// In en, this message translates to:
  /// **'New working copy'**
  String get inspectorComposerNewWorkingCopy;

  /// Composer result preview: what the new working copy is for.
  ///
  /// In en, this message translates to:
  /// **'stays here to keep working'**
  String get inspectorComposerStays;

  /// Composer result preview on another change: the part that keeps the unchecked files.
  ///
  /// In en, this message translates to:
  /// **'Rest'**
  String get inspectorComposerRest;

  /// Composer result preview: the rest keeps the change's description.
  ///
  /// In en, this message translates to:
  /// **'keeps “{subject}”'**
  String inspectorComposerKeeps(String subject);

  /// Composer result preview: the part with the checked files.
  ///
  /// In en, this message translates to:
  /// **'Selected'**
  String get inspectorComposerSelected;

  /// Composer result preview: a part without files.
  ///
  /// In en, this message translates to:
  /// **'empty'**
  String get inspectorComposerEmpty;

  /// Composer result preview: no file is checked.
  ///
  /// In en, this message translates to:
  /// **'nothing yet'**
  String get inspectorComposerNothingYet;

  /// Composer result preview: the summary field is empty.
  ///
  /// In en, this message translates to:
  /// **'no description yet'**
  String get inspectorComposerNoDescription;

  /// Composer result preview: the selected part's summary, quoted.
  ///
  /// In en, this message translates to:
  /// **'“{summary}”'**
  String inspectorComposerMessage(String summary);

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

  /// Changes header: how many of the listed files are marked Viewed.
  ///
  /// In en, this message translates to:
  /// **'{viewed}/{total} viewed'**
  String inspectorViewedCount(int viewed, int total);

  /// Tooltip of the Changes header's viewed counter.
  ///
  /// In en, this message translates to:
  /// **'{viewed} of {total} files viewed'**
  String inspectorViewedCountTooltip(int viewed, int total);

  /// Changes header when every listed file is marked Viewed (after a check mark).
  ///
  /// In en, this message translates to:
  /// **'all viewed'**
  String get inspectorAllViewed;

  /// Changes header button: mark every listed file Viewed.
  ///
  /// In en, this message translates to:
  /// **'Mark all'**
  String get inspectorMarkAllViewed;

  /// Changes header button: clear every listed file's Viewed mark.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get inspectorResetViewed;

  /// The diff block's review toggle.
  ///
  /// In en, this message translates to:
  /// **'Viewed'**
  String get inspectorViewed;

  /// Tooltip of the Viewed toggle while the file is not viewed.
  ///
  /// In en, this message translates to:
  /// **'Mark as viewed'**
  String get inspectorMarkViewed;

  /// Tooltip of the Viewed toggle while the file is viewed.
  ///
  /// In en, this message translates to:
  /// **'Mark as not viewed'**
  String get inspectorMarkNotViewed;

  /// The folded diff of a viewed file; a click unfolds it and clears Viewed.
  ///
  /// In en, this message translates to:
  /// **'Viewed — diff folded away. Click to show it again.'**
  String get inspectorViewedFolded;

  /// Accessible name of the diff's layout toggle.
  ///
  /// In en, this message translates to:
  /// **'Diff layout'**
  String get inspectorDiffLayout;

  /// Diff layout: one column.
  ///
  /// In en, this message translates to:
  /// **'Unified'**
  String get inspectorDiffUnified;

  /// Diff layout: the left side beside the right.
  ///
  /// In en, this message translates to:
  /// **'Side by side'**
  String get inspectorDiffSideBySide;

  /// The diff of a binary file, which has no lines.
  ///
  /// In en, this message translates to:
  /// **'Binary file'**
  String get inspectorDiffBinary;

  /// The diff of a file whose only change is its executable bit.
  ///
  /// In en, this message translates to:
  /// **'Executable bit changed'**
  String get inspectorDiffModeChange;

  /// The diff of a file with no hunks otherwise (a pure rename, an empty file).
  ///
  /// In en, this message translates to:
  /// **'No line changes'**
  String get inspectorDiffNoLines;

  /// Operation toast after jj abandon; changes is a list of change ids.
  ///
  /// In en, this message translates to:
  /// **'Abandoned {changes}'**
  String toastAbandoned(String changes);

  /// Operation toast after jj revert: change was reverted, the new change inverse holds its inverse.
  ///
  /// In en, this message translates to:
  /// **'Reverted {change} — {inverse} undoes it'**
  String toastReverted(String change, String inverse);

  /// Operation toast after jj revert when jj reported no new change.
  ///
  /// In en, this message translates to:
  /// **'Reverted {change}'**
  String toastRevertedAlone(String change);

  /// Operation toast after jj squash; both are change ids.
  ///
  /// In en, this message translates to:
  /// **'Squashed {source} into {destination}'**
  String toastSquashed(String source, String destination);

  /// Operation toast after jj commit: change is the committed change id, subject its first line.
  ///
  /// In en, this message translates to:
  /// **'Committed {change} · “{subject}”'**
  String toastCommitted(String change, String subject);

  /// Operation toast after jj commit without a description.
  ///
  /// In en, this message translates to:
  /// **'Committed {change}'**
  String toastCommittedAlone(String change);

  /// Operation toast after jj split: change kept the selected files, the new change rest holds the others.
  ///
  /// In en, this message translates to:
  /// **'Split {change} — the rest is now {rest}'**
  String toastSplit(String change, String rest);

  /// Operation toast after jj split when jj reported no new change.
  ///
  /// In en, this message translates to:
  /// **'Split {change}'**
  String toastSplitAlone(String change);

  /// Operation toast after jj bookmark create; names are bookmark names, target a change id.
  ///
  /// In en, this message translates to:
  /// **'Created {names} on {target}'**
  String toastBookmarkCreated(String names, String target);

  /// Operation toast after jj bookmark delete; names are bookmark names.
  ///
  /// In en, this message translates to:
  /// **'Deleted {names}'**
  String toastBookmarkDeleted(String names);

  /// Operation toast after jj bookmark move; names are bookmark names, target a change id.
  ///
  /// In en, this message translates to:
  /// **'Moved {names} to {target}'**
  String toastBookmarkMoved(String names, String target);

  /// Operation toast after jj bookmark rename.
  ///
  /// In en, this message translates to:
  /// **'Renamed {oldName} to {newName}'**
  String toastBookmarkRenamed(String oldName, String newName);

  /// Operation toast after jj bookmark track; name is the remote bookmark (name@remote).
  ///
  /// In en, this message translates to:
  /// **'Started tracking {name}'**
  String toastBookmarkTracked(String name);

  /// Operation toast after jj bookmark untrack; name is the remote bookmark (name@remote).
  ///
  /// In en, this message translates to:
  /// **'Stopped tracking {name}'**
  String toastBookmarkUntracked(String name);

  /// Operation toast after jj undo; command is the jj command that was undone.
  ///
  /// In en, this message translates to:
  /// **'Undid {command}'**
  String toastUndid(String command);

  /// Operation toast after jj redo; command is the jj command that was redone.
  ///
  /// In en, this message translates to:
  /// **'Redid {command}'**
  String toastRedid(String command);

  /// Toast button that runs jj undo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get toastUndo;

  /// Toast button that runs jj redo.
  ///
  /// In en, this message translates to:
  /// **'Redo'**
  String get toastRedo;

  /// Toast button that runs the failed jj command again.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get toastRetry;

  /// Toast when Undo found that another program's jj operation came after Zanshin's.
  ///
  /// In en, this message translates to:
  /// **'Nothing undone — another operation came after it'**
  String get toastNothingUndone;

  /// Toast when Redo found that another program's jj operation came after Zanshin's undo.
  ///
  /// In en, this message translates to:
  /// **'Nothing redone — another operation came after it'**
  String get toastNothingRedone;

  /// Toast when jj workspace update-stale failed; reason is jj's message or error code.
  ///
  /// In en, this message translates to:
  /// **'Updating the working copy failed — {reason}'**
  String toastStaleUpdateFailed(String reason);

  /// Toast in the project window after a project was created and opened with warnings; name is the project's.
  ///
  /// In en, this message translates to:
  /// **'Opened {name}'**
  String toastOpened(String name);

  /// Joins the last item of a list in a toast: a, b and c.
  ///
  /// In en, this message translates to:
  /// **'{head} and {last}'**
  String toastListAnd(String head, String last);

  /// Joins the items before the last of a list in a toast: a, b and c.
  ///
  /// In en, this message translates to:
  /// **'{head}, {next}'**
  String toastListComma(String head, String next);

  /// Menu bar: the File menu (Title Case, as the whole menu bar).
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get menuFile;

  /// Menu bar: the Edit menu.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get menuEdit;

  /// Menu bar: the View menu.
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get menuView;

  /// Menu bar: the Change menu (jj verbs on the selected change, else @).
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get menuChange;

  /// Menu bar: the Go menu (scrolling and moving the selection in the graph).
  ///
  /// In en, this message translates to:
  /// **'Go'**
  String get menuGo;

  /// Menu bar: the Window menu.
  ///
  /// In en, this message translates to:
  /// **'Window'**
  String get menuWindow;

  /// Menu bar: the Help menu.
  ///
  /// In en, this message translates to:
  /// **'Help'**
  String get menuHelp;

  /// File menu: the submenu of recently opened projects.
  ///
  /// In en, this message translates to:
  /// **'Open Recent'**
  String get menuOpenRecent;

  /// File menu: closes the key window (the project window closes the project and shows Projects).
  ///
  /// In en, this message translates to:
  /// **'Close Window'**
  String get menuCloseWindow;

  /// Edit menu: undoes Zanshin's own latest jj operation; action names it.
  ///
  /// In en, this message translates to:
  /// **'Undo {action}'**
  String menuUndo(String action);

  /// Edit menu: Undo when there is no own operation to name, or in a text field.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get menuUndoPlain;

  /// Edit menu: redoes Zanshin's own latest undo; action names what is redone.
  ///
  /// In en, this message translates to:
  /// **'Redo {action}'**
  String menuRedo(String action);

  /// Edit menu: Redo when there is no own undo to name, or in a text field.
  ///
  /// In en, this message translates to:
  /// **'Redo'**
  String get menuRedoPlain;

  /// Edit menu: cuts the selected text.
  ///
  /// In en, this message translates to:
  /// **'Cut'**
  String get menuCut;

  /// Edit menu: copies the selected text.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get menuCopy;

  /// Edit menu: pastes into the focused field.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get menuPaste;

  /// Edit menu: selects all text in the focused field.
  ///
  /// In en, this message translates to:
  /// **'Select All'**
  String get menuSelectAll;

  /// Edit menu: focuses the search (the graph's, or the Projects window's while it is key).
  ///
  /// In en, this message translates to:
  /// **'Find'**
  String get menuFind;

  /// View menu: the Free graph layout.
  ///
  /// In en, this message translates to:
  /// **'Free'**
  String get menuFree;

  /// View menu: the Compact graph layout.
  ///
  /// In en, this message translates to:
  /// **'Compact'**
  String get menuCompact;

  /// View menu: toggles detailed graph cards.
  ///
  /// In en, this message translates to:
  /// **'Detailed Cards'**
  String get menuDetailedCards;

  /// View menu: toggles grouping linear runs into stacks.
  ///
  /// In en, this message translates to:
  /// **'Group Stacks'**
  String get menuGroupStacks;

  /// View menu: opens the jj log Configurations window.
  ///
  /// In en, this message translates to:
  /// **'Edit Configurations…'**
  String get menuEditConfigurations;

  /// View menu: toggles the graph's minimap.
  ///
  /// In en, this message translates to:
  /// **'Show Minimap'**
  String get menuShowMinimap;

  /// View menu: reads the project and the graph again.
  ///
  /// In en, this message translates to:
  /// **'Reload'**
  String get menuReload;

  /// Change menu: jj new on the target change.
  ///
  /// In en, this message translates to:
  /// **'New Change'**
  String get menuNewChange;

  /// Change menu: edits the target change's description.
  ///
  /// In en, this message translates to:
  /// **'Describe…'**
  String get menuDescribe;

  /// Names a describe in Undo/Redo; target is @ or the change id.
  ///
  /// In en, this message translates to:
  /// **'Describe {target}'**
  String menuDescribeTarget(String target);

  /// Change menu: jj edit, without a target to name.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get menuChangeEdit;

  /// Change menu: jj edit on the target; target is the change id.
  ///
  /// In en, this message translates to:
  /// **'Edit {target}'**
  String menuChangeEditTarget(String target);

  /// Change menu: jj squash, without a target to name.
  ///
  /// In en, this message translates to:
  /// **'Squash into Parent'**
  String get menuSquash;

  /// Change menu: jj squash -r on the target; target is @ or the change id.
  ///
  /// In en, this message translates to:
  /// **'Squash {target} into Parent'**
  String menuSquashTarget(String target);

  /// Undo/Redo menu name of a jj commit; target is the committed change id.
  ///
  /// In en, this message translates to:
  /// **'Commit {target}'**
  String menuCommitTarget(String target);

  /// Undo/Redo menu name of a jj split; target is the split change id.
  ///
  /// In en, this message translates to:
  /// **'Split {target}'**
  String menuSplitTarget(String target);

  /// Change menu: jj revert, without a target to name.
  ///
  /// In en, this message translates to:
  /// **'Revert'**
  String get menuRevert;

  /// Change menu: jj revert on the target; target is the change id.
  ///
  /// In en, this message translates to:
  /// **'Revert {target}'**
  String menuRevertTarget(String target);

  /// Change menu: jj abandon, without a target to name.
  ///
  /// In en, this message translates to:
  /// **'Abandon'**
  String get menuAbandon;

  /// Change menu: jj abandon on the target; target is @ or the change id.
  ///
  /// In en, this message translates to:
  /// **'Abandon {target}'**
  String menuAbandonTarget(String target);

  /// Names a bookmark creation in Undo/Redo.
  ///
  /// In en, this message translates to:
  /// **'Create Bookmark {names}'**
  String menuBookmarkCreate(String names);

  /// Names a bookmark deletion in Undo/Redo.
  ///
  /// In en, this message translates to:
  /// **'Delete Bookmark {names}'**
  String menuBookmarkDelete(String names);

  /// Names a bookmark move in Undo/Redo.
  ///
  /// In en, this message translates to:
  /// **'Move Bookmark {names}'**
  String menuBookmarkMove(String names);

  /// Names a bookmark rename in Undo/Redo.
  ///
  /// In en, this message translates to:
  /// **'Rename Bookmark {names}'**
  String menuBookmarkRename(String names);

  /// Names jj bookmark track in Undo/Redo; name is the remote bookmark (name@remote).
  ///
  /// In en, this message translates to:
  /// **'Track {name}'**
  String menuBookmarkTrack(String name);

  /// Names jj bookmark untrack in Undo/Redo; name is the remote bookmark (name@remote).
  ///
  /// In en, this message translates to:
  /// **'Untrack {name}'**
  String menuBookmarkUntrack(String name);

  /// Change menu: jj git fetch.
  ///
  /// In en, this message translates to:
  /// **'Fetch'**
  String get menuFetch;

  /// Change menu: opens the Push sheet.
  ///
  /// In en, this message translates to:
  /// **'Push…'**
  String get menuPush;

  /// Go menu: scrolls to the selected change.
  ///
  /// In en, this message translates to:
  /// **'Selection'**
  String get menuGoSelection;

  /// Go menu: scrolls to the working-copy change, @.
  ///
  /// In en, this message translates to:
  /// **'Working Copy (@)'**
  String get menuGoWorkingCopy;

  /// Go menu: selects the selected change's first parent.
  ///
  /// In en, this message translates to:
  /// **'Parent'**
  String get menuGoParent;

  /// Go menu: selects the selected change's first child.
  ///
  /// In en, this message translates to:
  /// **'Child'**
  String get menuGoChild;

  /// Help menu: the app's help; app is the product name.
  ///
  /// In en, this message translates to:
  /// **'{app} Help'**
  String menuAppHelp(String app);

  /// Help menu: opens jj's documentation in the browser; tool is jj's name.
  ///
  /// In en, this message translates to:
  /// **'{tool} Documentation ↗'**
  String menuToolDocumentation(String tool);

  /// Names a jj op restore in Undo/Redo; operation is jj's 12-digit short operation id.
  ///
  /// In en, this message translates to:
  /// **'Restore to {operation}'**
  String menuRestoreOperation(String operation);

  /// The rail item, its preview's and its pinned panel's title: the operation log.
  ///
  /// In en, this message translates to:
  /// **'Undo Timeline'**
  String get undoTimelineTitle;

  /// Undo Timeline: jj undo of the newest operation.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undoTimelineUndo;

  /// Undo Timeline: jj redo of Zanshin's own latest undo.
  ///
  /// In en, this message translates to:
  /// **'Redo'**
  String get undoTimelineRedo;

  /// Undo Timeline row action: jj op restore to this operation.
  ///
  /// In en, this message translates to:
  /// **'Restore to here'**
  String get undoTimelineRestore;

  /// Undo Timeline row action: jj op show, what the operation changed.
  ///
  /// In en, this message translates to:
  /// **'Show changes'**
  String get undoTimelineShowChanges;

  /// Undo Timeline's operation view (jj op show): returns to the operation list.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get operationChangesBack;

  /// Undo Timeline's operation view: the operation has several parents, so jj op show prints no changes.
  ///
  /// In en, this message translates to:
  /// **'This operation merges several operations; jj shows no changes for it.'**
  String get operationChangesMerge;

  /// Undo Timeline's operation view: jj op show lists no changed commits, working copies, bookmarks or tags.
  ///
  /// In en, this message translates to:
  /// **'jj shows no changes for this operation.'**
  String get operationChangesNone;

  /// Undo Timeline's operation view: the selected commit's diff (as jj op show --patch shows it) changes no file.
  ///
  /// In en, this message translates to:
  /// **'No file changes'**
  String get operationChangesNoFiles;

  /// Why the Undo Timeline's actions are disabled: the project window shows no commit graph yet.
  ///
  /// In en, this message translates to:
  /// **'Available once the commit graph is shown'**
  String get undoTimelineNoRunner;

  /// Why the Undo Timeline's actions are disabled while another jj action runs.
  ///
  /// In en, this message translates to:
  /// **'Another action is running'**
  String get undoTimelineBusy;

  /// Why Undo is disabled: the operation before the newest is jj's root operation.
  ///
  /// In en, this message translates to:
  /// **'Undoing it would restore the root operation'**
  String get undoTimelineRootParent;

  /// Why Redo is disabled: Zanshin's own latest undo is not the newest operation.
  ///
  /// In en, this message translates to:
  /// **'Nothing to redo'**
  String get undoTimelineNothingToRedo;

  /// Undo Timeline: reading jj's operation log failed; detail is jj's error, verbatim.
  ///
  /// In en, this message translates to:
  /// **'The operation log could not be read: {detail}'**
  String undoTimelineLoadFailed(String detail);

  /// VoiceOver label of an Undo Timeline row: the operation's description and when it ran.
  ///
  /// In en, this message translates to:
  /// **'{description}, {when}'**
  String undoTimelineRow(String description, String when);

  /// VoiceOver label of an Undo Timeline row with the jj workspace the operation ran in.
  ///
  /// In en, this message translates to:
  /// **'{description}, {when}, workspace {workspace}'**
  String undoTimelineRowWorkspace(String description, String when, String workspace);

  /// The rail item, its preview's and its pinned panel's title: jj's bookmarks.
  ///
  /// In en, this message translates to:
  /// **'Bookmarks'**
  String get bookmarksTitle;

  /// Bookmarks preview: how many rows the preview leaves out; a click pins the panel.
  ///
  /// In en, this message translates to:
  /// **'+{count} more'**
  String bookmarksMore(int count);

  /// Bookmarks: the repository has no bookmark; command is jj's command, verbatim.
  ///
  /// In en, this message translates to:
  /// **'No bookmarks yet. Create one with `{command}`.'**
  String bookmarksEmpty(String command);

  /// Bookmarks: reading jj's bookmark list failed; detail is jj's error, verbatim.
  ///
  /// In en, this message translates to:
  /// **'The bookmarks could not be read: {detail}'**
  String bookmarksLoadFailed(String detail);

  /// A bookmark row's tooltip and VoiceOver label: the bookmark and its state's long form.
  ///
  /// In en, this message translates to:
  /// **'{name} — {state}'**
  String bookmarksRow(String name, String state);

  /// Bookmark row state, short: a local bookmark no remote tracks.
  ///
  /// In en, this message translates to:
  /// **'local'**
  String get bookmarksStateLocalShort;

  /// Bookmark row state, short: a remote bookmark that is not tracked.
  ///
  /// In en, this message translates to:
  /// **'remote'**
  String get bookmarksStateRemoteShort;

  /// Bookmark row state, short: jj's (deleted) — a local bookmark deleted while it still tracks a remote.
  ///
  /// In en, this message translates to:
  /// **'deleted'**
  String get bookmarksStateDeletedShort;

  /// Bookmark row state, short: jj's (not created yet) — a tracked remote bookmark not pushed yet.
  ///
  /// In en, this message translates to:
  /// **'not created yet'**
  String get bookmarksStateNotCreatedShort;

  /// Bookmark row state, short: the target change is divergent (jj's term).
  ///
  /// In en, this message translates to:
  /// **'divergent'**
  String get bookmarksStateDivergentShort;

  /// Bookmark row state, long: a local bookmark no remote tracks.
  ///
  /// In en, this message translates to:
  /// **'local only'**
  String get bookmarksStateLocal;

  /// Bookmark row state, long: a remote bookmark that is not tracked.
  ///
  /// In en, this message translates to:
  /// **'remote only, not tracked'**
  String get bookmarksStateRemote;

  /// Bookmark row state, long: jj's (deleted).
  ///
  /// In en, this message translates to:
  /// **'deleted, still tracking a remote'**
  String get bookmarksStateDeleted;

  /// Bookmark row state, long: jj's (not created yet).
  ///
  /// In en, this message translates to:
  /// **'not created on the remote yet'**
  String get bookmarksStateNotCreated;

  /// Bookmark row state, long: the bookmark's target is a conflict (jj's term).
  ///
  /// In en, this message translates to:
  /// **'conflicted'**
  String get bookmarksStateConflicted;

  /// Bookmark row state, long: the target change is divergent (jj's term).
  ///
  /// In en, this message translates to:
  /// **'divergent'**
  String get bookmarksStateDivergent;

  /// Bookmark row state, long: same target as other (a remote for a local row, the local bookmark for a remote row).
  ///
  /// In en, this message translates to:
  /// **'in sync with {other}'**
  String bookmarksStateSynced(String other);

  /// Bookmark row state, long: it has count commits other lacks; count may end in + (at least).
  ///
  /// In en, this message translates to:
  /// **'ahead of {other} by {count}'**
  String bookmarksStateAhead(String other, String count);

  /// Bookmark row state, long: other has count commits it lacks; count may end in + (at least).
  ///
  /// In en, this message translates to:
  /// **'behind {other} by {count}'**
  String bookmarksStateBehind(String other, String count);

  /// Bookmark row state, long: both it and other have commits the other lacks.
  ///
  /// In en, this message translates to:
  /// **'diverged from {other}'**
  String bookmarksStateDiverged(String other);

  /// Bookmark row state, long: a local bookmark whose tracked remote bookmark is not created yet.
  ///
  /// In en, this message translates to:
  /// **'not on {other} yet'**
  String bookmarksStateNotPushed(String other);

  /// Bookmark row button: jj bookmark track of an untracked remote bookmark.
  ///
  /// In en, this message translates to:
  /// **'Track'**
  String get bookmarksTrack;

  /// Bookmark row button: jj bookmark untrack of a tracked remote bookmark.
  ///
  /// In en, this message translates to:
  /// **'Untrack'**
  String get bookmarksUntrack;

  /// Why Track and Untrack are disabled while another jj action runs.
  ///
  /// In en, this message translates to:
  /// **'Another action is running'**
  String get bookmarksBusy;

  /// Card menu row: jj new on the change.
  ///
  /// In en, this message translates to:
  /// **'New change on top'**
  String get cardMenuNewOnTop;

  /// Card menu row: jj new -A, a new change inserted after this one.
  ///
  /// In en, this message translates to:
  /// **'Insert after'**
  String get cardMenuInsertAfter;

  /// Card menu row: jj new -B, a new change inserted before this one.
  ///
  /// In en, this message translates to:
  /// **'Insert before'**
  String get cardMenuInsertBefore;

  /// Card menu row: jj edit, making the change the working copy.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get cardMenuEdit;

  /// Why the card menu's Edit is disabled on the working copy.
  ///
  /// In en, this message translates to:
  /// **'Already the working copy'**
  String get cardMenuEditAlready;

  /// Card menu row: opens the inspector's describe form for the change.
  ///
  /// In en, this message translates to:
  /// **'Describe…'**
  String get cardMenuDescribe;

  /// Card menu row: jj squash -r, the change folded into its parent.
  ///
  /// In en, this message translates to:
  /// **'Squash into parent'**
  String get cardMenuSquash;

  /// Why the card menu's Squash into parent is disabled on a merge.
  ///
  /// In en, this message translates to:
  /// **'A merge has more than one parent'**
  String get cardMenuSquashMerge;

  /// Why the card menu's Squash into parent is disabled when the parent is immutable.
  ///
  /// In en, this message translates to:
  /// **'The parent is immutable'**
  String get cardMenuSquashParentImmutable;

  /// Card menu row: the submenu that copies the change id or the description.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get cardMenuCopy;

  /// Card menu Copy submenu row: copies the full change id.
  ///
  /// In en, this message translates to:
  /// **'Change id'**
  String get cardMenuCopyChangeId;

  /// Card menu Copy submenu row: copies the full description.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get cardMenuCopyDescription;

  /// Card menu row: jj revert -r <id> -B @.
  ///
  /// In en, this message translates to:
  /// **'Revert'**
  String get cardMenuRevert;

  /// Why the card menu's Revert is disabled on the working copy.
  ///
  /// In en, this message translates to:
  /// **'The revert lands below @ — @ itself can\'t be reverted'**
  String get cardMenuRevertAt;

  /// Why the card menu's Revert is disabled on a change that is not an ancestor of the working copy.
  ///
  /// In en, this message translates to:
  /// **'The revert lands below @ — only changes in @\'s history'**
  String get cardMenuRevertNotAncestor;

  /// Why the card menu's Revert is disabled on an empty change.
  ///
  /// In en, this message translates to:
  /// **'Nothing to revert — the change is empty'**
  String get cardMenuRevertEmpty;

  /// Card menu row: jj abandon.
  ///
  /// In en, this message translates to:
  /// **'Abandon'**
  String get cardMenuAbandon;

  /// Card menu note on an immutable change.
  ///
  /// In en, this message translates to:
  /// **'Immutable'**
  String get cardMenuImmutable;

  /// Card menu row on an immutable change: opens the immutable-commits settings.
  ///
  /// In en, this message translates to:
  /// **'Immutable commits…'**
  String get cardMenuImmutableCommits;

  /// Card menu header subject of a change without a description, as jj prints it.
  ///
  /// In en, this message translates to:
  /// **'(no description set)'**
  String get cardMenuNoDescription;

  /// VoiceOver name of a card's bookmark popover.
  ///
  /// In en, this message translates to:
  /// **'Bookmarks'**
  String get bookmarkMenuLabel;

  /// Bookmark popover row: renames the local bookmark.
  ///
  /// In en, this message translates to:
  /// **'Rename…'**
  String get bookmarkMenuRename;

  /// Bookmark popover row: moves the local bookmark to another revision.
  ///
  /// In en, this message translates to:
  /// **'Move to…'**
  String get bookmarkMenuMoveTo;

  /// Bookmark popover row: deletes the local bookmark.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get bookmarkMenuDelete;

  /// Why Track / Untrack is disabled until the bookmark list is read.
  ///
  /// In en, this message translates to:
  /// **'Reading bookmarks…'**
  String get bookmarkMenuReading;

  /// Why Track / Untrack is disabled after the bookmark list could not be read.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t read the bookmarks'**
  String get bookmarkMenuReadFailed;

  /// Bookmark popover row: creates a bookmark on this change.
  ///
  /// In en, this message translates to:
  /// **'Create bookmark here…'**
  String get bookmarkMenuCreate;

  /// Bookmark popover row: moves an existing bookmark to this change.
  ///
  /// In en, this message translates to:
  /// **'Move existing here…'**
  String get bookmarkMenuMoveHere;

  /// Name sheet title: renaming a bookmark.
  ///
  /// In en, this message translates to:
  /// **'Rename {name}'**
  String nameSheetRenameTitle(String name);

  /// Name sheet title: moving a bookmark to a revision.
  ///
  /// In en, this message translates to:
  /// **'Move {name} to'**
  String nameSheetMoveToTitle(String name);

  /// Name sheet title: a new bookmark on the change.
  ///
  /// In en, this message translates to:
  /// **'Create bookmark here'**
  String get nameSheetCreateTitle;

  /// Name sheet title: an existing bookmark moved to the change.
  ///
  /// In en, this message translates to:
  /// **'Move a bookmark here'**
  String get nameSheetMoveHereTitle;

  /// Name sheet field label: a bookmark name.
  ///
  /// In en, this message translates to:
  /// **'Bookmark name'**
  String get nameSheetNameLabel;

  /// Name sheet field label: the revision a bookmark moves to.
  ///
  /// In en, this message translates to:
  /// **'Revision'**
  String get nameSheetRevisionLabel;

  /// Name sheet button: closes it without running anything.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get nameSheetCancel;

  /// Name sheet confirm button: jj bookmark rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get nameSheetRename;

  /// Name sheet confirm button: jj bookmark move.
  ///
  /// In en, this message translates to:
  /// **'Move'**
  String get nameSheetMove;

  /// Name sheet confirm button: jj bookmark create.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get nameSheetCreate;

  /// The jj log Configurations window's title (Story 10.22).
  ///
  /// In en, this message translates to:
  /// **'jj log Configurations'**
  String get revsetConfigsTitle;

  /// A jj log configuration whose name is empty, in the list and the search menu.
  ///
  /// In en, this message translates to:
  /// **'Unnamed'**
  String get revsetConfigsUnnamed;

  /// The name a configuration added with Add configuration gets.
  ///
  /// In en, this message translates to:
  /// **'New configuration'**
  String get revsetConfigsNewName;

  /// The name of a duplicated configuration.
  ///
  /// In en, this message translates to:
  /// **'{name} copy'**
  String revsetConfigsCopyName(String name);

  /// The list toolbar's add button and the empty list's action.
  ///
  /// In en, this message translates to:
  /// **'Add configuration'**
  String get revsetConfigsAdd;

  /// The list toolbar's remove button.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get revsetConfigsRemove;

  /// The list toolbar's duplicate button.
  ///
  /// In en, this message translates to:
  /// **'Duplicate'**
  String get revsetConfigsDuplicate;

  /// The list toolbar's move-up button.
  ///
  /// In en, this message translates to:
  /// **'Move up'**
  String get revsetConfigsMoveUp;

  /// The list toolbar's move-down button.
  ///
  /// In en, this message translates to:
  /// **'Move down'**
  String get revsetConfigsMoveDown;

  /// The list's section over jj log and all().
  ///
  /// In en, this message translates to:
  /// **'Built-in'**
  String get revsetConfigsBuiltIn;

  /// The list's section over the user's configurations.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get revsetConfigsCustom;

  /// A built-in entry's read-only description in the editor.
  ///
  /// In en, this message translates to:
  /// **'Built-in · {detail}'**
  String revsetConfigsBuiltInDetail(String detail);

  /// The editor while no configuration is selected and none exists.
  ///
  /// In en, this message translates to:
  /// **'No custom configurations yet.'**
  String get revsetConfigsEmpty;

  /// The editor's name field label.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get revsetConfigsName;

  /// The editor's Default search switch row.
  ///
  /// In en, this message translates to:
  /// **'Default search'**
  String get revsetConfigsDefaultSearch;

  /// The Default search row's hint.
  ///
  /// In en, this message translates to:
  /// **'Listed first in the search menu — ✕ in the search field returns to it'**
  String get revsetConfigsDefaultHint;

  /// The Default search row's hint for jj log while it is the default (the switch is locked on).
  ///
  /// In en, this message translates to:
  /// **'Used whenever no other configuration is the default'**
  String get revsetConfigsDefaultLockedHint;

  /// The editor's rules block label.
  ///
  /// In en, this message translates to:
  /// **'Filters'**
  String get revsetConfigsFilters;

  /// VoiceOver label of the Match all / Match any control.
  ///
  /// In en, this message translates to:
  /// **'Combine'**
  String get revsetConfigsCombine;

  /// Rules joined with jj's & (every rule must match).
  ///
  /// In en, this message translates to:
  /// **'Match all &'**
  String get revsetConfigsMatchAll;

  /// Rules joined with jj's | (any rule may match).
  ///
  /// In en, this message translates to:
  /// **'Match any |'**
  String get revsetConfigsMatchAny;

  /// A rule's negation chip while it includes its matches.
  ///
  /// In en, this message translates to:
  /// **'is'**
  String get revsetConfigsIs;

  /// A rule's negation chip while it excludes its matches (jj's ~).
  ///
  /// In en, this message translates to:
  /// **'~ not'**
  String get revsetConfigsNot;

  /// Tooltip of a negated rule's chip.
  ///
  /// In en, this message translates to:
  /// **'Negated (~) — click to include'**
  String get revsetConfigsNotOnTooltip;

  /// Tooltip of a rule's negation chip while it includes its matches.
  ///
  /// In en, this message translates to:
  /// **'Click to exclude matches (~)'**
  String get revsetConfigsNotOffTooltip;

  /// VoiceOver label of a rule's function picker.
  ///
  /// In en, this message translates to:
  /// **'Function'**
  String get revsetConfigsFunction;

  /// VoiceOver label of a rule's match-mode picker.
  ///
  /// In en, this message translates to:
  /// **'Match'**
  String get revsetConfigsMatch;

  /// A rule's match mode; fileGlob is the files glob.
  ///
  /// In en, this message translates to:
  /// **'{mode, select, substring{contains} exact{is exactly} glob{matches glob} regex{matches regex} prefix{path or folder} file{exact file} fileGlob{glob} other{glob}}'**
  String revsetConfigsMode(String mode);

  /// What a rule function matches: the function picker's and add chips' tooltip and the value's placeholder for the text functions (files and revset show an example instead); other is files; revset is a raw revset rule.
  ///
  /// In en, this message translates to:
  /// **'{fn, select, author{Author name or email} committer{Committer name or email} mine{Changes authored by your user.email} subject{First line of the description} description{Full description text} revset{Any revset, as jj log -r takes it} other{Changes touching these paths}}'**
  String revsetConfigsHint(String fn);

  /// Second line under a raw revset rule's jj error, as jj words its similarity hint; names are jj's candidates, each in backticks, comma-separated.
  ///
  /// In en, this message translates to:
  /// **'Did you mean {names}?'**
  String revsetConfigsDidYouMean(String names);

  /// Tooltip of a text rule's Aa toggle (jj's -i).
  ///
  /// In en, this message translates to:
  /// **'Case-insensitive (-i)'**
  String get revsetConfigsCaseInsensitive;

  /// A rule row's remove button.
  ///
  /// In en, this message translates to:
  /// **'Remove filter'**
  String get revsetConfigsRemoveFilter;

  /// A configuration without rules; expression is all().
  ///
  /// In en, this message translates to:
  /// **'No filters — shows every commit ({expression}).'**
  String revsetConfigsNoFilters(String expression);

  /// A mine() rule, before the project's user.email (bold) and jj's key · user.email.
  ///
  /// In en, this message translates to:
  /// **'authored by'**
  String get revsetConfigsAuthoredBy;

  /// The command preview's label.
  ///
  /// In en, this message translates to:
  /// **'Command'**
  String get revsetConfigsCommand;

  /// After the bold match count in the command preview; total is the shown graph's count.
  ///
  /// In en, this message translates to:
  /// **' of {total} changes match'**
  String revsetConfigsMatchesOf(String total);

  /// Copies the previewed jj command.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get revsetConfigsCopy;

  /// The Copy link for a moment after copying.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get revsetConfigsCopied;

  /// The footer link to jj's revset documentation.
  ///
  /// In en, this message translates to:
  /// **'Revset reference ↗'**
  String get revsetConfigsReference;

  /// The footer's Cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get revsetConfigsCancel;

  /// The footer's Apply: saves without closing.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get revsetConfigsApply;

  /// The footer's OK: saves, shows the selected entry and closes.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get revsetConfigsOk;

  /// The sheet before unsaved configuration edits are dropped.
  ///
  /// In en, this message translates to:
  /// **'Discard changes?'**
  String get revsetConfigsDiscardTitle;

  /// The Discard changes? sheet's body.
  ///
  /// In en, this message translates to:
  /// **'Your edits to the configurations haven’t been applied. Cancel keeps them here.'**
  String get revsetConfigsDiscardBody;

  /// The Discard changes? sheet's destructive button.
  ///
  /// In en, this message translates to:
  /// **'Discard changes'**
  String get revsetConfigsDiscard;

  /// The Settings window's General tab, and the window's title while it shows.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get settingsTabGeneral;

  /// The Settings window's Project tab while no project is open.
  ///
  /// In en, this message translates to:
  /// **'Project'**
  String get settingsTabProject;

  /// VoiceOver name of the Settings window's tabs.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTabsLabel;

  /// Why the Settings window's Project tab is disabled.
  ///
  /// In en, this message translates to:
  /// **'Open a project first'**
  String get settingsOpenProjectFirst;

  /// The General tab's scope line, followed by the user config file's path.
  ///
  /// In en, this message translates to:
  /// **'For Zanshin on this Mac · jj settings go to'**
  String get settingsScopeGeneral;

  /// The Project tab's scope line, followed by the repo config file's path.
  ///
  /// In en, this message translates to:
  /// **'For {name} only ·'**
  String settingsScopeProject(String name);

  /// The Settings window's footer; viewOptions is settingsFooterViewOptions, shown bold.
  ///
  /// In en, this message translates to:
  /// **'How the graph looks lives with the graph: {viewOptions} in the toolbar.'**
  String settingsFooter(String viewOptions);

  /// The toolbar button the Settings footer names (bold).
  ///
  /// In en, this message translates to:
  /// **'View options'**
  String get settingsFooterViewOptions;

  /// VoiceOver name of a Settings page's back button.
  ///
  /// In en, this message translates to:
  /// **'Back to {name}'**
  String settingsBackTo(String name);

  /// A jj row's hint when its value comes from another config layer; scope is jj's layer name (user, repo, …).
  ///
  /// In en, this message translates to:
  /// **'From {scope} config'**
  String settingsFromScope(String scope);

  /// After an identity write: the working copy's author still differs; command is jj's command, verbatim.
  ///
  /// In en, this message translates to:
  /// **'@ keeps the author {name} <{email}>. {command} changes it.'**
  String settingsAuthorFact(String name, String email, String command);

  /// Settings › General group heading.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearance;

  /// Settings › General › Appearance row.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get settingsTheme;

  /// The light theme.
  ///
  /// In en, this message translates to:
  /// **'Paper'**
  String get settingsThemePaper;

  /// The dark theme.
  ///
  /// In en, this message translates to:
  /// **'Night'**
  String get settingsThemeNight;

  /// The theme follows macOS.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get settingsThemeAuto;

  /// Settings › General › Appearance row: the text size.
  ///
  /// In en, this message translates to:
  /// **'Density'**
  String get settingsDensity;

  /// Density choice: the default size.
  ///
  /// In en, this message translates to:
  /// **'Compact'**
  String get settingsDensityCompact;

  /// Density choice: one step larger.
  ///
  /// In en, this message translates to:
  /// **'Balanced'**
  String get settingsDensityBalanced;

  /// Density choice: two steps larger.
  ///
  /// In en, this message translates to:
  /// **'Comfy'**
  String get settingsDensityComfy;

  /// Settings › General › Appearance row.
  ///
  /// In en, this message translates to:
  /// **'Accent colour'**
  String get settingsAccent;

  /// The Accent colour row's hint.
  ///
  /// In en, this message translates to:
  /// **'Selection, focus and controls take the colour from System Settings › Appearance. Gold stays with @ and the primary action.'**
  String get settingsAccentHint;

  /// Accent colour choice: the macOS accent.
  ///
  /// In en, this message translates to:
  /// **'Follow macOS'**
  String get settingsAccentMacOS;

  /// Accent colour choice: Zanshin's own colour.
  ///
  /// In en, this message translates to:
  /// **'Zanshin'**
  String get settingsAccentZanshin;

  /// Settings › General group heading.
  ///
  /// In en, this message translates to:
  /// **'While you scroll'**
  String get settingsWhileScrolling;

  /// Settings › General › While you scroll row.
  ///
  /// In en, this message translates to:
  /// **'Hide controls'**
  String get settingsHideControls;

  /// The Hide controls row's hint.
  ///
  /// In en, this message translates to:
  /// **'Toolbars and panels step aside while you scroll the graph. The minimap stays.'**
  String get settingsHideControlsHint;

  /// VoiceOver name of the Hide controls switch.
  ///
  /// In en, this message translates to:
  /// **'Hide controls while scrolling'**
  String get settingsHideControlsSwitch;

  /// Settings › General group heading.
  ///
  /// In en, this message translates to:
  /// **'Diffs'**
  String get settingsDiffs;

  /// Settings › General › Diffs row.
  ///
  /// In en, this message translates to:
  /// **'Layout'**
  String get settingsDiffLayout;

  /// VoiceOver name of the diff layout choice.
  ///
  /// In en, this message translates to:
  /// **'Diff layout'**
  String get settingsDiffLayoutLabel;

  /// Diff layout choice: one column.
  ///
  /// In en, this message translates to:
  /// **'Unified'**
  String get settingsDiffUnified;

  /// Diff layout choice: two columns.
  ///
  /// In en, this message translates to:
  /// **'Side by side'**
  String get settingsDiffSideBySide;

  /// Settings group heading (General and Project).
  ///
  /// In en, this message translates to:
  /// **'Identity'**
  String get settingsIdentity;

  /// Settings › General › Identity row (user.name).
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get settingsName;

  /// Settings › Identity row (user.email).
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get settingsEmail;

  /// VoiceOver name of the Project tab's email field.
  ///
  /// In en, this message translates to:
  /// **'Project email'**
  String get settingsProjectEmail;

  /// Settings › Project group heading.
  ///
  /// In en, this message translates to:
  /// **'Remotes'**
  String get settingsRemotes;

  /// Settings › Project › Remotes row (git.fetch).
  ///
  /// In en, this message translates to:
  /// **'Fetch from'**
  String get settingsFetchFrom;

  /// Settings › Project › Remotes row (git.push).
  ///
  /// In en, this message translates to:
  /// **'Push to'**
  String get settingsPushTo;

  /// Fetch from / Push to when the repository has no remote.
  ///
  /// In en, this message translates to:
  /// **'No remotes'**
  String get settingsNoRemotes;

  /// Settings › Project › Remotes row: how often the project checks its remotes.
  ///
  /// In en, this message translates to:
  /// **'Check for remote changes'**
  String get settingsRemotePoll;

  /// Check for remote changes: never.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get settingsRemotePollOff;

  /// Check for remote changes: every 5 minutes.
  ///
  /// In en, this message translates to:
  /// **'5 min'**
  String get settingsRemotePoll5;

  /// Check for remote changes: every 15 minutes.
  ///
  /// In en, this message translates to:
  /// **'15 min'**
  String get settingsRemotePoll15;

  /// Settings › Project group heading.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get settingsHistory;

  /// Settings › Project › History row (the trunk() alias).
  ///
  /// In en, this message translates to:
  /// **'Trunk'**
  String get settingsTrunk;

  /// The Trunk choice while the alias is unset: jj's builtin trunk().
  ///
  /// In en, this message translates to:
  /// **'jj’s default'**
  String get settingsTrunkDefault;

  /// The row and field for a trunk() revset of one's own.
  ///
  /// In en, this message translates to:
  /// **'Custom trunk'**
  String get settingsTrunkCustom;

  /// The Trunk select's last choice: opens a field for one's own revset.
  ///
  /// In en, this message translates to:
  /// **'Custom…'**
  String get settingsTrunkCustomEllipsis;

  /// Settings › Project › Identity row: a user.email of the repository's own.
  ///
  /// In en, this message translates to:
  /// **'Use a different email here'**
  String get settingsOwnEmail;

  /// The Use a different email here row's hint.
  ///
  /// In en, this message translates to:
  /// **'For work repositories with their own address.'**
  String get settingsOwnEmailHint;

  /// VoiceOver name of the Use a different email here switch.
  ///
  /// In en, this message translates to:
  /// **'Use a different email'**
  String get settingsOwnEmailSwitch;

  /// Settings › Project › History row, the page it opens, and the window title on it.
  ///
  /// In en, this message translates to:
  /// **'Immutable commits'**
  String get settingsImmutableTitle;

  /// The Immutable commits row's summary while all four built-ins are on.
  ///
  /// In en, this message translates to:
  /// **'jj’s default (trunk, tags, remote bookmarks you don’t track)'**
  String get settingsImmutableSummaryDefault;

  /// Immutable commits summary item.
  ///
  /// In en, this message translates to:
  /// **'trunk'**
  String get settingsImmutableSummaryTrunk;

  /// Immutable commits summary item.
  ///
  /// In en, this message translates to:
  /// **'tags'**
  String get settingsImmutableSummaryTags;

  /// Immutable commits summary item.
  ///
  /// In en, this message translates to:
  /// **'untracked remote bookmarks'**
  String get settingsImmutableSummaryRemoteBookmarks;

  /// Immutable commits summary item.
  ///
  /// In en, this message translates to:
  /// **'untracked remote tags'**
  String get settingsImmutableSummaryRemoteTags;

  /// Immutable commits summary item.
  ///
  /// In en, this message translates to:
  /// **'other people’s changes'**
  String get settingsImmutableSummaryOthers;

  /// Immutable commits summary item.
  ///
  /// In en, this message translates to:
  /// **'a custom revset'**
  String get settingsImmutableSummaryCustom;

  /// Immutable commits summary when nothing is on; root() is jj's revset.
  ///
  /// In en, this message translates to:
  /// **'Only root()'**
  String get settingsImmutableSummaryNone;

  /// The Immutable commits page's sentence under its title.
  ///
  /// In en, this message translates to:
  /// **'jj won’t rewrite these changes or anything below them: no edit, describe, squash, rebase or abandon. New change on top and Revert still work. In the graph they’re hatched.'**
  String get settingsImmutableIntro;

  /// Immutable commits group heading.
  ///
  /// In en, this message translates to:
  /// **'Built in'**
  String get settingsImmutableBuiltIn;

  /// Immutable commits switch row: trunk().
  ///
  /// In en, this message translates to:
  /// **'Trunk'**
  String get settingsImmutableTrunk;

  /// The Trunk switch's hint; trunk() is jj's revset, trunk its current value.
  ///
  /// In en, this message translates to:
  /// **'Your main line. trunk() is {trunk}, set under History.'**
  String settingsImmutableTrunkHint(String trunk);

  /// Immutable commits switch row: tags().
  ///
  /// In en, this message translates to:
  /// **'Tags'**
  String get settingsImmutableTags;

  /// The Tags switch's hint.
  ///
  /// In en, this message translates to:
  /// **'Released versions.'**
  String get settingsImmutableTagsHint;

  /// Immutable commits switch row: untracked_remote_bookmarks().
  ///
  /// In en, this message translates to:
  /// **'Remote bookmarks you don’t track'**
  String get settingsImmutableRemoteBookmarks;

  /// The remote bookmarks switch's hint.
  ///
  /// In en, this message translates to:
  /// **'Fetched, but not yours to rewrite.'**
  String get settingsImmutableRemoteBookmarksHint;

  /// Immutable commits switch row: untracked_remote_tags().
  ///
  /// In en, this message translates to:
  /// **'Remote tags you don’t track'**
  String get settingsImmutableRemoteTags;

  /// The remote tags switch's hint.
  ///
  /// In en, this message translates to:
  /// **'Fetched, but not yours to move.'**
  String get settingsImmutableRemoteTagsHint;

  /// The Tags switch's hint naming this repository's tags (or settingsImmutableNoneHere).
  ///
  /// In en, this message translates to:
  /// **'Released versions: {names}.'**
  String settingsImmutableTagsNamed(String names);

  /// The remote bookmarks switch's hint naming this repository's untracked remote bookmarks (or settingsImmutableNoneHere).
  ///
  /// In en, this message translates to:
  /// **'Fetched, but not yours to rewrite: {names}.'**
  String settingsImmutableRemoteBookmarksNamed(String names);

  /// The remote tags switch's hint naming this repository's untracked remote tags.
  ///
  /// In en, this message translates to:
  /// **'Fetched, but not yours to move: {names}.'**
  String settingsImmutableRemoteTagsNamed(String names);

  /// The remote tags switch's hint when this repository has no untracked remote tags.
  ///
  /// In en, this message translates to:
  /// **'None in this repository.'**
  String get settingsImmutableRemoteTagsNone;

  /// Stands in a hint's name list when this repository has no match.
  ///
  /// In en, this message translates to:
  /// **'none here'**
  String get settingsImmutableNoneHere;

  /// The last item of a shortened name list: how many names it leaves out.
  ///
  /// In en, this message translates to:
  /// **'{count} more'**
  String settingsImmutableMore(int count);

  /// Immutable commits group heading.
  ///
  /// In en, this message translates to:
  /// **'Also immutable'**
  String get settingsImmutableAlso;

  /// Immutable commits switch row: everything after trunk() that is not yours.
  ///
  /// In en, this message translates to:
  /// **'Other people’s changes'**
  String get settingsImmutableOthers;

  /// The Other people's changes switch's hint.
  ///
  /// In en, this message translates to:
  /// **'Everything after trunk() that isn’t yours. What’s below them is locked too, your own changes included.'**
  String get settingsImmutableOthersHint;

  /// Immutable commits row: bookmark chips.
  ///
  /// In en, this message translates to:
  /// **'Bookmarks'**
  String get settingsImmutableBookmarks;

  /// The Bookmarks row's hint.
  ///
  /// In en, this message translates to:
  /// **'A release or shared bookmark you never rewrite.'**
  String get settingsImmutableBookmarksHint;

  /// The add chip that opens a menu of the other bookmarks.
  ///
  /// In en, this message translates to:
  /// **'Bookmark…'**
  String get settingsImmutableAddBookmark;

  /// Immutable commits row: a revset of one's own.
  ///
  /// In en, this message translates to:
  /// **'Custom revset'**
  String get settingsImmutableCustom;

  /// The Custom revset row's hint.
  ///
  /// In en, this message translates to:
  /// **'Joined with |. Written once jj resolves it.'**
  String get settingsImmutableCustomHint;

  /// Immutable commits group heading over the TOML as written.
  ///
  /// In en, this message translates to:
  /// **'Result'**
  String get settingsImmutableResult;

  /// After the bold count of immutable changes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{change is immutable} other{changes are immutable}}'**
  String settingsImmutableCountSuffix(int count);

  /// The note under the result; root is jj's root() revset, flag jj's --ignore-immutable.
  ///
  /// In en, this message translates to:
  /// **'{root} is always immutable. To rewrite one anyway, jj needs {flag}.'**
  String settingsImmutableRootNote(String root, String flag);

  /// Unsets the repository's immutable_heads() alias.
  ///
  /// In en, this message translates to:
  /// **'Reset to jj’s default'**
  String get settingsImmutableReset;
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
