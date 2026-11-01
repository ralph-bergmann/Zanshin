---
title: 'Story 10.22 — jj log Configurations window: structured filters, default search, command preview'
type: 'feature'
created: '2026-11-01'
status: 'done'
baseline_revision: '40c6371fe73b93e7143011160a6270c09b2d0837'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The jj log Configurations window has not been compared against the DS RevsetDialog cards in the running catalogue; only widget tests check it.
    evidence: |-
      Unattended run: the Marionette / Playwright check of the epic's definition of done cannot run in the background. The catalogue use case Windows › Configurations window has no project, so it shows no count and mine() without an email.
    location: >-
      app/lib/src/features/graph/revset_configs/revset_configs_window.dart
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** The graph search (10.21) lists only `jj log` and `all()`; its "Edit Configurations…" row and View › Edit Configurations… ⌥⌘L are disabled, the default search is always `jj log`, and nothing guards unsaved edits when the project switches, closes or the app quits (deferred I1, Story 10.22's part).

**Approach:** Build epics.md Story 10.22 with its design update 2026-10-16: global configurations + default search in `zanshin_settings`, a pure rule→revset builder extension in `zanshin_core`, the search menu listing the default first and every variant, and the `revset-configs` window (list · editor · command preview · footer) opened through `AppWindows`, with a "Discard changes?" sheet in front of its own close and, while dirty, a close guard in front of project switch, project close and quit.

## Boundaries & Constraints

**Always:**
- Store (global, `GraphSettings` in `zanshin_settings`): `revsetConfigs: List<RevsetConfiguration{id, name, op: and|or, rules: [RevsetRule{fn: author|committer|mine|subject|description|files, mode, value, ci, not}]}>` and `revsetDefault: String` = `'log'` | `'all'` | a configuration id. No `base`, no `expr`. A default id that no longer exists reads as `'log'`. List order = menu order.
- Expression (DS `exprOf`, RevsetDialog.jsx:16-27): a rule is `mine()` for mine; text fns `fn(<kind>[-i]:"v")` with kinds substring/exact/glob/regex (`subject(...)`, `committer(...)` added to the builder like `author`); files `files(cwd:"v" | file:"v" | glob:"v")` via `filesRevset` (no `-i`); `not` prefixes `~`; rules with a blank value (except mine) drop out; joined with ` & ` or ` | `; no valid rule → `all()`. Built in `zanshin_core` (`revset_text.dart`), the UI shows/sends its text verbatim. Built-ins count/show their own expression (`jj log` = the effective `logDefaults().log`, `all()`).
- View state (per repository, 10.21): `GraphShownView` gains `GraphLogView` (`{"view":"log"}`, revset null) and `GraphConfigView(id)` (`{"config":id}`). `GraphDefaultSearch` resolves through the store: `log` → null, `all` → `all()`, an id → that configuration's expression. A shown configuration that vanished → the default search.
- Search menu: the default search first, tagged Default; then the other variants in order `jj log`, `all()`, configurations (name + mono expression); then Go to, Filter by, Edit Configurations… (enabled, opens the window). ✕ returns to the default search.
- Window (`revsetConfigsWindowKey`, a new `revsetConfigsWindowSpec`: 880 × 580, min 820 × 460, `WindowFrameMode.full`, `WindowLevel.floatingWhileActive`, not `keepsAppAlive`), opened or brought forward (edits kept) by `AppWindowActions.openRevsetConfigs()` from the menu row, View › Edit Configurations… ⌥⌘L; built on `ZsWindowScaffold(title: 'jj log Configurations')`; it closes with the project window (already done by the coordinator).
- Which project: the window reads the current graph through `AppMenuModel.graph` (`GraphMenuBinding` gains `search`), so count, `mine()`'s email, Apply and OK follow a project switch; with no project the preview shows no count and Apply/OK only save.
- List (240 px): Built-in `jj log` / `jj log -r 'all()'` (read-only, "Built-in · <desc>"), Custom (name + mono expression, "Unnamed" if empty); `Default` tag; selected entry `--accent-soft`; toolbar Add ("New configuration", one `files` prefix rule, name selected), Remove, Duplicate ("<name> copy"), Move up/down; empty text "No custom configurations yet." + "Add configuration".
- Editor: Name `ZsTextField`; Default search row with `ZsSwitch` and hint "Listed first in the search menu — ✕ in the search field returns to it"; for `jj log` while it is the default: locked on, hint "Used whenever no other configuration is the default"; switching off → default `log`. Rule rows: `is`/`~ not` (`ZsChip` not), function `ZsSelect`, mode `ZsSelect` (contains, is exactly, matches glob, matches regex; files: path or folder, exact file, glob), mono value with the DS placeholder, `Aa` toggle (not files), remove; Match all `&` / Match any `|` from two rules; dashed add chips per function; "No filters — shows every commit (`all()`)."; mine reads "authored by <user.email> · user.email".
- Preview: `❯ jj log -r '<expr>'` (shell-quoted by `jjLogCommand`); "**N** of M changes match" — N from `GraphSearchController`'s op-pinned capped batched counts (`wantCounts`/`countOf`), M = `GraphViewModel.total`; a count error shows jj's message instead of the count and marks the rule whose term contains the error span (`revsetSpanUtf16` against the built text); Copy → "Copied" for 1.2 s, copies the shell-quoted command.
- Footer: "Revset reference ↗" opens `https://jj-vcs.github.io/jj/v0.46.0/revsets/` through the menu's `openUrl`; Cancel; Apply enabled only when the draft (configs or default) differs from the store — saves, and when the shown view's expression changed, redraws with exactly one layout request; OK (gold `ZsButtonVariant.primary`) = Apply, show the selected entry (the default → `showDefault`), close. ↩ outside a text field = OK.
- Leaving: Esc, ⌘W and the red button (`AppWindows.setCloseHandler(revsetConfigsWindowKey, …)`) cancel; when dirty they first show `ZsConfirmDialog` "Discard changes?" (body "Your edits to the configurations haven't been applied. Cancel keeps them here.", confirm "Discard changes", destructive) on this window. While dirty the window registers `AppWindows.addCloseGuard`: it brings the window forward, asks the same sheet, resolves true on Discard (draft reset) and false on Cancel. `mayClose()` already gates the project's red button, ⌘W and ⌘Q; a project switch (`ProjectSession.open`, `convert`, `initRepo`, `clone` while another project is open) now asks a `mayLeave` callback first (wired to `windows.mayClose`) and returns a new `ProjectSwitchCancelled` outcome when refused. Esc in an open Select closes only its list.
- The window never writes jj config; strings via `app_en.arb` (jj words, revsets, commands marked `// l10n-ignore:`); controls from `zanshin_ui`.

**Never:** a raw revset rule, `base`/narrowing, Save, writing `revsets.log` or `[revset-aliases]`, per-repository configurations, the docked dialog shell, a scrim.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Expression | rules `author contains "lena" -i`, `~ files glob "*.lock"`, op `&` | `author(substring-i:"lena") & ~files(glob:"*.lock")` | blank value rule dropped |
| Default removed | default = config X, X removed + Apply | default reads `log`; menu's first row `jj log` | — |
| Shown deleted | view = config X, X removed + OK | graph shows the default search | — |
| Apply shown | view = config X, edit X's rule, Apply | store saved, one layout request with the new expression | count error → rule marked |
| Dirty quit | draft dirty, ⌘Q | window forward, "Discard changes?"; Cancel → quit aborted; Discard → quits | — |
| Dirty switch | draft dirty, Open Recent other project | sheet; Cancel → `ProjectSwitchCancelled`, project stays | — |
| Clean close | no edits, Esc | window closes, no sheet | — |

</intent-contract>

## Code Map

- `packages/zanshin_settings/lib/src/model/graph_settings.dart` -- `GraphSettings` freezed (:20); add the two fields + new freezed `RevsetConfiguration`/`RevsetRule` (+ enums) with `fromJson`; regenerate with `dart run build_runner build` (build.yaml sets the format header); export from the package library.
- `packages/zanshin_settings/lib/src/settings_store.dart` -- `update(AppSettings Function(AppSettings))` :81.
- `packages/zanshin_core/lib/src/revset_text.dart` -- `authorRevset` :68 pattern; add `committerRevset`, `subjectRevset`, `revsetNot(term)`, `revsetJoin(terms, {required bool any})` (returns `all()` for none); export in `lib/zanshin_core.dart`; tests `test/revset_text_test.dart`.
- `app/lib/src/features/graph/graph_search_model.dart` -- `GraphShownView` :170 (decode :183), `GraphDefaultSearch` :205, `GraphAllView` :223; add `GraphLogView`, `GraphConfigView`.
- `app/lib/src/features/graph/graph_search_controller.dart` -- `showDefault` :75, `showAll` :81, `_setView` :118, `wantCounts`/`countOf` :252-257, `userEmail` :206, ctor :35; add a configurations source (the store's `GraphSettings`), `showLog()`, `showConfig(id)`, `defaultSearchRevset`, fallback for a vanished config, re-send on a config change that alters the shown expression.
- `app/lib/src/features/graph/graph_search_field.dart` -- `_MenuRow` :53 is fixed; menu rows `_menuList` :818, `_pickMenu` :380, `_currentMenuRow` :360, `onEditConfigurations` :63; restructure to dynamic variant rows.
- `app/lib/src/features/graph/graph_controls.dart` -- `GraphSearchField(search: search)` :136; pass `onEditConfigurations`.
- `app/lib/src/features/graph/graph_ports.dart` -- `jjLogCommand` :555.
- `app/lib/src/features/home/project_graph_host.dart` -- `_Graph` builds `GraphSearchController` (:112-136) and `GraphMenuBinding`; give the controller the settings store; add `search` to the binding.
- `app/lib/src/features/shell/app_menu.dart` -- `GraphMenuBinding` :40; View › Edit Configurations… :442-445 (no `onSelected`), Reload binding pattern :447-455, `openUrl` :97, `_actions`/`_windows` :103.
- `app/lib/src/features/window/app_windows.dart` -- `revsetConfigsWindowKey` :34, `DialogWindowSpec` :55, `projectsWindowSpec` :91, `openOrActivate` :324, `requestClose` :382, `setCloseHandler` :390, `addCloseGuard` :399, `mayClose` :405, `activate`.
- `app/lib/src/features/window/app_window_actions.dart` -- `AppWindowActions` (only `openProjects`); add `openRevsetConfigs()`.
- `app/lib/src/features/window/app_window_coordinator.dart` -- `_show(key, title, build, {dialog})` :231, `_openProjects` :226, `_closeProjectWindow` :176-189, `_showProjectsInstead` :238 (already closes `revsetConfigsWindowKey`).
- `app/lib/src/features/projects/project_session.dart` -- `open` :200, `convert`/`initRepo`/`clone`, sealed `ProjectOpenOutcome` :17 (switch in `reopenLast`); add `mayLeave` + `ProjectSwitchCancelled`; callers `home/home_page.dart:146`, `projects/projects_window.dart:384,493-495,531,717` handle the new outcome (do nothing).
- `packages/zanshin_ui/lib/src/materials/zs_window_scaffold.dart` :42; `controls/zs_confirm_dialog.dart` :40 (declarative, `closing`/`onClosed`; pattern `projects_window.dart:761-788, 1061-1080`); `ZsTextField` :282, `ZsSelect`, `ZsSwitch`, `ZsChip` (toggle/not/add), `ZsButton` (primary), `ZsIconButton`, `ZsTooltip`.
- Design: `_bmad-output/implementation-artifacts/design_system/components/search/RevsetDialog.prompt.md`, `RevsetDialog.jsx` (exprOf :16-27), `search.css` :111-203 (grid `240px 1fr`, rule grid `52px 124px 128px 1fr 26px`, footer); `_bmad-output/implementation-artifacts/design/revset-config.jsx` (texts, placeholders).
- `app/widgetbook/folders/windows.dart` -- `_open` :154, `_OpenProjectsWindow` :144; add the Configurations window; test `app/test/widgetbook/catalogue_windows_test.dart`.
- Tests: `app/test/helpers/fake_windows.dart` (`FakeWindowFactory`), `app/test/features/window/app_windows_test.dart`, `app_window_coordinator_test.dart` (`_Rig` :49), `app/test/helpers/scripted_graph_source.dart` (`requests`), `app/test/helpers/fake_graph_search_source.dart`, `app/test/features/shell/app_menu_test.dart`, `app/test/l10n/hard_coded_strings_test.dart`.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_settings/...graph_settings.dart` (+ generated, test) -- the configuration model and two fields, JSON round trip.
- `packages/zanshin_core/lib/src/revset_text.dart` (+ export, tests, and a real-cdylib parse witness in `test/worker/revset_search_test.dart`) -- committer/subject/not/join.
- `app/lib/src/features/graph/revset_configs/revset_config_expression.dart` (new) -- configuration → expression + per-rule term ranges (for span marking).
- `app/lib/src/features/graph/revset_configs/revset_configs_draft.dart` (new) -- `ChangeNotifier` draft: list ops, selection, default rules, dirty, apply/ok/reset.
- `app/lib/src/features/graph/revset_configs/revset_configs_window.dart` (new) -- the window UI, preview, footer, keys, discard sheet, close handler + close guard registration.
- `graph_search_model.dart`, `graph_search_controller.dart`, `graph_search_field.dart`, `graph_controls.dart` -- views, default resolution, dynamic menu, enabled edit row.
- `project_graph_host.dart`, `app_menu.dart`, `app_window_actions.dart`, `app_window_coordinator.dart`, `app_windows.dart` -- spec, `openRevsetConfigs`, ⌥⌘L, binding `search`.
- `project_session.dart` (+ callers, coordinator/main wiring of `mayLeave`) -- the switch guard (I1).
- `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`) -- strings.
- `app/widgetbook/folders/windows.dart` -- the window in the catalogue.
- `app/test/features/graph/revset_configs/*_test.dart`, search/controller, session, coordinator and menu tests -- the witnesses.

**Acceptance Criteria:**
- Given every function × mode × not × `-i`, and `&`/`|`, when built, then the golden strings match; a blank value drops its rule; no rules gives `all()`.
- Given the list toolbar, when add/remove/duplicate/move, then the list and (after Apply) the search menu order change accordingly.
- Given `jj log` is the default, then its switch is locked on; switching another entry's switch off returns the default to `jj log`; removing the default configuration falls back to `jj log`.
- Given no change, then Apply is disabled; after an edit (incl. only the default) it is enabled; OK saves, switches the view to the selected entry with one layout request, and closes; Apply on the shown configuration sends exactly one layout request.
- Given a fake count port, then the preview shows "N of M"; given an error with a span inside rule 2's term, then rule 2 is marked and the preview shows the message.
- Given a fake `user.email`, then a mine row shows it.
- Given a dirty draft, when Esc / ⌘W / red button / project close / ⌘Q / project switch, then "Discard changes?" shows and Cancel keeps the window, the project and the app; given a clean draft, Esc closes without asking.
- Given the window open with edits, when ⌥⌘L, then the same window comes forward with the edits kept; the spec is 880 × 580, min 820 × 460, floating while active.
- Given configurations saved, when the settings reload (restart) and in a second repository, then the same configurations and default are read.
- Given the search menu, then the default search is first tagged Default and Edit Configurations… opens the window.

## Spec Change Log

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 30 findings — high 0, medium 4, low 19, false 7, maybe-false 0 (the intent-alignment layer's divergences are logged as rows)
- findings:
  - Blind Hunter:
  - `[medium]` `[patch]` rule value fields go stale after a function round trip or a Discard reset (`_syncFields` keyed on id + rule count) — `_syncFields` now also resyncs a controller whose text differs from the draft's value; widget tests for both cases.
  - `[low]` `[reject]` `_save` marks the draft clean before the write is known to work — `SettingsStore.update` keeps the new value in memory on a failed write (settings_store.dart:81 doc), so the configurations stay for the session; the same pattern as `GraphPreferences._write`.
  - `[low]` `[patch]` `mayLeave` asked before `_detect` in `open()` spends a Discard on a target that is not a repo — the question moved after the `_detect` early return; creations and clone unchanged (see the Edge Case row).
  - `[false]` `[reject]` guarding a project switch is unnecessary — the epic's design update 2026-10-16 ("Leaving") and I1 name the switch explicitly.
  - `[false]` `[reject]` "N of M" compares the selection with the shown view — M is `GraphViewModel.total` = `GraphLayout.totalCount` = `topology.allCount`, the count of `all()` (backend_graph_layout.dart:56), as the story says.
  - `[low]` `[reject]` `wantCounts` called from `build()` — idempotent (asked set per (op, expression), one batch per pause); moving it to listeners adds bookkeeping for no observable change.
  - `[low]` `[reject]` an unknown enum or duplicate id in a hand-edited settings file — ids are generated by the draft; hand-editing the settings file is not an everyday path, and the fix is new decoding policy.
  - `[low]` `[reject]` `revsetConfigExpression` repeats `revsetJoin`'s separator to compute ranges — developer-only; the ranges are tested against the joined text, which would fail on drift.
  - `[low]` `[patch]` the Revset reference link uses another host and a second hand-written pin than Help › jj Documentation — derived from `jjDocumentationUrl` (`resolve('revsets/')`).
  - `[low]` `[patch]` the files glob mode reaches the ARB select's `other` arm through an invented key — a real `fileGlob` arm.
  - `[false]` `[reject]` OK writes the settings when nothing changed — `SettingsStore.update` is a no-op for an unchanged value (settings_store.dart:81).
  - `[medium]` `[patch]` list entries cannot be reached or selected by keyboard — entries are focusable, select on Enter/Space, the selected one takes the initial focus; widget test.
  - `[low]` `[patch]` ↩ = OK and a dirty draft across a project switch are untested — tests added (⌘W runs the same close handler as the red button, which is tested).
  - `[false]` `[reject]` the built-ins are labelled differently in the window and the menu — the design labels the list entries `jj log` / `jj log -r 'all()'` (RC:234-255) and the menu rows `jj log` / `all()` (10.21).
  - Edge Case Hunter:
  - `[medium]` `[patch]` value fields keep discarded text after a guard's Discard — same root cause as the Blind Hunter `_syncFields` row; fixed with it.
  - `[medium]` `[patch]` author→mine→author shows the old value while the rule is blank — same root cause; fixed with it.
  - `[low]` `[patch]` Discard then a target that is not a repo — same root cause as the Blind Hunter `mayLeave` row; fixed with it.
  - `[low]` `[reject]` Discard then a failing create/clone — asking after the creation would leave a created-but-unopened project on Cancel, a worse outcome; failures of a creation are rare.
  - `[low]` `[reject]` hand-edited ids `log`/`all` or duplicates — same reasoning as the Blind Hunter settings row.
  - `[low]` `[reject]` a hand-edited mode from the other family shows a blank picker — hand-edited settings only; the expression still uses the builder's fallback kind.
  - `[low]` `[patch]` duplicating an unnamed configuration gives " copy" — the copy name uses "Unnamed" for an empty name.
  - Verification Gap:
  - `[low]` `[patch]` `{"view":"log"}` / `{"config":id}` never decoded in a test — added to the round-trip list in graph_search_index_test.dart.
  - `[low]` `[patch]` the host's `settings:` and `search:` wiring is untested — home_page_test asserts the published binding's `search`.
  - `[low]` `[patch]` the search menu's Edit Configurations… row reaching `openRevsetConfigs` is untested — home_page_test taps the row and counts the call.
  - `[low]` `[patch]` `buildRevsetConfigs` in main.dart is untested — zanshin_app_test checks it builds the window over the component's settings and graph notifier. `[low]` `[reject]` the `mayLeave` assignment in `_startApp` — boot code no test reaches; a seam adds surface for one assignment.
  - Intent Alignment:
  - `[false]` `[reject]` `closeProject()` has no guard at the session level — its only caller (`app_window_coordinator.dart:202`, the red button and ⌘W path) runs `mayClose` first; I1 asks for the guard through `addCloseGuard`/`mayClose`, which is how it is wired.
  - `[low]` `[reject]` the tests stop at the `mayClose`/`mayLeave` seams, not the user triggers — the triggers' own tests (coordinator red button refusal, worker lifecycle quit refusal) already prove they call `mayClose`; the patched wiring tests close the remaining gaps.
  - `[false]` `[reject]` "ask first, then close with the project window" ordering untested — the existing coordinator test "a close guard that refuses keeps the project and the window" covers it.
  - `[false]` `[reject]` guarding `initRepo`/`convert`/`clone` is wider than I1 — each switches away from the open project, the epic's "a project switch"; scope consistent, not a defect.

## Design Notes

- The default search stays a symbolic view (`GraphDefaultSearch`); its revset is resolved at request time from the store, so changing the default redraws only repositories showing the default (and only through the current project's controller).
- Span → rule: `revset_config_expression.dart` returns the joined text plus each kept rule's `[start, end)` UTF-16 range; the error span converted by `revsetSpanUtf16` selects the rule whose range overlaps it.
- Built-in `jj log` description: 10.21's `graphSearchLogDetail`; `all()`: `graphSearchAllDetail`.

## Verification

**Commands:**
- `dart test` in `packages/zanshin_core` (revset_text + worker witness) -- pass.
- `flutter test` in `packages/zanshin_settings` -- pass.
- `flutter test test/features test/widgetbook test/l10n test/app` in `app` -- pass.
- `dart analyze --fatal-infos .` and `dart format --set-exit-if-changed -o none .` in app, zanshin_core, zanshin_settings -- clean.
- No Rust change: no cargo checks, codegen, parity oracle; no full gate or coverage (story-loop gate rule).

**Manual checks (if no CLI):**
- Marionette/Playwright check of the window against the DS cards is not possible unattended; record it as deferred.

**Verification notes (run 2026-11-01, gate rule of the story loop: no full gate; env pinned as `cargo make` does: JJ_*, GIT_CONFIG_GLOBAL, ZANSHIN_LOG_DIR, XDG_CONFIG_HOME=target/test-xdg-config):**
- `flutter test test/features test/widgetbook test/l10n test/app` (app) -- 1687 passed before the review patches, 1694 after.
- `dart test` (packages/zanshin_core, real cdylib, incl. the builder parse witness) -- 1186 passed.
- `flutter test` (packages/zanshin_settings) -- 40 passed.
- `dart analyze --fatal-infos .` -- no issues in app (incl. widgetbook), zanshin_core, zanshin_settings; `dart format --set-exit-if-changed -o none .` -- 0 changed in all three.
- Not run: cargo test/clippy/fmt (no Rust changed), `cargo make codegen` (no FFI or schema change), the parity oracle (no jj verb changed), the full gate and coverage (the loop runs them once at its end), the Marionette visual check (deferred).
- Without the env pins, 5 real-worker tests in `worker_project_repos_test.dart` fail with "XDG_CONFIG_HOME is not pinned" — environment, not this change.

## Auto Run Result

Status: done (commit b6e2093950abebcc25d2f794b1b0ac045dd0f4d9; review patches included in it).

**Summary.** jj log Configurations is a window of its own (`revset-configs`, 880 × 580, min 820 × 460, floating while active, frame remembered), opened or brought forward by the search menu's Edit Configurations… row and View › Edit Configurations… ⌥⌘L. Configurations (name, & / |, rules over author, committer, mine, subject, description, files with is / ~ not, mode, value, `Aa`) and the default search (`jj log`, `all()` or a configuration) are global in `GraphSettings`; the window edits a draft with list ops, the default-search switch rules, a command preview with an op-pinned capped "N of M" count and the failing rule marked by jj's span, Copy, Revset reference ↗, Cancel, Apply (dirty only, redraws the shown view once) and OK (saves, shows the selected entry in one request, closes). The search menu lists the default first, tagged Default, then `jj log`, `all()` and the configurations; a vanished configuration falls back to the default search. Esc, ⌘W and the red button ask "Discard changes?" when dirty; while dirty a close guard asks before a project switch, a project close and a quit.

**Files.**
- `packages/zanshin_settings/lib/src/model/graph_settings.dart` (+ generated, tests) -- `RevsetConfiguration`, `RevsetRule`, `revsetConfigs`, `revsetDefault`, `effectiveRevsetDefault`.
- `packages/zanshin_core/lib/src/revset_text.dart` (+ export, tests) -- `committerRevset`, `subjectRevset`, `revsetNot`, `revsetJoin`.
- `app/lib/src/features/graph/revset_configs/revset_config_expression.dart` -- configuration → expression + per-rule UTF-16 ranges.
- `app/lib/src/features/graph/revset_configs/revset_configs_draft.dart` -- the draft (list ops, selection, default rules, dirty).
- `app/lib/src/features/graph/revset_configs/revset_configs_window.dart` -- the window, preview, footer, keys, discard sheet, close handler, close guard.
- `app/lib/src/features/graph/graph_search_model.dart`, `graph_search_controller.dart`, `graph_search_field.dart`, `graph_controls.dart` -- `GraphLogView`, `GraphConfigView`, default resolution through the settings, data-driven menu rows, enabled edit row.
- `app/lib/src/features/window/app_windows.dart`, `app_window_actions.dart`, `app_window_coordinator.dart` -- `revsetConfigsWindowSpec`, `openRevsetConfigs`.
- `app/lib/src/features/shell/app_menu.dart`, `app/lib/src/features/home/project_graph_host.dart`, `app/lib/main.dart` (+ inject) -- ⌥⌘L, `GraphMenuBinding.search`, the window's content, `mayLeave` wiring.
- `app/lib/src/features/projects/project_session.dart`, `projects_window.dart` -- `mayLeave`, `ProjectSwitchCancelled`.
- `app/lib/l10n/app_en.arb` (+ generated) -- strings.
- `app/widgetbook/folders/windows.dart` -- Windows › Configurations window.
- Tests: `app/test/features/graph/revset_configs/*`, search controller/field/index, window coordinator, home page, app menu, zanshin_app, catalogue windows.

**Deferred work items given to this story.**
- **I1 — fixed (b6e2093950abebcc25d2f794b1b0ac045dd0f4d9).** While its draft is dirty the Configurations window registers a guard through `AppWindows.addCloseGuard`: it brings the window forward and asks "Discard changes?" (Cancel refuses, Discard drops the edits). `mayClose` already ran in front of the project window's red button and ⌘W (`closeProject()`'s only caller) and ⌘Q (`mayQuit`); a project switch now asks too: `ProjectSession.mayLeave` (wired to `windows.mayClose`) is asked by `open()` (after the target is known to be a jj workspace), `convert`, `initRepo` and `clone`, and a refusal returns `ProjectSwitchCancelled` with the current project kept. The window's own Esc, ⌘W and red button ask the same question first.

**Review.** One pass, 30 findings: 0 high, 4 medium, 19 low, 7 false, 0 maybe-false. Patched entries by verdict: 2 medium (stale value fields — 3 rows of one root cause; keyboard-unreachable list entries), 9 low (the switch question after detection, the shared docs URL, the `fileGlob` ARB arm, "Unnamed copy", and tests: ↩ = OK, a dirty draft across a project switch, the log/config view round trip, the host's `search` binding, the menu's Edit Configurations… row, `buildRevsetConfigs`). Deferred: none from the review (the visual check is the implementer's deferral). Rejected rows and their reasons are in the triage log.

**Follow-up review: recommended.** Two medium entries were patched. The unverified risk: the list entries' new keyboard focus (`FocusableActionDetector`, autofocus moved off the window root) interacts with ↩ = OK and Esc — clicking empty window space does not refocus the root, so ↩ after a click elsewhere is untested.

**Residual risks.**
- No visual check against the DS RevsetDialog cards (deferred).
- `Aa` sits beside the value field rather than inside it; the `~ not` chip has a 52 px minimum, so rule rows can shift slightly.
- Hand-edited settings with unknown enum values or duplicate ids are not tolerated (rejected low).
