# FFI wire-contract fixtures

Committed FlatBuffers buffers used to validate the Rust/`flatc` ↔ Dart wire
contract from the Dart side (see `app/test/ffi/envelope_fixture_test.dart`).

Each `*.bin` is produced by `flatc --binary` from a human-readable `*.json`
source against `schemas/envelope.fbs`. `flatc` is the same compiler that
generates the Rust and Dart accessors, so the binary is the canonical wire
shape — independent of Dart's own builder.

Fixtures are **committed** and never rebuilt at test time. Regenerate
deliberately after an `envelope.fbs` change:

```sh
flatc --binary -o test-fixtures/ffi schemas/envelope.fbs \
    test-fixtures/ffi/envelope_error.json
```

| Source (`.json`) | Binary (`.bin`) | Shape |
|------------------|-----------------|-------|
| `envelope_error.json` | `envelope_error.bin` | `ok=false`, `error{code, context}`, no payload |
