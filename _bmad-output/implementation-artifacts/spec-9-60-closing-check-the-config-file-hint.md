---
title: 'Story 9.60 closing run — a config error that knows its file carries the CLI''s "Check the config file" hint'
type: 'bugfix'
created: '2026-11-16'
status: 'done'
baseline_revision: '19e4dfba6c12c73e6ea9717f90b42a76e73e6e63'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      A config fault's `jj.config_error` context keeps a `config error: ` label on paths that
      convert through `mutate::cfg` (also `file::cfg`, `commit_views::rev`) and has none on paths
      that convert through `From<ConfigError>`, so one fault's context differs by path and the
      CLI's `Config error:` heading appears in-band.
    evidence: |-
      `crates/zanshin-jj/src/mutate.rs` `cfg` renders the `ConfigError` Display ("config error:
      <reason>"), `From<ConfigError> for MutateError` keeps the bare reason. A wrong-typed
      `snapshot.max-new-file-size` (`snapshot.rs` `SnapshotConfig::load`, `map_err(mutate::cfg)`)
      reaches the wire as "config error: Invalid type or value for …", a TOML parse error at open
      as "<path>: Configuration cannot be parsed …". The oracle helper `config_refusal`
      (`crates/zanshin-parity/tests/oracle/hints.rs:196-202`) says no carrier puts the label on
      the wire. Pre-existing since Story 9.60 added `From`; this run kept every reason text.
    location: >-
      crates/zanshin-jj/src/mutate.rs:619
    severity: low
  - summary: >-
      `git push`'s commit check maps an `immutable_heads()` resolution failure to
      `jj.config_error` without hints, while the CLI's bare `.resolve()?` raises a revset
      resolution error with its hints.
    evidence: |-
      `crates/zanshin-jj/src/push.rs:595-596` maps `resolve_expression`'s `RevsetError` through
      `cfg_text` (before this run the generic `cfg`, same result). CLI @ v0.47.0
      `cli/src/commands/git/push.rs:834-836` resolves with `.resolve()?`, which converts through
      `From<RevsetResolutionError>` with `revset_resolution_error_hints`. Pre-existing (Stories
      9.20 / 9.58).
    location: >-
      crates/zanshin-jj/src/push.rs:595
    severity: low
---

<intent-contract>

## Intent

**Problem:** Story 9.60's deferred item 1, verified at `19e4dfb`. The CLI (`cli/src/command_error.rs:415-447,1000-1007` @ v0.47.0) adds `Hint: Check the config file: <path>` to a `ConfigGetError::Type`, a `ConfigLoadError::Parse` and a `ConfigMigrateError` whose `source_path` is set. Zanshin's `value_error` / `file_error` (`crates/zanshin-jj/src/config.rs:338-351`) set no hints, `migrate` (`:1065-1076`) puts the line into the reason, and most carriers between `ConfigError` and `FfiError.hints` drop hints anyway (`mutate::cfg`, `FileError`/`CommitViewError`/`ConfigCmdError::Config`, `RevsetError::hints`, five FFI mappers). Probed with jj 0.47.1: the hint appears for a wrong-typed `snapshot.max-new-file-size` / `snapshot.auto-track` / `git.colocate`, a non-table `revset-aliases`, a TOML parse error and a failed `line-range-arg` migration — but NOT for a wrong-typed key jj-lib reads while loading the workspace (`ui.conflict-marker-style`, `working-copy.eol-conversion`, `git.executable-path`): the CLI reports those as "Internal error: …" without a hint (`map_workspace_load_error`, `From<WorkspaceInitError>`).

**Approach:** One helper `check_file_hint(Option<&Path>) -> Vec<String>` in `config.rs` fills `ConfigError::Load.hints` in `value_error` (`Type`), `file_error` (`Parse`), `migrate` (its line moves out of the reason) and `build_aliases_map`'s table error (`layer.path`); the workspace load/init fault helpers keep empty hints. Every carrier forwards them: `mutate::cfg` takes a `ConfigError` and keeps its hints (a generic `cfg_text` serves the few non-config callers); `FileError::Config`, `CommitViewError::Config` and `ConfigCmdError::Config` gain `hints`; `RevsetError::hints()` returns a `Config`'s; the FFI mappers for bookmarks, tags, revset search, log defaults, file and commit views forward them.

## Boundaries & Constraints

**Always:**
- `hints` equals the CLI's `Hint: ` line(s) without the label for the same fault, on every carrier through to `FfiError.hints`; oracle witnesses compare them with the pinned `jj`.
- Reasons (`context`) unchanged — except `migrate`'s, which loses its `\nCheck the config file: …` line. The `config error: ` text `cfg` puts on its reason stays.
- No hint where the CLI gives none: `ConfigGetError::NotFound`, `ConfigLoadError::Read`, a `None` source path (builtin layers, the manual `diff.color-words.max-inline-alternation` range error), and every workspace load/creation fault (`load_config_fault`, `init_config_fault`, `config_get_error`).
- Codes, refusal points and the no-operation rule unchanged.
- `docs/rust-error-codes.md` `jj.config_error` hints sentence names the new hint.

**Never:**
- No `.fbs`, codegen or Dart change (`FfiError.hints` → `ZanshinFfiException.hints` exists).
- No reason-text alignment with the CLI's `Caused by:` layout; no change to the four `git_subprocess_options` sites beyond what the `cfg` signature forces.
- Never regenerate fixtures; never lower `coverage-baseline.txt`; do not edit Story 9.60's spec, `epics.md`, or the deferred-work item's bullets.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Wrong type, pre-verb | repo config `snapshot.max-new-file-size = true`; `snapshot()` / any snapshotting verb | `PreconditionError::Config`, hints `["Check the config file: <repo config.toml>"]` | `jj.config_error`, no op |
| TOML parse | repo `config.toml` = `a = \n`; `Repo::open` and a later verb's refresh | `RepoError::Config` / `MutateError::Config`, same hint; reason as today | `jj.config_error` |
| Migration | `fix.tools.t.line-range-arg = 1` | reason `Migration failed: …` without a second line; same hint | `jj.config_error` |
| Alias table | `revset-aliases = 1`; a revset read | `RevsetError::Config`, `hints()` = same hint | `jj.config_error` |
| Load fault | `ui.conflict-marker-style = 1`; `Repo::open` | `RepoError::Config`, reason as today, hints empty | `jj.config_error` |
| No file | `NotFound`, `Read`, builtin / `None` path | hints empty | unchanged |
| Carriers | each of the cases through `cfg`, `rev`, file, commit views, config verbs, bookmarks, tags, revset search, log defaults, graph | `FfiError.hints` holds the hint | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/config.rs:286-301` -- `ConfigError::Load` doc ("only a remotes pattern carries one" — reword). `:337-351` `file_error` / `value_error`; `:1055-1076` `migrate` (reason line → hint; doc); `:1335-1376` `config_get_error` / `load_config_fault` / `init_config_fault` (stay hint-free: map without hint); `:1583-1592` manual `Type { source_path: None }` (no hint, unchanged). Inline tests `:4660-4685` pin migrate's old reason — update; add `value_error` / `file_error` / load-fault hint tests.
- `crates/zanshin-jj/src/revset.rs:83-95` -- `RevsetError::hints()` + doc; `:1078-1091` `build_aliases_map` table error → hint from `layer.path`.
- `crates/zanshin-jj/src/mutate.rs:618-638` -- `cfg` (now `ConfigError` → reason = Display, hints kept) + new generic `cfg_text`; `:654` `rev` keeps hints through `cfg`; test `:2288`.
- Non-`ConfigError` `cfg` callers (compiler lists them) -- `fix.rs:376,395,399` (messages), `template.rs:489` (`parse_trailers`), `push.rs:595` (`RevsetError`) → `cfg_text`; `colocation.rs:226`, `workspace_add.rs:179`, `workspace_ops.rs:104`, `remote_changes.rs:120` (`ConfigGetError`) → `|e| cfg(crate::config::value_error(&e))` like `push.rs:2134`.
- `crates/zanshin-jj/src/file.rs:258-264,276-279` -- `FileError::Config` + `hints`; its `cfg` takes `ConfigError` (only `:555-556`); test `:896`.
- `crates/zanshin-jj/src/commit_views.rs:226-234,259-261` -- `CommitViewError::Config` + `hints`; `rev` forwards; test `:724-728`. `drop_actions.rs:262-265` `view_err` forwards; test `:923`.
- `crates/zanshin-jj/src/config_cmd.rs:276-284,343-361` -- `ConfigCmdError::Config` + `hints`; `hints()` returns them; `From<ConfigError>` keeps them; constructions `:604,847,1151` `hints: Vec::new()`; test patterns `{ reason }` → `{ reason, .. }`.
- `crates/zanshin-ffi/src/{bookmarks.rs:35, tags.rs:100-108, revset_search.rs:36-45, log_defaults.rs:21-29, file.rs:36, commit_views.rs:45, config.rs:261}` -- forward hints (graph via `RevsetError::hints()`); their mapper tests assert a forwarded hint.
- `crates/zanshin-jj/tests/it/{api_stability.rs,config_cmd_user.rs}` and inline tests -- patterns/literals for the new fields; `api_stability` pins each new `hints` field by a struct literal.
- `crates/zanshin-parity/tests/oracle/hints.rs` -- `cli_error_labeled("Config error: ", …)` gives the CLI's hint lines; repo config set via `jj config set --repo`, its path via `jj config path --repo`. `main.rs` lists own-process tests if any.
- `docs/rust-error-codes.md:58` -- `jj.config_error` "Hints (Story 9.60)" sentence.
- CLI @ v0.47.0: `cli/src/command_error.rs:415-447` (three `From`s), `:1000-1007` `config_get_error_hint`; `cli/src/cli_util.rs:3026-3060` `map_workspace_load_error`; `command_error.rs:501-526` `From<WorkspaceInitError>`; `cli/src/config.rs` `load_aliases_map` (table error with `layer.path`).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/config.rs` -- `check_file_hint` (`pub(crate)`, cited @ v0.47.0); hints in `value_error` / `file_error` / `migrate`; load/init fault helpers without hint; docs; inline tests for each hint case, the no-hint cases and the load fault.
- `crates/zanshin-jj/src/revset.rs` -- `hints()` covers `Config`; alias-table hint; inline test.
- `crates/zanshin-jj/src/mutate.rs` + the non-config `cfg` callers -- typed `cfg` keeps hints, `cfg_text` for the rest; test.
- `crates/zanshin-jj/src/{file,commit_views,drop_actions,config_cmd}.rs` -- `hints` on the three `Config` variants, every conversion forwards; tests.
- `crates/zanshin-ffi/src/*` (seven mappers) -- forward hints; mapper tests assert them.
- `crates/zanshin-jj/tests/it/*` -- compile fixes; `api_stability` literals.
- `crates/zanshin-parity/tests/oracle/hints.rs` -- witnesses (hints == CLI hint lines): matrix rows 1 (`snapshot()` vs `jj status`), 2 (`Repo::open` vs `jj status`), 3 (`Repo::open` vs `jj status`), 4 (a revset read vs `jj log`), 5 (`Repo::open` vs `jj status`: both no hint).
- `docs/rust-error-codes.md` -- hints sentence.

**Acceptance Criteria:**
- Given a config fault the CLI hints "Check the config file: <path>" for, when Zanshin refuses it on any carrier, then `hints` holds exactly that line (oracle-checked for a wrong type, a TOML parse error, a migration and an alias table).
- Given a workspace load fault or a fault with no file, when Zanshin refuses it, then `hints` is empty, as in the CLI.
- Given valid config, when the suites run, then behavior is unchanged.

## Spec Change Log

## Review Triage Log

### 2026-11-16 — Review pass
- verdicts: 20 findings — high 0, medium 0, low 15, false 5, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) `conflict_marker_style` maps through `value_error`, so a read that re-reads the stack without reloading the workspace (`file_show`, `select_tree`, `hunks`) adds "Check the config file" for `ui.conflict-marker-style`, a key the CLI only ever reports at workspace load without a hint; the `file.rs` test pinned the hint — patched: `conflict_marker_style` maps through the hint-free `workspace_value_error` (why-comment), the `file.rs` test asserts empty hints. (`git_import_options`' `git.*` reads stay: the CLI's `GitSettings::from_settings(settings)?` hints if reached.)
  - `[low]` `[patch]` (blind) `crates/zanshin-ffi/src/repo.rs` tests `map_repo_err_config_…` / `map_mutate_err_config_…` said "a plain config fault has no hint" with an "invalid TOML" reason, now false for a real TOML fault — patched: message "an error built without hints maps to none"; forwarding through `map_repo_err` / `map_mutate_err` / `map_precondition_err` is pinned since Story 9.60.
  - `[low]` `[reject]` (blind) the file path shows twice (reason prefix and hint) for a TOML parse error and a non-table alias table, once for a migration — real but cosmetic; dropping `file_error`'s prefix needs a Parse/Read branch and changes reasons other tests and the registry pin, against the spec's "reasons unchanged"; the migrate move was the item's own instruction.
  - `[low]` `[defer]` (blind) `mutate::cfg` keeps the `config error: ` label in the reason while `From<ConfigError>` does not, so one fault's context differs by path — verified; pre-existing since Story 9.60 added `From`; this run kept every reason text; added to `deferred:` and mirrored into deferred-work.md.
  - `[low]` `[reject]` (blind) `ConfigError` has no `hints()` accessor, so conversions destructure it — style only; no caller diverges; the fix adds public API to a public type.
  - `[low]` `[patch]` (blind) `workspace_value_error`'s doc said the CLI reports "Internal error: …" through `From<WorkspaceInitError>`, but creation maps to "Failed to access the repository" (`command_error.rs:520-522` @ v0.47.0) — patched: the doc names both, neither with a hint. The missing creation-path oracle witness is rejected: the helper is shared with the load path (oracle-witnessed) and its init arm is unit-tested.
  - `[low]` `[reject]` (blind) oracle witnesses cover the repo-level file only (no user-level / `conf.d`, `template-aliases`, `fileset-aliases`, `MutateError` path; migration reason by prefix) — each fault kind is witnessed once through the shared `check_file_hint` / `build_aliases_map`; the `conf.d` inner file is pinned by `tests/it/config_cmd_user.rs`, the mutation path by `tests/it/config_identity.rs`; the reason layout is not this item.
  - `[low]` `[patch]` (blind) edited doc comments still cited the CLI @ v0.46.0 — patched: `RevsetError::hints` → `command_error.rs:1059-1144`, `ConfigCmdError::hints` → `config.rs:745-749`, `PreconditionError::hints` → `command_error.rs:292-323`, `RepoError::hints` → `commands/git/init.rs:233-240`, all @ v0.47.0 (spot-checked).
  - `[low]` `[patch]` (blind) the revset no-file test named a path-less Repo layer `builtin` — patched: renamed `pathless`.
  - `[low]` `[reject]` (blind) no Dart witness for the new hint, and deferred-work.md's Story 9.56 hint-family entry not marked — Dart: `ZanshinFfiException.hints` is filled from `FfiError.hints` for every code (Story 9.60's Dart test); the deferred-work entries are closed in the spec commit, as every closing run does.
  - `[low]` `[defer]` (edge) `push.rs:595-596` maps an `immutable_heads()` resolution failure through `cfg_text` to `jj.config_error` without hints, while the CLI's `.resolve()?` raises a resolution error with its hints (`cli/src/commands/git/push.rs:834-836` @ v0.47.0) — verified; pre-existing (the generic `cfg` did the same); added to `deferred:` and mirrored into deferred-work.md.
  - `[low]` `[defer]` (verification-gap, other) the `config error: ` label reaches the wire on `cfg` paths but not `From` paths; `config_refusal` assumes it never does; the new `mutate.rs` test pins the label — same root cause as the blind label row; deferred with it.
  - `[false]` `[reject]` (intent) the oracle compares the Rust API, the FFI only synthetic errors — every mapper's forwarding is asserted, and the `FfiErrorObj` → wire transport is shared and pinned since Story 9.56; no carrier drops a hint.
  - `[false]` `[reject]` (intent) carrier coverage is uneven (real faults vs synthetic conversions) — each carrier has an assertion that fails if it drops the hint; no bad outcome named.
  - `[false]` `[reject]` (intent) scope beyond the literal list, and `story_9_28_surface_resolves` split without a reason — the carriers are the intent's "check each carrier forwards it"; the split was forced by clippy's `too_many_lines` once the literals grew.
  - `[low]` `[patch]` (intent) the four `git_subprocess_options` sites changed their reason text against the spec's "reasons unchanged" — verified (unreachable: the workspace load reads `git.executable-path` first); patched: back to the old `ConfigGetError` Display via `cfg_text`.
  - `[low]` `[patch]` (intent) `ui.conflict-marker-style` gets a hint on `file_show` but none on open — same root cause as the first blind row; patched there.
  - `[low]` `[patch]` (intent) the stale "a plain config fault has no hint" message in `crates/zanshin-ffi/src/repo.rs` — same root cause as the second blind row; patched there.
  - `[false]` `[reject]` (intent) the spec has no Auto Run Result and nothing is committed — written and committed at finalization, after review.
  - `[false]` `[reject]` (intent) the problem statement cites a probe with jj 0.47.1 while the pin is 0.47.0 — the oracle witnesses run the pinned 0.47.0 `jj` and pass with the same outcomes; the fix would edit this spec.

## Design Notes

Why `cfg` takes a `ConfigError` instead of 60 call sites switching to `MutateError::from`: the sites already pass a `ConfigError`; typing `cfg` makes each keep its hints with no reason-text change, and the compiler finds the handful of other callers. `MutateError::from` (no `config error: ` label) stays for Story 9.60's sites.

Why the workspace fault helpers drop the hint: jj-lib reads those keys while loading or creating the workspace and the CLI reports its own load/init failure (`Internal error: The repository appears broken or inaccessible` / `Failed to read the tree state settings`) with no hint — probed with jj 0.47.1.

## Verification

**Commands (targeted; the story loop runs the full gate — do NOT run `cargo make test`, `cargo make test-full` or `cargo make coverage`):**
- `cargo test -p zanshin-jj` -- expected: green.
- `cargo test -p zanshin-ffi` -- expected: green.
- `cargo test -p zanshin-parity --test oracle` -- expected: green, no UNEXPECTED / CHANGED / STALE.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean.
- `cargo check -p zanshin-mcp --all-targets` -- expected: builds (it consumes `zanshin-jj`).

**Verification notes (run 2026-11-16; no `cargo make test` / `test-full` / `coverage` per the loop's gate rule):**
- Implementation pass: `cargo fmt --all --check` — clean; `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean; `cargo check -p zanshin-mcp --all-targets` — builds; `cargo test -p zanshin-jj` — 459 lib + 1572 `it` passed (1 pre-existing ignored perf benchmark); `cargo test -p zanshin-ffi` — 246 lib + 413 `it` passed; `cargo test -p zanshin-parity --test oracle` — 567 passed, no UNEXPECTED / CHANGED / STALE (incl. the five new `hints::` witnesses). After the verify-step test `config_identity::a_repo_writes_with_the_effective_config_stack` (refresh path, hint asserted) — passed.
- After the review patches: fmt, clippy (three crates, all targets) and the `zanshin-mcp` check — clean; `cargo test -p zanshin-jj` — 459 lib + 1572 `it` passed; `cargo test -p zanshin-ffi` — 246 + 413 passed; `cargo test -p zanshin-parity --test oracle hints::` — 21 passed (the patches touch no state scenario: hint text only, `conflict_marker_style`'s hint and four unreachable reasons).
- No `cargo make codegen` (no `.fbs` change), no Dart package touched (`FfiError.hints` → `ZanshinFfiException.hints` is generic).
- CLI behavior probed by hand in a scratch HOME/XDG (jj 0.47.1): hint for wrong-typed `snapshot.max-new-file-size`, `snapshot.auto-track`, `git.colocate`, non-table `revset-aliases`, a TOML parse error, a failed `line-range-arg` migration; none for `ui.conflict-marker-style`, `working-copy.eol-conversion`, `git.executable-path` (workspace load). The oracle confirms the witnessed cases at the pinned 0.47.0.
- Matrix audit: row 1 oracle `wrong_typed_snapshot_key_…`; row 2 oracle `toml_parse_error_…` (open) + `config_identity` (a later verb's refresh); row 3 oracle `failed_migration_…` + `config::tests` migrate test; row 4 `revset::tests::a_non_table_alias_table_from_a_file_…` (`RevsetError::Config` hints) + oracle `non_table_revset_aliases_…` (the snapshotting read arrives as its precondition's); row 5 oracle `workspace_load_fault_carries_no_hint_like_the_cli` + `config::tests::a_config_fault_in_a_known_file_…`; row 6 the same unit test; row 7 the FFI mapper tests, `mutate::tests::config_conversions_keep_a_config_faults_hints`, `commit_views` / `drop_actions` / `config_cmd` tests, `tests/it/config_cmd_user.rs` (`conf.d` inner file). All ran and passed.

## Auto Run Result

Status: done

**Items:**
- **1 — fixed (e1f7295cb477a08a02cc4524dc299c52050403d4).** Verified real at `19e4dfb`: `value_error` / `file_error` set no hints, `migrate` put "Check the config file: …" into the reason, and most carriers dropped `ConfigError` hints anyway. Now `check_file_hint` fills `ConfigError::Load.hints` in `value_error` (`Type` with a path), `file_error` (`Parse`, the error's own path — the inner file of a `conf.d` layer) and `migrate` (its line moved to the hint), plus `build_aliases_map`'s non-table error (the CLI's `load_aliases_map` builds a `ConfigGetError::Type` with the layer path). Where the CLI gives no hint, none is added: a missing value, an unreadable file, no path, and every fault jj-lib hits while loading or creating the workspace (`load_config_fault`, `init_config_fault`, `ui.conflict-marker-style`) — the CLI reports its own load/creation failure there. Every carrier forwards the hints: `mutate::cfg` now takes a `ConfigError` and keeps them (`cfg_text` for the few non-config callers), `FileError::Config`, `CommitViewError::Config` and `ConfigCmdError::Config` gained `hints`, `RevsetError::hints()` covers `Config`, and the bookmarks, tags, revset-search, log-defaults, file and commit-view FFI mappers pass them to `FfiError.hints`. Oracle: five `hints::` witnesses against the pinned `jj` (wrong type, TOML parse, migration, alias table, workspace load fault with no hint).

**New findings (deferred, mirrored into deferred-work.md):** the `config error: ` label in some `jj.config_error` contexts (`mutate::cfg` vs `From`), and `git push`'s commit check mapping an `immutable_heads()` resolution failure to `jj.config_error` without hints — both low and pre-existing; see `deferred:`.

**Files changed (e1f7295c):**
- `crates/zanshin-jj/src/config.rs` — `check_file_hint`; hints in `value_error` / `file_error` / `migrate`; hint-free `workspace_value_error` for workspace faults and `conflict_marker_style`; unit tests.
- `crates/zanshin-jj/src/revset.rs` — `RevsetError::hints()` covers `Config`; alias-table hint; unit test.
- `crates/zanshin-jj/src/mutate.rs` — typed `cfg` keeps hints, `cfg_text`; test. `fix.rs`, `template.rs`, `push.rs`, `colocation.rs`, `workspace_add.rs`, `workspace_ops.rs`, `remote_changes.rs` — `cfg_text` where the error is no `ConfigError` (reasons unchanged).
- `crates/zanshin-jj/src/{file,commit_views,drop_actions,config_cmd}.rs` — `hints` on the three `Config` variants, forwarded; tests. `repo.rs`, `snapshot.rs` — docs, citations at v0.47.0.
- `crates/zanshin-ffi/src/{bookmarks,tags,revset_search,log_defaults,file,commit_views,config,graph,repo}.rs` — hints forwarded; mapper tests.
- `crates/zanshin-jj/tests/it/{api_stability,config_cmd_user,config_identity}.rs` — struct literals, the `conf.d` hint, the refresh-path hint.
- `crates/zanshin-parity/tests/oracle/hints.rs` — five CLI witnesses.
- `docs/rust-error-codes.md` — `jj.config_error` hints sentence.
- Spec commit: this spec and `deferred-work.md` (item resolved, the Story 9.56 hint-family entry annotated, two new findings mirrored).

**Review:** 20 findings (low 15, false 5). Patched (all low): `conflict_marker_style` hint-free, stale FFI test messages, `workspace_value_error`'s CLI wording, four citations at v0.47.0, a misleading test variable, the four unreachable `git_subprocess_options` reasons back to their old text. Deferred: the `config error: ` label inconsistency and push's `immutable_heads()` resolution mapping (both low, pre-existing). Rejected: the doubled path in a TOML/alias reason (cosmetic; reasons stay), a `ConfigError::hints()` accessor (style, public API), oracle breadth (shared helpers, witnessed per kind), Dart/bookkeeping (generic transport; ledger closed here), plus the false rows in the triage log.

**Follow-up review recommended:** false — patched counts high 0, medium 0, low 6 entries.

**Verification:** see Verification notes — fmt, clippy, `zanshin-mcp` check, `zanshin-jj`, `zanshin-ffi`, the full oracle (and its `hints::` subset after the review patches); no full gate per the loop's rule.

**Residual risks:** coverage ratchet not run (the loop's gate at the end runs it); the new public `hints` fields on three error variants are API additions; a TOML or alias-table fault shows the path in both `context` and the hint; the reason layout still differs from the CLI's `Caused by:` lines (not this item).
