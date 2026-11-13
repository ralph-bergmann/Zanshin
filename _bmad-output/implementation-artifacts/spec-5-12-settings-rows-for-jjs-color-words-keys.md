---
title: 'Story 5.12 — Settings rows for jj''s three color-words keys; the Zanshin style names similar'
type: 'feature'
created: '2026-11-13'
status: 'done'
baseline_revision: '81ac413b14bd5efc7305f6620302c6af6743a2ec'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** jj's diff keys `diff.color-words.context`, `.conflict` and `.max-inline-alternation` change every diff Zanshin shows, but they can only be set in a config file. The "Zanshin" word-mark hint does not say where its marks come from (the `similar` library).

**Approach:** Settings › General › Diffs gets three jj rows (user scope, like the Identity rows) with existing controls, the Zanshin hint names `similar`, and every jj config write reloads the open inspector diff and the open operation view once.

## Boundaries & Constraints

**Always:**
- Rows of the Diffs group, in order: Layout, Changed words, Inline changes (only while "jj" is chosen), Context lines, Conflicts. Each new row carries its jj key (`configKey`).
- Identifiers `settings-diff-context`, `settings-diff-inline`, `settings-diff-conflict`.
- Controls: Context lines = `ZsSelect` with `0, 1, 2, 3, 5, 10, 20`; Inline changes = `ZsSelect` with Never (`0`), Up to 1, Up to 2, Up to 3, Up to 5, Always (`-1`); Conflicts = `ZsSegmented` "As markers" (`materialize`) / "In pairs" (`pair`). An effective number outside a list is added as its own option, in order, chosen.
- A choice always writes `vm.setConfig(ConfigScope.user, key, '<value>')`, also when it equals jj's default. No row unsets.
- Hints (one line each): Zanshin "Marks whole changed words, using the similar library. Removed lines come first." (jj hint unchanged); Context lines "Unchanged lines shown around each change."; Inline changes "How often a line may switch between removed and added words before it shows as an old and a new line. Experimental in jj."; Conflicts per value: "A conflicted side is compared as its text with conflict markers. Experimental in jj." / "Each pair of conflict sides is compared on its own. Experimental in jj."
- A value from jj's defaults or the user config shows no source note; another layer (environment, system) appends the existing "From ‹scope› config" note after the hint. With an open project whose effective value comes from its repo or workspace config, the hint also appends "The open project sets its own value."
- With no entry at all the rows show jj's defaults: context `3`, conflict `materialize`, inline `3`.
- A value jj cannot read (context not an integer ≥ 0, inline not an integer ≥ −1, conflict not `materialize`/`pair`) shows no chosen option and the error line "jj can't read ‹raw TOML value›."; a write error (`vm.errors[key]`) takes precedence. A choice overwrites it.
- Colours, the diff itself, the design system and the click-dummy stay as they are.
- Tests never write a real jj config: they use the fakes the neighbouring settings tests use.

**Never:** rows in the Project tab or a layer choice per row; unsetting from a row; free number entry; other diff keys; Rust, FFI, `packages/zanshin_core` or `packages/zanshin_settings` changes (unless `config_set` cannot write `-1`, `0` or `pair` so the diff reads it — verified it can: `crates/zanshin-jj/src/config_cmd.rs:621` `parse_value_or_bare_string`, the CLI's rule).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fresh config | no entries | Context `3`, Conflicts "As markers", with jj style Inline "Up to 3"; no source note | — |
| Style switch | Changed words Zanshin → jj | Inline row absent → present right below Changed words; Zanshin hint names similar | — |
| Writes | pick `10` / Never / Always / In pairs | calls `set user diff.color-words.context 10`, `…max-inline-alternation 0`, `… -1`, `…conflict pair`; row shows the new value | — |
| Reload | any jj config write (row or config-file page save) | inspector focused diff reloads once; open operation view re-reads its selection once | — |
| Off-list value | effective `context = 7` | option `7` chosen, between `5` and `10` | — |
| Unreadable | `context = "many"` | no option chosen; error line names `"many"`; picking `3` writes and clears it | row does not fail |
| Project override | open project, repo config sets context | General row shows the user value + "The open project sets its own value." | no project / no such value → no note |
| Other layer | context from env layer | hint ends with "From environment config" | — |
| Failed write | `configFailure` set | error under the row, old value kept | `errors[key]` |

</intent-contract>

## Code Map

- `app/lib/src/features/settings/settings_view_model.dart` -- `SettingsKeys` :23-47: add `diffContext`, `diffConflict`, `diffInline` consts and put them in `general` and `project` (the project read is only for the override note; `_reread` :676-691 then refreshes both after a write). Add `bool projectSetsOwn(String name)` (effective project entry's source is `repo` or `workspace`; false without a project since `projectConfig` is empty). `effective` :437.
- `app/lib/src/features/settings/general_tab.dart` -- Diffs group :162-199 (Changed words row :180-197 hint switch); Identity rows :200-225 are the jj-row pattern (`settingsSourceHint` :15-27, `configKey`, `vm.errors[key]`, `vm.setConfig(ConfigScope.user, …)`). `ZsSelect` usage pattern: Zoom row :112-128. `SettingsRow` has `hint`, `error`, `configKey` (`settings_widgets.dart:95-131`).
- `packages/zanshin_ui/lib/src/controls/zs_select.dart:110-131` / `zs_segmented.dart:89-134` -- a `value` matching no option shows "—" / no segment (safe for the unreadable case; use `int?` / `String?` type args).
- `app/lib/src/features/graph/graph_inspector.dart` -- `_settingsChanged` :236-264 holds the marks reload (keep `_previousDiff`, clear focus, `_loadFocus()`, notify); extract it into a public `configChanged()` the marks branch also calls.
- `app/lib/src/features/home/project_scope.dart` -- `ProjectScope` ctor :200-205 wires `_environment.configWrites.addListener(reasons.invalidate)`; add `inspector.configChanged` the same way and remove it in `dispose` :253-264. `operationChangesSource` provider :171-173 passes `environment.configWrites` to the source.
- `app/lib/src/features/undo_timeline/operation_changes.dart` -- `OperationChangesSource` :31-49 gains `Listenable get configWrites`; `RepoOperationChangesSource` :52 takes it; `OperationChangesModel` ctor :98-103 listens, `_settingsChanged` :173-187 marks branch (`_read(index, keep: _focused)`) is the reload to reuse; `dispose` :383 removes the listener.
- `app/lib/src/features/projects/projects_environment.dart:35-60,73-80,150-190` -- `configWrites` fires once after every `configSet`, `configUnset` and config-file write (the config-file page's save goes through it), so it is the reload trigger for both rows and the file page.
- `app/lib/l10n/app_en.arb:1471-1482` -- strings next to `settingsDiffMarks…`; regenerate with `flutter gen-l10n` (generated `app_localizations*.dart`).
- Fakes: `app/test/helpers/fake_projects_environment.dart:98-117` (`configSet` quotes every value; must store integers bare like jj's `parse_value_or_bare_string`), `app/test/helpers/fake_undo_timeline.dart:14-15,104` (`FakeOperationChangesSource`), `app/widgetbook/folders/undo_timeline.dart:148` (`_DemoChanges`).
- Tests: `app/test/features/settings/settings_window_test.dart` (General group :46-217, `_entry` helper :40, `SettingsRig` in `test/helpers/settings_rig.dart`), `app/test/features/graph/graph_inspector_test.dart` (marks reload tests), `app/test/features/undo_timeline/operation_changes_test.dart:443-460`.
- DI: `app/lib/main.inject.dart` / `test/helpers/test_component.inject.dart` are generated — rerun `dart run build_runner build` in `app/` if a provider's parameters change.

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/settings/settings_view_model.dart` -- the three keys in `SettingsKeys` (`general` + `project`), `projectSetsOwn`. -- reads and the override note.
- `app/lib/src/features/settings/general_tab.dart` -- the three rows and the reworded Zanshin hint, value parsing (TOML text → int / string, unreadable → null + error line), off-list options, hint composition (base hint, source note except for `defaults`/`user`, project note). -- the UI.
- `app/lib/l10n/app_en.arb` + `flutter gen-l10n` -- labels, option labels, hints, "The open project sets its own value.", "jj can't read {value}.". -- strings.
- `app/lib/src/features/graph/graph_inspector.dart`, `app/lib/src/features/home/project_scope.dart` -- `InspectorViewModel.configChanged()` wired to `configWrites`. -- inspector reload.
- `app/lib/src/features/undo_timeline/operation_changes.dart`, `project_scope.dart` provider, `test/helpers/fake_undo_timeline.dart`, `widgetbook/folders/undo_timeline.dart` -- `configWrites` on the source; the model re-reads its selection on it. -- operation view reload.
- `app/test/helpers/fake_projects_environment.dart` -- store integer values bare. -- fake matches jj.
- `app/test/features/settings/settings_window_test.dart`, `graph_inspector_test.dart`, `operation_changes_test.dart` -- one test per matrix row (settings), `configChanged` reloads the focused diff once (inspector), a `configWrites` notification re-reads the selection once (operation view). -- witnesses.

**Acceptance Criteria:**
- Given Settings › General, when it renders, then the Diffs rows appear in the order Layout, Changed words, [Inline changes], Context lines, Conflicts, each new row showing its jj key, and the Zanshin hint names the similar library.
- Given a project window with an open diff and an open operation view, when any jj config write lands (a row or the config-file page), then each reloads its diff exactly once.

## Spec Change Log

## Review Triage Log

### 2026-11-13 — Review pass
- verdicts: 22 findings — high 0, medium 2, low 16, false 3, maybe-false 1
- findings:
  - `[medium]` `[patch]` (verification-gap) ProjectScope's `configWrites` → `inspector.configChanged` wiring and its removal on dispose are untested — patched: a scope test in `project_graph_host_test.dart` fires the environment's `configWrites`.
  - `[medium]` `[patch]` (verification-gap) The `operationChangesSource` provider passing `environment.configWrites` is untested — patched in the same scope test.
  - `[low]` `[reject]` (verification-gap other) Every config write reloads the inspector diff, `user.name` too — accepted cost, recorded in Design Notes; `ConfigWrites` carries no key and a file save can change any key.
  - `[low]` `[reject]` (blind) The Inline row is hidden under Zanshin, so an unreadable `max-inline-alternation` (which fails every diff, `config.rs:1568-1579`) shows no error there — real but rare (a hand-edited `-5`); the inspector shows jj's own refusal; showing the row on error adds a branch.
  - `[low]` `[reject]` (blind) TOML integer forms `1_0`, `0o7`, `0b1` read as unreadable — rare for these keys; a TOML integer parser adds code.
  - `[low]` `[reject]` (blind) Every write reloads the diffs whatever the key — same as the verification-gap other row.
  - `[maybe-false]` `[reject]` (blind) The inspector reloads only the focused diff while the operation view re-reads its summary too — whether `conflict = pair` changes summary ± counts is unchecked (would settle: a summary diff of a conflicted file in both modes); if true only stale ± counts until the next selection (low).
  - `[low]` `[patch]` (blind) ProjectScope wiring untested — grouped with the first verification-gap row.
  - `[low]` `[patch]` (blind) Missing Settings cases (unreadable conflict, off-list Inline with Always last, `workspace` project note) — patched: tests added.
  - `[low]` `[patch]` (blind) The fake's comment claims `parse_value_or_bare_string` but keeps only integers and arrays bare — patched: comment narrowed.
  - `[low]` `[patch]` (blind) The widgetbook stub uses `AlwaysStoppedAnimation` as a listenable — patched: a `ConfigWrites` field.
  - `[low]` `[patch]` (blind) The `SettingsGeneralTab` doc line runs past 120 columns — patched: wrapped.
  - `[low]` `[patch]` (blind) jj's defaults are repeated as fallbacks — patched: a comment says they mirror jj-cli's built-in defaults at v0.47.0 and apply only when no layer lists the key.
  - `[low]` `[reject]` (edge-case) TOML integer forms — same as the blind row.
  - `[false]` `[reject]` (edge-case) The project note is missing when the repo sets the key but an environment layer wins — the story's rule is "its stack takes the key from its repo or workspace config"; with an environment layer winning, the project does not take it from there, so no note is correct.
  - `[low]` `[reject]` (intent) The reload is wired on `ProjectsEnvironment.configWrites`, not in the settings view model — same observable behaviour (each write reloads once, a file save too); recorded in Design Notes.
  - `[low]` `[reject]` (intent) The reload fires for any key, not only the three — same as the verification-gap other row.
  - `[low]` `[patch]` (intent) No seam test from a config write to both diffs — grouped with the verification-gap rows.
  - `[false]` `[reject]` (intent) The `-1` / `0` / `pair` round-trip is assumed at the fake only — `config_cmd.rs` `parse_value_or_bare_string_matches_the_cli_table` asserts `parse("-1")` is an integer; the fake mirrors that rule for integers and bare strings.
  - `[low]` `[patch]` (intent) A `defaults`-source entry is untested (only a missing entry) — patched: a test asserts no source note for it.
  - `[false]` `[reject]` (intent) "Without an open project, no note" is not asserted — the fresh-config test matches the exact hint text with no project open, which fails if a note were appended.
  - `[low]` `[reject]` (intent) The Marionette UI witness is not in the diff — by design; the loop's main session runs it.

## Design Notes

- **Reload trigger:** `ProjectsEnvironment.configWrites` instead of a new path from the settings view model. It already fires once after every set, unset and config-file write, and `ProjectScope` already uses it for `ImmutableReasons`. It carries no key, so any jj config write reloads the open diff (an Identity write too); a reload is one diff read and keeps the old diff on screen while it loads, so the superset is cheap and also covers a file-page save that changes any diff key.
- **Unreadable value:** the select shows no chosen option so that picking jj's default (`3`) still counts as a change (`ZsSelect` skips `onChanged` for the chosen value).

## Verification

**Commands:**
- `flutter gen-l10n` in `app/` -- expected: generated files updated, committed.
- `dart analyze` and `dart format --set-exit-if-changed .` in `app/` -- expected: clean.
- `flutter test test/features/settings/ test/features/graph/graph_inspector_test.dart test/features/undo_timeline/` in `app/` -- expected: pass.

**Manual checks (if no CLI):**
- Marionette on the real app with its own `JJ_CONFIG` file -- by the loop's main session, not this run.

**Verification notes** (2026-11-13, story run; the full gate is not run here, per the story loop's rule):
- `flutter gen-l10n` and `dart run build_runner build` in `app/` — ran clean; `app_localizations*.dart`, `lib/main.inject.dart`, `test/helpers/test_component.inject.dart` regenerated.
- `dart analyze` in `app/` — no issues; `dart format --set-exit-if-changed .` — 0 files changed (before and after the review patches).
- `flutter test test/features/settings/ test/features/graph/graph_inspector_test.dart test/features/undo_timeline/` — pass (232), before the review patches.
- After the review patches: `flutter test test/features/settings/ test/features/graph/graph_inspector_test.dart test/features/undo_timeline/ test/features/home/` — pass (273).
- No Rust, FFI or `packages/*` change, so no cargo check, codegen or parity run.
- The implementer's wider `flutter test` from `app/` saw 4 failures in `test/features/projects/worker_project_repos_test.dart` (imports nothing this story changed; the run printed "File modified during build. Build must be rerun." — the real cdylib was rebuilding; Story 5.11 recorded the same file failing outside `cargo make test-app`). Left to the loop's final gate.
- Not run: the Marionette witness on the real app (the loop's main session).

## Auto Run Result

Status: done

**Summary.** Settings › General › Diffs gains three jj rows at user scope — Inline changes (only under the jj style), Context lines, Conflicts — with their jj keys, off-list and unreadable-value handling, the source note and the "The open project sets its own value." note. The Zanshin hint names the similar library. Every jj config write (a row or the config-file page) reloads the inspector's focused diff and the open operation view once, through `ProjectsEnvironment.configWrites`.

**Files changed** (under `app/`):
- `lib/src/features/settings/settings_view_model.dart` — the three keys in `SettingsKeys.general` / `project`; `projectSetsOwn`.
- `lib/src/features/settings/general_tab.dart` — the rows, value parsing, hints and error line.
- `lib/l10n/app_en.arb` (+ generated `app_localizations*.dart`) — the strings, the reworded Zanshin hint.
- `lib/src/features/graph/graph_inspector.dart` — `InspectorViewModel.configChanged()`.
- `lib/src/features/home/project_scope.dart` — the inspector listens to `configWrites`; the operation source gets it.
- `lib/src/features/undo_timeline/operation_changes.dart` — `OperationChangesSource.configWrites`; the model re-reads its selection on it.
- `lib/main.inject.dart`, `test/helpers/test_component.inject.dart` — regenerated DI.
- `test/helpers/fake_projects_environment.dart` (integers stored bare), `test/helpers/fake_undo_timeline.dart`, `widgetbook/folders/undo_timeline.dart` — fakes and the catalogue stub.
- Tests: `test/features/settings/settings_window_test.dart`, `test/features/graph/graph_inspector_test.dart`, `test/features/undo_timeline/operation_changes_test.dart`, `test/features/home/project_graph_host_test.dart`.

**Review.** 22 findings: patched 2 medium + 8 low rows (wiring tests for the inspector and the operation view, four more settings cases, a narrowed fake comment, the catalogue stub, a wrapped doc line, a defaults comment); deferred none; rejected 12 (each with its reason in the Review Triage Log: reload on every write as an accepted cost, TOML integer forms, the hidden Inline row's error under Zanshin, summary re-read asymmetry as maybe-false, three false claims, the out-of-run Marionette witness).

**Follow-up review recommendation:** false. Two medium entries were patched, but both were test additions that now pass; no unverified risk remains to name.

**Verification:** see Verification notes above — `dart analyze`, `dart format`, targeted `flutter test` (273 pass).

**Residual risks:**
- The Marionette witness (hunks shrink at Context 0, "Never" under the jj style, the `JJ_CONFIG` file's values) is unchecked until the loop's main session runs it.
- Any jj config write, not only the three keys, reloads the open diff once (a cheap extra read).
- `worker_project_repos_test.dart` failed in one wider run while the cdylib rebuilt; the loop's final gate decides.
