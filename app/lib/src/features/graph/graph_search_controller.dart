// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';

import 'graph_layout.dart';
import 'graph_ports.dart';
import 'graph_search_index.dart';
import 'graph_search_model.dart';
import 'graph_search_store.dart';
import 'graph_view_model.dart';

final _log = Logger('zanshin.graph.search');

/// The cap of a suggestion's count (Story 10.21 item 4): a capped count reads "10,000+".
const graphSearchCountCap = 10000;

/// How many changes a description lookup beyond the view asks for.
const _foundLimit = 8;

/// What a `findChanges` lookup brought for one input: the changes, and jj's refusal of the input as a symbol.
typedef GraphSearchFinds = ({List<GraphSearchChange> found, String? refusal});

/// The graph search (Story 10.21): it owns what the graph shows ([view], persisted per repository through its
/// [GraphSearchStore]) and drives [model] — `setRevset` for the default search, `all()` and a filter, `goTo` for a
/// visible go-to target, `goToHidden` for one beyond the view — and keeps Recent (10 stored, 6 shown per scope).
///
/// It also feeds the suggestions: `bookmarks()`, @'s paths and `user.email`, read once per operation ([prepare]);
/// `findChanges` lookups and op-pinned counts, cached per (operation, expression) and batched per [pause] in typing.
class GraphSearchController extends ChangeNotifier {
  /// The search of [model] over [_source], its state in [_store].
  GraphSearchController({
    required this.model,
    required this._source,
    required GraphSearchStore store,
    this.pause = const Duration(milliseconds: 150),
  }) : _store = store,
       _view = store.loadView(),
       _recent = store.loadRecent();

  /// The graph's view model.
  final GraphViewModel model;

  final GraphSearchSource _source;
  final GraphSearchStore _store;

  /// The pause in typing a batch of counts and lookups waits for.
  final Duration pause;

  GraphShownView _view;
  List<GraphRecent> _recent;
  var _disposed = false;

  /// What the graph shows.
  GraphShownView get view => _view;

  /// The revset [view] sends; null for the default search. Pass it to the model's first request.
  String? get revset => _view.revset;

  /// Recent, newest first (at most [maxRecent]).
  List<GraphRecent> get recent => List<GraphRecent>.unmodifiable(_recent);

  /// How many Recent entries are stored.
  static const maxRecent = 10;

  /// How many Recent entries show.
  static const shownRecent = 6;

  // ── What the graph shows ──────────────────────────────────────────────────

  /// The default search: one request for the effective `revsets.log`.
  void showDefault() {
    _setView(GraphShownView.defaultSearch);
    model.setRevset(null);
  }

  /// `all()`: one request.
  void showAll() {
    _setView(const GraphAllView());
    model.setRevset(GraphAllView.expression);
  }

  /// Applies [filter]: one request for its revset, run in `all()`, and a Recent entry.
  void apply(GraphFilter filter) {
    _addRecent(GraphRecentFilter(filter));
    _setView(GraphFilterView(filter));
    model.setRevset(filter.revset);
  }

  /// Goes to [key] (item 5): a shown one is selected, revealed and pulsed without a request; one beyond the view
  /// switches to `all()` in one request that lands it ([commitId] is its key there when `all()` keys it by commit id).
  /// A bookmark go-to keeps the [bookmark]'s name in Recent.
  void goTo(String key, {String? bookmark, String? commitId}) {
    _addRecent(GraphRecentGoTo(key, bookmark: bookmark));
    if (model.layout?.indexOfKey(key) != null) {
      model.goTo(key);
      notifyListeners();
      return;
    }
    _setView(const GraphAllView());
    model.goToHidden(key, commitId: commitId == null || commitId.isEmpty ? null : commitId);
  }

  void _setView(GraphShownView view) {
    _view = view;
    _store.saveView(view);
    _notify();
  }

  /// How the field takes focus; the field sets it (null on dispose).
  bool Function()? fieldFocus;

  /// Focuses the field with its text selected (⌘F, `/`); false when there is none or it is disabled.
  bool focusField() => fieldFocus?.call() ?? false;

  // ── Recent ────────────────────────────────────────────────────────────────

  void _addRecent(GraphRecent entry) {
    _recent = <GraphRecent>[entry, ..._recent.where((r) => r != entry)].take(maxRecent).toList();
    _store.saveRecent(_recent);
  }

  /// Clears Recent.
  void clearRecent() {
    _recent = <GraphRecent>[];
    _store.saveRecent(_recent);
    _notify();
  }

  /// The Recent entries [scope] lists while its field is empty, at most [shownRecent]: a go-to whose change is absent
  /// from a shown `all()` layout is hidden.
  List<GraphRecent> recentFor(GraphSearchScope scope) {
    final GraphLayout? layout = model.layout;
    final bool all = _view is GraphAllView && layout != null;
    return _recent
        .where(
          (r) => switch (r) {
            GraphRecentGoTo(:final changeId, :final bookmark) =>
              (scope == GraphSearchScope.any ||
                      (scope == GraphSearchScope.change && bookmark == null) ||
                      (scope == GraphSearchScope.bookmark && bookmark != null)) &&
                  !(all && layout.indexOfKey(changeId) == null),
            GraphRecentFilter(:final filter) => scope == GraphSearchScope.any || scope == filter.scope,
          },
        )
        .take(shownRecent)
        .toList();
  }

  // ── Candidates ────────────────────────────────────────────────────────────

  String? _preparedOp;
  var _bookmarks = const <Bookmark>[];
  var _files = const <String>[];
  String? _email;
  var _emailRead = false;

  /// Reads `bookmarks()` and @'s paths once per operation, and `user.email` once it answers (the field opened).
  Future<void> prepare() async {
    final String? op = model.layout?.operationId;
    if (op == _preparedOp && _preparedOp != null) {
      return;
    }
    _preparedOp = op;
    final (List<Bookmark>, List<String>, String?) read = await (
      _read(_source.bookmarks, const <Bookmark>[]),
      _read(_source.files, const <String>[]),
      _emailRead ? Future<String?>.value(_email) : _read<String?>(_source.userEmail, null),
    ).wait;
    if (_disposed || _preparedOp != op) {
      return;
    }
    _bookmarks = read.$1;
    _files = read.$2;
    _email = read.$3;
    // An unset or failed read is asked again with the next operation.
    _emailRead = read.$3 != null;
    notifyListeners();
  }

  static Future<T> _read<T>(Future<T> Function() call, T fallback) async {
    try {
      return await call();
    } on ZanshinFfiException catch (error) {
      _log.warning('a search read failed: ${error.code}');
      return fallback;
    }
  }

  /// `user.email`, once [prepare] read it.
  String? get userEmail => _email;

  /// The suggestions' index for [scope] and [query]: the shown layout and its content, the bookmarks and paths of
  /// [prepare], and what the lookups for them found.
  GraphSearchIndex index(GraphSearchScope scope, String query) {
    final GraphLayout? layout = model.layout;
    return GraphSearchIndex.build(
      layout: layout,
      content: layout == null ? null : model.content,
      bookmarks: _bookmarks,
      paths: _files,
      found: finds(scope, query)?.found ?? const <GraphSearchChange>[],
      userEmail: _email,
    );
  }

  // ── Lookups and counts, per (operation, expression) ───────────────────────

  final _counts = <String, RevsetCount>{};
  final _countsAsked = <String>{};
  final _pendingCounts = <String>{};
  final _lookups = <String, Object>{};
  final _lookupsAsked = <String>{};
  final _pendingLookups = <({String expression, int limit})>{};
  final _foundContent = <String, GraphCommitContent>{};
  Timer? _batch;
  String? _cacheOp;

  static String _cacheKey(String op, String expression) => '$op\n$expression';

  /// Drops every cache and pending ask when the shown layout's operation moved on: they are per operation.
  void _sync(String op) {
    if (op == _cacheOp) {
      return;
    }
    _cacheOp = op;
    _counts.clear();
    _countsAsked.clear();
    _pendingCounts.clear();
    _lookups.clear();
    _lookupsAsked.clear();
    _pendingLookups.clear();
    _foundContent.clear();
  }

  /// [expression]'s count at the shown layout's operation; null until it arrives. A count with an `error` shows none.
  RevsetCount? countOf(String expression) {
    final String? op = model.layout?.operationId;
    return op == null ? null : _counts[_cacheKey(op, expression)];
  }

  /// Asks for the counts of [expressions] not yet asked at this operation, after the next pause in typing.
  void wantCounts(Iterable<String> expressions) {
    final String? op = model.layout?.operationId;
    if (op == null) {
      return;
    }
    _sync(op);
    var added = false;
    for (final e in expressions) {
      if (_countsAsked.add(_cacheKey(op, e))) {
        _pendingCounts.add(e);
        added = true;
      }
    }
    if (added) {
      _schedule();
    }
  }

  static List<({String expression, int limit})> _lookupsFor(GraphSearchScope scope, String query) {
    final String q = query.trim();
    if (q.length < 2 ||
        !(scope == GraphSearchScope.any || scope == GraphSearchScope.change || scope == GraphSearchScope.description)) {
      return const <({String expression, int limit})>[];
    }
    return <({String expression, int limit})>[
      // The input as `-r <input>` resolves it: bookmark, tag, change or commit prefix, jj's ambiguity refusal.
      if (scope != GraphSearchScope.description) (expression: jjRevsetSymbol(q), limit: 1),
      (expression: descriptionRevset(q, caseInsensitive: true), limit: _foundLimit),
    ];
  }

  /// Asks `findChanges` over `all()` for [query] in [scope] (the input as a revset symbol; its text in descriptions),
  /// after the next pause in typing.
  void lookup(GraphSearchScope scope, String query) {
    final String? op = model.layout?.operationId;
    if (op == null) {
      return;
    }
    _sync(op);
    var added = false;
    for (final ({String expression, int limit}) l in _lookupsFor(scope, query)) {
      if (_lookupsAsked.add(_cacheKey(op, l.expression))) {
        _pendingLookups.add(l);
        added = true;
      }
    }
    if (added) {
      _schedule();
    }
  }

  /// What the lookups for [query] in [scope] found so far; null before any answered.
  GraphSearchFinds? finds(GraphSearchScope scope, String query) {
    final GraphLayout? layout = model.layout;
    final String? op = layout?.operationId;
    final List<({String expression, int limit})> lookups = _lookupsFor(scope, query);
    if (op == null || lookups.isEmpty) {
      return null;
    }
    final found = <GraphSearchChange>[];
    String? refusal;
    var any = false;
    for (final l in lookups) {
      final bool symbol = l.limit == 1 && scope != GraphSearchScope.description;
      switch (_lookups[_cacheKey(op, l.expression)]) {
        case final FoundChanges result:
          any = true;
          for (final FoundChange f in result.entries) {
            found.add(_change(layout!, f, symbol: symbol));
          }
        case final ZanshinFfiException error:
          any = true;
          final RevsetErrorKind? kind = error.revsetError?.kind;
          if (kind == RevsetErrorKind.ambiguousChangeIdPrefix || kind == RevsetErrorKind.ambiguousCommitIdPrefix) {
            refusal = error.context;
          }
      }
    }
    return any ? (found: found, refusal: refusal) : null;
  }

  GraphSearchChange _change(GraphLayout layout, FoundChange f, {required bool symbol}) {
    final int? node = layout.indexOfKey(f.changeId) ?? layout.indexOfKey(f.commitId);
    final GraphCommitContent? content = _foundContent[f.commitId];
    return GraphSearchChange(
      key: node == null ? f.changeId : layout.keyOf(node),
      commitId: f.commitId,
      prefixLength: f.changePrefixLen,
      subject: content?.subject,
      authorName: content?.authorName ?? '',
      authorEmail: content?.authorEmail ?? '',
      inView: node != null,
      timestampMs: content?.timestampMs,
      symbolMatch: symbol,
      bodyMatch: !symbol,
    );
  }

  void _schedule() {
    _batch?.cancel();
    _batch = Timer(pause, () => unawaited(_flush()));
  }

  Future<void> _flush() async {
    final String? op = model.layout?.operationId;
    if (op != null) {
      _sync(op);
    }
    final List<String> counts = _pendingCounts.toList();
    final List<({String expression, int limit})> lookups = _pendingLookups.toList();
    _pendingCounts.clear();
    _pendingLookups.clear();
    if (op == null) {
      return;
    }
    await (_countBatch(op, counts), _lookupBatch(op, lookups)).wait;
  }

  Future<void> _countBatch(String op, List<String> expressions) async {
    if (expressions.isEmpty) {
      return;
    }
    List<RevsetCount> counts;
    try {
      counts = await _source.revsetCounts(op, expressions, cap: graphSearchCountCap);
    } on ZanshinFfiException catch (error) {
      _log.warning('counting search rows failed: ${error.code}');
      counts = <RevsetCount>[for (final _ in expressions) RevsetCount(n: 0, capped: false, error: error)];
    }
    if (op != _cacheOp) {
      return;
    }
    for (var i = 0; i < expressions.length && i < counts.length; i++) {
      _counts[_cacheKey(op, expressions[i])] = counts[i];
    }
    _notify();
  }

  Future<void> _lookupBatch(String op, List<({String expression, int limit})> lookups) async {
    if (lookups.isEmpty) {
      return;
    }
    final String shortPrefixes = model.logDefaults?.shortPrefixes ?? '';
    final hidden = <String>{};
    await Future.wait(<Future<void>>[
      for (final ({String expression, int limit}) l in lookups)
        () async {
          try {
            final FoundChanges result = await _source.findChanges(
              op,
              l.expression,
              limit: l.limit,
              shortPrefixes: shortPrefixes,
            );
            if (op != _cacheOp) {
              return;
            }
            _lookups[_cacheKey(op, l.expression)] = result;
            final GraphLayout? layout = model.layout;
            for (final FoundChange f in result.entries) {
              if (layout?.indexOfKey(f.changeId) == null && !_foundContent.containsKey(f.commitId)) {
                hidden.add(f.commitId);
              }
            }
          } on ZanshinFfiException catch (error) {
            if (op == _cacheOp) {
              _lookups[_cacheKey(op, l.expression)] = error;
            }
          }
        }(),
    ]);
    if (op != _cacheOp) {
      return;
    }
    if (hidden.isNotEmpty) {
      try {
        final Map<String, GraphCommitContent> page = await _source.content(op, hidden.toList());
        if (op == _cacheOp) {
          _foundContent.addAll(page);
        }
      } on ZanshinFfiException catch (error) {
        _log.warning('loading found changes failed: ${error.code}');
      }
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _batch?.cancel();
    super.dispose();
  }
}
