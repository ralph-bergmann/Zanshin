// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// A [ProjectStatus] as the status dot shows it (DS components/content/ProjectRow.jsx:5-15): its `--proj-*` colour
/// and the label its tooltip and VoiceOver read.
extension ProjectStatusStyle on ProjectStatus {
  /// The dot's colour in [colors].
  Color colorIn(ZsColors colors) => switch (this) {
    ProjectStatus.clean => colors.projClean,
    ProjectStatus.dirty => colors.projDirty,
    ProjectStatus.conflict => colors.projConflict,
    ProjectStatus.missing => colors.projMissing,
    ProjectStatus.stale => colors.projStale,
  };

  /// The dot's label.
  String get label => switch (this) {
    ProjectStatus.clean => 'clean',
    ProjectStatus.dirty => 'uncommitted changes',
    ProjectStatus.conflict => 'conflict',
    ProjectStatus.missing => 'path missing',
    ProjectStatus.stale => 'working copy is stale',
  };
}
