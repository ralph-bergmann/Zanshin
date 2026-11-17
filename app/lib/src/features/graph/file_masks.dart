// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io' show FileSystemException;
import 'dart:math' as math;

import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show FileMask, SettingsStore;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../shell/calm_controller.dart';
import '../shell/shell_scope.dart';
import 'inspector_diff.dart' show InspectorTextButton;

// File masks (Story 10.49; design `Inspector Extras Study.html` §4): one app-wide list of IntelliJ-style masks in
// `general.fileMasks`; ticked ones hide matching rows from the inspector's and the operation view's file lists.

/// The compiled masks of one `general.fileMasks` value: build it once per settings value, never per row.
///
/// An entry splits at commas into trimmed, non-empty masks and matches a path when any of them does. A mask without
/// `/` matches the file name (after the last `/`), one with `/` the whole repo path (a leading `/` dropped). `**/` is
/// zero or more whole folders, any other `**` any characters, `*` any characters but `/`, `?` one character but `/`;
/// the rest is literal; anchored at both ends; case-sensitive.
class FileMaskMatcher {
  /// The matcher of [masks].
  FileMaskMatcher(this.masks)
    : _entries = <List<({RegExp pattern, bool byPath})>>[for (final FileMask mask in masks) _compile(mask.mask)];

  /// The entries, in the settings' order.
  final List<FileMask> masks;

  final List<List<({RegExp pattern, bool byPath})>> _entries;

  /// How many entries are ticked.
  int get activeCount => masks.where((mask) => mask.active).length;

  /// Whether entry [index] matches [path].
  bool entryMatches(int index, String path) {
    final String name = path.substring(path.lastIndexOf('/') + 1);
    return _entries[index].any((mask) => mask.pattern.hasMatch(mask.byPath ? path : name));
  }

  /// Whether a ticked entry matches [path].
  bool hides(String path) {
    for (var i = 0; i < masks.length; i++) {
      if (masks[i].active && entryMatches(i, path)) {
        return true;
      }
    }
    return false;
  }

  /// How many of [paths] entry [index] matches.
  int count(int index, Iterable<String> paths) => paths.where((path) => entryMatches(index, path)).length;

  /// Whether [entry] holds at least one usable mask (`,` or `/` alone holds none).
  static bool usable(String entry) => _compile(entry).isNotEmpty;

  static List<({RegExp pattern, bool byPath})> _compile(String entry) => <({RegExp pattern, bool byPath})>[
    for (final String part in entry.split(','))
      if (part.trim() case final String mask when (mask.startsWith('/') ? mask.substring(1) : mask).isNotEmpty)
        (
          pattern: _pattern(mask.startsWith('/') ? mask.substring(1) : mask),
          byPath: mask.contains('/'),
        ),
  ];

  static RegExp _pattern(String mask) {
    final out = StringBuffer('^');
    var i = 0;
    while (i < mask.length) {
      if (mask.startsWith('**/', i)) {
        out.write('(?:.*/)?');
        i += 3;
      } else if (mask.startsWith('**', i)) {
        out.write('.*');
        i += 2;
      } else if (mask[i] == '*') {
        out.write('[^/]*');
        i++;
      } else if (mask[i] == '?') {
        out.write('[^/]');
        i++;
      } else {
        out.write(RegExp.escape(mask[i]));
        i++;
      }
    }
    out.write(r'$');
    return RegExp(out.toString());
  }
}

/// The mask edits both views share; a failed write is swallowed (the store keeps the value).
extension FileMaskEdits on SettingsStore {
  /// Adds [text], trimmed, at the top and ticked; an equal entry moves to the top and is ticked instead of doubling.
  /// Text that holds no usable mask (blank, `,`, `/`) does nothing.
  void addFileMask(String text) {
    final String mask = text.trim();
    if (!FileMaskMatcher.usable(mask)) {
      return;
    }
    _editMasks(
      (masks) => <FileMask>[
        FileMask(mask: mask, active: true),
        for (final FileMask entry in masks)
          if (entry.mask != mask) entry,
      ],
    );
  }

  /// Ticks or unticks entry [index].
  void toggleFileMask(int index) => _editMasks(
    (masks) => <FileMask>[
      for (final (int i, FileMask mask) in masks.indexed)
        if (i == index) mask.copyWith(active: !mask.active) else mask,
    ],
  );

  /// Removes entry [index].
  void removeFileMask(int index) => _editMasks(
    (masks) => <FileMask>[
      for (var i = 0; i < masks.length; i++)
        if (i != index) masks[i],
    ],
  );

  void _editMasks(List<FileMask> Function(List<FileMask> masks) edit) => unawaited(
    update(
      (s) => s.copyWith(general: s.general.copyWith(fileMasks: edit(s.general.fileMasks))),
    ).onError<FileSystemException>((_, _) {}),
  );
}

/// The funnel in a file list's header (Story 10.49): the `filter` glyph and, while [active] entries are ticked, their
/// number; 24 high, padding 0 6, radius 7, `--text-dim`, `--accent` while any is ticked, hover or [open] `--fl-hover`
/// with `--text`.
class FileMasksButton extends StatelessWidget {
  /// The funnel showing [active].
  const FileMasksButton({required this.active, required this.open, required this.onPressed, super.key});

  /// How many entries are ticked.
  final int active;

  /// Whether the popover is open.
  final bool open;

  /// Opens or closes the popover.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final String tooltip = active > 0 ? strings.fileMasksButtonActiveTooltip(active) : strings.fileMasksButtonTooltip;
    return ZsTooltip(
      message: tooltip,
      child: ZsControlCore(
        identifier: 'inspector-file-masks',
        onActivate: onPressed,
        ring: ZsRingPlacement.inside,
        ringRadius: 7,
        semantics: SemanticsProperties(button: true, expanded: open, label: tooltip),
        builder: (context, status) {
          final ZsColors colors = ZsColors.of(context);
          final bool lit = open || status.hovered;
          final Color ink = lit ? colors.text : (active > 0 ? colors.accent : colors.textDim);
          return Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: lit ? colors.flHover : colors.flHover.withValues(alpha: 0),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 3,
              children: <Widget>[
                ZanshinIcon(ZI.filter, size: ZsIconSize.md, color: ink),
                if (active > 0)
                  Text(
                    '$active',
                    style: ZsType.secondary.copyWith(
                      fontSize: ZsType.fsSm,
                      fontWeight: FontWeight.w600,
                      fontVariations: const <FontVariation>[FontVariation.weight(600)],
                      color: ink,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The row below a file list while ticked masks hide some of its files (Story 10.49): 30 high, 6 above, a 1 px
/// `--fl-border` line on top, 11.5 `--text-dim`. When [pickable] its 22 px check column holds the hidden files' pick
/// state ([picked]: all / some / none), always shown; then "N files hidden" ("N files match your masks" while
/// [showing]) with the pick part when [pickable], and the buttons Show / Hide and Masks….
class FileMasksHint extends StatelessWidget {
  /// The hint for [count] hidden files.
  const FileMasksHint({
    required this.count,
    required this.showing,
    required this.onShow,
    required this.onMasks,
    this.pickable = false,
    this.picked = false,
    this.onPick,
    super.key,
  });

  /// How many files the ticked masks hide.
  final int count;

  /// Whether the hidden files are listed anyway (dimmed).
  final bool showing;

  /// Toggles [showing].
  final VoidCallback onShow;

  /// Opens the masks popover.
  final VoidCallback onMasks;

  /// Whether the hidden files take a checkbox (a selectable change).
  final bool pickable;

  /// The hidden files' pick state: all, none, or null for some.
  final bool? picked;

  /// Picks or unpicks every hidden file.
  final VoidCallback? onPick;

  /// The check column's width (the inspector's `inspectorCheckGutter`).
  static const double _gutter = 22;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final String pickPart = !pickable
        ? ''
        : switch (picked) {
            true => strings.fileMasksAllPicked,
            false => strings.fileMasksNonePicked,
            null => strings.fileMasksSomePicked,
          };
    return Semantics(
      identifier: 'inspector-masked-hint',
      container: true,
      child: Container(
        height: 30,
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.flBorder)),
        ),
        child: Row(
          children: <Widget>[
            if (pickable)
              SizedBox(
                width: _gutter,
                child: Center(
                  child: ZsCheckbox(
                    value: picked,
                    tristate: true,
                    onChanged: (_) => onPick?.call(),
                    label: strings.fileMasksPickHidden(count),
                    size: ZsCheckboxSize.sm,
                    identifier: 'inspector-masked-check',
                  ),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  (showing ? strings.fileMasksMatching(count) : strings.fileMasksHidden(count)) + pickPart,
                  key: const ValueKey<String>('inspector-masked-text'),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: ZsType.secondary.copyWith(fontSize: 11.5, color: colors.textDim),
                ),
              ),
            ),
            const SizedBox(width: 4),
            InspectorTextButton(
              label: showing ? strings.fileMasksHideShown : strings.fileMasksShow,
              identifier: 'inspector-masked-show',
              onPressed: onShow,
            ),
            const SizedBox(width: 4),
            InspectorTextButton(
              label: strings.fileMasksMasks,
              identifier: 'inspector-masked-masks',
              onPressed: onMasks,
            ),
          ],
        ),
      ),
    );
  }
}

/// Hosts the masks popover on the widget [builder] returns (Story 10.49; the host pattern of the graph's View options):
/// a [RawMenuAnchor] on [controller] — anyone holding it opens the popover here — 6 below the anchor, left edges
/// aligned, kept 8 inside the window. Esc and a click outside close it; Esc gives the focus back to what had it when
/// it opened. The popover counts each entry's matches among [paths] (the shown change's files).
class FileMasksAnchor extends StatefulWidget {
  /// The host of the popover on [settings]' masks.
  const FileMasksAnchor({
    required this.settings,
    required this.paths,
    required this.controller,
    required this.builder,
    super.key,
  });

  /// The app settings holding the masks.
  final SettingsStore settings;

  /// The files the popover counts matches in.
  final List<String> paths;

  /// Opens and closes the popover.
  final MenuController controller;

  /// The anchor; its `open` is true while the popover shows.
  final Widget Function(BuildContext context, bool open) builder;

  @override
  State<FileMasksAnchor> createState() => _FileMasksAnchorState();
}

class _FileMasksAnchorState extends State<FileMasksAnchor> {
  final _popover = FocusScopeNode(debugLabel: 'File masks popover');
  var _open = false;
  var _closing = false;
  var _refocus = false;
  FocusNode? _opener;
  VoidCallback? _hide;
  CalmHold? _hold;

  @override
  void dispose() {
    _hold?.release();
    _popover.dispose();
    super.dispose();
  }

  void _close({required bool refocus}) {
    if (widget.controller.isOpen) {
      _refocus = refocus;
      widget.controller.close();
    }
  }

  void _opened() {
    _hold?.release();
    _hold = ShellScope.maybeOf(context)?.openSurface();
  }

  void _closed() {
    _hold?.release();
    _hold = null;
    final FocusNode? opener = _opener;
    if (_refocus && opener != null && opener.context != null) {
      opener.requestFocus();
    }
    _refocus = false;
    _opener = null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      _close(refocus: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => RawMenuAnchor(
    controller: widget.controller,
    consumeOutsideTaps: true,
    onOpenRequested: (position, show) {
      _hide = null;
      _opener = FocusManager.instance.primaryFocus;
      setState(() {
        _open = true;
        _closing = false;
      });
      show();
    },
    onCloseRequested: (hide) {
      if (_closing) {
        return;
      }
      _hide = hide;
      setState(() {
        _open = false;
        _closing = true;
      });
    },
    onOpen: _opened,
    onClose: _closed,
    overlayBuilder: (context, info) => Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _MasksLayout(info.anchorRect),
        child: TapRegion(
          groupId: info.tapRegionGroupId,
          onTapOutside: (_) => _close(refocus: false),
          child: FocusScope(
            node: _popover,
            onKeyEvent: _onKey,
            child: ListenableBuilder(
              listenable: widget.settings,
              builder: (context, _) => FileMasksPopover(
                settings: widget.settings,
                paths: widget.paths,
                closing: _closing,
                onClosed: () {
                  final VoidCallback? hide = _hide;
                  _hide = null;
                  hide?.call();
                },
              ),
            ),
          ),
        ),
      ),
    ),
    builder: (context, controller, child) => widget.builder(context, _open),
  );
}

/// Places the popover 6 below its anchor with the left edges aligned, kept 8 inside the window.
class _MasksLayout extends SingleChildLayoutDelegate {
  _MasksLayout(this.anchor);

  final Rect anchor;

  static const double _gap = 6;
  static const double _margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.loose(
    Size(math.max(0, constraints.maxWidth - 2 * _margin), math.max(0, constraints.maxHeight - 2 * _margin)),
  );

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    math.max(_margin, math.min(anchor.left, size.width - _margin - childSize.width)),
    math.max(_margin, math.min(anchor.bottom + _gap, size.height - _margin - childSize.height)),
  );

  @override
  bool shouldRelayout(_MasksLayout oldDelegate) => oldDelegate.anchor != anchor;
}

/// The masks popover (Story 10.49; design extras-study.jsx `MaskPopover`): a [ZsPopover] 360 wide — the title "Hide
/// files matching", a mono field (focused on open; ↩ adds its text and clears it), one 28-high row per entry (its
/// checkbox, the entry in mono, how many of [paths] it matches, a × on hover or keyboard focus; a click on the row
/// toggles it) and the syntax footer.
class FileMasksPopover extends StatefulWidget {
  /// The popover editing [settings]' masks.
  const FileMasksPopover({
    required this.settings,
    required this.paths,
    this.closing = false,
    this.onClosed,
    super.key,
  });

  /// The app settings holding the masks.
  final SettingsStore settings;

  /// The files whose matches each row counts.
  final List<String> paths;

  /// Whether the popover leaves.
  final bool closing;

  /// Runs once the exit completes.
  final VoidCallback? onClosed;

  @override
  State<FileMasksPopover> createState() => _FileMasksPopoverState();
}

class _FileMasksPopoverState extends State<FileMasksPopover> {
  final _text = ZsTextEditingController();
  final _field = FocusNode(debugLabel: 'New file mask');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.closing) {
        _field.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _field.dispose();
    super.dispose();
  }

  void _add(String text) {
    widget.settings.addFileMask(text);
    _text.clear();
    _field.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final matcher = FileMaskMatcher(widget.settings.value.general.fileMasks);
    final List<FileMask> masks = matcher.masks;
    return ZsPopover(
      width: 360,
      label: strings.fileMasksPopoverLabel,
      closing: widget.closing,
      onClosed: widget.onClosed,
      identifier: 'file-masks-popover',
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
              child: Semantics(
                header: true,
                child: Text(
                  strings.fileMasksTitle,
                  style: ZsType.secondary.copyWith(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    fontVariations: const <FontVariation>[FontVariation.weight(600)],
                    color: colors.textDim,
                  ),
                ),
              ),
            ),
            ZsTextField(
              controller: _text,
              focusNode: _field,
              mono: true,
              placeholder: strings.fileMasksPlaceholder,
              label: strings.fileMasksFieldLabel,
              onSubmitted: _add,
              identifier: 'file-masks-field',
            ),
            // Only the entries scroll: the title, the field and the footer stay put in a short window.
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 6),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (var i = 0; i < masks.length; i++)
                        _MaskRow(
                          // The index too: a hand-edited file may hold two equal entries.
                          key: ValueKey<String>('file-mask $i ${masks[i].mask}'),
                          index: i,
                          mask: masks[i],
                          count: matcher.count(i, widget.paths),
                          onToggle: () => widget.settings.toggleFileMask(i),
                          onRemove: () => widget.settings.removeFileMask(i),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.flBorder)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(2, 6, 2, 0),
                child: Text(
                  strings.fileMasksFooter,
                  style: ZsType.secondary.copyWith(fontSize: ZsType.fsSm, height: 1.45, color: colors.textFaint),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One entry of the popover: radius 6, hover `--fl-hover`; the × shows on hover or keyboard focus in the row.
class _MaskRow extends StatefulWidget {
  const _MaskRow({
    required this.index,
    required this.mask,
    required this.count,
    required this.onToggle,
    required this.onRemove,
    super.key,
  });

  final int index;
  final FileMask mask;
  final int count;
  final VoidCallback onToggle;
  final VoidCallback onRemove;

  @override
  State<_MaskRow> createState() => _MaskRowState();
}

class _MaskRowState extends State<_MaskRow> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final FileMask mask = widget.mask;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onToggle,
          child: Semantics(
            identifier: 'file-mask-${widget.index}',
            container: true,
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: _hovered ? colors.flHover : colors.flHover.withValues(alpha: 0),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                spacing: 9,
                children: <Widget>[
                  ZsCheckbox(
                    value: mask.active,
                    onChanged: (_) => widget.onToggle(),
                    label: mask.active ? strings.fileMasksStopHiding(mask.mask) : strings.fileMasksHideMask(mask.mask),
                    size: ZsCheckboxSize.sm,
                  ),
                  Expanded(
                    child: Text(
                      mask.mask,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: ZsType.id.copyWith(color: colors.text),
                    ),
                  ),
                  Text(
                    widget.count == 0 ? '' : '${widget.count}',
                    style: ZsType.id.copyWith(fontSize: ZsType.fsSm, color: colors.textFaint),
                  ),
                  Opacity(
                    opacity: _hovered || _focused ? 1 : 0,
                    child: ZsTooltip(
                      message: strings.fileMasksRemoveTooltip,
                      child: ZsControlCore(
                        identifier: 'file-mask-${widget.index}-remove',
                        onActivate: widget.onRemove,
                        ring: ZsRingPlacement.inside,
                        ringRadius: 5,
                        semantics: SemanticsProperties(button: true, label: strings.fileMasksRemove(mask.mask)),
                        builder: (context, status) => Container(
                          width: 20,
                          height: 20,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: status.hovered ? colors.flOn : colors.flOn.withValues(alpha: 0),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: ZanshinIcon(
                            ZI.close,
                            size: ZsIconSize.sm,
                            color: status.hovered ? colors.text : colors.textFaint,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
