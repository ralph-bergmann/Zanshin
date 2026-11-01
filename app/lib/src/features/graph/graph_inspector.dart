// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io' show FileSystemException;
import 'dart:math' as math;

import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
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
///   focused file's diff ([focusedDiff]). The first file starts focused; a reload keeps the focused path while it is
///   listed. A file is viewed while `viewedKey(change id, path, its summary fingerprint)` is in the viewed store's set; the
///   layout is `general.diffLayout` in [settings], followed when another writer changes it.
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
    final DiffLayoutSetting layout = settings.value.general.diffLayout;
    if (layout != _layout) {
      _layout = layout;
      _notify();
    }
  }

  void _loadFocus() {
    final int serial = ++_focusSerial;
    final String? path = _focused;
    final String? changeId = _changeId;
    if (path == null || changeId == null || _summary == null) {
      _focusedDiff = null;
      _focusError = null;
      return;
    }
    unawaited(() async {
      try {
        final Diff diff = await details.diff(changeId, paths: <String>[path]);
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
  Future<Diff?> _summaryRead(String changeId) async {
    try {
      return await details.diff(changeId, summary: true);
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
    final Future<ChangeActions?> previews = mutable ? _previews(changeId) : Future<ChangeActions?>.value();
    // The diff resolves a change id only: a hidden or divergent node (keyed by its commit id) would read another
    // commit, so it gets no diff (as a refused summary).
    final Future<Diff?> summary = layout.keyOf(node) == changeId ? _summaryRead(changeId) : Future<Diff?>.value();
    try {
      final ShowEntry entry = await details.show(layout.commitIdOf(node));
      final ChangeActions? actions = await previews;
      final Diff? diff = await summary;
      if (serial == _serial) {
        _entry = entry;
        _actions = actions;
        _summary = diff == null ? null : <String, FileDiff>{for (final FileDiff file in diff.files) file.path: file};
        _changeId = changeId;
        final List<String> paths = _listed;
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
///   "Abandon"; else "Edit", "Squash into parent", "Abandon" — each tooltip the full command; Squash stays disabled
///   (10.25).
/// - **Changes:** the file count with the summary's totals, the viewed counter with Mark all / Reset, one row per file
///   with its ± and ✓ (one Tab stop, ↑ ↓ move the highlight, a click or ↩ focuses), and the focused file's diff block
///   (Story 10.24); or the empty, stale or refusal text.
/// - **Esc:** in a field with a changed draft it leaves the field; else it closes the form, else the selection.
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

  /// The last panel built, shown while the shell plays the exit after the selection went.
  Widget? _last;

  @override
  void dispose() {
    _scroll.dispose();
    _root.dispose();
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
                        if (editing != null)
                          _DescribeForm(
                            key: ValueKey<String>(data.key),
                            model: _model,
                            changeKey: data.key,
                            initial:
                                _model.draftOf(data.key) ?? InspectorViewModel.draftFrom(editing.change.description),
                            blocked: graphBlockedReason(strings, graph),
                            // A save can end after the inspector went (a reload dropped the selection, Close).
                            onClosed: () {
                              if (mounted) {
                                _root.requestFocus();
                              }
                            },
                          )
                        else
                          _Title(model: _model, data: data, entry: entry),
                        _Meta(data: data, layout: layout, node: node, entry: entry, nowMs: graph.now.value),
                        if (data.refs.isNotEmpty) _Chips(refs: data.refs),
                        if (editing == null) _Actions(model: _model, data: data, layout: layout, node: node),
                        _Changes(model: _model, data: data),
                      ],
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
          Text(
            label,
            style: ZsType.control.copyWith(
              fontSize: ZsType.fsSm,
              fontWeight: weight,
              fontVariations: <FontVariation>[FontVariation.weight(weight.value.toDouble())],
              color: ink,
            ),
          ),
        ],
      ),
    );
    final String? tooltip = this.tooltip;
    return tooltip == null ? pill : ZsTooltip(message: tooltip, child: pill);
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
    final int prefix = data.prefixLength.clamp(0, id.length);
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
            ZsTooltip(
              message: layout.commitIdOf(node),
              child: Text.rich(
                TextSpan(
                  style: idStyle,
                  children: <InlineSpan>[
                    TextSpan(
                      text: id.substring(0, prefix),
                      style: idStyle.copyWith(
                        fontWeight: FontWeight.w600,
                        fontVariations: const <FontVariation>[FontVariation.weight(600)],
                        color: colors.text,
                      ),
                    ),
                    TextSpan(text: id.substring(prefix)),
                  ],
                ),
                maxLines: 1,
                key: const ValueKey<String>('inspector-id'),
              ),
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
    super.key,
  });

  final InspectorViewModel model;
  final String changeKey;
  final InspectorDraft initial;

  /// Why Save is disabled.
  final String? blocked;

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
    widget.model.updateDraft(widget.changeKey, _draft);
    setState(() {});
  }

  void _save() {
    if (widget.blocked != null || !widget.model.graph.hasActions) {
      return;
    }
    final String key = widget.changeKey;
    unawaited(
      widget.model.save(key, _draft).then((_) {
        if (!widget.model.isOpen(key)) {
          widget.onClosed();
        }
      }),
    );
  }

  void _cancel() {
    widget.model.closeForm(widget.changeKey);
    widget.onClosed();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final String? blocked = widget.blocked;
    final String command = GraphDescribe.fromParagraphs(
      widget.changeKey,
      InspectorViewModel.paragraphsOf(_draft),
    ).command;
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
                    label: strings.inspectorSave,
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

  /// The parents' short ids: `show`'s parents, else the layout's direct parents (the stale state).
  List<String> _parents() {
    final List<String>? shown = entry?.change.parents;
    if (shown != null) {
      return <String>[
        for (final String id in shown)
          switch (layout.indexOfKey(id)) {
            final int parent => graphShortId(layout, parent),
            null => id.substring(0, math.min(8, id.length)),
          },
      ];
    }
    final ({int start, int end}) edges = layout.parentEdges(node);
    return <String>[
      for (var e = edges.start; e < edges.end; e++)
        if (layout.kindOf(e) == GraphEdgeKind.direct) graphShortId(layout, layout.parentOf(e)),
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
    final List<String> parents = data.isRoot ? const <String>[] : _parents();
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
              TextSpan(
                text: parents[i],
                style: ZsType.id.copyWith(color: colors.textMuted),
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
    }) {
      final String? reason = blocked ?? disabled;
      return ZsTooltip(
        message: reason ?? command,
        cmd: reason == null ? null : command,
        child: ZsButton(
          label: label,
          variant: variant,
          icon: icon,
          onPressed: can && disabled == null ? () => unawaited(graph.run(action)) : null,
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
              // 10.25 enables it with the composer.
              disabled: refusal == null ? strings.inspectorSquashLater : refusal.context ?? refusal.code,
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
                      child: _FileRow(
                        file: files[i],
                        summary: model.summaryOf(files[i].path),
                        focused: files[i].path == focused,
                        highlighted: _focus.hasFocus && i == highlight,
                        viewed: model.isViewed(files[i].path),
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
/// keyboard highlight on `--fl-hover`; a viewed file's ✓ and its path at .55; the summary's ± when read.
class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.summary,
    required this.focused,
    required this.highlighted,
    required this.viewed,
  });

  final FileChange file;
  final FileDiff? summary;
  final bool focused;
  final bool highlighted;
  final bool viewed;

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
