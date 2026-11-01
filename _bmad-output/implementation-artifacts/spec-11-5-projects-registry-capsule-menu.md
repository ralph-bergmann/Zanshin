---
title: 'Story 11.5 — Projects: registry, project capsule, Project menu, switching repositories'
type: 'feature'
created: '2026-10-18'
status: 'done'
baseline_revision: 'f0576ae4c27307242b0cc57004a890937759716a'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      The Project menu's All Projects…, Project Settings… and Settings… rows stay disabled until 11.6 and 11.7 pass their actions; their shortcuts (⇧⌘O, ⌘,) are 11.13's.
    evidence: |-
      11.5 runs ahead of the epics' Sequencing (epics.md:11673-11674: 11.12 and 11.13 come before 11.5); neither the Projects window (11.6 on 11.12) nor the Settings window (11.7) exists. ProjectCapsule takes onAllProjects / onProjectSettings / onSettings as nullable callbacks; null disables the row (epic-11-context "until its verb lands, a UI element stays disabled or absent").
    location: >-
      app/lib/src/features/projects/project_capsule.dart; app/lib/src/features/home/home_page.dart
    severity: low
  - summary: >-
      Without the Projects window, a launch with no project to reopen (none stored, or it is missing) and the close-project action leave the project window open with an empty PLACE island instead of showing Projects as the only window.
    evidence: |-
      epics.md:12266-12268, :12287-12289 (design update witnesses) need 11.12's dialog windows, launch window and exit rule plus 11.6's window; boot opens only the project window (app/lib/src/features/bootstrap/boot_window_host.dart:73-75). The session's reopenLast and closeProject do 11.5's half (handle, registry); nothing shows Projects yet.
    location: >-
      app/lib/src/features/projects/project_session.dart; app/lib/main.dart
    severity: medium
    resolved: >-
      2026-10-19 — fixed (spec-11-12-window-foundation-dialog-windows, commit 0dbd2fb): AppWindowCoordinator shows Projects as the only window at launch with nothing to reopen and after closeProject, closes it on onOpened, and closing it with no project window quits.
  - summary: >-
      The close-project action has no trigger yet, and switching, closing and quitting run no unsaved-Configurations check: ⌘W is 11.13's, the red button's close intercept 11.12's, the "Discard changes?" check 10.22's.
    evidence: |-
      epics.md:12268-12269 (decisions 16.16, 16.21); no window shortcut, menu item or close intercept exists before 11.12 / 11.13, and 10.22 (backlog) owns the dirty Configurations window. ProjectSession.closeProject() and open() are the actions those stories call.
    location: >-
      app/lib/src/features/projects/project_session.dart
    severity: medium
    resolved: >-
      2026-11-01 — fixed (spec-10-22-jj-log-configurations-window, commit b6e20939): ⌘W (11.13) and the red button (11.12) run the close guards; the dirty Configurations window registers its "Discard changes?" guard and ProjectSession.mayLeave asks it before a project switch.
  - summary: >-
      A failed open keeps the current project and records the failure on the session, but nothing shows it: the DS has no design for a repository that will not load.
    evidence: |-
      epics.md:12311 ("shows the error"); deferred-work.md "The DS's 'Still open' list" (a repository that will not load: not a jj repo, a broken .jj, no permission) has no story or design; the sheets are ConfirmDialog and Push only (decision 16.17) and the toast is 10.23 (backlog). ProjectSession.lastFailure holds the outcome and the failure is logged at WARNING (code only).
    location: >-
      app/lib/src/features/projects/project_session.dart
    severity: medium
  - summary: >-
      The status dot has no ahead, behind, diverged or syncing yet: 9.29 (distances) and 11.8 (fetch/push) add those values to ProjectStatus.
    evidence: |-
      epics.md:12339-12345 (design question (a)); 9.29 and 11.8 are backlog. ProjectStatus holds clean, dirty, conflict, missing, stale; an unknown stored value reads as null (JsonKey unknownEnumValue), so a newer file never corrupts an older app's settings.
    location: >-
      packages/zanshin_settings/lib/src/model/projects_settings.dart
    severity: low
  - summary: >-
      The open project's dot refreshes only on jj operations, not on plain file edits, because the watcher reports op heads and the checkout only.
    evidence: |-
      packages/zanshin_core/lib/src/worker/events.dart:17-33; the same gap is 10.5 design question (c) (epics.md:9014-9015), whose refresh policy (window focus, timer, register-snapshot-trigger) Ralph decides.
    location: >-
      app/lib/src/features/projects/project_session.dart
    severity: low
    resolved: >-
      2026-11-01 — fixed (spec-10-12-adopt-backend-layout, commit 6b9feacb): Ralph's refresh rule is complete — window focus (20b5b0d), View › Reload Cmd-R (11.13, 0d7811d) and the in-window Reload button run ProjectSession.refresh().
  - summary: >-
      10.5 receives the open handle from ProjectSession.repo.handle (an OpenedRepoHandle) and refreshes its own graph; 10.5's text still says only that the handle "arrives at init".
    evidence: |-
      epics.md:8970 (10.5 item 1); 11.5 owns opening and switching, so the session is where the handle lives; a switch replaces the session's repo before the old handle closes.
    location: >-
      app/lib/src/features/projects/project_session.dart
    severity: low
    resolved: >-
      2026-10-30 — fixed (spec-10-5-graph-view-model-repo-wiring, commit 5d5548c): RepoGraphSource over ProjectSession.repo (whose ProjectRepo gained events); the epic text is reconciled; wiring into HomePage is 10.12's.
  - summary: >-
      The Project menu has no VoiceOver name: the DS names it "Project", and ZsMenuAnchor names a menu only through subject, which also draws a head the Project menu does not have.
    evidence: |-
      DS components/menus/ProjectMenu.jsx:30 (aria-label "Project"); packages/zanshin_ui/lib/src/controls/zs_menu.dart (ZsMenuPanel's container Semantics(label: subject)); ProjectCapsule passes no subject. Surfaced during the build.
    location: >-
      packages/zanshin_ui/lib/src/controls/zs_menu.dart; app/lib/src/features/projects/project_capsule.dart
    severity: low
    resolved: >-
      2026-10-18 — fixed (spec-11-5-closing-project-menu-voiceover-name, commit 4455307): ZsMenuAnchor takes a semanticLabel apart from the head (the container reads semanticLabel ?? subject), and the capsule passes "Project".
  - summary: >-
      The open project's reading (show of @ plus the topology call, each with the pre-verb snapshot) starts on every op-heads event, so a burst of external jj commands has Zanshin snapshotting between them; whether that can race the CLI into a divergent @ is not measured.
    evidence: |-
      Review pass 2026-10-18 (blind hunter): ProjectSession._refresh reads at once after each OpHeadsChangedEvent (coalescing only events that arrive during a reading); the parallel-agents research (research/technical-parallel-agents-one-working-copy-research-2026-09-30.md) measured divergent @ copies from concurrent jj calls in one working copy. jj's own working-copy lock should serialise the snapshots; no test or measurement shows either way. 10.5 item 3 reloads on every event the same way.
    location: >-
      app/lib/src/features/projects/project_session.dart (_refresh)
    severity: medium (unverified)
    resolved: >-
      2026-10-30 — fixed (spec-10-5-graph-view-model-repo-wiring, commit 5d5548c): measured — bursts of 40, 40 and 80 CLI commands against an open project gave 0 divergent changes and 0 concurrent operations, so no debounce.
  - summary: >-
      One malformed registry entry makes SettingsStore move the whole settings.json aside and reset every setting, the registry included.
    evidence: |-
      Review pass 2026-10-18 (blind hunter): SettingsStore.load decodes the document as a whole and renames it to settings.json.corrupt on a CheckedFromJsonException (packages/zanshin_settings/lib/src/settings_store.dart, _recover); pre-existing store behaviour, but the registry is the first user-made data in the file. Nothing is deleted (the .corrupt file keeps it).
    location: >-
      packages/zanshin_settings/lib/src/settings_store.dart; packages/zanshin_settings/lib/src/model/projects_settings.dart
    severity: low
  - summary: >-
      The adapter's stale mapping (a jj.stale_working_copy read gives the stale dot) is tested only through the isStale predicate and the session's fake, never against a real stale working copy.
    evidence: |-
      Review pass 2026-10-18 (verification gap): app/test/features/projects/worker_project_repos_test.dart covers clean, dirty, conflict, the label and the events with the real worker, but the Dart worker API cannot make a working copy stale (the Rust tests use test_helpers::rewrite_commit_files, crates/zanshin-ffi/tests/snapshot_ffi.rs:190-200; there is no workspace add).
    location: >-
      app/lib/src/features/projects/worker_project_repos.dart (read)
    severity: low
  - summary: >-
      A Project menu opened by keyboard during a running calm phase opens faded: the hold stops a new phase but, by 11.3's rule, does not end a running one.
    evidence: |-
      Review pass 2026-10-18 (intent auditor): calm_controller.dart ("a hold taken during a phase does not end it"); the PLACE group fades and ignores the pointer while calm, but a capsule that kept keyboard focus still opens its menu on ↓, and the menu inherits the island's ZsFade until the phase ends (650 ms after the last scroll). The same holds for every slot's surfaces (10.7, 10.21, 11.8).
    location: >-
      app/lib/src/features/shell/calm_controller.dart; app/lib/src/features/projects/project_capsule.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** The app has no project model: nothing opens a repository, the PLACE slot shows an empty island, and the old projects UI runs on `MockProject`. The bridge exports none of the handle or detect types an open needs.

**Approach:** A persisted project registry in `zanshin_settings`; an app-side `ProjectSession` that detects, opens, switches and closes repositories through a narrow port (real adapter over `ZanshinWorker`), reads the open project's dot and bookmark label, and records them; the project capsule in PLACE with its Project menu on 11.11's Menu (extended for the DS project rows), holding calm while open (ledger I1). Parts that need 11.6/11.7/11.12/11.13 stay disabled or absent (deferred list).

## Boundaries & Constraints

**Always:**
- epics.md Story 11.5 (:12261-12355) is the requirement; its "Design update 2026-10-16" (:12264-12293) supersedes items 2, 4-7, the design questions and witnesses it names; decisions 16.14-16.16, 16.27, 16.28, 16.42 (h, j), 16.43 apply. Precedence: epics decisions > DS tokens/CSS > DS prose/cards > the floating export.
- Detect before open (`ZanshinWorker.detect`): jj → `openRepo`; pathNotFound → missing; git → not opened (11.6 offers conversion); neither with a jj `suggestedRoot` → not opened, the root is reported for the caller to offer; else refused. The backend never opens a suggestion by itself.
- A switch opens the new handle first, swaps the session to it, then closes the old one; a failed open changes nothing about the current project. Opens and closes run one at a time, in call order.
- Status for the open project only: conflict (@'s change is conflicted) > dirty (@ has file changes) > clean, read from one `show(revset: '@', limit: 1)`; `jj.stale_working_copy` from any read → stale (the bookmark label keeps its last value). Bookmark label = the first by name of the local bookmark refs (`remote == null`, kind bookmark) of `graphTopology(revset: 'heads(::@ & bookmarks())')`, null ("—") when none. Other projects show their stored state.
- The registry stores status and label after every reading and before a close/switch; equal values write nothing (`SettingsStore.update`). Paths, names and change ids are logged at FINE only; WARNING lines carry error codes.
- App imports only `package:zanshin_core/zanshin_core.dart`, `package:zanshin_ui/zanshin_ui.dart`, `package:zanshin_settings/zanshin_settings.dart`. SPDX first line, page width 120, `dart analyze --fatal-infos --fatal-warnings` clean; open defaults say "Claude's proposal"; DS literals cite `DS <file>:<line>`. Every colour is a token.
- Text: sentence case except the menu rows as the DS writes them ("All Projects…", "Project Settings…", "Settings…"); the word is "bookmark", never "branch".

**Never:**
- No Projects or Settings window, no dialog-window support, no ⌘W/⇧⌘O/⌘, binding, no close intercept, no dirty-Configurations check, no ahead/behind/syncing states, no error toast or sheet (deferred list); no Workspaces section (16.27); no network access for projects that are not open.
- No Rust or FFI change; no `src/` imports across packages; no golden tests; no edits under `design/` or `design_system/`; never lower the coverage baseline.
- No `ProjectSummary`-style copy of the registry entry: the capsule and menu show `ProjectEntry` values.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Launch, stored project | registry `openProject: /r/a`, detect jj | `a` opens; `current` is a's entry with its first reading; capsule shows it | — |
| Launch, missing | `openProject: /r/gone`, detect pathNotFound | nothing opens; `openProject` → null; `/r/gone`'s status → missing; PLACE = `ShellEmptyIsland` | FINE log |
| Launch, nothing stored | `openProject: null` | no detect, no open | — |
| Switch | `a` open; `open('/r/b')` | order: detect b, open b, read b, `current` = b, notify, close a; a keeps its last status/label; `openProject` = b; b's `lastOpened` = clock (UTC) | — |
| Same project | `a` open; `open('/r/a')` | `ProjectOpened`, no detect/open/close | — |
| Open throws | `open('/r/b')`, `openRepo` throws `jj.repo_not_found` | `ProjectOpenFailed(code, context)`; `current` stays a; `lastFailure` set; registry unchanged | WARNING with the code |
| Path gone | detect pathNotFound, no suggestion | `ProjectNotARepo(pathNotFound)`; entry status missing (if registered); left out of Recent | — |
| Git / neither | detect git, or neither without suggestion | `ProjectNotARepo(git \| neither)`; nothing opened | — |
| Inside a repo | detect neither, `suggestedRoot: /r`, `suggestedKind: jj` | `ProjectInsideRepo('/r', jj)`; nothing opened | — |
| Detect throws | `jj.detect_failed` | `ProjectOpenFailed` | WARNING |
| Reading | @ conflicted / has file changes / neither | conflict / dirty / clean | — |
| Stale | a read throws `jj.stale_working_copy` | status stale, bookmark unchanged | — |
| Other read error | any other code | last state kept | WARNING |
| Label | local refs `zeta`, `alpha`, remote `main@origin`, a tag `v1` | `alpha` | none → null, shown "—" |
| Refresh | `OpHeadsChangedEvent` for the open handle (other handles ignored) | one more reading; events during a reading coalesce into at most one more | — |
| Own snapshot | the reading's snapshot writes an op, its event arrives | exactly one more reading, then quiet | — |
| Recent | 8 entries: open, 1 missing, 1 never opened, 5 others | open first (checked), then 4 by `lastOpened` desc; no missing, no never-opened | — |
| Old file | settings JSON without `projects` | empty registry, file loads | — |
| Newer status | stored `"status": "ahead"` | status null, file loads | — |
| Registry ops | add a, b; add group G; move b into G at 0; move a to index 1; reload store from disk | equal value after reload; sibling orders 0..n per parent | — |

</intent-contract>

## Code Map

- `_bmad-output/planning-artifacts/epics.md:12261-12355` -- Story 11.5 (design update :12264-12293 first); decisions :11558-11561 (16.13-16.16), :11566 (16.21), :11583-11584 (16.27, 16.28), :11610 (16.42 h), :11613 (16.42 j), :11620 (16.43); Sequencing :11673-11674; 10.5's handle and ports :8970-8980.
- `_bmad-output/implementation-artifacts/deferred-work.md:1345-1347` -- inbound I1 (calm hold); `:1179-1181` the sibling-workspace registry question (Ralph's, not touched: the registry is keyed by path).
- DS (`_bmad-output/implementation-artifacts/design_system/`): `components/menus/ProjectMenu.prompt.md:10-12` (300 px, 28 px rows, check column, dot after the name, bookmark in the mono column, order, keys, radio items), `ProjectMenu.jsx:9-23` (Recent header, rows, separators, disabled Project Settings…), `menus.css:13-25` (header, row, cmd 11 px mono `--text-faint`, highlight `--accent`/`--accent-ink`), `:57-62` (`.zs-pm` 300, name gap 8, checked name 600, dot 6, cmd max 130); `components/content/ProjectRow.jsx:5-15` (status keys, tokens, labels: clean "clean", dirty "uncommitted changes", conflict "conflict", missing "path missing", stale "working copy is stale"); `components/brand/NamiMark.jsx` (viewBox 256, tile rx 58 gradient #1d2540→#131831 + radial #dca85b .1 at cx .5 cy .6 r .7, waves with heavy strokes 13/15/17 at ≤ 48 px, round caps), `brand.css:3` + `tokens/effects.css:29, :55` (`--shadow-mark`, chip radius size × .2266); `ui_kits/desktop/kit.css:35-41` + `chrome.jsx:70-77` (capsule: gap 10, padding 0 12 0 8, hover `--fl-hover`, on `--fl-on`, chevron `--text-dim`, name 13/600 max 220, dot 7, menu at top 100% + 10, left 0); `readme.md:190-193, :225`.
- Floating export (`design/`): `float.css:57-64` (capsule), `:205` (focus ring 2 px accent, offset 2), `settings.css:5` (pressed), `app-float.jsx:155-163` (markup, `title` = path, dot only with a status), `settings.jsx:20` (Recent: drop missing, open first, by last opened, 5), `data.js:305-338` (HOME_TREE: nested groups, mixed sibling order).
- `packages/zanshin_core/lib/zanshin_core.dart:9-36` -- barrel; types to add live in `src/worker/handle.dart` (`RepoHandle` :45, `close` :84, `graphTopology` :155, `show` :813, `OpenedRepoHandle` :1154), `src/ffi/repo_detect.dart` (`RepoKind` :13 `{jj, git, neither, pathNotFound}`, `RepoDetectResult` :34 `kind/suggestedRoot/suggestedKind/warnings`), `src/ffi/status.dart:27` (`WorkingCopyStatus`), `src/worker/responses.dart:99` (`ZanshinFfiException` code/context), `src/ffi/change.dart:40` (`ConflictState`), `src/ffi/graph.dart:123-165` (`TopologyRefKind`, `TopologyRef` name/remote/kind; `refsOf(i)` :499, `nodeCount`).
- `packages/zanshin_core/lib/src/worker/isolate.dart` -- `openRepo` :373, `detect` :835 (no repo is not an error; throws `jj.detect_failed`), `events` :359 (broadcast; `RepoEvent.handleId`); `src/worker/events.dart:10-33`.
- `packages/zanshin_core/test/worker/warnings_test.dart:186-206` -- recipe for a conflicted @ (two siblings write `c.txt`, `newChange([left, right])`); worker tests use `ZanshinWorker.start()` + `initRepo(path, backend: 0)`.
- `docs/rust-error-codes.md:80` -- `jj.stale_working_copy` (context `cause\nwc_op\nrepo_op`; every snapshotting read).
- `packages/zanshin_settings/lib/src/model/app_settings.dart:12-35` -- no-migration rule, `@Default` sub-models; pattern `layout_settings.dart:12-25`; `build.yaml` (`checked`, `explicit_to_json`, width header); barrel `lib/zanshin_settings.dart`; `settings_store.dart` (`update` :81 notifies synchronously, skips equal, serialised writes; `load` :37 moves a corrupt file aside); tests `test/model/app_settings_test.dart:18-25, :36-44` (exact `toJson` maps to extend), `:53, :83-95` (old-file / unknown-key / enum patterns), `test/settings_store_test.dart:16-19` (`_darkJson`, compared byte-for-byte at :112, :137). Regenerate with `dart run build_runner build --delete-conflicting-outputs` in the package.
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart` -- `ZsMenuItem` :30-44 (label, text, icon, cmd, shortcut, danger, enabled, checked, radio, mono, submenu, onSelected, identifier), `ZsMenuController` :107-119 (`isOpen` true through the exit, `open({position})` relative to the anchor's top-left), `ZsMenuAnchor` :155-190 (entries, builder, controller, subject, headLeading, blink, onOpen, onClose after the exit, identifier), `_MenuLayout` :319-355, `ZsMenuPanel` min 250 / max 320 :407-408 / :785-797 (not exported), row `_Row` :960-1034 (height 28, `[16 lead | label | cmd, shortcut, ›]`, check `ZI.check` sm `accentText`, `radio` → `inMutuallyExclusiveGroup`); tests `test/controls/zs_menu_test.dart` (`zsHost`, `_openByKey` :79-85, activation :241-254, Esc :187-200).
- `packages/zanshin_ui/lib/src/controls/{zs_control_core.dart:75-97, zs_button.dart:316-449 (ZsIconButton: fills flHover/flOn/flOnHover/flPress, ring), zs_tooltip.dart:53-61 (semantics only when an ancestor of the core)}`; `materials/zs_glass.dart:51-59` (no nesting), `:138-159` (`ZsIsland` bar = height `chromeH` 44, radius `radiusIsland` 14); `icons/zanshin_icon.dart:21, :149+` (`ZI.chevronDown`); `design/zs_colors.dart:933-957` (`projClean`…`projStale`), `:294-310` (`night2`, `nightIcon`, `gold200/400/600`), `:818-894` (fl*, text*, accent*); `design/zs_elevation.dart:219` (`shadowMark`); `design/zs_type.dart` (`fsBase` 13, `fsSm` 11, `fwSemibold`, `cardSubject` :165); `lib/zanshin_ui.dart` (exports).
- `app/lib/src/features/shell/` -- `floating_shell.dart:48-58` ("What a slot must bring"), `:94-95` (`projectCapsule`), `:461-493` (`_CalmGroup`: fade, drift, `IgnorePointer`); `top_bar.dart:87, :103-114` (null slot → `ShellEmptyIsland`; slots measured by max intrinsic width); `shell_scope.dart:38` (`of`, no dependency, asserts); `shell_controller.dart:257-289` (`handleEscape`, `openSurface` → counted `CalmHold`, `reportUserScroll`); `calm_controller.dart:36-54, :105-122`.
- `app/lib/src/features/home/home_page.dart:20-38` (+ `home_page.factory.dart`, generated) -- the shell's slots; `app/lib/main.dart:77, :108-138` (`_startApp`, `MainComponent` modules, `@inject Future<ZanshinWorker> get worker`); `app/lib/main.inject.dart` (generated; `dart run build_runner build` in `app/`); module pattern `app/lib/src/features/bootstrap/icon_module.dart`.
- `app/lib/src/features/bootstrap/boot_window_host.dart:23-26, :73-75` -- `mainWindowKey` 'main', `mainWindowTitle` 'Zanshin', `openMain`; `app/lib/src/features/window/remembered_window_controller.dart:63-64` (doc still offers `project:<path>`; decision 16.42 j: one key); `app_windows.dart:5` (`ignore_for_file` for the internal windowing API), Flutter `widgets/_window.dart:1970-1988` (`WindowScope.maybeOf` → `BaseWindowController`; `WindowController.setTitle` :387).
- `app/widgetbook/{catalogue.dart:24-30, folders/shell.dart:142-171 (FloatingShellDemo; projectCapsule is a `_DemoIsland`)}`; `app/test/widgetbook/catalogue_smoke_test.dart:27-30` (folder names), `:33-47`; catalogue extension `app/widgetbook/catalogue_extension.dart:58-86` (path `<folder>/<component>/<use-case>`).
- App tests: `app/test/features/home/home_page_test.dart:27-123` (local `_ViewModels`, `pumpHome`, four `ShellEmptyIsland`s at (91,4)), `app/test/features/app/zanshin_app_test.dart:22-32, :90-116` (`_HomePageFactory`, `pumpApp`), `app/test/features/shell/floating_shell_test.dart:282` (hold witness pattern), helpers `app/test/helpers/{shell_host.dart, icon_registry.dart, recording_shell.dart}`, `app/test/features/window/app_windows_test.dart:16-23` (`WindowController(size:, constraints:, title:, delegate:)` constructible).
- `Makefile.toml:116-141` -- `test-flutter` pins `JJ_CONFIG`/`GIT_CONFIG_GLOBAL`/`JJ_USER`…, so app tests may boot a real worker (no jj config verbs).

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_core/lib/zanshin_core.dart` -- export `RepoHandle`, `OpenedRepoHandle` (handle.dart), `RepoDetectResult`, `RepoKind` (repo_detect.dart), `WorkingCopyStatus` (status.dart), `ZanshinFfiException` (responses.dart), `ConflictState` (change.dart), `GraphTopologyView`, `TopologyRef`, `TopologyRefKind` (graph.dart) -- the epic's bridge part plus the types the adapter names.
- `packages/zanshin_settings/lib/src/model/projects_settings.dart` (+ `.freezed.dart`/`.g.dart` via build_runner; export from the barrel) -- `ProjectsSettings({@Default([]) List<ProjectEntry> projects, @Default([]) List<ProjectGroup> groups, String? openProject})`, `ProjectEntry({required String path, required String name, String? group, @Default(0) int order, DateTime? lastOpened, @JsonKey(unknownEnumValue: JsonKey.nullForUndefinedEnumValue) ProjectStatus? status, String? bookmark})`, `ProjectGroup({required String id, required String name, String? parent, @Default(0) int order})`, `enum ProjectStatus { clean, dirty, conflict, missing, stale }`; docs per field. `app_settings.dart` gains `@Default(ProjectsSettings()) ProjectsSettings projects`.
- `packages/zanshin_settings/test/{model/projects_settings_test.dart, model/app_settings_test.dart, settings_store_test.dart}` -- round trip (DateTime UTC, enum by name), old file without `projects`, unknown status → null with the rest kept, wrong type → `CheckedFromJsonException`; extend the exact `toJson` maps and `_darkJson`.
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart` -- `ZsMenuAnchor.width` (double?: min = max = width; null keeps 250-320) and `cmdMaxWidth` (double?: cmd ellipsised); `ZsMenuItem.strong` (semibold label, DS menus.css:60), `dot` (Color?: 6 px circle 8 px after the label, DS menus.css:58, :61) and `dotLabel` (String?, joins the row's semantics after the label); on a highlighted row the dot gets a 1 px `accentInk` ring outside it (decision 16.42 h). Docs cite the DS.
- `packages/zanshin_ui/lib/src/icons/zs_nami_mark.dart` (+ export) -- `ZsNamiMark({double size = 28, bool chip = false})`, a leaf render box painting NamiMark.jsx: tile (radius size × .2266) with `nightIcon`→`night2` vertical gradient and the radial `gold400` glow at .1, the three waves in `gold200`/`gold400`/`gold600` (strokes 13/15/17 at ≤ 48 px, else 9/11/13, round caps and joins; `T` = reflected control point); `chip` adds `ZsElevation.shadowMark`; semantics label "Zanshin" (DS `title`; inside the capsule the control core excludes child semantics).
- `packages/zanshin_ui/test/{controls/zs_menu_test.dart, icons/zs_nami_mark_test.dart}` -- width 300 fixed, cmd ellipsis at 130, strong weight, dot paint and its ring only while highlighted, dot label in semantics, existing behaviour unchanged; mark: paints for 28 and 64 (stroke switch), chip shadow, nothing for size 0.
- `app/lib/src/features/projects/project_repos.dart` -- port (Claude's proposal): `abstract interface class ProjectRepos { Future<RepoDetectResult> detect(String path); Future<ProjectRepo> open(String path); }`, `abstract interface class ProjectRepo { OpenedRepoHandle get handle; Stream<void> get changes; Future<ProjectReading> read(); Future<void> close(); }`, `ProjectReading({required ProjectStatus status, String? bookmark})` (stale carries no bookmark); pure helpers `statusOf(...)` (conflict > dirty > clean), `bookmarkLabel(Iterable<TopologyRef>)`, `isStale(ZanshinFfiException)`.
- `app/lib/src/features/projects/worker_project_repos.dart` -- `WorkerProjectRepos(Future<ZanshinWorker>)`: detect/open pass through; `changes` = `events` filtered to `OpHeadsChangedEvent` of this handle; `read()` = `show(revset: '@', limit: 1)` then `graphTopology(revset: 'heads(::@ & bookmarks())', anchors: const [], withTimestamps: false)`; stale → `ProjectReading(status: stale)`; `close()` = handle close.
- `app/lib/src/features/projects/project_registry.dart` -- `ProjectRegistry(SettingsStore)`: `value`, `entry(path)`, `add(path, {name, group})` (name = last path segment, Claude's proposal; appends to its siblings; existing path → no-op), `addGroup(name, {parent})` → id `g<n>` (n = 1 + highest), `move(path, {group, index})` (renumbers old and new siblings 0..n, groups and projects share one order), `recordOpened(path, {at})`, `recordState(path, ProjectStatus?, String?)`, `setOpen(String?)`; `recent({String? open, int limit = 5})` per the matrix. Write failures (`FileSystemException`) are logged and swallowed, as 11.3's layout writes.
- `app/lib/src/features/projects/project_session.dart` -- `ProjectSession extends ChangeNotifier`: `current` (the registry entry of the open path, null when none), `repo` (10.5's handle source), `recent`, `lastFailure`; `open(path) → Future<ProjectOpenOutcome>` (sealed: `ProjectOpened`, `ProjectNotARepo(RepoKind)`, `ProjectInsideRepo(String root, RepoKind kind)`, `ProjectOpenFailed(String code, String? context)`), `closeProject()`, `reopenLast()`; serial queue; coalesced refresh on `repo.changes`; forwards the store's notifications; `clock` injectable; logger `zanshin.projects`.
- `app/lib/src/features/projects/project_status_style.dart` -- colour (`ZsColors.proj*`) and DS label per `ProjectStatus` (ProjectRow.jsx:5-15).
- `app/lib/src/features/projects/project_capsule.dart` -- `ProjectCapsule({required ProjectEntry project, required List<ProjectEntry> recent, required ValueChanged<String> onOpen, VoidCallback? onAllProjects, VoidCallback? onProjectSettings, VoidCallback? onSettings, ZsMenuController? menuController})` (Design Notes "Capsule"); `menuPosition` const; holds calm via `ShellScope.maybeOf(context)?.openSurface()` in the anchor's onOpen, releases in onClose (I1).
- `app/lib/src/features/shell/shell_scope.dart` -- `static ShellController? maybeOf(BuildContext)` (no dependency), for a capsule outside a shell (the catalogue).
- `app/lib/src/features/projects/project_window_title.dart` -- `ProjectWindowTitle({required String title, required Widget child})`: sets the enclosing `WindowController`'s title when it differs (`WindowScope.maybeOf`; `// ignore: invalid_use_of_internal_member` + `// WHY:`); no window → nothing.
- `app/lib/src/features/projects/projects_module.dart` -- `@module ProjectsModule` providing a singleton `ProjectSession(registry: ProjectRegistry(settings), repos: WorkerProjectRepos(worker))` from `SettingsStore` and `Future<ZanshinWorker>`.
- `app/lib/main.dart` (+ regenerated `main.inject.dart`, `home_page.factory.dart`) -- `ProjectsModule` in the component, `@inject ProjectSession get projectSession`; `_startApp` calls `unawaited(component.projectSession.reopenLast())` after the worker (not awaited: the boot does not wait on a repository).
- `app/lib/src/features/home/home_page.dart` -- injects `ProjectSession projects`; `ProjectWindowTitle(title: projects.current?.name ?? mainWindowTitle)` around the shell; PLACE = a `ListenableBuilder` giving `ShellEmptyIsland` without a project, else `ProjectCapsule(project:, recent:, onOpen: projects.open)` (row actions null).
- `app/lib/src/features/window/remembered_window_controller.dart:63` -- doc: the project window keeps the one key `main` (decision 16.42 j).
- `app/test/helpers/fake_projects.dart` -- `FakeProjectRepos` (scripted detect results, open failures, a call log in order, readings, a `changes` controller per repo; `handle` throws `UnsupportedError`).
- `app/test/features/projects/{project_registry_test, project_session_test, project_capsule_test, project_window_title_test, worker_project_repos_test, project_status_style_test}.dart` -- the matrix rows and ACs; `worker_project_repos_test` boots a real `ZanshinWorker` on temp repos (`initRepo` backend 0): clean, dirty, conflicted merge @, a bookmark label, an op-heads event on `changes`, detect pass-through.
- `app/test/features/{home/home_page_test.dart, app/zanshin_app_test.dart, shell/floating_shell_test.dart}` -- the session in HomePage (empty island without a project, capsule at (91,4) with one), `maybeOf`.
- `app/widgetbook/folders/projects.dart` + `catalogue.dart` -- folder "Projects": component "Project capsule" with use cases "States" (clean, dirty, conflict, stale, no status, a long name) and "Menu open" (menu opened after the first frame, five Recent rows across the statuses, one "—"); `folders/shell.dart` puts a `ProjectCapsule` in `FloatingShellDemo`'s PLACE; `catalogue_smoke_test.dart` lists the folder.
- Tracking: `deferred-work.md` (I1 by the ledger convention; "Surfaced in Story 11.5" with this spec's `deferred:` items, same commit as the spec), `epic-11-context.md` (Order and hand-off lines), `sprint-status.yaml` (11-5 done).

**Acceptance Criteria:**
- Given the app with `openProject` stored and a jj repository there, when it launches, then the project window shows the capsule with the project's name, its dot and the window title equal to the name; with nothing stored or the path missing, PLACE shows the 44 × 44 empty island and the title is "Zanshin".
- Given the capsule, when it renders, then it is a 44 px glass island (radius 14, padding 0 12 0 8, gaps 10) holding the 28 px Nami chip, the name in 13/600 cut with an ellipsis at 220 px, the 7 px dot in its `--proj-*` colour (absent without a status) and a `--text-dim` chevron; its tooltip is the path, the dot's is the status label; VoiceOver reads a button named after the project with the status as its value and its expanded state.
- Given a click, ↩, Space or ↓ on the capsule, when the menu opens, then it is 300 px wide, 10 px below the capsule's left edge, the capsule shows `--fl-on` while it is open, and a second click closes it; the menu holds the order Recent header · up to 5 radio rows (open one checked, name semibold, dot after the name, bookmark or "—" in the mono column, cut at 130 px) · separator · All Projects… ⇧⌘O · separator · Project Settings… · Settings… ⌘,, the last three disabled (deferred).
- Given the open menu, when ↑ ↓ Home End or typing a project name are used, then the highlight moves as 11.11's Menu does, a highlighted Recent row's dot shows the `--accent-ink` ring, ↩ on another project switches to it, and Esc closes the menu, returns focus to the capsule and is consumed (an Escape handler above the shell does not run).
- Given the shell with the menu open, when the user scrolls the graph layer past the calm threshold, then calm does not start; after the menu has closed, the same scroll starts calm (ledger I1, 11.5's part).
- Given a real temp repository, when the adapter reads it, then a conflicted merge @ reads conflict, a file edit reads dirty, an empty @ reads clean, a bookmark on @'s ancestor gives its name, and an operation by another handle raises `changes`.
- Given the catalogue, when Projects › Project capsule › States and Menu open and Shell › Floating shell › Slots are opened in night and paper, then they match the DS capsule, menu and Nami chip (Claude's visual check, Verification).
- Given the change, when `cargo make test` runs unpiped, then it passes with the coverage baseline unchanged.

## Spec Change Log

## Review Triage Log

### 2026-10-18 — Review pass
- verdicts: 61 findings — high 0, medium 5, low 42, false 13, maybe-false 1
- findings:
  - `[medium]` `[patch]` (blind 1) `reopenLast` clears `openProject` on any failed launch open, so a transient `ProjectOpenFailed` loses the project to reopen for good (nothing in the app can bring it back before 11.6) — patched: `openProject` is kept on `ProjectOpenFailed`, cleared only for not-a-repo / inside-a-repo outcomes; a session test covers it.
  - `[low]` `[reject]` (blind 2) Non-FFI errors (a dead worker's `StateError`, an empty `show`) leak the new handle, escape `_read`/`_closeRepo` and become unhandled — needs the worker isolate to die mid-call, after which no handle matters; `RepoHandle.close` already swallows the worker-closed `StateError`; `show('@')` resolves @ or throws, never returns empty; catch-alls would guard undemonstrated states.
  - `[low]` `[reject]` (blind 3) Every outcome but `ProjectOpenFailed` is invisible from the Recent menu; `lastFailure` is not cleared on close — a Recent project turning into a Git repo or plain folder is rare, a missing one leaves Recent visibly; nothing reads `lastFailure` before the failure surface (deferred item 4); widening it changes a public type for no user-visible gain yet.
  - `[low]` `[reject]` (blind 4) Paths are not normalised, so `/r/a/`, a symlinked spelling or a relative path makes a second entry — in 11.5 every opened path comes from the registry itself (launch, Recent), so spellings never differ; canonicalising user input is 11.6's add flow (its "no duplicates" witness).
  - `[maybe-false]` `[defer]` (blind 5) Readings start on every op-heads event without a quiet period, racing external CLI bursts — whether Zanshin's snapshots can make @ diverge needs a measurement (jj's working-copy lock should serialise them); medium if true; deferred with what would settle it.
  - `[low]` `[patch]` (blind 6) The reading, open and detect drop their warnings without a trace — patched: the adapter logs each warning's code at INFO on `zanshin.projects`; where warnings show stays 10.5 design question (e).
  - `[low]` `[patch]` (blind 7) `_recordLeaving` and `_reading` are dead: every reading already records the same state — patched: both removed; the class doc says each reading records, so a switch or close leaves the last one in the entry.
  - `[low]` `[reject]` (blind 8) A switch makes four or five separate settings writes, not atomic — each is a no-op-or-small write on the serial store queue; the only inconsistent crash state (new `lastOpened`, old `openProject`) reopens the old project, which is harmless; one combined write needs a new registry API.
  - `[low]` `[reject]` (blind 9) The session re-notifies on every unrelated settings change — such changes are rare (a theme switch, a resize-edge release after 400 ms), and the rebuild is one capsule and a sort of a handful of entries; filtering adds state.
  - `[low]` `[patch]` (blind 10) `menuPosition` hardcodes the 44 px capsule — patched: the open position derives from `ZsMetrics.chromeH` + 10 at open time.
  - `[low]` `[patch]` (blind 11) VoiceOver never hears a Recent row's bookmark (the row's label drops `cmd`) — patched: a row's semantics label is label, dot label, cmd (the DS card's accessible name, e.g. "MyApp uncommitted changes feature/new-ui").
  - `[low]` `[patch]` (blind 12) Test gaps: Project Settings… / Settings… actions unasserted, no HomePage-level Recent switch, unused `readGate` — patched: all three actions counted, a HomePage test switches through `project-menu-recent-1`, `readGate` removed.
  - `[false]` `[reject]` (blind 13) A failed worker start leaves the module's worker future pending forever — `_startApp` awaits the worker before completing it, so a failed start throws out of `_startApp` into the boot's failure screen before any session call or HomePage exists.
  - `[low]` `[reject]` (blind 14) `dispose` while an open is in flight assigns a never-closed handle — the session is the app-wide DI singleton and nothing disposes it in production; only tests dispose, after their opens.
  - `[low]` `[reject]` (blind 15) Missing state is never detected passively (a deleted open project, Recent entries until clicked) — deleting a project's folder is rare; the epic's design question (a) shows other projects' last known state, the click marks it missing and removes the row; a background detect pass is new behaviour, not a correction.
  - `[low]` `[defer]` (blind 16) One malformed registry entry moves the whole settings file aside — pre-existing all-or-nothing store behaviour that the registry now shares; deferred for Ralph.
  - `[low]` `[patch]` (blind 17) `epic-11-context.md`'s Order line marks 11.5 done but still sequences 11.12 and 11.13 before it — patched: the clauses name what still waits on them.
  - `[low]` `[reject]` (edge 1) A non-FFI error after `open` leaks the handle and `_incoming` — same as blind 2.
  - `[false]` `[reject]` (edge 2) An empty `show` makes `.first` throw — `show('@', limit: 1)` resolves @ (one entry) or throws a revset or working-copy error; it cannot return an empty list.
  - `[low]` `[reject]` (edge 3) A non-FFI error in a refresh is an unhandled async error — same as blind 2 (a dead or closing worker, at shutdown).
  - `[low]` `[reject]` (edge 4) `reopenLast`'s non-FFI error is unhandled in `main.dart` — same as blind 2.
  - `[low]` `[reject]` (edge 5) `dispose` during an open or refresh — same as blind 14.
  - `[low]` `[patch]` (edge 6) `dispose` closes with a bare `unawaited(_repo?.close())`, bypassing `_closeRepo`'s handling — patched: it goes through `_closeRepo`.
  - `[false]` `[reject]` (edge 7) A `pathNotFound` result with a suggestion discards the enclosing repository — by design: item 2 says a missing path is the missing state; offering the enclosing repository of a vanished project folder would open something else.
  - `[low]` `[reject]` (edge 8) A first reading that fails for a project stored as missing leaves the dot at "path missing" — a missing project is not in Recent and its launch entry is cleared, so only 11.6's add can reopen it, and then only with a failed first reading; the next reading overwrites the status.
  - `[medium]` `[patch]` (edge 9) A transient launch failure erases `openProject` — same entry as blind 1, patched there.
  - `[low]` `[reject]` (edge 10) A `WatchErrorEvent` silently stops the dot's refresh — showing the degraded state is 10.5's (item 8); a watcher error is rare and the next open re-arms it; a second listener is new behaviour.
  - `[low]` `[patch]` (edge 11) Open, detect and refusal warnings (one-shot config notices) are dropped — same entry as blind 6, patched there.
  - `[false]` `[reject]` (edge 12) A long detect, open or reading blocks later opens behind the session's queue — the worker runs one command at a time and cannot cancel one (epics.md 10.5 item 3), so the queue adds no wait the worker would not impose.
  - `[low]` `[reject]` (edge 13) The same workspace under another spelling gets a second entry — same as blind 4.
  - `[low]` `[patch]` (edge 14) `add` / `addGroup` place a new member at `siblings.length`, not last when stored orders have gaps — patched: 1 + the highest sibling order.
  - `[low]` `[reject]` (edge 15) A `group` / `parent` id that does not exist orphans the member — a caller error (11.6 passes ids it read from the registry); a guard covers an undemonstrated state.
  - `[low]` `[patch]` (edge 16) `int.parse` throws on an overlong `g<digits>` id — patched: `int.tryParse`, a null skipped.
  - `[false]` `[reject]` (edge 17) `recent` with a negative limit throws `RangeError` — every caller passes the constant 5; a programmer error that fails loudly is correct.
  - `[low]` `[patch]` (edge 18) The menu offset ignores the metrics — same entry as blind 10, patched there.
  - `[low]` `[reject]` (edge 19) A click during the menu's 120 ms exit closes again instead of reopening — needs a second click within the exit; tracking the closing phase needs state `ZsMenuAnchor` keeps private.
  - `[low]` `[patch]` (edge 20) `ZsNamiMark` under tight non-square constraints paints top-left — patched: the square tile is centred in the box.
  - `[false]` `[reject]` (edge 21) A negative `size` trips RenderBox assertions — a programmer error that fails loudly in debug.
  - `[false]` `[reject]` (edge 22, claim) A click-opened menu's Esc returns focus to the previous node, not the capsule — a pointer press never focuses a Zs control (11.11), so a click-opened menu returns focus where it was; the AC's focus return is the keyboard path (↩ / Space / ↓), which the capsule tests check.
  - `[low]` `[patch]` (verification gap 1) HomePage's window title is checked only on `ProjectWindowTitle` alone — patched: a HomePage test under a `WindowScope` follows an open and goes back to "Zanshin" after `closeProject`.
  - `[low]` `[patch]` (verification gap 2) HomePage's Recent rows are never driven — patched with blind 12 (a HomePage test activates `project-menu-recent-1`).
  - `[low]` `[patch]` (verification gap 3) Nothing checks that the generated graph gives HomePage the singleton session `_startApp` reopens — patched: an app test builds `MainComponent` and expects HomePage's `projects` to be the component's `projectSession`.
  - `[low]` `[defer]` (verification gap 4) The adapter's stale mapping is tested only through `isStale` — the Dart worker cannot make a working copy stale; deferred until a verb can.
  - `[low]` `[patch]` (verification gap 5) The `OpHeadsChangedEvent` half of `changes`' filter is untested — patched: a real-worker test raises a working-copy heartbeat for the open handle and expects nothing on `changes`.
  - `[low]` `[patch]` (verification gap other 1) `dispose` bypasses `_closeRepo` — same entry as edge 6.
  - `[low]` `[patch]` (verification gap other 2) The test "the old project's operations no longer read once it was switched away from" never emits on the old repository — patched: it emits after the switch and expects no further read.
  - `[medium]` `[defer]` (intent 1) Launch with nothing to reopen shows no Projects window — already deferred item 2 (11.12, 11.6); not added again.
  - `[medium]` `[defer]` (intent 2) The close-project action has no trigger and no dirty check — already deferred item 3 (11.13, 11.12, 10.22).
  - `[low]` `[patch]` (intent 3) Project Settings… / Settings… actions unasserted; "disabled without a project" has no surface — the assertion gap patched with blind 12; the capsule exists only with an open project, so the menu never shows without one.
  - `[medium]` `[defer]` (intent 4) A failed open shows nothing on screen — already deferred item 4.
  - `[low]` `[reject]` (intent 5) HomePage discards the Git / inside-a-repo outcomes; 11.6's hand-off is written only in the epic context — same as blind 3; 11.6 calls `open` from its own add flow and gets the outcomes there.
  - `[low]` `[defer]` (intent 6) 10.5 reads the handle from `ProjectSession.repo` — already deferred item 7.
  - `[false]` `[reject]` (intent 7) No test counts project windows — one window by construction: the session switches the one HomePage in place and creates no window.
  - `[low]` `[patch]` (intent 8) The title is tested only in isolation — same entry as verification gap 1.
  - `[false]` `[reject]` (intent 9) Dirty comes from `show('@')`, not `status()`; stale from the session's own read; temp repositories, not tar fixtures — the spec's Design Notes "Reading" decide the one-snapshot `show` (the same @-vs-parents diff); 10.5 does not exist, so the read error is the stale source; the repositories are real ones built in the test.
  - `[false]` `[reject]` (intent 10) Esc "does not clear the graph's selection" is checked through a stand-in — no graph exists before Epic 10; the observable is that the Esc is consumed, which the test checks.
  - `[low]` `[defer]` (intent 11) A menu opened during a running calm phase stays faded (11.3's hold rule); the I1 test asserts controller state — the hold rule is 11.3's and applies to every slot; deferred.
  - `[low]` `[patch]` (intent 12) `WindowFrameStore.swift:7` still documents the `project:<path>` key — patched: the comment names the one project-window key.
  - `[false]` `[reject]` (intent 13) Item 10's lifecycle edges are neither built nor deferred — the epic assigns them to 11.7 and 11.13 by name.
  - `[false]` `[reject]` (intent 14) No Auto Run Result or commit yet; sprint-status says done while the spec is in review — a mid-run state; finalize writes both in one commit.
  - `[false]` `[reject]` (intent 15) The diff shows no visual check — the catalogue and app checks ran in this run (Verification in the Auto Run Result).

## Design Notes

**Running ahead of the Sequencing.** The dispatch runs 11.5 before 11.12 and 11.13 (epics.md:11673-11674). The core needs neither: registry, detect/open/switch, reading, capsule, menu, title. What needs them is absent or disabled and listed in `deferred:`; the session's `open`/`closeProject` and the capsule's three nullable row callbacks are the seams 11.6, 11.7, 11.12 and 11.13 wire.

**Session.** The registry entry of the open path is the single source of what the capsule shows: every reading writes status and label into it, so "the open project" and "a stored project" are the same `ProjectEntry` type. A switch:

```dart
final repo = await repos.open(path);          // after detect == jj
final reading = await repo.read();            // first reading (failure → last state kept)
await registry.recordState(old.path, ...);    // the old project's last state
registry.recordOpened(path, at: clock()); registry.recordState(path, ...); registry.setOpen(path);
_repo = repo; notifyListeners();               // 10.5 switches here
await oldRepo.close();
```

**Reading.** One `show('@', limit: 1)` gives @'s conflict state and its diff against the merged parents (the same diff `status()` computes, 2.4) from one snapshot; the bookmark revset is the design question (b) recommendation. Local refs only, by name; tags never count.

**Capsule.** `ZsTooltip(path)` › `ZsMenuAnchor(width: 300, cmdMaxWidth: 130, onOpen/onClose: the hold)` › `ZsControlCore(selected: open, ring outside 14, shortcuts ↓ → activate, identifier 'project-capsule')` › a 44 px `ZsGlass(radius 14)` whose state fill (`--fl-hover` / `--fl-on` / `--fl-press`, as `ZsIconButton`) sits under one `Row(gap 10)` [mark, name, dot (own `ZsTooltip`), chevron `md`]. The capsule must answer `getMaxIntrinsicWidth` (bar rule), so no `LayoutBuilder`. If two nested `ZsTooltip`s both show, wrap mark+name and chevron in the path tooltip separately instead (Claude's proposal). Identifiers: `project-capsule`, `project-menu`, `project-menu-recent-<i>`, `project-menu-all`, `project-menu-project-settings`, `project-menu-settings`. The DS row `title` (path) is not built; the capsule carries the open project's path (Claude's proposal).

**Registry order.** Flat lists with `group`/`parent` ids and one `order` per parent shared by groups and projects reproduce HOME_TREE's mixed, nested siblings while keeping each project's fields as the epic names them.

## Verification

**Commands:**
- `dart run build_runner build --delete-conflicting-outputs` in `packages/zanshin_settings`, then in `app/` -- expected: generated files updated, no unused-binding warning beyond the two known ones (deferred-work.md:1360).
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `packages/zanshin_core`, `packages/zanshin_settings`, `packages/zanshin_ui`, `app/` -- expected: clean.
- `flutter test` in `packages/zanshin_settings`, `packages/zanshin_ui`, `app/` (env as `Makefile.toml` test-flutter) -- expected: all pass.
- `cargo make test` (repo root, unpiped, `PATH` with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0, `coverage-baseline.txt` unchanged.

**Manual checks (if no CLI):**
- Claude's check (project-context "UI tooling"): run the catalogue (`flutter run -d macos -t widgetbook/main.dart` in `app/`), connect Marionette, open `projects/project-capsule/states`, `projects/project-capsule/menu-open` and `shell/floating-shell/slots` in night and paper, screenshot, and compare with the DS menus card (ProjectMenu), the window card's capsule and the brand card's 28 px chip rendered full size over `design-system-preview`.
- Run the app with a backed-up-and-restored settings file whose `projects` registers two extracted fixtures (`tiny-3-commits`, `medium-1k-commits` under the scratchpad) with `openProject` set: the capsule shows the project, the menu lists both, a Recent row switches the project (capsule, title), the log shows no WARNING. Record what was and was not seen in the Auto Run Result.

## Auto Run Result

Status: done (2026-10-18). Blocking condition: none. Code commit: d8c86a3b3b09dbdfaa78b4e6ba088f2b3791960b.

**Summary.** The app now has projects. `zanshin_settings` holds the registry (`AppSettings.projects`: flat `ProjectEntry` / `ProjectGroup` lists with one sibling order per parent, `openProject`, `ProjectStatus` clean / dirty / conflict / missing / stale; an unknown stored status reads null). `zanshin_core` exports the handle, detect, status, topology and error types. `ProjectSession` (over the `ProjectRepos` port; `WorkerProjectRepos` is the real adapter) detects before it opens, opens and reads a new project before it switches and closes the old one, runs opens and closes one at a time, reads the open project's dot and bookmark label (`show('@', limit: 1)` and the topology of `heads(::@ & bookmarks())`) on opening and after every jj operation in it (coalesced), writes them into the registry entry, and maps `jj.stale_working_copy` to the stale dot; launch reopens the stored project (a failed open keeps it for the next launch). The project capsule fills the shell's PLACE slot: a 44 px glass island with the 28 px Nami chip (`ZsNamiMark`, new in `zanshin_ui`), the name cut at 220, the 7 px status dot and the chevron; its Project menu is 11.11's menu at 300 px, 10 below the capsule: Recent radio rows (open project checked and semibold, status dot with the accent-ink ring when highlighted, the bookmark or "—" cut at 130) · All Projects… ⇧⌘O · Project Settings… · Settings… ⌘, (the last three disabled until 11.6 / 11.7 pass their actions). The window title follows the project. The catalogue gains Projects › Project capsule (States, Menu open), and the floating-shell demo carries the real capsule.

The dispatch ran 11.5 ahead of the epics' Sequencing (11.12 and 11.13 come first, epics.md:11673-11674); what needs them is disabled or absent and listed in `deferred:` (mirrored in deferred-work.md, "Surfaced in Story 11.5").

**Inbound ledger items.**
- **I1 — fixed for Story 11.5's part** (commit d8c86a3b3b09dbdfaa78b4e6ba088f2b3791960b): the capsule takes `ShellScope.maybeOf(context)?.openSurface()` in its menu's `onOpen` and releases the hold in `onClose` (and on dispose), so calm scrolling cannot start while the Project menu is open; witness "I1: while the menu is open calm scrolling does not start; once it has closed, it does" (`app/test/features/projects/project_capsule_test.dart`), and the capsule opens no other surface (its tooltips are not surfaces under the shell's rule). Left for the bullet's other owners: 10.7, 10.21 and 11.8 hold calm for their own slots; `ZsSelect` / `ZsPopover` gain open callbacks when one of them needs them. A related case the review found — a menu opened by keyboard during a running calm phase stays faded, by 11.3's "a hold does not end a phase" rule — is a new deferral.

**Files changed** (one line each):
- `packages/zanshin_core/lib/zanshin_core.dart` -- exports `RepoHandle`, `OpenedRepoHandle`, `RepoDetectResult`, `RepoKind`, `WorkingCopyStatus`, `ZanshinFfiException`, `ConflictState`, `GraphTopologyView`, `TopologyRef`, `TopologyRefKind`.
- `packages/zanshin_settings/lib/src/model/{projects_settings.dart,app_settings.dart}` (+ generated), `lib/zanshin_settings.dart` -- the registry model and `AppSettings.projects`.
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart` -- `ZsMenuAnchor.width` / `cmdMaxWidth`, `ZsMenuItem.strong` / `dot` / `dotLabel`, the highlighted dot's ring, a row's semantics label = label, dot label, command.
- `packages/zanshin_ui/lib/src/icons/zs_nami_mark.dart`, `lib/zanshin_ui.dart` -- `ZsNamiMark` (tile, glow, three waves with optical stroke sizing, chip shadow).
- `app/lib/src/features/projects/{project_repos,worker_project_repos,project_registry,project_session,project_status_style,project_capsule,project_window_title,projects_module}.dart` -- the port and adapter, the registry, the session, the dot style, the capsule and menu, the window title, the DI module.
- `app/lib/src/features/{home/home_page.dart,shell/shell_scope.dart,window/remembered_window_controller.dart}`, `app/lib/main.dart` (+ `main.inject.dart`) -- PLACE and the title, `ShellScope.maybeOf`, the one frame key's doc, the module and the unawaited launch reopen.
- `app/macos/Runner/WindowFrameStore.swift` -- comment: the one project-window key.
- `app/widgetbook/{catalogue.dart,folders/projects.dart,folders/shell.dart}` -- the Projects folder and the capsule in the shell demo.
- Tests: `packages/zanshin_settings/test/{model/projects_settings_test.dart,model/app_settings_test.dart,settings_store_test.dart}`, `packages/zanshin_ui/test/{controls/zs_menu_test.dart,icons/zs_nami_mark_test.dart}`, `app/test/features/projects/*` (six files, one with the real worker), `app/test/helpers/fake_projects.dart`, `app/test/features/{home/home_page_test.dart,app/zanshin_app_test.dart,shell/floating_shell_test.dart}`, `app/test/widgetbook/catalogue_smoke_test.dart`.
- Tracking: this spec, `deferred-work.md` ("Surfaced in Story 11.5": 12 items), `epic-11-context.md` (Order and hand-off lines), `sprint-status.yaml` (11-5 done).

**Review findings.** 61 findings (high 0, medium 5, low 42, false 13, maybe-false 1). Patched (16 entries; 1 medium): a failed launch open no longer erases `openProject`; dead leaving-write removed; `dispose` closes through the guarded close; the adapter logs warning codes; the menu offset derives from the metrics; a menu row's VoiceOver label carries its command (the bookmark); registry orders take 1 + the highest sibling and overlong group ids are skipped; `ZsNamiMark` centres in a non-square box; tests for all three window rows, a HomePage Recent switch, the HomePage window title, the DI singleton reaching HomePage, heartbeats staying off `changes`, the old project's events after a switch; `WindowFrameStore.swift` and the epic context's Order line reworded. Before the review, the parent's catalogue check found and fixed one defect: the path tooltip showed over the open menu (focus inside the menu counted as focus inside the tooltip); the tooltip now sits inside the menu anchor, with a regression test proven to fail on the old structure. Deferred (new, mirrored): readings racing a CLI burst (medium, unverified), one bad registry entry resetting settings.json (low, pre-existing store behaviour), the real stale mapping untested (low), a menu opened mid-calm staying faded (low). Already deferred at planning (not added again): no Projects window at launch or close, no close trigger or dirty check, no failure UI, 10.5's handle text. Rejected, with reasons in the triage log: non-FFI worker-death errors, invisible non-failure outcomes from Recent, path normalisation (11.6's add flow), the multi-write switch, notifications on unrelated settings, dispose mid-open, passive missing detection, a missing project's failed first reading, the watch-error state (10.5's), orphan groups, a click during the exit fade, and the 13 false findings.

**Follow-up review recommendation:** false — this first pass patched one medium entry and no high; the remaining unverified risk is deferred (the reading race).

**Verification.**
- `cargo make test` (repo root, unpiped, `CARGO_HOME=~/development/sdks/cargo`): exit 0 three times — after the implementation (12 of 27 steps incl. coverage: 99.49 %, held, `coverage-baseline.txt` unchanged; app 515, zanshin_settings 33, zanshin_ui 392, zanshin_core suite under coverage), after the tooltip fix (app 516), and after the review patches (9 of 27 steps: app 525, zanshin_settings 33, zanshin_ui 393, analyze and format clean).
- Matrix audit: every row has a passing test — launch (stored, missing, nothing), switch order, same project, open throws, path gone, git / neither, inside a repo, detect throws (`project_session_test`); readings, stale, other read error, refresh and coalescing, own snapshot (`project_session_test`, `worker_project_repos_test` with the real worker: clean, dirty, conflicted merge @, the label, events of this handle only, heartbeats off); Recent and registry ops with reload (`project_registry_test`); old file and newer status (`projects_settings_test`).
- Seen in the catalogue (Marionette `zanshinCatalogue.open`, screenshots): Projects › Project capsule › States (clean, dirty, conflict, stale, no status, a name cut at 220) and › Menu open in night and paper, the highlighted row's dot ring after ↓, and Shell › Floating shell › Slots with the capsule in PLACE opening its menu and closing on Esc; compared with the DS window card's capsule and the menus card's ProjectMenu (Playwright, device scale) — same anatomy and proportions; the window rows show disabled here by design.
- Seen in the running app (`flutter run -d macos`, settings.json backed up, seeded with two extracted fixtures, restored afterwards): launch reopened `tiny` (clean dot, "—"); the menu listed both with the macOS accent check; `project-menu-recent-1` switched to `medium` (capsule, Recent order, stored `lastOpened`/status in settings.json); the window controller's title read "medium" through the VM service (CGWindowList hides names without screen recording); `jj log -r 'heads(::@ & bookmarks())'` on the medium fixture is empty, matching its "—"; no WARNING in the log.
- Not seen: the native window title in the Window menu / Mission Control, VoiceOver itself, and the paper app window (the catalogue covered paper).

**Residual risks.**
- The window title goes through Flutter's internal windowing API (`WindowController.setTitle`); only the Dart side was observed.
- The reading race with external CLI bursts is unmeasured (deferred).
- Until 11.6 exists, the registry can only be filled by hand; the capsule appears only for a stored project.
