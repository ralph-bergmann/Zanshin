# ADR-0002: Repository state model — warm loader + reload-per-operation, not a held state cache

- **Status:** Accepted (2026-06-22) — the core decision (repo handle = warm loader + reload-per-operation; op-heads watcher as coherency trigger; multi-repo 0..N) is benchmark-confirmed **up to 10k commits** (re-resolution ~0.7–1.0 ms; Story 3.11 AC-1). The commit-graph sub-decision (FR-GR-3) is **resolved — lazy revset stream (GG model), no materialized lane cache** (AC-4: full graph derive ~3.1 ms @ 10k; Story 3.11). Epic 4 implements it. See Open questions.
- **Date:** 2026-06-22
- **Deciders:** Ralph
- **Refines:** AD-2 (handle lifetime & ownership), AD-4 (worker isolate), AD-5 (watcher) in `architecture.md`
- **Touches:** FR-GR-3 (`zanshin-graph` lane cache) — see Open questions
- *(Note 2026-10-01, Story 4.12: the `zanshin-graph` crate named here and below (Decision 4, Consequences, Open questions, the benchmark and reference lines) was removed together with its FFI slice `zanshin_graph_slice`. The streamed, never-cached commit graph this ADR decided is now Story 4.10's index-only `Repo::graph_topology`, carried by `zanshin_graph_topology` and laid out in Dart (Story 4.11); the decision itself is unchanged. The accepted text below is kept as written.)*
- **Backed by:** `_bmad-output/planning-artifacts/research/technical-vcs-gui-repo-state-cache-vs-reload-research-2026-06-22.md`

## Context

The FFI **handle** (introduced through Stories 3.2/3.4a, wired to the worker isolate in Story 3-9 / commit `c1c1f38`) is a `Box<Repo>` leaked to Dart as an opaque `u64`. `Repo` bundles a jj-lib `Workspace` + `UserSettings`. The handle is held by the worker isolate for the app lifetime.

Reviewing it raised a foundational question: **what is the handle *for*, and does holding repo state in memory buy us anything worth its cost?** Two objections:

1. **A held in-memory cache creates a coherency problem** — it can silently diverge from disk when an external `jj` CLI (or the MCP server, or another GUI) mutates the repo. Zanshin's whole same-repo-concurrency model (FR-MCP-9, FR-RX-3) assumes exactly that.
2. **The jj CLI is not slow.** It reloads from disk per command and stays fast. Why hold state at all?

AD-2 in `architecture.md` (lines 205–213) settles handle *ownership* (`Box<T>`, single-threaded worker-isolate access, no `Arc<Mutex>`, `NativeFinalizer`) but is **silent on whether the handle holds cached repo state or re-derives it per operation.** This ADR fills that gap.

A 29-agent prior-art study (survey + adversarial verification against primary source code) examined 13 Git/jj GUIs and jj's own cost model. The decisive findings:

- **jj loading is lightweight.** Per the jj architecture docs, a `RepoLoader` is *"a pointer to the `.jj/repo/` directory"* that produces a `ReadonlyRepo` (*"the state of a repo at a specific operation"*) by resolving an operation ID — **not** a working-tree scan. The expensive step is the **working-copy snapshot** (`TreeState` mtime/size scan), which is *independent of hold-vs-reload* and is mitigated by `fsmonitor`/Watchman. The op-log is the source of truth and gives **lock-free concurrency**, so reload-per-operation is *correct-by-construction*.
- **Held caches are where the coherency bugs concentrate** (Zed #48703 indefinite staleness on a dropped FS event; GitHub Desktop stale branch lists; lazygit stuck-rebase race; **GitKraken had to ship explicit cache-bust code**, NodeGit PR #1685, because *"LibGit2 is not checking the disk"*; Sublime Merge history-graph lag). Even watcher-based tools need a focus/poll/manual backstop because *"the OS may drop file events at any time"* (VS Code docs).
- **GG — the only mature jj-lib desktop GUI — does NOT hold authoritative repo state.** It keeps the heavyweight `Workspace`/loaders warm but **re-resolves to the head operation from disk on every refresh** (`load_at_head()`), driven by refresh-on-focus, with **no filesystem watcher**, and renders the graph from a **lazy paginated revset stream** rather than a materialized graph.
- **The codebase already leans this way:** `crates/zanshin-jj/src/repo.rs:41-45` documents *"Decision D4"* — read-stories use `repo_loader().load_at_head()`; `Repo::clone` already calls it. This ADR turns that buried intent into a named architecture.

## Decision

**The on-disk jj operation log is the single source of truth. The handle is a warm *loader and watcher owner*, not a cache of repo state. Repo state is re-derived from the current operation on each operation; coherency comes from the op-heads watcher, never from trusting an in-memory copy.**

Concretely:

1. **Handle = warm `Workspace` loader + owner of the repo's op-heads watcher.** It holds the jj-lib `Workspace` (and `UserSettings`) loaded once — the cheap-to-keep part. It does **not** hold an authoritative `ReadonlyRepo` view as a long-lived cache that downstream reads trust blindly.

2. **Reads re-resolve to head.** Every read/refresh operation resolves the latest operation via `workspace.repo_loader().load_at_head()` and operates on that freshly-resolved `ReadonlyRepo`. (This is "Decision D4" made explicit and architecture-level.) Cheap derived indices may be memoized *for the duration of one resolved operation* and discarded when the op-id advances — never held across an op-id change.

3. **The op-heads watcher is the coherency mechanism, not merely a notification.** AD-5's watcher on `.jj/repo/op_heads/heads/` (+ `working_copy/checkout` heartbeat) both notifies the UI *and* signals "re-resolve / invalidate." Comparing the resolved op-id to the last-seen one is the cache-validity check (the same trick jjk uses by watching the op store). A missed event delays a refresh; it can never produce a silently-divergent authoritative cache, because there is no such cache.

4. **The commit graph is derived and streamed, not held as authoritative state (AC-4 resolved: ~3.1 ms full derive @ 10k).** Like GG, `zanshin-graph` renders from a lazy revset stream (`stream_graph` + `TopoGroupedGraph`) with **no materialized lane cache**; the graph is re-derived on op-id advance and never trusted across one. (Supersedes the FR-GR-3 "full lane-cache on open / op_heads" framing.)

5. **Unchanged.** The opaque-handle FFI mechanics (AD-2 `Box<T>` ownership, single-consumer worker isolate AD-4, no `Arc<Mutex>`, `NativeFinalizer`), FlatBuffers transport (ADR-0001), and the watcher's debounce/backpressure (AD-5) all stand. This ADR changes *what the handle represents* and *how reads derive state* — not the boundary mechanics.

## Multi-repo / project overview

Zanshin's UI is multi-project (a SourceTree-style overview that updates live as the user edits on the console or, later, on remote-sync). The app therefore holds **0..N** repos concurrently. This is already supported: the FFI handle mechanism is generic, the worker isolate already keys a `handleId → raw pointer` table for N handles, and **AD-2 holds for N repos** — one isolate serializes all access, so still no `Arc<Mutex>`. (AD-6's single-repo / no-in-process-registry rule is the **`zanshin-mcp` binary's** constraint, not the app's.)

But "a project in the overview" must **not** be conflated with "a warm `Repo` handle." Three tiers:

| Tier | Held state | Cost |
|------|-----------|------|
| **Registered** (listed, not focused) | a path (+ config entry) only | ~0 |
| **Overview summary** (status / change / ahead-behind shown) | **no warm handle** — stateless re-resolve on demand (`load_at_head()` is cheap), triggered by that project's op-heads watcher | one cheap re-resolve, only when the project actually changes |
| **Active** (graph / diff / mutation open) | a warm `Repo` handle | one full load, justified |

- **One op-heads watcher per observed project** is the live-update mechanism: an external `jj` CLI edit (or remote-sync) mutates that project's `op_heads` → its watcher fires → only that overview row re-resolves. Steady-state cost ≈ 0 (no polling across projects). The watcher thus does triple duty: notify + invalidate + "which project to refresh."
- **Watcher events carry a repo/handle correlation id** (which project fired) on the event port — a requirement for the deferred watcher stories (3.5 / 3.6).
- This **strengthens** the reload-per-operation decision: holding N warm heavyweight `Workspace` loads for an N-project sidebar would be the worst case for the held-cache model; stateless re-resolve per row scales cleanly. (GitHub Desktop is the multi-repo datapoint — `RepositoryStateCache` keys state by repo, holds many, reloads authoritative state from git per operation.)
- **The Story 3.11 benchmark must measure *per-repo* cost**, because the overview multiplies it by N.

## Evidence

From the research report (full citations there):

- **jj cost model** — load = pointer + op-id resolution (lightweight); snapshot = the real cost, orthogonal to hold-vs-reload, solved by Watchman; op-log = lock-free source of truth. (jj architecture / working-copy / operation-log / config docs.)
- **Prior-art split** — of 13 surveyed tools, the majority reload-per-operation; the held-cache cohort (GitKraken, Sublime Merge, SmartGit) all need a watcher *and* carry documented staleness bugs. "In-process library" ≠ "held state" (gitui links libgit2 yet opens a fresh `Repository` per op).
- **GG** (the closest analog) — warm loader + `load_at_head()` per refresh + lazy revset stream + no watcher. Verified against `gulbanana/gg` master source.
- **Coherency failure modes** — held caches diverge on dropped events; the watcher + a focus/manual backstop is the standard fix.

## Consequences

**Positive**

- The coherency problem (objection 1) is removed *structurally*: there is no authoritative in-memory cache that can silently diverge from disk. Same-repo concurrency (external `jj` CLI + MCP + GUI) is correct by construction, matching jj's own lock-free model.
- The handle's purpose becomes crisp and defensible: a warm loader + watcher owner. This answers "what is the handle for" cleanly and lets the `repo.rs`/`handle.rs`/AD-2 comments be corrected (see below).
- Aligns with the strongest prior art (GG) and with jj's design philosophy (disk = truth).
- Less to invalidate, fewer cache-coherency code paths, smaller bug surface.

**Negative / costs (accepted)**

- A read re-resolves the op each time. Cheap in jj-lib (pointer + op-id), but **unmeasured at Zanshin's fixture sizes** — see Open questions.
- Moving `zanshin-graph` off a materialized lane cache (now decided — AC-4) is real rework of the FR-GR-* plan and the current graph Story/Epic — Epic 4 implements the stream.
- A focus/manual backstop may still be needed for dropped watcher events (OS guarantees are not 100%), adding a small amount of UI plumbing (Ralph's UI scope).

## Affected prior decisions & docs

- **AD-2** — *refined, not contradicted*: ownership/lifecycle/concurrency stand; this ADR adds the missing rule that the handle is a warm loader, not a state cache, and that reads re-resolve to head. *(2026-09-30, Story 4.10: one read answers at a caller-supplied operation instead — see Addendum 2026-09-30.)*
- **AD-5** — *reframed*: the op-heads watcher is explicitly the coherency/invalidation trigger, not only a UI-refresh notification.
- **FR-GR-3** (`zanshin-graph` `cache.rs — full lane-cache on open / op_heads`, architecture.md lines 441–444) — *superseded (AC-4 resolved 2026-06-22)*: materialized lane cache → **lazy revset stream (GG model), no materialized cache**. A jj-lib spike derives the full graph at 10k in **~3.1 ms** and streams the first render page in **~27 µs** (Story 3.11), so re-deriving on op-id advance is trivially cheap. Epic 4's `cache.rs`/`slice.rs` implement the stream (lane-number assignment adds O(1)/node, expected negligible).
- **Doc-drift to fix** (follow-up story): `crates/zanshin-ffi/src/repo.rs:166` and `handle.rs` comments say *"AD-2: no handle table"* in a way that reads as "no state held"; reconcile their wording with "warm loader + re-resolve per op." (The Dart-side worker handle table from Story 3-9 also already provides use-after-free safety the Rust comments don't credit.)

## Open questions

- **Benchmark — resolved for the load path (2026-06-22, Story 3.11).** Measured on `tiny-3` + `medium-1k` + `large-10k` (release, warmup + min/median over 51 iters, two passes): `load_at_head()` re-resolution is **~100–250 µs at ≤1k and ~0.7–1.0 ms at 10k** (stable, monotonic tiny<medium<large, sub-linear growth); `Workspace::load` is ~0.3–1.0 ms. So reload-per-operation is decisively affordable and **Option C is confirmed up to 10k commits**. (An initial `tiny > medium` anomaly was traced to no-warmup measurement noise.) **Still open for the graph only:** `zanshin-graph`'s lane-build + render-slice cost at 10k (Epic 4) — that, not the load path, decides materialize-vs-stream; and the working-copy snapshot (orthogonal, → Watchman). See Story 3.11 Dev Agent Record.
- **Graph: stream vs. materialize — RESOLVED: stream (2026-06-22, Story 3.11 AC-4).** A spike over the 10k fixture (jj-lib `stream_graph` + `TopoGroupedGraph`, mirroring GG) derives the **entire** graph in **~3.1 ms** and streams the first 100-row render page in **~27 µs**. So re-deriving on every op-id advance is trivially cheap (≪ NFR-P-1 < 1s @ 10k) and streaming gives instant O(slice) render — a long-lived materialized lane cache buys nothing and would reintroduce the coherency burden this ADR avoids. **Decision: GG-style lazy revset stream, no materialized lane cache.** Epic 4 implements it (lane-number assignment adds O(1)/node, expected negligible).
- **Backstop policy.** GG uses focus-only (no watcher); Zanshin wants the op-heads watcher regardless. Is a focus/manual refresh *also* needed as a dropped-event backstop?

## Addendum 2026-09-23 — the working-copy snapshot is no longer "→ Watchman" (Story 9.26)

The "snapshot = the real cost … solved by Watchman" passages above (Context, Evidence, the Story 3.11 benchmark note) assumed Zanshin would never snapshot itself and that Watchman would record on-disk edits at the system level (project decision D2, Story 2.4). That assumption does not hold: Watchman is opt-in and not bundled, jj-lib triggers no snapshot on its own, and the trigger the CLI registers with Watchman excludes `.git` and `.jj`, so a `git commit`, a `git checkout` or a plain file edit made outside Zanshin stayed invisible to every Zanshin verb until the user ran a `jj` command.

Story 9.26 reverses D2. Every `Repo` verb whose CLI counterpart goes through `workspace_helper` now runs the CLI's `snapshot_impl` first — colocated: `import git head` → `snapshot working copy` → `import git refs` under jj's own `git_import_export.lock`; otherwise the snapshot alone — and `Repo::snapshot()` is `jj util snapshot`. The core decision of this ADR is unchanged: the op log stays the single source of truth, the handle stays a warm loader, reads still re-resolve to head (the precondition loads at head before it snapshots). What changes is that the snapshot's cost is paid per verb, exactly as the CLI pays it per command, with `fsmonitor.backend = "watchman"` honoured through jj-lib's compiled-in `watchman` client (the daemon is never bundled or launched). A precondition that finds nothing to do writes no operation, so the op-heads watcher → refresh → verb loop settles after one round. See `_bmad-output/implementation-artifacts/spec-9-26-implicit-snapshot-colocated-git-import.md`.

## Addendum 2026-09-30 — the op-pinned content read (Story 4.10)

A read that answers at a CALLER-SUPPLIED operation is pinned, not re-resolved, and returns commit-intrinsic values only. `Repo::commit_contents` (FFI `zanshin_commit_contents`) is that read: the commit-graph view first calls `Repo::graph_topology`, which re-resolves to head as §2 requires (after its pre-verb snapshot) and returns the operation id it loaded; it then loads the card content of the visible nodes at exactly that operation, page by page — the continuation of the same `jj log`, whose per-row commit load the CLI performs while it renders. The pinned read uses `load_operation` + `load_at`, never `load_at_head`: `load_at_head` is not write-free (it prunes ancestor op heads and publishes a "reconcile divergent operations" merge for divergent ones), whereas `load_at` writes no operation and no op head (like any load it may write the operation's index files when they are missing). Pinning cannot serve stale state: a commit is content-addressed and its parents are part of it, so its author, committer timestamp, description, conflict and emptiness are the same at every operation that indexes it; a head that moved since the topology call is picked up by re-requesting the topology on the watcher's event (§3). Nothing is retained across calls — no memoised pinned `ReadonlyRepo`, no timestamp cache — so the handle stays a warm loader (§1).

The ~3.1 ms / ~27 µs figures in the Status line, §4, the FR-GR-3 bullet and the stream-vs-materialize question time the index-only TOPOLOGY walk. Since Story 4.8 `Repo::walk_graph` loads every emitted commit for its metadata, so the full row costs the commit loads. Re-measured 2026-09-30 / 2026-10-01 (release, jj-lib 0.44.0, `crates/zanshin-jj/benches/graph_blueprint.rs` and `crates/zanshin-ffi/benches/graph_topology.rs`, medians): the raw topology-only walk is 3.1 ms at 10k and the first-100 page 30 µs, unchanged; the whole `graph_topology(all())` call — config load, parse, the precondition's snapshot (~2.5 ms on the fixtures' small working copies), the index-only per-node view half, change-id, `parent_count` and `all_count` passes — is 22 ms at 10k packed (26 ms loose) and 5 ms at 1k; its committer timestamps add ~31 ms at 10k packed (53 ms for the first call on a fresh handle) but ~1.0 s on the committed loose-object fixture; a 60-id content page is 1.7 ms packed / 3.1 ms loose at 10k on a cold commit cache, of which the pinned `load_operation` + `load_at` is ~0.8 ms; the old one-call cost — `Repo::walk_graph(all())` driven to the end on a fresh handle — is 53 ms packed / 1.09 s loose at 10k (topology plus the content of every node: 58 ms / 1.04 s). See `_bmad-output/implementation-artifacts/spec-4-10-graph-topology-content-split-op-pinned.md` § Measurements.

## References

- Research report: `_bmad-output/planning-artifacts/research/technical-vcs-gui-repo-state-cache-vs-reload-research-2026-06-22.md`
- `architecture.md` §§ AD-2 (205–213), AD-4 (231–239), AD-5 (241–249), `zanshin-graph` module + FR-GR-3 (441–444), run-time boundaries (576, 580).
- `docs/adr/0001-ffi-data-transport-flatbuffers.md` — FFI transport (unaffected).
- `crates/zanshin-jj/src/repo.rs` — "Decision D4" (`load_at_head`), `clone_into` already re-resolves.
- GG source: `github.com/gulbanana/gg` (`src/worker/gui_util.rs`, `queries.rs`, `CHANGELOG.md`).
- jj architecture: `docs.jj-vcs.dev/latest/technical/architecture/`; operation log: `…/operation-log/`.
