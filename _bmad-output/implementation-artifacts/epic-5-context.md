# Epic 5 Context: `zanshin-diff` — Word-Diff

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Epic 5 gives Zanshin a structured diff between any two revisions: files → hunks → lines → segments, computed in Rust and sent to Dart as a FlatBuffers payload. It feeds the inspector's diff view, hunk selection and the selection-to-tree path, so its line level matches the jj CLI. The line-level path is delivered (hunks, payload, revision API, FFI extern and worker command), and so are the word-level segments inside changed lines (`imara-diff` Histogram, 5.2). Epic 5 is complete. Syntax classes (5.3, 5.4) were built on 2026-11-11 and removed on 2026-11-12: Ralph does not want syntax highlighting in diffs, because its colors hide the red/green marks of the change.

## Stories

- Story 5.1: Line-level hunks via jj-lib (done)
- Story 5.2: Word-level diff via `imara-diff` Histogram (done)
- Story 5.3: tree-sitter-highlight integration (deleted 2026-11-12: no syntax highlighting in diffs)
- Story 5.4: Bundle initial 3 grammars — Rust / Dart / Markdown (deleted 2026-11-12, with 5.3)
- Story 5.5: Diff FlatBuffers payload (done, line-level only)
- Story 5.6: Diff between two revisions API (done)
- Story 5.7: 5k-line performance test (deleted)
- Story 5.8: FFI wrapper `zanshin-ffi/src/diff.rs` (done)

## Requirements & Constraints

- **Word diff (5.2).** Only inside changed lines, with `imara-diff`'s Histogram algorithm. Do not swap in `similar`: it is far slower on large diffs. Tokens follow Unicode word boundaries. A run of removed lines pairs in order with the run of added lines after it; leftover lines get no word diff and become one whole-line segment, and so does a pair with a line longer than 131,072 characters. Context lines are never word-diffed. Whitespace-only and trailing-whitespace changes show as small segments.
- **No syntax highlighting (Ralph, 2026-11-12).** Diffs carry no syntax classes and no file language.
- **Output shape.** A segment has its text and a `kind` (Equal / Added / Removed). Binary files carry no lines.
- **Robustness.** Very long lines (minified code, 100k characters) must finish in reasonable time. NUL bytes, emoji and accented text must not panic.
- **Rust computes, Dart decodes.** The UI computes nothing about the diff.
- **Performance.** A 5k-line changed file in under 500 ms is a soft target. There is no perf test and no CI gate.
- **Non-goal:** AST-level structural diffs (difftastic class).

## Technical Decisions

- **Delivered code.** Only `zanshin-jj` imports jj-lib, so the line-level read lives there: `crates/zanshin-jj/src/hunks.rs` with `Repo::compute_hunks` (two trees in) and `Repo::diff(&DiffOptions) -> RevisionDiff`. The payload builder is `zanshin_ffi::diff::diff_to_envelope` in `crates/zanshin-ffi/src/diff.rs`. The epic's older names (`crates/zanshin-diff/src/{hunks,output}.rs`, `compute_diff`, `DiffOutput`, `DiffError`, change-id inputs) are superseded.
- **Enrichment home.** The word diff is a pure text algorithm. It lives in the plain `lib` crate `zanshin-diff`: no jj-lib, no `extern "C"` (externs live only in `zanshin-ffi`). Decided in 5.2: `zanshin-diff` depends on `zanshin-jj` (for `HunkLine` only), and `zanshin-ffi` on `zanshin-diff`. The segments are built in `zanshin_ffi::diff::hunk_offset` through `zanshin_diff::line_segments` and cross as `HunkLine.segments`; `Repo::diff`'s data stays line-level.
- **Line facts to build on.** A hunk line is `Context`, `Removed` or `Added` and keeps its trailing `\n`; a missing one marks the end-of-file state. A conflicted file is diffed with its conflict materialized, as `jj diff` does. Summary mode returns files without hunks.
- **Transport.** FlatBuffers (ADR-0001), not JSON: no serde, no JSON Schema, no `schema_version`. `schemas/envelope.fbs` holds `Diff` → `FileDiff` → `Hunk` → `HunkLine` (+ `HunkLineKind`) → `Segment` (+ `SegmentKind`, 5.2). The Dart models and decoder live in `packages/zanshin_core/lib/src/ffi/diff.dart`. Tests read through the typed accessors and the `Verifier`. Dart calls `RepoHandle.diff` → `Future<Diff>` (extern `zanshin_diff`, a `DiffRequest` buffer in). No caching.
- **Dependencies.** Pin `imara-diff` and `unicode-segmentation` exactly (`=x.y.z`). `default-features = false` needs a `# WHY:` comment. Licences must be permissive (MIT project; no GPL, AGPL, LGPL or SSPL).
- **Existing language table.** 5.1's source-symbol port already maps file names to languages, as the CLI does; Dart has no symbol pattern there.

## UX & Interaction Patterns

- The design shows no word-level marks yet. The inspector's diff view renders line-level only. Drawing word marks there is deferred UI work, not part of the diff view story (10.24).
- Target look for that UI work (Ralph, 2026-11-12, after difftastic): a changed line's background in a faint red or green, its changed words (`Added` / `Removed` segments) in a strong one, no syntax colors. A line without a partner is one whole-line segment and gets only the faint color.
- The inspector's side-by-side layout pairs runs of removed and added lines row by row and leaves unpaired cells empty. This is the same pairing 5.2 uses.

## Cross-Story Dependencies

- The delivered line-level path (5.1 → 5.5 → 5.6 → 5.8) feeds the inspector diff view (10.24), hunk selection (10.26), hunk drags (10.27) and selection-to-tree (9.50, keyed by 5.1's sections; results pinned to an operation and commit id expose stale selections).
