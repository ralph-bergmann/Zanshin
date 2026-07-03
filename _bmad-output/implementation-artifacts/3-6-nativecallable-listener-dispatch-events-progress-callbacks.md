# Story 3.6: NativeCallable.listener dispatch — events + progress callbacks

---
baseline_commit: bd41c969ef0688933927f066cde721ba9ae20832
---

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Rust developer wiring async signals,
I want the Story 3.5 watcher event stream and the FR-FFI-8 progress contract delivered to Dart through **one** process-global `NativeCallable.listener` sink — armed inside every handle-producing repo wrapper (AR-G-5), serialized as FlatBuffers `Envelope` payloads (ADR-0001), demultiplexed per-repo in the worker isolate, and surfaced to the main isolate as a typed event `Stream` on the reserved event port,
so that FR-FFI-4 (async Rust→Dart signals), FR-RX-1 (op_heads change → Dart callback, functional), and AR-AD-4's event-stream-port pattern work end-to-end, and Epic 6's fetch progress (6-4a) later rides the identical channel with zero new mechanism.

## ⚠️ Read this first — this story owns the event-sink surface end-to-end

Per the 2026-06-21 correction in epics.md §3.6: Story 3.9 did **NOT** stub `zanshin_worker_init`; **this story designs and ships the whole surface**: the FlatBuffers event payloads, the process-global sink + registration extern fns, the per-repo dispatch thread, watcher arming inside the four handle-producing wrappers, the Dart `NativeCallable.listener` + event-stream wiring, the graceful worker shutdown that the callable lifecycle now forces, and the two regression tests deferred from 3.9's code review. Story 3.5 deliberately stopped at the standalone `watcher.rs` subsystem and deferred to here: *"repo_open arming (AR-G-5), extern fn, .fbs/codegen, Dart, envelope const"* — all of that is this story.

Three design decisions shape everything below. They follow directly from ADR-0001/0002 and the epic's own re-sequencing note, and are **recommendations you implement as written unless Ralph overrides them** (see [Open Questions](#open-questions-confirm-beforeduring-implementation)):

1. **ONE process-global sink, not per-handle callback registries.** The epic's Story 3.6 ACs (per-handle registry, `zanshin_watcher_register(handle, cb)`, `zanshin_progress_register(handle, op_id, cb)`) are superseded by the epic's own sequencing note ("the async event sink is **process-global**, registered once", epics.md:1803) and project-context ("Same mechanism for watcher events AND progress notifications — no special-case channels"). Events carry a **repo/handle correlation id** in the payload — ADR-0002 states this as a hard requirement for 3.6 ("Watcher events carry a repo/handle correlation id … on the event port", ADR-0002:57). Demux happens Dart-side in the worker (which already owns the raw↔handleId table). See [R3](#reconciliations-stale-epic-acs-corrected).

2. **The Rust handle becomes `RepoSession { repo, watcher, dispatch }` (composite Box).** ADR-0002 defines the handle as "warm `Workspace` loader **+ owner of the repo's op-heads watcher**" (ADR-0002:34). Arming in `repo_open` therefore means the leaked `Box<Repo>` becomes a leaked `Box<RepoSession>` owning the `Watcher` + its dispatch thread; `zanshin_repo_close` tears all three down. This touches every handle-dereferencing wrapper (5 read wrappers + close) mechanically — `extern "C"` **signatures are unchanged** (handles stay `u64`), so no Dart-visible ABI change from this refactor. See [Design → RepoSession](#the-repo-handle-becomes-reposession).

3. **The `NativeCallable` lifecycle forces a graceful worker shutdown.** `NativeCallable.listener`'s pointer is UB to invoke after `close()` (api.dart.dev), and it keeps the worker isolate alive until closed. Today `ZanshinWorker.close()` just `kill()`s the isolate — with Rust dispatch threads holding the sink pointer, that becomes a use-after-free factory (every Dart test that opens a repo then `close()`s would race it). This story adds a `ShutdownCommand` handshake: worker closes all repos (joins all dispatch threads) → unregisters the sink → closes the callable → acks → main kills as backstop. `close()` becomes `Future<void>`. See [Design → Shutdown](#lifecycle-the-shutdown-protocol-load-bearing).

**In scope:** `schemas/envelope.fbs` additions + codegen; `crates/zanshin-ffi/src/events.rs` (sink + extern fns + serialization); `RepoSession` + arming in `repo.rs` (all four producers: open/init/clone/**convert**); `watcher.io_error` flip to Emitted; `packages/zanshin_core` `ffi/events.dart` + worker event wiring + shutdown protocol + `Stream<RepoEvent>`; the two 3.9-review regression tests; Rust + Dart tests; `docs/ffi-abi.md` + `docs/rust-error-codes.md`.

**Out of scope:** the app-level E2E watcher test + storm sub-test + FR-RX-4 recovery assertion (**Story 3.10**); any real progress producer (`git fetch` — **6-4a**); Watchman detection (deleted 3.7); multi-repo *project-overview* watcher orchestration (deferred-work.md — later story); Flutter UI consumption of the stream (Ralph).

## Acceptance Criteria

> Reconciled from epics.md Story 3.6 (lines 2361–2434). The epic ACs predate ADR-0001 (JSON events, `schema_version`, `progress.v1.schema.json`) and the process-global-sink note; corrections are flagged in [Dev Notes › Reconciliations](#reconciliations-stale-epic-acs-corrected). Latency is asserted as *arrival* with a generous timeout, never a tight bound (NFR-P-4 soft in WIP; 3-5 R5 precedent).

### Wire schema (FlatBuffers, ADR-0001)

1. **`schemas/envelope.fbs` gains the event payloads** (appended **after** `RepoDetect` in the `Payload` union so existing discriminants don't shift — 3-4c convention):
   ```fbs
   enum WatcherEventKind : byte { OpHeadsChanged, WorkingCopyHeartbeat, WatchError }

   table WatcherEvent {
     repo_handle: uint64;     // correlation id == the u64 the Dart worker holds (ADR-0002:57)
     kind: WatcherEventKind;
     paths: [string];         // absent for WatchError (null-for-absence)
     message: string;         // set only for WatchError
   }

   table Progress {
     repo_handle: uint64;     // same correlation id; producer lands in 6-4a
     operation: string;       // e.g. "fetch"
     progress: float;         // ∈ [0, 1]
     message: string;
   }

   union Payload { …existing…, RepoDetect, WatcherEvent, Progress }
   ```
   No `schema_version` field anywhere (ADR-0001 / R2). The `RepoHandle` table's doc comment ("the Rust `*mut Repo` reinterpreted…") is updated to say `*mut RepoSession` (R6). `cargo make codegen` is run; all four generated artifacts are committed (`envelope_generated.rs`, `zanshin_ffi.h`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart`).

### Rust — sink, dispatch, arming

2. **New module `crates/zanshin-ffi/src/events.rs`** (SPDX line 1; `pub mod events;` in `lib.rs`; every `pub` item doc-commented). Defines:
   - `pub type EventCallback = unsafe extern "C" fn(event: *mut ZanshinBuf);` — one pointer arg so it is also `NativeFinalizer`-shape-compatible on the Dart side.
   - A process-global sink slot (e.g. `static SINK: Mutex<Option<EventCallback>>`). This is registration state, **not** a handle — it does not violate the no-locking-around-handles rule (AD-2); the dispatch threads + the registering worker thread are genuinely concurrent, so synchronization is mandatory. Document this with a `// WHY:`.
   - `pub(crate) fn dispatch(event_bytes: Vec<u8>)` — if a sink is registered, wrap via `vec_into_token` and invoke the callback (**ownership of the token transfers to Dart**, freed by `FfiBuffer.fromToken`'s finalizer path); if no sink is registered, drop the event with a `tracing::debug!` (serialize-then-check is fine; checking first and skipping serialization is better).
   - The FlatBuffers builders for the two payloads (noun module owns its domain mapping — 3.4b convention): `watcher_event_to_envelope(repo_handle: u64, &WatcherEvent) -> Vec<u8>` and `progress_to_envelope(repo_handle: u64, operation: &str, progress: f32, message: &str) -> Vec<u8>`, both producing `ok == true` envelopes with the respective payload.

3. **Registration extern fns — infallible, `void`-returning** (precedent: `zanshin_log` / `zanshin_logging_init`; registration of a pointer cannot meaningfully fail, so no `Envelope` overhead):
   ```rust
   #[no_mangle] pub extern "C" fn zanshin_events_register(callback: Option<EventCallback>);
   #[no_mangle] pub extern "C" fn zanshin_events_unregister();
   ```
   - `register(Some(cb))` stores the callback, **overwriting** any previous one (worker restart re-registers; document). `register(None)` is a no-op with a `tracing::warn!` (defensive; Dart never passes null).
   - `unregister()` clears the slot unconditionally; idempotent. (No compare-and-clear sophistication: production has exactly ONE worker per process — document that assumption in ffi-abi.md. The main isolate's death-path cleanup, AC 13, relies on unconditional clear since it cannot know the dead worker's pointer.)
   - Both are `catch_unwind`-wrapped (no panic across FFI) and, like `zanshin_log`, **handle-free and callable from any isolate** — explicitly exempt from the single-consumer rule (AD-2). This matters: the *main* isolate calls `unregister` on unexpected worker death (AC 13).
   - The epic's placeholder name `zanshin_worker_init` is dropped (the epic itself says "or whatever the registration entry point is named"); `zanshin_events_<verb>` follows AR-P-1 naming. See [OQ-2](#oq-2-extern-fn-naming--recommend-zanshin_events_registerunregister).

4. **The handle becomes `RepoSession`.** `repo.rs` (or `handle.rs` — keep it with the producers in `repo.rs`) defines `struct RepoSession { repo: Repo, watcher: Option<Watcher>, dispatch: Option<JoinHandle<()>> }` (Options so teardown can `take()`). All four handle producers — `zanshin_repo_open`, `zanshin_repo_init`, `zanshin_repo_clone`, **`zanshin_repo_convert`** (it returns a `RepoHandle` too, repo.rs:311) — construct it via one shared arm-helper. All five read wrappers (`status.rs:118`, `change.rs:153`, `op_log.rs:97`, `bookmarks.rs:89`, `remotes.rs:83`) switch mechanically to `handle_from_raw::<RepoSession>(handle as *mut RepoSession)` + `.repo`; `zanshin_repo_close` (repo.rs:238) tears the session down. **No `extern "C"` signature changes** for any existing symbol. Update every affected `// SAFETY:` comment (`Box<Repo>` → `Box<RepoSession>`).

5. **Arming order satisfies AR-G-5.** The shared arm-helper runs *inside* the wrapper before it returns: obtain `Repo` → `Watcher::new(&repo_path)` → `Box::into_raw` the session (watcher/dispatch still `None`) to learn the final handle value → spawn the dispatch thread with that `u64` + the `Receiver` → write `watcher`/`dispatch` into the session through the raw pointer (still exclusively owned — `// SAFETY:` it) → return the handle. The watcher is armed **before** the wrapper returns; no mutation between open-start and watcher-arm is missed (AR-G-5, "test for this" — see AC 16).

6. **Arming failure fails the open** (recommended default — see [OQ-1](#oq-1-arming-failure-policy--recommend-strict-fail)): `Watcher::new` → `Err(WatcherError)` maps via a new `map_watcher_err` to `error.code = "watcher.io_error"` (context = the error's `Display`), and the wrapper returns that error envelope. This cannot regress init/clone/convert on healthy inputs: `Workspace::init_*` always writes `.jj/working_copy/checkout` via `LocalWorkingCopy::init` → `CheckoutState::save` (verified jj-lib 0.42.0 `local_working_copy.rs:2658-2670`), so every freshly produced workspace is watchable. The already-opened `Repo` is dropped (no leak); for `init`/`clone`/`convert` the on-disk artefacts stay (same posture as existing post-init failures). `docs/rust-error-codes.md` flips `watcher.io_error` **Reserved → Emitted — Story 3.6**, noting: emitted on arming failure at open/init/clone/convert; post-arm watch errors ride the event stream as `kind = WatchError` (no code string — R5).

7. **Per-session dispatch thread.** A `std::thread` owning the `Receiver<WatcherEvent>`: blocking `recv()` loop → map `watcher::WatcherEvent` → envelope bytes (`OpHeadsChanged`/`WorkingCopyHeartbeat` → `kind` + `paths`; `WatchError { message }` → `kind = WatchError` + `message`) → `events::dispatch`. On `RecvError` (channel disconnected because the `Watcher` was dropped/stopped) the thread exits. The loop body is panic-proof (no `unwrap`/`expect`; a serialization failure is logged and the event dropped — never unwind into the `extern "C"` callback).

8. **Close is deterministic: no callback fires after `zanshin_repo_close` returns.** Teardown order in the session drop/close path: `watcher.take()` → `Watcher::stop()` (joins the debouncer thread — 3-5 chose `stop()` over drop *for* this guarantee) → `dispatch.take()` → `join()` (drains ≤256 buffered events, then sees disconnect and exits). After `close` returns, no Rust thread for that repo can touch the sink. Bounded-time: both joins are on threads with guaranteed exits.

### Dart — `packages/zanshin_core`

9. **`lib/src/ffi/events.dart`** (the only new file allowed to import `dart:ffi`; SPDX): owns the `NativeCallable`.
   - `NativeCallable<ffi.Void Function(ffi.Pointer<ZanshinBuf>)>.listener(_onNativeEvent)` — **void-return is mandatory** (listener supports only `void`); native calls are non-blocking and delivered async to the creating isolate (the worker).
   - The handler takes ownership: `FfiBuffer.fromToken(ptr)` → copy bytes → `dispose()` → `decodeEventEnvelope(bytes)` → forward. The handler is **fully `try`/`catch`-wrapped**: a malformed buffer is logged (via the `package:logging` façade) and dropped — it must NOT become an uncaught async error that kills the worker (that path is reserved for the deliberate fault-injection test, AC 15).
   - Public surface (mirroring the `repo.dart` adapter style): `registerEventSink(void Function(ZanshinRawEvent) onEvent)`, `void closeEventSink()` (calls `zanshin_events_unregister()` **then** `callable.close()` — in that order), and a standalone `void unregisterEventSink()` (FFI-only, no callable teardown — callable-free, safe from the **main** isolate on worker death). Without `closeEventSink()` the callable's `keepIsolateAlive` pins the worker forever.
   - `ZanshinRawEvent` + `decodeEventEnvelope(Uint8List)`: sealed family carrying the **raw** `repoHandle` (int) + per-kind fields (`paths` / `message` / `operation`+`progress`+`message`), decoded via the generated accessors with the established discriminant guard (`payload is! fbs.WatcherEvent` / `fbs.Progress` → `ZanshinFfiException('ffi.unknown', …)` — 3-8 pattern).

10. **`lib/src/worker/events.dart`** (pure Dart, no `dart:ffi`): the public event family sent to main and exported from `zanshin_core.dart`:
    ```dart
    sealed class RepoEvent { final int handleId; … }
    final class OpHeadsChangedEvent extends RepoEvent { final List<String> paths; … }
    final class WorkingCopyHeartbeatEvent extends RepoEvent { final List<String> paths; … }
    final class WatchErrorEvent extends RepoEvent { final String message; … }
    final class ProgressEvent extends RepoEvent { final String operation; final double progress; final String message; … }
    ```
    All fields sendable (`int`/`String`/`List<String>`).

11. **Worker-side wiring (`_workerEntry`).**
    - Maintains the reverse map `rawToId` alongside `handles` (updated in `_replyRepoOp` and on close-command removal).
    - During init, **before** the handshake `bootstrapSP.send` (so an init failure surfaces through `start()`'s existing race — that is the injection point AC 15a relies on): `registerEventSink(onEvent)` where `onEvent` maps `rawRepoHandle → handleId` via `rawToId` (unknown raw → log + drop; benign close-race) and sends the corresponding `RepoEvent` on the **event `SendPort`** (the 3.9-reserved port — stop discarding it: `final (bootstrapSP, responseSP, eventSP) = init;`). Events are never routed through the command-correlation map (AR-AD-4).
    - Handles the new `ShutdownCommand` (AC 12).

12. **Graceful shutdown protocol (`ShutdownCommand` + async `close()`).**
    - `commands.dart` gains `final class ShutdownCommand extends WorkerCommand` (the sealed switch stays exhaustive).
    - Worker on `ShutdownCommand`: close every repo left in `handles` (via the existing `zanshinRepoClose` adapter — each joins its Rust dispatch thread, AC 8) → `closeEventSink()` (unregister, then close the callable) → ack (`BufferResult` ok-envelope or a dedicated ack) → stop listening (close its `ReceivePort`).
    - `ZanshinWorker.close()` becomes **`Future<void>`**: idempotent; sends `ShutdownCommand`, awaits the ack with a bounded timeout (reuse the 10 s handshake constant or a dedicated ~5 s), then — ack or timeout — `_isolate.kill(priority: Isolate.immediate)` as backstop + `failAll` + `_teardown()`. Update the two call sites: `app/lib/src/app/worker_lifecycle_module.dart` (`onExitRequested` awaits it) and every test teardown. ~~In-flight commands issued before `close()` still fail via `failAll` exactly as today.~~ **Deviation (accepted, Ralph 2026-07-03, code review):** commands already queued when `ShutdownCommand` is sent are drained FIFO by the worker and may complete normally (the friendlier graceful-shutdown semantics); `failAll` remains the backstop for anything still pending after the ack/kill. The `worker_close_fails_in_flight_commands` test deliberately accepts either outcome.
    - `_onWorkerDeath` (unexpected death — worker cannot cooperate): additionally call `unregisterEventSink()` **from the main isolate** (AC 3's any-isolate exemption) so no later native dispatch invokes the dead worker's callable. The residual race (an event in flight at the instant of death) is documented as accepted — the open sessions' threads leak with the dead worker's handles, same posture as today's handle leak on worker death.

13. **`ZanshinWorker` exposes the stream.** `Stream<RepoEvent> get events` — broadcast stream fed by `_eventPort` (listen + type-filter; non-`RepoEvent` messages logged and dropped). Optionally (cheap, bridge-level): `RepoHandle.events` → `worker.events.where((e) => e.handleId == handleId)`. No UI call sites (Ralph's scope).

### Tests (both gates of the coverage union)

14. **Rust.**
    - Unit (inline in `events.rs`): register/overwrite/unregister semantics; `dispatch` with no sink drops (and does not allocate a token); `watcher_event_to_envelope` / `progress_to_envelope` round-trip **read back via the generated typed accessors + run the FlatBuffers `Verifier`** (wire-contract rule); `map_watcher_err` maps `Io`/`Notify` → `watcher.io_error`.
    - Integration (`crates/zanshin-ffi/tests/events_ffi.rs`, mirroring `tests/watcher.rs` style — env-pin, fixture-extract, `recv_timeout` guards): register a **Rust-side `extern "C"` test sink** (static `Mutex<Vec<Vec<u8>>>` + a named `unsafe extern "C" fn` that copies bytes and calls `zanshin_buffer_free_token`); `zanshin_repo_open` a `tiny-3-commits` fixture (arms); touch a file under `<repo>/.jj/repo/op_heads/heads/` → assert an envelope arrives (generous timeout) whose payload is `WatcherEvent { kind: OpHeadsChanged, repo_handle == the open handle }`; **two repos open → touching repo A yields only `repo_handle == A`** (the epic's per-handle isolation AC, realized as correlation-id demux); `zanshin_repo_close` → assert **no** further callback after close returns (touch again + bounded negative wait); arming-failure → open returns `watcher.io_error` (candidate sabotage: delete `<repo>/.jj/working_copy/checkout` before open — `Watcher::new` errors on the missing watch target; if `Repo::open` itself refuses that state, fall back to unit-testing the arm-helper's error path directly — the goal is the *mapped code*, not one specific sabotage).
    - Update the three existing `repo.rs` unit tests that assert the old `Box<Repo>` behaviour only if they break mechanically (`handle_roundtrip…` in `handle.rs` is type-generic and should not care).
15. **Dart (`packages/zanshin_core/test/`), real `Isolate.spawn` + real cdylib — never mocked.**
    - Decode-contract (synthetic buffers via `*ObjectBuilder`s): `decodeEventEnvelope` for all three watcher kinds + `Progress`; non-event payload → `ZanshinFfiException('ffi.unknown', …)`; null-for-absence fields.
    - Per-extern-fn coverage tests (the ratchet trap — see Dev Notes › Coverage): a real-cdylib test that calls `zanshin_events_register`/`unregister` through the bindings (the worker E2E below also exercises them, but keep one explicit seam test per the `zanshin_version_test.dart` convention).
    - **Worker E2E event round-trip** (`test/worker/events_test.dart`): `start()` → `initRepo(tmpDir, backend: 0)` → subscribe `worker.events` → touch a file under `<tmpDir>/.jj/repo/op_heads/heads/` → expect an `OpHeadsChangedEvent` with the repo's `handleId` (generous timeout, e.g. `expectLater` + `timeout(10s)` guard); heartbeat analogous or folded in; then `await worker.close()` → assert clean completion.
    - **Shutdown:** after `close()`, no further events are delivered, `send()` throws `StateError`, and the isolate is gone (pause-capability/ping or `addOnExitListener` observed during close).
    - **(AC 15a) 3.9-regression: pre-handshake failure.** Force the worker's init to fail before the handshake send (a test-only fault-injection flag threaded through the bootstrap record — e.g. an optional `bool failBeforeHandshake` on a `@visibleForTesting start()` parameter — is acceptable; the organic hook is the event-sink registration this story adds to the pre-handshake window). Assert `start()` completes with an **error** (no hang; well under the 10 s timeout when injected as a throw) and all five ports are closed. **Deviation (accepted, Ralph 2026-07-03, code review):** the five ports are `start()`-locals and not observable from a black-box test; the closure is review-verified (`closeAllPorts()` runs in `start()`'s catch path) instead of asserted. The isolate-gone halves of AC 15/15b are asserted for real via the `@visibleForTesting workerExited` exit-observation hook added by the review patches.
    - **(AC 15b) 3.9-regression: uncaught async worker error.** Force an uncaught async error inside the worker after the handshake (fault-injection flag or test-only scheduled throw). Assert pending command futures fail AND the isolate is no longer alive (`_onWorkerDeath`'s `kill` — observable via exit listener).
16. **AR-G-5 ordering evidence.** The integration test asserts the watcher is live for mutations that happen immediately after `open` returns (the first touch in AC 14's E2E *is* this assertion — no sleep between open-return and touch beyond what the debounce window needs). Document in the test why no tighter race assertion is possible without fault-injection inside jj-lib.
17. **`cargo make test` green end-to-end** — cargo tests, clippy pedantic `-D warnings`, rustfmt, `flutter test`, `dart analyze --fatal-infos --fatal-warnings` + format (app + zanshin_core), `cargo deny`, **coverage ratchet**: `events.rs` is a new file → ≥ 80 % floor; `repo.rs`/`watcher.rs` must not regress; commit the auto-raised `coverage-baseline.txt` with the code.

### Docs

18. **`docs/ffi-abi.md`** gains an "Async events" section: the `EventCallback` typedef, register/unregister contract (overwrite semantics, any-isolate exemption, unregister-before-callable-close ordering), token-ownership transfer (Rust allocates → Dart frees via `FfiBuffer.fromToken`; undelivered tokens at callable-close leak by design — bounded, shutdown-only), the `WatcherEvent`/`Progress` payload schemas, and the repo-correlation-id semantics. **`docs/rust-error-codes.md`** flips `watcher.io_error` per AC 6. Both in the same PR (project rule).

## Tasks / Subtasks

- [x] **T1 — Wire schema + codegen** (AC: 1)
  - [x] Add `WatcherEventKind`, `WatcherEvent`, `Progress` to `schemas/envelope.fbs`; append both tables at the **end** of `union Payload`; fix the `RepoHandle` doc comment (`*mut RepoSession`).
  - [x] `cargo make codegen`; commit all four generated artifacts. Never hand-edit them.
- [x] **T2 — `events.rs`: sink + builders + extern fns** (AC: 2, 3)
  - [x] `EventCallback` type; `static SINK: Mutex<Option<EventCallback>>` (+ `// WHY:` on why this lock is legal); `dispatch(Vec<u8>)`; `watcher_event_to_envelope` / `progress_to_envelope` builders (follow `ok_repo_detect`'s builder shape).
  - [x] `zanshin_events_register(Option<EventCallback>)` / `zanshin_events_unregister()` — infallible `void`, `catch_unwind`-wrapped, doc-commented for cbindgen; `pub mod events;` in `lib.rs`.
- [x] **T3 — `RepoSession` + arming in `repo.rs`** (AC: 4, 5, 6, 8)
  - [x] Define `RepoSession`; shared `arm_session(repo: Repo, repo_path: &Path) -> Result<u64, FfiErrorObj>` helper (Box → raw → spawn dispatch thread → write back watcher/dispatch); wire into open/init/clone/convert.
  - [x] `map_watcher_err(WatcherError) -> FfiErrorObj` + `WATCHER_IO_ERROR` const in `envelope.rs` (single-emission-point rule).
  - [x] Session teardown in `zanshin_repo_close`: stop watcher (join) → join dispatch → drop repo. Update all `handle_from_raw::<Repo>` sites (5 read wrappers) to `RepoSession` + `.repo`; refresh every affected `// SAFETY:` comment and the `ok_repo_handle` doc comment (`envelope.rs:89` still says "raw `*mut Repo`").
- [x] **T4 — Dispatch thread** (AC: 7)
  - [x] `recv()` loop; `WatcherEvent` → envelope mapping (incl. `WatchError → kind` + message); `events::dispatch`; exit on disconnect; panic-proof body.
- [x] **T5 — Rust tests** (AC: 14, 16)
  - [x] Inline unit tests in `events.rs`; `tests/events_ffi.rs` integration suite (test sink, E2E touch → callback, two-repo demux, close-stops-callbacks, arming-failure code). Every sink-touching test holds the test-local `TEST_GUARD` mutex (trap 11a).
- [x] **T6 — Dart FFI layer** (AC: 9)
  - [x] `lib/src/ffi/events.dart`: `NativeCallable.listener`, try/catch handler, `FfiBuffer.fromToken` ownership, `ZanshinRawEvent` + `decodeEventEnvelope` (discriminant guard), `registerEventSink`/`closeEventSink`/`unregisterEventSink`.
- [x] **T7 — Worker + main wiring** (AC: 10, 11, 12, 13)
  - [x] `lib/src/worker/events.dart` (`RepoEvent` family; export from `zanshin_core.dart`).
  - [x] `_workerEntry`: bind `eventSP`, `rawToId` reverse map, register sink pre-handshake, `onEvent` demux → `eventSP.send`.
  - [x] `ShutdownCommand` + worker handling (close repos → `closeEventSink()` → ack → stop); `ZanshinWorker.close()` → `Future<void>` with ack-timeout + kill backstop; `_onWorkerDeath` += `unregisterEventSink()`; `Stream<RepoEvent> get events` (+ optional `RepoHandle.events`).
  - [x] Update call sites: `app/lib/src/app/worker_lifecycle_module.dart` awaits `close()`; test teardowns.
- [x] **T8 — Dart tests** (AC: 15)
  - [x] Decode-contract tests (synthetic); extern-fn seam test; `test/worker/events_test.dart` E2E; shutdown test; the two 3.9-regression tests (fault-injection mechanism is the dev's choice — assert the observable contract).
  - [x] `packages/zanshin_core/dart_test.yaml` with `concurrency: 1` + `# WHY:` (trap 11b).
- [x] **T9 — Docs + registry** (AC: 6, 18)
  - [x] `docs/ffi-abi.md` "Async events" section; `docs/rust-error-codes.md` flip `watcher.io_error` → Emitted — Story 3.6 (with the WatchError-events-carry-no-code note).
- [x] **T10 — Gate** (AC: 17)
  - [x] `cargo make test` (unpiped — trust the exit code); fix clippy/fmt/analyze; confirm `events.rs ≥ 80 %`, no regressions; commit raised `coverage-baseline.txt`.

### Review Findings

> Adversarial code review 2026-07-03 (Blind Hunter / Edge Case Hunter / Acceptance Auditor, 26 raw findings → 20 unique after dedup; every finding verified against the working tree before triage). 7 dismissed as refuted/noise after verification.

- [x] [Review][Patch] **(resolved Decision, Ralph 2026-07-03: accept drain)** AC-12 deviation: in-flight commands sent just before `close()` may drain (complete normally, FIFO) instead of failing via `failAll`. Accepted as the friendlier graceful-shutdown semantics — record the deviation in AC 12's text (this story file), no code change. [packages/zanshin_core/lib/src/worker/isolate.dart:379]
- [x] [Review][Patch] **(resolved Decision, Ralph 2026-07-03: minimal exit hook)** AC-15/15a/15b test evidence: add a minimal `@visibleForTesting` exit-observation hook (a `Future<void>` completed by the worker's exit event) and use it in the AC-15b regression + shutdown tests to observe real isolate death; 15a's "all five ports are closed" stays unasserted (ports are `start()`-locals) — record as review-verified deviation (`closeAllPorts()` in `start()`'s catch path). [packages/zanshin_core/test/worker/events_test.dart:116-166]
- [x] [Review][Defer] **Raw-pointer ABA in event demux** [packages/zanshin_core/lib/src/worker/isolate.dart:757] — deferred (Ralph 2026-07-03): benign for coalescing-idempotent watcher events; document the race now (code comment + ffi-abi.md), revisit the correlation-id design (generation/session id) with Story 6-4a's first real Progress producer. Recorded in deferred-work.md.
- [x] [Review][Patch] **Sink-lifecycle hardening (3 merged findings).** (i) `close()`'s ack-timeout path kills the isolate but never unregisters the sink — with un-closed sessions' dispatch threads alive, the killed isolate's callable stays invocable (the UB clause ffi-abi.md declares unreachable); `_onWorkerDeath`'s `_closed` guard prevents the death path from cleaning up after `close()` set the flag. (ii) `_onWorkerDeath` kills before unregistering — reversing closes a window its own comment claims cannot exist. (iii) `events::dispatch` invokes the callback outside the `SINK` lock, so `unregister` is not a barrier against an in-flight invocation; holding the lock across the (non-blocking) call makes "after unregister returns, kill/close is safe" actually true. Plus: document the accepted residual race + session leak on unexpected worker death in ffi-abi.md (AC 12 says "documented as accepted" — currently nowhere). [packages/zanshin_core/lib/src/worker/isolate.dart:379,250; crates/zanshin-ffi/src/events.rs:92; docs/ffi-abi.md:213]
- [x] [Review][Patch] **Concurrent `close()` returns early.** `_closed` is set before the first await; a second caller gets a completed Future while shutdown is still in progress (`worker_lifecycle_module.dart`'s `onExitRequested` would proceed to exit). Memoize the in-progress future (`_closeFuture ??= …`). [packages/zanshin_core/lib/src/worker/isolate.dart:379]
- [x] [Review][Patch] **Double `registerEventSink` leaks the previous `NativeCallable`** (which pins the isolate alive). Unreachable in production (worker registers once), but a one-line `StateError` guard closes it. [packages/zanshin_core/lib/src/ffi/events.dart:128]
- [x] [Review][Patch] **`spawn_dispatch_thread` uses `std::thread::spawn`, which panics on OS spawn failure** — a panic source inside an FFI-reachable path (leaks the session `Box` into `catch_unwind`). Use `thread::Builder::spawn`, map `Err` via `WatcherError::Io` → `watcher.io_error`, reclaim the box. Also sharpen `arm_session`'s SAFETY comment: "no other code can observe or alias it yet" is imprecise — the dispatch thread observes the address *value*; state that nothing dereferences the pointee until the wrapper returns. [crates/zanshin-ffi/src/repo.rs:153,169]
- [x] [Review][Patch] **AC-16 rationale comment missing.** The mandated test comment ("why no tighter AR-G-5 race assertion is possible without jj-lib fault-injection") is absent from `event_arrives_on_op_heads_change`. [crates/zanshin-ffi/tests/events_ffi.rs:156]
- [x] [Review][Patch] **ffi-abi.md omits the init/clone/convert residue on arming failure.** "the repo is not left open in an unwatched state" elides that the on-disk artifacts persist (a retry hits already-exists). One clarifying sentence; behavior itself is AC-6-blessed. [docs/ffi-abi.md:185]

Dismissed after verification (record only): open-window event loss (refuted — `rawToId` insert is synchronous within the same worker-handler turn, queued listener messages process after it); ffi-abi 256-token bound (holds in practice for the graceful path via queue ordering); 500 ms negative window (debounce is 50 ms — 10× margin, positive path calibrates); asymmetric VT constants (pre-existing flatc/cbindgen emission quirk across all tables, generated files, no consumer); null-coalescing in `decodeEventEnvelope` (per-kind presence contract is consistent; `RepoEvent`'s non-null shape is AC-10's own definition; coercion only reachable on corrupt input); AC-15a injection point (spec explicitly blesses the flag mechanism; the observable contract is location-independent pre-handshake); `FfiBuffer.fromToken` token leak (throws only on nullptr — no token to leak; dispatch never passes null).

## Dev Notes

### What this story is, in one paragraph

The keystone's last missing piece: async Rust→Dart. Story 3.5 built a silent watcher (events die in a channel no one drains); Story 3.9 built a worker with a dead event port. This story connects them: every opened repo owns a watcher + a dispatch thread (ADR-0002's "warm loader + watcher owner", now literal); dispatch threads serialize `WatcherEvent`s to FlatBuffers `Envelope`s and push them through ONE process-global C callback registered by the worker isolate's `NativeCallable.listener`; the worker demuxes raw-handle → `handleId` (Model A intact — raw pointers still never reach main) and fans out typed `RepoEvent`s on the reserved event port; main exposes `Stream<RepoEvent>`. Progress (FR-FFI-8) gets its payload table + decode + the same dispatch path now, and its first real producer in 6-4a with **zero** new mechanism.

### Architecture & requirements anchors

- **FR-FFI-4** — async signals via `NativeCallable.listener`, same mechanism for watcher + progress. **FR-FFI-8** — progress contract `{operation, progress, message}` (shape preserved in the `Progress` table + `repo_handle` correlation). **FR-RX-1** — op_heads change → Dart callback (functional; latency soft). [prd.md:243,247,292]
- **AR-AD-4** — events go on the dedicated event port, never the correlation map. [architecture.md:239]
- **AR-AD-5** — the bounded channel + drop policy live in 3-5's `watcher.rs`; this story only *drains* it. [architecture.md:243-251]
- **AR-G-5** — "Watcher must start before `zanshin_repo_open` returns." Realized by arming inside the wrapper (AC 5). [epics.md:221]
- **ADR-0002:34,57** — handle = warm loader + **watcher owner**; events **must** carry a repo/handle correlation id. These two lines are the architectural license for `RepoSession` and the global-sink demux design.
- **ADR-0001** — composite data = FlatBuffers; the event payload is composite → FlatBuffers `Envelope`, reusing the existing union (one schema file, one codegen path, the existing `FfiBuffer`/accessor/Verifier machinery). No JSON, no `schema_version`, no second root type.

### The repo handle becomes `RepoSession`

Today all four producers leak `Box<Repo>` and five read wrappers deref `handle as *mut Repo`. ADR-0002 already re-defined what the handle *is*; this story makes the code match:

```rust
struct RepoSession {
    repo: Repo,
    watcher: Option<Watcher>,          // Option: teardown take()s
    dispatch: Option<JoinHandle<()>>,  // Option: teardown take()s + join()s
}
```

- Read wrappers change two tokens each: `handle_from_raw::<RepoSession>(handle as *mut RepoSession)` and `&session.repo`. Handles stay `u64` on the wire — **no ABI change, no Dart change** from this refactor.
- The arm-helper needs the **final handle value** before the dispatch thread starts (events carry it). Cleanest sequence: `let raw = Box::into_raw(Box::new(RepoSession { repo, watcher: None, dispatch: None }));` → `Watcher::new(path)?` → spawn thread capturing `(raw as u64, receiver)` → `unsafe { (*raw).watcher = Some(w); (*raw).dispatch = Some(handle); }` (`// SAFETY:` exclusive ownership until the wrapper returns) → `Ok(raw as u64)`. On `Watcher::new` failure, reconstitute the Box (`Box::from_raw`) and drop it — no leak.
- Teardown order matters (AC 8): `watcher.take() → stop()` **joins the debouncer thread** (3-5 chose `stop()` over bare drop precisely for the synchronous close), which drops the `SyncSender`; then `dispatch.take() → join()` drains ≤ 256 buffered events and exits on `RecvError`. Implement in a `close()` method called from `zanshin_repo_close`'s `handle_drop` path (or `impl Drop` — but an explicit method + `Drop` backstop documents intent).

### Event delivery: Envelope reuse, ownership transfer

- **Why Envelope and not a second root type:** a second `.fbs` root would need a second generated pair, codegen-task surgery, and a second Dart reader path. Adding two tables to the existing `Payload` union reuses *everything* (builders, `FfiBuffer`, accessors, `Verifier`, the `ffi.unknown` discriminant-guard idiom). Event envelopes are always `ok == true`; a *degraded watch* is data (`kind = WatchError` + `message`), not a failed call. The `watcher.io_error` **code string** is emitted in exactly one place: the arming-failure error envelope at open (single-emission-point rule, R3 in 3-5).
- **Ownership across the async hop:** `NativeCallable.listener` calls are non-blocking — Rust's `callback(token)` returns immediately, Dart's handler runs later. Rust therefore must NOT free the buffer after the call; the token transfers to Dart, exactly like a return value (`FfiBuffer.fromToken` → copy → `dispose`). Consequence: events dispatched but undelivered when the callable closes **leak their token**. This is shutdown-only, bounded (≤ 256/repo), and the graceful-shutdown ordering (repos closed → threads joined → *then* callable closed) makes the window empty in practice. Document in ffi-abi.md; do not build machinery for it.
- **`NativeCallable.listener` facts** (api.dart.dev, verified 2026-07-03): only `void`-returning function types; callable from **any thread**; args are sent over an internal SendPort and the callback runs "at some time in the future"; the creating isolate is **kept alive until `close()`**; invoking the pointer after `close()` is **undefined behavior**. The epic's "constructed with `Isolate.current.controlPort`" phrasing is obsolete internals — the factory constructor is the whole API.

### Lifecycle: the shutdown protocol (load-bearing)

The project-context edge case says it plainly: *"The Dart-side callable must outlive every Rust-side reference. Attach it to the worker isolate's lifetime, not to a single FFI call."* Concretely:

```
graceful close():                      unexpected worker death (_onWorkerDeath):
  main: send ShutdownCommand             main: unregisterEventSink()   // FFI, any-isolate-safe
  worker: close every repo in table      main: kill + failAll + teardown (as today)
          (each join()s its dispatch     → open sessions leak with the dead worker
           thread — AC 8)                  (same posture as today's handle leak);
  worker: zanshin_events_unregister()      future dispatches hit an empty sink and drop.
  worker: callable.close()
  worker: ack → stop listening
  main: await ack (timeout ~5s)
  main: kill (backstop) + teardown
```

Why each step: repos first (joins kill every thread that could still *read* the sink) → unregister (belt-and-suspenders: later opens on a half-dead worker can't dispatch into a closing callable) → callable close last (nothing can invoke it anymore → the UB clause is unreachable). Without this, **every Dart test** that opens a repo and calls `close()` races Rust dispatch threads against a killed isolate's callable — flaky segfaults, not a theoretical concern.

`close()` becoming `Future<void>` is a deliberate, small API break (WIP posture: callers update in the same PR): `worker_lifecycle_module.dart`'s `onExitRequested` already is async; test teardowns add `await`.

### Dart worker wiring specifics (verified against the current code)

- `_WorkerInit` is `(SendPort, SendPort, SendPort)` = bootstrap/response/event; the worker currently discards the third (`isolate.dart:462: final (bootstrapSP, responseSP, _) = init;`) — bind it.
- The five ports named by the 3.9 review: `_responsePort`, `_eventPort`, `_exitPort`, `_errorPort` + the local bootstrap port in `start()`. The regression test 15a asserts all five close on pre-handshake failure.
- `_replyRepoOp` (isolate.dart:627) is where `handles[id] = raw` happens — add `rawToId[raw] = id` there and remove in the `CloseRepoCommand` arm.
- Registration must happen **pre-handshake** in `_workerEntry` so a failure there surfaces through `start()`'s existing death/timeout race (isolate.dart:125-148) — that is precisely the "first worker-side init code that can fail" the 3.9 review predicted; the deferred regression test 15a leans on it.
- The `ZanshinFfiException`/`ffi.unknown` discriminant-guard idiom to copy: `packages/zanshin_core/lib/src/ffi/status.dart` (`_decodeStatusEnvelope`) / `repo_detect.dart`.
- Naming collision heads-up: the generated Dart class for the new table is `WatcherEvent` in `envelope_zanshin.ffi_generated.dart` — import as `fbs.WatcherEvent` (established alias pattern), keep the public family named `RepoEvent`/`…Event` (AC 10), and note Rust has `watcher::WatcherEvent` (internal enum) vs generated `envelope_generated::…::WatcherEvent` — module paths disambiguate; don't `use` both unqualified in one scope.

### Reconciliations (stale epic ACs corrected)

| # | Epic text (stale) | Corrected | Why |
|---|---|---|---|
| R1 | Events as JSON `*mut c_char`, freed via `zanshin_string_free`; `schemas/progress.v1.schema.json`; `schema_version` field | FlatBuffers `Envelope` token (`*mut ZanshinBuf`), freed via `FfiBuffer.fromToken`/`zanshin_buffer_free_token`; tables in `schemas/envelope.fbs`; no version field | ADR-0001 + project-context `overrides:`; same reconciliation as 3.4a/3.8/3.9. [mem: epics.md-FFI-ACs-predate-FlatBuffers] |
| R2 | `WatcherCallback` + `ProgressCallback` as two types; per-handle registry; `zanshin_watcher_register(handle, cb)` + `zanshin_progress_register(handle, op_id, cb)` | ONE `EventCallback`; ONE process-global sink registered once by the worker; events carry `repo_handle`; demux Dart-side | The epic's own sequencing note (epics.md:1803: "process-global … registered once") supersedes its older per-handle ACs; ADR-0002:57 requires the correlation id; project-context: "no special-case channels". Per-op progress registration is 6-4a's call-parameter design, not a global registry. |
| R3 | `zanshin_worker_init` as the entry-point name | `zanshin_events_register` / `zanshin_events_unregister` in `events.rs` | Epic explicitly defers naming ("or whatever the registration entry point is named"); AR-P-1 `zanshin_<noun>_<verb>`; module-by-noun. [OQ-2] |
| R4 | "bounded mpsc … before **drop-oldest** kicks in"; `tokio` channel | `std::sync::mpsc::sync_channel(256)`, **drop-newest** | Decided + shipped in 3-5 (R-channel/OQ-1); coalescing-idempotent per ADR-0002. |
| R5 | `WatcherError { code: String, … }` events carrying a code string | Post-arm errors are `kind = WatchError` + `message` (no code in the payload); the `watcher.io_error` **code** is emitted only by the arming-failure error envelope | 3-5 R3 single-emission-point rule; sprint-status 3-5 note: "watcher.io_error stays Reserved, 3.6 maps it". |
| R6 | (implicit) handle stays `Box<Repo>`; fbs comment "`*mut Repo` reinterpreted" | `Box<RepoSession>`; comment updated | ADR-0002:34 — handle = warm loader **+ watcher owner**. Wire type (`u64`) unchanged. |
| R7 | "verify the callback fires within 200ms … NFR-P-4 budget honoured" | assert *arrival* with generous timeouts; no tight latency bound | NFR-P-4 soft in WIP; no-flaky-tests rule; 3-5 R5 + 3.10's "drop the latency assertion" precedent. |
| R8 | `NativeCallable.listener … constructed with Isolate.current.controlPort` | `NativeCallable<T>.listener(fn)` factory; void-only; close() lifecycle | Current dart:ffi API (verified api.dart.dev 2026-07-03). |
| R9 | Heartbeat path `.jj/repo/working_copy/checkout` (in epic 3.5/3.6 prose) | `.jj/working_copy/checkout` — already correct in shipped `watcher.rs` | 3-5 R8 (verified vs jj-lib 0.42.0 `workspace.rs:140`); prd/epics/architecture still stale — do NOT "fix" the code back. |

### Existing patterns to reuse (do NOT reinvent)

- **Extern-fn skeleton:** `zanshin_repo_detect` (repo.rs) — `debug!(fn_name…)`, `catch(|| { … })`, `vec_into_token`. For the new *infallible void* fns, mirror `zanshin_logging_init`'s `catch_unwind` + swallow shape instead.
- **Builder shape:** `ok_repo_detect` (repo.rs) / `ok_diagnostics` (envelope.rs) — strings first, then table, then Envelope, then `finish`.
- **Error consts:** all `error.code` strings live in `envelope.rs` (`WATCHER_IO_ERROR` joins them); mapping fns (`map_watcher_err`) live with their noun.
- **Rust integration-test skeleton:** `tests/watcher.rs` (env pin via `LazyLock`, `extract_fixture("tiny-3-commits")`, `recv_timeout` deadlock guards) + `tests/repo_ffi.rs` (`read_and_free`/envelope parsing helpers).
- **Dart FFI adapter style:** `lib/src/ffi/repo.dart` (toNativeUtf8/finally-free — not needed here; the pattern of "pure-Dart types out, `dart:ffi` contained"); **`FfiBuffer.fromToken` → copy → dispose** is mandatory before anything crosses a port.
- **Decode guard:** `status.dart`/`repo_detect.dart` `payload is! fbs.X → ZanshinFfiException('ffi.unknown', …)`.
- **Worker test style:** `test/worker/zanshin_worker_test.dart` (real isolate, `initRepo(backend: 0)` into `Directory.systemTemp`, `addTearDown`, scenario names).
- **Warn-capture in Rust unit tests:** `logging.rs::run_scoped()` + Recorder (used by 3-5 for the channel-full warn).

### Coverage (ratchet — read this or fail the gate)

- `events.rs` is a **new file** → `new_file_floor_pct = 80.00`. The builders + `dispatch` + mapping are unit-testable inline (cheap floor-clearing, same play as 3-5's `classify`/`send_or_drop`).
- **The extern-fn attribution trap** ([mem: project-coverage-extern-fn-needs-zanshin-core-test]): `cargo-llvm-cov` does not credit `#[no_mangle] extern "C"` fn **bodies** called from cargo tests toward the union — only the `packages/zanshin_core` real-cdylib Dart tests do. `zanshin_events_register`/`unregister` get their explicit seam test (AC 15); the modified open/init/clone/close/convert bodies are already exercised by the existing zanshin_core worker tests, which keeps their attribution alive.
- The dispatch thread + `RepoSession` internals are ordinary Rust → covered by the cargo integration tests (`tests/events_ffi.rs`).
- `watcher.rs` sits at 96.00 % — don't regress it (you shouldn't touch it at all).
- Coverage runs only the `zanshin_core` Dart tests (not `app/`) — the E2E event test must live in `packages/zanshin_core/test/`, not `app/test/`.
- If the gate flags something you didn't touch, `git stash` to prove pre-existence before suspecting the baseline. **Never lower the baseline.**

### Critical correctness traps (the review will hunt these)

1. **Callable close ordering** — `zanshin_events_unregister()` BEFORE `callable.close()`; repos closed (threads joined) before both. Anything else is UB-by-API-contract.
2. **Token ownership across the async hop** — Rust must not free after invoking the callback; Dart must `FfiBuffer.fromToken` exactly once per token. Double-free or Rust-side free = heap corruption far from the cause.
3. **No panic on the dispatch thread** — the loop body wraps fallible work; a panic would unwind toward an `extern "C"` boundary.
4. **Handler in the worker must not throw** — an uncaught async error in the `NativeCallable` handler kills the worker (that's test 15b's *deliberate* path; production decode is try/caught).
5. **Model A holds** — the raw `repo_handle` in the event payload reaches only the *worker* isolate; the worker maps it to `handleId` before anything goes to main. Unknown raw (close race) → drop + log, never throw.
6. **Register pre-handshake** — otherwise `start()`'s failure race can't see registration failures and test 15a has no organic hook.
7. **`Watcher::stop()` not bare drop** — bare drop only flags the debouncer thread (non-blocking); `stop()` joins. AC 8's "no callback after close returns" depends on it.
8. **Don't re-add tokio, don't touch `watcher.rs`'s channel/drop policy** — 3-5 decided std `sync_channel(256)` drop-newest; this story only consumes the `Receiver`.
9. **`dart:ffi` stays in `lib/src/ffi/`** — `worker/events.dart` (the `RepoEvent` family) is pure Dart; only `ffi/events.dart` touches `dart:ffi`.
10. **Two repos, one sink** — never assume single-repo: the correlation id is load-bearing (project-overview opens 0..N handles, ADR-0002).
11. **The global sink is the crate's first process-global mutable state that tests contend on.** (a) Rust: cargo runs tests in parallel threads of one process — every test that registers/unregisters the sink (unit AND `tests/events_ffi.rs`) must serialize via a test-local `static TEST_GUARD: Mutex<()>` held for the test body (dep-free; the project's sanctioned alternative is `#[serial]`, but don't add a crate for what a local mutex does). (b) Dart: `dart test` runs suites as concurrent isolates in ONE VM process — several suites each start a `ZanshinWorker`, and last-registration-wins + unconditional unregister would clobber the events E2E suite's sink mid-test. Fix: add `concurrency: 1` to `packages/zanshin_core/dart_test.yaml` with a `# WHY:` comment (process-global native sink; suites share the process). Production is unaffected (exactly one worker per process — documented in ffi-abi.md).
12. **No new dependencies.** Dispatch = `std::thread`; sink = `std::sync::Mutex`; Dart side = `dart:ffi` core. Anyone reaching for tokio, a callback crate, or `serial_test` should re-read this line.

### Anti-patterns to avoid (review-blockers)

- No JSON on the FFI wire; no second envelope shape; no in-wire `schema_version` (ADR-0001).
- No per-handle native callback registries; no `Arc<Mutex<Repo>>` — the one `Mutex<Option<EventCallback>>` is registration state, documented with `// WHY:`.
- No new `extern "C"` outside `crates/zanshin-ffi/`; no codegen outside `cargo make codegen`; commit generated diffs.
- No `error.code` string literals outside `envelope.rs`.
- No `#[ignore]`/`skip:`-for-flakiness; no tight latency asserts (soft WIP targets).
- No speculative progress API surface (per-op registries, rate limiting, progress UI hooks) — 6-4a designs its producer against the channel this story ships.
- No Flutter UI / feature call sites (`worker.events` consumers are Ralph's scope; the stream itself is bridge scope per [mem: feedback-scope-bridge-is-claudes-ui-is-ralphs]).

### Project Structure Notes

- **New:** `crates/zanshin-ffi/src/events.rs`, `crates/zanshin-ffi/tests/events_ffi.rs`, `packages/zanshin_core/lib/src/ffi/events.dart`, `packages/zanshin_core/lib/src/worker/events.dart`, `packages/zanshin_core/dart_test.yaml` (`concurrency: 1`, trap 11b), `packages/zanshin_core/test/ffi/events_test.dart` (decode-contract + seam), `packages/zanshin_core/test/worker/events_test.dart` (E2E + shutdown + regressions; split files as sensible).
- **Modified:** `schemas/envelope.fbs`; `crates/zanshin-ffi/src/{lib.rs, envelope.rs, repo.rs, status.rs, change.rs, op_log.rs, bookmarks.rs, remotes.rs}`; `packages/zanshin_core/lib/src/worker/{isolate.dart, commands.dart}`; `packages/zanshin_core/lib/zanshin_core.dart` (exports); `app/lib/src/app/worker_lifecycle_module.dart` (await close); `docs/ffi-abi.md`; `docs/rust-error-codes.md`; `coverage-baseline.txt` (auto).
- **Generated (via `cargo make codegen`, committed, never hand-edited):** `crates/zanshin-ffi/src/envelope_generated.rs`, `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`.
- **Untouched:** `crates/zanshin-ffi/src/watcher.rs` (consume-only), `crates/zanshin-jj/**` (no new jj logic), `handle.rs` (generic helpers work for any `T`).
- Module-by-noun: `events.rs`/`events.dart` are proper nouns; the epic's `callbacks.rs` suggestion is superseded (R3).

### References

- [Source: epics.md#Story-3.6 (2361–2434) — base ACs; :2365 the "owns end-to-end" correction; :2367 the two 3.9-review regression tests; :1803 process-global sink note]
- [Source: epics.md AR-G-5 (:221), AR-AD-4 (:185ff via architecture.md:233-241), AR-AD-5 (architecture.md:243-251); FR-FFI-4/-8 (prd.md:243,247), FR-RX-1 (prd.md:292)]
- [Source: docs/adr/0002-…:30-42 (handle = warm loader + watcher owner; watcher = coherency trigger), :57 (events carry repo/handle correlation id — a 3.6 requirement)]
- [Source: docs/adr/0001-ffi-data-transport-flatbuffers.md — transport; :48 names NativeCallable events as FlatBuffers consumers]
- [Source: _bmad-output/implementation-artifacts/3-5-…md — Watcher API (`new`/`stop`, `WatcherEvent`, `WatcherError`), R-channel, R8 heartbeat path, review patches (secondary-workspace resolution, canonicalize)]
- [Source: _bmad-output/implementation-artifacts/3-9-…md — Model A, five ports, `_WorkerInit`, start()-race + kill-on-death patches, Q2]
- [Source: _bmad-output/implementation-artifacts/3-4c-…md — extern-fn skeleton, union-append convention, codegen workflow, extern-fn coverage trap, ffi-abi.md seed]
- [Source: _bmad-output/implementation-artifacts/deferred-work.md §3-9-story-creation + §3-9-code-review (the two regression tests, verbatim contracts) + §3-5-code-review (non-UTF8 notify panic — remains deferred)]
- [Source: docs/rust-error-codes.md — `watcher.io_error` Reserved row + flip instruction]
- [Source: crates/zanshin-ffi/src/{watcher.rs, repo.rs:107-241,311, handle.rs, envelope.rs, logging.rs (infallible-fn + any-isolate precedent), ffi_strings.rs (`ZanshinBuf`, `vec_into_token`)}]
- [Source: packages/zanshin_core/lib/src/worker/isolate.dart (:50-52 reserved port, :125-148 handshake race, :208-221 `_onWorkerDeath`, :314-322 `close()`, :461-476 `_workerEntry`, :627 `_replyRepoOp`); lib/src/ffi/{ffi_buffer.dart, status.dart, repo_detect.dart}]
- [Source: api.dart.dev — NativeCallable.listener (void-only, any-thread, async delivery, keepIsolateAlive, close-then-call = UB); verified 2026-07-03]
- [Source: _bmad-output/project-context.md — FFI boundary rules, Watcher subsystem, Edge cases (`NativeCallable.listener` lifecycle, watcher-armed-before-open-returns), Error taxonomy, Coverage ratchet, Critical Don't-Miss Rules]

## Open Questions (confirm before/during implementation)

> Recorded for Ralph; the story is **ready-for-dev** with the recommended defaults baked into the ACs/Tasks. If Ralph doesn't respond, implement the recommendations and record the choice in the Dev Agent Record.

### OQ-1: arming-failure policy — *recommend strict-fail*
When `Watcher::new` fails during open/init/clone/convert, the wrapper returns `watcher.io_error` and NO handle (recommended): AR-G-5's spirit is "no unobserved-mutation window", the op_heads dir is a structural invariant of a healthy repo (a repo we can't watch is almost certainly broken), and a degraded-open would need extra surface (an `armed` flag on the `RepoHandle` payload + UI handling) for a state we can't currently produce legitimately on macOS/FSEvents. **Alternative:** degraded open (handle without watcher, `watcher: None`, plus a way to tell Dart) — more user-permissive, more surface; can be retrofitted if a real-world FS turns up where opens must succeed unwatched. (Both keep `extern "C"` signatures unchanged.)

### OQ-2: extern-fn naming — *recommend `zanshin_events_register`/`unregister`*
The epic reserved "`zanshin_worker_init` (or whatever the registration entry point is named)". Recommended: `zanshin_events_register(callback)` + `zanshin_events_unregister()` in `events.rs` — noun-verb per AR-P-1, and the fns do exactly one thing (tracing init already has `zanshin_logging_init`; a grab-bag `worker_init` would re-couple concerns). **Alternative:** keep the epic's `zanshin_worker_init(callback)` name (single fn; null = unregister) if you prefer one worker-bootstrap entry point.

### OQ-3: Progress surface now — *recommend schema + decode + dispatch-path only*
Recommended: ship the `Progress` table, `ProgressEvent` decode/demux, and prove dispatch in unit tests — but NO progress-producing extern fn and NO per-op registration API (nothing real can emit progress until 6-4a's `git fetch`, and FR-FFI-8's "long-running ops accept a callback" is a statement about *those ops'* parameters, which 6-4a designs). **Alternative:** defer the `Progress` table entirely to 6-4a (leaner now; costs a second schema/codegen/decode round-trip later and makes 3.6's "events + progress callbacks" title a half-truth).

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5 (claude-sonnet-5)

### Debug Log References

- `cargo make codegen` run twice: once after the `.fbs` edit (T1), and once more after adding `zanshin_events_register`/`unregister` (T2) — the second run was required because cbindgen/ffigen only see `extern "C"` fns that exist at codegen time.
- cbindgen initially emitted an opaque `struct Option_EventCallback` for `Option<EventCallback>` (a type-alias parameter), which ffigen then silently **skipped** the whole `zanshin_events_register` function (no Dart binding generated, no error). Fixed by spelling the function-pointer type literally in the parameter (`Option<unsafe extern "C" fn(event: *mut ZanshinBuf)>`) instead of through the `EventCallback` alias — cbindgen's nullable-function-pointer special case only fires on the literal spelling. Verified with `cbindgen --config cbindgen.toml --crate zanshin-ffi` previews before re-running full codegen.
- AC 14's arming-failure sabotage (delete `.jj/working_copy/checkout` before `zanshin_repo_open`) fails inside jj-lib's `Workspace::load` itself (`jj.jj_lib_error`), never reaching `arm_session` — verified empirically via `tests/events_ffi.rs`. Per AC 14's own documented fallback, moved this coverage to an inline `repo.rs` unit test that opens successfully first, sabotages the checkout file *after* open, then calls `arm_session` directly.
- `ZanshinWorker.close()` becoming `Future<void>` initially broke `worker_close_fails_in_flight_commands`: awaiting `close()` before attaching `expectLater` to the in-flight command's Future let it complete-with-error while unobserved (reported as an unhandled zone error) during the real async shutdown work. Fixed by attaching `expectLater`'s listener to the in-flight Future *before* awaiting `close()`.

### Completion Notes List

- Full event-sink surface shipped end-to-end per the story's three baked-in recommendations (all implemented as written; no Ralph override received): OQ-1 strict-fail arming, OQ-2 `zanshin_events_register`/`unregister` naming, OQ-3 minimal Progress surface (schema + decode + dispatch-path only, no producer).
- Rust: `events.rs` (process-global sink + FlatBuffers builders + extern fns), `RepoSession` replacing `Box<Repo>` as the handle type (arming in all four producers: open/init/clone/convert), per-session dispatch thread, `watcher.io_error` flip. 91 lib unit tests + `tests/events_ffi.rs` (3 integration tests) all green; `cargo clippy -- -D warnings` and `cargo fmt --check` clean.
- Dart: `ffi/events.dart` (`NativeCallable.listener`, decode-contract, registration API), `worker/events.dart` (public `RepoEvent` family), full worker wiring (`rawToId` demux, pre-handshake sink registration, `ShutdownCommand` graceful-shutdown protocol, `ZanshinWorker.events` broadcast stream). 94 `dart test` cases green under the new `concurrency: 1` (trap 11b — the process-global native sink is shared across concurrently-run test-file isolates).
- Both Story-3.9-deferred regression tests (pre-handshake failure, uncaught async worker error) implemented via test-only `failBeforeHandshake`/`throwAsyncErrorAfterHandshake` parameters on `ZanshinWorker.start()`, exercising the organic pre-handshake hook this story adds (`registerEventSink`).
- `docs/ffi-abi.md` gained an "Async events" section; `docs/rust-error-codes.md`'s `watcher.io_error` row flipped Reserved → Emitted.
- `cargo make test` (full gate: cargo test/clippy/fmt, flutter test, dart analyze/format, cargo deny, coverage ratchet) run unpiped — **green**, exit code 0, 176 s. `events.rs` new-file coverage 100.00%; overall 98.38% (2552/2594 lines, 25 files); baseline raised (0 up, 1 new, 0 removed), no regressions; `extern-coverage: OK — every zanshin-ffi extern "C" fn is covered`.

### File List

**New:**
- `crates/zanshin-ffi/src/events.rs`
- `crates/zanshin-ffi/tests/events_ffi.rs`
- `packages/zanshin_core/lib/src/ffi/events.dart`
- `packages/zanshin_core/lib/src/worker/events.dart`
- `packages/zanshin_core/dart_test.yaml`
- `packages/zanshin_core/test/ffi/events_test.dart`
- `packages/zanshin_core/test/worker/events_test.dart`

**Modified:**
- `schemas/envelope.fbs`
- `crates/zanshin-ffi/src/lib.rs`
- `crates/zanshin-ffi/src/envelope.rs`
- `crates/zanshin-ffi/src/repo.rs`
- `crates/zanshin-ffi/src/status.rs`
- `crates/zanshin-ffi/src/change.rs`
- `crates/zanshin-ffi/src/op_log.rs`
- `crates/zanshin-ffi/src/bookmarks.rs`
- `crates/zanshin-ffi/src/remotes.rs`
- `packages/zanshin_core/lib/src/worker/isolate.dart`
- `packages/zanshin_core/lib/src/worker/commands.dart`
- `packages/zanshin_core/lib/zanshin_core.dart`
- `packages/zanshin_core/test/worker/zanshin_worker_test.dart`
- `packages/zanshin_core/test/worker/bookmarks_test.dart`
- `packages/zanshin_core/test/worker/change_test.dart`
- `packages/zanshin_core/test/worker/detect_test.dart`
- `packages/zanshin_core/test/worker/op_log_test.dart`
- `packages/zanshin_core/test/worker/remotes_test.dart`
- `packages/zanshin_core/test/worker/status_test.dart`
- `app/lib/src/app/worker_lifecycle_module.dart`
- `docs/ffi-abi.md`
- `docs/rust-error-codes.md`

**Generated (via `cargo make codegen`, committed, never hand-edited):**
- `crates/zanshin-ffi/include/zanshin_ffi.h`
- `crates/zanshin-ffi/src/envelope_generated.rs`
- `packages/zanshin_core/lib/src/ffi/bindings.dart`
- `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`

**Auto (coverage ratchet, commit alongside the code that earned it):**
- `coverage-baseline.txt`

## Change Log

| Date | Change |
|------|--------|
| 2026-07-03 | Story created (ready-for-dev). Epic ACs reconciled: JSON/`schema_version`/`progress.v1.schema.json` → FlatBuffers `Envelope` payloads (R1); per-handle registries + `zanshin_watcher_register`/`zanshin_progress_register` → ONE process-global sink + `repo_handle` correlation id per ADR-0002:57 (R2); `zanshin_worker_init` → `zanshin_events_register`/`unregister` (R3); drop-oldest → drop-newest per 3-5 (R4); WatchError code-in-payload → single-emission-point (R5); handle `Box<Repo>` → `Box<RepoSession>` per ADR-0002:34 (R6); latency asserts softened (R7); `NativeCallable` API modernized (R8); heartbeat path stays `.jj/working_copy/checkout` (R9). Scope: full event-sink surface end-to-end incl. arming in all four handle producers, graceful worker shutdown (`ShutdownCommand`, async `close()`), the two 3.9-review regression tests, `watcher.io_error` flip. 3 OQs with recommended defaults baked in (strict-fail arming, `zanshin_events_*` naming, minimal Progress surface). |
| 2026-07-03 | Adversarial code review complete → done. 3 layers (Blind Hunter / Edge Case Hunter / Acceptance Auditor), 26 raw → 20 unique findings, every one verified against the working tree: 7 dismissed as refuted/noise, 3 decisions resolved by Ralph (AC-12 drain semantics accepted; minimal `workerExited` exit-observation hook for AC 15/15b, 15a port-closure recorded as review-verified; ABA demux race documented + deferred to 6-4a), 8 patches applied — sink-lifecycle hardening (`unregisterEventSink()` on the `close()` ack-timeout path, unregister-before-kill in `_onWorkerDeath`, `SINK` lock held across the callback so unregister is a true barrier), `close()` future-memoization for concurrent callers, `StateError` guard on double `registerEventSink`, `thread::Builder` (panic-free spawn) + injectable spawner seam + spawn-failure unit test, sharpened `arm_session` SAFETY comment, AC-16 rationale comment in `events_ffi.rs`, ffi-abi.md additions (barrier semantics, timeout backstop, death residual-race/session-leak acceptance, init/clone/convert residue, ABA note). Gate green end-to-end: 92 Rust lib tests (+1), coverage 98.39 % (2574/2616, up from 98.38 %), `extern-coverage: OK`, 147 s. |
| 2026-07-03 | Implementation complete → review. All 3 recommended OQ defaults implemented as-is (no override received). `watcher.io_error` flipped Reserved → Emitted (single-emission-point at arming failure only). cbindgen quirk discovered + fixed: `Option<EventCallback>` (a type alias) silently dropped `zanshin_events_register` from the generated Dart bindings — fixed by spelling the function-pointer type literally in the parameter. `packages/zanshin_core/dart_test.yaml` added with `concurrency: 1` (trap 11b). `cargo make test` green (exit 0, 176 s): Rust 91 lib unit + 6 integration suites (incl. new `events_ffi.rs`, 3 tests) all pass; clippy pedantic + rustfmt clean; `flutter test` / `dart analyze --fatal-infos --fatal-warnings` / `dart format` clean for both `app/` and `packages/zanshin_core`; `cargo deny` clean; coverage ratchet: `events.rs` new file at 100.00%, overall 98.38%, baseline raised with zero regressions, all extern fns coverage-attributed. Dart: 94 `dart test` cases green (decode-contract, extern-fn seam, worker E2E round-trip ×3, shutdown, both Story-3.9 regressions). |
