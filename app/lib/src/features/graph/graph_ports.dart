// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../projects/project_repos.dart';
import 'backend_graph_layout.dart';
import 'graph_layout.dart';

final _log = Logger('zanshin.graph');

/// One layout request (Story 10.5 item 2): the revset and the view's mode and lane order, plus the jj parameters
/// passed through explicitly (FR-JJ-17) — `prioritize` and `shortPrefixes` pre-filled from `logDefaults()`, `anchors`
/// from zanshin_core's [defaultGraphAnchors] — and the stack state (10.17). It carries no card size and no "now".
@immutable
class GraphRequest {
  /// A request for [revset].
  const GraphRequest({
    required this.revset,
    required this.prioritize,
    required this.shortPrefixes,
    required this.anchors,
    required this.utcOffsetMin,
    this.mode = GraphMode.free,
    this.order = GraphLaneOrder.compact,
    this.stacks = false,
    this.expandedKeys = const <String>{},
    this.collapsedKeys = const <String>{},
    this.keepOpenKeys = const <String>{},
  });

  /// The revset shown.
  final String revset;

  /// The layout mode.
  final GraphMode mode;

  /// The lane order.
  final GraphLaneOrder order;

  /// `revsets.log-graph-prioritize`.
  final String prioritize;

  /// `revsets.short-prefixes`.
  final String shortPrefixes;

  /// The priority anchors.
  final List<String> anchors;

  /// The fixed UTC offset, in minutes, the day buckets are cut at.
  final int utcOffsetMin;

  /// Whether linear runs group into stacks (10.17).
  final bool stacks;

  /// The stacks the user expanded.
  final Set<String> expandedKeys;

  /// The stacks the user collapsed.
  final Set<String> collapsedKeys;

  /// The keys whose stack stays open: the selection and a pending reveal target.
  final Set<String> keepOpenKeys;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphRequest &&
          other.revset == revset &&
          other.mode == mode &&
          other.order == order &&
          other.prioritize == prioritize &&
          other.shortPrefixes == shortPrefixes &&
          listEquals(other.anchors, anchors) &&
          other.utcOffsetMin == utcOffsetMin &&
          other.stacks == stacks &&
          setEquals(other.expandedKeys, expandedKeys) &&
          setEquals(other.collapsedKeys, collapsedKeys) &&
          setEquals(other.keepOpenKeys, keepOpenKeys);

  @override
  int get hashCode => Object.hash(
    revset,
    mode,
    order,
    prioritize,
    shortPrefixes,
    Object.hashAll(anchors),
    utcOffsetMin,
    stacks,
    Object.hashAllUnordered(expandedKeys),
    Object.hashAllUnordered(collapsedKeys),
    Object.hashAllUnordered(keepOpenKeys),
  );

  @override
  String toString() => 'GraphRequest($revset, ${mode.name}, ${order.name}, keepOpen: $keepOpenKeys)';
}

/// The user's stack toggles of one repository (Story 10.17): the runs expanded and collapsed, each by its oldest
/// member's key. A run neither names shows the engine's default.
@immutable
class GraphStackToggles {
  /// The toggles; empty by default.
  const GraphStackToggles({this.expanded = const <String>{}, this.collapsed = const <String>{}});

  /// The runs the user expanded.
  final Set<String> expanded;

  /// The runs the user collapsed.
  final Set<String> collapsed;

  @override
  bool operator ==(Object other) =>
      other is GraphStackToggles && setEquals(other.expanded, expanded) && setEquals(other.collapsed, collapsed);

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(expanded), Object.hashAllUnordered(collapsed));
}

/// Where one repository's [GraphStackToggles] persist (Story 10.17).
abstract interface class GraphStackStore {
  /// The stored toggles.
  GraphStackToggles load();

  /// Stores [toggles]; a failed write keeps them for the session.
  void save(GraphStackToggles toggles);
}

/// What one layout call returned: the [layout], the call's [warnings] in the CLI's print order, and its pre-verb
/// snapshot report.
@immutable
class GraphLoad {
  /// A load of [layout].
  const GraphLoad(this.layout, {this.warnings = const <ZanshinWarning>[], this.precondition});

  /// The layout.
  final GraphLayout layout;

  /// The call's warnings.
  final List<ZanshinWarning> warnings;

  /// The call's snapshot report, when it ran one.
  final Precondition? precondition;
}

/// What the graph reads (Story 10.5 item 1). A failed call throws [ZanshinFfiException].
abstract interface class GraphSource {
  /// Lays out [request].
  Future<GraphLoad> layout(GraphRequest request);

  /// The content of [commitIds], read at [operationId] (the layout's, pinning the page; Story 10.11), keyed by commit
  /// id. An id the source cannot read is left out.
  Future<Map<String, GraphCommitContent>> content(String? operationId, List<String> commitIds);

  /// The repository's watcher events.
  Stream<RepoEvent> get events;

  /// The effective `jj log` defaults.
  Future<LogDefaults> logDefaults();

  /// `jj workspace update-stale` (Story 9.23).
  Future<StaleRecovery> updateStale();

  /// `jj show <commitId>` (Story 9.6): a gap's real parents (Story 10.19).
  Future<ShowEntry> show(String commitId);
}

/// One jj verb on the graph's changes (Story 10.9): its parameters passed through with the CLI's defaults, the one jj
/// v0.46.0 [command] it runs (change ids included, POSIX shell-quoted) and the cards it makes [pendingKeys]. Callers
/// pass the target; nothing here guesses one.
@immutable
sealed class GraphAction {
  const GraphAction();

  /// The full jj command, as the user would type it.
  String get command;

  /// The cards shown pending while it runs.
  Set<String> get pendingKeys;
}

/// `jj edit <id>`.
final class GraphEdit extends GraphAction {
  /// Edits [id].
  const GraphEdit(this.id);

  /// The change to edit.
  final String id;

  @override
  String get command => _jj(<String>['edit', id]); // l10n-ignore: jj command

  @override
  Set<String> get pendingKeys => <String>{id};
}

/// `jj describe <id> -m <paragraph>…`.
final class GraphDescribe extends GraphAction {
  /// Sets [id]'s description to [description], shown as one `-m` unless [paragraphs] says how it was joined.
  const GraphDescribe(this.id, this.description, {this.paragraphs});

  /// The CLI's `-m` [paragraphs], joined as `jj describe -m … -m …` joins them ([joinMessageParagraphs]).
  GraphDescribe.fromParagraphs(this.id, List<String> this.paragraphs) : description = joinMessageParagraphs(paragraphs);

  /// The change to describe.
  final String id;

  /// The new description.
  final String description;

  /// The `-m` paragraphs [description] was joined from; null shows [description] as one.
  final List<String>? paragraphs;

  @override
  String get command => _jj(<String>[
    'describe', id, // l10n-ignore: jj command
    for (final String paragraph in paragraphs ?? <String>[description]) ..._message(paragraph),
  ]);

  @override
  Set<String> get pendingKeys => <String>{id};
}

/// `jj new <parents>`, `jj new -A <insertAfter> -B <insertBefore>`.
final class GraphNew extends GraphAction {
  /// A new change on [parents], or inserted after [insertAfter] / before [insertBefore].
  const GraphNew({
    this.parents = const <String>[],
    this.insertAfter = const <String>[],
    this.insertBefore = const <String>[],
  });

  /// The new change's parents.
  final List<String> parents;

  /// `-A`.
  final List<String> insertAfter;

  /// `-B`.
  final List<String> insertBefore;

  @override
  String get command => _jj(<String>[
    'new', // l10n-ignore: jj command
    ...parents,
    for (final id in insertAfter) ...<String>['-A', id],
    for (final id in insertBefore) ...<String>['-B', id],
  ]);

  @override
  Set<String> get pendingKeys => <String>{...parents, ...insertAfter, ...insertBefore};
}

/// `jj abandon <ids>` (no confirmation, as the CLI).
final class GraphAbandon extends GraphAction {
  /// Abandons [ids].
  const GraphAbandon(this.ids);

  /// The changes to abandon.
  final List<String> ids;

  @override
  String get command => _jj(<String>['abandon', ...ids]); // l10n-ignore: jj command

  @override
  Set<String> get pendingKeys => ids.toSet();
}

/// `jj revert -r <id> -B @`; jj's `templates.revert_description` writes the description.
final class GraphRevert extends GraphAction {
  /// Reverts [id] before @.
  const GraphRevert(this.id);

  /// The change to revert.
  final String id;

  @override
  String get command => _jj(<String>['revert', '-r', id, '-B', '@']); // l10n-ignore: jj command

  @override
  Set<String> get pendingKeys => <String>{id};
}

/// `jj squash`: [revision] into its parent (`-r`), or [from] into [into] (each `null`/empty = @).
final class GraphSquash extends GraphAction {
  /// A squash with the CLI's defaults.
  const GraphSquash({
    this.revision,
    this.from = const <String>[],
    this.into,
    this.paths = const <String>[],
    this.message,
    this.useDestinationMessage = false,
    this.keepEmptied = false,
    this.editedDescription,
  });

  /// `-r`.
  final String? revision;

  /// `--from`.
  final List<String> from;

  /// `--into`.
  final String? into;

  /// Repo-relative path prefixes (`root:` filesets); empty = everything.
  final List<String> paths;

  /// `-m`, one entry per paragraph.
  final List<String>? message;

  /// `-u`.
  final bool useDestinationMessage;

  /// `-k`.
  final bool keepEmptied;

  /// The text saved in the CLI's editor (not part of [command]: the CLI opens its editor for it).
  final String? editedDescription;

  @override
  String get command => _jj(<String>[
    'squash', // l10n-ignore: jj command
    if (revision case final String revision) ...<String>['-r', revision],
    for (final id in from) ...<String>['--from', id],
    if (into case final String into) ...<String>['--into', into],
    for (final paragraph in message ?? const <String>[]) ..._message(paragraph),
    if (useDestinationMessage) '-u',
    if (keepEmptied) '-k',
    for (final path in paths) 'root:${_filesetString(path)}', // l10n-ignore: jj command
  ]);

  @override
  Set<String> get pendingKeys => <String>{?revision, ...from, ?into};
}

/// `jj bookmark create <names> [-r <revision>]` (`null` = @).
final class GraphBookmarkCreate extends GraphAction {
  /// Creates [names] on [revision].
  const GraphBookmarkCreate(this.names, {this.revision});

  /// The bookmark names.
  final List<String> names;

  /// The target.
  final String? revision;

  @override
  String get command => _jj(<String>[
    'bookmark', 'create', // l10n-ignore: jj command
    ...names.map(_revsetSymbol),
    if (revision case final String revision) ...<String>['-r', revision],
  ]);

  @override
  Set<String> get pendingKeys => <String>{?revision};
}

/// `jj bookmark delete <names>`: exactly these names (a glob-like one as `exact:`).
final class GraphBookmarkDelete extends GraphAction {
  /// Deletes the bookmarks [names].
  const GraphBookmarkDelete(this.names);

  /// The bookmark names.
  final List<String> names;

  /// The patterns jj receives, the same text the command shows.
  List<String> get patterns => names.map(_exactPattern).toList();

  @override
  String get command => _jj(<String>['bookmark', 'delete', ...patterns]); // l10n-ignore: jj command

  @override
  Set<String> get pendingKeys => const <String>{};
}

/// `jj bookmark move <names> [--from …] [--to <to>] [--allow-backwards]` (`to` `null` = @).
final class GraphBookmarkMove extends GraphAction {
  /// Moves [names] to [to].
  const GraphBookmarkMove(this.names, {this.from = const <String>[], this.to, this.allowBackwards = false});

  /// The exact bookmark names.
  final List<String> names;

  /// `--from`.
  final List<String> from;

  /// `--to`.
  final String? to;

  /// `--allow-backwards`.
  final bool allowBackwards;

  @override
  String get command => _jj(<String>[
    'bookmark', 'move', // l10n-ignore: jj command
    ...names.map(_exactPattern),
    for (final id in from) ...<String>['--from', id],
    if (to case final String to) ...<String>['--to', to],
    if (allowBackwards) '--allow-backwards',
  ]);

  @override
  Set<String> get pendingKeys => <String>{?to};
}

/// `jj bookmark rename <old> <new> [--overwrite-existing]`.
final class GraphBookmarkRename extends GraphAction {
  /// Renames [oldName] to [newName].
  const GraphBookmarkRename(this.oldName, this.newName, {this.overwriteExisting = false});

  /// The current name.
  final String oldName;

  /// The new name.
  final String newName;

  /// `--overwrite-existing`.
  final bool overwriteExisting;

  @override
  String get command => _jj(<String>[
    'bookmark', 'rename', _revsetSymbol(oldName), _revsetSymbol(newName), // l10n-ignore: jj command
    if (overwriteExisting) '--overwrite-existing',
  ]);

  @override
  Set<String> get pendingKeys => const <String>{};
}

/// `jj bookmark track <name>@<remote>` (Story 10.14): exactly that remote bookmark.
final class GraphBookmarkTrack extends GraphAction {
  /// Tracks [name]@[remote].
  const GraphBookmarkTrack(this.name, this.remote);

  /// The bookmark name.
  final String name;

  /// The remote.
  final String remote;

  /// The `BOOKMARK@REMOTE` symbol jj receives, the same text the command shows.
  String get symbol => remoteBookmarkSymbol(name, remote);

  @override
  String get command => _jj(<String>['bookmark', 'track', symbol]); // l10n-ignore: jj command

  @override
  Set<String> get pendingKeys => const <String>{};
}

/// `jj bookmark untrack <name>@<remote>` (Story 10.14): exactly that remote bookmark.
final class GraphBookmarkUntrack extends GraphAction {
  /// Stops tracking [name]@[remote].
  const GraphBookmarkUntrack(this.name, this.remote);

  /// The bookmark name.
  final String name;

  /// The remote.
  final String remote;

  /// The `BOOKMARK@REMOTE` symbol jj receives, the same text the command shows.
  String get symbol => remoteBookmarkSymbol(name, remote);

  @override
  String get command => _jj(<String>['bookmark', 'untrack', symbol]); // l10n-ignore: jj command

  @override
  Set<String> get pendingKeys => const <String>{};
}

/// [name]@[remote] as a remote bookmark symbol: each part bare when it is an identifier, else a string literal.
String remoteBookmarkSymbol(String name, String remote) => '${_revsetSymbol(name)}@${_revsetSymbol(remote)}';

/// `jj undo` of Zanshin's own latest operation, [of]'s.
final class GraphUndo extends GraphAction {
  /// Undoes [of].
  const GraphUndo(this.of);

  /// The action undone.
  final GraphAction of;

  @override
  String get command => _jj(<String>['undo']); // l10n-ignore: jj command

  @override
  Set<String> get pendingKeys => const <String>{};
}

/// `jj redo` of Zanshin's own latest undo, [of]'s action.
final class GraphRedo extends GraphAction {
  /// Redoes [of].
  const GraphRedo(this.of);

  /// The action redone.
  final GraphAction of;

  @override
  String get command => _jj(<String>['redo']); // l10n-ignore: jj command

  @override
  Set<String> get pendingKeys => const <String>{};
}

/// An operation from the op log (Story 11.9), as a [GraphUndo] names what it undid: not a verb of its own — [command]
/// is its `args` tag (the command line that wrote it) or else its description.
final class GraphLoggedOperation extends GraphAction {
  /// The operation [id] (forward hex) with its [description] and `args` tag [args].
  const GraphLoggedOperation(this.id, this.description, {this.args});

  /// The operation's id.
  final String id;

  /// jj's description of the operation.
  final String description;

  /// The value of its `args` tag, when it has one.
  final String? args;

  @override
  String get command => args ?? description;

  @override
  Set<String> get pendingKeys => const <String>{};
}

/// `jj op restore <operation>` (Story 9.12), with the CLI's defaults.
final class GraphOpRestore extends GraphAction {
  /// Restores the repository to [operation].
  const GraphOpRestore(this.operation);

  /// The operation id, as jj's 12-hex short id.
  final String operation;

  @override
  String get command => _jj(<String>['op', 'restore', operation]); // l10n-ignore: jj command

  @override
  Set<String> get pendingKeys => const <String>{};
}

/// `jj op show <operation>`, as the Undo Timeline's disabled Show changes names it (Story 11.9).
String jjOpShowCommand(String operation) => _jj(<String>['op', 'show', operation]); // l10n-ignore: jj command

/// The description `-m` [paragraphs] make (`join_message_paragraphs`, `../jj` v0.46.0 cli/src/description_util.rs:421):
/// each non-empty paragraph ends with a newline, and the paragraphs are joined by one more.
String joinMessageParagraphs(List<String> paragraphs) =>
    paragraphs.map((p) => p.isEmpty || p.endsWith('\n') ? p : '$p\n').join('\n');

/// `jj log -r <revset>`, shell-quoted as the action commands are (Story 10.21's footer).
String jjLogCommand(String revset) => _jj(<String>['log', '-r', revset]); // l10n-ignore: jj command

/// `jj` plus [args], each POSIX shell-quoted.
String _jj(List<String> args) => <String>['jj', ...args.map(_shellQuote)].join(' '); // l10n-ignore: jj command

/// `-m <text>`; a text clap would read as a flag goes as `--message=<text>`.
List<String> _message(String text) => text.startsWith('-') ? <String>['--message=$text'] : <String>['-m', text];

// No leading `=`: zsh's EQUALS option expands `=word` to a command path.
final _shellSafe = RegExp(r'^[A-Za-z0-9@%+:,./_-][A-Za-z0-9@%+=:,./_-]*$');

/// [text] as one POSIX shell word: bare when it holds only safe characters, else single-quoted.
String _shellQuote(String text) => _shellSafe.hasMatch(text) ? text : "'${text.replaceAll("'", r"'\''")}'";

// revset.pest's `identifier` @ v0.46.0, ASCII only (a non-ASCII name is quoted, which jj reads the same).
final _revsetIdentifier = RegExp(r'^[A-Za-z0-9_*/]+(?:(?:\.|-+|\+)[A-Za-z0-9_*/]+)*$');

/// [name] as a revset symbol: bare when it is an identifier, else a string literal.
String _revsetSymbol(String name) => _revsetIdentifier.hasMatch(name) ? name : _stringLiteral(name);

/// [name] as a name pattern matching only itself: a bare pattern is a glob, so a name with a glob character (jj-core
/// `is_glob_char` @ v0.46.0: `?*[]{}\`) is `exact:`.
String _exactPattern(String name) =>
    name.contains(RegExp(r'[*?[\]{}\\]')) ? 'exact:${_stringLiteral(name)}' : _revsetSymbol(name); // l10n-ignore: jj

// fileset.pest's `identifier` @ v0.46.0, without the glob characters.
final _filesetIdentifier = RegExp(r'^[A-Za-z0-9+\-.@_/]+$');

String _filesetString(String path) => _filesetIdentifier.hasMatch(path) ? path : _stringLiteral(path);

/// A jj string literal (revset and fileset share its escapes).
String _stringLiteral(String text) => '"${text.replaceAllMapped(_escaped, (m) => _escape(m[0]!))}"';

final _escaped = RegExp(r'[\\"\x00-\x1f]');

String _escape(String char) => switch (char) {
  r'\' => r'\\',
  '"' => r'\"',
  '\n' => r'\n',
  '\t' => r'\t',
  '\r' => r'\r',
  _ => '\\x${char.codeUnitAt(0).toRadixString(16).padLeft(2, '0')}',
};

/// How a [GraphAction] ended, as `GraphViewModel.run` reports it.
sealed class GraphActionResult {
  const GraphActionResult();
}

/// The verb ran; [outcome] is what the model published.
final class GraphActionDone extends GraphActionResult {
  /// A finished action.
  const GraphActionDone(this.outcome);

  /// Its outcome.
  final GraphOutcome outcome;
}

/// jj refused, with [error] verbatim.
final class GraphActionRefused extends GraphActionResult {
  /// A refusal.
  const GraphActionRefused(this.error);

  /// jj's error: code, context, hints and warnings.
  final ZanshinFfiException error;
}

/// Nothing ran, for [reason].
final class GraphActionDisabled extends GraphActionResult {
  /// A disabled trigger.
  const GraphActionDisabled(this.reason);

  /// Why.
  final GraphDisabledReason reason;
}

/// Why a trigger runs nothing.
enum GraphDisabledReason {
  /// Another action runs.
  busy,

  /// The working copy is stale; `jj workspace update-stale` recovers it.
  stale,

  /// No own operation to undo or redo.
  nothingToUndo,

  /// The op-log head is no longer Zanshin's own operation.
  foreignOperation,
}

/// What one action did (Story 10.9), for the toast (10.23), the Change menu (11.13) and the animations (10.20): the
/// [action], jj's [result] or [error], whether it is [undoable], and the op hints.
@immutable
class GraphOutcome {
  /// An outcome of [action].
  const GraphOutcome(
    this.action, {
    this.result,
    this.error,
    this.undoable = false,
    this.anchor,
    this.flash = const <String>[],
  });

  /// The action; a [GraphUndo] or [GraphRedo] names the action it undid or redid.
  final GraphAction action;

  /// jj's facts on success.
  final MutationResult? result;

  /// jj's refusal, verbatim.
  final ZanshinFfiException? error;

  /// Whether it wrote an operation an undo can take back.
  final bool undoable;

  /// The card the reload was anchored on.
  final String? anchor;

  /// The cards to flash (a squash's destination, a bookmark move's target).
  final List<String> flash;

  /// The changes it created, from [result].
  List<String> get born => result?.newChangeIds ?? const <String>[];

  /// jj's warnings, on success and on a refusal.
  List<ZanshinWarning> get warnings => result?.warnings ?? error?.warnings ?? const <ZanshinWarning>[];
}

/// Runs verbs on the graph's changes (Story 10.9). A refusal throws [ZanshinFfiException].
abstract interface class GraphActions {
  /// Runs [action].
  Future<MutationResult> run(GraphAction action);

  /// The op-log head's id (`jj op log -n 1`, which snapshots first).
  Future<String> headOpId();
}

/// [GraphActions] over an open [ProjectRepo]'s handle, one call per action.
class RepoGraphActions implements GraphActions {
  /// The actions of [_repo].
  RepoGraphActions(this._repo);

  final ProjectRepo _repo;

  @override
  Future<MutationResult> run(GraphAction action) {
    final RepoHandle handle = _repo.handle;
    return switch (action) {
      GraphEdit(:final id) => handle.edit(id),
      GraphDescribe(:final id, :final description) => handle.describe(changeId: id, description: description),
      GraphNew(:final parents, :final insertAfter, :final insertBefore) =>
        parents.isEmpty && insertAfter.isEmpty && insertBefore.isEmpty
            ? _newOnAt(handle)
            : handle.newChange(parents, insertAfter: insertAfter, insertBefore: insertBefore),
      GraphAbandon(:final ids) => handle.abandon(ids),
      GraphRevert(:final id) => _revertBeforeAt(handle, id),
      GraphSquash() => handle.squash(
        revision: action.revision,
        from: action.from,
        into: action.into,
        paths: action.paths,
        message: action.message,
        useDestinationMessage: action.useDestinationMessage,
        keepEmptied: action.keepEmptied,
        editedDescription: action.editedDescription,
      ),
      GraphBookmarkCreate(:final names, :final revision) => handle.bookmarkCreate(names, revision: revision),
      GraphBookmarkDelete() => handle.bookmarkDelete(action.patterns),
      GraphBookmarkMove(:final names, :final from, :final to, :final allowBackwards) => handle.bookmarkMove(
        names,
        from: from,
        to: to,
        allowBackwards: allowBackwards,
      ),
      GraphBookmarkRename(:final oldName, :final newName, :final overwriteExisting) => handle.bookmarkRename(
        oldName,
        newName,
        overwriteExisting: overwriteExisting,
      ),
      GraphBookmarkTrack(:final symbol) => handle.bookmarkTrack(<String>[symbol]),
      GraphBookmarkUntrack(:final symbol) => handle.bookmarkUntrack(<String>[symbol]),
      GraphUndo() => handle.undo(),
      GraphRedo() => handle.redo(),
      GraphOpRestore(:final operation) => handle.opRestore(operation),
      GraphLoggedOperation() => throw ArgumentError.value(action, 'action', 'an op-log entry is not a verb'),
    };
  }

  /// `-B @`: the handle takes change ids only, so @ is read when the verb runs (none: jj refuses the empty location).
  static Future<MutationResult> _revertBeforeAt(RepoHandle handle, String id) async {
    final String? at = (await handle.status()).workingCopyChangeId;
    return handle.revert(revisions: <String>[id], insertBefore: <String>[?at]);
  }

  /// `jj new` (the CLI's default parent @): the handle needs @ passed explicitly, so it is read when the verb runs.
  static Future<MutationResult> _newOnAt(RepoHandle handle) async {
    final String? at = (await handle.status()).workingCopyChangeId;
    return handle.newChange(<String>[?at]);
  }

  @override
  Future<String> headOpId() async => (await _repo.handle.opLog(limit: 1)).first.id;
}

/// What the inspector reads (Story 10.8). A failed call throws [ZanshinFfiException].
abstract interface class GraphDetails {
  /// `jj show <commitId>`: the change's full metadata and its file changes (it snapshots first, as the CLI does).
  Future<ShowEntry> show(String commitId);

  /// The previews of the verbs on [changeId] (`RepoHandle.changeActions`): what each would do, or why it would refuse.
  Future<ChangeActions> changeActions(String changeId);
}

/// [GraphDetails] over an open [ProjectRepo]'s handle.
class RepoGraphDetails implements GraphDetails {
  /// The details of [_repo].
  RepoGraphDetails(this._repo);

  final ProjectRepo _repo;

  @override
  Future<ShowEntry> show(String commitId) async => (await _repo.handle.show(revset: commitId)).single;

  @override
  Future<ChangeActions> changeActions(String changeId) => _repo.handle.changeActions(changeId);
}

/// [GraphSource] over an open [ProjectRepo] (`ProjectSession.repo`, Story 10.12): the worker's layout
/// (`RepoHandle.graphLayout`, read as a [BackendGraphLayout]), the card content (`commitContents` at the layout's
/// operation), its handle's events, `logDefaults` and `workspaceUpdateStale`.
class RepoGraphSource implements GraphSource {
  /// The source of [_repo].
  RepoGraphSource(this._repo);

  final ProjectRepo _repo;

  // The operations the landed layouts' revsets brought in, by operation: content reads pass them along. Kept per
  // operation (never cleared), so a dropped later reply or another revset at that operation loses none.
  // shortcut: unbounded — one small set per operation in a session; bound it if sessions grow past that.
  final _extraOperationIds = <String, Set<String>>{};

  @override
  Future<GraphLoad> layout(GraphRequest request) async {
    final RepoHandle handle = _repo.handle;
    final ({GraphTopologyView topology, GraphGridView grid}) reply;
    try {
      reply = await handle.graphLayout(
        revset: request.revset,
        anchors: request.anchors,
        utcOffsetMin: request.utcOffsetMin,
        prioritize: request.prioritize,
        shortPrefixes: request.shortPrefixes,
        mode: switch (request.mode) {
          GraphMode.free => LayoutMode.free,
          GraphMode.compact => LayoutMode.compact,
        },
        order: switch (request.order) {
          GraphLaneOrder.compact => LaneOrder.compact,
          GraphLaneOrder.greedy => LaneOrder.greedy,
        },
        stacks: request.stacks,
        expandedKeys: request.expandedKeys.toList(),
        collapsedKeys: request.collapsedKeys.toList(),
        keepOpenKeys: request.keepOpenKeys.toList(),
      );
    } on LayoutContractException catch (error) {
      // The caption shows only the code: the rule and its message go to the log.
      _log.severe('the layout engine refused the topology: $error');
      throw layoutContractFailure(error);
    }
    final layout = BackendGraphLayout(reply.topology, reply.grid, utcOffsetMinutes: request.utcOffsetMin);
    _extraOperationIds
        .putIfAbsent(reply.topology.operationId, () => <String>{})
        .addAll(reply.topology.extraOperationIds);
    return GraphLoad(layout, warnings: reply.topology.warnings, precondition: handle.lastPrecondition);
  }

  @override
  Future<Map<String, GraphCommitContent>> content(String? operationId, List<String> commitIds) async {
    if (operationId == null || commitIds.isEmpty) {
      return const <String, GraphCommitContent>{};
    }
    final WarnedList<CommitContent> page = await _repo.handle.commitContents(
      operationId: operationId,
      commitIds: commitIds,
      extraOperationIds: _extraOperationIds[operationId]?.toList() ?? const <String>[],
    );
    return <String, GraphCommitContent>{for (final CommitContent c in page) c.commitId: graphCommitContentOf(c)};
  }

  @override
  Stream<RepoEvent> get events => _repo.events;

  @override
  Future<LogDefaults> logDefaults() => _repo.handle.logDefaults();

  @override
  Future<StaleRecovery> updateStale() => _repo.handle.workspaceUpdateStale();

  @override
  Future<ShowEntry> show(String commitId) async => (await _repo.handle.show(revset: commitId)).single;
}

/// A broken layout-input contract as the model's error caption shows it (`ffi.unknown`, Story 10.12): the engine
/// refused the topology, which only a backend bug produces, so Retry is all the user can do.
ZanshinFfiException layoutContractFailure(LayoutContractException error) =>
    ZanshinFfiException('ffi.unknown', '${error.rule}: ${error.message}');

/// A card's content from the worker's [content]: the subject is the description's first line (jj's
/// `description.first_line()`), an undecidable `empty` (a merge read outside its index) reads as not empty.
GraphCommitContent graphCommitContentOf(CommitContent content) {
  final String description = content.description;
  final int newline = description.indexOf('\n');
  final String line = newline < 0 ? description : description.substring(0, newline);
  return GraphCommitContent(
    // Rust's `lines()` drops a CRLF's `\r` too.
    subject: line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
    description: description,
    authorName: content.authorName,
    authorEmail: content.authorEmail,
    empty: content.empty ?? false,
    conflict: content.conflict,
    timestampMs: content.committerTimestampMillis,
  );
}

/// What the graph search reads (Story 10.21). Only counts, finds and content are pinned to the shown layout's
/// operation; `bookmarks()`, `files()` and `userEmail()` read the live repository. A failed call throws
/// [ZanshinFfiException].
abstract interface class GraphSearchSource {
  /// How many commits each of [expressions] denotes at [operationId], at most [cap] each (9.25).
  Future<RevsetCounts> revsetCounts(String operationId, List<String> expressions, {required int cap});

  /// At most [limit] commits [expression] denotes at [operationId] (9.25).
  Future<FoundChanges> findChanges(
    String operationId,
    String expression, {
    required int limit,
    required String shortPrefixes,
  });

  /// `jj bookmark list`: the local bookmarks and their tracked remotes.
  Future<List<Bookmark>> bookmarks();

  /// The paths of @'s tree (`jj file list`), as the CLI's `jj log` path completion reads them.
  Future<List<String>> files();

  /// `user.email`, or null when it is unset.
  Future<String?> userEmail();

  /// The content of [commitIds] at [operationId], keyed by commit id (as [GraphSource.content]).
  Future<Map<String, GraphCommitContent>> content(String? operationId, List<String> commitIds);
}

/// [GraphSearchSource] over an open [ProjectRepo]'s handle; `user.email` and the content are the passed functions
/// (`configGet` runs on the worker only; the project window passes its [RepoGraphSource.content]).
class RepoGraphSearchSource implements GraphSearchSource {
  /// The search reads of [_repo].
  RepoGraphSearchSource(this._repo, {required this._userEmail, required this._content});

  final ProjectRepo _repo;
  final Future<String?> Function() _userEmail;
  final Future<Map<String, GraphCommitContent>> Function(String? operationId, List<String> commitIds) _content;

  @override
  Future<RevsetCounts> revsetCounts(String operationId, List<String> expressions, {required int cap}) =>
      _repo.handle.revsetCounts(operationId, expressions, cap: cap);

  @override
  Future<FoundChanges> findChanges(
    String operationId,
    String expression, {
    required int limit,
    required String shortPrefixes,
  }) => _repo.handle.findChanges(operationId, expression, limit: limit, shortPrefixes: shortPrefixes);

  @override
  Future<List<Bookmark>> bookmarks() => _repo.handle.bookmarks();

  @override
  Future<List<String>> files() async => <String>[
    // No revision: the CLI's `-r` default @ (the handle takes a change id there, never the revset `@`).
    for (final FileEntry entry in await _repo.handle.fileList()) entry.path,
  ];

  @override
  Future<String?> userEmail() => _userEmail();

  @override
  Future<Map<String, GraphCommitContent>> content(String? operationId, List<String> commitIds) =>
      _content(operationId, commitIds);
}
