// SPDX-License-Identifier: MIT

use std::fs;
use std::time::Duration;

use zanshin_ffi::watcher::{Watcher, WatcherError, WatcherEvent};

// Generous timeout so tests aren't flaky on a loaded CI host.
const RECV_TIMEOUT: Duration = Duration::from_secs(5);

#[test]
fn watcher_op_heads_changed() {
    test_helpers::pin_test_env();
    let fixture = test_helpers::extract_fixture("tiny-3-commits").unwrap();
    let (watcher, rx) = Watcher::new(&fixture.path).unwrap();

    let heads_dir = fixture.path.join(".jj/repo/op_heads/heads");
    fs::write(heads_dir.join("test_event"), b"").unwrap();

    let event = rx.recv_timeout(RECV_TIMEOUT).expect("OpHeadsChanged should arrive");
    assert!(
        matches!(event, WatcherEvent::OpHeadsChanged { .. }),
        "expected OpHeadsChanged, got {event:?}"
    );

    watcher.stop();
}

#[test]
fn watcher_working_copy_heartbeat() {
    test_helpers::pin_test_env();
    let fixture = test_helpers::extract_fixture("tiny-3-commits").unwrap();
    let (watcher, rx) = Watcher::new(&fixture.path).unwrap();

    let checkout = fixture.path.join(".jj/working_copy/checkout");
    // Re-write the file to trigger a modify event.
    let contents = fs::read(&checkout).unwrap();
    fs::write(&checkout, &contents).unwrap();

    let event = rx
        .recv_timeout(RECV_TIMEOUT)
        .expect("WorkingCopyHeartbeat should arrive");
    assert!(
        matches!(event, WatcherEvent::WorkingCopyHeartbeat { .. }),
        "expected WorkingCopyHeartbeat, got {event:?}"
    );

    watcher.stop();
}

#[test]
fn watcher_new_missing_repo_path_errors_io() {
    test_helpers::pin_test_env();
    let dir = tempfile::tempdir().unwrap();
    // repo_path itself does not exist → canonicalize() fails → Io.
    let result = Watcher::new(&dir.path().join("does-not-exist"));
    assert!(
        matches!(result, Err(WatcherError::Io(_))),
        "missing repo_path should yield WatcherError::Io"
    );
}

#[test]
fn watcher_new_no_jj_tree_errors_io() {
    test_helpers::pin_test_env();
    let dir = tempfile::tempdir().unwrap();
    // repo_path exists but has no .jj tree → canonicalizing the op_heads dir fails → Io.
    let result = Watcher::new(dir.path());
    assert!(
        matches!(result, Err(WatcherError::Io(_))),
        "missing .jj tree should yield WatcherError::Io"
    );
}

#[test]
fn watcher_burst_coalesces() {
    test_helpers::pin_test_env();
    let fixture = test_helpers::extract_fixture("tiny-3-commits").unwrap();
    let (watcher, rx) = Watcher::new(&fixture.path).unwrap();

    let heads_dir = fixture.path.join(".jj/repo/op_heads/heads");
    let burst: usize = 50;
    for i in 0..burst {
        fs::write(heads_dir.join(format!("burst_{i}")), b"").unwrap();
    }

    // Drain until 200 ms of silence (debounce window is 50 ms).
    let mut received: usize = 0;
    loop {
        match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(WatcherEvent::OpHeadsChanged { .. }) => received += 1,
            Ok(_) => {}
            Err(_) => break,
        }
    }

    assert!(received > 0, "expected at least one OpHeadsChanged");
    assert!(
        received < burst,
        "expected burst to be coalesced ({received} events for {burst} writes)"
    );

    watcher.stop();
}

#[test]
fn watcher_stop_closes_receiver() {
    use std::sync::mpsc::RecvTimeoutError;

    test_helpers::pin_test_env();
    let fixture = test_helpers::extract_fixture("tiny-3-commits").unwrap();
    let (watcher, rx) = Watcher::new(&fixture.path).unwrap();

    // stop() joins the debouncer thread, ensuring the handler's SyncSender is
    // dropped before this call returns — so the channel is definitely closed.
    watcher.stop();

    // Drain any events buffered before the stop; a Disconnected error confirms the
    // channel closed. Bounded so a regression that leaves the channel open fails
    // loudly instead of hanging the (test-timeout-less) gate forever.
    loop {
        match rx.recv_timeout(RECV_TIMEOUT) {
            Ok(_) => {}
            Err(RecvTimeoutError::Disconnected) => break,
            Err(RecvTimeoutError::Timeout) => panic!("channel not closed after stop()"),
        }
    }
}

#[test]
fn watcher_secondary_workspace_resolves_op_heads() {
    use std::os::unix::ffi::OsStrExt;

    test_helpers::pin_test_env();

    let primary = test_helpers::extract_fixture("tiny-3-commits").unwrap();

    // Build a minimal secondary-workspace layout: `.jj/repo` is a FILE whose bytes
    // are the primary repo dir's path (jj-lib DefaultWorkspaceLoader format — jj
    // writes it relative to `.jj/`; an absolute path is equally valid because the
    // resolver does `jj_dir.join(<contents>)`). working_copy is per-workspace.
    let secondary = tempfile::tempdir().unwrap();
    let sec_jj = secondary.path().join(".jj");
    fs::create_dir_all(sec_jj.join("working_copy")).unwrap();
    fs::write(sec_jj.join("working_copy/checkout"), b"").unwrap();
    let primary_repo = primary.path.join(".jj/repo").canonicalize().unwrap();
    fs::write(sec_jj.join("repo"), primary_repo.as_os_str().as_bytes()).unwrap();

    let (watcher, rx) = Watcher::new(secondary.path()).unwrap();

    // A change in the PRIMARY op_heads must reach the secondary workspace's watcher.
    let heads_dir = primary.path.join(".jj/repo/op_heads/heads");
    fs::write(heads_dir.join("sec_event"), b"").unwrap();

    let event = rx
        .recv_timeout(RECV_TIMEOUT)
        .expect("OpHeadsChanged should arrive from the primary repo");
    assert!(
        matches!(event, WatcherEvent::OpHeadsChanged { .. }),
        "expected OpHeadsChanged, got {event:?}"
    );

    watcher.stop();
}

#[test]
fn watcher_recovers_after_watched_dir_moved_away_and_back() {
    use std::sync::mpsc::RecvTimeoutError;
    use std::time::Instant;

    test_helpers::pin_test_env();
    let fixture = test_helpers::extract_fixture("tiny-3-commits").unwrap();
    let (watcher, rx) = Watcher::new(&fixture.path).unwrap();
    let heads_dir = fixture.path.join(".jj/repo/op_heads/heads");

    // Baseline: the watcher is live before any disturbance.
    fs::write(heads_dir.join("baseline_touch"), b"").unwrap();
    let event = rx
        .recv_timeout(RECV_TIMEOUT)
        .expect("baseline OpHeadsChanged should arrive");
    assert!(
        matches!(event, WatcherEvent::OpHeadsChanged { .. }),
        "expected OpHeadsChanged, got {event:?}"
    );

    // Simulate an FS disturbance (FR-RX-4): move the watched dir away and back.
    // Same volume as the fixture root => atomic rename.
    let parked = fixture.path.join("parked_heads");
    fs::rename(&heads_dir, &parked).unwrap();
    fs::rename(&parked, &heads_dir).unwrap();

    // The move itself generates noise on the watched path; drain until 200 ms of
    // silence before touching again (debounce window is 50 ms).
    while rx.recv_timeout(Duration::from_millis(200)).is_ok() {}

    fs::write(heads_dir.join("recovery_touch"), b"").unwrap();

    // Loop-recv, draining non-matching events, bounded by RECV_TIMEOUT overall.
    // No re-arm, no new Watcher — recovery must come from this SAME instance
    // (FR-RX-4; a deterministic failure here is a real product gap, per the
    // story's binding escalation rule — never patched around with manual
    // reset/re-watch logic).
    let deadline = Instant::now() + RECV_TIMEOUT;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(
            !remaining.is_zero(),
            "recovery_touch OpHeadsChanged did not arrive within RECV_TIMEOUT after the watched \
             dir was moved away and back — FR-RX-4 recovery gap"
        );
        match rx.recv_timeout(remaining) {
            Ok(WatcherEvent::OpHeadsChanged { paths }) => {
                if paths
                    .iter()
                    .any(|p| p.file_name().is_some_and(|n| n == "recovery_touch"))
                {
                    break;
                }
            }
            Ok(_) | Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => {
                panic!("channel disconnected while waiting for recovery_touch")
            }
        }
    }

    watcher.stop();
}
