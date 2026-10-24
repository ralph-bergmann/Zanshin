---
title: 'Story 9.14 — `simplify-parents`'
type: 'feature'
created: '2026-10-24'
status: 'done'
baseline_revision: 'f6050d8d1b84cfb3a2c9a3840c200b15ab5367f9'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: [oversized]
deferred: []
---

<intent-contract>

## Intent

**Problem:** zanshin-jj has no `jj simplify-parents`. A GUI cannot drop a merge's redundant parent edges (a parent that is also an ancestor of another parent) without rebasing by hand; only `rebase --simplify-parents` exists, and only for commits a rebase moves.

**Approach:** Port `cmd_simplify_parents` (`cli/src/commands/simplify_parents.rs` @ v0.46.0) end to end (`.fbs` → zanshin-jj → `extern "C"` → committed codegen → `packages/zanshin_core`) on the house verb template (`with_verb`, `finish_verb`, `no_op_result`), reporting the CLI's status-line counts as typed facts, with parity-oracle scenarios.

## Boundaries & Constraints

**Always:**
- The CLI at v0.46.0 is the spec (`git -C ../jj show v0.46.0:cli/src/commands/simplify_parents.rs`; CLI tests `cli/tests/test_simplify_parents_command.rs`): order of checks, op description byte-identical, every on-disk effect.
- `Repo::simplify_parents(&SimplifyParentsOptions { source: Vec<ChangeId>, revisions: Vec<ChangeId> })` → `SimplifyParentsResult`. Change ids, not revset text (ADR-0003, like `parallelize`/`arrange`/`fix`).
- Target set: both lists empty → the `revsets.simplify-parents` setting (jj's default `reachable(@, mutable())`, reaching the stack through `CLI_DEFAULTS`), parsed "In revset expression" like `arrange`/`fix` (reuse `arrange::target_expression` with the key); otherwise `commits(source).descendants() ∪ commits(revisions)` — `source` ids resolved first, then `revisions` (the CLI's parse order); an empty list is `none()`.
- `guard_rewritable` over every commit of the evaluated set (the CLI's `check_rewritable_expr(&revs)`), before the transaction writes anything.
- One transaction; `transform_descendants(commit_ids, …)` with the CLI's callback verbatim: for a commit in the set with more than one (mapped) new parent, `simplify_ancestor_merge`; if `parents_changed()`, `reparent().write()`; count it as simplified (`edges += old − new`) when its parent count dropped, else as a reparented descendant.
- Nothing changed (`!tx.repo().has_changes()`) → NO operation, `no_op_result` (the CLI's "Nothing changed."). Otherwise `finish_verb` with `simplify {num_target_commits} commits` (`num_target_commits` = size of the evaluated target set, as the CLI's `num_orig_commits`).
- New `SimplifyParentsResult { mutation: MutationResult, num_target_commits: u32, num_simplified_commits: u32, num_removed_edges: u32, num_rebased_descendants: u32 }` (saturating, as `FixResult`) — the CLI's "Removed {edges} edges from {simplified} out of {n} commits." / "Rebased {n} descendant commits." as typed facts. `mutation.new_change_ids` / `abandoned_change_ids` empty.
- No clap-level refusal exists (`-s`/`-r` are optional and combinable) → `with_verb`, snapshot first. No new error or warning code.

**Never:** no status text in results; no revset DSL input; no drop-action/`change_actions` row; no MCP; no UI code; never regenerate fixtures; never run `jj` outside temp dirs; no full gate (`cargo make test` / `test-full` / `coverage`) — this run's gate rule.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| redundant parent via `-r` / via `-s` | the CLI test graph: `b` on `a`, `c` = `@` = merge(`a`, `b`); `revisions=[c, a, b]` or `source=[a]` | `c` keeps only `b` as parent; op `simplify 3 commits`; counts: 3 targets, 1 simplified, 1 edge, 0 rebased | — |
| multiple + descendants | the CLI test graph (`c`, `f` redundant merges with children); `revisions=[c, f]` | 2 edges from 2 of 2, 2 descendants rebased | — |
| default target set | no args, merges inside `reachable(@, mutable())` | simplified per the CLI test's counts | — |
| custom setting | `revsets.simplify-parents = "d::"` | only `d::` simplified | — |
| nothing to simplify | linear `-s @-`; diamond with no redundant edge; setting `none()` | NO operation, `new_op_id` = pre-call head, all counts 0 except `num_target_commits` | — |
| immutable | `revisions=[root]` or an immutable commit | refused, head unchanged | `jj.immutable` |
| bad id / bad setting | unknown change id; setting `"("` / non-string | refused, no op | `jj.change_not_found`; `jj.revset_parse_error` / `jj.config_error` |

</intent-contract>

## Code Map

CLI anchors @ v0.46.0: `cli/src/commands/simplify_parents.rs` (whole file, `cmd_simplify_parents`), `cli/src/config/revsets.toml` (`simplify-parents = "reachable(@, mutable())"`), `cli/tests/test_simplify_parents_command.rs` (graphs + expected counts for the scenarios). jj-lib 0.46.0 (`~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.46.0/src/`): `repo.rs:1494` `transform_descendants(roots, AsyncFnMut(CommitRewriter) -> BackendResult<()>)`; `rewrite.rs:299` `new_parents`, `:331` `parents_changed`, `:337` `simplify_ancestor_merge` (→ `IndexResult`, map to `BackendError::Other` inside the callback as the CLI), `:455` `reparent`.

**zanshin-jj**
- `src/parallelize.rs` — the closest template: `reload_head`, `start_repo_transaction`, `resolve_ordered`, `guard_rewritable(&tx, &ctx.templates(workspace), &ids)`, `pollster::block_on(tx.repo_mut().transform_descendants(…))`, `has_changes` → `no_op_result`, `finish_verb`, `mutation_result`.
- `src/arrange.rs:280` `target_expression(tx, workspace, ctx, revisions, key)` (default-setting path; reuse with `"revsets.simplify-parents"` and empty revisions), `:304` `commits_of`.
- `src/fix.rs:97` `FixResult` — result-with-counts pattern (u32 saturating); `src/rebase.rs:72` the `simplify_parents` rebase flag (unchanged).
- New `src/simplify_parents.rs` (options, result, verb; module doc with CLI anchors); `src/lib.rs` re-export (`SimplifyParentsOptions`, `SimplifyParentsResult`).
- `src/repo.rs:3409` `parallelize` / `:3449` `arrange` facade doc shape → new facade `simplify_parents` next to them, house doc block + `# Errors`.
- `src/config.rs:192-196` — doc lists `simplify-parents` among keys "no Zanshin verb consumes"; reword so `arrange`, `fix`, `simplify-parents` are named as consumed verbs reading their default from `CLI_DEFAULTS`.

**Wire + FFI**
- `schemas/envelope.fbs` — `RequestKind` :94-159 append `SimplifyParents` after `WorkspaceRemove`; doc count "the other 46 tables" (:85) +1; `SimplifyParentsRequest { kind, source: [string], revisions: [string] }` near `ArrangeRequest` :386 (doc: ABSENT/EMPTY both = the setting); `SimplifyParentsResult { mutation, num_target_commits: uint, num_simplified_commits: uint, num_removed_edges: uint, num_rebased_descendants: uint }` near `FixResult` :1918, appended to `union Payload`.
- `crates/zanshin-ffi/src/rebase.rs` — `read_simplify_parents_request` (template `read_arrange_request` :97, `change_ids` :30), `zanshin_simplify_parents` (template `zanshin_arrange` :269), module doc; reader unit tests.
- `crates/zanshin-ffi/src/envelope.rs:991` `ok_fix_result` → `ok_simplify_parents_result` + its unit test (template `:2103`).
- Generated only via `cargo make codegen`: `zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart`.
- `docs/ffi-abi.md` (102 → 103 :40/:554, FlatBuffers-request count 65 → 66 :293, export row near :615, section near :1830); `crates/zanshin-ffi/tests/it/ffi_abi_doc_sync.rs:37` → 103. `docs/rust-error-codes.md` — "Also emitted — Story 9.14" on the codes the extern emits.

**Dart (`packages/zanshin_core`)**
- `lib/src/ffi/rebase.dart:95` (`zanshinParallelize`, NUL guard) → `zanshinSimplifyParents`; `SimplifyParentsResult` model + `decodeSimplifyParentsResultEnvelope(Internal)` (template `lib/src/ffi/metaedit_duplicate_fix.dart:133-172` `FixResult`).
- `lib/src/worker/commands.dart:2203` `ParallelizeCommand` → `SimplifyParentsCommand`; `lib/src/worker/isolate.dart:1836-1849` worker method + dispatch `:3893`; `lib/src/worker/handle.dart:1148` → `RepoHandle.simplifyParents({List<String> source = const [], List<String> revisions = const []})`; barrel `lib/zanshin_core.dart`.

**Tests**
- `crates/zanshin-jj/tests/it/parallelize_arrange.rs` (fixture style) → new module `simplify_parents.rs` declared in `tests/it/main.rs`; `tests/it/api_stability.rs` (facade + public types, near :1316).
- `crates/zanshin-ffi/tests/it/rebase_ffi.rs` — round trip (success + refusal, zero handle, wrong kind, result counts crossing).
- `packages/zanshin_core/test/ffi/rebase_test.dart` (NUL guard :27, decoder), `test/worker/rebase_test.dart` (real cdylib round trip).
- Oracle `crates/zanshin-parity/tests/oracle/scenarios.rs` — `parallelize_outcome` :3357, `verb_argv` :3951, `MERGE_AND_X` :3397, `B_IMMUTABLE` :3624, setup `Step::Jj(&["config","set","--repo",…])`; register in `main.rs` `parity!` list (near :360).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/simplify_parents.rs` (new) + `lib.rs` -- options, result, verb per Always -- one module per verb, house style.
- `crates/zanshin-jj/src/repo.rs` -- facade `simplify_parents` (`with_verb`) with doc + `# Errors` -- public surface.
- `crates/zanshin-jj/src/config.rs` -- reword the stale `[revsets]` doc sentence -- it now names a consumed key.
- `schemas/envelope.fbs` + `cargo make codegen` -- kind, request, result, payload member; commit generated files -- wire.
- `crates/zanshin-ffi/src/{rebase,envelope}.rs` -- reader (absent vector = empty, wrong kind refused), extern with rustdoc (codes emitted), result builder, unit tests -- FFI.
- `packages/zanshin_core` lib -- builder with NUL guards, model + decoder, command, worker method, dispatch, `RepoHandle.simplifyParents`, barrel -- Dart bridge.
- `crates/zanshin-jj/tests/it/{simplify_parents,main,api_stability}.rs` -- every matrix row against jj-lib state (parents, counts, op description, head unchanged on refusal/no-op) -- verb tests.
- `crates/zanshin-ffi/tests/it/{rebase_ffi,ffi_abi_doc_sync}.rs` -- round trips, 103 exports -- FFI tests.
- `packages/zanshin_core/test/{ffi,worker}/rebase_test.dart` -- wire shape, NUL guard, decoder, real-cdylib success + refusal -- Dart tests.
- `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` -- scenarios: redundant parent via `-r` and via `-s`, multiple redundant parents with descendants, no args (default setting), custom `revsets.simplify-parents`, no change (linear, diamond), setting `none()`, immutable refused -- parity.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- per Code Map.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- flip `9-14-simplify-parents` to `done` with a sibling-style summary, bump `last_updated`; `deferred-work.md` -- `## Surfaced in Story 9.14 (bmad-build-auto, 2026-10-24)` mirroring every `deferred:` entry (only if any).

**Acceptance Criteria:**
- Given `RepoHandle.simplifyParents`, when a Dart caller reaches it, then the whole chain exists and `ffi_abi_doc_sync` passes with 103 exports.
- Given every new oracle scenario, when the oracle runs, then each matches the pinned CLI or diverges only through a ledgered entry with reason and reference.
- Given any refusal or no-op, when the op head is compared before and after, then it is unchanged beyond the pre-verb snapshot and `new_op_id` equals that head.
- Given a successful call, when its result is read, then the four counts equal the numbers the CLI prints in its status lines for the same graph.

## Spec Change Log

## Review Triage Log

### 2026-10-24 — Review pass
- verdicts: 23 findings — high 0, medium 0, low 14, false 9, maybe-false 0
- findings:
  - `[false]` `[reject]` (blind) empty `source`/`revisions` runs the default revset, undocumented — documented in `envelope.fbs` ("Both ABSENT or EMPTY = the `revsets.simplify-parents` setting") and `Repo::simplify_parents`; with change ids an empty list IS the flag not given, as for `fix`/`arrange`.
  - `[low]` `[patch]` (blind) no test passes both `source` and `revisions` — fixed: `simplify_parents_unions_source_and_revisions` + oracle `simplify_parents_source_and_revisions`.
  - `[low]` `[patch]` (blind) the CLI's `-s c` case on the two-merges graph not ported — fixed: `-s M` in the counts test (4,2,2,2) + oracle `simplify_parents_source_two_merges`.
  - `[low]` `[reject]` (blind) the oracle never compares the counts — needs status-line parsing in the oracle driver (new infrastructure); counts are asserted against the CLI tests' numbers in `tests/it/simplify_parents.rs`.
  - `[low]` `[patch]` (blind) `simplify_parents_diamond_noop` gave the two sides different input — fixed: the same five labels on both sides.
  - `[low]` `[patch]` (blind) no oracle scenario for the setting's parse error / diagnostic warning — fixed: `simplify_parents_bad_setting_refused`, `simplify_parents_deprecated_setting_warns` (non-string stays Rust-tested: the CLI's `config set` writes strings).
  - `[low]` `[patch]` (blind) FFI/Dart round trips never use the default path — fixed: FFI `simplify_parents_with_absent_vectors_uses_the_setting` (4,1,1,0).
  - `[low]` `[patch]` (blind) `num_rebased_descendants` docs read as disjoint from the targets — fixed: Rust, `.fbs`, Dart and ffi-abi docs say every rewritten commit that lost no edge, targets included.
  - `[low]` `[patch]` (blind) `jj.not_a_git_repo` missing from the extern's documented codes — fixed for this verb (rustdoc, header, ffi-abi row/section, Dart throws lists, registry).
  - `[low]` `[reject]` (blind) `resolve_ordered(Some(..)).unwrap_or_default()` dead unwrap — house pattern shared with `parallelize`/`arrange`; changing it means a new helper for no behaviour.
  - `[low]` `[patch]` (blind) no assert that `@`'s contents stay unchanged — fixed: `-s B` case asserts `@` is still M and its tree ids unchanged.
  - `[low]` `[patch]` (blind) half-asserted outcomes (Dart op description, `working_copy_change_id`) — fixed in the Dart worker test, the zanshin-jj `-s` case and the FFI no-op/success round trips.
  - `[false]` `[reject]` (blind) the spec was not in the reviewed diff — deliberate: the claims file goes only to the edge-case layer.
  - `[low]` `[patch]` (edge) `jj.not_a_git_repo` omitted from the extern/Dart error lists — same fix as the blind row.
  - `[low]` `[patch]` (verification-gap) union of `-s` and `-r` never exercised — same fix as the blind union row.
  - `[low]` `[patch]` (verification-gap) the "only targets are simplified" guard unpinned — fixed: `simplify_parents_leaves_a_redundant_merge_that_is_not_a_target` (N = merge(M, B) keeps both parents, counts (1,1,1,1)) + oracle `simplify_parents_non_target_redundant_descendant`.
  - `[low]` `[patch]` (verification-gap) `-s` resolved before `-r` unpinned — fixed: unknown ids in both lists report the `source` id (in the union test).
  - `[false]` `[reject]` (intent) change ids instead of revset text — ADR-0003 (revsets are terminal input language), as `fix`/`arrange`/`parallelize`; deliberate, not a divergence from the intent.
  - `[false]` `[reject]` (intent) status lines become typed counts — the epic's rule (status lines are typed facts), as `FixResult`.
  - `[false]` `[reject]` (intent) setting errors only tested in zanshin-jj — superseded by the two oracle scenarios added above.
  - `[false]` `[reject]` (intent) guard over the evaluated list vs the CLI's expression check — `check_rewritable_expr` evaluates the same expression against the immutable set; equal sets give the same refusal.
  - `[false]` `[reject]` (intent) coverage ratchet not run — this run's gate rule; the loop's final gate measures it.
  - `[false]` `[reject]` (intent) spec / deferred-work outside the patch — deliberate; `deferred: []`, so no deferred-work section is owed.

## Design Notes

- **Counts as a result table, not `MutationResult` alone.** House rule (epic context: status lines are typed facts), as `FixResult` reports `fixed <n> commits`. `num_target_commits` is reported even on a no-op (the GUI can say "nothing to simplify in N commits").
- **`num_old_heads` is the mapped parent count** (`rewriter.new_parents().len()` before simplifying), not the old commit's — port it exactly so counts match the CLI after a parent was itself rewritten.

## Verification

Gate rule for this run: no `cargo make test` / `test-full` / `coverage`; targeted checks only. Record each run and outcome here.

**Commands:**
- `cargo make codegen` -- generated files committed; a second run leaves the tree unchanged.
- `cargo test -p zanshin-jj --lib`; `cargo test -p zanshin-jj --test it -- simplify_parents:: parallelize_arrange:: rebase:: api_stability::` -- pass.
- `cargo test -p zanshin-ffi --lib`; `cargo test -p zanshin-ffi --test it -- rebase_ffi:: ffi_abi_doc_sync::` -- pass.
- `cargo test -p zanshin-parity --test oracle` -- pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`; `cargo fmt --all --check` -- clean.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed lib test`, `dart test test/ffi/rebase_test.dart test/worker/rebase_test.dart` (real cdylib; JJ_*, GIT_CONFIG_GLOBAL, XDG_CONFIG_HOME pinned as the `test-core` task does) -- pass/clean.

**Runs (2026-10-24, story run):**
- `cargo make codegen` -- regenerated `zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart`; a second run (and again after `cargo fmt` / `dart format`) left all four byte-identical (shasum check).
- `cargo test -p zanshin-jj --lib` -- 370/371 in the parallel run; the one failure is `cancel::tests::kill_group_signals_a_whole_group_and_never_ours` (leader exit status `None`, expected SIGTERM), pre-existing and unrelated (`cancel.rs` untouched): it passes alone, in the `cancel::` group, and the whole lib suite passes with `--test-threads=1` (371/371). New inline `simplify_parents::tests::count_saturates` passes.
- `cargo test -p zanshin-jj --test it -- simplify_parents:: parallelize_arrange:: rebase:: api_stability::` -- 70 passed.
- `cargo test -p zanshin-ffi --lib` -- 217 passed; `cargo test -p zanshin-ffi --test it -- rebase_ffi:: ffi_abi_doc_sync::` -- 27 passed (103 exports).
- `cargo test -p zanshin-parity --test oracle` -- 412 passed; `every_scenario_has_a_test` needed its count bumped 387 → 397 (the 10 new scenarios), then passed. All 10 simplify-parents scenarios match the pinned CLI, no ledger entry.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` -- no issues; `dart format --set-exit-if-changed lib test` -- clean; `dart test test/ffi/rebase_test.dart test/worker/rebase_test.dart` (env pinned as `test-core`) -- 23 passed.

**Runs (2026-10-24, review fix-up):** union, `-s` on the two-merges graph, non-target redundant descendant, `@`'s working-copy id + unchanged tree, unknown id in both lists (reports the `source` id); oracle diamond labels aligned + 5 new scenarios; FFI default-path round trip + no-op `working_copy_change_id`; Dart op-description assert; `num_rebased_descendants` docs (targets included); `jj.not_a_git_repo` on the extern, ffi-abi row/section, Dart docs, registry.
- `cargo test -p zanshin-jj --test it -- simplify_parents::` -- 8 passed (before and after `cargo fmt`).
- `cargo make codegen` -- header/bindings regenerated (rustdoc + fbs doc); a second run left all four generated files byte-identical, still identical after `cargo fmt`.
- `cargo test -p zanshin-ffi --test it -- rebase_ffi:: ffi_abi_doc_sync::` -- 28 passed (first run before codegen failed `every_index_row_names_exactly_the_error_codes_its_rustdoc_bullets_do` as expected: stale header).
- `cargo test -p zanshin-parity --test oracle -- simplify_parents every_scenario_has_a_test ledger_names` -- 18 passed (15 simplify-parents scenarios + `rebase_simplify_parents` + 2 bookkeeping; scenario count 397 → 402), all match the pinned CLI, no ledger entry.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- first run flagged `too_many_lines` on `simplify_parents_scenarios`; split into two functions, then clean. `cargo fmt --all --check` -- clean.
- `packages/zanshin_core`: `dart format --set-exit-if-changed lib test` -- clean; `dart analyze --fatal-infos --fatal-warnings` -- no issues; `dart test test/ffi/rebase_test.dart test/worker/rebase_test.dart` (env pinned) -- 23 passed.

**Runs (2026-10-24, final tree, orchestrator):**
- `cargo fmt --all --check` -- clean; `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean.
- `cargo test -p zanshin-jj --lib` -- 371 passed (the flaky `cancel::` test passed this time).
- `cargo test -p zanshin-jj --test it -- simplify_parents:: api_stability:: parallelize_arrange:: rebase::` -- 72 passed.
- `cargo test -p zanshin-ffi --lib` -- 217 passed; `cargo test -p zanshin-ffi --test it -- rebase_ffi:: ffi_abi_doc_sync::` -- 28 passed.
- `cargo make codegen` twice -- exit 0, tree unchanged between runs.
- `cargo test -p zanshin-parity --test oracle` -- 418 passed (full run).
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` -- no issues; `dart format --set-exit-if-changed .` -- 0 changed; `dart test test/ffi/rebase_test.dart test/worker/rebase_test.dart` (env pinned as `test-core`) -- 23 passed.
- Not run (gate rule): `cargo make test`, `test-full`, `coverage`.

## Auto Run Result

Status: done

**Summary.** `jj simplify-parents` is ported from `cmd_simplify_parents` @ v0.46.0 end to end (`.fbs` → zanshin-jj `Repo::simplify_parents` → `zanshin_simplify_parents` → `RepoHandle.simplifyParents`; 103 exports). Targets: `source` with descendants ∪ `revisions` (change ids, `-s` resolved first), or — both empty — the `revsets.simplify-parents` setting parsed "In revset expression". The whole set is checked rewritable, one `transform_descendants` runs the CLI's callback verbatim, "Nothing changed." writes no operation, otherwise `simplify <n> commits`. New `SimplifyParentsResult { mutation, num_target_commits, num_simplified_commits, num_removed_edges, num_rebased_descendants }` carries the CLI's status lines as typed facts. No new error or warning code.

**Files changed.**
- `crates/zanshin-jj/src/simplify_parents.rs` (new) — options, result, verb; `lib.rs` re-export; `repo.rs` facade; `config.rs` stale `[revsets]` doc reworded.
- `schemas/envelope.fbs` + generated files — `RequestKind::SimplifyParents`, `SimplifyParentsRequest`, `SimplifyParentsResult` payload.
- `crates/zanshin-ffi/src/{rebase,envelope}.rs` — reader, extern, result builder, unit tests.
- `packages/zanshin_core/lib/src/{ffi/rebase,worker/commands,worker/isolate,worker/handle}.dart`, barrel — adapter, model/decoder, command, worker method, `RepoHandle.simplifyParents`.
- Tests: `crates/zanshin-jj/tests/it/simplify_parents.rs` (new), `main.rs`, `api_stability.rs`; `crates/zanshin-ffi/tests/it/{rebase_ffi,ffi_abi_doc_sync}.rs`; Dart `test/{ffi,worker}/rebase_test.dart`; oracle `scenarios.rs` / `main.rs` (15 scenarios).
- Docs: `docs/ffi-abi.md`, `docs/rust-error-codes.md`. Ledger: this spec, `sprint-status.yaml` (9-14 done).

**Review findings.** 23 findings (low 14, false 9). Patched 12 low entries (tests, oracle scenarios, docs; see the triage log). Rejected 2 low (oracle count comparison needs new driver infrastructure; the `resolve_ordered` unwrap is the house pattern) and 9 false. Nothing deferred, so no deferred-work.md section.

**Follow-up review recommendation: false.** Patched at entry verdict: high 0, medium 0, low 12.

**Residual risks.** Coverage ratchet not run (gate rule): `simplify_parents.rs` is a new file that must reach the 80 % floor at the loop's final gate; the `simplify_ancestor_merge` index-error mapping arm has no test (jj-lib index failure only). The oracle compares repo state, not the CLI's status text — count parity rests on the zanshin-jj tests mirroring the CLI tests' graphs. `cancel::tests::kill_group_signals_a_whole_group_and_never_ours` failed once under the parallel lib run (pre-existing, untouched file), passed on the final run.
