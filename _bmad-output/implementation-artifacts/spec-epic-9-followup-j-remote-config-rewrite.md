---
title: 'Epic 9 follow-up J: port the repo-config rewrite on `git remote remove`/`rename`'
type: 'feature'
created: '2026-09-06'
status: 'done'
baseline_revision: '70c6018572d3acbc5371292e2a6631d1755e2a76'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['oversized']
deferred:
  - summary: >-
      `Repo::clone_into` writes none of the repo-level presets the CLI's `jj git clone` writes,
      so a Zanshin-cloned repo has a different `trunk()` default than a CLI-cloned one.
    evidence: |-
      `cli/src/commands/git/clone.rs:289-296` @ v0.44.0 calls `write_repo_presets`, the third
      member of the same helper family as the two ported here (`cli/src/commands/git/mod.rs:151-190`):
      it writes `[remotes.<name>].fetch-bookmarks`/`fetch-tags` and
      `revset-aliases.'trunk()' = <default-branch>@<remote>` into the repo-level file through the
      same `ConfigFile` API. `grep write_repo_presets` over `crates/`, `docs/` and `_bmad-output/`
      has zero hits, so the omission is neither tested nor recorded as a divergence. Follow-up J
      ports remove/rename only, so the two verbs now MAINTAIN presets Zanshin itself never creates,
      and the "the rewrite finds what the clone wrote" round trip is never closed. Surfaced by this
      run's review; not caused by it — but Ralph's rule (on-disk CLI side effects are required
      parity) makes it a must-have rather than an accepted divergence. Belongs with the clone/init
      verbs (Story 9.20 territory), not with the remote-config verbs.
    location: >-
      crates/zanshin-jj/src/repo.rs::Repo::clone_into
    severity: medium
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

### 2026-09-06 — Implementation

Where the built change is narrower, wider or stricter than the prose above. The
`<intent-contract>` is unchanged; these are corrections to the Code Map, Tasks and Design
Notes.

- **`write_error`'s covered instantiation is the SAVE error, not the load error.** The Design
  Notes sketch (`:262`) shows `ConfigFile::load_or_empty(ConfigSource::Repo, path)
  .map_err(write_error)`, and closes with "the `ConfigLoadError` instantiation is covered by the
  unparseable-TOML test". The shipped code does not route the load through `write_error` at all:
  a load failure must name the FILE, so it goes through the existing `file_error(path, &e)`
  helper, whose reason is `"<path>: <chain>"` and which the `an_unparseable_repo_config…` rows
  assert on. `write_error` is therefore instantiated only by `ConfigFileSaveError` (covered by the
  unwritable-file row) and by `ConfigUpdateError` (structurally unreachable) — one covered
  instantiation is still enough to execute the shared body, which is the property the Design Note
  actually needed, so `config.rs` holds at 100.00 % either way.
- **The load was hoisted OUT of the transaction closure — the built behaviour is STRICTER than
  the I/O matrix's "Unparseable repo config" row.** That row (`:101`) expects "Verb refuses; the
  git-config edit inside the aborted transaction is not committed", and the Always bullet at `:52-55`
  puts only PATH resolution before the closure. Both are inside `<intent-contract>` and stay as
  written. What ships refuses EARLIER: the file is resolved *and loaded* before the transaction
  opens, so an unreadable file, invalid TOML or a malformed `config-id` leaves nothing mutated at
  all — the git config included — and only a `save()` failure can still abort a transaction after
  jj-lib's git-config edit. This is closer to the CLI, not further from it: `existing_repo_config_file`
  (`cli/src/config.rs:682-691`) wraps a repo layer the process parsed at start-up, so the CLI too
  fails before `git::remove_remote` writes anything. The loaded `ConfigFile` (a `jj_lib` type in a
  `pub(crate)` position, as `conflict_marker_style` already is) is moved into the closure, which
  keeps the WRITE where the intent contract puts it. Hoisting also removes a way to violate the
  contract's own "never create a repo config file": `load_or_empty` answers a missing file with an
  empty document, and the unconditional `save()` would then have created it.

## Review Triage Log

### 2026-09-06 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 16: (high 0, medium 4, low 12)
- defer: 1: (high 0, medium 1, low 0)
- reject: 11: (high 0, medium 2, low 9)
- addressed_findings:
  - `[medium]` `[patch]` The repo config was LOADED inside the transaction closure, so an
    unreadable/unparseable file or a malformed `config-id` refused only AFTER jj-lib had already
    rewritten the git config — the CLI, whose repo layer is parsed at process start, refuses before
    touching anything. The load was hoisted before `finish_or_no_op` (`config.rs::existing_repo_config_file`
    now returns a loaded `Option<ConfigFile>`); only a `save()` failure can still abort a transaction
    late, which is the CLI's own shape. Routed `patch`, not `bad_spec`: the fix is one call moved
    earlier plus two test contracts, with no ripple through the design, and the correction is recorded
    in the Spec Change Log.
  - `[medium]` `[patch]` `ConfigFile::load_or_empty` answers a missing file with an EMPTY document
    and the writers `save()` unconditionally, so a file deleted between the `.exists()` filter and
    the load would have been CREATED — the one thing the ported helpers must never do. The same hoist
    makes the filter and the load one step.
  - `[medium]` `[patch]` The reserved remote `git` — the case three doc layers cite as the reason the
    rewrite sits before the `has_changes()` guard — was never tested with a repo config present.
    Both reserved-remote rows now carry `[remotes.git]` + `'trunk()' = 'main@git'` and assert the
    rewrite happened while `new_op_id` is unchanged.
  - `[medium]` `[patch]` Every row reached the file through the legacy `.jj/repo/config.toml`
    fallback, which ignores `root_config_dir` entirely, so the canonical
    `<config_dir>/jj/repos/<config-id>/config.toml` branch was unpinned (swapping `repos` for
    `workspaces` broke no test). The suite now pins `$XDG_CONFIG_HOME` to a process-lifetime temp dir
    (also making it hermetic, as project-context.md requires) and adds a row through the canonical
    layout, asserting the legacy file is neither read nor written.
  - `[low]` `[patch]` `zanshin_git_remote_rename` advertised `jj.config_error` with no witness at any
    layer, though it takes the `set_value` arm rather than `remove`'s `delete_value`; a verb-level and
    an FFI refusal row were added.
  - `[low]` `[patch]` The rename rows asserted `contains("upstream")`, which the re-pointed alias
    alone satisfies — the `[remotes.<old>]` → `[remotes.<new>]` move could have been dropped without
    failing. The moved section and the vanished old name are now asserted explicitly.
  - `[low]` `[patch]` The rename rows hedged across quotings (`"main@upstream"` OR `'main@upstream'`),
    pinning nothing; the exact emitted line is asserted now.
  - `[low]` `[patch]` "Comments and unrelated keys survive byte-for-byte" was asserted with fragment
    `contains` checks after an edit; it is a whole-file `assert_eq!` now.
  - `[low]` `[patch]` `docs/rust-error-codes.md` still called `zanshin_git_import` "the only one of
    the six git verbs that reads config" and described `jj.config_error` as a READ failure only.
  - `[low]` `[patch]` `ConfigError` / `ConfigError::Load` rustdoc still said "errors from reading".
  - `[low]` `[patch]` "so the builtin `trunk()` applies again" was asserted unconditionally at four
    layers, but the writers touch the REPO layer only — a `trunk()` in the workspace or user layer
    still wins; qualified everywhere.
  - `[low]` `[patch]` The resolver silently yields `Ok(None)` when no `<config_dir>` can be
    determined, making the whole rewrite vanish; documented, together with why read and write stay
    consistent (the read side skips the repo layer under the same condition).
  - `[low]` `[patch]` `reload_after_config_write`'s doc claimed every caller had rewritten the git
    config; after the hoist a pre-transaction refusal reaches it having written nothing.
  - `[low]` `[patch]` The ledger resolution overclaimed on two points — `ffi_abi_doc_sync.rs` checks
    rustdoc against `docs/ffi-abi.md` only (nothing machine-checks the Dart lists) and `set_value`
    re-emits the alias value, so the user's quoting is not preserved byte-for-byte — and its ordering
    sentence needed restating after the hoist.
  - `[low]` `[patch]` Ralph's rule was recorded only as narrative. `_bmad-output/project-context.md`'s
    "NEVER diverge from the jj CLI's observable behavior" anti-pattern now says observable behaviour
    includes every on-disk, repo-side effect, and the ledger carries the forward prohibition.
  - `[low]` `[patch]` `docs/ffi-abi.md`'s general `jj.config_error` blurb described reads only.

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

## Auto Run Result

Status: done
Blocking condition: none

### Summary

`jj git remote remove`/`rename` now rewrite the repo-level jj config the way the CLI does, closing
the last must-have of `deferred-work.md`'s Story 9.5 git-sync group. `crates/zanshin-jj/src/config.rs`
— until now deliberately read-only — gains the crate's only config WRITERS: exactly the CLI's two
edits (`[remotes.<name>]` dropped or moved; a `revset-aliases.'trunk()'` that is a plain remote
symbol naming that remote deleted or re-pointed), keyed on the remote name alone, built on jj-lib's
own `toml_edit`-backed `ConfigFile` so comments, key order and unrelated keys survive. The file is
resolved by the same `secure_config_path` the READ side uses — canonical
`<config_dir>/jj/repos/<config-id>/config.toml`, legacy `.jj/repo/config.toml` as fallback — and
loaded BEFORE the transaction opens, so read and write address one file by construction and every
read-side fault refuses with nothing mutated at all, exactly as the CLI (whose repo layer is parsed
at process start) does. The rewrite itself runs inside `mutate::finish_or_no_op`'s closure, after
the jj-lib remote mutation and before the conditional commit, so it happens even when NO operation
is written (the reserved remote `git`), and a `save()` failure aborts the transaction while jj-lib's
git-config edit stands — the CLI's own shape. With no repo-level file the rewrite is a no-op that
creates nothing. The two `ui.status` lines are terminal UX and are not ported; the effect they
announce is. A rewrite failure is `MutateError::Config` → `jj.config_error`; no new error code, no
`.fbs` edit, no new `extern "C"` symbol, no new dependency, no signature change at any layer.

### Files changed

- `crates/zanshin-jj/src/config.rs` — the two writers, `existing_repo_config_file` (resolve + load,
  one step), the private `trunk_symbol` mirroring the CLI's `get_trunk_symbol`, the generic
  `write_error`, the revised module contract, and 11 inline rows covering the file-shape matrix.
- `crates/zanshin-jj/src/git.rs` — both verbs load the repo config before the transaction and rewrite
  it inside the closure; the module doc's "No jj repo-config rewrite" divergence bullet became a
  section describing the ported behaviour.
- `crates/zanshin-jj/src/repo.rs` — both facades' divergence paragraphs replaced, `MutateError::Config`
  added to their `# Errors`, `reload_after_config_write`'s doc widened for callers that wrote nothing.
- `crates/zanshin-jj/tests/git_remotes.rs` — `remove_does_not_edit_the_jj_repo_config` inverted, plus
  the rename twin, the survivors, create-nothing, both refusal orderings, the two reserved-`git` rows
  extended, the canonical-`config-id` row, and a hermetic `$XDG_CONFIG_HOME` pin.
- `crates/zanshin-ffi/src/git.rs` + `include/zanshin_ffi.h` — the two wrappers' divergence sentences
  rewritten and `jj.config_error` added to their `# Errors` (one `cargo make codegen`).
- `crates/zanshin-ffi/tests/git_ffi.rs` — the rewrite across the boundary, `jj.config_error` for both
  remote verbs, and the corrected "only one of the six reads config" comment.
- `packages/zanshin_core/lib/src/worker/handle.dart` + `ffi/bindings.dart` — the two doc paragraphs
  and both error-code lists.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` — the two symbol rows, the general `jj.config_error`
  blurb, and the registry row (these two verbs are its first emitters that also WRITE config).
- `_bmad-output/implementation-artifacts/deferred-work.md` — ledger item struck through and resolved;
  one new deferral recorded.
- `_bmad-output/implementation-artifacts/spec-9-5-git-local-sync-remote-config.md` — the matching
  `deferred:` item converted to the `summary:`/`evidence:`/`resolved:` shape.
- `_bmad-output/project-context.md` — the CLI-parity anti-pattern now says observable behaviour
  includes every on-disk, repo-side effect (Ralph's rule, made binding for future stories).

### Review findings breakdown

- Patches applied: 16 (high 0, medium 4, low 12) — see the Review Triage Log for each.
- Items deferred: 1 (medium) — `Repo::clone_into` writes none of the CLI's repo-level clone presets;
  recorded in the spec frontmatter and in the central ledger under this run's own section.
- Items rejected: 11 — chiefly Story 9.5's still-standing "No jj repo-config rewrite" bullet (it
  lives inside that spec's immutable `<intent-contract>`; the `resolved:` frontmatter block is the
  sanctioned record), the unconditional `save()` and the empty `[remotes]`/`[revset-aliases]` tables
  it can leave behind (both CLI parity), a guard against overwriting an existing `[remotes.<new>]` on
  rename (the CLI overwrites too, and jj-lib refuses the rename first anyway), `fs::write`
  atomicity/concurrency (jj-lib's own behaviour, shared with the CLI), `trunk_symbol` returning
  `(String, String)` instead of `RemoteRefSymbolBuf` (cosmetic), `write_error` resembling
  `value_error` (different receiver, both needed), the chmod-0444 row failing under root (the suite
  never runs as root), historical references to the renamed test inside struck-through ledger text,
  and the FFI suite's remaining `$HOME` dependence (pre-existing across every suite).
- Follow-up review recommended: **true**. Patched severities: high 0, medium 4, low 12; score
  = 3 × 4 + 1 × 12 = 24, at or above the threshold of 5.

### Verification performed

- `cargo make codegen` — run twice (once per commit round); the second run produced no diff at all,
  and the first's `zanshin_ffi.h` / `bindings.dart` diff is doc-comment hunks only: no `extern "C"`
  parameter type, name or order changed.
- `cargo make test` — exit 0, run unpiped and synchronously by this session after the review patches
  (434 s): cargo tests, clippy pedantic `-D warnings`, rustfmt, `flutter test`, `dart analyze`/`format`,
  `cargo deny`, `extern-coverage` OK, and the coverage ratchet green at 99.24 % with
  `coverage-baseline.txt` unchanged (`crates/zanshin-jj/src/config.rs` still 100.00).
- Matrix audit: every I/O-matrix row has a covering test that ran and passed — verified by name in the
  gate log (`remove_rewrites_…`, `rename_moves_…`, `an_alias_naming_another_remote_…`,
  `a_trunk_alias_that_is_not_a_plain_remote_symbol_…`, `without_a_repo_config_file_…`,
  `comments_and_unrelated_keys_survive_the_rewrite`, `the_canonical_config_id_addressed_file_is_the_one_rewritten`,
  `a_malformed_config_id_refuses_before_anything_is_mutated`,
  `an_unparseable_repo_config_refuses_before_anything_is_mutated` (+ the rename twin and the two FFI
  rows), `an_unwritable_repo_config_aborts_the_transaction_after_the_git_config_edit`, and the
  pre-existing missing-remote / reserved-`git` rows).
- Bookkeeping parsed: both edited specs' frontmatter loads as YAML; 9.5's first `deferred:` item now
  carries `summary:`/`evidence:`/`resolved:` and this spec's `deferred:` list holds the one new item.

### Residual risks

- **The exists→load race is narrowed, not eliminated.** If the repo config file is deleted between
  the `.exists()` filter and `ConfigFile::load_or_empty` (adjacent statements now), `load_or_empty`
  still yields an empty document and the unconditional `save()` recreates the file. Closing it fully
  would mean dropping the CLI's unconditional `save()`, which the intent contract pins.
- **Only the repo LAYER is rewritten.** A `trunk()` defined in the workspace or user layer still wins
  after a remove; the docs now say so, and the suite only sees the builtin because it pins
  `JJ_CONFIG=""`.
- **`an_unwritable_repo_config_…` relies on `chmod 0o444`** and would not provoke a failure if the
  suite ever ran as root.
- **The FFI suite is not hermetic on `$XDG_CONFIG_HOME`** (only `git_remotes.rs` is): its config rows
  all take the legacy fallback, so they still depend on the developer's `$HOME` yielding *some*
  `<config_dir>`. Pre-existing and shared with every other suite; judged noise rather than a deferral.
