---
title: 'Epic 9 follow-up D: canonicalise the workspace path at every creation seam so a repo resolves its own root'
type: 'bugfix'
created: '2026-09-05'
status: 'in-review'
baseline_revision: '1dc6b6a14b941ac2bbb4f67a49ae95fb3b4e6824'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** A repo reached through a path containing a symlink (on macOS every `TempDir` — `/var/folders/…`
is a symlink to `/private/var/folders/…`) records a workspace-store entry that its own reads cannot
resolve, so the workspace's own root reports as ABSENT through `list_workspaces` / `resolve_root`.
`SimpleWorkspaceStore::add` stores `relative_path(raw repo_path, workspace_root)`
(`jj-lib-0.44.0/src/workspace_store.rs:176-181`) using the RAW `repo_path` the store was loaded with,
while `Workspace::new` canonicalises the workspace root (`workspace.rs:170`) and the returned
`Workspace::repo_path()` is canonical after an init (`workspace.rs:337`); the recorded path is then one
`..` short of the join base every read uses. The real jj CLI never hits it because its workspace loader
canonicalises before either side runs. All three Story 9.7 test suites work around it with a documented
`canonicalize`, so **no test pins the defect**. This is the last open must-have of the Stories 9.3–9.8
ledger section that this run is chartered to close.

**Approach:** Canonicalise the caller-supplied workspace path once, at the entry of every seam in
`zanshin-jj` that hands a path to jj-lib's `Workspace` constructors — `Repo::open`, `Repo::init`,
`Repo::clone` and both `convert.rs` entry points, which all funnel into the same
`Workspace::init_with_factories` → `workspace_store.add` write — so the store's `repo_path` and the
`Workspace::repo_path()` that reads join onto are the same spelling. Then DELETE the three test
workarounds so the existing 9.7 suites become the witness: a run through the raw `/var/folders` temp
path must resolve its own root.

## Boundaries & Constraints

**Always:**
- **All five seams move together or the fix is a regression.** Today a raw-path `init`/`convert`/`clone`
  is *consistent with* a raw-path `Repo::open` (the recorded `..` count matches the raw join base, and
  `..` at `/` clamps). Canonicalising only `open` would BREAK repos created by `convert_colocated` /
  `convert_import` / `Repo::clone`, which today resolve. Change `open`, `init`, `clone`,
  `convert_colocated` and `convert_import` in the same commit.
- `std::fs::canonicalize`, never `dunce::canonicalize` — the house rule already recorded at
  `crates/zanshin-jj/src/workspace.rs:16-19` (the two differ only on Windows; Zanshin is macOS-only,
  `dunce` is not a direct dependency and must not become one).
- **Error payloads keep the CALLER's spelling.** `RepoError::{PathNotFound, NotARepo, NotAGitRepo,
  AlreadyJjRepo}` carry a path into the FFI `context` string; every one of them keeps
  `path.to_owned()` from the untouched argument. Only the path handed to jj-lib changes.
- **Observable outcomes stay put.** A missing `open` path is still `RepoError::PathNotFound`; a missing
  `init`/`clone` target is still `InitFailed` / `CloneFailed`; a missing `convert` path is still
  `NotAGitRepo`. Only the `reason`/`context` MESSAGE text may differ where the failure is now detected
  one step earlier — no error code, variant, or registry row changes.
- Paths returned by existing reads are unchanged: `Repo::workspace_root()` (and therefore
  `zanshin_repo_root`, `resolve_root(None)`) has ALWAYS been canonical, because `Workspace::new`
  canonicalises. `crates/zanshin-jj/tests/repo.rs:206-217` already pins that.
- **Error mapping stays on ONE `.map_err(…)?` expression**, never a multi-line `let … else { return … }`.
  A `map_err` closure's line is attributed to the enclosing covered statement (`convert.rs` sits at
  100.00 with untested `map_err` arms at `:226`/`:278`); a `return` inside an unexecuted `else` block is
  its own uncovered line and would move the ratchet.
- The coverage ratchet must not drop. `crates/zanshin-jj/src/{convert,detect}.rs` and
  `crates/zanshin-ffi/src/repo.rs` sit at 100.00 with `epsilon_pct = 0.10`; `zanshin-jj/src/repo.rs` at
  96.13.

**Block If:**
- Making the three 9.7 suites green after removing the workarounds needs a NEW workaround at a fourth
  site (i.e. the root-cause fix does not actually hold): HALT with `blocked`, blocking condition
  `canonicalisation does not fix the store round-trip`.
- The ratchet can only be made green by lowering a baseline entry or adding an `exclude_prefix`: HALT
  with `blocked`, blocking condition `coverage ratchet regression`.

**Never:**
- No change to `detect.rs` / `find_repo_root`: they are pure stat-only discovery helpers that never
  create a workspace, so they cannot record a store entry. `RepoRoot.root` deliberately echoes the
  caller's spelling and `crates/zanshin-jj/tests/find_repo_root.rs:43,58` plus the inline `detect.rs`
  tests compare it raw.
- No new error variant, no new `error.code`, no `.fbs` edit, no codegen run — no `extern "C"` signature
  moves, so `zanshin_ffi.h` / `bindings.dart` must stay byte-identical.
- No production `WorkspaceStore::{add,forget,rename}` call — `workspace add` is Story 9.23.
- No fixture regeneration. The `tiny-3-commits` archive records the GENERATOR's temp dir and must keep
  doing so: it is the free witness for the `list` degradation and the `root --name` stale-path refusal.
- No relocation of a removed workaround into a per-suite helper. `crates/test-helpers`'s
  `add_workspace` is fixed at its cause (it re-derived a repo path from a raw argument instead of using
  the loaded workspace's own root) — that is the stand-in for Story 9.23's production seam, not a
  canonicalize workaround.
- No unrelated cleanup in the touched functions.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| init through a symlinked path | `Repo::init(<raw /var/folders temp dir>, None)`, then `list_workspaces()` on the SAME handle | One row, `name == "default"`, `root == Some(<canonical dir>)` | No error expected |
| named root through a symlinked path | same handle, `resolve_workspace_root(Some("default"))` | The canonical workspace root — equal to `resolve_workspace_root(None)` | No error expected |
| open through a symlinked path | `Repo::init(raw)` then `Repo::open(raw)` then `list_workspaces()` | Same row with `root == Some(..)` — init and open agree on the spelling | No error expected |
| sibling workspace, raw fixture path | `test_helpers::add_workspace(<raw fixture path>, "second")`, then `Repo::open(<raw fixture path>)` | `second`'s row and `resolve_workspace_root(Some("second"))` both report the added directory; `default` still degrades (stale fixture entry) | No error expected |
| open, missing path | `Repo::open("/nonexistent/…")` | Refusal, unchanged | `RepoError::PathNotFound`, `path` = the caller's raw argument |
| open, existing non-jj dir | `Repo::open(<empty TempDir>)` | Refusal, unchanged | `RepoError::NotARepo`, `path` = the caller's raw argument |
| init, missing path | `Repo::init("/nonexistent/…", None)` | Refusal, unchanged variant (message now names the unresolvable path) | `RepoError::InitFailed` → `jj.jj_lib_error` |
| clone, missing target dir | `Repo::clone(url, "/nonexistent/…")` | Refusal, unchanged variant (detected before init instead of inside it) | `RepoError::CloneFailed` → `jj.jj_lib_error` |
| convert, missing path | `convert_colocated("/nonexistent/…")` | Refusal, unchanged | `RepoError::NotAGitRepo` (the `detect_repo` `PathNotFound` arm's own answer) |
| convert into a fresh dir | `convert_import(<git src>, <not-yet-existing dest>)` | Unchanged success — the dest is created first, then canonicalised | No error expected |

</intent-contract>

## Code Map

Zanshin anchors read against the working tree at baseline `1dc6b6a`; jj CLI anchors at tag `v0.44.0`
(`git -C ../jj show v0.44.0:<path>`); jj-lib anchors in the vendored `jj-lib-0.44.0`.

**The defect, read at the source (read-only)**
- `jj-lib-0.44.0/src/workspace.rs:307-346` `init_with_factories` — the shared seam behind
  `init_simple`, `init_internal_git` and `init_external_git`. `:327` loads the store with the **RAW**
  `repo_dir`; `:337` canonicalises `repo_dir`; `:338` `Self::new(..)` canonicalises the workspace root
  (`:170` `dunce::canonicalize`); `:339` `workspace_store.add(name, workspace.workspace_root())`. So the
  store's join base is raw while `Workspace::repo_path()` is canonical.
- `jj-lib-0.44.0/src/workspace_store.rs:176-181` (`add`) — stores `relative_path(repo_path, path)`,
  slash-normalised, relative to `.jj/repo`.
- `jj-lib-0.44.0/src/workspace.rs:567-593` `DefaultWorkspaceLoader::new` — for a PRIMARY workspace
  (`.jj/repo` is a dir) `repo_path` is `<given path>/.jj/repo`, **not** canonicalised; only the
  secondary-workspace FILE indirection is canonicalised (`:582`). This is why `Repo::open(raw)` happens
  to agree with a raw-recorded entry today, and why the two must be aligned deliberately.
- `jj-lib-0.44.0/src/workspace.rs:369-408` `init_workspace_with_existing_repo` — Story 9.23's future
  seam; it takes the repo path from the CALLER, canonicalises it at `:378`, and `add`s at `:406`. Once
  `Repo` holds a canonical workspace, 9.23 passing `self.workspace.repo_path()` is consistent by
  construction.

**Change — `crates/zanshin-jj/src/repo.rs`**
- `:1354-1370` `Repo::open` — replace the `!path.exists()` guard with the canonicalise; feed the
  canonical path to `Workspace::load` `:1362`. `PathNotFound`/`NotARepo` keep `path.to_owned()`.
- `:1380-1397` `Repo::init` — canonicalise after `make_settings()` `:1381`, feed
  `init_internal_git` `:1390` / `init_simple` `:1393`.
- `:1416-1433` `Repo::clone` — canonicalise `target_path` before `clone_into`; `created_dir` `:1418`
  and its `if` arm `:1425-1427` become provably dead (canonicalise succeeds only if the dir exists) and
  go with it; the rollback keeps the `.jj/` branch `:1428`.
- `:1436-1474`, `:1576` `clone_into` — takes the already-canonical `target_path`; both
  `Workspace::init_internal_git` `:1440` and the two `Workspace::load` calls (`:1468`, `:1576`) then
  agree. No signature change (it is a private associated fn).
- `:21-68` `RepoError` — read-only reference: `PathNotFound{path}` `:25`, `NotARepo{path}` `:31`,
  `InitFailed{reason}` `:37`, `CloneFailed{reason}` `:43`. No variant added.

**Change — `crates/zanshin-jj/src/convert.rs`**
- `:60-77` `convert_colocated` — canonicalise after the `detect_repo` match (which already answered
  `NotAGitRepo` for a missing path) and before `convert_into` `:69`; `Repo::open` `:70` and the `.jj/`
  rollback `:73` use the canonical path. The `map_err` mirrors the `PathNotFound` arm's answer.
- `:104-149` `convert_import` + `:240-241` `import_into` — the dest may not exist yet, so
  `create_dir_all` must run first. `import_into`'s existing `create_dir_all` `:241` is where the
  canonicalise belongs; `is_colocated`'s argument `:271` already comes from
  `workspace.workspace_root()` and stays untouched.
- `:183-186` `is_colocated`'s doc contract ("pass a canonicalized `workspace_root`") — still satisfied,
  do not weaken it.

**Change — `crates/test-helpers/src/lib.rs`** (coverage-excluded, `exclude_prefix`)
- `:119-130` `load` — read-only: it hands the RAW path to `Workspace::load`, so the returned
  `workspace.repo_path()` is raw while `workspace.workspace_root()` is canonical.
- `:520-541` `add_workspace` — `:525` re-derives `repo_path` from the raw ARGUMENT
  (`workspace_root.join(".jj").join("repo")`). That is the helper's own copy of the defect: derive it
  from the loaded workspace's canonical root instead. Callers: `zanshin-jj/tests/workspace.rs:143`,
  `zanshin-ffi/tests/workspace_ffi.rs:127`, `zanshin-jj/tests/graph.rs:1268`,
  `zanshin-jj/tests/view.rs:424` (the last two only read the returned commit hex).

**Delete — the three workarounds**
- `crates/zanshin-jj/tests/workspace.rs:133-144` `add_resolvable_workspace` (+ its four call sites
  `:193`, `:194`, `:338`, `:385` → plain `add_workspace`).
- `crates/zanshin-ffi/tests/workspace_ffi.rs:120-133` `open_two_workspace_scenario` — drop the
  `fs::canonicalize` `:126` and the WHY block `:120-123`; keep the `std::mem::forget` leaks.
- `packages/zanshin_core/test/worker/workspace_test.dart:43-57` — `repoPath` becomes `tempDir.path`;
  the WHY paragraph goes. Assertions `:78-82`, `:92-95` keep resolving BOTH sides (they compare a
  canonical wire path against a raw temp dir), so compare against `tempDir.resolveSymbolicLinksSync()`.

**Amend — the comment the fix falsifies**
- `crates/zanshin-jj/tests/workspace.rs:314-319` — says the canonical guarantee comes from jj-lib's
  `Workspace::new`, "NOT this function". Still true of `resolve_root`, but `Repo::open` now
  canonicalises its input as well; the WHY must name both.

**Tests / gates**
- `crates/zanshin-jj/tests/repo.rs:63-82` (`PathNotFound` / `NotARepo` — both arms of the replaced
  guard, `matches!` with `..` so no path payload is compared), `:104-120` init round-trips,
  `:128-154` clone refusals, `:158-190` clone happy path (`file://`), `:206-217`
  `repo_workspace_root_matches_open_path`.
- `crates/zanshin-jj/tests/workspace.rs` — `pin_env` `:31`-ish, `assert_same_dir` `:146-153`,
  `store_dir`/`corrupt_workspace_store`/`dangle_workspace_store` `:100-121`, `head_op_id` `:128-131`,
  `entry_pairs`/`wc_pairs`, and the `Repo::init(tmp.path(), None)` idiom at `:284-297`. The new
  raw-path witness belongs here.
- `crates/zanshin-ffi/tests/workspace_ffi.rs:145-260` — the two payload tests that consume
  `open_two_workspace_scenario`.
- `packages/zanshin_core/test/worker/workspace_test.dart` — the whole file init-repos through
  `repoPath`; `:68-85` is the row that becomes the end-to-end witness.
- `crates/zanshin-jj/tests/convert.rs:750-790` `convert_import_into_same_dir_is_colocated` — passes the
  path RAW on purpose to keep `is_colocated`'s canonical-vs-canonical comparison honest; its comment
  `:756-762` must be reconciled with the fact that `import_into` now canonicalises the dest.
- `coverage-baseline.txt` — knobs `:8-11` (`epsilon_pct = 0.10`, `new_file_floor_pct = 80.00`,
  `exclude_prefix = crates/test-helpers/`); `crates/zanshin-ffi/src/repo.rs = 100.00` `:31`,
  `crates/zanshin-jj/src/convert.rs = 100.00` `:45`, `crates/zanshin-jj/src/detect.rs = 100.00` `:46`,
  `crates/zanshin-jj/src/repo.rs = 96.13` `:54`, `crates/zanshin-jj/src/workspace.rs = 100.00` `:58`.
- `docs/rust-error-codes.md:42-43` — read-only: `jj.repo_not_found` / `jj.path_not_found` describe the
  CONDITION ("no jj repo found", "a path argument does not exist on disk"), which is unchanged. No
  registry edit.

**Bookkeeping**
- `_bmad-output/implementation-artifacts/deferred-work.md:202` — the ledger bullet to strike through.
- `_bmad-output/implementation-artifacts/spec-9-7-workspace-reads-list-root.md:12-30` — the first
  `deferred:` item, which gains a `resolved: >-` block scalar.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/repo.rs` -- in `Repo::open`, replace the `!path.exists()` guard with
  `std::fs::canonicalize(path).map_err(|_| RepoError::PathNotFound { path: path.to_owned() })?` and
  pass the canonical path to `Workspace::load`; keep `NotARepo`'s payload raw. -- The two guards are
  equivalent (`Path::exists` is a `metadata()` probe that follows symlinks, so it fails exactly where
  `canonicalize` does), so both existing refusal tests keep covering both arms without a new branch.
- `crates/zanshin-jj/src/repo.rs` -- in `Repo::init`, canonicalise `path` before either
  `Workspace::init_*` call, mapping failure onto `RepoError::InitFailed`. -- The store entry is written
  INSIDE the jj-lib init, so the path must be canonical before the call, not after it.
- `crates/zanshin-jj/src/repo.rs` -- in `Repo::clone`, canonicalise `target_path` before `clone_into`
  (failure → `RepoError::CloneFailed`), thread the canonical path through `clone_into`'s
  `init_internal_git` and both `Workspace::load` calls, and drop the now-dead `created_dir` binding and
  its rollback arm, leaving the `.jj/` rollback. -- `canonicalize` succeeds only for an existing
  directory, so `created_dir` can no longer be true; leaving it would ship a provably dead, uncovered
  branch. Update `Repo::clone`'s rollback sentence in its doc block accordingly.
- `crates/zanshin-jj/src/convert.rs` -- in `convert_colocated`, canonicalise after the `detect_repo`
  match (failure → `RepoError::NotAGitRepo { path: path.to_owned() }`) and use the canonical path for
  `convert_into`, `Repo::open` and the `.jj/` rollback. -- `convert_into` reaches the same
  `init_with_factories` seam, and `convert_colocated` hands its result straight to `Repo::open`, which
  now canonicalises: leaving this one raw would REGRESS a case that works today.
- `crates/zanshin-jj/src/convert.rs` -- in `import_into`, canonicalise `workspace_path` immediately
  after the existing `create_dir_all` (same `ConvertFailed` channel), then use it for
  `init_external_git`. -- The destination may legitimately not exist yet, so the canonicalise has to
  follow the directory creation; `is_colocated`'s argument already comes from
  `workspace.workspace_root()` and must not change.
- `crates/test-helpers/src/lib.rs` -- in `add_workspace`, take the repo path from the loaded
  workspace's own (jj-lib-canonicalised) root instead of re-deriving it from the raw argument, with a
  WHY comment naming the store's relative-record rule and the Story 9.23 seam it stands in for. -- The
  helper is the only writer of a SECOND workspace entry; without this the three suites cannot drop
  their canonicalize and still see a resolvable sibling root.
- `crates/zanshin-jj/tests/workspace.rs` -- delete `add_resolvable_workspace`, point its four call
  sites at `test_helpers::add_workspace`, and amend the canonical-guarantee WHY at `:314-319` to name
  `Repo::open`'s canonicalise alongside `Workspace::new`'s. -- The workaround is what kept the defect
  unpinned; the tests only become the witness once the raw path actually flows through.
- `crates/zanshin-jj/tests/workspace.rs` -- add the raw-path witness: `Repo::init` at a raw `TempDir`
  path, then assert on the SAME handle that `list_workspaces()`'s single row has `root == Some(..)`
  pointing at that directory and that `resolve_workspace_root(Some("default"))` returns the same path
  as `resolve_workspace_root(None)`; re-open through the raw path and assert the row again. -- This is
  the I/O matrix's first three rows and the only test that fails on `main`; it must exercise the
  handle `init` RETURNS (whose `repo_path` is canonical) as well as a re-`open`.
- `crates/zanshin-ffi/tests/workspace_ffi.rs` -- drop the `fs::canonicalize` and its WHY block from
  `open_two_workspace_scenario`, keeping the two `std::mem::forget` leaks and the returned tuple. --
  Same reason; the payload assertions already canonicalize both sides of every comparison.
- `packages/zanshin_core/test/worker/workspace_test.dart` -- set `repoPath` to `tempDir.path`, delete
  the resolve-symlinks WHY paragraph, and compare the returned roots against
  `tempDir.resolveSymbolicLinksSync()` so the ASSERTION still resolves both sides while the INPUT stays
  raw. -- This file is the end-to-end witness through the real cdylib: `initRepo` on a raw
  `/var/folders` path must produce a workspace that reports its own root.
- `crates/zanshin-jj/tests/convert.rs` -- reconcile the `convert_import_into_same_dir_is_colocated`
  comment with the fact that the dest is canonicalised inside `import_into` now, keeping the raw
  argument and the descendant assertion. -- The test's guard (that `is_colocated` compares two
  canonical paths and never a raw caller path) still holds; the comment must not claim a property the
  code no longer has.
- `_bmad-output/implementation-artifacts/deferred-work.md` + `spec-9-7-workspace-reads-list-root.md` --
  strike the ledger bullet in the house convention (`~~bold title~~` + ` — RESOLVED 2026-09-05
  (spec-epic-9-followup-d-symlinked-workspace-path, commit <short hash>): …`) and add a `resolved: >-`
  block scalar to the matching `deferred:` item, recording that Story 9.23 no longer inherits the trap.
  -- The ledger must end this run smaller than it started.

**Acceptance Criteria:**
- Given a repo created by `Repo::init` through a raw macOS temp path, when `list_workspaces` and
  `resolve_root(Some("default"))` are called on that same handle, then the workspace's own root is
  reported (not absent, not refused) — and the same holds after re-opening through the raw path.
- Given the three Story 9.7 suites with their `canonicalize` / `resolveSymbolicLinksSync` workarounds
  removed, when the full gate runs, then every one of their pre-existing assertions passes unchanged.
- Given `git stash`-ing only the `crates/zanshin-jj/src` and `crates/test-helpers/src` changes, when the
  new raw-path witness runs, then it FAILS — the test pins the defect rather than the workaround.
- Given the fixture-based rows of the 9.7 matrix (`default`'s stale entry degrading in `list`, the
  `jj.workspace_path_unresolved` refusal for `root --name default`), when the gate runs, then they still
  hold: the committed fixture's recorded path is unrelated to the caller's spelling.
- Given `cargo make codegen` is NOT run, when `git status --porcelain` is inspected, then no generated
  file (`zanshin_ffi.h`, `bindings.dart`, `*_generated.rs`, `*.ffi_generated.dart`, `schemas/`) appears.
- Given `cargo make test`, when it completes, then it exits 0 with no per-file coverage regression and no
  edit to `coverage-baseline.txt` other than ratchet-raised values.

## Spec Change Log

**2026-09-05 — the intent-contract's first Always bullet is factually wrong; the action it prescribes
is nevertheless correct and was carried out.**

The bullet ("All five seams move together or the fix is a regression") justifies bundling the five
canonicalise sites with the claim that today a raw-path `init`/`convert`/`clone` is *consistent with*
a raw-path `Repo::open` — "the recorded `..` count matches the raw join base, and `..` at `/` clamps"
— and therefore that repos created by `convert_colocated` / `convert_import` / `Repo::clone` "today
resolve". They do not, and never did. The same error is repeated in this spec's **Design Notes**
("Why the arithmetic makes 'only fix `open`' a regression") and in the fourth Execution bullet
("leaving this one raw would REGRESS a case that works today"). The `<intent-contract>` block is
read-only, so it is corrected here rather than edited.

*The true mechanism, verified two ways:*

1. `jj_lib::file_util::relative_path` (`jj-lib-0.44.0/src/file_util.rs:136-152`) computes the `..`
   count purely LEXICALLY — `strip_common_path_prefix` walks `Components`, and `depth` is the
   component count of the from-suffix. The common prefix of a RAW repo path and a CANONICAL workspace
   root is `/` alone, so the record is N × `..` followed by `private/var/…`, where N is the raw repo
   path's own component count. There is no "matching `..` count".
2. `resolve_recorded_root` (`crates/zanshin-jj/src/workspace.rs:130-131`) joins that record onto the
   base and then calls `std::fs::canonicalize` — `realpath(3)` — which resolves the symlink BEFORE
   applying the `..` segments. `realpath("/var/..")` is `/private`, not `/`; the assumed clamp at `/`
   never happens. The N `..` are therefore applied to an N+1-component resolved prefix and land on
   `/private`, yielding `/private/private/var/…` → ENOENT.

*Consequence:* a raw-recorded entry resolved from NEITHER a raw base nor a canonical one. Repos
created through a symlinked path by `Repo::clone`, `convert_colocated` or `convert_import` were
already broken before this change; the change FIXES them rather than preserving them. Moving all five
seams in one commit was still the right call — for COMPLETENESS of the fix, not to avoid a
regression. The corollary is worth recording: because those entries never resolved, canonicalising
`Repo::open` cannot strand any repo written by an older build, so there is no back-compat hazard.

*Action taken:* the five seams were canonicalised in one commit as prescribed (commit `2d6de57`). The
false rationale was also copied into two durable artifacts, which are corrected in place —
`deferred-work.md`'s struck-through ledger bullet and `spec-9-7-workspace-reads-list-root.md`'s
`resolved:` block now state the lexical-`relative_path` + `realpath`-ordering mechanism and the
completeness (not anti-regression) reason for the bundle.

## Review Triage Log

## Design Notes

**Why the arithmetic makes "only fix `open`" a regression.** On macOS `relative_path` between a raw and
a canonical spelling walks up to `/` and back down. With a raw repo dir `/var/f/A/.jj/repo` (5
components) and a canonical root `/private/var/f/A` (4), `add` records `../../../../../private/var/f/A`.
Joined onto the RAW base (5 components) the five `..` land on `/` and the path resolves; joined onto the
CANONICAL base (6 components) they land on `/private` and the result is `/private/private/var/f/A`,
which does not exist. `init` returns a workspace whose `repo_path` jj-lib already canonicalised
(`workspace.rs:337`), which is why the defect is visible on the init handle but not after a raw
`Repo::open` — and why aligning one side without the other flips which callers are broken.

**Why `Path::exists()` can be replaced outright.** `exists()` is `fs::metadata(path).is_ok()` — it
follows symlinks and returns `false` for ENOENT, ENOTDIR and a parent EACCES, which is exactly the set
where `canonicalize` returns `Err`. Mapping that `Err` to `PathNotFound` preserves the variant, the
`jj.path_not_found` code and the raw path in `context`, and keeps both existing refusal tests as the
coverage for the arm — no new branch, no new test needed for `open`.

**Shape of each seam (keep the mapping on one expression):**

```rust
// Repo::open — replaces the `!path.exists()` guard
let root = std::fs::canonicalize(path).map_err(|_| RepoError::PathNotFound { path: path.to_owned() })?;
if !root.join(".jj").is_dir() {
    return Err(RepoError::NotARepo { path: path.to_owned() });
}
```

**Why `created_dir` goes.** `Repo::clone` computed `created_dir = !target_path.exists()` and, on
failure, removed the whole target dir if it had been absent. After the canonicalise that branch is
unreachable — a missing target now fails before `clone_into` runs, with the same `CloneFailed` variant —
so the binding is dead code this change created. Clone never created the directory anyway
(`create_jj_dir` needs the parent to exist), so nothing is lost; `jj git clone`'s create-the-dest
behaviour remains Story 9.20's.

**Why `test-helpers` is fixed at its cause, not worked around.** `add_workspace` loaded a `Workspace`
and then ignored it, re-deriving `<raw arg>/.jj/repo` for `init_workspace_with_existing_repo`. The
loaded workspace's `workspace_root()` is already canonical (jj-lib guarantees it), so taking the repo
path from there removes the raw spelling at its source. This mirrors what Story 9.23's production
`workspace add` will do — it will hold a `Repo` whose workspace is canonical end to end — which is the
ledger bullet's "re-check 9.23 before it inherits the same trap".

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test workspace` -- expected: all pass, including the new raw-path witness
  and the four call sites now using `add_workspace` directly.
- `cargo test -p zanshin-jj --test repo --test convert --test clone_config --test find_repo_root --test view --test graph`
  -- expected: all pass unchanged; the refusal tests still report `PathNotFound` / `NotARepo` /
  `CloneFailed` / `NotAGitRepo`.
- `cargo test -p zanshin-ffi --test workspace_ffi --test repo_ffi` -- expected: all pass with the
  workaround gone.
- `cd packages/zanshin_core && dart test test/worker/workspace_test.dart` -- expected: all pass with the
  raw `tempDir.path` as the repo path. (Requires a current cdylib — `cargo make test` builds it.)
- Mutation probe: `git stash push -- crates/zanshin-jj/src crates/test-helpers/src`, then
  `cargo test -p zanshin-jj --test workspace` -- expected: the new raw-path witness FAILS; `git stash pop`.
- `git status --porcelain -- crates/zanshin-ffi/include packages/zanshin_core/lib/src/ffi schemas` --
  expected: empty (no codegen was run and none is needed).
- `cargo make test` -- expected: exit 0. Run unpiped and synchronously, allow ~15 minutes (cargo test +
  clippy pedantic `-D warnings` + rustfmt + `flutter test` + dart analyze/format + `cargo deny` + the
  coverage ratchet). The single gate.
- `git status --porcelain` -- expected: clean after the final commit.
