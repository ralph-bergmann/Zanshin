// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:inject_annotation/inject_annotation.dart';

/// Edit › Find while Projects is key (Story 11.13): the Projects content registers how it focuses its search while it
/// is mounted, and the menu bar runs that.
@inject
@singleton
class ProjectsSearchFocus {
  final _registered = <VoidCallback>[];

  /// Focuses the search of the Projects content mounted last; null while no Projects content is mounted.
  VoidCallback? get focus => _registered.lastOrNull;

  /// Registers [focus] as a mounted content's.
  void register(VoidCallback focus) => _registered.add(focus);

  /// Drops [focus]; another content's registration stays.
  void unregister(VoidCallback focus) => _registered.remove(focus);
}
