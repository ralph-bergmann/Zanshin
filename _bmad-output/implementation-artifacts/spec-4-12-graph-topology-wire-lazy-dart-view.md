---
title: 'Story 4.12: Graph topology wire — whole-revset scalar vectors + CSR, lazy Dart view, id → index lookups, one copy across isolates'
type: 'feature'
created: '2026-10-01'
status: 'done'
baseline_revision: '9d44be6151fb1cafb569743b46a2c42ee68c458e'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/decisions-review-4-10-to-4-13.md'
warnings: ['oversized']
deferred:
  - summary: >-
      No real-repo wire numbers: item 1's optional local real repo needs a path to one of
      Ralph's repos.
    evidence: |-
      The dispatch skipped the real-repo input (no path given). graph_wire.rs and
      benchmark/graph_wire.dart cover medium, large-10k loose, a git-gc-packed copy of
      large-10k and a 100k synthetic topology only. Run both against a COPY of a real repo
      (the topology call snapshots). Mirrored in deferred-work.md "Surfaced in Story 4.12".
    location: >-
      crates/zanshin-ffi/benches/graph_wire.rs, packages/zanshin_core/benchmark/graph_wire.dart
    severity: low
  - summary: >-
      graph_ids_test.dart's large-10k case costs ~80-90 s of the zanshin_core suite.
    evidence: |-
      The Ids row compares every node against show(revset: 'all()'), as the matrix prescribes;
      show computes every commit's file changes (~80 s for the 10k loose fixture, release
      cdylib). Timeout raised to 10 minutes for the coverage-instrumented run. If the gate time
      bites: drop the 10k case (medium covers 1,002 ids) or use a cheaper Rust display source
      (never a test-only extern). Mirrored in deferred-work.md "Surfaced in Story 4.12".
    location: packages/zanshin_core/test/worker/graph_ids_test.dart
    severity: low
  - summary: >-
      Story 9.25's tracking entry still says "Apply = evaluate via graphSlice", an API this story
      removed.
    evidence: |-
      sprint-status.yaml's 9-25-log-revset-input-presets-apply-save-completion comment ends
      "Apply = evaluate via graphSlice, Save = persist" (epics.md Story 9.25 likewise). graphSlice
      is gone since this story; the Apply path is RepoHandle.graphTopology and its "N revisions"
      count is GraphTopologyView.nodeCount. This story's intent forbids editing the 9.25 text
      ("settled when 9.25 is refined"), so the re-point waits for that refinement (Ralph).
      Mirrored in deferred-work.md "Surfaced in Story 4.12".
    location: >-
      _bmad-output/implementation-artifacts/sprint-status.yaml (9-25 entry), _bmad-output/planning-artifacts/epics.md (Story 9.25)
    severity: low
---

<intent-contract>

## Intent

**Problem:** The only graph read on the wire is `zanshin_graph_slice`: a table per row/edge/pass-through lane with hex target strings (~175 B/node), decoded eagerly into Dart objects (`graph.dart:373-433`) and copied twice across isolates (`readToken`'s `Uint8List.fromList` + the `SendPort` copy), while 4.10's index-only `Repo::graph_topology` — what the Dart layout engine (4.11) and the view (Epic 10) need — has no wire, no Dart view and no lookups.

**Approach:** Put `Repo::graph_topology` on the wire as a `GraphTopology` payload of scalar vectors + CSR (in `GraphSlice`'s `Payload` slot) behind a new request-buffer extern `zanshin_graph_topology`; read it in Dart through a lazy typed-data view (`GraphTopologyView`) with lazily built id → index lookups; move it worker → UI with exactly one copy (`TransferableTypedData`); remove the old lane path (extern, tables, Dart models, the `zanshin-graph` crate); decide the id encoding by measurement; sweep the docs.

## Boundaries & Constraints

**Always:**
- **Decisions are taken** (`decisions-review-4-10-to-4-13.md` § 4.12): OQ 1a REMOVE the old lane path, `GraphTopology` takes `GraphSlice`'s union slot (11) in place, `EXPECTED_EXPORTS` stays 61 · OQ 1b KEEP `Repo::walk_graph`, its tests (`crates/zanshin-jj/tests/{graph,warnings,graph_topology}.rs`) and the `graph_blueprint` bench · OQ 2 ids decided BY MEASUREMENT with the rule in Design Notes, (b) expected · OQ 3 the Missing edge carries NO target id.
- **Behaviour is 4.10's.** The extern is a transport over `Repo::graph_topology(revset, prioritize, short_prefixes, anchors, with_timestamps)` (unchanged): the pre-verb precondition runs exactly once; the envelope carries `precondition` + `warnings` on ok AND error arms (`precondition_envelope`), like every verb read. All five arguments are pass-throughs; Rust bakes in no default; `revset`, `prioritize`, `short_prefixes` are required on the wire (absent → `jj.invalid_input` `<field> is required`), absent `anchors` = `[]`, `with_timestamps` defaults to the wire's `false`.
- **Wire (ADR-0001):** `schemas/envelope.fbs` edited in place; `RequestKind.GraphTopology` APPENDED (value 30); `GraphTopology` replaces `GraphSlice` at Payload slot 11 (nothing renumbered); every generated file only via `cargo make codegen`. Null for absence: `timestamps` absent ⇔ not requested; the root's timestamp slot is 0 and reads `null` in Dart; a local ref's `remote` is absent; `change_offset` is kind-gated by a flags presence bit; `edge_target` is kind-gated (defined iff `kind != Missing`, the slot holds −1, Dart returns `null`).
- **Lazy Dart view:** O(1) per-node access, typed-data views over the aligned scalar vectors (a misaligned vector is copied, that one vector only), NO per-node objects allocated up front, a structurally required field missing (or of the wrong length) throws `ZanshinFfiException('ffi.unknown', …)` — never a `?? ''`/`?? []` coercion. Lookups (commit id → index; change id → indices, several for a divergent change) are built lazily on first use.
- **At most one copy across the isolate boundary** for the topology: the worker reads the token's native memory through views, copies it ONCE into a `TransferableTypedData`, frees the token, sends; the UI's `materialize()` is zero-copy. Every other extern keeps `readToken` + the `SendPort` copy. `docs/ffi-abi.md` states both counts.
- **Quality bar:** clippy pedantic refactor-not-suppress (WHY'd saturating casts only), rustfmt, SPDX first line, `# Errors`/`# Safety` rustdoc, no `unwrap`/`expect`/`panic!` in FFI-reachable code, scenario-named tests, no `#[ignore]`/`skip:`, no timing assertions; `dart analyze --fatal-infos --fatal-warnings` + `dart format` clean (including `benchmark/`). Dart NUL guards on the calling side (`ZanshinWorker`) and as adapter backstops; Rust does not re-check.
- **Coverage ratchet:** `crates/zanshin-ffi/src/graph.rs` keeps its path and must stay ≥ its baseline 99.81 − ε 0.10; no other file may drop; the new extern is credited by a `packages/zanshin_core` real-cdylib test; removed files leave `coverage-baseline.txt` by the gate's rewrite (never hand-lower an entry, never add `exclude_prefix`/`EXTERN_COV_ALLOW`); commit the rewritten baseline. Benches live in `benches/` / `benchmark/`, never in `src/` or `test/`.
- **Repo conventions:** fixtures never regenerated (special cases built in-test with `test_helpers`); commits on `main` with `--no-gpg-sign` and the `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` trailer; `sprint-status.yaml` — only the `4-12-…` status value + `last_updated`, plus item 8's dated note on the `# Epic 4:` comment line; never `sprint_plan.py generate`; `epic-4-context.md` edited LAST (stays newer than every planning artifact, keeps its `# Epic 4 Context:` prefix). Every deferral goes to the spec's `deferred:` AND a dated `deferred-work.md` section "Surfaced in Story 4.12 (bmad-build-auto, 2026-10-01)".

**Never:**
- No layout, priority classes or input builder (4.11); no painting/colour (Epic 10); no content changes (4.10's `commit_contents` untouched); no row-range API, lane cap, op-log graph, elided counts, synthetic rows.
- No change to `Repo::graph_topology`'s behaviour or signature; no Rust handle state; no new crate (the workspace drops to 7 `Cargo.toml` files).
- No Flutter UI (`app/` untouched); no `jj_lib` import outside `zanshin-jj`/`test-helpers`/`xtask`; no shelling to `jj` (tests and benches may shell to `tar`/`git` for fixture setup).
- No test-only extern; no barrel export of the new Dart types (10.12 exports them); never a Dart/FFI type named `GraphRef` or `GraphLayout`.
- No edits to the 9.25 story text (its `graphSlice` consumer is settled when 9.25 is refined); architecture.md `:32`/`:439-446` are 4.11's notes.

## I/O & Edge-Case Matrix

Fixture facts: **tiny-3-commits** — `all()` in `jj log` order `[@, c3, c2, c1, root]` (`@` → root; root ← c1 ← c2 ← c3), loose objects, no remote bookmarks, `trunk()` = root. **medium-1k-commits** — 1002 nodes, one octopus merge (3 parents), every `all()` edge Direct. **large-10k-commits** — 10,002 nodes, loose objects.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Wire == oracle | tiny + medium, `all()`, `DEFAULT_GRAPH_PRIORITIZE`, `DEFAULT_LOG_REVSET`, anchors `[trunk(), present(@)]`, no timestamps | every vector decodes to `Repo::graph_topology`'s value on a second handle: op id, `all_count`, ids, flags, `change_offset`, prefix lens, `parent_count` (medium's octopus = 3), CSR edges, anchors (tiny `[[4],[0]]`); `timestamps` absent | — |
| Timestamps on | tiny, `with_timestamps = true` | vector length n; non-root == oracle; root slot 0, Dart `null` | — |
| Narrowed revset | tiny, `c3 \| c1` (by id) | edges == oracle, among them c3 → c1 Indirect and c1's Missing edge (target slot −1, Dart `null`); `all_count` 5 ≠ n | — |
| Repeated target | in-test merge M(A, B), B child of A, `all() ~ B` | M's CSR range holds a Direct AND an Indirect edge to A's index, order == oracle | — |
| Empty revset | `none()` | n = 0: per-node vectors present + empty, `edge_start == [0]`, `anchor_start` length = anchors + 1, all zeros | — |
| Refs / WCs / divergent / hidden | in-test: `set_local_bookmark`, `set_remote_bookmark` (tracked), `set_tag`, `add_workspace`, `add_divergent_twin`, an abandoned commit named by id | `refs` sorted by node (bookmarks then tags per node), local `remote` absent (Dart `null`), remote synced/conflicted == oracle; `working_copies` entries per node; divergent flag + presence bit + `change_offset` set on both twins; hidden flag on the abandoned commit | — |
| jj errors | bogus revset/prioritize/anchor; unknown bookmark; NUL inside an anchor (Rust-built request); malformed repo config; corrupt `op_heads`; c2's loose object deleted + timestamps | `jj.revset_parse_error`; `jj.revset_resolution_error`; `jj.revset_parse_error`; `jj.config_error`; `jj.jj_lib_error`; `jj.jj_lib_error` — each error envelope carries `precondition` when the snapshot ran | no partial payload |
| FFI ladder | null data; unverifiable bytes; wrong `RequestKind`; zero handle + valid buffer; absent `revset`/`prioritize`/`short_prefixes`; absent `anchors` | `ffi.null_pointer`; `ffi.invalid_argument`; `ffi.invalid_argument` (before the handle); `ffi.invalid_handle`; `jj.invalid_input` `<field> is required`; ok with no anchors | no deref |
| Precondition + warnings | WC file written before the call; `short_prefixes` naming an unknown bookmark | `precondition().was_snapshot_taken()`; warning `jj.short_prefixes_failed` (Dart `warnings`) | — |
| Dart view contract | synthetic envelopes | random access == generated-accessor values; null for absence (above); missing required vector / wrong length → `ffi.unknown`; error envelope → `ZanshinFfiException`; wrong payload → `ffi.unknown`; unknown edge-kind byte → `ffi.unknown` on access; aligned bytes → 0 copied vectors, views share the buffer; bytes at offset 1 → copies, equal values; a view over `malloc`ed native memory reads the same | — |
| Lookups | synthetic + real | `indexOfCommitId` hit/miss (`null`); `indicesOfChangeId` returns both divergent twins, `[]` on a miss | — |
| Transfer | real cdylib, `sendRaw((id) => GraphTopologyCommand(commandId: id, …))` | response is a `TransferResult`; its materialized bytes back a view with 0 copied vectors | — |
| Ids (option (b) only) | tiny, medium, large-10k extracted with `tar` | for EVERY node `view.commitId(i)` / `view.changeId(i)` == Rust's display strings from `show(revset: 'all()')` | — |
| Dart calling side | NUL in revset/prioritize/shortPrefixes/an anchor; closed handle; unknown handle id | `ArgumentError` before `send`; `StateError`; `ffi.invalid_handle`; `lastPrecondition` updated by an ok call | — |

</intent-contract>

## Code Map

**Wire (`schemas/envelope.fbs`, then `cargo make codegen`)**
- `:51-101` `RequestKind` — append `GraphTopology` after `CommitContents` (`:100`); `:62` "For the other 27 tables" → 28.
- after `CommitContentsRequest` (`:513-522`) — `table GraphTopologyRequest { kind: RequestKind; revset: string; prioritize: string; short_prefixes: string; anchors: [string]; with_timestamps: bool; }`, doc in the `Arguments of \`zanshin_graph_topology\` (Story 4.12) — …` style (required vs absent rules).
- changelog `:524-553` — annotate `:531` (`Story 4-2 : GraphSlice ✓ …` → "(removed 4-12; slot 11 reused by GraphTopology)") and add `//   Story 4-12 : GraphTopology ✓ (GraphSlice's Payload slot 11)`.
- `:729-734` `enum GraphEdgeKind : byte { Direct, Indirect, Missing }` — KEEP (the edge-kind vector uses it); doc → mirrors `zanshin_jj::GraphEdgeKind`.
- `:736-832` — DELETE `GraphRowEdge`, `GraphCommitRef`, `GraphActiveLane`, `GraphRowMeta`, `GraphRow`, `GraphSlice`; ADD `enum TopologyRefKind : ubyte { Bookmark, Tag }`, `table TopologyRef { node: uint; kind: TopologyRefKind; name: string; remote: string; synced: bool; conflicted: bool; }`, `table TopologyWorkingCopy { node: uint; workspace: string; }`, `table GraphTopology` (fields in Design Notes § Wire layout) with full docs (flag bits, kind-gated −1 slot, root slot 0, CSR definitions, strides, sort orders, `all_count` = visible `all()` only).
- `:837` LogDefaults doc → `zanshin_graph_topology`'s pass-throughs (its `synthetic_elided` field stays: the effective config value; the topology call takes no such parameter). `:989` (SearchMatch's "same rule as GraphRowMeta.change_offset") → point at `ShowRequest.limit` / state the rule; `:1381` (CommitContent "Field names mirror GraphRowMeta's") → drop the dangling reference. `:1410` `GraphSlice,` → `GraphTopology,` (same position).
- Regenerated: `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart`, `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`.

**zanshin-ffi**
- `crates/zanshin-ffi/src/graph.rs` — REWRITE in place (keeps the 99.81 baseline). Drop `zanshin_graph` imports, `map_lane_stream_err`, `edge_kind`, `refs_offset`, `meta_offset`, `row_offset`, `graph_slice_to_envelope`, `zanshin_graph_slice` and their tests. Add: `map_topology_err(RevsetError) -> FfiErrorObj` (arms of today's `:32-62` minus the `LaneStreamError` wrapper: `Precondition` → `map_precondition_err`; `ParseError` → `JJ_REVSET_PARSE_ERROR`; `ResolutionError` → `JJ_REVSET_RESOLUTION_ERROR`; `JjLibError` → `JJ_JJ_LIB_ERROR`; `Config(ConfigError::Load)` → `JJ_CONFIG_ERROR`; `DanglingEdge` → `GRAPH_DANGLING_EDGE`; reason/target in `context`, `report: None`); `read_graph_topology_request` (template `commit_contents.rs:65-82`: `reject_null_request` → `root_with_opts` → `expect_request_kind(…, GraphTopology)` → `missing_field` per required string; anchors via `.into_iter().flatten()`); with (b) a pure `TopologyIds::encode(&zanshin_jj::GraphTopology) -> Result<TopologyIds, RevsetError>` (hex → bytes, reverse-hex → bytes `'z' - c`, one stride per column from node 0, 0 when n = 0; a malformed or odd-length id or a stride mismatch → `RevsetError::JjLibError`); `pub fn graph_topology_to_envelope(…, report: &CallReport) -> Vec<u8>` (`#[must_use]`, `pub` for the bench); the extern `zanshin_graph_topology(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf` (request read BEFORE `session_from_handle`; `session.repo.graph_topology(…)` then `.and_then` the id encoding; `precondition_envelope(&mut session.repo, result, map_topology_err, |v, p| …)`; `catch` + `vec_into_token`; `# Errors` bullets exactly: `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.stale_working_copy`, `jj.config_error`, `jj.jj_lib_error`, `graph.dangling_edge`). Inline tests: builder round-trip through `flatbuffers::root::<fbs::Envelope>` + typed accessors + `Verifier` (every vector, flag bits, −1 slots, absent vs present timestamps, root slot 0, refs incl. tag + remote, working copies, anchors incl. empty, n = 0, report fields), the id encoder (happy, reverse-hex extremes `z`/`k`, malformed, odd length, stride mismatch, n = 0), the mapper per variant, the request reader ladder.
- `crates/zanshin-ffi/src/envelope.rs:190-192` — `GRAPH_DANGLING_EDGE` doc → the topology call's Direct/Indirect target outside its node set. `:155-164` docs still say `graph.rs` (true).
- `crates/zanshin-ffi/src/log_defaults.rs:10` — `zanshin_graph_slice` → `zanshin_graph_topology`'s `revset`/`prioritize`/`short_prefixes`.
- `crates/zanshin-ffi/Cargo.toml:31` — drop `zanshin-graph`; add `[[bench]] name = "graph_wire" harness = false` with a `# WHY:` (pattern `:38-46`).
- `crates/zanshin-ffi/tests/graph_ffi.rs` — RESHAPE for the topology (keep env pin `:34-51`, `read_and_free`, `parse_envelope`, `open_fixture`, `assert_error*` helpers; oracle = `zanshin_jj::Repo::open(path)?.graph_topology(…)` on a second handle; a wire → comparable-struct mapper reading every vector through typed accessors, ids re-hexed). Every zanshin-ffi matrix row + carried-over behaviours: empty `short_prefixes` disables disambiguation, unknown-bookmark `short_prefixes` degrades with a warning, blank prioritize → parse error, repo `[revset-aliases]` written after open resolve on the next call (old `:820-854`), re-derive from head (an external commit appears on the next call).
- `crates/zanshin-ffi/tests/snapshot_ffi.rs` — `:35` import, the `ok_row` arm `:429-437` and the list entry `:610` re-pointed to `"graph_topology"` (request built with `request(|b| …)` `:406-410`).
- `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs` — `EXPECTED_EXPORTS` stays 61 (`:37`); `:94` comment + the synthetic header literal `:419-429` no longer claim the real `zanshin_graph_slice` exists (neutral name).
- `crates/zanshin-ffi/benches/graph_wire.rs` (**NEW**) — template `benches/graph_topology.rs` (env pin `:45-57`, `measure`/`measure_with` `:70-98`, packed copy `:256-267` via `git … gc`): stores medium loose, large-10k loose + packed, plus a 100k synthetic `zanshin_jj::GraphTopology` (exploratory). Rows: payload bytes + bytes/node + builder time (timestamps off/on); the full extern call; the OQ 2 comparison (id columns as `[string]` vs stride `[ubyte]`: bytes + build time) and the flag-packing comparison (one `[ubyte]` vs six `[bool]`), both built with the raw `flatbuffers` API inside the bench.

**zanshin-jj (docs/tests only — no code change)**
- `src/graph.rs:3` and `:45` — dated notes: the lane crate is gone; `walk_graph` stays as the `jj log`-faithful read (4.10's oracle); edge-kind order follows the wire's `GraphEdgeKind`.
- `src/commit_meta.rs:56`, `src/revset.rs:338`, `src/file.rs:220`, `README.md:135`, `tests/graph.rs:4`, `tests/revset.rs:171-172`, `tests/api_stability.rs:442` (`map_lane_stream_err` → `map_topology_err`), `benches/graph_blueprint.rs:6` — reword the slice/lane-crate mentions.

**Workspace**
- `Cargo.toml:11` (`default-members`) and `:53` (workspace dep) — drop `zanshin-graph`; `Cargo.lock` updates by build.
- `crates/zanshin-graph/` — DELETE (Cargo.toml, `src/{lib,lane,slice,stream}.rs`, `tests/{lane,slice,stream}.rs`, `tests/common/mod.rs`).
- `Makefile.toml:247-254` (`test-cargo-hygiene`) — expect 7 tracked `Cargo.toml` files, comment "root + six crates".
- `cbindgen.toml:20` — drop `zanshin-graph` from the dependency list comment. `crates/README.md:3` ("six" → "five"), `:11` row removed with a dated note.

**Dart bridge (`packages/zanshin_core`)**
- `lib/src/ffi/graph.dart` — REWRITE. Keep `defaultGraphPrioritize` (`:32`), `defaultLogRevset` (`:43`), `defaultShortPrefixes` (`:69`), `defaultGraphAnchors` (`:78`), docs re-pointed to `RepoHandle.graphTopology`; delete `defaultSyntheticElided` (`:55`, orphaned: it only pre-filled `graphSlice`) and everything from `:80` (adapter, models, decoder). Add: the adapter `FfiBuffer zanshinGraphTopology(int rawHandle, {required String revset, required String prioritize, required String shortPrefixes, required List<String> anchors, required bool withTimestamps})` (NUL backstops, `fbs.GraphTopologyRequestObjectBuilder(kind: fbs.RequestKind.GraphTopology, …)`, `withRequestBytes` + `FfiBuffer.fromToken` — NO `readToken` copy); `enum GraphEdgeKind { direct, indirect, missing }`, `enum TopologyRefKind { bookmark, tag }`, `final class TopologyRef` / `TopologyWorkingCopy`; `final class GraphTopologyView` (API in Design Notes § Dart view) with `factory GraphTopologyView.fromEnvelope(Uint8List bytes)`.
- `lib/src/ffi/request_bytes.dart:46-54` (`withRequestBytes`) and `lib/src/ffi/ffi_buffer.dart:29-99` (`FfiBuffer.fromToken`/`bytes`/`dispose`) — reuse, unchanged.
- `lib/src/worker/responses.dart` — add `final class TransferResult extends WorkerResponse { final TransferableTypedData data; }` with the one-copy doc.
- `lib/src/worker/commands.dart:178-215` — replace `GraphSliceCommand` with `GraphTopologyCommand` (handleId, revset, prioritize, shortPrefixes, `List<String> anchors`, `bool withTimestamps`; implements `HandleScopedCommand`; template `CommitContentsCommand` `:807-832`).
- `lib/src/worker/isolate.dart` — `:32` import kept; `:450-456` `send()` gains `TransferResult(:final data) => _recordPrecondition(cmd, data.materialize().asUint8List())`; the three other exhaustive switches (`:372-380`, `:429-436`, `:561-570`) throw `StateError` on `TransferResult`; add `@visibleForTesting Future<WorkerResponse> sendRaw(WorkerCommand Function(int commandId) build) => _sendCommand(build(_correlator.allocateId()))` (command ids come from the private correlator, `:370`); replace `graphSlice` (`:603-638`) with `Future<GraphTopologyView> graphTopology(int handleId, {required String revset, required String prioritize, required String shortPrefixes, required List<String> anchors, required bool withTimestamps})` (calling-side `rejectInteriorNul`/`rejectInteriorNuls` before `send`, template `commitContents` `:1343-1362`); replace the dispatch arm `:1797-1818`: unknown handle → `BufferResult(_invalidHandleEnvelope(…))`, else `FfiBuffer buf = zanshinGraphTopology(…)`; `try { data = TransferableTypedData.fromList([buf.bytes]); } finally { buf.dispose(); }` then send `TransferResult(data)`.
- `lib/src/worker/handle.dart:10-11`, `:124-163`, `:207-209` — imports; `RepoHandle.graphTopology({required String revset, String prioritize = defaultGraphPrioritize, String shortPrefixes = defaultShortPrefixes, required List<String> anchors, required bool withTimestamps})` with the `_closed` `StateError` guard (doc names `defaultGraphAnchors` as the pre-fill and `commitContents` as the continuation at `operationId`); `logDefaults` doc names `graphTopology`.
- `lib/src/ffi/log_defaults.dart:29-33` — doc → `RepoHandle.graphTopology`; drop the `defaultSyntheticElided` mention.
- Tests: `test/ffi/graph_test.dart` REWRITE (decode contract with synthetic envelopes built by `fbs.EnvelopeObjectBuilder` + `fbs.GraphTopologyObjectBuilder`; every view value checked against the generated `fbs.GraphTopology` accessors — project-context's "read through the generated typed accessors" rule; keep the `defaultGraphAnchors` pin `:84-90`); `test/worker/graph_test.dart` REWRITE (real cdylib, template `test/worker/commit_contents_test.dart:35-63`; credits the extern; the Transfer row via `sendRaw`; `commitContents(operationId: view.operationId, commitIds: [view.commitId(0)])` continuation); `test/worker/graph_ids_test.dart` (**NEW**, option (b) only: extract each fixture with `Process.run('tar', ['-xf', '../../test-fixtures/repos/<name>.tar.zst', '-C', dir])`, `worker.openRepo`, compare every node against `show(revset: 'all()')`'s `change.commitId`/`change.changeId`); `test/worker/warnings_test.dart:27`, `:150-162` → `graph_topology_reports_a_short_prefixes_index_that_does_not_load`; `test/ffi/warning_test.dart:37`, `:128-133` → a `graphTopology` row (minimal valid n = 0 payload); `test/worker/log_defaults_test.dart:22-23`, `:55-62` → drop `defaultSyntheticElided`, assert `syntheticElided` `isTrue`; `test/ffi/request_bytes_test.dart:7` comment.
- `benchmark/graph_wire.dart` (**NEW**, outside `test/`): synthetic OQ 2 + flag comparison (n = 10,002 and 100k; `fb.Builder` `writeList` of strings vs `writeListUint8`; first access = read all ids as `String`s from a fresh `BufferContext`, median of ≥ 15 runs after warm-up) and, for each repo dir given as an argument, the real path via `ZanshinWorker.start()` → `openRepo` → `graphTopology(…, anchors: defaultGraphAnchors, withTimestamps: false/true)`: call total, view construction, a full pass over every node (ids, flags, edges), lookup build, `copiedVectorCount`. Prints numbers only.

**Docs, planning, tracking**
- `docs/ffi-abi.md` — symbol-index row `:466` → `zanshin_graph_topology` (`(uint64_t handle, const uint8_t *data, uintptr_t len)`, `GraphTopologyRequest`, `GraphTopology`, codes = the header bullets exactly, `4.12`); stale counts `:36` (60 → 61), `:204`/`:206` (→ thirty of 61 / twenty handle-scoped); request-buffer counts `:267`, `:318`, `:330`, `:363` (28 → 29), `:372-373` (29 tables + 1 = the 30), `:392` (27 → 28); `:541-544` names `zanshin_graph_topology`; REPLACE the slice section `:861-1111` with `## GraphTopology payload and zanshin_graph_topology (Story 4.12)` (shape of the CommitContents section `:1242-1340`: prototype, request, pass-throughs, precondition + warnings, schema block, per-field rules incl. flag bits, strides + Dart formatting, kind-gated target, null for absence, CSR, refs/WC sort order, `all_count`, BOTH copy counts, the error table); `:1116`, `:1199-1206` (LogDefaults offers → the topology call), `:1250` (topology wire now exists), `:1338-1340` (`defaultGraphAnchors` path unchanged).
- `docs/rust-error-codes.md` — `:27` `graph` domain → the graph topology call (dated); `:40` nineteen → twenty (Story 4.12); `:41` `ffi.null_pointer` + `:46` `ffi.invalid_argument` (twenty-nine → thirty) + the `jj.invalid_input` row: "also emitted — Story 4.12 by `zanshin_graph_topology`"; `:45` keeps `graph.rs`; `:55-57` slice clauses → "for `zanshin_graph_slice` (removed in Story 4.12); since then `graph.rs::map_topology_err` for `zanshin_graph_topology`"; `:64` `graph.dangling_edge` meaning → `zanshin_jj::RevsetError::DanglingEdge`, status → emitted by `zanshin_graph_topology`; `:126` `jj.short_prefixes_failed` emitter → `graph_topology`; `:153`, `:155` → `zanshin_graph_topology`. Grep the file for every remaining `graph_slice`/`zanshin-graph` (e.g. a `ffi.utf8_error` emitter list) and date-note it.
- `docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md` — ONE dated note after `:7` covering the six `zanshin-graph` mentions (`:7`, `:40`, `:82`, `:89`, `:94`, `:113`); accepted text unchanged.
- `_bmad-output/project-context.md` — dated notes: frontmatter override `:14` (`zanshin_graph::collect_lanes` → removed in 4.12, the topology call + Dart layout), the worker-responses rule `:264-265` (the topology crosses as a `TransferableTypedData`, read through `GraphTopologyView`'s typed-data views, checked against the generated accessors in tests), `:349-351` (the `zanshin-graph` test exception lapses with the crate), `:697-712` (the lane-state / `collect_lanes` bullets → removed; the graph read is `zanshin_graph_topology`). YAML single-quoted frontmatter: escape `'` as `''`.
- `_bmad-output/planning-artifacts/architecture.md` — dated notes at `:41`, `:143`, `:459`, `:601`.
- `_bmad-output/planning-artifacts/epics.md` — dated retitle note "(2026-10-01: the lane crate was removed in 4.12)" on the Epic List entry `:375` and the heading `:2811`; a `> **Delivered (2026-10-01, Story 4.12 done):** …` note at the end of § Story 4.12 (before `### Story 4.13`, `:4009`; format of `:3600`).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `:48` comment retitle note; `:52` status `backlog` → `done` (comment kept); `last_updated`.
- `_bmad-output/implementation-artifacts/decisions-review-4-10-to-4-13.md` — under `## Taken during the runs` add `### 4.12` (table like `### 4.10`): OQ 2's measured numbers + the choice; the flag packing's numbers + choice; any other Ralph-marked question met.
- `_bmad-output/implementation-artifacts/deferred-work.md` — section "Surfaced in Story 4.12 (bmad-build-auto, 2026-10-01)" mirroring every spec deferral.
- `_bmad-output/implementation-artifacts/epic-4-context.md` — LAST: title retitle note, 4.12 → done, `:45` wire line states the measured id choice.
- `coverage-baseline.txt` — rewritten by the gate (zanshin-graph entries drop); commit it.

## Tasks & Acceptance

**Execution:**
- [x] `crates/zanshin-ffi/benches/graph_wire.rs` (OQ 2 + flag comparison part only, raw `flatbuffers` API over `Repo::graph_topology` output) + `packages/zanshin_core/benchmark/graph_wire.dart` (synthetic part) + the `[[bench]]` entry -- run `cargo bench -p zanshin-ffi --bench graph_wire` and `dart run benchmark/graph_wire.dart` (env of `Makefile.toml` `[tasks.test-core]`), apply the Design Notes decision rule, record numbers + choice in § Measurements -- the schema depends on the measured id choice.
- [x] `schemas/envelope.fbs` then `cargo make codegen` -- request table, `GraphTopology` + ref/WC tables in slot 11, appended `RequestKind`, removed slice tables, doc lines -- the wire.
- [x] `crates/zanshin-ffi/src/{graph,envelope,log_defaults}.rs`, `crates/zanshin-ffi/Cargo.toml` -- mapper, request reader, id encoder (if (b)), builder, extern, inline tests -- topology over FFI.
- [x] delete `crates/zanshin-graph/`; `Cargo.toml`, `Makefile.toml`, `cbindgen.toml`, `crates/README.md` -- workspace without the lane crate.
- [x] `crates/zanshin-ffi/tests/{graph_ffi,snapshot_ffi,ffi_abi_doc_sync}.rs` -- every zanshin-ffi matrix row, re-pointed witness, export count 61.
- [x] `crates/zanshin-jj/{src/graph.rs,src/commit_meta.rs,src/revset.rs,src/file.rs,README.md,tests/graph.rs,tests/revset.rs,tests/api_stability.rs,benches/graph_blueprint.rs}` -- doc rewording only.
- [x] `packages/zanshin_core/lib/src/{ffi/graph.dart,ffi/log_defaults.dart,worker/responses.dart,worker/commands.dart,worker/isolate.dart,worker/handle.dart}` -- adapter, view, lookups, `TransferResult`, `sendRaw`, command, worker + handle methods; slice code removed.
- [x] `packages/zanshin_core/test/{ffi/graph_test.dart,worker/graph_test.dart,worker/graph_ids_test.dart,worker/warnings_test.dart,ffi/warning_test.dart,worker/log_defaults_test.dart,ffi/request_bytes_test.dart}` -- every Dart matrix row.
- [x] finish `benches/graph_wire.rs` (real builder + extern rows, 100k synthetic) and `benchmark/graph_wire.dart` (real path on extracted large-10k loose + a `git gc`-packed copy in the scratchpad); run both; record § Measurements -- item 1's numbers.
- [x] `docs/{ffi-abi,rust-error-codes}.md`, `docs/adr/0002-…md`, `_bmad-output/{project-context.md,planning-artifacts/architecture.md,planning-artifacts/epics.md}`, `decisions-review-4-10-to-4-13.md`, `deferred-work.md` -- item 8's sweep, dated notes, decisions, deferrals.
- [x] run `cargo make test` (≈ 13 min; `nohup … > <scratchpad>/gate.log 2>&1 &`, then `caffeinate -w <pid>` in the same turn, exit code from the log/`wait`; never piped to `tail`) -- fix by adding tests; keep the rewritten `coverage-baseline.txt`; then `sprint-status.yaml`, and `epic-4-context.md` LAST. Do not commit (the run commits at finalization).

**Acceptance Criteria:**
- Given the finished tree, when `git grep -n -e zanshin_graph_slice -e GraphSlice -e graphSlice -e zanshin-graph -e collect_lanes -e stream_lanes -- ':!_bmad-output' ':!spikes' ':!docs/adr/0001*'` runs, then every hit is a dated note or history line (no code, schema, test or build reference), `crates/zanshin-graph` does not exist, and `cargo metadata` lists no `zanshin-graph` package.
- Given a Dart `RepoHandle` on a fresh repo, when `graphTopology(revset: 'all()', anchors: defaultGraphAnchors, withTimestamps: false)` runs through the real cdylib, then it returns a `GraphTopologyView` with 2 nodes (`@` then root), anchors `[[1], [0]]`, `allCount` 2, `operationId` == `opLog(limit: 1).single.id`, and `commitContents(operationId: view.operationId, commitIds: [view.commitId(0)])` returns that commit's content.
- Given the measurements, when the spec and the decisions file are read, then § Measurements holds both id options' payload bytes, Rust build time and Dart first-access time (and both flag layouts') at medium + large-10k loose + packed, the choice follows the decision rule, and `### 4.12` under `## Taken during the runs` records it.
- Given the finished tree, when `cargo make codegen` has run and `cargo make test` runs unpiped, then it exits 0 with `extern-coverage: OK` and `coverage-check: OK`, `crates/zanshin-ffi/src/graph.rs` ≥ 99.71 %, `EXPECTED_EXPORTS` is 61, and `git status` is clean after the finalization commit.

## Spec Change Log

## Review Triage Log

### 2026-10-01 — Review pass
- verdicts: 40 findings — high 0, medium 3, low 25, false 12, maybe-false 0
- findings:
  - `[medium]` `[patch]` (verification-gap) No Dart test proves `prioritize` reaches Rust; the slice's bogus-prioritize witnesses were dropped — added `prioritize: 'bogus_function()'` (→ `jj.revset_parse_error`) and `'nonexistent-bookmark-xyz'` (→ `jj.revset_resolution_error`) with a valid `revset` to `graph_topology_surfaces_each_jj_error_with_its_precondition` (`test/worker/graph_test.dart`).
  - `[low]` `[patch]` (verification-gap) `indicesOfChangeId`'s third-and-later arm (a change divergent 3+ ways) never ran — added `indicesOfChangeId returns every node of a change divergent three ways` (`test/ffi/graph_test.dart`).
  - `[false]` `[reject]` (intent-alignment) The production `graphTopology()` path's one copy is asserted only through `sendRaw` — the matrix's Transfer row prescribes `sendRaw`, which runs the same dispatch arm (`TransferableTypedData.fromList` once, then dispose); the production path returns a view over the materialized bytes in every worker test; no bad outcome.
  - `[low]` `[reject]` (intent-alignment) Rust-built bytes meet the Dart view only on a 2-node repo, an empty revset, a warning case and the id fixtures — the view is pinned field by field against the generated accessors and the Rust wire against the oracle, both over the same schema; a Rust-bytes test with refs/divergence/Missing edges would need new Dart-side repo setup (more than a direct correction) and no defect was shown.
  - `[low]` `[patch]` (intent-alignment) The Lookups row's "real" side covers only hits — the fresh-init worker test now also asserts a real miss for `indexOfCommitId` (`null`) and `indicesOfChangeId` (`[]`); divergent twins stay synthetic (the lookup is surface-independent; Rust pins real divergence).
  - `[false]` `[reject]` (intent-alignment) `graph_ids_test.dart` joins on commit id instead of matching node to node — with unique commit ids and equal counts the join pins EVERY node's commit id and change id to Rust's display strings (`graph_ids_test.dart:63-70`).
  - `[false]` `[reject]` (intent-alignment) The extern adds an encoder failure arm tested only inline — the Code Map prescribes `TopologyIds::encode` → `RevsetError::JjLibError` with inline tests; `zanshin-jj` only yields well-formed ids, so the arm is unreachable through the extern.
  - `[low]` `[reject]` (intent-alignment) An unknown `TopologyRefKind` byte surfaces as the generated reader's `StateError`, not `ffi.unknown`; nested ref strings are checked on first `refs` read — only a broken producer writes it (the cdylib ships with the bridge) and it already fails loudly; turning it into `ffi.unknown` adds a guard. Recorded in the decisions file (`### 4.12`).
  - `[false]` `[reject]` (intent-alignment) The OQ 2 decision rests on bench-local builders, no real repo, benches outside the gate — the spec prescribes raw-`flatbuffers` builders inside the bench for the comparison, the real repo is already deferred, benches are excluded from the gate by project rule.
  - `[false]` `[reject]` (intent-alignment) `sprint-status.yaml` says `done` while the spec is `in-review`, commit pending — this run's finalization sets the spec to `done` and commits everything in one change.
  - `[low]` `[patch]` (intent-alignment) `graph_ids_test.dart`'s timeout comment says "debug build" while the spec says release — `native_toolchain_rust`'s `RustBuilder` defaults to `BuildMode.release`; the comment now says the hook's release build.
  - `[low]` `[patch]` (intent-alignment) epics.md's Delivered note says "Precondition + warnings on every arm" — reworded to "on the ok arm and on every error arm after the snapshot ran" (the FFI ladder's refusals carry none).
  - `[low]` `[reject]` (edge-case) `edgeStart(nodeCount)` / `edgeEnd(-1)` return a value instead of a `RangeError` — only a caller indexing outside `[0, n)` meets it; in-range loops never do; the fix adds guards.
  - `[low]` `[reject]` (edge-case) A non-Missing `edge_target` of −1 or ≥ n is not rejected — Rust only writes in-range targets (a dangling one is `graph.dangling_edge` before any byte is written); value validation beyond the spec's presence/length contract would add an O(E) guard. Recorded in the decisions file.
  - `[low]` `[reject]` (edge-case) `edge_start` / `anchor_start` not starting at 0 is not rejected — Rust writes 0 first by construction (`graph.rs:269`, `:341`); malformed-buffer only; guard.
  - `[low]` `[reject]` (edge-case) Unsorted refs / working copies or a node ≥ n break the binary search silently — Rust emits both in node order by construction (`graph.rs:290`, `:319`); malformed-buffer only; guard.
  - `[low]` `[reject]` (edge-case) A vector uoffset past the buffer end escapes as a raw `RangeError` — corrupt buffers do the same through every generated accessor of the bridge; malformed-buffer only; guard.
  - `[false]` `[reject]` (edge-case) A view over native `FfiBuffer` bytes read after `dispose()` — documented contract (`graph.dart:219-221`); the worker copies into the `TransferableTypedData` before disposing and every returned view owns its bytes; no code path reads a view after dispose.
  - `[false]` `[reject]` (edge-case) `graph_topology_to_envelope(with_timestamps = true)` on a topology loaded without timestamps writes zeros — both callers (the extern, `graph.rs:493`, and the bench) pass the flag the topology was loaded with.
  - `[medium]` `[patch]` (edge-case) The removed Dart `prioritize` witness — same root cause and fix as the first row.
  - `[low]` `[reject]` (edge-case) AC 1's `git grep … ':!_bmad-output'` exits 128 (git reads `_` as pathspec magic) — the fix edits this build's spec; run as `':(exclude)_bmad-output' ':(exclude)spikes' ':(exclude)docs/adr/0001*'`, every hit is a dated note or history line.
  - `[low]` `[reject]` (blind) AC 1's command fails as written — same as the previous row.
  - `[false]` `[reject]` (blind) Tracking says done while the spec is in review — finalization sets the spec to `done` in the same commit.
  - `[low]` `[defer]` (blind) Story 9.25's tracking entry still says "Apply = evaluate via graphSlice", untracked — the intent forbids editing the 9.25 text ("settled when 9.25 is refined"); recorded in `deferred:` and `deferred-work.md` for the 9.25 refinement.
  - `[medium]` `[patch]` (blind) No Dart test proves `prioritize` reaches Rust — same root cause and fix as the first row.
  - `[low]` `[reject]` (blind) Unknown `TopologyRefKind` byte → `StateError` vs `ffi.unknown` for an edge kind, undocumented — same as the intent-alignment row; recorded in the decisions file.
  - `[low]` `[reject]` (blind) CSR values (`edge_start[0]`, monotonicity, target and `anchor_node` ranges) are not checked — same as the edge-case rows: a trusted producer guarantees them; the guard was rejected and the scope recorded in the decisions file.
  - `[low]` `[patch]` (blind) `GraphTopologyView.bytes` is a public mutable `Uint8List` beside unmodifiable typed views — the view now stores `bytes.asUnmodifiableView()`; the memory test pins that a write through it throws.
  - `[low]` `[reject]` (blind) An id-encoder failure surfaces as `jj.jj_lib_error`, not a `graph.*`/`internal.*` code — unreachable (`zanshin-jj` yields well-formed ids) and the Code Map prescribes `JjLibError`; a new code would add registry surface.
  - `[low]` `[reject]` (blind) The ids make a hex round trip (`zanshin-jj` formats, `zanshin-ffi` parses back), no deferred raw-bytes accessor — 146–159 µs at 10k against a 22 ms call (§ Measurements, Table 3), and the intent forbids changing `Repo::graph_topology`'s signature; no harm worth tracking.
  - `[false]` `[reject]` (blind) `graph_ids_test.dart` hard-codes `../../test-fixtures/repos/…` — the Code Map prescribes that path and the suite always runs from `packages/zanshin_core` (`[tasks.test-core]` `cwd`).
  - `[low]` `[reject]` (blind) The large-10k ids case costs ~80–90 s without extra encoding coverage — the matrix's Ids row requires large-10k; the cost is already a spec deferral.
  - `[low]` `[patch]` (blind) The same test's comment says "debug build" — same fix as the intent-alignment row.
  - `[false]` `[reject]` (blind) `crates/README.md` "five crates" contradicts `Makefile.toml` "root + six crates" — the README counts its table's product crates (`test-helpers` was never listed; 6 → 5), the Makefile counts tracked manifests (root + 6); the same split stood before (six vs seven).
  - `[low]` `[reject]` (blind) Regenerated `zanshin_ffi.h` / `bindings.dart` gained and lost unrelated `*_VT_*` constants — pre-existing cbindgen de-duplication by name; nothing consumes those constants (a consumer would not compile); changing it means cbindgen configuration.
  - `[false]` `[reject]` (blind) `hex_nibble`'s comment ("the decoder the § Measurements build times were taken with") mis-describes Table 1 — the bench's decoder (`benches/graph_wire.rs:304-353`) uses the same branch-free nibble functions, and Table 3 timed this production encoder.
  - `[false]` `[reject]` (blind) `LogDefaults.synthetic_elided` has no consumer and no tracked owner — the owner is recorded: sprint-status's 10.x view entry ("syntheticElided no longer sent: 4-10's topology has no synthetic nodes; its meaning stays 10-4 (a)") and 4-10's non-goals (elided N → 10-4 (a)).
  - `[low]` `[reject]` (blind) Dart first access was measured under JIT and is noisy — the decision does not depend on it ((a) loses on bytes, 2.67×, and on Rust build, +20 %); flagging it would edit the spec.
  - `[low]` `[patch]` (blind) `docs/ffi-abi.md` § LogDefaults says `RepoHandle.graphTopology`'s defaults are "unchanged" — reworded: `prioritize` / `shortPrefixes` default to the builtin constants, not to the LogDefaults read.
  - `[low]` `[patch]` (blind) `graph_topology_zero_handle_with_a_valid_buffer_returns_ffi_invalid_handle` lost the old pin that `ffi.invalid_handle` carries no context — `graph_ffi.rs` asserts the context is absent again.

## Design Notes

**OQ 2 decision rule (apply before writing the schema).** Metrics at large-10k packed (record medium + large loose too): (1) payload bytes of the two id columns, (2) Rust build time of the two id columns (median), (3) Dart first-access time — every commit + change id read as a `String` from a fresh buffer (median). Take **(b)** unless (a) is better on at least two of the three by more than 10 %. Same rule for the flags: one packed `[ubyte]` unless six `[bool]` vectors win two of three. With (b): `commit_ids`/`change_ids` are `[ubyte]` of `n × stride`, `commit_id_stride`/`change_id_stride: ubyte` (0 iff n = 0); Dart formats commit ids as lowercase hex and change ids as jj reverse-hex (nibble `v` → `'z' - v`, high nibble first; jj-lib `hex_util.rs:18`), and `graph_ids_test.dart` pins both. With (a): `commit_ids`/`change_ids` are `[string]` (Rust's `hex()` / `reverse_hex()`), no strides, no encoder, no `graph_ids_test.dart`.

**Wire layout (`table GraphTopology`, n nodes, E edges, A anchors).** `operation_id: string` (full hex) · `all_count: ulong` · ids per the rule above · `flags: [ubyte]` (n; bit 0 working_copy, 1 immutable, 2 hidden, 3 divergent, 4 root, 5 has_change_offset; 6-7 zero) · `change_offset: [uint]` (n; 0 when bit 5 is clear) · `change_id_prefix_len: [ubyte]`, `commit_id_prefix_len: [ubyte]` (n; a prefix is ≤ 2 × the id's byte length, saturating cast with a WHY) · `parent_count: [uint]` (n) · `edge_start: [uint]` (n + 1, `edge_start[0] == 0`, `edge_start[n] == E`) · `edge_target: [int]` (E; node index, −1 iff Missing) · `edge_kind: [GraphEdgeKind]` (E; jj stream order, repeated targets kept) · `timestamps: [long]` (n iff requested, epoch ms; root slot 0) · `refs: [TopologyRef]` (sorted by node; per node bookmarks then tags in zanshin-jj's order) · `working_copies: [TopologyWorkingCopy]` (sorted by node, per node in `TopologyMeta.working_copies` order) · `anchor_start: [uint]` (A + 1) · `anchor_node: [uint]` (ascending per anchor). Every vector but `timestamps` is always written (empty when n = 0). Node/edge indices fit `u32`/`i32` (a 2 GiB FlatBuffer cannot hold more), so `try_from(…).unwrap_or(MAX)` with a WHY. The −1 slot (not 4.2's 0) makes a reader that skips the kind check fail loudly instead of linking node 0.

**Dart view (`GraphTopologyView`, `lib/src/ffi/graph.dart`).** `fromEnvelope(Uint8List bytes)`: `fbs.Envelope(bytes)` (lazy) → `!ok` → `throw decodeEnvelopeErrorInternal(env)`; `dataType != GraphTopology` → `ffi.unknown`; strings/tables (`operationId`, `allCount`, strides, `refs`, `workingCopies`) via the generated `fbs.GraphTopology`; scalar vectors located by hand — root `bc.derefObject(0)`, the payload table through a `TableReader<int>` subclass on Envelope `data` (vtable offset 10), each vector through a `Reader<int>` subclass (`size => 4`, `read => bc.derefObject(o)`) at vtable offset `4 + 2 × field index`; length = the u32 prefix; view = `bytes.buffer.asXxxList(bytes.offsetInBytes + pos + 4, len)` when that absolute offset is a multiple of the element size, else a copy of that vector (counted in `@visibleForTesting int get copiedVectorCount`). Validates presence and lengths in O(1) per vector; little-endian host assumed (macOS). Surface: `bytes`, `operationId`, `allCount`, `warnings`, `nodeCount`, `commitId(i)`, `changeId(i)`, `commitIdPrefixLength(i)`, `changeIdPrefixLength(i)`, `isWorkingCopy/isImmutable/isHidden/isDivergent/isRoot(i)`, `changeOffset(i)` (`int?`), `parentCount(i)`, `edgeStart(i)`/`edgeEnd(i)`, `edgeTarget(e)` (`int?`), `edgeKind(e)` (unknown byte → `ffi.unknown`), `hasTimestamps`, `timestamp(i)` (`int?`, root `null`), `refs`/`refsOf(i)` (binary search), `workingCopies`/`workingCopiesOf(i)`, `anchorCount`/`anchorNodes(a)`, `indexOfCommitId(id)` (`int?`), `indicesOfChangeId(id)` (`List<int>`, `[]` on a miss), static flag-bit constants, and unmodifiable typed views for 4.11 (`flags`, `parentCounts`, `edgeStarts`, `edgeTargets`, `edgeKinds`, `timestamps?`, `anchorStarts`, `anchorNodesFlat`). A view over native memory is valid only while its `FfiBuffer` lives (doc it).

**Why `sendRaw`.** Nothing on the UI side can tell a materialized `TransferableTypedData` from a `SendPort` copy; the worker test observes the response type through a `@visibleForTesting` pass-through to `_sendCommand` — no test-only extern, no counter in production paths.

**Taken during this run** (append Ralph-marked ones to the decisions file too): `RepoHandle.graphTopology` keeps `graphSlice`'s pre-filled `prioritize`/`shortPrefixes` defaults but takes `anchors` and `withTimestamps` as required (4.10: the anchors pre-fill "is not applied by anything"; the timestamp cost is the layout mode's call); `defaultSyntheticElided` removed (orphaned); −1 Missing slot (above).

### Measurements

Release builds, Apple M4 Pro (24 GiB), macOS 27.0.1, 2026-10-01. Rust: `cargo bench -p zanshin-ffi --bench graph_wire` (3 warm-up + 25 timed runs). Dart: `dart run benchmark/graph_wire.dart <medium loose> <large-10k loose> <large-10k packed>` (JIT, 5 warm-up + 21 timed runs; the cdylib the hook builds is `--release`). Values are **median** (min in brackets where it matters). The id columns are identical in the loose and the packed store (packing only changes object loads), so the size and build rows coincide; the 100k rows are synthetic (`synthetic_topology` in the Rust bench, random ids in the Dart one). Dart's first access reads every commit and change id as a `String` from a fresh `BufferContext`.

**Table 1 — OQ 2: ids as `[string]` (a) vs fixed-stride `[ubyte]` (b).**

| Store | id bytes (a) | id bytes (b) | Rust build (a) | Rust build (b) | Dart first access (a), generated / ASCII-optimised `StringReader` | Dart first access (b), view + formatting |
|---|---|---|---|---|---|---|
| medium loose (1,002) | 96,224 B (96 B/node) | 36,112 B (36 B/node) | 31.7 µs | 29.5 µs | 189 µs [67] / 75 µs | 58 µs |
| large-10k loose (10,002) | 960,224 B | 360,112 B | 154.5 µs | 147.2 µs | 563 µs / 641 µs | 554 µs |
| large-10k packed | 960,224 B | 360,112 B | 174.9 µs | 146.3 µs | 565 µs / 671 µs | 553 µs |
| synthetic 100k | 9,600,032 B | 3,600,040 B | 1.70 ms | 1.52 ms | 10.8 ms / 10.3 ms | 5.67 ms |

Dart's own builder (not on the production path; Rust builds the wire): (a) 1,681 µs vs (b) 704 µs at 10k.

**Table 2 — flags: one packed `[ubyte]` vs six `[bool]` vectors.**

| Store | bytes packed | bytes six bool | Rust build packed | Rust build six bool | Dart first access packed | Dart first access six bool |
|---|---|---|---|---|---|---|
| medium loose | 1,028 B | 6,096 B | 2.2 µs | 9.7 µs | 2 µs | 6 µs |
| large-10k loose | 10,028 B | 60,096 B | 7.5 µs | 46.9 µs | 18 µs | 46 µs |
| large-10k packed | 10,028 B | 60,096 B | 8.3 µs | 46.8 µs | 25 µs | 46 µs |
| synthetic 100k | 100,024 B | 600,072 B | 105 µs | 512 µs | 1.42 ms | 2.38 ms |

**Table 3 — the chosen wire ((b) + packed flags).**

| Store | envelope, timestamps off / on | `TopologyIds::encode` + `graph_topology_to_envelope`, off / on | extern call `zanshin_graph_topology`, off / on | Dart `graphTopology` call total, off / on | view construction | full pass (ids, flags, edges) | lookup build (commit + change) | `copiedVectorCount` |
|---|---|---|---|---|---|---|---|---|
| medium loose | 57,544 B (57 B/node) / 65,560 B (65 B/node) | 48 µs / 56 µs | 5.07 ms / 127 ms | 5.29 ms / 122 ms | 5–9 µs | 57–63 µs | 187–217 µs | 0 / 0 |
| large-10k loose | 562,152 B (56 B/node) / 642,176 B (64 B/node) | 159 µs / 194 µs | 22.4 ms / 1.04 s | 21.7 ms / 1.21 s | 3–4 µs | 621–698 µs | 2.2 ms | 0 / 0 |
| large-10k packed | 562,152 B / 642,176 B | 162 µs / 190 µs | 22.1 ms / 52.3 ms | 21.7 ms / 56.7 ms | 3 µs | 620–637 µs | 2.2 ms | 0 / 0 |
| synthetic 100k | 5,650,352 B (56 B/node) / 6,450,360 B (64 B/node) | 2.00 ms / 2.50 ms | — (no repo) | — | — | — | — | — |

(The Dart call's envelope is 48–56 B larger than the Rust builder row's: the real call writes the `precondition` table, the builder row an empty report.) Compared with the removed slice (~175 B/node, two copies across isolates, eager decode), the topology wire is 56 B/node, one copy, and the view is ready in microseconds; the remaining cost of the call is the topology walk itself (4.10's ~22 ms at 10k) plus, with timestamps, the commit loads.

**The choice.** The rule: take (b) unless (a) is better on at least two of the three metrics (payload bytes, Rust build, Dart first access) by more than 10 %. At large-10k packed (a) is better on none: its id bytes are 2.67× (b)'s, its Rust build 20 % slower (175 vs 146 µs), its Dart first access level within 2 % (565 µs generated / 671 µs ASCII-optimised vs 553 µs); medium and large loose agree. **(b) taken** — `commit_ids` / `change_ids` are `[ubyte]` at `commit_id_stride` / `change_id_stride`, Dart formats them. Flags, same rule: six `[bool]` vectors win none of the three (6× the bytes, 5.6× the Rust build, 1.8× the Dart first access at 10k packed). **One packed `[ubyte]` taken.**

## Verification

**Commands:**
- `cargo make codegen` -- expected: exit 0; the header + bindings carry `zanshin_graph_topology` and no `zanshin_graph_slice`; both flatc outputs carry `GraphTopology`/`GraphTopologyRequest`, `PayloadTypeId.GraphTopology(11)`, no `GraphSlice`/`GraphRow*`.
- `cargo test -p zanshin-ffi --lib graph` and `cargo test -p zanshin-ffi --test graph_ffi --test snapshot_ffi --test ffi_abi_doc_sync` and `cargo test -p zanshin-jj --test api_stability --test graph --test graph_topology` -- expected: green.
- from `packages/zanshin_core` with the `[tasks.test-core]` env: `dart test test/ffi/graph_test.dart test/worker/graph_test.dart test/worker/graph_ids_test.dart test/worker/warnings_test.dart test/ffi/warning_test.dart test/worker/log_defaults_test.dart` (drop `graph_ids_test.dart` under (a)) and `dart analyze --fatal-infos --fatal-warnings` -- expected: green, no issues.
- `cargo bench -p zanshin-ffi --bench graph_wire` and `dart run benchmark/graph_wire.dart <large-10k loose dir> <packed dir>` -- expected: run to completion; numbers in § Measurements.
- the `git grep` of the first AC -- expected: only dated notes / history lines.
- `cargo make test` (nohup to a file, `caffeinate -w <pid>`, unpiped) -- expected: exit 0, `extern-coverage: OK`, `coverage-check: OK`.
- `git status --porcelain` after the finalization commit -- expected: empty.

**Manual checks:**
- `coverage-baseline.txt` has no `crates/zanshin-graph/` line and `crates/zanshin-ffi/src/graph.rs` ≥ 99.71.
- `_bmad-output/implementation-artifacts/epic-4-context.md` is newer than every file in `_bmad-output/planning-artifacts/` and still starts with `# Epic 4 Context:`.

## Auto Run Result

Status: done (bmad-build-auto, 2026-10-01; the run resumed after an HTTP 429 cut-off inside step-03 and reconciled the interrupted run's uncommitted work).

**Summary.** `Repo::graph_topology` (Story 4.10) is on the wire: the new extern `zanshin_graph_topology(handle, data, len)` reads a `GraphTopologyRequest` (`RequestKind.GraphTopology` = 30, appended) and answers an `Envelope<GraphTopology>` in `GraphSlice`'s Payload slot 11 — scalar vectors per node (ids as raw bytes at one stride per column, one flags byte, change offset with a presence bit, prefix lengths, parent counts, optional timestamps with the root's slot 0), CSR offsets for the edges (target −1 iff Missing) and the anchors, sparse ref / working-copy tables. Precondition + warnings ride the ok arm and every error arm after the snapshot. Dart reads it through `GraphTopologyView` (lazy typed-data views, O(1) per node, `ffi.unknown` on a structurally malformed buffer, null for absence, lazy `indexOfCommitId` / `indicesOfChangeId`), and the worker moves it to the UI with one copy (`TransferableTypedData` → `TransferResult`). The old lane path is gone (`zanshin_graph_slice`, its tables, the Dart slice models, `graphSlice`, the `zanshin-graph` crate); `walk_graph` stays. OQ 2 was decided by measurement: option (b), fixed-stride id bytes (36 vs 96 B/node, Rust build 146 vs 175 µs, Dart first access level at 10k packed); flags packed in one byte. The envelope is 56 B/node (64 with timestamps).

**Files changed.**
- `schemas/envelope.fbs` — `GraphTopologyRequest`, `TopologyRefKind`, `TopologyRef`, `TopologyWorkingCopy`, `GraphTopology` in slot 11; the slice tables removed; doc lines.
- Regenerated by `cargo make codegen`: `crates/zanshin-ffi/include/zanshin_ffi.h`, `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/bindings.dart`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`.
- `crates/zanshin-ffi/src/graph.rs` — rewritten: `map_topology_err`, request reader, `TopologyIds::encode`, `graph_topology_to_envelope`, the extern, inline tests.
- `crates/zanshin-ffi/src/{envelope,log_defaults}.rs`, `crates/zanshin-ffi/Cargo.toml` — doc re-points; `zanshin-graph` dependency dropped; `[[bench]] graph_wire`.
- `crates/zanshin-ffi/benches/graph_wire.rs` (new) — OQ 2 + flag comparisons, builder and extern rows per store.
- `crates/zanshin-ffi/tests/graph_ffi.rs` — reshaped against the `Repo::graph_topology` oracle (every zanshin-ffi matrix row); `snapshot_ffi.rs` witness re-pointed; `ffi_abi_doc_sync.rs` neutral synthetic header, 61 exports.
- `crates/zanshin-graph/` — deleted; `Cargo.toml`, `Cargo.lock`, `Makefile.toml` (7 manifests), `cbindgen.toml`, `crates/README.md` follow.
- `crates/zanshin-jj/{src/graph.rs,src/commit_meta.rs,src/revset.rs,src/file.rs,README.md,tests/graph.rs,tests/revset.rs,tests/api_stability.rs,benches/graph_blueprint.rs}` — doc rewording only.
- `packages/zanshin_core/lib/src/ffi/graph.dart` — rewritten: adapter, `GraphEdgeKind`, `TopologyRefKind`, `TopologyRef`, `TopologyWorkingCopy`, `GraphTopologyView`; `defaultSyntheticElided` removed.
- `packages/zanshin_core/lib/src/worker/{responses,commands,isolate,handle}.dart`, `lib/src/ffi/log_defaults.dart` — `TransferResult`, `GraphTopologyCommand`, `sendRaw`, `ZanshinWorker.graphTopology`, `RepoHandle.graphTopology`, docs.
- `packages/zanshin_core/test/{ffi/graph_test.dart,worker/graph_test.dart,worker/graph_ids_test.dart (new),worker/warnings_test.dart,ffi/warning_test.dart,worker/log_defaults_test.dart,ffi/request_bytes_test.dart}` — every Dart matrix row.
- `packages/zanshin_core/benchmark/graph_wire.dart` (new) — synthetic comparisons + the real path per repo dir.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md`, `docs/adr/0002-…md`, `_bmad-output/{project-context.md,planning-artifacts/architecture.md,planning-artifacts/epics.md}` — the doc sweep with dated notes.
- `_bmad-output/implementation-artifacts/{decisions-review-4-10-to-4-13.md,deferred-work.md,sprint-status.yaml,epic-4-context.md}` — `### 4.12` decisions, deferrals, 4-12 → done, epic context.
- `coverage-baseline.txt` — the three `zanshin-graph` entries dropped by the gate's rewrite.

**Review findings breakdown** (40 findings; full rows in § Review Triage Log).
- Patches applied (8 entries, 11 findings): the Dart `prioritize` pass-through witness (medium; 3 findings); a three-way divergent `indicesOfChangeId` test; real-surface lookup misses; the `graph_ids_test.dart` comment (release build; 2 findings); the epics.md "every arm" wording; `GraphTopologyView.bytes` read-only + test; the `docs/ffi-abi.md` LogDefaults sentence; the zero-handle no-context pin.
- Deferred (1): Story 9.25's "Apply = evaluate via graphSlice" — re-point at 9.25's refinement (the intent forbids editing it now).
- Rejected (28): 12 `false` — the one-copy test surface (`sendRaw` is prescribed), the ids join (pins every node), the encoder arm (prescribed, unreachable), the measurement method (prescribed / deferred / benches outside the gate by rule), tracking `done` vs `in-review` (twice; finalization commits both), use-after-dispose (documented contract, no such path), the timestamps flag (callers pass the load flag), the fixture path (prescribed, fixed `cwd`), the crate counts (different definitions, pre-existing split), the `hex_nibble` comment (same nibble functions), the `synthetic_elided` owner (10-4 (a)). 16 `low` — value validation of malformed buffers (edge targets, CSR start, monotonicity / ranges, ref order, uoffset bounds, the `TopologyRefKind` byte twice; trusted producer, guards; scope recorded in the decisions file), `edgeStart`/`edgeEnd` out of range (caller bug, guard), Rust-bytes-through-Dart breadth (new test infrastructure, no defect), AC 1's pathspec (twice; the fix edits the spec), the encoder's error code (unreachable, prescribed), the hex round trip (negligible cost, signature frozen), the 10k ids cost (matrix-required, already deferred), cbindgen `VT_` churn (no consumer, pre-existing), JIT noise (decision unaffected).

**Follow-up review recommendation: false.** Patched entries by verdict: high 0, medium 1, low 7. The single medium entry adds two test cases; the only patched production line is `GraphTopologyView.bytes` becoming an unmodifiable view, covered by the gate run below.

**Verification.**
- Step-03: the implementation's `cargo make test` exited 0 (`extern-coverage: OK`; `coverage-check: baseline RAISED (0 up, 0 new, 3 removed)` — the three `zanshin-graph` entries), run after the last code change; `cargo make codegen` byte-identical; the AC 1 grep (with `:(exclude)` pathspecs) shows only dated notes and history lines; `cargo metadata` lists no `zanshin-graph`; 7 tracked `Cargo.toml` files; the matrix audit found a covering test for every row that ran and passed in the gate log (`graph_ffi.rs`'s 20 tests, the inline `graph.rs` tests, `test/ffi/graph_test.dart`, `test/worker/graph_test.dart`, `test/worker/graph_ids_test.dart`).
- After the review patches: `cargo test -p zanshin-ffi --test graph_ffi zero_handle` green; `dart test test/ffi/graph_test.dart test/worker/graph_test.dart` (48 tests) green; `dart format` / `dart analyze --fatal-infos --fatal-warnings` clean; `cargo fmt --check` clean; then the full gate `cargo make test` (nohup to a file, waited on with `caffeinate -w`): exit 0 in 1,039 s, `coverage-check: OK — coverage held at 99.47% (14553/14631 lines)`, `extern-coverage: OK`.
- Manual: `coverage-baseline.txt` has no `crates/zanshin-graph/` line and keeps `crates/zanshin-ffi/src/graph.rs = 99.81` (≥ 99.71; measured 99.87 % in step-03); `epic-4-context.md` touched last, newer than every planning artifact, still `# Epic 4 Context:`.

**Residual risks.**
- `GraphTopologyView` trusts the Rust producer for value invariants (CSR monotonicity, target ranges, ref order, the ref-kind enum); a mismatched cdylib would surface as a `RangeError` / `StateError` or a wrong index, not `ffi.unknown` (decisions file `### 4.12`).
- No real-repo wire numbers (deferred); the 10k ids case adds ~80–90 s to the `zanshin_core` suite (deferred).
- Dart-built buffers (tests only) misalign `[long]` vectors, so the synthetic zero-copy tests run without timestamps; the real cdylib path shows 0 copies with timestamps on.
