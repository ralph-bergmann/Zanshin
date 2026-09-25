// SPDX-License-Identifier: MIT
//! Process-wide `tracing` initialization for the `zanshin-ffi` cdylib (AR-P-5).
//!
//! [`init_tracing`] installs a global subscriber with two layers:
//! - a daily-rotating **file** sink at `~/Library/Logs/Zanshin/zanshin.log.YYYY-MM-DD`,
//!   filtered by `ZANSHIN_LOG` (`RUST_LOG` syntax, default `info`); and
//! - an always-on **console** sink (native stderr) at `trace`. The cdylib is built in the
//!   `release` profile even for `flutter run` debug runs, so a `cfg!(debug_assertions)`
//!   gate would compile it out; `flutter run` forwards the app's native stderr, so an
//!   unconditional layer is the live dev view. Dart-origin logs forwarded via
//!   [`crate::logging::zanshin_log`] appear here too.
//!
//! **Path / overrides:** Zanshin ships **unsandboxed** (App Sandbox disabled in both
//! `DebugProfile.entitlements` and `Release.entitlements`, decided 2026-06-21 — a jj/git GUI
//! needs arbitrary-repo filesystem access and `zanshin-mcp` rules out the App Store; see
//! `deferred-work.md`). So `$HOME` is the real home and the file lands at the literal
//! `~/Library/Logs/Zanshin/`. The `ZANSHIN_LOG_DIR` env var overrides the directory outright —
//! the test suites set it to a throwaway dir (so tests never pollute the real log dir) and
//! operators can relocate logs without touching `$HOME`. (Were the sandbox ever re-enabled,
//! `$HOME` would be redirected to `~/Library/Containers/<bundle-id>/Data/…` automatically.)
//!
//! The sole init-time `eprintln!` is a single line if the log directory cannot be created
//! (AC-5.11) — never a panic.
//!
//! **WIP deviation (tracked in `deferred-work.md`, logging sink, 2026-06-18):** AR-P-5
//! mandates "no console output in release builds". The always-on console layer breaks that
//! for the shipped app and is deliberate only for the dev loop; re-gate it (env var) and
//! restore the `info` default before ship. `release_max_level_info` was removed from the
//! `tracing` dep so `debug`/`trace` compile in for the console.
//!
//! No log retention/size-cap in 0.1: old daily files persist until the user prunes them.
//! Size/age-cap rotation returns in the release-phase supportability hardening.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::Once;

use tracing::level_filters::{LevelFilter, STATIC_MAX_LEVEL};
use tracing::Subscriber;
use tracing_appender::rolling::{RollingFileAppender, Rotation};
use tracing_subscriber::filter::{FilterExt as _, Targets};
use tracing_subscriber::layer::{Filter, SubscriberExt};
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{EnvFilter, Layer};

const LOG_ENV: &str = "ZANSHIN_LOG";
/// The target jj-lib logs every `git` spawn under — see [`git_subprocess_cap`].
const GIT_SUBPROCESS_TARGET: &str = "jj_lib::git_subprocess";
const LOG_DIR_ENV: &str = "ZANSHIN_LOG_DIR"; // explicit log-dir override (tests + ops); wins over $HOME
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
            // Acceptable at init time only: one stderr line, never a panic.
            eprintln!("zanshin: could not create log dir {}: {e}", dir.display());
        }

        // File sink: `ZANSHIN_LOG` / default `info` (AR-P-5 disciplined default).
        // `Option`-wrapped: `None` (a no-op `Layer`) when the log file cannot be opened, so a
        // broken/unwritable dir degrades to "no file sink" instead of panicking (see
        // `build_file_appender`). The per-layer filter keeps the file at `info` while the
        // console below stays at `trace`.
        let file_layer = build_file_appender(dir).map(|appender| {
            tracing_subscriber::fmt::layer()
                .with_ansi(false)
                .with_writer(appender)
                .with_filter(file_filter(std::env::var(LOG_ENV).ok()))
        });

        // Console sink: ALWAYS on, everything down to `trace` but the capped git-spawn target.
        // See the module docs — the release-profile cdylib makes a `cfg!(debug_assertions)`
        // gate compile this out, and `flutter run` forwards native stderr, so this
        // unconditional layer is the live dev view. WIP deviation from AR-P-5 ("no console in
        // release"); re-gate before ship.
        let console_layer = tracing_subscriber::fmt::layer()
            .with_writer(std::io::stderr)
            .with_filter(git_subprocess_cap());

        // try_init (not init): idempotent + never panics if a global is already set.
        let _ = tracing_subscriber::registry()
            .with(file_layer)
            .with(console_layer)
            .try_init();
    });
}

/// Build the daily file appender, returning `None` instead of panicking when the log file
/// cannot be opened (unwritable/invalid dir). `tracing_appender::rolling::daily` `.expect()`s
/// on this path and would panic inside `Once::call_once`, poisoning it for every later call —
/// so we use the fallible builder and degrade to "no file sink" (AC-5.11: never panic).
fn build_file_appender(dir: &Path) -> Option<RollingFileAppender> {
    RollingFileAppender::builder()
        .rotation(Rotation::DAILY)
        .filename_prefix(LOG_PREFIX)
        .build(dir)
        .ok()
}

/// The file sink's filter: `ZANSHIN_LOG` (see [`env_filter_from`]), capped by
/// [`git_subprocess_cap`].
fn file_filter<S: Subscriber + for<'a> LookupSpan<'a>>(raw: Option<String>) -> impl Filter<S> {
    env_filter_from(raw).and(git_subprocess_cap())
}

/// Everything down to `trace`, except [`GIT_SUBPROCESS_TARGET`] at `info` — applied to BOTH sinks.
// WHY: jj-lib logs every git spawn as `debug!(cmd = ?git_cmd, …)` (`git_subprocess.rs:147` @
// 0.44.0), and `Command`'s `Debug` prints every variable set via `.envs` as `KEY="value"`. Since
// Story 9.36 that is the whole adopted login-shell environment — API tokens an rc file exports
// included — so without this cap every fetch/clone would write them to the always-on console
// sink and, under `ZANSHIN_LOG=debug`, to the log file.
fn git_subprocess_cap() -> Targets {
    Targets::new()
        .with_default(LevelFilter::TRACE)
        .with_target(GIT_SUBPROCESS_TARGET, LevelFilter::INFO)
}

/// Pure: build the level filter from an explicit value (testable without env mutation).
///
/// A bare level (`info`, `debug`, …) is clamped to `STATIC_MAX_LEVEL` before the filter is
/// built, so the filter can never request a level above what is compiled in (which would make
/// `tracing-subscriber` `eprintln!` a multi-line warning to stderr). With
/// `release_max_level_info` removed, `STATIC_MAX_LEVEL` is `trace` in every profile, so the
/// clamp is currently a harmless no-op and full `RUST_LOG` directive syntax is honored
/// verbatim. Complex directive sets fall through to `try_new`.
fn env_filter_from(raw: Option<String>) -> EnvFilter {
    match raw {
        Some(v) if !v.trim().is_empty() => {
            // A bare level: clamp it so a release build never warns to stderr about a level
            // that is compiled out. Complex directive sets fall through to `try_new`.
            if let Ok(level) = v.trim().parse::<LevelFilter>() {
                return EnvFilter::new(level.min(STATIC_MAX_LEVEL).to_string());
            }
            EnvFilter::try_new(&v).unwrap_or_else(|_| EnvFilter::new(DEFAULT_LEVEL))
        }
        _ => EnvFilter::new(DEFAULT_LEVEL),
    }
}

fn resolve_log_dir() -> PathBuf {
    log_dir_from_env(
        std::env::var_os(LOG_DIR_ENV),
        std::env::var_os("HOME").map(PathBuf::from),
    )
}

/// Returns the absolute directory where the tracing file sink writes its logs.
///
/// This is the single source of truth for `diagnostics.rs` — it reports exactly
/// the same directory the sink resolved (whether that came from `ZANSHIN_LOG_DIR`,
/// `$HOME/Library/Logs/Zanshin`, or the temp fallback).
#[must_use]
pub fn log_dir() -> PathBuf {
    resolve_log_dir()
}

/// Pure: an explicit `ZANSHIN_LOG_DIR` override wins; otherwise fall back to
/// `$HOME/Library/Logs/Zanshin` (or the temp dir). The override lets the test suites redirect
/// the file sink to a throwaway dir so `cargo make test` / `flutter test` never write into the
/// developer's real `~/Library/Logs/Zanshin`, and lets operators relocate logs without touching
/// `$HOME`. An empty value is ignored (treated as unset), mirroring the empty-`$HOME` handling.
fn log_dir_from_env(override_dir: Option<OsString>, home: Option<PathBuf>) -> PathBuf {
    match override_dir {
        Some(d) if !d.is_empty() => PathBuf::from(d),
        _ => log_dir_from_home(home),
    }
}

/// Pure: `$HOME/Library/Logs/Zanshin`, or a temp fallback when `$HOME` is unavailable.
///
/// An empty `$HOME` (set but blank — a sandbox/launchd/`env -i` edge) is treated as
/// unavailable: joining onto an empty `PathBuf` would yield a *relative* path created under
/// the process CWD, so it falls back to the temp dir too.
fn log_dir_from_home(home: Option<PathBuf>) -> PathBuf {
    match home {
        Some(h) if !h.as_os_str().is_empty() => h.join(LOG_SUBDIR),
        _ => std::env::temp_dir().join("Zanshin"),
    }
}

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
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl<'a> MakeWriter<'a> for Recorder {
        type Writer = Recorder;
        fn make_writer(&'a self) -> Self::Writer {
            self.clone()
        }
    }

    fn run_scoped(filter: EnvFilter, body: impl FnOnce()) -> String {
        let rec = Recorder::default();
        let subscriber = tracing_subscriber::registry().with(filter).with(
            tracing_subscriber::fmt::layer()
                .with_ansi(false)
                .with_writer(rec.clone()),
        );
        tracing::subscriber::with_default(subscriber, body);
        rec.contents()
    }

    /// Like [`run_scoped`], but with `filter` as a PER-LAYER filter — how both sinks apply theirs.
    fn run_filtered(
        filter: impl Filter<tracing_subscriber::Registry> + Send + Sync + 'static,
        body: impl FnOnce(),
    ) -> String {
        let rec = Recorder::default();
        let subscriber = tracing_subscriber::registry().with(
            tracing_subscriber::fmt::layer()
                .with_ansi(false)
                .with_writer(rec.clone())
                .with_filter(filter),
        );
        tracing::subscriber::with_default(subscriber, body);
        rec.contents()
    }

    /// Story 9.36: jj-lib's git-spawn DEBUG line carries the adopted environment, so neither sink
    /// records it — the file even under `ZANSHIN_LOG=debug` — while its INFO lines and every other
    /// target's DEBUG lines still get through.
    #[test]
    fn git_spawn_debug_lines_reach_neither_sink() {
        let emit = || {
            tracing::debug!(target: "jj_lib::git_subprocess", "spawn-debug-line");
            tracing::info!(target: "jj_lib::git_subprocess", "spawn-info-line");
            tracing::debug!("other-debug-line");
        };
        let file = run_filtered(file_filter(Some("debug".to_owned())), emit);
        let console = run_filtered(git_subprocess_cap(), emit);
        for out in [file, console] {
            assert!(!out.contains("spawn-debug-line"), "{out}");
            assert!(out.contains("spawn-info-line"), "{out}");
            assert!(
                out.contains("other-debug-line"),
                "only the git-spawn target is capped: {out}"
            );
        }
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

    #[test]
    fn log_dir_from_home_empty_falls_back_to_temp() {
        // An empty-but-set `$HOME` must not produce a relative path under CWD.
        let dir = log_dir_from_home(Some(PathBuf::from("")));
        assert!(dir.starts_with(std::env::temp_dir()));
        assert!(dir.to_string_lossy().contains("Zanshin"));
    }

    #[test]
    fn log_dir_from_env_override_wins_over_home() {
        // ZANSHIN_LOG_DIR redirects the sink wholesale — used by tests + ops.
        let dir = log_dir_from_env(Some("/tmp/zanshin-logs".into()), Some(PathBuf::from("/Users/x")));
        assert_eq!(dir, PathBuf::from("/tmp/zanshin-logs"));
    }

    #[test]
    fn log_dir_from_env_empty_override_falls_back_to_home() {
        // An empty override is treated as unset, so $HOME wins.
        let dir = log_dir_from_env(Some(OsString::new()), Some(PathBuf::from("/Users/x")));
        assert!(dir.ends_with("Library/Logs/Zanshin"));
    }

    #[test]
    fn build_file_appender_on_unwritable_dir_returns_none_without_panic() {
        // `/dev/null` is a character device, so any path *under* it can never be a directory:
        // the appender build fails (ENOTDIR) and returns `None` instead of panicking — the
        // regression guard for AC-5.11 ("never panic", no `Once` poisoning). macOS-only
        // target, so `/dev/null` always exists. Pure: no global `Once`, no real log dir.
        assert!(build_file_appender(Path::new("/dev/null/zanshin-cannot-exist")).is_none());
    }

    #[test]
    fn log_dir_accessor_returns_non_empty_absolute_path() {
        let dir = log_dir();
        assert!(dir.is_absolute(), "log_dir() must return an absolute path");
        assert!(!dir.as_os_str().is_empty(), "log_dir() must return a non-empty path");
    }
}
