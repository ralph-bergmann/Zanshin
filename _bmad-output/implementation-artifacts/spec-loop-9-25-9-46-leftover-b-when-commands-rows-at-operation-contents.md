---
title: 'Leftover run B after the story loop 9.25–9.46 — command scopes for select_tree and the action rows, at_operation() rows through commit_contents, nullable empty'
type: 'bugfix'
created: '2026-10-26'
status: 'done'
baseline_revision: 'aceaef5dd79e69bbc1788a66a4eed3a9680d967b'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings:
  - multiple-goals
  - oversized
deferred: []
---

<intent-contract>

## Intent

**Problem:** Three ledgered divergences from the jj CLI @ v0.46.0, each decided by Ralph on 2026-10-26 (deferred-work.md, sections "Surfaced in Story 9.41" and "Surfaced in Story 9.42"): (1) `select_tree`, `drop_actions` and `change_actions` resolve their config with no CLI command, so a `--when.commands` scope for the verb they serve never reaches their snapshot, tree or preview rows; (2) `graph_topology` returns the rows of an `at_operation(<non-ancestor op>, …)` revset but `commit_contents` refuses their ids (`CommitNotFound`), so the GUI's two-call path cannot load those rows' object half; (3) a merge outside the head index reports `empty: false` where the pinned `jj log` prints an inline template error.

**Approach:** (1) `SelectTreeOptions` gets an optional target verb (append-only wire enum; absent = today's no-command resolution) and the call resolves for that verb's `cli_command`; each `drop_actions` / `change_actions` row plans with a context resolved for its own verb's command (the call's snapshot keeps no command). (2) `GraphTopology` reports the operations its revset's `at_operation()`s brought in; `commit_contents` takes that list (append-only wire field; absent/empty = today) and checks and loads against the pinned index merged with theirs. (3) `CommitMeta.empty` and `CommitContent.empty` become `Option<bool>` / `bool?` — `None` exactly where jj-lib cannot determine it; with item 2's merged index `commit_contents` answers those merges.

## Boundaries & Constraints

**Always:** CLI semantics at v0.46.0 (`git -C /Users/ralph.bergmann/development/projects/privat/jj show v0.46.0:<path>`); every wire change append-only (new fields at the END of their table, new enum with `Unspecified = 0`); an absent new field keeps today's behavior exactly; a row's refusal is exactly the `MutateError` its verb returns — a row whose verb's own config fails to load/parse is that row's refusal (`MutateError::Precondition(PreconditionError::Config{..})`, as the verb's start-up), never a failure of the whole query; a row whose command resolves to the same stack as the call reuses the call's context (no extra `CommandEnv` parse); tests for every new branch; docs describing the old behavior are updated (rustdoc, `cli_command.rs` `NO_COMMAND` doc, `docs/ffi-abi.md` for every wire change, Dart doc comments, the `deferred-work.md`-referenced texts stay untouched until the ledger commit); every Dart consumer of `empty` (zanshin_core lib + tests, app/ — none found there) compiles and passes.

**Never:** no full gate (`cargo make test` / `test-full` / `coverage`) — targeted checks only (below); no new FFI symbol (no extern fn); no change to `walk_graph`'s index (it stays the head's, as `jj log`'s template does — so its out-of-index merge `empty` is `None`); no `sed`/`perl`/`python`/heredoc edits through Bash (use Edit/Write/Serena); `jj` only inside temp dirs a test created, absolute paths, no bare `cd`; no git commits by the implementer (the orchestrator commits).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| 1 select_tree verb scope | user config `[[--scope]] --when.commands=["split"]` with a value that faults the start-up (e.g. `revset-aliases."immutable_heads()"` that does not parse) | `select_tree(verb: Split)` refuses; `select_tree(verb: None)` and `verb: Commit` succeed | the verb's start-up refusal (`MutateError::Precondition(Config)`) |
| 1 select_tree records | `select_tree` with each verb | `repo.command()` = `COMMIT` / `SPLIT` / `SQUASH` / `DIFFEDIT`; none → `NO_COMMAND` | — |
| 1 drop rows scope | `["rebase"]` scope with `revset-aliases."immutable_heads()" = "<expr containing S>"`; drop change S `onto` one T | the three rebase rows Refused `Immutable`; squash / new / duplicate rows Available as without the scope | — |
| 1 card rows scope | `["abandon"]` scope making X immutable | `change_actions(X).abandon` Refused `Immutable`; `describe`, `new_*` Available | — |
| 1 row config fault | `["describe"]` scope whose `immutable_heads()` does not parse | `change_actions(X).describe` Refused with the verb's start-up error; the other rows and the call succeed | row refusal, not query error |
| 1 no scopes | default config | every row as before; call ctx reused (no per-row env parse) | — |
| 2 topology extras | revset `at_operation(<sibling op>, all())` | `GraphTopology.extra_operation_ids == [<sibling op full hex>]`; plain revset → `[]` | — |
| 2 contents with extras | `commit_contents(head op, [sibling op], <every topology id>)` | Ok, every row's object half, request order | — |
| 2 contents without extras | same ids, extras `[]` (or absent on the wire) | refused as today | `CommitNotFound` |
| 2 bad extra op | malformed / unknown extra op id | refused, checked after the pinned op and before commit ids | `InvalidInput` / `OperationNotFound` (same texts as `operation_id`) |
| 3 merge empty, head index | `walk_graph` over `at_operation(<sibling op>, all())`, the sibling merge | `meta.empty == None`; every other row `Some(..)` | — |
| 3 merge empty, merged index | `commit_contents` with the extras, the sibling merge | `empty == Some(<the merge's real emptiness>)` | — |
| 3 wire | `empty == None` | `CommitContent.empty = false, empty_unknown = true` → Dart `empty == null`; `Some(b)` → `empty = b, empty_unknown = false` | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/cli_command.rs:18-25` -- `CliCommand`, `NO_COMMAND` (doc lists select_tree / drop_actions / change_actions — rewrite: only `Repo::open` and the action queries' own snapshot). Table entries already exist for every row verb: `REBASE`, `SQUASH`, `NEW`, `DUPLICATE`, `REVERT`, `RESTORE`, `ABSORB`, `INTERDIFF`, `SPLIT`, `BOOKMARK_MOVE`, `EDIT`, `DESCRIBE`, `ABANDON`, `COMMIT`, `DIFFEDIT`.
- `crates/zanshin-jj/src/repo.rs:3650-3679` -- `Repo::drop_actions` / `change_actions` (`with_verb(NO_COMMAND, |repo, ctx| …(repo.workspace(), ctx, …))` — pass `repo` (a `&Repo`) so rows can resolve configs); docs. `:4294-4303` `Repo::select_tree` (`with_checked_verb(NO_COMMAND, …)` → the verb's command). `:583-645` `with_verb` / `start_command` / `precondition` (how a call ctx is built: `config::load_migrated` + `CommandEnv::load` + trunk fallback). `:5203-5335` inline test `every_verb_resolves_for_its_cli_command` (`records!`): add `select_tree` lines per verb (`:5368` area has the existing `NO_COMMAND` line).
- `crates/zanshin-jj/src/config.rs:1177-1198` -- `config::load_for(repo, command)` (resolves for a command, adds the trunk-fallback layer when the call set it); `:1034` `same_resolution(a, b)`.
- `crates/zanshin-jj/src/snapshot.rs:359-453` -- `CommandEnv::load(workspace, &config, &mut Warnings)` (row scratch warnings, discarded), `VerbContext { config, immutable, template_startup, colocated, auto_stats, warnings }`, `VerbContext::new`; `PreconditionError` (:177).
- `crates/zanshin-jj/src/drop_actions.rs` -- `Rows` (:256), `Rows::row` (:264, every row goes through it), `outcome` (:194, Precondition = query failure — the per-row config fault must bypass it as a refusal), `location_rows` (:415), `with_rows` (:541), `drop_actions` (:559), `change_actions` (:588). Each row picks its command; plan fns read only the ctx (`ctx.templates`, `ctx.immutable`, `ctx.template_startup`, `ctx.config`), not `workspace.settings()` (checked), so a per-row `VerbContext` suffices. Cache one context per distinct command per call.
- `crates/zanshin-jj/src/select_tree.rs:122-137` -- `SelectTreeOptions` (add `verb: Option<SelectTreeVerb>`; new `pub enum SelectTreeVerb { Commit, Split, Squash, Diffedit }` — the verbs with a tree arm: `commit.rs:60`, `squash_split` (split/squash trees), `diffedit.rs:53`), re-export in `lib.rs:142`.
- `crates/zanshin-jj/tests/it/when_commands.rs` -- witness pattern (`isolate`, `init_repo`, `[[--scope]]` TOML, `test_helpers::own_process!` usage there); add select_tree / drop_actions / change_actions witnesses here.
- `crates/zanshin-jj/src/topology.rs:29-44,137-233` -- `GraphTopology` (add `extra_operation_ids: Vec<OperationId>`, from `setup.other_repos` `op_id().hex()`, in their order); `graph.rs:286-300` `LogSetup.other_repos`.
- `crates/zanshin-jj/src/commit_content.rs:138-198` -- `load_pinned`, `commit_contents`: load each extra op with `load_pinned` (same checks/texts) after the pinned op; with extras, start a transaction on the pinned repo and `tx.repo_mut().merge_index(&other)` (jj-lib 0.46.0 `src/repo.rs:2059`, public) for each, then use `tx.repo()` as the `&dyn Repo` for both the `has_id` check and `object_half`; drop the transaction (writes nothing). `CommitContent.empty` (:52) → `Option<bool>`.
- `crates/zanshin-jj/src/repo.rs:1272-1310` -- `Repo::commit_contents(operation_id, commit_ids)` → add `extra_operation_ids: &[OperationId]` (between the two); ~30 call sites: `crates/zanshin-jj/tests/it/{commit_contents,git_colocation,graph_topology}.rs`, `crates/zanshin-ffi/{src/commit_contents.rs,tests/it/commit_contents_ffi.rs,benches/graph_topology.rs}`, `crates/zanshin-jj/README.md`.
- `crates/zanshin-jj/src/commit_meta.rs:96-99,245-282,288-310` -- `CommitMeta.empty` doc + type, `object_half`, `is_empty` (today's out-of-index-merge `Ok(false)` arm → `Ok(None)`), `from_halves`.
- `crates/zanshin-jj/tests/it/graph_topology.rs:479-521` -- `add_unpublished_op` + the sibling-merge test (sibling[2] is the merge): extend/add tests for extras, contents with/without extras, `empty` of the merge both ways; `recompose` helper (compares `CommitMeta`) adapts to `Option`.
- `crates/zanshin-parity/tests/oracle/log_at_operation.rs:20-62` -- `Row = (String, bool, bool)`; CLI template error counted as `false` — make the row's `empty` an `Option<bool>`: the CLI's `<Error: …>` → `None`, Zanshin's `meta.empty` compared directly.
- `schemas/envelope.fbs` -- `SelectTreeRequest` (:322, append `verb: SelectTreeVerb;` + new enum near it, `Unspecified` first, APPEND-only note as `DropSourceKind`), `GraphTopology` (:2012, append `extra_operation_ids: [string];` + doc bullet), `CommitContentsRequest` (:1349, append `extra_operation_ids: [string];` + doc), `CommitContent` (:2901, append `empty_unknown: bool;` + doc: `empty` meaningful only when `empty_unknown` is false). Then `cargo make codegen` (regenerates `crates/zanshin-ffi/src/envelope_generated.rs`, `include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/{envelope_zanshin.ffi_generated.dart,bindings.dart}`).
- `crates/zanshin-ffi/src/select_tree.rs:95-110` (reader: map the enum, `Unspecified` → `None`; an unknown value → `jj.invalid_input` like the other enum readers), `src/graph.rs:368-401` (writer), `src/commit_contents.rs:66-110` (reader + writer), each with inline roundtrip tests.
- `packages/zanshin_core/lib/src/ffi/{select_tree.dart:190,commit_contents.dart:32-128,graph.dart:216-362}`, `lib/src/worker/{commands.dart:1425,2277, isolate.dart:1768,2885,4579,4949, handle.dart:433-440}` -- thread `verb` (Dart enum `SelectTreeVerb`, exported where `SelectedTree` is) and `extraOperationIds` (optional, default empty) through; `GraphTopology` model gets `extraOperationIds`; `CommitContent.empty` → `bool?`. Tests: `test/ffi/{commit_contents_test,graph_test}.dart`, `test/worker/{commit_contents_test,graph_test,select_tree_test}.dart`, `test/graph_layout/support/topology_envelope.dart` if it builds the table.
- `docs/ffi-abi.md:1187-1220` (graph topology), `:1535-1560` (commit contents), `:2187+` (select_tree), plus any drop/change-actions text saying the rows resolve with no command.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/select_tree.rs`, `lib.rs`, `repo.rs` -- `SelectTreeVerb` + `SelectTreeOptions.verb`; `Repo::select_tree` resolves for `verb`'s command (`None` → `NO_COMMAND`); docs; `records!` lines.
- `crates/zanshin-jj/src/drop_actions.rs`, `repo.rs` -- per-row command (a `fn` mapping each row to its `CliCommand`, unit-tested), per-call cache of row contexts built with `config::load_for` + `CommandEnv::load` (reuse the call ctx when `same_resolution`), a context build failure → that row's `Refused` with `MutateError::Precondition(..)`; docs (module doc, `Repo::drop_actions` / `change_actions`, `cli_command.rs`).
- `crates/zanshin-jj/tests/it/when_commands.rs` -- the four item-1 scope rows of the matrix.
- `crates/zanshin-jj/src/{topology,commit_content,commit_meta,repo}.rs` -- items 2 and 3 as in the Code Map; inline tests where a private branch needs one.
- `crates/zanshin-jj/tests/it/graph_topology.rs` (and `commit_contents.rs` for the bad-extra-op rows) -- item 2/3 matrix rows; all `commit_contents` call sites updated.
- `crates/zanshin-parity/tests/oracle/log_at_operation.rs` -- `empty` as `Option<bool>`.
- `schemas/envelope.fbs` + `cargo make codegen`; `crates/zanshin-ffi/src/{select_tree,graph,commit_contents}.rs` + their tests, `tests/it/commit_contents_ffi.rs`, `benches/graph_topology.rs`.
- `packages/zanshin_core` lib + tests as in the Code Map; a worker-level test that `commitContents` with the topology's `extraOperationIds` loads an `at_operation()` row (or, if building such a repo from Dart is impractical, an FFI-level Rust test in `crates/zanshin-ffi/tests/it/commit_contents_ffi.rs` plus Dart decode tests of the new fields).
- `docs/ffi-abi.md` -- every wire change above.

**Acceptance Criteria:**
- Given each I/O-matrix row, when its test runs, then it passes.
- Given a wire buffer without any of the new fields (an old-shape request), when the FFI reads it, then the behavior is today's (select_tree no command, no extras, `empty_unknown` false).
- Given the change, when the targeted checks in Verification run, then all pass.

## Spec Change Log

## Review Triage Log

### 2026-10-26 — Review pass
- verdicts: 31 findings — high 0, medium 0, low 21, false 10, maybe-false 0
- findings:
  - `[false]` `[reject]` (intent) the two-call path answers the out-of-index merge's `empty` (`Some`) where `jj log` errors (reading 3b) — Ralph's decision asks exactly this: "check whether item 2's merged index already lets `is_empty` succeed — null stays for whatever still cannot be determined"; `walk_graph` keeps the CLI's `None`.
  - `[false]` `[reject]` (intent) `CommitMeta` has no FFI field / Dart model (reading 3c) — true, it is not on the wire; the nullable emptiness that crosses is `CommitContent`'s, its object half, which the diff made nullable.
  - `[false]` `[reject]` (intent) the wire carries two bools, not an optional — the house presence-bit form (flatc 25.12.19 has no optional scalar for Dart); Rust and Dart are nullable.
  - `[false]` `[reject]` (intent) the Dart `GraphTopologyView` refuses a topology without `extra_operation_ids` (reading 2b) — the decision's "absent list keeps today's behavior" is the `commit_contents` request; the response vector is always written by the bundled cdylib and decoded under the house rule for such vectors.
  - `[low]` `[patch]` (intent) the Dart extras test uses an ancestor op — same as the verification-gap row; patched there.
  - `[low]` `[patch]` (intent) witnesses cover only some row commands (edit/new none) — same as the verification-gap row; patched there.
  - `[false]` `[reject]` (intent) repo.rs's inline test is extended only for `select_tree` — the action queries' call command is `NO_COMMAND` (their snapshot), recorded there; per-row commands are not a call's command.
  - `[false]` `[reject]` (intent) the row-fault-as-refusal rule goes beyond the intent — it is the "a row's refusal is exactly the verb's" contract the queries already have (the verb refuses at its start-up with the same error, `a_faulting_describe_scope_refuses_the_describe_row_not_the_query`).
  - `[false]` `[reject]` (intent) the spec result and ledger are not in the diff — they land in the ledger commit after review.
  - `[low]` `[patch]` (verification-gap) the Dart worker test of `extraOperationIds` passes with the extras dropped — added an unknown 128-hex extra expecting `jj.operation_not_found` with its CLI text in `commit_contents_test.dart`.
  - `[low]` `[patch]` (verification-gap) the Dart `SelectTreeVerb` wire mapping is never observed — added `a_split_scope_reaches_select_tree_for_the_split_verb_only` (repo config written through `configFileWrite`: `split` refuses `jj.config_error`, `squash` and no verb succeed).
  - `[low]` `[patch]` (verification-gap) per-row command binding witnessed only for rebase/abandon/describe — added `a_faulting_scope_refuses_exactly_the_rows_of_its_command` (one child-process test: for each of the 13 row commands a start-up-faulting scope refuses exactly that command's rows across drop/selection/bookmark/card).
  - `[low]` `[reject]` (edge) rows re-read the config from disk per command, so a mid-call edit could split a query's rows across two stacks — needs an edit inside one call's few milliseconds; the fix (load raw once, resolve per command) restructures `config::load_for`.
  - `[low]` `[reject]` (edge) a failed row context is not cached, so each row of that command re-loads — only on a faulty scoped config; caching needs a cloneable `PreconditionError` or a stored text.
  - `[low]` `[patch]` (edge) the module doc says contexts are "built once per command and call" — now says a failed build is not kept and each row of that command tries again.
  - `[low]` `[patch]` (edge) docs/ffi-abi.md says `empty_unknown` is set for an `at_operation()` merge read without its extras — such an id is refused (`jj.change_not_found`) before any load; the paragraph now says `zanshin_commit_contents` answers only ids in the index it reads and the bit mirrors the shared object half.
  - `[low]` `[patch]` (edge) the Dart extras test cannot fail if the extras are dropped — same as the verification-gap row.
  - `[low]` `[patch]` (blind) `empty_unknown` is never produced by `commit_contents` while docs describe the opposite — same root as the edge row; docs corrected, the nullable type kept for the object half `object_half` shares with `walk_graph` (an unwrap there would be a dead branch).
  - `[false]` `[reject]` (blind) a new CLI divergence (two-call `Some` vs `jj log` error) needs Ralph's decision — it is Ralph's 2026-10-26 decision (see the first intent row); the README documents the one row where topology+contents no longer recompose `walk_graph`.
  - `[low]` `[reject]` (blind) per-row config loads are expensive on drag-hover — about a dozen small TOML parses per call, cheaper than the rebase rows' dry-run rebases the same call already runs; a "no scopes at all" fast path adds a branch.
  - `[low]` `[reject]` (blind) failed row context not cached — same as the edge row.
  - `[false]` `[reject]` (blind) `borrow_mut` held across `plan` would panic on a nested row — no plan calls a row; a reentrant call that does not exist is not a defect.
  - `[low]` `[patch]` (blind) rows swap only `VerbContext`, the transaction keeps the call's `UserSettings` — `shortcut:` comment added in `Rows::row_context` (no row outcome reads a setting the transaction holds today).
  - `[low]` `[patch]` (blind) `zanshin_drop_actions` / `zanshin_change_actions` rustdoc silent on per-row resolution and the in-row `jj.config_error` — both docs extended (regenerated into the header and `bindings.dart`).
  - `[false]` `[reject]` (blind) docs/ffi-abi.md pins the row refusal to `jj.config_error` though it could be `jj.jj_lib_error` — `config::load_for`'s `ConfigError` and every `CommandEnv::load` arm are `PreconditionError::Config`, which maps to `jj.config_error`.
  - `[low]` `[reject]` (blind) a context fault is a refusal while a plan's `Precondition` fails the query — no plan fn returns `Precondition` (they run after the snapshot); the module doc states the context rule.
  - `[low]` `[patch]` (blind) the Dart extras test cannot fail — same as the verification-gap row.
  - `[low]` `[patch]` (blind) the Dart `SelectTreeVerb` tests cannot detect a wrong mapping — same as the verification-gap row.
  - `[low]` `[reject]` (blind) the two mapping tests restate the match tables — they cost a few lines and pin the table against a silent edit; the scope witnesses now cover the behaviour too.
  - `[low]` `[reject]` (blind) `commit_contents` with extras re-loads each extra op and re-merges per page, unbenched — only for `at_operation()` revsets, a rare log filter; a bench case is more than a direct correction.
  - `[low]` `[patch]` (blind) `commit_content.rs`' module doc does not mention the extras — now names the merged index on a dropped transaction.

## Design Notes

Item 1: the action queries' own pre-verb snapshot stays `NO_COMMAND` — no single CLI command corresponds to the query, and every row's verb snapshots again when it actually runs. A row's context is the CLI's start-up for that verb minus the snapshot: its resolved config (with the call's trunk-fallback layer, `load_for`) and its start-up environment. The trunk-fallback decision itself is taken once for the call's (no-command) stack — a `trunk()` redefined only in a command scope is not re-checked per row (accepted; name it in a `shortcut:` comment).

Item 2: the CLI renders an `at_operation()` row in full from the store (`log.rs:161`, `ResolvedRevset::evaluate`); Zanshin's two-call path needs the operations to rebuild the index the topology evaluated against. jj-lib's own merge (`ResolvedRevset::merge_indexes`) is private; `MutableRepo::merge_index` on a dropped transaction is the public equivalent (starts from the pinned repo's readonly index, merges each other repo's).

Item 3: `walk_graph` keeps the head index (the CLI's template repo), so its out-of-index merge is `None` = the CLI's inline error; `commit_contents` with the extras answers it (`Some`) because its merged index has the common ancestors — the "check whether item 2's merged index already lets `is_empty` succeed" of the decision. `recompose`-style comparisons of topology+contents vs `walk_graph` therefore differ only on that row; tests must not assert equality there.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib` -- pass
- `cargo test -p zanshin-jj --test it -- when_commands:: graph_topology:: commit_contents:: graph:: drop_actions select_tree git_colocation:: api_stability::` -- pass
- `cargo test -p zanshin-ffi --lib` and `cargo test -p zanshin-ffi --test it -- commit_contents select_tree graph drop_actions` -- pass
- `cargo test -p zanshin-parity --test oracle` -- pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` and `cargo fmt --all --check` -- clean
- `cargo make codegen` -- run after the schema change; its output committed with the code
- in `packages/zanshin_core`: `flutter test`, `dart analyze`, `dart format --set-exit-if-changed .` -- pass; `dart analyze` in `app/` -- no new issues

## Auto Run Result

Status: done

**Items (all fixed by 51c9d2423992844f944db6f4c414b99286903ac5, none rejected — each verified against the code first):**
1. `select_tree` / `drop_actions` / `change_actions` command scopes — FIXED (51c9d24). Verified: all three passed `cli_command::NO_COMMAND` (`repo.rs`). `SelectTreeOptions.verb: Option<SelectTreeVerb>` (`Commit` / `Split` / `Squash` / `Diffedit`, the verbs with a tree arm; wire `SelectTreeRequest.verb`, enum with `Unspecified = 0` = today's no-command resolution, an unknown value `ffi.invalid_argument` like every FFI enum reader) resolves the call for that verb's command. Each action row plans with the context of its own verb's command (`DropVerb::command()`, `EDIT` / `DESCRIBE` / `ABANDON` for the card), built once per command and call with `config::load_for` + `CommandEnv::load`, the call's context reused when `same_resolution`; a row whose verb's start-up config fails is that row's `Refused` with the verb's own `MutateError::Precondition(Config)`. The queries' own snapshot stays no-command. Witnesses in `tests/it/when_commands.rs` (split scope → `select_tree`, rebase rows, abandon row, faulting describe row, and one test covering all 13 row commands); `records!` lines for every `SelectTreeVerb`.
2. `at_operation()` rows through `commit_contents` — FIXED (51c9d24). Verified: `commit_content.rs` refused every id outside the pinned index. `GraphTopology.extra_operation_ids` (the `at_operation()` operations, full hex; wire field appended, always written); `Repo::commit_contents(operation_id, extra_operation_ids, commit_ids)` checks each extra like the pinned op, then checks and loads against the pinned index merged with theirs (`MutableRepo::merge_index` on a dropped transaction — nothing written); `CommitContentsRequest.extra_operation_ids` appended, absent = today (`CommitNotFound` / `jj.change_not_found`).
3. Nullable `empty` — FIXED (51c9d24). Verified: `is_empty` returned `Ok(false)` for an out-of-index merge. `CommitMeta.empty` and `CommitContent.empty` are `Option<bool>`; `walk_graph` (head index, as `jj log`'s template) reports `None` for that merge, the parity oracle now matches the CLI's `<Error…>` to `None`; item 2's merged index lets `is_empty` succeed, so `commit_contents` with the extras answers the merge (`Some(true)` in the test). Wire: `CommitContent.empty_unknown` (presence bit); Dart `CommitContent.empty` is `bool?`. Dart consumers: only `packages/zanshin_core` (lib + tests) — none in `app/` or the other packages.

**Files changed:** `crates/zanshin-jj/src/{cli_command,commit_content,commit_meta,drop_actions,lib,repo,select_tree,topology}.rs`, `README.md`; `crates/zanshin-jj/tests/it/{api_stability,commit_contents,diffedit,git_colocation,graph,graph_topology,select_tree,when_commands}.rs`; `crates/zanshin-ffi/src/{commit_contents,drop_actions,graph,select_tree}.rs`, `tests/it/{commit_contents_ffi,graph_ffi,select_tree_ffi,snapshot_ffi}.rs`, `benches/{graph_topology,graph_wire}.rs`; `crates/zanshin-parity/tests/oracle/{log_at_operation,scenarios}.rs`; `schemas/envelope.fbs` + `cargo make codegen` output (`envelope_generated.rs`, `zanshin_ffi.h`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart`); `packages/zanshin_core/lib/{zanshin_core.dart, src/ffi/{commit_contents,graph,select_tree}.dart, src/worker/{commands,handle,isolate}.dart}` and tests `test/{ffi/{commit_contents,graph,warning}_test.dart, graph_layout/support/topology_envelope.dart, worker/{commit_contents,select_tree}_test.dart}`; `docs/ffi-abi.md`; this spec and `deferred-work.md` (ledger commit). No new extern fn.

**Review:** one pass, 31 findings (0 high, 0 medium, 21 low, 10 false). Patched (11 rows, 7 fixes, applied by the orchestrator — the implementer could not be re-engaged synchronously): Dart extras test now fails if the extras are dropped (unknown extra → `jj.operation_not_found`); Dart select-tree scope test (`split` refuses `jj.config_error` through a repo-config `[[--scope]]`, `squash` / no verb succeed); one child-process witness for all 13 row commands; module-doc fix (failed row contexts are retried); `docs/ffi-abi.md` `empty_unknown` paragraph corrected (an out-of-index id without its extras is refused, never answered unknown); `shortcut:` comment (row transactions keep the call's `UserSettings`); `zanshin_drop_actions` / `zanshin_change_actions` rustdoc (per-row resolution, in-row `jj.config_error`) and `commit_content.rs` module doc. Rejected with reasons in the triage log: mid-call config edit, uncached failed context (twice), per-row load cost, unbenched extras cost, error-path asymmetry, mapping tests restating the tables, and the ten `false` rows. Deferred: none (no new ledger item). Follow-up review: false (patched: 0 high, 0 medium, 11 low).

**Verification (targeted, per the run's gate rule — no `cargo make test` / `test-full` / `coverage`), after the review patches:**
- `cargo make codegen` — rerun after the FFI doc patches; output committed.
- `cargo fmt --all --check`, `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean.
- `cargo test -p zanshin-jj --lib` — 414 passed.
- `cargo test -p zanshin-jj --test it -- when_commands:: graph_topology:: commit_contents:: graph:: drop_actions select_tree git_colocation:: api_stability:: diffedit` — 233 passed (`when_commands::` alone 13).
- `cargo test -p zanshin-ffi --lib` — 232 passed; `cargo test -p zanshin-ffi --test it -- commit_contents select_tree graph drop_actions snapshot` — 62 passed.
- `cargo test -p zanshin-parity --test oracle` — 493 passed (before and after the patches).
- `packages/zanshin_core` (gate env from `Makefile.toml`: `JJ_CONFIG=""`, `JJ_USER`, `JJ_EMAIL`, …): `flutter test` 1122 passed; `dart analyze` no issues; `dart format --set-exit-if-changed .` 0 changed. `app/`: `dart analyze` no issues.

**Residual risks:** coverage not measured (the loop's final gate measures it; the row-context build and its failure arm run only in `own_process!` child processes, whose coverage attribution the gate will show); per-row context building costs one config load per distinct row command per call; the `trunk()` fallback is decided once for the call's stack and row transactions keep the call's `UserSettings` (both named in `shortcut:` comments).
