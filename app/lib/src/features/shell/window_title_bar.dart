// SPDX-License-Identifier: MIT

import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../../shared/theme/zanshin_colors.dart';
import '../../shared/widgets/zanshin_icon.dart';

enum AppThemeMode { light, dark, system }

class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({
    required this.projectName,
    required this.themeMode,
    required this.onThemeMode,
    super.key,
  });

  final String projectName;
  final AppThemeMode themeMode;
  final ValueChanged<AppThemeMode> onThemeMode;

  @override
  Widget build(BuildContext context) {
    final ZanshinColors zc = context.zc;
    return DragToMoveArea(
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: zc.bgWindow,
          border: Border(bottom: BorderSide(color: zc.border)),
        ),
        child: Row(
          children: [
            // Space for macOS traffic lights (close/min/max)
            const SizedBox(width: 72),
            Text(
              'JJ Client — $projectName',
              style: TextStyle(fontSize: 12.5, color: zc.textMuted, fontWeight: FontWeight.w500),
            ),
            const Spacer(),
            // Action buttons
            _TitleBarButtonGroup(zc: zc),
            const Spacer(),
            // Theme switch
            _ThemeSwitch(mode: themeMode, onChanged: onThemeMode, zc: zc),
            const SizedBox(width: 14),
          ],
        ),
      ),
    );
  }
}

class _TitleBarButtonGroup extends StatelessWidget {
  const _TitleBarButtonGroup({required this.zc});
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: zc.bgCard,
      border: Border.all(color: zc.border),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _HeaderBtn(icon: ZI.fetch, label: 'Fetch', zc: zc),
        _HeaderBtn(icon: ZI.pull, label: 'Pull', zc: zc),
        _HeaderBtn(icon: ZI.push, label: 'Push', zc: zc),
        Container(width: 1, height: 14, color: zc.border, margin: const EdgeInsets.symmetric(horizontal: 4)),
        _HeaderBtn(icon: ZI.plus, label: 'New', zc: zc),
      ],
    ),
  );
}

class _HeaderBtn extends StatefulWidget {
  const _HeaderBtn({required this.icon, required this.label, required this.zc});
  final String icon;
  final String label;
  final ZanshinColors zc;

  @override
  State<_HeaderBtn> createState() => _HeaderBtnState();
}

class _HeaderBtnState extends State<_HeaderBtn> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: GestureDetector(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: _hovered ? widget.zc.bgCard2 : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            ZanshinIcon(widget.icon, size: 13, color: _hovered ? widget.zc.textPrimary : widget.zc.textMuted),
            Text(
              widget.label,
              style: TextStyle(fontSize: 12, color: _hovered ? widget.zc.textPrimary : widget.zc.textMuted),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ThemeSwitch extends StatelessWidget {
  const _ThemeSwitch({required this.mode, required this.onChanged, required this.zc});
  final AppThemeMode mode;
  final ValueChanged<AppThemeMode> onChanged;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: zc.bgCard,
      border: Border.all(color: zc.border),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ThemeBtn(
          icon: ZI.sun,
          active: mode == AppThemeMode.light,
          onTap: () => onChanged(AppThemeMode.light),
          zc: zc,
        ),
        _ThemeBtn(
          icon: ZI.moon,
          active: mode == AppThemeMode.dark,
          onTap: () => onChanged(AppThemeMode.dark),
          zc: zc,
        ),
        _ThemeBtn(
          icon: ZI.auto,
          active: mode == AppThemeMode.system,
          onTap: () => onChanged(AppThemeMode.system),
          zc: zc,
        ),
      ],
    ),
  );
}

class _ThemeBtn extends StatelessWidget {
  const _ThemeBtn({required this.icon, required this.active, required this.onTap, required this.zc});
  final String icon;
  final bool active;
  final VoidCallback onTap;
  final ZanshinColors zc;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 26,
      height: 22,
      decoration: BoxDecoration(
        color: active ? zc.bgCard2 : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Center(child: ZanshinIcon(icon, size: 14, color: active ? zc.textPrimary : zc.textDim)),
    ),
  );
}
