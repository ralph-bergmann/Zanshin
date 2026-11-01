# Epic 5 Context: `zanshin-diff` — Word-Diff + Syntax Highlight

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Give the GUI (the inspector's diff view, hunk selection and the GUI diff-editor contract) and other callers a structured diff between any two revisions: files → hunks → lines, later enriched with word-level segments and tree-sitter syntax classes, delivered across the FFI as a FlatBuffers payload. The diff must match what the jj CLI shows, so a hunk selection names exactly what the user saw. Delivery is line-level first: hunks, the payload, the revision API and the FFI extern + worker command are done; word diff and highlighting come next.

## Stories

- Story 5.1: Line-level hunks via jj-lib (done)
- Story 5.2: Word-level diff via `imara-diff` Histogram
- Story 5.3: tree-sitter-highlight integration
- Story 5.4: Bundle initial 3 grammars — Rust / Dart / Markdown
- Story 5.5: Diff FlatBuffers payload (done, line-level)
- Story 5.6: Diff between two revisions API (done)
- Story 5.7: 5k-line performance test — deleted
- Story 5.8: FFI wrapper (`zanshin-ffi/src/diff.rs`) (done)

## Requirements & Constraints

- Line-level hunks come from jj-lib (never shell out to `jj`); word-level diff inside changed lines uses `imara-diff` with the Histogram algorithm.
- Syntax classes come from `tree-sitter-highlight`; language detection is by file name/extension (case-insensitive, final extension wins, a small known-filename registry), unknown → plain text with no classes. The initial grammar set is shrunk to Rust, Dart, Markdown; more languages are added on demand. No multi-parser fallback, no incremental highlighting. Per-line highlighting is best-effort and must never error on invalid syntax.
- Segments carry `kind` (Equal / Added / Removed) and an optional `syntax_class`; segments are split at token boundaries. Context lines get one Equal segment. Pairing: contiguous Removed lines pair with the following Added lines in order; unpaired lines get no word diff.
- Binary files carry no line data. A conflicted file is diffed with its conflict materialized, as `jj diff` does. A line keeps its trailing `\n`, so a missing one shows the EOF state.
- Performance: a 5k-line changed file in < 500 ms is a soft design target only; no perf test or CI gate in the WIP phase.
- Behave like the CLI: context lines (`--context`, default 3) and whitespace modes (`-w` / `-b`) pass through; `-r` semantics diff against the merged parents (root diff is empty); copy records yield renamed/copied files with `from_path`; unmatched paths produce the `jj.paths_unmatched` warning on the envelope's warning channel.

## Technical Decisions

- **Placement (reconciled):** the diff read lives in `zanshin-jj` (`crates/zanshin-jj/src/hunks.rs`: `Repo::compute_hunks` over two trees, `Repo::diff(&DiffOptions) -> RevisionDiff`), because only `zanshin-jj` imports jj-lib and section keys must come from `select_tree::sections`. The payload builder and accessors live in `zanshin-ffi` (`zanshin_ffi::diff::diff_to_envelope`). `crates/zanshin-diff` is an empty stub; the epic's `crates/zanshin-diff/...` file paths are stale — decide placement per story (pure text algorithms like word diff/highlight need no jj-lib).
- **Sections and hunks:** jj's own sections (`ContentDiff::by_line`, as the CLI's builtin diff editor cuts them), grouped into hunks with context like `jj diff --git`. Each hunk has before/after ranges, removed/added counts, the sections it shows (Story 9.50's `HunkKey`), and the ported jj 0.46 source symbol (cut at 80 bytes; none for languages without a pattern, Dart included).
- **RevisionDiff:** `DiffRevisions::Revision` (default `@`) or `FromTo` (absent side = `@`); prefix paths (no fileset DSL); per file `kind`, `from_path`, counts, a blake2b `fingerprint` over changed lines; a summary mode that drops only the hunks; results pinned to `operation_id`, `commit_id`, `from_commit_id`. Copied/renamed files have no sections. Single revisions only.
- **Transport:** FlatBuffers per ADR-0001, not JSON/JSON Schema. `schemas/envelope.fbs` has `Diff` → `FileDiff` → `Hunk` → `HunkLine` (+ `HunkLineKind`) as the last `Payload` member; ranges are four scalars, absent `symbol` = none, vectors always present. New fields (language, segments, syntax_class) are appended to these tables. No `schema_version`, no serde. Dart models + decoder: `packages/zanshin_core/lib/src/ffi/diff.dart`.
- **FFI extern (5.8, done):** `zanshin_diff(handle, data, len)` takes a `DiffRequest` request buffer (ids as plain strings inside it, not JSON-wrapped; the full `Repo::diff` option set); the result is the `Diff` payload in a `ZanshinBuf` (buffer+len); wrapped in the envelope catch. Adds the worker command, the `RepoHandle` method, the `zanshin_core.dart` export, and puts `ShowEntry.parent_tree_labels` / `tree_labels` on the wire. No caching at this layer.
- **Pins:** load-bearing pre-1.0 deps (`imara-diff`, tree-sitter crates) pinned `=x.y.z`, with `# WHY:` comments for feature opt-outs. jj reference is `../jj` at `v0.46.0`.
- **Tests:** `zanshin-jj` / `zanshin-ffi` integration tests go in the single `tests/it/` binary (diff tests: `tests/it/hunks.rs`); each new extern needs a `packages/zanshin_core` cdylib test for the coverage ratchet.

## UX & Interaction Patterns

- The inspector's hunk header shows the per-hunk counts and the source symbol as hunk context; the file list sums files and counts ("N files +a −r") from the summary mode and loads hunks only for the focused file. The design shows no word-level or syntax marks yet.

## Cross-Story Dependencies

- 5.1 → 5.5 → 5.6 → 5.8 (done); 5.8 unblocks the inspector diff view (Story 10.24) and hunk selection (Story 10.26).
- Story 9.50 (hunk selection → selected tree) consumes the section keys; pinned results let 10.26 / 9.50 detect stale selections. Story 9.32 provides the warning channel.
- 5.4 (grammars/language detection) precedes 5.3 (highlighting); 5.2 and 5.3 then plug into the line output and extend the `Diff` tables.
