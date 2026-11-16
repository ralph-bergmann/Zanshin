---
title: 'Second 9.60 / 11.28 leftover run: CLI text for the remaining config faults, CLI codes for the conversion alias step'
type: 'bugfix'
created: '2026-11-16'
status: 'done'
baseline_revision: '8a6698d2e328e61e60626082fdab5568c19289d7'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      A clone's preset write and the config verbs still report a secure-config fault and a save
      fault as jj.config_error, where the CLI raises an internal error and a user error; only the
      conversion's trunk() alias step splits them now.
    evidence: |-
      creation.rs:469-477 write_repo_presets(|| new_repo_config_file(..))? maps every fault to
      RepoError::Config (pinned by creation_warnings.rs:356); config_cmd.rs create_path /
      save_config_file map to ConfigCmdError::Config. The CLI: From<SecureConfigError> internal,
      From<ConfigFileSaveError> user error (cli/src/command_error.rs:409-413,951-955 @ v0.47.0).
      Outside this run's two items; texts already match the CLI.
    location: >-
      crates/zanshin-jj/src/creation.rs:469; crates/zanshin-jj/src/config_cmd.rs
    severity: low
  - summary: >-
      Workspace load and creation config faults keep jj.config_error although the CLI labels them
      Internal error / Error.
    evidence: |-
      load_config_fault / init_config_fault now carry the CLI's text but stay RepoError::Config;
      the conversion's secure-config fault, the same CLI class, is jj.jj_lib_error. Code kept by
      this spec's boundary; pre-existing.
    location: >-
      crates/zanshin-jj/src/config.rs (load_config_fault, init_config_fault)
    severity: low
  - summary: >-
      A project that fails to open on a config parse error no longer names the file in the app:
      the path moved to the hint and the open-failure UI shows context only.
    evidence: |-
      project_session.dart:90,506 ProjectOpenFailed drops ZanshinFfiException.hints;
      projects_window.dart:446 and home_page.dart:217 show error.context ?? error.code. UI code is
      written only inside a story.
    location: >-
      app/lib/src/features/projects/project_session.dart:506
    severity: low
    resolved: >-
      2026-11-16 — fixed (spec-11-29-sync-refusal-hints, commit d6c10ef6): ProjectOpenFailed carries
      the hints and the Projects window's open-failure notice shows them.
  - summary: >-
      A malformed or unreadable config-id still reads "<id_path>: invalid config ID …" /
      "<id_path>: <io error>" instead of the CLI's secure-config text.
    evidence: |-
      config.rs:544-554 secure_config_path checks the id before jj-lib runs; config_cmd.rs:852-856
      io_error. The pinned CLI prints "Internal error: Failed to determine the secure config for
      a repo" / "Caused by: Found an invalid config ID" (probed 2026-11-16).
    location: >-
      crates/zanshin-jj/src/config.rs:544
    severity: low
---

<intent-contract>

## Intent

**Problem:** Two low leftovers, both verified against the code. (1) Config faults outside `value_error` carry a text the CLI never prints: `file_error` prefixes the path and joins the source chain with `: ` ("<path>: Configuration cannot be parsed as TOML document: TOML parse error …"), `migrate` joins with `: `, `build_aliases_map`'s non-table alias table renders "<path>: <table>: Expected a table, but is …", and `workspace_value_error` (workspace load/creation faults) renders only the inner `ConfigGetError`, joined with `: `. The CLI prints the error's message, then `Caused by:` lines (`print_error_sources`), the path only in its hint. (2) The conversion's `trunk()` alias step (`convert.rs:567-569`) maps every fault to `jj.convert_failed` with a `ConfigError`'s Display ("config error: …"), where the CLI's `write_repo_presets` raises three different errors: a secure-config fault (`repo_config_path`) as `Internal error: Failed to determine the secure config for a repo`, a load fault as `Config error:`, a save fault as `Error:` (`cli/src/command_error.rs:409-413,951-955` @ v0.47.0).

**Approach:** One CLI renderer for every config fault text: `error_text(err)` (Display + `warning::caused_by(err.source())`, the CLI's `user_error` / `config_error` / `internal_error` body) and `message_text(msg, err)` (msg + `caused_by(Some(err))`, the `*_with_message` body). (1) `file_error`, `migrate`, `write_error`, `create_path`, `fix_up` use them; the alias table builds the CLI's own `ConfigGetError::Type` and goes through `value_error`; `load_config_fault` / `init_config_fault` render the outer workspace error as `map_workspace_load_error` / `From<WorkspaceInitError>` do. Codes stay. (2) The alias step resolves the path, loads, and writes in three steps, each mapped as the CLI: secure fault → `RepoError::Backend` (`jj.jj_lib_error`), load fault → `RepoError::Config` with hints (`jj.config_error`), save fault → `RepoError::ConvertFailed` (`jj.convert_failed`), each with the CLI's text without its label.

## Boundaries & Constraints

**Always:** the CLI's observable text (Ralph, 2026-10-23), verified against the pinned binary (`target/debug/jj`, probe texts in Design Notes); hints unchanged except where noted; the conversion keeps its no-data-loss invariant and its on-disk effects (nothing rolled back, `left_behind` unchanged); gate rule of this run: targeted checks only, no `cargo make test` / `test-full` / `coverage`.

**Never:** changing any error enum's Display or variant set; changing the code of a workspace load/creation fault, a config verb's or a clone's write fault (only their text follows the shared renderer — the codes are new deferred findings); touching `deferred-work.md`'s existing bullets, `epics.md`, `sprint-status.yaml` or any finished spec.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| TOML parse error | repo config `a = ` ; `Repo::open` vs `jj status` | reason = "Configuration cannot be parsed as TOML document\nCaused by: TOML parse error …" (the CLI's lines, no path); hint "Check the config file: <path>" | `jj.config_error` |
| Unreadable layer | repo config path is a directory | "Failed to read configuration file\nCaused by:\n1: Cannot access <path>\n2: Is a directory (os error 21)"; no hint | `jj.config_error` |
| Failed migration | `fix.tools.t.line-range-arg = 1` | "Migration failed\nCaused by:\n1: Invalid type or value for fix.tools.t.line-range-arg\n2: Failed to migrate …"; hint | `jj.config_error` |
| Non-table alias table | `revset-aliases = 1` / `template-aliases = 1` | "Invalid type or value for revset-aliases\nCaused by: Expected a table, but is integer"; hint | `jj.config_error` |
| Workspace load fault | `ui.conflict-marker-style = 1` / `git.executable-path = 1` | "Failed to read the tree state settings\nCaused by:\n1: …" / "The repository appears broken or inaccessible\nCaused by:\n1: …"; no hint | `jj.config_error` (code kept) |
| Workspace creation fault | the same keys in the creation's stack | "Failed to access the repository\nCaused by:\n1: …" (both keys); no hint | `jj.config_error` (code kept) |
| Alias step, secure fault | `<xdg>/jj` is a file; `convert_colocated` vs `jj git init --colocate` | `RepoError::Backend("Failed to determine the secure config for a repo\nCaused by:\n1: Cannot access <dir>\n2: Not a directory (os error 20)")`; `.jj/` left, `left_behind` = `[<root>/.jj]` | `jj.jj_lib_error` |
| Alias step, load / save fault | (not reachable through the public API: a fresh config-id's fresh file) | `RepoError::Config` with hints / `RepoError::ConvertFailed("Failed to write configuration file\nCaused by: …")` | `jj.config_error` / `jj.convert_failed` |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/config.rs:323-337` -- `describe` (": "-join): replaced by `error_text` + `message_text` (new, next to `check_file_hint`); remove `describe` once unused.
- `config.rs:348-359` -- `file_error(path, err)`: reason → `error_text(err)`; the `path` parameter goes (callers `:656`, `:739`, `:2270`, test `:3758-3765`).
- `config.rs:361-376` -- `value_error`: use `error_text` (same output).
- `config.rs:378-388` -- `workspace_value_error`: now only `conflict_marker_style` (`:1573-1580`) uses it: `error_text(err)`, no hint (the CLI fails at workspace load first; Zanshin reaches it only when the file changed after the open).
- `config.rs:1365-1406` -- `config_get_error` → a bool "a `ConfigGetError` is in the chain"; `load_config_fault` renders `match err { StoreLoadError(e @ (ReadError{..} | Backend(_))) => message_text("The repository appears broken or inaccessible", e), StoreLoadError(e) => error_text(e) /* Signing, user_error */, _ => error_text(err) /* WorkingCopyState is transparent */ }` (`cli/src/cli_util.rs:3026-3060` @ v0.47.0); `init_config_fault`: `Backend(_) | WorkingCopyState(_) => message_text("Failed to access the repository", err)` (transparent variants: Display and source equal the inner's), `_ => error_text(err)` (`command_error.rs:501-530`). Inline tests `:3659-3720` follow.
- `config.rs:833-841` -- `create_path`: `.map_err(write_error)` → `message_text("Failed to determine the secure config for a repo", &e)` (`From<SecureConfigError>`); `fix_up` `:867-872` the same (one constant). Test `:4490-4505` follows.
- `config.rs:1101-1106` -- `migrate`: `error_text(&e)`; tests `:4800-4830`.
- `config.rs:2254-2259` -- `write_error`: `error_text(&err)`; doc. Every config writer's save fault now reads "Failed to write configuration file\nCaused by: …".
- `config.rs:2355-2389` -- split a `create_repo_config_path(repo_dir, root, seed)` out of `create_repo_config_file`, and a `pub(crate) new_repo_config_path(workspace)` beside `new_repo_config_file` (clone keeps `new_repo_config_file`).
- `crates/zanshin-jj/src/revset.rs:1084-1094` -- non-table table: `crate::config::value_error(&ConfigGetError::Type { name: table_name.to_owned(), error: format!("Expected a table, but is {}", item.type_name()).into(), source_path: layer.path.clone() })` (`cli/src/config.rs:1184-1189` @ v0.47.0); test `:1306-1332`.
- `crates/zanshin-jj/src/convert.rs:543-574` -- `maybe_set_trunk_alias`: `new_repo_config_path` (`ConfigError::Load { reason, .. }` → `RepoError::Backend(reason)`), `config::load_config_file(ConfigSource::Repo, &path)?` (From → `RepoError::Config`), `config::set_trunk_alias(Some(file), &alias)` (→ `RepoError::ConvertFailed { reason }`); `None` path → `Ok(())`; doc cites `mod.rs:155-193`, `command_error.rs:409-413,951-955` @ v0.47.0.
- `crates/zanshin-jj/tests/it/convert_alias_write_failure.rs` -- expect `RepoError::Backend(reason)`, reason = CLI text (prefix + `Not a directory (os error 20)` tail; the config-id is random).
- `crates/zanshin-jj/tests/it/templates.rs:474,617` -- `ends_with` → the new text.
- `crates/zanshin-parity/tests/oracle/hints.rs:578-642` -- whole-text witnesses: parse error, migration, non-table `revset-aliases`, workspace load fault (`Internal error: `); new: an unreadable (directory) repo config, a wrong-typed `git.executable-path` (`Internal error: `). Use `config_refusal` / `cli_error_labeled`; module doc line 8-11.
- `docs/rust-error-codes.md` rows 46, 52, 58 -- 46: the conversion alias step's secure fault; 52: its save fault (CLI text); 58: context is the CLI's `Config error:` text without the label for every config fault (path in the hint for a parse error, in "Cannot access <path>" for a read error); a load/creation fault carries the CLI's load-failure text.
- `crates/zanshin-ffi/src/repo.rs:1081-1094` (`zanshin_repo_convert` `# Errors`) and `:825-833` (`zanshin_repo_init`) -- add / extend `jj.jj_lib_error` for the alias step's secure fault; `docs/ffi-abi.md:633` add `jj.jj_lib_error`; `cargo make codegen` regenerates header + bindings.
- Read-only evidence: jj-lib 0.47.0 `config.rs:60-100` (error Displays), `config_resolver.rs:260-286`, `repo.rs:439-454`, `workspace.rs:75-110`, `signing_factory.rs:31-38`, `local_working_copy.rs:2845-2849`; jj-core `backend.rs:270-285` (transparent backend errors).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/config.rs` -- renderers, every mapping above, path split, inline tests (one per new `match` arm, built from constructed jj-lib errors) -- items 1 and 2.
- `crates/zanshin-jj/src/revset.rs` -- alias table via `value_error`; test -- item 1.
- `crates/zanshin-jj/src/convert.rs` -- three-step alias write -- item 2.
- `crates/zanshin-jj/tests/it/{convert_alias_write_failure,templates}.rs` and any test that pinned an old text -- follow.
- `crates/zanshin-parity/tests/oracle/hints.rs` -- whole-text witnesses -- CLI parity at the outermost Rust surface.
- `docs/rust-error-codes.md`, `crates/zanshin-ffi/src/repo.rs`, `docs/ffi-abi.md`, generated files -- registry follows.

**Acceptance Criteria:**
- Given each matrix row, when it runs, then reason, hints and code match the row, and the oracle witnesses show Zanshin's text and hints equal the pinned CLI's.
- Given a failed conversion alias step, when it fails, then the disk is as before this change (`.jj/` and the secure-config dir left, `.git/` untouched, `left_behind` unchanged).
- Given the targeted checks of § Verification, when run, then all pass; clippy and `cargo fmt --all --check` are clean.

## Spec Change Log

## Review Triage Log

### 2026-11-16 — Review pass
- verdicts: 22 findings — high 0, medium 0, low 21, false 0, maybe-false 1
- findings:
  - `[low]` `[defer]` blind: a project that fails to open on a TOML parse error no longer names the file in the app (`ProjectOpenFailed` drops hints; the UI shows `context`) — verified at `project_session.dart:90,506`; UI code only inside a story; deferred and mirrored.
  - `[low]` `[patch]` blind: FFI / Rust / ffi-abi docs still say `context` "names the path or key" — reworded at each site; `cargo make codegen` regenerated header and bindings.
  - `[low]` `[defer]` blind: the clone's `write_repo_presets` keeps all three faults as `jj.config_error` — real, pre-existing, outside the run's two items ("nothing else"); deferred with the config verbs, mirrored.
  - `[low]` `[reject]` blind: no test reaches the alias step's save fault any more — the load and save faults are unreachable through the public API (fresh random config-id; matrix row and Design Notes); the mapping is one expression on a line the secure-fault test executes.
  - `[low]` `[reject]` blind: no FFI test for `zanshin_repo_convert` → `jj.jj_lib_error` — the FFI maps `RepoError::Backend` through the existing, tested generic arm (`repo.rs` `map_repo_err_code`, unit test of `RepoError::Backend`); `left_behind` is attached per outcome, not per code.
  - `[low]` `[reject]` blind: no oracle witness for the creation-side texts (init faults, the conversion's secure fault) — both need a changed process environment (`JJ_CONFIG` / `XDG_CONFIG_HOME`), i.e. new own-process scenario plumbing; the texts were checked against the pinned binary (Design Notes probe) and the unit tests use jj-lib's real error types.
  - `[low]` `[patch]` blind: `convert_colocated` / `convert_import` `# Errors` miss `RepoError::Backend` — added, `ConvertFailed` wording narrowed.
  - `[low]` `[patch]` blind: Dart wrapper docs (`repo.dart`, `isolate.dart`) miss `jj.jj_lib_error` — added.
  - `[low]` `[patch]` blind: `rust-error-codes.md` promises a `jj.config_error` from the alias step's load that cannot happen — marked as the CLI's mapping kept for parity, unreachable through the public API.
  - `[low]` `[patch]` blind: `set_trunk_alias`'s doc names `new_repo_config_file` as its source — doc corrected (signature kept: tests pass `load(..)`'s `Option`).
  - `[low]` `[reject]` blind: tests index `hints[0]` — an empty list still fails the test, only with a different message; cosmetic.
  - `[low]` `[reject]` blind: `conflict_marker_style` keeps the bare `ConfigGetError` text — reached only when the file changes after the open; the CLI's head line there is jj-lib's working-copy message, which this read never sees (Code Map, accepted by the spec).
  - `[low]` `[patch]` blind: `ffi-abi.md`'s `zanshin_repo_convert` row does not record this run — story column extended.
  - `[low]` `[defer]` edge: clone's secure-config fault is `jj.config_error`, convert's `jj.jj_lib_error` — same root cause as the clone row; deferred there.
  - `[maybe-false]` `[reject]` edge: `init_config_fault`'s `_` arm would miss the CLI's `with_message` prefix for `CheckOutCommit` / `OpHeadsStore` / `WorkspaceStore` / `Path` — settling it needs a `ConfigGetError` inside one of those errors; none of their jj-lib sources reads config; would only be low.
  - `[low]` `[reject]` edge: `hints[0]` in tests — same as the blind row.
  - `[low]` `[patch]` edge: docs promise `context` names the file — same fix as the blind docs row.
  - `[low]` `[defer]` edge: a malformed / unreadable `config-id` still renders "<id_path>: …" — real (`config.rs:544-554`, `config_cmd.rs:852-856`), outside the two items; the registry sentence that implied otherwise was narrowed (docs patch); deferred and mirrored.
  - `[low]` `[defer]` verification-gap: clone keeps the old mapping and `creation_warnings.rs:356` pins it — same root cause as the clone row; deferred there.
  - `[low]` `[patch]` verification-gap (other): convert's `# Errors` docs out of date — same fix as the blind row.
  - `[low]` `[defer]` verification-gap (other): the config verbs' `create_path` fault is `jj.config_error` — folded into the clone deferral.
  - `[low]` `[defer]` intent-alignment: the diff implements the broad readings (1B+1C, 2B); divergences are the unpinned unreachable alias-step branches and creation texts (rows above) and the code-class mismatch — workspace load/creation faults stay `jj.config_error` while the conversion's internal error is `jj.jj_lib_error`; that mismatch is deferred and mirrored.

## Design Notes

Probe of the pinned CLI (`target/debug/jj`, scratch repos, 2026-11-16): parse error → `Config error: Configuration cannot be parsed as TOML document` / `Caused by: TOML parse error at line 1, column 5` + caret lines; directory layer → `Config error: Failed to read configuration file` / `Caused by:` / `1: Cannot access <path>` / `2: Is a directory (os error 21)`, no hint; migration → `Migration failed` + numbered list; `revset-aliases = 1` → `Invalid type or value for revset-aliases` / `Caused by: Expected a table, but is integer`; `ui.conflict-marker-style = 1` → `Internal error: Failed to read the tree state settings` + numbered list; `git.executable-path = 1` → `Internal error: The repository appears broken or inaccessible` + list; `jj git init` with either key in the user config → `Internal error:` / `Error: Failed to access the repository` + list; `jj git init --colocate` with `<xdg>/jj` a file → `Internal error: Failed to determine the secure config for a repo` / `Caused by:` / `1: Cannot access <xdg>/jj/repos/<id>` / `2: Not a directory (os error 20)`.

The alias step's load and save faults cannot be reached through the public API (a new config-id's fresh file); their mappings are one-liners next to the reachable secure fault, as the earlier `write_error` reasoning accepts.

## Verification

**Commands:**
- `cargo test -p zanshin-jj` -- pass
- `cargo test -p zanshin-ffi` -- pass (dependents; FFI doc change)
- `cargo test -p zanshin-parity --test oracle hints::` then the whole `--test oracle` -- pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- clean
- `cargo make codegen` -- regenerated files committed; `dart analyze` / `dart format --set-exit-if-changed` on `packages/zanshin_core/lib/src/ffi/bindings.dart` -- clean

## Auto Run Result

Status: done. Code commit `405ecb2f3b057b1587d1737030594d12cee3dab6` (review patches included); this spec and the `deferred-work.md` mirror are in the commit that adds this spec.

**Items:**
1. **Fixed** (405ecb2f) — every config fault's `jj.config_error` context is now the CLI's text without its label: `file_error` (no path prefix; the path is in the parse error's hint or the read error's "Cannot access <path>" cause), `migrate` (numbered `Caused by:` list), the non-table alias table (the CLI's own `ConfigGetError::Type` through `value_error`, `revset-aliases` and `template-aliases`), workspace load / creation faults (`load_config_fault` / `init_config_fault` render the outer error as `map_workspace_load_error` / `From<WorkspaceInitError>` do), plus the shared renderers' other users (`write_error` save faults, the secure-config fault). Codes unchanged. Whole-text oracle witnesses: parse error, directory layer (new), migration, non-table `revset-aliases`, `ui.conflict-marker-style` and `git.executable-path` (new) load faults. Creation-side texts are pinned by unit tests on jj-lib's real error types (an oracle witness needs an own-process scenario; texts probed against the pinned binary).
2. **Fixed** (405ecb2f) — the conversion's `trunk()` alias step (`write_trunk_alias`) maps its faults as the CLI: secure-config fault → `RepoError::Backend` / `jj.jj_lib_error` ("Failed to determine the secure config for a repo" + causes), load fault → `RepoError::Config` with hints, save fault → `RepoError::ConvertFailed` ("Failed to write configuration file" + causes). No rollback; `.jj/` and the secure-config dir stay, `left_behind` unchanged. `convert_alias_write_failure.rs` and `creation_warnings.rs` pin `Backend` and the CLI's text. The load and save branches are not reachable through the public API (fresh random config-id).

**Files changed:** `crates/zanshin-jj/src/{config,convert,revset,config_cmd,repo,snapshot}.rs` (renderers, mappings, path split, docs, unit tests); 11 `crates/zanshin-jj/tests/it/*.rs` files and 4 `crates/zanshin-ffi/tests/it/*.rs` (expectations follow: path now in the hint); `crates/zanshin-parity/tests/oracle/hints.rs` (whole-text witnesses); `crates/zanshin-ffi/src/{repo,graph,config,envelope,log_defaults}.rs` + generated `zanshin_ffi.h` / `bindings.dart` (error docs); `packages/zanshin_core/lib/src/ffi/repo.dart`, `lib/src/worker/isolate.dart` (error docs); `docs/rust-error-codes.md`, `docs/ffi-abi.md`; ledger `deferred-work.md` (new section, four findings).

**Review:** 22 findings — 0 high, 0 medium, 21 low, 0 false, 1 maybe-false. Patched (all low, docs only): stale "context names the path" docs across FFI / Rust / ffi-abi (codegen rerun), convert `# Errors` (Backend added), Dart wrapper error lists, the registry's unreachable load-fault claim and over-broad no-path claim, `set_trunk_alias`'s doc, the ffi-abi row's story column. Deferred (all low, mirrored to `deferred-work.md` under "Surfaced in the second 9.60 / 11.28 leftover run"): clone and config verbs keep `jj.config_error` for secure-config / save faults; workspace load / creation faults keep `jj.config_error` (CLI: internal / user error); the app's failed-open note loses the file name (hints not shown; UI story); a malformed `config-id` keeps "<id_path>: …". Rejected with reasons in the triage log: untested unreachable alias-step branches, no FFI test for the generic Backend arm, no own-process oracle scenario for creation texts, `hints[0]` in tests, `conflict_marker_style`'s bare text, the `init_config_fault` `_` arm (maybe-false). Follow-up review: not recommended (patched: low 6 entries, no high or medium).

**Verification run (targeted only, no full gate per the run's gate rule):**
- Implementer: `cargo test -p zanshin-jj` 463 unit + 1572 integration passed; `cargo test -p zanshin-ffi` 246 + 413 passed; `cargo test -p zanshin-parity --test oracle` 570 passed.
- After `cargo fmt --all` (one FFI test reformatted) and the doc patches: `cargo test -p zanshin-jj --lib` 463 passed; `--test it` modules `convert` (58), `creation_warnings` (1), `templates` (42), `config` (120), `revset` (85, 1 ignored), `op_support` (13), `secure_config` (13) passed; `cargo test -p zanshin-ffi --lib` 246 passed, `--test it log_defaults` 4 passed; `cargo test -p zanshin-parity --test oracle hints::` 24 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` and `cargo fmt --all --check` clean; `cargo make codegen` rerun after the doc patches; `dart format --set-exit-if-changed` and `dart analyze --fatal-infos` on `bindings.dart`, `repo.dart`, `isolate.dart` clean. `packages/zanshin_core` `dart test` not run (doc-only Dart changes).
- CLI texts probed with the pinned `target/debug/jj` in scratch repos (deleted afterwards).

**Residual risks:** a parse fault's `context` no longer names the file; the app shows only `context` for a failed open, so the file name is lost there until the UI shows hints (deferred). Coverage not measured: the alias step's load/save mapping sits on lines the secure-fault test executes, and every new `match` arm has a unit test, but the ratchet has not run. `workspace_ops.rs:228` still builds its own "The repository appears broken or inaccessible: {}" text (outside the two items).
