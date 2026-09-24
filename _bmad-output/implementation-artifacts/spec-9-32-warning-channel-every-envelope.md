---
title: 'Story 9.32: Warning channel on every envelope — `warnings: [{ code, message }]`, the CLI''s `ui.warning_*` as coded facts'
type: 'feature'
created: '2026-09-24'
status: 'done'
baseline_revision: 'c448cadf161811071afd4736935f3f4ed473708b'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/docs/coverage.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The CLI's trunk() resolution fallback is not ported, so its two warnings do not exist either.
    evidence: |-
      cli/src/cli_util.rs:539-559 @ v0.44.0 (load_from_workspace) falls back to `root()` with "Failed to resolve `revset-aliases.trunk()`: …" + "The `trunk()` alias is temporarily set to `root()`."; Zanshin has no fallback — a behaviour gap whose warnings come with the port.
    location: >-
      crates/zanshin-jj/src/revset.rs (alias loading); deferred-work.md "Surfaced 2026-09-24 while implementing Story 9.32"
  - summary: >-
      git fetch reports its unreadable refs only as the jj.git_import_failed warning; the names have no typed payload.
    evidence: |-
      MutationResult (fetch's result) has no failed_ref_names, unlike GitImportResult; Story 9.30 reworks fetch and owns the payload.
    location: >-
      crates/zanshin-jj/src/remotes.rs::git_fetch
  - summary: >-
      "The current workspace '…' no longer exists after this operation" is a CLI warning; Zanshin errors after committing instead.
    evidence: |-
      cli/src/cli_util.rs:2437-2442 @ v0.44.0 (fmt.labeled("warning"), not ui.warning_*) — recorded divergence, no warning code.
    location: >-
      crates/zanshin-jj/src/mutate.rs::finish_transaction
  - summary: >-
      status's conflict lines (unresolved conflicts, conflicted bookmarks) have no typed data.
    evidence: |-
      Printed by the CLI's status formatter (cli/src/commands/status.rs @ v0.44.0), not ui.warning_*, so no warning code; Status/Bookmarks carry no conflict facts for them.
    location: >-
      crates/zanshin-jj/src/repo.rs::Repo::status
  - summary: >-
      Three steps of the CLI's per-command start-up environment are not ported for every verb, so neither their warnings nor their refusals exist there: the [template-aliases] load, the revsets.short-prefixes (fallback revsets.log) parse on verbs other than graph_slice, and workspace root's environment.
    evidence: |-
      WorkspaceCommandEnvironment::new (cli/src/cli_util.rs:934-966 @ v0.44.0) loads the fileset, revset AND template alias tables and parses the short-prefixes expression (:1092-1114) for every workspace command, workspace_helper_no_snapshot included (jj workspace root). Zanshin's pre-verb snapshot ports the fileset/revset alias loads and the immutable_heads() parse only; TemplateAliasParser lives in jj-cli; zanshin_workspace_root loads no config. Found by the Story 9.32 review (Blind Hunter, Edge Case Hunter, Intent Alignment); recorded in docs/rust-error-codes.md's out-of-scope list. Porting a step brings its warnings and its start-up refusals (e.g. an unparseable revsets.short-prefixes fails every CLI command).
    location: >-
      crates/zanshin-jj/src/snapshot.rs::Knobs::read; crates/zanshin-jj/src/repo.rs::Repo::resolve_workspace_root
    severity: low
  - summary: >-
      On a double fault (a bad alias entry plus a wrong-typed snapshot knob), the error envelope lacks the revset-alias warnings the CLI prints before it fails on the knob.
    evidence: |-
      Knobs::read (crates/zanshin-jj/src/snapshot.rs) reads snapshot.auto-track, snapshot.max-new-file-size and the ignore files BEFORE the revset-alias load and the immutable_heads() parse, while the CLI loads all alias tables and parses immutable_heads() in WorkspaceCommandEnvironment::new (cli_util.rs:934-966 @ v0.44.0) and reads the knobs only inside snapshot_working_copy. Pre-existing knob-read order; Story 9.34 moves the knob reads to where the CLI reads them, which puts the start-up alias loads first as in the CLI.
    location: >-
      crates/zanshin-jj/src/snapshot.rs::Knobs::read
    severity: low
---

<intent-contract>

## Intent

**Problem:** Zanshin answers refusals with a registered code, but has no uniform channel for the CLI's other half — success (or a partial run) *with a warning*. Three facts ride one-off fields (`MutationResult.identity_missing`, `Precondition.working_copy_immutable_new_commit`, `Precondition.jjconflict_files_present`), two more are bools in `FinishFacts`, and many `ui.warning_*` sites on shipped verbs report nothing at all (unmatched paths, empty bookmark target, broken alias entries, skipped checkout files, …). A UI cannot switch on a code to offer the remedy (missing identity → "set your identity") without parsing text.

**Approach:** Add `Envelope.warnings: [Warning { code, message }]` on ok AND error envelopes; inventory every CLI @ v0.44.0 `ui.warning_*` site on the paths Zanshin ports and emit each as ONE registered `jj.*` warning code through one per-call collector in `zanshin-jj` (MCP inherits it); move the one-off warning fields into the list; expose the list on every Dart command result.

## Boundaries & Constraints

**Always:**
- **Wire:** `table Warning { code: string; message: string; }`, `Envelope.warnings: [Warning]` appended after `precondition` (WIP in-place). ABSENT on the wire when empty (keeps `PANIC_FALLBACK_ENVELOPE` byte-identical); every reader treats absent as an empty list. Success without caveat = `ok` + empty list — there is no success code, no severity levels.
- **Rule:** every `ui.warning_*` site the CLI @ v0.44.0 reaches on a path Zanshin ports becomes ONE warning code (Design Notes § Inventory — the authoritative mapping). `ui.status()` lines (incl. the `labeled("warning")` status-formatter lines) stay typed facts or out of scope; `ui.hint_*` are never ported.
- **Codes:** `jj.` namespace, one code per remedy, registered in a new "Warning Codes" section of `docs/rust-error-codes.md`; the strings live only in `crates/zanshin-ffi/src/envelope.rs` (single-emission-point rule, as for errors); `zanshin-jj` carries a typed `WarningKind` enum.
- **Message** = the CLI's text block for that warning, verbatim: the `ui.warning_*` line(s) plus the detail lines the same site writes right after it on stderr, joined by `\n`, without the `Warning: ` heading, hints, colour labels or trailing newline. Paths are jj's repo-relative `/` form (Zanshin has no cwd — the one documented deviation). Log/tooltip only: nothing parses it.
- **Structured data stays typed** where it already is (`SnapshotStats`, `GitExportFailure` lists, `GitImportResult.failed_ref_names`, `UntrackResult.unmatched_paths`, `SkippedPath` lists, `ConfigSetResult.working_copy_author`, `ConfigGcResult.failed`): the warning says *that* there is something, the payload says *what*.
- **One mechanism:** `MutationResult.identity_missing` (+ table `IdentityMissing`), `Precondition.working_copy_immutable_new_commit`, `Precondition.jjconflict_files_present`, `FinishFacts.working_copy_became_immutable` and `FinishFacts.git_head_update_failed` are REMOVED (fbs, Rust, Dart) and emitted as warnings instead (pure bools = pure warnings). `FinishFacts` keeps its two export-failure lists.
- **Order** = the CLI's print order: config-load warnings, precondition (snapshot / imports), verb body, `finish_transaction`. The identity warning moves INTO `finish_transaction` (its CLI site), so the precondition's own finishes (`import git head` HEAD-deleted branch, `import git refs`) warn too.
- **Collector:** one per call. Handle verbs: `Repo` starts a fresh list with each verb (like the precondition) and `Repo::take_warnings()` hands it out; the FFI stamps it on the ok and the error arm. Handle-less `config_*` functions return their warnings with the result. Config-load warnings (alias entries, alias redefinition, `immutable_heads()` diagnostics) are recorded ONCE per call — Zanshin re-loading the same table within one call adds nothing (the CLI loads once per command).
- **Dart:** every command result a `ZanshinWorker` / `RepoHandle` method returns exposes `List<ZanshinWarning> warnings` on success (handle-scoped and handle-less alike; decoded from the envelope with ONE shared helper; nested payloads carry an empty list); typed constants `ZanshinWarningCode.*` for every registered code; both exported from the barrel.
- Coverage ratchet: never lower `coverage-baseline.txt`, no `exclude_prefix`; new files ≥ 80 %.

**Never:**
- No UI (the "set your identity" offer is Ralph's), no hint porting, no localization, no severity field.
- No Dart ERROR-path exposure (`ZanshinFfiException` unchanged — Story 9.35); no creation-verb warnings or return-shape change for open/init/clone/convert (Story 9.33).
- No behaviour ports that only exist to reach a warning: the `trunk()` fallback, secure-config fix-ups (9.37), the v0.44 undo stack and its push warning (9.39), fetch refspec/remote-pattern handling (9.30), bookmark auto-track (9.11/9.30), stale auto-update (9.23), the no-change gate (9.40).
- No text parsing of jj output; no new error codes; no change to what any verb writes.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Clean call | any verb, nothing to warn | `ok`, `warnings` absent → `[]` in Rust and Dart | N/A |
| Identity missing | `JJ_USER`/`JJ_EMAIL` unset, `describe` | one `jj.identity_missing`, message "Name and email not configured. Until configured, your commits will be created with the empty identity, and can't be pushed to remotes."; name-only / email-only variants "Name not configured." / "Email not configured." | N/A |
| Identity, nothing committed | no-op bookmark delete, `file_track` | no `jj.identity_missing` (no `finish_transaction`) | N/A |
| Identity in the precondition | colocated, git ref moved outside, empty identity | the `import git refs` finish warns (parity) — in addition to the verb's own finish | N/A |
| Immutable `@` snapshot | `immutable_heads()` covers `@`, dirty file | `jj.working_copy_immutable` "The working-copy commit is immutable; a new commit has been created on top of it." | N/A |
| `@` became immutable | a verb leaves `@` immutable | `jj.working_copy_immutable` "The working-copy commit became immutable; …" | N/A |
| Large file | file over `snapshot.max-new-file-size` | `jj.snapshot_files_refused` "Refused to snapshot some files:\n  big.bin: 2.0KiB (2048 bytes); the maximum size allowed is 1.0KiB (1024 bytes)"; `SnapshotStats` unchanged | N/A |
| Not auto-tracked only | `snapshot.auto-track = "none()"` | NO warning (CLI `build_untracked_reason_message` → `None`) | N/A |
| Unmatched paths | `file_list` with `nope.txt` | `jj.paths_unmatched` "No matching entries for paths: nope.txt" | N/A |
| Colocated export failure | bookmarks `foo` and `foo/bar` | `jj.git_export_failed` "Failed to export some bookmarks:\n  foo/bar@git: …"; `FinishFacts.export_failed_bookmarks` still set | N/A |
| Bad alias entry | repo config `revset-aliases.'bad(' = "x"` | `jj.config_alias_invalid` once per call, every precondition verb | N/A |
| Warning + refusal | precondition warned, verb refuses (`jj.immutable`) | error envelope carries `precondition` AND `warnings` | refusal code unchanged |
| Handle-less | `config_list` with a prefix matching nothing | `[]` entries + `jj.config_nothing_listed` "No matching config key for: nope" | N/A |
| Panic | any `internal.panic` | `PANIC_FALLBACK_ENVELOPE` bytes unchanged, no warnings | N/A |

</intent-contract>

## Code Map

Oracle: `git -C ../jj show v0.44.0:<path>` (CLI; `cli_util.rs` = **cu**), vendored `~/.cargo/registry/src/*/jj-lib-0.44.0/src/`. Ralph's rule: every CLI effect is parity; terminal UX is replaced.

**CLI evidence (read-only):** cu:1105-1119 `print_parse_diagnostics` (`command_error.rs`; heading line + `{err}` source chain); cu:2123-2127 snapshot immutable text; cu:2206-2210 `.jjconflict`; cu:2338-2342 finish "became immutable"; cu:2387-2415 identity (3 variants, only after the op is committed; `WorkspaceCommandTransaction::finish` cu:2790-2806 skips it on `!has_changes()`); cu:2673-2695 `try_reset_git_head` (`{err}` + `print_error_sources`); cu:3162-3249 `print_untracked_files` / `print_invalid_utf8_paths` / `print_snapshot_stats`; cu:3289-3319 `print_checkout_stats` (skipped_files); cu:3321-3347 `print_unmatched_explicit_paths` (`tree.path_value(p).is_absent()` over every given tree); cu:934-940 alias maps loaded once per command; `config.rs:984-1035` `load_aliases_map` ("Failed to load `{table}.{decl}`: {s}"); `revset_util.rs:154-180` `warn_user_redefined_builtin`; `commit_templater.rs:2208-2215` short-prefix index failure; `git_util.rs:270-279` import failures, `:468-506` export failures; per verb: `absorb.rs:102-107/:157`, `restore.rs:174-179`, `interdiff.rs:99-110`, `file/{list.rs:93, show.rs:133/:166-169/:193-196, search.rs:111-114/:164, track.rs:104, untrack.rs:109-114}`, `bookmark/create.rs:84-86`, `bookmark/mod.rs:184-203` (delete → `warn_unmatched_local_bookmarks`, exact patterns only), `git/remote/add.rs:95-110`, `config/{list.rs:116-123, set.rs:121-126, gc.rs:80-84}`, `util/snapshot.rs:40`, `status.rs:73`.

**zanshin-jj (to change):**
- `src/warning.rs` (NEW) -- `Warning { kind: WarningKind, message: String }`, `WarningKind` (one variant per code, rustdoc = CLI site), the per-call collector (record-once support for config-load warnings).
- `src/repo.rs` -- `pending_precondition` `:117` / `precondition()` `:229-251` / `take_precondition()` `:278-280` (twin: `pending_warnings` + `take_warnings()`, reset at every verb start); `snapshot()` `:266-269`; `walk_graph` `:661-665` (graph takes `&Repo` → sink param or returned warnings).
- `src/snapshot.rs` -- `Precondition` `:52-95` (drop `:78`, `:91`), `FinishFacts` `:100-126` (drop the two bools, `merge`/`into_option`), sets at `:536`, `:565`; finishes at `:493-499`, `:644-657`; `Knobs::read` `:290` (alias + `immutable_heads()` load for every precondition verb); stats → A18/A19.
- `src/mutate.rs` -- `MutationResult` `:48-106` (drop `identity_missing` `:99`), `IdentityMissing` `:110-116` + `identity_missing()` `:120-126` (becomes the warning inside `finish_transaction` `:589-650`), `try_reset_git_head` `:519-532`, export appends `:541-548`, `update_working_copy` stats discarded `:635` (A20), `mutation_result` `:684-701`, `no_op_result` `:955-972`, `commit_with_locked_wc` `:1158-1192`, `restore` / `absorb` bodies (`:1302`, `:1376`, `:1424`).
- `src/revset.rs` -- `parse_revset_with` `:222` (diagnostics discarded `:297`), `build_aliases_map` `:342-422` (two `tracing::warn!` → warnings, verbatim CLI text), `revset_config` `:201-212` (+ redefinition check), `immutable_expression` `:436`; `src/op_support.rs:84-90` `immutable_user_expression`.
- `src/graph.rs:113-124` (short-prefix `tracing::warn!` → `jj.short_prefixes_failed`), `:171-176` parses.
- `src/wc_ops.rs:201` (fileset-alias load), `:211` (fileset diagnostics — none at 0.44), `:467` (untrack unmatched paths); `src/file.rs:359-384`, `:662` (skipped reasons), file list/show/search bodies; `src/commit_views.rs` (interdiff); `src/bookmark_ops.rs:38-40` (empty-target note), create/delete bodies; `src/git.rs:477-489` (remote add), `:111-172` (import/export results); `src/remotes.rs:311-327` (fetch import stats, identity); `src/config_cmd.rs:172-178` (`ConfigSetOutcome`), `:731-803` (`set_with`, `check_wc_author` → `repo.take_warnings()`), `config_list` (empty-result note), gc delete `:949-956`; `src/convert.rs:347-355`, `:521` (creation — throwaway sink, 9.33).
- `src/lib.rs:59-78` re-exports (drop `IdentityMissing`, add `Warning`, `WarningKind`, `Warned`); `tests/api_stability.rs` `:162-187`, `:907-927`, `:976-978`, `:1004-1034`.
- Tests asserting removed fields: `tests/config_identity.rs:82-84,:280-314`, `tests/file_track_untrack.rs:258`, `tests/snapshot_precondition.rs:213,:379`, `tests/snapshot_colocated.rs:313,:332`.

**zanshin-ffi (to change):** `src/envelope.rs` -- `FfiErrorObj` `:212-222` (+ warnings), `precondition_envelope` `:258-269` (33 callers; also take warnings), `build_mutation_result` `:438-472`, `ok_empty` `:386`, `ok_repo_handle` `:411`, `ok_diagnostics` `:547`, `finish_envelope` `:583-602`, `err_with_precondition` `:619-647`, `catch` `:667-689`, `PANIC_FALLBACK_ENVELOPE` `:200-203` + test `:960`; inline tests `:738-797`. `src/snapshot.rs:24-66` builders + tests `:136-287`; `src/config.rs:568-571` (config_set arms), list/gc_delete builders; `src/git.rs:569-578`; `tests/repo_config_ffi.rs:140-141`, `tests/snapshot_ffi.rs:663-704`.
- `schemas/envelope.fbs` -- `MutationResult` `:818-832`, `FinishFacts` `:834-845`, `IdentityMissing` `:847-851`, `Precondition` `:1248-1276`, `Envelope` `:1401-1426`. `cargo make codegen` (`Makefile.toml:314-369`) regenerates the 4 committed outputs (`envelope_generated.rs`, `zanshin_ffi.h`, `envelope_zanshin.ffi_generated.dart`, `bindings.dart`).
- `tests/ffi_abi_doc_sync.rs` reads only `# Errors` bullets: never put a warning code in a `# Errors` section (use `# Warnings` or prose).

**packages/zanshin_core (to change):** per-file `_decode*Envelope` `!env.ok` blocks at `file_ops.dart:211`, `change.dart:142`, `status.dart:90`, `mutate.dart:305-333`, `bookmarks.dart:81`, `repo_detect.dart:61`, `graph.dart:369`, `file.dart:388`, `git.dart:313`, `config.dart:371-383`, `log_defaults.dart:72`, `commit_views.dart:370`, `remotes.dart:65`, `op_log.dart:81`, `workspace.dart:138`, `precondition.dart:119-178`; models `mutate.dart:166-240` (drop `identityMissing`, `IdentityMissing`), `precondition.dart:31-146` (drop the two bools; `FinishFacts` drop the two bools); `lib/src/worker/isolate.dart` method return types (table in Design Notes § Dart), `handle.dart` sugar; `lib/zanshin_core.dart` barrel. Tests referencing removed fields: `test/ffi/mutate_test.dart:118-224`, `git_test.dart:62-188`, `file_ops_test.dart:24-127`, `snapshot_test.dart:55-116`. Worker test setup: `test/worker/detect_test.dart:25-38` (colocated via `git init` + `convert`), `config_test.dart:33-35` (XDG guard).

**Docs/bookkeeping:** `docs/rust-error-codes.md` (new "Warning Codes" section + out-of-scope list after the code table `:33-79`; `jj.config_error` row mentions of alias-entry `tracing::warn!` become warnings), `docs/ffi-abi.md` (`## Envelope format` `:51-67`, `### precondition` `:69-104`, `MutationResult.identity_missing` `:436-443`, `:1056`); `_bmad-output/implementation-artifacts/{sprint-status.yaml:131, deferred-work.md}`.

## Tasks & Acceptance

**Execution:**
- [x] `crates/zanshin-jj/src/warning.rs` (NEW), `src/lib.rs` -- `Warning`, `WarningKind` (23 variants, § Inventory), `Warned<T> { value, warnings }`, collector; re-exports; inline unit tests (record-once, order) -- the Rust surface MCP inherits.
- [x] `crates/zanshin-jj/src/{repo,snapshot,mutate,revset,op_support,graph,wc_ops}.rs` -- thread the collector; `Repo::take_warnings()`; remove the five fields + `IdentityMissing`; identity warning inside `finish_transaction`; emit the shared-path codes (§ Inventory rows S1-S14) with verbatim messages; alias/diagnostic loads return their warnings (record-once) instead of `tracing::warn!`; `file_track` emits `jj.snapshot_files_refused` from its MERGED stats only (no UTF-8 warning, no separate precondition stats warning — `track.rs:104`); `convert` passes a throwaway sink -- shared paths.
- [x] `crates/zanshin-jj/src/{file,commit_views,bookmark_ops,git,remotes,config_cmd}.rs` + `mutate.rs` restore/absorb -- per-verb rows V1-V9; `ConfigSetOutcome.warnings` (snapshot warnings via `repo.take_warnings()` + the author warning); `config_list` / `config_gc_delete` return `Warned<…>`; a shared unmatched-paths helper reused by untrack -- verb bodies.
- [x] `crates/zanshin-jj/tests/*.rs` -- update the removed-field assertions to warnings; one witness per code a Rust test can produce (all but `jj.snapshot_paths_not_utf8` — APFS refuses non-UTF-8 names; and `jj.git_head_update_failed` if no deterministic trigger exists: then an inline unit test of the message builder) incl. identity 3 variants + "nothing committed → none" + precondition-finish identity, record-once (two loads, one warning), order, error-arm warnings; `tests/api_stability.rs` pins -- gate.
- [x] `schemas/envelope.fbs` + `cargo make codegen` -- `Warning`, `Envelope.warnings`, removals, doc comments (Envelope paragraph: present on ok and error, absent = empty, never on `PANIC_FALLBACK`) -- wire.
- [x] `crates/zanshin-ffi/src/{envelope,snapshot,config,git}.rs` -- `pub const` per warning code + `warning_code(WarningKind)`; every `EnvelopeArgs` literal and `FfiErrorObj` carry warnings; `precondition_envelope` takes `repo.take_warnings()` on both arms; config_set arms + `Warned` handle-less builders; inline tests (ok arm, error arm, absent-when-empty, panic bytes) -- FFI.
- [x] `crates/zanshin-ffi/tests/*.rs` -- replace removed-field assertions; one real-envelope witness that a precondition verb's warning crosses on the ok AND the error arm -- outermost Rust surface.
- [x] `packages/zanshin_core/lib/src/ffi/warning.dart` (NEW) + every decoder + `worker/{isolate,handle}.dart` + barrel -- `ZanshinWarning`, `ZanshinWarningCode`, shared `decodeEnvelopeWarningsInternal`, `warnings` on every result (§ Dart), removed fields dropped -- bridge.
- [x] `packages/zanshin_core/test/ffi/*.dart`, `test/worker/warnings_test.dart` (NEW) -- synthetic decode tests (absent → `[]`, order kept, every result type carries them, removed fields gone); real-cdylib witnesses for the § Dart-witness list -- bridge gate.
- [x] `docs/rust-error-codes.md`, `docs/ffi-abi.md` -- Warning Codes section (§ Inventory table incl. emitted-by + payload column) + "Not ported / out of scope" list with reasons and owning story; envelope contract (`warnings`), removed-field paragraphs rewritten -- record.
- [x] `_bmad-output/implementation-artifacts/{deferred-work.md, sprint-status.yaml}`, `coverage-baseline.txt` -- dated "Surfaced 2026-09-24 … Story 9.32" section (§ Deferrals); `9-32-…` → `done` + summary, bump `last_updated`; commit the auto-raised baseline -- bookkeeping.

**Acceptance Criteria:**
- Given any envelope-returning symbol, when it answers ok or error, then its `warnings` are exactly the CLI @ v0.44.0 warnings for that path in the CLI's order (per § Inventory), and an absent vector reads as an empty list in Rust and Dart.
- Given the five removed fields, when the schema, Rust and Dart are searched, then none remains and each fact is reachable only as its warning code.
- Given a `ZanshinWorker` or `RepoHandle` command (except the § Dart exclusions), when it succeeds, then its returned value exposes `warnings`, and every registered code exists as a `ZanshinWarningCode` constant equal to the registry string.
- Given `docs/rust-error-codes.md`, then every `WarningKind` has one registry row whose code equals `envelope.rs`'s constant, and every CLI site of § Inventory appears either as a row or in the out-of-scope list with its reason.
- Given `cargo make test`, then every step except the 3 pre-existing `test-flutter` splash-card failures is green, incl. clippy, the coverage ratchet and the extern guard.

## Spec Change Log

## Review Triage Log

- **2026-09-24 — twin check (implementation pass).** Installed `jj` is 0.45.1 (not the 0.44.0 pin); scratch repo with `JJ_CONFIG`/`XDG_CONFIG_HOME` in the scratchpad, `snapshot.max-new-file-size = 1024`, `[revset-aliases] 'bad(' = 'x'`, a 2048-byte `big.bin`, `jj file list nope.txt` run from the workspace root. All three CLI stderr blocks, minus `Warning: ` and the hint, equal Zanshin's messages byte for byte: `Refused to snapshot some files:\n  big.bin: 2.0KiB (2048 bytes); the maximum size allowed is 1.0KiB (1024 bytes)` (pinned by `test/worker/warnings_test.dart`), `No matching entries for paths: nope.txt` (pinned by `tests/warnings.rs` + the Dart witness), and the full pest rendering of the bad alias entry (``Failed to load `revset-aliases.bad(`:  --> 1:5`` … `= expected <strict_identifier>`) (now asserted verbatim in `tests/warnings.rs::a_bad_alias_entry_warns_once_per_call_on_every_verb`). The CLI prints the three in the order alias → snapshot → verb body, the order Zanshin emits.

### 2026-09-24 — Review pass
- verdicts: 36 findings — high 0, medium 4, low 23, false 8, maybe-false 1
- findings:
  - `[low]` `[patch]` (Blind Hunter) Template-alias load warnings never fire and the registry's reason "Zanshin renders no templates" is wrong — the CLI loads `[template-aliases]` in `WorkspaceCommandEnvironment::new` (cu:940) on every command. Group "start-up environment": registry out-of-scope entry reworded (the load is not ported; `TemplateAliasParser` is jj-cli-only) + frontmatter/deferred-work deferral for porting the start-up steps.
  - `[low]` `[patch]` (Blind Hunter) The start-up `revsets.short-prefixes` parse diagnostics reach only `graph_slice`; neither S13 nor the out-of-scope list names the other verbs. Group "start-up environment": new out-of-scope entry (Zanshin parses short-prefixes only in the graph walk) + the same deferral (the port also brings the CLI's start-up refusal on an unparseable expression).
  - `[low]` `[patch]` (Blind Hunter) `jj log`'s own warning sites (`log.rs:367-394`) are neither rows nor out-of-scope entries. Out-of-scope entry added: `zanshin_graph_slice` takes no FILESETS argument.
  - `[low]` `[reject]` (Blind Hunter) `jj.working_copy_immutable` and `jj.revset_diagnostic` each merge two remedies. The immutable pair shares one remedy (both say a new commit was created on top of `@`) and is the intent's own example code; the revset part (config-sourced vs input diagnostics) is real but reachable only through jj-lib 0.44's single `diff_contains` deprecation, and the fix adds a public code — unlikely in everyday use, more than a direct correction.
  - `[low]` `[reject]` (Blind Hunter) After a failed verb, Dart's `lastPrecondition` no longer shows the immutable/`.jjconflict`/finish facts, and their warnings are dropped on the Dart error path. Intent excludes: the fields are removed as WIP ("the UI does not consume them yet") and the Dart error path is Story 9.35's.
  - `[low]` `[reject]` (Blind Hunter) Nested payloads' `warnings` are always empty, so `result.mutation.warnings` misses `result.warnings`. The fix is the spec's Dart design (§ Dart: nested payloads carry `[]`, documented on every class); rejected as a spec edit.
  - `[false]` `[reject]` (Blind Hunter) A warning missing its code decodes to `''`. Unreachable: `envelope.rs::build_warnings` always writes both strings; `?? ''` is the house decoder style (Story 9.28 triage).
  - `[medium]` `[patch]` (Blind Hunter) Nothing checks the code strings against the registry; the kind list is hand-kept. Grouped with the Verification Gap "eight codes unpinned": `every_warning_kind_has_its_registered_code` now maps all 23 kinds to their literal registry strings through a wildcard-free `match` and checks distinctness.
  - `[low]` `[patch]` (Blind Hunter) `take_warnings()` after `workspace_root`/`resolve_workspace_root`/`log_defaults` returns an earlier verb's untaken list while the rustdoc says they "warn about nothing". Rustdoc corrected: the list is reset only by a precondition-running verb (the FFI drains it after every such verb).
  - `[low]` `[patch]` (Blind Hunter) Name-pattern/fileset/`resolve_revset` diagnostics are still dropped. Verified jj-lib 0.44's only `add_warning` is the `diff_contains` deprecation (`revset.rs:1129`), unreachable from string patterns and filesets; the stale `union_expression` comment calling them "status lines" was reworded to that reason.
  - `[low]` `[reject]` (Blind Hunter) Message parity evidence is thin (twin check on 0.45.1, 3 of 23; the export test compares against the same chain rendering). The spec's manual check names the installed `jj`; building a v0.44.0 CLI is beyond a direct correction; every message is pinned verbatim against the v0.44.0 source text.
  - `[low]` `[patch]` (Blind Hunter) The inline HEAD-reset test comment claims no deterministic trigger although `snapshot_colocated.rs` holds `.git/HEAD.lock`. Comment reworded (the inline test pins the single-cause and chain shapes the integration witness cannot vary).
  - `[false]` `[reject]` (Blind Hunter) Tracking out of step (sprint-status `done` vs spec `in-review`; CLI line ranges differ). The spec goes `done` in this same run; the ranges overlap and each cites a sub-range of the same site.
  - `[false]` `[reject]` (Blind Hunter) The `epic-9-context.md` rewrite drops content. It is the workflow's mandated regeneration of a stale cached context (step 1: a planning artifact was newer), compiled to the context format's size rules — not implementation code.
  - `[low]` `[reject]` (Blind Hunter) `WarnedList` is mutable only sometimes and derived lists lose `warnings`. The growable-vs-`const []` split predates this story (the decoders built those lists before); losing a field on `where`/`map` is `List` semantics; unlikely in use.
  - `[low]` `[defer]` (Edge Case Hunter) `Knobs::read` reads the snapshot knobs before the revset-alias load, so a bad alias entry plus a wrong-typed knob loses the alias warnings the CLI prints before failing. Pre-existing knob-read order; deferred to Story 9.34 (frontmatter + deferred-work).
  - `[low]` `[reject]` (Edge Case Hunter) `absorb` parses `into` (recording diagnostics) before resolving `from`, so an unresolvable `from` plus a deprecated `into` carries a diagnostic the CLI never prints. Double fault through jj-lib's single deprecation; the fix reorders a pre-existing refusal order across `Repo::absorb`/`mutate::absorb` — more than a direct correction.
  - `[maybe-false]` `[reject]` (Edge Case Hunter) The duplicate-URL check reads the cached git config, missing a remote added by another process while the handle is open. Would settle by checking whether `GitBackend`'s gix repo re-reads `.git/config` per `get_git_repo`; if true only low (rare external race, the same cache jj-lib's own `add_remote` existence check uses).
  - `[false]` `[reject]` (Edge Case Hunter) Warning decoding falls back to `''` — same as the Blind Hunter row: unreachable, house style.
  - `[low]` `[patch]` (Edge Case Hunter) `jj workspace root` builds the CLI's start-up environment (alias-load warnings) while `zanshin_workspace_root` warns nothing. Group "start-up environment": out-of-scope entry added (Zanshin's `workspace_root` loads no config) + the deferral.
  - `[low]` `[defer]` (Edge Case Hunter) Claim form of the `Knobs::read` order finding (alias warnings after the knobs). Grouped with the row above → Story 9.34.
  - `[low]` `[patch]` (Edge Case Hunter) Claim form of the short-prefixes finding. Group "start-up environment".
  - `[medium]` `[patch]` (Verification Gap) `git_export` and both `file_untrack` warning sites were exercised by tests that never read the warnings. `git_sync.rs` and `file_track_untrack.rs` now assert the exact `GitExportFailed` block (export, colocated untrack) and the two identical `SnapshotFilesRefused` warnings of the post-reset case (the precondition's, then untrack's own — the CLI's sequence).
  - `[low]` `[patch]` (Verification Gap) The colocated pre-verb refs import's `jj.git_import_failed` had no witness. Added `snapshot_colocated.rs::the_pre_verb_refs_import_warns_about_a_ref_it_cannot_import` (`refs/remotes/git/stolen`, then `status()`, exact message).
  - `[low]` `[patch]` (Verification Gap) Nothing showed `jj.absorb_path_skipped` survives an `Immutable` refusal. Added `content_ops.rs::absorb_keeps_its_skipped_path_warning_when_the_destination_is_immutable` (error + warning, no operation written).
  - `[medium]` `[patch]` (Verification Gap) Eight warning-code strings were pinned by nothing. Grouped with the Blind Hunter registry row: exhaustive literal table test.
  - `[low]` `[patch]` (Verification Gap) `zanshin_snapshot`'s hand-built error arm and `zanshin_config_gc_delete`'s warnings were never read through the extern. `snapshot_ffi.rs` asserts `jj.config_error` + partial report + one `jj.config_alias_invalid` on the snapshot error envelope; `config_ffi.rs` adds an undeletable-directory case asserting `jj.config_gc_delete_failed`.
  - `[low]` `[patch]` (Verification Gap) The push-URL half of the duplicate-URL check was untested. Added `warnings.rs::adding_a_remote_whose_push_url_another_remote_uses_warns`.
  - `[low]` `[reject]` (Intent Alignment) CLI-parity evidence rests on source reading for 20 of 23 messages. Same as the Blind Hunter evidence row.
  - `[low]` `[patch]` (Intent Alignment) Reading R2 vs R3 at the CLI's start-up (template aliases, short-prefixes on non-graph verbs, `workspace root`). Group "start-up environment".
  - `[low]` `[reject]` (Intent Alignment) Creation envelopes never carry warnings and `convert` collects into a throwaway sink. Intent excludes: creation-verb warnings and their return shape are Story 9.33's.
  - `[false]` `[reject]` (Intent Alignment) Absent-on-the-wire vs always-written empty vector. Every reader (Rust accessor `None`, Dart `decodeEnvelopeWarningsInternal` → `[]`) sees the intent's empty list; the absence keeps `PANIC_FALLBACK_ENVELOPE` byte-identical.
  - `[false]` `[reject]` (Intent Alignment) Several Dart results gain a `warnings` field Rust never fills. The intent requires every command's result to expose its warnings, handle-less included.
  - `[medium]` `[patch]` (Intent Alignment) Codes a fixture can produce lacked a `zanshin_core` real-cdylib witness. `test/worker/warnings_test.dart` gained seven (`short_prefixes_failed`, `path_not_a_file`, `absorb_path_skipped`, `checkout_files_skipped`, `config_gc_delete_failed`, `git_import_failed`, `git_head_update_failed`) → 20 of 23; the header names why the other three cannot be produced through the worker (`identity_missing`: the Makefile's `JJ_USER`/`JJ_EMAIL` EnvOverrides pin; `snapshot_paths_not_utf8`: APFS; `path_access_denied`: only jj-lib's test-only `SecretBackend`).
  - `[false]` `[reject]` (Intent Alignment) MCP inherits the kinds, not the code strings. The same architecture as the error codes: `zanshin-jj` carries typed kinds, the registry strings live only in `envelope.rs` (single emission point).
  - `[false]` `[reject]` (Intent Alignment) Sprint status `done` vs spec `in-review`. Same as the Blind Hunter tracking row: both are `done` at the end of this run.

## Design Notes

**Inventory — in scope** (code → CLI site → emitted by → typed data it points at). Message templates are the CLI's, per the Always-rule.

| # | Code | CLI site / text | Emitted by | Data |
|---|------|-----------------|------------|------|
| S1 | `jj.identity_missing` | cu:2390-2401, 3 variants | every committed `finish_transaction` (verbs + precondition's import finishes; NOT track/untrack, no-op results, fetch always — 9.40) | — |
| S2 | `jj.working_copy_immutable` | cu:2123-2127 "is immutable…" / cu:2338-2342 "became immutable…" | precondition snapshot / every finish | `MutationResult.working_copy_change_id` |
| S3 | `jj.jjconflict_files_present` | cu:2206-2210 | colocated precondition (fires even if the tree did not change) | — |
| S4 | `jj.git_head_update_failed` | cu:2689-2690 `{err}` + `Caused by:` chain | colocated finish, snapshot's immutable branch | — |
| S5 | `jj.git_export_failed` | `git_util.rs:470` / `:482` + `  {name}@{remote}: {chain}` lines; two warnings (bookmarks, tags) | colocated finish, snapshot, untrack, git export | `FinishFacts.export_failed_*`, `UntrackResult.failed_*`, `GitExportResult.failed_*` |
| S6 | `jj.git_import_failed` | `git_util.rs:272` + `  {ref}` lines | precondition refs import, git import, git fetch | `GitImportResult.failed_ref_names` (fetch: none — § Deferrals) |
| S7 | `jj.snapshot_files_refused` | cu:3194 + `  {path}: {HumanByteSize} ({n} bytes); the maximum size allowed is …` (FileTooLarge only) | every snapshot the CLI prints stats for (workspace_helper, status, util snapshot, untrack; track: merged) | `SnapshotStats.untracked` |
| S8 | `jj.snapshot_paths_not_utf8` | cu:3215-3218 + `  {dir}: {name:?}` | same as S7 except track | `SnapshotStats.invalid_utf8_paths` |
| S9 | `jj.checkout_files_skipped` | cu:3303-3309 | finish → working-copy update | — |
| S10 | `jj.paths_unmatched` | cu:3340-3343 "No matching entries for paths: a, b" | untrack, restore, absorb, interdiff, file list, file show (multi-path), file search — with the trees each CLI verb passes | `UntrackResult.unmatched_paths` |
| S11 | `jj.config_alias_invalid` | `config.rs:1027-1030` | revset- and fileset-alias loads — both run in `Knobs::read` (`snapshot.rs:287-290`), so every precondition verb, plus parsing reads | — |
| S12 | `jj.config_alias_redefined` | `revset_util.rs:172-176` | revset-alias load | — |
| S13 | `jj.revset_diagnostic` | `print_parse_diagnostics` with the CLI context line: "In `revset-aliases.immutable_heads()`" / "In `revsets.short-prefixes`" / "In revset expression" | immutable-set parse (record-once), graph short-prefixes, every verb revset parse | — |
| S14 | `jj.short_prefixes_failed` | `commit_templater.rs:2210` "Failed to load short-prefixes index" + source chain (no template-position rendering) | graph_slice | — |
| V1 | `jj.remote_url_duplicate` | `remote/add.rs:104-107` "Remote {name} already uses the same URL." | git remote add | — |
| V2 | `jj.bookmark_target_empty` | `create.rs:84-86` "Target revision is empty." | bookmark create | — |
| V3 | `jj.bookmark_names_unmatched` | `bookmark/mod.rs:198-202` (exact patterns, no local bookmark) | bookmark delete | — |
| V4 | `jj.absorb_path_skipped` | `absorb.rs:157` "Skipping {path}: {reason}", one per path | absorb | `AbsorbResult.skipped_paths` |
| V5 | `jj.path_access_denied` | `show.rs:166-169`, `search.rs:111-114`, one per path | file show, file search | `FileContents.skipped`, `FileSearch.skipped` |
| V6 | `jj.path_not_a_file` | `show.rs:193-196`, one per path | file show | `FileContents.skipped` |
| V7 | `jj.config_working_copy_author` | `set.rs:121-126` (3 lines) | config set | `ConfigSetResult.working_copy_author` |
| V8 | `jj.config_gc_delete_failed` | `gc.rs:80-84`, one per dir | config gc delete | `ConfigGcResult.failed` |
| V9 | `jj.config_nothing_listed` | `list.rs:118-122` "No matching config key for: {name}" / "No config to list." | config list | empty entries |

`FileContents.skipped` reasons the CLI never warns about (it panics: "is absent", "is a directory") stay data only.

**Inventory — out of scope** (recorded in the registry with the reason): trunk-fallback warnings cu:545-552 (fallback not ported — deferral); secure-config messages `secure_config.rs` + deprecated-config cu:4617 (9.37; `default_config_migrations()` empty at 0.44); template-alias loads and template-build short-prefix warnings for non-graph verbs (Zanshin renders no templates); fileset parse diagnostics (none at 0.44); undo-of-push `undo.rs:112-115` (9.39); fetch "Ignored refspec"/unmatched remotes/`--branch` (9.30); bookmark create auto-track (9.11/9.30); push stats (9.20); creation-verb warnings (9.33); cu:2277-2281 unresolved conflicts, cu:2437-2442 workspace gone, `status.rs` conflict lines (status formatter, not `ui.warning_*`); pager/editor/argv/alias-command/`debug` warnings (terminal UX); stale auto-update (9.23).

**Collector shape (implementer's choice within):** `Repo` holds the pending list beside `pending_precondition`; `VerbContext`/finish helpers and `&Repo` readers get a `&mut`-sink parameter or return their warnings — no global state. Record-once is keyed per config table / per `immutable_heads()` parse, not by string equality of arbitrary warnings (two different sites may legitimately print the same text).

**Dart.** One helper `decodeEnvelopeWarningsInternal(fbs.Envelope) → List<ZanshinWarning>` (unmodifiable, `[]` when absent), called by every top-level decoder. Class results gain `final List<ZanshinWarning> warnings` (MutationResult, AbsorbResult, GitImport/ExportResult, Track/UntrackResult, Status, Change, GraphSlice, LogDefaults, RepoDetectResult, FileContents, FileSearch, InterdiffView, Precondition (from `snapshot()`), ConfigSetResult, ConfigFileText, ConfigGcResult); nested payloads decode with `[]`. List results (opLog, bookmarks, remotes, fileList, fileAnnotate, show, evolog, workspaces, configList, configPath, configGcList) return a `List<E>` subtype that also exposes `warnings` (callers using it as a `List` stay source-compatible). String/void results become small classes: `configGet` → `{value, warnings}`, `configUnset` → `{path, warnings}`, `workspaceRoot` → `{path, warnings}`, `configFileWrite` → `{warnings}`. Excluded (reason in the class doc): `openRepo`/`initRepo`/`cloneRepo`/`convert` (9.33 owns their return shape; nothing warns there yet), `closeRepo`/shutdown (lifecycle, no CLI counterpart), events and `zanshin_diagnostics` (not worker commands). `lastPrecondition` unchanged.

**Dart real-cdylib witnesses** (Makefile env: identity pinned, so `jj.identity_missing` is Rust + synthetic only): `jj.paths_unmatched` (file list), `jj.bookmark_target_empty`, `jj.bookmark_names_unmatched`, `jj.remote_url_duplicate` (git backend), `jj.config_nothing_listed`, `jj.config_working_copy_author` (repo-scope `user.name`), `jj.snapshot_files_refused` (repo-scope `snapshot.max-new-file-size`), `jj.working_copy_immutable` (repo-scope `immutable_heads()` = `@`, dirty file, `snapshot()`), `jj.config_alias_invalid`, `jj.config_alias_redefined`, `jj.revset_diagnostic` (`show` with `diff_contains`), `jj.jjconflict_files_present` and `jj.git_export_failed` (colocated via `git init` + `convert`). The rest: Rust witnesses + synthetic decode.

**Deferrals** (frontmatter `deferred` + `deferred-work.md`): `trunk()` resolution fallback not ported (cu:545-552 — behaviour gap, its warnings come with it); `git fetch` failed-ref NAMES have no payload (warning only; 9.30 reworks fetch); cu:2437-2442 "workspace no longer exists" — Zanshin errors after committing instead (divergence); `status`'s conflict lines have no typed data (Status/Bookmarks lack conflict facts).

## Verification

**Commands** (foreground; the Bash cap and the 3 pre-existing `test-flutter` failures mean: run each `[tasks.test]` dependency with `cargo make --allow-private <task>`, `coverage` last; set `SDK_PATH`/`CARGO_HOME`/`RUSTUP_HOME`/`FLUTTER_ROOT` under `~/development/sdks` if a toolchain is missing; revert `pubspec.lock` drift after Dart runs):
- `cargo make codegen` then `git status` -- expected: the four generated files updated with the schema change, nothing else.
- `cargo make --allow-private test-cargo`, `test-clippy`, `test-fmt`, `test-dart-analyze`, `test-dart-format`, `test-core`, `test-core-analyze`, `test-core-format`, the `test-shell*` / `test-settings*` steps, `test-cargo-deny`, `test-cargo-hygiene`, `test-jj-adapter-hygiene`, `coverage` -- expected: green; coverage ≥ baseline; extern guard OK.
- `cargo make --allow-private test-flutter` -- expected: only the 3 pre-existing `app/test/features/bootstrap/zanshin_bootstrap_test.dart` failures.
- `grep -rn "identity_missing\|identityMissing\|working_copy_immutable_new_commit\|jjconflict_files_present\|working_copy_became_immutable\|git_head_update_failed" schemas crates packages/zanshin_core/lib` -- expected: no field/type hits (warning-kind names and prose only).

**Manual checks:**
- Twin check with the installed `jj` (scratch repo, `JJ_CONFIG`/`XDG_CONFIG_HOME` in scratch): for three warnings (large file, bad alias entry, unmatched `file list` path) the Zanshin message equals the CLI's stderr block minus `Warning: ` and hints; record in the Review Triage Log.

## Auto Run Result

Status: done
Blocking condition: none

**Summary.** `Envelope.warnings: [Warning { code, message }]` is appended after `precondition` (fbs + codegen): present on ok AND error envelopes, ABSENT on the wire when empty (read as `[]`; `PANIC_FALLBACK_ENVELOPE` byte-identical), no severity, no success code. The inventory of every CLI @ v0.44.0 `ui.warning_*` site on a ported path yields 23 registered `jj.*` warning codes (14 shared-path, 9 per-verb — Design Notes § Inventory), each message the CLI's text block verbatim minus heading and hints, in the CLI's print order. `zanshin-jj` gains `warning.rs` (`WarningKind`, `Warning`, `Warned<T>`, a per-call collector with record-once config loads); `Repo::with_verb` runs the precondition and keeps the call's warnings for `Repo::take_warnings()` on every path; the identity warning moved INTO `finish_transaction`, so the precondition's own import finishes warn too; alias-entry `tracing::warn!`s, parse diagnostics, the short-prefixes index failure, checkout skips, unmatched explicit paths (untrack, restore, absorb, interdiff, file list/show/search), empty bookmark target, unmatched delete names, duplicate remote URL, absorb/file skipped paths and the config author/gc/list notes all became warnings. REMOVED (fbs/Rust/Dart): `MutationResult.identity_missing` + `IdentityMissing`, `Precondition.working_copy_immutable_new_commit`/`.jjconflict_files_present`, `FinishFacts.working_copy_became_immutable`/`.git_head_update_failed`. `zanshin-ffi`: one `pub const` per code + `warning_code()`, `CallReport { precondition, warnings }` stamped on both arms. Dart: `ZanshinWarning`, `ZanshinWarningCode.*`, one shared decoder; every `ZanshinWorker`/`RepoHandle` result exposes `warnings` (list results as `WarnedList<E>`; `configGet`/`configUnset`/`workspaceRoot`/`configFileWrite` return small result classes); creation verbs, close and events excluded (9.33 / lifecycle). The review pass added witnesses (Rust, FFI, 7 more Dart real-cdylib codes → 20 of 23) and completed the registry's out-of-scope list.

**Files changed (grouped).**
- `schemas/envelope.fbs` + the four generated outputs — `Warning`, `Envelope.warnings`, the five removed fields.
- `crates/zanshin-jj/src/warning.rs` (new) — kinds, collector, CLI message renderers, unmatched-path helper, inline tests.
- `crates/zanshin-jj/src/{repo,snapshot,mutate,revset,op_support,graph,wc_ops,file,commit_views,bookmark_ops,git,remotes,config_cmd,convert,op_log,lib}.rs` — collector threading, emission sites, field removals, re-exports.
- `crates/zanshin-jj/tests/warnings.rs` (new) + updated `api_stability`, `config_identity`, `config_cmd(_user)`, `content_ops`, `file_reads`, `file_track_untrack`, `git_sync`, `graph`, `snapshot_colocated`, `snapshot_precondition` — witnesses.
- `crates/zanshin-ffi/src/envelope.rs` + every wrapper module — codes, `CallReport`, builders; `tests/{snapshot_ffi,repo_config_ffi,config_ffi}.rs` — wire witnesses.
- `packages/zanshin_core/lib/src/ffi/warning.dart` (new), every decoder, `worker/{isolate,handle}.dart`, barrel; `test/ffi/warning_test.dart`, `test/worker/warnings_test.dart` (new) + updated decode tests.
- `docs/rust-error-codes.md` (Warning Codes + out-of-scope list), `docs/ffi-abi.md` (envelope contract), `coverage-baseline.txt`, `_bmad-output/implementation-artifacts/{sprint-status.yaml, deferred-work.md, epic-9-context.md (regenerated — the cached context was stale)}`.

**Review findings.** 36 findings (high 0, medium 4, low 23, false 8, maybe-false 1). Patched (12 entries): exhaustive code-literal table test (medium, Blind Hunter + Verification Gap), warning assertions on `git_export`/`file_untrack` (medium), 7 Dart real-cdylib witnesses (medium), colocated precondition import-failure witness, absorb-refusal-keeps-warning witness, snapshot error-arm + gc-delete FFI witnesses, push-URL duplicate witness, registry out-of-scope entries (start-up environment steps, `jj log` FILESETS), `take_warnings` rustdoc, two stale comments. Deferred (frontmatter + `deferred-work.md`): the CLI start-up environment steps not ported for every verb (template aliases, short-prefixes parse, `workspace root`); the `Knobs::read` double-fault order (→ Story 9.34). Rejected (reasons in the Review Triage Log): merged remedies in two codes, the Dart error path (9.35), nested-payload `warnings` design, `?? ''` decoding (×2), thin twin evidence (×2), tracking/citation mismatch (×2), the regenerated epic context, `WarnedList` mutability, absorb parse-before-resolve double fault, cached git config (maybe-false), creation envelopes (9.33), absent-vs-empty vector, never-filled Dart fields, MCP code strings.

**Follow-up review recommended: true.** First pass; patched entries at entry verdict: medium 3 (code-literal table, export/untrack assertions, Dart witnesses), low 9. Named unverified risk: the patch pass's new test recipes — above all the Dart `jj.checkout_files_skipped` (`snapshot.auto-track = "none()"` + `fileTrack` + an untracked file + `edit`) and `jj.absorb_path_skipped` (a conflicted merge built through `newChange`, resolved on disk) witnesses and the rewritten registry test — have not been read by any reviewer, and the central collector plumbing (`Repo::with_verb`, the CLI print order across precondition/verb/finish) got a single pass.

**Verification.** After the patches: `cargo make codegen` leaves the generated files unchanged (the first run caught header/`bindings.dart` rustdoc drift, now regenerated); `cargo make --allow-private` test-cargo (75 suites), test-clippy, test-fmt, test-dart-analyze, test-dart-format, test-core (459 tests), test-core-analyze/format, all `test-shell*`/`test-settings*` steps, test-cargo-deny, test-cargo-hygiene, test-jj-adapter-hygiene and coverage PASS; test-flutter FAILS only on the 3 pre-existing `zanshin_bootstrap_test.dart` splash-card tests (Expected 524.0, Actual 584.0). Coverage 99.45% (13501/13575), ratchet OK (raised: `commit_views.rs` 98.67, `file.rs` 99.37, `repo.rs` 97.43, new `warning.rs` 100), extern-coverage OK. The removed-field grep finds only warning-kind names. Matrix audit: every I/O row has a passing witness. Twin check (installed jj 0.45.1) recorded in the Review Triage Log. `pubspec.lock` drift reverted after every Dart run.

**Residual risks.** Warnings on Dart ERROR results are still dropped until Story 9.35; creation verbs report none until Story 9.33; three CLI start-up steps (template aliases, short-prefixes parse on non-graph verbs, `workspace root`'s environment) are not ported, so their warnings are absent; message parity was run against the CLI for 3 of 23 codes (the rest is pinned to the v0.44.0 source text).
