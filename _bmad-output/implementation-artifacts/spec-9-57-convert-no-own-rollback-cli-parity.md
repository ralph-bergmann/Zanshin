---
title: 'Story 9.57 — `convert` leaves on disk what the CLI leaves: no own rollback, refuses under a broken `immutable_heads()`'
type: 'feature'
created: '2026-10-22'
status: 'ready-for-dev'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      A failed `Repo::init` over an existing `.git/` (the same External steps as `convert_colocated`) and a
      failed `init` of a new destination do not report what they left on disk; only the two convert verbs
      fill `CreationOutcome.left_behind`.
    evidence: |-
      `crates/zanshin-jj/src/creation.rs:187` (`create_or_reuse_dir` destination) and `:200`
      (`init_over_git_dir`, no rollback since Story 9.20); Story 9.57 scopes the "partial state left" fact
      to `convert`. Filling it there is the same existence check.
    location: >-
      crates/zanshin-jj/src/creation.rs:148
    severity: low
  - summary: >-
      `clone`'s finish maps an unresolvable `immutable_heads()` to `RepoError::CloneFailed`
      (`jj.jj_lib_error`), while the CLI's `tx.finish` reports a `Config error` (Zanshin: `jj.config_error`).
    evidence: |-
      `crates/zanshin-jj/src/creation.rs:486-487` (`resolve_immutable(..).map_err(|e| clone_failed(..))`);
      CLI v0.46.0 `cli_util.rs:2986-3002` `rebase_mutable_descendants` → `resolve_immutable_expression`
      config error. The refusal itself matches; only the code differs.
    location: >-
      crates/zanshin-jj/src/creation.rs:486
    severity: low
---

<intent-contract>

## Intent

**Problem:** Both convert verbs delete on failure what they think they created (`convert.rs:217` removes `<root>/.jj`; `:331-335` removes the whole destination or its `.jj/`) — a check-then-delete that can remove a `.jj/` another process created and that the CLI never does; and `convert_import`'s "import git head" finish (`convert.rs:655`) rebases without resolving the immutable set, so it succeeds under an unresolvable `immutable_heads()` where `jj git init --git-repo` refuses (deferred-work I1, Story 9.56).

**Approach:** Drop the own rollback in `convert_colocated` / `convert_import` entirely (jj-lib's own `.jj` removal in `init_with_factories` stays), route the head import's finish through the CLI's `tx.finish` order (resolve the immutable set against `tx.base_repo()` → `jj.config_error`, rebase the mutable descendants, then lock + finish), and report the paths a failed conversion created and left behind as a typed field: `CreationOutcome.left_behind` → `FfiError.left_behind` → `ZanshinFfiException.leftBehind`, so the UI can offer the decision. Docs state the new contract.

## Boundaries & Constraints

**Always:**
- CLI v0.46.0 observable behavior is the spec (`git -C ../jj show v0.46.0:cli/src/commands/git/init.rs`, `cli_util.rs:2849-2866`, `:2986-3002`): `do_init` propagates every error with `?` and cleans up nothing; `create_or_reuse_dir` leaves a destination it created.
- The working copy and `.git/` stay untouched, as today. Success paths write exactly what they write today.
- `left_behind` lists, outermost first, the paths a FAILED conversion created that still exist after the failure: `convert_colocated` → `<canonical root>/.jj` if present; `convert_import` → the topmost directory the call created on the way to the destination (first missing ancestor of `workspace_path`, recorded before any write; `create_dir_all` is the bridge's documented liberalization) if present, then `<workspace_path>/.jj` if present. Empty on success and on every refusal that wrote nothing (precondition / start-up config checks, jj-lib's self-cleaning `init_external_git` failure leaves only a created destination). A failed re-open counts as a failure (its `.jj/` is listed).
- Wire: append `left_behind: [string]` to `FfiError` (after `hints`); empty writes NO field, so `PANIC_FALLBACK_ENVELOPE` and every other error stay byte-identical. Source it from the FFI `CallReport` (new `left_behind: Vec<String>`), filled only in `creation_envelope_for` from the outcome; written only by the error writer. Edit `schemas/envelope.fbs` in place, run `cargo make codegen`, commit the output.
- Dart: `ZanshinFfiException.leftBehind` (`List<String>`, `const []` default, unmodifiable when decoded, absent → `[]`), decoded at the one choke point `decodeEnvelopeErrorInternal`; `toString()` prints it when non-empty, as it does `hints`.
- The head-import finish error maps `MutateError::Config` → `RepoError::Config` (`jj.config_error`), everything else → `RepoError::ConvertFailed`. The colocated arm keeps NOT resolving (the CLI's colocated `do_init` runs no `tx.finish`; its snapshot's head import uses `finish_transaction` directly).
- Tests per project-context.md layout (`tests/it/<module>.rs`, `pin_test_env()` first, env-changing tests `own_process!`).

**Never:**
- No deletion of anything by the backend on a convert failure (no "safe" partial cleanup either). No UI. No MCP change. No new error code; `jj.convert_failed` / `jj.config_error` keep their meaning. No warning code for the left-behind fact (warnings stay the CLI's `ui.warning_*` lines).
- Do not change `init` / `clone` behaviour or reporting (see `deferred:`); clone keeps its CLI-parity cleanup.
- Never regenerate fixtures; never lower the coverage baseline.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Unresolvable alias, import | user config `revset-aliases."immutable_heads()" = "nonexistent_symbol_xyz"`; `convert_import(src with a commit, new dest)` | `Err(RepoError::Config)` (`jj.config_error`) at the head-import finish; `dest/.jj` with ops `add workspace` + `import git refs` stays; `left_behind == [dest, dest/.jj]` | as the CLI (oracle) |
| Unresolvable alias, colocated | same alias; `convert_colocated(git repo)` | succeeds, as the CLI | — |
| init_external_git fails | source `.git` empty dir; `convert_import(src, new dest)` | `ConvertFailed`; jj-lib removed `dest/.jj`; `dest` stays; `left_behind == [dest]` | — |
| init_external_git fails, colocated | empty `.git` dir; `convert_colocated` | `ConvertFailed`; no `.jj`; `left_behind` empty | — |
| Late failure (blocked `.jj/.gitignore`, uncreatable repo config for the `trunk()` alias, refs-step config fault, snapshot fault, failed re-open) | as the existing tests force them | `.jj/` stays as written up to the failure; `left_behind == [<root>/.jj]` (import: `[dest, dest/.jj]` when dest was created) | — |
| Refusal before writing | not a Git repo / already jj / user-level config fault | today's error, `left_behind` empty, nothing created | — |
| Nested new destination | `convert_import(src, <tmp>/a/b)` with `a` missing, failing | `left_behind[0] == <tmp>/a` | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/convert.rs` -- module doc :38-105 ("rollback below…", "One deliberate departure", "rollback then removes the state it describes"), `convert_colocated` doc :144-186 + rollback :213-220, `convert_import` doc :223-281 + `created_dir` rollback :327-338, `init_over_git_dir` doc :526-529 ("WITHOUT convert_colocated's rollback"), `convert_into` / `import_into` docs :539-584 ("the caller rolls back", "rolled back with the directory" :570), `ConversionReport::into_outcome` :133-142 (add `left_behind`), `import_head_into_destination` :637-668 (plain `rebase_descendants()` :655 → CLI finish order). Inline tests :670-809 (`external_workspace` helper for a forced late failure).
- `crates/zanshin-jj/src/repo.rs:139-154` -- `CreationOutcome` (add `pub left_behind: Vec<PathBuf>`; doc :147-151 "state the rollback has since removed"); every literal: `repo.rs:2783` (`open_with_report`), `creation.rs:152`, `:253`; `RepoError::ConvertFailed` doc :89 ("has been rolled back").
- `crates/zanshin-jj/src/creation.rs:482-504` -- clone's `finish`: the exact port of the CLI finish order to mirror (resolve against `tx.base_repo()` → `rebase_descendants_with_options` → `lock_git_import_export` → `finish_transaction`); :200 comment mentions the conversion's rollback — reword.
- `crates/zanshin-jj/src/op_support.rs:86 resolve_immutable` -- returns `MutateError::Config` on an unresolvable alias. `mutate.rs:832-859 finish_verb` -- same order for verbs (reference only).
- Tests to flip from "rolled back" to "left as the CLI leaves it" (+ assert `left_behind`): `crates/zanshin-jj/tests/it/convert.rs:267-292` (empty `.git`, jj-lib self-cleans → `.jj` absent, `left_behind` empty), `:654-676` (dest stays, `left_behind == [dest]`), `:741-763` (pre-existing dest, no `.jj`, empty); `tests/it/convert_alias_write_failure.rs:30-83` (`.jj` stays); `tests/it/creation_warnings.rs:498-670` (five helpers asserting `!….join(".jj").exists()`, incl. import: dest + `.jj` stay); `tests/it/config_identity.rs:740-765` (colocated: jj-lib cleaned → unchanged; import: `import_dest` now exists); `tests/it/api_stability.rs:1665` (`CreationOutcome` literal).
- `crates/zanshin-ffi/src/envelope.rs` -- `CallReport` :432-447 (add `left_behind: Vec<String>`; literals also `config.rs:608`, `envelope.rs:1258/:1350`, `snapshot.rs:163/:167/:351`, `graph.rs:822`, `repo.rs:693`), `build_ffi_error` :1107-1135 (add the vector, `None` when empty), `err_with_report` :1150-1176 (pass `report.left_behind`), `build_action_outcome` :947 (refusals: none). Tests from :1190 (`err_with_report_writes_hints_only_when_there_are_some` :1927 is the model).
- `crates/zanshin-ffi/src/repo.rs:686-704 creation_envelope_for` -- copy `outcome.left_behind` (`to_string_lossy`) into the `CallReport`; `zanshin_repo_convert` doc :985-1060 ("If the operation fails, `.jj/` is rolled back …", "describes state the rollback removed"); `zanshin_repo_init` doc :761 ("without its rollback"); test literals :2198, :2224. FFI integration tests `crates/zanshin-ffi/tests/it/repo_ffi.rs:681-900` (`zanshin_repo_convert`) — add an error-envelope `left_behind` witness.
- `schemas/envelope.fbs:30-34` -- `FfiError` (append `left_behind: [string];` with doc); the `Precondition` table doc that the generated files quote ("describes state the rollback removed", `envelope_generated.rs:27514`) — reword. `Makefile.toml [tasks.codegen]` regenerates `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`, header + `bindings.dart` (the `zanshin_repo_convert` rustdoc is copied into `bindings.dart:2214-2238`, `:2292`).
- Dart `packages/zanshin_core/lib/src/worker/responses.dart:95-160` (`ZanshinFfiException`: field, `withReport` param, `toString`), `lib/src/ffi/precondition.dart:184-205` (`decodeEnvelopeErrorInternal`, `decodeErrorHintsInternal` as the model), `lib/src/ffi/repo.dart:171-175` and `lib/src/worker/commands.dart:376`, `isolate.dart:82-84` (convert docs). Tests: `test/worker/error_reports_test.dart:136-160` (real cdylib; flip `.jj` assertion, assert `leftBehind == [<canonical root>/.jj]` — macOS temp dirs are symlinks, compare `resolveSymbolicLinksSync()`), a decode unit test next to the hints one (`test/ffi/warning_test.dart:66-109` or `test/worker/` decode tests).
- Docs: `docs/ffi-abi.md:57-74` (Envelope/FfiError block: add `left_behind`), :160-175 and :670-700 (convert: "a rollback never deletes or rewrites", "although the rollback removes `.jj/`"); `docs/rust-error-codes.md:52` (`jj.convert_failed`: no rollback; `left_behind`), `:58` (`jj.config_error`: add the convert-import head-import emitter, Story 9.57).
- Oracle `crates/zanshin-parity/tests/oracle/`: `git_scenarios.rs:24-195` (`Prep`, `CreationScenario`, `SOURCE`, `GIT_HERE`, `CREATION_SCENARIOS`), `harness.rs:86-116` (`run_creation`, `created` — a failed side without `.jj` contributes its file listing), `driver.rs:38-50` (`command` pins `JJ_CONFIG=""` via `TEST_ENV`), `main.rs:24-36` (`parity!`), :238-242 (`every_scenario_has_a_test`, count 187), `ledger.rs` (`Expected { scenario, aspect, reason, reference, zanshin, cli }`). `test_helpers::reran_in_own_process(module_path!(), name)` (`crates/test-helpers/src/lib.rs:134-190`) is callable directly where `own_process!`'s `$test:literal` can't take `stringify!`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/repo.rs` -- add `CreationOutcome.left_behind: Vec<PathBuf>` (doc: failed conversions only, outermost first, what the call created and left; nothing is deleted); fill `vec![]` at every other literal; reword the `precondition` / `ConvertFailed` docs -- typed fact.
- `crates/zanshin-jj/src/convert.rs` -- delete both rollback blocks; record the import's first missing ancestor before `import_into`; on `Err` fill `left_behind` by existence (colocated `<root>/.jj`; import `[created top dir, <workspace_path>/.jj]`); `import_head_into_destination`: drop the plain `rebase_descendants()`, and when `has_changes()` resolve `env.immutable` against `tx.base_repo()` (`Config` → `RepoError::Config`) and `rebase_descendants_with_options` before the lock; rewrite every rollback sentence in module/fn docs to "convert never touches the working copy or `.git/`; on failure the disk is as `jj git init` leaves it, and `left_behind` names what was created"; inline unit tests for the existence/ancestor helper (incl. relative and nested paths) and the error mapping -- items 1, 2, 4.
- `crates/zanshin-jj/src/creation.rs` -- reword the `:200` comment only -- docs.
- `crates/zanshin-jj/tests/it/{convert,convert_alias_write_failure,creation_warnings,config_identity,api_stability}.rs` -- flip the rollback assertions to the CLI's on-disk state, assert `left_behind`, cite the CLI code path (`git/init.rs` `do_init` `?` propagation) on the rows the oracle can't drive (blocked `.jj/.gitignore`, failed re-open, snapshot fault on an unreadable file); add: unresolvable alias → import refuses `Config` with `.jj` + `left_behind`, colocated succeeds; nested new destination → `left_behind[0]` is the topmost created dir. The re-open failure needs no fixture of its own: `left_behind` is computed in ONE place over the `Err` of the whole post-precondition tail (`convert_into`/`import_into` then `Repo::open`) -- witnesses.
- `schemas/envelope.fbs`, then `cargo make codegen` -- `FfiError.left_behind`; Precondition doc reword -- wire.
- `crates/zanshin-ffi/src/{envelope.rs,repo.rs,config.rs,snapshot.rs,graph.rs}` -- `CallReport.left_behind`, written into `FfiError` by the error writer only (`None` when empty); `creation_envelope_for` copies it; doc rewrites in `repo.rs`; envelope unit tests (empty → no field, fallback bytes unchanged, non-empty → in order); FFI integration test in `tests/it/repo_ffi.rs`: `zanshin_repo_convert` over a Git repo with a mode-`0o000` new file (the snapshot fault the Dart test uses) carries `FfiError.left_behind == [<canonical root>/.jj]` and `.jj` exists -- FFI.
- `packages/zanshin_core/lib/src/{worker/responses.dart,ffi/precondition.dart,ffi/repo.dart,worker/commands.dart,worker/isolate.dart}` + tests -- `leftBehind`, decode, docs; flip `error_reports_test.dart`'s conversion test -- Dart.
- `crates/zanshin-parity/tests/oracle/{git_scenarios.rs,harness.rs,driver.rs,main.rs,ledger.rs}` -- parity scenarios `convert_colocated_default` (GIT_HERE, `jj git init --colocate`), `convert_import_default` (SOURCE, `jj git init --git-repo src dest`), `convert_import_invalid_source` (`src/.git` without objects, e.g. `Prep::Write("src/.git/description", …)`; dest left, no `.jj`); own-process creation tests that set a user config through `JJ_CONFIG` (driver: pass the process's `JJ_CONFIG` through instead of the pinned `""` — identical in the shared process) and restore it before the read-back: `convert_import_unresolvable_immutable` (both refuse, `.jj` equal), `convert_colocated_unresolvable_immutable` (both succeed), `convert_import_refs_step_config_fault` (`[remotes.origin] auto-track-bookmarks = "glob:("`); ledger entries only for divergences actually observed, each with its reason; keep `every_scenario_has_a_test` exhaustive (count updated, own-process ids included in the defined set) -- parity witnesses.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- new failure contract, `FfiError.left_behind`, `jj.config_error` emitter -- item 4.

**Acceptance Criteria:**
- Given any convert failure after jj-lib created `.jj/`, when it returns, then no file the call wrote is removed by Zanshin, `.git/` and the work tree are unchanged, and `left_behind` names `.jj/` (and the created destination for an import).
- Given the oracle's convert scenarios (default colocated, default import, invalid source, unresolvable alias import/colocated, refs-step config fault), when they run against the pinned `jj git init`, then the ledger reports no UNEXPECTED / CHANGED / STALE: outcome, op log and files match (the invalid-source and refusal sides compare their file listings).
- Given an unresolvable `immutable_heads()` alias and a source with a commit, when `convert_import` runs through Rust, then it refuses `RepoError::Config` after `.jj/` exists, as the CLI; `convert_colocated` under the same alias succeeds.
- Given a failing `zanshin_repo_convert`, when the error envelope is decoded in Rust and in Dart (real cdylib), then `FfiError.left_behind` / `ZanshinFfiException.leftBehind` equal `[<root>/.jj]`; every other error (and `PANIC_FALLBACK_ENVELOPE`) writes no `left_behind` field and decodes to `[]`.
- Given the docs, when read, then no convert doc (rustdoc, `.fbs`, generated bindings, Dart, `ffi-abi.md`, `rust-error-codes.md`) still promises a rollback; each states that convert never touches the working copy and that on failure the disk is as the CLI leaves it.

## Spec Change Log

## Review Triage Log

## Design Notes

**Why a typed `FfiError.left_behind`, not a warning.** Every warning code is a CLI `ui.warning_*` line (registry rule, 9.32); the CLI prints nothing about a half-initialised repo. The fact is error detail with structure (paths the UI may offer to delete), like `hints` (9.56), so it rides `FfiError` and is sourced from the call's `CallReport` — no change to the 76 `FfiErrorObj` literals, and `ActionOutcome.refusal` never sets it.

**Head-import finish, CLI order** (`do_init` → `tx.check_out` + `tx.finish`):
```rust
if !tx.repo().has_changes() { return Ok(()); }
let immutable = resolve_immutable(tx.base_repo().as_ref(), &env.immutable).map_err(repo_error)?; // Config → RepoError::Config
block_on(tx.repo_mut().rebase_descendants_with_options(&immutable, &RebaseOptions::default(), |_, _| {}))…;
let lock = lock_git_import_export(workspace, false)…; finish_transaction(…)
```

## Verification

**Commands (targeted; the story loop runs the full gate):**
- `cargo make codegen` -- expected: regenerated files committed, a re-run leaves the tree clean.
- `cargo test -p zanshin-jj` (or `--lib` + `--test it convert:: creation_warnings:: config_identity:: convert_alias_write_failure:: api_stability::`) -- expected: green.
- `cargo test -p zanshin-ffi` -- expected: green.
- `cargo test -p zanshin-parity --test oracle` -- expected: green, no UNEXPECTED / CHANGED / STALE.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity -p zanshin-mcp --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed .`, `dart test` (real cdylib, gate env); `dart analyze` in `app/` -- expected: green.
