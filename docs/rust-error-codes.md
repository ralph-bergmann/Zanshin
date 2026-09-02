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
| `jj.jj_lib_error`               | `jj`       | An unclassified error from jj-lib; detail in `context`.             | **Emitted — Story 3.4a** (`envelope.rs::JJ_JJ_LIB_ERROR`, `repo.rs`; also emitted by the other `zanshin_*` read wrappers and `graph.rs` (Story 4.6)) |
| `ffi.invalid_argument`          | `ffi`      | A required argument value is out of the accepted range.              | **Emitted — Story 3.4a** (`envelope.rs::FFI_INVALID_ARGUMENT`, `repo.rs`) |
| `jj.no_working_copy`            | `jj`       | The workspace has no working-copy commit (@).                        | **Emitted — Story 3.4b** (`envelope.rs::JJ_NO_WORKING_COPY`, `status.rs`) |
| `jj.change_not_found`           | `jj`       | No change found for the given id.                                    | **Emitted — Story 3.4b (change)** (`envelope.rs::JJ_CHANGE_NOT_FOUND`, `change.rs`); also emitted — Story 6.5 (`repo.rs::map_mutate_err`) by `zanshin_describe`/`zanshin_new_change`/`zanshin_edit`/`zanshin_abandon` |
| `jj.already_jj_repo`            | `jj`       | The path is already a jj workspace (`.jj/` present); convert skipped. | **Emitted — Story 3.4c** (`envelope.rs::JJ_ALREADY_JJ_REPO`, `repo.rs`); also produced by `convert_import` (Story 2.13) for both source and destination; `convert_import` FFI ships in the 0.2 fast-follow |
| `jj.not_a_git_repo`             | `jj`       | The path is not a Git repository (no `.git/`) or does not exist.     | **Emitted — Story 3.4c** (`envelope.rs::JJ_NOT_A_GIT_REPO`, `repo.rs`); also produced by `convert_import` (Story 2.13) when the source is not a Git repo (normal or bare); `convert_import` FFI ships in the 0.2 fast-follow |
| `jj.convert_failed`             | `jj`       | A jj-lib failure occurred during conversion; detail in `context`.    | **Emitted — Story 3.4c** (`envelope.rs::JJ_CONVERT_FAILED`, `repo.rs`) for `convert_colocated`; also produced by `convert_import` (Story 2.13); `convert_import` FFI ships in the 0.2 fast-follow |
| `jj.detect_failed`              | `jj`       | A filesystem I/O error (permission denied, a non-directory path component, …) prevented repo-kind classification. | **Emitted — Story 3.4c** (`envelope.rs::JJ_DETECT_FAILED`, `repo.rs`) |
| `watcher.io_error`              | `watcher`  | The filesystem watcher could not be armed while opening/initialising/cloning/converting a repo; detail in `context`. | **Emitted — Story 3.6** (`envelope.rs::WATCHER_IO_ERROR`, `repo.rs::map_watcher_err`). Single-emission-point: this code is returned ONLY by the arming-failure error envelope at `zanshin_repo_open`/`_init`/`_clone`/`_convert`. Post-arm watch errors never reuse it — they ride the async event stream as `WatcherEvent { kind: WatchError, message }` (no code string). |
| `watcher.watchman_not_configured` | `watcher` | Watchman is not installed or not on `$PATH`.                        | Reserved — deferred watcher stories |
| `jj.revset_parse_error`         | `jj`       | A revset expression (`revset`, `prioritize`, or — since Story 4.8 — `short_prefixes`) is syntactically invalid or names an unknown function; jj-lib's reason in `context`. | **Emitted — Story 4.6** (`envelope.rs::JJ_REVSET_PARSE_ERROR`, `graph.rs::map_lane_stream_err`) for `zanshin_graph_slice`; reusable by the Epic 9 `eval_revset` read joker (same `RevsetError::ParseError` source). Note: an EMPTY `short_prefixes` is not an error — it disables prefix disambiguation (CLI parity), unlike a blank `prioritize`. A PARSE failure is the ONLY `short_prefixes` failure that surfaces as an error code. |
| `jj.revset_resolution_error`    | `jj`       | A revset expression (`revset`, `prioritize`, or — since Story 4.8 — `short_prefixes`) is well-formed but a symbol cannot be resolved (unknown bookmark/tag, missing `@`, ambiguous id); reason in `context`. | **Emitted — Story 4.6** (`envelope.rs::JJ_REVSET_RESOLUTION_ERROR`, `graph.rs::map_lane_stream_err`) for `zanshin_graph_slice`; reusable by the Epic 9 `eval_revset` read joker (`RevsetError::ResolutionError`). Note: `short_prefixes` NEVER yields this code. Its symbols are resolved while LOADING the disambiguation index, and any load failure — an unknown bookmark/tag included — only warns and degrades to full-index prefixes (CLI parity, pinned by jj's `cli/tests/test_log_command.rs::test_log_bad_short_prefixes` @ v0.42.0). |
| `jj.config_error`               | `jj`       | The repo's effective jj config could not be read: a config file is unreadable or not valid TOML, a `config-id` is not exactly 20 ASCII hex characters, or a config value has the wrong type (`revsets.log` not a string, `ui.log-synthetic-elided-nodes` not a bool). The offending file path or config key is in `context`. | **Emitted — Story 4.9** (`envelope.rs::JJ_CONFIG_ERROR`, `log_defaults.rs::map_config_err` for `zanshin_log_defaults`, `graph.rs::map_lane_stream_err` for `zanshin_graph_slice`). Also emitted when a config layer's `revset-aliases` key is not a table (CLI parity — `cli/src/config.rs:943-953` returns `ConfigGetError::Type` for the TABLE level). Never a silent fall-back to the builtin defaults. NOT emitted for a single bad `[revset-aliases]` ENTRY: a non-string value or a declaration jj-lib's parser rejects only logs a `tracing::warn!` and is skipped, and the call succeeds (`cli/src/config.rs:964-977`). A malformed alias DEFINITION surfaces later still, as `jj.revset_parse_error`, and only where the alias is used. |
| `graph.dangling_edge`           | `graph`    | The exhausted revset graph stream left a dangling non-`Missing` edge — an upstream-stream contract violation (`zanshin_graph::GraphError::DanglingEdge`); the dangling target id in `context`. | **Emitted — Story 4.6** (`envelope.rs::GRAPH_DANGLING_EDGE`, `graph.rs::map_lane_stream_err`). First `graph.*` code. Unreachable with real jj-lib streams (pinned by the inline mapper unit test only). |
| `jj.invalid_input`              | `jj`       | The caller's arguments are structurally invalid for a mutation (e.g. an empty `parents` list for `new_change`, an empty `change_ids` list for `abandon`, a target that resolves to the root commit for `new_change`/`abandon`/`describe`, or — for `undo` — the head operation having more than one parent, a divergent-write merge op); reason in `context`. | **Emitted — Story 6.5** (`envelope.rs::JJ_INVALID_INPUT`, `repo.rs::map_mutate_err`) for `zanshin_new_change`/`zanshin_abandon`/`zanshin_describe`/`zanshin_undo`; source is `zanshin_jj::MutateError::InvalidInput` (Story 6.1/6.2). |
| `jj.immutable`                  | `jj`       | The target of a rewriting mutation lies inside the repo's EFFECTIVE immutable set, `::(immutable_heads() \| root())` — jj refuses to rewrite it. The hex commit id of the FIRST offending target is in `context` (the CLI names one offender too); more targets may also be immutable. No operation is committed. | **Emitted — Story 9.1** (`envelope.rs::JJ_IMMUTABLE`, `repo.rs::map_mutate_err`) for `zanshin_describe`/`zanshin_edit`/`zanshin_abandon`; source is `zanshin_jj::MutateError::Immutable`, raised by `op_support::check_rewritable` (CLI parity with `cli_util.rs:2011` `check_rewritable_expr` @ v0.44.0). The set comes from the repo's effective config, so a user's `revset-aliases."immutable_heads()"` decides it. The ROOT commit does NOT use this code for `describe`/`abandon`: their explicit root guards run first and keep refusing it as `jj.invalid_input` (both refuse and neither writes an op-log entry, so the observable behaviour matches the CLI). `zanshin_edit`, which has no such guard, does report root as `jj.immutable`. |
| `jj.nothing_to_undo`            | `jj`       | `zanshin_undo` was called with the head operation at the op-store root — there is no parent operation to restore to. | **Emitted — Story 6.5** (`envelope.rs::JJ_NOTHING_TO_UNDO`, `repo.rs::map_mutate_err`) for `zanshin_undo`; source is `zanshin_jj::MutateError::NothingToUndo` (Story 6.2). Not normally reachable through `Repo::init`/`open` alone — see `MutateError::NothingToUndo`'s own doc comment. |
| `jj.remote_not_found`           | `jj`       | `zanshin_git_fetch` was called with a remote name that has no configured git remote, or the repo has no git backend at all. | **Emitted — Story 6.5** (`envelope.rs::JJ_REMOTE_NOT_FOUND`, `repo.rs::map_mutate_err`) for `zanshin_git_fetch`; source is `zanshin_jj::MutateError::RemoteNotFound` (Story 6.4a). |
| `jj.network_error`              | `jj`       | `zanshin_git_fetch`'s underlying `git` subprocess failed — a network, authentication, or transport error; detail in `context`. No operation is committed. | **Emitted — Story 6.5** (`envelope.rs::JJ_NETWORK_ERROR`, `repo.rs::map_mutate_err`) for `zanshin_git_fetch`; source is `zanshin_jj::MutateError::NetworkError` (Story 6.4a). |

---

## Adding a New Code

1. Choose a `<domain>.<reason>` that is lowercase, dotted, and human-readable.
2. Add a `pub const` for it in `crates/zanshin-ffi/src/envelope.rs` (single-emission-point rule).
3. Add a row to this table with domain, meaning, and the story that introduces it.
4. Update the story file to reference this registry.
