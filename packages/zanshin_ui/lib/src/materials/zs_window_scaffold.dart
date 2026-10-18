// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:zanshin_shell/zanshin_shell.dart' show WindowDragArea;

import '../design/zs_appearance.dart';
import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_type.dart';
import 'zs_window_fill.dart';

/// Where a [ZsWindowScaffold]'s header row puts its items.
enum ZsWindowHeaderAlign {
  /// The title at the start, the header's controls after it at the end edge (`.zs-win-hd`; Projects).
  start,

  /// Everything centred in the window, both paddings `--chrome-first-x` (`.zs-win-hd.is-center`; Settings' tabs).
  center,
}

/// A window of its own — Settings, Projects, jj log Configurations — as DS components/window/window.css:20-43 draws it
/// (Window.prompt.md:14-23; readme.md:187-194): [ZsWindowFill] edge to edge, a 52 pt header row that shares its row
/// with the system's traffic lights, a `--fl-border` hairline under it, then the [body].
///
/// **Header** (`.zs-win-hd`, window.css:27-31): `--window-hd-h` high; every item centres on the traffic-light block's
/// centre line `--tl-mid-y` (the CSS shifts them by `margin-top:(tl-mid-y − hd/2)·2`; Claude's proposal: on the line
/// itself, not the CSS content box's half pixel above it), 12 apart. [ZsWindowHeaderAlign.start] starts the [title]
/// at `--chrome-first-x` (block end + 12) and puts the [header] controls at the end edge, `--chrome-inset` in;
/// [ZsWindowHeaderAlign.center] centres the controls (and the title, unless hidden) between two `--chrome-first-x`
/// paddings (window.css:34). The title is 600 `--fs-base`/1.2 in `--text`, `--text-dim` in an inactive window
/// (window.css:30-32), cut with an ellipsis; [titleHidden] leaves it out of the row, the system still knows it.
/// The header's empty space drags the window and a double-click runs the titlebar action ([WindowDragArea] behind
/// the row; the title takes no pointer, so a drag on it moves the window too).
///
/// **Sidebar** (`.has-side`, window.css:38-43): the [sidebar] runs the window's full height, its first 52 pt empty
/// under the traffic lights (they drag the window), with a `--fl-border` hairline on its right; the header then runs
/// across the main column only and starts the title `--chrome-inset` after the sidebar. A window with a sidebar
/// fills its height (Projects is sized).
///
/// **Body:** loose below the header, so a content-sized window (no size, finite maximum constraints) takes the body's
/// height, and a sized window gives a filling body the rest of its height.
class ZsWindowScaffold extends StatelessWidget {
  /// A window titled [title] showing [body], with the [header] controls and an optional [sidebar].
  const ZsWindowScaffold({
    required this.title,
    required this.body,
    this.header = const <Widget>[],
    this.align = ZsWindowHeaderAlign.start,
    this.titleHidden = false,
    this.sidebar,
    super.key,
  });

  /// The window's title in its header (and, for the caller, its native title).
  final String title;

  /// The controls of the header row, in order: after the title at the end edge, or centred.
  final List<Widget> header;

  /// Where the header puts its items.
  final ZsWindowHeaderAlign align;

  /// Whether the title stays out of the header row (Settings, `titleHidden`).
  final bool titleHidden;

  /// The sidebar, sized by itself (Projects: 200); null for none.
  final Widget? sidebar;

  /// The window's content below the header.
  final Widget body;

  /// `.zs-win-title{font:600 var(--fs-base)/1.2 var(--font-sans)}` (window.css:30-31).
  static const _titleStyle = TextStyle(
    fontFamily: ZsType.sansFamily,
    fontWeight: FontWeight.w600,
    fontVariations: <FontVariation>[FontVariation.weight(600)],
    fontSize: ZsType.fsBase,
    height: 1.2,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: 0,
  );

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final Widget main = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _header(context, colors, metrics),
        Flexible(child: body),
      ],
    );
    final Widget? side = sidebar;
    if (side == null) {
      return ZsWindowFill(child: main);
    }
    return ZsWindowFill(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: colors.flBorder)),
            ),
            // `.has-side>.zs-win-side{padding-top:var(--window-hd-h)}` (window.css:39); the sidebar sets the width.
            child: Stack(
              fit: StackFit.passthrough,
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.only(top: metrics.windowHdH),
                  child: side,
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: metrics.windowHdH,
                  child: const WindowDragArea(child: ColoredBox(color: Color(0x00000000))),
                ),
              ],
            ),
          ),
          Expanded(child: main),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, ZsColors colors, ZsMetrics metrics) {
    final bool inactive = ZsAppearance.maybeOf(context)?.inactive ?? false;
    final Widget? titleText = titleHidden
        ? null
        : IgnorePointer(
            child: Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: _titleStyle.copyWith(color: inactive ? colors.textDim : colors.text),
              ),
            ),
          );
    final Widget row = switch (align) {
      ZsWindowHeaderAlign.start => Row(
        spacing: 12,
        children: <Widget>[
          Expanded(
            child: Align(alignment: AlignmentDirectional.centerStart, child: titleText ?? const SizedBox.shrink()),
          ),
          ...header,
        ],
      ),
      ZsWindowHeaderAlign.center => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 12,
        children: <Widget>[
          if (titleText != null) Flexible(child: titleText),
          ...header,
        ],
      ),
    };
    final EdgeInsetsDirectional inset = switch (align) {
      // `.zs-win-hd.is-center{padding-left:var(--chrome-first-x);padding-right:var(--chrome-first-x)}` (window.css:34).
      ZsWindowHeaderAlign.center => EdgeInsetsDirectional.symmetric(horizontal: metrics.chromeFirstX),
      // `.zs-win.has-side .zs-win-hd{padding-left:var(--chrome-inset)}` (window.css:42).
      ZsWindowHeaderAlign.start when sidebar != null => EdgeInsetsDirectional.symmetric(
        horizontal: metrics.chromeInset,
      ),
      // `padding:0 var(--chrome-inset) 0 var(--chrome-first-x)` (window.css:27).
      ZsWindowHeaderAlign.start => EdgeInsetsDirectional.only(start: metrics.chromeFirstX, end: metrics.chromeInset),
    };
    // The row centres its items in what the padding leaves; twice the block line's offset from the header's middle,
    // on one side, puts that centre on `--tl-mid-y` (window.css:29).
    final double shift = metrics.tlMidY - metrics.windowHdH / 2;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.flBorder)),
      ),
      child: SizedBox(
        height: metrics.windowHdH,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const WindowDragArea(child: ColoredBox(color: Color(0x00000000))),
            Padding(
              padding: inset.add(EdgeInsets.only(top: shift > 0 ? shift * 2 : 0, bottom: shift < 0 ? -shift * 2 : 0)),
              child: row,
            ),
          ],
        ),
      ),
    );
  }
}
