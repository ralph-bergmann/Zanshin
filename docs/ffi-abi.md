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

**Infallible functions return plain types — no envelope.** There are eight:
`zanshin_ffi_version` (a `char *` the caller frees via `zanshin_string_free`) and
the seven `void`-returning ones — `zanshin_string_free`, `zanshin_buffer_free`,
`zanshin_buffer_free_token`, `zanshin_log`, `zanshin_logging_init`,
`zanshin_events_register`, `zanshin_events_unregister`.

The converse does **not** hold: returning an envelope does not make a function
fallible. `zanshin_diagnostics` returns a `ZanshinBuf *` token and is infallible
by contract (two compile-time constants plus one path resolution with a temp
fallback), so it carries no `# Errors` block and answers `ok == true` for every
input — the `internal.panic` backstop below is its only `ok == false` arm. It
is on the token path purely because its result is composite. "Infallible" in this
document means *has no `# Errors` block in `zanshin_ffi.h`* — nine of the 59
exported symbols, these eight plus `zanshin_diagnostics`.

`zanshin_buffer_free_token` frees **two** allocations: the payload the token
points at, and the token struct itself. It skips the payload when `ptr` is null
**or** `len == 0`, and always frees the token struct. So a caller that released
the payload through the synchronous `zanshin_buffer_free(ptr, len)` path can
still hand the token back for disposal by first zeroing `token.ptr` /
`token.len` — that is the only supported way to mix the two halves without a
double free, and it is what
`packages/zanshin_core/test/ffi/buffer_free_test.dart` does. Production Dart
never mixes them: `FfiBuffer` always uses the token path.

---

## Envelope format

Every token carries a FlatBuffers `Envelope` root (schema: `schemas/envelope.fbs`):

```
Envelope {
  ok:           bool           // true = success; false = error
  error:        FfiError?      // non-null only when ok == false
  data_type:    Payload        // union discriminant (NONE when ok == false)
  data:         Payload        // union value (absent when ok == false)
  precondition: Precondition?  // the pre-verb snapshot's report (Story 9.26), ok OR error
  warnings:     [Warning]?     // the call's CLI warnings (Story 9.32), ok OR error
}

Warning { code: string; message: string; }
```

**Success:** `ok = true`, `data` holds the concrete payload variant.  
**Error:** `ok = false`, `error.code` holds the dotted AR-P-4 code, `error.context`
holds human-readable detail. See `docs/rust-error-codes.md` for the full registry.

### `warnings` — the CLI's `Warning:` blocks as coded facts (Story 9.32)

Every envelope-returning symbol may carry `Envelope.warnings`: the jj CLI @ v0.44.0's
`ui.warning_*` output for the same call, one `Warning` per CLI block, in the CLI's print
order (config-load warnings, the pre-verb snapshot and imports, the verb body,
`finish_transaction`). `code` is one of the registered `jj.*` warning codes
(`docs/rust-error-codes.md` § Warning Codes); `message` is the CLI's text, verbatim,
without the `Warning: ` heading and without hints. A warning never changes the
outcome: it rides the ok envelope AND the error envelope (a precondition that warned
before the verb refused keeps its warnings next to the error). The vector is
**absent** when there is nothing to warn about — every reader treats that as an empty
list — and never appears on `PANIC_FALLBACK_ENVELOPE`, whose bytes are unchanged.
Success without a caveat is `ok` with no warnings; there is no success code and no
severity. Config-load warnings are recorded once per call. On the Dart side every
`ZanshinWorker` / `RepoHandle` command result exposes them as `warnings`
(`List<ZanshinWarning>`), decoded by one shared helper — except `openRepo` (opening
warns about nothing), `closeRepo` / `close` (lifecycle) and `events` (a stream, not a
command); a list result is a `WarnedList<E>`; payloads nested in another payload carry
none. The creations (Story 9.33) — `zanshin_repo_init` / `_clone` / `_convert` — carry the
creating call's warnings on the `RepoHandle` ok envelope AND on every error envelope
(including `watcher.io_error` after a successful creation); in Dart `initRepo`,
`cloneRepo` and `convert` return a `CreatedRepoHandle` (a `RepoHandle` subtype, so
existing callers compile unchanged) exposing them as `warnings`; a refused creation
throws `ZanshinFfiException` exposing them as its `warnings` (e.g.
`jj.clone_cleanup_failed`, which only an error envelope carries). `zanshin_repo_open`
carries none. On every error envelope — handle-scoped, handle-less or creation — Dart
reads the warnings the same way: the thrown `ZanshinFfiException.warnings` (Story 9.35).

### `precondition` — the pre-verb snapshot, whenever it ran (Story 9.26)

Like every jj CLI command, every handle-scoped symbol except `zanshin_repo_close`,
`zanshin_log_defaults` and `zanshin_workspace_root` first runs the CLI's
`snapshot_impl`: under jj's own `git_import_export.lock` (colocated workspaces
only) it imports a moved Git HEAD (`import git head`), snapshots the working copy
into `@` (`snapshot working copy`), and imports the Git refs (`import git refs`) —
each an operation only when it changed something. So a READ can write
operations, exactly as `jj log` does. `zanshin_snapshot` runs it alone (the CLI's
`jj util snapshot`).

Whenever the verb's pre-verb snapshot ran, the envelope — ok **and** error —
carries the report in `Envelope.precondition`: the facts the CLI prints before a command runs
(`was_snapshot_taken`, the snapshot's untracked paths, the head/refs import
outcome and rebased counts, and the ref export failures as `finish`). The pure
notes — `@` was immutable, `.jjconflict` files present, a failed Git HEAD reset —
are not fields: they are `Envelope.warnings` (Story 9.32). On an error it is PARTIAL — every field
up to the failing step. The field is **absent** on every other symbol (open,
init, clone, detect, close, `zanshin_log_defaults`,
`zanshin_workspace_root`, the infrastructure symbols, async events, and every
`zanshin_config_*` symbol but one) and whenever
the call was refused before the verb ran (`ffi.null_pointer`, `ffi.invalid_handle`,
a request buffer that fails validation). `zanshin_repo_convert` (Story 9.33) carries
the conversion's snapshot report — `jj git init`'s `maybe_snapshot` — iff that snapshot
started, on the ok and the error envelope (after a failure before the re-open it
describes state the rollback removed; a failed re-open or watcher arming leaves `.jj/`
in place); Dart exposes it as `CreatedRepoHandle.precondition`, never as
`lastPrecondition`, because a creation is not a verb on the handle — and a refused
conversion's as the thrown `ZanshinFfiException.precondition`. Every error envelope's
report reaches Dart that way (Story 9.35): the exception's `precondition` (`null` when
the envelope has none) — when a failed handle-scoped call's error envelope carries one,
the same report `RepoHandle.lastPrecondition` holds (one without a report leaves
`lastPrecondition` at the previous report while the exception's is `null`).
A failed pre-verb snapshot is `jj.stale_working_copy`, `jj.config_error` or
`jj.jj_lib_error`; every such symbol's row names all three.

`zanshin_config_set` (Story 9.28) is handle-less but runs the snapshot for
`user.name` / `user.email` with a workspace root — the CLI's `check_wc_author`,
whose failure it skips silently. Its envelope, ok or error, carries
`precondition` exactly when that snapshot ran — in Dart `ConfigSetResult.precondition`
on success, the thrown `ZanshinFfiException.precondition` on error (Story 9.35).

Every mutation whose CLI verb ends in `tx.finish` (all but `zanshin_file_track` /
`_untrack`, which the CLI commits through the locked working copy) likewise runs the
CLI's `finish_transaction`: in a
colocated workspace it resets Git HEAD to `@`'s parent and exports the refs, and
if `@` became immutable it creates a new `@` on top. The refs the export could not
write ride `MutationResult.finish` (absent when none failed); `@` becoming immutable,
a failed HEAD reset, the export failures themselves and an empty identity are
`Envelope.warnings` (Story 9.32).

`Payload` has **35** members. Two of them — `WatcherEvent` and `Progress` — are
returned by no exported symbol: they arrive asynchronously through the
`zanshin_events_register` callback (see *Async events* below). Union member order
is the wire discriminant, so the union is **append-only**.

### `internal.panic` — the universal backstop

Every fallible wrapper's body runs inside `envelope::catch`, a `catch_unwind`
that turns any Rust panic into an ordinary error envelope carrying
**`internal.panic`** with the panic message in `context`. Because it is universal
it is documented **only here**: it appears in no symbol's `# Errors` block and
therefore in no row of the symbol index below. Assume it for every symbol that
returns an envelope, including the otherwise-infallible `zanshin_diagnostics` —
that is the one way such a symbol can answer `ok == false`.

The backstop relies on the crate being built with `panic = "unwind"` (the
workspace default); under `panic = "abort"` `catch_unwind` cannot intercept at
all (`crates/zanshin-ffi/src/envelope.rs:499-502`).

**Coverage is not universal across the `void`-returning symbols.** Four of the
seven are wrapped and swallow a panic, having no channel to report on:
`zanshin_log` and `zanshin_logging_init` (`crates/zanshin-ffi/src/logging.rs`)
and `zanshin_events_register` / `_unregister`
(`crates/zanshin-ffi/src/events.rs`) — for `zanshin_log` deliberately, since
logging must never break its caller. The three deallocators —
`zanshin_string_free`, `zanshin_buffer_free`, `zanshin_buffer_free_token`
(`crates/zanshin-ffi/src/ffi_strings.rs`) — carry **no** `catch_unwind`, so a
panic in them would unwind across the C ABI. Their bodies are pointer-validity
checks plus a `drop`, which is why nothing was added; do not read the backstop as
a blanket guarantee that no panic ever crosses the boundary.

---

## Request-buffer contract

Twenty-seven of the 59 exported symbols take their arguments as a **FlatBuffers
request buffer** — the ADR-0001 composite-input pattern — rather than as C
strings. Eighteen use the handle-scoped three-parameter shape:

```c
ZanshinBuf* zanshin_<verb>(uint64_t handle, const uint8_t* data, uintptr_t len);
```

The nine `zanshin_config_*` symbols (Story 9.28) use the **handle-less
two-parameter shape**, every input — the workspace root included — inside the
request table (`workspace_root` absent = no workspace, the CLI run without `-R`):

```c
ZanshinBuf* zanshin_config_<verb>(const uint8_t* data, uintptr_t len);
```

They are handle-less on purpose: a stack only the workspace LOAD refuses (a
wrong-typed `git.*` key) makes `zanshin_repo_open` fail, and the config verbs are
how the user repairs it — exactly as the CLI's config commands never load the
workspace.

This section is the whole convention. The per-symbol rustdoc in
`crates/zanshin-ffi/include/zanshin_ffi.h` does not repeat it.

### Building the buffer (Dart side)

Dart builds the table with the flatc-generated object builder and hands the bytes
to `withRequestBytes` (`packages/zanshin_core/lib/src/ffi/request_bytes.dart:46-54`),
which `malloc`-copies them, calls the wrapper, and frees the pointer in a
`finally`. `callWithRequest` (`:110-113`) composes that with `readToken` for the
common call-and-decode shape:

```dart
// packages/zanshin_core/lib/src/ffi/commit_views.dart:59
final Uint8List request = fbs.ShowRequestObjectBuilder(revset: revset, ...).toBytes();
return callWithRequest(request, (ptr, len) => zanshin_show(rawHandle, ptr, len));
```

**Ownership is the AR-P-5 *inbound* rule: Dart allocates AND frees; Rust only
borrows for the duration of the call.** That is the exact **reverse** of the
outbound token rule above, where Rust allocates and Dart releases the allocation
through `zanshin_buffer_free_token`. The two directions never mix: a request
buffer is never freed Rust-side, and a returned token is never freed by `malloc`.

An empty buffer is deliberately **not** collapsed to `nullptr`
(`request_bytes.dart:40-45`). Every caller passes a finished FlatBuffers buffer,
which always carries at least a root offset and a vtable — but if a zero-length
buffer ever did arrive, passing `nullptr` instead would change the observable
answer to `ffi.null_pointer`, which is a different refusal.

### Reading the buffer (Rust side) — the refusal ladder

All twenty-seven wrappers share one reader shape (worked example:
`crates/zanshin-ffi/src/commit_views.rs:82-98`, whose module banner at `:51-56`
carries the SAFETY argument for the unbounded lifetime
`std::slice::from_raw_parts` produces — each reader builds its own slice in its
own scope and returns an OWNED struct, so the slice provably cannot outlive the
call). Five distinct refusals sit at five distinct layers:

| Order | Check | Code | `context` |
|-------|-------|------|-----------|
| 1 | `reject_null_request(data)` — `envelope.rs:183-191` | `ffi.null_pointer` | **absent** |
| 2 | `flatbuffers::root_with_opts::<fbs::X>(…)` verification — `envelope.rs:194-199` | `ffi.invalid_argument` | the flatbuffers verifier message |
| 3 | `expect_request_kind(req.kind(), …)` — the buffer was built for THIS wrapper | `ffi.invalid_argument` | `request kind mismatch: expected <K>, got <K>` |
| 4 | a required field is ABSENT from an otherwise valid table | `jj.invalid_input` | the field name |
| 5 | `session_from_handle(handle)` — the handle is `0` or the borrow yields `None` | `ffi.invalid_handle` | **absent** |

The two-parameter `zanshin_config_*` shape has rows 1–4 and **no row 5**: after the
required fields (row 4 there also refuses `ConfigScope::Unspecified` where a scope
is required, and `zanshin_config_list`'s scope-plus-`include_defaults` conflict)
come the verb's own codes.

Row 4 is the *reader's* own required-field guard, which among the handle-taking
readers only five have (`file annotate`'s `path`, `file search`'s `pattern`, `git remote add`'s `name`
and `url`, `git remote set-url`'s `name`, `interdiff`'s `from.id` / `to.id` — the
`id` inside a present `RevisionRef` union arm), plus the `zanshin_config_*` readers
above (`name`, `value`, `path`, `text`, a required scope). `interdiff`'s "at least one of from or to" refusal is
*not* row 4: an absent side is a legal value there, and the pair is judged by the
jj layer after row 5. Refusals raised further in — an empty `names` vector, an
unparseable pattern, a malformed commit-id prefix — likewise come from the jj
layer and land AFTER row 5. The per-symbol `# Errors` bullets in
`zanshin_ffi.h` are an inventory, not an evaluation order; this table is the
order.

`InterdiffRequest`'s two `RevisionRef` unions add one refusal *shape* to row 2:
a union occupies two vtable slots (discriminant + value) and
`Verifier::visit_union` requires them present or absent **together**, so a
half-written union is an inconsistent-union failure at row 2 rather than
anything the reader ever sees. An out-of-**range** discriminant byte does verify
— a union tag is range-checked no more than a plain enum is — and is refused by
the reader, as `ffi.invalid_argument` naming the tag.

A **zero-length or garbage buffer** fails verification, so it lands on
`ffi.invalid_argument` — never on `ffi.null_pointer`. Only a genuinely null
`data` pointer produces `ffi.null_pointer`.

**The whole request buffer is judged before the handle is borrowed.** Every one
of the eighteen handle-scoped wrappers calls its reader BEFORE `session_from_handle`, so rows 1
through 4 all precede row 5. That order is deliberate: a buffer built for the
wrong verb has to be refused on its own merits, not only when the caller happens
to hold a live handle. The only callers that see a different answer than they
would have before the tag landed are those that get BOTH wrong at once — a
malformed, mis-tagged or incomplete buffer together with a dead handle.

**The ladder starts only once `len` is honest.** `len` must describe exactly the
bytes readable at `data`; the reader builds its slice with
`std::slice::from_raw_parts(data, len)` before any verification runs, so a `len`
larger than the allocation is an out-of-bounds read — undefined behaviour, not a
refusal, and no ladder row covers it. That obligation is the caller's, and it is
repeated in every one of the twenty-seven symbols' `# Safety` blocks.

Layer 4 is a different question from layer 2: the buffer verified, but the *table*
does not carry a field the verb requires. ABSENCE is meaningful throughout —
across these tables an absent field is the wire form of "the user did not supply
it", which is what applies the CLI's own default (`@` for a revision, `mutable()`
for `absorb`'s `into`, the current workspace for `workspace root`). An explicitly
present **empty string is a VALUE, not an absence**, and takes the value path.

### Interior NUL

A FlatBuffers string is length-prefixed, so a NUL survives the wire and would
land inside a jj change id, path, pattern, bookmark name or remote URL. It is
rejected **Dart-side, at two layers**:

- `rejectInteriorNul` / `rejectInteriorNuls`
  (`request_bytes.dart:56-73`, `:81-85`) throw an `ArgumentError` — the
  direct-caller backstop.
- The **primary** guard sits one layer up, on the calling side in `ZanshinWorker`
  and `RepoHandle`, because a throw inside the worker isolate comes back as
  `internal.dispatch_error` rather than as the documented `ArgumentError`.

The check is deliberately spelled at both layers for that reason.

**Rust does not re-check.** There is no `reject_interior_nul` beside
`reject_null_request`: both enforcement layers are Dart-side, so a caller that
bypasses the generated adapters can put a NUL into a request string and it will
reach jj-lib. The guard is the adapter, not the wrapper. (The `RequestKind` tag
below is guarded on BOTH sides for the opposite reason: mis-routing a buffer is a
wire-level hazard, not a value-level one.)

### The request tables

`schemas/envelope.fbs` declares **26** request tables. They are **not** members of
the `Payload` union (that union is response-only). Field order IS the wire
contract: field ids are assigned by declaration order and baked into both
committed codegen sides. `kind` is **always field 0**; any other change to a
request table's field order is an in-place WIP edit that MUST regenerate BOTH
committed codegen sides in the same commit.

`ChangeIdList` is the only table shared by two symbols (`zanshin_new_change`'s
`parents` and `zanshin_abandon`'s `change_ids`). Every other table has exactly
one caller, and no table is orphaned. 26 tables + 1 shared reuse = the 27
request-buffer symbols.

`ChangeIdRef` and `CommitIdRef` are **not** in that count. They are the two
members of the `RevisionRef` union carried by `InterdiffRequest`'s `from`/`to`,
so they are nested values, never a buffer root: nothing verifies them
standalone, and they carry no `kind` tag of their own — the tag belongs to the
request table that owns them.

#### The `RequestKind` tag

Nothing in the FlatBuffers layer tells one request table from another: a buffer
built for one verb verifies as another verb's table, because none carries a
`file_identifier` and several put one string in the same slot. Field 0 of every
request table is therefore `kind: RequestKind`, and every reader refuses a buffer
whose tag is not its own — row 3 of the ladder above, before any other field is
read and before the handle is borrowed.

The tag is per-**wrapper**, not per-table. For 25 tables the variant name plus
`Request` is the table name; `ChangeIdList` carries **two** kinds, `NewChange`
and `Abandon`, because a per-table tag would have left the sharpest collision
unrefused — a buffer meant as `parents` abandoning those commits instead.

`Unspecified = 0` is FlatBuffers' default for an absent field, so a buffer built
by a producer that never sets `kind` is **byte-identical to a pre-tag buffer**,
decodes as `Unspecified`, and is always refused. "Legacy buffer" and "forgotten
tag" are the same, always-refused state; nothing untagged is ever accepted as any
verb. The tag is caller-supplied data and is never trusted: a byte outside the
enum verifies (FlatBuffers range-checks no enum scalar) and is refused by the
same rung, printing as `got <UNKNOWN n>`.

Member order in `RequestKind` IS the wire value — it is append-only, like the
tables it tags.

The tag guards the **wire**, not the caller: a caller bypassing the generated
adapters can still set it by hand. What it removes is the silent
mis-**execution** — a mis-routed buffer is now a refusal.

This closes the former "request tables verify interchangeably" caveat, one of the
cross-cutting must-haves on the central ledger,
`_bmad-output/implementation-artifacts/deferred-work.md` (others there remain
open).

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

## Symbol index

The cdylib exports **59** `extern "C"` functions. Every one has a row here; the
list is derived from `crates/zanshin-ffi/include/zanshin_ffi.h` and kept in sync
by `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs`, which fails if a header symbol
appears in neither a heading nor a first table cell of this file.

**The header rustdoc is authoritative for each code's CONDITION** — when a code
fires, what lands in `context`, which argument it blames. This index only *names*
the codes a symbol can return; read `zanshin_ffi.h`'s `# Errors` block for that
symbol to learn why. `internal.panic` is documented once under *Envelope format*
and is deliberately absent from every row.

Rows are grouped by noun: repository lifecycle, repo-state reads, commit views,
file reads, refs and workspaces, change mutations, bookmarks, working-copy tracking
and snapshot, git sync, config (Story 9.28), and infrastructure. `—` means "not applicable": no request table, no success payload,
or no `# Errors` block.

| Symbol | Args | Request table | Success payload | Error codes | Story |
|--------|------|---------------|-----------------|-------------|-------|
| `zanshin_repo_open` | `(const char *path)` | — | `RepoHandle` | `jj.path_not_found`, `jj.repo_not_found`, `jj.config_error`, `ffi.null_pointer`, `ffi.utf8_error`, `watcher.io_error` | 3.4a |
| `zanshin_repo_init` | `(const char *path, int32_t backend)` | — | `RepoHandle` | `ffi.invalid_argument`, `ffi.null_pointer`, `ffi.utf8_error`, `jj.config_error`, `jj.jj_lib_error`, `watcher.io_error` | 3.4a (+9.33) |
| `zanshin_repo_clone` | `(const char *url, const char *target_path)` | — | `RepoHandle` | `ffi.null_pointer`, `ffi.utf8_error`, `jj.config_error`, `jj.jj_lib_error`, `watcher.io_error` | 3.4a (+9.33) |
| `zanshin_repo_convert` | `(const char *path)` | — | `RepoHandle` | `jj.already_jj_repo`, `jj.not_a_git_repo`, `jj.convert_failed`, `jj.config_error`, `ffi.null_pointer`, `ffi.utf8_error`, `watcher.io_error` | 3.4c (+9.33) |
| `zanshin_repo_detect` | `(const char *path)` | — | `RepoDetect` | `jj.detect_failed`, `ffi.null_pointer`, `ffi.utf8_error` | 3.4c |
| `zanshin_repo_close` | `(uint64_t handle)` | — | — (no-payload success) | `ffi.invalid_handle` | 3.4a |
| `zanshin_status` | `(uint64_t handle)` | — | `Status` | `ffi.invalid_handle`, `jj.no_working_copy`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 3.4b |
| `zanshin_change` | `(uint64_t handle, const char *change_id)` | — | `Change` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.utf8_error`, `jj.change_not_found`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 3.4b |
| `zanshin_op_log` | `(uint64_t handle, int64_t limit)` | — | `OpLog` | `ffi.invalid_handle`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 3.4b |
| `zanshin_log_defaults` | `(uint64_t handle)` | — | `LogDefaults` | `ffi.invalid_handle`, `jj.config_error` | 4.9 |
| `zanshin_graph_slice` | `(uint64_t handle, const char *revset, const char *prioritize, bool synthetic_elided, const char *short_prefixes)` | — | `GraphSlice` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.utf8_error`, `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.stale_working_copy`, `jj.jj_lib_error`, `jj.config_error`, `graph.dangling_edge` | 4.6 (+4.8) |
| `zanshin_show` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `ShowRequest` | `ShowView` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.6 |
| `zanshin_evolog` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `EvologRequest` | `EvologView` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.6 |
| `zanshin_interdiff` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `InterdiffRequest` | `InterdiffView` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.change_not_found`, `jj.revset_resolution_error`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.6 |
| `zanshin_file_list` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `FileListRequest` | `FileList` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.change_not_found`, `jj.invalid_input`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.4 |
| `zanshin_file_show` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `FileShowRequest` | `FileContents` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.change_not_found`, `jj.path_not_found`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.4 |
| `zanshin_file_annotate` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `FileAnnotateRequest` | `FileAnnotation` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.change_not_found`, `jj.invalid_input`, `jj.path_not_found`, `jj.not_a_file`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.4 |
| `zanshin_file_search` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `FileSearchRequest` | `FileSearch` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.change_not_found`, `jj.invalid_input`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.4 |
| `zanshin_bookmarks` | `(uint64_t handle)` | — | `Bookmarks` | `ffi.invalid_handle`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 3.4b |
| `zanshin_remotes` | `(uint64_t handle)` | — | `Remotes` | `ffi.invalid_handle`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 3.4b |
| `zanshin_workspace_list` | `(uint64_t handle)` | — | `WorkspaceList` | `ffi.invalid_handle`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.7 |
| `zanshin_workspace_root` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `WorkspaceRootRequest` | `WorkspaceRoot` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.workspace_not_found`, `jj.workspace_no_recorded_path`, `jj.workspace_path_unresolved`, `jj.jj_lib_error` | 9.7 |
| `zanshin_describe` | `(uint64_t handle, const char *change_id, const char *description)` | — | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.utf8_error`, `jj.change_not_found`, `jj.invalid_input`, `jj.immutable`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 6.5 |
| `zanshin_new_change` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `ChangeIdList` | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.change_not_found`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 6.5 |
| `zanshin_edit` | `(uint64_t handle, const char *change_id)` | — | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.utf8_error`, `jj.change_not_found`, `jj.immutable`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 6.5 |
| `zanshin_abandon` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `ChangeIdList` | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 6.5 |
| `zanshin_restore` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `RestoreRequest` | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.3 |
| `zanshin_absorb` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `AbsorbRequest` | `AbsorbResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.invalid_input`, `jj.change_not_found`, `jj.immutable`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.3 |
| `zanshin_undo` | `(uint64_t handle)` | — | `MutationResult` | `ffi.invalid_handle`, `jj.nothing_to_undo`, `jj.invalid_input`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 6.5 |
| `zanshin_bookmark_create` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `BookmarkCreateRequest` | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.change_not_found`, `jj.bookmark_exists`, `jj.bookmark_tracked_remote_exists`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.8 |
| `zanshin_bookmark_delete` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `BookmarkDeleteRequest` | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.8 |
| `zanshin_file_track` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `FileTrackRequest` | `TrackResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.config_error`, `jj.no_working_copy`, `jj.concurrent_working_copy`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.22 |
| `zanshin_file_untrack` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `FileUntrackRequest` | `UntrackResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.config_error`, `jj.no_working_copy`, `jj.concurrent_working_copy`, `jj.path_not_ignored`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.22 |
| `zanshin_snapshot` | `(uint64_t handle)` | — | — (no-payload success; the report is `Envelope.precondition`) | `ffi.invalid_handle`, `jj.stale_working_copy`, `jj.config_error`, `jj.jj_lib_error` | 9.26 |
| `zanshin_git_fetch` | `(uint64_t handle, const char *remote_name)` | — | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.utf8_error`, `jj.remote_not_found`, `jj.not_a_git_repo`, `jj.config_error`, `jj.network_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 6.5 (domain side + `Progress`: 6.4a) |
| `zanshin_git_import` | `(uint64_t handle)` | — | `GitImportResult` | `ffi.invalid_handle`, `jj.not_a_git_repo`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.5 |
| `zanshin_git_export` | `(uint64_t handle)` | — | `GitExportResult` | `ffi.invalid_handle`, `jj.not_a_git_repo`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.5 |
| `zanshin_git_remote_add` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `GitRemoteAddRequest` | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.remote_exists`, `jj.not_a_git_repo`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.5 |
| `zanshin_git_remote_remove` | `(uint64_t handle, const char *name)` | — | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.utf8_error`, `jj.config_error`, `jj.remote_not_found`, `jj.remote_nonstandard_config`, `jj.not_a_git_repo`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.5 |
| `zanshin_git_remote_rename` | `(uint64_t handle, const char *old_name, const char *new_name)` | — | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.utf8_error`, `jj.config_error`, `jj.invalid_input`, `jj.remote_not_found`, `jj.remote_exists`, `jj.remote_nonstandard_config`, `jj.not_a_git_repo`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.5 |
| `zanshin_git_remote_set_url` | `(uint64_t handle, const uint8_t *data, uintptr_t len)` | `GitRemoteSetUrlRequest` | `MutationResult` | `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.remote_not_found`, `jj.not_a_git_repo`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error` | 9.5 |
| `zanshin_config_list` | `(const uint8_t *data, uintptr_t len)` | `ConfigListRequest` | `ConfigListResult` | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.path_not_found`, `jj.repo_not_found`, `jj.config_error`, `jj.config_parse_error` | 9.28 |
| `zanshin_config_get` | `(const uint8_t *data, uintptr_t len)` | `ConfigGetRequest` | `ConfigGetResult` | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.path_not_found`, `jj.repo_not_found`, `jj.config_error`, `jj.config_parse_error`, `jj.config_not_found` | 9.28 |
| `zanshin_config_path` | `(const uint8_t *data, uintptr_t len)` | `ConfigPathRequest` | `ConfigPathResult` | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.path_not_found`, `jj.repo_not_found`, `jj.config_error`, `jj.config_path_not_found` | 9.28 |
| `zanshin_config_set` | `(const uint8_t *data, uintptr_t len)` | `ConfigSetRequest` | `ConfigSetResult` (+ `precondition` iff the identity check snapshotted) | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.path_not_found`, `jj.repo_not_found`, `jj.config_error`, `jj.config_parse_error`, `jj.config_path_not_found`, `jj.config_ambiguous_file`, `jj.config_would_overwrite` | 9.28 |
| `zanshin_config_unset` | `(const uint8_t *data, uintptr_t len)` | `ConfigUnsetRequest` | `ConfigUnsetResult` | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.path_not_found`, `jj.repo_not_found`, `jj.config_error`, `jj.config_parse_error`, `jj.config_path_not_found`, `jj.config_ambiguous_file`, `jj.config_would_delete_table`, `jj.config_not_found` | 9.28 |
| `zanshin_config_file_read` | `(const uint8_t *data, uintptr_t len)` | `ConfigFileReadRequest` | `ConfigFileText` | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.path_not_found`, `jj.repo_not_found`, `jj.config_error`, `jj.config_path_not_found`, `jj.config_ambiguous_file` | 9.28 |
| `zanshin_config_file_write` | `(const uint8_t *data, uintptr_t len)` | `ConfigFileWriteRequest` | — (no-payload success) | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.path_not_found`, `jj.repo_not_found`, `jj.config_ambiguous_file`, `jj.config_parse_error`, `jj.config_error` | 9.28 |
| `zanshin_config_gc_list` | `(const uint8_t *data, uintptr_t len)` | `ConfigGcListRequest` | `ConfigGcList` | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.config_error`, `jj.config_path_not_found` | 9.28 |
| `zanshin_config_gc_delete` | `(const uint8_t *data, uintptr_t len)` | `ConfigGcDeleteRequest` | `ConfigGcResult` | `ffi.null_pointer`, `ffi.invalid_argument`, `jj.config_error`, `jj.config_path_not_found` | 9.28 |
| `zanshin_ffi_version` | `(void)` → `char *` | — | — | — | 3.2 |
| `zanshin_diagnostics` | `(void)` | — | `Diagnostics` | — (infallible; see *Token contract*) | 3.8 |
| `zanshin_log` | `(int32_t level, const char *target, const char *message)` → `void` | — | — | — | 3.3 |
| `zanshin_logging_init` | `(void)` → `void` | — | — | — | 3.3 |
| `zanshin_events_register` | `(void (*callback)(ZanshinBuf *event))` → `void` | — | — | — | 3.6 |
| `zanshin_events_unregister` | `(void)` → `void` | — | — | — | 3.6 |
| `zanshin_string_free` | `(char *ptr)` → `void` | — | — | — | 3.2 |
| `zanshin_buffer_free` | `(uint8_t *ptr, uintptr_t len)` → `void` | — | — | — | 3.2 |
| `zanshin_buffer_free_token` | `(ZanshinBuf *token)` → `void` | — | — | — | 3.2 |

Every symbol not marked `→ char *` or `→ void` returns `ZanshinBuf *` — the
never-null token described under *Token contract*.

**The empty-identity note (Stories 9.27 → 9.32).** A call whose `finish_transaction`
committed an operation while `user.name` and/or `user.email` was empty in the effective
config stack carries a `jj.identity_missing` entry in `Envelope.warnings` — the jj CLI's
post-transaction "Name and email not configured." block (or its name-only / email-only
variant), verbatim. Story 9.27's `MutationResult.identity_missing` table
(`IdentityMissing { name, email }`) is gone: the warning is the fact's only carrier. It
is never a refusal: the commit was created with the empty identity, exactly as the CLI
creates it; nothing is emitted when both are configured or when the call committed nothing
(and not for `zanshin_file_track` / `_untrack`, whose CLI verbs skip the finish). The
pre-verb snapshot's own import finishes warn too, as the CLI's do. Since Story 9.33 the
creations carry it where the CLI's flow finishes a transaction: `zanshin_repo_clone` ONCE
after its single `clone` operation (the CLI, which finishes up to three transactions, warns
up to three times — a recorded Story 9.20 deferral), the conversion snapshot's own finishes;
never `zanshin_repo_init` (an empty-directory `jj git init` finishes nothing) and never the
conversion's raw commits.

---

## Per-symbol contracts

Four symbols carry more contract than their rustdoc can hold, and keep a prose
section: `zanshin_repo_detect` and `zanshin_repo_convert` here,
`zanshin_graph_slice` and `zanshin_log_defaults` further down. For every other
symbol the rustdoc block above its declaration in `zanshin_ffi.h` is the contract.

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
by calling `convert_colocated` (`zanshin_jj`). It runs the same sequence as
`jj git init` over an existing `.git/` (`do_init`'s External arm): `import git
refs` (skipped when it changed nothing), a `.jj/.gitignore` containing `/*`, then
the CLI's per-command snapshot under jj's Git import/export lock (Story 9.26) —
`import git head` re-parents `@` onto the Git HEAD by resetting the working-copy
STATE only, and `snapshot working copy` records a dirty work tree into `@` — and
finally, when `refs/remotes/upstream/HEAD` or `refs/remotes/origin/HEAD` names a
bookmark, `revset-aliases.'trunk()'` in the repo-level config file, which lives
**outside** `.jj/`, under `<config_dir>/jj/repos/<config-id>/config.toml`. No
work-tree file is written or deleted. `.git/` is written only by the CLI's own
colocated steps — jj exports back the refs it has just imported and, when the
snapshot recorded changes, adds intent-to-add entries for the new files to
`.git/index` (`@` is mutable after the conversion, so the snapshot takes the
CLI's `export_working_copy_changes_to_git` branch; the HEAD/index reset happens
only for an immutable `@`) — so no
user-visible ref and no HEAD is moved, and a rollback never deletes or rewrites
`.git/`.

On success the function returns a live `RepoHandle` for the converted
workspace. The Dart worker stores the raw handle in its Model-A handle table
(`handleId → raw *mut RepoSession`) and returns an opaque `handleId` to the caller.

**The conversion's report (Story 9.33).** Both envelopes — ok and error — carry what
`jj git init` would have printed. `Envelope.precondition` is the report of the snapshot
the conversion runs, present iff it started (PARTIAL when it failed). `Envelope.warnings`
holds, in the CLI's order: the refs step's `jj.git_import_failed` (`git/init.rs:304`,
also when the step writes no operation) and colocated `jj.git_export_failed`
(`:311-312`); the config-load warnings (`jj.config_alias_invalid`,
`jj.config_alias_redefined`, `jj.revset_diagnostic`); the snapshot's own warnings (its
colocated refs import reports an unreadable ref a SECOND time, as the CLI does); then,
on the snapshot's success, `jj.snapshot_files_refused` / `jj.snapshot_paths_not_utf8`.
The refs step and the head import commit without a finish, so an empty identity is
warned only by a finish the snapshot itself runs. A failure keeps everything reported
before it — when it came before the re-open, although the rollback removes `.jj/`; a
failed re-open or watcher arming leaves `.jj/` in place.

**Success payload:** `Envelope<RepoHandle>`

```
RepoHandle {
  handle:     uint64   // raw *mut RepoSession reinterpreted as u64; opaque to Dart
  session_id: uint64   // process-unique event-correlation id (never reused);
                       // async events carry it — see "Correlation and demux"
}
```

**Error codes:**

| Code                 | Condition                                              |
|----------------------|--------------------------------------------------------|
| `jj.already_jj_repo` | `.jj/` already exists at `path`.                       |
| `jj.not_a_git_repo`  | No `.git/` at `path` (or path does not exist).         |
| `jj.convert_failed`  | jj-lib, config-write or `detect_repo` I/O error during conversion; detail in `context`. |
| `ffi.null_pointer`   | `path` is null.                                        |
| `ffi.utf8_error`     | `path` contains invalid UTF-8.                         |
| `watcher.io_error`   | The filesystem watcher could not be armed, so no handle is returned (strict-fail, OQ-1 — see *Async events* below). The written `.jj/` persists; detail in `context`. |

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
  _replyRepoOp(bytes, ...);  // stores handle on success, replies HandleResult(id, bytes)
```

Public `ZanshinWorker` API:

- `Future<RepoDetectResult> detect(String path)` — decodes via `decodeRepoDetectEnvelopeInternal`
- `Future<CreatedRepoHandle> convert(String path)` — stores handle, returns a
  `CreatedRepoHandle` whose `warnings` / `precondition` are decoded from the ok envelope
  `HandleResult` forwards (`decodeCreationReportInternal`, Story 9.33)

---

## Async events (Story 3.6)

FR-FFI-4's async Rust→Dart signal: Story 3.5's watcher events and FR-FFI-8's
future progress notifications both ride ONE process-global `NativeCallable`
sink, registered once by the Dart worker isolate at startup. There is no
per-handle callback registry.

### `RepoSession` — the handle is now a warm loader + watcher owner

Every handle-producing wrapper (`zanshin_repo_open`/`_init`/`_clone`/`_convert`)
constructs a `RepoSession { repo, watcher, dispatch }` and arms its filesystem
watcher **before returning** (AR-G-5). The `u64` handle Dart holds is a
`*mut RepoSession` (no wire/ABI change — handles were always opaque `u64`).
Each session owns one background dispatch thread that drains the watcher's
`Receiver` and forwards serialised events to the process-global sink.
`zanshin_repo_close` stops the watcher (joins the debouncer thread) and joins
the dispatch thread **before** the session — and the repo it holds — is
dropped, so no callback can fire for a handle after `close` returns.

**Arming failure is strict-fail (OQ-1):** if the watcher cannot be armed
(e.g. a required `.jj` sub-path is missing or unwatchable), the wrapper
returns `watcher.io_error` and **no handle** — the repo is not left open in
an unwatched state. For `init`/`clone`/`convert` the on-disk artefacts
created before the arming failure **persist** (only the arming failed; a
retry will see an existing repo — same posture as other post-init failures) and
the `watcher.io_error` envelope still carries the creation's warnings / snapshot
report (Story 9.33); `open` leaves no residue. Post-arm watch degradation (e.g. an FS error after a
successful open) never re-uses this code string; it rides the event stream
instead (see `WatchError` below) — `watcher.io_error` is emitted in exactly
one place: the arming-failure envelope at open/init/clone/convert.

### Registration

```c
typedef void (*EventCallback)(ZanshinBuf* event);

void zanshin_events_register(EventCallback callback);   // NULL is a defensive no-op
void zanshin_events_unregister(void);
```

Both are **infallible, `void`-returning, and `catch_unwind`-wrapped** — like
`zanshin_log`/`zanshin_logging_init`, they are handle-free and callable from
**any isolate/thread** (exempt from the single-consumer rule, AD-2).

- `register` **overwrites** any previously registered callback — there is no
  stacking. A worker restart simply re-registers.
- `unregister` is **unconditional and idempotent** — there is no
  compare-and-clear against a specific callback pointer, because production
  runs exactly one worker per process. This lets the **main** isolate call
  `unregister` on unexpected worker death without knowing the dead worker's
  callback pointer (`ZanshinWorker._onWorkerDeath`).
- **Ordering on graceful shutdown is load-bearing:** every open repo is closed
  (joining its dispatch thread) **before** `zanshin_events_unregister()`,
  which runs **before** the Dart `NativeCallable.close()`. Invoking a
  `NativeCallable`'s pointer after `close()` is undefined behaviour
  (api.dart.dev); this ordering makes that clause unreachable in practice.
- **`unregister` is a barrier:** the dispatch path holds the registration lock
  **across** the callback invocation, so once `unregister` returns no dispatch
  thread can still be inside a callback it loaded earlier — closing the
  callable or killing its isolate afterwards cannot race a delivery.
- **Shutdown-ack timeout backstop:** if the worker never acks the
  `ShutdownCommand` (hung or died mid-shutdown), the main isolate kills the
  worker and calls `zanshin_events_unregister()` itself — the killed
  isolate's callable must not stay reachable while un-closed sessions'
  dispatch threads are still alive.
- **Unexpected worker death:** the main isolate unregisters the sink
  (unconditional-clear, see above) and kills the worker. The dead worker's
  open sessions — their watchers and dispatch threads — **leak by design**
  (same posture as the handle leak on worker death); after the unregister they
  dispatch into an empty sink and drop. An event whose callback invocation is
  concurrent with the death instant is an **accepted residual race**; tokens
  already queued in the dead isolate leak with it.

### Token ownership across the async hop

`NativeCallable.listener` calls are non-blocking: Rust's `callback(token)`
returns immediately, and the Dart handler runs later, on the isolate that
created the callable. Rust therefore must **not** free the buffer after
invoking the callback — the token transfers to Dart exactly like a
synchronous return value:

```dart
// packages/zanshin_core/lib/src/ffi/events.dart:104
void _handleNativeEvent(
  void Function(ZanshinRawEvent event) onEvent,
  ffi.Pointer<ZanshinBuf> token,
) {
  try {
    final Uint8List bytes = readToken(token);   // copies out, then frees the token
    onEvent(decodeEventEnvelope(bytes));
  } catch (e, st) {
    _log.warning('dropping malformed event: $e', e, st);  // never unwind into Rust
  }
}
```

`readToken` is the shared outbound helper in
`packages/zanshin_core/lib/src/ffi/request_bytes.dart:99-106` — the same one every
`extern "C"` adapter uses. This handler is its one caller whose token is not an
`extern "C"` return value; the guarantee is the same (Rust only ever posts a real
token), and the handler's own `try`/`catch` is what keeps a violation from
unwinding into the callback.

**Undelivered tokens at callable-close leak by design.** If the callable is
closed while events are still in flight, those tokens are never freed. This
is bounded (at most the channel capacity — 256 — per repo, per Story 3.5) and
shutdown-only; the graceful-shutdown ordering above (repos closed → threads
joined → *then* the callable closes) makes the window empty in practice. No
machinery is built to reclaim it.

### Payload schemas

Both tables are appended to the existing `Payload` union (`schemas/envelope.fbs`)
— no second root type, no JSON, no `schema_version` (ADR-0001). Event
envelopes are always `ok == true`.

```
enum WatcherEventKind : byte { OpHeadsChanged, WorkingCopyHeartbeat, WatchError }

WatcherEvent {
  session_id:  uint64          // correlation id — process-unique, never reused
  kind:        WatcherEventKind
  paths:       [string]?       // absent for WatchError (null-for-absence)
  message:     string?         // set only for WatchError
}

Progress {
  session_id:  uint64          // same correlation id; first real producer is Story 6-4a
  operation:   string          // e.g. "fetch"
  progress:    float           // ∈ [0, 1]
  message:     string
}
```

`WatchError` is a **degraded-watch signal, not a failed call** — it never
carries the `watcher.io_error` code string (single-emission-point rule).

### Correlation and demux

Events carry the session's **`session_id`** — a process-unique `u64` allocated
from a monotonic counter when the session is armed (starts at 1; 0 is never
issued) and returned to the worker alongside the raw handle in the `RepoHandle`
payload (`RepoHandle { handle, session_id }`). The lookup lives in the
`registerEventSink` closure the worker installs
(`packages/zanshin_core/lib/src/worker/isolate.dart:1349-1352`): it reads
`sessionToId[raw.sessionId]` to recover the small dense `handleId` before
constructing the public `RepoEvent` sent to main; an unknown session id (a benign
close race) is logged and dropped, never thrown. Raw pointers still never reach
the main isolate (Model A holds); the raw handle is the worker-side token for
calls back INTO the cdylib — `zanshin_repo_close`, every read wrapper, and — since
Story 6.5 and Epic 9 — every mutation wrapper too.

**Resolved (2026-07-04) — raw-pointer ABA** (formerly a known accepted gap,
3-6 review): events used to carry the raw `*mut RepoSession`-derived `u64`; a
close → reopen could reuse the freed allocation's address, so a stale event
queued during the close window could be misattributed to the NEW repo's
`handleId` (first observed in the wild as a load-induced flake of the 3.6
two-repos isolation test, 2026-07-03). Session ids are never reused, so a
stale event can now only be dropped — never misattributed. Pulled forward
from Story 6-4a during the 3-10 code review (Ralph, 2026-07-04); Story 6-4a's
`Progress` producer inherits the same correlation id.

### Dart worker integration

- `lib/src/ffi/events.dart` — owns the `NativeCallable.listener`, the
  try/catch-wrapped native handler, and `registerEventSink` / `closeEventSink` /
  `unregisterEventSink`. It is **not** the only file that imports `dart:ffi`;
  every adapter under `lib/src/ffi/` does. The invariant is the layer boundary:
  **`dart:ffi` never reaches `lib/src/worker/`** — the worker deals in raw `int`
  handles and `Uint8List` envelopes only, which is what keeps `Pointer` out of
  the isolate seam.
- `lib/src/worker/events.dart` — pure Dart `RepoEvent` sealed family
  (`OpHeadsChangedEvent` / `WorkingCopyHeartbeatEvent` / `WatchErrorEvent` /
  `ProgressEvent`), exported from `zanshin_core.dart`.
- `ZanshinWorker.events` — a broadcast `Stream<RepoEvent>` fed by the
  previously-unused (Story 3.9) event `SendPort`.
- `ZanshinWorker.close()` is now `Future<void>`: it sends a `ShutdownCommand`
  the worker uses to run the shutdown ordering above, then awaits an ack
  (bounded timeout) before killing the isolate as a backstop.

---

## GraphSlice payload (Story 4.2) and `zanshin_graph_slice` (Stories 4.6 + 4.8)

The lane-assigned commit graph (Story 4.1, `zanshin_graph::Row`) crosses FFI
as a `GraphSlice` member of the `Payload` union (`schemas/envelope.fbs`) — no
JSON, no `schema_version` (ADR-0001). The exported symbol is
`zanshin_graph_slice` (Story 4.6, below): it calls
`zanshin_graph::collect_lanes` and serialises the rows with the Rust builder
`zanshin_ffi::graph::graph_slice_to_envelope(&[Row]) -> Vec<u8>` (infallible,
always `ok == true`); the Dart worker command `GraphSliceCommand` feeds the
bytes to `decodeGraphSliceEnvelopeInternal`
(`packages/zanshin_core/lib/src/ffi/graph.dart`).

Since **Story 4.8** each commit row is *self-contained renderable*: it carries
the `jj log`-parity display metadata (`GraphRowMeta`) and the lanes passing
through it (`GraphActiveLane`) alongside its own lane and edges, all derived
from the SAME `load_at_head` snapshot in the same stream pass. Rendering the
default `jj log` view therefore takes ONE call — no per-commit `zanshin_change`
follow-ups, and no window in which an external `jj` operation could make the
lanes and the metadata disagree.

### `zanshin_graph_slice`

```c
ZanshinBuf* zanshin_graph_slice(uint64_t handle,
                                const char* revset,
                                const char* prioritize,
                                bool synthetic_elided,
                                const char* short_prefixes);
```

Returns every lane-assigned row of `revset` in the repo referenced by `handle`,
in `jj log` order — the revset-selected slice of the commit graph. There is
exactly ONE graph function: no `zanshin_graph_build` / `_close`, no graph
handle, no `LaneCache` (ADR-0002 AC-4 — nothing to build, rebuild, or close),
and no `start` / `count` / `limit` / `reversed` (Story 4.4 delivered
return-all; windowing is deferred past WIP).

**Parameter semantics (FR-JJ-17 pass-through):**

- `handle` — a live `RepoSession` handle from `zanshin_repo_open` / `_init` /
  `_clone` / `_convert`. Borrowed, never consumed.
- `revset` — the revset selecting the rows (e.g. `all()`, `heads(all())`).
  Caller-owned NUL-terminated UTF-8 C string (Dart `toNativeUtf8` / `calloc.free`;
  Rust only borrows it — AR-P-5 inbound rule). The CLI's `revsets.log` default
  is exported as the Dart constant `defaultLogRevset` (a mirror of
  `zanshin_jj::DEFAULT_LOG_REVSET`) for the UI to pre-fill; it is never applied
  silently. It parses because Zanshin's builtin config layer defines the CLI's
  `[revset-aliases]` (`trunk()`, `builtin_immutable_heads()`,
  `immutable_heads()`, `immutable()`, `mutable()`, `visible()`, `hidden()`).
  **Since Story 4.9** all three revset pass-throughs — `revset`, `prioritize`
  and `short_prefixes` — resolve aliases from the repo's EFFECTIVE jj config
  (builtin defaults < user config < repo config < workspace config), re-read on
  every call, so a user's `[revset-aliases]` override of `trunk()` or
  `immutable_heads()` changes the row set and the per-row `meta.immutable` flag
  exactly as it does in their CLI, and their own `wip()` / `mine()` aliases are
  accepted. A malformed config fails the call with `jj.config_error`; a single
  bad alias entry only warns and is skipped. `zanshin_log_defaults` (below)
  returns the effective values of the four `jj log` defaults.
- `prioritize` — the branch-prioritisation revset (`jj log`'s
  `revsets.log-graph-prioritize`). Caller-owned C string, same ownership rule.
  The CLI default is `present(@)` — the Dart side pre-fills it as
  `defaultGraphPrioritize` (a mirror of `zanshin_jj::DEFAULT_GRAPH_PRIORITIZE`),
  editable by the caller; `none()` is the canonical "no prioritisation" value;
  a blank expression is a `jj.revset_parse_error`.
- `synthetic_elided` — render elided ancestry as synthetic "(elided revisions)"
  rows (the CLI's `ui.log-synthetic-elided-nodes`, default `true`, pre-filled
  Dart-side). `true`: every `Indirect` edge becomes a `Direct` edge into a
  spliced synthetic row emitted right after its child. `false`: the pre-4.8
  stream — plain `Indirect` edges, no synthetic rows. A plain `bool` at the C
  surface (`zanshin_ffi.h` already includes `<stdbool.h>`).
- `short_prefixes` — the disambiguation revset for the shortest-prefix lengths
  (`revsets.short-prefixes`, which the CLI falls back to `revsets.log` for, so
  the Dart pre-fill `defaultShortPrefixes == defaultLogRevset`). Caller-owned C
  string, same ownership rule. An **EMPTY string DISABLES** disambiguation
  (full-index prefix lengths) — the CLI's toggle semantic, deliberately unlike
  `prioritize`, where a blank expression is a parse error. A **PARSE** failure of
  the expression is a hard error; everything that can only fail while LOADING the
  disambiguation index — symbol resolution included — is a `jj.short_prefixes_failed`
  warning (Story 9.32) and degrades to full-index prefixes rather than failing the
  call, exactly as the CLI does (pinned by jj's `cli/tests/test_log_command.rs::test_log_bad_short_prefixes`
  @ v0.44.0: `revsets.short-prefixes = 'missing'` warns and still prints the whole
  log). So an unknown bookmark in `short_prefixes` succeeds; an unknown bookmark in
  `revset` or `prioritize` is `jj.revset_resolution_error`.

All expressions are passed through verbatim — nothing is baked in. An interior
NUL (U+0000) in `revset`, `prioritize`, or `shortPrefixes` is rejected
Dart-side with an `ArgumentError` (a C string cannot carry it; `toNativeUtf8`
would silently truncate the expression).

**Re-derive per call (ADR-0002).** The graph is re-derived from the head
operation on every call; Rust retains no graph state between calls. An
operation performed by another process (jj CLI, MCP) between two calls on the
same handle is visible in the second. The op-heads watcher event stream
(`OpHeadsChangedEvent`, Story 3.6) is the UI's re-request trigger — the worker
does **not** auto-re-derive.

**Success payload:** `Envelope<GraphSlice>` (shapes below); `total_rows ==
rows.length`. Size model: the whole revset result is materialised into ONE
buffer (every row and edge, no cap; `total_rows` saturates at `u32::MAX`) and
copied once into Dart — windowing is deferred past WIP.

**Error codes:**

| Code                         | Condition                                                                 |
|------------------------------|---------------------------------------------------------------------------|
| `ffi.invalid_handle`         | Rust: `handle == 0`. Worker: unknown/closed `handleId` (Model A handle-table lookup). A stale non-zero raw handle is UB — liveness is the worker's lookup, not a Rust check (see the fn's `# Safety` rustdoc). |
| `ffi.null_pointer`           | `revset`, `prioritize`, or `short_prefixes` is null.                      |
| `ffi.utf8_error`             | `revset`, `prioritize`, or `short_prefixes` contains invalid UTF-8.       |
| `jj.revset_parse_error`      | An expression is syntactically invalid / unknown function (incl. blank `prioritize`; an EMPTY `short_prefixes` is NOT an error — it disables disambiguation). The only `short_prefixes` failure that surfaces as an error code. Reason in `context`. |
| `jj.revset_resolution_error` | `revset` or `prioritize` names a symbol that cannot be resolved; reason in `context`. NOT raised for `short_prefixes` (it warns and degrades — see above). |
| `jj.jj_lib_error`            | jj-lib evaluation/backend failure (e.g. corrupt op store); detail in `context`. |
| `jj.config_error`            | The repo's effective jj config is unreadable, not valid TOML, has a malformed `config-id`, or a wrong-typed value (Story 4.9) — or, for `zanshin_git_remote_remove`/`_rename`, the repo-level file could not be WRITTEN back (Epic 9 follow-up J); the file path or config key in `context`. A single bad `[revset-aliases]` entry does NOT produce this — it warns and is skipped. |
| `graph.dangling_edge`        | The revset graph stream violated its contract (dangling non-`Missing` edge) — unreachable with real jj-lib streams; target id in `context`. |

An error envelope never carries partial rows.

**Dart worker integration:**

- `GraphSliceCommand(handleId, revset, prioritize, syntheticElided, shortPrefixes)`
  — worker looks up the raw handle (unknown id → `ffi.invalid_handle` envelope),
  calls `zanshinGraphSlice(raw, revset, prioritize, syntheticElided:,
  shortPrefixes:)` (`lib/src/ffi/graph.dart`; the two Story-4.8 parameters are
  NAMED Dart-side because `avoid_positional_boolean_parameters` forbids a
  positional `bool` — the C argument order is unchanged), and replies
  `BufferResult` with the `Envelope<GraphSlice>` bytes.
- `ZanshinWorker.graphSlice(handleId, {required revset, required prioritize,
  required syntheticElided, required shortPrefixes})` → `GraphSlice` via
  `decodeGraphSliceEnvelopeInternal`.
- `RepoHandle.graphSlice({required revset, prioritize = defaultGraphPrioritize,
  syntheticElided = defaultSyntheticElided, shortPrefixes = defaultShortPrefixes})`
  — closed-handle guard (`StateError`), pre-fills the CLI defaults, delegates.
  (`defaultSyntheticElided` is `true`; the constant, not the literal, is the
  default — `packages/zanshin_core/lib/src/worker/handle.dart:126`.)

```
enum GraphEdgeKind : byte { Direct, Indirect, Missing }   // == zanshin_graph::EdgeKind order

GraphRowEdge {
  target:      string          // parent commit id, hex
  target_lane: uint            // meaningful ONLY when kind != Missing (see below)
  kind:        GraphEdgeKind
}

GraphActiveLane {               // a lane passing THROUGH the row (Story 4.8)
  lane:        uint
  kind:        GraphEdgeKind    // the kind of the edge that opened the segment
}

GraphCommitRef {                // one bookmark/tag entry (Story 4.8)
  name:        string
  remote:      string           // ABSENT (Dart null) for the local entry
  synced:      bool
  conflicted:  bool
}

GraphRowMeta {                  // jj log-parity display metadata (Story 4.8)
  change_id:                   string   // reverse-hex display form
  change_id_prefix_len:        uint
  commit_id_prefix_len:        uint
  change_offset:               uint     // meaningful ONLY when has_change_offset
  has_change_offset:           bool
  author_name:                 string   // may be empty
  author_email:                string   // may be empty
  committer_timestamp_millis:  long
  committer_tz_offset_minutes: int
  bookmarks:                   [GraphCommitRef]
  tags:                        [GraphCommitRef]
  working_copies:              [string] // empty in a single-workspace repo
  working_copy:                bool     // this workspace's @
  immutable:                   bool     // in ::(immutable_heads() | root())
  conflict:                    bool
  empty:                       bool
  hidden:                      bool
  divergent:                   bool
  root:                        bool
  description_first_line:      string   // "" when the description is empty
}

GraphRow {
  commit_id:        string           // commit id, hex — rows are keyed by COMMIT id, not change id
  lane:             uint
  color_idx:        uint             // lane % PALETTE_SIZE (8)
  edges:            [GraphRowEdge]   // one per input parent edge, same order
  active_lanes:     [GraphActiveLane]// pass-through lanes, ascending; always present
  synthetic_elided: bool             // this is an "(elided revisions)" row
  meta:             GraphRowMeta     // ABSENT iff synthetic_elided
}

GraphSlice {
  rows:        [GraphRow]      // always present (empty list for an empty slice)
  total_rows:  uint
}
```

- **`target_lane` presence rule.** `flatc 25.12.19` rejects optional scalars
  (`= null`) for Dart, so absence is encoded by `kind`: a `Missing` edge never
  reserves a lane — Rust writes `target_lane = 0` and the Dart model
  (`GraphRowEdge.targetLane`) is `int?`, `null` iff `kind == missing`
  (null-for-absence at the model level; same presence-flag pattern as
  `RepoDetect.suggested_kind` / `Bookmark.remote_name`). Never read
  `target_lane` of a `Missing` edge.
- **`meta` absence rule.** `meta` is a NESTED TABLE precisely because that is
  the only shape flatc 25.12.19 lets Dart see as `null`: it is absent on a
  synthetic elided row (`GraphRow.meta` → `GraphRowMeta?`) and present on every
  commit row. On an elided row `commit_id` holds the ELIDED TARGET's id, the
  lane fields are real, and the single `Direct` edge points at that target's
  real row. Inside `GraphRowMeta`, `change_offset` uses the documented presence
  pair (`has_change_offset`; Dart `int?`) and `remote` uses string-nullability
  (Dart `String?`, `null` for the local entry).
- **Ref visibility is CONTENT, not styling.** `bookmarks` / `tags` carry the
  CLI's own per-commit filter (`collect_distinct_refs`: `is_local() ||
  !synced`) — a tracked-AND-synced remote entry simply is not part of a
  `jj log` row and is not emitted. The unfiltered view stays
  `zanshin_bookmarks_list`'s job. The `*` / `??` / `@remote` sigils are the UI's
  to draw from `synced` / `conflicted` / `remote`.
- **`commit_id` is not a unique row key.** With `synthetic_elided` on (the
  default) the synthetic "(elided revisions)" row carries its TARGET's
  `commit_id`, so a slice can contain two rows with the same id, and the child's
  `GraphRowEdge.target` names that id with no synthetic marker (deliberate — the
  wire has no `target_synthetic` field). A synthetic row always sits
  IMMEDIATELY after the child that elided to it; `lane` / `target_lane` are the
  linkage. Key rows by position, or by `(commit_id, synthetic_elided)`.
- **`active_lanes` invariant.** For every routed edge on lane `L` from a child
  row to its landing row, every row STRICTLY BETWEEN the two lists `L` in its
  `active_lanes`; a row never lists its own lane. A renderer can therefore paint
  any row's complete cross-section from that row's fields alone.
- **`total_rows` semantics.** Return-all (Story 4.4 delivered it as
  `zanshin_graph::collect_lanes`): `total_rows == rows.length`. Windowing is
  deferred past WIP; if it lands later it may set `total_rows > rows.length`
  (an in-place wire change — edit the `.fbs`, regenerate, update all callers).
- **Row order** is the stream / `jj log` order (topo-grouped, children before
  parents); one `GraphRow` per `Row`, one `GraphRowEdge` per `RowEdge`, verbatim
  strings (no escaping).
- **Decode contract (Dart).** `!ok` → `ZanshinFfiException(code, context)` carrying
  the envelope's `precondition` and `warnings` (Story 9.35, the shared
  `decodeEnvelopeErrorInternal`);
  `ok` with a non-`GraphSlice` union variant → `ZanshinFfiException('ffi.unknown')`
  (discriminant guard, same as every other payload decoder). An out-of-range
  `GraphEdgeKind` byte surfaces as the generated `StateError` (cdylib/bindings
  version-skew or corruption — crash loudly, not recoverable; the same by-design
  rule as `RepoKind` in `repo_detect.dart`).
- **Reachability.** The graph is reachable via the worker command
  (`GraphSliceCommand` → `ZanshinWorker.graphSlice` / `RepoHandle.graphSlice`,
  Story 4.6). The Dart models/decoder in `graph.dart` are — like every other
  noun's models (`Change`, `WorkingCopyStatus`, `Operation`, `RepoHandle`) —
  not exported from `package:zanshin_core/zanshin_core.dart` by convention; the
  decode-contract tests import them via `src/`.

## `LogDefaults` payload and `zanshin_log_defaults` (Story 4.9)

The repo's EFFECTIVE `jj log` defaults cross FFI as a `LogDefaults` member of the
`Payload` union (`schemas/envelope.fbs`, appended after `GraphSlice` — union
member order is the wire discriminant, so it is append-only). The exported
symbol calls `zanshin_jj::Repo::log_defaults()` and serialises the result with
`zanshin_ffi::log_defaults::log_defaults_to_envelope` (infallible, always
`ok == true`). The Dart worker command `LogDefaultsCommand` carries only the
`handleId`; the worker isolate calls the adapter and replies with the raw bytes
as a `BufferResult`, and the decode happens main-isolate-side in
`ZanshinWorker.logDefaults` via `decodeLogDefaultsEnvelopeInternal`
(`packages/zanshin_core/lib/src/ffi/log_defaults.dart`).

### `zanshin_log_defaults`

```c
ZanshinBuf* zanshin_log_defaults(uint64_t handle);
```

Handle-only — no C-string argument, so there is no `ffi.null_pointer` /
`ffi.utf8_error` path (the same asymmetry as `zanshin_remotes`).

**What "effective" means.** `zanshin-jj` rebuilds, per call, the layered config
the jj CLI would have at the pinned **v0.44.0** for that workspace and reads the
four values out of it:

| Layer (ascending precedence) | Source |
|------------------------------|--------|
| `ConfigSource::Default`      | jj-lib's own defaults + Zanshin's builtin layer (`[revsets] log` / `log-graph-prioritize`, `ui.log-synthetic-elided-nodes`, `ui.conflict-marker-style` (Story 9.4 — the style `zanshin_file_show` materializes a conflicted file with), and the CLI's 7-entry `[revset-aliases]` table, verbatim from `cli/src/config/{revsets,misc}.toml` @ v0.44.0) |
| `ConfigSource::System`       | `/etc/jj/config.toml`, `/etc/jj/conf.d/` — ONLY when `JJ_CONFIG` is unset (`cli/src/config.rs:334-345` @ v0.44.0). Non-existent entries are skipped silently. |
| `ConfigSource::EnvBase`      | `operation.hostname` / `operation.username` from `whoami` (the CLI's own crate; `$USER` as the username fallback), `NO_COLOR` (non-empty) → `ui.color = "never"`, `VISUAL` else `EDITOR` → `ui.editor` — values config files override |
| `ConfigSource::User`         | `JJ_CONFIG` (a `PATH`-style list of files and/or directories, which REPLACES discovery — including when it is the empty string, which disables user config entirely), else `$HOME/.jjconfig.toml`, `<config_dir>/jj/config.toml`, `<config_dir>/jj/conf.d/`. Non-existent entries are skipped silently. `<config_dir>` = `$XDG_CONFIG_HOME` when absolute, else `$HOME/.config`. |
| `ConfigSource::Repo`         | `.jj/repo/config-id` (20 ASCII hex chars) → `<config_dir>/jj/repos/<id>/config.toml`; absent id file → legacy `.jj/repo/config.toml` |
| `ConfigSource::Workspace`    | `.jj/workspace-config-id` → `<config_dir>/jj/workspaces/<id>/config.toml`; absent id file → legacy `.jj/workspace-config.toml` |
| `ConfigSource::EnvOverrides` | `JJ_USER` → `user.name`, `JJ_EMAIL` → `user.email`, `JJ_TIMESTAMP`, `JJ_RANDOMNESS_SEED`, `JJ_OP_TIMESTAMP`, `JJ_OP_HOSTNAME`, `JJ_OP_USERNAME`, `JJ_EDITOR`, `JJ_PAGER` — values that override every file (`cli/src/config.rs:789-819` @ v0.44.0) |

then flattens `--when` / `[[--scope]]` blocks through
`jj_lib::config::resolve`. **Read-only by construction:** the CLI reaches the
repo/workspace layer through `jj_lib::secure_config::SecureConfig`, whose
`maybe_load_config` writes (creates directories, writes `metadata.binpb`,
generates a `config-id`, copies configs on repo-move detection, symlinks the
legacy file away); Zanshin resolves the `config-id` → path indirection by hand
instead, so nothing on disk is created, migrated or symlinked. Not layered: the
`--config`/`--config-file` command-line layer (Zanshin has no command line).
`config_resolver::resolve` runs with `command: None`, so `--when.commands` scopes
never match; `hostname` is `whoami::hostname()`, so `--when.hostnames` scopes match
as in the CLI (Story 9.27).

**The same stack opens the workspace (Story 9.27).** `zanshin_repo_open` / `_init` /
`_clone` / `_convert` build the `UserSettings` jj-lib signs commits and operations
with — and its working-copy knobs (`fsmonitor.*`, `snapshot.*`) — from this stack
(creation paths: the user-level stack is checked first, as the CLI's start-up, then
resolved for the NEW workspace's paths, as the CLI's `settings_for_new_workspace` —
normally no repo or workspace file exists there yet, but `--when.repositories` /
`--when.workspaces` scopes already apply), and every
snapshotting call (see *`precondition`* above) re-derives them first when a stack file
or the environment changed. There is
no hardcoded identity and no `.gitconfig` fallback: an empty identity is jj-lib's
default and is reported per committing call as the `jj.identity_missing` warning
(Story 9.32).

**Re-read per call (ADR-0002 extended to config).** Nothing is cached: config
files change externally and the op-heads watcher does not cover them, so a file
edited between two calls on the same handle is visible in the second.

**Success payload:** `Envelope<LogDefaults>`.

```
LogDefaults {
  log:                  string   // revsets.log
  log_graph_prioritize: string   // revsets.log-graph-prioritize
  short_prefixes:       string   // revsets.short-prefixes (see below)
  synthetic_elided:     bool     // ui.log-synthetic-elided-nodes
}
```

- **`short_prefixes` fallback rule.** `revsets.short-prefixes` falls back to the
  EFFECTIVE `revsets.log` when the key is ABSENT from every layer — never when it
  is present but empty. An explicit `""` means "prefix disambiguation disabled"
  and is returned verbatim (`cli/src/cli_util.rs:987-1009`, the citation the
  implementing code carries at `crates/zanshin-jj/src/config.rs:407`).
- **These are offers, not policy (FR-JJ-17).** `zanshin_graph_slice`'s
  `revset` / `prioritize` / `short_prefixes` remain caller pass-throughs;
  nothing Rust-side substitutes a config value for a caller argument. The UI
  pre-fills from this read and the user edits. The Dart compile-time constants
  (`defaultLogRevset`, `defaultGraphPrioritize`, `defaultShortPrefixes`,
  `defaultSyntheticElided`) stay as the BUILTIN pre-fills for a pre-handle UI;
  `RepoHandle.graphSlice`'s default parameter values are unchanged (Dart
  defaults must be compile-time constants).

**Error codes:**

| Code                  | Condition                                                                     |
|-----------------------|-------------------------------------------------------------------------------|
| `ffi.invalid_handle`  | Rust: `handle == 0`. Worker: unknown/closed `handleId`. `context` is absent.   |
| `jj.config_error`     | A config file is unreadable or not valid TOML, a `config-id` is not exactly 20 ASCII hex characters, or one of the four values has the wrong type; the file path or config key in `context`. Never a silent fall-back to the builtin defaults. |

The two `[revset-aliases]` failure levels differ, exactly as in the CLI:

- **Table level → error.** A layer whose `revset-aliases` key is not a table
  fails the call with `jj.config_error` (`cli/src/config.rs:1000-1007` @ v0.44.0, `ConfigGetError::Type`).
- **Entry level → warn and continue.** A single entry with a non-string value or
  a declaration jj-lib's parser rejects is skipped with a `jj.config_alias_invalid`
  warning (Story 9.32), and the call succeeds with every other alias loaded
  (`cli/src/config.rs:1009-1032` @ v0.44.0).
  A malformed alias DEFINITION is not caught at load time at all — it surfaces
  as `jj.revset_parse_error` when the alias is used.

**Dart worker integration:**

- `LogDefaultsCommand(handleId)` — worker looks up the raw handle (unknown id →
  `ffi.invalid_handle` envelope built Dart-side), calls
  `zanshinLogDefaults(raw)` (`lib/src/ffi/log_defaults.dart`), and replies
  `BufferResult` with the `Envelope<LogDefaults>` bytes.
- `ZanshinWorker.logDefaults(handleId)` → `LogDefaults` via
  `decodeLogDefaultsEnvelopeInternal`.
- `RepoHandle.logDefaults()` — closed-handle guard (`StateError`), delegates.
- Decode contract: `!ok` → `ZanshinFfiException(code, context)` carrying the
  envelope's `precondition` (always `null` here: this symbol runs no pre-verb
  snapshot) and `warnings` (Story 9.35); `ok` with a
  non-`LogDefaults` union variant → `ZanshinFfiException('ffi.unknown')`. Absent
  strings coalesce to `''`, so an explicitly empty `short_prefixes` and an
  absent one are indistinguishable Dart-side — Rust always writes all three.
