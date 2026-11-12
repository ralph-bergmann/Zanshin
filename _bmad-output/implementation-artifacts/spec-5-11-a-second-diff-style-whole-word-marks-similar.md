---
title: 'Story 5.11 — A second diff style: whole-word marks by the longest common run (similar), switchable in Settings'
type: 'feature'
created: '2026-11-12'
status: 'done'
baseline_revision: 'e5d27d756feb8187e7c99432c68a273a0bf4ff04'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** jj's color-words marks are hard to read on some real changes: jj's word diff anchors on rare words, so in Ralph's widget-test example the old `testWidgets(` line finds no partner and in the jj `671e4eaca` example a rewritten call reads as kept text. Ralph decided (epics.md Story 5.11, 2026-11-12) on a second, switchable style built on the `similar` crate with the logic of his changed `terminal-inline` example.

**Approach:** Keep jj's line diff, hunks, numbers, context, sections and conflicts; only the step that turns one changed block into lines and segments (`Walk::diff_lines` in `crates/zanshin-jj/src/hunks.rs`) gets a second implementation, selected by a new `DiffMarks { Jj, Words }` option (Rust/FFI default `Jj`). Thread the option over the FlatBuffers wire, `zanshin_core`, a new `GeneralSettings.diffMarks` (app default `words`), every app diff load, the drawing, the design system, the catalogue and the docs.

## Boundaries & Constraints

**Always:**
- The second style's rule, per changed block of jj's line diff (a `Different` hunk of `diff_by_line`, i.e. the non-`context` call of `Walk::diff_lines`):
  1. A block with lines on one side only carries no word marks (every segment `Equal`).
  2. Otherwise the block's left bytes and right bytes (each already the joined lines) are decoded lossily as UTF-8 and compared with `similar::TextDiff::from_words` (Myers, its default). A token is a run of non-blanks or a run of blanks.
  3. Lines: all left lines (left numbers, kind `roles.before` → `Removed` normally), then all right lines (right numbers, kind of `roles.after`). Kind `Changed` never occurs in this style.
  4. On a left line `Delete` tokens are `roles.before` segments, on a right line `Insert` tokens are `roles.after` segments, all else `Equal`.
  5. A changed blank run is marked only where both its neighbours on the same line are marked non-blank tokens; indentation, trailing blanks and line breaks are never marked (a token holding `\n` is split at it first).
  6. A fixed size limit per block (constant, not time-based): above it, every segment `Equal`. Pick the limit by measuring the worst case (both sides with no common word) so one block stays within about 50 ms in a release build; record the measurement and the constant in Design Notes.
- `max-inline-alternation` has no effect in the `Words` style; `context`, `conflict` (`materialize` / `pair`, roles swapped under `-------`), `-w` / `-b` and summary mode apply to both. Context-labelled lines at `-w` / `-b` (the `context == true` call) keep the jj path in both styles: they are not a changed block of the line diff.
- For one file both styles give equal `fingerprint`, `sections`, hunk `before_range` / `after_range`, `symbol`, `removed` / `added`, the multiset of (left number, text) and (right number, text) per hunk — line texts and numbers survive a switch.
- Segment invariants hold in both styles: never empty, adjacent segments differ in kind, segments concatenate to the line text (with the `\n`).
- `similar` = "=3.2.1" in `[workspace.dependencies]`, `default-features = false, features = ["text"]`; `cargo deny` must accept Apache-2.0 (it does today if `deny.toml` allows it — check).
- The diff result reports its style: `RevisionDiff::marks`, wire `Diff.marks`, Dart `Diff.marks`.
- The app draws by the style the lines were loaded with (the loaded `Diff.marks`), never by the current setting. `Words`: a mark is drawn exactly where a segment is non-`Equal` (10.32's fill-only rule does not apply). `Jj`: unchanged.
- Look: today's tokens (10.32, 10.34); no underline, no strikethrough.
- Tests embed fixture text; never read `spikes/`, the scratchpad or `../similar`.

**Never:**
- No change to the jj style's output (Story 5.10's tests and the parity oracle stay untouched and green); no `similar` line diff, fork, path dependency, `inline` / `unicode` features; no per-file/hunk switch; no syntax colours; no settings UI for `diff.color-words.*`.
- No full gate (`cargo make test` / `test-full` / `coverage`) — targeted checks only (story-loop gate rule).
- No `jj` outside temp dirs this run created (with `JJ_CONFIG` = empty file); never a bare `cd`; never touch `~/development/projects/Kunden/`; never open `../similar/examples/diffs/`; no `git checkout --` / `git stash` on dirty files; no app start (the console session does the Marionette check).
- No edit of epics.md or existing deferred-work.md bullets.

## I/O & Edge-Case Matrix

`Words` style unless noted. ⟦…⟧ = a non-`Equal` segment.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| jj example | `671e4eaca` `write_locked_index` block (5.10's fixture) | removed 2454 `        .map_err(\|err\| ⟦GitResetHeadError::from_git(err.into_error()))?;⟧`; added 2454 `.map_err(\|err\| ⟦{⟧`; added 2455–2458 marked from first to last visible char, indentation not; added 2459 `⟦.map_err(GitResetHeadError::from_git)?;⟧`; removed 2456 `⟦GitResetHeadError::from_git(err.error))?;⟧` marked; added 2461 `⟦err.error)⟧` marked; 2462, 2463 marked whole (visible part) | — |
| jj example, pure insert hunk | the hunk that only adds `impl GitFetchError` | Added lines, all segments `Equal` | — |
| Widget test | `widget-test-rename` lines 8–23 (3 removed, 16 added) | removed 10: only `step',` marked; added 23: only `step on a tablet',` marked as ONE segment; added 10–21 marked whole, blank lines unmarked; comment lines and added 9 pinned from the real output | — |
| Stepper | `stepper/{before,after}.dart` | line 12: only `s.functionWizard_save` / `saveLabel`; split call: old `⟦Expanded(child:⟧` + `⟦lineColor)),⟧`, new `⟦Expanded(⟧`, `⟦child:⟧`, `⟦lineColor),⟧`, `⟦),⟧`, `_Line(color: isFirst ? null :` kept; `Spacing.spacing8,` / `Spacing.spacing2,` whole; inserted comment line marked whole (blanks between its words marked) | — |
| Over the limit | block above the size limit | lines as rule 3, every segment `Equal` | — |
| Both styles | any witness | equal fingerprint, sections, ranges, symbols, counts, numbered line texts | — |
| `pair` conflict | a side with a file conflict, `diff.color-words.conflict = "pair"` | header lines as in `Jj`; under `-------` the line and segment roles swap | — |
| Wire | `DiffRequest.marks` absent | `Jj` | — |
| Wire | `DiffRequest.marks` unknown value | refused | `ffi.invalid_argument`, like `DiffWhitespace` |
| Settings | stored `diffMarks` unknown / absent | `words` | fallback, no error |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/hunks.rs` -- `HunksOptions` :79-91 and `DiffOptions` :146-160 gain `marks: DiffMarks`; `Whitespace` :94-103 is the derive template for `pub enum DiffMarks { #[default] Jj, Words }`; `RevisionDiff` :205-226 gains `marks`; built at :459. `DiffReader::new` :566-589 → `WalkOptions` :557-560 gains `marks`; called from `compute_hunks` :336 and `diff` :360. `Walk::diff_lines` :1113-1185 is the one place to branch: `context == false && marks == Words` → the new function; `context == true` keeps the jj code. `roles` (:855, `ROLES.invert()` under `-------`) must drive kinds and segment kinds in the new path too. `segments()` :1337 joins runs; `Walk::push` :880. Module doc :1-36 names the second style. Inline tests :1372-2014: `jj_example()` :1703, `widget_test()` :1825, stepper test :1973, `pair_diff` :1884, `options()` :1462 (add a marks parameter or a second builder), `render()` :1530 for readable expectations.
- `crates/zanshin-jj/src/lib.rs:120` -- re-export `DiffMarks`.
- `crates/zanshin-jj/src/repo.rs:4434,4489` -- `compute_hunks` / `diff` docs mention the style.
- `crates/zanshin-jj/tests/it/{api_stability.rs:1821-1874, hunks.rs (156,254,415,515,636,659,686,737), diff.rs:153}` -- struct literals gain `marks` (or `..Default::default()`); `api_stability` lists the new public surface.
- `Cargo.toml` `[workspace.dependencies]` :26-; `crates/zanshin-jj/Cargo.toml:25-26`; `deny.toml` licence allow-list.
- `schemas/envelope.fbs` -- `DiffWhitespace` :354-357 (template, "APPEND only; unknown = invalid_argument"); `DiffRequest` doc :365-387, table :388-398 (append `marks: DiffMarks;` after `interdiff`; default 0 = `Jj`); `Diff` doc :3266-3273, table :3274-3280 (append `marks`). Then `cargo make codegen` (Makefile.toml:539-566).
- `crates/zanshin-ffi/src/diff.rs` -- `read_diff_request` :44-70 (doc :28-43), `diff_whitespace` :72-82 (template for `diff_marks`), `zanshin_diff` doc :96-140, `diff_to_envelope` :157-177 (`DiffArgs` :167-174). Inline tests: `diff_from_wire` :376, `pinned()` :423, `sample()` :447, `Request` :717-745, `read()` :747-774, `the_reader_reads_every_field` :782-817, unknown-whitespace refusal :891-916.
- `crates/zanshin-ffi/tests/it/diff_ffi.rs` -- `computed()` :36-78 (literals), `assert_wire_is` :167-172, `Req` :313-341, `request()` :343-367, `paths_context_whitespace_and_summary_reach_the_diff` :510-570 (add a marks test).
- `docs/ffi-abi.md` -- :671 verb row, `## Diff payload` :2464-2550 (result `marks`), :2547-2548 exports, `### zanshin_diff` :2550-2592 (request IDL :2556-2560, semantics :2570-2575, Dart threading :2591-2592).
- `packages/zanshin_core` -- `lib/src/ffi/diff.dart`: `DiffWhitespace` :25-44 (template), `Diff` :228-262 (add `marks`), `zanshinDiff` :264-317 (param + request :305-315), decoder :327-350. `lib/src/worker/commands.dart:2320-2360` `DiffCommand`; `lib/src/worker/isolate.dart:1795-1844` `ZanshinWorker.diff` and dispatch :4668-4697; `lib/src/worker/handle.dart:1642-1686` `RepoHandle.diff`; `lib/zanshin_core.dart:34` export. Tests `test/ffi/diff_test.dart:283-291` (wire values), synthetic envelopes :30, :138, :185; `test/worker/diff_test.dart:151-165`.
- `packages/zanshin_settings` -- `lib/src/model/general_settings.dart:9-34` (`DiffLayoutSetting` + `diffLayout` with `@JsonKey(unknownEnumValue:)` `@Default` — the pattern); regenerate `.g.dart` / `.freezed.dart` with build_runner; tests `test/model/app_settings_test.dart:23,66,105,110-114` and `test/settings_store_test.dart:19` (exact key maps).
- App: `app/lib/src/features/graph/graph_ports.dart:1007-1042` (`GraphDetails.diff` + `RepoGraphDetails.diff` → `handle.diff`); `graph_inspector.dart` ctor :55-65, `_settingsChanged` :228-245 (today re-renders only — a marks change must re-run `_summaryRead` :279-286 and `_loadFocus` :247-276), pass the loaded `Diff.marks` to the view; `undo_timeline/operation_changes.dart` `OperationChangesSource.diff` :31-48, `RepoOperationChangesSource.diff` :51-79, model ctor :83-99, `_settingsChanged` :162-168, `_diffOf` :265-276; `settings/general_tab.dart:162-181` (Diffs group, `ZsSegmented<DiffLayoutSetting>` row — add "Changed words" row below); strings `app/lib/l10n/app_en.arb:1461-1470` (+ gen-l10n output `app_localizations*.dart`); `graph/inspector_diff.dart` `diffWordMarks` :117-139, `_lineText` :221-260 (callers :777, :835), `InspectorDiffView` (add a `marks` field).
- App fakes/tests: `test/features/graph/graph_inspector_test.dart` `_Details` :73/:219-231, layout tests :1362-1374, :2403-2413; `graph_card_menu_test.dart:192,200`; `integration_test/glass_profile.dart:242,290`; `test/helpers/fake_undo_timeline.dart:100-175`; `test/features/graph/inspector_diff_test.dart:168-210`; `graph_ports_test.dart:157-175`; `undo_timeline/operation_changes_test.dart:443-451`; `settings/settings_window_test.dart:55-68`; `graph_real_repo_test.dart:203`.
- `app/widgetbook/folders/graph.dart` -- 'Inspector diff' component :274-279, `_colorWords` :926-960, `_DemoDetails` :963 (diff :1045), `_hunk` :1073-1098, `_diffOf` :1100-1160, `_HunkSelection` :1660-1720; `app/widgetbook/folders/undo_timeline.dart:148,211` `_DemoChanges.diff`.
- Design system `_bmad-output/implementation-artifacts/design_system/` -- `components/content/DiffHunk.{d.ts,jsx,prompt.md}`, `DiffView.{d.ts,jsx,prompt.md}` (prompt rule :13 "exactly jj's color-words output"), `content.card.html:44-68`, `readme.md` sync log :46-49, hand-kept `_ds_bundle.js` blocks; publish per `.claude/skills/design-artifacts/SKILL.md`.
- `_bmad-output/project-context.md:863-872` -- the diff rule ("No word-mark rule of Zanshin's own … Don't add a second word tokenizer") must name the second style as the one sanctioned exception.
- Fixtures: `git -C ../jj show 671e4eaca^:lib/src/git.rs` / `671e4eaca:lib/src/git.rs` (already in `jj_example()`); `spikes/structural-diff-probe/inputs/witness/{widget-test-rename,stepper}/{before,after}.dart` (copy text).

## Tasks & Acceptance

**Execution:**
- `Cargo.toml`, `crates/zanshin-jj/Cargo.toml` (`deny.toml` if needed) -- add `similar` 3.2.1 exact, `text` only. -- dependency.
- `crates/zanshin-jj/src/hunks.rs` -- `DiffMarks`; `marks` on `HunksOptions`, `DiffOptions`, `RevisionDiff`, `WalkOptions`; the `Words` block function (rules 1–6) called from `Walk::diff_lines` when not `context`; size-limit constant with its measurement in its doc; module and type docs; inline tests for every matrix row that needs no repo (jj example incl. the pure-insert hunk, widget test, stepper, over-limit, `pair` swap, blank rule, both-styles equality on all three witnesses), with jj-style tests untouched. -- the second style.
- `crates/zanshin-jj/src/{lib.rs,repo.rs}`, `tests/it/{api_stability,hunks,diff}.rs` -- export, docs, literals; one integration test that `Repo::diff` with `marks: Words` reports `Words` and equal fingerprints/sections/counts to `Jj`. -- surface.
- `schemas/envelope.fbs`, `cargo make codegen`, `crates/zanshin-ffi/src/diff.rs` (+ inline tests: read marks, refuse unknown, write marks), `crates/zanshin-ffi/tests/it/diff_ffi.rs` (marks reach the diff and come back), `docs/ffi-abi.md` -- wire. -- FFI.
- `packages/zanshin_core` (`ffi/diff.dart` `DiffMarks` + `Diff.marks` + `zanshinDiff(marks:)`, `commands.dart`, `isolate.dart`, `handle.dart`, `zanshin_core.dart` export, tests) -- bridge.
- `packages/zanshin_settings` (`DiffMarksSetting { words, jj }`, `GeneralSettings.diffMarks` default `words`, unknown → `words`, regenerated code, tests) -- setting.
- App (`graph_ports.dart`, `graph_inspector.dart`, `operation_changes.dart`, `general_tab.dart`, `app_en.arb` + generated l10n, `inspector_diff.dart`, every fake listed) -- pass the setting on every load; a setting change reloads the open diff; the "Changed words" row with segments "Zanshin" / "jj" and the explaining line per choice ("Whole words: the longest common run per changed block, removed lines first." / "As `jj diff` prints them, following your jj config."); draw by the loaded `Diff.marks`. Tests: settings row writes `diffMarks`; inspector and operation view pass it and reload on change; `diffWordMarks` in `Words` marks exactly the non-`Equal` segments (incl. a blank-only-unchanged line). -- UI.
- `app/widgetbook/folders/graph.dart` -- use case "Word marks" under 'Inspector diff': the jj example block and the widget-test block, each in both styles, from the lines the Rust tests pin. -- catalogue.
- Design system (DiffHunk / DiffView prompt.md, d.ts, jsx, `_ds_bundle.js`, `content.card.html` one hunk in the second style, readme sync line) and republish via `design-artifacts`. -- DS.
- `_bmad-output/project-context.md`, `hunks.rs` docs -- two styles; jj parity holds for the `Jj` style and for the lines of both. -- canonical rules.

**Acceptance Criteria:**
- Given a diff loaded with `Words`, when it crosses the FFI and `zanshin_core`, then `Diff.marks` is `words` and every line keeps kind, numbers and segments; an absent request field gives `Jj`.
- Given the app's Settings › General, when "Changed words" switches between Zanshin and jj, then the setting persists, the open inspector diff and the open operation view reload in the new style.
- Given the inspector showing the widget-test block in `Words`, when drawn, then the old `testWidgets(` line and new line 23 each show one mark and lines 10–21 are marked whole, in today's colours with no underline.
- Given the parity oracle and Story 5.10's tests, when run, then they pass with unchanged expectations.

## Spec Change Log

## Review Triage Log

### 2026-11-13 — Review pass
- verdicts: 23 findings — high 0, medium 2, low 15, false 6, maybe-false 0
- findings:
  - `[medium]` `[patch]` (verification-gap) No test runs `Words` under `-w` / `-b`, so the `!context` guard in `Walk::diff_lines` is unprotected — patched: `words_keep_a_whitespace_context_line_on_the_jj_path` loops both modes and asserts one Context line equal to the Jj output.
  - `[low]` `[patch]` (verification-gap) Side-by-side drawing in `Words` is untested — patched: the Words widget test pumps side by side too and asserts the same painted marks.
  - `[low]` `[patch]` (verification-gap) No test reads `InspectorDiffView.marks` in the operation view — patched: the focused-file and description views assert `DiffMarks.words`.
  - `[false]` `[reject]` (blind) Non-UTF-8 text differs between styles — both decode lossily and a run never splits a UTF-8 sequence (jj-lib keeps non-ASCII bytes together; `\n` is ASCII), so each invalid byte becomes the same U+FFFD in both.
  - `[low]` `[reject]` (blind) A whitespace-only edit gets no mark in `Words` — real, but it is the intent's rule 5 (indentation and trailing blanks are never marked); the line fills still show the change.
  - `[low]` `[reject]` (blind) The size limit is per block, not per file — the intent fixes a per-block limit; a file of many 100k-token blocks is unlikely and a per-file budget adds state.
  - `[low]` `[reject]` (blind) Token counting builds a Vec before the limit check — negligible next to the diff itself; not worth a counting tokenizer.
  - `[medium]` `[patch]` (blind) `-w` / `-b` claim untested — same root as the first verification-gap row, patched there; the "materialize untested in Words" part is false (materialize is the default path every Words test takes).
  - `[low]` `[patch]` (blind) `both_styles_keep_the_lines` discards `render(...)`, segment invariants unasserted — patched: explicit invariant checks on every Words line. Its fingerprint part is false: `fingerprint()` takes only the texts and the compare mode, never the style.
  - `[low]` `[patch]` (blind) The over-limit test's "just under the limit" comment is wrong — patched: "A small block of the same shape is marked."
  - `[false]` `[reject]` (blind) project-context.md "no own rules inside either" contradicts the blank rule — the blank rule is the story's own rule 5, part of the sanctioned style, not a Zanshin addition.
  - `[low]` `[reject]` (blind) Spec Change Log empty despite the rule-5 reading — fix would edit this build's spec; the reading is recorded in Design Notes.
  - `[low]` `[reject]` (blind) `line_kind`'s `Equal` arm hides an impossible case — cosmetic.
  - `[low]` `[reject]` (blind) The operation view blanks its file list while a style switch reloads — real flicker, only on a Settings toggle; keeping the old list needs extra state.
  - `[low]` `[reject]` (blind) Catalogue and DS card copy the pinned lines by hand; the DS card hunk is shortened — the DS card is a design demo; the catalogue strings match the Rust pins today; a generated link adds tooling.
  - `[low]` `[patch]` (blind) Settings copy shows literal backticks — patched: "As jj diff prints them, following your jj config.", l10n regenerated. The jargon / duplicate-key / `.first` finder parts are rejected: the copy is the story's, the key pair mirrors `settingsDiffLayout` / `Label`.
  - `[false]` `[reject]` (blind) `epic-5-context.md` trimmed beyond scope — it is regenerated by the workflow's compile step under its own "scope aggressively" rules; the dropped detail lives in the specs.
  - `[low]` `[reject]` (edge-case) No per-file token budget — same as the blind per-block row.
  - `[low]` `[reject]` (edge-case) Myers is not a strict longest common run — the story's own name for `similar`'s default; the doc says Myers.
  - `[false]` `[reject]` (intent) Rule 5 read as gap-filling (B2) rather than restrictive — rule 5's stated purpose is that fills must not cut a new line into chips, and the matrix witnesses ("marked whole") need it.
  - `[false]` `[reject]` (intent) Fingerprint equality asserted only on a trivial fixture — the fingerprint is computed outside the walk from texts and mode only, so it cannot depend on the style.
  - `[low]` `[reject]` (intent) `_DemoDetails` answers jj lines whatever is asked, catalogue strings hand-copied — only the new use case shows the second style, as the story asks.
  - `[false]` `[reject]` (intent) The inspector's summary read passes no marks — a summary read has no lines; documented in Design Notes.

## Design Notes

- **Why not `Changed` lines:** Ralph's example prints old lines then new lines; `similar`'s token stream is not aligned per line, so no line holds both sides. Side by side then pairs rows by number as for any Removed/Added run.
- **Why context lines keep the jj path:** at `-w` / `-b` the context call diffs two whitespace-variant copies of matching lines; it is not a changed block of the line diff, and the rule's lines would duplicate them.
- **Size limit:** `WORD_MARKS_LIMIT = 100_000` tokens (both sides together, counted with `similar`'s own `tokenize_words`). Measured 2026-11-12 on an Apple M4 Pro, release build, `similar` 3.2.1 with `default-features = false, features = ["text"]`, the same calls as `word_runs` (count tokens, `TextDiff::from_words`, walk `iter_all_changes`): two sides with no common word (`a0 a1 …` against `b0\nb1\n…`, not even the blanks match) take 11 ms at 100k tokens and 47 ms at 400k — `similar`'s Myers short-cuts a disjoint pair, so "no common word" is not its worst case. The slowest shape found is both sides drawn from a two-word vocabulary in different pseudo-random orders (many matches, an edit distance near half the tokens): 39 ms at 100k tokens (60 ms at 150k, 82 ms at 200k). 100k keeps every shape measured under the ~50 ms budget. Scratch benchmark only, not committed.
- **Blank runs between marked words (a reading of rule 5 the matrix needs):** `similar` matches the single spaces between two inserted words as unchanged tokens, so rule 4 alone leaves the widget test's new lines 13 and 15–20 cut into separate marks (`{+for (var+} {+i+} …`), which contradicts the matrix ("added 10–21 marked whole") and AC 3. Implemented: a blank run holding no line break is marked exactly when both its neighbours on the line are marked non-blank tokens — whether `similar` called it changed or not; a non-blank token is marked exactly when it changed. Indentation, trailing blanks and line breaks are still never marked, and every matrix row holds (pinned in `hunks.rs`' `words_*` tests).
- **The inspector's summary is not re-read on a style change:** it is a `summary` read (no hunks, so no lines), and fingerprints, sections and counts are equal in both styles; only the focused diff reloads. The operation view re-reads both, because its summary read keeps the inter-diff description block's hunks.
- **Draw style travels with the data:** `InspectorViewModel.diffMarks` / `OperationChangesModel.focusedMarks` hold the loaded `Diff.marks`; `InspectorDiffView` / `InspectorDiffHunk` take a `marks` field (default `jj`, so every existing caller draws as before). The catalogue's `_DemoDetails` keeps answering jj color-words lines with `Diff.marks = jj` whatever it is asked for; the new "Inspector diff / Word marks" use case shows both styles side by side.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib -- hunks::` -- expected: pass.
- `cargo test -p zanshin-jj --test it -- hunks:: diff:: api_stability::` -- expected: pass.
- `cargo test -p zanshin-ffi --lib diff::`; `cargo test -p zanshin-ffi --test it -- diff_ffi:: ffi_abi_doc_sync::` -- expected: pass.
- `cargo test -p zanshin-parity --test oracle -- diff_color_words:: diff_revisions::` -- expected: pass, unchanged.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`; `cargo fmt --all --check`; `cargo deny check licenses` -- expected: clean.
- `cargo make codegen` -- expected: generated files committed, a rerun leaves no diff.
- `packages/zanshin_core`, `packages/zanshin_settings`, `app`: `dart analyze`, `dart format --set-exit-if-changed`, targeted `flutter test` -- expected: pass.

**Verification notes** (2026-11-12, story run):
- `cargo test -p zanshin-jj --lib -- hunks::` — pass (25).
- `cargo test -p zanshin-jj --test it -- hunks:: diff:: api_stability::` — pass (103).
- `cargo test -p zanshin-ffi --lib diff::` — pass (8); `cargo test -p zanshin-ffi --test it -- diff_ffi:: ffi_abi_doc_sync::` — pass (25).
- `cargo test -p zanshin-parity --test oracle -- diff_color_words:: diff_revisions::` — pass (15), expectations untouched.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean.
- `cargo deny check licenses` — NOT run: `deny.toml` has no `[licenses]` table yet and its header forbids that check until the release phase (it rejects every licence, MIT included). Ran the gate's form `cargo deny check advisories bans` — ok. `similar` is Apache-2.0, inside the project's permissive posture.
- `cargo make codegen` — regenerated `envelope_generated.rs`, `envelope_zanshin.ffi_generated.dart`, `zanshin_ffi.h`, `bindings.dart`; a second run left no diff.
- `packages/zanshin_core`: `dart analyze` no issues, `dart format --set-exit-if-changed` clean, `dart test test/ffi/diff_test.dart test/worker/diff_test.dart` — pass (23).
- `packages/zanshin_settings`: build_runner regenerated `general_settings.{freezed,g}.dart`; `dart analyze`, `dart format` clean; `flutter test` — pass (46).
- `app`: `flutter gen-l10n`; `dart analyze` no issues; `dart format` clean; `flutter test` on `inspector_diff_test`, `graph_inspector_test`, `undo_timeline/`, `settings/`, `graph_card_menu_test`, `graph_ports_test` — pass (315). A full `flutter test` from `app/` passed all but 6 tests (`worker_project_repos_test` ×5, `remote_sync_test` ×1) that stop on "XDG_CONFIG_HOME is not pinned … run via `cargo make test-app`" — environment-only, unrelated to this story; the loop's final gate runs them properly.
- Design system: the Content card rendered through the `design-system-preview` server (both styles, no console errors); published to the DS artifact (version 1794526072-72f6) and synced to the canvas `6sAzL5mDcVpWXevbTcempu` (version 1794526147-6a91).
- Not run here: the full gate (story-loop rule) and the Marionette check of the catalogue use case (console session).

**Verification notes** (2026-11-13, after the review patches):
- `cargo test -p zanshin-jj --lib -- hunks::` — pass (26).
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean.
- App (implementation run): `dart analyze` clean, `dart format` clean, `flutter test` on `inspector_diff_test`, `operation_changes_test`, `settings_window_test` — pass (73).

**Manual checks (if no CLI):**
- Catalogue use case "Inspector diff / Word marks" in Marionette, night and paper, against the DS card — by the console session (this run cannot hold a running app).

## Auto Run Result

Status: done

**Summary.** A second word-mark style, `DiffMarks::Words`, sits beside jj's color-words marks. Lines, hunks, numbers, context, sections, conflicts and fingerprints stay jj's; only a changed block's lines and segments differ: its left lines, then its right lines, marked by `similar`'s `TextDiff::from_words`. The style travels over the FlatBuffers wire (`DiffRequest.marks`, absent = Jj; `Diff.marks`), through `zanshin_core`, into a new setting `GeneralSettings.diffMarks` (app default `words`), a "Changed words" row in Settings › General, every app diff load (a change reloads the open diff), and the drawing (by the loaded style). The catalogue use case **"Inspector diff / Word marks"** shows the jj example and the widget-test block in both styles.

**Files changed** (main ones):
- `crates/zanshin-jj/src/hunks.rs` — `DiffMarks`, `word_lines` / `word_runs` / `side_runs` / `run_lines`, `WORD_MARKS_LIMIT`, `words_*` tests; `Cargo.toml` / `crates/zanshin-jj/Cargo.toml` — `similar =3.2.1` (text only).
- `schemas/envelope.fbs` + generated code, `crates/zanshin-ffi/src/diff.rs`, `crates/zanshin-ffi/tests/it/diff_ffi.rs`, `docs/ffi-abi.md` — the wire.
- `packages/zanshin_core` (`ffi/diff.dart`, worker command / isolate / handle, export) — the bridge.
- `packages/zanshin_settings` (`general_settings.dart` + generated) — the setting.
- `app/lib/src/features/graph/{graph_ports,graph_inspector,inspector_diff}.dart`, `undo_timeline/operation_changes.dart`, `settings/general_tab.dart`, `l10n` — loads, reload, drawing, Settings row; fakes and tests.
- `app/widgetbook/folders/graph.dart` — use case "Word marks".
- `design_system/components/content/*`, `_ds_bundle.js`, `readme.md` — `marks` prop, one hunk in the second style; republished (DS artifact 1794526072-72f6, canvas 1794526147-6a91).
- `_bmad-output/project-context.md` — the second style as the one sanctioned exception.

**Review.** One pass, 23 findings (medium 2, low 15, false 6). Patched: `-w` / `-b` Words test (medium, two rows), side-by-side Words drawing test, operation-view `marks` assertions, segment invariants in `both_styles_keep_the_lines`, a wrong test comment, literal backticks in the jj hint (all low). Deferred: none. Rejected: whitespace-only edits unmarked (intent rule 5), per-block not per-file limit, double tokenizing, `line_kind` arm, operation-view flicker on a style switch, hand-copied catalogue/DS lines, spec change-log row (spec edit), Myers wording, `_DemoDetails` jj-only, settings copy wording; false: non-UTF-8 drift, project-context contradiction, epic-context trim, rule-5 reading, fingerprint scope, summary read without marks — reasons in the triage log.

**Follow-up review:** not recommended (`false`): 1 medium and 5 low entries patched, no high.

**Residual risks.**
- Rule 5 is read as "a blank run between two marked words is marked even when `similar` kept it" (Design Notes); Ralph's raw example prints the inserted comment as four marks, Zanshin as one.
- Coverage and the full gate were not run (story-loop rule); the Marionette check of the catalogue and the real app is left to the console session.
- `cargo deny check licenses` cannot run until `deny.toml` gets a `[licenses]` table; `advisories bans` passed.
