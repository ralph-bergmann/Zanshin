// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_toasts.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/shell/shell_toast.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart';
import '../../helpers/shell_host.dart';
import 'graph_harness.dart';

// Ten-character change ids, as jj prints them in the CLI's default length; their shortest prefixes come from the layout.
const _a = 'ovknlmrozz';
const _b = 'vruxwmqvzz';
const _c = 'kxqpsytnzz';

/// [_a] → [_b] → [_c] (newest first, each the parent of the one before), @ = [_a], prefix lengths 3, 9 and 2.
RecordedGraphLayout _layout() => handLayout(
  <(String, int, int)>[(_a, 2, 0), (_b, 1, 0), (_c, 0, 0)],
  edges: <(int, int)>[(0, 1), (1, 2)],
  workingCopy: 0,
  prefixLengths: <int>[3, 9, 2],
);

/// A fake port: each run writes operation `op<n>` (the head follows) with [born], [abandoned], [warnings] and [at],
/// or nothing ([noOp]), or throws [refuse].
class _Actions implements GraphActions {
  final ran = <GraphAction>[];
  var head = 'op0';
  ZanshinFfiException? refuse;
  var noOp = false;
  var born = const <String>[];
  var abandoned = const <String>[];
  var warnings = const <ZanshinWarning>[];
  String? at;

  @override
  Future<String> headOpId() async => head;

  @override
  Future<MutationResult> run(GraphAction action) async {
    ran.add(action);
    if (refuse case final error?) {
      throw error;
    }
    if (!noOp) {
      head = 'op${ran.length}';
    }
    return MutationResult(
      newOpId: head,
      newChangeIds: born,
      abandonedChangeIds: abandoned,
      workingCopyChangeId: at,
      finish: null,
      warnings: warnings,
    );
  }
}

const _warning = ZanshinWarning(code: ZanshinWarningCode.identityMissing, message: 'Name and email not configured.');

void main() {
  setUpIconRegistry();

  late ScriptedGraphSource source;
  late _Actions actions;
  late GraphViewModel model;
  late ShellToasts toasts;
  late GraphToasts binding;

  Future<void> start(WidgetTester tester) async {
    source = ScriptedGraphSource(respond: (_) => _layout());
    actions = _Actions();
    model = GraphViewModel()..init(source, actions: actions);
    toasts = ShellToasts();
    binding = GraphToasts(model, toasts);
    useShellWindow(tester);
    await tester.pumpWidget(
      shellHost(
        BackdropGroup(
          child: Center(
            child: ListenableBuilder(
              listenable: toasts,
              builder: (context, _) => toasts.occupied ? ShellToastView(toasts: toasts) : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// A widget test on a started rig, torn down before the binding checks its timers.
  void toastTest(String description, Future<void> Function(WidgetTester tester) body) =>
      testWidgets(description, (tester) async {
        await start(tester);
        await body(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        binding.dispose();
        model.dispose();
        toasts.dispose();
      });

  /// Runs [action] and lets its toast enter.
  Future<void> run(WidgetTester tester, GraphAction action) async {
    await tester.runAsync(() => model.run(action));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  ZsToast? shown(WidgetTester tester) {
    final Iterable<ZsToast> all = tester.widgetList<ZsToast>(find.byType(ZsToast));
    return toasts.current == null || all.isEmpty ? null : all.last;
  }

  String? text(WidgetTester tester) => shown(tester)?.message.toPlainText();

  List<String> buttons(WidgetTester tester) => <String>[
    for (final ZsToastAction action in shown(tester)?.actions ?? const <ZsToastAction>[]) action.label,
  ];

  /// The leaf spans of the shown toast's text.
  List<TextSpan> leaves(WidgetTester tester) {
    final spans = <TextSpan>[];
    shown(tester)!.message.visitChildren((span) {
      if (span is TextSpan && span.text != null) {
        spans.add(span);
      }
      return true;
    });
    return spans;
  }

  toastTest('abandon: "Abandoned ‹a›" with Undo; the id is 8 characters, its layout prefix bold', (tester) async {
    await run(tester, const GraphAbandon(<String>[_a]));
    expect(text(tester), 'Abandoned ovknlmro');
    expect(buttons(tester), <String>['Undo']);
    expect(shown(tester)!.actions.single.tooltip, 'jj undo');
    final TextSpan bold = leaves(tester).firstWhere((span) => span.text == 'ovk');
    expect(bold.style?.fontWeight, FontWeight.w600);
    expect(bold.style?.fontFamily, ZsType.monoFamily);
    expect(leaves(tester).map((span) => span.text), contains('nlmro'));
  });

  toastTest('dispose hides its own toast (its Undo names the disposed model), never a later one', (tester) async {
    await run(tester, const GraphAbandon(<String>[_a]));
    expect(toasts.current, isNotNull);
    binding.dispose();
    expect(toasts.current, isNull);

    final other = ShellToastEntry(
      tone: ZsToastTone.success,
      build: (context, dismiss) => ZsToast(
        message: const TextSpan(text: 'other'),
        onDismiss: dismiss,
      ),
    );
    toasts.show(other);
    binding.dispose();
    expect(toasts.current, same(other));
  });

  toastTest('a prefix longer than 8 shows in full; an id the layout lacks takes prefix 2', (tester) async {
    await run(tester, const GraphAbandon(<String>[_b, 'zzzzzzzzzzzz']));
    expect(text(tester), 'Abandoned vruxwmqvz and zzzzzzzz');
    expect(leaves(tester).map((span) => span.text), containsAll(<String>['vruxwmqvz', 'zz', 'zzzzzz']));
  });

  toastTest('several: a localized list', (tester) async {
    await run(tester, const GraphAbandon(<String>[_a, _b, _c]));
    expect(text(tester), 'Abandoned ovknlmro, vruxwmqvz and kxqpsytn');
  });

  toastTest('revert: "Reverted ‹x› — ‹y› undoes it"', (tester) async {
    actions.born = const <String>[_c];
    await run(tester, const GraphRevert(_b));
    expect(text(tester), 'Reverted vruxwmqvz — kxqpsytn undoes it');
    expect(buttons(tester), <String>['Undo']);
  });

  toastTest('revert without a new change: "Reverted ‹x›"', (tester) async {
    await run(tester, const GraphRevert(_b));
    expect(text(tester), 'Reverted vruxwmqvz');
  });

  toastTest('squash: -r into its parent, --from into --into, the source falling back to what jj abandoned', (
    tester,
  ) async {
    await run(tester, const GraphSquash(revision: _b));
    expect(text(tester), 'Squashed vruxwmqvz into kxqpsytn');
    await run(tester, const GraphSquash(from: <String>[_a], into: _c));
    expect(text(tester), 'Squashed ovknlmro into kxqpsytn');
    actions.abandoned = const <String>[_a];
    await run(tester, const GraphSquash());
    expect(text(tester), 'Squashed ovknlmro into vruxwmqvz');
  });

  toastTest('bookmarks: created on the revision or @, deleted, moved, renamed', (tester) async {
    await run(tester, const GraphBookmarkCreate(<String>['main'], revision: _b));
    expect(text(tester), 'Created main on vruxwmqvz');
    await run(tester, const GraphBookmarkCreate(<String>['main']));
    expect(text(tester), 'Created main on @');
    actions.at = _a;
    await run(tester, const GraphBookmarkCreate(<String>['main', 'dev']));
    expect(text(tester), 'Created main and dev on ovknlmro');
    await run(tester, const GraphBookmarkDelete(<String>['main']));
    expect(text(tester), 'Deleted main');
    await run(tester, const GraphBookmarkMove(<String>['main'], to: _c));
    expect(text(tester), 'Moved main to kxqpsytn');
    await run(tester, const GraphBookmarkMove(<String>['main']));
    expect(text(tester), 'Moved main to ovknlmro');
    await run(tester, const GraphBookmarkRename('main', 'trunk'));
    expect(text(tester), 'Renamed main to trunk');
    expect(buttons(tester), <String>['Undo']);
  });

  toastTest('new, edit and describe show no toast; with warnings, the warnings in the warn tone', (tester) async {
    await run(tester, const GraphNew(parents: <String>[_a]));
    await run(tester, const GraphEdit(_b));
    await run(tester, const GraphDescribe(_b, 'x'));
    expect(toasts.current, isNull);

    actions.warnings = const <ZanshinWarning>[_warning, _warning];
    await run(tester, const GraphEdit(_b));
    expect(shown(tester)!.tone, ZsToastTone.warn);
    expect(text(tester), 'Name and email not configured. · Name and email not configured.');
    expect(buttons(tester), isEmpty);
  });

  toastTest('a success with warnings adds a warn clause', (tester) async {
    actions.warnings = const <ZanshinWarning>[_warning];
    await run(tester, const GraphAbandon(<String>[_a]));
    expect(text(tester), 'Abandoned ovknlmro · Name and email not configured.');
    final TextSpan clause = leaves(tester).last;
    expect(clause.style?.color, ZsColors.night.warn);
  });

  toastTest('Undo calls undoLast once: "Undid jj …" with Redo follows; its Redo calls redoLast once', (tester) async {
    await run(tester, const GraphAbandon(<String>[_a]));
    await tester.tap(find.text('Undo'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(actions.ran.whereType<GraphUndo>(), hasLength(1));
    expect(text(tester), 'Undid jj abandon ovknlmrozz');
    expect(buttons(tester), <String>['Redo']);
    expect(shown(tester)!.actions.single.tooltip, 'jj redo');

    await tester.tap(find.text('Redo'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(actions.ran.whereType<GraphRedo>(), hasLength(1));
    expect(text(tester), 'Redid jj abandon ovknlmrozz');
    expect(buttons(tester), <String>['Undo']);
  });

  toastTest('after a foreign operation the button goes and the text stays; a late Undo says nothing was undone', (
    tester,
  ) async {
    await run(tester, const GraphAbandon(<String>[_a]));
    actions.head = 'foreign';
    await tester.tap(find.text('Undo'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(actions.ran.whereType<GraphUndo>(), isEmpty);
    expect(shown(tester)!.tone, ZsToastTone.warn);
    expect(text(tester), 'Nothing undone — another operation came after it');

    await run(tester, const GraphAbandon(<String>[_b]));
    expect(buttons(tester), <String>['Undo']);
    actions.head = 'foreign';
    source.emit(const OpHeadsChangedEvent(0, <String>[]));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(text(tester), 'Abandoned vruxwmqvz');
    expect(buttons(tester), isEmpty);
  });

  toastTest('a refusal: the warn tone with jj’s message, no Undo, gone after 6.5 s; a stale one shows none', (
    tester,
  ) async {
    actions.refuse = const ZanshinFfiException('jj.immutable', 'Commit 1234 is immutable');
    await tester.runAsync(() => model.run(const GraphAbandon(<String>[_c])));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(shown(tester)!.tone, ZsToastTone.warn);
    expect(text(tester), 'Commit 1234 is immutable');
    expect(buttons(tester), isEmpty);
    await tester.pump(const Duration(milliseconds: 6400));
    expect(toasts.current, isNull);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    actions.refuse = staleError('stale');
    await tester.runAsync(() => model.run(const GraphAbandon(<String>[_c])));
    await tester.pump();
    expect(toasts.current, isNull);
  });

  toastTest('a verb that wrote no operation says "Nothing changed.", keeping its warnings', (tester) async {
    actions
      ..noOp = true
      ..warnings = const <ZanshinWarning>[_warning];
    await run(tester, const GraphBookmarkMove(<String>['main'], to: _c));
    expect(text(tester), 'Nothing changed. · Name and email not configured.');
    expect(buttons(tester), isEmpty);
  });

  toastTest('a late Redo after a foreign operation says nothing was redone', (tester) async {
    await run(tester, const GraphAbandon(<String>[_a]));
    await tester.tap(find.text('Undo'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    actions.head = 'foreign';
    await tester.tap(find.text('Redo'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(actions.ran.whereType<GraphRedo>(), isEmpty);
    expect(shown(tester)!.tone, ZsToastTone.warn);
    expect(text(tester), 'Nothing redone — another operation came after it');
  });

  toastTest('a binding built on a model that already has a stale result or failure does not toast them', (
    tester,
  ) async {
    await tester.runAsync(model.updateStale);
    source.update = () async => throw const ZanshinFfiException('jj.io_error');
    await tester.runAsync(model.updateStale);
    expect(model.lastStaleRecovery, isNotNull);
    expect(model.staleUpdateError, isNotNull);
    binding.dispose();
    toasts.dismiss();
    binding = GraphToasts(model, toasts);

    model.select(_b);
    await tester.pump();
    expect(toasts.current, isNull);
  });

  toastTest("stale recovery: jj's sentences, never Undo; a failure stays with Retry", (tester) async {
    StaleRecovery recovery(StaleRecoveryOutcome outcome) => StaleRecovery(
      outcome: outcome,
      commitId: outcome == StaleRecoveryOutcome.notStale ? null : 'abcdef0123456789',
      checkout: null,
      gitHeadResetOpId: null,
      snapshotStats: const SnapshotStats(untracked: <UntrackedPath>[], invalidUtf8Paths: <String>[]),
      opId: 'op',
      warnings: outcome == StaleRecoveryOutcome.recovered ? const <ZanshinWarning>[_warning] : const <ZanshinWarning>[],
    );
    Future<void> update(StaleRecoveryOutcome outcome) async {
      source.update = () async => recovery(outcome);
      await tester.runAsync(model.updateStale);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    await update(StaleRecoveryOutcome.notStale);
    expect(text(tester), 'Attempted recovery, but the working copy is not stale.');
    await update(StaleRecoveryOutcome.updated);
    expect(text(tester), 'Updated working copy to fresh commit abcdef012345');
    await update(StaleRecoveryOutcome.recovered);
    expect(text(tester), 'Created and checked out recovery commit abcdef012345 · Name and email not configured.');
    expect(buttons(tester), isEmpty);

    source.update = () async => throw const ZanshinFfiException('jj.io_error', 'disk full');
    await tester.runAsync(model.updateStale);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(shown(tester)!.tone, ZsToastTone.error);
    expect(text(tester), 'Updating the working copy failed — disk full');
    expect(buttons(tester), <String>['Retry']);
    expect(shown(tester)!.actions.single.tooltip, 'jj workspace update-stale');
    await tester.pump(const Duration(seconds: 20));
    expect(toasts.current, isNotNull, reason: 'an error stays');

    final int before = source.updates;
    await tester.tap(find.text('Retry'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(source.updates, before + 1);
  });

  toastTest('the Undo Timeline: an undo of a logged operation reads "Undid ‹args› · Redo"; a restore "Restored to '
      'operation: ‹id›" with Undo', (tester) async {
    await tester.runAsync(
      () => model.undoOperation(
        'op0',
        const GraphLoggedOperation('op0', 'describe commit 1', args: 'jj describe -m wip'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(text(tester), 'Undid jj describe -m wip');
    expect(buttons(tester), <String>['Redo']);

    await tester.runAsync(
      () => model.undoOperation(actions.head, GraphLoggedOperation(actions.head, 'new empty commit')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(text(tester), 'Undid new empty commit', reason: 'no args tag: the description');

    await tester.runAsync(() => model.restoreOperation('1a2b3c4d5e6f'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(text(tester), 'Restored to operation: 1a2b3c4d5e6f');
    expect(buttons(tester), <String>['Undo']);
  });
}
