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
  String get graphReloadTooltip => 'Reload (⌘R)';

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
  String stackLabel(int n, String subject, String range) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n changes',
      one: '1 change',
    );
    return '$_temp0, $subject, $range';
  }

  @override
  String stackExpandHint(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Click to expand $n changes',
      one: 'Click to expand 1 change',
    );
    return '$_temp0';
  }

  @override
  String stackCollapseTooltip(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Collapse $n changes into a stack',
      one: 'Collapse 1 change into a stack',
    );
    return '$_temp0';
  }

  @override
  String get graphCardWidth => 'Card width';

  @override
  String get graphCardWidthUnit => 'px';

  @override
  String get graphMoreSettings => 'Appearance, diffs and more';

  @override
  String get graphSearchLabel => 'Search the graph';

  @override
  String get graphSearchMenu => 'Search menu';

  @override
  String get graphSearchSuggestions => 'Suggestions';

  @override
  String get graphSearchPlaceholder => 'Search changes, bookmarks, authors, files…';

  @override
  String get graphSearchPlaceholderShort => 'Search…';

  @override
  String graphSearchScope(String scope) {
    String _temp0 = intl.Intl.selectLogic(
      scope,
      {
        'change': 'Change',
        'bookmark': 'Bookmark',
        'author': 'Author',
        'file': 'File',
        'description': 'Description',
        'other': 'Any',
      },
    );
    return '$_temp0';
  }

  @override
  String graphSearchScopePlural(String scope) {
    String _temp0 = intl.Intl.selectLogic(
      scope,
      {
        'change': 'changes',
        'bookmark': 'bookmarks',
        'author': 'authors',
        'file': 'files',
        'description': 'descriptions',
        'other': 'results',
      },
    );
    return '$_temp0';
  }

  @override
  String graphSearchScopeGroup(String scope) {
    String _temp0 = intl.Intl.selectLogic(
      scope,
      {
        'change': 'Changes',
        'bookmark': 'Bookmarks',
        'author': 'Authors',
        'file': 'Files',
        'description': 'Descriptions',
        'other': 'Results',
      },
    );
    return '$_temp0';
  }

  @override
  String graphSearchScopePlaceholder(String scope) {
    String _temp0 = intl.Intl.selectLogic(
      scope,
      {
        'change': 'Change ID, commit ID or description',
        'bookmark': 'Bookmark name',
        'author': 'Author name',
        'file': 'Path, folder or glob',
        'description': 'Text in descriptions',
        'other': 'Search changes, bookmarks, authors, files…',
      },
    );
    return '$_temp0';
  }

  @override
  String graphSearchScopePlaceholderShort(String scope) {
    String _temp0 = intl.Intl.selectLogic(
      scope,
      {
        'change': 'Change ID or hash',
        'bookmark': 'Bookmark name',
        'author': 'Author name',
        'file': 'Path or glob',
        'description': 'Text',
        'other': 'Search…',
      },
    );
    return '$_temp0';
  }

  @override
  String get graphSearchChangeDetail => 'change ID · commit ID · description';

  @override
  String get graphSearchBookmarkDetail => 'name';

  @override
  String graphSearchBackToDefault(String name) {
    return 'Back to the default search — $name';
  }

  @override
  String get graphSearchClear => 'Clear';

  @override
  String get graphSearchDefaultTag => 'Default';

  @override
  String get graphSearchLogDetail => 'Your mutable changes plus trunk context';

  @override
  String get graphSearchAllDetail => 'Every visible commit, incl. immutable history';

  @override
  String get graphSearchGoTo => 'Go to';

  @override
  String get graphSearchGoToHint => 'selects a change · graph stays';

  @override
  String get graphSearchFilterBy => 'Filter by';

  @override
  String get graphSearchFilterByHint => 'redraws the graph';

  @override
  String get graphSearchEditConfigurations => 'Edit Configurations…';

  @override
  String graphSearchBroken(String message) {
    return 'Fails: $message';
  }

  @override
  String get graphSearchRecent => 'Recent';

  @override
  String graphSearchRecentIn(String scope) {
    return 'Recent $scope';
  }

  @override
  String graphSearchMore(int count, String scope) {
    return '$count more in $scope';
  }

  @override
  String graphSearchFallback(String scope, String query) {
    return 'No $scope matches “$query” — found elsewhere:';
  }

  @override
  String graphSearchNothing(String query) {
    return 'Nothing matches “$query”.';
  }

  @override
  String graphSearchNothingAnywhere(String query) {
    return 'Nothing matches “$query” — in any scope.';
  }

  @override
  String get graphSearchNotInView => 'not in view';

  @override
  String get graphSearchYou => 'you';

  @override
  String graphSearchAuthorsContaining(String value) {
    return 'Authors containing $value';
  }

  @override
  String graphSearchDescriptionsContaining(String value) {
    return 'Descriptions containing $value';
  }

  @override
  String graphSearchQuoted(String value) {
    return '“$value”';
  }

  @override
  String graphSearchCount(int count, String number) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$number changes',
      one: '1 change',
    );
    return '$_temp0';
  }

  @override
  String graphSearchCountCapped(String number) {
    return '$number+ changes';
  }

  @override
  String graphSearchNarrows(String scope) {
    return 'Narrows the search to $scope';
  }

  @override
  String get graphSearchSelects => 'Selects the change — the graph stays as it is';

  @override
  String graphSearchSwitches(String all) {
    return 'Not in this view — switches to $all and selects it';
  }

  @override
  String get graphSearchKeyShow => 'Show';

  @override
  String get graphSearchKeySelect => 'Select';

  @override
  String get graphSearchKeyFilter => 'Filter';

  @override
  String graphSearchSearchIn(String scope) {
    return 'Search in: $scope';
  }

  @override
  String graphSearchShowing(String name) {
    return 'Showing $name';
  }

  @override
  String graphSearchDefault(String name) {
    return 'Default search: $name';
  }

  @override
  String get newChange => 'New change';

  @override
  String get newChangeTooltip => 'jj new — start a new change on top of @';

  @override
  String get inspectorLabel => 'Change details';

  @override
  String get inspectorWidth => 'Inspector width';

  @override
  String get inspectorClose => 'Close (Esc)';

  @override
  String get inspectorFlagWorkingCopy => '@ Working copy';

  @override
  String get inspectorFlagImmutable => 'Immutable';

  @override
  String get inspectorFlagEmpty => 'Empty';

  @override
  String get inspectorFlagMerge => 'Merge';

  @override
  String get inspectorFlagConflict => 'Conflict';

  @override
  String get inspectorDescribePlaceholder => 'Describe this change…';

  @override
  String get inspectorNoDescription => '(no description set)';

  @override
  String get inspectorDescribeHint => 'Edit description';

  @override
  String get inspectorSummary => 'Summary';

  @override
  String get inspectorDetails => 'Details (optional)';

  @override
  String get inspectorCancel => 'Cancel';

  @override
  String get inspectorSave => 'Save';

  @override
  String inspectorParents(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'parents',
      one: 'parent',
    );
    return '$_temp0';
  }

  @override
  String get inspectorNewOnTop => 'New change on top';

  @override
  String get inspectorEdit => 'Edit';

  @override
  String get inspectorSquash => 'Squash into parent';

  @override
  String get inspectorSquashLater => 'Comes with the commit composer';

  @override
  String get inspectorAbandon => 'Abandon';

  @override
  String get inspectorBusy => 'Another action is running';

  @override
  String get inspectorChanges => 'Changes';

  @override
  String inspectorFileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files',
      one: '1 file',
    );
    return '$_temp0';
  }

  @override
  String get inspectorEmptyWorkingCopy => 'No changes yet — whatever you edit in your editor lands here.';

  @override
  String get inspectorEmptyMerge => 'A merge — no changes of its own.';

  @override
  String get inspectorEmptyRoot => 'The root of all history.';

  @override
  String get inspectorEmpty => 'This change has no file changes.';

  @override
  String get inspectorBookmarkLocal => 'local';

  @override
  String get inspectorBookmarkRemote => 'remote';

  @override
  String toastAbandoned(String changes) {
    return 'Abandoned $changes';
  }

  @override
  String toastReverted(String change, String inverse) {
    return 'Reverted $change — $inverse undoes it';
  }

  @override
  String toastRevertedAlone(String change) {
    return 'Reverted $change';
  }

  @override
  String toastSquashed(String source, String destination) {
    return 'Squashed $source into $destination';
  }

  @override
  String toastBookmarkCreated(String names, String target) {
    return 'Created $names on $target';
  }

  @override
  String toastBookmarkDeleted(String names) {
    return 'Deleted $names';
  }

  @override
  String toastBookmarkMoved(String names, String target) {
    return 'Moved $names to $target';
  }

  @override
  String toastBookmarkRenamed(String oldName, String newName) {
    return 'Renamed $oldName to $newName';
  }

  @override
  String toastBookmarkTracked(String name) {
    return 'Started tracking $name';
  }

  @override
  String toastBookmarkUntracked(String name) {
    return 'Stopped tracking $name';
  }

  @override
  String toastUndid(String command) {
    return 'Undid $command';
  }

  @override
  String toastRedid(String command) {
    return 'Redid $command';
  }

  @override
  String get toastUndo => 'Undo';

  @override
  String get toastRedo => 'Redo';

  @override
  String get toastRetry => 'Retry';

  @override
  String get toastNothingUndone => 'Nothing undone — another operation came after it';

  @override
  String get toastNothingRedone => 'Nothing redone — another operation came after it';

  @override
  String toastStaleUpdateFailed(String reason) {
    return 'Updating the working copy failed — $reason';
  }

  @override
  String toastOpened(String name) {
    return 'Opened $name';
  }

  @override
  String toastListAnd(String head, String last) {
    return '$head and $last';
  }

  @override
  String toastListComma(String head, String next) {
    return '$head, $next';
  }

  @override
  String get menuFile => 'File';

  @override
  String get menuEdit => 'Edit';

  @override
  String get menuView => 'View';

  @override
  String get menuChange => 'Change';

  @override
  String get menuGo => 'Go';

  @override
  String get menuWindow => 'Window';

  @override
  String get menuHelp => 'Help';

  @override
  String get menuOpenRecent => 'Open Recent';

  @override
  String get menuCloseWindow => 'Close Window';

  @override
  String menuUndo(String action) {
    return 'Undo $action';
  }

  @override
  String get menuUndoPlain => 'Undo';

  @override
  String menuRedo(String action) {
    return 'Redo $action';
  }

  @override
  String get menuRedoPlain => 'Redo';

  @override
  String get menuCut => 'Cut';

  @override
  String get menuCopy => 'Copy';

  @override
  String get menuPaste => 'Paste';

  @override
  String get menuSelectAll => 'Select All';

  @override
  String get menuFind => 'Find';

  @override
  String get menuFree => 'Free';

  @override
  String get menuCompact => 'Compact';

  @override
  String get menuDetailedCards => 'Detailed Cards';

  @override
  String get menuGroupStacks => 'Group Stacks';

  @override
  String get menuEditConfigurations => 'Edit Configurations…';

  @override
  String get menuShowMinimap => 'Show Minimap';

  @override
  String get menuReload => 'Reload';

  @override
  String get menuNewChange => 'New Change';

  @override
  String get menuDescribe => 'Describe…';

  @override
  String menuDescribeTarget(String target) {
    return 'Describe $target';
  }

  @override
  String get menuChangeEdit => 'Edit';

  @override
  String menuChangeEditTarget(String target) {
    return 'Edit $target';
  }

  @override
  String get menuSquash => 'Squash into Parent';

  @override
  String menuSquashTarget(String target) {
    return 'Squash $target into Parent';
  }

  @override
  String get menuRevert => 'Revert';

  @override
  String menuRevertTarget(String target) {
    return 'Revert $target';
  }

  @override
  String get menuAbandon => 'Abandon';

  @override
  String menuAbandonTarget(String target) {
    return 'Abandon $target';
  }

  @override
  String menuBookmarkCreate(String names) {
    return 'Create Bookmark $names';
  }

  @override
  String menuBookmarkDelete(String names) {
    return 'Delete Bookmark $names';
  }

  @override
  String menuBookmarkMove(String names) {
    return 'Move Bookmark $names';
  }

  @override
  String menuBookmarkRename(String names) {
    return 'Rename Bookmark $names';
  }

  @override
  String menuBookmarkTrack(String name) {
    return 'Track $name';
  }

  @override
  String menuBookmarkUntrack(String name) {
    return 'Untrack $name';
  }

  @override
  String get menuFetch => 'Fetch';

  @override
  String get menuPush => 'Push…';

  @override
  String get menuGoSelection => 'Selection';

  @override
  String get menuGoWorkingCopy => 'Working Copy (@)';

  @override
  String get menuGoParent => 'Parent';

  @override
  String get menuGoChild => 'Child';

  @override
  String menuAppHelp(String app) {
    return '$app Help';
  }

  @override
  String menuToolDocumentation(String tool) {
    return '$tool Documentation ↗';
  }

  @override
  String menuRestoreOperation(String operation) {
    return 'Restore to $operation';
  }

  @override
  String get undoTimelineTitle => 'Undo Timeline';

  @override
  String get undoTimelineUndo => 'Undo';

  @override
  String get undoTimelineRedo => 'Redo';

  @override
  String get undoTimelineRestore => 'Restore to here';

  @override
  String get undoTimelineShowChanges => 'Show changes';

  @override
  String get undoTimelineShowLater => 'Not available yet';

  @override
  String get undoTimelineNoRunner => 'Available once the commit graph is shown';

  @override
  String get undoTimelineBusy => 'Another action is running';

  @override
  String get undoTimelineRootParent => 'Undoing it would restore the root operation';

  @override
  String get undoTimelineNothingToRedo => 'Nothing to redo';

  @override
  String undoTimelineLoadFailed(String detail) {
    return 'The operation log could not be read: $detail';
  }

  @override
  String undoTimelineRow(String description, String when) {
    return '$description, $when';
  }

  @override
  String undoTimelineRowWorkspace(String description, String when, String workspace) {
    return '$description, $when, workspace $workspace';
  }

  @override
  String get bookmarksTitle => 'Bookmarks';

  @override
  String bookmarksMore(int count) {
    return '+$count more';
  }

  @override
  String bookmarksEmpty(String command) {
    return 'No bookmarks yet. Create one with `$command`.';
  }

  @override
  String bookmarksLoadFailed(String detail) {
    return 'The bookmarks could not be read: $detail';
  }

  @override
  String bookmarksRow(String name, String state) {
    return '$name — $state';
  }

  @override
  String get bookmarksStateLocalShort => 'local';

  @override
  String get bookmarksStateRemoteShort => 'remote';

  @override
  String get bookmarksStateDeletedShort => 'deleted';

  @override
  String get bookmarksStateNotCreatedShort => 'not created yet';

  @override
  String get bookmarksStateDivergentShort => 'divergent';

  @override
  String get bookmarksStateLocal => 'local only';

  @override
  String get bookmarksStateRemote => 'remote only, not tracked';

  @override
  String get bookmarksStateDeleted => 'deleted, still tracking a remote';

  @override
  String get bookmarksStateNotCreated => 'not created on the remote yet';

  @override
  String get bookmarksStateConflicted => 'conflicted';

  @override
  String get bookmarksStateDivergent => 'divergent';

  @override
  String bookmarksStateSynced(String other) {
    return 'in sync with $other';
  }

  @override
  String bookmarksStateAhead(String other, String count) {
    return 'ahead of $other by $count';
  }

  @override
  String bookmarksStateBehind(String other, String count) {
    return 'behind $other by $count';
  }

  @override
  String bookmarksStateDiverged(String other) {
    return 'diverged from $other';
  }

  @override
  String bookmarksStateNotPushed(String other) {
    return 'not on $other yet';
  }

  @override
  String get bookmarksTrack => 'Track';

  @override
  String get bookmarksUntrack => 'Untrack';

  @override
  String get bookmarksBusy => 'Another action is running';
}
