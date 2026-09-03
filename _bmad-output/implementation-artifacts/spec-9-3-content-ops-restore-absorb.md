---
title: 'Story 9.3: Content ops — `restore`, `absorb`'
type: 'feature'
created: '2026-09-03'
status: 'in-progress'
baseline_revision: '8ab8e7d4fe810ba38347d3304c0abf6faac49d2f'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: ['multiple-goals', 'oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Epic 9's Tier A opens here: `zanshin-jj` ships six mutation verbs
(`describe`/`new`/`edit`/`abandon`/`undo`/`git fetch`) and none of them moves *file content*
between commits. A user who wants `jj restore` or `jj absorb` must leave Zanshin for the CLI —
the exact gap ADR-0003 exists to close.

**Approach:** Add two typed verbs — `Repo::restore` (whole-file content restore between two
commits, via Story 9.1's `SelectedTree::from_paths` → jj-lib `rewrite::restore_tree`) and
`Repo::absorb` (`jj_lib::absorb::{split_hunks_to_trees, absorb_hunks}`) — and lift both through
the full surfacing chain: `.fbs` request/payload tables → `extern "C"` → committed codegen →
Dart adapter/command/worker/`RepoHandle` → tests.

## Boundaries & Constraints

**Always:**
- The jj CLI's **observable behavior at tag `v0.44.0`** is the oracle (NFR-R-2). Read prior art
  with `git -C ../jj show v0.44.0:cli/src/commands/{restore,absorb}.rs`; jj-lib is vendored at
  `~/.cargo/registry/src/*/jj-lib-0.44.0/`. Every refusal, default and op-log description below
  was read there, not inferred.
- **Full surfacing chain per verb** (epics.md:5514 header / epic-9-context.md): `.fbs` → typed
  `zanshin-jj` op (transaction Rust-side) → `zanshin-ffi` `extern "C"` + `cargo make codegen`
  → Dart worker command → tests. 9.3 is Epic 9's first *verb* story; 9.1/9.2 were precursors.
- No `jj_lib` type in a public position (`lib.rs:5-28`; enforced by `tests/api_stability.rs`
  and the `test-jj-adapter-hygiene` Makefile gate). Every jj-lib failure flattens to a `String`.
- `#![deny(missing_docs)]` (`lib.rs:3`) — every `pub`/`pub(crate)` item needs a doc comment.
- Re-resolve to head per call (ADR-0002); config re-read per call, never cached.
- Clippy pedantic `-D warnings`: dropping an `#[allow(dead_code)]` that still shields an unused
  item **fails the build**. Move the attribute, never delete it wholesale.
- Commit on `main` with `--no-gpg-sign`; never edit git config.
- The gate is the definition of done: `cargo make test` green. Coverage floors after
  `epsilon_pct = 0.10`: `zanshin-ffi/src/repo.rs` and `envelope.rs` are at **100.00** (every new
  FFI line must be exercised), `zanshin-jj/src/mutate.rs` ≥ **96.39**, `zanshin-jj/src/repo.rs`
  ≥ **93.54**, `op_support.rs` ≥ **99.49**.

**Block If:**
- `jj_lib::absorb`'s `SelectedTrees.target_commits` (a `HashMap<CommitId, MergedTreeBuilder>`)
  cannot be consumed without naming a `jj_lib` type in a **public** position — i.e. the
  `AbsorbResult` shape below turns out to be unrepresentable without leaking. (It should not be:
  everything crossing the public boundary is `ChangeId`/`String`/`u32`.)
- The `Payload` union's next free slot is contested — another in-flight story also appends a
  member. Union member order **is** the wire discriminant; two stories cannot both take slot 14.

**Never:**
- **No interactive/hunk selection.** epics.md:5536 scopes `restore` to whole-file and puts
  interactive selection out of scope; `absorb`'s `--interactive`/`--tool` arm is likewise out.
  Both take the CLI's *non-interactive* path only. `SelectedTree::from_tree_id` stays unused.
- **No working-copy snapshot.** Zanshin never snapshots (D2, `status.rs:84`, `revset.rs:61-62`);
  `LockedWorkingCopy::{snapshot,reset}` is Story 9.22's scope. Both verbs read the
  last-snapshotted `@`. Document it; record it as deferred.
- No MCP tool — `crates/zanshin-mcp/src/main.rs` is a 5-line stub and the whole tool surface is
  Epic 7. "Optional MCP tool" is a no-op here.
- No new error **codes**. Both verbs reuse codes already in `docs/rust-error-codes.md`.
- No fileset-DSL parsing (`fileset::parse_maybe_bare`) — see Design Notes.
- Do not regenerate fixtures. Do not repoint `JJ_CONFIG`. Do not lower `coverage-baseline.txt`
  or add an `exclude_prefix`. Do not touch generated files except via `cargo make codegen`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| restore, both sides given | `from=A`, `into=B`, `paths=[]` | `B`'s tree becomes `A`'s; op-log head is `restore into commit <B-hex>` | No error expected |
| restore, one side given | only `from=A` (or only `into=B`) | the omitted side is `@` (CLI branch 1) | No error expected |
| restore, neither side | `from=None,into=None,changes_in=None` | restores `@` from its **parent tree**; `@` ends up empty but keeps its description | No error expected |
| restore, `changes_in` | `changes_in=C` | `C` restored from `C.parent_tree()` — undoes `C`'s own diff | No error expected |
| restore, path filter | `paths=["a.txt"]`, other files differ too | only `a.txt` takes the source content; other paths untouched | No error expected |
| restore, no-op | source and destination trees already equal | **no operation written** (op-log head unchanged); `new_op_id` == pre-call head | No error expected |
| restore, descendants | `restore_descendants=true`, target has children | children are **reparented** (content preserved), not rebased | No error expected |
| restore, arg conflict | `changes_in` set together with `from` or `into` | no repo access | `InvalidInput` ("`changes_in` cannot be combined with `from`/`into`") |
| restore, root target | `into` resolves to the root commit | no op written | `Immutable { commit_id: <root hex> }` |
| restore, immutable target | `into` inside `::(immutable_heads() \| root())` | no op written | `Immutable` (first offender) |
| restore, bad id | any of `from`/`into`/`changes_in` malformed, absent, only-hidden, or divergent | no op written | `ChangeNotFound { id }` |
| restore, bad path | `paths` entry rejected by `RepoPathBuf::from_internal_string` | no op written | `InvalidInput` (offending path in `reason`) |
| absorb, happy | ancestor `A` introduces `a.txt`; source `S` (child) edits one of its lines; `into=None` | the hunk moves into `A`; `rewritten_change_ids == [A]`; op-log head is `absorb changes into 1 commits` | No error expected |
| absorb, source default | `from=None` | source is `@` (last-snapshotted content) | No error expected |
| absorb, destination default | `into=None` | destinations are `mutable()` — resolved through the effective config layer, not a Rust constant | No error expected |
| absorb, narrowed destinations | `into` excludes the annotating ancestor | nothing absorbed: `rewritten_change_ids` empty **and no operation written** | No error expected |
| absorb, path filter | `paths=["a.txt"]`, source also edits `b.txt` | only `a.txt`'s hunks move; `b.txt` stays in the source | No error expected |
| absorb, unabsorbable content | source only ADDS a new file | nothing absorbed, no operation written | No error expected |
| absorb, skipped path | a path jj-lib refuses to split (conflict / symlink / submodule / unreadable) | `skipped_paths` carries `(path, reason)` verbatim from jj-lib; the remaining paths still absorb | No error expected |
| absorb, immutable destination | `into` explicitly names an immutable commit that is an annotation target | no op written | `Immutable` (first offender) |
| absorb, revset syntax | `into="bogus_function()"` | no op written | `RevsetParseError` → `jj.revset_parse_error` |
| absorb, revset symbol | `into="nonexistent-bookmark"` | no op written | `RevsetResolutionError` → `jj.revset_resolution_error` |
| absorb, bad source | `from` malformed/absent/only-hidden/divergent | no op written | `ChangeNotFound { id }` |
| config fault (both verbs) | `revset-aliases."immutable_heads()"` unparseable | no op written; never a silent fall-back to builtins | `Config { reason }` |
| FFI, null request | `data == NULL` | — | `ffi.null_pointer` |
| FFI, garbage request | `data` does not verify as the request table | — | `ffi.invalid_argument` |
| FFI, zero/stale handle | `handle == 0` | — | `ffi.invalid_handle` |

</intent-contract>

## Code Map

Every anchor below was read and verified against the working tree at baseline `8ab8e7d`, and
every jj anchor at tag `v0.44.0`.

**Prior art (read-only, at the tag)**
- `v0.44.0:cli/src/commands/restore.rs` — arg surface `:52-101`; the `--revision` trap arm
  `:110-118`; the **two-branch default resolution** `:119-137` (branch 1: whichever of
  `--from`/`--into` is absent becomes `@`; branch 2: `to = changes_in|@`,
  `from_tree = to.parent_tree(repo)`, `from_commits = to.parents()`); `check_rewritable([to.id()])`
  `:138` — **before** matcher/tree work; `Diff::new(&to_tree, &from_tree)` into the selector
  `:161-172`; the no-op guard `if new_tree.tree_ids() == to_commit.tree_ids()` `:181-182`
  (**no transaction started**); `rewrite_commit(&to).set_tree(new_tree)` `:185-189`;
  `reparent_descendants()` vs `rebase_descendants()` `:190-199`;
  `tx.finish(ui, format!("restore into commit {}", to_commit.id().hex()))` `:208`.
- `v0.44.0:cli/src/commands/absorb.rs` — args `:52-84` (`--from` clap default `"@"`, `--into`
  clap default `"mutable()"`); `parse_union_revsets(...).resolve()` `:95-97`;
  `AbsorbSource::from_commit(repo, source)` (non-interactive arm) `:149`;
  `split_hunks_to_trees(repo, &source, &destinations, &matcher)` `:152` — **outside** the
  transaction; per-path skip warnings `:154-158`;
  `check_rewritable(selected_trees.target_commits.keys())` `:160-162`; `start_transaction()` `:164`;
  `absorb_hunks(tx.repo_mut(), &source, selected_trees.target_commits)` `:165`;
  `tx.finish(ui, format!("absorb changes into {} commits", stats.rewritten_destinations.len()))`
  `:189-195`.
- `v0.44.0:cli/src/cli_util.rs:2792-2795` — `tx.finish` prints `"Nothing changed."` and writes
  **no operation** when `!tx.repo().has_changes()`. This is absorb's no-op guard.

**jj-lib 0.44.0 (vendored, exact signatures)**
- `rewrite.rs:132` `pub async fn restore_tree(source, destination, source_label, destination_label,
  matcher) -> BackendResult<MergedTree>` — **source first**; the CLI's `Diff::new(before, after)`
  inverts at the call site. Story 9.1's `SelectedTree::from_paths` already encodes the inversion.
- `absorb.rs`: `AbsorbSource::from_commit(&dyn Repo, Commit) -> BackendResult<Self>` `:63`;
  `SelectedTrees { target_commits: HashMap<CommitId, MergedTreeBuilder>, skipped_paths:
  Vec<(RepoPathBuf, String)> }` `:99-104`; `split_hunks_to_trees(&dyn Repo, &AbsorbSource,
  &Arc<ResolvedRevsetExpression>, &dyn Matcher) -> Result<SelectedTrees, AbsorbError>` `:108`;
  `AbsorbStats { rewritten_source: Option<Commit>, rewritten_destinations: Vec<Commit>,
  num_rebased: usize }` `:294-304` (`num_rebased` **excludes** the destinations, **includes** the
  rewritten source); `absorb_hunks(&mut MutableRepo, &AbsorbSource, HashMap<…>) ->
  BackendResult<AbsorbStats>` `:308`. `AbsorbError` `:87` has `Backend` + `RevsetEvaluation` arms.
- `commit.rs`: `tree()` `:120`, `tree_ids() -> &Merge<TreeId>` `:128`,
  `async parent_tree(&dyn Repo)` `:134`, `async parents()` `:110`, `conflict_label()` `:219`,
  `pub fn conflict_label_for_commits(&[Commit]) -> String` `:252`.
- `repo.rs`: `MutableRepo::has_changes()` `:978`, `has_rewrites()` `:1079`,
  `async rebase_descendants()` `:1523`, `async reparent_descendants()` `:1542`.
- `matchers.rs`: `EverythingMatcher` (unit struct) `:120`, `PrefixMatcher::new(prefixes)` `:192`.
  `repo_path.rs`: `RepoPathBuf::from_internal_string(...) -> Result<Self, _>` `:251`.

**Extend — `crates/zanshin-jj`**
- `src/mutate.rs` — the module both verbs join. Reuse verbatim: `MutationResult` `:27-50`,
  `MutateError` `:54-139` (add two variants), `be` `:143` / `cfg` `:150`, `resolve_commit` `:164`,
  `guard_rewritable` `:197`, `capture_old_wc` `:212`, `sync_working_copy` `:227`. `describe`
  `:263-310` is the canonical scaffold to copy (fixed order: `load_at_head` → `capture_old_wc` →
  `start_transaction` → resolve → guards → mutate → rebase → `tx.commit(desc)` → `new_op_id` →
  `sync_working_copy` → result). `:22` already imports `check_rewritable`/`resolve_immutable`.
  Module doc `:3` says "the four P0 change mutations" — amend.
- `src/op_support.rs` — `SelectedTree` `:365-367` + `impl` `:369`, `from_paths(trees:
  Diff<&MergedTree>, tree_labels: Diff<String>, matcher: &dyn Matcher)` `:382-396` (**restore's
  primitive**, argument order already CLI-correct), `tree()` `:420`. `immutable_user_expression`
  `:71`, `resolve_immutable` `:94`, `check_rewritable` `:119`. The `#[allow(dead_code)]` at `:366`
  and `:369` must be **moved** onto the still-unused `from_tree_id` `:407` and
  `into_commit_selection` `:426`, not deleted (`-D warnings`).
- `src/revset.rs` — `parse_revset_with(repo, aliases_map, expr)` `:193`, `resolve_expression(
  repo_dyn, expr) -> Arc<ResolvedRevsetExpression>` `:273`, `build_aliases_map(config)` `:324`,
  `RevsetError` `:34-56` (the 3-stage taxonomy to preserve).
- `src/config.rs:74-105` `BUILTIN_CONFIG_TOML` — **verified**: `'mutable()' = '~immutable()'`
  `:101` and `'immutable()' = '::(immutable_heads() | root())'` `:100` are present, so absorb's
  `mutable()` default resolves through the effective-config layer.
- `src/repo.rs` — facade shape: `describe` `:384-393` (doc-comment template; two-line body that
  builds `immutable` from `&self` **before** `workspace_mut()`), `git_fetch` `:492`. Append the
  two new methods after `:492`.
- `src/lib.rs:30-44` modules, `:46-59` re-exports — add the two new public types to `:53`'s line
  or a new `pub use`.

**Extend — wire + FFI**
- `schemas/envelope.fbs` — request-only block `:31-40` (`ChangeIdList` `:38`, and the header
  comment that states Dart owns/frees these buffers); union ledger comment `:42-52`; `Payload`
  union `:350-365` — **next free discriminant is 14**; `MutationResult` `:338-348`; `FfiError`
  `:26-29`; `Envelope` `:380-384`.
- `crates/zanshin-ffi/src/repo.rs` — `map_mutate_err` `:79-114` (8 arms; add 2);
  `read_change_id_list` `:132-153` (the request-buffer template, incl. the
  `flatbuffers::root_with_opts::<T>` justification comment); mutation banner `:561`; wrappers
  `zanshin_describe` `:591`, `zanshin_new_change` `:643` (request-buffer arity), `zanshin_undo`
  `:764-800` (quoted doc template). Append after `:863`.
- `crates/zanshin-ffi/src/envelope.rs` — `FfiErrorObj` `:96-99`, `ok_mutation_result` `:154-182`
  (documented build order: string vectors → scalars → table → envelope), `err` `:222`, `catch`
  `:264`; constants `JJ_CHANGE_NOT_FOUND` `:36`, `JJ_INVALID_INPUT` `:39`, `JJ_IMMUTABLE` `:43`,
  `JJ_CONFIG_ERROR` `:70`, `JJ_JJ_LIB_ERROR` `:32`, `JJ_REVSET_PARSE_ERROR` `:63`,
  `JJ_REVSET_RESOLUTION_ERROR` `:66`, `FFI_NULL_POINTER` `:20`, `FFI_INVALID_ARGUMENT` `:24`.
- `docs/rust-error-codes.md` — rows `:47` (`jj.change_not_found`), `:54`/`:55` (revset codes),
  `:56` (`jj.config_error`), `:58` (`jj.invalid_input`), `:59` (`jj.immutable`). Story 9.1's
  "Also emitted — Story 9.1" clause on rows `:56`/`:59` is the annotation style to copy.

**Extend — Dart (`packages/zanshin_core`)**
- `lib/src/ffi/mutate.dart` — `_withChangeIdListBytes<T>` `:28-37` (malloc/setAll/`finally
  malloc.free`), `zanshinNewChange` `:71` (request-buffer adapter template), the interior-NUL
  guard `:44-46`, `MutationResult` model `:152-175`, `decodeMutationResultEnvelope` `:184` /
  `…Internal` `:187` / `_decode…` `:189-208`.
- `lib/src/worker/commands.dart` — `sealed class WorkerCommand` `:11`, `NewChangeCommand` `:246`,
  `AbandonCommand` `:285`; append after `:332`.
- `lib/src/worker/isolate.dart` — `ZanshinWorker.newChange` `:686`, `.abandon` `:720`; worker
  switch arms `NewChangeCommand` `:1025`, `AbandonCommand` `:1059` (16-line block incl. the
  synthesized `ffi.invalid_handle` envelope via `fbs.EnvelopeObjectBuilder`).
- `lib/src/worker/handle.dart` — `RepoHandle` `:30`, `newChange` `:216`, `abandon` `:245`
  (`if (_closed) throw StateError(...)` guard).
- Generated, regenerate only via `cargo make codegen`: `lib/src/ffi/bindings.dart`,
  `lib/src/ffi/envelope_zanshin.ffi_generated.dart`, `crates/zanshin-ffi/src/envelope_generated.rs`,
  `crates/zanshin-ffi/include/zanshin_ffi.h`.

**Tests / gates**
- `crates/zanshin-jj/tests/mutate.rs` — `pin_env()` `:17-24`, `make_test_settings`,
  `Layout`/`oracle_layout` `:50-113` (ids discovered **by description**, never hardcoded),
  `checkout_state_path` `:115`, the representative test `:121-150`, the two mandatory op-log
  assertions (description + `result.new_op_id == ops[0].id`; and `before_op == head_op_id(&repo)`
  on refusal). `crates/zanshin-jj/tests/op_support.rs` — `write_repo_config` `:116`,
  `head_op_id` `:121`, `assert_immutable` `:125`.
- `crates/test-helpers/src/lib.rs` — `extract_fixture` `:41`, `add_commit_off_root` `:95`,
  `set_tag` `:263` (how a commit is made immutable), `add_conflicted_merge_off_root` `:226`;
  **private** `one_file_tree(store, path, content)` `:133` — the single-file tree builder a new
  multi-file public helper generalizes. Crate is coverage-excluded (`coverage-baseline.txt:11`).
- `crates/xtask/src/tasks/gen_fixture.rs:143-161` — **each fixture commit's tree is built from an
  empty base and holds exactly one file `commit-<n>.txt`**, so `tiny-3-commits` has no path that
  survives across commits. Absorb (and any multi-file restore) needs purpose-built commits.
- `crates/zanshin-ffi/tests/repo_write_ffi.rs` — helpers `read_and_free` `:60`, `parse_envelope`
  `:71`, `cstr` `:76`, `change_id_list_bytes` `:82`, `open_handle` `:92`,
  `open_fixture_and_get_wc_change_id` `:116`, `open_fixture_with_repo_config` `:320`; the two
  cross-cutting sweeps `every_wrapper_bogus_change_id_returns_jj_change_not_found` `:696` and
  `every_wrapper_zero_handle_returns_ffi_invalid_handle` `:873` — **both must gain the new verbs**.
- `packages/zanshin_core/test/worker/mutate_test.dart` — header comment `:3-14` states this file
  is what credits each `extern "C"` fn in the coverage ratchet's extern-fn guard; sample test
  `:42-56`. `packages/zanshin_core/test/ffi/mutate_test.dart` — decode-contract + NUL-guard groups.
- `crates/zanshin-jj/tests/api_stability.rs` — type-alias count comment `:12-13`, `sample_*`
  field-naming constructors, `api_surface_resolves()`, and `:172-173`'s note on what cannot be
  `fn`-pointer-pinned.
- `Makefile.toml` — `[tasks.codegen]` `:289-295` (flatc-rust → flatc-dart → cbindgen → ffigen),
  `[tasks.verify-codegen]` `:348` (**manual**, refuses on a dirty tree), `[tasks.test]` `:47-72`
  (22 deps, ending in `coverage` `:449`), `test-jj-adapter-hygiene` `:255`,
  `test-cargo-hygiene` `:205` (asserts exactly 8 tracked `Cargo.toml` — **add no crate**).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/mutate.rs` -- add `MutateError::RevsetParseError { reason }` and
  `RevsetResolutionError { reason }` -- absorb is the first mutation taking a user-typed revset,
  and 9.2 established that the parse/resolution split is preserved rather than collapsed; both map
  onto codes the registry already carries.
- `crates/zanshin-jj/src/mutate.rs` -- add `pub(crate) fn restore(workspace, immutable, from,
  into, changes_in, paths, restore_descendants) -> Result<MutationResult, MutateError>` following
  `describe`'s scaffold: reject `changes_in` combined with `from`/`into`; resolve the two-branch
  CLI default (`@` = `view().get_wc_commit_id(workspace_name)`); `guard_rewritable` on the
  destination **before** any tree work; build the matcher; `op_support::SelectedTree::from_paths(
  Diff::new(&to_tree, &from_tree), Diff::new(to_commit.conflict_label(),
  conflict_label_for_commits(&from_commits)), matcher)`; **if the new tree ids equal the
  destination's, drop the transaction and return the pre-call head op id**; else `rewrite_commit`
  + `reparent_descendants()`/`rebase_descendants()` + `tx.commit(format!("restore into commit {}",
  to.id().hex()))` -- reusing 9.1's `SelectedTree` is what that layer was built for and keeps the
  `restore_tree` argument inversion in exactly one place.
- `crates/zanshin-jj/src/mutate.rs` -- add `pub(crate) fn absorb(workspace, immutable,
  destinations, from, paths) -> Result<AbsorbResult, MutateError>` mirroring the CLI's order:
  `load_at_head` → `capture_old_wc` → resolve source → `revset::resolve_expression(readonly,
  destinations)` → matcher → `AbsorbSource::from_commit` → `split_hunks_to_trees` → collect
  `skipped_paths` → `resolve_immutable` + `check_rewritable(target ids)` **before**
  `start_transaction` → `absorb_hunks` → `rebase_descendants()` → **if `!tx.repo().has_changes()`
  drop the transaction** and return the pre-call head op id, else
  `tx.commit(format!("absorb changes into {} commits", stats.rewritten_destinations.len()))` →
  `sync_working_copy` -- splitting before the transaction is the CLI's own ordering and keeps a
  refusal from leaving an operation behind.
- `crates/zanshin-jj/src/mutate.rs` -- add `pub struct AbsorbResult { mutation: MutationResult,
  rewritten_change_ids: Vec<ChangeId>, source_change_id: Option<ChangeId>, num_rebased: u32,
  skipped_paths: Vec<SkippedPath> }` and `pub struct SkippedPath { path: String, reason: String }`
  -- `MutationResult` alone cannot say which commits absorbed what or which paths jj-lib refused,
  and a silently unabsorbed file is a CLI *warning* the GUI must still be able to show. Amend
  `MutationResult::new_op_id`'s doc for the no-op contract, and the module doc at `:3`.
- `crates/zanshin-jj/src/op_support.rs` -- move the two `#[allow(dead_code)]` attributes from the
  `SelectedTree` struct/impl onto `from_tree_id` and `into_commit_selection`, each with a
  `// WHY:` naming the first caller (Story 9.15/9.17) -- restore makes the type live, and a
  blanket allow that no longer shields anything would let a genuinely dead item pass unnoticed.
- `crates/zanshin-jj/src/repo.rs` -- add `pub fn restore(...)` and `pub fn absorb(...)` after
  `:492`, in `describe`'s exact doc style (summary + `# Errors` naming every reachable variant +
  `#[must_use]`), building `immutable` — and, for absorb, the parsed destinations expression —
  from `&self` before `workspace_mut()` -- the facade's only job is ending the shared borrow.
- `crates/zanshin-jj/src/lib.rs` -- re-export `AbsorbResult` and `SkippedPath` -- the story's only
  public-type growth.
- `crates/test-helpers/src/lib.rs` -- add `add_commit_with_files(workspace_root, parents, files,
  description) -> String` generalizing the private `one_file_tree` to a complete multi-file tree
  -- the committed fixtures give every commit a single unique file, so no fixture path survives
  across commits and absorb's "ancestor introduced the line" precondition is unconstructible
  without it; regenerating fixtures is forbidden.
- `schemas/envelope.fbs` -- add request-only `RestoreRequest { from, into, changes_in, paths,
  restore_descendants }` and `AbsorbRequest { from, into, paths }` beside `ChangeIdList`; add
  payload `AbsorbSkippedPath { path, reason }` and `AbsorbResult { mutation: MutationResult,
  rewritten_change_ids, source_change_id, num_rebased, skipped_paths }`; append `AbsorbResult` to
  `Payload` (slot 14) and tick the ledger comment -- absent FlatBuffers strings are the wire form
  of "user did not supply it", which is what carries the CLI's own defaults through faithfully.
- `crates/zanshin-ffi/src/envelope.rs` -- extract the `MutationResult` table construction out of
  `ok_mutation_result` into a shared builder helper and add `ok_absorb_result` on top of it --
  one construction site, so the nested and top-level forms cannot drift.
- `crates/zanshin-ffi/src/repo.rs` -- add `read_restore_request` / `read_absorb_request` in
  `read_change_id_list`'s shape, two `map_mutate_err` arms for the revset variants, and
  `zanshin_restore` / `zanshin_absorb` (`handle: u64, data: *const u8, len: usize`) with the full
  `debug!` → `catch` → `handle_from_raw` → decode → call → payload → `vec_into_token` body and
  `zanshin_undo`'s doc-comment shape (`# Errors`, `# Safety`) -- cbindgen lifts those docs into
  the header and ffigen into `bindings.dart`, so they are the ABI documentation.
- `cargo make codegen` -- regenerate and commit `envelope_generated.rs`,
  `envelope_zanshin.ffi_generated.dart`, `include/zanshin_ffi.h`, `bindings.dart`; then run
  `cargo make verify-codegen` on a clean tree -- generated output is committed and the build never
  regenerates it.
- `packages/zanshin_core/lib/src/ffi/mutate.dart` -- add `zanshinRestore` / `zanshinAbsorb`
  adapters (request bytes built with the generated `…ObjectBuilder`, freed in `finally`),
  interior-NUL guards on every string, an `AbsorbResult`/`SkippedPath` model and its envelope
  decoder alongside the `MutationResult` one -- the adapter file owns the whole mutation surface.
- `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` -- add `RestoreCommand` /
  `AbsorbCommand` (isolate-sendable fields only), the two `ZanshinWorker` methods, the two worker
  switch arms incl. the synthesized `ffi.invalid_handle` envelope, and the two `RepoHandle`
  methods with the `_closed` guard -- Model A: the UI never holds a raw pointer.
- `crates/zanshin-jj/tests/content_ops.rs` (NEW) -- cover every `restore`/`absorb` row of the I/O
  matrix using `pin_env()`, `extract_fixture`, the new multi-file helper, and both mandatory
  op-log assertions (head description + `new_op_id`; unchanged head on refusal **and on a no-op**)
  -- integration level is right: both entry points are public `Repo` methods.
- `crates/zanshin-ffi/tests/repo_write_ffi.rs` -- add happy-path, `ffi.null_pointer` and
  `ffi.invalid_argument` cases for both wrappers and extend the two cross-cutting sweeps at `:696`
  and `:873` -- `zanshin-ffi/src/repo.rs` sits at a 100.00 baseline.
- `packages/zanshin_core/test/worker/mutate_test.dart` and `test/ffi/mutate_test.dart` -- add real
  cdylib round-trips for both verbs plus decode/NUL-guard tests -- the worker test is what credits
  each new `extern "C"` fn in the ratchet's extern-fn guard.
- `crates/zanshin-jj/tests/api_stability.rs` -- pin the two `Repo` methods, `AbsorbResult`,
  `SkippedPath` and the two new `MutateError` variants (aliases + `sample_*` constructors + the
  count comment) -- that file's job is to break on surface drift.
- `docs/rust-error-codes.md` -- append "Also emitted — Story 9.3" clauses to the rows for
  `jj.change_not_found`, `jj.invalid_input`, `jj.immutable`, `jj.config_error`,
  `jj.revset_parse_error`, `jj.revset_resolution_error`, naming the two wrappers -- the registry
  is canonical and every story that emits a code updates it.

**Acceptance Criteria:**
- Given the workspace after this change, when `cargo make test` runs, then it passes end to end
  with no baseline lowered and no `exclude_prefix` added; `crates/zanshin-ffi/src/repo.rs` and
  `crates/zanshin-ffi/src/envelope.rs` hold at 100.00 %, and `crates/zanshin-jj/src/mutate.rs`,
  `src/repo.rs` and `src/op_support.rs` stay at or above their baselines.
- Given `restore` and `absorb`, when the surfacing chain is inspected, then each has a `.fbs`
  request table, an `extern "C"` wrapper, regenerated **committed** codegen, a Dart adapter, a
  `WorkerCommand`, a `ZanshinWorker` method, a `RepoHandle` method, and at least one
  `packages/zanshin_core/test/worker` test that drives it through the real cdylib.
- Given a refusal (immutable target, bad id, bad revset, arg conflict) **or** a no-op (identical
  trees for `restore`, nothing absorbable for `absorb`), when the op log is read afterwards, then
  its head is byte-identical to the pre-call head — no operation was written in either case.
- Given a successful `restore` or `absorb`, when the op log is read, then the head description is
  exactly `restore into commit <hex>` / `absorb changes into <n> commits`, and the returned
  `new_op_id` equals the op-log head — the mutation is indistinguishable from a CLI-initiated one
  (NFR-R-2).
- Given `zanshin-jj`'s public API compared against the pre-change surface, then the only additions
  are `Repo::restore`, `Repo::absorb`, `AbsorbResult`, `SkippedPath` and the two `MutateError`
  variants; all are pinned in `tests/api_stability.rs`, no `jj_lib` type appears in any public
  position, and `test-jj-adapter-hygiene` passes.
- Given the repo after `cargo make codegen`, when `cargo make verify-codegen` runs on a clean
  tree, then it reports no drift for `zanshin_ffi.h`, `bindings.dart`, `envelope_generated.rs` and
  `envelope_zanshin.ffi_generated.dart`.
- Given `docs/rust-error-codes.md`, when it is read, then it contains no **new** code row — every
  code both verbs emit was already registered — and the reused rows name Story 9.3 as an emitter.
- Given `cargo make test`'s `test-cargo-hygiene` gate, when it runs, then it still sees exactly
  eight tracked `Cargo.toml` files — this story adds no crate.

## Spec Change Log

## Review Triage Log

## Design Notes

**Scope is the full surfacing chain — and that is derived, not assumed.** Four signals: (1)
epic-9-context.md states the per-verb definition of done as `.fbs` → `zanshin-jj` op →
`zanshin-ffi` + codegen → Dart worker command → optional MCP → tests, with "an FFI-path Dart test
(needed for coverage attribution of each `extern "C"` fn)" spelled out; (2) sprint-status.yaml's
Epic 9 header repeats it; (3) in epics.md 9.3 sits under **Tier A — cheap (start here)** and
carries the `[M]` mutation tag, unlike 9.2 which sat under `### Precursors` with no tag — that
placement was 9.2's decisive scope signal and it points the other way here; (4) Story 6.5 already
built this exact chain for six verbs, so there is a template rather than an invention. MCP is the
one link that stays empty: `crates/zanshin-mcp/src/main.rs` is a five-line stub and the tool
surface is Epic 7's entire scope, which is why the epic writes "**optional** MCP tool".

**Parameter currency: single revision → `ChangeId`, revision *set* → revset string.** All six
shipped mutation verbs take `ChangeId` even though the CLI takes revsets, and `repo.rs:381-383`
records that epics.md Story 6.1 fixed that signature; restore's `--from`/`--into`/`--changes-in`
are each `resolve_single_rev`, so they follow the house currency. Absorb's `--into` is different
in kind: it is a `Vec<RevisionArg>` unioned into a *set* whose CLI default is the dynamic
`mutable()`. Converting it to an id list would force the caller to materialize the set and would
destroy the expression's meaning, so FR-JJ-17's "pass the parameter through as the CLI shapes it"
selects a revset string. `mutable()` is verified present in `config.rs:101`, so the default
resolves through the effective config layer — a pre-filled, user-editable value, never a Rust
constant.

**Paths are repo-relative strings interpreted as prefixes, not the fileset DSL.** The CLI parses
`paths` with `fileset::parse_maybe_bare`, whose *bare* form is exactly `prefix_path` — so
`PrefixMatcher::new(paths)` reproduces the CLI's observable behavior for the input a GUI actually
produces (a file/directory selection), and an empty list maps to `EverythingMatcher`. The DSL
itself is terminal *input language*, and project-context is explicit that Zanshin replaces the
CLI's terminal UX while replicating its behavior — the same reasoning by which a GUI-supplied
`TreeId` replaces the interactive diff editor. Record DSL support as deferred: Story 9.4's file
reads will face the same question and can settle it once for both.

**No working-copy snapshot — a pre-existing project decision, not a shortcut.** `status.rs:84`
and `revset.rs:61-62` both document D2: Zanshin re-resolves to head and never snapshots. The CLI
snapshots inside `workspace_helper` before both commands, so `jj absorb` there sees on-disk edits
while ours sees the last-snapshotted `@`. Building the snapshot path here would pull in
`LockedWorkingCopy::{snapshot,reset}` + `SnapshotOptions`, which epics.md:5596 assigns to Story
9.22. Both verbs remain fully useful and fully testable without it (any `from`/`into` other than
`@` is pure committed-tree work), so this ships with the divergence documented on both `Repo`
methods and recorded as deferred against 9.22.

**Two no-op guards, because they are not interchangeable.** For `restore` the CLI compares
`new_tree.tree_ids() == to_commit.tree_ids()` *before* starting a transaction (`restore.rs:181`).
That check cannot be replaced by `has_changes()`: `rewrite_commit(...).set_tree(same_tree).write()`
already records a rewrite, so the guard has to run first. For `absorb` the CLI has no explicit
check — `tx.finish` refuses to write when `!tx.repo().has_changes()` (`cli_util.rs:2792-2795`), so
that is the guard to reproduce. In both cases the transaction is simply dropped (writing nothing)
and `MutationResult.new_op_id` carries the **pre-call head** op id. No `no_op` flag is added: the
op log is unchanged, which is the same signal jj itself gives, the GUI already tracks the head op
id through the op-heads watcher, and `AbsorbResult.rewritten_change_ids` makes the distinction
explicit on the absorb side anyway.

**Why `absorb` gets its own result type and `restore` does not.** `MutationResult`'s four fields
describe restore completely (it mints and abandons nothing). Absorb's core outcome — which
ancestors absorbed hunks, whether the source survived, and which paths jj-lib **refused** to split
and why — has no representation in it at all. The skipped-path list is not cosmetic: the CLI emits
one warning per skipped path, and dropping it would leave a file silently unabsorbed with no way
for the UI to say so. `AbsorbResult` therefore *nests* `MutationResult` rather than repeating its
fields, so the op-id / working-copy contract has one definition.

**Root needs no special guard here.** `describe`/`abandon` guard the root commit explicitly because
jj-lib's `rewrite_commit` asserts on it (`mutate.rs:275-284`). Restore reaches `rewrite_commit`
too, but `check_rewritable` runs first and `immutable_user_expression` unions `root()`
unconditionally (`config.rs:100`), so root always refuses as `Immutable` — exactly what the CLI
reports, since `restore.rs` likewise has no separate root guard. Absorb never rewrites the source's
own root.

**Traps to respect.** `restore_tree` takes **source first** while the CLI's `Diff::new` is
`(before, after)` — going through `SelectedTree::from_paths` keeps that inversion in one audited
place, and the conflict labels are load-bearing strings embedded into conflict output, not
cosmetics. `Transaction::write` **panics** (`"BUG: Descendants have not been rebased"`) if
`has_rewrites()` is still true, and Zanshin drives `jj_lib::transaction::Transaction` directly with
none of the CLI's `finish_transaction` safety net — so a `rebase_descendants()`/
`reparent_descendants()` pass must precede every commit, exactly as `new_change` already documents
(`mutate.rs:346-351`). `absorb_hunks` appends the source id to each target's predecessors itself
(`absorb.rs:357-361`); do not touch predecessors. `split_hunks_to_trees` writes content blobs to
the store outside any transaction — harmless orphans on a refusal, and the reason the CLI splits
before opening the transaction.

## Verification

**Commands:**
- `cargo make test` -- expected: green end to end (cargo test + clippy `-D warnings` + rustfmt +
  flutter/dart analyze+format + `cargo deny` + coverage ratchet). Run unpiped; capture the exit
  code. This is the single gate.
- `cargo make codegen` then `cargo make verify-codegen` -- expected: the second reports no drift.
  Run `verify-codegen` only on a clean tree; it refuses otherwise (`Makefile.toml:374-392`).
- `git -C ../jj show v0.44.0:cli/src/commands/restore.rs` and `:cli/src/commands/absorb.rs`
  -- expected: re-confirms the default resolution, guard ordering, no-op guards and op-log
  description strings before relying on the anchors above.
- `git status --porcelain` -- expected: afterwards only intended files; the four generated files
  appear only together with the `.fbs`/`extern "C"` change that earned them; `coverage-baseline.txt`
  appears only if the ratchet raised it.

**Manual checks (if no CLI):**
- Diff the crate's `pub` items: confirm the additions are exactly `Repo::restore`, `Repo::absorb`,
  `AbsorbResult`, `SkippedPath` and the two `MutateError` variants, and that no `jj_lib` type
  leaked into a public signature.
