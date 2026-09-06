---
title: 'Epic 9 follow-up F: the two Story 9.6 read-view must-haves — ShowRequest.limit and InterdiffView.base_has_conflicts'
type: 'feature'
created: '2026-09-06'
status: 'done'
baseline_revision: 'd7b196c5e4cb4a9e81e1fbf5950caeed421f3867'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['multiple-goals', 'oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Two shipped Story 9.6 surfaces are under-specified. (1) `show` is UNBOUNDED — one
envelope, no limit, a full merged-parent tree diff plus a per-parent copy-record stream per entry
(`crates/zanshin-jj/src/commit_views.rs::show`), so `show("all()")` on `medium-1k-commits`
materialises a thousand entries into one `FlatBuffers` buffer. That is CLI parity (`jj show` is
unbounded too) but the CLI streams to a pager; nothing here bounds or measures it, while the sibling
`evolog` already carries a `limit` and `zanshin-graph` streams. (2) `InterdiffView` cannot signal
that the in-memory rebase behind it left CONFLICTS in the tree it diffs FROM — `rebase_to_dest_parent`
is a 3-way merge that can return a conflicted `MergedTree`, and the payload is only `file_changes`,
so a caller sees a plausible change list derived from a conflicted rebase with no way to tell.
`ShowEntry` at least carries `Change.conflict`; no test anywhere constructs a conflicting rebase.

**Approach:** Add an optional `limit` to `ShowRequest` modelled EXACTLY on `EvologRequest.limit` at
every layer, with the same null/absent = unbounded semantics and the same walk-order early stop, plus
a `benches/` perf witness that prints (never asserts) timings; and add a `base_has_conflicts` presence
flag to `InterdiffView`, derived by the same predicate `Change.conflict` uses, witnessed by one
in-test conflicting rebase plus the negative pole. Both are in-place edits of shipped payloads. This
is a CLOSING run for the two named ledger entries; nothing else is in scope.

## Boundaries & Constraints

**Always:**
- **`ShowRequest.limit` mirrors `EvologRequest.limit` field-for-field and word-for-word.** Wire form
  is the presence PAIR `limit: uint; has_limit: bool;` (`schemas/envelope.fbs:188-192`), not an
  optional scalar — flatc 25.12.19 rejects optional scalars for Dart, and `limit = 0` is a MEANINGFUL
  value (an empty result, not an error) so absence cannot be encoded as zero. Rust parameter is
  `Option<usize>`; the Dart adapter SATURATES at `_maxWireLimit` (`0xFFFFFFFF`) and REFUSES a negative
  limit with `ArgumentError`, with the same calling-side guard in `ZanshinWorker` that `evolog`
  carries and the same WHY comment. Absent = unbounded = today's output, byte-for-byte.
- **Early stop is `take(limit.unwrap_or(usize::MAX))` applied to the commit stream BEFORE the loop
  body** — the identical shape `evolog` uses at `commit_views.rs:339`. Everything expensive
  (`parent_tree`, `copy_records_over_all_parents`, `tree_file_changes`, `change_from_commit`) lives
  inside that loop, so nothing beyond `limit` is computed. The limit applies in RAW revset order, the
  same order the unbounded call returns.
- **`base_has_conflicts` is derived by the same predicate `Change.conflict` is.**
  `Commit::has_conflict()` is `!self.tree_ids().is_resolved()`
  (`jj-lib-0.44.0/src/commit.rs:167-169`) and `MergedTree::has_conflict()` is
  `!self.tree_ids.is_resolved()` (`merged_tree.rs:211-213`) — the same test on the same shape. Call
  `has_conflict()` on the tree `rebase_to_dest_parent` returns; do not re-implement it and do not
  reach for `conflicts()`.
- **The flag is about the LEFT side of the diff only** — the rebased `from` tree. It is `true`
  whenever that tree is conflicted, whatever the cause: the 3-way merge left a conflict, OR the fast
  path (`rewrite.rs:456-460`, same parents) returned `from`'s own already-conflicted tree. `to`'s own
  conflict state is NOT reported here; it is addressable through `show`/`get_change`.
- **A Rust return struct is required for interdiff**, because the payload stops being a bare list.
  Mirror `zanshin_jj::FileSearch` (Story 9.4 / follow-up E): a `pub struct` named after the wire table
  (`InterdiffView`), exported from `lib.rs`, threaded through `Repo::interdiff`, the FFI writer, the
  Dart model and both worker seams. Same treatment on the Dart side (`FileSearch` in
  `packages/zanshin_core/lib/src/ffi/file.dart:232-240` is the template).
- Both are Zanshin-side additions the CLI has no counterpart for (`jj show` has no `-n`; the CLI
  renders conflict markers in the patch TEXT, which is Epic 5's surface here). Document each as such
  at every layer, and keep the absent/false default byte-identical to the current behaviour — that is
  what preserves NFR-R-2 parity and satisfies FR-JJ-17 (no hidden default decided for the user).
- `.fbs` edited IN PLACE (no `_v2` tables, no in-wire `schema_version`), ONE `cargo make codegen`,
  generated `envelope_generated.rs` + `envelope_zanshin.ffi_generated.dart` committed. No `extern "C"`
  SIGNATURE moves — both arguments ride in the existing request/response buffers — so
  `zanshin_ffi.h` / `bindings.dart` may only gain DOC-COMMENT hunks.
- `#![deny(missing_docs)]` stays satisfied; no `jj_lib` type appears in any public signature
  (`has_conflict()` returns a plain `bool`, so nothing leaks).
- The perf witness lives in `crates/zanshin-jj/benches/` with `harness = false`, exactly like
  `benches/graph_blueprint.rs`. Verified: `cargo test -p zanshin-jj --no-run` builds no bench target,
  so benches are outside the gate and outside coverage — while `cargo clippy --workspace
  --all-targets` DOES compile them, so it must be pedantic-clean. It prints timings with `eprintln!`
  and asserts NOTHING about wall-clock (`#[ignore]`-on-flaky is banned; a `benches/` target is the
  project's sanctioned home for non-running perf scaffolding).
- The coverage ratchet must not drop. Today: `crates/zanshin-jj/src/commit_views.rs = 98.13`,
  `crates/zanshin-ffi/src/commit_views.rs = 100.00`, `crates/zanshin-jj/src/repo.rs = 96.46`,
  with `epsilon_pct = 0.10`. Every new line — the `take`, the `has_conflict()` read, the presence-pair
  reader arm, the bool writer — needs a test that EXECUTES it, and both bool arms need executing.
- Every touched `extern "C"` fn keeps its `packages/zanshin_core` cdylib test; `zanshin_show` and
  `zanshin_interdiff` already have one, and none is added or removed.

**Block If:**
- A conflicting rebase cannot be constructed in-test from the existing `test-helpers` write helpers
  (`add_commit_with_files` on the `tiny-3-commits` fixture) and no other construction is found without
  regenerating a fixture, so the `true` arm ships uncovered and the ratchet drops: HALT `blocked`,
  blocking condition `no witness for the interdiff conflicted-base arm`.
- The ratchet can only be made green by lowering a baseline entry or adding an `exclude_prefix`: HALT
  `blocked`, blocking condition `coverage ratchet regression`.

**Never:**
- No cursor/pagination on `show` — the ledger's alternative ("or have the GUI cap the revset") is not
  taken either; `limit` is the whole mechanism. No limit on `interdiff`, none on the `paths` filter.
- No `limit` on the four other request tables, and no change to `EvologRequest` or to `evolog`'s
  behaviour: `evolog` is the TEMPLATE, not a target.
- No `conflicts()` path list on `InterdiffView` — a presence flag is what the ledger asks for, and a
  per-path conflict channel belongs with Epic 5's hunk payload.
- No fixture regeneration (`tiny-3-commits` / `medium-1k-commits` are built ON in-test, never
  rebuilt). No new `error.code` and no `docs/rust-error-codes.md` row: a limit is not an error, and a
  conflicted rebase base is not an error either — `interdiff` still SUCCEEDS.
- No `docs/ffi-abi.md` pass (that is its own open ledger item), no MCP surface, no unrelated cleanup
  in the touched functions or files.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| show, limit absent | `show(Some("all()"), None)` on a multi-commit repo | every commit the revset denotes, in raw revset order — byte-identical to the pre-change output | No error expected |
| show, limit below the set size | `show(Some("all()"), Some(2))` | exactly 2 entries, and they are the FIRST 2 of the unbounded result | No error expected |
| show, limit above the set size | `show(Some("@"), Some(5))` on a 1-commit revset | 1 entry — a limit larger than the set is not an error | No error expected |
| show, limit zero | `show(None, Some(0))` | EMPTY list and a SUCCESS, exactly as `evolog(_, Some(0))` | No error expected |
| show, limit on an empty revset | `show(Some("none()"), Some(3))` | empty list, success | No error expected |
| show, wire limit over the `uint` ceiling | Dart `show(limit: 0x100000000)` | SATURATES to `0xFFFFFFFF` — "everything" — never wraps to an empty result | No error expected |
| show, negative limit | Dart `show(limit: -1)` | refused before any FFI call | `ArgumentError` (synchronous, both in `ZanshinWorker.show` and in the `zanshinShow` adapter) |
| interdiff, clean rebase | the existing `interdiff_pair` (`from`/`to` with different parents, disjoint edits) | `file_changes` unchanged; `base_has_conflicts == false` | No error expected |
| interdiff, conflicting rebase | `from` and `to` both edit `f.txt` off DIFFERENT parents that also differ at `f.txt` | the call SUCCEEDS, `base_has_conflicts == true` | No error — a conflicted base is a fact, not a refusal |
| interdiff, revision against itself | `interdiff(to, to, [])` | empty `file_changes`; `base_has_conflicts == false` (the fast path returns `to`'s own clean tree) | No error expected |
| interdiff, unmatched path filter on a conflicted base | conflicting pair + `paths = ["nosuchdir"]` | `file_changes` EMPTY but `base_has_conflicts` still `true` — the flag describes the TREE, not the filtered result | No error expected |

</intent-contract>

## Code Map

Zanshin anchors read against the working tree at baseline `d7b196c`; jj CLI anchors at tag `v0.44.0`
(`git -C ../jj show v0.44.0:<path>`); jj-lib anchors in the vendored
`~/.cargo/registry/src/index.crates.io-*/jj-lib-0.44.0`.

**Read-only evidence (do not edit)**
- `jj-lib-0.44.0/src/rewrite.rs:451-460` — `rebase_to_dest_parent(repo, sources, destination)`; the
  FAST PATH returns `source.tree()` verbatim when the single source already has the destination's
  parents. `:462-490` — otherwise a `MergedTree::merge` of `Merge::from_diffs` over
  (`destination.parent_tree`, `source.parent_tree`, `source.tree`), i.e. a 3-way merge with the
  source's parent tree as base. Two sides that both edit one path leave that path unresolved.
- `jj-lib-0.44.0/src/merged_tree.rs:211-213` — `MergedTree::has_conflict() == !tree_ids.is_resolved()`;
  `:336` `MergedTree::merge`. `jj-lib-0.44.0/src/commit.rs:167-169` — `Commit::has_conflict()` is the
  IDENTICAL predicate, which is what makes the derivation "the way `ShowEntry` derives it".
- `crates/zanshin-jj/src/change.rs:241-250` — the `Change.conflict` derivation (`commit.has_conflict()`
  then `tree().conflicts()`); the flag reuses only the first half.
- `cli/src/commands/show.rs` @ v0.44.0 — no `-n/--limit` and no path argument (`EverythingMatcher`);
  `cli/src/commands/evolog.rs` — `-n/--limit` applied BEFORE the reversal.

**Item 1 — `ShowRequest.limit`**
- `schemas/envelope.fbs:164-180` `ShowRequest` (the doc block to extend); `:182-192` `EvologRequest`
  — the presence-pair template, whose `limit`/`has_limit` comment is the wording to mirror;
  `:820-829` `ShowView` (doc gains the limit sentence; the TABLE is unchanged).
- `crates/zanshin-jj/src/commit_views.rs:254-301` `show` — `:269-270` signature, `:283-297` the
  `pollster::block_on` walk to `take`; `:317-353` `evolog` is the shape to copy (`:339` is the
  `take(limit.unwrap_or(usize::MAX))` line). Module doc `:1-41` needs no change.
- `crates/zanshin-jj/src/repo.rs:940-991` `Repo::show` facade + doc; `:993-1032` `Repo::evolog` is the
  doc template for the `limit` paragraph.
- `crates/zanshin-ffi/src/commit_views.rs:58-63` `ShowRequestOwned`; `:65-70` `EvologRequestOwned`
  (template); `:80-94` `read_show_request`; `:101-113` `read_evolog_request` (`:109-111` is the
  presence-pair comment to mirror); `:204-255` `zanshin_show` doc + body.
- `packages/zanshin_core/lib/src/ffi/commit_views.dart:29-45` `zanshinShow`; `:47-78` `zanshinEvolog`
  + `_maxWireLimit` — the saturation/negative-guard template.
- `packages/zanshin_core/lib/src/worker/commands.dart:638-657` `ShowCommand`; `:659-682`
  `EvologCommand` (template).
- `packages/zanshin_core/lib/src/worker/isolate.dart:1066-1090` `ZanshinWorker.show`; `:1092-1121`
  `evolog` (`:1108-1116` is the calling-side-guard WHY comment to mirror); `:1738-1747` the
  `ShowCommand` dispatch arm, `:1749-1758` the `EvologCommand` one.
- `packages/zanshin_core/lib/src/worker/handle.dart:616-648` `RepoHandle.show`; `:650-685` `evolog`.
- Generated: `crates/zanshin-ffi/src/envelope_generated.rs` (`ShowRequest`/`ShowRequestArgs`/builder),
  `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`
  (`ShowRequest` + `ShowRequestObjectBuilder`).
- Tests: `crates/zanshin-jj/tests/commit_views.rs:278-620` the `show` block (`:280-299` the `@`
  default row, `:333` the `root()` row, `:365` the `parent::child` row — the natural host for a
  limit row, since it already builds a multi-commit revset); `:107-109` `head_op_id`,
  `:115-117` `open`, `:120-134` `summary`.
  `crates/zanshin-ffi/tests/commit_views_ffi.rs` — the `show_request_bytes` builder near `:100-137`
  and the `zanshin_show` round-trip block before `:337`.
  `packages/zanshin_core/test/ffi/commit_views_test.dart:270-271` the interior-NUL row (where the
  negative-limit row belongs); `packages/zanshin_core/test/worker/commit_views_test.dart:55-84` the
  two `show` rows, `:86-115` the `evolog` limit rows (the assertion template: zero, over-large
  saturation, negative `ArgumentError`).
- `crates/zanshin-jj/tests/api_stability.rs:685-686` the `Repo::show` fn-pointer cast (arity moves).

**Item 2 — `InterdiffView.base_has_conflicts`**
- `schemas/envelope.fbs:861-870` `InterdiffView` (table + doc). Convention exemplars for a plain
  bool: `Change.is_signed`/`divergent`; for the payload-struct pattern, `:703-706` `FileSearch`.
- `crates/zanshin-jj/src/commit_views.rs:355-419` `interdiff` — `:389-395` signature (return type
  moves), `:410-418` the rebase + diff block where the flag is read; `:60-74` `ShowEntry` is the
  struct-doc shape to mirror for the new `InterdiffView` struct; `:373-378` the doc paragraph that
  already NAMES the conflict possibility and must now point at the flag.
- `crates/zanshin-jj/src/file.rs` `FileSearch` (struct + its `Repo` facade threading) — the pattern
  follow-up E established for turning a bare `Vec` return into a two-field payload struct.
- `crates/zanshin-jj/src/lib.rs:54` the `commit_views` re-export list (gains `InterdiffView`).
- `crates/zanshin-jj/src/repo.rs:1034-1083` `Repo::interdiff` facade + doc (return type + a new
  paragraph).
- `crates/zanshin-ffi/src/commit_views.rs:189-200` `interdiff_view_to_envelope` (signature + one
  `base_has_conflicts` arg); `:336-349` `zanshin_interdiff`; `:534-548` the in-file writer unit test
  `interdiff_view_carries_the_change_list` (extend to BOTH bool arms); `:550-561`
  `empty_results_still_produce_ok_envelopes` (its `interdiff_view_to_envelope(&[])` call moves).
- `packages/zanshin_core/lib/src/ffi/commit_views.dart:203-220` the interdiff decoder (return type);
  `:104-148` the model block (where the new model goes);
  `packages/zanshin_core/lib/src/ffi/file.dart:232-240` `FileSearch` model + `:347-356` its decoder
  are the shape to mirror.
- `packages/zanshin_core/lib/src/worker/isolate.dart:1142-1158` `ZanshinWorker.interdiff` (return
  type); `packages/zanshin_core/lib/src/worker/handle.dart:687-720` `RepoHandle.interdiff`.
  The isolate DISPATCH arm (`:1760-1774`) forwards raw bytes — no change.
- Tests: `crates/zanshin-jj/tests/commit_views.rs:136-167` `interdiff_pair` (the clean-rebase
  fixture, and the shape the new conflicting pair copies), `:806-857` the three clean rows (negative
  pole), `:940-960` the cross-verb row. `test_helpers::add_commit_with_files`
  (`crates/test-helpers/src/lib.rs:196-222`) is the only builder needed — `add_conflicted_merge_off_root`
  builds a conflicted MERGE COMMIT, which is a different shape and NOT what this needs.
  `crates/zanshin-ffi/tests/commit_views_ffi.rs:337-380` the interdiff round-trip;
  `packages/zanshin_core/test/ffi/commit_views_test.dart:219-265` the interdiff decode group;
  `packages/zanshin_core/test/worker/commit_views_test.dart:128-168` the two interdiff rows.
- `crates/zanshin-jj/tests/api_stability.rs:96-108` the type-alias list, `:317-337` the two Story 9.6
  sample builders (a `sample_interdiff_view()` joins them), `:682-699` the call-site block and the
  `Repo::interdiff` fn-pointer cast.

**Perf witness**
- `crates/zanshin-jj/benches/graph_blueprint.rs` — the whole file is the template: `ENV_GUARD` +
  `pin_env` (`:50-61`), `measure(warmup, iters, f)` returning `(min, median)` (`:65-78`),
  `extract_fixture("medium-1k-commits")` (`:140`), the single `eprintln!` summary line (`:151`).
- `crates/zanshin-jj/Cargo.toml:34-40` — the `[[bench]]` block with its `harness = false` WHY comment;
  a second block joins it. `[dev-dependencies]` already carries `test-helpers` and `tempfile`.
- `test-fixtures/repos/medium-1k-commits.tar.zst` — committed, extracted by `extract_fixture`.

**Gates / bookkeeping**
- `coverage-baseline.txt:8-11` knobs; entries at `:17` (`zanshin-ffi/src/commit_views.rs`),
  `:41` (`zanshin-jj/src/change.rs`), `:43` (`zanshin-jj/src/commit_views.rs`), `:54`
  (`zanshin-jj/src/repo.rs`).
- `Makefile.toml:47-67` the `test` task (`test-clippy` runs `--workspace --all-targets`);
  `:289-344` `codegen`.
- `_bmad-output/implementation-artifacts/deferred-work.md:198` (`show` unbounded) and `:200`
  (`InterdiffView` conflicts) — the two bullets to strike through.
- `spec-9-6-read-views-show-evolog-interdiff.md` — the two matching `deferred:` items each get a
  `resolved: >-` block scalar.

## Tasks & Acceptance

**Execution:**
- `schemas/envelope.fbs` -- add `limit: uint;` + `has_limit: bool;` to `table ShowRequest` with the
  same trailing comment `EvologRequest` carries, and a doc sentence saying the CLI has NO `-n` here so
  absence is the CLI-parity default; add `base_has_conflicts: bool;` to `table InterdiffView` with a
  doc sentence naming the rebased `from` tree, the fast-path case, and that the CLI signals this in
  patch TEXT (Epic 5's surface). -- One in-place edit of the wire contract per WIP rules; both follow
  precedents already in this file.
- run `cargo make codegen` ONCE and commit `crates/zanshin-ffi/src/envelope_generated.rs` +
  `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`. -- Generated code is
  committed and the build never regenerates; `zanshin_ffi.h`/`bindings.dart` may only move by
  doc-comment hunks, because no `extern "C"` signature changes.
- `crates/zanshin-jj/src/commit_views.rs` -- give `show` a third `limit: Option<usize>` parameter and
  apply `.take(limit.unwrap_or(usize::MAX))` to the commit stream before the loop; add a
  `pub struct InterdiffView { file_changes, base_has_conflicts }` with a doc explaining both fields
  and the fast-path case; make `interdiff` return it, reading `from_tree.has_conflict()` BEFORE the
  diff; extend both fn docs. -- `take` on the stream is the only placement that stops the per-entry
  tree work; `has_conflict()` is the same predicate `Change.conflict` uses, so the two payloads agree.
- `crates/zanshin-jj/src/lib.rs` -- re-export `InterdiffView` from the `commit_views` list. -- The
  facade's return type must be nameable by consumers.
- `crates/zanshin-jj/src/repo.rs` -- thread `limit` through `Repo::show` and the new return type
  through `Repo::interdiff`, extending both doc blocks (a `limit` paragraph copied from `Repo::evolog`
  and adapted to "the CLI has no such flag"; a `base_has_conflicts` paragraph). -- The facade rustdoc
  is what a consumer reads.
- `crates/zanshin-ffi/src/commit_views.rs` -- add `limit: Option<usize>` to `ShowRequestOwned`, read
  it from the presence pair in `read_show_request` with the same comment `read_evolog_request` carries,
  pass it to `session.repo.show(...)`; change `interdiff_view_to_envelope` to take the
  `InterdiffView` and write the bool; extend the two `extern "C"` doc blocks. -- The reader/writer
  layer is where the wire shape becomes Rust, and cbindgen lifts the docs into the header.
- `packages/zanshin_core/lib/src/ffi/commit_views.dart` -- add `int? limit` to `zanshinShow` with the
  negative-refusal + `_maxWireLimit` saturation `zanshinEvolog` already has; add an `InterdiffView`
  model (`fileChanges`, `baseHasConflicts`) and return it from both interdiff decode seams. -- The
  saturation guard exists because an unclamped `4294967296` would be written as `0` and come back as
  an EMPTY result — the most misleading possible answer.
- `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` -- add `limit` to
  `ShowCommand`, to `ZanshinWorker.show` (with the calling-side negative guard and the same WHY
  comment `evolog` carries) and to `RepoHandle.show`; destructure `limit` in the `ShowCommand`
  dispatch arm; move the interdiff return type to `InterdiffView` in `ZanshinWorker` and
  `RepoHandle`. -- The worker bus is the production path; the dispatch arm is the only place the
  adapter is called.
- `crates/zanshin-jj/benches/show_limit.rs` + `crates/zanshin-jj/Cargo.toml` -- a second
  `harness = false` bench that pins `JJ_CONFIG`/`GIT_CONFIG_GLOBAL`, extracts `medium-1k-commits`,
  opens it with `zanshin_jj::Repo::open`, and prints `eprintln!` timings for `show("all()", None)`
  versus `show("all()", Some(N))` using a `measure`-style min/median helper. NO assertion on
  wall-clock, no `#[ignore]`. -- Benches are not built by `cargo test` (verified) so they cost the
  gate nothing, but clippy `--all-targets` compiles them, so the file must be pedantic-clean.
- `crates/zanshin-jj/tests/commit_views.rs` -- add the `show` limit rows (below the set size and
  first-N-of-unbounded, above the set size, zero, empty revset, absent unchanged) and ONE conflicting
  interdiff row built with `add_commit_with_files`: two parents that differ at `f.txt`, each carrying
  a child that edits `f.txt` differently, asserting the call SUCCEEDS with `base_has_conflicts` true;
  add the `false` pole to the existing clean rows. -- These are the I/O matrix rows that need a real
  repo; the conflicting pair is the only construction that reaches the 3-way merge's unresolved arm.
- `crates/zanshin-ffi/tests/commit_views_ffi.rs` -- extend the `ShowRequest` builder with the presence
  pair and add a limited/unlimited round-trip; assert `base_has_conflicts` on the existing interdiff
  round-trip. -- The request-buffer reader arm and the payload writer are only reachable here.
- `packages/zanshin_core/test/{ffi,worker}/commit_views_test.dart` -- decode-contract rows for
  `baseHasConflicts` (both arms, synthetic buffers) and the `zanshinShow` negative-limit refusal;
  worker rows for `show(limit: 0)`, a positive limit, the over-large saturation and the negative
  `ArgumentError`, plus `baseHasConflicts` through the real cdylib. -- Mirrors the `evolog` limit
  rows exactly; the worker rows are the end-to-end witness.
- `crates/zanshin-jj/tests/api_stability.rs` -- update the `Repo::show` / `Repo::interdiff`
  fn-pointer casts, add `InterdiffView` to the type-alias list and a `sample_interdiff_view()`
  builder called from the Story 9.6 block. -- A field rename, reorder or arity change must break at
  compile time.
- `_bmad-output/implementation-artifacts/deferred-work.md` and
  `spec-9-6-read-views-show-evolog-interdiff.md` -- strike through the two bullets in the house
  convention with a `— RESOLVED 2026-09-06 (…)` tail, and add a `resolved: >-` block scalar to each
  matching `deferred:` frontmatter item. -- The ledger must end this run smaller than it started.

**Acceptance Criteria:**
- Given a `ShowRequest` buffer built by an older caller (no `limit`, no `has_limit`), when it reaches
  `zanshin_show`, then the result is byte-identical to the pre-change unbounded output — absence is
  read as "unbounded", never as `limit = 0`.
- Given `cargo make codegen` has been run once, when it is run a second time, then neither flatc
  output changes, and `crates/zanshin-ffi/include/zanshin_ffi.h` and
  `packages/zanshin_core/lib/src/ffi/bindings.dart` differ from the baseline only in doc comments.
- Given the whole change, when `cargo make test` runs, then it exits 0 with no per-file coverage
  regression and `coverage-baseline.txt` either untouched or raised (never lowered, no new
  `exclude_prefix`).
- Given `cargo bench -p zanshin-jj --bench show_limit`, when it runs, then it prints one timing line
  per configuration and exits 0 without asserting on any duration.
- Given each of the two ledger bullets, when the run finishes, then the bullet is struck through with
  a resolution note naming this spec's slug and the commit, and the matching `deferred:` item in
  `spec-9-6-read-views-show-evolog-interdiff.md` carries a `resolved:` block scalar with the YAML
  still valid.

## Spec Change Log

### 2026-09-06 — Generated-artifact criterion reconciled (recorded, not amended)

The AC "`zanshin_ffi.h` and `bindings.dart` differ from the baseline only in doc comments" is
LITERALLY violated by the change, and the deviation is a generated-code artefact rather than a
surface change: cbindgen also emitted `#define InterdiffView_VT_BASE_HAS_CONFLICTS 6` and RENAMED
`EvologRequest_VT_LIMIT`/`_HAS_LIMIT` to `ShowRequest_VT_LIMIT`/`_HAS_LIMIT` (it dedupes
identically-valued constants and now picks the other owner — both values are unchanged, 6 and 8).
No `extern "C"` signature line moved, verified by filtering the diff, and nothing in the repo
references any of those constants (`grep` over `crates/`, `packages/`, `app/` finds only the two
generated files themselves). Recorded here rather than amended into the AC because the AC's
INTENT — "no `extern "C"` signature moves" — held, and the same reconciliation was made for
follow-up E. Future schema-field additions should expect vtable-offset `#define` churn in the
header whenever two tables share a slot value.

## Review Triage Log

### 2026-09-06 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 7: (high 0, medium 4, low 3)
- defer: 0
- reject: 17
- addressed_findings:
  - `[medium]` `[patch]` The `base_has_conflicts` doc enumerates TWO causes — the 3-way merge and
    `rebase_to_dest_parent`'s fast path returning `from`'s own already-conflicted tree — but only
    the first was exercised; three reviewers converged on it and one supplied a falsifying
    mutation (`from_tree.has_conflict() && from_commit.parent_ids() != to_commit.parent_ids()`)
    that left the whole suite green. Added
    `interdiff_flags_a_conflicted_base_reached_through_the_rebase_fast_path` in
    `crates/zanshin-jj/tests/commit_views.rs`: a conflicted merge interdiffed against ITSELF, so
    identical parents force the fast path and identical trees empty the change list, leaving the
    flag as the only signal. Mutation-probed — that mutation now fails exactly this test and
    nothing else.
  - `[medium]` `[patch]` Neither conflicted-base test asserted the change list SURVIVED, so a
    regression that reported the conflict and threw the comparison away would have passed both.
    `interdiff_reports_a_conflicted_rebase_base_without_refusing` now pins
    `summary(&view.file_changes) == [("f.txt", "M")]` on the unfiltered arm.
  - `[medium]` `[patch]` The schema's `// 0 / ignored when has_limit == false` contract had no
    witness: the FFI request builder always wrote `limit` and `has_limit` together, so the one
    combination the comment exists for was unconstructible. Split
    `show_request_bytes_with_limit` over a new `show_request_bytes_raw(revset, limit, has_limit)`
    and added a row with `limit = 1, has_limit = false` asserting UNBOUNDED. Mutation-probed
    against a zero-sentinel reader (`(req.limit() != 0).then(...)`), which fails exactly this test.
  - `[medium]` `[patch]` `benches/show_limit.rs` printed timings but asserted nothing, so a
    `take` that stopped bounding the walk would have printed FASTER numbers and read as a
    success. It now asserts `entries.len() == limit.min(total)` inside the measured closure — a
    shape assertion, not a wall-clock one, so the flakiness ban is untouched — and the count run
    doubles as the warmup instead of paying one extra ~450 ms unbounded pass.
  - `[low]` `[patch]` The `// Read BEFORE the diff:` comment claimed the read ORDER is what keeps
    a `paths` filter from narrowing the flag. It is not: `MergedTree::has_conflict()` takes no
    matcher, so the independence is by construction at any position. Reworded to say that.
  - `[low]` `[patch]` Two test comments claimed the rebase fast path returns `to`'s (Dart: `@`'s)
    own tree; `rewrite.rs:459` returns `source.tree()`, i.e. `from`'s. They coincided only
    because both tests compare a revision with itself. Corrected in
    `tests/commit_views.rs::interdiff_of_a_revision_against_itself_is_empty` and in the Dart
    worker test.
  - `[low]` `[patch]` The early stop's second-order consequence was undocumented: not computing
    an entry also means not FAILING on it, so a revset whose later commits are unreadable
    succeeds under a limit and errors without one. Named in `commit_views.rs::show` and in the
    `Repo::show` facade, with the note that `evolog`'s `take` has always had the same property.

Notable rejections, since three of them look like defects until checked: (a) "`base_has_conflicts`
can be true with zero conflicting paths" — false for these trees. `MergedTree::merge` ends in
`resolve()`, and `merged_tree.rs:169-172` states that a resolvable merge comes back RESOLVED, so
after the rebase `has_conflict()` holds exactly when `conflicts()` is non-empty; the reviewer had
generalised the `value_at_path` note about one path resolving inside a conflicted tree. (b) "Rust
has no legacy-buffer decode test for `InterdiffView`, while Dart does" — Rust only ever WRITES
that payload; the reading side is Dart, which has the test. The mirror-image case (Rust reading a
pre-field `ShowRequest`) is real and is covered by the retained `show_request_bytes`. (c) "the
negative-limit `ArgumentError` is documented as synchronous but is not" — the doc marks the
`StateError` as synchronous and deliberately does not make that claim for the `ArgumentError`,
matching `evolog`'s shipped wording. The rest were house patterns the change deliberately mirrors
(doc text repeated per layer, the `limit`-guard duplication `evolog` already carries, the bench
harness copied from `graph_blueprint.rs`, pinned jj-lib line citations), scope the intent itself
fixed (`bool` rather than a `ConflictState` path list; `limit` rather than `limit`/cursor;
`benches/` rather than a literal `#[ignore]`), or artefacts of the review diff (generated outputs
and bookkeeping excluded from it, `coverage-baseline.txt` legitimately unchanged).

## Design Notes

**One premise of the dispatched intent needs re-reading, and the resolution follows the project's
own rules rather than the literal wording.** The intent asks for "an `#[ignore]`d benchmark in the
crate's `benches/` (or `tests/`, never inline in `src/`)". `#[ignore]` applies to `#[test]`
functions; a `benches/` target with `harness = false` has no test functions at all, and
`cargo test -p zanshin-jj --no-run` was observed to build NO bench target — so a `benches/` file is
already fully outside the gate, which is what `#[ignore]` was reaching for. The project explicitly
bans `#[ignore]` as a flakiness escape hatch and names `benches/` as the home for non-running perf
scaffolding, and `benches/graph_blueprint.rs` is the in-repo precedent. The bench therefore has no
`#[ignore]`; the intent's substantive constraints (out of the gate, in `benches/`, never in `src/`,
no wall-clock assertion) are all satisfied.

**Why a conflicting rebase needs its own construction and not `add_conflicted_merge_off_root`.**
That helper builds a conflicted MERGE COMMIT — the conflict already lives in a committed tree. What
this needs is a conflict produced BY `rebase_to_dest_parent`'s 3-way merge, whose base is
`from.parent_tree()` and whose two sides are `to.parent_tree()` and `from.tree()`. So the shape is
four commits: two parents that already differ at one path, and one child of each that edits that same
path differently. Both sides then changed the base's value of `f.txt`, which is exactly the
unresolvable case. The fast path (`rewrite.rs:456-460`) does not fire, because the two children have
different parents.

```rust
// crates/zanshin-jj/tests/commit_views.rs — shape only
let p1 = add_commit_with_files(&fx.path, &[], &[("f.txt", "base-left\n")], "p1");
let p2 = add_commit_with_files(&fx.path, &[], &[("f.txt", "base-right\n")], "p2");
let from = add_commit_with_files(&fx.path, &[&p1], &[("f.txt", "from\n")], "from");
let to = add_commit_with_files(&fx.path, &[&p2], &[("f.txt", "to\n")], "to");
// rebase_to_dest_parent merges (base = p1.tree, sides = p2.tree and from.tree) → conflict at f.txt
```

**Why `base_has_conflicts` and not a per-path list.** `Change.conflict` carries paths because a
commit's conflict set is what a conflict-resolution flow acts on. Here the conflicted tree is a
transient in-memory artefact of the rebase — a caller cannot resolve it, only distrust the change list
derived from it. A presence flag is what the ledger asks for and what the payload can honestly carry;
a per-path channel belongs with Epic 5's hunk payload, where the CLI's own signal (conflict markers in
the patch text) lands.

**What the limit witnesses can and cannot prove.** "Limit honoured in walk order" and "absent =
unchanged" are directly observable and are pinned at all three layers. "Does not compute the rest" is
a STRUCTURAL property of `take`-before-the-loop-body — no repo state makes a skipped entry's tree diff
observable, so no behavioural test can pin it. The `benches/show_limit.rs` timing line is the evidence
for it, and the structural placement is the guarantee; this is recorded rather than papered over with
a test that only appears to prove it.

## Verification

**Commands:**
- `cargo make codegen` -- run ONCE; expected: only the two flatc outputs change materially, plus
  doc-comment hunks in `zanshin_ffi.h` / `bindings.dart`.
- `git diff -- crates/zanshin-ffi/include packages/zanshin_core/lib/src/ffi/bindings.dart`
  -- expected: doc-comment hunks only; no `extern "C"` signature line moves.
- `cargo test -p zanshin-jj --test commit_views --test api_stability` -- expected: all pass,
  including the new limit rows and the conflicting-rebase row.
- `cargo test -p zanshin-ffi --test commit_views_ffi` and `cargo test -p zanshin-ffi --lib`
  -- expected: all pass.
- `cd packages/zanshin_core && dart test test/ffi/commit_views_test.dart test/worker/commit_views_test.dart`
  -- expected: all pass. (Requires a current cdylib — `cargo make test` builds it.)
- `cargo clippy --workspace --all-targets -- -D warnings` -- expected: clean, INCLUDING the new bench.
- `cargo bench -p zanshin-jj --bench show_limit` -- expected: exit 0, one timing line per
  configuration, no assertion on duration.
- Mutation probe: `git stash push -- crates/zanshin-jj/src crates/zanshin-ffi/src`, then re-run the
  suites above -- expected: the limit rows and the `base_has_conflicts` rows FAIL; `git stash pop`.
- `cargo make test` -- expected: exit 0. Run unpiped and synchronously, allow ~15 minutes. The single
  gate; it ends with the coverage ratchet.
- `git status --porcelain` -- expected: clean after the final commit.

## Auto Run Result

Status: done
Blocking condition: none

### Summary

Both Story 9.6 read-view must-haves are closed in place.

`ShowRequest` gains `limit`, modelled field-for-field on `EvologRequest.limit` at all six layers:
the presence pair `limit: uint; has_limit: bool` (flatc 25.12.19 rejects optional scalars for Dart,
and `limit = 0` is a meaningful empty result, so absence cannot be encoded as zero),
`Option<usize>` in Rust, and a Dart adapter that saturates at `0xFFFFFFFF` and refuses a negative
limit on both the calling side and in the adapter. Absence stays the CLI-parity default — `jj show`
has no `-n/--limit`, so the field is documented as a Zanshin-side addition everywhere it appears,
which is what keeps NFR-R-2 and FR-JJ-17 satisfied. The early stop is
`.take(limit.unwrap_or(usize::MAX))` on the COMMIT STREAM, before the loop body, so no skipped
entry pays a merged-parent tree diff, a per-parent copy-record stream or a `change_from_commit`.
Neither alternative in the originating ledger bullet's "or" was taken: no cursor, and no GUI-side
revset cap.

`InterdiffView` gains `base_has_conflicts: bool`, derived by `MergedTree::has_conflict()` — the
same `!…is_resolved()` predicate `Commit::has_conflict()` gives `Change.conflict` — so the two
payloads agree, and a plain `bool` keeps every public signature `jj_lib`-free. It reports the LEFT
side of the diff only, is true whether the 3-way merge or the fast path produced the conflicted
tree, describes the tree rather than the filtered result, and never turns the call into a refusal.
Because the payload stopped being a bare list, `interdiff` now returns a
`pub struct zanshin_jj::InterdiffView`, mirroring follow-up E's `FileSearch` pattern.

`crates/zanshin-jj/benches/show_limit.rs` is the perf witness: `harness = false`, printing
timings and asserting entry COUNTS but never wall-clock, outside `cargo make test` and outside
coverage while `clippy --all-targets` still compiles it.

### Files changed

- `schemas/envelope.fbs` — `ShowRequest.limit`/`has_limit`, `InterdiffView.base_has_conflicts`.
- `crates/zanshin-ffi/src/envelope_generated.rs`,
  `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` — flatc output.
- `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart` —
  cbindgen/ffigen output; doc comments plus three vtable-offset `#define`s (see the Spec Change
  Log). No `extern "C"` signature moved.
- `crates/zanshin-jj/src/commit_views.rs` — `show`'s `limit` and its stream `take`; the new
  `InterdiffView` struct; the flag's derivation.
- `crates/zanshin-jj/src/{lib,repo}.rs` — re-export, both facade signatures and their docs.
- `crates/zanshin-ffi/src/commit_views.rs` — the `ShowRequest` presence-pair reader, the
  `InterdiffView` writer, both `extern "C"` doc blocks, and the writer unit test walking both
  bool arms.
- `packages/zanshin_core/lib/src/ffi/commit_views.dart` — `zanshinShow`'s limit with the
  saturation and negative guards; the new `InterdiffView` model and decoder.
- `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` — `ShowCommand.limit`,
  the dispatch arm, both `show` seams, and the threaded interdiff return type.
- `crates/zanshin-jj/benches/show_limit.rs` + `crates/zanshin-jj/Cargo.toml` — the perf witness
  and its second `[[bench]]` block.
- Tests: `crates/zanshin-jj/tests/{commit_views,api_stability}.rs`,
  `crates/zanshin-ffi/tests/commit_views_ffi.rs`,
  `packages/zanshin_core/test/{ffi,worker}/commit_views_test.dart`.
- Bookkeeping: `deferred-work.md` plus `spec-9-6-read-views-show-evolog-interdiff.md`.

### Review findings

7 patches applied (0 high, 4 medium, 3 low) — see the Review Triage Log. 0 items deferred: this
was a closing run and the ledger ends it two bullets smaller than it started. 17 findings
rejected, three of them only after checking the source rather than the claim (the
`has_conflict()`-without-conflicting-paths premise is false for a `MergedTree::merge` result; Rust
never READS an `InterdiffView`; the Dart doc never claimed the `ArgumentError` is synchronous).
The remainder were house patterns the change deliberately mirrors, scope the intent itself fixed,
or artefacts of the review diff.

Follow-up review recommended: **true** — patched severities high 0, medium 4, low 3; score
`3 × 4 + 1 × 3 = 15`, which is ≥ 5.

### Verification

- `cargo make codegen` run once; re-running produced NO diff in any of the four generated outputs
  (md5-compared before and after).
- `git diff` on `zanshin_ffi.h` / `bindings.dart`: doc-comment hunks plus three vtable-offset
  `#define`s; no `extern "C"` signature line moved, and nothing in `crates/`, `packages/` or
  `app/` references those constants.
- `cargo make test` — **exit 0**, run unpiped and synchronously (579 s after the review patches;
  515 s before them). Coverage held at 99.22 % (8492/8559 lines over 46 files), no per-file
  regression, `coverage-baseline.txt` UNTOUCHED, `extern-coverage: OK`.
- `cargo bench -p zanshin-jj --bench show_limit` — exit 0. 1002 entries: ~451 ms unbounded against
  ~346 µs at limit 1, ~1.6 ms at 10 and ~15.8 ms at 100 — linear in the limit, which is the
  evidence for the early stop that no behavioural test can carry.
- Matrix audit: all eleven I/O rows have a named covering test, and each was observed running and
  passing in the gate log — the five `show`-limit rows across
  `tests/commit_views.rs::show_applies_the_limit_in_raw_revset_order_and_is_unbounded_when_absent`
  and `tests/commit_views_ffi.rs::show_distinguishes_an_absent_limit_from_an_explicit_zero`, the
  saturation and negative-limit rows in the two Dart suites, and the four interdiff rows across
  `interdiff_factors_out_the_parent_difference`,
  `interdiff_of_a_revision_against_itself_is_empty`,
  `interdiff_reports_a_conflicted_rebase_base_without_refusing` and its FFI twin.
- Mutation probe, run twice (before and after the review patches), each mutation reverted
  afterwards: dropping the `.take(…)` failed the two limit tests; hardcoding
  `base_has_conflicts = false` failed the two conflicted-base tests; restricting the flag to the
  non-fast-path arm failed the new fast-path test and only it; a zero-sentinel `ShowRequest`
  reader failed the extended FFI limit test and only it.

### Residual risks

- **The early stop itself is unwitnessed by any gate-run test.** `out.truncate(n)` after the loop
  would return byte-identical results and pass every behavioural test; only the bench's timings
  distinguish it, and the bench is not run by `cargo make test`. The one observable proxy — a
  revset whose later commits are unreadable, which succeeds under a limit and errors without one
  — needs a construction `Repo::open` cannot reach (it hardcodes `default_backend_factories()`,
  the same wall follow-up E hit), so it was documented rather than faked. `evolog` has carried the
  identical unwitnessed property since Story 9.6.
- **The perf witness measures `Repo::show`, not the envelope build.** The ledger framed the harm
  as "builds one FlatBuffers buffer", but a bench in `zanshin-jj` cannot reach `zanshin-ffi`
  (dependency direction), and the ~450 ms is dominated by the per-entry tree diffs the limit
  bounds anyway — the envelope is built from the already-bounded list.
- **`InterdiffView.base_has_conflicts`'s `true` arm never crosses the cdylib into Dart.** No verb
  reachable from Dart writes committed file content (D2), so the Dart `true` arm is
  decode-contract-only; the derivation is witnessed at the `zanshin-jj` and `zanshin-ffi` layers,
  and the `false` arm runs end-to-end. Same shape as follow-up E's `FileSearch.skipped` risk.
- **`Repo::interdiff` and the Dart `interdiff` seams are source-breaking signature changes.**
  Checked: neither `app/lib` nor `crates/zanshin-mcp` calls `show` or `interdiff`, so the break is
  contained to `packages/zanshin_core`.
- **The flag is a bare bool where `Change.conflict` carries paths.** Intent-mandated ("a presence
  flag"), and argued in the ledger: the conflicted tree is a transient in-memory artefact a caller
  cannot resolve, only distrust. A per-path channel belongs with Epic 5's hunk payload, where the
  CLI's own signal — conflict markers in the patch text — lands.
