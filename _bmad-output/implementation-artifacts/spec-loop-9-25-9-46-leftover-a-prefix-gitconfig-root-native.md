---
title: 'Leftover run A after the story loop 9.25–9.46 — interdiff id prefixes, Git config stamp, parallelize at the root, native-backend remote list'
type: 'bugfix'
created: '2026-10-26'
status: 'done'
baseline_revision: '7e510328ee0981e8067657db701ff2e035587924'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings:
  - multiple-goals
  - oversized
deferred:
  - summary: >-
      The house change-id currency outside interdiff (`op_support::resolve_commit` — show, evolog, every mutation verb) bypasses the id-prefix context, refuses odd-length prefixes, and panics in jj-lib on an ambiguous even-length short id.
    evidence: |-
      `resolve_commit` builds a `ChangeId` from the reverse hex and calls `repo.resolve_change_id`, which is a prefix lookup that hits `panic!("complete change_id should be unambiguous")` on `AmbiguousMatch` (jj-lib 0.46.0 `src/repo.rs:140-150`); `try_from_reverse_hex` fails on odd lengths. The CLI resolves every `-r` through `ChangePrefixResolver` with the short-prefixes context and refuses an ambiguous prefix. Read from the code, not reproduced. GUI callers pass full ids.
    location: >-
      crates/zanshin-jj/src/op_support.rs resolve_commit
    severity: medium
    resolved: >-
      2026-10-26 — fixed (spec-loop-9-25-9-46-leftover-c-change-prefix-divergent-native-remotes, commit 0e180acb90953e44f0928e053d787c8f9b82930a): one change-id resolver (the CLI's `ChangePrefixResolver`) takes every call's short-prefixes context; odd lengths resolve, an ambiguous prefix refuses with jj-lib's text, the panic is gone (reproduced first); oracle scenarios added.
  - summary: >-
      A divergent change id is `jj.change_not_found` where the CLI raises `DivergentChangeId` (`jj.revset_resolution_error`, with the targets as hints); not on project-context.md's deliberate-divergence list.
    evidence: |-
      `resolve_commit` / `resolve_change_id_prefix` collapse more than one visible target to `NotFound`; jj-lib 0.46.0 `src/revset.rs` `ChangePrefixResolver::resolve_symbol` raises `RevsetResolutionError::DivergentChangeId`. Pre-existing.
    location: >-
      crates/zanshin-jj/src/op_support.rs
    severity: low
    resolved: >-
      2026-10-26 — fixed (spec-loop-9-25-9-46-leftover-c-change-prefix-divergent-native-remotes, commit 0e180acb90953e44f0928e053d787c8f9b82930a): a divergent change refuses `DivergentChangeId` (`jj.revset_resolution_error`) with the CLI's three hints on every single-revision argument; oracle scenario added.
  - summary: >-
      `git_push_remotes` / `git_fetch_remotes` still answer `[]` on a native backend while `list_remotes` now refuses `jj.not_a_git_repo`.
    evidence: |-
      `Repo::git_push_remotes` doc: "No match is `Ok(vec![])` … and so is a non-Git (native) backend"; the push/fetch verbs themselves refuse `NotAGitRepo`. Neither query has a CLI verb of its own. Pre-existing.
    location: >-
      crates/zanshin-jj/src/repo.rs git_push_remotes / git_fetch_remotes
    severity: low
    resolved: >-
      2026-10-26 — fixed (spec-loop-9-25-9-46-leftover-c-change-prefix-divergent-native-remotes, commit 0e180acb90953e44f0928e053d787c8f9b82930a): both queries refuse `jj.not_a_git_repo` on a native backend; a Git backend with no match stays `Ok([])`.
---

<intent-contract>

## Intent

**Problem:** Four ledgered divergences from the jj CLI @ v0.46.0, each decided by Ralph on 2026-10-26 (deferred-work.md): (1) `interdiff`'s `from`/`to` (`RevisionRef`) resolve without the `revsets.short-prefixes` id-prefix context; (2) an open handle never sees a terminal `git remote add` / `git config` because jj-lib's GitBackend keeps the gix config snapshot it took at load; (3) `Repo::parallelize` with the root commit in its set panics in jj-lib (`internal.panic` over FFI); (4) `list_remotes` on a native backend returns `[]` where `jj git remote list` refuses.

**Approach:** (1) resolve both `RevisionRef` arms through the call's `TemplateStartup::id_prefix_context()` (jj-lib's own `IdPrefixIndex`, whose full-index fallback keeps hidden commits resolvable) + two oracle scenarios; (2) stamp `<git dir>/config` (mtime + length) beside the `store/git_target` bytes and reload when either differs; (3) refuse a set containing the root with the immutability refusal before jj-lib is reached; (4) a new `RemoteError::NotAGitRepo` → `jj.not_a_git_repo` through FFI and Dart, FR-JJ-9's AC reworded.

## Boundaries & Constraints

**Always:** CLI semantics at v0.46.0 (`git -C ../jj show v0.46.0:<path>`); the no-change path of item 2 stays a few `stat`s (no reload when nothing changed) and covers the op-pinned reads (`follow_git_target`) the same way; existing error codes only (no new code, no schema field); tests for every new branch; docs that describe the old behavior are updated (rustdoc, `docs/ffi-abi.md`, `docs/rust-error-codes.md`, Dart doc comments, project-context.md's deliberate-divergence list for item 3).

**Never:** No change to the mutation verbs' `ChangeId` resolution (`op_support::resolve_commit`) — item 1 is `RevisionRef` only; no upstream report for item 3; no full gate (`cargo make test` / `test-full` / `coverage`) in this run; no new FFI symbol.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| 1 commit prefix in set | `interdiff(from: CommitId(<1 hex>), ..)`, prefix unique within `revsets.short-prefixes`, ambiguous repo-wide | resolves to the in-set commit | — |
| 1 change prefix in set | `from: ChangeId(<1 reverse-hex char>)`, same shape | resolves (odd length accepted, as the CLI) | — |
| 1 hidden commit | full/unique commit-id prefix of a hidden commit | still resolves (full-index fallback) | — |
| 1 ambiguous change prefix | change prefix ambiguous within the set or repo-wide | refuses, no panic | `CommitViewError::RevsetResolutionError` (jj-lib's `AmbiguousChangeIdPrefix` text) |
| 1 broken disambiguation set | `revsets.short-prefixes = 'missing'`, a present side | refuses | `RevsetResolutionError`, reason "Failed to resolve short-prefixes disambiguation revset: …" |
| 2 external git config edit | open handle; `[remote "ext"]` appended to `<git dir>/config` | next `list_remotes` lists `ext`; op-pinned read reloads once too | — |
| 2 nothing changed | two calls, no edit | no reload (same store `Arc`) | — |
| 3 root in set | `parallelize([root])` or `[root, x]` | refused, no operation written | `MutateError::Immutable { commit_id: root, hints: [] }` |
| 4 native backend | `list_remotes()` on `Repo::init(.., backend None)` | refused | `RemoteError::NotAGitRepo` → `jj.not_a_git_repo` |
| 4 git backend, no remote | git-backed repo | `Ok([])` unchanged | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/op_support.rs:684-760` -- `CommitPrefixError` + `resolve_commit_id_prefix` (bare `repo.index().resolve_commit_id_prefix`, doc calls it a DELIBERATE divergence — rewrite). Only caller: `commit_views.rs:314`.
- `crates/zanshin-jj/src/commit_views.rs:258-335` -- `res`, `res_commit`, `resolve_side`, `plan_interdiff`; `interdiff` at :586 (gets `workspace`, `sink`, sides — add the id-prefix context). Called from `repo.rs:2629` `Repo::interdiff` (`with_verb(INTERDIFF, |repo, ctx|` — `ctx.template_startup.id_prefix_context()`) and `drop_actions.rs:372-376` (row closure `|tx, _ctx|` → use `ctx`).
- jj-lib 0.46.0 `src/id_prefix.rs:139-253` -- `IdPrefixContext::populate` → `IdPrefixIndex::{resolve_commit_prefix, resolve_change_prefix}`; `IdPrefixIndexLoadError` (:44-49). `src/revset.rs:2842-2910` -- the CLI's `CommitPrefixResolver`/`ChangePrefixResolver` (populate lazily per symbol, `AmbiguousCommitIdPrefix(prefix.hex())`, `AmbiguousChangeIdPrefix(prefix.reverse_hex())`, populate failure → `RevsetResolutionError::Other`). `HexPrefix::try_from_reverse_hex` takes odd lengths; `repo.resolve_change_id` panics on an ambiguous short id (`repo.rs:149`).
- `crates/zanshin-jj/src/template.rs:74-89` -- `TemplateStartup::id_prefix_context()`; `graph.rs:156` `prefix_context`.
- `crates/zanshin-parity/tests/oracle/scenarios.rs:3134-3175` -- `bookmark_move_from_short_prefix`: the 256-hidden-commit setup to copy for `interdiff_from_short_commit_prefix` / `interdiff_from_short_change_prefix`; register both in `main.rs`'s `parity!` list (~:278).
- `crates/zanshin-jj/src/repo.rs:206-233,273-315,360-385,2053-2093,2199-2221` -- `Repo.git_target`, `read_git_target`, `load_effective`, `refresh_settings`, `load_workspace_again`, `follow_git_target`, `toggle_colocation`: every read/compare of the stamp. Inline tests `a_rewritten_git_target_reloads_the_workspace` / `follow_git_target_reloads_only_on_changed_bytes` (~:5056-5098) are the pattern.
- `crates/zanshin-jj/src/config.rs:1384-1394` -- private `FileStamp` + `stamp(path)` (path, mtime, length): make `pub(crate)` and reuse. jj-lib's GitBackend opens `store_path.join(<git_target bytes>)` (`git_backend.rs:330-345`); `jj_lib::file_util::path_from_bytes` decodes them.
- `crates/zanshin-jj/src/parallelize.rs:43-69` -- targets resolved, `needs_rewrite` built, `guard_rewritable` at :69. The root has no parents; `transform_descendants` → `new_parents(&[])` asserts. `op_support::check_rewritable` (:122-142) already refuses the root with empty hints. `Repo::parallelize` doc in `repo.rs`.
- `crates/zanshin-jj/src/remotes.rs:1-153` -- module doc (:9-10), `RemoteError` (:72-81), `list_remotes` (:132-153, `unwrap_or_default` at :139); CLI `cli/src/commands/git/remote/list.rs:37` (`get_git_repo(..)?` first). `repo.rs:~830-851` `Repo::list_remotes` doc. `mutate.rs:296-301` `MutateError::NotAGitRepo` ("not a git repository").
- `crates/zanshin-ffi/src/remotes.rs:32-42,72-100,395-405` -- `map_remotes_err`, `zanshin_remotes` doc, inline mapping test; `JJ_NOT_A_GIT_REPO` from `crate::envelope` (see `repo.rs:195`).
- `crates/zanshin-jj/tests/it/remotes.rs:56-79` -- `remotes_on_native_backend_returns_empty` (flip to the refusal); `api_stability.rs:444` (add the variant).
- `packages/zanshin_core/test/worker/remotes_test.dart:43-65` -- two `backend: 0` (native) empty-list tests → `backend: 1, noColocate: true`; add a native refusal test. Doc comments: `lib/src/worker/isolate.dart:976-983`, `lib/src/worker/handle.dart:~344-348`.
- `_bmad-output/planning-artifacts/epics.md:1693,1711-1714` -- Story 2.9's native-backend ACs (the ledger says 3.4b; the AC text lives in 2.9); `prd.md:207` FR-JJ-9 row.
- `docs/ffi-abi.md:634` (`zanshin_remotes` codes), `docs/rust-error-codes.md:51` (`jj.not_a_git_repo` emitters), plus any interdiff text there naming the full-index divergence.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/op_support.rs` -- `resolve_commit_id_prefix` takes the populated `IdPrefixIndex` and uses `resolve_commit_prefix`; add a change-prefix twin (`HexPrefix::try_from_reverse_hex`, `resolve_change_prefix`, visible single target else not found, ambiguous → its own outcome); docs rewritten; inline tests.
- `crates/zanshin-jj/src/commit_views.rs` -- `resolve_side`/`plan_interdiff`/`interdiff` take `&IdPrefixContext`, populate lazily for a present side, map ambiguity and populate failure to `RevsetResolutionError`; docs.
- `crates/zanshin-jj/src/repo.rs`, `crates/zanshin-jj/src/drop_actions.rs` -- pass the call's context.
- `crates/zanshin-parity/tests/oracle/scenarios.rs`, `main.rs` -- the two interdiff short-prefix scenarios.
- `crates/zanshin-jj/tests/it/` (interdiff module) -- prefix-in-set, change prefix, hidden commit, ambiguous change prefix, broken short-prefixes.
- `crates/zanshin-jj/src/config.rs`, `repo.rs` -- Git stamp (target bytes + `<git dir>/config` stamp) replaces the bytes-only field at every site; inline tests for refresh + follow; integration test: external `[remote]` append is listed by the open handle.
- `crates/zanshin-jj/src/parallelize.rs` -- root in the set joins the rewritable check; integration test (root alone, root + child): `Immutable` with root id, op log unchanged; `project-context.md` deliberate-divergence bullet.
- `crates/zanshin-jj/src/remotes.rs`, `zanshin-ffi/src/remotes.rs`, tests, Dart tests/docs, `docs/*.md`, `prd.md`, `epics.md` -- item 4; `cargo make codegen` if the FFI doc change regenerates bindings.

**Acceptance Criteria:**
- Given each I/O-matrix row, when its test runs, then it passes; given the parity oracle, when it runs, then the two new scenarios match the CLI (both succeed) with no new ledger entry.
- Given an unchanged repo, when two calls run on one handle, then the store `Arc` is the same (no reload).
- Given the change, when `cargo clippy --all-targets -D warnings`, `cargo fmt --all --check`, the touched crates' tests and `packages/zanshin_core`'s `flutter test`/`dart analyze`/`dart format` run, then all pass.

## Spec Change Log

## Review Triage Log

### 2026-10-26 — Review pass
- verdicts: 28 findings — high 0, medium 1, low 23, false 4, maybe-false 0
- findings:
  - `[low]` `[patch]` (verification-gap) the drop/change-actions interdiff row's use of the short-prefixes context is untested; `interdiff_rows_agree_with_interdiff` sees only full ids — added a `revsets.short-prefixes = "missing"` case where row and verb both refuse with `RevsetResolutionError`.
  - `[low]` `[patch]` (verification-gap) `docs/rust-error-codes.md`'s `jj.config_error` row still says `zanshin_interdiff` reads no config (bare index lookup) — sentence rewritten to the context resolution.
  - `[low]` `[reject]` (edge) a malformed side with an unresolvable `revsets.short-prefixes` reports the set's failure, where the CLI parses the prefix first — needs both a broken disambiguation set and a malformed typed id; the fix threads a new error variant through both resolvers.
  - `[low]` `[patch]` (edge) only `<git dir>/config` is stamped (global/system/include/`config.worktree` edits stay invisible) while the docs claim any `git config` — Ralph's decision names exactly that file; docs narrowed to "the repository's own Git config file" plus a `shortcut:` comment naming the limit.
  - `[low]` `[patch]` (edge) mtime+length misses a same-length edit inside one mtime tick — APFS mtimes are nanosecond; named in the same `shortcut:` comment (hashing would cost a read per call, against "keep the no-change path cheap").
  - `[low]` `[patch]` (edge) rust-error-codes `jj.config_error` row — same finding as the verification-gap row, same patch.
  - `[low]` `[reject]` (edge) the spec's task promises inline tests for the op_support resolvers, none exist — every arm runs through the `tests/it/commit_views.rs` interdiff tests (malformed, empty, unknown, only-hidden, divergent, ambiguous, in-set); the claim, not the code, differs.
  - `[medium]` `[defer]` (blind) `op_support::resolve_commit` (show/evolog/every mutation verb) still panics on an ambiguous even-length short change id (jj-lib `repo.rs:149`) — pre-existing, outside `RevisionRef`; deferred and mirrored (with the next two rows: one root, the house change-id currency bypasses the prefix resolver).
  - `[low]` `[defer]` (blind) a divergent change is `jj.change_not_found` where the CLI raises `DivergentChangeId` (`jj.revset_resolution_error`) — pre-existing collapse of the change-id currency, not on the deliberate-divergence list; deferred and mirrored.
  - `[low]` `[defer]` (blind) `ChangeIdRef` now resolves prefixes through the set while the same string in `show`/`restore`/… does not — same root as the panic row; the interdiff docs (`envelope.fbs`, `commit_views.dart`) already describe the interdiff behavior accurately.
  - `[low]` `[patch]` (blind) the drop-actions row changed without a test, and `docs/ffi-abi.md` (~:2011) names only `jj.change_not_found` for its refusal — test as in the verification-gap row; doc names `jj.revset_resolution_error` too.
  - `[low]` `[reject]` (blind) every drop-actions call now evaluates the short-prefixes revset — the CLI evaluates it for every command resolving a symbol; jj-lib caches it per context (`OnceCell`).
  - `[low]` `[patch]` (blind) the Git stamp watches only `<git dir>/config` while docs say any `git config` — same patch as the edge row.
  - `[low]` `[patch]` (blind) mtime+length blind spot — same `shortcut:` comment.
  - `[low]` `[reject]` (blind) `list_remotes` opens the Git repo twice and its `get_all_remote_names` error arm is unreachable — jj-lib's `get_all_remote_names` is `get_git_repo` + `iter_remote_names` (the CLI's own UTF-8 filter); a second gix handle clone per call is negligible and the shared helper keeps the name filter in one place.
  - `[false]` `[reject]` (blind) `NotAGitRepo` drops jj-lib's message, envelope carries no `context` — the registry fixes `jj.not_a_git_repo` as context-free for the workspace case (`MutateError::NotAGitRepo` → `(JJ_NOT_A_GIT_REPO, None)`, every `zanshin_git_*` wrapper); same shape here.
  - `[low]` `[patch]` (blind) `jj.not_a_git_repo`'s Meaning column still describes only a path — widened to an open workspace without a git backend.
  - `[low]` `[reject]` (blind) the oracle compares only the success paths — the oracle compares refused/warning counts, not refusal text (project-context.md § zanshin-jj); the stock CLI cannot create a native-backend repo, so no remote-list refusal scenario is possible.
  - `[low]` `[reject]` (blind) the interdiff scenarios sit in `bookmark_move_scenarios()` — they share that group's fixture constant; placement is cosmetic and every id is checked by `every_scenario_has_a_test`.
  - `[low]` `[reject]` (blind) no test resolves a divergent or hidden-only change THROUGH the disambiguation set — needs a set holding a divergent pair or a hidden commit; jj-lib's own branch, mapped to the same `NotFound` as the tested whole-index path.
  - `[low]` `[reject]` (blind) the hidden-commit fallback uses `v1`'s full hex, not a short prefix — a short prefix of a random id may collide; the fallback code path (set `NoMatch` → whole index) is the same for any length.
  - `[low]` `[patch]` (blind) `map_remotes_err_not_a_git_repo_maps_to_its_code` checks neither `hints` nor `report` — both asserted.
  - `[low]` `[defer]` (intent) interdiff's `ChangeIdRef` vs the rest of the API's change-id currency (reading R1b) — same root as the deferred panic row; the ledger follow-up the intent quotes names `RevisionRef` (reading R1a, implemented).
  - `[false]` `[reject]` (intent) a broken `revsets.short-prefixes` is a new interdiff failure mode — it is the CLI's (`CommitPrefixResolver::try_resolve` → `RevsetResolutionError::Other`), the behavior the item asks for.
  - `[false]` `[reject]` (intent) the op-pinned public reads are covered only through the private `follow_git_target` — every op-pinned read calls that one helper first (9.45 closing pattern), and its inline test edits the config.
  - `[low]` `[patch]` (intent) prd.md's FR-JJ-9 note lacks Ralph's name — now "(Ralph, 2026-10-26)".
  - `[low]` `[defer]` (intent) `git_push_remotes` / `git_fetch_remotes` still answer `[]` on a native backend while `list_remotes` refuses — pre-existing, outside the four items (no CLI verb of their own; the push/fetch verbs refuse `NotAGitRepo`); deferred and mirrored.
  - `[false]` `[reject]` (intent) whether other verbs give empty hints at the root is unshown — `check_rewritable` gives the root no hints for every verb (`op_support.rs:134-136`), as the CLI's root refusal.
  - (verification-gap layer: one gap, patched above.)

## Design Notes

Item 1 follows the CLI's resolvers literally: `context.populate(repo)` only when a side is present (an absent side is `@`), `PrefixResolution::AmbiguousMatch` → jj-lib's own `RevsetResolutionError::Ambiguous{Commit,Change}IdPrefix(..)` text, a populate error → `RevsetResolutionError` with `flatten_chain` of jj-lib's error. The change arm keeps its existing collapse of unknown / hidden-only / divergent to `ChangeNotFound`. Item 3: pushing the root id into `needs_rewrite` before `guard_rewritable` reuses `check_rewritable`'s root branch (empty hints) — the stock CLI panics, so no oracle scenario is possible; the divergence is recorded in project-context.md instead of the ledger.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib` and `cargo test -p zanshin-jj --test it -- remotes:: interdiff parallelize api_stability` -- all pass
- `cargo test -p zanshin-ffi --lib remotes` -- pass
- `cargo test -p zanshin-parity --test oracle` -- pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- clean
- `flutter test test/worker/remotes_test.dart`, `dart analyze`, `dart format --set-exit-if-changed .` in `packages/zanshin_core` -- pass

## Auto Run Result

Status: done

**Items (all fixed by b46a0302d87bb0e8723aacdb0c2e3cac4388b938, none rejected — each verified against the code first):**
1. `interdiff` id prefixes — FIXED (b46a030). Both `RevisionRef` arms resolve through the call's `TemplateStartup::id_prefix_context()` (`op_support::resolve_commit_id_prefix` takes the populated `IdPrefixIndex`; new twin `resolve_change_id_prefix`; `CommitPrefixError` → `PrefixError`), populated lazily for a present side; ambiguity → jj-lib's `Ambiguous{Commit,Change}IdPrefix` text, a set that does not resolve → `RevsetResolutionError` "Failed to resolve short-prefixes disambiguation revset: …"; the drop/change-actions interdiff row uses the same context. Oracle: `interdiff_from_short_commit_prefix`, `interdiff_from_short_change_prefix` (shared `SHORT_PREFIX_HIDDEN_COMMITS` setup, also used by `bookmark_move_from_short_prefix`). The mutation verbs' change-id currency (`resolve_commit`) is deferred (below).
2. Git config snapshot — FIXED (b46a030). `Repo.git_stamp` (`GitStamp`: `store/git_target` bytes + `config::stamp` of `<git dir>/config`) replaces the bytes-only field in `load_effective`, `refresh_settings`, `load_workspace_again`, `follow_git_target` (op-pinned reads) and `toggle_colocation`; no change = one read + one `stat`.
3. `parallelize` at the root — FIXED (b46a030). A set containing the root pushes it into the rewritable check → `MutateError::Immutable { root, hints: [] }`, nothing written; project-context.md lists it as a deliberate divergence (the stock CLI panics, so no oracle scenario or ledger entry).
4. Native-backend `list_remotes` — FIXED (b46a030). `RemoteError::NotAGitRepo` (from `get_git_repo(..)` first, as `list.rs:37` @ v0.46.0) → `jj.not_a_git_repo` (no context) in `zanshin-ffi`; Dart docs/tests; prd.md FR-JJ-9 and epics.md Story 2.9's native-backend ACs (the text the ledger attributed to 3.4b lives in 2.9) reworded with "(Ralph, 2026-10-26)".

**Files changed:** `crates/zanshin-jj/src/{op_support,commit_views,drop_actions,repo,config,parallelize,remotes}.rs`; `crates/zanshin-jj/tests/it/{commit_views,drop_actions,parallelize_arrange,remotes,api_stability}.rs`; `crates/zanshin-ffi/src/{remotes,commit_views}.rs`; `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs`; `schemas/envelope.fbs` + `cargo make codegen` output (`zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart` — doc comments only); `packages/zanshin_core/lib/src/{ffi/commit_views.dart,worker/handle.dart,worker/isolate.dart}`, `test/worker/remotes_test.dart`; `docs/ffi-abi.md`, `docs/rust-error-codes.md`; `_bmad-output/{project-context.md,planning-artifacts/prd.md,planning-artifacts/epics.md}`; this spec and `deferred-work.md` (ledger commit).

**Review:** one pass, 28 findings (1 medium, 23 low, 4 false). 11 patch rows, applied by the implementer: drop-actions interdiff row test under an unresolvable `revsets.short-prefixes` (row and verb refuse alike), an unparseable short-prefixes case (`jj.config_error` at call start), `docs/rust-error-codes.md` `jj.config_error` and `jj.not_a_git_repo` rows, `docs/ffi-abi.md` drop-row refusal text, Git-stamp docs narrowed to the repository's own config file + a `shortcut:` comment (unwatched files, same-length edit inside one mtime tick), prd.md "(Ralph, 2026-10-26)", `hints`/`report` asserts in the FFI mapping test. 4 deferred rows → 3 ledger items (mirrored into deferred-work.md "Surfaced in leftover run A after the story loop 9.25–9.46"). Rejected with reasons in the triage log: malformed-side-before-populate ordering (needs a broken set plus a malformed id), inline-test claim, drop-actions populate cost, double Git open in `list_remotes`, `NotAGitRepo` context, oracle refusal text, scenario placement, two extra resolver test shapes, and the four `false` rows. Follow-up review: false (patched: 0 high, 0 medium, 11 low).

**Verification (targeted, per the run's gate rule — no `cargo make test` / `test-full` / `coverage`):**
- `cargo test -p zanshin-jj --lib` — 412 passed (before and after the review patches).
- `cargo test -p zanshin-jj --test it` — full suite 1461 passed, 1 ignored (implementer, pre-patch); after the patches `-- commit_views:: drop_actions remotes::` 134 passed and `-- remotes:: commit_views:: parallelize_arrange:: api_stability:: drop_actions` 186 passed.
- `cargo test -p zanshin-ffi --lib remotes` — 6 passed; `cargo test -p zanshin-ffi --test it -- remotes interdiff drop_actions` — 24 passed.
- `cargo test -p zanshin-parity --test oracle` — 493 passed (both new scenarios match the CLI, no ledger entry; the review patches touched no verb code).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` and `cargo fmt --all --check` — clean.
- `cargo make codegen` — run by the implementer; only doc comments regenerated, committed.
- `packages/zanshin_core`: `flutter test test/worker/remotes_test.dart` 7 passed; `dart analyze` no issues; `dart format --set-exit-if-changed .` 0 changed.

**Residual risks:** coverage not measured in this run (the loop's final gate measures it); the new resolvers' `Backend` arms have no failing-index test; the Git stamp sees only `<git dir>/config` by mtime+length (documented `shortcut:`).
