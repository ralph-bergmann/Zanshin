---
title: 'Story 9.34: Snapshot knobs read after `import git head` — the CLI''s refusal order in the precondition'
type: 'bugfix'
created: '2026-09-24'
status: 'done'
baseline_revision: '27445cf9916406dec5a9b1a0e438735b9338b782'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/docs/coverage.md'
warnings: ['oversized']
deferred:
  - summary: >-
      A snapshot-knob fault's `jj.config_error` reason carries a `config error: ` prefix (doubled in the Rust Display), a start-up-environment fault's does not.
    evidence: |-
      `wc_ops::auto_tracking_matcher` and `wc_ops::snapshot_options` map `ConfigError` with `mutate::cfg`, which stores its
      Display ("config error: ..."); `PreconditionError::Config`'s Display adds "config error: " again. Pre-existing for
      `snapshot.auto-track` in the precondition (Story 9.26) and for file track/untrack's own reads (Story 9.22). Story 9.34
      moved the precondition's `snapshot.max-new-file-size` read onto that helper (its reason was bare before) and the
      non-table `[fileset-aliases]` fault the other way (now bare, via `CommandEnv::load`). No test pins the exact context
      text; every witness uses `contains`. Settle: choose one form (bare, as `From<ConfigError>` gives), map `ConfigError`
      without `cfg` in the two wc_ops helpers, and pin the exact reason with `assert_eq` (snapshot_precondition,
      snapshot_ffi, file_track_untrack).
    location: >-
      crates/zanshin-jj/src/wc_ops.rs:205-207, :316; crates/zanshin-jj/src/mutate.rs:374
    severity: low
  - summary: >-
      The error registry's `jj.config_error` row does not list the pre-verb snapshot (Stories 9.26 / 9.34) as an emitter, nor its op-log effect.
    evidence: |-
      docs/rust-error-codes.md:56 lists the Story 9.27 settings refresh ("write nothing") and the Story 9.22 track/untrack
      reads, but not the pre-verb snapshot's start-up refusal (before the Git import/export lock, nothing written) or its
      snapshot-knob refusal (after a colocated `import git head`, which stays; partial precondition). Pre-existing omission
      since Story 9.26; the FFI wrappers' rustdoc carries the facts.
    location: >-
      docs/rust-error-codes.md:56
    severity: low
  - summary: >-
      `zanshin_file_track` / `_untrack`'s `jj.config_error` bullets name only their own keys, not the pre-verb snapshot's.
    evidence: |-
      crates/zanshin-ffi/src/file_ops.rs names only `snapshot.max-new-file-size` for track (auto-track + size for untrack),
      but the pre-verb snapshot also refuses an unparseable `snapshot.auto-track` (snapshot step) and a bad
      `immutable_heads()` alias or a non-table alias layer (start-up environment) on both. Pre-existing since Story 9.26.
    location: >-
      crates/zanshin-ffi/src/file_ops.rs (the two `jj.config_error` bullets)
    severity: low
  - summary: >-
      The `jj.stale_working_copy` bullets say "nothing is written", but in a colocated workspace whose Git HEAD moved, `import git head` is committed before the stale check.
    evidence: |-
      `snapshot_impl` runs `import_git_head` before `snapshot_working_copy`, whose `handle_stale_working_copy` refuses
      afterwards — as the CLI does (`cli_util.rs:1298-1326`, `:2079` @ v0.44.0). Pre-existing since Story 9.26, not changed
      by 9.34; every FFI wrapper's stale bullet and the registry row (docs/rust-error-codes.md:79) say "Nothing is written".
    location: >-
      crates/zanshin-ffi/src/*.rs (`jj.stale_working_copy` bullets); docs/rust-error-codes.md:79
    severity: low
---

<intent-contract>

## Intent

**Problem:** The pre-verb precondition reads `snapshot.auto-track`, the ignore files and `snapshot.max-new-file-size` in `snapshot::Knobs::read`, BEFORE the `git_import_export.lock` and `import git head`. The jj CLI @ v0.44.0 reads those three knobs only inside `snapshot_working_copy`, i.e. after the lock and the head import. In the double fault "Git HEAD moved outside AND a wrong-typed snapshot knob", the CLI therefore writes `import git head` and then fails, while Zanshin writes nothing and fails: two different op logs. The conversion (`convert.rs::external_arm`) has the same early read, so it fails with no precondition report where the CLI has already imported the HEAD (handed over by Story 9.33).

**Approach:** Split `Knobs` along the CLI's own seam.
- The start-up environment (the CLI's `WorkspaceCommandEnvironment::new`) stays before the lock: the `[fileset-aliases]` and `[revset-aliases]` tables with their warnings, and the `immutable_heads()` PARSE.
- The three snapshot knobs are read at the top of `snapshot_working_copy`, before the working-copy lock and the stale check, exactly where the CLI reads them.
- The verb precondition and the conversion share this change.

## Boundaries & Constraints

**Always:**
- **The CLI's read points @ v0.44.0 are the spec** (`git -C ../jj show v0.44.0:<path>`; Code Map has the lines).
  - Before the lock: fileset-alias table → revset-alias table (plus builtin redefinitions) → `immutable_heads()` parse and diagnostics.
  - Inside `snapshot working copy`, before `start_working_copy_mutation`: `snapshot.auto-track` → the ignore files (`base_ignores`) → `snapshot.max-new-file-size`.
  - Unchanged: `immutable_heads()` is RESOLVED only where a step needs it; the Git import options are read inside the refs step; `snapshot.auto-update-stale` only on the stale path.
- **Warning order is the CLI's print order** (Story 9.32). The start-up loads' warnings still come first, and the knob read inside the snapshot step records no second alias warning (`Warnings::record_load` is record-once).
- **Conversion:** the start-up read moves to the CLI's `for_workable_repo` point, after `init_git_refs` and BEFORE `maybe_add_gitignore` (`git/init.rs:250-254`). The knob reads happen inside `maybe_snapshot`, so `CreationOutcome.precondition` is `Some`, and partial, on a knob fault.
- A knob fault stays `PreconditionError::Config` (`RepoError::Config` for the conversion; `jj.config_error` on the wire) naming the key. Operations committed before it stay, and the partial report says so.
- **Coverage ratchet:** never lower `coverage-baseline.txt`, no `exclude_prefix`.

**Never:**
- **No other precondition change**, in particular:
  - no port of the remaining start-up environment (template aliases, `revsets.short-prefixes`, `ui.conflict-marker-style`, the `trunk()` fallback — Story 9.32's deferral);
  - no change to `file track`/`untrack`'s own knob reads (`wc_ops.rs:412/:529`);
  - no Dart change (the error arm is Story 9.35).
- Do not move the `immutable_heads()` PARSE after the lock. The CLI refuses a bad alias before it (Design Notes).
- No wire/schema change, and no new error or warning code.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Double fault (colocated) | `git commit` outside moved HEAD; repo config `snapshot.max-new-file-size = true` | Op log gains exactly `import git head`. Partial report: `git_head_imported`, `was_snapshot_taken`, `git_refs` `None`. The same on the FFI error envelope. | `Config` / `jj.config_error`, reason names the key |
| Knob fault, lock held | colocated; another holder keeps `git_import_export.lock` for `T` | The verb WAITS ≥ `T` (knob read after the lock), then refuses | `Config` naming the key |
| Bad `immutable_heads()`, lock held | `'immutable_heads()' = 'bogus_function()'`; lock held | Refused WITHOUT waiting; no operation written | `Config` |
| Knob fault, nothing to import | non-colocated, or HEAD unchanged; wrong-typed knob | No operation; report present, `was_snapshot_taken` false (unchanged behaviour) | `Config` naming the key |
| Warning order | bad `[fileset-aliases]` entry + wrong-typed size knob | Warnings exactly `[jj.config_alias_invalid]` before the refusal (unchanged) | `Config` |
| Conversion knob fault | colocated convert of a repo with a commit; user config `snapshot.max-new-file-size = true` | `precondition` `Some`: `git_head_imported`, `was_snapshot_taken`. `.jj/` rolled back. | `RepoError::Config` naming the key |
| Conversion bad alias | same, user config `'immutable_heads()' = 'bogus_function()'` | `precondition` `None` (fails before `maybe_snapshot`); `.jj/` rolled back | `RepoError::Config` |

</intent-contract>

## Code Map

The oracle is `git -C ../jj show v0.44.0:<path>` (`cu` = `cli/src/cli_util.rs`).

**CLI evidence:**
- `cu`:
  - `:472-516` `workspace_helper_with_stats`: environment `:477` BEFORE the lock `:482-485`, then load `:486`, then `snapshot_impl` `:492`, and `auto-update-stale` `:499`;
  - `:936-966` `WorkspaceCommandEnvironment::new`: fileset `:938` → revset `:939` → template `:940` aliases, `reload_revset_expressions` `:964` → `immutable_heads()` parse `:1078-1090`;
  - `:1298-1326` `snapshot_impl`; `:1331-1342` `maybe_snapshot`.
- `cu:2058-2231` `snapshot_working_copy`, in order:
  1. `auto_tracking_matcher` `:2065-2067` (`:1604-1611`);
  2. options `:2068-2070`: `base_ignores` `:1617`, then `max-new-file-size` `:1618-1623`;
  3. WC lock `:2073`, then stale check `:2079`;
  4. immutable RESOLVE `:2105-2108`, only when the tree changed.
- `cli/src/commands/git/init.rs:244-272`: `init_git_refs` `:250` → `for_workable_repo` `:252` → `maybe_add_gitignore` `:253` → `maybe_snapshot` `:254`.

**zanshin-jj:**
- `src/snapshot.rs`:
  - module doc `:18`; `PreconditionError::Config` doc `:165-168`;
  - `Knobs` `:243-302` (`read` `:275-290`, `snapshot_options` `:293-301`, to be replaced);
  - `VerbContext::new` `:321-338` (takes only `immutable` from it); `run` `:353-370`;
  - `StepCtx` `:455-475` (`knobs` field `:460`, `finish_ctx` `:468-474`);
  - `snapshot_working_copy` `:532-565`: options `:541`, placed before `start_working_copy_mutation` `:542`; `sink` and `ctx.config` are already in scope;
  - `commit_snapshot` `:580-587` and `import_git_refs` `:674` resolve immutable (unchanged).
- `src/repo.rs::Repo::precondition` `:230-299`: doc step 2 `:234-237`, `Knobs::read` `:264`, `run` `:266-273`, `VerbContext::new` `:292-298`.
- `src/wc_ops.rs`, all reused as-is:
  - `auto_tracking_matcher` `:186-221` reads `snapshot.auto-track` and (re)loads `[fileset-aliases]` with record-once warnings;
  - `base_ignores` `:269-296`;
  - `snapshot_options(workspace, config, matcher)` `:310-324`, already in the CLI's order (ignores, then size).
- `src/op_support.rs::immutable_user_expression` `:64-90`: revset table and `immutable_heads()` parse.
- `src/revset.rs::build_aliases_map` (used at `wc_ops.rs:206` for `"fileset-aliases"`); `src/warning.rs` `Load` `:112-119`, `record_load` `:143-148`.
- `src/convert.rs`:
  - module doc `:78-101` (item 3 "config-load warnings");
  - `maybe_snapshot` `:426-455` (`(config, knobs)` `:437`);
  - `external_arm` `:570-603`: `Knobs::read` `:596` sits AFTER `maybe_add_gitignore` `:595`; its doc is `:577-580`;
  - `import_head_into_destination` `:610-636` (`knobs.immutable` `:630`).

**Tests:**
- `crates/zanshin-jj/tests/snapshot_colocated.rs`:
  - `a_wrong_typed_knob_is_refused_before_the_lock` `:415-445` (to replace);
  - lock-hold idiom `a_held_git_import_export_lock_is_waited_for` `:394-413`;
  - double-fault idiom `an_invalid_import_option_fails_after_the_head_import_like_the_cli` `:447-476`;
  - helpers `colocated`, `git`, `write`, `descriptions`, `new_descriptions`, `lock_path`.
- `crates/zanshin-jj/tests/creation_warnings.rs`:
  - a single env-phased `#[test]` `:95-129`;
  - idioms `a_refs_step_failure_reports_no_snapshot` `:452-477` (user `JJ_CONFIG` file, reset to `""` after) and `a_snapshot_failure_keeps_a_partial_report` `:421-450`.
- `crates/zanshin-ffi/tests/snapshot_ffi.rs`:
  - helpers `open_handle` `:105`, `parse_envelope` `:86`, `warnings_of` `:91`, `snapshot(handle)`, `close_handle`;
  - `zanshin_jj` is a dependency, so `convert_colocated` is callable;
  - existing knob tests `:216-269`, `:306-345`.
- These must stay green UNMODIFIED; they are non-colocated or order-insensitive:
  - `snapshot_precondition.rs:332`;
  - `warnings.rs:505-533` (fileset warning before the size fault);
  - `content_ops.rs:474/:908` (bad alias → `Config`, no op);
  - `file_track_untrack.rs:802-831`;
  - Dart `test/worker/snapshot_test.dart:104`.

**FFI docs (+ `cargo make codegen` → `include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart`):**
- `src/snapshot.rs:87-91`: `zanshin_snapshot`'s `jj.config_error` order bullet.
- Every "…a knob it reads wrongly typed (the key in `context`); nothing is written." bullet: `status.rs:109`, `change.rs:141`, `op_log.rs:79`, `bookmarks.rs:69`, `remotes.rs:67`, `workspace.rs:151`, `commit_views.rs:428`, `file.rs:350/:451/:499`.
- `file_ops.rs:199/:254`.
- The "settings refresh; nothing is written" bullets stay (still true).

**Docs/bookkeeping:**
- `docs/rust-error-codes.md`: `:118` ("the conversion's knob read") and `:153` ("The conversions DO read the knobs").
- `spec-9-26-implicit-snapshot-colocated-git-import.md`: the matrix row `:175` and Design Notes `:608-609`.
- `deferred-work.md`: `:392`, `:438`, `:448`.
- `sprint-status.yaml`: `:133`, and `last_updated` `:31`.

## Tasks & Acceptance

**Execution:**
- [x] `crates/zanshin-jj/src/snapshot.rs` -- replace `Knobs` with the CLI's start-up environment.
  - The new type is `CommandEnv` (doc: the part of `WorkspaceCommandEnvironment::new` the precondition ports). `CommandEnv::load(workspace, config, sink)` loads `[fileset-aliases]` (warnings via `record_load(Load::FilesetAliases, …)`), then `immutable_user_expression`. It holds only `immutable`.
  - `snapshot_working_copy` first calls `wc_ops::auto_tracking_matcher(ctx.config, sink)?`, then `wc_ops::snapshot_options(workspace, ctx.config, matcher.as_ref())?`, before `start_working_copy_mutation`.
  - Delete `Knobs::snapshot_options`. `StepCtx::knobs` → `env`, and `VerbContext::new` takes `CommandEnv`.
  - Rewrite the module doc, the `PreconditionError::Config` doc and the `run`/`snapshot_impl` docs to state the read points.
  - Rationale: the CLI's read points.
- [x] `crates/zanshin-jj/src/repo.rs` -- `Repo::precondition` calls `CommandEnv::load` where `Knobs::read` was (still before the lock). Its doc steps 2-3 list the CLI's read points (start-up environment → lock → head import → snapshot knobs → refs-step import options; `auto-update-stale` on the stale path) -- keeps the verb precondition's contract honest.
- [x] `crates/zanshin-jj/src/convert.rs` -- `external_arm` runs `CommandEnv::load` right after `init_git_refs` and BEFORE `maybe_add_gitignore`. `maybe_snapshot`/`import_head_into_destination` take `&CommandEnv`. Rewrite the module doc item 3 and `external_arm`'s doc ("start-up environment", the knobs inside the snapshot) -- the 9.33 handover.
- [x] `crates/zanshin-jj/tests/snapshot_colocated.rs` -- replace `a_wrong_typed_knob_is_refused_before_the_lock` with the matrix's first three rows -- the inverted pin plus the reworked lock witnesses:
  - **Double fault** (`an_invalid_import_option_…` shape): `new_descriptions == ["import git head"]`, `Config` naming the key, and the partial report.
  - **Knob waits for the lock** (`a_held_…_waited_for` shape): elapsed ≥ hold, `Config`.
  - **Bad `immutable_heads()` refused without waiting** (the old test's `mpsc` + `recv_timeout` shape): op count unchanged.
- [x] `crates/zanshin-jj/tests/creation_warnings.rs` -- two phases in the configured-identity block, each with a user `JJ_CONFIG` file reset to `""` afterwards -- the conversion's matrix rows:
  - a wrong-typed size knob → `RepoError::Config`, `precondition` `Some` with `git_head_imported` + `was_snapshot_taken`, `.jj/` absent;
  - `'immutable_heads()' = 'bogus_function()'` → `RepoError::Config`, `precondition` `None`, `.jj/` absent.
- [x] `crates/zanshin-ffi/tests/snapshot_ffi.rs` -- new test: a real `git` repo with one commit, `zanshin_jj::convert_colocated(..).result`, open handle, repo config `snapshot.max-new-file-size = true`, a `git commit` outside, then `zanshin_snapshot`. Assert `jj.config_error` with the key in `context`, and `precondition().git_head_imported()` + `was_snapshot_taken()` -- the double fault at the outermost Rust surface.
- [x] `crates/zanshin-ffi/src/{snapshot,status,change,op_log,bookmarks,remotes,workspace,commit_views,file,file_ops}.rs` + `cargo make codegen` -- keep the docs true.
  - In the listed `jj.config_error` bullets, replace "nothing is written" with the fact that operations the snapshot committed before the fault stay (colocated `import git head`), as in the CLI, and that the partial `precondition` names them.
  - Rewrite `zanshin_snapshot`'s order sentence to the read points.
- [x] `docs/rust-error-codes.md`, `_bmad-output/implementation-artifacts/spec-9-26-implicit-snapshot-colocated-git-import.md` -- keep the docs accurate.
  - `:118`/`:153` say "start-up environment" instead of "knob read".
  - The 9.26 matrix row `:175` and Design Notes `:608` get a dated note: "2026-09-24, Story 9.34: superseded — the CLI reads the snapshot knobs after `import git head`; only the start-up environment is refused before the lock". The row's original text stays.
- [x] `_bmad-output/implementation-artifacts/{deferred-work.md, sprint-status.yaml}`, `coverage-baseline.txt` -- bookkeeping.
  - Strike through `:392`, `:438` and `:448` with "RESOLVED 2026-09-24 (Story 9.34)".
  - Set `9-34` to `done` with a summary, and bump `last_updated`.
  - Commit an auto-raised baseline.

**Acceptance Criteria:**
- Given the repo after the change, when `crates/zanshin-jj/src` is searched, then neither the precondition nor the conversion reads a snapshot knob (`snapshot.auto-track`, `snapshot.max-new-file-size`, `base_ignores`) before `lock_git_import_export`. No rustdoc in `snapshot.rs`, `repo.rs`, `convert.rs` or the FFI wrappers claims otherwise, and grep `Knobs` finds nothing in `crates/`. (`file track`'s own "before the lock" refusals refer to its working-copy lock and stay.)
- Given the unmodified existing witnesses listed in the Code Map, when the suites run, then they pass. The start-up warnings still precede every step's warnings.
- Given the finished change, when `cargo make test` runs, then every step except the 3 pre-existing `test-flutter` splash-card failures is green, including clippy, the coverage ratchet and the extern guard.

## Spec Change Log

## Review Triage Log

- **2026-09-24 — twin check (implementation pass).** Installed `jj` is 0.45.1 (not the 0.44.0 pin); scratch `git` repo with one commit on `main`, `JJ_CONFIG`/`GIT_CONFIG_GLOBAL` = `/dev/null`, identity via `JJ_USER`/`JJ_EMAIL`. `jj git init --colocate` writes `import git head`, `import git refs`, `add workspace 'default'`. After `git commit --allow-empty -m outside`, `jj --config snapshot.max-new-file-size=true status` prints "Reset the working copy parent to the new Git HEAD.", then `Config error: Invalid type or value for snapshot.max-new-file-size` (exit 1); `jj op log` then shows a NEW `import git head` on top — the double fault writes the head import and then fails, as the new witnesses pin (`snapshot_colocated.rs::a_wrong_typed_knob_fails_after_the_head_import_like_the_cli`, the FFI and conversion rows). After a second outside commit, `jj --config "revset-aliases.'immutable_heads()'='bogus_function()'" status` fails with ``Config error: Invalid `revset-aliases.immutable_heads()` `` and the op log is unchanged — no head import, as `a_bad_immutable_heads_alias_is_refused_before_the_lock` pins.
- **2026-09-24 — twin check re-run (review step).** Same scenario against installed `jj` 0.45.1 in a scratchpad repo: `--config snapshot.max-new-file-size=true status` prints "Reset the working copy parent to the new Git HEAD." then `Config error: Invalid type or value for snapshot.max-new-file-size` (exit 1), and the op log gains `import git head`; after a second outside commit, the bad `immutable_heads()` alias fails with ``Config error: Invalid `revset-aliases.immutable_heads()` `` and the op log is unchanged. Matches the witnesses.

### 2026-09-24 — Review pass
- verdicts: 28 findings — high 0, medium 0, low 22, false 6, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) The `jj.config_error` doc update skipped the mutation wrappers (new_change, undo, bookmark create/delete, git export / remote add / set-url still say only "nothing is written") and several read wrappers never name the pre-verb snapshot fault — grouped with the edge finding below. Patched: the 7 settings-refresh bullets (`repo.rs` ×2, `git.rs` ×3, `bookmark_ops.rs` ×2) now add the pre-verb snapshot's knob fault and that its committed operations stay (partial `precondition`); `cargo make codegen` refreshed header + bindings. The read-wrapper bullets that never named the pre-verb snapshot make no op-log claim and predate this story — left.
  - `[low]` `[defer]` (blind) The registry's `jj.config_error` row (`docs/rust-error-codes.md:56`) does not list the pre-verb snapshot as an emitter; `docs/ffi-abi.md`'s convert section omits the start-up environment step — the ffi-abi part is refuted (its "present iff it started (PARTIAL when it failed)" and its warning order stay true); the registry omission is pre-existing since 9.26 → deferred.
  - `[low]` `[defer]` (blind) The new per-verb wording is imprecise — refuted in part: "(colocated: `import git head`)" is exactly what a snapshot-knob fault leaves and the sentence defers the rest to "the partial `precondition` says which"; "operations committed before the fault stay" is vacuously true for a start-up fault. The remaining part — `zanshin_file_track`/`_untrack`'s bullets name only their own keys, not the pre-verb snapshot's auto-track / `immutable_heads()` refusals — predates 9.34 → deferred.
  - `[low]` `[patch]` (blind) Nothing tests the resolved 9.32 deferral (a `[revset-aliases]` warning now precedes a wrong-typed knob refusal) — patched: `tests/warnings.rs::a_revset_alias_warning_precedes_a_wrong_typed_knob` (fails on the old `Knobs::read` order).
  - `[low]` `[patch]` (blind) The `[fileset-aliases]` load in `CommandEnv::load` has no pinning test — grouped with intent I2/I3; patched: `tests/snapshot_colocated.rs::a_non_table_fileset_aliases_is_refused_before_the_lock` (Git HEAD moved + held lock: refused without waiting, no operation — would block on the lock if the load moved into the snapshot step).
  - `[low]` `[reject]` (blind) `CommandEnv` discards the fileset map it loads and the snapshot step re-parses the table — the redundant parse of a small table is negligible, record-once dedup is the documented Story 9.32 invariant, and the fix changes `wc_ops::auto_tracking_matcher`'s signature shared with file track's own reads (a Never boundary); the spec's Design Notes chose this deliberately.
  - `[low]` `[patch]` (blind) Stale references after the rename — patched: `deferred-work.md` "Three CLI start-up environment steps" item now points at `snapshot.rs::CommandEnv::load`, the 9.33 start-up-environment item says the conversions "build the start-up environment"; 9.26 spec frontmatter `deferred` entry and implementation step 3 carry a dated 9.34 note; `creation_warnings.rs` module doc names the 9.34 rows. Refuted parts: `file_track_untrack.rs:808` ("before its lock" = the working-copy lock, still true; the test is non-colocated and must stay unmodified), `epics.md` Story 9.34 (its problem statement describes the pre-change state it fixes).
  - `[false]` `[reject]` (blind) The Story 9.34 spec is untracked, so the sprint-status reference dangles — the finalize step commits the spec with the change.
  - `[false]` `[reject]` (blind) `CommandEnv`'s rustdoc doesn't name what it omits — it enumerates exactly what it ports ("the part … the precondition ports: …"); no concrete harm named; the omissions are tracked in `deferred-work.md`.
  - `[low]` `[patch]` (blind) The new start-up tests assert too little — grouped with edge E1/E2; patched: both bad-alias witnesses (`snapshot_colocated.rs`, `creation_warnings.rs`) now require the reason to name `bogus_function`; the lock-wait witness also asserts the partial report (`!git_head_imported`, `!was_snapshot_taken`) and no warnings.
  - `[low]` `[patch]` (blind) Nothing tests the `convert_import` (non-colocated) error arm, whose `precondition` changed from `None` to `Some` — grouped with intent I6; patched: `creation_warnings.rs::a_wrong_typed_snapshot_knob_fails_inside_the_import_snapshot` (Config naming the key, partial report with no operation, `.jj/` rolled back).
  - `[low]` `[patch]` (blind) The new lock-wait witness takes `started` after spawning the releaser, so `elapsed >= hold` leans on post-lock work outlasting the head start — patched: `started` is taken before the spawn in `a_wrong_typed_knob_is_refused_only_once_the_held_lock_is_free`. The pre-existing `a_held_git_import_export_lock_is_waited_for` has the same shape (not this story's code).
  - `[low]` `[patch]` (edge) The conversion bad-alias witness matches any `Config` — grouped with blind "assert too little"; patched there.
  - `[low]` `[patch]` (edge) The colocated bad-alias witness dropped the old reason assertion — grouped with blind "assert too little"; patched there.
  - `[low]` `[patch]` (edge) Seven mutation wrappers still document `jj.config_error` as "nothing is written" — grouped with blind B1; patched there.
  - `[low]` `[defer]` (verification-gap) The `jj.config_error` context text changed for two faults (the size knob gained `config error: `, a non-table `[fileset-aliases]` lost it) and no test pins the exact text — the root cause, `mutate::cfg` keeping `ConfigError`'s Display in the two wc_ops helpers, predates 9.34 (auto-track and file track already carried it); fixing it changes file track's own error text, outside this story → deferred with the intended-form decision.
  - `[low]` `[patch]` (verification-gap) No test pins that a wrong-typed knob is refused before the stale check — grouped with intent I4; patched: `tests/snapshot_precondition.rs::a_wrong_typed_knob_wins_over_a_stale_working_copy`.
  - `[low]` `[defer]` (verification-gap, other) Doubled `config error: ` prefix — same root cause as the context-text finding above; deferred with it.
  - `[false]` `[reject]` (verification-gap, other) Stale comment `file_track_untrack.rs:808` — "before its lock" is the working-copy lock, which the knob read still precedes (`cli_util.rs:2065-2073`); the non-colocated test takes no Git lock.
  - `[false]` `[reject]` (intent) The op log is asserted only at the Rust `Repo` layer — the matrix's FFI expectation is the partial report, which the FFI witness asserts; the conversion's rollback erases its op log by design.
  - `[low]` `[patch]` (intent) The `[fileset-aliases]` table has no "refused before the lock" witness — grouped with blind B5; patched there.
  - `[low]` `[patch]` (intent) The warning-order tests cannot tell where the fileset table loads — grouped with blind B5; the before-the-lock witness pins the load's placement.
  - `[low]` `[patch]` (intent) "Before the stale check" and "before `maybe_add_gitignore`" are unwitnessed — grouped with the verification-gap stale finding; patched for the stale check. The `.gitignore`-order half needs a write-fault seam between `init_external_git` and `maybe_add_gitignore` — not added.
  - `[low]` `[patch]` (intent) `snapshot.auto-track` at its new read point is untested (the ignore-file read moving after the head import is correct CLI parity) — patched: `tests/snapshot_colocated.rs::a_wrong_typed_auto_track_fails_after_the_head_import_like_the_cli`.
  - `[low]` `[patch]` (intent) The non-colocated conversion's `precondition` change is untested — grouped with blind B11; patched there.
  - `[false]` `[reject]` (intent) The regenerated `bindings.dart` says "the partial `precondition` says which" although Dart drops error reports — the text documents the C envelope, which carries it; Dart's error-arm gap is `docs/ffi-abi.md:124-127` / Story 9.35.
  - `[false]` `[reject]` (intent) Resolved `deferred-work.md` items keep their bodies (one names the removed test) and `coverage-baseline.txt` is not in the diff — the struck-through title + RESOLVED note keep the body as history by design; coverage held (99.46%), so the baseline did not change.
  - `[low]` `[defer]` (intent) The `jj.stale_working_copy` bullets say "nothing is written", but a colocated `import git head` commits before the stale check — pre-existing since 9.26, untouched by this story → deferred.

## Design Notes

**Why `immutable_heads()` does not move.** The epic's gloss ("`immutable_heads()` where `snapshot_working_copy` needs it") matches the CLI only for the RESOLVE. The CLI PARSES the alias in `WorkspaceCommandEnvironment::new` (`cu:964` → `:1078-1090`), which `workspace_helper_with_stats` runs before the lock (`cu:477`). It resolves it inside the snapshot transaction (`cu:2105-2108`). Zanshin already does both at those points (`immutable_user_expression` before the lock; `resolve_immutable` in `commit_snapshot`/`import_git_refs`/`finish_transaction`). The story's rule "read each knob where the CLI reads it" therefore leaves it unchanged. Moving the parse after the head import would create the mirror-image op-log divergence.

**Why `CommandEnv` also loads `[fileset-aliases]`.** Today that table's warnings are recorded inside `auto_tracking_matcher`, first. Once that call moves into the snapshot step, the table would be recorded after the head import's warnings, which is not the CLI's order (`cu:938`). Loading it in `CommandEnv::load` keeps the order. The later `auto_tracking_matcher` re-load is silent (`record_load` is record-once) and cheap; a second API variant would not be worth it.

**Other double faults, for the record.** These are not witnessed and follow from the placement:
- a stale working copy plus a wrong-typed knob still refuses on the knob, because the knobs are read before the stale check, as in the CLI;
- in the conversion, a failed `.jj/.gitignore` write plus a bad alias entry now carries the alias warnings, because the start-up read precedes `maybe_add_gitignore` (9.33 follow-up row, rejected there and routed here).

## Verification

**Commands.** Run in the foreground. If a toolchain is missing, set `SDK_PATH`/`CARGO_HOME`/`RUSTUP_HOME`/`FLUTTER_ROOT` under `~/development/sdks`. Revert `pubspec.lock` drift after Dart runs.
- `cargo make codegen`, then `git status` -- expected: only the generated header/bindings change (doc text).
- `cargo make --allow-private test-cargo`, `test-clippy`, `test-fmt`, `test-dart-analyze`, `test-dart-format`, `test-core`, `test-core-analyze`, `test-core-format`, the `test-shell*`/`test-settings*` steps, `test-cargo-deny`, `test-cargo-hygiene`, `test-jj-adapter-hygiene`, `coverage` -- expected: green; coverage ≥ baseline; extern guard OK.
- `cargo make --allow-private test-flutter` -- expected: only the 3 pre-existing `zanshin_bootstrap_test.dart` failures.
- `grep -rn "Knobs" crates/` -- expected: no match.

**Manual checks:**
- **Twin check** with the installed `jj` (0.45.x), in a scratchpad `git` repo with one commit, `jj git init --colocate`, then `git commit --allow-empty -m outside`:
  - Run `jj --config snapshot.max-new-file-size=true status`. It is expected to fail with a config error naming the key.
  - Then `jj op log --no-graph -T 'description ++ "\n"' --limit 2` is expected to show `import git head` on top.
  - Record the result in the Review Triage Log.

## Auto Run Result

Status: done

**Summary.** `snapshot::Knobs` is replaced by `snapshot::CommandEnv`, the ported part of the CLI's `WorkspaceCommandEnvironment::new`: the `[fileset-aliases]` table, then the `[revset-aliases]` table and the `immutable_heads()` parse, built BEFORE `git_import_export.lock`. The three snapshot knobs (`snapshot.auto-track`, the ignore files, `snapshot.max-new-file-size`) are read at the top of `snapshot_working_copy` — after `import git head`, before the working-copy lock and the stale check — exactly where the CLI reads them. The double fault "Git HEAD moved outside AND a wrong-typed snapshot knob" now writes `import git head` and then fails with `jj.config_error`, as the CLI does (twin-checked against jj 0.45.1). The conversion builds the start-up environment at `for_workable_repo` (after `init_git_refs`, before `.jj/.gitignore`), so a knob fault there carries a PARTIAL `precondition`. No wire/schema/Dart/error-code change.

**Files changed.**
- `crates/zanshin-jj/src/snapshot.rs` — `Knobs` → `CommandEnv`; `snapshot_working_copy` reads the knobs itself; rustdoc states every read point.
- `crates/zanshin-jj/src/repo.rs` — `Repo::precondition` builds `CommandEnv` before the lock; doc steps 2-3 list the CLI's read points.
- `crates/zanshin-jj/src/convert.rs` — `external_arm` builds `CommandEnv` after `init_git_refs`, before `maybe_add_gitignore`; module doc item 3 and `external_arm`/`maybe_snapshot` docs.
- `crates/zanshin-jj/src/{mutate,op_support}.rs` — doc links `Knobs` → `CommandEnv`.
- `crates/zanshin-ffi/src/{snapshot,status,change,op_log,bookmarks,remotes,workspace,commit_views,file,file_ops}.rs` — `jj.config_error` bullets: committed operations stay, the partial `precondition` says which; `zanshin_snapshot`'s read-point sentence.
- `crates/zanshin-ffi/src/{repo,git,bookmark_ops}.rs` — (review patch) the 7 settings-refresh `jj.config_error` bullets add the pre-verb snapshot's knob fault.
- `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart` — regenerated (doc text only).
- `crates/zanshin-jj/tests/snapshot_colocated.rs` — the old "refused before the lock" pin replaced by the double-fault, lock-wait and bad-alias witnesses; (review) auto-track double fault, non-table `[fileset-aliases]` refused before the lock, stronger assertions, clock started before the releaser.
- `crates/zanshin-jj/tests/creation_warnings.rs` — conversion knob fault (partial report) and bad-alias (no report) phases; (review) `convert_import` knob-fault phase, reason assertion, module doc.
- `crates/zanshin-jj/tests/snapshot_precondition.rs` — (review) knob fault wins over a stale working copy.
- `crates/zanshin-jj/tests/warnings.rs` — (review) a `[revset-aliases]` warning precedes a wrong-typed knob refusal.
- `crates/zanshin-ffi/tests/snapshot_ffi.rs` — double fault on the FFI error envelope.
- `docs/rust-error-codes.md` — "start-up environment" wording.
- `_bmad-output/implementation-artifacts/spec-9-26-…md` — dated supersede notes (matrix row, Design Notes; review: frontmatter deferral, step 3).
- `_bmad-output/implementation-artifacts/deferred-work.md` — three items RESOLVED; (review) two stale refs fixed, new "Surfaced 2026-09-24 while reviewing Story 9.34" section.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `9-34` done with summary and review-pass note.

**Review findings breakdown.** 28 findings (high 0, medium 0, low 22, false 6, maybe-false 0).
- Patches applied (9 entries, all `low`): mutation-wrapper `jj.config_error` bullets (+codegen); witness for the resolved 9.32 alias-warning deferral; witness pinning `CommandEnv`'s `[fileset-aliases]` load before the lock; stale-reference bookkeeping; stronger start-up-refusal assertions; `convert_import` knob-fault witness; lock-wait clock before the releaser; knob-before-stale-check witness; auto-track double-fault witness. The implementation subagent could not be re-engaged synchronously in this unattended run, so the orchestrating run applied the patches itself.
- Deferred (4, all `low`, frontmatter `deferred` + `deferred-work.md`): the `cfg` double `config error: ` prefix / no exact-context test; the registry `jj.config_error` row lacks the pre-verb snapshot; file track/untrack bullets name only their own keys; `jj.stale_working_copy` "nothing is written" after a colocated head import.
- Rejected: `CommandEnv` discards the fileset map (low — negligible re-parse, record-once is the documented invariant, fix would change a helper shared with file track's own reads); untracked spec (false — committed at finalize); `CommandEnv` rustdoc omissions (false — it enumerates what it ports); stale `file_track_untrack.rs:808` comment (false — "its lock" is the working-copy lock); op log asserted only at the `Repo` layer (false — the FFI row's expectation is the partial report); `bindings.dart` report sentence (false — documents the C envelope; Dart gap is Story 9.35); bookkeeping bodies / baseline (false — history kept by design; coverage held).

**Follow-up review recommendation:** `false` — first pass; patched entries by verdict: high 0, medium 0, low 9.

**Verification performed.**
- `cargo make codegen` → only the generated header/bindings changed (doc text); `pubspec.lock` drift reverted after every Dart run.
- `cargo make --allow-private` `test-cargo`, `test-clippy`, `test-fmt`, `test-dart-analyze`, `test-dart-format`, `test-core` (464 passed), `test-core-analyze`, `test-core-format`, all nine `test-shell*` steps, the three `test-settings*` steps, `test-cargo-deny`, `test-cargo-hygiene`, `test-jj-adapter-hygiene`, `coverage` → green, before and after the review patches; coverage held at 99.46% (baseline unchanged), extern guard OK.
- `cargo make --allow-private test-flutter` → only the 3 pre-existing `zanshin_bootstrap_test.dart` splash-card failures.
- `grep -rn "Knobs" crates/` → no match.
- Matrix audit: all 7 rows covered by tests that ran and passed (`snapshot_colocated.rs` double fault / lock-wait / bad alias, `snapshot_ffi.rs` double fault + `a_wrong_typed_knob_is_jj_config_error_with_a_partial_report`, `snapshot_precondition.rs::a_wrong_typed_knob_is_a_config_fault_naming_the_key`, `warnings.rs::warnings_ride_the_error_arm_too`, `creation_warnings.rs` conversion phases).
- Twin check against the installed jj 0.45.1 (twice; see Review Triage Log).

**Residual risks.**
- The `jj.config_error` context text for a wrong-typed `snapshot.max-new-file-size` now carries a `config error: ` prefix (as `snapshot.auto-track` already did) — deferred with the intended-form decision.
- The "start-up environment before `.jj/.gitignore`" order in the conversion is implemented and documented but unwitnessed (needs a write-fault seam).
- The installed jj is 0.45.1, not the 0.44.0 pin; the twin check matches the v0.44.0 source read points.
