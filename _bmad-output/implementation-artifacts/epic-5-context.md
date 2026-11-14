# Epic 5 Context: `zanshin-diff` — Word-Diff + Syntax Highlight

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Epic 5 gives Zanshin a structured diff between any two revisions: files → hunks → lines → segments. Rust computes it and sends it to Dart as a FlatBuffers payload. It feeds the inspector diff view, hunk picking and selection-to-tree, so its lines must match the jj CLI. The title is historical: the `zanshin-diff` crate and syntax highlighting were removed on 2026-11-12. The lines are what `jj diff` prints with no `ui.diff-formatter` (the `:color-words` format, 5.10). A second "Zanshin" word-mark style (5.11, refined by 5.13, built on the `similar` crate) did not convince Ralph. Story 5.14 removes it: the diff shows jj's style only, and a Settings switch turns the word marks inside a line on or off. It also removes 5.12's Conflicts row.

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
- Story 5.11: A second diff style via `similar` (done; removed by 5.14)
- Story 5.12: Settings rows for jj's color-words keys (done; its Conflicts row removed by 5.14)
- Story 5.13: Finer tokens for the Zanshin style (done; removed by 5.14)
- Story 5.14: One diff style, jj's — a switch for the word marks, no Conflicts row (done)

## Requirements & Constraints

- **The diff behaves like the CLI's default diff** (jj 0.47.0, `cli/src/diff_util.rs`, `show_color_words_diff_hunks` and below). The parity oracle checks it against `jj diff --color=debug`; 5.14 leaves it and its expectations untouched. CLI parameters pass through (`--context`, `-w` / `-b`).
- **jj's config keys** come from the effective jj config on every diff call:

  | Key | Default | Meaning |
  |---|---|---|
  | `diff.color-words.context` | `3` | context lines around a change, integer ≥ 0 |
  | `diff.color-words.conflict` | `materialize` | a conflicted side as marker text, or `pair` (each pair of terms on its own) |
  | `diff.color-words.max-inline-alternation` | `3` | how often a line may switch sides and still show inline; `0` never, `-1` always |

  jj calls `conflict` and `max-inline-alternation` experimental. Config layers: built-in, user, repo, workspace, environment, command line; a later layer wins. After 5.14 the diff still follows `conflict` from the config, but no Settings row writes it.
- **Rust computes, Dart draws:** the UI never computes segments.
- **5.14 removes the Zanshin style completely:** `DiffMarks` (Rust, wire, Dart), the `Words` path in `hunks.rs` (`word_runs`, `side_runs`, rule 6, `WORD_MARKS_LIMIT`, their tests and docs), the `marks` option and reply field, `similar` (root and `zanshin-jj` `Cargo.toml`, `Cargo.lock`), `DiffMarksSetting` / `diffMarks`, its strings, catalogue and design-system parts. A search for `DiffMarks` / `DiffMarksSetting` must find nothing in code, schema or generated files.
- **The word-mark switch** is a new `bool` setting in `packages/zanshin_settings`, default `true`. A settings file that still holds `diffMarks` must load; the old key is ignored (`"diffMarks": "words"` loads with the switch on).
- **Non-goals across the epic:** syntax highlighting, tree-sitter or any parser, move detection, underline or strikethrough, a third style, the Zanshin style behind a flag, a setting for jj's colours (`colors."diff token"`), a quick toggle in the diff bar. Word-mark colours stay as built (10.32, 10.34) in night and paper.

## Technical Decisions

- **Where the code lives.** Only `zanshin-jj` imports jj-lib: the diff read is `crates/zanshin-jj/src/hunks.rs` (`Repo::diff(&DiffOptions)`, `compute_hunks`); the payload builder is `zanshin_ffi::diff::diff_to_envelope`. The PRD, the architecture doc and old story prose (`crates/zanshin-diff`, imara-diff, tree-sitter, JSON, NFR-P-3's 5k-line target) are superseded.
- **Line model (5.10).** A `HunkLine` has a kind (context, removed, added, changed, conflict header), optional left and right numbers as the CLI prints them, and segments (equal, removed, added). A `changed` line holds content of both sides. Lines, hunks, numbers, counts, sections and fingerprints of the jj path must not change: selections and Viewed marks are keyed by them.
- **Transport.** FlatBuffers (ADR-0001), `schemas/envelope.fbs`, regenerate with `cargo make codegen`, document in `docs/ffi-abi.md`. Schema changes follow `_bmad-output/project-context.md`.
- **Settings scopes (Story 11.7).** The General tab reads the user-level stack and writes `ConfigScope.user`. A row with a jj key carries it as `configKey`; a row without one (Layout, Changed words) is a Zanshin preference.
- **Docs.** The `DiffMarks::Words` paragraph of `_bmad-output/project-context.md` goes; `docs/` follows.
- **Tests** embed fixture text; they never read from `spikes/` or `../jj`. Settings tests live in `app/test/features/settings/` and use the neighbours' fakes.

## UX & Interaction Patterns

- **Settings › General › Diffs after 5.14:** Layout, Changed words, Inline changes, Context lines. "Changed words" is a switch, with a hint that it marks the words that changed inside a line, where `jj diff` underlines them. "Inline changes" keeps only its jj hint. No Conflicts row (its strings go, and `SettingsKeys.diffConflict` where only the row used it).
- **jj-key rows (5.12):** Context lines = select `0 1 2 3 5 10 20`; Inline changes = select Never (`0`), Up to 1/2/3/5, Always (`-1`). An effective number outside a list shows as its own chosen option. A choice always writes `jj config set --user NAME VALUE`; a failed write shows in the row's error line and keeps the old value. A write of a jj diff key, or a saved config-file page, reloads the inspector's focused diff and the Undo Timeline's operation view.
- **The switch acts at once and reloads nothing:** a diff loads without a style (`inspector_diff.dart`, `graph_inspector.dart`, `operation_changes.dart`). On: the marks as the jj style draws them today. Off: no word-mark fill on any line; on a `changed` line removed parts keep the removed hue and added parts the added hue as text colour (jj's colours without the underline), kept parts the line's ink; removed and added lines show only their line fill and ink.
- **Drawing basics (5.10):** unified rows show left number, right number, text; side by side rebuilds whole lines per side. Check both layouts.
- **Strings** live in `app/lib/l10n/app_en.arb` (plus generated files).
- **Catalogue:** "Inspector diff / Word marks" in `app/widgetbook/folders/graph.dart` shows the jj style with a knob for the switch; the Settings window use case follows.
- **Design system:** DiffHunk and DiffView prompts, the readme, the Content card (a hunk with the marks off) and the Settings page card (a switch row, no Conflicts row); republish with the `design-artifacts` skill and say so if the run cannot publish.
- **UI check:** catalogue and Marionette on the real app with a throwaway repo and its own `JJ_CONFIG` file (never Ralph's jj config), night and paper, compared with the DS cards.

## Cross-Story Dependencies

- 5.1 → 5.5 → 5.6 → 5.8 feed the inspector diff (10.24), hunk picking (10.26) and selection-to-tree (9.50).
- 5.10 replaced 5.9's line pairing. 5.14 depends on 5.10–5.13 (all done): it removes 5.11 and 5.13 (their specs stay as history) and 5.12's Conflicts row, and keeps 5.12's other rows (built on 11.7 and 11.19).
- 5.14's regression witnesses: the jj-style tests of 5.10 (Ralph's jj commit `671e4eaca`, `lib/src/git.rs`; the `stepper.dart` edits; the widget-test block), the conflict test with `pair`, and the parity oracle, all green with expectations untouched.
- 10.33 (ignore whitespace, backlog) reuses the `-w` / `-b` pass-through.
