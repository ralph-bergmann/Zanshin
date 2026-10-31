// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/l10n/app_localizations_en.dart';
import 'package:zanshin/src/features/projects/project_status_style.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

void main() {
  test('each status takes its --proj-* colour and the DS label (ProjectRow.jsx:5-15)', () {
    for (final colors in <ZsColors>[ZsColors.night, ZsColors.paper]) {
      expect(ProjectStatus.clean.colorIn(colors), colors.projClean);
      expect(ProjectStatus.dirty.colorIn(colors), colors.projDirty);
      expect(ProjectStatus.conflict.colorIn(colors), colors.projConflict);
      expect(ProjectStatus.missing.colorIn(colors), colors.projMissing);
      expect(ProjectStatus.stale.colorIn(colors), colors.projStale);
      expect(ProjectStatus.ahead.colorIn(colors), colors.projAhead);
      expect(ProjectStatus.behind.colorIn(colors), colors.projBehind);
      expect(ProjectStatus.diverged.colorIn(colors), colors.projDiverged);
    }
    expect(
      <String>[for (final ProjectStatus status in ProjectStatus.values) status.labelIn(AppLocalizationsEn())],
      <String>[
        'clean',
        'uncommitted changes',
        'conflict',
        'path missing',
        'working copy is stale',
        'ahead of remote',
        'behind remote',
        'diverged',
      ],
    );
  });
}
