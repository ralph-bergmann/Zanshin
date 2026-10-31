// ignore_for_file: deprecated_member_use

// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get bootFailed => 'Zanshin could not start.';

  @override
  String get bootLoadingSettings => 'Loading settings…';

  @override
  String get bootReadingShell => 'Reading the shell environment…';

  @override
  String get bootStarting => 'Starting Zanshin…';

  @override
  String get splashTagline => 'JUJUTSU CLIENT';

  @override
  String versionBuild(String version, String build) {
    return '$version · Build $build';
  }

  @override
  String jjLibVersion(String version) {
    return 'jj-lib $version';
  }

  @override
  String get projectsTitle => 'Projects';

  @override
  String get projectsSettingsTooltip => 'Settings — ⌘, (the tab shown last)';

  @override
  String get settingsEllipsis => 'Settings…';

  @override
  String get projectsSearchPlaceholder => 'Search projects, paths…';

  @override
  String get projectsAddDirectory => 'Add directory';

  @override
  String get projectsAddPrompt => 'Add';

  @override
  String get projectsClone => 'Clone…';

  @override
  String get projectsNewGroup => 'New group';

  @override
  String projectsPathMissing(String path) {
    return '$path does not exist.';
  }

  @override
  String get projectsConversionFailed => 'Conversion failed';

  @override
  String get projectsInitFailed => 'Creating a repository failed';

  @override
  String get projectsCloneFailed => 'Clone failed';

  @override
  String projectsOpenFailed(String name) {
    return 'Could not open $name';
  }

  @override
  String projectsConverted(String name) {
    return 'Converted $name';
  }

  @override
  String projectsCreated(String name) {
    return 'Created a repository in $name';
  }

  @override
  String projectsCloned(String name) {
    return 'Cloned $name';
  }

  @override
  String projectsOpened(String name) {
    return 'Opened $name';
  }

  @override
  String deleteGroupTitle(String name) {
    return 'Delete the group $name?';
  }

  @override
  String get deleteGroup => 'Delete group';

  @override
  String get deleteGroupBody => 'Its projects and groups take its place; nothing leaves the list.';

  @override
  String removeProjectTitle(String name) {
    return 'Remove $name from the list?';
  }

  @override
  String get removeProjectConfirm => 'Remove';

  @override
  String removeProjectBody(String path) {
    return '$path stays on disk; only the list forgets it.';
  }

  @override
  String get cloneUrl => 'Repository URL';

  @override
  String get cloneDestination => 'Destination';

  @override
  String get cloneChoose => 'Choose…';

  @override
  String get cloneChoosePrompt => 'Choose';

  @override
  String get cloneCancel => 'Cancel';

  @override
  String get cloneSubmit => 'Clone';

  @override
  String convertTitle(String name) {
    return 'Convert $name to a jj repository?';
  }

  @override
  String get convertConfirm => 'Convert';

  @override
  String convertBody(String path) {
    return '$path stays a Git repository; jj joins it and shares its working copy.';
  }

  @override
  String convertBodyInside(String inside, String path) {
    return '$inside lies inside the Git repository at $path. It stays a Git repository; jj joins it and shares its working copy.';
  }

  @override
  String initTitle(String name) {
    return 'Create a jj repository in $name?';
  }

  @override
  String get initConfirm => 'Create';

  @override
  String initBody(String path) {
    return '$path becomes a jj repository, its Git store inside .jj.';
  }

  @override
  String enclosingTitle(String name) {
    return 'Add the enclosing repository $name?';
  }

  @override
  String get enclosingConfirm => 'Add';

  @override
  String enclosingBody(String inside, String path) {
    return '$inside lies inside the jj repository at $path.';
  }

  @override
  String get identityCaption => 'Identity';

  @override
  String get setIdentity => 'Set identity…';

  @override
  String get noticeDismiss => 'Dismiss';

  @override
  String get dropToAddDirectory => 'Drop to add directory';

  @override
  String get treeLabel => 'Projects';

  @override
  String get treeEmpty => 'No projects yet. Add a directory or drop a folder here.';

  @override
  String treeNoResults(String query) {
    return 'No projects match “$query”';
  }

  @override
  String get treeDropHint => 'Drop between rows or on a group';

  @override
  String get treeTopLevel => 'To the top level';

  @override
  String treeInto(String name) {
    return 'Into $name';
  }

  @override
  String get renameGroup => 'Rename group';

  @override
  String get groupNamePlaceholder => 'Group name';

  @override
  String groupCount(int projects, int groups) {
    String _temp0 = intl.Intl.pluralLogic(
      groups,
      locale: localeName,
      other: ' · $groups groups',
      one: ' · 1 group',
      zero: '',
    );
    return '$projects$_temp0';
  }

  @override
  String get projectOpen => 'open';

  @override
  String get menuOpen => 'Open';

  @override
  String get menuRevealInFinder => 'Reveal in Finder';

  @override
  String get menuRemoveFromList => 'Remove from list';

  @override
  String get menuRename => 'Rename…';

  @override
  String get menuMoveToGroup => 'Move to group';

  @override
  String get menuTopLevel => 'Top level';

  @override
  String get menuNewGroup => 'New group…';

  @override
  String get moreTooltip => 'More…';

  @override
  String get moreLabel => 'More';

  @override
  String get statusClean => 'clean';

  @override
  String get statusDirty => 'uncommitted changes';

  @override
  String get statusConflict => 'conflict';

  @override
  String get statusMissing => 'path missing';

  @override
  String get statusStale => 'working copy is stale';

  @override
  String get statusAhead => 'ahead of remote';

  @override
  String get statusBehind => 'behind remote';

  @override
  String get statusDiverged => 'diverged';

  @override
  String get lastOpenedNow => 'now';

  @override
  String lastOpenedMinutes(int n) {
    return '${n}m ago';
  }

  @override
  String lastOpenedHours(int n) {
    return '${n}h ago';
  }

  @override
  String get lastOpenedYesterday => 'yesterday';

  @override
  String lastOpenedDays(int n) {
    return '${n}d ago';
  }

  @override
  String lastOpenedWeeks(int n) {
    return '${n}w ago';
  }

  @override
  String lastOpenedMonths(int n) {
    return '${n}mo ago';
  }

  @override
  String lastOpenedYears(int n) {
    return '${n}y ago';
  }

  @override
  String get capsuleRecent => 'Recent';

  @override
  String get capsuleAllProjects => 'All Projects…';

  @override
  String get capsuleProjectSettings => 'Project Settings…';

  @override
  String get capsuleMenuLabel => 'Project';

  @override
  String get railLabel => 'Panels';

  @override
  String get topBarView => 'View';

  @override
  String get panelWidth => 'Panel width';

  @override
  String get panelClose => 'Close';

  @override
  String graphLoadFailed(String code) {
    return 'The graph could not be loaded ($code).';
  }

  @override
  String get graphRetry => 'Retry';

  @override
  String get graphEmpty => 'No changes match this revset.';

  @override
  String get staleTitle => 'Working copy is stale';

  @override
  String get staleUpdate => 'Update working copy';

  @override
  String staleCopy(String command) {
    return 'Copy — $command';
  }

  @override
  String get dayToday => 'Today';

  @override
  String get dayYesterday => 'Yesterday';

  @override
  String get relativeNow => 'now';

  @override
  String relativeMinutes(int n) {
    return '${n}m';
  }

  @override
  String relativeHours(int n) {
    return '${n}h';
  }

  @override
  String relativeDays(int n) {
    return '${n}d';
  }

  @override
  String spokenMinutesAgo(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n minutes ago',
      one: '1 minute ago',
    );
    return '$_temp0';
  }

  @override
  String spokenHoursAgo(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n hours ago',
      one: '1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String spokenDaysAgo(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n days ago',
      one: '1 day ago',
    );
    return '$_temp0';
  }

  @override
  String get cardWorkingCopy => 'Working copy';

  @override
  String cardWorkingCopyOf(String name) {
    return 'Working copy of $name';
  }

  @override
  String cardOtherWorkingCopy(String names) {
    return 'working copy of $names';
  }

  @override
  String get cardImmutable => 'Immutable';

  @override
  String get cardNoDescription => 'no description';

  @override
  String get cardEmpty => 'empty';

  @override
  String get cardConflict => 'conflict';

  @override
  String get cardMerge => 'merge';

  @override
  String get cardHidden => 'hidden';

  @override
  String get cardDivergent => 'divergent';

  @override
  String get cardActions => 'Actions';

  @override
  String get cardAddBookmark => 'Add bookmark';

  @override
  String cardBookmarks(String names) {
    return 'Bookmarks: $names';
  }

  @override
  String get cardActionsTooltip => 'Actions (or right-click the card)';

  @override
  String get peekImmutable => 'Immutable';

  @override
  String get peekHintMutable => 'Click: details · Double-click: jj edit';

  @override
  String get peekHintImmutable => 'Click: details';

  @override
  String get peekHintWorkingCopy => 'Working copy (@) · Click for details';

  @override
  String get atPillLabel => 'Working copy';

  @override
  String get atPillTooltip => 'Scroll to the working copy';

  @override
  String atPillSemantics(String direction) {
    String _temp0 = intl.Intl.selectLogic(
      direction,
      {
        'up': 'Working copy, above',
        'down': 'Working copy, below',
        'left': 'Working copy, left',
        'other': 'Working copy, right',
      },
    );
    return '$_temp0';
  }

  @override
  String graphCountFiltered(String shown, int total) {
    return '$shown of $total';
  }

  @override
  String graphCountAll(int count, String number) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$number changes',
      one: '$number change',
    );
    return '$_temp0';
  }

  @override
  String graphCountTooltip(int shown, int total) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$shown of $total changes shown',
      one: '$shown of 1 change shown',
    );
    return '$_temp0';
  }

  @override
  String get graphViewOptions => 'View options';

  @override
  String get graphViewTitle => 'Graph view';

  @override
  String get graphLayout => 'Layout';

  @override
  String get graphLayoutFree => 'Free';

  @override
  String get graphLayoutFreeTooltip => 'Rows follow commit time';

  @override
  String get graphLayoutCompact => 'Compact';

  @override
  String get graphLayoutCompactTooltip => 'Rows = dependency depth';

  @override
  String get graphDetailedCards => 'Detailed cards';

  @override
  String get graphGroupStacks => 'Group stacks';

  @override
  String get graphGroupStacksTooltip => 'Collapse linear runs of changes into one stack card';

  @override
  String get graphCardWidth => 'Card width';

  @override
  String get graphCardWidthUnit => 'px';

  @override
  String get graphMoreSettings => 'Appearance, diffs and more';

  @override
  String get newChange => 'New change';

  @override
  String get newChangeTooltip => 'jj new — start a new change on top of @';
}
