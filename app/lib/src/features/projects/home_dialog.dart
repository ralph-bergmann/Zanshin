// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import '../../shared/data/mock_data.dart';
import '../../shared/theme/zanshin_colors.dart';
import '../../shared/widgets/zanshin_icon.dart';

class HomeDialog extends StatefulWidget {
  const HomeDialog({
    required this.activeProjectId,
    required this.onOpenProject,
    required this.onClose,
    super.key,
  });

  final String activeProjectId;
  final ValueChanged<MockProject> onOpenProject;
  final VoidCallback onClose;

  @override
  State<HomeDialog> createState() => _HomeDialogState();
}

class _HomeDialogState extends State<HomeDialog> {
  var _query = '';
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.activeProjectId;
  }

  List<MockProject> get _filtered {
    final String q = _query.trim().toLowerCase();
    if (q.isEmpty) {
      return kProjects;
    }
    return kProjects.where((p) => p.name.toLowerCase().contains(q) || p.path.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final ZanshinColors zc = context.zc;
    return GestureDetector(
      onTap: widget.onClose,
      child: Container(
        color: Colors.black.withAlpha(140),
        child: Center(
          child: GestureDetector(
            onTap: () {}, // absorb taps
            child: Container(
              width: 760,
              height: 520,
              decoration: BoxDecoration(
                color: zc.bgWindow,
                border: Border.all(color: zc.borderStrong),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(color: Colors.black.withAlpha(180), blurRadius: 60, offset: const Offset(0, 20))],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Row(
                  children: [
                    _HomeSide(activeProjectId: widget.activeProjectId, zc: zc),
                    Expanded(
                      child: _HomeMain(
                        query: _query,
                        onQueryChanged: (v) => setState(() => _query = v),
                        projects: _filtered,
                        selectedId: _selectedId,
                        activeProjectId: widget.activeProjectId,
                        onSelect: (id) => setState(() => _selectedId = id),
                        onOpen: widget.onOpenProject,
                        onClose: widget.onClose,
                        zc: zc,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeSide extends StatelessWidget {
  const _HomeSide({required this.activeProjectId, required this.zc});
  final String activeProjectId;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => Container(
    width: 220,
    decoration: BoxDecoration(
      color: zc.bgSidebar,
      border: Border(right: BorderSide(color: zc.border)),
    ),
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Brand
        Row(
          spacing: 10,
          children: [
            _ZanshinMarkSmall(),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Zanshin',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: zc.textPrimary),
                ),
                Text('jj client · v0.24.0', style: TextStyle(fontSize: 10, color: zc.textDim)),
              ],
            ),
          ],
        ),
        const SizedBox(height: 20),
        // Nav
        _SideNavItem(icon: ZI.folderOpen, label: 'Projects', active: true, zc: zc),
        _SideNavItem(icon: ZI.cloud, label: 'Remotes', active: false, zc: zc),
        _SideNavItem(icon: ZI.settings, label: 'Settings', active: false, zc: zc),
        const Spacer(),
        // User footer
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: zc.bgCard,
            border: Border.all(color: zc.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            spacing: 8,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFF3b82f6), Color(0xFFa855f7)]),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Center(
                  child: Text(
                    'A',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text('Alice Sralph', style: TextStyle(fontSize: 12, color: zc.textPrimary)),
                    Text(
                      'alice@dasralph.de',
                      style: TextStyle(fontSize: 10, color: zc.textDim),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ZanshinMarkSmall extends StatelessWidget {
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 32,
    height: 32,
    child: CustomPaint(painter: _MarkPainter()),
  );
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width / 256.0;
    canvas.scale(s, s);
    final bg = Paint()..color = const Color(0xFFF5ECD6);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 256, 256), const Radius.circular(58)), bg);
    final ink = Paint()
      ..color = const Color(0xFF1a1413)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    void arc(Offset from, Offset to, double w) {
      ink.strokeWidth = w;
      final path = Path()
        ..moveTo(from.dx, from.dy)
        ..arcToPoint(to, radius: const Radius.circular(78));
      canvas.drawPath(path, ink);
    }

    arc(const Offset(148, 53), const Offset(196, 89), 14);
    arc(const Offset(196, 89), const Offset(203, 148), 12);
    arc(const Offset(203, 148), const Offset(167, 196), 10);
    arc(const Offset(167, 196), const Offset(89, 196), 8);
    arc(const Offset(89, 196), const Offset(50, 128), 6);
    arc(const Offset(50, 128), const Offset(61, 89), 3.5);
    arc(const Offset(61, 89), const Offset(92, 60), 2);
    canvas.drawCircle(const Offset(124, 44), 9.5, Paint()..color = const Color(0xFFBF2C2A));
  }

  @override
  bool shouldRepaint(covariant CustomPainter _) => false;
}

class _SideNavItem extends StatelessWidget {
  const _SideNavItem({required this.icon, required this.label, required this.active, required this.zc});
  final String icon;
  final String label;
  final bool active;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 120),
    margin: const EdgeInsets.only(bottom: 2),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: active ? zc.bgCard : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
    ),
    child: Row(
      spacing: 10,
      children: [
        ZanshinIcon(icon, size: 14, color: active ? zc.textPrimary : zc.textMuted),
        Text(label, style: TextStyle(fontSize: 13, color: active ? zc.textPrimary : zc.textMuted)),
      ],
    ),
  );
}

class _HomeMain extends StatelessWidget {
  const _HomeMain({
    required this.query,
    required this.onQueryChanged,
    required this.projects,
    required this.selectedId,
    required this.activeProjectId,
    required this.onSelect,
    required this.onOpen,
    required this.onClose,
    required this.zc,
  });
  final String query;
  final ValueChanged<String> onQueryChanged;
  final List<MockProject> projects;
  final String? selectedId;
  final String activeProjectId;
  final ValueChanged<String> onSelect;
  final ValueChanged<MockProject> onOpen;
  final VoidCallback onClose;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      // Header
      Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: zc.border)),
        ),
        child: Row(
          children: [
            Text(
              'Projects',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: zc.textPrimary),
            ),
            const Spacer(),
            GestureDetector(
              onTap: onClose,
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(color: zc.bgCard2, borderRadius: BorderRadius.circular(6)),
                child: Center(child: ZanshinIcon(ZI.close, size: 12, color: zc.textDim)),
              ),
            ),
          ],
        ),
      ),
      // Toolbar
      Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: zc.border)),
        ),
        child: Row(
          spacing: 8,
          children: [
            // Search
            Expanded(
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: zc.bgCard,
                  border: Border.all(color: zc.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  spacing: 8,
                  children: [
                    ZanshinIcon(ZI.search, size: 13, color: zc.textDim),
                    Expanded(
                      child: TextField(
                        onChanged: onQueryChanged,
                        style: TextStyle(fontSize: 12.5, color: zc.textPrimary),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Search projects, paths…',
                          hintStyle: TextStyle(fontSize: 12.5, color: zc.textDim),
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _ToolbarBtn(label: 'Add directory', icon: ZI.plus, primary: true, zc: zc),
            _ToolbarBtn(label: 'Clone', icon: ZI.cloud, zc: zc),
          ],
        ),
      ),
      // Project list
      Expanded(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 6),
          children: projects.map((p) {
            final isActive = p.id == activeProjectId;
            final isSelected = p.id == selectedId;
            return _ProjectRow(
              project: p,
              isSelected: isSelected,
              isActive: isActive,
              onTap: () => onSelect(p.id),
              onDoubleTap: () => onOpen(p),
              zc: zc,
            );
          }).toList(),
        ),
      ),
      // Drop hint
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: zc.border)),
        ),
        child: Row(
          spacing: 8,
          children: [
            ZanshinIcon(ZI.download, size: 13, color: zc.textDim),
            Text('Drop a folder here to add it as a project', style: TextStyle(fontSize: 12, color: zc.textDim)),
          ],
        ),
      ),
    ],
  );
}

class _ToolbarBtn extends StatelessWidget {
  const _ToolbarBtn({required this.label, required this.icon, required this.zc, this.primary = false});
  final String label;
  final String icon;
  final bool primary;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => Container(
    height: 32,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: primary ? zc.accent : zc.bgCard,
      border: Border.all(color: primary ? zc.accent : zc.border),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        ZanshinIcon(icon, size: 12, color: primary ? Colors.white : zc.textMuted),
        Text(label, style: TextStyle(fontSize: 12, color: primary ? Colors.white : zc.textMuted)),
      ],
    ),
  );
}

class _ProjectRow extends StatefulWidget {
  const _ProjectRow({
    required this.project,
    required this.isSelected,
    required this.isActive,
    required this.onTap,
    required this.onDoubleTap,
    required this.zc,
  });
  final MockProject project;
  final bool isSelected;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final ZanshinColors zc;

  @override
  State<_ProjectRow> createState() => _ProjectRowState();
}

class _ProjectRowState extends State<_ProjectRow> {
  var _hovered = false;

  static Color _statusColor(String status) => switch (status) {
    'clean' => const Color(0xFF9ca3af),
    'dirty' => const Color(0xFFfacc15),
    'ahead' => const Color(0xFF4ade80),
    'behind' => const Color(0xFF60a5fa),
    'diverged' => const Color(0xFFfb923c),
    'conflict' => const Color(0xFFf87171),
    _ => const Color(0xFF71717a),
  };

  @override
  Widget build(BuildContext context) {
    final ZanshinColors zc = widget.zc;
    final Color sc = _statusColor(widget.project.status);
    final Color bg = widget.isSelected ? zc.bgCard2 : (_hovered ? zc.bgCard.withAlpha(180) : Colors.transparent);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            spacing: 10,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: sc, shape: BoxShape.circle),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 3,
                  children: [
                    Row(
                      spacing: 6,
                      children: [
                        Text(
                          widget.project.name,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: zc.textPrimary),
                        ),
                        if (widget.isActive)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: zc.accent.withAlpha(35),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('open', style: TextStyle(fontSize: 10, color: zc.accent)),
                          ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 3,
                          children: [
                            ZanshinIcon(ZI.branch, size: 10, color: zc.textDim),
                            Text(widget.project.branch, style: TextStyle(fontSize: 11, color: zc.textDim)),
                          ],
                        ),
                        if (widget.project.ahead > 0)
                          Text(
                            '↑${widget.project.ahead}',
                            style: TextStyle(fontSize: 10, color: zc.add, fontFamily: 'monospace'),
                          ),
                        if (widget.project.behind > 0)
                          Text(
                            '↓${widget.project.behind}',
                            style: TextStyle(fontSize: 10, color: zc.rem, fontFamily: 'monospace'),
                          ),
                      ],
                    ),
                    Row(
                      spacing: 6,
                      children: [
                        Text(
                          widget.project.path,
                          style: TextStyle(fontSize: 11, color: zc.textDim, fontFamily: 'monospace'),
                        ),
                        Text('·', style: TextStyle(fontSize: 11, color: zc.textFaint)),
                        Text(widget.project.lastOpened, style: TextStyle(fontSize: 11, color: zc.textDim)),
                      ],
                    ),
                  ],
                ),
              ),
              ZanshinIcon(ZI.more, size: 13, color: _hovered ? zc.textDim : Colors.transparent),
            ],
          ),
        ),
      ),
    );
  }
}
