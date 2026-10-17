// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_type.dart';
import 'zs_control.dart';
import 'zs_control_text.dart';

/// A key cap, only in prose — hints, empty states, callouts — and as the one hint in an empty search field (DS
/// components/content/Kbd.{d.ts,prompt.md}; content.css:62-63; readme.md:63): `--fs-xs` mono at line height 1.4 in
/// `--text-muted` on `--bg-card-2`, a 1 px `--border`, padding 1 5, radius `--radius-kbd`. One cap per key; menus,
/// tooltips and buttons write shortcuts as plain text. Not focusable; read as its text.
class ZsKbd extends StatelessWidget implements ZsControl {
  /// A cap showing [label].
  const ZsKbd(this.label, {this.identifier, super.key});

  /// The key's glyph ("⌘", "/").
  final String label;

  @override
  final String? identifier;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final Widget cap = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.bgCard2,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusKbd),
      ),
      child: Padding(
        // `padding:1px 5px` inside the 1 px border (DS components/content/content.css:63).
        padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
        child: Text(label, style: zsMono(ZsType.fsXs, height: 1.4).copyWith(color: colors.textMuted)),
      ),
    );
    return identifier == null ? cap : Semantics(container: true, identifier: identifier, child: cap);
  }
}
