// SPDX-License-Identifier: MIT

import 'package:material_ui/material_ui.dart';

import '../../shared/data/mock_data.dart';
import '../../shared/design/zs_metrics.dart';
import '../../shared/theme/zanshin_colors.dart';
import '../../shared/widgets/commit_tags.dart';
import '../../shared/widgets/zanshin_icon.dart';
import 'commit_detail.dart';

class BranchPanel extends StatefulWidget {
  const BranchPanel({
    required this.branchName,
    required this.onClose,
    super.key,
  });

  final String branchName;
  final VoidCallback onClose;

  @override
  State<BranchPanel> createState() => _BranchPanelState();
}

class _BranchPanelState extends State<BranchPanel> {
  String? _selectedChangeId;

  @override
  Widget build(BuildContext context) {
    final ZanshinColors zc = context.zc;
    final Color color = branchColor(widget.branchName);
    final List<MockCommit> commits = kCommitsByBranch[widget.branchName] ?? [];
    final MockBookmark? bookmark = kBookmarks.where((b) => b.name == widget.branchName).firstOrNull;
    final MockCommit? selectedCommit = commits.where((c) => c.changeId == _selectedChangeId).firstOrNull;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Branch column
        Container(
          width: 320,
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: zc.border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              _BranchHeader(
                name: widget.branchName,
                color: color,
                bookmark: bookmark,
                onClose: widget.onClose,
                zc: zc,
              ),
              // Commit list
              Expanded(
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: commits.length,
                  itemBuilder: (context, i) {
                    final MockCommit commit = commits[i];
                    final isSelected = commit.changeId == _selectedChangeId;
                    return _CommitCard(
                      commit: commit,
                      branchColor: color,
                      isSelected: isSelected,
                      onTap: () => setState(() {
                        _selectedChangeId = isSelected ? null : commit.changeId;
                      }),
                      zc: zc,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        // Inline detail panel
        if (selectedCommit != null)
          CommitDetail(
            commit: selectedCommit,
            branchColor: color,
            onClose: () => setState(() => _selectedChangeId = null),
          ),
      ],
    );
  }
}

class _BranchHeader extends StatelessWidget {
  const _BranchHeader({
    required this.name,
    required this.color,
    required this.bookmark,
    required this.onClose,
    required this.zc,
  });
  final String name;
  final Color color;
  final MockBookmark? bookmark;
  final VoidCallback onClose;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => Container(
    height: 36,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: zc.bgCard,
      border: Border(
        bottom: BorderSide(color: zc.border),
        top: BorderSide(color: color.withAlpha(80), width: 2),
      ),
    ),
    child: Row(
      children: [
        ZanshinIcon(ZI.branch, size: ZsIconSize.md, color: color),
        const SizedBox(width: 6),
        Text(
          name,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: zc.textPrimary),
        ),
        const Spacer(),
        if ((bookmark?.ahead ?? 0) > 0) ...[
          _Pill(label: '↑${bookmark!.ahead}', color: zc.add, zc: zc),
          const SizedBox(width: 4),
        ],
        if (bookmark?.current == true) ...[
          _Pill(label: '@', color: color, zc: zc),
          const SizedBox(width: 4),
        ],
        _CloseBtn(onClose: onClose, zc: zc),
      ],
    ),
  );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color, required this.zc});
  final String label;
  final Color color;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withAlpha(30),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 10, color: color, fontFamily: 'monospace'),
    ),
  );
}

class _CloseBtn extends StatefulWidget {
  const _CloseBtn({required this.onClose, required this.zc});
  final VoidCallback onClose;
  final ZanshinColors zc;

  @override
  State<_CloseBtn> createState() => _CloseBtnState();
}

class _CloseBtnState extends State<_CloseBtn> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: GestureDetector(
      onTap: widget.onClose,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: _hovered ? widget.zc.bgCard2 : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Center(
          child: ZanshinIcon(
            ZI.close,
            size: ZsIconSize.sm,
            color: _hovered ? widget.zc.textPrimary : widget.zc.textDim,
          ),
        ),
      ),
    ),
  );
}

class _CommitCard extends StatefulWidget {
  const _CommitCard({
    required this.commit,
    required this.branchColor,
    required this.isSelected,
    required this.onTap,
    required this.zc,
  });
  final MockCommit commit;
  final Color branchColor;
  final bool isSelected;
  final VoidCallback onTap;
  final ZanshinColors zc;

  @override
  State<_CommitCard> createState() => _CommitCardState();
}

class _CommitCardState extends State<_CommitCard> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ZanshinColors zc = widget.zc;
    final MockCommit commit = widget.commit;
    final bool isWc = commit.isWorkingCopy;

    Color bg;
    Color borderColor;
    if (widget.isSelected) {
      bg = zc.bgElevated;
      borderColor = widget.branchColor;
    } else if (_hovered) {
      bg = zc.bgElevated;
      borderColor = zc.borderStrong;
    } else {
      bg = zc.bgCard;
      borderColor = zc.border;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(7),
            boxShadow: widget.isSelected ? [BoxShadow(color: widget.branchColor.withAlpha(40), blurRadius: 8)] : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 6,
            children: [
              // Working-copy ribbon
              if (isWc)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: widget.branchColor.withAlpha(20),
                    border: Border.all(color: widget.branchColor.withAlpha(60)),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Row(
                    spacing: 6,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(color: widget.branchColor, shape: BoxShape.circle),
                      ),
                      Text(
                        '@ Checked out',
                        style: TextStyle(fontSize: 10, color: widget.branchColor, fontWeight: FontWeight.w500),
                      ),
                      const Spacer(),
                      Text(
                        'code changes go here',
                        style: TextStyle(fontSize: 10, color: widget.branchColor.withAlpha(180)),
                      ),
                    ],
                  ),
                ),
              // Tags
              CommitTagRow(
                isEmpty: commit.isEmpty,
                isMerge: commit.isMerge,
                hasConflict: commit.hasConflict,
                version: commit.version,
                bookmarks: commit.bookmarks,
              ),
              // Subject
              Text(
                commit.subject,
                style: TextStyle(fontSize: 12.5, color: zc.textPrimary, fontWeight: FontWeight.w500, height: 1.3),
              ),
              // Footer
              Row(
                spacing: 8,
                children: [
                  Text(
                    commit.changeId,
                    style: TextStyle(fontSize: 10, color: zc.textDim, fontFamily: 'monospace'),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 3,
                    children: [
                      ZanshinIcon(ZI.user, size: ZsIconSize.sm, color: zc.textDim),
                      Text(commit.author.split(' ').first, style: TextStyle(fontSize: 10, color: zc.textDim)),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 3,
                    children: [
                      ZanshinIcon(ZI.calendar, size: ZsIconSize.sm, color: zc.textDim),
                      Text(commit.date, style: TextStyle(fontSize: 10, color: zc.textDim)),
                    ],
                  ),
                  if (commit.stats.added > 0 || commit.stats.removed > 0) ...[
                    const Spacer(),
                    DiffStatBadge(added: commit.stats.added, removed: commit.stats.removed),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
