// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

import 'zs_appearance.dart';
import 'zs_colors.dart';

/// One accent family's 11 tokens in one theme: the 8 roles plus the live copies an inactive window keeps
/// (DS tokens/accents.css:11-24).
@immutable
class ZsAccentTokens {
  /// Creates one family's tokens.
  const ZsAccentTokens({
    required this.accent,
    required this.accentInk,
    required this.accentLine,
    required this.accentText,
    required this.accentSoft,
    required this.accentSoftHi,
    required this.accentRing,
    required this.accentSelect,
    required this.accentLiveLine,
    required this.accentLiveRing,
    required this.accentLiveText,
  });

  /// `--accent`.
  final Color accent;

  /// `--accent-ink`.
  final Color accentInk;

  /// `--accent-line`.
  final Color accentLine;

  /// `--accent-text`.
  final Color accentText;

  /// `--accent-soft`.
  final Color accentSoft;

  /// `--accent-soft-hi`.
  final Color accentSoftHi;

  /// `--accent-ring`.
  final Color accentRing;

  /// `--accent-select`.
  final Color accentSelect;

  /// `--accent-live-line`.
  final Color accentLiveLine;

  /// `--accent-live-ring`.
  final Color accentLiveRing;

  /// `--accent-live-text`.
  final Color accentLiveText;

  /// The 11 tokens as `'--name' → value`.
  Map<String, Color> toCss() => <String, Color>{
    '--accent': accent,
    '--accent-ink': accentInk,
    '--accent-line': accentLine,
    '--accent-text': accentText,
    '--accent-soft': accentSoft,
    '--accent-soft-hi': accentSoftHi,
    '--accent-ring': accentRing,
    '--accent-select': accentSelect,
    '--accent-live-line': accentLiveLine,
    '--accent-live-ring': accentLiveRing,
    '--accent-live-text': accentLiveText,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZsAccentTokens &&
          other.accent == accent &&
          other.accentInk == accentInk &&
          other.accentLine == accentLine &&
          other.accentText == accentText &&
          other.accentSoft == accentSoft &&
          other.accentSoftHi == accentSoftHi &&
          other.accentRing == accentRing &&
          other.accentSelect == accentSelect &&
          other.accentLiveLine == accentLiveLine &&
          other.accentLiveRing == accentLiveRing &&
          other.accentLiveText == accentLiveText;

  @override
  int get hashCode => Object.hash(
    accent,
    accentInk,
    accentLine,
    accentText,
    accentSoft,
    accentSoftHi,
    accentRing,
    accentSelect,
    accentLiveLine,
    accentLiveRing,
    accentLiveText,
  );
}

/// The eight named accent families (DS tokens/accents.css:28-51) and the app accent reported to macOS
/// (`--accent-native`, `:57`). Multicolor is the moon set of [ZsColors.night] and [ZsColors.paper].
abstract final class ZsAccents {
  /// Blue on night (DS tokens/accents.css:29).
  static const blueNight = ZsAccentTokens(
    accent: Color(0xFF67AFFD),
    accentInk: Color(0xFF0B1630),
    accentLine: Color(0xFF67AFFD),
    accentText: Color(0xFF67AFFD),
    accentSoft: Color.fromRGBO(103, 175, 253, 0.14),
    accentSoftHi: Color.fromRGBO(103, 175, 253, 0.24),
    accentRing: Color.fromRGBO(103, 175, 253, 0.3),
    accentSelect: Color.fromRGBO(103, 175, 253, 0.34),
    accentLiveLine: Color(0xFF67AFFD),
    accentLiveRing: Color.fromRGBO(103, 175, 253, 0.3),
    accentLiveText: Color(0xFF67AFFD),
  );

  /// Blue on paper (DS tokens/accents.css:30).
  static const bluePaper = ZsAccentTokens(
    accent: Color(0xFF1665C8),
    accentInk: Color(0xFFFFFFFF),
    accentLine: Color(0xFF1665C8),
    accentText: Color(0xFF1665C8),
    accentSoft: Color.fromRGBO(22, 101, 200, 0.09),
    accentSoftHi: Color.fromRGBO(22, 101, 200, 0.16),
    accentRing: Color.fromRGBO(22, 101, 200, 0.22),
    accentSelect: Color.fromRGBO(22, 101, 200, 0.22),
    accentLiveLine: Color(0xFF1665C8),
    accentLiveRing: Color.fromRGBO(22, 101, 200, 0.22),
    accentLiveText: Color(0xFF1665C8),
  );

  /// Purple on night (DS tokens/accents.css:32).
  static const purpleNight = ZsAccentTokens(
    accent: Color(0xFFD491DF),
    accentInk: Color(0xFF1F0F24),
    accentLine: Color(0xFFD491DF),
    accentText: Color(0xFFD491DF),
    accentSoft: Color.fromRGBO(212, 145, 223, 0.14),
    accentSoftHi: Color.fromRGBO(212, 145, 223, 0.24),
    accentRing: Color.fromRGBO(212, 145, 223, 0.3),
    accentSelect: Color.fromRGBO(212, 145, 223, 0.34),
    accentLiveLine: Color(0xFFD491DF),
    accentLiveRing: Color.fromRGBO(212, 145, 223, 0.3),
    accentLiveText: Color(0xFFD491DF),
  );

  /// Purple on paper (DS tokens/accents.css:33).
  static const purplePaper = ZsAccentTokens(
    accent: Color(0xFF8E3B94),
    accentInk: Color(0xFFFFFFFF),
    accentLine: Color(0xFF8E3B94),
    accentText: Color(0xFF8E3B94),
    accentSoft: Color.fromRGBO(142, 59, 148, 0.09),
    accentSoftHi: Color.fromRGBO(142, 59, 148, 0.16),
    accentRing: Color.fromRGBO(142, 59, 148, 0.22),
    accentSelect: Color.fromRGBO(142, 59, 148, 0.22),
    accentLiveLine: Color(0xFF8E3B94),
    accentLiveRing: Color.fromRGBO(142, 59, 148, 0.22),
    accentLiveText: Color(0xFF8E3B94),
  );

  /// Pink on night (DS tokens/accents.css:35).
  static const pinkNight = ZsAccentTokens(
    accent: Color(0xFFF88DBA),
    accentInk: Color(0xFF2A0C1A),
    accentLine: Color(0xFFF88DBA),
    accentText: Color(0xFFF88DBA),
    accentSoft: Color.fromRGBO(248, 141, 186, 0.14),
    accentSoftHi: Color.fromRGBO(248, 141, 186, 0.24),
    accentRing: Color.fromRGBO(248, 141, 186, 0.3),
    accentSelect: Color.fromRGBO(248, 141, 186, 0.34),
    accentLiveLine: Color(0xFFF88DBA),
    accentLiveRing: Color.fromRGBO(248, 141, 186, 0.3),
    accentLiveText: Color(0xFFF88DBA),
  );

  /// Pink on paper (DS tokens/accents.css:36).
  static const pinkPaper = ZsAccentTokens(
    accent: Color(0xFFC02E73),
    accentInk: Color(0xFFFFFFFF),
    accentLine: Color(0xFFC02E73),
    accentText: Color(0xFFC02E73),
    accentSoft: Color.fromRGBO(192, 46, 115, 0.09),
    accentSoftHi: Color.fromRGBO(192, 46, 115, 0.16),
    accentRing: Color.fromRGBO(192, 46, 115, 0.22),
    accentSelect: Color.fromRGBO(192, 46, 115, 0.22),
    accentLiveLine: Color(0xFFC02E73),
    accentLiveRing: Color.fromRGBO(192, 46, 115, 0.22),
    accentLiveText: Color(0xFFC02E73),
  );

  /// Red on night (DS tokens/accents.css:38).
  static const redNight = ZsAccentTokens(
    accent: Color(0xFFF2446C),
    accentInk: Color(0xFF1F0607),
    accentLine: Color(0xFFF2446C),
    accentText: Color(0xFFF78C9E),
    accentSoft: Color.fromRGBO(242, 68, 108, 0.14),
    accentSoftHi: Color.fromRGBO(242, 68, 108, 0.24),
    accentRing: Color.fromRGBO(242, 68, 108, 0.3),
    accentSelect: Color.fromRGBO(242, 68, 108, 0.34),
    accentLiveLine: Color(0xFFF2446C),
    accentLiveRing: Color.fromRGBO(242, 68, 108, 0.3),
    accentLiveText: Color(0xFFF78C9E),
  );

  /// Red on paper (DS tokens/accents.css:39).
  static const redPaper = ZsAccentTokens(
    accent: Color(0xFFA9023E),
    accentInk: Color(0xFFFFFFFF),
    accentLine: Color(0xFFA9023E),
    accentText: Color(0xFFA9023E),
    accentSoft: Color.fromRGBO(169, 2, 62, 0.09),
    accentSoftHi: Color.fromRGBO(169, 2, 62, 0.16),
    accentRing: Color.fromRGBO(169, 2, 62, 0.22),
    accentSelect: Color.fromRGBO(169, 2, 62, 0.22),
    accentLiveLine: Color(0xFFA9023E),
    accentLiveRing: Color.fromRGBO(169, 2, 62, 0.22),
    accentLiveText: Color(0xFFA9023E),
  );

  /// Orange on night (DS tokens/accents.css:41).
  static const orangeNight = ZsAccentTokens(
    accent: Color(0xFFFE8954),
    accentInk: Color(0xFF241004),
    accentLine: Color(0xFFFE8954),
    accentText: Color(0xFFFE8954),
    accentSoft: Color.fromRGBO(254, 137, 84, 0.14),
    accentSoftHi: Color.fromRGBO(254, 137, 84, 0.24),
    accentRing: Color.fromRGBO(254, 137, 84, 0.3),
    accentSelect: Color.fromRGBO(254, 137, 84, 0.34),
    accentLiveLine: Color(0xFFFE8954),
    accentLiveRing: Color.fromRGBO(254, 137, 84, 0.3),
    accentLiveText: Color(0xFFFE8954),
  );

  /// Orange on paper (DS tokens/accents.css:42).
  static const orangePaper = ZsAccentTokens(
    accent: Color(0xFFF3821D),
    accentInk: Color(0xFF2A1200),
    accentLine: Color(0xFFD65C04),
    accentText: Color(0xFFA03001),
    accentSoft: Color.fromRGBO(214, 92, 4, 0.09),
    accentSoftHi: Color.fromRGBO(214, 92, 4, 0.16),
    accentRing: Color.fromRGBO(214, 92, 4, 0.22),
    accentSelect: Color.fromRGBO(214, 92, 4, 0.22),
    accentLiveLine: Color(0xFFD65C04),
    accentLiveRing: Color.fromRGBO(214, 92, 4, 0.22),
    accentLiveText: Color(0xFFA03001),
  );

  /// Yellow on night (DS tokens/accents.css:44).
  static const yellowNight = ZsAccentTokens(
    accent: Color(0xFFECDB42),
    accentInk: Color(0xFF1F1C02),
    accentLine: Color(0xFFECDB42),
    accentText: Color(0xFFECDB42),
    accentSoft: Color.fromRGBO(236, 219, 66, 0.14),
    accentSoftHi: Color.fromRGBO(236, 219, 66, 0.24),
    accentRing: Color.fromRGBO(236, 219, 66, 0.3),
    accentSelect: Color.fromRGBO(236, 219, 66, 0.34),
    accentLiveLine: Color(0xFFECDB42),
    accentLiveRing: Color.fromRGBO(236, 219, 66, 0.3),
    accentLiveText: Color(0xFFECDB42),
  );

  /// Yellow on paper (DS tokens/accents.css:45).
  static const yellowPaper = ZsAccentTokens(
    accent: Color(0xFFEFD62F),
    accentInk: Color(0xFF2B2600),
    accentLine: Color(0xFF847E0D),
    accentText: Color(0xFF6B6611),
    accentSoft: Color.fromRGBO(132, 126, 13, 0.09),
    accentSoftHi: Color.fromRGBO(132, 126, 13, 0.16),
    accentRing: Color.fromRGBO(132, 126, 13, 0.22),
    accentSelect: Color.fromRGBO(132, 126, 13, 0.22),
    accentLiveLine: Color(0xFF847E0D),
    accentLiveRing: Color.fromRGBO(132, 126, 13, 0.22),
    accentLiveText: Color(0xFF6B6611),
  );

  /// Green on night (DS tokens/accents.css:47).
  static const greenNight = ZsAccentTokens(
    accent: Color(0xFF8AC738),
    accentInk: Color(0xFF0B1D04),
    accentLine: Color(0xFF8AC738),
    accentText: Color(0xFF8AC738),
    accentSoft: Color.fromRGBO(138, 199, 56, 0.14),
    accentSoftHi: Color.fromRGBO(138, 199, 56, 0.24),
    accentRing: Color.fromRGBO(138, 199, 56, 0.3),
    accentSelect: Color.fromRGBO(138, 199, 56, 0.34),
    accentLiveLine: Color(0xFF8AC738),
    accentLiveRing: Color.fromRGBO(138, 199, 56, 0.3),
    accentLiveText: Color(0xFF8AC738),
  );

  /// Green on paper (DS tokens/accents.css:48).
  static const greenPaper = ZsAccentTokens(
    accent: Color(0xFF79C32E),
    accentInk: Color(0xFF0F2205),
    accentLine: Color(0xFF4F8D11),
    accentText: Color(0xFF3D5E06),
    accentSoft: Color.fromRGBO(79, 141, 17, 0.09),
    accentSoftHi: Color.fromRGBO(79, 141, 17, 0.16),
    accentRing: Color.fromRGBO(79, 141, 17, 0.22),
    accentSelect: Color.fromRGBO(79, 141, 17, 0.22),
    accentLiveLine: Color(0xFF4F8D11),
    accentLiveRing: Color.fromRGBO(79, 141, 17, 0.22),
    accentLiveText: Color(0xFF3D5E06),
  );

  /// Graphite on night (DS tokens/accents.css:50).
  static const graphiteNight = ZsAccentTokens(
    accent: Color(0xFFB7B7B7),
    accentInk: Color(0xFF161A2A),
    accentLine: Color(0xFFB7B7B7),
    accentText: Color(0xFFB7B7B7),
    accentSoft: Color.fromRGBO(183, 183, 183, 0.14),
    accentSoftHi: Color.fromRGBO(183, 183, 183, 0.24),
    accentRing: Color.fromRGBO(183, 183, 183, 0.3),
    accentSelect: Color.fromRGBO(183, 183, 183, 0.34),
    accentLiveLine: Color(0xFFB7B7B7),
    accentLiveRing: Color.fromRGBO(183, 183, 183, 0.3),
    accentLiveText: Color(0xFFB7B7B7),
  );

  /// Graphite on paper (DS tokens/accents.css:51).
  static const graphitePaper = ZsAccentTokens(
    accent: Color(0xFF636363),
    accentInk: Color(0xFFFFFFFF),
    accentLine: Color(0xFF636363),
    accentText: Color(0xFF636363),
    accentSoft: Color.fromRGBO(99, 99, 99, 0.09),
    accentSoftHi: Color.fromRGBO(99, 99, 99, 0.16),
    accentRing: Color.fromRGBO(99, 99, 99, 0.22),
    accentSelect: Color.fromRGBO(99, 99, 99, 0.22),
    accentLiveLine: Color(0xFF636363),
    accentLiveRing: Color.fromRGBO(99, 99, 99, 0.22),
    accentLiveText: Color(0xFF636363),
  );

  /// `--accent-native`: the app accent reported to macOS under Multicolor, any appearance — a deeper moon,
  /// because native controls put white text on it (DS tokens/accents.css:57); the runner's AccentColor colour set
  /// (Story 11.4).
  static const native = Color(0xFF4757A1);

  /// `--accent-native-dark`: the dark appearance's app accent (DS tokens/accents.css:57).
  static const nativeDark = Color(0xFF5162AD);
}

/// The accent tokens of a family.
extension ZsAccentFamilyTokens on ZsAccentFamily {
  /// The 11 tokens of this family in [theme]; Multicolor reads the moon set.
  ZsAccentTokens tokensIn(ZsTheme theme) => switch ((this, theme)) {
    (ZsAccentFamily.multicolor, ZsTheme.night) => ZsColors.night.accentTokens,
    (ZsAccentFamily.multicolor, ZsTheme.paper) => ZsColors.paper.accentTokens,
    (ZsAccentFamily.blue, ZsTheme.night) => ZsAccents.blueNight,
    (ZsAccentFamily.blue, ZsTheme.paper) => ZsAccents.bluePaper,
    (ZsAccentFamily.purple, ZsTheme.night) => ZsAccents.purpleNight,
    (ZsAccentFamily.purple, ZsTheme.paper) => ZsAccents.purplePaper,
    (ZsAccentFamily.pink, ZsTheme.night) => ZsAccents.pinkNight,
    (ZsAccentFamily.pink, ZsTheme.paper) => ZsAccents.pinkPaper,
    (ZsAccentFamily.red, ZsTheme.night) => ZsAccents.redNight,
    (ZsAccentFamily.red, ZsTheme.paper) => ZsAccents.redPaper,
    (ZsAccentFamily.orange, ZsTheme.night) => ZsAccents.orangeNight,
    (ZsAccentFamily.orange, ZsTheme.paper) => ZsAccents.orangePaper,
    (ZsAccentFamily.yellow, ZsTheme.night) => ZsAccents.yellowNight,
    (ZsAccentFamily.yellow, ZsTheme.paper) => ZsAccents.yellowPaper,
    (ZsAccentFamily.green, ZsTheme.night) => ZsAccents.greenNight,
    (ZsAccentFamily.green, ZsTheme.paper) => ZsAccents.greenPaper,
    (ZsAccentFamily.graphite, ZsTheme.night) => ZsAccents.graphiteNight,
    (ZsAccentFamily.graphite, ZsTheme.paper) => ZsAccents.graphitePaper,
  };
}
