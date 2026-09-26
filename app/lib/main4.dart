// SPDX-License-Identifier: MIT

// Commit graph proof of concept: 100 000 fake commits in a view that
// virtualizes in both axes — one card per row at (row, lane), edges painted by
// the viewport behind the cards, scroll extents computed from the data alone.
// The view lives in src/features/graph_poc/. Not wired into the real boot.
//
//   flutter run -d macos -t lib/main4.dart      (from `app/`)
//
// Background and measurements:
// _bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md
// The POC deliberately does NOT yet address the review findings in section 5
// of that doc (card keys/identity, delegate shouldRebuild, scroll anchoring
// across reloads, semantics clip, fake edge model); those are Epic 10
// acceptance items.
//
// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'package:flutter/src/widgets/_window.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yaru/yaru.dart';
import 'package:zanshin_shell/zanshin_shell.dart';

import 'src/features/graph_poc/commit_graph_view.dart';
import 'src/features/graph_poc/graph_data.dart';
import 'src/features/window/app_windows.dart';

/// Rows in the fake graph.
const _rowCount = 100000;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The only window has to be part of the warm-up frame (see
  // AppWindows.create).
  final WindowEntry window = await AppWindows().create(
    key: 'graph-poc',
    title: 'Commit graph POC',
    builder: (_) => const _DemoApp(),
  );
  runWidget(WindowManager(initialWindows: <WindowEntry>[window]));
}

class _DemoApp extends StatelessWidget {
  const _DemoApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Commit graph POC',
    debugShowCheckedModeBanner: false,
    theme: yaruLight,
    darkTheme: yaruDark,
    home: const _GraphPage(),
  );
}

class _GraphPage extends StatefulWidget {
  const _GraphPage();

  @override
  State<_GraphPage> createState() => _GraphPageState();
}

/// Owns the graph and both scroll controllers for the window's lifetime.
class _GraphPageState extends State<_GraphPage> {
  final _graph = CommitGraphData.fake(_rowCount);
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 52,
          child: WindowDragArea(
            child: Padding(
              // Leaves room for the traffic lights.
              padding: const EdgeInsets.only(left: 84),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Commit graph POC · $_rowCount rows', style: Theme.of(context).textTheme.titleSmall),
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ColoredBox(
            color: const Color(0xFF16171B),
            child: CommitGraphView(
              graph: _graph,
              onTap: (row) => debugPrint('tapped row $row'),
              verticalController: _vertical,
              horizontalController: _horizontal,
            ),
          ),
        ),
      ],
    ),
  );
}
