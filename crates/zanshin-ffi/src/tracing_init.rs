// SPDX-License-Identifier: Apache-2.0
//! Process-wide `tracing` initialization for the `zanshin-ffi` cdylib (AR-P-5).
//!
//! [`init_tracing`] installs a global subscriber: a daily-rotating file sink at
//! `~/Library/Logs/Zanshin/zanshin.log.YYYY-MM-DD`, level from `ZANSHIN_LOG` (`RUST_LOG`
//! syntax, default `info`), plus a stderr layer **only** in debug builds. During normal
//! operation release builds emit nothing to stdout/stderr; the sole exception is a single
//! init-time `eprintln!` if the log directory cannot be created (AC-5.11). `debug`/`trace`
//! are compiled out via the crate's `release_max_level_info` feature on `tracing`.
//!
//! No log retention/size-cap in 0.1: old daily files persist until the user prunes them.
//! Size/age-cap rotation returns in the release-phase supportability hardening.
//!
//! Note: In a release build with `release_max_level_info` active, `ZANSHIN_LOG=debug` is
//! clamped to `info` — `debug`/`trace` call sites are compiled out entirely, and the level
//! filter is capped at the static max so `tracing-subscriber` emits no stderr warning about
//! the statically-disabled levels.

use std::path::{Path, PathBuf};
use std::sync::Once;

use tracing::level_filters::{LevelFilter, STATIC_MAX_LEVEL};
use tracing_appender::rolling::{RollingFileAppender, Rotation};
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

        // `Option`-wrapped: `None` (a no-op `Layer`) when the log file cannot be opened, so a
        // broken/unwritable dir degrades to "no file sink" instead of panicking (see
        // `build_file_appender`).
        let file_layer = build_file_appender(dir)
            .map(|appender| tracing_subscriber::fmt::layer().with_ansi(false).with_writer(appender));

        // Debug builds also log to stderr; release builds get `None` (a no-op `Layer`).
        let stderr_layer =
            cfg!(debug_assertions).then(|| tracing_subscriber::fmt::layer().with_writer(std::io::stderr));

        // try_init (not init): idempotent + never panics if a global is already set.
        let _ = tracing_subscriber::registry()
            .with(env_filter())
            .with(file_layer)
            .with(stderr_layer)
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
/// built. In a release build `release_max_level_info` lowers that cap to `info`, and building
/// an `EnvFilter` whose level exceeds the cap makes `tracing-subscriber` `eprintln!` a
/// multi-line warning to stderr — which would break "no console output in release" (AR-P-5).
/// `debug`/`trace` are compiled out in release anyway, so clamping loses no real output. In
/// debug builds the cap is `trace`, so the clamp is a no-op and full `RUST_LOG` directive
/// syntax is honored verbatim.
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
