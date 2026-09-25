---
title: 'Story 9.37: Secure-config fix-ups at every command start — `SecureConfig::maybe_load_config` parity (legacy `.jj/repo/config.toml` migration, moved/copied repos)'
type: 'feature'
created: '2026-09-25'
status: 'done'
baseline_revision: '2d640244f117bdc7bed8dd116f4bf88dd4a9d2b6'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** At the start of every command the jj CLI (v0.44.0) runs `SecureConfig::maybe_load_config` for the repo and the workspace layer (`cli/src/config.rs:447-469, 585-593, 653-665`, called from `cli_util.rs:4545-4549` / `:4592-4595`): it migrates a legacy `.jj/repo/config.toml` / `.jj/workspace-config.toml` into `<config_dir>/jj/{repos,workspaces}/<id>/`, re-points a MOVED repo's metadata, forks a COPIED repo's config, regenerates a missing config directory, and prints each resulting message as a `Warning:`. Zanshin's read path never writes (`config.rs` module doc "Reading never writes"), so these on-disk effects — required parity — never happen until a CLI run or a Zanshin config write.

**Approach:** Run jj-lib's own `maybe_load_config` for both secure layers, in the CLI's start-up order, wherever Zanshin plays a CLI command's start-up: `Repo::open`, the settings refresh every precondition-running verb starts with, and the handle-less `config_*` verbs that take a workspace root. Each jj-lib message becomes a 9.32 warning with its own code, carried on success AND on failure.

## Boundaries & Constraints

**Always:**
- **One primitive.** `SecureLayer::fix_up` (in `crates/zanshin-jj/src/config.rs`) calls `(self.new_secure)(dir).maybe_load_config(rng, root)` — never a re-implementation. No `<config_dir>` known (`root_config_dir` None) → nothing runs, as the CLI's `load_secure_config` returns `None`. BEFORE the call it resolves the layer side-effect-free (`resolved_path()`), so a malformed id file keeps today's path-named `invalid config ID` refusal and writes nothing. Any other `SecureConfigError` → `ConfigError::Load { reason: "Failed to determine the secure config for a repo: <describe(err)>" }` (the CLI's `command_error.rs:754-758` message) → `jj.config_error`.
- **Warning kinds from STATE, never from text** (`Warning.message` is never parsed): read the layer's id file before the call; for each returned message — no id file before → `WarningKind::ConfigMigrated`; id afterwards differs (the new `config_file`'s parent directory name) → `ConfigCopied`; same id → `ConfigRegenerated`. `message` = jj-lib's string verbatim. Codes: `jj.config_migrated`, `jj.config_copied`, `jj.config_regenerated`.
- **RNG.** One `ChaCha20Rng` per fix-up pass, shared by both layers (repo draws first, as the CLI's single `ConfigEnv.rng`), seeded exactly as `SecureLayer::create_path` seeds it (`JJ_RANDOMNESS_SEED`, else `getrandom`, never a panic) — extract that seeding into one helper both use.
- **CLI start-up order.** System and user layers load first (a broken one refuses before ANY fix-up); then repo fix-up → repo file load → workspace fix-up → workspace file load (a broken repo file refuses after the repo fix-up, before the workspace fix-up). Implement by giving `load_raw`'s secure-layer loop an optional fix-up sink (every existing caller passes none) plus `config::fix_up_secure_config(env, paths, &mut Vec<Warning>) -> Result<(), ConfigError>` = `load_raw` with the sink, stack dropped. Warnings recorded before a failure stay in the sink.
- **Call points.**
  - `Repo::load_effective`: the pass runs right after the loader resolves the paths, BEFORE the fingerprint (the stored fingerprint is post-fix-up → no redundant reload).
  - `Repo::refresh_settings`: the pass runs on EVERY call, before the fingerprint comparison (a deleted `metadata.binpb` changes no stamped file); reload only on a changed fingerprint — the reload's own pass is then a no-op. Its warnings go to a caller-owned sink (the reload replaces `*self`).
  - `Repo::precondition`: resets the collector, then puts the refresh's fix-up warnings FIRST — also when the refresh fails.
  - `config_cmd.rs`: `list`/`get`/`path`/`set`/`unset` run the pass inside `startup`'s `load_raw` (one load); the editor halves (`config_file_read`/`_write`, which deliberately load no stack) run `SecureLayer::fix_up` for both layers without loading any file, right after `resolve_workspace`. `workspace_root = None` and `config_gc_*` run nothing.
- **Open API.** New `pub fn Repo::open_with_report(path: &Path) -> CreationOutcome` (`precondition: None`; `warnings` = the fix-up's, on success AND failure); `Repo::open` keeps its signature and returns `open_with_report(path).result` (warnings dropped — documented). `CreationOutcome`'s doc names open too.
- **Config API.** New `pub struct ConfigOutcome<T> { pub result: Result<T, ConfigCmdError>, pub warnings: Vec<Warning> }` (`Debug`, re-exported in `lib.rs`). `config_list` (was `Result<Warned<Vec<ConfigEntry>>, _>`), `config_get`, `config_path`, `config_unset`, `config_file_read`, `config_file_write` return it; `config_list`'s `jj.config_nothing_listed` follows the fix-up's. `ConfigSetOutcome.warnings` = fix-up's, then the identity snapshot's, then the author note. `config_gc_*` unchanged.
- **FFI.** `zanshin_repo_open` answers through `creation_envelope(Repo::open_with_report(..))` (ok, refusal and `watcher.io_error` all carry the warnings). The six config wrappers stamp `outcome.warnings` on the ok envelope and via `with_report` on the error envelope. New `JJ_CONFIG_MIGRATED`/`JJ_CONFIG_COPIED`/`JJ_CONFIG_REGENERATED` + `warning_code` arms + literal-table rows. No `.fbs`, codegen or extern-fn change (`Envelope.warnings` exists on every envelope).
- **Dart.** `ZanshinWarningCode.configMigrated`/`configCopied`/`configRegenerated` (`values` 25 → 28). `ZanshinWorker.openRepo` returns `Future<OpenedRepoHandle>` — new `final class OpenedRepoHandle extends RepoHandle` in `handle.dart` with `final List<ZanshinWarning> warnings`, decoded from the `HandleResult` bytes with the existing creation-report decoder. Config result types already carry `warnings` — unchanged.

**Never:**
- No fix-up in creation paths (`init`, `clone`, `convert_*`, `check_startup_stack`, `user_settings_for_new_workspace`: the new workspace has no `.jj/` yet, so the CLI's `settings_for_new_workspace` call is a no-op), in `config_gc_*`, in the `&self` accessors outside the precondition (`workspace_root`, `resolve_workspace_root`, `log_defaults`), or in the read helpers (`config::load`, `load_for_workspace`, `stack_fingerprint`).
- No parsing of jj-lib's message text; no `jj_lib::config::migrate` port (`default_config_migrations()` is `vec![]` at v0.44.0 — say so in the module doc, re-check at pin bumps); no `config gc` change; keep `SecureLayer::records_another_dir` (still guards a copy jj-lib could not fork, e.g. a read-only one).
- No `.fbs`/codegen/new extern fn; no Flutter UI change; never lower `coverage-baseline.txt` or add an `exclude_prefix`.

## I/O & Edge-Case Matrix

Rust rows use a tempdir `XDG_CONFIG_HOME` (`<xdg>`); `<id>` = 20 hex chars. "Legacy repo" = a Zanshin `Repo::init` workspace (it writes no `config-id`) plus a hand-written `.jj/repo/config.toml` = `[test]\nmarker = "legacy"\n`.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Migrate on open | legacy repo | `open_with_report` ok; warnings = [`ConfigMigrated`, `Your config file has been migrated from <root>/.jj/repo/config.toml to <xdg>/jj/repos/<id>/config.toml. You can edit the new file with \`jj config edit\``]; `.jj/repo/config-id` = `<id>`; new file = legacy bytes; `.jj/repo/config.toml` is a symlink to it; `config_list(Repo scope)` lists `test.marker` with the new path | — |
| No second run | the handle above, then `status()` | `take_warnings()` has no fix-up warning; `config-id` and the new file unchanged; no workspace reload (stored fingerprint == a fresh one — witnessed inline in `repo.rs`) | — |
| Both layers | legacy repo + `.jj/workspace-config.toml` | two `ConfigMigrated`, repo first, then workspace (`<xdg>/jj/workspaces/<id2>/`) | — |
| Copied repo | repo A with a secure config (content C); `cp -R` A → B; open B | [`ConfigCopied`, `Your repo appears to have been copied from <A>/.jj/repo to <B>/.jj/repo. The corresponding repo config file has also been copied.`]; B's id ≠ A's; B's file = C; A's id + file untouched; a second open of B warns nothing | — |
| Moved repo | A with a secure config; rename A → C; open C | no warning; `<xdg>/jj/repos/<id>/metadata.binpb` records `C/.jj/repo`; id unchanged | — |
| Regenerated at verb start | open handle on A; delete `<xdg>/jj/repos/<id>/`; `status()` | first warning `ConfigRegenerated` with jj-lib's `CONFIG_NOT_FOUND` text (3 lines) verbatim; `metadata.binpb` exists again; the next verb warns nothing | — |
| Failure keeps warning (config) | legacy repo; `config_get(Some(root), "no.such")` | `result` = `Err(NotFound)`, `warnings` = [`ConfigMigrated`]; migrated on disk | — |
| Failure keeps warning (open) | legacy repo whose legacy file is `not toml [` | `open_with_report`: `Err(RepoError::Config)` naming the NEW secure file; warnings = [`ConfigMigrated`]; `Repo::open` → the same `Err` | — |
| Broken user layer first | explicit `ConfigEnv` whose user file is invalid TOML; legacy repo | `fix_up_secure_config` → `Err`; no `config-id`, legacy file still a regular file; no warnings | refuse |
| Broken repo file stops workspace | legacy repo file invalid TOML + legacy workspace file | `Err`; repo migrated (one `ConfigMigrated`), workspace NOT migrated | refuse |
| Malformed id | `.jj/repo/config-id` = `xyz` | today's path-named `invalid config ID` `ConfigError`; nothing created under `<xdg>/jj` | refuse |
| No config dir | explicit `ConfigEnv` with no `HOME`/`XDG_CONFIG_HOME` | nothing written, no warnings | — |
| Editor half, broken user file | legacy repo; `JJ_CONFIG` → invalid TOML; `config_file_read(Some(root), Repo, None)` | ok; warnings = [`ConfigMigrated`]; returns the new file with the legacy text | — |
| FFI | legacy repos; `zanshin_repo_open`; `zanshin_config_get` of `no.such` | ok `RepoHandle` envelope with warnings [`jj.config_migrated`]; error envelope `jj.config_not_found` with warnings [`jj.config_migrated`] | — |
| Dart, real cdylib | legacy repos; `openRepo`; `configGet(root, 'no.such')` | `OpenedRepoHandle.warnings` = one `configMigrated` (message starts `Your config file has been migrated from `); `ZanshinFfiException` `jj.config_not_found` whose `warnings` = one `configMigrated` | — |

</intent-contract>

## Code Map

**jj-lib / CLI evidence (read-only, v0.44.0):**
- `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.44.0/src/secure_config.rs` -- `CONFIG_NOT_FOUND` :48-50; `handle_metadata_path` :217-286 (moved = metadata re-point, no warning; copied = `NamedTempFile` probe in the new repo dir, new id + copied content + warning); `maybe_migrate_legacy_config` :321-355 (new id, content copied, legacy replaced by a symlink on Unix, warning; TODO: jj 0.49 stops auto-migrating — re-check at the pin bump); `maybe_load_config` :359-403 (id present + metadata missing → regenerate with the SAME id + `CONFIG_NOT_FOUND`); `load_config` :407-421. Each call yields at most one message.
- `../jj/cli/src/config.rs` @ v0.44.0 -- `load_secure_config` :447-469 (`root_config_dir` None → `None`; each warning via `ui.warning_default()`), `reload_repo_config` :585-593, `reload_workspace_config` :653-665; `default_config_migrations()` :879-881 = `vec![]`. `cli_util.rs` :4543-4550 / :4592-4595 (system → user → repo fix-up+load → workspace fix-up+load), `settings_for_new_workspace` :372-388; `command_error.rs:754-758`.

**zanshin-jj:**
- `crates/zanshin-jj/src/config.rs` -- module doc :20-86 ("Reading never writes", "WHY: by hand for READS", the `handle_metadata_path` "documented exception") → rewrite for 9.37: reads stay side-effect-free EXCEPT the start-up fix-up at the named call points; `:106-111` add the empty-`default_config_migrations` note. `SecureLayer` :613-714 (add `fix_up`; share the RNG seeding of `create_path` :699-713; keep `records_another_dir` :668-681), `secure_config_path` :396-429 (the malformed-id refusal reused), `secure_layers` :716-732, `load_raw` :746-778 (fix-up sink in the secure loop), `user_settings_for` :827-843, `fingerprint_with`/`stack_fingerprint` :986-1026 (unchanged; stamps id file + resolved path only), `write_error`/`describe` :1228-1240 (error rendering). Inline `tests` module: unit rows (order, malformed id, no config dir, kind classification incl. moved).
- `crates/zanshin-jj/src/warning.rs:24-85` -- three `WarningKind` variants (rustdoc cites `secure_config.rs` sites + `cli/src/config.rs:462-464`); build with `local` :157-164.
- `crates/zanshin-jj/src/repo.rs` -- `CreationOutcome` doc :91-106; `load_effective` :174-204 (fix-up after the loader, before the fingerprint; warnings sink param); `refresh_settings` :220-228 (fix-up every call; sink); `precondition` :263-305 (reset, then fix-up warnings first) and its doc steps; `take_warnings` doc :357-372 (print order starts with the fix-up); `open` :1823-1850 → delegate to new `open_with_report`; inline refresh tests ~:2240-2280 (add the no-redundant-reload witness).
- `crates/zanshin-jj/src/config_cmd.rs` -- module doc :1-37; pub verbs :303-443 → `ConfigOutcome`; `resolve_workspace` :462-475; `startup` :477-482 (sink into `load_raw`); `list_with`/`get_with`/… (suggested: keep `Result<T, _>` and take a `&mut Vec<Warning>` sink, the pub fn builds the outcome); `writable_files` :~905 keeps its `records_another_dir` filter.
- `crates/zanshin-jj/src/lib.rs:64,76,81` -- re-export `ConfigOutcome`.
- Call-site churn (`.result` / `.warnings`): `tests/config_cmd.rs`, `config_cmd_user.rs`, `convert.rs`, `git_remotes.rs`, `login_shell_environment.rs`, inline tests of `config.rs`/`config_cmd.rs`.
- `crates/zanshin-jj/tests/api_stability.rs` -- :993-1007 config pins → new return types + a `ConfigOutcome` construction pin; :1079-1120 exhaustive `WarningKind` (24 → 27); pin `Repo::open_with_report as fn(&Path) -> CreationOutcome` next to :1163-1173.
- Test idioms: `tests/config_cmd.rs:28-59` (`ENV_GUARD` LazyLock with leaked `<xdg>`, `workspace()`), `:301-312` `copy_tree`, `:314-345` copied-repo test (must stay green).

**zanshin-ffi:**
- `crates/zanshin-ffi/src/repo.rs:513-568` -- `creation_envelope`; `zanshin_repo_open` body + rustdoc ("warns about nothing … start-up-environment port" → the fix-up warnings).
- `crates/zanshin-ffi/src/config.rs` -- module doc :~15; `*_to_envelope` helpers :~297-430 (get/path/unset/file_text build `CallReport::default()` → take a report; `file_write`'s `ok_empty()` → a payload-less ok WITH warnings, `finish_envelope(.., fbs::Payload::NONE, None, &report)`); wrappers :483-692 (rustdoc: "Writes nothing" → "nothing but the CLI's start-up secure-config fix-up"; warnings on ok + error).
- `crates/zanshin-ffi/src/envelope.rs` -- warning consts :194-247, `warning_code` :252-280, literal-table test :1022.
- Tests: `crates/zanshin-ffi/tests/config_ffi.rs:30-62` (env guard + call helper to copy); `tests/environment_ffi.rs` (config_get call churn).

**Dart (`packages/zanshin_core`):**
- `lib/src/ffi/warning.dart:42-152` -- three constants + `values`.
- `lib/src/worker/handle.dart:~990-1015` -- `OpenedRepoHandle` next to `CreatedRepoHandle`.
- `lib/src/worker/isolate.dart` -- class doc :65-78, `openRepo` :357-367, `_handleOrThrow` :412-415, `_createdOrThrow` :417-428 (decoder reuse); dispatch `OpenRepoCommand` :1696 already sends `HandleResult(id, bytes)` (:2330) — verify.
- `test/ffi/warning_test.dart` -- pinned `values` (28); `test/worker/config_test.dart:31-50` (worker setUp + XDG guard template).

**Docs & bookkeeping:**
- `docs/ffi-abi.md` -- :72-98 (`openRepo`/`zanshin_repo_open` "carries none" → carries the fix-up's; print order starts with the fix-up), :431 symbol row, :~1131 (Story 9.27 stack note), config wrappers' rows (warnings + fix-up side effect).
- `docs/rust-error-codes.md` § Warning Codes :84-135 -- three rows (CLI site `cli/src/config.rs:462-464` → jj-lib `secure_config.rs`; Zanshin site: open, every precondition verb, root-taking `config_*`).
- `_bmad-output/implementation-artifacts/deferred-work.md:377` → RESOLVED 2026-09-25 (Story 9.37); `sprint-status.yaml:136` → `done` + summary, `last_updated`.

## Tasks & Acceptance

**Execution:**
- [x] `crates/zanshin-jj/src/warning.rs` -- `ConfigMigrated`, `ConfigCopied`, `ConfigRegenerated` -- one code per remedy.
- [x] `crates/zanshin-jj/src/config.rs` -- shared RNG seeding helper; `SecureLayer::fix_up` (resolved-path pre-check, id read, `maybe_load_config`, state-based kinds, error mapping); `load_raw` fix-up sink; `fix_up_secure_config`; module doc rewrite; inline tests for the Broken-user, Broken-repo-file, Malformed-id, No-config-dir rows plus migrated/copied/regenerated/moved classification on explicit envs -- the mechanism, covered without process env.
- [x] `crates/zanshin-jj/src/repo.rs` -- sinks in `load_effective`/`refresh_settings`, `precondition` ordering, `open_with_report`, `open` delegation, docs; inline test: after a fix-up (open and verb start) the stored fingerprint equals a fresh one and the following refresh reloads nothing -- no reload loop.
- [x] `crates/zanshin-jj/src/config_cmd.rs`, `lib.rs` -- `ConfigOutcome`, fix-up at the named verbs, `config_set` order, docs -- handle-less parity.
- [x] `crates/zanshin-jj/tests/secure_config_fixups.rs` (new; `ENV_GUARD` idiom) -- matrix rows Migrate-on-open, No-second-run, Both-layers, Copied, Moved, Regenerated, both Failure rows, Editor-half (its own `JJ_CONFIG` → put this row in a SEPARATE one-`#[test]` binary `tests/secure_config_fixups_user.rs` if the guard's `JJ_CONFIG` must differ) -- public-API end to end.
- [x] `crates/zanshin-jj/tests/{api_stability,config_cmd,config_cmd_user,convert,git_remotes,login_shell_environment}.rs` + inline tests -- new shapes and pins.
- [x] `crates/zanshin-ffi/src/{repo,config,envelope}.rs` -- open via `creation_envelope`, warnings on ok + error for the six wrappers, three codes, rustdoc.
- [x] `crates/zanshin-ffi/tests/secure_config_ffi.rs` (new) + `tests/environment_ffi.rs` -- the FFI row -- wire contract.
- [x] `packages/zanshin_core/lib/src/{ffi/warning.dart,worker/handle.dart,worker/isolate.dart}` -- codes, `OpenedRepoHandle`, `openRepo` -- the bridge surfaces open's warnings.
- [x] `packages/zanshin_core/test/worker/secure_config_test.dart` (new) + `test/ffi/warning_test.dart` -- the Dart row; values 28.
- [x] `docs/ffi-abi.md`, `docs/rust-error-codes.md`, `deferred-work.md`, `sprint-status.yaml`, `coverage-baseline.txt` -- per the Code Map; commit an auto-raised baseline.

**Acceptance Criteria:**
- Given the finished change, when `crates/` is searched for `maybe_load_config(`, then the only production call is `SecureLayer::fix_up` in `config.rs`.
- Given the finished change, when `config.rs`'s module doc and `zanshin_repo_open`'s rustdoc are read, then neither claims that reading never writes / that Zanshin never performs the moved/copied fix-up / that open warns about nothing; each names Story 9.37's call points.
- Given the finished change, when `cargo make test` runs, then it is green (a `test-flutter` failure only if shown pre-existing at the baseline revision), incl. clippy pedantic, the extern-fn guard and the coverage ratchet (new files ≥ 80%).

## Spec Change Log

## Review Triage Log

### 2026-09-25 — Review pass
- verdicts: 30 findings — high 0, medium 6, low 21, false 3, maybe-false 0 (layers: blind-hunter 13, edge-case-hunter 5, verification-gap 4, intent-alignment 8)
- findings:
  - `[low]` `[reject]` (blind) The fix-up also runs in the creation paths (`init`/`clone`/`convert_*` end in `Repo::open`), contrary to the spec's "Never" wording; warnings dropped, an extra stack parse, and a fix-up failure there would skip the conversion rollback — real (the re-open runs the pass), but on a freshly created `.jj/` there is no id and no legacy file, so jj-lib writes nothing and returns no message; a fix-up failure there is unreachable (and a failed re-open leaving `.jj/` is the documented pre-9.37 behaviour). Avoiding it needs a second, fix-up-free open path. Recorded in deferred-work.md (Story 9.37 section).
  - `[low]` `[reject]` (blind) The `edit` halves migrate under a broken user file, where every CLI command refuses before any fix-up — real, but a deliberate intent-contract decision (the halves run the fix-up alone because they load no stack, the 9.28 repair path); changing it edits this build's spec. Recorded in deferred-work.md.
  - `[low]` `[patch]` (blind) Stale cost claim in `refresh_settings`' rustdoc ("a few `stat`s per verb") plus more parsing per verb, the pass run thrice by `config set user.name`, and an eagerly seeded RNG — the doc really is stale → patched (cost sentence corrected); the extra parses are sub-millisecond TOML loads and an OS-RNG failure on macOS is not a realistic path, so those parts are not acted on.
  - `[low]` `[reject]` (blind) The fix-up's RNG and `create_path`'s are seeded separately, so under `JJ_RANDOMNESS_SEED` ids diverge from the CLI's one-RNG-per-command — real only with the reproducibility knob no user sets; sharing one RNG means threading it through `select_file`/`secure_create` callers (new parameters). Recorded in deferred-work.md.
  - `[medium]` `[patch]` (blind) Ordering promises untested: fix-up warnings first when the refresh fails, `config_list` → [migrated, nothing_listed], `config_set` → fix-up first / author note last, workspace-layer copied/regenerated — patched with jj-level rows (verb-failure row, list order, set order); the workspace-layer copy/regenerate case is the same layer-agnostic `SecureLayer::fix_up` code already pinned on the repo layer, so not added.
  - `[medium]` `[patch]` (blind) FFI/Dart witnesses cover only `config_get`'s error envelope; no ok envelope of the config wrappers (incl. the new payload-less `file_written_to_envelope`) is shown carrying a notice — patched with the FFI success-envelope table (grouped with the verification-gap entry below). A refused Dart `openRepo` needs no own witness: the error warnings go through 9.35's shared decoder, and the Rust FFI refusal row pins the envelope.
  - `[low]` `[patch]` (blind) `snapshot_test.dart:104` and `file_ops_test.dart:79,121` write legacy repo configs that the next verb now migrates, without the `XDG_CONFIG_HOME` guard, so a run outside `cargo make` pollutes the developer's real `~/.config/jj` — verified (no `setUpAll` guard in either file) → patched with config_test.dart's guard.
  - `[low]` `[patch]` (blind) `leaked_xdg_config_home` dirs pile up (`TempDir::keep()` never deletes) and its doc says "for the process lifetime" — the doc is wrong → patched ("kept on disk, never deleted"); the accumulation under `$TMPDIR` itself needs per-run cleanup logic → recorded in deferred-work.md.
  - `[low]` `[patch]` (blind) Dart `ConfigSetResult.warnings` doc omits the fix-up's leading notices; the worker's config section does not say a `workspaceRoot` runs the fix-up; `ffi-abi.md`'s `log_defaults` paragraph claims "the files read here are the fixed-up ones" — all three verified → patched.
  - `[low]` `[patch]` (blind) No trace of the one-shot notice where `Repo::open` drops it; `OpenedRepoHandle` not exported — `Repo::open` bypassed the crate's `warning::log_dropped` convention (verified: `revset.rs:100` is its precedent) → patched; the barrel omission follows the pre-existing pattern (`RepoHandle`/`CreatedRepoHandle` are not exported either) and the UI is out of scope, so not acted on.
  - `[low]` `[patch]` (blind) The known residual divergences are recorded nowhere in deferred-work.md → patched with a dated "Surfaced 2026-09-25 while implementing Story 9.37" section.
  - `[low]` `[patch]` (blind) `writable_files`' doc still justifies its filters by fix-ups "the CLI would" perform, though `file_write_with` now runs that fix-up first → patched (the filters now only matter for a layer the fix-up could not fix, e.g. a read-only copy).
  - `[low]` `[patch]` (blind) `Repo::open`'s new doc sentence "Use it wherever they can reach a user" reads as advice to use `Repo::open` → patched (names `open_with_report`).
  - `[low]` `[reject]` (edge) Under `JJ_RANDOMNESS_SEED` a copy's fork can draw its original's id and is then classified `ConfigRegenerated` — real only with the seed knob; the state-based rule is fixed in the intent-contract, so the fix edits this build's spec. Recorded in deferred-work.md.
  - `[low]` `[reject]` (edge) `create_path` reseeds after the fix-up drew — same root cause as the blind split-RNG finding; rejected there.
  - `[low]` `[patch]` (edge) `Repo::open` drops the notice with no trace, bypassing `log_dropped` — same root cause as the blind tracing finding; patched there.
  - `[low]` `[reject]` (edge) An `edit` half migrates the workspace layer after a broken repo file, where the CLI would refuse between the layers — same root cause as the blind editor-half finding; rejected there.
  - `[low]` `[patch]` (edge) Kept temp dirs pile up; "process lifetime" doc wrong — same root cause as the blind temp-dir finding; patched there.
  - `[medium]` `[patch]` (verification-gap) A failed settings refresh keeps the fix-up's warnings, but no test checks it — pre-verified; patched with a "verb refuses after its own migration" row asserting `take_warnings()` == [ConfigMigrated].
  - `[medium]` `[patch]` (verification-gap) Nothing checks that the fix-up runs on every verb with an UNCHANGED fingerprint — pre-verified; patched with a regenerate row whose secure dir holds no `config.toml`.
  - `[medium]` `[patch]` (verification-gap) Five of six root-taking config verbs and every FFI success envelope lack a fix-up witness — pre-verified; patched with the FFI table (list/get/path/set/unset/file_read migrate, file_write regenerates) plus a handle-verb row.
  - `[low]` `[patch]` (verification-gap, other) Dart `ConfigSetResult.warnings` doc order stale — same root cause as the blind Dart-docs finding; patched there.
  - `[low]` `[reject]` (intent) R1 ("every command" literally) vs the diff: `log_defaults` / `resolve_workspace_root` / `workspace_root` run no fix-up — the story's own Scope names exactly the three call points (open, the per-verb refresh, the root-taking config verbs), so the intent excludes the accessors; the narrow window (an external change between the last verb and an accessor call) is recorded in deferred-work.md.
  - `[low]` `[reject]` (intent) The creation paths run the fix-up through their final re-open — same root cause as the blind creation-path finding; rejected there.
  - `[low]` `[patch]` (intent) No FFI/Dart test shows a fix-up warning on a handle-scoped verb's envelope — patched with the handle-verb FFI row (the envelope's warnings come from the generic `take_warnings()` path, pinned since 9.32).
  - `[medium]` `[patch]` (intent) Config verbs: six changed, fewer tested — same root cause as the verification-gap config-verbs finding; patched there.
  - `[false]` `[reject]` (intent) The mechanism rows run below the public API (inline, against crate-private fns) — CLAUDE.md's test placement puts unit tests of private items inline; the public-API rows exist in `tests/secure_config_fixups.rs`, `secure_config_ffi.rs` and the Dart test.
  - `[low]` `[reject]` (intent) The notices end at the worker API (no UI consumer, no barrel export) — the Flutter UI is out of scope per CLAUDE.md, and the barrel omission is the pre-existing pattern for every `RepoHandle` type.
  - `[false]` `[reject]` (intent) Side effects of making reads write (test-isolation pins, two changed `snapshot_colocated.rs` expectations, `ConfigOutcome` API break) — describes the intended change; each is pinned (`api_stability.rs`) or witnessed, no bad outcome.
  - `[false]` `[reject]` (intent) Spec says `in-review` with unchecked tasks while sprint-status says `done` — transient; finalization sets the spec to `done` and checks the tasks.

## Design Notes

**Why a separate pass before the fingerprint.** The fingerprint stamps only the id file and the resolved config file. Running the fix-up first (in `load_effective`, and on every `refresh_settings`) makes the stored fingerprint post-fix-up, so a migration costs no second reload, and a fix-up that changes no stamped file (regenerated metadata, moved repo) still runs every verb, as in the CLI. Cost: one extra parse of the (small) stack per precondition verb — `config::load` in `precondition` stays.

**Why `open_with_report` and `ConfigOutcome`.** The fix-up is one-shot: a notice lost with a refusal is never shown again (e.g. `config get` of an unset key right after a migration). 9.32/9.35 carry warnings on error envelopes; `CreationOutcome` already has that shape and `creation_envelope` already stamps it. Changing `Repo::open`'s signature would touch ~45 test files for no gain.

**Why kinds from state.** jj-lib returns bare strings and `Warning.message` is documented as never parsed. The three branches are distinguishable from the id file alone (absent → migrated; changed → copied; same → regenerated).

Golden shape (sketch, not prescriptive):
```rust
let old_id = fs::read_to_string(self.dir.join(self.id_file_name)).ok();
let loaded = (self.new_secure)(self.dir.clone()).maybe_load_config(rng, root).map_err(secure_error)?;
let new_id = loaded.config_file.as_deref().and_then(Path::parent).and_then(Path::file_name);
for message in loaded.warnings {
    let kind = match old_id.as_deref() { None => ConfigMigrated, Some(id) if Some(OsStr::new(id)) != new_id => ConfigCopied, Some(_) => ConfigRegenerated };
    sink.push(warning::local(kind, message));
}
```

## Verification

**Commands** (foreground; put `~/development/sdks` on `PATH` if a toolchain is missing; revert `pubspec.lock` drift after Dart runs):
- `cargo test -p zanshin-jj --test secure_config_fixups` and `cargo test -p zanshin-ffi --test secure_config_ffi` -- expected: pass.
- `cargo make --allow-private test-core` -- expected: green incl. `test/worker/secure_config_test.dart`.
- `cargo make test` -- expected: green per the last AC; coverage ≥ baseline.

## Auto Run Result

Status: done

**Summary.** Zanshin now runs the jj CLI's start-up secure-config fix-up — jj-lib's own `SecureConfig::maybe_load_config`, for the repo then the workspace layer, in the CLI's order (system and user files load first; a broken repo file stops before the workspace fix-up) — wherever it plays a CLI command's start-up: `Repo::open` (new `Repo::open_with_report` → `CreationOutcome`), the settings refresh every precondition-running verb starts with (before the fingerprint, so no redundant reload and no reload loop), and the `config_*` verbs given a workspace root (new `ConfigOutcome<T>`; the two `edit` halves run the fix-up alone, loading no stack). A legacy `.jj/repo/config.toml` / `.jj/workspace-config.toml` is migrated (the legacy path becomes a symlink), a moved repo's metadata re-pointed, a copied repo's config forked, a missing secure dir regenerated. Each jj-lib message becomes a warning — `jj.config_migrated`, `jj.config_copied`, `jj.config_regenerated`, the kind read off the id file's state — carried first, on the ok AND the error envelope; Dart `openRepo` returns an `OpenedRepoHandle` with `warnings`.

**Files changed.**
- `crates/zanshin-jj/src/config.rs` — `SecureLayer::fix_up`, `secure_rng` (shared with `create_path`), `load_raw` fix-up sink, `fix_up_secure_config` / `fix_up_layers`, module doc rewrite; inline mechanism tests.
- `crates/zanshin-jj/src/repo.rs` — fix-up in `load_effective` / `refresh_settings`, warnings-first `precondition`, `open_with_report`, `open` via `log_dropped`; no-reload-loop inline test.
- `crates/zanshin-jj/src/config_cmd.rs`, `lib.rs`, `warning.rs` — `ConfigOutcome`, fix-up at the root-taking verbs, three `WarningKind`s.
- `crates/zanshin-ffi/src/{repo,config,envelope}.rs` — open via `creation_envelope`, warnings on the six config wrappers' ok + error envelopes, three codes; rustdoc (hence comment-only changes in the generated `zanshin_ffi.h` / `bindings.dart`).
- `packages/zanshin_core/lib/src/{ffi/warning.dart,ffi/config.dart,worker/handle.dart,worker/isolate.dart}` — three codes, `OpenedRepoHandle`, `openRepo`, docs.
- Tests: new `crates/zanshin-jj/tests/secure_config_fixups.rs` (10 rows), `secure_config_fixups_user.rs`, `crates/zanshin-ffi/tests/secure_config_ffi.rs` (6), `packages/zanshin_core/test/worker/secure_config_test.dart`; `test_helpers::leaked_xdg_config_home` + `XDG_CONFIG_HOME` pins in 18 integration binaries and `pin_test_env`; XDG guards in `snapshot_test.dart` / `file_ops_test.dart`; `.result` churn and two changed expectations (`git_remotes.rs`, `snapshot_colocated.rs`); `api_stability.rs` pins.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md`, `deferred-work.md` (9.28 item RESOLVED + new Story 9.37 section), `sprint-status.yaml` (9-37 `done`), `coverage-baseline.txt` (`repo.rs` 97.63 → 97.88).

**Review findings breakdown.** 30 findings (high 0, medium 6, low 21, false 3).
- Patched (re-engaged implementation subagent): witnesses for a verb refusing after its own migration, the verb-start fix-up with an unchanged fingerprint, the `config_list` / `config_set` warning order, every config wrapper's OK envelope (file_write via the regenerate route) and a snapshotting handle symbol's envelope; `Repo::open` logs dropped notices through `warning::log_dropped`; XDG guards in two Dart tests; doc fixes (refresh cost, `writable_files`, `leaked_xdg_config_home`, Dart `ConfigSetResult.warnings` + worker config section, `ffi-abi.md` `log_defaults`); the residual divergences recorded in deferred-work.md.
- Deferred: none routed to defer (frontmatter `deferred` stays empty); the rejected divergences below are recorded in deferred-work.md's Story 9.37 section.
- Rejected: creation paths' re-open runs the (no-op) fix-up (low — nothing to fix on a fresh `.jj/`; avoiding it needs a second open path); `edit` halves fix up under a broken stack (low — intent-contract decision, the 9.28 repair path); split RNG / seeded copy classified `ConfigRegenerated` under `JJ_RANDOMNESS_SEED` (low — test knob only; fixing needs RNG threading or edits the intent-contract rule); workspace-layer copy/regenerate rows (same layer-agnostic code); `&self` accessors run no fix-up (low — the story's Scope names the call points); notices end at the worker API / no barrel export (low — UI out of scope, pre-existing export pattern); inline mechanism tests, intended side effects, transient spec status (false).

**Follow-up review recommendation:** `false`. Patched entries by verdict: high 0, medium 2, low 8. Both medium entries were missing-witness findings, closed by tests that ran green; the patch pass changed production code only by one `log_dropped` call, so no specific unverified risk can be named.

**Verification performed.**
- `cargo test -p zanshin-jj --test secure_config_fixups --test secure_config_fixups_user`, `cargo test -p zanshin-ffi --test secure_config_ffi` → pass (before and after the patches).
- Gate step by step via `cargo make --allow-private`, twice (after implementation and after the review patches): `test-cargo`, `test-clippy`, `test-fmt`, `test-dart-analyze`, `test-dart-format`, `test-core` (556 tests, incl. `secure_config_test.dart`), `test-core-analyze`, `test-core-format`, every `test-shell*` / `test-settings*` step, `test-cargo-deny`, `test-cargo-hygiene`, `test-jj-adapter-hygiene`, `coverage` → exit 0. `test-flutter` → exactly the 3 pre-existing `zanshin_bootstrap_test.dart` splash-card failures (documented since 9.27; untouched by this story).
- Coverage 99.48% overall; `config.rs` 100, `config_cmd.rs` 99.39, `repo.rs` 97.88 (raised), `warning.rs` 100, zanshin-ffi `config.rs` / `repo.rs` / `envelope.rs` 100; extern guard OK. No `pubspec.lock` drift; the developer's `~/.config/jj/{repos,workspaces}` untouched.
- Matrix audit: every I/O row covered by a test that ran and passed (inline `config::tests`, `repo::tests`, `tests/secure_config_fixups*.rs`, `secure_config_ffi.rs`, `secure_config_test.dart`).

**Residual risks.**
- Reads now write the user's config store: a legacy or copied repo opened in Zanshin is migrated/forked exactly as the next `jj` command would do it — intended parity, but a user-visible on-disk change the UI does not announce yet.
- Every precondition-running verb parses the config stack once more (sub-millisecond for normal config sizes).
- `schemas/envelope.fbs` still says open's `RepoHandle` envelope carries no report (comment only; the spec barred `.fbs` edits).
- The divergences listed in deferred-work.md's Story 9.37 section.
