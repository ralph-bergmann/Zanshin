// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart' show RevsetCounts, ZanshinFfiException;

import '../settings/immutable_heads.dart';

/// Counts revsets at an operation, as `RepoHandle.revsetCounts`.
typedef ImmutableReasonCounts = Future<RevsetCounts> Function(
  String operationId,
  List<String> expressions, {
  required int cap,
});

/// Why a change is immutable (Story 11.7, I7/I8): the first top-level term of `immutable_heads()` whose ancestors
/// hold it, verbatim (jj's text) — `trunk()` for a change below trunk.
///
/// The alias is read once per operation ([readAlias]: its effective text, null when unset) and split into its
/// top-level `|` terms, `builtin_immutable_heads()` expanded to the CLI's v0.46.0 definition ([immutableBuiltins]).
/// For a commit it asks [counts] for `<commitId> & ::(<term>)` per term (cap 1); the first with a match is the
/// reason. Answers are cached per (operation, commit); a failed read answers null.
class ImmutableReasons {
  /// The reasons over [readAlias] and [counts].
  ImmutableReasons({required this.readAlias, required this.counts});

  /// The effective `revset-aliases."immutable_heads()"` text, or null when it is unset.
  final Future<String?> Function() readAlias;

  /// `revsetCounts` at an operation.
  final ImmutableReasonCounts counts;

  String? _termsOperation;
  late Future<List<String>> _terms;
  final _cache = <(String, String), Future<String?>>{};

  /// The reason [commitId] is immutable at [operationId], or null when none is known.
  Future<String?> reasonOf(String operationId, String commitId) {
    if (_termsOperation != operationId) {
      _termsOperation = operationId;
      _terms = _readTerms();
      _cache.clear();
    }
    final Future<List<String>> terms = _terms;
    return _cache.putIfAbsent((operationId, commitId), () => _reason(terms, operationId, commitId));
  }

  /// Drops the terms and every cached answer: a config write changes the alias without an operation.
  void invalidate() {
    _termsOperation = null;
    _cache.clear();
  }

  Future<List<String>> _readTerms() async {
    final String alias = await readAlias() ?? builtinImmutableHeads;
    return <String>[
      for (final String term in splitRevsetUnion(alias))
        if (term == builtinImmutableHeads) ...immutableBuiltins else term,
    ];
  }

  Future<String?> _reason(Future<List<String>> termsRead, String operationId, String commitId) async {
    try {
      final List<String> terms = await termsRead;
      if (terms.isEmpty) {
        return null;
      }
      final RevsetCounts answer = await counts(operationId, <String>[
        for (final String term in terms) '$commitId & ::($term)',
      ], cap: 1);
      for (var i = 0; i < terms.length && i < answer.length; i++) {
        if (answer[i].error == null && answer[i].n > 0) {
          return terms[i];
        }
      }
      return null;
    } on ZanshinFfiException {
      return null;
    }
  }
}

/// Provides the open repository's [ImmutableReasons] to the graph's peek and inspector (Story 11.7); null without one.
class ImmutableReasonScope extends InheritedWidget {
  /// Provides [reasons] to [child].
  const ImmutableReasonScope({required this.reasons, required super.child, super.key});

  /// The reasons, or null.
  final ImmutableReasons? reasons;

  /// The nearest reasons, or null.
  static ImmutableReasons? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ImmutableReasonScope>()?.reasons;

  @override
  bool updateShouldNotify(ImmutableReasonScope oldWidget) => !identical(reasons, oldWidget.reasons);
}

/// Builds with the reason [commitId] is immutable at [operationId] — null without a scope, before the answer and
/// when none is known.
class ImmutableReasonBuilder extends StatelessWidget {
  /// The reason of [commitId] at [operationId], handed to [builder].
  const ImmutableReasonBuilder({required this.operationId, required this.commitId, required this.builder, super.key});

  /// The operation the change is shown at.
  final String? operationId;

  /// The change's commit id.
  final String? commitId;

  /// Builds with the reason.
  final Widget Function(BuildContext context, String? reason) builder;

  @override
  Widget build(BuildContext context) {
    final ImmutableReasons? reasons = ImmutableReasonScope.maybeOf(context);
    final String? operation = operationId;
    final String? commit = commitId;
    if (reasons == null || operation == null || commit == null) {
      return builder(context, null);
    }
    return FutureBuilder<String?>(
      future: reasons.reasonOf(operation, commit),
      builder: (context, snapshot) => builder(context, snapshot.data),
    );
  }
}
