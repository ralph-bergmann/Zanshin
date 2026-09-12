// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import 'splash_card_render.dart';
import 'zanshin_bootstrap.dart';

/// Content size of the splash window.
const splashWindowSize = Size(560, 320);

/// Corner radius of the splash card. The native window is borderless and
/// transparent, so this is what gives the splash its shape.
const double splashCardRadius = 14;

/// The grain tile the card blends over its background; written by
/// `tool/gen_grain_tile.dart`.
const splashGrainAsset = 'assets/images/grain_128.png';

/// Identifies the footer's version line.
const splashVersionKey = Key('splash.version');

/// Identifies the boot status line.
const splashStatusKey = Key('splash.status');

final _log = Logger('zanshin.bootstrap');

/// The splash window's content: the designed card.
///
/// Always dark, unlike the old in-window splash: that one had to match the
/// colour the app's scaffold paints first, because the app appeared behind it.
/// This is a small floating card over the desktop, with no app surface to
/// blend into, so it does not follow the light/dark setting.
///
/// The card is one painted artifact ([SplashCardBody]); only the two footer
/// texts are widgets, because they change while the card is on screen.
class SplashCard extends StatefulWidget {
  const SplashCard({required this.status, required this.version, super.key});

  /// What the boot is doing right now.
  final ValueListenable<String> status;

  /// App version and build, or null while they are unknown.
  final ValueListenable<SplashVersion?> version;

  @override
  State<SplashCard> createState() => _SplashCardState();
}

class _SplashCardState extends State<SplashCard> with SingleTickerProviderStateMixin {
  ui.Image? _grain;

  @override
  void initState() {
    super.initState();
    unawaited(_loadGrain());
  }

  @override
  void dispose() {
    _grain?.dispose();
    super.dispose();
  }

  /// Decodes the grain tile once. The card paints without it until it is there;
  /// a failure is logged once and never retried.
  Future<void> _loadGrain() async {
    try {
      final ByteData data = await rootBundle.load(splashGrainAsset);
      final ui.Codec codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final ui.FrameInfo frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _grain = frame.image);
    } catch (error, stackTrace) {
      // Cosmetic asset on a boot-critical path: whatever went wrong, the card
      // still has to come up.
      _log.warning('The splash grain tile could not be decoded', error, stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) => MediaQuery.fromView(
    // Accessibility flags without a MaterialApp; a window provides only the
    // View.
    view: View.of(context),
    child: Builder(
      builder: (context) => SplashCardBody(
        vsync: this,
        // "Reduce motion": the runner freezes and the dot stays lit.
        animate: !MediaQuery.disableAnimationsOf(context),
        grain: _grain,
        version: ValueListenableBuilder<SplashVersion?>(
          valueListenable: widget.version,
          builder: (context, value, child) => RichText(
            key: splashVersionKey,
            textDirection: TextDirection.ltr,
            // Both footer lines sit on one baseline on a fixed grid; an
            // over-long one ellipsises rather than wrapping off it.
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            text: value == null
                ? const TextSpan(text: '', style: splashVersionStyle)
                : TextSpan(
                    style: splashVersionStyle,
                    children: <InlineSpan>[
                      TextSpan(text: value.version),
                      TextSpan(text: ' · Build ${value.build}', style: splashBuildStyle),
                    ],
                  ),
          ),
        ),
        status: ValueListenableBuilder<String>(
          valueListenable: widget.status,
          builder: (context, value, child) => RichText(
            key: splashStatusKey,
            textDirection: TextDirection.ltr,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(text: value, style: splashStatusStyle),
          ),
        ),
      ),
    ),
  );
}
