# Epic 5 Context: `zanshin-diff` — Word-Diff + Syntax Highlight

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Epic 5 gives Zanshin a structured diff between any two revisions: files → hunks → lines → segments. Rust computes it and sends it to Dart as a FlatBuffers payload. It feeds the inspector diff view, hunk picking and selection-to-tree, so its lines must match the jj CLI. The title is historical: the `zanshin-diff` crate and syntax highlighting were removed on 2026-11-12. The lines are what `jj diff` prints with no `ui.diff-formatter` (the `:color-words` format, 5.10). Two word-mark styles sit on those lines, switchable in Settings: "jj" (the CLI's marks) and "Zanshin" (built on the `similar` crate, 5.11, the app default). Story 5.12 put jj's three `diff.color-words` keys into Settings › General. Story 5.13 gives the Zanshin style finer tokens, so a mark covers only the changed part of a line, and shows one line replaced by one line as one line.

## Stories

- Story 5.1: Line-level hunks via jj-lib (done)
- Story 5.2: Word-level diff (done; jj-lib's word diff since 2026-11-12)
- Story 5.3: tree-sitter-highlight integration (deleted)
- Story 5.4: Bundle initial 3 grammars (deleted)
- Story 5.5: Diff FlatBuffers payload (done)
- Story 5.6: Diff between two revisions API (done)
- Story 5.7: 5k-line performance test (deleted)
- Story 5.8: FFI wrapper `zanshin-ffi/src/diff.rs` (done)
- Story 5.9: Structural diff, difftastic class (done; its line pairing replaced by 5.10)
- Story 5.10: The diff is jj's default format, color-words (done)
- Story 5.11: A second diff style via `similar`, switchable in Settings (done)
- Story 5.12: Settings rows for jj's three color-words keys; the Zanshin style names `similar` (done)
- Story 5.13: Finer tokens for the Zanshin style; a one-line change is one line (done)

## Requirements & Constraints

- **The jj style behaves like the CLI's default diff** (jj 0.47.0, `cli/src/diff_util.rs`, `show_color_words_diff_hunks` and below); the parity oracle checks it against `jj diff --color=debug` and stays unchanged. CLI parameters pass through (`--context`, `-w` / `-b`).
- **The three config keys** come from the effective jj config on every diff call:

  | Key | Default | Meaning | Applies to |
  |---|---|---|---|
  | `diff.color-words.context` | `3` | context lines around a change, integer ≥ 0 | both styles |
  | `diff.color-words.conflict` | `materialize` | a conflicted side as marker text, or `pair` (each pair of terms on its own) | both styles |
  | `diff.color-words.max-inline-alternation` | `3` | how often a line may switch sides and still show inline; `0` never, `-1` always | jj style; since 5.13 also the Zanshin style, for a block of one old and one new line |

  jj calls `conflict` and `max-inline-alternation` experimental. jj's config layers: built-in, user, repo, workspace, environment, command line; a later layer wins.
- **Both styles give the same fingerprint, sections, hunk ranges, counts, line numbers and line texts**, merged lines included, so a Viewed mark and a hunk selection survive a style switch. Only the word marks (and, after 5.13, the merging of a one-line block) differ.
- **Zanshin style basics (5.11, kept by 5.13):** jj supplies the lines; `similar` decides only the marks inside one changed block. A block with lines on one side only carries no marks. A fixed size limit per block (`WORD_MARKS_LIMIT`, measured so the worst shape stays within about 50 ms on the M4 Pro) leaves bigger blocks unmarked; no time-based cut-off. Removed lines come first, then added lines.
- **5.13 changes:** tokens are a run of blanks, a run of word characters (`char::is_alphanumeric` or `_`), or any other single character; Myers over the token lists; a run of changed tokens shifts right; indentation, trailing blanks and line breaks are never marked; the size limit is measured again. A block of exactly one old and one new line becomes one `changed` line with exact segments when it fits the limit, both lines have equal indentation and trailing blanks, and its alternation count is within `max-inline-alternation`.
- **Rust computes, Dart draws:** the UI never computes segments.
- **Non-goals across the epic:** syntax highlighting, tree-sitter or any parser, language-aware tokens, move detection, underline or strikethrough, a port of IntelliJ's diff, a third style or a token-fineness setting. Word-mark colours stay as built (10.32, 10.34) in night and paper, both styles. 5.13 leaves the jj style, lines, hunks and colours untouched and does not merge blocks with several lines on a side.

## Technical Decisions

- **Where the code lives.** Only `zanshin-jj` imports jj-lib: the diff read is `crates/zanshin-jj/src/hunks.rs` (`Repo::diff(&DiffOptions)`, `compute_hunks`); the payload builder is `zanshin_ffi::diff::diff_to_envelope`. The PRD, the architecture doc and old story prose (`crates/zanshin-diff`, imara-diff, tree-sitter, JSON, NFR-P-3's 5k-line target) are superseded.
- **Styles.** `DiffMarks { Jj, Words }` in Rust, on the wire (absent = `Jj`) and in `zanshin_core`; the result says which style its lines have. App setting `GeneralSettings.diffMarks`, default `words` ("Zanshin"). The Rust and FFI default stays `Jj`.
- **`similar`** is a plain crates.io dependency (3.2.1, Apache-2.0), no fork; its features in the root `Cargo.toml` match what the code uses.
- **Transport.** FlatBuffers (ADR-0001), `schemas/envelope.fbs`, regenerate with `cargo make codegen`, document in `docs/ffi-abi.md`.
- **Wording (5.13).** No description of the Zanshin style says "whole words": schema, FFI and `zanshin_core` docs, `GeneralSettings`, `docs/ffi-abi.md`, `_bmad-output/project-context.md`, the hint and the design system.
- **Settings scopes (Story 11.7).** The General tab reads the user-level stack and writes `ConfigScope.user`; the Project tab reads the workspace's stack and writes `ConfigScope.repo`. A row carries its jj key (`configKey`), which tells a jj row from a Zanshin preference.
- **No Rust change makes a new key value count:** the open diff only has to load again.
- **Tests** embed fixture text; they never read from `spikes/` or `../jj`. Settings tests live in `app/test/features/settings/` and use the neighbours' fakes.

## UX & Interaction Patterns

- **Settings › General › Diffs rows, in order:** Layout, Changed words, Inline changes, Context lines, Conflicts. Since 5.13 "Inline changes" shows in both styles, with one hint per style.
- **Controls (existing ones only):** Context lines = select `0 1 2 3 5 10 20`; Inline changes = select Never (`0`), Up to 1/2/3/5, Always (`-1`); Conflicts = segmented "As markers" / "In pairs". An effective number outside a list shows as its own chosen option.
- **A choice always writes** `jj config set --user NAME VALUE`. A failed write shows in the row's error line and the row keeps the old value. A write of one of the three keys, or a saved config-file page, reloads the inspector's focused diff and the Undo Timeline's operation view at once.
- **Strings** live in `app/lib/l10n/app_en.arb`. The Zanshin hint after 5.13: "Marks the changed part of each line, using the similar library. Removed lines come first."
- **Drawing** (`app/lib/src/features/graph/inspector_diff.dart`, shared with the operation view): draws by the style the lines were loaded with, not the current setting, and a `changed` line by its kind in both styles. Check a merged line in the unified and the side-by-side layout.
- **Catalogue:** "Inspector diff / Word marks" in `app/widgetbook/folders/graph.dart`, built from lines the Rust tests pin.
- **Design system:** `DiffHunk.prompt.md`, `DiffView.prompt.md`, the readme and the Content card show the Zanshin style; republish with the `design-artifacts` skill.
- **UI check:** Marionette on the real app with a throwaway repo and its own `JJ_CONFIG` file (never Ralph's jj config), night and paper, compared with the DS card.

## Cross-Story Dependencies

- 5.1 → 5.5 → 5.6 → 5.8 feed the inspector diff (10.24), hunk picking (10.26) and selection-to-tree (9.50); selections are keyed by 5.1's sections, so sections must not change.
- 5.10 replaced 5.9's line pairing; 5.11 adds to 5.10; 5.12 builds on 5.10, 5.11, 11.7 and 11.19; 5.13 replaces rules 2 and 5 of 5.11's Zanshin style, lifts its rule 3 for one-line blocks, and builds on 5.12's "Inline changes" row. All are done.
- Witnesses come from Ralph's examples: jj commits `671e4eaca` and `9346978d` (`lib/src/git.rs`), the `stepper.dart` edits, the widget-test block (3 removed + 16 added lines), and the reformat, nesting and reorder inputs of the 5.9 probe (copied into tests as fixture text).
- 10.33 (ignore whitespace, backlog) reuses the `-w` / `-b` pass-through.
