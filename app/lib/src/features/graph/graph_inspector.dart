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
import 'package:zanshin_settings/zanshin_settings.dart' show DiffLayoutSetting, SettingsStore;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'graph_card.dart';
import 'graph_layout.dart';
import 'graph_ports.dart';
import 'graph_view_model.dart';
import 'hatch_swatch.dart';
import 'inspector_diff.dart';
import 'inspector_viewed_store.dart';

final _log = Logger('zanshin.inspector');

/// The describe form's two fields.
typedef InspectorDraft = ({String summary, String details});

/// The inspector's model (Story 10.8): what [details] answers for the graph's selection, and the describe form's state.
///
/// - **Fetch.** On every change of the selected key or the layout's operation it reads `show` (the commit id) and,
///   for a mutable change, `changeActions`; a reply for an older key or operation is dropped. A refusal is kept as
///   [error]. While the working copy is stale nothing is read (jj refuses).
/// - **Drafts** live per change key for the session; the form's open state too, so a draft survives a selection
///   change and comes back open. [save] joins the fields as the CLI's `-m` paragraphs and runs `jj describe` through
///   the graph's runner — nothing when the text equals the current description.
/// - **Diff** (Story 10.24): with `show` it reads the summary diff ([summaryOf]: ± and fingerprints per file); then the
///   focused file's diff ([focusedDiff]) — both by the commit id, so a hidden or divergent node reads its own commit.
///   The first file starts focused; a reload keeps the focused path while it is
///   listed. A file is viewed while `viewedKey(change id, path, its summary fingerprint)` is in the viewed store's set; the
///   layout is `general.diffLayout` in [settings], followed when another writer changes it.
/// - **Composer** (Story 10.25): the checked files of the selection — @ starts with all, another change with none,
///   reset on a selection change, kept to the still-listed paths on a reload — and a composer draft per change key;
///   [runComposer] runs [composerAction] (`jj commit` / `jj split -r`). [squash] asks `squashPlan` first and opens the
///   squash form with the combined description when jj would open its editor.
class InspectorViewModel extends ChangeNotifier {
  /// The inspector of [graph]'s selection, reading through [details]; Viewed marks in [viewed], the diff layout in
  /// [settings].
  InspectorViewModel({
    required this.graph,
    required this.details,
    required InspectorViewedStore viewed,
    required this.settings,
  }) : _viewedStore = viewed,
       _viewed = viewed.load(),
       _layout = settings.value.general.diffLayout {
    graph.addListener(_graphChanged);
    settings.addListener(_settingsChanged);
    _graphChanged();
  }

  /// The graph whose selection it shows; its runner runs the actions.
  final GraphViewModel graph;

  /// What the inspector reads.
  final GraphDetails details;

  /// The app settings: the diff layout.
  final SettingsStore settings;

  final InspectorViewedStore _viewedStore;
  final Set<String> _viewed;
  DiffLayoutSetting _layout;

  Map<String, FileDiff>? _summary;
  String? _changeId;
  String? _commitId;
  String? _focused;
  FileDiff? _focusedDiff;
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
  final _drafts = <String, InspectorDraft>{};
  final _open = <String>{};
  var _disposed = false;

  // The composer (Story 10.25): the checked paths of [_key] (set up once per key by the first read), the drafts per key.
  final _picked = <String>{};
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

  /// The summary's totals: Σ added and Σ removed; null without a summary.
  ({int added, int removed})? get totals {
    final Iterable<FileDiff>? files = _summary?.values;
    if (files == null) {
      return null;
    }
    return (
      added: files.fold(0, (sum, file) => sum + file.added),
      removed: files.fold(0, (sum, file) => sum + file.removed),
    );
  }

  /// The path whose diff shows; null without files.
  String? get focusedPath => _focused;

  /// The focused file's diff; null while it loads, after a refusal, and when the reply lists no such file.
  FileDiff? get focusedDiff => _focusedDiff;

  /// The focused diff's refusal.
  ZanshinFfiException? get focusError => _focusError;

  /// Shows [path]'s diff (one read); on the focused path after a refusal it reads again.
  void focus(String path) {
    if (path == _focused && _focusError == null) {
      return;
    }
    _focused = path;
    _focusedDiff = null;
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

  void _settingsChanged() {
    var changed = false;
    final DiffLayoutSetting layout = settings.value.general.diffLayout;
    if (layout != _layout) {
      _layout = layout;
      changed = true;
    }
    // Another writer (a second window of the repo) may have changed the Viewed marks.
    final Set<String> viewed = _viewedStore.load();
    if (!setEquals(viewed, _viewed)) {
      _viewed
        ..clear()
        ..addAll(viewed);
      changed = true;
    }
    if (changed) {
      _notify();
    }
  }

  void _loadFocus() {
    final int serial = ++_focusSerial;
    final String? path = _focused;
    final String? commitId = _commitId;
    if (path == null || commitId == null || _summary == null) {
      _focusedDiff = null;
      _focusError = null;
      return;
    }
    unawaited(() async {
      try {
        final Diff diff = await details.diff(commitId, paths: <String>[path]);
        if (serial == _focusSerial) {
          _focusedDiff = diff.files.where((file) => file.path == path).firstOrNull;
          _focusError = null;
          _notify();
        }
      } on ZanshinFfiException catch (error) {
        _log.warning('diff refused: ${error.code}');
        if (serial == _focusSerial) {
          _focusedDiff = null;
          _focusError = error;
          _notify();
        }
      }
    }());
  }

  /// The summary, or null when it is refused (rows without ±, no diff block).
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

  /// [key]'s draft, when the form was edited.
  InspectorDraft? draftOf(String key) => _drafts[key];

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

  /// Keeps [draft] as [key]'s.
  void updateDraft(String key, InspectorDraft draft) => _drafts[key] = draft;

  /// The card menu's "Describe…" (10.15 calls it): selects [key] and opens its form.
  void describe(String key) {
    graph.select(key);
    openForm(key);
  }

  /// The selection's current description, once read.
  String? get description => _entry?.change.description;

  /// [key]'s draft differs from the current description.
  bool dirty(String key) {
    final InspectorDraft? draft = _drafts[key];
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

  /// Whether [path] is checked for the composer.
  bool isPicked(String path) => _picked.contains(path);

  /// How many files are checked.
  int get pickedCount => _picked.length;

  /// Whether every listed file is checked.
  bool get allPicked => _listed.isNotEmpty && _listed.every(_picked.contains);

  /// Checks or unchecks [path].
  void togglePick(String path) {
    if (!selectable) {
      return;
    }
    if (!_picked.remove(path)) {
      _picked.add(path);
    }
    _composerError = null;
    _notify();
  }

  /// Select all: checks every listed file, or unchecks them all when all are checked.
  void pickAll() {
    if (!selectable) {
      return;
    }
    final bool all = allPicked;
    _picked.clear();
    if (!all) {
      _picked.addAll(_listed);
    }
    _composerError = null;
    _notify();
  }

  /// The composer's Cancel: unchecks every file (the draft stays).
  void clearPicks() {
    if (_picked.isNotEmpty || _composerError != null) {
      _picked.clear();
      _composerError = null;
      _notify();
    }
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
    return at.layout.workingCopyIndex == at.node ? _listed.isNotEmpty : _picked.isNotEmpty;
  }

  /// What the composer runs for the selection — `jj commit` on @ (no paths when every file is checked), else
  /// `jj split -r` with the checked paths; null when it shows no composer or nothing is checked.
  GraphAction? get composerAction => _composer(short: false);

  /// [composerAction]'s command as the composer previews it — the change named by its short id, as the inspector's
  /// other buttons show theirs; null without an action.
  String? get composerCommand => _composer(short: true)?.command;

  GraphAction? _composer({required bool short}) {
    final ({GraphLayout layout, int node})? at = _mutableNode;
    final String? key = _key;
    if (at == null || key == null || !composing || _picked.isEmpty) {
      return null;
    }
    final List<String> paragraphs = paragraphsOf(composerFields);
    final paths = <String>[
      for (final String path in _listed)
        if (_picked.contains(path)) path,
    ];
    if (at.layout.workingCopyIndex == at.node) {
      return GraphCommit(key, message: paragraphs, paths: allPicked ? const <String>[] : paths);
    }
    return GraphSplit(short ? graphShortId(at.layout, at.node) : key, message: paragraphs, paths: paths);
  }

  /// Runs [composerAction] through the runner: done clears the key's draft and checks; a refusal stays in
  /// [composerError], the draft and checks with it.
  Future<GraphActionResult?> runComposer() async {
    final GraphAction? action = composerAction;
    final String? key = _key;
    if (action == null || key == null) {
      return null;
    }
    _composerError = null;
    _notify();
    final GraphActionResult result = await graph.run(action);
    switch (result) {
      case GraphActionDone():
        _composerDrafts.remove(key);
        if (_key == key) {
          _picked.clear();
        }
      case GraphActionRefused(:final error):
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
      _entry = null;
      _actions = null;
      _clearDiff();
      _picked.clear();
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
        final List<String> paths = _listed;
        if (_pickedFor != _key) {
          // @ starts with every file checked, another change with none.
          _pickedFor = _key;
          _picked
            ..clear()
            ..addAll(mutable && node == layout.workingCopyIndex ? paths : const <String>[]);
        } else {
          _picked.retainAll(paths);
        }
        final String? focused = paths.contains(_focused) ? _focused : paths.firstOrNull;
        if (focused != _focused) {
          _focusedDiff = null;
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
    super.dispose();
  }
}

/// The inspector (Story 10.8; DS ui_kits/desktop/inspector.jsx, kit.css:90-128): the selected change on the panel
/// island, a fixed header over a scrolling body.
///
/// - **Header:** the full change id, jj's unique prefix bold (one `Text.rich`, the commit id as its tooltip); the
///   flags "@ Working copy" (gold), Immutable (the hatch swatch; not on the root), Empty, Merge, Conflict; Close (Esc).
/// - **Title = describe:** the subject in `--type-inspector-title` and the rest of the description; on a mutable
///   change it is a control that opens the describe form (the pen on hover or focus), an undescribed one reading
///   "Describe this change…". The form replaces it in place: Summary and Details, ↩ in Summary or ⌘↩ save, the
///   command, Cancel and the gold Save.
/// - **Meta:** author · date · parents; **chips:** the bookmarks with ✓ / local / remote.
/// - **Actions** (hidden while the form is open): immutable "New change on top"; @ "New change", "Squash into parent",
///   "Abandon"; else "Edit", "Squash into parent", "Abandon" — each tooltip the full command; Squash is disabled only
///   with jj's refusal and opens the squash form when jj would ask for a combined description (Story 10.25).
/// - **Changes:** the file count with the summary's totals, the viewed counter with Mark all / Reset, one row per file
///   with its ± and ✓ (one Tab stop, ↑ ↓ move the highlight, a click or ↩ focuses), and the focused file's diff block
///   (Story 10.24); or the empty, stale or refusal text. On a mutable change each row and the header have a checkbox.
/// - **Composer** (Story 10.25; DS inspector.jsx:40-79, kit.css:129-144): at the island's bottom while composing.
/// - **Esc:** the squash form closes; in a composer field with a draft it leaves the field; in a field with a changed
///   describe draft it leaves the field; else it closes the form, else the selection.
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
        child: ZsIsland(
          shape: ZsIslandShape.panel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _Header(data: data, layout: layout, node: node, entry: entry, onClose: () => graph.select(null)),
              Expanded(
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
                                _model.draftOf(data.key) ?? InspectorViewModel.draftFrom(editing.change.description),
                            blocked: graphBlockedReason(strings, graph),
                            onClosed: refocus,
                          )
                        else
                          _Title(model: _model, data: data, entry: entry),
                        _Meta(data: data, layout: layout, node: node, entry: entry, nowMs: graph.now.value),
                        if (data.refs.isNotEmpty) _Chips(refs: data.refs),
                        if (editing == null && squashing == null)
                          _Actions(model: _model, data: data, layout: layout, node: node),
                        _Changes(model: _model, data: data),
                      ],
                    ),
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
String graphShortId(GraphLayout layout, int node) {
  final String key = layout.keyOf(node);
  final String changeId = layout.changeIdOf(node);
  if (key != changeId) {
    // shortcut: 12 hex digits as jj's `commit_id.short()`, not the commit's unique prefix (the layout has none).
    return key.substring(0, math.min(12, key.length));
  }
  return changeId.substring(0, math.min(changeId.length, math.max(layout.changeIdPrefixLengthOf(node), 8)));
}

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
                    // The reason ("Immutable · <reason>") comes with 11.7's producer.
                    _Flag(
                      label: strings.inspectorFlagImmutable,
                      icon: const HatchSwatch(),
                      tooltip: strings.inspectorFlagImmutable,
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
            child: Text(texts.body, style: ZsType.body.copyWith(color: colors.textMuted)),
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
/// parents' short ids mono in `--text-muted`.
class _Meta extends StatelessWidget {
  const _Meta({required this.data, required this.layout, required this.node, required this.entry, required this.nowMs});

  final GraphCardData data;
  final GraphLayout layout;
  final int node;
  final ShowEntry? entry;
  final int nowMs;

  /// The parents' short ids with the full id each copies: `show`'s parents, else the layout's direct parents (the
  /// stale state). A layout node's full id is its key, the id its short one is cut from.
  List<({String short, String full})> _parents() {
    final List<String>? shown = entry?.change.parents;
    if (shown != null) {
      return <({String short, String full})>[
        for (final String id in shown)
          switch (layout.indexOfKey(id)) {
            final int parent => (short: graphShortId(layout, parent), full: layout.keyOf(parent)),
            null => (short: id.substring(0, math.min(8, id.length)), full: id),
          },
      ];
    }
    final ({int start, int end}) edges = layout.parentEdges(node);
    return <({String short, String full})>[
      for (var e = edges.start; e < edges.end; e++)
        if (layout.kindOf(e) == GraphEdgeKind.direct)
          (short: graphShortId(layout, layout.parentOf(e)), full: layout.keyOf(layout.parentOf(e))),
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
    final List<({String short, String full})> parents = data.isRoot
        ? const <({String short, String full})>[]
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
                  style: ZsType.id.copyWith(color: colors.textMuted),
                  identifier: 'inspector-parent-$i',
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

/// The bookmark chips (DS BookmarkChip tag; kit.css:110; graph.css:55-57): padding 12 20 0, gap 6; each chip padding
/// 4 9, `--radius-chip`, `--fl-hover`, the filled bookmark, the name mono `--fs-id` and the state ✓ / local / remote
/// mono `--fs-xs`.
class _Chips extends StatelessWidget {
  const _Chips({required this.refs});

  final List<GraphRef> refs;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: <Widget>[
          for (final GraphRef ref in refs)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(color: colors.flHover, borderRadius: BorderRadius.circular(metrics.radiusChip)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
                children: <Widget>[
                  ZanshinIcon(ZI.bookmarkFilled, size: ZsIconSize.sm, color: colors.textDim),
                  Flexible(
                    child: Text(
                      ref.remote == null ? ref.name : '${ref.name}@${ref.remote}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ZsType.id.copyWith(color: colors.text),
                    ),
                  ),
                  Text(
                    ref.remote != null
                        ? strings.inspectorBookmarkRemote
                        : ref.synced
                        ? '✓' // l10n-ignore: a symbol for "in sync"
                        : strings.inspectorBookmarkLocal,
                    style: ZsType.id.copyWith(
                      fontSize: ZsType.fsXs,
                      color: ref.remote != null ? colors.remote : colors.textDim,
                    ),
                  ),
                ],
              ),
            ),
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
            button(
              strings.inspectorSquash,
              GraphSquash(revision: key),
              GraphSquash(revision: short).command,
              disabled: refusal == null ? null : refusal.context ?? refusal.code,
              onPressed: () => unawaited(model.squash(key)),
              identifier: 'inspector-squash',
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

/// The Changes section (DS kit.css:114-124): padding 16 20 20; the header "Changes" 12.5 600 and the file count; the
/// rows (DS components/content/FileRow, content.css:2-14) padding 6 8, gap 8, `--radius-md`, the status letter on its
/// 14 px badge and the path mono `--fs-id`; the highlighted row `--fl-on` while the list has focus. Or the text that
/// takes its place: the stale state, a refusal, an empty change.
class _Changes extends StatefulWidget {
  const _Changes({required this.model, required this.data});

  final InspectorViewModel model;
  final GraphCardData data;

  @override
  State<_Changes> createState() => _ChangesState();
}

class _ChangesState extends State<_Changes> {
  final _focus = FocusNode(debugLabel: 'inspector files');
  var _highlight = 0;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(_Changes oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.key != widget.data.key) {
      _highlight = 0;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _focusChanged() => setState(() {});

  KeyEventResult _onKey(FocusNode node, KeyEvent event, List<FileChange> files) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final int count = files.length;
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final bool modified =
        keyboard.isMetaPressed || keyboard.isShiftPressed || keyboard.isAltPressed || keyboard.isControlPressed;
    if (!modified &&
        (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      widget.model.focus(files[_highlight.clamp(0, count - 1)].path);
      return KeyEventResult.handled;
    }
    final int step = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown => 1,
      LogicalKeyboardKey.arrowUp => -1,
      _ => 0,
    };
    if (step == 0) {
      return KeyEventResult.ignored;
    }
    setState(() => _highlight = (_highlight + step).clamp(0, count - 1));
    return KeyEventResult.handled;
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
      final int highlight = _highlight.clamp(0, files.length - 1);
      final ({int added, int removed})? totals = model.totals;
      final int viewed = model.viewedCount;
      final TextStyle stat = ZsType.id.copyWith(fontSize: ZsType.fsSm);
      final String? focused = model.focusedPath;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              spacing: 10,
              children: <Widget>[
                if (model.selectable)
                  ZsCheckbox(
                    value: model.allPicked,
                    onChanged: (_) => model.pickAll(),
                    label: model.allPicked ? strings.inspectorDeselectAll : strings.inspectorSelectAll,
                    size: ZsCheckboxSize.sm,
                    identifier: 'inspector-select-all',
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
                  child: Text.rich(
                    key: const ValueKey<String>('inspector-files-meta'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    TextSpan(
                      style: ZsType.secondary.copyWith(color: colors.textDim),
                      children: <InlineSpan>[
                        TextSpan(text: strings.inspectorFileCount(files.length)),
                        if (totals != null) ...<InlineSpan>[
                          TextSpan(
                            text: '  +${totals.added}', // l10n-ignore: a count
                            style: stat.copyWith(color: colors.add),
                          ),
                          TextSpan(
                            text: '  −${totals.removed}', // l10n-ignore: a count
                            style: stat.copyWith(color: colors.rem),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (viewed > 0) ...<Widget>[
                  ZsTooltip(
                    message: strings.inspectorViewedCountTooltip(viewed, files.length),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 6,
                      children: <Widget>[
                        if (viewed == files.length) ZanshinIcon(ZI.check, size: ZsIconSize.xs, color: colors.add),
                        Text(
                          viewed == files.length
                              ? strings.inspectorAllViewed
                              : strings.inspectorViewedCount(viewed, files.length),
                          style: ZsType.secondary.copyWith(fontSize: 11.5, color: colors.textDim),
                        ),
                      ],
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
              ],
            ),
          ),
          Focus(
            focusNode: _focus,
            onKeyEvent: (node, event) => _onKey(node, event, files),
            child: Semantics(
              container: true,
              label: strings.inspectorChanges,
              child: Column(
                key: const ValueKey<String>('inspector-files'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 1,
                children: <Widget>[
                  for (var i = 0; i < files.length; i++)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        _focus.requestFocus();
                        setState(() => _highlight = i);
                        model.focus(files[i].path);
                      },
                      child: InspectorFileRow(
                        file: files[i],
                        summary: model.summaryOf(files[i].path),
                        focused: files[i].path == focused,
                        highlighted: _focus.hasFocus && i == highlight,
                        viewed: model.isViewed(files[i].path),
                        picked: model.selectable ? model.isPicked(files[i].path) : null,
                        onPick: () => model.togglePick(files[i].path),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (focused != null && model.hasSummary)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: InspectorDiffView(
                path: focused,
                diff: model.focusedDiff,
                error: model.focusError,
                viewed: model.isViewed(focused),
                onViewedChanged: (viewed) => model.setViewed(focused, viewed),
                layout: model.layout,
                onLayoutChanged: model.setLayout,
              ),
            ),
        ],
      );
    }
    return Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 20), child: body);
  }
}

/// One file (DS components/content/FileRow; content.css:2-18): the focused row (its diff shows) on `--fl-on`, the
/// keyboard highlight on `--fl-hover`; a viewed file's ✓ and its path at .55; the summary's ± when read. Story 10.29's
/// operation view reuses it without Viewed and checkboxes.
class InspectorFileRow extends StatelessWidget {
  /// The row of [file].
  const InspectorFileRow({
    required this.file,
    required this.summary,
    required this.focused,
    required this.highlighted,
    this.viewed = false,
    this.picked,
    this.onPick,
    super.key,
  });

  /// The file.
  final FileChange file;

  /// Its summary entry (±), when read.
  final FileDiff? summary;

  /// Whether its diff shows.
  final bool focused;

  /// Whether the keyboard highlight is on it.
  final bool highlighted;

  /// Whether it is marked Viewed.
  final bool viewed;

  /// Whether the composer takes the file; null: no checkbox (an immutable change).
  final bool? picked;

  /// Toggles [picked].
  final VoidCallback? onPick;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final (String letter, Color ink, Color fill) = switch (file.kind) {
      FileChangeKind.added => ('A', colors.add, colors.addBg), // l10n-ignore: jj's status letter
      FileChangeKind.modified => ('M', colors.statusM, colors.statusMBg), // l10n-ignore: jj's status letter
      FileChangeKind.removed => ('D', colors.rem, colors.remBg), // l10n-ignore: jj's status letter
      FileChangeKind.renamed => ('R', colors.statusM, colors.statusMBg), // l10n-ignore: jj's status letter
      FileChangeKind.copied => ('C', colors.add, colors.addBg), // l10n-ignore: jj's status letter
    };
    final String? from = file.fromPath;
    final FileDiff? summary = this.summary;
    final TextStyle stat = ZsType.id.copyWith(fontSize: ZsType.fsSm);
    final Widget row = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: focused
            ? colors.flOn
            : highlighted
            ? colors.flHover
            : colors.flOn.withValues(alpha: 0),
        borderRadius: BorderRadius.circular(metrics.radiusMd),
      ),
      child: Row(
        spacing: 8,
        children: <Widget>[
          if (picked case final bool picked)
            ZsCheckbox(
              value: picked,
              onChanged: (_) => onPick?.call(),
              label: file.path,
              size: ZsCheckboxSize.sm,
              identifier: 'inspector-file-check',
            ),
          Container(
            width: 14,
            height: 14,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(metrics.radiusKbd)),
            child: Text(
              letter,
              style: ZsType.id.copyWith(
                fontSize: ZsType.fs2xs,
                height: 1,
                fontWeight: FontWeight.w700,
                fontVariations: const <FontVariation>[FontVariation.weight(700)],
                color: ink,
              ),
            ),
          ),
          Expanded(
            child: Opacity(
              opacity: viewed ? .55 : 1,
              child: Text(
                from == null ? file.path : '$from → ${file.path}', // l10n-ignore: paths and an arrow
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ZsType.id.copyWith(color: focused || highlighted ? colors.text : colors.textMuted),
              ),
            ),
          ),
          if (viewed)
            Semantics(
              label: context.l10n.inspectorViewed,
              child: ZanshinIcon(
                ZI.check,
                size: ZsIconSize.xs,
                color: colors.add,
                key: const ValueKey<String>('inspector-file-viewed'),
              ),
            ),
          if (summary != null && summary.added > 0)
            Text('+${summary.added}', style: stat.copyWith(color: colors.add)), // l10n-ignore: a count
          if (summary != null && summary.removed > 0)
            Text('−${summary.removed}', style: stat.copyWith(color: colors.rem)), // l10n-ignore: a count
        ],
      ),
    );
    return Semantics(selected: focused, child: row);
  }
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
/// runs, Cancel (split only) and the gold Commit / Split; jj's hint when a split selects everything, and a refusal
/// in the warn colour.
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

  bool get _ready => widget.blocked == null && widget.model.graph.hasActions && widget.model.composerAction != null;

  void _run() {
    if (!_ready) {
      return;
    }
    unawaited(
      widget.model.runComposer().then((result) {
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
    final List<String> selected = paths.where(model.isPicked).toList();
    final List<String> rest = paths.where((p) => !model.isPicked(p)).toList();
    final String summary = _summary.text.split('\n').first;
    // Nothing checked: no command (a bare `jj commit` would take everything).
    final String command = model.composerCommand ?? '';
    final String? blocked = widget.blocked;
    final ZanshinFfiException? error = model.composerError;
    final TextStyle node = ZsType.secondary.copyWith(fontSize: 12, color: colors.textDim);
    final TextStyle note = ZsType.secondary.copyWith(fontSize: 11.5, height: 1.45, color: colors.textDim);
    final TextStyle stat = ZsType.id.copyWith(fontSize: ZsType.fsSm);

    Widget count(List<String> files) {
      final bool sums = model.hasSummary;
      final int added = files.fold(0, (sum, p) => sum + (model.summaryOf(p)?.added ?? 0));
      final int removed = files.fold(0, (sum, p) => sum + (model.summaryOf(p)?.removed ?? 0));
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
                label: isAt
                    ? <Widget>[
                        ZanshinIcon(ZI.workingCopyAt, size: ZsIconSize.sm, color: colors.co),
                        Text(strings.inspectorComposerNewWorkingCopy, style: labelStyle),
                      ]
                    : <Widget>[Text(strings.inspectorComposerRest, style: labelStyle)],
                meta: rest.isEmpty ? Text(strings.inspectorComposerEmpty, style: node) : count(rest),
                note: noteText(isAt ? strings.inspectorComposerStays : strings.inspectorComposerKeeps(subject)),
              ),
              row(
                dot: dot(chosen: true),
                label: <Widget>[Text(strings.inspectorComposerSelected, style: labelStyle)],
                meta: selected.isEmpty ? Text(strings.inspectorComposerNothingYet, style: node) : count(selected),
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
    final String run = isAt ? strings.inspectorCommit : strings.inspectorSplit;
    final runButton = ZsButton(
      label: run,
      variant: ZsButtonVariant.primary,
      onPressed: ready ? _run : null,
      disabledReason: blocked,
      identifier: 'inspector-composer-run',
    );
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
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 6,
                  children: <Widget>[
                    ZsTextField(
                      controller: _summary,
                      size: ZsTextFieldSize.md,
                      placeholder: isAt ? strings.inspectorComposerSummaryAt : strings.inspectorComposerSummarySplit,
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
                      child: Text(
                        command,
                        key: const ValueKey<String>('inspector-composer-command'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ZsType.command.copyWith(fontSize: ZsType.fsSm, color: colors.textFaint),
                      ),
                    ),
                    if (!isAt)
                      ZsButton(
                        label: strings.inspectorCancel,
                        onPressed: model.clearPicks,
                        identifier: 'inspector-composer-cancel',
                      ),
                    if (blocked ?? (command.isEmpty ? null : command) case final String tip)
                      ZsTooltip(
                        message: tip,
                        cmd: blocked == null || command.isEmpty ? null : command,
                        child: runButton,
                      )
                    else
                      runButton,
                  ],
                ),
                if (!isAt && model.allPicked)
                  Text(
                    'All changes have been selected, so the original revision will become empty.', // l10n-ignore: jj's hint
                    key: const ValueKey<String>('inspector-composer-hint'),
                    style: note,
                  ),
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
