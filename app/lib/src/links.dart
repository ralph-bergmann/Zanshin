// SPDX-License-Identifier: MIT

import 'dart:io';

/// jj's documentation at the pinned jj-lib version.
final Uri jjDocumentationUrl = Uri.parse('https://docs.jj-vcs.dev/v0.46.0/'); // l10n-ignore: a URL

/// Opens [url] in the browser (Help › jj Documentation, the jj log Configurations window's Revset reference).
Future<void> openInBrowser(Uri url) async {
  // Detached: a non-detached Dart child lets the VM reap the cdylib's children (project-context.md § Dart).
  await Process.start('/usr/bin/open', <String>[url.toString()], mode: ProcessStartMode.detached);
}
