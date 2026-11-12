# Epic 5 Context: `zanshin-diff` — Word-Diff + Syntax Highlight

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Epic 5 gives Zanshin a structured diff between any two revisions: files → hunks → lines → segments, computed in Rust and sent to Dart as a FlatBuffers payload. It feeds the inspector (diff view, word marks, hunk selection, selection-to-tree), so it must match the jj CLI. The title is historical: the `zanshin-diff` crate and syntax highlighting were removed on 2026-11-12. The line-level path and the word segments (jj-lib's own) are delivered. Only Story 5.9 is open. Its research (is a structural diff of the difftastic class worth building?) is done, and Ralph decided the build on 2026-11-12: option E2, which pairs removed and added lines before jj-lib's word diff, so a changed block's word marks stop scattering across unrelated lines.

## Stories

- Story 5.1: Line-level hunks via jj-lib (done)
- Story 5.2: Word-level diff (done; jj-lib's word diff since 2026-11-12)
- Story 5.3: tree-sitter-highlight integration (deleted 2026-11-12)
- Story 5.4: Bundle initial 3 grammars — Rust / Dart / Markdown (deleted 2026-11-12)
- Story 5.5: Diff FlatBuffers payload (done)
- Story 5.6: Diff between two revisions API (done)
- Story 5.7: 5k-line performance test (deleted)
- Story 5.8: FFI wrapper `zanshin-ffi/src/diff.rs` (done)
- Story 5.9: Structural diff, difftastic class — research first (in progress; research done, build E2 decided 2026-11-12, built in its closing run)

## Requirements & Constraints

- **Behave like the jj CLI.** Line-level hunks are the CLI's and stay so. CLI parameters pass through with the CLI's defaults: context lines (3) and the whitespace modes `-w` / `-b`.
- **Word segments: jj-lib's tokens on paired lines (E2, Ralph 2026-11-12).** 5.2 shipped jj-lib's own segments, which word-diff each changed block as one text with no line pairing — exactly what `jj diff --git` underlines. E2 lifts that rule: word marks are presentation. In each changed block, pair removed and added lines by similarity, keeping their order, with a minimum similarity. Word-diff each pair with jj-lib's own tokens (words are runs of `A-Z a-z 0-9 _` and non-ASCII bytes; every other byte is a token of its own). A line without a partner gets no word marks, only 10.32's faint fill. Line-level hunks stay the CLI's. Do not bring back the removed `imara-diff` / `unicode-segmentation` word diff.
- **No syntax highlighting (Ralph, 2026-11-12).** Its colors hide the red and green marks of the change. Diffs carry no syntax classes and no file language.
- **Output shape.** A segment has its text and a `kind` (Equal / Added / Removed). Context lines have no changed segment. Binary files carry no lines.
- **Rust computes, Dart draws:** the UI never computes or changes segments.
- **Robustness and speed.** Very long lines (minified code, 100k characters) must finish in reasonable time. NUL bytes, emoji and accented text must not panic. A 5k-line changed file in under 500 ms is a soft target, with no perf test and no CI gate.
- **Why E2.** jj-lib's `unified_diff_hunks` (`jj-lib-0.47.0/src/diff_presentation/unified.rs:230`) word-diffs all removed lines of a changed block against all its added lines, so common words ("the", "on a") match across unrelated lines. jj's color-words view guards against this with `diff.color-words.max-inline-alternation`; the git format has no guard. "Like difftastic" means rebuilding its look, not embedding difftastic. An own tree diff over tree-sitter comes later only if clear gaps remain.
- **E2 witnesses.** Ralph's widget-test example (3 removed lines against 16 added): both comments keep only the faint fill, and the renamed test marks only ` on a tablet`. Ralph's `stepper.dart` examples and 10.32's witnesses keep their marks, including the call split over three lines (only the new indentation and the comma). The move witness `f(a, b)` → `f(b, a)` is dropped: E2 detects no moves, and neither does difftastic.
- **E2 measurement.** The 5.9 probe (`spikes/structural-diff-probe/`) compares E2 with `difft` and with today's marks on the same 200 commits of this repository, and measures E2's cost per file. Today's jj word diff takes a median of 0.2–0.3 ms per file; `difft` takes 60–63 ms. Result (report §9): E2 meets the witnesses; on real diffs its drawn marks come net 4.5 % closer to difft's and its word marks net 8.3 % further away. Its pairing costs p99 3.2–3.3 ms and at most about 10 ms per file on those diffs (23.5 ms on the probe's synthetic file of 2,000 small blocks, where jj takes 15.9 ms), held by a per-file budget of 256 KiB that pays for each search's table and its word diffs. Keeping E2 or changing its rule is Ralph's open decision (deferred-work.md, "Surfaced in the closing run of Story 5.9").
- **5.9 research facts (2026-11-12).** Report `_bmad-output/planning-artifacts/research/technical-structural-diff-difftastic-class-research-2026-11-12.md`. difftastic 0.72.0 is a program only (no library); its JSON output needs `DFT_UNSTABLE=yes` and may change. It detects no moves: moved code and reordered arguments get the same marks as jj's. The options A–D in the report (A leave it, B `difft` as an external program, C a difftastic fork, D an own tree diff) are superseded by E2.
- **Dependencies.** Permissive licenses only (MIT project; no GPL, AGPL, LGPL or SSPL). Pin pre-1.0 crates exactly (`=x.y.z`). `default-features = false` needs a `# WHY:` comment.

## Technical Decisions

- **Where the code lives.** Only `zanshin-jj` imports jj-lib, so the diff read lives in `crates/zanshin-jj/src/hunks.rs` (`Repo::compute_hunks` takes two trees; `Repo::diff` serves revisions). `zanshin_jj::Hunk::segments` (index-aligned with `lines`) holds E2's tokens (`crates/zanshin-jj/src/line_pairs.rs`): pairs of similar removed and added lines take jj-lib's word diff per pair, a line without a partner is one changed segment, and once the file's pairing budget runs out a block keeps the block-wide tokens of jj-lib's `unified_diff_hunks`; `zanshin_ffi::diff::hunk_offset` writes them as `HunkLine.segments`. The payload builder is `zanshin_ffi::diff::diff_to_envelope` in `crates/zanshin-ffi/src/diff.rs`. Older planning prose (`crates/zanshin-diff/…`, `compute_diff`, `DiffOutput`, change-id inputs, imara-diff, tree-sitter, JSON) is superseded.
- **Line facts.** A hunk line is `Context`, `Removed` or `Added` and keeps its trailing `\n`; a missing one marks the end-of-file state. A conflicted file is diffed with its conflict materialized, as `jj diff` does. Summary mode returns files without hunks.
- **Transport.** FlatBuffers (ADR-0001), not JSON. `schemas/envelope.fbs` holds `Diff` → `FileDiff` → `Hunk` → `HunkLine` (+ `HunkLineKind`) → `Segment` (+ `SegmentKind`). Tests read through the typed accessors and the `Verifier`. Dart decodes in `packages/zanshin_core/lib/src/ffi/diff.dart` and calls `RepoHandle.diff` → `Future<Diff>` (extern `zanshin_diff`, a `DiffRequest` buffer in). No caching.
- **E2 keeps the wire:** the paired word segments still travel in `HunkLine.segments`; only which lines carry changed segments differs.
- **Languages and grammars.** 5.1's source-symbol port already maps file names to languages, as the CLI does; Dart has no symbol pattern there. The reverted 5.3/5.4 grammar setup (tree-sitter crates for Rust, Dart and Markdown) is in the git history: `revert(diff): remove syntax highlighting (Stories 5.3, 5.4)`.

## UX & Interaction Patterns

- **Word marks are drawn (10.32, decided by Ralph 2026-11-12).** A removed or added line keeps its faint fill. Its `Removed` / `Added` segments get a strong fill of the same hue (`--rem-word-bg` / `--add-word-bg`) with `--text` glyphs. Color is the only cue; there is no underline. Context lines and `Equal` segments stay plain. A line whose equal segments hold no visible character (an inserted line, a new or deleted file) gets no strong marks: its faint fill says it all. Unified and side by side alike.

## Cross-Story Dependencies

- The line-level path (5.1 → 5.5 → 5.6 → 5.8) feeds the inspector diff view (10.24), hunk selection (10.26), hunk drags (10.27) and selection-to-tree (9.50). Selections are keyed by 5.1's sections; a result pinned to an operation and commit id exposes a stale selection.
- 5.2's segments feed 10.32's word marks; the Undo Timeline's operation view (10.29) shows them too.
- 5.9 builds on 5.2's segments and 10.32's drawing (done 2026-11-12); Ralph decided E2 on real diffs in the app. E2 was built in 5.9's closing run: pairs of similar lines, jj-lib's word diff per pair, a line without a partner one changed segment, and over the file's pairing budget jj-lib's block-wide tokens.
- 10.33 (ignore whitespace, backlog) must check whether the word marks (5.2, 5.9) also ignore whitespace under `-b` / `-w`.
