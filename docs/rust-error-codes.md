# Rust Error Code Registry

AR-P-4 canonical registry for all `error.code` strings emitted across the Zanshin Rust workspace.

---

## Convention

Error codes follow the dotted `<domain>.<reason>` format, e.g. `jj.repo_not_found`.

**Rules:**

- **User data goes in `context`, never in `code`.** The `code` is a stable machine-readable key; human-readable detail (paths, messages) belongs in the `FfiError.context` field.
- **Reasons never change after release.** Once a code ships in a released version, its string is frozen. Add new codes rather than renaming existing ones.
- **All codes are emitted from `crates/zanshin-ffi/src/envelope.rs`.** Domain crates (`zanshin-jj`, etc.) translate their errors into `FfiErrorObj`; `envelope.rs` serialises them. No `error.code` string may appear outside `envelope.rs` (AR-P-4, `architecture.md:641`).

---

## Domain List

| Domain     | Crate / subsystem                  |
|------------|------------------------------------|
| `internal` | `zanshin-ffi` — infrastructure-level panics and serialisation failures |
| `ffi`      | `zanshin-ffi` — FFI contract violations (null pointers, invalid handles, UTF-8) |
| `jj`       | `zanshin-jj` — jj-lib operation errors |
| `diff`     | `zanshin-diff` — diff computation errors |
| `graph`    | `zanshin-graph` — DAG lane-assignment errors |
| `watcher`  | `zanshin-ffi` watcher subsystem — filesystem-watch errors |
| `mcp`      | `zanshin-mcp` — MCP server errors |

---

## Code Table

| Code                            | Domain     | Meaning                                                              | Status                              |
|---------------------------------|------------|----------------------------------------------------------------------|-------------------------------------|
| `internal.panic`                | `internal` | A Rust panic was caught by `envelope::catch`; message in `context`. | **Emitted — Story 3.1** (`envelope.rs::INTERNAL_PANIC`) |
| `internal.serialization_failed` | `internal` | JSON serialisation failure (pre-FlatBuffers era).                    | **Reserved / legacy** — FlatBuffers in-memory builder does not fail the way `serde_json::to_string` did; this code is documented for completeness but is not currently emitted. Do not invent a synthetic failure path to use it. |
| `ffi.invalid_handle`            | `ffi`      | A repo/object handle value is not in the live handle table.          | **Emitted — Story 3.2** (`envelope.rs::FFI_INVALID_HANDLE`) |
| `ffi.null_pointer`              | `ffi`      | A required pointer argument was null.                                | **Emitted — Story 3.2** (`envelope.rs::FFI_NULL_POINTER`) |
| `ffi.utf8_error`                | `ffi`      | A `*const c_char` argument contained invalid UTF-8.                 | **Emitted — Story 3.2** (`envelope.rs::FFI_UTF8_ERROR`) |
| `jj.repo_not_found`             | `jj`       | No jj repo found at or above the given path.                         | **Emitted — Story 3.4a** (`envelope.rs::JJ_REPO_NOT_FOUND`, `repo.rs`) |
| `jj.path_not_found`             | `jj`       | A path argument does not exist on disk.                              | **Emitted — Story 3.4a** (`envelope.rs::JJ_PATH_NOT_FOUND`, `repo.rs`) |
| `jj.jj_lib_error`               | `jj`       | An unclassified error from jj-lib; detail in `context`.             | **Emitted — Story 3.4a** (`envelope.rs::JJ_JJ_LIB_ERROR`, `repo.rs`) |
| `ffi.invalid_argument`          | `ffi`      | A required argument value is out of the accepted range.              | **Emitted — Story 3.4a** (`envelope.rs::FFI_INVALID_ARGUMENT`, `repo.rs`) |
| `jj.no_working_copy`            | `jj`       | The workspace has no working-copy commit (@).                        | **Emitted — Story 3.4b** (`envelope.rs::JJ_NO_WORKING_COPY`, `status.rs`) |
| `watcher.io_error`              | `watcher`  | An I/O error in the filesystem-watch subsystem.                      | Reserved — deferred watcher stories |
| `watcher.watchman_not_configured` | `watcher` | Watchman is not installed or not on `$PATH`.                        | Reserved — deferred watcher stories |

---

## Adding a New Code

1. Choose a `<domain>.<reason>` that is lowercase, dotted, and human-readable.
2. Add a `pub const` for it in `crates/zanshin-ffi/src/envelope.rs` (single-emission-point rule).
3. Add a row to this table with domain, meaning, and the story that introduces it.
4. Update the story file to reference this registry.
