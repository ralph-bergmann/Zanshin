// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../shell/shell_toast.dart';
import 'graph_layout.dart';
import 'graph_ports.dart';
import 'graph_view_model.dart';

/// The graph's toasts (Story 10.23): every published [GraphViewModel.outcome] that toasts per [graphOutcomeEntry], and
/// each new stale-recovery result or failure of [GraphViewModel.updateStale], shown through [toasts]. 10.12 creates it
/// where it mounts the graph in the project window; [dispose] stops listening.
class GraphToasts {
  /// The toasts of [model] in [toasts].
  GraphToasts(this.model, this.toasts) : _recovery = model.lastStaleRecovery, _failure = model.staleUpdateError {
    model.outcome.addListener(_outcome);
    model.addListener(_changed);
  }

  /// The graph's view model.
  final GraphViewModel model;

  /// The window's toast queue.
  final ShellToasts toasts;

  StaleRecovery? _recovery;
  ZanshinFfiException? _failure;
  ShellToastEntry? _shown;

  void _show(ShellToastEntry entry) => toasts.show(_shown = entry);

  void _outcome() {
    final GraphOutcome? outcome = model.outcome.value;
    final ShellToastEntry? entry = outcome == null ? null : graphOutcomeEntry(outcome, model: model, toasts: toasts);
    if (entry != null) {
      _show(entry);
    }
  }

  void _changed() {
    final StaleRecovery? recovery = model.lastStaleRecovery;
    if (!identical(recovery, _recovery)) {
      _recovery = recovery;
      if (recovery != null) {
        _show(_staleResultEntry(recovery));
      }
    }
    final ZanshinFfiException? failure = model.staleUpdateError;
    if (!identical(failure, _failure)) {
      _failure = failure;
      if (failure != null) {
        _show(_staleFailureEntry(failure));
      }
    }
  }

  ShellToastEntry _staleResultEntry(StaleRecovery recovery) => ShellToastEntry(
    tone: ZsToastTone.success,
    build: (context, dismiss) {
      final ZsColors colors = ZsColors.of(context);
      // jj's `short_commit_hash`: 12 hex digits.
      final String full = recovery.commitId ?? '';
      final String commit = full.substring(0, math.min(12, full.length));
      // jj's own sentences (`cli_util.rs:678`, `:723`, `:1557` @ v0.46.0).
      final InlineSpan text = switch (recovery.outcome) {
        StaleRecoveryOutcome.notStale => const TextSpan(
          text: 'Attempted recovery, but the working copy is not stale.', // l10n-ignore: jj's text
        ),
        StaleRecoveryOutcome.updated => TextSpan(
          children: <InlineSpan>[
            const TextSpan(text: 'Updated working copy to fresh commit '), // l10n-ignore: jj's text
            toastMono(colors, commit),
          ],
        ),
        StaleRecoveryOutcome.recovered => TextSpan(
          children: <InlineSpan>[
            const TextSpan(text: 'Created and checked out recovery commit '), // l10n-ignore: jj's text
            toastMono(colors, commit),
          ],
        ),
      };
      return ZsToast(
        message: toastWithWarnings(colors, text, recovery.warnings),
        onDismiss: dismiss,
        identifier: 'graph-toast',
      );
    },
  );

  ShellToastEntry _staleFailureEntry(ZanshinFfiException failure) => ShellToastEntry(
    tone: ZsToastTone.error,
    build: (context, dismiss) => ZsToast(
      tone: ZsToastTone.error,
      message: TextSpan(text: context.l10n.toastStaleUpdateFailed(failure.context ?? failure.code)),
      actions: <ZsToastAction>[
        ZsToastAction(
          label: context.l10n.toastRetry,
          tooltip: 'jj workspace update-stale', // l10n-ignore: jj command
          identifier: 'graph-toast-retry',
          onPressed: () {
            dismiss();
            unawaited(model.updateStale());
          },
        ),
      ],
      onDismiss: dismiss,
      identifier: 'graph-toast',
    ),
  );

  /// Stops listening and hides its toast if it still shows: its Undo, Redo or Retry would run on a disposed model.
  void dispose() {
    model.outcome.removeListener(_outcome);
    model.removeListener(_changed);
    final ShellToastEntry? shown = _shown;
    if (shown != null) {
      toasts.dismiss(shown);
    }
  }
}

/// The toast for [outcome], or null when it shows none (Story 10.23 item 2; the I/O matrix): a success says what it did
/// in the past tense, with Undo while it is [GraphViewModel.undoable] (Redo while [GraphViewModel.redoable]) and its
/// warnings as warn clauses; `new`, `edit` and `describe` toast only their warnings; a refusal shows jj's message in
/// the warn tone, a stale working copy's none (the stale notice is that surface). The ids are jj's shortest unique
/// prefix bold, max(prefix, 8) characters, the prefix from [GraphViewModel.layout] (2 when it lacks the id).
ShellToastEntry? graphOutcomeEntry(GraphOutcome outcome, {required GraphViewModel model, required ShellToasts toasts}) {
  final ZanshinFfiException? error = outcome.error;
  if (error != null) {
    if (error.code == 'jj.stale_working_copy') {
      return null;
    }
    return ShellToastEntry(
      tone: ZsToastTone.warn,
      build: (context, dismiss) => ZsToast(
        tone: ZsToastTone.warn,
        message: TextSpan(text: error.context ?? error.code),
        onDismiss: dismiss,
        identifier: 'graph-toast',
      ),
    );
  }
  final List<ZanshinWarning> warnings = outcome.warnings;
  final GraphAction action = outcome.action;
  final bool silent = action is GraphNew || action is GraphEdit || action is GraphDescribe;
  if (silent) {
    if (warnings.isEmpty) {
      return null;
    }
    return ShellToastEntry(
      tone: ZsToastTone.warn,
      build: (context, dismiss) => ZsToast(
        tone: ZsToastTone.warn,
        message: toastWithWarnings(ZsColors.of(context), null, warnings),
        onDismiss: dismiss,
        identifier: 'graph-toast',
      ),
    );
  }
  return ShellToastEntry(
    tone: ZsToastTone.success,
    listenable: model,
    build: (context, dismiss) {
      final AppLocalizations strings = context.l10n;
      final ZsColors colors = ZsColors.of(context);
      // A verb that wrote no operation changed nothing; jj says so (`cli_util.rs:2852` @ v0.46.0).
      final InlineSpan text = outcome.undoable || action is GraphUndo || action is GraphRedo
          ? _text(strings, colors, outcome, model.layout)
          : const TextSpan(text: 'Nothing changed.'); // l10n-ignore: jj's text
      final bool undo = identical(model.undoable, outcome);
      final bool redo = identical(model.redoable, outcome);
      return ZsToast(
        message: toastWithWarnings(colors, text, warnings),
        actions: <ZsToastAction>[
          if (undo)
            ZsToastAction(
              label: strings.toastUndo,
              tooltip: 'jj undo', // l10n-ignore: jj command
              identifier: 'graph-toast-undo',
              onPressed: () {
                dismiss();
                unawaited(_guarded(model.undoLast, toasts, (strings) => strings.toastNothingUndone));
              },
            ),
          if (redo)
            ZsToastAction(
              label: strings.toastRedo,
              tooltip: 'jj redo', // l10n-ignore: jj command
              identifier: 'graph-toast-redo',
              onPressed: () {
                dismiss();
                unawaited(_guarded(model.redoLast, toasts, (strings) => strings.toastNothingRedone));
              },
            ),
        ],
        onDismiss: dismiss,
        identifier: 'graph-toast',
      );
    },
  );
}

/// Undo or redo through [run]; when another operation came after Zanshin's, the warn toast says nothing happened
/// ([message]).
Future<void> _guarded(
  Future<GraphActionResult> Function() run,
  ShellToasts toasts,
  String Function(AppLocalizations strings) message,
) async {
  final GraphActionResult result = await run();
  if (result is GraphActionDisabled && result.reason == GraphDisabledReason.foreignOperation) {
    toasts.show(
      ShellToastEntry(
        tone: ZsToastTone.warn,
        build: (context, dismiss) => ZsToast(
          tone: ZsToastTone.warn,
          message: TextSpan(text: message(context.l10n)),
          onDismiss: dismiss,
          identifier: 'graph-toast',
        ),
      ),
    );
  }
}

/// What [outcome]'s verb did, from its action's fields and jj's result.
InlineSpan _text(AppLocalizations strings, ZsColors colors, GraphOutcome outcome, GraphLayout? layout) {
  InlineSpan id(String changeId) => _changeId(colors, changeId, _prefix(layout, changeId));
  InlineSpan ids(List<String> changeIds) => toastList(strings, <InlineSpan>[for (final String c in changeIds) id(c)]);
  InlineSpan names(List<String> bookmarks) =>
      toastList(strings, <InlineSpan>[for (final String n in bookmarks) toastMono(colors, n)]);
  InlineSpan target(String? changeId) =>
      changeId == null ? toastMono(colors, '@') : id(changeId); // l10n-ignore: jj's symbol
  final String s0 = toastSlot(0);
  final String s1 = toastSlot(1);
  final MutationResult? result = outcome.result;
  final List<InlineSpan> parts;
  final String message;
  switch (outcome.action) {
    case GraphAbandon(ids: final List<String> abandoned):
      message = strings.toastAbandoned(s0);
      parts = <InlineSpan>[ids(abandoned)];
    case GraphRevert(id: final String reverted):
      final String? inverse = outcome.born.firstOrNull;
      message = inverse == null ? strings.toastRevertedAlone(s0) : strings.toastReverted(s0, s1);
      parts = <InlineSpan>[id(reverted), ?(inverse == null ? null : id(inverse))];
    case GraphSquash(:final String? revision, :final List<String> from):
      message = strings.toastSquashed(s0, s1);
      parts = <InlineSpan>[
        if (revision != null)
          id(revision)
        else if (from.isNotEmpty)
          ids(from)
        else
          target(result?.abandonedChangeIds.firstOrNull),
        target(outcome.flash.firstOrNull),
      ];
    case GraphBookmarkCreate(names: final List<String> created, :final String? revision):
      message = strings.toastBookmarkCreated(s0, s1);
      parts = <InlineSpan>[names(created), target(revision ?? result?.workingCopyChangeId)];
    case GraphBookmarkDelete(names: final List<String> deleted):
      message = strings.toastBookmarkDeleted(s0);
      parts = <InlineSpan>[names(deleted)];
    case GraphBookmarkMove(names: final List<String> moved, :final String? to):
      message = strings.toastBookmarkMoved(s0, s1);
      parts = <InlineSpan>[names(moved), target(to ?? result?.workingCopyChangeId)];
    case GraphBookmarkRename(:final String oldName, :final String newName):
      message = strings.toastBookmarkRenamed(s0, s1);
      parts = <InlineSpan>[toastMono(colors, oldName), toastMono(colors, newName)];
    case GraphBookmarkTrack(:final String name, :final String remote):
      message = strings.toastBookmarkTracked(s0);
      parts = <InlineSpan>[toastMono(colors, '$name@$remote')]; // l10n-ignore: jj's symbol
    case GraphBookmarkUntrack(:final String name, :final String remote):
      message = strings.toastBookmarkUntracked(s0);
      parts = <InlineSpan>[toastMono(colors, '$name@$remote')]; // l10n-ignore: jj's symbol
    case GraphUndo(:final GraphAction of):
      message = strings.toastUndid(s0);
      parts = <InlineSpan>[toastMono(colors, of.command)];
    case GraphRedo(:final GraphAction of):
      message = strings.toastRedid(s0);
      parts = <InlineSpan>[toastMono(colors, of.command)];
    case GraphOpRestore(:final String operation):
      message = 'Restored to operation: $s0'; // l10n-ignore: jj's own words (`jj op restore`)
      parts = <InlineSpan>[toastMono(colors, operation)];
    // Never an outcome's own action: it only names what a GraphUndo undid.
    case GraphNew() || GraphEdit() || GraphDescribe() || GraphLoggedOperation():
      return const TextSpan();
  }
  return toastSpan(message, parts);
}

/// jj's shortest unique prefix of [changeId] in [layout]; 2 when the layout lacks it (as the search does).
int _prefix(GraphLayout? layout, String changeId) {
  final int? node = layout?.indexOfKey(changeId);
  return node == null ? 2 : layout!.changeIdPrefixLengthOf(node);
}

/// A change id with jj's shortest unique prefix bold, max(prefix, 8) characters, one text (decision 16.35).
InlineSpan _changeId(ZsColors colors, String id, int prefix) {
  final int shown = math.min(id.length, math.max(prefix, 8));
  final int bold = math.min(prefix, shown);
  final TextStyle style = ZsType.id.copyWith(fontSize: ZsType.fsMd, color: colors.textMuted);
  return TextSpan(
    children: <TextSpan>[
      TextSpan(
        text: id.substring(0, bold),
        style: style.copyWith(
          fontWeight: FontWeight.w600,
          fontVariations: const <FontVariation>[FontVariation.weight(600)],
          color: colors.text,
        ),
      ),
      TextSpan(text: id.substring(bold, shown), style: style),
    ],
  );
}
