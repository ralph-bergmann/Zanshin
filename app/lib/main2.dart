// SPDX-License-Identifier: MIT

// Window-background example: the two Zanshin windows from Claude Design's
// "Fensterhintergrund — Day & Night" (`_bmad-output/implementation-artifacts/
// design/Zanshin Window Background.html`) as real windows — the night one
// first, the day one next to it. Not wired into the real boot.
//
//   flutter run -d macos -t lib/main2.dart      (from `app/`)
//
// The window edge — hairline, drop shadow, traffic lights — is the native
// chrome the runner applies to every app window; only the canvas and what
// lies on it are drawn here.
//
// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'package:flutter/src/widgets/_window.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yaru/yaru.dart';
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import 'src/features/window/app_windows.dart';

/// Content size of both example windows.
const _windowSize = Size(900, 600);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final windows = AppWindows();
  // The first window has to be part of the warm-up frame (see
  // [AppWindows.create]); the second goes through the registry, which the
  // first window's build attaches.
  final WindowEntry night = await windows.create(
    key: 'bg-night',
    title: 'Zanshin — Night',
    size: _windowSize,
    builder: (_) => const _ExampleWindow(dark: true),
  );
  runWidget(WindowManager(initialWindows: <WindowEntry>[night]));
  await WidgetsBinding.instance.endOfFrame;
  await windows.openOrActivate(
    key: 'bg-day',
    title: 'Zanshin — Day',
    size: _windowSize,
    builder: (_) => const _ExampleWindow(dark: false),
  );
}

/// The window canvas: a diagonal base gradient plus a very flat radial glow
/// at the top left. Both are static decorations, drawn once behind the
/// content; no blur, no noise, no animation.
class ZanshinCanvas extends StatelessWidget {
  const ZanshinCanvas({required this.dark, required this.child, super.key});

  final bool dark;
  final Widget child;

  static const _nightBase = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF1A2038), Color(0xFF12162A), Color(0xFF0E1224)],
      stops: [0, .68, 1],
    ),
  );
  static const _dayBase = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFFF7F4F0), Color(0xFFF0ECE7), Color(0xFFE8E3DD)],
      stops: [0, .68, 1],
    ),
  );

  /// Indigo at 24 % (night) or gold at 20 % (day), fading to nothing.
  static BoxDecoration _glow(Color color) => BoxDecoration(
    gradient: RadialGradient(
      center: const Alignment(-.8, -1.15),
      radius: 1.35,
      colors: [color, color.withValues(alpha: 0)],
      stops: const [0, .62],
    ),
  );

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: DecoratedBox(
      decoration: dark ? _nightBase : _dayBase,
      child: DecoratedBox(
        decoration: _glow(dark ? const Color(0x3D6078B2) : const Color(0x33DCA85B)),
        child: child,
      ),
    ),
  );
}

/// What lies on the canvas: sidebar, cards and lines are alpha-blended over
/// the gradient, never opaque — white on dark at night, warm white by day.
enum _Tone {
  night(
    ink: Color(0xFFE7E9F2),
    dim: Color(0xFF98A0BB),
    line: Color(0x12FFFFFF), // white @ 7 %
    sidebar: Color(0x08FFFFFF), // white @ 3 %
    sidebarActive: Color(0x29788CC8), // 120 140 200 @ 16 %
    card: Color(0x0BFFFFFF), // white @ 4.5 %
    cardLine: Color(0x12FFFFFF), // white @ 7 %
  ),
  day(
    ink: Color(0xFF2C2A33),
    dim: Color(0xFF736C66),
    line: Color(0x173A2E22), // #3A2E22 @ 9 %
    sidebar: Color(0x94FFFDFA), // #FFFDFA @ 58 %
    sidebarActive: Color(0x33C89650), // 200 150 80 @ 20 %
    card: Color(0xB8FFFDFA), // #FFFDFA @ 72 %
    cardLine: Color(0x1A3A2E22), // #3A2E22 @ 10 %
  );

  const _Tone({
    required this.ink,
    required this.dim,
    required this.line,
    required this.sidebar,
    required this.sidebarActive,
    required this.card,
    required this.cardLine,
  });

  /// Primary text.
  final Color ink;

  /// Secondary text; also the skeleton lines at 28 %.
  final Color dim;

  /// Hairlines: titlebar bottom, sidebar right.
  final Color line;

  /// Sidebar tint over the canvas.
  final Color sidebar;

  /// The active sidebar entry.
  final Color sidebarActive;

  /// Card fill over the canvas.
  final Color card;

  /// Card border.
  final Color cardLine;
}

/// Status colour of the current change — an accent, not decoration.
const _gold = Color(0xFFDCA85B);

/// One example window: Yaru theme with a transparent scaffold, the canvas
/// underneath, the mock content on top.
class _ExampleWindow extends StatelessWidget {
  const _ExampleWindow({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = (dark ? yaruDark : yaruLight).copyWith(scaffoldBackgroundColor: Colors.transparent);
    return MaterialApp(
      title: 'Zanshin',
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: ZanshinCanvas(
        dark: dark,
        child: Scaffold(
          body: _WindowContent(tone: dark ? _Tone.night : _Tone.day),
        ),
      ),
    );
  }
}

class _WindowContent extends StatelessWidget {
  const _WindowContent({required this.tone});

  final _Tone tone;

  @override
  Widget build(BuildContext context) => DefaultTextStyle(
    style: TextStyle(fontFamily: ZsType.sansFamily, fontSize: 12, color: tone.dim),
    child: Column(
      children: [
        _TitleBar(tone: tone),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Sidebar(tone: tone),
              Expanded(child: _Main(tone: tone)),
            ],
          ),
        ),
      ],
    ),
  );
}

/// 38 px, hairline below; the traffic lights are native and sit in the
/// 72 px gap on the left.
class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.tone});

  final _Tone tone;

  @override
  Widget build(BuildContext context) => WindowDragArea(
    child: Container(
      height: 38,
      padding: const EdgeInsets.only(left: 72, right: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tone.line)),
      ),
      child: Row(
        spacing: 9,
        children: [
          Text(
            'Zanshin',
            style: TextStyle(fontWeight: FontWeight.w500, color: tone.ink),
          ),
          const Text('—  zanshin/main'),
        ],
      ),
    ),
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.tone});

  final _Tone tone;

  static const _entries = ['Änderungen', 'Historie', 'Branches', 'Konflikte'];

  @override
  Widget build(BuildContext context) => Container(
    width: 132,
    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
    decoration: BoxDecoration(
      color: tone.sidebar,
      border: Border(right: BorderSide(color: tone.line)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 7,
      children: [
        for (final (i, entry) in _entries.indexed)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 7),
            decoration: BoxDecoration(
              color: i == 0 ? tone.sidebarActive : null,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(entry, style: TextStyle(fontSize: 11.5, color: i == 0 ? tone.ink : tone.dim)),
          ),
      ],
    ),
  );
}

class _Main extends StatelessWidget {
  const _Main({required this.tone});

  final _Tone tone;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        _Card(
          tone: tone,
          current: true,
          title: 'ktrzqnvw  feat: rail spacing',
          meta: '2 files · +48 −12',
          skeletons: const [.74, .52],
        ),
        _Card(
          tone: tone,
          current: false,
          title: 'mpxlszou  fix: theme token',
          meta: '1 file · +6 −6',
          skeletons: const [.52],
        ),
      ],
    ),
  );
}

/// A change card: title, mono meta line, skeleton lines standing in for the
/// diff. The current change carries the gold dot.
class _Card extends StatelessWidget {
  const _Card({
    required this.tone,
    required this.current,
    required this.title,
    required this.meta,
    required this.skeletons,
  });

  final _Tone tone;
  final bool current;
  final String title;
  final String meta;

  /// Skeleton line widths as a fraction of the card's inner width.
  final List<double> skeletons;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 12),
    decoration: BoxDecoration(
      color: tone.card,
      border: Border.all(color: tone.cardLine),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 7,
      children: [
        Row(
          spacing: 6,
          children: [
            if (current) const _GoldDot(),
            Text(
              title,
              style: TextStyle(fontWeight: FontWeight.w500, color: tone.ink),
            ),
          ],
        ),
        Text(meta, style: const TextStyle(fontFamily: ZsType.monoFamily, fontSize: 10.5)),
        for (final width in skeletons)
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: width,
            child: Container(
              height: 6,
              decoration: BoxDecoration(
                color: tone.dim.withValues(alpha: .28),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
      ],
    ),
  );
}

/// 5 px gold disc with a 3 px ring at 18 %.
class _GoldDot extends StatelessWidget {
  const _GoldDot();

  @override
  Widget build(BuildContext context) => Container(
    width: 11,
    height: 11,
    decoration: BoxDecoration(shape: BoxShape.circle, color: _gold.withValues(alpha: .18)),
    child: const Center(
      child: SizedBox(
        width: 5,
        height: 5,
        child: DecoratedBox(
          decoration: BoxDecoration(shape: BoxShape.circle, color: _gold),
        ),
      ),
    ),
  );
}
