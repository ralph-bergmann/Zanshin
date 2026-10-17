// SPDX-License-Identifier: MIT

import 'package:material_ui/material_ui.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../shared/data/mock_data.dart';
import '../../shared/theme/zanshin_colors.dart';

enum DiffMode { inline, split }

class DiffBlock extends StatefulWidget {
  const DiffBlock({
    required this.filePath,
    super.key,
    this.mode = DiffMode.inline,
    this.onModeChanged,
  });

  final String filePath;
  final DiffMode mode;
  final ValueChanged<DiffMode>? onModeChanged;

  @override
  State<DiffBlock> createState() => _DiffBlockState();
}

class _DiffBlockState extends State<DiffBlock> {
  var _viewed = false;

  @override
  Widget build(BuildContext context) {
    final ZanshinColors zc = context.zc;
    return Container(
      decoration: BoxDecoration(
        color: zc.bgHistory,
        border: Border.all(color: zc.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Toolbar
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: zc.bgCard,
              border: Border(bottom: BorderSide(color: zc.border)),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.filePath,
                    style: TextStyle(fontSize: 11, color: zc.textMuted, fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                _ModeToggle(mode: widget.mode, onChanged: widget.onModeChanged, zc: zc),
                const SizedBox(width: 8),
                _ViewedToggle(viewed: _viewed, onTap: () => setState(() => _viewed = !_viewed), zc: zc),
              ],
            ),
          ),
          // Body
          if (_viewed)
            _CollapsedDiff(onExpand: () => setState(() => _viewed = false), zc: zc)
          else if (widget.mode == DiffMode.split)
            _SplitDiff(zc: zc)
          else
            _InlineDiff(zc: zc),
        ],
      ),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.mode, required this.onChanged, required this.zc});
  final DiffMode mode;
  final ValueChanged<DiffMode>? onChanged;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: zc.bgCard2,
      border: Border.all(color: zc.border),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SegBtn(
          label: 'Inline',
          icon: ZI.splitInline,
          active: mode == DiffMode.inline,
          onTap: () => onChanged?.call(DiffMode.inline),
          zc: zc,
        ),
        _SegBtn(
          label: 'Split',
          icon: ZI.splitSide,
          active: mode == DiffMode.split,
          onTap: () => onChanged?.call(DiffMode.split),
          zc: zc,
        ),
      ],
    ),
  );
}

class _SegBtn extends StatelessWidget {
  const _SegBtn({required this.label, required this.icon, required this.active, required this.onTap, required this.zc});
  final String label;
  final String icon;
  final bool active;
  final VoidCallback onTap;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: active ? zc.bgElevated : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          ZanshinIcon(icon, size: ZsIconSize.sm, color: active ? zc.textPrimary : zc.textDim),
          Text(label, style: TextStyle(fontSize: 11, color: active ? zc.textPrimary : zc.textDim)),
        ],
      ),
    ),
  );
}

class _ViewedToggle extends StatelessWidget {
  const _ViewedToggle({required this.viewed, required this.onTap, required this.zc});
  final bool viewed;
  final VoidCallback onTap;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 5,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: viewed ? zc.accent : Colors.transparent,
            border: Border.all(color: viewed ? zc.accent : zc.borderStrong),
            borderRadius: BorderRadius.circular(3),
          ),
          child: viewed
              ? const Center(
                  child: ZanshinIcon(ZI.check, size: ZsIconSize.xs, color: Colors.white),
                )
              : null,
        ),
        Text('Viewed', style: TextStyle(fontSize: 11, color: viewed ? zc.textPrimary : zc.textMuted)),
      ],
    ),
  );
}

class _CollapsedDiff extends StatelessWidget {
  const _CollapsedDiff({required this.onExpand, required this.zc});
  final VoidCallback onExpand;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onExpand,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        spacing: 8,
        children: [
          ZanshinIcon(ZI.check, size: ZsIconSize.sm, color: zc.add),
          Text(
            'Reviewed — diff hidden. Click to expand.',
            style: TextStyle(fontSize: 12, color: zc.textDim, fontStyle: FontStyle.italic),
          ),
        ],
      ),
    ),
  );
}

class _InlineDiff extends StatelessWidget {
  const _InlineDiff({required this.zc});
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: kSampleDiff.map((line) {
        if (line.type == 'hunk') {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: Text(
              line.text,
              style: TextStyle(fontSize: 11, color: zc.hunk, fontFamily: 'monospace'),
            ),
          );
        }
        final isAdd = line.type == 'add';
        final isRem = line.type == 'remove';
        return Container(
          color: isAdd ? zc.addBg : (isRem ? zc.remBg : Colors.transparent),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 14,
                child: Text(
                  isAdd ? '+' : (isRem ? '−' : ' '),
                  style: TextStyle(
                    fontSize: 11,
                    color: isAdd ? zc.add : (isRem ? zc.rem : zc.textDim),
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  line.text,
                  style: TextStyle(
                    fontSize: 11,
                    color: isAdd ? zc.add : (isRem ? zc.rem : zc.textMuted),
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    ),
  );
}

class _SplitDiff extends StatelessWidget {
  const _SplitDiff({required this.zc});
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) {
    // Build paired rows (remove+add pairs shown side by side)
    final rows = <({DiffLine? left, DiffLine? right, String? hunk})>[];
    var i = 0;
    while (i < kSampleDiff.length) {
      final DiffLine l = kSampleDiff[i];
      if (l.type == 'hunk') {
        rows.add((left: null, right: null, hunk: l.text));
        i++;
        continue;
      }
      if (l.type == 'remove' && i + 1 < kSampleDiff.length && kSampleDiff[i + 1].type == 'add') {
        rows.add((left: l, right: kSampleDiff[i + 1], hunk: null));
        i += 2;
        continue;
      }
      if (l.type == 'add') {
        rows.add((left: null, right: l, hunk: null));
      } else {
        rows.add((left: l, right: l, hunk: null));
      }
      i++;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: rows.map((row) {
          if (row.hunk != null) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              child: Text(
                row.hunk!,
                style: TextStyle(fontSize: 11, color: zc.hunk, fontFamily: 'monospace'),
              ),
            );
          }
          return IntrinsicHeight(
            child: Row(
              children: [
                Expanded(
                  child: _SplitSide(line: row.left, zc: zc),
                ),
                Container(width: 1, color: zc.border),
                Expanded(
                  child: _SplitSide(line: row.right, zc: zc),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _SplitSide extends StatelessWidget {
  const _SplitSide({required this.line, required this.zc});
  final DiffLine? line;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) {
    if (line == null) {
      return Container(color: zc.bgCard2, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1));
    }
    final isAdd = line!.type == 'add';
    final isRem = line!.type == 'remove';
    return Container(
      color: isAdd ? zc.addBg : (isRem ? zc.remBg : Colors.transparent),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Text(
        line!.text,
        style: TextStyle(
          fontSize: 11,
          color: isAdd ? zc.add : (isRem ? zc.rem : zc.textMuted),
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}
