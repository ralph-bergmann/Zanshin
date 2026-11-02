// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';

import '../window/app_window_actions.dart';

/// A tab of the Settings window.
enum SettingsTab {
  /// For Zanshin on this Mac, and the user's jj config.
  general,

  /// For the open project only.
  project,
}

/// A page inside the Project tab.
enum SettingsPage {
  /// Immutable commits (`revset-aliases."immutable_heads()"`).
  immutableCommits,
}

/// Which tab and page the Settings window shows (Story 11.7), held by the window coordinator in memory, so the tab
/// survives a close (the page does not).
///
/// - The Project tab exists only while a project is open: without one it is disabled and General shows; a project
///   closing while Project shows switches to General.
/// - The page belongs to the Project tab: General hides it, Project shows it again.
class SettingsWindowState extends ChangeNotifier {
  SettingsTab _tab = SettingsTab.general;
  SettingsPage? _page;
  var _projectOpen = false;

  /// The tab shown.
  SettingsTab get tab => _tab;

  /// The page shown: the Project tab's page while Project shows, else none.
  SettingsPage? get page => _tab == SettingsTab.project ? _page : null;

  /// Whether a project is open (the Project tab is enabled).
  bool get projectOpen => _projectOpen;

  /// The open project changed: without one, General shows.
  set projectOpen(bool open) {
    if (open == _projectOpen) {
      return;
    }
    _projectOpen = open;
    if (!open) {
      _tab = SettingsTab.general;
      _page = null;
    }
    notifyListeners();
  }

  /// Switches to [tab] (the tabs); Project only while a project is open.
  void selectTab(SettingsTab tab) {
    if (tab == _tab || (tab == SettingsTab.project && !_projectOpen)) {
      return;
    }
    _tab = tab;
    notifyListeners();
  }

  /// Switches to [target] (an entry point naming one); without a project, General shows.
  void show(SettingsTarget target) {
    switch (target) {
      case SettingsTarget.general:
        _tab = SettingsTab.general;
      case SettingsTarget.project when _projectOpen:
        _tab = SettingsTab.project;
        _page = null;
      case SettingsTarget.immutableCommits when _projectOpen:
        _tab = SettingsTab.project;
        _page = SettingsPage.immutableCommits;
      case SettingsTarget.project || SettingsTarget.immutableCommits:
        _tab = SettingsTab.general;
    }
    notifyListeners();
  }

  /// Opens [page] in the Project tab.
  void openPage(SettingsPage page) {
    if (!_projectOpen) {
      return;
    }
    _tab = SettingsTab.project;
    _page = page;
    notifyListeners();
  }

  /// Back from the page to the Project tab.
  void closePage() {
    if (_page == null) {
      return;
    }
    _page = null;
    notifyListeners();
  }

  /// The window closed: the tab stays for the next opening, the page goes.
  void windowClosed() => closePage();
}
