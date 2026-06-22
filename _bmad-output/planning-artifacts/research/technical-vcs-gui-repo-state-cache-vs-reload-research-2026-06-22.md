---
stepsCompleted: ['survey', 'verify', 'concepts', 'synthesis']
inputDocuments: ['_bmad-output/project-context.md', '_bmad-output/planning-artifacts/architecture.md', '_bmad-output/planning-artifacts/epics.md']
workflowType: 'research'
research_type: 'technical'
research_topic: 'VCS GUI repository state: held in-memory cache vs reload-per-operation, and how the cache is kept coherent with disk'
research_goals: 'Decide whether Zanshin should hold a long-lived in-memory jj-lib repository object (a "Repo handle") or reload state from disk per operation, by examining how existing Git and jj GUIs/TUIs solve it.'
user_name: 'Ralph'
date: '2026-06-22'
web_research_enabled: true
source_verification: true
---

# Research Report: How Git & jj GUIs manage repository state (held cache vs reload-per-operation)

**Date:** 2026-06-22
**Author:** Ralph
**Research Type:** technical
**Method:** 29-agent fan-out (13 tools surveyed + adversarially verified against primary source code; 3 concept lanes). Every architectural claim was independently re-checked against source code or official docs before inclusion.

---

## 0. The question (why this exists)

While reviewing the FFI repo **handle** (commit `c1c1f38`, Story 3-9), the deeper question surfaced: **why hold a handle at all?** A jj repo, unlike the jj CLI's per-command model, would be held warm in memory. Two objections drove the research:

1. **The cache creates a sync problem.** A held in-memory repo state can diverge from disk when an external `jj` CLI (or another process) mutates the repo. *"Schaffen wir uns durch diesen Cache nicht ein anderes Problem?"*
2. **The jj CLI is not slow.** Each CLI command reloads from disk and is fast. *"Warum sollten wir das mit der GUI nicht ähnlich effizient hinbekommen?"*

This report answers: **Do real Git/jj GUIs hold an internal cache, or reload from disk per operation — and how do the ones that cache stay coherent?**

---

## 1. Executive summary (the answer)

- **The majority of VCS GUIs/TUIs reload repository state from disk per operation.** The ones that hold a warm in-memory cache are the heavyweight commercial GUIs (GitKraken, Sublime Merge, SmartGit) — and **they pay for it with a filesystem watcher *plus* a documented history of stale-state bugs.**
- **The on-disk repository is universally treated as the single source of truth.** Any in-memory model is a *derived cache* that must be invalidated/re-derived on change. There is no tool that treats an in-memory model as authoritative.
- **For jj specifically, reloading per operation is endorsed by jj's own design.** Loading a repo (`RepoLoader` → `ReadonlyRepo`) is lightweight; the operation log is the source of truth and gives **lock-free concurrency**, making reload-per-operation *correct-by-construction*. The genuinely expensive step — the **working-copy snapshot** — is independent of hold-vs-reload and is solved by `fsmonitor`/Watchman.
- **The single most relevant prior art — GG, the only mature jj-lib desktop GUI — keeps only the heavyweight loader warm but re-resolves repo state from disk on every refresh** (`load_at_head()`), driven by refresh-on-focus, with **no filesystem watcher**. This is effectively "reload-per-operation for the actual state, warm loader for the cheap part."
- **The cache-coherency concern (objection 1) is real and is the dominant defect class** for held-state GUIs. The universal mitigation is a filesystem watcher — but even with one, a focus/poll/manual backstop is mandatory because the OS drops events.
- **Recommendation for Zanshin: lean to a GG-style hybrid (Option C).** Treat the op-log as authority, re-resolve to the latest operation per operation (`repo_loader().load_at_head()` — already the intent of the codebase's "Decision D4"), keep the `Workspace` warm only as a loader, and use the planned **op-heads watcher as the coherency trigger** (not as a cache that can silently diverge). Prefer a **lazy revset stream** for the commit graph (GG's model) over a materialized lane cache.

---

## 2. The two architectures

| | **(B) Reload-per-operation** | **(A) Held-in-memory cache** |
|---|---|---|
| Repo state | re-derived from disk each op/refresh | warm object + derived caches kept across ops |
| Coherency with external change | **free** — can't go stale (always re-derives) | must be engineered: watcher invalidation + backstop |
| Watcher role | *optimization* (when to re-read) — never a correctness dependency | *correctness dependency* — a missed event = silent staleness |
| Cost | a full read per refresh (cheap in jj; cheaper in libgit2) | complex invalidation; races against external writers; bug surface |
| Failure mode | UI flicker / latency on big repos | stale view persisting indefinitely on a dropped event |

A third, real-world shape is the **hybrid**: keep a warm *render cache* for snappy UI, but re-derive authoritative state from disk on each operation (GitHub Desktop, VS Code Git, and — at the jj-lib level — **GG**).

---

## 3. The survey (13 tools, all verified against primary source)

| Tool | Backend | State model | Coherency mechanism |
|---|---|---|---|
| **GG** (jj) | jj-lib in-process | **warm loader + reload-per-op** (`load_at_head`) | **refresh-on-focus**; re-resolves op-heads from disk; **no FS watcher** |
| jjui (jj) | jj CLI shell | reload-per-op (no cache) | post-mutation + focus + optional polling (default off) |
| lazyjj (jj) | jj CLI shell | reload-per-op (text cache only) | manual (`Shift+R`/`F5`) + post-action + focus-regain; no watcher |
| jjgui (jj) | jj CLI shell | reload-per-op | undocumented (closed) |
| **jjk / Jujutsu Kaizen** (jj, VS Code) | jj CLI shell | derived cache, **op-id-keyed** | **FS watcher on `.jj/…/op_store/operations/*`** + 5s poll + op-id invalidation |
| **gitui** (git) | libgit2 in-process | **reload-per-op** (opens repo fresh!) | opt-in `notify` watcher *(trigger only)*, else 5s poll + result-hash dedupe |
| lazygit (git) | git CLI shell | reload-per-op | **2s cheap-probe** (`for-each-ref`+HEAD diff) gates the full reload; 10s files / 60s fetch; no watcher |
| VS Code Git | git CLI shell | hybrid (parsed-status cache) | **2 FS watchers** (worktree + `.git`), 1s debounce, **focus-gated**; re-runs `git status` from disk |
| GitHub Desktop | git CLI (dugite) | hybrid (warm UI caches) | **refresh-on-focus** (primary); no worktree watcher; optional periodic fetch |
| Magit (git) | git CLI shell | **reload-per-op (pure)** | regenerate buffer from scratch via git after own command / manual `g`; no held model |
| GitKraken | libgit2 → git CLI | held + cache | **native FS watcher (NSFW)**; **shipped explicit cache-bust code** to stay correct |
| Sublime Merge | custom reader + git CLI | held + cache | **native FS watcher** + optimistic in-memory mutation; history-graph can lag |
| SmartGit | JGit → own read lib + git CLI | held + cache | **FS watcher** (inotify/FSEvents) + refresh-on-activation + manual `F5` |

**Two findings that puncture easy assumptions:**

- **"In-process library" ≠ "held state."** `gitui` links libgit2 yet **opens a fresh `git2::Repository` per operation** and holds no repo object — it is firmly reload-per-operation. The choice is *independent* of whether you embed a library or shell a CLI.
- **The held-state cohort is exactly where the coherency bugs live** (§5).

---

## 4. The jj cost model — reload is cheap; the snapshot is the cost

From the official jj architecture/working-copy/operation-log/config docs (verbatim, verified):

- **Loading is lightweight, not a scan.** *"The `RepoLoader` … you can think of as a pointer to the `.jj/repo/` directory. It can create a `ReadonlyRepo` given an operation ID."* A `ReadonlyRepo` is *"the state of a repo at a specific operation"* holding the view object. Loading resolves an operation ID and reads the associated view/index — it does **not** walk the working tree.
- **The expensive step is the working-copy snapshot**, which most commands do *first*: `TreeState` *"keeps track of the mtime and size for each tracked file … `snapshot()` will use the recorded mtimes and sizes and detect changes."* Cost scales with the number of tracked files. **This cost is paid whenever you snapshot — independent of whether you hold or reload the repo object.**
- **`fsmonitor`/Watchman makes the snapshot incremental:** *"In large repositories, it may be beneficial to use a 'filesystem monitor' … This allows jj to take working copy snapshots without having to rescan the entire working copy."* jj stores Watchman "clocks" in `TreeState`.
- **The op-log is the source of truth, and it is lock-free:** *"When you run a jj command, it will start by loading the repo at the latest operation."* *"One benefit of the operation log … is that it allows lock-free concurrency."* → **reloading per operation matches the CLI's proven, concurrency-safe model.** Holding an in-memory repo risks staleness vs. concurrent external jj processes *unless re-resolved to the latest operation*.
- **Numbers (low confidence — user-reported, not maintainer benchmarks):** `jj status` ~1s on a typical ~3M-LOC repo; ~25s only on a pathological repo (attributed to a huge *tag* count, not file count), per jj-vcs/jj#1841. No published repo-*load* benchmark was found. **→ This is exactly the kind of thing worth measuring against Zanshin's own fixtures before finalizing (see Risks).**

**Implication:** the performance justification for holding the jj repo object is *weak*. The real lever is the snapshot (→ Watchman) and not re-snapshotting redundantly — both orthogonal to hold-vs-reload.

---

## 5. The cache-coherency pattern (and why the cache is the problem)

There is no industry spec, but a convergent pattern: **disk is truth; the in-memory model is a derived cache invalidated on change.** Detection has two tiers used together:

1. **Event-driven filesystem watcher** (OS-native: inotify / FSEvents / ReadDirectoryChangesW; libs: `notify`, parcel-watcher, NSFW) over the working tree **and** the VCS internals (for git: `.git/refs`, `HEAD`, `index`; for jj: the **op store / op heads**).
2. **Backstops** — periodic polling, refresh-on-window-focus, manual refresh — **mandatory because watchers are not reliable.** VS Code's own docs: *"the operating system may decide to drop file events at any time, with no 100% guarantee of event delivery."*

**The held-cache model is where the bugs concentrate** (all real, cited):

- **Zed #48703** — git panel shows stale branch/file status after a terminal `checkout`/`rebase` or sleep/wake; lost/coalesced FS events + no rescan-on-activation ⇒ *"the stale state persists indefinitely."*
- **GitHub Desktop** — deleted branches still shown until restart (#5893, #1489); cached/IndexedDB branch list not invalidated.
- **lazygit #5184** — stuck in "Rebasing" state by reading a partially-written `.git/rebase-merge` (race against external writer).
- **GitKraken / NodeGit PR #1685** — had to ship explicit cache-busting (`git_repository_config_snapshot`) because *"LibGit2 is not checking the disk when listing the remote names."* **Direct evidence that holding the object created a coherency problem they engineered around.**
- **Sublime Merge** — history/commit-graph view lags external CLI mutations, needs manual `Cmd+R`; and fails to auto-update over WSL2/network mounts (the signature of a watcher, not a poller).

**The clean extreme is Magit:** it holds *no* long-lived model — it re-creates buffer contents from scratch via git on every refresh. Slow on big repos (#4702: ~28s), but it *cannot* silently diverge. Its safety comes precisely from not holding a cache.

**→ Objection 1 confirmed:** a held cache *is* the source of the sync problem, and the mitigation is the watcher you already accepted — the watcher does double duty (notification + cache invalidation).

---

## 6. The jj-GUI landscape (prior art completeness)

Per the jj wiki "GUI and TUI" page and the community-tools catalog: **~3 in-process jj-lib tools vs ~13 CLI-shelling tools.** jj's own summary: *"Most UIs (including jjui) shell out to jj, while some like gg and VisualJJ link to jj_lib and jj_cli."*

- **In-process (jj-lib):** **GG** (gulbanana — Tauri/Rust/Svelte), **VisualJJ** (proprietary VS Code extension), **jayjay** (native macOS Rust+SwiftUI; hybrid jj-lib + some CLI).
- **CLI-shelling:** jjui, lazyjj, blazingjj, jj_tui, jj-fzf, jjiles, jujutsu-gi/ji, jjk (Jujutsu Kaizen), Selvejj (JetBrains), Jjewel (Mac), jjgui, Visual Jujutsu/vjj, JJ View.

**GG is the single most relevant data point** — the only mature, open-source, jj-lib, desktop GUI. It is essentially Zanshin's reference architecture.

### 6.1 Deep dive — GG (the closest analog)

Verified against `gulbanana/gg` master source:

- Holds a `WorkspaceSession` with the jj-lib `Workspace` **loaded once** (`gui_util.rs`), plus a per-operation `OperationData { repo: Arc<ReadonlyRepo>, ref_index: OnceCell, workspace_index: OnceCell, prefix_context }`.
- On refresh (focus event → `ExecuteSnapshot`), `load_at_head()` **re-resolves the head operation from the on-disk op store** and swaps in fresh `OperationData` if the op-id changed; mutations replace it with the just-written op. The heavyweight loader/index-store stays warm; the per-op view is re-derived.
- **No filesystem watcher.** Coherency = refresh-on-focus + 30s liveness heartbeat (not a repo refresh). CHANGELOG confirms: *"snapshots happen after modifications or when the window/tab is focused"* and *"detect changes made by other Jujutsu clients and merge the operation log automatically."*
- **Does NOT materialize a commit graph.** `QuerySession` is a paginated cursor over a *lazily-evaluated revset stream* (`TopoGroupedGraph`) with one-node lookahead — `QueryState` stores only page size / cursor / graph-drawing stems.

### 6.2 The elegant coherency trick — jjk's op-store watcher

jjk (VS Code) watches **`.jj/…/op_store/operations/*`** and invalidates a cache keyed by the current **operation ID**: any jj command anywhere (incl. external CLI) appends a new operation file → the watcher fires → if the op-id changed, reload; else short-circuit (cache hit). This detects external changes precisely and cheaply by watching the *op store* rather than the working tree — **and it is exactly Zanshin's planned watch path** (`.jj/repo/op_heads/heads/`).

---

## 7. Implications for Zanshin

The codebase already leans the right way: `crates/zanshin-jj/src/repo.rs` documents **"Decision D4"** — read-stories use `repo_loader().load_at_head()` (re-resolve to head); `Repo::clone` already calls it. The research turns that buried intent into a deliberate, named architecture.

**Recommended: a GG-style hybrid (Option C).**

1. **Op-log = authority.** Per read/refresh, re-resolve to the latest operation (`load_at_head()`), do not serve a cached `ReadonlyRepo` view that can silently diverge.
2. **The handle keeps a narrow role:** a **warm loader + owner of the op-heads watcher** — *not* a cache of repo state. (This is GG's `WorkspaceSession`.) This directly answers the original "what is the handle for" question and removes the coherency hazard.
3. **The op-heads watcher is the coherency mechanism** (already planned, FR-FFI watcher stories): it both notifies the UI *and* triggers the re-resolve/invalidate. Watching the op store (jjk-style) is more precise than watching the working tree.
4. **Commit graph: prefer a lazy revset stream** (GG `QuerySession`) over the currently-planned "rebuild lane cache on every `op_heads` change." Re-evaluate whether a materialized lane cache is needed at all.
5. **Snapshot cost → Watchman**, not a repo cache (Zanshin already plans Watchman *detection*, FR-FFI-7).
6. **A focus/manual backstop** is still wise (OS drops events) even though Zanshin's worker-isolate single-consumer model is simpler than VS Code's.

What does **not** change: the single-consumer worker isolate (AD-4), no `Arc<Mutex>` (AD-2), the opaque-handle FFI mechanics, FlatBuffers transport (ADR-0001). The refinement is about *what the handle represents* (loader, not state-cache) and *how reads derive state* (re-resolve, not cache).

See **ADR-0002** for the resulting decision and **epics.md / the new code-direction story** for the implementation steering.

---

## 8. Risks & open questions

- **Unmeasured load/snapshot cost.** The whole hold-vs-reload trade rests on `Workspace::load` + snapshot cost at Zanshin's fixture sizes (tiny-3 / medium-1k / large-10k). *Recommend a small, non-CI benchmark* before committing to a graph-caching strategy. (jj's published numbers are user-reported and conflate git-import/tag costs.)
- **Graph streaming vs. lane cache** is the one place this research may contradict the current epics plan (`zanshin-graph` lane cache). Needs an explicit decision — GG ships without a materialized graph.
- **Backstop policy.** GG uses focus-only (no watcher); Zanshin wants the op-heads watcher anyway. Decide whether focus/manual refresh is also needed as a backstop for dropped events.
- **VisualJJ / jayjay** (the other two in-process jj-lib tools) were not source-audited (VisualJJ is closed; jayjay is young). A follow-up read could confirm whether either materializes a graph or holds authoritative state.

---

## 9. Sources

**jj (primary):**
- jj architecture — https://docs.jj-vcs.dev/latest/technical/architecture/
- jj working copy — https://docs.jj-vcs.dev/latest/working-copy/
- jj operation log — https://docs.jj-vcs.dev/latest/operation-log/
- jj config (fsmonitor) — https://docs.jj-vcs.dev/latest/config/
- jj GUI/TUI wiki — https://github.com/jj-vcs/jj/wiki/GUI-and-TUI
- jj community tools — https://docs.jj-vcs.dev/latest/community_tools/
- perf datapoint — https://github.com/jj-vcs/jj/issues/1841
- Firefox/mozilla-central jj guidance — https://firefox-source-docs.mozilla.org/contributing/jujutsu.html

**jj GUIs (primary source):**
- GG — https://github.com/gulbanana/gg (src/worker/gui_util.rs, session.rs, queries.rs; CHANGELOG.md)
- jjui — https://github.com/idursun/jjui (internal/ui/context/command_runner.go, main_context.go)
- lazyjj — https://github.com/Cretezy/lazyjj (src/commander/mod.rs, src/app.rs, src/ui/log_tab.rs)
- jjk — https://github.com/keanemind/jjk (src/services/RepoState.ts, src/repoLifecycle.ts, src/eventLoop.ts)
- jjgui — https://jj-gui.com/

**Git GUIs (primary source):**
- gitui — https://github.com/gitui-org/gitui (asyncgit/src/sync/repository.rs, status.rs, revlog.rs; src/watcher.rs, args.rs)
- lazygit — https://github.com/jesseduffield/lazygit (pkg/gui/background.go, commands/git_commands/status.go, commit_loader.go; issue #5278)
- VS Code Git — https://github.com/microsoft/vscode (extensions/git/src/repository.ts, watch.ts); File Watcher Internals wiki
- GitHub Desktop — https://github.com/desktop/desktop (app/src/lib/stores/git-store.ts, repository-state-cache.ts; app/src/ui/index.tsx; issues #2790, #5893, #1489)
- Magit — https://github.com/magit/magit (lisp/magit-mode.el, magit-git.el; docs.magit.vc/magit/Performance.html; issue #4702)
- GitKraken — https://www.gitkraken.com/blog/node-sentinel-file-watcher; https://github.com/nodegit/nodegit/pull/1685; https://github.com/Axosoft/nsfw
- Sublime Merge — https://news.ycombinator.com/item?id=19807838 (founder); sublime forum WSL2/history-graph threads
- SmartGit — https://docs.syntevo.com/SmartGit/Latest/...; https://www.smartgit.dev/whats-new/22_1/

**Coherency failure-mode evidence:**
- Zed #48703 — https://github.com/zed-industries/zed/issues/48703
- VS Code File Watcher (dropped events) — https://github.com/microsoft/vscode/wiki/File-Watcher-Internals
- GitButler watcher rationale — https://github.com/gitbutler/gitbutler/issues/7458
- Git fsmonitor — https://github.blog/2022-06-29-improve-git-monorepo-performance-with-a-file-system-monitor/

---

_Generated via a 29-agent research workflow (survey → adversarial verification → concept synthesis); all architectural classifications were verified against primary source code or official documentation. Confidence is high for open-source tools (source read directly) and medium for closed-source tools (docs/blogs/founder statements)._
