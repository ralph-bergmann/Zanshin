// SPDX-License-Identifier: MIT

// Theme extension carrying Zanshin design tokens.
// Dependency theme_tailor_annotation is declared for future @TailorMixin() migration.
// For now the extension is written manually for immediate compilation.

import 'package:material_ui/material_ui.dart';

@immutable
class ZanshinColors extends ThemeExtension<ZanshinColors> {
  const ZanshinColors({
    required this.bg,
    required this.bgWindow,
    required this.bgSidebar,
    required this.bgCard,
    required this.bgCard2,
    required this.bgElevated,
    required this.bgHistory,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textMuted,
    required this.textDim,
    required this.textFaint,
    required this.add,
    required this.addBg,
    required this.rem,
    required this.remBg,
    required this.hunk,
    required this.accent,
  });

  final Color bg;
  final Color bgWindow;
  final Color bgSidebar;
  final Color bgCard;
  final Color bgCard2;
  final Color bgElevated;
  final Color bgHistory;
  final Color border;
  final Color borderStrong;
  final Color textPrimary;
  final Color textMuted;
  final Color textDim;
  final Color textFaint;
  final Color add;
  final Color addBg;
  final Color rem;
  final Color remBg;
  final Color hunk;
  final Color accent;

  static const dark = ZanshinColors(
    bg: Color(0xFF0a0a0a),
    bgWindow: Color(0xFF0d0d0d),
    bgSidebar: Color(0xFF0d0d0d),
    bgCard: Color(0xFF131313),
    bgCard2: Color(0xFF1a1a1a),
    bgElevated: Color(0xFF1c1c1c),
    bgHistory: Color(0xFF0c0c0c),
    border: Color(0x0FFFFFFF),
    borderStrong: Color(0x1FFFFFFF),
    textPrimary: Color(0xFFe5e5e5),
    textMuted: Color(0xFF9ca3af),
    textDim: Color(0xFF6b7280),
    textFaint: Color(0xFF525252),
    add: Color(0xFF4ade80),
    addBg: Color(0x214ade80),
    rem: Color(0xFFf87171),
    remBg: Color(0x21f87171),
    hunk: Color(0xFF60a5fa),
    accent: Color(0xFF3b82f6),
  );

  static const light = ZanshinColors(
    bg: Color(0xFFf4f4f5),
    bgWindow: Color(0xFFfafafa),
    bgSidebar: Color(0xFFffffff),
    bgCard: Color(0xFFffffff),
    bgCard2: Color(0xFFf4f4f5),
    bgElevated: Color(0xFFffffff),
    bgHistory: Color(0xFFfafafa),
    border: Color(0x12000000),
    borderStrong: Color(0x26000000),
    textPrimary: Color(0xFF18181b),
    textMuted: Color(0xFF52525b),
    textDim: Color(0xFF71717a),
    textFaint: Color(0xFFa1a1aa),
    add: Color(0xFF16a34a),
    addBg: Color(0x2016a34a),
    rem: Color(0xFFdc2626),
    remBg: Color(0x20dc2626),
    hunk: Color(0xFF2563eb),
    accent: Color(0xFF3b82f6),
  );

  @override
  ZanshinColors copyWith({
    Color? bg,
    Color? bgWindow,
    Color? bgSidebar,
    Color? bgCard,
    Color? bgCard2,
    Color? bgElevated,
    Color? bgHistory,
    Color? border,
    Color? borderStrong,
    Color? textPrimary,
    Color? textMuted,
    Color? textDim,
    Color? textFaint,
    Color? add,
    Color? addBg,
    Color? rem,
    Color? remBg,
    Color? hunk,
    Color? accent,
  }) => ZanshinColors(
    bg: bg ?? this.bg,
    bgWindow: bgWindow ?? this.bgWindow,
    bgSidebar: bgSidebar ?? this.bgSidebar,
    bgCard: bgCard ?? this.bgCard,
    bgCard2: bgCard2 ?? this.bgCard2,
    bgElevated: bgElevated ?? this.bgElevated,
    bgHistory: bgHistory ?? this.bgHistory,
    border: border ?? this.border,
    borderStrong: borderStrong ?? this.borderStrong,
    textPrimary: textPrimary ?? this.textPrimary,
    textMuted: textMuted ?? this.textMuted,
    textDim: textDim ?? this.textDim,
    textFaint: textFaint ?? this.textFaint,
    add: add ?? this.add,
    addBg: addBg ?? this.addBg,
    rem: rem ?? this.rem,
    remBg: remBg ?? this.remBg,
    hunk: hunk ?? this.hunk,
    accent: accent ?? this.accent,
  );

  @override
  ZanshinColors lerp(ZanshinColors? other, double t) {
    if (other == null) {
      return this;
    }
    return ZanshinColors(
      bg: Color.lerp(bg, other.bg, t)!,
      bgWindow: Color.lerp(bgWindow, other.bgWindow, t)!,
      bgSidebar: Color.lerp(bgSidebar, other.bgSidebar, t)!,
      bgCard: Color.lerp(bgCard, other.bgCard, t)!,
      bgCard2: Color.lerp(bgCard2, other.bgCard2, t)!,
      bgElevated: Color.lerp(bgElevated, other.bgElevated, t)!,
      bgHistory: Color.lerp(bgHistory, other.bgHistory, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
      add: Color.lerp(add, other.add, t)!,
      addBg: Color.lerp(addBg, other.addBg, t)!,
      rem: Color.lerp(rem, other.rem, t)!,
      remBg: Color.lerp(remBg, other.remBg, t)!,
      hunk: Color.lerp(hunk, other.hunk, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
    );
  }
}

extension ZanshinColorsContext on BuildContext {
  ZanshinColors get zc => Theme.of(this).extension<ZanshinColors>()!;
}
