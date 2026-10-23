---
title: 'Story 9.40 — No-change verbs write no operation: `WorkspaceCommandTransaction::finish`''s `has_changes()` gate'
type: 'bugfix'
created: '2026-10-23'
status: 'done'
baseline_revision: '23bb2ad7622526f275bda12fc9f95299502066bd'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      `undo_preserves_current_git_head_and_git_refs_not_targets` no longer proves that `undo` keeps the
      current `git_refs`: its operations change only Git refs, so its undo now restores an equal view and
      writes nothing.
    evidence: |-
      `crates/zanshin-jj/tests/it/op_log.rs` (`undo_preserves_current_git_head_and_git_refs_not_targets`):
      still green, but since the Story 9.40 gate (`mutate::finish_verb`) the undo takes the no-change arm,
      so the `restored_view` git_refs/git_head assertions hold trivially. `undo_no_change` (oracle) still
      pins that `git_head` is kept; nothing pins `git_refs`.
    location: >-
      crates/zanshin-jj/tests/it/op_log.rs undo_preserves_current_git_head_and_git_refs_not_targets
    severity: low
  - summary: >-
      Story 9.38's tracking text still says `mutate.rs::edit` always commits `edit commit <id>`; since
      Story 9.40 an edit of the current NON-discardable `@` writes nothing, only the discardable case
      (jj-lib's `MutableRepo::edit` abandons it) and the CLI's early return remain.
    evidence: |-
      sprint-status.yaml `9-38-edit-current-at-is-noop`, deferred-work.md (the `edit` bullet Story 9.38
      owns); witness `crates/zanshin-jj/tests/it/mutate.rs`
      `edit_of_the_current_non_discardable_wc_writes_no_operation`.
    location: >-
      _bmad-output/implementation-artifacts/sprint-status.yaml 9-38-edit-current-at-is-noop
    severity: low
---

<intent-contract>

## Intent

**Problem:** `mutate::finish_verb` ports the CLI's `WorkspaceCommandTransaction::finish` (`cli/src/cli_util.rs:2849-2865` @ v0.46.0) minus its first step — `if !tx.repo().has_changes() { "Nothing changed."; return }` — so a `git fetch` that brings nothing and an `undo` that restores an equal view write an operation the CLI never writes, warn `jj.identity_missing` with it, and make a later CLI `jj undo` undo the wrong operation. `describe` with the unchanged text additionally rewrites the commit (a new predecessor ⇒ `has_changes()`), where the CLI's `cmd_describe` filters unchanged commits out first (`describe.rs:194-201`). Open items I1 (fetch + describe) and I2 (undo) of deferred-work.md.

**Approach:** Put the gate into `finish_verb`: with no changes it commits nothing and returns a no-op `Finish` built from `tx.base_repo()` (the house no-op contract: `new_op_id` = pre-call head op id, `@` read, no finish facts, no checkout, no warnings) and says so in a new `Finish.committed` flag. Port describe's unchanged-description filter (compare after trailers, as the CLI). Audit every `finish_verb` caller against its CLI verb, remove the four `describe_no_change` ledger rows, add oracle witnesses for fetch and undo, and correct every doc that states the old behavior.

## Boundaries & Constraints

**Always:**
- CLI v0.46.0 is the spec (`git -C ../jj show v0.46.0:<path>`). Audit result (every `finish_verb` caller ends in `tx.finish` in the CLI, so the gate is correct for all): describe (`describe.rs:237`), new (`new.rs:284`), edit (`edit.rs:70`), abandon (`abandon.rs:191`), restore (`restore.rs:195`), absorb (`absorb.rs:190`), squash (`squash.rs:456`), split (`split.rs:418`), commit (`commit.rs:193`), git push (`git/push.rs:654`), git fetch (`git/fetch.rs:254`), undo (`undo.rs:208`); `finish_or_no_op_at`'s callers already gate. No caller is a raw-commit verb (`file track`/`untrack` do not go through `finish_verb`).
- The gate runs BEFORE the immutable-set resolution, the rebase, the Git lock and `finish_transaction` — as the CLI's order — so a no-change call neither resolves `immutable_heads()` nor warns about identity, nor exports refs / resets Git HEAD / checks out.
- No-op result = `no_op_result`'s shape: `new_op_id` = `tx.base_repo()`'s op id (the head the verb loaded, after the pre-verb snapshot), `working_copy_change_id` read from that repo, `finish` `None`, `new_change_ids` / `abandoned_change_ids` whatever the caller passes (empty for every no-change path).
- `describe`: compare `commit.description()` with the builder's description AFTER the trailers step (the CLI's filter sits after it); equal ⇒ no write, no rebase. Warnings collected before the comparison (template warnings) stay.
- `git_fetch` passes `finish.committed` to `project_import` instead of the hard-coded `true`.
- Tests per project-context.md (`tests/it/<module>.rs`, `pin_test_env()` first; env-changing rows inside the existing own-process test).

**Never:**
- No `edit` guard (Story 9.38: `edit` of the current `@` keeps its own early return to build; the gate already makes a NON-discardable current `@` write nothing, a discardable one still diverges — leave it).
- No change to the redundant own no-change checks of `restore` / `absorb` / `squash` / `finish_or_no_op_at` (they stay correct; surgical).
- No FFI wire change, no new error or warning code, no UI, no MCP change; never regenerate fixtures; no full gate in this run (loop gate rule).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| describe same text | `@`'s exact stored description | `Ok`, `new_op_id` = pre-call head; op log unchanged; no `jj.identity_missing` even with an empty identity | — |
| describe same text, bad alias | same + unresolvable `immutable_heads()` | `Ok`, nothing written (no resolution without changes) | — |
| describe changed text | other text | as today: one `describe commit <hex>` op | — |
| fetch nothing new | remote already fetched | `Ok`, `new_op_id` = pre-call head, op log unchanged, changed lists empty | — |
| undo to an equal view | colocated, Git HEAD made unborn (`git symbolic-ref HEAD refs/heads/nowhere`), so the precondition writes `import git head` (only `git_head` changes) | `undo` restores an equal view: `Ok`, the precondition's op stays the head, no undo op — as `jj undo` ("Nothing changed.") | — |
| oracle | `describe_no_change`, new `fetch_nothing_new`, new `undo_no_change` | no UNEXPECTED / CHANGED / STALE; the 4 `describe_no_change` ledger rows removed | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/mutate.rs:634-645` `Finish` -- add `committed: bool` (doc: `false` = the no-change gate wrote nothing; `repo` is then the pre-call repo). `:809` the only constructor in `finish_transaction` → `committed: true`. `:817-859` `finish_verb` -- gate first (`if !tx.repo().has_changes()` → no-op `Finish` from `tx.base_repo()`: `wc_commit` via `view().get_wc_commit_id(workspace.workspace_name())` + `store().get_commit`, `facts: FinishFacts::default()`, `checkout: None`), then the existing resolution/rebase unconditionally; rewrite its doc (no longer "still committed here"). `:867-883` `mutation_result` unchanged (base op id flows through `finish.repo`). `:932-961` `describe` -- filter: `if builder.description() != commit.description() { write; rebase_descendants }`. Docs: module doc `:11-14` ("Two verbs can finish WITHOUT writing" → every `tx.finish` verb via the gate), `finish_transaction` doc `:721-722` ("its callers skip the call when nothing changed" — now `finish_verb` does). `:1467-1522` `finish_or_no_op_at` doc mentions the gate (keep code).
- `crates/zanshin-jj/src/remotes.rs:585-593` -- `project_import(&stats, &finish.repo, finish.committed, mutation)`; drop the "always writes its operation" WHY.
- `crates/zanshin-jj/src/op_log.rs:122-212` `undo` -- doc: an equal restored view writes nothing ("Nothing changed."), result = pre-call head; code unchanged (it already ends in `finish_verb`).
- `crates/zanshin-jj/src/repo.rs:1148-1184` `Repo::describe` doc (unchanged text ⇒ no op), `:1299-1326` `Repo::undo` doc ("onto a freshly-committed op" → unless the view is equal), `:1410-1425` `Repo::git_fetch` doc (delete the "NOT CLI parity … tracked divergence" sentence → no op when nothing changed).
- `crates/zanshin-ffi/src/repo.rs:1432-1440` `zanshin_git_fetch` doc ("— also when nothing changed" → "— only when something changed; otherwise the pre-call head"); then `cargo make codegen` (header + `packages/zanshin_core/lib/src/ffi/bindings.dart:1255` copy it); check `zanshin_describe` / `zanshin_undo` docs in `crates/zanshin-ffi/src/` for op-always claims (rg "describe commit", "undo: restore").
- `packages/zanshin_core/lib/src/ffi/fetch.dart:154-158` -- "A fetch writes an operation even when nothing changed" → no operation when nothing changed (`newOpId` = pre-call head).
- `docs/ffi-abi.md:1610-1614` -- fetch paragraph: drop "also when nothing changed (the tracked 9.40 divergence)"; add the general rule where the shared `MutationResult` / no-op contract is described (rg "pre-call" in ffi-abi.md).
- Tests (zanshin-jj, `tests/it/`): `git_fetch_parity.rs:1043-1057` -- add `a_fetch_with_nothing_new_writes_no_operation` beside it (`Fx`, `head_op()`, `fx.fetch`); `config_identity.rs:336-338` -- after `describe(wc, "described anonymously")` add the same-text describe: no identity warning, op head unchanged (own-process test, empty identity active); `mutate.rs:88-133` (describe section, `tiny-3-commits`, `oracle_layout`) -- add `describe_with_the_unchanged_text_writes_no_operation` (`describe(commit1, "Commit 1")` → `new_op_id` == pre-call head == op-log head, description unchanged) and the unresolvable-`immutable_heads()` row (repo config `.jj/repo/config.toml`, as other tests in the module write it); undo equal-view row in `tests/it/op_log.rs` (colocated tempdir repo via `Repo::init`, a commit, `git symbolic-ref HEAD refs/heads/nowhere`, `repo.undo(false)` → `new_op_id` == op-log head after the call, head description `import git head`).
- Oracle `crates/zanshin-parity/tests/oracle/ledger.rs:146-177` -- delete the 4 `describe_no_change` rows; `main.rs:290-301` `a_ledgered_aspect_with_other_values_fails` → use `describe_gui_text` / `descriptions` (`should_panic(expected = "CHANGED descriptions")`); `scenarios.rs:~745-755` -- add `undo_no_change` (`setup: &[Step::Git(&["symbolic-ref", "HEAD", "refs/heads/nowhere"])]`, `repo.undo(false)` vs `["undo"]`); `git_scenarios.rs:946-1000` -- add `fetch_nothing_new` (`push(...)` with init bare + `remote add origin` + `git push -b b-mark`, `GitFetchArgs::default()` vs `["git","fetch"]`), fix the `:948-950` comment; `main.rs` `parity!` list + count `196` → `198`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/mutate.rs` -- `Finish.committed`; the gate in `finish_verb`; describe's filter; docs -- I1, I2.
- `crates/zanshin-jj/src/remotes.rs` -- `finish.committed` into `project_import` -- I1 (fetch).
- `crates/zanshin-jj/src/{op_log,repo}.rs` -- docs -- I1, I2.
- `crates/zanshin-jj/tests/it/{git_fetch_parity,config_identity,op_log}.rs` , `mutate.rs` -- matrix rows -- witnesses.
- `crates/zanshin-parity/tests/oracle/{ledger,main,scenarios,git_scenarios}.rs` -- ledger rows out, two scenarios in, ledger self-test re-pointed -- CLI-observable witness.
- `crates/zanshin-ffi/src/repo.rs` (+ codegen output), `packages/zanshin_core/lib/src/ffi/fetch.dart`, `docs/ffi-abi.md` -- docs.

**Acceptance Criteria:**
- Given any verb that finishes through `finish_verb`, when its transaction has no changes, then no operation is written, `MutationResult.new_op_id` is the pre-call head op id, and no finish warning (identity) is collected.
- Given the parity oracle, when it runs, then `describe_no_change`, `fetch_nothing_new` and `undo_no_change` match the stock CLI with no ledger entry, and the ledger has no STALE row.
- Given the docs (`Repo::describe` / `undo` / `git_fetch`, `zanshin_git_fetch` + generated bindings, `fetch.dart`, `ffi-abi.md`), when read, then none still says a no-change fetch/describe/undo writes an operation.

## Spec Change Log

## Review Triage Log

### 2026-10-23 — Review pass
- verdicts: 26 findings — high 0, medium 0, low 23, false 3, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind) the matrix row "describe same text, bad alias → `Ok`" contradicts the test `describe_with_the_unchanged_text_and_an_unresolvable_alias_refuses_like_the_cli` — the row is a planning error: `jj describe` resolves `immutable_heads()` in `check_rewritable_expr` (`describe.rs:102-104` @ v0.46.0) before the compare and refuses (verified with the stock jj 0.46.0, "Config error: Invalid `revset-aliases.immutable_heads()`"); the code and test follow the contract's governing rule "CLI v0.46.0 is the spec". The fix is an edit of this build's spec → rejected; recorded under Auto Run Result.
  - `[false]` `[reject]` (blind) "pre-call head" misleads when the pre-verb snapshot writes an op — the precondition's op IS a write of that call, so a caller comparing with an older id correctly sees one; "pre-call head" is the house term `no_op_result` / restore / absorb already use, and `finish_verb`'s doc defines it.
  - `[low]` `[patch]` (blind) `record_push` ignores `Finish.committed` — `record_push` returns `(op id, committed)`; `outcome.recorded = committed`; doc fixed.
  - `[low]` `[patch]` (blind) `fetch_nothing_new` duplicates the `PUSHED` steps — uses `PUSHED`.
  - `[low]` `[patch]` (blind) no test for "compare after the trailers" — `templates.rs` `an_unchanged_description_is_compared_after_the_trailers` (stored text gets the trailer with one op; the same text again writes none).
  - `[low]` `[patch]` (blind) `edit` changed behavior with no doc/test, 9.38's text stale — witness `mutate.rs` `edit_of_the_current_non_discardable_wc_writes_no_operation` + a `Repo::edit` doc sentence; 9.38's stale tracking text deferred (`deferred:`, mirrored).
  - `[low]` `[reject]` (blind) planning artifacts stale — sprint-status is updated with this commit; `epics.md:7344` and `docs/superpowers/plans/2026-10-08-parity-oracle.md` are Story 9.47's historical initial-ledger record; closing I1/I2 in deferred-work.md is the loop's ledger step; the Code Map is this build's spec.
  - `[low]` `[reject]` (blind) the ledger self-test now pins `describe_gui_text`, which a later story may remove — any ledger row can go; re-pointing is one line then; a synthetic entry would fail `ledger_names_only_known_scenarios_and_aspects`.
  - `[low]` `[patch]` (blind) undo/describe FFI and Dart docs do not mention the no-change result — one sentence each in `zanshin_describe` / `zanshin_undo` and `RepoHandle.describe` / `undo`; codegen re-run.
  - `[low]` `[reject]` (blind) no FFI / zanshin_core test of a no-change result — the FFI copies `MutationResult` unchanged (no FFI code changed); its pass-through is pinned by existing tests.
  - `[low]` `[patch]` (blind) `describe`'s doc cites `describe.rs:101` @ v0.44.0 — re-pointed to `describe.rs:102-104` @ v0.46.0.
  - `[low]` `[patch]` (edge) `the_unchanged_describe_never_warns` reads the identity warnings after `op_log`, whose `with_verb` replaces them — vacuous; the warnings are now taken right after `describe`.
  - `[low]` `[patch]` (edge) `record_push` sets `recorded = true` without a write — same root cause as the blind push row; fixed with it.
  - `[low]` `[patch]` (edge) `schemas/envelope.fbs` `GitFetchResult` doc still says a no-change fetch writes an op — reworded; codegen regenerated `envelope_generated.rs` / `envelope_zanshin.ffi_generated.dart` (doc only).
  - `[low]` `[patch]` (edge) `MutationResult::new_op_id` doc names only restore/absorb as no-op verbs — reworded to every `finish_verb` verb.
  - `[low]` `[patch]` (verification-gap) trailers-compare regression gap — same as the blind trailers row; fixed with it.
  - `[low]` `[patch]` (verification-gap) edit of the current non-discardable `@` unwitnessed — same as the blind edit row; fixed with it.
  - `[low]` `[patch]` (verification-gap, other) `record_push` reports a write that may not have happened — same as the blind push row; fixed with it.
  - `[low]` `[reject]` (intent) identity warning witnessed only for describe, not fetch/undo — the warning lives only in `finish_transaction`, which the gate skips for every caller; the describe row pins the shared arm.
  - `[low]` `[reject]` (intent) "a CLI `jj undo` afterwards undoes the wrong op" not exercised as an interleaving — the oracle's equal op counts for describe/fetch/undo are exactly that fact.
  - `[low]` `[reject]` (intent) no FFI/Dart test of the no-change result — same as the blind FFI row.
  - `[low]` `[reject]` (intent) the other gated callers (new, abandon, commit, push, squash, split, restore, absorb) get no per-verb no-change witness — epics.md 9.40 names describe/fetch/undo as the witnesses; restore/absorb/squash already had their own no-change tests; the rest always change the repo.
  - `[low]` `[patch]` (intent) edit side effect untested — same as the blind edit row; fixed with it.
  - `[low]` `[reject]` (intent) spec matrix contradicts its test — same as the first blind row.
  - `[false]` `[reject]` (intent) existing tests changed to fit — `remotes_write.rs` pinned the defect itself ("a fresh op even when nothing changed"); `network_cancel.rs` needed a real change to still exercise a finishing fetch.
  - `[false]` `[reject]` (intent) Auto Run Result / commit hashes missing — written at finalize.

## Design Notes

```rust
pub(crate) fn finish_verb(workspace, mut tx, description, ctx) -> Result<Finish, MutateError> {
    // `cli_util.rs:2851-2854` @ v0.46.0: "Nothing changed." — no operation.
    if !tx.repo().has_changes() {
        let repo = tx.base_repo().clone();
        let wc_commit = repo.view().get_wc_commit_id(workspace.workspace_name())
            .map(|id| repo.store().get_commit(id)).transpose().map_err(be)?;
        return Ok(Finish { repo, wc_commit, facts: FinishFacts::default(), checkout: None, committed: false });
    }
    let immutable = resolve_immutable(tx.base_repo().as_ref(), &ctx.immutable)?;
    // … rebase, lock, finish_transaction as today
}
```

`edit` side effect: a NON-discardable current `@` now writes nothing (as the CLI's "Already editing that commit."); a discardable one is still abandoned by jj-lib's `MutableRepo::edit` — Story 9.38's early return.

## Verification

**Commands (targeted; the story loop runs the full gate):**
- `cargo test -p zanshin-jj` -- expected: green.
- `cargo test -p zanshin-ffi` -- expected: green.
- `cargo test -p zanshin-parity --test oracle` -- expected: green, no UNEXPECTED / CHANGED / STALE.
- `cargo make codegen` -- expected: output committed; a re-run leaves the tree clean.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed .`, `cargo make --allow-private test-core` -- expected: green.

**Verification notes (run 2026-10-23, after the review patches; no `cargo make test` / `test-full` / `coverage` per the loop's gate rule):**
- `cargo fmt --all --check` — clean.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean.
- `cargo test -p zanshin-jj` — 311 lib + 1027 `it` passed (1 pre-existing ignored perf benchmark).
- `cargo test -p zanshin-ffi` — 196 lib + 310 `it` passed.
- `cargo test -p zanshin-parity --test oracle` — 212 passed (198 scenarios incl. `undo_no_change`, `fetch_nothing_new`; `describe_no_change` now matches with no ledger row), no UNEXPECTED / CHANGED / STALE.
- `cargo make codegen` — re-run leaves the tree unchanged; regenerated header, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart` committed (doc comments only).
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` clean, `dart format --set-exit-if-changed .` 0 changed, `cargo make --allow-private test-core` 935 passed.
- Matrix audit: describe same text — `mutate.rs` `describe_with_the_unchanged_text_writes_no_operation`, `config_identity.rs` `the_unchanged_describe_never_warns`, oracle `describe_no_change`; describe same text + bad alias — `describe_with_the_unchanged_text_and_an_unresolvable_alias_refuses_like_the_cli` asserts the CLI's refusal (the row's `Ok` contradicts `jj describe` @ v0.46.0, checked against the stock binary; the gate's skipped resolution is pinned by `git_fetch_parity.rs` `a_fetch_with_nothing_new_does_not_resolve_the_immutable_set`); describe changed text — `describe_happy_path_rewrites_description_and_records_op_log`; fetch nothing new — `git_fetch_parity.rs` `a_fetch_with_nothing_new_writes_no_operation`, `remotes_write.rs`, oracle `fetch_nothing_new`; undo equal view — `op_log.rs` `undo_restoring_an_equal_view_writes_no_operation`, oracle `undo_no_change`; oracle row — 212 passed.
- Coverage not measured (loop gate rule); the new no-change arm of `finish_verb`, the describe filter and push's `committed` flow are exercised by the tests above.

## Auto Run Result

Status: done

**Items:**
- **I1 — fixed (05484b83de8a5763894c97049de0b0d3ac1607bd).** `mutate::finish_verb` now carries `WorkspaceCommandTransaction::finish`'s `has_changes()` gate (`cli_util.rs:2849-2865` @ v0.46.0): a `git fetch` that brings nothing writes no operation, raises no `jj.identity_missing`, and reports the head it started from with empty change lists (`project_import` reads `finish.committed`). `describe` ports the CLI's unchanged-description filter (`describe.rs:194-201`, compared after the trailers), so the stored text rewrites nothing and the gate leaves the op log untouched. Witnessed in zanshin-jj and by the oracle (`describe_no_change` matches without its four former ledger rows; new `fetch_nothing_new`).
- **I2 — fixed (05484b83de8a5763894c97049de0b0d3ac1607bd).** Verified: Story 9.39's ported `undo` ends in `finish_verb`, so the gate covers it with no undo code change; an undo restoring an equal view (undoing a pure `git_head` import) writes nothing, as `jj undo` ("Nothing changed."). Witnessed in `op_log.rs` and by the oracle `undo_no_change`.

**Summary.** One gate in `finish_verb` (before the immutable-set resolution, rebase, Git lock, export and checkout — the CLI's order) with a `Finish.committed` flag, describe's filter, `git_fetch` and `git push` reading the flag. Audit: every `finish_verb` caller (describe, new, edit, abandon, restore, absorb, squash, split, commit, git push, git fetch, undo) ends in `tx.finish` in the CLI @ v0.46.0, so the gate is right for all; no raw-commit verb goes through it. Side effect: `edit` of the current non-discardable `@` now writes nothing, as the CLI; the discardable case stays Story 9.38's.

**Files changed (05484b8):**
- `crates/zanshin-jj/src/mutate.rs` — the gate, `Finish.committed`, describe's filter, docs.
- `crates/zanshin-jj/src/remotes.rs`, `push.rs` — `committed` into the fetch projection and push's `recorded`.
- `crates/zanshin-jj/src/{op_log,repo}.rs` — docs (`undo`, `describe`, `edit`, `git_fetch`).
- `crates/zanshin-jj/tests/it/{mutate,config_identity,git_fetch_parity,op_log,templates,remotes_write,network_cancel}.rs` — witnesses; two tests that pinned the old behavior updated.
- `crates/zanshin-parity/tests/oracle/{ledger,main,scenarios,git_scenarios}.rs` — ledger rows out, two scenarios in (198), ledger self-test re-pointed.
- `crates/zanshin-ffi/src/repo.rs`, `schemas/envelope.fbs` + generated header / Rust / Dart, `packages/zanshin_core/lib/src/{ffi/fetch,worker/handle}.dart`, `docs/ffi-abi.md` — docs.

**Review:** 26 findings (low 23, false 3). Patched (low): push `recorded` from `committed`; vacuous identity assertion; trailers-compare witness; edit witness + doc; `.fbs` / `MutationResult` / FFI + Dart describe/undo docs; `PUSHED` reuse; v0.46.0 citation. Deferred (mirrored in deferred-work.md "Surfaced in Story 9.40"): `undo_preserves_current_git_head_and_git_refs_not_targets` now passes trivially; Story 9.38's tracking text is stale. Rejected (reasons in the triage log): the matrix row "describe same text, bad alias → Ok" (contradicts `jj describe`, which resolves `immutable_heads()` in its rewritability check before the compare — the code follows the CLI and refuses; the row is a planning error of this spec), "pre-call head" wording, historical planning records, ledger self-test target, FFI/Dart round-trip tests, per-verb witnesses for always-changing verbs, CLI interleaving test.

**Follow-up review recommended:** false — patched counts high 0, medium 0, low 9 entries.

**Residual risks:** coverage ratchet not run (loop gate at the end); deferred-work.md I1/I2 are not struck yet (the loop's ledger step); `undo`'s git_refs-keeping is no longer pinned by a test (deferred).
