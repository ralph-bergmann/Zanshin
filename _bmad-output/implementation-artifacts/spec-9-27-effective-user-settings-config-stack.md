---
title: 'Story 9.27: `Repo` opens with the effective jj config — identity, op metadata, snapshot/fsmonitor knobs (config-stack parity)'
type: 'feature'
created: '2026-09-23'
status: 'done'
baseline_revision: '677dbf546fc2d19203019b06b6ea1ef431aa64fd'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/docs/coverage.md'
warnings: ['oversized']
deferred:
  - summary: >-
      Read verbs keep the UserSettings of the last open/mutation; only the 16 &mut verbs run refresh_settings.
    evidence: |-
      Reads re-resolve every by-name key per call (aliases, mine() user.email, ui.conflict-marker-style, log defaults), but jj-lib-internal settings a read consults through the loaded Workspace (e.g. merge.* when a merge commit's parent tree is merged for status/show) stay stale until the next mutation. Before 9.27 reads never saw user settings at all. Story 9.26 makes every public verb a precondition call site (receiver rule: a read that needs it becomes &mut self); refresh_settings is the hook it runs first.
    location: >-
      crates/zanshin-jj/src/repo.rs::refresh_settings
    severity: low
  - summary: >-
      A wrong-typed key jj-lib reads while loading (git.*, ui.conflict-marker-style, working-copy.*, fsmonitor.*) now refuses Repo::open with jj.config_error.
    evidence: |-
      CLI parity (every CLI command in such a repo fails at start-up). Product consequence: the repo cannot be opened in Zanshin until the config is fixed, so Story 9.28's config surface must be reachable without an open Repo handle.
    location: >-
      crates/zanshin-jj/src/config.rs::load_config_fault
    severity: low
  - summary: >-
      Repo::init leaves .jj/ behind when the git backend fails during creation (pre-existing; now also reachable via a wrong-typed git.* key).
    evidence: |-
      clone and both convert verbs roll .jj/ back, init never did; whether jj git init leaves it too is unverified. Story 9.20 (init/clone destination parity) owns it.
    location: >-
      crates/zanshin-jj/src/repo.rs::init
    severity: low
  - summary: >-
      Repo::git_fetch and Repo::describe commit an operation even when nothing changed; the CLI's tx.finish prints "Nothing changed." and writes no operation (and so shows no identity warning).
    evidence: |-
      cli/src/commands/git/fetch.rs:254 and cli/src/commands/describe.rs:262 @ v0.44.0 end in tx.finish, which returns early without committing when !tx.repo().has_changes() (cli/src/cli_util.rs:2790-2795). Zanshin's remotes.rs::git_fetch and mutate.rs::describe always tx.commit. Pre-existing op-log divergence; identity_missing correctly follows Zanshin's committed op. git_fetch is reworked by Story 9.30.
    location: >-
      crates/zanshin-jj/src/remotes.rs::git_fetch, crates/zanshin-jj/src/mutate.rs::describe
    severity: medium
  - summary: >-
      A Finder/Dock-launched Zanshin gets launchd's environment, not the user's shell profile, so JJ_CONFIG / XDG_CONFIG_HOME / JJ_USER / JJ_EMAIL / VISUAL / EDITOR set in a shell rc differ from what the terminal jj sees.
    evidence: |-
      The config stack reads these env vars exactly like the CLI (JJ_CONFIG and XDG_CONFIG_HOME already since Story 4.9); the env the GUI process receives is an app-launch/product decision (e.g. import the login shell environment at startup), not a jj-parity bug in the stack.
    location: >-
      crates/zanshin-jj/src/config.rs::ConfigEnv::from_env
    severity: medium
  - summary: >-
      Three app splash-card layout tests fail at the baseline revision (pre-existing), so cargo make test is red at test-flutter independent of this story.
    evidence: |-
      app/test/features/bootstrap/zanshin_bootstrap_test.dart ("an empty status and an unknown version still paint the card", "the splash card lays its footer out on the design grid", "the status line follows its listenable and stays right-aligned"; Expected 524.0, Actual 584.0) fail identically with all 9.27 changes stashed at 677dbf546fc2d19203019b06b6ea1ef431aa64fd. No app/ file is touched by this story.
    location: >-
      app/test/features/bootstrap/zanshin_bootstrap_test.dart
    severity: medium
  - summary: >-
      pubspec.lock drifts on every dart/flutter resolve (vector_math 2.4.2 -> 2.4.3); reverted from this change.
    evidence: |-
      Unrelated to 9.27; the lock wants a deliberate pub upgrade commit.
    location: >-
      pubspec.lock
    severity: low
  - summary: >-
      Clone, init and both converts never report identity_missing, although the CLI warns after the creation transactions it finishes (git clone's fetch, git init's head import).
    evidence: |-
      The CLI warning sits in finish_transaction, reached by jj git clone via tx.finish(ui, "fetch from git remote into empty repo") (cli/src/commands/git/clone.rs:457 @ v0.44.0, also :314/:352) and by jj git init on an existing Git repo via tx.finish(ui, "import git head") (init.rs:268). zanshin_repo_clone/_init/_convert return only a RepoHandle, so a GUI clone with an empty identity (the typical first action on a new machine) writes its ops and @ commit with the empty identity and the UI learns it only on the first later mutation. Fix needs a decision: new identity_missing surface on the handle-producing results (FFI + Dart), or the UI calls Story 9.28's config_get user.name/user.email after creation. Follow-up review 2026-09-23 (BH + ECH).
    location: >-
      crates/zanshin-jj/src/repo.rs::Repo::clone, crates/zanshin-jj/src/repo.rs::Repo::init, crates/zanshin-jj/src/convert.rs::convert_colocated
    severity: medium
---

<intent-contract>

## Intent

**Problem:** `Repo::open`/`init`/`clone` and both convert verbs build their `UserSettings` from `repo.rs::make_settings` (`:1729-1746`): jj-lib's defaults plus ONE hardcoded user layer (`user.name = "Zanshin"`, `user.email = "zanshin@localhost"`, `operation.username = "zanshin"`, `operation.hostname = "localhost"`) — no user config file, no `JJ_CONFIG`, no repo or workspace layer, no environment layers. Every operation Zanshin writes therefore says `zanshin@localhost` in `jj op log`, every commit it creates or rewrites is signed `Zanshin <zanshin@localhost>` (jj-lib `UserSettings::signature()` feeds `CommitBuilder`), and jj-lib's working-copy settings (`fsmonitor.*`, `snapshot.*`) never see the user's config. The CLI builds its `UserSettings` from the full stack (`cli/src/config.rs` @ v0.44.0: Default → System → EnvBase → User → Repo → Workspace → EnvOverrides → CommandArg). `config::load_with` already mirrors Default/User/Repo/Workspace, but only for named reads (aliases, git options, conflict markers), never for the settings the workspace is opened with. Story 9.26 cannot be CLI parity until this lands, and a user alternating between the CLI and Zanshin sees two different authors in one history.

**Approach:** Build `UserSettings` from the same effective stack the CLI uses, in the CLI's order, everywhere a workspace is opened or created; add the missing System, EnvBase and EnvOverrides layers to `config::load_with`; re-derive settings so config edits (Story 9.28) and an external `jj config set` take effect without restarting Zanshin; report an empty identity as a typed fact exactly where the CLI warns. jj reads identity from its OWN config only — there is no `.gitconfig` fallback to port.

## Boundaries & Constraints

**Always:**
- **Stack order and sources exactly as the CLI** (`cli/src/config.rs`): Default (jj-lib builtin), System (`/etc/jj/config.toml` + `/etc/jj/conf.d`, `system_config_dir` `:377`), EnvBase (`env_base_layer` `:736-764`: `operation.hostname` = `whoami::hostname()`, `operation.username` = `whoami::username()` with `$USER` fallback, `NO_COLOR` → `ui.color`, `VISUAL`/`EDITOR` → `ui.editor`), User files (already mirrored), Repo + Workspace secure layers (already mirrored), EnvOverrides (`env_overrides_layer` `:789-817`: `JJ_USER`, `JJ_EMAIL`, `JJ_TIMESTAMP`, `JJ_RANDOMNESS_SEED`, `JJ_OP_TIMESTAMP`, `JJ_OP_HOSTNAME`, `JJ_OP_USERNAME`, `JJ_EDITOR`, `JJ_PAGER`). Zanshin has no CommandArg layer. `ConfigResolutionContext.hostname` = `whoami::hostname()` (today `""`), so `--when.hostnames` scopes resolve as in the CLI. `whoami` is the CLI's own crate — same values, `cargo deny` green.
- **Open order:** `DefaultWorkspaceLoaderFactory.create(root)` → `loader.repo_path()` (follows the `.jj/repo` file indirection of a secondary workspace) → effective stack for that repo + workspace → `UserSettings::from_config` → `loader.load(&settings, …)`. That is `Workspace::load`'s own body split in two (`lib/src/workspace.rs:410-419`, `:526-555`).
- **Creation paths** (`init`, `clone`, `convert_import` into a new dir): settings from the stack WITHOUT repo/workspace layers, because nothing exists yet; the returned `Repo` then re-opens with the full stack — the CLI's next invocation does the same.
- **Re-derive per invocation.** `UserSettings` is per-invocation in the CLI. Zanshin re-derives it — and reloads the `Workspace`, which captures settings in its `RepoLoader` and working copy — whenever the effective stack changed since it was last derived: at minimum after every Story 9.28 write and at every verb start when a file of the stack changed (fingerprint of paths + mtime/size). An unconditional per-verb reload is acceptable if step-02 measures it cheap (ADR-0002: `Workspace::load` ≈ 0.3–1 ms).
- **Empty identity is not an error.** jj-lib defaults `user.name`/`user.email` to `""` (`lib/src/config/misc.toml:48-50`); the CLI proceeds and warns after every transaction (`cli_util.rs:2387-2415`: "Name and email not configured. Until configured, your commits will be created with the empty identity, and can't be pushed to remotes."). Zanshin: `MutationResult.identity_missing { name: bool, email: bool }` (absent when both are configured). The UI turns it into the SourceTree-style "set your identity" prompt backed by Story 9.28. Never refuse, never substitute a placeholder.
- **Config faults refuse at open**, as the CLI fails at startup: unreadable file, invalid TOML, malformed `config-id`, wrong-typed value → `jj.config_error` with the path or key in `context` (new emitters: `zanshin_repo_open`/`_init`/`_clone`/`_convert`). No silent fall-back to defaults.
- **Tests stay machine-independent the CLI's way.** Every test binary's `ENV_GUARD` already pins `JJ_CONFIG=""` and `GIT_CONFIG_GLOBAL=""`; add `JJ_USER="Zanshin"`, `JJ_EMAIL="zanshin@localhost"`, `JJ_OP_HOSTNAME="localhost"`, `JJ_OP_USERNAME="zanshin"` there (jj's own test harness does exactly this), so identity and op metadata stay deterministic through the EnvOverrides layer. The 20+ hand-built `make_test_settings()` stubs are then redundant; retire them or derive them from the same env. Witnesses set a NON-default identity through `JJ_CONFIG` (single-test-binary rule, `tests/config_user_layer.rs`) and read op metadata and a fresh commit's signature back from the store.
- Surface: no new extern fn; `MutationResult` gains `identity_missing` (`.fbs` → `cargo make codegen` → `docs/ffi-abi.md`); `docs/rust-error-codes.md` row for the new `jj.config_error` emitters; coverage ratchet.

**Ask First:**
- Reload policy: fingerprint-triggered vs. unconditional per-verb re-derive (recommendation: fingerprint, unconditional only if it measures under 1 ms on `large-10k`).
- Where the builder lives: `config::user_settings_for(loader)` / `config::user_settings_for_new_workspace()` replacing `make_settings` (recommendation), or keep the name in `repo.rs`.
- Whether the cosmetic EnvBase/EnvOverrides keys (`ui.color`, `ui.editor`, `ui.pager`) are added for layer parity — they show up in Story 9.28's `config list` (recommendation: yes, five lines).

**Never:**
- No `.gitconfig` fallback for identity: jj-lib reads `user.name`/`user.email` only from its own stack (`lib/src/settings.rs:141-142`); git config is consulted by jj-lib for other things (`core.excludesFile`, fetch refspecs). Do not invent an import from git.
- No hardcoded identity anywhere in production code; no placeholder substitution for an empty identity.
- No config editing (Story 9.28), no CommandArg layer, no `--config`/`--config-file` flags.
- No lowering of `coverage-baseline.txt`, no `exclude_prefix`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Identity configured | `~/.config/jj/config.toml` has `user.name`/`user.email` | next op: `whoami` hostname/username; new commit signed with the configured identity | N/A |
| No identity | no user config, no env | ops written; commit author `""`/`""`; `identity_missing{name:true,email:true}` on every mutation result | N/A |
| Env override | `JJ_USER`/`JJ_EMAIL` set | override the file values (EnvOverrides > Workspace > Repo > User) | N/A |
| Repo-level override | `<config_dir>/jj/repos/<id>/config.toml` sets `user.email` | commits in THIS repo use it; other repos unaffected | N/A |
| Workspace-level override | `.jj/workspace-config-id` → secure workspace file | same, scoped to that workspace | N/A |
| Scoped table | `[[--scope]] --when.hostnames = ["x"]` | applies iff `whoami::hostname()` == `x` (today never, hostname was `""`) | N/A |
| External `jj config set --user user.email y` while Zanshin runs | file mtime changes | next Zanshin mutation uses `y` | N/A |
| `Repo::init` / `clone` | no workspace yet | settings from the user-level stack; returned `Repo` has the repo layer | N/A |
| Secondary workspace | `.jj/repo` is a FILE | repo layer resolved through the indirection, workspace layer from the secondary's `.jj` | N/A |
| Watchman configured | `fsmonitor.backend = "watchman"` (with 9.26) | jj-lib's `TreeState` sees it — today it does not | N/A |
| Broken TOML | syntax error in a stack file | `Repo::open` refuses | `jj.config_error` (path) |
| Wrong type | `user.name = 1` | refuses | `jj.config_error` (key) |
| `JJ_CONFIG=""` (tests) | env | no user layer; EnvBase + EnvOverrides still apply | N/A |

</intent-contract>

## Code Map

Oracle: `git -C ../jj show v0.44.0:<path>` (CLI), `~/.cargo/registry/src/*/jj-lib-0.44.0/src/` (jj-lib). Ralph's overriding rule for 9.27/9.22/9.26/9.28: every on-disk, op-log and config effect of the CLI is required parity; only terminal UX is replaced.

**CLI / jj-lib evidence (read-only):**
- `cli/src/config.rs` @ v0.44.0 -- `UnresolvedConfigEnv::resolve_system` `:334-345`: `/etc/jj/config.toml` + `/etc/jj/conf.d`, ONLY when `JJ_CONFIG` is unset (`self.jj_config.is_none()`); `reload_system_config` `:428-438` (dir → `load_dir`, file → `load_file`, existing paths only); `ConfigEnv::from_environment` `:366-419` (`hostname: whoami::hostname().ok()`); resolution context `:670-677` (`hostname: self.hostname.as_deref().unwrap_or("")`); `config_from_environment` `:724-730` (order doc `:713-721`); `env_base_layer` `:736-765`; `env_overrides_layer` `:789-819`; `JJ_RANDOMNESS_SEED` also seeds the config-id RNG `:411-417`.
- `cli/src/cli_util.rs` @ v0.44.0 -- identity warning `:2387-2415` lives in `finish_transaction`; `WorkspaceCommandTransaction::finish` `:2790-2795` returns "Nothing changed." BEFORE it, so the CLI warns only when an operation is committed.
- jj-lib 0.44 -- `settings.rs:135-165` (`UserSettings::from_config`, `user.name`/`user.email` read at `:141-142`, `signature()` `:206`); `workspace.rs:410-419` (`Workspace::load` = `DefaultWorkspaceLoaderFactory.create(root)?` → `loader.load(settings, …)`), `WorkspaceLoader::repo_path` `:531` (follows the `.jj/repo` FILE of a secondary workspace), `Workspace::settings()` `:438`; `config/misc.toml:48-50` (empty identity defaults).

**Zanshin (to change):**
- `crates/zanshin-jj/src/repo.rs` -- `Repo { workspace, settings }` `:82`; `make_settings` `:1729-1746` (hardcoded identity, DELETE); `open` `:1429-1464` (`make_settings` `:1455`, `Workspace::load` `:1456`); `init` `:1479-1505` (returns un-reopened `Self`); `clone` `:1528-1546` + `clone_into` `:1553-1704` (config read `:1609-1618`, maps to `CloneFailed`); `reload_workspace` `:712-722`; the 16 `&mut self` public verbs (`describe` `:558`, `new_change` `:579`, `edit` `:600`, `abandon` `:624`, `undo` `:645`, `git_fetch` `:684`, `git_import` `:775`, `git_export` `:802`, remote add/remove/rename/set-url `:833/:883/:929/:967`, bookmark verbs `:1247/:1277/:1332`, `absorb` `:1403`, plus `restore`); `RepoError` `:22-68` (no `Config` variant today).
- `crates/zanshin-jj/src/convert.rs` -- `use crate::repo::make_settings` `:91`; creation sites `:137` (`convert_colocated`) and `:237` (`convert_import`), both followed by `Repo::open`; inline tests `:539-581` use `make_settings`.
- `crates/zanshin-jj/src/config.rs` (baseline 100.00%) -- module doc `:81-92` ("Deliberately absent layers", `hostname: ""`) becomes false; `ConfigEnv` `:240-277` + `from_env` `:254`; `user_config_paths` `:301`; `add_user_layers` `:362`; `add_secure_layer` `:380`; `load_with` `:398-435` (context `hostname: ""` `:431`); `load`/`load_for_workspace` `:443-465`; `create_repo_config_file` `:656-673` (OS-RNG seed — CLI seeds from `JJ_RANDOMNESS_SEED` when set); unit tests `:823+` build `ConfigEnv` literals.
- `crates/zanshin-jj/src/revset.rs` -- `parse_revset_with` `:193-203` reads `user_email` from `repo.settings()` (the `mine()` revset); every caller already holds a per-call config (`parse_revset` `:180-184`, `graph.rs`, `op_support.rs`).
- `crates/zanshin-jj/src/mutate.rs` (baseline 97.91%) -- `MutationResult` `:41-79`; commit-path literals `:507` describe, `:566` new_change, `:619` edit, `:735` abandon, `:895` `finish_or_no_op_at` (funnel for git import/export/remote add/remove/rename `git.rs:318/398/435/476/521`, bookmark ops `bookmark_ops.rs:203/281`), `:1032` restore, `:1171` absorb; no-op literal `:760` `no_op_result` (also used directly by `git.rs:563` set-url); `cfg`/`be` error mappers.
- `crates/zanshin-jj/src/remotes.rs:332` (git_fetch literal), `crates/zanshin-jj/src/op_log.rs:173` (undo literal).
- `crates/zanshin-jj/src/lib.rs:61` -- `pub use mutate::{…MutationResult…}` (add `IdentityMissing`); `tests/api_stability.rs` `:25`, `:162-171` sample `MutationResult`, `:400`/`:472-478` `RepoError` variants.
- `crates/zanshin-ffi/src/repo.rs` (100%) -- `map_repo_err` `:40-69` (+ unit tests `:1149-1210`); extern fns `zanshin_repo_open` `:490`, `_init` `:522`, `_clone` `:567`, `_convert` `:707` (their `# Errors` rustdoc feeds `include/zanshin_ffi.h`).
- `crates/zanshin-ffi/src/envelope.rs` (100%) -- `JJ_CONFIG_ERROR` `:141`; `build_mutation_result` `:332-351` (single builder, nested use `:387`, `git.rs:162/186`); test literals `:605`, `:635`; `crates/zanshin-ffi/src/git.rs:535` test literal.
- `schemas/envelope.fbs` -- `table MutationResult` `:684-694`. `cargo make codegen` (Makefile.toml `:310-365`) regenerates `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`, `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart`.
- `packages/zanshin_core/lib/src/ffi/mutate.dart` -- `MutationResult` `:165`, decoder `:260-279` (model built `:273`), nested absorb `:306`; `lib/src/ffi/git.dart:319` `_mutation`; tests `test/ffi/mutate_test.dart:60` (+`:85/:105/:155/:206`), `test/ffi/git_test.dart:57/:162`.
- `docs/rust-error-codes.md` -- `jj.config_error` row `:56`; clone-config row `:44` ("clone config faults go out as `jj.jj_lib_error`"); `docs/ffi-abi.md` -- symbol index repo rows `:316-319` (Error-codes = 5th cell, must equal the header's `# Errors` codes — `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs:273`), MutationResult rows `:338-353`, config-layer paragraph `:947-959` ("Not layered: … EnvBase / EnvOverrides", `hostname: ""`).
- `Makefile.toml` -- `test-flutter` env `:109`, `test-core` env `:132`, coverage script inline env `:520` (all pin `JJ_CONFIG=""`, `GIT_CONFIG_GLOBAL=""` for the cdylib).
- `Cargo.toml` `[workspace.dependencies]` `:28`; `crates/zanshin-jj/Cargo.toml` deps; `deny.toml` (advisories + bans only; `whoami` not yet in `Cargo.lock`; jj uses `whoami = "2.1.2"`).
- Tests: `ENV_GUARD` (`JJ_CONFIG=""`, `GIT_CONFIG_GLOBAL=""`) in every `crates/zanshin-jj/tests/*.rs` except `api_stability`/`detect`/`find_repo_root` (verbatim shape `tests/mutate.rs:17-24`), `convert_alias_write_failure.rs:46-48`, `op_workspace_name.rs:53` (+`XDG_CONFIG_HOME`), inline `src/op_support.rs:719`, `benches/graph_blueprint.rs`, `benches/show_limit.rs`, every `crates/zanshin-ffi/tests/*_ffi.rs` + `watcher.rs` (e.g. `repo_write_ffi.rs:41-52`), inline `crates/zanshin-ffi/src/repo.rs:1320`, `crates/zanshin-graph/tests/{slice,stream}.rs`. `make_test_settings()` stubs (identical Zanshin literal, `tests/mutate.rs:26-43`) in ~20 zanshin-jj test files, `crates/test-helpers/src/lib.rs:68-85` (used by its `load()` `:119`), inline `src/file.rs:730-746`, `benches/graph_blueprint.rs:95-103`. `crates/test-helpers/` is an `exclude_prefix` in the baseline. Patterns to reuse: single-`#[test]` `JJ_CONFIG` binary `tests/config_user_layer.rs:27-55`; op-metadata read-back from the store `tests/op_workspace_name.rs:93-135`, `tests/op_log.rs:226-247`.
- Out of scope, untouched: `crates/xtask/src/tasks/gen_fixture.rs:114-130` (fixture generator's deterministic `Fixture` identity — a dev tool, never a Zanshin runtime path, excluded from coverage).

## Tasks & Acceptance

**Execution:**
- [x] `Cargo.toml`, `crates/zanshin-jj/Cargo.toml` -- add `whoami = "2.1.2"` (workspace dep, the CLI's pin) as a normal dependency of zanshin-jj; `deny.toml` unchanged unless `cargo deny` requires a documented entry -- the CLI's own hostname/username source.
- [x] `crates/zanshin-jj/src/config.rs` -- extend `ConfigEnv` with the snapshot inputs `system_config_dir: Option<PathBuf>` (`/etc`), `hostname: Option<String>` (`whoami::hostname().ok()`), `username: Option<String>` (`whoami::username().ok()`, `$USER` fallback) — `from_env` stays branch-free expressions; add pure builders `env_base_layer(&ConfigEnv)` / `env_overrides_layer(&ConfigEnv)` reading ONLY `env.environment` (keys/values exactly the CLI's `:736-819`, incl. `NO_COLOR`→`ui.color="never"` only when non-empty, `VISUAL` over `EDITOR`, `JJ_RANDOMNESS_SEED` as i64, no `$PAGER`); `add_system_layers` (CLI paths, only when `jj_config.is_none()`, dir→`load_dir`); rebuild `load_with` as Default(jj-lib)+Zanshin builtin → System → EnvBase → User → [Repo → Workspace] → EnvOverrides with `hostname: env.hostname.as_deref().unwrap_or("")` in the resolution context, the repo/workspace part optional (creation paths pass none and resolve with `repo_path`/`workspace_path` `None`); add `pub(crate) fn user_settings_for(loader: &dyn WorkspaceLoader) -> Result<UserSettings, ConfigError>` and `pub(crate) fn user_settings_for_new_workspace() -> Result<UserSettings, ConfigError>` (wrong-typed `user.*`/`operation.*` → `ConfigError::Load` naming the key); add `pub(crate) fn stack_fingerprint(repo_path, workspace_root) -> Result<StackFingerprint, ConfigError>` (`PartialEq`, see Design Notes); seed `create_repo_config_file`'s RNG from `JJ_RANDOMNESS_SEED` (u64, via `ConfigEnv`) when set, else OS RNG, as the CLI does; rewrite the module doc's "Deliberately absent layers" paragraph; unit-test every new branch with synthetic `ConfigEnv` values (file must stay at 100%) -- one stack for reads and for opening.
- [x] `crates/zanshin-jj/src/repo.rs` -- delete `make_settings`; add `RepoError::Config { reason }` (from `ConfigError`); `open` = canonicalize → `DefaultWorkspaceLoaderFactory.create(&root)` → fingerprint → `config::user_settings_for(&*loader)` → `loader.load(&settings, &default_backend_factories(), &default_working_copy_factories())`; `init`/`clone` build settings with `user_settings_for_new_workspace()` (fault → `RepoError::Config` BEFORE any disk write), then return `Repo::open(&root)` (full stack); `clone_into`'s own config read maps to `RepoError::Config` too (rollback of `.jj/` unchanged); add field `stack_fingerprint` and `pub(crate) fn refresh_settings(&mut self) -> Result<(), crate::MutateError>` (recompute fingerprint; if changed: new settings via `user_settings_for`, reload `workspace` + `settings`, store the fingerprint; `ConfigError` → `MutateError::Config`); call it FIRST in every `&mut self` public verb; inline `#[cfg(test)]` witness that a repo-layer `snapshot.max-new-file-size`/`fsmonitor.backend` reaches `repo.workspace().settings()` -- the story; the shared pre-verb hook 9.26/9.28 reuse.
- [x] `crates/zanshin-jj/src/convert.rs` -- both production sites use `config::user_settings_for_new_workspace()` (fault → `RepoError::Config`); inline tests switch off `make_settings` -- creation paths.
- [x] `crates/zanshin-jj/src/revset.rs` (+ its callers in `graph.rs`, `op_support.rs`, `commit_views.rs`) -- `mine()`'s `user_email` comes from the per-call effective config (`user.email`, `ConfigError` on wrong type) instead of `repo.settings()` -- reads see an external `jj config set` without becoming `&mut self`.
- [x] `crates/zanshin-jj/src/mutate.rs`, `remotes.rs`, `op_log.rs`, `lib.rs` -- `pub struct IdentityMissing { pub name: bool, pub email: bool }` (Debug, Clone, Copy, PartialEq, Eq), `MutationResult.identity_missing: Option<IdentityMissing>`, helper `identity_missing(&UserSettings)` = `None` when both are non-empty; `Some` only on paths that COMMITTED an operation (settings = the ones the transaction was started with), `None` from `no_op_result`; re-export; update `tests/api_stability.rs` -- the CLI's post-transaction warning as a fact.
- [x] `schemas/envelope.fbs` -- `table IdentityMissing { name: bool; email: bool; }` + `identity_missing: IdentityMissing;` APPENDED to `MutationResult` with a doc comment; `cargo make codegen`; `crates/zanshin-ffi/src/envelope.rs` `build_mutation_result` writes it iff `Some` (unit tests for both); `crates/zanshin-ffi/src/repo.rs` `map_repo_err`: `RepoError::Config` → `jj.config_error` with `reason` in context (+ unit test), `# Errors` rustdoc of `zanshin_repo_open/_init/_clone/_convert` lists `jj.config_error`; fix the test-only `MutationResult` literals -- wire contract.
- [x] `packages/zanshin_core/lib/src/ffi/mutate.dart`, `git.dart` (+ barrel export if `MutationResult` is exported) -- `final class IdentityMissing { name, email }`, `MutationResult.identityMissing` nullable (null = absent), decoded at every `MutationResult` construction site; tests in `test/ffi/mutate_test.dart` (present + absent) -- bridge.
- [x] `crates/zanshin-jj/tests/*.rs`, `benches/*.rs`, inline test modules that open/create workspaces (`src/op_support.rs`, `src/file.rs`, `src/convert.rs`, `src/repo.rs`), `crates/zanshin-ffi/tests/*.rs` + `src/repo.rs` inline, `crates/zanshin-graph/tests/{slice,stream}.rs` -- every env guard additionally pins `JJ_USER="Zanshin"`, `JJ_EMAIL="zanshin@localhost"`, `JJ_OP_HOSTNAME="localhost"`, `JJ_OP_USERNAME="zanshin"` (inline modules share one `#[cfg(test)]` pin helper so the lib test binary never reads the developer's real config); replace every `make_test_settings()` stub and `test_helpers`' private copy with one `pub fn test_settings()` in `crates/test-helpers/src/lib.rs` that layers the four pinned `JJ_*` values (when set) over `StackedConfig::with_defaults()`; fix `tests/repo.rs:11`'s stale `make_settings` comment -- machine-independent gate.
- [x] `crates/zanshin-jj/tests/config_identity.rs` (NEW, one `#[test]`, own env guard: `JJ_CONFIG` → temp file, `XDG_CONFIG_HOME` → temp dir, `GIT_CONFIG_GLOBAL=""`, the four identity `JJ_*` vars REMOVED) -- witnesses walking the I/O matrix: user-file identity on commit author + op `username`/`hostname` == `whoami` values (read from the store); same-handle rewrite of the file (size changes) and repointed `JJ_CONFIG` are picked up by the next mutation; empty identity → author `""`/`""` + `identity_missing` both true, a no-op call → `None`; `JJ_USER`/`JJ_EMAIL` beat the file; repo-level legacy `.jj/repo/config.toml` override in repo A only; secondary workspace's `.jj/workspace-config.toml` wins in that workspace only; `[[--scope]] --when.hostnames = [<whoami hostname>]` applies; broken TOML → `Repo::open` `RepoError::Config` naming the path; `user.name = 1` → names the key; a stack broken after open → next mutation `MutateError::Config` -- the ACs.
- [x] `crates/zanshin-ffi/tests/repo_config_ffi.rs` (NEW, one `#[test]`, identity vars removed) -- broken `JJ_CONFIG` → `zanshin_repo_open` envelope error `jj.config_error` with the path in context; valid identity-less config → a mutation extern's envelope carries `identity_missing` {name: true, email: true} -- outermost surface.
- [x] `Makefile.toml` -- add the four `JJ_*` identity pins next to `JJ_CONFIG=""` in `test-flutter`, `test-core` and the coverage script's inline env -- Dart/cdylib runs stay deterministic.
- [x] `docs/rust-error-codes.md` (`:56` new emitters `zanshin_repo_open/_init/_clone/_convert`, `:44` clone config faults now `jj.config_error`), `docs/ffi-abi.md` (repo rows `:316-319` add `jj.config_error`; `identity_missing` note next to the MutationResult rows; rewrite `:954-959` for the new layers and hostname) -- `ffi_abi_doc_sync` enforces the index.
- [x] `_bmad-output/implementation-artifacts/sprint-status.yaml` (row `9-27-…` → `done` + summary comment, bump `last_updated`), `deferred-work.md` (dated section for any deferral) -- bookkeeping.
- [x] `coverage-baseline.txt` -- commit the auto-raised baseline; never lower, no `exclude_prefix` -- ratchet.

**Acceptance Criteria:**
- Given a user config file with `user.name`/`user.email` and no `JJ_USER`/`JJ_EMAIL`/`JJ_OP_*` in the environment, when Zanshin writes a mutation, then the new commit's author equals the configured identity and the operation's `username`/`hostname` equal `whoami::username()`/`whoami::hostname()` — exactly what the CLI writes on the same machine.
- Given an already-open `Repo` handle, when the user config file is rewritten (or `JJ_CONFIG` repointed) between two mutations, then the second mutation carries the new identity without re-opening.
- Given no identity anywhere in the stack, when a mutation commits an operation through `zanshin_*`, then the commit carries the empty identity and the decoded `MutationResult` has `identity_missing` {name: true, email: true}; when a call commits nothing, then `identity_missing` is absent.
- Given a syntax error (or a wrong-typed `user.name`) in any stack file, when `zanshin_repo_open`/`_init`/`_clone`/`_convert` runs, then it refuses with `jj.config_error` naming the path (or key) and writes nothing; when the stack breaks after open, the next mutation refuses with `jj.config_error`.
- Given the finished change, when the production sources are searched, then `make_settings` is gone and no production path under `crates/zanshin-jj/src` or `crates/zanshin-ffi/src` contains a hardcoded identity.
- Given the finished change, when `cargo make test` runs, then it is green, including `cargo deny` with `whoami` in the tree, `ffi_abi_doc_sync`, and the coverage ratchet with `config.rs`, `envelope.rs`, `zanshin-ffi/src/repo.rs`, `convert.rs` still at 100% and `repo.rs`/`mutate.rs` not below baseline.

## Spec Change Log

## Review Triage Log

### 2026-09-23 — Review pass
- verdicts: 37 findings — high 0, medium 7, low 24, false 6, maybe-false 0
- findings:
  - `[false]` `[reject]` BH: spec status/checkboxes lag sprint-status and the spec edit is absent from the reviewed diff — the spec is the claims file and is deliberately excluded from the diff; it is finalized (status done, tasks ticked) in this step before commit.
  - `[medium]` `[defer]` BH: identity_missing is reported after a no-change git_fetch where the CLI shows no warning — verified: CLI fetch/describe end in tx.finish, which returns "Nothing changed." before finish_transaction; Zanshin's git_fetch/describe commit unconditionally (pre-existing op-log divergence). identity_missing correctly follows the op Zanshin writes; the unconditional commit is deferred (frontmatter + deferred-work.md).
  - `[low]` `[patch]` BH: Repo::init's native (init_simple) arm skips creation_error, so a wrong-typed working-copy key is jj.jj_lib_error there but jj.config_error on git init/convert — patched: the None arm now maps through creation_error.
  - `[low]` `[patch]` BH: a failed re-open after a successful clone/init is not rolled back — clone part patched: clone_into(..).and_then(Self::open) now sits inside the .jj/ rollback, matching its rustdoc; the init part is recorded under the ECH row below.
  - `[low]` `[reject]` BH: reload_workspace is a second load path with pre-write settings and a stale fingerprint — its settings cannot newly fail (unchanged settings), and the stale fingerprint only costs one extra ~1 ms reload on the next verb, which then re-derives correctly; negligible, and rerouting changes reload_after_config_write's error contract.
  - `[medium]` `[defer]` BH: a Finder/Dock-launched app gets launchd's environment, not the shell profile's JJ_CONFIG/XDG_CONFIG_HOME/JJ_USER — real, but pre-existing (the stack already read JJ_CONFIG/XDG_CONFIG_HOME since 4.9) and an app-launch product decision; deferred.
  - `[low]` `[reject]` BH: ~45 ENV_GUARD blocks hand-copy the identity pins instead of looping over test_helpers::TEST_ENV — values are fixed constants unlikely to change; the fix is churn across 45 files.
  - `[low]` `[patch]` BH: test_settings() reads the env (order-dependent) and two comments went stale (tests/status.rs, benches/graph_blueprint.rs) — every caller pins first (suite green); comments patched.
  - `[low]` `[reject]` BH: no FFI-level witness for clone/convert returning jj.config_error — all four externs share map_repo_err (unit-tested for RepoError::Config); clone/convert faults are witnessed at the Rust level (clone_config.rs, config_identity.rs), open/init at the FFI level (repo_config_ffi.rs).
  - `[low]` `[patch]` BH: Dart nested identityMissing decodes (git import/export, absorb) untested — patched: git_test.dart and mutate_test.dart assert the nested value (incl. name:false,email:true) and null when absent.
  - `[false]` `[reject]` BH: IdentityMissing{false,false} is representable — the two-bool shape is mandated verbatim by the intent contract; the absent table encodes "configured".
  - `[low]` `[reject]` BH: ConfigEnv::from_env (env clone + two whoami calls) runs several times per verb — microseconds per call; sharing one snapshot needs plumbing through every reader.
  - `[low]` `[patch]` ECH: Repo::init(None) maps init_simple errors to InitFailed — same root cause as the BH init_simple row; patched there.
  - `[low]` `[patch]` ECH: Repo::clone re-open failure leaves .jj/ — same group as the BH rollback row; patched.
  - `[low]` `[reject]` ECH: Repo::init re-open failure leaves a created repo — only reachable if the stack changes between creation and re-open (no repo/workspace layer exists yet, the user-level stack already passed creation); init never rolled back before, and a rollback adds a new branch.
  - `[low]` `[reject]` ECH: a same-length rewrite within mtime granularity leaves the fingerprint unchanged — APFS (macOS-only project) stamps nanosecond mtimes and editors write new files; practically unreachable.
  - `[low]` `[patch]` ECH: a non-UTF-8 JJ_CONFIG counts as set here but unset in the CLI — patched: jj_config = std::env::var("JJ_CONFIG").ok().map(OsString::from), as cli/src/config.rs:386.
  - `[false]` `[reject]` ECH: JJ_RANDOMNESS_SEED gives two repos created in one process the same config-id — the CLI seeds per invocation from the same variable, so two `jj git init` runs with the same seed produce the same id too; identical behaviour.
  - `[medium]` `[defer]` ECH: git_fetch/describe report identity_missing after a no-change call where the CLI stays silent — same root cause as the BH git_fetch row (pre-existing unconditional commit); deferred.
  - `[low]` `[patch]` ECH: the final reload moved outside the clone rollback — same group as the BH rollback row; patched.
  - `[medium]` `[patch]` VG: refresh_settings is witnessed only through new_change; 15 of 16 call sites unpinned — patched: config_identity.rs `every_mutating_verb_refreshes_first` breaks JJ_CONFIG under an open handle and asserts all 16 &mut verbs return MutateError::Config naming the file with the op head unchanged.
  - `[medium]` `[patch]` VG: identity_missing on finish_or_no_op_at's committed path (and describe/abandon) never asserted — patched: the empty-identity phase also runs a committing bookmark_create and describe, asserting Some{name:true,email:true}.
  - `[low]` `[patch]` VG: nested identityMissing Dart decode untested — same group as the BH Dart row; patched.
  - `[medium]` `[patch]` VG: mine() now reads user.email per call but no test evaluates mine() — patched: `mine_follows_the_stack` repoints user.email without a mutation and asserts mine() follows.
  - `[low]` `[patch]` VG: Repo::init(None) skips creation_error — same group as the BH init_simple row; patched.
  - `[low]` `[defer]` IA: re-derive runs before mutations only, while the intent says "at every verb start" — reads re-resolve every by-name key per call; only jj-lib-internal settings (e.g. merge.*) stay at the last derive, which before 9.27 were never user settings at all; Story 9.26 turns every verb into a precondition site (receiver rule). Deferred with that handoff.
  - `[false]` `[reject]` IA: the fingerprint includes the whole environment — no bad outcome: in-process env changes are rare and cost one ~1 ms reload; the env feeds both env layers and --when.environments scopes, so narrowing it could miss a change.
  - `[false]` `[reject]` IA: wrong-typed git.*/working-copy keys now fail Repo::open — CLI parity (the CLI loads the workspace, and jj-lib reads those keys, at start-up); the product consequence for 9.28 is recorded as a deferral.
  - `[low]` `[defer]` IA: init with a wrong-typed git key leaves .jj/ behind — pre-existing (init never rolled back); deferred to Story 9.20.
  - `[medium]` `[patch]` IA: only new_change is witnessed as a writer for author/identity_missing — same groups as the VG refresh and identity_missing rows; patched.
  - `[low]` `[patch]` IA: repo/workspace override rows witnessed only through legacy files, not the secure config-id paths — patched: `secure_config_ids_select_the_repo_and_workspace_layers` writes .jj/repo/config-id and .jj/workspace-config-id and reads the author back; other repo unaffected.
  - `[low]` `[patch]` IA: JJ_OP_HOSTNAME/JJ_OP_USERNAME overriding whoami asserted only at the layer level — patched: `op_metadata_overrides_reach_the_store` sets them after open and reads the next operation's metadata from the store.
  - `[low]` `[reject]` IA: the init witness cannot distinguish re-open from refresh — both produce the CLI-correct outcome (the repo layer applies to the next commit); the re-open is explicit in code.
  - `[low]` `[reject]` IA: a same-length edit within mtime resolution is not exercised — same as the ECH mtime row; practically unreachable on APFS.
  - `[false]` `[reject]` IA: the Watchman row is asserted at settings level, not TreeState — the intent row is explicitly "(with 9.26)"; 9.27's part is that the setting reaches the workspace's settings, which is witnessed (repo.rs inline test) including after a refresh.
  - `[low]` `[reject]` IA: clone/convert jj.config_error, the wrong-type row and the mutation-wrapper emitters not exercised at the FFI surface — same as the BH FFI row: one shared mapper per error type, unit-tested, with Rust-level witnesses.
  - `[low]` `[patch]` IA: Dart nested decodes untested — same group as the BH Dart row; patched.

### 2026-09-23 — Review pass (follow-up; diff = a3d4d91 + fc362ce only, every finding verified against HEAD after 9.22/9.26/9.28)
- verdicts: 35 findings — high 1, medium 3, low 22, false 9, maybe-false 0
- findings:
  - `[medium]` `[defer]` BH: clone/init/convert never report identity_missing although the CLI warns after clone's fetch tx.finish and git init's head-import tx.finish — verified (clone.rs:457/:314/:352, init.rs:268 @ v0.44.0); the fix needs new surface on the handle-producing results or a UI-side config_get, a product decision → deferred (frontmatter + deferred-work.md "Surfaced 2026-09-23 — Story 9.27 follow-up review").
  - `[low]` `[reject]` BH: reload_workspace bypasses load_effective (pre-write settings, stale fingerprint, Backend mapping) — carried: same claim as the first pass's reload_workspace row and the code still reads so (repo.rs:890-900); its settings are unchanged from the last successful load, so no new config fault can surface there.
  - `[false]` `[reject]` BH: nothing enforces refresh-first, a new verb may forget it — at HEAD every verb enters through Repo::precondition, which runs refresh_settings first (repo.rs:226-229, Story 9.26 fadbbfc), and config_identity.rs's 16-verb phase matches MutateError::Precondition(Config), so a verb bypassing the gate fails it.
  - `[low]` `[reject]` BH: load_effective takes two ConfigEnv snapshots — carried (first pass's from_env-per-verb row); the consistency part is not a defect: the fingerprint is taken first, so a change between the snapshots costs one redundant reload, never a missed one.
  - `[low]` `[reject]` BH: reordered tests now fail inside the pre-verb refresh, so the verbs' own git.*/guard config reads are untested — at HEAD the verbs read ctx.config loaded by precondition (git.rs:327, remotes.rs:260); their map_err arms are defensive (jj-lib reads git.* while loading, before them) and unreachable in practice; adding fault-only-the-verb-reads fixtures is more than a direct correction.
  - `[low]` `[reject]` BH: the four identity pins are hand-copied into ~40 ENV_GUARDs — carried (first pass's ENV_GUARD row).
  - `[low]` `[patch]` BH: TEST_ENV's doc claims "exactly what jj's own test harness does" while jj also pins JJ_TIMESTAMP/JJ_OP_TIMESTAMP/JJ_RANDOMNESS_SEED/JJ_TZ_OFFSET_MINS — patched: crates/test-helpers/src/lib.rs doc now says it is the identity half and names what is left to the environment.
  - `[low]` `[reject]` BH: the fingerprint compares only mtime+len — carried (first pass's mtime-granularity rows).
  - `[low]` `[patch]` BH: clone/convert config_error untested at FFI, clone pre-write refusal untested, convert_import config fault + rollback untested — FFI part carried (shared map_repo_err, unit-tested); clone pre-write shares init's witnessed first line; convert_import part patched with VG3's row (config_identity.rs creation_paths).
  - `[low]` `[patch]` BH: config_identity.rs phases depend on leftover global state (init's broken-stack refusal worked only because JJ_CONFIG still pointed at wrong-type.toml) — patched: creation_paths now sets its own wrong-typed file and asserts the key; the identity phases are documented as one sequential walk (single-test-binary rule).
  - `[low]` `[patch]` BH: hand-offs to other stories live only in deferred-work.md — at HEAD 9.26 and 9.28 already resolved theirs (deferred-work.md stamps); patched: the init .jj/ rollback hand-off is mirrored into sprint-status.yaml's 9-20 row. describe's no-change op stays in the carried medium deferral.
  - `[low]` `[patch]` BH: Repo::init's # Errors doc has a verb-less sentence — patched ("Returns [`RepoError::Config`] …").
  - `[low]` `[patch]` ECH: convert_colocated/convert_import re-open outside the rollback; a repo-scoped fault invisible to creation leaves .jj/ — grouped with the ECH creation-scope row (same root cause: creation resolved with no repo/workspace path); the root-cause patch makes creation see the same scopes, so the fault now refuses before any write; the residual trigger (stack edited between creation and re-open) is a race.
  - `[low]` `[patch]` ECH: Repo::init re-open failure leaves a fresh .jj/ on a --when.repositories-scoped fault — not carried (the first pass's init row assumed only a stack change could trigger it); same group and patch as above.
  - `[low]` `[reject]` ECH: an unknown signing.backend (SignInitError::UnknownBackend) maps to jj.jj_lib_error, not jj.config_error — real but both refuse with jj-lib's message naming the backend; typo-only, and the fix adds a match arm plus a test to keep config.rs at 100%.
  - `[low]` `[reject]` ECH: fingerprint misses a same-length edit within one mtime tick — carried.
  - `[high]` `[patch]` ECH: creation settings resolve with repo_path/workspace_path None, while the CLI's settings_for_new_workspace (cli_util.rs:372-388 @ v0.44.0, used by git init :236 and git clone :332) resolves for <root>/.jj/repo and <root> — verified: a --when.repositories per-directory identity (the documented work/personal pattern) is ignored for init's @ commit, the clone's @ commit and a conversion's snapshot commits; jj-lib keeps the author email when @ is later rewritten (commit_builder.rs:237-255), so the user's first real commit is pushed with the wrong email — a CLI-vs-Zanshin difference on disk. Patched (adaptation 3, local): config::user_settings_for_new_workspace(workspace_root) resolves with the new workspace's paths (secure layers find no file yet, as the CLI's reload); init/clone/convert_colocated derive it after canonicalizing their root, convert_import after creating + canonicalizing the destination (the CLI's order; a fault there rolls the created dir back); docs (repo.rs, convert.rs, ffi-abi.md, rust-error-codes.md) updated; witness config_identity.rs creation_paths: a --when.repositories-scoped email signs init's and convert_colocated's @ commit (mutation-checked: fails with the old None resolution).
  - `[medium]` `[defer]` ECH: clone/convert return no identity_missing fact where the CLI warns — same group as the BH identity row; deferred.
  - `[false]` `[reject]` VG: every_mutating_verb_refreshes_first cannot tell a missing refresh from 7 verbs' own config reads — at HEAD (fadbbfc) the refresh lives once in Repo::precondition, which identity_follows_the_user_stack witnesses (a dropped refresh keeps the old author), and a verb bypassing precondition returns MutateError::Config instead of the asserted MutateError::Precondition(Config).
  - `[false]` `[reject]` VG: identity_missing unasserted for edit/abandon/restore/absorb/undo/git_fetch literals — at HEAD (fadbbfc) there are no per-verb literals: every committed result goes through mutate.rs::mutation_result (identity_missing(finish.repo.settings()), mutate.rs:698), witnessed via new_change, bookmark_create and describe.
  - `[low]` `[patch]` VG: convert_import's creation_error → RepoError::Config mapping is untested — patched: creation_paths asserts convert_import with a wrong-typed git.abandon-unreachable-commits refuses as Config naming the key and removes the destination it created.
  - `[low]` `[reject]` VG: the non-UTF-8 JJ_CONFIG read has no test — a non-UTF-8 JJ_CONFIG is practically never set, and a safe test needs from_env split into an injectable constructor (a refactor, not a direct correction).
  - `[low]` `[reject]` VG (other): fingerprint mtime+len — carried.
  - `[false]` `[reject]` IA: the oracle is a jj-lib store read, not the jj binary, and an external `jj config set` is simulated by fs::write — the store is exactly what jj log / jj op log read, and jj config set writes the same file the fingerprint stats; no bad outcome.
  - `[low]` `[reject]` IA: Dart identityMissing is only decoded from hand-built buffers, no worker round-trip — the Rust envelope side is witnessed end-to-end (repo_config_ffi.rs) on the same schema the Dart decoder is tested against; a round-trip adds no new failure mode worth the harness.
  - `[medium]` `[defer]` IA: git_fetch/describe report identity_missing after a no-change call — carried (first pass's deferral; mutate.rs:575 still commits without has_changes).
  - `[false]` `[reject]` IA: read verbs do not refresh (A2 reading) — at HEAD every read verb runs Repo::precondition → refresh_settings (repo.rs:290-408, fadbbfc); the first pass's deferral is stamped resolved in deferred-work.md.
  - `[false]` `[reject]` IA: Watchman asserted at settings level, not TreeState — carried.
  - `[low]` `[reject]` IA: wrong-typed load-time keys now refuse the open and reordered tests only reach the refresh — same group as the BH reordered-tests row; the open refusal is CLI parity and 9.28 (fe54820) made the config verbs handle-less.
  - `[low]` `[reject]` IA: scoped-table non-match covered only with no hostname, not a different one — the matcher is jj-lib's own (config_resolver.rs matches_hostname); Zanshin only supplies whoami::hostname(), witnessed by the matching case.
  - `[low]` `[reject]` IA: "re-opened with the full stack" witnessed for init only — clone and both converts end in the same explicit Repo::open call; a per-verb witness adds nothing a reviewer cannot read.
  - `[low]` `[defer]` IA: init leaves .jj/ on a git-backend config fault — carried (first pass's 9.20 deferral; now also mirrored into sprint-status 9-20).
  - `[false]` `[reject]` IA: changes beyond the intent's surface (JJ_RANDOMNESS_SEED seeds config-id, no system layer with JJ_CONFIG set, var vs var_os, clone fault code, required Dart ctor param) — each is CLI parity (config.rs:411-417, resolve_system, cli/src/config.rs:386) or intent-mandated (clone is a named emitter); nothing in app/ constructs MutationResult.
  - `[false]` `[reject]` IA: test_settings() is not a full stack — it only signs the test oracle's own loads, with the same EnvOverrides values Zanshin reads; no test compares against a full-stack value through it.
  - `[false]` `[reject]` IA: Makefile pins reach flutter/dart/coverage runs beyond the intent's surface — the intent requires machine-independent gates, and those runs load the cdylib through the same stack.

## Design Notes

**Ask-First decisions (Ralph, 2026-09-23)** — resolved, not intent gaps:
1. Reload policy: fingerprint-triggered (paths + mtime/size of every file in the stack). An unconditional per-verb re-derive would only be acceptable if measured under 1 ms on `large-10k`; not taken.
2. Builder location: `config::user_settings_for(loader)` + `config::user_settings_for_new_workspace()` replace `repo.rs::make_settings`.
3. Cosmetic EnvBase/EnvOverrides keys (`ui.color`, `ui.editor`, `ui.pager`): added, for layer parity (Story 9.28's `config list` shows them).
4. Receiver rule (applies to 9.27 and 9.26): state-changing preconditions live INSIDE `zanshin-jj`; a read verb that needs one becomes `&mut self`. Never an FFI-side precondition — MCP (Epic 7) inherits parity automatically.

**Readings fixed by the CLI oracle (not gaps):**
- `identity_missing` "on every mutation result" is read through "exactly where the CLI warns": the warning sits in `finish_transaction`, which `finish` skips when nothing changed (`cli_util.rs:2790-2795`). So: `Some` iff this call committed an operation AND name and/or email is empty; `None` on a no-op result. Verbs that commit unconditionally in Zanshin (e.g. `git_fetch`) therefore report it every time.
- No read verb becomes `&mut self` in this story: the only read-side consumer of `UserSettings` is `mine()`'s `user_email`, and every read already re-resolves the effective config per call — taking `user.email` from that config gives CLI per-invocation semantics with no state change. 9.26 decides its own receivers.
- `refresh_settings` is the ONE pre-verb hook: 9.26 runs its snapshot after it, 9.28 calls it (or it simply fires on the next verb, since a config write changes the fingerprint).

**Fingerprint.** Compute it BEFORE deriving settings (a change in between costs a redundant reload, never a missed one). It must cover: every System and User candidate path (for a directory: each `*.toml` entry) as `(path, exists, mtime, len)`; `.jj/repo/config-id` and `.jj/workspace-config-id` (same tuple) and the secure config file each resolves to (legacy fallback included); and the EnvBase/EnvOverrides inputs (the relevant env values plus `hostname`/`username`) plus `JJ_CONFIG`/`HOME`/`XDG_CONFIG_HOME`, so env-driven changes also re-derive. Cheap: a handful of `stat`s per verb.

**Open split** (`Workspace::load` in two halves, `workspace.rs:410-419`): `let loader = DefaultWorkspaceLoaderFactory.create(&root)?; let settings = config::user_settings_for(&*loader)?; let workspace = loader.load(&settings, &default_backend_factories(), &default_working_copy_factories())?;` — `loader.repo_path()` gives the secondary workspace's real repo dir for the repo layer.

**Error mapping.** `RepoError::Config` → `jj.config_error` (existing code, new emitters). Clone: both the settings-stage and the existing in-clone config read now use it (previously `CloneFailed`/`jj.jj_lib_error`), so a clone config fault has one code; `.jj/` rollback unchanged.

**Coverage.** `config.rs`/`envelope.rs`/ffi `repo.rs`/`convert.rs` are at 100%: keep new logic in pure functions over `ConfigEnv` (unit-testable with synthetic snapshots), keep `from_env` to branch-free expressions, no dead error arms.

**Landing order:** 9.27 (this) → 9.22 → 9.26; 9.28 any time after 9.27.

## Verification

**Commands:**
- `cargo make codegen` then `git status` -- expected: the four generated files updated and committed with the schema change.
- `cargo make test` (foreground; if it cannot finish in one call, run each `[tasks.test]` dependency with `cargo make --allow-private <task>`, ending with `coverage`) -- expected: green, `cargo deny` green with `whoami`, coverage ≥ baseline.

**Manual checks (if no CLI):**
- On a scratch repo with a real `~/.config/jj/config.toml`: a Zanshin `describe`, then `jj log -r @ -T 'author ++ "\n"'` and `jj op log --limit 1` show the same identity and machine a CLI-written change shows.

## Auto Run Result

Status: done
Blocking condition: none

**Summary.** `Repo::open` now splits `Workspace::load` (loader → stack fingerprint → `config::user_settings_for(loader)` → `loader.load`); `init`/`clone`/both converts create with `config::user_settings_for_new_workspace()` and return a re-opened handle; `config::load_with` builds the CLI's Default(+builtin) → System (`/etc/jj`, only without `JJ_CONFIG`) → EnvBase (`whoami` host/user with `$USER` fallback, `NO_COLOR`, `VISUAL`/`EDITOR`) → User → Repo → Workspace → EnvOverrides (all nine `JJ_*`) stack with `whoami::hostname()` in the resolution context; `Repo::refresh_settings` (fingerprint of stack files mtime+len, id files, env, whoami) runs first in all 16 `&mut self` verbs; `mine()` reads `user.email` per call; `RepoError::Config` → `jj.config_error` for open/init/clone/convert (and every mutation wrapper via the refresh), including wrong-typed keys jj-lib reads while loading/creating; `MutationResult.identity_missing` (Rust/fbs/Dart) set iff an operation was committed with an empty name/email; `make_settings` deleted; `JJ_RANDOMNESS_SEED` seeds the config-id RNG as in the CLI.

**Files changed (grouped).**
- `Cargo.toml`, `Cargo.lock`, `crates/zanshin-jj/Cargo.toml` — `whoami = "2.1.2"` (resolved 2.1.3).
- `crates/zanshin-jj/src/config.rs` — System/EnvBase/EnvOverrides layers, settings builders, config-fault extraction, stack fingerprint, seeded RNG, module doc.
- `crates/zanshin-jj/src/repo.rs` — `RepoError::Config`, `load_effective`, `refresh_settings`, open/init/clone rewiring, refresh in every `&mut` verb, inline witnesses.
- `crates/zanshin-jj/src/{convert,revset,graph,op_support,mutate,op_log,remotes,lib,file}.rs` — creation settings, per-call `user.email`, `IdentityMissing`, shared test pin.
- `schemas/envelope.fbs` + generated `envelope_generated.rs`, `zanshin_ffi.h`, `envelope_zanshin.ffi_generated.dart`, `bindings.dart` — `IdentityMissing` table.
- `crates/zanshin-ffi/src/{repo,envelope,git,bookmark_ops}.rs` — `RepoError::Config` mapping, builder, `# Errors` docs.
- `packages/zanshin_core/lib/src/ffi/{mutate,git}.dart` + tests — `IdentityMissing` model and decoders.
- `crates/test-helpers/src/lib.rs` — `TEST_ENV`, `pin_test_env`, `test_settings` (replace ~20 stubs).
- `crates/zanshin-jj/tests/*.rs`, `crates/zanshin-ffi/tests/*.rs`, `crates/zanshin-graph/tests/*.rs`, `benches/*.rs`, `Makefile.toml` — identity pins; new witnesses `tests/config_identity.rs`, `crates/zanshin-ffi/tests/repo_config_ffi.rs`.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md`, `crates/zanshin-jj/README.md` — new emitters, layers, `identity_missing`.
- `coverage-baseline.txt` — `repo.rs` 96.46 → 97.08 (auto-raised).
- `_bmad-output/implementation-artifacts/{sprint-status.yaml,deferred-work.md}` — 9-27 done, deferrals.

**Review findings.** 37 findings (high 0, medium 7, low 24, false 6). Patched: native `init` config-fault mapping, clone re-open inside the `.jj/` rollback, CLI-style `JJ_CONFIG` read, two stale comments, and witnesses for all 16 refresh call sites, `JJ_OP_*` in the store, `identity_missing` on `finish_or_no_op_at`/describe, `mine()`, secure config-id paths, nested Dart decodes. Deferred (7, frontmatter + deferred-work.md): read verbs refresh in 9.26; open refuses wrong-typed load keys (9.28 must work without a handle); init `.jj/` rollback (9.20); no-change fetch/describe still commit an op (pre-existing); launchd GUI environment; 3 pre-existing app splash tests; `pubspec.lock` drift. Rejected: every `false` and `low` row in the Review Triage Log with its reason.

**Follow-up review recommended: true.** Patched by verdict: medium 3 entries (refresh call-site witnesses, `identity_missing` shared-path witness, `mine()` witness), low 7. Unverified risk: the three medium patches are new test code in the single-binary `tests/config_identity.rs` that no reviewer has read yet (e.g. whether the 16-verb refusal phase really proves each call site, not just the first refusing guard).

**Verification.** Gate run step by step with `cargo make --allow-private <task>` after the patches: test-cargo, test-clippy, test-fmt, test-cargo-deny, test-cargo-hygiene, test-jj-adapter-hygiene, test-dart-analyze, test-dart-format, test-core(+analyze/format), test-shell(+analyze/format), test-shell-pi(+analyze/format), test-shell-macos(+analyze/format), test-settings(+analyze/format) all PASS; coverage PASS (overall 99.30%, `repo.rs` 97.08, `config.rs`/`convert.rs`/`revset.rs`/`envelope.rs`/ffi `repo.rs` 100, `mutate.rs` ≥ 97.91, every extern covered); test-flutter FAIL only on the 3 pre-existing `app/test/features/bootstrap/zanshin_bootstrap_test.dart` splash-card tests, proven red at the baseline with all changes stashed. `cargo make codegen` outputs committed.

**Residual risks.** Read verbs use settings from the last open/mutation for jj-lib-internal keys until 9.26; a repo with a wrong-typed load-time key cannot be opened until fixed (CLI parity); Zanshin launched from Finder sees launchd's environment.

### Follow-up review pass — 2026-09-23

Status: done. Blocking condition: none. Review diff = this story's own range (`677dbf5..fc362ce`, generated files and this spec excluded); every finding verified against HEAD after Stories 9.22/9.26/9.28, no committed code reverted.

**Summary of the change in this pass.** Creation paths now resolve the config stack for the NEW workspace's paths, exactly like the CLI's `settings_for_new_workspace` (`cli/src/cli_util.rs:372-388` @ v0.44.0): `config::user_settings_for_new_workspace(workspace_root)` builds the stack with `<root>/.jj/repo` + `<root>` (the secure layers find no file yet, as the CLI's reload finds none), so a `--when.repositories` / `--when.workspaces` per-directory identity signs init's and clone's `@` commit and a conversion's snapshot commits. `init`/`clone`/`convert_colocated` derive it right after canonicalizing their root (still before any write); `convert_import` after creating and canonicalizing the destination (the CLI's order; a fault rolls the created directory back).

**Files changed.**
- `crates/zanshin-jj/src/config.rs` — `user_settings_for_new_workspace(workspace_root)`; `load_with` doc (None = no workspace, Story 9.28's handle-less verbs).
- `crates/zanshin-jj/src/repo.rs` — init/clone derive creation settings after canonicalize; `init` `# Errors` sentence fixed; docs.
- `crates/zanshin-jj/src/convert.rs` — both conversions resolve for the destination; `import_into` derives the settings itself; docs.
- `crates/zanshin-jj/tests/config_identity.rs` — `creation_paths`: explicit wrong-typed init stack naming `user.name`; `--when.repositories`-scoped email on init's and `convert_colocated`'s `@` commit (mutation-checked: fails with the old resolution); `convert_import` wrong-typed git key → `Config` + destination rolled back.
- `crates/test-helpers/src/lib.rs` — `TEST_ENV` doc no longer claims to match jj's harness exactly.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` — creation-stack wording.
- `_bmad-output/implementation-artifacts/{sprint-status.yaml,deferred-work.md}` — 9-20 hand-off note, 9-27 follow-up note, dated deferral section.

**Review findings.** 35 (high 1, medium 3, low 22, false 9). Patched: 1 high entry (creation scope resolution; its two low re-open rows grouped under it), 5 low entries (TEST_ENV doc, convert_import config-fault witness, explicit phase state in `creation_paths`, 9-20 hand-off in sprint-status, `init` doc sentence). Deferred: 1 new medium (clone/init/convert report no `identity_missing` where the CLI warns — needs an FFI-surface or UI decision); 2 carried (no-change fetch/describe op, init `.jj/` rollback → 9.20). Rejected: every `false` and `low`-reject row in the triage log above with its reason (9 false — 3 of them disproved by 9.26's `precondition` gate and `mutation_result` funnel; carried rejects for `reload_workspace`, env snapshots, ENV_GUARD copies, mtime granularity).

**Follow-up review recommended: true.** Patched by verdict: high 1, low 5. Unverified risk: the new creation-path resolution changes the order of `convert_import` (settings now derived after the destination is created, so a user-level config fault creates and removes the directory instead of refusing before any write) and `init`/`clone` (a missing path AND a broken stack now report the path error first) — the witnesses cover the scoped identity and the git-key fault, not those two orderings.

**Verification.** `cargo make --allow-private <task>` one by one after the patches: test-cargo PASS, test-clippy PASS, test-fmt PASS (after `cargo fmt`), test-flutter FAIL (only the 3 pre-existing `app/test/features/bootstrap/zanshin_bootstrap_test.dart` splash-card tests), test-dart-analyze, test-dart-format, test-core(+analyze/format), test-shell(+analyze/format), test-shell-pi(+analyze/format), test-shell-macos(+analyze/format), test-settings(+analyze/format), test-cargo-deny, test-cargo-hygiene, test-jj-adapter-hygiene all PASS; coverage PASS (overall 99.38%, no baseline change). `pubspec.lock` drift reverted.

**Residual risks.** Clone/init/convert still give the UI no identity fact (deferred); no-change fetch/describe still write an op (carried).
