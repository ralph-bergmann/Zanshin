// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:vector_graphics/vector_graphics.dart' show PictureInfo;

import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import 'icon_registry.dart';

/// One glyph of the design system's icon set (decisions 16.6, 16.32), painted from the boot-time [IconRegistry].
///
/// A leaf render box at one of the six size tokens: it paints the precompiled picture scaled from its 16-unit grid
/// to [size] inside a layer tinted with `ColorFilter.mode(colour, BlendMode.srcIn)`, synchronously, so no icon pops
/// in a frame late. The colour is [color], else the nearest [IconTheme]'s, else `--text`. Without a registry, or for
/// a name the registry does not hold, it paints nothing (an unknown name is also reported in debug builds).
///
/// The docked mock's call sites took the tokens by size — 10 → xs, 11 and 12 → sm, 13 and 14 → md, 16 → lg,
/// 17 → bar, 19 and up → rail — Claude's proposal (Story 11.1); 11.10 deletes them.
class ZanshinIcon extends LeafRenderObjectWidget {
  /// Paints the glyph [name] (a [ZI] constant) at [size].
  const ZanshinIcon(this.name, {required this.size, this.color, super.key});

  /// The glyph's name, a [ZI] constant.
  final String name;

  /// The icon size token.
  final ZsIconSize size;

  /// The tint; null takes the nearest [IconTheme]'s colour, else `--text`.
  final Color? color;

  @override
  RenderZanshinIcon createRenderObject(BuildContext context) =>
      RenderZanshinIcon(picture: _picture(context), side: size.size, color: _color(context));

  @override
  void updateRenderObject(BuildContext context, RenderZanshinIcon renderObject) {
    renderObject
      ..picture = _picture(context)
      ..side = size.size
      ..color = _color(context);
  }

  PictureInfo? _picture(BuildContext context) {
    final IconRegistry? registry = IconRegistryScope.maybeOf(context);
    final PictureInfo? picture = registry?[name];
    // Reported rather than thrown, so the icon still lays out and paints nothing.
    assert(() {
      if (registry != null && picture == null) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: FlutterError('ZanshinIcon: no glyph named "$name" in the icon registry.'),
            library: 'zanshin',
          ),
        );
      }
      return true;
    }());
    return picture;
  }

  Color _color(BuildContext context) =>
      color ?? context.dependOnInheritedWidgetOfExactType<IconTheme>()?.data.color ?? ZsColors.of(context).text;
}

/// The render box of a [ZanshinIcon].
class RenderZanshinIcon extends RenderBox {
  /// Creates the render box.
  RenderZanshinIcon({required this._picture, required this._side, required this._color});

  /// The DS draws every glyph on a 16-unit grid (DS readme.md:350).
  static const double _grid = 16;

  /// The picture painted, or null to paint nothing.
  PictureInfo? get picture => _picture;
  PictureInfo? _picture;
  set picture(PictureInfo? value) {
    if (identical(value, _picture)) {
      return;
    }
    _picture = value;
    markNeedsPaint();
  }

  /// The icon's side in logical pixels.
  double get side => _side;
  double _side;
  set side(double value) {
    if (value == _side) {
      return;
    }
    _side = value;
    markNeedsLayout();
  }

  /// The tint.
  Color get color => _color;
  Color _color;
  set color(Color value) {
    if (value == _color) {
      return;
    }
    _color = value;
    markNeedsPaint();
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(Size.square(_side));

  @override
  void performLayout() {
    size = computeDryLayout(constraints);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _side;

  @override
  double computeMaxIntrinsicWidth(double height) => _side;

  @override
  double computeMinIntrinsicHeight(double width) => _side;

  @override
  double computeMaxIntrinsicHeight(double width) => _side;

  @override
  void paint(PaintingContext context, Offset offset) {
    final PictureInfo? picture = _picture;
    if (picture == null) {
      return;
    }
    final double scale = _side / _grid;
    // A box forced larger than the token keeps the glyph at the token's size, centred.
    final Offset origin = offset + Offset((size.width - _side) / 2, (size.height - _side) / 2);
    context.canvas
      ..save()
      ..translate(origin.dx, origin.dy)
      ..saveLayer(Offset.zero & Size.square(_side), Paint()..colorFilter = ColorFilter.mode(_color, BlendMode.srcIn))
      ..scale(scale, scale)
      ..drawPicture(picture.picture)
      ..restore()
      ..restore();
  }
}

/// The glyph names: one constant per file in `assets/icons/svg/`, camelCase for the DS's kebab-case names
/// (DS assets/icons/glyphs.json:2-62). The retired aliases (`:63-73`) have no constant.
abstract final class ZI {
  static const abandon = 'abandon';
  static const alert = 'alert';
  static const arrowUp = 'arrow-up';
  static const auto = 'auto';
  static const bookmark = 'bookmark';
  static const bookmarkFilled = 'bookmark-filled';
  static const branch = 'branch';
  static const calendar = 'calendar';
  static const change = 'change';
  static const check = 'check';
  static const chevronDown = 'chevron-down';
  static const chevronLeft = 'chevron-left';
  static const chevronRight = 'chevron-right';
  static const chevronUp = 'chevron-up';
  static const close = 'close';
  static const cloud = 'cloud';
  static const conflict = 'conflict';
  static const copy = 'copy';
  static const describe = 'describe';
  static const description = 'description';
  static const duplicate = 'duplicate';
  static const fetch = 'fetch';
  static const file = 'file';
  static const fileText = 'file-text';
  static const folder = 'folder';
  static const folderOpen = 'folder-open';
  static const folderPlus = 'folder-plus';
  static const grip = 'grip';
  static const hash = 'hash';
  static const history = 'history';
  static const home = 'home';
  static const insertAfter = 'insert-after';
  static const insertBefore = 'insert-before';
  static const merge = 'merge';
  static const mergeNew = 'merge-new';
  static const minus = 'minus';
  static const moon = 'moon';
  static const more = 'more';
  static const moveOnly = 'move-only';
  static const moveOnto = 'move-onto';
  static const newOnTop = 'new-on-top';
  static const plus = 'plus';
  static const pull = 'pull';
  static const push = 'push';
  static const revert = 'revert';
  static const reviews = 'reviews';
  static const search = 'search';
  static const settings = 'settings';
  static const splitInline = 'split-inline';
  static const splitSide = 'split-side';
  static const squash = 'squash';
  static const squashInto = 'squash-into';
  static const stackCollapse = 'stack-collapse';
  static const sun = 'sun';
  static const undo = 'undo';
  static const updown = 'updown';
  static const user = 'user';
  static const viewOptions = 'view-options';
  static const workingCopyAt = 'working-copy-at';

  /// Not a DS glyph (workstreams are dropped, decision 16.26): the one named leftover of the mock, kept until 11.10
  /// deletes it with its users.
  static const workstream = 'workstream';

  /// Every glyph the registry loads.
  static const all = <String>[
    abandon,
    alert,
    arrowUp,
    auto,
    bookmark,
    bookmarkFilled,
    branch,
    calendar,
    change,
    check,
    chevronDown,
    chevronLeft,
    chevronRight,
    chevronUp,
    close,
    cloud,
    conflict,
    copy,
    describe,
    description,
    duplicate,
    fetch,
    file,
    fileText,
    folder,
    folderOpen,
    folderPlus,
    grip,
    hash,
    history,
    home,
    insertAfter,
    insertBefore,
    merge,
    mergeNew,
    minus,
    moon,
    more,
    moveOnly,
    moveOnto,
    newOnTop,
    plus,
    pull,
    push,
    revert,
    reviews,
    search,
    settings,
    splitInline,
    splitSide,
    squash,
    squashInto,
    stackCollapse,
    sun,
    undo,
    updown,
    user,
    viewOptions,
    workingCopyAt,
    workstream,
  ];
}
