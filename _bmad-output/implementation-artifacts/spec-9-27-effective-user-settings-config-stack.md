---
title: 'Story 9.27: `Repo` opens with the effective jj config — identity, op metadata, snapshot/fsmonitor knobs (config-stack parity)'
type: 'feature'
created: '2026-09-17'
status: 'draft'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

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

</frozen-after-approval>

## Code Map

- `crates/zanshin-jj/src/repo.rs` -- `make_settings` (`:1729-1746`) and its callers `open` (`:1455`), `init` (`:1480`), `clone`/`clone_into` (`:1529`)
- `crates/zanshin-jj/src/convert.rs` -- two production `make_settings()` sites (`:137`, `:237`) and three in its inline tests
- `crates/zanshin-jj/src/config.rs` -- `ConfigEnv` (`:240-277`), `user_config_paths` (`:301`), `secure_config_path` (`:335`), `add_user_layers`, `add_secure_layer`, `load_with` (`:398-435`, the `resolve` context with `hostname: ""`), `load` / `load_for_workspace`
- `crates/zanshin-jj/src/mutate.rs`, `op_support.rs` -- consumers of the loaded repo's settings for op metadata and signatures; no change expected beyond the `identity_missing` projection
- `crates/zanshin-jj/tests/*.rs` -- `ENV_GUARD` blocks and `make_test_settings()` stubs; `tests/config_user_layer.rs` (single-binary `JJ_CONFIG` pattern); `tests/op_workspace_name.rs` (op-metadata read-back pattern)
- `schemas/envelope.fbs` -- `MutationResult`; `crates/zanshin-ffi/src/envelope_generated.rs`, `include/zanshin_ffi.h`, `packages/zanshin_core` -- codegen + bridge
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- `identity_missing`, new `jj.config_error` emitters
- `Cargo.toml` (workspace), `deny.toml` -- `whoami`
- `../jj` @ v0.44.0 -- `cli/src/config.rs:288-331` (user path order), `:351-440` (`ConfigEnv`, system paths), `:693-708`, `:736-817` (env layers); `cli/src/cli_util.rs:2387-2415` (identity warning), `:4543` (system reload); `lib/src/settings.rs:135-165`; `lib/src/config/misc.toml`; `lib/src/workspace.rs:410-419`, `:526-555`

## Tasks & Acceptance

**Execution:**
- [ ] `Cargo.toml`, `deny.toml` -- add `whoami` -- the CLI's own source of hostname/username
- [ ] `crates/zanshin-jj/src/config.rs` -- System, EnvBase, EnvOverrides layers in `load_with`; `hostname` in the resolution context; `user_settings_for(loader)` + `user_settings_for_new_workspace()` -- one stack for reads and for opening
- [ ] `crates/zanshin-jj/src/repo.rs`, `convert.rs` -- replace every `make_settings()` with the builders; split open into loader → settings → load; creation paths use the user-level stack -- the story
- [ ] `crates/zanshin-jj/src/repo.rs` -- settings/workspace re-derive on stack change (fingerprint) -- long-lived process parity
- [ ] `crates/zanshin-jj/src/mutate.rs` -- `identity_missing` on `MutationResult` -- the CLI's post-transaction warning as a fact
- [ ] `schemas/envelope.fbs` + `cargo make codegen`; `packages/zanshin_core` -- widen `MutationResult` -- wire contract
- [ ] `crates/zanshin-jj/tests/*.rs` -- `ENV_GUARD` pins the four `JJ_*` identity vars; retire the stubs; identity + op-metadata witnesses via `JJ_CONFIG` -- machine-independent gate
- [ ] `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- rows -- `ffi_abi_doc_sync` enforces the first
- [ ] `coverage-baseline.txt` -- commit the auto-raised baseline -- ratchet

**Acceptance Criteria:**
- Given a user config with `user.name`/`user.email`, when Zanshin writes any mutation, then the new commit's author and the operation's `username`/`hostname` equal what `jj describe` on a twin copy writes.
- Given no identity anywhere in the stack, when Zanshin writes a mutation, then the commit carries the empty identity and the result reports `identity_missing` for both fields.
- Given `JJ_CONFIG` repointed to a file with a distinct identity, when the repo is re-opened, then the next commit carries that identity (single-binary witness).
- Given a repo-level `user.email` override, then commits in that repo use it and commits in another repo do not.
- Given a syntax error in a stack file, then `Repo::open` refuses with `jj.config_error` naming the path.
- Given `cargo make test`, then it is green including the coverage ratchet and `cargo deny`.

## Design Notes

- The split of `Workspace::load` is the only new mechanism: the loader gives the repo path the config stack needs, and the stack gives the settings the loader needs. Everything else is re-wiring existing readers.
- `identity_missing` belongs on `MutationResult`, not on a separate diagnostics call: the CLI prints it at `finish_transaction`, i.e. per mutation; a read never triggers it.
- Landing order across the neighbours: 9.27 (this) → 9.22 → 9.26; 9.28 can land any time after 9.27.

## Verification

**Commands:**
- `cargo make test` -- expected: green, coverage ≥ baseline, `cargo deny` green with `whoami` in the tree
- `cargo make codegen` then `git status` -- expected: generated outputs committed, tree clean

**Manual checks (if no CLI):**
- On a scratch repo with your real `~/.config/jj/config.toml`: a Zanshin `describe`, then `jj log -r @ -T 'author ++ "\n"'` and `jj op log --limit 1` show your identity and machine, indistinguishable from a CLI-written one.
