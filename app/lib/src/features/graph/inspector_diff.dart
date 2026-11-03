// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show SelectionArea;
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show DiffLayoutSetting;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';

/// [hunk]'s range as `jj diff --git` prints it, `@@ −l,n +r,m @@` with U+2212 for the minus: a line number is the
/// range's 1-based start, or its 0-based start when it is empty (jj's `to_line_number`, cli/src/diff_util.rs:1780 @
/// v0.46.0), the count its length.
String hunkHeader(Hunk hunk) {
  int line(({int start, int end}) range) => range.end > range.start ? range.start + 1 : range.start;
  final ({int start, int end}) l = hunk.before;
  final ({int start, int end}) r = hunk.after;
  return '@@ −${line(l)},${l.end - l.start} +${line(r)},${r.end - r.start} @@'; // l10n-ignore: jj's hunk header
}

/// The side-by-side rows of [lines] (DS DiffHunk.jsx:17-25): a context line fills both cells; a run of removed lines
/// followed by a run of added lines pairs row by row, the shorter side's cells null.
List<(HunkLine?, HunkLine?)> pairSideBySide(List<HunkLine> lines) {
  final rows = <(HunkLine?, HunkLine?)>[];
  var i = 0;
  while (i < lines.length) {
    if (lines[i].kind == HunkLineKind.context) {
      rows.add((lines[i], lines[i]));
      i++;
      continue;
    }
    final removed = <HunkLine>[];
    final added = <HunkLine>[];
    while (i < lines.length && lines[i].kind == HunkLineKind.removed) {
      removed.add(lines[i++]);
    }
    while (i < lines.length && lines[i].kind == HunkLineKind.added) {
      added.add(lines[i++]);
    }
    for (var k = 0; k < math.max(removed.length, added.length); k++) {
      rows.add((k < removed.length ? removed[k] : null, k < added.length ? added[k] : null));
    }
  }
  return rows;
}

String _text(HunkLine line) {
  final String text = line.text.endsWith('\n') ? line.text.substring(0, line.text.length - 1) : line.text;
  return text.endsWith('\r') ? text.substring(0, text.length - 1) : text;
}

/// jj's marker after a last line without its newline (`jj diff --git`).
const noNewlineMarker = r'\ No newline at end of file'; // l10n-ignore: jj's own words

/// The marker line under a line without its newline: faint mono, outside the selection like the sigils.
Widget _noNewline(ZsColors colors, EdgeInsets padding) => Padding(
  padding: padding,
  child: SelectionContainer.disabled(
    child: Text(noNewlineMarker, softWrap: false, style: ZsType.code.copyWith(color: colors.textFaint)),
  ),
);

/// The focused file's diff block (Story 10.24; DS components/content/DiffView, content.css:22-46): the code well with
/// a bar (the path, the layout toggle, Viewed) over its hunks, the refusal text or a one-line placeholder; a viewed
/// file folds into one green row whose click unfolds it and clears Viewed. Without [onViewedChanged] there is no Viewed
/// toggle and nothing folds (Story 10.29's operation view). With [hunkPicked] each hunk with sections gets a checkbox,
/// with [modePicked] the mode-change note does (Story 10.26); without them there is none.
class InspectorDiffView extends StatelessWidget {
  /// The block of [path].
  const InspectorDiffView({
    required this.path,
    required this.diff,
    required this.error,
    required this.layout,
    required this.onLayoutChanged,
    this.viewed = false,
    this.onViewedChanged,
    this.hunkPicked,
    this.onHunkToggled,
    this.modePicked,
    this.onModeToggled,
    super.key,
  });

  /// A hunk's pick state (all, none, null for mixed); null: no hunk checkboxes.
  final bool? Function(Hunk hunk)? hunkPicked;

  /// Toggles a hunk's pick.
  final ValueChanged<Hunk>? onHunkToggled;

  /// Whether the mode change is picked; null: no mode checkbox.
  final bool? modePicked;

  /// Toggles the mode change's pick.
  final VoidCallback? onModeToggled;

  /// The focused path.
  final String path;

  /// Its diff; null while it loads, after a refusal, or when the reply has no entry for it.
  final FileDiff? diff;

  /// The read's refusal.
  final ZanshinFfiException? error;

  /// Whether the file is marked Viewed (ignored without [onViewedChanged]).
  final bool viewed;

  /// Toggles Viewed; null hides the toggle.
  final ValueChanged<bool>? onViewedChanged;

  /// Unified or side by side.
  final DiffLayoutSetting layout;

  /// Changes the layout.
  final ValueChanged<DiffLayoutSetting> onLayoutChanged;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final ValueChanged<bool>? onViewedChanged = this.onViewedChanged;
    final bool viewed = this.viewed && onViewedChanged != null;
    final Widget body;
    if (onViewedChanged != null && viewed) {
      body = _FlatButton(
        identifier: 'inspector-diff-folded',
        label: strings.inspectorViewedFolded,
        onPressed: () => onViewedChanged(false),
        builder: (status) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          color: status.hovered ? colors.addBgHi : colors.addBg,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 8,
            children: <Widget>[
              ZanshinIcon(ZI.check, size: ZsIconSize.sm, color: colors.add),
              Flexible(
                child: Text(
                  strings.inspectorViewedFolded,
                  style: ZsType.secondary.copyWith(fontSize: ZsType.fsSm, color: colors.add),
                ),
              ),
            ],
          ),
        ),
      );
    } else if (error case final ZanshinFfiException error?) {
      body = _note(context, error.context ?? error.code);
    } else if (diff case final FileDiff diff?) {
      final bool? Function(Hunk hunk)? hunkPicked = this.hunkPicked;
      final Widget mode = modePicked == null
          ? _note(context, strings.inspectorDiffModeChange)
          : Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Row(
                children: <Widget>[
                  ZsCheckbox(
                    value: modePicked,
                    onChanged: (_) => onModeToggled?.call(),
                    label: strings.inspectorModeCheck,
                    size: ZsCheckboxSize.sm,
                    identifier: 'inspector-mode-check',
                  ),
                  Expanded(child: _note(context, strings.inspectorDiffModeChange)),
                ],
              ),
            );
      body = diff.binary
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (diff.modeChange) mode,
                _note(context, strings.inspectorDiffBinary),
              ],
            )
          : diff.hunks.isEmpty
          ? (diff.modeChange ? mode : _note(context, strings.inspectorDiffNoLines))
          : SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (diff.modeChange) mode,
                  for (var i = 0; i < diff.hunks.length; i++)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: i == 0 ? null : Border(top: BorderSide(color: colors.flBorder)),
                      ),
                      child: InspectorDiffHunk(
                        hunk: diff.hunks[i],
                        layout: layout,
                        selectable: hunkPicked != null && diff.hunks[i].sections.isNotEmpty,
                        picked: hunkPicked == null ? false : hunkPicked(diff.hunks[i]),
                        onToggle: () => onHunkToggled?.call(diff.hunks[i]),
                      ),
                    ),
                ],
              ),
            );
    } else {
      body = const SizedBox.shrink();
    }
    return Container(
      key: const ValueKey<String>('inspector-diff'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.codeBg,
        border: Border.all(color: viewed ? colors.addEdge : colors.flBorder),
        borderRadius: BorderRadius.circular(metrics.radiusWell),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.flBorder)),
            ),
            child: Row(
              spacing: 8,
              children: <Widget>[
                Expanded(
                  child: Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ZsType.id.copyWith(fontSize: ZsType.fsXs, color: colors.text),
                  ),
                ),
                ZsSegmented<DiffLayoutSetting>(
                  size: ZsSegmentedSize.sm,
                  label: strings.inspectorDiffLayout,
                  identifier: 'inspector-diff-layout',
                  value: layout,
                  onChanged: onLayoutChanged,
                  segments: <ZsSegment<DiffLayoutSetting>>[
                    ZsSegment(
                      value: DiffLayoutSetting.unified,
                      icon: ZI.splitInline,
                      tooltip: strings.inspectorDiffUnified,
                    ),
                    ZsSegment(
                      value: DiffLayoutSetting.sideBySide,
                      icon: ZI.splitSide,
                      tooltip: strings.inspectorDiffSideBySide,
                    ),
                  ],
                ),
                if (onViewedChanged != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: _ViewedToggle(viewed: viewed, onChanged: onViewedChanged),
                  ),
              ],
            ),
          ),
          body,
        ],
      ),
    );
  }

  static Widget _note(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
    child: Text(
      text,
      key: const ValueKey<String>('inspector-diff-note'),
      style: ZsType.code.copyWith(color: ZsColors.of(context).textDim),
    ),
  );
}

/// The Viewed toggle (DS content.css:40-44): a checkbox role around a presentational add-tone [ZsCheckbox] and
/// "Viewed".
class _ViewedToggle extends StatelessWidget {
  const _ViewedToggle({required this.viewed, required this.onChanged});

  final bool viewed;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    return ZsTooltip(
      message: viewed ? strings.inspectorMarkNotViewed : strings.inspectorMarkViewed,
      child: _FlatButton(
        identifier: 'inspector-viewed',
        label: strings.inspectorViewed,
        checked: viewed,
        radius: metrics.radiusTag,
        onPressed: () => onChanged(!viewed),
        builder: (status) {
          final (Color fill, Color edge, Color ink) = viewed
              ? (status.hovered ? colors.addBgHi : colors.addBg, colors.addRing, colors.add)
              : status.hovered
              ? (colors.flHover, colors.borderStrong, colors.text)
              : (colors.flHover.withValues(alpha: 0), colors.border, colors.textMuted);
          return Container(
            padding: const EdgeInsets.fromLTRB(6, 3, 8, 3),
            decoration: BoxDecoration(
              color: fill,
              border: Border.all(color: edge),
              borderRadius: BorderRadius.circular(metrics.radiusTag),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: <Widget>[
                ZsCheckbox(
                  value: viewed,
                  presentational: true,
                  size: ZsCheckboxSize.sm,
                  tone: ZsCheckboxTone.add,
                ),
                Text(
                  strings.inspectorViewed,
                  style: ZsType.control.copyWith(fontSize: ZsType.fsXs, color: ink),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A flat button on [ZsControlCore]: a click or ↩ / Space runs [onPressed]; [builder] paints it per state.
class _FlatButton extends StatelessWidget {
  const _FlatButton({
    required this.identifier,
    required this.label,
    required this.onPressed,
    required this.builder,
    this.checked,
    this.radius = 0,
  });

  final String identifier;
  final String label;
  final VoidCallback onPressed;
  final Widget Function(ZsControlStatus status) builder;
  final bool? checked;
  final double radius;

  @override
  Widget build(BuildContext context) => ZsControlCore(
    identifier: identifier,
    onActivate: onPressed,
    ring: ZsRingPlacement.inside,
    ringRadius: radius,
    semantics: SemanticsProperties(button: checked == null, checked: checked, label: label),
    builder: (context, status) => builder(status),
  );
}

/// A small text button in the Changes header, "Mark all" / "Reset" (DS kit.css:121-122): padding 2 7, radius 6,
/// `--text-muted`, hover `--fl-hover` and `--text`.
class InspectorTextButton extends StatelessWidget {
  /// A button reading [label].
  const InspectorTextButton({required this.label, required this.onPressed, required this.identifier, super.key});

  /// The text.
  final String label;

  /// Runs on activation.
  final VoidCallback onPressed;

  /// The node's identifier.
  final String identifier;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return _FlatButton(
      identifier: identifier,
      label: label,
      radius: 6,
      onPressed: onPressed,
      builder: (status) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: status.hovered ? colors.flHover : colors.flHover.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: ZsType.secondary.copyWith(
            fontSize: 11.5,
            color: status.hovered ? colors.text : colors.textMuted,
          ),
        ),
      ),
    );
  }
}

/// One hunk (DS components/content/DiffHunk, content.css:48-55): the header band (`--hunk-bg`: the range in
/// `--hunk`, the symbol, +added / −removed) over its lines, unified (a sigil column, scrolling horizontally on its own)
/// or side by side (two clipped cells per row). The unified lines sit in a [ZsScrollArea]: its bar along the bottom
/// shows a cut line while scrolling or hovered, ←/→ scroll it when focused. Story 10.26 (DS DiffHunk.prompt.md:8-11,
/// content.css:58-59): a [selectable] hunk leads its header with a tristate checkbox (its Tab stop, Space toggles);
/// a picked one (all or mixed) has its header on `--accent-soft-hi` with `--text` and a 2 px `--accent-line` edge
/// along its lines.
class InspectorDiffHunk extends StatefulWidget {
  /// [hunk] in [layout].
  const InspectorDiffHunk({
    required this.hunk,
    required this.layout,
    this.selectable = false,
    this.picked = false,
    this.onToggle,
    super.key,
  });

  /// The hunk.
  final Hunk hunk;

  /// Unified or side by side.
  final DiffLayoutSetting layout;

  /// Whether the header has a checkbox.
  final bool selectable;

  /// Its pick: all, none, or null for some of its sections.
  final bool? picked;

  /// Toggles [picked].
  final VoidCallback? onToggle;

  @override
  State<InspectorDiffHunk> createState() => _InspectorDiffHunkState();
}

class _InspectorDiffHunkState extends State<InspectorDiffHunk> {
  // The area's vertical controller stays unattached: the hunk scrolls only sideways, the inspector scrolls it down.
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  Hunk get hunk => widget.hunk;

  DiffLayoutSetting get layout => widget.layout;

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final TextStyle head = ZsType.id.copyWith(fontSize: ZsType.fsSm);
    final String? symbol = hunk.symbol;
    final bool chosen = widget.picked ?? true;
    final Widget lines = layout == DiffLayoutSetting.unified ? _unified(colors) : _sideBySide(colors);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          key: const ValueKey<String>('inspector-hunk-header'),
          constraints: const BoxConstraints(minHeight: 30),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          color: chosen ? colors.accentSoftHi : colors.hunkBg,
          child: Row(
            spacing: 8,
            children: <Widget>[
              if (widget.selectable)
                ZsCheckbox(
                  value: widget.picked,
                  tristate: true,
                  onChanged: (_) => widget.onToggle?.call(),
                  label: context.l10n.inspectorHunkCheck(hunkHeader(hunk)),
                  size: ZsCheckboxSize.sm,
                  identifier: 'inspector-hunk-check',
                ),
              Text(hunkHeader(hunk), style: head.copyWith(color: chosen ? colors.text : colors.hunk)),
              Expanded(
                child: symbol == null
                    ? const SizedBox.shrink()
                    : Text(
                        symbol,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: head.copyWith(color: colors.textMuted),
                      ),
              ),
              if (hunk.added > 0)
                Text('+${hunk.added}', style: head.copyWith(color: colors.add)), // l10n-ignore: a count
              if (hunk.removed > 0)
                Text('−${hunk.removed}', style: head.copyWith(color: colors.rem)), // l10n-ignore: a count
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          // Always there (no edge: none drawn), so a toggle keeps the lines' scroll position.
          child: DecoratedBox(
            key: const ValueKey<String>('inspector-hunk-edge'),
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: chosen ? Border(left: BorderSide(color: colors.accentLine, width: 2)) : null,
            ),
            child: lines,
          ),
        ),
      ],
    );
  }

  (Color, Color) _look(ZsColors colors, HunkLineKind kind) => switch (kind) {
    HunkLineKind.context => (colors.textMuted.withValues(alpha: 0), colors.textMuted),
    HunkLineKind.added => (colors.addBg, colors.add),
    HunkLineKind.removed => (colors.remBg, colors.rem),
  };

  Widget _unified(ZsColors colors) => LayoutBuilder(
    builder: (context, constraints) => ZsScrollArea(
      controller: _vertical,
      horizontalController: _horizontal,
      child: SingleChildScrollView(
        controller: _horizontal,
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final HunkLine line in hunk.lines) ...<Widget>[
                  Builder(
                    builder: (context) {
                      final (Color fill, Color ink) = _look(colors, line.kind);
                      final String sigil = switch (line.kind) {
                        HunkLineKind.context => ' ',
                        HunkLineKind.added => '+',
                        HunkLineKind.removed => '−',
                      };
                      return Container(
                        color: fill,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            SizedBox(
                              width: 14,
                              child: SelectionContainer.disabled(
                                child: Text(
                                  sigil,
                                  style: ZsType.code.copyWith(
                                    color: line.kind == HunkLineKind.context ? colors.textFaint : ink,
                                  ),
                                ),
                              ),
                            ),
                            Text(_text(line), softWrap: false, style: ZsType.code.copyWith(color: ink)),
                          ],
                        ),
                      );
                    },
                  ),
                  if (!line.text.endsWith('\n')) _noNewline(colors, const EdgeInsets.only(left: 24, right: 10)),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _sideBySide(ZsColors colors) {
    Widget cell(HunkLine? line, {required bool left}) {
      final BorderSide edge = left ? BorderSide(color: colors.flBorder) : BorderSide.none;
      if (line == null) {
        return Container(
          constraints: const BoxConstraints(minHeight: 17),
          decoration: BoxDecoration(
            color: colors.flHover.withValues(alpha: colors.flHover.a * .4),
            border: Border(right: edge),
          ),
        );
      }
      final (Color fill, Color ink) = _look(colors, line.kind);
      return Container(
        constraints: const BoxConstraints(minHeight: 17),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: fill,
          border: Border(right: edge),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _text(line),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: ZsType.code.copyWith(color: ink),
            ),
            if (!line.text.endsWith('\n')) _noNewline(colors, EdgeInsets.zero),
          ],
        ),
      );
    }

    return Column(
      key: const ValueKey<String>('inspector-diff-split'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final (HunkLine? left, HunkLine? right) in pairSideBySide(hunk.lines))
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: cell(left, left: true)),
                Expanded(child: cell(right, left: false)),
              ],
            ),
          ),
      ],
    );
  }
}
