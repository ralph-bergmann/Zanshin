// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'splash_card_render.dart';
import 'zanshin_bootstrap.dart';

/// Content size of the splash window.
const splashWindowSize = Size(620, 400);

/// Corner radius of the splash card. The native window is borderless and
/// transparent, so this is what gives the splash its shape.
const double splashCardRadius = 14;

/// Identifies the footer's version line.
const splashVersionKey = Key('splash.version');

/// Identifies the boot status line.
const splashStatusKey = Key('splash.status');

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
