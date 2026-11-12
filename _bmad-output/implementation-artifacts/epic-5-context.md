# Epic 5 Context: `zanshin-diff` — Word-Diff + Syntax Highlight

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Epic 5 gives Zanshin a structured diff between any two revisions: files → hunks → lines → segments, computed in Rust and sent to Dart as a FlatBuffers payload. It feeds the inspector (diff view, word marks, hunk selection, selection-to-tree), so it must match the jj CLI. The title is historical: the `zanshin-diff` crate and syntax highlighting were removed on 2026-11-12. The line-level path and the word segments (jj-lib's own) are delivered. Only Story 5.9 is open: its research (is a structural diff of the difftastic class worth building?) is done since 2026-11-12, and Ralph decides on the build.

## Stories

- Story 5.1: Line-level hunks via jj-lib (done)
- Story 5.2: Word-level diff (done; jj-lib's word diff since 2026-11-12)
- Story 5.3: tree-sitter-highlight integration (deleted 2026-11-12)
- Story 5.4: Bundle initial 3 grammars — Rust / Dart / Markdown (deleted 2026-11-12)
- Story 5.5: Diff FlatBuffers payload (done)
- Story 5.6: Diff between two revisions API (done)
- Story 5.7: 5k-line performance test (deleted)
- Story 5.8: FFI wrapper `zanshin-ffi/src/diff.rs` (done)
- Story 5.9: Structural diff, difftastic class — research first (backlog; research done 2026-11-12, build decision pending)

## Requirements & Constraints

- **Behave like the jj CLI.** Line-level hunks are the CLI's and stay so. CLI parameters pass through with the CLI's defaults: context lines (3) and the whitespace modes `-w` / `-b`.
- **Word segments are what `jj diff --git` underlines.** jj-lib word-diffs each changed region as one text, with no line pairing. Words are runs of `A-Z a-z 0-9 _` and non-ASCII bytes; every other byte is a token of its own. Do not bring back an own word diff (the removed `imara-diff` line pairing marked differently from the CLI).
- **No syntax highlighting (Ralph, 2026-11-12).** Its colors hide the red and green marks of the change. Diffs carry no syntax classes and no file language.
- **Output shape.** A segment has its text and a `kind` (Equal / Added / Removed). Context lines have no changed segment. Binary files carry no lines.
- **Rust computes, Dart draws:** the UI never computes or changes segments.
- **Robustness and speed.** Very long lines (minified code, 100k characters) must finish in reasonable time. NUL bytes, emoji and accented text must not panic. A 5k-line changed file in under 500 ms is a soft target, with no perf test and no CI gate.
- **Structural diff (5.9) is research first.** It must answer: can difftastic (`difft`, MIT) be used as a library or only as a program (alternatives: diffsitter, an own tree diff over tree-sitter); its cost on large files and its own limits (`DFT_BYTE_LIMIT`, the graph limit, the parse-error limit); which grammars it needs (Rust, Dart, Markdown first); and how its marks map onto `HunkLine.segments`. jj's word diff already handles a moved line break, an inserted line and `spacing8` → `spacing2`; a build pays off only for what it misses (moved code, reordered arguments, changed nesting), and only if real diffs in the app show it. *(Research 2026-11-12: difftastic detects no moves either; it marks moved code and reordered arguments as removed and added, like jj.)*
- **5.9 research done (2026-11-12).** Report `_bmad-output/planning-artifacts/research/technical-structural-diff-difftastic-class-research-2026-11-12.md`, probe `spikes/structural-diff-probe/`. Facts a build needs:
  - difftastic is a program only (no library in 0.72.0); its JSON output (`--display json`) needs `DFT_UNSTABLE=yes` and may change.
  - The JSON columns are byte offsets of the line without `\r` (difft strips every `\r` first).
  - Inside a changed comment or string the JSON lists every word as novel, so jj's word marks stay there.
  - No move detection: on the witnesses, moved code and reordered arguments get the same word marks as jj's.
  - Every fallback (`language` starts with `Text`: byte limit, graph limit, parse errors, no parser, conflict markers) keeps jj's word marks.
  - Ralph's options: A leave it (Claude's recommendation), B `difft` as an opt-in external program, C difftastic's code as a library (fork), D an own diff over tree-sitter.
- **If 5.9 is built:** structural marks go inside jj's line-level hunks. jj's word marks stay the fallback for an unsupported language, a large file, a parse error and a call over a time budget.
- **Dependencies.** Permissive licenses only (MIT project; no GPL, AGPL, LGPL or SSPL). Pin pre-1.0 crates exactly (`=x.y.z`). `default-features = false` needs a `# WHY:` comment.

## Technical Decisions

- **Where the code lives.** Only `zanshin-jj` imports jj-lib, so the diff read lives in `crates/zanshin-jj/src/hunks.rs` (`Repo::compute_hunks` takes two trees; `Repo::diff` serves revisions). `zanshin_jj::Hunk::segments` (index-aligned with `lines`) keeps the word tokens that jj-lib's `unified_diff_hunks` returns; `zanshin_ffi::diff::hunk_offset` writes them as `HunkLine.segments`. The payload builder is `zanshin_ffi::diff::diff_to_envelope` in `crates/zanshin-ffi/src/diff.rs`. Older planning prose (`crates/zanshin-diff/…`, `compute_diff`, `DiffOutput`, change-id inputs, imara-diff, tree-sitter, JSON) is superseded.
- **Line facts.** A hunk line is `Context`, `Removed` or `Added` and keeps its trailing `\n`; a missing one marks the end-of-file state. A conflicted file is diffed with its conflict materialized, as `jj diff` does. Summary mode returns files without hunks.
- **Transport.** FlatBuffers (ADR-0001), not JSON. `schemas/envelope.fbs` holds `Diff` → `FileDiff` → `Hunk` → `HunkLine` (+ `HunkLineKind`) → `Segment` (+ `SegmentKind`). Tests read through the typed accessors and the `Verifier`. Dart decodes in `packages/zanshin_core/lib/src/ffi/diff.dart` and calls `RepoHandle.diff` → `Future<Diff>` (extern `zanshin_diff`, a `DiffRequest` buffer in). No caching.
- **5.9's planned mapping keeps the wire:** structural segments in `HunkLine.segments` where available, jj's word segments otherwise.
- **Languages and grammars.** 5.1's source-symbol port already maps file names to languages, as the CLI does; Dart has no symbol pattern there. The reverted 5.3/5.4 grammar setup (tree-sitter crates for Rust, Dart and Markdown) is in the git history: `revert(diff): remove syntax highlighting (Stories 5.3, 5.4)`.

## UX & Interaction Patterns

- **Word marks are drawn (10.32, decided by Ralph 2026-11-12).** A removed or added line keeps its faint fill. Its `Removed` / `Added` segments get a strong fill of the same hue (`--rem-word-bg` / `--add-word-bg`) with `--text` glyphs. Color is the only cue; there is no underline. Context lines and `Equal` segments stay plain. A line whose equal segments hold no visible character (an inserted line, a new or deleted file) gets no strong marks: its faint fill says it all. Unified and side by side alike.

## Cross-Story Dependencies

- The line-level path (5.1 → 5.5 → 5.6 → 5.8) feeds the inspector diff view (10.24), hunk selection (10.26), hunk drags (10.27) and selection-to-tree (9.50). Selections are keyed by 5.1's sections; a result pinned to an operation and commit id exposes a stale selection.
- 5.2's segments feed 10.32's word marks; the Undo Timeline's operation view (10.29) shows them too.
- 5.9 depends on 5.2 and on 10.32 (done 2026-11-12): the build decision is made on real diffs in the app.
