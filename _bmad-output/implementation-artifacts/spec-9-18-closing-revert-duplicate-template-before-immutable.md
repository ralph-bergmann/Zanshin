---
title: 'Story 9.18 closing run: revert and duplicate parse their template before resolving the immutable set'
type: 'bugfix'
created: '2026-10-24'
status: 'done'
baseline_revision: '4bab31bc75878e27c614eae6beae4d73166c0a12'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      `new` with both a broken `templates.new_description` and an unresolvable `immutable_heads()` names the immutable set where the CLI names the template.
    evidence: |-
      `plan_new` resolves the set up front for every form (crates/zanshin-jj/src/mutate.rs:1182, :1189); `cmd_new` @ v0.46.0 resolves it only inside `compute_commit_location` for a location with children (cli/src/commands/new.rs:179), parses `templates.new_description` after it (:217-221) and resolves it again in `tx.finish` (:284). Both refuse `jj.config_error` with no operation; only the context text differs. Pre-existing, outside this run's item list (blind-hunter review).
    location: >-
      crates/zanshin-jj/src/mutate.rs:1170 (plan_new)
    severity: low
    resolved: >-
      2026-10-25 — fixed (spec-9-18-followup-new-template-before-immutable, commit ac6d0b4): plan_new no longer resolves the immutable set up front; the new rows resolve it after the plan; oracle refusal_order.rs witnesses every new form.
---

<intent-contract>

## Intent

**Problem:** (Item 1 of Story 9.18's ledger.) `plan_revert` and `plan_duplicate_ids` resolve the `immutable_heads()` set inside the plan — up front for `-A`/`-B`, at the end otherwise — so with both a broken `templates.revert_description`/`templates.duplicate_description` and an unresolvable alias Zanshin refuses with the immutable-set `jj.config_error` where the CLI reports the template parse error. Verified by hand with the pinned `target/debug/jj` (symbolic args, alias `nonexistent_symbol_xyz`, template `"undo " ++`): `revert -r @- -o @`, `-A @` (leaf), `duplicate @-`, `duplicate @- -o @`, `duplicate @- -A @` → `Failed to parse template: Syntax error`; `revert -r @- -A @--` (has a child), `-B @`, `duplicate @- -A @--` → `Config error: Invalid revset-aliases.immutable_heads()`; no operation in every case. `cmd_revert`/`cmd_duplicate` @ v0.46.0: revisions → location (`compute_commit_location` resolves the set only via `check_rewritable` for non-empty children) → template parse → writes → `tx.finish` (resolves the set).

**Approach:** The location resolves the immutable set lazily, from the call's templates, only when it has children — the CLI's `check_rewritable` inside `compute_commit_location`. `plan_revert`/`plan_duplicate_ids` drop both of their own resolutions, so the template parse comes before the finish's resolution (`finish_verb`, Story 9.56). `drop_actions`' `revert` and `duplicate` rows add their own resolution after the plan (a revert row only when the plan writes), so their previews keep refusing `Config`.

## Boundaries & Constraints

**Always:** The CLI's order per verb as above; every refusal writes no operation; the shared location keeps its internal order (children → rewritability → loop check → empty-parents refusal); callers of the location that resolve the set up front for their own reasons (`plan_new`, `rebase -b`'s insert branch, the target guards of `rebase -r`/`-s` and `split`) keep that resolution, so their observable behaviour is unchanged; drop rows keep agreeing with the verb on Available vs Refused (the verb's refusal may differ only where it parses a template the row never renders).

**Never:** No change to refusal codes, texts, FFI/schema, public API or other verbs' observable behaviour. Drop rows do not render or parse description templates. No caching of the resolved set across calls.

## I/O & Edge-Case Matrix

Both broken: alias `nonexistent_symbol_xyz`, template unparsable. History `A → B → C = @`.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| revert `-o` | `-r B -o C` | refused, no op | `Config` "Failed to parse template: …" |
| revert `-A` leaf | `-r B -A C` | refused, no op | template parse error |
| revert `-A` with child | `-r B -A A` | refused, no op | `Config` "Invalid `revset-aliases.immutable_heads()`: …" |
| revert `-B` | `-r B -B C` | refused, no op | immutable-set `Config` |
| duplicate no location / `-o` / `-A` leaf | `B` / `B -o C` / `B -A C` | refused, no op | template parse error |
| duplicate `-A` with child | `B -A A` | refused, no op | immutable-set `Config` |
| only alias broken | revert `-o`, duplicate `-o` | refused, no op (finish) | immutable-set `Config` |
| drop rows, only alias broken | revert/duplicate `-o C` rows | Refused | `Config` (unchanged) |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/op_support.rs` -- `resolve_commit_location` (:213) and `compute_commit_location` (:273) take `immutable: &Arc<ResolvedRevsetExpression>`; drop the param, resolve `resolve_immutable(repo, templates.immutable())?` inside `if !new_child_ids.is_empty()` before `check_rewritable` (:316). Docs: the "immutable is threaded in" paragraph and Errors (`Config` only with children). Inline tests :1061-1303 pass `immutable` from `at.parts()` — drop the arg (bind `_`); add one test: an unresolvable expression with `-A` on a leaf is Ok, with children refuses `Config`.
- `crates/zanshin-jj/src/revert.rs` -- `plan_revert` (:87-119): remove both `resolve_immutable` blocks (:101-105, :111-113); doc (:69-86) says the CLI order. Imports `resolve_immutable`, `ResolvedRevsetExpression`, `Arc` may become unused.
- `crates/zanshin-jj/src/duplicate.rs` -- `plan_duplicate_ids` (:96-129): same (:112-116, :125-127); docs :62-95.
- `crates/zanshin-jj/src/rebase.rs` -- callers :111, :140, :194 drop the `&resolved` arg; `plan_rebase_branch_ids` (:189-193) keeps `if location.inserts() { resolve_immutable(…)?; }` (behaviour unchanged); :105/:139 `guard_rewritable` result becomes unused (`guard_rewritable(…)?;`).
- `crates/zanshin-jj/src/mutate.rs` -- `plan_new` (:1188-1198): keep `resolve_immutable(base, …)?;` as a statement, drop the arg.
- `crates/zanshin-jj/src/squash_split.rs` -- `prepare_split` (:698-712): `guard_rewritable(…)?;`, drop the arg.
- `crates/zanshin-jj/src/drop_actions.rs` -- `revert` row (:309-327): after `plan_revert`, when `Some`, `resolve_immutable(tx.base_repo().as_ref(), &ctx.immutable)?`; `duplicate` row (:418-421): after `plan_duplicate`, the same. Model: the bookmark-move row :463-467.
- `crates/zanshin-jj/tests/it/revert.rs`, `tests/it/duplicate.rs` -- helpers `reconfigure`, `refused`, `immutable` from `crate::rebase`; existing template tests :141 / :162.
- `crates/zanshin-jj/tests/it/drop_actions.rs` -- `an_unresolvable_alias_refuses_the_unguarded_rows` (:1301) must stay green.
- `crates/zanshin-parity/tests/oracle/hints.rs` -- pattern for a same-repo witness (`fresh_repo`, `jj`, `Repo::open`, `change`); `main.rs` declares modules.
- Read-only: `git -C ../jj show v0.46.0:cli/src/commands/revert.rs` :98-243, `:cli/src/commands/duplicate.rs` :103-230, `:cli/src/cli_util.rs` :3644-3720 (`compute_commit_location`), :2849-2858 / :2986-3002 (`tx.finish`).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/op_support.rs` -- lazy resolution as in the Code Map; adapt tests; add the leaf/children test.
- `crates/zanshin-jj/src/revert.rs`, `duplicate.rs` -- drop the plan-level resolutions; fix docs.
- `crates/zanshin-jj/src/rebase.rs`, `mutate.rs`, `squash_split.rs` -- mechanical caller updates keeping each up-front resolution.
- `crates/zanshin-jj/src/drop_actions.rs` -- the two rows resolve after their plan.
- `crates/zanshin-jj/tests/it/revert.rs`, `duplicate.rs` -- one test each covering the matrix's rows for that verb (both broken; only the alias broken).
- `crates/zanshin-parity/tests/oracle/refusal_order.rs` (+ `main.rs` `mod`) -- witness per verb: same repo, both settings broken, Zanshin (change ids) and the pinned CLI (symbolic `@-`/`@`/`@--` args — change-id args make the CLI refuse earlier, at its short-prefixes index) refuse with the same class (template parse vs immutable set) and write no operation, for `-o`, `-A` leaf and `-A` with a child (duplicate also without a location).

**Acceptance Criteria:**
- Given both settings broken, when `revert`/`duplicate` run at each location of the matrix, then Zanshin's refusal class equals the pinned CLI's (oracle witness green) and no operation is written.
- Given only the alias broken, when the drop rows or the verbs run, then existing suites (`drop_actions::`, `revert::`, `duplicate::`, `rebase::`, `new_insert::`, `squash_split::`) and the full oracle stay green.

## Review Triage Log

### 2026-10-24 — Review pass
- verdicts: 17 findings — high 0, medium 0, low 9, false 8, maybe-false 0
- findings:
  - `[low]` `[reject]` (edge) with both settings broken the revert/duplicate drop row refuses with the immutable-set text while the verb refuses with the template text — real, but the rows never parse description templates (spec Never) and Ralph decided 2026-10-21 that rows stay advisory with the verb's refusal authoritative (deferred-work.md "preview rows stop at the verbs' plan phase"); a one-clause code comment was added with the drop_actions comment patch below.
  - `[low]` `[defer]` (blind) `plan_new` keeps resolving the set up front, so `new` with a broken `templates.new_description` and alias names the immutable set where `cmd_new` names the template — verified at new.rs:179/:217-221/:284 @ v0.46.0; pre-existing and outside this run's item list ("nothing else"); deferred (frontmatter) and mirrored in deferred-work.md.
  - `[low]` `[patch]` (blind) the kept `if location.inserts() { resolve_immutable(…)?; }` in `plan_rebase_branch_ids` has no visible reason — one-line why-comment added (keeps rebase -b's refusal order; rebase parses no template).
  - `[low]` `[reject]` (blind) `-A`/`-B` with an unresolvable location id plus a broken alias now refuses `ChangeNotFound` instead of `Config` — the CLI refuses neither way (change-id args hit its short-prefixes index first, Story 9.31 closing run); both refuse with no operation; no CLI text to match.
  - `[low]` `[patch]` (blind) duplicate `-B` uncovered while revert has it — `-B C` case added to `tests/it/duplicate.rs` and the oracle's duplicate witness.
  - `[low]` `[reject]` (blind) no `-A`+`-B` combination case — same `!new_child_ids.is_empty()` branch as `-B`, already covered.
  - `[low]` `[reject]` (blind) the new unit test does not exercise `-o` with an unresolvable set — `-o` is covered end to end by both new integration tests and the oracle.
  - `[low]` `[patch]` (blind) drop-row comments do not say the row skips the verb's template parse — one clause added to each comment.
  - `[false]` `[reject]` (blind) the set is resolved more often and `guard_rewritable`'s "do not resolve twice" rationale is dead — `mutate.rs:1414` still uses the returned set; the extra resolution with children is the CLI's own (`check_rewritable` resolves per call).
  - `[false]` `[reject]` (blind) shared test helpers live in `revert.rs`, names/docs repeated, alias literal in three places — test-only, compiles, no named harm.
  - `[false]` `[reject]` (blind) `class_of` uses `contains` and could misclassify — a text naming both or neither panics loudly; all 8 cases pass against the pinned CLI.
  - `[low]` `[patch]` (blind) the plan docs' "Otherwise the CLI's order … is the verb's" reads backwards — reworded.
  - `[false]` `[reject]` (blind) "(Story 9.18 closing run)" in docs is process history — the codebase cites stories throughout (e.g. "(Story 9.56)"); the CLI source lines are cited too.
  - `[false]` `[reject]` (verification-gap) no gaps found — informational.
  - `[false]` `[reject]` (intent) the change reaches shared `compute_commit_location`/callers beyond the two plan fns — the CLI's order for `-A` on a leaf needs the lazy resolution in the location; other callers keep their up-front resolutions (behaviour unchanged, `new_insert::`/`rebase::`/`squash_split::` green).
  - `[false]` `[reject]` (intent) `drop_actions` gains calls rather than "keeping its own" — the plan fns no longer resolve, so the rows resolve themselves to keep their previews, as the intent requires (`an_unresolvable_alias_refuses_the_unguarded_rows` green).
  - `[false]` `[reject]` (intent) the oracle compares the refusal class, not full text, and no Auto Run Result yet — the two sides' texts differ in framing (`Config error:` vs typed reason), the class is the observable order; the result is written at finalize.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib op_support:: revert:: duplicate:: rebase::` -- expected: pass
- `cargo test -p zanshin-jj --test it` -- expected: pass
- `cargo test -p zanshin-parity --test oracle` -- expected: pass incl. `refusal_order::`
- `cargo clippy -p zanshin-jj -p zanshin-parity --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean

**Verification notes (this run; gate rule: no `cargo make test` / coverage):**
- Pinned CLI by hand (`target/debug/jj`, scratch repo, alias `nonexistent_symbol_xyz`, templates `"undo " ++`): symbolic args give the matrix's classes, no operation each; change-id args refuse earlier with `Failed to resolve short-prefixes disambiguation revset`.
- Final tree (after review patches): `cargo test -p zanshin-jj --lib -- op_support:: revert:: duplicate:: rebase::` — 54 passed; `cargo test -p zanshin-jj --test it` — 1353 passed, 1 ignored (pre-existing), 0 failed; `cargo test -p zanshin-parity --test oracle` — 442 passed incl. `refusal_order::` (2); `cargo clippy -p zanshin-jj -p zanshin-parity --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean.
- Matrix audit: every row covered by `tests/it/revert.rs` / `tests/it/duplicate.rs` `a_broken_template_refuses_before_the_alias_unless_the_location_has_children` and `refusal_order::`; drop rows (alias only) by `drop_actions::an_unresolvable_alias_refuses_the_unguarded_rows`; all ran and passed.

## Auto Run Result

Status: done

- **Item 1 — fixed (3aba05a41f4a342f068aab1a93ba30b76c2a684f).** Real, and wider than `-o`: `cmd_revert`/`cmd_duplicate` @ v0.46.0 resolve the immutable set before the template only inside `compute_commit_location` for a location with children; `-o`, `-A` on a leaf and duplicate without a location parse the template first. `compute_commit_location`/`resolve_commit_location` now resolve the set lazily (children only); `plan_revert`/`plan_duplicate_ids` dropped both their resolutions, so the template parse precedes `finish_verb`'s resolution; the revert/duplicate drop rows resolve after their plan (previews unchanged). Witnessed against the pinned CLI on one repo by `crates/zanshin-parity/tests/oracle/refusal_order.rs` (symbolic CLI args, since change-id args make the CLI refuse at its short-prefixes index first).
- **Files changed:** `crates/zanshin-jj/src/op_support.rs` (lazy resolution + test); `revert.rs`, `duplicate.rs` (plan resolutions removed); `rebase.rs`, `mutate.rs`, `squash_split.rs` (call sites, up-front resolutions kept); `drop_actions.rs` (rows resolve after the plan); `tests/it/revert.rs`, `tests/it/duplicate.rs` (order tests); `crates/zanshin-parity/tests/oracle/refusal_order.rs` + `main.rs` (oracle witness); `deferred-work.md` (one new finding); this spec.
- **Review:** 17 findings — 4 patched (low: rebase -b why-comment, drop-row comments, duplicate `-B` cases, doc reword), 1 deferred (low: `new` has the same template/immutable order gap — `plan_new` resolves up front; mirrored in deferred-work.md), 5 low rejected and 8 false rejected, each with its reason in the Review Triage Log. Patched counts by verdict: high 0, medium 0, low 4 entries.
- **Follow-up review recommended:** false (no high or medium patched).
- **Verification:** see Verification notes.
- **Residual risk:** coverage ratchet not run (gate rule); the new `op_support.rs` line has its own unit test and the new `drop_actions.rs` lines are hit by the drop-row suites. Drop rows still read the immutable-set refusal where the verb reports a broken template (rows stay advisory, Ralph 2026-10-21).
