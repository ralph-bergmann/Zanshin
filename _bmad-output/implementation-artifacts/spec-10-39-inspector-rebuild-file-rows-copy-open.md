---
title: 'Story 10.39 — Inspector rebuild, part 2: file names first, tree or flat, copy, Reveal in Finder, Open in Editor'
type: 'feature'
created: '2026-11-14'
status: 'done'
baseline_revision: '4b8cc559a1639c5a479e56a49c51ac76e565b7be'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/.claude/skills/design-artifacts/SKILL.md'
warnings: ['oversized', 'multiple-goals']
deferred:
  - summary: >-
      The two IntelliJ checks the story asks for are not done: whether Go to File (⇧⌘O) takes an absolute path:line, and whether `idea --line` opens in the running IntelliJ when the project is open there.
    evidence: |-
      Both need Ralph's IntelliJ; the unattended run may not start a real editor. Open in Editor runs `idea --line <n> <absolute path>` (tested with a fake launcher in app/test/features/graph/project_files_test.dart).
    location: >-
      app/lib/src/features/graph/project_files.dart (editorCommand)
    severity: low
  - summary: >-
      The file rows, folder rows, tree/flat switch, menus and copyable diff path were not checked through Marionette against the mock-up and the DS cards.
    evidence: |-
      The epic's done rule asks for a Marionette check of every UI change; this unattended run had no catalogue session. Widget tests cover the behaviour; the catalogue has the use cases Inspector › Tree, Long path (460), File menu and Line menu.
    location: >-
      app/widgetbook/folders/graph.dart
    severity: low
  - summary: >-
      No test shows that a successful login-shell adoption stores the environment that editor detection and launching use.
    evidence: |-
      `_adopted ??= variables` in adoptLoginShellEnvironment has no test: a real adoption calls FFI and installs a process-global Rust environment that would leak into other test files. Only the decoding and the empty state are tested (packages/zanshin_core/test/environment/login_shell_test.dart).
    location: >-
      packages/zanshin_core/lib/src/environment/login_shell.dart (adoptLoginShellEnvironment)
    severity: low
---

<intent-contract>

## Intent

**Problem:** A file row shows one path cut at its end (`graph_inspector.dart` `InspectorFileRow`), which hides the file's name; a commit with many files has no folder view; the user cannot copy a path or jump from a diff line to the place in his editor (Ralph's use case: review in Zanshin, fix in IntelliJ). Deferred-work I1's open part (file rows, tree/flat, copy, Reveal, Open in Editor) is this story's.

**Approach:** Build #25's file rows (name first, folder dimmed and cut in the middle), a tree/flat switch with folder rows, ← → and ⌘C in the list, copy of absolute paths (diff header click, ⌘C, menus), context menus on file rows, folders, diff lines and bookmark chips, Reveal in Finder (`open -R`) and Open in Editor with an editor chosen in Settings › General › Editor (a detected `idea` / `code` / `zed` on the login shell's `PATH`, or a custom command with `{file}` and `{line}`). DS parts of #25 for 10.39 (FileRow, tree row, menus) in the repo only. DS synced through #26.

## Boundaries & Constraints

**Always:**
- **File row** (#25, `inspector-study.css:106-126`): 28 px; checkbox (mutable), status badge 17 px square (`--accent-soft` / `--accent` for M, R; A in `--add` on `--add-bg`; D in `--rem` on `--rem-bg`; C as A), the **name** in `--text` never cut while folder text is left, then (flat only) the **folder** with its trailing `/` in `--text-faint`, cut in its middle: the head (everything up to the last folder) gives way first, then the last folder, then the name (ellipsis at each). ✓ when viewed (name and folder at .55), ± at the right. Tooltip: the full path; a rename or copy shows the new name and folder, tooltip `old → new`. The operation view's rows get the same look (flat).
- **Tree or flat:** `GeneralSettings.diffFileList` (`flat` default, `tree`), a two-icon `ZsSegmented` (sm, glyphs `listFlat` / `listTree`, tooltips "Flat list" / "Tree") at the right end of the Changes header that writes the setting, and a Settings › General › Diffs row "File list" (Flat / Tree). Tree: folders sorted by name, then files by name; a folder whose only child is one folder joins with it (`packages/logic_designer/lib/src`); folder row = chevron, three-state checkbox (mutable: picks / unpicks all its files; mixed when some), folder glyph, name, a count pill (10 px, `--fl-hover`, `--text-dim`), summed ±; files indent 8 + 14 × depth + 18, folders 8 + 14 × depth. A click on a folder row selects it and toggles it. Collapsed folders are kept in the inspector model for the session only (never stored). Flat keeps jj's order.
- **Keys** (list focused): ↑ ↓ walk the visible rows (a file row shows its diff as in 10.38; a folder row only becomes current); ← on an open folder collapses it, on a file or closed folder moves to its parent folder; → on a closed folder expands, on an open folder moves to its first child; ↩ on a folder toggles it; Space and V on a folder act on all its files; ⌘C copies the current row's absolute path (file or folder). The current row carries the ring as in 10.38.
- **Absolute path** = the workspace root (`@projectRoot`) + `/` + the repo path. Copy path = absolute (Sourcetree); Copy relative path = the repo path; Copy path:line = `<absolute>:<line>`.
- **Diff header** (#25): the name (500) then the folder dimmed, cut as the row's, in a flat button; a click copies the absolute path and shows "Copied" in `--add` for 1.3 s (tooltip "Click to copy <absolute path>"). Same in the Undo Timeline's operation view (root from its source). Without a root (catalogue stand-ins) the header is plain text.
- **Context menus** (`ZsMenuAnchor` at the pointer, the existing menu style with hints and a note): file row = Open in Editor · Reveal in Finder · ─ · Copy path (hint ⌘C) · Copy relative path; folder = Reveal in Finder · ─ · Copy path · Copy relative path; diff line (both layouts) = Open in Editor at line · ─ · Copy path:line · Copy path; bookmark chip = Copy name (the shown text). On a change other than @, file-row and diff-line menus end with the note "Opens the file on disk — @'s version; a later change may have moved its lines." A right-click on a row also makes it current. The diff line's number is its new-side number; a removed line takes the next line's new number (the place where it stood; after the hunk's last line: last new + 1, or the hunk's new start).
- **Open in Editor:** `GeneralSettings.editor` (`String?`): null = none; `idea` / `code` / `zed` = a launcher; any other value = a custom command that must hold `{file}`. Arguments — idea: `--line <n> <file>` / `<file>`; code: `--goto <file>:<n>` / `<file>`; zed: `<file>:<n>` / `<file>`; custom: the command split like a shell word list (spaces; '…' and "…" quote), `{file}` and `{line}` replaced in each word (no line: 1). Row label "Open in IntelliJ IDEA" / "Open in VS Code" / "Open in Zed" / "Open in Editor" (custom), with " at line N" for a line; hint = the program and its arguments without the file (`idea --line 12`). Without an editor the row reads "Choose editor…" (hint "Settings › General › Editor") and opens Settings on the General tab (`AppWindowActionsScope`, disabled outside a window). Never the macOS default app.
- **Launch:** the program is found on the login shell's `PATH` (Story 9.36: zanshin_core keeps the first adopted environment, `adoptedLoginShellEnvironment()`; else the process's), started detached with that environment. Not found or a failed start: an error toast "Could not start <program>: <reason>". Reveal in Finder: `/usr/bin/open -R <absolute path>`, the same failure toast.
- **Files on disk:** a file (or folder) that does not exist in the working copy disables Open and Reveal, tooltip "<path> is not in the working copy." Checked when the menu opens.
- **Settings › General › Editor** (new group after Diffs; Claude's proposal in the style of the rows): a row "Open files in" with a `ZsSelect`: None, each detected launcher ("IntelliJ IDEA — idea", "VS Code — code", "Zed — zed"), the stored launcher even when not detected, "Custom command"; with Custom a second row "Command" with a `SettingsTextField` (hint "{file} and {line} are replaced; IntelliJ: idea --line {line} {file}"), refusing a command without `{file}` with an error. Detection scans the login-shell `PATH` once per process.
- Strings through the ARB (ICU where counted); jj's words and commands stay literals with `// l10n-ignore`. Zs controls and DS tokens only. Tests never run a real launcher or `open`: a fake `StartProcess` records calls; temp dirs only; never Ralph's settings.
- DS (repo only, skill steps C and E): `FileRow` (name first, middle-cut folder, the tree row: chevron, three-state check, count; `name`/`folder`/`tree`/`depth`/`open` props), `content.css`, the Content card, the kit inspector's rows, tree/flat switch, menus and copyable diff path; `_ds_bundle.js` by hand; the glyphs `listFlat`, `listTree` (`assets/icons/ui`, `glyphs.json`, Icon d.ts/prompt/card); readme Sync line; a dated "(Story 10.39)" line under DESIGN-SYSTEM-SYNC #25. No publish.

**Never:** opening the change's own version of a file; an editor per project; layout changes (10.38); storing collapsed folders; running a real editor or `open -R` in tests; the macOS default app; a new FFI call or Rust change.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Long path, narrow | `packages/logic_designer/lib/src/presentation/widgets/automation_overview_page.dart`, 460 pt inspector, flat | `automation_overview_page.dart` whole; folder cut in its head | — |
| Rename | `a/old.dart → b/new.dart` | name `new.dart`, folder `b/`, tooltip `a/old.dart → b/new.dart` | — |
| Tree join | files under `packages/logic_designer/lib/src/…` only | one folder row `packages/logic_designer/lib/src` | — |
| Folder pick | mutable, folder with 3 files, 1 picked | checkbox mixed; click → all 3 picked; click → none | — |
| Tree keys | tree, current = a file in `src` | ← → current = folder `src`; ← again collapses; → expands | — |
| Copy | file row ⌘C; menus | clipboard `<root>/<path>`, `<path>`, `<root>/<path>:<n>` | — |
| Removed line | right-click a removed line before new line 41 | Copy path:line → `…:41` | — |
| Open, IntelliJ | editor `idea`, line 12 | fake start gets `<PATH dir>/idea`, `[--line, 12, <abs>]`, login env | not on PATH → error toast |
| No editor | editor null | first row "Choose editor…" opens Settings › General | outside a window: disabled |
| Custom | `subl {file}:{line}` | `[<abs>:12]` | — |
| Missing on disk | file deleted in @ | Open, Reveal disabled with the reason | — |
| Reveal | file row | fake start gets `/usr/bin/open`, `[-R, <abs>]` | failure → error toast |
| Not @ | change other than @ | file and line menus end with the on-disk note | — |
| Restart | tree chosen, new `SettingsStore` on the same file | tree shows | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_inspector.dart:2493-2942` -- `InspectorSplit`, `_Changes`/`_ChangesState` (files pane header `:2718-2799`, list `:2800-2843`, `_onKey` `:2627-2677`, `_pending`/`_show`/`_settle`/`_reveal`, `_rows` keys per path). Rows become visible tree/flat rows; keys extend; menus attach here.
- `graph_inspector.dart:2944-3077` -- `InspectorFileRow`: rebuild as the name-first row; keep its params used by `operation_changes.dart:890`; add tree mode (folder rows as a sibling widget).
- `graph_inspector.dart:58-160, 244-300, 580-760` -- `InspectorViewModel` (`settings` listener `_settingsChanged` `:334`, `setLayout` `:302` write pattern, `togglePick`, `fileState`, `isPicked`, `setViewed`, `isViewed`, `selectable`): add `fileList` + `setFileList`, `collapsed` / `setCollapsed`, `togglePicks(paths)`, `setViewedAll(paths, bool)`, and an optional `files` (`ProjectFiles?`).
- `graph_inspector.dart:1412-1616` -- `_CopyId` ("Copied" pattern, `Clipboard.setData`, announce); `:2273-2341` `_Chips` (bookmark chip; add the Copy name menu).
- `app/lib/src/features/graph/inspector_diff.dart:526-790` -- `InspectorDiffView` header (`:705-749`: path `Text`); add `copyPath` (absolute) and `lineMenu` (entries for a new-side line number). `:935-1098` `_DiffBody` (`SelectionArea` `:1094`: its own right-click menu must not open over ours); `:1419-1657` `_unified` / `_sideBySide` rows: secondary tap → the line's new number. Add a pure `diffNewLineAt(Hunk, int index)`.
- `app/lib/src/features/undo_timeline/operation_changes.dart:32-102` -- `OperationChangesSource` (+ `String? get root`), `RepoOperationChangesSource` (root from `ProjectModule`); `:825, :851` its `InspectorDiffView`s get `copyPath`; fakes `app/test/helpers/fake_undo_timeline.dart:113`, `app/widgetbook/folders/undo_timeline.dart:149`.
- `app/lib/src/features/home/project_scope.dart:117-131, 200-203` -- provide `ProjectFiles` (root, settings, toasts) and pass it to the inspector; the source gets the root. Regenerate `app/lib/main.inject.dart` and `app/test/helpers/test_component.inject.dart` with `dart run build_runner build -d` in `app`.
- `app/lib/src/features/shell/shell_toast.dart` -- `ShellToasts.show(ShellToastEntry(tone: error, build: ZsToast(...)))` for launch failures (pattern `sync_model.dart:221`).
- `app/lib/src/features/window/app_window_actions.dart` -- `AppWindowActionsScope.maybeOf(context)?.openSettings(target: SettingsTarget.general)` for "Choose editor…" (pattern `graph_card_menu.dart:651-680`).
- `app/lib/src/links.dart` -- the detached `Process.start('/usr/bin/open', …)` pattern.
- `packages/zanshin_core/lib/src/environment/login_shell.dart:94-105` -- keep the first adopted variables; `adoptedLoginShellEnvironment()` (decoded, lossy UTF-8); export in `packages/zanshin_core/lib/zanshin_core.dart:9`; test the decoding helper in `test/environment/login_shell_test.dart` (the success path calls FFI and installs a process-global environment, so no test adopts for real).
- `packages/zanshin_settings/lib/src/model/general_settings.dart` -- `diffFileList` (enum `DiffFileListSetting`, unknown → flat), `editor` (`String?`); regenerate `.freezed.dart` / `.g.dart` (`dart run build_runner build -d`); export the enum.
- `app/lib/src/features/settings/general_tab.dart:166-235` -- Diffs group (+ File list row); new Editor group; `settings_widgets.dart` `SettingsRow`, `SettingsGroup`, `SettingsTextField`.
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart:23-157, 194-378` -- `ZsMenuItem` (`cmd` hint, `enabled`, `tooltip`), `ZsMenuSeparator`, `ZsMenuNote`, `ZsMenuAnchor` + `ZsMenuController.open(position:)`; right-click pattern `app/lib/src/features/projects/projects_tree.dart:1000-1011`.
- `packages/zanshin_ui/lib/src/icons/zanshin_icon.dart` + `assets/icons/svg/` -- add `listFlat`, `listTree` (pattern: the `parent` glyph, commit eb8efe95).
- Mock-up: `_bmad-output/implementation-artifacts/design/inspector-study.jsx:169-197` (tree), `:380-464` (files pane, keys), `:266-321` (diff header copy), `:510-527` (menus), `:223-249` (menu), `inspector-study.css:88-136, 188-208`.
- DS: `design_system/components/content/FileRow.{jsx,d.ts,prompt.md}`, `content.css:1-19`, `content.card.html`, `DiffView.jsx` (path), `components/brand/Icon.*`, `assets/icons/ui/`, `assets/icons/glyphs.json`, `ui_kits/desktop/inspector.jsx`, `kit.css`, `_ds_bundle.js`, `readme.md`; `design/DESIGN-SYSTEM-SYNC.md:230-250`.
- Tests: `app/test/features/graph/graph_inspector_test.dart` (fake details, `pump(tester, width:)`, constructs `InspectorViewModel` at `:506`), `inspector_diff_test.dart`, `app/test/features/settings/` (general tab), `app/test/features/undo_timeline/operation_changes_test.dart`, `packages/zanshin_settings/test/`.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_core/lib/src/environment/login_shell.dart` (+ export, test) -- keep and expose the adopted environment -- editors are found and started with the login shell's `PATH`.
- `packages/zanshin_settings/lib/src/model/general_settings.dart` (+ generated, export, test) -- `diffFileList`, `editor` -- defaults and round trip.
- `packages/zanshin_ui` -- glyphs `listFlat`, `listTree` (svg + `ZI`) -- the switch's icons.
- `app/lib/src/features/graph/project_files.dart` (new) -- `ProjectFiles` (root, absolute/relative, exists, copy, open in editor, reveal, failure toast) and pure helpers `editorCommand`, `splitCommandLine`, `findOnPath`, `detectEditors` -- one place for the disk actions; unit tests with a fake `StartProcess` and temp dirs.
- `app/lib/src/features/graph/inspector_path_label.dart` (new) -- a `RenderBox` with name, head, tail text slots and the cut order -- name-first rows and the diff header.
- `app/lib/src/features/graph/inspector_file_tree.dart` (new) -- pure tree building (join chains, sort, visible rows by collapsed set) -- tests.
- `app/lib/src/features/graph/graph_inspector.dart` -- rows, folder rows, switch, keys, ⌘C, menus (file, folder, chip), model additions, doc comments.
- `app/lib/src/features/graph/inspector_diff.dart` -- copyable header path, line menu, `diffNewLineAt`.
- `app/lib/src/features/undo_timeline/operation_changes.dart` + fakes -- root and the header copy.
- `app/lib/src/features/home/project_scope.dart` (+ `build_runner` in `app`) -- provide `ProjectFiles`, root to the source.
- `app/lib/src/features/settings/general_tab.dart` -- File list row; Editor group.
- `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`) -- every new string.
- `app/widgetbook/folders/graph.dart` -- use cases: Inspector › Tree, the file-row menu open, a long path at 460.
- Tests in `app/test/features/graph/`, `settings/`, `undo_timeline/` -- one per I/O row and AC.
- DS (C, E; no publish) and DESIGN-SYSTEM-SYNC #25 dated line.

**Acceptance Criteria:**
- Given the 460-point inspector, when the file list shows `packages/logic_designer/lib/src/presentation/widgets/automation_overview_page.dart`, then `automation_overview_page.dart` is shown whole.
- Given tree chosen in the Changes header, when the app restarts (a new `SettingsStore` on the same file), then the list is a tree, listing the same files as flat.
- Given the IntelliJ launcher set and a fake launcher, when the user picks Open in IntelliJ IDEA at line 12 on a diff line, then the fake sees `idea --line 12 <absolute path>`; Reveal in Finder runs `open -R <absolute path>`.
- Given the diff header of the focused file, when the user clicks the path, then the clipboard holds its absolute path and "Copied" shows.

## Spec Change Log

## Review Triage Log

### 2026-11-14 — Review pass
- verdicts: 36 findings — high 0, medium 1, low 34, false 1, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind) `editorCommand` replaces `{file}` then `{line}`, so a path holding the literal text `{line}` is changed — a workspace path with `{line}` in it is not met in use.
  - `[low]` `[patch]` (blind) `editorHint` drops the whole file argument, so `code --goto` / `zed` hints lose the line — the hint keeps the rest of a file argument (`code --goto :12`).
  - `[low]` `[reject]` (blind) the line menu replaces the selection's own right-click menu (Copy, Select all) — the approved mock-up's line menu replaces the native menu too (`inspector-study.jsx:339`, `preventDefault`); ⌘C still copies a selection.
  - `[medium]` `[patch]` (blind) no copy but the diff header gives feedback; nothing announces to VoiceOver, unlike `_CopyId` — every copy (menus, ⌘C, chip, header) now announces "Copied".
  - `[low]` `[patch]` (blind) the launch-failure log names neither program nor reason — the log carries both.
  - `[low]` `[patch]` (blind) a custom program like `~/bin/subl` is never expanded and fails as not found — a leading `~/` is expanded from the environment's `HOME`; the "not on PATH" wording for an explicit path is left (rare).
  - `[low]` `[patch]` (blind) Settings' `editors` seam is never used, so the Settings test reads the host `PATH` and the detected branch is untested — grouped with the verification-gap row below; a hermetic test injects detection.
  - `[low]` `[reject]` (blind) a hand-edited `general.editor` without `{file}` leaves Open disabled without a reason — Settings refuses such a command; only a hand edit reaches it, and the fix adds a branch.
  - `[low]` `[reject]` (blind) `diffNewLineOf` falls back to the hunk's first line when a line is not found — only a rebuilt conflict-header cell misses (left and right numbers null); a right-click there is rare and the fix adds a branch.
  - `[low]` `[reject]` (blind) collapsed folders are keyed by the joined path and never pruned — session-only by design; a handful of strings per session, and a chain that joins differently in another change simply shows open.
  - `[low]` `[patch]` (blind) missing tests: folder menu, ⌘C on a folder, side-by-side line menu, Choose editor in a window, path-label cut stages, a held arrow over a folder — the first five added with the verification-gap rows; the held-arrow-over-folder case is covered by the `_select` rule (a folder row takes no pending diff) and not added.
  - `[low]` `[reject]` (blind) the list rebuilds the tree and per-folder sums on every build — O(files × depth) string work beside the per-row widgets the non-lazy list (10.38) already builds; not measurable next to them.
  - `[low]` `[reject]` (blind) `statusM` / `statusMBg` look orphaned — they mirror the DS tokens `--status-m` / `--status-m-bg` (`tokens/colors.css:63,103`), which the token parity keeps; removing a DS token is not this story's.
  - `[low]` `[reject]` (blind) a stored launcher not on `PATH` gets no warning in Settings — the spec lists it on purpose; the launch toast names the reason.
  - `[low]` `[reject]` (blind) the chip copy bypasses `ProjectFiles.copy` and drops a clipboard error silently — the chip works without a workspace root; its announce comes with the copy-feedback patch, a logged clipboard failure adds nothing a user meets.
  - `[low]` `[patch]` (edge) a folder row's `Flexible` name and `Spacer` split the free room, cutting long joined names early — the name takes the room up to its width, the pill follows it.
  - `[low]` `[reject]` (edge) same as the hand-edited editor row above.
  - `[low]` `[patch]` (edge) `~` and relative programs in a custom command — grouped with the tilde patch; relative programs (`./tool`) are rejected (no working directory is meaningful for a GUI launch).
  - `[low]` `[reject]` (edge) a rebuilt side-by-side conflict-header cell maps to the hunk's first line — same as the `diffNewLineOf` row above.
  - `[low]` `[reject]` (edge) a right-click on a filler cell or hunk header opens nothing — no line stands there; nothing wrong happens.
  - `[low]` `[reject]` (edge) the selection's Copy / Select all menu is gone — same as the blind row above.
  - `[low]` `[patch]` (verification gap) the side-by-side line menu is never exercised — test added.
  - `[low]` `[patch]` (verification gap) the folder menu and ⌘C on a folder are untested — test added.
  - `[low]` `[patch]` (verification gap) "Choose editor…" inside a window is never checked — test with a recording `AppWindowActions`.
  - `[low]` `[patch]` (verification gap) the path label's tail-before-head order is not pinned — render test at three widths.
  - `[low]` `[patch]` (verification gap) Settings detection never injected; the test reads the host `PATH` — hermetic test with `editors: () => ['idea']`.
  - `[low]` `[patch]` (verification gap) the failure toast's text is unchecked — test builds the toast and checks program and reason.
  - `[low]` `[defer]` (verification gap) nothing tests that a successful adoption stores the environment — a real adoption installs a process-global Rust environment that would leak across test files; deferred.
  - `[false]` `[reject]` (intent) the I1 outcome under `## Auto Run Result` is missing — it is written at finalization of this run, not in the reviewed diff.
  - `[low]` `[reject]` (intent) witness 4 runs a recording `StartProcess`, not a spawned fake executable — a detached child cannot report its arguments back; the seam receives exactly what `Process.start` gets.
  - `[low]` `[defer]` (intent) the "To check in the story" IntelliJ items live only in the Design Notes — they need Ralph's IntelliJ; now a deferred item mirrored to deferred-work.md.
  - `[low]` `[patch]` (intent) the side-by-side line menu is tested only through `diffNewLineOf` — same test as the verification-gap row.
  - `[low]` `[patch]` (intent) "Choose editor…" is tested only disabled — same test as the verification-gap row.
  - `[low]` `[patch]` (intent) the menu's Copy path row is never chosen in a test — test added.
  - `[low]` `[defer]` (intent) no Marionette check of the catalogue against the DS cards and the mock-up — the unattended run has no catalogue session (as in 10.38); deferred.
  - `[low]` `[reject]` (intent) the 460-point witness runs with the test font — the cut order is what the widget decides; the real-font look belongs to the deferred Marionette check.

## Design Notes

- **Why the environment lives in zanshin_core:** Rust already keeps the first adopted environment process-wide; the Dart mirror is the same value, so detection and launching match what jj's `git` sees. A Finder launch has launchd's `PATH`, which never holds `idea`.
- **Why one menu anchor per surface:** the file list, the diff body and each chip own one `ZsMenuAnchor`; the right-click stores its target, then opens the menu at the pointer. Entries (with the disk check) are built only for that target, not for every row on every build.
- **Name-first cut:** CSS shrink factors (head 1000, tail 1, name last) have no Flex equivalent; the label measures each slot's max intrinsic width and hands out what is left in that order.
- **TO CHECK in the story** (IntelliJ Go to File with `path:line`; `idea --line` in the running IntelliJ): needs Ralph's IntelliJ; the run may not start a real editor, so it is deferred to Ralph.

## Verification

**Commands:**
- `dart run build_runner build -d` in `packages/zanshin_settings` and in `app` -- generated files updated.
- `flutter gen-l10n` in `app` -- output committed.
- `flutter test` in `packages/zanshin_core` (`test/environment/`), `packages/zanshin_settings`, `packages/zanshin_ui` -- pass.
- `cargo make test-app test/features/graph test/features/settings test/features/undo_timeline test/features/home test/widgetbook test/l10n test/architecture` -- pass.
- `dart analyze app packages/zanshin_core packages/zanshin_settings packages/zanshin_ui` -- no issues.
- `dart format --set-exit-if-changed` on the touched directories -- 0 changed.
- Not run (gate rule of the story loop): `cargo make test`, `test-full`, `coverage`. No Rust changes.

**Verification notes (2026-11-14, gate rule of the story loop: no full gate):**
- `dart run build_runner build -d` in `packages/zanshin_settings` and `app`; `flutter gen-l10n` in `app` -- run by the implementation; outputs committed.
- `flutter test` in `packages/zanshin_settings` -- 60 passed; `packages/zanshin_ui` -- 472 passed; `packages/zanshin_core` `test/environment/` -- 10 passed.
- `cargo make test-app test/features/graph test/features/settings test/features/undo_timeline test/features/home test/widgetbook test/l10n test/architecture` -- 1683 passed before the review patches, 1689 passed after them.
- `dart analyze app packages/zanshin_core packages/zanshin_settings packages/zanshin_ui` -- No issues found (before and after the patches).
- `dart format --set-exit-if-changed -o none` on `app/lib`, `app/test`, `app/widgetbook` and the three packages' `lib` and `test` -- 0 changed (before and after the patches).
- `node --check design_system/_ds_bundle.js` -- passes (implementation run).
- Not run: `cargo make test` / `test-full` / `coverage` (the loop's gate rule); no Rust or FFI changed, so no cargo checks, codegen or parity oracle. Not done: the Marionette check and the IntelliJ checks (deferred).

## Auto Run Result

Status: done

**Summary.** The inspector's file rows show the name first and the folder dimmed, cut in its middle (`InspectorPathLabel`, a RenderBox: head, then last folder, then name); a rename shows its new name with `old → new` as tooltip; badges are 17 px with M / R on `--accent-soft`. A flat/tree switch in the Changes header and a Settings › Diffs row write `GeneralSettings.diffFileList`; the tree joins one-child folder chains, folder rows have a chevron, a three-state checkbox, a count and summed ±, and folders collapse for the session. The list takes ↑ ↓ ← → ↩ Space V ⌘C. Context menus on file rows, folders, diff lines (both layouts; a removed line takes the next new line) and bookmark chips offer Open in Editor, Reveal in Finder (`/usr/bin/open -R`), Copy path (absolute), Copy relative path, Copy path:line and Copy name; a path not on disk disables Open and Reveal with the reason, and changes other than @ end with the on-disk note. The diff header path copies the absolute path ("Copied" for 1.3 s), also in the operation view. Settings › General › Editor chooses `idea` / `code` / `zed` found on the login shell's `PATH` (zanshin_core's new `adoptedLoginShellEnvironment()`) or a custom command with `{file}` / `{line}`; without one the row reads "Choose editor…" and opens Settings. Failed starts show an error toast. DS: `FileRow`, glyphs `list-flat` / `list-tree`, `DiffView` `copyPath`, the kit inspector; not published (the loop publishes). DS synced through #26.

**Commits.** `5f23a56a55062fd17f212a4b4c8034faa4d41dbf` (code, tests, DS, DESIGN-SYSTEM-SYNC #25 line); the docs commit (this spec, sprint status, epic 10 context, deferred work) follows it.

**Files changed.**
- `app/lib/src/features/graph/project_files.dart` (new) -- `ProjectFiles` (absolute paths, disk check, copy with announce, Open in Editor, Reveal, failure toast) and the editor / PATH helpers.
- `app/lib/src/features/graph/inspector_path_label.dart` (new) -- the name-first label.
- `app/lib/src/features/graph/inspector_file_tree.dart` (new) -- tree and flat rows.
- `app/lib/src/features/graph/graph_inspector.dart` -- model additions, name-first rows, folder rows, switch, keys, menus (`inspectorPathMenu`), chip menu.
- `app/lib/src/features/graph/inspector_diff.dart` -- copyable header path, line menu, `diffNewLineAt` / `diffNewLineOf`.
- `app/lib/src/features/undo_timeline/operation_changes.dart` -- `OperationChangesSource.root`, copyable header path.
- `app/lib/src/features/home/project_scope.dart` (+ generated inject files) -- provides `ProjectFiles`, the root to the operation source.
- `app/lib/src/features/settings/general_tab.dart` -- File list row, Editor group.
- `app/lib/l10n/*` -- new strings; `app/widgetbook/folders/graph.dart`, `undo_timeline.dart` -- use cases Tree, Long path, File menu, Line menu.
- `packages/zanshin_core/lib/src/environment/login_shell.dart`, `zanshin_core.dart` -- the adopted environment kept and exported.
- `packages/zanshin_settings/lib/src/model/general_settings.dart` (+ generated) -- `diffFileList`, `editor`.
- `packages/zanshin_ui` -- glyphs `listFlat`, `listTree`.
- Tests: `graph_inspector_test.dart`, `inspector_diff_test.dart`, `inspector_file_tree_test.dart`, `project_files_test.dart`, `settings_window_test.dart`, `operation_changes_test.dart`, settings and core tests.
- DS: `components/content/FileRow.*`, `DiffView.jsx`, `content.css`, `content.card.html`, `components/brand/Icon.*`, `brand.card.html`, `assets/icons/ui/list-*.svg`, `glyphs.json`, `ui_kits/desktop/inspector.jsx`, `kit.css`, `_ds_bundle.js`, `readme.md`; `design/DESIGN-SYSTEM-SYNC.md` dated line under #25.

**Review findings.** 36 findings: high 0, medium 1, low 34, false 1. Patched: 1 medium (no copy announced to VoiceOver) and 6 low code entries (hint keeps the line, failure log detail, `~/` expansion, folder name room) plus 8 test rows (side-by-side line menu, folder menu and ⌘C, Choose editor in a window, label cut order, hermetic editor detection, toast text, Copy path row). Deferred 3 (IntelliJ checks, Marionette check, adoption-store test; all low, mirrored to deferred-work.md). Rejected 18 with reasons in the triage log, 1 false.

**Follow-up review recommendation: false.** Patched this pass: high 0, medium 1, low 14 rows. One medium patch and no high do not reach the threshold.

**Deferred-work items.**
- **I1** (inspector too narrow; scrolling between file list and diff) -- fixed (`5f23a56a55062fd17f212a4b4c8034faa4d41dbf`, with Story 10.38's `ce0b31de`): this story adds the remaining part -- name-first file rows, tree / flat, copy, Reveal in Finder and Open in Editor.

**Residual risks.**
- Not checked visually through Marionette (deferred); the DS kit and cards were not re-opened in a browser after the review patches (no DS file changed in them).
- Real IntelliJ behaviour (`idea --line` in the running IntelliJ, Go to File with `path:line`) unverified (deferred to Ralph).
- The other Settings rig tests still let the General tab `stat` `idea` / `code` / `zed` on the host `PATH`; no assertion depends on it.
- A slow right-click on a diff line may also select a word through the selection area; the selection's own right-click menu is replaced by the line menu (as in the mock-up); ⌘C still copies a selection.
