---
title: 'Story 9.31 matrix-rows closing run: a location resolves its ids before the immutable set'
type: 'bugfix'
created: '2026-10-21'
status: 'done'
baseline_revision: '771b7902b8d4f1743f83164af82a7589bc15685d'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      A verb's finish does not resolve the immutable set the way the CLI's `tx.finish` does, so verbs without an up-front rewritability guard succeed (and their drop/card rows read Available) under an unresolvable `immutable_heads()` alias where the CLI refuses `Config error: Invalid revset-aliases.immutable_heads()` and writes no operation.
    evidence: |-
      CLI v0.46.0: `WorkspaceCommandTransaction::finish` (cli/src/cli_util.rs:2849-2858) calls `rebase_mutable_descendants` (:2986-3002), which resolves the set with `?` for every write that has changes. Reproduced with the pinned `target/debug/jj`: `jj new -A @` on a leaf and `jj bookmark create yy -r @` both refuse with the Config error, no op. Zanshin: `finish_transaction` / `finish_verb` (crates/zanshin-jj/src/mutate.rs:669-775) resolve the set only in `wc_is_immutable`, which skips on failure; `new_change` (mutate.rs:1018) uses plain `rebase_descendants()`. With `plan_new`'s up-front resolution removed (this run's reverted attempt), the oracle's `new -A <leaf>` returned Ok and wrote 1 op while the CLI refused — so the finish path never refuses. `crates/zanshin-jj/tests/it/new_insert.rs` `only_insert_resolves_the_immutable_set` pins the divergent plain-`new` success. Only `commit.rs:204`, `remotes.rs:568`, `git.rs:337` (and `creation.rs:479`) resolve the set against the base repo; `squash_split.rs:714` and `workspace_add.rs:218` call plain `rebase_descendants()`.
    location: >-
      crates/zanshin-jj/src/mutate.rs:669 (finish_transaction / finish_verb); every finish_verb / finish_or_no_op caller without its own resolution — e.g. new with positional parents, the bookmark verbs, duplicate/revert at -o or without a location, undo/op verbs (op_log.rs), git export and remote remove/rename (git.rs), workspace add — plus their drop/card rows
    severity: low
---

<intent-contract>

## Intent

**Problem:** (Item 1 of the matrix-rows run's ledger.) `plan_revert`, `plan_rebase_branch`, `plan_duplicate` and `plan_new` resolve the `immutable_heads()` set before the `-A`/`-B` location ids and whether or not the location has children. The CLI's `compute_commit_location` (`cli/src/cli_util.rs:3644-3720` @ v0.46.0) resolves `-o`/`-A`/`-B` first and calls `check_rewritable` — the only place it resolves the set — only for non-empty `new_child_ids`. So with an unresolvable alias, `-A` on a leaf refuses `jj.config_error` where the CLI succeeds, and an unknown location id reads `jj.config_error` where the CLI reports the unknown revision. `new -A` / `-B` is the shipped `new_change` verb (Story 9.48).

**Approach:** One shared helper: `compute_commit_location` (and its wrapper `resolve_commit_location`) in `op_support.rs` take the UNRESOLVED immutable expression and resolve it inside, only when `new_child_ids` is non-empty, right before the rewritability check — the CLI's order. The four plans drop their own up-front resolution; the callers that already resolved for their target guard (`rebase -r`/`-s`, `split`) pass the expression too (the CLI's `check_rewritable` also resolves on every call).

## Boundaries & Constraints

**Always:** CLI v0.46.0 order inside the location: resolve `onto`, `-A`, `-B` ids (each argument-ordered, dedup) → children → (children non-empty) resolve the immutable set + rewritability → loop check → empty-parents refusal. Target guards that run before the location in the CLI (`rebase -r`/`-s` `check_rewritable(targets)`, `rebase -b`'s roots check after the location, `split`'s target guard) keep their place and still resolve the set (Config refusal) as the CLI does. Every verb's observable behaviour equals the CLI's; the parity oracle stays green with no new ledger entry.

**Never:** No change to refusal codes, texts, row lists or any FFI/schema surface. No new public API. No caching of the resolved set across calls. Nothing outside the item (other deferred items untouched).

## I/O & Edge-Case Matrix

Alias `immutable_heads()` = `no-such-bookmark` (parses, does not resolve). Fixture: `drop_actions.rs`' `base()` — `root → A → B → C`, `D` a second child of `A` (`@`); C and D are leaves.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| `new -A` leaf (verb) | `new_change(&[], &[C], &[])` | new commit on C, ok | none |
| `new -A` unknown id (verb) | `new_change(&[], &[UNKNOWN], &[])` | refused | `ChangeNotFound{UNKNOWN}` (was `Config`) |
| `new -B` leaf (change_actions) | `change_actions(C).new_insert_before` (child C) | Refused | `Config` (children non-empty) |
| `new -A` leaf (change_actions) | `change_actions(C).new_insert_after` | Available | none |
| revert `-A` leaf (drop row) | source D, `after(&[C])` | Revert Available; RebaseRevisions Refused `Config` (target guard first, as CLI) | — |
| revert `-A` with child | source D, `after(&[B])` (child C) | Revert Refused `Config` | — |
| revert `-A` unknown | source D, `after(&[UNKNOWN])` | Revert Refused `ChangeNotFound{UNKNOWN}` | — |
| duplicate / rebase `-b` `-A` (inline, no drop row reaches them) | unresolvable expr; `-A` on a leaf / unknown id | duplicate Ok / `ChangeNotFound`; `-b` leaf `Config` (roots guard after the location, as CLI), unknown `ChangeNotFound` | — |

</intent-contract>

## Code Map

> Superseded: Code Map, Tasks & Acceptance, Design Notes and the Verification commands describe the attempted fix, which was reverted (item 1 rejected — see Spec Change Log and Auto Run Result).

- `crates/zanshin-jj/src/op_support.rs` -- `compute_commit_location` (:228, `immutable: &Arc<ResolvedRevsetExpression>` → `&Arc<UserRevsetExpression>`; resolve with `resolve_immutable(repo, immutable)?` inside the `!new_child_ids.is_empty()` block, :291); `resolve_commit_location` (:171, same param change); `resolve_immutable` (:85, `cfg` → `MutateError::Config`); unit tests from :880 (`immutable_at_head` returns the resolved set; `compute_commit_location` tests at :997-1199 need the user expression).
- `crates/zanshin-jj/src/revert.rs` -- `plan_revert` (:51-79): drop the `if location.inserts()` resolution; doc says ids first, set only for children. Inline `mod tests` at :83.
- `crates/zanshin-jj/src/duplicate.rs` -- `plan_duplicate` (:47-79): same; no inline tests module yet.
- `crates/zanshin-jj/src/rebase.rs` -- `plan_rebase_branch` (:118-149) drop the inserts resolution; `plan_rebase_revisions` (:51) / `plan_rebase_source` (:85) keep `guard_rewritable(...)?;` and pass `immutable`; inline test `plan_rebase_branch_with_an_insert_location_checks_the_children` (:290).
- `crates/zanshin-jj/src/mutate.rs` -- `plan_new` (:928-971): drop `resolve_immutable(base, …)`, pass `immutable`; `guard_rewritable` (:534); `resolve_immutable` import may become unused there (still used by `wc_is_immutable` :630 and :541).
- `crates/zanshin-jj/src/squash_split.rs` -- `prepare_split` (:584-630): passes the guard's resolved set to `compute_commit_location`; pass `&ctx.immutable` instead (local `immutable` then unused).
- `crates/zanshin-jj/src/drop_actions.rs` -- callers of all four plans (:286, :316, :374, :414); unchanged.
- `crates/zanshin-jj/tests/it/drop_actions.rs` -- `base()` (:91), `after()` (:149), `before()`, `row()`/`available()`, `UNKNOWN` (:29); new matrix tests go here.
- `crates/zanshin-parity/tests/oracle/scenarios.rs` -- Story 9.48 `new -A` scenarios (:1622-1718, `new_insert_after_immutable_child` config pattern); `main.rs` `parity!` list.
- Read-only: `git -C ../jj show v0.46.0:cli/src/cli_util.rs` :2035-2074 (`check_rewritable` resolves every call), :3644-3730; `:cli/src/commands/rebase.rs` :430-560 (target guard order per form).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/op_support.rs` -- change both location fns to take `&Arc<UserRevsetExpression>`, resolve lazily for non-empty children; update docs (Errors: `Config` only when children exist); adapt unit tests (a helper returning the user expression) and add one inline test: an unresolvable expression with `-A` on a leaf is Ok, with children refuses `Config`.
- `crates/zanshin-jj/src/revert.rs`, `duplicate.rs`, `rebase.rs`, `mutate.rs`, `squash_split.rs` -- drop the up-front/guard-result plumbing as in the Code Map; fix each plan's doc (`Config` arm).
- `crates/zanshin-jj/src/duplicate.rs`, `rebase.rs` -- inline tests for the matrix's last row (unresolvable expr: `-A` leaf, unknown `-A` id).
- `crates/zanshin-jj/tests/it/drop_actions.rs` -- one test per matrix row group (verb `new_change`, `change_actions`, drop rows) with the unresolvable alias.
- `crates/zanshin-parity/tests/oracle/scenarios.rs` + `main.rs` -- scenario `new_insert_after_leaf_unresolvable_immutable` (`jj config set --repo revset-aliases.'immutable_heads()' no-such-bookmark`, then `new -A C`), no ledger entry.

**Acceptance Criteria:**
- Given an unresolvable `immutable_heads()` alias, when `new_change` inserts after a leaf, then it succeeds exactly as `jj new -A` does (oracle scenario green, no ledger entry).
- Given any verb whose target guard precedes its location in the CLI, when it runs, then its refusals and their order are unchanged (existing `zanshin-jj` suites and the full oracle stay green).

## Spec Change Log

### 2026-10-21 — implementation stopped: the item's premise is false
- Trigger: the implementation subagent's oracle scenario `new_insert_after_leaf_unresolvable_immutable` failed (Zanshin Ok + 1 op, CLI refused, 0 ops, 7 short-prefixes warnings), confirmed by hand with the pinned CLI.
- Finding: the CLI resolves the immutable set again in `tx.finish` → `rebase_mutable_descendants` (`cli_util.rs:2849-2858`, `:2986-3002` @ v0.46.0) with `?`, so NO CLI write with changes succeeds under an unresolvable alias. The item's "the CLI would not refuse" holds only inside `compute_commit_location`; end to end the CLI refuses `Config` for `-A` on a leaf, and for an unknown id — positional, `-A` or `-B`, all three run by hand — it refuses `Failed to resolve short-prefixes disambiguation revset` (the default `revsets.short-prefixes` uses `immutable_heads()`), not the unknown revision; Zanshin's typed-id verbs have no short-prefix resolution, and both sides refuse with no operation.
- Amended: nothing inside `<intent-contract>` (read-only); the item is rejected per the dispatch ("reject it with the reason if it is false"). The attempted code change (lazy resolution in `compute_commit_location`, four plans, tests, oracle scenario) was reverted: it made the shipped `new_change` succeed where `jj new -A` refuses — a parity regression. The matrix rows that predict success are falsified by the CLI and stay unimplemented.
- Known-bad state avoided: Zanshin `new -A <leaf>` writing an operation the CLI refuses; drop/card rows reporting Available for a verb the CLI refuses.
- KEEP: if the finish-path gap (frontmatter `deferred`) is ever fixed, the location reorder becomes behaviour-neutral and may then follow the CLI literally.

## Review Triage Log

### 2026-10-21 — Review pass
- verdicts: 21 findings — high 0, medium 0, low 14, false 7, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind) the rejected ledger item stays open in deferred-work.md and its follow-up still asks for the reorder — the story loop closes handed-over ledger items in its own `chore(ledger)` commits (771b790, 4e40594); this run's outcome is recorded under Auto Run Result for it.
  - `[low]` `[patch]` (blind) `squash_split.rs:713` / `workspace_add.rs:217` wrongly cited as resolving the set — verified (plain `rebase_descendants()` at :714 / :218); citations corrected to `commit.rs:204`, `remotes.rs:568`, `git.rs:337`, `creation.rs:479` in the frontmatter and deferred-work.md.
  - `[low]` `[patch]` (blind) the new deferral's affected list is hand-picked and incomplete (workspace add, git remote remove/rename) — reworded to "every unguarded `finish_verb`/`finish_or_no_op` caller" with an audit follow-up and the missed verbs named.
  - `[false]` `[reject]` (blind) the short-prefixes failure and the 7 CLI warnings are an unrecorded parity gap — the warnings come from rendering commit summaries (terminal UX); for an unknown id both sides refuse with no operation, and Zanshin's typed ids have no short-prefix resolution.
  - `[low]` `[patch]` (blind) the unknown-location-id evidence came from a positional parent — ran `jj new -A <unknown>` and `-B <unknown>` with the pinned CLI (same short-prefixes refusal); Change Log reworded.
  - `[low]` `[patch]` (blind) no witness pins the CLI-matching refusal of `new -A <leaf>` — added `new_insert.rs` `insert_after_a_leaf_refuses_an_unresolvable_alias_like_the_cli` (70c98bea).
  - `[low]` `[patch]` (blind) the spec body still reads as the plan for the rejected fix — a "Superseded" note heads the Code Map; `<intent-contract>` stays read-only.
  - `[false]` `[reject]` (blind) the deferral's oracle follow-up hides a blocker — it states the scenario needs a ledger entry for the CLI's warnings, which is the dependency.
  - `[low]` `[patch]` (edge) affected list misses undo/op verbs, git export/remote verbs, workspace add, location-less duplicate — same root cause and fix as the blind affected-list row.
  - `[low]` `[patch]` (edge) the follow-up names `squash_split.rs:713` as a model — corrected with the citation row.
  - `[low]` `[patch]` (edge) spec evidence cites `squash_split.rs:713` / `workspace_add.rs:217` — corrected with the citation row.
  - `[low]` `[reject]` (edge) the intent and matrix still say the CLI succeeds — the fix edits this build's spec intent (read-only); the rejection is recorded in the Change Log, the Superseded note and the Auto Run Result.
  - `[low]` `[reject]` (edge) AC1 is CLI-falsified while the spec reads open — the fix edits this build's spec; status is `done` with item 1 rejected.
  - `[false]` `[reject]` (intent) the deciding evidence is end-to-end, not the plan layer the follow-up names — the intent's Note requires verb-level CLI parity and the oracle.
  - `[low]` `[reject]` (intent) plan-only rows get no final-state check — rows are unchanged code covered by the existing `drop_actions` suite; their divergence from the CLI verb is part of the deferred finding.
  - `[low]` `[patch]` (intent) whether Zanshin's refusal matches the CLI's short-prefixes failure is not stated — Change Log now says both refuse with no operation.
  - `[false]` `[reject]` (intent) `## Auto Run Result` missing — written at finalize, below.
  - `[low]` `[patch]` (intent) stale spec body — same as the blind Superseded row.
  - `[false]` `[reject]` (intent) the new finding is deferred though it needs no product decision — the dispatch limits this run to its item list ("nothing else") and prescribes mirroring new findings; the product-decision clause governs the listed items.
  - `[false]` `[reject]` (intent) spec and deferred-work.md might not share a commit — they are committed together.
  - `[false]` `[reject]` (intent) no checks on the final state — the final tree changes no verb; the targeted checks for the added test are recorded.

## Design Notes

Passing the unresolved expression and resolving inside `compute_commit_location` mirrors the CLI literally (`check_rewritable` → `resolve_immutable_expression` per call), so the double resolution on `rebase -r`/`-s`/`split` with children is the CLI's own cost, not a regression; no enum/closure abstraction is needed.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib op_support:: revert:: duplicate:: rebase::` -- expected: pass
- `cargo test -p zanshin-jj --test it drop_actions::` / `new_insert` / `rebase` / `squash_split::` -- expected: pass
- `cargo test -p zanshin-jj` -- expected: pass
- `cargo test -p zanshin-parity --test oracle` -- expected: pass, new scenario included
- `cargo clippy -p zanshin-jj -p zanshin-parity --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean

**Verification notes (this run; gate rule: no `cargo make test`):**
- Attempted fix (reverted): `cargo test -p zanshin-jj --lib op_support:: revert:: duplicate:: rebase::` — 47/47 pass; `cargo test -p zanshin-jj --test it drop_actions::` — 37/37 pass; `cargo test -p zanshin-parity --test oracle new_insert_after_leaf_unresolvable_immutable` — FAIL (zanshin Ok + 1 op, CLI refused + 0 ops, 7 CLI warnings): the CLI evidence that rejects the item.
- Pinned CLI by hand (`target/debug/jj`, scratch repo, alias `no-such-bookmark`): `jj new -A @` (leaf) → `Config error: Invalid revset-aliases.immutable_heads()`, no op; `jj bookmark create yy -r @` → same Config error, no op; `jj new <unknown>` → `Failed to resolve short-prefixes disambiguation revset`.
- Final tree: no production-code change; one witness test added at review (`crates/zanshin-jj/tests/it/new_insert.rs` `insert_after_a_leaf_refuses_an_unresolvable_alias_like_the_cli`). `cargo test -p zanshin-jj --test it new_insert::` — 21/21 pass; `cargo clippy -p zanshin-jj --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean. No oracle run on the final state: no jj verb changed (the oracle scenario was part of the reverted attempt).

## Auto Run Result

Status: done

- **Item 1 — rejected (false premise).** The CLI does refuse: `WorkspaceCommandTransaction::finish` → `rebase_mutable_descendants` (`cli_util.rs:2849-2858`, `:2986-3002` @ v0.46.0) resolves `immutable_heads()` with `?` for every write with changes, so `jj new -A <leaf>` (and `revert`/`duplicate`/`rebase` at a childless location) refuses `Config error: Invalid revset-aliases.immutable_heads()` with no operation — what Zanshin's up-front resolution already answers. An unknown location id makes the CLI refuse `Failed to resolve short-prefixes disambiguation revset`, not the unknown revision. The reorder was implemented, failed the parity oracle (Zanshin Ok + 1 op, CLI refused), and was reverted; applying it would regress the shipped `new_change`.
- **Commits:** 70c98beab71b37e559cd75d169b0f5b3da38d33f — witness test `crates/zanshin-jj/tests/it/new_insert.rs` `insert_after_a_leaf_refuses_an_unresolvable_alias_like_the_cli` (pins the CLI-matching refusal); plus the commit carrying this spec and `deferred-work.md`.
- **Files changed:** `crates/zanshin-jj/tests/it/new_insert.rs` (one witness test); `_bmad-output/implementation-artifacts/deferred-work.md` (new section, one finding); this spec.
- **Deferred (1 new, low, mirrored in deferred-work.md):** verbs without an up-front rewritability guard (plain `new`, bookmark verbs, `duplicate`/`revert` at `-o`, undo/op, git export/remote, `workspace add`) succeed under an unresolvable alias where the CLI's `tx.finish` refuses — Zanshin's shared finish does not resolve the set against the base repo.
- **Review:** 21 findings — 10 patch rows (low; citations, affected list, `-A`/`-B` CLI evidence, witness test, Superseded note, error-class wording), 4 low rejected and 7 false rejected, each with its reason in the Review Triage Log. Patched counts by verdict: high 0, medium 0, low 10.
- **Follow-up review recommended:** false (no high or medium patched).
- **Verification:** see Verification notes (attempt: unit 47/47, drop_actions 37/37, oracle scenario FAIL = the rejecting evidence; final: `new_insert::` 21/21, clippy clean, fmt clean; pinned CLI by hand).
- **Residual risk:** the ledger item at deferred-work.md "Surfaced in the Story 9.31 matrix-rows run" stays open until the loop closes it as rejected; its follow-up text must not be executed.
