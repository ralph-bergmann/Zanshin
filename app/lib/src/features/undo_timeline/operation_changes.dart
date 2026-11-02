// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show DiffLayoutSetting, SettingsStore;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../graph/graph_inspector.dart' show InspectorFileRow;
import '../graph/graph_ports.dart' show jjOpShowCommand;
import '../graph/inspector_diff.dart';
import '../projects/project_repos.dart';
import 'undo_timeline_model.dart' show shortOperationId;

final _log = Logger('zanshin.operation_changes');

/// What the operation view reads (Story 10.29). A failed call throws [ZanshinFfiException].
abstract interface class OperationChangesSource {
  /// `jj op show <operation>` as data, `--show-changes-in` the effective `revsets.op-diff-changes-in`.
  Future<OpShow> opShow(String operation);

  /// `jj show <revset>`'s entries.
  Future<List<ShowEntry>> show(String revset);

  /// `jj diff -r <revision>`, or `--from` / `--to` read as `jj interdiff` when [interdiff].
  Future<Diff> diff({
    String? revision,
    String? from,
    String? to,
    bool interdiff = false,
    bool summary = false,
    List<String> paths = const <String>[],
  });
}

/// [OperationChangesSource] over an open [ProjectRepo].
class RepoOperationChangesSource implements OperationChangesSource {
  /// The reads of [_repo].
  RepoOperationChangesSource(this._repo);

  final ProjectRepo _repo;

  @override
  Future<OpShow> opShow(String operation) => _repo.handle.opShow(operation: operation);

  @override
  Future<List<ShowEntry>> show(String revset) => _repo.handle.show(revset: revset);

  @override
  Future<Diff> diff({
    String? revision,
    String? from,
    String? to,
    bool interdiff = false,
    bool summary = false,
    List<String> paths = const <String>[],
  }) => _repo.handle.diff(
    revision: revision,
    from: from,
    to: to,
    interdiff: interdiff,
    summary: summary,
    paths: paths,
  );
}

/// One line of a changed commit or ref: jj's `+` / `−` marker and its text.
typedef OperationChangeLine = ({bool added, String text});

/// The operation view's state (Story 10.29): one `opShow` of [operation] at creation, then one `show` of every commit
/// it references for the summaries ("change id commit id first line", the commit id alone after a refusal). The first
/// changed commit starts selected; a selection reads its files (a summary diff) and the first file's diff, both as
/// `jj op show --patch` diffs it (`show_change_diff`): a created or abandoned commit against its parents, a rewritten
/// one as an interdiff from its first predecessor. Refusals are kept per read. The layout is `general.diffLayout` in
/// [settings], written and followed.
class OperationChangesModel extends ChangeNotifier {
  /// The view of [operation] (an id), reading through [_source].
  OperationChangesModel(this._source, {required this.operation, required this.settings})
    : _layout = settings.value.general.diffLayout {
    settings.addListener(_settingsChanged);
    unawaited(_load());
  }

  final OperationChangesSource _source;

  /// The operation's id.
  final String operation;

  /// The app settings: the diff layout.
  final SettingsStore settings;

  DiffLayoutSetting _layout;
  OpShow? _show;
  ZanshinFfiException? _error;
  var _summaries = const <String, ShowEntry>{};
  int? _selected;
  Diff? _files;
  ZanshinFfiException? _filesError;
  String? _focused;
  FileDiff? _focusedDiff;
  ZanshinFfiException? _focusError;
  var _serial = 0;
  var _disposed = false;

  /// What `opShow` returned; null while it loads and after a refusal.
  OpShow? get show => _show;

  /// `opShow`'s refusal.
  ZanshinFfiException? get error => _error;

  /// The changed commits; empty without a commit section.
  List<OpChangedCommit> get changes => _show?.diff?.commits?.changes ?? const <OpChangedCommit>[];

  /// The selected entry of [changes].
  int? get selected => _selected;

  /// The selection's summary diff (its files); null while it loads and after a refusal.
  Diff? get files => _files;

  /// The summary diff's refusal.
  ZanshinFfiException? get filesError => _filesError;

  /// The path whose diff shows.
  String? get focusedPath => _focused;

  /// The focused file's diff; null while it loads, after a refusal, and when the reply lists no such file.
  FileDiff? get focusedDiff => _focusedDiff;

  /// The focused diff's refusal.
  ZanshinFfiException? get focusError => _focusError;

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

  /// [commitId]'s summary as jj's `commit_summary` starts it: the change id and commit id (8 each) and the
  /// description's first line or `(no description set)`; the commit id alone when the `show` read gave none.
  String summaryOf(String commitId) {
    final Change? change = _summaries[commitId]?.change;
    if (change == null) {
      return commitId;
    }
    final String line = change.description.split('\n').first;
    final description = line.isEmpty ? '(no description set)' : line; // l10n-ignore: jj's own words
    return '${_short(change.id)} ${_short(change.commitId)} $description'; // l10n-ignore: ids and jj's text
  }

  static String _short(String id) => id.length <= 8 ? id : id.substring(0, 8);

  /// [change]'s lines: its new commit `+`, then its predecessors (or the abandoned commit) `−`.
  List<OperationChangeLine> linesOf(OpChangedCommit change) => <OperationChangeLine>[
    for (final String id in change.addedCommitIds) (added: true, text: summaryOf(id)),
    for (final String id in change.removedCommitIds) (added: false, text: summaryOf(id)),
  ];

  /// [target]'s lines as `jj op show` writes a ref target (`write_ref_target_summary`): `(absent)`, a conflict's
  /// `(added)` / `(removed)` commits, or its commit; [prefix] (`tracked` / `untracked`) before each.
  List<OperationChangeLine> targetLines(OpRefTarget target, {required bool added, String? prefix}) {
    final lead = prefix == null ? '' : '$prefix ';
    if (target.isAbsent) {
      return <OperationChangeLine>[(added: added, text: '$lead(absent)')]; // l10n-ignore: jj's own words
    }
    if (target.conflicted) {
      return <OperationChangeLine>[
        for (final String id in target.adds) (added: added, text: '$lead(added) ${summaryOf(id)}'), // l10n-ignore: jj's
        for (final String id in target.removes)
          (added: added, text: '$lead(removed) ${summaryOf(id)}'), // l10n-ignore: jj's
      ];
    }
    return <OperationChangeLine>[(added: added, text: '$lead${summaryOf(target.adds.first)}')];
  }

  /// A working copy's commit as a ref target: absent when null.
  static OpRefTarget commitTarget(String? id) =>
      OpRefTarget(adds: <String>[?id], removes: const <String>[], conflicted: false);

  Future<void> _load() async {
    try {
      _show = await _source.opShow(shortOperationId(operation));
    } on ZanshinFfiException catch (error) {
      _log.warning('op show refused: ${error.code}');
      _error = error;
      _notify();
      return;
    }
    if (_disposed) {
      return;
    }
    if (changes.isNotEmpty) {
      select(0);
    }
    _notify();
    await _readSummaries();
  }

  /// One `show` of every commit the diff names, by full commit id (hidden ones resolve).
  Future<void> _readSummaries() async {
    final OpDiff? diff = _show?.diff;
    if (diff == null) {
      return;
    }
    final ids = <String>{
      for (final OpChangedCommit change in changes) ...<String>[...change.addedCommitIds, ...change.removedCommitIds],
      for (final OpWorkingCopyChange wc in diff.workingCopies) ...<String>[?wc.from, ?wc.to],
      for (final OpRefChange ref in <OpRefChange>[...diff.localBookmarks, ...diff.localTags]) ...<String>[
        ...ref.from.adds,
        ...ref.from.removes,
        ...ref.to.adds,
        ...ref.to.removes,
      ],
      for (final OpRemoteRefChange ref in <OpRemoteRefChange>[...diff.remoteBookmarks, ...diff.remoteTags]) ...<String>[
        ...ref.from.adds,
        ...ref.from.removes,
        ...ref.to.adds,
        ...ref.to.removes,
      ],
    };
    if (ids.isEmpty) {
      return;
    }
    try {
      final List<ShowEntry> entries = await _source.show(ids.join(' | '));
      _summaries = <String, ShowEntry>{for (final ShowEntry entry in entries) entry.change.commitId: entry};
      _notify();
    } on ZanshinFfiException catch (error) {
      _log.warning('show of the changed commits refused: ${error.code}');
    }
  }

  /// `jj op show --patch`'s diff of [change] (`show_change_diff`, cli/src/commands/operation/diff.rs:845 @ v0.46.0).
  Future<Diff> _diffOf(OpChangedCommit change, {bool summary = false, List<String> paths = const <String>[]}) {
    final bool rewritten = !change.abandoned && change.removedCommitIds.isNotEmpty;
    return rewritten
        ? _source.diff(
            from: change.removedCommitIds.first,
            to: change.commitId,
            interdiff: true,
            summary: summary,
            paths: paths,
          )
        : _source.diff(revision: change.commitId, summary: summary, paths: paths);
  }

  /// Selects [changes]' entry [index]: reads its files and focuses the first.
  void select(int index) {
    if (_disposed || (index == _selected && _filesError == null)) {
      return;
    }
    _selected = index;
    _files = null;
    _filesError = null;
    _focused = null;
    _focusedDiff = null;
    _focusError = null;
    final int serial = ++_serial;
    final OpChangedCommit change = changes[index];
    unawaited(() async {
      try {
        final Diff files = await _diffOf(change, summary: true);
        if (serial != _serial) {
          return;
        }
        _files = files;
        if (files.files.isNotEmpty) {
          focus(files.files.first.path);
        }
      } on ZanshinFfiException catch (error) {
        _log.warning('diff of a changed commit refused: ${error.code}');
        if (serial == _serial) {
          _filesError = error;
        }
      }
      _notify();
    }());
    _notify();
  }

  /// Shows [path]'s diff (one read); on the focused path after a refusal it reads again.
  void focus(String path) {
    final int? selected = _selected;
    if (_disposed || selected == null || (path == _focused && _focusError == null)) {
      return;
    }
    _focused = path;
    _focusedDiff = null;
    _focusError = null;
    final int serial = _serial;
    final OpChangedCommit change = changes[selected];
    unawaited(() async {
      try {
        final Diff diff = await _diffOf(change, paths: <String>[path]);
        if (serial == _serial && path == _focused) {
          _focusedDiff = diff.files.where((file) => file.path == path).firstOrNull;
          _notify();
        }
      } on ZanshinFfiException catch (error) {
        _log.warning('file diff refused: ${error.code}');
        if (serial == _serial && path == _focused) {
          _focusError = error;
          _notify();
        }
      }
    }());
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
    // A read still in flight drops its reply and starts no further read.
    _serial++;
    settings.removeListener(_settingsChanged);
    super.dispose();
  }
}

/// The elided counts' line as `jj op show` writes it (`write_elided_commit_counts`), or null when none was elided.
String? elidedLine(OpCommitsDiff commits) {
  String? count(RefDistance d) => switch ((d.lower, d.upper)) {
    (0, 0) => null,
    (0, _) => 'some', // l10n-ignore: jj's own words
    (final int lower, final int upper) when upper == lower => '$lower',
    (final int lower, _) => '$lower+',
  };
  final parts = <String>[
    if (count(commits.elidedNewlyVisible) case final String c) '$c newly added', // l10n-ignore: jj's own words
    if (count(commits.elidedNewlyHidden) case final String c) '$c newly removed', // l10n-ignore: jj's own words
  ];
  return parts.isEmpty ? null : '(Elided ${parts.join(' and ')} revisions)'; // l10n-ignore: jj's own words
}

/// The Undo Timeline's operation view (Story 10.29): in the pinned panel instead of the list, a header (Back, the
/// operation's first line, `jj op show <id>` in mono) over what `jj op show` lists — the changed commits (`+` new, `−`
/// predecessors or abandoned) with the elided count, the changed working copies, local bookmarks and tags, remote
/// bookmarks and tags, under jj's own headings. The selected commit (click, ↩) shows its files and the focused file's
/// diff in 10.24's components, without Viewed. Esc or Back runs [onBack].
class OperationChangesView extends StatelessWidget {
  /// The view of [model]'s operation, [operation] its row.
  const OperationChangesView({required this.model, required this.operation, required this.onBack, super.key});

  /// The view's state.
  final OperationChangesModel model;

  /// The operation, as the list read it.
  final Operation operation;

  /// Returns to the list.
  final VoidCallback onBack;

  /// The list's padding (the Undo Timeline's).
  static const _padding = EdgeInsets.fromLTRB(6, 0, 6, 10);

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (node, event) {
      if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
        onBack();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: ListenableBuilder(
      listenable: model,
      builder: (context, _) => ListView(
        primary: true,
        padding: _padding,
        children: <Widget>[_header(context), ..._body(context)],
      ),
    ),
  );

  Widget _header(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final String line = operation.rootOp
        ? 'root()' // l10n-ignore: jj's text
        : operation.description.split('\n').first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: <Widget>[
          ZsButton(
            label: context.l10n.operationChangesBack,
            icon: ZI.chevronLeft,
            identifier: 'operation-changes-back',
            onPressed: onBack,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              line,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ZsType.secondary.copyWith(color: colors.text),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              jjOpShowCommand(shortOperationId(operation.id)),
              style: ZsType.id.copyWith(color: colors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    if (model.error case final ZanshinFfiException error?) {
      return <Widget>[_Text(error.context ?? error.code, key: const ValueKey<String>('operation-changes-error'))];
    }
    final OpShow? show = model.show;
    if (show == null) {
      return const <Widget>[];
    }
    final warnings = <Widget>[
      for (final ZanshinWarning warning in show.warnings) _Text(warning.message, color: colors.warn),
    ];
    final OpDiff? diff = show.diff;
    if (diff == null) {
      return <Widget>[...warnings, _Text(strings.operationChangesMerge)];
    }
    final OpCommitsDiff? commits = diff.commits;
    final String? elided = commits == null ? null : elidedLine(commits);
    final sections = <Widget>[
      if (model.changes.isNotEmpty || elided != null)
        _Section(
          heading: 'Changed commits:', // l10n-ignore: jj's own words
          children: <Widget>[
            for (var i = 0; i < model.changes.length; i++) ...<Widget>[
              _CommitRow(model: model, index: i),
              if (model.selected == i) _Files(model: model),
            ],
            if (elided != null) _Text(elided),
          ],
        ),
      for (final OpWorkingCopyChange wc in diff.workingCopies)
        _RefSection(
          heading: 'Changed working copy ${wc.workspace}@:', // l10n-ignore: jj's own words
          lines: <OperationChangeLine>[
            ...model.targetLines(OperationChangesModel.commitTarget(wc.to), added: true),
            ...model.targetLines(OperationChangesModel.commitTarget(wc.from), added: false),
          ],
        ),
      if (diff.localBookmarks.isNotEmpty)
        _refs(model, 'Changed local bookmarks:', diff.localBookmarks), // l10n-ignore: jj's own words
      if (diff.localTags.isNotEmpty) _refs(model, 'Changed local tags:', diff.localTags), // l10n-ignore: jj's own words
      if (diff.remoteBookmarks.isNotEmpty)
        _remoteRefs(model, 'Changed remote bookmarks:', diff.remoteBookmarks), // l10n-ignore: jj's own words
      if (diff.remoteTags.isNotEmpty)
        _remoteRefs(model, 'Changed remote tags:', diff.remoteTags), // l10n-ignore: jj's own words
    ];
    return <Widget>[
      ...warnings,
      if (sections.isEmpty && warnings.isEmpty) _Text(strings.operationChangesNone),
      ...sections,
    ];
  }

  static Widget _refs(OperationChangesModel model, String heading, List<OpRefChange> refs) => _Section(
    heading: heading,
    children: <Widget>[
      for (final OpRefChange ref in refs)
        _RefSection(
          heading: '${ref.name}:', // l10n-ignore: a ref name
          lines: <OperationChangeLine>[
            ...model.targetLines(ref.to, added: true),
            ...model.targetLines(ref.from, added: false),
          ],
        ),
    ],
  );

  static Widget _remoteRefs(OperationChangesModel model, String heading, List<OpRemoteRefChange> refs) => _Section(
    heading: heading,
    children: <Widget>[
      for (final OpRemoteRefChange ref in refs)
        _RefSection(
          heading: '${ref.name}@${ref.remote}:', // l10n-ignore: a ref symbol
          lines: <OperationChangeLine>[
            ...model.targetLines(ref.to, added: true, prefix: _tracking(ref.toTracked)),
            ...model.targetLines(ref.from, added: false, prefix: _tracking(ref.fromTracked)),
          ],
        ),
    ],
  );

  static String _tracking(bool tracked) => tracked ? 'tracked' : 'untracked'; // l10n-ignore: jj's own words
}

/// A section: jj's heading over its rows.
class _Section extends StatelessWidget {
  const _Section({required this.heading, required this.children});

  final String heading;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            heading,
            style: ZsType.secondary.copyWith(
              fontWeight: FontWeight.w600,
              fontVariations: const <FontVariation>[FontVariation.weight(600)],
              color: ZsColors.of(context).text,
            ),
          ),
        ),
        ...children,
      ],
    ),
  );
}

/// A ref's or working copy's name over its `+` / `−` lines.
class _RefSection extends StatelessWidget {
  const _RefSection({required this.heading, required this.lines});

  final String heading;
  final List<OperationChangeLine> lines;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(heading, style: ZsType.id.copyWith(color: ZsColors.of(context).text)),
        for (final OperationChangeLine line in lines) _Line(line),
      ],
    ),
  );
}

/// One `+` / `−` line in mono, the marker in the add / remove ink.
class _Line extends StatelessWidget {
  const _Line(this.line);

  final OperationChangeLine line;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return Text.rich(
      TextSpan(
        style: ZsType.id.copyWith(color: colors.textMuted),
        children: <InlineSpan>[
          TextSpan(
            text: line.added ? '+ ' : '− ', // l10n-ignore: jj's markers
            style: TextStyle(color: line.added ? colors.add : colors.rem),
          ),
          TextSpan(text: line.text),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// A changed commit's lines; a click or ↩ selects it.
class _CommitRow extends StatelessWidget {
  const _CommitRow({required this.model, required this.index});

  final OperationChangesModel model;
  final int index;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final List<OperationChangeLine> lines = model.linesOf(model.changes[index]);
    final selected = model.selected == index;
    return ZsControlCore(
      identifier: 'operation-changes-commit-$index',
      onActivate: () => model.select(index),
      ring: ZsRingPlacement.inside,
      ringRadius: metrics.radiusMd,
      selected: selected,
      semantics: SemanticsProperties(
        button: true,
        selected: selected,
        label: lines.map((l) => '${l.added ? '+' : '−'} ${l.text}').join('\n'), // l10n-ignore: jj's lines
      ),
      builder: (context, status) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? colors.flOn
              : status.hovered
              ? colors.flHover
              : colors.flOn.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(metrics.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[for (final OperationChangeLine line in lines) _Line(line)],
        ),
      ),
    );
  }
}

/// The selected commit's files and the focused file's diff, or the refusal in their place.
class _Files extends StatelessWidget {
  const _Files({required this.model});

  final OperationChangesModel model;

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (model.filesError case final ZanshinFfiException error?) {
      child = _Text(error.context ?? error.code, key: const ValueKey<String>('operation-changes-files-error'));
    } else if (model.files case final Diff diff?) {
      final String? focused = model.focusedPath;
      child = diff.files.isEmpty
          ? _Text(context.l10n.operationChangesNoFiles)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 1,
              children: <Widget>[
                for (var i = 0; i < diff.files.length; i++)
                  _FileRow(model: model, file: diff.files[i], index: i, focused: diff.files[i].path == focused),
                if (focused != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: InspectorDiffView(
                      path: focused,
                      diff: model.focusedDiff,
                      error: model.focusError,
                      layout: model.layout,
                      onLayoutChanged: model.setLayout,
                    ),
                  ),
              ],
            );
    } else {
      child = const SizedBox.shrink();
    }
    return Padding(padding: const EdgeInsets.fromLTRB(8, 4, 0, 8), child: child);
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.model, required this.file, required this.index, required this.focused});

  final OperationChangesModel model;
  final FileDiff file;
  final int index;
  final bool focused;

  @override
  Widget build(BuildContext context) => ZsControlCore(
    identifier: 'operation-changes-file-$index',
    onActivate: () => model.focus(file.path),
    ring: ZsRingPlacement.inside,
    ringRadius: ZsMetrics.of(context).radiusMd,
    selected: focused,
    semantics: SemanticsProperties(button: true, selected: focused, label: file.path),
    builder: (context, status) => InspectorFileRow(
      file: FileChange(path: file.path, kind: file.kind, fromPath: file.fromPath),
      summary: file,
      focused: focused,
      highlighted: status.hovered,
    ),
  );
}

/// A line of text in place of content: jj's text or a note, `--text-dim` (or [color]).
class _Text extends StatelessWidget {
  const _Text(this.text, {this.color, super.key});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    child: Text(text, style: ZsType.code.copyWith(color: color ?? ZsColors.of(context).textDim)),
  );
}
