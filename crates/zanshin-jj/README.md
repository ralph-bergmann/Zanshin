# zanshin-jj

Anti-corruption layer over [`jj-lib`](https://crates.io/crates/jj-lib) for the
Zanshin workspace (FR-JJ-16). This is the **only** crate in Zanshin's
production/library surface that imports `jj_lib` — `zanshin-ffi` and `zanshin-mcp`
consume its typed API, never `jj_lib` directly. (The `xtask` fixture generator
also imports `jj_lib`, but only as a build-time tool.)

## Purpose

`zanshin-jj` hides every `jj-lib` internal type behind a stable, crate-owned
public API. When `jj-lib` releases a breaking change (it is pre-1.0 and does so
regularly), the diff is absorbed inside this crate — downstream crates
(`zanshin-ffi`, `zanshin-mcp`) never see it.

## The "no `jj_lib` types in public positions" rule

The public API is **fully `jj_lib`-type-free**:

- No `jj_lib::*` (and no `gix::*`) type appears in any public signature, struct
  field, or error variant.
- Every `jj_lib` failure is flattened to an opaque `Backend(String)` or
  `JjLibError(String)` error variant before crossing the crate boundary.
- **`pub use jj_lib::…` is forbidden.** The `test-jj-adapter-hygiene` task in
  `Makefile.toml` mechanically rejects any such line in `src/`.

## Adding new functionality

To expose a new jj concept (a new "noun"):

1. Create `src/<noun>.rs`.
2. Import and use `jj_lib` internally — it is fine inside this crate.
3. Define **crate-owned** types (`pub struct`, `pub enum`) for inputs and
   outputs.  Do **not** expose any `jj_lib::*` type in a public position.
4. Map every `jj_lib` error to `Backend(String)` (or a named variant wrapping
   a `String`).
5. Re-export the new types from `lib.rs` with `pub use <noun>::{…}`.
6. **Never** add `pub use jj_lib::…` to `lib.rs`.

## Conversion modes

Two functions convert an existing Git repository into a jj workspace. Like every
creation (`Repo::init`, `Repo::clone`), they return a `CreationOutcome` — the
`Result<Repo, RepoError>` as `result`, plus the warnings the jj CLI prints on the
same flow and the conversion's snapshot report (Story 9.33):

### `convert_colocated` — in-place, colocated (FR-JJ-18a)

```rust
convert_colocated(path: &Path) -> CreationOutcome
```

Creates a jj workspace **inside** the existing Git repo: `.jj/` is added
alongside `.git/`, and the two share the same directory and the same object
store.  The Git CLI continues to work; jj leads on the snapshot schedule.
Deleting `.jj/` fully restores the plain Git repo.

Mirrors `jj git init --colocate` over an existing `.git/`.  **Bare repos are
not supported** (returns `NotAGitRepo`).

### `convert_import` — jj-native at a separate destination (FR-JJ-18b)

```rust
convert_import(git_repo_path: &Path, workspace_path: &Path) -> CreationOutcome
```

Creates a **separate**, non-colocated jj workspace at a **user-chosen
destination**.  The destination gets a `.jj/` and **no** `.git/`; jj leads
exclusively.  **Bare repos are supported.**

**⚠ This is NOT a clone.** The new workspace shares the source's Git object
store (`git_target` → `<source>/.git`).  The source repo must continue to
exist — moving or deleting it corrupts the jj workspace.  Use `Repo::clone`
if you need a self-contained copy of the objects.

Mirrors `jj git init --git-repo=<source> <destination>`.

#### In-place jj-native conversion is impossible in jj 0.42

`jj git init --no-colocate` over an existing `.git/` is a hard error in jj
0.42 — a genuinely non-colocated result always requires a **separate**
destination directory.  The two-parameter signature of `convert_import`
reflects this constraint; the destination is always caller-supplied (no
baked-in default).

## Graph stream (`Repo::walk_graph`)

```rust
repo.walk_graph(
    revset: &str,
    prioritize: &str,
    short_prefixes: &str,
    visit: impl FnMut(GraphNode) -> ControlFlow<()>,
) -> Result<ControlFlow<()>, RevsetError>
```

Streams the commit graph of `revset` — one `GraphNode { id: CommitId, parents:
Vec<GraphEdge { target, kind: Direct | Indirect | Missing }>, meta: CommitMeta }`
per commit, children before parents — in the order `jj log -r <revset>` prints it.
`meta` is the `jj log`-parity display metadata (ids + shortest-prefix lengths,
author, committer timestamp, bookmarks/tags/workspace markers, the
working-copy / immutable / conflict / empty / hidden / divergent / root flags and
the description's first line), extracted from the SAME head-resolved snapshot in
the same pass (Story 4.8), so a row's lanes and its content can never disagree.
`short_prefixes` scopes the shortest-prefix disambiguation; an EMPTY string
disables it (full-index lengths) — the CLI's `revsets.short-prefixes` toggle,
deliberately unlike `prioritize`. The pipeline is the
CLI's at v0.42.0: `TopoGroupedGraph::new(revset.stream_graph(), |id| id)` with
`prioritize_branch` for every commit of `prioritize ∩ revset` (the
`revsets.log-graph-prioritize` mechanics; the intersection happens as user
expressions before resolution). Both expressions are caller pass-throughs;
`DEFAULT_GRAPH_PRIORITIZE` (`"present(@)"`) exposes the CLI default as a
pre-fill, never applied silently. `"none()"` is the canonical "no
prioritization" value — an empty/blank `prioritize` is a `ParseError`, as the
CLI fails on an empty config value. The prioritized set (`prioritize ∩ revset`)
is materialized before streaming, so keep it small (`present(@)` is one commit;
`all()` would materialize every id).

The stream is lazy and re-derived from the head operation on every call
(ADR-0002 — no cache, nothing retained); `visit` returning `ControlFlow::Break`
stops it early (`Ok(Break)`), exhaustion yields `Ok(Continue)`. Parse /
resolution / jj-lib failures of either expression surface as `RevsetError`.
Aliases are resolved from the repo's effective jj config, builtin defaults
included (Story 4.9): `config.rs` rebuilds the CLI's layer stack per operation —
Zanshin's builtin default layer, the system config, the `EnvBase` layer, the user
config (`JJ_CONFIG` or platform discovery), the repo layer, the workspace layer
and the `EnvOverrides` layer — and every parse site feeds from it. Since Story
9.27 the same stack is what `Repo` opens the workspace with (commit author,
operation user/host, working-copy knobs), re-derived before every mutation when
it changed. So `DEFAULT_LOG_REVSET` (the CLI's `revsets.log` default and the
pre-fill for `revset` / `short_prefixes`) parses out of the box, while a user's
`[revset-aliases]` override of `trunk()` or `immutable_heads()`, or a
brand-new `wip()`, resolves exactly as it does in their CLI. `Repo::log_defaults()`
returns the four *effective* `jj log` defaults for the UI to pre-fill.
`zanshin-graph`'s `stream_lanes` feeds this stream through its lane assigner.

## Graph topology + op-pinned content (`Repo::graph_topology`, `Repo::commit_contents`)

Story 4.10 splits `jj log` along "index/View-derived" vs "object-derived", for a
view that lays out the WHOLE revset before its first frame and loads card content
per visible page:

```rust
repo.graph_topology(revset, prioritize, short_prefixes, anchors: &[String], with_timestamps: bool)
    -> Result<GraphTopology, RevsetError>
repo.commit_contents(&operation_id, &commit_ids) -> Result<Vec<CommitContent>, CommitContentError>
```

- **`graph_topology`** runs `walk_graph`'s parse → `load_at_head` → `TopoGroupedGraph` +
  `prioritize_branch` pipeline (the setup is one shared helper) and the pre-verb
  precondition exactly once, but reads nothing per node that needs the commit object:
  each `TopologyNode` carries its commit id, jj's edges verbatim (Direct / Indirect /
  Missing in stream order, repeated targets kept, targets resolved to node indices, a
  Missing edge without target) and `TopologyMeta` — the view half of `CommitMeta` plus an
  exact `parent_count` from index-only `ParentCount` filter passes. The change ids come
  from one `commit_change_ids` pass. The result also carries `all_count` (`|all()|`,
  counted by iterating — never `count_estimate`), per anchor the node indices it selects,
  and the `operation_id` the call loaded. `with_timestamps` loads each non-root commit for
  its committer timestamp (epoch ms) — the one per-node load, per call, never cached.
- **`commit_contents`** (`&self`) is the continuation of that `jj log` — its per-row
  commit load — pinned to the returned operation (`load_operation` + `load_at`, never
  `load_at_head`): no precondition, no config load, no operation or op head written.
  `CommitContent` is the object half (author, committer timestamp, FULL description,
  conflict, empty), one entry per id in request order. Ids are full hex only; the error
  ladder is bad id → `InvalidInput`, vanished operation → `OperationNotFound`, id not in
  the pinned index → `CommitNotFound`, load failure → `Backend`.

`TopologyMeta` plus the matching `CommitContent` recompose `walk_graph`'s `CommitMeta`
exactly; `walk_graph` itself is unchanged.

## Integration-test fixture pattern

Integration tests that need a real jj repository use the pre-built fixtures:

```rust
use test_helpers::extract_fixture;

let handle = extract_fixture("tiny-3-commits");  // FixtureHandle, auto-deleted on drop
let path = handle.path();
let repo = zanshin_jj::Repo::open(path).unwrap();
```

The fixtures live in `test-fixtures/repos/` as `.tar.zst` archives and are
**never** regenerated at test time (see `cargo xtask gen-fixture` for
deliberate regeneration).
