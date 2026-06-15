# FFI Wire Schemas

`.fbs` files in this directory are the **wire-contract source of truth** for the
Rust ↔ Dart FFI boundary (ADR-0001).

## Rules

- **Breaking changes in WIP:** edit the `.fbs` in place, regenerate both sides
  (`cargo make codegen`), and update all callers in the same PR.  No `_v2` suffix,
  no in-wire `schema_version` field.  Post-1.0 versioning is deferred.
- **Generated accessors are committed.** Running `cargo make codegen` writes
  `envelope_generated.rs` → `crates/zanshin-ffi/src/` and
  `envelope_zanshin.ffi_generated.dart` → `app/lib/src/ffi/`.  The build never auto-regenerates
  them — a PR that changes a `.fbs` MUST include both the schema diff and the
  regenerated accessor diffs.  These `flatc` outputs carry the compiler's own
  banner and are **exempt** from the SPDX-first-line rule (see
  `_bmad-output/project-context.md` § Documentation).
- **`flatc` version must match the crate and package.** See
  `docs/development-setup.md` for the pinned versions and the install command.

## Schema registry

| File | Domain | Status |
|------|--------|--------|
| `envelope.fbs` | FFI envelope + error (core) | active |

Noun-specific schemas (`graph.fbs`, `diff.fbs`, `change.fbs`, …) are added as the
corresponding Epic 2 / Epic 4–6 stories land.
