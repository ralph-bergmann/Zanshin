// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

/// The jj log Configurations window's edits (Story 10.22; DS RevsetDialog.jsx): the configurations and the default
/// search as the window shows them, the selected entry (`log`, `all`, a configuration id, or null for none), and
/// whether they differ from what is stored ([dirty]). Nothing is written until the window saves [applyTo]'s result.
class RevsetConfigsDraft extends ChangeNotifier {
  /// The draft of [stored], [selected] selected (the default search when null or unknown).
  RevsetConfigsDraft(GraphSettings stored, {String? selected, math.Random? random})
    : _random = random ?? math.Random(),
      _stored = stored,
      _configs = stored.revsetConfigs,
      _home = stored.effectiveRevsetDefault {
    _selected = _known(selected) ? selected : _home;
  }

  final math.Random _random;
  GraphSettings _stored;
  List<RevsetConfiguration> _configs;
  String _home;
  String? _selected;

  /// The configurations, in menu order (the default search leads the menu, the rest keep this order).
  List<RevsetConfiguration> get configs => List<RevsetConfiguration>.unmodifiable(_configs);

  /// The default search: `log`, `all` or a configuration id.
  String get home => _home;

  /// The selected entry, or null (no configuration left to select).
  String? get selected => _selected;

  /// The selected configuration, or null for a built-in or none.
  RevsetConfiguration? get current => _find(_selected);

  /// The selected configuration's index, or -1.
  int get currentIndex => _configs.indexWhere((c) => c.id == _selected);

  /// Whether the edits differ from what is stored.
  bool get dirty => !listEquals(_configs, _stored.revsetConfigs) || _home != _stored.effectiveRevsetDefault;

  /// Whether the selected entry's Default search switch is locked on: `jj log` while it is the default.
  bool get homeLocked => _selected == revsetDefaultLog && _home == revsetDefaultLog;

  RevsetConfiguration? _find(String? id) {
    for (final RevsetConfiguration c in _configs) {
      if (c.id == id) {
        return c;
      }
    }
    return null;
  }

  bool _known(String? id) => id == revsetDefaultLog || id == revsetDefaultAll || _find(id) != null;

  /// [stored] with the draft's configurations and default.
  GraphSettings applyTo(GraphSettings stored) => stored.copyWith(revsetConfigs: _configs, revsetDefault: _home);

  /// The draft was saved as [stored]: it is clean again.
  void saved(GraphSettings stored) {
    _stored = stored;
    notifyListeners();
  }

  /// Drops every edit: the draft is [stored] again, the selection kept where it still exists.
  void reset(GraphSettings stored) {
    _stored = stored;
    _configs = stored.revsetConfigs;
    _home = stored.effectiveRevsetDefault;
    if (!_known(_selected)) {
      _selected = _home;
    }
    notifyListeners();
  }

  /// Selects [id].
  void select(String id) {
    if (_known(id) && id != _selected) {
      _selected = id;
      notifyListeners();
    }
  }

  /// The selected entry becomes the default search ([on]), or the default returns to `jj log`.
  void setHome({required bool on}) {
    final String? selected = _selected;
    if (selected == null || homeLocked) {
      return;
    }
    _home = on ? selected : revsetDefaultLog;
    notifyListeners();
  }

  String _newId() {
    String id;
    do {
      id = 'c-${_random.nextInt(1 << 30).toRadixString(36)}';
    } while (_find(id) != null);
    return id;
  }

  /// Adds a configuration named [name] with one empty `files` path rule, last, and selects it; answers its id.
  String add(String name) {
    final c = RevsetConfiguration(
      id: _newId(),
      name: name,
      rules: <RevsetRule>[newRevsetRule(RevsetRuleFunction.files)],
    );
    _configs = <RevsetConfiguration>[..._configs, c];
    _selected = c.id;
    notifyListeners();
    return c.id;
  }

  /// Duplicates the selected configuration right after it as [name] and selects the copy.
  void duplicate(String name) {
    final int i = currentIndex;
    if (i < 0) {
      return;
    }
    final RevsetConfiguration c = _configs[i].copyWith(id: _newId(), name: name);
    _configs = <RevsetConfiguration>[..._configs.take(i + 1), c, ..._configs.skip(i + 1)];
    _selected = c.id;
    notifyListeners();
  }

  /// Removes the selected configuration and selects its neighbour (none when it was the last); the default falls
  /// back to `jj log` when it was the default.
  void remove() {
    final int i = currentIndex;
    if (i < 0) {
      return;
    }
    if (_home == _configs[i].id) {
      _home = revsetDefaultLog;
    }
    _configs = <RevsetConfiguration>[..._configs.take(i), ..._configs.skip(i + 1)];
    _selected = _configs.isEmpty ? null : _configs[math.min(i, _configs.length - 1)].id;
    notifyListeners();
  }

  /// Moves the selected configuration one place up ([by] -1) or down (1).
  void move(int by) {
    final int i = currentIndex;
    final int j = i + by;
    if (i < 0 || j < 0 || j >= _configs.length) {
      return;
    }
    final next = List<RevsetConfiguration>.of(_configs);
    next[i] = _configs[j];
    next[j] = _configs[i];
    _configs = next;
    notifyListeners();
  }

  /// Replaces the selected configuration with [change]'s result.
  void edit(RevsetConfiguration Function(RevsetConfiguration current) change) {
    final int i = currentIndex;
    if (i < 0) {
      return;
    }
    final RevsetConfiguration next = change(_configs[i]);
    if (next == _configs[i]) {
      return;
    }
    _configs = <RevsetConfiguration>[..._configs.take(i), next, ..._configs.skip(i + 1)];
    notifyListeners();
  }

  /// Replaces rule [index] of the selected configuration with [rule].
  void setRule(int index, RevsetRule rule) =>
      edit((c) => c.copyWith(rules: <RevsetRule>[...c.rules.take(index), rule, ...c.rules.skip(index + 1)]));

  /// Switches rule [index] to [fn]: a fresh rule of [fn] that keeps the negation and, unless [fn] is `mine`, the
  /// value (DS RevsetDialog.jsx `updRule`).
  void setRuleFunction(int index, RevsetRuleFunction fn) {
    final RevsetRule? old = current?.rules.elementAtOrNull(index);
    if (old == null || old.fn == fn) {
      return;
    }
    setRule(index, newRevsetRule(fn).copyWith(not: old.not, value: fn == RevsetRuleFunction.mine ? '' : old.value));
  }

  /// Removes rule [index].
  void removeRule(int index) =>
      edit((c) => c.copyWith(rules: <RevsetRule>[...c.rules.take(index), ...c.rules.skip(index + 1)]));

  /// Adds an empty rule of [fn] last.
  void addRule(RevsetRuleFunction fn) => edit((c) => c.copyWith(rules: <RevsetRule>[...c.rules, newRevsetRule(fn)]));
}

/// A fresh rule of [fn] (DS RevsetDialog.jsx `zsNewRule`): `files` matches a path or folder, the text functions a
/// substring.
RevsetRule newRevsetRule(RevsetRuleFunction fn) => RevsetRule(
  fn: fn,
  mode: fn == RevsetRuleFunction.files ? RevsetRuleMode.prefix : RevsetRuleMode.substring,
);
