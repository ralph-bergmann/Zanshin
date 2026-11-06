// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';

/// A Settings group (DS components/settings/SettingsGroup.*, settings.css:2-4,16): the sentence-case [title] rendered
/// in caps, [meta] in mono beside it, then its rows in one `--fl-hover` box of radius 12 — or, [bare], as they are
/// (the Result well).
class SettingsGroup extends StatelessWidget {
  /// The group [title] over [children].
  const SettingsGroup({required this.title, required this.children, this.meta, this.bare = false, super.key});

  /// The heading, sentence case.
  final String title;

  /// A mono note beside the heading (`builtin_immutable_heads()`).
  final String? meta;

  /// Whether the rows sit without the box.
  final bool bare;

  /// The rows.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final String? meta = this.meta;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 7),
          child: Semantics(
            header: true,
            child: Text.rich(
              TextSpan(
                text: ZsType.caps(title),
                children: <InlineSpan>[
                  if (meta != null)
                    TextSpan(
                      text: '  $meta',
                      style: ZsType.id.copyWith(fontSize: ZsType.fsXs, letterSpacing: 0, color: colors.textFaint),
                    ),
                ],
              ),
              style: ZsType.capsLabel.copyWith(color: colors.textDim),
            ),
          ),
        ),
        if (bare)
          ...children
        else
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.flHover,
              borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusWell),
            ),
            // A row painting its own fill (a remote form's `--fl-on`) keeps the box's corners.
            child: ClipRRect(
              borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusWell),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (var i = 0; i < children.length; i++)
                    if (i == 0)
                      children[i]
                    else
                      DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border(top: BorderSide(color: colors.flBorder)),
                        ),
                        child: children[i],
                      ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A Settings row (DS components/settings/SettingsRow.*, settings.css:5-15,19-27): [label] (13), an optional [hint], an
/// [error] and the jj [configKey] in mono under it; [child] on the right, or full width below it when [stack].
///
/// With [onOpen] it is a navigation row: the whole row is one button (click, ↩, Space) showing [child] (a value) and
/// ›; hover `--fl-on`, pressed `--fl-press`.
class SettingsRow extends StatelessWidget {
  /// The row [label] with [child].
  const SettingsRow({
    required this.label,
    this.child,
    this.hint,
    this.error,
    this.configKey,
    this.stack = false,
    this.onOpen,
    this.identifier,
    super.key,
  });

  /// The label.
  final String label;

  /// The control (or, for a navigation row, the value).
  final Widget? child;

  /// A sentence under the label.
  final String? hint;

  /// The last write's error, under the label.
  final String? error;

  /// The jj config key the row writes, in mono.
  final String? configKey;

  /// Whether the control goes full width below the label.
  final bool stack;

  /// Opens the row's page; makes it a navigation row.
  final VoidCallback? onOpen;

  /// The navigation row's Semantics identifier.
  final String? identifier;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final String? hint = this.hint;
    final String? error = this.error;
    final String? configKey = this.configKey;
    final Widget labels = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: <Widget>[
        Text(label, style: ZsType.body.copyWith(height: 1.35, color: colors.text)),
        if (hint != null)
          Text(
            hint,
            style: ZsType.meta.copyWith(fontSize: ZsType.fsId, height: 1.4, color: colors.textDim),
          ),
        if (error != null)
          Text(
            error,
            style: ZsType.meta.copyWith(fontSize: ZsType.fsId, height: 1.4, color: colors.conflict),
          ),
        if (configKey != null)
          Text(
            configKey,
            style: ZsType.id.copyWith(fontSize: ZsType.fsXs, color: colors.textFaint),
          ),
      ],
    );
    final VoidCallback? open = onOpen;
    // The density (DS density.css .zs-setrow, .zs-setrow.is-stack): the minimum gains the step, the padding half of it each side.
    final double step = ZsMetrics.of(context).rowStep;
    final double half = step / 2;
    if (open == null) {
      final Widget? control = child;
      return ConstrainedBox(
        constraints: BoxConstraints(minHeight: 46 + step),
        child: Padding(
          padding: stack
              ? EdgeInsets.fromLTRB(14, 10 + half, 14, 12 + half)
              : EdgeInsets.symmetric(horizontal: 14, vertical: 8 + half),
          child: stack
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8,
                  children: <Widget>[labels, ?control],
                )
              : Row(
                  spacing: 16,
                  children: <Widget>[
                    Expanded(child: labels),
                    ?control,
                  ],
                ),
        ),
      );
    }
    return ZsControlCore(
      identifier: identifier,
      onActivate: open,
      ring: ZsRingPlacement.inside,
      ringRadius: ZsMetrics.of(context).radiusWell,
      semantics: SemanticsProperties(button: true, label: label, hint: hint),
      builder: (context, status) => ColoredBox(
        color: status.pressed
            ? colors.flPress
            : status.hovered
            ? colors.flOn
            : const Color(0x00000000),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: 46 + step),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8 + half),
            child: Row(
              spacing: 16,
              children: <Widget>[
                Expanded(child: labels),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 10,
                  children: <Widget>[
                    ?child,
                    ZanshinIcon(ZI.chevronRight, size: ZsIconSize.sm, color: colors.textDim),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A Settings text field (I1): it writes on ↩ or when it loses focus — only when its text differs from [value], the
/// last value read, or the last it wrote. [validate] may refuse the text (its error shows, nothing is written). Its
/// pending write is registered with [register] for the window's close, which writes a valid one and drops an invalid
/// one.
class SettingsTextField extends StatefulWidget {
  /// A field showing [value] that writes through [onCommit].
  const SettingsTextField({
    required this.value,
    required this.onCommit,
    required this.label,
    required this.register,
    required this.unregister,
    this.validate,
    this.error,
    this.mono = false,
    this.placeholder,
    this.identifier,
    super.key,
  });

  /// The value read, or null when there is none.
  final String? value;

  /// Writes the text; true when it landed.
  final Future<bool> Function(String text) onCommit;

  /// The text's error, or null when it may be written.
  final Future<String?> Function(String text)? validate;

  /// The last failed write's error.
  final String? error;

  /// The field's VoiceOver name.
  final String label;

  /// Registers the pending write for the window's close.
  final void Function(Object owner, Future<void> Function() flush) register;

  /// Removes it again.
  final void Function(Object owner) unregister;

  /// Whether the text is mono.
  final bool mono;

  /// The empty field's placeholder.
  final String? placeholder;

  /// The Semantics identifier.
  final String? identifier;

  @override
  State<SettingsTextField> createState() => SettingsTextFieldState();
}

/// The field's state; [commit] is its write.
class SettingsTextFieldState extends State<SettingsTextField> {
  late final ZsTextEditingController _controller;
  final _focus = FocusNode(debugLabel: 'settings field');
  late String _last;
  String? _invalid;
  var _committing = false;

  @override
  void initState() {
    super.initState();
    _last = widget.value ?? '';
    _controller = ZsTextEditingController(text: _last);
    _focus.addListener(_focusChanged);
    widget.register(this, commit);
  }

  @override
  void didUpdateWidget(SettingsTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final String value = widget.value ?? '';
    // A new read shows unless the field holds an edit.
    if (value != _last && _controller.text == _last && !_focus.hasFocus) {
      _last = value;
      _controller.text = value;
    }
  }

  @override
  void dispose() {
    widget.unregister(this);
    _focus
      ..removeListener(_focusChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (!_focus.hasFocus) {
      unawaited(commit());
    }
  }

  /// Writes the text when it differs from the last value read or written and is valid.
  Future<void> commit() async {
    final String text = _controller.text;
    if (text == _last || _committing) {
      return;
    }
    _committing = true;
    try {
      final String? invalid = await widget.validate?.call(text);
      if (invalid != null) {
        if (mounted) {
          setState(() => _invalid = invalid);
        }
        return;
      }
      if (await widget.onCommit(text)) {
        _last = text;
      }
      if (mounted) {
        setState(() => _invalid = null);
      }
    } finally {
      _committing = false;
    }
  }

  @override
  Widget build(BuildContext context) => ZsTextField(
    controller: _controller,
    focusNode: _focus,
    mono: widget.mono,
    label: widget.label,
    placeholder: widget.placeholder,
    error: _invalid ?? widget.error,
    identifier: widget.identifier,
    onSubmitted: (_) => unawaited(commit()),
  );
}

/// A page inside a Settings tab (DS components/settings/SettingsPage.*, settings.css:30-36): the back button "‹ [back]"
/// (read "Back to [back]"; ⌘[ goes back too, and Tab starts at it), the [title] (17/600, a heading), one sentence
/// [intro], then its groups 18 apart.
class SettingsPage extends StatelessWidget {
  /// The page [title] under a back button to [back].
  const SettingsPage({
    required this.back,
    required this.onBack,
    required this.title,
    required this.intro,
    required this.children,
    this.spacing = 18,
    super.key,
  });

  /// The gap between the heading block and each child (the config page's is 14, DS settings.css:93).
  final double spacing;

  /// Where back leads: the tab's name.
  final String back;

  /// Goes back to the tab.
  final VoidCallback onBack;

  /// The page's name.
  final String title;

  /// One sentence under the title.
  final String intro;

  /// The groups.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true): onBack,
      },
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: spacing,
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Transform.translate(
                  offset: const Offset(-6, -4),
                  child: ZsControlCore(
                    identifier: 'settings-page-back',
                    onActivate: onBack,
                    ring: ZsRingPlacement.outside,
                    ringRadius: ZsMetrics.of(context).radiusChip,
                    semantics: SemanticsProperties(button: true, label: context.l10n.settingsBackTo(back)),
                    builder: (context, status) => DecoratedBox(
                      decoration: BoxDecoration(
                        color: status.pressed
                            ? colors.flOn
                            : status.hovered
                            ? colors.flHover
                            : const Color(0x00000000),
                        borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusChip),
                      ),
                      child: SizedBox(
                        height: 26,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 10, 0),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 3,
                            children: <Widget>[
                              ZanshinIcon(
                                ZI.chevronLeft,
                                size: ZsIconSize.sm,
                                color: status.hovered || status.pressed ? colors.text : colors.textMuted,
                              ),
                              Text(
                                back,
                                style: ZsType.control.copyWith(
                                  fontWeight: FontWeight.w400,
                                  fontVariations: const <FontVariation>[FontVariation.weight(400)],
                                  color: status.hovered || status.pressed ? colors.text : colors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                  child: Semantics(
                    header: true,
                    child: Text(title, style: ZsType.dialogTitle.copyWith(color: colors.text)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 500),
                    child: Text(
                      intro,
                      style: ZsType.secondary.copyWith(fontSize: ZsType.fsControl, color: colors.textMuted),
                    ),
                  ),
                ),
              ],
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}
