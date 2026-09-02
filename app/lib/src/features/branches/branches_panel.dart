// SPDX-License-Identifier: MIT

import 'package:material_ui/material_ui.dart';

import '../../shared/data/mock_data.dart';
import '../../shared/theme/zanshin_colors.dart';
import '../../shared/widgets/zanshin_icon.dart';

class BranchesPanel extends StatefulWidget {
  const BranchesPanel({required this.openBranches, required this.onToggle, super.key});
  final List<String> openBranches;
  final ValueChanged<String> onToggle;

  @override
  State<BranchesPanel> createState() => _BranchesPanelState();
}

class _BranchesPanelState extends State<BranchesPanel> {
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final ZanshinColors zc = context.zc;
    final String q = _query.trim().toLowerCase();
    final List<MockBookmark> local = kBookmarks.where((b) => q.isEmpty || b.name.toLowerCase().contains(q)).toList();
    final List<MockRemoteBranch> remote = kRemoteBranches
        .where((b) => q.isEmpty || b.name.toLowerCase().contains(q))
        .toList();

    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: zc.bgCard,
        border: Border(right: BorderSide(color: zc.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: zc.bgCard,
              border: Border(bottom: BorderSide(color: zc.border)),
            ),
            child: Row(
              spacing: 8,
              children: [
                ZanshinIcon(ZI.branch, size: 13, color: zc.textDim),
                Text(
                  'Branches',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: zc.textPrimary),
                ),
              ],
            ),
          ),
          // Search
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: zc.border)),
            ),
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: zc.bgCard2,
                border: Border.all(color: zc.border),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                spacing: 6,
                children: [
                  ZanshinIcon(ZI.search, size: 12, color: zc.textDim),
                  Expanded(
                    child: TextField(
                      onChanged: (v) => setState(() => _query = v),
                      style: TextStyle(fontSize: 12, color: zc.textPrimary),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Filter…',
                        hintStyle: TextStyle(fontSize: 12, color: zc.textDim),
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // List
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 10),
              children: [
                _SectionHeader(label: 'Local', count: local.length, zc: zc),
                if (local.isEmpty)
                  _EmptyLabel(zc: zc)
                else
                  ...local.map(
                    (b) => _LocalBranchRow(
                      bookmark: b,
                      isOpen: widget.openBranches.contains(b.name),
                      onTap: () => widget.onToggle(b.name),
                      zc: zc,
                    ),
                  ),
                const SizedBox(height: 6),
                _SectionHeader(label: 'Remote', count: remote.length, zc: zc),
                if (remote.isEmpty) _EmptyLabel(zc: zc) else ...remote.map((b) => _RemoteBranchRow(branch: b, zc: zc)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.count, required this.zc});
  final String label;
  final int count;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
    child: Row(
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(fontSize: 10, letterSpacing: 0.1, fontWeight: FontWeight.w600, color: zc.textFaint),
        ),
        const Spacer(),
        Text(
          '$count',
          style: TextStyle(fontSize: 10, color: zc.textDim, fontFamily: 'monospace'),
        ),
      ],
    ),
  );
}

class _EmptyLabel extends StatelessWidget {
  const _EmptyLabel({required this.zc});
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(18),
    child: Text(
      'no match',
      style: TextStyle(fontSize: 12, color: zc.textDim, fontStyle: FontStyle.italic),
      textAlign: TextAlign.center,
    ),
  );
}

class _LocalBranchRow extends StatefulWidget {
  const _LocalBranchRow({required this.bookmark, required this.isOpen, required this.onTap, required this.zc});
  final MockBookmark bookmark;
  final bool isOpen;
  final VoidCallback onTap;
  final ZanshinColors zc;

  @override
  State<_LocalBranchRow> createState() => _LocalBranchRowState();
}

class _LocalBranchRowState extends State<_LocalBranchRow> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ZanshinColors zc = widget.zc;
    final Color color = branchColor(widget.bookmark.name);
    final Color bg = widget.isOpen ? color.withAlpha(25) : (_hovered ? zc.bgCard2 : Colors.transparent);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            spacing: 8,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              Expanded(
                child: Text(
                  '${widget.bookmark.name}${widget.bookmark.current ? ' @' : ''}',
                  style: TextStyle(fontSize: 12.5, color: zc.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.bookmark.ahead > 0)
                Text(
                  '↑${widget.bookmark.ahead}',
                  style: TextStyle(fontSize: 10, color: zc.add, fontFamily: 'monospace'),
                ),
              if (widget.bookmark.behind > 0)
                Text(
                  '↓${widget.bookmark.behind}',
                  style: TextStyle(fontSize: 10, color: zc.rem, fontFamily: 'monospace'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RemoteBranchRow extends StatelessWidget {
  const _RemoteBranchRow({required this.branch, required this.zc});
  final MockRemoteBranch branch;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) {
    final Color color = branch.trackedBy != null ? branchColor(branch.trackedBy!) : zc.textDim;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      margin: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        spacing: 8,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color.withAlpha(branch.trackedBy != null ? 255 : 100),
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Text(
              branch.name,
              style: TextStyle(fontSize: 12.5, color: branch.trackedBy != null ? zc.textMuted : zc.textDim),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (branch.aheadOfLocal > 0)
            Text(
              '↑${branch.aheadOfLocal}',
              style: TextStyle(fontSize: 10, color: zc.add, fontFamily: 'monospace'),
            ),
          if (branch.behindLocal > 0)
            Text(
              '↓${branch.behindLocal}',
              style: TextStyle(fontSize: 10, color: zc.rem, fontFamily: 'monospace'),
            ),
        ],
      ),
    );
  }
}

// ── Side panels for workstream / reviews / undo ──────────────────────────────

class SidePanel extends StatelessWidget {
  const SidePanel({required this.title, required this.icon, required this.child, super.key});
  final String title;
  final String icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ZanshinColors zc = context.zc;
    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: zc.bgCard,
        border: Border(right: BorderSide(color: zc.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: zc.bgCard,
              border: Border(bottom: BorderSide(color: zc.border)),
            ),
            child: Row(
              spacing: 8,
              children: [
                ZanshinIcon(icon, size: 13, color: zc.textDim),
                Text(
                  title,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: zc.textPrimary),
                ),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class UndoPanel extends StatelessWidget {
  const UndoPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final ZanshinColors zc = context.zc;
    const ops = [
      ('describe -m "wip: refactor"', '8 min ago', true),
      ('new -A @', '12 min ago', false),
      ('git fetch', '2h ago', false),
      ('rebase -d main', '3h ago', false),
      ('bookmark create feat/onboarding', 'yesterday', false),
    ];
    return SidePanel(
      title: 'Undo Timeline',
      icon: ZI.undo,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 6),
        children: ops.map((op) {
          final (label, time, isActive) = op;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Row(
              spacing: 10,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    color: isActive ? zc.accent : zc.textDim,
                    shape: BoxShape.circle,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Text(
                        label,
                        style: TextStyle(fontSize: 12, color: zc.textPrimary, fontFamily: 'monospace'),
                      ),
                      Text(time, style: TextStyle(fontSize: 10, color: zc.textDim)),
                    ],
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}
