// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'sync_model.dart';

/// The top bar's ACTION sync island (Story 10.12, Story 11.8; DS ui_kits/desktop/chrome.jsx:101-104): Reload, then
/// Fetch and Push as the 11.11 icon buttons at the bar size.
///
/// - **Reload** (⌘R): [onReload] reads the project and the graph again; null disables it.
/// - **Fetch** has no shortcut; its tooltip is "Fetch from ‹remotes›" over `jj git fetch`, one line per remote naming
///   the bookmarks the poll found changed, or "Fetching… N%" while it runs (busy). The badge counts them.
/// - **Push…** opens the Push sheet; its tooltip names the default push remotes over `jj git push`.
/// - Both are disabled without [sync], without a remote ("No remote") and while the working copy is stale ("Working
///   copy is stale").
class SyncIsland extends StatelessWidget {
  /// The island of [sync] with Reload running [onReload].
  const SyncIsland({required this.onReload, this.sync, super.key});

  /// Reload; null while nothing can reload.
  final VoidCallback? onReload;

  /// The open repository's sync; null without one.
  final SyncModel? sync;

  @override
  Widget build(BuildContext context) {
    final SyncModel? sync = this.sync;
    return ZsIsland(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ZsTooltip(
            message: context.l10n.graphReloadTooltip,
            child: ZsButton(
              label: context.l10n.menuReload,
              variant: ZsButtonVariant.ghost,
              onPressed: onReload,
              identifier: 'graph.reload',
            ),
          ),
          if (sync == null) ...<Widget>[
            ZsIconButton(icon: ZI.fetch, label: context.l10n.menuFetch, identifier: 'sync-fetch'),
            ZsIconButton(icon: ZI.push, label: context.l10n.menuPush, identifier: 'sync-push'),
          ] else
            ListenableBuilder(
              listenable: sync,
              builder: (context, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[_fetch(context, sync), _push(context, sync)],
              ),
            ),
        ],
      ),
    );
  }

  static String? _disabledReason(AppLocalizations strings, SyncModel sync, {required bool hasRemote}) =>
      sync.stale ? strings.staleTitle : (hasRemote ? null : strings.syncNoRemote);

  Widget _fetch(BuildContext context, SyncModel sync) {
    final AppLocalizations strings = context.l10n;
    final double? progress = sync.fetchProgress;
    final String message;
    if (sync.fetching) {
      message = progress == null ? strings.syncFetching : strings.syncFetchingPercent((progress * 100).round());
    } else {
      message = <String>[
        strings.syncFetchTooltip(sync.fetchRemotes.join(', ')),
        for (final MapEntry<String, List<String>> entry in sync.remoteChanges.entries)
          strings.syncFetchChanged(entry.value.join(', '), entry.key),
      ].join('\n');
    }
    return ZsTooltip(
      message: message,
      cmd: 'jj git fetch', // l10n-ignore: jj command
      child: ZsIconButton(
        icon: ZI.fetch,
        label: strings.menuFetch,
        tooltip: false,
        badge: sync.badge,
        busy: sync.fetching,
        onPressed: sync.canFetch || sync.fetching ? () => unawaited(sync.fetch()) : null,
        disabledReason: _disabledReason(strings, sync, hasRemote: sync.fetchRemotes.isNotEmpty),
        identifier: 'sync-fetch',
      ),
    );
  }

  Widget _push(BuildContext context, SyncModel sync) {
    final AppLocalizations strings = context.l10n;
    return ZsTooltip(
      message: strings.syncPushTooltip(sync.pushRemotes.join(', ')),
      cmd: 'jj git push', // l10n-ignore: jj command
      child: ZsIconButton(
        icon: ZI.push,
        label: strings.menuPush,
        tooltip: false,
        active: sync.pushSheet != null,
        onPressed: sync.canPush ? sync.openPush : null,
        disabledReason: _disabledReason(strings, sync, hasRemote: sync.hasRemote),
        identifier: 'sync-push',
      ),
    );
  }
}
