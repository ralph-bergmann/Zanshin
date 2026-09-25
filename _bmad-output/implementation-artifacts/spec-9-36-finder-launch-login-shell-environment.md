---
title: 'Story 9.36: Finder/Dock launch sees the login-shell environment — `JJ_CONFIG`, `XDG_CONFIG_HOME`, `JJ_*` as in the terminal'
type: 'feature'
created: '2026-09-25'
status: 'done'
baseline_revision: '43787f5cf5ac36a8f26f0db08b651cf000b52f55'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      Variables the login shell's rc file UNSETS stay in the git subprocess environment.
    evidence: |-
      jj-lib's `create_command` (jj-lib-0.44.0 git_subprocess.rs:99-143) applies `GitSubprocessOptions::environment`
      with `Command::envs` on top of the inherited process environment and never calls `env_clear`, so the adopted
      map can add and override variables but never remove one. The config stack is unaffected (it reads the adopted
      map alone). Needs an upstream jj-lib option.
    location: >-
      crates/zanshin-jj/src/environment.rs (git_subprocess_options)
    severity: low
  - summary: >-
      jj-lib's signing subprocesses (gpg, ssh-keygen), its git gc, gix's in-process config reads and zanshin-mcp still see the environment the process was started with.
    evidence: |-
      No environment hook exists: `gpg_signing.rs:187,269`, `ssh_signing.rs:157`, `git_backend.rs:925` (`run_git_gc`)
      spawn with the process environment, and gix reads `HOME`/`XDG_CONFIG_HOME`/`GIT_CONFIG_*` from the process.
      A Finder-launched Zanshin can therefore sign with a different gpg/ssh-keygen (or none on PATH) than the
      terminal jj. The story's Scope names only ConfigEnv and the git subprocess environment; the fix needs an
      upstream hook (set_var is ruled out). zanshin-mcp keeps its client's environment and never adopts.
    location: >-
      jj-lib-0.44.0 src/gpg_signing.rs, src/ssh_signing.rs, src/git_backend.rs; crates/zanshin-mcp
    severity: medium
  - summary: >-
      The UI does not surface env.login_shell_unresolved; the bootstrap only logs it.
    evidence: |-
      `app/lib/main.dart::_adoptShellEnvironment` (`_startApp` before the 2026-09-25 redirect) logs each warning as
      `<code>: <message>` under `zanshin.bootstrap`. A user whose rc file hangs or fails gets the launchd environment
      with no visible hint. UI is Ralph's scope.
    location: >-
      app/lib/main.dart (_adoptShellEnvironment)
    severity: low
  - summary: >-
      RESOLVED 2026-09-25 (Story 9.36 redirect: ZanshinBootSequence's adoptShellEnvironment step, pinned by
      zanshin_bootstrap_test.dart) — No test pins that the bootstrap adopts the login-shell environment before the app is created.
    evidence: |-
      `_startApp` is the private composition root; `zanshin_bootstrap_test.dart` injects its own `startApp`, so dropping
      the `adoptLoginShellEnvironment()` call or moving it after `zanshinAppFactory.create()` ships with every witness
      green. Needs a seam (the adopt-and-log step as a helper the app tests drive).
    location: >-
      app/lib/main.dart (_startApp)
    severity: low
  - summary: >-
      RESOLVED 2026-09-25 (Story 9.36 redirect: Dart reads the shell with ProcessStartMode.detachedWithStdio, i.e.
      setsid, so it has no controlling terminal) — On TIMEOUT a real zsh -i started under a controlling terminal is still SIGKILLed and can leave the terminal's foreground process group dead.
    evidence: |-
      An interactive zsh opens /dev/tty and makes itself the terminal's foreground process group, handing it back only
      on a normal exit. The review patch lets the shell exit on its own on SUCCESS, but the timeout arm still kills it
      (e.g. Zanshin run via `flutter run` from a terminal, rc file hanging) — the launching tool then stops with
      SIGTTIN. The proper fix is `setsid` for the child: `CommandExt::setsid` is unstable in std 1.95 and `unsafe`
      (pre_exec) is not allowed in zanshin-jj. Never observed with a real zsh; derived from zsh's acquire/release_pgrp.
    location: >-
      crates/zanshin-jj/src/environment.rs (read_login_environment, timeout arm)
    severity: low
---

<intent-contract>

## Intent

**Problem:** A Zanshin started from Finder/Dock gets launchd's minimal environment, so `JJ_CONFIG`, `XDG_CONFIG_HOME`, `JJ_USER`/`JJ_EMAIL`/`JJ_OP_*`, `VISUAL`/`EDITOR`, `NO_COLOR` set in a shell rc file never reach `ConfigEnv::from_env` (a different config and identity than the terminal `jj`), and jj-lib's `git` subprocess on fetch/clone misses the shell's `PATH`, `SSH_AUTH_SOCK`, `GIT_*`.

**Approach:** Decided option (a): at app start-up, before any repo is opened, Rust spawns `$SHELL -l -i -c` once, reads an `env -0` dump between markers under a timeout, and ADOPTS the result as a write-once process-wide map in `zanshin-jj` (never `std::env::set_var`). Every CLI-parity environment read in `zanshin-jj` and the git subprocess environment read that map; on timeout/failure nothing is adopted, the process environment stays in effect, and a 9.32 warning reports it. The app bootstrap triggers it through a new handle-less worker command.

## Boundaries & Constraints

**Always:**
- **Store.** `crates/zanshin-jj/src/environment.rs` owns one `static` write-once map (`OnceLock<HashMap<OsString, OsString>>`). Readers get the adopted map when set, else the live process environment — so everything behaves exactly as today until an adoption succeeds (tests, MCP, `cargo test`).
- **Adoption** (`pub fn adopt_login_shell_environment(shell: Option<&OsStr>, timeout: Duration) -> Vec<Warning>`): `shell` absent → the process `$SHELL`. Spawn `<shell> -l -i -c "<cmd>"` with the inherited environment, stdin and stderr null, stdout piped; `<cmd>` prints a begin marker, `/usr/bin/env -0`, an end marker. Success = the end marker is read within `timeout` (NOT EOF — a background job the rc started may hold the pipe); parse the NUL-separated `KEY=VALUE` entries after the begin marker as raw bytes (`OsString`, non-UTF-8 kept). The child is always killed or reaped before returning; no thread spawn or read may panic (use `thread::Builder::spawn`'s `Result`).
- Adoption succeeds → store the map, return no warnings. Fails → store nothing, return exactly one `WarningKind::LoginShellUnresolved`. A map already adopted → no-op, no spawn, no warnings (a Flutter hot restart re-runs the bootstrap against the same loaded cdylib). A failed attempt leaves the next call free to try again.
- **Warning message** (Zanshin-only, no CLI site): `Could not read the login-shell environment from <shell>: <reason>. Using the environment Zanshin was started with.` with `<shell>` via `to_string_lossy` and `<reason>` one of `timed out after <N> ms` · `could not start it: <io::Error Display>` · `it exited with <ExitStatus Display>` (EOF before the end marker, non-success status) · `it printed no environment` (EOF before the end marker, success status). No shell at all: `Could not read the login-shell environment: SHELL is not set. Using the environment Zanshin was started with.`
- **Readers.** `ConfigEnv::from_env` (`HOME`, `XDG_CONFIG_HOME`, the UTF-8 `environment` snapshot, `JJ_CONFIG` read as UTF-8-or-unset, the `$USER` fallback) derives everything from ONE snapshot taken through the store; `wc_ops.rs`'s `XDG_CONFIG_HOME` and `detect.rs`'s `HOME` read through the store too. Only `environment.rs` touches `std::env` in `crates/zanshin-jj/src` (non-test code).
- **Git subprocess.** Both `GitSubprocessOptions::from_settings` sites set `environment` to the adopted map MINUS `LC_ALL`, `LANGUAGE`, `LC_MESSAGES` (jj-lib removes/sets those before applying `environment`, so git's output stays parseable) — an empty map when nothing is adopted (today's behaviour).
- **Wire.** New handle-less extern fn `zanshin_environment_adopt(data, len)` in `crates/zanshin-ffi/src/environment.rs`; request `EnvironmentAdoptRequest { kind: RequestKind; shell: string; timeout_ms: uint; }` (`kind` field 0, `RequestKind.EnvironmentAdopt` appended); reply = ok `Envelope` with NO payload plus warnings. Refusals: the handle-less ladder only (`ffi.null_pointer`, `ffi.invalid_argument`). New code `env.login_shell_unresolved` (`ENV_LOGIN_SHELL_UNRESOLVED`) in a new registry domain `env`.
- **Dart.** `ZanshinWorker.adoptLoginShellEnvironment({String? shell, Duration timeout = const Duration(seconds: 10)})` → `Future<LoginShellEnvironmentResult>` (`warnings`, like `ConfigFileWriteResult`); `shell` with an interior NUL or a timeout outside `0..0xFFFFFFFF` ms throws `ArgumentError` before any FFI call. `ZanshinWarningCode.loginShellUnresolved`; `LoginShellEnvironmentResult` exported from the barrel.
- **Bootstrap.** `app/lib/main.dart::_startApp` awaits the worker, then `adoptLoginShellEnvironment()`, logs each warning with the existing `_log.warning` (`<code>: <message>`), THEN creates the app — so nothing can open a repo before adoption.
- Never log environment contents above `debug`.

**Never:**
- No `std::env::set_var`/`remove_var` in production code; no merge of the adopted map with the launchd environment for `ConfigEnv` (the dump IS the login shell's full environment).
- No terminal-launch detection (tty/`SHLVL`); no rc-file edits; no `ZANSHIN_*` marker variable exported to the shell; no Zanshin setting for `JJ_CONFIG`/`XDG_CONFIG_HOME` (options (b)/(c) not chosen).
- No UI beyond the logged warning; no `zanshin-mcp` change; do not route jj-lib's signing (`gpg`/`ssh-keygen`), `git gc` or gix's in-process config reads (no hook exists — deferral, below).
- No Dart test may make an adoption SUCCEED (all `packages/zanshin_core` test files share one process and one cdylib); no inline `zanshin-jj` lib test may touch the static.
- Never lower `coverage-baseline.txt` or add an `exclude_prefix`/`EXTERN_COV_ALLOW` entry.

## I/O & Edge-Case Matrix

Fake shells are `#!/bin/sh` scripts in a tempdir (mode 0755) invoked as `<script> -l -i -c <cmd>`, i.e. `$4` is `<cmd>`.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Adopt (own `tests/` binary) | process pinned with `TEST_ENV` (`JJ_CONFIG=""`, `JJ_USER=Test User`); shell script: `unset JJ_CONFIG; export JJ_USER='Shell User' XDG_CONFIG_HOME=<tmp>/xdg LC_ALL=de_DE.UTF-8 LC_MESSAGES=de_DE.UTF-8 ZANSHIN_SENTINEL=1 PATH=<tmp>/bin:$PATH; exec /bin/sh -c "$4"`; `<tmp>/xdg/jj/config.toml` = `[test]\nmarker = "from-xdg"`; `<tmp>/bin/git` appends `env` to `<tmp>/git-env.txt`, exits 1 | before: `config_get(None,"user.name")` = `Test User`, `test.marker` → `ConfigCmdError::NotFound`; `adopt(Some(script), 5 s)` → `[]`; after: `user.name` = `Shell User`, `test.marker` = `from-xdg`; a git-backed repo's `git_fetch` from a remote runs the fake git, whose `git-env.txt` holds `ZANSHIN_SENTINEL=1` and `LC_MESSAGES=C`, no `LC_ALL=` line | the fetch's own error is ignored |
| Second call | right after the row above, shell `/nonexistent/shell` | `[]`, no spawn; `user.name` still `Shell User` | — |
| Timeout | script `exec sleep 30`, timeout 200 ms | one warning, reason `timed out after 200 ms`; returns in < 5 s; child killed; nothing adopted | fallback |
| Cannot start | shell `/nonexistent/zanshin-shell` | reason starts `could not start it: ` | fallback |
| Exit without dump | script `exit 3` | reason `it exited with exit status: 3` | fallback |
| No dump, success | script `echo hello` | reason `it printed no environment` | fallback |
| No shell | `shell` absent and no `SHELL` (unit: the inner fn with `None`) | the `SHELL is not set` message | fallback |
| rc noise + background job | script prints `welcome`, starts `sleep 30 >&1 &`, then `exec /bin/sh -c "$4"` | success, map parsed; returns in < 5 s | — |
| Odd values | dump with a value containing `=` and `\n`, one non-UTF-8 value, one entry without `=` | `=`/`\n` value intact; non-UTF-8 kept in the git map, dropped from `ConfigEnv.environment`; a non-UTF-8 `JJ_CONFIG` counts as unset; the `=`-less entry skipped | — |
| Dart, real cdylib | `worker.adoptLoginShellEnvironment(shell: '/nonexistent/zanshin-shell')`; and a `sleep 30` script with `timeout: 200 ms` | each: `warnings` = one `ZanshinWarning` code `env.login_shell_unresolved`, message starts `Could not read the login-shell environment from ` and contains the reason | — |

</intent-contract>

## Code Map

**New store (zanshin-jj):**
- `crates/zanshin-jj/src/environment.rs` (new) -- the `OnceLock`, `adopt_login_shell_environment`, a store-injectable inner fn (`adopt_into(store: &OnceLock<…>, shell: Option<OsString>, timeout)`) so unit tests use local `OnceLock`s, the resolver, the dump parser, `snapshot()` (adopted clone or `std::env::vars_os()`), `var_os(name)`, and a pure git-map filter plus the `GitSubprocessOptions` helper. Register in `lib.rs` and re-export next to the warning re-export (`crates/zanshin-jj/src/lib.rs:79`).
- `crates/zanshin-jj/src/warning.rs:28-85` -- add `WarningKind::LoginShellUnresolved` (rustdoc: Zanshin-only, Story 9.36, no CLI site); build it via `local(kind, msg)` (`:159`).

**Readers to reroute:**
- `crates/zanshin-jj/src/config.rs:284-312` -- `ConfigEnv::from_env`: four direct reads (`HOME` :288, `XDG_CONFIG_HOME` :293, `vars_os` :296, `JJ_CONFIG` via `var` :303) + `$USER` fallback :308 → one snapshot from the store (a `from_vars(&HashMap<OsString,OsString>)`-style constructor keeps it unit-testable). Update the module doc's env-layer section (`:88-105`) to name the source. Callers (`:823/838/859/1001/1026/1288/1343`, `config_cmd.rs:317-442`) stay untouched. `stack_fingerprint` (`:953-1001`) hashes the whole environment, so an adoption after a repo opened costs that repo one settings reload (`repo.rs:220-228`) — expected; the bootstrap adopts first.
- `crates/zanshin-jj/src/wc_ops.rs:227` -- `XDG_CONFIG_HOME` (the CLI's `base_ignores`, `cli_util.rs:1660-1667`) → `environment::var_os`. The `etcetera::home_dir()` fallback (:230) and gix's `config_snapshot()` (:277/:289) are library-internal → deferral.
- `crates/zanshin-jj/src/detect.rs:113` -- `HOME` walk-up ceiling → `environment::var_os`.
- `crates/zanshin-jj/src/remotes.rs:269` (`git_fetch`) and `crates/zanshin-jj/src/repo.rs:2074` (`clone_into`) -- the only `GitSubprocessOptions::from_settings` sites; set `environment` from the store helper.

**Read-only evidence:**
- `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.44.0/src/git_subprocess.rs:99-143` `create_command`: no `env_clear`; `.env_remove("LC_ALL").env_remove("LANGUAGE").env("LC_MESSAGES","C")`, then `git_cmd.envs(&self.options.environment)` LAST. `jj-lib-0.44.0/src/git.rs:125-143` `GitSubprocessOptions { executable_path, environment }` — the doc invites consumers to set it. The CLI passes an empty map (`../jj/cli/src/commands/git/fetch.rs:238`, `clone.rs:383`), i.e. its git inherits the terminal's env. Rust's `Command` searches the child's `PATH` when `PATH` is set on the command, so the adopted `PATH` also picks which `git` runs (`git.executable-path` defaults to `"git"`).
- Other jj-lib subprocesses have no env hook: `gpg_signing.rs:187,269`, `ssh_signing.rs:157`, `git_backend.rs:925` (`run_git_gc`).
- Process-globals precedent: `crates/zanshin-ffi/src/tracing_init.rs:50` (`Once`), `events.rs:30-37` (`SINK` + `// WHY:`). zanshin-jj has none yet — give the static a `// WHY:` (write-once, never mutated; AD-2's no-lock rule is about handles).

**FFI (mirror `zanshin_config_gc_list`):**
- `crates/zanshin-ffi/src/config.rs:218-225` `read_gc_list_request` (the ladder: `reject_null_request` → `from_raw_parts` → `root_with_opts` → `expect_request_kind`; no generic reader, `envelope.rs:390-395`), `:707-716` the extern fn (`debug!(fn_name=…)`, `vec_into_token(catch(|| …))`).
- `crates/zanshin-ffi/src/envelope.rs:194-247` warning consts, `:252-280` exhaustive `warning_code()`, `:298-308` `CallReport::warnings`, `:686-710` `finish_envelope` (payload-less precedent `snapshot.rs:66-68`: `finish_envelope(FlatBufferBuilder::with_capacity(256), fbs::Payload::NONE, None, &report)`; fix its doc "`data` is `None` only for `zanshin_snapshot`"), `:1021` test `every_warning_kind_has_its_registered_code`.
- `schemas/envelope.fbs:70-99` `RequestKind` (append-only), `:482-485` `ConfigGcListRequest` shape, `:494-521` roadmap comment, `:62` table count. Scalars have no optional form here — `timeout_ms` is a required `uint`; `shell` absent = `$SHELL`.
- Codegen: `cargo make codegen` (`Makefile.toml:314-369`) → `envelope_generated.rs`, `envelope_zanshin.ffi_generated.dart`, `include/zanshin_ffi.h`, `bindings.dart` — all committed.
- Tests to copy: `crates/zanshin-ffi/tests/config_ffi.rs:30-62` (env guard, `Wrapper` call helper).

**Dart (mirror `configGcList` / `configFileWrite`):**
- `packages/zanshin_core/lib/src/worker/commands.dart:1066-1068` command class (handle-free block `:921-926`); `isolate.dart:1606-1609` public method, `:2254-2256` dispatch arm (`BufferResult`).
- `packages/zanshin_core/lib/src/ffi/config.dart:312-322` request with an optional string (`rejectInteriorNul`), `:325-328` `callWithRequest`, `:157-165` + `:419-421` warnings-only result + decoder; `request_bytes.dart:46-113`. New file `lib/src/ffi/environment.dart` holds builder, result type and decoder (errors via `decodeEnvelopeErrorInternal`, `precondition.dart:174`).
- `packages/zanshin_core/lib/src/ffi/warning.dart:42-144` `ZanshinWarningCode` + `values` (24 → 25).
- `packages/zanshin_core/lib/zanshin_core.dart:9-31` barrel.
- `app/lib/main.dart:90-95` `_startApp`; `_log` = `Logger('zanshin.bootstrap')` (`:25`).

**Tests & guards:**
- Rust env pinning: `crates/test-helpers/src/lib.rs:75-97` (`TEST_ENV`, `pin_test_env`); one-`#[test]`-per-file idiom for process-global state: `crates/zanshin-jj/tests/creation_warnings.rs:9-18`, `config_identity.rs:7-12`; remote in-test via `git::add_remote` (memory: fixtures have no remotes).
- `crates/zanshin-jj/tests/api_stability.rs:1082-1120` exhaustive `WarningKind` pin (+ pin the new pub fn).
- `packages/zanshin_core/test/ffi/warning_test.dart:108-314` `_cases` (no-payload entry like `configFileWrite` `:296-301`), `:336-366` pinned `values`; `test/worker/config_test.dart:31-50,116-135` worker setUp + XDG guard + warnings-only template; `dart_test.yaml:3-11` (one process).
- Coverage extern guard `Makefile.toml:562-589` (needs a `zanshin_core` cdylib test calling the fn); `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs:37` `EXPECTED_EXPORTS = 59` → 60.

**Docs & bookkeeping:**
- `docs/ffi-abi.md` -- symbol-index row (`:398-476`, no-payload spelled like `zanshin_config_file_write` `:465`), request-buffer counts (`:186-194`), request tables (`:328`, `:355`), `RequestKind` list (`:346-369`), envelope warnings (`:72-98`), § Dart worker integration (`:615-635`) if it lists handle-free commands.
- `docs/rust-error-codes.md` -- domain `env` (`:19-29`, "`zanshin-jj` start-up environment — login-shell adoption"), Warning Codes row for `env.login_shell_unresolved` (CLI site: none — Zanshin-only), per § Adding a New Code (`:173-180`).
- `_bmad-output/implementation-artifacts/deferred-work.md:370` (9.27 item) → RESOLVED 2026-09-25 (Story 9.36); new dated "Surfaced 2026-09-25 while implementing Story 9.36" section: signing/`git gc` subprocesses and gix in-process reads (`HOME`/`XDG_CONFIG_HOME`/`GIT_CONFIG_*`) still see the launchd env; the UI does not surface the warning yet (logged only); vars the rc `unset`s stay in git's env (jj-lib's `envs` cannot remove); `zanshin-mcp` never adopts.
- `_bmad-output/implementation-artifacts/sprint-status.yaml:135` → `done` with summary; `last_updated` → 2026-09-25.

## Tasks & Acceptance

**Execution:**
- [x] `crates/zanshin-jj/src/environment.rs` (new), `lib.rs`, `warning.rs` -- store, adoption, resolver, parser, snapshot/`var_os`, git-map helper, `WarningKind::LoginShellUnresolved`; inline tests for every matrix row except the `tests/` and Dart rows, using local `OnceLock`s and fake-shell scripts -- the mechanism, fully covered without touching the static.
- [x] `crates/zanshin-jj/src/config.rs`, `wc_ops.rs`, `detect.rs` -- read through the store; unit test for the snapshot-based `ConfigEnv` constructor (non-UTF-8 value dropped, non-UTF-8 `JJ_CONFIG` unset, `$USER` fallback) -- the config stack sees the adopted env.
- [x] `crates/zanshin-jj/src/remotes.rs`, `repo.rs` -- git subprocess `environment` from the helper -- fetch/clone see the shell's `PATH`/`SSH_AUTH_SOCK`/`GIT_*`.
- [x] `crates/zanshin-jj/tests/login_shell_environment.rs` (new, ONE `#[test]`) -- matrix rows "Adopt" + "Second call" through the public API (`config_get`, `Repo::git_fetch`) -- the real static and both consumers end-to-end.
- [x] `crates/zanshin-jj/tests/api_stability.rs` -- `WarningKind` arm + fn pin.
- [x] `schemas/envelope.fbs` then `cargo make codegen` -- `EnvironmentAdoptRequest`, `RequestKind.EnvironmentAdopt`, roadmap/count comments; commit all four generated files.
- [x] `crates/zanshin-ffi/src/environment.rs` (new), `lib.rs`, `envelope.rs` -- `zanshin_environment_adopt` (rustdoc `# Errors`: `ffi.null_pointer`, `ffi.invalid_argument`), `ENV_LOGIN_SHELL_UNRESOLVED` + `warning_code` arm + literal-table test entry, `finish_envelope` doc.
- [x] `crates/zanshin-ffi/tests/environment_ffi.rs` (new) -- ladder rows (null, garbage, wrong `kind`) and a failing shell → ok, no payload, one `env.login_shell_unresolved` -- wire contract; never adopts.
- [x] `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs` -- `EXPECTED_EXPORTS` 60.
- [x] `packages/zanshin_core/lib/src/ffi/environment.dart` (new), `lib/src/worker/{commands,isolate}.dart`, `lib/src/ffi/warning.dart`, `lib/zanshin_core.dart` -- command, method, dispatch, builder, `LoginShellEnvironmentResult`, decoder, warning constant, barrel export.
- [x] `packages/zanshin_core/test/worker/environment_test.dart` (new) -- the Dart matrix row (both fallbacks, real cdylib, XDG guard) + the two `ArgumentError`s; `test/ffi/warning_test.dart` -- `_cases` entry and `values` (25) -- credits the extern fn; never a success.
- [x] `app/lib/main.dart` -- `_startApp` adopts and logs before creating the app.
- [x] `docs/ffi-abi.md`, `docs/rust-error-codes.md`, `_bmad-output/implementation-artifacts/{deferred-work.md,sprint-status.yaml}`, `coverage-baseline.txt` -- per the Code Map; commit an auto-raised baseline.

**Acceptance Criteria:**
- Given the finished change, when non-test code under `crates/zanshin-jj/src` is searched for `std::env::`, `env::var` and `vars_os`, then every hit is in `environment.rs`.
- Given the finished change, when the workspace is searched for `set_var`/`remove_var` outside `#[cfg(test)]` modules, `tests/`, `benches/` and `crates/test-helpers`, then there is no hit.
- Given the app bootstrap, when `_startApp` runs, then `adoptLoginShellEnvironment()` completes before `zanshinAppFactory.create()` is called, and each returned warning is logged as `<code>: <message>`.
- Given the finished change, when `cargo make test` runs, then it is green (a `test-flutter` failure is acceptable only if shown pre-existing at the baseline revision), including clippy pedantic, the doc-sync test, the extern-fn coverage guard and the ratchet (new files ≥ 80%).

## Spec Change Log

### 2026-09-25 — Redirect by Ralph: Dart reads the shell, Rust adopts the map (supersedes the conflicting parts of the intent contract)

**Trigger.** After commit `8d5b89a` Ralph rejected the placement: the adoption ran inside `_startApp` AFTER the settings load and the worker start, so the shell's time added to the boot. It must run inside `ZanshinBootSequence` — during the splash, in parallel with the settings load — where no `ZanshinWorker` exists. Decided (Ralph, 2026-09-25): **(1) Dart reads the login-shell environment and hands the map to Rust; (2) Dart builds the `env.login_shell_unresolved` warning.** This is the story text's own reading ("the resolution in the app bootstrap … the map crosses to Rust once at init").

**New design — authoritative where it conflicts with the intent contract, Code Map, Tasks or matrix above:**
- **Reader (Dart, `packages/zanshin_core`, new `lib/src/environment/login_shell.dart`).** `Future<LoginShellRead> readLoginShellEnvironment({String? shell, Duration timeout = const Duration(seconds: 10)})` — `shell` null or empty → `Platform.environment['SHELL']`; still null/empty → failure `SHELL is not set`. Spawns `Process.start(shell, ['-l', '-i', '-c', cmd], mode: ProcessStartMode.detachedWithStdio)` — detached = `setsid()` in the Dart runtime (`runtime/bin/process_macos.cc`), so an interactive `zsh -i` never sees a controlling terminal (this RESOLVES the timeout-arm terminal deferral). `cmd` = the same `printf BEGIN; /usr/bin/env -0; printf END` line (same opaque markers). Close stdin at once, drain stderr, collect stdout BYTES until the end marker follows the begin marker (NOT EOF), then cancel the subscription and leave the shell to exit on its own (it is not our child — no reaping). Parse like before: NUL-separated entries, split at the first `=` after the first byte, skip entries without one, keep raw bytes. Failure reasons: `timed out after <N> ms` (then `Process.killPid(pid, ProcessSignal.sigkill)`), `could not start it: <ProcessException.message>`, `it printed no environment` (stdout ended before the end marker, OR the dump parsed to zero entries — a detached process has no exit code, so `it exited with …` is gone). Message format unchanged: `Could not read the login-shell environment from <shell>: <reason>. Using the environment Zanshin was started with.` / `Could not read the login-shell environment: SHELL is not set. Using the environment Zanshin was started with.` The warning is a Dart-built `ZanshinWarning(code: ZanshinWarningCode.loginShellUnresolved, …)`. The reader never touches FFI.
- **Adoption (Dart).** `Future<LoginShellEnvironmentResult> adoptLoginShellEnvironment({String? shell, Duration timeout = const Duration(seconds: 10)})` (top-level, barrel-exported with `LoginShellEnvironmentResult`): read; on success call the FFI adapter DIRECTLY on the calling isolate (installing a map is cheap — no worker, no blocking) and return no warnings; on failure return the one warning and call nothing. `timeout` negative or beyond `0xFFFFFFFF` ms → `ArgumentError` before anything runs (keep `loginShellTimeoutMillis`-style guard). The worker path goes away: remove `ZanshinWorker.adoptLoginShellEnvironment`, `EnvironmentAdoptCommand`, its dispatch arm and import.
- **Wire (edit in place, WIP rule).** `table EnvironmentVariable { name: [ubyte]; value: [ubyte]; }` (bytes — non-UTF-8 survives; a nested helper table like `ChangeIdRef`, not counted as a request table) and `table EnvironmentAdoptRequest { kind: RequestKind; variables: [EnvironmentVariable]; }` (drop `shell`/`timeout_ms`). `zanshin_environment_adopt(data, len)` ladder rows 1-4: null → `ffi.null_pointer`; unverifiable / wrong kind → `ffi.invalid_argument`; `variables` absent or EMPTY, or an entry without `name` or with an empty `name` → `jj.invalid_input` (`envelope.rs::missing_field` style; an empty environment is never a login shell's); an absent `value` is the empty value. Success: ok envelope, NO payload, NO warnings (`CallReport::default()`). Keep the extern fn body a one-line delegation to a normal fn so cargo tests credit the logic.
- **Rust (`zanshin-jj`).** `environment.rs` keeps the write-once store, `snapshot`/`var_os`, `split_paths`, `git_subprocess_options`/`git_environment`; its resolver (spawn, reader thread, `wait_until`/`Ended`, markers, parser, `resolve_shell`) is REMOVED — zanshin-jj spawns no process. New `pub fn adopt_environment(environment: HashMap<OsString, OsString>)`: stores it if nothing is adopted yet, else a no-op (documented; hot restart). Remove `WarningKind::LoginShellUnresolved`, `ENV_LOGIN_SHELL_UNRESOLVED` + its `warning_code` arm + literal-table row, the `api_stability` arm (back to 24) and pin the new fn instead. The `tracing_init.rs` git-spawn cap STAYS (git still receives the adopted map).
- **Bootstrap.** `ZanshinBootSequence` gains a required injected `Future<void> Function() adoptShellEnvironment` (no `zanshin_core` import there). `_load()` STARTS it before `openSettings()`, awaits settings, then — if still pending — `log('lese Shell-Umgebung…')` and awaits it, then `log('starte App…')` and `startApp(settings)`. A throw fails the boot like a settings failure. `main.dart` passes a private closure that awaits `adoptLoginShellEnvironment()` and logs each warning as `<code>: <message>` with `_log.warning`; `_startApp` no longer adopts.
- **Witnesses.** Rust: inline tests for the store/readers/git filter (no process); `tests/login_shell_environment.rs` (one `#[test]`) adopts a map built from `std::env::vars_os()` plus the fake shell's former edits (unset `JJ_CONFIG`, `JJ_USER`, `XDG_CONFIG_HOME`, `HOME`, `LC_ALL`/`LC_MESSAGES`, sentinel, `PATH` with the fake git) and keeps every assertion (config, fetch, clone, XDG ignore, HOME ceiling, second call no-op); `crates/zanshin-ffi/tests/environment_ffi.rs`: ladder rows 1-4 + one success install (own process) checked through a public reader (e.g. `zanshin_jj::config_get`). Dart (`zanshin_core`, one shared process — NEVER install there): `test/environment/login_shell_test.dart` for the reader with fake `#!/bin/sh` shells (success with rc noise + a background job holding stdout + odd/non-UTF-8 values, timeout 200 ms returns < 5 s, cannot start, no dump, empty dump, `SHELL` empty, default timeout outlasting a `sleep 1` shell, argument guards); the real-cdylib FFI test calls `zanshin_environment_adopt` only with REFUSED requests (absent/empty `variables`) — enough for the extern-fn guard; drop the `_cases` row (the envelope carries no warnings); `ZanshinWarningCode.values` keeps the code (25). App: `zanshin_bootstrap_test.dart` passes a stub to every construction and gains a test that `startApp` is not called before the adoption completes (RESOLVES the `_startApp` test-seam deferral).
- **Docs.** `ffi-abi.md` (symbol row: `EnvironmentAdoptRequest`, errors `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, no-payload success, no warnings; ladder rows 1-4; `EnvironmentVariable` next to `ChangeIdRef`/`CommitIdRef` as uncounted helper tables; drop the "only `zanshin_environment_adopt` carries it" warning note); `rust-error-codes.md` (`env` domain → the `zanshin_core` login-shell reader; the warning row says it is BUILT IN DART and never on an envelope — the one exception to the `envelope.rs` single-emission rule; `jj.invalid_input` row names the adopt request); revert the review's "Zanshin-only exception" notes in `envelope.fbs`'s `Warning` doc and `warning.rs` (no such code is on the wire any more) but keep/adjust `warning.dart`'s (the Dart-built code). `deferred-work.md`: the timeout-arm zsh item and the `_startApp` seam item → RESOLVED (Story 9.36 redirect); the rest stays. `sprint-status.yaml` 9-36 summary gets a dated "REDIRECT 2026-09-25" note.

**Known-bad state avoided.** The shell's run time serialized behind settings + worker start (slower boot); an interactive shell able to grab the launching terminal; a Rust-only resolver that needed `unsafe` for `setsid`.

**KEEP.** The write-once store and its "adopted map else process env" readers; `ConfigEnv::from_vars` and the `detect.rs`/`wc_ops.rs` rerouting; the git-map locale filter at both `GitSubprocessOptions` sites; the `tracing_init.rs` git-spawn cap; the message texts and the marker/`env -0`/parse rules; the one-`#[test]` integration binary and all its witnesses; never a successful adoption in the shared Dart test process.

## Review Triage Log

### 2026-09-25 — Review pass
- verdicts: 36 findings — high 0, medium 4, low 25, false 7, maybe-false 0
- findings:
  - `[medium]` `[patch]` (blind) Every fetch/clone writes the whole adopted login-shell environment (API tokens exported in an rc file included) to the logs — verified: jj-lib `git_subprocess.rs:147` logs `debug!(cmd = ?git_cmd, …)`, std's `Debug for Command` prints every `.envs` variable as `KEY="value"` (`sys/process/unix/common.rs:553-556`), and the console sink is always on at TRACE. Patched: `tracing_init.rs::git_subprocess_cap` caps target `jj_lib::git_subprocess` at INFO in both sinks (file keeps `ZANSHIN_LOG` on top), `// WHY:` + unit test `git_spawn_debug_lines_reach_neither_sink`.
  - `[medium]` `[patch]` (blind) The login shell is SIGKILLed right after the end marker; an interactive `zsh -i` under a controlling terminal (Zanshin via `flutter run`) has taken the terminal's foreground process group and only hands it back on a normal exit, so the launching tool stops with SIGTTIN — derived from zsh's `init_io`/`acquire_pgrp`/`release_pgrp`; `setsid` is unstable in std 1.95 and `unsafe` is barred in zanshin-jj. Patched: the success arm now `wait_until(&mut child, deadline)` (kills only past the deadline); the timeout arm's residual is deferred.
  - `[low]` `[reject]` (blind) On timeout only the shell pid is killed; rc-started orphans hold the pipe and the reader thread lingers, one per retry — real, but a timeout is rare and retries happen only on a hot restart; the fix needs process-group kills, which a job-control `zsh -i` defeats without `setsid`.
  - `[low]` `[reject]` (blind) `timeout_ms = 0` is accepted and always times out — the spec's intent contract defines the accepted range as `0..0xFFFFFFFF` ms; refusing 0 would edit the spec, and Dart always sends the 10 s default.
  - `[low]` `[patch]` (blind) `wc_ops.rs::xdg_config_home` fell back to the PROCESS `HOME` via `etcetera::home_dir()` while the config stack reads the adopted `HOME` — patched: a non-empty adopted `HOME` first, `etcetera::home_dir()` only when absent; the deferred-work bullet no longer lists `etcetera`.
  - `[low]` `[patch]` (blind) The end-to-end witness covered only `config_get` and `git_fetch` — patched with the verification-gap rows below (clone, XDG ignore, HOME ceiling, `None` → `$SHELL`); the "one settings reload of a pre-adoption handle" doc claim stays unwitnessed (the app adopts before any repo opens).
  - `[low]` `[reject]` (blind) One argv for every shell (tcsh takes `-l` only alone, nu/pwsh quoting) — an unsupported shell degrades to the documented fallback warning; such login shells are rare on macOS and per-shell argv adds branches.
  - `[low]` `[reject]` (blind) `_startApp` lets an exception from `adoptLoginShellEnvironment()` abort the boot — only reachable through a worker death or an `internal.panic` (nothing on the path panics); a dead worker leaves the app unusable anyway, so failing the boot loudly is correct. No timing log: cosmetic.
  - `[low]` `[patch]` (blind) `Warning` docs (`envelope.fbs` table, `warning.rs` `Warning.message`, `warning.dart` class + `message`) still say every code is `jj.*` and every message the CLI's — patched: each names the one Zanshin-only exception; `cargo make codegen` regenerated the doc-carrying files.
  - `[low]` `[patch]` (blind) sprint-status says `environment.rs 96.81` / `99.41%` while the baseline reads 97.16 — patched: 97.16 / 99.42%, plus the review summary.
  - `[low]` `[reject]` (blind) No `getpwuid` fallback when `$SHELL` is unset — launchd always sets `SHELL` for GUI apps; the fallback is the documented warning and the fix adds a libc lookup.
  - `[false]` `[reject]` (edge) An empty dump (`env -0` failing) would adopt an empty environment — `/usr/bin/env -0` works on this macOS (checked: NUL-separated output); without it nothing is printed between the markers only if `env` fails, which the supported macOS never does.
  - `[medium]` `[patch]` (edge) No `setsid`: the interactive shell takes or stops on the terminal — same root cause as the blind SIGKILL finding; patched there.
  - `[low]` `[reject]` (edge) Orphaned rc processes survive a timeout and keep the reader thread alive — same root cause as the blind orphan finding; rejected there.
  - `[low]` `[reject]` (edge) After a timeout the orphaned reader drains an endlessly writing descendant with unbounded memory and quadratic marker rescans — same root cause (post-timeout orphans); a normal dump is a few KB and the success path returns at the end marker.
  - `[low]` `[reject]` (edge) Timeout 0 spawns and kills a shell at once — same root cause as the blind timeout-0 finding; spec-defined range.
  - `[low]` `[reject]` (edge) An empty `$SHELL`/`shell: ''` produces "…from : could not start it…" instead of "SHELL is not set" — cosmetic wording of the same fallback; unlikely.
  - `[low]` `[reject]` (edge) `_startApp` shows BootFailure when adoption throws — same root cause as the blind `_startApp` finding; rejected there.
  - `[low]` `[patch]` (edge) A negative sub-millisecond `Duration` truncated to 0 ms and was accepted although the doc says a negative timeout throws — patched: `loginShellTimeoutMillis` rejects `timeout.isNegative`; `Duration(microseconds: -500)` added to `bad_arguments_are_refused_on_the_calling_side`.
  - `[false]` `[reject]` (edge) An adoption during a running verb mixes environments within one verb — the only caller adopts before any repo is opened, and adoption and every verb are FFI calls on the same worker isolate, so they cannot overlap.
  - `[low]` `[patch]` (edge) `xdg_config_home`'s `<home>` fallback reads the process `HOME` — same root cause as the blind `HOME` finding; patched there.
  - `[low]` `[patch]` (verification-gap) `Repo::clone`'s git environment had no post-adoption witness — patched: the integration test truncates `git-env.txt`, clones from the fake remote and asserts `ZANSHIN_SENTINEL=1`, `LC_MESSAGES=C`, no `LC_ALL=`.
  - `[low]` `[patch]` (verification-gap) The adopted `XDG_CONFIG_HOME` git-ignore read was never exercised — patched: `<tmp>/xdg/git/ignore` keeps a matching workspace file untracked after `status()` while a control file is tracked (process `XDG_CONFIG_HOME` points elsewhere).
  - `[low]` `[patch]` (verification-gap) `find_repo_root`'s adopted `HOME` ceiling had no witness — patched: `<tmp>/.jj` above the adopted `HOME`, `find_repo_root(<tmp>/home/sub)` returns `None`.
  - `[low]` `[patch]` (verification-gap) The default 10 s timeout and `_startApp`'s adopt-before-app order were unverified — patched the timeout half: `the_default_timeout_waits_for_a_slow_shell` (`sleep 1; exit 3`, no `timeout`). Writing it exposed a real bug, also fixed: the Dart VM reaps every child while one of its own `Process`es runs, so `try_wait` failed and the old code reported "timed out" ~1 s in and SIGKILLed a pid it no longer owned — `wait_until` now returns `Ended { Exited, Reaped, Killed }` and never kills on `Reaped` ("it printed no environment"). The `_startApp` half has no test seam → deferred.
  - `[low]` `[patch]` (verification-gap, other) sprint-status coverage figure disagrees with the baseline — same root cause as the blind bookkeeping finding; patched there.
  - `[false]` `[reject]` (intent) Rust, not the Dart bootstrap, spawns and parses the shell, so the map itself never crosses the FFI — no user-observable difference: the map lands in Rust once and never changes; the bootstrap still triggers it before any repo opens (Design Notes).
  - `[false]` `[reject]` (intent) Adoption is an opt-in method, guaranteed only by `main.dart` — the app is the only `ZanshinWorker` consumer; `zanshin-mcp` uses zanshin-jj directly and is documented as never adopting (deferred).
  - `[false]` `[reject]` (intent) The config stack reads an ambient global rather than a passed parameter — the intent's "explicit map" is contrasted with `std::env::set_var`; readers get the adopted map, never a mutated process environment.
  - `[low]` `[defer]` (intent) git's child environment is the process environment overlaid with the map, so rc-unset variables remain — jj-lib's `envs` cannot remove; frontmatter `deferred` + deferred-work.md.
  - `[medium]` `[defer]` (intent) Signing, `git gc`, gix's in-process reads and `zanshin-mcp` still see launchd's environment — pre-existing, outside the intent's Scope (ConfigEnv + the git subprocess), no hook exists; frontmatter `deferred` + deferred-work.md (the `etcetera` part was patched).
  - `[low]` `[reject]` (intent) Resolution runs on every launch, terminal included, so a session override of an rc-assigned variable differs from the terminal `jj` — the decision text is unconditional ("once at start-up"), the shell inherits Zanshin's own environment so session exports survive unless the rc re-assigns them, and tty detection adds branches that misfire under `flutter run`.
  - `[low]` `[defer]` (intent) The warning is logged, not shown in the UI — UI is Ralph's scope; frontmatter `deferred` + deferred-work.md.
  - `[false]` `[reject]` (intent) The registry gains its first non-CLI code in a new `env` domain — documented in `rust-error-codes.md` (domain row + § Warning Codes note) and the `Warning` docs; no bad outcome.
  - `[false]` `[reject]` (intent) sprint-status says `done` while the spec says `in-review` — transient; finalization sets the spec to `done`.
  - `[low]` `[patch]` (intent) Untested surfaces (FFI/Dart success, `main.dart` order, `shell: null` → fake `$SHELL`, `JJ_CONFIG` set by the rc, clone) — patched: `SHELL` set to the fake shell and adoption with `None`, clone witness; FFI/Dart success stays excluded by design (one shared Dart test process; the wrapper has no success-only branch); `JJ_CONFIG`-set runs through the same `from_vars` lookup the unit test pins; `main.dart` order deferred.

## Design Notes

**Why Rust resolves, not Dart.** The map's consumers are Rust; resolving there avoids shipping a whole environment (non-UTF-8 values included) across FlatBuffers, and puts the spawn/timeout/parse logic under the Rust coverage ratchet with fake-shell cargo tests. "The map crosses to Rust once at init" holds: it lands in Rust once and never changes.

**Why always resolve, no terminal detection.** The decision says "once at start-up" without a condition. The shell inherits Zanshin's own environment, so a terminal launch keeps its session exports unless an rc file re-assigns the same variable; a tty check would also misfire under `flutter run` (piped stdout). Keeping one path keeps behaviour predictable.

**Why no Dart success witness.** `dart_test.yaml` runs every `zanshin_core` test file in one process against one cdylib; a successful adoption there would silently replace the environment (incl. the pinned `XDG_CONFIG_HOME`) for every later file. The extern fn has no success-only branch (warnings are empty or not), so the fallback witnesses credit it fully; success is witnessed in its own cargo test process.

**Why filter three locale variables.** jj-lib strips `LC_ALL`/`LANGUAGE` and forces `LC_MESSAGES=C` so it can parse git's stderr, then applies `environment` last; a shell map carrying them would undo that. Dropping exactly those three reproduces the CLI's child environment.

Golden shape of the command string (markers are opaque constants):
```rust
let cmd = format!("printf '%s' '{BEGIN}'; /usr/bin/env -0; printf '%s' '{END}'");
Command::new(shell).args(["-l", "-i", "-c", &cmd]).stdin(Stdio::null()).stderr(Stdio::null()).stdout(Stdio::piped())
```

## Verification

**Commands** (foreground; if a toolchain is missing, put `~/development/sdks` on `PATH`; revert `pubspec.lock` drift after Dart runs):
- `cargo make codegen` then `git status` -- expected: exactly the four generated files change besides `schemas/envelope.fbs`.
- `cargo test -p zanshin-jj --test login_shell_environment` and `cargo test -p zanshin-ffi --test environment_ffi` -- expected: pass.
- `cargo make --allow-private test-core` -- expected: green incl. `test/worker/environment_test.dart` and `test/ffi/warning_test.dart`.
- `cargo make test` -- expected: green per the last AC; coverage ≥ baseline, extern guard OK.

## Auto Run Result

Status: done

**Summary.** At app start-up `app/lib/main.dart::_startApp` awaits the worker, calls the new `ZanshinWorker.adoptLoginShellEnvironment()`, logs each returned warning as `<code>: <message>`, and only then creates the app. The call crosses as `zanshin_environment_adopt` (handle-less, `EnvironmentAdoptRequest { kind, shell, timeout_ms }`, ok envelope with no payload, warnings only) into `zanshin_jj::adopt_login_shell_environment`, which runs `<shell> -l -i -c` once (`shell` absent = the process `$SHELL`), reads the `/usr/bin/env -0` dump between markers within the timeout (the end marker, not EOF, ends the read), and stores it in a write-once `static OnceLock` — never `set_var`. From then on `ConfigEnv::from_env` (HOME, XDG_CONFIG_HOME, JJ_CONFIG, the env layers, `$USER`), `detect.rs`'s HOME ceiling, `wc_ops.rs`'s XDG/HOME for the global git ignore, and the fetch/clone `git` subprocess (adopted map minus `LC_ALL`/`LANGUAGE`/`LC_MESSAGES`) read that map; with nothing adopted every reader sees the process environment as before. A failed read adopts nothing and returns exactly one new `env.login_shell_unresolved` warning (new `env` registry domain, the first Zanshin-only code); a second call after a success is a no-op.

**Files changed.**
- `crates/zanshin-jj/src/environment.rs` (new) — store, adoption, resolver (thread-bounded read, `wait_until` → `Ended { Exited, Reaped, Killed }`), dump parser, `snapshot`/`var_os`, `git_subprocess_options`; inline tests on local stores.
- `crates/zanshin-jj/src/{config,detect,wc_ops,remotes,repo,warning,lib}.rs` — readers through the store (`ConfigEnv::from_vars`), git options helper at both sites, `WarningKind::LoginShellUnresolved`, re-export.
- `crates/zanshin-jj/tests/login_shell_environment.rs` (new, one `#[test]`) and `tests/api_stability.rs` — end-to-end witness through the real static; API pins.
- `crates/zanshin-ffi/src/environment.rs` (new), `envelope.rs`, `lib.rs`, `tracing_init.rs` — the extern fn, `ENV_LOGIN_SHELL_UNRESOLVED`, `finish_envelope` doc, the `jj_lib::git_subprocess` INFO cap in both log sinks.
- `crates/zanshin-ffi/tests/environment_ffi.rs` (new), `tests/ffi_abi_doc_sync.rs` (60 exports).
- `schemas/envelope.fbs` + the four generated files (`envelope_generated.rs`, `zanshin_ffi.h`, `envelope_zanshin.ffi_generated.dart`, `bindings.dart`).
- `packages/zanshin_core/lib/src/ffi/environment.dart` (new), `lib/src/ffi/warning.dart`, `lib/src/worker/{commands,isolate}.dart`, `lib/zanshin_core.dart` — command, method, dispatch, `LoginShellEnvironmentResult`, decoder, warning constant, barrel export.
- `packages/zanshin_core/test/worker/environment_test.dart` (new), `test/ffi/warning_test.dart` — real-cdylib fallback witnesses (never a success), argument guards, default timeout; decoder table + 25 codes.
- `app/lib/main.dart` — adopt and log before the app exists.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` — symbol row and counts, `env` domain, warning row, ladder notes.
- `_bmad-output/implementation-artifacts/{deferred-work.md,sprint-status.yaml}`, `coverage-baseline.txt` — 9.27 item RESOLVED, new 9.36 section, 9-36 `done`, baseline (2 new files, tracing_init.rs/wc_ops.rs raised).

**Review findings breakdown.** 36 findings (high 0, medium 4, low 25, false 7, maybe-false 0).
- Patches applied (re-engaged implementation subagent): env-in-debug-log leak capped in both sinks (medium); success path waits for the shell instead of SIGKILL, so a `zsh -i` hands the terminal back (medium); `wc_ops` `<home>` fallback reads the adopted HOME; integration witnesses for clone, adopted XDG git ignore, adopted HOME ceiling and `None` → `$SHELL`; Dart default-timeout witness, which exposed and fixed a real bug (Dart VM reaps children → old code misreported "timed out" and killed a pid it no longer owned); negative sub-ms Dart timeout rejected; `Warning` docs name the Zanshin-only exception (codegen); sprint-status numbers.
- Deferred (5, frontmatter `deferred` + deferred-work.md): rc-unset vars stay in git's env (low); signing/`git gc`/gix/`zanshin-mcp` keep the process env (medium); UI does not show the warning (low); no test seam for `_startApp`'s adopt-before-app order (low); timeout arm still kills a real `zsh -i` under a tty (low).
- Rejected: orphaned rc jobs / lingering reader thread / unbounded post-timeout read after a timeout (low — rare, needs process-group kills a job-control zsh defeats without `setsid`); `timeout_ms = 0` (low — spec-defined range); one argv for every shell (low — unsupported shells get the fallback warning); `_startApp` exception propagation (low — only a dead worker or a panic reaches it; loud failure is correct); no `getpwuid` fallback / empty `$SHELL` wording (low — launchd always sets `SHELL`); terminal-launch detection (low — the decision is unconditional); empty-dump adoption (false — `env -0` works on supported macOS); concurrent adoption during a verb (false — same worker thread); Rust-side resolution, opt-in method, global store, new `env` domain, transient status mismatch (false — no bad outcome).

**Follow-up review recommendation:** `true` — first pass with two `medium` entries patched (patched by verdict: high 0, medium 2, low 8). Named risk: the patch pass added unreviewed process-handling logic — the `Ended::Reaped` path (a host that reaps children, e.g. the Dart VM) and the success-path wait for the shell's own exit — witnessed only indirectly (the Dart default-timeout test accepts either reason; no real `zsh -i` under a controlling terminal was ever exercised).

**Verification performed.**
- `cargo make codegen` twice (initial and after the doc patch) → no drift beyond the committed generated files; `pubspec.lock` drift reverted after every Dart run.
- `cargo test -p zanshin-jj --test login_shell_environment`, `cargo test -p zanshin-ffi --test environment_ffi`, the inline `environment::tests` and `tracing_init::tests::git_spawn_debug_lines_reach_neither_sink` → pass.
- Gate step by step via `cargo make --allow-private` (a full `cargo make test` stops at `test-flutter`): `test-cargo`, `test-clippy`, `test-fmt`, `test-dart-analyze`, `test-dart-format`, `test-core` (551 tests), `test-core-analyze`, `test-core-format`, all `test-shell*`/`test-settings*`, `test-cargo-deny`, `test-cargo-hygiene`, `test-jj-adapter-hygiene`, `coverage` → exit 0, before and after the review patches. `test-flutter` → exactly the 3 pre-existing `zanshin_bootstrap_test.dart` splash-card failures (documented since 9.27; no app test imports `main.dart`).
- Coverage 99.42% overall; new files `zanshin-ffi/src/environment.rs` 100, `zanshin-jj/src/environment.rs` 97.16; `tracing_init.rs` 94.96 → 95.91, `wc_ops.rs` 98.15 → 98.27; extern-fn guard OK.
- Matrix audit: every row covered by a test that ran and passed (inline `environment::tests`, `config::tests`, `tests/login_shell_environment.rs`, `test/worker/environment_test.dart`).

**Residual risks.**
- The terminal-takeover analysis for a real `zsh -i` is derived from zsh's source, not observed; the timeout arm can still leave a terminal's foreground group dead (deferred).
- Signing, `git gc`, gix's own config reads and `zanshin-mcp` still see the started-with environment (deferred, medium for signing users).
- The UI shows nothing when the adoption falls back; only the `zanshin.bootstrap` log does.

### Redirect 2026-09-25 — Dart reads the shell, Rust adopts the map

Implemented the Spec Change Log entry of the same date on top of `8d5b89a` (uncommitted).

**What changed.**
- `packages/zanshin_core/lib/src/environment/login_shell.dart` (new): `readLoginShellEnvironment({shell, timeout = 10 s})` → sealed `LoginShellRead` (`LoginShellVariables` / `LoginShellUnresolved`); `Process.start(<shell>, ['-l','-i','-c', cmd], mode: detachedWithStdio)`, stdin closed, stderr discarded, stdout bytes collected until the end marker follows the begin marker, subscriptions cancelled and the shell left to exit; timeout → `Process.killPid(pid, sigkill)`. Same markers, `env -0` parse rule and message texts; reasons now `timed out after N ms` · `could not start it: <ProcessException.message>` · `it printed no environment` (EOF before the end marker or zero entries) · `SHELL is not set` (shell null/empty and `SHELL` unset/empty). `adoptLoginShellEnvironment` (barrel, with `LoginShellEnvironmentResult`) reads, then calls the FFI adapter directly on the calling isolate; NUL shell / negative or > `0xFFFFFFFF` ms timeout → `ArgumentError` before anything runs. `readLoginShellEnvironmentInternal(environment:)` lets tests run without a `SHELL`.
- Wire: `EnvironmentVariable { name, value: [ubyte] }` (uncounted helper) + `EnvironmentAdoptRequest { kind, variables }`; `cargo make codegen` (all four generated files). `zanshin_environment_adopt`: ladder rows 1-4 (`variables is required` for absent/empty, `variables[<i>].name is required`), absent value = empty, success = ok, no payload, `CallReport::default()`; the extern body is a one-line call of `adopt()`.
- `zanshin-jj`: resolver removed; `pub fn adopt_environment<S: BuildHasher>(HashMap<OsString, OsString, S>)` (generic hasher for `clippy::implicit_hasher`; the pin names `adopt_environment::<RandomState>`), write-once, a later call a logged no-op. `WarningKind::LoginShellUnresolved`, `ENV_LOGIN_SHELL_UNRESOLVED` + arm + literal-table row removed; `api_stability` back to 24. `warning.rs` and the fbs `Warning` doc are byte-identical to pre-9.36.
- Dart worker path removed (`EnvironmentAdoptCommand`, `ZanshinWorker.adoptLoginShellEnvironment`, dispatch arm, import — `commands.dart`/`isolate.dart` identical to pre-9.36); `warning_test.dart`'s `_cases` row dropped (values stay 25); `warning.dart` docs name the Dart-built code.
- App: `ZanshinBootSequence(adoptShellEnvironment:)` — started right after `log('lade Settings…')`, before `openSettings()`, `..ignore()`d so an early failure is not unhandled while the settings load; after the settings, `log('lese Shell-Umgebung…')` only while still pending, then awaited (a throw → `BootFailure`), then `log('starte App…')`. `main.dart::_adoptShellEnvironment` logs `<code>: <message>`; `_startApp` is back to its pre-9.36 body.
- Docs/bookkeeping: `ffi-abi.md`, `rust-error-codes.md`, `deferred-work.md` (timeout-arm zsh + `_startApp` seam RESOLVED, 9.27 entry and UI item re-pointed), `sprint-status.yaml` REDIRECT note, this spec's frontmatter `deferred` (two entries marked RESOLVED, UI entry re-pointed), `coverage-baseline.txt`.

**Tests.** Rust: inline `environment::tests` (first map stays, readers, git filter), `tests/login_shell_environment.rs` (adopts `vars_os()` plus the former rc edits; every assertion kept; second adoption of `JJ_USER=Other User` is a no-op), `crates/zanshin-ffi/tests/environment_ffi.rs` (null, garbage, wrong/untagged kind, absent/empty `variables`, nameless and empty-named entry, one install read back through `zanshin_jj::config_get` — `user.name` from `JJ_USER`, empty `user.email` from an absent value), inline reader test (raw bytes). Dart: `test/environment/login_shell_test.dart` (rc noise + background job + odd and non-UTF-8 values; 200 ms timeout < 5 s with the sleeper gone per `pgrep`; cannot start; no dump; empty dump; null/empty shell with `SHELL` absent/empty and the `$SHELL` fallback; default timeout outlasting `sleep 1`; argument guards on both functions; the adoption's failure path; the parser), `test/ffi/environment_test.dart` (real cdylib, refused requests only — credits the extern fn). App: every `ZanshinBootSequence` gets a stub; new tests pin that `startApp` waits for the adoption (status sequence `lade Settings…` → `lese Shell-Umgebung…` → `starte App…`) and that a failed adoption fails the boot with the persisted theme. Two pre-existing failure-page tests now `flush` before completing `startApp`'s error — the extra await hop otherwise let an error with no listener count as unhandled. Mutation checks: dropping `Process.killPid` fails the timeout test; dropping `..ignore()` fails the new failure test.

**Verification.** `cargo make codegen` → only the four generated files beside `schemas/envelope.fbs`; `pubspec.lock` reverted after every Dart/Flutter run. Via `cargo make --allow-private`: `test-cargo`, `test-clippy`, `test-fmt`, `test-core` (554 tests), `test-core-analyze`, `test-core-format`, `test-dart-analyze`, `test-dart-format`, `test-cargo-deny`, `test-cargo-hygiene`, `test-jj-adapter-hygiene`, `coverage` → exit 0; `test-flutter` → exactly the 3 pre-existing splash-card failures. Coverage 99.47% overall; `crates/zanshin-jj/src/environment.rs` 97.16 → 100.00 (baseline raised), `crates/zanshin-ffi/src/environment.rs` 100; extern guard OK. `test-shell*`/`test-settings*` not run (packages untouched, no reference to the removed API).

**Residual risks.** The detached-shell behaviour relies on the Dart runtime's `setsid` for `detachedWithStdio` (as the Change Log states); no real `zsh -i` under a terminal was exercised. On timeout only the shell pid is killed — rc-started background jobs survive, but our pipe ends are closed. The shell's run time now overlaps the settings load; a slow rc file still delays `startApp`, now with the `lese Shell-Umgebung…` status. Signing, `git gc`, gix and `zanshin-mcp` deferrals unchanged.
