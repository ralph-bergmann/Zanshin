---
title: 'Story 9.25 closing run: every user revset resolves with the id-prefix context, search errors keep their warnings, show/evolog/bookmark list carry revset hints'
type: 'bugfix'
created: '2026-10-25'
status: 'done'
baseline_revision: '3f4a5efe634952a9554dca5232eb9b77627fcc25'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      `interdiff`'s `from`/`to` prefixes and the change-id currency still resolve without the id-prefix context.
    evidence: |-
      `op_support::resolve_commit_id_prefix` (bare full-index lookup, deliberate Epic 9 follow-up I divergence) and `op_support::resolve_commit` take no `revsets.short-prefixes` context, while the CLI's `jj interdiff --from/--to` resolves through `resolve_single_rev` → `attach_revset_evaluator` (cli/src/cli_util.rs:1905-1921 @ v0.46.0). A prefix unique within the set but ambiguous repo-wide resolves in the CLI and refuses in Zanshin; GUI callers pass full ids. Pre-existing, outside this run's three items (intent-alignment and blind-hunter review). Mirrored into deferred-work.md.
    location: >-
      crates/zanshin-jj/src/op_support.rs:730 (resolve_commit_id_prefix), crates/zanshin-jj/src/commit_views.rs (resolve_side)
    severity: low
    resolved: >-
      2026-10-26 — fixed (spec-loop-9-25-9-46-leftover-a-prefix-gitconfig-root-native, commit b46a030): interdiff's `RevisionRef` prefixes resolve through the call's `revsets.short-prefixes` context, with oracle scenarios.
---

<intent-contract>

## Intent

**Problem:** Three CLI-parity gaps Story 9.25 deferred. (1) Only `revset_counts` / `find_changes` resolve symbols with the id-prefix context; `graph_topology`, the reads and every verb that takes revset text resolve without it, so a short prefix unique within `revsets.short-prefixes` but ambiguous repo-wide refuses `jj.revset_resolution_error` where the CLI (`attach_revset_evaluator` → `default_symbol_resolver`, `cli/src/revset_util.rs:197-203`, `cli_util.rs:1905-1921` @ v0.46.0) resolves it. (2) A call-level failure of the two searches drops the warnings collected before it (`revset_search.rs::finish` logs them); the CLI prints them before failing (Story 9.32 rule: warnings ride the error envelope). (3) `show`/`evolog` (`commit_views.rs::rev`) and `bookmark list -r` (`bookmarks.rs::rev`) drop `detail.hints`; the CLI prints the revset hints there (`From<RevsetParseError> for CommandError`). `op diff`'s `resolve_both` (also named) is NOT a gap: the CLI turns that failure into a warning without hints and parses `--show-changes-in` with `user_error_with_message` (no hints) (`operation/diff.rs:203-223`, `:280-310`) — reject.

**Approach:** `resolve_expression` / `evaluate_revset` take an explicit `prefixes: Option<&IdPrefixContext>`; every call site resolving a user/config revset passes the call's context (verbs: from the start-up `TemplateStartup.short_prefixes`; the topology/graph walk: its `short_prefixes` argument; `resolve_revset`: the effective config), the three CLI no-context sites pass `None`. The searches return `Warned<RevsetSearchError>` on the error arm, written onto the error envelope. `CommitViewError`/`BookmarkError` revset variants gain `hints`, mapped to `FfiError.hints`.

## Boundaries & Constraints

**Always:**
- Context = `IdPrefixContext` disambiguated within the effective short-prefixes expression (`graph::prefix_context`); `None` text (empty) = no disambiguation. One context per call where cheap (the topology shares one for log/prio/immutable/anchors and its prefix lengths).
- `None` (no context) exactly where the CLI uses a plain resolver or an empty context: `op_support::resolve_immutable` (`cli_util.rs:1146-1167`), `revset::trunk_resolution_error` (`revset_util.rs:237`), `op_diff::resolve_both` (`diff.rs:251-252`). Each gets a one-line WHY comment.
- `push`'s `immutable_heads` and `git.private-commits` resolve WITH the context (`push.rs:803-811`).
- A short-prefixes set that fails to populate refuses only hex-like symbols with `RevsetResolutionError::Other` — jj-lib's/CLI's behaviour, now for every call.
- Search warnings: the ok arm keeps `RevsetCounts.warnings` / `FoundChanges.warnings`; the error arm carries everything collected before the fault, in order.
- Hints verbatim, CLI order, as `MutateError` already carries them (`mutate.rs::rev`).

**Never:** No new error codes, FFI symbols or schema fields (no codegen expected). No change to change-id/commit-id currency resolution (`resolve_commit`, `resolve_commit_id_prefix`, interdiff — not revset text). No `FfiError.revset` detail for the views/bookmarks (hints only). No Dart API change.

## I/O & Edge-Case Matrix

Medium fixture; `P` = one-char change-id prefix of bookmark `tip`'s commit (ambiguous repo-wide); `cfg` = `revsets.short-prefixes = "tip"` in the repo config.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Reads, no cfg | `eval_revset`/`show`/`evolog`/`list_bookmarks -r`/`resolve_revset` with `P` | refused | `RevsetResolutionError` (ambiguous change id prefix) |
| Reads, cfg | same | resolve to `tip` only | — |
| Topology | revset `P`, `short_prefixes` `""` vs `"tip"`; anchor `P` | `""` refuses; `"tip"` yields `tip` / anchors `tip` | ambiguous refusal |
| Verbs, cfg | `bookmark move --from P`, `bookmark advance` with `revsets.bookmark-advance-to = P`, `workspace add -r P` | act on `tip` | — |
| Oracle | BASE + extras, `short-prefixes = b-mark`, `bookmark move --from <B's 1st char> --to C` | same outcome as the CLI | — |
| Counts error warnings | bad alias entry + `short-prefixes = "bogus("` | `Err(Warned{Config, [config_alias_invalid]})` | envelope `jj.config_error` + warnings |
| Find error warnings | `short_prefixes` `diff_contains("x")`, expression `bogus(` | `Err` with the short-prefixes diagnostic | `jj.revset_parse_error` + warnings |
| View hints | `show`/`evolog`/`bookmark list -r` `descripton(x)` | refused | `hints` holds the "Did you mean" line |

</intent-contract>

## Code Map

All paths relative to `/Users/ralph.bergmann/development/projects/privat/Zanshin`.

**Item 1 — id-prefix context (`crates/zanshin-jj/src`)**
- `revset.rs` — `resolve_expression` (:867-876), `resolve_for_evaluation` (:885-901, doc :882-884 "Only the Story 9.25 searches pass one" → rewrite), `evaluate_revset` (:911-921): add `prefixes` to the first and last. Callers inside: `resolve_revset` (:224-251; build config once: `config::load` → `revset_config` → `template::load_short_prefixes` → `parse_revset_with`), `eval_revset` (:284-319, add a `prefixes: &IdPrefixContext` param), `trunk_resolution_error` (:1055, `None`).
- `template.rs` — `TemplateStartup` (:74-80): add `pub(crate) fn id_prefix_context(&self) -> IdPrefixContext` (= `crate::graph::prefix_context(self.short_prefixes.as_ref())`).
- `graph.rs` — `prefix_context` (:156); `LogParse::evaluate` (:257-270): build the context first, pass it to log/prio/immutable, store it; `LogSetup.prefix_ctx` (:281) → `pub(crate)`.
- `topology.rs:164` — anchors: `evaluate_revset(repo_dyn, expr, Some(&setup.prefix_ctx))`.
- `repo.rs` — `with_verb` closures: `list_bookmarks` (:687), `eval_revset` (:1287), `show` (:2247), `evolog` (:2290) pass `&ctx.template_startup.id_prefix_context()`. Doc of `revset_counts` (:1177-1199) / `find_changes` (:1210-1228) for item 2.
- `commit_views.rs` — `show` (:417, evaluate :430), `evolog` (:479, :492): new `prefixes` param.
- `bookmarks.rs` — `list_bookmarks` (:486, evaluate :511): new param; internal caller at :670 (test helper).
- `bookmark_ops.rs` — `move` (:646), `advance` (:741), `advance_target` (:675-696 → `push::single_commit`): `ctx.template_startup.id_prefix_context()`.
- `push.rs` — `Planner` (:707-722, built at :1370): add `prefixes: IdPrefixContext` from `template_startup`; `CommitsValidator::new` immutable (:513) and private (:519); `collect_ids` (:742) and `single_commit` (:1000) take `prefixes`; `resolve_single` (:986-988).
- `workspace_add.rs:304-330` `resolve_some_revsets` (has `ctx`).
- `mutate.rs:2077` absorb destinations (has `ctx`; build the context before `plan_absorb`).
- `arrange.rs:280-301` `target_expression` (has `ctx`).
- `op_support.rs:90`, `op_diff.rs:264`: `None` + WHY.
- jj-lib 0.46 `revset.rs:2837-2900` `CommitPrefixResolver`/`ChangePrefixResolver` (populate failure → `Other`).

**Item 2 — search warnings on error**
- `crates/zanshin-jj/src/revset_search.rs` — `revset_counts` (:182), `find_changes` (:223), `finish` (:282-294) → `Err(Warned { value: e, warnings: sink.take() })`; module/field docs (:46-49, :71-74). `crate::Warned` is `warning.rs:319`.
- `crates/zanshin-ffi/src/revset_search.rs` — both externs (:241-244, :296-299) map `Warned` → `map_search_err(w.value).with_report(CallReport::warnings(w.warnings))` (one helper); module doc (:8-10) "on the ok arm" → both arms; `# Errors` unchanged. `FfiErrorObj::with_report` keeps the revset detail (`envelope.rs`).
- Test homes: `crates/zanshin-jj/tests/it/revset_search.rs` (err-arm matches at :206-211, :254-273, :338-341, :383, :406-407, :426 need `.value`); `crates/zanshin-jj/tests/it/api_stability.rs` (pins `revset_counts`/`find_changes` signatures — grep `RevsetSearchError`); FFI inline tests (:305-454); `packages/zanshin_core/test/worker/revset_search_test.dart` (real cdylib; `ZanshinFfiException.warnings` is decoded by `precondition.dart::decodeEnvelopeErrorInternal`).

**Item 3 — view/bookmark hints**
- `crates/zanshin-jj/src/commit_views.rs` — `CommitViewError::RevsetParseError`/`RevsetResolutionError` (find by name, ~:190-216) gain `hints: Vec<String>`; `rev` (:231-243) fills them from `detail.hints`; `res`/`res_commit` (:252, :275) pass `Vec::new()`; inline tests :634-706.
- `crates/zanshin-jj/src/bookmarks.rs` — `BookmarkError` revset variants + `rev` (:232-241); inline tests :730-745.
- `crates/zanshin-jj/src/drop_actions.rs:245-247` — pass the hints through to `MutateError`; test :732-739.
- `crates/zanshin-ffi/src/commit_views.rs:38-53`, `crates/zanshin-ffi/src/bookmarks.rs:28-43` — set `FfiErrorObj.hints`; tests :530-537 / :350-354.
- Pattern sites to add `..` / `hints`: `crates/zanshin-jj/tests/it/{arg_refusals.rs:246, commit_views.rs:531,631,639,651,825,833,1309, workspace_ops.rs:114, bookmarks.rs:1083,1089, api_stability.rs:814-818,1023-1024}`.

**Oracle (`crates/zanshin-parity/tests/oracle`)**
- `scenarios.rs` — `BASE` (:44-52), `Scenario`/`simple` (:79-113), `bookmark_move_scenarios` (:2999, `bookmark_move_from` at :3041-3068 is the template); `main.rs` `parity!` list (:55+); `state.rs` `State` (:60-91) — add `pub fn change_ids(&self) -> impl Iterator<Item = &str>` over `labels.of_change` keys.

**Docs**
- `docs/rust-error-codes.md` :56-57 (`jj.revset_parse_error` / `jj.revset_resolution_error`: hints now also from show/evolog/bookmarks; the 2026-10-25 note "not so for revset_counts/find_changes" generalises to every call), the warnings section if it lists the searches' warnings arm.
- `docs/ffi-abi.md` — the searches' warnings (:1546 area, :1635-1642 "id-prefix context"), the graph topology section's `short_prefixes` (now also resolves symbols).

## Tasks & Acceptance

**Execution:**
1. `crates/zanshin-jj/src/revset.rs`, `template.rs`, `graph.rs`, `topology.rs` -- add the `prefixes` params, `TemplateStartup::id_prefix_context`, the topology's shared context; update docs -- item 1 core.
2. `crates/zanshin-jj/src/{repo,commit_views,bookmarks,bookmark_ops,push,workspace_add,mutate,arrange,op_support,op_diff}.rs` -- pass the call's context at each site (or `None` + WHY at the three CLI no-context sites) -- item 1 reach.
3. `crates/zanshin-jj/tests/it/id_prefix_context.rs` (new, registered in `tests/it/main.rs`) -- every I/O row of item 1 except the oracle -- the context is observable per surface.
4. `crates/zanshin-parity/tests/oracle/{scenarios,main,state}.rs` -- scenario `bookmark_move_from_short_prefix`: setup = `jj config set --repo revsets.short-prefixes b-mark` + extra commits off root (`jj new --no-edit 'root()' -m E`, then `jj duplicate 'subject(exact:"E")'` repeated until B's first change-id char is shared; the Zanshin closure asserts another commit's change id starts with that char) -- CLI parity witness. *(As built: ids are random per oracle repo (not seeded), so a change-id collision was flaky (~29 %); the scenario uses B's one-hex-char COMMIT-id prefix against 256 HIDDEN commits (8 duplicate doublings, then abandoned — unlabelled, still indexed), failure chance ≈ 7e-8, and asserts the full-index ambiguity via jj-lib; `State::commit_arg`.)*
5. `crates/zanshin-jj/src/revset_search.rs`, `repo.rs` docs, `crates/zanshin-ffi/src/revset_search.rs`, their tests, `packages/zanshin_core/test/worker/revset_search_test.dart` -- item 2 (`Warned` error arm onto the envelope; Rust, FFI-unit and real-cdylib Dart assertions).
6. `crates/zanshin-jj/src/{commit_views,bookmarks,drop_actions}.rs`, `crates/zanshin-ffi/src/{commit_views,bookmarks}.rs`, the pattern sites above -- item 3; tests: zanshin-jj integration (show/evolog/bookmark list `descripton(x)` carry the "Did you mean" hint) and FFI mapper unit tests (hints reach `FfiErrorObj.hints`).
7. `docs/rust-error-codes.md`, `docs/ffi-abi.md` -- dated 2026-10-25 notes for all three items.

**Acceptance Criteria:**
- Given `revsets.short-prefixes = "tip"` and the one-char prefix `P` of `tip`'s change id, when `show`, `evolog`, `eval_revset`, `list_bookmarks(revisions: [P])`, `bookmark_move(from: [P])` or `workspace_add(revisions: [P])` runs, then it resolves `P` to `tip` exactly as the CLI does; without the config it refuses the ambiguous prefix.
- Given the oracle scenario, when both sides run `bookmark move --from <prefix> --to C`, then the oracle reports no divergence.
- Given a call-level failure of `zanshin_revset_counts` / `zanshin_find_changes` after a warning, when Dart receives the error, then `ZanshinFfiException.warnings` holds that warning.
- Given `zanshin_show` with `descripton(x)`, when it fails, then `FfiError.hints` holds the CLI's "Did you mean" line.

## Spec Change Log

## Review Triage Log

### 2026-10-25 — Review pass
- verdicts: 26 findings — high 0, medium 3, low 18, false 5, maybe-false 0
- findings:
  - `[medium]` `[patch]` (verification-gap) Push, absorb, arrange and `bookmark-advance-from` resolve through the context with no witness — patched: `id_prefix_context.rs` gained without/with pairs for absorb `into`, `bookmark-advance-from` and arrange (see Auto Run Result); push stays unwitnessed directly, but its `collect_ids`/`single_commit` path is the one `bookmark-advance-to`'s witness drives.
  - `[low]` `[patch]` (verification-gap) The topology's `prioritize` through the context is unpinned — patched: the topology test asserts `prioritize = P` refuses with `""` and succeeds with `"tip"`.
  - `[low]` `[defer]` (intent) Reading 1B: `interdiff`'s commit/change-id prefixes (not revset text) still resolve without the context, unlike the CLI's `resolve_single_rev` — pre-existing deliberate divergence outside the three items; deferred and mirrored.
  - `[low]` `[reject]` (intent) Only one oracle scenario for a cross-cutting change — every surface goes through the same two helpers (`resolve_expression`/`evaluate_revset`), each surface has a zanshin-jj without/with witness, and the oracle scenario proves the CLI agrees on the shared path; a scenario per verb adds ~12 s each for no new mechanism.
  - `[medium]` `[patch]` (intent) Changed sites with no witness (push, absorb, arrange, advance-from, prioritize) — same root as the first verification-gap row; patched there.
  - `[low]` `[reject]` (intent) No FFI/Dart test for item 1 — the FFI wrappers pass the `Repo` result through unchanged (no FFI code changed for item 1); a cdylib test would re-test zanshin-jj.
  - `[low]` `[patch]` (intent) The "without" witnesses run with the `revsets.log` fallback context, not no context — patched: they write `short-prefixes = ""`.
  - `[false]` `[reject]` (intent) Item 2's shape (`Warned` on the error arm only) diverges from the ledger's options — the intent offers the options with "or" and fixes the outcome at the envelope, which the diff reaches.
  - `[low]` `[reject]` (intent) Item 3's hints are not checked through the cdylib — the hint vector is encoded by the shared `build_ffi_error` path that `MutateError` and topology hints already cross end to end (Story 9.25's `graph_test.dart`); the mappers are unit-tested.
  - `[false]` `[reject]` (intent) The views/bookmarks get hints but no `FfiError.revset` — the intent asks for `detail.hints` "the way `mutate.rs::rev` does", which carries no detail.
  - `[low]` `[reject]` (blind) A fresh `IdPrefixContext` per site re-populates the index — performance only and lazy (populated only for an id-prefix-shaped symbol or prefix lengths); a shared `OnceCell` adds lifetime plumbing through `VerbContext`/`Templates`.
  - `[low]` `[reject]` (blind) `sign_before_push` takes a `(templates, prefixes)` tuple and a fresh context — cosmetic; behaviour is identical (same effective set).
  - `[low]` `[patch]` (blind) The oracle scenario stays green if disambiguation broke on both sides — patched: the Zanshin closure asserts the move succeeded.
  - `[low]` `[reject]` (blind) Parity covers one verb — same as the intent row above.
  - `[medium]` `[patch]` (blind) `id_prefix_context.rs` misses push/absorb/arrange/advance-from/topology-failed-load and the `None` sites — grouped with the first verification-gap row (patched); negative tests for the `None` sites rejected: a short id prefix inside `immutable_heads()`/`trunk()`/`--show-changes-in` is contrived, and each site carries a WHY comment citing the CLI.
  - `[low]` `[patch]` (blind) `medium("")` does not disable short-prefixes — same as the intent row; patched.
  - `[low]` `[patch]` (blind) `resolve_revset`'s rustdoc misses the new `Config` failure and the prefix resolution — patched (doc).
  - `[low]` `[patch]` (blind) `Warned`'s doc still names only handle-less verbs — patched (doc); a `Display`/`Error` impl rejected: new public surface no caller needs.
  - `[false]` `[reject]` (blind) Hints added but the structured detail dropped — the intent asked for hints only (item 3's ledger follow-up).
  - `[low]` `[reject]` (blind) No end-to-end Dart test of the new hints — same as the intent row above.
  - `[low]` `[defer]` (blind) `zanshin_interdiff` remains an undocumented exception — same root as the intent 1B row; deferred and mirrored.
  - `[false]` `[reject]` (blind) ffi-abi.md per-function entries not updated — the registry rows (`docs/rust-error-codes.md`) and the topology/search sections carry the change, which is where the file records cross-cutting behaviour; the per-function entries state nothing the change contradicts.
  - `[low]` `[patch]` (blind) `CommitViewError::RevsetResolutionError::hints` doc omits the missing-working-copy arm — patched (doc).
  - `[false]` `[reject]` (blind) The two warning channels of the pinned searches are unexplained — `Repo::revset_counts`/`find_changes` docs already say they are op-pinned `&self` reads that leave `take_warnings` untouched, and the module doc now says warnings ride both arms.
  - `[low]` `[patch]` (edge-case) "only a hex-like symbol then refuses" — jj-lib's change-id resolver populates too — patched: "an id-prefix-shaped symbol (commit or change id)" in `repo.rs` and `revset.rs`.
  - `[low]` `[patch]` (edge-case) ffi-abi.md's "every read and verb … uses the effective one" ignores the `None` sites — patched: the sentence names the immutable set, the `trunk()` check and `op diff`'s `--show-changes-in` as resolving without one, as the CLI.

## Design Notes

- Explicit `Option<&IdPrefixContext>` on `resolve_expression`/`evaluate_revset` (not a default) so every call site states its CLI counterpart; the compiler finds them all.
- `Warned<RevsetSearchError>` on the error arm only (the ok types keep their `warnings` field) — the smallest public change; it mirrors `ConfigOutcome`'s "warnings on success AND failure".
- Oracle collision: change ids are deterministic under the pinned env; pigeonhole over 16 letters does not guarantee B's letter collides, hence the closure's explicit precondition assert.

## Verification

**Commands (gate rule: no `cargo make test`/`test-full`/`coverage`):**
- `cargo test -p zanshin-jj --test it` -- all pass
- `cargo test -p zanshin-jj --lib` -- all pass
- `cargo test -p zanshin-ffi --lib` and `cargo test -p zanshin-ffi --test it revset_search_ffi:: commit_views graph_ffi:: bookmarks` -- pass
- `cargo test -p zanshin-parity --test oracle` -- pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- clean
- `flutter test test/worker/revset_search_test.dart`, `dart analyze`, `dart format --set-exit-if-changed .` in `packages/zanshin_core` -- clean

**Verification notes (2026-10-25, after the review patches; the full gate deliberately not run, per the story loop's gate rule):**
- `cargo test -p zanshin-jj --test it` — 1391 passed, 1 ignored.
- `cargo test -p zanshin-jj -p zanshin-ffi --lib` — 389 + 229 passed.
- `cargo test -p zanshin-ffi --test it` — 384 passed.
- `cargo test -p zanshin-parity --test oracle` — 444 passed (incl. `bookmark_move_from_short_prefix`; that scenario also ran 5× in a row green, and with a probe passing `None` in `bookmark move` it reported UNEXPECTED outcome/bookmarks/ops — probe reverted).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean.
- `packages/zanshin_core` (run from the package root, native assets need it): `flutter test test/worker/revset_search_test.dart` — 5 passed; `dart analyze` — no issues; `dart format --set-exit-if-changed .` — 0 changed.
- No FFI/schema change → no `cargo make codegen`. Coverage not measured (gate rule).

## Auto Run Result

Status: done. Code commit `0bad0549a32e857642a92300f8830e63289b66f6`.

**Items:**
1. **fixed** (`0bad0549a32e857642a92300f8830e63289b66f6`) — `resolve_expression`/`evaluate_revset` take an explicit `Option<&IdPrefixContext>`; every user/config revset resolves through the effective `revsets.short-prefixes` context (`TemplateStartup::id_prefix_context()`): the topology/graph walk (log, prioritize, immutable, anchors — one shared context from its `short_prefixes` argument), `eval_revset`, `resolve_revset`, show/evolog, bookmark list/move/advance (to and from), workspace add `-r`, absorb `into`, `arrange::target_expression`, and push (user revsets, default targets, `git.private-commits`, `immutable_heads`, sign-on-push). `None` + WHY at the CLI's own no-context sites: `op_support::resolve_immutable`, `trunk_resolution_error`, `op_diff::resolve_both`. Oracle scenario `bookmark_move_from_short_prefix` + `tests/it/id_prefix_context.rs` witnesses.
2. **fixed** (`0bad0549a32e857642a92300f8830e63289b66f6`) — `Repo::revset_counts`/`find_changes` return `Result<_, Warned<RevsetSearchError>>`; the error carries the warnings collected before the fault; FFI `map_warned_err` writes them onto the error envelope (`ZanshinFfiException.warnings` in Dart, tested through the cdylib).
3. **fixed** for show/evolog and the bookmark list (`0bad0549a32e857642a92300f8830e63289b66f6`) — `CommitViewError`/`BookmarkError` revset variants gained `hints`, mapped to `FfiError.hints` (and through `drop_actions::view_err`). **rejected for `op diff`'s `resolve_both`**: the CLI prints no revset hints there — a resolution failure becomes the hint-less "Could not resolve revset expression for elision" warning, and a `--show-changes-in` parse error is wrapped by `user_error_with_message`, which adds none (`cli/src/commands/operation/diff.rs:203-223`, `:280-310` @ v0.46.0).

**Files changed:**
- `crates/zanshin-jj/src/revset.rs`, `template.rs`, `graph.rs`, `topology.rs` — the context parameter, `TemplateStartup::id_prefix_context`, the topology's shared context, docs.
- `crates/zanshin-jj/src/{repo,commit_views,bookmarks,bookmark_ops,push,workspace_add,mutate,arrange,op_support,op_diff}.rs` — the call sites; `repo.rs` also the `Warned` signatures and docs.
- `crates/zanshin-jj/src/revset_search.rs`, `warning.rs` — `Warned` error arm; doc.
- `crates/zanshin-jj/src/{commit_views,bookmarks,drop_actions}.rs`, `crates/zanshin-ffi/src/{commit_views,bookmarks,revset_search}.rs` — hints and the warned error mapping, with unit tests.
- `crates/zanshin-jj/tests/it/id_prefix_context.rs` (new) + pattern updates in `api_stability`, `arg_refusals`, `bookmarks`, `commit_views`, `revset_search`, `workspace_ops`.
- `crates/zanshin-parity/tests/oracle/{scenarios,main,state}.rs` — the scenario, count 425, `State::commit_arg`.
- `packages/zanshin_core/test/worker/revset_search_test.dart` — warnings on the error through the cdylib.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` — dated 2026-10-25 notes.

**Review (one pass, 26 findings):** 12 patch rows (3 medium in one group: witnesses for absorb/advance-from/arrange; low: prioritize witness, `short-prefixes = ""` for the no-context halves, oracle success assert, `resolve_revset`/`Warned`/`hints`/id-prefix-shaped wording docs, ffi-abi qualification); 2 deferred rows (one entry: interdiff's id prefixes without the context, mirrored into `deferred-work.md`); rejected: one oracle scenario only (shared helpers, per-surface witnesses), no FFI/Dart test for item 1 (pass-through), hints not checked through the cdylib (shared encoder already crossed), item 2's shape (intent offered alternatives), no `FfiError.revset` for views (not asked), fresh context per site (perf only, lazy), `sign_before_push` tuple (cosmetic), `None`-site negative tests (contrived), `Display` impl for `Warned` (new surface), per-function ffi-abi entries (registry carries it), two warning channels (already documented).

**Follow-up review recommendation:** `false` — one `medium` entry patched (test witnesses only), no `high`.

**Residual risks:**
- Push's own `Planner.prefixes` initialisation has no direct witness; its `collect_ids`/`single_commit` path is driven by the `bookmark-advance-to` witness.
- The oracle scenario relies on 256 hidden commits making B's first hex char ambiguous; the chance it does not is ≈ 7e-8 per run, and the scenario then fails loudly (asserted), never passes vacuously.
- A failing short-prefixes set now refuses id-prefix-shaped symbols in every call (CLI behaviour), where the topology previously only warned.
