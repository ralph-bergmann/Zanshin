# Epic 5 Context: `zanshin-diff` — Word-Diff + Syntax Highlight

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Epic 5 gives Zanshin a structured diff between any two revisions: files → hunks → lines → segments. Rust computes it and sends it to Dart as a FlatBuffers payload. It feeds the inspector diff view, hunk picking and selection-to-tree, so its lines must match the jj CLI. The title is historical: the `zanshin-diff` crate and syntax highlighting were removed on 2026-11-12. Story 5.10 (done) made the diff what `jj diff` prints with no `ui.diff-formatter`, the `:color-words` format. Story 5.11 (Ralph, 2026-11-12) adds a second word-mark style next to it, built on the `similar` crate and switchable in Settings. The lines stay jj's in both styles; only the word marks inside a changed block differ.

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
- Story 5.10: The diff is jj's default format, color-words (done)
- Story 5.11: A second diff style — whole-word marks by the longest common run (`similar`), switchable in Settings

## Requirements & Constraints

- **The jj style behaves like the CLI's default diff.** Lines, line numbers, token sides and texts equal the pinned `jj diff --color=debug` output (jj 0.47.0, `cli/src/diff_util.rs`, `show_color_words_diff_hunks` and below). Pass CLI parameters through: `--context`, `-w` / `-b`.
- **What the CLI does:**
  - Line diff: jj-lib's `diff_by_line` with the whitespace mode.
  - Context: `diff.color-words.context` (default 3; `--context` overrides). A longer unchanged range is skipped; a range exactly one line longer than the shown lines is shown whole. The skipped range's label is the source symbol.
  - Changed block: `ContentDiff::by_word` over the block's two texts. Inline (`DiffLineIterator`) when no group switches between removed and added more often than `diff.color-words.max-inline-alternation` (default 3; `-1` always, `0` never); otherwise `unzip_diff_hunks_to_lines` (removed lines, then added lines). Zanshin follows the coloured path.
  - Under `-w` / `-b`, context lines whose sides differ go through the changed-block path, labelled context.
  - Conflicts: `diff.color-words.conflict` = `materialize` (default) or `pair` (header lines, roles swapped under `-------`).
  - All `diff.color-words.*` keys come from the effective jj config.
- **The second style (5.11), per changed block of jj's line diff:**
  - A block with lines on one side only carries no word marks.
  - Otherwise the joined removed lines and the joined added lines go through `similar`'s `TextDiff::from_words` (Myers). A token is a run of non-blanks or a run of blanks.
  - The block's lines are all removed lines (left numbers), then all added lines (right numbers); the kind `changed` does not occur.
  - Deleted words are `Removed`, inserted words `Added`, the rest `Equal`. A marked blank run only between two marked words on the same line; never indentation, trailing blanks or line breaks.
  - A fixed size limit per block (no time cut-off): above it, no word marks. Pick it by measuring the worst case (no common word) to stay within about 50 ms, and record the measurement in the spec.
  - `max-inline-alternation` has no effect; `context` and `conflict` apply to both styles.
- **Both styles give the same fingerprint, sections, hunk ranges, counts, line numbers and line texts,** so a Viewed mark and a hunk selection survive a switch.
- **Non-goals:** reading `ui.diff-formatter`; own word-mark rules in the jj style; move detection; syntax colours; underline or strikethrough; `similar`'s line diff, a fork, or its `inline` / `unicode` features; a style switch per file or hunk; the ignore-whitespace switch (10.33); a settings UI for `diff.color-words.*`.
- **No syntax highlighting (Ralph, 2026-11-12).**
- **Rust computes, Dart draws:** the UI never computes segments.
- **Robustness:** long lines (100k characters), NUL bytes, emoji and accents must not panic or stall.
- **Dependencies:** permissive licences only; pin exactly (`similar` 3.2.1, Apache-2.0); `cargo deny` stays green.

## Technical Decisions

- **Where the code lives.** Only `zanshin-jj` imports jj-lib: the diff read is `crates/zanshin-jj/src/hunks.rs` (`Repo::compute_hunks`, `Repo::diff(&DiffOptions)`). The payload builder is `zanshin_ffi::diff::diff_to_envelope`. Older prose (`crates/zanshin-diff`, imara-diff, tree-sitter, JSON) is superseded.
- **Data model.** A `HunkLine` has a kind (context, removed, added, changed, conflict header), optional left and right numbers, and segments (equal, removed, added). A `Hunk` is the run of lines between two skipped ranges. `context: None` means the effective `diff.color-words.context`.
- **The style option (5.11).** `DiffMarks { Jj, Words }` in Rust, on the wire and in `zanshin_core`. `DiffOptions` and `HunksOptions` gain it; the Rust and FFI default is `Jj` (a caller that says nothing gets the CLI's lines). Only the step that turns one changed block into lines and segments gets a second implementation; everything around it is shared. The diff result says which style its lines have.
- **Transport.** FlatBuffers (ADR-0001): `schemas/envelope.fbs` (5.11 adds an enum and a request field, absent = jj); regenerate with `cargo make codegen`; update `packages/zanshin_core` (`ffi/diff.dart`, the worker's command, handle and isolate) and `docs/ffi-abi.md`. No caching.
- **Settings.** `GeneralSettings.diffMarks` in `packages/zanshin_settings`, app default the second style; an unknown stored value falls back to the default.
- **Parity oracle** (`crates/zanshin-parity/tests/oracle/`) checks the jj style only and stays unchanged by 5.11.
- **Tests** embed fixture text; they never read from `spikes/`.
- **Docs:** `_bmad-output/project-context.md` and the `hunks.rs` docs say the diff has two styles; jj parity holds for the jj style and for the lines of both.

## UX & Interaction Patterns

- **Unified layout** (`app/lib/src/features/graph/inspector_diff.dart`; the Undo Timeline's operation view reuses it): one row per line with left number, right number, text; numbers stay outside the selection.
- **Looks** (today's tokens, 10.32 / 10.34, no underline): context = faint numbers, muted text; removed / added = coloured number, line fill, word marks on `--rem-word-bg` / `--add-word-bg`; changed line (jj style) = both numbers in colour, no fill.
- **Word marks:** the view draws by the style its lines were loaded with, not the current setting. jj style: 10.32's fill-only rule stays. Second style: a mark is drawn exactly where a segment says so; the fill-only rule does not apply.
- **Side by side:** whole lines per side, rebuilt from the same lines.
- **Settings › General** (`general_tab.dart`): a row "Changed words" below the diff layout, segments "Zanshin" and "jj", one explaining line per choice. Strings live with the neighbours'.
- **Loads:** the inspector (`graph_ports.dart`, `graph_inspector.dart`) and the operation view (`operation_changes.dart`) pass the setting; a change reloads the open diff.
- **Design system:** `design_system/components/content/` (DiffHunk, DiffView prompts, readme, Content card) names both styles; republish via the `design-artifacts` skill and say so if the run cannot publish. Catalogue (`app/widgetbook/folders/graph.dart`): a use case "Inspector diff / Word marks" with the jj example block and the widget-test block in both styles, from lines the Rust tests pin.

## Cross-Story Dependencies

- 5.1 → 5.5 → 5.6 → 5.8 feed the inspector diff (10.24), hunk picking (10.26), hunk drags (10.27) and selection-to-tree (9.50); selections are keyed by 5.1's sections, so sections must not change.
- 5.10 depends on 10.24, 10.26, 10.32 and replaces 5.9's E2. 5.11 adds to 5.10 (removes nothing) and depends on 5.10, 10.24, 10.26, 10.32, 10.34 (all done).
- Witnesses come from Ralph's examples: jj commit `671e4eaca` (`lib/src/git.rs`, `write_locked_index`), the `stepper.dart` edits (10.32's demo data) and the widget-test block of 3 removed + 16 added lines (5.9's note; in the second style the old `testWidgets(` line pairs with new line 23, marking only `step on a tablet',`).
- 10.33 (ignore whitespace, backlog) reuses the `-w` / `-b` pass-through.
