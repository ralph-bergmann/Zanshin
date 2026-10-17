// SPDX-License-Identifier: MIT

import 'package:material_ui/material_ui.dart';

import '../../shared/data/mock_data.dart';
import '../../shared/design/zs_metrics.dart';
import '../../shared/theme/zanshin_colors.dart';
import '../../shared/widgets/zanshin_icon.dart';

class HistoryColumn extends StatefulWidget {
  const HistoryColumn({required this.openBranches, super.key});
  final List<String> openBranches;

  @override
  State<HistoryColumn> createState() => _HistoryColumnState();
}

class _HistoryColumnState extends State<HistoryColumn> {
  String? _hoveredId;
  String? _selectedId;

  // Merge all commits from all branches into a deduped list ordered by branch first
  List<({MockCommit commit, Color color, String branch})> _buildRows() {
    final seen = <String>{};
    final rows = <({MockCommit commit, Color color, String branch})>[];
    for (final MockBookmark b in kBookmarks) {
      final List<MockCommit> commits = kCommitsByBranch[b.name] ?? [];
      final Color color = branchColor(b.name);
      for (final c in commits) {
        if (!seen.contains(c.changeId)) {
          seen.add(c.changeId);
          rows.add((commit: c, color: color, branch: b.name));
        }
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final ZanshinColors zc = context.zc;
    final List<({String branch, Color color, MockCommit commit})> rows = _buildRows();

    return Container(
      width: 400,
      decoration: BoxDecoration(
        color: zc.bgHistory,
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
              spacing: 6,
              children: [
                ZanshinIcon(ZI.history, size: ZsIconSize.md, color: zc.textDim),
                Text(
                  'History',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: zc.textPrimary),
                ),
                Text('${rows.length} commits', style: TextStyle(fontSize: 11, color: zc.textDim)),
              ],
            ),
          ),
          // Lane legend
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: zc.border)),
            ),
            child: Wrap(
              spacing: 10,
              runSpacing: 4,
              children: kBookmarks.map((b) {
                final Color c = branchColor(b.name);
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                    ),
                    Text(b.name, style: TextStyle(fontSize: 10, color: zc.textMuted)),
                  ],
                );
              }).toList(),
            ),
          ),
          // Commit rows
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final ({String branch, Color color, MockCommit commit}) row = rows[i];
                final isSelected = _selectedId == row.commit.changeId;
                final bool isHovered = _hoveredId == row.commit.changeId && !isSelected;
                return _HistoryRow(
                  commit: row.commit,
                  laneColor: row.color,
                  isSelected: isSelected,
                  isHovered: isHovered,
                  onTap: () => setState(() => _selectedId = isSelected ? null : row.commit.changeId),
                  onHover: (v) => setState(() => _hoveredId = v ? row.commit.changeId : null),
                  zc: zc,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.commit,
    required this.laneColor,
    required this.isSelected,
    required this.isHovered,
    required this.onTap,
    required this.onHover,
    required this.zc,
  });
  final MockCommit commit;
  final Color laneColor;
  final bool isSelected;
  final bool isHovered;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) {
    Color bg;
    if (isSelected) {
      bg = zc.accent.withAlpha(46);
    } else if (isHovered) {
      bg = Colors.white.withAlpha(18);
    } else {
      bg = Colors.transparent;
    }

    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            spacing: 8,
            children: [
              // Lane node
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: commit.isWorkingCopy ? laneColor : Colors.transparent,
                  border: Border.all(color: laneColor, width: commit.isWorkingCopy ? 0 : 1.5),
                  shape: commit.hasConflict ? BoxShape.rectangle : BoxShape.circle,
                  borderRadius: commit.hasConflict ? BorderRadius.circular(2) : null,
                ),
              ),
              // Change ID
              SizedBox(
                width: 56,
                child: Text(
                  commit.changeId,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: isSelected ? zc.textPrimary : zc.textDim,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              // Subject + badges
              Expanded(
                child: Row(
                  spacing: 6,
                  children: [
                    if (commit.isEmpty)
                      Text(
                        '(empty)',
                        style: TextStyle(fontSize: 11, color: zc.textFaint, fontStyle: FontStyle.italic),
                      ),
                    Expanded(
                      child: Text(
                        commit.subject,
                        style: TextStyle(fontSize: 12, color: isSelected ? zc.textPrimary : zc.textMuted),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (commit.isWorkingCopy) _Badge(label: '@', color: laneColor),
                    if (commit.version != null) _Badge(label: commit.version!, color: const Color(0xFFfbbf24)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withAlpha(35),
      border: Border.all(color: color.withAlpha(100)),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 10, color: color, fontFamily: 'monospace'),
    ),
  );
}
