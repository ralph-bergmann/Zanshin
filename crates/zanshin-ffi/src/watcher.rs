// SPDX-License-Identifier: MIT

//! Filesystem-watch subsystem for Zanshin.
//!
//! Watches two jj-internal paths that signal repository mutations:
//! - `.jj/repo/op_heads/heads/` — every committed jj operation writes here.
//! - `.jj/working_copy/checkout` — updated on every working-copy change.
//!
//! Call [`Watcher::new`] to arm; receive [`WatcherEvent`]s on the returned
//! [`Receiver`]. Drop the [`Watcher`] or call [`Watcher::stop`] to disarm.

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
    // Disconnected: consumer dropped the Receiver; silently stop sending.
}

impl Watcher {
    /// Start watching the jj repository at `repo_path`.
    ///
    /// Returns `(watcher, receiver)`. Keep `watcher` alive while you need
    /// events, then drop it or call [`Self::stop`].
    ///
    /// # Errors
    ///
    /// Returns [`WatcherError::Notify`] if the OS watch cannot be armed
    /// (e.g. the watched paths do not exist, or an OS watch limit is reached).
    pub fn new(repo_path: &Path) -> Result<(Self, Receiver<WatcherEvent>), WatcherError> {
        // WHY: on macOS, callers may hold a /var/… path (tempfile, Finder) while
        // FSEvents delivers /private/var/… (the resolved canonical path). Canonicalize
        // once so the paths we build below match what the OS hands back in events.
        let repo_root = repo_path.canonicalize()?;
        let op_heads_dir = repo_root.join(".jj/repo/op_heads/heads");
        // WHY: jj-lib workspace.rs:140 sets working_copy_state_path = jj_dir/"working_copy"
        // where jj_dir = <workspace_root>/.jj. The correct heartbeat path is therefore
        // .jj/working_copy/checkout, NOT .jj/repo/working_copy/checkout as written in
        // the story spec / epics.md (copy-paste error in those docs).
        let checkout_path = repo_root.join(".jj/working_copy/checkout");

        let (tx, rx) = mpsc::sync_channel::<WatcherEvent>(256);

        let handler = {
            let op_heads_dir = op_heads_dir.clone();
            let checkout_path = checkout_path.clone();
            move |result: DebounceEventResult| match result {
                Ok(events) => {
                    let mut op_paths: Vec<PathBuf> = Vec::new();
                    let mut heartbeat_paths: Vec<PathBuf> = Vec::new();
                    for event in events {
                        for path in &event.paths {
                            match classify(path, &op_heads_dir, &checkout_path) {
                                Some(WatchKind::OpHeads) => op_paths.push(path.clone()),
                                Some(WatchKind::Heartbeat) => heartbeat_paths.push(path.clone()),
                                None => {}
                            }
                        }
                    }
                    if !op_paths.is_empty() {
                        send_or_drop(&tx, WatcherEvent::OpHeadsChanged { paths: op_paths });
                    }
                    if !heartbeat_paths.is_empty() {
                        send_or_drop(&tx, WatcherEvent::WorkingCopyHeartbeat { paths: heartbeat_paths });
                    }
                }
                Err(errors) => {
                    let message = errors.iter().map(ToString::to_string).collect::<Vec<_>>().join("; ");
                    send_or_drop(&tx, WatcherEvent::WatchError { message });
                }
            }
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
    use std::path::PathBuf;
    use std::sync::mpsc;

    use super::{classify, send_or_drop, WatchKind, WatcherEvent};

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

    #[test]
    fn send_or_drop_fills_then_drops() {
        let (tx, rx) = mpsc::sync_channel::<WatcherEvent>(1);
        // First send succeeds.
        send_or_drop(&tx, WatcherEvent::WatchError { message: "a".into() });
        // Second is dropped (channel full) — must not panic.
        send_or_drop(&tx, WatcherEvent::WatchError { message: "b".into() });
        // Only the first event is in the channel.
        assert!(matches!(rx.recv().unwrap(), WatcherEvent::WatchError { .. }));
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn send_or_drop_disconnected_does_not_panic() {
        let (tx, rx) = mpsc::sync_channel::<WatcherEvent>(1);
        drop(rx);
        send_or_drop(&tx, WatcherEvent::WatchError { message: "gone".into() });
    }
}
