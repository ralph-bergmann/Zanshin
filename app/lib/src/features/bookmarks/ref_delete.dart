// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../graph/graph_ports.dart';
import '../graph/graph_view_model.dart';
import '../sync/remote_sync.dart';
import 'bookmark_list_model.dart';

/// jj's mirror of the colocated Git refs (`default_ignored_remote_name`, `../jj` v0.47.0 cli/src/cli_util.rs): never a
/// remote a deletion is pushed to.
const _gitRemote = 'git'; // l10n-ignore: jj's remote name

/// One Delete… of a bookmark or tag (Story 10.44): its [kind], [name] and the [remotes] that track it.
@immutable
class RefDeleteRequest {
  /// Delete… of [name], tracked on [remotes].
  const RefDeleteRequest({required this.kind, required this.name, this.remotes = const <String>[]});

  /// Delete… of [name] with the tracked remotes [rows] (a `--all-remotes` list) name; `git` is not a remote, and a
  /// tracked remote without a target (jj's "not created yet") does not hold it.
  factory RefDeleteRequest.of(RefKind kind, String name, Iterable<Bookmark> rows) => RefDeleteRequest(
    kind: kind,
    name: name,
    remotes: <String>[
      for (final Bookmark row in rows)
        if (row.kind case RemoteBookmark(:final String remoteName, tracked: true)
            when row.name == name && remoteName != _gitRemote && row.target != null)
          remoteName,
    ],
  );

  /// A bookmark or a tag.
  final RefKind kind;

  /// Its name.
  final String name;

  /// The remotes that track it; only a tracked remote makes the delete differ from a forget, and only a tracked one
  /// gets the deletion pushed (`find_bookmarks_to_push`, `../jj` v0.47.0 cli/src/commands/git/push.rs:1424-1456).
  final List<String> remotes;

  /// Whether the delete sheet asks where it goes.
  bool get asks => remotes.isNotEmpty;
}

/// Where a deleted ref goes (Story 10.44).
enum RefDeleteChoice {
  /// Only here — the remotes keep it.
  onlyHere,

  /// Here, and on the remotes when the deletion is pushed: the default.
  onPush,

  /// Here and on the remotes now.
  now,
}

/// The verbs one choice runs, in order: jj actions, then at most one push.
typedef RefDeleteSteps = ({List<GraphAction> actions, PushRequest? push});

/// What [choice] runs for [request]: "only here" forgets a bookmark, and untracks a tag on each remote before it
/// deletes it (jj 0.47 has no `tag forget`); "on push" deletes it; "now" deletes it and pushes the deletion to every
/// remote that tracks it.
RefDeleteSteps refDeleteSteps(RefDeleteRequest request, RefDeleteChoice choice) {
  final String name = request.name;
  final tag = request.kind == RefKind.tag;
  final GraphAction delete = tag ? GraphTagDelete(<String>[name]) : GraphBookmarkDelete(<String>[name]);
  return switch (choice) {
    RefDeleteChoice.onlyHere => (
      actions: tag
          ? <GraphAction>[for (final String remote in request.remotes) GraphTagUntrack(name, remote), delete]
          : <GraphAction>[GraphBookmarkForget(name)],
      push: null,
    ),
    RefDeleteChoice.onPush => (actions: <GraphAction>[delete], push: null),
    RefDeleteChoice.now => (
      actions: <GraphAction>[delete],
      push: PushRequest(
        remotes: request.remotes,
        mode: PushMode.custom,
        bookmarks: tag ? const <String>[] : <String>[name],
        tags: tag ? <String>[name] : const <String>[],
      ),
    ),
  };
}

/// [steps]' commands, one per verb, as the sheet shows them.
List<String> refDeleteCommands(RefDeleteSteps steps) => <String>[
  for (final GraphAction action in steps.actions) action.command,
  ?steps.push?.command,
];

/// Runs [steps] in order: each action through [run], the push through [push]; a step that does not end
/// [GraphActionDone] stops the rest. True when every step ran.
Future<bool> runRefDeleteSteps(
  RefDeleteSteps steps, {
  required Future<GraphActionResult> Function(GraphAction action) run,
  Future<bool> Function(PushRequest request)? push,
}) async {
  for (final GraphAction action in steps.actions) {
    if (await run(action) is! GraphActionDone) {
      return false;
    }
  }
  final PushRequest? request = steps.push;
  if (request == null) {
    return true;
  }
  return push != null && await push(request);
}

/// The one delete flow of a project's bookmarks and tags (Story 10.44): the views' Delete… and the card popover's go
/// through [delete]. Without a tracked remote the delete runs at once through [graph] (its toast offers Undo);
/// otherwise [pending] holds the request while [RefDeleteHost]'s sheet asks.
class RefDeleteFlow extends ChangeNotifier {
  /// The flow over [graph]'s runner; the "now" choice pushes through [push].
  RefDeleteFlow({required this.graph, this.push});

  /// The graph's view model: the runner of every verb.
  final GraphViewModel graph;

  /// `SyncModel.pushNow`: true when it pushed.
  final Future<bool> Function(PushRequest request)? push;

  RefDeleteRequest? _pending;

  /// The request the sheet asks about.
  RefDeleteRequest? get pending => _pending;

  /// Delete… of [request]'s ref.
  void delete(RefDeleteRequest request) {
    if (request.asks) {
      _pending = request;
      notifyListeners();
    } else {
      unawaited(run(request, RefDeleteChoice.onPush));
    }
  }

  /// Runs [choice]'s steps for [request].
  Future<bool> run(RefDeleteRequest request, RefDeleteChoice choice) =>
      runRefDeleteSteps(refDeleteSteps(request, choice), run: graph.run, push: push);

  /// The sheet's confirm: [choice] runs for the pending request.
  void confirm(RefDeleteChoice choice) {
    final RefDeleteRequest? request = _pending;
    if (request != null) {
      _pending = null;
      notifyListeners();
      unawaited(run(request, choice));
    }
  }

  /// The sheet's Cancel and Esc.
  void cancel() {
    if (_pending != null) {
      _pending = null;
      notifyListeners();
    }
  }
}

/// Shows [flow]'s delete sheet in the root overlay while it asks, and lets it leave with its exit.
class RefDeleteHost extends StatefulWidget {
  /// The host of [flow]'s sheet around [child].
  const RefDeleteHost({required this.flow, required this.child, super.key});

  /// The project's delete flow.
  final RefDeleteFlow flow;

  /// The subtree.
  final Widget child;

  @override
  State<RefDeleteHost> createState() => _RefDeleteHostState();
}

class _RefDeleteHostState extends State<RefDeleteHost> {
  final _portal = OverlayPortalController();
  RefDeleteRequest? _shown;
  var _closing = false;

  @override
  void initState() {
    super.initState();
    widget.flow.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  @override
  void didUpdateWidget(RefDeleteHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.flow, widget.flow)) {
      oldWidget.flow.removeListener(_changed);
      widget.flow.addListener(_changed);
      // An old project's sheet must not stay open: its Cancel would go to a flow nobody hears.
      WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
    }
  }

  @override
  void dispose() {
    widget.flow.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) {
      return;
    }
    final RefDeleteRequest? pending = widget.flow.pending;
    if (pending != null) {
      setState(() {
        _shown = pending;
        _closing = false;
      });
      _portal.show();
    } else if (_shown != null) {
      setState(() => _closing = true);
    }
  }

  void _closed() {
    _portal.hide();
    setState(() => _shown = null);
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayLocation: OverlayChildLocation.rootOverlay,
    overlayChildBuilder: (context) {
      final RefDeleteRequest? shown = _shown;
      if (shown == null) {
        return const SizedBox.shrink();
      }
      return Positioned.fill(
        child: RefDeleteSheet(
          key: ObjectKey(shown),
          request: shown,
          closing: _closing,
          onClosed: _closed,
          onCancel: widget.flow.cancel,
          onConfirm: widget.flow.confirm,
        ),
      );
    },
    child: widget.child,
  );
}

/// The delete sheet (Story 10.44): a destructive [ZsConfirmDialog] "Delete `name`?" whose body names the remotes and
/// offers the three [RefDeleteChoice]s as a radio group, the default the middle one; each choice shows its label, its
/// commands (mono, one per line) and its note, "now" in the danger tone. Delete (⌘↩) runs the chosen one.
class RefDeleteSheet extends StatefulWidget {
  /// The sheet of [request].
  const RefDeleteSheet({
    required this.request,
    required this.onConfirm,
    required this.onCancel,
    this.closing = false,
    this.onClosed,
    super.key,
  });

  /// What it asks about.
  final RefDeleteRequest request;

  /// Runs with the chosen choice.
  final ValueChanged<RefDeleteChoice> onConfirm;

  /// Runs on Cancel and Esc.
  final VoidCallback onCancel;

  /// Whether the sheet leaves.
  final bool closing;

  /// Runs once the exit completes.
  final VoidCallback? onClosed;

  @override
  State<RefDeleteSheet> createState() => _RefDeleteSheetState();
}

class _RefDeleteSheetState extends State<RefDeleteSheet> {
  RefDeleteChoice _choice = RefDeleteChoice.onPush;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final RefDeleteRequest request = widget.request;
    final String remotes = request.remotes.join(', '); // l10n-ignore: separator
    final tag = request.kind == RefKind.tag;
    return ZsConfirmDialog(
      title: strings.refDeleteTitle(request.name),
      confirmLabel: strings.refDeleteConfirm,
      identifier: 'ref-delete-sheet',
      closing: widget.closing,
      onClosed: widget.onClosed,
      onCancel: widget.onCancel,
      onConfirm: () {
        if (!widget.closing) {
          widget.onConfirm(_choice);
        }
      },
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: <Widget>[
          Text(tag ? strings.refDeleteBodyTag(remotes) : strings.refDeleteBodyBookmark(remotes)),
          Semantics(
            container: true,
            label: strings.refDeleteChoices,
            explicitChildNodes: true,
            child: RadioGroup<RefDeleteChoice>(
              groupValue: _choice,
              onChanged: (choice) => setState(() => _choice = choice ?? _choice),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 4,
                children: <Widget>[
                  for (final RefDeleteChoice choice in RefDeleteChoice.values)
                    _ChoiceRow(
                      choice: choice,
                      on: choice == _choice,
                      label: switch (choice) {
                        RefDeleteChoice.onlyHere => strings.refDeleteOnlyHere(remotes),
                        RefDeleteChoice.onPush => strings.refDeleteOnPush(remotes),
                        RefDeleteChoice.now => strings.refDeleteNow(remotes),
                      },
                      note: switch (choice) {
                        RefDeleteChoice.onlyHere =>
                          tag ? strings.refDeleteOnlyHereNoteTag(remotes) : strings.refDeleteOnlyHereNote(remotes),
                        RefDeleteChoice.onPush => strings.refDeleteOnPushNote,
                        RefDeleteChoice.now =>
                          tag ? strings.refDeleteNowNoteTag(remotes) : strings.refDeleteNowNoteBookmark(remotes),
                      },
                      commands: refDeleteCommands(refDeleteSteps(request, choice)),
                      onTap: () => setState(() => _choice = choice),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One choice (Refs Study `.rs-choice`): padding 10 12, radius `--radius-card`, `--fl-on` when chosen, `--fl-hover` on
/// hover; the radio, then the label (500 `--fs-control`, with the default mark), the commands (mono `--fs-sm`/1.5,
/// `--text-muted`) and the note (`--fs-id`/1.4, `--text-dim`); "now" in `--rem`.
class _ChoiceRow extends StatefulWidget {
  const _ChoiceRow({
    required this.choice,
    required this.on,
    required this.label,
    required this.note,
    required this.commands,
    required this.onTap,
  });

  final RefDeleteChoice choice;
  final bool on;
  final String label;
  final String note;
  final List<String> commands;
  final VoidCallback onTap;

  @override
  State<_ChoiceRow> createState() => _ChoiceRowState();
}

class _ChoiceRowState extends State<_ChoiceRow> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final danger = widget.choice == RefDeleteChoice.now;
    final bool inactive = ZsAppearance.of(context).inactive;
    return Semantics(
      container: true,
      identifier: 'ref-delete-choice-${widget.choice.name}',
      label: <String>[
        if (widget.choice == RefDeleteChoice.onPush)
          '${widget.label}, ${context.l10n.refDeleteDefault}'
        else
          widget.label,
        ...widget.commands,
        widget.note,
      ].join('. '), // l10n-ignore: separator
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: widget.onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: widget.on
                  ? colors.flOn
                  : _hovered && !inactive
                  ? colors.flHover
                  : null,
              borderRadius: BorderRadius.circular(metrics.radiusCard),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 10,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: ZsRadio<RefDeleteChoice>(value: widget.choice, rowHovered: _hovered),
                  ),
                  Expanded(
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 4,
                        children: <Widget>[
                          Text.rich(
                            TextSpan(
                              children: <InlineSpan>[
                                TextSpan(text: widget.label),
                                if (widget.choice == RefDeleteChoice.onPush)
                                  TextSpan(
                                    text: '  ${context.l10n.refDeleteDefault}',
                                    style: ZsType.meta.copyWith(fontSize: ZsType.fsXs, color: colors.textFaint),
                                  ),
                              ],
                            ),
                            style: ZsType.control.copyWith(height: 1.35, color: danger ? colors.rem : colors.text),
                          ),
                          Text(
                            widget.commands.join('\n'),
                            style: ZsType.code.copyWith(height: ZsType.lhUi, color: colors.textMuted),
                          ),
                          Text(
                            widget.note,
                            style: ZsType.meta.copyWith(
                              fontSize: ZsType.fsId,
                              height: 1.4,
                              color: danger ? colors.rem : colors.textDim,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
