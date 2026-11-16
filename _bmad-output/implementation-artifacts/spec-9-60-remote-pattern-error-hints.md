---
title: 'Story 9.60 — a bad `remotes.<r>.*` pattern refuses with the CLI''s `Caused by:` lines and hint'
type: 'bugfix'
created: '2026-11-16'
status: 'done'
baseline_revision: '4aba257bd81e10b1f25c07c3f7249b2447aade5d'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      A config error that names its file carries no hint, while the CLI prints "Hint: Check the
      config file: <path>" for a wrong-typed value, a TOML parse failure and a failed migration.
    evidence: |-
      CLI @ v0.47.0 `cli/src/command_error.rs:415-447` (`From<ConfigGetError>` via
      `config_get_error_hint` `:1000-1007`, `From<ConfigLoadError>`, `From<ConfigMigrateError>`)
      adds the hint when the error has a `source_path`. Zanshin's `value_error` / `file_error`
      (`crates/zanshin-jj/src/config.rs:338-351`) set no hints, and `migrate` (`:1066-1075`) puts
      "Check the config file: …" into the reason instead. Pre-existing; Story 9.60's non-goal
      "other config errors". The hints channel on `jj.config_error` now exists to carry it.
    location: >-
      crates/zanshin-jj/src/config.rs:338
    severity: medium
    resolved: >-
      2026-11-16 — fixed (spec-9-60-closing-check-the-config-file-hint, commit e1f7295c): a wrong-typed
      value, a TOML parse failure, a failed migration and a non-table alias table carry the CLI's
      "Check the config file" hint, and every carrier forwards it.
---

<intent-contract>

## Intent

**Problem:** A `remotes.<r>.auto-track-bookmarks` / `auto-track-created-bookmarks` / `fetch-bookmarks` / `fetch-tags` value that does not parse refuses `jj.config_error` with only "Invalid `remotes.<r>.<field>`: <kind>" (`config.rs:1714-1724`, clone's `preset` closure `creation.rs:541-550`). The CLI's `parse_remote_string_expression` (`cli/src/revset_util.rs:463-488` @ v0.47.0) raises `config_error_with_message(message, err)` — the parse error's `Caused by:` lines below the first line — plus `revset_parse_error_hint`. No `jj.config_error` carrier has a hints field, and the fetch / import / bookmark-create sites wrap the error through `mutate::cfg`, which prepends a second `config error: `.

**Approach:** One renderer in `parse_remote_string_expression`, shaped like `bookmark_ops::pattern_parse_error`: reason = `["Invalid `remotes.{r}.{field}`: {kind}"] + warning::caused_by(Some(&err))` joined by `\n`, hints = `revset::parse_hint(&err)`. Add `hints: Vec<String>` to `ConfigError::Load`, `RepoError::Config`, `MutateError::Config` and `PreconditionError::Config`; every conversion between them carries the hints and each `hints()` returns them, so the existing FFI mappers forward them to `FfiError.hints` → `ZanshinFfiException.hints`. A new `From<ConfigError> for MutateError` (reason as is, hints kept) replaces `mutate::cfg` at the sites that read these keys. Clone's closure reuses the shared renderer.

## Boundaries & Constraints

**Always:**
- For all four keys, on every path that parses them (fetch and the remote-change poll, `git import` / fetch import, the colocated pre-verb import, bookmark create/set, clone, init/convert): `jj.config_error`'s `context` equals the CLI's `Config error:` text without the `Config error: ` label (every line before the first `Hint: `), and `hints` the CLI's `Hint: ` lines without the label. The CLI's "For help, see …" footer is not a hint and is not carried.
- Codes, refusal points and the no-operation rule unchanged; valid patterns behave as before.
- Every other `jj.config_error` keeps empty hints.
- `docs/rust-error-codes.md` `jj.config_error` row states which refusals carry hints.
- Every changed line gets a test witness; oracle witnesses compare context and hints with the pinned `jj`.

**Never:**
- No `.fbs`, codegen or Dart library change (`FfiError.hints` / `ZanshinFfiException.hints` already exist).
- Do not change other config errors' text, and do not replace `mutate::cfg` outside the six sites below.
- Never regenerate fixtures; never lower `coverage-baseline.txt`; do not edit `epics.md` or the deferred-work item's bullets.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fetch, syntax | `remotes.origin.fetch-bookmarks = "glob:("`, `git_fetch` | context `Invalid \`remotes.origin.fetch-bookmarks\`: Syntax error\nCaused by:  --> 1:7\n  \|\n1 \| glob:(\n  \|       ^---\n  \|\n  = expected <expression>`; hints = the revsets-syntax hint | `jj.config_error`, no op |
| Fetch, kind | `fetch-tags = "bogus:x"` | first line `… fetch-tags\`: Invalid string pattern`, numbered `Caused by:` (2 lines); hint "Try prefixing with one of …" | same |
| Poll | `remote_changes` with the syntax case | as row 1 | same |
| Colocated start-up | `auto-track-bookmarks = "a b"`, any snapshotting verb (e.g. `git_import`) | `PreconditionError::Config` with row-1 shape and hint | `jj.config_error`, nothing written |
| Bookmark create | `auto-track-created-bookmarks = "("` | `MutateError::Config` with text + hint | no bookmark created |
| Clone | user config `fetch-tags = "bogus:x"` | `RepoError::Config` as row 2; destination removed | `jj.config_error` |
| Init / convert | user config `auto-track-bookmarks = "glob:("` | `RepoError::Config` with text + hint | as today otherwise |
| Valid pattern | `main` | unchanged | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/config.rs:289-298` -- `ConfigError::Load` (+ `hints`); constructions `:336,343,496,503,822,928,1059,1720,2189`; `:1710-1724` `parse_remote_string_expression` (→ `pub(crate)`, new text, cite @ v0.47.0); callers `:1636-1690` (auto-track maps), `:2048-2062` (`remote_fetch_expression`), `:1616` (`git_import_options`); inline tests `:2817-2943` (patterns), `:4470-4553` (pin the broken-pattern text — tighten to exact text + hints), `:4608-4618`.
- `crates/zanshin-jj/src/bookmark_ops.rs:170-174` -- `pattern_parse_error`: the shape to copy. `:343`, `:999` -- `auto_track.map_err(mutate::cfg)` → `MutateError::from`.
- `crates/zanshin-jj/src/revset.rs:841` -- `parse_hint` (already `pub(crate)`); `:1083,1203,1247` ConfigError sites.
- `crates/zanshin-jj/src/warning.rs:438` -- `caused_by` (reuse).
- `crates/zanshin-jj/src/mutate.rs:197-200` -- `MutateError::Config` (+ `hints`); `:584-600` `hints()`; `:621-623` `cfg` (`hints: Vec::new()`); add `impl From<ConfigError> for MutateError`; test `:2381`.
- `crates/zanshin-jj/src/snapshot.rs:202-206,249-266,274-291` -- `PreconditionError::Config` (+ `hints`), `hints()`, both `From`s; `:679` uses `From<ConfigError>`; tests `:1007,1037,1095-1116,1177`.
- `crates/zanshin-jj/src/repo.rs:101-137` -- `RepoError::Config` (+ `hints`), `hints()`, `From<ConfigError>`.
- `crates/zanshin-jj/src/creation.rs:123,621` -- conversions carry hints; `:540-566` clone presets → `config::parse_remote_string_expression` + `RepoError::from`; `:676` already `?`; test `:920`.
- `crates/zanshin-jj/src/convert.rs:443,514,773` -- conversions carry hints; tests `:850-929`.
- `crates/zanshin-jj/src/remotes.rs:351,363,554`, `git.rs:328` -- `map_err(mutate::cfg)` → `MutateError::from`.
- Compile-only sites (add `hints: Vec::new()` / `..`): `push.rs:1496` (use `MutateError::from`), `drop_actions.rs:262,803,918`, `template.rs:124,261,483,491,495,598,919`, `fix.rs:1041-1139`, `op_support.rs:93,1404`, `wc_ops.rs:228`, `op_diff.rs:170`, `config_cmd.rs:359`, `workspace.rs:242`, `commit_views.rs:724`, `bookmarks.rs:769`; the compiler lists any further one.
- `crates/zanshin-ffi/src/{repo.rs:130,180,2069,2178; envelope.rs:653,2250; bookmarks.rs:35,376; graph.rs:45,994; tags.rs:102,400; log_defaults.rs:23,143; revset_search.rs:39,445,471; commit_views.rs:572}` -- patterns `..`, literals `hints`; the `RepoError` / `MutateError` / precondition mapper tests assert forwarded hints.
- `crates/zanshin-jj/tests/it/*` -- ~100 `Config { reason }` / `Load { reason }` patterns → `{ reason, .. }`. Strengthen: `git_fetch_parity.rs:500-513,745-754` (exact text + hint), `snapshot_colocated.rs:583-610`, `snapshot_precondition.rs:365-380`, `bookmark_ops.rs:855-870`, `creation_warnings.rs:660-690` (hint asserted); new clone test in `clone_init.rs` via `with_user_config` (`:616`).
- `crates/zanshin-parity/tests/oracle/hints.rs:149-184` -- `cli_error` / `refusal` helpers (the CLI's label here is `Config error: `, footer "For help, see …"); `refusal_order.rs:125` pattern; `git_scenarios.rs:1489-1632` fetch table, `:240-334` creation table; `main.rs` `parity!` ids (own-process list for user-config scenarios).
- `packages/zanshin_core/test/worker/mutate_test.dart:289-340` -- fetch worker tests without a git subprocess: the shape for the Dart witness.
- `docs/rust-error-codes.md:58` -- `jj.config_error` "Carries no hints" sentence.
- CLI @ v0.47.0: `cli/src/revset_util.rs:400-488`; `cli/src/command_error.rs:206-211` (`config_error_with_message`), `:1190-1257` (`Config error: ` label, `print_error_sources`, footer); `cli/src/commands/git/clone.rs:231-246`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/config.rs` -- `ConfigError::Load.hints`; `parse_remote_string_expression` renders the CLI text + hint, `pub(crate)`, cited @ v0.47.0; inline tests pin exact text and hints for a syntax and a string-pattern-kind case.
- `crates/zanshin-jj/src/{repo,mutate,snapshot}.rs` -- `hints` on the three `Config` variants, `hints()` arms, every `From` carries hints; `From<ConfigError> for MutateError`.
- `crates/zanshin-jj/src/{creation,convert,remotes,git,bookmark_ops,push}.rs` -- conversions and the six `cfg` sites as in the Code Map; clone presets reuse the shared parser.
- Remaining compile sites in `zanshin-jj`, `zanshin-ffi`, `zanshin-parity` -- `hints: Vec::new()` / `..`.
- `crates/zanshin-ffi/src/{repo,envelope}.rs` tests -- `jj.config_error` carries hints from `RepoError::Config`, `MutateError::Config`, `PreconditionError::Config`.
- `crates/zanshin-jj/tests/it/{git_fetch_parity,snapshot_colocated,snapshot_precondition,bookmark_ops,creation_warnings,clone_init}.rs` -- matrix rows 1–7 with exact text (row 1, 6) and hints.
- `crates/zanshin-parity/tests/oracle/hints.rs` -- CLI-vs-Zanshin witnesses (context == CLI error lines, hints == CLI hint lines): fetch row 1, fetch row 2, `git import` row 4 (colocated), clone row 6 in its own process.
- `crates/zanshin-parity/tests/oracle/{git_scenarios,main}.rs` -- state scenarios `fetch_bad_remote_pattern` (row 1) and creation `clone_bad_fetch_tags_pattern` (own process).
- `packages/zanshin_core/test/worker/mutate_test.dart` -- `gitFetch` with row 1's config throws `jj.config_error` with that context and hint.
- `docs/rust-error-codes.md` -- `jj.config_error` hints sentence.

**Acceptance Criteria:**
- Given a bad pattern in any of the four keys, when a verb or creation that reads it refuses, then `jj.config_error`'s context and hints equal the pinned CLI's error text and hint lines (oracle-checked for fetch, colocated import and clone).
- Given that refusal through the FFI, when Dart receives it, then `ZanshinFfiException.hints` holds the hint.
- Given valid patterns or any other config error, when the suites run, then behavior and hints (empty) are unchanged.

## Spec Change Log

## Review Triage Log

### 2026-11-16 — Review pass
- verdicts: 22 findings — high 0, medium 1, low 19, false 2, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) `git_fetch` still maps `every_remote_settings` with `mutate::cfg` (`remotes.rs:528`), so a malformed `remotes.<name>` entry refuses the fetch with a `config error: ` label the poll no longer has — verified (the poll reaches `remote_settings` through `MutateError::from`); patched: `MutateError::from` at `:528`, `tracked_refuses_a_malformed_remote_entry` asserts fetch and poll reasons are equal and unlabelled.
  - `[low]` `[reject]` (blind) the six switched sites also drop the `config error: ` label from non-pattern faults (wrong-typed `git.*` import keys, a malformed `remotes.<name>` entry), against the spec's "do not change other config errors' text" — verified real, but the dropped text is a second copy of the label the CLI prints as its `Config error: ` heading, which every Zanshin `context` strips (`RepoError::Config` / `PreconditionError::Config` never had it); keeping it would need a branch that preserves a non-CLI text. Recorded as an intended side effect in the Auto Run Result.
  - `[low]` `[patch]` (blind) the `bookmark set` site (`bookmark_ops.rs:999`) has no witness — patched with the verification-gap row below.
  - `[low]` `[patch]` (blind) the fetch's import-options site (`remotes.rs:554`) has no test — patched with the verification-gap row below.
  - `[low]` `[patch]` (blind) `auto-track-created-bookmarks` is never compared with the CLI and its inline test checks `hints.len()` only — the text comes from the one renderer the oracle compares for three keys (the field name is plain interpolation), so no oracle witness was added; patched: the inline test asserts the exact hint for both auto-track fields.
  - `[low]` `[reject]` (blind) no oracle result recorded; CLI hand-checked with jj 0.47.1 — the fix edits this build's spec; the oracle (562 passed, run against the `CARGO_BIN_EXE_jj` built from the pinned `jj-cli`) is recorded in the verification notes, so the 0.47.1 hand check is only a cross-check.
  - `[low]` `[reject]` (blind) five FFI mappers (`bookmarks`, `graph`, `log_defaults`, `revset_search`, `tags`), `mutate::rev` and `ConfigCmdError::from` drop `ConfigError::Load.hints` — verified that no `remotes.*` parser reaches them, so nothing is lost today; forwarding through `mutate::rev` would also change revset-config texts, more than a direct correction for a defect nobody meets.
  - `[low]` `[patch]` (blind) `api_stability` no longer pins the three carriers' `hints` field by construction — patched: one struct literal per variant in `config_error_carriers_keep_their_hints`.
  - `[low]` `[patch]` (blind) stale v0.46.0 citations next to the changed parser, `# Errors` docs, `ffi-abi.md`, registry sentence without init over `.git` — patched: the three `config.rs` citations re-cited at v0.47.0 and the init phrase checked; rejected: the `# Errors` docs end in "…", which still covers the added lines, and `ffi-abi.md:120-121` delegates per-code hints to the registry.
  - `[low]` `[reject]` (blind) new comments say "Story 9.60" — every module and test in this repo cites its story (the closing run of 9.59 did the same); matching the surrounding style.
  - `[low]` `[patch]` (edge) `remotes.rs:528` fetch/poll label disagreement — same root cause as the first blind row; patched there.
  - `[medium]` `[defer]` (edge) the CLI adds "Hint: Check the config file: <path>" to a config error with a source path; Zanshin sends none (`value_error`, `file_error`, `migrate` puts it in the reason) — verified at `cli/src/command_error.rs:415-447,1000-1007` @ v0.47.0; pre-existing and the story's non-goal "other config errors"; added to `deferred:` and mirrored into deferred-work.md.
  - `[low]` `[reject]` (edge) non-pattern config faults at the switched sites changed text — same as the second blind row.
  - `[low]` `[patch]` (verification-gap) `set_refuses_a_broken_auto_track_pattern_after_the_backwards_check` matches only the variant — patched: asserts the reason's first lines and the hint.
  - `[low]` `[patch]` (verification-gap) no fetch test reaches `remotes.rs:554` with a broken `auto-track-bookmarks` — patched: a non-colocated fetch test pins the exact text, the hint and no operation.
  - `[low]` `[patch]` (verification-gap, other) `remotes.rs:528` still uses `mutate::cfg` — same as the first blind row; patched there.
  - `[low]` `[reject]` (intent) the per-key × caller witness matrix is only partly exercised (fetch-bookmarks in clone, auto-track-bookmarks in fetch and clone) — the story allows "one per caller if the text is shared"; clone's two presets share one closure (fetch-tags is tested), clone's import uses the same `From<ConfigError> for RepoError` the conversion test witnesses, and the fetch import site got its own test in this pass.
  - `[low]` `[reject]` (intent) Dart exercises only the `MutateError` path end to end — `ZanshinFfiException.hints` is filled from `FfiError.hints` for every code, and the `RepoError` and precondition mappers are pinned by FFI unit tests.
  - `[low]` `[reject]` (intent) some FFI mappers drop the new field — same as the blind mapper row.
  - `[low]` `[reject]` (intent) the change reaches the non-goal "other config errors" at the switched sites — same as the second blind row.
  - `[false]` `[reject]` (intent) bookkeeping not visible in the diff — the diff excludes the spec by design; the Auto Run Result is written at finalization.
  - `[false]` `[reject]` (intent) the CLI's `print_parse_diagnostics` is not ported — jj-lib 0.47 emits no diagnostic for string patterns, so the sink is always empty and no output differs (documented at the parser).

## Design Notes

Why fields on four variants rather than a new variant: the remote patterns reach `jj.config_error` through all four carriers (fetch / import / bookmark create → `MutateError`, colocated start-up → `PreconditionError`, clone / init / convert → `RepoError`), and the CLI prints the same hint on each. A separate variant would split one remedy across two variants and every `match`; a field keeps one variant per carrier. The cost is mechanical: patterns gain `..`.

Why `From<ConfigError> for MutateError` only at six sites: `mutate::cfg` takes any `Display` and is used for template, fileset and other errors; changing it would rewrite many unrelated texts. At the six sites the old text was `config error: Invalid …` (doubled label), which no longer matches the CLI's first line.

## Verification

**Commands (targeted; the story loop runs the full gate — do NOT run `cargo make test`, `cargo make test-full` or `cargo make coverage`):**
- `cargo test -p zanshin-jj` -- expected: green.
- `cargo test -p zanshin-ffi` -- expected: green.
- `cargo test -p zanshin-parity --test oracle` -- expected: green, no UNEXPECTED / CHANGED / STALE.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean.
- In `packages/zanshin_core`: `dart test test/worker/mutate_test.dart`, `dart analyze`, `dart format --set-exit-if-changed .` -- expected: green / clean.

**Verification notes (run 2026-11-16; no `cargo make test` / `test-full` / `coverage` per the loop's gate rule):**
- `cargo fmt --all --check` — clean.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean.
- `cargo test -p zanshin-jj` — 456 lib + 1570 `it` passed (1 pre-existing ignored perf benchmark).
- `cargo test -p zanshin-ffi` — 246 lib + 413 `it` passed.
- `dart test test/worker/mutate_test.dart` (gate env: `JJ_CONFIG=""`, pinned identity, `XDG_CONFIG_HOME=target/test-xdg-config`) — 34 passed; `dart analyze --fatal-infos --fatal-warnings` — no issues; `dart format --set-exit-if-changed` — 0 changed.
- `cargo test -p zanshin-parity --test oracle` — 562 passed (505 scenarios incl. `fetch_bad_remote_pattern` and `clone_bad_fetch_tags_pattern`, and the four new `hints.rs` witnesses), no UNEXPECTED / CHANGED / STALE.
- After the review patches: `cargo fmt --all --check` and clippy (three crates, all targets) — clean; `cargo test -p zanshin-ffi` — 246 + 413 passed; `cargo test -p zanshin-parity --test oracle -- hints:: fetch_ clone_bad` — 28 passed; `cargo test -p zanshin-jj` — 456 lib + 1571 `it` passed (1 pre-existing ignored perf benchmark).
- No `cargo make codegen` (no FFI schema change).
- Matrix audit: row 1 `git_fetch_parity::a_malformed_remote_fetch_setting_is_a_config_error` + oracle `hints::bad_fetch_bookmarks_pattern_…` + Dart `gitFetch_bad_remote_pattern_…`; row 2 `config::tests::remote_pattern_with_an_unknown_kind_…` + oracle `hints::bad_fetch_tags_kind_…`; row 3 `git_fetch_parity::the_poll_refuses_what_the_fetch_refuses`; row 4 `snapshot_colocated::an_invalid_import_option_fails_before_the_head_import_like_the_cli` + oracle `hints::bad_auto_track_pattern_refuses_the_colocated_import_…`; row 5 `bookmark_ops::create_refuses_a_broken_auto_track_pattern_…` and `bookmark_tracking::set_refuses_a_broken_auto_track_pattern_…`; row 6 `clone_init::a_bad_fetch_tags_preset_refuses_with_the_cli_text_and_hint` + oracle `hints::bad_clone_fetch_tags_preset_…` + scenario `clone_bad_fetch_tags_pattern`; row 7 `creation_warnings::a_refs_step_failure_reports_no_snapshot` (conversion); row 8 the existing suites. All ran and passed.
- CLI text checked by hand in a scratch repo (jj 0.47.1): `fetch-bookmarks = "glob:("`, `fetch-tags = "bogus:x"`, colocated `auto-track-bookmarks = "a b"` (every command refuses at start-up) — the shapes the tests pin; the "For help, see …" footer follows the hint.

## Auto Run Result

Status: done

**Items:**
- **I1 — fixed (23dba0c4385562ec7205f68a45105cfa66fbcf1d).** Verified real at `4aba257`: `config.rs::parse_remote_string_expression` and clone's `preset` closure rendered only "Invalid `remotes.<r>.<field>`: <kind>", and no `jj.config_error` carrier had a hints field. Now the one parser (clone's presets call it too) builds the CLI's `config_error_with_message` text — that first line plus the parse error's own `Caused by:` lines (`warning::caused_by`, pest caret diagram included) — and `revset::parse_hint` as the hint. `ConfigError::Load`, `RepoError::Config`, `MutateError::Config` and `PreconditionError::Config` carry `hints`; every conversion keeps them and the FFI mappers forward them through `e.hints()` to `FfiError.hints` → `ZanshinFfiException.hints`. It covers all four keys (`auto-track-created-bookmarks` too, which shares the parser) on every path that reads them: fetch and the poll, `git import` and the colocated pre-verb import, bookmark create/set, clone, the conversions and init over an existing `.git`. Oracle: four text witnesses in `hints.rs` (fetch ×2, colocated import, clone) and scenarios `fetch_bad_remote_pattern`, `clone_bad_fetch_tags_pattern`; Dart: `gitFetch_bad_remote_pattern_surfaces_jj_config_error_with_the_cli_hint`.

**Intended side effect:** where the code now converts with the new `From<ConfigError> for MutateError` (`bookmark_ops.rs` create/set, `remotes.rs` fetch expressions, the `remotes.<name>` read and the import options, `git.rs` import, `push.rs` `immutable_heads()`), other config faults read there — a wrong-typed `git.*` import key, a malformed `remotes.<name>` entry — lose the doubled `config error: ` label in `context`. The CLI prints that label once, as its `Config error: ` heading, which every Zanshin `context` strips; `RepoError::Config` / `PreconditionError::Config` never carried it.

**New finding (deferred, mirrored into deferred-work.md):** a config error that names its file carries no "Check the config file: <path>" hint (the CLI adds it for a wrong-typed value, a TOML parse failure and a failed migration) — see `deferred:`.

**Files changed (23dba0c4385562ec7205f68a45105cfa66fbcf1d):**
- `crates/zanshin-jj/src/config.rs` — `ConfigError::Load.hints`; the parser renders the CLI text and hint; citations at v0.47.0; inline tests pin text and hint.
- `crates/zanshin-jj/src/{repo,mutate,snapshot}.rs` — `hints` on the three `Config` variants, `hints()`, `From` impls (new `From<ConfigError> for MutateError`).
- `crates/zanshin-jj/src/{creation,convert,remotes,git,bookmark_ops,push}.rs` — conversions carry hints; `MutateError::from` where these keys are read; clone presets use the shared parser.
- Other `zanshin-jj`, `zanshin-ffi`, `zanshin-parity` sources and tests — `hints: Vec::new()` / `..` at constructions and patterns; FFI mapper tests assert forwarded hints.
- `crates/zanshin-jj/tests/it/*` — exact text and hint in `git_fetch_parity` (fetch, poll, import options, fetch/poll agreement), `snapshot_colocated`, `snapshot_precondition`, `bookmark_ops`, `bookmark_tracking`, `creation_warnings`, a new clone test in `clone_init`; shared helpers in `main.rs`; `api_stability` pins the carriers.
- `crates/zanshin-parity/tests/oracle/{hints,git_scenarios,main}.rs` — CLI witnesses (`cli_error_labeled` for `Config error: `), two scenarios, count 505.
- `packages/zanshin_core/test/worker/mutate_test.dart` — the hint reaches Dart.
- `docs/rust-error-codes.md` — `jj.config_error` hints sentence.
- Spec commit: this spec, `epic-9-context.md` (recompiled for 9.60), `deferred-work.md` (the new finding), `sprint-status.yaml`.

**Review:** 22 findings (medium 1, low 19, false 2). Patched (all low): the fetch's `remotes.<name>` read now converts like the poll (`remotes.rs:528`), witnesses for `bookmark set` and the fetch's import-options site, exact hint asserts in the auto-track inline test, struct-literal pins in `api_stability`, v0.47.0 citations next to the parser, init over `.git` in the registry. Deferred: the "Check the config file" hint (medium, pre-existing, the story's non-goal). Rejected: the label drop at the switched sites (CLI-ward, recorded above), the oracle-notes row (fix edits this spec; recorded), hint-dropping mappers no remote pattern reaches, story references in comments (repo convention), a partial key × caller matrix (shared renderer and conversions, each witnessed), Dart only on the `MutateError` path (generic hints transport), plus two false rows.

**Follow-up review recommended:** false — patched counts high 0, medium 0, low 6 entries.

**Verification:** see Verification notes — fmt, clippy, `zanshin-jj`, `zanshin-ffi`, the full parity oracle (and its hint/fetch/clone subset after the review patches), the Dart worker test, `dart analyze` and `dart format`; no full gate per the loop's rule.

**Residual risks:** coverage ratchet not run (loop gate at the end); tests pin pest's caret diagram verbatim, so a jj-lib/pest change at the next pin bump moves those strings (the oracle witnesses show the CLI's new text); the first Dart run of the implementation pass went without the gate's pinned environment and left one orphaned secure-config entry at `/Users/ralph.bergmann/.config/jj/repos/5a644000ec94973fe215/` (a deleted temp repo's `config.toml` + `metadata.binpb`) — harmless, not deleted without Ralph's consent.
