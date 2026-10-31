// SPDX-License-Identifier: MIT

import '../../l10n/strings.dart';

/// When a project was last opened, as the Projects tree's second line shows it in [strings] (Story 11.6; Claude's
/// proposal; the floating export's "now" and "2h ago", design/data.js:305-338): under a minute "now", under an hour
/// "‹n›m ago", under a day "‹n›h ago", the calendar day before [now] "yesterday", then "‹n›d ago" under a week, "‹n›w
/// ago" under 30 days, "‹n›mo ago" under 365 days and "‹n›y ago" beyond. A time after [now] reads "now". Both are
/// compared in local time.
String lastOpenedLabel(AppLocalizations strings, DateTime at, DateTime now) {
  final DateTime local = at.toLocal();
  final DateTime today = now.toLocal();
  final Duration ago = today.difference(local);
  if (ago < const Duration(minutes: 1)) {
    return strings.lastOpenedNow;
  }
  if (ago < const Duration(hours: 1)) {
    return strings.lastOpenedMinutes(ago.inMinutes);
  }
  if (ago < const Duration(days: 1)) {
    return strings.lastOpenedHours(ago.inHours);
  }
  final yesterday = DateTime(today.year, today.month, today.day - 1);
  if (local.year == yesterday.year && local.month == yesterday.month && local.day == yesterday.day) {
    return strings.lastOpenedYesterday;
  }
  final int days = ago.inDays;
  if (days < 7) {
    return strings.lastOpenedDays(days);
  }
  if (days < 30) {
    return strings.lastOpenedWeeks(days ~/ 7);
  }
  if (days < 365) {
    return strings.lastOpenedMonths(days ~/ 30);
  }
  return strings.lastOpenedYears(days ~/ 365);
}

/// [path] for display: the [home] folder at its start abbreviated to `~` (Claude's proposal; DS
/// components/content/ProjectRow.prompt.md:5 shows `~/code/work/mobile/myapp`).
String displayPath(String path, String home) {
  final String base = home.endsWith('/') && home.length > 1 ? home.substring(0, home.length - 1) : home;
  if (base.isEmpty || base == '/') {
    return path;
  }
  if (path == base) {
    return '~';
  }
  return path.startsWith('$base/') ? '~${path.substring(base.length)}' : path;
}
