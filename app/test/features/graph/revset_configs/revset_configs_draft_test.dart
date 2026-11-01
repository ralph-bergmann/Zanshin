// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/revset_configs/revset_configs_draft.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

const _a = RevsetConfiguration(
  id: 'a',
  name: 'A',
  rules: <RevsetRule>[RevsetRule(fn: RevsetRuleFunction.mine)],
);
const _b = RevsetConfiguration(id: 'b', name: 'B');

RevsetConfigsDraft _draft({String home = revsetDefaultLog, String? selected}) {
  final draft = RevsetConfigsDraft(
    const GraphSettings(revsetConfigs: <RevsetConfiguration>[_a, _b]).copyWith(revsetDefault: home),
    selected: selected,
    random: math.Random(1),
  );
  addTearDown(draft.dispose);
  return draft;
}

List<String> _ids(RevsetConfigsDraft draft) => <String>[for (final RevsetConfiguration c in draft.configs) c.id];

void main() {
  test('the default search is selected first; an unknown selection reads as it', () {
    expect(_draft(home: 'b').selected, 'b');
    expect(_draft(selected: 'gone').selected, revsetDefaultLog);
    expect(_draft(selected: revsetDefaultAll).selected, revsetDefaultAll);
  });

  test('add: one empty files path rule, last, selected; duplicate: "<name> copy" right after; move up and down', () {
    final RevsetConfigsDraft draft = _draft(selected: 'a');
    final String id = draft.add('New configuration');
    expect(_ids(draft), <String>['a', 'b', id]);
    expect(draft.selected, id);
    expect(draft.current!.name, 'New configuration');
    expect(draft.current!.rules, const <RevsetRule>[
      RevsetRule(fn: RevsetRuleFunction.files, mode: RevsetRuleMode.prefix),
    ]);

    draft
      ..select('a')
      ..duplicate('A copy');
    final String copy = draft.selected!;
    expect(_ids(draft), <String>['a', copy, 'b', id]);
    expect(draft.current!.rules, _a.rules);

    draft.move(-1);
    expect(_ids(draft), <String>[copy, 'a', 'b', id]);
    draft.move(-1);
    expect(_ids(draft), <String>[copy, 'a', 'b', id], reason: 'the first stays first');
    draft.move(1);
    expect(_ids(draft), <String>['a', copy, 'b', id]);
  });

  test('remove selects the neighbour; removing the default returns it to jj log', () {
    final RevsetConfigsDraft draft = _draft(home: 'b', selected: 'b')..remove();
    expect(_ids(draft), <String>['a']);
    expect(draft.selected, 'a');
    expect(draft.home, revsetDefaultLog);
    draft.remove();
    expect(draft.configs, isEmpty);
    expect(draft.selected, isNull);
  });

  test("jj log's switch is locked on while it is the default; another switched off returns the default to jj log", () {
    final RevsetConfigsDraft draft = _draft();
    expect(draft.homeLocked, isTrue);
    draft.setHome(on: false);
    expect(draft.home, revsetDefaultLog);

    draft
      ..select('a')
      ..setHome(on: true);
    expect(draft.home, 'a');
    draft.select(revsetDefaultLog);
    expect(draft.homeLocked, isFalse, reason: 'jj log is not the default now');
    draft
      ..select('a')
      ..setHome(on: false);
    expect(draft.home, revsetDefaultLog);
  });

  test('dirty after any edit, the default alone included; saved and reset make it clean', () {
    final RevsetConfigsDraft draft = _draft(selected: 'a');
    expect(draft.dirty, isFalse);
    draft.setHome(on: true);
    expect(draft.dirty, isTrue);
    draft.setHome(on: false);
    expect(draft.dirty, isFalse, reason: 'back to what is stored');

    draft.setRuleFunction(0, RevsetRuleFunction.author);
    expect(draft.current!.rules.single, const RevsetRule(fn: RevsetRuleFunction.author));
    expect(draft.dirty, isTrue);
    final GraphSettings saved = draft.applyTo(const GraphSettings());
    expect(saved.revsetConfigs.first.rules.single.fn, RevsetRuleFunction.author);
    draft.saved(saved);
    expect(draft.dirty, isFalse);

    draft.addRule(RevsetRuleFunction.subject);
    expect(draft.dirty, isTrue);
    draft.reset(saved);
    expect(draft.dirty, isFalse);
    expect(draft.current!.rules, hasLength(1));
  });

  test('a function switch keeps the negation and the value (not for mine)', () {
    final RevsetConfigsDraft draft = _draft(selected: 'a')
      ..setRule(0, const RevsetRule(fn: RevsetRuleFunction.subject, value: 'fix', not: true, ci: true))
      ..setRuleFunction(0, RevsetRuleFunction.files);
    expect(
      draft.current!.rules.single,
      const RevsetRule(fn: RevsetRuleFunction.files, mode: RevsetRuleMode.prefix, value: 'fix', not: true),
    );
    draft.setRuleFunction(0, RevsetRuleFunction.mine);
    expect(draft.current!.rules.single, const RevsetRule(fn: RevsetRuleFunction.mine, not: true));
    draft.removeRule(0);
    expect(draft.current!.rules, isEmpty);
  });
}
