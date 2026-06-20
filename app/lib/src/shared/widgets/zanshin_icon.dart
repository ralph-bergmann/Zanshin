// SPDX-License-Identifier: MIT

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

// SVG-based icon widget. Uses assets/icons/svg/<name>.svg.
// Replace with Icon(ZanshinIcons.xxx) once the icon font is generated.
class ZanshinIcon extends StatelessWidget {
  const ZanshinIcon(this.name, {super.key, this.size = 16.0, this.color});

  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color effectiveColor =
        color ?? IconTheme.of(context).color ?? Theme.of(context).iconTheme.color ?? Colors.white;
    return SvgPicture.asset(
      'assets/icons/svg/$name.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(effectiveColor, BlendMode.srcIn),
    );
  }
}

// Icon name constants matching the svg file names.
abstract final class ZI {
  static const folder = 'folder';
  static const branch = 'branch';
  static const workstream = 'workstream';
  static const reviews = 'reviews';
  static const history = 'history';
  static const undo = 'undo';
  static const chevronDown = 'chevron_down';
  static const chevronRight = 'chevron_right';
  static const plus = 'plus';
  static const settings = 'settings';
  static const close = 'close';
  static const user = 'user';
  static const calendar = 'calendar';
  static const hash = 'hash';
  static const arrowLeft = 'arrow_left';
  static const file = 'file';
  static const fileText = 'file_text';
  static const merge = 'merge';
  static const conflict = 'conflict';
  static const splitInline = 'split_inline';
  static const splitSide = 'split_side';
  static const sun = 'sun';
  static const moon = 'moon';
  static const auto = 'auto';
  static const fetch = 'fetch';
  static const push = 'push';
  static const pull = 'pull';
  static const grip = 'grip';
  static const home = 'home';
  static const search = 'search';
  static const cloud = 'cloud';
  static const folderOpen = 'folder_open';
  static const folderPlus = 'folder_plus';
  static const more = 'more';
  static const download = 'download';
  static const edit = 'edit';
  static const check = 'check';
}
