---
title: 'Story 11.23: jj 0.47 follow-ups — config gc of workspace configs, binary files in file search, the dead wire values, the stale title draft'
type: 'feature'
created: '2026-11-04'
status: 'done'
baseline_revision: 'e9e8c79e348d986c4f13e2bb4d5dbe35a99d09c7'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['multiple-goals', 'oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** The jj 0.46 → 0.47 pin bump left four gaps: `config gc` ignores workspace configs (the CLI collects them since 0.47), `file search` returns binary files as lines (the CLI reports "Binary file matches" and has `--binary-as-text` / `--skip-binary`), three wire values jj 0.47 never produces still exist, and the inspector's describe form prefills a stale (empty) draft after the change was described through the composer.

**Approach:** Port the CLI's 0.47 `config gc` and `file search` behavior into `zanshin-jj` with a `kind` on `MissingRepoConfig` and a tri-state `binary` mode + `binary` flag on `SearchMatch`, carried through the FlatBuffers schema, `zanshin-ffi` and `packages/zanshin_core`; delete the dead values end to end; make an inspector title draft remember its base description and be dropped when stale.

## Boundaries & Constraints

**Always:** CLI parity at v0.47.0 (`git -C ../jj show v0.47.0:cli/src/commands/config/gc.rs`, `:cli/src/commands/file/search.rs`). Schema enums keep their remaining wire values (removing a middle member leaves an explicit gap: `NotPostfixOperator = 2`); new fields are appended to their tables. `cargo make codegen` after schema/FFI edits, output committed. Null for absence; jj's words verbatim. New/changed lines get tests (Rust inline or `tests/it/<module>.rs`, Dart under `packages/zanshin_core/test`, `app/test`). Strings via `app/lib/l10n/app_en.arb` + `flutter gen-l10n`.

**Never:** No new Settings UI for config gc (none lists `MissingRepoConfig` today — the Dart model only gains the field). No remote-poll refspec pre-check, no `resolve` 0.47 hint (non-goals). Never run `jj` in this repo; no full gate (`cargo make test`/`test-full`/`coverage`) in this run.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| gc lists both kinds | `<cfg>/jj/repos/a` and `<cfg>/jj/workspaces/b` record vanished paths | `[a (Repo), b (Workspace)]` — repo entries first then workspace, each sorted; `config_gc_delete([b])` deletes `b` | no config dir → `NoConfigPath` "No repo configs directory found" |
| search binary Detect | file with a NUL in its first 8000 bytes matching the pattern | one `SearchMatch { binary: true, line_number: 0, content: [], conflict_side: None }` | — |
| search AsText | same file | its matching lines, `binary: false` | — |
| search Skip | same file | no match | — |
| search conflict, one binary side | conflict whose any `adds()` side is binary, a side matches | Detect: one binary match (no side); AsText: per-side lines; Skip: none | — |
| stale draft (Ralph) | undescribed `@` title typed+deleted, Esc, composer commit with message, reopen title | field prefilled with the new description | — |
| typed draft survives | draft "my text" kept, description changed meanwhile | field shows "my text" and the note "The description changed meanwhile." | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/config_cmd.rs:236-243` -- `MissingRepoConfig`; add `pub kind: ConfigGcKind` (`Repo`/`Workspace`, export from `lib.rs:102`).
- `config_cmd.rs:1113-1186` -- `gc_root` (→ return both roots `<cfg>/jj/repos`, `<cfg>/jj/workspaces`; error reason "No repo configs directory found"; the workspace text "No workspace configs directory found" is the CLI's second check, unreachable when the first passes since both hang off `root_config_dir` — keep it for parity), `find_missing_repo_configs` (rename → `find_configs_with_missing_paths(root, kind)`, cite gc.rs @ v0.47.0), `gc_list_with` (repo list then workspace list), `gc_delete_with` (reason text "not a missing config directory"). Doc comments at `:477-503` say repos only — update.
- `crates/zanshin-jj/src/config_cmd.rs` inline tests / `crates/zanshin-jj/tests/it/` (rg `config_gc`) -- existing gc tests to extend; `api_stability.rs:2243,2274`.
- `crates/zanshin-jj/src/file.rs:138-153` `SearchMatch` (add `binary: bool`), `:662-686` `collect_matches`, `:714-772` `file_search` (add `binary: BinaryMode` param: `Detect` default/`AsText`/`Skip`; `jj_lib::file_util::is_binary`; port search.rs:138-181 @ v0.47.0 — binary match pushes one `SearchMatch` with no line, path only; name_only unchanged). `crates/zanshin-jj/src/repo.rs:1147-1160` `Repo::file_search` + `:5450`. Callers to update: `tests/it/{file_reads,snapshot_precondition,arg_refusals,api_stability,warnings}.rs`.
- `schemas/envelope.fbs:59-60` RevsetErrorKind (drop `NotPrefixOperator`, `NotPostfixOperator = 2`), `:870-876` FileSearchRequest (append `binary: FileSearchBinary`; new `enum FileSearchBinary : ubyte { Detect, AsText, Skip }`), `:2322` PushRefStatus (drop `Unexported`), `:2508-2514` SearchMatch (append `binary: bool`), `:2952-2955` MissingRepoConfig (append `kind: ConfigGcKind`; new `enum ConfigGcKind : ubyte { Repo, Workspace }`).
- `crates/zanshin-ffi/src/file.rs:149,282,533-542` request read / envelope / call; tests `:747-850`, `tests/it/file_ffi.rs:606-770`. `crates/zanshin-ffi/src/config.rs:412-425,907` gc envelope. `crates/zanshin-ffi/src/push.rs:94,381,445` Unexported. `crates/zanshin-ffi/src/envelope.rs:387,497,1480,1871,1958,2601` dead codes.
- `crates/zanshin-jj/src/push.rs:172` `PushRefStatus::Unexported`; `warning.rs:218` `PushBookmarksNotUpdatedLocally`; `revset.rs:120-122` `NotPrefixOperator`; `repo.rs:1943` doc; `tests/it/api_stability.rs:2378,2514,2670-2692,2829`.
- `packages/zanshin_core/lib/src/ffi/config.dart:211-215,463-470` MissingRepoConfig + decode (add `kind` enum `ConfigGcKind`, export in `lib/zanshin_core.dart:30`); test `test/ffi/config_test.dart:71`.
- `packages/zanshin_core/lib/src/ffi/file.dart:97-113,227+` zanshinFileSearch + SearchMatch (`binary` param + field; Dart enum `FileSearchBinary`, exported); plumbing `worker/handle.dart:1876-1901`, `worker/commands.dart:991-1008`, `worker/isolate.dart:2438-2455,4801-4814`; tests `test/worker/file_test.dart`, `test/ffi/file_test.dart` (if present).
- `packages/zanshin_core/lib/src/ffi/push.dart:121,463`, `revset_search.dart:77,229`, `warning.dart:246,390`; tests `test/ffi/push_test.dart:89,144`, `test/ffi/warning_test.dart:459`.
- `app/lib/src/features/sync/push_sheet.dart:561` unexported arm; `app/lib/l10n/app_en.arb:1733-1734` `pushSheetUnexported` (remove; regenerate l10n).
- `app/lib/src/features/graph/graph_inspector.dart:97` `_drafts`, `:291` `draftOf`, `:301-308` close/update, `:350-364` save, `:633-660` `runComposer` (done → also drop `_drafts[key]`), `:1008-1016` form prefill, `:1580-1720` `_DescribeForm` (note line). Tests in `app/test/features/graph/graph_inspector_test.dart`.
- `docs/ffi-abi.md:2175,2186` and `docs/rust-error-codes.md:185` -- drop the dead values; document `kind`, `binary`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/config_cmd.rs` (+ `lib.rs`) -- `ConfigGcKind`, both roots, CLI texts, tests (a missing workspace config listed with `Workspace` and deleted; the "No repo configs directory found" error) -- I1.
- `crates/zanshin-jj/src/file.rs`, `repo.rs` -- `BinaryMode` param + `binary` flag per CLI; tests per mode on a NUL file and a conflict with a binary side; update callers -- I2.
- `crates/zanshin-jj/src/{push,warning,revset,repo}.rs`, `tests/it/api_stability.rs` -- delete the three dead values -- I3.
- `schemas/envelope.fbs` then `cargo make codegen` -- the schema edits above -- I1-I3.
- `crates/zanshin-ffi/src/{config,file,push,envelope}.rs` + tests -- carry `kind`/`binary`/mode, drop dead arms; FFI round trip for binary search -- I1-I3.
- `packages/zanshin_core/...` -- Dart enums/fields/params, drop dead values, tests reading `kind` and `binary` -- I1-I3.
- `app/lib/src/features/sync/push_sheet.dart`, `app/lib/l10n/app_en.arb` (+ gen-l10n) -- drop `unexported` -- I3.
- `app/lib/src/features/graph/graph_inspector.dart` -- draft base description; `draftOf` drops a stale untouched/empty draft; `describedMeanwhile(key)` drives a note string `inspectorDescriptionChangedMeanwhile` ("The description changed meanwhile.") in `_DescribeForm`; `runComposer` done drops the title draft; widget tests for both sequences -- I4.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- update -- I1-I3.

**Acceptance Criteria:**
- Given the schema, when grepping it, then `Unexported`, `NotPrefixOperator` and `jj.push_bookmarks_not_updated_locally` occur nowhere in schema, Rust, Dart, l10n or docs (except history in `_bmad-output`), and `cargo make codegen` leaves no diff.
- Given a Dart `configGcList()` decode with a workspace entry, then `MissingRepoConfig.kind == ConfigGcKind.workspace`.
- Given a binary search over FFI, when decoded in Dart, then `SearchMatch.binary` is true.

## Spec Change Log

## Review Triage Log

### 2026-11-04 — Review pass
- verdicts: 29 findings — high 0, medium 0, low 19, false 10, maybe-false 0
- findings:
  - `[low]` `[patch]` (verification-gap) runComposer's title-draft drop unpinned: the 11.23 test passes without it — added a typed-draft ('abc') composer-commit case.
  - `[low]` `[reject]` (edge-case) base recorded at first keystroke, not at form open: a reload between open and first keystroke gives the draft the newer base — needs a reload while an untouched form is open; the fix adds a second state map.
  - `[low]` `[reject]` (edge-case) draftOf drops a stale prefill-equal draft while its form is open — needs the user to type back exactly the old prefill and a reload meanwhile; guard adds a branch for a near-unreachable case.
  - `[false]` `[reject]` (edge-case) updateDraft records base '' for an unselected key / null description — the describe form only exists for the selection with its `show` entry read (`editing` comes from the entry), so updateDraft always has `key == _key` and a description.
  - `[low]` `[patch]` (edge-case) out-of-range `binary` refused as "binary is required" — context now names the unknown value; FFI test asserts it.
  - `[low]` `[reject]` (edge-case) Dart maps an unknown gc kind to repo — the cdylib and zanshin_core ship and regenerate together; no newer native lib can meet this Dart.
  - `[low]` `[patch]` (blind) wrong error text for a bad `binary` value — same fix as the edge-case row.
  - `[false]` `[reject]` (blind) runComposer drops typed title drafts against the stale-draft rule — the intent (epics.md 11.23 item 4) explicitly says a successful composer commit/split drops the same change's title draft.
  - `[low]` `[reject]` (blind) the "changed meanwhile" note offers no action — the intent asks for a note only; clearing the fields is the remedy.
  - `[low]` `[patch]` (blind) the note shows when the draft already equals the new description — `describedMeanwhile` now also requires the draft to differ.
  - `[false]` `[reject]` (blind) draftOf mutates during build, order-dependent with describedMeanwhile — the parent build calls draftOf (form `initial`) before the child form's build reads describedMeanwhile; same frame, fixed order.
  - `[low]` `[reject]` (blind) updateDraft empty base for unselected key — duplicate of the edge-case row; unreachable (see above).
  - `[low]` `[patch]` (blind) stale v0.46 CLI citations / "repo"-only wording in warning.rs, file.rs, envelope.rs, warning.dart, config_ffi.rs, rust-error-codes.md — updated.
  - `[low]` `[patch]` (blind) PushRefStatus value 4 retired without a note — schema comment added.
  - `[false]` `[reject]` (blind) the removal reverses the earlier "keep so values stay put" decision unrecorded — Ralph decided removal on 2026-11-04 (deferred-work I3, epics.md 11.23 item 3).
  - `[low]` `[reject]` (blind) Dart unknown gc kind → repo — duplicate of the edge-case row.
  - `[low]` `[patch]` (blind) docs not extended (invalid_input row, gc_delete row) — added.
  - `[low]` `[reject]` (blind) binary + name_only untested — the binary arm ignores name_only by construction (one path-only match either way); a test adds nothing a reader cannot see.
  - `[low]` `[reject]` (blind) weak AsText conflict test (sides, contents) — per-side numbering is pinned by the pre-existing `file_search_numbers_conflict_sides_independently`.
  - `[false]` `[reject]` (blind) gc_missing loses repo results when the workspaces root fails — the CLI does the same (`?` on each root, gc.rs:42-53 @ v0.47.0).
  - `[false]` `[reject]` (intent) Settings UI for gc rows not built — no Settings surface lists `MissingRepoConfig` (no `configGcList` use in app/lib); nothing to extend.
  - `[low]` `[reject]` (intent) "No workspace configs directory found" untested — unreachable once the repo root resolved (both derive from root_config_dir), kept as the CLI's check.
  - `[low]` `[reject]` (intent) delete-failure reason now "not a missing config directory" — data-only text with no CLI counterpart; the old text would be wrong for workspace dirs.
  - `[false]` `[reject]` (intent) no UI for binary hits — no app caller of fileSearch; intent is bridge-level (deferred-work I2 "tri-state + flag").
  - `[false]` `[reject]` (intent) NotPrefixOperator retired rather than deleted — it is gone from every API; the explicit `= 2` only keeps the later wire values, per the schema's append-only rule.
  - `[false]` `[reject]` (intent) codegen cleanliness not verifiable from the diff — `cargo make codegen` was rerun after implementation with no further diff.
  - `[low]` `[reject]` (intent) I4 tests call closeForm instead of pressing Esc — Esc → closeForm is pinned by the existing Esc test; the new tests target the draft logic.
  - `[low]` `[reject]` (intent) composer split never exercised for the draft drop — the drop sits on the shared GraphActionDone arm for both actions.
  - `[false]` `[reject]` (intent) Auto Run Result / mirroring not in the diff — written at finalize; `deferred` is empty, so nothing to mirror.

## Design Notes

A draft records `base` = the description shown when it was first kept. `draftOf(key)` for the selected key: when `base != description` and the draft is empty or equals `draftFrom(base)`, it removes the draft and returns null (the form prefills from the new description); otherwise the draft stays and `describedMeanwhile(key)` is true. `dirty`/`save` keep their logic.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib` and `cargo test -p zanshin-jj --test it file_reads:: config` -- pass
- `cargo test -p zanshin-ffi` (lib + `--test it file_ffi::`) -- pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`; `cargo fmt --all --check` -- clean
- `cargo make codegen` -- committed, no diff after
- `flutter test` / `dart analyze` / `dart format --set-exit-if-changed .` in `packages/zanshin_core` and `app` -- pass

## Auto Run Result

Status: done

**Items (deferred-work.md, Story 11.23):**
- I1 (config gc of workspace configs): fixed (b068f068248a01248f03e4b0f734e77a5e1c6776) — `<cfg>/jj/workspaces` scanned after `repos` like gc.rs @ v0.47.0; `MissingRepoConfig.kind` (`ConfigGcKind` Repo/Workspace) through schema, FFI and zanshin_core; error text "No repo configs directory found". No Settings UI lists gc rows today, so none was changed.
- I2 (binary files in file search): fixed (b068f068248a01248f03e4b0f734e77a5e1c6776) — `BinaryMode` Detect (default)/AsText/Skip parameter and `SearchMatch.binary` (path-only match) through Rust, FFI (`FileSearchBinary`) and Dart.
- I3 (dead wire values): fixed (b068f068248a01248f03e4b0f734e77a5e1c6776) — `PushRefStatus::Unexported`, `RevsetErrorKind::NotPrefixOperator`, `jj.push_bookmarks_not_updated_locally` removed from schema, zanshin-jj, zanshin-ffi, zanshin_core, Push sheet, l10n and docs; retired wire values documented (RevsetErrorKind 1, PushRefStatus 4) so no remaining value moves.
- I4 (stale title draft): fixed (b068f068248a01248f03e4b0f734e77a5e1c6776) — drafts keep their base description; a stale empty/prefill draft is dropped, a typed one stays with "The description changed meanwhile."; a successful composer run drops the title draft. Widget tests: Ralph's exact sequence, a typed draft through a composer commit, and the typed-draft-survives note.

**Files changed (main):** `schemas/envelope.fbs` + generated code; `crates/zanshin-jj/src/{config_cmd,file,repo,push,warning,revset,lib}.rs` and `tests/it/*`; `crates/zanshin-ffi/src/{config,file,push,envelope}.rs` and `tests/it/{file_ffi,snapshot_ffi,config_ffi}.rs`; `crates/test-helpers/src/lib.rs` (`add_conflicted_merge_of`); `packages/zanshin_core/lib/src/{ffi/{config,file,push,revset_search,warning},worker/{commands,handle,isolate}}.dart` + tests; `app/lib/src/features/{graph/graph_inspector,sync/push_sheet}.dart`, `app/lib/l10n/app_en.arb` + generated l10n, `app/test/features/graph/graph_inspector_test.dart`; `docs/ffi-abi.md`, `docs/rust-error-codes.md`; `_bmad-output/implementation-artifacts/epic-11-context.md` (regenerated, stale vs epics.md).

**Review:** 29 findings (0 high, 0 medium, 19 low, 10 false). Patched 7 low (typed-draft composer test, note suppressed when the draft equals the description, out-of-range `binary` context text, PushRefStatus retirement comment, v0.47 citations / repo-or-workspace wording, two docs rows). Deferred: none. Rejected: all others, reasons in the Review Triage Log.

**Follow-up review recommended:** false (0 high, 0 medium patched).

**Verification (targeted, per the loop's gate rule — no cargo make test/coverage):**
- `cargo test -p zanshin-jj`: lib 441 passed, `it` 1522 passed (1 ignored).
- `cargo test -p zanshin-ffi`: lib 239, `it` 406 passed; after review patches lib 239 and `--test it file_ffi::` 16 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p test-helpers --all-targets -- -D warnings`: clean; `cargo fmt --all --check`: clean (rerun after patches).
- `cargo make codegen`: rerun after patches, no further diff.
- `cargo make --allow-private test-core` (zanshin_core dart test with the Makefile env): 1200 passed. `dart analyze` / `dart format --set-exit-if-changed` clean in zanshin_core and app (rerun after patches).
- `cargo make --allow-private test-app` on graph_inspector_test, push_sheet_test, remote_sync_test: all passed (88 inspector tests after patches). The implementer ran the full app `flutter test` with the test env: 2044 passed. Plain `flutter test` without the Makefile env fails remote_sync_test — environment, not this change.
- Parity oracle not run: it covers neither `config gc` nor `file search`.

**Residual risks:** the coverage ratchet has not run (test-helpers / zanshin-ffi file.rs per-file numbers show only at the loop's final gate); the "changed meanwhile" note was not checked in the running app via Marionette.

