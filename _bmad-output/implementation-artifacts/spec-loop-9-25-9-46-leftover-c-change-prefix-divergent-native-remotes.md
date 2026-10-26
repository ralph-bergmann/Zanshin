---
title: 'Leftover run C after the story loop 9.25–9.46 — change-id prefixes through the short-prefixes context, divergent change refusal, native-backend default remotes'
type: 'bugfix'
created: '2026-10-26'
status: 'done'
baseline_revision: '16d1be55932d6e92de5c577f0605359f419b0f1d'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings:
  - multiple-goals
  - oversized
deferred:
  - summary: >-
      Every change-id argument (including `get_change`, which the GUI calls per selection) now evaluates the effective `revsets.short-prefixes` (default `revsets.log`) to build the disambiguation index; the per-call cost on a large repo is unmeasured.
    evidence: |-
      Unverified (maybe-false). `op_support::resolve_change` populates the call's `IdPrefixContext` for every present id, as the CLI's `ChangePrefixResolver` does once per command; before this run `get_change` and the mutation verbs did a bare index lookup. Settled by timing `Repo::get_change` with a full id on a 10k-commit repo against the pre-change baseline.
    location: >-
      crates/zanshin-jj/src/op_support.rs resolve_change; crates/zanshin-jj/src/change.rs get_change
    severity: medium (unverified)
    resolved: >-
      2026-10-26 — fixed (spec-loop-9-25-9-46-leftover-d-short-prefix-cost-file-no-wc, commit c2318ca4dc68cdb9cc797bc48f4f033254275bf0): measured, about +1.5 ms per get_change call on large-10k (loose and packed) vs 16d1be5, below 5 ms, so no code change; bench benches/get_change.rs.
  - summary: >-
      The file reads report an omitted revision in a workspace without a working-copy commit as `jj.invalid_input`, where the CLI raises `WorkspaceMissingWorkingCopy` (`jj.revset_resolution_error`, as the mutation verbs and commit views map it).
    evidence: |-
      `crates/zanshin-jj/src/file.rs` `res` maps `ResolveError::NoWorkingCopy` to `FileError::InvalidInput`; `mutate::res` / `commit_views::res` map it to `RevsetResolutionError`. `FileError::RevsetResolutionError` exists since this run. Pre-existing; left alone as outside the three items.
    location: >-
      crates/zanshin-jj/src/file.rs res
    severity: low
    resolved: >-
      2026-10-26 — fixed (spec-loop-9-25-9-46-leftover-d-short-prefix-cost-file-no-wc, commit c2318ca4dc68cdb9cc797bc48f4f033254275bf0): file.rs res maps NoWorkingCopy to FileError::RevsetResolutionError (jj.revset_resolution_error, no hints) for all four file reads.
---

<intent-contract>

## Intent

**Problem:** Three ledgered CLI divergences deferred by leftover run A (deferred-work.md "Surfaced in leftover run A after the story loop 9.25–9.46"; decided like the CLI, Ralph 2026-10-23): (1) the house change-id currency (`op_support::resolve_commit` — every mutation verb, the file reads, select-tree, resolve-list, bookmark verbs — and `change::get_change`) resolves with `repo.resolve_change_id`, bypassing the `revsets.short-prefixes` id-prefix context, refusing odd-length prefixes and PANICKING in jj-lib on an ambiguous even-length short id (`jj-lib 0.46.0 src/repo.rs:140-150`, `panic!("complete change_id should be unambiguous")`); (2) a divergent change id is `jj.change_not_found` where the CLI raises `RevsetResolutionError::DivergentChangeId` (`jj.revset_resolution_error`, three hints); (3) `git_push_remotes` / `git_fetch_remotes` answer `[]` on a native backend where `list_remotes` and the push/fetch verbs refuse `jj.not_a_git_repo`.

**Approach:** (1+2) one change-id resolver — the CLI's `ChangePrefixResolver` (`lib/src/revset.rs:2881-2948` @ v0.46.0, minus the `/offset` form): validate the reverse hex first (malformed/empty → not found, no populate), then populate the call's id-prefix context, resolve the prefix (ambiguous → jj-lib's `AmbiguousChangeIdPrefix` text), zero visible → not found, one → the commit, several → jj-lib's `DivergentChangeId { symbol: <caller's text>, visible_targets }` text with the CLI's `revset_resolution_error_hints` (house port `revset::resolution_hints`); every caller passes its call's context; each family maps the new outcome to its `RevsetResolutionError`-coded variant. (3) `push::default_remote_names` refuses `MutateError::NotAGitRepo` when the backend is not Git, as `push.rs:814` does.

## Boundaries & Constraints

**Always:** CLI semantics at v0.46.0 (`git -C ../jj show v0.46.0:<path>`, jj-lib read from `~/.cargo/registry/src/*/jj-lib-0.46.0`); ONE shared resolver in `op_support` (no per-family copy); the context is built once per verb call where a call resolves several ids, never re-populated per id; reasons are jj-lib's own error values' `to_string()` (never retyped wording); a divergent `ChangeIdRef` of `interdiff` and a drop/change-actions row refuse the same way (shared resolver); existing error codes only (`jj.change_not_found`, `jj.revset_resolution_error`, `jj.not_a_git_repo`); the `get_change` read keeps Decision D4 for a divergent id (first visible target + `Change::divergent`, it is no CLI `-r`) but goes through the context and never panics; tests for every new branch, the panic reproduced by a test FIRST (run against the unchanged code, observe the panic, then fix); docs describing the old behavior updated (rustdoc, `docs/rust-error-codes.md`, `docs/ffi-abi.md`, Dart doc comments in `packages/zanshin_core`, `envelope.fbs` comments if any name the collapse).

**Never:** No `/offset` change-id syntax, no bookmark/tag/commit-id fallback in the change-id currency; no new FFI symbol, schema field or error code; no change to how `show`/`evolog`/`eval_revset` resolve their revsets; no full gate (`cargo make test` / `test-full` / `coverage`) in this run; no remap of `ResolveError::NoWorkingCopy` in `file.rs` (pre-existing `jj.invalid_input`, out of scope).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| 1 even ambiguous prefix (the panic) | a verb (e.g. `describe`) and `get_change` with a 2-char change prefix shared by two changes, both outside `revsets.short-prefixes` | refused, no panic, nothing written | `RevsetResolutionError`, reason ``Change ID prefix `<id>` is ambiguous``; `get_change` → `ChangeError::RevsetResolutionError` |
| 1 odd prefix in set | 1-char change prefix ambiguous repo-wide, unique within `revsets.short-prefixes` | resolves to the in-set change (verb succeeds) | — |
| 1 odd prefix, no set | unique 1-char (or 3-char) prefix with `revsets.short-prefixes = ""` | resolves (odd length accepted) | — |
| 1 unknown / hidden-only / malformed | no change, only hidden commits, non-reverse-hex, empty | unchanged | `ChangeNotFound` (each family's) |
| 1 malformed with a broken set | `revsets.short-prefixes = 'missing'`, id `"xyz!"` | not found (validated before populate, as the CLI) | `ChangeNotFound` |
| 1 broken set, valid id | `revsets.short-prefixes = 'missing'`, a valid present id | refused | `RevsetResolutionError`, reason "Failed to resolve short-prefixes disambiguation revset: …" (jj-lib error + chain, `mutate::flatten_chain`) |
| 1 omitted revision | `@` default (`resolve_or_wc(None)`) with a broken set | `@`, no populate | — |
| 2 divergent | a change with two visible commits, passed to a mutation verb, a file read, `interdiff` (`ChangeIdRef`), a drop/change-actions row | refused, nothing written | `RevsetResolutionError`, reason ``Change ID `<id>` is divergent``, hints `["Use change offset to select single revision: <id>/<o1>, <id>/<o2>", "Use `change_id(<id>)` to select all revisions", "To abandon unneeded revisions, run `jj abandon <commit_id>`"]` |
| 2 divergent `get_change` | same, `get_change` | `Ok`, `divergent: true` (D4 unchanged) | — |
| 3 native backend | `git_push_remotes()` / `git_fetch_remotes()` on `Repo::init(.., backend None)` | refused | `MutateError::NotAGitRepo` → `jj.not_a_git_repo` (no context) |
| 3 git backend, no remote | git-backed repo | `Ok([])` (warning for the implicit `origin` unchanged) | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/op_support.rs:606-656` -- `ResolveError` (`NotFound`/`NoWorkingCopy`/`Backend`) + `resolve_commit(repo, id)` (the panic path, `repo.resolve_change_id`). Add a resolution outcome (e.g. `ResolveError::Resolution { reason, hints }`) and an `&IdPrefixContext` parameter. `:658-683` `resolve_ordered`, `:216-234` `resolve_commit_location`, `:784-810` `resolve_or_wc` forward it. `:685-782` `PrefixError` / `resolve_commit_id_prefix` / `resolve_change_id_prefix` (leftover run A): the change twin is the base — it already uses `IdPrefixIndex::resolve_change_prefix`; give it the divergent outcome (`visible_with_offsets`, `at_most_one` as `revset.rs:2938-2946`) and the validate-before-populate order.
- `crates/zanshin-jj/src/revset.rs:839-879` -- private `resolution_hints(&RevsetResolutionError)` (the CLI's `revset_resolution_error_hints`, DivergentChangeId arm at :848-861): make `pub(crate)` and reuse.
- `crates/zanshin-jj/src/mutate.rs:629-641` `res` (+ `:674-688` the two wrappers), `commit_views.rs:261-325` `res`/`res_change`/`short_prefixes_failed`/`resolve_side`, `file.rs:~240-251` `res` -- the three family mappings. `FileError` (`file.rs:~176-220`) has no resolution variant: add `RevsetResolutionError { reason, hints }` and map it in `crates/zanshin-ffi/src/file.rs:28-44` `map_file_err` to `JJ_REVSET_RESOLUTION_ERROR` with `hints` (extend `map_file_err_covers_every_variant`).
- `crates/zanshin-jj/src/change.rs:156-197` `get_change(workspace, id)` -- same panic (`resolve_change_id` at :184); add an `&IdPrefixContext` param and `ChangeError::RevsetResolutionError { reason, hints }` (`change.rs:111-131`); FFI `crates/zanshin-ffi/src/change.rs:25-41` `map_change_err` → `JJ_REVSET_RESOLUTION_ERROR`. Caller `repo.rs:730-733` `Repo::get_change` (`with_verb(SHOW, |repo, _ctx|` → use `ctx`).
- `crates/zanshin-jj/src/template.rs:74-89,133-213` -- `TemplateStartup::id_prefix_context()` (builds a new, unpopulated context each call; `IdPrefixContext` is not `Clone`); `Templates` stores only `short_prefixes`. For planners that take `&Templates`, a `Templates` accessor returning a context owned by `Templates` (built in `new`) avoids threading a second parameter.
- Call sites (investigated; every one listed — T = has `templates`, C = has `ctx: &mut VerbContext`, N = neither):
  - T: `rebase.rs:104,111,138,140,172,194`; `revert.rs:93,101`; `duplicate.rs:79,113`; `mutate.rs:1026` (describe), `:1188-1190` (new), `:1360` (edit), `:1429` (abandon).
  - C: `diffedit.rs:97-101`; `resolve.rs:374`; `rebase.rs:406`; `wc_ops.rs:628,780,819`; `bookmark_ops.rs:312,638` (already builds `prefixes` at :646 — build it before the resolve and reuse), `:683` (prefixes at :696), `:970`; `simplify_parents.rs:77-78`; `parallelize.rs:44`; `metaedit.rs:167,169`; `duplicate.rs:199`; `arrange.rs:288` (prefixes at :300); `squash_split.rs:696,701-703`; `mutate.rs:1816-1821` (restore), `:1982` (absorb — `mutate.rs:2078` already builds prefixes before `plan_absorb`); `drop_actions.rs:578` (row closure's `ctx`), `:440` (closure passed into `plan_absorb` while `ctx` is borrowed mutably — build `prefixes` before the call and capture it, as `mutate.rs:2078`).
  - N (thread from the first frame with `ctx`): `select_tree.rs:314,317` ← `repo.rs:4320` `Repo::select_tree`; `resolve.rs:260` ← `repo.rs:4353` `Repo::resolve_list`; `squash_split.rs:354` (`source_trees`) and `:384-398` (`resolve_squash`) ← `plan_squash` (C, :287/:302); `arrange.rs:317` (`target_of`) ← `arrange()` :374 (C); `file.rs:271` `head_commit` ← `file_list` :333 / `file_show` :507 / `file_annotate` :596 / `file_search` :726 ← `repo.rs:999,1050,1092,1137`.
- `crates/zanshin-jj/src/push.rs:934-946` -- `default_remote_names`: `let Ok(all_remotes) = get_all_remote_names(..) else { return Ok(Vec::new()) }` → `.map_err(|_| MutateError::NotAGitRepo)?` as `push.rs:814`. Docs: `repo.rs:879-935` (`git_push_remotes` / `git_fetch_remotes` "and so is a non-Git (native) backend", add `NotAGitRepo` under `# Errors`); `push.rs:~877` doc.
- Tests to flip/extend: `crates/zanshin-jj/tests/it/push_remotes.rs:123-135` `a_native_backend_has_none` → the refusal; `git_fetch_parity.rs:535-546` `a_native_backend_is_not_a_git_repo` (last line asserts `[]`). Existing divergent-expects-`ChangeNotFound` tests (grep `divergent` in `crates/zanshin-jj/tests/it/*.rs`, `crates/zanshin-ffi/tests/it/*.rs`, `packages/zanshin_core/test`) encode the old collapse — update them to the refusal. `tests/it/api_stability.rs` (new `FileError`/`ChangeError` variants, changed signatures if public — `get_change` is `pub(crate)`).
- Dart: `packages/zanshin_core/lib/src/worker/handle.dart:~360-395` and `isolate.dart:~1000-1030` doc comments of `gitPushRemotes`/`gitFetchRemotes`; `test/worker/remotes_test.dart` (leftover A's native `listRemotes` refusal test is the template — add one for each of the two). Grep `lib/` for "divergent" docs naming `change_not_found`.
- Oracle: `crates/zanshin-parity/tests/oracle/scenarios.rs:138-150` `SHORT_PREFIX_HIDDEN_COMMITS` and `:3180-3225` `interdiff_from_short_change_prefix` (asserts the 1-char change prefix is ambiguous in the full index) are the template; register new ids in `main.rs`'s `parity!` list (`every_scenario_has_a_test` checks).
- Docs: `docs/rust-error-codes.md:49` (`jj.change_not_found` — every "divergent" sentence), `:57` (`jj.revset_resolution_error` — add the change-id currency, divergent, ambiguous prefix, the file reads and `get_change`), `:51` (`jj.not_a_git_repo` emitters + the two default-remote queries); `docs/ffi-abi.md:635-636,~1891-1997` (the two queries' codes) and any `jj.change_not_found` "divergent" text there.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/tests/it/` (new module, e.g. `change_id_prefix.rs`, declared in `main.rs`) -- FIRST: a test that a 2-char change prefix shared by two changes (pigeonhole: 257 changes guarantee a shared 2-char prefix; set `revsets.short-prefixes = ""`) passed to `describe` and `get_change` refuses — run it against the unchanged code, record the panic in Verification, then fix. Then one test per matrix row 1-2 across a mutation verb, a file read, `select_tree` or `resolve_list`, `interdiff` and a drop/change-actions row.
- `crates/zanshin-jj/src/op_support.rs`, `revset.rs` -- the shared resolver (context param, validate → populate → resolve → visible → divergent), `resolution_hints` reused; inline tests for the new arms where reachable without a fixture.
- `crates/zanshin-jj/src/{template,mutate,commit_views,file,change,repo,bookmark_ops,select_tree,resolve,squash_split,arrange,rebase,revert,duplicate,diffedit,wc_ops,simplify_parents,parallelize,metaedit,drop_actions}.rs` -- pass each call's context; family mappings; `FileError`/`ChangeError` variants; docs.
- `crates/zanshin-ffi/src/{file,change}.rs` -- map the new variants (code + hints), inline mapping tests.
- `crates/zanshin-jj/src/push.rs`, `repo.rs` -- item 3 refusal + docs; flip `push_remotes.rs` / `git_fetch_parity.rs` native tests; an FFI test that `zanshin_git_push_remotes` / `_fetch_remotes` on a native repo answer `jj.not_a_git_repo`.
- `crates/zanshin-parity/tests/oracle/scenarios.rs`, `main.rs` -- scenarios with `SHORT_PREFIX_HIDDEN_COMMITS`: `describe`, `abandon` and `new` each taking B's 1-char change prefix (both sides succeed; assert the prefix is ambiguous in the full index, as `interdiff_from_short_change_prefix`); one divergent scenario (setup e.g. `describe -r b-mark -m B1`, then `--at-op @- describe -r b-mark -m B2`; `describe <B's change id> -m x` refused on both sides).
- `packages/zanshin_core` -- doc comments; native refusal tests for `gitPushRemotes` / `gitFetchRemotes`.
- `docs/rust-error-codes.md`, `docs/ffi-abi.md` -- as the Code Map lists.

**Acceptance Criteria:**
- Given each I/O-matrix row, when its test runs, then it passes; given the parity oracle, when it runs, then every new scenario matches the CLI with no new ledger entry.
- Given the panic test, when it ran against the unchanged code, then it panicked (recorded in Verification); after the change it refuses.
- Given the change, when `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check`, the touched crates' tests and `packages/zanshin_core`'s `flutter test` / `dart analyze` / `dart format --set-exit-if-changed .` run, then all pass.

## Spec Change Log

- 2026-10-26 (implementation): the default `revsets.short-prefixes` is `revsets.log`, which names `immutable_heads()`; with that alias unresolvable a change-id argument now refuses ``Failed to resolve short-prefixes disambiguation revset: …`` before the immutable set's `Config` refusal — verified against the pinned stock CLI (`jj describe <change id> -m x` answers exactly that). Tests whose intent is the immutable-set refusal order (`revert.rs::UNRESOLVABLE_ALIAS` and its users, `mutate.rs`, `op_support.rs`, `drop_actions.rs`, `new_insert.rs`, `when_commands.rs`, oracle `refusal_order.rs`) empty `revsets.short-prefixes`; `change_id_prefix.rs` pins the CLI order. The app's project status (`worker_project_repos.dart`) reads a native repo's `jj.not_a_git_repo` from `gitPushRemotes` as "no push targets" (its native-backend tests read `clean` otherwise).

## Review Triage Log

### 2026-10-26 — Review pass
- verdicts: 31 findings — high 0, medium 0, low 25, false 1, maybe-false 5
- findings:
  - `[low]` `[patch]` (verification-gap) the app adapter's `jj.not_a_git_repo` → `[]` catch has no test that another code is rethrown — added a `worker_project_repos_test.dart` case (native repo, `git.push = 1` → `read()` throws `jj.config_error`).
  - `[low]` `[patch]` (verification-gap) the default-remote queries' config-before-backend order is untested on a native backend — added native + malformed `git.push` / `git.fetch` → `MutateError::Config` tests.
  - `[low]` `[patch]` (verification-gap, other) duplicate `# Errors` headings in `Repo::get_change` and `arrange::target_expression` — prose moved above one heading.
  - `[low]` `[patch]` (blind) the same duplicate headings, and `Repo::get_change`'s summary still says a full id — same patch, summary names the prefix.
  - `[low]` `[patch]` (blind) the mechanical "(a divergent change: …)" doc edits broke the bullets' grammar and left ~61 `///` lines over 120 columns (header churn) — bullets restored, lines rewrapped, codegen re-run.
  - `[low]` `[patch]` (blind) the mutation-verb FFI rustdocs name `jj.revset_resolution_error` only for the divergent case — each change-id wrapper got its own bullet (ambiguous prefix, divergent change, short-prefixes load failure).
  - `[low]` `[patch]` (blind) Dart `RepoHandle` Throws lists of `getChange`/`describe`/`edit`/`abandon`/… and `ffi/change.dart` omit the new refusals — updated.
  - `[low]` `[patch]` (blind) `Templates` builds a second id-prefix context in `Env` and several verbs a third one, populating the short-prefixes set twice per call — `Env` uses `Templates.prefixes`; diffedit, metaedit, parallelize, squash, restore, resolve and the three `wc_ops` verbs resolve through `templates.prefixes()`. Partly: `arrange`, `fix`, `simplify_parents` and `absorb` (+ its drop row) keep their own context, because they pass `&mut ctx` into a helper while the ids' context is borrowed; their second context fills only when the guard refuses and renders its hint.
  - `[maybe-false]` `[defer]` (blind) every change-id argument (incl. `get_change`, per GUI selection) now evaluates the effective `revsets.short-prefixes` (default `revsets.log`) — the CLI does the same per command; the cost on a 10k repo is unmeasured; if-true medium (unverified), settled by timing `get_change` on a 10k-commit repo.
  - `[low]` `[reject]` (blind) the divergent hints suggest `<id>/<offset>` / `change_id(<id>)`, which the change-id currency does not accept — the intent mandates the CLI's message and hints verbatim; how the GUI offers a way out (a commit-id ref, a revset read) is the UI's decision.
  - `[low]` `[patch]` (blind) no test crosses the envelope with the new refusal — one FFI test: a divergent id through a wrapper answers `jj.revset_resolution_error` with the three hints.
  - `[low]` `[reject]` (blind) several rewritten call sites (absorb row `into`, drop bookmark-move `target`, `select_tree`'s `from`, bookmark move/set, squash `source_trees`) have no prefix/divergence test — each only passes its context to the one shared resolver and maps through the shared `mutate::res`; representative sites per family are tested.
  - `[low]` `[reject]` (blind) the oracle has no even-length-ambiguous or broken-short-prefixes scenario — the oracle compares refused/warning counts, not text; a guaranteed shared 2-char prefix needs ~257 changes per repo (not deterministic with the shared hidden-commit setup); the broken-set order was checked by hand against the stock CLI and is pinned in `change_id_prefix.rs`.
  - `[low]` `[patch]` (blind) the `default_remote_names` reorder is untested — same patch as the verification-gap row.
  - `[low]` `[patch]` (blind) `handle.dart`'s `gitFetchRemotes` enable-rule doc disagrees with `Repo::git_fetch_remotes`; the app catch is untested — doc aligned; test as above.
  - `[low]` `[patch]` (blind) `get_change`'s step comments skip 4 — renumbered. (`&visible[0]` cannot panic: `resolve_change` returns `NotFound` for an empty list — that half is false.)
  - `[low]` `[patch]` (edge) `resolve_side`'s `CommitIdRef` arm populates before validating the hex, so a non-hex commit id with a broken `revsets.short-prefixes` reports the load failure instead of `InvalidInput` (the CLI's `CommitPrefixResolver` validates first) — validation moved before the populate, test added.
  - `[low]` `[reject]` (edge) a native repo with a wrong-typed `git.push` now fails the app's project reading with `jj.config_error` — the same as a Git-backed repo with that config and as `jj git push` (config read first); intended.
  - `[low]` `[patch]` (edge) the app catch drops the exception's snapshot `warnings` — now logged as on the success path.
  - `[low]` `[patch]` (edge) `handle.dart` `gitFetchRemotes` doc — same patch as above.
  - `[low]` `[reject]` (edge) `a_unique_odd_prefix_resolves_without_short_prefixes` checks uniqueness among visible changes only — the committed medium fixture is deterministic and is never regenerated (project rule), so a hidden collision cannot appear.
  - `[low]` `[patch]` (edge) the mutation wrappers' FFI `# Errors` miss the ambiguous / load-failure refusals — same patch as the blind row.
  - `[low]` `[patch]` (edge) duplicate `# Errors` headings — same patch.
  - `[false]` `[reject]` (intent) the Auto Run Result, ledger and `resolved:` lines are missing — they are written at finalize, after the review.
  - `[low]` `[reject]` (intent) the intent's evidence names show/evolog as `resolve_commit` callers, unrecorded — the fix is spec text; recorded under Auto Run Result (show/evolog resolve revsets with the context since Story 9.25; the `show`-scoped `get_change` read had the panic and is fixed).
  - `[maybe-false]` `[reject]` (intent) the oracle checks outcomes, not the refusal texts — oracle design (project-context.md § zanshin-jj); the texts are jj-lib's own error values plus the house port of the CLI hints, compared word for word by the auditor; if-true low.
  - `[maybe-false]` `[reject]` (intent) `get_change` keeps D4 for a divergent id where `jj show` refuses — `get_change` is a by-id read, not `jj show <revset>`; D4 is a recorded decision; the divergent refusal applies to every `-r`-shaped argument; if-true low.
  - `[low]` `[reject]` (intent) app code changed outside a story — the adapter keeps a native repo's status reading as before the refusal; surfaced for Ralph under residual risks; the untested-catch half is patched above.
  - `[maybe-false]` `[reject]` (intent) the context populates against the repo it is handed (often `tx.repo()`) rather than the command's base repo — every resolution runs before the verb mutates, where `tx.repo()` equals the base; if-true low.
  - `[maybe-false]` `[reject]` (intent) an index error in `resolve_change_prefix` maps to `jj.jj_lib_error` where the CLI raises `RevsetResolutionError::Other` — an index read failure is a backend I/O fault no everyday use meets; if-true low, the fix adds a branch.
  - `[low]` `[reject]` (intent) the divergent hints name `/offset` syntax the currency refuses — same as the blind row.
  - (layers: verification-gap 3 rows — two gaps, both patched, plus one other finding; blind 13; edge 7; intent 8.)

## Design Notes

CLI order (`ChangePrefixResolver::resolve_symbol`): `try_from_reverse_hex` fails → `Ok(None)` before any populate, so a malformed id never sees a broken short-prefixes set; populate failure → `RevsetResolutionError::Other(IdPrefixIndexLoadError)`; `AmbiguousMatch` → `AmbiguousChangeIdPrefix(prefix.reverse_hex())`; visible targets `at_most_one()` — none → `None` (the house `ChangeNotFound`), several → `DivergentChangeId { symbol: change_id.to_owned(), visible_targets }`. Change ids are reverse hex (z–k), disjoint from commit hex (0–9a–f), so the CLI's commit-prefix resolver never claims a change id first. Sketch:

```rust
let prefix = HexPrefix::try_from_reverse_hex(&id.0).filter(|_| !id.0.is_empty()).ok_or(NotFound)?;
let index = prefixes.populate(repo).map_err(|e| resolution(flatten_chain(&e), vec![]))?;
// SingleMatch(targets) → targets.visible_with_offsets().at_most_one() …
```

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib` -- pass
- `cargo test -p zanshin-jj --test it` -- full `it` suite passes (the change touches every mutation verb)
- `cargo test -p zanshin-ffi --lib` and `cargo test -p zanshin-ffi --test it` -- pass
- `cargo test -p zanshin-parity --test oracle` -- pass, new scenarios included
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- clean
- `cargo make codegen` -- only if `schemas/envelope.fbs` comments change; commit the output
- in `packages/zanshin_core`: `flutter test test/worker/remotes_test.dart` (plus any Dart test touched), `dart analyze`, `dart format --set-exit-if-changed .` -- pass

**Results (2026-10-26):** the panic test `change_id_prefix::an_even_length_ambiguous_prefix_is_refused_not_a_panic`, run against the unchanged code, panicked at `jj-lib-0.46.0/src/repo.rs:149:49` "complete change_id should be unambiguous" — through `describe` and, run first, through `zanshin_jj::change::get_change`; after the change it refuses. `zanshin-jj --lib` 414 ok, `--test it` 1474 ok; `zanshin-ffi --lib` 232 ok, `--test it` 396 ok; parity oracle 497 ok (four new scenarios); clippy (`-p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -D warnings`) and `cargo fmt --all --check` clean; `cargo make codegen` run (envelope.fbs + extern-fn doc comments); `packages/zanshin_core` `remotes_test.dart` ok, `dart analyze` / `dart format` clean; `app` `worker_project_repos_test.dart` ok.

**Parent verification (step-03, same day):** `zanshin-jj --lib` 414 ok, `--test it` 1474 ok (1 ignored); `zanshin-ffi --lib` 232 ok, `--test it` first 395 ok / 1 FAILED (`ffi_abi_doc_sync::every_index_row_names_exactly_the_error_codes_its_rustdoc_bullets_do`: the four `zanshin_file_*` rustdocs named `jj.revset_resolution_error` only inside the `jj.change_not_found` bullet) — fixed with a bullet of its own in each, `cargo make codegen` re-run, `ffi_abi_doc_sync` 17 ok; full parity oracle 497 ok; clippy (three crates, `--all-targets -D warnings`) and `cargo fmt --all --check` clean; `packages/zanshin_core`: `cargo make --allow-private test-core` (the whole `dart test` suite with the pinned env) 1123 ok, `dart analyze` no issues, `dart format --set-exit-if-changed .` 0 changed; `app`: `dart analyze --fatal-infos --fatal-warnings` clean, `dart format` 0 changed, `flutter test test/features/projects/worker_project_repos_test.dart` (pinned env) 32 ok.

**After the review patches (step-04, same day):** `zanshin-jj --lib` 414 ok, `--test it` 1474 ok (1 ignored); `zanshin-ffi --lib` 232 ok, `--test it` 397 ok (incl. `ffi_abi_doc_sync`); full parity oracle 497 ok; clippy (three crates, `--all-targets -D warnings`) and `cargo fmt --all --check` clean; `cargo make codegen` re-run, no further diff; `packages/zanshin_core`: `cargo make --allow-private test-core` 1123 ok, `dart analyze` no issues, `dart format --set-exit-if-changed .` 0 changed; `app`: `dart analyze --fatal-infos --fatal-warnings` clean, `dart format` 0 changed, `flutter test test/features/projects/` (pinned env) 195 ok. No `cargo make test` / `test-full` / `coverage` (gate rule of this run).

## Auto Run Result

Status: done

**Items (each verified against the code first; all fixed by commit 0e180acb90953e44f0928e053d787c8f9b82930a, none rejected):**
1. Change-id currency through the id-prefix context — FIXED (0e180acb90953e44f0928e053d787c8f9b82930a). `op_support::resolve_change` / `resolve_commit` port the CLI's `ChangePrefixResolver` (no `/offset`): reverse hex validated first (malformed/empty → not found, nothing populated), then the call's `revsets.short-prefixes` context populates (failure → ``Failed to resolve short-prefixes disambiguation revset: …``), odd lengths resolve, an ambiguous prefix refuses jj-lib's ``Change ID prefix `…` is ambiguous`` (`jj.revset_resolution_error`). Every caller (all mutation verbs, file reads, select-tree, resolve-list, bookmark verbs, drop/change-action rows, interdiff's `ChangeIdRef`) passes its call's context; `Templates::prefixes()` holds one per `Templates`. `get_change` had the same panic and is fixed the same way (`ChangeError::RevsetResolutionError`); `FileError::RevsetResolutionError` is new; both map to `jj.revset_resolution_error` with hints over FFI. The panic was reproduced first (`change_id_prefix::an_even_length_ambiguous_prefix_is_refused_not_a_panic`, `jj-lib-0.46.0/src/repo.rs:149`). Oracle: `describe` / `abandon` / `new` with B's 1-char change prefix (ambiguous repo-wide, unique within the set). Note on the evidence: `show` / `evolog` are not callers of `resolve_commit` — they resolve revsets with the context since Story 9.25 and are unchanged; the `show`-scoped `Repo::get_change` read is the one that shared the panic.
2. Divergent change — FIXED (0e180acb90953e44f0928e053d787c8f9b82930a). Every single-revision change-id argument refuses jj-lib's ``Change ID `<id>` is divergent`` (`jj.revset_resolution_error`) with the CLI's three hints (`revset::resolution_hints`, now `pub(crate)`, the port of `command_error.rs:938-951` @ v0.46.0); `get_change` keeps Decision D4 (first visible commit, `divergent: true`). Oracle: `describe_divergent_change` (both refuse).
3. Native-backend default remotes — FIXED (0e180acb90953e44f0928e053d787c8f9b82930a). `push::default_remote_names` reads `git.push`/`git.fetch` first, then refuses `MutateError::NotAGitRepo` (`jj.not_a_git_repo`) on a non-Git backend, as the verbs; a Git backend with no match stays `Ok([])`. Rust, FFI and Dart docs/tests; the app's project status reads a native repo's refusal as "no push targets" (logs its warnings; other codes rethrow).

**Side effect (CLI parity, verified against the stock CLI by the implementer):** the default `revsets.short-prefixes` is `revsets.log`, which names `immutable_heads()`; with that alias unresolvable, a change-id argument now refuses with the short-prefixes load error before the immutable-set `Config` refusal (`jj describe <id> -m x` answers the same). Tests whose subject is the immutable-set refusal order set `revsets.short-prefixes = ""`; `change_id_prefix.rs` pins the CLI order.

**Files changed:** `crates/zanshin-jj/src/{op_support,revset,template,mutate,commit_views,file,change,repo,push,bookmark_ops,select_tree,resolve,squash_split,arrange,rebase,revert,duplicate,diffedit,wc_ops,simplify_parents,parallelize,metaedit,drop_actions,fix}.rs` (shared resolver, context threading, new variants, docs); `crates/zanshin-jj/tests/it/{change_id_prefix (new),main,api_stability,bookmark_ops,commit_views,drop_actions,file_reads,git_fetch_parity,mutate,new_insert,op_support,push_remotes,revert,when_commands}.rs`; `crates/zanshin-ffi/src/*.rs` (mappings, rustdoc), `tests/it/{push_remotes_ffi,repo_write_ffi}.rs`, `include/zanshin_ffi.h` + `envelope_generated.rs` (codegen); `crates/zanshin-parity/tests/oracle/{scenarios,main,refusal_order}.rs`; `schemas/envelope.fbs` (comments); `packages/zanshin_core/lib/src/{ffi/bindings.dart,ffi/change.dart,ffi/commit_views.dart,ffi/envelope_zanshin.ffi_generated.dart,worker/handle.dart,worker/isolate.dart}`, `test/worker/remotes_test.dart`; `app/lib/src/features/projects/worker_project_repos.dart`, `app/test/features/projects/worker_project_repos_test.dart`; `docs/{ffi-abi,rust-error-codes}.md`; ledger commit: this spec, `deferred-work.md`, leftover run A's spec.

**Review:** one pass, 31 findings (25 low, 1 false, 5 maybe-false; no high/medium). Patched (all low): duplicate `# Errors` headings + `get_change` summary; FFI/`MutateError` rustdocs restored with their own `jj.revset_resolution_error` bullet per change-id wrapper and ≤120-column lines; Dart Throws lists and the fetch enable-rule doc; one shared prefix context in `Templates` (partly — `arrange`, `fix`, `simplify_parents`, `absorb` keep a second context, borrow-checker bound); `resolve_side`'s commit arm validates before populating; `get_change` step comments; native + malformed-key order tests for both queries; app catch logs warnings + a rethrow test; an FFI envelope test for the divergent refusal. Deferred (mirrored into deferred-work.md "Surfaced in leftover run C …"): the unmeasured per-call short-prefixes cost (medium, unverified); the file reads' `NoWorkingCopy` → `jj.invalid_input` (low, pre-existing, found while planning). Rejected with reasons in the triage log: CLI hints naming `/offset`, per-site prefix tests, oracle text/even-length scenarios, a native repo's bad `git.push` failing the app reading, fixture-uniqueness fragility, the show/evolog evidence note (recorded above), get_change D4, app code outside a story (surfaced below), populate repo, index-error code, process deliverables (false). Follow-up review: false (patched: 0 high, 0 medium, 17 low rows).

**Residual risks:** coverage not measured (the index-error `Backend` arm of `resolve_change` is probably uncovered); the app adapter change (`worker_project_repos.dart`) is app code outside a story — needed so native repos keep reading their status; Ralph should look at it; the per-call populate cost (deferred); four verbs build a second, lazily populated prefix context. The implementer's manual stock-CLI check wrote a scratch repo's config to `~/.config/jj/repos/7a989e9059f476e17caa`, which it then deleted (only that directory).
