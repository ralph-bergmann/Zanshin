// SPDX-License-Identifier: MIT

import 'package:flutter/material.dart';

// ── Branch colours ──────────────────────────────────────────────────────────

const kBranchColors = <String, Color>{
  'main': Color(0xFF3b82f6),
  'develop': Color(0xFF22c55e),
  'feature/new-ui': Color(0xFFa855f7),
  'feat/onboarding': Color(0xFFa855f7),
  'fix/ios-keyboard': Color(0xFFf59e0b),
  'exp/riverpod-3': Color(0xFFec4899),
};

Color branchColor(String name) => kBranchColors[name] ?? const Color(0xFF3b82f6);

// ── Data models ──────────────────────────────────────────────────────────────

class MockFileChange {
  const MockFileChange({
    required this.path,
    required this.status,
    required this.added,
    required this.removed,
  });
  final String path;
  final String status; // M, A, D, R
  final int added;
  final int removed;
}

class MockCommitStats {
  const MockCommitStats({required this.added, required this.removed, required this.files});
  final int added;
  final int removed;
  final int files;
}

class MockCommit {
  const MockCommit({
    required this.changeId,
    required this.subject,
    required this.author,
    required this.date,
    required this.stats,
    this.description = '',
    this.isWorkingCopy = false,
    this.isEmpty = false,
    this.isMerge = false,
    this.hasConflict = false,
    this.version,
    this.bookmarks = const [],
    this.parents = const [],
    this.files = const [],
  });

  final String changeId;
  final String subject;
  final String description;
  final String author;
  final String date;
  final bool isWorkingCopy;
  final bool isEmpty;
  final bool isMerge;
  final bool hasConflict;
  final String? version;
  final List<String> bookmarks;
  final List<String> parents;
  final List<MockFileChange> files;
  final MockCommitStats stats;
}

class MockBookmark {
  const MockBookmark({
    required this.name,
    this.ahead = 0,
    this.behind = 0,
    this.current = false,
    this.head = '',
  });
  final String name;
  final int ahead;
  final int behind;
  final bool current;
  final String head;
}

class MockRemoteBranch {
  const MockRemoteBranch({
    required this.name,
    this.trackedBy,
    this.aheadOfLocal = 0,
    this.behindLocal = 0,
  });
  final String name;
  final String? trackedBy;
  final int aheadOfLocal;
  final int behindLocal;
}

class MockProject {
  const MockProject({
    required this.id,
    required this.name,
    required this.path,
    required this.status,
    this.branch = 'main',
    this.ahead = 0,
    this.behind = 0,
    this.lastOpened = '',
  });
  final String id;
  final String name;
  final String path;
  final String status; // clean, dirty, ahead, behind, diverged, conflict, missing
  final String branch;
  final int ahead;
  final int behind;
  final String lastOpened;
}

// ── Diff data ────────────────────────────────────────────────────────────────

class DiffLine {
  const DiffLine({required this.type, required this.text});
  final String type; // context, add, remove, hunk
  final String text;
}

const kSampleDiff = [
  DiffLine(type: 'hunk', text: '@@ -1,6 +1,8 @@'),
  DiffLine(type: 'context', text: "import 'package:flutter/material.dart';"),
  DiffLine(type: 'context', text: ''),
  DiffLine(type: 'remove', text: 'class BranchColumn extends StatelessWidget {'),
  DiffLine(type: 'add', text: 'class BranchColumn extends StatefulWidget {'),
  DiffLine(type: 'context', text: '  final String branchName;'),
  DiffLine(type: 'context', text: '  final List<Commit> commits;'),
  DiffLine(type: 'add', text: '  final ValueChanged<Commit>? onSelect;'),
  DiffLine(type: 'add', text: ''),
  DiffLine(type: 'hunk', text: '@@ -18,7 +20,12 @@'),
  DiffLine(type: 'context', text: '  @override'),
  DiffLine(type: 'remove', text: '  Widget build(BuildContext context) {'),
  DiffLine(type: 'add', text: '  State<BranchColumn> createState() => _BranchColumnState();'),
  DiffLine(type: 'add', text: '}'),
  DiffLine(type: 'add', text: ''),
  DiffLine(type: 'add', text: 'class _BranchColumnState extends State<BranchColumn> {'),
  DiffLine(type: 'add', text: '  @override'),
  DiffLine(type: 'add', text: '  Widget build(BuildContext context) {'),
  DiffLine(type: 'context', text: '    return ListView.builder('),
  DiffLine(type: 'context', text: '      itemCount: widget.commits.length,'),
];

// ── Mock commits ─────────────────────────────────────────────────────────────

const _kFiles1 = [
  MockFileChange(path: 'lib/src/ui/branch_column.dart', added: 45, removed: 12, status: 'M'),
  MockFileChange(path: 'lib/src/ui/commit_card.dart', added: 23, removed: 8, status: 'M'),
  MockFileChange(path: 'lib/src/models/commit.dart', added: 15, removed: 0, status: 'M'),
  MockFileChange(path: 'lib/src/utils/legacy.dart', added: 0, removed: 32, status: 'D'),
  MockFileChange(path: 'lib/src/hooks/use_commits.dart', added: 8, removed: 3, status: 'M'),
];

const _kFiles2 = [
  MockFileChange(path: 'lib/src/features/history/history_column.dart', added: 112, removed: 34, status: 'M'),
  MockFileChange(path: 'lib/src/shared/theme/zanshin_colors.dart', added: 28, removed: 0, status: 'A'),
];

final kCommitsByBranch = <String, List<MockCommit>>{
  'main': [
    const MockCommit(
      changeId: 'kpwzlmq',
      subject: 'wip: refactor commit detail panel',
      author: 'Alice',
      date: 'now',
      isWorkingCopy: true,
      isEmpty: true,
      stats: MockCommitStats(added: 0, removed: 0, files: 0),
    ),
    const MockCommit(
      changeId: 'nqrstvw',
      subject: 'feat: add branch column resize',
      description: 'Drag handle between columns now lets you resize each pane independently.',
      author: 'Alice',
      date: '2h ago',
      files: _kFiles1,
      stats: MockCommitStats(added: 76, removed: 24, files: 5),
    ),
    const MockCommit(
      changeId: 'xyzabcd',
      subject: 'fix: scroll position lost on panel switch',
      author: 'Bob',
      date: 'yesterday',
      stats: MockCommitStats(added: 18, removed: 6, files: 2),
    ),
    const MockCommit(
      changeId: 'c3d4e5f',
      subject: 'chore: update dependencies to latest',
      author: 'Alice',
      date: 'Dec 10',
      stats: MockCommitStats(added: 8, removed: 8, files: 1),
    ),
    const MockCommit(
      changeId: 'b2c3d4e',
      subject: 'Add authentication module',
      author: 'Bob',
      date: 'Dec 2',
      version: 'v0.1.0',
      stats: MockCommitStats(added: 412, removed: 18, files: 11),
    ),
    const MockCommit(
      changeId: 'a1b2c3d',
      subject: 'Initial commit',
      author: 'Alice',
      date: 'Dec 1',
      stats: MockCommitStats(added: 1240, removed: 0, files: 32),
    ),
  ],
  'develop': [
    const MockCommit(
      changeId: 'vtxnbqr',
      subject: 'feat: status bar shows current branch',
      author: 'Charlie',
      date: '30m ago',
      files: _kFiles2,
      stats: MockCommitStats(added: 140, removed: 34, files: 2),
    ),
    const MockCommit(
      changeId: 'pqrstuv',
      subject: 'refactor: extract shared theme tokens',
      author: 'Alice',
      date: '4h ago',
      stats: MockCommitStats(added: 88, removed: 44, files: 7),
    ),
    const MockCommit(
      changeId: 'nqrstvw',
      subject: 'feat: add branch column resize',
      author: 'Alice',
      date: '2h ago',
      stats: MockCommitStats(added: 76, removed: 24, files: 5),
    ),
    const MockCommit(
      changeId: 'xyzabcd',
      subject: 'fix: scroll position lost on panel switch',
      author: 'Bob',
      date: 'yesterday',
      stats: MockCommitStats(added: 18, removed: 6, files: 2),
    ),
    const MockCommit(
      changeId: 'c3d4e5f',
      subject: 'chore: update dependencies to latest',
      author: 'Alice',
      date: 'Dec 10',
      stats: MockCommitStats(added: 8, removed: 8, files: 1),
    ),
    const MockCommit(
      changeId: 'b2c3d4e',
      subject: 'Add authentication module',
      author: 'Bob',
      date: 'Dec 2',
      version: 'v0.1.0',
      stats: MockCommitStats(added: 412, removed: 18, files: 11),
    ),
    const MockCommit(
      changeId: 'a1b2c3d',
      subject: 'Initial commit',
      author: 'Alice',
      date: 'Dec 1',
      stats: MockCommitStats(added: 1240, removed: 0, files: 32),
    ),
  ],
  'feature/new-ui': [
    const MockCommit(
      changeId: 'kpwzlmq',
      subject: 'wip: redesign commit detail pane',
      author: 'Alice',
      date: 'now',
      isWorkingCopy: true,
      bookmarks: ['feature/new-ui'],
      stats: MockCommitStats(added: 0, removed: 0, files: 0),
      isEmpty: true,
    ),
    const MockCommit(
      changeId: 'mqlbxzn',
      subject: 'feat: inline diff with syntax highlight',
      author: 'Alice',
      date: '1h ago',
      files: _kFiles1,
      stats: MockCommitStats(added: 220, removed: 55, files: 8),
    ),
    const MockCommit(
      changeId: 'abcdef1',
      subject: 'feat: collapsible file list in detail',
      author: 'Alice',
      date: '3h ago',
      stats: MockCommitStats(added: 78, removed: 12, files: 3),
    ),
    const MockCommit(
      changeId: 'abcdef2',
      subject: 'fix: detail panel overflows on small windows',
      author: 'Alice',
      date: 'yesterday',
      hasConflict: true,
      stats: MockCommitStats(added: 34, removed: 28, files: 4),
    ),
    const MockCommit(
      changeId: 'nqrstvw',
      subject: 'feat: add branch column resize',
      author: 'Alice',
      date: '2h ago',
      stats: MockCommitStats(added: 76, removed: 24, files: 5),
    ),
  ],
  'fix/ios-keyboard': [
    const MockCommit(
      changeId: 'iosfix1',
      subject: 'fix: keyboard dismissal on iOS branch list',
      author: 'Bob',
      date: '6h ago',
      files: _kFiles1,
      stats: MockCommitStats(added: 22, removed: 8, files: 2),
    ),
    const MockCommit(
      changeId: 'iosfix2',
      subject: 'fix: text field focus handling in search',
      author: 'Bob',
      date: 'yesterday',
      stats: MockCommitStats(added: 15, removed: 5, files: 1),
    ),
    const MockCommit(
      changeId: 'nqrstvw',
      subject: 'feat: add branch column resize',
      author: 'Alice',
      date: '2h ago',
      stats: MockCommitStats(added: 76, removed: 24, files: 5),
    ),
  ],
  'exp/riverpod-3': [
    const MockCommit(
      changeId: 'rv3exp1',
      subject: 'chore: migrate providers to Riverpod 3 API',
      author: 'Charlie',
      date: 'Dec 12',
      stats: MockCommitStats(added: 340, removed: 280, files: 18),
    ),
    const MockCommit(
      changeId: 'rv3exp2',
      subject: 'fix: async notifier lifecycle on hot reload',
      author: 'Charlie',
      date: 'Dec 11',
      stats: MockCommitStats(added: 45, removed: 18, files: 5),
    ),
  ],
};

const kBookmarks = [
  MockBookmark(name: 'main', head: 'a7c8d9e'),
  MockBookmark(name: 'develop', ahead: 2, head: 'b3f8a21'),
  MockBookmark(name: 'feature/new-ui', ahead: 6, current: true, head: 'kpwzlmq'),
  MockBookmark(name: 'fix/ios-keyboard', ahead: 2, behind: 1, head: 'vtxnbqr'),
  MockBookmark(name: 'exp/riverpod-3', ahead: 7, behind: 12, head: 'mqlbxzn'),
];

const kRemoteBranches = [
  MockRemoteBranch(name: 'origin/main', trackedBy: 'main'),
  MockRemoteBranch(name: 'origin/develop', trackedBy: 'develop', behindLocal: 2),
  MockRemoteBranch(name: 'origin/feature/new-ui', trackedBy: 'feature/new-ui', behindLocal: 6),
  MockRemoteBranch(name: 'origin/fix/ios-keyboard', trackedBy: 'fix/ios-keyboard', aheadOfLocal: 1, behindLocal: 2),
  MockRemoteBranch(name: 'origin/main-rc'),
  MockRemoteBranch(name: 'origin/release/1.5.x'),
];

const kInitialOpenBranches = ['main', 'develop', 'feature/new-ui'];

// ── Projects (home dialog) ───────────────────────────────────────────────────

const kProjects = [
  MockProject(
    id: 'p_myapp',
    name: 'myapp',
    path: '~/code/myapp',
    status: 'ahead',
    branch: 'feature/new-ui',
    ahead: 6,
    lastOpened: 'just now',
  ),
  MockProject(
    id: 'p_ripjj',
    name: 'ripjj',
    path: '~/code/ripjj',
    status: 'clean',
    lastOpened: '2h ago',
  ),
  MockProject(
    id: 'p_docs',
    name: 'docs',
    path: '~/code/docs',
    status: 'dirty',
    lastOpened: 'yesterday',
  ),
  MockProject(
    id: 'p_design',
    name: 'design',
    path: '~/code/design',
    status: 'behind',
    behind: 3,
    lastOpened: 'Dec 10',
  ),
  MockProject(
    id: 'p_api',
    name: 'backend-api',
    path: '~/code/backend-api',
    status: 'clean',
    branch: 'develop',
    lastOpened: 'Dec 8',
  ),
];
