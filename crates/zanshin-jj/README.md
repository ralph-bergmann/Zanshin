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
