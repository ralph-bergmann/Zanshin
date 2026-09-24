---
title: 'Story 9.33: Creation paths report what the CLI prints — `clone`/`init`/`convert`: `jj.identity_missing` + the conversion''s snapshot report'
type: 'feature'
created: '2026-09-24'
status: 'done'
baseline_revision: '9c77e2ca6c1d0eda9f52f2ddadd82877aa633d64'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/docs/coverage.md'
warnings: ['oversized']
deferred:
  - summary: >-
      Repo::clone into an EXISTING jj workspace deletes its .jj/ — data loss the CLI cannot cause (severity high).
    evidence: |-
      init_internal_git refuses a target with .jj/ (DestinationExists, jj-lib workspace.rs:121-129 @ 0.44.0) and the clone rollback then removes the pre-existing .jj/; the CLI refuses a non-empty destination first (cli/src/commands/git/clone.rs:187-192 @ v0.44.0). Recorded, not fixed (Never list).
    location: >-
      crates/zanshin-jj/src/repo.rs::Repo::clone / roll_back_clone; deferred-work.md "Surfaced 2026-09-24 while implementing Story 9.33" → Story 9.20 or an immediate fix story
  - summary: >-
      The CLI's start-up environment is not ported to clone/init — its warnings and clone's became-immutable check are absent.
    evidence: |-
      for_workable_repo (cli/src/cli_util.rs:936-966 @ v0.44.0, twice on clone) loads the alias tables and parses immutable_heads()/short-prefixes/templates; Zanshin's init/clone read none of it. The conversions do (Knobs::read).
    location: >-
      crates/zanshin-jj/src/repo.rs::Repo::init / Repo::clone → Story 9.20 (clone parity) / the start-up-environment port 9.32 deferred
  - summary: >-
      clone warns jj.identity_missing once where the CLI warns up to three times (one per finished transaction).
    evidence: |-
      clone.rs:352/:457/:314 @ v0.44.0 finish three transactions; Zanshin writes one `clone` operation. Twin check (jj 0.45.1): three identity warnings on `jj git clone`.
    location: >-
      crates/zanshin-jj/src/repo.rs::clone_into → Story 9.20 (op split)
  - summary: >-
      The conversion reads its snapshot knobs before the snapshot starts, so a wrong-typed knob fails with no precondition, where the CLI has already imported the Git HEAD.
    evidence: |-
      external_arm calls snapshot::Knobs::read before maybe_snapshot sets the report; the CLI reads snapshot.auto-track / max-new-file-size inside snapshot_working_copy, after maybe_snapshot's lock and colocated `import git head` (cli/src/cli_util.rs:1331-1416 @ v0.44.0). Verbs set Some(default) before their knob read, so the two differ on this double fault. Pre-existing knob-read order, the verb half of which Story 9.34 already owns (review pass 2026-09-24, Blind Hunter + Edge Case Hunter).
    location: >-
      crates/zanshin-jj/src/convert.rs::external_arm → Story 9.34 (extend its scope to the conversion)
    severity: low
  - summary: >-
      Repo::init over a directory that already holds .git/ creates an internal-git workspace beside it, where the CLI's `jj git init` runs the External flow (git.colocate = true) or refuses (git.colocate = false).
    evidence: |-
      cli/src/commands/git/init.rs:198-234 @ v0.44.0 picks GitInitMode::External over an existing .git (warnings, snapshot) or refuses "Did not create a jj repo because there is an existing Git repo in this directory."; Zanshin's init always calls init_internal_git / init_simple. Pre-existing (review pass 2026-09-24, Blind Hunter + Intent Alignment).
    location: >-
      crates/zanshin-jj/src/repo.rs::Repo::init → Story 9.20 (init parity)
    severity: low
  - summary: >-
      A clone that fails after the CLI's `add git remote` finish lacks the identity warning the CLI already printed.
    evidence: |-
      The CLI commits `add git remote origin` through tx.finish (git/clone.rs:352 @ v0.44.0) before fetching, so an empty identity warns even when the fetch then fails; Zanshin commits no remote operation (throwaway transaction) and warns only after its single `clone` commit. Part of the recorded op-split divergence (review pass 2026-09-24, Edge Case Hunter).
    location: >-
      crates/zanshin-jj/src/repo.rs::clone_into → Story 9.20 (op split)
    severity: low
  - summary: >-
      No test drives Repo::clone into a failed rollback, so jj.clone_cleanup_failed through the clone (last warning) is witnessed only at the helper and the synthetic FFI envelope.
    evidence: |-
      The only trigger without a fault seam is a pre-existing .jj/ with a read-only entry — the recorded data-loss path. Add the end-to-end witness with Story 9.20's rollback fix instead of pinning that path (review pass 2026-09-24, Verification Gap).
    location: >-
      crates/zanshin-jj/src/repo.rs::Repo::clone / roll_back_clone
    severity: low
  - summary: >-
      The zanshin_core barrel exports neither RepoHandle nor CreatedRepoHandle nor Precondition, so the app cannot name the creation result's types without a src/ import.
    evidence: |-
      packages/zanshin_core/lib/zanshin_core.dart exports ZanshinWorker and the warning types only; RepoHandle and Precondition were already absent before this story (type inference still exposes .warnings / .precondition). Pre-existing (review pass 2026-09-24, Blind Hunter).
    location: >-
      packages/zanshin_core/lib/zanshin_core.dart
    severity: low
  - summary: >-
      Until Story 9.35 a failed creation's warnings are visible nowhere on the Dart side — no exception field and no log.
    evidence: |-
      Before this story the conversion's warnings were traced (log_dropped("convert")); now they ride the error envelope, and _createdOrThrow turns it into ZanshinFfiException(code, context). Rust/MCP callers keep them. Story 9.35 owns the creation verbs' error results (follow-up review 2026-09-24, Edge Case Hunter).
    location: >-
      packages/zanshin_core/lib/src/worker/isolate.dart::_createdOrThrow → Story 9.35
    severity: low
---

<intent-contract>

## Intent

**Problem:** `zanshin_repo_init`/`_clone`/`_convert` answer with a bare `RepoHandle`. The warnings the jj CLI @ v0.44.0 prints on those flows are dropped (`convert.rs::external_arm` logs them through `log_dropped`; `Repo::clone` never records any). That covers the empty identity after a committed operation, the conversion's snapshot/import/export warnings, and a failed clone clean-up. The conversion's snapshot report (Story 9.26's `Precondition`) never leaves Rust. A GUI clone, typically the first action on a new machine, therefore learns of an empty identity only at the first later mutation.

**Approach:** The four `zanshin-jj` creation functions return a `CreationOutcome { result, precondition, warnings }`. It has the `ConfigSetOutcome` shape and is filled on both arms, exactly where the CLI's flow warns. The FFI stamps it into the EXISTING `Envelope.precondition` / `Envelope.warnings` on the ok and the error envelope (no new wire field). Dart `initRepo`/`cloneRepo`/`convert` return a `CreatedRepoHandle`, a source-compatible `RepoHandle` subtype exposing `warnings` and `precondition`.

## Boundaries & Constraints

**Always:**
- **9.32's rule applied to the creation flows:** every `ui.warning_*` the CLI @ v0.44.0 reaches on a step Zanshin's creation flow ports becomes its registered `jj.*` code. Messages follow 9.32's verbatim rule, and warnings come in the CLI's print order. Design Notes § Inventory is the authoritative mapping; every other CLI site on these flows is an entry in the registry's out-of-scope list with a reason and an owner.
- **Identity:** `jj.identity_missing` fires ONCE per operation a finish-equivalent commits:
  - clone's single `clone` op;
  - `convert_import`'s `import git head` finish (`init.rs:268`);
  - the colocated conversion's precondition finishes, exactly as 9.32 already emits them.
  - It never fires for `Repo::init`, nor for a raw `tx.commit` step (`add workspace`, `init_git_refs`'s `import git refs`).
- **Clone order:** `jj.git_import_failed` (the fetch's import stats; `clone.rs:456`) → commit → `jj.checkout_files_skipped` (the `workspace.check_out` stats, today discarded) → `jj.identity_missing`. On the error arm only, `jj.clone_cleanup_failed` comes LAST.
- **Convert order:**
  1. `init_git_refs`: `jj.git_import_failed` (`init.rs:304`), printed BEFORE its `has_changes()` early return.
  2. Colocated only: `jj.git_export_failed` (`init.rs:311-312`).
  3. `Knobs::read`'s config-load warnings.
  4. `maybe_snapshot`'s `snapshot_impl` warnings.
  5. `snapshot_stats` warnings, on success only (`cu:1340`).
  6. Non-colocated only: the head-import finish's warnings.
- **`CreationOutcome.precondition`** is `Some` iff the conversion's `maybe_snapshot` started. It is PARTIAL on failure, and `was_snapshot_taken` is computed as `snapshot::run` does. It is always `None` for init and clone.
- **Both arms carry the report:** the outcome keeps everything recorded before a failure. FFI error envelopes carry it, including `watcher.io_error` after a successful creation. `zanshin_repo_open` stays report-free.
- **New code** `jj.clone_cleanup_failed` (`WarningKind::CloneCleanupFailed`). It reports `clone.rs:277-282` "Failed to clean up {path}: {err}", with the canonical target path and the `io::Error` of the `.jj/` removal. Follow the full "Adding a New Code" warning checklist (`docs/rust-error-codes.md`).
- **Wire:** only fbs DOC comments change (the `Envelope` paragraph now names convert as a precondition carrier) → `cargo make codegen`.
- **Dart:** `initRepo`/`cloneRepo`/`convert` return `Future<CreatedRepoHandle>`; `openRepo` still returns a plain `RepoHandle`. `lastPrecondition` is untouched, because creation is not a verb on the handle. Decoding uses the shared `decodeEnvelopeWarningsInternal` + `decodePreconditionInternal`.
- **Coverage ratchet:** never lower `coverage-baseline.txt`, no `exclude_prefix`.

**Never:**
- **No change to what the flows do:** operations written, refusals, rollback scope, colocation, `--branch`, object hash, destination creation are all 9.20's. No op split for clone. Do NOT fix the surfaced clone-rollback data loss (Design Notes); record it.
- **No port of the CLI start-up environment into init/clone** (`for_workable_repo`: alias maps, `immutable_heads()`/short-prefixes/template parses, and their refusals). Hence clone gets no became-immutable check.
- No new payload data (the conversion's refs step stays warning-only), no Dart error-path exposure (9.35), no UI, no warnings on `open`, no text parsing.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Init | empty dir, identity EMPTY | ok; warnings `[]`; precondition `None` | N/A |
| Clone, identity set | `file://` source with a commit | ok; warnings `[]`; precondition `None` | N/A |
| Clone, identity empty | same, `JJ_USER`/`JJ_EMAIL` unset | exactly ONE `jj.identity_missing` ("Name and email not configured. …"), last | N/A |
| Clone, colliding file | target already holds untracked `a.txt`, which the default branch also has | `jj.checkout_files_skipped` "1 of those updates were skipped because there were conflicting changes in the working copy."; the file is untouched | N/A |
| Clone fails, clean-up fails | fetch fails; `.jj/` cannot be removed | `CloneFailed` (`jj.jj_lib_error`) + `jj.clone_cleanup_failed` "Failed to clean up <target>: <io error>" last | refusal unchanged |
| Convert import, identity empty | source with born HEAD | ONE `jj.identity_missing` (head-import finish) | N/A |
| Convert colocated, identity empty | plain repo, no ref moves | NO `jj.identity_missing` (the CLI commits the head import via `maybe_commit_transaction`) | N/A |
| Big new file | convert colocated, or import into an EXISTING destination holding it; a file > `snapshot.max-new-file-size` | `precondition.snapshot_stats.untracked` names it + `jj.snapshot_files_refused` | N/A |
| Reserved ref | colocated source has `refs/remotes/git/stolen` | `jj.git_import_failed` TWICE: the refs step, then the precondition's refs import (CLI parity) | N/A |
| Convert fails late | the trunk-alias write fails (`tests/convert_alias_write_failure.rs`) | error + partial precondition + warnings so far; `.jj/` rolled back | refusal unchanged |
| Open | any repo | unchanged: no precondition, no warnings | N/A |

</intent-contract>

## Code Map

The oracle is `git -C ../jj show v0.44.0:<path>` (`cu` = `cli/src/cli_util.rs`).

**CLI evidence:**
- `cli/src/commands/git/clone.rs`:
  - `:277-282` clean-up warning;
  - `:352`/`:457`/`:314` the three `tx.finish` (add remote / fetch / checkout);
  - `:436-443` unmatched `-b`;
  - `:456` `print_git_import_stats`.
- `cli/src/commands/git/init.rs`:
  - `:238-243`/`:273-275` empty-dir modes finish nothing;
  - `:246-270` External;
  - `:302-316` `init_git_refs` (`tx.commit`, summary `:304`, export `:311-312`);
  - `:268` head-import finish.
- `cu`:
  - `:1331-1342` `maybe_snapshot` (stats printed AFTER `snapshot_impl`);
  - `:1352-1416` head import (`maybe_commit_transaction`; finish only when HEAD was deleted, `:1412`);
  - `:1428-1460` refs import;
  - `:2387-2401` identity;
  - `:2792-2795` finish skips all on `!has_changes()`;
  - `:3304-3309` skipped files.
- `git_util.rs:270-295` failed imports, `:468-506` export.

**zanshin-jj:**
- `src/repo.rs`:
  - `Repo::init` `:1851`, `Repo::clone` `:1911` (rollback `:1925-1929`), `clone_into` `:1937`;
  - import stats `:2030` (unwarned), `tx.commit("clone")` `:2067`, `workspace.check_out` `:2072` (stats discarded);
  - `Repo::precondition` `:212-281` shows the stats-warning placement.
- `src/convert.rs`:
  - `convert_colocated` `:130`, `convert_import` `:212`;
  - `init_git_refs` `:299` (drops import/export stats `:311`/`:317`), `maybe_snapshot` `:342` (throwaway report `:356`);
  - `external_arm` `:480` (throwaway sink + `log_dropped` `:483-485`), `import_head_into_destination` `:513` (already finishes into `sink`).
- `src/snapshot.rs`: `run` `:352` (`was_snapshot_taken` logic, lock + head load), `snapshot_impl` `:397`, `Precondition` `:56`.
- `src/warning.rs`:
  - `WarningKind` `:28`, `Warnings` `:121`;
  - builders `identity_missing` `:236`, `git_export_failed` `:273`, `git_import_failed` `:294`, `snapshot_stats` `:334`, `checkout_files_skipped` `:349`, `local` `:157`, `log_dropped` `:167`.
- `src/config_cmd.rs:168-181` `ConfigSetOutcome` is the shape precedent. `src/lib.rs:79` re-exports.
- `tests/api_stability.rs`: `convert_*` pins `:486-488`, warning block `:1078-1147`.
- Call sites to adapt (`.result`): ~160 across `tests/*.rs` (41 in `convert.rs`, 18 in `config_identity.rs`), `zanshin-ffi/tests/*`, and in-`src` uses (`remotes.rs`, `config.rs`, `config_cmd.rs`, `file.rs`, `mutate.rs`, `lib.rs` — check whether each is a doc or a test).
- Identity-unset idiom: `tests/config_identity.rs:30-50,:120` (`set_env`/`remove_var` guard).
- Reserved-ref idiom: 9.32's `snapshot_colocated.rs::the_pre_verb_refs_import_warns_about_a_ref_it_cannot_import`. `file://` sources: `tests/clone_config.rs:68`, `tests/repo.rs:225`.

**zanshin-ffi:**
- `src/repo.rs` externs: `zanshin_repo_open` `:539`, `_init` `:575`, `_clone` `:623`, `_convert` `:769`, `arm_session` `:451`.
- `src/envelope.rs`:
  - `warning_code` `:250-277`, `CallReport` `:294`, `FfiErrorObj{report}` `:329`/`with_report` `:338`;
  - `ok_repo_handle` `:528` (hardcodes both fields `None`; route it through `finish_envelope` `:691`), `err_with_report` `:759`;
  - inline tests `:856`, `:934-995`, and the 9.32 literal code table test.
- `tests/repo_ffi.rs`: clone `:268-330` (`file://` `:280`), convert `:586-650`. `tests/ffi_abi_doc_sync.rs` reads `# Errors` bullets only, so warnings go under `# Warnings`.
- `schemas/envelope.fbs:1407-1413` (precondition paragraph), `:667` (RepoHandle doc). `cargo make codegen` (`Makefile.toml:314-369`) regenerates 4 committed outputs.

**packages/zanshin_core:**
- `lib/src/worker/responses.dart:19` `HandleResult(handleId)`.
- `lib/src/worker/isolate.dart`:
  - class doc `:65-72` (exclusions);
  - `openRepo` `:356`, `initRepo` `:366`, `cloneRepo` `:378`, `_handleOrThrow` `:392`, `convert` `:685`;
  - worker dispatch `:1659-1669,:1778`, `_replyRepoOp` `:2275` (drops the envelope).
- `lib/src/worker/handle.dart:40` `final class RepoHandle` (a subtype is legal in the same library).
- `lib/src/ffi/warning.dart` `ZanshinWarning`/`ZanshinWarningCode`/`decodeEnvelopeWarningsInternal` `:181`; `lib/src/ffi/precondition.dart:117` `decodePreconditionInternal(p, {warnings})`.
- Tests: `test/worker/detect_test.dart:129-195` (convert via `git init`), `warnings_test.dart` (9.32 witnesses + code-pin test), `test/ffi/warning_test.dart`.

**Docs/bookkeeping:**
- `docs/rust-error-codes.md`: Warning Codes `:83` (table `:103-127`), out-of-scope `:132` (`:149` is the 9.33 line).
- `docs/ffi-abi.md`: `:86-90` Dart exclusion, `:109-111` precondition-absent list, symbol rows `:399-402`, convert contract `:525`.
- `_bmad-output/implementation-artifacts/`: `sprint-status.yaml:132`, `deferred-work.md:400,:410,:416-417`.

## Tasks & Acceptance

**Execution:**
- [x] `crates/zanshin-jj/src/warning.rs` -- add `WarningKind::CloneCleanupFailed` (rustdoc = CLI site) and a builder `clone_cleanup_failed(&Path, &io::Error) -> Warning`, with inline tests -- the new code's Rust half.
- [x] `crates/zanshin-jj/src/repo.rs` + `src/lib.rs` -- `pub struct CreationOutcome { result: Result<Repo, RepoError>, precondition: Option<Precondition>, warnings: Vec<Warning> }` (rustdoc: both arms), re-exported.
  - `Repo::init`/`Repo::clone` return it.
  - `clone_into` records into a sink: fetch import failed, then checkout skipped from the kept `CheckoutStats`, then identity after the commit.
  - Extract the `.jj/` rollback into a helper returning `Option<Warning>`, with an inline test: `.jj/` holding a file, chmod 0o555 → `Some`; restore permissions. Rollback scope unchanged.
  - Rationale: the Rust surface MCP inherits.
- [x] `crates/zanshin-jj/src/convert.rs` + `src/snapshot.rs` -- make the conversion report instead of drop.
  - `convert_colocated`/`convert_import` return `CreationOutcome`.
  - `external_arm` returns its sink and the snapshot report; the `log_dropped("convert")` call goes.
  - `init_git_refs` records import-failed / colocated export-failed.
  - `maybe_snapshot` keeps the `Precondition`, sets `was_snapshot_taken` like `snapshot::run` (extract the shared post-lock body from `run` rather than copy it), and adds `snapshot_stats` warnings on success.
  - Update the module doc and fn docs.
- [x] `crates/zanshin-jj/tests/**`, `crates/zanshin-ffi/tests/**`, in-`src` callers, `tests/api_stability.rs` -- a mechanical `.result` at every creation call site, plus pins for `CreationOutcome` fields, the four signatures and `CloneCleanupFailed` -- keeps the gate compiling.
- [x] `crates/zanshin-jj/tests/creation_warnings.rs` (NEW) -- one witness per I/O-matrix row except Open (FFI) and the clean-up row (inline). Assert exact ordered `(kind, message)` lists, the precondition fields and the absent identity where expected -- the Rust witnesses.
- [x] `schemas/envelope.fbs` + `cargo make codegen` -- rewrite the `Envelope` precondition paragraph: convert carries the conversion's snapshot report; open/init/clone do not. Also the RepoHandle doc at `:667`, if it lists creation symbols -- doc-only wire change.
- [x] `crates/zanshin-ffi/src/envelope.rs` + `src/repo.rs` -- the FFI half.
  - Add a `pub const` for `jj.clone_cleanup_failed`, its `warning_code` arm and a literal-table row.
  - `ok_repo_handle(handle, session_id, &CallReport)` goes through `finish_envelope`.
  - init/clone/convert stamp the outcome's report on the ok arm, the refusal arm and the `arm_session` failure arm. `open` passes `&CallReport::default()`.
  - Rustdoc `# Warnings` sections (never inside `# Errors`); inline tests for ok, error and absent.
- [x] `crates/zanshin-ffi/tests/repo_ffi.rs` -- real-envelope witnesses:
  - convert with a big new file: `precondition` + `jj.snapshot_files_refused` on the wire;
  - clone into a colliding target: `jj.checkout_files_skipped`;
  - init and open: both fields absent.
  - Rationale: the outermost Rust surface.
- [x] `packages/zanshin_core/lib/src/worker/{responses,isolate,handle}.dart` + `lib/src/ffi/warning.dart` -- the Dart bridge.
  - `HandleResult` carries the ok envelope bytes.
  - `_replyRepoOp` forwards them.
  - `initRepo`/`cloneRepo`/`convert` → `CreatedRepoHandle`, and the class doc's exclusions are rewritten.
  - `ZanshinWarningCode.cloneCleanupFailed` is added, together with its Dart pin.
- [x] `packages/zanshin_core/test/worker/creation_test.dart` (NEW), plus the decode tests -- real-cdylib witnesses (identity is pinned by the Makefile, so it gets no Dart witness):
  - convert of a `git init` repo with a new file > 1 MiB (default limit): `warnings` + `precondition.snapshotStats`;
  - `cloneRepo` from a `file://` source into a colliding target: `jj.checkout_files_skipped`;
  - `initRepo`: `[]` and `null`;
  - a synthetic decode test: absent → `[]`/`null`.
- [x] `docs/rust-error-codes.md`, `docs/ffi-abi.md` -- documentation.
  - A registry row for `jj.clone_cleanup_failed`.
  - "Emitted by" updated for identity/import/export/snapshot/checkout/immutable/jjconflict/HEAD/alias/diagnostic rows.
  - The `:149` line is replaced by § Inventory's out-of-scope entries.
  - The ffi-abi exclusion lines, the precondition list and the creation symbol contracts are updated.
- [x] `_bmad-output/implementation-artifacts/{deferred-work.md, sprint-status.yaml}`, `coverage-baseline.txt` -- bookkeeping.
  - A dated "Surfaced 2026-09-24 while implementing Story 9.33" section (§ Deferrals).
  - Mark the two 9.33-routed items (`:400`, `:410`) resolved.
  - `9-33-…` → `done` + summary, and bump `last_updated`.
  - Commit the auto-raised baseline.

**Acceptance Criteria:**
- **Warnings are exactly the Inventory's.** Given a creation call (Rust fn, extern or Dart method), when it answers ok or error, then its warnings are exactly § Inventory's for that flow, in the CLI's order, and convert's precondition is present iff its snapshot started.
- **No creation path drops warnings.** Given the repo, when searched, then no creation path drops warnings: `log_dropped` has no creation caller, and the four functions return `CreationOutcome`.
- **The new code is registered everywhere.** Given `jj.clone_cleanup_failed`, when the code tables are compared, then it exists in `WarningKind`, `envelope.rs`, the literal table, `api_stability`, `ZanshinWarningCode` + its pin, and the registry. Every § Inventory CLI site appears either as a registry row or as an out-of-scope entry.
- **Dart stays source-compatible.** Given existing Dart callers of `initRepo`/`cloneRepo`/`convert`, when the package is analysed, then they compile unchanged, and `openRepo` still returns a plain `RepoHandle`.
- **The gate passes.** Given the finished change, when `cargo make test` runs, then every step except the 3 pre-existing `test-flutter` splash-card failures is green, including clippy, the coverage ratchet and the extern guard.

## Spec Change Log

## Review Triage Log

- **2026-09-24 — twin check (implementation pass).** Installed `jj` is 0.45.1 (not the 0.44.0 pin); scratch dir with `JJ_CONFIG` an empty file, `XDG_CONFIG_HOME` in the scratchpad, `JJ_USER`/`JJ_EMAIL` unset, a `git init` source with one commit on `main`. `jj git clone --no-colocate file://<src> dst` prints `Name and email not configured. Until configured, your commits will be created with the empty identity, and can't be pushed to remotes.` THREE times (after `add git remote`, the fetch and the checkout) — Zanshin's message is byte-equal, its count is 1 (the expected § Inventory divergence, deferred to 9.20). `jj git init --git-repo=<src> dst2` prints it exactly ONCE, after the head-import checkout — equal to Zanshin. `jj git init --colocate` over a copy prints NO identity warning — equal. With an identity set: a 2 MiB untracked `big.bin` gives `Refused to snapshot some files:\n  big.bin: 2.0MiB (2097152 bytes); the maximum size allowed is 1.0MiB (1048576 bytes)` (byte-equal to `tests/creation_warnings.rs::REFUSED`, the FFI and the Dart witnesses), and `refs/remotes/git/stolen` gives `Failed to import some Git refs:\n  refs/remotes/git/stolen` TWICE (refs step, then the snapshot's refs import) — byte-equal and equal in count. The colliding-target clone cannot be twinned: the CLI refuses a non-empty destination (`Destination path exists and is not an empty directory`, Story 9.20's parity); Zanshin's `jj.checkout_files_skipped` text is `print_checkout_stats`' (`cu:3304-3309`), shared with 9.32's witnesses.

### 2026-09-24 — Review pass
- verdicts: 39 findings — high 2, medium 5, low 25, false 7, maybe-false 0
- findings:
  - `[high]` `[defer]` (Blind Hunter) `Repo::clone` into an existing jj workspace still deletes its `.jj/`, `roll_back_clone`'s rustdoc claims it removes only what `init_internal_git` wrote, and the new deferred-work entry duplicates Story 3.4a's unlinked. The data loss is pre-existing (identical before this story; `deferred-work.md:85`) and the intent's non-goal "no change to what the flows do" excludes the fix → stays deferred (frontmatter item 1). Its sub-claims are this story's and were patched: rustdoc now says the rollback removes a pre-existing `.jj/` too, and the 9.33 entry links the 3.4a one.
  - `[low]` `[patch]` (Blind Hunter) Dart never sees a refused creation's report (`jj.clone_cleanup_failed`, a failed conversion's partial precondition) and no doc says so. Group "Dart error arm": `cloneRepo` / `convert` / `CreatedRepoHandle` / `ZanshinWarningCode.cloneCleanupFailed` docs and `ffi-abi.md` now state the report reaches Dart on success only, until Story 9.35.
  - `[low]` `[patch]` (Blind Hunter) "On an error envelope it describes state the rollback removed" is wrong after a failed re-open (`convert_*_steps` has no rollback there) or a failed watcher arming (`.jj/` persists). Reworded in `CreationOutcome::precondition`, the `convert.rs` module doc, `zanshin_repo_convert`'s `# Warnings`, `schemas/envelope.fbs` (+ codegen) and `ffi-abi.md` (two places).
  - `[low]` `[defer]` (Blind Hunter) A wrong-typed snapshot knob fails the conversion with no precondition (`Knobs::read` runs before `maybe_snapshot`), while the CLI has already imported the HEAD and verbs report `Some(default)`. Pre-existing knob-read order → Story 9.34, whose scope should cover the conversion too (frontmatter + deferred-work).
  - `[low]` `[patch]` (Blind Hunter) The clone-collision witnesses and docs present `jj.checkout_files_skipped` on clone as CLI parity, though only the non-empty-target divergence (Story 9.20) reaches it. Notes added to both tests, the registry row, `zanshin_repo_clone`'s rustdoc and `cloneRepo`'s doc: reachable only through the divergence, flips to a refusal with 9.20.
  - `[medium]` `[patch]` (Blind Hunter) The documented multi-warning orders (clone: skip before identity; `convert_import`: refusal, skip, identity) were never asserted with more than one warning. Added `clone_warns_the_checkout_skip_before_the_identity` and `convert_import_warns_refusal_then_checkout_skip_then_identity` (empty-identity phase, exact ordered lists).
  - `[medium]` `[patch]` (Blind Hunter) The conversion's refs-step-before-config-load order is untested. Group "config-load witness" with the Verification Gap row: `a_bad_alias_entry_warns_between_the_two_imports` asserts `[GitImportFailed, ConfigAliasInvalid, GitImportFailed]`.
  - `[low]` `[patch]` (Blind Hunter) Registry rows name conversion emitters no test exercises. Added the two constructible ones: `convert_import`'s head-import `jj.checkout_files_skipped` (in the order row above) and `a_jjconflict_entry_is_reported_by_the_colocated_conversion`. `working_copy_immutable` / `git_export_failed` on a conversion stay witnessed through the shared machinery (9.32).
  - `[low]` `[reject]` (Blind Hunter) A failed conversion rollback (`let _ = remove_dir_all`) is silent. There is no CLI site (the CLI never rolls back `jj git init`), so a warning would be an invented code; rare, and pre-existing.
  - `[low]` `[defer]` (Blind Hunter) The barrel exports neither `CreatedRepoHandle` nor `Precondition`. `RepoHandle` and `Precondition` were already absent (pre-existing); inference still exposes the fields → frontmatter + deferred-work.
  - `[false]` `[reject]` (Blind Hunter) The spec is missing from the reviewed diff and could stay uncommitted. It is the claims file, excluded from the diff by the review protocol, and the finalize step commits it.
  - `[low]` `[defer]` (Blind Hunter) "`init` never warns" holds only for a target without `.git/`; Zanshin's init over `.git/` diverges from the CLI (External flow or refusal). Zanshin's init warns about nothing in every case, so the doc is true; the init-over-`.git` divergence is pre-existing → Story 9.20 (frontmatter + deferred-work).
  - `[low]` `[patch]` (Blind Hunter) The VM-reaping deferral names no concrete check. The deferred-work entry now names it: a `cloneRepo` and a `gitFetch` from the running macOS app, when Story 6.4a wires fetch.
  - `[false]` `[reject]` (Blind Hunter) The CLI clean-up line references differ (276-284 / 277-282 / 262-284). Verified at v0.44.0: `clean_up_dirs` spans 262-275 and its `if let Err` warning 276-283; every citation is a sub-range of that one site.
  - `[low]` `[patch]` (Blind Hunter) No FFI test reads a real creation error envelope. Group "failed-snapshot report" with the Verification Gap row: `repo_ffi.rs::convert_whose_snapshot_fails_reports_on_the_error_envelope` asserts `jj.convert_failed`, the refs-step warning and the partial precondition on the wire.
  - `[low]` `[reject]` (Blind Hunter) `decodeCreationReport` sits in `precondition.dart`. That file holds the envelope-level precondition decoders it composes; placement preference, no caller diverges.
  - `[low]` `[defer]` (Edge Case Hunter) A clone that fails after the CLI's `add git remote` finish lacks the identity warning that finish printed. Part of the op-split divergence (Zanshin commits no remote operation) → Story 9.20 (frontmatter + deferred-work).
  - `[false]` `[reject]` (Edge Case Hunter) An unknown untracked reason makes `decodeCreationReportInternal` throw and orphans the worker handle. Unreachable: the cdylib and the Dart decoder come from the same `envelope.fbs` in one build, and Rust emits only the schema's reasons.
  - `[high]` `[defer]` (Edge Case Hunter) The clone rollback deletes a pre-existing `.jj/`. Same data loss as the first Blind Hunter row: pre-existing, excluded by the intent's non-goal, already frontmatter item 1.
  - `[low]` `[reject]` (Edge Case Hunter) The inline rollback test fails when run as root (chmod does not block removal). This project's gate runs locally as the developer (no CI), and the fix adds a root guard branch.
  - `[low]` `[reject]` (Edge Case Hunter) The task claims a Dart colliding-clone witness that does not exist. It is infeasible: the Dart VM reaps the `git` child, recorded in the Auto Run Result and deferred-work. The FFI test covers the path, and the only fix is a spec edit.
  - `[low]` `[patch]` (Edge Case Hunter) The Dart error arm drops the report. Group "Dart error arm" (see above).
  - `[false]` `[reject]` (Edge Case Hunter) The identity is recorded after `workspace.check_out`, so a failed checkout loses it. The CLI's `finish_transaction` returns at `update_working_copy(…).await?` (cu:2369) BEFORE its identity check (cu:2387), so a failed checkout warns no identity in the CLI either; Zanshin's order is the finish's.
  - `[low]` `[defer]` (Edge Case Hunter) The precondition is absent where the CLI's snapshot had started (knobs read first). Same as the Blind Hunter knob row → Story 9.34.
  - `[low]` `[patch]` (Edge Case Hunter) `crates/zanshin-jj/README.md` still documents `-> Result<Repo, RepoError>`. Group "README": both signatures now `-> CreationOutcome`, with one sentence on the outcome.
  - `[medium]` `[patch]` (Verification Gap) The refs step's `jj.git_import_failed` before its early return was unwitnessed (both reserved-ref rows import `main`). Added `a_refs_step_that_imports_nothing_still_warns` (only ref `refs/remotes/git/stolen`, HEAD unborn) → `[STOLEN, STOLEN]`.
  - `[medium]` `[patch]` (Verification Gap) The conversion's config-load warnings and their place after the refs step were unwitnessed. Group "config-load witness" (see above).
  - `[low]` `[defer]` (Verification Gap) `jj.clone_cleanup_failed` through `Repo::clone` has no end-to-end witness. The only fault-free trigger is the data-loss path → with Story 9.20's rollback fix (frontmatter + deferred-work; filed disposition defer).
  - `[medium]` `[patch]` (Verification Gap) No test covered a partial report when the conversion's own snapshot fails. Group "failed-snapshot report": `a_snapshot_failure_keeps_a_partial_report` (a mode-0o000 new file) asserts `ConvertFailed`, `[STOLEN]`, `git_head_imported` and `was_snapshot_taken`, plus the FFI wire test.
  - `[low]` `[patch]` (Verification Gap, other) Stale README signatures. Group "README" (see above).
  - `[low]` `[reject]` (Intent Alignment) The headline (a clone with an empty identity) is never exercised end to end through Dart. Infeasible in the harness (`Makefile.toml` pins `JJ_USER`/`JJ_EMAIL`, and the VM reaps `git`), both documented; the Rust witness plus the real FFI envelope machinery cover the chain.
  - `[low]` `[reject]` (Intent Alignment) Scope (4) "clone with and without identity" is witnessed only in the Rust library. Same harness limits as above; the FFI wire path is witnessed by the colliding-clone test.
  - `[false]` `[reject]` (Intent Alignment) The motivation's "`jj git init` over an existing Git repo" identity case reaches no envelope. At v0.44.0 the identity finish runs only in the non-colocated `--git-repo` branch. `zanshin_repo_convert` is the colocated flow, which the CLI also runs without an identity warning (witnessed), and `convert_import` has no FFI symbol (pre-existing).
  - `[low]` `[defer]` (Intent Alignment) There is no witness for `init` over a directory holding `.git/`. Same as the Blind Hunter init row → Story 9.20.
  - `[low]` `[reject]` (Intent Alignment) Under reading R2a (the CLI's count), the test pins the divergence. The intent's rule ("only when a finish_transaction-equivalent committed an operation") selects per-operation, and the count gap is a recorded 9.20 deferral.
  - `[low]` `[patch]` (Intent Alignment) The broad additions barely reach Dart, and the motivation's facts lack creation-flow witnesses. Covered by groups "Dart error arm" (docs) and the conversion emitter witnesses (`.jjconflict`, head-import checkout skip).
  - `[low]` `[patch]` (Intent Alignment) FFI error arms are covered only synthetically. Group "failed-snapshot report" (real error envelope test).
  - `[false]` `[reject]` (Intent Alignment) The report lives in `CreatedRepoHandle.precondition`, not `lastPrecondition`. This is the intent's "return the handle together with warnings and report"; `lastPrecondition` is the last VERB's report and a creation is not a verb on the handle.
  - `[false]` `[reject]` (Intent Alignment) "No change to what the flows do" holds on disk; an absent `.jj/` is now explicitly success. Not a defect: the on-disk rollback is identical (a `NotFound` removal was already ignored).

### 2026-09-24 — Review pass (follow-up)
- verdicts: 27 findings — high 1, medium 3, low 18, false 5, maybe-false 0
- findings:
  - `[low]` `[patch]` (Blind Hunter) The init docs say the CLI's init reaches no `ui.warning_*`, but its default colocated arm runs `for_workable_repo` (`git/init.rs:241`), which loads the alias tables; clone's list reads as complete although that runs twice there. `zanshin_repo_init`'s `# Warnings` and `initRepo`'s doc now name the `--no-colocate` equivalence and the unported alias warnings; `Repo::clone`, `zanshin_repo_clone` and `cloneRepo` docs say the start-up-environment warnings are not ported (+ codegen).
  - `[false]` `[reject]` (Blind Hunter) A linked Git worktree takes the non-colocated shape, so `zanshin_repo_convert` could warn the head-import finish's codes. `wc_ops.rs::is_colocated_git_workspace` returns true when the git work dir IS the workspace root, which is the case for a linked worktree (its gitdir pointer resolves to that worktree), so it takes the colocated shape.
  - `[low]` `[patch]` (Blind Hunter) The convert module doc and `convert_import`'s rustdoc omit the head-import finish's `jj.working_copy_immutable`, which the registry lists. Both now list it before the checkout skip and the identity (the finish's order).
  - `[medium]` `[patch]` (Blind Hunter) No test covers the refs step's new `jj.git_export_failed` call site. Group "refs-step export witness" with the Verification Gap row.
  - `[low]` `[reject]` (Blind Hunter) Clone's `jj.git_import_failed` has no witness and no deferral. The trigger is unreachable on macOS: the fetch from `origin` writes only `refs/remotes/origin/*` (the reserved namespace is `refs/remotes/git/*`) and APFS refuses non-UTF-8 names; the builder is witnessed (9.32), and the emission is one line.
  - `[low]` `[defer]` (Blind Hunter) "Precondition present" differs between verbs and convert on a knob failure. carried — first pass's knob-order row (frontmatter item 4 → Story 9.34); the code reads as that row describes.
  - `[low]` `[patch]` (Blind Hunter) The 9.20/9.34 handovers were recorded only in deferred-work. The `9-20`, `9-34` and `9-35` entries in `sprint-status.yaml` now carry dated "HANDED OVER … by 9-33" notes (the `9-20` 9.27 precedent).
  - `[high]` `[defer]` (Blind Hunter) The clone-rollback data loss has no owner and no test, and the deferral should be reconsidered. carried — first pass's data-loss row (pre-existing since 3.4a, excluded by the intent's non-goal; frontmatter item 1). A fix chip ("Stop clone rollback deleting an existing .jj/") and the 9-20 handover now name the owner.
  - `[low]` `[patch]` (Blind Hunter) `ffi-abi.md`'s warnings paragraph lacks the Dart "success only" caveat the precondition paragraph got. Added: a refused creation throws without its warnings (e.g. `jj.clone_cleanup_failed`) until Story 9.35.
  - `[low]` `[patch]` (Blind Hunter) `HandleResult.bytes` is sent for `openRepo` too, and its doc speaks only of creations. The doc now says open ignores them (a ~100-byte envelope; no payload change).
  - `[low]` `[patch]` (Blind Hunter) The two RESOLVED deferred-work entries keep present-tense text without the file's resolved marker. Their titles are now struck through (`~~…~~`), the house convention for resolved entries.
  - `[false]` `[reject]` (Edge Case Hunter) `decodeCreationReportInternal` throws and orphans the handle. carried — first pass: unreachable (one schema, one build).
  - `[low]` `[reject]` (Edge Case Hunter) A `.jj/.gitignore` write failure plus a bad alias entry loses the alias warnings the CLI prints before that failure. Double fault; the order (`Knobs::read` after the gitignore) predates this story, and separating the alias load from the knob read is Story 9.34's move — more than a direct correction.
  - `[low]` `[defer]` (Edge Case Hunter) With `log_dropped("convert")` gone, a failed Dart creation's warnings show up nowhere. The Dart error path is Story 9.35's (intent's Never list) → frontmatter + deferred-work + `9-35` handover note.
  - `[low]` `[patch]` (Edge Case Hunter) The Dart error arm discards the report. carried — first pass's "Dart error arm" docs group; the code reads as documented.
  - `[medium]` `[patch]` (Verification Gap) The refs step's `jj.git_export_failed` is asserted by no test. Group "refs-step export witness": `creation_warnings.rs::a_refs_step_export_failure_warns_first` (user config `remotes.origin.auto-track-bookmarks = "glob:*"`, `refs/heads/foo` + `refs/remotes/origin/foo/bar`) asserts exactly `[GitExportFailed]` whose message starts "Failed to export some bookmarks:\n  foo/bar".
  - `[low]` `[patch]` (Verification Gap, other) `tests/convert.rs`'s comment says the auto-track map is hardcoded empty. Rewritten: the map is the effective config's; the branch is witnessed by the new row.
  - `[low]` `[reject]` (Intent Alignment) The empty-identity clone is witnessed in Rust only. carried — first pass: harness pins `JJ_USER`/`JJ_EMAIL`, and the VM reaps `git`.
  - `[low]` `[reject]` (Intent Alignment) The Dart colliding-clone witness became a refusal test. carried — first pass: infeasible in `dart test`.
  - `[low]` `[defer]` (Intent Alignment) The clean-up-failure row is witnessed only in pieces. carried — first pass: end-to-end witness with Story 9.20's rollback fix.
  - `[false]` `[reject]` (Intent Alignment) `convert_import`'s identity reaches no envelope. carried — first pass: no FFI symbol (pre-existing), and the colocated convert matches the CLI.
  - `[low]` `[reject]` (Intent Alignment) Init, identity-set clone, colocated identity and the import-shape big file are Rust-only or harness-pinned at the FFI/Dart surfaces. The FFI stamping is flow-independent and witnessed on the ok wire (big file, colliding clone) and a real error envelope; identity is pinned by the harness.
  - `[false]` `[reject]` (Intent Alignment) The reserved-ref-twice row appears only once on the FFI wire. The row describes the conversion's logic, witnessed at the Rust surface; the FFI error test deliberately fails the snapshot before its refs import, and the wire carries whatever list the outcome holds.
  - `[false]` `[reject]` (Intent Alignment) The late-failure row is staged in `creation_warnings.rs`, not `tests/convert_alias_write_failure.rs`. The matrix names that file as the trigger; `a_late_failure_keeps_the_report` uses the same `XDG_CONFIG_HOME` trigger.
  - `[low]` `[patch]` (Intent Alignment) The spec's AC includes the Dart error arm, which is not met. carried — first pass's "Dart error arm" docs group (by design, 9.35).
  - `[medium]` `[patch]` (Intent Alignment) Conversion emitters lack conversion witnesses. Group "refs-step export witness" for `jj.git_export_failed`; `working_copy_immutable` / `git_head_update_failed` are carried from the first pass (shared snapshot machinery).
  - `[low]` `[patch]` (Intent Alignment) The out-of-scope "`In remotes.<r>.*` / `In name pattern`" entry has no owner. Added: the next jj-lib pin bump re-checks it.

## Design Notes

**Inventory — in scope.** Every code except `jj.clone_cleanup_failed` is 9.32's; only the emitters are new.

| Flow | Code | CLI site | Zanshin emitter |
|---|---|---|---|
| clone | `jj.git_import_failed` | clone.rs:456 → git_util.rs:272 | `clone_into` after `import_refs` |
| clone | `jj.checkout_files_skipped` | checkout finish → cu:3304 | `clone_into` after `workspace.check_out` |
| clone | `jj.identity_missing` | finish cu:2387 | `clone_into` after `tx.commit("clone")`, once |
| clone (error) | `jj.clone_cleanup_failed` | clone.rs:277-282 | the rollback helper |
| convert | `jj.git_import_failed` | init.rs:304 | `init_git_refs` |
| convert (colocated) | `jj.git_export_failed` | init.rs:311-312 | `init_git_refs` |
| convert | `jj.config_alias_invalid` / `_redefined`, `jj.revset_diagnostic` | `for_workable_repo` (cu:936-966) | `Knobs::read` (already recorded) |
| convert | S2–S7 and identity inside `snapshot_impl` | cu:1331-1342 | `maybe_snapshot` (already recorded) |
| convert | `jj.snapshot_files_refused` / `_paths_not_utf8` | cu:1340 | `maybe_snapshot` on success (NEW) |
| convert (import) | finish codes | init.rs:268 | `import_head_into_destination` (already recorded) |

**Inventory — out of scope** (one registry entry each, replacing `:149`):
- **Start-up environment on clone/init** (`for_workable_repo`, twice on clone): alias-load and `immutable_heads()`/short-prefixes/template diagnostics, and clone's became-immutable check, which needs that parsed set. They come with the start-up-environment port that 9.32 deferred; for clone they are 9.20's parity.
- **Clone's identity count:** the CLI prints it once per finish (add remote always; fetch when something changed; checkout when there is a working branch), so up to 3 times. Zanshin writes one `clone` op, which gives 1. It converges when 9.20 splits the op.
- `No matching branches found on remote` — no `--branch` (9.20/9.30).
- `In remotes.<r>.*` / `In name pattern` diagnostics — unreachable at jj-lib 0.44.
- Colocated clone/init export and HEAD warnings — Zanshin's clone/init are never colocated (9.20).
- Secure-config migration messages — unreachable on a fresh `.jj` (9.37).
- `open` — not a CLI command; its start-up warnings belong to the same deferral.

**Why `CreationOutcome`, a signature change.** Warnings exist on the error arm (clone clean-up; everything recorded before a late failure). `Result<Warned<Repo>, _>` cannot carry them, and a parallel `*_reported` API would leave a warning-dropping entry point beside it, which is exactly what 9.32 removed. `ConfigSetOutcome` is the in-repo precedent. The churn (~160 `.result` insertions) is mechanical.

**Why a Dart subtype.** 9.32's `WarnedList<E>` precedent: stay source-compatible. `final class CreatedRepoHandle extends RepoHandle { final List<ZanshinWarning> warnings; final Precondition? precondition; }` changes no line in the ~151 existing `initRepo` fixture calls. The class doc distinguishes `precondition` (the creating call's) from `lastPrecondition` (the last verb's).

**Convert's error arm.** A failed conversion rolls `.jj/` back (Zanshin's documented departure), yet the error arm still carries the partial precondition and the warnings. That follows 9.26/9.32's "partial on failure" contract; the rustdoc says the report describes rolled-back state.

**Surfaced (record, do not fix — Never list).** `Repo::clone` into an EXISTING jj workspace: `init_internal_git` fails with `DestinationExists` (jj-lib `workspace.rs:121-129`), and the rollback then deletes the pre-existing `.jj/`. This is a data loss the CLI cannot cause (it refuses a non-empty destination first). It is high severity and belongs to 9.20 or an immediate fix story. Record it in the deferred-work section and the Auto Run Result.

**Deferrals** (frontmatter `deferred` + deferred-work): the clone rollback data loss (high); the clone/init start-up environment incl. became-immutable (9.20); the clone identity count (9.20 op split).

## Verification

**Commands.** Run everything in the foreground, with the environment set up as follows:
- Run each `[tasks.test]` dependency as `cargo make --allow-private <task>`, with `coverage` last.
- If a toolchain is missing, set `SDK_PATH`/`CARGO_HOME`/`RUSTUP_HOME`/`FLUTTER_ROOT` under `~/development/sdks`.
- Revert `pubspec.lock` drift after every Dart run.

The checks:
- `cargo make codegen` then `git status` -- expected: only the 4 generated outputs change (doc text).
- `cargo make --allow-private test-cargo`, `test-clippy`, `test-fmt`, `test-dart-analyze`, `test-dart-format`, `test-core`, `test-core-analyze`, `test-core-format`, the `test-shell*`/`test-settings*` steps, `test-cargo-deny`, `test-cargo-hygiene`, `test-jj-adapter-hygiene`, `coverage` -- expected: green; coverage ≥ baseline; extern guard OK.
- `cargo make --allow-private test-flutter` -- expected: only the 3 pre-existing `zanshin_bootstrap_test.dart` failures.
- `grep -rn "log_dropped" crates/zanshin-jj/src` -- expected: no creation-path caller.

**Manual checks:**
- Twin check with the installed `jj`, using a scratch `JJ_CONFIG`/`XDG_CONFIG_HOME` and an empty identity. Run `jj git clone file://<src> dst` and `jj git init --git-repo=<src> dst2`, then compare the stderr `Warning:` blocks with Zanshin's messages. The identity count on clone is expected to differ (§ Inventory). Record the result in the Review Triage Log.

## Auto Run Result

Status: done
Blocking condition: none

**Summary.** The four `zanshin-jj` creation functions (`Repo::init`, `Repo::clone`, `convert_colocated`, `convert_import`) return `CreationOutcome { result, precondition, warnings }` — `ConfigSetOutcome`'s shape, filled on success AND failure, re-exported.

- **Clone:** records the fetch's `jj.git_import_failed`. After its single `clone` commit it adds `jj.checkout_files_skipped` (from the now-kept `CheckoutStats`) and `jj.identity_missing` once. Its rollback moved into `roll_back_clone` with an unchanged scope (an absent `.jj/` is no failure), and a removal failure adds the NEW code `jj.clone_cleanup_failed` last.
- **Conversions:** report instead of dropping (`log_dropped("convert")` is gone).
  - `init_git_refs` records import-failed before its no-change return, and export-failed when colocated.
  - `Knobs::read` records its config-load warnings where the CLI's `for_workable_repo` prints them.
  - `maybe_snapshot` keeps its `Precondition` (`Some` iff started, partial on failure; `was_snapshot_taken` via `snapshot::snapshot_locked`, extracted from `snapshot::run`) and adds the snapshot stats on success.
  - The non-colocated head import finishes into the same collector.
- **Unchanged:** what the flows do.
- **FFI:**
  - `ok_repo_handle` goes through `finish_envelope`.
  - `creation_envelope` stamps the outcome on the ok, refusal and `arm_session`-failure arms; `open` passes an empty report.
  - The fbs change is doc-only (+ codegen).
- **Dart:**
  - `HandleResult` carries the ok envelope.
  - `initRepo`/`cloneRepo`/`convert` return `CreatedRepoHandle` (a `RepoHandle` subtype with `warnings` / `precondition`; `lastPrecondition` untouched); `openRepo` returns a plain `RepoHandle`.
  - `ZanshinWarningCode.cloneCleanupFailed`.
  - A refused creation's report reaches Dart only with Story 9.35.

**Files changed (grouped).**
- `crates/zanshin-jj/src/{warning,repo,convert,snapshot,lib}.rs` — new kind + builder, `CreationOutcome`, the clone/convert reporting, `snapshot_locked`, inline tests.
- `crates/zanshin-jj/README.md` — the conversion signatures.
- `.result` at every creation call site: `src/{config,config_cmd,file,mutate,lib}.rs` tests, about 150 sites across `crates/zanshin-jj/tests/*` and `crates/zanshin-ffi/tests/*`.
- `crates/zanshin-jj/tests/creation_warnings.rs` (new; 17 phases in one env-sequenced test) and `tests/api_stability.rs` — Rust witnesses and pins.
- `crates/zanshin-ffi/src/{envelope,repo}.rs`, `tests/repo_ffi.rs` — the code const, table row, `creation_envelope`, `# Warnings` rustdoc, and wire witnesses (ok and real error envelope).
- `schemas/envelope.fbs` + the four generated outputs (doc text only).
- `packages/zanshin_core/lib/src/{worker/responses,worker/isolate,worker/handle,ffi/warning,ffi/precondition}.dart`, `test/worker/creation_test.dart` (new), `test/ffi/warning_test.dart`.
- `docs/rust-error-codes.md`, `docs/ffi-abi.md`, `_bmad-output/implementation-artifacts/{deferred-work.md, sprint-status.yaml}`, `coverage-baseline.txt`.

**Deviation from the task list.** The Dart `cloneRepo` colliding-target witness cannot run: a clone's fetch runs a `git` subprocess whose `Child::wait()` fails inside any `dart test` process, because the Dart VM reaps its children. `mutate_test.dart` records the same for `gitFetch`. The witness lives in `crates/zanshin-ffi/tests/repo_ffi.rs`; the Dart test covers the refusal arm. Recorded in deferred-work, together with a concrete app-side check.

**Review findings.** 39 findings: high 2, medium 5, low 25, false 7, maybe-false 0.

Patched (10 entries):
- the multi-warning order witnesses (medium);
- the refs-step warning before the no-change return (medium);
- the alias warning between the two imports (medium);
- a failing conversion snapshot's partial report, in Rust and on the real FFI error envelope (medium);
- the conversion `.jjconflict` and head-import checkout-skip witnesses;
- the error-arm rollback wording (rustdoc, fbs + codegen, ffi-abi);
- the Dart "report on success only until 9.35" docs;
- the clone checkout-skip divergence notes;
- the README signatures;
- the VM-reaping check.

Also patched as the high row's sub-claims: `roll_back_clone`'s rustdoc and the link to Story 3.4a's entry.

Deferred:
- the clone-rollback data loss (high, pre-existing since 3.4a, intent non-goal) — already frontmatter item 1;
- the conversion knob read → 9.34;
- init over `.git/` → 9.20;
- the clone error arm lacking the add-remote identity warning → 9.20;
- the end-to-end `jj.clone_cleanup_failed` witness → with 9.20's rollback fix;
- the barrel exports (pre-existing).

Rejected, with reasons in the Review Triage Log:
- the silent convert rollback (no CLI site);
- the spec missing from the diff (false);
- the clean-up line citations (false);
- the decoder placement;
- an unreachable decode throw (false);
- the root-only test;
- the infeasible Dart clone witness;
- the identity after checkout (false: the CLI's finish order);
- the two Dart end-to-end identity limits;
- the colocated convert identity (false);
- the R2a count;
- `lastPrecondition` (false);
- the flow-unchanged observation (false).

**Follow-up review recommended: true.** This was the first pass, and 4 medium entries were patched (low 6). The named unverified risk: the patch pass's six new witnesses were written and run by the orchestrator but read by no reviewer. That covers the mode-0o000 snapshot failure, the unborn-HEAD refs step, and the alias-order and combined-order rows. The same is true of the reworded error-arm contract (rollback vs re-open vs arming) now in the fbs and generated headers.

**Verification.** After the patches:
- `cargo make codegen` changes only the generated docs and is idempotent.
- `cargo make --allow-private` PASS: test-cargo (76 suites), test-clippy, test-fmt (after `cargo fmt` of the new tests), test-dart-analyze, test-dart-format, test-core (464 tests), test-core-analyze/format, all `test-shell*` / `test-settings*` steps, test-cargo-deny, test-cargo-hygiene, test-jj-adapter-hygiene, coverage.
- test-flutter FAILS only on the 3 pre-existing `zanshin_bootstrap_test.dart` splash-card tests.
- Coverage 99.46% (13672/13746), ratchet OK (baseline `repo.rs` 97.63 from the implementation pass), extern-coverage OK.
- `grep -rn log_dropped crates/zanshin-jj/src` finds only `resolve_revset`.
- Twin check (installed jj 0.45.1) recorded in the Review Triage Log.
- Matrix audit: every I/O row has a passing witness. The clean-up row is covered by the rollback-helper test plus the FFI error-arm test; its end-to-end form is deferred.
- `pubspec.lock` drift reverted.

**Residual risks.**
- **HIGH, pre-existing, not fixed:** `Repo::clone` into an existing jj workspace deletes its `.jj/` (Story 3.4a / 9.20).
- A refused creation's report is invisible in Dart until 9.35.
- The Dart `cloneRepo` success path has no real-cdylib witness, and an app-process clone may hit the same `git` wait failure (unverified; check named for 6.4a).
- Clone warns the identity once where the CLI warns up to 3 times, and clone/init lack the CLI's start-up-environment warnings (9.20 / start-up port).

### Follow-up review pass (2026-09-24)

Status: done. Blocking condition: none. Every change since baseline `9c77e2ca` (commit `a46687af`) was reviewed with all four layers: blind, edge-case, verification-gap and intent-alignment. The intent-alignment layer got the spec's intent contract. Ten findings carried over from the first pass (same location and claim, code as described) and were not re-patched or re-deferred.

**Summary of the change.** The shipped behaviour has no defect. This pass witnessed the one new emission site nothing reached (the refs step's colocated `jj.git_export_failed`) and tightened docs and bookkeeping.

**Files changed.**
- `crates/zanshin-jj/tests/creation_warnings.rs`: new `a_refs_step_export_failure_warns_first`, using an auto-track glob and a `foo` / `foo/bar` Git ref conflict.
- `crates/zanshin-jj/tests/convert.rs`: the stale auto-track comment.
- `crates/zanshin-jj/src/{convert,repo}.rs`: the head-import finish now lists `jj.working_copy_immutable`; clone's start-up-environment note.
- `crates/zanshin-ffi/src/repo.rs` + codegen (`zanshin_ffi.h`, `bindings.dart`): init's `--no-colocate` equivalence and clone's start-up-environment note.
- `packages/zanshin_core/lib/src/worker/{isolate,responses}.dart`: the `initRepo` / `cloneRepo` docs, and `HandleResult.bytes` for open.
- `docs/ffi-abi.md`: the Dart success-only caveat on the warnings paragraph.
- `docs/rust-error-codes.md`: an owner for the diagnostics entry.
- `_bmad-output/implementation-artifacts/deferred-work.md`: struck-through RESOLVED titles, plus the 9.35 visibility deferral.
- `_bmad-output/implementation-artifacts/sprint-status.yaml`: handover notes on `9-20`, `9-34` and `9-35`.

**Review findings.** 27 findings (high 1, medium 3, low 18, false 5, maybe-false 0).
- **Patched:**
  - medium 1: the refs-step export witness, one group of three members.
  - low 9: init/clone start-up-environment docs, the head-import warning list, the sprint-status handovers, the ffi-abi caveat, the `HandleResult` doc, the RESOLVED markers, the stale test comment, and the owner of the out-of-scope entry.
- **Deferred (new):** a failed creation's warnings are invisible on the Dart side until Story 9.35.
- **Rejected** (reasons in the Review Triage Log): the linked-worktree shape (false), clone's unreachable import-failure witness, the gitignore + alias double fault, the Rust-only surfaces pinned by the harness, the reserved-ref FFI count (false), and the late-failure test location (false). The rest are carried rejections.

**Follow-up review recommended: false.** This follow-up pass patched no `high` (medium 1, low 9), so the work has converged.

**Verification.**
- `cargo make codegen` changes only the generated docs and is idempotent.
- `cargo make --allow-private` PASS: test-cargo (76 suites), test-clippy, test-fmt, test-dart-analyze, test-dart-format, test-core (464 tests), test-core-analyze/format, all `test-shell*` / `test-settings*` steps, test-cargo-deny, test-cargo-hygiene, test-jj-adapter-hygiene and coverage.
- test-flutter FAILS only on the 3 pre-existing `zanshin_bootstrap_test.dart` splash-card tests.
- Coverage is 99.46% (13672/13746) with no baseline change; extern-coverage is OK.
- `log_dropped` has no creation caller.
- `pubspec.lock` drift was reverted.

**Residual risks.** Unchanged from the first pass: the HIGH clone-rollback data loss (fix chip + 9.20 handover), the Dart error path (9.35), no Dart successful-clone witness, clone's identity count and start-up environment (9.20).

**Post-story resolution (2026-09-24).** The HIGH clone-rollback data loss (frontmatter `deferred` item 1) is fixed by `spec-clone-rollback-keeps-existing-jj.md`. The rollback now runs only for a `.jj/` the clone created, witnessed by `tests/repo.rs::a_clone_into_an_existing_jj_workspace_fails_and_keeps_it`.
