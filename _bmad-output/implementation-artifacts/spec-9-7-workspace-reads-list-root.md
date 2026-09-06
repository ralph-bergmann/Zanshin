---
title: 'Story 9.7: Workspace reads — `workspace list`, `workspace root`'
type: 'feature'
created: '2026-09-04'
status: 'done'
baseline_revision: '7989ca05cb22a332f6a4a55efa6d50aedd63adc8'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      A repo initialised through a path containing a symlink records a store entry its own reads
      cannot resolve, so the workspace's own root reports as absent.
    evidence: |-
      `SimpleWorkspaceStore::add` stores `relative_path(store.repo_path, workspace_root)`
      (`jj-lib-0.44.0/src/workspace_store.rs:176-181`) using the RAW `repo_path` it was handed,
      while `Workspace::new` canonicalizes the workspace root (`workspace.rs:170`) and every
      READ joins the recorded path onto the canonicalized `Workspace::repo_path()`. On macOS
      the system temp dir is `/var/folders/…`, a symlink to `/private/var/folders/…`, so an
      init through the raw path records one `..` too few and nothing resolves. The real jj CLI
      never hits it because its workspace loader canonicalizes before either side runs. The
      fault is in the INIT path (`Repo::init`/`Repo::open`, Story 2.3), not in this story's
      read-only verbs, so it is out of scope here — but it is reached THROUGH them, and all
      three new test suites work around it with a documented canonicalize
      (`add_resolvable_workspace`, `open_two_workspace_scenario`,
      `tempDir.resolveSymbolicLinksSync()`), so no test pins the defect itself.
    location: >-
      crates/zanshin-jj/src/repo.rs::init
    severity: medium
    resolved: >-
      RESOLVED 2026-09-05 (spec-epic-9-followup-d-symlinked-workspace-path, commits 2d6de57..3bb2e7e).
      The caller-supplied workspace path is now canonicalized at ALL FIVE seams that hand a path
      to jj-lib's Workspace constructors - Repo::open, Repo::init, Repo::clone, convert_colocated
      and import_into - because they funnel into the same init_with_factories ->
      workspace_store.add write. All five had to move for COMPLETENESS, not to avoid a regression:
      a raw-recorded entry never resolved from EITHER base, because relative_path counts the ..
      segments LEXICALLY (jj-lib-0.44.0/src/file_util.rs:136-152 - the common prefix of a raw and a
      canonical path is / alone, so the record is N x .. plus private/var/...), while
      resolve_recorded_root joins and then calls std::fs::canonicalize, i.e. realpath(3), which
      resolves the symlink BEFORE applying the .. segments - realpath("/var/..") is /private, not /.
      So repos created through a symlinked path by clone / convert_colocated / convert_import were
      ALREADY broken and this change fixes them; and, by the same token, canonicalizing Repo::open
      cannot strand any repo written by an older build, because none of those entries resolved.
      std::fs::canonicalize, never dunce:: (this crate's workspace.rs house rule).
      Nothing observable moved: Repo::open's !path.exists() guard is replaced by the canonicalize
      (exists() is an fs::metadata probe that follows symlinks, so it returned false exactly
      where canonicalize returns Err), every error payload keeps the CALLER's spelling, and a
      missing init/clone target is still InitFailed/CloneFailed - only detected one step earlier,
      with the unresolvable path named in `reason`. No new variant, no error-code or registry
      change, no .fbs edit and no codegen. All three of this story's workarounds are DELETED so
      its own suites are the witness (workspace.rs::add_resolvable_workspace,
      workspace_ffi.rs::open_two_workspace_scenario's fs::canonicalize, and workspace_test.dart's
      resolveSymbolicLinksSync on the INPUT path - its assertions still resolve both sides), and
      four new store-round-trip witnesses pin the write seams one at a time: tests/workspace.rs
      (init, walking both the handle init RETURNS and a re-open), tests/repo.rs (clone) and
      tests/convert.rs (convert_colocated, convert_import). Repo::open's canonicalize is
      FORWARD-DEFENCE rather than part of the read fix - the read join finishes with realpath(3),
      which resolves the symlinked prefix before the record's .. segments, so a raw and a
      canonical base answer identically; what it buys is a canonical Workspace::repo_path() for
      any future writer that records an entry from an OPENED repo. test-helpers::add_workspace was fixed at its cause (it re-derived <raw arg>/.jj/repo
      after loading a workspace it then ignored; it now takes the repo path from that workspace's
      own canonical root), which is what Story 9.23's `workspace add` gets for free from a Repo
      that is canonical end to end - so 9.23 no longer inherits the trap. The committed fixture
      is untouched, so this story's stale-entry rows still hold.
  - summary: >-
      Request tables are structurally interchangeable, so a hand-crafted `ShowRequest` verifies
      as a `WorkspaceRootRequest` and its revset is read as a workspace name.
    evidence: |-
      `schemas/envelope.fbs` declares no `file_identifier` (only `root_type Envelope`), and
      `WorkspaceRootRequest` puts a single string in the first slot exactly as `ShowRequest`
      does. House-wide since Story 9.3 and already on 9.6's deferred list; 9.7 adds a table
      that makes the collision exact, so it is carried forward rather than dropped. Only
      reachable by a caller that bypasses the generated Dart adapters, so the fix belongs with
      the schema convention, not with one story.
    location: >-
      schemas/envelope.fbs
    severity: low
  - summary: >-
      `docs/ffi-abi.md` has been stale since Story 4.9 and gains no entry for the two new
      `extern "C"` functions.
    evidence: |-
      The file lists none of the verbs added by Stories 9.4–9.6 either (`zanshin_file_list`,
      `zanshin_git_import`, `zanshin_show`, `zanshin_evolog` all return no match). Each of
      those stories recorded the staleness in its `sprint-status.yaml` summary; carried
      forward here so the debt stays on the ledger while the ABI surface keeps growing.
    location: >-
      docs/ffi-abi.md
    severity: low
    resolved: >-
      RESOLVED 2026-09-06 by spec-epic-9-followup-g-ffi-abi-doc-pass. `docs/ffi-abi.md` now
      carries a `## Symbol index` with one row per exported symbol — 47 of them, so
      `zanshin_workspace_list` and `zanshin_workspace_root` (with `WorkspaceRootRequest` and
      the `WorkspaceList` / `WorkspaceRoot` payloads and their three distinct workspace
      refusals) are covered alongside every verb Stories 9.4–9.6 added — plus a
      `## Request-buffer contract` section documenting the shared composite-input pattern
      once. `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs` fails the build if the ABI surface
      grows past the document again.
  - summary: >-
      `WorkspaceEntry.wc_commit_id` is the LAST-SNAPSHOTTED working-copy commit, where the
      CLI's `jj workspace list` snapshots first.
    evidence: |-
      `cmd_workspace_list` uses `command.workspace_helper(ui)`, which snapshots the working
      copy (`cli/src/cli_util.rs:459-477` @ v0.44.0), while `workspace root --name` uses
      `workspace_helper_no_snapshot`. Zanshin snapshots in neither — the epic-wide D2
      deferral — so an uncommitted edit made outside Zanshin leaves the reported commit id
      behind the CLI's. Recorded by Stories 9.4/9.5/9.6 the same way; carried forward because
      it is now a COLUMN of a shipped payload rather than a defaulted argument.
    location: >-
      crates/zanshin-jj/src/workspace.rs::list_workspaces
    severity: low
---

<intent-contract>

## Intent

**Problem:** A GUI cannot answer the two questions `jj workspace list` and `jj workspace root` answer:
*which workspaces does this repo have, where does each one live, and where is this one rooted*.
Story 9.2 shipped the VIEW half (`view.rs::list_working_copies` — name + working-copy commit id) but
deliberately stopped at the boundary it documents at `view.rs:156-157`: "No workspace *path* is
reported — that lives in the `WorkspaceStore`, not the `View`." Nothing in the workspace has ever
touched `jj_lib::workspace_store`, and neither verb reaches FFI, so a multi-workspace user has no way
to see or locate a sibling workspace from Zanshin.

**Approach:** Add a new `zanshin-jj` noun module `workspace.rs` holding the two typed read verbs —
`list_workspaces` (the existing view half + the path half read from `SimpleWorkspaceStore`) and
`resolve_root(name: Option<&str>)` (the CLI's `jj workspace root [--name]`) — and surface both through
the chain 9.3–9.6 established: `.fbs` → typed op → `extern "C"` + committed codegen → Dart
adapter/`WorkerCommand`/`ZanshinWorker`/`RepoHandle` → tests. The jj CLI at tag `v0.44.0` is the
behavioral oracle for argument arity, defaults, refusals and op-log effect.

## Boundaries & Constraints

**Always:**
- Both verbs are READS: no transaction, no operation written — not even on a refusal. Assert the head
  operation id is unchanged around every call, success and failure alike (the
  `no_commit_view_wrapper_writes_an_operation` pattern, `crates/zanshin-ffi/tests/commit_views_ffi.rs:486`).
- CLI parity @ `v0.44.0` on **argument arity, defaults and refusals**: `workspace list` takes NO
  argument at all (only `-T`, which is rendering) and lists one row per entry of
  `View::wc_commit_ids()` in jj-lib's own `BTreeMap` order; `workspace root` takes one OPTIONAL
  `--name` (long-only) that must be passed through (FR-JJ-17), defaulting to the CURRENT workspace.
- Reproduce the CLI's own **asymmetry** between the two verbs on an unusable path: `list` degrades
  (`dunce::canonicalize(..).ok()` → the row keeps its name and commit and reports no root,
  `cli/src/commit_templater.rs:1787`), `root --name` REFUSES with three distinct errors
  (`cli/src/commands/workspace/root.rs:50-72`). Do not unify them.
- Mirror the CLI's check ORDER in `root --name` exactly: load the store, then the view-membership
  check, then `get_workspace_path`, then join + canonicalize. Each stage has its own refusal.
- `resolve_root(None)` reads the loader only — no repo load, no store read — exactly as
  `root.rs:78` does. It is the one path that cannot fail.
- Path currency: `PathBuf` in the `zanshin-jj` public API (the `RepoRoot.root` precedent,
  `detect.rs:42`), `to_string_lossy()` at the FFI boundary (`zanshin-ffi/src/repo.rs:271`), a plain
  `string` on the wire, null-for-absence for an unavailable root.
- `zanshin-jj` stays sync (`pollster::block_on` for jj-lib's async), stays `jj_lib`-type-free in every
  public signature (`lib.rs:17-28`), and keeps `#![deny(missing_docs)]` satisfied.
- Every new `extern "C"` fn needs at least one `packages/zanshin_core` test that calls it through the
  real cdylib, or the coverage gate's extern-fn guard fails (`Makefile.toml:537-564`).

**Block If:**
- jj-lib 0.44.0 does not expose `workspace_store::{SimpleWorkspaceStore, WorkspaceStore}` with the
  signatures recorded in the Code Map (pin drift): HALT with `blocked`, blocking condition
  `jj-lib API drift`.
- The coverage ratchet can only be made green by lowering a baseline entry or adding an
  `exclude_prefix`: HALT with `blocked`, blocking condition `coverage ratchet regression`.

**Never:**
- No workspace MUTATION: `workspace add`/`forget`/`rename`/`update-stale` are Stories 9.13 and 9.23.
  `WorkspaceStore::{add,forget,rename}` must not be called from production code in this story.
- No fixture regeneration (forbidden, `test-helpers/src/lib.rs:135-138`) — in particular, do NOT
  regenerate a fixture to "fix" its stale recorded workspace path. That staleness is a test asset.
- No terminal UX: no templates, `-T`, `templates.workspace_list`, `root.relative()` rendering, or
  CWD-relative path shortening. The GUI formats; the backend returns absolute paths.
- No change to `view.rs`'s shipped `list_working_copies` / `WorkingCopy` contract — it stays the raw
  View read; the new verb composes on top of it.
- No renaming of the existing infallible `Repo::workspace_root() -> &Path` accessor (`repo.rs:96-100`)
  to free the name — it has a production call site that cannot handle a `Result`
  (`zanshin-ffi/src/repo.rs:401`).
- No shelling to `jj`, no MCP tool (`zanshin-mcp` is still a stub; Epic 7 owns the tool surface, and
  9.3–9.6 all skipped it).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| list, single-workspace fixture | `list_workspaces()` on `tiny-3-commits` | Exactly one entry: `name == "default"`, `wc_commit_id` equal to the raw-jj-lib oracle's `wc_commit_ids()["default"]`, and `root == None` — the committed fixture records a path relative to the GENERATOR's temp dir, which no longer resolves | No error expected |
| list, second workspace | after `test_helpers::add_workspace(root, "second")` | Two entries in `BTreeMap` order (`default`, `second`); `second.root` is `Some(<second workspace root>)` (compare canonicalized), `default.root` is still `None` | No error expected |
| list, no recorded path | `.jj/repo/workspace_store` removed, then `list_workspaces()` | One entry, `root == None`, `ok = true`; jj-lib recreates the store dir empty | No error expected |
| list, unreadable store | `.jj/repo/workspace_store/index` overwritten with non-protobuf bytes | Entries still returned with `root == None` — a path failure NEVER fails the listing (CLI parity) | No error expected |
| root, current workspace | `resolve_root(None)` | The open workspace's root, equal to `Repo::workspace_root()`; the one path that reads neither repo nor store | No error expected |
| root, named second workspace | `resolve_root(Some("second"))` | That workspace's root (compare canonicalized) — proving a sibling workspace's path is visible from this one | No error expected |
| root, named current workspace on the fixture | `resolve_root(Some("default"))`, fixture untouched | Refusal, even though `resolve_root(None)` succeeds — the named path goes through the store, which holds a stale path (CLI parity: `root --name` never shortcuts to the loader) | `jj.workspace_path_unresolved`, context names the workspace and the I/O reason |
| root, unknown name | `resolve_root(Some("nosuch"))` | Refusal | `jj.workspace_not_found`, context = the name |
| root, empty name string | `resolve_root(Some(""))` | Refusal — an explicitly present empty string is a VALUE, not an absence, and no workspace is named `""` | `jj.workspace_not_found` |
| root, name present but no recorded path | store dir removed, `resolve_root(Some("default"))` | Refusal, distinct from the stale-path one | `jj.workspace_no_recorded_path`, context = the name |
| root, unreadable store | garbage `index`, `resolve_root(Some("default"))` | Refusal | `jj.jj_lib_error`, context = jj-lib's reason |
| any verb, unknown handle | `handle = 0` or a closed handle | No call into `zanshin-jj` | `ffi.invalid_handle` |
| `zanshin_workspace_root`, null request buffer | `data = null` | — | `ffi.null_pointer` |
| `zanshin_workspace_root`, malformed request buffer | non-FlatBuffers bytes | Verifier rejects before use | `ffi.invalid_argument` |
| either verb, success and refusal | any of the above | The head operation id is unchanged, at both the `zanshin-jj` and the FFI layer | — |

</intent-contract>

## Code Map

Zanshin anchors read against the working tree at baseline `7989ca0`; jj CLI anchors at tag `v0.44.0`
(`git -C ../jj show v0.44.0:<path>`); jj-lib anchors in the vendored `jj-lib-0.44.0`.

**Prior art (read-only, at the tag)**
- `v0.44.0:cli/src/commands/workspace/list.rs:27-47` — `WorkspaceListArgs` has exactly ONE field,
  `-T/--template`; no positional, no filter. `:73` walks `repo.view().wc_commit_ids()` directly, `:74`
  resolves each commit, `:76` builds a `WorkspaceRef`.
- `v0.44.0:cli/src/commit_templater.rs:1746-1790` — the row's three observable fields: `name`,
  `target` (the wc commit) and `root` → `Option<PathBuf>`. `root()` at `:1771-1789` reconstructs a
  loader, does `SimpleWorkspaceStore::load(&repo_path)` `:1780`, `get_workspace_path(self.name())`
  `:1785`, `repo_path.join(..)` `:1786` and `dunce::canonicalize(path).ok()` `:1787` — **every failure
  collapses to `None`**. The comment at `:1781-1783` names the cause: workspaces created before jj
  0.38.0 have no recorded path. `root` shipping in the default row is new in 0.44.0.
- `v0.44.0:cli/src/commands/workspace/root.rs:32-37` — `--name: Option<WorkspaceNameBuf>`, long-only,
  "defaults to current". `:78` is the no-name path: `workspace_loader()?.workspace_root()` — no repo,
  no snapshot. `:46-77` is the named path, in this order: `SimpleWorkspaceStore::load` `:48` →
  `view().wc_commit_ids().contains_key(ws_name)` else `No such workspace` `:50-55, :73-76` →
  `get_workspace_path(..)? == None` ⇒ `Workspace has no recorded path` `:56-63` →
  `repo_path().join(path)` + `dunce::canonicalize` ⇒ `Cannot resolve absolute workspace path`
  `:64-72`. `:80-83` writes raw path BYTES, not `Display`.
- `v0.44.0:cli/tests/test_workspaces.rs:96-101` (row shape), `:1907-1926` (deleted directory ⇒ the
  resolve error), `:2057-2063` (unknown name), `:2082-2101` (no recorded path ⇒ `list` omits the root
  while `root --name` errors).

**jj-lib 0.44.0 (vendored, exact signatures)**
- `view.rs:64` `pub fn wc_commit_ids(&self) -> &BTreeMap<WorkspaceNameBuf, CommitId>` — the ordering
  guarantee is the `BTreeMap`'s (lexicographic by name); `:68` `get_wc_commit_id(&WorkspaceName)`.
- `workspace_store.rs:48-70` `pub trait WorkspaceStore` — the ONLY read method is
  `fn get_workspace_path(&self, &WorkspaceName) -> Result<Option<PathBuf>, WorkspaceStoreError>`
  `:66-69`. There is **no list-all**, which is why `list` is one store read per row.
- `workspace_store.rs:105` `pub fn SimpleWorkspaceStore::load(repo_path: &Path) -> Result<Self, _>` —
  `repo_path` is the `.jj/repo` dir. **`load` is not read-only**: `:117-125` creates
  `workspace_store/` and writes an empty store when the dir is absent (legacy repos). It writes no
  operation.
- `workspace_store.rs:176-181` (in `add`) — the stored path is `relative_path(repo_path, path)`,
  slash-normalized, so it is **relative to `.jj/repo`**; both CLI callers therefore do
  `repo_path.join(stored)` and must canonicalize (the join keeps `../..` segments).
- `workspace_store.rs:134-140` `read_store` — a missing or non-protobuf `index` is an `Err`, not a
  `None`. `:41-45`/`:74-93` `WorkspaceStoreError::Other(Box<dyn Error>)` is **not structurally
  matchable**: only its message is available, which is exactly what a `Backend(String)` variant wants.
- `workspace.rs:421` `workspace_root(&self) -> &Path`, `:425` `workspace_name(&self) -> &WorkspaceName`,
  `:429` `repo_path(&self) -> &Path`. There is no `workspace_id()` in 0.44.0.
- `workspace.rs:391`/`:406` — `init_workspace_with_existing_repo` loads the SHARED repo's store and
  `add`s the new workspace, so a secondary workspace's path is visible from the primary one.
- `ref_name.rs:100`/`:111` `WorkspaceNameBuf`/`WorkspaceName`; `:157` `const fn new(&str) -> &Self`
  (zero-copy ref-cast), `:160-162` `as_str`. Names are guaranteed UTF-8 (backed by `String`); only
  PATHS need lossy handling.

**Extend — `crates/zanshin-jj`**
- `src/workspace.rs` (**NEW**) — `WorkspaceEntry`, `WorkspaceError`, `list_workspaces`,
  `resolve_root`, and a module-private path resolver shared by both verbs. Module-doc shape:
  `view.rs:3-9` / `commit_views.rs` (CLI parity tag, ported CLI files, deliberate divergences).
- `src/view.rs:152-174` `list_working_copies` — **the view half, reused not copied**; `WorkingCopy`
  `:46-57`; `ViewError` `:59-67` and `be` `:69-72` are the minimal error template.
- `src/commit_views.rs:104-181` — the full error-enum template: per-variant docs, `#[error(..)]`
  strings, the `be` helper `:153-156`, and `res` `:172-181` (mapping a resolver error plus the
  offending id into a variant).
- `src/config.rs:381-386` — the crate's ONLY existing `workspace.repo_path()` use, with the WHY
  comment explaining that `repo_path()` is jj-lib's already-resolved `.jj/repo` (it follows the FILE
  indirection in a secondary workspace). The store lives under exactly that path.
- `src/detect.rs:42` `RepoRoot.root: PathBuf` — the one precedent for a filesystem path in a public
  struct field. `to_string_lossy` appears nowhere in this crate; `.display()` only inside error
  message strings (`config.rs:163`).
- `src/repo.rs:96-100` `workspace_root()` (**do not rename**), `:103` `workspace()`, `:207-220` the
  `list_working_copies` facade (the closest doc template), Story 9.6 block `:909-1044`, Story 9.3
  `restore` at `:1046`. Insert the Story 9.7 facades after `:1044`.
- `src/lib.rs:30-47` module list (append `pub(crate) mod workspace;` after `view` at `:47`), `:49-65`
  re-export block (append `pub use workspace::{WorkspaceEntry, WorkspaceError};` after `:65`).
  `#![deny(missing_docs)]` `:3`; the `jj_lib`-type-free rule `:17-28`.

**Extend — wire + FFI**
- `schemas/envelope.fbs` — request tables end at `:212` (append `WorkspaceRootRequest` there; **field
  order is the wire contract**, `:32-39`); the null-for-absence rule for an optional request string is
  spelled out at `:174-177`. Ledger comment `:214-230` (append a `//   Story 9-7  : …` line). Payload
  tables end at `:800`; `union Payload` `:802-827` — **next free discriminants are 24 and 25**,
  appended after `InterdiffView` `:826`. Closest payload shapes: `Remotes`/`Remote` `:335-345` (a
  vector of two-string tables) and `RepoDetect.suggested_root` `:351-364` (the only other absolute
  filesystem path on the wire, present-or-absent).
- `crates/zanshin-ffi/src/workspace.rs` (**NEW**) + `pub mod workspace;` in `lib.rs:32-49` between
  `tracing_init` `:48` and `watcher` `:49` (alphabetical — `cargo fmt` re-sorts and the header must
  then be regenerated; see commit `f77ecbf`). Templates: `commit_views.rs` — module doc `:1-17`, error
  mapper `:34-50`, request-reader banner + soundness note `:52-57`, the one-optional-string reader
  `:81-95`, a vector-of-tables payload builder `:136-160` ending in `finish_envelope`,
  `session_from_handle` `:203-215`, and an `extern "C"` wrapper with its full doc block `:219-270`.
  For the argument-free wrapper: `remotes.rs:78-94` `zanshin_remotes` (**but build the envelope with
  `finish_envelope`, not `remotes.rs:50-60`'s hand-rolled `fbs::Envelope::create` — that predates the
  helper**).
- `crates/zanshin-ffi/src/envelope.rs` — code constants `:14-106`; reuse `FFI_INVALID_HANDLE` `:18`,
  `FFI_NULL_POINTER` `:20`, `FFI_INVALID_ARGUMENT` `:24`, `JJ_JJ_LIB_ERROR` `:32`; **add three new
  consts** here (single-emission-point rule). `FfiErrorObj` `:124`, `reject_null_request` `:140`,
  `invalid_request` `:151`, `finish_envelope` `:363`, `err` `:387`, `catch` `:429`.
- `crates/zanshin-ffi/src/repo.rs:271` — `b.create_string(&root.root.to_string_lossy())`, the
  path→wire precedent; `:299-320` `RepoSession`, whose doc enumeration of the read wrappers that
  borrow `.repo` (`:304-306`) must gain this story's two.
- `crates/zanshin-ffi/src/ffi_strings.rs` — `ZanshinBuf` and `vec_into_token`, the wrapper return path.
- Generated, regenerate only via `cargo make codegen`: `crates/zanshin-ffi/include/zanshin_ffi.h`,
  `crates/zanshin-ffi/src/envelope_generated.rs`,
  `packages/zanshin_core/lib/src/ffi/{bindings.dart,envelope_zanshin.ffi_generated.dart}`.

**Extend — Dart (`packages/zanshin_core`)**
- `lib/src/ffi/workspace.dart` (**NEW**) — banners `// ── Request-buffer helpers ──` /
  `// ── FFI adapters ──` / `// ── Dart models ──` / `// ── Decoder ──`. Templates in
  `ffi/commit_views.dart`: `_withRequestBytes` `:31-44`, `_rejectInteriorNul` `:46-55`,
  `_callWithRequest` `:57-70`, the one-optional-string adapter `:86-90`, a model `:153-166`, the
  decoder triple with its union-discriminant guard `:203-216`, `_okEnvelope` `:282-…`. For the
  argument-free verb: `ffi/remotes.dart:21-29` (adapter) and `:53-70` (decoder) — but use
  `_okEnvelope`, not remotes' inlined `!env.ok` check.
- `lib/src/worker/commands.dart` — sealed base `:3-17`; request-carrying template `ShowCommand`
  `:636-657`; append after `InterdiffCommand` ends `:712`, before `ShutdownCommand` `:714` (**must
  stay last**).
- `lib/src/worker/isolate.dart` — aliased import block `:11-36` (add after `status` `:36`);
  `ZanshinWorker` method template `show` `:1080-1085`, append after `interdiff` `:1118-1153`;
  switch-arm template with the synthesized `ffi.invalid_handle` envelope `:1759-1774`, append after
  the `InterdiffCommand` arm `:1793-1813`, before `case ShutdownCommand():` `:1815`.
- `lib/src/worker/handle.dart` — the `_closed`-guard method template `show` `:629-634`; append after
  `interdiff` `:673-706`, before the GC-backstop comment `:708`.

**Tests / gates**
- `crates/zanshin-jj/tests/view.rs` — the closest harness AND the file that already covers the view
  half: `ENV_GUARD` `:25-29`, `pin_env` `:31-33`, `make_test_settings` `:35-52`, `oracle_workspace`
  `:54-63`, **`wc_pairs` (the raw jj-lib oracle for name→commit)** `:81-90`, `corrupt_op_heads`
  `:92-95`, and the three existing wc tests `:399`, `:420` (already uses `add_workspace`), `:453`.
- `crates/zanshin-jj/tests/commit_views.rs` — the fuller harness: `head_op_id` `:106-109`, `open`
  `:115-117`, `write_repo_config` `:111-113`, and the read-writes-no-operation idiom (capture
  `head_op_id` before, assert equal after — used on refusals too, `:529`/`:538`).
- `crates/test-helpers/src/lib.rs:509-541` **`add_workspace(workspace_root, name) -> (FixtureHandle,
  String)`** — creates a real secondary workspace in its own `TempDir` (parallel-test safety, WHY at
  `:513-515`), records its path in the shared store, and returns the new workspace root as
  `handle.path` plus its wc commit hex. This is the only way to reach a resolvable root in a test.
  `extract_fixture` `:41`; fixture regeneration is forbidden `:135-138`.
- **Fixture fact (verified by decoding the committed archive):**
  `tiny-3-commits.tar.zst` DOES contain `.jj/repo/workspace_store/index`, and it records `default` →
  `../../../../../../../../private/var/folders/…/T/.tmpGOpTuZ` — the generator's temp directory.
  After extraction that path does not exist, so canonicalize fails. This is what makes the fixture a
  free witness for both the `list` degradation and the `root --name` stale-path refusal.
- `crates/zanshin-ffi/tests/commit_views_ffi.rs` — `read_and_free` `:55`, the `Wrapper` fn-pointer
  alias `:67` (**a handle-only verb needs a second alias, `fn(u64) -> *mut ZanshinBuf`**),
  `parse_envelope` `:69`, `open_handle`/`close_handle` `:78`/`:91`, request builders `:112-162`
  (including deliberately-absent-field variants), `open_scenario` `:163-171` (with the
  `std::mem::forget(fixture)` so the `TempDir` outlives the handle), the table-driven guard contract
  `:426-430`, and `no_commit_view_wrapper_writes_an_operation` `:486`. `remotes_ffi.rs` is the
  handle-only second model.
- `packages/zanshin_core/test/ffi/commit_views_test.dart` — `errorEnvelope` `:23`, `wrongPayload`
  `:29`; `test/ffi/remotes_test.dart` for the handle-only shape.
- `packages/zanshin_core/test/worker/commit_views_test.dart:3-27` — **the header paragraph the new
  worker test file must carry** (real `Isolate.spawn` + real cdylib, and "what credits each
  `zanshin_*` extern \"C\" function in the coverage ratchet's extern-fn guard"), plus the closed- and
  unknown-handle tests `:170`, `:183`.
- `crates/zanshin-jj/tests/api_stability.rs` — the running type count in the header `:12-18`
  (**currently 58**), alias blocks `:20-112` (appended in STORY order), `sample_*` constructors
  ending `:325`, and the per-story `*_surface_resolves` convention `:596-655` (which also asserts
  every new error variant's `Display`, because an unexercised `thiserror` arm is an uncovered line).
  Never extend `api_surface_resolves` `:272`.
- `Makefile.toml` — `[tasks.test]` `:47-72` (`coverage` last), `[tasks.codegen]` `:289-295`,
  `[tasks.verify-codegen]` `:348-446` (manual; refuses on a dirty tree), `[tasks.coverage]` `:449-571`
  with the **extern-fn guard** `:537-564`: it greps every `extern "C" fn` name out of
  `crates/zanshin-ffi/src` and fails on `FNDA:0,<name>`, and a Rust-only integration test does NOT
  satisfy it.
- `coverage-baseline.txt` — knobs `:1-13` (`epsilon_pct = 0.10`, `new_file_floor_pct = 80.00`);
  `zanshin-ffi/src/*` `:14-33` (siblings at 100.00; insert `workspace.rs` after `watcher.rs` `:33`);
  `zanshin-jj/src/*` `:37-54` — `repo.rs = 95.97`, `view.rs = 96.15`, insert `workspace.rs` after
  `view.rs` `:54`.
- `docs/rust-error-codes.md` — the code table `:35-65`, the four-step add procedure `:69-74`, the
  established reuse annotation `; also emitted — Story 9.x by …` (`:39`, `:40`, `:45`), and the
  precedent for minting a sibling code because the REMEDY differs (`jj.remote_exists` `:64`,
  `jj.remote_nonstandard_config` `:65`).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/workspace.rs` (new) -- add the module doc (CLI parity tag `v0.44.0`, the two
  ported CLI files, the deliberate divergences listed under **Never**, and the note that
  `SimpleWorkspaceStore::load` may CREATE `.jj/repo/workspace_store/` on a legacy repo while writing
  no operation), the owned type `WorkspaceEntry { name: String, wc_commit_id: CommitId, root:
  Option<PathBuf> }` (`#[derive(Debug, Clone, PartialEq, Eq)]`, matching `WorkingCopy`), and
  `WorkspaceError` with `NotFound { name }`, `NoRecordedPath { name }`, `PathUnresolved { name,
  reason }` and `Backend(String)` -- one variant per CLI refusal, because the remedies differ
  (`jj.remote_exists` set that precedent).
- `crates/zanshin-jj/src/workspace.rs` -- implement `list_workspaces(workspace: &Workspace) ->
  Result<Vec<WorkspaceEntry>, WorkspaceError>`: reuse `view::list_working_copies` for the view half
  (mapping its `ViewError::Backend` onto `WorkspaceError::Backend`), then per row look the path up in
  `SimpleWorkspaceStore::load(workspace.repo_path())`, join it onto `repo_path` and canonicalize --
  with EVERY path-side failure (store load, store read, absent entry, canonicalize) collapsing to
  `root: None` so a broken path can never fail the listing, exactly as the CLI's `WorkspaceRef::root`
  does.
- `crates/zanshin-jj/src/workspace.rs` -- implement `resolve_root(workspace: &Workspace, name:
  Option<&str>) -> Result<PathBuf, WorkspaceError>`: with `name` absent return
  `workspace.workspace_root()` without touching repo or store; with a name present run the CLI's four
  stages in order -- store load (`Backend`), `load_at_head` + `view().wc_commit_ids()` membership
  (`NotFound`), `get_workspace_path` (`Err` ⇒ `Backend`, `Ok(None)` ⇒ `NoRecordedPath`), join +
  `std::fs::canonicalize` (`PathUnresolved`, carrying the I/O reason). Use `WorkspaceName::new(name)`;
  names are UTF-8 by construction.
- `crates/zanshin-jj/src/repo.rs` -- add the two `#[must_use]` facades after the Story 9.6 block:
  `list_workspaces()` and `resolve_workspace_root(name: Option<&str>)`, each a one-line delegation
  with the house doc block (summary naming the CLI verb, the ADR-0002 re-resolve + read-only +
  never-writes-an-operation sentence, defaults, the deliberate divergences, `# Errors` one bullet per
  variant). Both docs must state the relationship to their neighbours: `list_workspaces` is
  `list_working_copies` plus the path half, and `resolve_workspace_root(None)` returns exactly what
  the infallible `workspace_root()` accessor returns -- while `resolve_workspace_root(Some(<current
  workspace's own name>))` can still REFUSE, because the CLI's named path goes through the store.
- `crates/zanshin-jj/src/lib.rs` -- declare `pub(crate) mod workspace;` and re-export
  `WorkspaceEntry` + `WorkspaceError`, both after the `view` entries.
- `schemas/envelope.fbs` -- append `WorkspaceRootRequest { name }` to the request block (documenting
  absent = the current workspace, and that a present empty string is a VALUE); append
  `WorkspaceEntry { name; wc_commit_id; root }` + `WorkspaceList { entries }` + `WorkspaceRoot
  { root }` to the payload tables (documenting null-for-absence on `root` and the list/root
  asymmetry); append `WorkspaceList`, `WorkspaceRoot` as Payload slots 24-25; add the Story 9-7 ledger
  line.
- `crates/zanshin-ffi/src/envelope.rs` -- add `JJ_WORKSPACE_NOT_FOUND`, `JJ_WORKSPACE_NO_RECORDED_PATH`
  and `JJ_WORKSPACE_PATH_UNRESOLVED` consts in the code block, keeping the single-emission-point rule.
- `crates/zanshin-ffi/src/workspace.rs` (new) + `lib.rs` -- add the error mapper, the
  `WorkspaceRootRequest` reader returning an owned struct (null/verifier guards via
  `reject_null_request`/`invalid_request`), the two payload builders ending in the shared
  `finish_envelope` (paths via `to_string_lossy`), and the two `extern "C"` wrappers
  `zanshin_workspace_list(handle)` and `zanshin_workspace_root(handle, data, len)` with the full doc
  block (`# Errors` one bullet per code, `# Safety` handle + buffer + free-once contract); extend the
  `RepoSession` doc's read-wrapper enumeration.
- `cargo make codegen` -- regenerate and commit `zanshin_ffi.h`, `envelope_generated.rs`,
  `bindings.dart` and `envelope_zanshin.ffi_generated.dart` in the same change as the `.fbs` and
  `extern "C"` edits; `cargo make verify-codegen` must then report no drift on a clean tree.
- `packages/zanshin_core/lib/src/ffi/workspace.dart` (new) -- the two adapters (interior-NUL guard on
  `name`), the `WorkspaceEntry` model with a nullable `root`, and the two decoder triples that guard
  the union discriminant before the cast.
- `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` -- add `WorkspaceListCommand`
  and `WorkspaceRootCommand` (before `ShutdownCommand`), the aliased import, the two `ZanshinWorker`
  methods, the two switch arms with the synthesized `ffi.invalid_handle` envelope, and the two
  non-async `RepoHandle` methods behind the `_closed` guard.
- `crates/zanshin-jj/tests/workspace.rs` (new) -- cover every jj-level row of the I/O matrix against a
  raw jj-lib oracle, using `add_workspace` for the resolvable-root rows, removing
  `.jj/repo/workspace_store` for the no-recorded-path rows and writing non-protobuf bytes into `index`
  for the unreadable-store rows; assert `head_op_id` is unchanged around every call including
  refusals, and canonicalize both sides of every path comparison (the macOS `/var` → `/private/var`
  trap, already pinned at `tests/repo.rs:211-214`).
- `crates/zanshin-ffi/tests/workspace_ffi.rs` (new) -- cover the envelope/verifier contract, the
  request reader (absent-name and malformed-buffer variants), a zero-handle assertion for BOTH
  wrappers (the handle-only one needs its own fn-pointer alias), and one cross-cutting
  no-operation-written test.
- `packages/zanshin_core/test/ffi/workspace_test.dart` +
  `packages/zanshin_core/test/worker/workspace_test.dart` (new) -- decode-contract tests over
  synthetic buffers (ok / error / wrong-payload / empty-list / absent-root) and real-cdylib worker
  tests that call BOTH `extern "C"` functions at least once, carrying the extern-fn-guard header
  paragraph.
- `crates/zanshin-jj/tests/api_stability.rs` -- add the Story 9.7 alias block, bump the header type
  count, add a `sample_workspace_entry()` naming every field, and a `workspace_surface_resolves` test
  pinning both method signatures and every `WorkspaceError` variant's `Display`.
- `docs/rust-error-codes.md` -- add the three new rows (domain `jj`, meaning, "Emitted — Story 9.7"
  plus the remedy-differs rationale) and append `; also emitted — Story 9.7 by …` clauses to the
  reused rows (`ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.jj_lib_error`).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- flip
  `9-7-workspace-reads-list-root` to `done` with a summary comment in the established style.

**Acceptance Criteria:**
- Given the two verbs exist, when a caller reaches them from Dart, then the whole chain is present for
  each -- `.fbs` payload (plus the request table for `workspace root`), typed `zanshin-jj` op,
  `extern "C"` wrapper, regenerated and committed codegen, Dart adapter, `WorkerCommand`,
  `ZanshinWorker` method and `RepoHandle` method -- and `cargo make verify-codegen` reports no drift.
- Given a repo with two workspaces, when `list_workspaces` runs, then its name/commit half is
  byte-identical to what `View::wc_commit_ids()` reports through the raw jj-lib oracle -- proving the
  view half is reused from `view.rs` rather than re-derived -- and the second workspace's `root`
  equals the directory `add_workspace` created.
- Given a workspace whose recorded path does not resolve, when `list_workspaces` reports it, then the
  row is still returned with `root` absent; given the same workspace through
  `resolve_workspace_root(Some(name))`, then the call REFUSES -- the CLI's own asymmetry, reproduced
  rather than smoothed over.
- Given either verb is called, when it succeeds **and** when it refuses, then the head operation id is
  unchanged, at both the `zanshin-jj` and the FFI layer.
- Given the three new `error.code` values, when the registry is inspected, then each has a row naming
  Story 9.7 and the remedy that distinguishes it from its siblings, and each is declared exactly once
  in `crates/zanshin-ffi/src/envelope.rs`.
- Given `cargo make test` runs on the final tree, then it exits 0 -- cargo test, clippy pedantic
  `-D warnings`, rustfmt, flutter/dart analyze + format, `cargo deny`, the coverage ratchet and the
  extern-fn guard -- with no baseline entry lowered and no `exclude_prefix` added, and the raised
  `coverage-baseline.txt` is committed with the code that earned it.
- Given the working tree at the end of the run, when `git status --porcelain` is inspected, then it is
  clean and every commit message ends with the required co-author trailer.

## Spec Change Log

## Review Triage Log

### 2026-09-04 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 9: (high 0, medium 1, low 8)
- defer: 4: (high 0, medium 1, low 3)
- reject: 13: (high 0, medium 2, low 11)
- addressed_findings:
  - `[medium]` `[patch]` No test ever opened the SECONDARY workspace — every case did
    `Repo::open(&fx.path)` and used the sibling root only as an expected value. In a secondary
    workspace `.jj/repo` is a FILE pointing at the shared repo, and `Workspace::repo_path()`
    resolving that indirection is the join base for every store lookup; deriving it locally as
    `workspace_root().join(".jj").join("repo")` left the whole suite green while every root went
    absent from the secondary side. `secondary_workspace_sees_the_shared_store_through_the_repo_file`
    now asserts the `.jj/repo` file, both rows with a resolvable sibling root,
    `resolve_workspace_root(None)` being that workspace's own root, and `Some("default")` reaching
    the shared store.
  - `[low]` `[patch]` `workspaceRoot`'s interior-NUL guard lived only in the FFI adapter, which
    runs in the WORKER isolate — so the `ArgumentError` was caught by the dispatch loop and reached
    the caller as `internal.dispatch_error`. The same defect Story 9.6's review fixed for `evolog`'s
    limit. Guard moved to the calling side, adapter guard kept as the direct-caller backstop, and
    the `ArgumentError` now documented on both `ZanshinWorker.workspaceRoot` and
    `RepoHandle.workspaceRoot`.
  - `[low]` `[patch]` Both store-LOAD failure branches (`list`'s `.ok()` degradation and `root`'s
    `map_err(be)`) shipped unpinned: `SimpleWorkspaceStore::load` never reads the index, so the
    corrupt-index tests hit `get_workspace_path` instead, and line coverage cannot see the
    difference. A dangling symlink at the store path makes `load` itself fail deterministically
    (`exists()` follows the link → `create_dir` returns EEXIST), driving two new tests.
  - `[low]` `[patch]` `jj.jj_lib_error` is documented for both wrappers and had no witness at the
    FFI layer — the jj-level `Backend` test and the inline mapper unit test never compose the
    wrapper's own path. `both_wrappers_report_jj_lib_error_when_the_head_cannot_be_resolved`
    destroys `op_heads` under an already-open handle.
  - `[low]` `[patch]` The `BTreeMap`-order assertion `["default", "second"]` was satisfied by
    insertion, creation and lexicographic order alike, so it pinned nothing. A workspace named
    `aaa` is now added LAST, and only lexicographic order yields `["aaa", "default", "second"]`.
  - `[low]` `[patch]` Three doc sites promise the returned root is "ABSOLUTE and canonicalized",
    but `resolve_root(None)` returns `workspace.workspace_root()` verbatim and every assertion
    canonicalized BOTH sides, so a non-canonical return would have passed. The returned path is now
    asserted to be already canonical, with the WHY naming jj-lib's `Workspace::new`
    (`workspace.rs:170`) as where the guarantee actually comes from.
  - `[low]` `[patch]` The GUI's null-root path and two of the three new codes were never witnessed
    end to end through the real cdylib. A worker test now wipes the store from Dart and asserts both
    a `null` root and `jj.workspace_no_recorded_path`; the file's SCOPE NOTE was corrected, since
    the degraded-path rows turned out to be reachable from Dart after all.
  - `[low]` `[patch]` `WorkspaceEntry.wcCommitId`'s Dart doc referenced `WorkingCopy.commitId`, a
    type that exists only in Rust — nothing named `WorkingCopy` exists in `packages/zanshin_core`.
    Reworded against `View::wc_commit_ids()` and `WorkingCopyStatus`.
  - `[low]` `[patch]` The `sprint-status.yaml` entry was written before the review and carried no
    commit hashes, no `Review: …` clause, and had dropped two ledger items its three predecessor
    stories carried forward (`docs/ffi-abi.md` stale since 4.9, and the D2 no-snapshot note that now
    affects a shipped payload column). Refreshed to the reviewed final state.

## Design Notes

**Why a new noun module rather than extending `view.rs`.** `view.rs` is "the direct `View` reads" and
its own doc draws the line this story crosses: the path lives in the `WorkspaceStore`, not the `View`.
Extending `WorkingCopy` with a `root` field would push a store read into a module whose contract is
"read straight off the head-resolved `View` — no revset is evaluated". Instead `workspace.rs` owns the
store and composes: `list_workspaces` calls `view::list_working_copies` for the half that already
exists and attaches the half that does not. The two public shapes stay distinct on purpose --
`WorkingCopy` is the raw View row (`zanshin-jj`-only), `WorkspaceEntry` is the `jj workspace list`
row (the FFI verb) -- the same split `list_bookmarks` (unfiltered) and `CommitMeta::tags` (filtered)
already make.

**Why `resolve_workspace_root` and not `workspace_root`.** `Repo::workspace_root() -> &Path`
(`repo.rs:96-100`) is an infallible accessor with a production call site that cannot absorb a
`Result` (`zanshin-ffi/src/repo.rs:401` arms the watcher with it). Overloading is impossible in Rust
and renaming it would churn a shipped accessor plus four test call sites for cosmetics. The new verb
therefore takes a distinct name, and both doc blocks cross-reference so the overlap is explicit:
`resolve_workspace_root(None)` returns exactly what the accessor returns, and that is the ONLY
overlap -- with a name, even the current workspace's own, the call goes through the store and can
refuse.

**Why three new error codes.** The CLI raises three distinct `user_error`s and the registry's own test
for minting a code is whether the REMEDY differs (`jj.remote_exists`, `docs/rust-error-codes.md:64`).
They do: an unknown name means "pick a different workspace"; no recorded path means "this workspace
predates jj 0.38 or its store was wiped -- nothing to do"; an unresolved path means "the directory
moved or was deleted -- offer to forget it" (Story 9.13). Collapsing the last two would force a GUI
to string-match `context`, which the registry forbids ("user data goes in `context`, never in
`code`") precisely because it is not machine-readable.

**Why `std::fs::canonicalize` and not `dunce`.** The CLI uses `dunce::canonicalize`, which differs
from `std` only on Windows (it avoids UNC paths). Zanshin is macOS-only, so `std` is the faithful
equivalent and no dependency is added. The consequence to respect is the `/var` → `/private/var`
symlink: every path assertion in the tests canonicalizes BOTH sides, as `tests/repo.rs:211-214`
already does.

**Traps to respect.** `SimpleWorkspaceStore::load` is not a pure read -- on a repo with no
`workspace_store/` directory it CREATES one and writes an empty store (`workspace_store.rs:117-125`).
That is jj-lib's own behavior and the CLI triggers it too; it writes no operation, which is what the
tests assert. `read_store` treats a missing or corrupt `index` as an `Err`, never as "no entry", so
`Ok(None)` and `Err` are genuinely different states and map to different codes in `resolve_root` --
while `list` flattens both to `None`. Stored paths are relative to `.jj/repo` (not to the workspace
root), so the join base is `workspace.repo_path()`, and the joined path keeps `../..` segments that
only canonicalize resolves. `get_workspace_path` re-decodes the whole protobuf index per call, so
`list` is O(rows × index size) -- acceptable at realistic workspace counts and exactly what the CLI
does, but do not "optimize" it into `WorkspaceStore::add`-adjacent internals.

## Verification

**Commands:**
- `cargo make test` -- expected: exit 0, run unpiped (cargo test + clippy pedantic `-D warnings` +
  rustfmt + flutter/dart analyze + format + `cargo deny` + coverage ratchet + extern-fn guard). This
  is the single gate.
- `cargo make codegen` then `cargo make verify-codegen` -- expected: the second reports no drift. Run
  `verify-codegen` only on a clean tree; it refuses otherwise.
- `git -C ../jj show v0.44.0:cli/src/commands/workspace/list.rs` (and `root.rs`,
  `cli/src/commit_templater.rs`) -- expected: re-confirms the argument arity, the `--name` default,
  the three refusals and the list/root asymmetry before relying on the anchors above.
- `git status --porcelain` -- expected: clean after each commit; the four generated files appear only
  together with the `.fbs`/`extern "C"` change that earned them, and `coverage-baseline.txt` only if
  the ratchet raised it.

**Manual checks (if no CLI):**
- Diff the crate's `pub` items: the additions are exactly two `Repo` methods, one struct and one error
  enum, and no `jj_lib` type appears in a public signature.

## Auto Run Result

Status: done
Blocking condition: none

### Summary of implemented change

Story 9.7 adds the jj CLI's two workspace READ verbs — `workspace list` and `workspace root` — as
typed `zanshin-jj` operations in a new `workspace.rs` noun module, and surfaces both through the full
chain Stories 9.3–9.6 established: `schemas/envelope.fbs` request + payload tables, `extern "C"`
wrappers in `zanshin-ffi`, committed `flatc`/cbindgen/ffigen output, and the Dart
adapter → `WorkerCommand` → `ZanshinWorker` → `RepoHandle` path. This is the crate's FIRST use of
`jj_lib::workspace_store`: Story 9.2 shipped the VIEW half (`view.rs::list_working_copies`) and
stopped at the boundary its own doc draws — "the path lives in the `WorkspaceStore`, not the `View`" —
so `list_workspaces` COMPOSES on top of that shipped read rather than widening `WorkingCopy`, and the
two shapes stay distinct (`WorkingCopy` = the raw View row, `WorkspaceEntry` = the `jj workspace list`
row). The story is the CLI's own asymmetry reproduced rather than smoothed over: `list` DEGRADES
(every path-side failure collapses to `root: None`, so a broken path can never fail the listing)
while `root --name` REFUSES with three distinct errors, each minted as its own code because the
remedies differ. `resolve_root(None)` reads the loader alone and is the one path that cannot fail;
naming the current workspace can still refuse, because the named path never shortcuts to the loader.
`zanshin-mcp` untouched (Epic 7 owns the tool surface).

### Files changed

- `crates/zanshin-jj/src/workspace.rs` (new) — the two verbs, `WorkspaceEntry`, `WorkspaceError`, and
  the shared `resolve_recorded_root` path resolver whose three failure stages `list` discards and
  `root` reports.
- `crates/zanshin-jj/src/repo.rs` — the two `#[must_use]` `Repo` facades and their doc blocks; the
  infallible `workspace_root()` accessor is deliberately untouched.
- `crates/zanshin-jj/src/lib.rs` — module declaration and re-exports.
- `crates/zanshin-jj/tests/workspace.rs` (new) — 15 integration scenarios against a raw jj-lib
  oracle, including a real secondary workspace and three distinct store-damage modes.
- `crates/zanshin-jj/tests/api_stability.rs` — the Story 9.7 alias block, `sample_workspace_entry`
  and `workspace_surface_resolves`.
- `schemas/envelope.fbs` — `WorkspaceRootRequest`; `WorkspaceEntry`, `WorkspaceList`,
  `WorkspaceRoot`; `Payload` slots 24–25; the Story 9-7 ledger line.
- `crates/zanshin-ffi/src/envelope.rs` — three new code constants (single-emission-point rule).
- `crates/zanshin-ffi/src/workspace.rs` (new) — request reader, payload builders and the two
  `extern "C"` wrappers; `zanshin_workspace_list` is handle-only, matching the CLI verb's zero
  arguments.
- `crates/zanshin-ffi/src/{lib,repo}.rs` — module declaration; `RepoSession`'s read-wrapper doc.
- `crates/zanshin-ffi/tests/workspace_ffi.rs` (new) — 7 tests: envelope/verifier contract, the
  request reader, a per-wrapper guard table (with a second fn-pointer alias for the handle-only
  verb), the `jj.jj_lib_error` witness, and the cross-cutting no-operation-written test.
- `packages/zanshin_core/lib/src/ffi/workspace.dart` (new) — adapters, model, decoders.
- `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` — the two commands, switch
  arms, `ZanshinWorker` methods and `RepoHandle` methods.
- `packages/zanshin_core/test/{ffi,worker}/workspace_test.dart` (new) — decode-contract tests over
  synthetic buffers plus real-cdylib worker tests.
- Committed codegen: `crates/zanshin-ffi/include/zanshin_ffi.h`,
  `crates/zanshin-ffi/src/envelope_generated.rs`,
  `packages/zanshin_core/lib/src/ffi/{bindings.dart,envelope_zanshin.ffi_generated.dart}`.
- `docs/rust-error-codes.md` — three new rows plus "also emitted" clauses on four reused ones.
- `coverage-baseline.txt` — two new entries at 100.00; nothing lowered, no `exclude_prefix` added.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — the story flipped to `done` with the
  summary comment refreshed to this reviewed final state.

### Review findings breakdown

Four review layers ran (blind hunter, edge-case hunter, verification-gap, intent alignment).

- Patches applied: 9 — 0 high, 1 medium, 8 low. Listed individually in the Review Triage Log.
- Items deferred: 4 — 1 medium, 3 low. In the `deferred` frontmatter, with evidence.
- Items rejected: 13. The substantive ones and why: guarding against an ABSOLUTE recorded store path
  or against a recorded path that is not a directory would DIVERGE from jj-lib and the CLI (an
  absolute entry is what `add` deliberately stores when there is no common prefix, and `join`
  handling it is the intended behavior); `to_string_lossy` at the FFI boundary and `?? ''` for a
  required wire string are both the established house patterns (`repo.rs:271`, `_mapRemote`), and
  changing them in one new module would create the inconsistency the finding complains about;
  `PathUnresolved`'s `"{name}: {reason}"` context does not force string-matching, because the caller
  supplied the name and `context` is diagnostic text by definition (AR-P-4); a `tracing` line for the
  swallowed path errors would duplicate a diagnostic the design already provides — `list` degrades
  and points at `resolve_root`, which reports the exact cause on demand; loading the store BEFORE
  validating the name mirrors `root.rs:48-50` exactly and is what the spec's own stage enumeration
  prescribes, and the two orders are observationally identical; the duplicated `session_from_handle`
  and Dart request helpers are the crate's existing per-module pattern, already on 9.4's and 9.6's
  deferred lists and rejected by 9.6's review for the same reason; and "the spec artifact is not
  closed out" is precisely what this pass does.

### Follow-up review recommendation

`followup_review_recommended: true`. Patched findings by severity: high 0, medium 1, low 8. No
high-severity patch, so the score decides: `3 × 1 + 1 × 8 = 11`, which is ≥ 5.

### Verification performed

- `cargo make test` — exit 0, run unpiped (redirected to a log with the exit code captured
  separately, never piped to `tail`), twice: once on the feature commit and once on the final review
  commit. Final run: all Rust suites green (15 `zanshin-jj` + 7 `zanshin-ffi` workspace tests), 273
  Dart tests green, clippy pedantic `-D warnings` clean, rustfmt clean, `dart analyze
  --fatal-infos --fatal-warnings` and `dart format` clean, `cargo deny` clean, coverage held at
  99.15 % (8152/8222 lines over 44 files) with both new source files at 100.00, no baseline entry
  lowered and no `exclude_prefix` added, and `extern-coverage: OK — every zanshin-ffi extern "C" fn
  is covered`.
- `cargo make verify-codegen` — no drift, confirmed on a clean tree after the feature commit; the
  review commit touched no `.fbs`, `extern "C"` body or doc text, so no regeneration was due.
- CLI oracle re-read at tag `v0.44.0` (`cli/src/commands/workspace/{list,root}.rs`,
  `cli/src/commit_templater.rs::WorkspaceRef::root`) and jj-lib's `workspace_store.rs` signatures
  confirmed in the vendored `jj-lib-0.44.0`, so the Block-If pin-drift condition is clear.
- Matrix audit: every I/O-matrix row has at least one covering test that ran and passed in the final
  gate output.
- `git status --porcelain` — clean after each commit.

### Residual risks

- The symlinked-init defect (first `deferred` item) is the substantive one: a repo initialised
  through a path containing a symlink records a store entry its own reads cannot resolve, so
  `workspace list` reports that workspace's root as absent and `workspace root --name` refuses. The
  fault is in the init path, not in these read verbs, but it is reached through them, and all three
  test suites work around it with a documented canonicalize rather than pinning it.
- `list_workspaces` is deliberately more forgiving than the CLI on a store-LOAD or store-READ
  failure: the CLI's template property propagates it, here it degrades like every other path failure.
  The consequence is that a corrupt store is indistinguishable from a legacy workspace in the LIST
  payload; `resolve_workspace_root` is the diagnostic path, and both are documented as such.
- `SimpleWorkspaceStore::load` writes to the repo directory (creating `workspace_store/` on a legacy
  repo) from what the API calls a READ. That is jj-lib's own behavior and the CLI triggers it too; no
  operation is written, which the tests assert — but a strictly read-only filesystem would surface it
  as `jj.jj_lib_error`.
- Path handling is `to_string_lossy` at the FFI boundary, so a non-UTF-8 path would cross mangled.
  Unreachable on macOS (APFS/HFS+ enforce UTF-8 filenames) and consistent with `RepoDetect`'s
  precedent, but it is a lossy conversion on the wire.
