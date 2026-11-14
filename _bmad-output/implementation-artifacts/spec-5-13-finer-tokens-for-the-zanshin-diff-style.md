---
title: 'Story 5.13 — The Zanshin style marks only the changed part of a line, and a one-line change is one line (finer tokens for similar)'
type: 'feature'
created: '2026-11-14'
status: 'done'
baseline_revision: 'ff7e2b55405dce301023084ce32e4d801fa77aac'
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

**Problem:** Zanshin's word-mark style (`DiffMarks::Words`, Story 5.11) splits text only at blanks, so a call chain is one word: when one call of a chain changes, the whole old chain shows as removed and the whole new chain as added (deferred-work I1). A change of one line by one line shows as an old and a new line, where the jj style shows one line (deferred-work I2).

**Approach:** In `crates/zanshin-jj/src/hunks.rs`, replace Story 5.11's tokens and blank rule with epics.md Story 5.13's rules 1–5 (finer tokens, `similar`'s Myers over token slices, shift right, gap marks) and add rule 6 (a block of one old and one new line becomes one `Changed` line under `diff.color-words.max-inline-alternation`). Reword every description of the style, show Settings' "Inline changes" row in both styles, and update the catalogue, the design system and the docs.

## Boundaries & Constraints

**Always:**
- The rule, per changed block of jj's line diff with lines on both sides (the non-`context` call of `Walk::diff_lines` in the `Words` style). Each side is its joined lines, decoded lossily as UTF-8 as today.
  1. **Tokens.** A run of blanks (`char::is_whitespace`, so a line break belongs to a blank run); a run of word characters (`char::is_alphanumeric` or `_`); any other character on its own.
  2. **Comparison.** `similar::capture_diff_slices(Algorithm::Myers, old, new)` over the two token lists; two tokens are equal when their text is equal. A token only one side has is *changed*. In a block of exactly one old and one new line each word token stands twice in both lists (rule 6); such a token is kept only when both its copies pair with the two copies of one token on the other side, otherwise it is changed on both sides. Kept tokens therefore pair one to one, in order.
  3. **Shift right.** On each side, a maximal run of changed tokens moves right while its first non-blank token equals the token right after the run: that first token becomes unchanged, the token after the run becomes changed (the run then also takes any changed tokens that now touch it). Blank tokens at the start of the run stay changed.
  4. **Marks** (lines that are not merged). A changed non-blank token is marked. A maximal run of blank tokens (changed or not) and unchanged tokens without a word character is marked exactly when it holds no line break and the tokens right before and right after it are both marked non-blank tokens. Nothing else is marked: indentation, trailing blanks and line breaks never are.
  5. **Size limit.** `WORD_MARKS_LIMIT` counts the entries handed to the comparison (both sides, doubled word tokens included). It is measured again with the product code in a release build on the M4 Pro: every shape tried (at least: two sides with no common token; two sides from a two-word vocabulary in different pseudo-random orders, also doubled; two sides from a four-character punctuation-and-word vocabulary without blanks) stays within about 50 ms. The constant's doc and Design Notes record the numbers. A block over the limit carries no marks and is never merged. No time-based cut-off.
  6. **One line for one line.** A block whose left side is exactly one line and whose right side is exactly one line:
     - is **merged** when it is within the size limit, both lines have the same indentation (leading whitespace) and the same trailing whitespace (the line break included), and its count fits `max_inline_alternation` exactly as the jj path reads it (`None` always, `Some(0)` never, else `count <= max`);
     - the **count** walks the merged line's parts in order and adds 1 each time a changed part's side differs from the previous changed part's side (jj's `count_diff_alternation` rule): one removed part is 1, removed then added is 2, removed, kept, removed is 1;
     - the **merged line** has kind `HunkLineKind::Changed`, both numbers, and its segments in line order: each kept token once as `Equal`; between two kept tokens the left side's changed tokens as one `roles.before` part, then the right side's as one `roles.after` part. Every token of each side appears, blanks included, so each side's text rebuilds from the line; rule 4 does not apply in it. Under `pair` the roles swap under a `-------` term as in the jj style;
     - **not merged:** the old line, then the new line, marked by rules 3 and 4 from the same (doubled) comparison.
- Unchanged from Story 5.11: a block with lines on one side only carries no marks; context lines at `-w` / `-b` keep the jj path; the `DiffMarks` names and wire; the jj style's output. For one file both styles give equal fingerprints, sections, hunk ranges, symbols, counts and each side's numbered line texts (merged lines included); segments are never empty, adjacent segments differ in kind, and a line's segments join to its text.
- `similar` in the root `Cargo.toml` becomes `default-features = false` with no features (the code uses only `capture_diff_slices`, `Algorithm`, `DiffOp`); its WHY comments and `crates/zanshin-jj/Cargo.toml`'s follow.
- Wording: no description of the Zanshin style says "whole word(s)" or "longest common run" (code docs, schema, FFI docs, `zanshin_core`, `GeneralSettings`, `docs/ffi-abi.md`, `project-context.md`, l10n, catalogue, design system). The hint `settingsDiffMarksZanshinHint` reads exactly "Marks the changed part of each line, using the similar library. Removed lines come first."
- Settings › General: the "Inline changes" row shows in both styles, right below "Changed words". While "jj" is chosen its hint stays. While "Zanshin" is chosen it reads exactly "How often a line may switch between removed and added parts before it shows as an old and a new line. Applies where one line replaces one line. Experimental in jj."
- The app draws a `Changed` line of the `Words` style by its kind with its marks, in the unified and the side-by-side layout.
- Tests embed fixture text: never read `spikes/`, `../jj` or the scratchpad. Story 5.10's tests and the parity oracle stay untouched and green.

**Never:**
- tree-sitter or any parser; language-aware tokens; a port of IntelliJ's algorithm; a third style or a token-fineness setting; a limit of Zanshin's own for rule 6; merging a block with several lines on a side; `similar`'s `TextDiff` / line diff / a fork; any change to the jj style, to lines, hunks, numbers or colours.
- The full gate (`cargo make test`, `test-full`, `coverage`): targeted checks only (story-loop gate rule).
- `jj` outside temp dirs this run created (with `JJ_CONFIG` = an empty file); a bare `cd`; `git checkout --` / `git stash` on dirty files; starting the app or Marionette (the loop's main session does the UI check).
- Edits to epics.md or to existing deferred-work.md bullets; git commits (the orchestrating run commits).

## I/O & Edge-Case Matrix

`Words` style, context 3, `max-inline-alternation` 3 unless noted. `~` a `Changed` line (both numbers), `-` removed, `+` added; `[-…-]` a `Removed` segment, `{+…+}` an `Added` one, as `hunks.rs`' test `render()` writes them (numbers left out here).

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Single lines (9346978d) | `    let actual = git_repo.references().map_err(GitImportError::from_git)?;` → `…references()?;`; same for `actual.local_branches()`, `remote_branches()`, `tags()` (`…?,`) | each one `~` line: `    let actual = git_repo.references()[-.map_err(GitImportError::from_git)-]?;` (count 1) | — |
| Same, limit 0 | `max-inline-alternation = 0` | `-    let actual = git_repo.references()[-.map_err(GitImportError::from_git)-]?;` then `+    let actual = git_repo.references()?;` (no mark) | — |
| Prefix added | `    gix::lock::File::acquire_to_update_resource(` → `    let lock = gix::…(` | `~    {+let lock = +}gix::lock::File::acquire_to_update_resource(` | — |
| Chain to one line | `let git_repo = git_backend` / `.open_git_repo_at_workdir(workspace_root)` / `.map_err(GitImportError::from_git)?;` → one line | only `[-.map_err(GitImportError::from_git)-]` on the third old line; the other old lines and the new line unmarked | — |
| Shift with leading blank | `let file_blob = git_repo` / `.write_blob(` / string / `)` / `.map_err(GitResetHeadError::from_git)?;` → 3 lines | only `[-.map_err(GitResetHeadError::from_git)-]` on old line 5; new lines unmarked | — |
| Removed around a kept word | `        _ => Err(GitResetHeadError::from_git(err)),` → `        _ => Err(err),` | `~        _ => Err([-GitResetHeadError::from_git(-]err)[-)-],` (count 1) | — |
| Words count twice | `        Err(err) => Err(GitResetHeadError::from_git(err)),` → `…Err(err.into()),` | `~        Err(err) => Err([-GitResetHeadError::from_git(-]err{+.into(+})),` (count 2) | — |
| Count over the limit | `    Git(Box<dyn std::error::Error + Send + Sync>),` → `    Git(#[from] gix::Error),` (a 1:1 block) | count 5: `-    Git([-Box<dyn std::error-]::Error [-+ Send + Sync>-]),` / `+    Git({+#[from] gix+}::Error),`; at `-1` one `~` line (pinned from the real output) | — |
| Closing brackets | `    )` / `    .map_err(GitResetHeadError::from_git)` → `    )?;` / `    Ok(lock)` | `-    )`, `-    [-.map_err(GitResetHeadError::from_git-])`, `+    ){+?;+}`, `+    {+Ok(lock+})` | — |
| 671e4eaca (5.11's `jj_example`) | the `write_locked_index` block | `-2454 …map_err(\|err\| [-GitResetHeadError::from_git-](err.[-into_error-]()))?;`; `+2454 …map_err(\|err\| {+{+}`; `+2455            {+let (source, out) =+} err.{+into_parts();+}`; `+2456`–`2458` marked first to last visible character; `+2459        {+.map_err(GitResetHeadError::from_git+})?;`; `-2456 …map_err(\|err\| [-GitResetHeadError::from_git(-]err.error))?;`; `+2461` no mark; `+2462        {+.context(index.path())+}`; `+2463        {+.map_err(GitResetHeadError::from_git+})?;` | — |
| Widget test | `widget_witness()` | old 10 (`testWidgets(…last step'…`) no mark; new 23 `…the last step {+on a tablet+}', (tester) async {` (one mark); new 11–21 marked first to last visible character, blank lines unmarked; new 10 `    {+await openWizard(tester, size:+} phone{+);+}`; comment lines and new 9 pinned from the real output | — |
| Stepper | `stepper_witness()` | `~    child: Text(isLastStep ? [-s.functionWizard_save-]{+saveLabel+} : s.functionWizard_next),`; split call: old line no mark, new `      child: _Line(color: isFirst ? null : lineColor){+,+}`, `    Expanded(` and `    ),` unmarked; `-  padding: Spacing.[-spacing8-],`, `+  {+// Small side padding.+}`, `+  padding: Spacing.{+spacing2+},` | — |
| Reformat | `compute(first_argument, second_argument, third_argument);` → split over five lines | only `third_argument{+,+}` | — |
| Nesting | two statements wrapped in `if event.is_relevant() {` | old lines no mark; new `    {+if event.is_relevant() {+}`, `    {+}+}`, `    log({+redact(+}state.summary()){+)+};`, the moved statements unmarked | — |
| Reorder | `f(a, b)` → `f(b, a)` (Rust and Dart lines) | `~    let total = f({+b, +}a[-, b-]);` / `~  final total = f({+b, +}a[-, b-]);` | — |
| Indentation changes | `    let a = old;` → `        let a = new;` | two lines: `-    let a = [-old-];`, `+        let a = {+new+};` | — |
| Line-break state differs | a last line `old` without `\n` → `new\n` | two lines | — |
| One-sided / over the limit | a pure insertion; a block over `WORD_MARKS_LIMIT` (also 1:1) | lines unmarked; a 1:1 block over the limit stays two lines | — |
| `pair` base term | conflict `x / b / y` against `z` | under `-------`: `~{+b+}[-z-]`; the `+++++++` terms `~[-x-]{+z+}`, `~[-y-]{+z+}` | — |
| Both styles | every witness above, merged lines included | equal fingerprints, sections, ranges, symbols, counts, numbered side texts; segment invariants hold | — |
| Settings | Changed words = Zanshin, then jj | the Inline changes row shows under both, below Changed words, with its hint per style; a choice writes `diff.color-words.max-inline-alternation` at user scope | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/hunks.rs`
  - Module doc :1-42 (the style bullet :21-26) and `DiffMarks::Words` doc :110-116 — describe the new rule; drop "never a Changed line" and "`max-inline-alternation` has no effect".
  - `Walk::diff_lines` :1149-1224 — the `Words` branch :1156; the jj path's limit match :1160-1170 is the model for rule 6's fit check; `side_kind` :1171-1176; how an inline line is pushed :1177-1199 (`self.push(at, kind, numbers, segments)`, then both counters move).
  - `Walk::word_lines` :1228-1251 — rule 6 goes here: a 1:1 block that fits pushes one `Changed` line with `Diff::new(Some(left), Some(right))` and advances both counters; otherwise as today via `run_lines`.
  - `WORD_MARKS_LIMIT` :1254-1259, `word_runs` :1261-1298 (uses `similar::DiffableStr::tokenize_words` and `TextDiff::from_words`, both `text`-feature APIs that go away), `side_runs` :1300-1323 (5.11's blank rule, replaced by rule 4), `run_lines` :1325-1341 (keep: cuts runs at `\n`), `segments()` :1489-1507 (joins and drops empty runs), `ROLES` :891, `count_diff_alternation` :1453-1467 (the counting rule to mirror; it takes jj-lib `DiffHunk`s, so rule 6 counts its own parts).
  - Tests :1526-2586: `options()` :1617, `words()` :1630, `diff_with()` :1640, `line()`/`render()` :1656-1701 (`~` = Changed), `jj_example()` :1894, `widget_test()` :2016, `STEPPER` :2153, `widget_witness()`/`stepper_witness()` :2216-2238; 5.11's `words_*` tests :2240-2525 (follow the new rule, rename `words_mark_the_jj_example_by_whole_words`); `words_mark_blanks_only_between_marked_words` :2460 calls `word_runs` directly (its 1:1 inputs now merge or not by the count); `side_texts` :2529 and `both_styles_keep_the_lines` :2549 (add the new fixtures). Story 5.10's jj-style tests stay untouched.
- `Cargo.toml:54`, `crates/zanshin-jj/Cargo.toml:30` — `similar` entry and WHY comments.
- `crates/zanshin-jj/src/repo.rs:4420` — doc names the style.
- `crates/zanshin-jj/tests/it/diff.rs:198-239` `the_words_style_keeps_the_files_and_reports_itself` — its `b` → `B` block is 1:1 and now merges (`~[-b-]{+B+}`); counts, fingerprints, sections assertions stay.
- `crates/zanshin-ffi/tests/it/diff_ffi.rs:~590-625` — asserts no `Changed` line in `Words` for `f.txt`; follow rule 6. `crates/zanshin-ffi/src/diff.rs:134` doc (feeds `crates/zanshin-ffi/include/zanshin_ffi.h` and `packages/zanshin_core/lib/src/ffi/bindings.dart` via `cargo make codegen`).
- `schemas/envelope.fbs:360` — `DiffMarks` doc (feeds `envelope_generated.rs`, `envelope_zanshin.ffi_generated.dart`; `cargo make codegen`).
- `docs/ffi-abi.md:2510-2521` — the `Words` paragraph states the old rule; rewrite to rules 1–6.
- `packages/zanshin_core/lib/src/ffi/diff.dart:53` doc; `packages/zanshin_core/test/worker/diff_test.dart:175-189` asserts no `changed` line in `words` — follow rule 6.
- `packages/zanshin_settings/lib/src/model/general_settings.dart:19` — `DiffMarksSetting.words` doc (rerun build_runner only if generated files copy it).
- `_bmad-output/project-context.md:870-879` — the sanctioned-exception paragraph names `TextDiff::from_words` and "whole words"; rewrite to the new rule (rule 6 included; jj parity holds for the jj style and for both styles' numbered line texts).
- App:
  - `app/lib/src/features/settings/general_tab.dart:202-217` — drop the `if (… == DiffMarksSetting.jj)` guard; hint by style.
  - `app/lib/l10n/app_en.arb:1476,1479,1484-1486` — `@settingsDiffMarksZanshin` description, `settingsDiffMarksZanshinHint`, `@settingsDiffInline` description, a new `settingsDiffInlineZanshinHint`; then `flutter gen-l10n` (generated `app_localizations*.dart`).
  - `app/test/features/settings/settings_window_test.dart:72-89, 247-283` (Zanshin hint text, the Inline row absent under Zanshin, row order) and the other Inline tests that switch to jj first.
  - `app/lib/src/features/graph/inspector_diff.dart` — `diffWordMarks` :129-150 already marks every non-equal segment in `words`; `pairSideBySide` :39-113 splits a changed line into left and right cells; `HunkLineKind.changed` look :741. No change expected.
  - `app/test/features/graph/inspector_diff_test.dart:~300-360` — the `words` widget-test block pins 5.11's marks (`-step',`, `+step on a tablet',`); follow the new marks and add a merged `changed` line in both layouts.
  - `app/widgetbook/folders/graph.dart:1736-1876` `_WordMarks` — `_wordsExample` / `_wordsWidget` take the new pins; add Ralph's 9346978d lines (the four single lines as `~` lines and the three-line chain); doc comment :1736-1737. Notation as `_DemoDetails._hunk` parses it (`~` lines with both numbers).
- Design system `_bmad-output/implementation-artifacts/design_system/`: `components/content/DiffView.prompt.md:14`, `DiffHunk.prompt.md:11`, `DiffView.d.ts:16`, `DiffHunk.d.ts:16`, `DiffView.jsx:13` and its block in `_ds_bundle.js` (:1341), `content.card.html:68-77` (the Zanshin hunk: show the new rule, a merged `~` line included), `readme.md` sync log (a dated line after :50). Publish per `.claude/skills/design-artifacts/SKILL.md` A then B.
- Fixture sources (copy text into tests; never read at test time): `git -C ../jj show 9346978d^:lib/src/git.rs` and `9346978d:lib/src/git.rs`. jj 0.47's line diff cuts its blocks at old/new lines 962/960, 964/962, 971/969, 978/976 (single lines), 1249-1251/1243 (chain), 1318/1310 (`Git(Box…)`), 2210/2185, 2493/2456, 2375-2379/2348-2350 (`file_blob`), 2432/2401 (`let lock = `), 2437-2438/2406-2407 (closing brackets); take each with a few unchanged lines around it. `spikes/structural-diff-probe/inputs/witness/{reformat,nesting,reorder-rust,reorder-dart}/` hold the small inputs.

## Tasks & Acceptance

**Execution:**
- `Cargo.toml`, `crates/zanshin-jj/Cargo.toml` -- `similar` without features; WHY comments -- the code no longer uses `text`.
- `crates/zanshin-jj/src/hunks.rs` -- rules 1–6 replacing `word_runs` / `side_runs`' logic, rule 6 in `Walk::word_lines`, `WORD_MARKS_LIMIT` re-measured (doc records the numbers), module and `DiffMarks::Words` docs; tests: one per matrix row (new 9346978d fixture, reformat / nesting / reorder / indentation / line-break fixtures embedded), 5.11's `words_*` tests and `both_styles_keep_the_lines` following the new rule with the new fixtures added -- the style.
- `crates/zanshin-jj/src/repo.rs`, `crates/zanshin-jj/tests/it/diff.rs`, `crates/zanshin-ffi/tests/it/diff_ffi.rs`, `crates/zanshin-ffi/src/diff.rs`, `schemas/envelope.fbs` + `cargo make codegen`, `docs/ffi-abi.md` -- docs and tests that pinned "no Changed line" follow rule 6 -- surface.
- `packages/zanshin_core` (`ffi/diff.dart` doc, `test/worker/diff_test.dart`), `packages/zanshin_settings` (`general_settings.dart` doc) -- wording and the merged line -- bridge.
- `app/lib/l10n/app_en.arb` + gen-l10n, `general_tab.dart`, `settings_window_test.dart` -- hint, Inline row in both styles with its per-style hint -- Settings.
- `app/test/features/graph/inspector_diff_test.dart` (+ `inspector_diff.dart` only if a merged line draws wrong) -- new marks; a merged `changed` line in unified and side by side -- drawing.
- `app/widgetbook/folders/graph.dart` -- new pins and the 9346978d example -- catalogue.
- Design system files above, then publish (A, B) -- DS; if publishing fails, say so in the result.
- `_bmad-output/project-context.md` -- the rule -- canonical rules.

**Acceptance Criteria:**
- Given a diff loaded in the `Words` style, when it crosses the FFI and `zanshin_core`, then a merged line arrives as kind `changed` with both numbers and its exact segments, and `Diff.marks` is `words`.
- Given Settings › General with "Zanshin" chosen, when the user picks "Never" in Inline changes, then `diff.color-words.max-inline-alternation = 0` is written at user scope and the open diff reloads (Story 5.12's wiring), and the Rust side shows each 1:1 block as an old and a new line.
- Given a search for "whole word" and "longest common run", when run over code docs, the schema, the l10n strings, the catalogue, the design system and project-context.md, then no description of the Zanshin style matches.
- Given the parity oracle and Story 5.10's tests, when run, then they pass with unchanged expectations.

## Spec Change Log

## Review Triage Log

### 2026-11-14 — Review pass
- verdicts: 24 findings — high 0, medium 0, low 20, false 4, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) The `similar` WHY comment names only "no `std` deadline"; without `std` similar 3.2.1 also uses `BTreeMap` maps and a fixed SipHash key in its Myers preflight (`src/types.rs`, `src/algorithms/utils.rs:83-99`) — patched: the comment names both effects and that `WORD_MARKS_LIMIT` was measured that way. Collisions only slow the dedup (linear scans), and the inputs are the user's own files.
  - `[low]` `[reject]` (blind) The limit measurement harness was not kept in `benches/` — same as Story 5.11; the numbers sit in the constant's doc and Design Notes; keeping a harness adds code that never runs in the gate.
  - `[false]` `[reject]` (blind) No test shows the `Words` style reading `max-inline-alternation` from jj config — `Walk::word_lines` reads `self.options.words.max_inline_alternation`, which `DiffReader::new` fills from the effective config for both styles; the parity oracle proves that path at `0` and `-1` (`crates/zanshin-parity/tests/oracle/diff_color_words.rs:255-267`), and `words_mark_the_changed_part_of_the_error_cleanup` proves the `Words` branch at `Some(0)`.
  - `[false]` `[reject]` (blind) `merged_runs` silently drops kept tokens left on one side — cannot happen: `compare_tokens` keeps a token only with a full group of pairs, so kept tokens pair one to one in order, and `shift_right` swaps a kept token for an equal one on the same side, so both sides keep equal kept sequences; `both_styles_keep_the_lines` rebuilds both sides' texts from every merged line.
  - `[low]` `[reject]` (blind) Whitespace-only changes inside a line: merged they show tinted blank parts, not merged they show no mark, and at `-b` a changed indentation keeps two lines — each follows the story's rules 4 and 6 (Claude's calls Ralph reviews in the app); no defect beyond the rules.
  - `[low]` `[reject]` (blind) The tokenizer splits a grapheme cluster (combining mark, ZWJ emoji, flag pair) into tokens — real but rare in code diffs and only visual (segments stay on `char` boundaries); a cluster-aware tokenizer adds branches the story's rule 1 does not have.
  - `[low]` `[reject]` (blind) The size check tokenizes and builds the owner vectors before rejecting a huge block — the same shape Story 5.11's review rejected; jj's line diff of such a block already costs more; a counting pass adds code.
  - `[low]` `[reject]` (blind) The DS card and the catalogue show no merged row with both colours and no 1:1 block that stays two lines; the catalogue numbers 1–30 while the card uses 961/959 — the story asks for the four single lines and one chain from the Rust pins (done); a both-colour changed row is already on the card (Story 5.10's inlined block); the catalogue numbers are the Rust fixture's, as the story asks.
  - `[low]` `[reject]` (blind) The DS readme's dated 5.11 entry was reworded — it keeps its date and facts with a pointer to the 5.13 entry; restoring "whole words" would make the story's wording witness hit the design system. Its other point, "Settings › Diffs" in the 5.13 entry, was fixed in the patch below.
  - `[low]` `[patch]` (blind) `DiffView.prompt.md` and the readme's 5.13 entry say "the same indentation and line end", but rule 6 compares all trailing whitespace — patched: both use the rule's words; the readme entry now says "Settings › General › Diffs"; DS republished.
  - `[low]` `[patch]` (blind) `project-context.md` dropped "own rules inside either", so nothing closes the `Words` rules — patched: the sentence forbids rules beyond `hunks.rs`' rules 1–6.
  - `[low]` `[reject]` (blind) `zanshin_ffi.h` re-wraps the `zanshin_diff` prototype — generated by cbindgen from the doc lines (it flipped before in `ecd0105d`, `cc725683`); a rerun leaves no diff; pinning cbindgen's wrapping is a config change outside this story.
  - `[low]` `[reject]` (blind) `30 000` appears in the constant, the `DiffMarks::Words` doc and `docs/ffi-abi.md` with nothing tying them — as for 5.11's `100 000`; a doc-sync assertion adds a test harness for one number.
  - `[low]` `[patch]` (blind) `epic-5-context.md` still lists 5.13 as backlog and "the open story"; `sprint-status.yaml` says backlog — patched: both say done.
  - `[low]` `[reject]` (blind) `words_mark_blanks_only_between_marked_words` chains the private steps by hand — it tests rule 4 on a 2:2 block, its later asserts go through `words()`, and every other `Words` test drives `Walk::word_lines` through `words()` / `words_with()`, so a change of the product's order would fail those.
  - `[low]` `[reject]` (edge) Grapheme cluster split — same as the blind row.
  - `[low]` `[reject]` (edge) Huge block allocated before the limit check — same as the blind row.
  - `[low]` `[patch]` (edge) The DS says "line end" where rule 6 compares trailing whitespace — grouped with the blind row; patched there.
  - `[false]` `[reject]` (intent) The item accounting, verification outcomes and commit hashes are missing — they are written at finalize (`## Auto Run Result`, Verification notes) after this review.
  - `[low]` `[reject]` (intent) The UI witness is checked only at stand-in surfaces (widget test, hand-copied catalogue lines, `a`→`A` across the FFI) — the Marionette check is the loop's main session's by the story-loop rule (spec Never list); a merged line crosses the wire like any `Changed` line, whose transport is unchanged.
  - `[false]` `[reject]` (intent) "Never" turning merged lines into two lines is checked only in pieces — Story 5.12's scope test fires `configWrites` and asserts the inspector and operation view reload; the Rust side at `Some(0)` is pinned here; nothing between them changed.
  - `[low]` `[patch]` (intent) `project-context.md` drops the "own rules" guardrail; the DS readme's 5.11 entry rewritten — the first part grouped with the blind row (patched), the second with its blind row (rejected).
  - `[low]` `[reject]` (intent) Generated-header noise in `zanshin_ffi.h` — same as the blind row.
  - `[low]` `[patch]` (intent) `epic-5-context.md` and `sprint-status.yaml` labels; DS republishing unrecorded — labels patched (blind row); the republish versions are in `## Auto Run Result`.

## Design Notes

- **The rule reproduces every witness.** A throwaway probe of this planning run (scratchpad, not kept in the repo) implemented rules 1–6 as stated above over jj's blocks (checked with `jj diff` at `max-inline-alternation = 0`: the 9346978d blocks equal the epic probe's; 32 two-sided blocks, 13 of them 1:1, 12 merged at the default limit; 62 marks over 1,549 marked non-blank characters) and printed exactly the matrix rows, the epic's widget-test, stepper, reformat, nesting, reorder and indentation witnesses included. No witness difference to record.
- **Doubled words** stay consistent by token: a word token counts as kept only when both copies pair with the copies of one partner token. Kept tokens then pair one to one and in order, so the merged line can walk both sides' kept tokens together (shift right keeps the kept texts' order, because it swaps a kept token for an equal one with only changed tokens between).
- **Limit guide.** The probe (String tokens, a HashMap) took, in a release build on the M4 Pro: two-word vocabulary 36 ms at 50k entries; doubled two-word 48 ms at about 75k compared entries; four-symbol punctuation without blanks 35 ms at 23k and 70 ms at 47k; disjoint sides 8 ms at 100k. Expect a limit near 30k entries; the product code's own measurement decides.
- **Limit measured (build run, 2026-11-14).** `WORD_MARKS_LIMIT = 30_000` entries. Product code (`compare_tokens`, `shift_right` both sides, `side_runs` both sides, `merged_runs` for the doubled shapes) in a release build on the M4 Pro, five runs each, the limit lifted for the run, six random rounds at 30k: four-character punctuation-and-word vocabulary without blanks about 47 ms at 30k entries (51-55 ms at 33k), doubled 45-50 ms at 30.7k; two-word vocabulary in different orders 46-48 ms at 30k (one round 14 ms), doubled 18-21 ms; disjoint sides about 2 ms. At 35k the punctuation shape took 58 ms and two-word 53-55 ms, so 30k is the largest round size within about 50 ms. The probe's prediction (near 30k) held.
- **Merged lines and `max-inline-alternation`.** Rule 6 reads the same effective key and the same `None` / `Some(0)` / `count <= max` reading as the jj path, so Story 5.12's reload makes a new value count at once.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib -- hunks::` -- expected: pass.
- `cargo test -p zanshin-jj --test it -- hunks:: diff:: api_stability::` -- expected: pass.
- `cargo test -p zanshin-ffi --lib diff::`; `cargo test -p zanshin-ffi --test it -- diff_ffi:: ffi_abi_doc_sync::` -- expected: pass.
- `cargo test -p zanshin-parity --test oracle -- diff_color_words:: diff_revisions::` -- expected: pass, expectations unchanged.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`; `cargo fmt --all --check`; `cargo deny check advisories bans` -- expected: clean.
- `cargo make codegen` -- expected: generated files committed; a rerun leaves no diff.
- `packages/zanshin_core`: `dart analyze`, `dart format --set-exit-if-changed .`, `dart test test/ffi/diff_test.dart test/worker/diff_test.dart` -- expected: pass.
- `packages/zanshin_settings`: `dart analyze`, `dart format --set-exit-if-changed .`, `flutter test` -- expected: pass.
- `app`: `flutter gen-l10n`; `dart analyze`; `dart format --set-exit-if-changed .`; `flutter test test/features/settings/ test/features/graph/inspector_diff_test.dart test/features/graph/graph_inspector_test.dart test/features/undo_timeline/` -- expected: pass.
- `rg -n -i "whole[- ]word|longest common run"` over the files above -- expected: no description of the Zanshin style.

**Manual checks (if no CLI):**
- Catalogue "Inspector diff / Word marks" and the real app on a throwaway repo (Marionette, night and paper, unified and side by side, against the DS card) -- by the loop's main session, not this run.

**Verification notes** (2026-11-14, story run; the full gate is not run here, per the story loop's rule):
- `cargo test -p zanshin-jj --lib -- hunks::` — pass (31).
- `cargo test -p zanshin-jj --test it -- hunks:: diff:: api_stability::` — pass (103).
- `cargo test -p zanshin-ffi --lib diff::` — pass (8); `cargo test -p zanshin-ffi --test it -- diff_ffi:: ffi_abi_doc_sync::` — pass (25).
- `cargo test -p zanshin-parity --test oracle -- diff_color_words:: diff_revisions::` — pass (15), expectations untouched.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean; `cargo deny check advisories bans` — ok (also after the review's `Cargo.toml` comment patch).
- `cargo make codegen` — rerun left the generated files as committed (`zanshin_ffi.h` keeps cbindgen's three-line `zanshin_diff` prototype).
- `packages/zanshin_core`: `dart analyze` no issues, `dart format --set-exit-if-changed .` 0 changed, `dart test test/ffi/diff_test.dart test/worker/diff_test.dart` — pass (23).
- `packages/zanshin_settings`: `dart analyze` no issues, `dart format` 0 changed, `flutter test` — pass (46).
- `app`: `flutter gen-l10n` (no further change), `dart analyze` no issues, `dart format --set-exit-if-changed .` 0 changed, `flutter test test/features/settings/ test/features/graph/inspector_diff_test.dart test/features/graph/graph_inspector_test.dart test/features/undo_timeline/` — pass (265).
- Wording: `rg -n -i "whole[- ]word|longest common run"` finds only the unrelated `--when.commands` prefix docs and `epic-5-context.md`'s rule about the wording.
- Witness blocks: jj 0.47.1 in a throwaway repo (`JJ_CONFIG` = an empty file) cut 9346978d's `lib/src/git.rs` into the blocks the fixtures copy.
- Matrix test audit: every matrix row has a passing test (`words_mark_the_changed_part_of_the_error_cleanup`, `words_merge_a_one_line_block_by_its_alternation_count`, `words_mark_the_changed_part_of_the_jj_example`, `words_mark_the_widget_test_block`, `words_mark_the_stepper_edits`, `words_mark_a_reformat_a_nesting_and_a_reorder`, `words_keep_two_lines_when_the_edges_differ`, `words_leave_a_one_sided_block_unmarked`, `words_leave_a_block_over_the_limit_unmarked`, `words_swap_roles_under_a_base_term`, `both_styles_keep_the_lines`, the settings tests).
- Not run here: the full gate and coverage (story-loop rule; the implementer's targeted `cargo llvm-cov` on the hunks tests showed no uncovered new line), the Marionette check.
- After the review patches: `cargo test -p zanshin-jj --lib -- hunks::` pass (31), `cargo fmt --all --check` clean, `cargo deny check advisories bans` ok; `app`: `flutter test test/widgetbook/catalogue_smoke_test.dart test/widgetbook/ds_manifest_parity_test.dart` pass (374).

## Auto Run Result

Status: done

**Summary.** `DiffMarks::Words` (the app's default "Zanshin" style) now marks only the changed part of a line and shows one line replaced by one line as one line. In `crates/zanshin-jj/src/hunks.rs` rules 1–6 replace Story 5.11's blank-split words: tokens are blank runs, word runs and single other characters; `similar::capture_diff_slices` (Myers) compares them, word tokens doubled in a 1:1 block; changed runs shift right; blanks and punctuation between two marked tokens of a line are marked; `WORD_MARKS_LIMIT` = 30 000 comparison entries (measured on the M4 Pro, worst shapes 45–50 ms); a 1:1 block with equal indentation and trailing whitespace whose count fits `diff.color-words.max-inline-alternation` is one `Changed` line with exact segments. Every witness of the story reproduces (9346978d's four single lines each one line with only `.map_err(GitImportError::from_git)` marked; 671e4eaca; widget test; stepper; reformat; nesting; reorder; indentation). Jj's lines, hunks, counts and fingerprints, the jj style and the wire are unchanged.

**Commits.** `7629ab56c7153f0223e6be1e003dad7733f5e691` (implementation, docs, catalogue, design system); the spec, epic context and sprint status follow in the next commit.

**Files changed** (main ones):
- `crates/zanshin-jj/src/hunks.rs` — rules 1–6 (`tokenize`, `compare_tokens`, `shift_right`, `side_runs`, `merged_runs`, `Walk::word_lines`), `WORD_MARKS_LIMIT`, docs, tests and the 9346978d / probe fixtures.
- `Cargo.toml`, `crates/zanshin-jj/Cargo.toml` — `similar` without features, WHY comments.
- `crates/zanshin-jj/{src/repo.rs,tests/it/diff.rs}`, `crates/zanshin-ffi/{src/diff.rs,tests/it/diff_ffi.rs}`, `schemas/envelope.fbs` + generated code, `docs/ffi-abi.md` — wording; tests expect the merged line.
- `packages/zanshin_core` (`ffi/diff.dart`, `test/worker/diff_test.dart`), `packages/zanshin_settings` (`general_settings.dart`) — wording; the merged line across the FFI.
- `app/lib/src/features/settings/general_tab.dart`, `app/lib/l10n/*` — "Inline changes" in both styles with a hint per style; the reworded Zanshin hint.
- `app/test/features/{settings/settings_window_test.dart,graph/inspector_diff_test.dart}` — the row in both styles; new marks; a merged line in unified and side by side.
- `app/widgetbook/folders/graph.dart` — "Word marks" takes the new marks and the 9346978d lines.
- Design system (`DiffView.prompt.md`, `DiffHunk.prompt.md`, `DiffView.d.ts`, `DiffView.jsx` + `_ds_bundle.js`, `content.card.html`, `readme.md`) — republished: DS artifact version 35 (`1794620433-bf83`), canvas `6sAzL5mDcVpWXevbTcempu` version 52 (`1794620476-f2ec`).
- `_bmad-output/project-context.md` — the sanctioned-exception paragraph states the new rule and closes it at rules 1–6.

**Review.** One pass, 24 findings (low 20, false 4). Patched 4 low entries (7 rows): the `similar` WHY comment names what no `std` changes; the DS wording uses rule 6's words and the full Settings path (DS republished); `project-context.md` forbids rules beyond 1–6; `epic-5-context.md` and `sprint-status.yaml` say done. Deferred: none. Rejected 13 low rows (no kept bench harness, whitespace-only changes per rules 4 and 6, grapheme clusters, allocation before the limit check, catalogue and card coverage and numbering, the reworded 5.11 readme entry, cbindgen's header wrapping, the limit written in three places, a test chaining private steps, the stand-in UI surfaces) and 4 false (config reading of the limit, leftover kept tokens, item accounting before finalize, the "Never" reload) — reasons in the Review Triage Log.

**Follow-up review recommendation:** `false`. Patched: high 0, medium 0, low 4 — no risk left to name.

**Verification:** see Verification notes above.

**Deferred-work items:**
- **I1** (the Zanshin style marks a whole call chain): fixed (`7629ab56c7153f0223e6be1e003dad7733f5e691`). Rules 1–5: 9346978d's single lines mark only `.map_err(GitImportError::from_git)`, as RustRover does (`words_mark_the_changed_part_of_the_error_cleanup`).
- **I2** (one line where one line replaces one line): fixed (`7629ab56c7153f0223e6be1e003dad7733f5e691`). Rule 6 with Claude's calls as stated (words count twice, a changed indentation or trailing blank keeps two lines, exact segments so `{+let lock = +}` holds its blank); 12 of the 13 one-line blocks of 9346978d merge at the default limit. Ralph's in-app review of those calls stays with Ralph, as the item says; no new deferral.

**Residual risks:**
- The Marionette check (catalogue and the real app, night and paper, unified and side by side, against the DS card) is left to the loop's main session.
- The full gate and coverage run at the loop's end; `hunks.rs` sits at a 100 % baseline (the targeted `cargo llvm-cov` showed no uncovered new line).
- Blocks over 30 000 comparison entries now go unmarked sooner than under Story 5.11's 100 000 tokens.
