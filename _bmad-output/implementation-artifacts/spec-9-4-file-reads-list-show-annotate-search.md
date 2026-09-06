---
title: 'Story 9.4: File reads — `file list`, `file show`, `file annotate`, `file search`'
type: 'feature'
created: '2026-09-03'
status: 'done'
baseline_revision: 'c6f90d35724ca611c76c380a08a08baef16f790b'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      An omitted revision means the LAST-SNAPSHOTTED `@`, not the working copy's on-disk
      state, because Zanshin never snapshots.
    evidence: |-
      The CLI's `workspace_helper` snapshots before all four `jj file` commands, so
      `jj file list` there sees uncommitted on-disk edits while these verbs see the last
      snapshot. Pre-existing project decision D2 (`status.rs:82-89`, `revset.rs:61-62`);
      `LockedWorkingCopy::{snapshot,reset}` is Story 9.22. The intent contract mandates
      recording it here. All four verbs stay fully useful without it — any revision other
      than `@` is pure committed-tree work.
    location: >-
      crates/zanshin-jj/src/file.rs (head_commit) — Story 9.22
    severity: medium
  - summary: >-
      "The workspace has no working-copy commit" flattens to `jj.jj_lib_error` although
      `jj.no_working_copy` is registered and used by `status`.
    evidence: |-
      `op_support::resolve_or_wc` reports the missing-`@` case as `ResolveError::Backend`,
      which becomes `FileError::Backend`. That is the default call shape for a GUI file
      browser (`revision: null`). It cannot be fixed inside this story: the helper is shared
      verbatim with the mutation verbs, whose observable behavior an acceptance criterion
      requires to stay byte-identical after the lift. Fixing it is a crate-wide change that
      should move `mutate.rs` and `file.rs` together.
    location: >-
      crates/zanshin-jj/src/op_support.rs (resolve_or_wc)
    severity: medium
  - summary: >-
      `FileSearch` carries no `skipped` channel, so a GUI cannot tell "no match in this file"
      from "this file's blob could not be read".
    evidence: |-
      `file_search` silently drops `MaterializedTreeValue::AccessDenied`, where the CLI prints
      "Skipping '…' due to permission error: …" (`cli/src/commands/file/search.rs` @ v0.44.0).
      The divergence is documented in the module doc, but `FileContents` has a `skipped`
      vector for exactly this and `FileSearch` does not. Adding one is a wire change
      (`.fbs` + codegen + Dart decoder) beyond this story's settled result shape.
    location: >-
      crates/zanshin-jj/src/file.rs (file_search) + schemas/envelope.fbs (FileSearch)
    severity: low
    resolved: >-
      RESOLVED 2026-09-05 (spec-epic-9-followup-e-payload-widenings, commit 28a9aaa). file_search now returns a
      FileSearch { matches, skipped } struct mirroring FileContents and reusing SkippedPath
      rather than minting a second type; the change goes through the Repo facade, the extern "C"
      doc, schemas/envelope.fbs (vtable slot 6, the same slot FileContents uses), the Dart model
      and both worker seams. skipped carries ONLY AccessDenied, because that is the single case
      jj file search warns about (cli/src/commands/file/search.rs:109-115 @ v0.44.0) — Symlink,
      GitSubmodule and OtherConflict are skipped SILENTLY there (:134, :159-160), the exact
      opposite of jj file show — and the reason string is search's OWN sentence
      ("Skipping '<path>' due to permission error: {e}"), not render_entry's show wording, so
      the two verbs' contracts stay distinct. The witness is INLINE in src/file.rs rather than
      in tests/: MaterializedTreeValue::AccessDenied comes from exactly one jj-lib error
      (BackendError::ReadAccessDenied), raised by exactly one backend — the testing-gated
      SecretBackend, which refuses any path containing "secret" — and Repo::open hardcodes
      default_backend_factories(), which this change deliberately does NOT widen, so the test
      builds the Workspace itself with an add_backend(SecretBackend::name(), ...) factory and
      calls the pub(crate) file_search directly. That is also what keeps the new arm covered.
      jj-lib with features = ["testing"] went into zanshin-jj's [dev-dependencies] only, so
      cargo build and the shipped cdylib never enable it. The eight existing file_search rows
      moved to the new return type, and the symlink row's silent-skip claim plus the no-match
      row are now checkable via skipped.is_empty(). No fixture was regenerated.
  - summary: >-
      `docs/ffi-abi.md` has been stale since Story 4.9 — it documents none of Epic 9's
      wrappers, payload discriminants, or the `AbsorbSkippedPath` → `SkippedPath` rename.
    evidence: |-
      Its "Exported symbols" section stops at `zanshin_repo_convert` / `zanshin_graph_slice` /
      `zanshin_log_defaults`; `zanshin_restore`, `zanshin_absorb` and the four file reads
      appear nowhere. Stories 9.1 and 9.3 did not update it either, so this is accumulated
      drift rather than a Story 9.4 regression, and closing it is a doc pass across Epic 9.
    location: >-
      docs/ffi-abi.md
    severity: low
    resolved: >-
      RESOLVED 2026-09-06 by spec-epic-9-followup-g-ffi-abi-doc-pass. The stale
      `## Exported symbols (Story 3.4c)` heading was replaced by a `## Symbol index` covering
      all 47 exported symbols — the four `zanshin_file_*` reads included, with their request
      tables and `FileList` / `FileContents` / `FileAnnotation` / `FileSearch` payloads — plus
      a new `## Request-buffer contract` section. The `AbsorbSkippedPath` → `SkippedPath`
      rename turned out to be a NON-issue for this document: neither name ever appeared in
      `docs/`, so the gap was coverage, not a stale name, and it is closed by
      `zanshin_absorb`'s row naming the `AbsorbResult` payload.
      `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs` guards the index against re-staling.
  - summary: >-
      `nameOnly` cannot be pinned by any Dart-side assertion.
    evidence: |-
      Proving the flag reached Rust needs a file with several matching lines, and no shipped
      verb can write a tree from Dart (`test/worker/file_test.dart`'s SCOPE NOTE). `paths`,
      `pattern` and `revision` all have an error-producing value that witnesses them; a
      boolean has none. It is covered in Rust
      (`file_ffi.rs::file_search_round_trip_carries_name_only_and_the_path_filter`); only the
      Dart hops are unwitnessed. A write verb (Story 9.22) or an exposed request-bytes builder
      would close it.
    location: >-
      packages/zanshin_core/test/worker/file_test.dart
    severity: low
  - summary: >-
      `isolate.dart` now holds a dozen verbatim copies of the synthesized `ffi.invalid_handle`
      envelope, four of them added by this story.
    evidence: |-
      Each worker switch arm rebuilds the same ~12-line `fbs.EnvelopeObjectBuilder` for the
      closed-handle case. Extracting one `_invalidHandleEnvelope(handleId)` helper would
      remove roughly 130 lines file-wide, but it touches eight arms this story does not own —
      a separate focused refactor, not a surgical change here.
    location: >-
      packages/zanshin_core/lib/src/worker/isolate.dart
    severity: low
    resolved: >-
      RESOLVED 2026-09-05 (spec-epic-9-followup-a-dedupe-ffi-helpers, commit a64d1c5). The count
      had grown to 33 by Story 9.8, not a dozen. One top-level private `_invalidHandleEnvelope(
      handleId)` before `_replyRepoOp` now returns the identical envelope (`ok: false`,
      `code: 'ffi.invalid_handle'`, `context: 'unknown or closed handleId: $handleId'`) and every
      arm calls it, removing ~230 lines. Each arm keeps its own per-arm `log.warning`, whose text
      differs and was never part of the duplication, and the `internal.dispatch_error` envelope is
      untouched. Behaviour-preserving: the 14 `*_on_closed_handle_surfaces_ffi_invalid_handle`
      worker tests are the witnesses.
  - summary: >-
      `file_annotate` does not reproduce the CLI's root-commit fallback for an origin commit
      that is absent from the store.
    evidence: |-
      The CLI substitutes the root commit when `get_commit_async` fails for a line's origin
      (shallow-then-unshallowed repos); this API propagates the store failure as
      `FileError::Backend` instead, documented as a `# KNOWN DIVERGENCE`. No fixture can
      construct the state, so the fallback branch would be permanently unreachable code and
      the coverage ratchet would reject it.
    location: >-
      crates/zanshin-jj/src/file.rs (file_annotate)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Zanshin can list *changes* but cannot read *file content*. Nothing in the surface
answers "what files are in this revision", "show me this file at that revision", "who wrote this
line", or "which files contain this string" — so a GUI file browser, viewer, blame gutter and
search box all have to shell out to the CLI. Epic 9 Tier A closes that with the four `jj file`
read verbs.

**Approach:** Add a new `zanshin-jj` noun module `file.rs` with four typed read operations —
`file_list`, `file_show`, `file_annotate`, `file_search` — implemented against jj-lib
(`MergedTree::entries_matching` / `path_value`, `conflicts::materialize_tree_value`,
`annotate::FileAnnotator`, `str_util::StringPattern`), and lift all four through the full
surfacing chain Story 9.3 established: `.fbs` request/payload tables → `extern "C"` → committed
codegen → Dart adapter / `WorkerCommand` / `ZanshinWorker` / `RepoHandle` → tests.

## Boundaries & Constraints

**Always:**
- The jj CLI's **observable behavior at tag `v0.44.0`** is the oracle (NFR-R-2). Read prior art
  with `git -C ../jj show v0.44.0:cli/src/commands/file/{list,show,annotate,search}.rs`; jj-lib is
  vendored at `~/.cargo/registry/src/*/jj-lib-0.44.0/`. Every default, refusal and skip rule below
  was read there, not inferred.
- **Full surfacing chain per verb** (epic-9-context.md "Definition of done per verb", repeated in
  `sprint-status.yaml`'s Epic 9 header): `.fbs` → typed `zanshin-jj` op → `zanshin-ffi`
  `extern "C"` + `cargo make codegen` → Dart worker command → tests, where tests mean a
  `zanshin-jj` integration test **plus** a `packages/zanshin_core` worker test per `extern "C"` fn
  (the ratchet's extern-fn guard has no other coverage source).
- No `jj_lib` type in a public position (`lib.rs:17-28`; enforced by `tests/api_stability.rs` and
  the `test-jj-adapter-hygiene` Makefile gate). Every jj-lib failure flattens to a `String`.
- `#![deny(missing_docs)]` (`lib.rs:3`) — every `pub`/`pub(crate)` item needs a doc comment.
- Re-resolve to head per call (ADR-0002); effective config re-read per call, never cached.
- Reads write **no operation**: `git status --porcelain`-equivalent of the op log is unchanged by
  every one of the four verbs, including on refusal.
- Clippy pedantic `-D warnings`; `rustfmt`; commit on `main` with `--no-gpg-sign`; never edit git
  config.
- The gate is the definition of done: `cargo make test` green. Floors after `epsilon_pct = 0.10`:
  every `crates/zanshin-ffi/src/*` file touched is at **100.00** except `graph`/`handle`/`logging`/
  `tracing_init`/`watcher`; `crates/zanshin-jj/src/repo.rs` ≥ **94.34**, `mutate.rs` ≥ **97.32**,
  `op_support.rs` ≥ **99.59**, `config.rs` = **100.00**. New files must clear
  `new_file_floor_pct = 80.00`.

**Block If:**
- The `Payload` union's next free discriminants (15–18) are contested by another in-flight story.
  Union member order **is** the wire discriminant; two stories cannot both take slot 15.
- `jj_lib::annotate::FileAnnotator`'s per-line result cannot be projected into owned
  `String`/`Vec<u8>`/`u32` fields without naming a `jj_lib` type in a **public** position. (It
  should not be: `LineOrigin` is `CommitId` + `usize`.)

**Never:**
- **No fileset DSL.** `paths` entries stay repo-relative strings interpreted as prefixes
  (`PrefixMatcher`), exactly as Story 9.3 settled it; this story is where that decision is
  settled "once for both" (9.3's deferred item). `glob:` / `~` / `all()` are not accepted.
- **No working-copy snapshot.** Zanshin never snapshots (D2, `status.rs:82-89`,
  `revset.rs:61-62`); `LockedWorkingCopy::{snapshot,reset}` is Story 9.22. An omitted `revision`
  means the **last-snapshotted** `@`. Document it; record it as deferred.
- **No terminal-UX parameters.** `-T/--template` (all four), `--line-number` (search) are output
  formatting for a text terminal, which ADR-0003 replaces — the typed result always carries the
  structured fields those flags would have rendered. `--name-only` IS carried through, because it
  changes the *work done* (stop scanning a file at its first match), not the result shape.
- **No annotate domain parameter.** The CLI hardcodes `RevsetExpression::all()` and carries an
  upstream TODO about exposing one; jj-lib warns a non-contiguous domain silently under-reports.
  Mirror the CLI exactly.
- No MCP tool — `crates/zanshin-mcp/src/main.rs` is a 5-line stub and the tool surface is Epic 7;
  "optional MCP tool" is a no-op here.
- Do not regenerate fixtures. Do not repoint `JJ_CONFIG`. Do not lower `coverage-baseline.txt` or
  add an `exclude_prefix`. Do not touch generated files except via `cargo make codegen`.
- Do not add a crate (`test-cargo-hygiene` pins exactly 8 tracked `Cargo.toml`).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| list, happy | `revision=A` (2 files), `paths=[]` | one `FileEntry` per file, in `entries_matching` (tree) order, `file_type=File` | No error expected |
| list, default revision | `revision=None` | entries of `@` (last-snapshotted) | No error expected |
| list, prefix filter | `paths=["dir"]` | only entries under `dir/` | No error expected |
| list, empty-string path | `paths=[""]` | matches everything (root is a prefix of every path) — same as `paths=[]` | No error expected |
| list, executable | tree holds an executable file | that entry has `executable=true` | No error expected |
| list, symlink | tree holds a symlink | `file_type=Symlink`, `executable=false` | No error expected |
| list, conflicted path | conflicted merge | `file_type=Conflict`, `conflict_side_count == simplified side count` | No error expected |
| show, single file | `paths=["a.txt"]` | one `ShownFile` with the exact bytes; `skipped` empty | No error expected |
| show, directory prefix | `paths=["dir"]` | one `ShownFile` per file under `dir/`, recursively | No error expected |
| show, conflicted file | `paths=["conflicted.txt"]` | content is the **materialized** merge (markers per the effective `ui.conflict-marker-style`), `conflict=true` | No error expected |
| show, symlink / submodule | `paths=["link"]` | no `ShownFile`; one `skipped` entry with jj-lib's reason | No error expected |
| show, single absent path | `paths=["nope.txt"]` | — | `PathNotFound { path }` → `jj.path_not_found` |
| show, absent among many | `paths=["a.txt","nope.txt"]` | `a.txt` is returned; the missing path is simply absent from the result | No error expected |
| show, no paths | `paths=[]` | — | `InvalidInput` (the CLI marks FILESETS `required`) |
| annotate, happy | `a.txt` introduced by `A`, one line edited by `B`, `revision=B` | one line per file line; each carries the originating `commit_id` + `change_id` and the 1-based `original_line_number`; `origin_found=true` | No error expected |
| annotate, absent path | `path="nope.txt"` | — | `PathNotFound { path }` |
| annotate, directory | `path="dir"` | — | `NotAFile { path }` → `jj.not_a_file` |
| annotate, symlink | `path="link"` | — | `NotAFile { path }` |
| annotate, conflicted file | every side is a file/absent | annotates the materialized content (CLI accepts it: `to_file_merge().is_some()`) | No error expected |
| search, happy | `pattern="needle"` | one `SearchMatch` per matching line: path, 1-based `line_number`, raw line bytes | No error expected |
| search, pattern kind | `pattern="substring:ndl"` | `kind:pattern` split exactly as the CLI; bare pattern defaults to kind `regex` | No error expected |
| search, invalid pattern | `pattern="(" ` | — | `InvalidInput` (jj-lib's `StringPatternParseError` verbatim in `reason`) |
| search, `name_only` | file with 3 matching lines | exactly one `SearchMatch` for that file (scan stops at the first match) | No error expected |
| search, conflicted file | conflicted path matching on one side | one match per matching side line; `conflict_side` names the 0-based side, line numbers restart per side | No error expected |
| search, symlink / submodule | tree holds them | silently not searched (CLI parity) | No error expected |
| search, no match | pattern matches nothing | empty result | No error expected |
| any verb, bad revision | `revision` malformed, absent, only-hidden, or **divergent** | — | `ChangeNotFound { id }` → `jj.change_not_found` |
| any verb, bad path | a `paths`/`path` entry with a leading/trailing `/` or `//` | — | `InvalidInput` (offending path in `reason`) |
| any verb, op log | after any call, success or refusal | op-log head is byte-identical to the pre-call head | No error expected |
| FFI, null request | `data == NULL` | — | `ffi.null_pointer` |
| FFI, garbage request | `data` does not verify as the request table | — | `ffi.invalid_argument` |
| FFI, zero/stale handle | `handle == 0` | — | `ffi.invalid_handle` |

</intent-contract>

## Code Map

Every anchor below was read and verified against the working tree at baseline `c6f90d3`, and every
jj anchor at tag `v0.44.0`.

**Prior art (read-only, at the tag)**
- `v0.44.0:cli/src/commands/file/list.rs` — args `:30-58` (`-r` clap default `"@"`, `-T`,
  positional FILESETS, empty ⇒ all); `run()` `:66-94`: `resolve_single_rev` → `commit.tree()` →
  `parse_file_patterns` → `to_matcher()` → **`tree.entries_matching(matcher)`** → per-entry
  `value?`. **No refusals at all**; `print_unmatched_explicit_paths` is a trailing warning only.
- `v0.44.0:cli/src/commit_templater.rs:2665-2728` — `TreeEntry { path, value }` and the exact
  per-entry keyword set a GUI needs: `path`, `conflict` (`!value.is_resolved()`),
  `conflict_side_count` (`value.simplify().num_sides()`), `file_type`
  (`"file"|"symlink"|"tree"|"git-submodule"|""|"conflict"`), `executable`.
- `v0.44.0:cli/src/commands/file/show.rs` — args `:49-76` (FILESETS **`required = true`**);
  `run()` `:84-134`: the **single-path fast path** `:104-119` (`get_single_path` →
  `tree.path_value` → `value.is_absent()` ⇒ `user_error("No such path: …")`; non-tree ⇒ render one),
  otherwise `entries_matching` + `write_tree_entries` `:149-202`, which dispatches
  `materialize_tree_value(store, path, value, tree.labels())`: `File` ⇒ bytes,
  `FileConflict` ⇒ `materialize_merge_result(contents, labels, out, &options)`,
  `OtherConflict` ⇒ `id.describe(&labels)`, `Symlink`/`GitSubmodule` ⇒ warn "Path '…' exists but is
  not a file.", `AccessDenied(e)` ⇒ warn "…access is denied: {e}", `Absent`/`Tree` ⇒ `panic!`.
  Options are `ConflictMaterializeOptions { marker_style: env().conflict_marker_style(),
  marker_len: None, merge: store.merge_options().clone() }`.
- `v0.44.0:cli/src/cli_util.rs:962` + `:1074` — `conflict_marker_style` is
  `settings.get("ui.conflict-marker-style")`; the CLI's own default is
  `cli/src/config/misc.toml:45` `conflict-marker-style = "diff"`.
- `v0.44.0:cli/src/commands/file/annotate.rs` — args `:38-66` (**one** positional `path`, plain
  path via `parse_file_path`, **not** a fileset; `-r` falls back to `RevisionArg::AT`); `run()`
  `:74-112`: `path_value` → `is_absent()` ⇒ `"No such path: …"` → `to_file_merge().is_none()` ⇒
  `"Path exists but is not a regular file: …"` → `FileAnnotator::from_commit(&commit, &path)` →
  `annotator.compute(repo.as_ref(), &RevsetExpression::all())` (domain hardcoded; TODO at `:101`)
  → `to_annotation()`. `render_file_annotation` `:115-151` adds `+1` to both line numbers and
  collapses the `Err(origin)` "stopped outside domain" case to the root commit — a lossy display
  choice this story does **not** copy.
- `v0.44.0:cli/src/commands/file/search.rs` — args `:43-75` (`-p/--pattern` **required**,
  `--name-only` (`conflicts_with = "line_number"`), `-n/--line-number`, FILESETS, `-r`); `run()`
  `:83-165`: pattern `split_once(':')` → `StringPattern::from_str_kind(pat, kind)`, else
  `from_str_kind(whole, "regex")` → `to_matcher()`; then `entries_matching` +
  `materialize_tree_value`: `File` ⇒ `read_all` then `write_matches`, `FileConflict` ⇒ iterate
  `contents.adds()` per side (`:146-147`: line numbers restart per side, deliberately),
  `Symlink`/`OtherConflict`/`GitSubmodule` ⇒ silently skipped, `AccessDenied` ⇒ warn + continue.
  `write_matches` `:168-194` — `split_inclusive(b'\n')`, `enumerate()`, `i + 1` is the reported
  line number.
- `v0.44.0:cli/src/cli_util.rs:1598-1611` `parse_file_patterns` — empty ⇒ `FilesetExpression::all()`;
  `:3362-3386` `print_unmatched_explicit_paths` (a warning, not a refusal).

**jj-lib 0.44.0 (vendored, exact signatures)**
- `merged_tree.rs:256` `entries()`, `:261` `entries_matching<'m>(&self, &'m dyn Matcher) ->
  TreeEntriesIterator<'m>`, item `(RepoPathBuf, BackendResult<MergedTreeValue>)` (`:489`).
  **Sync iterator that `block_on`s internally** (`:495`, `:570`, `:629`) — fine here, `zanshin-jj`
  is sync. Doc `:247-255`: a subtree conflicting with a non-tree is emitted as a single entry and
  **not descended into**. `:218` `async path_value(&RepoPath) -> BackendResult<MergedTreeValue>`
  (no sync form at the pin), `:119` `labels()`.
- `merge.rs:734` `MergedTreeValue = Merge<Option<TreeValue>>`; `:760` `to_file_merge()`
  (`Some` iff every side is file-or-absent — annotate's guard), `:778` `to_executable_merge()`,
  `:876` `describe(&labels)`; `Merge::simplify()`, `num_sides()`, `is_resolved()`, `as_resolved()`.
- `conflicts.rs:207` `async materialize_tree_value(store, path, value, labels) ->
  BackendResult<MaterializedTreeValue>`; `:133` the 8-variant enum; `:161` `MaterializedFileValue
  { id, executable, copy_id, reader }` + `:171` `async read_all(&mut self, path)`; `:186`
  `MaterializedFileConflictValue { ids, labels, contents: Merge<BString>, executable:
  Option<bool>, … }`; `:326` `ConflictMaterializeOptions`; `:475` **sync**
  `materialize_merge_result_to_bytes(&Merge<T>, &ConflictLabels, &options) -> BString`;
  `:305` `enum ConflictMarkerStyle { Diff, DiffExperimental, Snapshot, Git }`.
- `annotate.rs:165` `async FileAnnotator::from_commit(&Commit, &RepoPath) -> BackendResult<Self>`
  ("if the file is not found, the result would be empty" — so the two guards must run first);
  `:219` `async compute(&mut self, &dyn Repo, &Arc<ResolvedRevsetExpression>) ->
  Result<(), RevsetEvaluationError>`; `:233` `to_annotation()`; `:74`
  `FileAnnotation::line_origins() -> impl Iterator<Item = (Result<&LineOrigin, &LineOrigin>,
  &BStr)>`; `:290` `LineOrigin { commit_id: CommitId, line_number: usize }` — **0-based**;
  `Err(origin)` means "search stopped outside the domain", not a failure.
- `str_util.rs:95` `StringPattern` (8 kinds), `:172` `from_str_kind(src, kind) ->
  Result<Self, StringPatternParseError>`, `:302` `to_matcher() -> StringMatcher`, `:504`
  `is_match_bytes`, `:513` `match_lines` (yields matching lines **without** indices — which is why
  the CLI re-splits in `write_matches`).
- `matchers.rs:120` `EverythingMatcher`, `:192` `PrefixMatcher::new`;
  `repo_path.rs:251` `RepoPathBuf::from_internal_string`.
- `store.rs:123` `root_commit_id()`, `:156` `get_commit_async`, `:102` `merge_options()`.

**Extend — `crates/zanshin-jj`**
- `src/file.rs` (**NEW**) — the four operations + their owned result types + `FileError`. Model it
  on `src/view.rs` (Story 9.2, the freshest read module): module doc `:3-9`, `be` converter `:70`,
  `pub(crate) fn f(workspace: &Workspace) -> Result<…>` shape, `#[must_use = "the Result must be
  used; drop it explicitly if intentional"]`, the head-resolve line
  `pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?` (`view.rs:89`).
- `src/mutate.rs` — `build_matcher` `:260-296` (verbatim doc incl. the empty-string-is-root rule
  and its pinning test), `resolve_commit` `:328-345` (empty-id panic guard, malformed / absent /
  only-hidden / **divergent** all ⇒ `ChangeNotFound`), `resolve_or_wc` `:302-316` (the `@` default
  and its `Backend("workspace has no working-copy commit")` spelling), `SkippedPath` `:223-232`,
  `be` `:236`.
- `src/op_support.rs` — the shared re-port home (ADR-0003); `immutable_user_expression` `:71` shows
  the `pub(crate)` helper style. This is where the two lifted helpers land.
- `src/change.rs:161-193` `get_change` — the READ-side resolver, deliberately *divergence-tolerant*
  (picks the first visible). `-r` is `resolve_single_rev`, which refuses ambiguity, so the four
  file reads follow `mutate.rs::resolve_commit`'s rule, **not** this one.
- `src/config.rs:74-105` `BUILTIN_CONFIG_TOML` (`[ui] log-synthetic-elided-nodes = true` is the
  existing `ui.*` entry), `:370-385` `load(repo)` ("re-read on every call — never cached"),
  `:397-416` `log_defaults` (`config.get::<T>(key)` + `value_error` mapping).
- `src/repo.rs` — read-facade shape: `status` `:117-128`, `list_tags` `:174-189` (the doc template),
  `eval_revset` `:314-362`; `workspace()` `:103`, `settings()` `:113`. Append the four methods
  after `list_remotes`/`log_defaults`.
- `src/lib.rs:30-44` modules, `:46-59` re-exports.

**Extend — wire + FFI**
- `schemas/envelope.fbs` — request-only block `:31-78` with its **APPEND-only field-order
  invariant** `:36-39`; union ledger `:80-91`; payload tables `:93-415` (`Status` `:127`,
  `Bookmarks` `:192`, `GraphSlice` `:358`, `AbsorbSkippedPath` `:392`, `AbsorbResult` `:409`);
  `union Payload` `:417-433` — **next free discriminant is 15**; the append-only note is inline at
  `:429`. Conventions: `snake_case` fields, `enum … : byte`, null-for-absence on strings and
  nested tables only, presence-flag pairs for optional scalars (`change_offset` /
  `has_change_offset` `:311-312`), and **no `[ubyte]` anywhere yet**.
- `crates/zanshin-ffi/src/file.rs` (**NEW**) + `pub mod file;` in `lib.rs:32-46` (alphabetical,
  between `events` and `ffi_strings`). Templates: `bookmarks.rs` (module doc `:3-7`, imports
  `:9-17`, `map_bookmarks_err` `:19-26`, `bookmarks_to_envelope` `:33-67` with the
  "children before parents" note, `extern "C"` `:84-100`); `crates/zanshin-ffi/src/repo.rs:128-147`
  (the request-reader module comment — the lifetime rationale for building the byte slice in-scope
  and returning **owned** structs), `:153` `reject_null_request`, `:164` `invalid_request`,
  `:176`/`:216`/`:239` the three readers, `:1010-1029` `zanshin_restore`'s call-site shape.
  Doc-comment shape cbindgen lifts: summary → semantics → "Returns a `FlatBuffers` `Envelope`
  carrying a `<Payload>` payload on success." → `# Errors` (one bullet per code) → `# Safety`
  (handle provenance, `0` ⇒ `ffi.invalid_handle`, caller-owned `data`, free the token once).
- `crates/zanshin-ffi/src/envelope.rs` — constants `:15-78` (`JJ_PATH_NOT_FOUND` `:27`,
  `JJ_CHANGE_NOT_FOUND` `:36`, `JJ_INVALID_INPUT` `:39`, `JJ_JJ_LIB_ERROR` `:32`,
  `FFI_NULL_POINTER` `:20`, `FFI_INVALID_ARGUMENT` `:24`, `FFI_INVALID_HANDLE` `:18`), each with a
  `/// AR-P-4:` doc line; `FfiErrorObj` `:95-99`; `build_mutation_result` `:154-173` (the
  shared-builder pattern for a table used both nested and top-level); `err` `:290`; `catch` `:332`.
  Single-noun payload builders live in the **noun file**, not here (`status.rs:41`,
  `bookmarks.rs:33`).
- `crates/zanshin-ffi/src/ffi_strings.rs:107` `ZanshinBuf`, `:122` `vec_into_token`.
- `docs/rust-error-codes.md:35-62` — the registry table; rows `jj.path_not_found`,
  `jj.change_not_found`, `jj.invalid_input`, `jj.jj_lib_error`; `:66-71` the four steps for adding
  a code. Story 9.1/9.3's "Also emitted — Story N" clause is the annotation style to copy.

**Extend — Dart (`packages/zanshin_core`)**
- `lib/src/ffi/file.dart` (**NEW**) — sections `// ── FFI adapter ──` / `// ── Dart models ──` /
  `// ── Decoder ──`. Templates: `status.dart:21-29` (adapter; `Uint8List.fromList(buf.bytes)`
  **copies** before `dispose()`), `:92-115` (the `decodeXEnvelope` / `…Internal` / `_decode…`
  triple and the wrong-union-variant `ffi.unknown` throw); `bookmarks.dart:38` (sealed-class model
  for discriminated wire fields); `mutate.dart:28-41` `_withRequestBytes` / `_withChangeIdListBytes`,
  `:49-53` `_rejectInteriorNul`, `:175-205` `zanshinRestore` (the request-buffer adapter),
  `:382-384` (null-for-absence rule), `SkippedPath` model.
- `lib/src/worker/commands.dart` — `sealed class WorkerCommand` `:3-17`, read subclass template
  `StatusCommand` `:68-78`, request-carrying `RestoreCommand` `:340-370`; append before
  `ShutdownCommand` `:407`.
- `lib/src/worker/isolate.dart` — `ZanshinWorker.status` `:497-502`, `graphSlice` `:536-554`;
  worker switch arms `StatusCommand` `:935-950` (the synthesized `ffi.invalid_handle` envelope via
  `fbs.EnvelopeObjectBuilder`), `RestoreCommand` `:1176`.
- `lib/src/worker/handle.dart` — `RepoHandle` `:30`, `_closed` `:38`, `status()` `:72-82`
  (non-`async` so the guard throws synchronously), `show`-scoped model imports `:3-11`.
- Generated, regenerate only via `cargo make codegen`: `lib/src/ffi/bindings.dart`,
  `lib/src/ffi/envelope_zanshin.ffi_generated.dart`, `crates/zanshin-ffi/src/envelope_generated.rs`,
  `crates/zanshin-ffi/include/zanshin_ffi.h`.

**Tests / gates**
- `crates/zanshin-jj/tests/view.rs` — the copy-paste harness (`ENV_GUARD`/`pin_env` `:25-38`,
  `make_test_settings`, `oracle_workspace` `:55-63`, `corrupt_op_heads` `:93-95` — the
  `Backend` driver). `tests/content_ops.rs:8-13` states the fixture constraint and `:38-116` the
  oracle helpers (`jj_repo`, `change_id_of`, `head_op_id` `:108`, `head_op_description` `:112`,
  `write_repo_config` `:116`); `:138-164` is the scenario-construction pattern.
- `crates/test-helpers/src/lib.rs` — `extract_fixture` `:41`, `add_commit_off_root` `:95`,
  `add_commit_with_files` `:167`, `tree_hex` `:212`, `add_conflicted_merge_off_root` `:294`,
  `add_conflicted_merge_with_extra_files` `:308`; private `multi_file_tree` `:134-151`, which
  **hardcodes `executable: false` and has no symlink path** — the one real gap this story must
  close. Crate is coverage-excluded (`coverage-baseline.txt:11`).
- `crates/xtask/src/tasks/gen_fixture.rs:143-161` — every fixture commit's tree holds exactly one
  file `commit-<n>.txt`; **no path survives across commits**, no conflicts, no executables, no
  symlinks. Regenerating fixtures is forbidden.
- `crates/zanshin-ffi/tests/status_ffi.rs` / `bookmarks_ffi.rs` — the read-FFI harness shape
  (`read_and_free`, `parse_envelope`, `open_handle`); `repo_write_ffi.rs:60-116` for the
  request-buffer variants and `:320` `open_fixture_with_repo_config`.
- `packages/zanshin_core/test/worker/mutate_test.dart:3-14` — the header that states this file is
  what credits each `extern "C"` fn in the ratchet's extern-fn guard (**the new worker test must
  carry that paragraph**); `test/worker/status_test.dart:40/:64/:103` — the three canonical cases
  (happy via `worker.initRepo`, `ffi.invalid_handle` after `handle.close()`, synchronous
  `StateError` from the `RepoHandle` guard). `test/ffi/mutate_test.dart:3-10` — synthetic-buffer
  decode-contract tests; note the Dart discriminant enum is `fbs.PayloadTypeId`.
- `crates/zanshin-jj/tests/api_stability.rs` — the alias block `:12-15` (running count comment),
  `sample_*` constructors `:94-171`, `api_surface_resolves` `:173` (**at clippy's
  `too_many_lines` ceiling** — Story 9.3 added a second test `content_ops_surface_resolves`
  `:304-325` for exactly that reason), and `:172-173`'s note that a visitor-generic method cannot
  be `fn`-pointer-pinned.
- `Makefile.toml` — `[tasks.codegen]` `:289-295`, `[tasks.verify-codegen]` `:348` (manual; refuses
  on a dirty tree), `[tasks.test]` `:47-72` (22 deps ending in `coverage`), `test-cargo-hygiene`
  `:205` (**exactly 8 tracked `Cargo.toml`**), `test-jj-adapter-hygiene` `:255` (no
  `pub use jj_lib` in `crates/zanshin-jj/src/`), `[tasks.coverage]` `:449` with the **extern-fn
  guard** `:537-564` (`FNDA:0,<name>` fails; `EXTERN_COV_ALLOW="zanshin_buffer_free"` only).
- `coverage-baseline.txt` — `epsilon_pct = 0.10`, `new_file_floor_pct = 80.00`, `exclude_prefix`
  for `crates/xtask/` and `crates/test-helpers/`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/op_support.rs` -- lift `build_matcher` and `resolve_commit` out of
  `mutate.rs` into `pub(crate)` helpers whose error is a plain reason (a small crate-internal enum
  distinguishing "not found" from "backend"), generalizing `resolve_commit`'s receiver from
  `&MutableRepo` to `&dyn jj_lib::repo::Repo` (it only calls `resolve_change_id` +
  `store().get_commit`, both on the `Repo` trait); keep thin mapping wrappers in `mutate.rs` so
  `MutateError` behavior stays byte-identical -- the alternative is a second copy of the
  empty-id-panic guard, the divergence rule and the empty-string-is-root rule, which would drift
  from the mutation verbs' semantics the first time either is touched.
- `crates/zanshin-jj/src/config.rs` -- add `ui.conflict-marker-style = "diff"` to
  `BUILTIN_CONFIG_TOML` and a `pub(crate)` getter reading it off the effective `StackedConfig` in
  `log_defaults`' style -- `file show` must materialize conflicts the way the user's own jj config
  says (epic-9-context: "config-derived defaults come from the existing per-operation layered
  config loader, rebuilt per call and never cached"), and `"diff"` is the CLI's own default at
  `cli/src/config/misc.toml:45`, surfaced as an editable pre-fill rather than a Rust constant.
- `crates/zanshin-jj/src/file.rs` (NEW) -- add `FileError` (`ChangeNotFound { id }`,
  `PathNotFound { path }`, `NotAFile { path }`, `InvalidInput { reason }`, `Config { reason }`
  (added during implementation -- see the Spec Change Log entry of 2026-09-03), `Backend(String)`), the
  `be` converter, and `pub(crate) fn file_list(workspace, revision, paths) ->
  Result<Vec<FileEntry>, FileError>` over `entries_matching`, projecting each entry into the CLI's
  own keyword set -- `FileEntry { path, file_type, executable, conflict_side_count }` with
  `enum FileType { File, Symlink, Tree, GitSubmodule, Conflict }`; document that `Tree` is
  unreachable through `entries_matching` (it recurses) but is modelled for totality.
- `crates/zanshin-jj/src/file.rs` -- add `pub(crate) fn file_show(repo, revision, paths) ->
  Result<FileContents, FileError>` reproducing the CLI's two branches: with exactly one path,
  `path_value` first (absent ⇒ `PathNotFound`, non-tree ⇒ render that one entry), otherwise the
  `entries_matching` walk; each entry through `materialize_tree_value`, with `File` ⇒ `read_all`,
  `FileConflict` ⇒ `materialize_merge_result_to_bytes` under the config-derived
  `ConflictMaterializeOptions`, `OtherConflict` ⇒ `describe(&labels)`, and
  `Symlink`/`GitSubmodule`/`AccessDenied` ⇒ a `SkippedPath` carrying the CLI's own wording. Takes
  `&Repo` (not `&Workspace`) because it needs the effective config; empty `paths` ⇒
  `InvalidInput`.
- `crates/zanshin-jj/src/file.rs` -- add `pub(crate) fn file_annotate(workspace, revision, path) ->
  Result<Vec<AnnotationLine>, FileError>`: `path_value` ⇒ `is_absent()` ⇒ `PathNotFound`,
  `to_file_merge().is_none()` ⇒ `NotAFile`, then `FileAnnotator::from_commit` +
  `compute(repo, &RevsetExpression::all())` + `to_annotation()`, projecting `line_origins()` into
  `AnnotationLine { commit_id, change_id, original_line_number, content, origin_found }` --
  the two guards must precede the annotator because jj-lib returns an EMPTY annotation for a
  missing file rather than an error; `change_id` is resolved once per DISTINCT commit (a
  `HashMap` join) instead of the CLI's per-line `get_commit_async`; `origin_found` preserves the
  `Ok`/`Err` distinction the CLI collapses to the root commit; `line_number` is deliberately
  absent (it is the 1-based index in the returned `Vec`).
- `crates/zanshin-jj/src/file.rs` -- add `pub(crate) fn file_search(workspace, revision, pattern,
  paths, name_only) -> Result<Vec<SearchMatch>, FileError>`: split `pattern` on the first `:` into
  `kind:pattern` (bare ⇒ kind `regex`) exactly as `search.rs:95-101`, `StringPattern::from_str_kind`
  failure ⇒ `InvalidInput`; then `entries_matching` + `materialize_tree_value`, re-splitting each
  file's bytes with `split_inclusive(b'\n')` + `enumerate()` for 1-based line numbers (jj-lib's
  `match_lines` yields no indices, which is why the CLI re-splits too); conflicts iterate
  `contents.adds()` with `conflict_side` set and line numbers restarting per side;
  symlinks/submodules/other-conflicts are silently skipped; `name_only` stops a file's scan at its
  first match.
- `crates/zanshin-jj/src/repo.rs` -- add the four `pub fn` facades (`file_list`, `file_show`,
  `file_annotate`, `file_search`) after `log_defaults`, in `list_tags`' exact doc style (summary +
  ADR-0002 re-resolve line + "Read-only; never shells to `jj file …`" + CLI-parity notes with
  `v0.44.0` anchors + `# Errors` bullet per variant + `#[must_use]`), each taking
  `revision: Option<ChangeId>` -- absent is the wire and API form of "the user did not supply it",
  which is what lets the CLI's own `@` default apply here instead of one this layer invented.
- `crates/zanshin-jj/src/lib.rs` -- re-export `FileEntry`, `FileType`, `ShownFile`, `FileContents`,
  `AnnotationLine`, `SearchMatch`, `FileError`; generalize `SkippedPath`'s doc so it reads as
  "a path an operation could not process, and the reason" rather than absorb-only -- it is reused
  verbatim by `file_show`.
- `crates/test-helpers/src/lib.rs` -- add an entry-spec helper (`add_commit_with_entries` over a
  small public `Entry { File, Executable, Symlink }` spec) generalizing the private
  `multi_file_tree`, which hardcodes `executable: false` and cannot build a symlink -- the
  committed fixtures contain no executable, symlink, or multi-file commit and regenerating them is
  forbidden, so `file_type`/`executable`/skip coverage is otherwise unconstructible.
- `schemas/envelope.fbs` -- append request tables `FileListRequest`, `FileShowRequest`,
  `FileAnnotateRequest`, `FileSearchRequest` to the request-only block; add payload tables
  `FileEntry` + `enum FileType : byte`, `FileList`, `ShownFile`, `FileContents`, `AnnotationLine`,
  `FileAnnotation`, `SearchMatch`, `FileSearch`; rename `AbsorbSkippedPath` to `SkippedPath` and
  reuse it for `FileContents.skipped` (WIP allows in-place schema edits with all callers updated in
  the same change — one Rust builder, one Dart decoder); append the four payloads to `Payload` as
  slots 15–18 and tick the ledger comment. File bytes are `[ubyte]` (the schema's first) because a
  tracked file is not guaranteed UTF-8; `SearchMatch.conflict_side` uses the established
  presence-flag pair.
- `crates/zanshin-ffi/src/file.rs` (NEW) + `pub mod file;` in `lib.rs` -- add `map_file_err`, four
  request readers in `read_restore_request`'s shape (owned structs, byte slice built and verified
  in-scope), the four payload builders, and `zanshin_file_list` / `zanshin_file_show` /
  `zanshin_file_annotate` / `zanshin_file_search`, each `(handle: u64, data: *const u8, len:
  usize)` with the full `debug!` → `catch` → `handle_from_raw` → decode → call → payload →
  `vec_into_token` body -- a request table (not C strings) for all four because each request is a
  composite whose `revision` must be distinguishably ABSENT, which is exactly the ADR-0001
  composite-input case Story 9.3 established.
- `crates/zanshin-ffi/src/envelope.rs` -- add `JJ_NOT_A_FILE = "jj.not_a_file"` with its
  `/// AR-P-4:` doc line -- "the path exists in the revision's tree but is not a regular file" is a
  condition no registered code expresses, and a GUI must distinguish it from "you mistyped the
  path" (`jj.path_not_found`) to say anything useful.
- `cargo make codegen` -- regenerate and commit `envelope_generated.rs`,
  `envelope_zanshin.ffi_generated.dart`, `include/zanshin_ffi.h`, `bindings.dart`; then run
  `cargo make verify-codegen` on a clean tree -- generated output is committed and the build never
  regenerates it.
- `packages/zanshin_core/lib/src/ffi/file.dart` (NEW) -- four adapters building their request
  bytes with the generated `…ObjectBuilder` inside `_withRequestBytes`, interior-NUL guards on
  every caller-supplied string, the model classes (`FileEntry`/`FileType`, `ShownFile`/
  `FileContents`, `AnnotationLine`, `SearchMatch`) and their envelope decoders in the
  `decodeXEnvelope` / `…Internal` / `_decode…` triple -- reuse `mutate.dart`'s `SkippedPath` model
  rather than defining a second one.
- `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` -- add
  `FileListCommand`/`FileShowCommand`/`FileAnnotateCommand`/`FileSearchCommand` (isolate-sendable
  fields only), the four `ZanshinWorker` methods, the four worker switch arms incl. the synthesized
  `ffi.invalid_handle` envelope, and the four `RepoHandle` methods with the synchronous `_closed`
  guard -- Model A: the UI never holds a raw pointer.
- `crates/zanshin-jj/tests/file_reads.rs` (NEW) -- cover every `zanshin-jj`-level row of the I/O
  matrix using `pin_env()`, `extract_fixture`, the new entry-spec helper and the conflicted-merge
  helpers, asserting against raw jj-lib oracles rather than a second call to the code under test,
  plus an explicit "op-log head unchanged" assertion on both a success and a refusal for each verb
  -- integration level is right: all four entry points are public `Repo` methods.
- `crates/zanshin-ffi/tests/file_ffi.rs` (NEW) -- per wrapper: a happy path that proves the payload
  actually carries the verb's distinguishing data (not merely a well-formed envelope), plus
  `ffi.null_pointer`, `ffi.invalid_argument`, `ffi.invalid_handle` and a bogus-revision
  `jj.change_not_found` case -- and carry `paths` / `name_only` / a non-default `revision` through
  the buffer in at least one test each, so a reader that hardcoded them would fail.
- `packages/zanshin_core/test/worker/file_test.dart` and `test/ffi/file_test.dart` (NEW) -- real
  cdylib round-trips for all four verbs (happy, `ffi.invalid_handle` after close, synchronous
  `StateError`) plus synthetic-buffer decode-contract and NUL-guard tests -- the worker file is
  what credits each new `extern "C"` fn in the ratchet's extern-fn guard, and must carry that
  header paragraph.
- `crates/zanshin-jj/tests/api_stability.rs` -- add a NEW `#[test] fn file_reads_surface_resolves()`
  (never extend `api_surface_resolves`, which is at clippy's `too_many_lines` ceiling) pinning the
  four `Repo` methods as `fn` pointers, `sample_*` constructors for every new struct, aliases for
  every new type, and each `FileError` variant constructed -- and update the running type count in
  the header comment.
- `docs/rust-error-codes.md` -- add the `jj.not_a_file` row and append "Also emitted — Story 9.4"
  clauses to `jj.change_not_found`, `jj.path_not_found` (widened: "also the path does not exist in
  the target revision's tree"), `jj.invalid_input`, `jj.jj_lib_error`, `ffi.null_pointer`,
  `ffi.invalid_argument` and `ffi.invalid_handle` -- the registry is canonical and every story that
  adds or emits a code updates it in the same change.

**Acceptance Criteria:**
- Given the workspace after this change, when `cargo make test` runs, then it passes end to end
  with no baseline lowered and no `exclude_prefix` added; every touched `crates/zanshin-ffi/src`
  file holds its baseline, the two new source files clear `new_file_floor_pct`, and the extern-fn
  guard reports every `zanshin-ffi` `extern "C"` fn covered.
- Given each of the four verbs, when the surfacing chain is inspected, then each has a `.fbs`
  request table, a `Payload` member, an `extern "C"` wrapper, regenerated **committed** codegen, a
  Dart adapter, a `WorkerCommand`, a `ZanshinWorker` method, a `RepoHandle` method, and at least
  one `packages/zanshin_core/test/worker` test that drives it through the real cdylib.
- Given any of the four verbs on any input — success, refusal, or empty result — when the op log is
  read afterwards, then its head is byte-identical to the pre-call head: a read never writes an
  operation, unlike the CLI, whose `workspace_helper` may snapshot first.
- Given `zanshin-jj`'s public API compared against the pre-change surface, then the only additions
  are the four `Repo` methods and `FileEntry`, `FileType`, `ShownFile`, `FileContents`,
  `AnnotationLine`, `SearchMatch`, `FileError`; all are pinned in `tests/api_stability.rs`, no
  `jj_lib` type appears in any public position, and `test-jj-adapter-hygiene` passes.
- Given the two helpers lifted into `op_support.rs`, when `crates/zanshin-jj/tests/mutate.rs` and
  `tests/content_ops.rs` run unchanged, then they still pass — the mutation verbs' observable
  behavior is byte-identical after the lift.
- Given the repo after `cargo make codegen`, when `cargo make verify-codegen` runs on a clean tree,
  then it reports no drift for `zanshin_ffi.h`, `bindings.dart`, `envelope_generated.rs` and
  `envelope_zanshin.ffi_generated.dart`.
- Given `docs/rust-error-codes.md`, when it is read, then it contains exactly one new row
  (`jj.not_a_file`) and the reused rows name Story 9.4 as an emitter.
- Given `cargo make test`'s `test-cargo-hygiene` gate, when it runs, then it still sees exactly
  eight tracked `Cargo.toml` files — this story adds no crate.

## Spec Change Log

### 2026-09-03 — `FileError::Config` added to the enumerated variant set

- **Triggering finding:** the shipped `FileError` carries six variants; the Tasks bullet
  enumerated five. The deviation was made during implementation and never recorded, so the
  spec's own enumeration, `Repo::file_show`'s `# Errors` doc, and both Dart error-code lists
  disagreed with the code (review pass 2026-09-03, four findings).
- **What was amended:** the `crates/zanshin-jj/src/file.rs` Tasks bullet now names
  `Config { reason }` and points here. Nothing inside `<intent-contract>` was touched.
- **Known-bad state avoided:** flattening a malformed `ui.conflict-marker-style` into
  `FileError::Backend` / `jj.jj_lib_error`. That would tell a GUI the *repository* is broken
  when the user's own config is, and it would make `file_show` the only config-reading verb in
  the crate that does not report `jj.config_error` (`log_defaults`, `graph_slice` and the Story
  9.1/9.3 mutations all do). `jj.config_error` is already in the registry, so the variant adds
  no new code -- it reuses one, which is why the "exactly one new row (`jj.not_a_file`)"
  acceptance criterion still holds.
- **KEEP:** `file_show` is the ONLY verb that reads config, so it stays the only verb that can
  return `Config`; `list`/`annotate`/`search` keep taking `&Workspace` and stay config-free.

## Review Triage Log

_Note: the review pass that ran immediately before the one below was interrupted by an
infrastructure failure after its patches had been dispatched but before its log entry was
written. Its 14 patch findings are present in the code but have no entry here; the pass below
re-reviewed the resulting tree in full, so its findings supersede that lost record._

### 2026-09-03 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 11: (high 0, medium 6, low 5)
- defer: 7: (high 0, medium 2, low 5)
- reject: 14: (high 0, medium 0, low 14)
- addressed_findings:
  - `[medium]` `[patch]` `Repo::file_show`'s `# Errors` omitted `FileError::Config` and
    asserted "these verbs have no separate config error", which the shipped enum contradicts
    — added the bullet, removed the false claim (`crates/zanshin-jj/src/repo.rs`).
  - `[medium]` `[patch]` `RepoHandle.fileShow` and `ZanshinWorker.fileShow` omitted
    `jj.config_error` from their error-code lists — added, naming `file_show` as the only file
    read that consults the effective jj config.
  - `[medium]` `[patch]` `map_file_err`'s `Config → jj.config_error` arm never crossed the FFI
    boundary in a test — added
    `file_show_surfaces_a_malformed_conflict_marker_style_as_jj_config_error` to
    `crates/zanshin-ffi/tests/file_ffi.rs`.
  - `[medium]` `[patch]` Dart `fileShow`'s `paths` defaulted to `const []` at all three layers
    although an empty list is always a refusal (the CLI marks FILESETS `required`) — made it a
    `required` named parameter in `ffi/file.dart`, `worker/isolate.dart` and `worker/handle.dart`;
    the runtime refusal is still pinned by an explicitly empty list.
  - `[medium]` `[patch]` `fileSearch`'s `paths` crossed no Dart assertion — deleting the
    argument at the worker arm or the handle left every Dart test green. Added
    `fileSearch_carries_the_path_filter_through_the_request_buffer`.
  - `[medium]` `[patch]` the `FileError::Config` deviation from the Tasks enumeration was
    unrecorded — logged in `## Spec Change Log` and the Tasks bullet amended.
  - `[low]` `[patch]` `no_file_read_wrapper_writes_an_operation` compared two unsorted
    `fs::read_dir` listings — both are sorted now.
  - `[low]` `[patch]` `crates/zanshin-jj/src/file.rs::res` had no unit test although
    `mutate.rs::res` does, leaving its `revision: None ⇒ empty id` arm unexercised — added the
    mirror test.
  - `[low]` `[patch]` `Repo::file_show`'s doc claimed every skipped path carries "the CLI's own
    wording" (false for the two cases the CLI `panic!`s on) and called `AccessDenied` "an
    unreadable blob" (a `read_all` failure aborts the call instead) — both phrases tightened.
  - `[low]` `[patch]` `enum FileType : byte` carried no append-only note although member order
    is the wire value — added, matching `union Payload`'s.
  - `[low]` `[patch]` `original_line_number`, `line_number` and `conflict_side` saturate at
    `u32::MAX` undocumented while `conflict_side_count` documents it — documented consistently
    in the Rust types and the `.fbs` field comments.

## Design Notes

**Scope is the full surfacing chain — derived, not assumed.** Four signals, the same ones Story 9.3
weighed: (1) epic-9-context.md states the per-verb definition of done as `.fbs` → `zanshin-jj` op →
`zanshin-ffi` + codegen → Dart worker command → optional MCP → tests, spelling out "an FFI-path
Dart test (needed for coverage attribution of each `extern "C"` fn)"; (2) sprint-status.yaml's
Epic 9 header repeats it; (3) in epics.md 9.4 sits under **Tier A — cheap (start here)** with the
`[R]` tag, exactly where 9.3 sat with `[M]`, unlike 9.2 which sat under `### Precursors` — and 9.2's
zanshin-jj-only outcome turned on a `Stream` having no wire form, which does not apply to four
finite, snapshot-shaped results; (4) Story 9.3 already built this chain, so there is a template
rather than an invention. MCP stays the one empty link for 9.3's reason.

**Which CLI flags survive the terminal-UX cut.** ADR-0003 replicates *what* the CLI does, not its
terminal UX. `-T/--template` renders text and is dropped everywhere (as it already is for `log`).
`--line-number` toggles a `path:N:` prefix on printed text — the typed result carries `line_number`
unconditionally, so the flag has nothing left to switch. `--name-only` is different in kind: it
stops scanning a file after its first match, so it changes the *work*, not the rendering; it is
carried through as a plain boolean, and the result shape is unchanged (each entry still carries its
first match), which is a superset of what the CLI prints. `-r`, `--pattern` and the path arguments
are pure pass-through (FR-JJ-17).

**Parameter currency: single revision → `ChangeId`.** All four CLI verbs take `-r <REVSET>` resolved
by `resolve_single_rev`, but every shipped Zanshin verb takes a `ChangeId` for a single revision —
`repo.rs:381-383` records that epics.md Story 6.1 fixed that signature, and Story 9.3 re-derived it.
`resolve_single_rev` *refuses* an ambiguous revision, which is why these reads follow
`mutate.rs::resolve_commit` (divergent ⇒ `ChangeNotFound`) rather than `change.rs::get_change`
(divergent ⇒ pick the first visible). That difference is the reason `resolve_commit` is lifted
rather than re-implemented.

**Paths are prefixes — this story settles the question 9.3 deferred.** The CLI parses `paths` with
`fileset::parse_maybe_bare`, whose *bare* form is exactly `prefix_path`, so `PrefixMatcher`
reproduces the CLI's observable behavior for the input a GUI produces (a file/directory selection);
an empty list is `EverythingMatcher`. The DSL is terminal *input language*, which ADR-0003 replaces
rather than ports — the same reasoning by which a GUI-supplied `TreeId` replaces the interactive
diff editor. `annotate` is unaffected: its `path` is a plain path in the CLI too
(`parse_file_path`, not a fileset).

**Why `file show` needs the config layer and the others do not.** Materializing a conflict requires
`ConflictMaterializeOptions.marker_style`, which the CLI reads from `ui.conflict-marker-style`
(default `"diff"`). Hardcoding it would bake in a decision the CLI leaves to the user's config
(FR-JJ-17), so `file_show` takes `&Repo` and reads the effective `StackedConfig` per call, while
`list`/`annotate`/`search` need no config and take `&Workspace` — the crate's established split
(`repo.rs:188` vs `:311`).

**Annotate is projected, not transcribed.** jj-lib gives `(Result<&LineOrigin, &LineOrigin>, &BStr)`
per line, where `Err` means "the search stopped outside the domain" — not a failure. The CLI
collapses that to the root commit id for display and then does one `get_commit_async` **per line**.
Neither is copied: `origin_found` keeps the distinction, and commit → change-id resolution is
deduplicated per distinct commit. `LineOrigin.line_number` is 0-based in jj-lib and the CLI adds 1;
this API reports the CLI's 1-based number and documents the base explicitly, because the two
conventions are one off-by-one apart.

**No working-copy snapshot — a pre-existing project decision, not a shortcut.** `status.rs:82-89`
and `revset.rs:61-62` document D2. The CLI's `workspace_helper` snapshots before all four commands
(and can therefore *write an operation from a read*), so `jj file list` there sees on-disk edits
while ours sees the last-snapshotted `@`. Story 9.22 owns `LockedWorkingCopy`. All four verbs stay
fully useful and fully testable without it — any `revision` other than `@` is pure committed-tree
work — so this ships documented and recorded as deferred.

**Traps to respect.** `entries_matching` is a sync iterator that `block_on`s internally on every
subtree descent; that is fine in this sync crate but must not be moved onto a runtime worker later.
It never yields a bare tree (it recurses) and never yields an absent entry — but a subtree that
conflicts with a non-tree is emitted as one entry and **not** descended into, so a GUI file tree
must render it as an opaque conflict rather than an empty directory. `FileAnnotator::from_commit`
returns an *empty* annotation for a missing file instead of an error, so the absent/not-a-file
guards must run first. `MaterializedFileValue::read_all` has no size cap and neither does
`materialize_merge_result*` — `file show` and `file search` therefore hold whole files in memory,
which the CLI avoids by streaming to stdout; that is a resource divergence, not a behavioral one,
and is recorded as a residual risk rather than papered over with an invented limit.

## Verification

**Commands:**
- `cargo make test` -- expected: green end to end (cargo test + clippy `-D warnings` + rustfmt +
  flutter/dart analyze+format + `cargo deny` + coverage ratchet + extern-fn guard). Run unpiped;
  capture the exit code. This is the single gate.
- `cargo make codegen` then `cargo make verify-codegen` -- expected: the second reports no drift.
  Run `verify-codegen` only on a clean tree; it refuses otherwise.
- `git -C ../jj show v0.44.0:cli/src/commands/file/list.rs` (and `show.rs`, `annotate.rs`,
  `search.rs`) -- expected: re-confirms the arg surface, guard ordering, skip rules and pattern
  parsing before relying on the anchors above.
- `git status --porcelain` -- expected: afterwards only intended files; the four generated files
  appear only together with the `.fbs`/`extern "C"` change that earned them; `coverage-baseline.txt`
  appears only if the ratchet raised it.

**Manual checks (if no CLI):**
- Diff the crate's `pub` items: confirm the additions are exactly the four `Repo` methods and the
  seven new types, and that no `jj_lib` type leaked into a public signature.

## Auto Run Result

Status: done
Blocking condition: none

### Summary of implemented change

The four `jj file` read verbs — `file list`, `file show`, `file annotate`, `file search` — are
implemented in a new `zanshin-jj` noun module against jj-lib and surfaced through the full chain
this epic requires: `.fbs` request + payload tables, `Payload` slots 15–18, four `extern "C"`
wrappers, regenerated committed codegen, a Dart adapter, four `WorkerCommand`s, four
`ZanshinWorker` methods and four `RepoHandle` methods. The jj CLI at tag `v0.44.0` is the
behavioral oracle throughout: guard ordering, refusal conditions, skip rules, the `kind:pattern`
split and the per-side conflict line numbering are ports of its observable behavior, not of its
terminal UX. `build_matcher`, `resolve_commit` and `resolve_or_wc` were lifted from `mutate.rs`
into `op_support.rs` behind a crate-internal `ResolveError`, with thin mapping wrappers left
behind so the mutation verbs' observable behavior is byte-identical after the lift. No read writes
an operation, on success or on refusal, and that is asserted at both the `zanshin-jj` and the FFI
layer.

### Files changed

- `crates/zanshin-jj/src/file.rs` (new) — the four typed read operations, their owned result
  types, and `FileError`.
- `crates/zanshin-jj/src/op_support.rs` — the three resolver/matcher helpers lifted out of
  `mutate.rs`, generalized to `&dyn Repo`.
- `crates/zanshin-jj/src/mutate.rs` — the helpers replaced by thin mapping wrappers.
- `crates/zanshin-jj/src/repo.rs` — the four public `Repo` facades.
- `crates/zanshin-jj/src/config.rs` — `ui.conflict-marker-style = "diff"` in the builtin config
  plus its effective-config getter.
- `crates/zanshin-jj/src/lib.rs` — re-exports for the seven new public types.
- `crates/zanshin-ffi/src/file.rs` (new) — four request readers, four payload builders and the
  four `extern "C"` wrappers.
- `crates/zanshin-ffi/src/envelope.rs` — the `jj.not_a_file` code; `crates/zanshin-ffi/src/lib.rs`
  and `repo.rs` — module wiring and the shared request-reader shape.
- `schemas/envelope.fbs` — four request tables, the payload tables, `enum FileType`, the
  `AbsorbSkippedPath` → `SkippedPath` rename, and `Payload` slots 15–18.
- Committed codegen: `crates/zanshin-ffi/src/envelope_generated.rs`,
  `crates/zanshin-ffi/include/zanshin_ffi.h`,
  `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`,
  `packages/zanshin_core/lib/src/ffi/bindings.dart`.
- `packages/zanshin_core/lib/src/ffi/file.dart` (new) — adapters, models and decoders;
  `lib/src/worker/{commands,isolate,handle}.dart` — commands, worker methods and handle methods.
- Tests: `crates/zanshin-jj/tests/file_reads.rs` (new), `crates/zanshin-ffi/tests/file_ffi.rs`
  (new), `packages/zanshin_core/test/{ffi,worker}/file_test.dart` (new),
  `crates/zanshin-jj/tests/api_stability.rs` (new pinning test),
  `crates/test-helpers/src/lib.rs` (the `Entry` spec helper — the committed fixtures hold no
  executable, symlink or multi-file commit and regenerating them is forbidden).
- `docs/rust-error-codes.md` — the `jj.not_a_file` row plus Story 9.4 emitter clauses.
- `coverage-baseline.txt` — two new files, `zanshin-jj/src/repo.rs` raised 94.34 → 94.92 and
  `zanshin-jj/src/file.rs` raised 97.76 → 98.15 by the review pass's added test.

### Review findings breakdown

- Patches applied: 11 (high 0, medium 6, low 5) — see the 2026-09-03 entry in the Review Triage
  Log for each finding and the action taken.
- Items deferred: 7 (medium 2, low 5) — recorded in the frontmatter `deferred` list.
- Items rejected: 14 — chiefly the cross-verb guard-ordering precedence (every ordering yields a
  valid refusal), the unreachable `render_entry`/`file_search` defensive arms, the per-verb
  repetition of the `@`-default test (all four route through one `head_commit` helper, pinned
  once), the deliberate `mem::forget` in the FFI test harness (the established pattern in
  `change_ffi.rs` and `repo_write_ffi.rs`), the unchanged `mutate.rs`/`op_support.rs` baselines
  (the ratchet ran and held them within `epsilon_pct`), and a claim that `file_search`'s skip
  comment misstates CLI parity (it names the divergence explicitly).
- Follow-up review recommended: **true**. Patched severities: high 0, medium 6, low 5; score
  = 3 × 6 + 1 × 5 = 23, at or above the threshold of 5.

### Verification performed

- `cargo make test` — green end to end after the patches (cargo test + clippy pedantic
  `-D warnings` + rustfmt + flutter/dart analyze + format + `cargo deny` + the coverage ratchet).
  Overall coverage 99.07% (6845/6909 lines over 38 files); the ratchet raised
  `crates/zanshin-jj/src/file.rs` and the updated `coverage-baseline.txt` is committed with the
  test that earned it. `extern-coverage` reports every `zanshin-ffi` `extern "C"` fn covered.
- `cargo make verify-codegen` — run on the clean tree after the finalization commit; no drift.
  The review pass's `.fbs` edits are deliberately non-doc `//` comments, which `flatc` does not
  propagate into generated code.
- `git status --porcelain` — clean after finalization.

### Residual risks

- **Whole files are held in memory.** `file show` and `file search` buffer each file's full
  contents (`MaterializedFileValue::read_all` and `materialize_merge_result_to_bytes` have no size
  cap) where the CLI streams to stdout. A resource divergence, not a behavioral one; no invented
  limit was added to paper over it.
- **The four verbs' guard order is fixed by code shape, not by a pinned contract.** A call with
  two simultaneous faults (a bad revision *and* a bad path, or a broken config *and* a bad
  revision on `file_show`) surfaces whichever guard runs first. Every outcome is a valid refusal,
  but the precedence is not asserted anywhere.
- **`AnnotationLine.origin_found == false` is unreachable with any constructible fixture.** The
  domain is `all()`, so the `Err(origin)` branch needs a shallow-then-unshallowed repo, which is
  also the state where the subsequent store read fails and the call becomes `Backend`. The field's
  contract is exercised only through synthetic buffers.
- **`nameOnly` reaches Rust unwitnessed by the Dart layer** — see the `deferred` entry; it is
  covered in `file_ffi.rs`, but no Dart-side assertion changes value with the flag.
