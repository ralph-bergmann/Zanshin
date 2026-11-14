---
title: 'Story 10.33 — Ignore whitespace in the inspector diff: a diff options menu with whitespace and context lines, picks while whitespace is ignored'
type: 'feature'
created: '2026-11-14'
status: 'done'
baseline_revision: 'f96247b3fd0bd6cde54fcf76afb8f7ba88b5d5e8'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/.claude/skills/design-artifacts/SKILL.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The diff options menu, the folded whitespace rows and the dimmed, tagged lines were not checked through Marionette against the mock-up and the DS cards.
    evidence: |-
      The epic's done rule asks for a Marionette check of every UI change; this unattended run had no catalogue session. Widget tests cover the behaviour; the catalogue has Inspector diff › Whitespace ignored and the MenuButton icon-only rows. One look to settle: the unified fold row's hatch stops at the number columns (as the mock-up's `.isd-foldrow .isd-nums` background does), while the DS card hatches the full row.
    location: >-
      app/widgetbook/folders/graph.dart, app/widgetbook/folders/controls.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** Flutter work re-indents a lot, and every shifted line shows as changed in the inspector diff. jj can ignore that (`jj diff -b` / `-w`), the backend already takes the mode (`zanshinDiff(whitespace:)`), but the app never sets it. Context lines can only be changed in Settings.

**Approach:** Build the approved design (`design/Inspector Study.html`, DESIGN-SYSTEM-SYNC #26, sprint-status DESIGN UPDATE 2026-11-14): a diff options menu as the last control of the diff header — Whitespace (Show all / `-b` / `-w`, an app setting) and Context lines (jj's `diff.color-words.context`, user scope). While whitespace is ignored, lines that changed only in whitespace read as unchanged, a whitespace-only part folds into one row, and a picked (or opened) part shows those lines dimmed and tagged, so a pick never takes a line the user did not see. DS changes through the `design-artifacts` skill (C and E only, no publish). DS synced through #26.

## Boundaries & Constraints

**Always:**
- **Menu** (`ZsMenuButton`, 10.36, plus a new icon-only form): the last control in the diff header, the `view-options` glyph and the chevron, no text; ghost look; the glyph in `--accent` while whitespace ≠ Show all or context ≠ 3. Its name and tooltip: "Diff options — <whitespace label>, N context lines". Rows (`ZsMenuHeader`, check rows `checked`/`radio`, `ZsMenuSeparator`, `ZsMenuNote`): *Whitespace* — Show all whitespace (`jj diff`), Ignore changes in amount (`jj diff -b`), Ignore all whitespace (`jj diff -w`); *Context lines* — 0, 1, 2, 3 (hint "jj's default"), 5, 10, 20, plus the effective value in order when it is off that list (as the Settings row); none checked when jj cannot read the value; then the note of the mock-up. Shown wherever `InspectorDiffView` has `onWhitespaceChanged` (inspector, operation view); not on the operation view's description block.
- **Whitespace** is `GeneralSettings.diffWhitespace` (`zanshin_settings`, enum `DiffWhitespaceSetting { showAll, ignoreChangesInAmount, ignoreAll }`, default showAll, unknown value → showAll), global, remembered like `diffLayout`; also a row "Whitespace" in Settings › General › Diffs (a `ZsSelect`). A change reloads the open diff (inspector and operation view).
- **Context lines**: read like the Settings row (`configList(name: 'diff.color-words.context')` without a workspace root, `effectiveConfigEntry`, no entry = 3, unparsable or negative = unreadable); a pick writes `jj config set --user diff.color-words.context N` through `ProjectsEnvironment.configSet`, which fires `configWrites`, so the open diff reloads (as today) and the menu re-reads.
- **Reads while whitespace is ignored:** the focused file is read twice in parallel — exact (as today: parts, picks, header, counts) and at the mode (`-b`/`-w`) — and shown only when both arrived. The summary (file list ±, fingerprints, Viewed keys) stays exact. A refusal of either read is the diff's refusal.
- **What shows** (a pure, tested function over the exact hunk + what the ignoring read says): a changed line is *whitespace-only* when neither its left number is among the ignoring read's changed left numbers nor its right number among its changed right numbers. A part (exact section, `hunkPartOf`) whose changed lines are all whitespace-only is a *whitespace-only part*.
  - Part picked (file whole or the section) or opened → its whitespace-only lines show as they are, text dimmed to .62; in the unified layout a line with a right number carries the pill "whitespace only" (10.5 px, `--fl-hover`, `--text-dim`; for an opened, not picked part a button "whitespace only · Hide" that closes it).
  - Whitespace-only part, neither picked nor opened → its lines fold into one hatched row (`paintGraphHatch`, 6 px, `--fl-hover`): "⋯ N lines changed whitespace only · Show" (N = the larger of its distinct left and right numbers; ICU plural); Show opens it. With picks available the row carries the part's checkbox (pick → it opens, as picked).
  - Whitespace-only line of a mixed part (or of no part), not shown → in its place the ignoring read's context line with the same right number (once), else nothing — what `jj diff -w` shows there.
  - A hunk left with only context lines goes; a file left with no hunk shows the note "Only whitespace changed in this file." Opened parts reset with the file and the mode.
- Side by side: the same rows; fold rows full width (the part gutter leads them when the hunk shows parts); revealed cells dimmed; no tag.
- Strings through the ARB with ICU plurals; `flutter gen-l10n` output committed. Zs controls only; tokens from the DS layer. Tests never call a jj config verb for real; never Ralph's settings.

**Never:**
- Rust, FFI or schema changes; a whitespace mode per file; whitespace in the summary or the Viewed fingerprint.
- Picking single lines or only a part's visible lines; refusing picks while whitespace is ignored; a "+N not shown" hint.
- Publishing the DS artifact or syncing the canvas (A, B) — Story 10.38's ledger item covers it.
- Ralph's real jj config or settings in a test or the catalogue.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Padding wrap, -b | indented subtree wrapped in `Padding(` … `),` | only `Padding(`, `padding:` and `),` lines stay changed; the re-indented lines read as context | — |
| Space amount | `a b` → `a  b` | gone under -b and -w (folded, whitespace-only part) | — |
| Space removed | `a b` → `ab` | whitespace-only (folded) under -w; a real change under -b | — |
| Pick re-indenting part, -w | mixed part (real line + re-indented line), pick it | re-indented line shows dimmed + tag; committing the section takes it | — |
| Fold pick | whitespace-only part, tick its fold checkbox | row opens dimmed; the commit holds its lines | — |
| Show / Hide | fold row Show, then tag Hide | opens without a pick; Hide folds it again | — |
| Only whitespace | file with only whitespace changes, no sections (op view) | note "Only whitespace changed in this file." | — |
| Context menu | user config context 5 | menu checks 5; Settings row shows 5; pick 10 → `set user diff.color-words.context 10`, diff reloads | write refused: logged, value kept |
| Off-list context | effective 7 | menu lists 0,1,2,3,5,7,10,20, 7 checked | unreadable: none checked |
| Restart | whitespace -w, new `SettingsStore` on the file | the menu and the read use -w | — |
| Second read refused | ignoring read throws | the diff shows the refusal | — |

</intent-contract>

## Code Map

- `packages/zanshin_core/lib/src/ffi/diff.dart:25-45, 97-170` -- `DiffWhitespace` (exact / ignoreAllSpace = -w / ignoreSpaceChange = -b), `HunkLine` (kinds, `left`/`right` 1-based), `Hunk.sections`. At -w/-b a context line whose sides differ in whitespace keeps kind context with the CLI's marks (`crates/zanshin-jj/src/hunks.rs:1663-1686`); a whitespace-only change outside the context range shows no line (`:1652-1661`). Read-only.
- `packages/zanshin_core/lib/src/worker/handle.dart:1660` -- `diff(..., whitespace:)`; already exported.
- `packages/zanshin_settings/lib/src/model/general_settings.dart` -- add `DiffWhitespaceSetting` + `diffWhitespace`; regenerate `.freezed.dart`/`.g.dart` (`dart run build_runner build -d`, `build.yaml` header rule). Tests in `packages/zanshin_settings/test/`.
- `app/lib/src/features/graph/graph_ports.dart:1035-1068` -- `GraphDetails.diff` gains `whitespace`; add `diffContext()` / `setDiffContext(int)`; `RepoGraphDetails(repo, environment)`.
- `app/lib/src/features/undo_timeline/operation_changes.dart:40-90, 100-400, 690-749` -- `OperationChangesSource` same three changes; `RepoOperationChangesSource(repo, environment:)` (its `configWrites` from the environment); model: whitespace from settings, second read, context state; `_Files` passes the menu props (not to the description block).
- `app/lib/src/features/home/project_scope.dart:117-125, 194-197` -- providers: inspector gets `ProjectsEnvironment`; regenerate `app/lib/main.inject.dart` and `app/test/helpers/test_component.inject.dart` (`dart run build_runner build -d` in `app`).
- `app/lib/src/features/projects/projects_environment.dart:17-60` -- `configList`, `configSet`, `configWrites`; `effectiveConfigEntry` (used by `settings_view_model.dart:451`) for the read.
- `app/lib/src/features/settings/settings_view_model.dart:40` -- `SettingsKeys.diffContext`; `general_tab.dart:163-220` -- Diffs group: add the Whitespace row after the layout row; the context row's list `[0,1,2,3,5,10,20]` is the menu's.
- `app/lib/src/features/graph/graph_inspector.dart:53-360` -- `InspectorViewModel`: `_settingsChanged` (add whitespace → reload), `configChanged` (also re-read context), `_loadFocus` (two reads, serial), `focusedDiff`/`previousDiff` (add the ignoring side for both); `partPicked` `:506`, `togglePart` `:511`. `:2751-2775` the diff pane passes the new props.
- `app/lib/src/features/graph/inspector_diff.dart` -- `InspectorDiffView` `:346-556` (bar `:504-546`: add the menu last; note for an all-whitespace file), `_DiffBody` `:697-821` (open parts state, keyed by path and mode; hunks → rows), `InspectorDiffHunk` `:838-1203` (`_unified` / `_sideBySide` iterate rows; fold row; dim + tag), `hunkPartOf` `:274`, `pairSideBySide` `:33`, `_lineText` `:227`. New: the pure row builder and the menu entries builder.
- `app/lib/src/features/graph/hatch_swatch.dart:11` -- `paintGraphHatch` for the fold row.
- `packages/zanshin_ui/lib/src/controls/zs_menu_button.dart`, `zs_button.dart:141-325` -- add the icon-only form (`iconOnly`: glyph + chevron, label as name and tooltip) and `active` (glyph in `--accent`). Tests `packages/zanshin_ui/test/controls/`; catalogue `app/widgetbook/folders/controls.dart` (MenuButton use cases).
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart:23-145` -- `ZsMenuItem(checked:, radio:, cmd:, shortcut:)`, `ZsMenuHeader`, `ZsMenuSeparator`, `ZsMenuNote`.
- Mock-up `_bmad-output/implementation-artifacts/design/inspector-study.jsx:147-166` (`shown`), `:261-365` (menu, tag, fold row), `inspector-study.css:174-189`.
- DS `_bmad-output/implementation-artifacts/design_system/`: `components/actions/MenuButton.{jsx,d.ts,prompt.md}`, `actions.css`, `menubutton.card.html`; `components/content/DiffHunk.*`, `DiffView.*`, `content.css`, `content.card.html`; `_ds_bundle.js` (blocks of the changed jsx); `readme.md` (change log, "Synced through"). `design/DESIGN-SYSTEM-SYNC.md` #26: a dated "2026-11-14 (Story 10.33)" line.
- Fakes to update (new `diff` parameter and context methods): `app/test/features/graph/graph_inspector_test.dart:75`, `graph_card_menu_test.dart:202`, `app/widgetbook/folders/graph.dart:1015`, `app/integration_test/glass_profile.dart:242`, `app/test/helpers/fake_undo_timeline.dart:105`, `app/widgetbook/folders/undo_timeline.dart:149`; `RepoGraphDetails(repo)` in `graph_ports_test.dart:166,579`, `graph_real_repo_test.dart:165`.
- Real-repo tests: `app/test/features/graph/graph_ports_test.dart:360-470` (`setUpRepo`, `addedLines`, `GraphCommit` with `HunkChoice`).

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_settings/lib/src/model/general_settings.dart` (+ generated, tests) -- `DiffWhitespaceSetting`, `diffWhitespace` -- the remembered mode; default, round trip, unknown value.
- `packages/zanshin_ui/lib/src/controls/zs_button.dart`, `zs_menu_button.dart` (+ test) -- icon-only menu button with `active` -- the options control.
- `app/lib/src/features/graph/graph_ports.dart`, `operation_changes.dart` (source), `project_scope.dart` (+ regenerated inject files) -- whitespace on `diff`, `diffContext` / `setDiffContext` over the environment.
- `app/lib/src/features/graph/inspector_diff.dart` -- row builder (`whitespaceRows`), the options menu's entries (`diffOptionsEntries`), fold row, dim + tag, all-whitespace note, new view props (`whitespace`, `onWhitespaceChanged`, `ignored`, `contextLines`, `onContextLinesChanged`).
- `app/lib/src/features/graph/graph_inspector.dart` -- model: whitespace setting, two reads, context state, setters; pane passes the props.
- `app/lib/src/features/undo_timeline/operation_changes.dart` -- model and `_Files`: the same for the operation view.
- `app/lib/src/features/settings/general_tab.dart` -- the Whitespace row.
- `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`) -- menu name, heads, rows, hint, note, tag, Hide, fold text (ICU), fold checkbox labels, Show tooltip, all-whitespace note, Settings row label + options.
- `app/widgetbook/folders/graph.dart`, `controls.dart` -- use cases: Inspector diff › Whitespace ignored (a fold row, a mixed part picked), Controls › MenuButton icon-only; fakes updated.
- Tests: `app/test/features/graph/inspector_diff_test.dart` (row builder per matrix row, fold/Show/Hide/checkbox, menu checks and callbacks, accent glyph), `graph_inspector_test.dart` (setting → two reads with the mode, restart, context menu = Settings row value, pick writes user config, refusal), `graph_ports_test.dart` (real repo: Padding wrap under -b, `a b`→`a  b` / `ab`, pick of a re-indenting part commits it under -w, folded part picks and commits), `operation_changes_test.dart` (menu present, mode reloads), `app/test/features/settings/` general tab (Whitespace row writes the setting).
- DS via `design-artifacts` C and E (no A/B): `MenuButton` icon-only + active; `DiffView` bar with the options button; `DiffHunk` dimmed whitespace lines, the tag, the folded row; cards; `_ds_bundle.js` blocks; readme change log + "Synced through #26" line; dated line under DESIGN-SYSTEM-SYNC #26.

**Acceptance Criteria:**
- Given a diff open in the inspector, when the user picks "Ignore all whitespace" in the diff options menu, then the diff reloads at `-w`, the glyph turns accent, and after a restart (new `SettingsStore` on the same file) the menu still checks it.
- Given whitespace is ignored and a part that changes code and re-indents a line, when the user ticks that part, then the re-indented line shows dimmed with "whitespace only", and committing takes it (real repo).
- Given a whitespace-only part, when the user ticks its folded row, then the row opens and the commit holds its lines (real repo).
- Given a user config with context 5, when the menu opens, then 5 is checked and Settings › General › Diffs shows 5; picking 10 writes `diff.color-words.context = 10` at user scope and the diff reloads.
- Given the Undo Timeline's operation view, when a file diff shows, then its header has the same menu and a whitespace change reloads it.

## Spec Change Log

## Review Triage Log

### 2026-11-14 — Review pass
- verdicts: 32 findings — high 0, medium 2, low 25, false 4, maybe-false 1
- findings:
  - `[low]` `[patch]` (blind) `whitespaceRows` fills a `touched` set nobody reads — deleted.
  - `[low]` `[patch]` (blind) the fold checkbox's "Unpick" branch is unreachable: a fold row exists only for an unrevealed part and every picked part is revealed — the box is always unchecked with the pick label; `inspectorFoldUnpick` removed from the ARB.
  - `[low]` `[reject]` (blind) the menu checks the user-level context while a repo or workspace layer may override what the diff uses — the intent asks that the menu equal the Settings row, which reads the user level; a repo-level `diff.color-words.context` is rare and a hint adds UI.
  - `[low]` `[reject]` (blind) re-picking the checked context value writes the same value again — harmless (same value, one reload); a guard in two models adds code for no user-visible gain.
  - `[low]` `[reject]` (blind) an unreadable context turns the glyph accent — an unreadable value is not jj's default, so the mark is defensible; the label already says "context lines unreadable".
  - `[low]` `[reject]` (blind) the operation view does not notify on a whitespace switch and shows an empty pane while reading — `_refocus` → `focus()` ends in `_notify()`, so the menu updates at once (that part is false); the empty pane while a read runs is the operation view's existing file-switch behaviour.
  - `[false]` `[reject]` (blind) opened parts carry over to another commit with the same path in the operation view — `_read` sets `_focused = null` and notifies, so `_Files` drops the diff view and its state before the next commit's diff mounts.
  - `[low]` `[patch]` (blind) test gaps: mode-change reset, side-by-side fold with picks — tests added (grouped with the verification rows below); the operation view's refused `-w` read (same `Future.wait` path as the inspector's tested one), the restart reading the menu (the menu reads `model.whitespace`, which the test checks) and the fold tick through the model (`partPicked` is passed straight from the model, tested in 10.38) are rejected as low-value.
  - `[low]` `[reject]` (blind) `general_tab.dart` imports two values from `inspector_diff.dart`, `immutable_heads.dart` re-exports `effectiveConfigEntry` — no cycle and no caller diverges; moving them is churn.
  - `[false]` `[reject]` (blind) the unified fold row's hatch stops at the opaque number columns, unlike the DS card — the approved mock-up does the same (`.isd-foldrow .isd-nums{background:var(--isd-code)}`); the Marionette comparison is deferred (grouped with the intent row below).
  - `[low]` `[patch]` (blind) an active icon-only menu button keeps the accent glyph while disabled — the accent applies only while enabled; test added. The missing `assert(!active || iconOnly)` is rejected: no caller passes `active` alone.
  - `[maybe-false]` `[reject]` (blind) one `Opacity` layer per dimmed line may slow long picked re-indents — unmeasured; if real only low (dimmed lines exist only in picked or opened whitespace parts); settle by picking a part of a few hundred re-indented lines in a profile build.
  - `[low]` `[reject]` (blind) `DiffFoldRow` has a const constructor but its `lines` grow while rows are built — rows are built fresh per build and never shared; no harm named.
  - `[low]` `[reject]` (blind) DS `zsNumbered` does not advance the counters past a fold row — only git-sigil lines after a fold miscount; the DS cards use numbered color-words lines, so nothing shows wrong.
  - `[medium]` `[patch]` (edge) a whole-picked renamed or copied file (no part picks) keeps its whitespace-only lines hidden while the pick commits them — the inspector passes no ignoring read for a file picked whole without part picks, so every line shows; test added.
  - `[low]` `[reject]` (edge) the repo-level context override — grouped with the blind row above.
  - `[low]` `[reject]` (edge) an opened part cannot be folded again in side by side (no Hide there) — the mock-up has no tag or Hide in side by side either; the unified layout or another file folds it.
  - `[low]` `[patch]` (edge) icon-only menu button: accent while disabled — grouped with the blind row above; the ignored `size` is rejected (no caller passes another size).
  - `[false]` `[reject]` (edge, claim) "a picked or opened part shows those lines dimmed and tagged" is untrue in side by side — the code and spec say the pill is unified only, side by side dims.
  - `[medium]` `[patch]` (edge, claim) a pick can take unseen whitespace lines of a whole-picked renamed file — grouped with the edge row above.
  - `[low]` `[patch]` (verification) the side-by-side fold checkbox with picks is untested — test added.
  - `[low]` `[patch]` (verification) the previous diff keeping its whitespace read while a reload runs is untested — test added.
  - `[low]` `[patch]` (verification) the accent glyph for context ≠ 3 is untested — test added.
  - `[low]` `[patch]` (verification) opened parts resetting on a mode change are untested — test added.
  - `[low]` `[reject]` (verification, other) the repo-level context override — grouped with the blind row above.
  - `[low]` `[reject]` (intent) the view keeps the exact hunk frame, headers and counts rather than `jj diff -w`'s, and the To-check answers (Sourcetree, word marks) are not recorded — the frame is the spec's design decision (Design Notes: parts and picks need every exact line); the design update superseded the To-check items.
  - `[low]` `[reject]` (intent) the context witness reads the user level, not `jj config get` in the repo — grouped with the blind row above.
  - `[low]` `[reject]` (intent) the commit witnesses are split across a real-repo test and widget tests — the real repo commits the exact sections the row builder reveals; the widget tests prove the pick reaches the model.
  - `[low]` `[reject]` (intent) the Padding witness asserts the changed rows are a subset of the new lines, not that `),` shows changed — in the exact frame a `),` that jj aligns as context stays context; the re-indented lines reading as context is the witness's point.
  - `[low]` `[reject]` (intent) the restart witness is a new `SettingsStore` on the same file, not an app restart — that is what a restart reads.
  - `[false]` `[reject]` (intent) the look differs from the design (color-words instead of − / +, no side-by-side pill, accent when unreadable, reset on file and mode) — each is a recorded decision (Design Notes; the epic: build along jj's behaviour) or matches the mock-up.
  - `[low]` `[defer]` (intent) the Marionette check of the menu and the whitespace rows is not done and not recorded as deferred — deferred (mirrored in deferred-work.md).

## Design Notes

- **Why two reads, with the exact diff as the frame:** parts and picks are the exact sections; only the exact diff holds every line a part takes, also lines `jj diff -w` skips (a long re-indent splits into two `-w` hunks; at context 0 a re-indented line is not in any `-w` hunk). The ignoring read only says which line numbers really changed and gives the CLI's context line for a substituted one. Rust stays the only place that compares lines; Dart only matches numbers.
- **The mock-up's − / + pair in jj's color-words:** the app draws jj's color-words lines (Story 5.10), so a revealed whitespace-only line is the exact line as jj prints it (a changed line with its whitespace marks, or a removed / added pair), dimmed; the tag goes on lines with a right number.
- **Fold checkbox in a one-part hunk:** the design gives the folded row its own checkbox; with one part it does what the header's checkbox does. Kept for one rule everywhere.
- **Context through the ports:** `GraphDetails` and `OperationChangesSource` are each view's port to the outside; the context read and write sit there (over `ProjectsEnvironment`), so the models stay testable with fakes and no config verb runs for real in tests.

## Verification

**Commands:**
- `dart run build_runner build -d` in `packages/zanshin_settings` and in `app` -- generated files updated and committed.
- `flutter gen-l10n` in `app` -- output committed.
- `flutter test` in `packages/zanshin_ui`, `packages/zanshin_settings` -- pass.
- `cargo make test-app test/features/graph test/features/undo_timeline test/features/settings test/widgetbook test/l10n test/architecture` -- pass.
- `dart analyze app packages/zanshin_ui packages/zanshin_settings` -- no issues.
- `dart format --set-exit-if-changed -o none` on the touched Dart directories -- 0 changed.
- `node --check _bmad-output/implementation-artifacts/design_system/_ds_bundle.js` -- passes.
- Not run (the loop's gate rule): `cargo make test`, `test-full`, `coverage`. No Rust changes, so no cargo checks.

**Manual checks:**
- Marionette check of the menu and the whitespace rows in the catalogue: left to the console session, as in 10.35–10.38.

**Verification notes (2026-11-14, gate rule of the story loop: no full gate):**
- `dart run build_runner build -d` in `packages/zanshin_settings` and in `app` (implementation run) -- generated settings and inject files updated.
- `flutter gen-l10n` in `app` -- run after the implementation and again after the review removed `inspectorFoldUnpick`.
- `flutter test` in `packages/zanshin_ui` -- 472 passed (after the review patches); in `packages/zanshin_settings` -- 57 passed.
- `cargo make test-app test/features/graph test/features/undo_timeline test/features/settings test/widgetbook test/l10n test/architecture` -- 1599 passed after the implementation; 1604 passed after the review patches.
- `dart analyze app packages/zanshin_ui packages/zanshin_settings` -- No issues found (both times).
- `dart format --set-exit-if-changed -o none` on `app/lib`, `app/test`, `app/widgetbook`, `app/integration_test` and both packages' `lib` and `test` -- 0 changed (both times).
- `node --check _bmad-output/implementation-artifacts/design_system/_ds_bundle.js` -- passes; the implementation run also loaded the bundle with a stub React and rendered the new DiffHunk rows, the DiffView menu and the note without errors.
- Not run: `cargo make test` / `test-full` / `coverage` (the loop's gate rule). No Rust, FFI or schema changed, so no cargo checks, codegen or parity oracle. DS publish (A, B) out of scope; the Marionette check is deferred.

## Auto Run Result

Status: done

**Summary.** The diff header ends in a diff options menu: an icon-only `ZsMenuButton` (`view-options` glyph + chevron, accent while whitespace ≠ show all or context ≠ 3). Whitespace — Show all (`jj diff`), Ignore changes in amount (`jj diff -b`), Ignore all (`jj diff -w`) — is `GeneralSettings.diffWhitespace`, global, also a row in Settings › General › Diffs. Context lines (0, 1, 2, 3 jj's default, 5, 10, 20, plus an off-list effective value) read and write `diff.color-words.context` at user scope through `ProjectsEnvironment`, like the Settings row. While whitespace is ignored the focused file is read exact and at the mode in parallel; `whitespaceRows` keeps the exact frame: a whitespace-only line of a picked or opened part shows dimmed (unified: the pill "whitespace only", or "whitespace only · Hide"), a whitespace-only part folds into a hatched "⋯ N lines changed whitespace only · Show" row with its checkbox, any other whitespace-only line gives way to the ignoring read's context line or nothing, context-only hunks go, an empty file reads "Only whitespace changed in this file." A file picked whole without part picks shows its exact lines. The operation view gets the same menu and reads. DS: `MenuButton` icon-only / active, `DiffView` options menu and note, `DiffHunk` whitespace rows. DS synced through #26.

**Commits.** `4daa310414848b40b5c6734f1a39abaf5008146f` (code, tests, DS); the docs commit (this spec, sprint status, epic 10 context, deferred work) follows it.

**Files changed.**
- `app/lib/src/features/graph/inspector_diff.dart` -- `IgnoredLines`, `DiffRow` / `DiffLineRow` / `DiffFoldRow`, `whitespaceRows`, `diffOptionsEntries`, `diffContextChoices`, `diffWhitespaceLabel`, the options menu in the bar, fold rows, dimming and pills in both layouts, the only-whitespace note.
- `app/lib/src/features/graph/graph_inspector.dart` -- whitespace setting, two reads, previous ignoring read kept during reloads, context state and setters; the diff pane passes the new props (no ignoring read for a whole-picked file without part picks).
- `app/lib/src/features/graph/graph_ports.dart`, `app/lib/src/features/undo_timeline/operation_changes.dart` -- `diff(whitespace:)`, `diffContext()` / `setDiffContext()`; the operation view's model and `_Files`.
- `app/lib/src/features/projects/projects_environment.dart` -- `diffContextKey`, `readDiffContext`, `writeDiffContext`, `effectiveConfigEntry` (moved from `settings/immutable_heads.dart`, re-exported there).
- `app/lib/src/features/home/project_scope.dart` (+ `main.inject.dart`, `test_component.inject.dart`) -- the ports get the environment.
- `app/lib/src/features/settings/general_tab.dart`, `settings_view_model.dart` -- the Whitespace row; shared context choices and key.
- `app/lib/l10n/*` -- menu, rows, note, pills, fold row, only-whitespace note, Settings row.
- `packages/zanshin_settings/lib/src/model/general_settings.dart` (+ generated) -- `DiffWhitespaceSetting`, `diffWhitespace`.
- `packages/zanshin_ui/lib/src/controls/zs_button.dart`, `zs_menu_button.dart` -- icon-only menu button with `active` (accent only while enabled).
- `app/widgetbook/folders/graph.dart`, `controls.dart`, `undo_timeline.dart` -- Inspector diff › Whitespace ignored, MenuButton icon-only rows, fakes.
- Tests: `inspector_diff_test.dart`, `graph_inspector_test.dart`, `graph_ports_test.dart` (real repo: Padding wrap, `a b`, a picked re-indenting part and a folded part commit), `operation_changes_test.dart`, `settings_window_test.dart`, settings model tests, `zs_menu_button_test.dart`; fakes updated.
- DS: `components/actions/MenuButton.*`, `actions.css`, `menubutton.card.html`, `components/content/DiffHunk.*`, `DiffView.*`, `content.css`, `content.card.html`, `_ds_bundle.js`, `readme.md`; `design/DESIGN-SYSTEM-SYNC.md` dated line under #26.

**Review findings.** 32 findings: 11 patch rows in 8 entries (1 medium entry: a whole-picked renamed or copied file hid whitespace-only lines its pick commits; 7 low: dead set, unreachable Unpick branch and string, accent while disabled, four missing tests); 1 deferred (Marionette check, low); 16 rejected (low or maybe-false) with reasons in the triage log (repo-level context override vs the Settings row's user level, re-picking the checked context, accent while unreadable, op-view empty pane while reading, cross-feature imports, `Opacity` per dimmed line, `DiffFoldRow` built in place, DS fold numbering, no side-by-side Hide as in the mock-up, the exact frame vs `jj diff -w`'s headers, test-surface choices); 4 false.

**Follow-up review recommendation: false.** Patched this pass: high 0, medium 1, low 7 entries; a first pass recommends another only after a high or two mediums.

**Deferred-work items.** One new item, mirrored under "Surfaced in Story 10.33" in deferred-work.md: the Marionette comparison with the mock-up and the DS cards (low).

**Residual risks.**
- Not checked visually through Marionette (deferred); the DS cards were not opened in a browser.
- The menu reads the user-level context like the Settings row; a repo-level `diff.color-words.context` makes the menu and the shown diff differ.
- Both models show context 3 until the first read lands.
- In the exact frame a `),` that jj aligns as context stays context in the Padding case; hunk headers and counts stay exact while whitespace is ignored.
