# Story 3.5: Watcher subsystem with `notify-debouncer-full`

---
baseline_commit: 563a0ab764b1f8dd9a8894b2afa7c9965573d5fe
---

Status: review

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Rust developer implementing the reactivity keystone,
I want a self-contained filesystem-watch subsystem in `crates/zanshin-ffi/src/watcher.rs` built on `notify-debouncer-full` (50 ms debounce window, bounded channel with backpressure, AR-AD-5),
so that changes on `.jj/repo/op_heads/heads/` (primary, real state mutations) and `.jj/repo/working_copy/checkout` (heartbeat) are coalesced and delivered to a consumer with a defined drop policy — ready for the Story 3.6 dispatch loop to forward to Dart.

## ⚠️ Read this first — scope, sequencing, and the two decisions baked in

This story was **deferred** in the 2026-06-15 WIP re-sequencing and is now being built as net-new code with **zero rework** to the existing FFI surface. Two things shaped the scope below; both are **recommendations you should implement as written unless Ralph overrides them** (see [Open Questions](#open-questions-confirm-before-or-during-implementation)):

1. **Scope = the standalone subsystem only.** This story builds `watcher.rs` + `tests/watcher.rs`. It does **NOT** touch `repo.rs`/`zanshin_repo_open`, adds **no** `extern "C"` symbol, **no** FlatBuffers schema, **no** codegen, **no** Dart. Arming the watcher inside `repo_open` (AR-G-5) and the `NativeCallable.listener` dispatch + Dart wiring belong to **Story 3.6**, which "owns the full event-sink surface end-to-end" (epics.md Story 3.6, 2026-06-21 correction). This matches the epic's Story 3.5 ACs exactly (they describe only `watcher.rs` + `Watcher::new` + `tests/watcher.rs`; the dispatch loop is attributed to 3.6). See [OQ-2](#oq-2-arming-scope--recommend-defer-arming-to-36).

2. **Channel = `std::sync::mpsc::sync_channel`, not tokio.** The literal AR-AD-5 text says `tokio::sync::mpsc` + drop-oldest. That is **unbuildable as written**: `tokio` was deliberately removed from the workspace in Story 9-0 ("dropped orphan tokio dep"), `notify-debouncer-full` v0.7 does **not** require it, and a bounded-mpsc producer **cannot** drop-oldest (it can only drop-newest or block). This is a JSON/transport-era staleness on par with the FlatBuffers reconciliations done in 3.4a/3.8/3.9. See [OQ-1](#oq-1-channel-type--drop-policy--tokio--recommend-stdsyncmpsc-drop-newest).

## Acceptance Criteria

> Reconciled from epics.md Story 3.5 (lines 2288–2357). Stale items are corrected inline and flagged in [Dev Notes › Reconciliations](#reconciliations-stale-epic-acs-corrected). ACs are functional and testable; the `< 100 ms` latency is a **soft WIP design target**, not a tight test bound (NFR-P-4 is soft in WIP; AR-P-7 allows 200 ms CI slack — this story asserts *arrival*, not a tight deadline; see [OQ flag in Dev Notes](#reconciliations-stale-epic-acs-corrected)).

1. **Module exists.** `crates/zanshin-ffi/src/watcher.rs` is created and declared `pub mod watcher;` in `lib.rs`. SPDX-License-Identifier on line 1. Every `pub` item is doc-commented (crate uses `#![deny(missing_docs)]` via workspace lints / pedantic).

2. **`WatcherEvent` enum.** Defines (NO `schema_version` field — see Reconciliation R2):
   ```rust
   pub enum WatcherEvent {
       OpHeadsChanged { paths: Vec<PathBuf> },
       WorkingCopyHeartbeat { paths: Vec<PathBuf> },
       WatchError { message: String },
   }
   ```
   `WatchError` carries the human-readable message only; the dotted `watcher.io_error` code string is assigned at the **3.6** envelope boundary (single-emission-point rule — see R3).

3. **`WatcherError` constructor-error type.** A typed `thiserror::Error` enum returned by `Watcher::new` — e.g. `Io(std::io::Error)` and/or `Notify(notify_debouncer_full::notify::Error)`. NO embedded `code: String` (R3). Distinct from the `WatcherEvent::WatchError` event variant (R3 resolves the epic's name collision).

4. **`Watcher` struct.** `pub struct Watcher { debouncer: Debouncer<RecommendedWatcher, RecommendedCache> }` (NOT `Debouncer<RecommendedWatcher>` — the v0.7 API added the cache type param; R1). The `SyncSender` is owned by the debounce handler closure, not the struct (so dropping the debouncer closes the channel — gives `stop()` semantics for free).

5. **`Watcher::new(repo_path: &Path) -> Result<(Watcher, Receiver<WatcherEvent>), WatcherError>`.** Sets up **one** debouncer (`new_debouncer(Duration::from_millis(50), None, handler)`) with **two** watches:
   - Primary: `<repo_path>/.jj/repo/op_heads/heads/` — `RecursiveMode::NonRecursive`.
   - Heartbeat: `<repo_path>/.jj/repo/working_copy/checkout` — `RecursiveMode::NonRecursive`.

   Returns the `Watcher` plus the receiving end of the bounded channel.

6. **Bounded channel, capacity 256** (AR-AD-5). Created inside `new`; the `Receiver`/`SyncSender` pair is `std::sync::mpsc::sync_channel(256)` (R-channel / OQ-1).

7. **`op_heads/heads/` event → `OpHeadsChanged`.** A debounced filesystem event whose path is under the primary watch produces `WatcherEvent::OpHeadsChanged { paths }` sent on the channel.

8. **`working_copy/checkout` event → `WorkingCopyHeartbeat`.** A debounced event under the heartbeat watch produces `WatcherEvent::WorkingCopyHeartbeat { paths }`.

9. **Backpressure: channel-full → drop + warn.** On a full channel the send drops one event and logs exactly `tracing::warn!("watcher channel full, dropping oldest")` (message text per epic AC; **drop-newest** under the recommended `sync_channel` — the log text is kept verbatim for grep-compatibility, the *behavior* is reconciled in R-channel/OQ-1). Never panics, never blocks the debouncer thread.

10. **`Watcher::stop(self)`.** Consumes `self`, drops the debouncer (stops both OS watches and the handler/sender), so the `Receiver` observes channel close (`recv()` → `Err(RecvError)`; the std equivalent of "Receiver gets `None`").

11. **Path classification ignores noise.** Events whose path is under neither watch are dropped (not sent). A pure `classify(&Path, &op_heads_dir, &checkout_path) -> Option<EventKind>` helper makes this branch unit-testable (satisfies the "Spotlight indexing noise" edge case without FS timing).

12. **`Watcher::new` on a non-existent path → `Err`.** When `<repo_path>/.jj/repo/op_heads/heads/` does not exist, `notify`'s `watch()` errors and `new` returns `Err(WatcherError::Io(_)/Notify(_))` (epic's `watcher.io_error` — the string code is the 3.6 envelope mapping, R3).

### Edge cases (ACs continued)

13. **Debounce coalescing.** A rapid burst of many events on `op_heads/heads/` within ~10 ms collapses (via the 50 ms window) into a small number of `OpHeadsChanged` events — **assert "coalesced, not one-per-FS-event" (e.g. `< burst_count`)**, not exactly-1 (FSEvents may legitimately split a burst; R6).

14. **Auto-rescan on disappear/reappear (FR-RX-4).** Documented as provided by `notify-debouncer-full`'s `FileIdCache` (the reason debouncer-**full** is chosen over -mini). **Not** unit-tested here — a deterministic unmount/remount can't be simulated in a unit test; the recovery assertion lives in Story 3.10 (R7). Do NOT hand-roll manual reset logic that fights the debouncer (project-context anti-pattern).

15. **Single-watcher isolation.** Each `Watcher` instance owns its own debouncer + channel (the multi-`Watcher`/multi-repo isolation in 3.10 builds on this). Multi-repo per-project watchers + a correlation id are explicitly a **later** story (deferred-work.md), out of scope here.

### Test ACs

16. **Inline unit tests** (`#[cfg(test)] mod tests` at the bottom of `watcher.rs`, for private items) cover at minimum: `classify` for each branch (op_heads → kind, checkout → kind, unrelated → `None`); the channel-full drop path (build a `sync_channel(1)`, fill it, send once more, assert the drop + that a warn is emitted). These count toward coverage.

17. **Integration tests** (`crates/zanshin-ffi/tests/watcher.rs`, public-API + real fixture) cover: extract `tiny-3-commits`; `Watcher::new`; touch a file under `.jj/repo/op_heads/heads/` → assert an `OpHeadsChanged` arrives (functional, via a generous `recv_timeout` deadlock-guard, not a tight 200 ms bound — R5); touch `working_copy/checkout` → `WorkingCopyHeartbeat`; non-existent path → `Err`; burst → coalesced (AC 13); `stop()` → receiver disconnects. Pin `JJ_CONFIG`/`GIT_CONFIG_GLOBAL` to `""` (test-convention, see `status_ffi.rs`).

18. **`cargo make test` is green** (the single quality gate): `cargo test`, clippy pedantic `-D warnings`, rustfmt, `cargo deny check advisories bans`, and the **coverage ratchet**. `watcher.rs` is a **new file** → must reach `new_file_floor_pct = 80.00`; commit the auto-raised `coverage-baseline.txt` row.

## Tasks / Subtasks

- [x] **Confirm the two decisions** (AC: all) — read [Open Questions](#open-questions-confirm-before-or-during-implementation). If Ralph hasn't weighed in, implement the recommended defaults (std `sync_channel`/drop-newest; subsystem-only/no `repo_open` arming; `=0.7.0` exact pin) and note the choice in the Dev Agent Record.
- [x] **Add the dependency** (AC: 4, 5)
  - [x] Root `Cargo.toml` `[workspace.dependencies]`: add `notify-debouncer-full = "=0.7.0"` (pre-1.0 load-bearing → exact pin, matching the jj-lib/rmcp discipline; confirm in [OQ-3](#oq-3-version-pin-minor)). Add a `# WHY:` note (watcher core; re-exports `notify`).
  - [x] `crates/zanshin-ffi/Cargo.toml` `[dependencies]`: add `notify-debouncer-full = { workspace = true }`.
  - [x] Do **NOT** add a separate `notify` dependency — reference `notify` types via the re-export `notify_debouncer_full::notify::{RecommendedWatcher, RecursiveMode, Error, …}` to guarantee version match (R4).
  - [x] Do **NOT** re-add `tokio` (R-channel).
  - [x] Run `cargo deny check advisories bans` — confirm `notify`/`notify-debouncer-full` and their transitive deps pass (permissive licenses expected: notify is `CC0-1.0 OR Artistic-2.0`, debouncer-full is MIT).
- [x] **Implement `watcher.rs`** (AC: 1–11)
  - [x] SPDX line 1; module doc-comment; `pub mod watcher;` in `lib.rs` (keep the existing alphabetical-ish ordering — insert after `tracing_init` or in sorted position).
  - [x] `WatcherEvent` enum (R2: no `schema_version`), `WatcherError` thiserror enum (R3), `Watcher` struct (R1: two type params).
  - [x] `classify(path, &op_heads_dir, &checkout_path) -> Option<…>` pure helper (path-prefix match; `Path::starts_with`). Compute `op_heads_dir` and `checkout_path` once in `new`.
  - [x] `send_or_drop(&SyncSender<WatcherEvent>, WatcherEvent)` helper: `try_send`; on `Err(TrySendError::Full(_))` → `tracing::warn!("watcher channel full, dropping oldest")` and drop; on `Err(Disconnected)` → drop quietly (consumer gone). Keep these as small free fns so unit tests hit the branches without FS timing.
  - [x] Debounce handler closure (`move |res: DebounceEventResult| { … }`, captures the `SyncSender` + the two precomputed paths): on `Ok(events)` classify each and `send_or_drop`; on `Err(errors)` send a single `WatcherEvent::WatchError { message }` (join the notify errors). The closure runs on the debouncer's own thread → must be `Send + 'static` and must never block/panic.
  - [x] `Watcher::new`: create `sync_channel(256)`; `new_debouncer(Duration::from_millis(50), None, handler)`; `.watch(op_heads_dir, NonRecursive)` then `.watch(checkout_path, NonRecursive)`; map `notify`/io errors → `WatcherError`; return `(Watcher { debouncer }, receiver)`.
  - [x] `Watcher::stop(self)` (drop is sufficient; the explicit method documents intent and is an AC).
  - [x] Inline `#[cfg(test)] mod tests` (AC 16).
- [x] **Implement `tests/watcher.rs`** (AC: 17) — mirror `status_ffi.rs` style: `pin_env()` (`JJ_CONFIG`/`GIT_CONFIG_GLOBAL` = `""`), `extract_fixture("tiny-3-commits")`, `recv_timeout` deadlock-guard, leak-clean.
- [x] **Run the gate** (AC: 18) — `cargo make test`; fix clippy/fmt; confirm `watcher.rs ≥ 80 %`; commit the raised `coverage-baseline.txt`.
- [x] **Update the error registry note** — leave `watcher.io_error` / `watcher.watchman_not_configured` rows **Reserved** in `docs/rust-error-codes.md` (this story does not emit them across FFI; 3.6 flips `watcher.io_error` to Emitted). Add a one-line pointer that 3.5 introduced the typed `WatcherError`/`WatchError` that 3.6 will map. (No `envelope.rs` const here — R3.)

## Dev Notes

### What this story is, in one paragraph

A pure-Rust, in-crate (`zanshin-ffi`) filesystem-watch subsystem. It has **no FFI surface of its own** — it is plumbing that Story 3.6 will consume. The `Watcher` owns a `notify-debouncer-full` debouncer watching two jj paths; debounced events are classified by path and pushed onto a bounded `std::sync::mpsc::sync_channel(256)`; the `Receiver` is handed back to the caller (a test today; the 3.6 dispatch loop tomorrow). Because there is no `extern "C"` symbol, there is **no codegen, no `.fbs`, no `bindings.dart`/`zanshin_ffi.h`, no Dart, no cross-FFI coverage test** — a refreshing simplification versus the 3.4* wrapper stories.

### Architecture & requirements anchors

- **AR-AD-5 (Watcher Coalescing & Backpressure)** — `notify-debouncer-full`, 50 ms debounce, bounded channel cap 256, drop-on-full + `tracing::warn!`, auto-rescan on path disappear/reappear. **The op-heads watcher is also the coherency trigger** (op-id compare), not just a UI ping: a missed event delays a refresh but can't produce a silently-stale view because no authoritative repo state is held (ADR-0002). [Source: epics.md#AR-AD-5 (line 186); project-context.md › Watcher subsystem]
- **AR-G-5 (init ordering)** — the watcher must start *before* `zanshin_repo_open` returns; "mutations between open-call-start and watcher-arm would silently disappear." This invariant is **realized in 3.6** (which arms the watcher in `repo_open`), not here — but design `Watcher::new` so it is cheap and synchronous enough to call inline within `repo_open` (no async, no long blocking). [Source: epics.md#AR-G-5 (line 221); project-context.md › Edge cases]
- **FR-FFI-5 / FR-RX-1 / FR-RX-4** — watch `op_heads/heads/` (primary) + `working_copy/checkout` (heartbeat); op_heads change → callback; recover from FS disturbances. [Source: epics.md lines 74, 115, 118]
- **The two watched paths matter and are not interchangeable:** `op_heads/heads/` is where *real* state mutations land (any jj op, GUI/MCP/CLI alike — same-repo concurrency via filesystem, FR-MCP-9, no IPC/locks); `working_copy/checkout` is a heartbeat that fires on any jj activity. The consumer (3.6) treats `OpHeadsChanged` as "re-resolve to head"; the heartbeat is a weaker signal. [Source: project-context.md › Watcher subsystem; › Same-repo concurrency]

### Decision: channel + drop policy (the crux) — recommend std `sync_channel`, drop-newest

The literal AR-AD-5 (`tokio::sync::mpsc` + drop-oldest) **cannot be implemented as written**, for three independent reasons:

1. **No tokio in the workspace.** Story 9-0 removed it ("dropped orphan tokio dep"). `notify-debouncer-full` v0.7 is synchronous (own background thread, std callback) and does **not** pull tokio. (project-context.md's parenthetical "tokio … e.g. … notify-debouncer-full" is itself stale for v0.7.)
2. **No async consumer exists.** Today's consumer is a test; 3.6's is a synchronous drain that calls a `NativeCallable` C function pointer. Nothing `.await`s. The async boundary lives entirely on the **Dart** side (the worker isolate).
3. **Bounded-mpsc producers can't drop-oldest.** Neither `tokio::sync::mpsc` nor `std::sync::mpsc::sync_channel` lets the *sending* end evict the front; both can only drop-newest (via `try_send`) or block. So "tokio + drop-oldest" was never coherent.

**Recommendation (implement unless Ralph picks the alternative):** `std::sync::mpsc::sync_channel(256)`; on `try_send` → `Full`, log the warn and drop the just-arrived event (drop-newest). This is **correct here** because op_heads/heartbeat events are **coalescing-idempotent**: the 3.6 consumer always *re-resolves to head* (ADR-0002), and head-on-disk is always current, so which end is dropped under pathological overflow does not affect the resulting view. The 256-cap is purely an OOM backstop; the 50 ms debounce already collapses bursts long before it's reached. Keep the warn text verbatim (`"watcher channel full, dropping oldest"`) for log-grep stability and to flag the (rare) overflow.

**Alternative (only if Ralph wants the documented policy literally):** a ~40–50-line bounded `Arc<(Mutex<VecDeque<WatcherEvent>>, Condvar)>` ring with true drop-oldest (std-only, no tokio). More surface to test/maintain for a functionally-moot difference. See [OQ-1](#oq-1-channel-type--drop-policy--tokio--recommend-stdsyncmpsc-drop-newest). **Do not** re-add tokio just to match the type name — it buys nothing and still can't drop-oldest.

### Reconciliations (stale epic ACs corrected)

| # | Epic text (stale) | Corrected | Why |
|---|---|---|---|
| R1 | `Debouncer<RecommendedWatcher>` | `Debouncer<RecommendedWatcher, RecommendedCache>` | v0.7.0 `new_debouncer` returns the 2-param type. [docs.rs/notify-debouncer-full 0.7.0] |
| R2 | `WatcherEvent` variants carry `schema_version: &'static str` | dropped | `WatcherEvent` is an internal Rust enum (doesn't cross FFI in 3.5); ADR-0001 forbids in-wire `schema_version` anyway. [project-context.md `overrides:`; mem: epics.md-FFI-ACs-predate-FlatBuffers] |
| R3 | `WatcherEvent::WatcherError { code: String, message: String }` and `Watcher::new -> …WatcherError` (same name; embedded `code` string) | event variant `WatchError { message }`; separate typed `enum WatcherError` (thiserror) for the `new` Result; **no** embedded code string | Resolves the name collision; honors the single-emission-point rule (all `error.code` strings live in `envelope.rs`, assigned at the 3.6 boundary). [rust-error-codes.md › Convention; project-context.md › Error code taxonomy] |
| R4 | (implicit) add `notify` dep | reference `notify` via `notify_debouncer_full::notify::…` re-export; no separate dep | avoids version skew between notify and debouncer-full. |
| R5 | "assert the event arrives within **200 ms**" | assert *arrival* via a generous `recv_timeout` deadlock-guard; the `<100/200 ms` budget is a **soft** WIP design target asserted nowhere tight | NFR-P-4 is soft in WIP; the project bans `#[ignore]`/flaky tests, and a tight FS-timing bound is flaky on CI. Consistent with Story 3.10's explicit "drop the latency assertion." [epics.md lines 357, 2608; project-context.md › Performance assertions DEFERRED] |
| R6 | burst "collapse into a **single** event … no event dropped" | assert *coalesced* (count `< burst_count`), not exactly-1 | FSEvents may legitimately split a burst into a few debounced batches; exactly-1 is flaky. |
| R7 | unit-test the auto-rescan (FR-RX-4) | document it as `FileIdCache`-provided; assert recovery in 3.10 | a deterministic unmount/remount isn't simulable in a unit test. |
| R-channel | `tokio::sync::mpsc`, drop-oldest | `std::sync::mpsc::sync_channel(256)`, drop-newest (recommended) | see [Decision: channel](#decision-channel--drop-policy-the-crux--recommend-std-sync_channel-drop-newest) / OQ-1. |

### `notify-debouncer-full` v0.7.0 API cheat-sheet (get these right)

```rust
use notify_debouncer_full::{new_debouncer, Debouncer, DebounceEventResult, RecommendedCache};
use notify_debouncer_full::notify::{RecommendedWatcher, RecursiveMode};

// returns Result<Debouncer<RecommendedWatcher, RecommendedCache>, notify::Error>
let mut deb = new_debouncer(
    Duration::from_millis(50),
    None,                       // tick_rate: Option<Duration>
    move |res: DebounceEventResult| { /* Ok(Vec<DebouncedEvent>) | Err(Vec<notify::Error>) */ },
)?;
deb.watch(&op_heads_dir, RecursiveMode::NonRecursive)?;   // method is on the Debouncer
deb.watch(&checkout_path, RecursiveMode::NonRecursive)?;
```
- `DebounceEventResult = Result<Vec<DebouncedEvent>, Vec<notify::Error>>`. `DebouncedEvent` derefs to `notify::Event`; use `event.paths` for classification.
- The debouncer runs its own thread; dropping the `Debouncer` stops it (so `stop(self)`/drop closes the channel). **Confirm exact import paths against the installed v0.7.0** (e.g. whether `RecommendedWatcher` is also re-exported at the crate root) — don't guess; the crate moved items across recent versions. [Source: docs.rs/notify-debouncer-full/0.7.0]
- macOS uses FSEvents for `RecommendedWatcher`. `NonRecursive` is honored by notify's event filtering; the explicit `classify` step (AC 11) is the belt-and-suspenders against FSEvents' inherently-recursive kernel notifications.

### Existing patterns to reuse (do NOT reinvent)

- **Fixture extraction:** `test_helpers::extract_fixture("tiny-3-commits")` → `FixtureHandle { path }` (temp dir, auto-cleaned). [crates/test-helpers/src/lib.rs]
- **Integration-test skeleton:** copy the shape of `crates/zanshin-ffi/tests/status_ffi.rs` — `LazyLock` env pin, `cstr` helper, leak-clean teardown. (Watcher tests don't deal in `ZanshinBuf`/Envelope — they consume `WatcherEvent` directly — so skip the `read_and_free`/`parse_envelope` helpers.)
- **Tracing:** `tracing::warn!`/`debug!` are already wired (`tracing_init.rs`); just call the macros. No new sink.
- **`lib.rs` mod list:** add `pub mod watcher;` alongside the existing `pub mod {bookmarks, change, …};` block.

### Coverage

- `watcher.rs` is a **new file** → the ratchet's `new_file_floor_pct = 80.00` applies. The `classify` + `send_or_drop` free fns + inline tests are the cheap way to clear the floor deterministically (no reliance on FS timing for the bulk of branches); the integration test covers the real debouncer path. There is **no `extern "C"` fn here**, so the `project-coverage-extern-fn-needs-zanshin-core-test` trap does **not** apply — coverage comes entirely from cargo tests (inline + `tests/watcher.rs`). Commit the auto-raised baseline row with the code. [Source: docs/coverage.md; coverage-baseline.txt]

### Anti-patterns to avoid (review-blockers)

- No `tokio` re-introduction (R-channel). No async wrapping of synchronous notify work.
- No manual reset/rescan logic fighting the debouncer (FR-RX-4 is the crate's job). [project-context.md › Edge cases]
- No `extern "C"`, no `.fbs` edit, no `cargo make codegen`, no Dart — that's 3.6. Keeping `repo_open`'s signature unchanged is the load-bearing assumption of the whole 2026-06-15 re-sequencing. [epics.md lines 1803, 2111-2113]
- No `error.code` string literal outside `envelope.rs` (R3). No panic/`unwrap`/`expect` on the debouncer thread.
- No multi-repo/correlation-id machinery — single `Watcher` per repo; multi-repo is a separate later story. [deferred-work.md line 102]

### Project Structure Notes

- New: `crates/zanshin-ffi/src/watcher.rs`, `crates/zanshin-ffi/tests/watcher.rs`.
- Edit: `crates/zanshin-ffi/src/lib.rs` (`pub mod watcher;`), `Cargo.toml` (workspace dep), `crates/zanshin-ffi/Cargo.toml` (crate dep), `coverage-baseline.txt` (auto), `docs/rust-error-codes.md` (one-line pointer; rows stay Reserved).
- Module-by-noun layout (AR-P-3): `watcher.rs` is the canonical name listed in the `zanshin-ffi` module layout. No conflict.
- Untouched: `repo.rs`, `envelope.rs`, `handle.rs`, all schemas, all generated code, all Dart.

### References

- [Source: epics.md#Story-3.5 (lines 2288–2357)] — base ACs (reconciled above).
- [Source: epics.md#Story-3.6 (lines 2361–2434, esp. 2365 correction)] — the consumer/dispatch/arming this story stops short of.
- [Source: epics.md#Story-3.4a (lines 2067–2113)] — `repo_open` deliberately does not arm a watcher; signature must stay stable.
- [Source: epics.md AR-AD-5 (186), AR-G-5 (221), AR-P-7 (199); FR-FFI-5/6 (74-75), FR-RX-1/2/4 (115-118)]
- [Source: _bmad-output/project-context.md › Watcher subsystem; › Error code taxonomy; › Coverage ratchet; › Critical Don't-Miss Rules]
- [Source: docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md] — coherency-trigger / re-resolve-per-op rationale (why drop policy is idempotent).
- [Source: docs/rust-error-codes.md] — `watcher.io_error` / `watcher.watchman_not_configured` Reserved rows.
- [Source: crates/zanshin-ffi/tests/status_ffi.rs; crates/test-helpers/src/lib.rs] — test + fixture patterns.
- [Source: crates/zanshin-ffi/src/repo.rs; src/lib.rs] — current FFI module layout (unchanged here).
- [Source: docs.rs/notify-debouncer-full/0.7.0] — `new_debouncer` signature, `DebounceEventResult`, threading, no-tokio.
- [Source: _bmad-output/implementation-artifacts/deferred-work.md line 102] — multi-repo watcher is a later story.

## Open Questions (confirm before/during implementation)

> Per the workflow, these are recorded for Ralph but the story is **ready-for-dev** with the recommended defaults baked into the ACs/Tasks. If Ralph doesn't respond, the dev agent implements the recommendations and records the choice.

### OQ-1: channel type + drop policy + tokio — *recommend `std::sync::mpsc`, drop-newest*
The literal AR-AD-5 (`tokio::sync::mpsc` + drop-oldest) is unbuildable (tokio removed in 9-0; debouncer-full doesn't need it; bounded-mpsc can't drop-oldest). **Recommended:** `std::sync::mpsc::sync_channel(256)`, drop-newest on full + warn — correct because events are coalescing-idempotent (consumer re-resolves to head, ADR-0002). **Alternative:** custom `Mutex<VecDeque>+Condvar` ring for true drop-oldest (std-only, ~50 LOC). Pick the recommended unless you specifically want the documented drop-oldest policy realized exactly.

### OQ-2: arming scope — *recommend defer arming to 3.6*
Does 3.5 also arm the watcher inside `repo_open` (requires refactoring the leaked-`Box<Repo>` handle into a `RepoHandle { repo, watcher, receiver }` struct and holding an *undrained* receiver until 3.6), or is arming deferred to 3.6 (which "owns the event-sink surface end-to-end")? **Recommended:** defer to 3.6 — 3.5 = pure subsystem, matching the epic's 3.5 ACs and avoiding dead plumbing. The "signature unchanged" guarantee holds either way. (The 3.4a/sprint-status cross-references that say "arming added in 3.5" were written when 3.5+3.6 were deferred as a pair; the clean split puts arming with the dispatch that consumes it.)

### OQ-3: version pin — *minor*
`notify-debouncer-full` is pre-1.0 (0.7.0). **Recommended:** exact pin `=0.7.0` (load-bearing watcher, matching the jj-lib/rmcp/imara-diff pre-1.0 discipline). Caret `0.7` is the alternative if Ralph prefers to absorb patch bumps automatically.

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

- **macOS FSEvents path canonicalization (critical fix):** `TempDir::path()` returns `/var/folders/…` but FSEvents delivers canonical `/private/var/folders/…`. `classify()` returned `None` for all events, silently dropping them. Fixed by `repo_path.canonicalize()` at the top of `Watcher::new`; added `WatcherError::Io(#[from] std::io::Error)` variant to propagate the `io::Error` from `canonicalize()`.
- **Heartbeat path discrepancy (spec bug):** Story spec and epics.md say `<repo_path>/.jj/repo/working_copy/checkout`. jj-lib `workspace.rs:140` sets `working_copy_state_path = jj_dir.join("working_copy")` where `jj_dir = workspace_root/.jj`. Correct path is `.jj/working_copy/checkout` (NOT `.jj/repo/working_copy/checkout`). Implemented with the correct path; documented with `// WHY:` comment.
- **`Debouncer::stop()` vs `drop`:** `Debouncer::drop` only sets an atomic stop flag (non-blocking). `Debouncer::stop()` joins the background thread, guaranteeing the handler's `SyncSender` is dropped synchronously. Used `self.debouncer.stop()` in `Watcher::stop(self)` so `rx.recv()` returns `Err(RecvError)` immediately after `stop()` returns.
- **Clippy `match_same_arms`:** Original `send_or_drop` had `Ok(()) => {}` and `Err(Disconnected) => {}` as identical arms. Restructured to `if let Err(TrySendError::Full(_)) = tx.try_send(event)` pattern.

### Completion Notes List

- Implemented recommended OQ-1 default: `std::sync::mpsc::sync_channel(256)`, drop-newest on full, verbatim warn text.
- Implemented recommended OQ-2 default: subsystem-only, no `repo_open` arming (deferred to Story 3.6).
- Implemented recommended OQ-3 default: exact pin `=0.7.0`.
- `watcher.rs` achieved 93.59% line coverage (floor: 80%); `coverage-baseline.txt` auto-raised.
- All ACs satisfied; `cargo make test` green (cargo test + clippy pedantic + rustfmt + flutter test + dart analyze/format + cargo deny + coverage ratchet).

### File List

**Created:**
- `crates/zanshin-ffi/src/watcher.rs`
- `crates/zanshin-ffi/tests/watcher.rs`

**Modified:**
- `Cargo.toml` — added `notify-debouncer-full = "=0.7.0"` to `[workspace.dependencies]`
- `Cargo.lock` — updated by cargo
- `crates/zanshin-ffi/Cargo.toml` — added `notify-debouncer-full = { workspace = true }` and `thiserror = { workspace = true }`
- `crates/zanshin-ffi/src/lib.rs` — added `pub mod watcher;`
- `coverage-baseline.txt` — auto-raised (new row: `watcher.rs` at 93.59%)
- `docs/rust-error-codes.md` — updated `watcher.io_error` row with pointer to Story 3.5

### Change Log

- 2026-06-28: Story 3.5 implemented — `watcher.rs` subsystem with `notify-debouncer-full` v0.7.0; 93.59% coverage; gate green.
