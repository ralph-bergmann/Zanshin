// SPDX-License-Identifier: MIT

//! Story 9.52 witnesses: cancelling `Repo::git_fetch` and `Repo::git_push` through their cancel
//! tokens. A slow `git` is a wrapper script generated in a temp dir and set as the repo's
//! `git.executable-path` (repo-level config, so the tests stay parallel); it runs the real `git`
//! from `PATH`. Each wrapper writes marker files the test waits on, so a cancel lands at a known
//! point. The clone rows need a user-level config and live in `tests/it/clone_cancel.rs`.

use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use tempfile::TempDir;
use zanshin_jj::cancel::{self, CancelGuard};
use zanshin_jj::{
    Backend, CloneOptions, GitPushArgs, InitOptions, MutateError, ProgressEvent, PushFailureKind, PushRefStatus, Repo,
};

/// The kill must beat the wrappers' 30 s sleep by far.
const KILLED_WITHIN: Duration = Duration::from_secs(10);

/// Runs `git` in `dir`; panics on a non-zero exit. Fixture setup only.
fn git(args: &[&str], dir: &Path) -> String {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git spawns");
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// The real `git` on `PATH`, as an absolute path for the wrappers.
fn real_git() -> String {
    let out = Command::new("/bin/sh")
        .args(["-c", "command -v git"])
        .output()
        .expect("sh spawns");
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// A token of this binary's own, far from anything else in the process.
fn token() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1 << 40);
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    cancel::register(id);
    id
}

/// Cancels `id` once `marker` exists.
fn cancel_when(marker: PathBuf, id: u64) -> JoinHandle<()> {
    thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_mins(1);
        while !marker.exists() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(20));
        }
        cancel::cancel(id);
    })
}

/// Cancels `id` once `marker` exists, then writes `confirmed`, which the wrapper waits for.
fn cancel_and_confirm(marker: PathBuf, id: u64, confirmed: PathBuf) -> JoinHandle<()> {
    thread::spawn(move || {
        cancel_when(marker, id).join().unwrap();
        fs::write(confirmed, "").unwrap();
    })
}

/// A workspace cloned (not colocated) from a bare remote with `main` (two commits), `@` on
/// `main`, plus the temp dir the wrapper scripts and markers live in.
struct World {
    _dirs: Vec<TempDir>,
    bare: PathBuf,
    root: PathBuf,
    scratch: PathBuf,
    repo: Repo,
}

fn world() -> World {
    test_helpers::pin_test_env();
    let src = TempDir::new().unwrap();
    git(&["init", "--initial-branch=main"], src.path());
    git(&["config", "user.email", "test@zanshin.test"], src.path());
    git(&["config", "user.name", "Fixture"], src.path());
    for (n, text) in ["hello", "hello again"].into_iter().enumerate() {
        fs::write(src.path().join("README.md"), text).unwrap();
        git(&["add", "."], src.path());
        git(&["commit", "-m", &format!("commit {n}")], src.path());
    }
    let parent = TempDir::new().unwrap();
    let bare = parent.path().join("remote.git");
    git(
        &[
            "clone",
            "--bare",
            &src.path().to_string_lossy(),
            &bare.to_string_lossy(),
        ],
        parent.path(),
    );
    let ws = TempDir::new().unwrap();
    let root = ws.path().join("ws");
    let repo = Repo::clone(
        &CloneOptions {
            source: bare.to_string_lossy().into_owned(),
            destination: root.clone(),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: ProgressEvent| {},
        None,
    )
    .result
    .expect("clone the remote");
    let root = fs::canonicalize(root).unwrap();
    let scratch = parent.path().join("scratch");
    fs::create_dir(&scratch).unwrap();
    World {
        _dirs: vec![src, parent, ws],
        bare,
        root,
        scratch,
        repo,
    }
}

impl World {
    /// Writes `body` as the wrapper script and sets it as the repo's `git.executable-path`.
    /// `$GIT` is the real git, `$MARK` the scratch dir.
    fn slow_git(&mut self, body: &str) {
        let path = self.scratch.join("slow-git");
        let text = format!(
            "#!/bin/sh\nGIT='{}'\nMARK='{}'\n{body}\n",
            real_git(),
            self.scratch.display()
        );
        fs::write(&path, text).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        let id = fs::read_to_string(self.root.join(".jj").join("repo").join("config-id")).expect("config-id");
        let xdg = PathBuf::from(std::env::var_os("XDG_CONFIG_HOME").expect("pinned"));
        let config = xdg.join("jj").join("repos").join(id.trim()).join("config.toml");
        let existing = fs::read_to_string(&config).unwrap_or_default();
        fs::write(
            &config,
            format!("{existing}\n[git]\nexecutable-path = '{}'\n", path.display()),
        )
        .expect("write the repo config");
        self.repo = Repo::open(&self.root).expect("reopen");
    }

    fn marker(&self, name: &str) -> PathBuf {
        self.scratch.join(name)
    }

    fn head_op(&mut self) -> String {
        self.repo.op_log(Some(1)).expect("op log")[0].id.0.clone()
    }

    fn fetch(&mut self, guard: &CancelGuard) -> Result<zanshin_jj::MutationResult, MutateError> {
        self.repo.git_fetch("origin", &|_: ProgressEvent| {}, Some(guard))
    }

    /// Adds a bare copy of the remote as `name`, with `main@name` tracked at the remote's `main`.
    fn add_remote_copy(&mut self, name: &str) {
        let copy = self.bare.with_file_name(format!("{name}.git"));
        git(
            &["clone", "--bare", &self.bare.to_string_lossy(), &copy.to_string_lossy()],
            &self.scratch,
        );
        self.repo
            .git_remote_add(name, &copy.to_string_lossy(), None)
            .expect("add a remote");
        let main = git(&["rev-parse", "main"], &self.bare);
        test_helpers::set_remote_bookmark(&self.root, "main", name, &main, true);
        self.repo = Repo::open(&self.root).expect("reopen");
    }

    /// `main` moved onto a new described commit, `@` a child of it; returns its hex.
    fn advance_main(&mut self) -> String {
        let main = git(&["rev-parse", "main"], &self.bare);
        let third = test_helpers::add_commit_with_files(&self.root, &[&main], &[("third.txt", "third")], "third");
        test_helpers::set_local_bookmark(&self.root, "main", &[&third]);
        self.repo = Repo::open(&self.root).expect("reopen");
        third
    }

    fn push_r1_r2(&mut self, guard: &CancelGuard) -> zanshin_jj::GitPushOutcome {
        self.repo
            .git_push(
                &GitPushArgs {
                    remotes: Some(vec!["r1".to_owned(), "r2".to_owned()]),
                    bookmarks: vec!["main".to_owned()],
                    ..Default::default()
                },
                &|_: ProgressEvent| {},
                Some(guard),
            )
            .expect("a push's cancel is data")
    }
}

/// Cancel mid-fetch: git has fetched and the wrapper holds its pipes open; the cancel kills it,
/// the fetch refuses as `Cancelled` within seconds and imports nothing.
// The kill is macOS-only.
#[cfg(target_os = "macos")]
#[test]
fn a_fetch_cancelled_while_git_runs_is_killed_and_records_nothing() {
    let mut w = world();
    w.slow_git(r#""$GIT" "$@"; s=$?; touch "$MARK/fetched"; sleep 30; exit $s"#);
    let before = w.head_op();
    let id = token();
    let guard = cancel::attach(id).expect("attaches");
    let canceller = cancel_when(w.marker("fetched"), id);
    let started = Instant::now();
    let result = w.fetch(&guard);
    let elapsed = started.elapsed();
    canceller.join().unwrap();
    assert!(matches!(result, Err(MutateError::Cancelled)), "{result:?}");
    assert!(elapsed < KILLED_WITHIN, "the kill took {elapsed:?}");
    drop(guard);
    assert_eq!(w.head_op(), before, "no import, no operation");
}

/// A cancel after git finished but before the import: git is NOT killed (the wrapper re-execs as
/// a process that neither carries the token nor names the git dir, and only that one writes the
/// marker the cancel waits for), and the fetch still refuses at its checkpoint before
/// `import_refs`.
#[test]
fn a_fetch_cancelled_after_its_git_work_refuses_before_the_import() {
    let mut w = world();
    w.slow_git(
        r#""$GIT" "$@"; s=$?
exec env -u ZANSHIN_CANCEL_TOKEN /bin/sh -c "touch '$MARK/fetched'; while [ ! -e '$MARK/cancelled' ]; do sleep 0.05; done; exit $s""#,
    );
    let before = w.head_op();
    let id = token();
    let guard = cancel::attach(id).expect("attaches");
    let canceller = cancel_and_confirm(w.marker("fetched"), id, w.marker("cancelled"));
    let result = w.fetch(&guard);
    canceller.join().unwrap();
    assert!(matches!(result, Err(MutateError::Cancelled)), "{result:?}");
    drop(guard);
    assert_eq!(w.head_op(), before, "no import, no operation");
}

/// A cancel before the fetch's first checkpoint: git never runs.
#[test]
fn a_fetch_cancelled_before_it_starts_never_runs_git() {
    let mut w = world();
    w.slow_git(r#"touch "$MARK/ran"; exec "$GIT" "$@""#);
    let before = w.head_op();
    let id = token();
    cancel::cancel(id);
    let guard = cancel::attach(id).expect("attaches");
    let result = w.fetch(&guard);
    assert!(matches!(result, Err(MutateError::Cancelled)), "{result:?}");
    assert!(!w.marker("ran").exists(), "git never ran");
    drop(guard);
    assert_eq!(w.head_op(), before);
}

/// Story 9.24: a remote-change poll cancelled while its `git ls-remote` runs — the wrapper's git
/// is killed and the poll refuses as `Cancelled` within seconds, writing nothing.
// The kill is macOS-only.
#[cfg(target_os = "macos")]
#[test]
fn a_remote_change_poll_cancelled_while_git_runs_is_killed() {
    let mut w = world();
    w.slow_git(r#""$GIT" "$@"; s=$?; touch "$MARK/listed"; sleep 30; exit $s"#);
    let before = w.head_op();
    let id = token();
    let guard = cancel::attach(id).expect("attaches");
    let canceller = cancel_when(w.marker("listed"), id);
    let started = Instant::now();
    let result = w.repo.remote_changes("origin", Some(&guard));
    let elapsed = started.elapsed();
    canceller.join().unwrap();
    assert!(matches!(result, Err(MutateError::Cancelled)), "{result:?}");
    assert!(elapsed < KILLED_WITHIN, "the kill took {elapsed:?}");
    drop(guard);
    assert_eq!(w.head_op(), before, "no operation");
}

/// Story 9.24: a remote-change poll cancelled before it starts never runs git.
#[test]
fn a_remote_change_poll_cancelled_before_it_starts_never_runs_git() {
    let mut w = world();
    w.slow_git(r#"touch "$MARK/ran"; exec "$GIT" "$@""#);
    let id = token();
    cancel::cancel(id);
    let guard = cancel::attach(id).expect("attaches");
    let result = w.repo.remote_changes("origin", Some(&guard));
    assert!(matches!(result, Err(MutateError::Cancelled)), "{result:?}");
    assert!(!w.marker("ran").exists(), "git never ran");
}

/// A fetch with a token nobody cancels is a normal fetch, and a cancel after it is a no-op.
#[test]
fn an_uncancelled_fetch_finishes_and_a_later_cancel_is_a_no_op() {
    let mut w = world();
    let before = w.head_op();
    let id = token();
    let guard = cancel::attach(id).expect("attaches");
    w.fetch(&guard).expect("fetch");
    drop(guard);
    cancel::cancel(id);
    assert_ne!(w.head_op(), before, "the fetch wrote its operation");
}

/// A non-network error while cancelled is that error: a workspace with no git backend refuses as
/// `NotAGitRepo`, a push with no remote as `InvalidInput`.
#[test]
fn a_non_network_error_while_cancelled_passes_through() {
    test_helpers::pin_test_env();
    let native = TempDir::new().unwrap();
    let mut repo = Repo::init(&InitOptions {
        path: native.path().to_owned(),
        ..Default::default()
    })
    .result
    .expect("native init");
    let id = token();
    cancel::cancel(id);
    let guard = cancel::attach(id).expect("attaches");
    let fetched = repo.git_fetch("origin", &|_: ProgressEvent| {}, Some(&guard));
    assert!(matches!(fetched, Err(MutateError::NotAGitRepo)), "{fetched:?}");

    let git_ws = TempDir::new().unwrap();
    let mut repo = Repo::init(&InitOptions {
        path: git_ws.path().to_owned(),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("git init");
    let pushed = repo.git_push(&GitPushArgs::default(), &|_: ProgressEvent| {}, Some(&guard));
    assert!(matches!(pushed, Err(MutateError::InvalidInput { .. })), "{pushed:?}");
}

/// Remotes r1 and r2, r2's git slow: the cancel kills r2's push; r1 is finished with its ref
/// pushed, r2 is not finished, the failure is `Cancelled` and nothing is recorded.
// The kill is macOS-only.
#[cfg(target_os = "macos")]
#[test]
fn a_push_cancelled_between_remotes_reports_which_remotes_got_their_refs() {
    let mut w = world();
    let third = w.advance_main();
    w.add_remote_copy("r1");
    w.add_remote_copy("r2");
    w.slow_git(
        r#"for a in "$@"; do [ "$a" = r2 ] && { touch "$MARK/r2"; sleep 30; }; done
exec "$GIT" "$@""#,
    );
    let before = w.head_op();
    let id = token();
    let guard = cancel::attach(id).expect("attaches");
    let canceller = cancel_when(w.marker("r2"), id);
    let started = Instant::now();
    let outcome = w.push_r1_r2(&guard);
    let elapsed = started.elapsed();
    canceller.join().unwrap();
    drop(guard);
    assert!(elapsed < KILLED_WITHIN, "the kill took {elapsed:?}");
    let failure = outcome.failure.as_ref().expect("failed");
    assert_eq!(
        (failure.kind, failure.message.as_str()),
        (PushFailureKind::Cancelled, "Cancelled")
    );
    assert!(!outcome.recorded);
    assert_eq!(outcome.remotes[0].name, "r1");
    assert!(outcome.remotes[0].finished);
    assert_eq!(outcome.remotes[0].refs[0].status, Some(PushRefStatus::Pushed));
    assert_eq!(outcome.remotes[1].name, "r2");
    assert!(!outcome.remotes[1].finished);
    let r1 = w.bare.with_file_name("r1.git");
    assert_eq!(git(&["rev-parse", "main"], &r1), third, "r1 has the ref");
    assert_eq!(w.head_op(), before, "nothing recorded");
}

/// A push cancelled before its first remote: no git push runs, nothing is pushed or recorded.
#[test]
fn a_push_cancelled_before_it_starts_runs_no_git_push() {
    let mut w = world();
    w.advance_main();
    w.add_remote_copy("r1");
    w.add_remote_copy("r2");
    w.slow_git(r#"touch "$MARK/ran"; exec "$GIT" "$@""#);
    let before = w.head_op();
    let id = token();
    cancel::cancel(id);
    let guard = cancel::attach(id).expect("attaches");
    let outcome = w.push_r1_r2(&guard);
    drop(guard);
    assert_eq!(outcome.failure.map(|f| f.kind), Some(PushFailureKind::Cancelled));
    assert!(!outcome.recorded);
    assert!(outcome.remotes.iter().all(|remote| !remote.finished));
    assert!(!w.marker("ran").exists(), "no git push ran");
    assert_eq!(w.head_op(), before);
}

/// A cancel after the last remote's git push started is too late: there is no checkpoint after
/// the last remote, so the push finishes normally and is recorded. The wrapper re-execs as a
/// process that neither carries the token nor names the git dir, and only that one writes the
/// marker the cancel waits for, so the cancel kills nothing.
#[test]
fn a_push_cancelled_during_the_last_git_push_finishes_normally() {
    let mut w = world();
    let third = w.advance_main();
    w.add_remote_copy("r1");
    w.add_remote_copy("r2");
    w.slow_git(
        r#""$GIT" "$@"; s=$?
for a in "$@"; do [ "$a" = r2 ] && r2=1; done
[ -n "$r2" ] && exec env -u ZANSHIN_CANCEL_TOKEN /bin/sh -c "touch '$MARK/r2'; while [ ! -e '$MARK/cancelled' ]; do sleep 0.05; done; exit $s"
exit $s"#,
    );
    let before = w.head_op();
    let id = token();
    let guard = cancel::attach(id).expect("attaches");
    let canceller = cancel_and_confirm(w.marker("r2"), id, w.marker("cancelled"));
    let outcome = w.push_r1_r2(&guard);
    canceller.join().unwrap();
    assert!(guard.is_cancelled(), "the cancel did land");
    drop(guard);
    assert_eq!(outcome.failure, None);
    assert!(outcome.recorded);
    assert!(outcome.remotes.iter().all(|remote| remote.finished));
    let r2 = w.bare.with_file_name("r2.git");
    assert_eq!(git(&["rev-parse", "main"], &r2), third);
    assert_ne!(w.head_op(), before, "the push was recorded");
}

/// The token reaches git's environment: with a guard every git runs with
/// `ZANSHIN_CANCEL_TOKEN=<token>`, without one with no such variable.
#[test]
fn the_token_rides_gits_environment_only_for_a_call_that_carries_one() {
    let mut w = world();
    w.slow_git(r#"env >> "$MARK/env"; exec "$GIT" "$@""#);
    let id = token();
    let guard = cancel::attach(id).expect("attaches");
    w.fetch(&guard).expect("fetch with a token");
    drop(guard);
    let with = fs::read_to_string(w.marker("env")).expect("the wrapper ran");
    assert!(
        with.lines().any(|line| line == format!("ZANSHIN_CANCEL_TOKEN={id}")),
        "{with}"
    );

    fs::remove_file(w.marker("env")).unwrap();
    w.repo
        .git_fetch("origin", &|_: ProgressEvent| {}, None)
        .expect("fetch without a token");
    let without = fs::read_to_string(w.marker("env")).expect("the wrapper ran");
    assert!(!without.contains("ZANSHIN_CANCEL_TOKEN"), "{without}");
}

/// Set in the environment of the child process
/// `a_readable_process_spawned_after_the_cancel_is_killed_by_its_token` spawns.
const SLEEPER_VAR: &str = "ZANSHIN_TEST_SLEEPER";

/// Not a witness of its own: run as that child (this test binary with [`SLEEPER_VAR`] set), it
/// sleeps 30 s; in a normal run it returns at once.
#[test]
fn sleeper_child() {
    if std::env::var_os(SLEEPER_VAR).is_some() {
        thread::sleep(Duration::from_secs(30));
    }
}

/// The token pair alone marks a process whose environment is readable — a locally built binary,
/// not one of Apple's platform binaries (e.g. Homebrew's git) — and a process spawned after the
/// cancel, while its verb is attached, is caught too. The guard watches no git dir, so only the
/// pair can match.
#[cfg(target_os = "macos")]
#[test]
fn a_readable_process_spawned_after_the_cancel_is_killed_by_its_token() {
    use std::os::unix::process::ExitStatusExt as _;

    let id = token();
    let guard = cancel::attach(id).expect("attaches");
    cancel::cancel(id);
    let (name, value) = guard.env_pair();
    let mut child = Command::new(std::env::current_exe().expect("the test binary"))
        .args(["--exact", "network_cancel::sleeper_child", "--test-threads=1"])
        .env(SLEEPER_VAR, "1")
        .env(name, value)
        .stdout(std::process::Stdio::null())
        .spawn()
        .expect("the test binary spawns");
    let deadline = Instant::now() + KILLED_WITHIN;
    let status = loop {
        if let Some(status) = child.try_wait().expect("try_wait") {
            break Some(status);
        }
        if Instant::now() >= deadline {
            break None;
        }
        thread::sleep(Duration::from_millis(20));
    };
    drop(guard);
    let Some(status) = status else {
        child.kill().expect("kill");
        child.wait().expect("wait");
        panic!("the process carrying the token was not killed");
    };
    assert_eq!(status.signal(), Some(libc::SIGTERM));
}
