---
title: 'Story 5.14 — One diff style, jj''s: a switch for the word marks, no Conflicts row'
type: 'refactor'
created: '2026-11-14'
status: 'done'
baseline_revision: 'c71404e6f3352e8064d791d98d3b94971fd4f079'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The design system artifact and the app design canvas still show Stories 5.11 and 5.13's two styles: the run could not republish them.
    evidence: |-
      The permission classifier refused the implementation run's publish to the DS artifact J5iSiy8cS6Q1EXa44g945d. The repo files under design_system/ are updated (DiffView, DiffHunk, content.css, both cards, _ds_bundle.js, readme), and build_ds.py built the publish tree in that run's scratchpad, which a later session cannot rely on.
    location: >-
      _bmad-output/implementation-artifacts/design_system/ (publish per .claude/skills/design-artifacts/SKILL.md A and B)
    severity: medium
  - summary: >-
      The DS UI kit's Settings dialog and the click dummy's Settings page still show the Diffs group with Layout only: no Changed words switch, Inline changes or Context lines.
    evidence: |-
      design_system/ui_kits/desktop/dialogs.jsx:273-275 and design/settings.jsx (Diffs group) list only Layout. The rows have been missing there since Story 5.11, and Story 5.12 left the click dummy for the next design round. The Settings card (components/settings/settings.card.html) now shows all four rows.
    location: >-
      _bmad-output/implementation-artifacts/design_system/ui_kits/desktop/dialogs.jsx:273
    severity: low
---

<intent-contract>

## Intent

**Problem:** The diff has two word-mark styles: jj's (Story 5.10) and Zanshin's `DiffMarks::Words` on the `similar` crate (Stories 5.11, 5.13). Ralph rejected the second one. He also wants to switch off the marks of the changed words inside a line, and Settings' Conflicts row (5.12) looks like it does nothing.

**Approach:** Remove the Zanshin style completely: Rust, the `similar` crate, wire, Dart bridge, setting, strings, catalogue and design system. Every diff takes jj's path. Add a `bool` app setting `diffWordMarks` (default `true`). Settings › General › Diffs shows it as a switch in the "Changed words" row. It changes only how the inspector and the operation view draw, with no reload. Remove the Conflicts row; the diff still reads `diff.color-words.conflict` from jj's config.

## Boundaries & Constraints

**Always:**
- jj's path stays byte-for-byte: lines, hunks, numbers, counts, sections, fingerprints, conflict handling (`materialize` and `pair`), `-w` / `-b`, summary mode, and Story 5.10's tests with their expectations. After the change, `crates/zanshin-jj/src/hunks.rs` equals its pre-5.11 version (`e5d27d75`) plus only the loop refactor from `0e63134b` (`Walk::resolved_hunks`, index `hunk.contents[0]` / `[1]` instead of the `if let` with an unreachable else).
- A search for `DiffMarks` and `DiffMarksSetting` (case-sensitive) finds nothing in code, schema, generated files, tests, catalogue, design system or `docs/`. Spec history, `epics.md`, `sprint-status.yaml`, `deferred-work.md` and `epic-5-context.md` may still name them. `Cargo.lock` has no `similar` entry.
- The setting is `GeneralSettings.diffWordMarks` (`@Default(true) bool`, JSON key `diffWordMarks`). A settings file that still holds `"diffMarks"` loads without error, and the old key is ignored.
- The view draws by the current switch value. The models read it from `SettingsStore` and notify on a change. Flipping it calls `diff` / `GraphDetails.diff` zero times.
- **Switch on:** today's jj-style marks (`diffWordMarks` rule of 10.32 / 5.10: fill on `--rem-word-bg` / `--add-word-bg`, `--text` glyphs). **Switch off:** no word-mark fill on any line. A run that the on-state would mark is drawn as text in its side's hue (`ZsColors.rem` for removed, `ZsColors.add` for added) with no fill. So on a `changed` line removed runs are red text, added runs green text, and kept text keeps the line's ink. On removed and added lines and on side-by-side cells, the hue equals the line ink, so they show only their fill and ink.
- Schema edits follow project-context.md: edit `schemas/envelope.fbs` in place, run `cargo make codegen`, commit the generated files.
- Gate rule of this run: no `cargo make test` / `test-full` / `coverage`. Run only the targeted checks under Verification. Add the tests that each new or changed line needs.

**Never:**
- A third style, the Zanshin style behind a flag, a setting for jj's colours, or a toggle in the diff bar.
- Any change to jj's lines, hunks, colours, `config.rs`'s `diff.color-words.*` reading or the parity oracle's expectations.
- Lowering `coverage-baseline.txt`, or adding an `exclude_prefix`.
- Running jj outside temp directories this run creates. The Marionette check in the real app is left to the story loop's main session.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Old settings file | `{"general": {"diffMarks": "words"}}` or `"jj"` | Loads; `diffWordMarks == true`; a save writes `diffWordMarks`, not `diffMarks` | No warning, no exception |
| Switch off in the file | `{"general": {"diffWordMarks": false}}` | `diffWordMarks == false`; round-trips | A non-bool value throws `CheckedFromJsonException`, as `hideControls` does |
| Settings rows | General tab, fresh config | Diffs group: Layout, Changed words (a `ZsSwitch`, on), Inline changes (jj hint only), Context lines; no Conflicts row, no `diff.color-words.conflict` key text | — |
| Toggle the switch | Tap the Changed words switch | `general.diffWordMarks` flips in the store; no jj config write | A failed store write is swallowed like the other preferences |
| Switch on, changed line | `~2454 2459\|{+        .map_err(+}GitResetHeadError::from_git[-(err.into_error())-])?;` | Two painted marks (`addWordBg`, `remWordBg`) as today | — |
| Switch off, changed line | same line | No painted mark; the added run in `colors.add`, the removed run in `colors.rem`, the rest in `colors.text` | — |
| Switch off, removed / added line or side-by-side cell | a removed line with a marked word | No painted mark; the whole text in the line's ink | — |
| Flip with a diff open | Inspector or operation view showing a file | Repaints with the new state; no new `diff` call; the focused path and the scroll position stay | — |
| Pair conflicts from config | `diff.color-words.conflict = "pair"` in jj config, a conflicted side | Header lines and swapped roles as in Story 5.10 (`pairing_*` tests, `conflict_diff` in `tests/it/hunks.rs`) | — |

</intent-contract>

## Code Map

- **Rust, `crates/zanshin-jj`:**
  - `src/hunks.rs`: restore the `e5d27d75` version with `git restore --source=e5d27d75 -- crates/zanshin-jj/src/hunks.rs`, or remove by hand if that command is denied. Then re-apply `0e63134b`'s loop refactor in `Walk::resolved_hunks` (`git show 0e63134b -- crates/zanshin-jj/src/hunks.rs`, first hunk). This removes `DiffMarks`, the `marks` fields of `HunksOptions` / `DiffOptions` / `RevisionDiff` / `WalkOptions`, the `DiffReader::new` parameter, `Walk::word_lines`, `WORD_MARKS_LIMIT`, `tokenize` … `run_lines`, the `Words` tests and fixtures (`error_cleanup`, `widget_witness`, `stepper_witness`, `words*`, `pair_diff_in`, `side_texts`, `both_styles_keep_the_lines`), and the module and `DiffMarks::Words` docs.
  - `src/lib.rs:119-122`: drop `DiffMarks` from `pub use hunks::{…}`.
  - `src/repo.rs:~4416-4470`: the `compute_hunks` and `diff` docs lose their `marks` sentences (`git show ecd0105d -- crates/zanshin-jj/src/repo.rs` shows what 5.11 added; 5.13 reworded one).
  - `tests/it/diff.rs`: remove `DiffMarks` from the imports (line 14) and remove `the_words_style_keeps_the_files_and_reports_itself` (~198-240).
  - `tests/it/hunks.rs:~158,418,690,745`: remove the four `..HunksOptions::default()` lines. Every field is set without them, so clippy's `needless_update` would fire.
  - `tests/it/api_stability.rs:~1821-1895`: remove the `marks` fields and the `DiffMarks` asserts in `compute_hunks_surface_resolves`.
  - `Cargo.toml:54` and `crates/zanshin-jj/Cargo.toml:30`: remove the `similar` lines. Cargo then drops `similar` from `Cargo.lock` on the next build or test.
- **FFI and wire:**
  - `schemas/envelope.fbs:~360-366`: remove `enum DiffMarks`, its doc, `DiffRequest.marks` (~407) with its doc line, and `Diff.marks` (~3291) with the "Story 5.11 appends" sentence. Then run `cargo make codegen`. It regenerates `crates/zanshin-ffi/src/envelope_generated.rs`, `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` and `bindings.dart`.
  - `crates/zanshin-ffi/src/diff.rs`: revert 5.11's additions (`git show ecd0105d -- crates/zanshin-ffi/src/diff.rs` lists them): the import, `marks: diff_marks(…)`, `diff_marks`, `wire_marks`, `marks: wire_marks(…)`, the doc sentences (as reworded by 5.13), and in tests `diff_from_wire`'s `marks`, `sample()`'s `marks`, the "word-mark style rides the payload" block, `Request.marks`, the `Words` request case and the unknown-marks case.
  - `crates/zanshin-ffi/tests/it/diff_ffi.rs`: the import, `..HunksOptions::default()` (~73), `assert_wire_is`' marks block (~178-183), `Req.marks`, and `marks_reach_the_diff_and_come_back` (~590-660).
  - `docs/ffi-abi.md:~2476, 2510-2539, 2574, 2580, 2592, 2609-2610, 2627`: remove the `marks` / `DiffMarks` text. `ffi_abi_doc_sync` checks this against the schema.
- **Dart bridge, `packages/zanshin_core`:**
  - `lib/src/ffi/diff.dart`: remove `enum DiffMarks` (~47-66), `Diff.marks` (constructor ~257, field ~283), `zanshinDiff`'s `marks` (~310-343), and the decode switch (~378-381).
  - `lib/src/worker/handle.dart:9, ~1650-1685`, `commands.dart:8, ~2332-2340`, `isolate.dart:~1817, 1842, 4679, 4697`: remove the `marks` parameters, fields and imports.
  - `lib/zanshin_core.dart:35`: remove `DiffMarks` from the export.
  - Tests: `test/ffi/diff_test.dart:~294-308` ("every DiffMarks …") and `test/worker/diff_test.dart:~174-190` (`marks_cross_the_buffer_and_come_back` and 5.13's merged-line test there) go.
- **Settings model, `packages/zanshin_settings`:**
  - `lib/src/model/general_settings.dart`: `DiffMarksSetting` and `diffMarks` go. Add `/// … @Default(true) bool diffWordMarks` with a doc that names Settings › General › Diffs › "Changed words". Run `dart run build_runner build --delete-conflicting-outputs` in the package to regenerate `.freezed.dart` and `.g.dart`.
  - `test/model/app_settings_test.dart:23,66,105,114,118-125`: expected JSON uses `'diffWordMarks': true`. Replace the "diff marks default …" test with: the default is on; `false` round-trips; `{'diffMarks': 'words'}` and `{'diffMarks': 'jj'}` load with the switch on; a non-bool value throws.
  - `test/settings_store_test.dart:19`: `_darkJson` holds `"diffWordMarks": true`. Add a load test: a file with `"diffMarks": "words"` loads with the switch on and logs no warning.
- **App:**
  - `app/lib/src/features/graph/inspector_diff.dart`:
    - Remove `diffMarksOf` (:15-19) and the `DiffMarksSetting` import.
    - `diffWordMarks(line)` loses its `marks` parameter and returns to the jj rule (:123-147).
    - `_lineText` (:229-268) takes `bool wordMarks`. On: as today. Off: the same spans, but a marked run is styled `TextStyle(color: kind == added ? colors.add : colors.rem)` and there is no `DiffWordMarks` painter.
    - `InspectorDiffView` and `InspectorDiffHunk` replace `marks` (:283/:311, :626/:636) with `final bool wordMarks` (default `true`), with docs. They pass it through at :404, :795 and :853.
  - `app/lib/src/features/graph/graph_inspector.dart`:
    - Replace `_marks` / `_loadedMarks` / `diffMarks` (:63, :81-83, :162-163) with `bool _wordMarks` from `settings.value.general.diffWordMarks` and a getter `wordMarks`.
    - `_settingsChanged` (:243-249) sets it and marks `changed`, with no `_reloadFocus`.
    - `_loadFocus` (:287-290) loses `marks:` and `_loadedMarks`. The class doc (:46-47) follows. Pass `wordMarks: model.wordMarks` at :2298.
    - Keep `configChanged` / `_reloadFocus` (5.12).
  - `app/lib/src/features/graph/graph_ports.dart:1013-1048`: `GraphDetails.diff` / `RepoGraphDetails.diff` lose `marks` (back to the pre-5.11 signature).
  - `app/lib/src/features/undo_timeline/operation_changes.dart`:
    - `OperationChangesSource.diff` and `RepoOperationChangesSource.diff` lose `marks` (:38-48, :71-87).
    - The model replaces `_marks` / `_focusedMarks` / `focusedMarks` with `_wordMarks` and a `wordMarks` getter. `_settingsChanged` (:180-191) only notifies on its change. `_rereadSelection` stays for `configWrites`.
    - `_diffOf` (:300-315) and `focus` (:372) lose marks. `_Files` passes `wordMarks: model.wordMarks` (:722, :748). The class doc (:99-100) follows.
  - `app/lib/src/features/settings/general_tab.dart`:
    - Replace the Changed words row (:184-201) with `SettingsRow(label: s.settingsDiffWordMarks, hint: s.settingsDiffWordMarksHint, child: ZsSwitch(label: s.settingsDiffWordMarksSwitch, identifier: 'settings-diff-marks', value: prefs.general.diffWordMarks, onChanged: …copyWith.general(diffWordMarks: on)))`, the "Hide controls" row pattern (:154-163).
    - The Inline row's hint becomes `s.settingsDiffInlineHint` (:206-209).
    - Remove `_diffConflictRow(s)` (:231) and the method (:316-345), plus the `tomlStringValue` import if nothing else uses it. The class doc (:62-64) follows.
  - `app/lib/src/features/settings/settings_view_model.dart:42-64`: `SettingsKeys.diffConflict` and its entries in `project` and `general` go. Only the row used it.
  - `app/lib/l10n/app_en.arb:1471-1511`, then run `flutter gen-l10n` in `app/`:
    - Remove `settingsDiffMarks*`, `settingsDiffInlineZanshinHint` and every `settingsDiffConflict*` string.
    - Add `settingsDiffWordMarks` ("Changed words"), `settingsDiffWordMarksHint` ("Marks the words that changed inside a line, where jj diff underlines them.") and `settingsDiffWordMarksSwitch` ("Mark changed words", the VoiceOver name).
    - The descriptions of `@settingsDiffInline` / `@settingsDiffInlineHint` no longer name the two styles.
  - Fakes and callers lose `marks` / `DiffMarks`:
    - `app/test/features/graph/graph_inspector_test.dart:218-285`
    - `app/test/features/graph/graph_card_menu_test.dart:~200-205`
    - `app/test/helpers/fake_undo_timeline.dart:140-198`
    - `app/integration_test/glass_profile.dart:33, 291-296`
    - `app/widgetbook/folders/graph.dart:50, ~1047-1056`
    - `app/widgetbook/folders/undo_timeline.dart:~215-225`
  - Tests:
    - `app/test/features/graph/inspector_diff_test.dart`: remove `view(…, marks:)` (:241-248), the `Words` group test (:206-227) and the widget tests at :321-395. Add the switch-off tests: a changed line in both layouts, and a removed line.
    - `app/test/features/graph/graph_inspector_test.dart:1211-1214, 1395-1420`: remove the `diffMarks: jj` setup, and rewrite the reload test as "flipping `diffWordMarks` repaints and calls diff zero times".
    - `app/test/features/undo_timeline/operation_changes_test.dart:18, 152, 306, 457-471`: the same for the operation view.
    - `app/test/features/settings/settings_window_test.dart:60-89, 219-425`: the switch row, the row order (Layout, Changed words, Inline changes, Context lines), and no Conflicts row. Remove the conflict write and readability tests (:299-321 conflict parts, :381-393). The Inline hint is the jj hint.
  - `app/widgetbook/folders/graph.dart:1736-1913`: `_WordMarks({required this.wordMarks})`, registered at :279 with `context.knobs.boolean(label: 'word marks', initialValue: true)`. It shows `_jjExample` and `_jjWidget` only, and passes `wordMarks:`. Remove `_wordsExample`, `_wordsWidget` and `_wordsCleanup`. The doc comment follows.
- **Design system, `_bmad-output/implementation-artifacts/design_system/`:**
  - `components/content/DiffView.jsx`, `DiffHunk.jsx`, `.d.ts` and `.prompt.md`: replace the prop `marks: "jj" | "words"` with `wordMarks?: boolean` (default `true`). `zsDiffLine` / `zsDiffSides` lose their `marks` parameter (jj rule only). `wordMarks={false}` adds a root class.
  - The content CSS (the file that holds `.zs-diff-line .w` at :48-50): under that class `.w` has no background, `.w.rem` uses `color: var(--rem)` and `.w.add` uses `var(--add)`.
  - `_ds_bundle.js`: hand-update both blocks (skill E).
  - `content.card.html`: remove the Zanshin hunks. Add a jj hunk with `wordMarks={false}`, and update the subtitle.
  - `components/settings/settings.card.html`: add a "Diffs" group with Layout and Changed words (a `Switch`, hint as in the app). Raise the viewport height if needed.
  - `readme.md`: add a dated sync line.
  - Publish per `.claude/skills/design-artifacts/SKILL.md` A, then B.
- **Docs:** `_bmad-output/project-context.md:863-885`: from "**The one sanctioned exception**" to "rules 1–6." goes. One sentence says Story 5.14 removed the second style and `GeneralSettings.diffWordMarks` only changes how word marks are drawn.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/hunks.rs`: restore `e5d27d75`, then re-apply `0e63134b`'s loop refactor. Rationale: removes the style and keeps jj's path exactly.
- `crates/zanshin-jj/{src/lib.rs,src/repo.rs,tests/it/diff.rs,tests/it/hunks.rs,tests/it/api_stability.rs}`, `Cargo.toml`, `crates/zanshin-jj/Cargo.toml`: remove `marks`, `DiffMarks` and `similar`. Rationale: the API and dependencies follow.
- `schemas/envelope.fbs`, then `cargo make codegen`; `crates/zanshin-ffi/src/diff.rs`, `crates/zanshin-ffi/tests/it/diff_ffi.rs`, `docs/ffi-abi.md`: remove the enum and fields. Rationale: the wire follows.
- `packages/zanshin_core` (`ffi/diff.dart`, worker `handle` / `commands` / `isolate`, `zanshin_core.dart`, both test files): remove `DiffMarks` and `marks`. Rationale: the bridge follows.
- `packages/zanshin_settings` (`general_settings.dart`, then build_runner; `app_settings_test.dart`; `settings_store_test.dart`): replace `diffMarks` with `diffWordMarks`, and add the old-file tests. Rationale: the switch and old files.
- `app/lib/src/features/graph/{inspector_diff,graph_inspector,graph_ports}.dart`, `app/lib/src/features/undo_timeline/operation_changes.dart`: draw by `wordMarks` with no reload, and remove marks from loads. Rationale: the switch's effect.
- `app/lib/src/features/settings/{general_tab,settings_view_model}.dart`, `app/lib/l10n/app_en.arb`, then `flutter gen-l10n`: the switch row, the jj Inline hint, and no Conflicts row. Rationale: Settings.
- App tests and fakes (listed in the Code Map), `app/integration_test/glass_profile.dart`, `app/widgetbook/folders/{graph,undo_timeline}.dart`: follow the API, add the switch tests, and add a knob to the catalogue. Rationale: tests and catalogue.
- Design-system files listed above, then publish (A, B). Rationale: the DS. If publishing fails, the result says so.
- `_bmad-output/project-context.md`: the paragraph. Rationale: the canonical rules.

**Acceptance Criteria:**
- Given the finished tree, when `rg -n "DiffMarks|DiffMarksSetting" crates packages app schemas docs _bmad-output/project-context.md _bmad-output/implementation-artifacts/design_system` and `rg -n 'name = "similar"' Cargo.lock` run, then both find nothing.
- Given the finished tree, when `git diff e5d27d75 -- crates/zanshin-jj/src/hunks.rs` runs, then it shows only `0e63134b`'s loop refactor.
- Given the parity oracle, Story 5.10's `hunks::` unit tests, `tests/it/hunks.rs` (the `pair` conflict test included) and `tests/it/diff.rs`, when they run, then they pass with unchanged expectations.
- Given the inspector with a file open, when the user flips Settings › General › Diffs › Changed words, then the open diff repaints in the new state and `GraphDetails.diff` is not called again. The same holds for the operation view's `OperationChangesSource.diff`.

## Spec Change Log

## Review Triage Log

### 2026-11-14 — Review pass
- verdicts: 27 findings — high 0, medium 1, low 20, false 5, maybe-false 1
- findings:
  - `[low]` `[patch]` (verification-gap) Nothing tests that the operation view passes the switch to its views. Its asserts `view.wordMarks, isTrue` cannot fail, because the widget defaults to `true`. — patched: a widget test turns the switch off and checks that the description block and the focused file's `InspectorDiffView` both get `wordMarks == false`.
  - `[low]` `[patch]` (edge) Side by side, switch off, under a `-------` conflict term: `pairSideBySide` gives the left cell kind `removed` but keeps its added runs, so green glyphs appear on a red cell. — patched: with the switch off, only a `changed` line keeps hue spans and every other line draws plain text in its ink. A test pins the swapped-term cell; the DS CSS got the same rule (`.chg` rows only).
  - `[low]` `[reject]` (edge) Without the Conflicts row, Settings cannot show or fix a malformed `diff.color-words.conflict`. — The intent removes the row. A malformed key still shows as the inspector's `jj.config_error` refusal, and the config-file page (11.19) edits it.
  - `[low]` `[reject]` (edge) A non-bool `diffWordMarks` now throws and moves the whole settings file aside, where the old enum fell back. — `hideControls` and every other flag work the same way, and only a hand edit can trigger it. The fix would add a custom converter, not a direct correction.
  - `[low]` `[reject]` (intent) Nothing shows UI evidence against the DS cards; the switch-off widget tests use only the default appearance. — The Marionette check in night and paper belongs to the loop's main session (spec, Never). The tests assert token identity (`colors.rem` / `colors.add`), and a theme loop adds no code path.
  - `[false]` `[reject]` (intent) Side by side with the switch off shows no per-word cue, against a reading where cells keep both hues. — A cell holds one side's runs only, and that side's hue is the cell's ink. No reading can show a second hue in a cell without a fill, so "only fill and ink" is the only reading that can be drawn.
  - `[low]` `[patch]` (intent) Side by side under a `-------` term is not tested. — Grouped with the edge row above and patched there.
  - `[false]` `[reject]` (intent) The jj-path test sources were edited, not left untouched. — `git diff e5d27d75` shows those tests identical to their pre-5.11 text. The edits only remove 5.11's additions; their expectations are untouched.
  - `[false]` `[reject]` (intent) The parity oracle's result is not visible in the diff. — It ran: `diff_color_words:: diff_revisions::`, 15 passed, expectations unchanged (Verification notes).
  - `[low]` `[patch]` (intent) The Content card's switch-off hunk is not jj output: its last line is the removed Zanshin picture, and `~2454:2457` is renumbered. — patched: the hunk now uses jj's lines 2453–2460 exactly as `_jjExample` pins them.
  - `[low]` `[patch]` (intent) The Settings card's Diffs group shows only Layout and Changed words; the app has four rows. — patched: Inline changes and Context lines were added with their `configKey`s, per Ralph's confirmation.
  - `[medium]` `[defer]` (intent) The design system was not republished. — The implementation run's publish to the DS artifact was refused by the permission classifier. The repo files are updated and the scratchpad tree was built; steps A and B of the `design-artifacts` skill remain (deferred).
  - `[false]` `[reject]` (intent) `project-context.md` replaces the paragraph with a note instead of deleting it. — The `DiffMarks::Words` paragraph is gone. The three-line note only records that the second style was removed and what the switch does.
  - `[low]` `[patch]` (intent) `deferred-work.md` and `sprint-status.yaml` are unchanged, and the spec is untracked. — patched at finalize: sprint-status entry and epic context set to done, deferred items mirrored, everything committed.
  - `[low]` `[reject]` (intent) A non-bool value throws. — Grouped with the edge row above, rejected for the same reason.
  - `[low]` `[patch]` (blind) Side by side, switch off, under `-------`: green glyphs on a removed cell, in the app and in the DS. — Grouped with the edge row above and patched there.
  - `[maybe-false]` `[reject]` (blind) With the switch off, a changed line shows red against green as its only cue, and no token test pins `--rem` / `--add` glyph contrast on `--code-bg`. — Hue-only text is jj's own colouring, which Ralph chose. To settle the contrast question, compute WCAG contrast of `--rem` / `--add` on `--code-bg` in night and paper. If it fails, the harm is low readability on a few glyphs, so it is rejected with this note.
  - `[low]` `[reject]` (blind) The hint and the VoiceOver name describe only the on state. — The story gives the hint text verbatim.
  - `[low]` `[patch]` (blind) The DS Settings card's Diffs group is incomplete. — Grouped with the intent row above and patched there.
  - `[low]` `[defer]` (blind) The DS UI kit (`ui_kits/desktop/dialogs.jsx`) and the click dummy (`design/settings.jsx`) still show a Diffs group with Layout only. — This predates the story: the Changed words row has been missing there since 5.11, and 5.12 left it for the next design round (deferred).
  - `[low]` `[patch]` (blind) The Content card's switch-off hunk is not jj output. — Grouped with the intent row above and patched there.
  - `[low]` `[patch]` (blind) The operation view's `wordMarks` asserts cannot fail, and no widget test flips the switch. — Grouped with the verification-gap row and patched there.
  - `[false]` `[reject]` (blind) The matrix row's "scroll position stays" is untested. — The flip only notifies: no reload, and no swap to `previousDiff`. The same tree rebuilds with the same `FileDiff` and its `Scrollable` keeps its state. The inspector test pins both "no reload" and "the loaded diff stays".
  - `[low]` `[reject]` (blind) A non-bool `diffWordMarks` costs all settings. — Grouped with the edge row above, rejected for the same reason.
  - `[low]` `[patch]` (blind) The epic context and `sprint-status.yaml` still say backlog. — Grouped with the intent bookkeeping row and patched at finalize.
  - `[low]` `[reject]` (blind) `diffWordMarks` names both the top-level function in `inspector_diff.dart` and the setting field. — Their scopes differ: a function over a `HunkLine` versus `general.diffWordMarks`, and each doc names its own item. A rename would touch the pre-existing function and its tests for no behaviour change.
  - `[low]` `[patch]` (blind) The catalogue's "Word marks" use case hard-codes unified, so side by side with the switch off cannot be shown. — patched: a layout knob was added.

## Design Notes

- **Why restore `hunks.rs` instead of deleting by hand.** Only three commits touched it after `e5d27d75`: 5.11 (`ecd0105d`), its fix-up (`0e63134b`) and 5.13 (`7629ab56`). Only `0e63134b`'s loop refactor is jj-path code. It drops an `else` that can never run, and the 100.00 coverage baseline of `hunks.rs` depends on it. A restore guarantees "jj path untouched" by construction, and the AC's `git diff` proves it.
- **Off state, one code path.** `_lineText` keeps the ranges `diffWordMarks` gives. Off only swaps the run style (fill and `--text` glyphs become side-hue glyphs) and drops the painter. On removed and added lines the hue equals the ink, so "only fill and ink" follows without a branch per kind. Context lines under `-w` / `-b` mark only blanks, so their hue text is invisible.
- **Names.** The l10n keys move from `settingsDiffMarks*` to `settingsDiffWordMarks*`, because a case-sensitive search for `DiffMarks` would also match `settingsDiffMarks`. The widget identifier `settings-diff-marks` stays.
- **Decided (Ralph, 2026-11-14, through the story loop's coordinator).** Settings › General › Diffs keeps the "Inline changes" row (`diff.color-words.max-inline-alternation`) and the "Context lines" row (`diff.color-words.context`) as they are. Only the Conflicts row goes. "Inline changes" loses only its Zanshin-style hint; the jj hint stays.
- **Off only colours a changed line (review pass).** With the switch off, only a `changed` line keeps its runs in their side's hue. Every other line draws plain text in its ink, in the app and in the DS (`.no-word-marks`). This keeps "only fill and ink" true for side-by-side cells under a `-------` conflict term too: there a left cell of kind `removed` holds the added runs.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib -- hunks::`; `cargo test -p zanshin-jj --test it -- hunks:: diff:: api_stability::` -- expected: pass.
- `cargo test -p zanshin-ffi --lib diff::`; `cargo test -p zanshin-ffi --test it -- diff_ffi:: ffi_abi_doc_sync::` -- expected: pass.
- `cargo test -p zanshin-parity --test oracle -- diff_color_words:: diff_revisions::` -- expected: pass, expectations unchanged.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`; `cargo fmt --all --check`; `cargo deny check advisories bans licenses` -- expected: clean.
- `cargo make codegen`, run twice -- expected: the generated files are committed, and the second run leaves no diff.
- `packages/zanshin_core`: `dart analyze`, `dart format --set-exit-if-changed .`, `dart test test/ffi/diff_test.dart test/worker/diff_test.dart` -- expected: pass.
- `packages/zanshin_settings`: `dart analyze`, `dart format --set-exit-if-changed .`, `flutter test` -- expected: pass.
- `app`: `flutter gen-l10n`; `dart analyze`; `dart format --set-exit-if-changed .`; `flutter test test/features/settings/ test/features/graph/ test/features/undo_timeline/ test/features/home/ test/widgetbook/` -- expected: pass.
- The AC searches (`rg`, `git diff e5d27d75`) -- expected: as stated.

**Manual checks (if no CLI):**
- In the catalogue "Inspector diff / Word marks", the knob off removes every fill, and the changed rows keep red and green text. The real app is checked with Marionette in night and paper, unified and side by side, against the DS cards, by the loop's main session.

**Verification notes** (2026-11-14, story run; per the story loop's rule, the full gate is not run here):
- **Rust:**
  - `cargo test -p zanshin-jj --lib -- hunks::`: pass (17).
  - `cargo test -p zanshin-jj --test it -- hunks:: diff:: api_stability::`: pass (102).
  - `cargo test -p zanshin-ffi --lib diff::`: pass (8). `cargo test -p zanshin-ffi --test it -- diff_ffi:: ffi_abi_doc_sync::`: pass (24).
  - `cargo test -p zanshin-parity --test oracle -- diff_color_words:: diff_revisions::`: pass (15), expectations untouched.
  - `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`: clean. `cargo fmt --all --check`: clean.
  - `cargo deny check advisories bans`: ok. `licenses` was dropped from the planned command because it fails on many unrelated crates; the gate runs only advisories and bans.
- **Codegen:** `cargo make codegen` was run twice; the second run left no diff. The four generated files equal their `e5d27d75` versions.
- **AC searches:**
  - `git diff e5d27d75` over `hunks.rs`, `lib.rs`, `repo.rs`, `tests/it/{diff,hunks,api_stability}.rs`, both `Cargo.toml` files, the schema, `zanshin-ffi` `diff.rs` / `diff_ffi.rs`, the generated files and `packages/zanshin_core/`: the only difference is `0e63134b`'s loop refactor in `Walk::resolved_hunks`.
  - `rg "DiffMarks|DiffMarksSetting"` over `crates packages app schemas docs`, project-context and the design system: nothing.
  - `Cargo.lock` has no `similar`. `cargo tree -i similar` showed only `zanshin-jj` before the change.
- **Dart:**
  - `packages/zanshin_core`: `dart analyze` no issues, `dart format` 0 changed, `dart test test/ffi/diff_test.dart test/worker/diff_test.dart` pass (21).
  - `packages/zanshin_settings`: `dart analyze` no issues, `dart format` 0 changed, `flutter test` pass (47).
  - `app`: `flutter gen-l10n` (no further change), `dart analyze` no issues, `dart format --set-exit-if-changed .` 0 changed.
  - `app`: `flutter test test/features/settings/ test/features/graph/ test/features/undo_timeline/ test/features/home/ test/widgetbook/` pass: 1519 before the review patches, 1521 after them. One rerun crashed in the flutter tool with `FileSystemException` errno 22 while the implementation agent's own `flutter test` ran at the same time; it passed once that run had ended.
- **Matrix test audit:** each matrix row has a passing test:
  - old file: `app_settings_test` and `settings_store_test`;
  - switch off in the file: `app_settings_test`;
  - Settings rows: `settings_window_test` (row order, no Conflicts row, its id absent);
  - toggle: `settings_window_test` (store flips, `rig.calls` empty);
  - switch on: the existing `inspector_diff_test` unified matrix test;
  - switch off: `inspector_diff_test` group "Changed words off" (unified; side by side; the swapped `-------` cell);
  - flip with a diff open: `graph_inspector_test` and `operation_changes_test` (zero `diff` calls, the loaded diff and focused path kept, both operation-view views get `false`);
  - pair conflicts: Rust `pairing_*` and `tests/it/hunks.rs` `conflict_diff`.
- **DS:** the implementation agent checked the Content and Settings cards in the Browser pane over `design-system-preview`, in both layouts, with no console errors.
- **Not run here:** the full gate and coverage (story-loop rule); the Marionette check in the real app (the loop's main session); the DS republish (refused by the permission classifier; deferred).

## Auto Run Result

Status: done

**Summary.** The diff has one style, jj's, and a switch for its word marks.

- **Removed:** the Zanshin style of Stories 5.11 and 5.13.
  - `crates/zanshin-jj/src/hunks.rs` is back to its pre-5.11 code (`e5d27d75`), plus only `0e63134b`'s loop refactor.
  - `DiffMarks` and every `marks` field are gone from Rust, the schema and its generated code, `zanshin-ffi`, `docs/ffi-abi.md` and `zanshin_core`.
  - `similar` is out of both `Cargo.toml` files and `Cargo.lock`.
- **The switch:** `GeneralSettings.diffWordMarks` (`bool`, default `true`) replaces `DiffMarksSetting`. An old `diffMarks` key loads with the switch on and is dropped on the next save.
- **Settings › General › Diffs:** Layout, Changed words (a `ZsSwitch`), Inline changes (jj hint), Context lines. Ralph confirmed on 2026-11-14 that both jj rows stay. The Conflicts row, its strings and `SettingsKeys.diffConflict` are gone; the diff still reads `diff.color-words.conflict`.
- **Drawing:** the inspector and the operation view follow the switch at once, with no reload.
  - On: today's jj marks.
  - Off: no word-mark fill. A `changed` line keeps its runs in their side's hue as text colour; every other line, side-by-side cells included, shows only its fill and ink.
- **Catalogue:** "Word marks" shows only jj's blocks, with knobs for the switch and the layout.
- **Design system:**
  - The repo files are updated: `wordMarks` / `.no-word-marks` in DiffView and DiffHunk, the Content card's switch-off hunk using jj's real lines, the Settings card's Diffs group, and the readme.
  - Not republished: the permission classifier refused the publish (deferred).

**Commits:**
- `1411b5399215e61a5338f2df8aa533f45350a1e6`: the implementation, the generated code, docs and the design system.
- The spec, epic context, sprint status and the `deferred-work.md` mirror come in the next commit.

**Files changed** (main ones):
- `crates/zanshin-jj/src/hunks.rs`, `lib.rs`, `repo.rs`, `tests/it/{diff,hunks,api_stability}.rs`, `Cargo.toml`, `crates/zanshin-jj/Cargo.toml`, `Cargo.lock`: the style, its tests and `similar` removed.
- `schemas/envelope.fbs` and its generated files (`envelope_generated.rs`, `zanshin_ffi.h`, `envelope_zanshin.ffi_generated.dart`, `bindings.dart`), `crates/zanshin-ffi/src/diff.rs`, `tests/it/diff_ffi.rs`, `docs/ffi-abi.md`: the wire without `DiffMarks`.
- `packages/zanshin_core` (`ffi/diff.dart`, worker handle / commands / isolate, export, tests): the bridge without `marks`.
- `packages/zanshin_settings` (`general_settings.dart` and generated code, tests): `diffWordMarks` and the old-file tests.
- `app/lib/src/features/graph/{inspector_diff,graph_inspector,graph_ports}.dart`, `app/lib/src/features/undo_timeline/operation_changes.dart`: the switch draws, nothing reloads.
- `app/lib/src/features/settings/{general_tab,settings_view_model}.dart`, `app/lib/l10n/*`: the switch row, no Conflicts row.
- App tests, fakes, `integration_test/glass_profile.dart`, `widgetbook/folders/{graph,undo_timeline}.dart`: follow the API; switch tests and knobs.
- `_bmad-output/implementation-artifacts/design_system/` (DiffView, DiffHunk, `content.css`, both cards, `_ds_bundle.js`, readme): the DS.
- `_bmad-output/project-context.md`: the `DiffMarks::Words` paragraph replaced by one note.

**Review findings:** 27 findings in total.
- **Patched:** 7 entries, all `low`:
  - operation-view switch test;
  - side by side under a `-------` term, in the app and in the DS CSS;
  - the Content card's jj lines;
  - the Settings card's four rows;
  - sprint-status and epic-context bookkeeping;
  - the catalogue's layout knob.
- **Deferred:** 2, mirrored in `deferred-work.md`:
  - the DS republish (medium);
  - the UI kit and click dummy Diffs rows (low).
- **Rejected:**
  - Conflicts-row loss of the config-error view: intended. The inspector refusal and the config-file page remain.
  - Non-bool `diffWordMarks` moves the file aside: same as `hideControls`; only a hand edit triggers it.
  - Default-appearance-only off tests: the Marionette check is the main session's; the tests assert token identity.
  - Side by side shows no per-word cue: `false`; a cell holds one side's runs only.
  - jj-path test sources edited: `false`; they equal their pre-5.11 text.
  - Oracle result not visible: `false`; it ran green.
  - project-context note: `false`; the paragraph is gone.
  - Hue-only cue and unpinned glyph contrast: `maybe-false`, `low` if true.
  - Hint describes only the on state: the story gives the text.
  - Scroll position untested: `false`; no reload means the same tree.
  - `diffWordMarks` name clash between a function and a setting: different scopes; a rename brings no behaviour change.

**Follow-up review recommendation:** `false`. This pass patched 0 high, 0 medium and 7 low entries.

**Verification:** see Verification notes. The Rust, codegen, Dart and AC checks all pass. The full gate, coverage and Marionette were not run here.

**Residual risks:**
- The DS artifact and the design canvas show the removed style until someone with publish permission republishes them (`design-artifacts` A, then B).
- Coverage is not measured here: `hunks.rs` is back to code that was at 100.00 with the same loop refactor, and the new Dart lines have tests. The loop's final gate confirms.
- The switch-off look (hue text on a changed line) has not yet been compared with the DS cards in the real app, in night and paper.
