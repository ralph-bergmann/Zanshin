// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// "Working copy is stale · ‹command›" (Story 10.5 item 9; DS components/overlays/StaleNotice.{prompt.md,jsx},
/// overlays.css:62-68): a glass pill 44 high (`--control-xl`, radius `--radius-pill`, padding 0 7 0 16, gap 9), the
/// mark `conflict` in `--warn`, the sentence `--text` 500, "·" `--text-faint`, the command mono `--text-muted`.
///
/// With [onUpdate] it offers "Update working copy" — a quiet button with `jj workspace update-stale` in its tooltip,
/// [busy] while it runs — for every cause (9.23's `update-stale` recovers all three); without one, an icon-only Copy
/// that writes [command] to the clipboard. jj's [message] for the cause is the sentence's tooltip and part of the
/// label (Claude's proposal). Role status (a live region, announced when it appears); the button is its Tab stop. The
/// shell's slot positions it and fades it in.
class StaleNotice extends StatelessWidget {
  /// A notice naming [command].
  const StaleNotice({required this.command, this.message, this.onUpdate, this.busy = false, super.key});

  /// The sentence.
  static const title = 'Working copy is stale';

  /// What "Update working copy" runs.
  static const updateCommand = 'jj workspace update-stale';

  /// The command jj's hint names.
  final String command;

  /// jj's message for the cause.
  final String? message;

  /// Runs `jj workspace update-stale`; null offers Copy instead.
  final VoidCallback? onUpdate;

  /// Whether the update runs.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    const gap = SizedBox(width: 9);
    final Widget sentence = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ZanshinIcon(ZI.conflict, size: ZsIconSize.md, color: colors.warn),
        gap,
        Text(
          title,
          style: ZsType.control.copyWith(color: colors.text, fontWeight: ZsType.fwMedium),
        ),
        gap,
        Text('·', style: ZsType.control.copyWith(color: colors.textFaint)),
        gap,
        Flexible(
          child: Text(
            command,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ZsType.id.copyWith(color: colors.textMuted),
          ),
        ),
      ],
    );
    final String? message = this.message;
    final VoidCallback? onUpdate = this.onUpdate;
    return Semantics(
      container: true,
      liveRegion: true,
      label: message == null ? '$title · $command' : '$title · $command. $message',
      child: SizedBox(
        height: metrics.controlXl,
        child: ZsGlass(
          radius: metrics.radiusPill,
          padding: const EdgeInsets.only(left: 16, right: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // A narrow window ellipsizes the command; the label keeps it whole.
              Flexible(
                child: ExcludeSemantics(
                  child: message == null ? sentence : ZsTooltip(message: message, child: sentence),
                ),
              ),
              // The gap plus the button's own 4 px margin (overlays.css:63, :68).
              const SizedBox(width: 13),
              if (onUpdate != null)
                ZsTooltip(
                  message: updateCommand,
                  child: ZsButton(
                    label: 'Update working copy',
                    icon: ZI.fetch,
                    size: ZsButtonSize.md,
                    busy: busy,
                    onPressed: onUpdate,
                    identifier: 'stale-notice.update',
                  ),
                )
              else
                ZsButton(
                  label: 'Copy — $command',
                  icon: ZI.copy,
                  iconOnly: true,
                  onPressed: () => unawaited(Clipboard.setData(ClipboardData(text: command))),
                  identifier: 'stale-notice.copy',
                ),
            ],
          ),
        ),
      ),
    );
  }
}
