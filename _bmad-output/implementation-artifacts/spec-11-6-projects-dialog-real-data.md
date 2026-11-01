---
title: 'Story 11.6 — Projects window content on real data (tree, search, add directory, clone, folder drop, new group)'
type: 'feature'
created: '2026-10-18'
status: 'done'
baseline_revision: 'c11ec10ca7975194c7d235b589f9c9d2a899a013'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      The sidebar's version line shows only the app's version: nothing exposes jj-lib's.
    evidence: |-
      Story 11.6 item 2 proposes "the app's version with jj-lib's" (Claude's proposal, epics.md:12411). The only FFI version is zanshin-ffi's own (`zanshin_ffi_version`, crates/zanshin-ffi/src/lib.rs:69-72, "0.1.0 (<sha>)"); `Diagnostics` carries appVersion/gitSha/logPath; the jj-lib pin lives only in the root Cargo.toml (`=0.46.0`).
    location: >-
      app/lib/src/features/projects/projects_window.dart (sidebar brand block)
    severity: low
    resolved: >-
      2026-10-18 — fixed (spec-11-6-closing-jj-lib-version-in-brand, commit 23ddab3): zanshin_jj::JJ_LIB_VERSION (guarded against Cargo.lock) crosses the FFI as Diagnostics.jj_lib_version, and the brand shows "jj-lib 0.46.0" on a line of its own.
  - summary: >-
      The creation report and a failed open show in the Projects content's notice; once 11.12 closes Projects on a successful open, a report that came with it needs another place.
    evidence: |-
      epics.md:12370 ("Opening a project closes Projects"); the content calls onOpened(outcome) with the warnings and keeps them in its notice; the host is 11.12's, the toast 10.23's (backlog).
    location: >-
      app/lib/src/features/projects/projects_window.dart (onOpened)
    severity: low
    resolved: >-
      2026-11-01 — fixed (spec-10-23-operation-toast, commit e2da414): the project window shows the creation's warnings once as a toast via `ProjectSession.openReport`, and Projects always closes after an open.
  - summary: >-
      Groups can be created, nested and moved, but not renamed or deleted: the DS gives group rows no ••• and no other surface.
    evidence: |-
      DS components/content/ProjectRow.jsx:42-51 (group row: chevron, folder, name, count only); epics.md:12442 (item 8 names only creating and nesting).
    location: >-
      app/lib/src/features/projects/project_registry.dart; app/lib/src/features/projects/projects_tree.dart
    severity: low
  - summary: >-
      Reordering rows has no keyboard path; the keyboard regroups only through ••• › Move to group.
    evidence: |-
      epics.md:12428 (drag into groups and order); epic-11-context "a keyboard path" on every surface; no reorder key is designed (DS ProjectRow.prompt.md:11 lists ↑ ↓ Home End → ← ↩ only).
    location: >-
      app/lib/src/features/projects/projects_tree.dart
    severity: low
  - summary: >-
      The identity footer reads user.name / user.email when the content opens and when the open project changes, not after a config edit made elsewhere.
    evidence: |-
      No config-change event exists (9.28 verbs are request/response only); 11.7 will write identity rows; an external `jj config set` is invisible until the next read.
    location: >-
      app/lib/src/features/projects/projects_window.dart (footer)
    severity: low
  - summary: >-
      Clone shows no progress and cannot be cancelled, and the CLI's destination rules (create the folder, refuse a non-empty one, remove a folder it created after a failure) run app-side until 9.20 brings them into the verb.
    evidence: |-
      `ZanshinWorker.cloneRepo({url, targetPath})` takes no progress or cancel and requires an existing target, accepting a non-empty one (packages/zanshin_core/lib/src/worker/isolate.dart:421; 9.20 backlog); the CLI's rules are cli/src/commands/git/clone.rs:186-196, :259-270 @ v0.46.0.
    location: >-
      app/lib/src/features/projects/project_session.dart (clone)
    severity: low
  - summary: >-
      A successful clone is witnessed only on a fake port in the app: under dart/flutter test the VM reaps git's child, so jj-lib's fetch fails; whether the running app's clone works is unverified.
    evidence: |-
      packages/zanshin_core/test/worker/creation_test.dart:63-90 (only the refusal runs); deferred-work.md:448 (the running app); Rust witnesses crates/zanshin-ffi/tests/repo_ffi.rs:280, repo_write_ffi.rs:679-725.
    location: >-
      app/lib/src/features/projects/worker_project_repos.dart (clone)
    severity: medium
  - summary: >-
      The native folder picker and Reveal in Finder are unverified: only their Dart channel half is tested, and nobody has seen the NSOpenPanel sheet or the Finder selection.
    evidence: |-
      Review pass 2026-10-18 (verification gap): packages/zanshin_shell_macos/test/zanshin_shell_macos_test.dart pins the method names and argument maps against a mocked channel; ZanshinShellPlugin.swift (chooseDirectory, revealInFinder) and DirectoryPanel.swift have no test harness (app/macos/RunnerTests is a stub); the run's visual check could not drive the panel (Marionette taps reach the catalogue's view only).
    location: >-
      packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/{ZanshinShellPlugin.swift,DirectoryPanel.swift}
    severity: medium
---

<intent-contract>

## Intent

**Problem:** The registry from 11.5 has no window to show, fill or order it: projects can only be added by editing settings.json, Git repositories and plain folders cannot be converted or initialised from the UI, clone and folder drop do not exist, and the only Projects UI is the mock `home_dialog.dart` on `MockProject`.

**Approach:** Build the Projects window's content as a window-agnostic, DI-provided widget on real data (sidebar, 52 pt header, keyboard tree from `ProjectRegistry`, search, Add directory with detect → open / convert / init / enclosing-repo offers as ConfirmDialog sheets, an inline Clone form, Finder folder drop and row drag placed by `tree_drop.dart`, New group, ••• row menu, identity footer), extend the session/port with convert, init and clone, add a folder picker and Reveal in Finder to `zanshin_shell`, and export the creation result types. The native dialog window that hosts it (frames, style mask, title, launch window, exit rule, All Projects…) stays 11.12's: this story runs ahead of 11.12/11.13 as 11.5 did.

## Boundaries & Constraints

**Always:**
- epics.md Story 11.6 (:12359-12470) is the requirement; its "Design update 2026-10-16" (:12362-12395) supersedes item 1, the sheet bounds, Esc/scrim closing, `canClose`, "moon" selection, "Clone from remote" and "over the dialog". Precedence: epics decisions > DS tokens/CSS > DS prose/cards > the floating export (`design/`). Every open default is marked "Claude's proposal" in code docs; DS literals cite `DS <file>:<line>`.
- The content never assumes a window: it lays out in any size (catalogue panel, a catalogue window, 11.12's dialog window later), paints `ZsWindowFill`, draws its own 52 pt header row and a 52 pt empty sidebar top (the traffic lights sit there in a real window), and puts `WindowDragArea` on the empty header and sidebar top.
- CLI parity in what is shown and run: detect before anything; a jj workspace opens; a Git repository gets the conversion offer, a plain folder the init offer, a folder inside a repository the enclosing-repository offer; declining changes nothing on disk or in the registry. Every command shown is real at v0.46.0, in full, POSIX shell-quoted: convert = `jj git init --colocate <path>`, init = `jj git init --no-colocate <path>` (the worker's `initRepo(path, backend: 1)` is never colocated), clone = `jj git clone --no-colocate <url> <destination>` (`cloneRepo` is never colocated, remote `origin`). Warnings are shown with their `message` verbatim (9.33).
- Opens, creations and closes go through `ProjectSession`'s serial queue; a successful add/convert/init/clone registers the canonical path (symlinks resolved) at its placement and opens it (switching the one project window in place, 11.5). A path already in the registry (canonical comparison) is never added twice.
- App imports only `package:zanshin_core/zanshin_core.dart`, `package:zanshin_ui/zanshin_ui.dart`, `package:zanshin_settings/zanshin_settings.dart`, `package:zanshin_shell/zanshin_shell.dart`. SPDX first line, page width 120, `dart analyze --fatal-infos --fatal-warnings` clean. Every colour is a token; no Material or Yaru control; text entry is Zs fields.
- Text: English, sentence case, "bookmark" never "branch", `…` on items that open something, curly quotes, no "please"/"!". DS strings verbatim: "Projects", "Search projects, paths…", "Add directory", "Clone…", "New group", "Settings…", "More…", "No projects match “{q}”", status labels of `ProjectStatusStyle`.
- Paths, names and URLs are logged at FINE only; WARNING lines carry codes. App tests never call a jj config verb for real (Makefile.toml:138-140) and never reach the network.

**Never:**
- No dialog window, no `AppWindows` change, no per-window app root, no window title/style mask/frame/minimum, no launch-window or exit-rule change, no ⌘W/⇧⌘O/⌘,/⌘F binding, no All Projects… action in `HomePage` (11.12/11.13; deferred-work "Surfaced in Story 11.5" I1/I2).
- No Remotes navigation row (design question (a) is Ralph's; deferred-work.md:1071 records it; "until its verb lands, a UI element stays disabled or absent"). No ↑/↓ ahead/behind (9.29), no clone progress or cancel (9.20), no Settings window (11.7: the Settings… row and the identity link take nullable callbacks).
- No Rust or FFI change; no new pub dependency; no `src/` imports across packages; no golden tests; no edits under `design/` or `design_system/`; never lower the coverage baseline; do not delete `home_dialog.dart`/`app_shell.dart` (11.10's list, epics.md:12817).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Add a jj workspace | detect jj, path new | registered (canonical path) at the placement, opened, `ProjectOpened(warnings: [])`; the row is selected and carries OPEN | — |
| Add an existing entry | canonical path equals a registered one (another spelling, trailing `/`, symlink) | nothing added; that row is selected and opened like a tree open | — |
| Add a Git repo | detect git | `ProjectNotARepo(git)` → convert sheet; Convert → `convert(path)`, registered, opened, warnings shown; Cancel → disk and registry unchanged | convert throws → `ProjectOpenFailed(code, context, warnings)`; nothing registered |
| Add a plain folder | detect neither, no suggestion | init sheet; Create → `initRepo(path, backend: 1)`, registered, opened | `jj.jj_lib_error` → failure notice with `context` |
| Inside a repo | neither, `suggestedRoot: /r`, kind jj (or git) | enclosing-repository sheet for `/r` (Add / or the convert sheet for `/r` when git) | — |
| Path gone | detect pathNotFound | notice "‹path› does not exist." (Claude's proposal); a registered entry gets status missing | — |
| Clone | url `…/repo.git`, destination `<parent>/repo` missing | folder created, `cloneRepo`, registered, opened, warnings (e.g. `jj.identity_missing`) shown | failure → folder the session created removed again; `ProjectOpenFailed` |
| Clone into non-empty | destination exists with files | `ProjectRefused('Destination path exists and is not an empty directory')`, no worker call | — |
| Clone into empty dir | destination exists, empty | cloned there; on failure the folder stays (it existed) | — |
| Drop folders | 1 jj + 1 git + 1 listed folder onto a group row's middle | in order: jj registered inside that group (not opened, several folders), convert sheet for the git one, the listed one skipped; a single dropped jj folder is opened | each folder's own outcome |
| Remove from list | ••• › Remove from list on a closed project | entry gone, siblings renumbered, folder on disk untouched; disabled for the open project | — |
| Move group | drag group G onto its own descendant | refused (no change) | — |
| Search | "api" | rows whose `name + " " + path` contains it (trimmed, case-insensitive), with their ancestor groups expanded; a matching group shows its whole subtree; none → "No projects match “api”" | — |
| Missing row | status missing | struck through, `--text-faint`, dot at .5; ↩ / double-click / Open do nothing | — |
| Identity | `configGet` gives `''` / values | footer: the CLI's phrase ("Name and email not configured." / "Name not configured." / "Email not configured.") or the name and email | read throws → footer hidden, WARNING with the code |

</intent-contract>

## Code Map

- `_bmad-output/planning-artifacts/epics.md:12359-12470` -- Story 11.6 (design update :12362-12395 first); 11.12 (:12925-13001) for what is not built here; decisions 16.13-16.17, 16.38-16.47 (:11535-11630); house rule Commands (:8018-8022).
- DS (`_bmad-output/implementation-artifacts/design_system/`): `components/window/Window.prompt.md:14-23`, `window.css:26-43` (fill, `.has-side` row, sidebar 200 with `padding-top:52` and right hairline, header 52 with bottom hairline, title at sidebar + 12, 600 13/1.2, inactive `--text-dim`); `ui_kits/desktop/dialogs.jsx:13-58` (toolbar order, search autofocus, initial selection = open project, group click selects and toggles, search semantics :14-17, no-results :51), `kit.css:192-202` (brand gap 9 padding 6 14 12, nav padding 0 10 gap 1, footer padding 10 14 14 + top hairline, tree padding 8 10 12 gap 1, no-results 30 16 `--fs-md` `--text-dim`); `components/surfaces/surfaces.css:33-39` (nav row 30, padding 0 9, radius 9, 12.5 `--text-muted`, icon md `--text-dim`, current `--fl-on`); `components/content/ProjectRow.{prompt.md:8-11,jsx:5-80}`, `content.css:66-95` (indent 16/level, padding 6 8 6 (8+16·depth), radius 8, gap 8; group: chevron sm in 14 box rotating on `--dur-expand`, folder/folder-open md, name `--fs-sm` 600 caps tracking .08em `--text-muted`, count mono `--fs-xs` `--text-faint` "N" + " · 1 group"/" · M groups" only when M > 0; project: dot 7, name 13/500, OPEN 600 `--fs-2xs` caps `--co-text`, bookmark mono `--fs-xs` `--text-dim` with xs glyph ("—" hides it), line 2 mono `--fs-xs` path · last opened (sans), ••• 22×22 radius 6 `more` md shown on hover/focus-within, missing struck .5 px; states hover `--fl-hover`, pressed `--fl-on`, selected `--accent-soft` also on hover, selected+pressed `--accent-soft-hi`, base.css:48-49 text rung shift, contrast.css:26 inset `--accent-line`); `tokens/inactive.css:17-22`; `components/controls/ConfirmDialog.prompt.md:9-12`; `components/forms/SearchField.prompt.md:7-10`; `readme.md:49-65` (text rules), `:187-194`, `:209` (typeahead `--dur-typeahead`).
- Floating export `design/windows.jsx:149, :178-179, :219` + `windows.css:59, :61` + `app.css:2345-2362` -- search `flex:0 1 230px; min-width:120px`, Clone… icon-only below 800 wide, New group always icon-only, drop hint "Drop to add directory" (icon `download` retired → `ZI.fetch`) shown only during a drag.
- `app/lib/src/features/projects/project_session.dart:16-60` (sealed outcomes: `ProjectOpened`, `ProjectNotARepo(kind)`, `ProjectInsideRepo(root, kind)`, `ProjectOpenFailed(code, context)`), `:77-135` (ctor, `current`, `repo`, `recent`, `lastFailure`, `open`, `closeProject`, `reopenLast`), `:137-204` (`_open`: detect, open, read, `registry.add` :183, `recordOpened` :184, `setOpen` :188), `:282-287` (`_serial`).
- `app/lib/src/features/projects/project_repos.dart:9-35` (port; `ProjectRepo.handle` is `OpenedRepoHandle` :20 → widen to `RepoHandle`), `worker_project_repos.dart:22-87`, `project_registry.dart:15-216` (`add` :50, `addGroup` :72, `move` projects only :95 with one shared sibling order, `_siblings` :168 groups before projects on a tie, swallowed write failures :162-165), `projects_module.dart:29-30` (registry built inline), `project_status_style.dart:9-27`, `project_capsule.dart:101, :181-198` (ZsControlCore row pattern, calm hold), `tree_drop.dart:6-124` (`treeDropPlacement` quarters/halves, `treeInsertionPoint`, `treeAppendPoint`, `insertTreeNodes` on `TreeSliverNode<T>`), `app/lib/main3.dart:185-326` (drop POC: per-row `FolderDropTarget` + outer append target, hover via the target's callbacks only, deferred-work.md:336-337).
- `packages/zanshin_core/lib/zanshin_core.dart:9-42` -- barrel; add `CreatedRepoHandle` (`src/worker/handle.dart:1121`: `warnings`, `precondition`), `Precondition` (`src/ffi/precondition.dart:54`), `SnapshotStats`, `UntrackedPath`, `UntrackedReason`, `FileTooLarge`, `FileNotAutoTracked` (`src/ffi/file_ops.dart:97+`). Worker: `detect` :835, `convert` :853, `initRepo(path, {backend})` :398 (path must exist), `cloneRepo({url, targetPath})` :421 (target must exist; all failures `jj.jj_lib_error`), `configGet(name, {workspaceRoot})` :1687 (unset identity reads `''`, jj-lib misc.toml:48-50). Codes: `docs/rust-error-codes.md:45-63, :113`.
- `packages/zanshin_shell/lib/src/zanshin_shell.dart` (static facade), `packages/zanshin_shell_platform_interface/lib/src/zanshin_shell_platform.dart` (methods throw `UnimplementedError`; `setFolderDragHandler` :64, `enableFolderDrops` :67), `packages/zanshin_shell_macos/lib/zanshin_shell_macos.dart` (method channel), `macos/zanshin_shell_macos/Sources/zanshin_shell_macos/{ZanshinShellPlugin.swift:195-215 (dispatch), FlutterViewLookup.swift (view → window)}`; tests `packages/zanshin_shell_platform_interface/test/`, `packages/zanshin_shell_macos/test/zanshin_shell_macos_test.dart`; `FolderDropTarget` `packages/zanshin_shell/lib/src/folder_drop_target.dart:38` (`onDrop`, `onDragUpdate` → accept, `onDragExit`; innermost wins; paths not canonical).
- `packages/zanshin_ui/lib/zanshin_ui.dart` -- `ZsWindowFill`, `ZsSearchField` (Esc clears, Esc on empty leaves), `ZsTextField`, `ZsButton` (`primary` gold, `quiet`, `ghost`, `iconOnly`, `busy`), `ZsIconButton`, `ZsScrollArea`, `ZsMenuAnchor`/`ZsMenuItem` (submenu, danger, `ZsMenuController.open(position:)` for a pointer menu), `ZsTooltip`, `ZsControlCore` (no focus on pointer press, no double/secondary tap), `ZsConfirmDialog` + `ZsSheet` (fills its parent; tone `standard`), `ZsLink`, `ZsNamiMark(size: 32, chip: true)`, `ZanshinIcon`/`ZI` (`folder`, `folderOpen`, `folderPlus`, `chevronRight`, `plus`, `cloud`, `more`, `search`, `settings`, `bookmark`, `fetch`), `ZsColors` (`accentSoft`, `accentSoftHi`, `accentLine`, `accentLive*`, `flHover`, `flOn`, `flPress`, `flBorder`, `text*`, `proj*`, `coText` for OPEN), `ZsType`, `ZsMetrics` (`windowHdH` 52, `controlMd` 30), `ZsAppearance.inactive` (`design/zs_appearance.dart:201-204`).
- `app/lib/src/features/home/home_page.dart:30-68` (capsule wiring stays as is), `app/lib/main.dart:108-150` (`_startApp`, `MainComponent` getters + `// ignore: unreachable_from_main`; regenerate `main.inject.dart` with `dart run build_runner build --delete-conflicting-outputs` in `app/`), `app/lib/src/features/bootstrap/zanshin_bootstrap.dart:200-208` (PackageInfo read) and `splash_card.dart:76-82` (format "‹version› · Build ‹build›").
- Catalogue: `app/widgetbook/catalogue.dart:25-35, :155-178`, `folders/projects.dart` (`demoProjects`, capsule use cases), `folders/windows.dart:55-140` (`CatalogueWindows.of(context).openOrActivate`, `CatalogueWindowRoot`; comment :58 swaps 11.6/11.7 — fix it), `catalogue_extension.dart:58-86`; `app/test/widgetbook/catalogue_smoke_test.dart:27-78` (folder names, required paths, every use case in both themes + all flags), `app/test/helpers/recording_shell.dart` (lacks the folder-drop overrides).
- Tests/helpers: `app/test/helpers/{fake_projects.dart, shell_host.dart (shellHost, useShellWindow), icon_registry.dart, catalogue.dart}`; patterns `app/test/features/projects/{project_session_test.dart:28-31 (real SettingsStore in a temp dir), project_capsule_test.dart:107-142, :404-468 (focus, keys, semantics), worker_project_repos_test.dart:51-76 (real worker)}`; `packages/zanshin_core/test/worker/creation_test.dart:21-40` (`git init -b main` + commit via `Process.run` for convert fixtures).
- `crates/xtask/src/tasks/gate_plan.rs:233-262` -- core/shell/ui/app prefixes; no app test reads outside `app/`.
- jj CLI @ v0.46.0 (`git -C ../jj show v0.46.0:<path>`): `cli/src/commands/git/init.rs:60-104, :161-222` (`--colocate`, `--no-colocate`, destination), `cli/src/commands/git/clone.rs:162-196, :259-270` (destination from the source, the non-empty refusal text, `create_dir_all`, cleanup of a folder it created).

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_core/lib/zanshin_core.dart` -- export `CreatedRepoHandle`, `Precondition`, `SnapshotStats`, `UntrackedPath`, `UntrackedReason`, `FileTooLarge`, `FileNotAutoTracked` -- item 9's bridge part (the creation results).
- `packages/zanshin_shell_platform_interface/lib/src/zanshin_shell_platform.dart`, `packages/zanshin_shell_macos/lib/zanshin_shell_macos.dart`, `.../Sources/zanshin_shell_macos/ZanshinShellPlugin.swift` (+ a `DirectoryPanel.swift` if cleaner), `packages/zanshin_shell/lib/src/zanshin_shell.dart` -- `Future<String?> chooseDirectory({required int viewId, String? initialDirectory, String? prompt})` (NSOpenPanel: directories only, one, create allowed; a sheet on the view's window when found, else `runModal`; null on cancel) and `Future<void> revealInFinder(String path)` (`NSWorkspace.activateFileViewerSelecting`); tests in both Dart packages (channel arguments/results, default throws) -- the folder picker and Reveal in Finder (item 4's ••• and item 5).
- `app/lib/src/features/projects/project_repos.dart` -- `ProjectRepo.handle` → `RepoHandle`; port gains `Future<ProjectCreation> convert(String path)`, `init(String path)`, `clone({required String url, required String destination})`; `ProjectCreation({required ProjectRepo repo, List<ZanshinWarning> warnings})`.
- `app/lib/src/features/projects/worker_project_repos.dart` -- convert/init (`backend: 1`)/clone pass-throughs wrapping the `CreatedRepoHandle` as a `ProjectRepo` (same `changes`/`read`/`close` as open), warnings carried; failures rethrown as `ZanshinFfiException` (warnings kept).
- `app/lib/src/features/projects/project_registry.dart` -- `remove(String path)` (renumbers siblings, clears `openProject` only if equal), `moveGroup(String id, {required int index, String? parent})` (same index semantics as `move`; a move into itself or a descendant is a no-op), `contains(String canonicalPath)` helper if useful.
- `app/lib/src/features/projects/project_session.dart` -- `ProjectOpened` and `ProjectOpenFailed` gain `List<ZanshinWarning> warnings` (default `const []`); new `ProjectRefused(String message)` outcome; `open(path, {String? group, int? index})` places a newly registered path; `convert`, `initRepo`, `clone({url, destination, group, index})` through the serial queue (detect not repeated; clone takes the destination as given — the form pre-fills it — and does the CLI's destination rules: refuse an existing non-empty folder with the CLI text, create a missing folder, remove a folder it created after a failure); canonical paths (`resolveSymbolicLinksSync` when the path exists, normalised); one shared switch step for opened and created repos (11.5's order: read, record, switch, notify, close the old).
- `app/lib/src/features/projects/projects_environment.dart` -- port `ProjectsEnvironment { Future<String?> appVersion(); Future<JjIdentity> identity({String? workspaceRoot}); Future<String?> chooseDirectory({required int viewId, String? initialDirectory}); Future<void> revealInFinder(String path); }`, `JjIdentity({String? name, String? email})` (`''` → null; `missingPhrase` gives the CLI's phrase); the desktop adapter: PackageInfo in the splash's format, `configGet('user.name'|'user.email', workspaceRoot:)`, `ZanshinShell`.
- `app/lib/src/features/projects/projects_window.dart` -- `ProjectsWindow` (`@assistedInject`; injected session, registry, environment; assisted `onOpened` `ValueChanged<ProjectOpened>?`, `onSettings` `VoidCallback?`, `onIdentitySettings` `VoidCallback?`, key; root `Semantics(identifier: 'projects-window')` + `KeyedSubtree`) -- layout of Design Notes "Window"; sidebar (brand, nav Projects current + Settings… disabled while `onSettings` is null with tooltip "Settings — ⌘, (the tab shown last)", footer identity); header (title, search, Add directory, Clone…, New group; responsive); notice; inline Clone form; the tree; the offer sheets (`ZsSheet` + `ZsConfirmDialog`, tone standard, the command in the well); folder-drop hint.
- `app/lib/src/features/projects/projects_tree.dart` (+ `projects_tree_model.dart` for the pure projection if it helps testing) -- builds `TreeSliverNode`s from the registry (sibling order; collapsed set in memory, groups expanded by default — Claude's proposal), the search filter, rows per DS, keyboard model, typeahead, row drag (`Draggable` / `DragTarget`, placement by `treeDropPlacement` + `treeInsertionPoint`), Finder drop per row + an outer append target, ••• / right-click menu (Open, Reveal in Finder, Move to group ›, Remove from list), drop indicators (Design Notes).
- `app/lib/src/features/projects/relative_time.dart` -- `lastOpenedLabel(DateTime at, DateTime now)` (Design Notes; Claude's proposal) and `displayPath(String path, String home)` (`~` prefix).
- `app/lib/src/features/projects/projects_module.dart` (+ regenerated `app/lib/main.inject.dart`) -- provide `@singleton ProjectRegistry`, the session from it, and a `ProjectsEnvironment` (`DesktopProjectsEnvironment(Future<ZanshinWorker>)`); `app/lib/main.dart` adds `@inject ProjectsWindowFactory get projectsWindowFactory` (with the `unreachable_from_main` ignore + WHY) so 11.12 only hosts it; an app test builds `MainComponent` and checks the factory's content gets the component's singleton session and registry.
- `app/test/helpers/{fake_projects.dart, fake_projects_environment.dart, recording_shell.dart}` -- the fake port gains convert/init/clone scripting (results, failures with warnings, call log); a fake environment (version, identity, picker answers, reveal log); `RecordingShell` implements `setFolderDragHandler` / `enableFolderDrops` / `disableFolderDrops` (records views, lets a test inject `FolderDragEvent`s).
- `app/test/features/projects/{project_registry_test, project_session_test, worker_project_repos_test, projects_window_test, projects_tree_test, relative_time_test}.dart` -- every matrix row; `worker_project_repos_test` with the real worker: convert of a `git init -b main` + commit repo (handle, warnings list, `.jj` present), init of an empty dir (Git backend, no `.git` in the folder), clone refusal into a missing target (`jj.jj_lib_error`); widget tests for the ACs.
- `app/widgetbook/folders/projects.dart` (+ `app/widgetbook/demo_projects_fakes.dart`), `folders/windows.dart`, `catalogue.dart`, `app/test/widgetbook/catalogue_smoke_test.dart` -- component "Projects window" with use cases "Tree" (nested groups, every status, OPEN, missing, long names, a selection), "Search" (a query with matches), "No results", "Empty", "Narrow" (680 × 440), "Convert offer" (sheet open), "Clone form" (open, one busy knob), "Drop hint" (shown), "No identity"; Windows folder "Projects window" opening the content at 900 × 640, minimum 680 × 440 through `CatalogueWindows`; demo data over a temp-file `SettingsStore` and fake repos/environment; smoke-test paths extended.
- Tracking (finalize): `deferred-work.md` ("Surfaced in Story 11.6" mirroring `deferred:`), `epic-11-context.md` (Order + hand-off lines), `sprint-status.yaml` (11-6).

**Acceptance Criteria:**
- Given a registry with nested groups and projects, when the content renders at 900 × 640, then it shows the 200 px sidebar (52 empty, brand with the 32 px Nami chip, "Zanshin", the version line, nav, identity footer), the 52 px header with "Projects" at sidebar + 12 and the toolbar search 230 · Add directory (gold) · Clone… · New group (icon), and the tree in registry order with group counts in the DS format, dots, OPEN on the open project, bookmark labels, "‹~path› · ‹last opened›" and struck-through missing rows; at 680 × 440 the search is 120 and Clone… is icon-only.
- Given the tree, when it has focus, then it is one Tab stop (the selected row, else the first row), ↑ ↓ Home End move and select, → expands or steps in, ← collapses or steps to the parent, ↩ opens a project or toggles a group, typing a name prefix within 600 ms selects it, Tab reaches only the selected row's •••, and VoiceOver reads each row with its selected/expanded state and the dot's label.
- Given the search field (focused on open), when text is typed, then the tree filters by name and path across groups with matching ancestors expanded, Esc clears it and never closes anything, ↓ moves focus into the tree, and no match shows "No projects match “‹q›”".
- Given Add directory, when the picker returns a folder, then the matrix's add rows hold: jj opens, Git gets "Convert ‹name› to a jj repository?" with `jj git init --colocate '<path>'`, a plain folder gets the init sheet with `jj git init --no-colocate '<path>'`, a folder inside a repository gets the enclosing-repository sheet; Cancel leaves disk and registry unchanged; creation warnings show verbatim in the notice.
- Given a Finder drag over the content, when it hovers a row, then the drop hint and the placement indicator show in the live accent tokens, and the drop runs the add flow per folder at `tree_drop.dart`'s placement without duplicates; given a row dragged onto another row, then the registry order and grouping follow the same placement.
- Given ••• (or a right-click) on a project row, when Open / Reveal in Finder / Move to group › / Remove from list is chosen, then it opens, reveals (environment called), regroups or removes only the registry entry; Open and Reveal are disabled for a missing row, Remove for the open project.
- Given New group, when a name is typed and ↩ pressed, then a group is created (inside the selected group, else top level) in place of the inline field; Esc or an empty name cancels.
- Given the Clone form, when a URL and destination are entered and Clone is pressed, then the button is busy and the fields are disabled until the outcome; the matrix's clone rows hold; the Clone button's tooltip is the shell-quoted `jj git clone --no-colocate` command.
- Given `onSettings`/`onIdentitySettings` null, when the content renders, then the Settings… row is disabled and the footer link is absent; when passed, they run on activation.
- Given the catalogue, when Projects › Projects window's use cases and Windows › Projects window are opened in night and paper (and inactive), then they match the DS window, ProjectRow and SearchField cards (Claude's visual check, Verification).
- Given the change, when `cargo make test` runs unpiped, then it passes with the coverage baseline unchanged.

## Spec Change Log

## Review Triage Log

### 2026-10-18 — Review pass
- verdicts: 55 findings — high 0, medium 3, low 46, false 6, maybe-false 0
- findings:
  - `[medium]` `[patch]` (blind 1) A multi-folder drop calls `onOpened` as soon as a confirmed offer opens its repository, so a host closing Projects there (11.12) cuts the rest of the batch off — patched: during a batch the opens are collected and `onOpened` runs once with the last after the loop; a drop test confirms an offer mid-batch and checks the later folder was registered before `onOpened` ran.
  - `[low]` `[reject]` (blind 2) A click on a row does not move keyboard focus into the tree — by 11.11's rule a pointer press never focuses a Zs control (`ZsControlCore`), and ↓ from the search (which holds focus) reaches the selected row; changing it goes against the library rule.
  - `[low]` `[patch]` (blind 3) Toggling a group during a search flips a collapse state nobody sees — patched: toggles are ignored while a query is present; a test toggles Mobile during a search and finds it still expanded after the search is cleared.
  - `[low]` `[patch]` (blind 4) A `~` or relative clone destination is resolved against the app's working directory — patched: the form resolves `~` and relative paths against the home folder (Claude's proposal) for the call and the tooltip's command; a test clones into `~/elsewhere/repo`.
  - `[low]` `[patch]` (blind 5) A URL that names no folder pre-fills the bare parent as the destination — patched: the destination stays empty (the CLI refuses such a source), so Clone waits; a test checks the empty field and the disabled Clone.
  - `[low]` `[patch]` (blind 6) "Failed to create …" drops the OS cause and is untested — patched: the refusal appends the cause, as the CLI's `user_error_with_message` does; a session test clones under a regular file.
  - `[low]` `[reject]` (blind 7) `registered()` runs synchronous filesystem calls per entry — the registry is small, entries stored since 11.6 are canonical, and a stall needs an entry on an unreachable network volume; a cache adds state.
  - `[low]` `[patch]` (blind 8) `_clone` registers its canonical path and bypasses the registry's other-spelling lookup — patched: it goes through `_target`; a session test clones into a folder listed through a symlink and keeps one entry.
  - `[low]` `[patch]` (blind 9) The convert sheet for a folder inside a Git repository does not say why — patched: the body names the chosen folder and the repository around it; the inside-Git test checks the sentence.
  - `[low]` `[reject]` (blind 10) The drop hint shrinks the tree mid-drag — the rows keep their place unless the list is scrolled to its end; overlaying the hint is a layout change beyond a direct correction for a rare case.
  - `[low]` `[reject]` (blind 11) With a long list the one Tab stop can vanish when the selected row is scrolled out of the built range — needs a pointer scroll and then Tab; ↓ from the search still reaches the row; a fallback stop needs tracking which rows are built.
  - `[low]` `[reject]` (blind 12) "Last opened" labels never refresh — they refresh on every registry or session change (each open); a timer adds state for a cosmetic drift.
  - `[low]` `[reject]` (blind 13) The search matches the stored path, not the `~` form shown — the DS matches name and path; matching the display form needs the home folder in the model for a rarely typed `~`.
  - `[low]` `[patch]` (blind 14) Typeahead drops a space — patched: a space continues a name being typed (never starts one); a test types "my p" to reach "my project".
  - `[low]` `[patch]` (blind 15) The picker's `prompt` is plumbed through but never used — patched: Add directory passes "Add", Clone's Choose… passes "Choose" (Claude's proposal); the Add directory test checks the prompt.
  - `[low]` `[reject]` (blind 16) VoiceOver users get no hint or action for opening a row — ↩ opens and a second activation opens; custom semantics actions are new surface the DS does not design.
  - `[low]` `[patch]` (blind 17) Missing widget witnesses: a reorder before another row, a drop on the end zone, a Finder drop on an empty window, an offer confirmed in a batch, the row's "open" value — patched: tests for each (with verification gaps 1 and 2).
  - `[low]` `[reject]` (blind 18) Row ids are built from strings in several places — no defect; the formats are defined by `ProjectsItem.id` and read by a handful of callers in the same feature.
  - `[low]` `[reject]` (blind 19) `ProjectSession.registry` exists only for a test — it is the DI witness's one way to the singleton registry; one accessor.
  - `[false]` `[reject]` (blind 20) The exported snapshot-report types have no consumer and the report is missing — the exports are epic item 9's bridge part; the report reaches the notice through the warnings, which carry the CLI's text and repeat `SnapshotStats` (9.33: `snapshot_files_refused`, `snapshot_paths_not_utf8`).
  - `[low]` `[reject]` (blind 21) Unawaited futures without an error path (Reveal's `PlatformException`, a non-FFI identity failure) — needs a dead worker or a channel refusing a path it was given; the class 11.5 rejected (its blind 2).
  - `[low]` `[reject]` (edge 1) A non-FFI throw from convert/init/open leaves the offer sheet busy — worker-death class (see blind 21).
  - `[low]` `[reject]` (edge 2) A non-FFI throw from clone leaves the form busy — same class.
  - `[low]` `[reject]` (edge 3) A non-FFI throw from the clone leaves the created folder — same class.
  - `[low]` `[reject]` (edge 4) A `StateError` from the identity read is unhandled — same entry as blind 21.
  - `[false]` `[reject]` (edge 5) A second add flow can replace a shown offer and strand its completer — the sheet's scrim fills the content above the tree (`Positioned.fill` in the Stack) and takes every hit, so no row `FolderDropTarget` is under the pointer; the window's own target refuses while an offer is up; the toolbar is behind the scrim and outside the sheet's focus trap.
  - `[medium]` `[patch]` (edge 6) A confirmed offer in a multi-folder drop fires `onOpened` mid-batch — same entry as blind 1, patched there.
  - `[low]` `[reject]` (edge 7) Several failing folders in one drop show only the last notice — needs several failures in one drop; accumulating changes the notice's model.
  - `[low]` `[patch]` (edge 8) The header's Clone… clears the form while a clone runs — patched: it is disabled while the clone runs; a test taps it mid-clone.
  - `[low]` `[reject]` (edge 9) New group inside a selected group whose ancestor is collapsed shows no field — needs a group selected during a search inside a collapsed group, then New group after clearing; expanding ancestors adds a walk for a rare path.
  - `[low]` `[patch]` (edge 10) Switching apps cancels the new group's field (macOS parks focus at the root while the app is inactive) — patched: a blur while the app is not resumed does not cancel; a macOS-variant test fails without the guard and passes with it.
  - `[low]` `[patch]` (edge 11) Toggles during a search — same entry as blind 3.
  - `[low]` `[patch]` (edge 12) `~` / relative destination — same entry as blind 4.
  - `[low]` `[patch]` (edge 13) A parent of `/` gives `//name` — patched: the destination joins without a double slash.
  - `[low]` `[reject]` (edge 14) A dragged row unmounted mid-drag stays at half opacity — needs scrolling the tree during a drag; cosmetic, cleared by the next drag.
  - `[low]` `[patch]` (edge 15) A list taller than the window leaves no end zone to drop at the top level's end — patched: the end zone is at least 24 high (Claude's proposal); the end-zone drag test drops there.
  - `[low]` `[reject]` (edge 16) A group-parent cycle hides groups — the registry never writes one (`moveGroup` refuses); only a hand-edited file could, and `projectsTree` stays finite.
  - `[low]` `[reject]` (edge 17) A clone failing with `watcher.io_error` after it succeeded on disk is reported failed — rare; the folder is a jj workspace then, which Add directory opens.
  - `[low]` `[patch]` (edge 18) The create failure lacks its cause — same entry as blind 6.
  - `[low]` `[reject]` (edge 19) A failed removal of the created folder is only logged — needs removing an empty folder the session just created to fail; a shown line needs a warning code of its own.
  - `[low]` `[patch]` (edge 20) A clone registers a second entry for a folder listed under another spelling — same entry as blind 8.
  - `[low]` `[patch]` (verification gap 1) A Finder drop outside any row (the empty window) is unverified — same entry as blind 17: a test drops on an empty window and checks detect/open/read and the top level.
  - `[low]` `[patch]` (verification gap 2) A row dragged to the empty space below the rows is unverified — same entry as blind 17: a test drags MyApp below the last row.
  - `[low]` `[patch]` (verification gap 3) The order of several dropped folders is unverified — patched: the batch test drops `a`, a Git repository and `b` before `top` and checks orders 1, 2, 3, 4.
  - `[low]` `[patch]` (verification gap 4) A clone with a group selected is not checked to land there — patched: a test selects Mobile, clones and checks the group.
  - `[low]` `[patch]` (verification gap 5) `DesktopProjectsEnvironment` is untested — patched: `projects_environment_test.dart` checks the identity keys, the workspace root, `''` → not configured, and the version line, over a fake worker (no real config verb) and `PackageInfo.setMockInitialValues`.
  - `[low]` `[patch]` (verification gap 6) The destination that cannot be created is untested — same entry as blind 6.
  - `[medium]` `[defer]` (verification gap 7) The Swift folder picker and Reveal in Finder are unverified and the gap is not recorded — no Swift test harness exists; deferred (frontmatter `deferred:`, mirrored in deferred-work.md) as a manual check in Windows › Projects window.
  - `[low]` `[patch]` (verification gap other 1) A relative or `~` destination — same entry as blind 4.
  - `[false]` `[reject]` (intent 1) I1 is not wired (the row stays disabled) — the intent's own clause defers to a later story; 11.12 (backlog, after this run) builds `openProjects` (epics.md:12970), and `AppWindows` stays outside DI until then; the Auto Run Result reports I1 as not done.
  - `[false]` `[reject]` (intent 2) I2 is not shown at launch or after a close — the intent puts the launch window and exit rule on 11.12; 11.6's part (the hostable content, the factory, `onOpened`) is built; reported as partly done.
  - `[false]` `[reject]` (intent 3) The Auto Run Result does not list I1/I2 — a mid-run state; finalize writes both.
  - `[low]` `[patch]` (intent 4) The owner of I1/I2 disagrees across the ledger and `home_page.dart:59-60` — patched: the comment names 11.12 for All Projects… and 11.7 for the other two; the deferred-work lines are closed from the Auto Run Result by the dispatcher's ledger commit (the run's convention), not re-mirrored.
  - `[low]` `[reject]` (intent 5) 11.12's non-goals exclude window content, yet the context names 11.12 for passing All Projects… — 11.12 builds `openProjects`, the only action the row can call; the context records where the host lands; Ralph can move it.
  - `[false]` `[reject]` (intent 6) The mirror's same-commit rule cannot be confirmed — a mid-run state; the spec and deferred-work.md land in one commit.

## Design Notes

**Running ahead of 11.12 and 11.13.** The dispatch runs 11.6 before them (epic-11-context Order). The window's content is the deliverable; `MainComponent.projectsWindowFactory` is the seam 11.12's `openProjects` hosts (dialog window `projects`, 900 × 640, minimum 680 × 440, title "Projects"), closing it on `onOpened` and showing it at launch-with-nothing-to-reopen and after `closeProject`; 11.13 binds ⇧⌘O/⌘W/⌘F. Ledger I1 and I2 stay with them (not re-mirrored).

**Window** (Claude's proposals marked in code): row of sidebar (200, right hairline `--fl-border`) and main column (header 52 with bottom hairline; notice; Clone form; tree in a `ZsScrollArea`; drop hint). Version line: "‹version› · Build ‹build›" (the splash's). Footer: caps "Identity", avatar 24 (`--fl-on`, initial), name, email mono; without one the CLI phrase plus "Set identity…" (`ZsLink`, only when `onIdentitySettings` is passed). Notice: a dismissible block under the header (padding 8 12, `--fs-control`, `--text-muted`; a title line — "Could not open ‹name›", "Conversion failed", "Clone failed", "‹path› does not exist." — then `context` and each warning's message verbatim). Empty registry: "No projects yet. Add a directory or drop a folder here." Clone form: inline under the header — URL field, destination field (mono) pre-filled `‹last parent or ~›/‹name›` with the CLI's `clone_destination_for_source` rule, Choose… (picker for the parent), Clone (gold, busy) and Cancel. Offer sheets: `ZsConfirmDialog(tone: standard)` — "Convert ‹name› to a jj repository?" / Convert; "Create a jj repository in ‹name›?" / Create; "Add the enclosing repository ‹root name›?" / Add; body one sentence naming the path. Drop look: hovered row "inside" = 1 px `--accent-live-line` border + `--accent-live-ring` 4 px ring; before/after = a 2 px `--accent-live-line` line at the row's edge, indented to the insertion depth; the hint bar per the export with live tokens. Last opened: < 1 min "now", < 1 h "‹n›m ago", < 24 h "‹n›h ago", calendar yesterday "yesterday", < 7 d "‹n›d ago", < 30 d "‹n›w ago", < 365 d "‹n›mo ago", else "‹n›y ago"; never opened → no "· …". Row heights 28 (group) / 44 (project). Identifiers: `projects-search`, `projects-add-directory`, `projects-clone`, `projects-new-group`, `projects-settings`, `projects-tree`, `projects-row-<i>` and `projects-row-<i>-more` (visible order), `projects-offer`, `projects-clone-url|destination|choose|submit|cancel`.

**Placement mapping.** `TreeInsertionPoint(parent, index)` → `group = parent?.content.id` (null at top level), `index` among that parent's children as the registry sorts them (groups and projects share one order), passed to `registry.move` / `moveGroup` or the session's `{group, index}`.

## Verification

**Commands:**
- `dart run build_runner build --delete-conflicting-outputs` in `app/` -- expected: `main.inject.dart` and the new `.factory.dart` regenerated.
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `packages/zanshin_core`, `packages/zanshin_shell*`, `app/` -- expected: clean.
- `flutter test` in `packages/zanshin_shell*` and `app/` (env as `Makefile.toml` test-flutter) -- expected: all pass.
- `cargo make test` (repo root, unpiped, `PATH` with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0, `coverage-baseline.txt` unchanged.

**Manual checks (if no CLI):**
- Claude's check (project-context "UI tooling"): run the catalogue (`flutter run -d macos -t widgetbook/main.dart` in `app/`), connect Marionette, open each `projects/projects-window/*` use case and `windows/projects-window/projects-window` (then the opened window) in night and paper and inactive, screenshot, and compare with the DS window card, ProjectRow/content card and SearchField rendered full size over `design-system-preview` (Playwright, `scale: "device"`). In the opened window, drag a Finder folder in if possible and press Add directory to see the real NSOpenPanel. Record what was and was not seen in the Auto Run Result.

## Auto Run Result

Status: done (2026-10-18). Blocking condition: none. Code commit: 96edbab9fa6a8d29b47f59ed0c0f345fb45bb439.

**Summary.** The Projects window's content exists on real data, window-agnostic and DI-provided (`MainComponent.projectsWindowFactory` over the singleton `ProjectRegistry` / `ProjectSession` and a `ProjectsEnvironment`): the 200 px sidebar (32 px Nami chip, "Zanshin", the version line "‹version› · Build ‹build›", Projects / Settings… (disabled until 11.7 passes it), the jj identity footer with the CLI's "… not configured." phrases), the 52 pt header ("Projects" at sidebar + 12; search 230 → 120 below 800 wide; Add directory; Clone…, icon-only below 800; New group), a notice for creation reports and failures, and the tree from the registry (ProjectRow per the DS: counts "N · M groups", dots, OPEN, bookmark labels, `~` paths, last opened, ••• and right-click menu with Open / Reveal in Finder / Move to group › / Remove from list, missing rows struck through) with one Tab stop, ↑ ↓ Home End → ← ↩, typeahead and search across groups. Add directory, Finder drops and opens detect first: a jj workspace is registered (canonical path, at the selected group or the drop's `tree_drop.dart` placement) and opened; a Git repository gets the "Convert ‹name› to a jj repository?" sheet (`jj git init --colocate '<path>'`), a plain folder the init sheet (`jj git init --no-colocate '<path>'`), a folder inside a repository the enclosing one; Cancel changes nothing. An inline form clones (`jj git clone --no-colocate`, busy while it runs) with the CLI's destination rules app-side. Rows drag to reorder and regroup; New group names a group inline. `zanshin_shell` gains `chooseDirectory` (NSOpenPanel, a sheet on the view's window) and `revealInFinder`; `zanshin_core` exports the creation result types. The catalogue gains Projects › Projects window (nine states) and Windows › Projects window (a real 900 × 640 window, minimum 680 × 440).

The dispatch ran 11.6 ahead of 11.12 and 11.13 (as 11.5): the dialog window itself (style mask, title, frame, launch window, exit rule), All Projects… and the shortcuts stay with them.

**Inbound ledger items.**
- **I1 — not done.** All Projects… needs a window to open, and the Projects window is 11.12's parentless dialog window (`openProjects`, epics.md:12970); `AppWindows` lives outside DI and no per-window root exists before 11.12. Enabling the row now would offer an action that opens nothing (epic-11-context: "until its verb lands, a UI element stays disabled or absent"). 11.6's part of the path is built — the content and `MainComponent.projectsWindowFactory` that 11.12's host opens (commit 96edbab9fa6a8d29b47f59ed0c0f345fb45bb439) — and `home_page.dart`'s comment now names 11.12 for the row. Already in deferred-work.md ("Surfaced in Story 11.5"); not mirrored again.
- **I2 — partly done** (commit 96edbab9fa6a8d29b47f59ed0c0f345fb45bb439). 11.6's part is in place: the window-agnostic `ProjectsWindow` works as the start window with no project open (its own add, convert, init and clone flows; no OPEN marker), `MainComponent.projectsWindowFactory` builds it over the app's singletons, and `onOpened` tells the host when a project opened (once per dropped batch, so a host closing Projects there never cuts a batch short). Left for 11.12: open Projects at launch when `reopenLast` opens nothing and after `closeProject`, close it from `onOpened`, the exit rule. Already in deferred-work.md; not mirrored again.

**Files changed** (one line each):
- `packages/zanshin_core/lib/zanshin_core.dart` -- exports `CreatedRepoHandle`, `Precondition`, `SnapshotStats`, `UntrackedPath`, `UntrackedReason`, `FileTooLarge`, `FileNotAutoTracked`.
- `packages/zanshin_shell_platform_interface/lib/src/zanshin_shell_platform.dart`, `packages/zanshin_shell_macos/lib/zanshin_shell_macos.dart`, `packages/zanshin_shell/lib/src/zanshin_shell.dart`, `.../Sources/zanshin_shell_macos/{ZanshinShellPlugin.swift,DirectoryPanel.swift}` -- `chooseDirectory` (NSOpenPanel sheet, else modal) and `revealInFinder`.
- `app/lib/src/features/projects/{project_repos,worker_project_repos}.dart` -- the port's convert / init (Git backend) / clone and `ProjectCreation`; `ProjectRepo.handle` is a `RepoHandle`.
- `app/lib/src/features/projects/project_registry.dart` -- `canonicalPath`, `registered`, `group`, `isWithin`, `add(index:)`, `remove`, `moveGroup`.
- `app/lib/src/features/projects/project_session.dart` -- canonical paths, `open` with placement, `add`, `convert`, `initRepo`, `clone` (the CLI's destination rules), `ProjectAdded` / `ProjectRefused`, warnings on `ProjectOpened` / `ProjectOpenFailed`.
- `app/lib/src/features/projects/{projects_environment,projects_window,projects_tree,projects_tree_model,relative_time}.dart` (+ generated `projects_window.factory.dart`) -- the environment port and desktop adapter, the window content, the tree, its model and the time and path labels.
- `app/lib/src/features/projects/projects_module.dart`, `app/lib/main.dart` (+ `main.inject.dart`) -- the registry, session and environment singletons and `projectsWindowFactory`.
- `app/lib/src/features/home/home_page.dart` -- the PLACE comment names 11.12 / 11.7 for the disabled rows.
- `app/widgetbook/{demo_projects_fakes.dart,folders/projects.dart,folders/windows.dart}` -- the demo fakes, Projects › Projects window and Windows › Projects window (and the 11.6/11.7 comment fixed).
- Tests: `app/test/features/projects/{project_registry,project_session,worker_project_repos,projects_window,projects_tree,projects_environment,relative_time}_test.dart`, `app/test/helpers/{fake_projects,fake_projects_environment,recording_shell}.dart`, `app/test/widgetbook/catalogue_smoke_test.dart`, `packages/zanshin_shell*/test/*`.
- Tracking: this spec, `deferred-work.md` ("Surfaced in Story 11.6": 8 items), `epic-11-context.md` (Order and hand-off lines), `sprint-status.yaml` (11-6 done).

**Review findings.** 55 findings (high 0, medium 3, low 46, false 6). Patched 18 entries (1 medium, 17 low): a dropped batch reports its open once, after the batch; toggles are ignored during a search; `~` and relative clone destinations resolve against the home folder and a URL that names no folder leaves the destination empty; the create refusal carries its cause; a clone into a folder listed under another spelling keeps one entry; the inside-Git convert sheet says why; typeahead continues across a space; the picker buttons read "Add" / "Choose"; Clone… is disabled while a clone runs; a blur while the app is inactive no longer cancels the new group's field (proven with a macOS-variant test that fails without the guard); no double slash under `/`; the end drop zone is at least 24 high; `home_page.dart`'s comment; tests for a reorder before a row, the end zone, a drop on an empty window, the drop order, a confirmed offer mid-batch, the row's "open" value, the clone's selected group and the desktop environment adapter. Deferred (new, mirrored): the native picker and Reveal in Finder unverified (medium). Rejected, with reasons in the triage log: focus on click (11.11's pointer rule), synchronous canonicalisation, the hint shifting a scrolled-to-end list, a vanishing Tab stop after pointer scrolling, stale relative labels, `~` in search, VoiceOver actions, string ids, the registry accessor, worker-death errors (5), several failures in one drop, New group under a collapsed ancestor, half opacity after an unmount mid-drag, hand-edited group cycles, a clone failing on the watcher after it succeeded, an unreported cleanup failure, the 11.12 wording, and the 6 false findings.

**Follow-up review recommendation:** false — this first pass patched one medium entry (the batch's `onOpened`) and no high.

**Verification.**
- `cargo make test` (repo root, unpiped, `CARGO_HOME=~/development/sdks/cargo`): exit 0 in this run twice — before the review (app 643 tests; analyze and format clean) and after the review patches (app 655 tests; analyze and format clean); the implementation's own runs covered the core and shell packages and the coverage step (99.49 %, held); `coverage-baseline.txt` unchanged.
- Matrix audit: every row has a passing test — add jj / existing spelling / Git (convert, Cancel, failure) / plain folder / inside a repository (jj and Git) / path gone (`projects_window_test`, `project_session_test`); clone missing, non-empty, empty-existing, failure cleanup, uncreatable destination (`project_session_test`); drops (batch, single, empty window), Remove, Move group into a descendant (`projects_window_test`, `project_registry_test`); search and missing rows (`projects_tree_test`, `projects_window_test`); identity (`projects_window_test`, `projects_environment_test`). The adapter's convert and init ran against the real worker (`worker_project_repos_test`).
**Visual check (2026-10-18, Claude; catalogue via `flutter run -d macos -t widgetbook/main.dart`, Marionette 0.7, DS cards over `design-system-preview` with Playwright at `scale: "device"`).**
- Seen: Projects › Projects window › Tree (night), Narrow 680 × 440 (paper: search 120, Clone… icon-only), Convert offer (night and paper: the sheet with `jj git init --colocate '<path>'`, the body's path with `~`), Clone form (night, not busy), Drop hint (paper, inactive: neutral selection, no focus ring, the hint in the live accent), No identity (night: "Name and email not configured." with "Set identity…"), Search ("backend": the matching group with its subtree, ancestors expanded); Windows › Projects window opened as a real 900 × 640 window (Flutter layer only). Compared with the DS window card (Projects in night and paper) and the content card (ProjectRow). One deviation found and fixed in the run: a group row's count sat mid-row (`Flexible` + `Spacer`), now at the row's end (`margin-left:auto`).
- Not seen: the busy Clone button (the knob is not reachable through `zanshinCatalogue.open`; witnessed by `projects_window_test.dart`), the real NSOpenPanel and a Finder folder drag in the opened window (Marionette taps go to the catalogue's view and cannot drag from Finder; the picker and the drop are witnessed on the channel and in widget tests), the native traffic lights (11.12's window).
- After the review patches (text and state only: the inside-Git sheet sentence, Clone… disabled while busy, the empty destination, the 24 px end zone) the catalogue was not re-rendered; widget tests witness each.

**Residual risks.**
- The native folder picker and Reveal in Finder have run only through their Dart channel (deferred, medium); the running app's successful clone is unverified (deferred, medium).
- Until 11.12 hosts the content, nothing in the app opens Projects; the registry still fills only through settings.json or the catalogue.
