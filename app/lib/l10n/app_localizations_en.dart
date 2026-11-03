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
  String get cloneProgress => 'Cloning';

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
  String get statusSyncing => 'syncing';

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
  String get graphMinimap => 'Minimap';

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
  String peekImmutableReason(String label, String reason) {
    return '$label · $reason';
  }

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
  String get gapElided => 'elided';

  @override
  String get gapTitleIndirect => 'Commits hidden between these changes';

  @override
  String get gapTitleHiddenMerge => 'A hidden merge sits below this change';

  @override
  String get gapTitleMissing => 'History continues outside this revset';

  @override
  String get gapHiddenCommits => 'Hidden commits';

  @override
  String get gapOlderHistory => 'Older history not shown';

  @override
  String get gapParentNotInRevset => 'parent, not in revset';

  @override
  String get gapDescIndirect =>
      'The dashed edge skips commits the revset doesn\'t include and links to the nearest visible ancestor.';

  @override
  String get gapDescHiddenMerge =>
      'The only parent is hidden and is itself a merge, so the gap leads to two visible ancestors.';

  @override
  String get gapDescMissing => 'No ancestor reached through this parent is part of the current revset.';

  @override
  String gapShowIn(String revset) {
    return 'Show in $revset';
  }

  @override
  String get gapShowInHint => 'switches revset · centers here';

  @override
  String gapCount(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n gaps',
      one: '1 gap',
    );
    return '$_temp0';
  }

  @override
  String get gapLegendTitle => 'This revset hides part of the history';

  @override
  String get gapLegendSolid => 'Solid';

  @override
  String get gapLegendSolidText => 'direct parent';

  @override
  String get gapLegendDashed => 'Dashed';

  @override
  String get gapLegendDashedText => 'commits in between are hidden';

  @override
  String get gapLegendEnd => 'End';

  @override
  String get gapLegendEndText => 'older history isn\'t in the revset';

  @override
  String gapLegendTimes(int n) {
    return '$n×';
  }

  @override
  String get gapLegendNote => 'Stacks never span a gap. Hover a marker for details.';

  @override
  String gapLegendShow(String revset) {
    return 'Show $revset';
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
  String get inspectorCopyId => 'Click to copy';

  @override
  String get inspectorIdCopied => 'Copied';

  @override
  String get inspectorCopyIdHint => 'Copies the full id';

  @override
  String get inspectorIdCopyFailed => 'Couldn\'t copy. Select the id to copy it.';

  @override
  String get inspectorFlagWorkingCopy => '@ Working copy';

  @override
  String get inspectorFlagImmutable => 'Immutable';

  @override
  String inspectorFlagImmutableReason(String reason) {
    return 'Immutable · $reason';
  }

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
  String get inspectorSquashConfirm => 'Squash';

  @override
  String get inspectorSelectAll => 'Select all';

  @override
  String get inspectorDeselectAll => 'Deselect all';

  @override
  String get inspectorCommit => 'Commit';

  @override
  String get inspectorSplit => 'Split';

  @override
  String get inspectorComposerSummaryAt => 'Summary of what you did';

  @override
  String get inspectorComposerSummarySplit => 'Summary of the selected changes';

  @override
  String get inspectorComposerNewWorkingCopy => 'New working copy';

  @override
  String get inspectorComposerStays => 'stays here to keep working';

  @override
  String get inspectorComposerRest => 'Rest';

  @override
  String inspectorComposerKeeps(String subject) {
    return 'keeps “$subject”';
  }

  @override
  String get inspectorComposerSelected => 'Selected';

  @override
  String get inspectorComposerEmpty => 'empty';

  @override
  String get inspectorComposerNothingYet => 'nothing yet';

  @override
  String get inspectorComposerNoDescription => 'no description yet';

  @override
  String inspectorComposerMessage(String summary) {
    return '“$summary”';
  }

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
  String inspectorViewedCount(int viewed, int total) {
    return '$viewed/$total viewed';
  }

  @override
  String inspectorViewedCountTooltip(int viewed, int total) {
    return '$viewed of $total files viewed';
  }

  @override
  String get inspectorAllViewed => 'all viewed';

  @override
  String get inspectorMarkAllViewed => 'Mark all';

  @override
  String get inspectorResetViewed => 'Reset';

  @override
  String get inspectorViewed => 'Viewed';

  @override
  String get inspectorMarkViewed => 'Mark as viewed';

  @override
  String get inspectorMarkNotViewed => 'Mark as not viewed';

  @override
  String get inspectorViewedFolded => 'Viewed — diff folded away. Click to show it again.';

  @override
  String get inspectorDiffLayout => 'Diff layout';

  @override
  String get inspectorDiffUnified => 'Unified';

  @override
  String get inspectorDiffSideBySide => 'Side by side';

  @override
  String get inspectorDiffBinary => 'Binary file';

  @override
  String get inspectorDiffModeChange => 'Executable bit changed';

  @override
  String get inspectorDiffNoLines => 'No line changes';

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
  String toastCommitted(String change, String subject) {
    return 'Committed $change · “$subject”';
  }

  @override
  String toastCommittedAlone(String change) {
    return 'Committed $change';
  }

  @override
  String toastSplit(String change, String rest) {
    return 'Split $change — the rest is now $rest';
  }

  @override
  String toastSplitAlone(String change) {
    return 'Split $change';
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
  String toastRebasedOnto(String source, String target) {
    return 'Moved $source onto $target';
  }

  @override
  String toastRebasedAfter(String source, String target) {
    return 'Inserted $source after $target';
  }

  @override
  String toastRebasedBefore(String source, String target) {
    return 'Inserted $source before $target';
  }

  @override
  String toastMerged(String first, String second) {
    return 'Merged $first and $second in a new change';
  }

  @override
  String toastDuplicated(String source, String target) {
    return 'Duplicated $source onto $target';
  }

  @override
  String get dropMoveHere => 'Move here';

  @override
  String get dropMoveOnly => 'Move only this change';

  @override
  String get dropInsertAfter => 'Insert after';

  @override
  String get dropInsertBefore => 'Insert before';

  @override
  String get dropSquash => 'Squash into this change';

  @override
  String get dropNewMerge => 'New merge change';

  @override
  String get dropDuplicate => 'Duplicate here';

  @override
  String dropMoveBookmark(String name) {
    return 'Move $name here';
  }

  @override
  String get dropBackwards => 'backwards';

  @override
  String get dropMenuLabel => 'Drop actions';

  @override
  String get dragHintChange => 'Drop on a change';

  @override
  String get dragHintBookmark => 'Drop on the change it should point to';

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
  String menuRebaseOnto(String source, String target) {
    return 'Move $source onto $target';
  }

  @override
  String menuRebaseAfter(String source, String target) {
    return 'Insert $source after $target';
  }

  @override
  String menuRebaseBefore(String source, String target) {
    return 'Insert $source before $target';
  }

  @override
  String menuDuplicateOnto(String source, String target) {
    return 'Duplicate $source onto $target';
  }

  @override
  String menuNewMerge(String first, String second) {
    return 'New Merge Change of $first and $second';
  }

  @override
  String menuCommitTarget(String target) {
    return 'Commit $target';
  }

  @override
  String menuSplitTarget(String target) {
    return 'Split $target';
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
  String get operationChangesBack => 'Back';

  @override
  String get operationChangesMerge => 'This operation merges several operations; jj shows no changes for it.';

  @override
  String get operationChangesNone => 'jj shows no changes for this operation.';

  @override
  String get operationChangesNoFiles => 'No file changes';

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

  @override
  String get cardMenuNewOnTop => 'New change on top';

  @override
  String get cardMenuInsertAfter => 'Insert after';

  @override
  String get cardMenuInsertBefore => 'Insert before';

  @override
  String get cardMenuEdit => 'Edit';

  @override
  String get cardMenuEditAlready => 'Already the working copy';

  @override
  String get cardMenuDescribe => 'Describe…';

  @override
  String get cardMenuSquash => 'Squash into parent';

  @override
  String get cardMenuSquashMerge => 'A merge has more than one parent';

  @override
  String get cardMenuSquashParentImmutable => 'The parent is immutable';

  @override
  String get cardMenuCopy => 'Copy';

  @override
  String get cardMenuCopyChangeId => 'Change id';

  @override
  String get cardMenuCopyDescription => 'Description';

  @override
  String get cardMenuRevert => 'Revert';

  @override
  String get cardMenuRevertAt => 'The revert lands below @ — @ itself can\'t be reverted';

  @override
  String get cardMenuRevertNotAncestor => 'The revert lands below @ — only changes in @\'s history';

  @override
  String get cardMenuRevertEmpty => 'Nothing to revert — the change is empty';

  @override
  String get cardMenuAbandon => 'Abandon';

  @override
  String get cardMenuImmutable => 'Immutable';

  @override
  String get cardMenuImmutableCommits => 'Immutable commits…';

  @override
  String get cardMenuNoDescription => '(no description set)';

  @override
  String get bookmarkMenuLabel => 'Bookmarks';

  @override
  String get bookmarkMenuRename => 'Rename…';

  @override
  String get bookmarkMenuMoveTo => 'Move to…';

  @override
  String get bookmarkMenuDelete => 'Delete';

  @override
  String get bookmarkMenuReading => 'Reading bookmarks…';

  @override
  String get bookmarkMenuReadFailed => 'Couldn\'t read the bookmarks';

  @override
  String get bookmarkMenuCreate => 'Create bookmark here…';

  @override
  String get bookmarkMenuMoveHere => 'Move existing here…';

  @override
  String nameSheetRenameTitle(String name) {
    return 'Rename $name';
  }

  @override
  String nameSheetMoveToTitle(String name) {
    return 'Move $name to';
  }

  @override
  String get nameSheetCreateTitle => 'Create bookmark here';

  @override
  String get nameSheetMoveHereTitle => 'Move a bookmark here';

  @override
  String get nameSheetNameLabel => 'Bookmark name';

  @override
  String get nameSheetRevisionLabel => 'Revision';

  @override
  String get nameSheetCancel => 'Cancel';

  @override
  String get nameSheetRename => 'Rename';

  @override
  String get nameSheetMove => 'Move';

  @override
  String get nameSheetCreate => 'Create';

  @override
  String get revsetConfigsTitle => 'jj log Configurations';

  @override
  String get revsetConfigsUnnamed => 'Unnamed';

  @override
  String get revsetConfigsNewName => 'New configuration';

  @override
  String revsetConfigsCopyName(String name) {
    return '$name copy';
  }

  @override
  String get revsetConfigsAdd => 'Add configuration';

  @override
  String get revsetConfigsRemove => 'Remove';

  @override
  String get revsetConfigsDuplicate => 'Duplicate';

  @override
  String get revsetConfigsMoveUp => 'Move up';

  @override
  String get revsetConfigsMoveDown => 'Move down';

  @override
  String get revsetConfigsBuiltIn => 'Built-in';

  @override
  String get revsetConfigsCustom => 'Custom';

  @override
  String revsetConfigsBuiltInDetail(String detail) {
    return 'Built-in · $detail';
  }

  @override
  String get revsetConfigsEmpty => 'No custom configurations yet.';

  @override
  String get revsetConfigsName => 'Name';

  @override
  String get revsetConfigsDefaultSearch => 'Default search';

  @override
  String get revsetConfigsDefaultHint => 'Listed first in the search menu — ✕ in the search field returns to it';

  @override
  String get revsetConfigsDefaultLockedHint => 'Used whenever no other configuration is the default';

  @override
  String get revsetConfigsFilters => 'Filters';

  @override
  String get revsetConfigsCombine => 'Combine';

  @override
  String get revsetConfigsMatchAll => 'Match all &';

  @override
  String get revsetConfigsMatchAny => 'Match any |';

  @override
  String get revsetConfigsIs => 'is';

  @override
  String get revsetConfigsNot => '~ not';

  @override
  String get revsetConfigsNotOnTooltip => 'Negated (~) — click to include';

  @override
  String get revsetConfigsNotOffTooltip => 'Click to exclude matches (~)';

  @override
  String get revsetConfigsFunction => 'Function';

  @override
  String get revsetConfigsMatch => 'Match';

  @override
  String revsetConfigsMode(String mode) {
    String _temp0 = intl.Intl.selectLogic(
      mode,
      {
        'substring': 'contains',
        'exact': 'is exactly',
        'glob': 'matches glob',
        'regex': 'matches regex',
        'prefix': 'path or folder',
        'file': 'exact file',
        'fileGlob': 'glob',
        'other': 'glob',
      },
    );
    return '$_temp0';
  }

  @override
  String revsetConfigsHint(String fn) {
    String _temp0 = intl.Intl.selectLogic(
      fn,
      {
        'author': 'Author name or email',
        'committer': 'Committer name or email',
        'mine': 'Changes authored by your user.email',
        'subject': 'First line of the description',
        'description': 'Full description text',
        'revset': 'Any revset, as jj log -r takes it',
        'other': 'Changes touching these paths',
      },
    );
    return '$_temp0';
  }

  @override
  String revsetConfigsDidYouMean(String names) {
    return 'Did you mean $names?';
  }

  @override
  String get revsetConfigsCaseInsensitive => 'Case-insensitive (-i)';

  @override
  String get revsetConfigsRemoveFilter => 'Remove filter';

  @override
  String revsetConfigsNoFilters(String expression) {
    return 'No filters — shows every commit ($expression).';
  }

  @override
  String get revsetConfigsAuthoredBy => 'authored by';

  @override
  String get revsetConfigsCommand => 'Command';

  @override
  String revsetConfigsMatchesOf(String total) {
    return ' of $total changes match';
  }

  @override
  String get revsetConfigsCopy => 'Copy';

  @override
  String get revsetConfigsCopied => 'Copied';

  @override
  String get revsetConfigsReference => 'Revset reference ↗';

  @override
  String get revsetConfigsCancel => 'Cancel';

  @override
  String get revsetConfigsApply => 'Apply';

  @override
  String get revsetConfigsOk => 'OK';

  @override
  String get revsetConfigsDiscardTitle => 'Discard changes?';

  @override
  String get revsetConfigsDiscardBody =>
      'Your edits to the configurations haven’t been applied. Cancel keeps them here.';

  @override
  String get revsetConfigsDiscard => 'Discard changes';

  @override
  String get settingsTabGeneral => 'General';

  @override
  String get settingsTabProject => 'Project';

  @override
  String get settingsTabsLabel => 'Settings';

  @override
  String get settingsOpenProjectFirst => 'Open a project first';

  @override
  String get settingsScopeGeneral => 'For Zanshin on this Mac · jj settings go to';

  @override
  String settingsScopeProject(String name) {
    return 'For $name only ·';
  }

  @override
  String settingsFooter(String viewOptions) {
    return 'How the graph looks lives with the graph: $viewOptions in the toolbar.';
  }

  @override
  String get settingsFooterViewOptions => 'View options';

  @override
  String settingsBackTo(String name) {
    return 'Back to $name';
  }

  @override
  String settingsFromScope(String scope) {
    return 'From $scope config';
  }

  @override
  String settingsAuthorFact(String name, String email, String command) {
    return '@ keeps the author $name <$email>. $command changes it.';
  }

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsTheme => 'Theme';

  @override
  String get settingsThemePaper => 'Paper';

  @override
  String get settingsThemeNight => 'Night';

  @override
  String get settingsThemeAuto => 'Auto';

  @override
  String get settingsDensity => 'Density';

  @override
  String get settingsDensityCompact => 'Compact';

  @override
  String get settingsDensityBalanced => 'Balanced';

  @override
  String get settingsDensityComfy => 'Comfy';

  @override
  String get settingsAccent => 'Accent colour';

  @override
  String get settingsAccentHint =>
      'Selection, focus and controls take the colour from System Settings › Appearance. Gold stays with @ and the primary action.';

  @override
  String get settingsAccentMacOS => 'Follow macOS';

  @override
  String get settingsAccentZanshin => 'Zanshin';

  @override
  String get settingsWhileScrolling => 'While you scroll';

  @override
  String get settingsHideControls => 'Hide controls';

  @override
  String get settingsHideControlsHint =>
      'Toolbars and panels step aside while you scroll the graph. The minimap stays.';

  @override
  String get settingsHideControlsSwitch => 'Hide controls while scrolling';

  @override
  String get settingsDiffs => 'Diffs';

  @override
  String get settingsDiffLayout => 'Layout';

  @override
  String get settingsDiffLayoutLabel => 'Diff layout';

  @override
  String get settingsDiffUnified => 'Unified';

  @override
  String get settingsDiffSideBySide => 'Side by side';

  @override
  String get settingsIdentity => 'Identity';

  @override
  String get settingsName => 'Name';

  @override
  String get settingsEmail => 'Email';

  @override
  String get settingsProjectEmail => 'Project email';

  @override
  String get settingsRemotes => 'Remotes';

  @override
  String get settingsFetchFrom => 'Fetch from';

  @override
  String get settingsPushTo => 'Push to';

  @override
  String get settingsNoRemotes => 'No remotes';

  @override
  String get settingsRemotePoll => 'Check for remote changes';

  @override
  String get settingsRemotePollOff => 'Off';

  @override
  String get settingsRemotePoll5 => '5 min';

  @override
  String get settingsRemotePoll15 => '15 min';

  @override
  String get settingsHistory => 'History';

  @override
  String get settingsTrunk => 'Trunk';

  @override
  String get settingsTrunkDefault => 'jj’s default';

  @override
  String get settingsTrunkCustom => 'Custom trunk';

  @override
  String get settingsTrunkCustomEllipsis => 'Custom…';

  @override
  String get settingsOwnEmail => 'Use a different email here';

  @override
  String get settingsOwnEmailHint => 'For work repositories with their own address.';

  @override
  String get settingsOwnEmailSwitch => 'Use a different email';

  @override
  String get settingsImmutableTitle => 'Immutable commits';

  @override
  String get settingsImmutableSummaryDefault => 'jj’s default (trunk, tags, remote bookmarks you don’t track)';

  @override
  String get settingsImmutableSummaryTrunk => 'trunk';

  @override
  String get settingsImmutableSummaryTags => 'tags';

  @override
  String get settingsImmutableSummaryRemoteBookmarks => 'untracked remote bookmarks';

  @override
  String get settingsImmutableSummaryRemoteTags => 'untracked remote tags';

  @override
  String get settingsImmutableSummaryOthers => 'other people’s changes';

  @override
  String get settingsImmutableSummaryCustom => 'a custom revset';

  @override
  String get settingsImmutableSummaryNone => 'Only root()';

  @override
  String get settingsImmutableIntro =>
      'jj won’t rewrite these changes or anything below them: no edit, describe, squash, rebase or abandon. New change on top and Revert still work. In the graph they’re hatched.';

  @override
  String get settingsImmutableBuiltIn => 'Built in';

  @override
  String get settingsImmutableTrunk => 'Trunk';

  @override
  String settingsImmutableTrunkHint(String trunk) {
    return 'Your main line. trunk() is $trunk, set under History.';
  }

  @override
  String get settingsImmutableTags => 'Tags';

  @override
  String get settingsImmutableTagsHint => 'Released versions.';

  @override
  String get settingsImmutableRemoteBookmarks => 'Remote bookmarks you don’t track';

  @override
  String get settingsImmutableRemoteBookmarksHint => 'Fetched, but not yours to rewrite.';

  @override
  String get settingsImmutableRemoteTags => 'Remote tags you don’t track';

  @override
  String get settingsImmutableRemoteTagsHint => 'Fetched, but not yours to move.';

  @override
  String settingsImmutableTagsNamed(String names) {
    return 'Released versions: $names.';
  }

  @override
  String settingsImmutableRemoteBookmarksNamed(String names) {
    return 'Fetched, but not yours to rewrite: $names.';
  }

  @override
  String settingsImmutableRemoteTagsNamed(String names) {
    return 'Fetched, but not yours to move: $names.';
  }

  @override
  String get settingsImmutableRemoteTagsNone => 'None in this repository.';

  @override
  String get settingsImmutableNoneHere => 'none here';

  @override
  String settingsImmutableMore(int count) {
    return '$count more';
  }

  @override
  String get settingsImmutableAlso => 'Also immutable';

  @override
  String get settingsImmutableOthers => 'Other people’s changes';

  @override
  String get settingsImmutableOthersHint =>
      'Everything after trunk() that isn’t yours. What’s below them is locked too, your own changes included.';

  @override
  String get settingsImmutableBookmarks => 'Bookmarks';

  @override
  String get settingsImmutableBookmarksHint => 'A release or shared bookmark you never rewrite.';

  @override
  String get settingsImmutableAddBookmark => 'Bookmark…';

  @override
  String get settingsImmutableCustom => 'Custom revset';

  @override
  String get settingsImmutableCustomHint => 'Joined with |. Written once jj resolves it.';

  @override
  String get settingsImmutableResult => 'Result';

  @override
  String settingsImmutableCountSuffix(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'changes are immutable',
      one: 'change is immutable',
    );
    return '$_temp0';
  }

  @override
  String settingsImmutableRootNote(String root, String flag) {
    return '$root is always immutable. To rewrite one anyway, jj needs $flag.';
  }

  @override
  String get settingsImmutableReset => 'Reset to jj’s default';

  @override
  String syncFetchTooltip(String remotes) {
    return 'Fetch from $remotes';
  }

  @override
  String syncFetchChanged(String names, String remote) {
    return '$names changed on $remote';
  }

  @override
  String get syncFetching => 'Fetching…';

  @override
  String syncFetchingPercent(int percent) {
    return 'Fetching… $percent%';
  }

  @override
  String syncPushTooltip(String remotes) {
    return 'Choose what to push to $remotes';
  }

  @override
  String get syncNoRemote => 'No remote';

  @override
  String toastFetched(int count, String remotes) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Fetched from $remotes · $count bookmarks changed',
      one: 'Fetched from $remotes · 1 bookmark changed',
      zero: 'Fetched from $remotes',
    );
    return '$_temp0';
  }

  @override
  String toastPushed(String names, String remotes) {
    return 'Pushed $names to $remotes';
  }

  @override
  String get pushSheetTitle => 'Push';

  @override
  String get pushSheetTo => 'to';

  @override
  String get pushSheetRemoteDefault => 'A default remote, no flag';

  @override
  String get pushSheetRemoteFlag => 'Pushed with --remote';

  @override
  String get pushSheetBookmarks => 'Bookmarks';

  @override
  String get pushSheetBookmarksAndTags => 'Bookmarks and tags';

  @override
  String get pushSheetBare => 'As jj git push';

  @override
  String pushSheetBareTooltip(String revset, String remotes) {
    return 'Tracked bookmarks and tags in $revset, to $remotes';
  }

  @override
  String pushSheetBareTooltipNoRevset(String remotes) {
    return 'Tracked bookmarks and tags in revsets.git-push, to $remotes';
  }

  @override
  String get pushSheetTracked => 'Tracked';

  @override
  String get pushSheetAll => 'All';

  @override
  String get pushSheetDeleted => 'Deleted';

  @override
  String get pushSheetTag => 'TAG';

  @override
  String get pushSheetNotSent => 'not sent';

  @override
  String get pushSheetSkipped => 'skipped';

  @override
  String get pushSheetRefused => 'refused';

  @override
  String pushSheetAllowedWith(String flags) {
    return 'Allowed · pushed with $flags';
  }

  @override
  String get pushSheetAllow => 'Allow';

  @override
  String get pushSheetAllowEmptyDescription => 'Allow empty descriptions';

  @override
  String get pushSheetAllowPrivate => 'Allow private commits';

  @override
  String get pushSheetAllowConflicts => 'Allow conflicts';

  @override
  String pushSheetChange(String id) {
    return 'Push $id as a new bookmark';
  }

  @override
  String get pushSheetChangeName => 'Bookmark name';

  @override
  String get pushSheetChangeGenerated =>
      'The name jj generates (templates.git_push_bookmark) — type your own to name it.';

  @override
  String get pushSheetChangeNamed => 'Your name — pushed with --named.';

  @override
  String pushSheetEmptyRemotes(String remotes) {
    return 'Nothing goes to $remotes. jj still runs git push there, which fails, and then the push is not recorded.';
  }

  @override
  String get pushSheetSigning =>
      'git.sign-on-push is on: the push signs commits and rebases their descendants, so the pushed ids can differ from this preview.';

  @override
  String get pushSheetChecked => 'Checked with --dry-run';

  @override
  String get pushSheetChecking => 'Checking…';

  @override
  String get pushSheetRan => 'Ran';

  @override
  String get pushSheetCommand => 'Command';

  @override
  String get pushSheetCancel => 'Cancel';

  @override
  String get pushSheetPush => 'Push';

  @override
  String get pushSheetDone => 'Done';

  @override
  String pushSheetPushing(String remotes) {
    return 'Pushing to $remotes…';
  }

  @override
  String get pushSheetProgress => 'Pushing';

  @override
  String get pushSheetRecorded => 'The push is recorded, so Undo works as usual.';

  @override
  String get pushSheetNotRecorded => 'Nothing was recorded.';

  @override
  String pushSheetStoppedAt(String remote, String earlier) {
    return 'The push stopped at $remote. $earlier already got their refs.';
  }

  @override
  String pushSheetStoppedAtFirst(String remote) {
    return 'The push stopped at $remote. No remote got its refs.';
  }

  @override
  String get pushSheetPushed => 'pushed';

  @override
  String pushSheetMovedOn(String remote) {
    return 'moved on $remote';
  }

  @override
  String get pushSheetRejected => 'rejected';

  @override
  String get pushSheetUnexported => 'couldn’t be updated locally';

  @override
  String get pushSheetNotReached => 'not pushed';
}
