---
title: 'Story 5.6 — Diff between two revisions API (revision form, copies, counts, summary, pinning)'
type: 'feature'
created: '2026-10-31'
status: 'done'
baseline_revision: 'c3f0fbf18167d6359488c41bcf055d9e28eb29ba'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      Selecting a renamed or copied file in 10.26 cannot be expressed through select_tree by its Repo::diff entry alone: the entry is the target path (sections empty), while the builtin diff editor select_tree mirrors sees the rename as a removed source path plus an added target path.
    evidence: |-
      Repo::diff uses copy records (as jj diff does), so the rename source's removal is folded into the target entry; select_tree diffs without copy records (builtin.rs:567 @ v0.46.0), so choosing the target "whole" leaves the source path unselected. hunks.rs DiffReader::file empties sections for copy entries.
    location: >-
      crates/zanshin-jj/src/hunks.rs DiffReader::file
    severity: medium
    resolved: >-
      2026-11-03 — fixed (spec-10-26-hunk-selection-gui-tree, commit 5937e4f4): renamed/copied files are whole-only and a whole pick also selects the source path, on both the paths and the tree route.
---

<intent-contract>

## Intent

**Problem:** Story 5.1's `Repo::compute_hunks` diffs two trees the caller already holds; nothing diffs *revisions* the way `jj diff` does (`-r` = merged parents → revision, or `--from`/`--to`), with copy records (renames/copies), a path filter and its unmatched-paths warning, per-file kind / `from_path` / counts, a hunk-free summary mode with a per-file fingerprint (10.24's Viewed key), or a pin naming the operation and commit(s) the result was computed at (10.26 / 9.50 stale detection). 5.5's `Diff` wire table lacks those fields.

**Approach:** Add `zanshin_jj::Repo::diff(&DiffOptions) -> Result<RevisionDiff, MutateError>` (CLI command `diff`), sharing `hunks.rs`' `DiffReader` (extended to take a matcher and copy records), add `kind` / counts / `fingerprint` to `zanshin_jj::FileDiff` (also filled by `compute_hunks`), append the new fields to the `FileDiff` and `Diff` wire tables, and make `zanshin_ffi::diff::diff_to_envelope` + the Dart decoder carry them. Steps 3–4 of epics' `compute_diff` (word diff, highlighting) stay skipped (line-level first, decision (g)).

## Boundaries & Constraints

**Always:**
- CLI behaviour at v0.46.0 (`cli/src/commands/diff.rs` `cmd_diff`, `diff_util.rs` `show_git_diff`): `DiffRevisions::Revision(r)` — from `merge_commit_trees(parents of r)` to `r`'s tree, copy records accumulated over every (parent, r) pair; `DiffRevisions::FromTo { from, to }` — each absent side is `@`, copy records `get_copy_records(from, to, matcher)`. Copy records are filtered by the matcher on the record's TARGET (`get_copy_records`, `diff_util.rs:676-689`). Default = `Revision(None)` (`-r @`). Root's diff is empty; `from == to` is empty, no error.
- Revisions are the house single-revision currency `Option<ChangeId>`, resolved through the call's `revsets.short-prefixes` context by `crate::mutate::resolve_or_wc` (same errors as `select_tree`/`file_list`: `ChangeNotFound`, `RevsetResolutionError`). Everything is read from ONE `crate::snapshot::reload_head` repo.
- `paths` are the house prefix paths (`op_support::build_matcher` / `parse_prefixes`, as `interdiff` and `file list` take them — the fileset DSL is terminal input language, ADR-0003); invalid entry → `MutateError::InvalidInput`. Unmatched explicit paths warn `jj.paths_unmatched` via `warning::warn_unmatched_paths` over `[from_tree, to_tree]` (`print_unmatched_explicit_paths`, diff.rs:226).
- Per entry of `diff_stream_with_copies`: before side materialized at the SOURCE path, after side at the TARGET path, language from the target (as `show_git_diff`); `path` = target. Kind as `commit_views::tree_file_changes` classifies it (copy source first, then presence). A copied/renamed entry has empty `sections` (file and hunks): the builtin diff editor `select_tree` mirrors uses NO copy records (`builtin.rs:567`), so source→target keys are not keys it accepts — it can only be selected whole.
- Per-file `removed` / `added` = the sums of its hunks' counts (0 for binary/mode-only). `fingerprint` = lowercase hex of `jj_lib::content_hash::blake2b_hash` over the file's changed lines in order (removed tagged `-`, added tagged `+`, no line numbers, no context), plus — so a change without lines still changes it — both sides' raw contents when `binary` and a marker when `mode_change`. Deterministic across processes (it is persisted by 10.24).
- `summary: true` returns the same files, kinds, `from_path`s, flags, sections, counts and fingerprints with `hunks` empty.
- `RevisionDiff { operation_id, commit_id, from_commit_id, files }`: `operation_id` = the read repo's op id (post-snapshot); `commit_id` = the revision (`Revision`) or `to` (`FromTo`); `from_commit_id` = `None` for `Revision`, `Some(from)` for `FromTo`. Full hex.
- `compute_hunks` keeps its contract and output except the new fields (no copies → kind from presence, `from_path` none).
- Wire: append (never reorder) to `table FileDiff`: `kind: ChangeKind` (the existing enum), `from_path: string` (absent unless Renamed/Copied), `removed: uint`, `added: uint`, `fingerprint: string`; to `table Diff`: `operation_id: string`, `commit_id: string`, `from_commit_id: string` (absent = none). Regenerate with `cargo make codegen` only; commit what it emits.
- Writes no operation beyond the pre-verb snapshot. Every `pub` item doc-commented; clippy pedantic refactor-not-suppress; tests via generated accessors + Verifier on the Rust wire side.

**Never:**
- No `extern "C"` fn, `WorkerCommand`, `RepoHandle` method, `zanshin_core.dart` export, or `ShowEntry` labels on the wire (Story 5.8). No word segments / language / syntax classes (5.2–5.4). No code in `crates/zanshin-diff`.
- No multi-revision `-r` revsets (gaps check etc.), no `--stat` byte deltas, no fileset DSL parsing, no caching.
- No regeneration of committed fixtures.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Revision of a plain change | `Revision(Some(C))`, C modifies `f.txt` | files = `compute_hunks(C's parent tree, C's tree)`'s, kind `Modified`; `commit_id` = C's, `from_commit_id` none, `operation_id` = head op | — |
| Default | `DiffOptions::default()` | equals `Revision(Some(@))` | — |
| Merge | M with parents P1 (adds `a`), P2 (adds `b`), M adds `c` | only `c` (diffed against the merged parents) | — |
| Root | `Revision(Some(root))` | `files` empty | — |
| Rename (git backend) | C renames `old.txt`→`new.txt`, edits one line | ONE file `new.txt`, kind `Renamed { from: old.txt }`, hunks source→target, `sections` empty | — |
| From/to | `FromTo { from: A, to: C }` | diff A's tree → C's tree; `from_commit_id` = A, `commit_id` = C; one side `None` = `@` | — |
| Equal | `FromTo { from: C, to: C }` | empty | — |
| Paths | `paths: ["f.txt"]` | only `f.txt`; `["nope"]` → empty files + one `jj.paths_unmatched` warning | `["/x"]` → `InvalidInput` |
| Summary | same revision, `summary: true` | same files/kinds/counts/fingerprints as the full diff, every `hunks` empty | — |
| Fingerprint | same changed lines at shifted line numbers (context added above) vs a different changed line | equal vs different | — |
| Unknown revision | `Revision(Some("zzzz…"))` | — | `MutateError::ChangeNotFound` |
| Wire round trip | a `RevisionDiff` with all kinds, `from_path`, counts, fingerprint, pins (and `from_commit_id` none) | Rust: Verifier passes, mapping back yields the input; Dart: models equal, absent `from_path`/`from_commit_id` → null | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/hunks.rs:44-155` -- `HunksOptions`, `Whitespace`, `FileDiff`, `Hunk`, `compute_hunks`; `:158-215` `DiffReader { files, file }` — `files` uses `diff_stream(…, &EverythingMatcher)` and `materialize_tree_value(…, &entry.path, …)` per side; extend to `diff_stream_with_copies(after, matcher, records)` (`entry.path.source()`/`target()`, `copy_operation()`), keep the binary/equal rules. `compute_hunks` passes `EverythingMatcher` + `CopyRecords::default()`.
- `crates/zanshin-jj/src/commit_views.rs:382-440` -- `tree_file_changes` (kind classification to mirror), `copy_records_over_all_parents` (pattern; the new one must filter by the matcher on `record.target`).
- `crates/zanshin-jj/src/status.rs:25-53` -- `FileChange`/`ChangeKind` (`Renamed { from: PathBuf }`, `Copied { from }`): reuse `ChangeKind` as `FileDiff::kind` (add `Clone, PartialEq, Eq` derives).
- `crates/zanshin-jj/src/repo.rs:4389-4419` -- `Repo::compute_hunks` (`with_verb(cli_command::DIFF, |repo, ctx| …)`, `ctx.config`, `ctx.warnings`, `ctx.template_startup.id_prefix_context()`); add `Repo::diff` beside it with a full doc (CLI refs, errors list).
- `crates/zanshin-jj/src/mutate.rs:634-685` -- `res` / `resolve_or_wc` → `MutateError`. `crates/zanshin-jj/src/file.rs:283-292` -- `head_commit` pattern (`snapshot::reload_head` then resolve).
- `crates/zanshin-jj/src/op_support.rs:879-905` -- `build_matcher`, `parse_prefixes`. `crates/zanshin-jj/src/warning.rs:787` -- `warn_unmatched_paths`.
- `jj_lib::rewrite::merge_commit_trees` (used in `diffedit.rs:109`), `Store::get_copy_records(None, root, head)`, `jj_lib::content_hash::blake2b_hash`, `jj_lib::hex_util::encode_hex`; `crate::OperationId` (`op_log.rs:40`), `crate::CommitId` (`change.rs:18`).
- `crates/zanshin-jj/src/lib.rs:117` -- `pub use hunks::{…}`: add `DiffOptions`, `DiffRevisions`, `RevisionDiff`.
- `crates/zanshin-jj/tests/it/hunks.rs` -- fixture style (`init()`, `write`, `set_executable`, `wc`, `head_op`); `tests/it/commit_views.rs:250-270` `renamed_on_git_backend` (rename recipe: write, snapshot, new, `fs::rename`, snapshot); `tests/it/api_stability.rs:1774-1822` `compute_hunks_surface_resolves` — extend with the new fields and `Repo::diff` as a fn pointer.
- `schemas/envelope.fbs:1505-1514` -- `enum ChangeKind`, `FileChange.from_path` precedent; `:3104-3122` `table FileDiff`, `table Diff` — append fields + update docs.
- `crates/zanshin-ffi/src/diff.rs` -- `diff_to_envelope(files, report)` → change to `diff_to_envelope(diff: &zanshin_jj::RevisionDiff, report)`; extend helpers and the inline round-trip tests (`files_from_wire`, `sample`). Kind mapping like `crates/zanshin-ffi/src/commit_views.rs` / status's `ChangeKind` → `fbs::ChangeKind`.
- `crates/zanshin-ffi/tests/it/diff_ffi.rs` -- real-repo test: switch to `repo.diff(…)` (still assert wire keys == `compute_hunks` keys for the same trees) + pins.
- `packages/zanshin_core/lib/src/ffi/diff.dart:83-170` -- `FileDiff`, `Diff`, decoder; reuse `FileChangeKind` from `status.dart:74` (map like `status.dart:137` `_mapChangeKind`). `packages/zanshin_core/test/ffi/diff_test.dart` -- decode-contract tests.
- `docs/ffi-abi.md` -- "`Diff` payload (Story 5.5)" section: add the 5.6 fields.
- `_bmad-output/planning-artifacts/epics.md:4796-4805` -- Story 5.6 blockquote; append a dated "Delivered" note. `_bmad-output/implementation-artifacts/sprint-status.yaml:117` -- `5-6-diff-between-two-revisions-api`, `last_updated`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/status.rs` -- derive `Clone, PartialEq, Eq` on `ChangeKind` -- reuse as `FileDiff::kind`.
- `crates/zanshin-jj/src/hunks.rs` -- `FileDiff` gains `kind: ChangeKind`, `removed: u32`, `added: u32`, `fingerprint: String` (documented); `DiffReader::files` takes matcher + copy records and source/target paths; copy entries get empty sections; add `DiffOptions { revisions: DiffRevisions, paths: Vec<String>, context: Option<usize>, whitespace: Whitespace, summary: bool }`, `DiffRevisions` (default `Revision(None)`), `RevisionDiff`, and `pub(crate) fn diff(workspace, config, sink, prefixes, options)`; inline unit tests for the fingerprint and summary/count helpers -- one reader for both entry points.
- `crates/zanshin-jj/src/repo.rs` + `lib.rs` -- `Repo::diff` (CLI command `diff`), re-exports.
- `crates/zanshin-jj/tests/it/diff.rs` (new, declared in `tests/it/main.rs`) -- the zanshin-jj matrix rows (plain, default, merge, root, rename on git backend, from/to, equal, paths + warning + invalid, summary, fingerprint, unknown revision, no operation written); `tests/it/api_stability.rs` + `tests/it/hunks.rs` -- adjust for the new fields.
- `schemas/envelope.fbs` then `cargo make codegen` -- append the wire fields; commit generated Rust + Dart.
- `crates/zanshin-ffi/src/diff.rs`, `tests/it/diff_ffi.rs` -- builder over `RevisionDiff`; round-trip incl. new fields and pins.
- `packages/zanshin_core/lib/src/ffi/diff.dart`, `test/ffi/diff_test.dart` -- models + decoder + tests for the new fields.
- `docs/ffi-abi.md`, `epics.md` 5.6 note, `sprint-status.yaml` -- docs and ledgers (5-6 → done at finalize).

**Acceptance Criteria:**
- Given a merge commit, when `Repo::diff` runs with `Revision(merge)`, then only what the merge itself changed is listed (merged parents as the left side).
- Given a rename on a git-backed repo, when diffed, then one file with kind `Renamed`, `from_path` = the old path, and hunks between the two contents.
- Given any revision, when diffed with `summary: true` and `false`, then the file lists equal field by field except `hunks`.
- Given a path matching nothing, when diffed, then the call's warnings carry one `jj.paths_unmatched` and the result is empty.
- Given any result, then it carries the head operation id and the commit id(s), and the wire + Dart decoder carry them unchanged.

## Spec Change Log

## Review Triage Log

### 2026-10-31 — Review pass
- verdicts: 28 findings — high 0, medium 3, low 19, false 6, maybe-false 0
- findings:
  - `[low]` `patch` (blind) The fingerprint hashes no path or kind, so content-less changes (pure rename, empty-file add) share one value. — 10.24 keys Viewed by (change id, path, fingerprint), so the path disambiguates; the docs (hunks.rs, fbs, Dart, ffi-abi) now say it covers content only and is combined with the path.
  - `[low]` `patch` (blind) The fingerprint depends on `whitespace` and `ui.conflict-marker-style`, but the docs only say "stable". — Docs now name both dependencies.
  - `[low]` `reject` (blind) The result does not record which options (summary, whitespace, context, paths) produced it. — The caller passed them and holds them; adding echo fields is new surface for no named consumer.
  - `[low]` `reject` (blind) Summary mode computes the hunks and discards them. — Deliberate (Design Notes): one code path guarantees the summary's counts equal the full diff's; performance is a soft target.
  - `[low]` `reject` (blind) Binary fingerprints copy both contents before hashing. — One transient allocation per binary file; an incremental hasher adds code for no measured cost.
  - `[false]` `reject` (blind) `change_kind` builds `from` differently from `repo_path_to_pathbuf`, so `from_path` can diverge. — `repo_path_to_pathbuf` is exactly `PathBuf::from(p.as_internal_file_string())` (commit_views.rs:378-380), the same expression; the duplication itself names no harm.
  - `[low]` `patch` (blind) The `hunks.rs` module doc still describes only `diff_stream`. — A Story 5.6 bullet added.
  - `[low]` `defer` (blind) Scope cuts are not in deferred-work.md. — Of the three: prefix paths are the house rule (ADR-0003, as interdiff / file list) → reject; single revision is what the intent asks (`diff(revision, paths)`) → reject; a copy/rename's missing sections is real for 10.26 → deferred (medium) and mirrored.
  - `[low]` `reject` (blind) Error paths (ambiguous prefix, config, precondition), summary on rename/binary, `context` override, root prefix untested in `diff.rs`. — They run through shared, already-tested helpers (`resolve_or_wc`, `DiffReader::new` via compute_hunks tests, `build_matcher`); the FromTo-rename part is the gap layer's patch below.
  - `[low]` `reject` (blind) The Dart decoder turns absent `operationId`/`commitId`/`fingerprint` into `''`. — Only a corrupt buffer reaches it (the builder always writes them); same `?? ''` convention 5.5's review rejected for `path`/`text`.
  - `[low]` `reject` (blind) The FFI integration test maps every non-Added kind to Modified; the unit helper's `_ => Copied` wildcard. — The fixture has only added/modified files, so the check is exact for it; the five kinds round-trip in the unit test; the wildcard only maps generated-enum values the builder writes.
  - `[low]` `patch` (blind) ffi-abi section heading still "Story 5.5"; fingerprint length and saturating counts undocumented. — Heading and both facts added.
  - `[low]` `patch` (edge) Content-less changes share a fingerprint. — Same root cause as the first blind row; same doc patch.
  - `[low]` `patch` (edge) Fingerprint differs under another whitespace mode / marker style. — Same as the second blind row.
  - `[low]` `reject` (edge) Absent pins decode as `''`. — Same as the Dart `?? ''` row.
  - `[low]` `reject` (edge) Absent fingerprint decodes as `''`. — Same.
  - `[low]` `reject` (edge) Unit helper maps unknown kinds to Copied. — Same as the wildcard row.
  - `[low]` `patch` (edge, claim) "Stable" claim omits options and path. — Same doc patch.
  - `[medium]` `patch` (gap) `Repo::diff` missing from the per-verb `records!` registry test. — `records!(repo, DIFF, diff(...))` added beside `compute_hunks`.
  - `[medium]` `patch` (gap) The FromTo copy-record path is never exercised with a rename. — `a_rename_is_one_file_with_its_source` also runs FromTo(A, C) and asserts the single Renamed file.
  - `[medium]` `patch` (gap) The operation pin is checked only on a clean working copy. — New case: a dirty @, `diff`, then the pin equals the post-call head and differs from the pre-call one.
  - `[false]` `reject` (intent) The API is a `Repo` method in zanshin-jj with `MutateError`, not `zanshin-diff::compute_diff` / `DiffError`. — Only zanshin-jj imports jj-lib (project-context, 5.1's reconciliation); epic-5-context records it; FlatBuffers replaces `schema_version` (ADR-0001).
  - `[false]` `reject` (intent) Step 2 (`detect_language`) absent. — Language detection belongs to 5.3/5.4 (later); line-level first, decision (g).
  - `[low]` `reject` (intent) Paths are prefixes, not the fileset DSL. — House rule (ADR-0003, `op_support::build_matcher` doc), same as interdiff / file list.
  - `[false]` `reject` (intent) `-r` takes one revision, not a revset. — The intent's revision form is `diff(revision, paths)`.
  - `[low]` `reject` (intent) Summary envelopes and diff-produced warnings are not tested on the wire. — The builder is mode-agnostic (empty hunks vectors are already round-tripped) and warnings ride `finish_envelope` like every payload (5.5's report test).
  - `[false]` `reject` (intent) No extern / worker command / RepoHandle method. — Story 5.8's, by the epic plan and the spec's Never list.
  - `[false]` `reject` (intent) Verification outcomes not recorded. — Written at finalize, below.
  - Verification-gap layer: 3 gap findings (rows above), all patched.

### 2026-10-31 — Review pass (follow-up)
- verdicts: 25 findings — high 0, medium 2, low 13, false 3, maybe-false 0 (7 carried)
- findings:
  - `[medium]` `patch` (blind) The fingerprint's bytes depend on jj-lib's `ContentHash` encoding, and the unit test computed its expected value with the same `blake2b_hash`, so a pin bump changing the encoding would silently reset every persisted Viewed key. — `the_fingerprint_keys_the_changed_lines_only` now also locks the literal 128-char hex.
  - `[low]` `reject` (blind) carried: summary mode computes the hunks and discards them. — As logged in the first pass (one code path keeps counts equal).
  - `[low]` `reject` (blind) carried: binary fingerprints copy both contents before hashing. — As logged.
  - `[low]` `reject` (blind) carried: the Dart decoder turns absent pins/fingerprint into `''`. — As logged (only a corrupt buffer reaches it).
  - `[low]` `reject` (blind) A `FileDiff` written without `kind` reads as `Added` (the enum default). — The builder always writes `kind`; only a corrupt buffer omits it, and an absent enum field reading its default is the FlatBuffers convention every wire enum here follows.
  - `[low]` `reject` (blind) carried: `kind_from_wire`'s `_ => Copied` wildcard. — As logged.
  - `[low]` `reject` (blind) carried: the FFI integration test's two-way kind guess. — As logged.
  - `[low]` `reject` (blind) No end-to-end test with a real copy record. — The git backend's rewrite tracking produced no `Copy` in any fixture (already a recorded residual risk); `Copied` round-trips on the wire in Rust and Dart.
  - `[low]` `patch` (blind) No test of a path filter matching only a rename's target. — `a_rename_is_one_file_with_its_source` asserts `paths: ["new.txt"]` keeps the one renamed file; the root prefix part rejected (shared `build_matcher`, tested by its own callers).
  - `[medium]` `patch` (blind) `whitespace` / `context` are never exercised through `Repo::diff`. — Same root cause as the gap layer's first finding; same test (conflicted sides / binary under summary run through the shared reader, rejected).
  - `[low]` `reject` (blind) carried: prefix paths instead of filesets. — As logged (ADR-0003 house rule).
  - `[false]` `reject` (blind) carried: `-r` takes one revision, not a revset. — As logged.
  - `[low]` `patch` (blind) `ChangeKind`'s doc still says only "between `@-` and `@`". — Doc now also names `FileDiff::kind`'s two sides.
  - `[low]` `patch` (blind) The Dart `fingerprint` doc omits binary contents and the mode marker. — Added.
  - `[low]` `reject` (edge) A file↔symlink type change with equal materialized text gets the content-less fingerprint. — Rare (same bytes as a symlink target), the Viewed key carries the path, and the fix adds a branch.
  - `[low]` `reject` (edge) carried: absent pins/fingerprint decode as `''`. — As logged.
  - `[medium]` `patch` (gap) `Repo::diff`'s `context` / `whitespace` pass-through is untested (every call uses the defaults). — New `context_and_whitespace_reach_the_reader`: `context: Some(0)` drops the context lines; a whitespace-only edit under `IgnoreAllSpace` has no hunks and a different fingerprint.
  - `[low]` `patch` (gap) A rename's hunk language (target path) is untested. — New `a_rename_takes_its_language_from_the_target` (`main.txt` → `main.rs`, symbol `fn main() {`).
  - `[low]` `reject` (intent) The fingerprint row is witnessed by a unit test, not at `Repo::diff`. — One function over the reader's hunks; the new whitespace test also shows the fingerprint at `Repo::diff`.
  - `[low]` `patch` (intent) The rename row's "hunks source→target" checks only counts. — The rename test now asserts the changed lines are `-line 5` / `+line five` (left side read at the source).
  - `[low]` `reject` (intent) Copy-record accumulation over several parents is untested. — A plain loop over parents; the merge test runs it (no records) and the rename tests run the add.
  - `[low]` `reject` (intent) `Copied` only on the wire. — Same as the blind copy-record row.
  - `[low]` `patch` (intent) "Language from the target" untested. — Same root cause as the gap layer's language row; same test.
  - `[low]` `reject` (intent) carried: the Dart `''` coercion. — As logged.
  - `[false]` `reject` (intent) `compute_hunks` output can no longer be serialized without pins. — The intent makes `diff_to_envelope` carry a `RevisionDiff`; `compute_hunks` has no extern (Story 5.8 wires `diff`).
- Coverage (orchestrator note): `a_missing_object_is_a_backend_error` deletes C's root tree object (fails in `get_copy_records` → `read_tree_for_commit`, `add_copy_records`' first `map_err`) and then C's commit object (D's `parents()` fails in `diff`). Not reachable without a mid-stream gix failure: `add_copy_records`' stream `map_err` and `merge_commit_trees`' (lazy for one parent).

## Design Notes

Why `Repo::diff` returns `MutateError`: it shares `compute_hunks`' config/backend errors and `select_tree`'s resolution errors, and 5.8 maps one taxonomy. Why reuse `ChangeKind`: it is already the wire `ChangeKind` + `from_path` pair `show`/`status` ship, so Dart reuses `FileChangeKind`. Fingerprint shape (example): lines `-foo\n`, `+bar\n` → `blake2b_hash(&vec![b"-foo\n".to_vec(), b"+bar\n".to_vec()])` hex; binary appends `b"<"+before`, `b">"+after`; mode change appends `b"x"`. Summary mode computes hunks and drops them: one code path guarantees equal counts (the AC); performance is a soft target only.

## Verification

**Commands:**
- `cargo make codegen` -- expected: succeeds; only the generated envelope files change
- `cargo test -p zanshin-jj --test it diff::` and `cargo test -p zanshin-jj --test it hunks::` and `cargo test -p zanshin-jj --test it api_stability::` and `cargo test -p zanshin-jj --lib hunks` -- expected: pass
- `cargo test -p zanshin-ffi --lib` and `cargo test -p zanshin-ffi --test it diff_ffi::` -- expected: pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean
- `cargo make --allow-private test-core` (or `flutter test packages/zanshin_core/test/ffi/diff_test.dart`), `dart analyze --fatal-infos --fatal-warnings packages/zanshin_core`, `dart format --set-exit-if-changed packages/zanshin_core` -- expected: pass/clean
- No full gate (`cargo make test`/`test-full`/`coverage`) — story-loop gate rule. Parity oracle not needed (a new read verb; no existing verb changes).

**Verification notes (run on 2026-10-31; full gate deferred to the story loop by its gate rule):**
- `cargo make codegen` -- succeeded twice (implementation, review doc patch); only `envelope_generated.rs` and `envelope_zanshin.ffi_generated.dart` changed.
- `cargo test -p zanshin-jj --test it -- diff:: hunks:: api_stability::` -- 81 passed after implementation, 82 after the review patches (the `diff::` filter also matches `diffedit::`).
- `cargo test -p zanshin-jj --lib -- hunks every_verb_resolves_for_its_cli_command` -- 11 passed (incl. the new `records!(repo, DIFF, diff(...))` entry).
- `cargo test -p zanshin-ffi --lib` -- 235 passed; `cargo test -p zanshin-ffi --test it diff_ffi::` -- 1 passed (before and after the review patches).
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` -- clean. `cargo fmt --all --check` -- clean.
- `cargo make --allow-private test-core` -- 1167 passed, after the review patches.
- `dart analyze --fatal-infos --fatal-warnings packages/zanshin_core` -- no issues; `dart format --set-exit-if-changed packages/zanshin_core` -- 0 changed.
- Follow-up review pass (2026-10-31): `cargo test -p zanshin-jj --test it diff::` -- 31 passed (3 new tests); `cargo test -p zanshin-jj --lib hunks` -- 10 passed (fingerprint hex locked); `cargo clippy -p zanshin-jj --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean; `dart analyze --fatal-infos --fatal-warnings packages/zanshin_core` -- no issues; `dart format --set-exit-if-changed packages/zanshin_core` -- 0 changed. No FFI/schema change (no codegen), no verb change (no oracle).
- Not run: the parity oracle (no existing jj verb changed; `diff` is a new read verb whose only repo effect is the shared pre-verb snapshot), coverage and the full gate (story-loop gate rule).

## Auto Run Result

Status: done.

**Summary.** `zanshin_jj::Repo::diff(&DiffOptions) -> Result<RevisionDiff, MutateError>` is `jj diff` as data (CLI command `diff`): `DiffRevisions::Revision` (`-r`, default `@`; the merged parents' tree against the revision's, copy records over every parent) or `FromTo` (an absent side `@`), copy records filtered on the target, prefix `paths` with the `jj.paths_unmatched` warning, `summary` (hunks dropped, everything else equal), and a pin (`operation_id` post-snapshot, `commit_id`, `from_commit_id`). It shares `hunks.rs`' `DiffReader` with `compute_hunks`, now over `diff_stream_with_copies` (left side at the copy source, right at the target; a copy has no sections). `FileDiff` gains `kind` (`ChangeKind`, carrying `from_path`), `removed` / `added` and a blake2b `fingerprint` of the changed lines. The wire `FileDiff` / `Diff` tables gain the same fields and pins; `diff_to_envelope` takes a `RevisionDiff`; the Dart decoder carries them. Word diff and highlighting stay skipped (line-level first).

**Files changed.**
- `crates/zanshin-jj/src/hunks.rs` -- `Repo::diff`'s body, `DiffOptions`/`DiffRevisions`/`RevisionDiff`, copy-aware reader, kinds, counts, fingerprint, unit tests.
- `crates/zanshin-jj/src/repo.rs` -- `Repo::diff` + registry `records!` entry. `src/lib.rs` -- re-exports. `src/status.rs` -- `ChangeKind` derives `Clone, PartialEq, Eq`.
- `crates/zanshin-jj/tests/it/diff.rs` (new) + `main.rs` -- the matrix rows; `tests/it/hunks.rs`, `tests/it/api_stability.rs` -- new fields and surface.
- `schemas/envelope.fbs` + regenerated `envelope_generated.rs` / `envelope_zanshin.ffi_generated.dart` -- appended fields.
- `crates/zanshin-ffi/src/diff.rs` -- builder over `RevisionDiff`, round-trip tests; `src/status.rs` -- shared `change_kind_offset`; `tests/it/diff_ffi.rs` -- real-repo wire test via `repo.diff`.
- `packages/zanshin_core/lib/src/ffi/diff.dart`, `status.dart` (`mapChangeKind` library-visible), `test/ffi/diff_test.dart` -- Dart models, decoder, tests.
- `docs/ffi-abi.md` -- the `Diff` payload's 5.6 fields; `epics.md` -- Story 5.6 "Delivered" note; `sprint-status.yaml` -- 5-6 done; `epic-5-context.md` -- recompiled in step-01 (epics.md was newer); `deferred-work.md` -- "Surfaced in Story 5.6".

**Review.** 28 findings: 0 high, 3 medium, 19 low, 6 false. Patched: 3 medium (the registry entry, a FromTo rename test, a dirty-@ operation-pin test) and the low doc entries (fingerprint's option/config dependency and content-only scope, `hunks.rs` module doc, ffi-abi heading, fingerprint length, saturating counts). Deferred: 1 (a renamed/copied file cannot be selected through `select_tree` as one entry — Story 10.26; mirrored in deferred-work.md). Rejected, with reasons in the Review Triage Log: option echo fields, summary computing hunks, the binary-hash allocation, the duplicated classifier, untested shared error paths, Dart `?? ''` defaults (three rows), the FFI test's kind mapping and wildcard (two rows), prefix paths instead of filesets, wire tests for summary/warnings; as false: the `from_path` conversion claim and the intent auditor's notes on the zanshin-jj location, language detection, single revision, the extern and the verification notes.

**Follow-up review recommended: true.** This first pass patched 3 medium entries (two or more). The unverified risk: per-file coverage of `crates/zanshin-jj/src/hunks.rs` — the backend-error closures in `add_copy_records` and `diff` have no test that reaches them, and the ratchet is measured only by the story loop's final gate.

**Verification.** See the verification notes above; every targeted command passed.

**Residual risks.**
- Coverage of `hunks.rs` (above) and `crates/zanshin-ffi/src/diff.rs` is measured only at the loop's final gate.
- Rust-written `Diff` bytes are first decoded in Dart once Story 5.8's extern and its real-cdylib test land.
- `ChangeKind::Copied` is only round-tripped synthetically: the git backend's copy records produced no copy in any fixture.

**Follow-up review pass (2026-10-31).** 25 findings: 0 high, 2 medium, 13 low, 3 false (7 carried from the first pass). Patched: 2 medium (fingerprint hex locked against a jj-lib encoding change; `context`/`whitespace` through `Repo::diff`) and 6 low (target-only path filter, rename hunk lines read at the source, rename language from the target, `ChangeKind` and Dart `fingerprint` docs). Deferred: none. Rejected, with reasons in the triage log: the carried rows, wire `kind` default, the end-to-end copy test, the type-change fingerprint, the unit-level fingerprint row, multi-parent copy accumulation, `compute_hunks` wire serialization. Added `a_missing_object_is_a_backend_error` for the backend-error closures in `add_copy_records` / `diff` that a deleted object reaches. Files: `crates/zanshin-jj/tests/it/diff.rs` (3 new tests, 2 extended assertions), `crates/zanshin-jj/src/hunks.rs` (locked hex), `crates/zanshin-jj/src/status.rs` and `packages/zanshin_core/lib/src/ffi/diff.dart` (docs). Follow-up review recommended: false (no high patched). Residual: `add_copy_records`' stream-error closure and `merge_commit_trees`' closure stay unreached; coverage is measured at the loop's final gate.
