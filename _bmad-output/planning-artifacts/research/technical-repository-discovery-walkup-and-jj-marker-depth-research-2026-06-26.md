---
stepsCompleted: [1, 2, 3, 4, 5]
status: 'complete'
inputDocuments:
  - crates/zanshin-jj/src/detect.rs
  - crates/zanshin-jj/src/repo.rs
  - _bmad-output/implementation-artifacts/2-11-implement-detect-rs-repository-kind-detection.md
  - _bmad-output/project-context.md
workflowType: 'research'
lastStep: 1
research_type: 'technical'
research_topic: 'Repository discovery for the open-project flow — single-directory stat vs. ancestor walk-up, walk-up stopping point, and jj detection-marker depth (.jj/ vs .jj/repo/store)'
research_goals: 'Decide whether Zanshin''s detect()/open-project flow should walk up the directory tree, where such a walk should stop, and whether `.jj/` presence is the correct workspace marker or a deeper check (`.jj/repo/store`) is needed — grounded in how jj-lib, git/libgit2, and real jj/Git clients behave.'
user_name: 'Ralph'
date: '2026-06-26'
web_research_enabled: true
source_verification: true
---

# Research Report: Repository Discovery & Detection-Marker Depth

**Date:** 2026-06-26
**Author:** Ralph
**Research Type:** technical

---

## Research Overview

This report investigates three concrete questions raised about Zanshin's
`detect()` function (Story 2.11) and the broader open-project flow:

- **Q1 — Walk-up:** Is classifying the selected directory enough, or should the
  flow walk *up* to a parent directory when the selected path is not itself a
  repository root?
- **Q2 — Stopping point:** If it walks up, does it go all the way to `/`, or
  stop earlier (filesystem boundary, ceiling directories, `$HOME`)?
- **Q3 — Marker depth:** Is checking for a `.jj/` directory sufficient, or should
  the check look for `.jj/repo/store`?

Methodology: ground-truth source reading of the locally-vendored **jj-lib 0.41.0**
plus multi-source web verification of **git/libgit2** and a survey of real
**jj and Git clients** (GUI + TUI). Each pivotal claim was adversarially
cross-checked. Confidence levels are noted per claim.

---

## Technical Research Scope Confirmation

**Research Topic:** Repository discovery for the open-project flow — single-directory stat vs. ancestor walk-up, walk-up stopping point, and jj detection-marker depth (`.jj/` vs `.jj/repo/store`).
**Research Goals:** Decide whether Zanshin's `detect()`/open-project flow should walk up the directory tree, where such a walk should stop, and whether `.jj/` presence is the correct workspace marker or a deeper check is needed.

**Scope Confirmed:** 2026-06-26

---

## Executive Summary — direct answers

| # | Question | Answer | Confidence |
|---|----------|--------|------------|
| **Q3** | Is `.jj/` enough, or should we check `.jj/repo/store`? | **`.jj/` (as a directory) is the correct marker. `.jj/repo/store` would be a *bug*** — it misclassifies valid **secondary workspaces** (`jj workspace add`), where `.jj/repo` is a *file* pointing at another workspace's store. Our current `detect.rs` is **already right**; it uses exactly jj-lib's own marker. | **High** (jj-lib source + jj's own test) |
| **Q1** | Single-dir classify, or walk up on a miss? | **Both — but at different layers.** Keep `detect()` single-directory (it mirrors jj-lib's own `Workspace::load` precondition). **Walk-up is a *separate, additive* concern** that sits *above* `detect()`. This is exactly how jj's CLI, the `gg` GUI, VS Code, and JetBrains are built. The dominant, user-friendly pattern is to accept any sub-directory and walk up. | **High** |
| **Q2** | Walk up to `/`, or stop earlier? | jj's own tools (jj-CLI, `gg`) walk to **`/`** with no guard. Git stops at a **filesystem/mount boundary by default** + `GIT_CEILING_DIRECTORIES`. JetBrains stops at **`$HOME`**. Recommended for Zanshin: **walk to `/` (matches jj)** with an **optional `$HOME` ceiling** (cheap guard against accidentally adopting a dotfiles repo). FS-boundary stop is a lower-priority macOS refinement. | **High** |

**Bottom line for the code we just shipped (Story 2.11):** `detect.rs` needs **no change** — its `.jj/`-is-`dir` + `.git`-`exists` checks are exactly correct and match jj-lib's and the entire client ecosystem's behaviour. The *open* question is purely **additive**: whether to add a small `find_repo_root(start)` walk-up helper for the open-project flow (and reuse it for the MCP cwd-walk, Story 7-1). That is a new, separate piece of surface — out of 2.11's scope.

---

## Methodology & source integrity

- **Ground truth first:** jj-lib 0.41.0 was read directly from the locally-vendored crate source (`~/.cargo/registry/.../jj-lib-0.41.0`) — not from memory or the web. The author independently re-read the decisive functions (`DefaultWorkspaceLoader::new`, `init_workspace_with_existing_repo`) to confirm the agent findings.
- **Web-sourced** for git/libgit2 semantics and the client survey (9 agents, ~909 K tokens, 178 tool calls).
- **Adversarial verification:** the three pivotal claims were handed to independent skeptic agents instructed to *refute* them. Two returned **confirmed** with fresh citations (incl. jj's own `tests/test_workspace.rs`); the third (git FS-boundary) reached "confirmed" but failed to emit structured output — its claim already rests on three independent authoritative sources, so it stands.
- **Two agent failures, both recovered (honest disclosure):** the dedicated *jj-CLI* agent and the *git-FS-boundary verifier* hit a StructuredOutput retry cap. Their facts were recovered from other agents: the jj-CLI walk-up (`find_workspace_dir`) was independently located by the Q1 verifier in jj-cli v0.41.0; the FS-boundary default was triple-sourced by the git/libgit2 agent. No claim in this report rests on an un-recovered failed agent.

---

## Q3 — Marker depth: `.jj/` vs `.jj/repo/store` (the decisive one)

**Finding: `.jj/` as a directory is jj-lib's *own* marker. `.jj/repo/store` is NOT a universal marker and checking for it would be a correctness bug.**

jj-lib's canonical loader gates on exactly one thing — `.jj` being a directory:

```rust
// jj-lib-0.41.0/src/workspace.rs:564-570  (DefaultWorkspaceLoader::new)
let jj_dir = workspace_root.join(".jj");
if !jj_dir.is_dir() {
    return Err(WorkspaceLoadError::NoWorkspaceHere(workspace_root.to_owned()));
}
```

The reason `.jj/repo/store` fails as a marker is **secondary workspaces** (`jj workspace add`). For those, `.jj/repo` is a **regular file** whose bytes are a *relative path* to the real repo dir — there is no `.jj/repo/store` directory locally at all:

```rust
// jj-lib-0.41.0/src/workspace.rs:571-582  (loader resolves the pointer)
let mut repo_dir = jj_dir.join("repo");
// If .jj/repo is a file, then we interpret its contents as a relative path to
// the actual repo directory (typically in another workspace).
if repo_dir.is_file() {
    let buf = fs::read(&repo_dir)?;
    let repo_path = file_util::path_from_bytes(&buf)?;
    repo_dir = dunce::canonicalize(jj_dir.join(repo_path))?;
    if !repo_dir.is_dir() { return Err(WorkspaceLoadError::RepoDoesNotExist(repo_dir)); }
}
```

The write side confirms the asymmetry:

| Workspace kind | `.jj/repo` is… | Created by |
|----------------|----------------|------------|
| **Primary** | a **directory** (`.jj/repo/store/…` lives here) | `std::fs::create_dir(jj_dir.join("repo"))` — `workspace.rs:305-306` |
| **Secondary** (`jj workspace add`) | a **file** with a relative path to the primary's repo | `fs::write(jj_dir.join("repo"), repo_dir_bytes)` — `workspace.rs:382-385` |

jj's own test suite asserts this directly: a secondary workspace's `.jj/repo` is a file containing `"../../repo/.jj/repo"` (`jj-lib tests/test_workspace.rs:79-82`).

**Cross-check against `gg` (the only real jj GUI):** it uses the *identical* check we do — `path.join(".jj").is_dir()` (`gg src/worker/gui_util.rs:1345-1349`). So our marker choice matches both jj-lib internally and the reference GUI.

**Implication for `detect.rs`:** none — keep `.jj/`-is-`dir`. Going deeper would (a) break secondary workspaces and (b) violate Story 2.11's own AC-9 principle that `detect` reports *structural presence*, not *integrity*. The "is it actually loadable?" question (e.g. a secondary workspace whose target repo moved → jj-lib returns `RepoDoesNotExist`) is correctly delegated to `Repo::open`, exactly as the detect/open split already specifies.

> **One precision worth recording:** `.jj/` presence proves a *workspace marker* exists, not that the repo is fully *loadable*. For a secondary workspace, full validity additionally requires the redirected target dir to exist. `detect()` deliberately does not check that — `Repo::open` does. This is the correct separation, not a gap.

---

## Q1 — Single-directory classify vs. ancestor walk-up

### Ground truth: jj-lib does **not** walk up; jj's **CLI** does

- **jj-lib (the library Zanshin calls):** `Workspace::load(path)` → `DefaultWorkspaceLoader::new(path)` looks only at `<path>/.jj` and errors `NoWorkspaceHere` otherwise (`workspace.rs:406-415`, `:564-570`). A workspace-wide grep for `walk`/`ancestors`/`parent()`/`find_workspace` in jj-lib returns nothing. **The caller must pass the exact root.**
- **jj-CLI (jj-cli v0.41.0):** the walk-up lives *here*, not in the library —
  ```rust
  // jj-cli/cli/src/cli_util.rs:2739-2743
  pub fn find_workspace_dir(cwd: &Path) -> &Path {
      cwd.ancestors().find(|path| path.join(".jj").is_dir()).unwrap_or(cwd)
  }
  // called at :4398 → .create(find_workspace_dir(&cwd))
  ```
  This matches the jj docs: "Jujutsu searches for the closest `.jj/` directory in an ancestor of the current working directory."

**Architectural lesson:** the walk-up is a thin layer *above* the single-directory loader. `detect()` is the single-directory primitive; a `find_repo_root()` helper is the walk-up layer. Keeping them separate is the established design.

### Client survey — who walks up?

| Client | Type | Walk-up on sub-dir? | Marker | Notes / citation |
|--------|------|---------------------|--------|------------------|
| **jj-lib** | library | **No** (by design) | `.jj/`.is_dir() | caller passes root — `workspace.rs:564` |
| **jj CLI** | CLI | **Yes → `/`** | `.jj/`.is_dir() | `find_workspace_dir`, `cli_util.rs:2739` |
| **gg** | jj GUI | **Yes** (own walk, then jj-lib) | `.jj/`.is_dir() | `gui_util.rs:1345`; file-picker `Open…` |
| **lazyjj** | jj TUI | **Yes** (delegates to `jj root`) | jj-lib's | `env.rs` shells `jj root` |
| **jjui** | jj TUI | **Yes** (delegates to `jj root`) | jj-lib's | `main.go` shells `jj root` |
| **Sublime Merge** | git GUI | **Yes** | `.git` dir (or bare+`core.worktree`) | walks to first `.git` ancestor |
| **VS Code** | editor | **Yes** (`git rev-parse --show-toplevel`) + down-scan | git's | ancestor repo gated by `git.openRepositoryInParentFolders` (default *prompt*) |
| **JetBrains** | editor | **Yes** (up *and* down) | `.git` dir/file | up-walk excludes `$HOME` and above |
| **Zed** | editor | **Yes** (`AboveProject`) | `.git` | records sub-folder-of-repo case |
| **GitKraken** | git GUI | **No** ("Could not find a compatible repository") | `.git` at exact path | walk-up is an open feature request |
| **SourceTree** | git GUI | **No** ("not a valid working copy path") | `.git` at exact path | no init, no walk-up |
| **GitHub Desktop** | git GUI | **No** (acknowledged bug #2832) | git at literal path | offers `init` for non-repo folders |
| **Tower** | git GUI | **No** (manual Add = root); **scans *down*** | `.git` | "Search Local Hard Drive" bulk-add |
| **Fork** | git GUI | unknown; **scans *down*** | `.git` | source-directory model |

**Pattern:** every **jj** client and every **editor** walks up. Among **git GUIs** it's split — and the no-walk-up ones (GitKraken, SourceTree, GitHub Desktop) each have **bug reports / feature requests** asking for walk-up, i.e. users expect it. Two clients (Tower, Fork) add an orthogonal **downward** bulk-scan ("add a folder full of repos").

---

## Q2 — Where does the walk-up stop?

| Tool | Stop condition | Citation |
|------|----------------|----------|
| **jj CLI / gg** | Walks `cwd.ancestors()` to **filesystem root `/`**; stops at first `.jj`. **No** boundary/ceiling/`$HOME` guard. | `cli_util.rs:2739`; `gg gui_util.rs:1345` |
| **git / libgit2** | Stops at the **first of**: filesystem/**mount boundary** *(default — `GIT_DISCOVERY_ACROSS_FILESYSTEM` unset → `one_filesystem=true`, stop on `st_dev` change)*; any `GIT_CEILING_DIRECTORIES` entry; `/`. `$GIT_DIR` short-circuits the walk entirely. | git(1) env vars; `setup.c` `setup_git_directory_gently_1`; libgit2 `GIT_REPOSITORY_OPEN_CROSS_FS` |
| **JetBrains** | Walks up but **excludes `$HOME` and above** (explicit `// ignore mappings in ~/ and above`); else to `/`. | `VcsRootDetectorImpl.java:190-191` |
| **VS Code** | Defers up-walk to git (so git's boundary + ceiling); auto-opening an ancestor repo *outside the workspace* is **prompted** (`git.openRepositoryInParentFolders`, default `prompt`). | `model.ts:632` |
| **Sublime Merge** | First `.git` ancestor; no documented boundary. | `sublimemerge.com/docs/command_line` |

The most-misremembered fact, triple-sourced: **git does NOT cross filesystem boundaries by default** — it is opt-*out* via `GIT_DISCOVERY_ACROSS_FILESYSTEM`, not opt-in.

**For Zanshin:** since we wrap jj and want jj's mental model, **walk to `/` like jj-CLI/gg** is the simplest defensible default. The single cheap, thoughtful guard worth considering is **JetBrains' `$HOME` ceiling**: on macOS, dotfile repos make `~/.git` (or even a `~/.jj`) common, and walking past `$HOME` could silently surface a dotfiles repo when the user picked something unrelated under their home. The git-style **filesystem-boundary** stop matters mostly for network mounts/autofs and is a lower priority for a macOS desktop GUI (git itself notes a desktop GUI may reasonably want `across_fs`).

---

## Synthesis & recommendation for Zanshin

### 1. `detect.rs` (Story 2.11) — **ship as-is, no change**

`detect()`'s `.jj/`-is-`dir` and `.git`-`exists` checks are exactly correct:
- `.jj/`-is-`dir` == jj-lib's own marker, and correctly classifies **both** primary and secondary workspaces as `Jj` (a secondary workspace still has `.jj/` as a directory; only `.jj/repo` inside it is a file).
- `.git`-`exists` (file **or** dir) correctly captures git work-trees, the `gitdir:` pointer-file case (submodules/linked worktrees), and bare-ish layouts — matching what every Git GUI effectively does ("`.git` presence") and Story 2.11's AC-10.
- Reporting **structural presence, not integrity** is the right contract; the deeper "is it loadable" check belongs to `Repo::open` (already the case).

### 2. Walk-up is a **separate, additive** concern — recommended, but its own work item

Add a small **stat-only** helper in `zanshin-jj`, above `detect()`, mirroring `gg`/jj-CLI:

```rust
/// Walks up from `start` to the nearest enclosing repository root.
/// Returns the first ancestor (including `start`) that `detect()` classifies
/// as `Jj` or `Git`, together with that kind; `None` if the walk reaches the
/// ceiling with no hit. Stat-only — cheap enough for a file picker.
#[must_use]
pub fn find_repo_root(start: &Path) -> Option<(PathBuf, RepoKind)>;
```

- **Composes with `detect()`** — it calls the same checks at each ancestor; zero duplication of the marker logic.
- **Serves both flows** Zanshin already has: the GUI **open-project** picker (be forgiving if the user picks a sub-dir) *and* the planned **MCP cwd-walk-up** (Story 7-1 already specifies "CWD ancestor walk-up for `.jj/`"). One helper, both call-sites — DRY.
- **Stop policy:** default to `/` (jj parity). Treat a `$HOME` ceiling as a worthwhile, optional guard — but per project memory *"backend exposes capability, UI offers the decision"*, keep the helper minimal and let the **open-flow / UI decide** whether to walk up at all and whether to prompt before adopting an out-of-picked-folder ancestor repo (the VS Code / JetBrains pattern). Do **not** bake a UX policy into the primitive (Simplicity First).

### 3. UX nuance for the GUI file-picker (decision for the UI layer, surfaced not decided)

When the user *explicitly* picks a folder, two reasonable behaviours exist, both seen in the wild:
- **Forgiving (Sublime Merge / editors):** if the picked folder is `Neither`, walk up and open the enclosing repo.
- **Consent-gated (VS Code `openRepositoryInParentFolders: prompt`, JetBrains notification):** walk up, but *offer* the ancestor repo ("This folder is inside a jj repo at `<root>` — open that?") rather than silently retargeting.

The consent-gated variant fits Zanshin's "don't patronise — surface the choice" stance best. This is a UI decision (out of this repo's scope); the backend just needs to expose `find_repo_root` so the UI *can* offer it.

### 4. Story / sequencing impact

- **Story 2.11**: unaffected — stays in `review`, no rework. The research *validates* the implemented marker.
- **Walk-up helper**: net-new surface. Cleanest home is **Story 7-1** (MCP cwd-walk-up already needs it) promoted to a shared `find_repo_root` in `zanshin-jj`, consumed by both the MCP binary and the GUI open-flow. Alternatively a small dedicated story feeding both. Not 2.11, not 3.4c.
- **Story 2.12 (convert)**: benefits directly — "user picked a sub-dir of a Git repo → offer convert at the resolved root" uses the same helper.

---

## Risks, edge cases & gotchas

- **Secondary-workspace store is remote-on-disk:** `detect()` returning `Jj` for a secondary workspace is *correct*, but `Repo::open` may still fail with `RepoDoesNotExist` if the primary moved. UI must handle "looks like jj, won't load" — already the detect/open split's job.
- **Dotfiles repos under `$HOME`:** the concrete reason to consider a `$HOME` ceiling on walk-up (JetBrains does exactly this).
- **`.git` as a pointer file** (`gitdir:`): `detect()` already returns `Git` via `.git`-`exists` — matches AC-10 and git's own gitfile handling. Walk-up over such a tree is fine.
- **Colocated repos:** `.jj/` + `.git/` → `Jj` (AC-3) and that ordering matches jj's "a colocated repo *is* a jj repo". No interaction problem with walk-up.
- **Symlinked markers:** jj-lib `dunce::canonicalize`s the resolved secondary-repo path; our `is_dir()`/`exists()` already follow symlinks (`stat`, AC-11). Consistent.
- **Don't add the git-style structural check** (`HEAD`+`objects/`+`refs/`) to `detect()`: for the "is this plausibly a convertible Git repo" purpose, *presence* is the right altitude (and every Git GUI agrees). Integrity is the converter's / `Repo::open`'s job.

---

## Sources

**jj-lib 0.41.0 (local source — ground truth):**
- `src/workspace.rs:406-415` (`Workspace::load`), `:564-589` (`DefaultWorkspaceLoader::new`, the `.jj/`-is-`dir` gate + `.jj/repo`-file redirection), `:305-306` (primary `init` → `.jj/repo` dir), `:382-385` (`init_workspace_with_existing_repo` → `.jj/repo` file), `:91-105` (`WorkspaceLoadError` — all failures are `Result`s, no panic)
- `src/repo.rs:710-711` (store at `<repo_dir>/store`), `:641-649` (`read_store_type`)
- `tests/test_workspace.rs:79-82` (secondary `.jj/repo` is a file `"../../repo/.jj/repo"`)

**jj-cli v0.41.0:** `cli/src/cli_util.rs:2739-2743` (`find_workspace_dir` walk-up), call site `:4398`

**git / libgit2:** git(1) env vars (`GIT_DISCOVERY_ACROSS_FILESYSTEM`, `GIT_CEILING_DIRECTORIES`, `GIT_DIR`); `git/setup.c` (`is_git_directory`, `setup_git_directory_gently_1`, `read_gitfile`); `gitrepository-layout(5)`; libgit2 `include/git2/repository.h` (`git_repository_discover`, `GIT_REPOSITORY_OPEN_NO_SEARCH`, `GIT_REPOSITORY_OPEN_CROSS_FS`)

**jj clients:** `gg` `src/worker/gui_util.rs:1345-1349`, `:118-129`, `src/gui/menu.rs` (file picker); `lazyjj` `src/env.rs` (`jj root`); `jjui` `cmd/jjui/main.go` (`jj root`)

**Git GUIs:** GitKraken feedback #199003 (no walk-up); Sublime Merge `docs/command_line` + issues #1548/#1026; SourceTree Atlassian community thread; GitHub Desktop issue #2832; Tower Mac help (root + "Search Local Hard Drive"); Fork release notes

**Editors:** VS Code `extensions/git/src/git.ts:504`, `src/model.ts:632`/`409-443`, `package.json` (`git.autoRepositoryDetection`, `git.repositoryScanMaxDepth=1`, `git.openRepositoryInParentFolders=prompt`); JetBrains `intellij-community .../roots/VcsRootDetectorImpl.java:88-228` (up+down, `$HOME` ceiling); Zed worktree `WorkDirectory::AboveProject`

**Project context:** `crates/zanshin-jj/src/detect.rs` (Story 2.11), `crates/zanshin-jj/src/repo.rs` (`Repo::open`), `_bmad-output/implementation-artifacts/2-11-…md`, sprint-status Story 7-1 (MCP cwd-walk-up)

---

*Research conducted 2026-06-26 via a 9-agent fan-out workflow (ground-truth source reading + multi-source web verification + adversarial cross-check of 3 pivotal claims). Two agents hit a tooling cap; their facts were independently recovered and are noted inline.*
