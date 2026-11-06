// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../window/app_window_actions.dart';

/// A tab of the Settings window.
enum SettingsTab {
  /// For Zanshin on this Mac, and the user's jj config.
  general,

  /// For the open project only.
  project,
}

/// A page inside a tab.
enum SettingsPage {
  /// Immutable commits (`revset-aliases."immutable_heads()"`), in the Project tab.
  immutableCommits,

  /// The tab's config file as text (`jj config edit`, Story 11.19), in either tab.
  configFile,
}

/// Which tab and page the Settings window shows (Stories 11.7, 11.19), held by the window coordinator in memory, so
/// the tab survives a close (the pages do not).
///
/// - The Project tab exists only while a project is open: without one it is disabled and General shows; a project
///   closing while Project shows switches to General.
/// - Each tab keeps its own page. Immutable commits stays with the Project tab: General hides it, Project shows it
///   again. A config page closes when it is left (its draft lives in the page), so coming back shows the tab.
/// - Leaving a config page with edits ([editing]) — back, the other tab, an entry point that switches — asks
///   [confirmDiscard] first and only goes on when it answers true.
class SettingsWindowState extends ChangeNotifier {
  SettingsTab _tab = SettingsTab.general;
  final _pages = <SettingsTab, SettingsPage>{};
  var _projectOpen = false;

  /// Whether the shown config page holds edits; the page reports it.
  var editing = false;

  /// Asks whether the shown config page's edits may go (the window's Discard sheet); true lets them go. Null while no
  /// window shows the state.
  Future<bool> Function()? confirmDiscard;

  /// The tab shown.
  SettingsTab get tab => _tab;

  /// The page shown in the shown tab, or none.
  SettingsPage? get page => _pages[_tab];

  /// Whether a project is open (the Project tab is enabled).
  bool get projectOpen => _projectOpen;

  /// Whether leaving the shown page asks first: a config page with edits.
  bool get asksBeforeLeaving => page == SettingsPage.configFile && editing && confirmDiscard != null;

  /// Whether the shown page may be left: true at once without edits, else [confirmDiscard]'s answer.
  Future<bool> mayLeave() async {
    final Future<bool> Function()? confirm = confirmDiscard;
    if (!asksBeforeLeaving || confirm == null) {
      return true;
    }
    return confirm();
  }

  /// The open project changed: without one, General shows.
  set projectOpen(bool open) {
    if (open == _projectOpen) {
      return;
    }
    _projectOpen = open;
    if (!open) {
      if (_tab == SettingsTab.project) {
        editing = false;
      }
      _tab = SettingsTab.general;
      _pages.remove(SettingsTab.project);
    }
    notifyListeners();
  }

  /// Switches to [tab] (the tabs); Project only while a project is open.
  void selectTab(SettingsTab tab) {
    if (tab == _tab || (tab == SettingsTab.project && !_projectOpen)) {
      return;
    }
    _leave(() => _go(tab, _pages[tab]));
  }

  /// Switches to [target] (an entry point naming one); without a project, General shows.
  void show(SettingsTarget target) {
    final (SettingsTab tab, SettingsPage? page) = switch (target) {
      SettingsTarget.project when _projectOpen => (SettingsTab.project, null),
      SettingsTarget.immutableCommits when _projectOpen => (SettingsTab.project, SettingsPage.immutableCommits),
      _ => (SettingsTab.general, _pages[SettingsTab.general]),
    };
    if (tab == _tab && page == this.page) {
      notifyListeners();
      return;
    }
    _leave(() => _go(tab, page));
  }

  /// Opens [page]: a config page in the shown tab, Immutable commits in the Project tab.
  void openPage(SettingsPage page) {
    switch (page) {
      case SettingsPage.immutableCommits when _projectOpen:
        _go(SettingsTab.project, page);
      case SettingsPage.configFile:
        editing = false;
        _go(_tab, page);
      case SettingsPage.immutableCommits:
        break;
    }
  }

  /// Back from the page to its tab.
  void closePage() {
    if (page == null) {
      return;
    }
    _leave(() => _go(_tab, null));
  }

  /// The window closed (it asked first): the tab stays for the next opening, the pages go.
  void windowClosed() {
    _pages.clear();
    editing = false;
    notifyListeners();
  }

  /// Runs [change] now, or — leaving a config page with edits — once [confirmDiscard] let the edits go.
  void _leave(VoidCallback change) {
    if (!asksBeforeLeaving) {
      change();
      return;
    }
    unawaited(
      mayLeave().then((leave) {
        if (leave) {
          change();
        }
      }),
    );
  }

  /// Shows [tab] with [page]; a config page that is left closes.
  void _go(SettingsTab tab, SettingsPage? page) {
    if (this.page == SettingsPage.configFile && (tab != _tab || page != SettingsPage.configFile)) {
      _pages.remove(_tab);
      editing = false;
    }
    _tab = tab;
    if (page == null) {
      _pages.remove(tab);
    } else {
      _pages[tab] = page;
    }
    notifyListeners();
  }
}
