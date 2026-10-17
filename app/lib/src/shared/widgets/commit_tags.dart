// SPDX-License-Identifier: MIT

import 'package:material_ui/material_ui.dart';

import '../design/zs_metrics.dart';
import '../theme/zanshin_colors.dart';
import 'zanshin_icon.dart';

class CommitTag extends StatelessWidget {
  const CommitTag._({required this.label, required this.bg, required this.fg, this.icon});

  factory CommitTag.workingCopy() => const CommitTag._(
    label: '@ working copy',
    bg: Color(0x1A3b82f6),
    fg: Color(0xFF60a5fa),
  );

  factory CommitTag.empty() => const CommitTag._(
    label: 'empty',
    bg: Color(0x1A6b7280),
    fg: Color(0xFF9ca3af),
  );

  factory CommitTag.merge() => const CommitTag._(
    label: 'merge',
    bg: Color(0x1A6b7280),
    fg: Color(0xFF9ca3af),
  );

  factory CommitTag.version(String v) => CommitTag._(
    label: v,
    bg: const Color(0x1Af59e0b),
    fg: const Color(0xFFfbbf24),
  );

  factory CommitTag.conflict() => const CommitTag._(
    label: 'conflict',
    bg: Color(0x1Af87171),
    fg: Color(0xFFf87171),
    icon: ZI.conflict,
  );

  factory CommitTag.bookmark(String name) => CommitTag._(
    label: name,
    bg: const Color(0x1A3b82f6),
    fg: const Color(0xFF3b82f6),
  );

  final String label;
  final Color bg;
  final Color fg;
  final String? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: fg.withAlpha(60)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        if (icon != null) ZanshinIcon(icon!, size: ZsIconSize.xs, color: fg),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: fg,
            height: 1,
          ),
        ),
      ],
    ),
  );
}

// Renders the row of tags for a commit card header.
class CommitTagRow extends StatelessWidget {
  const CommitTagRow({
    super.key,
    this.isWorkingCopy = false,
    this.isEmpty = false,
    this.isMerge = false,
    this.hasConflict = false,
    this.version,
    this.bookmarks = const [],
  });

  final bool isWorkingCopy;
  final bool isEmpty;
  final bool isMerge;
  final bool hasConflict;
  final String? version;
  final List<String> bookmarks;

  bool get hasAny => isWorkingCopy || isEmpty || isMerge || hasConflict || version != null || bookmarks.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    if (!hasAny) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        if (isWorkingCopy) CommitTag.workingCopy(),
        if (isEmpty) CommitTag.empty(),
        if (isMerge) CommitTag.merge(),
        if (version != null) CommitTag.version(version!),
        if (hasConflict) CommitTag.conflict(),
        for (final b in bookmarks) CommitTag.bookmark(b),
      ],
    );
  }
}

// Stat badge showing +added / -removed counts.
class DiffStatBadge extends StatelessWidget {
  const DiffStatBadge({required this.added, required this.removed, super.key});
  final int added;
  final int removed;

  @override
  Widget build(BuildContext context) {
    final ZanshinColors zc = context.zc;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        Text(
          '+$added',
          style: TextStyle(fontSize: 10, color: zc.add, fontFamily: 'monospace'),
        ),
        Text(
          '−$removed',
          style: TextStyle(fontSize: 10, color: zc.rem, fontFamily: 'monospace'),
        ),
      ],
    );
  }
}
