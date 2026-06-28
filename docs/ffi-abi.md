# FFI ABI Reference

Low-level contract between the Dart layer (`packages/zanshin_core`) and the
compiled Rust cdylib (`zanshin_ffi`). Implementors of new FFI wrappers must
read this document together with `ADR-0001` (FlatBuffers envelope transport)
and `docs/rust-error-codes.md`.

---

## Token contract

Every **fallible composite** `extern "C"` function returns a `*mut ZanshinBuf`
**token** — never null.

| Step | Actor                                     | Action                                                    |
|------|-------------------------------------------|-----------------------------------------------------------|
| Rust | writes heap bytes into `ZanshinBuf`       | returns the pointer as a token                            |
| Dart | calls `FfiBuffer.fromToken(token)`        | reads `.bytes` (a `Uint8List` copy)                       |
| Dart | calls `buf.dispose()` / `NativeFinalizer` | Rust frees the allocation via `zanshin_buffer_free_token` |

The Dart copy is isolated from Rust memory; it is safe to send across isolate
ports and use after disposal.

**Infallible hot-path functions** (`zanshin_ffi_version`, `zanshin_string_free`,
`zanshin_buffer_free`, `zanshin_buffer_free_token`) return plain types — no
envelope.

---

## Envelope format

Every token carries a FlatBuffers `Envelope` root (schema: `schemas/envelope.fbs`):

```
Envelope {
  ok:        bool          // true = success; false = error
  error:     FfiError?     // non-null only when ok == false
  data_type: Payload       // union discriminant (NONE when ok == false)
  data:      Payload       // union value (absent when ok == false)
}
```

**Success:** `ok = true`, `data` holds the concrete payload variant.  
**Error:** `ok = false`, `error.code` holds the dotted AR-P-4 code, `error.context`
holds human-readable detail. See `docs/rust-error-codes.md` for the full registry.

---

## RepoKind enum

Used by `zanshin_repo_detect` and its `RepoDetect` payload.

| Variant        | Value | Meaning                                                |
|----------------|-------|--------------------------------------------------------|
| `Jj`           | 0     | Path is a jj workspace (`.jj/` present).               |
| `Git`          | 1     | Path is a plain Git repo (`.git/` present, no `.jj/`). |
| `Neither`      | 2     | Path exists but contains neither.                      |
| `PathNotFound` | 3     | Path does not exist on disk.                           |

Order must stay identical to `zanshin_jj::RepoKind` and `fbs::RepoKind`
(generated from `schemas/envelope.fbs`).

---

## Exported symbols (Story 3.4c)

### `zanshin_repo_detect`

```c
ZanshinBuf* zanshin_repo_detect(const char* path);
```

Classifies the repository kind at `path`.

**`Neither` and `PathNotFound` are success results**, not errors. Only a
genuine filesystem I/O failure (e.g. `EACCES`, `ENOTDIR`) yields an error
envelope.

When the result is `Neither` or `PathNotFound` and an enclosing jj or Git
repo is found by the consent-gated ancestor walk (FR-JJ-14), the payload
populates `suggested_root` and `suggested_kind`. The UI decides whether to
offer opening it — the backend never auto-opens.

The ancestor walk stops at the `$HOME` ceiling: a repo at or above `$HOME`
(e.g. a dotfiles repo at `~`) is intentionally **not** surfaced as a
suggestion, so `suggested_root` may be null even though an ancestor technically
contains a repo.

**Success payload:** `Envelope<RepoDetect>`

```
RepoDetect {
  kind:           RepoKind   // classification of path
  suggested_root: string?    // enclosing repo path, or null if no suggestion
  suggested_kind: RepoKind   // kind of the enclosing repo (only valid when
                             // suggested_root is non-null — D4 presence flag)
}
```

**Error codes:**

| Code               | Condition                                      |
|--------------------|------------------------------------------------|
| `jj.detect_failed` | Filesystem I/O error prevented classification. |
| `ffi.null_pointer` | `path` is null.                                |
| `ffi.utf8_error`   | `path` contains invalid UTF-8.                 |

---

### `zanshin_repo_convert`

```c
ZanshinBuf* zanshin_repo_convert(const char* path);
```

Converts the Git repository at `path` to a colocated jj workspace in-place
by calling `convert_colocated` (`zanshin_jj`). The operation writes only
`.jj/` — no working-copy I/O, no `@`-reparent, no snapshot.

On success the function returns a live `RepoHandle` for the converted
workspace. The Dart worker stores the raw handle in its Model-A handle table
(`handleId → raw *mut Repo`) and returns an opaque `handleId` to the caller.

**Success payload:** `Envelope<RepoHandle>`

```
RepoHandle {
  handle: uint64   // raw *mut Repo reinterpreted as u64; opaque to Dart
}
```

**Error codes:**

| Code                 | Condition                                              |
|----------------------|--------------------------------------------------------|
| `jj.already_jj_repo` | `.jj/` already exists at `path`.                       |
| `jj.not_a_git_repo`  | No `.git/` at `path` (or path does not exist).         |
| `jj.convert_failed`  | jj-lib failure during conversion; detail in `context`. |
| `ffi.null_pointer`   | `path` is null.                                        |
| `ffi.utf8_error`     | `path` contains invalid UTF-8.                         |

---

## Dart worker integration

Both functions are **handle-free** (path-in only). The Dart worker dispatches
them directly without a handle-table lookup:

```dart
case DetectRepoCommand(:final String path):
  final bytes = repo_ffi.zanshinRepoDetect(path);
  responseSP.send((commandId, BufferResult(bytes)));

case ConvertRepoCommand(:final String path):
  final bytes = repo_ffi.zanshinRepoConvert(path);
  _replyRepoOp(bytes, ...);  // stores handle on success, replies HandleResult
```

Public `ZanshinWorker` API:

- `Future<RepoDetectResult> detect(String path)` — decodes via `decodeRepoDetectEnvelopeInternal`
- `Future<RepoHandle> convert(String path)` — stores handle, returns `RepoHandle`
