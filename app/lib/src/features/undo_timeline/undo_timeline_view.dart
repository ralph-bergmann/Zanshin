// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart' show Operation;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../graph/graph_ports.dart';
import '../projects/relative_time.dart';
import '../shell/shell_controller.dart';
import 'undo_timeline_model.dart';

/// The rail's "Undo Timeline" item (Story 11.9): [model]'s hover preview and pinned panel; [actions] is the runner
/// (null until 10.12 mounts the graph's view model: every action then shows disabled with its command). No count
/// (design question (b)).
ShellRailItem undoTimelineRailItem(AppLocalizations strings, UndoTimelineModel model, {UndoTimelineActions? actions}) =>
    ShellRailItem(
      id: 'undo',
      label: strings.undoTimelineTitle,
      icon: ZI.undo,
      scrolls: true,
      preview: UndoTimelinePreview(model: model),
      panel: UndoTimelinePanel(model: model, actions: actions),
    );

/// The Undo Timeline's hover preview (DS ui_kits/desktop/kit.css:68-72, `.zk-ops`/`.zk-op`; chrome.jsx:133): the 3
/// newest operations, "description · when" on one line — the description mono 11.5 in `--text-muted`, ellipsized, the
/// relative time `--fs-sm` in `--text-dim` — or "Working copy is stale".
class UndoTimelinePreview extends StatelessWidget {
  /// The preview of [model].
  const UndoTimelinePreview({required this.model, super.key});

  /// The timeline's state.
  final UndoTimelineModel model;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final AppLocalizations strings = context.l10n;
      final ZsColors colors = ZsColors.of(context);
      if (_note(strings, model) case final String note) {
        return _Note(note);
      }
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final Operation operation in model.operations.take(3))
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  spacing: 10,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        operation.rootOp ? 'root()' : _firstLine(operation.description), // l10n-ignore: jj's text
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: ZsType.id.copyWith(color: colors.textMuted),
                      ),
                    ),
                    if (!operation.rootOp)
                      Text(
                        lastOpenedLabel(strings, _time(operation), model.now),
                        style: ZsType.meta.copyWith(color: colors.textDim),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// The Undo Timeline's pinned panel (Story 11.9): the operation log as a lazy list (the panel's scroll area), newest
/// first, a page more read as the end comes near. Rows: a dot (the current operation `--accent-line`, decision 16.43;
/// the others `--text-faint`), the description's first line, the `args` tag in mono when the operation has one
/// (Claude's proposal, prototype defect 76), the relative time and the workspace; snapshots at .55. The newest row
/// carries Undo and Redo; the others show Restore to here and Show changes on hover or keyboard focus. A disabled
/// button names its reason, its tooltip the full jj command (decisions 16.39, 16.44).
class UndoTimelinePanel extends StatelessWidget {
  /// The panel of [model], acting through [actions].
  const UndoTimelinePanel({required this.model, this.actions, super.key});

  /// The timeline's state.
  final UndoTimelineModel model;

  /// The runner, or null.
  final UndoTimelineActions? actions;

  /// The list's padding: `.zk-ops` 0 6, the panel body's 10 at the bottom (DS kit.css:68, 87).
  static const _padding = EdgeInsets.fromLTRB(6, 0, 6, 10);

  /// From this many rows before the end, the next page is read.
  static const _ahead = 10;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable?>[model, actions]),
    builder: (context, _) {
      final AppLocalizations strings = context.l10n;
      if (_note(strings, model) case final String note) {
        return ListView(primary: true, padding: _padding, children: <Widget>[_Note(note)]);
      }
      final List<Operation> operations = model.operations;
      final String? failed = model.error == null ? null : _failed(strings, model);
      return ListView.builder(
        primary: true,
        padding: _padding,
        itemCount: operations.length + (failed == null ? 0 : 1),
        itemBuilder: (context, index) {
          if (index >= operations.length) {
            return _Note(failed!);
          }
          if (index >= operations.length - _ahead) {
            WidgetsBinding.instance.addPostFrameCallback((_) => model.loadMore());
          }
          return _OperationRow(
            key: ValueKey<String>(operations[index].id),
            operation: operations[index],
            index: index,
            model: model,
            actions: actions,
          );
        },
      );
    },
  );
}

/// What shows instead of the rows: "Working copy is stale" (no Retry, decision 16.28), or a failed read with no rows.
String? _note(AppLocalizations strings, UndoTimelineModel model) {
  if (model.stale) {
    return strings.staleTitle;
  }
  if (model.error != null && model.operations.isEmpty) {
    return _failed(strings, model);
  }
  return null;
}

String _failed(AppLocalizations strings, UndoTimelineModel model) =>
    strings.undoTimelineLoadFailed(model.error!.context ?? model.error!.code);

String _firstLine(String text) {
  final int end = text.indexOf('\n');
  return end < 0 ? text : text.substring(0, end);
}

DateTime _time(Operation operation) => DateTime.fromMillisecondsSinceEpoch(operation.timestampMillis);

/// A line of `--fs-sm` text in `--text-dim` (DS kit.css:68, `.zk-co-more`'s look).
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    child: Text(text, style: ZsType.meta.copyWith(color: ZsColors.of(context).textDim)),
  );
}

class _OperationRow extends StatefulWidget {
  const _OperationRow({
    required this.operation,
    required this.index,
    required this.model,
    required this.actions,
    super.key,
  });

  final Operation operation;
  final int index;
  final UndoTimelineModel model;
  final UndoTimelineActions? actions;

  @override
  State<_OperationRow> createState() => _OperationRowState();
}

class _OperationRowState extends State<_OperationRow> {
  var _hovered = false;
  var _focused = false;

  bool get _newest => widget.index == 0;

  /// Whether Restore to here can run now.
  bool get _restorable => !_newest && !widget.operation.rootOp && (widget.actions?.actionsEnabled ?? false);

  void _restore() => unawaited(widget.actions!.restoreOperation(shortOperationId(widget.operation.id)));

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final bool inactive = ZsAppearance.of(context).inactive;
    final Operation operation = widget.operation;
    final bool root = operation.rootOp;
    // jj op log shows the root as `root()` with no time (`format_root_operation`).
    final String description = root ? 'root()' : _firstLine(operation.description); // l10n-ignore: jj's text
    final String? args = operationArgs(operation);
    final String? when = root ? null : lastOpenedLabel(strings, _time(operation), widget.model.now);
    final String? workspace = operation.workspaceName;
    final String label = when == null
        ? description
        : workspace == null
        ? strings.undoTimelineRow(description, when)
        : strings.undoTimelineRowWorkspace(description, when, workspace);
    final bool shown = _newest || _hovered || _focused;
    final List<Widget> buttons = shown ? _buttons(strings) : const <Widget>[];
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        // The keyboard path to a row's hidden actions: Tab lands on the row, which shows them.
        canRequestFocus: !_newest,
        skipTraversal: _newest,
        includeSemantics: false,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _hovered && !inactive ? colors.flHover : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Semantics(
                  container: true,
                  identifier: 'undo-timeline-row-${widget.index}',
                  label: label,
                  // VoiceOver's path to Restore to here, which shows only on hover or keyboard focus.
                  customSemanticsActions: _restorable
                      ? <CustomSemanticsAction, VoidCallback>{
                          CustomSemanticsAction(label: strings.undoTimelineRestore): _restore,
                        }
                      : null,
                  child: ExcludeSemantics(
                    // The dot and the texts only: a snapshot row's enabled buttons must not look disabled.
                    child: Opacity(
                      opacity: operation.isSnapshot ? .55 : 1,
                      child: _texts(colors, description, args, when, workspace),
                    ),
                  ),
                ),
                if (buttons.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 15),
                    child: Wrap(spacing: 6, runSpacing: 4, children: buttons),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _texts(ZsColors colors, String description, String? args, String? when, String? workspace) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 8,
    children: <Widget>[
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: SizedBox.square(
          dimension: 7,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _newest ? colors.accentLine : colors.textFaint,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              description,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: ZsType.secondary.copyWith(color: colors.text),
            ),
            if (args != null)
              Text(
                args,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: ZsType.id.copyWith(color: colors.textMuted),
              ),
            if (when != null)
              Text(
                workspace == null ? when : '$when · $workspace',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: ZsType.meta.copyWith(color: colors.textDim),
              ),
          ],
        ),
      ),
    ],
  );

  List<Widget> _buttons(AppLocalizations strings) {
    final UndoTimelineActions? actions = widget.actions;
    final UndoTimelineModel model = widget.model;
    final Operation operation = widget.operation;
    final String? runner = actions == null
        ? strings.undoTimelineNoRunner
        : actions.actionsEnabled
        ? null
        : strings.undoTimelineBusy;
    if (_newest) {
      final Operation undoTarget = model.undoTarget(operation);
      final GraphLoggedOperation undone = loggedOperation(undoTarget);
      // Zanshin's own undo, else any undo-operation `jj redo` would take back (a CLI undo too).
      final Operation? redoTarget = actions?.redoable == null ? model.redoTarget(operation) : null;
      final String? undo =
          runner ??
          (undoTarget.rootOp
              ? 'Cannot undo root operation' // l10n-ignore: jj's own words (`jj undo`)
              : model.headOnRoot
              ? strings.undoTimelineRootParent
              : null);
      final String? redo =
          runner ?? (actions!.redoable == null && redoTarget == null ? strings.undoTimelineNothingToRedo : null);
      return <Widget>[
        _action(
          strings.undoTimelineUndo,
          GraphUndo(undone).command,
          'undo-timeline-undo',
          undo,
          () => unawaited(actions!.undoOperation(operation.id, undone)),
        ),
        _action(
          strings.undoTimelineRedo,
          GraphRedo(undone).command,
          'undo-timeline-redo',
          redo,
          () => unawaited(
            redoTarget == null
                ? actions!.redoLast()
                : actions!.redoOperation(operation.id, loggedOperation(redoTarget)),
          ),
        ),
      ];
    }
    final String short = shortOperationId(operation.id);
    final int n = widget.index;
    return <Widget>[
      if (!operation.rootOp)
        _action(
          strings.undoTimelineRestore,
          GraphOpRestore(short).command,
          'undo-timeline-restore-$n',
          runner,
          _restore,
        ),
      _action(
        strings.undoTimelineShowChanges,
        jjOpShowCommand(short),
        'undo-timeline-show-$n',
        strings.undoTimelineShowLater,
        () {},
      ),
    ];
  }

  /// A Zs button; disabled with [reason], its tooltip then the reason over the jj [command] (decisions 16.39, 16.44).
  static Widget _action(String label, String command, String identifier, String? reason, VoidCallback onPressed) =>
      ZsTooltip(
        message: reason ?? command,
        cmd: reason == null ? null : command,
        child: ZsButton(
          label: label,
          onPressed: reason == null ? onPressed : null,
          disabledReason: reason,
          identifier: identifier,
        ),
      );
}
