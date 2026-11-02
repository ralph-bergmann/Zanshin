// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:material_ui/material_ui.dart' show Material, MaterialType, TextField;
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart'
    show GraphSettings, RevsetConfiguration, revsetDefaultAll, revsetDefaultLog;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../shell/calm_controller.dart';
import '../shell/shell_scope.dart';
import 'graph_card.dart' show graphRelativeDate;
import 'graph_ports.dart' show jjLogCommand;
import 'graph_search_controller.dart';
import 'graph_search_index.dart';
import 'graph_search_model.dart';
import 'graph_view_model.dart';
import 'revset_configs/revset_config_expression.dart';

// The graph search field (Story 10.21 item 2; DS components/search/search.css; design/graph-search.jsx:470-491): the
// well [pill ▾ | input | ✕ or ⌘F], and one field-attached list below it — the menu or the suggestions — whose keyboard
// row the field drives while focus stays in the field.

/// At or below this window width the input is 250 wide (`is-medium`, DS search.css:35).
const double graphSearchMediumWidth = 1180;

/// At or below this window width the pill drops its label (`is-compact`, DS search.css:38).
const double graphSearchCompactWidth = 1100;

/// At or below this window width the input is 170 wide, the `⌘F` hint goes and the placeholders shorten
/// (`is-narrow`, DS search.css:36).
const double graphSearchNarrowWidth = 980;

/// The input's width at the window width [window].
double graphSearchInputWidth(double window) => window > graphSearchMediumWidth
    ? 320
    : window > graphSearchNarrowWidth
    ? 250
    : 170;

/// The built-in `jj log` variant's name.
const _jjLog = 'jj log'; // l10n-ignore: jj command

/// jj's builtin `revsets.log` (cli/src/config/revsets.toml @ v0.46.0).
const _builtinLog = 'builtin_log()'; // l10n-ignore: jj revset

enum _Popup { none, menu, suggestions }

/// What a menu row is (item 3): a jj log variant, a scope, or Edit Configurations….
enum _MenuKind { variant, change, bookmark, author, file, description, edit }

/// A menu row; a variant row names its variant (`log`, `all` or a configuration id, Story 10.22).
@immutable
class _MenuRow {
  const _MenuRow(this.kind) : variant = null;

  const _MenuRow.variant(String this.variant) : kind = _MenuKind.variant;

  static const scopes = <_MenuRow>[
    _MenuRow(_MenuKind.change),
    _MenuRow(_MenuKind.bookmark),
    _MenuRow(_MenuKind.author),
    _MenuRow(_MenuKind.file),
    _MenuRow(_MenuKind.description),
  ];

  static const edit = _MenuRow(_MenuKind.edit);

  final _MenuKind kind;
  final String? variant;

  /// The row's identifier suffix: `log`, `all`, `config-<id>` or the kind's name.
  String get name => switch (variant) {
    revsetDefaultLog || revsetDefaultAll => variant!,
    final String id => 'config-$id',
    null => kind.name,
  };

  @override
  bool operator ==(Object other) => other is _MenuRow && other.kind == kind && other.variant == variant;

  @override
  int get hashCode => Object.hash(kind, variant);
}

/// The graph search field (Story 10.21). It shows what [search] shows the graph — the default search (empty, calm
/// pill, placeholder and `⌘F`), a typed filter (the scope's icon and label, the value, a ✕ back to the default search)
/// or another jj log variant (`$` and the name) — and opens one field-attached list: the menu (the pill) or the
/// suggestions (typing, and Recent on an empty field). While either is open it holds the shell's calm.
///
/// The menu lists the default search first, tagged Default, then the other variants — `jj log`, `all()` and the jj log
/// configurations in order (Story 10.22). [onEditConfigurations] opens the configurations window; null disables the
/// row.
class GraphSearchField extends StatefulWidget {
  /// The field of [search].
  const GraphSearchField({required this.search, this.onEditConfigurations, super.key});

  /// The search.
  final GraphSearchController search;

  /// "Edit Configurations…"; null disables the row.
  final VoidCallback? onEditConfigurations;

  /// The lists' gap below the field (`top:calc(100% + 12px)`, DS search.css:42).
  static const double popoverGap = 12;

  /// The menu's width (DS search.css:84).
  static const double menuWidth = 420;

  /// The suggestions' least width (DS search.css:43).
  static const double suggestionsWidth = 540;

  @override
  State<GraphSearchField> createState() => _GraphSearchFieldState();
}

class _GraphSearchFieldState extends State<GraphSearchField> {
  final _text = ZsTextEditingController();
  final _focus = FocusNode(debugLabel: 'Graph search');
  final _list = ZsFieldListController();
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _scroll = ScrollController();
  final _tapGroup = Object();
  final GlobalKey<State<StatefulWidget>> _fieldKey = GlobalKey();
  var _rowKeys = <GlobalKey>[];

  GraphSearchScope _scope = GraphSearchScope.any;
  _Popup _popup = _Popup.none;
  CalmHold? _hold;
  var _quiet = false;
  var _hovered = false;
  var _pillHovered = false;
  var _pillPressed = false;

  // What the open list shows: menu rows, or suggestion rows (with the Recent entries they stand for).
  var _menu = const <_MenuRow>[];
  var _rows = const <GraphSearchRow>[];
  GraphSuggestions? _suggestions;

  GraphSearchController get _search => widget.search;

  GraphViewModel get _model => _search.model;

  @override
  void initState() {
    super.initState();
    _revert();
    _focus.addListener(_focusChanged);
    _search.addListener(_changed);
    _model.addListener(_changed);
    _list.addListener(_activeChanged);
    _search.fieldFocus = _focusFromShortcut;
  }

  @override
  void didUpdateWidget(GraphSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.search != widget.search) {
      oldWidget.search
        ..removeListener(_changed)
        ..fieldFocus = null;
      oldWidget.search.model.removeListener(_changed);
      _search
        ..addListener(_changed)
        ..fieldFocus = _focusFromShortcut;
      _model.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _search.removeListener(_changed);
    if (_search.fieldFocus == _focusFromShortcut) {
      _search.fieldFocus = null;
    }
    _model.removeListener(_changed);
    _hold?.release();
    _focus.dispose();
    _text.dispose();
    _list.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ── State ─────────────────────────────────────────────────────────────────

  GraphShownView get _view => _search.view;

  /// The scope and value the shown view puts in the field.
  (GraphSearchScope, String) get _shown => switch (_view) {
    GraphFilterView(:final GraphFilter filter) => (filter.scope, filter.value),
    _ => (GraphSearchScope.any, ''),
  };

  void _revert() {
    final (GraphSearchScope scope, String value) = _shown;
    _scope = scope;
    _setText(value);
  }

  void _setText(String text) => _text.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );

  void _changed() {
    if (!mounted) {
      return;
    }
    if (!_focus.hasFocus && _popup == _Popup.none) {
      _revert();
    }
    // An operation landed while a list is open: the candidates of the new one (prepare guards per operation).
    if (_popup != _Popup.none) {
      unawaited(_search.prepare());
    }
    _refresh();
  }

  void _focusChanged() {
    if (_focus.hasFocus) {
      unawaited(_search.prepare());
      if (!_quiet) {
        _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length);
        _open(_Popup.suggestions);
      }
      _quiet = false;
      setState(() {});
      return;
    }
    _quiet = false;
    _close();
    _revert();
    setState(() {});
  }

  /// Focuses the field without selecting its text or opening the suggestions; the focus change arrives later, so
  /// [_focusChanged] consumes the flag.
  void _focusQuietly() {
    if (!_focus.hasFocus) {
      _quiet = true;
      _focus.requestFocus();
    }
  }

  bool _focusFromShortcut() {
    if (_model.stale != null || !mounted) {
      return false;
    }
    // Already focused, the focus listener does not fire: open the suggestions here.
    final bool focused = _focus.hasFocus;
    _focus.requestFocus();
    _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length);
    if (focused && _popup == _Popup.none) {
      _open(_Popup.suggestions);
    }
    return true;
  }

  void _open(_Popup popup) {
    final opening = _popup == _Popup.none;
    _popup = popup;
    if (opening) {
      _portal.show();
    }
    _refresh(reset: true);
  }

  void _close() {
    if (_popup == _Popup.none) {
      return;
    }
    _popup = _Popup.none;
    _hold?.release();
    _hold = null;
    _list.detach();
    _portal.hide();
    if (mounted) {
      setState(() {});
    }
  }

  void _leave() {
    _close();
    _focus.unfocus();
  }

  /// Recomputes the open list; [reset] puts the keyboard row on its start (the menu's current row, the first
  /// suggestion).
  void _refresh({bool reset = false}) {
    if (!mounted) {
      return;
    }
    final int keep = _list.active;
    var start = -1;
    var count = 0;
    bool Function(int)? enabled;
    switch (_popup) {
      case _Popup.none:
        _menu = const <_MenuRow>[];
        _rows = const <GraphSearchRow>[];
        _suggestions = null;
      case _Popup.menu:
        _menu = <_MenuRow>[for (final String v in _variants) _MenuRow.variant(v), ..._MenuRow.scopes, _MenuRow.edit];
        count = _menu.length;
        start = _menu.indexOf(_currentMenuRow);
        enabled = (i) => _menu[i] != _MenuRow.edit || widget.onEditConfigurations != null;
      case _Popup.suggestions:
        final String q = _text.text.trim();
        if (q.isEmpty) {
          _suggestions = null;
          final GraphSearchIndex index = _search.index(_scope, '');
          _rows = <GraphSearchRow>[for (final GraphRecent r in _search.recentFor(_scope)) _recentRow(index, r)];
        } else {
          _search.lookup(_scope, q);
          final GraphSearchFinds? finds = _search.finds(_scope, q);
          _suggestions = suggestGraphSearch(_search.index(_scope, q), _scope, q, refusal: finds?.refusal);
          _rows = _suggestions!.rows;
        }
        count = _rows.length;
        enabled = (i) => _rows[i] is! GraphRefusalRow;
        start = _rows.indexWhere((r) => r is! GraphRefusalRow);
        _wantCounts(-1);
    }
    if (_popup != _Popup.none) {
      _list.attach(
        count: count,
        enabled: enabled,
        onActivate: _activate,
        active: reset || keep < 0 || keep >= count ? (count == 0 ? -1 : start) : keep,
      );
      if (_rowKeys.length != count) {
        _rowKeys = <GlobalKey>[for (var i = 0; i < count; i++) GlobalKey()];
      }
    }
    // The calm is held while a list shows (I3) — an empty Recent shows none.
    final bool visible =
        _popup == _Popup.menu ||
        (_popup == _Popup.suggestions && (_suggestions != null || _rows.isNotEmpty || _model.revsetError != null));
    if (visible && _hold == null) {
      _hold = ShellScope.maybeOf(context)?.openSurface();
    } else if (!visible) {
      _hold?.release();
      _hold = null;
    }
    setState(() {});
  }

  /// A Recent row; a bookmark go-to goes where the bookmark points now, else to the change it was recorded on.
  static GraphSearchRow _recentRow(GraphSearchIndex index, GraphRecent recent) => switch (recent) {
    GraphRecentGoTo(:final changeId, :final String bookmark) => () {
      final String key = index.bookmarks.where((b) => b.name == bookmark).firstOrNull?.key ?? changeId;
      return GraphBookmarkRow(bookmark, key, change: index.change(key), score: 0);
    }(),
    GraphRecentGoTo(:final changeId) => GraphChangeRow(
      index.change(changeId) ?? GraphSearchChange(key: changeId, commitId: '', prefixLength: 2, inView: false),
      GraphChangeMatch.recent,
      score: 0,
    ),
    GraphRecentFilter(:final filter) => GraphFilterRow(filter, GraphFilterRowKind.recent, filter.value, score: 0),
  };

  /// Counts the filter rows: author and description rows always, a File row only as the keyboard row (I2: one
  /// `files()` count diffs every commit).
  void _wantCounts(int active) {
    _search.wantCounts(<String>[
      for (var i = 0; i < _rows.length; i++)
        if (_rows[i] case GraphFilterRow(:final filter))
          if (filter.scope != GraphSearchScope.file || i == active) filter.revset,
    ]);
  }

  void _activeChanged() {
    final int active = _list.active;
    if (_popup == _Popup.suggestions && active >= 0 && active < _rows.length) {
      if (_rows[active] case GraphFilterRow(:final filter) when filter.scope == GraphSearchScope.file) {
        _search.wantCounts(<String>[filter.revset]);
      }
    }
    if (active >= 0 && active < _rowKeys.length) {
      final BuildContext? row = _rowKeys[active].currentContext;
      if (row != null) {
        Scrollable.ensureVisible(row, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
        Scrollable.ensureVisible(row, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
      }
    }
    if (mounted) {
      setState(() {});
    }
  }

  _MenuRow get _currentMenuRow => switch (_view) {
    GraphFilterView(:final GraphFilter filter) => _MenuRow(switch (filter.scope) {
      GraphSearchScope.file => _MenuKind.file,
      GraphSearchScope.description => _MenuKind.description,
      _ => _MenuKind.author,
    }),
    _ => _MenuRow.variant(_currentVariant!),
  };

  /// The jj log variants in menu order (Story 10.22): the default search first, then `jj log`, `all()` and the
  /// configurations.
  List<String> get _variants {
    final GraphSettings settings = _search.configurations;
    final String home = settings.effectiveRevsetDefault;
    return <String>[
      home,
      for (final String v in <String>[
        revsetDefaultLog,
        revsetDefaultAll,
        for (final RevsetConfiguration c in settings.revsetConfigs) c.id,
      ])
        if (v != home) v,
    ];
  }

  /// The variant the shown view is; null for a filter.
  String? get _currentVariant => switch (_view) {
    GraphDefaultSearch() => _search.defaultSearch,
    GraphLogView() => revsetDefaultLog,
    GraphAllView() => revsetDefaultAll,
    // The controller falls a vanished configuration back to the default search.
    GraphConfigView(:final String id) => _config(id) == null ? _search.defaultSearch : id,
    GraphFilterView() => null,
  };

  RevsetConfiguration? _config(String id) => _search.configurations.revsetConfigs.where((c) => c.id == id).firstOrNull;

  /// [variant]'s name: `jj log`, `all()` or the configuration's name ("Unnamed" when empty).
  String _variantName(AppLocalizations s, String variant) => switch (variant) {
    revsetDefaultLog => _jjLog,
    revsetDefaultAll => GraphAllView.expression,
    _ => switch (_config(variant)?.name) {
      final String name when name.isNotEmpty => name,
      _ => s.revsetConfigsUnnamed,
    },
  };

  /// The configuration [id]'s expression.
  String _configText(String id) => switch (_config(id)) {
    final RevsetConfiguration c => revsetConfigText(c),
    null => GraphAllView.expression,
  };

  /// The revset the variant [v] runs (the effective `revsets.log` for `jj log`).
  String _variantRevset(String v) => switch (v) {
    revsetDefaultLog => _model.logDefaults?.log ?? _builtinLog,
    revsetDefaultAll => GraphAllView.expression,
    _ => _configText(v),
  };

  /// Whether the field shows the default search: the default, or the variant the default is.
  bool get _atDefault => _view is GraphDefaultSearch || _currentVariant == _search.defaultSearch;

  // ── Actions ───────────────────────────────────────────────────────────────

  void _activate(int index) {
    if (_popup == _Popup.menu) {
      _pickMenu(_menu[index]);
    } else if (index < _rows.length) {
      _pick(_rows[index]);
    }
  }

  void _pickMenu(_MenuRow row) {
    switch (row.kind) {
      case _MenuKind.variant:
        _scope = GraphSearchScope.any;
        _setText('');
        switch (row.variant!) {
          case final String v when v == _search.defaultSearch:
            _search.showDefault();
          case revsetDefaultLog:
            _search.showLog();
          case revsetDefaultAll:
            _search.showAll();
          case final String id:
            _search.showConfig(id);
        }
        _leave();
      case _MenuKind.change:
        _pickScope(GraphSearchScope.change);
      case _MenuKind.bookmark:
        _pickScope(GraphSearchScope.bookmark);
      case _MenuKind.author:
        _pickScope(GraphSearchScope.author);
      case _MenuKind.file:
        _pickScope(GraphSearchScope.file);
      case _MenuKind.description:
        _pickScope(GraphSearchScope.description);
      case _MenuKind.edit:
        _leave();
        widget.onEditConfigurations?.call();
    }
  }

  /// A scope keeps what was being typed; the shown filter's value makes room for a new one.
  void _pickScope(GraphSearchScope scope) {
    final draft = _text.text != _shown.$2;
    _scope = scope;
    if (!draft) {
      _setText('');
    }
    _focusQuietly();
    _open(_Popup.suggestions);
  }

  void _pick(GraphSearchRow row) {
    switch (row) {
      case GraphMoreRow(:final scope):
        _scope = scope;
        _refresh(reset: true);
      case GraphChangeRow(:final change):
        _goTo(change.key, commitId: change.commitId);
      case GraphBookmarkRow(:final name, :final key, :final change):
        _goTo(key, bookmark: name, commitId: change?.commitId);
      case GraphFilterRow(:final filter):
        _search.apply(filter);
        _scope = filter.scope;
        _setText(filter.value);
        _leave();
      case GraphRefusalRow():
        break;
    }
  }

  void _goTo(String key, {String? bookmark, String? commitId}) {
    _search.goTo(key, bookmark: bookmark, commitId: commitId);
    _close();
    _revert();
    _focus.unfocus();
  }

  void _clear() {
    _scope = GraphSearchScope.any;
    _setText('');
    if (!_atDefault) {
      _search.showDefault();
    }
    if (_focus.hasFocus) {
      _open(_Popup.suggestions);
    } else {
      _close();
    }
  }

  void _togglePill() {
    if (_popup == _Popup.menu) {
      _close();
      _revert();
      return;
    }
    _focusQuietly();
    _open(_Popup.menu);
  }

  void _onChanged(String value) {
    if (parseGraphSearchPrefix(value) case (:final scope, :final rest)) {
      _scope = scope;
      _setText(rest);
    }
    _open(_Popup.suggestions);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // An input method's composition owns its keys (Enter commits the candidate).
    if (event is KeyUpEvent || (_text.value.isComposingRangeValid && !_text.value.composing.isCollapsed)) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      if (_popup == _Popup.none) {
        _open(_Popup.suggestions);
      } else if (key == LogicalKeyboardKey.arrowDown) {
        _list.next();
      } else {
        _list.previous();
      }
      return KeyEventResult.handled;
    }
    if (_popup == _Popup.menu && (key == LogicalKeyboardKey.home || key == LogicalKeyboardKey.end)) {
      key == LogicalKeyboardKey.home ? _list.first() : _list.last();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (event is! KeyDownEvent) {
        // A held Enter runs its row once.
        return KeyEventResult.handled;
      }
      if (_popup != _Popup.none) {
        _list.activate();
      } else if (_text.text.trim().isNotEmpty) {
        _open(_Popup.suggestions);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (event is! KeyDownEvent) {
        return KeyEventResult.handled;
      }
      if (_popup == _Popup.menu) {
        _close();
        _revert();
        setState(() {});
      } else if (_popup != _Popup.none) {
        _close();
      } else {
        _revert();
        _focus.unfocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace && _text.text.isEmpty && _scope != GraphSearchScope.any) {
      _scope = GraphSearchScope.any;
      _refresh(reset: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final AppLocalizations s = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final appearance = ZsAppearance.of(context);
    final double window = MediaQuery.sizeOf(context).width;
    final bool compact = window <= graphSearchCompactWidth;
    final bool narrow = window <= graphSearchNarrowWidth;
    final bool inactive = appearance.inactive;
    final bool focused = _focus.hasFocus && !inactive;
    final bool atDefault = _atDefault;
    final String? variant = _currentVariant;
    final bool showView = !_focus.hasFocus && variant != null && !atDefault;
    final GraphStale? stale = _model.stale;
    final bool builtIn = variant == revsetDefaultLog || variant == revsetDefaultAll;
    final bool mono = (showView && builtIn) || _scope == GraphSearchScope.change || _scope == GraphSearchScope.file;
    final String placeholder = showView
        ? _variantName(s, variant)
        : narrow
        ? s.graphSearchScopePlaceholderShort(_scope.name)
        : s.graphSearchScopePlaceholder(_scope.name);
    final TextStyle inputStyle =
        (mono ? ZsType.id.copyWith(fontSize: ZsType.fsControl) : ZsType.body.copyWith(fontSize: ZsType.fsBase))
            .copyWith(height: ZsType.lhSnug, color: colors.text);
    final TextStyle valueStyle = !atDefault && !_focus.hasFocus ? _weight(inputStyle, 500) : inputStyle;
    final bool query = _text.text.isNotEmpty;

    final Widget pill = _pill(
      context,
      s,
      colors,
      metrics,
      showView: showView,
      compact: compact,
    );
    final Widget input = SizedBox(
      width: graphSearchInputWidth(window),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(7, 0, 6, 0),
        child: Stack(
          alignment: AlignmentDirectional.centerStart,
          children: <Widget>[
            if (!query)
              ExcludeSemantics(
                child: Text(
                  placeholder,
                  style: showView
                      ? _weight(inputStyle, 500)
                      : inputStyle.copyWith(color: ZsTextRung.of(colors, hovered: _hovered && !inactive).dim),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            Material(
              type: MaterialType.transparency,
              child: TextField(
                controller: _text,
                focusNode: _focus,
                groupId: _tapGroup,
                decoration: null,
                style: valueStyle,
                cursorColor: inactive ? const Color(0x00000000) : colors.accentLine,
                onChanged: _onChanged,
              ),
            ),
          ],
        ),
      ),
    );
    final Widget end = query || !atDefault
        ? _ClearButton(
            tooltip: atDefault
                ? s.graphSearchClear
                : s.graphSearchBackToDefault(_variantName(s, _search.defaultSearch)),
            onPressed: _clear,
          )
        : (!_focus.hasFocus && !narrow
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(2, 0, 6, 0),
                  child: ExcludeSemantics(
                    child: Text(
                      '⌘F', // l10n-ignore: a key shortcut
                      style: ZsType.body.copyWith(fontSize: ZsType.fsMd, height: 1, color: colors.textFaint),
                    ),
                  ),
                )
              : const SizedBox(width: 22));

    Widget well = CustomPaint(
      key: _fieldKey,
      painter: _WellPainter(
        fill: colors.flHover,
        border: focused ? colors.accentLine : const Color(0x00000000),
        halo: focused ? colors.accentRing : const Color(0x00000000),
        radius: metrics.radiusCard,
        haloWidth: metrics.fieldHalo,
      ),
      child: SizedBox(
        height: metrics.controlLg,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Row(mainAxisSize: MainAxisSize.min, spacing: 2, children: <Widget>[pill, input, end]),
        ),
      ),
    );
    well = MouseRegion(
      cursor: SystemMouseCursors.text,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        onKeyEvent: _onKey,
        child: Semantics(
          container: true,
          identifier: 'graph-search',
          textField: true,
          label: s.graphSearchLabel,
          expanded: _popup != _Popup.none,
          // The keyboard row, read as the field's hint: SemanticsRole.comboBox has no active descendant here.
          hint: _activeLabel(s),
          child: well,
        ),
      ),
    );
    well = TapRegion(
      groupId: _tapGroup,
      onTapOutside: (_) {
        if (_popup != _Popup.none) {
          _close();
          if (!_focus.hasFocus) {
            _revert();
          }
        }
      },
      child: CompositedTransformTarget(link: _link, child: well),
    );
    if (stale != null) {
      final String reason = stale.message ?? stale.command;
      well = ZsTooltip(
        message: reason,
        child: Semantics(
          hint: reason,
          child: IgnorePointer(
            child: ExcludeFocus(
              child: Opacity(opacity: metrics.disabledOpacity, child: well),
            ),
          ),
        ),
      );
    }
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _overlay,
      child: well,
    );
  }

  Widget _pill(
    BuildContext context,
    AppLocalizations s,
    ZsColors colors,
    ZsMetrics metrics, {
    required bool showView,
    required bool compact,
  }) {
    final open = _popup == _Popup.menu;
    final bool any = showView || _scope == GraphSearchScope.any;
    // An inactive window paints no hover (decision 16.42 (i)). No tint at any view (Story 10.30).
    final bool lit = (_pillHovered && !ZsAppearance.of(context).inactive) || open;
    final Color fill = _pillPressed ? colors.flPress : (lit ? colors.flOn : const Color(0x00000000));
    final Color text = lit || _pillPressed ? colors.text : (any ? colors.textDim : colors.textMuted);
    final Color chevron = colors.textFaint;
    final String? variant = _currentVariant;
    final String tooltip = _focus.hasFocus || variant == null
        ? s.graphSearchSearchIn(s.graphSearchScope(_scope.name))
        : _atDefault
        ? s.graphSearchDefault(_variantName(s, variant))
        : s.graphSearchShowing(_variantName(s, variant));
    final TextStyle label = _weight(ZsType.control, 500).copyWith(color: text, height: 1);
    return ZsTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        identifier: 'graph-search-pill',
        label: s.graphSearchMenu,
        expanded: open,
        onTap: _togglePill,
        child: MouseRegion(
          cursor: SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _pillHovered = true),
          onExit: (_) => setState(() => _pillHovered = false),
          child: GestureDetector(
            excludeFromSemantics: true,
            onTapDown: (_) => setState(() => _pillPressed = true),
            onTapUp: (_) => setState(() => _pillPressed = false),
            onTapCancel: () => setState(() => _pillPressed = false),
            onTap: _togglePill,
            child: DecoratedBox(
              decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(metrics.radiusChip)),
              child: SizedBox(
                height: 28,
                child: Padding(
                  padding: any || compact
                      ? const EdgeInsets.fromLTRB(7, 0, 5, 0)
                      : const EdgeInsets.fromLTRB(8, 0, 7, 0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: any || compact ? 3 : 6,
                    children: <Widget>[
                      if (showView)
                        _Dollar(color: text)
                      else
                        ZanshinIcon(_scopeIcon(_scope), size: ZsIconSize.md, color: text),
                      if (!showView && !any && !compact) Text(s.graphSearchScope(_scope.name), style: label),
                      ZanshinIcon(ZI.chevronDown, size: ZsIconSize.sm, color: chevron),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _overlay(BuildContext context) {
    if (_popup == _Popup.none) {
      return const SizedBox.shrink();
    }
    final Size window = MediaQuery.sizeOf(context);
    final double field = (_fieldKey.currentContext?.findRenderObject() as RenderBox?)?.size.width ?? 0;
    final menu = _popup == _Popup.menu;
    final double width = math.min(
      menu ? GraphSearchField.menuWidth : math.max(field + 10, GraphSearchField.suggestionsWidth),
      window.width - 24,
    );
    final double maxHeight = menu ? math.min(window.height * .72, 640) : math.min(window.height * .66, 560);
    final Widget? body = menu ? _menuList(context) : _suggestionList(context);
    if (body == null) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: 0,
      top: 0,
      width: width,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomLeft,
        offset: const Offset(-5, GraphSearchField.popoverGap),
        child: TapRegion(
          groupId: _tapGroup,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: ZsMenuMaterial(child: body),
          ),
        ),
      ),
    );
  }

  Widget _scrolling(Widget list, {required String label, required String identifier}) => Flexible(
    child: Semantics(
      container: true,
      identifier: identifier,
      label: label,
      child: ZsScrollArea(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.all(6),
          child: list,
        ),
      ),
    ),
  );

  Widget? _menuList(BuildContext context) {
    final AppLocalizations s = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final _MenuRow current = _currentMenuRow;
    final LogDefaults? defaults = _model.logDefaults;
    // The shown variant's request failed: its row says why.
    final ZanshinFfiException? broken = current.kind == _MenuKind.variant ? _model.revsetError : null;
    final String home = _search.defaultSearch;
    Widget variantRow(String v, {required bool shown}) {
      final ZanshinFfiException? error = shown ? broken : null;
      final String? tag = v == home ? s.graphSearchDefaultTag : null;
      return switch (v) {
        revsetDefaultLog => _variantRow(
          colors,
          _jjLog,
          error != null
              ? s.graphSearchBroken(error.revsetError?.message ?? error.context ?? error.code)
              : (defaults == null || defaults.log == _builtinLog ? s.graphSearchLogDetail : defaults.log),
          mono: !(defaults == null || defaults.log == _builtinLog) && error == null,
          tag: tag,
          danger: error != null,
        ),
        revsetDefaultAll => _variantRow(
          colors,
          GraphAllView.expression,
          error != null
              ? s.graphSearchBroken(error.revsetError?.message ?? error.context ?? error.code)
              : s.graphSearchAllDetail,
          tag: tag,
          danger: error != null,
        ),
        _ => _variantRow(
          colors,
          _variantName(s, v),
          error != null
              ? s.graphSearchBroken(error.revsetError?.message ?? error.context ?? error.code)
              : _configText(v),
          nameMono: false,
          mono: error == null,
          tag: tag,
          danger: error != null,
        ),
      };
    }

    Widget row(int i) {
      final _MenuRow r = _menu[i];
      final shown = r == current;
      final String? icon = switch (r.kind) {
        _MenuKind.variant => null,
        _MenuKind.change => _scopeIcon(GraphSearchScope.change),
        _MenuKind.bookmark => _scopeIcon(GraphSearchScope.bookmark),
        _MenuKind.author => _scopeIcon(GraphSearchScope.author),
        _MenuKind.file => _scopeIcon(GraphSearchScope.file),
        _MenuKind.description => _scopeIcon(GraphSearchScope.description),
        _MenuKind.edit => ZI.settings,
      };
      final Widget child = switch (r.kind) {
        _MenuKind.variant => variantRow(r.variant!, shown: shown),
        _MenuKind.change => _scopeRow(colors, s, GraphSearchScope.change, s.graphSearchChangeDetail),
        _MenuKind.bookmark => _scopeRow(colors, s, GraphSearchScope.bookmark, s.graphSearchBookmarkDetail),
        _MenuKind.author => _scopeRow(colors, s, GraphSearchScope.author, 'author()'), // l10n-ignore: jj revset
        _MenuKind.file => _scopeRow(colors, s, GraphSearchScope.file, 'files()'), // l10n-ignore: jj revset
        _MenuKind.description => _scopeRow(
          colors,
          s,
          GraphSearchScope.description,
          'description()',
        ), // l10n-ignore: jj revset
        _MenuKind.edit => Text(s.graphSearchEditConfigurations, style: TextStyle(color: colors.textMuted)),
      };
      final bool disabled = r == _MenuRow.edit && widget.onEditConfigurations == null;
      final Widget built = ZsFieldListRow(
        key: _rowKeys.length > i ? _rowKeys[i] : null,
        active: _list.active == i,
        shown: shown,
        icon: icon,
        onPressed: disabled ? null : () => _pickMenu(r),
        identifier: 'graph-search-menu-${r.name}',
        child: child,
      );
      return switch (r.variant) {
        revsetDefaultLog => ZsTooltip(message: _jjLog, child: built),
        final String v => ZsTooltip(message: jjLogCommand(_variantRevset(v)), child: built),
        null when disabled => Opacity(opacity: ZsMetrics.of(context).disabledOpacity, child: built),
        null => built,
      };
    }

    final int scopes = _menu.indexOf(_MenuRow.scopes.first);
    final int filters = _menu.indexOf(const _MenuRow(_MenuKind.author));
    final int edit = _menu.indexOf(_MenuRow.edit);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _scrolling(
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 1,
            children: <Widget>[
              for (var i = 0; i < _menu.length; i++) ...<Widget>[
                if (i == scopes) ...<Widget>[
                  const _Separator(),
                  _Header(s.graphSearchGoTo, note: s.graphSearchGoToHint),
                ],
                if (i == filters) _Header(s.graphSearchFilterBy, note: s.graphSearchFilterByHint),
                if (i == edit) const _Separator(),
                row(i),
              ],
            ],
          ),
          label: s.graphSearchMenu,
          identifier: 'graph-search-menu',
        ),
        if (_errorFooter(context) case final Widget error) error,
      ],
    );
  }

  Widget _variantRow(
    ZsColors colors,
    String name,
    String detail, {
    bool mono = false,
    bool nameMono = true,
    String? tag,
    bool danger = false,
  }) => Row(
    spacing: 10,
    children: <Widget>[
      _Dollar(color: colors.textDim),
      Text(
        name,
        style: nameMono
            ? ZsType.id.copyWith(fontSize: ZsType.fsControl, color: colors.text)
            : _weight(ZsType.body, 500).copyWith(height: 1.2, color: colors.text),
      ),
      Expanded(
        child: Text(
          detail,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: (mono ? ZsType.id : ZsType.body.copyWith(fontSize: ZsType.fsMd)).copyWith(
            height: 1.2,
            color: danger ? colors.rem : colors.textDim,
          ),
        ),
      ),
      if (tag != null) _Tag(tag),
    ],
  );

  Widget _scopeRow(ZsColors colors, AppLocalizations s, GraphSearchScope scope, String detail) {
    final GraphShownView view = _view;
    final bool on = view is GraphFilterView && view.filter.scope == scope;
    final String? prefix = scope.prefix;
    return Row(
      spacing: 10,
      children: <Widget>[
        Text(
          s.graphSearchScope(scope.name),
          style: _weight(ZsType.body, 500).copyWith(height: 1.2, color: colors.text),
        ),
        Expanded(
          child: Text(
            on ? _shown.$2 : detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (scope.isFilter && !on ? ZsType.id : ZsType.body.copyWith(fontSize: ZsType.fsMd)).copyWith(
              height: 1.2,
              color: on ? colors.textMuted : colors.textDim,
            ),
          ),
        ),
        if (prefix != null) ZsKbd(prefix),
      ],
    );
  }

  Widget? _suggestionList(BuildContext context) {
    final AppLocalizations s = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final GraphSuggestions? suggestions = _suggestions;
    final String q = _text.text.trim();
    final Widget? error = _errorFooter(context);
    if (suggestions == null && _rows.isEmpty && error == null) {
      return null;
    }
    final children = <Widget>[];
    if (suggestions == null) {
      if (_rows.isNotEmpty) {
        children.add(
          _Header(
            _scope == GraphSearchScope.any
                ? s.graphSearchRecent
                : s.graphSearchRecentIn(s.graphSearchScopePlural(_scope.name)),
            action: s.graphSearchClear,
            onAction: _search.clearRecent,
          ),
        );
        for (var i = 0; i < _rows.length; i++) {
          children.add(_suggestionRow(context, i));
        }
      }
    } else {
      if (suggestions.fallback) {
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
            child: Text(
              s.graphSearchFallback(s.graphSearchScope(_scope.name).toLowerCase(), q),
              style: ZsType.body.copyWith(fontSize: ZsType.fsMd, height: 1.3, color: colors.textDim),
            ),
          ),
        );
      }
      var i = 0;
      for (final GraphSearchGroup g in suggestions.groups) {
        if (g.labelled &&
            (_scope == GraphSearchScope.any || suggestions.fallback || _scope == GraphSearchScope.description)) {
          children.add(_Header(s.graphSearchScopeGroup(g.scope.name)));
        }
        for (final GraphSearchRow _ in g.rows) {
          children.add(_suggestionRow(context, i++));
        }
      }
      if (suggestions.groups.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            child: Text(
              _scope == GraphSearchScope.any ? s.graphSearchNothing(q) : s.graphSearchNothingAnywhere(q),
              style: ZsType.body.copyWith(fontSize: ZsType.fsControl, height: 1.3, color: colors.textDim),
            ),
          ),
        );
      }
    }
    final int active = _list.active;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (children.isNotEmpty)
          _scrolling(
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 1,
              children: children,
            ),
            label: s.graphSearchSuggestions,
            identifier: 'graph-search-suggestions',
          ),
        if (active >= 0 && active < _rows.length) _footer(context, _rows[active]),
        ?error,
      ],
    );
  }

  Widget _suggestionRow(BuildContext context, int i) {
    final AppLocalizations s = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final GraphSearchRow row = _rows[i];
    final active = _list.active == i;
    final TextStyle base = ZsType.body.copyWith(fontSize: ZsType.fsBase, height: 1.2, color: colors.textMuted);
    final TextStyle meta = ZsType.body.copyWith(
      fontSize: ZsType.fsMd,
      height: 1.2,
      color: colors.textDim,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    String? icon;
    Widget? leading;
    Widget main;
    final metaParts = <Widget>[];
    var dim = false;
    switch (row) {
      case GraphChangeRow(:final change, :final how, :final match):
        icon = ZI.change;
        final String subject = change.subject ?? '';
        main = Row(
          spacing: 9,
          children: <Widget>[
            if (change.workingCopy)
              Text('@', style: _weight(ZsType.id, 600).copyWith(color: colors.text)), // l10n-ignore: jj symbol
            if (change.key.isNotEmpty) _changeId(colors, change.key, change.prefixLength),
            if (how == GraphChangeMatch.hash)
              Text(
                change.commitId.substring(0, math.min(8, change.commitId.length)),
                style: ZsType.id.copyWith(color: colors.textFaint),
              ),
            Flexible(
              child: subject.isEmpty && change.subject != null
                  ? Text(
                      s.inspectorNoDescription,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: base.copyWith(color: colors.textDim, fontStyle: FontStyle.italic),
                    )
                  : _highlight(
                      colors,
                      subject,
                      how == GraphChangeMatch.subject ? match : null,
                      base.copyWith(color: colors.text),
                    ),
            ),
          ],
        );
        if (!change.inView) {
          metaParts.add(_Tag(s.graphSearchNotInView));
        }
        // DS search-suggestions.card.html: "Lena · 2d".
        final int? ts = change.timestampMs;
        final String byline = <String>[
          if (change.authorName.isNotEmpty) change.authorName.split(' ').first,
          if (ts != null)
            graphRelativeDate(
              s,
              ts,
              nowMs: _model.now.value,
              utcOffsetMinutes: _model.layout?.utcOffsetMinutes ?? 0,
            ),
        ].join(' · ');
        if (byline.isNotEmpty) {
          metaParts.add(Text(byline, style: meta));
        }
      case GraphBookmarkRow(:final name, :final key, :final change, :final match):
        icon = ZI.bookmark;
        main = _highlight(colors, name, match, base.copyWith(color: colors.text));
        if (change == null || !change.inView) {
          metaParts.add(_Tag(s.graphSearchNotInView));
        }
        metaParts.add(_changeId(colors, key, change?.prefixLength ?? 2, small: true));
      case GraphFilterRow(:final filter, :final kind, :final text, :final match, :final split):
        final TextStyle path = ZsType.id.copyWith(fontSize: ZsType.fsControl, height: 1.2, color: colors.text);
        switch (kind) {
          case GraphFilterRowKind.author:
            leading = _Avatar(name: text, active: active);
            main = Row(
              spacing: 9,
              children: <Widget>[
                Flexible(child: _highlight(colors, text, match, base.copyWith(color: colors.text))),
                if (filter.isMine) _Tag('${s.graphSearchYou} · mine()'), // l10n-ignore: jj revset
              ],
            );
          case GraphFilterRowKind.contains:
            icon = ZI.user;
            main = _plain(s.graphSearchAuthorsContaining(s.graphSearchQuoted(text)), base);
          case GraphFilterRowKind.dir:
          case GraphFilterRowKind.path:
            icon = kind == GraphFilterRowKind.dir ? ZI.folder : ZI.file;
            main = _highlight(colors, text, match, path, split: split, dimColor: colors.textDim);
          case GraphFilterRowKind.glob:
            icon = ZI.file;
            main = Row(
              spacing: 9,
              children: <Widget>[
                Flexible(child: _plain(text, path)),
                const _Tag('glob'), // l10n-ignore: jj's pattern kind
              ],
            );
          case GraphFilterRowKind.description:
            icon = ZI.description;
            main = _plain(s.graphSearchDescriptionsContaining(s.graphSearchQuoted(text)), base);
          case GraphFilterRowKind.recent:
            icon = _scopeIcon(filter.scope);
            main = Row(
              spacing: 9,
              children: <Widget>[
                Text(
                  filter.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: base.copyWith(color: colors.text),
                ),
                Flexible(
                  child: Text(
                    filter.revset,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ZsType.id.copyWith(color: colors.textDim),
                  ),
                ),
              ],
            );
        }
        final RevsetCount? count = _search.countOf(filter.revset);
        if (count != null && count.error == null) {
          dim = count.n == 0;
          final String number = _number(s, count.capped ? graphSearchCountCap : count.n);
          metaParts.add(
            Text(count.capped ? s.graphSearchCountCapped(number) : s.graphSearchCount(count.n, number), style: meta),
          );
        }
      case GraphMoreRow(:final scope, :final count):
        main = Text(
          s.graphSearchMore(count, s.graphSearchScope(scope.name)),
          style: ZsType.body.copyWith(
            fontSize: ZsType.fsControl,
            height: 1.2,
            color: active ? colors.text : colors.textDim,
          ),
        );
        metaParts.add(ZanshinIcon(ZI.chevronRight, size: ZsIconSize.sm, color: colors.textDim));
      case GraphRefusalRow(:final message):
        icon = ZI.alert;
        main = _plain(message, base.copyWith(color: colors.textDim));
    }
    final Widget content = Row(
      spacing: 10,
      children: <Widget>[
        Expanded(child: main),
        if (metaParts.isNotEmpty) Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: metaParts),
      ],
    );
    final Widget built = ZsFieldListRow(
      key: _rowKeys.length > i ? _rowKeys[i] : null,
      active: active,
      icon: icon,
      leading: leading,
      onPressed: row is GraphRefusalRow ? null : () => _pick(row),
      identifier: 'graph-search-row-$i',
      child: content,
    );
    return dim ? Opacity(opacity: .5, child: built) : built;
  }

  Widget _footer(BuildContext context, GraphSearchRow row) {
    final AppLocalizations s = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final TextStyle text = ZsType.body.copyWith(fontSize: ZsType.fsMd, height: 1.2, color: colors.textDim);
    final TextStyle code = ZsType.id.copyWith(color: colors.textMuted);
    final Widget lead;
    String? key;
    switch (row) {
      case GraphMoreRow(:final scope):
        lead = _plain(s.graphSearchNarrows(s.graphSearchScopePlural(scope.name)), text);
        key = s.graphSearchKeyShow;
      case GraphChangeRow(change: GraphSearchChange(:final inView)) ||
          GraphBookmarkRow(change: GraphSearchChange(:final inView)):
        lead = _plain(inView ? s.graphSearchSelects : s.graphSearchSwitches(GraphAllView.expression), text);
        key = inView ? s.graphSearchKeySelect : s.graphSearchKeyShow;
      case GraphBookmarkRow():
        lead = _plain(s.graphSearchSwitches(GraphAllView.expression), text);
        key = s.graphSearchKeyShow;
      case GraphFilterRow(:final filter):
        lead = ZsTooltip(message: filter.command, child: _plain(filter.command, code));
        key = s.graphSearchKeyFilter;
      case GraphRefusalRow(:final message):
        lead = _plain(message, text);
    }
    return _FooterBox(
      child: Row(
        spacing: 16,
        children: <Widget>[
          Expanded(child: lead),
          if (key != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 7,
              children: <Widget>[
                Text(key, style: _weight(text, 500).copyWith(color: colors.textMuted)),
                const ZsKbd('↵'), // l10n-ignore: a key glyph
              ],
            ),
        ],
      ),
    );
  }

  /// A revset error of the last request (item 8): jj's message, and the expression with its span underlined.
  Widget? _errorFooter(BuildContext context) {
    final ZanshinFfiException? error = _model.revsetError;
    if (error == null) {
      return null;
    }
    final ZsColors colors = ZsColors.of(context);
    final String expression = _model.request?.revset ?? '';
    final RevsetSpan? span = error.revsetError?.span;
    final TextStyle code = ZsType.id.copyWith(color: colors.textMuted);
    final List<InlineSpan> parts;
    if (span == null || expression.isEmpty) {
      parts = <InlineSpan>[TextSpan(text: expression, style: code)];
    } else {
      final (:int start, :int end) = revsetSpanUtf16(expression, span);
      final int stop = math.min(expression.length, math.max(end, start + 1));
      parts = <InlineSpan>[
        TextSpan(text: expression.substring(0, start), style: code),
        TextSpan(
          text: expression.substring(start, stop),
          style: code.copyWith(
            color: colors.rem,
            decoration: TextDecoration.underline,
            decorationColor: colors.rem,
            decorationThickness: 1.5,
          ),
        ),
        TextSpan(text: expression.substring(stop), style: code),
      ];
    }
    return _FooterBox(
      child: Semantics(
        identifier: 'graph-search-error',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: <Widget>[
            Text(
              error.revsetError?.message ?? error.context ?? error.code,
              style: ZsType.body.copyWith(fontSize: ZsType.fsMd, height: 1.3, color: colors.rem),
            ),
            if (expression.isNotEmpty)
              Text.rich(TextSpan(children: parts), key: const ValueKey<String>('graph-search-error-span')),
          ],
        ),
      ),
    );
  }

  static Widget _plain(String text, TextStyle style) =>
      Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: style);

  /// [text] with the input's [match] underlined in the accent line and the text before [split] dimmed.
  static Widget _highlight(
    ZsColors colors,
    String text,
    (int, int)? match,
    TextStyle style, {
    int split = 0,
    Color? dimColor,
  }) {
    final List<int> cuts = <int>{
      0,
      split,
      if (match != null) ...<int>[match.$1, match.$2],
      text.length,
    }.toList()..sort();
    final spans = <TextSpan>[];
    for (var i = 0; i + 1 < cuts.length; i++) {
      final int a = cuts[i];
      final int b = cuts[i + 1];
      if (a == b || a < 0 || b > text.length) {
        continue;
      }
      var part = style;
      if (a < split) {
        part = part.copyWith(color: dimColor);
      }
      if (match != null && a >= match.$1 && b <= match.$2) {
        part = _weight(part, 600).copyWith(
          color: colors.text,
          decoration: TextDecoration.underline,
          decorationColor: colors.accentLine,
          decorationThickness: 1.5,
        );
      }
      spans.add(TextSpan(text: text.substring(a, b), style: part));
    }
    return Text.rich(TextSpan(children: spans), maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false);
  }

  /// A change id with jj's shortest unique prefix bold, max(prefix, 8) characters, one text (decision 16.35).
  static Widget _changeId(ZsColors colors, String id, int prefix, {bool small = false}) {
    final int shown = math.min(id.length, math.max(prefix, 8));
    final int bold = math.min(prefix, shown);
    final TextStyle style = (small ? ZsType.id : ZsType.id.copyWith(fontSize: ZsType.fsMd)).copyWith(
      color: colors.textMuted,
    );
    return Text.rich(
      TextSpan(
        children: <TextSpan>[
          TextSpan(
            text: id.substring(0, bold),
            style: _weight(style, 600).copyWith(color: colors.text),
          ),
          TextSpan(text: id.substring(bold, shown), style: style),
        ],
      ),
      maxLines: 1,
      softWrap: false,
    );
  }

  static String _number(AppLocalizations s, int n) => NumberFormat.decimalPattern(s.localeName).format(n);

  /// What VoiceOver reads for the keyboard row; null without one.
  String? _activeLabel(AppLocalizations s) {
    final int active = _list.active;
    if (_popup == _Popup.menu && active >= 0 && active < _menu.length) {
      final _MenuRow row = _menu[active];
      return switch (row.kind) {
        _MenuKind.variant => _variantName(s, row.variant!),
        _MenuKind.change => s.graphSearchScope(GraphSearchScope.change.name),
        _MenuKind.bookmark => s.graphSearchScope(GraphSearchScope.bookmark.name),
        _MenuKind.author => s.graphSearchScope(GraphSearchScope.author.name),
        _MenuKind.file => s.graphSearchScope(GraphSearchScope.file.name),
        _MenuKind.description => s.graphSearchScope(GraphSearchScope.description.name),
        _MenuKind.edit => s.graphSearchEditConfigurations,
      };
    }
    if (_popup == _Popup.suggestions && active >= 0 && active < _rows.length) {
      return switch (_rows[active]) {
        GraphChangeRow(:final GraphSearchChange change) => '${change.key} ${change.subject ?? ''}'.trim(),
        GraphBookmarkRow(:final String name) => name,
        GraphFilterRow(:final GraphFilter filter) => filter.command,
        GraphMoreRow(:final GraphSearchScope scope, :final int count) => s.graphSearchMore(
          count,
          s.graphSearchScope(scope.name),
        ),
        GraphRefusalRow(:final String message) => message,
      };
    }
    return null;
  }
}

String _scopeIcon(GraphSearchScope scope) => switch (scope) {
  GraphSearchScope.any => ZI.search,
  GraphSearchScope.change => ZI.change,
  GraphSearchScope.bookmark => ZI.bookmark,
  GraphSearchScope.author => ZI.user,
  GraphSearchScope.file => ZI.file,
  GraphSearchScope.description => ZI.description,
};

TextStyle _weight(TextStyle style, int weight) => style.copyWith(
  fontWeight: FontWeight.values[(weight ~/ 100) - 1],
  fontVariations: <FontVariation>[FontVariation.weight(weight.toDouble())],
);

/// `$`: a variant that draws the graph (DS search.css:22).
class _Dollar extends StatelessWidget {
  const _Dollar({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: 14,
      height: 14,
      child: Center(
        child: Text(
          r'$', // l10n-ignore: a symbol
          style: _weight(ZsType.id, 600).copyWith(fontSize: ZsType.fsBase, height: 1, color: color),
        ),
      ),
    ),
  );
}

/// An author's initial in an 18 px circle (DS search.css:73-74, SearchPopover.jsx `SearchAvatar`): `--fs-xs` 600 in
/// `--text-muted` on `--fl-on`; on the keyboard row `--accent-text`, transparent, an inset 1 px `--accent-ring`.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.active});

  final String name;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return ExcludeSemantics(
      child: Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? null : colors.flOn,
          border: active ? Border.all(color: colors.accentRing) : null,
        ),
        child: Text(
          name.trim().characters.take(1).toString(),
          style: _weight(
            ZsType.body,
            600,
          ).copyWith(fontSize: ZsType.fsXs, height: 1, color: active ? colors.accentText : colors.textMuted),
        ),
      ),
    );
  }
}

/// A small tag (DS search.css:72).
class _Tag extends StatelessWidget {
  const _Tag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.flHover,
        borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusTag),
      ),
      child: SizedBox(
        height: 18,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: ZsType.body.copyWith(fontSize: ZsType.fsSm, height: 1, color: colors.textDim),
            ),
          ),
        ),
      ),
    );
  }
}

/// A list heading in caps, with an optional note or action (DS search.css:46-50).
class _Header extends StatelessWidget {
  const _Header(this.label, {this.note, this.action, this.onAction});

  final String label;
  final String? note;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final String? action = this.action;
    final String? note = this.note;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        spacing: 12,
        children: <Widget>[
          Expanded(
            child: Text(ZsType.caps(label), style: ZsType.capsLabel.copyWith(color: colors.textDim)),
          ),
          if (note != null)
            Text(
              note,
              style: ZsType.body.copyWith(fontSize: ZsType.fsId, height: 1.2, color: colors.textFaint),
            ),
          if (action != null)
            // A click keeps focus in the field; no Tab stop of its own (Claude's proposal).
            Semantics(
              button: true,
              identifier: 'graph-search-clear-recent',
              onTap: onAction,
              child: GestureDetector(
                excludeFromSemantics: true,
                onTap: onAction,
                child: Text(
                  action,
                  style: _weight(ZsType.body, 500).copyWith(fontSize: ZsType.fsId, height: 1.2, color: colors.textDim),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Separator extends StatelessWidget {
  const _Separator();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
    child: SizedBox(height: 1, child: ColoredBox(color: ZsColors.of(context).flBorder)),
  );
}

/// The footer band under a list (DS search.css:78).
class _FooterBox extends StatelessWidget {
  const _FooterBox({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: ZsColors.of(context).flBorder)),
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 38),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
        child: Align(alignment: AlignmentDirectional.centerStart, child: child),
      ),
    ),
  );
}

/// The field's ✕ (DS search.css:30-32): 22 px, radius `--radius-sm`. It takes no focus, so a click keeps the field's.
class _ClearButton extends StatefulWidget {
  const _ClearButton({required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<_ClearButton> createState() => _ClearButtonState();
}

class _ClearButtonState extends State<_ClearButton> {
  var _hovered = false;
  var _pressed = false;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final bool lit = _hovered || _pressed;
    return ZsTooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: widget.tooltip,
        identifier: 'graph-search-clear',
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
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _pressed ? colors.flPress : (_hovered ? colors.flOn : const Color(0x00000000)),
                borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusSm),
              ),
              child: SizedBox.square(
                dimension: 22,
                child: Center(
                  child: ZanshinIcon(ZI.close, size: ZsIconSize.xs, color: lit ? colors.text : colors.textDim),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The well (DS search.css:7-8): `--fl-hover`, a 1 px border and the focus halo outside it.
class _WellPainter extends CustomPainter {
  _WellPainter({
    required this.fill,
    required this.border,
    required this.halo,
    required this.radius,
    required this.haloWidth,
  });

  final Color fill;
  final Color border;
  final Color halo;
  final double radius;
  final double haloWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    if (halo.a > 0) {
      canvas.drawDRRect(rrect.inflate(haloWidth), rrect, Paint()..color = halo);
    }
    canvas.drawRRect(rrect, Paint()..color = fill);
    if (border.a > 0) {
      canvas.drawDRRect(rrect, rrect.deflate(1), Paint()..color = border);
    }
  }

  @override
  bool shouldRepaint(_WellPainter old) =>
      old.fill != fill ||
      old.border != border ||
      old.halo != halo ||
      old.radius != radius ||
      old.haloWidth != haloWidth;
}

/// `/` outside a text field focuses the graph search with its text selected (Story 10.21 item 2) — not while a modal
/// route covers [child]. ⌘F is the menu bar's Edit › Find alone (Story 10.12): it focuses the search through
/// `GraphMenuBinding.focusSearch`. Put it above the project window's content; key events reach it along the focus
/// chain.
class GraphSearchShortcuts extends StatelessWidget {
  /// The shortcuts of [search] over [child].
  const GraphSearchShortcuts({required this.search, required this.child, super.key});

  /// The search; null (no project open) ignores every key, so the window keeps its tree when one opens.
  final GraphSearchController? search;

  /// The window's content.
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    includeSemantics: false,
    onKeyEvent: (node, event) {
      if (event is! KeyDownEvent || ModalRoute.of(context)?.isCurrent == false) {
        return KeyEventResult.ignored;
      }
      final HardwareKeyboard keys = HardwareKeyboard.instance;
      final bool slash =
          (event.character == '/' || event.logicalKey == LogicalKeyboardKey.slash) &&
          !keys.isMetaPressed &&
          !keys.isControlPressed &&
          !keys.isAltPressed &&
          !_inTextField();
      if (slash && (search?.focusField() ?? false)) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: child,
  );

  static bool _inTextField() =>
      FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() != null;
}
