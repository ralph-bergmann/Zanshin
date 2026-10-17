// SPDX-License-Identifier: MIT

import 'package:material_ui/material_ui.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../shared/data/mock_data.dart';
import '../../shared/theme/zanshin_colors.dart';
import '../../shared/widgets/commit_tags.dart';
import 'diff_block.dart';

class CommitDetail extends StatefulWidget {
  const CommitDetail({
    required this.commit,
    required this.branchColor,
    required this.onClose,
    super.key,
  });

  final MockCommit commit;
  final Color branchColor;
  final VoidCallback onClose;

  @override
  State<CommitDetail> createState() => _CommitDetailState();
}

class _CommitDetailState extends State<CommitDetail> {
  String? _selectedFile;
  DiffMode _diffMode = DiffMode.inline;

  @override
  void initState() {
    super.initState();
    _selectedFile = widget.commit.files.isNotEmpty ? widget.commit.files.first.path : null;
  }

  @override
  void didUpdateWidget(CommitDetail old) {
    super.didUpdateWidget(old);
    if (old.commit.changeId != widget.commit.changeId) {
      _selectedFile = widget.commit.files.isNotEmpty ? widget.commit.files.first.path : null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZanshinColors zc = context.zc;
    final MockCommit commit = widget.commit;

    return Container(
      width: 440,
      decoration: BoxDecoration(
        color: zc.bgCard,
        border: Border(left: BorderSide(color: widget.branchColor.withAlpha(100))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: CommitTagRow(
                    isWorkingCopy: commit.isWorkingCopy,
                    isEmpty: commit.isEmpty,
                    isMerge: commit.isMerge,
                    hasConflict: commit.hasConflict,
                    version: commit.version,
                  ),
                ),
                GestureDetector(
                  onTap: widget.onClose,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(5)),
                    child: Center(
                      child: ZanshinIcon(ZI.close, size: ZsIconSize.sm, color: zc.textDim),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Subject
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              commit.subject,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: zc.textPrimary, height: 1.3),
            ),
          ),
          // Scrollable body
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 10,
                children: [
                  // Meta card
                  _MetaCard(commit: commit, zc: zc),
                  // Description
                  if (commit.description.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: zc.bgCard2.withAlpha(60),
                        border: Border(left: BorderSide(color: zc.borderStrong, width: 2)),
                        borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(4),
                          bottomRight: Radius.circular(4),
                        ),
                      ),
                      child: Text(
                        commit.description,
                        style: TextStyle(fontSize: 11.5, color: zc.textMuted, height: 1.5),
                      ),
                    ),
                  // Files
                  if (commit.files.isNotEmpty) ...[
                    _FilesSection(
                      files: commit.files,
                      stats: commit.stats,
                      selected: _selectedFile,
                      onSelect: (p) => setState(() => _selectedFile = p),
                      zc: zc,
                    ),
                  ],
                  // Diff
                  if (_selectedFile != null)
                    DiffBlock(
                      filePath: _selectedFile!,
                      mode: _diffMode,
                      onModeChanged: (m) => setState(() => _diffMode = m),
                    ),
                  // Actions
                  _ActionRow(zc: zc),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaCard extends StatelessWidget {
  const _MetaCard({required this.commit, required this.zc});
  final MockCommit commit;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: zc.bgCard2,
      border: Border.all(color: zc.border),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Column(
      spacing: 6,
      children: [
        _MetaRow(icon: ZI.user, text: commit.author, zc: zc),
        _MetaRow(icon: ZI.calendar, text: commit.date == 'now' ? 'just now' : commit.date, zc: zc),
        _MetaRow(icon: ZI.hash, text: commit.changeId, mono: true, zc: zc),
        if (commit.parents.isNotEmpty)
          _MetaRow(icon: ZI.chevronLeft, label: 'parent', text: commit.parents.first, mono: true, zc: zc),
      ],
    ),
  );
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.icon, required this.text, required this.zc, this.label, this.mono = false});
  final String icon;
  final String text;
  final String? label;
  final bool mono;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 6,
    children: [
      ZanshinIcon(icon, size: ZsIconSize.sm, color: zc.textDim),
      if (label != null) Text(label!, style: TextStyle(fontSize: 11, color: zc.textDim)),
      Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: zc.textMuted,
          fontFamily: mono ? 'monospace' : null,
        ),
      ),
    ],
  );
}

class _FilesSection extends StatelessWidget {
  const _FilesSection({
    required this.files,
    required this.stats,
    required this.selected,
    required this.onSelect,
    required this.zc,
  });
  final List<MockFileChange> files;
  final MockCommitStats stats;
  final String? selected;
  final ValueChanged<String> onSelect;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 4,
    children: [
      // Section header
      Row(
        spacing: 6,
        children: [
          ZanshinIcon(ZI.fileText, size: ZsIconSize.sm, color: zc.textDim),
          Text(
            'Changed files (${files.length})',
            style: TextStyle(fontSize: 11, color: zc.textDim, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          DiffStatBadge(added: stats.added, removed: stats.removed),
        ],
      ),
      // File list
      Container(
        decoration: BoxDecoration(
          color: zc.bgCard2,
          border: Border.all(color: zc.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          children: files.map((f) {
            final isSelected = f.path == selected;
            final Color statusColor = switch (f.status) {
              'A' => zc.add,
              'D' => zc.rem,
              'M' => zc.hunk,
              _ => zc.textMuted,
            };
            return GestureDetector(
              onTap: () => onSelect(f.path),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isSelected ? zc.bgElevated : Colors.transparent,
                  border: Border(bottom: BorderSide(color: zc.border)),
                ),
                child: Row(
                  spacing: 8,
                  children: [
                    SizedBox(
                      width: 14,
                      child: Text(
                        f.status,
                        style: TextStyle(
                          fontSize: 10,
                          color: statusColor,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        f.path,
                        style: TextStyle(fontSize: 11, color: zc.textMuted, fontFamily: 'monospace'),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DiffStatBadge(added: f.added, removed: f.removed),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    ],
  );
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.zc});
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 6,
    children: [
      _ActionBtn(label: 'Edit', primary: true, zc: zc),
      _ActionBtn(label: 'Squash', zc: zc),
      _ActionBtn(label: 'Abandon', zc: zc),
      _ActionBtn(label: 'Rebase…', zc: zc),
    ],
  );
}

class _ActionBtn extends StatefulWidget {
  const _ActionBtn({required this.label, required this.zc, this.primary = false});
  final String label;
  final bool primary;
  final ZanshinColors zc;

  @override
  State<_ActionBtn> createState() => _ActionBtnState();
}

class _ActionBtnState extends State<_ActionBtn> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Color bg = widget.primary ? (widget.zc.accent) : (_hovered ? widget.zc.bgElevated : widget.zc.bgCard2);
    final Color fg = widget.primary ? Colors.white : widget.zc.textMuted;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: widget.primary ? widget.zc.accent : widget.zc.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(widget.label, style: TextStyle(fontSize: 12, color: fg)),
      ),
    );
  }
}
