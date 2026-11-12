# Epic 5 Context: `zanshin-diff` — Word-Diff + Syntax Highlight

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Epic 5 gives Zanshin a structured diff between any two revisions: files → hunks → lines → segments, computed in Rust and sent to Dart as a FlatBuffers payload. It feeds the inspector diff view, hunk selection and selection-to-tree, so it must match the jj CLI. The title is historical: the `zanshin-diff` crate and syntax highlighting were removed on 2026-11-12. The open story is 5.10 (Ralph, 2026-11-12): the diff becomes what `jj diff` prints with no `ui.diff-formatter`, the `:color-words` format. It replaces both the `jj diff --git`-style layout and Story 5.9's line pairing (E2), so no rule of Zanshin's own decides which words are marked.

## Stories

- Story 5.1: Line-level hunks via jj-lib (done)
- Story 5.2: Word-level diff (done; jj-lib's word diff since 2026-11-12)
- Story 5.3: tree-sitter-highlight integration (deleted 2026-11-12)
- Story 5.4: Bundle initial 3 grammars (deleted 2026-11-12)
- Story 5.5: Diff FlatBuffers payload (done)
- Story 5.6: Diff between two revisions API (done)
- Story 5.7: 5k-line performance test (deleted)
- Story 5.8: FFI wrapper `zanshin-ffi/src/diff.rs` (done)
- Story 5.9: Structural diff, difftastic class (done; its line pairing E2 is replaced by 5.10)
- Story 5.10: The diff is jj's default format, color-words (backlog, next)

## Requirements & Constraints

- **Behave like the jj CLI's default diff.** The lines, line numbers, token sides and texts equal the pinned `jj diff --color=debug` output (jj 0.47.0, `cli/src/diff_util.rs`, `show_color_words_diff_hunks` and below). Pass CLI parameters through: `--context`, `-w` / `-b`.
- **What the CLI does:**
  - Line diff: jj-lib's `diff_by_line` with the whitespace mode.
  - Context: `diff.color-words.context` (default 3; `--context` overrides) after a change and before the next. A longer unchanged range is skipped; a range exactly one line longer than the shown lines is shown whole. The skipped range's label is the source symbol.
  - Changed block: `ContentDiff::by_word` over the block's two texts. Inline (jj-lib's `DiffLineIterator`) when no group of changed lines switches between removed and added more often than `diff.color-words.max-inline-alternation` (default 3; `-1` always, `0` never). An inline line has a left number if it holds left content and a right number if it holds right content; one old line can spread over several lines. Otherwise `unzip_diff_hunks_to_lines`: the removed lines, then the added lines, with block-wide word marks. Zanshin follows the coloured path (the CLI never inlines without colour).
  - Under `-w` / `-b`, context lines whose sides differ go through the changed-block path, labelled context.
  - Conflicts: `diff.color-words.conflict` = `materialize` (default, diff the marker text) or `pair` (header lines `<<<<<<< Created/Resolved/Modified conflict`, `+++++++` / `-------` terms, `>>>>>>> Conflict ends`; roles swapped under `-------`).
  - All three `diff.color-words.*` keys come from the effective jj config.
- **Non-goals:** reading `ui.diff-formatter` (delta, difft are terminal output; the `:git` layout goes away); own word-mark rules, move detection, syntax colours; underline or strikethrough; the ignore-whitespace switch (10.33) and a settings UI for the `diff.color-words.*` keys.
- **No syntax highlighting (Ralph, 2026-11-12):** its colours hide the change marks. No syntax classes, no file language on the wire.
- **Rust computes, Dart draws:** the UI never computes segments.
- **Robustness and speed:** long lines (100k characters), NUL bytes, emoji and accents must not panic or stall. A 5k-line file in under 500 ms is a soft target, no perf gate.
- **Dependencies:** permissive licences only; pin pre-1.0 crates exactly (`=x.y.z`).

## Technical Decisions

- **Where the code lives.** Only `zanshin-jj` imports jj-lib, so the diff read is `crates/zanshin-jj/src/hunks.rs` (`Repo::compute_hunks` takes two trees; `Repo::diff(&DiffOptions)` serves `-r` and from/to). The payload builder is `zanshin_ffi::diff::diff_to_envelope` (`crates/zanshin-ffi/src/diff.rs`). Older prose (`crates/zanshin-diff`, `compute_diff`, imara-diff, tree-sitter, JSON) is superseded.
- **5.10's data model.** A `HunkLine` has a kind (context, removed, added, changed, conflict header), an optional left and right line number as the CLI prints them, and segments (equal, removed, added). A changed line holds content of both sides. A `Hunk` is the run of lines between two skipped ranges; its ranges, symbol, sections and counts keep their meaning; `removed` / `added` count the left and right lines of its changed blocks. `context: None` means the effective `diff.color-words.context` (was `diff.git.context`).
- **Unchanged in meaning:** file kinds, binary and mode-only rules, copy and rename reading, sections (selection keys from the builtin diff editor), fingerprints, the description block, summary mode, `compute_hunks`.
- **Removed:** `crates/zanshin-jj/src/line_pairs.rs` (E2) with everything only it uses, its `coverage-baseline.txt` line included.
- **Transport.** FlatBuffers (ADR-0001): `schemas/envelope.fbs` `Diff` → `FileDiff` → `Hunk` → `HunkLine` → `Segment`; regenerate with `cargo make codegen`; update `packages/zanshin_core` (`lib/src/ffi/diff.dart`, `RepoHandle.diff` → `Future<Diff>`, extern `zanshin_diff` with a `DiffRequest` buffer) and `docs/ffi-abi.md`. No caching.
- **Parity oracle.** `crates/zanshin-parity/tests/oracle/` compares the pinned CLI's `--color=debug` output with Zanshin's lines on the witnesses, also with `max-inline-alternation` at `0` and `-1`, `--context 1` and `-w`.
- **Docs:** every place that calls the diff `jj diff --git`'s (project-context.md, code docs) must say color-words.

## UX & Interaction Patterns

- **Unified layout** (`app/lib/src/features/graph/inspector_diff.dart`; the Undo Timeline's operation view reuses it): one row per line with left number, right number, text. Numbers replace the sigil column and stay outside the selection.
- **Looks** (today's tokens, no underline): context = faint numbers, muted text. Removed = left number in `--rem`, `--rem-bg` fill, changed words on `--rem-word-bg`; added likewise in green. Changed line = both numbers in colour, no fill, `--text` ink, removed words on `--rem-word-bg`, added words on `--add-word-bg`.
- **Word marks:** a removed or added line whose unchanged text has no visible character keeps only its fill (10.32's rule); a changed line always draws its marks.
- **Side by side:** whole lines per side, rebuilt from the same lines (the left cell joins equal + removed segments of lines sharing a left number, the right cell equal + added of lines sharing a right number); inside a run of changed lines cells pair row by row; each cell shows its number.
- Hunk header stays (range, symbol, counts, 10.26's picking checkbox). Conflict header lines: mono, `--text-dim`, no numbers. The `\ No newline at end of file` marker stays.
- **Design system:** `design_system/components/content/` (DiffHunk, DiffView, Content card, bundle copies) shows numbers and the changed line; republish via the `design-artifacts` skill. Catalogue demo (`app/widgetbook/folders/graph.dart`): a simple block, a block over the limit, context lines.

## Cross-Story Dependencies

- 5.1 → 5.5 → 5.6 → 5.8 feed the inspector diff (10.24), hunk picking (10.26), hunk drags (10.27) and selection-to-tree (9.50); selections are keyed by 5.1's sections, so sections must not change.
- 5.10 depends on 10.24, 10.26 and 10.32 (word-mark drawing and tokens); it replaces 5.9's E2.
- Witnesses come from Ralph's examples: jj commit `671e4eaca` (`lib/src/git.rs`, `write_locked_index`, embedded as fixture text), the `stepper.dart` edits (10.32's demo data), and the widget-test block of 3 removed + 16 added lines (5.9's decision note), which stays over the limit.
- 10.33 (ignore whitespace, backlog) reuses the `-w` / `-b` pass-through.
