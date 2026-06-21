---
baseline_commit: 118f6d0160c6564dc255386773f3995f3ad4db60
---

# Story 3.9: Dart worker isolate bootstrap — `Isolate.spawn` + ports + correlation

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart developer setting up the worker isolate,
I want `app/lib/src/worker/{isolate,commands,responses,correlation,handle}.dart` implementing AR-AD-4 (sealed `WorkerCommand`, `SendPort`-based dispatch, `commandId` correlation, a **worker-side handle table** that hides raw pointers behind dense ids), plus a thin `app/lib/src/ffi/repo.dart` adapter that keeps `dart:ffi` inside the FFI layer, and the boot/DI wiring that makes the worker injectable,
so that the main isolate can issue typed commands to a single long-running worker that owns every FFI call, get back results to read via the generated FlatBuffers accessors (ADR-0001), and reference open repos by opaque `handleId` with a GC backstop (AR-AD-2) — raw addresses never leave the worker.

---

## ⚠️ CRITICAL — Read this before writing any code (reconciliations + the handle model)

The Story 3.9 acceptance criteria in `epics.md` (lines 2467–2557) were written **before ADR-0001 and before the current `@ffi.Native` native-asset binding style landed**. The ACs in *this* file are authoritative; the corrections below override the epics prose.

**R1 — Transport is FlatBuffers, never JSON.** The epics text says "JSON-parsed results", `Completer<String>`, `toJson()`, "returning JSON". **Superseded by ADR-0001.** FFI results are FlatBuffers `Envelope` bytes read via the generated typed accessors (`Envelope(bytes)`, `env.ok`, `env.error!.code`, `env.data as RepoHandle`). No JSON anywhere; no `toJson()`. (Same reconciliation Story 3.4a applied.)

**R2 — `dart:ffi` stays inside `app/lib/src/ffi/`.** project-context: *"`dart:ffi` boundary lives ONLY in `app/lib/src/ffi/`. No `dart:ffi` imports elsewhere in `lib/`."* So this story adds a thin Dart-typed adapter **`app/lib/src/ffi/repo.dart`** (`String` in → `Uint8List` envelope-bytes out) that owns all pointer marshalling (`CString` alloc/free, `FfiBuffer.fromToken`, byte-copy, `dispose`). Nothing under `app/lib/src/worker/` imports `dart:ffi` or `package:ffi`. **Consequence for the handle table (see model below): the worker stores the raw handle as an `int` (`Map<int,int>`), never as a `Pointer` — a `Pointer<Void>` field would pull `dart:ffi` into `worker/`.** (This corrects the epics' literal `Map<int, Pointer<Void>>`.)

**R3 — No `DynamicLibrary`; symbols bind via `@ffi.Native` native assets.** The epics step "Initialize the FFI library via `DynamicLibrary.process()`" is **obsolete**. `bindings.dart` uses `@ffi.Native<…>()` under `@ffi.DefaultAsset('package:zanshin/src/ffi/bindings.dart')`; these resolve process-wide and are callable from **any isolate in the group**. `Isolate.spawn` keeps the worker in the same group → it just calls the `repo.dart` adapter. **Add no `DynamicLibrary.open/process`.**

**R4 — Main-side handle wrapper uses Dart `Finalizer`, not `NativeFinalizer`.** A `NativeFinalizer` callback must be a **C function pointer** taking a single `Pointer<Void>` (that is exactly why `FfiBuffer` can use one — its callback is the C function `zanshin_buffer_free_token`). Sending a port message to close a repo is a **Dart** action, so the main-side `RepoHandle` uses a Dart **`Finalizer<int>`** whose callback enqueues a `CloseRepoCommand(handleId)`. The project-context "`NativeFinalizer` MUST be attached" rule governs wrappers that free a Rust pointer **via a C function** (`FfiBuffer`); the main-side `RepoHandle` holds only an opaque id and frees it **across the isolate boundary**, so `Finalizer` is correct.

**Handle-exposure model — Model A (chosen 2026-06-21: do it right from the start).** Raw pointers **never leave the worker**:
- The worker keeps `Map<int handleId, int rawHandle>` (dense, incrementing `handleId` → the raw `*mut Repo`-as-`u64` it got from FFI) + `int _nextHandleId`.
- On `open`/`init`/`clone` **success**, the worker reads `RepoHandle.handle` (raw) from the FFI envelope, stores it under a fresh `handleId`, and sends main a `HandleResult(handleId)` — the raw value is consumed in the worker and discarded from the wire. On **error**, it forwards the error envelope bytes (`BufferResult`) — no pointer in it.
- Main references repos only by `handleId` (wrapped in `RepoHandle`). Every handle-taking command (`close` now; `status`/`change`/… in Story 3.4b) carries the `handleId`; the worker resolves it via the table before calling FFI.
- **Validation payoff:** an unknown / already-removed `handleId` is rejected by the worker with a clean `ffi.invalid_handle` error — never a use-after-free. (Under Model B the raw pointer would cross to main and a stale int would be dereferenced as UB; Model A makes that structurally impossible.)
- **AD-2 holds:** only `app/lib/src/ffi/repo.dart`, called from the single worker isolate, ever materialises a pointer. The Dart-side table is bookkeeping over `int`s, not a Rust handle table.

This intentionally diverges from project-context's "responses are the same bytes that crossed FFI" **for the handle-returning commands only** (the worker substitutes a `handleId` for the raw pointer). Read-payload commands (3.4b) still forward FFI bytes verbatim. Rationale recorded in Q1.

**Scope — only the four `repo` commands exist today.** `zanshin_status`, `zanshin_change`, … don't exist yet (they land per-noun in Story 3.4b). This story defines `WorkerCommand` + the four committed commands (`open`/`init`/`clone`/`close`) and proves the round-trip with **init→open→close** against a real repo. Read commands are added incrementally by 3.4b (the sealed `switch` makes each a compile-checked arm).

**Pure-Dart story — no Rust, no `cargo make codegen`.** Consumes the committed `bindings.dart` / `envelope_zanshin.ffi_generated.dart` / `ffi_buffer.dart` as-is. The async event sink / `NativeCallable` / `zanshin_worker_init` stays **deferred to Story 3.6** (Q2; tracked in `epics.md` §3.6 + `deferred-work.md`); 3.9 only reserves the Dart-side event-port plumbing.

---

## Acceptance Criteria

1. **New files, no `dart:ffi` under `worker/`.** Created: `app/lib/src/ffi/repo.dart`; `app/lib/src/worker/commands.dart`, `responses.dart`, `correlation.dart`, `isolate.dart`, `handle.dart`. Each starts with `// SPDX-License-Identifier: MIT`. **No file under `app/lib/src/worker/` imports `dart:ffi` or `package:ffi`** (R2; `dart analyze --fatal-infos` enforces it, but design it right). Files are `snake_case.dart`.

2. **FFI adapter (`app/lib/src/ffi/repo.dart`, keeps `dart:ffi` in the FFI layer, R2).** Four pure-Dart-typed functions that own all marshalling:
   ```dart
   Uint8List zanshinRepoOpen(String path);
   Uint8List zanshinRepoInit(String path, int backend);
   Uint8List zanshinRepoClone(String url, String targetPath);
   Uint8List zanshinRepoClose(int rawHandle);   // takes the raw u64; FFI reconstructs the pointer in Rust
   ```
   Each: converts input `String`s to NUL-terminated C strings (`package:ffi` `toNativeUtf8()`) and frees them in a `finally` (Dart owns inbound strings — Rust borrows for the call); calls the matching `bindings.zanshin_repo_*`; wraps the returned `Pointer<ZanshinBuf>` in `FfiBuffer.fromToken`; **copies** the bytes (`Uint8List.fromList(buf.bytes)`); `dispose()`s the `FfiBuffer`; returns the owned copy. `zanshinRepoClose` passes the `int` straight to `bindings.zanshin_repo_close` (a `Uint64` — no `Pointer` is constructed Dart-side). The returned `Uint8List` is a standalone heap copy, safe to send across ports and outliving the freed native buffer.

3. **`WorkerCommand` sealed hierarchy (`commands.dart`).** `sealed class WorkerCommand { final int commandId; … }` + exactly four `final class` subtypes carrying only sendable (`int`/`String`) fields. **Handle-taking commands carry the opaque `handleId`, not a raw handle** (Model A):
   ```dart
   final class OpenRepoCommand  extends WorkerCommand { final String path; … }
   final class InitRepoCommand  extends WorkerCommand { final String path; final int backend; … }
   final class CloneRepoCommand extends WorkerCommand { final String url; final String targetPath; … }
   final class CloseRepoCommand extends WorkerCommand { final int handleId; … }
   ```
   **No `toJson()`** (R1). Instances are sent over the `SendPort` directly; the worker `switch`es on the sealed type (compiler-checked exhaustiveness). Read commands (`StatusCommand` …) are intentionally absent — they arrive with their 3.4b FFI noun.

4. **Worker→main response protocol (`responses.dart`).** A sealed internal response type:
   ```dart
   sealed class WorkerResponse { const WorkerResponse(); }
   final class HandleResult extends WorkerResponse { final int handleId; … }   // open/init/clone success
   final class BufferResult extends WorkerResponse { final Uint8List bytes; … } // read payloads + any error envelope
   ```
   The worker→main message couples a `commandId` with a `WorkerResponse` (e.g. a `(int, WorkerResponse)` record, or a small wrapper). Raw handles never appear in any `WorkerResponse`.

5. **`CommandCorrelator` (`correlation.dart`).** `Map<int, Completer<WorkerResponse>> _pending`; `int _nextId = 0`; `int allocateId() => _nextId++;`; `Future<WorkerResponse> register(int id)`; `void resolve(int id, WorkerResponse r)`; `void error(int id, Object e, [StackTrace? st])`; `void failAll(Object e)` (completes every pending completer with `e`, clears the map — used on worker death / close). Completer type is `WorkerResponse`, **not `String`** (R1).

6. **`ZanshinWorker` (`isolate.dart`) — typed API hides the wire format.**
   - `static Future<ZanshinWorker> start()` — spawns via `Isolate.spawn(_workerEntry, <bootstrap SendPort>)`, awaits the handshake (worker's command `SendPort`), returns ready. `Isolate.spawn` throwing → the returned `Future` errors (AC-12).
   - `Future<RepoHandle> openRepo(String path)` / `Future<RepoHandle> initRepo(String path, {required int backend})` / `Future<RepoHandle> cloneRepo({required String url, required String targetPath})` — send the command, await the `WorkerResponse`; on `HandleResult(id)` return `RepoHandle(this, id)` (AC-9); on `BufferResult(errorBytes)` parse the envelope and throw `ZanshinFfiException(code, context)` (AC-11).
   - `Future<Uint8List> send(WorkerCommand cmd)` — generic path for read commands (3.4b); awaits a `BufferResult` and returns its bytes (the `Envelope`); the caller inspects `env.ok`. Fails with `StateError('Worker is closed')` after `close()` — surfaced through the returned `Future` since the method is `async` (AC-13).
   - `void close()` — shuts the worker down (sentinel or `isolate.kill`), tears down ports, `failAll`s in-flight commands with a `StateError`. Idempotent.
   - Holds the correlator, the worker's command `SendPort`, its own response `ReceivePort`, and a reserved **event `ReceivePort`** (no traffic — AC-14).
   - Internal `Future<void> closeRepo(int handleId)` used by `RepoHandle` (sends `CloseRepoCommand`, awaits ack).

7. **`_workerEntry(SendPort bootstrap)` (top-level fn in `isolate.dart`) — owns the handle table.**
   1. Creates its command `ReceivePort` + the response channel back to main; sends its command `SendPort` over `bootstrap` (handshake).
   2. **No `DynamicLibrary`** (R3).
   3. Holds local state: `final handles = <int, int>{};` (handleId → rawHandle) and `var nextHandleId = 0;`.
   4. Message loop, exhaustive `switch` over `WorkerCommand`:
      - `open`/`init`/`clone` → call the `repo.dart` adapter → parse the returned `Envelope`; if `ok && dataType == PayloadTypeId.RepoHandle`: `final raw = (env.data as RepoHandle).handle; final id = nextHandleId++; handles[id] = raw;` reply `HandleResult(id)`. Else reply `BufferResult(bytes)` (error envelope forwarded verbatim).
      - `close` → `final raw = handles.remove(cmd.handleId);` if `raw == null` reply an error (worker `error`s the command with `ZanshinFfiException('ffi.invalid_handle', 'unknown or closed handleId: ${cmd.handleId}')` — Model A validation, no UB); else `repo.zanshinRepoClose(raw)` and reply `BufferResult(okBytes)`.
      - A dispatch that *throws* is reported as a transport error tagged with the `commandId` (→ `correlator.error`, AC-10); the loop never dies.

8. **`RepoHandle` + Dart `Finalizer` (`handle.dart`, R4, Model A).** `final class RepoHandle` wraps `(ZanshinWorker worker, int handleId)` and:
   - exposes `int get handleId` (so 3.4b read commands can do `worker.send(StatusCommand(h.handleId))`);
   - registers a Dart **`Finalizer<int>`** (`dart:core`, **not** `NativeFinalizer`) whose callback calls `worker.closeRepo(id)` and **swallows all errors** (a GC-time throw is unacceptable; a closed worker has already released everything for the process);
   - `Future<void> close()` — detaches the finalizer, guards double-close with an idempotent bool (mirroring `FfiBuffer.dispose`), and calls `worker.closeRepo(id)` once. Explicit `close()` swallows `StateError('Worker is closed')` but lets a genuine `ffi.invalid_handle` surface (it signals a bug). `handleId` values produced by the worker are always valid; `RepoHandle` is only ever constructed by the worker's typed methods.

9. **Open/init/clone round-trip.** `await worker.openRepo(path)` (or `initRepo`) resolves to a `RepoHandle` whose `handleId` is a small dense int (first is `0`). The raw pointer is **not** observable on the main side anywhere.

10. **Transport error propagation.** A command whose worker dispatch throws (or whose worker dies) `completeError`s its future. Worker death (response `ReceivePort` closes / `onError`/`onExit` fires) triggers `correlator.failAll(...)` so no caller hangs. (An FFI **error envelope** is *not* a transport error — see AC-11.)

11. **FFI error surfacing.** An FFI call that returns `ok == false` (e.g. `openRepo('/no/such/path')`) is surfaced as a **thrown `ZanshinFfiException`** carrying `env.error.code` + `env.error.context` from the typed handle methods (`openRepo`/`initRepo`/`cloneRepo`), because there is no useful handle to return. For the generic `send()` (read commands, 3.4b) the error envelope is returned as bytes for the caller to inspect. `ZanshinFfiException` is a small Dart type (define in `app/lib/src/worker/` — e.g. in `responses.dart` or a `ffi_exception.dart`; pure Dart, no `dart:ffi`).

12. **Edge case — isolate startup failure.** If `Isolate.spawn` throws, `ZanshinWorker.start()`'s `Future` completes with the error so the caller can retry/surface it. The bootstrap fallback log for this path uses `dart:developer` `log()` (project-context: the bootstrap-only fallback for records before FFI logging is up — e.g. isolate-spawn failures), **not** the `package:logging` façade.

13. **Edge case — command after close.** After `close()`, `send(...)`/`openRepo(...)`/etc. fail with `StateError('Worker is closed')` — the `_closed` guard in `_sendCommand` surfaces it through the returned `Future` (the typed methods are `async`, so it is delivered as a rejected `Future`, not a call-site throw), never a silently-dropped or forever-pending command.

14. **Edge case — async events reserved, no traffic.** A dedicated event `ReceivePort`/`SendPort` pair is created and wired (separate from the command/response channel, per AR-AD-4 "*do not multiplex events and command-responses on the same port*") but carries **no traffic**. No `NativeCallable`, no `zanshin_worker_init`, no watcher — those land in Story 3.6 (Q2). Reservation is structural only, so 3.6 adds the producer without reshaping `ZanshinWorker`.

15. **Logging discipline.** Worker- and main-side diagnostics use a `package:logging` `Logger` forwarded to Rust `tracing` via the existing façade (`app/lib/src/ffi/log_forwarder.dart` → `zanshin_log`, handle-free + isolate-safe per AR-P-5); **no second Dart sink**. The **only** `dart:developer` use is the spawn-failure bootstrap fallback (AC-12). Log `handleId` (the dense id) in worker spans where relevant — clean small ids are a Model-A benefit.

16. **Unit/integration tests (`app/test/worker/…`), real isolate + real cdylib** (project-context: "*boot the REAL `Isolate.spawn` flow and the real ffigen bindings against the real cdylib. No mocked isolates, no mocked FFI surface.*"):
    - **Round-trip:** `start()`; `initRepo(tempDir, backend: 0)` into a fresh `Directory.systemTemp` subdir → assert a `RepoHandle` with `handleId == 0`; `openRepo(sameDir)` → another `RepoHandle`; `handle.close()` → completes; (uses `init`, so no committed-fixture extraction and no network).
    - **FFI error → exception:** `openRepo('/no/such/path')` throws `ZanshinFfiException` with `code == 'jj.path_not_found'` (or `jj.repo_not_found` for a non-repo dir).
    - **Invalid handleId rejected (Model A):** sending `CloseRepoCommand` for an unknown id (e.g. close the same `RepoHandle` twice via the internal path, or fabricate) yields `ffi.invalid_handle`, **not** a crash.
    - **Command after close:** `close()` then any send throws `StateError`.
    - **Shutdown:** `close()` completes cleanly and any in-flight command future errors (no hang).
    - Pin `JJ_CONFIG`/`GIT_CONFIG_GLOBAL` to empty (deterministic CI vs local). `addTearDown` to delete temp dirs and `close()` worker + handles (leak-clean). Test names describe the scenario.

17. **Native-asset test build path proven (first-of-its-kind).** This is the **first Dart test that calls the real cdylib** (existing `app/test/ffi/*` avoid it deliberately). Confirm `flutter test` builds + links the native asset so `@ffi.Native` resolves at runtime; the cdylib must be built first (the gate runs `build-rust`/`test-cargo` before `test-flutter`). If `flutter test` does not auto-build native assets on the pinned Flutter `main` channel, fix the `test-flutter` task wiring in `Makefile.toml` (ordering / required experiment flag) and document it — **do not** fall back to mocking the FFI surface. Record the resolution in the Dev Agent Record.

18. **App-boot bootstrap + DI provision (the Dart↔Rust bridge lifecycle is in scope).** The worker is started and made injectable at boot (bridge plumbing, not UI):
    - `app/lib/src/worker/worker_module.dart`: `@module class WorkerModule { WorkerModule(this._worker); final ZanshinWorker _worker; @provides @singleton ZanshinWorker worker() => _worker; }` (mirrors `ZanshinFfiModule`).
    - `app/lib/main.dart`: in the existing boot sequence (after `initLogForwarding`) `final worker = await ZanshinWorker.start();`, add `WorkerModule` to `@Component([ZanshinFfiModule, WorkerModule])`, pass `MainComponent.create(workerModule: WorkerModule(worker))`. Run `dart run build_runner build`; commit the regenerated `main.inject.dart`.
    - Graceful shutdown is **best-effort**: expose `worker.close()` and note the hook point; the worker's FFI handles are process-lifetime and reclaimed by the OS at exit, so a missed shutdown close is not a leak that outlives the process. Don't add UI-lifecycle widgets to drive it.
    - **Boundary:** starting + providing the worker is in scope (Dart↔Rust); *which* widgets/features call `worker.…` is Ralph's UI scope — add no feature/screen call sites.

19. **Quality gate green.** `cargo make test` passes end-to-end — esp. `test-flutter`, `test-dart-analyze` (`--fatal-infos --fatal-warnings`), `test-dart-format`. No new analyzer infos/warnings; `analysis_options.yaml` (incl. hand-curated rules) passes. Rust gate unaffected (no Rust changes). No `// ignore:` without a `// WHY:`-style justification.

---

## Tasks / Subtasks

- [x] **T1 — FFI adapter** (AC: 2, R2) — `app/lib/src/ffi/repo.dart` (SPDX). `toNativeUtf8()` + `calloc.free` in `finally`; `FfiBuffer.fromToken` → `Uint8List.fromList(buf.bytes)` → `buf.dispose()` → return copy. `zanshinRepoClose(int)` passes the int straight through. Doc-comment ownership.

- [x] **T2 — Commands & responses** (AC: 3, 4, R1) — `commands.dart` (`sealed WorkerCommand` + 4 subtypes; `CloseRepoCommand.handleId`; no `toJson()`), `responses.dart` (`sealed WorkerResponse` = `HandleResult`/`BufferResult` + `ZanshinFfiException`).

- [x] **T3 — Correlation** (AC: 5, 10) — `correlation.dart`: `Map<int, Completer<WorkerResponse>>` + `allocateId`/`register`/`resolve`/`error`/`failAll`.

- [x] **T4 — Worker isolate + handle table** (AC: 6, 7, 9, 10, 11, 13, 14) — `isolate.dart`: `ZanshinWorker` (typed `openRepo`/`initRepo`/`cloneRepo`/`send`/`close`/`closeRepo`) + `_workerEntry` with `Map<int,int> handles` + `nextHandleId`; exhaustive dispatch → `repo.dart`; `HandleResult`/`BufferResult`; unknown-id → `ffi.invalid_handle`; reserved event port; worker-death → `failAll`; `_closed` guard → `StateError`.

- [x] **T5 — Main-side handle wrapper** (AC: 8, R4) — `handle.dart`: `RepoHandle(worker, handleId)`; Dart `Finalizer<int>` → `worker.closeRepo` (swallow-all); idempotent `close()`; expose `handleId`.

- [x] **T6 — Tests** (AC: 16, 17) — `app/test/worker/zanshin_worker_test.dart` (+ optional splits). Pin env; `systemTemp` + `addTearDown`. init→open→close round-trip; FFI-error→`ZanshinFfiException`; invalid-handleId→`ffi.invalid_handle`; command-after-close `StateError`; shutdown-completes-pending. Prove the native-asset build/link path; adjust `Makefile.toml` `test-flutter` only if required; record findings.

- [x] **T7 — App-boot bootstrap + DI** (AC: 18) — `worker_module.dart`; wire `main.dart` (`await ZanshinWorker.start()`, `@Component([…, WorkerModule])`, pass instance); `build_runner`; commit regenerated `main.inject.dart`. No feature/screen call sites.

- [x] **T8 — Gate** (AC: 19) — `cargo make test` green (focus `test-flutter`/`test-dart-analyze`/`test-dart-format`). No Rust/codegen changes.

---

## Dev Notes

### What you are building on (exact, verified — do not reinvent)

**Committed FFI surface you call (`crates/zanshin-ffi/include/zanshin_ffi.h` + `app/lib/src/ffi/bindings.dart`):**
```c
ZanshinBuf *zanshin_repo_open (const char *path);                       // -> Envelope (RepoHandle | error)
ZanshinBuf *zanshin_repo_init (const char *path, int32_t backend);      // backend 0=native,1=Git; else ffi.invalid_argument
ZanshinBuf *zanshin_repo_clone(const char *url, const char *target_path);
ZanshinBuf *zanshin_repo_close(uint64_t handle);                        // handle==0 -> ffi.invalid_handle; -> ok_empty envelope
void        zanshin_buffer_free_token(ZanshinBuf *token);
```
Dart bindings: `@ffi.Native<…>() external` under `@ffi.DefaultAsset('package:zanshin/src/ffi/bindings.dart')`; e.g. `ffi.Pointer<ZanshinBuf> zanshin_repo_open(ffi.Pointer<ffi.Char> path)`, `ffi.Pointer<ZanshinBuf> zanshin_repo_close(ffi.Uint64 handle)`. **Callable from the worker isolate** (same isolate group; native assets resolve process-wide — R3).

**`FfiBuffer` (`app/lib/src/ffi/ffi_buffer.dart`) — reuse:** `FfiBuffer.fromToken(Pointer<ZanshinBuf>)` (takes ownership, attaches `NativeFinalizer(zanshin_buffer_free_token)`); `Uint8List get bytes` is a **view over native memory** (throws after `dispose()`) — you **MUST copy** (`Uint8List.fromList(buf.bytes)`) before `dispose()` and before sending across a port; `void dispose()` is idempotent and detaches the finalizer.

**Generated FlatBuffers accessors (`app/lib/src/ffi/envelope_zanshin.ffi_generated.dart`) — verified names:**
```dart
final env = Envelope(bytes);
env.ok;                  // bool
env.error;               // FfiError?  -> error.code (String), error.context (String?)
env.dataType;            // PayloadTypeId?  (PayloadTypeId.NONE | PayloadTypeId.RepoHandle)
env.data;                // dynamic union → cast: (env.data as RepoHandle).handle  (int, the raw u64)
```
There is **no `dataAsRepoHandle()`** (that's C/Rust style) — read the union via `env.data as RepoHandle`. Builders also exist (`EnvelopeObjectBuilder`, `RepoHandleObjectBuilder`) if you ever need to synthesise a buffer Dart-side — not required by this story (the worker rejects bad ids via `correlator.error`, not a synthesised envelope). These accessors are pure Dart — safe in `worker/`.

**String marshalling (`package:ffi`, only in `repo.dart`):** `final p = path.toNativeUtf8(); try { token = bindings.zanshin_repo_open(p.cast()); } finally { calloc.free(p); }`. Dart allocates+frees inbound strings; Rust borrows for the call (AR-P-5).

**Logging façade (`app/lib/src/ffi/log_forwarder.dart`):** `forwardLogRecord` / `initLogForwarding` forward `package:logging` to Rust `tracing` via `zanshin_log` (isolate-safe). `dart:developer` `log()` only for the spawn-failure fallback (mirror `main.dart`'s uncaught-zone-error use).

**DI pattern (`main.inject.dart`, verified):** `MainComponent$Component.create({ZanshinFfiModule? zanshinFfiModule})` — modules are optional instance args defaulting to fresh. A `WorkerModule(worker)` holding the started instance is passed the same way (AC-18). `@module`/`@provides @singleton` mirror `ZanshinFfiModule` exactly.

### Critical correctness traps

- **Copy bytes before `dispose()` and before sending** — `FfiBuffer.bytes` is a native view; send a `Uint8List.fromList(...)` copy.
- **`@ffi.Native` works in the worker isolate** (same group) — no `DynamicLibrary` (R3).
- **`NativeFinalizer` is C-only → main-side handle uses Dart `Finalizer`** (R4).
- **Worker handle table is `Map<int,int>`, never `Map<int,Pointer>`** — a `Pointer` field drags `dart:ffi` into `worker/` (R2). The raw value is an `int`; only `repo.dart`/Rust turn it into a pointer.
- **Error envelope ≠ transport error** — FFI `ok==false` → throw `ZanshinFfiException` from typed methods (AC-11); only worker death / dispatch-throw → `completeError` (AC-10).
- **No `dart:ffi`/`package:ffi`/`dart:convert` under `worker/`** — `dart analyze --fatal-infos` will flag a stray import; design it out.
- **Sendability:** `WorkerCommand`/`WorkerResponse` carry only `int`/`String`/`Uint8List` → safe across isolates of one group. No closures/`Pointer`/`ReceivePort` fields.
- **Worker death must not hang callers** — wire `onExit`/`onError` (or detect the port closing) to `correlator.failAll(...)`.

### Why Model A (handle hidden behind dense id)

"Right from the start": raw addresses never reach the main isolate, `handleId`s are small + clean in logs (the `handle_id` tracing field becomes meaningful), and an unknown/stale id is rejected as `ffi.invalid_handle` by the worker instead of being dereferenced as UB. Costs: the worker is stateful (a `Map<int,int>`) and the open/init/clone responses are not byte-verbatim forwards (the worker substitutes the id). The Rust FFI is unchanged either way — this is a pure Dart-side choice (so it stays cheap to evolve). See Q1 for the Model B comparison that was rejected.

### Testing standards (project-context "Testing Rules" + "Worker / isolate testing")

- `app/test/worker/` mirroring `lib/src/worker/`. Real `Isolate.spawn`, real cdylib, real bindings — **never** mock isolate or FFI.
- cdylib must exist before `flutter test` (gate runs `build-rust`/`test-cargo` first). **AC-17 is real work** — you are the first Dart test calling the cdylib; verify the link path, fix `test-flutter` wiring if needed, don't mock.
- Use `initRepo` into `Directory.systemTemp` (no committed-fixture extraction, no network). `addTearDown` cleanup; close worker + handles (leak-clean).
- Pin `JJ_CONFIG`/`GIT_CONFIG_GLOBAL` to empty. Scenario test names: `worker_open_invalid_path_throws_ffi_exception`, `worker_close_unknown_handle_id_returns_invalid_handle`.

### Hard guardrails (reject-on-sight)

- **No JSON on the FFI/worker wire** (no `dart:convert`, no `toJson()`); FlatBuffers `Envelope` bytes only.
- **`dart:ffi` only in `app/lib/src/ffi/`** — worker imports the `repo.dart` adapter + generated accessors only.
- **No `Isolate.run` for repeated work** — this *is* the single long-running worker.
- **`sealed`** `WorkerCommand`/`WorkerResponse` for exhaustive `switch`.
- **Scope boundary (clarified 2026-06-21):** the Dart↔Rust **bridge** is in scope incl. worker boot + DI (AC-18); out of scope is **Flutter UI** (widgets, navigation, theming, a11y/i18n) and *feature/screen call sites* of `worker.…`.
- **No `DynamicLibrary`, no `flutter_rust_bridge`, no telemetry SDKs.**
- **SPDX first line** on every new `.dart`. `dart analyze --fatal-infos --fatal-warnings` is the bar; any `// ignore:` needs a `// WHY:` (see `main.dart:75`).

### Project Structure Notes

- New: `app/lib/src/ffi/repo.dart`; `app/lib/src/worker/{commands,responses,correlation,isolate,handle,worker_module}.dart`; `app/test/worker/zanshin_worker_test.dart` (+ optional splits).
- Modified: `app/lib/main.dart` (start worker + `@Component`), regenerated `app/lib/main.inject.dart` (committed). `Makefile.toml` `[tasks.test-flutter]` **only if** the native-asset build/link needs ordering/flag (AC-17). No Rust / no `cargo make codegen`.
- A `worker/` barrel is optional (only if it shortens imports). Module-by-noun: `repo.dart` sibling of `zanshin_version.dart`/`log_forwarder.dart`/`ffi_buffer.dart`.

### References

- [Source: `_bmad-output/planning-artifacts/epics.md#Story 3.9`] (lines 2467–2557 — JSON/`DynamicLibrary`/`NativeFinalizer`/`Map<int,Pointer>`/`StatusCommand` phrasing superseded here; AR-AD-4 at line 185).
- [Source: `docs/adr/0001-ffi-data-transport-flatbuffers.md`] — FlatBuffers transport.
- [Source: `_bmad-output/project-context.md`] — "Worker isolate (Dart, AD-4)", Dart rules (`dart:ffi` boundary; `sealed WorkerCommand`; `NativeFinalizer`; `dart:developer` bootstrap-only), AR-P-5 (`zanshin_log`), Testing Rules.
- [Source: `app/lib/src/ffi/ffi_buffer.dart`] — `FfiBuffer.fromToken`/`bytes` (native view!)/`dispose`; the `NativeFinalizer`-needs-a-C-callback fact behind R4.
- [Source: `app/lib/src/ffi/bindings.dart`] — `@ffi.Native`/`@ffi.DefaultAsset` (R3).
- [Source: `app/lib/src/ffi/envelope_zanshin.ffi_generated.dart` + `app/test/ffi/envelope_fixture_test.dart`] — `Envelope(bytes)`, `env.ok`, `env.error!.code`, `env.data as RepoHandle`, `RepoHandle.handle`, `PayloadTypeId`.
- [Source: `app/lib/src/ffi/zanshin_version.dart`] — the "FFI-layer module exposing a Dart-typed value" pattern to mirror for `repo.dart`.
- [Source: `crates/zanshin-ffi/include/zanshin_ffi.h`] — `zanshin_repo_*` signatures + error codes.
- [Source: `app/lib/main.dart` + `app/lib/main.inject.dart`] — boot sequence, `dart:developer` fallback, DI `create({Module?})` pattern.
- [Source: `Makefile.toml` `[tasks.test]`/`[tasks.test-flutter]`] — gate order; the `flutter test` task to adjust if AC-17 requires.
- [Source: `_bmad-output/implementation-artifacts/3-4a-repo-ffi-wrappers-…md`] — the FFI layer this consumes; `close(u64)`; reconciliation precedent.
- Previous-story learnings: [3-4a] handle is a `u64`; `FfiBuffer.fromToken` is the token consumer; generated accessors are the only sanctioned reader.

---

## Open Questions

- **Q1 — RESOLVED (2026-06-21): Model A (worker-side handle table, dense ids).** Ralph chose to do it right from the start. Raw pointers stay in the worker; main sees only opaque `handleId`s; unknown ids are rejected as `ffi.invalid_handle` instead of UB. The rejected **Model B** (forward FFI bytes verbatim; raw pointer crosses to main as an inert int; `close(rawInt)`) was simpler and matched project-context's "same bytes that crossed FFI" literally, but exposed addresses in main/logs and gave UB on a stale int. Model A is a pure Dart-side choice — the Rust FFI is identical — so it stays cheap to evolve.

- **Q2 — Defer the Rust `zanshin_worker_init` / event sink to Story 3.6 (confirmed; now tracked).** This story does **not** add a no-op `zanshin_worker_init` Rust stub now; the whole `NativeCallable` event mechanism is designed and built in 3.6 with the watcher. 3.9 reserves only the Dart-side event-port plumbing (AC-14). Recorded in `epics.md` §3.6 and `deferred-work.md` so it is not forgotten. (No action needed unless you'd rather pin the Rust symbol now — that would make 3.9 a Rust+codegen story.)

- **Q3 — RESOLVED (2026-06-21): worker bootstrap + DI is in scope** (AC-18). The Dart↔Rust bridge incl. boot + DI is Claude's; only Flutter UI + feature call sites are Ralph's.

---

## Dev Agent Record

### Agent Model Used
claude-sonnet-4-6[1m] (2026-06-21)

### Debug Log References
None — no blocking issues encountered.

### Completion Notes List
- T1: `app/lib/src/ffi/repo.dart` — four Dart-typed FFI adapter functions. Imports `bindings.dart` without alias so `ZanshinBuf` is in scope for type annotations. Pattern: `toNativeUtf8` → `try`/`finally calloc.free` → `FfiBuffer.fromToken` → `Uint8List.fromList(buf.bytes)` → `buf.dispose()`. `zanshinRepoClose(int)` passes raw handle straight through (no Dart Pointer constructed).
- T2: `commands.dart` + `responses.dart` — `sealed WorkerCommand` (4 subtypes: Open/Init/Clone/CloseRepoCommand) + `sealed WorkerResponse` (HandleResult/BufferResult) + `ZanshinFfiException`. No JSON/toJson anywhere.
- T3: `correlation.dart` — `CommandCorrelator` with `Map<int, Completer<WorkerResponse>>`, `allocateId`/`register`/`resolve`/`error`/`failAll`.
- T4: `isolate.dart` — `ZanshinWorker` (main-side, typed API) + top-level `_workerEntry(_WorkerInit)`. Bootstrap record `typedef _WorkerInit = (SendPort, SendPort, SendPort)` carries bootstrapSP, responseSP, eventSP. Worker owns `Map<int, int> handles` (handleId→rawHandle). Exhaustive sealed `switch` dispatches to `repo_ffi.*`. Unknown handleId → synthesised `ffi.invalid_handle` FlatBuffers envelope. Worker death detected via `addOnExitListener`/`addErrorListener` → `correlator.failAll`. Reserved event port wired but carries no traffic (3.6 deferred). Name collision between generated `fbs.RepoHandle` and Dart `RepoHandle` resolved via `import 'envelope_zanshin.ffi_generated.dart' as fbs`.
- T5: `handle.dart` — `RepoHandle(ZanshinWorker worker, int handleId)` with Dart `Finalizer<(ZanshinWorker, int)>` (not NativeFinalizer — R4). Idempotent `close()` catches concurrent-close `StateError` via `catch(e) { if (e is! StateError) rethrow; }` (avoids `avoid_catching_errors` lint on `StateError` subclass). GC backstop: `worker.closeRepo(handleId).catchError((_) {}).ignore()`.
- T6: `test/worker/zanshin_worker_test.dart` — 7 tests across 5 groups. All pass against the REAL cdylib (first Dart test suite to do so). AC-17 finding: `flutter test` on Flutter main channel automatically invokes `hook/build.dart` via the Dart hook system, which calls `native_toolchain_rust` to build/link the cdylib. With `test-cargo` running first in the Makefile.toml chain, the Rust artifacts are already in `target/` — no recompile needed. NO changes to `Makefile.toml` required.
- T7: `worker_module.dart` + `main.dart` updated + `main.inject.dart` regenerated via `dart run build_runner build`. The module starts the worker itself via an `@asynchronous` provider (`Future<ZanshinWorker> worker() => ZanshinWorker.start()`); `main.dart` forces creation with `await mainComponent.worker` after `initLogForwarding`, and a `@provisionListener` (`_WorkerLifecycleListener`) wires an `AppLifecycleListener` for best-effort macOS shutdown. (Earlier draft said "`WorkerModule(worker)` passed to `MainComponent.create`" — superseded; the module owns `start()`, no pre-started instance is injected.) inject_generator warning "ZanshinWorker registered but never used by any component entry point" is expected — no feature/screen call sites (UI scope).
- T8: `cargo make test` green. 52 Rust unit + 17 Rust integration + 15 Flutter (8 existing + 7 new worker) = 84 total tests. `dart analyze --fatal-infos --fatal-warnings`: 0 issues. `dart format`: 0 changes. `clippy pedantic`: clean. `cargo deny`: clean.

### File List
- `app/lib/src/ffi/repo.dart` (new)
- `app/lib/src/worker/commands.dart` (new)
- `app/lib/src/worker/responses.dart` (new)
- `app/lib/src/worker/correlation.dart` (new)
- `app/lib/src/worker/isolate.dart` (new)
- `app/lib/src/worker/handle.dart` (new)
- `app/lib/src/worker/worker_module.dart` (new)
- `app/test/worker/zanshin_worker_test.dart` (new)
- `app/lib/main.dart` (modified — added `ZanshinWorker.start()` + WorkerModule DI)
- `app/lib/main.inject.dart` (regenerated — added WorkerModule + ZanshinWorker providers)
- `_bmad-output/implementation-artifacts/sprint-status.yaml` (modified — status: review)

### Change Log

| Date | Change |
|------|--------|
| 2026-06-21 | Story created (ready-for-dev). ACs reconciled JSON→FlatBuffers (R1), `dart:ffi`-boundary adapter (R2), `@ffi.Native` native assets / no `DynamicLibrary` (R3), Dart `Finalizer` for main-side handle (R4); scoped to the four committed `repo` commands; events deferred to 3.6. Pure-Dart story. |
| 2026-06-21 | Scope clarification (Ralph): worker boot + DI in scope (AC-18; Q3 resolved). |
| 2026-06-21 | **Handle model → Model A (Ralph: "do it right from the start").** Worker-side `Map<int handleId,int rawHandle>` hides raw pointers; dense ids; unknown-id → `ffi.invalid_handle` (no UB). Added `responses.dart` (`WorkerResponse` = `HandleResult`/`BufferResult`) + `ZanshinFfiException`; `ZanshinWorker` typed methods (`openRepo`/`initRepo`/`cloneRepo`); correlator now `Completer<WorkerResponse>`; corrected Dart union read to `env.data as RepoHandle` (no `dataAsRepoHandle()`). Q1 resolved. Q2 (Rust `zanshin_worker_init`) tracked in epics §3.6 + deferred-work.md. |
| 2026-06-21 | Implementation complete. T1–T8 all done. 84 tests green. AC-17: `flutter test` auto-builds native assets on Flutter main — no Makefile.toml changes needed. |

---

## Review Findings

**Code review — 2026-06-21** (adversarial: 4 parallel layers — Blind Hunter, Edge Case Hunter, Acceptance Auditor, Concurrency/Isolate-Lifecycle — + per-finding adversarial refutation). Baseline `118f6d0`. 25 raw findings → 8 confirmed → 6 after dedup. **2 decision-needed, 4 patch, 0 deferred, 17 dismissed as noise.**

### Decision-needed

- [x] [Review][Decision] AC-13 "synchronous" throw is not actually synchronous (RESOLVED 2026-06-21: option (a) — reword spec; becomes a doc Patch) — The typed methods (`openRepo`/`initRepo`/`cloneRepo`/`send`) are `async`, so the `_closed` guard in `_sendCommand` (`isolate.dart:225-232`) surfaces as a *rejected Future*, never a call-site throw. The behavioral contract (StateError delivered, no hang, no silent drop) holds and is tested, but the literal AC-13/AC-6 "synchronously" wording is unmet and the test (`zanshin_worker_test.dart:157-167`) only asserts future-rejection. Options: (a) reword AC-13/AC-6 to drop "synchronously" (zero code change), or (b) make the four methods non-`async` (call `_sendCommand` outside `await`) for a true synchronous throw + add `expect(() => …, throwsStateError)`.
- [x] [Review][Decision] AC-18 scope: app-lifecycle shutdown driver + async DI deviate from spec (RESOLVED 2026-06-21: keep code as-is, only correct the inaccurate T7 note; becomes a doc Patch) — (1) `worker_module.dart:45-58` wires an `AppLifecycleListener(onExitRequested: …)` that drives `worker.close()`, but AC-18 said "expose `worker.close()` and **note the hook point** … Don't add UI-lifecycle widgets to drive it" (and `feedback-scope-bridge-is-claudes-ui-is-ralphs` reserves Flutter UI for Ralph); `AppLifecycleListener` is a `WidgetsBindingObserver` from `package:flutter/widgets.dart`, on the bridge↔UI boundary. (2) The module uses `@asynchronous Future<ZanshinWorker> worker() => ZanshinWorker.start()` instead of AC-18's prescribed pre-started `WorkerModule(worker)`; the Dev Agent Record T7 note ("`WorkerModule(worker)` passed to `MainComponent.create`") inaccurately describes the shipped code. Behaviorally harmless; needs an author call.

### Patch

- [x] [Review][Patch] start() can hang forever if the worker dies before the handshake send [app/lib/src/worker/isolate.dart:102] — `await bootstrap.first` is not raced against exit/error or a timeout; the `_exitSub`/`_errorSub` consumers are wired only *after* the handshake resolves. If `_workerEntry` throws before `bootstrapSP.send` (`:294`), `start()` neither completes nor errors → boot deadlock via `main.dart` `await mainComponent.worker`. Empirically reproduced. Trigger near-unreachable today (pre-handshake window only runs `initLogForwarding`, internally try/catch'd), but the author's comment (`:95-96`) shows this case was *intended* to be covered and the fix is cheap. Fix: resolve `start()` via a single `Completer<SendPort>` completed by EITHER the handshake OR an exit/error notification, plus a `.timeout()`; close all 5 ports + kill on failure.
- [x] [Review][Patch] `_onWorkerDeath` never kills the isolate it declares dead [app/lib/src/worker/isolate.dart:139-147] — Spawned with `errorsAreFatal:false`, so an uncaught async worker error fires `addErrorListener` but does NOT terminate the isolate. `_onWorkerDeath` sets `_closed`, `failAll`s, and `_teardown`s — but never `_isolate.kill()` (only the deliberate `close()` does). Result: a "dead" main-side worker while the real isolate stays alive holding all `*mut Repo` handles. No live trigger in 3.9 (dispatch is sync + fully try/catch'd) — becomes reachable once 3.6 adds the future-spawning event sink. One-line fix: `_isolate.kill(priority: Isolate.immediate)` inside `_onWorkerDeath` (the `_closed` guard makes it idempotent). Best fixed before 3.6.
- [x] [Review][Patch] Tests don't pin JJ_CONFIG/GIT_CONFIG_GLOBAL (determinism guardrail) [Makefile.toml:75-79] — project-context "Property of every test suite" + AC-16 require pinning so CI and local runs match; the Rust suites already pin both to `""` (`repo_ffi.rs:29-30`). The Flutter path is unpinned (`[tasks.test-flutter]` is a bare `flutter test`; the gap is documented at `zanshin_worker_test.dart:15-21`). Dart can't set process env in-process, so fix in the Makefile: `env = { JJ_CONFIG = "", GIT_CONFIG_GLOBAL = "" }` on `[tasks.test-flutter]`, and update the test note to point at it.
- [x] [Review][Patch] Round-trip test uses backend:1 (Git), not AC-16's backend:0 (native/simple) [app/test/worker/zanshin_worker_test.dart:51] — AC-16 specifies `initRepo(tempDir, backend: 0)`; tests use `backend: 1` (also `:131`), leaving the native/simple init path untested. The inline rationale ("Git backend … no user.email needed") is wrong: `zanshin-jj` `make_settings()` hard-codes user identity, so backend 0 works with no env pinning. Fix: switch both to `backend: 0` and correct/drop the misleading notes (`:18`, `:50`).
- [x] [Review][Patch] Reword AC-13/AC-6 to drop "synchronously" [this story §Acceptance Criteria AC-6, AC-13] — Resolution of decision D1. `async` typed methods cannot throw synchronously by construction; the behavioral contract (StateError delivered, no hang/silent-drop) + the existing future-rejection test stay. Spec-wording fix only, no code change.
- [x] [Review][Patch] Correct Dev Agent Record T7 note [this story §Dev Agent Record → Completion Notes T7] — Resolution of decision D2. T7 says "`WorkerModule(worker)` passed to `MainComponent.create`", but the shipped module uses `@asynchronous Future<ZanshinWorker> worker() => ZanshinWorker.start()` with `await mainComponent.worker` in `main.dart` (plus an `AppLifecycleListener` shutdown hook, kept by decision). Note-only fix; the code is intentionally retained.
