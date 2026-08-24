---
title: 'Story 4.8: CLI-parity log rows — metadata-enriched, self-contained GraphSlice rows'
type: 'feature'
created: '2026-08-23'
status: 'done'
baseline_revision: '35bee2170a5eb10292ef0cfed77c84939208b1b2'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
  - '{project-root}/_bmad-output/specs/spec-4-8-log-rows-cli-parity/SPEC.md'
  - '{project-root}/_bmad-output/specs/spec-4-8-log-rows-cli-parity/cli-log-parity.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The `syntheticElided` flag is never exercised as `false`, nor against elidable
      ancestry, through the real cdylib from Dart — the Dart-to-C `bool` hop is unverified.
    evidence: |-
      `synthetic_elided` is the project's first and only `bool` at the C surface. The Rust
      extern fn honours both values (`graph_slice_synthetic_elided_toggle_adds_rows_and_off_keeps_plain_indirect_edges`
      in crates/zanshin-ffi/tests/graph_ffi.rs), and the Dart decoder handles both
      (test/ffi/graph_test.dart, over hand-built ObjectBuilder buffers). What no test covers
      is the argument plumbing in between: replacing `syntheticElided: syntheticElided` with
      a literal `true` at packages/zanshin_core/lib/src/worker/isolate.dart or
      .../worker/handle.dart keeps `dart analyze` and every Dart test green, because every
      live-cdylib worker test runs against `worker.initRepo` on a fresh temp dir — a repo of
      `@` plus root, whose ancestry cannot elide, so the flag cannot change the output.
      Consequence: a UI toggle for elided rows could silently do nothing.
      Not closable inside Story 4.8: the Dart test suite has no fixture-extraction path and
      no commit-creating FFI verb (Epic 9), so elidable ancestry cannot be constructed from
      Dart. Closing it needs either a Dart-side fixture extractor or the mutation verbs.
      Contrast `shortPrefixes`, which IS proven end-to-end because a bad expression surfaces
      `jj.revset_parse_error` only if the string actually crossed the boundary.
    location: >-
      packages/zanshin_core/test/worker/graph_test.dart
    severity: medium
---

<intent-contract>

## Intent

**Problem:** `GraphSlice` rows carry lane topology only (`commit_id`, `lane`, `color_idx`, `edges`) — the schema itself says "display metadata joins later". Rendering a log view today needs one `zanshin_graph_slice` call plus N `zanshin_change` calls, each re-resolving head, which is slow and races external `jj` mutations (lane/commit mismatch). Rows are also not self-contained (a cell cannot paint its cross-section without neighbours), elided ancestry is an `Indirect` edge instead of the CLI's synthetic row, and the CLI's default log revset does not even parse (only `trunk()` is defined — `crates/zanshin-jj/src/revset.rs:146`).

**Approach:** Extract `jj log`-parity metadata inside `zanshin-jj` during the SAME single head-resolved walk (`store.get_commit` per node, like the CLI), carry it as an opaque payload through `zanshin-graph`'s stream into the `Row` its lane assignment produced; add per-row `active_lanes` read off the assigner's live reservation state; splice synthetic elided rows in `zanshin-graph`'s stream layer (CLI's `(CommitId, bool)` keying); define the CLI's builtin `[revset-aliases]` in one `build_aliases_map` table; widen `zanshin_graph_slice` with `synthetic_elided` + `short_prefixes` and the `.fbs` in place.

## Boundaries & Constraints

**Always:**
- **One call = one snapshot (ADR-0002).** Metadata is extracted in the same `load_at_head` scope and the same stream pass as lane assignment, and lands inside the same `Row`. No second walk, no parallel arrays, no join key across FFI, nothing retained Rust-side.
- **Per-call O(1) setup, amortized O(1) per row.** Build ONCE per call: the refs reverse index (`View::bookmarks()` + `View::tags()`), the `wc_commit_ids` map, the `IdPrefixContext`/`IdPrefixIndex`, the immutable `containing_fn`. Never evaluate a revset per row. `active_lanes` costs O(open lanes) because that IS the output.
- **ACL (FR-JJ-16) unchanged.** All `jj_lib` use stays in `zanshin-jj` (+ the test-only `test-helpers` tool crate). `zanshin-graph` stays `jj_lib`-free: it may hold `zanshin_jj::CommitMeta` as an **opaque pass-through** it never inspects. `zanshin-ffi` keeps the single cdylib boundary.
- **CLI is the semantic oracle at v0.42.0 (NFR-R-2), content only.** Field catalog, flags, ref-visibility rule, elided sequencing and row order per `cli-log-parity.md`. Ship flags, never glyphs/colors/layout.
- **Pass-through (FR-JJ-17).** `revset`, `prioritize` (existing) + `synthetic_elided` (default `true`) + `short_prefixes` (default = the `revsets.log` expression; **empty string = disabled**, mirroring the CLI). CLI defaults are pre-filled and editable **Dart-side** (`defaultLogRevset`, `defaultGraphPrioritize`, `defaultShortPrefixes`), never applied silently in Rust.
- **Transport (ADR-0001).** `schemas/envelope.fbs` edited in place (WIP: no versioning), `cargo make codegen` regenerates all four generated files, committed in the same change. Optional scalars are impossible for Dart in flatc 25.12.19 → absence rides a flag or a nested table (see Design Notes).
- **Error taxonomy unchanged.** Reuse `jj.revset_parse_error` / `jj.revset_resolution_error` / `jj.jj_lib_error` / `graph.dangling_edge` / `ffi.*`. Add a registry code ONLY if a genuinely new failure class appears (then update `docs/rust-error-codes.md` in the same change).
- **Quality bar.** clippy pedantic refactor-not-suppress, rustfmt, SPDX first line on new files, `# Errors`/`# Safety` rustdoc on the extern fn, scenario-named tests, `JJ_CONFIG`/`GIT_CONFIG_GLOBAL` pinned, no `#[ignore]`/`skip:`, no timing asserts, `dart analyze`/`dart format` clean.
- **Fixtures are never regenerated.** Edge states (divergent, hidden, conflict, empty, local/remote/unsynced/conflicted bookmarks, tags, multi-workspace) are constructed in-test via new `test-helpers` write helpers (`crates/test-helpers/` is a coverage `exclude_prefix`, dev-dep only — the reviewed 4.6 precedent).
- **Coverage ratchet.** `cargo make test` must exit 0 with `extern-coverage: OK` and no per-file regression; new Rust files ≥ 80 %. Commit the auto-raised `coverage-baseline.txt`.
- **Repo conventions.** ONE focused commit on `main` (`feat(zanshin-graph): CLI-parity log rows with metadata + active_lanes (Story 4.8)`) incl. story artifacts and regenerated files; `flutter`/`dart` gate churn (`app/analysis_options.yaml`, `pubspec.lock`) reverted, never committed; `epic-4-context.md` edited LAST so it stays newer than every planning artifact.

**Block If:**
- `cargo make test` fails for a reason outside this story that cannot be fixed in scope (never lower the baseline, never add an `exclude_prefix`, never add a name to `EXTERN_COV_ALLOW`).
- `cargo make codegen` is unavailable (flatc / cbindgen / ffigen missing) — generated files must come from the tool, never by hand.
- Commit signing fails with `op-ssh-sign` "failed to fill whole buffer" (locked 1Password): stage the work and HALT `blocked`. **Never** `--no-gpg-sign`.
- A jj-lib 0.42 API needed for a catalogued field turns out not to exist as investigated, and no equivalent observable behavior can be reproduced.

**Never:**
- Do NOT implement Story 4.9 (user/repo jj-config overrides of aliases). `build_aliases_map` must remain the single table 4.9 layers config over; do not read `JJ_CONFIG` / repo config / `settings` for aliases here.
- Do NOT edit `_bmad-output/implementation-artifacts/sprint-status.yaml` (the orchestrator owns tracking for this run).
- No windowing/pagination, no `--limit`/`--reversed`, no op-log graph parity, no cryptographic-signature field, no multi-line descriptions (`get_change`'s job), no changes to `zanshin_change` or the MCP surface, no Flutter UI.
- No new dependency: do NOT add `insta` (it is not in the workspace — `Cargo.lock` has no entry); golden values are explicit assertions in the repo's established style.
- No shelling to `jj` from production code or from tests (authoring-time oracle use is a human step, not committed code).
- No materialized/persistent graph or metadata cache; no `Arc<Mutex>`/`RwLock`; no JSON on the wire; no per-call `#[allow(...)]` to dodge clippy.

## I/O & Edge-Case Matrix

Fixture facts: **tiny-3-commits** = `root` ← `@` and `root` ← c1 ← c2 ← c3; `all()` + `present(@)` = 5 rows. **medium-1k-commits** = 1002 rows, contains an octopus merge; neither fixture has remote bookmarks.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Metadata joins the row | tiny, `all()`, defaults | Every non-elided row carries `meta`; `commit_id`/`change_id` pair matches `zanshin_jj::get_change` for the same commit; `description_first_line` is the description's first line (`""` when unset) | none |
| Root row | tiny, `all()` | The root row has `root == true`, `immutable == true`, `empty == true`, empty description, and `meta` still fully populated (uniform payload; special rendering is the UI's) | none |
| Working copy + immutable | tiny, `all()` | Exactly one row has `working_copy == true` (this workspace's `@`); root and `trunk()`-ancestry rows have `immutable == true`; the `@` row has `immutable == false` | none |
| CLI default log revset | tiny, `revset = present(@) \| ancestors(immutable_heads().., 2) \| trunk()` | Evaluates (CAP-4 aliases defined); returns a non-empty row set | none |
| Shortest prefixes | tiny, default `short_prefixes` | `change_id_prefix_len` / `commit_id_prefix_len` ≥ 1 and ≤ full id length; slicing the id to that length yields a prefix unique within the fixture | none |
| Prefixes disabled | `short_prefixes = ""` | Call succeeds; lengths come from the full repo index (≥ the disambiguated lengths for the same commits) | none |
| Empty rows | `revset = none()` | `ok`, `rows` present and empty, `total_rows == 0` | none |
| `active_lanes` invariant | medium, `all()` | For every routed edge on lane `L` from row `a` to its landing row `b`, every row strictly between lists `(L, kind)` in `active_lanes`; no row lists its own lane when that lane neither passes through nor is reused by an earlier edge; each row's fields alone paint its cross-section | none |
| Elided rows on | eliding revset (e.g. `@ \| root()` on tiny), `synthetic_elided = true` | Each `Indirect` edge becomes a `Direct` edge; one synthetic row per elided target is emitted immediately after its child, carrying exactly one `Direct` edge to the real target, occupying a real lane, `synthetic_elided == true`, `meta` absent, `commit_id` = target id | none |
| Elided rows off | same revset, `synthetic_elided = false` | Output is byte-identical to today's stream: plain `Indirect` edges, no synthetic rows | none |
| Duplicate elided target | two children eliding to the same target | TWO synthetic rows are emitted (CLI does not dedup), each after its own child; the stream still terminates with no dangling reservation | none |
| Divergent / hidden | in-test constructed divergent change | Both commits of the change report `divergent == true`; a hidden commit reports `hidden == true`; `change_offset` present where jj-lib yields one | none |
| Conflict / empty | in-test constructed conflicted + empty commit | `conflict == true` / `empty == true` on the right rows only | none |
| Refs on a commit | in-test local bookmark, untracked remote, tracked-unsynced remote, tracked-synced remote, conflicted local, tag | Local entry always present (`conflicted` set from the local target); untracked and tracked-unsynced remote entries present; the tracked-**synced** remote entry is suppressed (CLI `collect_distinct_refs` rule); tags follow the same rule | none |
| Multi-workspace | in-test second workspace | `working_copies` lists every workspace whose wc commit is this row (incl. the current one); in a single-workspace repo it is always empty (CLI guard) | none |
| Re-derive after external op | slice, `test_helpers::add_commit_off_root`, slice again on the SAME handle | The second call shows the new row; an external `describe` on an existing commit is visible in the second call's `description_first_line` | none |
| Bad `short_prefixes` | `short_prefixes = "bogus_function()"` / `"nonexistent-bookmark-xyz"` | `ok:false`, `jj.revset_parse_error` / `jj.revset_resolution_error`, non-empty `context`, no rows | propagated, no panic |
| `short_prefixes` populate failure | expression parses but fails to evaluate at populate time | Degrade like the CLI: fall back to the full-index prefixes + `tracing::warn!`; the call still succeeds | warn, not error |
| Null / invalid UTF-8 `short_prefixes` | null pointer / `0x80` byte | `ffi.null_pointer` / `ffi.utf8_error` | no deref |
| Interior NUL (Dart) | `shortPrefixes` containing a U+0000 code unit | `ArgumentError` thrown Dart-side before the FFI call (existing `revset` / `prioritize` guards unchanged) | — |
| Dart round-trip | real cdylib, fresh `initRepo`, `graphSlice(revset: 'all()')` | 2 rows decoded with non-null `meta`; `rows[0].meta!.workingCopy == true`, `rows[1].meta!.root == true`; an elided-row case decodes with `meta == null` and `syntheticElided == true` | errors surface as `ZanshinFfiException` with the same codes |

</intent-contract>

## Code Map

**zanshin-jj (metadata + aliases; sole `jj_lib` importer)**

- `crates/zanshin-jj/src/commit_meta.rs` (**NEW**) -- the per-call index bundle + per-commit extractor. Public types: `CommitMeta` (field list = `cli-log-parity.md` § Row model), `CommitRef { name, remote: Option<String>, synced, conflicted }`. Crate-internal `LogMetaIndex<'a>` holding: refs reverse index (`HashMap<String /*commit id hex*/, Vec<CommitRef>>` for bookmarks and one for tags), `wc_by_commit: HashMap<String, Vec<String>>` + `multi_workspace: bool`, `IdPrefixIndex<'a>`, `Box<RevsetContainingFn<'a>>`, `root_commit_id`, current `WorkspaceName`. Built once per walk, then `fn extract(&self, repo_dyn, commit: &Commit) -> Result<CommitMeta, RevsetError>` per node.
  - Refs index mirrors `cli/src/commit_templater.rs:2013-2034` (`build_local_remote_refs_index`) + `:2047-2053` (`collect_distinct_refs`): iterate `view.bookmarks()` / `view.tags()` → `(&RefName, LocalRemoteRefTarget { local_target, remote_refs })`; if `local_target.is_present()` insert a local entry at every `local_target.added_ids()` with `synced = remote_refs.all(|r| !r.is_tracked() || r.target == *local_target)` and `conflicted = local_target.has_conflict()`; per remote insert an entry at every `remote_ref.target.added_ids()` with `synced = remote_ref.is_tracked() && remote_ref.target == *local_target`, `conflicted = remote_ref.target.has_conflict()`; **keep only `remote.is_none() || !synced`**.
  - Per commit: `repo_dyn.resolve_change_id(commit.change_id())` ONCE → `hidden` (`!targets.has_visible(id)` or `None`), `divergent` (`targets.is_divergent()`), `change_offset` (`targets.find_offset(id)`). `empty` = `commit.is_empty(repo_dyn).await`. `conflict` = `commit.has_conflict()`. `root` = `commit.id() == store.root_commit_id()`. `working_copy` = `view.get_wc_commit_id(&workspace_name) == Some(id)`. `change_id` = `commit.change_id().reverse_hex()`; prefix lengths from `IdPrefixIndex::shortest_change_prefix_len` / `shortest_commit_prefix_len` (both take `repo_dyn`). `author_name`/`author_email` from `commit.author()`; committer timestamp from `commit.committer().timestamp` (`.timestamp.0` millis + `.tz_offset` minutes — the `change.rs:135-144` converter shape). `description_first_line` = first line of `commit.description()`.
- `crates/zanshin-jj/src/graph.rs` l.107-145 -- widen `walk_graph(repo, revset, prioritize, short_prefixes, visit)`; after step 2 (`readonly` / `repo_dyn`) build the `LogMetaIndex` (incl. the `IdPrefixContext` from `short_prefixes` and the immutable `containing_fn`), and in the step-5 async loop `store.get_commit_async(&id).await` then `to_node(&id, edges, meta)`. `GraphNode` (l.58-64) gains `pub meta: CommitMeta`. Keep `edge_kind`/`GraphEdgeKind` untouched.
- `crates/zanshin-jj/src/revset.rs` l.85-124 (`parse_revset`), l.126-138 (`evaluate_revset`), l.146-160 (`build_aliases_map`) -- extend `build_aliases_map` to the FULL builtin table from `cli/src/config/revsets.toml` @ v0.42.0 (`trunk()`, `builtin_immutable_heads()`, `immutable_heads()`, `immutable()`, `mutable()`, `visible()`, `hidden()`; keep them verbatim, including `trunk()`'s six `remote_bookmarks(exact:…, exact:…)` terms which the current one-arg version gets wrong). ADD `pub const DEFAULT_LOG_REVSET: &str = "present(@) | ancestors(immutable_heads().., 2) | trunk()";` (`revsets.log`) and a crate-internal `immutable_containing_fn(repo, repo_dyn)` = parse `"immutable_heads()"` → `.union(&RevsetExpression::root())` → `.ancestors()` → evaluate → `containing_fn()` (the CLI's in-code construction, `cli/src/cli_util.rs:956-961` + `revset_util.rs:193-203`), so 4.9's config layer flows in for free. `build_aliases_map` is called twice per walk today (graph.rs:115-116) — hoist to once and pass `&RevsetAliasesMap` into `parse_revset`, or memoize; do not regress to three calls.
- `crates/zanshin-jj/src/repo.rs` l.183-218 -- `walk_graph` wrapper signature + rustdoc (delete the l.189 "Only the `trunk()` alias is defined" limitation note).
- `crates/zanshin-jj/src/change.rs` l.18-58 (`CommitId`, `Signature`, `Timestamp`), l.135-144 (`to_signature`) -- the identity/timestamp shape to mirror. READ-ONLY unless a converter is genuinely shared.
- `crates/zanshin-jj/tests/api_stability.rs` l.104-116 -- `GraphEdge`/`GraphNode` struct literals gain `meta`; ADD `CommitMeta`/`CommitRef` type aliases and a `DEFAULT_LOG_REVSET` value assertion next to the `DEFAULT_GRAPH_PRIORITIZE` one.
- `crates/zanshin-jj/tests/graph.rs` (18 tests) -- update for the new `walk_graph` arity; ADD metadata tests per the I/O matrix (root/wc/immutable flags, CLI default revset, prefix lengths, `short_prefixes = ""`, parse/resolution errors for `short_prefixes`).
- `crates/zanshin-jj/README.md` l.108 + `crates/zanshin-jj/src/lib.rs` l.41-50 -- alias-limitation prose and the `pub use` surface.

**zanshin-graph (row model, `active_lanes`, elided splice; stays `jj_lib`-free)**

- `crates/zanshin-graph/src/lane.rs` -- ADD `pub struct NodeId { pub commit_id: String, pub synthetic: bool }` (+ `NodeId::commit(..)` / `NodeId::elided(..)`, `Hash + Eq + Clone`) and `pub struct ActiveLane { pub lane: u32, pub kind: EdgeKind }`. `GraphEdge.target` (l.36-42) and `GraphNode.id` (l.60-70) become `NodeId`; `GraphNode` gains `pub meta: Option<zanshin_jj::CommitMeta>` (**opaque** — the algorithm never reads it; document that). `Row` (l.96-106) gains `pub synthetic_elided: bool`, `pub active_lanes: Vec<ActiveLane>`, `pub meta: Option<CommitMeta>`; `commit_id` stays the hex `String` (from `NodeId.commit_id`) and `RowEdge.target` stays a hex `String`. State (l.138-150): `lanes: Vec<Option<Reservation>>` where `Reservation { target: NodeId, kind: EdgeKind }`; `reservations: HashMap<NodeId, Vec<u32>>`. `reserve` (l.255-261) must **preserve the kind of the edge that created the reservation** (only set `kind` when the slot was `None`) — a later edge reusing the lane joins an existing segment, it does not restyle it. `push` (l.176-198): read `active_lanes` IMMEDIATELY after `place()` (l.177) and BEFORE the edge loop (l.180) — at that instant every lane ending at this row is `None` and the node's own lane is `None` in both `place` branches, so the occupied set is exactly the pass-through set; ascending lane order. `GraphError::DanglingEdge { target: String }` keeps its shape (report `NodeId.commit_id`).
- `crates/zanshin-graph/src/stream.rs` l.24-47 (`From` impls), l.70-96 (`stream_lanes` + `drive_lanes`) -- `stream_lanes(repo, revset, prioritize, short_prefixes, synthetic_elided, sink)`. The `From<zanshin_jj::GraphNode>` conversion becomes a splice function: rewrite each `Indirect` edge to `Direct` → `NodeId::elided(target)` (collecting targets in edge order) when `synthetic_elided`, else `NodeId::commit(target)` with the kind unchanged; `Missing` untouched. The driving closure pushes the real node, calls `sink`, then for each collected target pushes a synthetic node (`id: NodeId::elided(t)`, one `Direct` edge to `NodeId::commit(t)`, `meta: None`) and calls `sink` — honouring `Break` from either. Mirrors `cli/src/commands/log.rs:245-329`.
- `crates/zanshin-graph/src/slice.rs` l.31 -- `collect_lanes(repo, revset, prioritize, short_prefixes, synthetic_elided)`.
- `crates/zanshin-graph/src/lib.rs` l.14-24 -- re-exports (`NodeId`, `ActiveLane`) + the "no `jj_lib`, opaque metadata" note.
- `crates/zanshin-graph/tests/{lane,stream,slice}.rs` (41 tests) + inline `lane.rs:304-390` / `stream.rs:99-207` -- the local `node()`/`row()` literal builders must gain the new fields; ADD the `active_lanes` invariant test on medium (octopus), the elided-splice tests (on/off/duplicate target), and inline tests for the pass-through read point and kind preservation.

**zanshin-ffi + wire**

- `schemas/envelope.fbs` l.207-241 -- ADD `table GraphCommitRef { name: string; remote: string; synced: bool; conflicted: bool; }`, `table GraphActiveLane { lane: uint; kind: GraphEdgeKind; }`, `table GraphRowMeta { … }` (catalog fields; `change_offset: uint` + `has_change_offset: bool` presence pair, documented like `GraphRowEdge.target_lane`); `GraphRow` gains `active_lanes: [GraphActiveLane]`, `synthetic_elided: bool`, `meta: GraphRowMeta` (**absent on elided rows** — a nested table is the only shape flatc 25.12.19 lets Dart see as null). Update the l.228-230 "display metadata joins later" doc. `Payload`/`Envelope` untouched.
- `crates/zanshin-ffi/src/graph.rs` l.55-126 (builder), l.130-189 (extern fn) -- `row_offset` gains the meta/active-lane sub-builders (`signature_offset` in `change.rs:42` is the nested-table precedent); `zanshin_graph_slice(handle, revset, prioritize, synthetic_elided: bool, short_prefixes: *const c_char)` — `bool` is safe at the C surface (`zanshin_ffi.h` already includes `<stdbool.h>`); update the l.130-165 rustdoc (`# Errors`/`# Safety`) since cbindgen+ffigen copy it. `map_lane_stream_err` unchanged. Inline test helpers `kind_from_wire`/`rows_from_wire` (l.237-285) and their verbatim twins in `tests/graph_ffi.rs:103-137` must both learn the new fields.
- `crates/zanshin-ffi/tests/graph_ffi.rs` -- widen `slice_bytes` (l.96) and the 4 direct `zanshin_graph_slice` call sites (l.363/376/391/405); ADD the Rust I/O-matrix rows (metadata equality vs `zanshin_jj::get_change`, root/wc/immutable, CLI default revset, elided on/off/duplicate, `active_lanes` invariant on medium, `short_prefixes` empty/parse/resolution/null/utf8, describe-visible-after-external-op).
- `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/{bindings.dart,envelope_generated…}`, `crates/zanshin-ffi/src/envelope_generated.rs` -- regenerated by `cargo make codegen` ONLY (Makefile.toml:226-281); commit all four.

**Dart bridge (`packages/zanshin_core`)**

- `lib/src/ffi/graph.dart` -- `zanshinGraphSlice(rawHandle, revset, prioritize, syntheticElided, shortPrefixes)`: a third interior-NUL guard for `shortPrefixes` and its own nested `try/finally` free (l.44-72 pattern). ADD `defaultLogRevset` and `defaultShortPrefixes` consts next to `defaultGraphPrioritize` (l.26), both mirroring `zanshin_jj::DEFAULT_LOG_REVSET`. ADD models `GraphCommitRef`, `GraphActiveLane`, `GraphRowMeta`; `GraphRow` gains `activeLanes`, `syntheticElided`, `meta` (`GraphRowMeta?`); extend `_mapRow` and add `_mapMeta` (`changeOffset` → `int?` gated on `hasChangeOffset`, `remote` → `String?`).
- `lib/src/worker/commands.dart` l.143-166 -- `GraphSliceCommand` gains `syntheticElided: bool` + `shortPrefixes: String`; update the `sealed class WorkerCommand` doc (l.3-10) which currently says "only `int` or `String` fields" (a `bool` is equally sendable).
- `lib/src/worker/isolate.dart` l.534-548 (`ZanshinWorker.graphSlice`) + l.763-778 (dispatch arm; the destructuring pattern must gain both fields or `dart analyze` fails).
- `lib/src/worker/handle.dart` l.105-113 -- `RepoHandle.graphSlice({required revset, prioritize = defaultGraphPrioritize, syntheticElided = true, shortPrefixes = defaultShortPrefixes})` — the defaults layer (FR-JJ-17).
- `test/worker/graph_test.dart` (10 tests) + `test/ffi/graph_test.dart` (6 tests, synthetic `*ObjectBuilder` buffers) -- widen every call/builder; ADD a metadata round-trip, an elided-row decode (`meta == null`), a `shortPrefixes` NUL-guard test, and value pins for `defaultLogRevset` / `defaultShortPrefixes`. The worker test is what credits `zanshin_graph_slice` in the extern-coverage guard.

**Test helpers + docs + planning**

- `crates/test-helpers/src/lib.rs` (coverage `exclude_prefix`; `add_commit_off_root` at l.86 + `make_test_settings` at l.59 are the precedent) -- ADD the write helpers the edge-state tests need (describe an existing commit, create a divergent change, abandon a commit to make one hidden, write a conflicted tree, write an empty commit, set local/remote bookmarks + tags incl. unsynced/untracked/conflicted, add a second workspace). Keep them small, `# Panics`-documented, and add only what a test actually uses.
- `docs/ffi-abi.md` l.333-409 -- update the C prototype (l.348), the parameter table (add both new params incl. the empty-string-disables rule and the interior-NUL rule), the payload shapes (new tables, `meta` absent on elided rows), and the worker-integration lines.
- `docs/rust-error-codes.md` l.54-56 -- extend the `jj.revset_*` rows to name `short_prefixes` as a third source expression. No new codes expected.
- `_bmad-output/planning-artifacts/epics.md` -- Epic 4 currently ends at Story 4.7 (l.3067); ADD a `### Story 4.8` section after it in the established style with a dated "**Delivered (2026-08-23, Story 4.8 done):**" note pointing at `_bmad-output/specs/spec-4-8-log-rows-cli-parity/`.
- `_bmad-output/implementation-artifacts/epic-4-context.md` l.18 (4.8 → done + one-line delivery), l.23 (retire "display metadata joins later"), l.31 (anti-speculation bullet), l.35/l.37 (stream + FFI-surface signatures). **EDIT LAST.**
- `coverage-baseline.txt` l.20/l.30-32/l.37/l.41 -- expect movement on `zanshin-ffi/src/graph.rs`, `zanshin-graph/src/{lane,slice,stream}.rs`, `zanshin-jj/src/{graph,revset}.rs`; the new `zanshin-jj/src/commit_meta.rs` must land ≥ 80 % (aim 100 %). Commit the raised file.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/revset.rs` -- full builtin alias table + `DEFAULT_LOG_REVSET` + `immutable_containing_fn`; build the aliases map once per walk -- CAP-4, and the single seam Story 4.9 layers config over.
- `crates/zanshin-jj/src/commit_meta.rs` (new) -- `CommitMeta` / `CommitRef` + per-call `LogMetaIndex` + per-commit `extract` -- CAP-1, O(1) setup / O(1) per row.
- `crates/zanshin-jj/src/{graph.rs,repo.rs,lib.rs}` -- thread `short_prefixes`, build the index inside the `load_at_head` scope, fetch the commit per node, attach `meta` to `GraphNode` -- one snapshot, one pass.
- `crates/zanshin-graph/src/lane.rs` -- `NodeId`, `ActiveLane`, kind-carrying reservations, `active_lanes` read after `place()`, opaque `meta` pass-through on `GraphNode`/`Row` -- CAP-2 + the elided identity space.
- `crates/zanshin-graph/src/{stream.rs,slice.rs,lib.rs}` -- elided splice + `synthetic_elided`/`short_prefixes` pass-through -- CAP-3, spliced where the CLI splices.
- `schemas/envelope.fbs` -- `GraphCommitRef`, `GraphActiveLane`, `GraphRowMeta`; `GraphRow` gains `active_lanes` / `synthetic_elided` / `meta` -- the wire contract (edit in place, WIP).
- `crates/zanshin-ffi/src/graph.rs` -- builder for the new sub-tables + widened extern fn + rustdoc -- CAP-5.
- run `cargo make codegen` -- regenerate header, bindings and both flatc outputs -- generated surface must carry the new signature and tables.
- `packages/zanshin_core/lib/src/ffi/graph.dart`, `lib/src/worker/{commands,isolate,handle}.dart` -- adapter + NUL guard + models + decoder + command/dispatch/defaults -- CAP-5, FR-JJ-17 pre-fills.
- `crates/test-helpers/src/lib.rs` -- the jj-lib write helpers the edge-state tests need -- fixtures are never regenerated.
- `crates/zanshin-jj/tests/{graph.rs,api_stability.rs}`, `crates/zanshin-graph/tests/{lane,stream,slice}.rs`, `crates/zanshin-ffi/tests/graph_ffi.rs`, `packages/zanshin_core/test/{worker,ffi}/graph_test.dart` -- cover EVERY I/O-matrix row incl. the CLI-parity golden values and the `active_lanes` structural invariant -- the definition of "proven".
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- ABI contract + registry sourcing -- FFI-surface change discipline.
- `_bmad-output/planning-artifacts/epics.md`, then `_bmad-output/implementation-artifacts/epic-4-context.md` (LAST) -- doc reconciliation -- keep the epic-context cache valid and newest.
- run `cargo make test` (unpiped, read the exit code) -- fix by refactoring/adding tests; commit the raised `coverage-baseline.txt`; revert gate churn; ONE commit -- definition of done.

**Acceptance Criteria:**
- Given a repo handle, when `zanshin_graph_slice` is called once with the CLI default log revset, then the returned rows carry, per commit row, every field of `cli-log-parity.md` § Row model, derived from a single `load_at_head` snapshot, and no second FFI call is needed to render the default `jj log` view.
- Given the committed golden parity tests, when they run, then the reconstructed CLI row for each fixture commit (ids at their shortest-prefix lengths, author email, committer timestamp, refs with `*`/`??`/`@remote` sigils, `(empty)`/`(hidden)`/`(divergent)`/`(conflict)` markers, description first line) equals the jj v0.42.0 rendering documented in-test, and no test shells out to `jj`.
- Given the medium fixture (octopus merge, multiple roots), when the structural-invariant test runs, then every routed edge's lane appears in `active_lanes` of every row strictly between its child and its landing row, and no assertion needs a neighbouring row's fields to validate a row.
- Given an eliding revset, when `synthetic_elided` is `true`, then the emitted row sequence, links and lanes match the CLI's observable output (synthetic row directly after its child, one `Direct` edge to the real target, duplicates not deduped); when it is `false`, the output is identical to the pre-4.8 stream.
- Given the finished tree, when `cargo make codegen` has run and `cargo make test` runs unpiped, then it exits 0 with `extern-coverage: OK` and `coverage-check: OK`, no per-file regression, `commit_meta.rs` ≥ 80 %, clippy/fmt/analyze/format/deny green, and `git status` is clean after the single commit (deliberate gate-churn reverts aside).

## Spec Change Log

## Review Triage Log

### 2026-08-24 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 6: (high 0, medium 3, low 3)
- defer: 1: (high 0, medium 1, low 0)
- reject: 27: (high 0, medium 0, low 27)
- addressed_findings:
  - `[medium]` `[patch]` `change_id_prefix_len` shipped with a bounds check only — no uniqueness proof, so a constant or the adjacent `shortest_commit_prefix_len` call would pass every test. Extended `walk_graph_shortest_prefix_lengths_are_unique_within_the_fixture` (`crates/zanshin-jj/tests/graph.rs`) with the same `starts_with` uniqueness loop the commit id already gets.
  - `[medium]` `[patch]` Four of the seven new builtin revset aliases (`immutable()`, `mutable()`, `visible()`, `hidden()`) were never expanded by any code path or test, and jj-lib does not validate an alias definition at insert time (`dsl_util.rs`: "The `defn` part isn't checked"), so `build_aliases_map()` returning `Ok` proved nothing. Added `every_builtin_revset_alias_expands_and_resolves` (all seven) plus the semantic pin `mutable_and_immutable_partition_all` in `crates/zanshin-jj/tests/revset.rs`. The table itself was re-verified verbatim against `git -C ../jj show v0.42.0:cli/src/config/revsets.toml`.
  - `[medium]` `[patch]` `_bmad-output/implementation-artifacts/epic-4-context.md` had become OLDER than `_bmad-output/planning-artifacts/epics.md`, breaking the spec's "edit LAST" rule and silently invalidating the cached epic context. Re-edited last; it is now the newest of the two.
  - `[low]` `[patch]` `app/analysis_options.yaml` carried `android/ios/web/windows/linux` excludes that the intent forbids committing (and that are inert — none of those directories exist in this macOS-only app). Reverted to baseline. Confirmed to be tool churn: the Flutter step of `cargo make test` regenerates it, so it was reverted again after the final gate run.
  - `[low]` `[patch]` The golden parity test's comment claimed its rendering "proves we ship the lengths the CLI computes"; the CLI's own `id.shortest(8)` floor makes that rendering insensitive to every prefix length both fixtures produce. Corrected the comment and pointed it at the test that actually pins the lengths.
  - `[low]` `[patch]` `epic-4-context.md` still cited the pre-4.8 "~3 ms full 10k derive" baseline, measured on the topology-only walk that 4.8 replaced with a per-row commit read. Annotated as stale, naming what was added and that a commit-read failure now fails the call.

Notes on the largest reject groups, recorded because each was checked against the pinned
oracle rather than dismissed:

- **Committer vs. author timestamp** (claimed parity bug): rejected. At v0.42.0
  `templates.toml:315` defines `'commit_timestamp(commit)' = 'commit.committer().timestamp()'`,
  and `format_short_commit_header` renders exactly that. Shipping `committer_timestamp` is correct.
- **`builtin_immutable_heads()` missing a `present(...)` wrapper** and **`trunk()` narrowed to
  origin/upstream**: both rejected. The shipped table is byte-for-byte the v0.42.0
  `revsets.toml`; the pre-4.8 one-arg `trunk()` was the bug this story fixes.
- **`short_prefixes` degrading instead of erroring** (contradicts this spec's own I/O matrix
  row): rejected against the code — the implementation is right and the matrix row is wrong
  about the CLI. jj's own `cli/tests/test_log_command.rs::test_log_bad_short_prefixes` at
  v0.42.0 shows `!nval!d` exiting 1 while `'missing'` only warns and still prints the log.
  The intent's "CLI is the semantic oracle at v0.42.0" clause resolves the contradiction to a
  single reading, so this is not an intent_gap. Carried into Residual risks instead.
- **Blank-but-not-empty `short_prefixes` erroring while `prioritize` treats it as empty**:
  rejected. The CLI's own guard is `revset_string.is_empty()` (`cli_util.rs:996`), so `"   "`
  reaching a parse error is exact parity.

## Design Notes

- **Why metadata rides `GraphNode`/`Row` instead of a side channel.** The SPEC's atomicity constraint bans parallel arrays and join keys. `zanshin-graph` never inspects `CommitMeta`; it is an opaque payload moved from the node to the row it produced. That keeps `lane.rs` a pure algorithm (still fixture-free, still `jj_lib`-free) while making the row the unit of atomicity.
- **Why `active_lanes` is read right after `place()`.** At that instant `place()` has cleared every lane landing at this row, and the node's own lane is `None` in BOTH branches (a reservation hit clears its slots; `alloc_lane` returns a free index without occupying it). Lanes the row's own edges will take are either freshly allocated (still `None` → excluded) or an existing reservation made by an EARLIER row (`Some` → included, which is correct: that earlier edge's segment genuinely passes through this row). Reading after the edge loop would need subtraction and still could not tell the two apart. The per-edge invariant in the acceptance criteria is the tie-breaker that makes this well-defined.
- **Why a kind on the reservation.** `lanes: Vec<Option<String>>` records no kind today, so a pass-through's dash styling would be unrecoverable. The reservation carries the kind of the edge that CREATED it; a later edge joining the same lane does not restyle the existing segment. With `synthetic_elided = true` (the default) every `Indirect` has already become `Direct`, so this only bites in the toggle-off mode.
- **Why `(commit_id, synthetic)` identity.** The CLI keys renderdag on `(CommitId, bool)` (`cli/src/commands/log.rs:245-329`); a synthetic row must be able to reserve and consume its own lane without colliding with the real commit. Namespacing into the `String` would leak into `Row::commit_id` and `GraphError::DanglingEdge`. Duplicate elided targets stay un-deduped (jj's own test calls this out); each synthetic row consumes exactly the reservation its immediately-preceding child created, so `finish()` still sees no dangling lane.
- **Why `meta` is a nested table.** flatc 25.12.19 rejects optional scalars for Dart (recorded on `GraphRowEdge`), so a flat row could not express "absent on elided rows". A nested table is naturally nullable in the generated Dart. Inside it, `change_offset` uses the documented presence-pair (`has_change_offset`) and `remote` uses string-nullability.
- **`change_offset` presence = the jj fact, not the render rule.** Ship it whenever `find_offset` yields one; the CLI's "render `/N` only when hidden or divergent" is a UI decision reproducible from the shipped `hidden`/`divergent` flags. Backend exposes, UI decides — and the golden test proves the CLI rendering is reconstructible.
- **Why the CLI's ref filter IS applied backend-side.** `collect_distinct_refs` (`is_local() || !synced`) is part of the observable row CONTENT, not styling — a tracked-and-synced remote bookmark simply is not part of a `jj log` row. Applying it is content parity; the unfiltered view remains `list_bookmarks`' job.
- **`short_prefixes` failure split mirrors the CLI exactly.** A parse/resolution failure of a user-typed expression is a hard error in the CLI (`cli_util.rs:987-1009` propagates); a failure at `populate()` time is a warning that degrades to full-index prefixes (`commit_templater.rs:2216-2229`). Reproduce both — do not "improve" either.
- **Immutable set is built in code, not from the `immutable()` alias.** The CLI takes `immutable_heads()`'s definition, unions `root()`, and calls `.ancestors()` (`cli_util.rs:956-961`); the `immutable()` alias exists only for user-written revsets. Both denote the same set, but mirroring the in-code construction is what makes 4.9's config override of `immutable_heads()` flow through automatically.
- **Authoring-time parity oracle.** The locally installed `jj` is **0.44.0**, not the pinned 0.42.0, so it is only a valid oracle where the parity surface is unchanged. Verified: `git -C ../jj diff v0.42.0 v0.44.0` touches `templates.toml` only in `workspace_list` (`builtin_log_compact` / `format_short_commit_header` / `builtin_log_node` / `format_root_commit` / `format_short_change_id_with_change_offset` / `format_commit_labels` are byte-identical), leaves the builtin `[revset-aliases]` and `ui.log-synthetic-elided-nodes` unchanged (`revsets.log` only moved behind a `builtin_log()` alias with the same expression), and changes none of `commit_templater.rs`'s parity functions. So `jj log` from the 0.44 binary, run against an EXTRACTED COPY of a fixture in a temp dir (never the committed archive), is a sound authoring-time cross-check; record that provenance in the golden test's comment together with the v0.42.0 template lines the values derive from.
- **No `insta`.** It is absent from `Cargo.toml` and `Cargo.lock`; the repo's graph tests already pin values with explicit assertions. Adding a snapshot dependency for one story is a new dep for no gain.

## Verification

**Commands:**
- `cargo make codegen` -- expected: `zanshin_ffi.h` + `bindings.dart` carry the 5-arg `zanshin_graph_slice`; `envelope_generated.rs` + `envelope_zanshin.ffi_generated.dart` carry `GraphRowMeta` / `GraphCommitRef` / `GraphActiveLane`.
- `cargo test -p zanshin-jj`, `cargo test -p zanshin-graph`, `cargo test -p zanshin-ffi --test graph_ffi` -- expected: green.
- `cargo clippy --workspace --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean, no new `#[allow]`.
- `dart analyze` + `dart format --set-exit-if-changed` in `packages/zanshin_core`; `dart test test/worker/graph_test.dart test/ffi/graph_test.dart` -- expected: clean and green (the sealed-switch arm satisfied).
- `cargo make test` (unpiped, exit code read directly) -- expected: exit 0; `extern-coverage: OK`; `coverage-check: OK`; commit the updated `coverage-baseline.txt`.
- `git status --porcelain` after the commit -- expected: empty.

**Manual checks (if no CLI):**
- Golden parity: for at least one fixture commit and one in-test edge-state commit, reconstruct the CLI row string from the shipped fields and compare against `jj log` output produced at authoring time from the 0.44 binary on an extracted fixture copy (provenance + the v0.42.0 template lines documented in the test).
- `_bmad-output/implementation-artifacts/epic-4-context.md` is the newest file relative to `_bmad-output/planning-artifacts/` after all doc edits.

## Auto Run Result

Status: done
Blocking condition: none

### Run history — read this before trusting the shape of the commits

This story did NOT run as one clean pass, and the history should not be read as if it did.

1. The implementation pass produced commit `03a2009 feat(zanshin-graph): CLI-parity log rows
   with metadata + active_lanes (Story 4.8)` on top of `baseline_revision` `35bee21`.
2. A first review pass ran, applied 17 findings to the working tree, and was then cut off by
   a **session limit** before it could write its triage-log entry. That is why
   `## Review Triage Log` was empty and `review_loop_iteration` was still `0` at the start of
   this pass: the entry was never written, not skipped.
3. During that interrupted pass a **concurrent-writer incident** occurred — two patch agents
   wrote the same working tree at once and corrupted the pass's own progress. The stray
   scratch files it left (`tmp_perf.rs`, `tmp_perf2.rs`, `tmp_dump.rs`) were removed before
   this pass. This pass ran every subagent synchronously, single-writer.
4. Ralph then made four un-reviewed repairs by hand to get the gate green again (see
   "Human repairs carried into this review" below). Those were reviewed here, not before.
5. This pass is therefore the FIRST completed review of Story 4.8. It produced a second
   commit rather than the single focused commit the intent asked for — an unavoidable
   consequence of the interruption, since `03a2009` is already published and the intent
   forbids amending a published commit.

### Summary of implemented change

`zanshin_graph_slice` now returns self-contained `jj log`-parity rows from ONE call.
`zanshin-jj` gained `commit_meta.rs`: a per-call index bundle (`LogMetaIndex` — refs reverse
index, working-copy map, `IdPrefixIndex`, immutable containment fn) built once per walk inside
the same `load_at_head` scope, plus a per-commit `extract` producing `CommitMeta`. `walk_graph`
threads `short_prefixes` and attaches that payload to each `GraphNode`. `revset.rs` replaced the
lone (and wrong) one-arg `trunk()` with the verbatim v0.42.0 builtin `[revset-aliases]` table and
added `DEFAULT_LOG_REVSET` plus an in-code immutable expression, so the CLI's default log revset
parses for the first time. `zanshin-graph` stays `jj_lib`-free and carries `CommitMeta` as an
opaque pass-through: `lane.rs` gained `NodeId` (the CLI's `(CommitId, bool)` keying),
kind-carrying reservations and per-row `active_lanes` read off the live reservation state
immediately after placement; `stream.rs` splices one synthetic "(elided revisions)" row per
elided target directly behind its child, un-deduped, exactly where the CLI splices. The wire
gained `GraphRowMeta` / `GraphCommitRef` / `GraphActiveLane` and `GraphRow.{meta,
active_lanes, synthetic_elided}`, with `meta` absent on elided rows. The Dart bridge decodes all
of it and pre-fills the CLI defaults (`defaultLogRevset`, `defaultShortPrefixes`,
`defaultSyntheticElided`) editable at the call site, per FR-JJ-17.

### Files changed (since `35bee21`; 41 files)

**zanshin-jj**
- `src/commit_meta.rs` (NEW) — `CommitMeta` / `CommitRef`, the per-call `LogMetaIndex`, per-commit `extract`.
- `src/graph.rs` — builds the index in the `load_at_head` scope, loads each commit, attaches `meta` to `GraphNode`.
- `src/revset.rs` — full v0.42.0 builtin alias table, `DEFAULT_LOG_REVSET`, in-code immutable expression, aliases map built once per walk.
- `src/repo.rs`, `src/lib.rs`, `README.md`, `Cargo.toml` — widened `walk_graph` signature, re-exports, `tracing` dep, retired the "only `trunk()` is defined" prose.
- `tests/graph.rs` — metadata, flags, refs, prefixes, golden CLI-row reconstruction; **this pass** added change-id prefix uniqueness and corrected the golden test's overstated claim.
- `tests/api_stability.rs` — `meta` on the struct literals, `DEFAULT_LOG_REVSET` value pin.
- `tests/revset.rs` — **this pass**: `every_builtin_revset_alias_expands_and_resolves`, `mutable_and_immutable_partition_all`.

**zanshin-graph**
- `src/lane.rs` — `NodeId`, `ActiveLane`, kind-carrying `Reservation`, `active_lanes` read after `place()`, opaque `meta` on `GraphNode`/`Row`.
- `src/stream.rs` — `splice_elided` + `elided_node`; synthetic rows spliced behind their child, honouring sink `Break`.
- `src/slice.rs`, `src/lib.rs` — parameter pass-through, re-exports, the "no `jj_lib`, opaque metadata" note.
- `tests/{common/mod.rs,lane.rs,slice.rs,stream.rs}` — new field builders, the `active_lanes` structural invariant on medium, elided splice on/off/duplicate.

**zanshin-ffi + wire**
- `schemas/envelope.fbs` — `GraphCommitRef`, `GraphActiveLane`, `GraphRowMeta`; `GraphRow` widened (edited in place, WIP).
- `src/graph.rs` — meta/active-lane sub-builders, 5-arg extern fn, `# Errors`/`# Safety` rustdoc.
- `tests/graph_ffi.rs` — widened call sites plus the FFI-surface I/O-matrix rows and the 1002-row wire-vs-`collect_lanes` oracle.
- `include/zanshin_ffi.h`, `src/envelope_generated.rs` — regenerated by `cargo make codegen`.

**Dart bridge (`packages/zanshin_core`)**
- `lib/src/ffi/graph.dart` — `shortPrefixes` NUL guard, new models, `_mapMeta`, the three CLI-default consts.
- `lib/src/worker/{commands,isolate,handle}.dart` — the two new command fields, dispatch arm, `RepoHandle.graphSlice` defaults.
- `lib/src/ffi/{bindings.dart,envelope_zanshin.ffi_generated.dart}` — regenerated.
- `test/{worker,ffi}/graph_test.dart` — widened calls and builders, metadata round-trip, elided decode, NUL guards, default value pins.
- `test/ffi/buffer_free_test.dart` (NEW) — real-cdylib cover for the synchronous `zanshin_buffer_free` path.

**Support / docs / planning**
- `crates/test-helpers/src/lib.rs` — jj-lib write helpers for the in-test edge states (fixtures are never regenerated).
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` — ABI contract, new payload tables, `short_prefixes` sourcing.
- `Makefile.toml` — `EXTERN_COV_ALLOW` **comment** only; no name added or removed.
- `coverage-baseline.txt` — `commit_meta.rs` at 100.00; `ffi_strings.rs` 99.14 → 100.00; `graph.rs` 99.60 → 99.81.
- `_bmad-output/planning-artifacts/epics.md`, `_bmad-output/implementation-artifacts/epic-4-context.md` — Story 4.8 delivery notes; epic context re-edited LAST this pass and its stale perf baseline annotated.
- `app/analysis_options.yaml` — reverted to baseline (tool churn, deliberately not committed).

### Human repairs carried into this review

Four un-reviewed hand repairs were made after the interrupted pass died. All four were reviewed
here and all four are **correct**:

1. `crates/zanshin-ffi/src/graph.rs` — the shared `row()` test helper now supplies
   `Some(full_meta())` (and `meta: None` is pinned explicitly in the synthetic-elided test) so
   the new `debug_assert_eq!` "meta absent IFF synthetic elided" holds. Consistent with the
   only producers of `Row` along the FFI path.
2. `crates/zanshin-graph/tests/stream.rs` — the assertion in
   `stream_lanes_synthetic_row_reports_its_own_pass_through_lanes` was retargeted from the
   first synthetic row to the second. **Independently confirmed by hand-tracing `LaneAssigner`
   over the test's five-row stream** (tip_X, synth_X, tip_Y, synth_Y, root): at synth_X the
   lane vector is `[None]`, so `active_lanes` is genuinely empty — tip_Y sits BELOW synth_X and
   its lane cannot cross a row above it. The real pass-through is at synth_Y, crossed by the
   still-open lane-0 edge synth_X opened toward root. Checked against the spec's own CAP-2
   phrasing ("every row strictly BETWEEN its child and its landing row") and against renderdag's
   top-down column allocation, where a later tip's column starts at its own row. The original
   expectation `[1]` was wrong; the implementation was right. This was a correct test fix, NOT a
   masked implementation bug.
3. `packages/zanshin_core/lib/src/ffi/graph.dart` — dropped a redundant `bool` annotation that
   tripped `omit_obvious_property_types` under `--fatal-infos`. Cosmetic, correct.
4. `app/analysis_options.yaml` revert — correct and required by the intent; it had merely been
   re-applied by the Flutter step of the gate (see the patch note above).

### Review findings breakdown

Four review layers ran in parallel as blocking calls in a single turn: blind hunter, edge-case
hunter, verification-gap reviewer, intent-alignment auditor.

- **intent_gap: 0.** Every apparent ambiguity resolves to exactly one reading through the
  intent's own "CLI is the semantic oracle at v0.42.0" constraint, verified against the pinned tag.
- **bad_spec: 0.** No finding required re-deriving the code.
- **patches applied: 6** — high 0, medium 3, low 3 (listed in the triage log above).
- **items deferred: 1** — the unverified Dart-to-C `bool` hop for `syntheticElided` (see
  frontmatter `deferred`). Not closable in this story: the Dart suite has no fixture-extraction
  path and no commit-creating verb, so elidable ancestry cannot be built from Dart.
- **items rejected: 27.** The substantive ones were rejected only after checking the pinned
  oracle (`../jj` at v0.42.0 and the vendored jj-lib 0.42.0), not on assertion — see the triage
  log's notes on the timestamp field, the alias table, and the `short_prefixes` failure split.

### Follow-up review recommendation

`followup_review_recommended: true`.
Patched counts this pass: high 0, medium 3, low 3. No high-severity patch, so the score decides:
`3 × 3 + 1 × 3 = 12`, which is >= 5. Recommendation: **true**.

### Verification performed

- `cargo test -p zanshin-jj --test revset --test graph` — green (36 + 17 passed, 1 pre-existing
  `#[ignore]` perf target); used as a fast pre-check on the two touched test files.
- `cargo make test`, run **unpiped** with its exit code read directly (output redirected to a
  file, not piped, so `$?` is the task's own status) — **exit 0**.
  - `coverage-check: OK — coverage held at 98.92% (3848/3890 lines).`
  - `extern-coverage: OK — every zanshin-ffi extern "C" fn is covered (allow: zanshin_buffer_free).`
  - Coverage **held** rather than rose, so `coverage-baseline.txt` is correctly unchanged by this
    pass. No baseline value was lowered and no `exclude_prefix` was added.
  - One intermediate red: `cargo fmt --all --check` flagged a >100-col closure in the new
    `tests/revset.rs` test. Reformatted; the re-run was clean. Clippy pedantic was green in both runs.
- `cargo make codegen` was **not** re-run this pass and did not need to be: no `.fbs`, no
  `extern "C"` signature and no rustdoc on the extern fn changed after the implementation commit.
- Manual: `_bmad-output/implementation-artifacts/epic-4-context.md` (24 Aug 01:59) is newer than
  every file in `_bmad-output/planning-artifacts/` (newest: `epics.md`, 23 Aug 23:17). Cache valid.
- Manual: builtin alias table re-checked line-by-line against
  `git -C ../jj show v0.42.0:cli/src/config/revsets.toml` — verbatim.
- Manual: `git status --porcelain` empty after the finalizing commit.

### Residual risks

- **This spec's own I/O-matrix row for `short_prefixes` is wrong about the CLI.** It states that
  an unresolvable symbol yields `ok:false` + `jj.revset_resolution_error` + no rows. jj v0.42.0
  actually warns and degrades to full-index prefixes (`test_log_bad_short_prefixes`); only a
  PARSE failure is a hard error. The code, its rustdoc, `docs/rust-error-codes.md` and two tests
  all implement the CLI behavior, which the intent's oracle clause mandates. The matrix row was
  left untouched because this workflow forbids editing `<intent-contract>`; it should be
  corrected the next time the contract is legitimately amended, or it will mislead a later reader.
- **`(commit_id, synthetic_elided)` is offered as a row key in three doc surfaces**
  (`schemas/envelope.fbs`, `docs/ffi-abi.md`, `graph.dart`) but is NOT unique: two children
  eliding to the same target produce two rows with identical `(commit_id, true)`, deliberately
  un-deduped for CLI parity. Positional keying — also documented, and listed first — is the only
  safe key. Correcting the wording touches four synchronized artifacts plus a codegen cycle, so it
  was not attempted here.
- **`ActiveLane`'s doc phrase "neither starts nor ends at that row's node"** is loose for a lane
  a merge edge REUSES at that row: the segment was opened by an earlier row and genuinely crosses,
  but the row's own edge also routes into it. The intent's invariant explicitly contemplates this
  ("nor is reused by an earlier edge") and the behavior is correct, so only the summary wording is
  imprecise.
- **Prefix lengths are proven unique but not proven MINIMAL** — for either the commit id or the
  change id. A length longer than necessary would pass. Minimality was out of scope for the
  finding that was fixed and is not asserted for the commit id either, so it was left symmetric.
- **The metadata walk is no longer index-only.** Every emitted node now costs a
  `store.get_commit_async`, an `is_empty` parent-tree merge, two prefix lookups and a containment
  check, so a repo with an unreadable object store that previously streamed topology now fails the
  call. This is by design; `epic-4-context.md`'s ~3 ms/10k figure predates it and is annotated as stale.
- **Two commits, not one.** The intent asked for a single focused commit; the session interruption
  makes that impossible without amending the published `03a2009`, which the project rules forbid.
