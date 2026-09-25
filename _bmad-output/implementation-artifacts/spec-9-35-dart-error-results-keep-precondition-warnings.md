---
title: 'Story 9.35: Dart keeps `precondition` and `warnings` on error results — handle-less commands included'
type: 'feature'
created: '2026-09-25'
status: 'done'
baseline_revision: 'd90827de48c172d96787594afcceb53380720917'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The `zanshin_core` barrel exports neither `ZanshinFfiException` nor `Precondition`, so the app cannot name the carrier of the error report without a `src/` import.
    evidence: |-
      `packages/zanshin_core/lib/zanshin_core.dart` exports `ZanshinWorker`, `ZanshinWarning` and the config result types,
      but not `worker/responses.dart::ZanshinFfiException` nor `ffi/precondition.dart::Precondition`. Pre-existing: the
      Story 9.33 barrel deferral (`deferred-work.md`, "exports neither `RepoHandle`, `CreatedRepoHandle` nor
      `Precondition`") never named the exception. The app does not catch `ZanshinFfiException` today (no reference in
      `app/`), so nothing breaks until the UI first reads the report.
    location: >-
      packages/zanshin_core/lib/zanshin_core.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** Rust stamps `Envelope.precondition` (Story 9.26) and `Envelope.warnings` (Story 9.32) on ERROR envelopes too — a verb whose pre-verb snapshot ran (and maybe wrote operations) and then refused, a `config_set` of `user.name` whose identity check snapshotted and then hit `jj.config_would_overwrite`, a failed `clone`/`convert` with its warnings and partial snapshot report. Every Dart decoder turns an error envelope into `ZanshinFfiException(code, context)` and drops both, so the UI loses the report exactly when something went wrong. `RepoHandle.lastPrecondition` catches only a handle-scoped error's precondition, never its warnings, and nothing at all for handle-less commands (`config_*`) and the creation verbs (`jj.clone_cleanup_failed` is error-only and so never reaches Dart).

**Approach:** `ZanshinFfiException` gains the envelope's `precondition` and `warnings`, filled by ONE shared helper that every `!env.ok` branch in `packages/zanshin_core` uses. Handle-scoped, handle-less and creation commands therefore expose the error report the same way — on the exception. Bridge-only: no Rust, schema or codegen change.

## Boundaries & Constraints

**Always:**
- **Exception shape.** `ZanshinFfiException` keeps `code` and `context` and adds:
  - `Precondition? precondition` — the envelope's (possibly PARTIAL) pre-verb snapshot report, `null` when the envelope has none (null for absence);
  - `List<ZanshinWarning> warnings` — the envelope's warnings in wire order (the CLI's print order), unmodifiable, `const []` when none.
- The existing `const ZanshinFfiException(code, [context])` constructor stays source-compatible and yields `precondition == null`, `warnings` empty. Every synthesized `ffi.unknown` throw (payload-type mismatch, missing nested table, corrupt buffer) keeps using it — those are not error envelopes.
- **One helper.** A single function decodes an error envelope into the exception (code/context from `FfiError`, `'ffi.unknown'` when `error` is absent, precondition via `decodePreconditionInternal`, warnings via `decodeEnvelopeWarningsInternal`). Every `!env.ok` branch in `packages/zanshin_core/lib` throws its result; no other site builds a `ZanshinFfiException` from an `FfiError`.
- The exception's `precondition` carries NO warnings (its `warnings` field stays empty) — they live on the exception, as the `lastPrecondition` report has none.
- `RepoHandle.lastPrecondition` / `ZanshinWorker.send`'s recording are unchanged: after a failed handle-scoped call, `lastPrecondition` and the exception's `precondition` describe the same report.
- Creation verbs (`initRepo`, `cloneRepo`, `convert`) throw the same enriched exception (via `_createdOrThrow` / `_handleOrThrow` → `_envelopeToException`); `openRepo` stays as is (Rust stamps no report on it, so it arrives empty).
- Docs stay true: every "until Story 9.35" / "success only" caveat in `docs/ffi-abi.md` and the Dart doc comments is rewritten to the new contract.

**Never:**
- No Rust, `.fbs`, generated-code or error/warning-code change. If an error path turns out NOT to stamp the envelope, record it as a deferral — do not widen scope.
- No new exception type or sealed hierarchy; no change to `toString()`, to the success result types, or to the barrel `lib/zanshin_core.dart` (its missing exports are a known 9.33 deferral).
- No UI (`app/`) change.
- Never lower `coverage-baseline.txt` or add an `exclude_prefix`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Handle-scoped refusal after the precondition | Git-backend workspace whose repo config holds `[revset-aliases]\n'bad(' = 'x'\n`; `handle.describe(changeId: 'z' * 32 /* root */, description: 'x')` | Exception: `warnings` exactly one `jj.config_alias_invalid` (message starts ``Failed to load `revset-aliases.bad(`: ``); `precondition` non-null; `handle.lastPrecondition` non-null with the same `wasSnapshotTaken` | `ZanshinFfiException('jj.invalid_input', …)` |
| Handle-less identity write over a table | repo config file `[user.name]\nx = 1\n` (written via `configFileRead`/`configFileWrite`); `worker.configSet(ConfigScope.repo, 'user.name', 'x', workspaceRoot: root)` | Exception: `precondition` non-null; `warnings` exactly one `jj.config_working_copy_author` (message starts `This setting will only impact future commits.`) | `ZanshinFfiException('jj.config_would_overwrite', …)` |
| Failed creation | `git init` repo with one commit; `git update-ref refs/remotes/git/stolen HEAD`; a new file `locked.txt` mode `0o000`; `worker.convert(root)` (restore `0o644` in `finally`) | Exception: `warnings == [ZanshinWarning(jj.git_import_failed, 'Failed to import some Git refs:\n  refs/remotes/git/stolen')]`; `precondition!.gitHeadImported` true; `.jj/` absent | `ZanshinFfiException('jj.convert_failed', …)` |
| Error without a report | `worker.openRepo(<existing empty dir>)` | Exception: `precondition == null`, `warnings` empty | `ZanshinFfiException('jj.repo_not_found', …)` |
| Synthetic decode, report present | `ok: false` envelope with `FfiError{code, context}`, a `Precondition`, two warnings — fed to EVERY top-level decoder | Each throws the exception with that code, context, both warnings in order, and the precondition's fields | — |
| Synthetic decode, report absent | same without `precondition`/`warnings`; also no `error` table | `precondition == null`, `warnings` empty; missing `error` → code `ffi.unknown`, context `null` | — |

</intent-contract>

## Code Map

**The exception and the helper:**
- `packages/zanshin_core/lib/src/worker/responses.dart:44-68` -- `ZanshinFfiException` (`const` ctor `(this.code, [this.context])`, `toString`). Dart cannot mix optional positional and named params, so the report comes in through a second (named) constructor, e.g. `ZanshinFfiException.withReport(code, context, {precondition, warnings})`; the default ctor initializes `precondition = null, warnings = const []`. Importing `../ffi/precondition.dart` / `../ffi/warning.dart` for the field types is fine (precondition.dart already imports responses.dart; Dart allows the cycle).
- `packages/zanshin_core/lib/src/ffi/precondition.dart` -- home of the helper, next to `decodeCreationReportInternal` (`:157-160`, already decodes warnings + precondition from one `fbs.Envelope`). Reuse `decodePreconditionInternal` (`:116-132`, `warnings` param defaults to `[]` — leave it defaulted) and `warning.dart::decodeEnvelopeWarningsInternal` (`:187-193`).

**Every `!env.ok` branch to route through the helper (current shape `throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context)`):**
- `lib/src/ffi/`: `file_ops.dart:228`, `change.dart:148`, `status.dart:96`, `mutate.dart:300` and `:326`, `bookmarks.dart:83`, `repo_detect.dart:67`, `graph.dart:374`, `file.dart:409`, `git.dart:331`, `log_defaults.dart:78`, `config.dart:470` (`_okEnvelope`, shared by all nine config decoders), `commit_views.dart:378`, `diagnostics.dart:66`, `remotes.dart:67`, `op_log.dart:83`, `workspace.dart:156`, `precondition.dart:173` (`decodeSnapshotEnvelopeInternal`).
- `lib/src/worker/isolate.dart:549-555` (`closeRepo`'s inline check) and `:2349-2353` (`_envelopeToException`, used by `_handleOrThrow` `:409-412` and `_createdOrThrow` `:416-425`).
- Leave alone: the `ffi.unknown` synthesized throws (e.g. `file_ops.dart:188/212/247`, `events.dart:94`, `workspace.dart:148`, `precondition.dart:180`, `bookmarks.dart:108`).

**Read-only evidence (Rust already stamps the error arm):**
- `crates/zanshin-ffi/src/envelope.rs:293-322` `CallReport`; `:749-775` `err_with_report` writes `precondition` + `warnings` on the error envelope; `crates/zanshin-ffi/src/repo.rs:517` `creation_envelope`.
- Error-arm stamping per family: handle-scoped verbs via `envelope.rs:377-388` `precondition_envelope` (and `snapshot.rs:112-122`); handle-less: only `config_set` (`config.rs:593-600`) stamps a report on its error arm — the other `config_*` symbols have none there by type; creations via `repo.rs:517-526`. None on open/close/detect/log_defaults/workspace_root/diagnostics.
- Recipes the Dart witnesses mirror: `crates/zanshin-ffi/tests/snapshot_ffi.rs:760-810` (`a_precondition_warning_crosses_on_the_ok_and_the_error_arm`: bad alias entry + `describe` of the root change → `jj.invalid_input` with precondition + `jj.config_alias_invalid`); `crates/zanshin-ffi/tests/config_ffi.rs:558-590` (identity set over a `[user.name]` table → error + precondition + `jj.config_working_copy_author`); `crates/zanshin-ffi/tests/repo_ffi.rs:774-808` (`convert_whose_snapshot_fails_reports_on_the_error_envelope`).
- `isolate.dart:428-463` `send` / `_recordPrecondition` already record a handle-scoped reply's precondition on BOTH arms — unchanged (witnessed by `test/worker/snapshot_test.dart:86`).
- Known Rust gap, out of scope: `envelope.rs:805-812` `catch`'s panic arm builds `internal.panic` with no report, so a verb that panics after its precondition loses it.

**Test idioms to reuse:**
- `packages/zanshin_core/test/worker/warnings_test.dart:37-51` `_gitWithCommit`, `:63-65` XDG pin guard, `:67-90` setUp/tearDown + `initGit` / `initWithRepoConfig` (repo-scope config via `configFileRead`/`configFileWrite`, then `openRepo`), `:361-381` the `refs/remotes/git/stolen` idiom.
- `packages/zanshin_core/test/ffi/snapshot_test.dart:36` `fullPrecondition()`, `:66` `expectFullPreconditionDecoded`, `:147-179` error envelopes built with `fbs.EnvelopeObjectBuilder(ok: false, error: fbs.FfiErrorObjectBuilder(code:, context:), precondition: …)` — the builder also takes `warnings:`.
- `packages/zanshin_core/test/ffi/warning_test.dart:45-57` `_expected` / `_wire()` / `_ok`, `:59-267` the `_cases` table (one entry per top-level decoder with a `read` callback), `:338-384` the "every top-level decoder carries the envelope warnings" group — the error-arm group goes beside it and drives the same `read` callbacks. `decodeSnapshotEnvelope` and `diagnostics.dart::decodeDiagnosticsEnvelope` (`:64`) are not in `_cases`; cover them explicitly.
- `packages/zanshin_core/test/worker/zanshin_worker_test.dart:98-107` openRepo on an existing non-repo dir → `jj.repo_not_found`.

**Docs to update (drop the "until Story 9.35" / success-only caveats):**
- `docs/ffi-abi.md:90-96` (creations' warnings "on success only"), `:120-127` (convert's report "only on success"), `:1048` and `:1178` (decode contract `!ok → ZanshinFfiException(code, context)` → also names the report).
- `lib/src/worker/isolate.dart:384-395` (`cloneRepo`), `:718-721` (`convert`) — `initRepo`'s doc (`:365-370`) has no such caveat; `lib/src/worker/handle.dart:57-66` (`lastPrecondition` — may point at the exception's report) and `:987-988` (`CreatedRepoHandle`); `lib/src/ffi/warning.dart:112-114` (`cloneCleanupFailed`); `lib/src/worker/responses.dart:44-49` (class doc: what the exception now carries).

**Bookkeeping:**
- `_bmad-output/implementation-artifacts/deferred-work.md:379` (config_set precondition dropped on the Dart error path) and `:453` (a failed creation's warnings visible nowhere) → struck through, "RESOLVED 2026-09-25 (Story 9.35)".
- `_bmad-output/implementation-artifacts/deferred-work.md`: a new dated "Surfaced 2026-09-25 while implementing Story 9.35" section recording the panic-arm gap above (severity low).
- `_bmad-output/implementation-artifacts/sprint-status.yaml:134` → `done` with a summary; `last_updated` (`:31`) → `2026-09-25`.

## Tasks & Acceptance

**Execution:**
- [x] `packages/zanshin_core/lib/src/worker/responses.dart` -- add `precondition` + `warnings` fields and the report-carrying named constructor; update the class doc -- the one error type every command throws now carries the report.
- [x] `packages/zanshin_core/lib/src/ffi/precondition.dart` -- add the shared helper (e.g. `ZanshinFfiException decodeEnvelopeErrorInternal(fbs.Envelope env)`), and use it in `decodeSnapshotEnvelopeInternal` -- one decoding point, as `decodeEnvelopeWarningsInternal` is for warnings.
- [x] `packages/zanshin_core/lib/src/ffi/{file_ops,change,status,mutate,bookmarks,repo_detect,graph,file,git,log_defaults,config,commit_views,diagnostics,remotes,op_log,workspace}.dart` -- replace each `!env.ok` throw with the helper -- "every decoder passes them".
- [x] `packages/zanshin_core/lib/src/worker/isolate.dart` -- `_envelopeToException` and `closeRepo`'s check use the helper; rewrite the `cloneRepo`/`convert` doc caveats -- creation and lifecycle errors carry the report too.
- [x] `packages/zanshin_core/lib/src/worker/handle.dart`, `packages/zanshin_core/lib/src/ffi/warning.dart` -- doc updates listed in the Code Map -- keep the docs true.
- [x] `packages/zanshin_core/test/ffi/warning_test.dart` -- new group: every `_cases` decoder plus `decodeSnapshotEnvelope` and `decodeDiagnosticsEnvelope` throws the enriched exception for an error envelope WITH a report (code, context, `_expected` warnings, precondition fields) and an empty report WITHOUT one; one case with no `error` table → `ffi.unknown` -- the matrix's synthetic rows.
- [x] `packages/zanshin_core/test/worker/error_reports_test.dart` (new) -- real-cdylib witnesses, one per command family (handle-scoped, handle-less config, creation) plus the no-report `openRepo` row, with the XDG guard and the recipes in the matrix -- the story's "real-cdylib witness per command family".
- [x] `docs/ffi-abi.md` -- rewrite the lines listed in the Code Map -- the envelope contract doc states the Dart error arm.
- [x] `_bmad-output/implementation-artifacts/{deferred-work.md,sprint-status.yaml}`, `coverage-baseline.txt` -- bookkeeping per the Code Map (two items RESOLVED, the panic-arm deferral, 9-35 `done`); commit an auto-raised baseline if the gate raises it.

**Acceptance Criteria:**
- Given the finished change, when the hand-written files under `packages/zanshin_core/lib` (not `*_generated.dart` / `bindings.dart`) are searched for `ZanshinFfiException(e?.code`, `ZanshinFfiException(err?.code` and `FfiError`, then the only construction of an exception from an `FfiError` is inside the shared helper.
- Given the repo after the change, when `docs/`, `packages/zanshin_core/lib` and `crates/` are searched for `9.35`, then no "until Story 9.35" caveat remains.
- Given the finished change, when `cargo make test` runs, then every step except the 3 pre-existing `test-flutter` splash-card failures is green, including `test-core`, `test-core-analyze`, `test-core-format`, clippy and the coverage ratchet (extern guard OK).

## Spec Change Log

## Review Triage Log

### 2026-09-25 — Review pass
- verdicts: 25 findings — high 0, medium 0, low 18, false 7, maybe-false 0
- findings:
  - `[low]` `[defer]` (blind) The barrel `lib/zanshin_core.dart` exports neither `ZanshinFfiException` nor `Precondition`, so the app cannot name the carrier of the new report without a `src/` import — pre-existing (the 9.33 barrel deferral covers `RepoHandle`/`CreatedRepoHandle`/`Precondition`; `ZanshinFfiException` was never exported); the intent is "no UI" and the spec kept the barrel untouched → deferred, mirrored in `deferred-work.md`.
  - `[low]` `[patch]` (blind) `handle.dart`'s `lastPrecondition` doc and `docs/ffi-abi.md` say the exception's `precondition` and `lastPrecondition` are always the same report — false when the error envelope has none (`logDefaults`/`workspaceRoot` errors, worker-built `ffi.invalid_handle`): `_recordPrecondition` keeps the previous report while `e.precondition` is `null`. Patched: both reworded to "when the error envelope carries one".
  - `[low]` `[patch]` (blind) The handle-scoped witness compares only `wasSnapshotTaken`, `false` on both sides in a clean fresh workspace, so a stale report would pass; the sprint-status summary overclaims "precondition == lastPrecondition's". Patched: a new file is written before `describe`, `wasSnapshotTaken` asserted TRUE on both; sprint-status wording matches the assertion.
  - `[low]` `[patch]` (blind) The synthetic error matrix toggles precondition and warnings together, so a helper that dropped one when the other is absent would pass (a clone refusal carries warnings only). Patched: warnings-only and precondition-only rows.
  - `[false]` `[reject]` (blind) No Dart witness checks that an error report is PARTIAL (later fields at defaults) — partialness is set by Rust (witnessed in `repo_ffi.rs` / `snapshot_ffi.rs`); Dart decodes every field as sent, pinned by the synthetic full-precondition decode tests. No Dart-side bad outcome.
  - `[low]` `[patch]` (blind) A failed `snapshot()` carries its warnings on `e.warnings` while `e.precondition.warnings` is always empty, but `Precondition.warnings`' doc names only `lastPrecondition` as the always-empty case and `RepoHandle.snapshot`'s doc says nothing. Patched: both docs.
  - `[low]` `[reject]` (blind) `toString()` is unchanged, so `'$e'` in a log loses the report — the intent is that the error RESULT carries the report, which it does; the spec deliberately kept `toString`; the app does not reference `ZanshinFfiException` today; changing the log format is a UI-side choice.
  - `[low]` `[patch]` (blind) The new panic-arm deferral calls it "the one error arm that still arrives empty", but the worker's own `internal.dispatch_error` and `ffi.invalid_handle` envelopes carry no report either (the claimed raw-handle leak is false: `_replyRepoOp` casts only after checking `dataType == RepoHandle`). Patched: the entry names the one RUST arm plus the two worker-built envelopes.
  - `[low]` `[reject]` (blind) The identity-set witness relies on the pinned `JJ_USER` but the guard checks only `XDG_CONFIG_HOME`; `chmod 000` is ineffective as root — the same guard idiom is accepted in `warnings_test.dart`/`config_test.dart`/`creation_test.dart`, the suite runs via `cargo make` which pins all of them, tests never run as root; the fix adds guards.
  - `[low]` `[patch]` (blind) New import cycles and a stale `precondition.dart` header — the cycles are harmless (Dart resolves library cycles, no top-level side effects; analyze + tests green), the header is stale. Patched: one header sentence names `decodeEnvelopeErrorInternal`.
  - `[low]` `[patch]` (blind) `withReport` stores any list although the `warnings` doc promises "unmodifiable"; the positional ctor doc calls Dart-synthesized failures non-envelopes although the worker-built envelopes decode through `withReport`. Patched: docs made accurate (decoded list unmodifiable; positional ctor = failures Dart detects in a buffer).
  - `[false]` `[reject]` (edge) A corrupt nested table in the error envelope's precondition (an `UntrackedPath` without `reason`) turns the real code into `ffi.unknown` — Rust always writes `reason` (unreachable), and loud failure on a corrupt buffer is the documented stance on the ok arm too.
  - `[false]` `[reject]` (edge) `_envelopeToException` on an ok open/creation envelope without a `RepoHandle` payload yields `ffi.unknown` carrying a success report — unreachable: Rust's ok creation/open envelope always carries `RepoHandle` (`ok_repo_handle`), and `_replyRepoOp` routes exactly that case to `HandleResult`.
  - `[low]` `[patch]` (edge) `handle.dart:64-68` says the two reports match although a report-less failure leaves the previous `lastPrecondition` — same root cause as the blind lastPrecondition finding; patched there.
  - `[low]` `[reject]` (edge) Docs call them "the same report" but they are separate decodes and `Precondition` has no `==` — "same report" states content, not identity; nobody compares report objects today; value equality would add public surface across the nested payload types.
  - `[low]` `[patch]` (edge) `withReport` is public and `const` and accepts a growable list — same root cause as the blind `withReport` finding; patched there.
  - `[low]` `[patch]` (verification-gap, other) `docs/ffi-abi.md` says after a failed handle-scoped call `lastPrecondition` holds the same report — false when the envelope has none — same root cause as the blind lastPrecondition finding; patched there.
  - `[false]` `[reject]` (intent) Reading "precondition-warnings" as snapshot warnings kept on the `Precondition` object — the story text (epics.md 9.35) asks for "the envelope's `precondition` and `warnings`", i.e. both, on the error result; the flat list is the envelope's own shape.
  - `[false]` `[reject]` (intent) The diff extends `ZanshinFfiException` instead of a successor type — the story allows "`ZanshinFfiException` or its successor".
  - `[false]` `[reject]` (intent) The `send` choke point is not changed, so handle-less commands record nothing persistent — the story's scope is that the error RESULT carries the report and handle-less commands "expose them the same way", which the exception does for every command.
  - `[low]` `[reject]` (intent) Logging (`toString`) still shows neither warnings nor precondition — same root cause as the blind `toString` finding; rejected there.
  - `[low]` `[reject]` (intent) The Rust panic arm (`envelope.rs::catch`) builds `internal.panic` with no report although the story says "bridge-only unless an error path turns out not to stamp the envelope" — real but reachable only through a panic, which the project rules forbid on FFI paths (the `catch` is a never-reached backstop), and the fix means carrying a partial `CallReport` across `catch_unwind`; left recorded in `deferred-work.md` ("Surfaced 2026-09-25 while implementing Story 9.35"). The other empty cases it lists (`config_list`/`config_gc_delete` error arms, worker-built envelopes) carry no report by construction.
  - `[false]` `[reject]` (intent) "Witness per command family" read as per module (clone, init, snapshot, git, …) — the story's scope sentence groups commands as handle-scoped / handle-less (`config_*`) / creation, each witnessed on the real cdylib; every decoder is covered by the synthetic group; `jj.clone_cleanup_failed` end-to-end is the known 9.20 deferral (no fault seam).
  - `[low]` `[patch]` (intent) Assertions thinner than the docs (`wasSnapshotTaken` only) — same root cause as the blind handle-scoped-witness finding; patched there.
  - `[low]` `[defer]` (intent) The public entry point cannot name the carrier — same root cause as the blind barrel finding; deferred there.

## Design Notes

**Why extend `ZanshinFfiException` instead of a successor type.** Every command already documents and tests `throws [ZanshinFfiException]` (≈40 test files match on it); a subtype or a result-union would touch all of them for no gain. Adding fields keeps every `isA<ZanshinFfiException>().having((e) => e.code, …)` matcher valid, and a caller that wants the report reads two more fields. The positional constructor cannot also take named params in Dart, hence the second constructor.

**Why warnings are not copied into `precondition.warnings`.** `Precondition.warnings` is documented as the SNAPSHOT verb's result warnings and "always empty on the report `RepoHandle.lastPrecondition` holds". The exception's precondition is the same report as `lastPrecondition`; duplicating the list would make two places to read one fact.

Golden shape:
```dart
ZanshinFfiException decodeEnvelopeErrorInternal(fbs.Envelope env) {
  final fbs.FfiError? e = env.error;
  return ZanshinFfiException.withReport(e?.code ?? 'ffi.unknown', e?.context,
      precondition: decodePreconditionInternal(env.precondition),
      warnings: decodeEnvelopeWarningsInternal(env));
}
// at each site:  if (!env.ok) throw decodeEnvelopeErrorInternal(env);
```

## Verification

**Commands** (foreground; if a toolchain is missing, put `~/development/sdks` on `PATH`; revert `pubspec.lock` drift after Dart runs):
- `cargo make --allow-private test-core` -- expected: green, including `test/ffi/warning_test.dart` and `test/worker/error_reports_test.dart`.
- `cargo make --allow-private test-core-analyze` and `test-core-format` -- expected: no issues.
- `cargo make test` -- expected: green except the 3 pre-existing `zanshin_bootstrap_test.dart` splash-card failures in `test-flutter`; coverage ≥ baseline.
- `grep -rn "9\.35" docs packages/zanshin_core/lib crates` -- expected: no "until Story 9.35" caveat.

## Auto Run Result

Status: done

**Summary.** A failed command's `ZanshinFfiException` now carries the error envelope's report: `precondition` (the PARTIAL pre-verb snapshot report, `null` when the envelope has none) and `warnings` (wire order, empty when none). One shared helper, `precondition.dart::decodeEnvelopeErrorInternal`, is thrown by every `!env.ok` branch in `packages/zanshin_core/lib` — the 16 decoders (config's shared `_okEnvelope` covers all nine config decoders), `decodeSnapshotEnvelopeInternal`, and `isolate.dart`'s `closeRepo` check and `_envelopeToException` (open/init/clone/convert). Handle-scoped, handle-less (`config_*`) and creation commands therefore expose the error report the same way. The positional `ZanshinFfiException(code, [context])` constructor stays source-compatible (no report) for failures Dart detects in a buffer; `toString()` and `lastPrecondition` recording are unchanged. Bridge-only: no Rust, schema, codegen or error-code change.

**Files changed.**
- `packages/zanshin_core/lib/src/worker/responses.dart` — `ZanshinFfiException.precondition` / `.warnings`, named ctor `withReport`, class/field docs.
- `packages/zanshin_core/lib/src/ffi/precondition.dart` — the shared `decodeEnvelopeErrorInternal`; header + `Precondition.warnings` docs.
- `packages/zanshin_core/lib/src/ffi/{bookmarks,change,commit_views,config,diagnostics,file,file_ops,git,graph,log_defaults,mutate,op_log,remotes,repo_detect,status,workspace}.dart` — every `!env.ok` branch throws the helper.
- `packages/zanshin_core/lib/src/worker/isolate.dart` — `closeRepo` and `_envelopeToException` use the helper; class, `cloneRepo`, `convert` docs.
- `packages/zanshin_core/lib/src/worker/handle.dart` — `lastPrecondition`, `snapshot`, `CreatedRepoHandle` docs.
- `packages/zanshin_core/lib/src/ffi/warning.dart` — `cloneCleanupFailed` doc.
- `packages/zanshin_core/test/ffi/warning_test.dart` — error-arm group: every `_cases` decoder + snapshot + diagnostics with and without a report, warnings-only and precondition-only rows, no `error` table → `ffi.unknown`, unmodifiable warnings, bare positional ctor.
- `packages/zanshin_core/test/worker/error_reports_test.dart` (new) — real-cdylib witnesses: handle-scoped `describe` of the root (bad alias entry, new file → `wasSnapshotTaken` true on the exception AND `lastPrecondition`), handle-less `configSet` of `user.name` over a `[user.name]` table, failed `convert` (reserved ref + unreadable file, partial report, `.jj/` rolled back), and the report-less `openRepo`.
- `docs/ffi-abi.md` — creations' warnings, convert's report, `config_set`, both decode contracts; no "until Story 9.35" caveat left.
- `_bmad-output/implementation-artifacts/deferred-work.md` — the 9.28 `config_set` item and the 9.33 failed-creation item RESOLVED; new "Surfaced 2026-09-25 while implementing Story 9.35" (panic arm) and "… while reviewing Story 9.35" (barrel) sections.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `9-35` done with summary and review note; `last_updated` 2026-09-25.

**Review findings breakdown.** 25 findings (high 0, medium 0, low 18, false 7, maybe-false 0).
- Patches applied (7 entries, all `low`): `lastPrecondition` equals the exception's precondition only when the error envelope carries one (`ffi-abi.md`, `handle.dart`); the handle-scoped witness now snapshots a new file so `wasSnapshotTaken` is TRUE on both sides (+ sprint-status wording); warnings-only and precondition-only synthetic rows; `Precondition.warnings` / `RepoHandle.snapshot` docs name the exception's report; the panic-arm deferral names the worker-built `ffi.invalid_handle` / `internal.dispatch_error`; `precondition.dart` header; `withReport` / positional-ctor / `warnings` "unmodifiable" wording. The implementation subagent was re-engaged via SendMessage and applied them.
- Deferred (1, `low`, frontmatter `deferred` + `deferred-work.md`): the barrel exports neither `ZanshinFfiException` nor `Precondition` (pre-existing, extends the 9.33 barrel item).
- Rejected: `toString()`/logging lacks the report (low — the error result carries it, which is the intent; log format is a UI choice); env-guard checks only `XDG_CONFIG_HOME` / `chmod 000` as root (low — the idiom of three existing suites, tests run via `cargo make`, never as root); `Precondition` has no `==` (low — "same report" is content; equality would add surface across nested payload types); Rust panic arm carries no report (low — a never-reached backstop, the fix carries a `CallReport` across `catch_unwind`; left recorded in `deferred-work.md`); no Dart partial-report witness (false — partialness is Rust's, witnessed there); import cycles (false — harmless in Dart; the stale header part was patched); corrupt nested precondition table (false — unreachable, loud failure by design); ok open envelope without `RepoHandle` (false — unreachable, `_replyRepoOp` routes it); intent readings: precondition-only warnings, successor type, `send` choke point, per-module witnesses (false — the story text selects the implemented reading).

**Follow-up review recommendation:** `false` — first pass; patched entries by verdict: high 0, medium 0, low 7.

**Verification performed.**
- `cargo make --allow-private test-core` → 543 tests passed (541 before the review patches), incl. all four `error_reports_test.dart` witnesses and the 73 error-arm decoder cases; `test-core-analyze`, `test-core-format`, `test-dart-analyze`, `test-dart-format` → clean.
- `cargo make test` → `test-cargo`, `test-clippy`, `test-fmt` green, then stops at `test-flutter` on exactly the 3 pre-existing `zanshin_bootstrap_test.dart` splash-card failures; every later step run via `cargo make --allow-private` (`test-shell*`, `test-settings*`, `test-cargo-deny`, `test-cargo-hygiene`, `test-jj-adapter-hygiene`, `coverage`) → exit 0. Run before and after the review patches.
- Coverage held at 99.46% (13707/13781); `coverage-baseline.txt` unchanged; extern guard OK.
- `grep` checks: no hand-written file builds an exception from an `FfiError` outside the helper (the two `isolate.dart` hits build worker envelopes); no "until Story 9.35" caveat in `docs/`, `packages/zanshin_core/lib`, `crates/`.
- Matrix audit: all six rows covered by tests that ran and passed.
- `pubspec.lock` drift (`vector_math`) reverted after every Dart run.

**Residual risks.**
- A verb that panics after its pre-verb snapshot still loses the report (Rust `catch` panic arm) — recorded in `deferred-work.md`.
- The app cannot name `ZanshinFfiException` / `Precondition` without a `src/` import until the barrel exports them (deferred).
- `jj.clone_cleanup_failed` has no end-to-end witness (the known 9.20 fault-seam deferral); its Dart path is the same helper the conversion witness exercises.
