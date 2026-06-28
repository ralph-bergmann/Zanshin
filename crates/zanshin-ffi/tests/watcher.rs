// SPDX-License-Identifier: MIT

use std::sync::LazyLock;
use std::time::Duration;
use std::{env, fs};

use zanshin_ffi::watcher::{Watcher, WatcherError, WatcherEvent};

// Pin JJ_CONFIG / GIT_CONFIG_GLOBAL so tests are hermetic.
static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // SAFETY: set once via LazyLock::force before any Watcher is armed, and this
    // test binary performs no concurrent getenv (the watcher path never reads
    // jj-lib/git config) — so there is no set_var/getenv data race. (cargo test
    // is multi-threaded; the single-init-before-use ordering is what makes this
    // sound — mirrors change_ffi.rs / repo_ffi.rs.)
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
fn watcher_new_missing_repo_path_errors_io() {
    pin_env();
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
    pin_env();
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
    use std::sync::mpsc::RecvTimeoutError;

    pin_env();
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

    pin_env();

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
