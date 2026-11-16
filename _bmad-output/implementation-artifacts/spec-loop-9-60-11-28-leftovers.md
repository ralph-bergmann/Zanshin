---
title: 'Story-loop 9.60 / 11.28 leftovers: bare config-error reasons, push commit check resolution error, write_error doc'
type: 'bugfix'
created: '2026-11-16'
status: 'done'
baseline_revision: '4d8bba7f5fe4b525bde9738d605e3eb47195c1d9'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      Config faults outside value_error (file_error, migrate, build_aliases_map's non-table alias
      table, workspace_value_error) still carry a path prefix and one ': '-joined line instead of
      the CLI's Config error text and its Caused by lines.
    evidence: |-
      config.rs file_error renders "<path>: Configuration cannot be parsed as TOML document: …";
      the CLI prints the message, then Caused by, with the path only in its hint
      (cli/src/command_error.rs:424-436 @ v0.47.0). migrate, the non-table alias table and
      workspace_value_error join with ': ' too. Pre-existing; this run moved only value_error to
      the CLI's form. The oracle's config-file witnesses compare only the hint for these.
    location: >-
      crates/zanshin-jj/src/config.rs (file_error, migrate, workspace_value_error); crates/zanshin-jj/src/revset.rs (build_aliases_map)
    severity: low
  - summary: >-
      The push sheet shows a refused push's context only, never its hints, so the commit check's
      new "Did you mean" hint (and every other push refusal hint) never reaches the user.
    evidence: |-
      app/lib/src/features/sync/push_sheet.dart:261-264 shows error.context ?? error.code for
      planError / pushError; the hints ride ZanshinFfiException.hints. Pre-existing UI behavior;
      UI code is written only inside a story.
    location: >-
      app/lib/src/features/sync/push_sheet.dart:261
    severity: low
  - summary: >-
      Conversion's trunk() alias step puts a ConfigError's Display into jj.convert_failed, so its
      context carries the 'config error: ' label and its code differs from the CLI's.
    evidence: |-
      convert.rs:567-569 maps with RepoError::ConvertFailed { reason: e.to_string() }; the CLI
      raises a load fault as Config error, a save fault as Error (From<ConfigFileSaveError>) and a
      secure-config fault as Internal error (cli/src/command_error.rs:409-413,951-955 @ v0.47.0).
      Pinned only as ConvertFailed { .. } by tests/it/convert_alias_write_failure.rs. Pre-existing.
    location: >-
      crates/zanshin-jj/src/convert.rs:567
    severity: low
---

<intent-contract>

## Intent

**Problem:** Three low leftovers of the story loop 9.60 / 11.28, each verified against the current code: (1) `mutate::cfg`, `file::cfg` and `commit_views::rev`'s config arm put a `ConfigError`'s Display ("config error: <reason>") into the `jj.config_error` context, while `From<ConfigError> for MutateError` and every FFI carrier keep the bare reason — so one fault's context depends on the path, and the CLI's `Config error:` heading shows up in-band (e.g. a wrong-typed `snapshot.max-new-file-size` through `SnapshotConfig::load`); (2) `git push`'s commit check maps an `immutable_heads()` resolution failure through `cfg_text` to `jj.config_error` without hints (`push.rs:594-595`), where the CLI's bare `.resolve()?` (`cli/src/commands/git/push.rs:834-836` @ v0.47.0) raises `From<RevsetResolutionError>` with `revset_resolution_error_hints`; (3) `write_error`'s doc (`config.rs:2231-2242`) says `set_value`/`delete_value` fail only on a non-inline TABLE target, but jj-lib 0.47.0's `ConfigLayer::set_value` also fails (`WouldOverwriteValue`) when a middle node is not a table.

**Approach:** (1) One conversion: `mutate::cfg` delegates to `From`, `file::cfg` and `commit_views::rev` destructure the bare reason; tests that pinned the label change. (2) Map the commit check's `resolve_expression` error through `mutate::rev` (resolution code + hints), as the CLI. (3) Correct the doc with each caller's real reason (remote writers: `trunk_symbol` found a string, so its parents are tables; `write_repo_presets`: a new repo's fresh file, the CLI `.expect`s "initial repo config shouldn't have invalid values"; `env_layer`: a fresh layer of distinct keys) and pin with a unit test that a pre-filled non-table `remotes.<name>` refuses (no panic, nothing saved) while the rename writer still succeeds on it.

## Boundaries & Constraints

**Always:** CLI observable behavior (Ralph, 2026-10-23); `jj.config_error` context never carries the `config error: ` label on any path; hints kept on every conversion; the commit-check refusal writes nothing; no panic for the contrived write (the CLI panics there, Zanshin refuses — project rule: no panic on FFI-reachable paths); gate rule of this run: targeted checks only, no `cargo make test` / `test-full` / `coverage`.

**Never:** changing the `Display` of any error enum (`config error: …` stays as Display — only the carried `reason` changes); removing `cfg` (it stays the `map_err` fn pointer at ~40 sites); touching `convert.rs`'s `ConvertFailed` mapping, `deferred-work.md`'s existing bullets for these items, `epics.md`, `sprint-status.yaml`, or any finished spec.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Wrong-typed knob via `cfg` | repo config `snapshot.max-new-file-size = true`; `Repo::snapshot` vs `jj status` | `PreconditionError::Config` reason = the CLI's `Config error:` text without the label; hint "Check the config file: <path>" | `jj.config_error` |
| `From` path | a `ConfigError` converted by `From` | same reason and hints as `cfg` | — |
| File / commit-view config fault | `file::cfg(Load{reason:"k",hints:["h"]})`, `commit_views::rev(Config(..))` | `Config { reason: "k", hints: ["h"] }` | — |
| Push commit check | repo `revset-aliases.'immutable_heads()' = 'b-mar'`, `git push` (bare) vs `jj git push` | `MutateError::RevsetResolutionError`, reason and hints equal the CLI's `Error:` text and `Hint:` lines | `jj.revset_resolution_error`; no operation |
| Presets into a non-table parent | `write_repo_presets` on a file holding `[remotes]\norigin = "x"` with a `fetch_tags` preset | refuses `ConfigError::Load` naming `remotes.origin`; file bytes unchanged | no panic |
| Remote writer on the same file | `rename_remote_in_repo_config(origin→upstream)` with `remotes.origin = "x"` and `trunk()` = `main@origin` | succeeds: `upstream = "x"`, `trunk()` = `main@upstream` | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/mutate.rs:616-648` -- `cfg` (renders Display) → `e.into()`; its doc and `From`'s doc ("unlike [`cfg`] …") updated; `rev`'s config arm (`:664`) follows automatically.
- `crates/zanshin-jj/src/mutate.rs:2245-2264` -- inline test `config_conversions_keep_a_config_faults_hints` pins `reason == "config error: k"` → `"k"`; doc line too. `:2308` comment stays true.
- `crates/zanshin-jj/src/file.rs:279-284` -- `cfg` → destructure `ConfigError::Load { reason, hints }`; inline tests at `:848`.
- `crates/zanshin-jj/src/commit_views.rs:262-267` -- config arm → `Config(crate::ConfigError::Load { reason, hints }) => CommitViewError::Config { reason, hints }`; inline test `:729-735` tightens `reason.contains("not a table")` → `reason == "not a table"`.
- `crates/zanshin-jj/src/push.rs:591-595` -- commit check: `.map_err(cfg_text)` → `.map_err(rev)`; comment cites `push.rs:834-836` @ v0.47.0 and `From<RevsetResolutionError>` (hints). `:595` is push.rs's only `cfg_text` call: drop it from the `use` at `:64`.
- `crates/zanshin-jj/src/push.rs:1493-1496` -- comment "`cfg` would prepend `config error: `" becomes false: use `.map_err(cfg)` and drop the comment.
- `crates/zanshin-jj/src/repo.rs:2022-2027` -- `git_push` `# Errors`: move "`immutable_heads()` does not resolve" from the `Config` bullet to the `RevsetParseError`/`RevsetResolutionError` bullet (at the commit check).
- `crates/zanshin-jj/tests/it/push.rs:1109-1139` -- `an_unresolvable_immutable_alias_at_the_commit_check_keeps_jj_libs_text`: expect `MutateError::RevsetResolutionError { reason, .. }`, rename the test, doc @ v0.47.0 lines.
- `crates/zanshin-jj/tests/it/snapshot_precondition.rs:319-339` -- add `!reason.starts_with("config error: ")` witness (outermost Rust surface of the `cfg` path).
- `crates/zanshin-parity/tests/oracle/hints.rs` -- (a) `wrong_typed_snapshot_key_carries_the_cli_check_the_config_file_hint` (`:530-548`): also compare the whole text: `config_refusal(&err.to_string(), err.hints())` == `cli_error_labeled("Config error: ", &["status"], &root)`; (b) new witness for item 2 next to the push hints: `pushed_repo()` + `jj config set --repo "revset-aliases.'immutable_heads()'" b-mar`, `cli_error(&["git","push"], &root)` vs Zanshin's `git_push(&GitPushArgs::default(), &|_| {}, None)` → `RevsetResolutionError { reason, hints }` equal; assert the CLI gave ≥1 hint. Module doc line 3-9 mentions the new witness.
- `crates/zanshin-jj/src/config.rs:2231-2242` -- `write_error` doc corrected (see Approach (3)); `env_layer` doc (`:660-664`) already names the middle-node case — leave it.
- `crates/zanshin-jj/src/config.rs` tests (`:4220-4256` neighbourhood; helpers `repo_config`, `load`, `read_back`, `FRESH_FILE_HEADER`) -- new test for the matrix's last two rows; `RepoPresets { remote: "origin", fetch_bookmarks: None, fetch_tags: Some(&[..]), trunk: None }`; loader `|| Ok(Some(load(&path)))`.
- `docs/rust-error-codes.md:58` (`jj.config_error` row) -- replace "`zanshin_git_push`'s commit check keeps jj-lib's bare text, as the CLI's (`cli/src/commands/git/push.rs:803-805` resolves with a plain `.resolve()?`)" with the new code; add one sentence: the context never carries the `config error: ` label (every path, since this run). `:57` (`jj.revset_resolution_error` row) -- one sentence: also `zanshin_git_push`'s commit check for an `immutable_heads()` that does not resolve, with the CLI's hints. `docs/ffi-abi.md:720` already lists `jj.revset_resolution_error` for push.
- Read-only evidence: jj-lib 0.47.0 `src/config.rs:425-490` (`set_value`/`delete_value`); CLI v0.47.0 `cli/src/commands/git/mod.rs:155-262` (`write_repo_presets` `.expect`, remote writers), `cli/src/command_error.rs:858-865` (`From<RevsetResolutionError>`), `cli/src/commands/git/push.rs:337,360,384,506` (validator built unconditionally per remote).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/mutate.rs` -- `cfg` = `From`; docs; inline test -- item 1, one conversion.
- `crates/zanshin-jj/src/file.rs`, `crates/zanshin-jj/src/commit_views.rs` -- bare reason; inline test assertions (add one for `file::cfg`) -- item 1.
- `crates/zanshin-jj/src/push.rs`, `crates/zanshin-jj/src/repo.rs` -- `rev` at the commit check; `cfg` at `:1496`; `git_push` errors doc -- items 1–2.
- `crates/zanshin-jj/tests/it/push.rs`, `tests/it/snapshot_precondition.rs` -- updated / added witnesses -- items 1–2.
- `crates/zanshin-parity/tests/oracle/hints.rs` -- full-text snapshot witness; push commit-check resolution witness -- CLI parity at the outermost surface.
- `crates/zanshin-jj/src/config.rs` -- `write_error` doc; unit test -- item 3.
- `docs/rust-error-codes.md` -- rows 57/58 -- registry follows the codes.

**Acceptance Criteria:**
- Given any config fault that reaches `jj.config_error` through `cfg`, `From`, `file::cfg` or `commit_views::rev`, when it is converted, then its reason is the `ConfigError`'s bare reason and its hints are kept.
- Given the matrix rows, when each runs, then the outcome matches the row; the oracle witnesses show Zanshin's text and hints equal the pinned CLI's.
- Given the targeted checks of § Verification, when run, then all pass and `cargo fmt --all --check` / clippy are clean.

## Spec Change Log

- 2026-11-16 (implementation): the oracle's whole-text witness for the wrong-typed snapshot knob showed a second gap beyond the label — `config::value_error` joined the source chain with `: ` where the CLI prints `\nCaused by: …` (`print_error_sources`). Fixed in `value_error` (the existing `warning::caused_by` renderer), pinned by a unit assertion; `rust-error-codes.md` row 58 says so. `config.rs`'s test helper `load` already returns `Option<ConfigFile>`, so the presets loader is `|| Ok(load(&path))`.

## Review Triage Log

### 2026-11-16 — Review pass
- verdicts: 21 findings — high 0, medium 0, low 19, false 1, maybe-false 1
- findings:
  - `[low]` `[patch]` blind: `zanshin_git_push`'s FFI `# Errors` doc (`crates/zanshin-ffi/src/push.rs:346`, header, `bindings.dart`) still lists an unresolvable `immutable_heads()` under `jj.config_error` — moved to the `jj.revset_resolution_error` bullet; `cargo make codegen` regenerated the header and bindings.
  - `[maybe-false]` `[reject]` blind: four `cfg_text` sites (`colocation.rs:226`, `workspace_ops.rs:104`, `remote_changes.rs:120`, `workspace_add.rs:180`) render a wrong-typed `git.executable-path` without `Caused by:` or hint — jj-lib's git backend factory reads that key at workspace load and the pre-verb snapshot reloads the stack first, so the fault refuses through `load_config_fault` before these sites; settling it needs a path where the key changes between that reload and the verb. Would be low; pre-existing.
  - `[low]` `[patch]` blind: `cfg_text`'s doc still names a revset failure, whose last caller (the push commit check) this run removed — doc now names a message, a trailer parse error and a `ConfigGetError`.
  - `[low]` `[patch]` blind: the new row-58 sentence claims the `Caused by:` form for every wrong-typed value — narrowed to values looked up through `value_error` (after the load); the no-label rule stays for every path.
  - `[low]` `[reject]` blind: the `value_error` change is wider than the spec's Intent and the Dart suites did not run — its fix would edit this spec; it is the CLI's text, pinned by the oracle's whole-text witness; no Dart file changed and no Dart or app test pins "Invalid type or value" (searched).
  - `[low]` `[reject]` blind: the spec's Verification lines pass several test filters to one `cargo test` — fix edits the spec; the commands actually run are recorded under Auto Run Result.
  - `[low]` `[reject]` blind: the Code Map's loader `|| Ok(Some(load(&path)))` contradicts the Change Log — fix edits the spec; the Change Log is the record.
  - `[low]` `[patch]` blind: the oracle module doc's sentence is garbled — reworded.
  - `[low]` `[patch]` blind: `env_layer`'s doc names only the middle-node failure and calls its keys "distinct" — now both failure modes and "no key is a prefix of another".
  - `[low]` `[patch]` blind: `write_repo_presets`' `# Errors` misses the non-table-parent refusal the new test pins — added (not reachable through the public API). Its `mod.rs:155-193` citation still holds at v0.47.0.
  - `[low]` `[defer]` blind: the push sheet shows a refused push's `context` only, never its hints (`push_sheet.dart:261-264`) — pre-existing UI; UI code only inside a story.
  - `[low]` `[defer]` blind: `convert.rs:567-569` puts the labelled `ConfigError` Display into `jj.convert_failed` and is not recorded — pre-existing, a different code than the items; deferred and mirrored.
  - `[low]` `[patch]` blind: the row-58 sentence sits mid-row — moved next to the Story 9.60 closing run's format statement (with the narrowing above).
  - `[low]` `[patch]` blind: `caused_by`'s doc cites `command_error.rs:1068-1084` without a tag; `value_error` now relies on it — `:1241-1257` @ v0.47.0.
  - `[low]` `[reject]` blind: `snapshot_precondition`'s witness checks only that the label is gone — the oracle compares the real snapshot path's whole text with the CLI and the unit test pins the format; a third copy adds nothing.
  - `[low]` `[patch]` edge: same as the first row (FFI push doc + generated bindings) — same fix.
  - `[low]` `[patch]` edge: the registry claim does not hold for `build_aliases_map`'s non-table alias table — same narrowing as the row-58 fix.
  - `[low]` `[patch]` edge: nor for `migrate`'s one-line text — same narrowing.
  - `[low]` `[reject]` edge: `value_error`'s cross-cutting change goes unreviewed against the spec — same as the blind row: the fix edits the spec; the change is CLI parity, oracle-pinned.
  - `[low]` `[defer]` verification-gap (other finding): `file_error`'s text ("<path>: …: …") differs from the CLI's message + `Caused by:` — pre-existing; deferred with `migrate`, the alias table and `workspace_value_error` as one entry, mirrored. No gaps reported.
  - `[false]` `[reject]` intent-alignment (side note): `zanshin-ffi/src/graph.rs:45` drops a config fault's hints — `map_topology_err` reads `e.hints()` before the match; the `None` there is the revset detail. The audit's other notes are descriptive: the wire is reached through the unchanged `map_*_err` arms, item 3 is measured at the public API, Auto Run Result and commits are settled in Finalize.

## Design Notes

- Item 3 is a doc-only correction: the `ConfigUpdateError` instantiation is not reachable through the public API — the presets go only into the new repo's freshly created file (random `config-id`), and the remote writers write `trunk()` only after finding it as a string. The CLI asserts the same with `.expect(…)` (it would panic); Zanshin's refusal is the non-panicking equivalent, so no behavior changes.
- Item 2 witness symbol `b-mar` (next to `b-mark`) makes jj-lib's `NoSuchRevision` carry candidates, so the CLI prints a "Did you mean" hint and the oracle compares a non-empty hint list.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib mutate:: file:: commit_views:: config::` -- pass
- `cargo test -p zanshin-jj --test it push:: snapshot_precondition:: git_fetch_parity::` -- pass
- `cargo test -p zanshin-jj` (whole crate; label changes can surface anywhere) -- pass
- `cargo test -p zanshin-ffi` -- pass (no FFI change; dependents' config-error tests)
- `cargo test -p zanshin-parity --test oracle hints::` then the whole `--test oracle` -- pass
- `cargo clippy -p zanshin-jj -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- clean

## Auto Run Result

Status: done. Code commit `ca4886a423e5e52a39327e4e087038c4bea308d4` (the review patches included); this spec and the `deferred-work.md` mirror are in the commit that adds this spec.

**Items:**
1. **Fixed** (ca4886a4) — every `ConfigError` reaches `jj.config_error` with its bare reason and its hints: `mutate::cfg` = `From`, `file::cfg` and `commit_views::rev` destructure the reason, `plan_push` uses `cfg`. The oracle's whole-text witness (`wrong_typed_snapshot_key_carries_the_cli_check_the_config_file_hint`) also showed `value_error` joined the cause with `: ` where the CLI prints `\nCaused by: …`; `value_error` now renders the CLI's form (`warning::caused_by`), so a wrong-typed or missing value's context equals the CLI's `Config error:` text without the label. Other config faults keep their old text (new deferral 1).
2. **Fixed** (ca4886a4) — the push commit check maps `immutable_heads()`'s resolution failure through `mutate::rev`: `jj.revset_resolution_error` with the CLI's hints, nothing written; oracle `unresolvable_immutable_heads_at_the_push_commit_check_refuses_with_the_cli_error_and_hints` compares text and hints with the pinned CLI. Registry rows 57/58, `Repo::git_push` and `zanshin_git_push` docs (header and Dart bindings regenerated) follow.
3. **Fixed** (ca4886a4), doc correction — the claim was real: `set_value` also fails on a non-table middle node. The `ConfigUpdateError` instantiation is still unreachable through the public API (presets go only into a new repo's fresh file; the remote writers write `trunk()` only after finding it as a string; `env_layer`'s fixed keys are no prefix of each other). The CLI `.expect`s the same writes (`cli/src/commands/git/mod.rs:155-193` @ v0.47.0) and would panic; Zanshin refuses instead (no panic on FFI-reachable paths), so there is no CLI behavior to copy. The kept unit test `a_preset_below_a_non_table_remote_refuses_while_the_rename_writer_succeeds` pins the refusal (node named, nothing saved) and that the rename writer succeeds on the same file. `write_error`, `env_layer` and `write_repo_presets` docs corrected.

**Files changed:** `crates/zanshin-jj/src/{mutate,file,commit_views,push,repo,config,warning}.rs` (conversions, commit check, `value_error`, docs, unit tests); `crates/zanshin-jj/tests/it/{push,snapshot_precondition}.rs` (witnesses); `crates/zanshin-parity/tests/oracle/hints.rs` (two CLI witnesses); `crates/zanshin-ffi/src/push.rs` + generated `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart` (push error doc); `docs/rust-error-codes.md` (rows 57/58); ledger: `deferred-work.md` (new section, three new findings).

**Review:** 21 findings — 0 high, 0 medium, 19 low, 1 false, 1 maybe-false. Patched (all low): the FFI push doc + regenerated bindings, `cfg_text`'s doc, the over-broad and misplaced registry sentence (narrowed to `value_error`), the oracle module doc wording, `env_layer`'s doc, `write_repo_presets`' `# Errors`, `caused_by`'s CLI citation. Deferred (all low, mirrored to `deferred-work.md` under "Surfaced in the 9.60 / 11.28 leftover run"): config faults outside `value_error` keep a non-CLI text; the push sheet never shows a thrown push error's hints; conversion's alias step puts the labelled Display into `jj.convert_failed`. Rejected with reasons in the triage log: the four `cfg_text` git-option sites (unreachable before the load refuses), the `value_error` scope / spec-wording findings (fixes edit this spec), an extra exact-text witness (duplicates the oracle), and the false `graph.rs:45` note. Follow-up review: not recommended (no high or medium patched; patched counts: low 7 entries, 11 rows).

**Verification run (targeted only, no full gate per the run's gate rule):**
- `cargo test -p zanshin-jj` — 461 unit + 1572 integration passed (1 ignored); after the doc patches `--lib` 461 passed.
- `cargo test -p zanshin-ffi` — 246 unit + 413 integration passed; after the patches `--lib` 246 passed.
- `cargo test -p zanshin-parity --test oracle` — 568 passed; after the patches `hints::` 22 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean.
- `cargo make codegen` — run by the implementer; only the push doc block changed in the header and bindings; committed.
- `packages/zanshin_core`: `dart analyze --fatal-infos` and `dart format --set-exit-if-changed` on `lib/src/ffi/bindings.dart` — clean. No other Dart file changed; no Dart or app test pins the changed context texts (searched "Invalid type or value", "config error").
- The Verification lines above with several test filters were run as single-filter or whole-crate runs (cargo takes one filter); the outcomes listed here are the runs made.

**Residual risks:** the `value_error` change turns every wrong-typed or missing config value's wire context into the CLI's multi-line text; the UI shows `context` as is, so such a note now spans two lines (not checked in the running app). No FFI- or Dart-level test exercises the push commit-check refusal's code and hints; they follow the unchanged generic `map_mutate_err` arm.
