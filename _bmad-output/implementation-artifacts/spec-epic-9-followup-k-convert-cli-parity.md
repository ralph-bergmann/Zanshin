---
title: 'Epic 9 follow-up K: make both convert verbs match `jj git init`''s External branch'
type: 'feature'
created: '2026-09-06'
status: 'done'
baseline_revision: '7e799c04073ede02dc6e1820ca853b3568e7aad4'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['oversized']
deferred:
  - summary: >-
      The colocated head import omits the working-copy `check_out` + `reset` the CLI pairs with
      it, so the operation's view CONTENT differs even though its description and skip rule match.
    evidence: |-
      `cli/src/cli_util.rs::import_git_head` (`:1352-1416` @ v0.44.0) does four things:
      `git::import_head`, the no-change early return, `check_out` + `locked_wc().reset(&wc_commit)`,
      and the `import git head` commit. This run ports the first, second and fourth. The `reset`
      needs `start_working_copy_mutation` — the locked-working-copy lifecycle Story 9.22 owns —
      and reversing project decision D2 ("Zanshin never snapshots") was out of this run's scope,
      so `@` is not re-parented onto the imported HEAD; it settles there on the first snapshot
      (2.12's D3a). Same cause: on a DIRTY working tree the CLI's colocated `maybe_snapshot` also
      writes a `snapshot working copy` operation and a second `import git refs`; Zanshin writes
      neither, so the colocated op-log witness pins "and nothing more" only for a clean tree.
      Documented at the function, the module doc, both public verbs' rustdoc, the FFI rustdoc,
      `docs/ffi-abi.md` and the ledger resolution.
    location: >-
      crates/zanshin-jj/src/convert.rs::import_git_head
    severity: medium
  - summary: >-
      The CLI's refusal to colocate inside a linked Git worktree is not ported, so
      `convert_colocated` succeeds where `jj git init --colocate` hard-errors.
    evidence: |-
      `cli/src/commands/git/init.rs:209-219` @ v0.44.0 guards the colocate-over-existing-`.git`
      path with `is_linked_git_worktree(workspace_root)` and returns
      "Cannot create a colocated jj repo inside a Git worktree." with a hint. `detect_repo`
      classifies a linked worktree (whose `.git` is a gitdir POINTER file) as `Git`, so it reaches
      `convert_into`, which ACCOMMODATES the shape by reading `is_colocated` instead of refusing.
      Pre-existing since Story 2.12 and outside this run's ledger bullet (which covers the op
      split, the `trunk()` alias and the `.gitignore`), but a real divergence under Ralph's
      "Zanshin always behaves like the CLI" rule, and untested either way.
    location: >-
      crates/zanshin-jj/src/convert.rs::convert_colocated
    severity: medium
  - summary: >-
      No Zanshin verb sets the operation's `workspace_name` metadata, which the CLI writes on
      every transaction and which is persisted op-log state.
    evidence: |-
      The CLI opens every transaction through `cli_util.rs::start_repo_transaction`
      (`:2883-2894` @ v0.44.0), which calls `tx.set_workspace_name(workspace_name)` — jj-lib's
      `Transaction::set_workspace_name` writes `op_metadata.workspace_name`
      (`jj-lib-0.44.0/src/transaction.rs:120-122`) — before the command-arg attributes (those the
      intent explicitly excludes). `grep set_workspace_name crates/` has zero hits, so every
      Zanshin operation records `workspace_name = None` where a CLI-written one records the
      workspace. Surfaced by this run's op-log-parity claim but crate-wide and pre-existing: the
      fix belongs to a shared transaction-opening helper, not to the convert verbs alone.
    location: >-
      crates/zanshin-jj/src/mutate.rs (and every verb that calls `start_transaction`)
    severity: medium
  - summary: >-
      A conversion that fails after the alias step orphans the secure-config directory it created,
      because the rollback removes only `.jj/` and with it the `config-id` back-pointer.
    evidence: |-
      `create_repo_config_file` calls `SecureConfig::load_config`, which creates
      `<config_dir>/jj/repos/<id>/` with a `metadata.binpb` and writes `.jj/repo/config-id`. The
      rollback in both verbs deletes `.jj/` (2.12 D4 / 2.13's `created_dir` branch) and never
      reaches outside it, so the directory is left with a metadata back-pointer to a path that no
      longer exists. The CLI cannot produce this state because it never rolls back. Documented in
      three rustdoc blocks; not fixed, because extending the rollback outside `.jj/` is a change to
      the no-data-loss invariant's stated reach, which the intent froze.
    location: >-
      crates/zanshin-jj/src/convert.rs::convert_colocated / convert_import (rollback arms)
    severity: low
  - summary: >-
      The `LazyLock` env-var pin used by the test suites is only sound because every test remembers
      to call `pin_env()` first; nothing states or enforces it.
    evidence: |-
      `tests/convert.rs`, `tests/git_remotes.rs`, `tests/git_sync.rs` and `tests/repo_ffi.rs` all
      set `JJ_CONFIG` / `GIT_CONFIG_GLOBAL` / `XDG_CONFIG_HOME` from a `LazyLock` forced inside
      whichever test body wins the race, while sibling test threads are already running — the
      `unsafe` that Rust 2024's `env::set_var` signature is warning about. The pattern predates
      this run (follow-up J introduced it), and this run only widened its blast radius: a test that
      forgets `pin_env()` now writes a `trunk()` alias into the developer's real `~/.config`.
      A real fix is a process-start hook (`#[ctor]`) or a serialised harness, project-wide.
    location: >-
      crates/zanshin-jj/tests/convert.rs:20-42 (and the three sibling suites)
    severity: low
---

<intent-contract>

## Intent

**Problem:** `convert_colocated` (2.12) and `convert_import` (2.13) diverge from `jj git init`'s
External branch in three on-disk ways: they write ONE operation with a description the CLI never
writes (`"convert to colocated"` / `"import git repo"`) where the CLI writes up to two
(`import git refs`, `import git head`) each guarded by `has_changes()`; they never seed
`.jj/.gitignore`; and they never write the repo-level `revset-aliases.'trunk()'`. Story 2.13's
Decision D10 classed the latter two as "CLI-UX/convenience" and D4 classed the op fold as
"cosmetic". Ralph's rule of 2026-09-06 overturns both: the op log IS on-disk state and undo
granularity IS observable behaviour — a user must be able to `jj undo` with the CLI what Zanshin
did, and land in the same state. Ledger entry:
`_bmad-output/implementation-artifacts/deferred-work.md`, section `## Lifted 2026-09-06 …`.

**Approach:** Port `do_init`'s `GitInitMode::External` arm verbatim into both verbs — the same
transaction boundaries, the same descriptions, the same skip-when-no-changes rules, the same
`git::export_refs` for the colocated case, and the two repo-side effects in the CLI's own order.
The `trunk()` writer becomes the fourth member of the `config.rs` writer family follow-up J
started, built on jj-lib's own `SecureConfig` so the file lands exactly where the CLI puts it. The
one part deliberately left behind is the working-copy `reset` the CLI pairs with its colocated head
import — that needs the locked-working-copy lifecycle owned by Story 9.22 (project decision D2:
Zanshin never snapshots). Closing run for that one ledger entry.

## Boundaries & Constraints

**Always:**
- **The oracle is `cli/src/commands/git/init.rs::do_init` @ v0.44.0, arm `GitInitMode::External`,
  read at the pinned tag — NOT the ledger's prose.** Two of the ledger's citations are stale and
  the oracle wins: (a) at 0.44.0 `maybe_set_repository_level_trunk_alias` is NOT guarded by
  `get_single_remote`; it tries `refs/remotes/upstream/HEAD` then `refs/remotes/origin/HEAD`, stops
  at the first remote that HAS such a reference (whether or not it parses), and writes the alias
  only when that reference's symbolic target parses as a `GitRefKind::Bookmark`; (b)
  `maybe_add_gitignore` does not seed `.jj/` into the workspace's `.gitignore` — it writes the
  literal `/*\n` to `<workspace_root>/.jj/.gitignore`, and ONLY when the working copy is shared
  with git (colocated).
- **The CLI's op sequence, exactly.** `init_git_refs` opens one transaction, runs `import_refs`
  with `abandon_unreachable_commits: false` + `record_synthetic_predecessors: false` (the rest off
  config), returns with NO operation when `!tx.repo().has_changes()`, calls `git::export_refs`
  when colocated, and commits `import git refs`. The head import is a second transaction committed
  as `import git head` only when `has_changes()`. Both verbs' existing hardcoded
  `GitImportOptions` already equal the CLI's overrides for this flow — leave them and document why
  (`remote_auto_track_bookmarks` staying empty is a SEPARATE ledger item, not this run's).
- **Order, per the CLI:** refs op → `.jj/.gitignore` (colocated only) → head op (colocated) →
  `trunk()` alias → head op (non-colocated). Colocation is decided by the existing `is_colocated`
  helper, which already ports `is_colocated_git_workspace`, so `convert_import` with
  `dest == source` (D5) takes the colocated shape.
- **The alias goes where the CLI puts it.** `write_repo_presets` resolves through
  `ConfigEnv::repo_config_path(ui)` = `SecureConfig::load_config` with creation forced, so the file
  is `<config_dir>/jj/repos/<new-id>/config.toml` and `.jj/repo/config-id` is created alongside.
  Use jj-lib's `SecureConfig` rather than re-implementing config-id generation or writing the
  legacy `.jj/repo/config.toml` (which the CLI would later migrate, with a warning). When no
  `<config_dir>` can be determined, skip silently — the CLI's own "couldn't find the user's home
  directory" branch, and the same condition under which `add_secure_layer` skips the repo layer.
- **Failure handling is unchanged.** Any step failing yields `RepoError::ConvertFailed` and the
  existing rollback (only `.jj/`, never `.git/`, never the source; 2.13's `created_dir` branch).
  No new error variant, no new `error.code`. Note in rustdoc that this is stricter than the CLI,
  which leaves the converted repo in place, and that a rolled-back conversion can orphan the
  secure-config directory it created.
- **Coverage:** `crates/zanshin-jj/src/{convert.rs,config.rs}` are both at `100.00` in
  `coverage-baseline.txt`. Every new line must be executed by a test, so keep each `map_err`
  closure on the SAME line as its fallible call (the established idiom in both files) and make
  every `else`/early-return branch reachable from a test — including the non-git-backend branch of
  the alias reader (an inline unit test on a `Workspace::init_simple` workspace, the sibling of
  the existing `is_colocated_with_simple_backend_returns_false`).
- Public signatures stay `jj_lib`-type-free; new items are `pub(crate)` or private. No `unwrap`/
  `expect`/`panic!` on any FFI-reachable path (`rand::make_rng()` is therefore NOT the seeding
  route). Clippy pedantic clean with no new `#[allow]`. SPDX first line on any new file.
- Tests must be hermetic: `convert.rs`'s `pin_env` currently pins only `JJ_CONFIG` and
  `GIT_CONFIG_GLOBAL`, so it must also pin `$XDG_CONFIG_HOME` to a process-lifetime temp dir —
  the pattern `crates/zanshin-jj/tests/git_remotes.rs:39-53` already established — or the alias
  write lands in the developer's real `~/.config`.

**Block If:**
- `SecureConfig::load_config` cannot be reached without a dependency that is NOT already in
  `Cargo.lock` as a jj-lib transitive → HALT, blocking condition `config-id creation unavailable`.
- The codegen diff changes an `extern "C"` parameter's TYPE, NAME or ORDER → HALT, blocking
  condition `unexpected codegen drift`. (Doc-comment hunks are EXPECTED.)

**Never:**
- No port of `print_trackable_remote_bookmarks`, of `print_git_import_stats_summary` /
  `print_git_export_stats`, or of the `ui.status` lines (`Setting the revset alias …`, `Done
  importing changes …`) — terminal UX.
- No working-copy snapshot and no `locked_wc().reset()` anywhere: the CLI's colocated
  `import_git_head` pairs its operation with a working-copy reset, and that half stays with Story
  9.22. `convert_import`'s existing non-colocated `check_out` + `workspace.check_out`
  materialisation is untouched — it already ports the CLI's own non-colocated branch.
- No `remotes.<name>.auto-track-bookmarks` work, no `write_repo_presets` `fetch-bookmarks`/
  `fetch-tags` half (that is clone/Story 9.20 territory), no general config-write API beyond the
  one call site.
- No change to any verb signature, `.fbs` schema, or `extern "C"` symbol; no new error code; no
  fixture regeneration; no `#[ignore]`; no lowered baseline or new `exclude_prefix`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Colocated, repo with a commit | `convert_colocated` over a `.git` with `main` + HEAD | op log newest-first: `import git head`, `import git refs`, `add workspace 'default'`, root | No error expected |
| Import, repo with a commit | `convert_import(source, dest)` | same two descriptions, in the same order | No error expected |
| No refs at all | source with an unborn branch (no commits) | NO `import git refs` op and NO `import git head` op are written | No error expected |
| Undo granularity | `Repo::undo` after `convert_import` | reverts only the head import: imported bookmarks survive, the working-copy commit reverts to the pre-head-import one | No error expected |
| Colocated gitignore | `convert_colocated` succeeds | `<root>/.jj/.gitignore` contains exactly `/*\n` | No error expected |
| Non-colocated gitignore | `convert_import` into a separate dest | NO `.jj/.gitignore` is written | No error expected |
| `trunk()` from origin | source cloned so `refs/remotes/origin/HEAD` → `refs/remotes/origin/main` | repo config gets `revset-aliases.'trunk()' = 'main@origin'`; `Repo::eval_revset("trunk()")` resolves to that commit | No error expected |
| `upstream` wins | both `refs/remotes/upstream/HEAD` and `…/origin/HEAD` exist | the alias names `@upstream`; `origin` is not consulted | No error expected |
| Unparseable remote HEAD | `refs/remotes/origin/HEAD` is a direct (non-symbolic) ref | NO alias is written, and the loop stops there (does not fall through to a later remote) | No error expected |
| No remote HEAD ref | a plain `git init` source, no `refs/remotes/*` | NO alias is written and NO repo config file is created | No error expected |
| No `<config_dir>` | neither `$HOME` nor an absolute `$XDG_CONFIG_HOME` | the alias step is skipped silently; conversion still succeeds | No error expected |
| Alias write fails | the secure-config root cannot be created | conversion fails and rolls back (`.jj/` removed, source untouched) | `RepoError::ConvertFailed` |
| Existing rollback rows | 2.12/2.13's failure fixtures | unchanged: partial `.jj/` removed, pre-existing dest dir survives, `.git/` byte-identical | Unchanged codes |

</intent-contract>

## Code Map

Anchors read against the working tree at baseline `7e799c0`.

**Oracle (read-only, `git -C ../jj show v0.44.0:<path>`)**
- `cli/src/commands/git/init.rs:197-234` mode selection (an existing `.git` under `--colocate`
  AND `--git-repo=<path>` both land in `External`); `:244-272` the External arm — the exact call
  order this spec's "Order" bullet reproduces; `:285-320` `init_git_refs` (the `GitImportOptions`
  overrides, the `!has_changes()` early return with NO op, the colocated `git::export_refs`, and
  `tx.commit("import git refs")`); `:324-364` `maybe_set_repository_level_trunk_alias`;
  `:366-404` `print_trackable_remote_bookmarks` (NOT ported).
- `cli/src/commands/git/mod.rs:110-123` `maybe_add_gitignore` (`/*\n` into `.jj/.gitignore`, only
  when `working_copy_shared_with_git`); `:133` `TRUNK_CONFIG_NAME`; `:156-193`
  `write_repo_presets` (early return when all presets are `None`; `repo_config_path` ⇒ the file is
  CREATED; `set_value(TRUNK_CONFIG_NAME, symbol.to_string())`; `save()`).
- `cli/src/cli_util.rs:1298-1326` `snapshot_impl` (colocated ⇒ `import_git_head`, then
  `snapshot_working_copy`, then `import_git_refs`); `:1352-1416` `import_git_head` — the op
  `import git head` is written only after `import_head` reports changes, and the CLI pairs it with
  `locked_wc().reset()` (the 9.22 half); `:1428-1460` `import_git_refs`; `:372-388`
  `settings_for_new_workspace` (calls `reset_repo_path`, which is why `repo_config_path` resolves
  at all during init).
- `cli/src/config.rs:535-549` `maybe_repo_config_path` vs `repo_config_path` (the `force` flag is
  the create-or-not switch); `:447-469` `load_secure_config`.

**jj-lib 0.44.0 (vendored, all `pub`)**
- `secure_config.rs:166` `SecureConfig::new_repo(repo_dir)`; `:407-421` `load_config(&mut
  ChaCha20Rng, root_config_dir)` — generates the id, creates `<root>/<id>/`, writes the metadata
  and `.jj/repo/config-id` atomically, returns `LoadedSecureConfig { config_file, .. }`.
- `git.rs:337` `parse_git_ref(&GitRefName) -> Option<(GitRefKind, RemoteRefSymbol)>`; `:424`
  `get_git_repo(store) -> Result<gix::Repository, UnexpectedGitBackendError>`; `:518-525`
  `GitImportOptions` (exactly three fields); `:1287` `export_refs(&mut MutableRepo)` (sync).
- `workspace.rs:132-159` `init_working_copy` — every `Workspace::init_*` already writes an
  `add workspace 'default'` op with a root-commit working copy, so that op is the baseline both
  verbs build on and the state `undo` falls back to.
- `rand_chacha 0.10.0` re-exports `rand_core` (`SeedableRng::from_seed([u8; 32])`);
  `getrandom 0.4.2::fill(&mut [u8]) -> Result<(), Error>`. Both are already in `Cargo.lock` as
  jj-lib transitives.

**`zanshin-jj`**
- `src/convert.rs:209-242` `convert_into` (the colocated fold to split); `:244-316` `import_into`
  (`:248-251` the "we fold into one" rustdoc to delete, `:279-307` the fold, `:289-304` the
  non-colocated `check_out` block to KEEP, `:310-313` the working-copy materialisation to KEEP);
  `:188-207` `is_colocated` (reuse as the colocation decision); `:318-351` inline tests (the
  `init_simple` pattern the alias reader's error-branch test copies).
- `src/config.rs:142` `TRUNK_CONFIG_NAME`; `:303-326` `secure_config_path` (READ resolver — the
  write path must agree with it); `:519-536` the writer-family banner + `write_error`;
  `:552-592` `load_repo_config_file` / `existing_repo_config_file` (the split-for-testability
  pattern to mirror); `:602-612` `trunk_symbol`; `:632-698` the two shipped writers;
  `:219-245` `ConfigEnv::from_env` + `root_config_dir`.
- `src/repo.rs:155` `Repo::op_log(Option<usize>)` — reverse-chronological, newest first;
  `:645` `Repo::undo`; `:530` `Repo::eval_revset`.
- `src/op_log.rs:26-49` `Operation` (`description` is the field the new rows assert);
  `:187-197` `restored_view` — `wc_commit_ids` come from the target op, `git_head` does not.

**FFI / Dart / docs**
- `crates/zanshin-ffi/src/repo.rs:666-690` `zanshin_repo_convert` rustdoc (`:672-673` the
  "only writes `.jj/`" sentence to correct); `tests/repo_ffi.rs:573-637` the three convert rows.
- `packages/zanshin_core/lib/src/ffi/repo.dart:85-97`; `worker/isolate.dart:642-653` — error
  lists are unchanged (no new code); only a prose claim would need touching.
- `docs/ffi-abi.md:319` index row and `:419-452` the section (`:425-427` the "writes only `.jj/`
  — no working-copy I/O, no `@`-reparent, no snapshot" sentence, now incomplete).
- `docs/rust-error-codes.md:48-52` — convert rows; no op descriptions are named there.
- `_bmad-output/implementation-artifacts/2-13-…-convert-import.md:152-166` D4, `:201-203` D10,
  `:452`, `:480`, `:504`; `deferred-work.md:275` the ledger bullet.

**Test surface**
- `crates/zanshin-jj/tests/convert.rs:18-25` `pin_env` (to extend); `:34-60` `git_head_ids`;
  `:63-94` `git`/`git_stdout`/`init_git_repo_with_commit`; `:129` the `.git`-untouched row that
  `export_refs` must not break; `:252`, `:614`, `:701` the rollback rows that must keep passing;
  `:751` the `dest == source` colocated row.
- `crates/zanshin-jj/tests/git_remotes.rs:39-53` the `$XDG_CONFIG_HOME` pin to copy.

## Tasks & Acceptance

**Execution:**
- `Cargo.toml` (workspace) + `crates/zanshin-jj/Cargo.toml` -- add `rand_chacha` and `getrandom`
  as exact-pinned workspace dependencies at the versions already in `Cargo.lock`, each with an
  inline `# WHY:` naming the single call site (seeding the `ChaCha20Rng` that
  `SecureConfig::load_config` requires). Do not add `rand` — `rand::make_rng()` can panic.
- `crates/zanshin-jj/src/config.rs` -- extend the writer family with, all `pub(crate)` or private:
  a create-mode resolver `create_repo_config_file(repo_dir: &Path, root_config_dir: Option<&Path>)
  -> Result<Option<ConfigFile>, ConfigError>` (seed the rng via `getrandom::fill` +
  `SeedableRng::from_seed`, call `SecureConfig::new_repo(...).load_config(...)`, then
  `ConfigFile::load_or_empty`; `None` root ⇒ `Ok(None)`), its `&Workspace` wrapper, and
  `set_trunk_alias(file: Option<ConfigFile>, symbol: &str) -> Result<(), ConfigError>` (one
  `set_value(TRUNK_CONFIG_NAME, symbol)` + `save()`, errors through the existing `write_error`).
  Extend the module doc and the writer-family banner: this is the family's third member and the
  FIRST that creates a file — say why that is correct here and wrong for remove/rename.
- `crates/zanshin-jj/src/config.rs` (inline tests) -- cover every new line: a `None` root config
  dir, a successful create (asserting `config-id` appears in the repo dir and the file lands under
  `<root>/<id>/config.toml`), a create whose root cannot be made (error), and `set_trunk_alias`
  writing the exact `revset-aliases.'trunk()' = "…"` line into an empty and into a pre-existing
  file. Hold `config.rs` at 100.00.
- `crates/zanshin-jj/src/convert.rs` -- replace both folded transactions with the CLI's sequence.
  Add three private helpers: `init_git_refs(repo, colocated) -> Result<Arc<ReadonlyRepo>, …>`
  (one transaction, `has_changes()` early return returning the UNCHANGED repo, `export_refs` when
  colocated, `tx.commit("import git refs")`); `maybe_add_gitignore(workspace_root, colocated)`;
  and `maybe_set_trunk_alias(workspace, repo)` (the `["upstream", "origin"]` loop over
  `try_find_reference` + `parse_git_ref`, then `config::set_trunk_alias`). Rewrite the module doc
  and both verbs' rustdoc: name the two operations and their skip rules, the `.jj/.gitignore` and
  `trunk()` side effects, that the colocated head import deliberately omits the CLI's paired
  working-copy reset (Story 9.22, decision D2), and that a failed conversion rolls back further
  than the CLI does and can orphan the created secure-config directory. Delete the "we fold into
  one … cosmetic" paragraph.
- `crates/zanshin-jj/tests/convert.rs` -- extend `pin_env` to pin `$XDG_CONFIG_HOME` and return it,
  then add rows for every I/O-matrix scenario above that needs a real repo: the two op-log shapes,
  the no-refs case, the undo-granularity case, both `.gitignore` cases, the four `trunk()` cases,
  and the alias-write failure. Add an op-log helper that returns the descriptions newest-first.
- `crates/zanshin-ffi/src/repo.rs` -- correct `zanshin_repo_convert`'s rustdoc: it now writes two
  operations with the CLI's descriptions, seeds `.jj/.gitignore`, and may write the repo-level
  `trunk()` alias OUTSIDE `.jj/`. The `# Errors` list is unchanged.
- `cargo make codegen` -- run AFTER the FFI rustdoc is final; commit all generated outputs.
- `docs/ffi-abi.md` -- rewrite the `zanshin_repo_convert` section's effect sentence to match; the
  index row's code list is unchanged.
- `_bmad-output/implementation-artifacts/deferred-work.md` +
  `2-13-…-convert-import.md` -- bookkeeping in the established convention: strike the ledger
  bullet's bold title and append ` — RESOLVED 2026-09-06 (spec-epic-9-followup-k-convert-cli-parity,
  commit <short>): <one line>`, naming precisely which half of the colocated head import is left
  to Story 9.22; append a dated note under Decision D10 saying D10 and D4 are superseded and where
  the port lives.

**Acceptance Criteria:**
- Given a Git repo with one commit and a HEAD, when `convert_colocated` succeeds, then
  `Repo::op_log(None)` reads `["import git head", "import git refs", "add workspace 'default'", ""]`
  newest-first and nothing else, and `.git/`'s ref listing and HEAD are byte-identical to before.
- Given the same repo imported with `convert_import` into a separate destination, when the call
  succeeds, then the op log carries the same two descriptions in the same order and the
  destination's working copy is still materialised from the imported HEAD.
- Given a converted repo whose source had exactly one commit, when `Repo::undo` runs once, then it
  succeeds, the bookmarks imported by the refs operation are still listed, and the working-copy
  commit is the one that existed before the head import.
- Given `cargo make test`, when it completes, then the coverage ratchet is green with no baseline
  entry lowered and both `crates/zanshin-jj/src/convert.rs` and `…/config.rs` still at 100.00.
- Given the shipped docs at every layer, when read, then no live text claims that the two CLI
  operations are folded into one, that the conversion writes only `.jj/`, or that the `trunk()`
  alias and `.gitignore` are out of scope as terminal UX.

## Spec Change Log

### 2026-09-06 — Implementation (commit `2590d7f`)

Where the built change is narrower, wider or shaped differently than the prose above. The
`<intent-contract>` is unchanged; these are corrections to the Code Map, Tasks and Design
Notes. Both oracle corrections the Always bullets called out were confirmed against
`v0.44.0` and shipped as written (no `get_single_remote` guard; `/*` into
`<workspace_root>/.jj/.gitignore`, colocated only).

- **Four private helpers, not three.** The Tasks list names `init_git_refs`,
  `maybe_add_gitignore` and `maybe_set_trunk_alias`; the colocated head import needed a
  fourth, `import_git_head`, because it is the CLI's `cli_util.rs::import_git_head` minus
  its working-copy half and is called from both verbs. Same shape as `init_git_refs`:
  one transaction, `has_changes()` early return handing back the UNCHANGED repo, commit.
- **`convert_colocated` does NOT take the CLI's non-colocated tail, deliberately.** The
  "Order" bullet reads refs op → `.gitignore` → head op (colocated) → alias → head op
  (non-colocated), and `import_into` implements all five. `convert_into` implements the
  first four and stops: it reads `is_colocated` rather than assuming it (a linked git
  worktree, where `.git` is a gitdir POINTER file, is classified `Git` by `detect_repo` and
  reaches this far — a documented 2.12 deferral), but in that shape it must still write no
  working-copy files, because 2.12's D3 promises the colocated verb never does. Running the
  non-colocated tail there would `check_out` + materialise into the user's linked worktree.
  So the colocated verb's head import is unconditional and always the reset-free one.
- **The non-colocated head op's `has_changes()` guard is the COMMIT, not an early return.**
  Writing `if !has_changes() { return Ok(()) }` before the materialisation step makes the
  `new_wc_commit == None` arm of that step unreachable — a region no test can execute, and
  `convert.rs` is baselined at 100.00. The shipped shape binds
  `let new_repo = if tx.repo().has_changes() { Some(tx.commit("import git head")?) } else
  { None }` and materialises under `if let (Some(new_repo), Some(wc_commit))`, which is the
  same behaviour with both arms reachable (the unborn-source rows take the `None` path).
- **`maybe_set_trunk_alias` collapses the CLI's two nested conditions into one `Option`
  chain.** The CLI nests `if let Some(reference_name) = reference.target().try_name()`
  inside `if let Some((GitRefKind::Bookmark, symbol)) = …`. Keeping both nested left the
  inner false arm (a symbolic `HEAD` that parses as something other than a bookmark — a
  tag, say) as an unexecutable region. The chain `try_name → from_utf8 → parse_git_ref →
  matches!(kind, Bookmark)` yields one `Option`, so "no symbolic target" and "not a
  bookmark" share the arm the direct-ref row exercises. Observable behaviour is identical:
  either way no alias is written and the loop still stops at that remote.
- **The alias-write-failure row lives in its own test binary.** Tasks put every new row in
  `crates/zanshin-jj/tests/convert.rs`, but `config.rs` reads `$XDG_CONFIG_HOME` from the
  PROCESS environment on every call, and the rest of that file's rows need it pointing at a
  writable directory. Cargo gives each `tests/*.rs` its own binary, so
  `crates/zanshin-jj/tests/convert_alias_write_failure.rs` sets a broken
  `$XDG_CONFIG_HOME` (a regular file at `<xdg>/jj`) hermetically. Mutating it from a
  `#[test]` sharing a process with the others would be a data race on the environment.
- **The "No `<config_dir>`" matrix row is a unit row, for the same reason.** It cannot be
  built from an integration test without unsetting `$HOME` and `$XDG_CONFIG_HOME` for the
  whole process; `config.rs::create_without_a_config_dir_writes_nothing_and_the_writer_is_a_no_op`
  covers both the `Ok(None)` resolver arm and `set_trunk_alias(None, …)` instead.
- **The created file carries jj-lib's own header and quoting.** `ConfigFile::load_or_empty`
  stamps a document it had to invent with `#:schema https://docs.jj-vcs.dev/latest/config-schema.json`
  and re-emits the alias key double-quoted (`"trunk()" = "main@origin"`), not in the
  `'trunk()'` spelling the shipped repo-config fixtures use. Both are jj-lib's, so
  `jj git init` produces the same bytes; the tests pin the whole string.
- **`create_repo_config_file` maps rather than matches its `Option`.** The Tasks sketch
  implies a `let … else` around `loaded.config_file`; `load_config` always fills it, so that
  arm would be unexecutable. `.map(…).transpose()` — the shape the CLI's own
  `new_repo_config_file` uses — has no dead branch.
- **The FFI rustdoc must not contain the literal `/*`.** cbindgen copies it verbatim into
  the C header, where it is a `'/*' within block comment` warning, and ffigen refuses to
  generate bindings from a header with warnings. `zanshin_repo_convert`'s doc therefore
  describes the `.jj/.gitignore` in words instead of quoting its contents. The generated
  diff is doc-comment-only in both `zanshin_ffi.h` and `bindings.dart` — no signature drift,
  so the `unexpected codegen drift` block-if did not fire.
- **`write_error`'s rustdoc was widened, not rewritten.** It claimed both of its
  instantiations were unreachable-by-construction because the two remote writers rule the
  failure out with `as_str()`. There are now four call sites and two reachable
  instantiations (`ConfigFileSaveError` via the unwritable-file rows, `SecureConfigError`
  via the uncreatable-root row); the note names them.

## Review Triage Log

### 2026-09-07 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 12: (high 0, medium 5, low 7)
- defer: 5: (high 0, medium 3, low 2)
- reject: 14: (high 0, medium 1, low 13)
- addressed_findings:
  - `[medium]` `[patch]` `import_into`'s `maybe_set_trunk_alias` call was exercised by NO test —
    all four alias rows drive `convert_colocated`, and every `convert_import` row builds a source
    with no `refs/remotes/*/HEAD`, so deleting the line broke nothing. Added
    `convert_import_sets_the_trunk_alias_on_the_destination`, which converts a CLONED source and
    asserts the destination's own `config-id` and alias file; verified by hand that removing the
    call fails it.
  - `[medium]` `[patch]` The D5 (`workspace_path == git_repo_path`) branch of `import_into` gained
    three behaviours — the colocated `.jj/.gitignore`, the colocated `import_git_head` operation
    and the early return that skips the non-colocated head import — and
    `convert_import_into_same_dir_is_colocated` still asserted only `.jj`/`.git` presence. It now
    asserts the op-log descriptions and the `.gitignore`.
  - `[medium]` `[patch]` The non-colocated head transaction has its OWN `has_changes()` guard,
    separate from the two in `init_git_refs` / `import_git_head`, and no `convert_import` row with
    an empty source read the op log — so dropping it would have shipped a spurious `import git
    head` operation undetected. `convert_import_unborn_branch_source_succeeds` now asserts the op
    descriptions.
  - `[medium]` `[patch]` "`.git/` is never touched" became literally false: `init_git_refs` calls
    `git::export_refs` for a colocated workspace, which WRITES git refs (it writes back exactly
    what it just imported, which is why the 2.12 ref-invariance row still passes). Corrected at
    every layer that carries the claim to the guarantee actually held — no user-visible ref and no
    HEAD is moved, and the rollback never deletes or rewrites `.git/`.
  - `[medium]` `[patch]` Hermeticity: convert now writes OUTSIDE the repo, into
    `$XDG_CONFIG_HOME/jj/repos/`, but only the three suites that assert the alias pinned that
    variable. `crates/zanshin-ffi/tests/repo_ffi.rs` and `crates/zanshin-jj/tests/git_sync.rs` also
    call a convert verb and were safe only because their fixtures happen to have no remote HEAD;
    both now pin it.
  - `[low]` `[patch]` `cargo make codegen` had not been re-run after the last rustdoc re-wrap, so
    `zanshin_ffi.h` and `bindings.dart` carried a different line-wrapping than
    `crates/zanshin-ffi/src/repo.rs`. Re-run; the diff is doc-comment-only, no signature drift.
  - `[low]` `[patch]` `zanshin_repo_convert`'s `# Errors`, `docs/ffi-abi.md` and
    `docs/rust-error-codes.md` still described `jj.convert_failed` as "a jj-lib failure during
    conversion" after `convert_colocated`'s own rustdoc was widened to include config-write
    failures. Widened to match; no new code minted.
  - `[low]` `[patch]` The module doc's numbered step list claimed both verbs port the External arm
    "step for step" with one order, but the non-colocated verb runs 1, 2, 4 and then an inline head
    import that does not go through `import_git_head`. Both shapes are now stated.
  - `[low]` `[patch]` `config.rs`'s heading "exactly three verbs write" sat above a module whose
    `create_repo_config_file` also writes a directory, `metadata.binpb` and `.jj/repo/config-id`
    without being a verb. Reworded so the invariant it asserts is exactly true.
  - `[low]` `[patch]` The comment above the ref-snapshot assertion in
    `convert_colocated_writes_the_two_cli_operations` read as if it verified that `export_refs`
    ran; the assertion holds either way, and per the CLI's own comment the export only has an
    effect once `remote_auto_track_bookmarks` creates local bookmarks — a map this crate hardcodes
    empty. Rewritten to say what it actually pins.
  - `[low]` `[patch]` `tests/convert.rs`'s `ENV_GUARD` SAFETY note claimed the `set_var` runs
    "before any test body runs"; it runs INSIDE whichever test wins the `LazyLock` race. The note
    now states the invariant that actually makes it sound and the consequence of forgetting
    `pin_env()`.
  - `[low]` `[patch]` `repo_config_path` turned ANY read error into `None`, so the three "no alias
    was written" rows could pass vacuously; only `NotFound` is treated as absence now.

## Design Notes

**Why `SecureConfig` and not the legacy path.** Zanshin's `config.rs` deliberately never wrote a
config file until follow-up J, and its READ resolver (`secure_config_path`) falls back to
`.jj/repo/config.toml` when no `config-id` exists. Writing the alias there would be read correctly
by both tools — but the CLI would then MIGRATE it on its next run (new secure dir, symlink left
behind, a status line), which is a different on-disk end state than `jj git init` produces. Calling
jj-lib's own `SecureConfig::load_config` reproduces the CLI's layout exactly, including the
metadata file and the atomic `config-id` write, without re-implementing id generation. The cost is
two dependencies whose only job is to hand that call a `ChaCha20Rng`.

**Seeding without a panic.** `rand_core` 0.10 dropped `from_os_rng`, and `rand::make_rng()` —
what the CLI uses — `expect`s on OS-RNG failure, which no FFI-reachable path may do:

```rust
let mut seed = [0_u8; 32];
getrandom::fill(&mut seed).map_err(|e| ConfigError::Load { reason: describe(&e) })?;
let mut rng = ChaCha20Rng::from_seed(seed);
```

**The 9.22 boundary, precisely.** The CLI's colocated head import
(`cli_util.rs::import_git_head`) does four things: `git::import_head`, an early return when it
changed nothing, `check_out` + `locked_wc().reset(&wc_commit)`, and `maybe_commit_transaction(tx,
"import git head")`. This run ports the first, second and fourth. The `reset` needs
`start_working_copy_mutation` — the locked-working-copy lifecycle Story 9.22 owns — and reversing
project decision D2 ("Zanshin never snapshots") is not this run's call. Consequence to state in
the rustdoc and the ledger: after a Zanshin colocated conversion the op log matches the CLI's, but
`@` has not been re-parented onto the imported HEAD; it settles on the first snapshot, exactly as
2.12's D3a already documented.

**Why `export_refs` cannot break the `.git`-untouched row.** `convert_git_repo_does_not_modify_git_dir`
compares HEAD and the full ref listing before and after. On a fresh colocated conversion the jj
bookmarks were just imported FROM those same git refs, so the export writes the same values it
read and only records jj's export view. If the row fails, that is a real finding, not a test to
relax.

## Verification

**Commands:**
- `cargo make codegen` -- expected: only doc-comment hunks in `zanshin_ffi.h` / `bindings.dart`;
  no signature drift.
- `cargo make test` -- expected: exit 0, run unpiped and synchronously (~15 min), including clippy
  pedantic, `dart analyze`/`format`, `cargo deny check advisories bans` (the two new dependencies
  must pass) and a green coverage ratchet.

**Manual checks (if no CLI):**
- `git diff` on `coverage-baseline.txt`: entries may rise, none may fall.
- The two bookkeeping files parse, and the ledger resolution names the 9.22 remainder explicitly.

## Auto Run Result

Status: done
Blocking condition: none

### Summary

`convert_colocated` and `convert_import` now run `do_init`'s `GitInitMode::External` arm step for
step instead of folding it into one operation with a description the CLI never writes. Both write
`import git refs` (with `git::export_refs` when colocated) and then `import git head`, each only
when its import reports `has_changes()`, so a source with no refs writes neither and a `jj undo`
issued from either tool lands in the same state. A colocated conversion also seeds
`.jj/.gitignore` with the literal `/*`, and both verbs write `revset-aliases.'trunk()'` into the
repo-level config file when `refs/remotes/upstream/HEAD` or `refs/remotes/origin/HEAD` names a
bookmark. `config.rs` gains the writer family's third member and its first CREATING resolver,
built on jj-lib's own `SecureConfig::load_config`, so the alias lands where `jj git init` puts it —
`<config_dir>/jj/repos/<config-id>/config.toml` plus `metadata.binpb` and an atomic
`.jj/repo/config-id` — rather than in the legacy file the CLI would later migrate.

Two of the ledger bullet's own citations were stale and the v0.44.0 oracle won: at that tag
`maybe_set_repository_level_trunk_alias` has NO `get_single_remote` guard, and
`maybe_add_gitignore` writes `<root>/.jj/.gitignore`, not a `.jj/` line in the workspace's
`.gitignore`. Both corrections are recorded in the spec, the code and the ledger resolution.

### Files changed

- `crates/zanshin-jj/src/convert.rs` — the two folded transactions replaced by the CLI's sequence,
  plus four private helpers (`init_git_refs`, `maybe_add_gitignore`, `import_git_head`,
  `maybe_set_trunk_alias`) and rewritten module/verb rustdoc.
- `crates/zanshin-jj/src/config.rs` — `create_repo_config_file` / `new_repo_config_file` /
  `set_trunk_alias`, the family's create mode, with seven new inline unit rows.
- `crates/zanshin-jj/tests/convert.rs` — twelve new or extended rows: both op-log shapes, the
  no-refs case, undo granularity, both `.gitignore` cases, five `trunk()` cases (including one
  through `convert_import`), the D5 same-dir shape and the unborn-source op log; `pin_env` now
  pins `$XDG_CONFIG_HOME`.
- `crates/zanshin-jj/tests/convert_alias_write_failure.rs` (new) — the alias-write failure and its
  rollback, in its own binary because it needs a broken `$XDG_CONFIG_HOME`.
- `crates/zanshin-ffi/tests/repo_ffi.rs`, `crates/zanshin-jj/tests/git_sync.rs` — the same
  `$XDG_CONFIG_HOME` pin, since both call a convert verb.
- `crates/zanshin-ffi/src/repo.rs`, `crates/zanshin-ffi/include/zanshin_ffi.h`,
  `packages/zanshin_core/lib/src/ffi/bindings.dart`, `docs/ffi-abi.md`,
  `docs/rust-error-codes.md` — the convert wrapper's documented effects and the widened
  `jj.convert_failed` description; the two generated files come from `cargo make codegen`.
- `Cargo.toml`, `crates/zanshin-jj/Cargo.toml`, `Cargo.lock` — `rand_chacha` and `getrandom`,
  exact-pinned to versions already in the lockfile, for the one `ChaCha20Rng` seed.
- `_bmad-output/implementation-artifacts/deferred-work.md` — the ledger bullet struck through and
  resolved; five new deferrals recorded.
- `_bmad-output/implementation-artifacts/2-13-implement-external-git-import-conversion-convert-import.md`
  — a dated note under Decision D10 recording that D10 and D4 are superseded and where the port
  lives.

### Review findings breakdown

- Patches applied: 12 (high 0, medium 5, low 7) — see the Review Triage Log.
- Items deferred: 5 (medium 3, low 2) — recorded in this spec's `deferred:` frontmatter and in the
  central ledger under `## Deferred from: spec-epic-9-followup-k-convert-cli-parity (2026-09-06)`.
- Items rejected: 14 (medium 1, low 13) — chiefly findings that would diverge from the CLI rather
  than towards it (the trunk symbol's remote assumption and the unchecked `export_refs` stats are
  the CLI's own behaviour), the request for a distinct `jj.config_error` on convert (error codes
  were frozen by the intent), the request to spread `GitImportOptions` off config (behaviourally
  identical today, since the only config-derived field is one no verb in this crate populates),
  and a claim that `coverage-baseline.txt` should have been committed (coverage held at 99.26 %,
  so the ratchet rewrote nothing).
- Follow-up review recommended: **true** — patched counts high 0, medium 5, low 7; score
  3 × 5 + 1 × 7 = 22, which is ≥ 5.

### Verification performed

- `cargo make codegen` — run twice (once to repair a stale wrap, once after the review patches);
  the final diff in `zanshin_ffi.h` and `bindings.dart` is doc-comment-only, no parameter type,
  name or order drift, so the `unexpected codegen drift` block-if never fired.
- `cargo make test` — run unpiped and synchronously by this session after implementation
  (405 s, exit 0) and again after the review patches (416 s, exit 0). Both green across
  `cargo test`, clippy pedantic, rustfmt, `flutter test`, `dart analyze`/`format`, `cargo deny`
  and the coverage ratchet: `coverage held at 99.26% (8961/9028)`, `extern-coverage: OK`.
- `git diff coverage-baseline.txt` is empty — nothing lowered, no `exclude_prefix` added;
  `crates/zanshin-jj/src/convert.rs` and `.../config.rs` both still `= 100.00`.
- Matrix audit: every row of the I/O & Edge-Case Matrix is covered by a named test that ran and
  passed in the final gate (`tests/convert.rs` 41 passed, `tests/convert_alias_write_failure.rs`
  1 passed, plus the `config.rs` inline rows).

### Residual risks

- The colocated `import git head` operation matches the CLI's description and skip rule but not
  its view content: `@` is not re-parented onto the imported HEAD. That is the Story 9.22
  remainder, deferred and documented at six sites.
- A conversion that fails after the alias step leaves the created secure-config directory behind,
  because the rollback reaches only into `.jj/`. Deferred; documented in the rustdoc.
- `remote_auto_track_bookmarks` stays empty in the convert import options, as it does at every
  other import site in the crate — a separate, still-open ledger bullet.
