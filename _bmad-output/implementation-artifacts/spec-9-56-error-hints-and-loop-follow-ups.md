---
title: 'Story 9.56 — Hints on errors, and three follow-ups of the 9.24/9.30/9.31 loop'
type: 'feature'
created: '2026-10-21'
status: 'in-progress'
baseline_revision: '6f863bf23349a91ab6b8268673556c8bea7fed63'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized', 'multiple-goals']
deferred:
  - summary: >-
      The CLI's generic, error-structure-derived hint families stay dropped: revset parse/resolution
      hints ("Did you mean …", operator and divergent-id hints), config Type/Parse/Migrate "Check the
      config file: <path>", fileset parse hints, string-pattern `InvalidKind` and name-pattern parse hints.
    evidence: |-
      CLI v0.46.0 cli/src/command_error.rs `revset_parse_error_hint` :892-924, resolution hints :926-978,
      :980-989, config :258-290 / :831-838, fileset :857-874, cli/src/revset_util.rs :370-403 / :512-520.
      They hang off read-path error types (RevsetError, ConfigError, FileError …) across Epics 2/4/9.25,
      not the verb refusals this story names; Story 9.56 builds the channel and fills the verb-specific hints.
    location: >-
      crates/zanshin-jj/src/{revset.rs,config.rs,file.rs,bookmark_ops.rs}; crates/zanshin-ffi/src/*.rs map_*_err
    severity: low
  - summary: >-
      `convert`'s "import git head" finish (`import_head_into_destination`) does not resolve the immutable
      set, while the CLI's `jj git init --git-repo` goes through `tx.finish` (init.rs:268).
    evidence: |-
      crates/zanshin-jj/src/convert.rs:655/666 (plain rebase, then `finish_transaction`). Under an
      unresolvable alias the CLI fails after writing `.jj/` (a half-initialised repo); Zanshin's convert
      rolls `.jj/` back on any failure (no-data-loss invariant), so matching the CLI's on-disk effect
      conflicts with the rollback contract — a Ralph decision.
    location: >-
      crates/zanshin-jj/src/convert.rs:655
    severity: low
---

<intent-contract>

## Intent

**Problem:** (1) A refusal crosses the FFI as `code` + `context` only, so the CLI's hint lines are either dropped or glued into the reason (fetch's `RemoteName` "Hint: Run `jj git remote rename` …"). (2) Zanshin's shared finish never resolves `immutable_heads()`, so unguarded verbs (positional/merge `new`, bookmark create/delete, undo, git export, git remote add/remove/rename, workspace add) and their drop/card rows succeed under an unresolvable alias where the CLI's `tx.finish` refuses `Config error` with no operation. (3) `git push` lists remotes before parsing `--remote` / `git.push`, so a native backend answers `jj.not_a_git_repo` instead of the config/pattern error. (4) `num_rewritten` is never observed non-zero through a real fetch/import.

**Approach:** Add an appended `hints: [string]` to `FfiError`, carried from each zanshin-jj error (a `hints()` accessor; a `hints` field only where the hint depends on the emitting site) through every FFI mapper and the envelope writer to Dart (`ZanshinFfiException.hints`, `ActionRefusal.hints`), and fill it on every ported verb-specific CLI hint path. Resolve the immutable set against the base repo in the shared finish (gated on `has_changes()`, as CLI `cli_util.rs:2849-2858`, `:2986-3002`) and in the unguarded plan fns. Reorder push's remote resolution like fetch's. Add a same-change-id force-push fixture.

## Boundaries & Constraints

**Always:**
- CLI v0.46.0 observable behavior is the spec (`git -C ../jj show v0.46.0:<path>`). Hint lines verbatim (incl. embedded newlines, as the CLI's `add_hint` text), in the CLI's order; the reason/context no longer contains any `Hint:` text.
- `hints` absent on the wire = none. An empty list writes NO field, so `PANIC_FALLBACK_ENVELOPE` (`envelope.rs:418`) stays byte-identical. Append the field; edit `schemas/envelope.fbs` in place; run `cargo make codegen` and commit its output.
- Shared-finish resolution only when `tx.repo().has_changes()` (a no-change tx keeps today's path), against `tx.base_repo()`, via `op_support::resolve_immutable` → `MutateError::Config` → `jj.config_error`; the rebase uses `rebase_descendants_with_options(&immutable, …)`. A refused verb writes no operation.
- Drop/card rows must agree with the verbs (9.31): an unguarded row whose plan is not a no-op resolves the set and reads Refused `jj.config_error`.
- Registry `docs/rust-error-codes.md` notes every code that carries hints (and the text); `docs/ffi-abi.md` documents `FfiError.hints` + the Dart field. Tests per project-context.md layout (`tests/it/<module>.rs`, `pin_test_env()` first).

**Never:**
- No hints on warnings (`Warning` stays code + message). No UI. No MCP changes. No new error codes, no code renames.
- The CLI's `Config error` footer "For help, see https://docs.jj-vcs.dev/latest/config/ …" (`command_error.rs:1028-1035`) is NOT a hint (printed by the error printer, not in `cmd_err.hints`) — do not add it.
- Do not touch the generic hint families or convert's finish (see `deferred:`). Do not change `default_remote_names` (Zanshin-only read helper, documented at `repo.rs:581`).
- Never regenerate fixtures; never lower the coverage baseline.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Reserved remote | fetch from a remote named `git` | `jj.invalid_input`, context = jj-lib's message only, `hints == ["Run `jj git remote rename` to give a different name."]` (Rust, FFI, Dart) | no op |
| Malformed refspec | fetch / poll with a `GitRefExpansionError::Expression` pattern | `jj.invalid_input`, `hints == ["Specify patterns in `(positive \| ...) & ~(negative \| ...)` form."]`; `InvalidBranchPattern` has none | no op |
| Hint-less error | any refusal without a CLI hint | `hints` empty / field absent | — |
| Unresolvable alias | `revset-aliases."immutable_heads()" = "nonexistent_symbol_xyz"`; plain `new`, `bookmark create`, `undo`, `git export`, remote rename/remove, `workspace add` | `jj.config_error`, no new operation (as the CLI); new_onto / NewMerge / Duplicate-onto / Revert-onto / BookmarkMove rows read Refused | — |
| No-change verb under that alias | e.g. `git import` / `git export` with nothing to do | today's no-op result (CLI "Nothing changed." skips the resolution) | — |
| Push ordering | native backend + malformed `git.push` / unparsable `--remote` | `jj.config_error` / `jj.invalid_input`, not `jj.not_a_git_repo` | — |
| Rewritten import | upstream force-pushes a same-change-id rewrite of a commit with a local child | fetch and `git import` report `num_rewritten == 1`; the child is rebased onto the rewrite | — |

</intent-contract>

## Code Map

**Item 1 — hint channel**
- `schemas/envelope.fbs:20-29` -- `table FfiError { code; context; }` → append `hints: [string];` (doc: absent = none, CLI order, verbatim). Also used by `ActionOutcome.refusal` (:1343-1350). Payload precedents `GitFetchResult.hints` :1038, `GitPushResult.hints` :1488.
- `Makefile.toml:532-595` `[tasks.codegen]` -- regenerates `crates/zanshin-ffi/src/envelope_generated.rs` and `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` (+ header/bindings, unchanged); all committed.
- `crates/zanshin-ffi/src/envelope.rs` -- `FfiErrorObj { code, context, report }` :461-475 (add `hints: Vec<String>`); `err_with_report` :1115-1147 and `FfiError::create` :1119-1125; `catch`/`err_never_unwind` :1166-1187; `build_action_outcome` :925-949; `build_warnings` :1075-1097 is the "None for empty" pattern; `PANIC_FALLBACK_ENVELOPE` :418; `map_precondition_err` :482.
- FFI mappers that build `FfiErrorObj { report: None, code, context }` (set `hints` from the error): `repo.rs:45 map_repo_err`, `:146 map_mutate_err` (shared by git/bookmark_ops/file_ops/push/drop_actions, `envelope.rs:843`), `:425`, `:510`; `config.rs:253`; `log_defaults.rs:21`, `graph.rs:36`, `bookmarks.rs:20`, `change.rs:25`, `commit_contents.rs:35`, `commit_views.rs:38`, `remotes.rs:31`, `status.rs:22`, `workspace.rs:41`, `file.rs:28`, `op_log.rs:20` (hint-less ones just default to empty).
- zanshin-jj errors: `MutateError` (`mutate.rs:115`; `InvalidInput { reason }` :126, `Immutable { commit_id }` :146, `BookmarkExists` ~:281, `BookmarkTrackedRemoteExists` ~:297, `PathsNotIgnored` ~:320, undo cross-workspace, push ref/commit refusals), `RepoError::GitRepoExists` (`repo.rs:63`), `PreconditionError::StaleWorkingCopy` (`snapshot.rs:184`), `ConfigCmdError::UnrecognizedFile` (`config_cmd.rs:303`).
- Hint sites to fill (CLI v0.46.0 text verbatim):
  | Code / emitter | CLI hint | CLI source |
  |---|---|---|
  | invalid_input, `remotes.rs:454-470 fetch_error` RemoteName (move out of reason; drop doc :456-457 "no hint channel") | "Run `jj git remote rename` to give a different name." | command_error.rs:587-588 |
  | invalid_input, `expand_fetch_refspecs(..).map_err(invalid)` `remotes.rs:507,:523`, `remote_changes.rs:120` — `Expression` variant only | "Specify patterns in `(positive \| ...) & ~(negative \| ...)` form." | :604-609 |
  | jj_lib_error, clone `creation.rs:268` (RemoteName), `:562` (refspec) | the two above | same |
  | bookmark_exists, `bookmark_ops.rs:236` | "Use `jj bookmark set` to update it." | bookmark/create.rs:70 |
  | bookmark_exists, `push.rs:959` | "Use 'jj bookmark move' to move it, and 'jj git push -b {symbol}' to push it" | git/push.rs:1260-1262 |
  | bookmark_tracked_remote_exists, `bookmark_ops.rs:241`, `push.rs:964` | the two create.rs:77-81 / push.rs:1269-1272 hints | |
  | path_not_ignored, `wc_ops.rs:502` | file/untrack.rs:95-98 hint | |
  | git_repo_exists, `creation.rs:195` | init.rs:233-236 hint | |
  | undo_cross_workspace, `op_log.rs:173` | undo.rs:129-132 hint | |
  | invalid_input undo-merge, `op_log.rs:195` (also fix reason casing to the CLI's "Cannot undo a merge operation") | "Consider using `jj op restore` instead" | undo.rs:161-163 |
  | invalid_input squash-a-merge, `squash_split.rs:339` | "Use `--into` to specify which parent to squash into" | squash.rs:243-244 |
  | invalid_input push `--named` ×3, `push.rs:935-951` | "For example, `--named myfeature=@` is valid syntax" | push.rs:1278-1297 |
  | push_ref_refused `push.rs:1222` / push_commit_rejected `:1270` (hints computed for the dry-run plan, dropped on the error) | `refusal.hint` / `rejection.hints` | push.rs:768-773, :1148-1153 |
  | immutable, `op_support.rs:110-123 check_rewritable` (non-root only) | "Could not modify commit: <summary>", "Immutable commits are used to protect shared history.", the indoc "For more information, see: …" block, "This operation would rewrite {n}[ or more] immutable commits." (`immutable ∩ to_rewrite.descendants()` `count_estimate`) | cli_util.rs:2049-2083 |
  | stale_working_copy, `snapshot.rs:846` (per kind: stale / sibling op / not found) | cli_util.rs:3046-3074 | |
  | config_unrecognized_file, `config_cmd.rs:719,757` | cli/src/config.rs:737-741 | |
  | repo_not_found where `.git` exists — port only if `map_repo_err NotARepo` already distinguishes it, else note as not ported | cli_util.rs:2914-2918 | |
- `crates/zanshin-jj/src/push.rs:475 commit_summary` -- reuse (make `pub(crate)`) for the immutable "Could not modify commit:" hint.
- Dart: `packages/zanshin_core/lib/src/worker/responses.dart:101-151 ZanshinFfiException` (add `final List<String> hints`, default `const []`, set by `.withReport`); single decode choke point `lib/src/ffi/precondition.dart:183-191 decodeEnvelopeErrorInternal`; mirror `lib/src/ffi/warning.dart:335-341` (absent → `const []`, unmodifiable); `lib/src/ffi/drop_actions.dart:360-380 ActionRefusal`. Tests: `test/ffi/warning_test.dart:66-109`, `test/worker/error_reports_test.dart`, `test/ffi/fetch_test.dart:~113`, `test/ffi/drop_actions_test.dart`.
- Docs: `docs/ffi-abi.md` :55-74 (Envelope/FfiError), :76-104 (warnings precedent), :1563-1565 (remove the in-band sentence), :1596/:1616 (refusal); `docs/rust-error-codes.md` (:65, :81, :86-88 notes; add a "carries hints" note per code).
- Witnesses to update: `crates/zanshin-jj/tests/it/git_fetch_parity.rs:987-1017 a_remote_named_git_refuses_with_the_rename_hint`; unit test `remotes.rs:638-647`; `:739 the_poll_refuses_what_the_fetch_refuses` (malformed pattern); FFI `crates/zanshin-ffi/tests/it/repo_write_ffi.rs:785-1030`; `repo.rs` `map_mutate_err_*` tests :1888-2036; `envelope.rs` tests from :1190, `ok_drop_actions_writes_every_row_with_its_mapped_refusal` :1616.

**Item 2 — finish resolves the immutable set**
- `crates/zanshin-jj/src/mutate.rs:750-768 finish_verb` -- add (before the lock) `if tx.repo().has_changes()`: `resolve_immutable(tx.base_repo().as_ref(), &ctx.immutable)?` + `rebase_descendants_with_options`. Template: `creation.rs:474-495 finish` (already an exact port). `finish_transaction` :669-741 / `wc_is_immutable` :625-638 (soft resolve against `tx.repo()`, mirrors CLI :2372 — keep).
- Now-redundant per-verb resolutions (remove in favor of the shared finish): `commit.rs:204-209`, `remotes.rs:568-575` (fetch), `push.rs:1889-1895` (`record_push`), `git.rs:337` (git_import — currently inside the `finish_or_no_op` closure, so a no-op import refuses where the CLI says "Nothing changed."; moving it fixes that).
- Unguarded callers now covered: `new_change` `mutate.rs:1018-1094` (plain `rebase_descendants()` :1079/:1090 standing in for the finish rebase → let the shared finish do it), `op_log.rs:210` undo, `git.rs:459` export, `:503` remote add, `:589` remove, `:640` rename, `bookmark_ops.rs:226` create, `:349` delete; plus grep every other `finish_verb`/`finish_or_no_op*` caller (op restore/revert if present). `finish_or_no_op(_at)` :1362-1430 already skips on no changes.
- `crates/zanshin-jj/src/workspace_add.rs:218-221` -- calls `finish_transaction` directly after a plain `rebase_descendants()`: resolve `new_env.immutable` the same way. jj-lib writes the "add workspace" op earlier (`Workspace::init_workspace_with_existing_repo`); match the CLI's resulting on-disk state (verify with the pinned `jj`).
- Matches the CLI already, leave: `wc_ops.rs` file track/untrack (`commit_with_locked_wc` :1509, CLI `tx.commit`), `squash_split.rs:714` split (guarded :617), snapshot/import_git_head/stale recovery, `convert.rs:409`.
- Plans/rows (`crates/zanshin-jj/src/drop_actions.rs`; `outcome` :192-213 already turns `Config` into Refused): `plan_new` `mutate.rs:930-957` (resolve also without `-A`/`-B`), `duplicate.rs:67 plan_duplicate` (non-insert), `revert.rs:67-71 plan_revert` (when the plan is Some), bookmark move plan (`drop_actions.rs:453-472`, FastForward/Backwards only; NoOp stays NoOp). Rows: `change_actions.new_onto` :538+, `NewMerge` :410-412, `Duplicate` :413-418, `Revert` :309-325, `BookmarkMove` :453-472.
- Tests: `crates/zanshin-jj/tests/it/new_insert.rs:384-400 only_insert_resolves_the_immutable_set` (plain-new half flips; rename/redoc), `:402-414` neighbour; `tests/it/drop_actions.rs`; `tests/it/op_support.rs:276`.
- Oracle `crates/zanshin-parity/tests/oracle/`: `scenarios.rs` (`Scenario` :46-58, `BASE` :31-39, `describe_immutable` :813-830 shows `Step::Jj(&["config","set","--repo","revset-aliases.'immutable_heads()'", …])`, `new_on_wc` :607-614), register ids in `main.rs` `parity!(…)` :38+, ledger `ledger.rs` (`Expected { scenario, aspect, reason, reference, zanshin, cli }`; aspect `warnings` counts CLI `Warning: ` lines, `compare.rs:49`). CLI argv must avoid change/commit-id args (they fail in the prefix resolver before finish) — use `@`, names, or none. Expect ~4 CLI start-up "Warning: In template expression" lines (short-prefixes index fails) → a `warnings` ledger entry per scenario with the observed numbers.

**Item 3 — push remote order**
- `crates/zanshin-jj/src/push.rs:784-809 resolve_remotes` -- build `union_expression(texts)?` / `configured_remotes(config, PUSH_REMOTES)?` (:848) BEFORE `get_all_remote_names` (`→ NotAGitRepo`), exactly like `remotes.rs:293-322 resolve_fetch_remotes`. Callers `plan_push` :1316/:1332 (dry run and real push share it).
- Tests to mirror: `tests/it/git_fetch_parity.rs:942 a_malformed_git_fetch_setting_refuses_before_the_backend_check`, `:967 an_unparsable_remote_pattern_refuses_before_the_backend_check`; native repo = `Repo::init(&InitOptions { path, ..Default::default() })`; push call `repo.git_push(&GitPushArgs{..}, &|_: ProgressEvent| {}, None)`; add to `tests/it/push_remotes.rs`.

**Item 4 — real `num_rewritten`**
- `crates/zanshin-jj/src/git.rs:369-401 project_import` (`num_rewritten = stats.rewritten_commit_ids.len()`), used by `git_import` :346 and fetch `remotes.rs:583/591`.
- jj-lib 0.46.0 `git.rs:821-900 record_synthetic_predecessors`: an old commit counts only when a new referenced commit carries the SAME change id (a `change-id` commit header). Abandoned commits go to `abandoned_commits`, not here — plain `git commit --amend` (no header) yields 0, which is why today's tests see 0.
- Fixture: commit X written by jj (header present, `write-change-id-header` default on) reaches the remote; the local repo fetches it, adds a child; upstream replaces X with X' carrying the same `change-id` header (e.g. `git cat-file commit X` → edit message → `git hash-object -t commit -w --stdin` → `update-ref` + mirror push); fetch → `num_rewritten == 1`, child rebased onto X'. For `git import`, set the Git ref in the backing store to X' and import. Helpers: `git_fetch_parity.rs` `Upstream` :41 / `Fx` :118 / `publish` :95; `git_sync.rs` `git_cmd` :29, `git_store` :50. jj model: `../jj` `lib/tests/test_git.rs:2072`.

## Tasks & Acceptance

**Execution:**
- `schemas/envelope.fbs` -- append `hints: [string]` to `FfiError` with doc; run `cargo make codegen`, commit outputs -- wire field.
- `crates/zanshin-jj/src/{mutate.rs,repo.rs,snapshot.rs,config_cmd.rs}` -- add `pub fn hints(&self) -> Vec<String>` to each error enum that can carry a CLI hint (derive constant/data-derived hints from the variant); add a `hints: Vec<String>` field only to `MutateError::InvalidInput`, `Immutable`, `BookmarkExists` (site-dependent texts); provide a small constructor so hint-less sites stay terse; update every construction/pattern mechanically (`..` in patterns) -- Rust carrier.
- `crates/zanshin-jj/src/{remotes.rs,remote_changes.rs,creation.rs,bookmark_ops.rs,push.rs,wc_ops.rs,op_log.rs,squash_split.rs,op_support.rs}` -- fill the hint table's sites; strip the in-band `Hint:` from fetch's reason; immutable hints via `commit_summary` + `count_estimate` -- CLI hints.
- `crates/zanshin-ffi/src/envelope.rs` + every `map_*_err` -- carry `hints` into `FfiErrorObj` and write them in `err_with_report`, `err_never_unwind`, `build_action_outcome` (None when empty) -- FFI.
- `packages/zanshin_core/lib/src/{worker/responses.dart,ffi/precondition.dart,ffi/drop_actions.dart}` -- `ZanshinFfiException.hints`, `ActionRefusal.hints`, decode absent → `const []` -- Dart.
- `crates/zanshin-jj/src/mutate.rs` (`finish_verb`, `new_change`, `plan_new`), `workspace_add.rs`, `commit.rs`, `remotes.rs`, `push.rs`, `git.rs`, `duplicate.rs`, `revert.rs`, `drop_actions.rs` -- shared has_changes-gated resolution; remove the redundant per-verb copies; plans of unguarded rows resolve -- item 2.
- `crates/zanshin-jj/src/push.rs` -- reorder `resolve_remotes` -- item 3.
- Tests: Rust `tests/it/{git_fetch_parity,new_insert,drop_actions,push_remotes,git_sync,…}.rs` + inline unit tests for every new hint path and the `hints()` accessors; FFI `tests/it/repo_write_ffi.rs` (reserved-remote fetch carries `hints`, context clean) + envelope unit tests (empty hints → no field; fallback bytes unchanged; refusal row hints); a `zanshin_core` real-cdylib test that `ZanshinFfiException.hints` arrives (worker path) and a decode unit test for `ActionRefusal.hints` -- witnesses.
- `crates/zanshin-parity/tests/oracle/{scenarios.rs,main.rs,ledger.rs}` -- scenarios `new_unresolvable_immutable`, `bookmark_create_unresolvable_immutable`, `git_export_unresolvable_immutable` (or `undo_…`) with ledger entries for the observed CLI-only warnings -- item 2 parity.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- document the field and which codes carry hints; drop the in-band sentence -- docs.

**Acceptance Criteria:**
- Given a remote named `git`, when the user fetches through Rust, the FFI and Dart, then the error is `jj.invalid_input` whose context has no "Hint:" and whose hints equal the CLI's rename hint.
- Given a malformed fetch ref expression (`GitRefExpansionError::Expression`), when fetch or the poll runs, then the refusal carries the CLI's pattern hint.
- Given any hint-less refusal (e.g. `jj.not_a_git_repo`), when it crosses the FFI, then the envelope has no `hints` field and Dart's `hints` is empty; the panic fallback envelope's bytes are unchanged.
- Given each row of the Code Map hint table, when the refusal is triggered, then its hints equal the CLI's text in the CLI's order (one test per site).
- Given an unresolvable `immutable_heads()` alias, when `new` (positional), `bookmark create`, and one more unguarded finish caller run in the oracle, then both Zanshin and the CLI refuse (`jj.config_error`) and write no operation; `new_onto`, `NewMerge`, `Duplicate`/`Revert` onto and FF `BookmarkMove` rows read Refused `jj.config_error`; `new_insert.rs`'s plain-new half asserts the refusal.
- Given an unresolvable alias and a no-change `git import`, when it runs, then it returns the no-op result as the CLI does.
- Given a native-backend repo, when `git push` runs with a malformed `git.push` / an unparsable `--remote`, then it refuses `jj.config_error` / `jj.invalid_input`.
- Given the same-change-id force-push fixture, when fetch and `git import` run, then each reports `num_rewritten == 1` and the local child sits on the rewrite.

## Spec Change Log

## Review Triage Log

## Design Notes

**Why `hints()` plus a few fields.** Most hints are constant per variant or derived from its data (bookmark name, stale kind), so a `hints()` accessor keeps those variants unchanged and lets each FFI mapper set `FfiErrorObj.hints = e.hints()` uniformly. Only variants reused by sites with different CLI hints (`InvalidInput` across fetch/undo/squash/push, `Immutable` needing a repo-computed summary/count, `BookmarkExists` differing between `bookmark create` and `git push`) need a field. Shape:
```rust
MutateError::InvalidInput { reason: String, hints: Vec<String> }
impl MutateError { pub fn hints(&self) -> Vec<String> { match self { Self::InvalidInput { hints, .. } => hints.clone(), Self::PathsNotIgnored { .. } => vec![PATHS_HINT.into()], _ => vec![] } } }
```

**Why gate on `has_changes()` in `finish_verb`.** CLI `finish` returns "Nothing changed." before `rebase_mutable_descendants` (`cli_util.rs:2849-2858`), so a no-change verb never resolves; `finish_verb` itself has no such gate (ledger `describe_no_change`, Story 9.40), so the resolution carries its own.

## Verification

**Commands (targeted; the story loop runs the full gate):**
- `cargo make codegen` -- expected: regenerated files committed, `git status` clean afterwards.
- `cargo test -p zanshin-jj` (or `--test it <module>::` per touched module + `--lib`) -- expected: green.
- `cargo test -p zanshin-ffi` -- expected: green.
- `cargo test -p zanshin-parity --test oracle` -- expected: green, ledger has no UNEXPECTED/CHANGED/STALE.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean.
- `flutter test` / `dart analyze` / `dart format --set-exit-if-changed .` in `packages/zanshin_core` -- expected: green (zanshin_core tests need the cdylib built as the gate builds it).
