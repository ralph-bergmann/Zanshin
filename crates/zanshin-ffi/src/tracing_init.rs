// SPDX-License-Identifier: Apache-2.0
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

use std::path::{Path, PathBuf};
use std::sync::Once;

use tracing::level_filters::{LevelFilter, STATIC_MAX_LEVEL};
use tracing_appender::rolling::{RollingFileAppender, Rotation};
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{EnvFilter, Layer};

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
                .with_filter(env_filter())
        });

        // Console sink: ALWAYS on, everything down to `trace`. See the module docs — the
        // release-profile cdylib makes a `cfg!(debug_assertions)` gate compile this out, and
        // `flutter run` forwards native stderr, so this unconditional layer is the live dev
        // view. WIP deviation from AR-P-5 ("no console in release"); re-gate before ship.
        let console_layer = tracing_subscriber::fmt::layer()
            .with_writer(std::io::stderr)
            .with_filter(LevelFilter::TRACE);

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

fn env_filter() -> EnvFilter {
    env_filter_from(std::env::var(LOG_ENV).ok())
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
    log_dir_from_home(std::env::var_os("HOME").map(PathBuf::from))
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
    fn build_file_appender_on_unwritable_dir_returns_none_without_panic() {
        // `/dev/null` is a character device, so any path *under* it can never be a directory:
        // the appender build fails (ENOTDIR) and returns `None` instead of panicking — the
        // regression guard for AC-5.11 ("never panic", no `Once` poisoning). macOS-only
        // target, so `/dev/null` always exists. Pure: no global `Once`, no real log dir.
        assert!(build_file_appender(Path::new("/dev/null/zanshin-cannot-exist")).is_none());
    }
}
