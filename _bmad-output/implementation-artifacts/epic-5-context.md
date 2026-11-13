# Epic 5 Context: `zanshin-diff` — Word-Diff + Syntax Highlight

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Epic 5 gives Zanshin a structured diff between any two revisions: files → hunks → lines → segments. Rust computes it and sends it to Dart as a FlatBuffers payload. It feeds the inspector diff view, hunk picking and selection-to-tree, so its lines must match the jj CLI. The title is historical: the `zanshin-diff` crate and syntax highlighting were removed on 2026-11-12. The diff is what `jj diff` prints with no `ui.diff-formatter` (the `:color-words` format, 5.10), with a second word-mark style built on the `similar` crate (5.11), switchable in Settings. Story 5.12 makes jj's three `diff.color-words` keys editable in Settings › General and names `similar` in the Zanshin style's hint.

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
- Story 5.11: A second diff style — whole-word marks via `similar`, switchable in Settings (done)
- Story 5.12: Settings rows for jj's three color-words keys; the Zanshin style names `similar`

## Requirements & Constraints

- **The jj style behaves like the CLI's default diff** (jj 0.47.0, `cli/src/diff_util.rs`, `show_color_words_diff_hunks` and below); the parity oracle checks it against `jj diff --color=debug`. CLI parameters pass through (`--context`, `-w` / `-b`).
- **The three config keys** come from the effective jj config on every diff call:

  | Key | Default | Meaning | Applies to |
  |---|---|---|---|
  | `diff.color-words.context` | `3` | context lines around a change, integer ≥ 0 | both styles |
  | `diff.color-words.conflict` | `materialize` | a conflicted side as marker text, or `pair` (each pair of terms on its own) | both styles |
  | `diff.color-words.max-inline-alternation` | `3` | how often a line may switch sides and still show inline; `0` never, `-1` always | jj style only |

  jj calls `conflict` and `max-inline-alternation` experimental. jj's config layers: built-in, user, repo, workspace, environment, command line; a later layer wins.
- **Both styles give the same fingerprint, sections, hunk ranges, counts, line numbers and line texts**, so a Viewed mark and a hunk selection survive a style switch. Only the word marks inside a changed block differ.
- **Rust computes, Dart draws:** the UI never computes segments.
- **No syntax highlighting, no underline or strikethrough, no move detection** (Ralph). Word-mark colours stay as built (10.32, 10.34) in night and paper, both styles.
- **5.12 non-goals:** rows in the Project tab or a layer choice per row; unsetting a key from a row; free number entry; other diff keys (`diff.git.context`, `ui.diff-formatter`, `ui.conflict-marker-style`); design-system or click-dummy changes; changes to colours or the diff itself.
- **5.12 expects no change** to Rust, the FFI, `packages/zanshin_core` or `packages/zanshin_settings`. Exception: if `config_set` cannot write `-1`, `0` or `pair` so that the diff reads it back, fix that at its cause, with a test.

## Technical Decisions

- **Where the code lives.** Only `zanshin-jj` imports jj-lib: the diff read is `crates/zanshin-jj/src/hunks.rs` (`Repo::diff(&DiffOptions)`, `compute_hunks`); the payload builder is `zanshin_ffi::diff::diff_to_envelope`. Older prose (`crates/zanshin-diff`, imara-diff, tree-sitter, JSON) is superseded.
- **Styles.** `DiffMarks { Jj, Words }` in Rust, on the wire (absent = `Jj`) and in `zanshin_core`; the result says which style its lines have. App setting `GeneralSettings.diffMarks`, default `words` ("Zanshin").
- **Transport.** FlatBuffers (ADR-0001), `schemas/envelope.fbs`, regenerate with `cargo make codegen`, document in `docs/ffi-abi.md`.
- **Settings scopes (Story 11.7).** The General tab reads the user-level stack (`configList` without a workspace) and writes `ConfigScope.user`; the Project tab reads the workspace's stack and writes `ConfigScope.repo`. The Identity rows are the pattern: a row carries its jj key (`configKey`), which tells a jj row from a Zanshin preference.
- **No Rust change makes a new key value count:** the open diff only has to load again.
- **Tests** embed fixture text; they never read from `spikes/`. Settings tests live in `app/test/features/settings/` and use the neighbours' fakes.

## UX & Interaction Patterns

- **Settings › General › Diffs rows, in order:** Layout, Changed words, Inline changes (only while "jj" is chosen), Context lines, Conflicts.
- **Controls (existing ones only):** Context lines = select `0 1 2 3 5 10 20`; Inline changes = select Never (`0`), Up to 1/2/3/5, Always (`-1`); Conflicts = segmented "As markers" (`materialize`) / "In pairs" (`pair`). An effective number outside a list shows as its own chosen option, in order.
- **A choice always writes** `jj config set --user NAME VALUE`, also when it equals jj's default. A failed write shows in the row's error line (`errors[key]`) and the row keeps the old value. A value jj cannot read shows raw in the error line; a choice overwrites it.
- **Source notes:** no note for a default or user value; the existing "From ‹scope› config" note for another user-level layer (environment, system); "The open project sets its own value." when the open project's repo or workspace config sets the key.
- **Reload:** a write of one of the three keys, or a saved config-file page (`configFileSaved`), reloads the inspector's focused diff and the Undo Timeline's operation view at once, as a "Changed words" change already does.
- **Strings** in `app/lib/l10n/app_en.arb` with the neighbours'; identifiers `settings-diff-context`, `settings-diff-inline`, `settings-diff-conflict`. The epic fixes the hint texts; the Zanshin hint names the `similar` library.
- **Drawing** (`app/lib/src/features/graph/inspector_diff.dart`, shared with the operation view): draws by the style the lines were loaded with, not the current setting.
- **UI check:** Marionette on the real app with a throwaway repo and its own `JJ_CONFIG` file, never Ralph's jj config.

## Cross-Story Dependencies

- 5.1 → 5.5 → 5.6 → 5.8 feed the inspector diff (10.24), hunk picking (10.26) and selection-to-tree (9.50); selections are keyed by 5.1's sections, so sections must not change.
- 5.10 replaced 5.9's line pairing; 5.11 adds to 5.10; 5.12 builds on 5.10, 5.11, 11.7 (Settings scopes) and 11.19 (all done).
- Witnesses come from Ralph's examples: jj commit `671e4eaca` (`lib/src/git.rs`, `write_locked_index`), the `stepper.dart` edits and the widget-test block (3 removed + 16 added lines).
- 10.33 (ignore whitespace, backlog) reuses the `-w` / `-b` pass-through.
