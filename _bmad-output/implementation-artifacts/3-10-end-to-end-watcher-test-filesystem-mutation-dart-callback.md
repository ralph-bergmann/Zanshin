---
baseline_commit: c57b586078b3eef5cc5fce17dafbda43a8758af6
---

# Story 3.10: End-to-end watcher test — filesystem mutation → Dart callback

Status: done

## Story

As a developer validating the FFI keystone end-to-end,
I want integration tests that mutate the filesystem under `.jj/repo/op_heads/heads/` and assert the Dart-side callback pipeline reacts — including through the `openRepo` producer, under burst load, and after a filesystem disturbance,
so that FR-RX-1 (functional pathway), FR-RX-4 (recovery), the Murat-Szenario-2 watcher-storm behaviour, and the full Rust→Dart pipeline are validated — **without latency assertions** (WIP).

## ⚠️ Scope reality check — READ FIRST

**Story 3.6 already shipped most of the epic's core AC.** `packages/zanshin_core/test/worker/events_test.dart` already boots the real worker isolate + real cdylib, `initRepo`s a repo, touches `.jj/repo/op_heads/heads/`, and asserts `OpHeadsChangedEvent` arrival with the correct `handleId` — plus heartbeat, two-repo isolation, and the no-events-after-close negative test. **Do not duplicate any of that.** This story is TEST-ONLY net-new code covering exactly three gaps:

1. **E2E via the `openRepo` producer** (epic AC step 3 used `OpenRepoCommand`; 3.6's Dart E2E only exercised `initRepo`) — including the epic's event-payload `paths` assertion, which no Dart test makes yet.
2. **Watcher-storm sub-test at E2E level** (WIP-rework 2026-05-17 appendix; consumes deleted Story 7.8 / Murat Szenario-2). Rust-level coalescing is already covered by `watcher_burst_coalesces`; the DART pipeline (dispatch thread → NativeCallable → event port → broadcast stream) has never seen a burst.
3. **FR-RX-4 recovery test** — explicitly deferred from Story 3.5 (its AC-14/R7: "a deterministic unmount/remount can't be simulated [at unit level]; recovery assertion lives in Story 3.10").

**No production code changes. No new deps. No codegen. No `.fbs` change. No new error codes.** If implementing a test reveals a product defect (see AC-3 escalation), STOP and surface it — do not silently patch production code inside this story.

## Acceptance Criteria

> Reconciliations vs. the epic text (epics.md:2604–2679) are inline; the epic predates ADR-0001 (FlatBuffers), the WIP-rework (no latency asserts), Story 3.5/3.6 as-built reality, and the `packages/zanshin_core` move. Where they conflict, THIS file wins.

### AC-1 — `openRepo`-path E2E round-trip (new Dart test file)

**Given** a new test file `packages/zanshin_core/test/worker/watcher_e2e_test.dart` (real `Isolate.spawn`, real cdylib — never mocked)
**When** a test: (1) `initRepo(tempDir.path, backend: 0)` → (2) `await handle.close()` → (3) `openRepo(tempDir.path)` → (4) subscribes `worker.events` → (5) writes a file under `<tempDir>/.jj/repo/op_heads/heads/`
**Then** an `OpHeadsChangedEvent` with the **open** handle's `handleId` arrives within the generous `_eventTimeout` (10 s — arrival-only, NO latency bound)
**And** the event's `paths` payload contains an entry whose basename matches the touched file (match by suffix, e.g. `endsWith('test_event_open')` — NEVER by full-path equality; macOS FSEvents delivers canonical `/private/var/…` while `Directory.systemTemp` reports `/var/…`)
**And** the test closes the handle and the worker cleanly (mirror 3.6's `setUp`/`tearDown`: `worker.close()` + recursive tempDir delete).

> Supersedes epic: `app/integration_test/watcher_e2e_test.dart` → `packages/zanshin_core/test/worker/` (the bridge lives in `packages/zanshin_core`; the coverage ratchet unions ONLY zanshin_core's `dart test`; `app/` has no `integration_test/` dir today). "payload parsed JSON matches `progress.v1.schema.json`" → superseded by ADR-0001: the payload is the FlatBuffers `WatcherEvent` table read through generated accessors — `decodeEventEnvelope` already does this; the `paths` assertion above is the surviving payload-structure check. Fixture strategy: init→close→open in a tmpdir instead of extracting `tiny-3-commits` in Dart (OQ-3, recommended default — no Dart-side tar.zst machinery, no new dep; the reactive pathway is content-agnostic).

### AC-2 — Watcher-storm sub-test (same new Dart file)

**Given** an opened repo (fresh tmpdir + `initRepo` is fine here) and an active `worker.events` subscription that collects every event for that `handleId`
**When** the test writes **50 distinct files** in a tight synchronous loop under `<tempDir>/.jj/repo/op_heads/heads/` (mirrors Rust `watcher_burst_coalesces`; the epic's "5 rapid mutations" is a floor, not a design — 5 writes coalesce to 1 event and prove nothing)
**And** then drains events until **500 ms pass without a new event** (overall hard cap ≤ 10 s)
**Then** the number of `OpHeadsChangedEvent`s observed for the handle is **≥ 1 and < 50** (debounce coalescing observed end-to-end; NEVER assert an exact count — FSEvents may legitimately split a burst across debounce windows, 3.5-R6)
**And** **no** `WatchErrorEvent` was observed
**And** the pipeline is still live afterwards: one more file write (distinct name, after the quiet period) yields a further `OpHeadsChangedEvent` within `_eventTimeout`, and the worker still answers commands — `await handle.close()` succeeding in teardown is the concrete round-trip proof (no extra command API needed).

> Reconciliation (binding): the epic's "bounded channel drop-oldest behaviour observed" is **not honestly observable at E2E level** — the 50 ms debouncer coalesces bursts long before the 256-slot channel fills, and the as-built semantics are drop-NEWEST anyway (3.5 reconciliation: which end drops is moot because watcher events are coalescing-idempotent per ADR-0002). The E2E-observable contract is **coalescing + no event-pipeline lock-up/crash under burst** — that IS Murat Szenario-2's residual concern. The channel-full drop path stays covered at unit level (`watcher.rs` `send_or_drop`).

### AC-3 — FR-RX-4 recovery test (Rust integration test)

**Given** a new test in the existing `crates/zanshin-ffi/tests/watcher.rs` (recommended placement, OQ-2 — the recovery mechanism lives entirely inside `watcher.rs`; a Dart duplicate adds flake surface and zero extra mechanism coverage), following that file's existing conventions (`pin_env()`, `test_helpers::extract_fixture("tiny-3-commits")`, `RECV_TIMEOUT = 5 s`, no `TEST_GUARD` needed — pure-watcher tests never touch the global sink)
**When** the test: (1) creates a `Watcher` on the fixture and asserts a baseline touch→`OpHeadsChanged` round-trip; (2) simulates the FS disturbance per the epic's own guidance: `fs::rename` the watched `.jj/repo/op_heads/heads` directory to an unwatched sibling inside the fixture root (same volume → atomic) and `fs::rename` it back; (3) drains rename-induced noise until 200 ms of channel silence; (4) writes a new file (e.g. `recovery_touch`) under the restored dir
**Then** an `OpHeadsChanged` event whose `paths` include `recovery_touch` arrives within `RECV_TIMEOUT` on the **same** watcher instance — no re-arm, no new `Watcher`, no process restart (FR-RX-4)
**And** `watcher.stop()` completes cleanly afterwards.

> **Escalation rule (binding):** Story 3.5 asserts recovery is "provided by `notify-debouncer-full`'s `FileIdCache`" but never proved it. If this test fails **deterministically** (FSEvents/notify does not survive the rename-away/rename-back), that is a REAL FR-RX-4 product gap in `watcher.rs` — STOP, report to Ralph with the observed behaviour, and do NOT (a) add manual reset/re-watch logic that fights the debouncer (project-context "Edge cases" rule), (b) mark the test `#[ignore]`/skip (determinism rule: a test is deterministic or deleted), or (c) quietly drop the test.

### AC-4 — Superseded / deferred epic ACs (documented, not implemented)

1. **No latency assertions anywhere** — the epic's "within 200 ms", "within 500 ms post-remount", "500 ms end-to-end", the 2× retry-on-flake wrapper, and the "250ms exceeds budget" failure-message AC are ALL dropped (WIP-rework 2026-05-17; prd.md FR-RX-1/FR-RX-2 "soft design goal … no Test-Assertion on the latency bound"; architecture.md:354). Retries are moot without a bound and would mask nondeterminism.
2. **FR-RX-2 external-edit/Watchman sub-test → DEFERRED** (OQ-1 recommended default): FR-FFI-7 (Watchman detection) is deferred, there is NO CI (GitHub = code storage; Story 1-9 backlog), the mechanism under test (Watchman triggers jj auto-snapshot) is entirely jj+Watchman machinery outside Zanshin code, and FR-RX-3 origin-equivalence means the direct op_heads touch already exercises every Zanshin-owned line of that pathway. An environment-conditional skip (`@TestOn('mac-with-watchman')`) violates the determinism rule. Record the deferral in `deferred-work.md` (release-phase item, alongside the latency assertions).
3. **Multi-watcher non-interference edge case** — already covered by 3.6 (`two_repos_open_touching_one_dispatches_only_its_handle` in Rust + `'two repos open — touching one dispatches only its handleId'` in Dart). Do not duplicate.
4. **Network-mount documentation AC** (`docs/watchman-setup.md`) — deferred with the Watchman surface; that doc does not exist in WIP.

### AC-5 — Quality gate & hygiene

1. `cargo make test` passes — run **unpiped** (never pipe to `tail`/`head`; it masks the exit code).
2. Coverage ratchet: no per-file regression. This story adds no Rust source files; the new recovery test may RAISE `crates/zanshin-ffi/src/watcher.rs` above its 96.00 baseline — if `coverage-baseline.txt` is auto-raised, **commit it together with the tests**.
3. New Dart file starts with `// SPDX-License-Identifier: MIT`; Rust test additions follow existing file style (rustfmt `max_width = 100`, clippy pedantic clean — test code included).
4. Test names describe scenarios (e.g. `watcher_recovers_after_watched_dir_moved_away_and_back`), not functions.
5. No `#[ignore]`, no `skip:`, no sleeps-as-synchronization (drain-until-quiet + bounded timeouts only).

## Tasks / Subtasks

- [x] Task 1: Dart E2E — `openRepo`-path round-trip (AC: 1)
  - [x] Create `packages/zanshin_core/test/worker/watcher_e2e_test.dart`; copy the `setUp`/`tearDown` + `_eventTimeout = Duration(seconds: 10)` skeleton from `test/worker/events_test.dart` (same imports: `worker/events.dart`, `worker/handle.dart`, `worker/isolate.dart`)
  - [x] Test: init → `await handle.close()` → `openRepo(tempDir.path)` → subscribe → touch `heads/test_event_open` → assert `OpHeadsChangedEvent` + `handleId` + `paths` suffix match
  - [x] Keep exactly ONE `ZanshinWorker` alive at a time (double `registerEventSink` throws `StateError` — 3.6 guard); sequential tests are fine because `worker.close()` unregisters
- [x] Task 2: Dart E2E — watcher-storm sub-test (AC: 2)
  - [x] Drain helper: subscribe to `worker.events`, collect events for the handle, complete after 500 ms of silence, hard-cap 10 s (a small local helper in the test file; don't add library code for it)
  - [x] Write 50 distinct files in a tight sync loop (`File(...).writeAsBytesSync(const [])` — mirror 3.6's touch idiom); assert 1 ≤ count < 50, no `WatchErrorEvent`
  - [x] Liveness: post-quiet touch → further event arrives; worker still serves commands
- [x] Task 3: Rust — FR-RX-4 recovery test in `crates/zanshin-ffi/tests/watcher.rs` (AC: 3)
  - [x] Baseline round-trip → `fs::rename(heads, fixture_root/parked_heads)` → rename back → drain until 200 ms silence (`while rx.recv_timeout(200ms).is_ok() {}`) → touch `recovery_touch` → loop-recv until `OpHeadsChanged` containing `recovery_touch` (bounded by `RECV_TIMEOUT`, drain non-matching events) → `watcher.stop()`
  - [x] On deterministic failure: STOP per AC-3 escalation rule — NOT triggered: the test passed deterministically across 6 consecutive runs (`notify-debouncer-full`'s macOS FSEvents backend does survive a same-volume rename-away/rename-back of the watched dir), so FR-RX-4 recovery is proven, not a product gap.
- [x] Task 4: Record deferrals (AC: 4)
  - [x] `deferred-work.md`: add FR-RX-2 Watchman external-edit E2E + all watcher latency assertions as release-phase items (cite this story + prd.md FR-RX-1/2 soft-target note)
- [x] Task 5: Gate (AC: 5)
  - [x] `cargo make test` unpiped, green; commit auto-raised `coverage-baseline.txt` if the recovery test lifted `watcher.rs` — not applicable: coverage held at 98.39% (2574/2616 lines), `coverage-baseline.txt` unchanged (the recovery test exercises only already-covered `watcher.rs` lines)
  - [x] Update this story's Dev Agent Record + File List; sprint-status → review

### Review Findings

> bmad-code-review 2026-07-04 (ultracode: 5 layers [Blind Hunter / Edge Case Hunter / Acceptance Auditor / Rust-timing lens / Dart-async lens], 30 raw → 19 unique findings, per-finding 2-skeptic verification [correctness + spec-grounding]; independent gate re-run + 6× flake repro of the out-of-band gate failure).

- [x] [Review][Patch] `_collectUntilQuiet` arms the 500 ms quiet timer before any event arrived — a hidden first-arrival deadline ~20× tighter than the sanctioned 10 s bound; under load (instrumented cdylib + busy host) the helper can return `[]` at t=500 ms and fail `≥ 1` as a fake FR-RX gap. Fix: complete the quiet window only after the first collected event (or guard `observed.isNotEmpty`); the 10 s `hardCap` then bounds first arrival. Deviates from AC-2's *literal* drain algorithm, sanctioned by the binding no-latency-assert constraint (AC-4.1 / Dev-Notes trap 9) — the story's conflict rule resolves toward the constraint. (Same latent shape exists in Rust `watcher_burst_coalesces` since 3.5 — pre-existing, short in-process path, empirically stable; left untouched.) [packages/zanshin_core/test/worker/watcher_e2e_test.dart:128-141]
- [x] [Review][Patch] Storm-test liveness check is satisfiable by a burst straggler: `nextMatch` filters only `handleId` + `OpHeadsChangedEvent`, so a late coalesced burst event delivered after `_collectUntilQuiet` cancelled its subscription can satisfy it before the watcher ever saw the `after_quiet` write — false pass of the "pipeline stays live" property. Fix: strengthen the predicate with `e.paths.any((p) => p.endsWith('after_quiet'))` (the AC-1-established pattern; faithful reading of AC-2's "yields"). [packages/zanshin_core/test/worker/watcher_e2e_test.dart:105-107]
- [x] [Review][Defer] Out-of-band review discovery, NOT caused by this diff: the pre-existing 3.6 test `two repos open — touching one dispatches only its handleId` failed once in the reviewer's independent gate run under heavy machine load (44 parallel review agents) — a stray event carried repo B's `handleId` although only A was touched. Log evidence matches the documented rawToId-ABA family: `event for unknown raw handle 36226958080 — dropped` immediately followed by `repo opened raw=36226958080` (freed `RepoSession` address reused while a stale event was still queued in the worker isolate's message queue). 6/6 green when re-run on an idle machine; second independent gate run green. Consequence: the ABA acceptance ("benign for coalescing-idempotent watcher events") holds for production semantics but NOT for this isolation *test*, which asserts exactly what the accepted race violates — under load it is nondeterministic. [packages/zanshin_core/test/worker/events_test.dart:79] — ~~deferred, pre-existing; correlation-id fix already tracked for Story 6-4a~~ **RESOLVED in-review (Ralph-directed pull-forward, 2026-07-04):** events now carry a process-unique, never-reused `session_id` instead of the raw handle — `schemas/envelope.fbs` (`RepoHandle.session_id` added; `WatcherEvent`/`Progress` `repo_handle` → `session_id`, in-place WIP edit + `cargo make codegen`), Rust `arm_session_with` allocates via `AtomicU64` and `spawn_dispatch_thread`/builders/`ok_repo_handle` carry it, Dart `ZanshinRawEvent.sessionId` + worker `sessionToId` demux replace `rawToId`. A stale event can now only be dropped, never misattributed — the ABA race class is dead, and the 3.6 two-repos test is deterministic under load by construction. ffi-abi.md + deferred-work.md annotated.

#### Review changes applied (2026-07-04)

Both patches + the Ralph-directed ABA pull-forward touched:

- `packages/zanshin_core/test/worker/watcher_e2e_test.dart` — patch 1 (`observed.isNotEmpty` guard in `_collectUntilQuiet` + doc) & patch 2 (`after_quiet` path predicate)
- `schemas/envelope.fbs` — `RepoHandle.session_id` added; `WatcherEvent`/`Progress`: `repo_handle` → `session_id` (in-place WIP edit)
- `crates/zanshin-ffi/src/envelope_zanshin_generated.rs`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` — regenerated via `cargo make codegen` (cbindgen/ffigen outputs unchanged — no `extern "C"` signature change)
- `crates/zanshin-ffi/src/repo.rs` — `NEXT_SESSION_ID: AtomicU64` in `arm_session_with` (returns `(handle, session_id)`); `spawn_dispatch_thread` captures the session id, not the address; producers pass both to `ok_repo_handle`
- `crates/zanshin-ffi/src/envelope.rs` — `ok_repo_handle(handle, session_id)`
- `crates/zanshin-ffi/src/events.rs` — builders tag envelopes with `session_id`; docs + unit-test assertions updated
- `crates/zanshin-ffi/tests/events_ffi.rs` — `open_handle` returns `(handle, session_id)`; matching on `session_id()`
- `packages/zanshin_core/lib/src/ffi/events.dart` — `ZanshinRawEvent.sessionId` (was `repoHandle`)
- `packages/zanshin_core/lib/src/worker/isolate.dart` — `sessionToId` demux replaces `rawToId`; ABA comment replaced by resolution note
- `packages/zanshin_core/test/ffi/events_test.dart` — ObjectBuilder params + assertions renamed
- `docs/ffi-abi.md` — `RepoHandle` payload + § "Correlation and demux" rewritten (ABA: resolved)
- `_bmad-output/implementation-artifacts/deferred-work.md` — both ABA entries annotated as resolved

## Dev Notes

### What already exists — the map (do NOT reinvent)

| Layer | File | Already covers |
|---|---|---|
| Rust watcher unit/integration | `crates/zanshin-ffi/tests/watcher.rs` | op_heads round-trip, heartbeat, missing-path → `Err(Io)`, burst coalescing (50 files, `< burst` assert, drain-until-200ms-quiet), `stop()` closes receiver, secondary-workspace `.jj/repo`-file indirection |
| Rust FFI events | `crates/zanshin-ffi/tests/events_ffi.rs` | sink round-trip via `zanshin_repo_open` on extracted fixture (AR-G-5 evidence: touch immediately after open returns), two-repo handle isolation, close-stops-dispatch negative test; helpers: `TEST_GUARD`, `RECEIVED`, `collect_until_watcher_event`, `open_handle`/`close_handle` |
| Dart decode contract | `packages/zanshin_core/test/ffi/events_test.dart` | `decodeEventEnvelope` for all 3 watcher kinds + Progress, `ffi.unknown` on non-event payload, null-for-absence, register/unregister cdylib seam |
| Dart worker E2E | `packages/zanshin_core/test/worker/events_test.dart` | **initRepo**-path op_heads round-trip w/ handleId, heartbeat, two-repo isolation, `close()` completes stream + rejects commands + no events after close, 3.9-regressions (AC 15a/15b) |

Your three tests fill the only remaining gaps: openRepo producer at Dart level (+ paths payload assert), Dart-pipeline burst behaviour, FR-RX-4 recovery.

### API cheat sheet (verified against code, 2026-07-03)

**Dart (`packages/zanshin_core`):**
- `ZanshinWorker.start()` → `Future<ZanshinWorker>` (real `Isolate.spawn`, 10 s handshake race) — `lib/src/worker/isolate.dart:111`
- `worker.openRepo(String path)` → `Future<RepoHandle>` — `isolate.dart:334`
- `worker.initRepo(String path, {required int backend})` — `backend: 0` = native/simple, `1` = Git — `isolate.dart:344`
- `worker.events` → `Stream<RepoEvent>` (broadcast; completes on shutdown; subscribe BEFORE mutating — broadcast streams don't buffer) — `isolate.dart:325`
- `RepoEvent` sealed family (`lib/src/worker/events.dart`): `OpHeadsChangedEvent(handleId, paths)`, `WorkingCopyHeartbeatEvent(handleId, paths)`, `WatchErrorEvent(handleId, message)`, `ProgressEvent(...)`
- `handle.close()` → tears down the Rust `RepoSession` (watcher stopped + dispatch thread joined before it returns — no callback after close, docs/ffi-abi.md barrier)
- `worker.close()` → `Future<void>`, graceful `ShutdownCommand` protocol, 5 s ack timeout + kill backstop, idempotent (`_closeFuture` memoized); in-flight commands may drain FIFO (AC-12 decision, Ralph 2026-07-03)

**Rust (`crates/zanshin-ffi`):**
- `Watcher::new(repo_path: &Path) -> Result<(Watcher, mpsc::Receiver<WatcherEvent>), WatcherError>` — arms synchronously; canonicalizes paths internally; watches `.jj/repo/op_heads/heads` + `.jj/working_copy/checkout`, both `NonRecursive`; 50 ms debounce; `sync_channel(256)` drop-newest
- `WatcherEvent::{OpHeadsChanged{paths}, WorkingCopyHeartbeat{paths}, WatchError{message}}`
- `watcher.stop()` — joins debouncer thread, closes channel
- Test helpers: `test_helpers::extract_fixture("tiny-3-commits")` → `Fixture { path }` in a TempDir; `pin_env()` (pins `JJ_CONFIG`/`GIT_CONFIG_GLOBAL` once via `LazyLock`); `const RECV_TIMEOUT: Duration = Duration::from_secs(5)`

### Traps (each one has bitten before or will)

1. **Garbage files in `op_heads/heads` break a subsequent jj open.** jj-lib parses every filename in that dir as an operation id at open time. Touch/pollute ONLY AFTER the last `openRepo`/`initRepo` on that directory. AC-1's init→close→open order exists precisely for this: open first, touch after.
2. **macOS `/private` canonicalization.** FSEvents delivers `/private/var/folders/…`; `Directory.systemTemp`/`TempDir` report `/var/folders/…`. `Watcher::new` canonicalizes its watch roots (3.5 critical fix), so events ARRIVE — but your `paths` assertions must match by suffix/basename, never full-path equality.
3. **Never assert exact event counts.** FSEvents may split a burst across debounce windows (3.5-R6). Assert ranges (`≥ 1 && < N`) after a quiet period.
4. **One worker at a time.** `registerEventSink` throws `StateError` on double registration (3.6 guard). `dart_test.yaml` `concurrency: 1` serializes test FILES, not tests within a file — your `setUp`/`tearDown` per-test worker (3.6 pattern) is already correct; just never overlap two live workers inside one test.
5. **Subscribe before you mutate.** `worker.events` is a broadcast stream — events emitted with no active listener are gone.
6. **Drain rename-noise before the recovery touch.** The `mv` itself generates events on the watched path (dir-level, possibly classified as `OpHeadsChanged`); drain until 200 ms of silence before touching, then loop-recv draining non-matching events until the one containing `recovery_touch` (don't assert "the next event is X").
7. **No sink guard needed in `tests/watcher.rs`.** Pure-`Watcher` tests never touch the process-global `SINK`; they run in parallel safely. `TEST_GUARD` is only for `events_ffi.rs`-style tests. Don't cargo-cult it in.
8. **`JJ_CONFIG`/`GIT_CONFIG_GLOBAL` pinning:** Rust side via `pin_env()`; Dart side handled externally by `Makefile.toml` (see comment in `zanshin_worker_test.dart:8-11`) — nothing to add in test code.
9. **Timeout discipline:** arrival timeouts are generous deadlock guards (10 s Dart / 5 s Rust), never latency claims. `future.timeout(_eventTimeout)` is the 3.6 idiom.
10. **Coverage ratchet is part of `cargo make test`** and rebuilds the cdylib instrumented + re-runs zanshin_core's `dart test` — your new Dart tests run twice per gate (normal + coverage pass); keep them fast (storm test: one repo, one worker).

### Architecture constraints that bind this story

- **Real everything:** real `Isolate.spawn`, real ffigen bindings, real cdylib, real filesystem. The isolate boundary and FFI surface are NEVER mocked (project-context "Worker / isolate testing"). The cdylib is built by the gate before `dart test` runs.
- **No latency asserts** (WIP): prd.md FR-RX-1/FR-RX-2 soft targets; architecture.md:354.
- **Watcher-armed-before-open-returns (AR-G-5):** already evidenced by 3.6's touch-immediately-after-open tests; AC-1 re-evidences it for `openRepo` at the Dart level. No tighter race assertion is possible without jj-lib fault injection (documented 3.6 decision).
- **Determinism:** no `#[ignore]`/`skip:` ever; no network; parallel-by-default except where opted out (`dart_test.yaml concurrency: 1` already committed).
- **FlatBuffers wire contract:** events are read through generated typed accessors inside `decodeEventEnvelope` — your tests consume the typed `RepoEvent` family and need no schema work.

### Previous-story intelligence (3.5 / 3.6 / 3.9)

- 3.5 deferred FR-RX-4 here verbatim: recovery is claimed via `notify-debouncer-full`'s `FileIdCache` auto-rescan but unproven — AC-3 is the proof (or the escalation).
- 3.5 reconciled the channel to `std::sync::mpsc::sync_channel(256)` **drop-NEWEST** (the AR-AD-5 "tokio + drop-oldest" wording is unbuildable); the warn text still says "dropping oldest" for grep-stability. Don't "fix" either as part of this story.
- 3.6's review hardened the sink lifecycle (unregister-is-a-barrier, held SINK lock across callback, unregister-before-kill in `_onWorkerDeath`) and accepted documented residual races (in-flight event at worker death; rawToId ABA on close→reopen — benign for coalescing-idempotent watcher events, deferred to 6-4a). Your tests must not try to assert around these accepted races.
- 3.6 decision (Ralph): `close()` drains queued commands FIFO before shutdown — a teardown-time command may legitimately succeed.
- 3.9: Model A — raw pointers never leave the worker; events carry raw `repo_handle` (u64) and are demuxed to `handleId` inside the worker. Unknown raw → logged + dropped (benign close-race).

### Git intelligence

Recent pattern (last 5 commits): `feat(zanshin-ffi): add async event sink + Dart dispatch (Story 3.6)` → `fix(zanshin-ffi): apply Story 3.5 watcher review findings` → `feat(zanshin-ffi): add watcher subsystem (Story 3.5)`. Convention: imperative subject ≤ ~60 chars, `(Story N.N)` or FR-ID reference, coverage-baseline changes committed with the code that earned them. A fitting subject here: `test(zanshin-ffi): add E2E watcher tests — storm + FR-RX-4 recovery (Story 3.10)`.

### Latest-tech note

No new libraries, no version changes. `notify-debouncer-full =0.7.0` (re-exports notify) and the FSEvents backend behaviour are as pinned/validated in Story 3.5. Nothing to research; nothing to upgrade.

### Open Questions — recommended defaults are baked into the ACs; Ralph can override

- **OQ-1 — FR-RX-2 Watchman external-edit sub-test:** recommended **defer to release phase** (AC-4.2 rationale: no Watchman surface in WIP, no CI, environment-conditional skip violates determinism, FR-RX-3 equivalence covers Zanshin's side). Alternative: a `@TestOn`-guarded test now — rejected by the determinism rule.
- **OQ-2 — recovery-test placement:** recommended **Rust `tests/watcher.rs` only** (mechanism-local, deterministic, cheap to debug). Alternative: additional Dart E2E recovery variant — adds flake surface, covers no new code.
- **OQ-3 — open-path fixture strategy:** recommended **init→close→open in a tmpdir** (no Dart tar.zst extraction, no new dep, content-agnostic pathway). Alternative: Dart-side fixture extraction helper — new machinery for zero added signal.

### Project Structure Notes

- New file: `packages/zanshin_core/test/worker/watcher_e2e_test.dart` (SPDX first line; naming mirrors sibling tests).
- Modified: `crates/zanshin-ffi/tests/watcher.rs` (append recovery test), `_bmad-output/implementation-artifacts/deferred-work.md` (FR-RX-2 + latency deferrals), possibly `coverage-baseline.txt` (auto-raise only — never hand-edit downward).
- NOT touched: any `lib/`/`src/` production code, `schemas/*.fbs`, generated bindings/headers, `docs/rust-error-codes.md`, `docs/ffi-abi.md` (no ABI change), `app/` (no `integration_test/` dir exists; epic path superseded).
- Epic-doc drift to leave alone: prd.md/epics.md/architecture.md still carry the stale `.jj/repo/working_copy/checkout` heartbeat path (3.5-R8 flagged; fix-on-next-touch belongs to a docs pass, not this story).

### References

- Epic: [epics.md](_bmad-output/planning-artifacts/epics.md) § Story 3.10 (lines 2604–2679); WIP-rework note (line 365); deferral + process-global-sink rationale (lines 1796–1803); Szenario-2 provenance (line 4618)
- PRD: [prd.md](_bmad-output/planning-artifacts/prd.md) FR-RX-1..4 (lines 292–295), NFR-P-4/P-6 (soft, lines 310–312), FR-FFI-5/6/7 (lines 244–246), Epic-C summary "functional only — no latency assert" (line 383)
- Architecture: [architecture.md](_bmad-output/planning-artifacts/architecture.md) AD-5 (line 243 ff.), watcher-test policy (line 354), AR-G-5 ordering (line 667)
- Canonical rules: [project-context.md](_bmad-output/project-context.md) §§ Watcher subsystem, Testing Rules, Coverage ratchet, Critical Don't-Miss Rules
- Prior stories: [3-5](_bmad-output/implementation-artifacts/3-5-watcher-subsystem-with-notify-debouncer-full.md) (FR-RX-4 deferral, R6/R7/R8, canonicalize fix), [3-6](_bmad-output/implementation-artifacts/3-6-nativecallable-listener-dispatch-events-progress-callbacks.md) (event sink end-to-end, shutdown protocol, test inventory), [3-9](_bmad-output/implementation-artifacts/3-9-dart-worker-isolate-bootstrap-isolate-spawn-ports-correlation.md) (worker boot, Model A)
- Code (verified): [watcher.rs](crates/zanshin-ffi/src/watcher.rs), [events.rs](crates/zanshin-ffi/src/events.rs), [tests/watcher.rs](crates/zanshin-ffi/tests/watcher.rs), [tests/events_ffi.rs](crates/zanshin-ffi/tests/events_ffi.rs), [isolate.dart](packages/zanshin_core/lib/src/worker/isolate.dart), [events.dart (worker)](packages/zanshin_core/lib/src/worker/events.dart), [events_test.dart (worker)](packages/zanshin_core/test/worker/events_test.dart), [dart_test.yaml](packages/zanshin_core/dart_test.yaml), [docs/ffi-abi.md](docs/ffi-abi.md), [docs/coverage.md](docs/coverage.md)
- ADRs: [0001 FlatBuffers transport](docs/adr/0001-ffi-data-transport-flatbuffers.md), [0002 repo state model / coalescing-idempotent events](docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md)

## Dev Agent Record

### Agent Model Used

claude-sonnet-5

### Debug Log References

- `cargo make test` (unpiped, full gate): green in 140.22s. `cargo test --workspace` all green (92 zanshin-ffi unit tests incl. the 8 `tests/watcher.rs` integration tests; 100+ across zanshin-jj/test-helpers/xtask); clippy pedantic `-D warnings` clean; `cargo fmt --check` clean; `flutter test` + `dart analyze`/`format` (app) clean; `packages/zanshin_core` `dart test` 96 tests green (incl. the 2 new `watcher_e2e_test.dart` tests) + analyze/format clean; `cargo deny check advisories bans` clean; cargo/jj-adapter hygiene checks clean; coverage ratchet: `coverage-check: OK — coverage held at 98.39% (2574/2616 lines)`, `extern-coverage: OK`. `coverage-baseline.txt` unchanged (not committed — no diff).
- New Rust test `watcher_recovers_after_watched_dir_moved_away_and_back` (AC-3) run in isolation 6 consecutive times (`cargo test -p zanshin-ffi --test watcher watcher_recovers_after_watched_dir_moved_away_and_back`) before folding into the full gate — deterministic pass every time. FR-RX-4 recovery (survives a same-volume rename-away/rename-back of the watched `op_heads/heads` dir via `notify-debouncer-full`'s macOS FSEvents backend) is empirically proven; the AC-3 escalation rule was NOT triggered.
- New Dart tests in `watcher_e2e_test.dart` (AC-1, AC-2) run standalone via `dart test test/worker/watcher_e2e_test.dart` before folding into the full gate — both passed on first run.

### Completion Notes List

- AC-1: added `packages/zanshin_core/test/worker/watcher_e2e_test.dart` group `'ZanshinWorker watcher E2E via openRepo (real cdylib)'` — init → close → `openRepo` → subscribe → touch `heads/test_event_open` → asserts `OpHeadsChangedEvent` with the **open** handle's `handleId` and a `paths` entry matching by `endsWith('test_event_open')` suffix (never full-path equality, per the `/private` canonicalization trap).
- AC-2: added the sibling group `'ZanshinWorker watcher-storm E2E (real cdylib)'` with a local `_collectUntilQuiet` helper (single subscription + idle `Timer`, no polling, no per-iteration re-subscribe) that drains events for a handle until 500 ms of silence, hard-capped at 10 s. The 50-file burst asserts `1 ≤ opHeadsEvents.length < 50` and zero `WatchErrorEvent`s, then proves pipeline liveness with a post-quiet touch + `handle.close()` round-trip.
- AC-3: added `watcher_recovers_after_watched_dir_moved_away_and_back` to `crates/zanshin-ffi/tests/watcher.rs` — baseline round-trip, `fs::rename` the watched `op_heads/heads` dir away and back (same-volume, atomic), drain rename noise until 200 ms of silence, touch `recovery_touch`, loop-recv (bounded by `RECV_TIMEOUT`, draining non-matching events) until an `OpHeadsChanged` naming `recovery_touch` arrives on the **same** `Watcher` instance. Escalation rule not triggered — recovery is real, proven deterministic across 6 runs.
- AC-4: recorded both epic-superseded deferrals (all watcher latency assertions; the FR-RX-2 Watchman external-edit sub-test + its `docs/watchman-setup.md` doc AC) in `deferred-work.md` under a new "story creation of 3-10" section, citing prd.md FR-RX-1/2 and this story.
- AC-5: full `cargo make test` gate green (see Debug Log). No production code, dependencies, codegen, `.fbs`, or error codes touched — test-only story, as scoped.
- No HALTs, no scope deviations. All three gaps identified in the story's "Scope reality check" (openRepo-path E2E, Dart-pipeline storm behaviour, FR-RX-4 recovery proof) are now closed without duplicating Story 3.6's existing `initRepo`-path coverage.

### File List

- `packages/zanshin_core/test/worker/watcher_e2e_test.dart` (new)
- `crates/zanshin-ffi/tests/watcher.rs` (modified — added `watcher_recovers_after_watched_dir_moved_away_and_back`)
- `_bmad-output/implementation-artifacts/deferred-work.md` (modified — recorded AC-4 deferrals)
- `_bmad-output/implementation-artifacts/sprint-status.yaml` (modified — status tracking)
- `_bmad-output/implementation-artifacts/3-10-end-to-end-watcher-test-filesystem-mutation-dart-callback.md` (this file — frontmatter, checkboxes, Dev Agent Record, Status)
