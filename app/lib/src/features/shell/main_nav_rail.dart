// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import '../../shared/theme/zanshin_colors.dart';
import '../../shared/widgets/zanshin_icon.dart';

enum NavPanel { history, branches, workstream, reviews, undo }

class MainNavRail extends StatelessWidget {
  const MainNavRail({
    required this.activePanel,
    required this.onSelectPanel,
    required this.onHomePressed,
    super.key,
    this.homeActive = false,
  });

  final NavPanel activePanel;
  final ValueChanged<NavPanel> onSelectPanel;
  final VoidCallback onHomePressed;
  final bool homeActive;

  @override
  Widget build(BuildContext context) {
    final ZanshinColors zc = context.zc;
    return Container(
      width: 64,
      decoration: BoxDecoration(
        color: zc.bgWindow,
        border: Border(right: BorderSide(color: zc.border)),
      ),
      child: Column(
        children: [
          // Zanshin logo / home button
          _NavActivityBtn(
            active: homeActive,
            onTap: onHomePressed,
            zc: zc,
            child: const _ZanshinMark(size: 26),
          ),
          Container(height: 1, color: zc.border, margin: const EdgeInsets.symmetric(vertical: 2)),
          _NavActivityBtn(
            active: activePanel == NavPanel.history,
            onTap: () => onSelectPanel(NavPanel.history),
            zc: zc,
            child: const ZanshinIcon(ZI.history, size: 22),
          ),
          _NavActivityBtn(
            active: activePanel == NavPanel.branches,
            onTap: () => onSelectPanel(NavPanel.branches),
            zc: zc,
            child: const ZanshinIcon(ZI.branch, size: 22),
          ),
          _NavActivityBtn(
            active: activePanel == NavPanel.workstream,
            onTap: () => onSelectPanel(NavPanel.workstream),
            zc: zc,
            child: const ZanshinIcon(ZI.workstream, size: 22),
          ),
          _NavActivityBtn(
            active: activePanel == NavPanel.reviews,
            onTap: () => onSelectPanel(NavPanel.reviews),
            zc: zc,
            child: const ZanshinIcon(ZI.reviews, size: 22),
          ),
          _NavActivityBtn(
            active: activePanel == NavPanel.undo,
            onTap: () => onSelectPanel(NavPanel.undo),
            zc: zc,
            child: const ZanshinIcon(ZI.undo, size: 22),
          ),
          const Spacer(),
          _NavActivityBtn(
            active: false,
            onTap: () {},
            zc: zc,
            child: const ZanshinIcon(ZI.settings, size: 20),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _NavActivityBtn extends StatefulWidget {
  const _NavActivityBtn({required this.child, required this.active, required this.onTap, required this.zc});
  final Widget child;
  final bool active;
  final VoidCallback onTap;
  final ZanshinColors zc;

  @override
  State<_NavActivityBtn> createState() => _NavActivityBtnState();
}

class _NavActivityBtnState extends State<_NavActivityBtn> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Color color = widget.active || _hovered ? widget.zc.textPrimary : widget.zc.textDim;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            SizedBox(
              width: 64,
              height: 48,
              child: Center(
                child: IconTheme(
                  data: IconThemeData(color: color),
                  child: widget.child,
                ),
              ),
            ),
            // Active indicator: left border pill
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 2,
              height: widget.active ? 18 : 0,
              decoration: BoxDecoration(
                color: widget.zc.textPrimary,
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(2),
                  bottomRight: Radius.circular(2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Zanshin brand mark (dry-brush ensō)
class _ZanshinMark extends StatelessWidget {
  const _ZanshinMark({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _ZanshinMarkPainter()),
  );
}

class _ZanshinMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width / 256.0;
    canvas.scale(s, s);

    // Paper background
    final paperPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFF5ECD6), Color(0xFFE6D7B2)],
      ).createShader(const Rect.fromLTWH(0, 0, 256, 256));
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 256, 256), const Radius.circular(58)),
      paperPaint,
    );

    // Ink strokes
    final inkPaint = Paint()
      ..color = const Color(0xFF1a1413)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();

    inkPaint.strokeWidth = 14;
    path
      ..moveTo(148, 53)
      ..arcToPoint(const Offset(196, 89), radius: const Radius.circular(78));
    canvas.drawPath(path, inkPaint);
    path.reset();

    inkPaint.strokeWidth = 12;
    path
      ..moveTo(196, 89)
      ..arcToPoint(const Offset(203, 148), radius: const Radius.circular(78));
    canvas.drawPath(path, inkPaint);
    path.reset();

    inkPaint.strokeWidth = 10;
    path
      ..moveTo(203, 148)
      ..arcToPoint(const Offset(167, 196), radius: const Radius.circular(78));
    canvas.drawPath(path, inkPaint);
    path.reset();

    inkPaint.strokeWidth = 8;
    path
      ..moveTo(167, 196)
      ..arcToPoint(const Offset(89, 196), radius: const Radius.circular(78));
    canvas.drawPath(path, inkPaint);
    path.reset();

    inkPaint.strokeWidth = 6;
    path
      ..moveTo(89, 196)
      ..arcToPoint(const Offset(50, 128), radius: const Radius.circular(78));
    canvas.drawPath(path, inkPaint);
    path.reset();

    inkPaint.strokeWidth = 3.5;
    path
      ..moveTo(50, 128)
      ..arcToPoint(const Offset(61, 89), radius: const Radius.circular(78));
    canvas.drawPath(path, inkPaint);
    path.reset();

    inkPaint.strokeWidth = 2;
    path
      ..moveTo(61, 89)
      ..arcToPoint(const Offset(92, 60), radius: const Radius.circular(78));
    canvas.drawPath(path, inkPaint);
    path.reset();

    // Red seal
    canvas.drawCircle(const Offset(124, 44), 9.5, Paint()..color = const Color(0xFFBF2C2A));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
