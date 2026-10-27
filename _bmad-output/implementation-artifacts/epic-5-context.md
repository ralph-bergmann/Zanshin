# Epic 5 Context: `zanshin-diff` — Word-Diff + Syntax Highlight

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Give the GUI (and any Rust caller) a structured, jj-faithful diff between revisions: files → hunks → lines (→ later word segments with syntax classes), crossing the FFI as FlatBuffers. Since the floating-client design update (2026-10-14, export `e74ced3`) the epic's first consumer is the inspector: its diff view (10.24) shows these hunks, hunk selection (10.26) picks them, and `select_tree` (9.50, done) writes a tree from a selection by the same section keys. The design shows neither word-level nor syntax marks, so the epic runs **line-level first**: 5.1, 5.5 (without segments), 5.6 and 5.8 now; 5.2–5.4 later, when a UI story needs them.

## Stories

- Story 5.1: Line-level hunks via jj-lib (`hunks.rs`)
- Story 5.2: Word-level diff via `imara-diff` Histogram (later)
- Story 5.3: tree-sitter-highlight integration (`highlight.rs`) (later, shrunk)
- Story 5.4: Bundle initial 3 grammars — Rust / Dart / Markdown (later, shrunk)
- Story 5.5: Diff output schema (FlatBuffers `Diff` table; segments later)
- Story 5.6: Diff between two revisions API (+ revision form and summary mode)
- Story 5.7: 5k-line performance test (deleted)
- Story 5.8: FFI wrapper (`zanshin-ffi/src/diff.rs`)

## Requirements & Constraints

- **Behave like the jj CLI** (pinned `v0.46.0`, read in `../jj` at the tag): sections, hunks, context, whitespace modes, copy/rename handling, source symbols and warnings must equal what `jj diff` / `jj diff --git` / the builtin diff editor produce. Only terminal UX (colour, pager) is dropped.
- **Sections = the builtin diff editor's** (`ContentDiff::by_line`, `cli/src/merge_tools/builtin.rs`); hunks group sections with context as `jj diff --git` does (`cli/src/diff_util.rs`). Each hunk lists its sections, so a selection names exactly what the user saw. The section key must equal 9.50's existing `HunkKey` (0-based `old_start`/`old_count`/`new_start`/`new_count`, lines cut like `split_inclusive('\n')`).
- **Pass parameters through** with the CLI's defaults as editable pre-fills: context lines (`diff.git.context = 3`), whitespace modes `-w` / `-b`, filesets for paths. No baked-in defaults.
- **Per hunk:** added and removed counts and a key stable within one result (path + each section's old/new range). **Per file:** kind (added, modified, removed, renamed, copied), `from_path`, counts. Copy records are used, as the CLI does (supersedes the old "rename detection is implicit" decision).
- **Source symbol** (jj 0.46's hunk-header funcname, `cli/src/source_symbol.rs`): language from the file name, cut at 80 bytes; languages without a pattern (Dart among them) get none.
- **Inputs:** `compute_hunks` takes two trees, not change ids; the revision form (`jj diff -r` = merged parents → revision; root's diff empty) and from/to share it.
- **Binary** files: marked binary, no line breakdown. **Conflicted** files: diffed with the conflict materialized, as `jj diff` does. EOF-without-newline state is preserved per line. `from == to` → empty result, no error.
- **Summary mode** (like `--stat`): files with kind, `from_path`, counts and a fingerprint of each file's changed lines (removed + added lines, no line numbers) — 10.24's Viewed key — without hunks. Full diff is then requested per focused file.
- **Pinned results:** every result names the operation and commit id it was computed at (stale-selection detection in 10.26 / 9.50).
- **Unmatched paths** warn like the CLI, as a coded warning on the envelope's warning channel (9.32, in place).
- Performance (< 500 ms for a 5k-line file) is a soft target only; no timing assertions.
- Later stories (5.2–5.4) keep their shrinks: word pairing = first N removed with first N added in a run (also 10.24's side-by-side pairing); segments split at token boundaries; 3 grammars only; plain-text fallback; no fallback parsers, no incremental highlighting.

## Technical Decisions

- **Only `zanshin-jj` imports `jj_lib`** (anti-corruption layer). `crates/zanshin-diff` is still a skeleton; any jj-lib diff machinery (`ContentDiff`, tree diff streams, copy records, conflict materialization) lives behind `zanshin-jj`'s typed API. `zanshin-jj` already cuts sections with `ContentDiff::by_line` in `select_tree.rs` for 9.50 — reuse it so the two cannot drift.
- **FlatBuffers, not JSON** (ADR-0001): the diff is a `Diff` payload in `schemas/envelope.fbs`'s `Payload` union, added at the end; no `schema_version`, no `.v1`, no `serde`/`jsonschema`. Tests read through generated accessors + the `Verifier`. Regenerate with `cargo make codegen`; generated code is committed.
- **FFI** (5.8): `zanshin_diff_*` externs only in `zanshin-ffi`, wrapped in the envelope's panic catch; change ids are lone CStrings (no JSON wrapping); composite results ride the buffer token. Each request recomputes (no caching; ADR-0002 — no repo state on the handle). Dart side: a `WorkerCommand` and a `RepoHandle` method in `packages/zanshin_core`; `docs/ffi-abi.md` extended.
- **Errors:** `thiserror` types mapped to registered `<domain>.<reason>` codes (`docs/rust-error-codes.md`); no `unwrap`/`panic` on FFI-reachable paths.
- **Pins:** `imara-diff` exact pin; tree-sitter grammar crates exact for pre-1.0; `default-features = false` needs a `# WHY:` comment.
- **Tests and coverage:** Rust unit tests inline, integration tests in the crate's single `tests/it/` binary; every new extern needs a `zanshin_core` cdylib test (the coverage ratchet attributes only that union); new files reach 80 %. Committed fixtures are never regenerated.

## UX & Interaction Patterns

The inspector diff (10.24) is line-level: unified (default) or side by side, mono text with add/remove fills, hunk header `@@ −old,n +new,m @@` plus jj's source symbol and ±, no line numbers, "Binary file" placeholder, conflicted files shown as materialized text. The header sums the summary's counts ("N files +a −r"). Nothing is computed in Dart — the backend supplies kinds, counts, fingerprints and hunks.

## Cross-Story Dependencies

- Order: 5.1 → 5.5 (no segments) → 5.6 (with summary mode) → 5.8; then 10.24 can start. 5.2 needs 5.1; 5.3 and 5.4 belong together; 5.6's steps for word diff and highlighting are skipped until they land (a line carries text only).
- Consumers: 10.24 (diff view, needs the line-level path), 10.26 (hunk selection, needs 5.1's keys + 9.50), 10.27 (hunk drags), 9.50 `select_tree` (done; its `HunkKey` is the contract 5.1's sections must match).
- Uses 9.32's `Envelope.warnings` channel (done) for the unmatched-paths warning.
- 5.1 acceptance additions from the design update: sections equal the builtin editor's for the same file pair; a hunk's counts equal its lines; context 0 and 3 yield the same sections; the source symbol equals `jj diff --git`'s on a Rust fixture and is absent on Dart. 5.6 additions: a merge diffs against its merged parents; a renamed file reports `renamed` + `from_path`; summary mode returns the same files and counts as the full diff; an unmatched path warns; a result carries its operation and commit id.
