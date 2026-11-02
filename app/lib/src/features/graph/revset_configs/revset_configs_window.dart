// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../../l10n/strings.dart';
import '../../shell/app_menu.dart' show GraphMenuBinding, jjDocumentationUrl;
import '../../window/app_windows.dart';
import '../graph_ports.dart' show jjLogCommand;
import '../graph_search_controller.dart';
import '../graph_search_model.dart';
import '../graph_view_model.dart';
import 'revset_config_expression.dart';
import 'revset_configs_draft.dart';

final _log = Logger('zanshin.graph.configurations');

TextStyle _sans(double size, {double height = 1.3, bool medium = false}) => ZsType.body.copyWith(
  fontSize: size,
  height: height,
  fontWeight: medium ? FontWeight.w500 : null,
  fontVariations: medium ? const <FontVariation>[FontVariation.weight(500)] : null,
);

TextStyle _mono(double size, {double height = 1.3}) => ZsType.id.copyWith(fontSize: size, height: height);

/// jj's revset reference at the pinned jj-lib version, beside Help's documentation.
final Uri revsetReferenceUrl = jjDocumentationUrl.resolve('revsets/'); // l10n-ignore: a URL path

/// The jj log Configurations window (Story 10.22; DS components/search/RevsetDialog.{jsx,prompt.md}, search.css:111-203):
/// the list (Built-in `jj log` and `all()`, the custom configurations), the editor of the selected entry (name, the
/// Default search switch, the rules), the command preview with its count, and the footer (Revset reference, Cancel,
/// Apply, OK).
///
/// - **Which project:** count, `mine()`'s email, Apply and OK go through the project window's graph in [graph] (the
///   menu bar's binding), so they follow a project switch; without one the preview shows no count and Apply / OK only
///   save.
/// - **Saving** writes [settings]' `graph` (the configurations and the default search, global) — never jj config. Apply
///   saves (the search redraws a shown entry whose expression changed); OK saves and shows the selected entry in one
///   request, then closes.
/// - **Leaving:** Esc, ⌘W and the red button ([AppWindows.setCloseHandler]) cancel, asking "Discard changes?" first
///   while the draft is dirty; while dirty the window also guards closing the project, switching it and quitting
///   ([AppWindows.addCloseGuard]). ↩ outside a text field = OK.
class RevsetConfigsWindow extends StatefulWidget {
  /// The window [windowKey] of [windows] over [settings] and the project window's [graph].
  const RevsetConfigsWindow({
    required this.settings,
    required this.graph,
    required this.windows,
    this.windowKey = revsetConfigsWindowKey,
    this.openUrl,
    super.key,
  });

  /// The settings the configurations live in.
  final SettingsStore settings;

  /// The project window's graph, or null without an open project.
  final ValueListenable<GraphMenuBinding?> graph;

  /// The app's windows: the close handler, the close guard, closing and bringing this window forward.
  final AppWindows windows;

  /// This window's key in [windows].
  final String windowKey;

  /// Opens the revset reference in the browser; null disables the link.
  final Future<void> Function(Uri url)? openUrl;

  /// The list's width (DS search.css:120).
  static const double listWidth = 240;

  @override
  State<RevsetConfigsWindow> createState() => RevsetConfigsWindowState();
}

/// One "Discard changes?" question: [result] completes once its sheet has gone, true for Discard.
class _Discard {
  final result = Completer<bool>();
  var closing = false;
  var confirmed = false;
}

/// The window's state; [draft] is open for the catalogue and tests.
class RevsetConfigsWindowState extends State<RevsetConfigsWindow> {
  late final RevsetConfigsDraft draft;
  final _name = ZsTextEditingController();
  final _nameFocus = FocusNode(debugLabel: 'configuration name');
  final _root = FocusNode(debugLabel: 'jj log Configurations');
  final _editorScroll = ScrollController();
  var _values = <ZsTextEditingController>[];
  ({String? id, int rules}) _valuesOf = (id: null, rules: -1);
  _Discard? _asking;
  VoidCallback? _removeGuard;
  GraphMenuBinding? _bound;
  Timer? _copiedTimer;
  var _copied = false;

  /// The entry that takes the window's first focus (the selection it opened with; DS: focus starts there).
  String? _initialFocus;

  GraphSearchController? get _search => _bound?.search;

  GraphViewModel? get _model => _bound?.model;

  @override
  void initState() {
    super.initState();
    _bind();
    draft = RevsetConfigsDraft(widget.settings.value.graph, selected: _shownEntry())..addListener(_draftChanged);
    _initialFocus = draft.selected;
    _syncFields();
    widget.graph.addListener(_graphChanged);
    widget.windows.setCloseHandler(widget.windowKey, () async => cancel());
  }

  @override
  void dispose() {
    widget.graph.removeListener(_graphChanged);
    _unbind();
    widget.windows.setCloseHandler(widget.windowKey, null);
    _removeGuard?.call();
    if (_asking case final _Discard asking when !asking.result.isCompleted) {
      asking.result.complete(true);
    }
    _copiedTimer?.cancel();
    draft.dispose();
    _name.dispose();
    _nameFocus.dispose();
    _root.dispose();
    _editorScroll.dispose();
    for (final ZsTextEditingController c in _values) {
      c.dispose();
    }
    super.dispose();
  }

  // ── The project's graph ───────────────────────────────────────────────────

  void _bind() {
    _bound = widget.graph.value;
    _bound?.search?.addListener(_rebuild);
    _bound?.model.addListener(_modelChanged);
    _modelChanged();
  }

  void _unbind() {
    _bound?.search?.removeListener(_rebuild);
    _bound?.model.removeListener(_modelChanged);
    _bound = null;
  }

  /// A layout landed: `user.email` is read once per operation (the search guards it), and the preview counts at it.
  void _modelChanged() {
    if (_bound?.search case final GraphSearchController search) {
      unawaited(search.prepare());
    }
    _rebuild();
  }

  void _graphChanged() {
    _unbind();
    _bind();
    _rebuild();
  }

  void _rebuild() {
    if (mounted) {
      setState(() {});
    }
  }

  /// The entry the graph shows, for the first selection; null for a filter (the default is selected then).
  String? _shownEntry() {
    final GraphSearchController? search = _search;
    return switch (search?.view) {
      GraphDefaultSearch() => search!.defaultSearch,
      GraphLogView() => revsetDefaultLog,
      GraphAllView() => revsetDefaultAll,
      GraphConfigView(:final String id) => id,
      _ => null,
    };
  }

  // ── The draft ─────────────────────────────────────────────────────────────

  void _draftChanged() {
    final bool dirty = draft.dirty;
    if (dirty && _removeGuard == null) {
      _removeGuard = widget.windows.addCloseGuard(_guard);
    } else if (!dirty) {
      _removeGuard?.call();
      _removeGuard = null;
    }
    _syncFields();
    _rebuild();
  }

  /// The name field and the value fields follow the selection; an edit in them is the draft's already.
  void _syncFields() {
    final RevsetConfiguration? current = draft.current;
    if (current != null && _name.text != current.name) {
      _name.text = current.name;
    }
    final ({String? id, int rules}) of = (id: current?.id, rules: current?.rules.length ?? -1);
    if (of != _valuesOf) {
      for (final ZsTextEditingController c in _values) {
        c.dispose();
      }
      _values = <ZsTextEditingController>[
        for (final RevsetRule r in current?.rules ?? const <RevsetRule>[]) ZsTextEditingController(text: r.value),
      ];
      _valuesOf = of;
    }
    // A function round trip or a reset changes a value without the field typing it.
    final List<RevsetRule> rules = current?.rules ?? const <RevsetRule>[];
    for (var i = 0; i < _values.length && i < rules.length; i++) {
      if (_values[i].text != rules[i].value) {
        _values[i].text = rules[i].value;
      }
    }
  }

  void _add() {
    draft.add(context.l10n.revsetConfigsNewName);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _nameFocus.requestFocus();
        _name.selection = TextSelection(baseOffset: 0, extentOffset: _name.text.length);
      }
    });
  }

  // ── Saving and leaving ────────────────────────────────────────────────────

  void _save() {
    final GraphSettings saved = draft.applyTo(widget.settings.value.graph);
    unawaited(
      widget.settings
          .update((s) => s.copyWith(graph: draft.applyTo(s.graph)))
          .catchError(
            (Object error, StackTrace stack) => _log.warning('saving the configurations failed', error, stack),
          ),
    );
    draft.saved(saved);
  }

  /// Apply: saves; the search redraws what it shows when its expression changed.
  void apply() {
    if (draft.dirty) {
      _save();
    }
  }

  /// OK: saves, shows the selected entry (the default as the default search) and closes.
  void ok() {
    final String? selected = draft.selected;
    final GraphShownView view = selected == null || selected == draft.home
        ? GraphShownView.defaultSearch
        : switch (selected) {
            revsetDefaultLog => const GraphLogView(),
            revsetDefaultAll => const GraphAllView(),
            _ => GraphConfigView(selected),
          };
    if (_search case final GraphSearchController search) {
      search.showSaving(view, _save);
    } else {
      _save();
    }
    widget.windows.close(widget.windowKey);
  }

  /// Cancel (Esc, ⌘W, the red button): closes, asking first while the draft is dirty.
  Future<void> cancel() async {
    if (draft.dirty && !await _ask()) {
      return;
    }
    widget.windows.close(widget.windowKey);
  }

  /// The close guard while dirty: the window comes forward and asks; Discard drops the edits and lets the close on.
  Future<bool> _guard() async {
    widget.windows.activate(widget.windowKey);
    return _ask();
  }

  /// Shows "Discard changes?" (or joins the one showing); true once Discard dropped the edits.
  Future<bool> _ask() {
    final _Discard asking = _asking ??= _Discard();
    _rebuild();
    return asking.result.future;
  }

  void _answered(_Discard asking, {required bool discard}) => setState(() {
    asking
      ..confirmed = discard
      ..closing = true;
  });

  void _askClosed(_Discard asking) {
    if (identical(_asking, asking)) {
      setState(() => _asking = null);
    }
    if (asking.confirmed) {
      draft.reset(widget.settings.value.graph);
    }
    if (!asking.result.isCompleted) {
      asking.result.complete(asking.confirmed);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_asking != null || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      unawaited(cancel());
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) && !_inTextField) {
      ok();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static bool get _inTextField =>
      FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() != null;

  // ── The preview ───────────────────────────────────────────────────────────

  /// The selected entry's command and the expression its count asks for (null: none to count).
  ({String command, String? expression, ({String text, List<({int start, int end})?> ranges})? built}) _preview() {
    final String? selected = draft.selected;
    if (draft.current case final RevsetConfiguration c) {
      final ({List<({int end, int start})?> ranges, String text}) built = revsetConfigExpression(c);
      return (command: jjLogCommand(built.text), expression: built.text, built: built);
    }
    return switch (selected) {
      revsetDefaultLog => (command: 'jj log', expression: _model?.logDefaults?.log, built: null), // l10n-ignore: jj
      revsetDefaultAll => (
        command: jjLogCommand(GraphAllView.expression),
        expression: GraphAllView.expression,
        built: null,
      ),
      _ => (command: '', expression: null, built: null),
    };
  }

  void _copy(String command) {
    unawaited(Clipboard.setData(ClipboardData(text: command)));
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(ZsMotion.of(context).durCopied, () {
      if (mounted) {
        setState(() => _copied = false);
      }
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final AppLocalizations s = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final ({({List<({int end, int start})?> ranges, String text})? built, String command, String? expression}) preview =
        _preview();
    final String? expression = preview.expression;
    final GraphSearchController? search = _search;
    RevsetCount? count;
    if (search != null && expression != null) {
      search.wantCounts(<String>[expression]);
      count = search.countOf(expression);
    }
    // The rule whose term holds the count error's span.
    int? marked;
    final ZanshinFfiException? error = count?.error;
    final RevsetSpan? span = error?.revsetError?.span;
    if (preview.built case (:final String text, :final List<({int start, int end})?> ranges) when span != null) {
      final (:int start, :int end) = revsetSpanUtf16(text, span);
      final int stop = math.max(end, start + 1);
      for (var i = 0; i < ranges.length; i++) {
        final ({int start, int end})? r = ranges[i];
        // A position at the very end of the text (an end-of-input parse error) belongs to the term ending there.
        if (r != null && r.start < stop && (start < r.end || (start == text.length && r.end == text.length))) {
          marked = i;
          break;
        }
      }
    }
    // A spanless error (every resolution error) goes to the raw rule naming its symbol, else to the only raw rule.
    final List<RevsetRule>? rules = draft.current?.rules;
    if (preview.built case (:final List<({int start, int end})?> ranges, text: _)
        when marked == null && error != null && span == null && rules != null) {
      final raw = <int>[
        for (var i = 0; i < rules.length && i < ranges.length; i++)
          if (ranges[i] != null && rules[i].fn == RevsetRuleFunction.revset) i,
      ];
      final String? symbol = error.revsetError?.symbol;
      marked = symbol == null ? null : raw.where((i) => rules[i].value.contains(symbol)).firstOrNull;
      marked ??= raw.length == 1 ? raw.single : null;
    }
    // A raw rule's field marks the span itself, in its own text: the term is the value, maybe grouped or negated.
    TextRange? fieldSpan;
    if (preview.built case (:final String text, :final List<({int start, int end})?> ranges)
        when marked != null && span != null && rules != null && rules[marked].fn == RevsetRuleFunction.revset) {
      final ({int start, int end})? r = ranges[marked];
      final String value = rules[marked].value;
      final int index = r == null ? -1 : text.substring(r.start, r.end).indexOf(value);
      final int at = r == null ? 0 : r.start + index;
      final (:int start, :int end) = revsetSpanUtf16(text, span);
      // Only a span on the value's own text (a position may sit at its end) marks the field.
      final bool inside = start == end
          ? start >= at && start <= at + value.length
          : start < at + value.length && end > at;
      if (value.isNotEmpty && index >= 0 && inside) {
        int from = (start - at).clamp(0, value.length);
        int to = (end - at).clamp(from, value.length);
        if (to == from) {
          // A position (an end-of-input error) marks the char at it, or the last one.
          from = math.min(from, value.length - 1);
          to = from + 1;
        }
        fieldSpan = TextRange(start: from, end: to);
      }
    }
    final _Discard? asking = _asking;
    return Semantics(
      identifier: 'revset-configs-window',
      container: true,
      explicitChildNodes: true,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Focus(
              focusNode: _root,
              onKeyEvent: _onKey,
              child: ZsWindowScaffold(
                title: s.revsetConfigsTitle,
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border(right: BorderSide(color: colors.flBorder)),
                            ),
                            child: SizedBox(width: RevsetConfigsWindow.listWidth, child: _list(context, s, colors)),
                          ),
                          Expanded(child: _editor(context, s, colors, preview, count, marked, fieldSpan)),
                        ],
                      ),
                    ),
                    _footer(s, colors),
                  ],
                ),
              ),
            ),
          ),
          if (asking != null)
            Positioned.fill(
              child: ZsConfirmDialog(
                title: s.revsetConfigsDiscardTitle,
                confirmLabel: s.revsetConfigsDiscard,
                body: Text(s.revsetConfigsDiscardBody),
                closing: asking.closing,
                onConfirm: () => _answered(asking, discard: true),
                onCancel: () => _answered(asking, discard: false),
                onClosed: () => _askClosed(asking),
                identifier: 'revset-configs-discard',
              ),
            ),
        ],
      ),
    );
  }

  // ── The list ──────────────────────────────────────────────────────────────

  Widget _list(BuildContext context, AppLocalizations s, ZsColors colors) {
    final int index = draft.currentIndex;
    final List<RevsetConfiguration> configs = draft.configs;
    Widget tag(String id) => id == draft.home ? _Tag(s.graphSearchDefaultTag) : const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.flBorder)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              spacing: 2,
              children: <Widget>[
                ZsIconButton(
                  icon: ZI.plus,
                  label: s.revsetConfigsAdd,
                  size: ZsIconButtonSize.sm,
                  onPressed: _add,
                  identifier: 'revset-configs-add',
                ),
                ZsIconButton(
                  icon: ZI.minus,
                  label: s.revsetConfigsRemove,
                  size: ZsIconButtonSize.sm,
                  onPressed: index < 0 ? null : draft.remove,
                  identifier: 'revset-configs-remove',
                ),
                ZsIconButton(
                  icon: ZI.copy,
                  label: s.revsetConfigsDuplicate,
                  size: ZsIconButtonSize.sm,
                  onPressed: index < 0
                      ? null
                      : () => draft.duplicate(
                          s.revsetConfigsCopyName(
                            configs[index].name.isEmpty ? s.revsetConfigsUnnamed : configs[index].name,
                          ),
                        ),
                  identifier: 'revset-configs-duplicate',
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: SizedBox(width: 1, height: 16, child: ColoredBox(color: colors.flBorder)),
                ),
                ZsIconButton(
                  icon: ZI.chevronUp,
                  label: s.revsetConfigsMoveUp,
                  size: ZsIconButtonSize.sm,
                  onPressed: index <= 0 ? null : () => draft.move(-1),
                  identifier: 'revset-configs-up',
                ),
                ZsIconButton(
                  icon: ZI.chevronDown,
                  label: s.revsetConfigsMoveDown,
                  size: ZsIconButtonSize.sm,
                  onPressed: index < 0 || index >= configs.length - 1 ? null : () => draft.move(1),
                  identifier: 'revset-configs-down',
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
            children: <Widget>[
              _Section(s.revsetConfigsBuiltIn),
              _ListItem(
                on: draft.selected == revsetDefaultLog,
                onPressed: () => draft.select(revsetDefaultLog),
                identifier: 'revset-configs-item-log',
                autofocus: _initialFocus == revsetDefaultLog,
                name: _code('jj log', colors, builtIn: true), // l10n-ignore: jj command
                tag: tag(revsetDefaultLog),
              ),
              _ListItem(
                on: draft.selected == revsetDefaultAll,
                onPressed: () => draft.select(revsetDefaultAll),
                identifier: 'revset-configs-item-all',
                autofocus: _initialFocus == revsetDefaultAll,
                name: _code(jjLogCommand(GraphAllView.expression), colors, builtIn: true),
                tag: tag(revsetDefaultAll),
              ),
              _Section(s.revsetConfigsCustom),
              for (final RevsetConfiguration c in configs)
                _ListItem(
                  on: draft.selected == c.id,
                  onPressed: () => draft.select(c.id),
                  identifier: 'revset-configs-item-${c.id}',
                  autofocus: _initialFocus == c.id,
                  name: Text(
                    c.name.isEmpty ? s.revsetConfigsUnnamed : c.name,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: _sans(ZsType.fsBase).copyWith(color: colors.text),
                  ),
                  tag: tag(c.id),
                  detail: Text(
                    revsetConfigText(c),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: _mono(ZsType.fsSm).copyWith(color: colors.textDim),
                  ),
                ),
              if (configs.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: ZsButton(
                      label: s.revsetConfigsAdd,
                      icon: ZI.plus,
                      variant: ZsButtonVariant.ghost,
                      onPressed: _add,
                      identifier: 'revset-configs-list-add',
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _code(String text, ZsColors colors, {bool builtIn = false}) => Text(
    text,
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.ellipsis,
    style: _mono(builtIn ? ZsType.fsMd : ZsType.fsSm).copyWith(color: colors.textMuted),
  );

  // ── The editor ────────────────────────────────────────────────────────────

  Widget _editor(
    BuildContext context,
    AppLocalizations s,
    ZsColors colors,
    ({String command, String? expression, ({String text, List<({int start, int end})?> ranges})? built}) preview,
    RevsetCount? count,
    int? marked,
    TextRange? fieldSpan,
  ) {
    final String? selected = draft.selected;
    final RevsetConfiguration? current = draft.current;
    if (selected == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: <Widget>[
            Text(s.revsetConfigsEmpty, style: _sans(ZsType.fsBase).copyWith(color: colors.textDim)),
            ZsButton(
              label: s.revsetConfigsAdd,
              icon: ZI.plus,
              size: ZsButtonSize.md,
              onPressed: _add,
              identifier: 'revset-configs-empty-add',
            ),
          ],
        ),
      );
    }
    final TextStyle label = _sans(ZsType.fsMd).copyWith(color: colors.textMuted);
    return ZsScrollArea(
      controller: _editorScroll,
      child: SingleChildScrollView(
        controller: _editorScroll,
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 22,
          children: <Widget>[
            Row(
              spacing: 12,
              children: <Widget>[
                Text(s.revsetConfigsName, style: label),
                Expanded(
                  child: current != null
                      ? ZsTextField(
                          controller: _name,
                          focusNode: _nameFocus,
                          size: ZsTextFieldSize.md,
                          label: s.revsetConfigsName,
                          onChanged: (name) => draft.edit((c) => c.copyWith(name: name)),
                          identifier: 'revset-configs-name',
                        )
                      : _builtInName(s, colors, selected),
                ),
              ],
            ),
            _homeRow(s, colors),
            if (current != null) _filters(s, colors, current, marked, fieldSpan, count?.error),
            _previewBlock(s, colors, preview.command, count, label),
          ],
        ),
      ),
    );
  }

  Widget _builtInName(AppLocalizations s, ZsColors colors, String selected) {
    final log = selected == revsetDefaultLog;
    return Row(
      spacing: 10,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Text(
          log ? 'jj log' : jjLogCommand(GraphAllView.expression), // l10n-ignore: jj command
          style: _mono(ZsType.fsBase).copyWith(color: colors.text),
        ),
        Expanded(
          child: Text(
            s.revsetConfigsBuiltInDetail(log ? s.graphSearchLogDetail : s.graphSearchAllDetail),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: _sans(ZsType.fsMd).copyWith(color: colors.textDim),
          ),
        ),
      ],
    );
  }

  Widget _homeRow(AppLocalizations s, ZsColors colors) {
    final metrics = ZsMetrics.of(context);
    final bool locked = draft.homeLocked;
    final isHome = draft.selected == draft.home;
    return DecoratedBox(
      decoration: BoxDecoration(color: colors.flHover, borderRadius: BorderRadius.circular(metrics.radiusWell)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 46),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            spacing: 16,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: <Widget>[
                    Text(
                      s.revsetConfigsDefaultSearch,
                      style: _sans(ZsType.fsBase).copyWith(color: colors.text),
                    ),
                    Text(
                      locked ? s.revsetConfigsDefaultLockedHint : s.revsetConfigsDefaultHint,
                      style: _sans(ZsType.fsId, height: 1.4).copyWith(color: colors.textDim),
                    ),
                  ],
                ),
              ),
              ZsSwitch(
                value: isHome,
                label: s.revsetConfigsDefaultSearch,
                onChanged: locked ? null : (on) => draft.setHome(on: on),
                identifier: 'revset-configs-default',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filters(
    AppLocalizations s,
    ZsColors colors,
    RevsetConfiguration current,
    int? marked,
    TextRange? fieldSpan,
    ZanshinFfiException? error,
  ) {
    final List<RevsetRule> rules = current.rules;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 26),
          child: Row(
            spacing: 12,
            children: <Widget>[
              Expanded(
                child: Text(
                  s.revsetConfigsFilters,
                  style: _sans(ZsType.fsMd).copyWith(color: colors.textMuted),
                ),
              ),
              if (rules.length > 1)
                ZsSegmented<RevsetCombine>(
                  label: s.revsetConfigsCombine,
                  size: ZsSegmentedSize.sm,
                  value: current.op,
                  segments: <ZsSegment<RevsetCombine>>[
                    ZsSegment<RevsetCombine>(value: RevsetCombine.and, label: s.revsetConfigsMatchAll),
                    ZsSegment<RevsetCombine>(value: RevsetCombine.or, label: s.revsetConfigsMatchAny),
                  ],
                  onChanged: (op) => draft.edit((c) => c.copyWith(op: op)),
                  identifier: 'revset-configs-combine',
                ),
            ],
          ),
        ),
        if (rules.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              s.revsetConfigsNoFilters(GraphAllView.expression),
              style: _sans(ZsType.fsMd).copyWith(color: colors.textDim),
            ),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 6,
            children: <Widget>[
              for (var i = 0; i < rules.length; i++)
                _rule(
                  s,
                  colors,
                  i,
                  rules[i],
                  marked: marked == i,
                  error: marked == i ? error : null,
                  errorSpan: marked == i ? fieldSpan : null,
                ),
            ],
          ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final RevsetRuleFunction fn in RevsetRuleFunction.values)
              ZsTooltip(
                message: s.revsetConfigsHint(fn.name),
                child: ZsChip(
                  label: fn.name,
                  kind: ZsChipKind.add,
                  mono: true,
                  onPressed: () => draft.addRule(fn),
                  identifier: 'revset-configs-add-${fn.name}',
                ),
              ),
          ],
        ),
      ],
    );
  }

  static const _textModes = <RevsetRuleMode>[
    RevsetRuleMode.substring,
    RevsetRuleMode.exact,
    RevsetRuleMode.glob,
    RevsetRuleMode.regex,
  ];

  static const _pathModes = <RevsetRuleMode>[RevsetRuleMode.prefix, RevsetRuleMode.file, RevsetRuleMode.glob];

  Widget _rule(
    AppLocalizations s,
    ZsColors colors,
    int i,
    RevsetRule rule, {
    required bool marked,
    ZanshinFfiException? error,
    TextRange? errorSpan,
  }) {
    final files = rule.fn == RevsetRuleFunction.files;
    final raw = rule.fn == RevsetRuleFunction.revset;
    final ZsTextEditingController? value = i < _values.length ? _values[i] : null;
    final String placeholder = raw
        ? 'trunk()..@' // l10n-ignore: an example revset
        : files
        ? (rule.mode == RevsetRuleMode.glob ? 'lib/**/*.dart' : 'app/lib/main.dart') // l10n-ignore: example paths
        : s.revsetConfigsHint(rule.fn.name);
    // A raw rule shows jj's one-line message and its similar names; a structured rule is only marked (Story 10.22).
    final List<String> candidates = error?.revsetError?.candidates ?? const <String>[];
    final String? errorText = !marked
        ? null
        : !raw || error == null
        ? ''
        : <String>[
            error.revsetError?.message ?? error.context ?? error.code,
            if (candidates.isNotEmpty)
              s.revsetConfigsDidYouMean(candidates.map((c) => '`$c`').join(', ')), // l10n-ignore: jj's quoting
          ].join('\n');
    final String? email = _search?.userEmail;
    final Widget body;
    if (rule.fn == RevsetRuleFunction.mine) {
      body = Expanded(
        child: Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(text: '${s.revsetConfigsAuthoredBy} '),
                TextSpan(
                  text: email ?? '…', // l10n-ignore: a symbol
                  style: TextStyle(color: marked ? colors.rem : colors.text, fontWeight: FontWeight.w500),
                ),
                TextSpan(
                  text: ' · user.email', // l10n-ignore: jj's config key
                  style: TextStyle(color: colors.textFaint),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _sans(ZsType.fsMd).copyWith(color: colors.textMuted),
          ),
        ),
      );
    } else {
      body = Expanded(
        child: Row(
          spacing: 6,
          children: <Widget>[
            if (!raw)
              SizedBox(
                width: 128,
                child: ZsSelect<RevsetRuleMode>(
                  label: s.revsetConfigsMatch,
                  value: rule.mode,
                  options: <ZsSelectEntry<RevsetRuleMode>>[
                    for (final RevsetRuleMode m in files ? _pathModes : _textModes)
                      ZsSelectOption<RevsetRuleMode>(
                        value: m,
                        label: s.revsetConfigsMode(files && m == RevsetRuleMode.glob ? 'fileGlob' : m.name),
                      ),
                  ],
                  onChanged: (m) => draft.setRule(i, rule.copyWith(mode: m)),
                  identifier: 'revset-configs-rule-$i-mode',
                ),
              ),
            Expanded(
              child: ZsTextField(
                controller: value,
                mono: true,
                size: ZsTextFieldSize.md,
                placeholder: placeholder,
                error: errorText,
                errorRange: errorSpan,
                onChanged: (v) => draft.setRule(i, rule.copyWith(value: v)),
                identifier: 'revset-configs-rule-$i-value',
              ),
            ),
            if (!files && !raw)
              ZsTooltip(
                message: s.revsetConfigsCaseInsensitive,
                child: ZsChip(
                  label: 'Aa', // l10n-ignore: a symbol
                  mono: true,
                  size: ZsChipSize.sm,
                  on: rule.ci,
                  onChanged: (ci) => draft.setRule(i, rule.copyWith(ci: ci)),
                  identifier: 'revset-configs-rule-$i-ci',
                ),
              ),
          ],
        ),
      );
    }
    return Semantics(
      identifier: 'revset-configs-rule-$i',
      container: true,
      child: Row(
        spacing: 6,
        children: <Widget>[
          // The DS's 52 px column as a minimum: "~ not" may be wider in some fonts.
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 52),
            child: ZsTooltip(
              message: rule.not ? s.revsetConfigsNotOnTooltip : s.revsetConfigsNotOffTooltip,
              child: ZsChip(
                label: rule.not ? s.revsetConfigsNot : s.revsetConfigsIs,
                kind: ZsChipKind.not,
                mono: true,
                on: rule.not,
                onChanged: (not) => draft.setRule(i, rule.copyWith(not: not)),
                identifier: 'revset-configs-rule-$i-not',
              ),
            ),
          ),
          SizedBox(
            width: 124,
            child: ZsTooltip(
              message: s.revsetConfigsHint(rule.fn.name),
              child: ZsSelect<RevsetRuleFunction>(
                label: s.revsetConfigsFunction,
                mono: true,
                value: rule.fn,
                options: <ZsSelectEntry<RevsetRuleFunction>>[
                  for (final RevsetRuleFunction fn in RevsetRuleFunction.values)
                    ZsSelectOption<RevsetRuleFunction>(
                      value: fn,
                      label: fn == RevsetRuleFunction.revset
                          ? fn.name
                          : '${fn.name}()', // l10n-ignore: jj revset function
                      text: fn.name,
                      mono: true,
                    ),
                ],
                onChanged: (fn) => draft.setRuleFunction(i, fn),
                identifier: 'revset-configs-rule-$i-fn',
              ),
            ),
          ),
          body,
          ZsIconButton(
            icon: ZI.close,
            label: s.revsetConfigsRemoveFilter,
            size: ZsIconButtonSize.sm,
            onPressed: () => draft.removeRule(i),
            identifier: 'revset-configs-rule-$i-remove',
          ),
        ],
      ),
    );
  }

  Widget _previewBlock(AppLocalizations s, ZsColors colors, String command, RevsetCount? count, TextStyle label) {
    final metrics = ZsMetrics.of(context);
    final ZanshinFfiException? error = count?.error;
    final int? total = _model?.total;
    final Widget status = switch (count) {
      _ when error != null => Text(
        error.revsetError?.message ?? error.context ?? error.code,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colors.rem),
      ),
      RevsetCount(:final int n, :final bool capped) when total != null => Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: capped ? '$n+' : '$n',
              style: TextStyle(color: colors.text, fontWeight: FontWeight.w500),
            ),
            TextSpan(text: s.revsetConfigsMatchesOf('$total')),
          ],
        ),
      ),
      _ => const SizedBox.shrink(),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: <Widget>[
        Text(s.revsetConfigsCommand, style: label),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.codeBg,
            border: Border.all(color: colors.flBorder),
            borderRadius: BorderRadius.circular(metrics.radiusWell),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Semantics(
                  identifier: 'revset-configs-command',
                  child: Text.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        TextSpan(
                          text: '❯ ', // l10n-ignore: a prompt symbol
                          style: _mono(ZsType.fsMd, height: 1.55).copyWith(color: colors.textFaint),
                        ),
                        TextSpan(text: command),
                      ],
                    ),
                    style: _mono(ZsType.fsControl, height: 1.55).copyWith(color: colors.text),
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: colors.flBorder)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
                  child: Row(
                    spacing: 10,
                    children: <Widget>[
                      Expanded(
                        child: Semantics(
                          identifier: 'revset-configs-count',
                          child: DefaultTextStyle.merge(
                            style: _sans(ZsType.fsMd).copyWith(color: colors.textDim),
                            child: status,
                          ),
                        ),
                      ),
                      ZsLink(
                        label: _copied ? s.revsetConfigsCopied : s.revsetConfigsCopy,
                        quiet: true,
                        onPressed: command.isEmpty ? null : () => _copy(command),
                        identifier: 'revset-configs-copy',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── The footer ────────────────────────────────────────────────────────────

  Widget _footer(AppLocalizations s, ZsColors colors) {
    final Future<void> Function(Uri url)? openUrl = widget.openUrl;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.flBorder)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 14, 14),
        child: Row(
          spacing: 8,
          children: <Widget>[
            ZsLink(
              label: s.revsetConfigsReference,
              quiet: true,
              onPressed: openUrl == null ? null : () => unawaited(openUrl(revsetReferenceUrl)),
              identifier: 'revset-configs-reference',
            ),
            const Spacer(),
            ZsButton(
              label: s.revsetConfigsCancel,
              size: ZsButtonSize.md,
              onPressed: () => unawaited(cancel()),
              identifier: 'revset-configs-cancel',
            ),
            ZsButton(
              label: s.revsetConfigsApply,
              size: ZsButtonSize.md,
              onPressed: draft.dirty ? apply : null,
              identifier: 'revset-configs-apply',
            ),
            ZsButton(
              label: s.revsetConfigsOk,
              size: ZsButtonSize.md,
              variant: ZsButtonVariant.primary,
              onPressed: ok,
              identifier: 'revset-configs-ok',
            ),
          ],
        ),
      ),
    );
  }
}

/// A list section heading (`.zs-rsd-sec`, DS search.css:125).
class _Section extends StatelessWidget {
  const _Section(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      child: Text(label.toUpperCase(), style: ZsType.capsLabel.copyWith(color: colors.textDim)),
    );
  }
}

/// The `Default` tag (DS search.css:136): 16 high, outlined in `--border-strong`, no fill.
class _Tag extends StatelessWidget {
  const _Tag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.borderStrong),
        borderRadius: BorderRadius.circular(metrics.radiusXs),
      ),
      child: SizedBox(
        height: 16,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: _sans(ZsType.fsXs, height: 1, medium: true).copyWith(color: colors.textDim),
            ),
          ),
        ),
      ),
    );
  }
}

/// A list entry (`.zs-rsd-item`, DS search.css:126-135): [name] (and [tag]) over an optional [detail]; hover
/// `--fl-hover`, pressed `--fl-on`, selected `--accent-soft`.
class _ListItem extends StatefulWidget {
  const _ListItem({
    required this.on,
    required this.onPressed,
    required this.identifier,
    required this.name,
    required this.tag,
    this.detail,
    this.autofocus = false,
  });

  final bool on;
  final VoidCallback onPressed;
  final String identifier;
  final Widget name;
  final Widget tag;
  final Widget? detail;

  /// Whether the entry takes the window's first focus (the selected one).
  final bool autofocus;

  @override
  State<_ListItem> createState() => _ListItemState();
}

class _ListItemState extends State<_ListItem> {
  var _hovered = false;
  var _pressed = false;
  var _ring = false;

  // Space selects the focused entry; ↩ goes on to the window's OK (a click selects without moving the focus, so a
  // ↩ here must not re-select the focused entry).
  static const _keys = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
  };

  late final _actions = <Type, Action<Intent>>{
    ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onPressed()),
  };

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final bool inactive = ZsAppearance.of(context).inactive;
    final Color fill = widget.on
        ? (_pressed ? colors.accentSoftHi : colors.accentSoft)
        : _pressed
        ? colors.flOn
        : _hovered && !inactive
        ? colors.flHover
        : const Color(0x00000000);
    final Widget? detail = widget.detail;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        button: true,
        selected: widget.on,
        identifier: widget.identifier,
        onTap: widget.onPressed,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            excludeFromSemantics: true,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: widget.onPressed,
            child: FocusableActionDetector(
              autofocus: widget.autofocus,
              shortcuts: _keys,
              actions: _actions,
              onShowFocusHighlight: (ring) => setState(() => _ring = ring),
              child: ZsFocusRing(
                visible: _ring,
                radius: metrics.radiusMd,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(metrics.radiusMd)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 2,
                      children: <Widget>[
                        Row(
                          spacing: 6,
                          children: <Widget>[
                            Flexible(child: widget.name),
                            widget.tag,
                          ],
                        ),
                        ?detail,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
