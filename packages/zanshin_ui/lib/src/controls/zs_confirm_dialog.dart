// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_type.dart';
import '../icons/zanshin_icon.dart';
import '../materials/zs_sheet.dart';
import '../zs_strings.dart';
import 'zs_button.dart';
import 'zs_control.dart';
import 'zs_control_text.dart';

/// A confirmation's tone (DS components/controls/ConfirmDialog.d.ts).
enum ZsConfirmTone {
  /// The filled red button is the one primary; focus starts on Cancel; ⌘↩ confirms.
  destructive,

  /// The gold primary, focused; the `conflict` mark in `--warn` before the title.
  warn,

  /// The gold primary, focused.
  standard,
}

/// The confirmation sheet for the few things `jj undo` cannot take back (DS
/// components/controls/ConfirmDialog.{d.ts,jsx,prompt.md}; controls.css:126-136), the content of 11.2's `ZsSheet`
/// (420 wide): padding 20 20 16, rows 10 apart — the title (600 `--fs-lg`/1.35, `--tracking-dialog`; warn adds
/// `ZI.conflict` lg in `--warn`), the [body] (`--fs-control`/1.5 in `--text-muted`), the exact command [cmd] in a well
/// (padding 8 10, radius `--radius-md`, `--code-bg`, a 1 px `--fl-border`, `--fs-id` mono/1.55), and the footer 8
/// below: the destructive hint "⌘↩ confirms" (`--fs-sm`, `--text-faint`) on the left, then Cancel and the confirm
/// button (md; destructive or the gold primary), 8 apart.
///
/// **Keys.** Destructive: focus starts on Cancel, ↩ presses the focused button, ⌘↩ confirms. Warn and standard: the
/// gold primary has focus, ↩ confirms. Esc cancels; Tab stays inside; a click on the scrim does nothing; focus
/// returns to the opener (all `ZsSheet`'s). While [busy] the confirm button shows a spinner and ⌘↩, ↩ and Esc do
/// nothing. VoiceOver: the sheet named by the title.
class ZsConfirmDialog extends StatefulWidget implements ZsControl {
  /// A confirmation asking [title].
  const ZsConfirmDialog({
    required this.title,
    required this.confirmLabel,
    required this.onConfirm,
    required this.onCancel,
    this.body,
    this.cmd,
    this.cancelLabel,
    this.tone = ZsConfirmTone.destructive,
    this.busy = false,
    this.closing = false,
    this.onClosed,
    this.identifier,
    super.key,
  });

  /// The question, in sentence case, ending with "?".
  final String title;

  /// What changes and what cannot be recovered.
  final Widget? body;

  /// The exact jj command, shown in a mono well.
  final String? cmd;

  /// The confirm button's verb ("Clear history").
  final String confirmLabel;

  /// The cancel button's label; "Cancel" when null.
  final String? cancelLabel;

  /// Destructive, warn or standard.
  final ZsConfirmTone tone;

  /// Runs on the confirm button and ⌘↩.
  final VoidCallback onConfirm;

  /// Runs on Cancel and Esc.
  final VoidCallback onCancel;

  /// Whether the confirmed action runs.
  final bool busy;

  /// Whether the sheet leaves.
  final bool closing;

  /// Runs once the exit completes.
  final VoidCallback? onClosed;

  @override
  final String? identifier;

  /// The sheet's width (DS components/controls/ConfirmDialog.jsx:10).
  static const double _width = 420;

  @override
  State<ZsConfirmDialog> createState() => _ZsConfirmDialogState();
}

class _ZsConfirmDialogState extends State<ZsConfirmDialog> {
  final _cancel = FocusNode(debugLabel: 'ZsConfirmDialog cancel');
  final _confirm = FocusNode(debugLabel: 'ZsConfirmDialog confirm');

  bool get _destructive => widget.tone == ZsConfirmTone.destructive;

  @override
  void dispose() {
    _cancel.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _confirmIfIdle() {
    if (!widget.busy) {
      widget.onConfirm();
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final LogicalKeyboardKey key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter && key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    if (!_destructive || !(keyboard.isMetaPressed || keyboard.isControlPressed)) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      _confirmIfIdle();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final String? cmd = widget.cmd;
    final Widget? body = widget.body;
    return ZsSheet(
      semanticLabel: widget.title,
      onCancel: widget.onCancel,
      busy: widget.busy,
      closing: widget.closing,
      onClosed: widget.onClosed,
      initialFocus: _destructive ? _cancel : _confirm,
      width: ZsConfirmDialog._width,
      child: Semantics(
        identifier: widget.identifier,
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          onKeyEvent: _handleKey,
          child: Padding(
            // `padding:20px 20px 16px` (DS components/controls/controls.css:127).
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 10,
              children: <Widget>[
                Row(
                  spacing: 8,
                  children: <Widget>[
                    if (widget.tone == ZsConfirmTone.warn)
                      ZanshinIcon(ZI.conflict, size: ZsIconSize.lg, color: colors.warn),
                    Expanded(
                      child: Text(
                        widget.title,
                        style: zsSans(ZsType.fsLg, weight: FontWeight.w600, height: ZsType.lhSnug).copyWith(
                          color: colors.text,
                          letterSpacing: ZsType.trackingDialog * ZsType.fsLg,
                        ),
                      ),
                    ),
                  ],
                ),
                if (body != null)
                  DefaultTextStyle.merge(
                    style: zsSans(ZsType.fsControl, height: ZsType.lhUi).copyWith(color: colors.textMuted),
                    child: body,
                  ),
                if (cmd != null)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.codeBg,
                      border: Border.all(color: colors.flBorder),
                      borderRadius: BorderRadius.circular(metrics.radiusMd),
                    ),
                    child: Padding(
                      // `padding:8px 10px` inside the 1 px border (DS components/controls/controls.css:134).
                      padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
                      child: Text(cmd, style: zsMono(ZsType.fsId, height: 1.55).copyWith(color: colors.textMuted)),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    spacing: 8,
                    children: <Widget>[
                      Expanded(
                        child: _destructive
                            ? Text(
                                zsStrings(context).confirmShortcutHint,
                                style: zsSans(ZsType.fsSm, height: ZsType.lhSnug).copyWith(color: colors.textFaint),
                              )
                            : const SizedBox.shrink(),
                      ),
                      ZsButton(
                        label: widget.cancelLabel ?? zsStrings(context).confirmCancel,
                        size: ZsButtonSize.md,
                        focusNode: _cancel,
                        onPressed: () {
                          if (!widget.busy) {
                            widget.onCancel();
                          }
                        },
                      ),
                      ZsButton(
                        label: widget.confirmLabel,
                        size: ZsButtonSize.md,
                        variant: _destructive ? ZsButtonVariant.destructive : ZsButtonVariant.primary,
                        focusNode: _confirm,
                        busy: widget.busy,
                        onPressed: _confirmIfIdle,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
