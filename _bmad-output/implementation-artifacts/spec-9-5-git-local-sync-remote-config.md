---
title: 'Story 9.5: Git local sync + remote config — `git import`, `git export`, `git remote add`/`remove`/`rename`/`set-url`'
type: 'feature'
created: '2026-09-03'
status: 'in-review'
baseline_revision: 'd797d3a09ad9b5438d8cd3582c180bdcc4af199c'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: ['multiple-goals', 'oversized']
deferred:
  - 'No jj repo-config rewrite on `git remote remove`/`rename`. The CLI additionally edits
    `.jj/repo/config.toml` (drops `[remotes.<name>]`, rewrites the
    `revset-aliases.''trunk()''` alias — `cli/src/commands/git/mod.rs:196-262` @ v0.44.0);
    `config.rs` is deliberately read-only and no TOML writer was added. Consequence: a
    `trunk()` alias pinned to a renamed or removed remote keeps naming the old one, and a
    `[remotes.<name>]` section outlives its remote. Documented on `Repo::git_remote_remove`
    and `Repo::git_remote_rename`, and pinned by
    `tests/git_remotes.rs::remove_does_not_edit_the_jj_repo_config`.'
  - 'No `remotes.<name>.auto-track-bookmarks` support. `GitImportOptions
    .remote_auto_track_bookmarks` stays empty in `git_import`, exactly as `git_fetch`
    (`remotes.rs:209`) and `clone_into` (`repo.rs:936`) already leave it. Porting the CLI''s
    string-expression parser would have to change all three call sites at once.'
  - 'No duplicate-URL warning on `git remote add` (`cli/src/commands/git/remote/add.rs:75-117`)
    and no per-ref import/export warning text. Both are `ui.warning` output with no effect on
    the operation, and `MutationResult` has no warning channel; the structured facts those
    lines render (`changed_bookmarks`, `failed_ref_names`, `failed_bookmarks`) do ride the
    payload.'
  - 'No `absolute_git_url` resolution of a relative local path for `remote add`/`set-url`.
    The CLI resolves against its process CWD, which a GUI backend has none worth consulting;
    URLs cross verbatim (FR-JJ-17).'
---

<intent-contract>

## Intent

**Problem:** Zanshin can read git remotes and `git fetch`, but it cannot sync the jj view with the
backing git repo in either direction, and it cannot manage remotes at all. There is no
`git import`, no `git export`, and no way to add, remove, rename or re-point a remote — so every
one of those forces the user out to the jj CLI. `export_refs` is called nowhere in the crate
today, which means a colocated Zanshin workspace never writes its bookmarks back to git.

**Approach:** Add a new `zanshin-jj` noun module `git.rs` with six typed operations —
`git_import`, `git_export`, `git_remote_add`, `git_remote_remove`, `git_remote_rename`,
`git_remote_set_url` — implemented against jj-lib (`git::{import_head, import_refs, export_refs,
add_remote, remove_remote, rename_remote, set_remote_urls}`), and lift all six through the full
surfacing chain Stories 9.3/9.4 established: `.fbs` request/payload tables → `extern "C"` →
committed codegen → Dart adapter / `WorkerCommand` / `ZanshinWorker` / `RepoHandle` → tests.

## Boundaries & Constraints

**Always:**
- The jj CLI's **observable behavior at tag `v0.44.0`** is the oracle (NFR-R-2). Read prior art with
  `git -C ../jj show v0.44.0:cli/src/commands/git/{import,export}.rs` and
  `:cli/src/commands/git/remote/{add,remove,rename,set_url}.rs`; jj-lib is vendored at
  `~/.cargo/registry/src/*/jj-lib-0.44.0/`. Every guard, default and refusal below was read there.
- **Full surfacing chain per verb** (epic-9-context.md "Definition of done per verb", repeated in
  `sprint-status.yaml`'s Epic 9 header): `.fbs` → typed `zanshin-jj` op → `zanshin-ffi`
  `extern "C"` + `cargo make codegen` → Dart worker command → tests, where tests mean a
  `zanshin-jj` integration test **plus** a `packages/zanshin_core` worker test per `extern "C"` fn
  (the ratchet's extern-fn guard has no other coverage source).
- **A verb that rewrites the git config file MUST reload the workspace afterwards.**
  `add_remote`/`remove_remote`/`rename_remote`/`set_remote_urls` call jj-lib's `save_git_config()`,
  which writes to disk immediately but does **not** update the already-loaded `GitBackend`'s gix
  config cache — `repo.rs:899-923` (`clone_into` steps 2–3) and
  `crates/zanshin-jj/tests/remotes_write.rs:163-178` both document this. Without the reload,
  `Repo::list_remotes()` on the same handle would not see the change.
- No `jj_lib` type in a public position (`lib.rs:3` `#![deny(missing_docs)]`, hygiene gate
  `test-jj-adapter-hygiene`). Every jj-lib failure flattens to a `String`; a `#[source]`-carrying
  error is flattened along its whole chain, exactly as the CLI renders it.
- Re-resolve to head per call (ADR-0002); effective config re-read per call, never cached.
- Clippy pedantic `-D warnings`; `rustfmt`; commit on `main` with `--no-gpg-sign`; never edit git
  config.
- The gate is the definition of done: `cargo make test` green. Floors after `epsilon_pct = 0.10`:
  `crates/zanshin-ffi/src/repo.rs` = **100.00**, `envelope.rs` = **100.00**,
  `crates/zanshin-jj/src/mutate.rs` ≥ **97.32**, `repo.rs` ≥ **94.92**, `config.rs` = **100.00**,
  `remotes.rs` = **100.00**. The two new source files must clear `new_file_floor_pct = 80.00`.

**Block If:**
- The `Payload` union's next free discriminants (19–20) are contested by another in-flight story.
  Union member order **is** the wire discriminant; two stories cannot both take slot 19.
- `jj_lib::git::export_refs` cannot be driven from a `Workspace`-owned transaction without the
  CLI's colocated auto-export plumbing. (It should be: it is a sync `&mut MutableRepo` call.)

**Never:**
- **No jj repo-config rewrite.** The CLI additionally edits `.jj/repo/config.toml` on
  `remote remove`/`rename` — dropping `[remotes.<name>]` and rewriting the `revset-aliases.'trunk()'`
  alias (`cli/src/commands/git/mod.rs:196-262`). That is CLI-layer policy on top of jj-lib (it even
  prints an informational message), and `config.rs` is deliberately read-only (`config.rs:13-29`).
  Do not add a TOML writer. The consequence — a `trunk()` alias pinned to a renamed or removed
  remote keeps naming the old one, and a `[remotes.<name>]` section outlives its remote — must be
  documented on the two verbs and recorded as deferred.
- **No colocated skip.** The CLI's "No import/export needed in colocated workspaces." is a
  consequence of its own implicit per-command snapshot/auto-export, which Zanshin structurally does
  not perform (D2; `export_refs` is called nowhere today). Do not port the guard — see Design Notes.
- **No auto-track-bookmarks config.** `GitImportOptions.remote_auto_track_bookmarks` stays
  `HashMap::new()`, as `git_fetch` (`remotes.rs:209`) and `clone_into` (`repo.rs:936`) already do.
  Porting the CLI's `remotes.<name>.auto-track-bookmarks` string-expression parser would have to
  change all three call sites at once.
- **No terminal-UX output.** No hints, no padded columns, no "Nothing changed." — the typed result
  carries the structured fields those lines would have rendered.
- **No new crate** (`test-cargo-hygiene` pins exactly 8 tracked `Cargo.toml`). Do not regenerate
  fixtures. Do not repoint `JJ_CONFIG`. Do not lower `coverage-baseline.txt` or add an
  `exclude_prefix`. Do not touch generated files except via `cargo make codegen`.
- No MCP tool — `crates/zanshin-mcp/src/main.rs` is a stub and the tool surface is Epic 7;
  "optional MCP tool" is a no-op here, exactly as in 9.3/9.4.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| import, happy | a git ref exists that jj has not imported | that ref appears in `list_bookmarks`; `changed_bookmarks` names it with `kind=New`; a new op is written, description `import git refs` | No error expected |
| import, nothing to import | git and jj already agree | no operation written; `mutation.new_op_id` is the pre-call head; all stat vectors empty | No error expected |
| import, failed ref | `refs/remotes/git/x` exists (reserved namespace) | call SUCCEEDS; `failed_ref_names` contains that ref name | No error expected |
| import, failed ref only | the only pending ref is a failing one | no operation written **and** `failed_ref_names` is non-empty | No error expected |
| import, abandoned wc | import abandons the `@` commit | `abandoned_change_ids` non-empty; `mutation.working_copy_change_id` is the new `@`; the on-disk working copy is checked out to it | No error expected |
| import, config | `git.abandon-unreachable-commits = false` in `.jj/repo/config.toml` | unreachable commits are NOT abandoned | No error expected |
| import, malformed config | `git.abandon-unreachable-commits = "yes"` | — | `Config { reason }` → `jj.config_error` |
| import, native backend | repo created with `Repo::init(p, None)` | — | `NotAGitRepo` → `jj.not_a_git_repo` |
| export, happy | a jj local bookmark not yet in git | `git show-ref` finds `refs/heads/<name>`; op written, description `export git refs` | No error expected |
| export, nothing to export | git already matches | no operation written; `mutation.new_op_id` is the pre-call head | No error expected |
| export, failed ref | bookmarks `foo` and `foo/bar` both exist | call SUCCEEDS; `failed_bookmarks` carries one entry whose `reason` is the flattened source chain | No error expected |
| export, native backend | native repo | — | `NotAGitRepo` → `jj.not_a_git_repo` |
| remote add, happy | `name="origin"`, `url`, `push_url=None` | `list_remotes()` on the SAME handle now returns it; op written, description `add git remote origin` | No error expected |
| remote add, push url | `push_url=Some(u)` | the git config gains a `pushurl` for that remote | No error expected |
| remote add, duplicate | the name already exists | — | `RemoteExists { name }` → `jj.remote_exists` |
| remote add, reserved name | `name="git"` | — | `InvalidInput` (jj-lib's reason verbatim) |
| remote add, slash / invalid | `name="a/b"`, `name=""` | — | `InvalidInput` |
| remote remove, happy | an existing remote | `list_remotes()` no longer returns it; op written, description `remove git remote <name>` | No error expected |
| remote remove, missing | no such remote | — | `RemoteNotFound { name }` → `jj.remote_not_found` |
| remote remove, reserved | `name="git"` | git config/refs are updated; **no operation is written** and `new_op_id` is the pre-call head | No error expected |
| remote remove, nonstandard | the remote was added WITH a push url (gix writes `pushurl`) | — | `RemoteNonstandardConfig { name }` → `jj.remote_nonstandard_config` |
| remote rename, happy | `old` exists, `new` free | `list_remotes()` shows `new` and not `old`; op description `rename git remote <old> to <new>` | No error expected |
| remote rename, new is reserved | `new="git"` | — | `InvalidInput` — checked BEFORE "old not found" (jj-lib's own order) |
| remote rename, old missing | `old` absent, `new` valid and free | — | `RemoteNotFound { name: old }` |
| remote rename, new taken | both exist | — | `RemoteExists { name: new }` |
| remote rename, from reserved | `old="git"` | config/refs renamed; **no operation written** | No error expected |
| remote set-url, fetch | `url=Some(u)`, `push_url=None` | fetch URL changes; push URL unchanged; **no operation is ever written** | No error expected |
| remote set-url, both absent | `url=None`, `push_url=None` | silent no-op, success **even for a remote that does not exist** (jj-lib's own early return) | No error expected |
| remote set-url, missing | `url=Some(u)` on an absent remote | — | `RemoteNotFound { name }` |
| remote set-url, reserved | `name="git"` with a url | — | `InvalidInput` |
| any verb, op log | on every refusal | op-log head is byte-identical to the pre-call head | No error expected |
| FFI, null request | `data == NULL` (add / set-url) | — | `ffi.null_pointer` |
| FFI, garbage request | `data` does not verify as the request table | — | `ffi.invalid_argument` |
| FFI, null C string | `name == NULL` (remove / rename) | — | `ffi.null_pointer` |
| FFI, zero/stale handle | `handle == 0` | — | `ffi.invalid_handle` |

</intent-contract>

## Code Map

Every Zanshin anchor was read against the working tree at baseline `d797d3a`; every jj anchor at
tag `v0.44.0`; every jj-lib anchor in the vendored `jj-lib-0.44.0`.

**Prior art (read-only, at the tag)**
- `v0.44.0:cli/src/commands/git/import.rs:37-63` — **no args at all**; colocated guard `:46-50`
  ("Git refs are imported during the snapshot."); then `load_git_import_options` `:54`, then
  **`import_head` FIRST `:58`, `import_refs` SECOND `:59`**, then `tx.finish(ui, "import git refs")`
  `:61`. Doc `:30-32`: "If a working-copy commit gets abandoned, it will be given a new, empty commit."
- `v0.44.0:cli/src/commands/git/export.rs:29-53` — no args; `--no-integrate-operation` is a
  `cli_error` `:36-39`; colocated guard `:41-46`; `export_refs(tx.repo_mut())` `:49`;
  `tx.finish(ui, "export git refs")` `:50`; stats printed AFTER the commit `:51`.
- `v0.44.0:cli/src/cli_util.rs:2790-2806` `WorkspaceCommandTransaction::finish` — **`if
  !tx.repo().has_changes() { "Nothing changed."; return }`** then `rebase_mutable_descendants`. This
  guard applies to every command below, which is why `add` needs no guard of its own.
  `:2927-2945` `rebase_mutable_descendants` — `resolve_immutable_expression(tx.base_repo())` +
  `rebase_descendants_with_options(&immutable, &RebaseOptions::default(), |_,_| count+=1)`.
- `v0.44.0:cli/src/git_util.rs:404-460` `RefStatus` — the exact projection this story ports:
  `import_status` from `(old_remote_ref.target.is_absent(), new_target.is_absent())` →
  `(true,false)=New`, `(false,true)=Deleted`, else `Updated`; the tracked flag from the
  **post-import** view (`repo.view().get_remote_bookmark(symbol).state`, `RemoteRefState::Tracked`
  ⇒ tracked). `:250-265` abandoned-commit list + `Updated {n} rewritten commits.`
  `:270-295` failed import refs are a **warning**, exit 0. `:468-506` failed export refs are a
  warning too, each reason rendered as the flattened `error::Error::source()` chain joined by `": "`.
- `v0.44.0:cli/src/commands/git/remote/add.rs:29-65` — positional `remote`, positional `url`,
  `--push-url`; `absolute_git_url` before the tx; `add_remote` `:61`; duplicate-URL warning
  `:75-117` (deliberately omits the URL — "remote URLs can contain credentials");
  `tx.finish(format!("add git remote {}", args.remote.as_symbol()))` `:63`.
- `v0.44.0:cli/src/commands/git/remote/remove.rs:27-49` — `remove_remote` `:40`, then the jj
  repo-config edit `:41`, then `if tx.repo().has_changes() { tx.finish(…) }` `:42-47` with the
  comment "Do not print \"Nothing changed.\" for the remote named \"git\"" `:46`. Description
  `format!("remove git remote {}", …)`.
- `v0.44.0:cli/src/commands/git/remote/rename.rs:27-58` — description
  `format!("rename git remote {old} to {new}")`; same `has_changes` shape `:45-57`.
- `v0.44.0:cli/src/commands/git/remote/set_url.rs:28-75` — `url` positional is **optional**,
  `--fetch` conflicts with it, `--push` is separate; **no transaction is started at all** `:69-74`.
- `v0.44.0:cli/src/commands/git/mod.rs:196-262` — `rename_remote_in_repo_config` /
  `remove_remote_from_repo_config`: the jj repo-config edits this story deliberately does not port.

**jj-lib 0.44.0 (vendored, exact signatures)**
- `git.rs:1169` `async fn import_head(&mut MutableRepo) -> Result<(), GitImportError>`;
  `:587` `async fn import_refs(&mut MutableRepo, &GitImportOptions) -> Result<GitImportStats,
  GitImportError>`; `:1287` **sync** `fn export_refs(&mut MutableRepo) -> Result<GitExportStats,
  GitExportError>`.
- `git.rs:2371` `add_remote(&mut MutableRepo, &RemoteName, url: &str, push_url: Option<&str>)`;
  `:2411` `remove_remote(&mut MutableRepo, &RemoteName)`; `:2483` `rename_remote(&mut MutableRepo,
  &RemoteName, &RemoteName)`; `:2599` `set_remote_urls(&Store, &RemoteName, Option<&str>,
  Option<&str>)` — **`&Store`, no transaction**, and `:2606-2608` early-returns `Ok(())` when both
  URLs are `None`, *before* the existence check.
- `git.rs:520-525` `GitImportOptions { abandon_unreachable_commits, record_synthetic_predecessors,
  remote_auto_track_bookmarks }` — no `Default`, struct-literal only.
  `src/config/misc.toml:12-16` — jj-lib's own defaults, **already in `StackedConfig::with_defaults()`**
  (`config.rs:663-666`, `:910-913`): `git.abandon-unreachable-commits = true`,
  `git.record-synthetic-predecessors = true`. No `BUILTIN_CONFIG_TOML` addition is needed.
- `git.rs:549-566` `GitImportStats { abandoned_commits: Vec<Commit>, rewritten_commit_ids:
  HashSet<CommitId>, changed_remote_bookmarks: Vec<GitImportRefUpdate>, changed_remote_tags: …,
  failed_ref_names: Vec<BString> }`; `:527-546` `GitImportRefUpdate { symbol: RemoteRefSymbolBuf,
  old_remote_ref: RemoteRef, new_target: RefTarget }`.
- `git.rs:1250-1258` `GitExportStats { failed_bookmarks: Vec<(RemoteRefSymbolBuf,
  FailedRefExportReason)>, failed_tags: … }`; `:1220-1247` `FailedRefExportReason` — 8 variants, the
  last two (`FailedToDelete`/`FailedToSet`) hide the real cause behind `#[source]`.
- `git.rs:2147-2165` `GitRemoteManagementError` — `NoSuchRemote(RemoteNameBuf)`,
  `RemoteAlreadyExists(RemoteNameBuf)`, `RemoteName(#[from] GitRemoteNameError)`,
  `NonstandardConfiguration(RemoteNameBuf)`, `GitConfigSaveError(#[source] io::Error)`,
  `InternalGitError(#[source] …)`, `UnexpectedBackend(#[from] UnexpectedGitBackendError)`,
  `RefExpansionError(…)`. `:145-156` `GitRemoteNameError` — reserved `git` / slash / gix-invalid.
- `git.rs:158-167` `validate_remote_name` is **private** and applied by `add_remote`,
  `rename_remote` (on the NEW name only) and `set_remote_urls` — **not** by `remove_remote`.
  `:2320-2350` `remove_remote_git_config_sections` raises `NonstandardConfiguration` for any
  `[remote "x"]` key outside `url`/`fetch`/`tagOpt` — **a remote added with a push URL therefore
  cannot be removed**, because `save_remote` (`:2229-2250`) writes `pushurl`.
- `git.rs:87` `RESERVED_REMOTE_REF_NAMESPACE = "refs/remotes/git/"`; `:85`
  `REMOTE_NAME_FOR_LOCAL_GIT_REPO = "git"`. `:796` `record_abandoned_commit` — **this is why
  `git_import` must rebase descendants before committing**: it populates `parent_mapping`, and
  `Transaction::write` panics on outstanding rewrites (`mutate.rs:466-472`).
- `ref_name.rs:157` `RemoteName::new(&str)`, `:160` `.as_str()`, `:184` `RemoteNameBuf::from(&str)`.
  Neither implements `Display` — **use `.as_str()` for payload fields**, never `.as_symbol()`
  (which renders quoted revset syntax).

**Extend — `crates/zanshin-jj`**
- `src/git.rs` (**NEW**) — the six operations, their owned result types, the shared
  `finish_or_no_op` skeleton, `map_remote_mgmt_err`, and a `flatten_chain` helper. Model it on
  `src/remotes.rs` (module doc `:3-9`, `pub(crate) fn` shape, `#[must_use = "the Result must be
  used; drop it explicitly if intentional"]`, `git_fetch` `:193-269` — the transaction skeleton,
  including the `mutate::be` converter usage and the post-commit `@` read `:257-268`).
- `src/mutate.rs` — `MutateError` `:76-182` (append the three new variants after `NetworkError`
  `:151`, keeping `Backend` last), `be` `:241`, `cfg` `:248`, `capture_old_wc` `:333`
  (already `pub(crate)`), `sync_working_copy` `:348` (already `pub(crate)`), **`no_op_result` `:666`
  (currently private — make it `pub(crate)`)**, the `has_changes` no-op guard `:897-919`, the
  descendant-pass-before-commit rule `:466-472`, and `abandon`'s
  `rebase_descendants_with_options(&resolved_immutable, &options, |_, _| {})` `:623-627`.
- `src/op_support.rs:72` `immutable_user_expression(&Repo)`, `:95` `resolve_immutable(&dyn Repo,
  &Arc<UserRevsetExpression>)` — `git_import` needs both, resolved against `tx.base_repo()`.
- `src/config.rs:379-388` `load(repo)` ("re-read on every call — never cached"), `:436-440`
  `conflict_marker_style` (the single-key `pub(crate)` getter returning a `jj_lib` type — the
  template), `:168` `value_error`.
- `src/repo.rs` — `Repo { workspace, settings }` `:82-85`, `workspace()` `:103`, `workspace_mut()`
  `:108`, `settings()` `:113`; the borrow-split idiom `:722-733` (`restore`); the `list_tags` doc
  template `:174-189`; `git_fetch` `:641-664` (place the six new facades directly after it, before
  `restore`); **`clone_into` `:885-923` — steps 2–3 are the config-write-then-reload pattern**, and
  `Workspace::load(&settings, path, &default_backend_factories(), &default_working_copy_factories())`
  `:817-823` is the exact reload call.
- `src/lib.rs:30-45` module list (add `pub(crate) mod git;` alphabetically, between `file` and
  `graph`), `:47-61` re-export block (add a `pub use git::{…};` line between `file` and `graph`).

**Extend — wire + FFI**
- `schemas/envelope.fbs` — request-only block ends at `:128` with its **APPEND-only field-order
  invariant** `:31-39`; ledger comment `:130-142` (add a `//   Story 9-5 : …` line); payload tables
  end at `:566`; `union Payload` `:568-588` — **next free discriminants are 19 and 20**, the
  append-only note is inline at `:580`. Conventions: `snake_case` fields, `enum … : byte` with an
  append-only note (`FileType` `:479-481` is the canonical wording), null-for-absence on strings and
  nested tables only, presence-flag pairs for optional scalars (`SearchMatch.conflict_side` /
  `has_conflict_side` `:559-560`), saturating `uint` documented at `:470`.
  `MutationResult` `:428-438`, `AbsorbResult` `:466-472` (the nested-`MutationResult` precedent),
  `RestoreRequest` `:58-64`, `FileSearchRequest` `:123-128`.
- `crates/zanshin-ffi/src/git.rs` (**NEW**) + `pub mod git;` in `lib.rs:32-47` (alphabetical, after
  `file`). Templates: `file.rs` — `map_file_err` `:28`, the request-reader banner `:43`, the owned
  structs `:69-88`, `read_file_list_request` `:90-105`, the payload builders `:183-203`, the shared
  `finish_envelope` `:310-326` ("single-noun payload builders stay in the noun file"), the
  `extern "C"` skeleton `:359-376`.
- `crates/zanshin-ffi/src/repo.rs` — the request-reader module comment `:128-148` (the lifetime
  rationale: build the byte slice in scope, return **owned** structs); `read_restore_request`
  `:190-211`; **`map_mutate_err` `:83-126` (currently private — make it `pub(crate)`)** and its
  per-story doc ledger `:70-82`; `zanshin_git_fetch` `:908-940` (the git-verb naming precedent and
  the `cstr_to_string` shape); `zanshin_restore` `:944-1008` (doc block + body template);
  `RepoSession` `:277`.
- `crates/zanshin-ffi/src/envelope.rs` — the constant block `:15-84` with its `/// AR-P-4:` doc
  lines (`JJ_REMOTE_NOT_FOUND` `:55`, `JJ_NOT_A_GIT_REPO` `:64`, `JJ_INVALID_INPUT` `:45`,
  `JJ_CONFIG_ERROR` `:76`, `JJ_JJ_LIB_ERROR` `:32`, `FFI_NULL_POINTER` `:20`,
  `FFI_INVALID_ARGUMENT` `:24`, `FFI_INVALID_HANDLE` `:18`); `FfiErrorObj` `:101-105`;
  `reject_null_request` / `invalid_request` `:107-134`; `build_mutation_result` `:189-208` and
  `ok_mutation_result` `:216` (**the four remote verbs return this unchanged**); `err` `:325`;
  `catch` `:367`.
- `crates/zanshin-ffi/src/ffi_strings.rs:45` `cstr_to_string`, `:106` `ZanshinBuf`, `:122`
  `vec_into_token`.
- `docs/rust-error-codes.md:33-63` the registry table, `:67-73` the four-step add procedure. The
  established reuse annotation is "; also emitted — Story 9.5 by …" appended to an existing row.

**Extend — Dart (`packages/zanshin_core`)**
- `lib/src/ffi/git.dart` (**NEW**) — sections `// ── Request-buffer helpers ──` /
  `// ── FFI adapters ──` / `// ── Dart models ──` / `// ── Decoder ──`. Templates:
  `mutate.dart:28-36` `_withRequestBytes`, `:49-53` `_rejectInteriorNul`, `:147-163` `zanshinGitFetch`
  (the lone-C-string adapter), `:165-205` `zanshinRestore` (the request-buffer adapter),
  `:319-348` the `decodeXEnvelope` / `…Internal` / `_decodeX` triple, `MutationResult` model `:241`;
  `file.dart:13` (`import 'mutate.dart' show SkippedPath;` — the model-reuse precedent),
  `:398-405` `_okEnvelope`.
- `lib/src/worker/commands.dart` — sealed base `:3-17`, `GitFetchCommand` `:312-332` (the
  lone-string shape), `RestoreCommand` `:334-370` (the request-carrying shape); append after
  `FileSearchCommand` ends at `:506`, before `ShutdownCommand` `:508-515` (which must stay last).
- `lib/src/worker/isolate.dart` — aliased imports `:11-40`; the `ZanshinWorker` method template
  `:766-798`; the worker switch arm with the synthesized `ffi.invalid_handle` envelope `:1331-1350`.
  Append methods after `:931` (before the `// ─── Worker entry point ───` banner at `:932`) and
  switch arms after `:1421` (before `case ShutdownCommand():` at `:1423`).
- `lib/src/worker/handle.dart` — `RepoHandle` `:31`, `_closed` guard, `absorb` `:347-352`,
  `fileList` `:376-381`; append after `:461`, before the finalizer block at `:463`.
- Generated, regenerate only via `cargo make codegen`: `lib/src/ffi/bindings.dart`,
  `lib/src/ffi/envelope_zanshin.ffi_generated.dart`, `crates/zanshin-ffi/src/envelope_generated.rs`,
  `crates/zanshin-ffi/include/zanshin_ffi.h`.

**Tests / gates**
- `crates/zanshin-jj/tests/remotes_write.rs` — the closest harness: `ENV_GUARD` `:24`, `pin_env`
  `:29`, `make_test_settings` `:33`, `git_cmd` `:53`, `git_stdout` `:63`,
  `init_git_repo_with_commits` `:79`, `git_bare_clone` `:146`, and `register_remote` `:163-178`
  (the drop-the-tx variant, with the reload rationale in its doc). `tests/remotes.rs:63-74`
  `add_remotes` is the commit-the-tx variant.
- `crates/zanshin-jj/tests/content_ops.rs` — `head_op_id` `:108`, `head_op_description` `:112`,
  `write_repo_config` `:116` (writes `.jj/repo/config.toml`), `jj_repo` `:69`.
  `tests/convert.rs` — real-git-repo construction and colocated conversion.
- `crates/test-helpers/src/lib.rs` — `extract_fixture` `:41`, `add_commit_off_root` `:95`,
  `set_local_bookmark` `:421`, `set_tag` `:434`, `set_remote_bookmark` `:447`. **The committed
  fixtures contain no remotes and no remote bookmarks; construct them in-test and never regenerate
  a fixture.**
- `crates/zanshin-ffi/tests/repo_write_ffi.rs` — `read_and_free` `:61`, `parse_envelope` `:72`,
  `cstr` `:77`, `restore_request_bytes` `:94`, `open_handle` `:150`,
  `open_fixture_and_get_wc_change_id` `:174` (+ the deliberate `mem::forget` at `:200`),
  `open_fixture_with_repo_config` `:378`, and the git scaffolding `:593-633`.
- `packages/zanshin_core/test/worker/mutate_test.dart:3-15` — the header paragraph naming this file
  as what credits each `extern "C"` fn in the ratchet's extern-fn guard (**the new worker test file
  must carry that paragraph**); `:168-282` the four canonical cases.
  `test/ffi/mutate_test.dart:226-284` — the synthetic-buffer decode contract + one NUL-guard test
  per string parameter.
- `crates/zanshin-jj/tests/api_stability.rs` — alias block `:18-98` with the running type count in
  the header `:12-16` (**currently 50**), `sample_*` constructors `:104-229`, and the per-story
  `*_surface_resolves` convention (`content_ops_surface_resolves` `:363`,
  `file_reads_surface_resolves` `:393`) — never extend `api_surface_resolves` `:232`, which is at
  clippy's `too_many_lines` ceiling.
- `Makefile.toml` — `[tasks.test]` `:47-72`, `[tasks.codegen]` `:289-295`, `[tasks.verify-codegen]`
  `:348` (manual; refuses on a dirty tree), `[tasks.coverage]` `:449` with the **extern-fn guard**
  `:537-564`, `test-cargo-hygiene` `:205` (exactly 8 tracked `Cargo.toml`), `test-jj-adapter-hygiene`
  `:255`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/mutate.rs` -- make `no_op_result` `pub(crate)` and add three `MutateError`
  variants after `NetworkError`: `RemoteExists { name }`, `RemoteNonstandardConfig { name }`, and
  `NotAGitRepo` (unit) -- a duplicate remote name, a remote whose git config jj refuses to rewrite,
  and a repo with no git backend each have a different remedy in the UI, and none of the registered
  codes expresses any of them; `Backend` stays "unclassified", which these three are not.
- `crates/zanshin-jj/src/config.rs` -- add a `pub(crate) fn git_import_options(config:
  &StackedConfig) -> Result<GitImportOptions, ConfigError>` in `conflict_marker_style`'s style,
  reading `git.abandon-unreachable-commits` and `git.record-synthetic-predecessors` off the
  EFFECTIVE config and passing `remote_auto_track_bookmarks: HashMap::new()` -- both keys already
  resolve through `StackedConfig::with_defaults()` (jj-lib's own `config/misc.toml`), so no
  `BUILTIN_CONFIG_TOML` entry is added; hardcoding them would silently decide for a user who set
  `abandon-unreachable-commits = false` (FR-JJ-17).
- `crates/zanshin-jj/src/git.rs` (NEW) -- module doc stating the split from `remotes.rs` (which
  keeps the FR-JJ-9 read and the FR-JJ-13 fetch that predate this story), the ADR-0002 re-resolve
  rule, the AR-AP-1 never-shell rule, and every deliberate divergence with its `v0.44.0` anchor.
  Add `flatten_chain(&dyn std::error::Error) -> String` (joins `Display` with each `source()` by
  `": "`, exactly as `git_util.rs:475-478` renders it), `map_remote_mgmt_err(GitRemoteManagementError,
  name: &str) -> MutateError` (`NoSuchRemote` -> `RemoteNotFound`, `RemoteAlreadyExists` ->
  `RemoteExists`, `RemoteName(_)` -> `InvalidInput` with jj-lib's reason verbatim,
  `NonstandardConfiguration` -> `RemoteNonstandardConfig`, `UnexpectedBackend` -> `NotAGitRepo`,
  everything else -> `Backend(flatten_chain(...))`), the same `UnexpectedBackend -> NotAGitRepo` /
  else-`Backend` mapping for `GitImportError` and `GitExportError`, and a private
  `finish_or_no_op(...)` carrying the shared skeleton:
  `load_at_head` -> `capture_old_wc` -> `start_transaction` -> verb work -> `if
  !tx.repo().has_changes() { drop(tx); no_op_result(...) }` -> `tx.commit(<CLI description>)` ->
  `sync_working_copy` -> `MutationResult`.
- `crates/zanshin-jj/src/git.rs` -- add `pub(crate) fn git_import(workspace: &mut Workspace,
  immutable: &Arc<UserRevsetExpression>, options: &GitImportOptions) -> Result<GitImportResult,
  MutateError>`: `import_head` FIRST then `import_refs` (the CLI's order), then
  `resolve_immutable(tx.base_repo().as_ref(), immutable)` +
  `rebase_descendants_with_options(&resolved, &RebaseOptions::default(), |_, _| {})` BEFORE the
  commit -- `import_refs` calls `record_abandoned_commit`, and `Transaction::write` panics on
  outstanding rewrites. Description `"import git refs"`. The stats are projected AFTER the commit
  from `new_repo`'s view; on the no-op path the stats are still returned (a run where every ref
  failed changes nothing yet must report `failed_ref_names`).
- `crates/zanshin-jj/src/git.rs` -- add the owned result types: `GitImportResult { mutation,
  changed_bookmarks, changed_tags, abandoned_change_ids, num_rewritten, failed_ref_names }`,
  `GitRefUpdate { name, remote, kind, tracked }` with `enum GitRefUpdateKind { New, Updated,
  Deleted }`, `GitExportResult { mutation, failed_bookmarks, failed_tags }` and `GitExportFailure {
  name, remote, reason }` -- `kind` and `tracked` reproduce `git_util.rs:404-460`'s own derivation
  (the tracked flag reads the POST-import view, not `old_remote_ref`); `failed_ref_names` is
  `String::from_utf8_lossy` over jj-lib's `BString`s because a git ref name is not guaranteed UTF-8;
  `num_rewritten` is a count because that is all the CLI reports, and resolving each rewritten
  commit id to a change id would be work no consumer asked for.
- `crates/zanshin-jj/src/git.rs` -- add `pub(crate) fn git_export(workspace: &mut Workspace) ->
  Result<GitExportResult, MutateError>` over the sync `export_refs`, description
  `"export git refs"`; failed bookmarks/tags are carried in the RESULT, never as an `Err` -- the CLI
  warns and exits 0, and an export whose only outcome is a failure list must still be readable.
- `crates/zanshin-jj/src/git.rs` -- add `git_remote_add`, `git_remote_remove`, `git_remote_rename`
  (each `&mut Workspace`, each through `finish_or_no_op` with the CLI's own description strings
  `"add git remote {name}"` / `"remove git remote {name}"` / `"rename git remote {old} to {new}"`)
  and `git_remote_set_url`, which starts NO transaction at all (jj-lib's `set_remote_urls` takes
  `&Store`) and returns `no_op_result` -- mirroring the CLI, which never opens one either.
- `crates/zanshin-jj/src/repo.rs` -- add a private `fn reload_workspace(&mut self) ->
  Result<(), MutateError>` doing the `Workspace::load` of `clone_into` step 3, and the six `pub fn`
  facades after `git_fetch`, in `list_tags`' doc style with a `# Errors` bullet per reachable
  variant. The four remote facades run the reload on BOTH the success and the failure path (jj-lib
  writes the git config before the git-ref edits that can still fail), surfacing a reload error only
  when the verb itself succeeded, so an already-failing call never has its error replaced.
  `git_import` builds the immutable expression and the import options from `&self` BEFORE
  `workspace_mut()` takes `&mut self`, exactly as `restore` does.
- `crates/zanshin-jj/src/lib.rs` -- add the module and re-export `GitExportFailure`,
  `GitExportResult`, `GitImportResult`, `GitRefUpdate`, `GitRefUpdateKind`.
- `schemas/envelope.fbs` -- append request tables `GitRemoteAddRequest { name, url, push_url }` and
  `GitRemoteSetUrlRequest { name, url, push_url }` (both with null-for-absence on `push_url`, and on
  `url` for set-url); add payload tables `GitRefUpdate` + `enum GitRefUpdateKind : byte` (with the
  append-only note `FileType` carries), `GitImportResult`, `GitExportFailure`, `GitExportResult`;
  append `GitImportResult` and `GitExportResult` to `union Payload` as slots 19-20 and tick the
  ledger comment. `remove`/`rename` get NO request table -- every argument is a required lone string,
  which ADR-0001 routes to a `CString`, not to FlatBuffers.
- `crates/zanshin-ffi/src/repo.rs` -- make `map_mutate_err` `pub(crate)`, add its three new arms
  (`RemoteExists` -> `jj.remote_exists`, `RemoteNonstandardConfig` -> `jj.remote_nonstandard_config`,
  `NotAGitRepo` -> `jj.not_a_git_repo` with `context: None`) and a line in its per-story doc ledger.
- `crates/zanshin-ffi/src/envelope.rs` -- add `JJ_REMOTE_EXISTS` and `JJ_REMOTE_NONSTANDARD_CONFIG`
  with their `/// AR-P-4:` doc lines, and widen `JJ_REMOTE_NOT_FOUND`'s doc, which currently names
  only `zanshin_git_fetch`.
- `crates/zanshin-ffi/src/git.rs` (NEW) + `pub mod git;` in `lib.rs` -- two request readers in
  `read_restore_request`'s shape (owned structs, byte slice built and verified in scope), the
  `GitImportResult`/`GitExportResult` payload builders with their own `finish_envelope`, and the six
  `extern "C"` wrappers `zanshin_git_import(handle)`, `zanshin_git_export(handle)`,
  `zanshin_git_remote_add(handle, data, len)`, `zanshin_git_remote_remove(handle, name)`,
  `zanshin_git_remote_rename(handle, old_name, new_name)`,
  `zanshin_git_remote_set_url(handle, data, len)` -- each with the full `# Errors` / `# Safety` doc
  block cbindgen lifts, and the `debug!` -> `catch` -> `handle_from_raw` -> decode -> call ->
  payload -> `vec_into_token` body.
- `cargo make codegen` -- regenerate and commit `envelope_generated.rs`,
  `envelope_zanshin.ffi_generated.dart`, `include/zanshin_ffi.h`, `bindings.dart`; run it AGAIN
  after the `extern "C"` signatures and their doc comments are final, then `cargo make
  verify-codegen` on a clean tree.
- `packages/zanshin_core/lib/src/ffi/git.dart` (NEW) -- six adapters (request buffers for add and
  set-url, `toNativeUtf8()` C strings for remove and rename, bare handle for import and export),
  interior-NUL guards on every caller-supplied string, the models
  (`GitImportResult`/`GitRefUpdate`/`GitRefUpdateKind`/`GitExportResult`/`GitExportFailure`) and two
  decoder triples -- import `MutationResult` from `mutate.dart` rather than defining a second one,
  and reuse `decodeMutationResultEnvelopeInternal` for the four remote verbs.
- `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` -- six `WorkerCommand`
  subclasses (isolate-sendable fields only), six `ZanshinWorker` methods, six worker switch arms
  including the synthesized `ffi.invalid_handle` envelope, and six `RepoHandle` methods with the
  synchronous `_closed` guard -- Model A: the UI never holds a raw pointer.
- `crates/zanshin-jj/tests/git_sync.rs` (NEW) -- import/export against a real git-backed workspace
  built in-test (the `git_cmd`/`init_git_repo_with_commits` helpers from `remotes_write.rs`, or
  `convert_colocated` where a colocated `.git` is needed), covering every `zanshin-jj`-level import
  and export row of the I/O matrix, including the reserved-namespace failed import ref
  (`refs/remotes/git/…`), the `foo` vs `foo/bar` failed export, the malformed-config refusal, the
  native-backend refusal, and an "op-log head unchanged" assertion on the no-op and the refusal
  paths.
- `crates/zanshin-jj/tests/git_remotes.rs` (NEW) -- the four remote verbs against oracles read with
  raw jj-lib/gix rather than a second call to the code under test, covering every remote row of the
  I/O matrix, plus the two assertions this story exists for: `list_remotes()` on the SAME `Repo`
  reflects each verb immediately (the reload), and the reserved remote `git` is removable/renamable
  WITHOUT writing an operation.
- `crates/zanshin-ffi/tests/git_ffi.rs` (NEW) -- per wrapper: a happy path proving the payload
  carries the verb's distinguishing data (not merely a well-formed envelope), plus `ffi.null_pointer`,
  `ffi.invalid_handle`, `ffi.invalid_argument` (add / set-url) and one real domain refusal each --
  all three NEW `map_mutate_err` arms must cross the FFI boundary here (`jj.remote_exists`,
  `jj.remote_nonstandard_config`, `jj.not_a_git_repo`), since `crates/zanshin-ffi/src/repo.rs` is
  pinned at 100.00 and an unexercised arm fails the ratchet; and carry `push_url` / a non-default
  `url` through the request buffer in at least one test, so a reader that hardcoded them would fail.
- `packages/zanshin_core/test/worker/git_test.dart` and `test/ffi/git_test.dart` (NEW) -- real
  cdylib round-trips for all six verbs (happy, a real refusal surfacing its `ZanshinFfiException`
  code, `ffi.invalid_handle` after `handle.close()`, synchronous `StateError` from the `RepoHandle`
  guard) plus synthetic-buffer decode-contract and NUL-guard tests -- the worker file is what
  credits each new `extern "C"` fn in the ratchet's extern-fn guard, and must carry that header
  paragraph.
- `crates/zanshin-jj/tests/api_stability.rs` -- add a NEW `#[test] fn git_ops_surface_resolves()`
  pinning the six `Repo` methods as `fn` pointers, `sample_*` constructors for each new struct,
  aliases for the five new types, each new `MutateError` variant constructed AND its `Display`
  asserted (an unexercised `thiserror` arm is an uncovered line in `mutate.rs`, which is pinned at
  97.32), and update the running type count in the header comment.
- `docs/rust-error-codes.md` -- add the `jj.remote_exists` and `jj.remote_nonstandard_config` rows
  and append "Also emitted — Story 9.5" clauses to `jj.remote_not_found`, `jj.not_a_git_repo`
  (widened: also "the open workspace has no git backend"), `jj.invalid_input`, `jj.config_error`,
  `jj.jj_lib_error`, `ffi.null_pointer`, `ffi.invalid_argument` and `ffi.invalid_handle`.

**Acceptance Criteria:**
- Given the workspace after this change, when `cargo make test` runs, then it passes end to end with
  no baseline lowered and no `exclude_prefix` added; every touched `crates/zanshin-ffi/src` file
  holds its baseline, the two new source files clear `new_file_floor_pct`, and the extern-fn guard
  reports every `zanshin-ffi` `extern "C"` fn covered.
- Given each of the six verbs, when the surfacing chain is inspected, then each has an `extern "C"`
  wrapper, regenerated **committed** codegen, a Dart adapter, a `WorkerCommand`, a `ZanshinWorker`
  method, a `RepoHandle` method, and at least one `packages/zanshin_core/test/worker` test that
  drives it through the real cdylib; and each of `add`/`set-url` additionally has a `.fbs` request
  table while `import`/`export` additionally have a `Payload` member.
- Given a repo whose git config was just changed by any of the four remote verbs, when
  `Repo::list_remotes()` is called on the SAME handle, then it reflects the change — no reopen is
  required.
- Given any of the six verbs on any input — success, refusal, or empty result — when the op log is
  read afterwards, then a refusal and a legitimate no-op leave the head op id byte-identical to the
  pre-call head, and a successful mutating call's head carries the CLI's own description string
  verbatim.
- Given `zanshin-jj`'s public API compared against the pre-change surface, then the only additions
  are the six `Repo` methods, the five new types, and the three new `MutateError` variants; all are
  pinned in `tests/api_stability.rs`, no `jj_lib` type appears in any public position, and
  `test-jj-adapter-hygiene` passes.
- Given a `git import` or `git export` whose only outcome is a failed ref, when the call returns,
  then it is `Ok` and the failure is readable from the payload — the CLI warns and exits 0, so a
  failed ref is never an error envelope.
- Given the repo after `cargo make codegen`, when `cargo make verify-codegen` runs on a clean tree,
  then it reports no drift for `zanshin_ffi.h`, `bindings.dart`, `envelope_generated.rs` and
  `envelope_zanshin.ffi_generated.dart`.
- Given `docs/rust-error-codes.md`, when it is read, then it contains exactly two new rows
  (`jj.remote_exists`, `jj.remote_nonstandard_config`) and every reused row names Story 9.5 as an
  emitter.
- Given `cargo make test`'s `test-cargo-hygiene` gate, when it runs, then it still sees exactly
  eight tracked `Cargo.toml` files — this story adds no crate.

## Spec Change Log

## Review Triage Log

## Design Notes

**Why all six verbs live in one new module.** `remotes.rs` owns the FR-JJ-9 remote *list* and the
FR-JJ-13 *fetch*, both shipped and both at 100.00 coverage. The six verbs here are the `jj git`
command family the CLI itself groups under `cli/src/commands/git/` — sync in both directions plus
remote configuration. Splitting them across `remotes.rs` and a new module would put `git remote add`
in one file and `git remote list` in another; keeping them together in `git.rs` leaves the shipped
module untouched, gives the six verbs one place for their shared skeleton, error mapper and chain
flattener, and mirrors the FFI side (`zanshin-ffi/src/git.rs`) one-to-one.

**Why the colocated skip is not ported.** The CLI refuses both `git import` and `git export` in a
colocated workspace with an informational, exit-0 message. Its own comment gives the reason: "Git
refs are imported during the snapshot" (`import.rs:47`) — its `workspace_helper` snapshots before
every command and its `finish_transaction` auto-exports after every op in a colocated repo
(`cli_util.rs:2300-2385`). Zanshin does neither: D2 fixes that the working copy is never snapshotted
(`status.rs:82-89`), and `export_refs` is currently called nowhere in the crate. The guard's premise
is therefore false here, and porting it would make the two verbs unusable in exactly the repos that
need them most. Running them unconditionally reproduces the CLI's *observable end state* (refs
imported / exported); the guard is a HOW-artifact of the CLI's implicit plumbing, which ADR-0003
replaces rather than mirrors. This is a selection the project rules make — not a free choice.

**Why the git-config reload is load-bearing.** jj-lib's four remote mutators call `save_git_config()`,
which writes the git config file but leaves the already-loaded `gix::Repository`'s in-memory config
untouched. `clone_into` works around it by dropping its throwaway transaction and calling
`Workspace::load` again (`repo.rs:899-923`), and `remotes_write.rs:163-178` warns callers to reopen.
Without a reload inside the verb, `repo.git_remote_add(…)` followed by `repo.list_remotes()` on the
same handle would return the pre-call list — an observable defect a GUI would hit immediately, which
is why it is an acceptance criterion rather than a note. The reload runs on the failure path too:
`remove_remote` and `rename_remote` write the config *before* the git-ref edits that can still fail,
so a mid-verb failure would otherwise leave a stale cache behind.

**Why `git import` needs a descendant pass and the others do not.** `import_refs` calls
`record_abandoned_commit` (`git.rs:796`), which populates `parent_mapping`; `Transaction::write`
panics if rewrites are still outstanding (`mutate.rs:466-472`). The CLI handles this centrally in
`tx.finish` → `rebase_mutable_descendants` (`cli_util.rs:2927-2945`), resolving the immutable
expression against `tx.base_repo()` — which is exactly what `mutate.rs::abandon` already re-ports.
`export_refs` and the four remote verbs rewrite no commit, so they need neither the rebase nor the
immutable expression, and they can take the `git_fetch` shape.

**Which stats survive the terminal-UX cut.** `-T/--template`, column padding, the `foo`/`foo/bar`
hint and the "Nothing changed." line are rendering. What they render is not: `failed_ref_names` and
the export failure lists are the *only* record that a ref could not be synced, and nothing in the
repository state lets a caller re-derive them afterwards, so they belong in the payload. The per-ref
`changed_bookmarks`/`changed_tags` are kept for the same reason a GUI shows "3 bookmarks updated":
re-deriving them would require the caller to snapshot the bookmark list before the call.
`num_rewritten` is a plain count because a count is all the CLI reports.

**Error taxonomy: two new codes, deliberately.** `jj.remote_exists` and
`jj.remote_nonstandard_config` each carry a remedy no registered code implies — "use set-url instead"
and "edit the git config by hand". The second is not exotic: jj's own `save_remote` writes a
`pushurl` key, and `remove_remote_git_config_sections` (`git.rs:2320-2350`) refuses any key outside
`url`/`fetch`/`tagOpt`, so *adding a remote with a push URL and then removing it* — a plausible first
GUI session — hits it. Everything else reuses: the three `GitRemoteNameError` cases (reserved `git`,
slash, gix-invalid) become `InvalidInput` with jj-lib's own reason verbatim, and
`UnexpectedGitBackendError` becomes `NotAGitRepo`, reusing the already-registered `jj.not_a_git_repo`
whose meaning widens from "this path" to "this workspace's backend".

**Traps to respect.** `set_remote_urls` returns `Ok(())` when both URLs are `None` *before* it checks
that the remote exists (`git.rs:2606-2608`) — mirror it; inventing a refusal there would be a
divergence. `rename_remote` validates the NEW name before reporting that the OLD one is missing, so
`rename nonexistent git` reports the reserved-name error. `remove_remote` does not validate the name
at all, which is how the reserved remote `git` can be removed — and that case changes no view, so no
operation is written. `RemoteName`/`RemoteNameBuf` have no `Display`; `.as_symbol()` renders *quoted
revset syntax*, so payload fields must use `.as_str()`. `failed_ref_names` are `BString`s because git
ref names are not guaranteed UTF-8.

## Verification

**Commands:**
- `cargo make test` -- expected: green end to end (cargo test + clippy `-D warnings` + rustfmt +
  flutter/dart analyze+format + `cargo deny` + coverage ratchet + extern-fn guard). Run unpiped;
  capture the exit code. This is the single gate.
- `cargo make codegen` then `cargo make verify-codegen` -- expected: the second reports no drift.
  Run `verify-codegen` only on a clean tree; it refuses otherwise.
- `git -C ../jj show v0.44.0:cli/src/commands/git/import.rs` (and `export.rs`,
  `remote/{add,remove,rename,set_url}.rs`, `cli/src/git_util.rs`) -- expected: re-confirms the arg
  surface, guard ordering, transaction descriptions and stat rendering before relying on the anchors
  above.
- `git status --porcelain` -- expected: afterwards only intended files; the four generated files
  appear only together with the `.fbs`/`extern "C"` change that earned them; `coverage-baseline.txt`
  appears only if the ratchet raised it.

**Manual checks (if no CLI):**
- Diff the crate's `pub` items: confirm the additions are exactly the six `Repo` methods, the five
  new types and the three `MutateError` variants, and that no `jj_lib` type leaked into a public
  signature.
