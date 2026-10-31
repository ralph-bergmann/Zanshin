// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';

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
    ProjectStatus.ahead => colors.projAhead,
    ProjectStatus.behind => colors.projBehind,
    ProjectStatus.diverged => colors.projDiverged,
  };

  /// The dot's label in [strings].
  String labelIn(AppLocalizations strings) => switch (this) {
    ProjectStatus.clean => strings.statusClean,
    ProjectStatus.dirty => strings.statusDirty,
    ProjectStatus.conflict => strings.statusConflict,
    ProjectStatus.missing => strings.statusMissing,
    ProjectStatus.stale => strings.statusStale,
    ProjectStatus.ahead => strings.statusAhead,
    ProjectStatus.behind => strings.statusBehind,
    ProjectStatus.diverged => strings.statusDiverged,
  };
}
