---
title: 'Story 9.18 follow-up: new parses its template before resolving the immutable set'
type: 'bugfix'
created: '2026-10-25'
status: 'done'
baseline_revision: 'f2f9b21e7d4b9dc55b213199c60198732226f85a'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: []
deferred:
  - summary: >-
      A `new` merge with the root commit and a broken `templates.new_description` refuses with the Git backend's root-merge text where the CLI names the template.
    evidence: |-
      `plan_new` calls `refuse_git_root_merge` up front (crates/zanshin-jj/src/mutate.rs:1186, :1195 after this run; Story 9.31); `cmd_new` @ v0.46.0 parses the template (cli/src/commands/new.rs:217-221) and only then writes the hidden/real commit, where the backend refuses. Verified by hand with the pinned `target/debug/jj`: `new @ 'root()'` with template `"x" ++` → `Failed to parse template: Syntax error`; with an empty template → the backend text. Both refuse with no operation. Found while planning this run; outside its item.
    location: >-
      crates/zanshin-jj/src/mutate.rs:1186 (plan_new)
    severity: low
---

<intent-contract>

## Intent

**Problem:** (Item 1 deferred by the closing run of Story 9.18.) `plan_new` resolves the `immutable_heads()` set up front for every form, so with both a broken `templates.new_description` and an unresolvable alias Zanshin refuses with the immutable-set `jj.config_error` where the CLI names the template. `cmd_new` @ v0.46.0: location (`compute_commit_location`, `new.rs:179` — resolves the set only via `check_rewritable` for a location with children) → advance config → template parse (`:217-221`) → writes → `tx.finish` (`:284`, resolves the set).

**Approach:** Mirror commit 3aba05a: `plan_new` drops both of its `resolve_immutable` calls — `compute_commit_location` already resolves lazily for children, `finish_verb` resolves for the rest. The `new` drop/card rows (`RowContext::new_change` in `drop_actions.rs`, the merge row and the card's three `new` rows) resolve the set themselves after `plan_new`, so their previews keep refusing `Config` when only the alias is broken.

## Boundaries & Constraints

**Always:** The CLI's order for every `new` form; every refusal writes no operation; with only the alias broken the verb (at the finish) and every `new` row still refuse `Config`.

**Never:** No change to refusal codes, texts, FFI/schema, public API or any other verb. Rows do not parse or render description templates. The up-front root-merge refusal stays (deferred finding).

## I/O & Edge-Case Matrix

Both broken: alias `nonexistent_symbol_xyz`, template `"undo " ++`. History `A → B → C = @`.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| plain parent | `new C` (CLI `new @`, `new -o @`) | refused, no op | template parse `Config` |
| `-A` leaf | `-A C` | refused, no op | template parse |
| `-A` with child | `-A A` | refused, no op | immutable-set `Config` |
| `-B` | `-B C` | refused, no op | immutable-set `Config` |
| only alias broken | `new C` | refused, no op (finish) | immutable-set `Config` |
| rows, only alias broken | merge row, card `new` rows | Refused | `Config` (unchanged) |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/mutate.rs` -- `plan_new` (:1170-1194): remove `resolve_immutable(…)?` at :1182 and :1189; keep `base` for `compute_commit_location`. Docs :1127-1169 (the "immutable set is still resolved, last" bullet, the `-A`/`-B` bullet, Errors `Config`) and `new_change` docs :1244-1246 say the CLI order. `resolve_immutable` stays imported (used at :705, :798, :964).
- `crates/zanshin-jj/src/drop_actions.rs` -- `RowContext::new_change` (:380-391): after `plan_new`, `resolve_immutable(tx.base_repo().as_ref(), &ctx.immutable)?` with the duplicate row's comment (:429-431) as model; it serves the merge row (:426) and the card rows (:570-572).
- `crates/zanshin-jj/tests/it/new_insert.rs` -- local `base`, `set_repo_config`, `refused(fx, parents, after, before)`; existing `every_new_resolves_the_immutable_set` (:388) and `insert_after_a_leaf_refuses_an_unresolvable_alias_like_the_cli` (:405) must stay green. Reuse `crate::revert::{assert_config_class, UNRESOLVABLE_ALIAS}` (revert.rs:174-188).
- `crates/zanshin-jj/tests/it/drop_actions.rs` -- `an_unresolvable_alias_refuses_the_unguarded_rows` (:1328) covers the merge row and the card's `new_onto` with only the alias broken; must stay green.
- `crates/zanshin-parity/tests/oracle/refusal_order.rs` -- `BOTH_BROKEN` (add `templates.new_description`), `assert_same_class`, `location`, `id_of`; add a `new` witness.
- Read-only: `git -C ../jj show v0.46.0:cli/src/commands/new.rs` :162-291; `crates/zanshin-jj/src/op_support.rs` `compute_commit_location` (:273, lazy resolution at :316).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/mutate.rs` -- drop the two resolutions in `plan_new`; fix its and `new_change`'s docs.
- `crates/zanshin-jj/src/drop_actions.rs` -- the `new` row helper resolves after the plan.
- `crates/zanshin-jj/tests/it/new_insert.rs` -- one test covering the matrix's verb rows (both broken; only the alias broken).
- `crates/zanshin-parity/tests/oracle/refusal_order.rs` -- add the template to `BOTH_BROKEN` and a `new` witness: `new @`, `new -o @`, `new -A @` → Template; `new -A @--`, `new -B @` → ImmutableSet; module doc names `new`.

**Acceptance Criteria:**
- Given both settings broken, when `new` runs in each form of the matrix, then Zanshin's refusal class equals the pinned CLI's (oracle witness green) and no operation is written.
- Given only the alias broken, when the `new` drop/card rows or `new` run, then they refuse `Config` (existing `drop_actions::`, `new_insert::` suites green) and the full oracle stays green.

## Spec Change Log

## Review Triage Log

### 2026-10-25 — Review pass
- verdicts: 10 findings — high 0, medium 0, low 5, false 5, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind) the first Verification command passes two filters before `--` — real, but its fix edits this spec, not the change; the command line was corrected in passing to the form actually run (`-- new_insert:: drop_actions::`).
  - `[false]` `[reject]` (blind) no both-broken witness for a positional merge (`new @- @`) or `-A`+`-B` — a merge takes the same `destination` branch as `new @` (no resolution in the plan), and `-A`+`-B` always has children, the `-B` branch's path; both forms are covered by those cases.
  - `[low]` `[patch]` (blind; grouped with the intent auditor's row below) only the card's `new_onto` was asserted with the alias broken, so the card's `-A` on a leaf — now refusing solely through the row's own resolution — was unpinned — `an_unresolvable_alias_refuses_the_unguarded_rows` now asserts all three card `new` rows of the leaf `c` refuse `Config`.
  - `[low]` `[defer]` (blind) the up-front root-merge refusal has the same order gap and could be fixed here — the intent says "change only what the item needs"; already in this spec's `deferred:` (found at planning) and mirrored in deferred-work.md.
  - `[false]` `[reject]` (blind) the new test's alias-only tail duplicates `every_new_resolves_the_immutable_set` and the old tests hard-code `no-such-mark` — the tail adds the class check the old test lacks; no named harm.
  - `[false]` `[reject]` (blind) rows with children resolve the set twice, with a duplicated comment — the verb does the same, as the CLI's `check_rewritable` plus `tx.finish` do; one extra revset evaluation per row, no named harm; a helper would be an abstraction for two call sites.
  - `[low]` `[patch]` (blind) the new `plan_new` doc paragraph's "Otherwise" has no antecedent and the `new.rs` cite lacks `@ v0.46.0` — reworded ("Positional parents and an `-A` without children …"), tag added, `Rows::new_change` named.
  - `[false]` `[reject]` (blind) the doc's "`change_actions`' three" is stale — `change_actions` is the `Repo` fn in `drop_actions.rs` (:566-576) whose three `new` rows it names; accurate.
  - `[low]` `[patch]` (intent) the card's `new_insert_after` on a leaf with only the alias broken was untested — same root cause and fix as the grouped blind row above.
  - `[false]` `[reject]` (intent) with both settings broken the rows name the immutable set while the verb names the template (reading R3) — the intent only asks rows to keep refusing `Config` with the alias broken; rows never parse templates (precedent 3aba05a, Ralph 2026-10-21: rows advisory).
- Edge-case hunter: no findings. Verification-gap reviewer: no gaps.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it -- new_insert:: drop_actions::` -- expected: pass
- `cargo test -p zanshin-jj --test it` -- expected: pass
- `cargo test -p zanshin-parity --test oracle` -- expected: pass incl. `refusal_order::`
- `cargo clippy -p zanshin-jj -p zanshin-parity --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean

**Verification notes (this run; gate rule: no `cargo make test` / coverage):**
- Pinned CLI by hand (`target/debug/jj`, scratch repo): `new @ 'root()'` with `templates.new_description = '"x" ++'` → `Failed to parse template`, with an empty template → the Git backend's root-merge text, no operation either way (the deferred finding). The matrix's both-broken classes are witnessed against the same CLI by the oracle.
- Before review patches: `cargo test -p zanshin-jj --test it` — 1356 passed, 1 ignored (pre-existing), 0 failed; `cargo test -p zanshin-parity --test oracle` — 443 passed incl. `refusal_order::` (3: revert, duplicate, new); clippy `-p zanshin-jj -p zanshin-parity --all-targets -D warnings` — clean; `cargo fmt --all --check` — clean.
- After review patches (one test widened, one doc reworded): `cargo test -p zanshin-jj --test it -- drop_actions::an_unresolvable_alias new_insert::` — 23 passed; clippy (same) — clean; `cargo fmt --all --check` — clean.
- Matrix audit: plain parent, `-A` leaf, `-A` with child, `-B` and alias-only by `new_insert::a_broken_template_refuses_before_the_alias_unless_the_location_has_children` and (CLI side, incl. `-o`) `refusal_order::new_parses_its_template_before_the_finish_resolves_the_immutable_set`; rows with only the alias broken by `drop_actions::an_unresolvable_alias_refuses_the_unguarded_rows` (merge row + all three card `new` rows); all ran and passed.

## Auto Run Result

Status: done

- **Item 1 — fixed (ac6d0b4f9740959a7f9df6ea2dfbacb51154b672).** Real for plain parents, `-o` and `-A` on a leaf: `cmd_new` @ v0.46.0 resolves the immutable set before the template only inside `compute_commit_location` for a location with children (`-A` with a child, `-B`), and otherwise parses `templates.new_description` before `tx.finish` resolves it. `plan_new` dropped both up-front `resolve_immutable` calls (the lazy resolution of 3aba05a covers the children case, `finish_verb` the rest); `drop_actions`' `Rows::new_change` (merge row and the card's three `new` rows) resolves the set after the plan, so their previews keep refusing `Config` with only the alias broken.
- **Files changed:** `crates/zanshin-jj/src/mutate.rs` (plan resolutions removed, docs); `crates/zanshin-jj/src/drop_actions.rs` (row resolves after the plan); `crates/zanshin-jj/tests/it/new_insert.rs` (order test); `crates/zanshin-jj/tests/it/drop_actions.rs` (all three card `new` rows asserted); `crates/zanshin-parity/tests/oracle/refusal_order.rs` (`new` witness, `templates.new_description` in `BOTH_BROKEN`); `deferred-work.md` (item marked resolved, one new finding); this spec.
- **Review:** 10 findings — 2 patch entries (low: card rows test, doc wording; 3 rows), 1 deferred (low: root-merge order, already found at planning), 1 low and 5 false rejected with reasons in the Review Triage Log. Patched counts by verdict: high 0, medium 0, low 2 entries.
- **Follow-up review recommended:** false (no high or medium patched).
- **Verification:** see Verification notes.
- **Residual risk:** coverage ratchet not run (gate rule); the only new production line (`drop_actions.rs` row resolution) is executed by the drop-row suites. The root-merge refusal still precedes the template parse (deferred).
