---
title: 'Story 11.7 — Settings window: General and Project tabs over app preferences and jj config'
type: 'feature'
created: '2026-11-02'
status: 'done'
baseline_revision: 'a66b46a8b7cebddff3d79ee56db0f18f67569237'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      A list- or pattern-valued git.fetch / git.push shows read-only, without design question (b)'s "Edit…".
    evidence: |-
      project_tab.dart shows the TOML text when the value is not one remote name; the witness only asks for read-only text, the Edit… was a recommendation.
    location: >-
      app/lib/src/features/settings/project_tab.dart (_remoteRow)
    severity: low
  - summary: >-
      The Immutable commits page shows no heads list under the count, and the built-in switches' hints do not name this repository's tags or untracked remote bookmarks.
    evidence: |-
      No read lists the heads or the matching tags/bookmarks per built-in (design/immutable.jsx:76-92, ImmutablePage.prompt.md); the hints use fixed text.
    location: >-
      app/lib/src/features/settings/immutable_page.dart
    severity: low
    resolved: >-
      2026-11-03 — fixed (spec-11-7-closing-immutable-names-and-nami-segment, commit c527fb1): the built-in hints name this repository's tags and remote refs (≤5, then "n more") via SettingsRepoReads.revsetMembers, and a mono line under the count lists immutable_heads().
  - summary: >-
      The Project tab segment shows a folder icon instead of the Nami mark beside the project name.
    evidence: |-
      ZsSegment.icon takes an icon name only (packages/zanshin_ui zs_segmented.dart:25); the Nami mark is a widget (ZsNamiMark).
    location: >-
      app/lib/src/features/settings/settings_window.dart
    severity: low
    resolved: >-
      2026-11-03 — fixed (spec-11-7-closing-immutable-names-and-nami-segment, commit c527fb1): ZsSegment gained a leading widget slot; the Project segment shows ZsNamiMark(size: 14).
  - summary: >-
      The running-app checks were not made: the Marionette comparison with the DS settings cards and the window behaviour (top edge kept, normal level, Esc does nothing, ⌘W and the red button) on screen.
    evidence: |-
      The unattended run allows only synchronous commands, so the catalogue was not launched; all witnesses run over fake windows in flutter test.
    location: >-
      app/widgetbook/folders/windows.dart (Settings window use case)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Zanshin has no Settings window. ⌘,, Settings… (app menu, capsule, Projects sidebar), Project Settings…, Set identity…, View options' "Appearance, diffs and more" and the card menu's Immutable commits… are all disabled; the theme, accent, hide-controls and diff-layout preferences have no UI; jj config (identity, remotes, trunk, immutable heads) can only be changed with the CLI; and the graph's IMMUTABLE eyebrow and flag show no reason. epics.md Story 11.7 (with its 2026-10-16 and 2026-10-26 design updates) plus deferred-work items I1–I10 of the dispatch.

**Approach:** A parentless, content-sized dialog window under `settingsWindowKey` (620 wide, height follows the tab up to 740, not resizable, origin-only frame), opened through `AppWindowCoordinator.openSettings(...)` on the tab shown last; a window-agnostic `SettingsWindow` content with a General and a Project tab built from new `SettingsGroup`/`SettingsRow`/`SettingsPage` widgets over 11.11's Zs controls; preferences write `SettingsStore`, jj rows read and write through 9.28's config verbs via the existing `ProjectsEnvironment` port, extended; the Immutable commits page writes `revset-aliases."immutable_heads()"` at repo scope; a cached immutable-reason producer feeds the peek and the inspector.

## Boundaries & Constraints

**Always:**
- Window: `settingsWindowSpec = DialogWindowSpec(constraints: BoxConstraints(maxWidth: 620, maxHeight: 740), resizable: false, frame: WindowFrameMode.position)` (I6; no minimum). The content is a column stretched to 620. `ZanshinWindowRoot` gains `sizeToContent` (I5): with it, the window's child sits under `MaterialApp(builder:)` in `Overlay.wrap(alwaysSizeToContent: true, …)` with no `home:`/Navigator, exactly like `catalogueAppBuilder(sizeToContent: true)`.
- Opening: `AppWindowActions` gains `Future<void> openSettings({SettingsTarget? target})`; `SettingsTarget` = `general` | `project` | `immutableCommits`. `null` (⌘,, every "Settings…" row) opens or activates on the tab shown last and never switches tab or page; a target switches to it (`immutableCommits` = Project tab with the page). With no open project, Project resolves to General. Every route goes through `AppWindows.openOrActivate`. Esc does nothing; ⌘W and the red button close. Minimise/zoom stay grey (11.13 already greys them for `settingsWindowKey`).
- Tab state (tab + open page) lives in a `SettingsWindowState` held by the coordinator (in memory, not persisted): the tab survives a close; the page is dropped on close; General hides the page and Project shows it again; a project close while Project shows switches to General; Project is disabled with `disabledReason` "Open a project first" while no project is open.
- Window title: "General", the project's name, or "Immutable commits" on the page — set through the windowing `setTitle` (extend the `ProjectWindowTitle` mechanism to `DialogWindowController`, which also has `setTitle`).
- Header: `ZsWindowScaffold(titleHidden: true, align: centre)` with the tabs `ZsSegmented(variant: tabs)` `[⚙ General | Nami + project name]`; scope line "For Zanshin on this Mac · jj settings go to <path>" / "For <name> only · <path>", both paths from `configPath(ConfigScope.user|repo)`; footer "How the graph looks lives with the graph: **View options** in the toolbar."
- Rows: label 13, optional hint, the config key in mono under the label (DS `components/settings/settings.css`); control right, or below (`stack`) for long text. Groups: sentence-case headings rendered caps, `--fl-hover` box radius 12, 18 apart; `SettingsGroup` has `meta` and `bare`; `SettingsRow` has `onOpen` (navigation row: whole row one button, ↩/Space open, value + ›). Each control carries `Semantics(identifier:)` (`settings-*`), the window root a key `settings-window` for Marionette.
- General tab: Appearance › Theme (Paper · Night · Auto → `ZanshinAppViewModel.setThemeMode`, I2), Density (Compact · Balanced · Comfy, new pref), Accent colour (Follow macOS · Zanshin → `appearance.accentSource`, with the DS hint); While you scroll › Hide controls (`general.hideControls`); Diffs › Layout (Unified · Side by side → `general.diffLayout`, I10); Identity › Name `user.name`, Email `user.email` at user scope.
- Project tab: Remotes › Fetch from `git.fetch`, Push to `git.push` (select of `remotes()` names while the value is one remote name or unset — unset shows the CLI's resolved default from `gitFetchRemotes()`/`gitPushRemotes()`; any list or pattern value shows read-only as its TOML text), Check for remote changes (Off · 5 min · 15 min, per-project pref, default 15); History › Trunk `revset-aliases."trunk()"` (select of the default fetch remote's bookmarks written as `<name>@<remote>`, plus Custom… → a mono stack field), Immutable commits (navigation row: summary hint, key, `HatchSwatch` + count, ›); Identity › "Use a different email here" (on = `user.email` exists at repo scope; on writes the current effective email there, off unsets it) and its Email field while on.
- Effective values: every jj row shows the effective value (`configList(name:, workspaceRoot:)`, the last non-overridden entry) and, when its source is another scope than the tab's, "From <scope> config" as hint. Writes go to the tab's scope only (`ConfigScopeTarget`).
- Text fields write on ↩ or blur **only when the value differs from the last value read or written** (I1); the close handler (`AppWindows.setCloseHandler(settingsWindowKey, …)`) flushes a pending valid field before destroying the window and drops an invalid one.
- After an identity write (user or repo), show 9.28's working-copy-author fact when `ConfigSetResult.workingCopyAuthor` is non-null ("@ keeps the author <name> <email>. `jj metaedit --update-author` changes it.", the command verbatim), and notify `ProjectsEnvironment.configWrites` so the Projects window's identity footer re-reads (I4).
- Graph follows: a write or unset of `revset-aliases."trunk()"`, `revset-aliases."immutable_heads()"` or `revsets.log` calls `GraphViewModel.configChanged()` exactly once through `AppMenuModel.graph.value?.model`.
- Immutable commits page per epics.md 11.7's 2026-10-26 note (DS `components/settings/ImmutablePage.prompt.md`, `design/immutable.jsx:113-169`): Built in (4 switches; all on = `builtin_immutable_heads()`, else the chosen calls), Also immutable (Other people's changes `(trunk().. & ~mine())`; bookmark chips written as `present(<name>)`; custom revset field, written on ↩/blur only once `revsetCounts(cap: 0)` resolves it, else the field's error state and no write), Result well with the TOML exactly as written, `HatchSwatch` + "**N** changes are immutable" (`revsetCounts(['::immutable_heads() ~ root()'], cap: 10000)`, "10,000+" when capped, recounted after each write; heads in mono), the root note and Reset to jj's default (`configUnset` repo scope; shown only while the set differs). Opening maps the effective alias's top-level `|` terms onto the controls (built-ins, `present(x)`/bare bookmark names → chips, `(trunk().. & ~mine())` → switch, rest → custom in order); a write keeps the order built-ins, chips, others, custom. Back "‹ <project name>" (read "Back to <name>"), ⌘[ goes back, Tab starts at it. Counts use the head operation id (`handle.opLog(limit: 1)`).
- Immutable reason (I7, I8): `ImmutableReasons` — reads `immutable_heads()` once per operation, splits its top-level terms (expanding `builtin_immutable_heads()` to `trunk()`, `tags()`, `untracked_remote_bookmarks()`, `untracked_remote_tags()`, the CLI's v0.46.0 definition), and for a commit asks `revsetCounts(op, ['<commitId> & ::(<term>)' …], cap: 1)`; the first term with `n > 0` is the reason (verbatim term, jj's text). Cached per (operation, commit). Provided by an `ImmutableReasonScope` above the graph in `ProjectGraphHost`; the peek shows "IMMUTABLE · <term>" and the inspector flag tooltip "Immutable · <term>"; without a scope or before the answer they show today's text.
- Entry points (I3, I9): app menu Settings… ⌘, and the File menu's Project Settings… (target project); the capsule's Project Settings… and Settings…; the Projects sidebar Settings… and the footer's Set identity… (target general); View options' "Appearance, diffs and more" (target general); the card menu's Immutable commits… (target immutableCommits) — all from `AppWindowActionsScope.maybeOf(context)` (null → disabled, as today).
- New prefs as defaulted Freezed fields, no migration: `AppearanceSettings.density` (`enum DensitySetting { compact, balanced, comfy }`, default compact, `unknownEnumValue: compact`); `ProjectEntry.remotePoll` (`enum RemotePollSetting { off, fiveMinutes, fifteenMinutes }`, default fifteenMinutes, `unknownEnumValue`). Density is applied in `ZanshinWindowRoot` as a linear `TextScaler` of 1.0 / 13⁄12.5 / 13.5⁄12.5 (Claude's proposal: the prototype's 12.5:13:13.5 ratio, with Compact = today's DS sizes so the default look does not change).
- Bridge: export `Remote` from `packages/zanshin_core/lib/zanshin_core.dart` (item 8).
- All user-facing strings in `app/lib/l10n/app_en.arb` (run `flutter gen-l10n`, commit generated files); config keys, revset terms, paths and jj commands carry `// l10n-ignore: <reason>` where a checked argument holds them. Remove `cardMenuSettingsLater` once unused.
- A Widgetbook "Windows" use case "Settings window" opens the real window through `CatalogueWindows` with fake ports (content-sized scaffold path).

**Never:** a raw config editor or key catalogue (`configFileRead`/`configFileWrite` stay unused); managing remotes; a write of an unchanged value; a write to a scope other than the tab's; a Navigator inside the Settings window; a minimum constraint on the Settings spec; Material/Yaru controls; any test calling a real jj config verb (fake ports only); the full quality gate in this run (targeted checks only, per the dispatch's gate rule); an "Edit…" for list-valued `git.fetch`/`git.push` (deferred).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| ⌘, first | no Settings window, last tab Project, project open | window opens on Project | — |
| ⌘, again | Settings open on a page | window activated, tab and page unchanged | — |
| No project | last tab Project, no project | opens on General; Project disabled "Open a project first" | — |
| Project closes | Project tab shown | switches to General, Project disabled | — |
| Name unchanged | field blurred by a window switch, text = last value | no `configSet` | — |
| Name edited | ↩ with new text | one `configSet(ConfigScopeTarget(user), 'user.name', text)`; author fact shown when returned; `configWrites` fires | `ZanshinFfiException` → field error, value kept |
| Pending field on close | edited Immutable custom field, valid | written before the window is destroyed | invalid → dropped, window closes |
| Trunk pick | `main` of remote `origin` | `configSet(repo, 'revset-aliases."trunk()"', 'main@origin')`, one `configChanged()` | error → row error |
| List `git.fetch` | effective `["origin", "upstream"]` | read-only mono TOML text, no select | — |
| Unset `git.fetch` | no value | select shows the CLI default remote | — |
| Immutable all built-ins | 4 switches on | writes `builtin_immutable_heads()` | — |
| Tags off | other 3 on | writes `trunk() \| untracked_remote_bookmarks() \| untracked_remote_tags()` | — |
| Chip + switch | chip `develop`, Other people's on | writes `… \| present(develop) \| (trunk().. & ~mine())` | — |
| Bad custom | fake `revsetCounts` returns an error | field error state, no write | — |
| Reset | set differs | `configUnset(ConfigScopeTarget(repo), 'revset-aliases."immutable_heads()"')` | — |
| Alias mapping | `builtin_immutable_heads() \| present(develop) \| heads(foo)` | 4 switches on, chip develop, custom `heads(foo)` | — |
| Count capped | > 10,000 | "10,000+" | count error → no count shown |
| Reason | commit below trunk only | peek "IMMUTABLE · trunk()" | reason read fails → plain IMMUTABLE |

</intent-contract>

## Code Map

All app paths relative to `app/`.
- `lib/src/features/window/app_windows.dart` -- `settingsWindowKey` (:31) exists; add `settingsWindowSpec` next to `projectsWindowSpec` (:91); `create` refuses a min on a content-sized spec (:286); `setCloseHandler`, `openOrActivate` (:333).
- `lib/src/features/window/app_window_actions.dart` -- interface `{openProjects, openRevsetConfigs}` + `AppWindowActionsScope.maybeOf`; add `openSettings({SettingsTarget? target})`.
- `lib/src/features/window/app_window_coordinator.dart` -- `AppWindowCoordinator` (:51/:55 ctor), `openRevsetConfigs` (:121) is the pattern; `_show(key,title,build,{dialog})` (:249) builds content once; `_showProjectsInstead` (:256). Add `buildSettings` ctor param and own the `SettingsWindowState`.
- `lib/src/features/window/zanshin_window_root.dart` -- `@assistedInject` root, always `home:` today; add `sizeToContent` (I5) and the density `TextScaler`.
- `widgetbook/catalogue.dart:165` -- `catalogueAppBuilder(sizeToContent:)` (:192-194) is the reference for the switch.
- `widgetbook/folders/windows.dart` -- `windowsFolder` (:124), `_open` (:186, sets `sizeToContent` for size-less dialogs :202), `_OpenRevsetConfigsWindow` (:488) is the pattern; add "Settings window".
- `lib/main.dart` -- `appWindowCoordinator(component, windows)` (:153) builds windows from `MainComponent` getters (:180-213: `worker`, `projectSession`, `zanshinWindowRootFactory`, `appMenu`, `settings`, `projectsWindowFactory`); `_startApp` (:125). Add `buildSettings`.
- `lib/src/features/projects/project_window_title.dart` -- `setTitle` only for `WindowController` (:53); extend to dialog windows.
- `lib/src/features/projects/projects_environment.dart` -- `ProjectsEnvironment` (:18-38, `identity`), `DesktopProjectsEnvironment(Future<ZanshinWorker>)` (:77-113); extend with `configList`/`configSet`/`configUnset`/`configPath` wrappers and `Listenable configWrites`.
- `lib/src/features/projects/projects_window.dart` -- ctor `onSettings`/`onIdentitySettings` (:74-82, null from main); identity read `_readIdentity` (:299), re-read on key (:213-221); sidebar row (:814-822); footer `_IdentityFooter` (:1216). Listen to `configWrites`.
- `lib/src/features/projects/project_session.dart:133` -- `ProjectSession` (`current` name/path, `repo.handle`); Settings observes it.
- `lib/src/features/home/home_page.dart:132-144` -- `ProjectCapsule(... onAllProjects:)`; pass `onProjectSettings`/`onSettings`.
- `lib/src/features/projects/project_capsule.dart:36-62,139-162` -- nullable callbacks, identifiers `project-menu-project-settings`, `project-menu-settings`.
- `lib/src/features/shell/app_menu.dart` -- `_appMenu(s, onSettings:)` (:243-254) called with null (:232, :338); File menu Project Settings… (:350); `_run` (:178); `GraphMenuBinding.model` (:50); ⌘F while Settings key already activates the project window and focuses its search (:322-331) — item 10 holds, add a test only if none covers it.
- `lib/src/features/home/project_graph_host.dart` -- `GraphView` (:259), `GraphViewControls` without `onSettings` (:267), `RepoGraphSearchSource` wiring (:120-129); host `ImmutableReasonScope` here.
- `lib/src/features/graph/graph_controls.dart` -- `onSettings` → "Appearance, diffs and more" `ZsOptionLink` (:389-394); reads `AppWindowActionsScope` (:133) already.
- `lib/src/features/graph/graph_card_menu.dart` -- disabled Immutable commits… (:167-181, `cardMenuSettingsLater`); `graphCardMenuEntries` (:102), `GraphCardMenuHost` (:618/:651); add `onImmutableCommits`.
- `lib/src/features/graph/graph_peek.dart:151-161` -- IMMUTABLE eyebrow; `graph_inspector.dart:1225-1231` -- `_Flag` tooltip.
- `lib/src/features/graph/graph_ports.dart` -- `GraphSearchSource.revsetCounts` (:968), `RepoGraphSearchSource` (:995); `graph_view_model.dart` `configChanged()` (:638, no caller yet).
- `lib/src/features/graph/hatch_swatch.dart:34` -- `HatchSwatch({label})`, needs `GraphTheme` above it.
- `lib/src/features/app/zanshin_app_view_model.dart:82` -- `setThemeMode`; `appearance` (:55).
- `packages/zanshin_settings/lib/src/model/{appearance_settings,general_settings,projects_settings}.dart` -- Freezed + json; regenerate with `dart run build_runner build -d` in the package; `SettingsStore.update` (`settings_store.dart`).
- `packages/zanshin_core/lib/zanshin_core.dart:102` -- add `Remote` to the exports; worker config verbs `worker/isolate.dart:3496-3646`; handle `remotes()` :355, `gitFetchRemotes()` :397, `gitPushRemotes()` :374, `bookmarks(remotes:)` :326, `revsetCounts` :477, `opLog(limit:)` :298; types `ffi/config.dart` (`ConfigScope`, `ConfigScopeTarget`, `ConfigEntry{name,value,source,path,overridden}`, `ConfigSetResult.workingCopyAuthor`), `RevsetCount{n,capped,error}`.
- `packages/zanshin_ui/lib/zanshin_ui.dart` -- `ZsSegmented`(`ZsSegment.disabledReason`, variants `tabs`/`inset`), `ZsSelect`(+`ZsSelectCustom`, `onCustom`), `ZsSwitch`, `ZsTextField`(`size: sm`, `mono`, `error`), `ZsChip`(`filter`/`add`), `ZsMenuAnchor`, `ZsButton`, `ZsWindowScaffold`, `ZsNamiMark`, `ZsScrollArea`.
- DS: `_bmad-output/implementation-artifacts/design_system/components/settings/{SettingsRow,SettingsGroup,SettingsPage,ImmutablePage}.prompt.md`, `settings.css`, `components/window/Window.prompt.md`, `ui_kits/desktop/dialogs.jsx:204-261` (labels/hints), `ui_kits/desktop/kit.css:212-217` (scope line, body, footer).
- Tests/fakes: `test/helpers/fake_projects_environment.dart` (extend), `fake_windows.dart` (`FakeWindowFactory`), `fake_graph_search_source.dart`, `fake_projects.dart`; `test/features/window/app_window_coordinator_test.dart` (`_Rig` :49, Settings at :471), `app_windows_test.dart`, `zanshin_window_root_test.dart`, `test/features/app/zanshin_app_test.dart:219-232` (wiring check pattern), `test/features/home/home_page_test.dart:50`, `test/features/shell/app_menu_test.dart:55` (fake `AppWindowActions` — add `openSettings`), `test/widgetbook/ds_manifest_parity_test.dart:92-95` (pending `'11.7'` for SettingsRow/Group/Page/ImmutablePage — remove them from pending), `test/widgetbook/catalogue_windows_test.dart:268`, `test/l10n/hard_coded_strings_test.dart`.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_core/lib/zanshin_core.dart` -- export `Remote` -- item 8.
- `packages/zanshin_settings/lib/src/model/appearance_settings.dart`, `projects_settings.dart` (+ generated files, tests in `test/model/`) -- add `density` and `ProjectEntry.remotePoll` defaulted fields -- items 3, 4, 7.
- `app/lib/src/features/window/{app_windows,app_window_actions,app_window_coordinator,zanshin_window_root}.dart`, `lib/main.dart`, `lib/src/features/projects/project_window_title.dart` -- spec, `SettingsTarget`, `openSettings`, `SettingsWindowState`, close handler flush, size-to-content root, density scaler, dialog titles -- I5, I6, window item.
- `app/lib/src/features/projects/projects_environment.dart`, `projects_window.dart` -- config verbs + `configWrites`; footer re-reads on it; pass `onSettings`/`onIdentitySettings` from main -- I3, I4.
- `app/lib/src/features/settings/` (new: `settings_window.dart` content, `settings_view_model.dart`, `settings_widgets.dart` with `SettingsGroup`/`SettingsRow`/`SettingsPage`, `general_tab.dart`, `project_tab.dart`, `immutable_page.dart` + pure `immutable_heads.dart` parse/compose) -- the window's content -- items 1–7, 9, 11.
- `app/lib/src/features/graph/{immutable_reasons.dart (new), graph_peek.dart, graph_inspector.dart, graph_card_menu.dart, graph_view.dart}`, `home/project_graph_host.dart`, `home/home_page.dart`, `shell/app_menu.dart` -- reason producer + scope, card-menu action, entry points -- I3, I7, I8, I9.
- `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n` output) -- strings.
- `app/widgetbook/folders/windows.dart` (+ demo fakes) -- "Settings window" use case -- item 9.
- `app/test/...` -- tests for every witness below; update fakes implementing `AppWindowActions`/`ProjectsEnvironment`; DS parity pending list.

**Acceptance Criteria:**
- Given the coordinator, when `openSettings()` runs twice, then one window `settings` exists with `settingsWindowSpec`, activated the second time, on the same tab and page.
- Given Project shown last and no project, when ⌘, (app menu Settings…) fires, then General shows and the Project segment is disabled with "Open a project first".
- Given a project, when Project Settings… (capsule or File menu) fires, then Project shows; when "Appearance, diffs and more" fires, then General shows; when the card menu's Immutable commits… fires, then Project with the Immutable commits page shows and the title reads "Immutable commits".
- Given Settings, when Esc is pressed, then nothing happens; when the red button / ⌘W fires, then the window closes, and the next opening shows the tab without the page.
- Given the Settings window, when the tab changes, then its height follows its content (≤ 740) — size-to-content root without a Navigator; and its title reads "General" or the project's name.
- Given the Project tab shown, when the project closes, then General shows.
- Given the Theme row, when Night is chosen, then `appearance.themeMode` is dark and every open window restyles; Accent colour writes `appearance.accentSource` (default Follow macOS); Hide controls off writes `general.hideControls = false` (calm scrolling then does nothing — 11.3's existing gate); Layout writes `general.diffLayout`; Density writes `appearance.density` and changes the text scale.
- Given Name/Email fields, when a typed value is submitted, then `configSet` is called at user scope with it and the working-copy-author fact shows when returned; when the field blurs unchanged, then no call; the Projects footer re-reads identity after the write.
- Given the scope lines, then they show the fake `configPath` results for user and repo.
- Given the identity switch, when turned on and off, then repo `user.email` is set and unset.
- Given the navigation row, when activated (click, ↩, Space), then the page shows; ‹ and ⌘[ return; General hides the page and Project shows it again.
- Given any page write or a Trunk write, then exactly one `configChanged()` reaches the bound graph model.
- Given the peek of an immutable card with a reason scope answering `trunk()`, then the eyebrow reads "IMMUTABLE · trunk()" and the inspector flag tooltip "Immutable · trunk()".
- Given the Widgetbook "Settings window" use case, when opened, then the real Settings window opens through `CatalogueWindows`.

## Spec Change Log

## Review Triage Log

### 2026-11-02 — Review pass
- verdicts: 46 findings — high 0, medium 6, low 23, false 9, maybe-false 8
- findings:
  - Blind Hunter
    - `[medium]` `[patch]` ImmutableReasons caches per operation; a config write makes no operation, so reasons go stale — `invalidate()` called on `environment.configWrites` from `ProjectGraphHost`; test.
    - `[medium]` `[patch]` A multi-line TOML alias reads as unset, so the page shows the default and the first toggle overwrites it — `tomlStringValue` decodes `'''`/`"""` strings; test.
    - `[medium]` `[patch]` Reset runs `unset --repo` even when the alias comes from another scope — Reset shows only with a repo value (spec (c)); test.
    - `[medium]` `[patch]` `_load` has no generation guard and keeps the old project's fields — fields reset at load start, superseded loads dropped; test.
    - `[medium]` `[patch]` A pending field edit survives a project switch and writes into the new project — Project tab content keyed by the project path.
    - `[low]` `[reject]` No unset choice for Fetch from / Push to once set — rare; the CLI's `jj config unset` remains; adds a new option and state to two selects.
    - `[low]` `[reject]` `errors['user.email']` shared by the General and Project email rows — only after a failed write, on the other tab; fix needs a scoped error key.
    - `[low]` `[patch]` `immutableSummary` capitalises a bookmark name — only localized labels are capitalised.
    - `[medium]` `[patch]` A bare symbol (`@-`, `main@origin`, ids) becomes a Bookmark chip and is rewritten as `present(...)` — bare terms are chips only when they are known local bookmarks; the reorder on write is the spec's order (built-ins, chips, others, custom) and stays.
    - `[low]` `[patch]` Density replaces the platform text scaler — it multiplies the existing one.
    - `[false]` `[reject]` "Check for remote changes" has no consumer — epics.md 11.7 item 4: the preference "drives 11.8's poll"; 11.8 is the consumer.
    - `[maybe-false]` `[reject]` `configPath(...).first` may throw StateError on an empty list — would need the worker to answer an empty path list, which 9.28's `config path` never does for a scope; if true, only low.
    - `[low]` `[patch]` A non-FFI error in a flush aborts the close — each flush's error is caught and logged.
    - `[low]` `[patch]` Missing tests for the risky paths — tests added with the patches above (switch to no project, invalidate, Reset with a user-scope alias, multi-line alias, both-quotes TOML); the density scale already had a test.
  - Edge Case Hunter
    - `[medium]` `[patch]` Reason cache stale after a config write — same fix as the Blind Hunter's first row.
    - `[medium]` `[patch]` `_load` race / stale fields — same fix as above.
    - `[maybe-false]` `[reject]` A pending edit is lost when ⌘[ or a tab switch disposes the field before blur — a tab click moves focus (blur, then write) before the swap; ⌘[ inside a field goes to the field (text shortcuts win). Would need a running-app check; if true, only low.
    - `[false]` `[reject]` `user.name` typed as `42`/`true` is stored as a TOML number/bool — the CLI's `jj config set` parses VALUE as TOML the same way (cli config set, value parsed with a string fallback); parity is required.
    - `[maybe-false]` `[reject]` Remote/bookmark names needing revset quoting make `<name>@<remote>` invalid — would need a remote bookmark whose name is not a bare symbol; rare, if true only low.
    - `[low]` `[patch]` Reset when the alias is user-scope — same fix as above.
    - `[low]` `[reject]` "Use a different email here" turned on with no email anywhere writes `""` at repo scope — `""` is jj's own unset default (misc.toml), the case only arises with no identity at all (where 9.27's prompt points to General first); fixing needs a third switch state.
    - `[low]` `[patch]` Summary capitalises a bookmark — same fix as above.
    - `[low]` `[reject]` A repeated `present(main)` lands in the custom field — rare duplicate input; harmless (the write keeps the user's own text).
    - `[low]` `[patch]` `tomlString` with both quote kinds emits invalid TOML in the well — escaped basic string; test.
    - `[maybe-false]` `[reject]` A `\U` escape beyond U+10FFFF throws RangeError — would need such an escape in a user's alias; jj refuses invalid escapes when it parses the file, so it cannot reach configList; if true only low.
    - `[false]` `[reject]` `opLog(limit: 1)` may be empty — the op log always holds at least the root operation.
    - `[low]` `[patch]` Density replaces the system text scale — same fix as above.
  - Verification Gap
    - `[low]` `[patch]` HomePage capsule Project Settings… / Settings… → `openSettings` never asserted — test added.
    - `[low]` `[patch]` GraphViewControls' scope fallback untested — test added.
    - `[low]` `[patch]` GraphCardMenuHost → `openSettings(immutableCommits)` untested — host-level test added.
    - `[low]` `[patch]` main.dart's Projects window `onSettings`/`onIdentitySettings` unasserted — zanshin_app_test extended.
    - `[low]` `[patch]` DesktopProjectsEnvironment config verbs / `configWrites` untested — test added where the fake-worker pattern exists (see Auto Run Result).
    - `[low]` `[patch]` ProjectWindowTitle's dialog-controller branch untested — test added.
    - `[low]` `[reject]` ProjectGraphHost's ImmutableReasons wiring untested at host level — the producer, scope and both consumers are tested; a host test needs a full graph rig for three lines of wiring; checked by reading.
    - `[medium]` `[patch]` (other) reason staleness after a Settings write — same fix as the first row.
    - `[low]` `[reject]` (other) shared `user.email` error — same as above.
  - Intent Alignment
    - `[maybe-false]` `[reject]` Window-level witnesses (Esc, ⌘W, level, beside Projects, top edge, restyle, Window-menu title) are only unit-tested over fake windows — needs the running app (Marionette/CGWindowList), not available in this unattended run; recorded as not done under Auto Run Result.
    - `[false]` `[reject]` Item 10 (⌘F while Settings is key) has no change — `app_menu.dart:322-331` already activates the project window and focuses its search when any non-Projects window is key (11.13).
    - `[medium]` `[patch]` Reason cache keyed by operation — same fix as the first row.
    - `[false]` `[reject]` The reason shows the raw term instead of words — the 2026-10-26 note and I7 ask for the `immutable_heads()` term; the term is jj's text, verbatim by the house rule.
    - `[false]` `[reject]` Immutable commits… stays enabled while another action runs — opening Settings is no jj action; the blocked reason gates jj verbs only.
    - `[low]` `[patch]` I9 not exercised end to end from the graph host — the GraphCardMenuHost scope test closes it.
    - `[false]` `[reject]` Project Settings… sits in the File menu, not a "Project menu" — 11.13 placed it there; the capsule (11.5's Project menu) gets both callbacks.
    - `[maybe-false]` `[reject]` Density scales all text, not 11.1's base-size token — design question (a)'s recommendation is a scale on the base size; `fsBase` is a const used beside explicit sizes, so a text scale is the Claude's-proposal reading recorded in the spec; Ralph may decide otherwise at review.
    - `[false]` `[reject]` The Theme row uses a never-`init()`ed `ZanshinAppViewModel` — `setThemeMode` writes the store (every window root follows it) and mirrors the chrome without needing `init()` (`zanshin_app_view_model.dart:82-86`).
    - `[maybe-false]` `[reject]` "Edit…" for list-valued `git.fetch`/`git.push` is absent — design question (b) is a recommendation; deferred (see `deferred:`).

## Design Notes

- **Why extend `ProjectsEnvironment`** rather than a new port: it already is the app's worker-backed config reader (identity) with a DI singleton and a test fake; the Projects footer needs the write notification from the same object (I4).
- **Pending writes on close:** each text row registers a flush with the window's `SettingsViewModel`; the close handler awaits `flushPending()` then `windows.close(settingsWindowKey)`.
- **Immutable alias split** is top-level `|` only (skip `|` inside parentheses and quotes). Example: `builtin_immutable_heads() | present(develop) | heads(foo)` → `[builtin…, present(develop), heads(foo)]`. Compose order: built-ins (or `builtin_immutable_heads()` when all four), chips, `(trunk().. & ~mine())`, custom.
- **Density** is a Claude's proposal (design question (a)): one `TextScaler.linear` on the window, Compact = 1.0.

## Verification

**Commands:**
- `flutter test` in `app/` (whole suite) -- expected: all pass.
- `dart analyze --fatal-infos --fatal-warnings` in `app/`, `packages/zanshin_settings`, `packages/zanshin_core` -- expected: no issues.
- `dart format --set-exit-if-changed` on touched Dart packages -- expected: no changes.
- `dart test` in `packages/zanshin_settings` -- expected: all pass.
- `dart test` (or `flutter test`) for `packages/zanshin_core` export change -- expected: compiles; no Rust changed so no cargo checks.

**Manual checks (if no CLI):**
- Open the Widgetbook "Settings window" use case via Marionette (`zanshinCatalogue.open`) and compare with `design_system/components/settings/settings.card.html` / `immutable-page.card.html` when the catalogue can be run; otherwise record that it was not done.

**Verification notes (2026-11-02, gate rule of the story loop: no `cargo make test`/`test-full`/`coverage`):**
- `cargo make --allow-private test-flutter` (the app's `flutter test` with the gate's pinned env) — 1895 passed, after the review patches (1882 before them).
- `dart analyze --fatal-infos --fatal-warnings` in `app/`, `packages/zanshin_settings`, `packages/zanshin_core` — no issues.
- `flutter test` in `packages/zanshin_settings` — 43 passed.
- `dart format --set-exit-if-changed` over app/lib, app/test, app/widgetbook, packages/zanshin_settings, packages/zanshin_core/lib — 0 changed.
- `packages/zanshin_core`: only an export line changed; analyze passes, its suite (cdylib) was not run. No Rust, FFI or schema change, so no cargo checks, codegen or parity oracle.
- Not done: the Marionette catalogue comparison with the DS cards and the on-screen window checks (deferred, see `deferred:`).

## Auto Run Result

Status: done

**Summary.** The Settings window (key `settings`, content-sized 620 × ≤740, position-only frame, no minimum, no navigator) opens through `AppWindowActions.openSettings({SettingsTarget? target})` on the tab shown last; General (Theme, Density, Accent colour, Hide controls, Diff layout, user Name/Email) and Project (Fetch from, Push to, Check for remote changes, Trunk, the Immutable commits page, the repo email switch) tabs over `SettingsStore` and 9.28's config verbs through an extended `ProjectsEnvironment`; text rows write only changed values; graph keys re-request the layout once; an `ImmutableReasons` producer feeds the peek and the inspector. Code commit 9522ef8a1622dca99dd75e9eeb1951490fc2c2c4.

**Files (main).**
- `app/lib/src/features/settings/*` (new) — window content, view model, tabs, Immutable commits page, row/group/page widgets, alias parse/compose, tab state.
- `app/lib/src/features/graph/immutable_reasons.dart` (new) — cached reason producer + scope; `graph_peek.dart`, `graph_inspector.dart` show it; `graph_card_menu.dart` enables Immutable commits…; `graph_controls.dart` opens General.
- `app/lib/src/features/window/{app_windows,app_window_actions,app_window_coordinator,zanshin_window_root}.dart`, `projects/project_window_title.dart`, `main.dart` — spec, target, coordinator, size-to-content root + density, dialog titles, wiring.
- `app/lib/src/features/projects/{projects_environment,projects_window,project_registry}.dart` — config verbs + `configWrites`, footer re-read, `setRemotePoll`.
- `app/lib/src/features/{home/home_page,home/project_graph_host,shell/app_menu}.dart` — entry points, reason scope.
- `packages/zanshin_settings` — `AppearanceSettings.density`, `ProjectEntry.remotePoll`; `packages/zanshin_core` — `Remote` exported.
- `app/lib/l10n/*` — strings; `app/widgetbook/*` — "Windows / Settings window" use case; tests under `app/test/`.

**Review.** 46 findings: 0 high, 6 medium, 23 low, 9 false, 8 maybe-false. Patched: 6 medium + 13 low rows (reason-cache invalidation, multi-line TOML, Reset only with a repo value, chips only for known bookmarks, project-switch reset + generation guard, content keyed by project, guarded flushes, summary casing, density × platform scale, both-quotes TOML, 6 wiring tests). Deferred: 4 low (see `deferred:`). Rejected, with reasons in the triage log: Fetch/Push unset option, shared `user.email` error, remotePoll consumer (11.8's), `configPath` empty list, pending edit lost on ⌘[, TOML-typed names (CLI parity), revset quoting of odd bookmark names, own-email `""`, duplicate chip, `\U` escape, empty op log, host-level reason wiring test, running-app witnesses (deferred), item 10 (already in 11.13, `app_menu.dart:322-331`), raw-term reason, card row enabled while busy, File-menu placement, density as a text scale (Claude's proposal), un-init'ed theme view model, Edit… (deferred).

**Follow-up review recommendation:** false — no high patched; every medium patch carries a test. Patched counts: medium 6, low 13.

**Deferred-work items of the dispatch.**
- I1 — fixed (9522ef8): `SettingsTextField` writes on ↩/blur only when the text differs from the last value read or written; witness "an unchanged blur writes nothing".
- I2 — fixed (9522ef8): General › Theme (Paper · Night · Auto) calls `ZanshinAppViewModel.setThemeMode`.
- I3 — fixed (9522ef8): capsule Project Settings… and Settings…, app menu Settings… ⌘, and File › Project Settings… call `openSettings`; the Projects sidebar Settings… too.
- I4 — fixed (9522ef8): `ProjectsEnvironment.configWrites` fires after each write; the Projects footer re-reads the identity on it.
- I5 — fixed (9522ef8): `ZanshinWindowRoot(sizeToContent:)` puts the child in `Overlay.wrap(alwaysSizeToContent: true)` without `home:`; Settings uses it.
- I6 — fixed (9522ef8): `settingsWindowSpec = DialogWindowSpec(constraints: BoxConstraints(maxWidth: 620, maxHeight: 740), resizable: false, frame: WindowFrameMode.position)`.
- I7 — fixed (9522ef8): the peek's eyebrow reads "IMMUTABLE · <term>" from `ImmutableReasons` (one batched `revsetCounts` per commit over the alias's terms, cached per operation, invalidated on config writes).
- I8 — fixed (9522ef8): the inspector's Immutable flag tooltip reads "Immutable · <term>".
- I9 — fixed (9522ef8): the card menu's Immutable commits… opens Settings on Project › Immutable commits.
- I10 — fixed (9522ef8): General › Diffs › Layout writes `general.diffLayout`.

**Residual risks.** `RepoSettingsReads` (remotes, `exact:<remote>` bookmarks, head-operation counts) runs only against fakes in tests; the window's on-screen behaviour and the DS look are unchecked until the catalogue is opened via Marionette; density scales all text (a Claude's proposal Ralph may revisit).
