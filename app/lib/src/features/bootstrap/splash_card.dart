// SPDX-License-Identifier: MIT

import 'package:lottie/lottie.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yaru/yaru.dart';

import 'zanshin_bootstrap.dart';

/// Content size of the splash window.
const splashWindowSize = Size(320, 320);

/// Corner radius of the splash card. The native window is borderless and
/// transparent, so this is what gives the splash its shape.
const double splashCardRadius = 12;

/// The splash window's content: the loader animation on a rounded card.
///
/// Always dark, unlike the old in-window splash: that one had to match the
/// colour the app's scaffold paints first, because the app appeared behind it.
/// This is a small floating card over the desktop, with no app surface to
/// blend into, so it does not follow the light/dark setting.
class SplashCard extends StatelessWidget {
  const SplashCard({super.key});

  @override
  Widget build(BuildContext context) => MediaQuery.fromView(
    // Accessibility flags without a MaterialApp; a window provides only the
    // View.
    view: View.of(context),
    child: Builder(
      builder: (context) => DecoratedBox(
        decoration: BoxDecoration(
          color: yaruDark.scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(splashCardRadius),
        ),
        child: Center(
          child: Lottie.asset(
            splashAnimationAsset,
            width: splashAnimationSize,
            height: splashAnimationSize,
            // "Reduce motion": the first frame is the static logo.
            animate: !MediaQuery.disableAnimationsOf(context),
          ),
        ),
      ),
    ),
  );
}
