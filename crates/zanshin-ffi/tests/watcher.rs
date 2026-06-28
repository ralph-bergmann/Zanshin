// SPDX-License-Identifier: MIT

use std::sync::LazyLock;
use std::time::Duration;
use std::{env, fs};

use zanshin_ffi::watcher::{Watcher, WatcherEvent};

// Pin JJ_CONFIG / GIT_CONFIG_GLOBAL so tests are hermetic.
static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // SAFETY: tests run single-threaded per process (cargo test default).
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

// Generous timeout so tests aren't flaky on a loaded CI host.
const RECV_TIMEOUT: Duration = Duration::from_secs(5);

#[test]
fn watcher_op_heads_changed() {
    pin_env();
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
    pin_env();
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
fn watcher_new_nonexistent_path_errors() {
    pin_env();
    let dir = tempfile::tempdir().unwrap();
    // No .jj/ tree → op_heads_dir watch fails.
    let result = Watcher::new(dir.path());
    assert!(result.is_err(), "Watcher::new should Err when watch paths do not exist");
}

#[test]
fn watcher_burst_coalesces() {
    pin_env();
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
    pin_env();
    let fixture = test_helpers::extract_fixture("tiny-3-commits").unwrap();
    let (watcher, rx) = Watcher::new(&fixture.path).unwrap();

    // stop() joins the debouncer thread, ensuring the handler's SyncSender is
    // dropped before this call returns — so the channel is definitely closed.
    watcher.stop();

    // Drain any events that were buffered before the stop; Err(RecvError) confirms close.
    while rx.recv().is_ok() {}
}
