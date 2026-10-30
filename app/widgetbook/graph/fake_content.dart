// SPDX-License-Identifier: MIT

import 'package:zanshin/src/features/graph/graph_layout.dart';

// The design's subjects and authors (design/graph-data.js).
const _subjects = <String>[
  'Initial commit',
  'Add authentication module',
  'Update user interface components',
  'feat(api): endpoints for data sync',
  'Merge api-sync into main',
  'fix: memory leak in image cache',
  'perf: lazy-load heavy screens',
  'chore(deps): update dependencies',
  'feat(onboarding): scaffold 4-page flow',
  'feat(onboarding): hero illustrations + lottie loader',
  'feat(onboarding): animated page indicator',
  'feat(onboarding): swipe gestures + haptic feedback',
  'exp: migrate providers to riverpod 3 codegen',
  'fix(ios): keyboard avoidance on iPad split view',
  'refactor(api): extract response middleware',
  'test(settings): golden tests for all sections',
  'docs: auth flow sequence diagrams',
];

const _authors = <(String, String)>[
  ('Ralph Stein', 'ralph@example.com'),
  ('Lena König', 'lena@example.com'),
  ('Bob', 'bob@example.com'),
  ('Alice', 'alice@example.com'),
  ('Charlie Davis', 'charlie@example.com'),
  ('', 'ci-bot@example.com'),
];

// The legend cases (epics.md:8976) and jj's sigils.
const _refs = <List<GraphRef>>[
  <GraphRef>[GraphRef('feature/ZAN-412_onboarding-swipe')],
  <GraphRef>[GraphRef('release/1.5.x', remote: 'origin')],
  <GraphRef>[GraphRef('riverpod'), GraphRef('exp/riverpod-3'), GraphRef('main')],
  <GraphRef>[GraphRef('main', conflicted: true)],
  <GraphRef>[GraphRef('dev', synced: false)],
  <GraphRef>[GraphRef('docs/api-reference')],
];

/// Deterministic fake content for [node] (Story 10.3): the design's subjects and authors; about every 7th
/// description is empty, some changes are empty, a few conflicted. The key is unused (the index decides).
GraphCommitContent fakeContent(int node, String key) {
  final (String name, String email) = _authors[node % _authors.length];
  return GraphCommitContent(
    subject: node % 7 == 3 ? '' : _subjects[node % _subjects.length],
    authorName: name,
    authorEmail: email,
    empty: node % 11 == 5,
    conflict: node % 13 == 6,
  );
}

/// Deterministic fake bookmarks for [node]: about every 4th node gets the next legend case.
List<GraphRef> fakeRefs(int node, String key) => node % 4 == 1 ? _refs[node ~/ 4 % _refs.length] : const <GraphRef>[];
