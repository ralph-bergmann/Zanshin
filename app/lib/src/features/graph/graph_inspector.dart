// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io' show FileSystemException;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/semantics.dart' show SemanticsService;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart' show SelectionArea;
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart'
    show DiffFileListSetting, DiffLayoutSetting, DiffWhitespaceSetting, LayoutSettings, SettingsStore;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../projects/projects_environment.dart' show DiffContext;
import '../window/app_window_actions.dart';
import 'graph_card.dart';
import 'graph_drag.dart';
import 'graph_layout.dart';
import 'graph_ports.dart';
import 'graph_view_model.dart';
import 'hatch_swatch.dart';
import 'immutable_reasons.dart';
import 'inspector_check_reveal.dart';
import 'inspector_diff.dart';
import 'inspector_file_tree.dart';
import 'inspector_path_label.dart';
import 'inspector_viewed_store.dart';
import 'project_files.dart';

final _log = Logger('zanshin.inspector');

/// The describe form's two fields.
typedef InspectorDraft = ({String summary, String details});

/// What the composer runs (Story 10.48): `jj commit` or `jj split`.
enum ComposerVerb {
  /// `jj commit` (@ only).
  commit,

  /// `jj split -r`.
  split,
}

/// A part of the composer's result preview.
enum ComposerPart {
  /// The rest: on @ the new working copy.
  rest,

  /// The selected part.
  selected,
}

/// The inspector's model (Story 10.8): what [details] answers for the graph's selection, and the describe form's state.
///
/// - **Fetch.** On every change of the selected key or the layout's operation it reads `show` (the commit id) and,
///   for a mutable change, `changeActions`; a reply for an older key or operation is dropped. A refusal is kept as
///   [error]. While the working copy is stale nothing is read (jj refuses).
/// - **Drafts** live per change key for the session; the form's open state too while the draft differs from the
///   description, so a draft survives a selection change and comes back open — an untouched form closes. [save]
///   joins the fields as the CLI's `-m` paragraphs and runs `jj describe` through the graph's runner — nothing when
///   the text equals the current description.
/// - **Diff** (Story 10.24): with `show` it reads the summary diff ([summaryOf]: ± and fingerprints per file); then the
///   focused file's diff ([focusedDiff]) — both by the commit id, so a hidden or divergent node reads its own commit.
///   The first file starts focused; a reload keeps the focused path while it is
///   listed. A file is viewed while `viewedKey(change id, path, its summary fingerprint)` is in the viewed store's set; the
///   layout is `general.diffLayout` in [settings], followed when another writer changes it, and so is
///   `general.diffWordMarks` ([wordMarks], Story 5.14), which only changes how the loaded diff is drawn. The split
///   between files and diff takes its share per layout from `layout` in [settings] ([filesShare], Story 10.38).
///   Story 10.33: `general.diffWhitespace` ([whitespace]) is followed too; while it ignores whitespace the focused file
///   is also read at `-b` / `-w` ([focusedIgnoring]), and the diff options menu writes `diff.color-words.context`
///   ([contextLines]) through [details]. The summary and the Viewed fingerprints stay exact.
/// - **Composer** (Story 10.25): the checked files of the selection — @ starts with all, another change with none,
///   reset on a selection change, kept to the still-listed paths on a reload — and a composer draft per change key;
///   [runComposer] runs [composerAction] (`jj commit` / `jj split -r`); the verb follows the pick ([composerVerb], on @
///   with [composerAlternative], Story 10.48), and the preview shows where the change's bookmarks land
///   ([bookmarksLandOn], `split.legacy-bookmark-behavior` read at start and on [configChanged]). [squash] asks
///   `squashPlan` first and opens the
///   squash form with the combined description when jj would open its editor.
/// - **File list** (Story 10.39): flat or tree is `general.diffFileList` in [settings] ([fileList]); the tree's
///   collapsed folders live here for the session ([collapsed]); a folder picks and marks Viewed all of its files
///   ([togglePicks], [setViewedAll]). [files] does what touches the disk.
class InspectorViewModel extends ChangeNotifier {
  /// The inspector of [graph]'s selection, reading through [details]; Viewed marks in [viewed], the diff layout in
  /// [settings].
  InspectorViewModel({
    required this.graph,
    required this.details,
    required InspectorViewedStore viewed,
    required this.settings,
    this.files,
  }) : _viewedStore = viewed,
       _viewed = viewed.load(),
       _layout = settings.value.general.diffLayout,
       _fileList = settings.value.general.diffFileList,
       _wordMarks = settings.value.general.diffWordMarks,
       _whitespace = settings.value.general.diffWhitespace,
       _shares = (
         narrow: settings.value.layout.inspectorFilesNarrow,
         wide: settings.value.layout.inspectorFilesWide,
       ) {
    graph.addListener(_graphChanged);
    settings.addListener(_settingsChanged);
    viewed.addListener(_viewedChanged);
    _graphChanged();
    unawaited(_readContext());
    unawaited(_readLegacyBookmarks());
  }

  /// The graph whose selection it shows; its runner runs the actions.
  final GraphViewModel graph;

  /// What the inspector reads.
  final GraphDetails details;

  /// The app settings: the diff layout and the word-mark switch.
  final SettingsStore settings;

  /// The repository's files on disk (Story 10.39): copy, Open in Editor, Reveal in Finder; null without a workspace
  /// root (the catalogue's stand-ins), which drops the menus and the copyable diff path.
  final ProjectFiles? files;

  final InspectorViewedStore _viewedStore;
  final Set<String> _viewed;
  DiffLayoutSetting _layout;
  DiffFileListSetting _fileList;

  // The tree's collapsed folders, by path; for the session only.
  final _collapsed = <String>{};
  bool _wordMarks;
  DiffWhitespaceSetting _whitespace;
  DiffContext _context = (lines: 3, fromRepo: false);
  var _contextSerial = 0;
  bool? _legacyBookmarks;
  var _legacySerial = 0;
  ({double narrow, double wide}) _shares;

  Map<String, FileDiff>? _summary;
  String? _changeId;
  String? _commitId;
  String? _focused;
  FileDiff? _focusedDiff;
  ({String commitId, DiffWhitespace whitespace})? _focusedRevision;
  FileDiff? _previousDiff;
  FileDiff? _focusedIgnoring;
  FileDiff? _previousIgnoring;
  ZanshinFfiException? _focusError;
  var _focusSerial = 0;

  String? _key;
  String? _op;
  var _stale = false;
  var _serial = 0;
  ShowEntry? _entry;
  ChangeActions? _actions;
  ZanshinFfiException? _error;
  var _loading = false;
  // Each draft with its base: the description shown when it was first kept.
  final _drafts = <String, ({InspectorDraft draft, String base})>{};
  final _open = <String>{};
  var _disposed = false;

  // The composer (Story 10.25): the checked paths of [_key] (set up once per key by the first read), the drafts per key.
  // Story 10.26: [_partial] holds the files picked by sections and mode — never empty, never full, never in [_picked].
  final _picked = <String>{};
  final _partial = <String, ({Set<HunkKey> keys, bool mode})>{};
  String? _pickedFor;
  final _composerDrafts = <String, InspectorDraft>{};
  ZanshinFfiException? _composerError;

  // The squash form: the key it was opened for and the combined description's fields.
  ({String key, InspectorDraft initial})? _squashForm;

  /// The selection's `show` entry; null until it is read, while stale, and after a refusal.
  ShowEntry? get entry => _entry;

  /// The selection's verb previews; null for an immutable change and until read.
  ChangeActions? get actions => _actions;

  /// The last read's refusal.
  ZanshinFfiException? get error => _error;

  /// Whether a read runs.
  bool get loading => _loading;

  /// [path]'s summary entry (± and fingerprint); null until the summary is read, after its refusal, and for a path
  /// it does not list.
  FileDiff? summaryOf(String path) => _summary?[path];

  /// Whether the summary was read.
  bool get hasSummary => _summary != null;

  /// The path whose diff shows; null without files.
  String? get focusedPath => _focused;

  /// The focused file's diff; null while it loads, after a refusal, and when the reply lists no such file.
  FileDiff? get focusedDiff => _focusedDiff;

  /// The commit and whitespace mode the last focused diff was read at; gap rows read their lines there ([diffLines]).
  /// Kept while a [previousDiff] shows; null before the first read, after a refusal and without a diff.
  ({String commitId, DiffWhitespace whitespace})? get focusedRevision => _focusedRevision;

  /// The diff shown before [focus] switched files, kept while the new one loads so the view keeps its height (and
  /// its scroll offset); null once the new diff or a refusal arrives.
  FileDiff? get previousDiff => _previousDiff;

  /// [focusedDiff]'s file as the read at [whitespace] lists it ([ignoringOf]); null while whitespace shows (Stories
  /// 10.33, 10.41).
  FileDiff? get focusedIgnoring => _focusedIgnoring;

  /// [focusedIgnoring] of [previousDiff].
  FileDiff? get previousIgnoring => _previousIgnoring;

  /// The focused diff's refusal.
  ZanshinFfiException? get focusError => _focusError;

  /// Whether the diff fills the words that changed inside a line (Settings › Changed words, Story 5.14).
  bool get wordMarks => _wordMarks;

  /// How the diff treats whitespace: `general.diffWhitespace` in [settings] (Story 10.33).
  DiffWhitespaceSetting get whitespace => _whitespace;

  /// Writes the whitespace mode (a failed write is swallowed; the store keeps the value); the diff reloads once the
  /// store has it.
  void setWhitespace(DiffWhitespaceSetting whitespace) {
    if (whitespace == _whitespace) {
      return;
    }
    unawaited(
      settings
          .update((s) => s.copyWith(general: s.general.copyWith(diffWhitespace: whitespace)))
          .onError<FileSystemException>((_, _) {}),
    );
  }

  /// `diff.color-words.context` as `jj diff` in the workspace reads it; null when jj cannot read it.
  int? get contextLines => _context.lines;

  /// Whether the repo or the workspace config sets [contextLines], which then wins over a user-level pick.
  bool get contextFromRepo => _context.fromRepo;

  /// Writes `diff.color-words.context` at user scope; the config write reloads the diff and reads the value again. A
  /// refused write is logged and the value kept.
  Future<void> setContextLines(int lines) async {
    try {
      await details.setDiffContext(lines);
    } on ZanshinFfiException catch (error) {
      _log.warning('writing diff.color-words.context refused: ${error.code}');
    }
  }

  Future<void> _readContext() async {
    final int serial = ++_contextSerial;
    DiffContext context;
    try {
      context = await details.diffContext();
    } on ZanshinFfiException catch (error) {
      _log.warning('reading diff.color-words.context refused: ${error.code}');
      context = (lines: null, fromRepo: false);
    }
    if (serial == _contextSerial && context != _context) {
      _context = context;
      _notify();
    }
  }

  Future<void> _readLegacyBookmarks() async {
    final int serial = ++_legacySerial;
    bool? legacy;
    try {
      legacy = await details.splitLegacyBookmarks();
    } on ZanshinFfiException catch (error) {
      _log.warning('reading split.legacy-bookmark-behavior refused: ${error.code}');
    }
    if (serial == _legacySerial && legacy != _legacyBookmarks) {
      _legacyBookmarks = legacy;
      _notify();
    }
  }

  /// Keeps the shown diff (and what the ignoring read said about it) as the previous one while another loads.
  void _keepPrevious() {
    if (_focusedDiff != null) {
      _previousDiff = _focusedDiff;
      _previousIgnoring = _focusedIgnoring;
    }
    _focusedDiff = null;
    _focusedIgnoring = null;
  }

  /// Shows [path]'s diff (one read, two while whitespace is ignored); on the focused path after a refusal it reads
  /// again.
  void focus(String path) {
    if (path == _focused && _focusError == null) {
      return;
    }
    _focused = path;
    _keepPrevious();
    _focusError = null;
    _loadFocus();
    _notify();
  }

  String? _viewedKeyOf(String path) {
    final String? fingerprint = _summary?[path]?.fingerprint;
    final String? changeId = _changeId;
    return fingerprint == null || changeId == null ? null : viewedKey(changeId, path, fingerprint);
  }

  /// Whether [path] is marked Viewed with its current fingerprint.
  bool isViewed(String path) => _viewed.contains(_viewedKeyOf(path));

  /// Marks [path] Viewed or not; a path without a summary entry stays as it is.
  void setViewed(String path, bool viewed) => _setViewed(<String>[path], viewed);

  /// Marks every listed file Viewed.
  void markAll() => _setViewed(_listed, true);

  /// Clears every listed file's Viewed mark.
  void resetViewed() => _setViewed(_listed, false);

  /// How many listed files are viewed.
  int get viewedCount => _listed.where(isViewed).length;

  List<String> get _listed => <String>[for (final FileChange file in _entry?.fileChanges ?? const []) file.path];

  void _setViewed(List<String> paths, bool viewed) {
    var changed = false;
    for (final path in paths) {
      final String? key = _viewedKeyOf(path);
      if (key == null || (_viewed.contains(key) == viewed)) {
        continue;
      }
      if (viewed) {
        _viewed.add(key);
      } else {
        _viewed.remove(key);
      }
      changed = true;
    }
    if (changed) {
      _viewedStore.save(_viewed);
      _notify();
    }
  }

  /// Unified or side by side.
  DiffLayoutSetting get layout => _layout;

  /// Writes the layout preference (a failed write is swallowed; the store keeps the value).
  void setLayout(DiffLayoutSetting layout) {
    if (layout == _layout) {
      return;
    }
    unawaited(
      settings
          .update((s) => s.copyWith(general: s.general.copyWith(diffLayout: layout)))
          .onError<FileSystemException>((_, _) {}),
    );
  }

  /// Flat or tree: `general.diffFileList` in [settings] (Story 10.39).
  DiffFileListSetting get fileList => _fileList;

  /// Writes the file list preference (a failed write is swallowed; the store keeps the value).
  void setFileList(DiffFileListSetting fileList) {
    if (fileList == _fileList) {
      return;
    }
    unawaited(
      settings
          .update((s) => s.copyWith(general: s.general.copyWith(diffFileList: fileList)))
          .onError<FileSystemException>((_, _) {}),
    );
  }

  /// The tree's collapsed folders by path, kept for the session and never stored.
  Set<String> get collapsed => Set<String>.unmodifiable(_collapsed);

  /// Collapses or expands the tree's folder at [path].
  void setCollapsed(String path, {required bool collapsed}) {
    if (collapsed ? _collapsed.add(path) : _collapsed.remove(path)) {
      _notify();
    }
  }

  /// The checkbox of a folder holding [paths]: all picked whole → true, none with a pick → false, else mixed.
  bool? picksState(List<String> paths) {
    if (paths.isNotEmpty && paths.every(_picked.contains)) {
      return true;
    }
    return paths.any(hasPick) ? null : false;
  }

  /// A folder's checkbox (Story 10.39): picks [paths] whole, or unpicks them all when every one is picked whole.
  void togglePicks(List<String> paths) {
    if (!selectable || paths.isEmpty) {
      return;
    }
    final bool all = picksState(paths) ?? false;
    for (final path in paths) {
      _partial.remove(path);
      if (all) {
        _picked.remove(path);
      } else {
        _picked.add(path);
      }
    }
    _picksChanged();
  }

  /// Marks every one of [paths] Viewed or not (V on a folder).
  void setViewedAll(List<String> paths, {required bool viewed}) => _setViewed(paths, viewed);

  /// The files' share of the split between the file list and the diff, per layout (Story 10.38; app-wide, in
  /// `layout` of [settings]).
  double filesShare({required bool wide}) =>
      wide ? settings.value.layout.inspectorFilesWide : settings.value.layout.inspectorFilesNarrow;

  /// Writes the files' share of [wide]'s split — once a divider drag ends or on reset, never per move (a failed write
  /// is swallowed; the store keeps the value).
  void setFilesShare({required bool wide, required double share}) {
    unawaited(
      settings
          .update(
            (s) => s.copyWith(
              layout: wide
                  ? s.layout.copyWith(inspectorFilesWide: share)
                  : s.layout.copyWith(inspectorFilesNarrow: share),
            ),
          )
          .onError<FileSystemException>((_, _) {}),
    );
  }

  void _settingsChanged() {
    var changed = false;
    final DiffLayoutSetting layout = settings.value.general.diffLayout;
    if (layout != _layout) {
      _layout = layout;
      changed = true;
    }
    final DiffFileListSetting fileList = settings.value.general.diffFileList;
    if (fileList != _fileList) {
      _fileList = fileList;
      changed = true;
    }
    // Another window (or a reset) moved a split.
    final ({double narrow, double wide}) shares = (
      narrow: settings.value.layout.inspectorFilesNarrow,
      wide: settings.value.layout.inspectorFilesWide,
    );
    if (shares != _shares) {
      _shares = shares;
      changed = true;
    }
    // The switch only changes the drawing, so the loaded diff stays.
    final bool wordMarks = settings.value.general.diffWordMarks;
    if (wordMarks != _wordMarks) {
      _wordMarks = wordMarks;
      changed = true;
    }
    // The mode changes the reads: the focused diff loads again, the old one stays meanwhile.
    final DiffWhitespaceSetting whitespace = settings.value.general.diffWhitespace;
    if (whitespace != _whitespace) {
      _whitespace = whitespace;
      _reloadFocus();
      changed = true;
    }
    if (changed) {
      _notify();
    }
  }

  // Another writer (a second window of the repo, the cleanup, Settings' reset, the store's limit) changed the marks.
  void _viewedChanged() {
    final Set<String> viewed = _viewedStore.load();
    if (!setEquals(viewed, _viewed)) {
      _viewed
        ..clear()
        ..addAll(viewed);
      _notify();
    }
  }

  /// A jj config write may change `diff.color-words.*`: the focused diff loads again, the old one stays meanwhile, and
  /// the context lines and `split.legacy-bookmark-behavior` are read again.
  void configChanged() {
    _reloadFocus();
    unawaited(_readContext());
    unawaited(_readLegacyBookmarks());
    _notify();
  }

  void _reloadFocus() {
    _keepPrevious();
    _focusError = null;
    _loadFocus();
  }

  /// The unchanged lines a gap row of [path] opens (Story 10.43): `-r` the shown diff's commit at its whitespace mode
  /// ([focusedRevision]) — after a rewrite the old diff shows until the new one arrives. A refusal is logged like the
  /// diff's and rethrown: the gap stays closed.
  Future<List<HunkLine>> diffLines(String path, int start, int end) async {
    final ({String commitId, DiffWhitespace whitespace})? revision = _focusedRevision;
    if (revision == null) {
      return const <HunkLine>[];
    }
    try {
      return await details.diffLines(
        revision.commitId,
        path: path,
        start: start,
        end: end,
        whitespace: revision.whitespace,
      );
    } on ZanshinFfiException catch (error) {
      _log.warning('diff lines refused: ${error.code}');
      rethrow;
    }
  }

  /// Reads the focused file: exact (parts, picks, header, counts) and, while whitespace is ignored, at the mode too, in
  /// parallel; it shows once both arrived, and a refusal of either is the diff's refusal (Story 10.33).
  void _loadFocus() {
    final int serial = ++_focusSerial;
    final String? path = _focused;
    final String? commitId = _commitId;
    if (path == null || commitId == null || _summary == null) {
      _focusedDiff = null;
      _focusedRevision = null;
      _focusedIgnoring = null;
      _focusError = null;
      return;
    }
    final DiffWhitespace mode = diffWhitespaceOf(_whitespace);
    unawaited(() async {
      try {
        final List<Diff> diffs = await Future.wait<Diff>(<Future<Diff>>[
          details.diff(commitId, paths: <String>[path]),
          if (mode != DiffWhitespace.exact) details.diff(commitId, paths: <String>[path], whitespace: mode),
        ]);
        FileDiff? fileOf(Diff diff) => diff.files.where((file) => file.path == path).firstOrNull;
        if (serial == _focusSerial) {
          _focusedDiff = fileOf(diffs.first);
          _focusedRevision = _focusedDiff == null ? null : (commitId: commitId, whitespace: mode);
          _focusedIgnoring = diffs.length > 1 ? ignoringOf(path, fileOf(diffs.last)) : null;
          _previousDiff = null;
          _previousIgnoring = null;
          _focusError = null;
          _notify();
        }
      } on ZanshinFfiException catch (error) {
        _log.warning('diff refused: ${error.code}');
        if (serial == _focusSerial) {
          _focusedDiff = null;
          _focusedRevision = null;
          _focusedIgnoring = null;
          _previousDiff = null;
          _previousIgnoring = null;
          _focusError = error;
          _notify();
        }
      }
    }());
  }

  /// The summary, or null when it is refused (no diff block).
  Future<Diff?> _summaryRead(String commitId) async {
    try {
      return await details.diff(commitId, summary: true);
    } on ZanshinFfiException catch (error) {
      _log.warning('summary diff refused: ${error.code}');
      return null;
    }
  }

  /// Whether [key]'s describe form is open.
  bool isOpen(String key) => _open.contains(key);

  /// [key]'s draft, when the form was edited. A draft that is stale — the selection's description changed since it
  /// was kept, and it is empty or still the old prefill — is dropped, so the form prefills the new description.
  InspectorDraft? draftOf(String key) {
    final ({InspectorDraft draft, String base})? kept = _drafts[key];
    if (kept == null) {
      return null;
    }
    final InspectorDraft draft = kept.draft;
    final bool untouched = (draft.summary.isEmpty && draft.details.isEmpty) || draft == draftFrom(kept.base);
    if (_describedMeanwhile(key, kept.base) && untouched) {
      _drafts.remove(key);
      return null;
    }
    return draft;
  }

  /// The selection [key]'s description changed since its kept draft was first kept, and the draft differs from it.
  bool describedMeanwhile(String key) {
    final ({InspectorDraft draft, String base})? kept = _drafts[key];
    return kept != null && _describedMeanwhile(key, kept.base) && !_unchanged(kept.draft);
  }

  bool _describedMeanwhile(String key, String base) => key == _key && description != null && description != base;

  /// Opens [key]'s describe form.
  void openForm(String key) {
    if (_open.add(key)) {
      _notify();
    }
  }

  /// Closes [key]'s describe form; its draft stays.
  void closeForm(String key) {
    if (_open.remove(key)) {
      _notify();
    }
  }

  /// Keeps [draft] as [key]'s; the first one records the description shown as its base.
  void updateDraft(String key, InspectorDraft draft) =>
      _drafts[key] = (draft: draft, base: _drafts[key]?.base ?? (key == _key ? description ?? '' : ''));

  /// The card menu's "Describe…" (10.15 calls it): selects [key] and opens its form.
  void describe(String key) {
    graph.select(key);
    openForm(key);
  }

  /// The selection's current description, once read.
  String? get description => _entry?.change.description;

  /// [key]'s draft differs from the current description.
  bool dirty(String key) {
    final InspectorDraft? draft = _drafts[key]?.draft;
    return draft != null && key == _key && !_unchanged(draft);
  }

  /// [draft] joins to the current description, or still holds its prefill (a description jj would not have written
  /// from `-m` paragraphs, "S\nD", must not be rewritten by an untouched form).
  bool _unchanged(InspectorDraft draft) {
    final String current = description ?? '';
    return joinMessageParagraphs(paragraphsOf(draft)) == current || draft == draftFrom(current);
  }

  /// The fields a [description] prefills: its first line, and the rest after the blank line.
  static InspectorDraft draftFrom(String description) {
    final int newline = description.indexOf('\n');
    if (newline < 0) {
      return (summary: description, details: '');
    }
    final String rest = description.substring(newline).replaceFirst(RegExp(r'^\n+'), '');
    return (summary: description.substring(0, newline), details: rest.replaceFirst(RegExp(r'\n+$'), ''));
  }

  /// The `-m` paragraphs of [draft]: the summary, and the details when not empty.
  static List<String> paragraphsOf(InspectorDraft draft) => <String>[
    draft.summary,
    if (draft.details.isNotEmpty) draft.details,
  ];

  /// Saves [draft] as [key]'s description: nothing when it is unchanged — it joins to the current one or holds its
  /// prefill — (the form closes), else `jj describe` through the runner; the form closes and the draft goes once it
  /// ran.
  Future<GraphActionResult?> save(String key, InspectorDraft draft) async {
    final List<String> paragraphs = paragraphsOf(draft);
    if (key == _key ? _unchanged(draft) : joinMessageParagraphs(paragraphs).isEmpty) {
      _drafts.remove(key);
      closeForm(key);
      return null;
    }
    final GraphActionResult result = await graph.run(GraphDescribe.fromParagraphs(key, paragraphs));
    if (result is GraphActionDone) {
      _drafts.remove(key);
      closeForm(key);
    }
    return result;
  }

  /// The selection's node while it is a mutable, non-root change in the shown layout; else null.
  ({GraphLayout layout, int node})? get _mutableNode {
    final String? key = _key;
    final GraphLayout? layout = graph.layout;
    final int? node = key == null ? null : layout?.indexOfKey(key);
    if (node == null || graph.stale != null || node == layout!.rootIndex || layout.isImmutable(node)) {
      return null;
    }
    return (layout: layout, node: node);
  }

  /// Whether the selection's files take checkboxes: a read, mutable, non-root change with files.
  bool get selectable => _mutableNode != null && _listed.isNotEmpty;

  /// Whether [path] is checked whole for the composer.
  bool isPicked(String path) => _picked.contains(path);

  /// Whether [path] has a pick, whole or partial.
  bool hasPick(String path) => _picked.contains(path) || _partial.containsKey(path);

  /// How many files have a pick.
  int get pickedCount => _picked.length + _partial.length;

  /// Whether every listed file is checked whole.
  bool get allPicked => _listed.isNotEmpty && _listed.every(_picked.contains);

  /// [path]'s checkbox: true when picked whole, null (mixed) when picked by sections or mode, else false.
  bool? fileState(String path) => _picked.contains(path) ? true : (_partial.containsKey(path) ? null : false);

  /// Select all's checkbox: every listed file whole → true, no pick → false, else mixed.
  bool? get allState => allPicked ? true : (_picked.isEmpty && _partial.isEmpty ? false : null);

  /// Whether [path] takes hunk and mode checkboxes: its summary has sections or a mode change (Story 10.26). A rename
  /// or copy stays whole-only: a partial pick would leave its source behind.
  bool hunkable(String path) {
    final FileDiff? shape = _summary?[path];
    return selectable &&
        shape != null &&
        shape.kind != FileChangeKind.renamed &&
        shape.kind != FileChangeKind.copied &&
        (shape.sections.isNotEmpty || shape.modeChange);
  }

  /// Whether [path]'s mode change is picked: the file whole, or its partial's mode.
  bool modePicked(String path) => _picked.contains(path) || (_partial[path]?.mode ?? false);

  /// Checks or unchecks [path] whole: all → none, else → all.
  void togglePick(String path) {
    if (!selectable) {
      return;
    }
    _partial.remove(path);
    if (!_picked.remove(path)) {
      _picked.add(path);
    }
    _picksChanged();
  }

  /// Whether [part] (one of a hunk's sections) of [path] is picked: the file whole, or the section in its partial.
  bool partPicked(String path, HunkKey part) =>
      _picked.contains(path) || (_partial[path]?.keys.contains(part) ?? false);

  /// Toggles one part of a hunk in [path] (Story 10.38): the smallest pick, a section, never a line. Like a hunk, only
  /// a key still in the file's current sections; a full partial becomes a whole pick.
  void togglePart(String path, HunkKey part) {
    if (!hunkable(path) || !_summary![path]!.sections.contains(part)) {
      return;
    }
    final ({Set<HunkKey> keys, bool mode}) pick = _partialOf(path);
    if (!pick.keys.remove(part)) {
      pick.keys.add(part);
    }
    _setPartial(path, pick);
  }

  /// Toggles [path]'s mode change.
  void toggleMode(String path) {
    if (!hunkable(path) || !(_summary?[path]?.modeChange ?? false)) {
      return;
    }
    final ({Set<HunkKey> keys, bool mode}) pick = _partialOf(path);
    _setPartial(path, (keys: pick.keys, mode: !pick.mode));
  }

  /// [path]'s pick as a (fresh) partial: whole → every section and the mode, none → nothing.
  ({Set<HunkKey> keys, bool mode}) _partialOf(String path) {
    if (_picked.contains(path)) {
      final FileDiff shape = _summary![path]!;
      return (keys: shape.sections.toSet(), mode: shape.modeChange);
    }
    final ({Set<HunkKey> keys, bool mode})? pick = _partial[path];
    return (keys: <HunkKey>{...?pick?.keys}, mode: pick?.mode ?? false);
  }

  void _setPartial(String path, ({Set<HunkKey> keys, bool mode}) pick) {
    _picked.remove(path);
    _partial[path] = pick;
    _normalize(path);
    _picksChanged();
  }

  /// After a reload: a partial keeps the keys still in its file's sections and its mode while the file still has a
  /// mode change; a file no longer listed or now whole-only drops it.
  void _remapPartials() {
    final Set<String> listed = _listed.toSet();
    for (final String path in _partial.keys.toList()) {
      if (!listed.contains(path) || !hunkable(path)) {
        _partial.remove(path);
        continue;
      }
      final FileDiff shape = _summary![path]!;
      final ({Set<HunkKey> keys, bool mode}) pick = _partial[path]!;
      _partial[path] = (
        keys: pick.keys.where(shape.sections.contains).toSet(),
        mode: pick.mode && shape.modeChange,
      );
      _normalize(path);
    }
  }

  /// An empty partial goes, a full one becomes a whole pick.
  void _normalize(String path) {
    final ({Set<HunkKey> keys, bool mode})? pick = _partial[path];
    final FileDiff? shape = _summary?[path];
    if (pick == null || shape == null) {
      return;
    }
    if (pick.keys.isEmpty && !pick.mode) {
      _partial.remove(path);
    } else if (pick.keys.containsAll(shape.sections) && (pick.mode || !shape.modeChange)) {
      _partial.remove(path);
      _picked.add(path);
    }
  }

  void _picksChanged() {
    _composerError = null;
    _notify();
  }

  /// Select all: checks every listed file whole, or clears every pick when all are checked whole.
  void pickAll() {
    if (!selectable) {
      return;
    }
    final bool all = allPicked;
    _picked.clear();
    _partial.clear();
    if (!all) {
      _picked.addAll(_listed);
    }
    _picksChanged();
  }

  /// The composer's Cancel (and Esc on a change with picks): clears every pick (the draft stays).
  void clearPicks() {
    if (_picked.isNotEmpty || _partial.isNotEmpty || _composerError != null) {
      _picked.clear();
      _partial.clear();
      _picksChanged();
    }
  }

  /// The ± of [path]'s picked part: its summary's when whole, the picked sections' when partial, else none.
  ({int added, int removed}) pickedStat(String path) {
    final FileDiff? shape = _summary?[path];
    if (_picked.contains(path)) {
      return (added: shape?.added ?? 0, removed: shape?.removed ?? 0);
    }
    final Set<HunkKey> keys = _partial[path]?.keys ?? const <HunkKey>{};
    return (
      added: keys.fold(0, (sum, key) => sum + key.newCount),
      removed: keys.fold(0, (sum, key) => sum + key.oldCount),
    );
  }

  /// [key]'s composer draft, when it was edited.
  InspectorDraft? composerDraftOf(String key) => _composerDrafts[key];

  /// What the selection's composer fields hold: its draft, else the change's description — the text the CLI's editor
  /// starts with (an undescribed change starts empty).
  InspectorDraft get composerFields => (_key == null ? null : _composerDrafts[_key]) ?? draftFrom(description ?? '');

  /// Keeps [draft] as [key]'s composer draft.
  void updateComposerDraft(String key, InspectorDraft draft) {
    _composerDrafts[key] = draft;
    _clearComposerError();
  }

  void _clearComposerError() {
    if (_composerError != null) {
      _composerError = null;
      _notify();
    }
  }

  /// The last composer run's refusal, for the selection.
  ZanshinFfiException? get composerError => _composerError;

  /// Whether the composer shows: on a mutable change, @ with files or another change with a file checked.
  bool get composing {
    final ({GraphLayout layout, int node})? at = _mutableNode;
    if (at == null || _entry == null) {
      return false;
    }
    return at.layout.workingCopyIndex == at.node ? _listed.isNotEmpty : pickedCount > 0;
  }

  bool get _atWorkingCopy {
    final ({GraphLayout layout, int node})? at = _mutableNode;
    return at != null && at.layout.workingCopyIndex == at.node;
  }

  /// The verb the composer's button names and runs on a click (Story 10.48): on @ a part (a partial pick, or some
  /// files whole) is Split, everything whole — or nothing picked — Commit; another change is always Split; null when
  /// it shows no composer.
  ComposerVerb? get composerVerb {
    if (!composing) {
      return null;
    }
    if (!_atWorkingCopy) {
      return ComposerVerb.split;
    }
    return pickedCount > 0 && !allPicked ? ComposerVerb.split : ComposerVerb.commit;
  }

  /// The alternative the button's chevron offers: Commit beside @'s Split; else null (a plain button).
  ComposerVerb? get composerAlternative =>
      composerVerb == ComposerVerb.split && _atWorkingCopy ? ComposerVerb.commit : null;

  /// What the composer runs for the selection with [verb] (default [composerVerb]) — `jj commit` on @ (no paths when
  /// every file is checked), `jj split -r` with the checked paths (a renamed file with its source); with a partial
  /// pick both take the hunk selection instead (Story 10.26); null when it shows no composer, nothing is checked or
  /// [verb] is neither [composerVerb] nor [composerAlternative].
  GraphAction? composerActionAs([ComposerVerb? verb]) => _composer(verb, short: false);

  /// [composerActionAs] for [composerVerb].
  GraphAction? get composerAction => composerActionAs();

  /// [composerActionAs]'s command as the composer previews it — the change named by its short id, as the inspector's
  /// other buttons show theirs; null without an action.
  String? composerCommandAs([ComposerVerb? verb]) => _composer(verb, short: true)?.command;

  /// [composerCommandAs] for [composerVerb].
  String? get composerCommand => composerCommandAs();

  /// [composerCommandAs] with each `-m` paragraph longer than [keep] characters cut to its first [keep] and "…": the
  /// command line shortens the message, never the change id or the paths.
  String? composerCommandCut(int keep, {ComposerVerb? verb}) => _composer(verb, short: true, keep: keep)?.command;

  /// The selection's local bookmarks, by name in jj's order (Story 10.48): what the composer's preview places.
  List<String> get composerBookmarks {
    final ({GraphLayout layout, int node})? at = _mutableNode;
    if (at == null) {
      return const <String>[];
    }
    return <String>[
      for (final GraphRef ref in at.layout.refsOf(at.node))
        if (ref.remote == null) ref.name,
    ];
  }

  /// Where [verb] leaves the selection's bookmarks: `jj commit` on the selected part (the change keeps them); `jj split`
  /// on the rest while `split.legacy-bookmark-behavior` is true (jj's default), on the selected part while it is false;
  /// null while that is unknown (unread, refused or no boolean).
  ComposerPart? bookmarksLandOn(ComposerVerb verb) => switch (verb) {
    ComposerVerb.commit => ComposerPart.selected,
    ComposerVerb.split => switch (_legacyBookmarks) {
      true => ComposerPart.rest,
      false => ComposerPart.selected,
      null => null,
    },
  };

  /// Whether the button's verb and its alternative leave the bookmarks on different parts: the menu rows then say
  /// where.
  bool get composerBookmarksDiffer {
    final ComposerVerb? verb = composerVerb;
    final ComposerVerb? alternative = composerAlternative;
    if (verb == null || alternative == null || composerBookmarks.isEmpty) {
      return false;
    }
    final ComposerPart? here = bookmarksLandOn(verb);
    final ComposerPart? there = bookmarksLandOn(alternative);
    return here != null && there != null && here != there;
  }

  /// Whether the split would take every file of a change other than @ and leave it empty: the composer shows only its
  /// hint and Cancel.
  bool get splitsEverything {
    final ({GraphLayout layout, int node})? at = _mutableNode;
    return at != null && at.layout.workingCopyIndex != at.node && allPicked;
  }

  GraphAction? _composer(ComposerVerb? asked, {required bool short, int? keep}) {
    final ({GraphLayout layout, int node})? at = _mutableNode;
    final String? key = _key;
    final ComposerVerb? verb = asked ?? composerVerb;
    if (at == null || key == null || !composing || pickedCount == 0) {
      return null;
    }
    if (verb == null || (verb != composerVerb && verb != composerAlternative)) {
      return null;
    }
    final paragraphs = <String>[
      for (final String paragraph in paragraphsOf(composerFields))
        if (keep != null && paragraph.characters.length > keep)
          '${paragraph.characters.take(keep)}…' // l10n-ignore: the ellipsis of a cut message
        else
          paragraph,
    ];
    final commit = verb == ComposerVerb.commit;
    final String id = short ? graphShortId(at.layout, at.node) : key;
    final List<FileChange> files = _entry?.fileChanges ?? const <FileChange>[];
    // A rename picked whole selects its source's removal too (deferred I1): `jj commit root:new root:old`.
    String? source(FileChange file) => file.kind == FileChangeKind.renamed ? file.fromPath : null;
    if (_partial.isEmpty) {
      final paths = <String>[
        for (final FileChange file in files)
          if (_picked.contains(file.path)) ...<String>[file.path, ?source(file)],
      ];
      return commit
          ? GraphCommit(key, message: paragraphs, paths: allPicked ? const <String>[] : paths)
          : GraphSplit(id, message: paragraphs, paths: paths);
    }
    final hunks = HunkChoice(
      left: _entry?.parentTreeIds ?? const <String>[],
      files: <FileSelection>[
        for (final FileChange file in files)
          if (_picked.contains(file.path)) ...<FileSelection>[
            FileSelection.whole(file.path),
            if (source(file) case final String from) FileSelection.whole(from),
          ] else if (_partial[file.path] case final pick?)
            _selection(file.path, pick),
      ],
    );
    return commit
        ? GraphCommit(key, message: paragraphs, hunks: hunks)
        : GraphSplit(id, message: paragraphs, hunks: hunks);
  }

  /// [path]'s partial [pick] as a selection, its keys in section order.
  FileSelection _selection(String path, ({Set<HunkKey> keys, bool mode}) pick) {
    final keys = <HunkKey>[
      for (final HunkKey key in _summary?[path]?.sections ?? const <HunkKey>[])
        if (pick.keys.contains(key)) key,
    ];
    return pick.mode ? FileSelection.modeAndHunks(path, keys) : FileSelection.hunks(path, keys);
  }

  /// Runs [composerActionAs] [verb] (default [composerVerb]) through the runner: done clears the key's drafts (the
  /// composer's and the title's — the change was described) and checks; a refusal stays in [composerError], the draft
  /// and checks with it. Nothing runs while [splitsEverything].
  Future<GraphActionResult?> runComposer([ComposerVerb? verb]) async {
    final GraphAction? action = composerActionAs(verb);
    final String? key = _key;
    if (action == null || key == null || splitsEverything) {
      return null;
    }
    _composerError = null;
    _notify();
    final GraphActionResult result = await graph.run(action);
    switch (result) {
      case GraphActionDone():
        _composerDrafts.remove(key);
        _drafts.remove(key);
        if (_key == key) {
          _picked.clear();
          _partial.clear();
        }
      case GraphActionRefused(:final ZanshinFfiException error):
        if (_key == key) {
          _composerError = error;
        }
      case GraphActionDisabled():
        break;
    }
    _notify();
    return result;
  }

  /// Squash into parent (the inspector's, the card menu's, Change › Squash): selects [key], then asks
  /// `squashPlan`; a combined description opens the squash form pre-filled with it, else — none, or a refused plan,
  /// which the squash refuses alike — `jj squash -r` runs at once.
  Future<void> squash(String key) async {
    graph.select(key);
    String? combined;
    try {
      combined = (await details.squashPlan(key)).combinedDescription;
    } on ZanshinFfiException catch (error) {
      _log.warning('squashPlan refused: ${error.code}');
    }
    if (_disposed) {
      return;
    }
    if (combined == null) {
      await graph.run(GraphSquash(revision: key));
      return;
    }
    if (graph.selected == key) {
      _squashForm = (key: key, initial: draftFrom(combined));
      _notify();
    }
  }

  /// The squash form's prefill while it is open for [key].
  InspectorDraft? squashFormOf(String key) => _squashForm?.key == key ? _squashForm!.initial : null;

  /// Closes the squash form; nothing runs.
  void closeSquash() {
    if (_squashForm != null) {
      _squashForm = null;
      _notify();
    }
  }

  /// Saves the squash form: `jj squash -r` with [draft] as the edited description; the form closes once it ran.
  Future<GraphActionResult> saveSquash(String key, InspectorDraft draft) async {
    final GraphActionResult result = await graph.run(
      GraphSquash(revision: key, editedDescription: joinMessageParagraphs(paragraphsOf(draft))),
    );
    if (result is GraphActionDone && _squashForm?.key == key) {
      closeSquash();
    }
    return result;
  }

  void _graphChanged() {
    final String? key = graph.selected;
    final GraphLayout? layout = graph.layout;
    final int? node = key == null ? null : layout?.indexOfKey(key);
    final String? op = layout?.operationId;
    final stale = graph.stale != null;
    if (key == _key && op == _op && stale == _stale) {
      return;
    }
    if (key != _key) {
      // Leaving a change keeps its form open only for a draft that differs; `dirty` reads the old key's entry.
      if (_key case final String left when !dirty(left)) {
        _open.remove(left);
      }
      _entry = null;
      _actions = null;
      _clearDiff();
      _picked.clear();
      _partial.clear();
      _pickedFor = null;
      _composerError = null;
    }
    // A new operation may have rewritten the change or its parent: the combined description is gone with it.
    if (key != _key || op != _op || stale) {
      _squashForm = null;
    }
    _key = key;
    _op = op;
    _stale = stale;
    _error = null;
    final int serial = ++_serial;
    if (node == null || stale) {
      _entry = null;
      _actions = null;
      _clearDiff();
      _loading = false;
      _notify();
      return;
    }
    unawaited(_fetch(serial, layout!, node));
  }

  void _clearDiff() {
    _summary = null;
    _changeId = null;
    _commitId = null;
    _focused = null;
    _focusedDiff = null;
    _focusedRevision = null;
    _previousDiff = null;
    _focusedIgnoring = null;
    _previousIgnoring = null;
    _focusError = null;
    _focusSerial++;
  }

  Future<void> _fetch(int serial, GraphLayout layout, int node) async {
    _loading = true;
    _notify();
    final bool mutable = node != layout.rootIndex && !layout.isImmutable(node);
    final String changeId = layout.changeIdOf(node);
    final String commitId = layout.commitIdOf(node);
    final Future<ChangeActions?> previews = mutable ? _previews(changeId) : Future<ChangeActions?>.value();
    final Future<Diff?> summary = _summaryRead(commitId);
    try {
      final ShowEntry entry = await details.show(commitId);
      final ChangeActions? actions = await previews;
      final Diff? diff = await summary;
      if (serial == _serial) {
        _entry = entry;
        _actions = actions;
        _summary = diff == null ? null : <String, FileDiff>{for (final FileDiff file in diff.files) file.path: file};
        _changeId = changeId;
        _commitId = commitId;
        // A hidden or divergent node is keyed by its commit id: its change's other commits keep their marks.
        if (diff != null && layout.keyOf(node) == changeId) {
          _pruneViewed(changeId, diff.files);
        }
        final List<String> paths = _listed;
        if (_pickedFor != _key) {
          // @ starts with every file checked, another change with none.
          _pickedFor = _key;
          _picked
            ..clear()
            ..addAll(mutable && node == layout.workingCopyIndex ? paths : const <String>[]);
          _partial.clear();
        } else {
          _picked.retainAll(paths);
          _remapPartials();
        }
        final String? focused = paths.contains(_focused) ? _focused : paths.firstOrNull;
        if (focused != _focused) {
          _focusedDiff = null;
          _previousDiff = null;
          _focusedIgnoring = null;
          _previousIgnoring = null;
          _focusError = null;
        }
        _focused = focused;
        _loadFocus();
      }
    } on ZanshinFfiException catch (error) {
      _log.warning('show refused: ${error.code}');
      if (serial == _serial) {
        _entry = null;
        _actions = null;
        _error = error;
        _clearDiff();
      }
    } finally {
      if (serial == _serial) {
        _loading = false;
        _notify();
      }
    }
  }

  // Drops [changeId]'s marks of files it no longer lists or whose content changed (Story 10.37).
  void _pruneViewed(String changeId, List<FileDiff> files) {
    final current = <String>{for (final FileDiff file in files) viewedKey(changeId, file.path, file.fingerprint)};
    final int before = _viewed.length;
    _viewed.removeWhere((key) => key.startsWith('$changeId:') && !current.contains(key));
    if (_viewed.length != before) {
      _viewedStore.save(_viewed);
    }
  }

  /// The previews, or null when they fail (only Squash's reason reads them).
  Future<ChangeActions?> _previews(String changeId) async {
    try {
      return await details.changeActions(changeId);
    } on ZanshinFfiException catch (error) {
      _log.warning('changeActions refused: ${error.code}');
      return null;
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    graph.removeListener(_graphChanged);
    settings.removeListener(_settingsChanged);
    _viewedStore.removeListener(_viewedChanged);
    super.dispose();
  }
}

/// The inspector (Story 10.8; DS ui_kits/desktop/inspector.jsx, kit.css:90-128): the selected change on the panel
/// island. Story 10.38 (design `Inspector Study.html`, DESIGN-SYSTEM-SYNC #25): a fixed header, a top part at its
/// natural height up to 48 % of the space below the header (then it scrolls: the title or a form, meta, chips,
/// actions), and the split of files and diff filling the rest; the composer at the bottom. The split puts the files
/// beside the diff once the inspector is 780 points wide and above it below 740; between the two the last layout stays.
///
/// - **Header:** the full change id, jj's unique prefix bold (one `Text.rich`, the commit id as its tooltip); the
///   flags "@ Working copy" (gold), Immutable (the hatch swatch; not on the root), Empty, Merge, Conflict; Close (Esc).
/// - **Title = describe:** the subject in `--type-inspector-title` and the rest of the description (at most 3 lines,
///   then "Show more" / "Show less"); on a mutable
///   change it is a control that opens the describe form (the pen on hover or focus), an undescribed one reading
///   "Describe this change…". The form replaces it in place: Summary and Details, ↩ in Summary or ⌘↩ save, the
///   command, Cancel and the gold Save.
/// - **Meta:** author · date · parents; **chips:** the bookmarks with ✓ / local / remote.
/// - **Actions** (hidden while the form is open): immutable "New change on top"; @ "New change", "Squash ▾",
///   "Abandon"; else "Edit", "Squash ▾", "Abandon" — each tooltip the full command. The Squash menu button (Story
///   10.36) opens "Squash into parent" and "Absorb into ancestors", each row's command its hint and its tooltip the
///   reason it is off, else the command: Squash is disabled only with jj's refusal and opens the squash form when jj
///   would ask for a combined description (Story 10.25); Absorb with jj's refusal, or when no hunk is absorbable.
/// - **Changes:** the files pane — the file count, the viewed counter with Mark all / Reset, one row per file with its
///   quiet word and ✓ in a scroll of its own (one Tab stop with Finder's keys: ↑ ↓ show the next file, Space picks, V
///   marks Viewed) — and the focused file's diff block (Story 10.24) with a divider between them whose share is
///   remembered per layout; or the empty, stale or refusal text. On a mutable change each row and the header have a
///   checkbox, and a hunk of several parts a checkbox per part; each pane shows its unpicked boxes only while the
///   pointer or keyboard focus is in it (Story 10.42, [InspectorCheckReveal]).
/// - **Composer** (Story 10.25; DS inspector.jsx:40-79, kit.css:129-144): at the island's bottom while composing.
/// - **Esc:** the squash form closes; in a composer field with a draft it leaves the field; in a field with a changed
///   describe draft it leaves the field; else it closes the form, else on another change than @ it clears the picks
///   (Story 10.26), else the selection.
class GraphInspector extends StatefulWidget {
  /// The inspector of [model].
  const GraphInspector({required this.model, super.key});

  /// The model.
  final InspectorViewModel model;

  @override
  State<GraphInspector> createState() => _GraphInspectorState();
}

class _GraphInspectorState extends State<GraphInspector> {
  final _scroll = ScrollController();
  final _root = FocusNode(debugLabel: 'inspector', skipTraversal: true);
  final _composerFocus = FocusNode(debugLabel: 'inspector composer', skipTraversal: true);

  /// The last panel built, shown while the shell plays the exit after the selection went.
  Widget? _last;

  /// Whether the files sit beside the diff; null until the first build.
  bool? _wide;

  /// The layout of the split at [width] (Story 10.38): beside from 780 points, above below 740, the last one between.
  bool _wideAt(double width) => _wide = switch (_wide) {
    true => width >= 740,
    false || null => width >= 780,
  };

  @override
  void dispose() {
    _scroll.dispose();
    _root.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  InspectorViewModel get _model => widget.model;

  /// Whether the primary focus is in a text field.
  static bool get _typing {
    final BuildContext? context = FocusManager.instance.primaryFocus?.context;
    return context != null &&
        (context.widget is EditableText || context.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    final String? key = _model.graph.selected;
    if (key == null) {
      return KeyEventResult.ignored;
    }
    if (_model.squashFormOf(key) != null) {
      _model.closeSquash();
      _root.requestFocus();
      return KeyEventResult.handled;
    }
    final InspectorDraft? composed = _model.composerDraftOf(key);
    if (_typing &&
        _composerFocus.hasFocus &&
        composed != null &&
        (composed.summary.isNotEmpty || composed.details.isNotEmpty)) {
      _root.requestFocus();
      return KeyEventResult.handled;
    }
    final GraphLayout? layout = _model.graph.layout;
    final int? node = layout?.indexOfKey(key);
    if (node != null && _editing(layout!, node) != null) {
      if (!(_typing && _model.dirty(key))) {
        _model.closeForm(key);
      }
      _root.requestFocus();
      return KeyEventResult.handled;
    }
    // Story 10.26: on another change the picks go first, the panel stays; the next Esc closes it.
    if (node != null && node != layout!.workingCopyIndex && _model.pickedCount > 0) {
      _model.clearPicks();
      return KeyEventResult.handled;
    }
    _model.graph.select(null);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final GraphViewModel graph = _model.graph;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[_model, graph, graph.content, graph.now]),
      builder: (context, _) {
        final GraphLayout? layout = graph.layout;
        final String? key = graph.selected;
        final int? node = key == null ? null : layout?.indexOfKey(key);
        if (node == null) {
          return _last ?? const SizedBox.shrink();
        }
        return _last = _panel(context, layout!, node);
      },
    );
  }

  /// The entry the describe form prefills from while the form shows: open, read, mutable, not stale; else null.
  ShowEntry? _editing(GraphLayout layout, int node) {
    final bool immutable = node == layout.rootIndex || layout.isImmutable(node);
    return _model.isOpen(layout.keyOf(node)) && !immutable && _model.graph.stale == null ? _model.entry : null;
  }

  Widget _panel(BuildContext context, GraphLayout layout, int node) {
    final AppLocalizations strings = context.l10n;
    final GraphViewModel graph = _model.graph;
    final data = GraphCardData.of(layout, node, content: graph.content);
    final ShowEntry? entry = _model.entry;
    final ShowEntry? editing = _editing(layout, node);
    final bool mutable = node != layout.rootIndex && !layout.isImmutable(node) && graph.stale == null;
    final InspectorDraft? squashing = mutable ? _model.squashFormOf(data.key) : null;
    final ZsMotion motion = ZsMotion.of(context);
    void refocus() {
      // A save can end after the inspector went (a reload dropped the selection, Close).
      if (mounted) {
        _root.requestFocus();
      }
    }

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: strings.inspectorLabel,
      child: Focus(
        focusNode: _root,
        onKeyEvent: _onKey,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final bool wide = _wideAt(constraints.maxWidth);
            return ZsIsland(
              shape: ZsIslandShape.panel,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _Header(data: data, layout: layout, node: node, entry: entry, onClose: () => graph.select(null)),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, body) => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          // The top part keeps its natural height up to 48 % of the body, then scrolls.
                          ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: body.maxHeight * .48),
                            child: ZsScrollArea(
                              controller: _scroll,
                              label: strings.inspectorLabel,
                              identifier: 'inspector-body',
                              child: SingleChildScrollView(
                                controller: _scroll,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: <Widget>[
                                    if (squashing != null)
                                      _DescribeForm(
                                        key: ValueKey<String>('squash ${data.key}'),
                                        model: _model,
                                        changeKey: data.key,
                                        initial: squashing,
                                        blocked: graphBlockedReason(strings, graph),
                                        squashCommand: GraphSquash(revision: graphShortId(layout, node)).command,
                                        onClosed: refocus,
                                      )
                                    else if (editing != null)
                                      _DescribeForm(
                                        key: ValueKey<String>(data.key),
                                        model: _model,
                                        changeKey: data.key,
                                        initial:
                                            _model.draftOf(data.key) ??
                                            InspectorViewModel.draftFrom(editing.change.description),
                                        blocked: graphBlockedReason(strings, graph),
                                        onClosed: refocus,
                                      )
                                    else
                                      _Title(model: _model, data: data, entry: entry),
                                    _Meta(
                                      data: data,
                                      layout: layout,
                                      node: node,
                                      entry: entry,
                                      nowMs: graph.now.value,
                                      onJump: graph.goTo,
                                    ),
                                    if (data.refs.isNotEmpty || data.tags.isNotEmpty)
                                      _Chips(
                                        refs: data.refs,
                                        tags: data.tags,
                                        drag: graph.actionsEnabled ? graph.drag : null,
                                      ),
                                    if (editing == null && squashing == null)
                                      _Actions(model: _model, data: data, layout: layout, node: node),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: _Changes(model: _model, data: data, wide: wide),
                          ),
                        ],
                      ),
                    ),
                  ),
                  ZsPresence(
                    key: ValueKey<String>('composer ${data.key}'),
                    open: _model.composing,
                    exit: motion.durExitLg,
                    builder: (context, closing) => _ComposerMotion(
                      closing: closing,
                      child: ExcludeFocus(
                        excluding: closing,
                        child: Focus(
                          focusNode: _composerFocus,
                          child: _Composer(
                            model: _model,
                            data: data,
                            shortId: graphShortId(layout, node),
                            blocked: graphBlockedReason(strings, graph),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Why the graph's actions are disabled (the inspector's, the card menu's), or null when they may run.
String? graphBlockedReason(AppLocalizations strings, GraphViewModel graph) => graph.stale != null
    ? strings.staleTitle
    : !graph.actionsEnabled
    ? strings.inspectorBusy
    : null;

/// [node]'s id as a command shows it: max(jj's unique prefix, 8) of the change id; a hidden or divergent node's key is
/// its commit id.
String graphShortId(GraphLayout layout, int node) => graphShortIdOf(
  key: layout.keyOf(node),
  changeId: layout.changeIdOf(node),
  prefix: layout.changeIdPrefixLengthOf(node),
);

/// A flag's look (DS components/graph/Flag.jsx; graph.css:60-62).
enum _FlagKind { neutral, workingCopy, warn }

/// A status pill in the header (DS components/graph/Flag): 20 high, padding 0 8, `--radius-pill`, 500 `--fs-sm`;
/// neutral `--fl-hover` / `--text-dim`, @ `--co` / `--co-ink` 600, warn `--warn-bg` / `--warn`. The icon slot takes a
/// widget (the hatch swatch).
class _Flag extends StatelessWidget {
  const _Flag({required this.label, this.kind = _FlagKind.neutral, this.icon, this.tooltip});

  final String label;
  final _FlagKind kind;
  final Widget? icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final (Color fill, Color ink) = switch (kind) {
      _FlagKind.neutral => (colors.flHover, colors.textDim),
      _FlagKind.workingCopy => (colors.co, colors.coInk),
      _FlagKind.warn => (colors.warnBg, colors.warn),
    };
    final FontWeight weight = kind == _FlagKind.workingCopy ? FontWeight.w600 : FontWeight.w500;
    final Widget pill = Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusPill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: <Widget>[
          ?icon,
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZsType.control.copyWith(
                fontSize: ZsType.fsSm,
                fontWeight: weight,
                fontVariations: <FontVariation>[FontVariation.weight(weight.value.toDouble())],
                color: ink,
              ),
            ),
          ),
        ],
      ),
    );
    final String? tooltip = this.tooltip;
    return tooltip == null ? pill : ZsTooltip(message: tooltip, child: pill);
  }
}

/// An id that copies itself (Story 10.30): [full] cut to [shown] chars, the first [prefix] bold in `--text`, an
/// optional [subscript] (`jj` / `git`) lowered in `--text-faint`. "Click to copy" over the full id is its tooltip; a
/// click writes [full] to the clipboard and shows "Copied" briefly; a failed write opens a popover with [full] as
/// selectable text until a tap outside or Esc. A Tab stop: ↩ / Space copy too, and the result is announced.
class _CopyId extends StatefulWidget {
  const _CopyId({
    required this.full,
    required this.shown,
    required this.style,
    this.prefix = 0,
    this.bold,
    this.subscript,
    this.identifier,
    super.key,
  });

  final String full;
  final int shown;
  final int prefix;
  final TextStyle style;

  /// The prefix's colour; [style]'s when null.
  final Color? bold;
  final String? subscript;
  final String? identifier;

  /// How long "Copied" shows.
  static const _copiedFor = Duration(milliseconds: 1300);

  @override
  State<_CopyId> createState() => _CopyIdState();
}

class _CopyIdState extends State<_CopyId> with SingleTickerProviderStateMixin {
  final _link = LayerLink();
  final _copied = OverlayPortalController();
  final _failed = OverlayPortalController();
  late final _fade = AnimationController(vsync: this);
  final _popoverFocus = FocusNode(debugLabel: 'copy id popover');
  final _idFocus = FocusNode(debugLabel: 'copy id');
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ZsMotion motion = ZsMotion.of(context);
    _fade
      ..duration = motion.durHover
      ..reverseDuration = motion.durExit;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fade.dispose();
    _popoverFocus.dispose();
    _idFocus.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.full));
    } on Exception {
      if (mounted) {
        _copied.hide();
        _failed.show();
        _announce(context.l10n.inspectorIdCopyFailed);
        // Take focus even from a focused graph, so Esc reaches the popover first.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _failed.isShowing) {
            _popoverFocus.requestFocus();
          }
        });
      }
      return;
    }
    if (!mounted) {
      return;
    }
    _timer?.cancel();
    _failed.hide();
    _copied.show();
    _announce(context.l10n.inspectorIdCopied);
    _fade.forward(from: 0);
    _timer = Timer(_CopyId._copiedFor, () async {
      await _fade.reverse();
      if (mounted) {
        _copied.hide();
      }
    });
  }

  /// The bubble and the popover are overlays outside the id's node: VoiceOver hears them only announced.
  void _announce(String message) =>
      unawaited(SemanticsService.sendAnnouncement(View.of(context), message, Directionality.of(context)));

  Widget _below(Widget child) => Positioned(
    left: 0,
    top: 0,
    child: CompositedTransformFollower(
      link: _link,
      targetAnchor: Alignment.bottomLeft,
      offset: const Offset(0, 8),
      child: child,
    ),
  );

  Widget _popover(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return _below(
      TapRegion(
        onTapOutside: (_) => _failed.hide(),
        child: Focus(
          focusNode: _popoverFocus,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
              _failed.hide();
              // Focus goes back to the id, not into the void the popover leaves.
              _idFocus.requestFocus();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: ZsMenuMaterial(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Semantics(
              identifier: '${widget.identifier}-popover',
              child: SelectionArea(
                child: Text(widget.full, style: ZsType.id.copyWith(color: colors.text)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final String full = widget.full;
    final int shown = widget.shown.clamp(0, full.length);
    final int prefix = widget.prefix.clamp(0, shown);
    final String? subscript = widget.subscript;
    final Widget text = Text.rich(
      TextSpan(
        style: widget.style,
        children: <InlineSpan>[
          if (prefix > 0)
            TextSpan(
              text: full.substring(0, prefix),
              style: widget.style.copyWith(
                fontWeight: FontWeight.w600,
                fontVariations: const <FontVariation>[FontVariation.weight(600)],
                color: widget.bold,
              ),
            ),
          TextSpan(text: full.substring(prefix, shown)),
          if (subscript != null)
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: Transform.translate(
                offset: const Offset(1, 3),
                child: Text(
                  subscript,
                  style: ZsType.id.copyWith(fontSize: ZsType.fs2xs, color: colors.textFaint),
                ),
              ),
            ),
        ],
      ),
      maxLines: 1,
      softWrap: false,
    );
    return OverlayPortal(
      controller: _failed,
      overlayChildBuilder: _popover,
      child: OverlayPortal(
        controller: _copied,
        overlayChildBuilder: (context) => _below(
          IgnorePointer(
            child: ZsTooltipBubble(animation: _fade, message: context.l10n.inspectorIdCopied),
          ),
        ),
        child: CompositedTransformTarget(
          link: _link,
          child: ZsTooltip(
            message: context.l10n.inspectorCopyId,
            cmd: full,
            child: ZsControlCore(
              identifier: widget.identifier,
              focusNode: _idFocus,
              onActivate: _copy,
              cursor: SystemMouseCursors.click,
              ring: ZsRingPlacement.outside,
              ringRadius: 3,
              semantics: SemanticsProperties(button: true, label: full, hint: context.l10n.inspectorCopyIdHint),
              builder: (context, status) => text,
            ),
          ),
        ),
      ),
    );
  }
}

/// The header (DS kit.css:91-94): padding 14 12 0 20, gap 10, at least 42 high.
class _Header extends StatelessWidget {
  const _Header({
    required this.data,
    required this.layout,
    required this.node,
    required this.entry,
    required this.onClose,
  });

  final GraphCardData data;
  final GraphLayout layout;
  final int node;
  final ShowEntry? entry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final String id = data.changeId;
    final String commit = layout.commitIdOf(node);
    final TextStyle idStyle = ZsType.id.copyWith(fontSize: ZsType.fsMd, color: colors.textFaint);
    final GraphCommitContent? content = data.content;
    final bool conflict = (content?.conflict ?? false) || entry?.change.conflict == ConflictState.conflicted;
    final bool empty = content?.empty ?? (entry != null && entry!.fileChanges.isEmpty && !data.merge);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 42),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 0),
        child: Row(
          spacing: 10,
          children: <Widget>[
            // Story 10.30: the short change and commit ids as the card's (max(prefix, 8)), each copying its full id.
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: <Widget>[
                _CopyId(
                  key: const ValueKey<String>('inspector-id'),
                  full: id,
                  prefix: data.prefixLength,
                  shown: math.max(data.prefixLength, 8),
                  style: idStyle,
                  bold: colors.text,
                  subscript: 'jj', // l10n-ignore: the tool's name
                  identifier: 'inspector-change-id',
                ),
                _CopyId(
                  key: const ValueKey<String>('inspector-commit-id'),
                  full: commit,
                  prefix: data.commitPrefixLength,
                  shown: math.max(data.commitPrefixLength, 8),
                  style: idStyle,
                  bold: colors.text,
                  subscript: 'git', // l10n-ignore: the tool's name
                  identifier: 'inspector-commit-id',
                ),
              ],
            ),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  if (data.isWorkingCopy) _Flag(label: strings.inspectorFlagWorkingCopy, kind: _FlagKind.workingCopy),
                  if (data.immutable && !data.isRoot)
                    // The tooltip names the reason once the scope answers it (Story 11.7).
                    ImmutableReasonBuilder(
                      operationId: layout.operationId,
                      commitId: data.commitId,
                      builder: (context, reason) => _Flag(
                        label: strings.inspectorFlagImmutable,
                        icon: const HatchSwatch(),
                        tooltip: reason == null
                            ? strings.inspectorFlagImmutable
                            : strings.inspectorFlagImmutableReason(reason),
                      ),
                    ),
                  if (empty) _Flag(label: strings.inspectorFlagEmpty),
                  if (data.merge) _Flag(label: strings.inspectorFlagMerge),
                  if (conflict)
                    _Flag(
                      label: strings.inspectorFlagConflict,
                      kind: _FlagKind.warn,
                      icon: ZanshinIcon(ZI.conflict, size: ZsIconSize.sm, color: colors.warn),
                    ),
                ],
              ),
            ),
            ZsIconButton(
              icon: ZI.close,
              label: strings.inspectorClose,
              size: ZsIconButtonSize.sm,
              identifier: 'inspector-close',
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// The description split for the title: the subject and the rest; null while unknown.
({String subject, String body})? _texts(GraphCardData data, ShowEntry? entry) {
  if (entry != null) {
    final InspectorDraft parts = InspectorViewModel.draftFrom(entry.change.description);
    return (subject: parts.summary, body: parts.details);
  }
  final GraphCommitContent? content = data.content;
  return content == null ? null : (subject: content.subject, body: '');
}

/// The title (DS kit.css:98-105): margin 8 12 0, padding 4 8 6, radius 10; on a mutable change a control whose hover
/// and focus show `--fl-hover` and the pen.
class _Title extends StatelessWidget {
  const _Title({required this.model, required this.data, required this.entry});

  final InspectorViewModel model;
  final GraphCardData data;
  final ShowEntry? entry;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final ({String subject, String body})? texts = _texts(data, entry);
    final bool mutable = !data.immutable;
    final bool undescribed = texts != null && texts.subject.isEmpty;
    final String subject = !undescribed
        ? texts?.subject ?? ''
        : mutable
        ? strings.inspectorDescribePlaceholder
        : strings.inspectorNoDescription;
    final TextStyle style = undescribed
        ? ZsType.inspectorTitle.copyWith(
            fontWeight: FontWeight.w500,
            fontVariations: const <FontVariation>[FontVariation.weight(500)],
            fontStyle: FontStyle.italic,
            color: colors.textDim,
          )
        : ZsType.inspectorTitle.copyWith(color: colors.text);
    Widget content(bool pen) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text.rich(
          TextSpan(
            style: style,
            children: <InlineSpan>[
              TextSpan(text: subject),
              if (pen)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: ZanshinIcon(ZI.describe, size: ZsIconSize.sm, color: colors.textFaint),
                  ),
                ),
            ],
          ),
        ),
        if (texts != null && texts.body.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            // Keyed by the change: another selection starts closed.
            child: _Description(
              key: ValueKey<String>(data.key),
              text: texts.body,
              style: ZsType.body.copyWith(color: colors.textMuted),
            ),
          ),
      ],
    );
    const padding = EdgeInsets.fromLTRB(8, 4, 8, 6);
    const margin = EdgeInsets.fromLTRB(12, 8, 12, 0);
    if (!mutable) {
      return Padding(
        padding: margin,
        child: Padding(padding: padding, child: content(false)),
      );
    }
    final String? reason = model.graph.stale != null ? strings.staleTitle : null;
    final bool ready = entry != null && reason == null;
    return Padding(
      padding: margin,
      child: ZsControlCore(
        identifier: 'inspector-title',
        enabled: ready,
        disabledReason: reason,
        dimWhenDisabled: false,
        onActivate: () => model.openForm(data.key),
        ring: ZsRingPlacement.inside,
        ringRadius: 10,
        semantics: SemanticsProperties(
          button: true,
          // While the description loads the subject is empty.
          label: subject.isEmpty ? strings.inspectorDescribePlaceholder : subject,
          hint: strings.inspectorDescribeHint,
        ),
        builder: (context, status) {
          final bool lit = ready && (status.hovered || status.focusVisible);
          return AnimatedContainer(
            duration: ZsMotion.of(context).durHover,
            padding: padding,
            decoration: BoxDecoration(
              color: lit ? colors.flHover : colors.flHover.withValues(alpha: 0),
              borderRadius: BorderRadius.circular(10),
            ),
            child: content(lit),
          );
        },
      ),
    );
  }
}

/// The description body under the subject (Story 10.38; design inspector-study.css:60-63): at most 3 lines, then
/// "Show more" (12 px, weight 500, `--accent`) under it while it is cut; open, all of it and "Show less". The button
/// is its own control, so it never opens the describe form around it.
class _Description extends StatefulWidget {
  const _Description({required this.text, required this.style, super.key});

  final String text;
  final TextStyle style;

  @override
  State<_Description> createState() => _DescriptionState();
}

class _DescriptionState extends State<_Description> {
  static const _lines = 3;

  var _open = false;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: DefaultTextStyle.of(context).style.merge(widget.style)),
          maxLines: _lines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling,
        )..layout(maxWidth: constraints.maxWidth);
        final bool cut = painter.didExceedMaxLines;
        painter.dispose();
        final String label = _open ? strings.inspectorShowLess : strings.inspectorShowMore;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              widget.text,
              maxLines: _open ? null : _lines,
              overflow: _open ? null : TextOverflow.ellipsis,
              style: widget.style,
            ),
            if (cut)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: ZsControlCore(
                  identifier: 'inspector-description-more',
                  onActivate: () => setState(() => _open = !_open),
                  ring: ZsRingPlacement.inside,
                  ringRadius: 5,
                  semantics: SemanticsProperties(button: true, label: label),
                  builder: (context, status) => Text(
                    label,
                    style: ZsType.secondary.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      fontVariations: const <FontVariation>[FontVariation.weight(500)],
                      color: colors.accent,
                      decoration: status.hovered ? TextDecoration.underline : TextDecoration.none,
                      decorationColor: colors.accent,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The describe form (DS inspector.jsx:11-38; kit.css:125-128): margin 8 12 0, padding 10, radius 12, `--fl-hover`,
/// gap 8; Summary (lg) and Details (multiline) 6 apart; the footer the command, Cancel and the gold Save.
class _DescribeForm extends StatefulWidget {
  const _DescribeForm({
    required this.model,
    required this.changeKey,
    required this.initial,
    required this.blocked,
    required this.onClosed,
    this.squashCommand,
    super.key,
  });

  final InspectorViewModel model;
  final String changeKey;
  final InspectorDraft initial;

  /// Why Save is disabled.
  final String? blocked;

  /// In squash mode (Story 10.25) the command shown — `jj squash -r <id>`, where the CLI opens its editor — and the
  /// form saves the edited combined description through [InspectorViewModel.saveSquash]; null: describe.
  final String? squashCommand;

  /// Runs after the form closed itself.
  final VoidCallback onClosed;

  @override
  State<_DescribeForm> createState() => _DescribeFormState();
}

class _DescribeFormState extends State<_DescribeForm> {
  late final _summary = ZsTextEditingController(text: widget.initial.summary);
  late final _details = ZsTextEditingController(text: widget.initial.details);
  final _summaryFocus = FocusNode(debugLabel: 'describe summary');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _summaryFocus.requestFocus();
        _summary.selection = TextSelection(baseOffset: 0, extentOffset: _summary.text.length);
      }
    });
  }

  @override
  void dispose() {
    _summary.dispose();
    _details.dispose();
    _summaryFocus.dispose();
    super.dispose();
  }

  InspectorDraft get _draft => (summary: _summary.text, details: _details.text);

  void _changed(String _) {
    if (widget.squashCommand == null) {
      widget.model.updateDraft(widget.changeKey, _draft);
    }
    setState(() {});
  }

  void _save() {
    if (widget.blocked != null || !widget.model.graph.hasActions) {
      return;
    }
    final String key = widget.changeKey;
    if (widget.squashCommand != null) {
      unawaited(
        widget.model.saveSquash(key, _draft).then((_) {
          if (widget.model.squashFormOf(key) == null) {
            widget.onClosed();
          }
        }),
      );
      return;
    }
    unawaited(
      widget.model.save(key, _draft).then((_) {
        if (!widget.model.isOpen(key)) {
          widget.onClosed();
        }
      }),
    );
  }

  void _cancel() {
    if (widget.squashCommand != null) {
      widget.model.closeSquash();
    } else {
      widget.model.closeForm(widget.changeKey);
    }
    widget.onClosed();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final String? blocked = widget.blocked;
    final String command =
        widget.squashCommand ??
        GraphDescribe.fromParagraphs(widget.changeKey, InspectorViewModel.paragraphsOf(_draft)).command;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _save,
        const SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true): _save,
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: colors.flHover, borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 6,
              children: <Widget>[
                ZsTextField(
                  controller: _summary,
                  focusNode: _summaryFocus,
                  size: ZsTextFieldSize.lg,
                  placeholder: strings.inspectorSummary,
                  label: strings.inspectorSummary,
                  identifier: 'inspector-summary',
                  onChanged: _changed,
                  onSubmitted: (_) => _save(),
                ),
                ZsTextField(
                  controller: _details,
                  multiline: true,
                  placeholder: strings.inspectorDetails,
                  label: strings.inspectorDetails,
                  identifier: 'inspector-details',
                  onChanged: _changed,
                ),
              ],
            ),
            if (widget.squashCommand == null && widget.model.describedMeanwhile(widget.changeKey))
              Text(
                strings.inspectorDescriptionChangedMeanwhile,
                style: ZsType.secondary.copyWith(fontSize: ZsType.fsSm, color: colors.textDim),
              ),
            Row(
              spacing: 6,
              children: <Widget>[
                Expanded(
                  child: Text(
                    command,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ZsType.command.copyWith(fontSize: ZsType.fsSm, color: colors.textFaint),
                  ),
                ),
                ZsButton(label: strings.inspectorCancel, onPressed: _cancel, identifier: 'inspector-cancel'),
                ZsTooltip(
                  message: blocked ?? command,
                  cmd: blocked == null ? null : command,
                  child: ZsButton(
                    label: widget.squashCommand == null ? strings.inspectorSave : strings.inspectorSquashConfirm,
                    variant: ZsButtonVariant.primary,
                    onPressed: blocked == null && widget.model.graph.hasActions ? _save : null,
                    disabledReason: blocked,
                    identifier: 'inspector-save',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The meta line (DS kit.css:106-109): padding 4 20 0, 12.5 `--text-dim`, the parts joined by a faint "·"; the
/// parents' short ids mono in `--text-muted`, jj's unique prefix bold in `--text` as the header's, each followed by
/// its jump (Story 10.35).
class _Meta extends StatelessWidget {
  const _Meta({
    required this.data,
    required this.layout,
    required this.node,
    required this.entry,
    required this.nowMs,
    required this.onJump,
  });

  final GraphCardData data;
  final GraphLayout layout;
  final int node;
  final ShowEntry? entry;
  final int nowMs;

  /// Selects a parent by its layout key.
  final ValueChanged<String> onJump;

  /// A parent's short id, the full id it copies, its bold prefix and its layout key (null outside the layout).
  ({String short, String full, int prefix, String? key}) _inLayout(int parent) {
    final String key = layout.keyOf(parent);
    return (
      short: graphShortId(layout, parent),
      full: key,
      prefix: key == layout.changeIdOf(parent)
          ? layout.changeIdPrefixLengthOf(parent)
          : layout.commitIdPrefixLengthOf(parent),
      key: key,
    );
  }

  /// The parents: `show`'s, else the layout's direct parents (the stale state). A layout node's full id is its key,
  /// the id its short one is cut from.
  List<({String short, String full, int prefix, String? key})> _parents() {
    final List<String>? shown = entry?.change.parents;
    if (shown != null) {
      return <({String short, String full, int prefix, String? key})>[
        for (final String id in shown)
          switch (layout.indexOfKey(id)) {
            final int parent => _inLayout(parent),
            null => (short: id.substring(0, math.min(8, id.length)), full: id, prefix: 0, key: null),
          },
      ];
    }
    final ({int start, int end}) edges = layout.parentEdges(node);
    return <({String short, String full, int prefix, String? key})>[
      for (var e = edges.start; e < edges.end; e++)
        if (layout.kindOf(e) == GraphEdgeKind.direct) _inLayout(layout.parentOf(e)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final TextStyle style = ZsType.secondary.copyWith(fontSize: ZsType.fsControl, color: colors.textDim);
    final Signature? author = entry?.change.author;
    final String name = switch (author) {
      final Signature a => a.name.trim().isNotEmpty ? a.name.trim() : a.email.trim(),
      null =>
        data.content == null
            ? ''
            : data.content!.authorName.trim().isNotEmpty
            ? data.content!.authorName.trim()
            : data.content!.authorEmail.trim(),
    };
    final int? ts = data.timestampMs;
    final List<({String short, String full, int prefix, String? key})> parents = data.isRoot
        ? const <({String short, String full, int prefix, String? key})>[]
        : _parents();
    final parts = <InlineSpan>[
      if (name.isNotEmpty) TextSpan(text: name),
      if (ts != null)
        TextSpan(
          text: graphRelativeDate(strings, ts, nowMs: nowMs, utcOffsetMinutes: data.utcOffsetMinutes),
        ),
      if (parents.isNotEmpty)
        TextSpan(
          children: <InlineSpan>[
            TextSpan(text: '${strings.inspectorParents(parents.length)} '),
            for (var i = 0; i < parents.length; i++) ...<InlineSpan>[
              if (i > 0) const TextSpan(text: ' + '), // l10n-ignore: a symbol joining the parents
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: _CopyId(
                  full: parents[i].full,
                  shown: parents[i].short.length,
                  prefix: parents[i].prefix,
                  style: ZsType.id.copyWith(color: colors.textMuted),
                  bold: colors.text,
                  identifier: 'inspector-parent-$i',
                ),
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: _ParentJump(
                    short: parents[i].short,
                    onJump: switch (parents[i].key) {
                      final String key => () => onJump(key),
                      null => null,
                    },
                    identifier: 'inspector-parent-jump-$i',
                  ),
                ),
              ),
            ],
          ],
        ),
    ];
    if (parts.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Text.rich(
        key: const ValueKey<String>('inspector-meta'),
        TextSpan(
          style: style,
          children: <InlineSpan>[
            for (var i = 0; i < parts.length; i++) ...<InlineSpan>[
              if (i > 0)
                TextSpan(
                  text: '  ·  ',
                  style: TextStyle(color: colors.textFaint),
                ), // l10n-ignore: separator
              parts[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// The jump after a parent's id (Story 10.35; DS ui_kits/desktop/kit.css `.zk-ins-jump`): 20 px, radius 6, the `parent` glyph in
/// `--text-faint`, hover `--fl-hover` / `--text`, the accent ring; "Select parent `id`" as name and tooltip. Without
/// [onJump] — the parent is not in the shown graph — it is disabled with that reason.
class _ParentJump extends StatelessWidget {
  const _ParentJump({required this.short, required this.onJump, required this.identifier});

  final String short;
  final VoidCallback? onJump;
  final String identifier;

  static const double _side = 20;
  static const double _radius = 6;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final String name = strings.inspectorParentJump(short);
    final Widget button = ZsControlCore(
      identifier: identifier,
      onActivate: onJump,
      enabled: onJump != null,
      disabledReason: onJump == null ? strings.inspectorParentAbsent(short) : null,
      cursor: SystemMouseCursors.click,
      ring: ZsRingPlacement.outside,
      ringRadius: _radius,
      semantics: SemanticsProperties(button: true, label: name),
      builder: (context, status) {
        final ZsColors colors = ZsColors.of(context);
        final bool lit = status.hovered || status.pressed;
        return Container(
          width: _side,
          height: _side,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: lit ? colors.flHover : null,
            borderRadius: BorderRadius.circular(_radius),
          ),
          child: ZanshinIcon(ZI.parent, size: ZsIconSize.sm, color: lit ? colors.text : colors.textFaint),
        );
      },
    );
    return onJump == null ? button : ZsTooltip(message: name, child: button);
  }
}

/// The bookmark chips (DS BookmarkChip tag; kit.css:110; graph.css:55-57): padding 12 20 0, gap 6; each chip padding
/// 4 9, `--radius-chip`, `--fl-hover`, the filled bookmark, the name mono `--fs-id` and the state ✓ / local / remote
/// mono `--fs-xs`. The tag chips follow (Story 10.45): the same chip with the tag glyph, no state word, not draggable.
class _Chips extends StatelessWidget {
  const _Chips({required this.refs, this.tags = const <GraphRef>[], this.drag});

  final List<GraphRef> refs;

  final List<GraphRef> tags;

  /// The graph's drag (Story 10.10): a local chip drags its bookmark; null drags none.
  final GraphDrag? drag;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);

    Widget chip(GraphRef ref, Widget child) => ZsMenuAnchor(
      // Story 10.39: a right-click copies the name as the chip shows it.
      entries: <ZsMenuEntry>[
        ZsMenuItem(
          label: strings.inspectorCopyName,
          identifier: 'inspector-chip-copy',
          onSelected: () => unawaited(() async {
            try {
              await Clipboard.setData(ClipboardData(text: ref.remote == null ? ref.name : '${ref.name}@${ref.remote}'));
            } on PlatformException {
              return;
            }
            if (context.mounted) {
              announceCopied(context);
            }
          }()),
        ),
      ],
      semanticLabel: ref.name,
      identifier: 'inspector-chip-menu',
      builder: (context, menu) => GestureDetector(
        onSecondaryTapUp: (details) => menu.open(position: details.localPosition),
        child: child,
      ),
    );

    Widget body(String glyph, GraphRef ref, {Widget? state}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: colors.flHover, borderRadius: BorderRadius.circular(metrics.radiusChip)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: <Widget>[
          ZanshinIcon(glyph, size: ZsIconSize.sm, color: colors.textDim),
          Flexible(
            child: Text(
              ref.remote == null ? ref.name : '${ref.name}@${ref.remote}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZsType.id.copyWith(color: colors.text),
            ),
          ),
          ?state,
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: <Widget>[
          for (final GraphRef ref in refs)
            chip(
              ref,
              GraphDragSource(
                drag: drag,
                payload: GraphBookmarkDrag(ref.name),
                enabled: graphBookmarkDraggable(ref.name, remote: ref.remote),
                child: body(
                  ZI.bookmarkFilled,
                  ref,
                  state: Text(
                    ref.conflicted
                        ? strings.inspectorBookmarkConflicted
                        : ref.remote != null
                        ? strings.inspectorBookmarkRemote
                        : ref.synced
                        ? '✓' // l10n-ignore: a symbol for "in sync"
                        : strings.inspectorBookmarkLocal,
                    style: ZsType.id.copyWith(
                      fontSize: ZsType.fsXs,
                      color: ref.conflicted
                          ? colors.conflict
                          : ref.remote != null
                          ? colors.remote
                          : colors.textDim,
                    ),
                  ),
                ),
              ),
            ),
          for (final GraphRef tag in tags) chip(tag, body(ZI.tag, tag)),
        ],
      ),
    );
  }
}

/// The action row (DS inspector.jsx:117-124; kit.css:112): margin-top 16, padding 0 20 16, gap 6, a bottom
/// `--fl-border`; Abandon right-aligned.
class _Actions extends StatelessWidget {
  const _Actions({required this.model, required this.data, required this.layout, required this.node});

  final InspectorViewModel model;
  final GraphCardData data;
  final GraphLayout layout;
  final int node;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final GraphViewModel graph = model.graph;
    final String key = data.key;
    final String short = graphShortId(layout, node);
    final String? blocked = graphBlockedReason(strings, graph);
    final bool can = blocked == null && graph.hasActions;

    Widget button(
      String label,
      GraphAction action,
      String command, {
      required String identifier,
      ZsButtonVariant variant = ZsButtonVariant.quiet,
      String? icon,
      String? disabled,
      VoidCallback? onPressed,
    }) {
      final String? reason = blocked ?? disabled;
      return ZsTooltip(
        message: reason ?? command,
        cmd: reason == null ? null : command,
        child: ZsButton(
          label: label,
          variant: variant,
          icon: icon,
          onPressed: can && disabled == null ? onPressed ?? () => unawaited(graph.run(action)) : null,
          disabledReason: reason,
          identifier: identifier,
        ),
      );
    }

    final ActionOutcome? squash = model.actions?.squashIntoParent;
    final ActionRefusal? refusal = squash?.status == ActionStatus.refused ? squash?.refusal : null;
    final String? squashDisabled = refusal == null ? null : refusal.context ?? refusal.code;
    final String squashCommand = GraphSquash(revision: short).command;
    final ActionOutcome? absorb = model.actions?.absorb;
    final String? absorbDisabled = switch (absorb) {
      ActionOutcome(status: ActionStatus.refused, :final ActionRefusal? refusal) => refusal?.context ?? refusal?.code,
      ActionOutcome(status: ActionStatus.noOp) => strings.inspectorAbsorbNothing,
      _ => null,
    };

    /// A row of the Squash menu: [command] as its hint, its tooltip the reason it is off, else the command.
    ZsMenuItem row(String label, String command, {required String identifier, String? disabled, VoidCallback? run}) =>
        ZsMenuItem(
          label: label,
          cmd: command,
          enabled: can && disabled == null,
          tooltip: disabled ?? command,
          identifier: identifier,
          onSelected: run,
        );
    // The verbs wrap (`flex-wrap:wrap`, DS kit.css:112); Abandon stays right-aligned beside them.
    final verbs = data.immutable
        ? <Widget>[
            button(
              strings.inspectorNewOnTop,
              GraphNew(parents: <String>[key]),
              GraphNew(parents: <String>[short]).command,
              variant: ZsButtonVariant.primary,
              icon: ZI.plus,
              identifier: 'inspector-new',
            ),
          ]
        : <Widget>[
            if (data.isWorkingCopy)
              button(
                strings.newChange,
                GraphNew(parents: <String>[key]),
                GraphNew(parents: <String>[short]).command,
                variant: ZsButtonVariant.primary,
                identifier: 'inspector-new',
              )
            else
              button(
                strings.inspectorEdit,
                GraphEdit(key),
                GraphEdit(short).command,
                variant: ZsButtonVariant.primary,
                icon: ZI.workingCopyAt,
                identifier: 'inspector-edit',
              ),
            // Story 10.48: the label squashes into the parent (the squash form first when both changes carry a
            // description); the chevron offers both verbs.
            ZsSplitButton(
              label: strings.inspectorSquashMenu,
              onPressed: can && squashDisabled == null ? () => unawaited(model.squash(key)) : null,
              disabledReason: blocked ?? squashDisabled,
              tooltip: blocked ?? squashDisabled ?? squashCommand,
              cmd: (blocked ?? squashDisabled) == null ? null : squashCommand,
              menuDisabledReason:
                  blocked ??
                  (squashDisabled != null && absorbDisabled != null ? '$squashDisabled\n$absorbDisabled' : null),
              identifier: 'inspector-squash-button',
              entries: <ZsMenuEntry>[
                row(
                  strings.inspectorSquash,
                  squashCommand,
                  identifier: 'inspector-squash',
                  disabled: squashDisabled,
                  run: () => unawaited(model.squash(key)),
                ),
                row(
                  strings.inspectorAbsorb,
                  GraphAbsorb(short).command,
                  identifier: 'inspector-absorb',
                  disabled: absorbDisabled,
                  run: () => unawaited(graph.run(GraphAbsorb(key))),
                ),
              ],
            ),
          ];
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.flBorder)),
      ),
      child: Row(
        spacing: 6,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Wrap(spacing: 6, runSpacing: 6, children: verbs),
          ),
          if (!data.immutable)
            button(
              strings.inspectorAbandon,
              GraphAbandon(<String>[key]),
              GraphAbandon(<String>[short]).command,
              variant: ZsButtonVariant.danger,
              identifier: 'inspector-abandon',
            ),
        ],
      ),
    );
  }
}

/// The lengths of the inspector's split of files and diff [extent] long, the divider's band included (Story 10.38):
/// the files keep 220 (wide) or 110 (narrow), the diff 320 or 140; when both cannot fit the diff's minimum wins, and
/// the files never go below 0.
@immutable
class InspectorSplit {
  /// The split of [extent] in the [wide] or the narrow layout.
  const InspectorSplit({required this.wide, required this.extent});

  /// Whether the files sit beside the diff.
  final bool wide;

  /// The split's length along its axis.
  final double extent;

  /// What the two panes share: [extent] less the band.
  double get room => math.max(0, extent - ZsSplitDivider.band);

  /// The files' minimum.
  double get minFiles => wide ? 220 : 110;

  /// The files' maximum: what leaves the diff its minimum.
  double get maxFiles => room - (wide ? 320 : 140);

  /// The files' length at [share] of [room], clamped.
  double files(double share) => math.max(0, math.min(maxFiles, math.max(minFiles, share * room)));
}

/// The split of the files and the diff (Story 10.38; design `Inspector Study.html`, DESIGN-SYSTEM-SYNC #25; DS
/// kit.css:114-124): padding 12 16 14; [wide] puts the files left of the diff, else above it, with a [ZsSplitDivider]
/// between them ("Files and diff"). The files' share comes from the settings per layout (0.34 wide, 0.38 narrow by
/// default) and is written when a drag ends or on reset; the files keep 220 / 110 and the diff 320 / 140 (wide /
/// narrow), and when both cannot fit the diff's minimum wins.
///
/// The files pane: the header "Changes" 12.5 600 and the file count, then the rows in a scroll of their own (DS
/// components/content/FileRow, content.css:2-14). The list is one Tab stop with Finder's keys: ↑ ↓ move the current
/// row and show its diff at once — while a key repeats the row moves at once and the diff loads after an 80 ms pause
/// without further repeats; Space toggles the current file's pick on a mutable change; V toggles its Viewed mark; ↩
/// shows its diff. The current row is the focused file's (`--fl-on`), with a 1.5 px `--accent` ring while the list has
/// focus, and is scrolled into view. Or the text that takes the split's place: the stale state, a refusal, an empty
/// change.
class _Changes extends StatefulWidget {
  const _Changes({required this.model, required this.data, required this.wide});

  final InspectorViewModel model;
  final GraphCardData data;
  final bool wide;

  @override
  State<_Changes> createState() => _ChangesState();
}

class _ChangesState extends State<_Changes> {
  final _focus = FocusNode(debugLabel: 'inspector files');
  final _files = ScrollController();

  /// One key per row (`f:` a file's path, `d:` a folder's): a key that moved with the current row would carry its
  /// row's state to another row.
  final _rows = <String, GlobalKey>{};

  GlobalKey _rowKey(String key) => _rows.putIfAbsent(key, () => GlobalKey(debugLabel: 'inspector row $key'));

  static String _keyOf(InspectorListRow row) => switch (row) {
    InspectorFileListRow() => 'f:${row.path}',
    InspectorFolderListRow() => 'd:${row.path}',
  };

  /// The path a held arrow key moved to (a path, so a reload meanwhile keeps the file); its diff loads once the key
  /// pauses.
  String? _pending;
  Timer? _repeat;

  /// The tree's folder row that is current; null while a file's row is (Story 10.39).
  String? _folder;

  /// The list's context menu: the row it was opened on, and whether its path was on disk then.
  final _menu = ZsMenuController();
  final GlobalKey _list = GlobalKey(debugLabel: 'inspector files list');
  InspectorListRow? _menuRow;
  var _menuOnDisk = true;

  /// The files' share while the divider is dragged; the settings get it once the drag ends.
  double? _dragShare;

  /// The pause after a key repeat before the current row's diff loads.
  static const _repeatPause = Duration(milliseconds: 80);

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(_Changes oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.key != widget.data.key) {
      _repeat?.cancel();
      _pending = null;
      _folder = null;
      _rows.clear();
      // Another change's list starts at its top.
      if (_files.hasClients) {
        _files.jumpTo(0);
      }
    }
  }

  @override
  void dispose() {
    _repeat?.cancel();
    _focus.dispose();
    _files.dispose();
    super.dispose();
  }

  void _focusChanged() => setState(() {});

  /// The rows the list shows: jj's order flat, or the tree's visible rows.
  List<InspectorListRow> _rowsOf(List<FileChange> files) => widget.model.fileList == DiffFileListSetting.tree
      ? inspectorTreeRows(files, widget.model.collapsed)
      : inspectorFlatRows(files);

  /// The current row: the current folder's, else the one a held key moved to, else the focused file's; a file inside a
  /// collapsed folder makes its deepest shown folder current.
  int _currentOf(List<InspectorListRow> rows) {
    if (_folder case final String folder) {
      final int at = rows.indexWhere((row) => row is InspectorFolderListRow && row.path == folder);
      if (at >= 0) {
        return at;
      }
    }
    final String? current = _pending ?? widget.model.focusedPath;
    final int at = rows.indexWhere((row) => row is InspectorFileListRow && row.path == current);
    if (at >= 0 || current == null) {
      return math.max(0, at);
    }
    return math.max(
      0,
      rows.lastIndexWhere((row) => row is InspectorFolderListRow && current.startsWith('${row.path}/')),
    );
  }

  /// Shows [path]'s diff now, ending a key repeat's wait.
  void _show(String path) {
    _repeat?.cancel();
    _pending = null;
    _folder = null;
    widget.model.focus(path);
  }

  /// Makes [row] current: a file shows its diff, a folder only becomes current.
  void _select(InspectorListRow row) {
    switch (row) {
      case InspectorFileListRow(:final String path):
        _show(path);
      case InspectorFolderListRow(:final String path):
        _repeat?.cancel();
        _pending = null;
        _folder = path;
    }
  }

  /// A right-click on [row]: it becomes current, then the menu opens at the pointer with its disk state read now.
  void _openMenu(InspectorListRow row, Offset global) {
    final ProjectFiles? files = widget.model.files;
    final box = _list.currentContext?.findRenderObject() as RenderBox?;
    _focus.requestFocus();
    setState(() {
      _select(row);
      _menuRow = row;
      _menuOnDisk = files?.exists(row.path) ?? false;
    });
    if (files != null && box != null) {
      _menu.open(position: box.globalToLocal(global));
    }
  }

  void _settle() {
    final String? pending = _pending;
    final List<FileChange> files = widget.model.entry?.fileChanges ?? const <FileChange>[];
    if (pending != null && files.any((file) => file.path == pending)) {
      setState(() => _show(pending));
    } else if (pending != null) {
      // The file went in a reload: the row falls back to the focused file's.
      setState(() => _pending = null);
    }
  }

  /// Scrolls the row of [key] into view after the frame that moved the current row there.
  void _reveal(String key, {required bool down}) => WidgetsBinding.instance.addPostFrameCallback((_) {
    final BuildContext? row = _rows[key]?.currentContext;
    if (row != null && row.mounted) {
      Scrollable.ensureVisible(
        row,
        alignmentPolicy: down
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    }
  });

  KeyEventResult _onKey(FocusNode node, KeyEvent event, List<InspectorListRow> rows) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final InspectorViewModel model = widget.model;
    final int current = _currentOf(rows).clamp(0, rows.length - 1);
    final InspectorListRow row = rows[current];
    final String path = row.path;
    final List<String> paths = switch (row) {
      InspectorFolderListRow(:final List<FileChange> files) => <String>[for (final FileChange file in files) file.path],
      InspectorFileListRow() => <String>[path],
    };
    final folder = row is InspectorFolderListRow;
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final bool others = keyboard.isShiftPressed || keyboard.isAltPressed || keyboard.isControlPressed;
    final bool modified = keyboard.isMetaPressed || others;
    final LogicalKeyboardKey key = event.logicalKey;
    final down = event is KeyDownEvent;
    if (key == LogicalKeyboardKey.keyC && keyboard.isMetaPressed && !others) {
      final ProjectFiles? files = model.files;
      if (files == null) {
        return KeyEventResult.ignored;
      }
      if (down) {
        unawaited(files.copy(files.absolute(path), context));
      }
      return KeyEventResult.handled;
    }
    if (!modified && (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter)) {
      if (row case InspectorFolderListRow(:final bool open)) {
        if (down) {
          model.setCollapsed(path, collapsed: open);
        }
      } else {
        setState(() => _show(path));
      }
      return KeyEventResult.handled;
    }
    if (!modified && key == LogicalKeyboardKey.space) {
      if (!model.selectable) {
        return KeyEventResult.ignored;
      }
      if (down) {
        folder ? model.togglePicks(paths) : model.togglePick(path);
      }
      return KeyEventResult.handled;
    }
    if (!modified && key == LogicalKeyboardKey.keyV) {
      if (down) {
        model.setViewedAll(paths, viewed: !paths.every(model.isViewed));
      }
      return KeyEventResult.handled;
    }
    final tree = model.fileList == DiffFileListSetting.tree;
    if (tree && !modified && key == LogicalKeyboardKey.arrowLeft) {
      if (row case InspectorFolderListRow(open: true)) {
        model.setCollapsed(path, collapsed: true);
        return KeyEventResult.handled;
      }
      for (int j = current - 1; j >= 0; j--) {
        if (rows[j] is InspectorFolderListRow && rows[j].depth < row.depth) {
          setState(() => _select(rows[j]));
          _reveal(_keyOf(rows[j]), down: false);
          break;
        }
      }
      return KeyEventResult.handled;
    }
    if (tree && !modified && key == LogicalKeyboardKey.arrowRight) {
      if (row case InspectorFolderListRow(:final bool open)) {
        if (!open) {
          model.setCollapsed(path, collapsed: false);
        } else if (current + 1 < rows.length) {
          setState(() => _select(rows[current + 1]));
          _reveal(_keyOf(rows[current + 1]), down: true);
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final int step = switch (key) {
      LogicalKeyboardKey.arrowDown => 1,
      LogicalKeyboardKey.arrowUp => -1,
      _ => 0,
    };
    if (step == 0) {
      return KeyEventResult.ignored;
    }
    final InspectorListRow next = rows[(current + step).clamp(0, rows.length - 1)];
    if (down || next is InspectorFolderListRow) {
      setState(() => _select(next));
    } else {
      // A held key: the row follows at once, the diff once the repeats pause.
      setState(() {
        _folder = null;
        _pending = next.path;
      });
      _repeat?.cancel();
      _repeat = Timer(_repeatPause, _settle);
    }
    _reveal(_keyOf(next), down: step > 0);
    return KeyEventResult.handled;
  }

  /// The context menu's rows for [_menuRow].
  List<ZsMenuEntry> _menuEntries(BuildContext context) {
    final InspectorListRow? row = _menuRow;
    final ProjectFiles? files = widget.model.files;
    if (row == null || files == null) {
      return const <ZsMenuEntry>[];
    }
    return inspectorPathMenu(
      context,
      files,
      path: row.path,
      onDisk: _menuOnDisk,
      folder: row is InspectorFolderListRow,
      workingCopy: widget.data.isWorkingCopy,
    );
  }

  /// [row]'s widget; [current] puts it on `--fl-on`, with the ring while the list has focus.
  Widget _row(InspectorListRow row, {required bool current, required bool tree}) {
    final InspectorViewModel model = widget.model;
    switch (row) {
      case InspectorFileListRow(:final FileChange file):
        return InspectorFileRow(
          key: ValueKey<String>('inspector-file ${file.path}'),
          file: file,
          focused: current,
          highlighted: false,
          ring: _focus.hasFocus && current,
          viewed: model.isViewed(file.path),
          pickable: model.selectable,
          picked: model.fileState(file.path),
          onPick: () => model.togglePick(file.path),
          tree: tree,
          depth: row.depth,
        );
      case InspectorFolderListRow(:final List<FileChange> files):
        final paths = <String>[for (final FileChange file in files) file.path];
        return InspectorFolderRow(
          key: ValueKey<String>('inspector-folder ${row.path}'),
          folder: row,
          current: current,
          ring: _focus.hasFocus && current,
          pickable: model.selectable,
          picked: model.picksState(paths),
          onPick: () => model.togglePicks(paths),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final InspectorViewModel model = widget.model;
    final GraphCardData data = widget.data;
    final ShowEntry? entry = model.entry;
    final ZanshinFfiException? error = model.error;
    final TextStyle note = ZsType.secondary.copyWith(fontSize: ZsType.fsControl, color: colors.textDim);
    Widget text(String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 2),
      child: Text(value, key: const ValueKey<String>('inspector-files-note'), style: note),
    );
    const padding = EdgeInsets.fromLTRB(16, 12, 16, 14);
    final Widget body;
    if (model.graph.stale != null) {
      body = text(strings.staleTitle);
    } else if (error != null) {
      body = text(error.context ?? error.code);
    } else if (entry == null) {
      body = const SizedBox.shrink();
    } else if (entry.fileChanges.isEmpty) {
      body = text(
        data.isRoot
            ? strings.inspectorEmptyRoot
            : data.isWorkingCopy
            ? strings.inspectorEmptyWorkingCopy
            : data.merge
            ? strings.inspectorEmptyMerge
            : strings.inspectorEmpty,
      );
    } else {
      final List<FileChange> files = entry.fileChanges;
      final tree = model.fileList == DiffFileListSetting.tree;
      final List<InspectorListRow> rows = _rowsOf(files);
      final int current = _currentOf(rows).clamp(0, rows.length - 1);
      final int viewed = model.viewedCount;
      final String? focused = model.focusedPath;
      final bool pickHunks = focused != null && model.previousDiff == null && model.hunkable(focused);
      final Widget filesPane = InspectorCheckReveal(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                spacing: 10,
                children: <Widget>[
                  if (model.selectable)
                    // In the rows' check column (design calm-study.jsx:214).
                    SizedBox(
                      width: inspectorCheckGutter,
                      child: Center(
                        child: InspectorCheck(
                          value: model.allState,
                          child: ZsCheckbox(
                            value: model.allState,
                            tristate: true,
                            onChanged: (_) => model.pickAll(),
                            label: model.allPicked ? strings.inspectorDeselectAll : strings.inspectorSelectAll,
                            size: ZsCheckboxSize.sm,
                            identifier: 'inspector-select-all',
                          ),
                        ),
                      ),
                    ),
                  Text(
                    strings.inspectorChanges,
                    style: ZsType.secondary.copyWith(
                      fontSize: ZsType.fsControl,
                      fontWeight: FontWeight.w600,
                      fontVariations: const <FontVariation>[FontVariation.weight(600)],
                      color: colors.text,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      strings.inspectorFileCount(files.length),
                      key: const ValueKey<String>('inspector-files-meta'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ZsType.secondary.copyWith(color: colors.textDim),
                    ),
                  ),
                  if (viewed > 0) ...<Widget>[
                    // It gives way before the buttons and the file list switch (Story 10.39).
                    Flexible(
                      child: ZsTooltip(
                        message: strings.inspectorViewedCountTooltip(viewed, files.length),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 6,
                          children: <Widget>[
                            if (viewed == files.length) ZanshinIcon(ZI.check, size: ZsIconSize.xs, color: colors.add),
                            Flexible(
                              child: Text(
                                viewed == files.length
                                    ? strings.inspectorAllViewed
                                    : strings.inspectorViewedCount(viewed, files.length),
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                                style: ZsType.secondary.copyWith(fontSize: 11.5, color: colors.textDim),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (viewed == files.length)
                      InspectorTextButton(
                        label: strings.inspectorResetViewed,
                        identifier: 'inspector-viewed-reset',
                        onPressed: model.resetViewed,
                      )
                    else
                      InspectorTextButton(
                        label: strings.inspectorMarkAllViewed,
                        identifier: 'inspector-viewed-all',
                        onPressed: model.markAll,
                      ),
                  ],
                  ZsSegmented<DiffFileListSetting>(
                    size: ZsSegmentedSize.sm,
                    label: strings.inspectorFileList,
                    identifier: 'inspector-file-list',
                    value: model.fileList,
                    onChanged: model.setFileList,
                    segments: <ZsSegment<DiffFileListSetting>>[
                      ZsSegment(
                        value: DiffFileListSetting.flat,
                        icon: ZI.listFlat,
                        tooltip: strings.inspectorFileListFlat,
                      ),
                      ZsSegment(
                        value: DiffFileListSetting.tree,
                        icon: ZI.listTree,
                        tooltip: strings.inspectorFileListTree,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: Focus(
                focusNode: _focus,
                onKeyEvent: (node, event) => _onKey(node, event, rows),
                child: Semantics(
                  container: true,
                  label: strings.inspectorChanges,
                  child: ZsMenuAnchor(
                    controller: _menu,
                    entries: _menuEntries(context),
                    semanticLabel: _menuRow?.path,
                    identifier: 'inspector-files-menu',
                    maxWidth: inspectorMenuMaxWidth,
                    cmdMaxWidth: inspectorMenuHintMaxWidth,
                    builder: (context, _) => ZsScrollArea(
                      key: _list,
                      controller: _files,
                      identifier: 'inspector-files-list',
                      child: SingleChildScrollView(
                        controller: _files,
                        child: Column(
                          key: const ValueKey<String>('inspector-files'),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          spacing: 1,
                          children: <Widget>[
                            for (var i = 0; i < rows.length; i++)
                              GestureDetector(
                                key: _rowKey(_keyOf(rows[i])),
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  _focus.requestFocus();
                                  setState(() => _select(rows[i]));
                                  if (rows[i] case InspectorFolderListRow(:final String path, :final bool open)) {
                                    model.setCollapsed(path, collapsed: open);
                                  }
                                },
                                onSecondaryTapUp: (details) => _openMenu(rows[i], details.globalPosition),
                                child: _row(rows[i], current: i == current, tree: tree),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
      final Widget diffPane = focused != null && model.hasSummary
          // While another file's diff loads the previous one stays, dimmed.
          ? Opacity(
              opacity: model.previousDiff != null ? ZsMetrics.of(context).disabledOpacity : 1,
              child: InspectorCheckReveal(
                child: InspectorDiffView(
                  // Keyed by the change too: another change's diff of the same path starts at the top and the left.
                  key: ValueKey<String>(widget.data.key),
                  path: model.previousDiff?.path ?? focused,
                  copyPath: model.files?.absolute(model.previousDiff?.path ?? focused),
                  lineMenu: switch (model.files) {
                    final ProjectFiles files => (context, line) => inspectorPathMenu(
                      context,
                      files,
                      path: model.previousDiff?.path ?? focused,
                      onDisk: files.exists(model.previousDiff?.path ?? focused),
                      workingCopy: widget.data.isWorkingCopy,
                      line: line,
                    ),
                    null => null,
                  },
                  diff: model.focusedDiff ?? model.previousDiff,
                  ignoring: model.focusedDiff != null ? model.focusedIgnoring : model.previousIgnoring,
                  // A file picked whole opens every gap: the commit takes every line.
                  revealAll: model.isPicked(focused),
                  whitespace: model.whitespace,
                  onWhitespaceChanged: model.setWhitespace,
                  contextLines: model.contextLines,
                  contextFromRepo: model.contextFromRepo,
                  onContextLinesChanged: (lines) => unawaited(model.setContextLines(lines)),
                  wordMarks: model.wordMarks,
                  error: model.focusError,
                  viewed: model.isViewed(focused),
                  onViewedChanged: (viewed) => model.setViewed(focused, viewed),
                  layout: model.layout,
                  onLayoutChanged: model.setLayout,
                  // The dimmed previous file's diff takes no picks: they would land on the focused path.
                  // The previous file's lines belong to its own path: its gaps show their counts only.
                  readLines: model.previousDiff == null ? (start, end) => model.diffLines(focused, start, end) : null,
                  linesRevision: model.focusedRevision,
                  partPicked: pickHunks ? (part) => model.partPicked(focused, part) : null,
                  onPartToggled: (part) => model.togglePart(focused, part),
                  modePicked: pickHunks ? model.modePicked(focused) : null,
                  onModeToggled: () => model.toggleMode(focused),
                ),
              ),
            )
          : const SizedBox.shrink();
      return Padding(
        padding: padding,
        child: LayoutBuilder(builder: (context, constraints) => _split(context, constraints, filesPane, diffPane)),
      );
    }
    return Padding(
      padding: padding,
      child: Align(alignment: Alignment.topLeft, child: body),
    );
  }

  /// The two panes and the divider between them in [constraints].
  Widget _split(BuildContext context, BoxConstraints constraints, Widget filesPane, Widget diffPane) {
    final InspectorViewModel model = widget.model;
    final bool wide = widget.wide;
    final split = InspectorSplit(
      wide: wide,
      extent: wide ? constraints.maxWidth : constraints.maxHeight,
    );
    final double room = split.room;
    final double minFiles = split.minFiles;
    final double maxFiles = split.maxFiles;
    final double files = split.files(_dragShare ?? model.filesShare(wide: wide));
    const defaults = LayoutSettings();
    final double defaultShare = wide ? defaults.inspectorFilesWide : defaults.inspectorFilesNarrow;
    // A pane too short for its header and a row clips instead of overflowing.
    final double paneHeight = wide ? constraints.maxHeight : files;
    final Widget pane = ClipRect(
      child: OverflowBox(
        alignment: Alignment.topCenter,
        minHeight: 0,
        maxHeight: math.max(paneHeight, 72),
        child: filesPane,
      ),
    );
    final AppLocalizations strings = context.l10n;
    return Flex(
      direction: wide ? Axis.horizontal : Axis.vertical,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(width: wide ? files : null, height: wide ? null : files, child: pane),
        ZsSplitDivider(
          axis: wide ? Axis.horizontal : Axis.vertical,
          value: files,
          min: minFiles,
          max: maxFiles,
          defaultValue: defaultShare * room,
          total: room,
          label: strings.inspectorSplitLabel,
          tooltip: strings.inspectorSplitTooltip,
          identifier: 'inspector-split',
          onChanged: (value) => setState(() => _dragShare = room > 0 ? value / room : null),
          onChangeEnd: (value) {
            if (room > 0) {
              model.setFilesShare(wide: wide, share: value / room);
            }
            setState(() => _dragShare = null);
          },
        ),
        Expanded(child: diffPane),
      ],
    );
  }
}

/// The width of the file and folder rows' check column (Story 10.42; design calm-study.css `.cs-gut`).
const double inspectorCheckGutter = 22;

/// The space between a row's glyph, name and quiet word (design calm-study.css `.cs-ind`).
const double _rowGap = 6;

/// One file (DS components/content/FileRow; content.css:2-18; Story 10.39, design inspector-study.css:106-126; Story
/// 10.42, design calm-study.jsx:234-243): 28 high; when [pickable] the 22 px check column at the left edge, its box
/// shown on demand ([InspectorCheck]); then the file's **name** in `--text` and its quiet word — "new" in `--add`,
/// "deleted" in `--rem` (both at .85), "from …" in `--text-faint` for a rename or copy (the old name, the old path
/// when the folder changed), nothing for a modification — then (flat only) its **folder** with its `/` in
/// `--text-faint` — the folder's head gives way first, then its last folder, then the name with its word
/// ([InspectorPathLabel]) — then ✓ when viewed (name and folder at .55). A rename or copy shows its new path; the
/// tooltip is the full path, `old → new` for a rename or copy. The focused row (its diff shows) is on `--fl-on` (in the
/// inspector with the current row's [ring] while the list has focus), a highlight on `--fl-hover`. In the [tree] it
/// shows the name only, indented 14 × [depth] + 20 after the check column (else after 8 px). Story 10.29's operation
/// view reuses it flat, without Viewed and checkboxes.
class InspectorFileRow extends StatelessWidget {
  /// The row of [file].
  const InspectorFileRow({
    required this.file,
    required this.focused,
    required this.highlighted,
    this.ring = false,
    this.viewed = false,
    this.pickable = false,
    this.picked = false,
    this.onPick,
    this.tree = false,
    this.depth = 0,
    super.key,
  });

  /// Whether the row sits in the tree: the name only, indented by [depth].
  final bool tree;

  /// The folders above it in the tree.
  final int depth;

  /// The file.
  final FileChange file;

  /// Whether its diff shows.
  final bool focused;

  /// Whether the pointer or a keyboard highlight is on it (`--fl-hover`).
  final bool highlighted;

  /// Whether it carries the current row's 1.5 px `--accent` ring (the inspector's list has focus, Story 10.38).
  final bool ring;

  /// Whether it is marked Viewed.
  final bool viewed;

  /// Whether the row has a checkbox (not on an immutable change).
  final bool pickable;

  /// Whether the composer takes the file: whole, none, or null for part of it (Story 10.26).
  final bool? picked;

  /// Toggles [picked].
  final VoidCallback? onPick;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final AppLocalizations strings = context.l10n;
    final String? from = file.fromPath;
    final TextStyle quiet = ZsType.secondary.copyWith(fontSize: 10.5);
    final TextSpan? word = switch (file.kind) {
      FileChangeKind.added => TextSpan(
        text: strings.inspectorFileNew,
        style: quiet.copyWith(color: colors.add.withValues(alpha: colors.add.a * .85)),
      ),
      FileChangeKind.removed => TextSpan(
        text: strings.inspectorFileDeleted,
        style: quiet.copyWith(color: colors.rem.withValues(alpha: colors.rem.a * .85)),
      ),
      FileChangeKind.renamed || FileChangeKind.copied when from != null => TextSpan(
        text: strings.inspectorFileFrom(inspectorRenameSource(from, file.path)),
        style: quiet.copyWith(color: colors.textFaint),
      ),
      _ => null,
    };
    final TextSpan? note = word == null
        ? null
        : TextSpan(
            children: <InlineSpan>[
              const WidgetSpan(child: SizedBox(width: _rowGap)),
              word,
            ],
          );
    final ({String name, String head, String tail}) parts = inspectorPathParts(file.path);
    final TextStyle nameStyle = ZsType.id.copyWith(color: colors.text);
    final Widget label = tree
        ? Text.rich(
            TextSpan(text: parts.name, children: <InlineSpan>[?note]),
            style: nameStyle,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          )
        : InspectorPathLabel(
            name: parts.name,
            head: parts.head,
            tail: parts.tail,
            nameStyle: nameStyle,
            folderStyle: ZsType.id.copyWith(color: colors.textFaint),
            note: note,
          );
    final Widget row = Container(
      // 28 high, plus the density's step (DS density.css .zs-file).
      constraints: BoxConstraints(minHeight: 28 + metrics.rowStep),
      padding: EdgeInsets.only(left: pickable ? 0 : 8, right: 8),
      decoration: BoxDecoration(
        color: focused
            ? colors.flOn
            : highlighted
            ? colors.flHover
            : colors.flOn.withValues(alpha: 0),
        borderRadius: BorderRadius.circular(metrics.radiusMd),
      ),
      // Always a decoration, so the ring coming and going keeps the row's checkbox (and its focus) in place.
      foregroundDecoration: BoxDecoration(
        border: ring ? Border.all(color: colors.accent, width: 1.5) : null,
        borderRadius: BorderRadius.circular(metrics.radiusMd),
      ),
      child: Row(
        children: <Widget>[
          if (pickable)
            _CheckGutter(value: picked, onPick: onPick, label: file.path, identifier: 'inspector-file-check'),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(left: tree ? 14.0 * depth + 14 + _rowGap : 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Opacity(opacity: viewed ? .55 : 1, child: label),
              ),
            ),
          ),
          if (viewed)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Semantics(
                label: strings.inspectorViewed,
                child: ZanshinIcon(
                  ZI.check,
                  size: ZsIconSize.xs,
                  color: colors.add,
                  key: const ValueKey<String>('inspector-file-viewed'),
                ),
              ),
            ),
        ],
      ),
    );
    return ZsTooltip(
      message: from == null ? file.path : '$from → ${file.path}', // l10n-ignore: paths and an arrow
      child: Semantics(selected: focused, label: file.path, child: row),
    );
  }
}

/// What a rename or copy's "from" names (Story 10.42): [from]'s file name while the folder stays, else its whole path.
String inspectorRenameSource(String from, String path) {
  final ({String name, String head, String tail}) old = inspectorPathParts(from);
  final ({String name, String head, String tail}) now = inspectorPathParts(path);
  return old.head + old.tail == now.head + now.tail ? old.name : from;
}

/// A row's check column (design calm-study.css `.cs-gut`): 22 px at the row's left edge, the box centred and shown on
/// demand.
class _CheckGutter extends StatelessWidget {
  const _CheckGutter({required this.value, required this.onPick, required this.label, required this.identifier});

  final bool? value;
  final VoidCallback? onPick;
  final String label;
  final String identifier;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: inspectorCheckGutter,
    child: Center(
      child: InspectorCheck(
        value: value,
        child: ZsCheckbox(
          value: value,
          tristate: true,
          onChanged: (_) => onPick?.call(),
          label: label,
          size: ZsCheckboxSize.sm,
          identifier: identifier,
        ),
      ),
    ),
  );
}

/// A folder in the tree (Story 10.39; Story 10.42, design calm-study.jsx:224-231): when pickable the 22 px check column
/// (mutable: picks or unpicks every file below; mixed when some), then indented 14 × depth the folder glyph — open
/// while expanded, closed while collapsed, no chevron — and its name, 6 apart. Current like a file row.
class InspectorFolderRow extends StatelessWidget {
  /// The row of [folder].
  const InspectorFolderRow({
    required this.folder,
    required this.current,
    this.ring = false,
    this.pickable = false,
    this.picked = false,
    this.onPick,
    super.key,
  });

  /// The folder.
  final InspectorFolderListRow folder;

  /// Whether it is the list's current row (`--fl-on`).
  final bool current;

  /// Whether it carries the current row's ring.
  final bool ring;

  /// Whether the row has a checkbox.
  final bool pickable;

  /// All its files picked, none, or null for some.
  final bool? picked;

  /// Toggles [picked].
  final VoidCallback? onPick;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final Widget row = Container(
      constraints: BoxConstraints(minHeight: 28 + metrics.rowStep),
      padding: EdgeInsets.only(left: pickable ? 0 : 8, right: 8),
      decoration: BoxDecoration(
        color: current ? colors.flOn : colors.flOn.withValues(alpha: 0),
        borderRadius: BorderRadius.circular(metrics.radiusMd),
      ),
      foregroundDecoration: BoxDecoration(
        border: ring ? Border.all(color: colors.accent, width: 1.5) : null,
        borderRadius: BorderRadius.circular(metrics.radiusMd),
      ),
      child: Row(
        children: <Widget>[
          if (pickable)
            _CheckGutter(value: picked, onPick: onPick, label: folder.path, identifier: 'inspector-folder-check'),
          SizedBox(width: 14.0 * folder.depth),
          ZanshinIcon(
            folder.open ? ZI.folderOpen : ZI.folder,
            // 14 px, so a file's name below lines up at 14 + 6 (design calm-study.jsx:230).
            size: ZsIconSize.md,
            color: colors.textFaint,
            key: const ValueKey<String>('inspector-folder-glyph'),
          ),
          const SizedBox(width: _rowGap),
          Expanded(
            child: Text(
              folder.name,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: ZsType.id.copyWith(color: colors.text),
            ),
          ),
        ],
      ),
    );
    return ZsTooltip(
      message: folder.path,
      child: Semantics(selected: current, expanded: folder.open, label: folder.path, child: row),
    );
  }
}

/// The context menu of [path] (Story 10.39): a file's row — Open in Editor, Reveal in Finder, Copy path (⌘C), Copy
/// relative path; a [folder]'s — Reveal in Finder, Copy path, Copy relative path; a diff [line]'s — Open in Editor at
/// the line, Copy path:line, Copy path. Without an editor the Open row reads "Choose editor…" and opens Settings ›
/// General (disabled outside a window). A path not [onDisk] disables Open and Reveal with the reason. A [line] past the
/// end of the file on disk (Story 10.40) opens the file at its start, a note under the Open row says so. Outside the
/// [workingCopy] a file's and a line's menu end with the note that the file on disk is @'s.
List<ZsMenuEntry> inspectorPathMenu(
  BuildContext context,
  ProjectFiles files, {
  required String path,
  required bool onDisk,
  required bool workingCopy,
  bool folder = false,
  int? line,
}) {
  final AppLocalizations strings = context.l10n;
  final String absolute = files.absolute(path);
  final String? missing = onDisk ? null : strings.filesNotOnDisk(path);
  final String? editor = files.editor;
  final ZsMenuItem open;
  ZsMenuNote? pastEnd;
  if (editor == null) {
    final AppWindowActions? windows = AppWindowActionsScope.maybeOf(context);
    open = ZsMenuItem(
      label: strings.filesChooseEditor,
      cmd: strings.filesChooseEditorHint,
      identifier: 'files-open',
      enabled: windows != null,
      onSelected: windows == null ? null : () => unawaited(windows.openSettings(target: SettingsTarget.general)),
    );
  } else {
    final String name = switch (editor) {
      'idea' => 'IntelliJ IDEA', // l10n-ignore: a product name
      'code' => 'VS Code', // l10n-ignore: a product name
      'zed' => 'Zed', // l10n-ignore: a product name
      _ => strings.filesEditorCustom,
    };
    // A line the file on disk lacks (it is @'s, a later change moved its lines) opens the file at its start.
    final int? lines = line != null && onDisk ? files.lineCount(path) : null;
    // A removed last line stands right after the file's end (`diffNewLineAt`): it opens at the last line.
    final bool atEnd = line != null && lines != null && lines > 0 && line == lines + 1;
    final bool beyond = !atEnd && line != null && lines != null && line > lines;
    final int? at = beyond ? null : (atEnd ? lines : line);
    final String? hint = editorHint(editor, line: at);
    open = ZsMenuItem(
      label: at == null ? strings.filesOpenIn(name) : strings.filesOpenInAtLine(name, at),
      cmd: hint,
      identifier: 'files-open',
      enabled: missing == null && hint != null,
      tooltip: missing,
      onSelected: () => unawaited(files.openInEditor(path, line: at)),
    );
    if (beyond) {
      pastEnd = ZsMenuNote(strings.filesLinePastEnd(line));
    }
  }
  final reveal = ZsMenuItem(
    label: strings.filesReveal,
    cmd: 'open -R', // l10n-ignore: the command
    identifier: 'files-reveal',
    enabled: missing == null,
    tooltip: missing,
    onSelected: () => unawaited(files.reveal(path)),
  );
  ZsMenuItem copy(String label, String text, String identifier, {String? shortcut}) => ZsMenuItem(
    label: label,
    shortcut: shortcut,
    identifier: identifier,
    onSelected: () => unawaited(files.copy(text, context)),
  );
  final note = workingCopy
      ? const <ZsMenuEntry>[]
      : <ZsMenuEntry>[const ZsMenuSeparator(), ZsMenuNote(strings.filesOnDiskNote)];
  if (line != null) {
    return <ZsMenuEntry>[
      open,
      ?pastEnd,
      const ZsMenuSeparator(),
      copy(strings.filesCopyPathLine, '$absolute:$line', 'files-copy-line'),
      copy(strings.filesCopyPath, absolute, 'files-copy-path'),
      ...note,
    ];
  }
  return <ZsMenuEntry>[
    if (!folder) open,
    reveal,
    const ZsMenuSeparator(),
    copy(strings.filesCopyPath, absolute, 'files-copy-path', shortcut: '⌘C'), // l10n-ignore: a key
    copy(strings.filesCopyRelativePath, path, 'files-copy-relative'),
    if (!folder) ...note,
  ];
}

/// The composer's entrance (DS kit.css:129-130): it rises 12 px × `--motion` and fades in on `--dur-slide` /
/// `--ease-glide`, and leaves with a fade on `--dur-exit-lg` / `--ease-exit`; reduce motion keeps only the fades.
class _ComposerMotion extends StatefulWidget {
  const _ComposerMotion({required this.closing, required this.child});

  final bool closing;
  final Widget child;

  @override
  State<_ComposerMotion> createState() => _ComposerMotionState();
}

class _ComposerMotionState extends State<_ComposerMotion> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this);
  var _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ZsMotion motion = ZsMotion.of(context);
    _controller
      ..duration = motion.durSlide
      ..reverseDuration = motion.durExitLg;
    if (!_started) {
      _started = true;
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(_ComposerMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.closing != oldWidget.closing) {
      if (widget.closing) {
        _controller.reverse();
      } else {
        _controller.forward();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZsMotion motion = ZsMotion.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final double v = _controller.value;
        final double eased = widget.closing ? motion.easeExit.flipped.transform(v) : motion.easeGlide.transform(v);
        return Transform.translate(
          key: const ValueKey<String>('inspector-composer-motion'),
          // In it rises from 12 px below; out it drifts back down as it fades.
          offset: Offset(0, 12 * motion.motion * (1 - eased)),
          child: ZsFade(opacity: eased.clamp(0, 1), child: child!),
        );
      },
      child: widget.child,
    );
  }
}

/// `--fl-sheen` over the composer's box.
class _SheenPainter extends CustomPainter {
  const _SheenPainter(this.sheen);

  final ZsLinearGradient sheen;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = sheen.createShader(rect));
  }

  @override
  bool shouldRepaint(_SheenPainter oldDelegate) => oldDelegate.sheen != sheen;
}

/// The composer (Story 10.25; DS inspector.jsx:40-79, kit.css:129-144): the island's bottom section, padding 14 16,
/// gap 10, a top `--fl-border` over `--fl-sheen`. Summary and Details (md; ↩ in Summary or ⌘↩ run), the result preview
/// (the rest — on @ the new working copy — above the selected part), the command [InspectorViewModel.composerAction]
/// runs (cut inside its message when it does not fit), Cancel (split only) and the gold Commit / Split — on @ with a
/// part picked the split button Split ▾ Commit (Story 10.48), whose highlighted menu row the command, the placeholder
/// and the bookmark chips follow. When Split would take everything only its hint and Cancel show (Story 10.40), the
/// draft kept; a refusal shows in the warn colour.
class _Composer extends StatefulWidget {
  const _Composer({required this.model, required this.data, required this.shortId, required this.blocked});

  final InspectorViewModel model;
  final GraphCardData data;
  final String shortId;

  /// Why the run is disabled.
  final String? blocked;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  late final InspectorDraft _initial = widget.model.composerFields;
  late final _summary = ZsTextEditingController(text: _initial.summary);
  late final _details = ZsTextEditingController(text: _initial.details);

  /// The verb of the split button's highlighted menu row (Story 10.48), which the preview follows meanwhile.
  ComposerVerb? _highlighted;

  /// The verb the preview shows: the highlighted row's while it is one of the composer's verbs, else the button's.
  ComposerVerb? get _shown {
    final ComposerVerb? verb = widget.model.composerVerb;
    final ComposerVerb? row = _highlighted;
    return row != null && (row == verb || row == widget.model.composerAlternative) ? row : verb;
  }

  @override
  void dispose() {
    _summary.dispose();
    _details.dispose();
    super.dispose();
  }

  void _changed(String _) {
    widget.model.updateComposerDraft(widget.data.key, (summary: _summary.text, details: _details.text));
    setState(() {});
  }

  bool get _ready =>
      widget.blocked == null &&
      widget.model.graph.hasActions &&
      widget.model.composerAction != null &&
      !widget.model.splitsEverything;

  /// The command line: [full] when it fits [width], else the command with every `-m` paragraph cut to the most
  /// characters that fit (an end ellipsis only when even "…" alone overflows).
  String _fitted(String full, double width, TextStyle style) {
    if (full.isEmpty) {
      return full;
    }
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final TextDirection direction = Directionality.of(context);
    bool fits(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final bool fit = painter.width <= width;
      painter.dispose();
      return fit;
    }

    if (fits(full)) {
      return full;
    }
    final InspectorViewModel model = widget.model;
    final int longest = InspectorViewModel.paragraphsOf(
      model.composerFields,
    ).fold(0, (most, paragraph) => math.max(most, paragraph.characters.length));
    // The largest k below the longest paragraph whose cut fits; k = 0 when none does.
    final ComposerVerb? verb = _shown;
    var low = 0;
    int high = longest - 1;
    while (low < high) {
      final int mid = (low + high + 1) ~/ 2;
      if (fits(model.composerCommandCut(mid, verb: verb) ?? '')) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return model.composerCommandCut(low, verb: verb) ?? full;
  }

  void _run([ComposerVerb? verb]) {
    if (!_ready) {
      return;
    }
    unawaited(
      widget.model.runComposer(verb).then((result) {
        if (result is GraphActionDone && mounted) {
          _summary.clear();
          _details.clear();
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final InspectorViewModel model = widget.model;
    final bool isAt = widget.data.isWorkingCopy;
    final paths = <String>[for (final FileChange file in model.entry?.fileChanges ?? const []) file.path];
    final List<String> selected = paths.where(model.hasPick).toList();
    final List<String> rest = paths.where((p) => !model.isPicked(p)).toList();
    final String summary = _summary.text.split('\n').first;
    final ComposerVerb? verb = model.composerVerb;
    final ComposerVerb? alternative = model.composerAlternative;
    final ComposerVerb? shown = _shown;
    // Nothing checked: no command (a bare `jj commit` would take everything). The line follows a highlighted menu row;
    // the button's tooltip keeps naming its own verb.
    final String command = model.composerCommandAs(shown) ?? '';
    final String labelCommand = model.composerCommand ?? '';
    final List<String> bookmarks = model.composerBookmarks;
    final ComposerPart? landing = shown == null ? null : model.bookmarksLandOn(shown);
    final String? blocked = widget.blocked;
    final ZanshinFfiException? error = model.composerError;
    final TextStyle node = ZsType.secondary.copyWith(fontSize: 12, color: colors.textDim);
    final TextStyle note = ZsType.secondary.copyWith(fontSize: 11.5, height: 1.45, color: colors.textDim);
    final TextStyle stat = ZsType.id.copyWith(fontSize: ZsType.fsSm);

    // A file's ± in the selected part: its picked sections' (all of it when whole); in the rest: the remainder.
    Widget count(List<String> files, {required bool chosen}) {
      final bool sums = model.hasSummary;
      int part(String p, int Function(({int added, int removed}) stat) of) {
        final FileDiff? file = model.summaryOf(p);
        final int picked = of(model.pickedStat(p));
        return chosen ? picked : of((added: file?.added ?? 0, removed: file?.removed ?? 0)) - picked;
      }

      final int added = files.fold(0, (sum, p) => sum + part(p, (s) => s.added));
      final int removed = files.fold(0, (sum, p) => sum + part(p, (s) => s.removed));
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: <Widget>[
          Text(strings.inspectorFileCount(files.length), style: node),
          if (sums && added > 0) Text('+$added', style: stat.copyWith(color: colors.add)), // l10n-ignore: a count
          if (sums && removed > 0) Text('−$removed', style: stat.copyWith(color: colors.rem)), // l10n-ignore: a count
        ],
      );
    }

    Widget dot({required bool chosen}) => Container(
      width: 9,
      height: 9,
      margin: const EdgeInsets.symmetric(horizontal: 2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: chosen ? colors.accent : null,
        border: Border.all(
          width: 1.5,
          color: chosen
              ? colors.accentLine
              : isAt
              ? colors.co
              : colors.textFaint,
        ),
        boxShadow: !chosen && isAt ? <BoxShadow>[BoxShadow(color: colors.coSoft, spreadRadius: 3)] : null,
      ),
    );

    Widget row({required Widget dot, required List<Widget> label, required Widget meta, required Widget note}) =>
        SizedBox(
          height: 24,
          child: Row(
            spacing: 8,
            children: <Widget>[
              dot,
              ...label,
              meta,
              Expanded(
                child: Align(alignment: Alignment.centerRight, child: note),
              ),
            ],
          ),
        );

    final TextStyle labelStyle = node.copyWith(
      fontWeight: FontWeight.w600,
      fontVariations: const <FontVariation>[FontVariation.weight(600)],
      color: colors.text,
    );
    Text noteText(String text, {Color? color}) => Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: note.copyWith(color: color, height: 1),
    );
    // The change's local bookmarks on the part the shown verb leaves them on (Inspector Extras Study `.xs-bm`): an
    // `--accent` bookmark glyph and the name in mono 11 on an `--fl-on` pill 18 high. Chips that do not fit are cut at
    // the row's free space.
    List<Widget> chips(ComposerPart part) => landing != part || bookmarks.isEmpty
        ? const <Widget>[]
        : <Widget>[
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: <Widget>[
                    for (final String name in bookmarks)
                      ZsTooltip(
                        message: strings.inspectorComposerBookmarkHere(name),
                        child: Container(
                          key: ValueKey<String>('inspector-composer-bookmark-${part.name}-$name'),
                          height: 18,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            color: colors.flOn,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 4,
                            children: <Widget>[
                              ZanshinIcon(ZI.bookmark, size: ZsIconSize.xs, color: colors.accent),
                              Text(
                                name,
                                softWrap: false,
                                style: ZsType.id.copyWith(fontSize: ZsType.fsSm, color: colors.text, height: 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ];
    final String subject = InspectorViewModel.draftFrom(model.description ?? '').summary;
    final Widget result = Stack(
      key: const ValueKey<String>('inspector-composer-result'),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Column(
            spacing: 2,
            children: <Widget>[
              row(
                dot: dot(chosen: false),
                label: <Widget>[
                  if (isAt) ...<Widget>[
                    ZanshinIcon(ZI.workingCopyAt, size: ZsIconSize.sm, color: colors.co),
                    Text(strings.inspectorComposerNewWorkingCopy, style: labelStyle),
                  ] else
                    Text(strings.inspectorComposerRest, style: labelStyle),
                  ...chips(ComposerPart.rest),
                ],
                meta: rest.isEmpty ? Text(strings.inspectorComposerEmpty, style: node) : count(rest, chosen: false),
                note: noteText(isAt ? strings.inspectorComposerStays : strings.inspectorComposerKeeps(subject)),
              ),
              row(
                dot: dot(chosen: true),
                label: <Widget>[
                  Text(strings.inspectorComposerSelected, style: labelStyle),
                  ...chips(ComposerPart.selected),
                ],
                meta: selected.isEmpty
                    ? Text(strings.inspectorComposerNothingYet, style: node)
                    : count(selected, chosen: true),
                note: summary.isEmpty
                    ? noteText(strings.inspectorComposerNoDescription)
                    : noteText(strings.inspectorComposerMessage(summary), color: colors.text),
              ),
            ],
          ),
        ),
        // The line from the rest down to the selected part (DS kit.css:135).
        Positioned(
          left: 8.25,
          top: 17,
          width: 1.5,
          height: 16,
          child: ColoredBox(color: colors.textFaint.withValues(alpha: colors.textFaint.a * .7)),
        ),
      ],
    );

    final bool ready = _ready;
    String name(ComposerVerb? verb) => verb == ComposerVerb.split ? strings.inspectorSplit : strings.inspectorCommit;
    final String run = name(verb);
    final cancel = ZsButton(
      label: strings.inspectorCancel,
      onPressed: model.clearPicks,
      identifier: 'inspector-composer-cancel',
    );
    // Where a verb leaves the bookmarks, said under its menu row while the two verbs differ (Story 10.48).
    String? landsNote(ComposerVerb verb) {
      if (!model.composerBookmarksDiffer) {
        return null;
      }
      final int count = bookmarks.length;
      final String names = switch (count) {
        1 => bookmarks.single,
        2 => strings.inspectorComposerBookmarkPair(bookmarks.first, bookmarks.last),
        _ => strings.inspectorComposerBookmarkCount(count),
      };
      return model.bookmarksLandOn(verb) == ComposerPart.rest
          ? strings.inspectorComposerBookmarksMove(names, count)
          : strings.inspectorComposerBookmarksStay(names, count);
    }

    ZsMenuItem verbRow(ComposerVerb verb) => ZsMenuItem(
      label: name(verb),
      cmd: verb == ComposerVerb.split
          ? GraphSplit(widget.shortId, message: const <String>[]).command
          : GraphCommit(widget.data.key, message: const <String>[]).command,
      note: landsNote(verb),
      noteIcon: ZI.bookmark,
      enabled: ready,
      identifier: 'inspector-composer-${verb.name}',
      onHighlight: (on) {
        if (mounted) {
          setState(() => _highlighted = on ? verb : (_highlighted == verb ? null : _highlighted));
        }
      },
      onSelected: () => _run(verb),
    );
    final Widget runButton = alternative != null && verb != null
        ? ZsSplitButton(
            label: run,
            variant: ZsButtonVariant.primary,
            onPressed: ready ? _run : null,
            disabledReason: blocked,
            tooltip: blocked ?? (labelCommand.isEmpty ? null : labelCommand),
            cmd: blocked == null || labelCommand.isEmpty ? null : labelCommand,
            menuDisabledReason: blocked,
            identifier: 'inspector-composer-run',
            entries: <ZsMenuEntry>[verbRow(verb), verbRow(alternative)],
          )
        : ZsButton(
            label: run,
            variant: ZsButtonVariant.primary,
            onPressed: ready ? _run : null,
            disabledReason: blocked,
            identifier: 'inspector-composer-run',
          );
    final TextStyle commandStyle = DefaultTextStyle.of(
      context,
    ).style.merge(ZsType.command.copyWith(fontSize: ZsType.fsSm, color: colors.textFaint));
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _run,
        const SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true): _run,
      },
      child: Semantics(
        container: true,
        label: run,
        child: CustomPaint(
          painter: _SheenPainter(colors.flSheen),
          child: Container(
            key: const ValueKey<String>('inspector-composer'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.flBorder)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 10,
              children: <Widget>[
                // Split cannot take every change (it would leave an empty one): only the hint and Cancel show. The
                // draft stays in the controllers and shows again once a pick goes.
                if (model.splitsEverything)
                  Row(
                    spacing: 6,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          strings.inspectorSplitAllHint,
                          key: const ValueKey<String>('inspector-composer-hint'),
                          style: note,
                        ),
                      ),
                      cancel,
                    ],
                  )
                else ...<Widget>[
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 6,
                    children: <Widget>[
                      ZsTextField(
                        controller: _summary,
                        size: ZsTextFieldSize.md,
                        placeholder: shown == ComposerVerb.commit
                            ? strings.inspectorComposerSummaryAt
                            : strings.inspectorComposerSummarySplit,
                        label: strings.inspectorSummary,
                        identifier: 'inspector-composer-summary',
                        onChanged: _changed,
                        onSubmitted: (_) => _run(),
                      ),
                      ZsTextField(
                        controller: _details,
                        size: ZsTextFieldSize.md,
                        multiline: true,
                        placeholder: strings.inspectorDetails,
                        label: strings.inspectorDetails,
                        identifier: 'inspector-composer-details',
                        onChanged: _changed,
                      ),
                    ],
                  ),
                  result,
                  Row(
                    spacing: 6,
                    children: <Widget>[
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) => Text(
                            _fitted(command, constraints.maxWidth, commandStyle),
                            key: const ValueKey<String>('inspector-composer-command'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: commandStyle,
                          ),
                        ),
                      ),
                      if (!isAt) cancel,
                      if (runButton is ZsButton && (blocked ?? (labelCommand.isEmpty ? null : labelCommand)) != null)
                        ZsTooltip(
                          message: blocked ?? labelCommand,
                          cmd: blocked == null || labelCommand.isEmpty ? null : labelCommand,
                          child: runButton,
                        )
                      else
                        runButton,
                    ],
                  ),
                ],
                if (error != null)
                  Text(
                    error.context ?? error.code,
                    key: const ValueKey<String>('inspector-composer-error'),
                    style: note.copyWith(color: colors.warn),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
