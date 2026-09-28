import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Nami · Indigo — Ladeanimation als reiner CustomPainter (kein Asset, kein Package).
///
/// Alle drei Linien teilen dieselbe Wellenlaenge, Berge und Taeler liegen
/// uebereinander. Ein Schwung laeuft einmal durch, danach kurze Pause.
///
///   NamiIndigoIcon(size: 96)
///   NamiIndigoIcon(size: 96, background: false)   // nur die Wellen
class NamiIndigoIcon extends StatefulWidget {
  const NamiIndigoIcon({
    super.key,
    this.size = 256,
    this.cornerRadius,
    this.background = true,
    this.animate = true,
    this.mode = NamiWaveMode.sweep,
    this.lift = 20.5,
    this.spread = 40,
    this.sweepDuration = const Duration(milliseconds: 1300),
    this.pauseDuration = const Duration(milliseconds: 550),
  });

  final double size;

  /// Standard: 22.66 % der Kantenlaenge.
  final double? cornerRadius;
  final bool background;
  final bool animate;
  final NamiWaveMode mode;

  /// Hoehe des durchlaufenden Schwungs, in Design-Einheiten (Basis 256).
  final double lift;

  /// Breite des Schwungs, in Design-Einheiten (Basis 256).
  final double spread;
  final Duration sweepDuration;
  final Duration pauseDuration;

  @override
  State<NamiIndigoIcon> createState() => _NamiIndigoIconState();
}

enum NamiWaveMode { sweep, pulse }

class _NamiIndigoIconState extends State<NamiIndigoIcon>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _t = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() => _t = elapsed.inMicroseconds / 1e6);
    });
    if (widget.animate) _ticker.start();
  }

  @override
  void didUpdateWidget(NamiIndigoIcon old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_ticker.isActive) _ticker.start();
    if (!widget.animate && _ticker.isActive) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final painter = _NamiPainter(
      time: widget.animate ? _t : -1,
      mode: widget.mode,
      lift: widget.lift,
      spread: widget.spread,
      sweep: widget.sweepDuration.inMicroseconds / 1e6,
      pause: widget.pauseDuration.inMicroseconds / 1e6,
      background: widget.background,
    );
    final paint = CustomPaint(size: Size.square(widget.size), painter: painter);
    if (!widget.background) return paint;
    return ClipRRect(
      borderRadius:
          BorderRadius.circular(widget.cornerRadius ?? widget.size * 0.2266),
      child: paint,
    );
  }
}

class _Line {
  const _Line(this.baseY, this.strokeWidth, this.color, this.start, this.segs,
      this.per);
  final double baseY, strokeWidth;
  final Color color;
  final Offset start;

  /// Quadratische Bezier-Segmente des App-Logos: [Kontrollpunkt, Endpunkt].
  final List<List<Offset>> segs;
  final int per;

  List<Offset> points() {
    final pts = <Offset>[start];
    var p0 = start;
    for (final seg in segs) {
      final c = seg[0], p1 = seg[1];
      for (var i = 1; i <= per; i++) {
        final t = i / per, m = 1 - t;
        pts.add(Offset(
          m * m * p0.dx + 2 * m * t * c.dx + t * t * p1.dx,
          m * m * p0.dy + 2 * m * t * c.dy + t * t * p1.dy,
        ));
      }
      p0 = p1;
    }
    return pts;
  }
}

final List<_Line> _lines = [
  _Line(92, 9, const Color(0xFFF4CF80), const Offset(28, 92), const [
    [Offset(72, 60), Offset(116, 92)],
    [Offset(160, 124), Offset(196, 92)],
    [Offset(218, 84), Offset(228, 90)],
  ], 10),
  _Line(134, 11, const Color(0xFFDCA85B), const Offset(24, 134), const [
    [Offset(76, 100), Offset(132, 134)],
    [Offset(188, 168), Offset(212, 134)],
    [Offset(226, 130), Offset(234, 134)],
  ], 10),
  _Line(178, 13, const Color(0xFFB58346), const Offset(22, 178), const [
    [Offset(88, 138), Offset(154, 178)],
    [Offset(220, 218), Offset(234, 178)],
  ], 15),
];

final List<List<Offset>> _basePoints = _lines.map((l) => l.points()).toList();

const double _vb = 256; // Design-Koordinatensystem
const double _x0 = 22, _x1 = 234;

class _NamiPainter extends CustomPainter {
  _NamiPainter({
    required this.time,
    required this.mode,
    required this.lift,
    required this.spread,
    required this.sweep,
    required this.pause,
    required this.background,
  });

  final double time; // < 0 == Ruhezustand
  final NamiWaveMode mode;
  final double lift, spread, sweep, pause;
  final bool background;

  /// Vertikaler Versatz an Position x. Bei time < 0 == Ruhezustand.
  Offset _shift(int li, Offset p) {
    if (time < 0) return p;
    final total = sweep + pause;
    final tc = time % total;
    if (tc >= sweep) return p;
    final prog = tc / sweep;

    if (mode == NamiWaveMode.pulse) {
      final amt = (0.5 - 0.5 * math.cos(prog * 2 * math.pi)) * (lift / 11);
      final baseY = _lines[li].baseY;
      return Offset(p.dx, baseY + (p.dy - baseY) * (1 + amt));
    }

    final ease = 0.5 - 0.5 * math.cos(prog * math.pi);
    final a = _x0 - spread * 1.7, b = _x1 + spread * 1.7;
    final cx = a + ease * (b - a);
    final u = (p.dx - cx) / spread;
    return Offset(p.dx, p.dy - lift * math.exp(-u * u));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / _vb;
    final rect = Offset.zero & size;

    if (background) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1D2540), Color(0xFF131831)],
          ).createShader(rect),
      );
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(0, 0.2),
            radius: 0.7,
            colors: [
              const Color(0xFFDCA85B).withValues(alpha: 0.10),
              const Color(0xFFDCA85B).withValues(alpha: 0.0),
            ],
          ).createShader(rect),
      );
    }

    for (var li = 0; li < _lines.length; li++) {
      final line = _lines[li];
      final pts = _basePoints[li];
      final path = Path();
      for (var i = 0; i < pts.length; i++) {
        final p = _shift(li, pts[i]);
        if (i == 0) {
          path.moveTo(p.dx * k, p.dy * k);
        } else {
          path.lineTo(p.dx * k, p.dy * k);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = line.color
          ..strokeWidth = line.strokeWidth * k
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      );
    }
  }

  @override
  bool shouldRepaint(_NamiPainter old) => old.time != time || old.mode != mode;
}
