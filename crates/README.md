# Zanshin Rust Workspace — Crates

This directory contains all six Rust crates that make up the Zanshin backend.

## Crate Overview

| Crate | Type | Purpose |
|---|---|---|
| `zanshin-jj` | lib | Anti-corruption layer over `jj-lib` (Epic 2) |
| `zanshin-diff` | lib | Word-level diff + syntax highlight (Epic 5) |
| `zanshin-graph` | lib | DAG lane assignment (Epic 4) |
| `zanshin-ffi` | cdylib | FFI boundary exposed to Dart via `libzanshin_ffi.dylib` (Epic 3) |
| `zanshin-mcp` | bin | MCP server binary (Epic 7) |
| `xtask` | bin | Build helper tasks invoked via `cargo xtask` (Story 1.4+) |

## `Cargo.toml` Hygiene Convention (AR-P-8)

### Workspace-version single source of truth (AR-AD-7)

All version metadata is declared once in the root `[workspace.package]` block and
inherited by every member crate via `version.workspace = true`, `edition.workspace = true`,
`license.workspace = true`, `authors.workspace = true`, `repository.workspace = true`.

**Never** add a standalone `version = "..."` line inside a member crate's `[package]`
block — it defeats the single-source guarantee and causes drift.

### Version-pinning rules

- **Load-bearing pre-1.0 deps** (`jj-lib`, `rmcp`, `imara-diff`): use exact pins `=x.y.z`.
  These crates make breaking changes between minor versions; absorbing upgrades is
  an explicit, reviewed decision — not a silent `cargo update`.
- **Stable deps** (1.0+): caret pins (`^x.y.z` or bare `x.y.z`), matching standard
  Cargo semver semantics.
- Shared workspace deps are declared in root `[workspace.dependencies]` and consumed
  in member crates as `serde = { workspace = true }` (no version repetition).

### `default-features = false` comment requirement

Any `default-features = false` entry **must** have an inline `# WHY:` comment
explaining what feature-set was dropped and why it matters:

```toml
# Good — inline `# WHY:` makes the omission auditable
serde = { workspace = true, default-features = false, features = ["derive"] }  # WHY: drop serde's std feature for no_std test builds

# Bad — reviewer cannot judge whether the omission is intentional
serde = { workspace = true, default-features = false, features = ["derive"] }
```

### No `[patch.crates-io]` in 0.x

While the project is pre-1.0, `[patch.crates-io]` is prohibited. If a fork is
required, file an issue documenting the expected drop date and link the issue from
the patch entry. See `project-context.md` for the full rationale.

## macOS APFS case-insensitivity

macOS APFS is case-insensitive by default. Every crate directory under `crates/`
must be case-unique against every other crate directory — `zanshin-ffi` and
`zanshin-FFI` collide silently at build time. Always lowercase, hyphen-separated.
The same constraint applies to `[lib] name = "..."` and any cdylib artefact name.

## Rust Toolchain

Rust is pinned to `1.95.0` via the workspace-root `rust-toolchain.toml`. `rustup`
auto-applies it on every `cargo` invocation from anywhere in the repo. See the root
`README.md` § Toolchain for install + bump policy.
