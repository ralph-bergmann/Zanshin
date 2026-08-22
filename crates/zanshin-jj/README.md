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

Two functions convert an existing Git repository into a jj workspace:

### `convert_colocated` — in-place, colocated (FR-JJ-18a)

```rust
convert_colocated(path: &Path) -> Result<Repo, RepoError>
```

Creates a jj workspace **inside** the existing Git repo: `.jj/` is added
alongside `.git/`, and the two share the same directory and the same object
store.  The Git CLI continues to work; jj leads on the snapshot schedule.
Deleting `.jj/` fully restores the plain Git repo.

Mirrors `jj git init --colocate` over an existing `.git/`.  **Bare repos are
not supported** (returns `NotAGitRepo`).

### `convert_import` — jj-native at a separate destination (FR-JJ-18b)

```rust
convert_import(git_repo_path: &Path, workspace_path: &Path) -> Result<Repo, RepoError>
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
repo.walk_graph(revset: &str, prioritize: &str, visit: impl FnMut(GraphNode) -> ControlFlow<()>)
    -> Result<ControlFlow<()>, RevsetError>
```

Streams the commit graph of `revset` — one `GraphNode { id: CommitId, parents:
Vec<GraphEdge { target, kind: Direct | Indirect | Missing }> }` per commit, children
before parents — in the order `jj log -r <revset>` prints it. The pipeline is the
CLI's at v0.42.0: `TopoGroupedGraph::new(revset.stream_graph(), |id| id)` with
`prioritize_branch` for every commit of `prioritize ∩ revset` (the
`revsets.log-graph-prioritize` mechanics; the intersection happens as user
expressions before resolution). Both expressions are caller pass-throughs;
`DEFAULT_GRAPH_PRIORITIZE` (`"present(@)"`) exposes the CLI default as a
pre-fill, never applied silently.

The stream is lazy and re-derived from the head operation on every call
(ADR-0002 — no cache, nothing retained); `visit` returning `ControlFlow::Break`
stops it early (`Ok(Break)`), exhaustion yields `Ok(Continue)`. Parse /
resolution / jj-lib failures of either expression surface as `RevsetError`.
Only the `trunk()` alias is defined — other CLI aliases (`immutable_heads()`,
…) fail to parse. `zanshin-graph`'s `stream_lanes` feeds this stream through
its lane assigner.

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
