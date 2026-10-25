---
title: 'Story 9.25 — Graph search backend: revset counts, change search, structured revset errors'
type: 'feature'
created: '2026-10-25'
status: 'done'
baseline_revision: '9b65ca848ec464c432f6c52ce920af3453c6ecc2'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      Only revset_counts / find_changes resolve revset symbols with the id-prefix context; graph_topology and every mutating verb still resolve without it (CLI parity gap).
    evidence: |-
      The CLI's default_symbol_resolver (cli/src/revset_util.rs:197-203 @ v0.46.0) resolves every command with with_id_prefix_context; only crates/zanshin-jj/src/revset_search.rs passes a context to resolve_for_evaluation. Touches every verb, so it needs its own story (spec Design Notes).
    location: >-
      crates/zanshin-jj/src/revset.rs (resolve_for_evaluation call sites)
    severity: medium
    resolved: >-
      2026-10-25 — fixed (spec-9-25-closing-id-prefix-context-search-warnings-view-hints, commit 0bad054): every user and config revset (topology, eval/resolve_revset, show/evolog, bookmark list/move/advance, workspace add, absorb, arrange, push) resolves with the effective `revsets.short-prefixes` id-prefix context; the CLI's own no-context sites (immutable set, `trunk()` check, op diff) stay without.
  - summary: >-
      A call-level failure of revset_counts / find_changes drops the warnings collected before it.
    evidence: |-
      Both calls return warnings inside the Ok answer; on Err they are logged via warning::log_dropped and the error envelope carries none, unlike the Story 9.32 rule.
    location: >-
      crates/zanshin-jj/src/revset_search.rs (finish)
    severity: low
    resolved: >-
      2026-10-25 — fixed (spec-9-25-closing-id-prefix-context-search-warnings-view-hints, commit 0bad054): both calls return `Warned<RevsetSearchError>` on failure and the FFI writes those warnings onto the error envelope.
  - summary: >-
      RevsetSpan offsets are UTF-8 byte offsets; Dart strings are UTF-16, and no conversion helper exists for the 10.21/10.22 highlighters.
    evidence: |-
      The story mandates byte offsets; packages/zanshin_core/lib/src/ffi/revset_search.dart exposes them raw, so a non-ASCII expression (author("Jörg")) would highlight shifted unless the consumer converts.
    location: >-
      packages/zanshin_core/lib/src/ffi/revset_search.dart (RevsetSpan)
    severity: low
  - summary: >-
      The CLI's revset hint lines reach only MutateError verbs, graph_topology and the two new calls; show/evolog, the bookmark reads and op diff still drop them.
    evidence: |-
      commit_views.rs::rev, bookmarks.rs::rev and op_diff.rs::resolve_both match { reason, .. } and ignore detail.hints; the CLI prints the same hints for e.g. jj show descripton(x). Pre-existing (no revset hints existed before this story).
    location: >-
      crates/zanshin-jj/src/commit_views.rs, bookmarks.rs, op_diff.rs
    severity: low
    resolved: >-
      2026-10-25 — fixed (spec-9-25-closing-id-prefix-context-search-warnings-view-hints, commit 0bad054): show/evolog and the bookmark list carry the hints to `FfiError.hints`; op diff rejected — the CLI prints no revset hints there (`operation/diff.rs:203-223`, `:280-310` @ v0.46.0).
  - summary: >-
      render_span parses pest's render; a jj-lib or pest bump can change it silently, and the pin-bump checklist does not name it.
    evidence: |-
      jj-lib 0.46 keeps RevsetParseError's pest error private (revset_parser.rs:155-161); the shortcut is pinned only by unit tests. The checklist lives in agent-context files (project-context.md section zanshin-jj), which this run does not edit.
    location: >-
      crates/zanshin-jj/src/revset.rs (render_span)
    severity: low
---

<intent-contract>

## Intent

**Problem:** The floating client's search (10.21) and its Configurations dialog (10.22) need to count arbitrary revsets, find changes outside the shown view, and point at the part of a revset that fails. The API has none of these: `eval_revset` is Rust-only and snapshots, the topology call is a layout input, and revset errors reach Dart as one flattened string.

**Approach:** Add two op-pinned reads, `Repo::revset_counts` and `Repo::find_changes`, modelled on `commit_contents` (load at a full-hex operation, no snapshot, no operation written). Give `RevsetError` a structured detail: kind, span, symbol, candidates. Carry it, with the CLI's hint lines, on the existing `jj.revset_parse_error` / `jj.revset_resolution_error` envelopes for the topology call and both new calls. Expose everything through FFI, `WorkerCommand`s and `RepoHandle`. Settle open items I1–I7 (see Design Notes).

## Boundaries & Constraints

**Always:**
- Both calls take a full-hex `operation_id` and load the repo with `load_operation` + `load_at`, as `commit_content.rs:150-160` does.
  - No pre-verb snapshot, no operation written, op heads untouched, `take_precondition()` stays `None`, Dart `lastPrecondition` unchanged.
  - An unknown operation is `jj.operation_not_found`; a malformed one is the same invalid-input refusal `commit_contents` gives.
- Revsets parse exactly as every Zanshin revset does (`revset.rs::parse_revset_in`): the effective `[revset-aliases]`, `user.email` for `mine()`, the workspace root as cwd for `files()`, `@` as the handle's workspace. Use the same effective config load the other revset reads use.
- CLI parity: symbols resolve with the id-prefix context (`SymbolResolver::with_id_prefix_context`, as `cli/src/revset_util.rs:197-203` @ v0.46.0).
  - `find_changes` builds the context from its `short_prefixes` argument. Empty means no context and the full index, as `graph.rs::prefix_context` does. The same index gives both resolution and the shortest-prefix lengths.
  - `revset_counts` uses the effective `revsets.short-prefixes` (`config::revsets_short_prefixes`), as the CLI does without `--config`.
- Counting iterates the evaluated revset's stream and never calls `count_estimate`.
  - `cap > 0`: read at most `cap + 1` entries; `n = min(len, cap)`, `capped = len > cap`.
  - `cap == 0`: parse and resolve only, never evaluate; `n = 0`, `capped = false`. Parse and resolution errors are still reported.
- In a counts batch every expression gets its own `Ok(Count)` or `Err(RevsetError)`. Only call-level faults fail the whole call: the operation, input, config or backend.
- `find_changes` keeps the revset's iteration order (`jj log --no-graph`). It takes `limit + 1` to set `truncated`. Each entry holds the commit id, the change id, and both shortest-prefix lengths.
- Parse diagnostics from either call become the call's warnings (`CallReport.warnings`, under `In revset expression`), in expression order.
- Error texts stay jj-lib's `Display` text verbatim (`reason`). An ambiguous prefix reads ``Change ID prefix `k` is ambiguous`` / ``Commit ID prefix `…` is ambiguous``. An unmatched prefix is no error and returns no entries.
- New public Rust types are pinned in `api_stability.rs`. New FlatBuffers fields and tables are append-only. `PANIC_FALLBACK_ENVELOPE` stays byte-identical: the new `FfiError` field is absent when unset.
- Every new extern fn gets a `zanshin_core` real-cdylib test (extern-coverage guard). Every new or changed Rust line gets a test.

**Never:**
- No second revset parser or text rewriting. The only text parsing allowed is reading the span back out of jj-lib's pest render (Design Notes).
- No config writes, no presets, no completion candidates, no Apply/Save, no cancellation or debouncing (the UI's job).
- No MCP surface (`zanshin-mcp` is a stub).
- No change to how other verbs resolve symbols (see the deferred item in Design Notes).
- No fixture regeneration, no `count_estimate`, and no `jj` run outside self-made temp dirs.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Count matches topology | medium fixture, op = head; `author(exact:…)`, `author(substring-i:…)`, `mine()`, `description(substring-i:…)`, `subject(glob:…)`, `files(cwd:…)`, `files(file:…)`, `files(glob:…)` | each `n` == `graph_topology(expr).nodes.len()` at that op, `capped=false` | — |
| Cap | `all()` with cap 5 | `n=5, capped=true` | — |
| Cap 0 | `all()` → `n=0, capped=false`; `bogus(` with cap 0 | the error is still reported | the entry's `ParseError` |
| Batch isolation | `[all(), "nonexistent_bookmark", description(regex:"(")]` | entry 0 Ok; 1 is a ResolutionError (`NoSuchRevision`); 2 is a ParseError | per entry; the call succeeds |
| Dirty `@`, pinned op | `@` has an unsnapshotted edit | both calls: no op files or op heads change; precondition None | — |
| Find order/limit | `all()`, limit 3 | 3 entries in iteration order, `truncated=true`; ids and prefix lengths == the topology's for the same nodes and the same `short_prefixes` | — |
| Ambiguous prefix | `change_id(k)` (1 char) on medium, `short_prefixes=""` | no entries | ResolutionError, kind `AmbiguousChangeIdPrefix`, symbol `k`, reason ``Change ID prefix `k` is ambiguous`` |
| Unmatched prefix | a valid but unused hex `commit_id(…)` | 0 entries, `truncated=false` | no error |
| Unknown op | 40/128-hex id not in the store | — | call-level `jj.operation_not_found` |
| Error spans | unclosed quote `description("x`; unknown function `fooo()`; bad regex `description(regex:"(")` | kind + byte offset/length point at the failing part; `NoSuchFunction` carries candidates | on topology + counts + find, reaching Dart `ZanshinFfiException.revsetError` |

</intent-contract>

## Code Map

All paths are relative to `/Users/ralph.bergmann/development/projects/privat/Zanshin`.

**Rust, `crates/zanshin-jj`**
- `crates/zanshin-jj/src/revset.rs` — `RevsetError` (:38-73).
  - Parse errors are flattened at :496-498 (`flatten_chain`).
  - Resolution happens at :530-538 (`resolve_for_evaluation`; there is no prefix context today) and evaluation at :548-558.
  - The parse chain is `parse_diagnosed_at` (:380) → `parse_revset_in` (:427-499). `IN_REVSET_EXPRESSION` is at :283.
  - Variant match sites that need the new field (or `..`): `commit_views.rs:233`, `bookmarks.rs:235`, `mutate.rs:613`, `template.rs:506`, `op_diff.rs:265`, `revset.rs:693`. Test sites: `commit_views.rs:634`, `mutate.rs:2272,2276`, `bookmarks.rs:730`.
- `crates/zanshin-jj/src/graph.rs` — `prefix_context` (:156) and `short_prefix_index` (:132), which warns and falls back on a load failure; `LogParse::new` (:202-244) parses `short_prefixes`; `evaluate` is at :254.
- `crates/zanshin-jj/src/commit_meta.rs:191-217,296` — the shortest-prefix length calls and `prefix_len`.
- `crates/zanshin-jj/src/topology.rs:137-230` — the topology. `all_count` (:221-222) is the stream-count pattern to reuse (add a take).
- `crates/zanshin-jj/src/commit_content.rs:55-160` — the op-pinned template: `CommitContentError`, `parse_operation_id` (:104), `classify` (:92). Share these helpers instead of copying them.
- `crates/zanshin-jj/src/repo.rs` — `commit_contents(&self)` (:1169-1175) delegates to the module (the pattern to copy). `graph_topology` is at :1121.
- `crates/zanshin-jj/src/mutate.rs:312-331,611-621` — `MutateError::Revset*Error { reason, hints }`, where `hints` is always empty. Fill it from the new detail.
- `crates/zanshin-jj/src/config.rs:1140` (`load`), `:1322` (`user_email`), `:1866` (`revsets_short_prefixes`).
- `crates/zanshin-jj/tests/it/{revset,commit_contents,graph_topology,api_stability}.rs` — test homes. Op-pinned no-side-effect witnesses: `commit_contents.rs:24-47` (listing/op_heads helpers) and `:319-361`. Vanished op: `:180`. Dirty `@`: `std::fs::write(fx.path.join(..))`.
- `crates/test-helpers/src/lib.rs` — `pin_test_env` (:115), `extract_fixture`, `build_changed_path_index`.

**jj-lib 0.46.0** (vendored at `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.46.0/src/`)
- `revset_parser.rs:155-207` — `RevsetParseError`: `kind()` and `origin()` are public; the span is private, and `Display` = the pest render. `RevsetParseErrorKind` variants.
- `revset.rs:94-122` — `RevsetResolutionError` variants; `with_id_prefix_context` is at :2998.
- `dsl_util.rs:933` — `collect_similar`.
- pest 2.8.6 `src/error.rs:533-690` — the render format: ` --> L:C` (1-based char column); `^` / `^^` / `^-…-^` for a span; `^---` for a position; a two-line form when the span crosses lines.

**CLI @ v0.46.0** (read with `git -C ../jj show v0.46.0:cli/src/command_error.rs`)
- :680-697 — parse and resolution messages.
- :892-977 — `revset_parse_error_hint`, which walks `origin()` to the bottom error, and `revset_resolution_error_hints`.
- :227 — `format_similarity_hint`.

**FFI, `crates/zanshin-ffi`**
- `src/commit_contents.rs` — the full template: reader (:66-83), mapper (:35-48), builder (:90-122), extern (:126-179), with `# Errors` / `# Safety` rustdoc.
- `src/graph.rs:36-51` — `map_topology_err`, revset → code.
- `src/envelope.rs`:
  - error codes at :64, :207, :210;
  - `CallReport` (:535-544), which carries `warnings`, `precondition` and `left_behind`, and is the place for the new detail;
  - `FfiErrorObj` (:575-581; 79 struct literals, so do NOT add a field there);
  - `precondition_envelope` (:634-645). Its `with_report(CallReport::take(repo))` OVERWRITES the mapper's report; keep the detail when merging.
  - `build_ffi_error` (:1395-1415), `err_with_report` (:1447-1471), `PANIC_FALLBACK_ENVELOPE` (:524);
  - the `ActionOutcome.refusal` per-row `FfiError` precedent at :1224-1237.
- `src/lib.rs:37-72` — module registry.
- `src/repo.rs:957-959` — "is the one pinned read" becomes false; mirror the fix into the header.
- `tests/it/main.rs:42-77` — module registry.
- `tests/it/commit_contents_ffi.rs` — request/guard test template.
- `tests/it/graph_ffi.rs:606-660` — revset error tests.
- `tests/it/ffi_abi_doc_sync.rs:37` — `EXPECTED_EXPORTS = 107`, which becomes 109. The `# Errors` bullets must equal the doc table cell.

**Schema and codegen**
- `schemas/envelope.fbs`:
  - `FfiError` (:21-47): append a `revset: RevsetErrorDetail` field;
  - `RequestKind` (:94-164): append `RevsetCounts` and `FindChanges`; update the prose count at :85;
  - request tables go next to `CommitContentsRequest` (:1244-1253) and `GraphTopologyRequest` (:1289-1302);
  - the story ledger is at :1304-1337;
  - payload tables are declared before `union Payload` (:2857-2916), appended after `ResolveList`;
  - the `Envelope.precondition` doc at :2942-2948 lists the symbols that never carry it.
- `Makefile.toml:532-595` — `cargo make codegen` regenerates `envelope_generated.rs`, `envelope_zanshin.ffi_generated.dart`, `zanshin_ffi.h` and `bindings.dart`. The extern-coverage guard is at :793-819.

**Dart, `packages/zanshin_core`**
- `lib/src/ffi/commit_contents.dart` — the adapter, model and decoder template (`rejectInteriorNul`, `callWithRequest`, `decodeEnvelopeErrorInternal`).
- `lib/src/ffi/precondition.dart:185-206` — the single error decode point. Add `revsetError` there.
- `lib/src/worker/responses.dart:101-185` — `ZanshinFfiException`. Add a nullable `revsetError`.
- `lib/src/worker/commands.dart:1376-1400` — the `CommitContentsCommand` template.
- `lib/src/worker/isolate.dart` — import (:16), main-side method (:2829-2866), worker arm (:4748-4765).
- `lib/src/worker/handle.dart` — `commitContents` (:429-437); the `lastPrecondition` doc (:90) lists the no-snapshot verbs.
- `lib/src/ffi/drop_actions.dart:369-380` — decoding a per-row `FfiError`.
- `lib/src/ffi/warning.dart:419` — `WarnedList`.
- `lib/zanshin_core.dart` — exports. Export the new public models and the error detail.
- `test/worker/commit_contents_test.dart` — the real-cdylib template.
- `test/ffi/commit_contents_test.dart` — the synthetic decode template.
- `test/worker/graph_test.dart` — revset errors through the topology.

**Docs**
- `docs/ffi-abi.md` — the counts at :40, :293-295, :454, :469 (these two already disagree; fix them) and :554; the index rows at :585-586; the warnings/precondition absent lists (:164-166, :183-188, :207); the template section at :1484-1583; the `FfiError` sections (:78, :110).
- `docs/rust-error-codes.md` — :56-57 (revset codes) and :88 (`jj.operation_not_found`).

## Tasks & Acceptance

**Execution:**

1. `crates/zanshin-jj/src/revset.rs` — add `RevsetErrorDetail { kind: RevsetErrorKind, span: Option<RevsetSpan{offset, length: Option<u32>}>, symbol: Option<String>, candidates: Vec<String> }`.
   - Give `ParseError` and `ResolutionError` a `detail` field, and build it where the errors are mapped.
   - The parse span is read from the pest render (Design Notes).
   - Add `fn hints(&self) -> Vec<String>`, a port of the CLI's revset hints. The divergent and conflicted hints need the targets, so keep them in the detail.
   - Add a resolver entry point that takes an optional `IdPrefixContext`.
   - Update every match site.
   - Inline unit tests: the span parser (position, 1, 2 and n chars, multi-byte, multi-line → `length: None`) and `hints()` per kind.
2. A new `crates/zanshin-jj/src/revset_search.rs`, wired in `lib.rs` and `repo.rs`:
   - `revset_counts(&self, operation_id, &[String], cap) -> Result<RevsetCounts{ counts: Vec<Result<RevsetCount{n, capped}, RevsetError>>, warnings }, RevsetSearchError>`;
   - `find_changes(&self, operation_id, expression, limit, short_prefixes) -> Result<FoundChanges{ entries: Vec<FoundChange{commit_id, change_id, commit_prefix_len, change_prefix_len}>, truncated, warnings }, RevsetSearchError>`.
   - `RevsetSearchError` covers the call-level faults: invalid input, operation not found, config, backend, and `find_changes`' own revset error.
   - Share the op parsing and loading with `commit_content.rs`.
3. `crates/zanshin-jj/src/mutate.rs` — fill `hints` from `detail.hints()` in `rev()`.
4. `crates/zanshin-jj/tests/it/revset_search.rs` (new, registered in `main.rs`) and `crates/zanshin-jj/tests/it/api_stability.rs` — every Rust row of the I/O matrix, the no-side-effect witnesses, and the new types pinned.
5. `schemas/envelope.fbs`:
   - `enum RevsetErrorKind`, `table RevsetSpan`, `table RevsetErrorDetail`;
   - `FfiError.revset`;
   - `RevsetCountsRequest{kind, operation_id, expressions, cap: ulong}` and `FindChangesRequest{kind, operation_id, expression, limit: ulong, short_prefixes}`;
   - the payloads `RevsetCounts{counts:[RevsetCount{n, capped, error: FfiError}]}` and `FoundChanges{entries, truncated}`;
   - the new `RequestKind` values and `Payload` variants;
   - the doc counts and ledger.
   - Then run `cargo make codegen` and commit the output.
6. `crates/zanshin-ffi/src/envelope.rs` — `CallReport.revset`, written as `FfiError.revset`. Keep it through `precondition_envelope`'s `with_report`.
7. `crates/zanshin-ffi/src/graph.rs` and a new `crates/zanshin-ffi/src/revset_search.rs`:
   - In `map_topology_err`, set the detail and hints.
   - The new module holds both externs, their readers, mappers and builders. A per-count error is a nested `FfiError` (code + context + hints + revset).
   - Register the module in `lib.rs` and fix the `repo.rs:957-959` note.
   - Add inline mapper tests.
8. `crates/zanshin-ffi/tests/it/revset_search_ffi.rs` (new), `graph_ffi.rs` and `ffi_abi_doc_sync.rs`:
   - the request ladder (null, bad kind, missing field, NUL, bad handle, bad op);
   - envelopes for every matrix row;
   - the topology's parse error now carries the detail;
   - `EXPECTED_EXPORTS` set to 109.
9. `packages/zanshin_core/lib/src/ffi/revset_search.dart` (new), plus `precondition.dart`, `responses.dart`, `commands.dart`, `isolate.dart`, `handle.dart` and `zanshin_core.dart`:
   - `RepoHandle.revsetCounts(operationId, expressions, {required int cap}) → RevsetCounts`, a `WarnedList` of `RevsetCount{n, capped, ZanshinFfiException? error}`;
   - `RepoHandle.findChanges(operationId, expression, {required int limit, required String shortPrefixes}) → FoundChanges{entries, truncated, warnings}`;
   - `ZanshinFfiException.revsetError: RevsetErrorDetail?` (null for absence);
   - the NUL guards;
   - the `lastPrecondition` doc.
10. `packages/zanshin_core/test/worker/revset_search_test.dart` and `test/ffi/revset_search_test.dart` (new), and `test/worker/graph_test.dart`:
    - real-cdylib tests per extern: counts, cap, a bad entry, find order/truncated, an ambiguous prefix, no `lastPrecondition` change;
    - synthetic decode tests (absent detail → null, a missing required vector throws);
    - the topology error's `revsetError` span.
11. `docs/ffi-abi.md` and `docs/rust-error-codes.md`:
    - the two symbol rows and a section;
    - the `FfiError.revset` section;
    - counts 107 → 109 and the other prose counts;
    - the absent-precondition and warnings lists;
    - the revset and operation-not-found code rows.
12. `crates/zanshin-jj/benches/revset_counts.rs` (new, `[[bench]] harness = false`) — I7. Time `revset_counts` on medium, large-10k loose, large-10k `git gc`-packed (copy `crates/zanshin-ffi/benches/graph_topology.rs`'s packing), and large with and without `build_changed_path_index`. Expressions: `author(substring-i:…)`, `description(substring-i:…)`, `mine()`, `files(glob:…)`, `all()`, each at cap 10000. Run it once and record min/median per row in Verification. Assert nothing about wall-clock.
13. `_bmad-output/planning-artifacts/epics.md` (Story 4.12 at :4012 and the Story 9.28 line naming "9.25's `revsets.log` writer") and `_bmad-output/implementation-artifacts/sprint-status.yaml` (9-25 status, `last_updated`) — add dated settle notes for I1/I3/I5 and set the status.

**Acceptance Criteria:**
- Given a dirty working copy and the head operation id, when Dart calls `revsetCounts` or `findChanges` through the real cdylib, then no operation file or op head changes, `lastPrecondition` is unchanged, and the next `graphTopology` still snapshots.
- Given an expression that fails in a counts batch, when the batch returns, then only that entry carries a `ZanshinFfiException` with code `jj.revset_parse_error` or `jj.revset_resolution_error` and a `revsetError`, and the other entries hold counts.
- Given `graphTopology` with the revset `fooo()`, when it fails, then the Dart exception's `revsetError` has kind `noSuchFunction`, symbol `fooo`, a span covering jj-lib's name span (`offset 0, length 4`), `candidates` from jj-lib, and the CLI's "Did you mean" hint when candidates exist.
- Given the I7 bench, when it is run, then its numbers are recorded in this spec and nothing is gated on them.

## Spec Change Log

## Review Triage Log

### 2026-10-25 — Review pass
- verdicts: 26 findings — high 0, medium 6, low 17, false 3, maybe-false 0
- findings:
  - `[false]` `[reject]` (intent) No `## Auto Run Result` with commit hashes in the diff — the result section and the commits are written at finalize, after review; this is the order the workflow requires, not a gap in the diff.
  - `[low]` `[patch]` (intent) The 4-12 sprint-status comment still says "9-25's Apply via graphSlice … re-point" with no settle note — fixed: appended the same dated I3/I5 settle note to the 4-12 comment.
  - `[low]` `[reject]` (intent) The bench does not time `subject()` / `committer()` — they belong to the same commit-load class as `author()` / `description()`, which the bench measures. Adding rows would give I7 no new information.
  - `[low]` `[patch]` (intent) At the Dart surface, only `fooo()`'s span is checked; the unclosed quote and the bad regex are not — fixed: real-cdylib asserts for `description("x` (`syntaxError`, `(14, 0)`) and `description(regex:"(")` (`expression`, `(12, 9)`) in `test/worker/revset_search_test.dart`.
  - `[low]` `[patch]` (intent) The `mine()` count-equality check may be a trivial 0 == 0 on the medium fixture — verified true (medium has no commit with the pinned email). Fixed: the test adds one commit with `add_commit_off_root`, which gets the pinned identity, and every expression now asserts a non-empty topology.
  - `[false]` `[reject]` (intent) The optional 9.47 parity-oracle comparison was not done — the story marks it "Optional", so skipping it is no defect. It is recorded as not done.
  - `[medium]` `[patch]` (verification-gap) `find_changes`' id-prefix context from its `short_prefixes` argument is never exercised — fixed: `find_resolves_a_prefix_within_its_short_prefixes` — with `""`, `tip`'s one-char change-id prefix refuses `AmbiguousChangeIdPrefix`; with `"tip"`, it resolves to exactly `tip` with `change_prefix_len` 1.
  - `[medium]` `[patch]` (verification-gap, other) A bad `short_prefixes` in `find_changes` yields a span into the `short_prefixes` text, while the docs say "into the expression" — fixed: a new `RevsetError::without_span()` drops the span for parse errors outside the call's primary expression (topology `prioritize` / `short_prefixes` / anchors, `find_changes`' `short_prefixes`); the docs say "the call's primary expression"; tested by `a_topology_error_outside_the_revset_has_no_span` and the extended `find_reports_a_bad_short_prefixes_or_expression_as_its_revset_error`.
  - `[low]` `[patch]` (edge-case) `render_span` reads pest's lone `^` as length 1, but an empty span (`author()` args) renders the same way — fixed: a lone `^` now gives `length: None` (ambiguous between 0 and 1), with a WHY comment; the docs (Rust, fbs, Dart, ffi-abi) are updated; a real jj-lib `author()` gives `(7, None)`.
  - `[medium]` `[patch]` (edge-case) The `find_changes` `short_prefixes` parse error has a mis-targeted span — fixed: a new `RevsetError::without_span()` drops the span for parse errors outside the call's primary expression (topology `prioritize` / `short_prefixes` / anchors, `find_changes`' `short_prefixes`); the docs say "the call's primary expression"; tested by `a_topology_error_outside_the_revset_has_no_span` and the extended `find_reports_a_bad_short_prefixes_or_expression_as_its_revset_error`.
  - `[medium]` `[patch]` (edge-case) In `graph_topology`, a `prioritize` / `short_prefixes` parse error now carries a span into the wrong text — fixed: a new `RevsetError::without_span()` drops the span for parse errors outside the call's primary expression (topology `prioritize` / `short_prefixes` / anchors, `find_changes`' `short_prefixes`); the docs say "the call's primary expression"; tested by `a_topology_error_outside_the_revset_has_no_span` and the extended `find_reports_a_bad_short_prefixes_or_expression_as_its_revset_error`.
  - `[false]` `[reject]` (edge-case) `cap == 0` reports `capped=false` for a non-empty revset — the spec's Always rules define cap 0 as parse + resolve only (`n=0, capped=false`), and the docs say so. That is the intended contract, not a contradiction.
  - `[low]` `[reject]` (edge-case) An evaluation or iteration `JjLibError` of one expression fails the whole batch — jj-lib evaluation errors are backend (store) failures, which are repository-wide, and the spec makes backend faults call-level. The story's "a bad one never fails the batch" concerns bad expressions (parse/resolution), which stay per entry.
  - `[low]` `[patch]` (edge-case) A `short-prefixes` set that fails to populate surfaces as a per-expression `ResolutionError` of kind `Other` instead of a warning — this behavior matches jj-lib's and the CLI's (`CommitPrefixResolver::try_resolve`, revset.rs:2848-2853), so the code stays. The stale note in `rust-error-codes.md` is fixed — (the `jj.revset_resolution_error` row in `docs/rust-error-codes.md` got a dated note on the populate-failure refusal for these two calls)
  - `[low]` `[patch]` (blind) `render_span` reads an empty span as length 1 — fixed: a lone `^` now gives `length: None` (ambiguous between 0 and 1), with a WHY comment; the docs (Rust, fbs, Dart, ffi-abi) are updated; a real jj-lib `author()` gives `(7, None)`.
  - `[medium]` `[patch]` (blind) The span does not say which input text it points into — fixed: a new `RevsetError::without_span()` drops the span for parse errors outside the call's primary expression (topology `prioritize` / `short_prefixes` / anchors, `find_changes`' `short_prefixes`); the docs say "the call's primary expression"; tested by `a_topology_error_outside_the_revset_has_no_span` and the extended `find_reports_a_bad_short_prefixes_or_expression_as_its_revset_error`.
  - `[low]` `[defer]` (blind) Spans are UTF-8 byte offsets, while Dart strings are UTF-16 — the story requires byte offsets; converting is a consumer concern for 10.21/10.22. Deferred and mirrored.
  - `[low]` `[patch]` (blind) The span parser is tested mostly on hand-written renders — fixed: `jj_lib_parse_errors_read_back_their_spans` with real jj-lib errors (`author()` → `(7, None)`, `author("Jörg") & fooo()` → `(18, Some(4))`, a two-line expression → `(8, Some(4))`, a span that crosses lines → `(7, None)`).. The missing pin-bump checklist entry goes in an agent-context file and is deferred and mirrored.
  - `[low]` `[reject]` (blind) `revset_counts` ignores a caller `short_prefixes`, unlike find/topology — it follows the CLI, which uses the effective `revsets.short-prefixes`, and the topology resolves without a context at all (deferred separately). A mismatch needs an id-prefix count with a non-default `short_prefixes`, which is rare in everyday use, and the fix adds a request field.
  - `[low]` `[patch]` (blind) A failing `short-prefixes` set now fails lookups instead of degrading, and `rust-error-codes.md` is stale — the behavior is the CLI's and stays; the doc is fixed — (the `jj.revset_resolution_error` row in `docs/rust-error-codes.md` got a dated note on the populate-failure refusal for these two calls)
  - `[low]` `[reject]` (blind) One bad expression's evaluation error can fail the batch — rejected for the same reason as the edge-case row above (backend faults are call-level by spec).
  - `[low]` `[defer]` (blind) The CLI's revset hints are still missing on show/evolog/bookmarks/op diff — pre-existing: no revset hints existed before this story. Deferred and mirrored.
  - `[low]` `[patch]` (blind) The request-before-handle ordering is untested — fixed: for both externs, handle 0 + null request → `ffi.null_pointer`, and handle 0 + wrong kind → `ffi.invalid_argument`.
  - `[medium]` `[patch]` (blind) The bench's per-expression times include `Repo::open` — fixed: a bare `Repo::open` row per store and per index state, then a re-run; it costs 0.5–1.6 ms and the other rows barely moved; the table and its note are updated.
  - `[low]` `[patch]` (blind) `ZanshinFfiException.toString()` omits `revsetError` — fixed: `toString()` now appends `; revset: <kind> at <offset>+<length|?> \`<symbol>\``; a decode test checks it.. The missing `==` / `toString` on the value classes and the list mutability are rejected: no consumer compares them yet, and adding them goes beyond a direct correction.
  - `[low]` `[patch]` (blind) The tracking docs are out of step: sprint-status `in-progress`, MCP/oracle skips not recorded, new deferrals not mirrored — the status is set to `done` at finalize; the skips are recorded under Auto Run Result; the deferrals are mirrored into `deferred-work.md`.

### 2026-10-25 — Review pass (follow-up)
- verdicts: 22 findings — high 0, medium 2, low 15, false 5, maybe-false 0
- findings:
  - `[medium]` `[reject]` (blind) `graph_topology` and the verbs still resolve without the id-prefix context, so a prefix `revsetCounts` counts can be refused by `graphTopology` — real, but the intent's Never list forbids changing how other verbs resolve symbols; it is already the first `deferred:` item (Design Notes) and mirrored in `deferred-work.md`.
  - `[low]` `[defer]` (blind) Revset hints still dropped by show/evolog/bookmarks/op diff, and `render_span` missing from the pin-bump checklist — carried: same claims as the first pass's two deferred rows; the code still reads `{ reason, .. }` at those sites. Not deferred again.
  - `[low]` `[reject]` (blind) A lone `^` gives `length: None` for one-char operator errors (`x + y`, `foo^`) whose length is knowable from the symbol — the offset is still exact and null length is documented as "unknown"; recovering it adds a symbol-matching heuristic branch for a cosmetic underline.
  - `[low]` `[reject]` (blind) `RevsetErrorDetail` names no source text, so an anchor / `prioritize` resolution error looks like an expression error — those texts come from the app and the effective config, not the user's typing; the `reason` names the symbol; the fix adds a public field.
  - `[low]` `[reject]` (blind) `FoundChange` carries no divergence data (change offset, hidden flag) — the intent fixes the entry's fields (ids + both prefix lengths); divergent hits are rare and the fix adds public surface.
  - `[low]` `[patch]` (blind) `docs/rust-error-codes.md`'s `jj.invalid_input` row omits the two new externs — fixed: appended a Story 9.25 sentence (absent `operation_id` / `expression` / `short_prefixes`, a malformed or non-full operation id).
  - `[low]` `[patch]` (blind) `find_changes`' `jj.short_prefixes_failed` warning is undocumented — fixed: the `FoundChanges.warnings` rustdoc, `docs/ffi-abi.md` § Graph search and the `jj.short_prefixes_failed` row in `docs/rust-error-codes.md` now name it.
  - `[low]` `[reject]` (blind) epics.md 9.28's Motivation still says "`revsets.log` (9.25)" and 9.25 item 1 still shows `-> Vec<RevsetCount>` / "stops at `cap`" — the Motivation names the key's consumer, not a writer (the Scope line got the dated note); the planning text predates the build and this spec is the as-built record; nobody meets it in everyday use.
  - `[false]` `[reject]` (blind) Struck-through REJECTED/RESOLVED ledger items in `deferred-work.md` still end with live follow-ups — each sits under a struck heading with its dated status first; keeping the original entry text below it is the file's convention (e.g. "MOOT … Original entry:").
  - `[low]` `[reject]` (blind) The I/O matrix says a 40-hex unknown op is `jj.operation_not_found`, but a 40-hex id is refused `jj.invalid_input` — the code follows the Always rule ("a malformed one is the same invalid-input refusal `commit_contents` gives"); operation ids are 128 hex, and the only fix is editing this spec.
  - `[false]` `[reject]` (blind) `limit == 0` evaluates while `cap == 0` does not, undocumented — `limit == 0` reads `limit + 1 = 1` commit exactly as the documented "reads at most `limit + 1`" rule says, and `truncated` keeps its meaning; nothing contradicts the docs.
  - `[low]` `[patch]` (blind) The topology's resolution detail and the "Did you mean" hint are never checked through the cdylib — fixed: `test/worker/graph_test.dart` asserts the anchor refusal's `noSuchRevision` kind and symbol, and `descripton(x)`'s `noSuchFunction` with `description` among the candidates and a "Did you mean" hint.
  - `[false]` `[reject]` (edge-case) `render_span` walks into a later line when the header column lies past its line's end — pest renders the same text the caller sent (the top-level error's span is in the caller's text, and `without_span` drops the others), so the column never exceeds the line length + 1; that position is the line's own `\n`.
  - `[low]` `[reject]` (edge-case) `revset_counts` ignores a caller `short_prefixes` — carried: the first pass's reject row (follows the CLI's effective `revsets.short-prefixes`); the code is unchanged.
  - `[low]` `[reject]` (edge-case) A bad `short_prefixes` in `find_changes` reports the same code, kind and symbol as an expression error — same root as the source-field row above: the view's `short_prefixes` already parsed for the topology it came from, so this refusal is practically unreachable; the fix adds a variant or field.
  - `[low]` `[reject]` (edge-case) An unknown wire `RevsetErrorKind` throws while decoding — the Dart decoder and the cdylib are generated by the same `cargo make codegen` and ship together; a newer Rust kind with stale Dart cannot occur in a build; a fallback adds a branch.
  - `[medium]` `[patch]` (verification-gap) `find_changes`' `short_prefixes` pass-through is never exercised with a non-empty value above zanshin-jj — fixed: `find_changes_passes_its_short_prefixes_through` in `test/worker/revset_search_test.dart` (real cdylib): `tip`'s one-char change-id prefix refuses `ambiguousChangeIdPrefix` with `''` and resolves to exactly `tip` with `changePrefixLen` 1 with `'tip'`.
  - `[low]` `[patch]` (intent) A lone `^` gives `null` instead of the Design Notes' "`^` = 1" — carried: the first pass's patch row (empty and one-char spans render the same); not patched again.
  - `[low]` `[reject]` (intent) Reading F: a 40-hex op id is not `jj.operation_not_found` — same as the blind matrix row above.
  - `[false]` `[reject]` (intent) Resolution and the prefix lengths may use different index loads — both take the same `prefixes` `IdPrefixContext` (`revset_search.rs:244-254`), whose populated index is cached; a populate failure either refuses resolution or warns and falls back, as the topology does.
  - `[low]` `[patch]` (intent) The Dart tests do not check the AC's "no operation file or op head changes" — fixed: the counts test lists `.jj/repo/op_store/operations` and `op_heads/heads` before the dirty-`@` reads and after `revsetCounts` + `findChanges`, and expects them equal; the remaining matrix rows stay at the Rust and FFI layers behind the one decode point.
  - `[false]` `[reject]` (intent) The `MutateError` hints exceed the named surface and only a unit test pins them — task 3 asks for them, and `crates/zanshin-jj/tests/it/bookmark_move.rs` covers them end to end.

## Design Notes

**Span.** jj-lib 0.46 keeps the pest error private; `RevsetParseError`'s `Display` is pest's render. Parse it:
- The header ` --> L:C` gives the start. Map line and character column to a byte offset in the caller's expression.
- For a one-line render, the underline gives the length: `^---` = a position (length 0), `^` = 1, `^^` = 2, `^-…-^` = n.
- When the render spans two source lines, set `length: None` (null).
- Mark it in code: `shortcut: parses pest's render because jj-lib 0.46 keeps the span private; replace when jj-lib exposes it`.
- Report the top-level error's kind and span. They point into the caller's text even inside an alias expansion.
- Example: `description("x` → kind `SyntaxError`, a position span (`length 0`) at or after the opening quote (offset ≥ 12); the test pins the exact offset jj-lib reports.

**Counting.** Counting reuses the `all_count` stream fold from `topology.rs:221-222` with `.take(cap + 1)`.

**Kinds.** `RevsetErrorKind` mirrors jj-lib's variants:
- the parse kinds — `SyntaxError`, the three `Not*Operator`, `NoSuchFunction`, `InvalidFunctionArguments`, `FsPathWithoutWorkspace`, `WorkingCopyWithoutWorkspace`, `RedefinedFunctionParameter`, `Expression`, `InAliasExpansion`, `InParameterExpansion`, `RecursiveAlias`;
- the resolution kinds — `NoSuchRevision`, `WorkspaceMissingWorkingCopy`, `EmptyString`, `AmbiguousCommitIdPrefix`, `AmbiguousChangeIdPrefix`, `DivergentChangeId`, `ConflictedRef`, `Backend`, `Other`.

**Open items:**
- **I1** — rejected: the refined text (item 5) dropped the writer and names 9.28's `configSet`. Only 9.28's text still names "9.25's `revsets.log` writer"; add a dated note there (task 13).
- **I2** — rejected: the refinement dropped presets, Apply and Save (item 5).
- **I3 / I5** — the refined 9.25 and its sprint-status comment no longer mention `graphSlice`; only 4.12's "consumers to re-point" line remains. Add a dated settle note there (task 13).
- **I4 / I6** — fixed by `find_changes`.
- **I7** — measured by task 12. The 100k "synthetic" input is a topology without a repository, so counts cannot run on it: rejected, with that reason. Choosing a mitigation stays 10.21's / Ralph's.

**Deferred (mirror into `deferred-work.md` in the spec's commit):** only the two new calls resolve with the id-prefix context. `graph_topology` and every mutating verb still resolve without it, unlike the CLI's `default_symbol_resolver`. That parity change touches every verb, so it needs its own story.

## Verification

**Verification notes (2026-10-25, after the review patches; the full gate deliberately not run, per the story loop's gate rule):**
- `cargo test -p zanshin-jj --test it` — 1383 passed, 1 ignored.
- `cargo test -p zanshin-jj --lib` — 389 passed.
- `cargo test -p zanshin-ffi --test it` — 384 passed.
- `cargo test -p zanshin-ffi --lib` — 227 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` — clean.
- `cargo fmt --all --check` — clean.
- `cargo make codegen` — exit 0; re-running leaves no drift beyond the committed output.
- `cargo make --allow-private test-core` (zanshin_core `dart test`, real cdylib, pinned env) — 1097 passed.
- `test-core-analyze` and `dart analyze app` — no issues.
- `test-core-format` — 0 changed.
- `cargo bench -p zanshin-jj --bench revset_counts` — ran; numbers below.
- Not run: the coverage ratchet and the 9.47 parity oracle (optional; no jj verb changed).

**Verification notes (2026-10-25, follow-up review pass; the full gate deliberately not run, per the story loop's gate rule):**
- `cargo make --allow-private test-core` (zanshin_core `dart test`, real cdylib, pinned env) — 1098 passed (the new `find_changes_passes_its_short_prefixes_through` plus the extended counts and topology-error tests).
- `cargo make --allow-private test-core-analyze` — no issues.
- `cargo make --allow-private test-core-format` — 0 changed.
- `cargo clippy -p zanshin-jj --all-targets -- -D warnings` (a rustdoc edit) — clean.
- `cargo fmt --all --check` — clean.
- `cargo test -p zanshin-ffi --test it ffi_abi_doc_sync::` (`docs/ffi-abi.md` changed) — 17 passed.
- Not run: codegen (no schema or FFI change), the parity oracle (no jj verb changed), coverage and the full gate (the loop's end).

**Run constraints (story loop, Ralph 2026-10-20 / 2026-10-23):**
- Do NOT run `cargo make test`, `cargo make test-full` or `cargo make coverage`. The loop runs the full gate once at its end; use the targeted commands below only.
- Use absolute paths and never a bare `cd` (zoxide).
- Run `jj` only inside temp dirs you created.
- Edit with Edit/Write, not sed, perl or heredocs.
- Do not commit; the orchestrator commits.
- Run every command in the foreground. Never use `run_in_background`.

**Commands:**
- `cargo test -p zanshin-jj --test it revset_search::` / `revset::` / `graph_topology::` / `commit_contents::` / `api_stability::` -- expected: pass
- `cargo test -p zanshin-jj --lib` -- expected: pass (span + hints unit tests)
- `cargo test -p zanshin-ffi --test it revset_search_ffi::` / `graph_ffi::` / `ffi_abi_doc_sync::` and `cargo test -p zanshin-ffi --lib` -- expected: pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean
- `cargo make codegen` then `git status` -- expected: the generated files are committed, and re-running leaves no diff
- In `packages/zanshin_core`: `flutter test` (or `dart test`), `dart analyze`, `dart format --set-exit-if-changed .` -- expected: pass
- `cargo bench -p zanshin-jj --bench revset_counts` -- expected: runs; numbers recorded below

**I7 measurements (2026-10-25, `cargo bench -p zanshin-jj --bench revset_counts`, M-series Mac, release; one `revset_counts` call per expression on a fresh handle, cap 10 000; min / median of 5 after 1 warm-up):**

| Store | `Repo::open` alone | `author(substring-i:"fixture")` | `description(substring-i:"branch")` | `mine()` (0) | `files(glob:"commit-1*.txt")` | `all()` |
|---|---|---|---|---|---|---|
| medium-1k loose | 1.44 / 1.60 ms | 120.3 / 126.4 ms (1001) | 118.7 / 129.1 ms (199) | 119.3 / 121.1 ms | 234.9 / 238.8 ms (115) | 0.88 / 0.90 ms (1002) |
| large-10k loose | 0.75 / 1.25 ms | 1.190 / 1.207 s (10000) | 1.193 / 1.224 s (1981) | 1.188 / 1.260 s | 2.415 / 2.496 s (1116) | 1.60 / 1.67 ms (10000, capped) |
| large-10k loose + changed-path index | 0.51 / 0.60 ms | 1.196 / 1.232 s | 1.194 / 1.198 s | 1.193 / 1.225 s | 2.17 / 2.32 ms | 1.66 / 1.70 ms |
| large-10k packed | 0.66 / 0.77 ms | 34.7 / 37.4 ms | 32.9 / 33.3 ms | 32.7 / 32.8 ms | 55.1 / 55.3 ms | 1.71 / 1.77 ms |
| large-10k packed + changed-path index | 0.58 / 0.59 ms | 33.5 / 33.7 ms | 33.5 / 35.6 ms | 33.8 / 34.3 ms | 2.42 / 2.46 ms | 1.77 / 1.80 ms |

Every expression row includes one fresh `Repo::open` (the cold commit cache a search after a reload has); the `Repo::open alone` column is that share — read a row net of it (0.5–1.6 ms, noisy: on medium the bare open even measured above the whole `all()` row). Re-run 2026-10-25 after the review added that column.

Reading: the commit-loading functions cost one commit load per commit of the domain (~1.2 s loose, ~33 ms packed at 10k); `files()` costs about twice that without jj's changed-path index and ~2 ms with it; `all()` is index-only. Nothing is gated on these numbers; choosing a mitigation stays 10.21's / Ralph's.

## Auto Run Result

Status: done. Implementation commit: `b6da7c21dcdda508b2e7c837236205c9a2268e80`. Spec and ledger commit: the commit that adds this file.

**Summary.**
- Two op-pinned reads:
  - `Repo::revset_counts(operation_id, expressions, cap)`: per expression, `Count{n, capped}` or its own revset error;
  - `Repo::find_changes(operation_id, expression, limit, short_prefixes)`: the commit and change ids plus both shortest-prefix lengths, in iteration order, with `truncated`.
- Both load the repo with `load_operation` + `load_at`. They take no snapshot, write no operation and leave the precondition unchanged.
- Symbols resolve with jj's id-prefix context, as the CLI's `default_symbol_resolver` does.
- `RevsetError` gains a structured detail:
  - the kind (22 variants, mirroring jj-lib);
  - a byte span into the call's primary expression, read back from pest's render (`shortcut:`-marked);
  - the symbol and candidates;
  - the CLI's hint lines.
- The detail reaches Dart as `FfiError.revset` / `ZanshinFfiException.revsetError`, on the topology call and on both new externs.
- `MutateError` revset refusals now carry the CLI's hints.

**Files (main):**
- `crates/zanshin-jj/src/revset.rs` — the error detail, span parser, hint port and prefix-context resolution.
- `crates/zanshin-jj/src/revset_search.rs` — the two searches.
- `crates/zanshin-jj/src/commit_content.rs` — the shared `load_pinned`.
- `crates/zanshin-jj/src/repo.rs` — the `Repo` methods.
- `crates/zanshin-jj/src/{graph,topology,mutate,commit_views,bookmarks,op_diff,template}.rs` — the new detail and span scoping, plus match sites.
- `schemas/envelope.fbs` and the generated files — the new tables, `FfiError.revset`, two `RequestKind`s and two `Payload` variants.
- `crates/zanshin-ffi/src/revset_search.rs` — the two externs.
- `crates/zanshin-ffi/src/envelope.rs` — `CallReport.revset`, which is merged through `with_report`.
- `crates/zanshin-ffi/src/graph.rs` — the detail and hints on topology errors.
- `packages/zanshin_core/lib/src/ffi/revset_search.dart` — the models and decoders.
- `packages/zanshin_core/lib/src/worker/{commands,isolate,handle,responses}.dart` and `ffi/precondition.dart` — the surface.
- Tests:
  - `crates/zanshin-jj/tests/it/revset_search.rs` and `api_stability.rs`;
  - `crates/zanshin-ffi/tests/it/revset_search_ffi.rs` and `graph_ffi.rs`;
  - `packages/zanshin_core/test/{worker,ffi}/revset_search_test.dart` and `test/worker/graph_test.dart`.
- `crates/zanshin-jj/benches/revset_counts.rs` — I7.
- `docs/ffi-abi.md` (exports 107 → 109) and `docs/rust-error-codes.md`.
- `epics.md` (dated notes on 4.12 and 9.28) and `sprint-status.yaml` (9-25 done, 4-12 note).

**Open items:**
- **I1 — rejected: no longer applies.** The 2026-10-14 refinement dropped the `revsets.log` writer (item 5) and names 9.28's `configSet`. `isolate.dart` no longer carries the claim. The one stale mention, 9.28's "9.25's `revsets.log` writer", got a dated note in `b6da7c2`.
- **I2 — rejected: no longer applies.** The refinement dropped presets, Apply and Save (item 5). This UI never writes `revsets.log` (decision (g)).
- **I3 — fixed (`b6da7c2`).** The refined 9.25 no longer builds on `graphSlice`; counts are their own call and are tested against the topology's node count. The remaining 4.12 line ("Consumers to re-point") and the 4-12 sprint-status comment got dated settle notes.
- **I4 — fixed (`b6da7c2`).** `find_changes` is the backend path for go-to beyond the view. It resolves `change_id(x)` / `commit_id(x)` / `description(…)` / `subject(…)` / bookmarks like the CLI's `-r`, with the CLI's ambiguous-prefix refusal verbatim; an unmatched prefix yields no entries. Resolving the input in the view stays 10.21's.
- **I5 — fixed (`b6da7c2`).** The refined 9.25 text and its sprint-status comment no longer say "Apply via `graphSlice`". The 4.12 texts that still pointed at it got dated settle notes.
- **I6 — fixed (`b6da7c2`).** `find_changes` over `description(substring-i:)` / `subject()` searches every change at the shown operation.
- **I7 — partly done (`b6da7c2`, numbers in Verification).**
  - Measured on medium, large-10k loose and large-10k packed, each with and without jj's changed-path index.
  - Commit-loading functions: ~1.2 s loose / ~33 ms packed at 10k.
  - `files()`: ~2.4 s loose / ~55 ms packed without the index, and ~2 ms with it.
  - The "synthetic inputs" part is rejected: the 100k synthetic input (`crates/zanshin-ffi/benches/graph_wire.rs`) is a topology with no repository, so a revset cannot be counted on it.
  - Choosing a mitigation stays 10.21's / Ralph's, as the item says.

**Review findings:** 26 findings — high 0, medium 6, low 17, false 3, maybe-false 0.
- **Patched (15 rows in 11 fixes):**
  - `find_changes`' `short_prefixes` resolution test;
  - the span only on the primary expression;
  - a lone `^` gives length null;
  - real jj-lib span cases;
  - `mine()` non-zero;
  - the Dart span checks;
  - the request-before-handle tests;
  - the bench `Repo::open` row;
  - the `rust-error-codes.md` note;
  - `toString()`;
  - the 4-12 note.
- **Deferred (5, in frontmatter and mirrored to `deferred-work.md`):**
  - id-prefix context for the topology and every verb (medium, CLI parity, touches every verb);
  - warnings dropped on call-level errors;
  - UTF-8 vs UTF-16 offsets for the Dart highlighters;
  - revset hints on show/evolog/bookmarks/op diff;
  - `render_span` on the pin-bump checklist.
- **Rejected:**
  - Auto Run Result missing: written at finalize.
  - `subject()` / `committer()` not benched: same cost class as `author` / `description`.
  - The optional oracle: optional.
  - `cap 0` gives `capped=false`: spec-defined.
  - An evaluation `JjLibError` fails the batch (×2): backend faults are repository-wide and call-level by spec; bad expressions stay per entry.
  - `revset_counts` without a caller `short_prefixes`: follows the CLI's effective config; rare; the fix would add a request field.
  - Value-class `==` / `toString` / mutability: no consumer yet.

**Follow-up review: recommended (`true`).** Three medium entries were patched. The unverified risk is the patch round's `RevsetError::without_span()` scoping across the topology's `prioritize` / `short_prefixes` / anchor parse paths (`crates/zanshin-jj/src/graph.rs` `LogParse::new`, `crates/zanshin-jj/src/topology.rs`). It changed what an existing call reports and has had no independent review.

**Not done:**
- The optional 9.47 parity-oracle comparison of the counts.
- MCP (`zanshin-mcp` is a stub).
- The coverage ratchet and the full gate: deliberately not run, because the story loop runs them once at its end. The extern-coverage guard should be satisfied by the two real-cdylib Dart tests.

**Residual risks:**
- The span is read back from pest's rendered text: a jj-lib or pest bump can change it silently (deferred).
- The new Rust files' coverage is unmeasured until the loop's gate. A few backend-only error arms in `revset_search.rs` are not exercised.

### Follow-up review pass (2026-10-25)

Four layers (blind, edge-case, verification-gap, intent-alignment) reviewed the full diff since `9b65ca8`. 22 findings — high 0, medium 2, low 15, false 5, maybe-false 0.

**Patched (5 entries; by verdict: medium 1, low 4; no code change, tests and docs only):**
- `packages/zanshin_core/test/worker/revset_search_test.dart` — `find_changes_passes_its_short_prefixes_through` (medium: the `shortPrefixes` pass-through was untested above zanshin-jj); the counts test now also lists the op store and op heads around the dirty-`@` reads (the AC's "no operation file or op head changes" at the Dart surface).
- `packages/zanshin_core/test/worker/graph_test.dart` — the topology's resolution detail (`noSuchRevision`, symbol) and `descripton(x)`'s candidates and "Did you mean" hint through the cdylib.
- `crates/zanshin-jj/src/revset_search.rs` (`FoundChanges.warnings` rustdoc), `docs/ffi-abi.md` § Graph search and `docs/rust-error-codes.md` (`jj.invalid_input` and `jj.short_prefixes_failed` rows) — the new externs' invalid-input texts and `find_changes`' short-prefixes warning.

**Deferred:** none new (the hints-on-other-reads and pin-bump-checklist rows were carried from the first pass); nothing added to `deferred-work.md`.

**Rejected (with reasons in the triage log):** id-prefix context for the other verbs (the intent forbids it; already deferred); a lone `^` length heuristic; a source field on the detail (×2); divergence data on `FoundChange`; stale planning text in epics.md; the 40-hex matrix row (×2; only a spec edit); `revset_counts`' `short_prefixes` (carried); an unknown wire kind in Dart; and five false findings (struck ledger convention, `limit == 0`, `render_span` past line end, two index loads, `MutateError` hints coverage).

**Follow-up review: not recommended (`false`).** A follow-up pass recommends another only when it patched a `high`; this one patched 1 medium and 4 low, all test or doc changes.
