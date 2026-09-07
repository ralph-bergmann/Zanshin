---
title: 'Epic 9 follow-up L: every Zanshin operation records `op_metadata.workspace_name`'
type: 'bugfix'
created: '2026-09-07'
status: 'done'
baseline_revision: '2e4d7794c8ee8f0855f23771bcb5da9eae208dda'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['oversized']
deferred:
  - summary: >-
      The `reconcile divergent operations` operation still records `workspace_name: None`,
      because jj-lib's `RepoLoader::load_at_head` hardcodes it and the CLI does not use that
      entry point.
    evidence: |-
      `jj-lib-0.44.0/src/repo.rs:706-729` `load_at_head` calls `merge_operations` with a literal
      `let workspace_name = None;` (`:712`) when it finds divergent op heads, so the
      `reconcile divergent operations` operation it writes carries no name. The CLI never calls
      `load_at_head`: `cli/src/cli_util.rs:773-805` `resolve_operation` drives
      `op_heads_store::resolve_op_heads` itself and passes `Some(workspace_name)` into
      `merge_operations` (`:792-799`), so a CLI-written reconcile operation names the workspace.
      This is the same observable field this run fixed, at the same surface, and it is a real
      divergence — but it is not a `start_transaction` call site and not written by a Zanshin
      verb, so the creep guard cannot see it. Closing it means replacing every
      `workspace.repo_loader().load_at_head()` in the crate — 64 sites across 16 modules,
      including every READ verb — with a helper that reproduces the CLI's
      `resolve_op_heads` + `merge_operations(Some(name), …)` shape. That is the head-load path
      (ADR-0002 territory), not the transaction path, and its own run: it needs its own guard,
      and a witness has to fabricate divergent op heads the way
      `crates/zanshin-jj/tests/op_log.rs:525` does.
    location: >-
      crates/zanshin-jj/src (every `repo_loader().load_at_head()` call site)
    severity: medium
---

<intent-contract>

## Intent

**Problem:** The jj CLI opens EVERY transaction through one helper,
`cli/src/cli_util.rs::start_repo_transaction` (`:2883-2894` @ v0.44.0), which calls
`tx.set_workspace_name(workspace_name)`; jj-lib's `Transaction::set_workspace_name`
(`jj-lib-0.44.0/src/transaction.rs:120-122`) writes `op_metadata.workspace_name`, which is
persisted op-log state that `jj op log`/`jj op show` display and multi-workspace repos rely on.
`grep set_workspace_name crates/` has zero hits, so all 14 transaction openers in
`crates/zanshin-jj/src` record `workspace_name = None` where a CLI-written operation names the
workspace. Under Ralph's rule of 2026-09-06 (the op log is on-disk state, so its metadata is
required parity) that is a divergence. Ledger entry:
`_bmad-output/implementation-artifacts/deferred-work.md`, section
`## Deferred from: spec-epic-9-followup-k-convert-cli-parity (2026-09-06)`, bullet
"No Zanshin verb sets the operation's `workspace_name` metadata".

**Approach:** Port the oracle helper — minus the command-arg attributes Zanshin deliberately does
not have — as one crate-internal `op_support::start_repo_transaction(repo, workspace_name)`, route
all 14 call sites through it, and add an inline source-scanning guard test so a future direct
`repo.start_transaction(` cannot creep back in. Closing run for that one ledger bullet.

## Boundaries & Constraints

**Always:**
- **The oracle is `cli/src/cli_util.rs::start_repo_transaction` @ v0.44.0**, read at the pinned
  tag. It does exactly three things: `repo.start_transaction()`, `tx.set_workspace_name(name)`,
  and a loop setting `command_args_to_transaction_attribute(string_args)`. Reproduce the first
  two ONLY — the third encodes a terminal command line, which ADR-0003 replaces rather than
  ports. Nothing else is invented: `hostname`/`username`/`time` already come from jj-lib's
  `create_op_metadata(user_settings, …)`, and `is_snapshot` is not the CLI helper's business.
- **The name is the workspace the `Repo`/`Workspace` was opened for** — jj-lib's
  `Workspace::workspace_name()`. Never a literal `"default"`, never a constant, never derived
  from a path.
- **All 14 `crates/zanshin-jj/src` call sites route through the one helper**, including
  `repo.rs`'s Step-2 throwaway transaction in `clone_into`, which is deliberately dropped without
  committing: routing it costs one identifier and leaves the guard with zero exceptions. Say in a
  `// WHY:` at that site that the metadata is unobservable there and the call is for uniformity.
- **The helper's name must not contain the substring `start_transaction`.** Naming it
  `start_repo_transaction` matches the oracle AND makes the guard's needle — the bare identifier
  `start_transaction` — unambiguous, so the guard also catches a UFCS
  `ReadonlyRepo::start_transaction(&repo)` and never false-positives on a call to the helper.
- **The guard is a unit test, not a lint.** The repo has no `clippy.toml`, and a workspace-root
  `disallowed-methods` entry would fire in `crates/test-helpers`, `crates/xtask` and every
  `crates/zanshin-jj/tests/*.rs`, all of which legitimately open transactions directly. Skip
  comment lines the way `Makefile.toml`'s `test-jj-adapter-hygiene` gate already does, and split
  the scan into a pure function over `(path, contents)` pairs so the negative probe can feed it a
  synthetic violation.
- **Coverage:** `crates/zanshin-jj/src/{convert,op_log,remotes}.rs` are at `100.00` and
  `op_support.rs` at `99.59` in `coverage-baseline.txt`. Every new line — helper body, guard test,
  scanner — must be executed. Entries may rise; none may fall.
- Public signatures stay `jj_lib`-type-free; the helper and any new parameter are `pub(crate)` or
  private. No `unwrap`/`expect`/`panic!` on FFI-reachable paths (test code is exempt). Clippy
  pedantic clean with no new `#[allow]`. SPDX first line on any new file.
- Witness tests are hermetic: pin `JJ_CONFIG`, `GIT_CONFIG_GLOBAL` and — because the convert verbs
  write the repo-level `trunk()` alias outside the repo — `XDG_CONFIG_HOME`, following
  `crates/zanshin-jj/tests/convert.rs:27-47`. No test reaches the network: git remotes are local
  bare clones / `file://` URLs, as in `tests/remotes_write.rs`.

**Block If:**
- Routing a call site would require changing a PUBLIC signature (a `pub fn` on `Repo`, an
  `extern "C"` symbol, or a `.fbs` table) → HALT, blocking condition `public surface change
  required`.
- `cargo make test` reports a coverage regression that cannot be closed by adding a test → HALT,
  blocking condition `coverage regression`.

**Never:**
- No `set_attribute` / `args` / `hostname` / `username` invention, and no `set_is_snapshot`.
- No widening of `crate::Operation` (`op_log.rs:32-49`), the `.fbs` schemas, the FFI surface or
  the Dart payload to EXPOSE `workspace_name` — that is Story 9.21's surface. This run only
  RECORDS the metadata.
- No new error code, no `docs/rust-error-codes.md` row, no `cargo make codegen` run (no
  `extern "C"` signature or rustdoc changes), no fixture regeneration, no `#[ignore]`, no lowered
  baseline, no new `exclude_prefix`, no `clippy.toml`.
- No change to the transaction call sites in `crates/test-helpers`, `crates/xtask` or
  `crates/zanshin-jj/tests/*.rs` — those are test/build-time tools outside the shipped surface and
  outside the guard's scan.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Mutate family | `Repo::describe` on a git-backed workspace | newest op's `metadata().workspace_name == Some("default")` | No error expected |
| Bookmark family | `Repo::bookmark_create` | same, on the `create bookmark …` op | No error expected |
| Git sync family | `Repo::git_import` after a new git ref | same, on the `import git refs` op | No error expected |
| Remote-config family | `Repo::git_remote_add` | same, on the `add git remote …` op | No error expected |
| Fetch (`remotes.rs`) | `Repo::git_fetch` against a local bare clone | same, on the `fetch from git remote(s) origin` op | No error expected |
| Undo (`op_log.rs`) | `Repo::undo` after a mutation | same, on the `undo operation …` op | No error expected |
| Clone (`repo.rs`) | `Repo::clone` from a `file://` bare repo | same, on the `clone` op | No error expected |
| Convert, colocated | `convert_colocated` over a git repo with a commit | both `import git refs` and `import git head` carry the name | No error expected |
| Convert, import | `convert_import(source, dest)` | same two operations on the destination | No error expected |
| Second workspace | `Repo::open(<second workspace root>)` then `describe` | the newest op records `Some("second")`, NOT `"default"` | No error expected |
| Guard, clean tree | the crate's real `src/` | no file outside `op_support.rs` opens a transaction directly | Test fails, naming file:line |
| Guard, synthetic violation | `[("fake.rs", "let mut tx = repo.start_transaction();")]` | the scanner reports exactly that one `fake.rs:1` | No error expected |
| Guard, commented mention | a source line whose trimmed form starts with `//` | the scanner reports nothing | No error expected |

</intent-contract>

## Code Map

Anchors read against the working tree at baseline `2e4d779`.

**Oracle (read-only)**
- `git -C ../jj show v0.44.0:cli/src/cli_util.rs` — `:2883-2894` `start_repo_transaction` (the
  three statements); `:2896-…` `command_args_to_transaction_attribute` (NOT ported);
  `:2286-2298` `WorkspaceCommandHelper::start_transaction`, the sole caller, which passes
  `self.workspace_name()`; `:1550-1552` `workspace_name()` = `self.workspace.workspace_name()`.
- jj-lib 0.44.0 (vendored under `$CARGO_HOME/registry/src/*/jj-lib-0.44.0/src/`):
  `transaction.rs:120-122` `set_workspace_name`; `:176-198` `create_op_metadata` (defaults
  `workspace_name: None`, fills hostname/username from `UserSettings`); `operation.rs:124`
  `Operation::metadata() -> &OperationMetadata`; `workspace.rs:425-427`
  `Workspace::workspace_name() -> &WorkspaceName`; `repo.rs:333` `ReadonlyRepo::start_transaction`.

**The 14 call sites (`grep -n start_transaction crates/zanshin-jj/src`)**
- `mutate.rs:476` `describe`, `:537` `new_change`, `:602` `edit`, `:660` `abandon`, `:865`
  `finish_or_no_op_at`, `:968` `restore`, `:1089` `absorb` — every one already binds
  `let workspace_name = workspace.workspace_name().to_owned();` on the line above its
  `capture_old_wc` call, so each edit is one line. `:865` is the shared skeleton behind ALL of
  `bookmark_ops.rs` (`:203`, `:281`) and `git.rs` (`:318`, `:398`, `:435`, `:476`, `:521`) — those
  two files open no transaction of their own.
- `op_log.rs:158` `undo` — `workspace_name` bound at `:151`.
- `remotes.rs:260` `git_fetch` — takes `workspace: &Workspace`; use `workspace.workspace_name()`.
- `repo.rs:1573` `clone_into` Step 2, the throwaway transaction (`:1580` "intentionally dropped
  without commit"); the workspace is bound as `_workspace_init` at `:1557` and must be renamed to
  `workspace_init` to supply the name. `:1631` `clone_into` Step 4 — `workspace_name` bound at
  `:1592`.
- `convert.rs:314` inside `fn init_git_refs(repo, colocated)` (`:308`), `:353` inside
  `fn import_git_head(repo)` (`:352`), `:484` inline in `import_into`. The two private helpers
  need a `workspace_name: &WorkspaceName` parameter; their callers are `convert_into` (`:414`,
  immutable `workspace` — pass `workspace.workspace_name()`) and `import_into` (`:444`, already
  binds `workspace_name` at `:464`).

**Helper's home**
- `crates/zanshin-jj/src/op_support.rs:3-30` module doc — "the four pieces of rewrite
  orchestration … that live in jj-cli's `cli_util`, not in jj-lib". The helper is a fifth such
  piece; the doc's "four" framing and its numbered list must gain the new section. `:639-669` the
  existing `#[cfg(test)] mod tests` header and `pin_env` pattern; `:1126` end of file.
- `crates/zanshin-jj/src/mutate.rs:28,32` already import `WorkspaceName` and `Transaction`;
  `:35` already imports from `crate::op_support`. `:415-418` `capture_old_wc(&ReadonlyRepo,
  &WorkspaceName)` — the deref shape `&workspace_name` already used at every site.

**Guard precedent (read-only)**
- `Makefile.toml:255-275` `test-jj-adapter-hygiene` — the repo's existing source-grep invariant
  gate, including its "exclude comment lines" rule. Precedent for the scanning rule, not the
  mechanism: this guard is a unit test so it runs under `cargo test` and counts for coverage.

**Test surface**
- `crates/zanshin-jj/tests/convert.rs:27-47` the three-variable env pin (with a leaked
  `TempDir` for `$XDG_CONFIG_HOME`) and `:84-116` `git`/`git_stdout`/`init_git_repo_with_commit`.
- `crates/zanshin-jj/tests/remotes_write.rs:33-50` `make_test_settings`, `:79-90`
  `init_git_repo_with_commits`, `:170-179` `git_bare_clone`, `:189-204` `register_remote`,
  `:208-247` the `git_fetch` happy path.
- `crates/zanshin-jj/tests/git_sync.rs:99-156` `git_repo_with_one_commit` + the `update-ref`
  dance that makes `git_import` write an operation.
- `crates/zanshin-jj/tests/workspace.rs:60-81` the `oracle_workspace` / `Workspace::load` +
  `load_at_head` read pattern; `crates/test-helpers/src/lib.rs:545-574` `add_workspace(root,
  name)`, which creates a SECOND workspace with that name and returns its root.
- `crates/zanshin-jj/tests/repo.rs:~300-315` the `Repo::clone` from a local `file://` bare repo.

**Untouched by design**
- `crates/zanshin-jj/src/op_log.rs:32-49` `Operation` (no `workspace_name` field — 9.21's job);
  `schemas/*.fbs`; `crates/zanshin-ffi/`; `packages/zanshin_core/`; `docs/`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/op_support.rs` -- add a fifth section, `§5 Transaction opening`, holding
  `pub(crate) fn start_repo_transaction(repo: &Arc<ReadonlyRepo>, workspace_name: &WorkspaceName)
  -> Transaction` — two statements, the oracle's first two, with rustdoc naming the oracle by file
  and line, stating that the command-arg attributes are deliberately not ported (ADR-0003 replaces
  the terminal UX), and that this is the crate's ONLY sanctioned transaction opener. Update the
  module doc's "four pieces"/numbered list to five. Add `use jj_lib::ref_name::WorkspaceName;` and
  `use jj_lib::transaction::Transaction;`.
- `crates/zanshin-jj/src/op_support.rs` (inline tests) -- add the creep guard: a pure
  `fn direct_transaction_openers(sources: &[(String, String)]) -> Vec<String>` returning
  `"<path>:<line>"` for every non-comment line containing the identifier `start_transaction`, plus
  three tests — the real-tree scan (walk `env!("CARGO_MANIFEST_DIR")/src` recursively, skip
  `op_support.rs`, assert empty and assert the scan actually saw files), the synthetic-violation
  negative probe, and the commented-mention probe. Also assert `op_support.rs` still contains
  `fn start_repo_transaction`, so deleting or renaming the helper fails the guard too.
- `crates/zanshin-jj/src/mutate.rs` -- route all seven sites through
  `op_support::start_repo_transaction(&readonly, &workspace_name)`; no other change.
- `crates/zanshin-jj/src/op_log.rs` -- route `undo`'s site; `workspace_name` is already in scope.
- `crates/zanshin-jj/src/remotes.rs` -- route `git_fetch`'s site with
  `workspace.workspace_name()`.
- `crates/zanshin-jj/src/repo.rs` -- rename `_workspace_init` to `workspace_init` and route the
  Step-2 throwaway with a `// WHY:` noting the metadata is unobservable on an uncommitted
  transaction and the call is for uniformity with the guard; route the Step-4 site with
  `&workspace_name`.
- `crates/zanshin-jj/src/convert.rs` -- give `init_git_refs` and `import_git_head` a
  `workspace_name: &WorkspaceName` parameter, route all three sites, and pass
  `workspace.workspace_name()` / `&workspace_name` from the two callers. Extend the module doc's
  operation description to say both operations now carry the workspace name, as the CLI's do.
- `crates/zanshin-jj/tests/op_workspace_name.rs` (new) -- the witness suite: the three-variable env
  pin, a `head_op_workspace_name(root) -> Option<String>` oracle that loads the workspace with
  jj-lib and reads `load_at_head().operation().metadata().workspace_name`, and one row per I/O
  matrix scenario that needs a real repo — `describe`, `bookmark_create`, `git_import`,
  `git_remote_add`, `git_fetch`, `undo`, `Repo::clone`, `convert_colocated`, `convert_import`, and
  the two-workspace row built on `test_helpers::add_workspace`. The convert rows assert BOTH
  operations, not just the newest.
- `_bmad-output/implementation-artifacts/deferred-work.md` +
  `spec-epic-9-followup-k-convert-cli-parity.md` -- bookkeeping in the established convention:
  wrap the ledger bullet's bold title in `~~…~~` and append ` — RESOLVED 2026-09-07
  (spec-epic-9-followup-l-op-workspace-name, commit <short>): <one line>`; add a `resolved: >-`
  block scalar to the matching `deferred:` item in follow-up K's frontmatter, keeping the YAML
  parseable.

**Acceptance Criteria:**
- Given the crate's shipped sources, when `grep -rn "start_transaction" crates/zanshin-jj/src`
  runs, then the only hit is inside `op_support.rs`, and `grep -rn "set_workspace_name" crates/`
  has exactly one non-test hit, in that same helper.
- Given a repo opened at its default workspace, when any of the nine witnessed verbs writes an
  operation, then that operation's `workspace_name` is `Some("default")` — never `None`.
- Given a repo with a second workspace named `second`, when a mutation runs through a `Repo`
  opened at the SECOND workspace's root, then the newest operation records `Some("second")`, and
  the first workspace's name appears nowhere in it.
- Given `cargo make test`, when it completes, then it exits 0 and the coverage ratchet is green
  with no baseline entry lowered.
- Given the shipped public surface, when compared with baseline `2e4d779`, then no `pub` signature,
  `.fbs` schema, `extern "C"` symbol, generated header/binding or error code has changed.

## Spec Change Log

## Review Triage Log

### 2026-09-07 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 14: (high 0, medium 1, low 13)
- defer: 1: (high 0, medium 1, low 0)
- reject: 17: (high 0, medium 0, low 17)
- addressed_findings:
  - `[medium]` `[patch]` The anti-requirement "never a hardcoded `default`" was witnessed at
    exactly ONE of the routed sites. Nine of the ten rows run in a workspace literally named
    `default` and assert `Some("default")`, so they pass unchanged against a helper that ignores
    its argument; only `a_verb_run_in_a_second_workspace_records_that_workspace` distinguishes,
    and it drives `describe` alone. Added
    `the_shared_funnel_undo_and_fetch_also_record_the_second_workspace`, which runs
    `bookmark_create` (i.e. `mutate::finish_or_no_op_at`, the skeleton all eleven bookmark and
    git verbs funnel through), `undo` (`op_log.rs`) and `git_fetch` (`remotes.rs`, the one site
    passing `workspace.workspace_name()` inline) through a SECOND workspace's handle. Verified by
    substituting `WorkspaceName::DEFAULT` at `remotes.rs:260`: the ten pre-existing rows stayed
    green and only the new one failed (`left: Some("default")`, `right: Some("second")`).
  - `[low]` `[patch]` The helper's rustdoc called `cli_util.rs:2286-2298` "the CLI's sole
    caller". There are two — the snapshot path at `:2099` follows it with
    `set_is_snapshot(true)`, which is precisely why the next sentence disclaims `is_snapshot`.
    Reworded to "the caller this port mirrors" and the second caller is now named.
  - `[low]` `[patch]` The guard's rustdoc promised the needle "never false-positives", true only
    of calls to the sanctioned helper. A mention in a trailing comment, a `/* … */` block or a
    string literal is a hit. The limitation is now stated, with why over-flagging is the safe
    direction.
  - `[low]` `[patch]` The allow-list used `path.ends_with("op_support.rs")`, a path-suffix match
    that would also exempt a future `git_op_support.rs` — silently, the one way this guard could
    go quiet unnoticed. Now compares `Path::file_name()`.
  - `[low]` `[patch]` The scan's sanity check was `sources.len() > 5`, satisfied by any directory
    holding six `.rs` files. Now asserts `mutate.rs` and `convert.rs` are among the paths, which
    proves it read THIS crate's `src/`.
  - `[low]` `[patch]` The helper claimed to be "the crate's ONLY sanctioned transaction opener"
    without saying what the guard's scope is or why `crates/test-helpers` (12 direct openers) and
    `crates/xtask` (3) are exempt. Both are now stated, together with the reason no other
    production crate can open one (`zanshin-jj` is the sole `jj_lib` importer).
  - `[low]` `[patch]` The module doc's arithmetic broke: "the five pieces of rewrite
    orchestration" over a list numbered 1-5 whose fifth item was labelled `(§6)`, with `§5`
    explained only parenthetically and the wiring-status paragraph never extended. Rewritten as a
    §-labelled list; transaction opening is no longer miscalled rewrite orchestration, and §6's
    wiring status is stated.
  - `[low]` `[patch]` `convert.rs`'s new module-doc paragraph said "all three transactions",
    but no single conversion opens three — three is the count of transaction SITES in the file.
    Corrected, with which site only `import_into` reaches.
  - `[low]` `[patch]` The witness suite's module doc did not state that `bookmark_ops.rs` and
    `git.rs` open no transaction of their own, so its eleven unlisted verbs read as coverage
    oversights rather than as the funnel argument they are. Stated.
  - `[low]` `[patch]` `git_workspace()`'s doc claimed "a git-backed workspace with one jj
    commit"; the body is `Repo::init` and creates none. Corrected.
  - `[low]` `[patch]` `head_op_workspace_name` duplicated `recent_ops`'s whole
    `Workspace::load` + `load_at_head` block. It now delegates to `recent_ops(root, 1)`.
  - `[low]` `[patch]` `recent_ops`'s magic `4` was unexplained. Documented as a cap, not a search
    depth, with why 4 reaches the root for a converted repo.
  - `[low]` `[patch]` The dead `assert_ne!(Some("default"))` in the second-workspace row could
    never fire after the `assert_eq!(Some("second"))` above it; its message was the useful part
    and now lives on the `assert_eq!`.
  - `[low]` `[patch]` The guard's rustdoc said nothing about what a future INLINE `#[cfg(test)]`
    test in `src/` should do when it needs to fabricate repo state — the one legitimate case the
    guard would block. It now points at the sanctioned helper and `test-helpers`.

## Design Notes

**Why `op_support.rs` and not `mutate.rs`.** The module exists precisely to hold "the pieces of
orchestration every thick jj verb needs that live in jj-cli's `cli_util`, not in jj-lib" — and
`start_repo_transaction` is a `cli_util` function by that exact name. `mutate.rs` would work
mechanically but couples `convert.rs` and `repo.rs` (both `RepoError`-domain) to the mutation
family's module for something that is not a mutation.

**Why the helper is named after the oracle.** The guard needs an unambiguous needle. Since
`start_repo_transaction` does not contain the substring `start_transaction`, the guard can scan for
the bare identifier and catch method calls, UFCS calls and comment-free mentions alike, without a
single false positive on calls to the helper itself. Naming the helper `start_transaction` — the
intent's illustrative sketch — would have forced a fragile `.start_transaction(`-with-leading-dot
needle that a UFCS call slips past.

**Shape of the helper** (the whole of it, minus rustdoc):

```rust
pub(crate) fn start_repo_transaction(repo: &Arc<ReadonlyRepo>, workspace_name: &WorkspaceName) -> Transaction {
    let mut tx = repo.start_transaction();
    tx.set_workspace_name(workspace_name);
    tx
}
```

**Why the guard scans rather than lints.** `clippy::disallowed_methods` is configured in a
workspace-root `clippy.toml` with no per-crate scoping, so it would also fire on
`crates/test-helpers` (12 sites), `crates/xtask` (3) and 14 sites across `crates/zanshin-jj/tests`
— all legitimate. Suppressing it in each would be worse than the invariant is worth. The unit test
scopes exactly to `crates/zanshin-jj/src`, runs under plain `cargo test`, and — unlike a
`Makefile.toml` gate — counts toward the coverage ratchet and carries its own negative probe.

**What the two-workspace row proves.** `test_helpers::add_workspace` builds the second workspace
through jj-lib's own `init_workspace_with_existing_repo`, whose `add workspace 'second'` operation
jj-lib already stamps with the name (`jj-lib .../repo.rs:810-811`). The row is only meaningful
because it drives a ZANSHIN verb afterwards through a `Repo` opened at the second root: a
hardcoded `"default"`, or a name read from the repo rather than the workspace handle, fails there
and nowhere else.

## Verification

**Commands:**
- `cargo make test` -- expected: exit 0, run unpiped and synchronously (~15 min); includes
  `cargo test --workspace`, clippy pedantic `-D warnings`, rustfmt, `dart analyze`/`format`,
  `cargo deny check advisories bans` and the coverage ratchet.
- `grep -rn "start_transaction" crates/zanshin-jj/src` -- expected: hits only in `op_support.rs`.
- `grep -rn "set_workspace_name" crates/` -- expected: one hit in `op_support.rs` plus whatever the
  new witness suite reads back.

**Manual checks (if no CLI):**
- `git diff coverage-baseline.txt`: entries may rise, none may fall.
- `git diff --stat` touches no file under `schemas/`, `crates/zanshin-ffi/`, `packages/`, `app/`
  or `docs/`.
- Both bookkeeping files parse: the ledger bullet is struck through with a dated resolution, and
  follow-up K's frontmatter still loads as YAML with the new `resolved:` field.

## Auto Run Result

Status: done
Blocking condition: none

### Summary

Every transaction `crates/zanshin-jj/src` opens now goes through one helper,
`op_support::start_repo_transaction(repo, workspace_name)`, which reproduces the first two of
the three statements in the CLI's `cli_util.rs::start_repo_transaction` (`:2883-2894` @ v0.44.0):
`ReadonlyRepo::start_transaction` and `Transaction::set_workspace_name`. The third — the
`command_args_to_transaction_attribute` loop — encodes a terminal command line that ADR-0003
replaces with a GUI, so it is deliberately not ported, and nothing else is invented
(`hostname`/`username`/`time` already come from jj-lib's own `create_op_metadata`). All 14
previous call sites are routed; the name is always the one the caller's `Workspace` handle was
opened for, never a constant. An operation Zanshin writes therefore names its workspace in
`jj op log`/`jj op show` exactly as a CLI-written one does, where before it recorded
`workspace_name = None`.

No observable surface moved otherwise: no public signature, no `.fbs`, no `extern "C"` symbol, no
generated header or binding, no error code, and `crate::Operation` was NOT widened to expose the
field — that stays Story 9.21's surface.

### Files changed

- `crates/zanshin-jj/src/op_support.rs` -- new `§6 Transaction opening` holding the ported helper,
  plus the creep guard: a pure `direct_transaction_openers` scanner over `(path, contents)` pairs
  and six inline tests (real-tree scan, helper-still-defined probe, subdirectory descent, and
  three scanner probes covering a method call, a UFCS call and comment/sanctioned-helper lines).
  Module doc reworked so the section list and the §-numbers agree.
- `crates/zanshin-jj/src/mutate.rs` -- seven sites routed (`describe`, `new_change`, `edit`,
  `abandon`, `finish_or_no_op_at`, `restore`, `absorb`). `finish_or_no_op_at` is the skeleton all
  of `bookmark_ops.rs` and `git.rs` funnel through, so those two files needed no change.
- `crates/zanshin-jj/src/op_log.rs` -- `undo`'s site routed.
- `crates/zanshin-jj/src/remotes.rs` -- `git_fetch`'s site routed with
  `workspace.workspace_name()`.
- `crates/zanshin-jj/src/repo.rs` -- `clone_into`'s two sites routed; `_workspace_init` renamed so
  the Step-2 throwaway transaction can name its workspace too, with a `// WHY:` explaining that
  the metadata is unobservable on a transaction that is never committed and that routing it keeps
  the guard exception-free.
- `crates/zanshin-jj/src/convert.rs` -- `init_git_refs` and `import_git_head` gained a
  `workspace_name: &WorkspaceName` parameter; all three sites routed; module doc extended.
- `crates/zanshin-jj/tests/op_workspace_name.rs` (new) -- 11 witness rows reading the metadata
  back off the op store via jj-lib, covering every family plus two second-workspace scenarios.

### Review findings breakdown

- **Patches applied: 14** (high 0, medium 1, low 13). The medium one closed the real coverage
  hole: the "never a hardcoded `default`" rule was witnessed at one site only, because every
  other row runs in a workspace that IS called `default`. The rest were doc corrections in text
  this run itself introduced, plus three hardenings of the guard (file-name match instead of path
  suffix, a scan-sanity check that names real modules, scope statement).
- **Deferred: 1** (medium) — `reconcile divergent operations` still records no workspace name,
  because jj-lib's `RepoLoader::load_at_head` hardcodes `None` and the CLI does not use that
  entry point. Verified against both sources; recorded in the frontmatter and in the central
  ledger. It is the head-load path, not the transaction path: 64 call sites across 16 modules,
  including every read verb, and a witness has to fabricate divergent op heads.
- **Rejected: 17** (all low). Notable ones and why: `repo.rs` was said to be inconsistent for
  spelling the helper fully-qualified — that file has zero `use crate::…` imports and 24
  fully-qualified `crate::` references, so the diff matches its convention; `GIT_CONFIG_NOSYSTEM`
  and the duplicated `LazyLock` env pin are instances of a harness item already in the ledger;
  "commit the raised `coverage-baseline.txt`" does not apply because the gate held coverage
  within epsilon and rewrote nothing; and hardening the scanner against block comments and string
  literals was declined because over-flagging is the safe direction for a creep guard.
- **Follow-up review recommended: true** — patched severities were high 0, medium 1, low 13, so
  the score is 3×1 + 1×13 = 16, at or above the threshold of 5.

### Verification performed

- `cargo make test` -- exit 0, run unpiped and synchronously (534 s). Includes
  `cargo test --workspace`, clippy pedantic `-D warnings`, rustfmt, `dart analyze`/`format`,
  `cargo deny check advisories bans` and the coverage ratchet:
  `coverage-check: OK — coverage held at 99.27% (9059/9126 lines)`, `extern-coverage: OK`, and
  `coverage-baseline.txt` unmodified (no entry rose or fell). Run twice — once before the review
  patches (99.25%) and once after.
- **Matrix audit:** all 13 I/O-matrix rows are covered by tests that ran and passed —
  the ten verb/second-workspace rows in `tests/op_workspace_name.rs` and the three guard rows in
  `op_support.rs`'s inline tests (`no_source_file_outside_op_support_opens_a_transaction_directly`,
  `the_scanner_reports_a_synthetic_violation`,
  `the_scanner_ignores_comments_and_the_sanctioned_helper`).
- **Negative probe on the witness suite:** substituting `WorkspaceName::DEFAULT` for
  `workspace.workspace_name()` at `remotes.rs:260` left all ten pre-existing rows green and
  failed only the new second-workspace row — the concrete demonstration that the added test earns
  its place. Reverted immediately.
- **ACs:** `grep -rn start_transaction crates/zanshin-jj/src` hits only `op_support.rs`;
  `grep -rn set_workspace_name crates/` has exactly one code hit, in the helper.
  `git diff --stat` touches nothing under `schemas/`, `crates/zanshin-ffi/`, `packages/`, `app/`
  or `docs/`.

### Residual risks

- The creep guard is textual. It cannot see an operation-writing path that never spells
  `start_transaction` — which is exactly how the deferred `reconcile divergent operations` gap
  hides, and how a future jj-lib entry point that opens its own transaction would too.
- `repo.rs`'s Step-2 throwaway transaction is routed but unobservable by construction (it is
  dropped without committing), so for that one site the guard is the only enforcement.
- `convert.rs`'s three sites and `repo.rs`'s clone CREATE the workspace they name, so `default`
  is the only answer they can give and no second-workspace row can exist for them; their names
  are pinned structurally (they read `Workspace::workspace_name()`) rather than behaviourally.
- The committed fixtures under `test-fixtures/repos/` were generated by `xtask`, which opens
  transactions directly, so their historical operations still carry `workspace_name: None`. That
  is correct — they predate this change and regenerating fixtures is forbidden — but a reader of
  a fixture's op log will see the mix.
