# Epic 5 Context: `zanshin-diff` — Word-Diff + Syntax Highlight

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Give the GUI (and any Rust caller) a structured, jj-faithful diff between revisions: files → hunks → lines (→ later word segments with syntax classes), crossing the FFI as FlatBuffers. The epic's first consumer is the floating client's inspector: its diff view (10.24) shows these hunks, hunk selection (10.26) picks them, and `select_tree` (9.50, done) writes a tree from a selection by the same section keys. The design shows neither word-level nor syntax marks, so the epic runs **line-level first**: 5.1 and 5.5 (without segments) are done, then 5.6 and 5.8; 5.2–5.4 come later, when a UI story needs them.

## Stories

- Story 5.1: Line-level hunks via jj-lib (done)
- Story 5.2: Word-level diff via `imara-diff` Histogram (later)
- Story 5.3: tree-sitter-highlight integration (later, shrunk)
- Story 5.4: Bundle initial 3 grammars — Rust / Dart / Markdown (later, shrunk)
- Story 5.5: Diff output schema (FlatBuffers `Diff` table, line-level; done)
- Story 5.6: Diff between two revisions API (+ revision form and summary mode)
- Story 5.7: 5k-line performance test (deleted)
- Story 5.8: FFI wrapper (`zanshin-ffi/src/diff.rs`)

## Requirements & Constraints

- **Behave like the jj CLI** (pinned `v0.46.0`, read in `../jj` at the tag): sections, hunks, context, whitespace modes, copy/rename handling, source symbols, binary rule and warnings must equal what `jj diff` / `jj diff --git` / the builtin diff editor produce. Only terminal UX (colour, pager) is dropped.
- **Sections = the builtin diff editor's**; hunks group sections with context as `jj diff --git` does. Each hunk lists its sections, so a selection names exactly what the user saw; section keys are exactly the keys `select_tree` accepts.
- **Pass parameters through** with the CLI's defaults as editable pre-fills: context lines (`None` = effective `diff.git.context`, 3), whitespace modes exact / `-w` / `-b`, filesets for paths. No baked-in defaults.
- **Per hunk:** removed/added counts, source symbol, sections, lines (context/removed/added; a line keeps its `\n`, so a last line without one shows the EOF state). **Per file** (5.6 adds): kind (added, modified, removed, renamed, copied), `from_path`, counts. Copy records are used, as the CLI does (supersedes the old "rename detection is implicit" decision).
- **Binary** (a NUL in either side's first 8000 bytes): marked binary, no hunks. **Conflicted** files are diffed with the conflict materialized, honouring `ui.conflict-marker-style`. Mode-only changes: no hunks, a mode-change flag. `from == to` → empty result, no error.
- **Revision form** (`jj diff -r`): merged parents → revision; the root's diff is empty. It and from/to share the two-tree read.
- **Summary mode** (like `--stat`): files with kind, `from_path`, counts and a fingerprint of each file's changed lines (removed + added lines, no line numbers) — 10.24's Viewed key — without hunks. Full hunks are then requested per focused file.
- **Pinned results:** every 5.6 result names the operation and commit id it was computed at (stale-selection detection in 10.26 / 9.50).
- **Unmatched paths** warn like the CLI, as a coded warning on the envelope's warning channel.
- Performance (< 500 ms for a 5k-line file) is a soft target only; no timing assertions.
- Later stories keep their shrinks: word pairing = first N removed with first N added in a run (also 10.24's side-by-side pairing); segments split at token boundaries; 3 grammars only; plain-text fallback; no fallback parsers, no incremental highlighting.

## Technical Decisions

- **Only `zanshin-jj` imports `jj_lib`.** The line-level read is `zanshin_jj::Repo::compute_hunks` (`crates/zanshin-jj/src/hunks.rs`), not `crates/zanshin-diff` — epics ACs naming `zanshin-diff/src/hunks.rs` / `lib.rs` are reconciled to `zanshin-jj`. `crates/zanshin-diff` stays a skeleton until 5.2–5.4. Hunks come from jj-lib's `unified_diff_hunks` (what the CLI's `show_git_diff` calls); section keys come only from `select_tree::sections`, so the two cannot drift.
- **Trees in, not change ids:** `compute_hunks` takes two trees (ids + labels). `ShowEntry` reports parent/tree labels so a caller can name a merged parent tree; those labels are Rust-only until 5.8 adds them to the FFI `ShowEntry`.
- **Config** resolves for the CLI command `diff` through the per-verb config path, like every read.
- **Source symbol** is a verbatim port of the CLI's `source_symbol.rs` (language from the new path's file name; none for Dart), cut at 80 bytes; new side unless the hunk has no added lines. Regex init must not panic.
- **FlatBuffers, not JSON** (ADR-0001): the diff is the `Diff` payload (`Diff` → `FileDiff` → `Hunk` → `HunkLine` + `HunkLineKind`) in `schemas/envelope.fbs`, the last `Payload` member, reusing 9.50's `HunkKey` for file and hunk sections; ranges are four scalars, an absent `symbol` = none, vectors always present. No `schema_version`, no `.v1`, no `serde`/`jsonschema`/`json_schema`. New fields (5.6's kind, `from_path`, counts; later segments/language) are appended to these tables. Tests read through generated accessors + the `Verifier`. Regenerate with `cargo make codegen`; generated code is committed.
- **Builder and decoder exist:** `zanshin_ffi::diff::diff_to_envelope` (`crates/zanshin-ffi/src/diff.rs`) builds the payload; the Dart models + decoder are in `packages/zanshin_core/lib/src/ffi/diff.dart`. 5.6/5.8 extend these, not new files in `zanshin-diff`.
- **FFI** (5.8): `zanshin_diff_*` externs in `crates/zanshin-ffi/src/diff.rs`, wrapped in the envelope's panic catch; ids are lone CStrings (no JSON wrapping); results ride the buffer token. Each request recomputes (no caching, no repo state on the handle). Dart side: a `WorkerCommand`, a `RepoHandle` method and the `zanshin_core.dart` export in `packages/zanshin_core`; `docs/ffi-abi.md` extended.
- **Errors:** 5.1 reuses `MutateError` (InvalidInput, Backend, Config, Precondition) as `select_tree` does; new error types map to registered `<domain>.<reason>` codes. No `unwrap`/`panic` on FFI-reachable paths.
- **Pins:** `imara-diff` exact; tree-sitter grammar crates exact for pre-1.0; `default-features = false` needs a `# WHY:` comment.
- **Tests and coverage:** unit tests inline; integration tests in the crate's single `tests/it/` binary (5.1's in `tests/it/hunks.rs`); every new extern needs a `zanshin_core` cdylib test; new files reach 80 %. Committed fixtures are never regenerated.

## UX & Interaction Patterns

The inspector diff (10.24) is line-level: unified (default) or side by side, mono text with add/remove fills, hunk header `@@ −old,n +new,m @@` plus jj's source symbol and ±, no line numbers, "Binary file" placeholder, conflicted files shown as materialized text. The header sums the summary's counts ("N files +a −r"). Nothing is computed in Dart — the backend supplies kinds, counts, fingerprints and hunks.

## Cross-Story Dependencies

- Order: 5.1 (done) → 5.5 (done, no segments) → 5.6 (with summary mode) → 5.8; then 10.24 can start. 5.2 needs 5.1; 5.3 and 5.4 belong together; 5.6's word-diff and highlighting steps are skipped until they land (a line carries text only).
- 5.6 adds what 5.1 left out: copy/rename records, path filesets, the unmatched-paths warning, file kinds and counts, summary mode, (operation, commit) pinning. Its ACs: a merge diffs against its merged parents; a renamed file reports `renamed` + `from_path`; summary mode returns the same files and counts as the full diff; an unmatched path warns; a result carries its operation and commit id.
- 5.8 also carries `ShowEntry`'s tree labels onto the wire (deferred from 5.1).
- Consumers: 10.24 (diff view), 10.26 (hunk selection, needs 5.1's keys + 9.50), 10.27 (hunk drags), 9.50 `select_tree` (its `HunkKey` is the section-key contract). Uses 9.32's `Envelope.warnings` channel (done).
