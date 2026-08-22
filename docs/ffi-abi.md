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
(`handleId → raw *mut RepoSession`) and returns an opaque `handleId` to the caller.

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
retry will see an existing repo — same posture as other post-init failures);
`open` leaves no residue. Post-arm watch degradation (e.g. an FS error after a
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
void _onNativeEvent(ffi.Pointer<ZanshinBuf> token) {
  final buf = FfiBuffer.fromToken(token);
  try {
    /* decode buf.bytes, forward */
  } finally {
    buf.dispose();
  }
}
```

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
payload (`RepoHandle { handle, session_id }`). The worker's
`_onNativeEvent`/`onEvent` handler looks up `sessionToId[sessionId]` to recover
the small dense `handleId` before constructing the public `RepoEvent` sent to
main; an unknown session id (a benign close race) is logged and dropped, never
thrown. Raw pointers still never reach the main isolate (Model A holds), and
the raw handle is used only for calls back INTO the cdylib
(`zanshin_repo_close`, read wrappers).

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

- `lib/src/ffi/events.dart` — the only new file besides `bindings.dart`/the
  generated FlatBuffers accessors allowed to import `dart:ffi`. Owns the
  `NativeCallable.listener`, the try/catch-wrapped native handler, and
  `registerEventSink` / `closeEventSink` / `unregisterEventSink`.
- `lib/src/worker/events.dart` — pure Dart `RepoEvent` sealed family
  (`OpHeadsChangedEvent` / `WorkingCopyHeartbeatEvent` / `WatchErrorEvent` /
  `ProgressEvent`), exported from `zanshin_core.dart`.
- `ZanshinWorker.events` — a broadcast `Stream<RepoEvent>` fed by the
  previously-unused (Story 3.9) event `SendPort`.
- `ZanshinWorker.close()` is now `Future<void>`: it sends a `ShutdownCommand`
  the worker uses to run the shutdown ordering above, then awaits an ack
  (bounded timeout) before killing the isolate as a backstop.

---

## GraphSlice payload (Story 4.2)

The lane-assigned commit graph (Story 4.1, `zanshin_graph::Row`) crosses FFI
as a `GraphSlice` member of the `Payload` union (`schemas/envelope.fbs`) — no
JSON, no `schema_version` (ADR-0001). **No extern fn yet**: Story 4.6 adds the
`zanshin_graph_*` wrappers that call the Rust builder
`zanshin_ffi::graph::graph_slice_to_envelope(&[Row]) -> Vec<u8>` (infallible,
always `ok == true`) and the Dart worker command that feeds
`decodeGraphSliceEnvelopeInternal` (`packages/zanshin_core/lib/src/ffi/graph.dart`).

```
enum GraphEdgeKind : byte { Direct, Indirect, Missing }   // == zanshin_graph::EdgeKind order

GraphRowEdge {
  target:      string          // parent commit id, hex
  target_lane: uint            // meaningful ONLY when kind != Missing (see below)
  kind:        GraphEdgeKind
}

GraphRow {
  commit_id:   string          // commit id, hex — rows are keyed by COMMIT id, not change id
  lane:        uint
  color_idx:   uint            // lane % PALETTE_SIZE (8)
  edges:       [GraphRowEdge]  // one per input parent edge, same order
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
- **`total_rows` semantics.** WIP return-all: `total_rows == rows.length`.
  Story 4.4 windowing may set `total_rows > rows.length` later (a breaking
  in-place change, allowed in WIP).
- **Row order** is the stream / `jj log` order (topo-grouped, children before
  parents); one `GraphRow` per `Row`, one `GraphRowEdge` per `RowEdge`, verbatim
  strings (no escaping).
- **Decode contract (Dart).** `!ok` → `ZanshinFfiException(code, context)`;
  `ok` with a non-`GraphSlice` union variant → `ZanshinFfiException('ffi.unknown')`
  (discriminant guard, same as every other payload decoder). An out-of-range
  `GraphEdgeKind` byte surfaces as the generated `StateError` (cdylib/bindings
  version-skew or corruption — crash loudly, not recoverable; the same by-design
  rule as `RepoKind` in `repo_detect.dart`).
- **Reachability (until 4.6).** The Dart models/decoder in `graph.dart` are not
  exported from `package:zanshin_core/zanshin_core.dart` and no worker command
  feeds them yet; until Story 4.6 wires the extern fn they are reachable only via
  the `src/` import used by the decode-contract tests.
