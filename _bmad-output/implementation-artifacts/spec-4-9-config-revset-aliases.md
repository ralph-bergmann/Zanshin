---
title: 'Story 4.9: Honor jj config revset aliases + expose the effective log defaults'
type: 'feature'
created: '2026-08-24'
status: 'blocked'
baseline_revision: 'a5d20bb8490678df44107e74dbe1fa2ad91eda31'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
  - '{project-root}/_bmad-output/specs/spec-4-9-config-revset-aliases/SPEC.md'
  - '{project-root}/_bmad-output/specs/spec-4-9-config-revset-aliases/jj-config-reference.md'
warnings: ['oversized']
deferred:
  - summary: >-
      `packages/zanshin_core/test/worker/events_test.dart` is de-flaked with a fixed 400 ms
      settle rather than a deterministic drain signal, and the race it papers over is
      pre-existing.
    evidence: |-
      The test asserts an ABSENCE ("repo B was never touched"), which is inherently
      timing-dependent. `initRepo` itself writes into `.jj/repo/op_heads/heads/` and the
      watcher is armed BEFORE the open call returns, so repo B's own init event can beat the
      listener attach. Confirmed pre-existing and unrelated to Story 4.9: `crates/zanshin-jj/src/repo.rs`
      is purely additive (`open`/`init`/`clone` and `make_settings` untouched), so nothing in
      this story touches the watcher path. Reproduction: restoring HEAD's version of the file
      and running `dart test test/worker/events_test.dart` in isolation passes 3/3, but the
      same file fails under full-suite load — this story's two new Dart test files raised that
      load enough to surface it. The settle matches the file's own existing idiom (it already
      carries a 300 ms trailing sleep at the same assertion), and removing it fails the gate.
      It widens the observation window rather than eliminating the race, so it will still flake
      on a sufficiently loaded host. A deterministic fix needs a drain/quiescence signal the
      worker does not currently expose, which is its own change.
    location: >-
      packages/zanshin_core/test/worker/events_test.dart:90
    severity: medium
  - summary: >-
      A revset alias dropped by the CLI-parity warn-and-continue path is invisible to a GUI
      user — it is logged via `tracing::warn!` and nothing crosses the envelope.
    evidence: |-
      The jj CLI writes these to `ui.warning_default()`, so its user sees "Failed to load
      `revset-aliases.foo()`: …". Zanshin has no terminal, and this story's Non-goals forbid
      new FFI surface beyond CAP-2, so the warning stays in the rotating log file. Consequence:
      in the GUI a silently dropped alias is indistinguishable from one that was never defined
      — which bites exactly the recognizability dimension the story exists for. Closing it
      means carrying non-fatal diagnostics on the envelope (a wire change), or a diagnostics
      channel, and belongs with whatever story introduces that surface.
    location: >-
      crates/zanshin-jj/src/revset.rs (build_aliases_map warn paths)
    severity: medium
  - summary: >-
      `RevsetParseContext.user_email` still comes from the hardcoded `make_settings` identity,
      so a jj builtin keyed on the user's email resolves differently than in their CLI.
    evidence: |-
      `make_settings` pins `user.email = "zanshin@localhost"` in a `ConfigSource::User` layer
      and is deliberately untouched by this story: merging the real user config into the repo's
      `UserSettings` would let a repo's `user.name` take over commit/operation authorship and
      would collide on that very source. The config stack this story adds is read-only and
      revset/log-scoped, and `user.*` is outside CAP-2's four values. Pre-existing (it predates
      4.9), but now visibly inconsistent with "aliases resolve exactly as the jj CLI resolves
      them". Closing it means deciding how Zanshin's identity and the user's identity coexist.
    location: >-
      crates/zanshin-jj/src/revset.rs:128
    severity: low
---

<intent-contract>

## Intent

**Problem:** `zanshin-jj` reads no jj config at all. `make_settings()` (`crates/zanshin-jj/src/repo.rs:457`) builds `StackedConfig::with_defaults()` plus one hardcoded `[user]`/`[operation]` literal — no user file, no repo file — and Story 4.8's builtin `[revset-aliases]` live in a Rust `const BUILTIN_ALIASES` array (`revset.rs:173`) that nothing can override. A user who redefines `trunk()` or `immutable_heads()`, or who defines `wip()`/`mine()`, gets a Zanshin graph that disagrees with their own `jj log` — different ◆ set, different default view — and a hard parse error for aliases their CLI accepts. The four log defaults (`revsets.log`, `revsets.log-graph-prioritize`, `revsets.short-prefixes`, `ui.log-synthetic-elided-nodes`) likewise exist only as frozen Rust/Dart constants, so the UI pre-fills values the user's CLI would not apply.

**Approach:** Add one config loader in `zanshin-jj` (the sole `jj_lib` importer) that rebuilds, per operation, the layered `StackedConfig` the jj CLI would have at v0.42.0 for that workspace — Zanshin's builtin defaults layer, then user config, repo config and workspace config — and run it through `jj_lib::config::resolve`. Story 4.8's alias table stops being a Rust array and becomes that builtin **default layer**, so builtins and user aliases enter the `RevsetAliasesMap` through the one code path the CLI uses (all layers, lowest first). Both existing parse sites take their aliases from it, so the graph slice, `prioritize`, `short_prefixes`, plain revset resolution and the per-row `immutable` flag all follow the user's config for free. The same loader backs one new read — `Repo::log_defaults()` and the `zanshin_log_defaults` extern fn — returning the four effective values.

## Boundaries & Constraints

**Always:**
- **The pinned CLI is the oracle (NFR-R-2, ADR-0003).** Layer order, discovery rules, fallbacks and error/warning split are read at `v0.42.0` from `../jj` (`git -C ../jj show v0.42.0:cli/src/config.rs`, `:cli/src/cli_util.rs`, `:cli/src/config/*.toml`) and from the vendored `jj-lib-0.42.0`. Where the SPEC's prose and the pinned CLI disagree, the CLI wins (the SPEC's own "mirrored at the pin (v0.42.0)" clause and the companion's "for contract questions the tag's sources below win"). Two such corrections are already known and are recorded in Design Notes — do not implement the prose instead.
- **One resolution path.** All config loading lives in the new `crates/zanshin-jj/src/config.rs`. `build_aliases_map` takes the loaded config; the only two parse entry points (`revset::parse_revset`, `graph::walk_graph`) both feed from it. No second code path, no alias table left in Rust.
- **Re-read per operation, never cached.** `Repo` gains no config field; `load_at_head`-scoped calls load the stack themselves. Config files change externally and the op-heads watcher does not cover them.
- **Read-only on disk.** Config loading must not create, move, migrate or symlink anything.
- **ACL (FR-JJ-16) unchanged.** `jj_lib` stays inside `zanshin-jj`; `crates/zanshin-jj/src/lib.rs:24` forbids `pub use jj_lib::…` (mechanically gated by `Makefile.toml:192-220`), so the new public surface is plain `String`/`bool`/`thiserror` types only.
- **Pass-throughs stay pass-throughs (FR-JJ-17).** `walk_graph`'s `revset` / `prioritize` / `short_prefixes` arity and semantics are unchanged; nothing Rust-side silently substitutes a config value for a caller argument. `log_defaults()` *offers* the effective defaults; the caller decides.
- **Transport (ADR-0001).** `schemas/envelope.fbs` edited in place (WIP, no versioning); the new payload table is **appended** to `union Payload` (member order is the wire discriminant). `cargo make codegen` regenerates all four generated files, committed in the same change.
- **Error taxonomy.** One new registry code `jj.config_error` (malformed/unreadable config, bad `config-id`, wrong-typed config value) added to `docs/rust-error-codes.md` and `crates/zanshin-ffi/src/envelope.rs` in the same change. Everything else reuses `ffi.invalid_handle` / `jj.*` as today.
- **Test-suite isolation is now load-bearing.** Every test keeps pinning `JJ_CONFIG` and `GIT_CONFIG_GLOBAL`; a test may point `JJ_CONFIG` at a temp path but **never unsets it** — unset means the developer's real `~/.config/jj/config.toml` would load. Because `JJ_CONFIG` is process-global and `cargo test` threads a binary, any test that changes it lives alone in its own `tests/*.rs` file.
- **Quality bar.** clippy pedantic refactor-not-suppress, rustfmt, SPDX first line on new files, `# Errors`/`# Safety` rustdoc on the extern fn, scenario-named tests, no `#[ignore]`/`skip:`, no timing asserts, `dart analyze`/`dart format` clean.
- **Coverage ratchet.** `cargo make test` exits 0 with `coverage-check: OK` and `extern-coverage: OK`; both new Rust files ≥ 80 % (peers sit at ~100 %). The new extern fn needs a real-cdylib `packages/zanshin_core` test or the extern-coverage guard flags it. Commit the raised `coverage-baseline.txt`.
- **Repo conventions.** ONE focused commit on `main`; `app/analysis_options.yaml` gate churn reverted, never committed; `epic-4-context.md` edited LAST so it stays newer than every planning artifact.

**Block If:**
- `cargo make test` fails for a reason outside this story that cannot be fixed in scope (never lower the baseline, never add an `exclude_prefix`, never add a name to `EXTERN_COV_ALLOW`).
- `cargo make codegen` is unavailable (flatc / cbindgen / ffigen missing) — generated files must come from the tool, never by hand.
- Commit signing fails with `op-ssh-sign` "failed to fill whole buffer" (locked 1Password): stage the work and HALT `blocked`. **Never** `--no-gpg-sign`.
- A jj-lib 0.42 config API named in the Code Map turns out not to exist as investigated and no equivalent observable behavior can be reproduced.

**Never:**
- Do NOT touch `make_settings()` or the `Repo`'s `UserSettings`. Feeding the user's config into it would let a repo's `user.name` override Zanshin's commit/operation identity and break the `op_log` oracles — and `user.*` is out of scope. The new stack is read-only, revset/log-scoped, and never becomes `UserSettings`.
- Do NOT call `jj_lib::secure_config::SecureConfig::{load_config, maybe_load_config}`. Those WRITE: they create directories, write `metadata.binpb`, generate a `config-id`, copy configs on repo-move detection and replace a legacy `.jj/repo/config.toml` with a symlink, and they consume an RNG. Resolve the indirection by hand, read-only.
- No `--config` / `--config-file` command-line layer, no `ConfigSource::EnvBase` / `EnvOverrides` layers (their key set is provably disjoint from this story's — see Design Notes), no `config_resolver::migrate` (empty rule list at the pin), no fileset aliases, no template aliases, no config writing/editing, no settings surface beyond the four values.
- Do NOT cache the config on the handle or anywhere else; no `Arc<Mutex>`/`RwLock`; no JSON on the wire; no `#[allow(...)]` to dodge clippy.
- Do NOT add a new crate (`Makefile.toml:142-190` hard-asserts exactly 8 tracked `Cargo.toml` files). Prefer adding no dependency at all: the platform config dir is a five-line rule on this macOS-only project.
- Do NOT change `RepoHandle.graphSlice`'s default parameter values to config-derived ones — Dart defaults must stay compile-time constants, and a silently applied config value would violate FR-JJ-17.
- Do NOT regenerate fixtures; construct config cases in-test on an extracted fixture copy or a temp repo.
- Do NOT edit `_bmad-output/implementation-artifacts/sprint-status.yaml` (the orchestrator owns tracking for this run).
- No shelling to `jj` from production code or tests; no Flutter UI.

## I/O & Edge-Case Matrix

Fixture facts: **tiny-3-commits** = `root` ← `@` and `root` ← c1 ← c2 ← c3; `all()` = 5 rows. Extracted fixtures carry **no** `.jj/repo/config.toml` and **no** `.jj/repo/config-id`, so with `JJ_CONFIG=""` the effective config is exactly the builtin default layer.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| No user/repo config | `JJ_CONFIG=""`, extracted fixture | All 7 builtin aliases expand and resolve; `walk_graph` on `DEFAULT_LOG_REVSET` and every per-row `immutable` flag are unchanged from Story 4.8 | none |
| `log_defaults` with no overrides | same | `log` == `DEFAULT_LOG_REVSET`, `log_graph_prioritize` == `DEFAULT_GRAPH_PRIORITIZE` (`present(@)`), `short_prefixes` == `DEFAULT_LOG_REVSET` (CLI fallback), `synthetic_elided` == `true` | none |
| Repo-config alias override | `.jj/repo/config.toml` with `[revset-aliases]` `'trunk()' = 'root()'` | `resolve_revset("trunk()")` yields the root change; the default-view row set and the `immutable` flags follow the override | none |
| `immutable_heads()` override flips ◆ | repo config `'immutable_heads()' = 'all()'` (or `'none()'`) | Rows that were `immutable == false` flip (resp. all become mutable except root, which stays immutable via the in-code `\| root()` union) | none |
| Custom alias | repo config `'wip()' = 'description(glob:"wip:*")'` | `resolve_revset("wip()")` evaluates; before this story it was `RevsetError::ParseError` | none |
| User layer via `JJ_CONFIG` file | `JJ_CONFIG` = temp `.toml` defining `'trunk()' = 'root()'` | Same override effect as the repo layer | none |
| `JJ_CONFIG` names a directory | dir with two `*.toml` files defining the same alias | Both load, lexicographic order; the later file wins | none |
| `JJ_CONFIG` entry missing | `JJ_CONFIG` = path that does not exist | Silently ignored, no layer, no error (CLI parity) | none |
| `JJ_CONFIG=""` | the suite's pin | Discovery is fully disabled — zero user layers; platform files are NOT read | none |
| Layer precedence | same alias in the `JJ_CONFIG` user file and in `.jj/repo/config.toml` | The repo value wins | none |
| Workspace layer | legacy `.jj/workspace-config.toml` defining the alias, plus a different repo-config value | The workspace value wins (`ConfigSource::Workspace` > `Repo` at the pin) | none |
| Repo config via `config-id` | `.jj/repo/config-id` holding 20 hex chars | The layer is read from `<config_dir>/jj/repos/<id>/config.toml`; the legacy file is NOT read and NOT migrated or symlinked | none |
| Bad `config-id` | `config-id` that is not exactly 20 ASCII hex chars | `jj.config_error` with the offending path in `context` (CLI hard-errors here) | propagated, no panic |
| Malformed config TOML | `.jj/repo/config.toml` = `not = = toml` | `RevsetError::Config` → `jj.config_error`, context names the file; **never** a silent fall-back to builtins | propagated, no panic |
| Non-string alias value | `'foo()' = 42` | `tracing::warn!`, entry skipped, every other alias still works, the call SUCCEEDS (CLI parity) | warn, not error |
| Bad alias declaration | `'not a decl' = 'root()'` | `tracing::warn!`, entry skipped, call succeeds | warn, not error |
| Malformed alias definition | `'wip()' = '('` | Insert succeeds (jj-lib does not check `defn`); a revset that USES `wip()` fails with `jj.revset_parse_error`; one that does not is unaffected | error only on use |
| `revsets.log` override | repo config `[revsets] log = "@"` | `log_defaults().log == "@"`; `short_prefixes` follows it too (unset ⇒ fallback to `revsets.log`) | none |
| `short-prefixes` explicit | repo config `short-prefixes = "trunk()"` / `= ""` | Returned verbatim; `""` means disabled and is NOT replaced by the `revsets.log` fallback | none |
| `ui.log-synthetic-elided-nodes` | repo config `= false` | `log_defaults().synthetic_elided == false` | none |
| Wrong-typed config value | `log-synthetic-elided-nodes = "yes"` or `[revsets] log = 42` | `jj.config_error` naming the key (CLI hard-errors on a type mismatch) | propagated, no panic |
| `zanshin_log_defaults` bad handle | handle `0`, or a handle after `zanshin_repo_close` | `ok:false`, `ffi.invalid_handle`, empty `context` | no deref |
| Dart round-trip | real cdylib, fresh `initRepo` temp dir, `RepoHandle.logDefaults()` | Decodes the four builtin values; matches the `defaultLogRevset` / `defaultGraphPrioritize` / `defaultShortPrefixes` / `defaultSyntheticElided` consts | errors surface as `ZanshinFfiException` with the same codes |
| Dart closed handle | `logDefaults()` after `handle.close()` | Synchronous `StateError` from the `RepoHandle` guard; via `worker.logDefaults(id)` directly: `ffi.invalid_handle` | — |

</intent-contract>

## Code Map

**`zanshin-jj` — the config loader (new, sole `jj_lib` importer)**

- `crates/zanshin-jj/src/config.rs` (**NEW**) — the whole layer stack. Public: `ConfigError` (one variant, `Load { reason }`, `thiserror`) and `LogDefaults { log, log_graph_prioritize, short_prefixes, synthetic_elided }`. Crate-internal: `load(repo) -> Result<StackedConfig, ConfigError>` and `log_defaults(config) -> Result<LogDefaults, ConfigError>`.
  - Builtin layer: `StackedConfig::with_defaults()` (jj-lib's own `Default` layer) then `add_layer(ConfigLayer::parse(ConfigSource::Default, BUILTIN_CONFIG_TOML)?)` — a TOML literal holding `[revsets] log / log-graph-prioritize`, `[ui] log-synthetic-elided-nodes = true` and the 7-entry `[revset-aliases]` table, copied verbatim from `git -C ../jj show v0.42.0:cli/src/config/revsets.toml` and `:cli/src/config/misc.toml:43`. This is where Story 4.8's `BUILTIN_ALIASES` array moves to. Do NOT copy the CLI's other `[revsets]` keys (`arrange`, `fix`, `sign`, …) — no verb consumes them.
  - User layer (`ConfigSource::User`), replicating `cli/src/config.rs:288-331` + `:433-479`: if `JJ_CONFIG` is **set at all** (empty string included) it REPLACES discovery — `std::env::split_paths`, drop empty components, each entry may be a file or a directory, a missing entry is silently skipped. Unset ⇒ `$HOME/.jjconfig.toml` (only if it exists), then `<config_dir>/jj/config.toml`, then `<config_dir>/jj/conf.d/` (as a directory) — later = higher precedence, non-existent paths skipped. `<config_dir>` on this macOS-only project = `$XDG_CONFIG_HOME` when absolute, else `$HOME/.config` (etcetera's `choose_base_strategy` maps macOS to XDG; a `// WHY:` comment records that, no new dependency). Files load via `StackedConfig::load_file`, directories via `load_dir` (non-recursive, `*.toml`, sorted).
  - Repo layer (`ConfigSource::Repo`) and workspace layer (`ConfigSource::Workspace`), mirroring `cli/src/config.rs:485-546` + `:531-540` / `:599-612` but READ-ONLY: read `<repo_path>/config-id` (resp. `<workspace_root>/.jj/workspace-config-id`); when present and exactly 20 ASCII hex chars the file is `<config_dir>/jj/repos/<id>/config.toml` (resp. `.../workspaces/<id>/config.toml`); when the id file is absent fall back to legacy `<repo_path>/config.toml` (resp. `<workspace_root>/.jj/workspace-config.toml`); when `<config_dir>` cannot be determined the secure path is skipped (CLI parity). `<repo_path>` is `workspace.repo_path()` — jj-lib already resolves the `.jj/repo`-is-a-FILE indirection of secondary workspaces.
  - Finally `jj_lib::config::resolve(&config, &ConfigResolutionContext { home_dir: canonicalized `$HOME`, repo_path, workspace_path, command: None, hostname: "", environment: &env::vars().collect() })` to flatten `--when`/`--scope`. Skip `migrate` (`cli/src/config.rs:825` returns an empty rule list at the pin).
  - `log_defaults`: `get::<String>("revsets.log")`, `get::<String>("revsets.log-graph-prioritize")`, `get_bool("ui.log-synthetic-elided-nodes")`, and — mirroring `cli/src/cli_util.rs:987-1009` — `get::<String>("revsets.short-prefixes").optional()?` falling back to `revsets.log` **on absence only**, never on empty.
  - Keep the path-selection logic in pure functions taking explicit inputs (`jj_config: Option<&OsStr>`, `xdg: Option<&Path>`, `home: Option<&Path>`, dir + id-file + legacy-file) with a thin `from_env` wrapper, so the whole selection matrix is inline-unit-testable without touching process env. That is also what gets this file over the 80 % floor.
- `crates/zanshin-jj/src/revset.rs` — DELETE `const BUILTIN_ALIASES` (`:173-195`); `build_aliases_map(config: &StackedConfig) -> RevsetAliasesMap` becomes **infallible** and mirrors `cli/src/config.rs:930-981`: iterate `config.layers()` lowest→highest, per layer look up the `revset-aliases` table, and for each entry insert the string value (a table with a `definition` string key is also accepted by the CLI — accept it too); a non-string value or a failing `insert` is a `tracing::warn!` and `continue`, never an error. `parse_revset` (`:96`) loads the config and builds the map. `RevsetError` gains `#[error(transparent)] Config(#[from] ConfigError)`. `parse_revset_with`, `evaluate_revset` and `immutable_expression` (`:223`) are untouched — the latter picks up an `immutable_heads()` override for free, which is why 4.8 built it in code rather than from the `immutable()` alias.
- `crates/zanshin-jj/src/graph.rs:165-173` — `walk_graph` loads the config ONCE per call and passes it to `build_aliases_map`; the four expressions keep sharing that one map. The `short_prefixes` warn-and-degrade path (`:113`) is the precedent for the alias warn-and-continue style.
- `crates/zanshin-jj/src/repo.rs` — ADD `pub fn log_defaults(&self) -> Result<LogDefaults, ConfigError>`, a two-line delegator exactly like `list_remotes` (`:179-181`). `make_settings` (`:457-474`) and the `open`/`init`/`clone` constructors stay as they are.
- `crates/zanshin-jj/src/lib.rs:42-52` — `pub use config::{ConfigError, LogDefaults};` plus the module declaration; the crate is `#![deny(missing_docs)]`.
- `crates/zanshin-jj/README.md`, `crates/zanshin-jj/src/repo.rs:191-217` rustdoc — retire "the CLI's builtin `[revset-aliases]` … are all defined" in favour of "resolved from the repo's effective jj config, builtin defaults included".

**`zanshin-jj` tests**

- `crates/zanshin-jj/tests/revset.rs` — `every_builtin_revset_alias_expands_and_resolves` (`:190`) and `mutable_and_immutable_partition_all` (`:212`) MUST keep passing unchanged: they are the no-regression proof for the default layer. ADD the repo-config override / custom-alias / precedence / malformed-config / warn-and-continue rows, writing `.jj/repo/config.toml` into the extracted fixture (`test_helpers::extract_fixture` returns a writable temp workspace root).
- `crates/zanshin-jj/tests/config_user_layer.rs` (**NEW**, one `#[test]`) — the only place that points `JJ_CONFIG` at something other than `""`. One test, so nothing races the process-global var; it covers the file form, the directory form and user-vs-repo precedence, and it never unsets the var. Document that rule in the file header.
- `crates/zanshin-jj/tests/graph.rs` — `walk_graph_accepts_the_cli_default_log_revset` (`:562`), `trunk_alias_resolves_a_main_bookmark_on_origin_and_ignores_other_remotes` (`:958`) and `walk_graph_immutable_covers_the_ancestry_of_every_immutable_head` (`:990`, whose doc says it "pins the ancestry semantics Story 4.9's config layer must preserve") are the regression guards. ADD the `immutable_heads()`-override row proving the ◆ set follows config.
- `crates/zanshin-jj/tests/api_stability.rs` — type aliases (`:16-65`) for `ConfigError` / `LogDefaults`, and a value assertion next to the `DEFAULT_LOG_REVSET` one (`:151-160`) pinning that the builtin layer's `revsets.log` equals `DEFAULT_LOG_REVSET` and `log-graph-prioritize` equals `DEFAULT_GRAPH_PRIORITIZE` — the anti-drift check between the const and the TOML literal.

**`zanshin-ffi` + wire**

- `schemas/envelope.fbs` — ADD `table LogDefaults { log: string; log_graph_prioritize: string; short_prefixes: string; synthetic_elided: bool; }` near the other payload tables (`Diagnostics` at `:55-61` is the shape template) and **append** `LogDefaults` to `union Payload` (`:312-324`, currently 11 members — appending keeps every existing discriminant).
- `crates/zanshin-ffi/src/log_defaults.rs` (**NEW**) — modelled line-for-line on `remotes.rs` (154 lines, the smallest handle→payload read): private `log_defaults_to_envelope(&LogDefaults) -> Vec<u8>`, private `map_config_err(ConfigError) -> FfiErrorObj` → `jj.config_error`, and `#[no_mangle] pub unsafe extern "C" fn zanshin_log_defaults(handle: u64) -> *mut ZanshinBuf` using the verbatim `handle_from_raw::<RepoSession>` + `FFI_INVALID_HANDLE` block from `remotes.rs:85-89`, wrapped in `catch`, returned through `vec_into_token`. Inline `#[cfg(test)] mod tests`: builder round-trip through `flatbuffers::root::<fbs::Envelope>` + typed accessors, and the error-mapper unit test.
- `crates/zanshin-ffi/src/lib.rs:32-45` — register `pub mod log_defaults;` in the alphabetical block.
- `crates/zanshin-ffi/src/envelope.rs:15-58` — ADD `pub const JJ_CONFIG_ERROR: &str = "jj.config_error";` (single-emission-point rule).
- `crates/zanshin-ffi/src/graph.rs:34-53` — `map_lane_stream_err` gains the `RevsetError::Config` arm → `JJ_CONFIG_ERROR`; extend the inline mapper test at `:735-747`.
- `crates/zanshin-ffi/tests/graph_ffi.rs` — ADD the FFI-surface rows: malformed repo config on an extracted fixture ⇒ `ok:false` + `jj.config_error`; an alias override visible through `zanshin_graph_slice` on the same handle (which also re-proves the no-caching rule).
- `crates/zanshin-ffi/tests/` — a new `log_defaults_ffi.rs` (or an added block in an existing repo-handle test file) covering the happy path, the override and `handle = 0`.
- `crates/zanshin-ffi/include/zanshin_ffi.h`, `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/{bindings.dart,envelope_zanshin.ffi_generated.dart}` — regenerated by `cargo make codegen` ONLY (`Makefile.toml:226-281`); commit all four.

**Dart bridge (`packages/zanshin_core`)**

- `lib/src/ffi/log_defaults.dart` (**NEW**) — the 4-section shape of `lib/src/ffi/remotes.dart` (78 lines): adapter `Uint8List zanshinLogDefaults(int rawHandle)` (token → `FfiBuffer.fromToken` → `Uint8List.fromList(buf.bytes)` in `try` / `buf.dispose()` in `finally`; no `calloc`, handle-only), a `final class LogDefaults` model, `@visibleForTesting decodeLogDefaultsEnvelope` + `decodeLogDefaultsEnvelopeInternal` over one private impl, and a field mapper with `?? ''` coalescing.
- `lib/src/worker/commands.dart:92-102` (`RemotesCommand` is the template) — `LogDefaultsCommand({required super.commandId, required this.handleId})`.
- `lib/src/worker/isolate.dart` — the aliased import (`:28` pattern), the dispatch arm modelled on `:830-845` (handle lookup, `ffi.invalid_handle` envelope built Dart-side when unknown, else `BufferResult(bytes)`), and `ZanshinWorker.logDefaults` modelled on `:585-598`.
- `lib/src/worker/handle.dart:162-172` — `RepoHandle.logDefaults()` with the `_closed` `StateError` guard; add the `show LogDefaults` import (`:8` pattern). Check whether `lib/zanshin_core.dart` (the 15-line barrel) needs the model exported.
- `lib/src/ffi/graph.dart:26/33/41/50` — the four `default*` consts STAY (compile-time pre-fills). Extend their doc comments to point at `RepoHandle.logDefaults()` as the config-resolved source the UI should prefer.
- `test/worker/log_defaults_test.dart` (**NEW**, `test/worker/remotes_test.dart` at 114 lines is the template) — the real-cdylib round trip that credits `zanshin_log_defaults` in the extern-coverage guard, plus the closed-handle cases. `test/ffi/log_defaults_test.dart` (**NEW**, `test/ffi/remotes_test.dart` template) — synthetic `*ObjectBuilder` decode contract: error envelope, wrong payload type, full field equality. Note `Platform.environment` is read-only in Dart: `JJ_CONFIG=""` comes from `Makefile.toml:120`, so Dart tests can only exercise the builtin-defaults case and must survive `JJ_CONFIG=""`.

**Docs + planning + baseline**

- `docs/rust-error-codes.md:33-56` — ADD the `jj.config_error` row (domain `jj`, Story 4.9).
- `docs/ffi-abi.md` — ADD a `## LogDefaults payload and `zanshin_log_defaults` (Story 4.9)` section at the end, following the GraphSlice section's shape (`:343-363`): C prototype, payload schema, parameter/return semantics, error table, worker integration. Also note in the `zanshin_graph_slice` section that the three revset pass-throughs now resolve config aliases.
- `_bmad-output/planning-artifacts/epics.md` — ADD a `### Story 4.9` section after Story 4.8's, in the established style with a dated "**Delivered (2026-08-24, Story 4.9 done):**" note pointing at `_bmad-output/specs/spec-4-9-config-revset-aliases/`.
- `_bmad-output/implementation-artifacts/epic-4-context.md:19` — 4.9 → done with a one-line delivery note; also refresh the `revset.rs` alias-table mentions at `:18`/`:35`. **EDIT LAST** so the cached epic context stays newer than every planning artifact.
- `coverage-baseline.txt` — expect movement on `crates/zanshin-jj/src/{revset,graph,repo}.rs` and `crates/zanshin-ffi/src/graph.rs`; the new `crates/zanshin-jj/src/config.rs` and `crates/zanshin-ffi/src/log_defaults.rs` must land ≥ 80 % (aim ~100 %, matching their peers). Commit the raised file.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/config.rs` (new) — the layered loader, the builtin TOML default layer, `resolve`, `ConfigError`, `LogDefaults`, and pure path-selection helpers with inline unit tests — CAP-1 + CAP-2, the single resolution path.
- `crates/zanshin-jj/src/revset.rs` — retire `BUILTIN_ALIASES`, make `build_aliases_map` config-fed and infallible with CLI warn-and-continue semantics, add `RevsetError::Config` — the seam 4.8 left for this story.
- `crates/zanshin-jj/src/{graph.rs,repo.rs,lib.rs}` — load the config once per `walk_graph`, add `Repo::log_defaults`, export the new types, refresh the rustdoc that claims aliases are builtin-only.
- `schemas/envelope.fbs` — `LogDefaults` table appended to the `Payload` union — the wire contract (edit in place, WIP).
- `crates/zanshin-ffi/src/{log_defaults.rs,lib.rs,envelope.rs,graph.rs}` — the extern fn + builder + `jj.config_error` const + the new `map_lane_stream_err` arm — CAP-2 across the wire.
- run `cargo make codegen` — regenerate header, bindings and both flatc outputs; commit all four.
- `packages/zanshin_core/lib/src/ffi/log_defaults.dart` and `lib/src/worker/{commands,isolate,handle}.dart` — adapter, model, decoder, command, dispatch arm, worker verb, handle verb — CAP-2 reaches the UI.
- `crates/zanshin-jj/tests/{revset.rs,graph.rs,api_stability.rs}` + `crates/zanshin-jj/tests/config_user_layer.rs` (new) — every config-layer row of the I/O matrix, plus the const-vs-TOML drift pin and the untouched 4.8 regression guards.
- `crates/zanshin-ffi/tests/{graph_ffi.rs,log_defaults_ffi.rs}` and `packages/zanshin_core/test/{worker,ffi}/log_defaults_test.dart` — the FFI-surface and real-cdylib rows; the worker test is what credits the new extern fn in the extern-coverage guard.
- `docs/rust-error-codes.md`, `docs/ffi-abi.md` — registry + ABI contract — FFI-surface change discipline.
- `_bmad-output/planning-artifacts/epics.md`, then `_bmad-output/implementation-artifacts/epic-4-context.md` (LAST) — doc reconciliation; keep the epic-context cache valid and newest.
- run `cargo make test` (unpiped, exit code read directly) — fix by refactoring/adding tests; commit the raised `coverage-baseline.txt`; revert `app/analysis_options.yaml` churn; ONE commit — definition of done.

**Acceptance Criteria:**
- Given an extracted fixture whose `.jj/repo/config.toml` redefines `trunk()` and `immutable_heads()` and adds a custom `wip()`, when `zanshin_graph_slice` is called on the CLI default log revset and `resolve_revset("wip()")` is called, then the returned row set, the per-row `immutable` flags and the `wip()` resolution all match what `jj` v0.42.0 would produce with that config — and with the config file removed, output is identical to Story 4.8's.
- Given the same handle, when the config file is changed between two calls, then the second call reflects the new config without reopening the handle — proving config is re-read per operation and never cached.
- Given a repo config that overrides `revsets.log` and sets `ui.log-synthetic-elided-nodes = false`, when `Repo::log_defaults()` / `zanshin_log_defaults` / `RepoHandle.logDefaults()` are called, then the overrides are returned and `short_prefixes` follows `revsets.log` on absence; with no overrides the four values equal the constants Story 4.8 ships.
- Given a malformed config file or a wrong-typed config value, when any revset is parsed or `log_defaults` is read, then the call fails with `jj.config_error` and a context naming the file or key — never a silent fall-back to the builtin layer; whereas a single bad `[revset-aliases]` entry only warns and the call still succeeds.
- Given the finished tree, when `cargo make codegen` has run and `cargo make test` runs unpiped, then it exits 0 with `extern-coverage: OK` and `coverage-check: OK`, no per-file regression, both new Rust files ≥ 80 %, clippy/fmt/analyze/format/deny green, and `git status` is clean after the single commit (deliberate gate-churn reverts aside).

## Spec Change Log

## Review Triage Log

### 2026-08-24 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 10: (high 0, medium 4, low 6)
- defer: 3: (high 0, medium 2, low 1)
- reject: 18: (high 0, medium 0, low 18)
- addressed_findings:
  - `[medium]` `[patch]` A non-table `revset-aliases` warned and skipped the layer instead of hard-erroring — the exact "silent fall-back to builtins" the intent-contract forbids. Verified against the pin: `cli/src/config.rs:943-953` returns `ConfigGetError::Type` for the table-level branch; only the per-entry branch at `:964-977` warns. Flagged independently by three review layers. `build_aliases_map` is fallible again, both call sites updated, the rustdoc corrected, the test that pinned the wrong behavior rewritten as `a_non_table_revset_aliases_key_is_a_config_error`, and the three doc sites that cited `:964-977` as authority for the table-level case fixed (`docs/rust-error-codes.md`, `docs/ffi-abi.md`, `epics.md`). Per-entry warn/skip was verified correct and left alone.
  - `[medium]` `[patch]` The `config-id` indirection — the change's headline correction against the SPEC — was only tested for path *construction* against a fabricated root. Swapping or misspelling `root.join("repos")` / `join("workspaces")` passed the whole suite, because every behavioral test goes through the legacy fallback and `add_secure_layer` silently adds nothing when the path does not exist. Added `add_secure_layer_loads_the_file_the_config_id_points_at`, which creates a real `<root>/<20-hex>/config.toml` and asserts the layer loads.
  - `[medium]` `[patch]` `jj_lib::config::resolve` was called but never exercised: no test contained a `--when` or `[[--scope]]` block, so replacing it with `Ok(config)` passed everything, while a user keeping per-repo `[revset-aliases]` under `[[--scope]]` would silently get the builtins. Added `a_matching_when_scope_is_flattened_into_the_layer` and `a_non_matching_when_scope_is_dropped`.
  - `[medium]` `[patch]` CAP-1's success criterion names both the `immutable` flag *and* the default-view contents, but no test at any layer walked `DEFAULT_LOG_REVSET` under an alias override — the ◆ half was covered over `all()` (which asserts the row set is unchanged) and the alias half over `wip()`. Added `an_alias_override_changes_the_default_log_views_row_set`.
  - `[low]` `[patch]` `resolve_revset`'s public `# Errors` rustdoc still listed only `ParseError`/`ResolutionError`/`JjLibError` although it can now return `RevsetError::Config`; the crate's only public revset entry point had been missed while `parse_revset`, `walk_graph` and `Repo::walk_graph` were all updated.
  - `[low]` `[patch]` `RevsetError::Config` was not pinned in `crates/zanshin-jj/tests/api_stability.rs`, although every other public error variant is — and it is the variant `zanshin-ffi::map_lane_stream_err` matches on.
  - `[low]` `[patch]` `revsets.short-prefixes` was the only one of the four values with no wrong-type test; `.optional()` re-raises `Type` errors, so the behavior was intended but unproven. Added a third block to `a_wrong_typed_config_value_is_a_config_error_naming_the_key`.
  - `[low]` `[patch]` A malformed *user* config file was unproven — `add_user_layers`' `file_error` path is the only place a `ConfigSource::User` path reaches an error context, and every malformed-file assertion ran against the repo layer. Folded into the single user-layer test.
  - `[low]` `[patch]` The `config.rs` module doc claimed hand-resolving the indirection yields "identical config CONTENT in every case"; `jj-lib-0.42.0/src/secure_config.rs:187-227` re-points or copies the config on repo move/copy detection, so after a repo copy the two can read different files. Claim softened and the exception named.
  - `[low]` `[patch]` `docs/ffi-abi.md` attributed the envelope decode to `LogDefaultsCommand`, which carries only `handleId`; the decode happens in `ZanshinWorker.logDefaults` on the main isolate. Fixed — that paragraph is the template later stories copy.

Notes on the largest reject groups, recorded because each was checked rather than dismissed:

- **`<config_dir>` derived from a canonicalized `$HOME`** (claimed to load a different config than the CLI): rejected. A symlinked `$HOME` and its canonical target share the same `.config` directory, so the resolved files are identical; only the recorded path string differs.
- **Non-UTF-8 `JJ_CONFIG`** (we use `var_os`, the CLI uses `var().ok()` and would fall back to discovery): rejected as unreachable through any supported action on this macOS-only project, and `var_os` is the safer choice for path data.
- **TOCTOU between the `exists()` filter and `load_file`, a FIFO/device `JJ_CONFIG` entry, and a non-table `revsets`/`ui` shadowing the builtin layer**: all rejected as exact CLI parity — the CLI has the identical behavior at the pin.
- **"A typo in `BUILTIN_CONFIG_TOML` now degrades silently since `build_aliases_map` lost its `Result`"**: rejected — Story 4.8's retained `every_builtin_revset_alias_expands_and_resolves` asserts all seven builtins expand and resolve, which is exactly that guard.
- **`LogDefaults` missing from the package barrel**: rejected — `packages/zanshin_core/lib/zanshin_core.dart` exports no payload model at all (not `Remote`, `Change`, `GraphSlice`, nor `RepoHandle`), so this matches the established convention.
- **`sprint-status.yaml` still says `backlog`**: rejected on the authority of the run's own guardrail — the orchestrator owns tracking for this run.

## Design Notes

- **Two SPEC statements are wrong about the pinned CLI; implement the CLI.** (a) The SPEC and `jj-config-reference.md` place the repo config at `.jj/repo/config.toml`. At v0.42.0 the CLI resolves it through `jj_lib::secure_config`: `.jj/repo/config-id` (20 hex chars) → `<config_dir>/jj/repos/<id>/config.toml`, treating `.jj/repo/config.toml` only as a LEGACY path it migrates away. Supporting both — id first, legacy fallback — reproduces the observable content in every case, which is why the legacy-file tests in the companion's testing notes still work. (b) The SPEC's layer list omits `ConfigSource::Workspace`, which sits ABOVE `Repo` at the pin and can carry `[revset-aliases]`. Both corrections follow the constraint's own "mirrored at the pin (v0.42.0)" clause and the companion's "for contract questions the tag's sources below win"; the same rule resolved 4.8's wrong `short_prefixes` matrix row. Do not propagate that row either: an INVALID `short_prefixes` expression is a hard error, an UNRESOLVABLE one only warns and degrades (`cli/tests/test_log_command.rs::test_log_bad_short_prefixes`).
- **Why the secure-config indirection is hand-resolved instead of calling `SecureConfig`.** `maybe_load_config` is a *writing* read: it creates directories, writes `metadata.binpb`, can generate a fresh `config-id`, copies configs when it detects a moved/copied repo, and on Unix replaces the legacy file with a symlink — plus it needs a `&mut ChaCha20Rng`. A GUI backend must not rewrite the user's repo layout while drawing a graph. Reading the id and joining the path yields identical config CONTENT with no side effects; the only thing given up is the CLI's migration and its warning text, and Zanshin has no terminal to print it to (it replaces the CLI's UX, NFR-R-2).
- **Why the env layers are omitted, safely.** `ConfigSource::EnvBase` maps only `operation.hostname`, `operation.username`, `ui.color`, `ui.editor`; `EnvOverrides` only `user.*`, `debug.*`, `operation.*`, `ui.editor`, `ui.pager` (`cli/src/config.rs:682-765`). Neither can set `[revset-aliases]`, `revsets.*` or `ui.log-synthetic-elided-nodes`, so their absence is unobservable for this story. `--config`/`--config-file` is excluded by the SPEC.
- **Why the builtin aliases become a TOML layer rather than staying a Rust array.** The CLI has no special path for its builtins — they are simply the lowest config layer, and `load_aliases_map` walks every layer lowest-first (`cli/src/config.rs:930-981`). Overriding therefore works by (name, arity): a user's `trunk()` replaces the builtin `trunk()`, while a user's `trunk(x)` ADDS an overload and leaves `trunk()` alone. Reproducing that requires one insertion path over layered config; a separate hardcoded array plus a config pass would get the arity semantics subtly wrong. Because the same layer also carries `revsets.log` and `ui.log-synthetic-elided-nodes`, CAP-2's "absent overrides return the builtin defaults" falls out of the same mechanism.
- **Why `immutable_expression` needs no change.** Story 4.8 deliberately built the immutable set in code (`parse("immutable_heads()")` → `.union(root())` → `.ancestors()`) rather than from the `immutable()` alias, mirroring `cli/src/cli_util.rs:956-961`. Once the alias map is config-fed, a user override of `immutable_heads()` flows into the ◆ flag with zero extra plumbing — that was the point of the 4.8 decision.
- **Why the alias failure split is warn/continue but the value failure split is hard-error.** `cli/src/config.rs:964-977` warns and continues on a non-string alias value or a bad declaration; `get_bool("ui.log-synthetic-elided-nodes")` (`cli/src/commands/log.rs:197`) and `get_string("revsets.log")` (`:148`) propagate a type error. Getting this backwards changes observable behavior on messy configs. `jj-lib`'s `insert` validates only the declaration ("The `defn` part isn't checked", `dsl_util.rs:594-597`), which is why a malformed DEFINITION surfaces later, at substitution — `revset.rs:190`'s existing test exists precisely because `Ok` from the map proves nothing.
- **Why `config_resolver::resolve` is called with `command: None` and `hostname: ""`.** Skipping `resolve` would leave `[[--scope]]` blocks unflattened (their values silently missing) and would keep layers the CLI drops via a top-level `--when`. The CLI's own first pass runs with `command: None` (`cli/src/cli_util.rs:4404-4441`) and falls back to `""` when `whoami::hostname()` fails, so both values are states the CLI itself produces. Consequence, worth recording: `--when.commands` and `--when.hostnames` scopes never match in Zanshin. Adding a hostname dependency to close the second one is out of scope here.
- **Why the config stack is separate from `Repo`'s `UserSettings`.** `make_settings()` pins Zanshin's commit/operation identity in a `ConfigSource::User` layer. Merging the real user config into it would (a) let a repo's `user.name` silently take over authorship, (b) collide on that very source, and (c) drift from the nine copied `make_test_settings` variants used as independent test oracles. This story's stack is read-only and never becomes `UserSettings`, so `Workspace::load` and every write path are untouched. Known residual: `RevsetParseContext.user_email` still comes from the hardcoded identity, so a jj builtin that keys off the user's email resolves differently than in the CLI — pre-existing, out of this story's scope, record it rather than fix it here.
- **Test isolation is the sharp edge.** Today `JJ_CONFIG=""` is "defence in depth" (`crates/zanshin-jj/tests/repo.rs:15-17`); after this change it is the only thing standing between the suite and the developer's real config. `""` is set, not unset, and set-but-empty is exactly the CLI's documented way to disable user config — so the existing pin keeps the suite hermetic by construction. Repo-layer tests need no env at all (write the legacy file into the extracted fixture), which is why they carry the bulk of the integration coverage; the one test that repoints `JJ_CONFIG` gets its own binary.

## Verification

**Commands:**
- `cargo make codegen` -- expected: `zanshin_ffi.h` + `bindings.dart` carry `zanshin_log_defaults`; `envelope_generated.rs` + `envelope_zanshin.ffi_generated.dart` carry `LogDefaults` and the appended `Payload` member.
- `cargo test -p zanshin-jj`, `cargo test -p zanshin-graph`, `cargo test -p zanshin-ffi` -- expected: green, including the untouched 4.8 alias/immutable regression tests.
- `cargo clippy --workspace --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean, no new `#[allow]`.
- `dart analyze` + `dart format --set-exit-if-changed` in `packages/zanshin_core`; `dart test test/worker/log_defaults_test.dart test/ffi/log_defaults_test.dart` -- expected: clean and green (the sealed-switch arm satisfied).
- `cargo make test` (unpiped, exit code read directly — redirect to a file is fine, `| tail` is not) -- expected: exit 0; `extern-coverage: OK`; `coverage-check: OK`; commit the updated `coverage-baseline.txt`.
- `git status --porcelain` after the commit -- expected: empty.

**Manual checks (if no CLI):**
- The builtin TOML layer is byte-compatible with `git -C ../jj show v0.42.0:cli/src/config/revsets.toml` (`[revset-aliases]` + `log` + `log-graph-prioritize`) and `:cli/src/config/misc.toml` (`ui.log-synthetic-elided-nodes`) — check line by line, as the 4.8 review did for the alias table.
- No production code path calls `SecureConfig` or writes during a config read: `grep -rn 'secure_config' crates/` returns nothing in `src/`.
- `_bmad-output/implementation-artifacts/epic-4-context.md` is the newest file relative to `_bmad-output/planning-artifacts/` after all doc edits.

## Auto Run Result

Status: blocked
Blocking condition: commit signing unavailable — 1Password is locked, so `op-ssh-sign` fails
(`error: 1Password: failed to fill whole buffer`, then `error: 1Password: agent returned an
error` on retry; both end in `fatal: failed to write commit object`). Per this spec's Block If
and the repo's rules, `--no-gpg-sign` was NOT used. **All 36 files are staged and the quality
gate is green** — unlock 1Password and re-run the commit; nothing else is outstanding. The
implementation, the review pass and all 10 patches are complete and verified below; only the
signed commit remains.

Prepared commit message:

```
feat(zanshin-jj): honor jj config revset aliases (Story 4.9)

Rebuild the jj CLI's effective config stack per operation inside zanshin-jj
(the sole jj_lib importer): builtin defaults < user (JJ_CONFIG or platform
discovery) < repo < workspace, flattened through jj_lib::config::resolve.
Story 4.8's builtin [revset-aliases] table becomes that default LAYER, so
builtins and user aliases enter the RevsetAliasesMap through the one path
the CLI uses and override by (name, arity). Both parse sites feed from it,
so the graph slice, prioritize, short_prefixes, plain revset resolution and
the per-row immutable flag all follow the user's config.

Expose the effective log defaults per repo handle (CAP-2): Repo::log_defaults
behind a new zanshin_log_defaults extern fn and a LogDefaults payload appended
to the Payload union, reaching Dart as RepoHandle.logDefaults(). graphSlice's
Dart defaults stay compile-time constants (FR-JJ-17).

Two SPEC statements are corrected against the pin, per its own "mirrored at
the pin (v0.42.0)" clause: repo config is reached through the config-id
indirection (resolved read-only, never via SecureConfig, which writes), and
ConfigSource::Workspace sits above Repo and is layered too.

Config is re-read per operation and never cached. Adds jj.config_error.

FR-JJ-16, FR-JJ-17, NFR-R-2, ADR-0003
```

### Summary of implemented change

`zanshin-jj` now rebuilds, **per operation**, the layered jj config the CLI would have at
v0.42.0 for the workspace — Zanshin's builtin defaults (`ConfigSource::Default`) < user
(`JJ_CONFIG` or platform discovery) < repo < workspace — and flattens `--when` / `[[--scope]]`
through `jj_lib::config::resolve`. Story 4.8's `BUILTIN_ALIASES` Rust array is gone: the CLI's
`[revsets] log` / `log-graph-prioritize`, `ui.log-synthetic-elided-nodes` and the seven-entry
`[revset-aliases]` table are now that builtin **layer**, so builtins and user aliases enter the
`RevsetAliasesMap` through the one path the CLI uses (all layers, lowest first), giving correct
(name, arity) override semantics. Both parse sites — `revset::parse_revset` and
`graph::walk_graph` — feed from it, so the graph slice, `prioritize`, `short_prefixes`, plain
revset resolution and the per-row `immutable` flag all follow the user's config; `zanshin-graph`
and `zanshin-ffi` inherit it without changes to their own logic. CAP-2 ships as
`Repo::log_defaults()` behind a new `zanshin_log_defaults` extern fn and a `LogDefaults` payload
appended to the `Payload` union, reaching Dart as `RepoHandle.logDefaults()`; `graphSlice`'s Dart
defaults stay compile-time constants (FR-JJ-17). Config is never cached and the loader never
writes to disk.

### Files changed (since `a5d20bb`; 36 files, +3310 −69)

**zanshin-jj**
- `src/config.rs` (NEW, ~640 lines) — the layer stack, `BUILTIN_CONFIG_TOML`, `resolve`, the read-only `config-id` indirection, `ConfigError`, `LogDefaults`, and pure path-selection helpers with inline unit tests.
- `src/revset.rs` — `BUILTIN_ALIASES` retired; `build_aliases_map(&StackedConfig)` walks layers lowest-first with the CLI's error/warn split; `RevsetError::Config`.
- `src/graph.rs`, `src/repo.rs`, `src/lib.rs`, `README.md` — config loaded once per `walk_graph`, `Repo::log_defaults`, re-exports, reconciled rustdoc.
- `tests/config.rs` (NEW), `tests/config_user_layer.rs` (NEW, one `#[test]` because `JJ_CONFIG` is process-global), `tests/revset.rs`, `tests/graph.rs`, `tests/api_stability.rs`.

**zanshin-ffi + wire**
- `schemas/envelope.fbs` — `LogDefaults` table, appended to `union Payload` (discriminant 12; existing ones unchanged).
- `src/log_defaults.rs` (NEW) — `zanshin_log_defaults`, builder, `map_config_err`.
- `src/envelope.rs` (`JJ_CONFIG_ERROR`), `src/graph.rs` (new `map_lane_stream_err` arm), `src/lib.rs`.
- `tests/log_defaults_ffi.rs` (NEW), `tests/graph_ffi.rs`.
- `include/zanshin_ffi.h`, `src/envelope_generated.rs` — regenerated by `cargo make codegen`.

**Dart bridge (`packages/zanshin_core`)**
- `lib/src/ffi/log_defaults.dart` (NEW) — adapter, model, decoder.
- `lib/src/worker/{commands,isolate,handle}.dart` — `LogDefaultsCommand`, dispatch arm, `ZanshinWorker.logDefaults`, `RepoHandle.logDefaults()`.
- `lib/src/ffi/graph.dart` — the four `default*` consts kept, docs point at `logDefaults()`.
- `lib/src/ffi/{bindings.dart,envelope_zanshin.ffi_generated.dart}` — regenerated.
- `test/worker/log_defaults_test.dart` (NEW), `test/ffi/log_defaults_test.dart` (NEW), `test/worker/events_test.dart` (out-of-story de-flake — see `deferred`).

**Docs / planning / baseline**
- `docs/rust-error-codes.md` (`jj.config_error`), `docs/ffi-abi.md` (LogDefaults section + graph-section note).
- `_bmad-output/planning-artifacts/epics.md` (Story 4.9), `_bmad-output/implementation-artifacts/epic-4-context.md` (edited LAST; 04:47 vs `epics.md` — cache valid).
- `coverage-baseline.txt` — raised in place.

### Review findings breakdown

Four review layers ran (blind hunter, edge-case hunter, verification-gap, intent-alignment).

- **intent_gap: 0.** The two places where the SPEC's prose and the pinned CLI disagree (repo config location, missing workspace layer) are resolved to a single reading by the constraint's own "mirrored at the pin (v0.42.0)" clause and the companion's "for contract questions the tag's sources below win".
- **bad_spec: 0.** No finding required re-deriving the code.
- **patches applied: 10** — high 0, medium 4, low 6 (listed in the triage log).
- **items deferred: 3** — the `events_test.dart` settle, invisible alias warnings, and the `user_email` residual (frontmatter `deferred`).
- **items rejected: 18**, all low. The substantive ones were rejected only after checking the pinned oracle — canonicalized-`$HOME` config dir, non-UTF-8 `JJ_CONFIG`, the `exists()`/`load` TOCTOU, FIFO entries, and non-table `revsets`/`ui` shadowing are all either CLI-identical or unreachable.

The single most important finding was flagged independently by three of the four layers: a
non-table `revset-aliases` warned-and-skipped instead of hard-erroring. That was verified
directly against `git -C ../jj show v0.42.0:cli/src/config.rs` (lines 943-953 vs 964-977) and
fixed, together with the test that had pinned the wrong behavior and the three doc sites that
cited the per-entry line range as authority for the table-level case.

### Follow-up review recommendation

`followup_review_recommended: true`.
Patched counts this pass: high 0, medium 4, low 6. No high-severity patch, so the score decides:
`3 × 4 + 1 × 6 = 18`, which is >= 5. Recommendation: **true**.

### Verification performed

- `cargo make test`, run **unpiped** with the exit code read directly (output redirected to a
  file, never piped, so `$?` is the task's own status) — **exit 0**, twice: once on the
  implementation tree and again after the 10 patches.
  - Final run: `coverage-check: OK — coverage held at 99.04% (4311/4353 lines).`
  - `extern-coverage: OK — every zanshin-ffi extern "C" fn is covered (allow: zanshin_buffer_free).`
  - 984 Rust tests pass; the Dart suite reports `All tests passed!`. No baseline value lowered,
    no `exclude_prefix` added, no name added to `EXTERN_COV_ALLOW`.
- **Matrix test audit:** all 24 I/O-matrix rows map to at least one test, and every covering test
  was confirmed present in the run output — including `tests/config.rs` (9 → 11 tests),
  `tests/config_user_layer.rs`, `tests/log_defaults_ffi.rs`, and both Dart `log_defaults` files.
- **Independent check of the out-of-story test change:** HEAD's version of
  `events_test.dart` was restored into the worktree and run three times in isolation — it passed
  3/3, confirming the race only manifests under full-suite load and that the story's own new Dart
  test files surfaced a pre-existing defect rather than introducing one.
- Manual: the builtin `[revset-aliases]` block was diffed line-by-line against
  `git -C ../jj show v0.42.0:cli/src/config/revsets.toml` — identical, comments included; the two
  `[revsets]` values and `ui.log-synthetic-elided-nodes` likewise.
- Manual: `grep -rn 'jj_lib::secure_config\|SecureConfig::' crates` returns only doc comments —
  the writing entry points are never called.
- Manual: `epic-4-context.md` is newer than every file in `_bmad-output/planning-artifacts/`.
- `app/analysis_options.yaml` gate churn reverted after each gate run, never committed.

### Residual risks

- **The `config-id` path is unit-proven, not integration-proven.** `add_secure_layer` is now shown
  to load a real file from a real `<root>/<id>/config.toml`, but no end-to-end test drives it
  through `Repo::log_defaults`, because that needs `$XDG_CONFIG_HOME` control and the suite pins
  process-global env deliberately. Every integration row still injects via the legacy files.
- **`--when.commands` and `--when.hostnames` scopes never match**, because `resolve` runs with
  `command: None` and `hostname: ""`. Both are states the CLI itself produces (its own first pass
  has `command: None`), but a user scoping config by hostname gets builtin behavior in Zanshin.
- **A repo the CLI has moved or copied can diverge.** `handle_metadata_path` re-points or copies
  the config on move/copy detection; the read-only resolver deliberately does not, so after such a
  move the two can read different files until the CLI runs again.
- **Config is re-read on every operation by design**, which costs a `$HOME` canonicalization and a
  process-environment snapshot per `walk_graph` / `resolve_revset`. Negligible beside the
  `load_at_head` index load it accompanies, but it is per-call work that did not exist before.
- **One out-of-story file is in the commit** (`events_test.dart`) — required to keep the gate
  green, recorded under `deferred` with its reproduction.
