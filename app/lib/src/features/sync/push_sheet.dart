// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../shell/calm_controller.dart';
import '../shell/shell_scope.dart';
import 'push_sheet_model.dart';
import 'remote_sync.dart';
import 'sync_model.dart';

/// Mounts the Push sheet of [sync] over the window while one is open (Story 11.8): a [ZsSheet] in the root overlay,
/// around [child] (the graph slot — not glass, so no glass mounts inside other glass). While it shows — its exit
/// included — it holds the shell's calm scrolling (I1), released when it closes or this host unmounts.
class PushSheetHost extends StatefulWidget {
  /// The host of [sync]'s sheet around [child].
  const PushSheetHost({required this.sync, required this.child, super.key});

  /// The open repository's sync.
  final SyncModel sync;

  /// What the host wraps.
  final Widget child;

  @override
  State<PushSheetHost> createState() => _PushSheetHostState();
}

class _PushSheetHostState extends State<PushSheetHost> {
  final _portal = OverlayPortalController();
  PushSheetModel? _shown;
  CalmHold? _hold;

  @override
  void initState() {
    super.initState();
    widget.sync.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didUpdateWidget(PushSheetHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sync != widget.sync) {
      oldWidget.sync.removeListener(_sync);
      widget.sync.addListener(_sync);
      _sync();
    }
  }

  @override
  void dispose() {
    widget.sync.removeListener(_sync);
    _hold?.release();
    super.dispose();
  }

  void _sync() {
    if (!mounted) {
      return;
    }
    final PushSheetModel? sheet = widget.sync.pushSheet;
    if (identical(sheet, _shown)) {
      return;
    }
    setState(() => _shown = sheet);
    if (sheet == null) {
      _hold?.release();
      _hold = null;
      _portal.hide();
    } else {
      _hold ??= ShellScope.maybeOf(context)?.openSurface();
      _portal.show();
    }
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayLocation: OverlayChildLocation.rootOverlay,
    overlayChildBuilder: (context) {
      final PushSheetModel? sheet = _shown;
      return sheet == null
          ? const SizedBox.shrink()
          : Positioned.fill(
              child: PushSheet(model: sheet, onClosed: widget.sync.pushSheetClosed),
            );
    },
    child: widget.child,
  );
}

/// The Push sheet (Story 11.8 item 7; DS components/push/PushDialog.{jsx,prompt.md}; push.css), over [model]: the
/// remote chips, the rows with their per-remote lines, the bulk choices, the change row, the notes, and the footer's
/// exact command with Cancel and the gold Push (Done after a partial push). Focus starts on Push; ↩ pushes except from
/// the name field (in done it is Done); Esc and Cancel cancel, not while pushing; a click beside it does nothing.
class PushSheet extends StatefulWidget {
  /// The sheet of [model]; [onClosed] runs once its exit ends.
  const PushSheet({required this.model, this.onClosed, super.key});

  /// The sheet's state.
  final PushSheetModel model;

  /// Runs once the exit ends.
  final VoidCallback? onClosed;

  /// The sheet's width (DS PushDialog.jsx:60).
  static const double width = 560;

  @override
  State<PushSheet> createState() => _PushSheetState();
}

class _PushSheetState extends State<PushSheet> {
  final _push = FocusNode(debugLabel: 'Push');
  final _name = ZsTextEditingController();
  final _nameFocus = FocusNode(debugLabel: 'Push bookmark name');
  final _scroll = ScrollController();
  String? _generated;

  @override
  void dispose() {
    _push.dispose();
    _name.dispose();
    _nameFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _enter() {
    final PushSheetModel model = widget.model;
    if (model.phase == PushSheetPhase.done) {
      model.done();
    } else if (!_nameFocus.hasFocus) {
      unawaited(model.push());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final PushSheetModel model = widget.model;
      final String? generated = model.generatedName;
      if (generated != _generated && !model.named) {
        _generated = generated;
        _name.text = generated ?? '';
      }
      final AppLocalizations strings = context.l10n;
      return ZsSheet(
        semanticLabel: strings.pushSheetTitle,
        onCancel: model.cancel,
        busy: model.phase == PushSheetPhase.pushing,
        closing: model.closing,
        onClosed: widget.onClosed,
        initialFocus: _push,
        width: PushSheet.width,
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.enter): _enter,
            const SingleActivator(LogicalKeyboardKey.numpadEnter): _enter,
          },
          child: Semantics(
            identifier: 'push-sheet',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _header(context, model),
                Flexible(
                  child: ZsScrollArea(
                    controller: _scroll,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(18, 2, 18, 16),
                      child: _body(context, model),
                    ),
                  ),
                ),
                _footer(context, model),
              ],
            ),
          ),
        ),
      );
    },
  );

  // ---- header ----

  Widget _header(BuildContext context, PushSheetModel model) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final ready = model.phase == PushSheetPhase.ready;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      child: Row(
        spacing: 12,
        children: <Widget>[
          Text(
            strings.pushSheetTitle,
            style: ZsType.control.copyWith(
              fontSize: ZsType.fsLg,
              fontWeight: FontWeight.w600,
              fontVariations: const <FontVariation>[FontVariation.weight(600)],
              color: colors.text,
            ),
          ),
          const Spacer(),
          Text(
            strings.pushSheetTo,
            style: ZsType.body.copyWith(fontSize: ZsType.fsMd, color: colors.textDim),
          ),
          Flexible(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.end,
              children: <Widget>[
                for (final String remote in model.remoteNames)
                  ZsTooltip(
                    message: model.defaultRemotes.contains(remote)
                        ? strings.pushSheetRemoteDefault
                        : strings.pushSheetRemoteFlag,
                    cmd: model.defaultRemotes.contains(remote) ? null : '--remote $remote', // l10n-ignore: jj flag
                    child: ZsChip(
                      label: remote,
                      mono: true,
                      size: ZsChipSize.sm,
                      on: model.chosen.contains(remote),
                      onChanged: ready ? (_) => model.toggleRemote(remote) : null,
                      identifier: 'push-remote-$remote',
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- body ----

  Widget _body(BuildContext context, PushSheetModel model) {
    final AppLocalizations strings = context.l10n;
    final done = model.phase == PushSheetPhase.done;
    final List<String> remotes = model.chosen;
    final bool hasTags = model.rows.any((key) => key.kind == PushRefKind.tag);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 14,
      children: <Widget>[
        if (model.planError case final ZanshinFfiException error)
          _Note(text: error.context ?? error.code, tone: _NoteTone.error, identifier: 'push-plan-error'),
        if (model.pushError case final ZanshinFfiException error)
          _Note(text: error.context ?? error.code, tone: _NoteTone.error, identifier: 'push-error'),
        if (done) _doneNote(context, model),
        if (model.config.signOnPush) _Note(text: strings.pushSheetSigning, identifier: 'push-signing'),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 7,
          children: <Widget>[
            _sectionHeader(context, model, hasTags: hasTags, done: done),
            if (done)
              _List(
                children: <Widget>[for (final PushRowKey key in _resultRows(model)) _resultRow(context, model, key)],
              )
            else if (model.rows.isNotEmpty)
              _List(children: <Widget>[for (final PushRowKey key in model.rows) _row(context, model, key)]),
          ],
        ),
        if (model.change != null && !done) _changeRow(context, model),
        if (!done && model.emptyRemotes.isNotEmpty)
          _Note(text: strings.pushSheetEmptyRemotes(model.emptyRemotes.join(', ')), identifier: 'push-empty-remotes'),
        if (!done && model.phase == PushSheetPhase.ready && model.empty && remotes.isNotEmpty)
          const _Quiet(text: 'Nothing changed.', identifier: 'push-nothing'), // l10n-ignore: jj's text
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, PushSheetModel model, {required bool hasTags, required bool done}) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final ready = model.phase == PushSheetPhase.ready;
    final String remotes = model.chosen.join(', ');
    final String? revset = model.config.gitPushRevset;
    Widget bulk(PushMode mode, String label, String tooltip, {String? cmd}) => ZsTooltip(
      message: tooltip,
      cmd: cmd,
      child: ZsChip(
        label: label,
        size: ZsChipSize.sm,
        on: model.mode == mode,
        onChanged: ready ? (_) => model.setMode(mode) : null,
        identifier: 'push-mode-${mode.name}',
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        spacing: 12,
        children: <Widget>[
          Expanded(
            child: Text(
              (hasTags ? strings.pushSheetBookmarksAndTags : strings.pushSheetBookmarks).toUpperCase(),
              style: ZsType.body.copyWith(
                fontSize: ZsType.fsSm,
                fontWeight: FontWeight.w600,
                fontVariations: const <FontVariation>[FontVariation.weight(600)],
                color: colors.textDim,
              ),
            ),
          ),
          if (!done)
            Wrap(
              spacing: 2,
              children: <Widget>[
                bulk(
                  PushMode.bare,
                  strings.pushSheetBare,
                  revset == null
                      ? strings.pushSheetBareTooltipNoRevset(remotes)
                      : strings.pushSheetBareTooltip(revset, remotes),
                ),
                bulk(
                  PushMode.tracked,
                  strings.pushSheetTracked,
                  strings.pushSheetTracked,
                  cmd: '--tracked',
                ), // l10n-ignore: jj flag
                bulk(PushMode.all, strings.pushSheetAll, strings.pushSheetAll, cmd: '--all'), // l10n-ignore: jj flag
                bulk(
                  PushMode.deleted,
                  strings.pushSheetDeleted,
                  strings.pushSheetDeleted,
                  cmd: '--deleted',
                ), // l10n-ignore: jj flag
              ],
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, PushSheetModel model, PushRowKey key) {
    final AppLocalizations strings = context.l10n;
    final bool sent = model.sent(key);
    final bool tickable = model.tickable(key);
    final ready = model.phase == PushSheetPhase.ready;
    final PushRefusal? explicit = model.explicitRefusalOf(key);
    final PushCommitRejection? rejection = model.rejectionOf(key);
    final bool multi = model.chosen.length > 1;
    // The mode's skip, the same on every remote it skips on (jj's reason and hint); one remote's own stays on its line.
    final PushRefusal? skipped = model.chosen.map((remote) => model.skippedOn(key, remote)).nonNulls.firstOrNull;
    final subs = <Widget>[
      if (skipped != null && rejection == null)
        _Sub.refusal(skipped, identifier: 'push-row-${key.kind.name}-${key.name}-skipped'),
      if (model.mode == PushMode.custom && !sent && explicit != null)
        _Sub.refusal(explicit, identifier: 'push-row-${key.kind.name}-${key.name}-refused'),
      if (rejection != null) ..._rejection(context, model, rejection, inline: !multi),
    ];
    return _RowShell(
      identifier: 'push-row-${key.kind.name}-${key.name}',
      checkbox: ZsCheckbox(
        value: sent,
        label: key.kind == PushRefKind.tag ? '${strings.pushSheetTag} ${key.name}' : key.name,
        onChanged: ready && (sent || tickable) ? (_) => model.toggle(key) : null,
        disabledReason: explicit?.message ?? rejection?.message,
        identifier: 'push-row-${key.kind.name}-${key.name}-check',
      ),
      name: _Name(name: key.name, tag: key.kind == PushRefKind.tag),
      subs: subs,
      lines: <Widget>[
        for (final String remote in model.chosen)
          _RemoteLine(
            remote: multi ? remote : null,
            ref: model.refOn(key, remote),
            pill: switch (model.refOn(key, remote)) {
              null => (strings.pushSheetNotSent, _Tone.none),
              _ when model.skippedOn(key, remote) != null => (strings.pushSheetSkipped, _Tone.warn),
              _ when model.mode == PushMode.custom && !sent && explicit != null => (
                strings.pushSheetRefused,
                _Tone.warn,
              ),
              _ => null,
            },
          ),
      ],
      trailing: !multi && rejection != null ? _inlineAllow(context, model, rejection) : null,
    );
  }

  /// The commit check's lines: jj's message, or "Allowed · pushed with …"; the long chips under several reasons.
  List<Widget> _rejection(
    BuildContext context,
    PushSheetModel model,
    PushCommitRejection rejection, {
    required bool inline,
  }) {
    final List<PushAllow?> flags = rejection.reasons.map(PushAllow.of).toList();
    final bool allowed = flags.every((flag) => flag != null && model.allowed.contains(flag));
    final open = <PushAllow>[
      for (final PushAllow? flag in flags)
        if (flag != null && !model.allowed.contains(flag)) flag,
    ];
    final bool hard = flags.contains(null);
    return <Widget>[
      if (allowed)
        _Sub(
          text: context.l10n.pushSheetAllowedWith(flags.nonNulls.map((f) => f.flag).join(' ')),
          tone: _Tone.warn,
        )
      else
        _Sub(text: <String>[rejection.message, ...rejection.hints].join('\n'), tone: _Tone.warn),
      if (!hard && (open.length > 1 || (!inline && open.isNotEmpty)))
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[for (final PushAllow flag in open) _allowChip(context, model, flag, short: false)],
        ),
    ];
  }

  /// The one inline "Allow" chip, for a single allowable open reason.
  Widget? _inlineAllow(BuildContext context, PushSheetModel model, PushCommitRejection rejection) {
    final List<PushAllow?> flags = rejection.reasons.map(PushAllow.of).toList();
    final open = <PushAllow?>[
      for (final PushAllow? flag in flags)
        if (flag == null || !model.allowed.contains(flag)) flag,
    ];
    if (open.length != 1 || open.single == null) {
      return null;
    }
    return _allowChip(context, model, open.single!, short: true);
  }

  Widget _allowChip(BuildContext context, PushSheetModel model, PushAllow flag, {required bool short}) {
    final AppLocalizations strings = context.l10n;
    final String long = switch (flag) {
      PushAllow.emptyDescription => strings.pushSheetAllowEmptyDescription,
      PushAllow.private => strings.pushSheetAllowPrivate,
      PushAllow.conflicts => strings.pushSheetAllowConflicts,
    };
    return ZsTooltip(
      message: long,
      cmd: flag.flag,
      child: ZsChip(
        label: short ? strings.pushSheetAllow : long,
        size: ZsChipSize.sm,
        onChanged: model.phase == PushSheetPhase.ready ? (on) => model.setAllow(flag, on) : null,
        identifier: 'push-allow-${flag.name}',
      ),
    );
  }

  // ---- change row ----

  Widget _changeRow(BuildContext context, PushSheetModel model) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final PushChangeTarget target = model.change!;
    final ready = model.phase == PushSheetPhase.ready;
    final PushCommitRejection? rejection = model.changeRejection;
    final String? refusal = model.changeRefusal;
    final Widget? inline = rejection == null ? null : _inlineAllow(context, model, rejection);
    return Semantics(
      identifier: 'push-change',
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.flHover,
          borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusWell),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: <Widget>[
              ZsCheckbox(
                value: model.changeOn,
                label: strings.pushSheetChange(target.rev),
                onChanged: ready && (model.changeOn || model.changeTickable) ? model.setChange : null,
                disabledReason: refusal ?? rejection?.message,
                identifier: 'push-change-check',
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 7,
                  children: <Widget>[
                    Row(
                      spacing: 10,
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            strings.pushSheetChange(target.rev),
                            style: ZsType.body.copyWith(fontSize: ZsType.fsBase, color: colors.text),
                          ),
                        ),
                        ?inline,
                      ],
                    ),
                    if (refusal != null) _Sub(text: refusal, tone: _Tone.warn),
                    if (rejection != null) ..._rejection(context, model, rejection, inline: true),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 280),
                      child: ZsTextField(
                        controller: _name,
                        focusNode: _nameFocus,
                        mono: true,
                        label: strings.pushSheetChangeName,
                        enabled: ready && model.changeOn,
                        error: model.changeOn && model.named ? model.checkError : null,
                        identifier: 'push-change-name',
                        onChanged: model.setName,
                      ),
                    ),
                    _Sub(text: model.named ? strings.pushSheetChangeNamed : strings.pushSheetChangeGenerated),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- done ----

  List<PushRowKey> _resultRows(PushSheetModel model) {
    final seen = <PushRowKey>{};
    return <PushRowKey>[
      for (final PushRemote remote in model.result?.remotes ?? const <PushRemote>[])
        for (final PushRef ref in remote.refs)
          if (ref.path == PushPath.push && seen.add((kind: ref.kind, name: ref.name))) (kind: ref.kind, name: ref.name),
    ];
  }

  Widget _resultRow(BuildContext context, PushSheetModel model, PushRowKey key) {
    final AppLocalizations strings = context.l10n;
    final bool multi = (model.result?.remotes.length ?? 0) > 1;
    final lines = <Widget>[];
    final subs = <Widget>[];
    for (final PushRemote remote in model.result?.remotes ?? const <PushRemote>[]) {
      final PushRef? ref = remote.refs.where((r) => r.kind == key.kind && r.name == key.name).firstOrNull;
      if (ref == null) {
        continue;
      }
      final (String, _Tone) pill = switch (ref.status) {
        PushRefStatus.pushed => (strings.pushSheetPushed, _Tone.add),
        PushRefStatus.leaseRejected => (strings.pushSheetMovedOn(remote.name), _Tone.warn),
        PushRefStatus.remoteRejected => (strings.pushSheetRejected, _Tone.error),
        PushRefStatus.unexported => (strings.pushSheetUnexported, _Tone.warn),
        PushRefStatus.notReached => (strings.pushSheetNotReached, _Tone.none),
      };
      lines.add(_RemoteLine(remote: multi ? remote.name : null, ref: ref, pill: pill));
      if (ref.statusReason case final String reason) {
        subs.add(_Sub(text: reason, tone: ref.status == PushRefStatus.remoteRejected ? _Tone.error : _Tone.warn));
      }
    }
    return _RowShell(
      identifier: 'push-result-${key.kind.name}-${key.name}',
      checkbox: ZsCheckbox(value: false, label: key.name, identifier: 'push-result-${key.kind.name}-${key.name}-check'),
      name: _Name(name: key.name, tag: key.kind == PushRefKind.tag),
      subs: subs,
      lines: lines,
    );
  }

  Widget _doneNote(BuildContext context, PushSheetModel model) {
    final AppLocalizations strings = context.l10n;
    final GitPushResult result = model.result!;
    final PushFailure? failure = result.failure;
    final PushRemote? stopped = result.remotes.where((remote) => remote.error != null).firstOrNull;
    final earlier = <String>[
      for (final PushRemote remote in result.remotes)
        if (remote.finished && remote != stopped) remote.name,
    ];
    final String text = <String>[
      ?failure?.message,
      ?failure?.hint,
      if (stopped != null && earlier.isEmpty) strings.pushSheetStoppedAtFirst(stopped.name),
      if (stopped != null && earlier.isNotEmpty) strings.pushSheetStoppedAt(stopped.name, earlier.join(', ')),
      if (stopped?.error case final String error) error,
      if (result.recorded) strings.pushSheetRecorded else strings.pushSheetNotRecorded,
    ].join('\n');
    return _Note(
      text: text,
      tone: stopped != null ? _NoteTone.error : _NoteTone.warn,
      identifier: 'push-done-note',
    );
  }

  // ---- footer ----

  Widget _footer(BuildContext context, PushSheetModel model) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final PushSheetPhase phase = model.phase;
    final done = phase == PushSheetPhase.done;
    final pushing = phase == PushSheetPhase.pushing;
    final String? checkError = model.changeOn && model.named ? null : model.checkError;
    final bool showCommand = !model.empty || done;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.flBorder)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 10,
          children: <Widget>[
            if (pushing)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 8,
                children: <Widget>[
                  LayoutBuilder(
                    builder: (context, constraints) => ZsProgressBar(
                      value: model.progress,
                      width: constraints.maxWidth,
                      label: strings.pushSheetProgress,
                      identifier: 'push-progress',
                    ),
                  ),
                  Text(
                    strings.pushSheetPushing(model.chosen.join(', ')),
                    style: ZsType.body.copyWith(fontSize: ZsType.fsMd, color: colors.textMuted),
                  ),
                ],
              )
            else if (showCommand && model.phase != PushSheetPhase.loading)
              Semantics(
                label: strings.pushSheetCommand,
                identifier: 'push-command',
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.codeBg,
                    border: Border.all(color: colors.flBorder),
                    borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusMd),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Text(
                      model.request.command,
                      key: const ValueKey<String>('push-command-text'),
                      style: ZsType.id.copyWith(color: colors.text, height: 1.55),
                    ),
                  ),
                ),
              ),
            if (checkError != null && !done) _Sub(text: checkError, tone: _Tone.error),
            Row(
              spacing: 8,
              children: <Widget>[
                Expanded(
                  child: Text(
                    done
                        ? strings.pushSheetRan
                        : model.checking || phase == PushSheetPhase.loading
                        ? strings.pushSheetChecking
                        : strings.pushSheetChecked,
                    style: ZsType.body.copyWith(fontSize: ZsType.fsSm, color: colors.textDim),
                  ),
                ),
                if (done)
                  ZsButton(
                    label: strings.pushSheetDone,
                    variant: ZsButtonVariant.primary,
                    size: ZsButtonSize.md,
                    focusNode: _push,
                    identifier: 'push-done',
                    onPressed: model.done,
                  )
                else ...<Widget>[
                  ZsButton(
                    label: strings.pushSheetCancel,
                    size: ZsButtonSize.md,
                    identifier: 'push-cancel',
                    onPressed: pushing ? null : model.cancel,
                  ),
                  ZsButton(
                    label: strings.pushSheetPush,
                    variant: ZsButtonVariant.primary,
                    size: ZsButtonSize.md,
                    busy: pushing,
                    focusNode: _push,
                    identifier: 'push-submit',
                    onPressed: model.canPush || pushing ? () => unawaited(model.push()) : null,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _Tone { quiet, add, warn, error, none }

enum _NoteTone { warn, error }

Color _toneColor(ZsColors colors, _Tone tone) => switch (tone) {
  _Tone.quiet => colors.textMuted,
  _Tone.add => colors.add,
  _Tone.warn => colors.warn,
  _Tone.error => colors.rem,
  _Tone.none => colors.textDim,
};

/// The tone of jj's dry-run words: add green, forward quiet, backward, sideways and delete warn.
_Tone _actionTone(String action) {
  if (action.startsWith('add')) {
    return _Tone.add;
  }
  if (action.startsWith('move forward')) {
    return _Tone.quiet;
  }
  return _Tone.warn;
}

/// The rows' well (DS push.css:20).
class _List extends StatelessWidget {
  const _List({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: ZsColors.of(context).flHover,
      borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusWell),
    ),
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 1, children: children),
    ),
  );
}

/// One row: the checkbox, the name with its notes, one line per remote, and an inline chip at the end.
class _RowShell extends StatelessWidget {
  const _RowShell({
    required this.identifier,
    required this.checkbox,
    required this.name,
    required this.subs,
    required this.lines,
    this.trailing,
  });

  final String identifier;
  final Widget checkbox;
  final Widget name;
  final List<Widget> subs;
  final List<Widget> lines;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Semantics(
    identifier: identifier,
    container: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: <Widget>[
          Padding(padding: const EdgeInsets.only(top: 2), child: checkbox),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 3,
              children: <Widget>[
                Row(
                  spacing: 10,
                  children: <Widget>[
                    Expanded(child: name),
                    ?trailing,
                  ],
                ),
                ...subs,
                ...lines,
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _Name extends StatelessWidget {
  const _Name({required this.name, required this.tag});

  final String name;
  final bool tag;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return Row(
      spacing: 7,
      children: <Widget>[
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ZsType.id.copyWith(
              fontSize: ZsType.fsBase,
              fontWeight: FontWeight.w500,
              fontVariations: const <FontVariation>[FontVariation.weight(500)],
              color: colors.text,
            ),
          ),
        ),
        if (tag)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colors.borderStrong),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              child: Text(
                context.l10n.pushSheetTag,
                style: ZsType.body.copyWith(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  fontVariations: const <FontVariation>[FontVariation.weight(600)],
                  color: colors.textMuted,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One remote's line under a row: the remote (with several), jj's words for the move, and a pill.
class _RemoteLine extends StatelessWidget {
  const _RemoteLine({required this.remote, required this.ref, this.pill});

  final String? remote;
  final PushRef? ref;
  final (String, _Tone)? pill;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final String? action = ref?.action;
    final TextStyle mono = ZsType.id.copyWith(fontSize: ZsType.fsSm);
    final (String, _Tone)? pill = this.pill;
    return Row(
      spacing: 10,
      children: <Widget>[
        if (remote case final String remote) Text(remote, style: mono.copyWith(color: colors.textDim)),
        Expanded(
          child: Text(
            action ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: mono.copyWith(color: action == null ? colors.textDim : _toneColor(colors, _actionTone(action))),
          ),
        ),
        if (pill != null)
          Text(
            pill.$1,
            style: ZsType.body.copyWith(
              fontSize: ZsType.fsSm,
              fontWeight: FontWeight.w500,
              color: _toneColor(colors, pill.$2),
            ),
          ),
      ],
    );
  }
}

/// A note line under a row's name.
class _Sub extends StatelessWidget {
  const _Sub({required this.text, this.tone = _Tone.none}) : identifier = null;

  /// jj's refusal with its hint.
  _Sub.refusal(PushRefusal refusal, {this.identifier})
    : text = <String>[refusal.message, ?refusal.hint].join('\n'),
      tone = _Tone.warn;

  final String text;
  final _Tone tone;
  final String? identifier;

  @override
  Widget build(BuildContext context) => Semantics(
    identifier: identifier,
    child: Text(
      text,
      style: ZsType.body.copyWith(
        fontSize: ZsType.fsSm,
        height: 1.4,
        color: _toneColor(ZsColors.of(context), tone),
      ),
    ),
  );
}

/// A centred quiet sentence (DS push.css:66).
class _Quiet extends StatelessWidget {
  const _Quiet({required this.text, this.identifier});

  final String text;
  final String? identifier;

  @override
  Widget build(BuildContext context) => Semantics(
    identifier: identifier,
    liveRegion: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: ZsType.body.copyWith(fontSize: ZsType.fsMd, color: ZsColors.of(context).textDim),
      ),
    ),
  );
}

/// A note in the warn or error tone (DS push.css:60-65), announced.
class _Note extends StatelessWidget {
  const _Note({required this.text, this.tone = _NoteTone.warn, this.identifier});

  final String text;
  final _NoteTone tone;
  final String? identifier;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final error = tone == _NoteTone.error;
    return Semantics(
      identifier: identifier,
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: error ? colors.remBg : colors.warnBg,
          borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusMd),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 9,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: ZanshinIcon(
                  error ? ZI.alert : ZI.conflict,
                  size: ZsIconSize.md,
                  color: error ? colors.rem : colors.warn,
                ),
              ),
              Expanded(
                child: Text(
                  text,
                  style: ZsType.body.copyWith(fontSize: ZsType.fsMd, height: 1.45, color: colors.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
