---
title: 'Story 9.56 closing run — commit-summary hints render `templates.commit_summary`'
type: 'bugfix'
created: '2026-10-21'
status: 'done'
baseline_revision: 'bf6232e4bdf90aebde5489f1bbbf80f3492d5c83'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The CLI parses `templates.commit_summary`, `templates.op_summary` and the short change-id
      template at the start of EVERY workspace command, so a broken one refuses every command and
      their parse diagnostics warn on every command; Zanshin parses the summary template only when
      a hint renders it (diagnostics dropped) and `templates.op_summary` never.
    evidence: |-
      CLI v0.46.0 `cli/src/cli_util.rs:1272-1290` (`WorkspaceCommandHelper::new`: `get_string` of
      both keys, then `parse_operation_template` / `parse_commit_template` ×2 "to report error
      before starting mutable operation"); `crates/zanshin-jj/src/snapshot.rs` `CommandEnv::load`
      parses neither. Found while porting the summary hint (this run).
    location: >-
      crates/zanshin-jj/src/snapshot.rs CommandEnv::load; crates/zanshin-jj/src/template.rs
    severity: low
---

<intent-contract>

## Intent

**Problem:** Story 9.56's deferred item 1, verified at `bf6232e`: the immutable refusal's "Could not modify commit: <summary>" hint (`op_support.rs:135-156 immutable_hints`), push's "Rejected commit: <summary>" hint (`push.rs:458-472 Rejected::aborted`) and the commit list of push's "Skipped signing … immutable commits:" warning (`push.rs:1588-1595`) all render `push::commit_summary` (`push.rs:474-494`) — `<change 8> <commit 8> [(conflict)] [(empty)] <subject>` — where the CLI renders `templates.commit_summary` (`cli_util.rs:2049-2068`, `push.rs:753/769-770/953` @ v0.46.0; default `format_commit_summary_with_refs(self, format_commit_ref_names(bookmarks))`, `templates.toml:4`, `:350-368`). A bookmarked commit loses its "<refs> | " part, shortest ids are not used, and a user's custom summary template is ignored.

**Approach:** Render the effective `templates.commit_summary` through the existing jj-cli template engine (`template::Templates`, Story 9.51) at all three sites: a `Templates::commit_summary` method, and the `Templates` of the call threaded to `check_rewritable` (through `guard_rewritable`, `compute_commit_location`, `resolve_commit_location` and the plan fns that today take `immutable`) and into push's validator and signing. `push::commit_summary` and its documented divergence go.

## Boundaries & Constraints

**Always:**
- Output = the CLI's plain text: `templates.commit_summary` parsed with the call's start-up template aliases, immutable set, id-prefix context and workspace (exactly `Templates::parse_commit`'s language) over the repo the check runs against (`tx.base_repo()` / push's `base`, the CLI's workspace-helper repo), rendered `format_plain_text`, lossy UTF-8. Hint order and the other three immutable hints unchanged; root still gets none.
- The render discards template diagnostics (the CLI's `reparse_valid_template` uses a throwaway `TemplateDiagnostics`); a non-string or unparsable `templates.commit_summary` turns the refusal into `MutateError::Config` (`jj.config_error`) with `Templates::parse_commit`'s text — the CLI refuses that config at start-up before any verb runs (see `deferred:`).
- Drop/card rows (Story 9.31) carry the same rendered hint as the verb, through the shared plan fns.
- `docs/rust-error-codes.md` rows `jj.immutable` (:67), `jj.push_commit_rejected` (:89), `jj.push_signing_skipped_immutable` (:165) and `push.rs`'s module doc (:25-28) state the template rendering; the old divergence text is removed.
- Tests per project-context.md (`tests/it/<module>.rs`, `pin_test_env()` first); the parity witnesses run Zanshin and the pinned `jj` on the SAME repo and compare the hint line verbatim.

**Never:**
- No start-up parse of `templates.commit_summary` / `op_summary` (deferred), no new error or warning code, no FFI/schema/Dart/MCP/UI change, no change to the hint channel itself.
- No change to the skip path's warning ("Won't push …") — the CLI prints the summary there as a status line, not a warning or hint.
- Never regenerate fixtures; never lower `coverage-baseline.txt`; do not touch Story 9.56's spec, `epics.md` or `epic-9-context.md`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Bookmarked immutable | `immutable_heads()` = `b-mark`; describe the commit `b-mark` points at | hints[0] = "Could not modify commit: " + the CLI's rendering, incl. "b-mark \| B" — equal to the pinned `jj describe b-mark -m x` "Hint: " line | `jj.immutable` |
| Custom template | `templates.commit_summary = 'commit_id.short() ++ " custom"'` | immutable hint and push "Rejected commit:" hint render the custom text (CLI-equal) | as before |
| Push rejection | `jj git push -c @` on an undescribed `@` | hints[0] = "Rejected commit: " + rendering, CLI-equal; dry-run row hints the same | `jj.push_commit_rejected` |
| Signing skip list | `git.sign-on-push`, an immutable commit to push | each listed line renders the template | warning `jj.push_signing_skipped_immutable` |
| Broken template | `templates.commit_summary = 'nope('` and an immutable target | refusal is `Config` "Failed to parse template: …", no operation | `jj.config_error` |
| Root | edit root | no hints (unchanged) | `jj.immutable` |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/template.rs` -- `Templates` (:124-163, private fields incl. `immutable` :126), `parse_commit` (:210-256; records diagnostics into `sink`), `push_bookmark_names` (:377-389) as the render pattern. Add `pub(crate) fn immutable(&self) -> &Arc<UserRevsetExpression>` and `pub(crate) fn commit_summary(&self, repo: &dyn JjRepo, commit: &Commit) -> Result<String, MutateError>` (throwaway `Warnings`). Unit-test fixture `Fixture`/`repo_with` (:461-509).
- `crates/zanshin-jj/src/config.rs:1571-1615` -- add `templates_commit_summary` beside `templates_git_push_bookmark` (CLI `cli_util.rs:1272`; default from `CLI_DEFAULTS`).
- `crates/zanshin-jj/src/op_support.rs` -- `check_rewritable` :112-132 (+ `templates` param), `immutable_hints` :135-156 (summary via `templates.commit_summary`), `resolve_commit_location` :202-221, `compute_commit_location` :259 (+ `templates`, passed to `check_rewritable` :302). Unit tests :900-1220 (`immutable_at_head` :915 builds `CommandEnv` — extend it to hand back what `Templates::new` needs).
- `crates/zanshin-jj/src/mutate.rs` -- `guard_rewritable` :608-618 (take `templates`, resolve `templates.immutable()`); plan fns taking `immutable: &Arc<UserRevsetExpression>` → `templates: &Templates<'_>`: `plan_describe` :896, `plan_new` :1017 (also its own resolve / `compute_commit_location` :1049), `plan_edit` :1193, `plan_abandon` :1253; ctx-taking `plan_restore` :1632 (:1655), `plan_absorb` :1790 (:1836) build a `Templates` from `ctx` + `workspace`. Verb callers :941, :1118, :1231, :1312 build `Templates::new(&ctx.config, &ctx.immutable, &ctx.template_startup, workspace)` (pattern :947, :1139; mind the disjoint field borrows vs `&mut ctx.warnings`).
- `crates/zanshin-jj/src/rebase.rs` -- `plan_rebase_revisions` :51, `plan_rebase_source` :85, `plan_rebase_branch` :119 (`immutable` → `templates`); test :295-360 uses a hand-made immutable set (`RevsetExpression::commits(c2)`) — build a `Templates` with it.
- `crates/zanshin-jj/src/duplicate.rs:49 plan_duplicate`, `crates/zanshin-jj/src/revert.rs:54 plan_revert` (test :111) -- same param swap.
- `crates/zanshin-jj/src/squash_split.rs` -- `plan_squash` :234 (:257), `prepare_split` :583 (:614, `compute_commit_location` :620): build a `Templates` from `ctx` + `workspace` (existing ones at :393, :466, :686 are later and may be reused/reordered only if trivial).
- `crates/zanshin-jj/src/drop_actions.rs` -- callers :282-284, :314, :372, :412, :554-569 pass `&ctx.immutable` today; build `Templates::new(&ctx.config, &ctx.immutable, &ctx.template_startup, self.workspace)` per row (or once per call if borrows allow). `outcome` already maps `e.hints()` into `ActionRefusal.hints`.
- `crates/zanshin-jj/src/push.rs` -- module doc divergence bullet :25-28; `Rejected::aborted` :458 (+ `&Templates`, returns `Result`); `commit_summary` :474-494 (delete); `CommitsValidator` :497+ (`repo` field; `new(base, remote, planner)` :~510) — hold a `&Templates` built from `planner.config/immutable/template_startup/repo.workspace()` (pattern :1016-1021); `validate_explicit` :1253-1300 (`aborted` at :1270, :1293); `sign_before_push` :1572-1600 (`&ctx.immutable` at :1853 → a `Templates`; skipped list :1588-1595); `skipped_signing_message` tests :1995-2015 untouched (pure strings).
- Existing witnesses: `crates/zanshin-jj/tests/it/push.rs:279-299` (hint prefix + 8 hex), `:970-1001`, `:1204` (signing list); `tests/it/drop_actions.rs:1340-1380` (`ends_with(" B")`); `crates/zanshin-ffi/src/repo.rs:1970` (synthetic, unaffected).
- Oracle: `crates/zanshin-parity/tests/oracle/main.rs` (`mod` list :14-20; standalone `#[test]`s after `parity!`), `driver.rs` (`fresh_repo` :103, `jj` :52, `Step::Git` bare remote pattern `git_scenarios.rs:216-219`), `scenarios.rs` `BASE` :31-39 (B carries `b-mark`). Zanshin side via `zanshin_jj::Repo::open(root)` + public verbs (`describe`, `git_push(&GitPushArgs{changes: vec!["@".into()], ..}, &|_| {}, None)`) and `MutateError::hints()`.
- Docs: `docs/rust-error-codes.md:67`, `:89`, `:165`.
- `_bmad-output/implementation-artifacts/deferred-work.md:1784-1786` -- mark the item RESOLVED (strike-through + commit) as earlier closing runs did; add the new `deferred:` finding under `## Surfaced in the closing run of Story 9.56 (bmad-build-auto, 2026-10-21)`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/config.rs`, `src/template.rs` -- `templates_commit_summary` accessor; `Templates::immutable()` + `Templates::commit_summary` -- the renderer.
- `crates/zanshin-jj/src/op_support.rs`, `src/mutate.rs`, `src/rebase.rs`, `src/duplicate.rs`, `src/revert.rs`, `src/squash_split.rs`, `src/drop_actions.rs` -- thread `&Templates` to `check_rewritable` as mapped above; `immutable_hints` renders the summary -- immutable hint.
- `crates/zanshin-jj/src/push.rs` -- `aborted` and the signing skip list render through `Templates`; delete `commit_summary` and the divergence bullet -- push hint + warning list.
- Tests (zanshin-jj): unit test of `Templates::commit_summary` (default template on a bookmarked commit contains "<bookmark> | <subject>"; custom template; unparsable → `Config`); `tests/it/` witnesses: immutable refusal with a custom template (verb + drop row hints equal), broken template → `Config` with no new operation, push rejection with a custom template (real + dry run), signing list with a custom template (extend the `:1204` test); update existing assertions only where the format changed.
- `crates/zanshin-parity/tests/oracle/hints.rs` (new, `mod hints;` in `main.rs`) -- same-repo witnesses vs the pinned `jj`: immutable hint on bookmarked B (default template), immutable hint with a custom template, push "Rejected commit:" hint with default and custom template; each compares Zanshin's hint string with the CLI's matching `Hint: ` stderr line -- parity.
- `docs/rust-error-codes.md` -- the three rows -- registry.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- resolve item, mirror the new finding -- ledger.

**Acceptance Criteria:**
- Given BASE with `immutable_heads()` = `b-mark`, when Zanshin describes B and the pinned CLI runs `jj describe b-mark -m x` on the same repo, then Zanshin's first hint equals the CLI's "Could not modify commit: …" hint line, including "b-mark | B".
- Given a custom `templates.commit_summary`, when the immutable refusal and `git push -c @` on an undescribed `@` run through Zanshin and the pinned CLI on the same repo, then both summary hints equal the CLI's.
- Given an immutable target in a drop/card row, when the row is previewed, then its refusal hints equal the verb's.
- Given an unparsable `templates.commit_summary`, when a rewrite of an immutable commit is attempted, then it refuses `jj.config_error` and writes no operation.
- `push::commit_summary` no longer exists; no doc or registry row describes the approximate summary.

## Spec Change Log

## Review Triage Log

### 2026-10-21 — Review pass
- verdicts: 23 findings — high 0, medium 0, low 17, false 6, maybe-false 0
- findings:
  - `[low]` `[patch]` (intent) the push "Rejected commit:" hint is compared with the CLI only on a commit without bookmarks — added oracle `hints::rejected_commit_hint_renders_the_refs_of_a_bookmarked_commit` (bookmark `here` on the undescribed `@`, CLI-equal, contains " here | ").
  - `[low]` `[reject]` (intent) the sign-on-push skip list has no oracle witness — it renders through the same `Templates::commit_summary` the two hint witnesses pin against the CLI; an oracle signing setup (test signing backend, immutable pushed commits) is more than a direct correction for no demonstrated defect; pinned by `tests/it/push.rs`.
  - `[false]` `[reject]` (intent) the `hints::` witnesses bypass the scenario/ledger machinery and compare hint text only — a refusal writes nothing, and the refused repo state is already compared by the scenario `describe_immutable`; the witnesses add exactly the text comparison the oracle cannot make.
  - `[low]` `[defer]` (intent) a broken summary template refuses only where a hint renders it, while the CLI refuses at start-up for every command — pre-existing start-up-parse gap, already this run's `deferred:` entry and mirrored into deferred-work.md.
  - `[false]` `[reject]` (intent) `## Auto Run Result` with a commit hash is missing — written at finalize, after this review.
  - `[false]` `[reject]` (intent) the verification section records expected, not actual outcomes — the actual outcomes are recorded at finalize under Verification notes.
  - `[low]` `[patch]` (verification-gap) no test pins that a broken template refuses the push (real and dry run) — added `tests/it/push.rs::a_broken_commit_summary_template_refuses_the_push` (`Config` "Failed to parse template: …", head op unchanged, both runs).
  - `[low]` `[patch]` (blind) the `jj.config_error` registry row did not list the new emitters — row extended (non-root immutable refusals incl. drop/card rows, push rejection real + dry run, sign-on-push skip list; points at the deferred start-up gap).
  - `[low]` `[patch]` (blind) the `jj.immutable` row overstated the broken-template refusal (root never renders a summary) — narrowed to non-root offenders; root and mutable rewrites named.
  - `[false]` `[reject]` (blind) the throwaway `Warnings` drops environment-load warnings — `CommandEnv::load` already recorded the revset and fileset alias loads for the call (record-once), and `ui.conflict-marker-style` loads emit no warnings; nothing the call's sink lacks is lost.
  - `[low]` `[reject]` (blind) `sign_before_push` parses the summary template per skipped commit and renders an 11th unused one — at most 11 parses, only under `git.sign-on-push` with immutable commits; a parse-once renderer adds an API for negligible cost.
  - `[low]` `[reject]` (blind) each refused card row builds its own `Templates` and template environment — the environment loads only when a non-root immutable refusal renders its hint (a handful of rows per menu); sharing one `Templates` across rows conflicts with each row's `&mut VerbContext` borrow, so the fix is a restructuring, not a correction. Residual risk below.
  - `[low]` `[patch]` (blind) the deferred-work resolution claimed CLI witnesses for all three sites — reworded: the two hints are CLI-witnessed, the signing list is pinned by `tests/it/push.rs` only; the parity-witness request itself is rejected with the intent row above.
  - `[low]` `[reject]` (blind) no parity witness for the broken-template refusal text — the CLI refuses that config at start-up, a path the deferred start-up parse will port; pinning today's hint-site text against it adds nothing durable.
  - `[low]` `[patch]` (blind) a dry run with a broken template ends in `Err`, contrary to the dry-run divergence bullet — the bullet in `push.rs`'s module doc now names the exception.
  - `[low]` `[patch]` (blind) wrong citation in the new `tests/it/drop_actions.rs` doc (`write_commit_summary` is `cli_util.rs:2027-2033`) — fixed; the `@ v0.44.0` citation kept in the `jj.immutable` row is pre-existing text, rejected.
  - `[low]` `[reject]` (blind) `the_commit_summary_renders_the_template` renders a commit of the first fixture with later fixtures' `Templates` — every render runs over the owning repo (`tx.repo()`); the other fixtures differ only in the config under test, so the assertions hold for the right reason.
  - `[low]` `[reject]` (blind) the `compute_commit_location` threading is only compile-checked, and root + broken template is untested — every path passes the one `Templates` the call's `VerbContext` builds, so no other value can arrive there; the root path renders no summary (unchanged code).
  - `[low]` `[patch]` (blind) the resolved deferred-work item kept live sub-bullets pointing at deleted code — marked "(as found)" and the follow-up struck "Done (348d70f)", as earlier closing runs did; the trailing "Low." is the file's convention.
  - `[false]` `[reject]` (blind) the `with_repo_config` test helper appends a duplicate `[templates]` table if the fixture had one — the fixture's repo config has no `[templates]` table; the outcome does not happen.
  - `[false]` `[reject]` (edge) any template-environment fault (`ui.conflict-marker-style`, `[fileset-aliases]`, revset config) now flips the refusal to `jj.config_error` — those faults refuse every verb earlier (the start-up `CommandEnv::load` and jj-lib's working-copy load), so the hint site never sees them.
  - `[low]` `[patch]` (edge) the `jj.push_signing_skipped_immutable` row did not say a broken template refuses the whole push — added.
  - `[low]` `[patch]` (edge) the `jj.immutable` claim covered root — same fix as the blind-hunter row (non-root only).

## Design Notes

**Why `Templates` replaces the `immutable` parameter.** `Templates` already holds the start-up immutable set (`::(immutable_heads() | root())`) plus everything the summary template needs (config, aliases, short-prefixes, workspace), so swapping the plan fns' `immutable: &Arc<UserRevsetExpression>` for `templates: &Templates<'_>` threads the template context with no extra parameter; `guard_rewritable` resolves `templates.immutable()`. `compute_commit_location` / `resolve_commit_location` / `check_rewritable` keep their RESOLVED set and gain `templates` only for the hint.

**Why the throwaway sink.** The CLI renders through `reparse_valid_template` (`cli_util.rs:1939-1956`), discarding diagnostics; its diagnostics come from the start-up parse Zanshin does not port (deferred). Recording them at the hint site would add warnings the CLI prints in another place and count.

## Verification

**Commands (targeted; the story loop runs the full gate):**
- `cargo test -p zanshin-jj` -- expected: green.
- `cargo test -p zanshin-ffi` -- expected: green (dependent; error mapping unchanged).
- `cargo test -p zanshin-parity --test oracle` -- expected: green, no UNEXPECTED/CHANGED/STALE, new `hints::` tests pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean.

**Verification notes (run 2026-10-21, after the review patches; no `cargo make test` / `test-full` / `coverage` per the loop's gate rule):**
- `cargo fmt --all --check` — clean.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean.
- `cargo test -p zanshin-jj` — 302 lib + 1012 `it` passed (1 pre-existing ignored).
- `cargo test -p zanshin-ffi` — 195 lib + 307 `it` passed (dependent; error mapping unchanged).
- `cargo test -p zanshin-parity --test oracle` — 201 passed (incl. the 5 new `hints::` witnesses), no UNEXPECTED / CHANGED / STALE.
- No FFI/schema/Dart change: `cargo make codegen` and the Dart checks do not apply. Coverage not measured (loop gate rule); every new or changed line got tests.

## Auto Run Result

Status: done

**Items:**
- **1 — fixed (348d70fe8ddd735d0b938b7385c2f3cd4347cd44).** Verified real at `bf6232e`: `immutable_hints`, push's `Rejected::aborted` and the skipped-signing list rendered `push::commit_summary`. Now `Templates::commit_summary` renders the effective `templates.commit_summary` (jj-cli engine, call's aliases / immutable set / id-prefix context / workspace, over the check's base repo, diagnostics dropped as the CLI's reparse does) at all three sites; the call's `Templates` replaces the `immutable` parameter of `guard_rewritable` and the plan fns and reaches `check_rewritable` / `compute_commit_location` / `resolve_commit_location`, so drop/card rows carry the verb's hint. `push::commit_summary` and its documented divergence are gone; registry rows updated. A non-string/unparsable template refuses as `jj.config_error` where a hint renders it. Witnessed against the pinned CLI on the same repo (oracle `hints::`): immutable hint on bookmarked B (default and custom template), push "Rejected commit:" (default, custom, bookmarked `@`).

**New finding (deferred, mirrored into deferred-work.md):** the CLI parses `templates.commit_summary`, `templates.op_summary` and the short change-id template at every command's start (`cli_util.rs:1272-1290`); Zanshin does not — see `deferred:`.

**Files changed:** `crates/zanshin-jj/src/{config,template}.rs` (accessor + renderer); `src/{op_support,mutate,rebase,duplicate,revert,squash_split,drop_actions,snapshot}.rs` (templates threaded to the guard; `VerbContext::templates`); `src/push.rs` (validator/signing render through templates, `commit_summary` deleted, module doc); tests `src/template.rs`, `src/op_support.rs`, `src/rebase.rs`, `src/revert.rs`, `tests/it/{drop_actions,push}.rs`; `crates/zanshin-parity/tests/oracle/{hints.rs,main.rs}`; `docs/rust-error-codes.md`; `deferred-work.md`.

**Review:** 23 findings (low 17, false 6). Patched (all low): bookmarked push oracle witness, broken-template push test, registry rows (`jj.config_error`, `jj.immutable` non-root only, signing row), dry-run doc exception, test citation, deferred-work resolution wording. Deferred: the start-up template parse (this run's finding). Rejected: see the triage log, each with its reason.

**Follow-up review recommended:** false — patched counts high 0, medium 0, low 9 entries.

**Residual risks:** each refused card row builds its own template environment (id-prefix context over `revsets.short-prefixes`) when it renders the immutable hint — a few renders per menu on immutable commits; the sign-on-push skip list has no CLI witness; a broken summary template refuses only where a hint renders it (deferred start-up gap); coverage ratchet not run (loop gate at the end).
