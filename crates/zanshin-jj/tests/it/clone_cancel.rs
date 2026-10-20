// SPDX-License-Identifier: MIT

//! Story 9.52 witnesses: cancelling `Repo::clone` through its cancel token. The new repository
//! has no config yet, so the slow `git` — a wrapper script that waits 30 s and then runs the real
//! `git` from `PATH` — comes from a user-level `JJ_CONFIG` file.
//!
//! # Why one test in its own process
//!
//! `JJ_CONFIG` is process-global, so — the `tests/it/config_identity.rs` idiom — this file holds
//! exactly ONE `#[test]` that walks the clone rows of the story's matrix in sequence.

use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use tempfile::TempDir;
use zanshin_jj::cancel;
use zanshin_jj::{CloneOptions, CreationOutcome, ProgressEvent, Repo, RepoError};

/// The kill must beat the wrapper's 30 s sleep by far.
const KILLED_WITHIN: Duration = Duration::from_secs(10);

/// Runs `git` in `dir`; panics on a non-zero exit. Fixture setup only.
fn git(args: &[&str], dir: &Path) {
    let status = Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .expect("git spawns");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

fn set_env(name: &str, value: &str) {
    // SAFETY: single-threaded — this test runs alone in its own process (`own_process!`), and every change
    // happens before the calls that read the environment.
    unsafe { std::env::set_var(name, value) };
}

/// Clones `source` into `destination` under token `id`, cancelling it once `marker` exists — or
/// before the clone starts for `None` — and then writing `confirm` (which a waiting wrapper polls
/// for). Returns the outcome and how long the clone took.
fn clone_cancelled(
    source: &str,
    destination: &Path,
    id: u64,
    marker: Option<PathBuf>,
    confirm: Option<PathBuf>,
) -> (CreationOutcome, Duration) {
    cancel::register(id);
    let canceller = match marker {
        None => {
            cancel::cancel(id);
            None
        }
        Some(marker) => Some(thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_mins(1);
            while !marker.exists() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(20));
            }
            cancel::cancel(id);
            if let Some(confirm) = confirm {
                fs::write(confirm, "").unwrap();
            }
        })),
    };
    let guard = cancel::attach(id).expect("attaches");
    let started = Instant::now();
    let outcome = Repo::clone(
        &CloneOptions {
            source: source.to_owned(),
            destination: destination.to_owned(),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: ProgressEvent| {},
        Some(&guard),
    );
    let elapsed = started.elapsed();
    if let Some(canceller) = canceller {
        canceller.join().unwrap();
    }
    (outcome, elapsed)
}

#[test]
fn a_cancelled_clone_refuses_and_cleans_up_what_it_created() {
    test_helpers::own_process!("a_cancelled_clone_refuses_and_cleans_up_what_it_created");
    let tmp = TempDir::new().unwrap();
    let mark = tmp.path().join("mark");
    fs::create_dir(&mark).unwrap();
    let real_git = Command::new("/bin/sh")
        .args(["-c", "command -v git"])
        .output()
        .expect("sh spawns")
        .stdout;
    let wrapper = tmp.path().join("slow-git");
    fs::write(
        &wrapper,
        // Normally slow before git; with `after` present, the real git runs and the `remote show`
        // (the clone's LAST git call) re-execs as a process that is not the call's (no token, no
        // `--git-dir`), which writes `ran` and waits for `confirmed`.
        format!(
            r#"#!/bin/sh
M='{mark}'
G='{git}'
if [ -e "$M/after" ]; then
  "$G" "$@"; s=$?
  case " $* " in *" remote show "*) exec env -u ZANSHIN_CANCEL_TOKEN /bin/sh -c "touch '$M/ran'; while [ ! -e '$M/confirmed' ]; do sleep 0.05; done; exit $s";; esac
  exit $s
fi
touch "$M/ran"
sleep 30
exec "$G" "$@"
"#,
            mark = mark.display(),
            git = String::from_utf8_lossy(&real_git).trim()
        ),
    )
    .unwrap();
    fs::set_permissions(&wrapper, fs::Permissions::from_mode(0o755)).unwrap();
    let config = tmp.path().join("config.toml");
    fs::write(&config, format!("[git]\nexecutable-path = '{}'\n", wrapper.display())).unwrap();
    for (name, value) in test_helpers::TEST_ENV {
        set_env(name, value);
    }
    set_env("JJ_CONFIG", config.to_str().unwrap());
    set_env("XDG_CONFIG_HOME", tmp.path().join("xdg").to_str().unwrap());

    let src = tmp.path().join("src");
    fs::create_dir(&src).unwrap();
    git(&["init", "--initial-branch=main"], &src);
    git(&["config", "user.email", "test@zanshin.test"], &src);
    git(&["config", "user.name", "Fixture"], &src);
    fs::write(src.join("README.md"), "hello").unwrap();
    git(&["add", "."], &src);
    git(&["commit", "-m", "initial"], &src);
    let source = format!("file://{}", src.display());
    let ran = mark.join("ran");

    // The two mid-clone rows depend on the kill, which only macOS does.
    #[cfg(target_os = "macos")]
    {
        // Mid-clone, into a folder the clone creates: git is killed, the folder is gone.
        let created = tmp.path().join("created");
        let (outcome, elapsed) = clone_cancelled(&source, &created, 1 << 41, Some(ran.clone()), None);
        assert!(
            matches!(outcome.result, Err(RepoError::Cancelled)),
            "{:?}",
            outcome.result
        );
        assert!(elapsed < KILLED_WITHIN, "the kill took {elapsed:?}");
        assert!(!created.exists(), "the folder the clone created is gone");

        // Mid-clone, into a pre-existing empty folder: the folder stays, empty.
        let _ = fs::remove_file(&ran);
        let existing = tmp.path().join("existing");
        fs::create_dir(&existing).unwrap();
        let (outcome, elapsed) = clone_cancelled(&source, &existing, (1 << 41) + 1, Some(ran.clone()), None);
        assert!(
            matches!(outcome.result, Err(RepoError::Cancelled)),
            "{:?}",
            outcome.result
        );
        assert!(elapsed < KILLED_WITHIN, "the kill took {elapsed:?}");
        assert!(existing.is_dir(), "a pre-existing folder stays");
        assert_eq!(fs::read_dir(&existing).unwrap().count(), 0, "and is empty again");
    }

    // Cancelled before the first checkpoint: git never runs, the created folder is gone.
    let _ = fs::remove_file(&ran);
    let early = tmp.path().join("early");
    let (outcome, _) = clone_cancelled(&source, &early, (1 << 41) + 2, None, None);
    assert!(
        matches!(outcome.result, Err(RepoError::Cancelled)),
        "{:?}",
        outcome.result
    );
    assert!(!ran.exists(), "git never ran");
    assert!(!early.exists());

    // Cancelled after the clone's last git call returned (`git remote show`): the checkpoint
    // after the git work refuses, and the clean-up removes the folder.
    let _ = fs::remove_file(&ran);
    fs::write(mark.join("after"), "").unwrap();
    let late = tmp.path().join("late");
    let (outcome, _) = clone_cancelled(
        &source,
        &late,
        (1 << 41) + 3,
        Some(ran.clone()),
        Some(mark.join("confirmed")),
    );
    assert!(
        matches!(outcome.result, Err(RepoError::Cancelled)),
        "{:?}",
        outcome.result
    );
    assert!(ran.exists(), "the clone's git work ran to its end");
    assert!(!late.exists(), "the folder the clone created is gone");
}
