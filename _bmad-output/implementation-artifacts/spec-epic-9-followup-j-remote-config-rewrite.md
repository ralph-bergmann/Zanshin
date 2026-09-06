---
title: 'Epic 9 follow-up J: port the repo-config rewrite on `git remote remove`/`rename`'
type: 'feature'
created: '2026-09-06'
status: 'in-progress'
baseline_revision: '70c6018572d3acbc5371292e2a6631d1755e2a76'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** `jj git remote remove` / `rename` do two on-disk things: they rewrite the git config
(jj-lib's job, already ported) and they rewrite the repo-level jj config — dropping
`[remotes.<name>]` and, when `revset-aliases.'trunk()'` is a plain remote symbol naming that
remote, deleting (remove) or re-pointing (rename) it. Story 9.5 ported only the first half because
`config.rs` was deliberately read-only, so today a `trunk()` alias pinned to a removed remote keeps
naming it and a `[remotes.<name>]` section outlives its remote — a silently wrong `jj log` default
for the rest of the session. Ledger must-have at
`_bmad-output/implementation-artifacts/deferred-work.md:215`.

**Approach:** Ralph's decision (2026-09-06): **Zanshin always behaves like the CLI — every on-disk,
repo-side effect the CLI produces is required parity; only its terminal UX is cosmetic.** So port
the two rewrites verbatim: `config.rs` gains its first WRITER — a repo-config-path resolver plus
exactly the two edits `remove_remote_from_repo_config` / `rename_remote_in_repo_config` make,
built on jj-lib's own `toml_edit`-backed `ConfigFile` (comments and formatting survive) — and
`git.rs::git_remote_remove` / `_rename` call it in the CLI's position: after the jj-lib remote
mutation, inside the transaction window, before the conditional commit. The two `ui.status` lines
are terminal UX and are NOT ported; the effect they announce is. Closing run for that one ledger
entry; the only other work is docs and bookkeeping.

## Boundaries & Constraints

**Always:**
- **Exactly the CLI's two edits, nothing more.** No general-purpose config-write API, no new public
  verb, no `set_value` helper beyond what these two call sites need. Both edits are keyed on the
  **remote name only** (`old_symbol.remote == old_remote`), never on the bookmark name.
- **Never create a repo config file.** Both CLI helpers early-return when no repo-level config file
  exists (`existing_repo_config_file` wraps an already-loaded layer, so a missing file means no
  layer). Mirror that: resolve the path, and if the file does not exist, do nothing.
- **The path is resolved the way `config.rs` already resolves the repo layer** — `secure_config_path
  (workspace.repo_path(), "config-id", "config.toml", <config_dir>/jj/repos)` — NOT a hardcoded
  `.jj/repo/config.toml`. At 0.44.0 the canonical file lives at
  `<config_dir>/jj/repos/<config-id>/config.toml` and the `.jj/repo/config.toml` name is the legacy
  fallback the resolver already handles. The read path and the write path must agree by
  construction, or the verb rewrites a file the session does not read.
- **CLI ordering:** jj-lib remote mutation → repo-config rewrite → conditional commit. The rewrite
  goes INSIDE the `mutate::finish_or_no_op` closure, after `git::remove_remote`/`rename_remote`, so
  a rewrite failure aborts the transaction exactly as the CLI's `?` does. Path resolution happens
  BEFORE the closure so a malformed `config-id` fails before anything is mutated.
- **`Repo::reload_after_config_write` stays the wrapper** for both verbs (unchanged call shape), so
  the reloaded session re-reads the rewritten file — config is re-read per call and never cached.
- **A rewrite failure is `MutateError::Config`** → `jj.config_error` at the FFI boundary. No new
  error code is minted; the two wrappers' `# Errors` blocks, `docs/ffi-abi.md` rows and the Dart
  doc code-lists gain that one code (`ffi_abi_doc_sync.rs` enforces rustdoc↔index agreement).
- **`crates/zanshin-jj/src/config.rs` is at 100.00 % in `coverage-baseline.txt`** — every new line
  must be executed by a test. Error-mapping must therefore go through ONE generic helper whose body
  a provokable instantiation covers (see Design Notes), never per-call-site closures that can only
  run in an unreachable state.
- Every public signature stays `jj_lib`-type-free; the new items are `pub(crate)`. No `unwrap`/
  `expect`/`panic!` (the CLI's `.expect("old value was string")` is NOT ported). Clippy pedantic
  clean with no new `#[allow]`. SPDX first line on any new file.
- The verbs' signatures do not change at any layer, so no `.fbs` edit and no new `extern "C"`
  symbol. `cargo make codegen` still runs (the header carries the edited rustdoc) and its four
  outputs are committed.

**Block If:**
- jj-lib 0.44.0's `ConfigFile` cannot express the two edits without adding a direct `toml_edit`
  dependency AND `toml_edit` cannot be added from the existing lockfile entry → HALT, blocking
  condition `repo-config write API unavailable`.
- The codegen diff changes an `extern "C"` parameter's TYPE, NAME or ORDER → HALT, blocking
  condition `unexpected codegen drift`. (Doc-comment hunks are EXPECTED and are inspected, not
  halted on.)

**Never:**
- No port of the two `ui.status` lines, no warning channel on `MutationResult`, no new payload
  field. No `remotes.<name>.auto-track-bookmarks` work (a separate ledger item).
- No touching `git_remote_add` / `git_remote_set_url`: the CLI rewrites the repo config for
  `remove` and `rename` only (`add`/`set-url` write none).
- No config WRITE on any read path, and no `SecureConfig` adoption — `config.rs`'s documented
  no-side-effect-on-read stance is unchanged; only these two verbs write.
- No fixture regeneration, no `#[ignore]`, no lowered baseline, no new `exclude_prefix`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Remove, alias pinned to it | repo config has `[remotes.origin]` and `'trunk()' = 'main@origin'`; `git_remote_remove("origin")` | Both are gone from the file; the builtin `trunk()` applies again | No error expected |
| Rename, alias pinned to it | same file; `git_remote_rename("origin", "upstream")` | `[remotes.origin]` becomes `[remotes.upstream]`; `'trunk()'` becomes `'main@upstream'` | No error expected |
| Alias names a DIFFERENT remote | `'trunk()' = 'main@other'`; remove/rename `origin` | `[remotes.origin]` handled; `'trunk()'` untouched | No error expected |
| Alias is not a plain remote symbol | `'trunk()' = 'latest(main@origin)'` (or a non-string value) | `'trunk()'` untouched — parse yields no `RemoteSymbol` | No error expected |
| No repo config file | no `config-id`, no legacy file | Both verbs succeed; NO file is created | No error expected |
| Comments + unrelated keys | file carries comments, `[revsets] log = …`, other `[remotes.*]` | Everything but the two edits survives byte-for-byte | No error expected |
| Same-session read-back | after remove, `eval_revset("trunk()")` on the SAME handle | Resolves through the builtin alias (root() in a remote-less repo) | No error expected |
| Malformed `config-id` | `.jj/repo/config-id` is not 20 hex chars | Verb refuses BEFORE mutating anything | `jj.config_error`, path in `context` |
| Unparseable repo config | repo config file is invalid TOML | Verb refuses; the git-config edit inside the aborted transaction is not committed | `jj.config_error`, path + TOML position in `context` |
| Unwritable repo config | config file exists but cannot be written | Verb refuses; no operation is committed | `jj.config_error`, io reason in `context` |
| Remote missing / reserved `git` | `remove("nonexistent")`, `remove("git")` | Unchanged from today (refusal / no-op-written) | Unchanged codes |

</intent-contract>

## Code Map

Anchors read against the working tree at baseline `70c6018`.

**Oracle (read-only, `git -C ../jj show v0.44.0:<path>`)**
- `cli/src/commands/git/mod.rs:133` `TRUNK_CONFIG_NAME = ["revset-aliases", "trunk()"]`;
  `:195-229` `rename_remote_in_repo_config`; `:231-262` `remove_remote_from_repo_config`;
  `:264-274` `get_trunk_symbol` (`layer.look_up_item` → `as_str` → `revset::parse_program` →
  `ExpressionKind::RemoteSymbol`, everything else ⇒ `None`).
- `cli/src/config.rs:682-691` `existing_repo_config_file` — picks the already-loaded
  `ConfigSource::Repo` layer, never touches the filesystem, never creates.
- `cli/src/commands/git/remote/remove.rs:33-49` and `rename.rs:36-59` — the call order:
  `git::remove_remote(tx.repo_mut())` → config rewrite → `if tx.repo().has_changes() { tx.finish() }`.

**jj-lib 0.44.0 (vendored, all `pub`)**
- `config.rs:552-640` `ConfigFile`: `load_or_empty(source, path)`, `layer()`, `data_mut()`
  (`&mut toml_edit::DocumentMut`), `set_value(name, value)`, `delete_value(name)`, `save()`.
  `toml_edit`-backed ⇒ comments/formatting preserved; `save()` is `fs::write` of `data.to_string()`.
- `config.rs:413` `ConfigLayer::look_up_item`; the `[&str; N]` `ToConfigNamePath` impl is how
  `["revset-aliases", "trunk()"]` is expressed (never the dotted string).
- `revset.rs` re-exports `parse_program` + `ExpressionKind`; `ref_name.rs:345/311/414`
  `RemoteRefSymbolBuf { name, remote }`, `RefName::to_remote_symbol`, `Display`.

**`zanshin-jj`**
- `src/config.rs:3-42` module doc — the "deliberately read-only" contract to revise;
  `:150-171` `describe`/`file_error`/`value_error` (reuse); `:262-295` `secure_config_path`
  (reuse — the resolver both halves must share); `:317-332` `add_secure_layer` (the read-side
  caller); `:188-214` `ConfigEnv::from_env` + `root_config_dir`; `:488-773` inline tests.
- `src/git.rs:30-40` module-doc bullet "**No jj repo-config rewrite.**" — becomes its opposite;
  `:426-453` `git_remote_remove`; `:455-488` `git_remote_rename` (both call
  `mutate::finish_or_no_op` with a one-line closure).
- `src/repo.rs:724-745` `reload_after_config_write`; `:840-869` `Repo::git_remote_remove`
  (`:848-849` the divergence paragraph); `:871-906` `Repo::git_remote_rename` (`:875`).
- `src/mutate.rs:134` `MutateError::Config`; `:328` `cfg()`; `:821-831` `finish_or_no_op`
  (closure runs inside the transaction, before the `has_changes()` check).

**`zanshin-ffi`**
- `src/git.rs:330-379` `zanshin_git_remote_remove` (`:339-341` divergence, `:351-359` `# Errors`);
  `:381-439` `zanshin_git_remote_rename` (`:386-387`, `:401-412`).
- `src/repo.rs:109` `map_mutate_err`'s `MutateError::Config` → `jj.config_error` arm (already there).
- `tests/git_ffi.rs:250-251` — "the only one of the six that reads config" comment, now false;
  `:439` the remove happy-path row.
- `tests/ffi_abi_doc_sync.rs:273` enforces rustdoc `# Errors` == `docs/ffi-abi.md` row codes.

**Dart / docs**
- `packages/zanshin_core/lib/src/worker/handle.dart:537-585` — `gitRemoteRemove`/`gitRemoteRename`
  docs (`:557-558` the divergence sentence, `:563`/`:585` the error-code lists).
- `packages/zanshin_core/lib/src/ffi/git.dart:71-99` adapters (no doc claim about the config).
- `docs/ffi-abi.md:351-352` the two rows; `docs/rust-error-codes.md` the `jj.config_error` row.

**Test surface**
- `crates/zanshin-jj/tests/git_remotes.rs:559-584` `remove_does_not_edit_the_jj_repo_config` — the
  row to invert; `:31-38` `pin_env` (`JJ_CONFIG=""`, so only the repo layer is live);
  `:107-113` `git_workspace()`; `:66-101` op-log/remote oracles.
- `crates/zanshin-jj/tests/revset.rs:554` `write_repo_config` — proves the legacy
  `.jj/repo/config.toml` really is the layer this suite's repos read.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/config.rs` -- revise the module doc (it is no longer read-only: name the
  two verbs that write, and keep the no-side-effect-on-READ stance explicit). Add, all
  `pub(crate)`: `existing_repo_config_path(workspace: &Workspace) -> Result<Option<PathBuf>,
  ConfigError>` (reuse `ConfigEnv::from_env` + `root_config_dir` + `secure_config_path`, filtered by
  `.exists()` — the same resolution `add_secure_layer` uses, so read and write agree by
  construction); `remove_remote_from_repo_config(path: Option<&Path>, remote: &str)` and
  `rename_remote_in_repo_config(path: Option<&Path>, old: &str, new: &str)`, each a verbatim port of
  the CLI helper minus its `ui.status` line; a private `trunk_symbol(layer) -> Option<(String,
  String)>` (bookmark, remote) mirroring `get_trunk_symbol`; and ONE generic error helper for the
  write path (see Design Notes). Document WHY the trunk edit keys on the remote only and why a
  non-symbol value is left alone.
- `crates/zanshin-jj/src/git.rs` -- resolve the path before `finish_or_no_op` and call the matching
  writer INSIDE the closure, after `git::remove_remote`/`rename_remote`, mapping its error with
  `mutate::cfg`. Rewrite the module-doc bullet from "No jj repo-config rewrite" into the ported
  behaviour (name what is rewritten and that the status lines are not). Extend both fns' `# Errors`
  with `MutateError::Config`.
- `crates/zanshin-jj/src/repo.rs` -- replace the two "`.jj/repo/config.toml` is NOT edited"
  paragraphs with the ported behaviour (which file, which two edits, that no file is created), add
  the `MutateError::Config` bullet to both `# Errors`, and keep the existing "an `Err` does not mean
  nothing happened" paragraph accurate for the new failure point.
- `crates/zanshin-jj/tests/git_remotes.rs` -- REWRITE `remove_does_not_edit_the_jj_repo_config` into
  its opposite and add the sibling rows: rename moves the section and re-points the alias; an alias
  naming a different remote survives both verbs; a non-symbol `trunk()` survives; no config file ⇒
  both verbs succeed and create none; comments + unrelated keys survive byte-for-byte (assert on the
  untouched remainder, not on the whole file); and the same-session read-back via
  `Repo::eval_revset("trunk()")` (after remove it resolves through the builtin; after rename the
  refusal names the NEW remote, proving the reloaded config carries it).
- `crates/zanshin-jj/src/config.rs` (inline tests) -- unit-test the writers directly against
  tempfile paths for every I/O-matrix row that does not need a repo: absent file, absent `remotes`
  table, alias variants (matching / different remote / non-symbol / non-string), comment and
  formatting preservation, unparseable TOML, and an unwritable file. Coverage of this file must stay
  at 100.00.
- `crates/zanshin-ffi/src/git.rs` -- rewrite the two divergence sentences and add `jj.config_error`
  to both `# Errors` blocks (naming the repo-config rewrite as its source).
- `crates/zanshin-ffi/tests/git_ffi.rs` -- correct the "only one of the six that reads config"
  comment and add one row proving `zanshin_git_remote_remove` surfaces `jj.config_error` for an
  unparseable repo config, plus one asserting the rewrite is visible through the FFI path.
- `cargo make codegen` -- run it AFTER every rustdoc edit is final (the header is generated from the
  rustdoc); commit all four outputs.
- `packages/zanshin_core/lib/src/worker/handle.dart` -- rewrite the two divergence sentences and add
  `jj.config_error` to both code lists.
- `docs/ffi-abi.md` + `docs/rust-error-codes.md` -- add `jj.config_error` to rows `:351`/`:352` and
  record the widened emitter set on the `jj.config_error` registry row (the two remote verbs now
  read AND write the repo-level config).
- `_bmad-output/implementation-artifacts/deferred-work.md` + `spec-9-5-git-local-sync-remote-config.md`
  -- bookkeeping in the established convention: strike through the ledger bullet and append
  ` — RESOLVED 2026-09-06 (spec-epic-9-followup-j-remote-config-rewrite, commit <short>): <one line,
  naming Ralph's rule that on-disk CLI side effects are required parity>`; convert 9.5's first
  `deferred:` item to the `summary:`/`evidence:`/`resolved:` shape without changing its text, and
  re-parse the frontmatter.

**Acceptance Criteria:**
- Given a repo config with `[remotes.origin]` and `'trunk()' = 'main@origin'`, when
  `Repo::git_remote_remove("origin")` succeeds, then both are gone from that file, the file's other
  content is unchanged, and `Repo::eval_revset("trunk()")` on the SAME handle resolves through the
  builtin alias.
- Given the same file, when `Repo::git_remote_rename("origin", "upstream")` succeeds, then the
  section is `[remotes.upstream]`, `'trunk()'` is `main@upstream`, and a same-session `trunk()`
  resolution names `upstream` rather than `origin`.
- Given a workspace with no repo-level config file, when either verb succeeds, then no config file
  exists afterwards.
- Given an unparseable or unwritable repo config, when either verb runs, then it fails with
  `MutateError::Config` (`jj.config_error` through the FFI) and writes no operation.
- Given the pre-existing suites, when `cargo make test` runs, then every unrelated remote-verb row
  still passes unchanged and `ffi_abi_doc_sync.rs` is green with `EXPECTED_EXPORTS` untouched.
- Given `cargo make test`, when it completes, then the coverage ratchet is green with no baseline
  entry lowered and `crates/zanshin-jj/src/config.rs` still at 100.00.
- Given the shipped docs at every layer, when read, then no live text claims that
  `.jj/repo/config.toml` is not edited or that the rewrite is a deliberate divergence.

## Spec Change Log

## Review Triage Log

## Design Notes

**Why inside the transaction closure.** `mutate::finish_or_no_op` runs its closure between
`start_transaction()` and the `has_changes()` check, which is exactly where the CLI calls its helper
(`remove.rs:35-37`). Putting the rewrite there — rather than after the verb returns — reproduces
both halves of the CLI's coupling: the rewrite happens even when NO operation is written (the
reserved remote `git`), and a rewrite failure drops the transaction, so the jj view is untouched
while the git-config edit jj-lib already performed stands. That asymmetry is the CLI's own and is
mirrored, not corrected; the "an `Err` does not mean nothing happened" paragraph already covers it.

**The error helper and the 100.00 % file.** `set_value`/`delete_value` return `ConfigUpdateError`
only when the target is a TABLE, and both call sites are guarded by `as_str()` — so those arms are
structurally unreachable, and a per-call-site `.map_err(|e| …)` closure would add lines no test can
execute. Use one generic function instead and pass it by name, so the uncoverable states share a
body that a coverable instantiation executes:

```rust
fn write_error<E: std::error::Error + 'static>(err: E) -> ConfigError {
    ConfigError::Load { reason: describe(&err) }   // `describe` walks the source chain
}
// call sites, no closure:
let mut file = ConfigFile::load_or_empty(ConfigSource::Repo, path).map_err(write_error)?;
file.delete_value(TRUNK_CONFIG_NAME).map_err(write_error)?;
file.save().map_err(write_error)?;
```

The `ConfigLoadError` instantiation is covered by the unparseable-TOML test and `ConfigFileSaveError`
by the unwritable-file test, so the body's lines are executed; the update-error instantiation reuses
them.

**`toml_edit` without a direct dependency.** The `[remotes.<name>]` move/removal needs
`file.data_mut()` → `get_mut("remotes")` → `as_table_like_mut()` → `remove`/`insert`. All of those
are reached by method call on values jj-lib hands out; `TableLike`'s methods resolve as inherent
candidates of the `dyn TableLike` object type, so nothing has to be NAMED and no direct `toml_edit`
dependency is required. `as_table_like_mut` (not `as_table_mut`) is deliberate — it also covers the
inline-table spelling `remotes = { origin = { … } }`, exactly as the CLI does. If this does not
compile, add `toml_edit` as a workspace dependency pinned to the version already in the lockfile as
a jj-lib transitive (cargo-deny clean) rather than narrowing the shape.

**Unconditional `save()`.** The CLI saves even when neither edit matched. Keep that: `toml_edit`
round-trips the document byte-for-byte, so the only observable difference is the file's mtime, and
diverging here would mean auditing when a save is "needed" — more code for less parity.

## Verification

**Commands:**
- `cargo make codegen` -- expected: only doc-comment hunks in `zanshin_ffi.h`; no signature drift.
- `cargo make test` -- expected: exit 0, run unpiped and synchronously (~15 min), including clippy
  pedantic, `dart analyze`/`format`, `cargo deny` and a green coverage ratchet with
  `crates/zanshin-jj/src/config.rs` at 100.00.

**Manual checks (if no CLI):**
- `git diff` on `coverage-baseline.txt`: entries may rise, none may fall.
- The two bookkeeping files parse: the ledger bullet is struck through with a resolution line, and
  `spec-9-5-…`'s frontmatter still loads as YAML with the first `deferred:` item carrying
  `summary:`/`evidence:`/`resolved:`.
