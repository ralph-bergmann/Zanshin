// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zanshin/src/features/branches/branches_panel.dart';
import 'package:zanshin/src/features/commits/commit_card.dart';
import 'package:zanshin/src/features/history/history_column.dart';
import 'package:zanshin/src/features/projects/home_dialog.dart';
import 'package:zanshin/src/features/shell/main_nav_rail.dart';
import 'package:zanshin/src/features/shell/status_bar.dart';
import 'package:zanshin/src/features/shell/window_title_bar.dart';
import 'package:zanshin/src/shared/data/mock_data.dart';
import 'package:zanshin/src/shared/theme/zanshin_colors.dart';
import 'package:zanshin/src/shared/widgets/zanshin_icon.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  NavPanel _activePanel = NavPanel.history;
  bool _homeOpen = true;
  String _activeProjectId = 'p_myapp';
  List<String> _openBranches = List.of(kInitialOpenBranches);
  AppThemeMode _themeMode = AppThemeMode.dark;

  String get _activeProjectName => kProjects.where((p) => p.id == _activeProjectId).firstOrNull?.name ?? 'myapp';
  String get _currentBranch => kBookmarks.where((b) => b.current).firstOrNull?.name ?? 'main';

  void _toggleBranch(String name) {
    setState(() {
      if (_openBranches.contains(name)) {
        _openBranches.remove(name);
      } else {
        _openBranches.add(name);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final zc = context.zc;
    return Scaffold(
      backgroundColor: zc.bg,
      body: KeyboardListener(
        focusNode: FocusNode()..requestFocus(),
        onKeyEvent: (e) {
          if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape && _homeOpen) {
            setState(() => _homeOpen = false);
          }
        },
        child: Stack(
        children: [
          // Main window
          Container(
            color: zc.bg,
            child: Column(
              children: [
                WindowTitleBar(
                  projectName: _activeProjectName,
                  themeMode: _themeMode,
                  onThemeMode: (m) => setState(() => _themeMode = m),
                ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      MainNavRail(
                        activePanel: _activePanel,
                        onSelectPanel: (p) => setState(() => _activePanel = p),
                        onHomePressed: () => setState(() => _homeOpen = true),
                        homeActive: _homeOpen,
                      ),
                      Expanded(
                        child: _MainArea(
                          activePanel: _activePanel,
                          openBranches: _openBranches,
                          onToggleBranch: _toggleBranch,
                          onSelectPanel: (p) => setState(() => _activePanel = p),
                          zc: zc,
                        ),
                      ),
                    ],
                  ),
                ),
                StatusBar(
                  currentBranch: _currentBranch,
                  openColumns: _openBranches.length,
                ),
              ],
            ),
          ),
          // Home dialog overlay
          if (_homeOpen)
            Positioned.fill(
              child: HomeDialog(
                activeProjectId: _activeProjectId,
                onOpenProject: (p) => setState(() {
                  _activeProjectId = p.id;
                  _homeOpen = false;
                }),
                onClose: () => setState(() => _homeOpen = false),
              ),
            ),
        ],
        ),
      ),
    );
  }
}

class _MainArea extends StatelessWidget {
  const _MainArea({
    required this.activePanel,
    required this.openBranches,
    required this.onToggleBranch,
    required this.onSelectPanel,
    required this.zc,
  });

  final NavPanel activePanel;
  final List<String> openBranches;
  final ValueChanged<String> onToggleBranch;
  final ValueChanged<NavPanel> onSelectPanel;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Left fixed panel (history / side panel)
        _LeftPanel(
          activePanel: activePanel,
          openBranches: openBranches,
          onToggle: onToggleBranch,
          onSelectPanel: onSelectPanel,
          zc: zc,
        ),
        // Scrollable branch columns
        if (openBranches.isNotEmpty)
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: openBranches.map((name) => BranchPanel(
                    key: ValueKey(name),
                    branchName: name,
                    onClose: () => onToggleBranch(name),
                  )).toList(),
                ),
              ),
            ),
          )
        else
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 12,
                children: [
                  ZanshinIcon(ZI.branch, size: 32, color: zc.textFaint),
                  Text('No branch columns open', style: TextStyle(fontSize: 14, color: zc.textDim)),
                  Text('Open a branch from the Branches panel', style: TextStyle(fontSize: 12, color: zc.textFaint)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _LeftPanel extends StatelessWidget {
  const _LeftPanel({
    required this.activePanel,
    required this.openBranches,
    required this.onToggle,
    required this.onSelectPanel,
    required this.zc,
  });

  final NavPanel activePanel;
  final List<String> openBranches;
  final ValueChanged<String> onToggle;
  final ValueChanged<NavPanel> onSelectPanel;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) {
    return switch (activePanel) {
      NavPanel.history => HistoryColumn(openBranches: openBranches),
      NavPanel.branches => BranchesPanel(openBranches: openBranches, onToggle: onToggle),
      NavPanel.workstream => SidePanel(
          title: 'Workstreams',
          icon: ZI.workstream,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  ZanshinIcon(ZI.workstream, size: 28, color: zc.textFaint),
                  Text('No workstreams yet.', style: TextStyle(color: zc.textDim, fontSize: 12)),
                  Text('Create one with\njj workstream new', style: TextStyle(color: zc.textFaint, fontSize: 11, fontFamily: 'monospace'), textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      NavPanel.reviews => SidePanel(
          title: 'Reviews',
          icon: ZI.reviews,
          child: Center(child: Text('No open reviews.', style: TextStyle(color: zc.textDim, fontSize: 12))),
        ),
      NavPanel.undo => const UndoPanel(),
    };
  }
}
