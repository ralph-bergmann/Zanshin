// SPDX-License-Identifier: MIT

//! Filesystem-watch subsystem for Zanshin.
//!
//! Watches two jj-internal paths that signal repository mutations:
//! - `.jj/repo/op_heads/heads/` — every committed jj operation writes here.
//! - `.jj/working_copy/checkout` — updated on every working-copy change.
//!
//! Call [`Watcher::new`] to arm; receive [`WatcherEvent`]s on the returned
//! [`Receiver`]. Drop the [`Watcher`] or call [`Watcher::stop`] to disarm.

use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::time::Duration;

use notify_debouncer_full::notify::{RecommendedWatcher, RecursiveMode};
use notify_debouncer_full::{new_debouncer, DebounceEventResult, Debouncer, RecommendedCache};
use thiserror::Error;

/// Events delivered to the consumer of a [`Watcher`].
#[allow(clippy::module_name_repetitions)]
// WHY: `WatcherEvent` lives in module `watcher`; the prefix aids clarity at
// call sites outside this module where the module name is not in scope.
#[derive(Debug)]
pub enum WatcherEvent {
    /// One or more files changed under `.jj/repo/op_heads/heads/`.
    OpHeadsChanged {
        /// Paths that changed.
        paths: Vec<PathBuf>,
    },
    /// The working-copy checkout file changed.
    WorkingCopyHeartbeat {
        /// Paths that changed.
        paths: Vec<PathBuf>,
    },
    /// The filesystem-watch subsystem encountered an error.
    WatchError {
        /// Human-readable error description.
        message: String,
    },
}

/// Errors returned by [`Watcher::new`].
#[allow(clippy::module_name_repetitions)]
// WHY: `WatcherError` lives in module `watcher`; the prefix aids clarity at
// call sites outside this module where the module name is not in scope.
#[derive(Debug, Error)]
pub enum WatcherError {
    /// An I/O error (e.g. path canonicalization or a missing watched directory).
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    /// The underlying notify watcher failed to initialize or arm.
    #[error("notify error: {0}")]
    Notify(#[from] notify_debouncer_full::notify::Error),
}

// Distinguishes which watch triggered an event.
enum WatchKind {
    OpHeads,
    Heartbeat,
}

/// Active filesystem watcher for a jj repository.
///
/// Created via [`Watcher::new`]. Call [`Watcher::stop`] or drop to disarm.
pub struct Watcher {
    // WHY: the Debouncer owns the background thread and the handler closure
    // (which holds the SyncSender). Dropping it stops both OS watches and
    // closes the sender side of the channel.
    debouncer: Debouncer<RecommendedWatcher, RecommendedCache>,
}

fn classify(path: &Path, op_heads_dir: &Path, checkout_path: &Path) -> Option<WatchKind> {
    if path.starts_with(op_heads_dir) {
        Some(WatchKind::OpHeads)
    } else if path == checkout_path {
        Some(WatchKind::Heartbeat)
    } else {
        None
    }
}

fn send_or_drop(tx: &SyncSender<WatcherEvent>, event: WatcherEvent) {
    if let Err(mpsc::TrySendError::Full(_)) = tx.try_send(event) {
        tracing::warn!("watcher channel full, dropping oldest");
    }
    // Disconnected (receiver gone): this send no-ops; the debouncer thread keeps
    // running until the Watcher is dropped or stopped.
}

/// Resolve the jj repo directory, following the `.jj/repo` indirection.
///
/// In the default workspace `.jj/repo` is a directory. In a *secondary* workspace
/// it is a FILE whose bytes are the primary repo dir's path, relative to `.jj/`
/// (jj-lib 0.42.0 `workspace.rs` `DefaultWorkspaceLoader`); the authoritative
/// `op_heads` live under the resolved primary repo dir, not under the secondary
/// workspace's own `.jj/`. Mirrors jj-lib: read the file, `jj_dir.join(..)`,
/// canonicalize.
fn resolve_repo_dir(jj_dir: &Path) -> Result<PathBuf, WatcherError> {
    let repo_link = jj_dir.join("repo");
    if repo_link.is_file() {
        let buf = std::fs::read(&repo_link)?;
        let rel = Path::new(OsStr::from_bytes(&buf));
        Ok(jj_dir.join(rel).canonicalize()?)
    } else {
        Ok(repo_link)
    }
}

// Route a debounced result to the channel. Extracted from the handler closure so
// the Err-arm (WatchError emission) is unit-testable without driving the OS
// watcher. Runs on the debouncer's background thread → must never panic or block.
fn handle(result: DebounceEventResult, op_heads_dir: &Path, checkout_path: &Path, tx: &SyncSender<WatcherEvent>) {
    match result {
        Ok(events) => {
            let mut op_paths: Vec<PathBuf> = Vec::new();
            let mut heartbeat_paths: Vec<PathBuf> = Vec::new();
            for event in events {
                for path in &event.paths {
                    match classify(path, op_heads_dir, checkout_path) {
                        Some(WatchKind::OpHeads) => op_paths.push(path.clone()),
                        Some(WatchKind::Heartbeat) => heartbeat_paths.push(path.clone()),
                        None => {}
                    }
                }
            }
            if !op_paths.is_empty() {
                send_or_drop(tx, WatcherEvent::OpHeadsChanged { paths: op_paths });
            }
            if !heartbeat_paths.is_empty() {
                send_or_drop(tx, WatcherEvent::WorkingCopyHeartbeat { paths: heartbeat_paths });
            }
        }
        Err(errors) => {
            let message = errors.iter().map(ToString::to_string).collect::<Vec<_>>().join("; ");
            send_or_drop(tx, WatcherEvent::WatchError { message });
        }
    }
}

impl Watcher {
    /// Start watching the jj repository at `repo_path`.
    ///
    /// Returns `(watcher, receiver)`. Keep `watcher` alive while you need
    /// events, then drop it or call [`Self::stop`].
    ///
    /// # Errors
    ///
    /// Returns [`WatcherError::Io`] if `repo_path` — or a required `.jj`
    /// sub-path (the resolved repo dir, `op_heads/heads`, or `working_copy`) —
    /// cannot be canonicalized, e.g. it does not exist. Returns
    /// [`WatcherError::Notify`] if the OS watch cannot be armed (e.g. the
    /// `checkout` file is absent, or an OS watch limit is reached).
    pub fn new(repo_path: &Path) -> Result<(Self, Receiver<WatcherEvent>), WatcherError> {
        // WHY: on macOS, callers may hold a /var/… path (tempfile, Finder) while
        // FSEvents delivers /private/var/… (the resolved canonical path). Canonicalize
        // repo_root — and, below, the actual watch targets — so the paths we classify
        // against match what the OS hands back in events, including any symlinked
        // component below repo_root inside `.jj`.
        let repo_root = repo_path.canonicalize()?;
        let jj_dir = repo_root.join(".jj");
        // WHY: follow the `.jj/repo` indirection so the op_heads watch points at the
        // real store in both default and secondary workspaces (see `resolve_repo_dir`).
        let repo_dir = resolve_repo_dir(&jj_dir)?;
        // The op_heads dir is a structural invariant of any initialized repo; a missing
        // one (corrupt/uninitialized) surfaces here as WatcherError::Io via canonicalize.
        let op_heads_dir = repo_dir.join("op_heads/heads").canonicalize()?;
        // WHY: jj-lib workspace.rs sets working_copy_state_path = <workspace_root>/.jj/working_copy
        // (per-workspace). The heartbeat file is therefore .jj/working_copy/checkout, NOT
        // .jj/repo/working_copy/checkout as written in the story spec / epics.md. Canonicalize
        // the dir (stable) rather than the file (atomically rewritten by jj).
        let checkout_path = jj_dir.join("working_copy").canonicalize()?.join("checkout");

        let (tx, rx) = mpsc::sync_channel::<WatcherEvent>(256);

        let handler = {
            let op_heads_dir = op_heads_dir.clone();
            let checkout_path = checkout_path.clone();
            move |result: DebounceEventResult| handle(result, &op_heads_dir, &checkout_path, &tx)
        };

        let mut debouncer = new_debouncer(Duration::from_millis(50), None, handler)?;
        debouncer.watch(&op_heads_dir, RecursiveMode::NonRecursive)?;
        debouncer.watch(&checkout_path, RecursiveMode::NonRecursive)?;

        Ok((Self { debouncer }, rx))
    }

    /// Stop watching and close the event channel.
    ///
    /// Blocks until the debouncer background thread exits (at most one tick,
    /// ~12 ms). After this returns, the paired [`Receiver`] will return
    /// `Err(RecvError)` once all buffered events are drained.
    pub fn stop(self) {
        // WHY: Debouncer::stop() joins the background thread (unlike plain drop,
        // which only signals it). Joining guarantees the handler's SyncSender is
        // dropped before this function returns, so callers get a synchronous close.
        self.debouncer.stop();
    }
}

#[cfg(test)]
mod tests {
    use std::io::{self, Write};
    use std::path::PathBuf;
    use std::sync::{mpsc, Arc, Mutex};

    use notify_debouncer_full::notify;
    use tracing_subscriber::fmt::MakeWriter;
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::EnvFilter;

    use super::{classify, handle, send_or_drop, WatchKind, WatcherEvent};

    #[test]
    fn classify_op_heads() {
        let op = PathBuf::from("/r/.jj/repo/op_heads/heads");
        let ck = PathBuf::from("/r/.jj/working_copy/checkout");
        let p = PathBuf::from("/r/.jj/repo/op_heads/heads/abc123");
        assert!(matches!(classify(&p, &op, &ck), Some(WatchKind::OpHeads)));
    }

    #[test]
    fn classify_heartbeat() {
        let op = PathBuf::from("/r/.jj/repo/op_heads/heads");
        let ck = PathBuf::from("/r/.jj/working_copy/checkout");
        assert!(matches!(classify(&ck, &op, &ck), Some(WatchKind::Heartbeat)));
    }

    #[test]
    fn classify_unrelated() {
        let op = PathBuf::from("/r/.jj/repo/op_heads/heads");
        let ck = PathBuf::from("/r/.jj/working_copy/checkout");
        let p = PathBuf::from("/r/.jj/repo/store/something");
        assert!(classify(&p, &op, &ck).is_none());
    }

    // Capture tracing output so the channel-full warn can be asserted. Mirrors the
    // `Recorder`/`run_scoped` test helper in `logging.rs` / `tracing_init.rs`.
    #[derive(Clone, Default)]
    struct Recorder(Arc<Mutex<Vec<u8>>>);
    impl Recorder {
        fn contents(&self) -> String {
            String::from_utf8(self.0.lock().unwrap().clone()).unwrap()
        }
    }
    impl Write for Recorder {
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
    fn run_scoped(body: impl FnOnce()) -> String {
        let rec = Recorder::default();
        let subscriber = tracing_subscriber::registry().with(EnvFilter::new("trace")).with(
            tracing_subscriber::fmt::layer()
                .with_ansi(false)
                .with_writer(rec.clone()),
        );
        tracing::subscriber::with_default(subscriber, body);
        rec.contents()
    }

    #[test]
    fn send_or_drop_fills_then_drops_and_warns() {
        let (tx, rx) = mpsc::sync_channel::<WatcherEvent>(1);
        let logs = run_scoped(|| {
            // First send succeeds.
            send_or_drop(&tx, WatcherEvent::WatchError { message: "a".into() });
            // Second is dropped (channel full) — must not panic, and must warn.
            send_or_drop(&tx, WatcherEvent::WatchError { message: "b".into() });
        });
        // Only the first event is in the channel (the second was dropped).
        assert!(matches!(rx.recv().unwrap(), WatcherEvent::WatchError { .. }));
        assert!(rx.try_recv().is_err());
        // AC 9 / AC 16: the verbatim warn text fired (grep-stability contract).
        assert!(
            logs.contains("watcher channel full, dropping oldest"),
            "expected channel-full warn, got logs: {logs:?}"
        );
    }

    #[test]
    fn send_or_drop_disconnected_does_not_panic() {
        let (tx, rx) = mpsc::sync_channel::<WatcherEvent>(1);
        drop(rx);
        send_or_drop(&tx, WatcherEvent::WatchError { message: "gone".into() });
    }

    #[test]
    fn handle_err_emits_watch_error() {
        // Drives the handler's Err-arm directly (the only producer of WatchError),
        // which the OS-watcher integration tests cannot deterministically reach.
        let (tx, rx) = mpsc::sync_channel::<WatcherEvent>(4);
        let op = PathBuf::from("/r/.jj/repo/op_heads/heads");
        let ck = PathBuf::from("/r/.jj/working_copy/checkout");
        handle(Err(vec![notify::Error::generic("boom")]), &op, &ck, &tx);
        match rx.recv().unwrap() {
            WatcherEvent::WatchError { message } => assert!(message.contains("boom")),
            other => panic!("expected WatchError, got {other:?}"),
        }
    }
}
