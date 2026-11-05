// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart' show ZanshinWarning, ZanshinWarningCode;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../graph/graph_ports.dart' show jjCommand;
import '../projects/project_session.dart' show ProjectOpenReport;
import '../shell/shell_toast.dart';

/// The project window's "Opened ‹name›" toast for [report] (Story 10.23, I2; Story 11.22): each warning as a warn
/// clause, every line in the tooltip; with remote bookmarks the conversion left untracked, the CLI's post-`jj git init`
/// hint and a Track / Track all action ([onTrack]) for its one `jj bookmark track` command.
ZsToast openReportToast(
  BuildContext context,
  ProjectOpenReport report, {
  required VoidCallback onTrack,
  required VoidCallback onDismiss,
}) {
  final AppLocalizations strings = context.l10n;
  final ZsColors colors = ZsColors.of(context);
  final List<String> untracked = report.trackableRemoteBookmarks;
  final String track = jjCommand(<String>['bookmark', 'track', ...untracked]); // l10n-ignore: jj command
  // The CLI prints the hint after the conversion's other warnings and before the linked-worktree one (`init.rs:285`).
  bool afterHint(ZanshinWarning w) => w.code == ZanshinWarningCode.colocatedInGitWorktree;
  final InlineSpan opened = toastWithWarnings(
    colors,
    toastSpan(strings.toastOpened(toastSlot(0)), <InlineSpan>[TextSpan(text: report.name)]),
    report.warnings,
  );
  return ZsToast(
    tone: untracked.isEmpty ? ZsToastTone.success : ZsToastTone.warn,
    message: untracked.isEmpty
        ? opened
        : TextSpan(
            children: <InlineSpan>[
              opened,
              const TextSpan(text: ' · '), // l10n-ignore: separator
              if (untracked.length == 1)
                toastSpan(strings.toastOpenedUntrackedOne(toastSlot(0)), <InlineSpan>[
                  toastMono(colors, untracked.single),
                ])
              else
                TextSpan(text: strings.toastOpenedUntrackedMany(untracked.length)),
            ],
          ),
    tooltip: <String>[
      for (final ZanshinWarning w in report.warnings)
        if (!afterHint(w)) w.message,
      if (untracked.isNotEmpty) ...<String>[
        "Hint: The following remote bookmarks aren't associated with the existing local bookmarks:", // l10n-ignore: jj's text
        for (final String symbol in untracked) '  $symbol',
        'Hint: Run the following command to keep local bookmarks updated on future pulls:', // l10n-ignore: jj's text
        '  $track',
        strings.toastUntrackedHelp,
      ],
      for (final ZanshinWarning w in report.warnings)
        if (afterHint(w)) w.message,
    ].join('\n'),
    actions: <ZsToastAction>[
      if (untracked.isNotEmpty)
        ZsToastAction(
          label: untracked.length == 1 ? strings.toastTrack : strings.toastTrackAll,
          tooltip: track,
          identifier: 'project-toast-track',
          onPressed: onTrack,
        ),
    ],
    onDismiss: onDismiss,
    identifier: 'project-toast',
  );
}
