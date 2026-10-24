---
title: 'Story 9.10 — Working-copy movement: next, prev'
type: 'feature'
created: '2026-10-24'
status: 'ready-for-dev'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Zanshin has no `jj next` / `jj prev`: the GUI cannot step the working copy to a child/parent (or the next/previous conflicted commit) with the CLI's exact target computation, refusals and op descriptions, and the CLI's terminal prompt for an ambiguous target has no GUI counterpart.

**Approach:** Port `cli/src/movement_util.rs` @ v0.46.0 (`move_to_commit`, `get_target_commit`, `build_target_revset`, `target_not_found_error`) into a new `zanshin-jj` module. Replace the prompt by a read call that returns the candidate targets (CLI order) and an optional `target` commit id on the verb, so the GUI picks. Wire both through FFI and `packages/zanshin_core`, with parity-oracle scenarios.

## Boundaries & Constraints

**Always:**
- Behave like the CLI at v0.46.0, in its order: clap checks (refused before the snapshot, via `with_checked_verb`), then the pre-verb snapshot, then the `@` lookup, the `ui.movement.edit` read, the no-children check, target evaluation, the not-found refusal, choosing one target, `check_rewritable` (edit only), the transaction and its finish.
- `should_edit = edit || (!no_edit && ui.movement.edit)`. `ui.movement.edit` is read from the effective config (`get_bool`, default `false` from jj-cli's own misc layer, already in the stack). A non-bool value refuses `jj.config_error`, naming the key.
- `offset: Option<u64>`, where `None` means the CLI default `1`. `Some(_)` together with `conflict` is clap's `conflicts_with = "offset"` and is refused. Clap never fires on its default, so `None` + `conflict` is fine. `edit && no_edit` is refused too. Both refusals are `jj.invalid_input`, before the snapshot.
- Next non-edit uses `offset.wrapping_sub(1)` on the u64, as the release CLI does. Offset `0` then hits `descendants_at(u64::MAX)` (an empty range), so it is refused as not-found.
- Refusal texts, op descriptions and hints are the CLI's, verbatim:
  - Op descriptions: `{next|prev}: {12-hex @} -> editing {12-hex target}` and `{next|prev}: {12-hex @} -> {12-hex target}`.
  - Not-found refusals: the eight `target_not_found_error` messages. Their hints are one per start commit, `Working copy: <summary>` or `Working copy parent: <summary>`, rendered with `Templates::commit_summary`.
  - The no-children refusal: `The working copy must not have any children`, with the hint ``Create a new commit on top of this one or use `--edit` ``.
- No `@` in this workspace refuses `MutateError::NoWorkingCopy` (`jj.no_working_copy`), as `commit` does (9.49).
- Candidates are the target revset's commits in its stream order, which is the order of the CLI's prompt list.
  - With `target: Some(id)`: when `id` is a candidate, use it; when it is not, refuse `jj.stale_selection` (the context names the id and says it is not a `{next|prev}` target).
  - With `target: None` and one candidate: use it.
  - With `target: None` and several: refuse `jj.invalid_input` with the reason `ambiguous {next|prev} commit, choose one to target` (the CLI's prompt header).
- The edit form: `guard_rewritable` on the target, then `MutableRepo::edit`. The non-edit form: `MutableRepo::check_out` (a new `@` on the target). Both go through `finish_verb`, so the 9.40 no-change gate applies (e.g. `prev` offset 0 `--edit` writes no operation).
- The targets call runs exactly the verb's steps up to choosing a target, including its refusals. It writes no operation except the pre-verb snapshot's.

**Never:** no terminal prompt or stdin; no MCP tool; no UI code; no Zanshin-chosen default when ambiguous; no new error or warning code; no `jj_cli` type in a public position; never regenerate fixtures.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| next default | `@` is an empty head on B, and B has child C | New `@` on C; op `next: <@> -> <C>` | — |
| next --edit | `@` = B, child C | `@` = C; op `next: <B> -> editing <C>` | — |
| next 2 / prev 2 | linear stack | Moves 2 generations; prev non-edit counts from `@`'s parents | — |
| prev default / --edit | `@` on C | New `@` on C's parent / `@` = parent | — |
| --conflict | Conflicted descendant or ancestor | Nearest conflicted (`roots` for next, `heads` for prev) | Not-found refusal with its conflict text when there is none |
| ui.movement.edit = true | Config set | Edit form; `no_edit` restores the non-edit form | Non-bool value → `jj.config_error` |
| `@` has children, non-edit | `@` not a visible head | Refused, no op | `jj.invalid_input` + hint |
| nothing there | No descendant or ancestor at offset | Refused, no op | `jj.invalid_input`, one hint per start commit |
| edit target immutable | `prev --edit` onto root / immutable | Refused, no op | `jj.immutable` |
| ambiguous, no target | Two children | Refused, no op; the targets call lists both | `jj.invalid_input` |
| ambiguous, chosen | `target` = one candidate | Moves there | — |
| stale choice | `target` not a candidate | Refused, no op | `jj.stale_selection` |
| clap refusals | `edit && no_edit`; `Some(offset)` + `conflict` | Refused BEFORE the snapshot (a dirty wc stays unsnapshotted) | `jj.invalid_input` |
| no `@` | Workspace without a working-copy commit | Refused | `jj.no_working_copy` |

</intent-contract>

## Code Map

CLI anchors at `v0.46.0` (`git -C ../jj show v0.46.0:cli/src/…`). jj-lib is at `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.46.0/src`. Zanshin baseline is `1a649a6`.

**Prior art (read-only)**
- `cli/src/movement_util.rs` — the whole port: `MovementArgsInternal`, `Direction::{cmd, target_not_found_error, build_target_revset}`, `get_target_commit`, `choose_commit` (replaced), `move_to_commit`.
- `cli/src/commands/{next,prev}.rs` — the clap args: `offset` default 1; `-e/--edit`; `-n/--no-edit` `conflicts_with = "edit"`; `--conflict` `conflicts_with = "offset"`.
- `cli/src/config/misc.toml:51-52` — `[ui.movement] edit = false`.
- `cli/tests/test_next_prev_commands.rs` — the CLI's own cases to mirror (ambiguous, conflict, offsets, config).
- jj-lib `revset.rs:508` `ancestors_at`, `:553` `descendants_at`, `children`, `minus`, `filtered(RevsetFilterPredicate::HasConflict)`, `roots`/`heads`. `repo.rs:1709` `MutableRepo::check_out`, `MutableRepo::edit`.

**Reuse — `crates/zanshin-jj`**
- `src/mutate.rs` — `edit` `:1353` (the reload → `start_repo_transaction` → `edit` → `rebase_descendants` → `finish_verb` template), `guard_rewritable` `:681`, `finish_verb` `:924`, `mutation_result` `:968`, `MutateError::{invalid, invalid_hinted}` `:528-543`, `InvalidInput { reason, hints }` `:142`, `NoWorkingCopy` `:368`, `StaleSelection` `:437`, `be`/`cfg`.
- `src/template.rs:406` `Templates::commit_summary`. `src/op_support.rs:111-152` is a hint-rendering example with `commit_summary`.
- `src/config.rs` — add `ui_movement_edit(&StackedConfig) -> Result<bool, ConfigError>` next to `templates_commit_summary` `:1795` and `split_legacy_bookmark_behavior` `:1961`, in the same style.
- `src/snapshot.rs:413` `VerbContext` (`config`, `templates`).
- `src/metaedit.rs:127` `check_metaedit_args` (the clap-check template). `src/repo.rs` `with_checked_verb` `:504`, `squash`/`squash_plan` `:2926-2951` (verb + plan facade doc-block template), `metaedit` `:3244`.
- `src/change.rs` `CommitId`, `src/status.rs` `ChangeId`. Re-exports in `src/lib.rs`.

**Extend — wire + FFI**
- `schemas/envelope.fbs` — append `RequestKind.Movement`, `enum MovementDirection { Next, Prev }`, and `table MovementRequest { kind, direction, offset: ulong = null, edit, no_edit, conflict, target: string }`. An absent `target` means `None`. Add `table MovementTargets { edit: bool, targets: [MovementTarget] }` and `table MovementTarget { commit_id, change_id }`, and append `MovementTargets` to `Payload`.
- New `crates/zanshin-ffi/src/movement.rs`, on the template `metaedit_duplicate_fix.rs`: the reader plus `zanshin_move_working_copy` (an `ok_mutation_result` envelope) and `zanshin_movement_targets`. Also touch `lib.rs`, `envelope.rs` (an `ok_movement_targets` helper) and `repo.rs::map_mutate_err` (the existing arms already cover every error).
- Generated only via `cargo make codegen`: `zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart`.
- `docs/ffi-abi.md` (symbols, request and result tables). `crates/zanshin-ffi/tests/it/ffi_abi_doc_sync.rs` `EXPECTED_EXPORTS` goes from 92 to 94.
- `docs/rust-error-codes.md` — "Also emitted — Story 9.10" clauses on `jj.invalid_input` (its hints list too), `jj.no_working_copy`, `jj.immutable`, `jj.config_error`. On `jj.stale_selection`, widen the meaning: a next/prev `target` that is no longer a candidate (remedy: re-read the targets and pick again).

**Extend — Dart (`packages/zanshin_core`)**
- New `lib/src/ffi/movement.dart`, on the template `metaedit_duplicate_fix.dart`: the request builder, the `MovementTargets`/`MovementTarget` models and the decoder.
- `lib/src/worker/{commands,isolate,handle}.dart` and `RepoHandle.moveWorkingCopy(direction:, offset:, edit:, noEdit:, conflict:, target:)` plus `RepoHandle.movementTargets(...)`, behind the close guard with NUL rejection. Export from the barrel `lib/zanshin_core.dart`.
- Test templates: `test/ffi/metaedit_duplicate_fix_test.dart` and `test/worker/metaedit_duplicate_fix_test.dart` (synthetic + real-cdylib, with the extern-fn-guard header paragraph).

**Tests / oracle**
- `crates/zanshin-jj/tests/it/main.rs` + new `movement.rs`; `api_stability.rs` (the surface pin); `arg_refusals.rs` (the clap-before-snapshot template).
- `crates/zanshin-ffi/tests/it/main.rs` + new `movement_ffi.rs`.
- `crates/zanshin-parity/tests/oracle/scenarios.rs` (the 9.9 block `:3811+` is the template: `simple`, `args`, `verb_argv`, `zanshin_outcome`; register the scenarios in the chain at `:2938`). `hints.rs` compares commit-summary hints against the pinned CLI and is the place for the not-found hint check. `ledger.rs` only gets an entry with a reason and a reference.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/config.rs` -- `ui_movement_edit` + inline test (default false, true, non-bool → error names the key) -- the CLI's `get_bool("ui.movement.edit")`.
- `crates/zanshin-jj/src/movement.rs` (new) -- the module:
  - `pub enum Direction { Next, Prev }`; `pub struct MovementOptions { direction, offset: Option<u64>, edit, no_edit, conflict, target: Option<CommitId> }` (Default = Next, None, false…); `pub struct MovementTargets { edit: bool, targets: Vec<MovementTarget> }`; `pub struct MovementTarget { commit_id: CommitId, change_id: ChangeId }`.
  - `check_movement_args` (the clap refusals).
  - A shared `plan_movement` (wc → config → no-children → revset → evaluate → not-found with hints), `choose_target`, and the `move_working_copy` verb.
  - Inline unit tests: tx descriptions, the eight not-found messages, clap refusals, `wrapping_sub`.
- `crates/zanshin-jj/src/{repo,lib}.rs` -- `#[must_use]` facades `Repo::move_working_copy(&MovementOptions) -> Result<MutationResult, MutateError>` and `Repo::movement_targets(&MovementOptions) -> Result<MovementTargets, MutateError>`, both via `with_checked_verb`, with house doc blocks (errors list). Add the module and the re-exports.
- `schemas/envelope.fbs` + `cargo make codegen` -- the tables above; commit the regenerated files.
- `crates/zanshin-ffi/src/movement.rs` (new) + `lib.rs`/`envelope.rs` -- the reader (absent offset/target → `None`, wrong kind → `ffi.invalid_argument`) and the two externs, with full rustdoc.
- `packages/zanshin_core/...` -- the builder, decoder, models, commands, worker methods, `RepoHandle` methods and barrel export.
- `crates/zanshin-jj/tests/it/movement.rs` (new) -- every matrix row against jj-lib state, plus:
  - each refusal leaves the op head unchanged and `new_op_id` equal to the pre-call head;
  - the targets call lists the ambiguous children in CLI order and writes no op on a clean wc;
  - a chosen candidate moves there; a non-candidate refuses `jj.stale_selection`;
  - a clap refusal on a dirty wc writes no snapshot op.
- `crates/zanshin-ffi/tests/it/movement_ffi.rs` (new) -- the reader (absent vs present, malformed, wrong kind), the zero handle for both externs, one refusal envelope with hints, one success envelope, one targets envelope.
- `packages/zanshin_core/test/{ffi,worker}/movement_test.dart` (new) -- synthetic + real-cdylib round trips for both externs; every request field is observed.
- `crates/zanshin-parity/tests/oracle/scenarios.rs` (+ `hints.rs`) -- these scenarios, each against `jj next|prev …`:
  - next: default, `--edit`, `2`, `--edit 2`, `--conflict`;
  - prev: default, `--edit`, `2`, `--conflict`, `0 --edit` (no op);
  - `ui.movement.edit = true` with `next` and with `next --no-edit`;
  - refusals: children non-edit, nothing found (next and prev), `prev --edit` onto root (immutable), ambiguous next (the CLI is non-TTY and refuses; Zanshin without a target refuses; both write no op beyond the snapshot), `--edit --no-edit`, `--conflict 1`;
  - plus one hints check (not-found `Working copy parent: …`).
  Next non-edit offset 0 gets no scenario: the debug-built oracle CLI panics on the u64 underflow there (the release CLI wraps). Note that in the scenario doc.
- `crates/zanshin-jj/tests/it/api_stability.rs` -- the new types field by field, the two `Repo` methods as `fn` pointers.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- symbols, tables, code clauses.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- 9-10 → `done` with a sibling-style summary; bump `last_updated`.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- mirror any `deferred:` entry under `## Surfaced in Story 9.10 (bmad-build-auto, 2026-10-24)`.

**Acceptance Criteria:**
- Given a Dart caller, when it calls `RepoHandle.moveWorkingCopy` / `movementTargets`, then the whole chain is present (`.fbs`, zanshin-jj verb, `extern "C"`, committed codegen, adapter, `WorkerCommand`, worker method, `RepoHandle` method) and `ffi_abi_doc_sync` passes with 94 exports.
- Given every parity scenario above, when the oracle runs, then each matches the pinned CLI on every compared aspect, or diverges only through a ledgered entry with a reason and a reference.
- Given an ambiguous target, when the GUI calls `movement_targets` and then `move_working_copy` with one returned `commit_id`, then the working copy ends where the CLI ends after choosing that index at its prompt.
- Given any refusal or no-op, when the op head is compared before and after, then it is unchanged and `new_op_id` equals the pre-call head (zanshin-jj and FFI layers).
- Given the targeted checks of this run's gate rule, then each passes (see Verification), and `git status --porcelain` is clean at the end with every commit carrying the required co-author trailer.

## Spec Change Log

## Review Triage Log

## Design Notes

**Ambiguity → GUI choice.** The CLI prompts only when the target revset yields more than one commit. The epic rule is "where the CLI prompts, return candidates": `movement_targets` returns them and `move_working_copy` takes the choice. The choice is checked against the candidates computed in the same call, so a stale pick never moves the working copy somewhere the CLI could not.
- No new code: a missing choice is the CLI's refusal family (`jj.invalid_input`, with its prompt header as the reason), and a non-candidate pick is the selection-no-longer-fits remedy (`jj.stale_selection`, widened).
- Commit ids, not change ids, identify a candidate, because divergent commits can share a change id.

**Shape:**
```rust
let opts = MovementOptions { direction: Direction::Next, ..Default::default() };
let plan = repo.movement_targets(&opts)?;            // MovementTargets { edit: false, targets: [C1, C2] }
let res = repo.move_working_copy(&MovementOptions { target: Some(plan.targets[1].commit_id.clone()), ..opts })?;
```

## Verification

Gate rule for this run (Ralph, 2026-10-20): no `cargo make test` / `test-full` / `coverage`.

**Commands:**
- `cargo test -p zanshin-jj --lib movement` and `cargo test -p zanshin-jj --lib config` -- expected: pass
- `cargo test -p zanshin-jj --test it movement::` and `--test it api_stability::` and `--test it arg_refusals::` -- expected: pass
- `cargo test -p zanshin-ffi --test it movement_ffi::` and `--test it ffi_abi_doc_sync::` -- expected: pass
- `cargo test -p zanshin-parity --test oracle` -- expected: pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean
- `cargo make codegen` -- expected: committed output unchanged after a second run
- In `packages/zanshin_core`: `dart test test/ffi/movement_test.dart test/worker/movement_test.dart` (the package runs under `dart test`, see `Makefile.toml:174-195`), `dart analyze`, `dart format --set-exit-if-changed .` -- expected: pass/clean

**Verification notes:** (filled by the implementation run)
