# Story 3.3: Tracing init with rotating file sink

---
baseline_commit: d9c28ce
---

Status: done

> **⚠️ Scope-reconciliation (binding — WIP-shrink 2026-05-17 + the 3-0/3-1/3-2 reality, 2026-06-15):**
> The epic's Story 3.3 text (`epics.md:1794`) predates the FlatBuffers transport (ADR-0001) and the
> 3-0…3-2 work. Three reconciliations apply and are **binding**:
>
> 1. **WIP-shrink (epics.md:1796):** rotation-policy tests, log-size-cap ACs, and structured-event-schema
>    validation ACs are **dropped**. This story delivers the tracing init + daily file sink + `ZANSHIN_LOG`
>    level filtering + debug-only stderr, and nothing more. The "future story may add size/age-cap" note
>    (epic AC, `epics.md:1838`) is captured as a one-line module-doc comment — **do not** build retention.
> 2. **Infrastructure-only, like 3-2:** there is **no fallible `extern "C"` FFI function yet** (the first,
>    `zanshin_repo_open`, lands in **3-4a**). So the epic's "wrap subsequent FFI calls in
>    `info_span!("ffi_call", …)`" and "init runs when the cdylib is loaded via the first FFI call" ACs are
>    **forward-looking**. This story builds and unit-tests `init_tracing()` in isolation and proves the
>    subscriber **records** `ffi_call` span fields; the per-call `info_span!` wrapping and the call site
>    (`zanshin_worker_init` in **3-9**, plus each 3-4a wrapper) land in those stories. This mirrors how 3-2
>    landed `handle.rs` with "no FFI consumer yet — that is expected."
> 3. **`init_tracing()` is a Rust-internal `pub fn`, NOT an `extern "C"` symbol.** It adds **no** symbol to
>    `zanshin_ffi.h` / `bindings.dart` → **no `cargo make codegen` run, no generated-file diff** in this
>    story (the opposite of 3-2, which changed a signature). It also emits **no `error.code`** → **no
>    `docs/rust-error-codes.md` change**. Logging-init failures use `eprintln!` once at init, never an
>    envelope error.

---

## Story

As a developer setting up structured logging for the Zanshin Rust core,
I want `tracing` + `tracing-appender` initialized via a new `crates/zanshin-ffi/src/tracing_init.rs::init_tracing()`
that installs a daily-rotating file sink at `~/Library/Logs/Zanshin/zanshin.log.YYYY-MM-DD`, reads the level
from `ZANSHIN_LOG` (default `info`), and adds a stderr layer only in debug builds,
so that every future FFI call and watcher event is traceable per AR-P-5 with **zero stdout/stderr output in
release builds**, and so 3-4a / 3-9 can wire it in as a thin step (FR-FFI-9-adjacent, AR-P-5).

**This story sits on top of Stories 3-0, 3-1, and 3-2.** It is pure new infrastructure inside `zanshin-ffi`:
one new module file + the workspace/crate dependency wiring + a one-line `pub mod` declaration in `lib.rs`.
It does **not** touch `envelope.rs`, `ffi_strings.rs`, `handle.rs`, `build.rs`, the generated header/bindings,
or the error-code registry.

---

## Acceptance Criteria

> These criteria reconcile the epic's Story 3.3 GWT (`epics.md:1794`) with the WIP-shrink and the
> post-3-0/3-1/3-2 reality (see the scope-reconciliation callout). Behavioural requirements (daily file
> sink, `ZANSHIN_LOG` default `info`, debug-only stderr, idempotent init, dir-creation + fallback, never
> panic) are binding. The dropped ACs (rotation tests, log-cap, schema-validation) and the forward-looking
> ACs (per-call `info_span!` wiring, ctor/first-call wiring) are reconciled as noted.

### AC-1 — `tracing_init.rs` (new) — `pub fn init_tracing()`

1. `crates/zanshin-ffi/src/tracing_init.rs` is **created**, starts with `// SPDX-License-Identifier: Apache-2.0`
   on the **first line**, and is declared `pub mod tracing_init;` in `lib.rs` (AR-P-3 module layout, noun-per-file).
2. It defines `pub fn init_tracing()` that installs a **process-global** `tracing_subscriber` registry composed of
   (a) an `EnvFilter`, (b) a daily-rotating file `fmt` layer, and (c) — **only** in debug builds — a stderr `fmt` layer.
3. `init_tracing()` is **idempotent**: guarded by `std::sync::Once` and installed via `.try_init()` (not `.init()`),
   so a second (or concurrent) call is a no-op and **never** panics with a "global subscriber already set" error.

### AC-2 — Daily file sink at `~/Library/Logs/Zanshin/zanshin.log.YYYY-MM-DD`

4. The file layer uses `tracing_appender::rolling::daily(<log_dir>, "zanshin.log")`, which produces files named
   `zanshin.log.YYYY-MM-DD` (the prefix + `.` + UTC date is `tracing-appender`'s built-in daily naming) at
   `<log_dir>` = `~/Library/Logs/Zanshin/`.
5. The file layer sets `.with_ansi(false)` (no ANSI colour escapes in the on-disk log).
6. Use the **blocking** `RollingFileAppender` directly as the layer's `MakeWriter` — **not** `tracing_appender::non_blocking`.
   Rationale (binding, see Dev Notes): the non-blocking path returns a `WorkerGuard` that must be held for the process
   lifetime and is the only thing that flushes the background thread on shutdown; the cdylib has no clean teardown hook
   to drop such a guard, so a blocking appender (each event `write`-flushed) better satisfies the "earlier lines
   preserved on crash, flush-on-drop where possible" requirement without the guard-lifetime footgun.

### AC-3 — Level from `ZANSHIN_LOG`, default `info`

7. The `EnvFilter` is built from the `ZANSHIN_LOG` env var (RUST_LOG directive syntax, per AR-P-5 / project-context
   § Logging discipline). When `ZANSHIN_LOG` is **unset, empty, or unparseable**, the filter defaults to `info`.
8. When `ZANSHIN_LOG=debug` (or any valid directive), the subscriber respects it — `debug`+ events are enabled.

### AC-4 — Debug-only stderr; release builds are silent

9. A stderr `fmt` layer is added **only** when `cfg!(debug_assertions)` is true (debug/dev builds). In release builds
   the stderr layer is absent — **no stdout/stderr output in release** (AR-P-5, project-context § Logging discipline,
   "NO console output in release builds"). Implement with an `Option<Layer>` (a `None` layer is a no-op `Layer`) so the
   registry type compiles in both build modes without `#[cfg]` on the `with(...)` chain.
10. Compile-time level cap: `zanshin-ffi` enables `tracing`'s `release_max_level_info` feature so `debug`/`trace`
    statements are **compiled out** of release builds entirely (zero-cost), satisfying project-context's "debug
    (per-call entry/exit) compiled out in release" and "PII is debug-only and compiled out of release". (This is the
    compile-time complement to the runtime `EnvFilter`.)

### AC-5 — Log-dir creation + home-dir resolution, never panics

11. Before constructing the appender, `init_tracing()` ensures `<log_dir>` exists via `std::fs::create_dir_all`.
    On error (permission denied, sandbox), it logs **once** via `eprintln!` at init time (acceptable at init only;
    later FFI calls produce no stderr) and **continues** — it must **never panic or abort**.
12. The log dir is resolved from `$HOME`: `~/Library/Logs/Zanshin`. When `$HOME` is unset/unavailable (edge case),
    resolution falls back to `std::env::temp_dir().join("Zanshin")` (a writable location) rather than panicking.
    Use `std::env::var_os("HOME")` — **do not** add the `dirs` crate (dependency minimalism; macOS-only target makes
    `$HOME` sufficient, and the epic explicitly allows `std::env::var("HOME")` as the resolution path).

### AC-6 — Span-recording readiness (forward-looking, reconciled)

13. The installed subscriber must **record span context** so that future FFI wrappers (3-4a) entering
    `tracing::info_span!("ffi_call", fn_name = %fn_name, command_id = ?command_id, handle_id = ?handle_id)` produce
    log lines carrying those fields. This is satisfied by the default `fmt` layer (which renders the current span's
    name + fields). **No per-call `info_span!` wrapping is added in this story** — there is no fallible `extern "C"`
    fn to wrap yet (first is `zanshin_repo_open`, Story 3-4a). The span-recording is **proved by a unit test** (AC-8.18),
    and the per-call wrapping convention is documented in Dev Notes for 3-4a to apply.

### AC-7 — Dependencies wired (exact stack, correct features)

14. `[workspace.dependencies]` (root `Cargo.toml`) gains:
    ```toml
    tracing = "0.1"
    tracing-subscriber = { version = "0.3", features = ["env-filter"] }
    tracing-appender = "0.2"
    ```
    Caret pins (not `=`): the `tracing` ecosystem is treated as **stable** here (it is not in the project's
    exact-pin load-bearing list `jj-lib`/`rmcp`/`imara-diff`; project-context § Version pinning rules → "Stable
    crates: caret"). `env-filter` is **not** a default feature of `tracing-subscriber` — it must be enabled for
    `EnvFilter`/`ZANSHIN_LOG`. **No `"*"` wildcard** (`deny.toml [bans] wildcards = "deny"` would hard-fail CI).
15. `crates/zanshin-ffi/Cargo.toml` `[dependencies]` gains:
    ```toml
    tracing = { workspace = true, features = ["release_max_level_info"] }
    tracing-subscriber = { workspace = true }
    tracing-appender = { workspace = true }
    ```
    The `release_max_level_info` feature is enabled at the **consumption site** (this crate needs it now); via Cargo
    feature unification it applies build-wide, which is the intended behaviour (no debug/trace from any crate in release).
16. Latest stable versions confirmed against crates.io at story time: `tracing-subscriber 0.3.23`, `tracing-appender 0.2.5`,
    `tracing 0.1.44` (already resolved transitively via `jj-lib` — declaring `"0.1"` unifies, no new top-level version).
    All are MIT-licensed (permissive — project-context allow-list). `cargo deny check advisories bans` (run by
    `cargo make test`) must stay green; `multiple-versions = "warn"` means any new duplicate (e.g. `regex` pulled by
    `env-filter`'s `matchers`) **warns** but does not block.

### AC-8 — Tests (inline, per project-context testing rule)

17. `tracing_init.rs` has an inline `#[cfg(test)] mod tests`. **Log-content assertions use a local
    `Mutex<Vec<u8>>`-backed `MakeWriter` and a scoped subscriber via `tracing::subscriber::with_default(...)` — NOT
    the global `init_tracing()` and NOT the real file sink** (the file sink is integration-tested separately; the epic's
    `tracing_subscriber::test::TestWriter` reference is **corrected** — that path is wrong and `TestWriter` cannot be
    asserted programmatically anyway; see Dev Notes). Required cases:
    - **Default level is `info`** (AC-3.7): a scoped subscriber built with the default filter records an `info!` line
      and **drops** a `debug!` line.
    - **`ZANSHIN_LOG=debug` enables debug** (AC-3.8): a scoped subscriber built from a `Some("debug")` directive records
      a `debug!` line and **drops** a `trace!` line. Build the filter from an **explicit value** (a pure
      `env_filter_from(Option<String>)` helper), **not** by mutating the process `ZANSHIN_LOG` env (env mutation is
      process-global and races parallel tests — forbidden by project-context § Testing: tests don't depend on/ mutate
      global env and run in parallel).
    - **`ffi_call` span fields are recorded** (AC-6.13): inside `info_span!("ffi_call", fn_name = "demo", command_id = 1)`,
      an `info!` event's captured output contains `ffi_call`, `fn_name`, and `demo`.
18. Pure-helper tests (no globals, no real FS, parallel-safe):
    - `log_dir_from_home(Some("/Users/x".into()))` ends with `Library/Logs/Zanshin`.
    - `log_dir_from_home(None)` falls back under `std::env::temp_dir()` and contains `Zanshin`.
19. **Optional** (not required; include only if leak-clean and parallel-safe): one smoke test that calls the
    directory-injecting installer against a `tempfile::tempdir()` **twice** and asserts no panic + that a
    `zanshin.log.<date>` file is produced after an event. If included, it must be the **only** test that touches the
    global installer (the `Once` is process-wide; multiple global-install tests would race). `tempfile` is already a
    workspace dev-dependency-eligible dep (`[workspace.dependencies] tempfile = "3"`).

### AC-9 — No codegen, no new extern symbol, no registry change (guardrail)

20. `init_tracing()` and all helpers are Rust-internal `fn`/`pub fn`. **No `#[no_mangle] extern "C"` symbol** is added.
    Therefore **`cargo make codegen` is NOT run** and `crates/zanshin-ffi/include/zanshin_ffi.h` +
    `app/lib/src/ffi/bindings.dart` are **unchanged** (zero diff). If a dev runs codegen anyway, the generated files
    must show **no delta** — any delta means something leaked into the FFI surface and is a bug.
21. **No `error.code` is emitted** → `docs/rust-error-codes.md` is **not** modified. Logging-init failure is an
    `eprintln!`, never an envelope/`FfiErrorObj`.

### AC-10 — Quality gate

22. `cargo make test` passes fully green (workspace tests incl. the new inline `tracing_init` tests, `clippy --pedantic
    -D warnings`, `cargo fmt --check`, `flutter test` + `dart analyze`/`dart format` — unchanged, no Dart edits,
    `cargo deny check advisories bans`, cargo hygiene). No `unsafe` is introduced (this module has none — keep it that
    way; `unsafe` is confined to `handle.rs`/`ffi_strings.rs` per project-context). No `#[allow(...)]` without an inline
    `// WHY:`.

### Edge cases (from the epic, reconciled)

- **`~/Library/Logs/Zanshin/` cannot be created** (sandbox/permission): `create_dir_all` errors → one `eprintln!`,
  continue; the `rolling::daily` appender will then fail to write but must **never panic** the process (AC-5.11). In
  debug builds the stderr layer still surfaces logs; in release the events are silently dropped (acceptable WIP
  degradation — documented limitation).
- **`$HOME` unset / unusual** (AC-5.12): fall back to `temp_dir().join("Zanshin")`; never panic.
- **Interaction of `release_max_level_info` + `ZANSHIN_LOG=debug` in a release build:** debug is compiled out, so it
  will not appear regardless of the env var. This is intended (release silence). Document it so it is not mistaken for
  a bug.

---

## Tasks / Subtasks

- [x] **T1 — AC-7: Wire dependencies** (do this first so the module compiles)
  - [x] T1.1 Add `tracing = "0.1"`, `tracing-subscriber = { version = "0.3", features = ["env-filter"] }`,
        `tracing-appender = "0.2"` to root `[workspace.dependencies]` (keep the table alphabetically grouped with the
        existing entries; caret pins; no `"*"`).
  - [x] T1.2 Add the three deps to `crates/zanshin-ffi/Cargo.toml [dependencies]` as `{ workspace = true }`; on the
        `tracing` line add `features = ["release_max_level_info"]`.
- [x] **T2 — AC-1/2/3/4/5/6: Create `crates/zanshin-ffi/src/tracing_init.rs`**
  - [x] T2.1 SPDX first line + module doc (AR-P-5 sink location; `ZANSHIN_LOG` default `info`; debug-only stderr;
        the "no retention/size-cap in 0.1 — old daily files persist until the user prunes" one-liner; the
        `release_max_level_info`×`ZANSHIN_LOG` interaction note).
  - [x] T2.2 `pub fn init_tracing()` → resolves dir, delegates to a dir-injecting installer guarded by `std::sync::Once`;
        `create_dir_all` + one-time `eprintln!` on error; `rolling::daily(dir, "zanshin.log")` blocking appender;
        `.with_ansi(false)` file layer; `Option`-wrapped debug-only stderr layer; `.try_init()`.
  - [x] T2.3 Pure helpers: `env_filter_from(Option<String>) -> EnvFilter` (None/empty/invalid → `info`); `env_filter()`
        = `env_filter_from(std::env::var("ZANSHIN_LOG").ok())`; `log_dir_from_home(Option<PathBuf>) -> PathBuf`;
        `resolve_log_dir()` = `log_dir_from_home(std::env::var_os("HOME").map(...))`.
  - [x] T2.4 Declare `pub mod tracing_init;` in `lib.rs` (the **only** lib.rs change; place it next to the other
        `pub mod` lines — do not touch `zanshin_ffi_version` or any existing item).
- [x] **T3 — AC-8: Inline tests**
  - [x] T3.1 Local `Mutex<Vec<u8>>`-backed `MakeWriter` (the recording writer in Dev Notes).
  - [x] T3.2 `default_level_is_info`, `zanshin_log_debug_enables_debug` (built from an explicit directive value, **no**
        env mutation), `ffi_call_span_fields_are_recorded` — all via `with_default(scoped_subscriber, …)`.
  - [x] T3.3 `log_dir_from_home_uses_library_logs`, `log_dir_from_home_unset_falls_back_to_temp`.
  - [x] T3.4 (optional) skipped — the `Once` is process-wide; T3.2/T3.3 already prove the helpers; no global-install test included.
- [x] **T4 — AC-9/10: Validate, no codegen**
  - [x] T4.1 Confirmed **no** `extern "C"` symbol added; `cargo make codegen` NOT run; `docs/rust-error-codes.md` untouched.
  - [x] T4.2 `cargo make test` fully green (34 zanshin-ffi tests, clippy --pedantic -D warnings, cargo fmt --check, cargo deny check advisories bans — all pass). No new `unsafe`, no `#[allow]` without `// WHY:`.

---

## Dev Notes

### What already exists — do NOT touch

- `crates/zanshin-ffi/src/lib.rs` currently declares `pub mod envelope; pub use envelope::*; pub mod ffi_strings;
  pub mod handle;` plus the `#[allow(warnings)] pub(crate) mod envelope_generated;` and the real
  `zanshin_ffi_version()`. **The only edit is adding `pub mod tracing_init;`.** Leave `zanshin_ffi_version` and its
  inline test exactly as-is (do **not** wire `init_tracing()` into it — see "Wiring" below; calling it there would make
  the version unit test create the real `~/Library/Logs/Zanshin/` dir, an unwanted FS side effect).
- `envelope.rs` (3-1), `ffi_strings.rs` (3-0/3-2), `handle.rs` (3-2), `build.rs` (3-2), `envelope_generated.rs`
  (flatc), the generated `zanshin_ffi.h` / `bindings.dart` (3-2) — **all untouched** by this story.
- `tracing 0.1.44` + `tracing-core 0.1.36` are already in `Cargo.lock` via `jj-lib`. Declaring `tracing = "0.1"`
  unifies to the existing resolution; no version bump churn.

### Wiring: why `init_tracing()` is delivered unwired (reconciliation)

Like 3-2's `handle.rs` ("no FFI consumer yet — that is expected"), 3-3 lands and unit-tests `init_tracing()` in
isolation. The canonical call site is **`zanshin_worker_init` (Story 3-9)** — called once at worker-isolate startup;
the sprint notes already reserve the process-global init/event-sink there. Each 3-4a `catch`-wrapped wrapper will also
call `init_tracing()` defensively (idempotent `Once`, ~one atomic load after first) and open the per-call
`info_span!`. Do **not** add `#[ctor]` (new proc-macro dep; dlopen-time ctor in a cdylib is a portability footgun) and
do **not** wire init into `zanshin_ffi_version` (FS side effect in its test; it is an infallible hot-path fn that
should stay trivial). Net: in 3-3 nothing logs yet (there are no `tracing::*` call sites in the crate), which is fine —
the infrastructure is proven by the scoped-subscriber tests.

### `tracing_init.rs` — recommended shape

```rust
// SPDX-License-Identifier: Apache-2.0
//! Process-wide `tracing` initialization for the `zanshin-ffi` cdylib (AR-P-5).
//!
//! [`init_tracing`] installs a global subscriber: a daily-rotating file sink at
//! `~/Library/Logs/Zanshin/zanshin.log.YYYY-MM-DD`, level from `ZANSHIN_LOG` (RUST_LOG
//! syntax, default `info`), plus a stderr layer **only** in debug builds. Release builds
//! emit nothing to stdout/stderr, and `debug`/`trace` are compiled out via the crate's
//! `release_max_level_info` feature on `tracing`.
//!
//! No log retention/size-cap in 0.1: old daily files persist until the user prunes them.
//! Size/age-cap rotation returns in the release-phase supportability hardening.

use std::path::{Path, PathBuf};
use std::sync::Once;

use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::EnvFilter;

const LOG_ENV: &str = "ZANSHIN_LOG";
const DEFAULT_LEVEL: &str = "info";
const LOG_SUBDIR: &str = "Library/Logs/Zanshin"; // joined onto $HOME
const LOG_PREFIX: &str = "zanshin.log"; // → files named `zanshin.log.YYYY-MM-DD`

static INIT: Once = Once::new();

/// Install process-wide tracing (AR-P-5). Idempotent — later calls are no-ops; never panics.
pub fn init_tracing() {
    init_with_dir(&resolve_log_dir());
}

fn init_with_dir(dir: &Path) {
    INIT.call_once(|| {
        if let Err(e) = std::fs::create_dir_all(dir) {
            // Acceptable at init time only: one stderr line, never a panic. Later FFI
            // calls produce no stderr (the file sink takes over).
            eprintln!("zanshin: could not create log dir {}: {e}", dir.display());
        }

        let file_layer = tracing_subscriber::fmt::layer()
            .with_ansi(false)
            .with_writer(tracing_appender::rolling::daily(dir, LOG_PREFIX));

        // Debug builds also log to stderr; release builds get `None` (a no-op Layer).
        let stderr_layer = cfg!(debug_assertions)
            .then(|| tracing_subscriber::fmt::layer().with_writer(std::io::stderr));

        // try_init (not init): idempotent + never panics if a global is already set.
        let _ = tracing_subscriber::registry()
            .with(env_filter())
            .with(file_layer)
            .with(stderr_layer)
            .try_init();
    });
}

fn env_filter() -> EnvFilter {
    env_filter_from(std::env::var(LOG_ENV).ok())
}

/// Pure: build the level filter from an explicit value (testable without env mutation).
fn env_filter_from(raw: Option<String>) -> EnvFilter {
    match raw {
        Some(v) if !v.trim().is_empty() => {
            EnvFilter::try_new(&v).unwrap_or_else(|_| EnvFilter::new(DEFAULT_LEVEL))
        }
        _ => EnvFilter::new(DEFAULT_LEVEL),
    }
}

fn resolve_log_dir() -> PathBuf {
    log_dir_from_home(std::env::var_os("HOME").map(PathBuf::from))
}

/// Pure: `$HOME/Library/Logs/Zanshin`, or a temp fallback when `$HOME` is unavailable.
fn log_dir_from_home(home: Option<PathBuf>) -> PathBuf {
    match home {
        Some(h) => h.join(LOG_SUBDIR),
        None => std::env::temp_dir().join("Zanshin"),
    }
}
```

**Why blocking over `non_blocking` (AC-2.6):** `tracing_appender::non_blocking(appender)` returns
`(NonBlocking, WorkerGuard)`. The `WorkerGuard` MUST be kept alive for the whole process or buffered logs are dropped,
and dropping it is the only thing that flushes the background writer thread. A cdylib has no guaranteed teardown hook
to drop a stashed guard, so on process exit the tail of the log can be lost. The blocking `RollingFileAppender` writes
(and the OS flushes) each event synchronously, so a crash loses at most the in-flight line and never the earlier ones —
exactly the epic's durability requirement, with no guard to leak. Volume is tiny (FFI-call-level `info`), so blocking
I/O cost is negligible in WIP.

**Type note (AC-4.9):** the two `fmt` layers have different writer types (`RollingFileAppender` vs `Stderr`), so
`stderr_layer` is its own `Option<Fmt<…, Stderr>>`. `Option<L: Layer>` implements `Layer` (a `None` is a no-op), which
is what lets the same `.with(stderr_layer)` line compile in both release (`None`) and debug (`Some`) without `#[cfg]`
on the builder chain.

### Tests — recording writer (corrects the epic's `TestWriter`)

The epic says `tracing_subscriber::test::TestWriter`; that path is wrong (it's `fmt::TestWriter`) **and** `TestWriter`
only forwards to libtest's captured stdout — you cannot assert its contents programmatically. For content assertions use
a `Mutex<Vec<u8>>`-backed `MakeWriter` and a **scoped** subscriber (never the global `init_tracing()` / real file):

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::io;
    use std::sync::{Arc, Mutex};
    use tracing_subscriber::fmt::MakeWriter;

    #[derive(Clone, Default)]
    struct Recorder(Arc<Mutex<Vec<u8>>>);
    impl Recorder {
        fn contents(&self) -> String {
            String::from_utf8(self.0.lock().unwrap().clone()).unwrap()
        }
    }
    impl io::Write for Recorder {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> io::Result<()> { Ok(()) }
    }
    impl<'a> MakeWriter<'a> for Recorder {
        type Writer = Recorder;
        fn make_writer(&'a self) -> Self::Writer { self.clone() }
    }

    fn run_scoped(filter: EnvFilter, body: impl FnOnce()) -> String {
        let rec = Recorder::default();
        let subscriber = tracing_subscriber::registry()
            .with(filter)
            .with(tracing_subscriber::fmt::layer().with_ansi(false).with_writer(rec.clone()));
        tracing::subscriber::with_default(subscriber, body);
        rec.contents()
    }

    #[test]
    fn default_level_is_info() {
        let out = run_scoped(env_filter_from(None), || {
            tracing::info!("info-line");
            tracing::debug!("debug-line");
        });
        assert!(out.contains("info-line"));
        assert!(!out.contains("debug-line"));
    }

    #[test]
    fn zanshin_log_debug_enables_debug() {
        let out = run_scoped(env_filter_from(Some("debug".to_owned())), || {
            tracing::debug!("debug-line");
            tracing::trace!("trace-line");
        });
        assert!(out.contains("debug-line"));
        assert!(!out.contains("trace-line"));
    }

    #[test]
    fn ffi_call_span_fields_are_recorded() {
        let out = run_scoped(env_filter_from(None), || {
            let span = tracing::info_span!("ffi_call", fn_name = "demo", command_id = 1);
            let _e = span.enter();
            tracing::info!("inside");
        });
        assert!(out.contains("ffi_call"));
        assert!(out.contains("fn_name"));
        assert!(out.contains("demo"));
    }

    #[test]
    fn log_dir_from_home_uses_library_logs() {
        let dir = log_dir_from_home(Some(PathBuf::from("/Users/x")));
        assert!(dir.ends_with("Library/Logs/Zanshin"));
    }

    #[test]
    fn log_dir_from_home_unset_falls_back_to_temp() {
        let dir = log_dir_from_home(None);
        assert!(dir.starts_with(std::env::temp_dir()));
        assert!(dir.to_string_lossy().contains("Zanshin"));
    }
}
```

> **Caution on `release_max_level_info` in tests:** test builds are **debug** (`debug_assertions` on,
> `release_max_level_*` inactive), so `debug!`/`trace!` are present and the level tests behave as written. Don't be
> surprised that the same `debug!` would be compiled out under `cargo build --release`.

### Clippy / fmt carry-overs (bit 3-0/3-1/3-2; will bite again)

- `clippy::doc_markdown` flags bare `ZanshinBuf`, `WorkerGuard`, `RollingFileAppender`, `EnvFilter`, `MakeWriter`,
  `RUST_LOG` in doc comments → backtick them.
- `clippy::pedantic` is crate-wide. Likely nits: prefer `std::env::var_os` over `var` where you only need presence;
  `#[must_use]` is not needed on `init_tracing` (returns `()`); avoid needless `.clone()` in the writer impl beyond
  what the `MakeWriter` contract requires.
- Repo `rustfmt.toml` governs width (the crate's effective `max_width` is **120** — a known divergence from
  project-context's 100; format with the repo config, do not hand-wrap).
- The new module is `#[cfg(test)]`-tested inline at the bottom (project-context § Testing: inline `#[cfg(test)] mod
  tests`, **not** a `tests/` integration file).

### Hard guardrails (reject-at-review for this story)

- **No `extern "C"` symbol, no codegen, no generated-file diff** (AC-9). `init_tracing` is Rust-internal. Do **not**
  run `cargo make codegen`; if run, `zanshin_ffi.h` / `bindings.dart` must show zero delta.
- **No `error.code`, no `docs/rust-error-codes.md` change** (AC-9.21). Init failure is `eprintln!`, never an envelope.
- **No `unsafe`** in this module (project-context: `unsafe` only in `handle.rs`/`ffi_strings.rs`). None is needed here.
- **No new dep beyond the tracing stack.** No `dirs`, no `ctor`, no `once_cell` (use `std::sync::Once`). `tempfile`
  (already a workspace dep) only if the optional smoke test is included.
- **Caret pins, never `"*"`** (`deny.toml [bans] wildcards = "deny"`). `env-filter` feature is mandatory for `EnvFilter`.
- **Never panic from init** (AC-5). `create_dir_all` error → `eprintln!` + continue; `.try_init()` not `.init()`.
- **Do not mutate `ZANSHIN_LOG`/`HOME` in tests** (process-global, races parallel tests). Use the pure
  `env_filter_from` / `log_dir_from_home` helpers with explicit inputs.
- **Do not wire `init_tracing()` into `zanshin_ffi_version`** or add a per-call `info_span!` (no fallible FFI fn yet;
  that lands in 3-4a / 3-9). The `lib.rs` change is exactly one line: `pub mod tracing_init;`.

### Project Structure Notes

- `tracing_init.rs` lands at `crates/zanshin-ffi/src/tracing_init.rs` — noun/feature-per-file, no `mod.rs`
  (project-context § module organization; AR-P-3). `lib.rs` stays re-exports + `zanshin_ffi_version` only.
- No Dart-side work: no `extern "C"` change ⇒ `bindings.dart` is not regenerated; `app/` is untouched. The Dart/flutter
  CI gates still run but assert no change.
- `~/Library/Logs/Zanshin/` is the macOS-standard per-user Logs location (project-context § Logging discipline,
  "Crash logs are LOCAL: `~/Library/Logs/Zanshin/`"). macOS-only target (Windows/Linux are explicit non-goals), so
  `$HOME` + this fixed subpath is correct; no cross-platform dir crate needed.

## References

- `_bmad-output/planning-artifacts/epics.md` § Story 3.3 (`:1794`–`:1865`) — the GWT this story reconciles; WIP-shrink
  note at `:1796` (rotation tests / log-cap / schema-validation **dropped**).
- `_bmad-output/planning-artifacts/epics.md` AR-P-5 (`:196`) + AR-P-5-MCP (`:197`) — tracing/logging requirement
  (rotating file sink, `ZANSHIN_LOG`, no console in release; the MCP all-modes-file-only variant is Story 7.2, not this one).
- `_bmad-output/project-context.md` § Logging discipline (`tracing` + `tracing-appender`; sink path; levels; "NO console
  output in release"; PII debug-only/compiled-out; `ZANSHIN_LOG`=`RUST_LOG` syntax) and § Version pinning rules
  (stable crates → caret) and § Testing Rules (inline `#[cfg(test)]`; no global-env dependence; parallel-safe).
- `_bmad-output/implementation-artifacts/3-2-handle-module-ffi-strings-zanshin-ffi-version.md` — the precedent for
  "land + unit-test infrastructure with no FFI consumer yet"; the clippy/fmt carry-overs; the codegen discipline (3-3
  is the inverse: **no** codegen).
- `crates/zanshin-ffi/src/lib.rs` — the one-line `pub mod tracing_init;` addition; `zanshin_ffi_version` to leave alone.
- `crates/zanshin-ffi/Cargo.toml` + root `Cargo.toml` `[workspace.dependencies]` — the dep wiring (AC-7).
- `deny.toml` — `[bans] wildcards = "deny"` (no `"*"`), `multiple-versions = "warn"` (new transitive duplicates warn,
  don't block); `[advisories]` form is `cargo deny check advisories bans` (wired into `cargo make test`).
- crates.io (verified at story time): `tracing-subscriber 0.3.23`, `tracing-appender 0.2.5`, `tracing 0.1.44`.
- `tracing-appender` docs — `rolling::daily(dir, prefix)` ⇒ blocking `RollingFileAppender`, files `prefix.YYYY-MM-DD`;
  `non_blocking` ⇒ `WorkerGuard` (deliberately avoided, AC-2.6).

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

- Clippy `doc_markdown`: backtick `RUST_LOG` in module-level doc comment (line 5).
- `rustfmt`: three formatting adjustments — `stderr_layer` assignment, `env_filter_from` match arm, `run_scoped` subscriber builder chain — to comply with repo `rustfmt.toml` (max_width 120).

### Completion Notes List

- Created `crates/zanshin-ffi/src/tracing_init.rs` with `pub fn init_tracing()` guarded by `std::sync::Once`, daily-rotating blocking `RollingFileAppender` (no `WorkerGuard` footgun), `Option`-wrapped debug-only stderr layer, `EnvFilter` from `ZANSHIN_LOG` defaulting to `info`, `create_dir_all` + `eprintln!` on error (never panics).
- Added `tracing`, `tracing-appender`, `tracing-subscriber` (with `env-filter` feature) to root `[workspace.dependencies]` with caret pins; added the three as `{ workspace = true }` to `crates/zanshin-ffi/Cargo.toml` with `release_max_level_info` on the `tracing` line.
- Added `pub mod tracing_init;` to `lib.rs` — the only change to that file.
- 5 inline tests all pass (2 level-filter tests, 1 span-field test, 2 pure helper tests). No env mutation in tests; no global `init_tracing()` called from tests.
- `cargo make test` fully green: 34 zanshin-ffi unit tests, clippy `--pedantic -D warnings`, `cargo fmt --check`, `cargo deny check advisories bans`.
- No `extern "C"` symbol added; no codegen run; `zanshin_ffi.h` and `bindings.dart` unchanged; `docs/rust-error-codes.md` unchanged. No `unsafe` introduced.

### File List

- `Cargo.toml` — added `tracing`, `tracing-appender`, `tracing-subscriber` to `[workspace.dependencies]`
- `crates/zanshin-ffi/Cargo.toml` — added the three tracing deps to `[dependencies]`
- `crates/zanshin-ffi/src/tracing_init.rs` — new file (tracing init + helpers + inline tests)
- `crates/zanshin-ffi/src/lib.rs` — added `pub mod tracing_init;`

## Change Log

- 2026-06-15: Story 3-3 implemented — `tracing_init.rs` created with `init_tracing()`, daily-rotating file sink, `ZANSHIN_LOG` level filter, debug-only stderr layer; tracing deps wired in workspace and crate `Cargo.toml`; 5 inline tests green; `cargo make test` fully green.

## Review Findings

> Code review 2026-06-15 (3 adversarial layers: Blind Hunter, Edge Case Hunter, Acceptance Auditor).
> The Acceptance Auditor found the code matches the spec's "recommended shape" verbatim — but the
> Edge Case Hunter (verified against the actual crate sources) found two binding-behaviour violations
> that exist **in the spec's own recommended code block**: `rolling::daily()` panics, and `EnvFilter`
> construction writes to stderr. Behavioural ACs ("never panic", "no stderr in release") outrank the
> recommended shape.

### Decision-needed (resolved 2026-06-15)

- [x] [Review][Decision] Release stderr leak when `ZANSHIN_LOG` > `info` — **RESOLVED → Patch (option a: clamp in release).** `EnvFilter::try_new` → `from_directives` does an ungated `eprintln!` of a 4–5 line warning whenever a directive exceeds `STATIC_MAX_LEVEL` (`tracing-subscriber-0.3.23/src/filter/env/builder.rs:234-258`). With `release_max_level_info` the cap is `INFO`, so `ZANSHIN_LOG=debug` in a **release** build prints to stderr, violating AR-P-5 "NO console output in release builds." Ralph chose: clamp the runtime filter to ≤ `STATIC_MAX_LEVEL` in release so the warning never fires. See Patch P-D1.

### Patches

- [x] [Review][Patch] (P-D1) Clamp the `EnvFilter` to `≤ STATIC_MAX_LEVEL` in release builds so `EnvFilter` construction never `eprintln!`s a warning to stderr when `ZANSHIN_LOG` exceeds the compile-time cap (AR-P-5 "no console output in release"). When `tracing::level_filters::STATIC_MAX_LEVEL` is below the requested level, build the filter capped at the static max (the exceeding levels are compiled out anyway), avoiding the `from_directives` warning path. Add a debug-build-skipping note; keep debug builds honoring `ZANSHIN_LOG` verbatim. [tracing_init.rs:60-70]
- [x] [Review][Patch] `init_tracing()` panics on an unwritable log dir and poisons the `Once` — `tracing_appender::rolling::daily()` calls `RollingFileAppender::new()` → `.build(dir).expect("initializing rolling file appender failed")` (`tracing-appender-0.2.5/src/rolling.rs:155-156`); on an unwritable / non-creatable dir (failed `create_dir_all`, `$HOME` → non-dir, sandbox) it panics, and the panic inside `INIT.call_once` poisons the `Once` so every later call panics too. Violates AC-5.11 + the module's "never panics" doc. Fix: build via `RollingFileAppender::builder().rotation(Rotation::DAILY).filename_prefix(LOG_PREFIX).build(dir)` (returns `Result`), `Option`-wrap the file layer, skip it + `eprintln!`-once on `Err`; add a regression test (`init_with_dir` against an unwritable dir asserts no panic). [tracing_init.rs:45]
- [x] [Review][Patch] `$HOME=""` yields a relative log path under the process CWD — `var_os("HOME")` returns `Some("")` for an empty-but-set `HOME`, so `log_dir_from_home` takes the `Some` arm → `PathBuf::from("").join("Library/Logs/Zanshin")` = a **relative** path created under the host CWD (sandbox/launchd/`env -i` edge), not the temp fallback. Fix: treat empty `HOME` as `None` (`.filter(|s| !s.is_empty())`); add a `Some("")` helper test. [tracing_init.rs:73,77-82]
- [x] [Review][Patch] Module doc overstates release silence — header says "Release builds emit nothing to stdout/stderr", but the spec-sanctioned init `eprintln!` (create_dir_all failure, AC-5.11) and the `EnvFilter` warning (decision item) can both write to stderr in release. Correct the doc to state the init-time exception. [tracing_init.rs:6-7]

### Deferred

- [x] [Review][Defer] One invalid directive discards the whole `ZANSHIN_LOG` → silent downgrade to `info` — `EnvFilter::try_new` is all-or-nothing; `info,foo=bogus` silently falls back to bare `info`. AC-3.7 covers fully-unparseable values; partial directives are unspecified. `parse_lossy` would preserve valid directives but adds per-directive stderr (worsens the decision item). [tracing_init.rs:67] — deferred, hardening beyond AC-3.7
- [x] [Review][Defer] `try_init()` `Err` (a foreign global subscriber already installed) is silently swallowed — `let _ =` is the mandated idempotency pattern (AC-1.3) for the self-double-call case, but if another component installs a global subscriber first, Zanshin's file sink is never installed and there is no signal. Hardening: `eprintln!`-once on `Err` in debug. [tracing_init.rs:52-56] — deferred, low / unlikely in the single-cdylib worker isolate
- [x] [Review][Defer] Post-init runtime durability — UTC midnight rollover into a deleted dir / disk-full silently drop subsequent log lines, and `tracing-appender` `eprintln!`s on rollover failure (another release-stderr path). No `tracing::*` call sites exist yet (infra-only); ties to the deferred size/age-cap supportability hardening. [tracing_init.rs:45] — deferred, WIP runtime-durability, no live call sites
- [x] [Review][Defer] Global-init path untested by design — tests use scoped subscribers only (AC-8.17) and skip the optional global smoke (T3.4), which is exactly why the two HIGH findings weren't caught at test time. The Patch-1 regression test partially closes this; a fuller global/FS integration test stays deferred. [tracing_init.rs:84-172] — deferred, spec-sanctioned test scope (AC-8.17/T3.4)

_Dismissed as noise (7): blocking-appender "no WorkerGuard" (AC-2.6 mandates blocking — finding recommended the opposite); `Once`-keyed-on-first-call (intended idempotency); span-field substring test (validates required AC-6.13, format stable); UTC filename date (AC-2.4 documents UTC explicitly); `cfg!` vs `#[cfg]` for stderr layer (AC-4.9 mandates the `Option`-layer pattern; `None` never writes); test-only `unwrap`s; concurrent-first-call race (`Once` blocks — confirmed safe)._
