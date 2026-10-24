---
title: 'Story 9.10 — Working-copy movement: next, prev'
type: 'feature'
created: '2026-10-24'
status: 'done'
baseline_revision: '9eb3bfb1ee72f0a0f9741e121e34fead3b986ba8'
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

### 2026-10-24 — Review pass
- verdicts: 23 findings — high 0, medium 0, low 15, false 8, maybe-false 0
- findings:
  - `[false]` `[reject]` (intent-alignment) "GUI picks" read at the user surface: no app/ picker — CLAUDE.md: UI code only inside a story that asks for it; Epic 9 is the operation API, the backend exposes candidates + choice (ADR-0003).
  - `[false]` `[reject]` (intent-alignment) orchestration shared only between next/prev, not a general helper — the intent's "shared movement_util" is the CLI's module shared by both verbs, which `plan_movement` is.
  - `[false]` `[reject]` (intent-alignment) next offset 0 non-edit refuses with jj-lib's generation text instead of not-found — matches the release CLI (checked on the pinned CLI with `jj prev 5000000000`), documented in the verification notes; oracle `prev_offset_too_large_refused` witnesses the path.
  - `[false]` `[reject]` (intent-alignment) sprint-status says done while the spec is in-review; no deferred-work section — finalize sets the spec done in the same commit; nothing was deferred, so the mirror rule adds nothing.
  - `[low]` `[patch]` (verification-gap) the Dart move path's `offset`/`noEdit` could be dropped undetected (offset 1 = default; edit+noEdit refusal asserted by code only) — patched: `test/worker/movement_test.dart` moves `prev --edit 2` then `next --edit 2`, and asserts the clap context.
  - `[low]` `[reject]` (edge-case) a malformed/short/uppercase `target` refuses `jj.stale_selection`, not `jj.invalid_input` — still a refusal with no write; the GUI only passes ids from `movement_targets`; fix adds a parse guard.
  - `[low]` `[reject]` (edge-case) files edited between `movement_targets` and an ambiguous `next --edit` rewrite `@` and rebase its children, so the chosen id refuses stale — safe outcome (refusal, re-pick), needs ambiguous next --edit plus a dirty wc in between; a mapping through the snapshot's rewrites is new design.
  - `[false]` `[reject]` (edge-case) "prev 0 --edit writes no operation" claim — the docs say "a move that changes nothing"; with a discardable `@` the move does change `@` (abandon + new `@`), as the stock CLI does; the oracle scenario matches the CLI either way.
  - `[false]` `[reject]` (edge-case) AC "any refusal leaves the op head unchanged" vs a dirty wc — the op is the pre-verb snapshot's, which the CLI writes too and the test asserts; the fix would edit the spec.
  - `[false]` `[reject]` (blind) ambiguous refusal shares `jj.invalid_input`, GUI would string-match — the GUI learns ambiguity from `movement_targets`' typed list (len > 1) before moving; the refusal is only the guard.
  - `[low]` `[reject]` (blind) malformed `target` reported as stale — same as the edge-case row: harmless refusal, ids come from the targets call, fix adds a guard.
  - `[low]` `[reject]` (blind) `MovementTargets` carries no `@` it was computed from — a pick that is still a candidate from the new `@` is a legitimate CLI move; needs an external writer between two calls; fix adds public surface.
  - `[low]` `[patch]` (blind) docs claim every candidate is a valid target although an immutable one refuses when editing — patched: `crates/zanshin-jj/src/repo.rs` and `crates/zanshin-ffi/src/movement.rs` now say the targets call runs no rewritability guard (header regenerated).
  - `[false]` `[reject]` (blind) bookkeeping: sprint-status done vs spec in-review, no deferred-work mirror — finalize sets done; nothing deferred.
  - `[low]` `[reject]` (blind) prompt-parity test covers only ambiguous non-edit next — both sides evaluate the same revset expression through the same jj-lib stream, so the order cannot differ by direction; more scenarios add no signal.
  - `[low]` `[reject]` (blind) refusal reasons not compared with the CLI's `Error:` line — texts copied verbatim from the v0.46.0 source and pinned by unit tests; the oracle compares outcome + warnings by design.
  - `[low]` `[reject]` (blind) non-bool `ui.movement.edit` has no oracle scenario — the CLI source reads `get_bool(..)?` unconditionally before the flags (`movement_util.rs` `move_to_commit`); zanshin-jj tests witness it.
  - `[low]` `[reject]` (blind) "targets refuses exactly like the move" mostly untested — both run the one `plan_movement`, so the refusal paths are shared code.
  - `[low]` `[reject]` (blind) Dart decoder maps an empty targets vector to an empty list — Rust never sends an empty list; fix adds a guard for an impossible case.
  - `[low]` `[patch]` (blind) the caller-side negative-offset guard (`isolate.dart` `_rejectNegativeOffset`) is untested — patched: worker test asserts `ArgumentError` for `moveWorkingCopy(offset: -1)` and `movementTargets(offset: -1)`.
  - `[low]` `[reject]` (blind) out-of-range direction builds `FfiErrorObj` inline instead of a shared helper — cosmetic; the existing helper is module-private in `op_log.rs`.
  - `[low]` `[reject]` (blind) oracle `state.rs` 12-hex normalisation renames any 12-hex token and `HashMap::find` is unordered on prefix collisions — op ids never match the commit map; a 12-hex collision among a scenario's few commits is negligible.
  - `[low]` `[patch]` (blind) a `hints.rs` module-doc line exceeds the 120 width — patched: reflowed.

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

**Verification notes:** (filled by the implementation run, 2026-10-24)

- `cargo test -p zanshin-jj --lib movement` — 5 passed (clap refusals, the eight not-found texts, tx descriptions, the `wrapping_sub` generation; plus the config test the filter also matches). `--lib config` — 121 passed (incl. `ui_movement_edit_defaults_false_and_reads_the_user_layer`).
- `cargo test -p zanshin-jj --test it movement::` — 19 passed; `api_stability::` — 30 passed; `arg_refusals::` — 4 passed.
- `cargo test -p zanshin-ffi --test it movement_ffi::` — 7 passed; `ffi_abi_doc_sync::` — 17 passed (94 exports).
- `cargo test -p zanshin-parity --test oracle` — 356 passed (20 new scenarios, no ledger entries; `hints::next_not_found_hint_renders_the_working_copy_parent_summary`; `prompt::a_chosen_candidate_moves_where_the_clis_prompt_answer_moves` — the CLI forced interactive with `JJ_INTERACTIVE=1`, the index on stdin, against `movement_targets` + `target`, both indices).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean.
- `cargo make codegen` — run, then run again: the four generated files' checksums unchanged.
- `packages/zanshin_core`: `dart test test/ffi/movement_test.dart test/worker/movement_test.dart` (with `[tasks.test-core]`'s env) — 8 passed; `dart analyze --fatal-infos --fatal-warnings` — no issues; `dart format --set-exit-if-changed .` — 0 changed.
- Not run (gate rule): `cargo make test` / `test-full` / `coverage`.

Deviations from the spec text, each to match the CLI or the toolchain:
- Next non-edit offset 0 is NOT a not-found refusal: `descendants_at(u64::MAX)` makes jj-lib's evaluation refuse ("Lower bound of generation (18446744073709551615) is too large", `default_index/revset_engine.rs`), which the release CLI reports as a user error (`From<RevsetEvaluationError> for CommandError` = `user_error`). Zanshin maps `RevsetEvaluationError::Other` to `jj.invalid_input` with jj-lib's text; any offset beyond `u32::MAX` refuses alike (checked against the pinned CLI: `jj prev 5000000000` → the same text, exit 1; oracle scenario `prev_offset_too_large_refused`).
- `ui.movement.edit` is read before the flags (the CLI's `get_bool(..)?` runs unconditionally), so a non-bool value refuses `--edit` too.
- `MovementRequest.offset` is a struct `MovementOffset { value: ulong }`, not `ulong = null`: `flatc --dart` refuses optional scalars ("Optional scalars are not yet supported in at least one of the specified programming languages"); an absent struct field is the same null-for-absence.
- clap's conflict texts depend on the argv order; the field order is used: `the argument '--edit' cannot be used with '--no-edit'`, `the argument '--conflict' cannot be used with '[OFFSET]'` (checked against the pinned CLI).
- The oracle's op-text normalisation (`state.rs` `normalize`) now names a 12-hex commit prefix like its full id, so the `@` a non-edit move abandons keeps its before-name in `next: <@> -> <target>` (it is in neither repo's after-state, and its id differs between the repos).

- Review patches re-verified (2026-10-24): `--test it movement::` 19, `--lib movement` 5, `movement_ffi::` 7, `ffi_abi_doc_sync::` 17, oracle 356 passed; clippy (3 crates, `-D warnings`) and `cargo fmt --all --check` clean; `dart test` movement ffi+worker 8 passed, `dart analyze --fatal-infos --fatal-warnings` and `dart format` clean; `cargo make codegen` stable on a second run.

## Auto Run Result

Status: done

**Summary.** `jj next` / `jj prev` ported from `cli/src/movement_util.rs` @ v0.46.0 through the whole chain. `Repo::move_working_copy(&MovementOptions)` and `Repo::movement_targets(&MovementOptions)` share one `plan_movement`. The CLI's prompt for several targets becomes typed candidates plus an optional `target` commit id. Without a choice the move refuses with the prompt header (`jj.invalid_input`); a non-candidate choice refuses `jj.stale_selection` (widened). FFI exports `zanshin_move_working_copy` / `zanshin_movement_targets` (94 exports). Dart adds `RepoHandle.moveWorkingCopy` / `movementTargets`. The oracle gains 20 scenarios, a not-found hint check and an interactive-prompt parity test.

**Files changed**
- `crates/zanshin-jj/src/movement.rs` (new) — the port: types, clap checks, target revset, not-found refusal with hints, choice, edit/check_out + finish.
- `crates/zanshin-jj/src/{repo,lib,config}.rs` — facades, re-exports, `ui_movement_edit`.
- `crates/zanshin-jj/tests/it/{movement,api_stability,main}.rs` — 19 integration tests, surface pin.
- `schemas/envelope.fbs` + regenerated `zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart` — `MovementRequest` / `MovementTargets` / `MovementOffset`.
- `crates/zanshin-ffi/src/{movement,envelope,lib}.rs`, `tests/it/{movement_ffi,ffi_abi_doc_sync,main}.rs` — reader, two externs, `ok_movement_targets`, tests.
- `packages/zanshin_core/lib/src/ffi/movement.dart`, `lib/src/worker/{commands,isolate,handle}.dart`, `lib/zanshin_core.dart`, `test/{ffi,worker}/movement_test.dart` — the Dart chain and its tests.
- `crates/zanshin-parity/tests/oracle/{scenarios,hints,main,prompt,state}.rs` — scenarios, hint check, prompt parity, short-id op-text naming.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` — symbols, tables, 9.10 clauses, `jj.stale_selection` widened.
- `_bmad-output/implementation-artifacts/{sprint-status.yaml,epic-9-context.md}` — 9-10 done; Epic 9 context refreshed (epics.md was newer).

**Review.** 23 findings: 4 low patched (Dart worker seam test, candidate-validity docs, negative-offset guard test, doc line width), 0 deferred, 11 low rejected and 8 false, each with its reason in the Review Triage Log. Follow-up review: not recommended (no high or medium patched).

**Verification.** Targeted checks only, per the run's gate rule — see Verification notes. `cargo make test` / `test-full` / `coverage` were not run; the loop runs the gate at its end.

**Residual risks.**
- Coverage was not measured. The `RevsetEvaluationError::Backend` arm in `movement.rs` is untested.
- An ambiguous `next --edit` with files edited between the targets call and the move refuses stale (safe; the GUI re-reads).
- Next non-edit offset 0 has no CLI witness, because the debug oracle CLI panics on the u64 underflow there.
- The oracle's `state.rs` normalisation change touches every scenario's op-text naming. All 356 stay green.
