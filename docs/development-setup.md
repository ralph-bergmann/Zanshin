# Development Setup

## Prerequisites

### Rust toolchain

Pinned via `rust-toolchain.toml` — `rustup` installs it automatically on first use.

### Flutter / Dart

Zanshin requires the **Flutter `main` channel** (≥ 3.44.0-1.0.pre-573) for multi-window
support. Stable-channel pins are not viable until multi-window lands on stable; revisit then.

```sh
flutter channel main
flutter upgrade
```

### FlatBuffers compiler (`flatc`)

The FlatBuffers compiler generates the Rust and Dart wire-type accessors from
`schemas/*.fbs`.  The compiler, the Rust crate, and the Dart package **must all be on the
same version line** — currently **25.x**:

| Component | Version | Pin |
|-----------|---------|-----|
| `flatc` (compiler, system install) | `25.12.19` | exact |
| `flatbuffers` (Rust crate, `Cargo.toml`) | `=25.12.19` | exact |
| `flat_buffers` (Dart package, `pubspec.yaml`) | `^25.9.23` | caret (25.x) |

Install via Homebrew:

```sh
brew install flatbuffers
flatc --version   # must print 25.12.19
```

> **Note:** The generated accessors (`envelope_generated.rs`,
> `envelope_zanshin.ffi_generated.dart`, …) are **committed** to the repo — the
> build never regenerates them.  To update them after a schema change, run:
>
> ```sh
> cargo make codegen
> ```
>
> and commit both the schema diff and the regenerated accessors in the same PR.
> Moving to a new `flatc` version requires bumping all three pins atomically.

### `cbindgen` and `ffigen`

These are required by `cargo make codegen` to regenerate the C header
(`crates/zanshin-ffi/include/zanshin_ffi.h`) and the Dart FFI bindings
(`app/lib/src/ffi/bindings.dart`).

```sh
cargo install cbindgen
dart pub global activate ffigen
```

### `cargo-make`

```sh
cargo install cargo-make
```

## Build & test

```sh
cargo make build   # Rust workspace (release) + Flutter macOS
cargo make test    # full quality gate
cargo make codegen # regenerate C header, Dart bindings, and FlatBuffers accessors (manual, commit result)
```
