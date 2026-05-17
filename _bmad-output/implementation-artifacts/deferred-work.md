# Deferred Work

_Items raised during code reviews that are real but intentionally not actioned now. Each entry links back to the originating review and includes a one-line reason for deferral._

## Deferred from: code review of 1-1-initialize-cargo-workspace-and-create-empty-crate-skeletons (2026-05-17)

- **No `NOTICE` file alongside Apache-2.0 `LICENSE`** [`LICENSE`] — release phase; no downstream redistributors during WIP.
- **No `[workspace.lints]` table for central lint enforcement** [`Cargo.toml`] — owned by Story 1.7 (lint/format config).
- **No `[profile.release]` / `[profile.dev]` customization (LTO, codegen-units, strip)** [`Cargo.toml`] — release-phase optimization.
- **`xtask` not excluded from default-members** [`Cargo.toml:3-5`] — `cargo build --workspace --release` builds xtask unnecessarily; ergonomic; revisit when Story 1.4/1.9 wires CI.
