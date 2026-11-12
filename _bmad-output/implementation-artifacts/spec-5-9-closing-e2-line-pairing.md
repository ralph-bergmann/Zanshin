---
title: 'Story 5.9 closing run — E2: pair lines before jj-lib''s word diff, and measure it'
type: 'feature'
created: '2026-11-12'
status: 'done'
baseline_revision: 'c7587fa3dbd2f17d0e2bd810f186bff70e0983ae'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      E2 does not bring the word marks closer to difftastic on real diffs; Ralph decides whether to keep it as built, change its similarity rule or threshold, or go back to jj-lib's block-wide marks.
    evidence: |-
      Probe history at 5ba5f5d4 (2,536 files, 96,295 lines without a difft fallback), line_pairs.rs blob 15ddbd39: lines whose marks differ from difft's, today 4,755 word / 10,812 drawn, E2 5,148 / 10,332; net change of today's gap -8.3 % word, +4.4 % drawn; 3,189 of E2's differing lines are whole-line marks (no partner). The witnesses hold (Ralph's example: E2 = difft on 19 of 19 lines, today 16). Report section 9, open point 1.
    location: >-
      crates/zanshin-jj/src/line_pairs.rs (MIN_SIMILARITY_PERCENT, group_value)
    severity: medium
  - summary: >-
      E2 is not measured on reflowed prose (doc comments, Markdown, commit descriptions), where words move between lines and E2 has no many-to-many groups.
    evidence: |-
      Not measured: the probe corpus is .rs / .dart only. pair_lines also runs on .md files and on the inter-diff description block (hunks_of). With groups of 1:1, 1:k and k:1 only, a paragraph rewrapped over different line counts may mark moved words, or whole lines, where jj's block-wide diff marked only the line breaks. Settled by running the probe on .md files and commit descriptions.
    location: >-
      crates/zanshin-jj/src/line_pairs.rs (group_shapes)
    severity: medium (unverified)
  - summary: >-
      In a block of one removed and one added line, E2 can only lose word marks: jj's block-wide diff cannot scatter there, yet a pair at or below 50 % similarity becomes two whole-line marks (`true,` → `false,` is exactly 50 %).
    evidence: |-
      For a 1×1 block jj-lib's block-wide word diff equals the pair's word diff, so E2 equals jj's marks when the pair is taken and marks both whole lines when it is not (pinned by `a_group_pairs_only_above_half`, and by the intent's `a` → `A` row). jj and difft mark only `true` / `false` in `true,` → `false,`. How many of E2's differing lines come from such blocks is not counted. Follow-up review of the closing run, blind finding 5; part of Ralph's decision on deferred item 1.
    location: >-
      crates/zanshin-jj/src/line_pairs.rs (pair_block, group_value, MIN_SIMILARITY_PERCENT)
    severity: medium
---

<intent-contract>

## Intent

**Problem:** Ledger item 1 handed to this closing run (Story 5.9's build, decided by Ralph on 2026-11-12: option E2, the "Decided 2026-11-12" note in epics.md Story 5.9). jj-lib's `unified_diff_hunks` (`jj-lib-0.47.0/src/diff_presentation/unified.rs:229-233`) word-diffs all removed lines of a changed block against all its added lines as one text (`ContentDiff::by_word`). When a block rewrites several lines, common words match across unrelated lines and the marks scatter — on Ralph's widget-test example almost every word of both comments and both test names is marked.

**Approach:** Keep jj-lib's line-level hunks untouched and rewrite only the word tokens of each changed block: pair its removed and added lines by similarity (order kept, minimum similarity, one line may pair with a run of consecutive lines on the other side), word-diff each pair with jj-lib's own `ContentDiff::by_word`, and give a line without a partner one changed segment for the whole line. Above a work cap the block keeps today's block-wide tokens. Then measure E2 against `difft` and against today's marks with the Story 5.9 probe on the research corpus.

## Boundaries & Constraints

**Always:**
- Line-level hunks (lines, kinds, ranges, counts, sections, symbols, fingerprints) stay exactly `unified_diff_hunks`' output — only `Hunk::segments` change. Whitespace modes (`Whitespace`, `-w` / `-b`) keep working: pairing runs inside whatever blocks the mode leaves.
- Word tokens are jj-lib's: `ContentDiff::by_word` per pair, `unzip_diff_hunks_to_lines` to split them into lines. No own word tokenizer or word diff.
- The pairing lives in one new module, `crates/zanshin-jj/src/line_pairs.rs`, that imports only `jj_lib` and `std`, so the probe compiles the same file (`#[path]`) and measures the real implementation without building zanshin-jj.
- Similarity, threshold, run length and work cap are named constants with doc comments that say why (Design Notes).
- Segment invariants hold: a line's segments concatenate to its text, none is empty, adjacent ones differ in kind.
- Docs that state 5.2's rule ("segments = what `jj diff --git` underlines") are reworded to the E2 rule: the Rust docs, `schemas/envelope.fbs` (then `cargo make codegen`, generated output committed), `docs/ffi-abi.md`, the zanshin_core Dart docs, `inspector_diff.dart`'s doc comment, `project-context.md`'s "Word diffs are jj-lib's" rule.

**Never:**
- No change to jj's line-level hunks, the wire schema's shape, `hunk_line`'s run merging, or the Dart drawing (`diffWordMarks`); no move detection; no tree-sitter; no `difft` in the product.
- No edit of Story 5.9's spec, its deferred-work ledger bullet, or epics.md Story 5.9.
- No full gate (`cargo make test` / `test-full` / `coverage`) — targeted checks only (loop gate rule).
- No jj outside temp dirs; nothing under `~/development/projects/Kunden/`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Ralph's example | 3 removed lines (2 comments, the old `testWidgets(... on the last step'`) vs 16 added (comment, phone test, …, tablet test) | comment lines: one whole-line changed segment each; old test pairs with the tablet test, only ` on a tablet` changed; phone test: one whole-line segment | — |
| Expression rewrite | `s.functionWizard_save` → `saveLabel` (3 lines, each paired 1:1) | marks exactly `s.functionWizard_save` / `saveLabel`, `functionWizard_save` / `functionWizard_next`, `1` / `2` | — |
| Call split over three lines | `Expanded(child: …)),` → `Expanded(` / `child: …,` / `),` | removed line: no changed segment; added lines: only the new line break, indentation and comma (today's marks) | — |
| Inserted comment line | `padding: …spacing8,` → `// Small side padding.` + `padding: …spacing2,` | comment line: one whole-line Added segment; `spacing8` / `spacing2` paired, only they are marked (the leading `  ` is no longer marked) | — |
| Join (k:1) | two removed lines → one added line holding both | joined pair keeps precise marks | — |
| Dissimilar 1:1 | `a` → `A` | each line one whole-line segment (`a\n`, `A\n`) | — |
| Block over the work cap | e.g. 20,000 changed statements | today's block-wide tokens, unchanged | — |
| `-w` / `-b` | whitespace-only lines become context | pairing runs on the remaining blocks; whitespace-only hunks still drop | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/hunks.rs:701-730` -- `hunks_of`: calls `unified_diff_hunks` then maps lines via `hunk_line` (734-767). E2 hooks in between: `let mut hunks = unified_diff_hunks(…); line_pairs::pair_lines(&mut hunks, texts);`. `Segment` doc (242-246) and module doc state 5.2's rule. Inline tests 937-1031 (`marked`, `segments_are_the_words_jj_underlines`, `a_moved_line_break_is_only_one_more_token`, `an_inserted_line_does_not_pair_with_a_changed_one`) are the stepper/10.32 witnesses; the last one asserts today's `{+  +}` scatter and must change.
- `crates/zanshin-jj/src/lib.rs` -- module list; add `mod line_pairs;`.
- `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.47.0/src/diff_presentation/unified.rs:183-240` -- `unified_diff_hunks`; a block is removed lines then added lines between context lines / hunk breaks; context lines carry the right side's text but advance both sides' counters. `mod.rs:104-156` -- `unzip_diff_hunks_to_lines` (pub). `jj-core-0.47.0/src/diff.rs:34` `find_line_ranges`, `:774` `ContentDiff::by_word` (exact compare, word then non-word refine), `DiffHunk { kind, contents }`.
- `crates/zanshin-ffi/tests/it/diff_ffi.rs:153-158` -- asserts `a\n` → `[Removed "a", Equal "\n"]`; becomes `[Removed "a\n"]`. `assert_wire_is` compares wire segments to `Hunk::segments` (unchanged).
- `packages/zanshin_core/test/worker/diff_test.dart:109-110` -- same `a` / `A` expectation through the real cdylib.
- `app/test/features/graph/graph_real_repo_test.dart:189-192` -- real-worker witness: `'  padding: Spacing.spacing2,': ['  ', 'spacing2']` becomes `['spacing2']`.
- `app/widgetbook/folders/graph.dart:1035-1131` -- `_DemoDetails._words` demo data "as `jj diff --git` underlines them"; hunk 3's `{+  +}padding` and comment line follow E2's output; doc reworded.
- Docs with 5.2's rule: `crates/zanshin-ffi/src/diff.rs:8-9,93`, `schemas/envelope.fbs:3189-3194`, `docs/ffi-abi.md:2512`, `packages/zanshin_core/lib/src/ffi/diff.dart:71,94-96`, `packages/zanshin_core/lib/src/worker/handle.dart:1629-1630`, `app/lib/src/features/graph/inspector_diff.dart:57`, `_bmad-output/project-context.md:863-866`. Generated: `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart`, `crates/zanshin-ffi/src/envelope_generated.rs`, Dart flatc output (via `cargo make codegen`).
- `app/lib/src/features/graph/inspector_diff.dart:60-75` -- `diffWordMarks`: no strong marks when no Equal segment holds visible text, so a whole-line segment draws only the faint fill. Read-only: no change.
- `spikes/structural-diff-probe/` -- detached crate (`Cargo.toml` jj-lib 0.47.0 no default features). `src/marks.rs:59-99` `jj_diff` (today's marks), `drawn` / `classify` / `classify_drawn`; `src/history.rs` corpus loop and tables; `src/witness.rs` witness printing; `src/limits.rs` synthetic inputs + `jj-marks` child; `README.md` method/results; `inputs/witness/<case>/`.
- `_bmad-output/planning-artifacts/research/technical-structural-diff-difftastic-class-research-2026-11-12.md` -- German report, sections 1-8 + Anhang; §6 has today's figures (11.2 % drawn, 4.9 % word marks of 96,295 non-fallback lines).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/line_pairs.rs` -- new: `pair_lines(&mut [UnifiedDiffHunk<'a>], Diff<&'a [u8]>)` finds each block (removed run + added run), cuts its text with `find_line_ranges`, and replaces its lines' tokens with `pair_block`'s, or keeps them when the block is over the cap. `pair_block`: order-keeping DP over (removed, added) with groups 1:1, 1:k and k:1 (k ≤ `MAX_RUN_LINES`), group value `200·kept − MIN_SIMILARITY_PERCENT·ink`, upper-bound pruning, then `by_word` + `unzip_diff_hunks_to_lines` per chosen group and one `Different` token per unpaired line. Inline unit tests: cap fallback, join, threshold edge, unpaired line, run choice. -- the E2 build.
- `crates/zanshin-jj/src/lib.rs` -- declare the module. -- wiring.
- `crates/zanshin-jj/src/hunks.rs` -- call `pair_lines` in `hunks_of`; reword `Segment` / module docs; rework the three witness tests to E2's marks and add Ralph's example, a dissimilar 1:1 line and a `-b` case. -- the outermost Rust surface of the segments.
- `crates/zanshin-ffi/tests/it/diff_ffi.rs`, `packages/zanshin_core/test/worker/diff_test.dart`, `app/test/features/graph/graph_real_repo_test.dart` -- new expectations. -- tests that pinned 5.2's marks.
- Doc files listed in the Code Map, then `cargo make codegen` -- reword 5.2's rule to E2's. -- no stale contract text.
- `app/widgetbook/folders/graph.dart` -- demo data hunk 3 to E2's segments; doc wording. -- the catalogue shows what the backend sends.
- `spikes/structural-diff-probe/` -- compile `line_pairs.rs` via `#[path]`; `marks::jj_diff` gains E2 marks (`Line.e2`) and E2 time; `history` adds E2-vs-difft tables (word and drawn), the net change of today's gap, E2-vs-today counts, E2 cost per file next to jj's, examples where E2 and difft differ; `witness` prints an `e2` row per changed line and adds Ralph's example as an input case; `limits` adds E2 time (child prints it) and an at-cap input. Run `witness`, `history --rev 5ba5f5d43b21d45c24c099092384f9d9610fe009`, `limits`; paste outputs into README results; then `cargo clean`. -- Ralph's measurement.
- Research report -- new German §9 "E2" with the figures; status line points to it. -- Ralph's measurement write-up.
- `_bmad-output/project-context.md` -- reword the "Word diffs are jj-lib's" rule. -- canonical rules follow the decision.

**Acceptance Criteria:**
- Given any two texts, when `compute_hunks` / `Repo::diff` runs (any `Whitespace`), then its lines, ranges, counts, sections, symbols and fingerprints equal today's, and only segments differ.
- Given a changed block within the file's pairing budget, when its segments are computed, then each removed / added line either carries one whole-line changed segment (no partner) or its pair's `by_word` tokens; over the budget, today's tokens.
- Given the probe's history corpus, when `history` runs, then it reports for E2 and for today the drawn and word-mark classes against `difft`, the net change of today's gap under E2, and E2's cost per file next to jj's.

## Spec Change Log

- 2026-11-12 (build, matrix audit): **Similarity by tokens, not bytes.** The first build measured similarity in non-whitespace bytes, so `a.functionWizard_save` → `a.functionWizard_next` kept 14 % and stayed unpaired, against the I/O matrix's expression row. The matrix is authoritative, so the code changed: similarity now counts jj-lib's word-diff tokens (each word or non-whitespace byte counts 1), and that row keeps 3 of 4 tokens a side (75 %). The expression row now holds (`hunks.rs` `paired_lines_take_jjs_words`, `graph_real_repo_test.dart`); the Similarity and Threshold notes are recomputed in tokens.
- 2026-11-12 (build): **Second pruning bound.** With only the Design Notes' size bound, E2's per-file p99 was 12–13 ms (8–10× jj's, measured with bytes) at every cap tried, because blocks of dissimilar lines prune nothing. `pair_block` also caps `kept` at the tokens a group's lines share (jj-lib's word diff keeps only whole equal words and equal single non-word bytes); it is an upper bound, so skipping never changes the result (verified with bytes and with tokens: debug-assertion runs on the whole corpus, identical counts). With tokens and the per-block cap, p99 3.1 / 3.3 ms.
- 2026-11-12 (build, review): **Per-file budget instead of a per-block cap.** The per-block cap bounded neither a file of many blocks nor the runs (it counts only 1:1 reads): 20 blocks of one-line calls reformatted to one argument per line took 3.15 s. `MAX_PAIRING_WORK` is now a per-file budget on the bytes the scoring word diffs read: a block whose 1:1 reads exceed what is left is not searched, `pair_block` subtracts each diff's input bytes, and once the budget runs out that block and every later block keep today's tokens. Value kept at 256 KiB: a search that uses all of it takes about 20 ms. `find_line_ranges` runs only once a block with removed and added lines is found.
- 2026-11-12 (build, review): The probe's "share of today's gap closed" is labelled **net change of today's gap** (lines E2 brings to difft's marks minus lines it takes away, over today's differing lines), since it can be negative.
- 2026-11-12 (build): **Probe mapping against E2.** For E2 against difft, the corrected mapping rule takes E2's word marks inside novel comments and strings (today's are used against today), so each side is compared with difft on code tokens only. With today's marks there, difft's proxy would carry the scatter E2 removes (`widget-test-rename` witness).
- 2026-11-12 (build): `cargo test` takes one filter, so the first Verification command runs as `cargo test -p zanshin-jj --lib -- hunks:: line_pairs::`. Ralph's widget-test example is his exact hunk (`hunks.rs` `rewritten_comments_and_a_renamed_test_mark_only_the_rename`; the probe's `widget-test-rename` keeps its lines inside a minimal Dart frame so difft parses it).
- 2026-11-12 (follow-up review): **The budget pays for the search's table.** Triggered by blind 1 / edge-case 1 (high): the per-file budget paid only for the scoring word diffs, so a block whose candidates the bounds all prune built its shared-token table and searched every cell for free, and a file of many such blocks grew without limit (`limits` `e2-pruned-blocks`, 280 KB: 371.8 ms against jj's 14.5 ms, budget never short). Amended: `pair_lines_within` now subtracts `block_work` (the one-to-one candidates' bytes, which the table reads and which bound its size) before `pair_block`, then each scoring diff pays as before; `MAX_PAIRING_WORK` stays 256 KiB. Known-bad state avoided: a time bound that holds only for blocks whose candidates run word diffs. KEEP: the shared-token bound, the 256 KiB value, the fallback to jj-lib's block-wide tokens, the `ran_out` flag (now documented as "a block kept jj-lib's tokens because the budget could not pay for it"). The probe's `e2-at-cap` now fills the budget with table and diffs together (44 lines a side); figures re-measured on blob `21d507ba`.

## Review Triage Log

### 2026-11-12 — Review pass
- verdicts: 27 findings — high 2, medium 3, low 14, false 7, maybe-false 1
- findings:
  - `[low]` `[reject]` (intent-alignment 1) The stepper comment example's `padding` line lost its indentation fill, against "keep their marks" — the word marks (`spacing8` / `spacing2`) are unchanged; only the whitespace fill went, which is the cross-line scatter E2 removes (difft agrees), and report §8 point 5 already scoped that witness to word marks.
  - `[false]` `[reject]` (intent-alignment 2) `inspector_diff_test.dart` stays on pre-E2 segments — it tests the unchanged drawing rule with fixed inputs; E2's output reaches the paint surface in `graph_real_repo_test.dart` (rerun, 2 passed).
  - `[false]` `[reject]` (intent-alignment 3) Ralph's example is checked on the backend only — `pair_lines` runs inside `hunks_of`, the one producer of `Hunk::segments` for `compute_hunks` and `Repo::diff`; the wire copies them unchanged (`diff_ffi.rs` `assert_wire_is`), and the drawing rule for a whole-line segment (faint fill only) is `diffWordMarks`' existing early return.
  - `[false]` `[reject]` (intent-alignment 4) The two difft proxies make the gap figures incomparable — each variant keeps its own word marks only inside comments and strings, so both are compared with difft on the same code tokens; the method is stated in the README and report §9.
  - `[medium]` `[defer]` (intent-alignment 5) E2's word marks end up further from difft than today's (net −8.3 %; drawn +4.4 %), yet E2 is the default — the intent asked to build and measure; keeping E2, changing its rule or going back is Ralph's decision (deferred item 1, report §9 open point 1).
  - `[false]` `[reject]` (intent-alignment 6) The move witness is still measured by the probe — dropped as an acceptance witness; the `reorder-*` probe cases are data only and harm nothing.
  - `[false]` `[reject]` (intent-alignment 7) Spec figures, Auto Run Result, deferred-work mirror and `cargo clean` are missing from the diff — the spec is left out of the review diff on purpose; the rest happens at finalize; the probe has no `target/`.
  - `[medium]` `[patch]` (verification-gap) No test pins runs of 4–8 lines — added `a_run_of_eight_lines_pairs` (8-line split and its mirror join) and `a_run_of_nine_lines_does_not_pair` in `line_pairs.rs`.
  - `[low]` `[patch]` (verification-gap, other) `docs/ffi-abi.md` "Segments (5.2)" broken wrap — paragraph rewrapped to 100 columns.
  - `[low]` `[patch]` (verification-gap, other) `epic-5-context.md` "until E2 replaces them" is stale — reworded to the built rule.
  - `[medium]` `[patch]` (blind 1) The "slowest case" timing claim is not shown; run-heavy blocks are slower — grouped with edge-case 1–2: `MAX_PAIRING_WORK` is now a per-file budget on the bytes the scoring diffs read; the doc no longer names a slowest case; `limits` gained `e2-reformatted-calls` (21.2 ms, budget ran out).
  - `[false]` `[reject]` (blind 2) A group's slot can stay empty through `zip` truncation — `unzip_diff_hunks_to_lines` splits each group's text, made of whole lines, at its line breaks (a last line without `\n` is pushed as the final line), so it yields exactly the group's line count; no slot stays empty.
  - `[low]` `[patch]` (blind 3) Line bookkeeping untested for an offset hunk with two blocks, and `-w` untested — added `two_blocks_in_one_hunk_keep_their_own_marks` under `Exact` and `IgnoreAllSpace` (grouped with the run-length test gap).
  - `[low]` `[reject]` (blind 4) Order-keeping forces worse partners on swapped lines — "keeping their order (no crossing pairs)" is the intent's own rule; its cost is inside the measured figures (§9).
  - `[maybe-false]` `[defer]` (blind 5) Reflowed prose (doc comments, Markdown, descriptions) is not measured; with no k:l groups E2 may mark moved words where jj marked only line breaks — if true medium (unverified); settled by running the probe on `.md` files and commit descriptions (the intent fixed the corpus to `.rs` / `.dart`); deferred item 2.
  - `[low]` `[patch]` (blind 6) "Exact bound" is the wrong term — reworded to "an upper bound, so skipping never changes the result" in code, README, report and spec.
  - `[low]` `[patch]` (blind 7) `epic-10-context.md:59` still states 5.2's rule — reworded to the built rule.
  - `[low]` `[patch]` (blind 8) `epic-5-context.md` stale and future tense — reworded (same root cause as the verification-gap item).
  - `[low]` `[patch]` (blind 9) `docs/ffi-abi.md` broken wrap — same fix as the verification-gap item.
  - `[low]` `[reject]` (blind 10) The one-line contract summaries (`zanshin_ffi.h`, `diff.rs`, `bindings.dart`, `handle.dart`, Dart `Segment`) omit the unpaired-line and budget cases — the full rule sits in the schema doc, `docs/ffi-abi.md` and `HunkLine.segments`; changing the summaries means a codegen round for wording only.
  - `[false]` `[reject]` (blind 11) Open points are not mirrored for Ralph — finalize mirrors this run's deferred items to deferred-work.md; the `-w` / `-b` question is already in Story 10.33's sprint-status entry ("whether the word marks (5-2, 5-9) also ignore whitespace").
  - `[low]` `[patch]` (blind 12) The published figures name no code revision — `git hash-object` of the measured `line_pairs.rs` (`15ddbd39…`) recorded in README, report §9 and Verification.
  - `[low]` `[patch]` (blind 13) `find_line_ranges` scans both whole files on every call — computed only when the first block with removed and added lines is found.
  - `[low]` `[patch]` (blind 14) Run length over the limit, ties and the cap edge are untested — added `a_run_of_nine_lines_does_not_pair`, `a_tie_keeps_the_shorter_group` and `a_spent_budget_leaves_later_blocks_to_jj_lib` (budget edges at 34 / 33 / 29 / 23 bytes).
  - `[low]` `[patch]` (blind 15) "Share of today's gap E2 closes" is a net change — relabelled "net change of today's gap" in `history.rs`, README, report and spec.
  - `[high]` `[patch]` (edge-case 1) A block within the cap pairs run-heavy (one-line calls reformatted to one argument per line) for 158 ms — per-file budget on actual diffed bytes (see blind 1).
  - `[high]` `[patch]` (edge-case 2) No per-file limit: 20 such blocks took 3.15 s against 4.2 ms for jj — same fix; the input now pairs in 21.2 ms and the rest falls back to jj-lib's tokens; on the corpus the budget runs out in 9 of 2,536 files.

### 2026-11-12 — Review pass (follow-up)
- verdicts: 26 findings — high 2, medium 2, low 13, false 8, maybe-false 1
- findings:
  - `[low]` `[patch]` (intent-alignment 1) The work cap reads per block in the intent but is a per-file budget in the code, and the docs carry both framings ("a huge block" vs "the file's pairing budget") — the per-file budget is the previous pass's recorded fix (a per-block cap bounds no file); the docs now say one thing everywhere: "a block the file's pairing budget cannot pay for keeps jj-lib's word diff" in `schemas/envelope.fbs` (+ codegen, comment-only), `hunks.rs` `Segment`, Dart `HunkLine.segments`, `docs/ffi-abi.md`. `project-context.md`'s "a block over the pairing cap" is left as is: it names no per-block size, and the file is agent context.
  - `[false]` `[reject]` (intent-alignment 2) Commit `30714877` edits Story 5.9's spec and its ledger bullet against the intent's "Never" — that commit is the story loop's own ledger close (`.claude/skills/story-loop/SKILL.md`, "close Story <id> deferrals"), not this build; the build's commits `a91fbddd` / `cbb910f3` leave both untouched.
  - `[false]` `[reject]` (intent-alignment 3) Several matrix rows' tests pass with or without pairing, and the wire level sees only `a` → `A` — for those rows (expression rewrite, call split, join, `-b`) the intent expects exactly jj-lib's output, so a test equal to it is the right check; the rows where E2 differs are pinned (Ralph's example, inserted comment, dissimilar 1:1, two blocks at an offset, 9-line run, tie, threshold); the wire copies `Hunk::segments` unchanged (`assert_wire_is`).
  - `[false]` `[reject]` (intent-alignment 4) carried — Ralph's example is checked on the backend only (intent-alignment 3 of the first pass): `pair_lines` runs inside `hunks_of`, the one producer of `Hunk::segments`; the wire copies them, and a whole-line segment draws through `diffWordMarks`' existing early return.
  - `[false]` `[reject]` (intent-alignment 5) No test compares the line-level output with and without pairing — `pair_lines` writes only tokens; the debug assertion checks every block's tokens against its text in every test, `marked` checks each line's segments against its text, and the parity oracle (509) compares the lines with the jj CLI with pairing on.
  - `[medium]` `[defer]` (intent-alignment 6) carried — E2's word marks end up further from difft than today's (intent-alignment 5 of the first pass; deferred item 1). The re-run moved the figures only slightly (−8.3 % word, +4.5 % drawn).
  - `[false]` `[reject]` (intent-alignment 7) carried — the two difft proxies make the gap figures incomparable (intent-alignment 4 of the first pass): each variant keeps its own word marks only inside comments and strings, so both are compared with difft on the same code tokens.
  - `[maybe-false]` `[defer]` (intent-alignment 8) carried — the corpus is `.rs` / `.dart` only, reflowed prose is unmeasured (blind 5 of the first pass; deferred item 2).
  - `[low]` `[reject]` (intent-alignment 9) carried — the one-line contract summaries omit unpaired lines and the fallback (blind 10 of the first pass): the full rule sits in the schema doc, `docs/ffi-abi.md` and `HunkLine.segments`.
  - `[low]` `[reject]` (intent-alignment 10) carried — `epic-5-context.md` says the stepper examples "keep their marks" while the comment example lost its indentation fill (intent-alignment 1 of the first pass): the word marks are unchanged; the fill was the scatter E2 removes.
  - `[low]` `[patch]` (verification-gap, other) The schema, `hunks.rs`, Dart and `project-context.md` docs say "a huge block" / "over the pairing cap" while the budget is per file — grouped with intent-alignment 1, same fix.
  - `[high]` `[patch]` (blind 1) The budget does not bound time: the shared-token table and the search over every cell are never charged, so pruned blocks cost nothing and a file of many of them grows without limit; the module doc's "bounds the pairing's time and memory per file, whatever its blocks" is false — verified in the code (`pair_block` touches `budget` only before a scoring diff) and measured: `e2-pruned-blocks` (300 blocks of 120 unrelated one-word lines, 280 KB) took 371.8 ms against jj's 14.5 ms with the budget never short. Fixed: each searched block pays `block_work` before its search (`pair_lines_within`); now 1.6 ms. `a_spent_budget_leaves_later_blocks_to_jj_lib` reworked (58 / 57 / 53 / 23 bytes; at 57 the second block, which runs no word diff, now keeps jj-lib's tokens, which fails on the old code); `MAX_PAIRING_WORK` doc rewritten; probe `limits` gained `e2-pruned-blocks`, `e2-at-cap` resized; witness / history / limits re-run.
  - `[low]` `[patch]` (blind 2) The public contract describes the fallback wrongly in five places; the Dart `Segment` summary omits unpaired lines and the fallback — grouped with intent-alignment 1 (the "huge block" wording, fixed); the one-line summary part is the carried rejection of the first pass's blind 10.
  - `[false]` `[reject]` (blind 3) The block-text invariant is only a `debug_assert`, so drifting line counters would show other lines' text in release; `sides == None` skips without `ran_out` — the counters advance exactly as `unified_diff_hunks` builds its lines (context: one line each side; removed / added: one on their side) over the same `find_line_ranges` split, so no input reaches a drift; the assertion runs in every test, offset hunks and `-w` included.
  - `[low]` `[reject]` (blind 4) `hunks_of` discards `pair_lines`' flag, no `#[must_use]`, no log — a developer meets it only when chasing why one file's marks scatter; the fix adds logging, not a direct correction; the probe reads the flag.
  - `[medium]` `[defer]` (blind 5) In a 1×1 block E2 can only lose marks: no scatter is possible, yet a pair at or below 50 % becomes two whole-line marks (`true,` → `false,`) — verified: `group_value(1, 4)` is 0, so the pair is pruned, while jj and difft mark only `true` / `false`. The intent's `a` → `A` row asks for whole lines in exactly such a block, so keeping jj-lib's tokens there changes the intent; deferred to Ralph's decision on item 1 (new deferred item 3, mirrored to deferred-work.md).
  - `[low]` `[patch]` (blind 6) The 3,189 whole-line lines are attributed only to lines without a partner, but the probe counts lines whose pair kept none of their ink too — verified in `history.rs` (`e2_whole`) and its own output line; report §9 and the ledger bullet now say both, and that the probe counts them together.
  - `[false]` `[reject]` (blind 7) No tests for a last line without `\n`, CRLF or the description block — `hunks.rs` `a_last_line_without_a_newline_keeps_it` drives an unpaired last line without `\n` through `pair_lines` and its assertion; a paired one uses the same `find_line_ranges` slices and `unzip_diff_hunks_to_lines`' split; `\r` is whitespace in both the scoring and the kept count; the description block goes through the same `hunks_of`.
  - `[low]` `[patch]` (blind 8) `sprint-status.yaml` still says Ralph decides whether to build 5.9, and the 5-9 entry has no outcome — Stufe 6 note and the 5-9 comment now state the build, its figures and Ralph's open decision.
  - `[low]` `[reject]` (blind 9) Nothing enforces the probe / product coupling (`#[path]`, the probe's own jj-lib pin, the pin-bump checklist) — a broken probe fails loudly on its next build; enforcing it means building the probe in the gate or editing agent context, not a direct correction; the module doc and the README already name the coupling and that an edit detaches the figures.
  - `[false]` `[reject]` (blind 10) The 80 % coverage floor for the new `line_pairs.rs` is unchecked and untracked — the coverage ratchet checks every new file whenever it runs, and `gate_plan.rs` maps `crates/zanshin-jj/` to the Rust group, so the loop's final gate and every later gate run check it.
  - `[low]` `[patch]` (blind 11) Names drift: "cap" vs "budget", and `epic-5-context.md`'s measurement bullet gives no E2 result — test renamed `a_block_over_the_budget_keeps_jj_libs_tokens`; the bullet now states E2's result, cost and the open decision. `a_context_line_is_one_equal_segment` keeps its name: its first assertions still check exactly that.
  - `[high]` `[patch]` (edge-case 1) Many medium blocks of short dissimilar lines prune every candidate and charge nothing (a reviewer's 519 KB file: 5.4 s against jj's 38 ms) — same root cause and fix as blind 1.
  - `[low]` `[patch]` (edge-case 2) `ran_out` is also true when a too-big block is skipped while the budget is intact, so "the budget ran out in 9 files" overstates — the flag means "a block kept jj-lib's tokens because the budget could not pay for it" (the test pins a later block still pairing); its doc and the probe's labels (`marks.rs`, `history.rs`, `limits.rs`, README) now say that.
  - `[low]` `[patch]` (edge-case 3) The wire-contract docs say "a huge block" / "over the pairing cap" — grouped with intent-alignment 1, same fix.
  - `[low]` `[reject]` (edge-case 4) The spec's Tasks line names `ink` while the code counts tokens — the fix edits this build's spec; the Design Notes and the Spec Change Log ("Similarity by tokens, not bytes") already state tokens.

## Design Notes

**Similarity** of a group (removed line(s) vs added line(s)): `2·kept / total`, counted in tokens. A token is one of jj-lib's word-diff tokens — a word from `find_word_ranges` or one non-word byte — that is not ASCII whitespace; each counts 1, whatever its length. `total` = the tokens of both sides; `kept` = the tokens inside the `Matching` hunks of `ContentDiff::by_word` on the group's texts (matching hunks are token-aligned, so their text is tokenized). Whitespace is left out so shared indentation and spaces do not make unrelated lines look alike; the measure is jj's own word diff, so it scores exactly what the marks will show. Tokens, not bytes: a changed identifier is one change whatever its length — `a.functionWizard_save,` → `a.functionWizard_next,` keeps 3 of 4 tokens a side (75 %) and pairs; by bytes it kept 14 % and stayed unpaired.

**Threshold and value:** `MIN_SIMILARITY_PERCENT = 50`. A group is worth `(similarity − 50 %) · total` = `200·kept − 50·total` (integer, ×100); the DP maximises the sum and an unpaired line is worth 0, so a group is taken only above half — "more of the two lines is shared than marked". On Ralph's example: old test vs tablet test 20 of 20 / 23 tokens kept ≈ 93 % (value 1,850), vs phone test 18 of 20 / 22 ≈ 86 % (1,500), the comments well below half (negative). The value penalises absorbing a loosely related line into a run (`foo(a,b)` vs `foo(a,c)` + `bar(x)`: 1:1 = 400 (5 kept of 12), run = 200 (5 kept of 16)).

**Runs:** one removed line vs `k` consecutive added lines (split) or `k` removed vs one added (join), `k ≤ MAX_RUN_LINES = 8`; ties keep the shorter group. The call-split witness is a 1:3 run whose diff equals today's block diff. No k:l groups (k, l > 1).

**Cost:** per cell up to `2·MAX_RUN_LINES − 1` candidates; a candidate's upper bound `200·min(tokensL, tokensR) − 50·(tokensL + tokensR)` skips the diff when it cannot beat the cell's best (the build adds a second bound: `kept` ≤ the tokens the group's lines share; it is an upper bound, so skipping never changes the result, see the Spec Change Log). Work cap `MAX_PAIRING_WORK` on `added_lines·removed_bytes + removed_lines·added_bytes` (the bytes the 1:1 candidates read); above it the block keeps today's tokens. (The build turns the cap into a per-file budget, see the Spec Change Log.) Starting value 1 MiB, then set from the probe: the cap must keep E2's per-file p99 within a few times jj's and the `limits` at-cap input under ~50 ms; the chosen value and its measurements go to Verification.

**Probe runtime:** one shell command may run at most 10 minutes, and `history` took about 7 minutes idle (one `difft` process per file). If that does not fit, add `--jobs N` to `history`: `difft` runs on N threads (only its marks are used; its times are then not comparable to the report's §2.1 and are not reported for that run), while jj's and E2's marks and times stay in-process and sequential. The comparison figures for today against `difft` must reproduce §6's (11.2 % drawn, 4.9 % word marks of the non-fallback lines) before E2's figures are trusted.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib hunks:: line_pairs::` -- expected: pass.
- `cargo test -p zanshin-jj --test it hunks::` -- expected: pass (line-level CLI checks unchanged).
- `cargo test -p zanshin-ffi --test it diff_ffi::` -- expected: pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean.
- `cargo make codegen` then `git diff --stat` -- expected: only comment changes in generated files.
- `cargo test -p zanshin-parity --test oracle` -- expected: pass (diff line parity).
- `dart test test/worker/diff_test.dart` in `packages/zanshin_core` (env as `[tasks.test-core]`); `dart analyze` / `dart format --set-exit-if-changed` there and in `app`; `flutter test test/features/graph/graph_real_repo_test.dart` in `app` -- expected: pass.
- Probe: `cargo build --release --offline`, `witness`, `history --rev 5ba5f5d43b21d45c24c099092384f9d9610fe009`, `limits`, then `cargo clean` -- expected: figures recorded below and in the README / report.

**Results (2026-11-12, build run):**
- All commands above pass: zanshin-jj lib 26 (`hunks::` + `line_pairs::`, rerun after the per-file budget), zanshin-jj `it` `hunks::` 15, zanshin-ffi `it` `diff_ffi::` 7, parity oracle 509, `diff_test.dart` 13, `graph_real_repo_test.dart` 2; clippy, rustfmt, `dart analyze` / `dart format` (zanshin_core, app) clean. `cargo make codegen`: generated files changed in comments only.
- Re-run by the orchestrating run after the review patches (2026-11-12): `cargo test -p zanshin-jj --lib -- hunks:: line_pairs::` 26 passed; `--test it hunks::` 15 passed; `cargo test -p zanshin-ffi --test it diff_ffi::` 7 passed; `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` clean; `cargo fmt --all --check` clean; `cargo test -p zanshin-parity --test oracle` 509 passed; `dart test test/worker/diff_test.dart` (zanshin_core, `[tasks.test-core]` env) 13 passed; `cargo make test-app test/features/graph/graph_real_repo_test.dart` 2 passed; `dart analyze --fatal-infos --fatal-warnings` and `dart format --set-exit-if-changed` clean in zanshin_core and app (Dart unchanged by the patches). No full gate (`cargo make test` / `test-full` / `coverage`), per the loop's gate rule; coverage of the new `line_pairs.rs` is not measured here.
- Measured file: `git hash-object crates/zanshin-jj/src/line_pairs.rs` = `15ddbd3902b9068efce3d7e4deee3a6e264183fa`; a later edit of that file needs a new probe run.
- **Budget: `MAX_PAIRING_WORK` = 262,144 bytes (256 KiB) per file**, on the bytes the scoring word diffs read. `limits`: `e2-at-cap` (63 × 63 lines, every pair sharing all tokens, so no bound skips a pair) 18.0 ms; `e2-reformatted-calls` (20 blocks of 28 one-line calls `f(a0, …, a5);`, reformatted to one argument per line; 3.15 s under the per-block cap) 21.2 ms, budget ran out. The slowest file measured is `scattered-changes` (2,000 small blocks that read little each) at 23.7 ms against jj's 16.5 ms: its cost grows with the file, as jj's does. History: the budget ran out in 9 of 2,536 files. E2 per file (pairing alone): median 0.0 / 0.1 ms, p90 0.5 / 0.5 ms, p99 3.0 / 3.4 ms, max 15.0 / 13.1 ms (Dart / Rust) against jj's 0.1 / 0.2, 0.5 / 0.7, 1.3 / 1.5, 3.4 / 2.9 ms — p99 2–3× jj's. Earlier settings, per-block cap: tokens, both bounds, 256 KiB: at-cap 17.6 ms, p99 3.1 / 3.3 ms, max 28.2 ms; bytes: p99 12.6 / 12.1 ms with only the size bound at 256 KiB, 11.5 / 10.2 ms at 64 KiB, 1.6 / 1.6 ms with both bounds; the first at-cap input took 99 ms at 1 MiB.
- **History** (`--jobs 8`; today's figures reproduce §6: 4,755 word / 10,812 drawn of 96,295): E2 against difft 5,148 (5.3 %) word / 10,332 (10.7 %) drawn; net change of today's gap −8.3 % word, 4.4 % drawn; 3,189 of E2's differing lines are whole-line marks. E2 against today: same word marks on 92.2 % of 115,515 lines, more 5.0 %, fewer 1.8 %, different 1.0 %.
- New `line_pairs` tests: an 8-line split and its mirror join keep precise marks; a 9-line split does not pair as one run; a tie keeps the shorter group; a hunk starting after line 0 with two blocks of unequal counts keeps each block's marks under `Exact` and `IgnoreAllSpace`; a spent budget leaves the block and every later one to jj-lib, and a block too big for what is left is skipped while a later small block still pairs.
- Witnesses: Ralph's example (his exact hunk) — 3 removed against 16 added; both comments whole-line; the old test pairs with the tablet test, which marks only ` on a tablet`; the phone test line one whole-line segment; the same word marks as difft on 19 of 19 lines (today 16). The expression row marks `s.functionWizard_save` / `saveLabel`, `functionWizard_save` / `functionWizard_next`, `1` / `2`. stepper.dart unchanged except the comment example's `padding` line, which no longer fills its indentation.

**Results (2026-11-12, follow-up review, after its patches):**
- `cargo test -p zanshin-jj --lib -- hunks:: line_pairs::` 26 passed (incl. the reworked `a_spent_budget_leaves_later_blocks_to_jj_lib`).
- `cargo test -p zanshin-jj --test it hunks::` 15 passed. A first run failed 14 of 15 with `Backend("Failed to write non-git metadata")`: the disk was full (122 MiB free) while another project's Flutter build ran; the rerun with 2.1 GiB free passed.
- `cargo test -p zanshin-ffi --test it diff_ffi::` 7 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` clean; `cargo fmt --all --check` clean; probe `cargo fmt --check` clean.
- `cargo make codegen`: `envelope_generated.rs` and `envelope_zanshin.ffi_generated.dart` changed in the `HunkLine` doc comment only; `zanshin_ffi.h` / `bindings.dart` unchanged.
- zanshin_core: `dart test test/worker/diff_test.dart` (`[tasks.test-core]` env) 13 passed; `dart analyze --fatal-infos --fatal-warnings` no issues; `dart format --set-exit-if-changed` on the two changed files clean.
- app: `cargo make test-app test/features/graph/graph_real_repo_test.dart` 2 passed (no app file changed).
- Not rerun: the parity oracle — no jj verb changed and the line-level hunks are untouched (the loop's gate rule runs it only when a verb changes).
- Probe (release, then `cargo clean`): measured file `git hash-object crates/zanshin-jj/src/line_pairs.rs` = `21d507ba73adb17d9836ca9f668ce416090f32ca`; the old file was measured from a copy of `15ddbd39` with the probe's `#[path]` pointed at it for one build (restored afterwards). `limits` `e2-pruned-blocks` (280,690 bytes a side): E2 371.8 ms before, 1.6 ms after (jj 14.0–14.5 ms); `e2-at-cap` (44 lines) 9.9 → 9.1 ms; `e2-reformatted-calls` 22.6 → 0.5 ms (its first block's table nearly fills the budget, so every block keeps jj's marks); slowest file `scattered-changes` 23.5 ms (jj 15.9 ms). `history --jobs 8`: today's figures unchanged (4,755 / 10,812 of 96,295); E2 against difft 5,150 word / 10,325 drawn, net change −8.3 % / +4.5 %, 3,199 whole-line; E2 against today same word marks on 92.4 %; the budget left a block to jj in 12 of 2,536 files (was 9); E2 per file p99 3.2 / 3.3 ms, max 7.2 / 10.1 ms (Dart / Rust). `witness`: every E2 mark equal to the E2 run's (only timing lines differ). Outputs in the probe README, "Re-run after the follow-up review".
- No full gate (`cargo make test` / `test-full` / `coverage`), per the loop's gate rule.

## Auto Run Result

Status: done. Blocking condition: none.

**Item 1 (Story 5.9's build, decided by Ralph 2026-11-12: option E2) — fixed in `a91fbdddd703ed8ddf8e0ca884e24022a1821538`.** E2 is built and measured. One decision stays with Ralph (deferred item 1): on real diffs E2 does not bring the word marks closer to difftastic.

**What changed:**
- `crates/zanshin-jj/src/line_pairs.rs` (new): `pair_lines` rewrites the word tokens of each changed block of jj-lib's `unified_diff_hunks`. It pairs removed and added lines in order by token similarity (above `MIN_SIMILARITY_PERCENT` = 50; 1:1, 1:k and k:1 groups with k ≤ `MAX_RUN_LINES` = 8), word-diffs each group with `ContentDiff::by_word`, gives a line without a partner one changed token, and stops at a per-file budget (`MAX_PAIRING_WORK` = 256 KiB of bytes read by the scoring diffs), after which blocks keep jj-lib's block-wide tokens. Imports only `jj_lib` and `std`, so the probe compiles the same file.
- `crates/zanshin-jj/src/hunks.rs`: calls `pair_lines` in `hunks_of`; `Segment` and module docs state the E2 rule; witness tests (Ralph's exact example, the stepper / 10.32 examples, `a` → `A`, `-b`). `lib.rs`: module declared.
- Tests with new expectations: `crates/zanshin-ffi/tests/it/diff_ffi.rs`, `packages/zanshin_core/test/worker/diff_test.dart`, `app/test/features/graph/graph_real_repo_test.dart`; comment only in `app/test/features/graph/inspector_diff_test.dart`.
- Docs reworded from 5.2's rule to E2's: `schemas/envelope.fbs` (then `cargo make codegen`: comment-only changes in `envelope_generated.rs`, `envelope_zanshin.ffi_generated.dart`, `zanshin_ffi.h`, `bindings.dart`), `crates/zanshin-ffi/src/diff.rs`, `docs/ffi-abi.md`, `packages/zanshin_core/lib/src/ffi/diff.dart`, `packages/zanshin_core/lib/src/worker/handle.dart`, `app/lib/src/features/graph/inspector_diff.dart`, `_bmad-output/project-context.md` (the word-diff rule), `epic-5-context.md`, `epic-10-context.md`.
- `app/widgetbook/folders/graph.dart`: `_DemoDetails` hunk 3 carries E2's segments.
- `spikes/structural-diff-probe/`: compiles `line_pairs.rs` via `#[path]`; E2 marks and time per line and file; `history --jobs N`, E2-against-difft tables, net change of today's gap, E2 against today, budget counts; `witness` with `e2` rows and Ralph's example as `widget-test-rename`; `limits` with E2 time and the `e2-at-cap` / `e2-reformatted-calls` inputs. README "Results of the E2 run" holds the outputs; `cargo clean` done.
- Research report: new German §9 (build, witnesses, real diffs, cost, open points); status line points to it.

**Figures** (probe at `5ba5f5d4`, `line_pairs.rs` blob `15ddbd39`): today's marks against difft reproduce §6 (4,755 word / 10,812 drawn of 96,295 lines). E2 against difft: 5,148 word / 10,332 drawn — net change of today's gap −8.3 % on word marks, +4.4 % drawn. E2 against today: same word marks on 92.2 % of 115,515 lines. Cost per file (pairing alone): p99 3.0 / 3.4 ms, max 15.0 / 13.1 ms (Dart / Rust) against jj's p99 1.3 / 1.5 ms; budget ran out in 9 of 2,536 files.

**Review** (first pass, 27 findings): patches applied — 2 high (one root cause: the per-block cap bounded neither runs nor files; now a per-file budget), 1 medium (tests for runs of 4–9 lines, ties, two blocks at an offset under `Exact` / `-w`, the budget), 6 low (the "exact bound" wording, stale epic contexts, `docs/ffi-abi.md` wrap, "net change" label, measured blob hash, lazy `find_line_ranges`). Deferred: 2 (E2's distance to difft — Ralph's decision; reflowed prose unmeasured). Rejected: 3 low (whitespace fill on the stepper comment example is the removed scatter; order-keeping is the intent's rule; one-line contract summaries point to the full rule), 7 false (see the triage log).

**Follow-up review recommended: true** — one high entry was patched (patched by verdict: high 2 rows / 1 entry, medium 1, low 6). Unverified risk: the per-file budget path in `pair_lines_within` / `pair_block` (early return when the budget runs out, a too-big block skipped without spending, the `ran_out` result) was added in the review round and is covered only by `a_spent_budget_leaves_later_blocks_to_jj_lib` and the probe's `limits` / `history` runs.

**Verification:** see `## Verification` (every listed command re-run after the review patches; all pass). No full gate, per the loop's gate rule.

**Residual risks:**
- Coverage of the new `line_pairs.rs` is not measured in this run; the loop's final gate checks the 80 % floor.
- No Marionette check of the catalogue's changed demo hunk (drawing code unchanged; `graph_real_repo_test.dart` covers the real cdylib path).
- Reflowed prose and `.md` / description diffs are not measured (deferred item 2).

### Follow-up review pass (2026-11-12)

Status: done. Blocking condition: none.

**Summary:** The named risk was real. The per-file budget paid only for the word diffs that score candidates, so a block whose candidates the bounds all prune built its table for free, and a file of many such blocks grew without limit (`e2-pruned-blocks`, 280 KB: 371.8 ms of pairing against jj's 14.5 ms). Each searched block now pays for its one-to-one candidates before its search; the same input takes 1.6 ms. Figures re-measured on the new blob `21d507ba`: they moved only slightly.

**Files changed:**
- `crates/zanshin-jj/src/line_pairs.rs` — `pair_lines_within` charges `block_work` before `pair_block`; `MAX_PAIRING_WORK`, module and `pair_lines` docs rewritten (the flag means "a block kept jj-lib's tokens because the budget could not pay for it"); `a_spent_budget_leaves_later_blocks_to_jj_lib` reworked to pin the charge; `a_block_over_the_cap_…` renamed `a_block_over_the_budget_keeps_jj_libs_tokens`.
- `schemas/envelope.fbs` (+ `cargo make codegen`: `envelope_generated.rs`, `envelope_zanshin.ffi_generated.dart`, comment only), `crates/zanshin-jj/src/hunks.rs` (`Segment` doc), `packages/zanshin_core/lib/src/ffi/diff.dart` (`HunkLine.segments` doc), `docs/ffi-abi.md` — one wording for the fallback: "a block the file's pairing budget cannot pay for".
- `spikes/structural-diff-probe/` — `limits` gained `e2-pruned-blocks` and resized `e2-at-cap` for the charged table; budget labels reworded (`marks.rs`, `history.rs`, `limits.rs`); README section "Re-run after the follow-up review" with the before / after table and the new outputs; `cargo clean` done.
- Research report §9 — budget mechanism, the whole-line attribution (unpaired or a group that kept none of the line's ink), the re-run figures, and the 1×1-block point under open point 1.
- `deferred-work.md` — the E2 bullet's whole-line wording and re-run figures; new section "Surfaced in the follow-up review of Story 5.9" (deferred item 3).
- `epic-5-context.md` — the measurement bullet states E2's result and the open decision. `sprint-status.yaml` — Stufe 6 note and the 5-9 entry state the build and Ralph's open decision.

**Review findings** (26; high 2, medium 2, low 13, false 8, maybe-false 1):
- Patched: 1 high entry (blind 1, edge-case 1: the budget now pays for the table); 5 low entries (the fallback wording in the contract docs — intent-alignment 1, verification-gap other, blind 2, edge-case 3; the `ran_out` meaning and the probe's labels — edge-case 2; the whole-line attribution — blind 6; sprint-status — blind 8; "cap" vs "budget" and epic-5's missing result — blind 11).
- Deferred: 1 new (blind 5: in a 1×1 block E2 can only lose word marks; deferred item 3, part of Ralph's decision on item 1). Carried, already deferred: intent-alignment 6 (item 1), intent-alignment 8 (item 2).
- Rejected: intent-alignment 2 (false: `30714877` is the loop's ledger close), 3 (false: the rows that equal jj's output are tested against it), 4 (false, carried), 5 (false: the assertion, `marked` and the parity oracle cover the line level), 7 (false, carried), 9 (low, carried: the one-line summaries point to the full rule), 10 (low, carried: the lost fill is the removed scatter); blind 3 (false: the counters cannot drift), 4 (low: logging the flag is more than a direct correction), 7 (false: the cases follow covered code), 9 (low: enforcing the probe coupling needs the gate or agent context), 10 (false: the ratchet checks every new file); edge-case 4 (low: the fix edits the spec; the notes already say tokens).

**Follow-up review recommended: true** — this pass patched a high entry (patched by verdict: high 1 entry, low 5). Unverified risk: the new charge bounds the table work only by argument — the shared-token table reads at most `block_work` bytes and the search visits at most about `block_work / 2` cells with up to 71 steps each, since every line has at least one byte — and the per-block tokenizing and the final word diff of each chosen group stay uncharged (bounded by the block's bytes). It is measured only on `e2-pruned-blocks`, `e2-at-cap`, `e2-reformatted-calls`, `scattered-changes` and the `history` corpus; whether 256 KiB is still the right size now that the table shares it (`e2-reformatted-calls` no longer pairs at all) is not settled.

**Verification:** see `## Verification`, "Results (2026-11-12, follow-up review, after its patches)": every targeted check passes; the parity oracle was not rerun (no jj verb changed). No full gate, per the loop's gate rule.

**Residual risks:**
- Coverage of `line_pairs.rs` is still unmeasured here; the loop's final gate checks the 80 % floor (the reworked budget test covers the new charge).
- Disk space ran out once during this pass (another project's build); the loop's final gate needs room for a full build.
