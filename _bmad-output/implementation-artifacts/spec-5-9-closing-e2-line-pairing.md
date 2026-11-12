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
