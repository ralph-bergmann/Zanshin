---
title: 'Story 9.58 — Follow-ups of 9.57: `init` reports what it left, `convert_import` creates one level, the CLI''s `immutable_heads()` error text'
type: 'feature'
created: '2026-10-22'
status: 'done'
baseline_revision: '60088c515c34bd1f074917221198a770be1f8f53'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized', 'multiple-goals']
deferred:
  - summary: >-
      A failed NEW colocated `Repo::init` (no `.git` before the call) also leaves the `.git/` jj-lib's
      `init_colocated_git` created; `left_behind` lists only the destination and `.jj`, as Story 9.58 scopes it.
    evidence: |-
      `crates/zanshin-jj/src/creation.rs` `init_steps` colocated arm: `init_colocated_git` (jj-lib 0.46.0
      `GitBackend::init_colocated` creates `<root>/.git`; its `init_with_factories` cleanup removes only `.jj`),
      then `workable_env` / `add_gitignore` / `Repo::open` can fail (e.g. a bad `immutable_heads()` alias).
    location: >-
      crates/zanshin-jj/src/creation.rs init_steps
    severity: low
  - summary: >-
      An `immutable_heads()` alias that does not PARSE still refuses with jj-lib's bare parse error, while the CLI
      prefixes that case with "Invalid `revset-aliases.immutable_heads()`" too; Story 9.58 prefixed only the
      resolve failure.
    evidence: |-
      CLI v0.46.0 `cli/src/cli_util.rs:1115` (`load_immutable_heads_expression`: `config_error_with_message(
      "Invalid `revset-aliases.immutable_heads()`", e)` on the parse); Zanshin `crates/zanshin-jj/src/revset.rs`
      `immutable_heads_expression` returns `RevsetError::ParseError` unprefixed and its callers map it with `cfg`.
      Pre-existing; found in this story's review.
    location: >-
      crates/zanshin-jj/src/revset.rs immutable_heads_expression
    severity: low
---

<intent-contract>

## Intent

**Problem:** After Story 9.57 only the two convert verbs report what a failed creation left on disk (`CreationOutcome.left_behind`); a failed `Repo::init` reports nothing. `convert_import` creates every missing level of its destination where `jj git init --git-repo` creates one, and decides "did we create it" by a check BEFORE the creation (`topmost_missing_ancestor`), which misnames the directory under a concurrent create or a `..` path. An unresolvable `immutable_heads()` refuses with jj-lib's bare error where the CLI says "Invalid `revset-aliases.immutable_heads()`". Nothing says a `watcher.io_error` after a successful creation leaves a complete repo.

**Approach:** One helper with jj-lib's `create_or_reuse_dir` semantics that returns whether THIS call created the directory; `init` and `convert_import` use it (one level, CLI refusal text), and both list in `left_behind` the destination they created (canonical, read from that result) plus the `.jj` only when this call's jj-lib creation returned `Ok`. `resolve_immutable` prefixes the CLI's message. Docs (Rust, FFI, `.fbs` + codegen, Dart, `ffi-abi.md`, `rust-error-codes.md`) state the new facts.

## Boundaries & Constraints

**Always:**
- CLI v0.46.0 is the spec: `cli/src/commands/git/init.rs:161-163` (`create_or_reuse_dir` + canonicalize → `user_error_with_message("Failed to create workspace", e)`), jj-lib 0.46.0 `file_util::create_or_reuse_dir` (`create_dir`; `Err(_) if is_dir()` → reused), `cli_util.rs:1146-1167` (`config_error_with_message("Invalid `revset-aliases.immutable_heads()`", e)`).
- "Created" = `std::fs::create_dir` returned `Ok` in this call; never a `symlink_metadata`/`exists` check before it. A reused (existing) destination is never listed.
- `left_behind` for `init` and `convert_import`: outermost first — the destination this call created, then `<canonical root>/.jj` when this call's jj-lib creation (`init_external_git` / `init_colocated_git` / `init_internal_git` / `init_simple`) returned `Ok` — each only when it still exists after the failure; empty on success and on every refusal that wrote nothing. Paths are the canonical root's (the caller's spelling only if canonicalizing the just-created destination itself fails). `convert_colocated` keeps its 9.57 behavior; `clone` keeps its own clean-up and reports nothing.
- `convert_import`'s create failure keeps `RepoError::ConvertFailed` (its documented error for an uncreatable destination; no FFI symbol) with the CLI's text "Failed to create workspace: <io error>"; `init`'s stays `RepoError::InitFailed` (`init_failed`).
- `resolve_immutable`'s `MutateError::Config.reason` = "Invalid `revset-aliases.immutable_heads()`: <jj-lib error>" — the `init_failed` style; every caller inherits it (verbs, clone, `convert_import`'s head finish).
- FFI: `creation_envelope_for` already copies `outcome.left_behind` for every creation — no wire change; only the `.fbs` doc of `FfiError.left_behind` widens to `zanshin_repo_init` (then `cargo make codegen`, commit its output).
- Tests per project-context.md (`tests/it/<module>.rs`, `pin_test_env()` first, env-changing rows inside the existing own-process tests).

**Never:**
- No UI, no MCP change, no new error or warning code, no deletion by the backend on an `init` / `convert_import` failure.
- No `left_behind` on a `watcher.io_error` (Ralph 2026-10-22: docs only).
- No tests for `import_head_into_destination`'s rebase / lock arms (Ralph: leave them).
- Never regenerate fixtures; never lower the coverage baseline; no full gate in this run (loop gate rule).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| init, new dest, late fault | `Repo::init` Git, `path` missing (parent exists), a wrong-typed `git.*` key | refuses `Config`; jj-lib removed its `.jj`; `left_behind == [<canonical path>]` | as the CLI |
| init over `.git`, late fault | Git repo with a mode-`0o000` new file, colocated init | `ConvertFailed`; `.jj` stays; `left_behind == [<canonical root>/.jj]` | as the CLI |
| init, refusal before writing | existing `.jj` / `--no-colocate` over `.git` / missing parent | today's error; `left_behind` empty; nothing created | — |
| init, missing parent | `path = <tmp>/missing/dest` | `InitFailed` "Failed to create workspace: …"; nothing created | unchanged |
| import, missing parent | `convert_import(src, <tmp>/missing/dest)` | `ConvertFailed` "Failed to create workspace: …"; `<tmp>/missing` NOT created; `left_behind` empty | CLI parity (oracle) |
| import, missing dest, parent exists | `convert_import(src, <tmp>/dest)` | as today (success) | — |
| existing dest | dest already a directory, conversion fails | dest never listed (only `.jj` if created) | — |
| `..` destination | `convert_import(src, <tmp>/x/../y)`, `x` exists, failing | `left_behind[0] == <canonical tmp>/y` (the directory created) | — |
| unresolvable alias | `immutable_heads() = 'nonexistent_symbol_xyz'`; a verb, `clone`, `convert_import` | `Config`, reason starts "Invalid `revset-aliases.immutable_heads()`: " and still names the symbol | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/creation.rs:147-157` `init` (`left_behind: Vec::new()` → fill on `Err`), `:159-165` `init_failed` (the CLI text; reuse its format for import), `:175-224` `init_steps` (`file_util::create_or_reuse_dir` + canonicalize at :187-189 → own created-reporting helper; External arm :200-210 via `convert::init_over_git_dir`; colocated `init_colocated_git` :212-215 then `workable_env` + `add_gitignore` can fail with `.jj` (and jj-lib's `.git`) left; internal `init_internal_git` :217-218; `Repo::open` :220), `:224-236` `init_native` (dest must exist; `init_simple` → `.jj`). Clone's `finish` :482-504 calls `resolve_immutable` (text inherits).
- `crates/zanshin-jj/src/convert.rs` -- `ConversionReport` :130-155 (`jj_created`), `convert_import` doc :240-307 ("spelled as `workspace_path` was passed", "`create_dir_all` is the bridge's documented liberalization"), `convert_import_steps` :316-362 (`topmost_missing_ancestor` :355 → delete; `left_behind` :356-360), `topmost_missing_ancestor` :364-372 + its unit test :818-843 (delete), `still_present` :375-380 (make `pub(crate)` for init), `init_over_git_dir` :571-580 (return `jj_created` too — e.g. a small `pub(crate)` struct instead of the 3-tuple), `import_into` :601-626 (`create_dir_all` :602 → one level; canonicalize :607; doc comment :613), module doc :76-85.
- `crates/zanshin-jj/src/op_support.rs:68-91` `resolve_immutable` -- add the CLI prefix (doc already quotes the CLI message). `mutate.rs:514 cfg` is the plain mapper (keep).
- `crates/zanshin-jj/src/repo.rs:139-165` `CreationOutcome.left_behind` doc ("What a FAILED conversion … created", "spelled as the caller passed", "Empty … for every other creation path") -- widen to `init`, canonical spelling; `Repo::init` rustdoc (find via `pub fn init`) -- add the failure contract.
- Tests: `crates/zanshin-jj/tests/it/convert.rs:654-700` (import dest / nested `a/b` row at :692 → now refuses one level, nothing created), `:741-822`; `tests/it/creation_warnings.rs:640-660`, `:780-795` (`[dst, dst/.jj]` → canonical), `:652`, `:727` (reason `contains` still holds; add a `starts_with` prefix assert on one verb, clone and import row); `tests/it/config_identity.rs:715-770` (own-process env test: add a new-destination init row with the wrong-typed git key → `left_behind == [canonical]`; `import_dest` assertion :769 → canonical); `tests/it/op_support.rs:275-290` (assert the reason prefix for a verb); init rows (refusal → empty; over `.git` snapshot fault → `[<root>/.jj]`) in `tests/it/creation_warnings.rs` or `tests/it/convert.rs` next to the 9.57 rows; `tests/it/api_stability.rs:1676` unchanged.
- FFI `crates/zanshin-ffi/src/repo.rs:681-704` `creation_envelope_for` (no code change), `zanshin_repo_init` doc :752-788 (add the `left_behind` failure contract; `watcher.io_error` row → "the repository is complete; no `left_behind`; the UI can open it again"), `zanshin_repo_clone` doc :~830-880 (`watcher.io_error` row), `zanshin_repo_convert` doc :1037-1040; `crates/zanshin-ffi/tests/it/repo_ffi.rs:915-933` `repo_init` helper (no-colocate only — add a colocated variant) and a new test next to `convert_whose_snapshot_fails_reports_on_the_error_envelope` :865-910: `zanshin_repo_init` over a Git repo with a `0o000` file → `jj.convert_failed` + `left_behind == [<canonical>/.jj]`; a missing-parent init → no `left_behind`.
- `schemas/envelope.fbs:31-44` `FfiError.left_behind` doc (names `zanshin_repo_convert` only) → widen to `zanshin_repo_init`; `cargo make codegen` regenerates `crates/zanshin-ffi/src/envelope_generated.rs`, `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`.
- Dart: `packages/zanshin_core/lib/src/worker/isolate.dart:452-490` `initRepo` doc, `:492-525` `cloneRepo` doc, `:1018-1033` `convert` doc (failure contract + `watcher.io_error` = repo complete); `lib/src/ffi/repo.dart:171-178` (+ the init wrapper's doc there), `lib/src/worker/responses.dart:113-120` (`leftBehind` doc: "failed conversion" → creation); test `packages/zanshin_core/test/worker/error_reports_test.dart:136-176` (add an init-over-`.git` snapshot-fault row asserting `leftBehind == ['$root/.jj']`; reword the `an_error_without_a_report_carries_none` reason).
- Docs: `docs/ffi-abi.md:69-95` (`FfiError.left_behind` section: init, canonical import spelling, one level), `:131-160`, `:675-750` (convert contract + `watcher.io_error` row :748), `:797-805` (async-events `watcher.io_error`), symbol table :529-531 unchanged codes; `docs/rust-error-codes.md:52` (`jj.convert_failed`: "init carries none" → init carries it), `:58` (`jj.config_error`: the CLI prefix).
- Oracle `crates/zanshin-parity/tests/oracle/git_scenarios.rs:205-275` (`convert_import_*` scenarios: add `convert_import_missing_parent` — `prep: SOURCE`, `target: "missing"`, `cli: ["git","init","--git-repo","src","missing/dest"]`, zanshin `convert_import(dir/src, dir/missing/dest)`; target `missing` so an extra created parent diverges), `main.rs:235-275` (`parity!` list + `every_scenario_has_a_test` count). The oracle compares refused/warnings counts and disk only, so the immutable text change does not touch it (`compare.rs:13-19`).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/creation.rs` -- add `pub(crate) fn create_or_reuse_dir(path) -> io::Result<bool>` (jj-lib's semantics, `true` iff `create_dir` returned `Ok`), use it in `init_steps`; track the created destination (canonical root, caller spelling only if canonicalize fails) and the `.jj` per jj-lib creation `Ok`; `init` fills `left_behind` with `still_present([...])` on `Err` -- items 1, 3.
- `crates/zanshin-jj/src/convert.rs` -- `init_over_git_dir` also returns `jj_created`; `import_into` creates one level through the helper (error "Failed to create workspace: <e>" as `ConvertFailed`), records the created canonical destination in `ConversionReport`; drop `topmost_missing_ancestor` (+ its unit test) and the liberalization wording; `still_present` `pub(crate)`; docs (module "What a failure leaves", `convert_import` "What a failure leaves"/errors, `CreationOutcome` cross-refs) -- items 2, 3; unit test for the helper (new → `true`, existing → `false`, missing parent → `Err`, existing file → `Err`).
- `crates/zanshin-jj/src/op_support.rs` -- `resolve_immutable` maps to `MutateError::Config { reason: format!("Invalid `revset-aliases.immutable_heads()`: {e}") }` -- item 4.
- `crates/zanshin-jj/src/repo.rs` -- `CreationOutcome.left_behind` + `Repo::init` docs -- item 1.
- `crates/zanshin-jj/tests/it/{convert,creation_warnings,config_identity,op_support}.rs` -- the matrix rows above (init new dest / over `.git` / refusal; import missing parent nothing created, existing dest never listed, `..` dest canonical; prefix asserts for a verb, clone, import); adjust 9.57 rows to canonical paths and to one-level creation -- witnesses.
- `crates/zanshin-ffi/src/repo.rs`, `crates/zanshin-ffi/tests/it/repo_ffi.rs` -- docs (init contract, `watcher.io_error` = repo complete for init/clone/convert); init `left_behind` + refusal witnesses -- items 1, 5.
- `schemas/envelope.fbs` then `cargo make codegen` -- doc only -- item 1.
- `packages/zanshin_core/lib/src/{worker/isolate.dart,ffi/repo.dart,worker/responses.dart}` + `test/worker/error_reports_test.dart` -- docs and the init witness -- items 1, 5.
- `crates/zanshin-parity/tests/oracle/{git_scenarios,main}.rs` -- `convert_import_missing_parent` -- item 2.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- items 1, 2, 4, 5.

**Acceptance Criteria:**
- Given a failing `Repo::init` / `zanshin_repo_init` / `initRepo`, when the outcome / error envelope / exception is read, then `left_behind` / `FfiError.left_behind` / `leftBehind` names exactly what that call created and left (destination, then `.jj`), and is empty for a refusal that wrote nothing.
- Given `convert_import` into `<missing>/<dest>`, when run through Rust and through the pinned CLI (oracle), then both refuse and neither creates `<missing>`; the ledger shows no UNEXPECTED / CHANGED / STALE.
- Given an unresolvable `immutable_heads()`, when a verb, `clone` or `convert_import` refuses, then the `jj.config_error` reason starts with "Invalid `revset-aliases.immutable_heads()`: ".
- Given the docs, when read, then `Repo::init`, `zanshin_repo_init`, `initRepo`, the `.fbs` + generated bindings and `ffi-abi.md` state init's `left_behind`; no doc still describes `convert_import`'s `create_dir_all` or caller-spelled paths; init/clone/convert docs say a `watcher.io_error` comes after a successful creation, the repo is complete, carries no `left_behind`, and can be opened again.

## Spec Change Log

## Review Triage Log

### 2026-10-22 — Review pass
- verdicts: 28 findings — high 0, medium 0, low 18, false 10, maybe-false 0
- findings:
  - `[low]` `[patch]` (verification-gap) no witness that a failed NEW colocated/internal/native init lists its `.jj` (the two-entry `[dest, dest/.jj]` init shape is asserted nowhere) — added an own-process row in `creation_warnings.rs`: colocated init into a missing destination under a `bogus_function()` `immutable_heads()` alias → `Config`, `.jj` stays, `left_behind == [canonical, canonical/.jj]`.
  - `[low]` `[defer]` (verification-gap, other) a failed new colocated init leaves jj-lib's `.git/` unlisted — Story 9.58's list is destination + `.jj`; already in `deferred:` (planning) for Ralph, mirrored in deferred-work.md "Surfaced in Story 9.58".
  - `[low]` `[reject]` (edge) `convert_import` into `<file>/dest` refuses through `detect_repo`'s ENOTDIR with bare io text, not "Failed to create workspace: …" — pre-existing precondition order (Story 2.13), same `ConvertFailed` code, no FFI symbol; a destination under a regular file is not an everyday input and the fix adds a branch.
  - `[low]` `[patch]` (edge) `zanshin_repo_init`'s `jj.convert_failed` bullet promised the `.jj` in `left_behind` unconditionally (absent when `init_external_git` itself failed) — bullet reworded (only when the creation succeeded); codegen re-run.
  - `[low]` `[reject]` (edge) a non-UTF-8 canonical path is sent lossily — as rejected in 9.57: FFI paths enter as UTF-8; only a non-UTF-8 symlink target could produce one; skipping/flagging adds a branch for a case not met in practice.
  - `[low]` `[patch]` (edge) `git push`'s commit check inherited the new prefix, but the CLI resolves `immutable_heads_expression()` there with a plain `.resolve()?` (`push.rs:803-805` @ v0.46.0) — `CommitsValidator::new` resolves with `resolve_expression(..).map_err(cfg)` again (CLI cited), a push test asserts no prefix, the `jj.config_error` row names the exception.
  - `[low]` `[patch]` (blind) same as the edge row above (push prefix) — fixed with it.
  - `[low]` `[defer]` (blind) an `immutable_heads()` alias that does not PARSE still refuses without the CLI's prefix (`cli_util.rs:1115`) — pre-existing, outside item 4 (the resolve failure); added to `deferred:` and deferred-work.md.
  - `[low]` `[patch]` (blind) init's `# Errors` bullets name `left_behind` only for `jj.convert_failed`, though a `jj.config_error` / `jj.jj_lib_error` after the destination step carries it too — bullets reworded to point at the failure paragraph; codegen re-run.
  - `[false]` `[reject]` (blind) "a refusal that wrote nothing" is misleading for init — the docs enumerate refusals that indeed write nothing (existing workspace, `no_colocate` over `.git/`, missing parent); a config fault after the destination step is not called such a refusal and lists the destination.
  - `[low]` `[patch]` (blind) no test shows the two-entry init case — same root cause as the first verification-gap row; fixed with it.
  - `[low]` `[reject]` (blind) the caller-spelling fallback when canonicalizing a just-created directory fails is untested and the `.fbs`-derived docs say "canonical" without the exception — not reachable without fault injection between `create_dir` and `canonicalize`; harmonising five doc layers for it is more than a direct correction.
  - `[false]` `[reject]` (blind) `creation.rs` and `convert.rs` now import each other (`still_present`, `Created`) — no named harm: both are private modules of one crate and nothing diverges.
  - `[false]` `[reject]` (blind) `ConversionReport.left_behind` duplicates `created.left_behind()` and `OverGitDir.jj_dir` duplicates `Created.jj_dir` — no named harm: each is written once from the one source and read once.
  - `[low]` `[reject]` (blind) no oracle scenario for init under a missing parent / a late init failure — init's one-level creation is unchanged by this story (it used `create_or_reuse_dir` since 9.20; `init_missing_destination` already runs); the new fact is the report, which the oracle does not compare.
  - `[low]` `[reject]` (blind) the native arm's `.jj` listing has no test and the docs' "missing parent" refusal reads as Git-only text — native `.jj` is listed only after a failed `Repo::open` following a successful `init_simple`, unreachable without fault injection; the native arm's own missing-path refusal also creates nothing, so "carries none" holds.
  - `[false]` `[reject]` (blind) "the UI can open it again" over-promises because open arms the same watcher — the sentence states what the disk allows (Ralph's wording, item 5), not a guarantee that arming succeeds.
  - `[low]` `[reject]` (blind) the prefix is asserted only at the Rust surface — the reason crosses unchanged as `context` through `map_repo_err` / `map_mutate_err`, whose pass-through is pinned by existing tests; no FFI/Dart code changed for it.
  - `[low]` `[reject]` (blind) `create_or_reuse_dir`'s unit test skips symlink cases — the body is jj-lib's verbatim (`file_util.rs:70-76`), so a symlink to a directory is reused and a dangling one refuses, exactly as the CLI; no new branch to pin.
  - `[low]` `[patch]` (blind) the `creation_envelope` doc broke into "onto / whichever / envelope answers" and edited `envelope.rs` doc lines were left unevenly wrapped — re-wrapped.
  - `[false]` `[reject]` (blind) the ledger is not mirrored and the spec has no result yet — done at finalize (this run's commit).
  - `[low]` `[patch]` (intent) FFI has no new-destination witness and Dart no refusal witness for init — added an own-process FFI test (`zanshin_repo_init` into a missing destination under a wrong-typed `git.*` key → `jj.config_error`, `left_behind == [<canonical dest>]`) and a Dart row (`initRepo` under a missing parent → `jj.jj_lib_error` "Failed to create workspace: …", `leftBehind` empty, nothing created). A Dart new-destination row would need a per-test user config in the worker's process; the FFI row pins the same copy.
  - `[low]` `[patch]` (intent) arms the code covers but no test exercises (new colocated, two entries) — same root cause as the first verification-gap row; fixed with it (native: see the native row above).
  - `[false]` `[reject]` (intent) `convert_import`'s missing-parent refusal keeps `ConvertFailed`, not the CLI's user-error class — the spec's chosen mapping (the verb's documented error for an uncreatable destination); no FFI symbol exposes a code, and the oracle compares refused/disk only.
  - `[false]` `[reject]` (intent) item 4 witnessed at Rust only, single-line text — the single-line "<message>: <cause>" form is the story's named style (`init_failed`); the pass-through is covered as in the Rust-only row above.
  - `[false]` `[reject]` (intent) `ffi/repo.dart`'s low-level clone wrapper doc was not touched for item 5 — item 5 names the worker docs `initRepo` / `cloneRepo` / `convert`, all updated; the low-level wrapper documents no error codes.
  - `[false]` `[reject]` (intent) `## Auto Run Result` missing — written at finalize.
  - `[false]` `[reject]` (intent) the unlisted `.git/` goes beyond the intent — it is the story's own scope boundary, made explicit and deferred to Ralph (see the defer row above), not added behaviour.

## Design Notes

**`.git` of a failed new colocated init is not listed.** `init_colocated_git` also creates `<root>/.git`; a later `workable_env` / `add_gitignore` / re-open failure leaves it. The story's list is the destination and `.jj` only; listing `.git` too is Ralph's call — recorded in `deferred:` (mirrored into deferred-work.md at finalize).

**Helper:**
```rust
pub(crate) fn create_or_reuse_dir(path: &Path) -> std::io::Result<bool> {
    match std::fs::create_dir(path) {
        Ok(()) => Ok(true),
        Err(_) if path.is_dir() => Ok(false), // jj-lib file_util.rs:70-76
        Err(e) => Err(e),
    }
}
```

## Verification

**Commands (targeted; the story loop runs the full gate):**
- `cargo test -p zanshin-jj` -- expected: green.
- `cargo test -p zanshin-ffi` -- expected: green.
- `cargo test -p zanshin-mcp` -- expected: green (consumer of verb error texts).
- `cargo test -p zanshin-parity --test oracle` -- expected: green, no UNEXPECTED / CHANGED / STALE.
- `cargo make codegen` -- expected: re-run leaves the tree clean; output committed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity -p zanshin-mcp --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed .`, `cargo make --allow-private test-core` (real cdylib) -- expected: green.

**Verification notes (run 2026-10-22, after the review patches; no `cargo make test` / `test-full` / `coverage` per the loop's gate rule):**
- `cargo fmt --all --check` — clean.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity -p zanshin-mcp --all-targets -- -D warnings` — clean.
- `cargo test -p zanshin-jj` — 308 lib + 1021 `it` passed (1 pre-existing ignored perf benchmark).
- `cargo test -p zanshin-ffi` — 196 lib + 310 `it` passed.
- `cargo test -p zanshin-mcp` — green (the crate has no tests; 0 run).
- `cargo test -p zanshin-parity --test oracle` — 210 passed (196 scenarios incl. the new `convert_import_missing_parent`), no UNEXPECTED / CHANGED / STALE.
- `cargo make codegen` — re-run leaves the tree unchanged; the regenerated header, `envelope_generated.rs`, `bindings.dart` and `envelope_zanshin.ffi_generated.dart` are committed.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` clean, `dart format --set-exit-if-changed .` clean (0 changed), `cargo make --allow-private test-core` (real cdylib, gate env) 935 passed.
- Matrix audit: every I/O row has a passing test — init new dest (`config_identity.rs` + FFI `init_into_a_new_destination_failing_late_names_it_in_left_behind`), init over `.git` (`convert.rs` `init_over_a_git_repo_failing_late_reports_its_jj`, FFI, Dart), init refusals and missing parent (`convert.rs` `init_refusals_that_write_nothing_leave_nothing_behind`, FFI, Dart), import missing parent (`convert.rs` + oracle), existing dest and `..` (`convert.rs`), alias prefix for a verb / clone / import (`op_support.rs`, `creation_warnings.rs`), push keeps the bare text (`push.rs`).
- Coverage not measured (loop gate rule); new lines got tests except the caller-spelling fallback of `create_destination` (canonicalize failing on a just-created directory, one line).

## Auto Run Result

Status: done

**Items:**
- **I1 — fixed (2bb36ad42af1cfca294d8faa88893aaa6d7389b4).** `Repo::init` fills `CreationOutcome.left_behind` on failure as convert does: the canonical destination when this call created it, then `<root>/.jj` once this call's jj-lib creation (`init_external_git` via `init_over_git_dir`, `init_colocated_git`, `init_internal_git`, `init_simple`) returned `Ok`, each only while it exists; empty on refusals that wrote nothing. Carried through `FfiError.left_behind` / `ZanshinFfiException.leftBehind` (no wire change); documented in `Repo::init`, `zanshin_repo_init`, `.fbs` + generated bindings, `initRepo`, `ffi-abi.md`, `rust-error-codes.md`. The `.git/` a failed NEW colocated init leaves is not listed (story scope) — deferred to Ralph.
- **I2 — fixed (2bb36ad42af1cfca294d8faa88893aaa6d7389b4).** `convert_import` creates its destination one level with `create_or_reuse_dir` semantics; a missing parent refuses `ConvertFailed` "Failed to create workspace: …" and creates nothing, as `jj git init --git-repo` (oracle `convert_import_missing_parent`). The `create_dir_all` liberalization and its docs are gone.
- **I3 — fixed (2bb36ad42af1cfca294d8faa88893aaa6d7389b4).** `resolve_immutable` reasons read "Invalid `revset-aliases.immutable_heads()`: <jj-lib error>" (`cli_util.rs:1146-1167`) for every verb's finish/guard, `clone` and `convert_import`'s head finish; `git push`'s commit check keeps jj-lib's bare text, as the CLI's plain `.resolve()?` (`push.rs:803-805`). The PARSE failure of the alias is not prefixed yet (pre-existing; deferred).
- **I4 — fixed (2bb36ad42af1cfca294d8faa88893aaa6d7389b4).** "Created" is read from the one `create_dir` result (`create_or_reuse_dir -> bool`), replacing `topmost_missing_ancestor`: an existing destination is never listed (closes the concurrent-create case by construction), and a `..` destination is listed canonically as the directory actually created.
- **I5 — fixed (2bb36ad42af1cfca294d8faa88893aaa6d7389b4).** The FFI docs of `zanshin_repo_init` / `_clone` / `_convert`, `ffi-abi.md` and the Dart docs of `initRepo` / `cloneRepo` / `convert` say a `watcher.io_error` comes after a successful creation: the repository is complete, carries no `left_behind`, and can be opened again. No `left_behind` on it (Ralph).

**Summary.** One helper, `creation::create_or_reuse_dir` (jj-lib's semantics, `true` iff this call's `create_dir` succeeded) plus `create_destination` (then canonicalize) and a `Created { destination, jj_dir }` record shared by `init` and the conversions; `init` and `convert_import` report from it on failure. `resolve_immutable` carries the CLI's text.

**Files changed (2bb36ad):**
- `crates/zanshin-jj/src/creation.rs` — `create_or_reuse_dir`, `create_destination`, `Created`, `failed_to_create_workspace`; `init` fills `left_behind`; unit tests.
- `crates/zanshin-jj/src/convert.rs` — one-level `import_into`, `Created` instead of `jj_created`, `OverGitDir` from `init_over_git_dir`, `topmost_missing_ancestor` removed, docs.
- `crates/zanshin-jj/src/op_support.rs`, `push.rs` — CLI prefix; push keeps the bare text.
- `crates/zanshin-jj/src/repo.rs` — `CreationOutcome.left_behind` / `Repo::init` docs.
- `crates/zanshin-jj/tests/it/{convert,creation_warnings,config_identity,op_support,push}.rs` — init/import/prefix witnesses, canonical 9.57 rows.
- `crates/zanshin-ffi/src/{repo,envelope}.rs`, `tests/it/repo_ffi.rs` — docs, init `left_behind` tests.
- `schemas/envelope.fbs` + generated header / Rust / Dart — `left_behind` doc.
- `packages/zanshin_core/lib/src/{worker/isolate,worker/responses,ffi/repo}.dart`, `test/worker/error_reports_test.dart` — docs, init witnesses.
- `crates/zanshin-parity/tests/oracle/{git_scenarios,main}.rs` — `convert_import_missing_parent`.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` — contracts.

**Review:** 28 findings (low 18, false 10). Patched (low): push commit check keeps the CLI's bare text (+ test, docs); two-entry init witness (new colocated init under a bad alias); `zanshin_repo_init` error bullets on `left_behind`; doc re-wraps; FFI new-destination and Dart refusal witnesses. Deferred (mirrored in deferred-work.md "Surfaced in Story 9.58"): the unlisted `.git/` of a failed new colocated init; the unprefixed PARSE failure of `immutable_heads()`. Rejected (reasons in the triage log): ENOTDIR destination text, non-UTF-8 lossy paths, untested canonicalize fallback, module coupling, redundant state, init oracle scenarios, native arm, Rust-only prefix witnesses, symlink unit cases, watcher wording, error class of the import refusal, low-level clone wrapper doc, ledger/result timing, `.git` scope.

**Follow-up review recommended:** false — patched counts high 0, medium 0, low 6 entries.

**Residual risks:** coverage ratchet not run (loop gate at the end) — the `create_destination` canonicalize-failure fallback line is untested; a failed new colocated init into an existing empty directory leaves an unlisted `.git/` (deferred).
