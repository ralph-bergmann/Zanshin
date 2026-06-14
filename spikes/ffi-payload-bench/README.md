# FFI payload spike: JSON vs FlatBuffers

A throwaway, **detached** spike (not part of the Zanshin workspace) answering one
question: for the complex data that crosses the Rust ↔ Dart FFI boundary, how
does the current JSON transport (AD-1) compare to FlatBuffers on
**serialize time (Rust)**, **wire size**, and **parse/access time (Dart)**?

The comparison uses synthetic, deterministically-seeded data shaped like real
payloads — the result depends on data *shape + size*, not on the data's origin,
so it transfers to the real jj-lib-sourced payloads.

## Layout

```
schema/payload.fbs   single source of truth for both code generators
rust/                producer side: serde_json + FlatBuffers builders
  benches/serialize.rs   criterion: serialize time + wire size
  src/bin/gen_artifacts.rs writes JSON+FB buffers + manifest.json to ../artifacts
dart/                consumer side: jsonDecode vs FlatBuffers zero-copy read
  bin/bench.dart
artifacts/           generated data (gitignored)
```

Two payloads are modeled: **GraphSlice** (int-heavy nodes + a couple of
variable-length id strings + a small parent-index array) and **Diff**
(deeply nested + string-heavy: files → hunks → lines).

## Prerequisites

`flatc` (official FlatBuffers compiler) on PATH — `brew install flatbuffers`.
Versions must agree: Rust `flatbuffers` crate, Dart `flat_buffers` package, and
the installed `flatc` are all on the 25.x line.

## Run

```sh
# Rust: serialize timing + wire sizes, and write artifacts for Dart
cargo bench   --manifest-path rust/Cargo.toml --bench serialize -- --measurement-time 3 --warm-up-time 1
cargo run --release --manifest-path rust/Cargo.toml --bin gen_artifacts

# Dart: parse/access timing (codegen first if schema changed)
flatc --dart -o dart/lib schema/payload.fbs
dart pub get -C dart
dart run dart/bin/bench.dart artifacts
```

## Results (2026-06-15, Apple M4 Pro, macOS 26.5.1, release build)

### Rust — serialize time + wire size

| Payload    | JSON time | FB time | FB faster | JSON size | FB size | FB smaller |
|------------|-----------|---------|-----------|-----------|---------|------------|
| graph 1k   | 130 µs    | 82 µs   | 1.6×      | 240 KB    | 175 KB  | 27 %       |
| graph 10k  | 1.42 ms   | 0.82 ms | 1.7×      | 2.43 MB   | 1.75 MB | 28 %       |
| graph 50k  | 7.68 ms   | 6.07 ms | 1.3×      | 12.2 MB   | 8.75 MB | 28 %       |
| diff 50    | 159 µs    | 111 µs  | 1.4×      | 264 KB    | 185 KB  | 30 %       |
| diff 500   | 1.70 ms   | 1.14 ms | 1.5×      | 2.65 MB   | 1.86 MB | 30 %       |
| diff 2000  | 8.14 ms   | 5.46 ms | 1.5×      | 10.7 MB   | 7.49 MB | 30 %       |

### Dart — parse/access time (median)

| Case                       | JSON     | FlatBuffers | FB speedup |
|----------------------------|----------|-------------|------------|
| graph 1k  consume-all      | 766 µs   | 129 µs      | 5.9×       |
| graph 1k  consume-subset   | 716 µs   | 9 µs        | 80×        |
| graph 10k consume-all      | 8.34 ms  | 1.54 ms     | 5.4×       |
| graph 10k consume-subset   | 8.04 ms  | 104 µs      | 77×        |
| graph 50k consume-all      | 51.4 ms  | 8.67 ms     | 5.9×       |
| graph 50k consume-subset   | 52.1 ms  | 623 µs      | 84×        |
| diff 2000 consume-all      | 60.4 ms  | 6.72 ms     | 9.0×       |
| diff 2000 consume-subset   | 56.5 ms  | 44 µs       | 1283×      |

- **consume-all** materializes every field including strings.
- **consume-subset** reads one scalar field per element — JSON must still parse
  the whole buffer; FlatBuffers skips to the field (zero-copy).
- The JSON consumer reads into untyped `Map`/`List` (no typed-class mapping), so
  these JSON numbers are a *lower bound* — real json_serializable mapping is more.

## Caveats

- This measures serialize (Rust) and parse/access (Dart) only. It does **not**
  measure the end-to-end FFI round-trip through the worker isolate (Tier 2).
- It does not establish what fraction of total latency serialization is vs. the
  jj-lib computation — that needs a real graph/diff path (not built yet).
