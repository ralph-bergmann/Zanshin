// SPDX-License-Identifier: MIT

//! Cancel tokens for the network verbs — fetch, clone and push (Story 9.52).
//!
//! jj-lib 0.46 spawns `git` itself and offers no hook to stop it, so a cancel works from the
//! outside. A token is a process-unique id (the FFI layer allocates it from the session-id
//! space). A verb that carries a token runs every `git` with `ZANSHIN_CANCEL_TOKEN=<token>` in
//! its environment ([`CancelGuard::env_pair`], added by `environment::git_subprocess_options`);
//! git's helpers (`git-remote-*`, `ssh`, `git-upload-pack`) inherit it. [`cancel`] sets the
//! token's flag and — while the verb is attached — polls every [`POLL_INTERVAL`] for the verb's
//! git processes among the descendants of this process: SIGTERM first (git removes its lock and
//! temp files, as on the CLI's Ctrl-C), SIGKILL for any still alive [`KILL_GRACE`] after the
//! cancel. Each one is stopped (SIGSTOP) before its children are listed and continued after the
//! signal, so no child it forks mid-scan escapes as an orphan of a killed parent. Polling keeps
//! running until the verb ends, so a git spawned after the cancel is caught too. The verb itself
//! refuses at its next checkpoint ([`CancelGuard::checkpoint`]); a killed git is
//! indistinguishable from any other failure in jj-lib, so the flag ([`CancelGuard::is_cancelled`])
//! is what tells a cancel apart.
//!
//! Which descendants are the verb's: a process whose environment carries the exact pair, and
//! every descendant of such a process. macOS hides the environment of Apple's platform binaries
//! from other processes (`KERN_PROCARGS2` stops after the arguments) — `/usr/bin/git`, the
//! Command Line Tools' git and its helpers, `/bin/sh`, `ssh` — so for a process whose environment
//! is hidden the arguments decide instead: jj-lib runs every git as `git … --git-dir <dir> …`,
//! and the verb names its repository's git dir ([`watch_store`]) — but only when exactly one live
//! call watches that dir (two handles of one repository get no fallback). Residual: a git
//! without a token on that dir — a concurrent `workspace add`'s worktree git — is not told apart
//! from the call's.
//!
//! Lifetime: [`register`] creates the token's entry, [`attach`] hands the verb its guard, and
//! dropping the guard removes the entry and stops the polling. A cancel of a finished or unknown
//! token is a no-op.
//!
//! Only macOS walks and signals processes; elsewhere a cancel sets the flag and the checkpoints
//! refuse, nothing more.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsString;
use std::os::unix::ffi::OsStrExt as _;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::thread;
use std::time::{Duration, Instant};

use jj_lib::store::Store;

/// The environment variable that marks a cancellable verb's `git` processes.
pub const CANCEL_TOKEN_VAR: &str = "ZANSHIN_CANCEL_TOKEN";

/// How often an attached, cancelled token looks for its verb's processes — and how often a
/// running `fix` tool checks its token.
pub(crate) const POLL_INTERVAL: Duration = Duration::from_millis(50);

/// How long after the cancel a process may outlive its SIGTERM before it gets SIGKILL — and how
/// long a killed `fix` tool's group gets for each step.
pub(crate) const KILL_GRACE: Duration = Duration::from_secs(2);

/// The verb refuses because its token was cancelled.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("cancelled")]
pub struct Cancelled;

#[derive(Debug, Default)]
struct Entry {
    /// When the token was cancelled; `None` while it is not.
    cancelled_at: Option<Instant>,
    /// A verb holds the token's guard.
    attached: bool,
    /// The kill poller runs.
    polling: bool,
    /// The git dirs the verb's git processes name (`--git-dir <dir>`).
    git_dirs: Vec<PathBuf>,
}

static REGISTRY: Mutex<BTreeMap<u64, Entry>> = Mutex::new(BTreeMap::new());

fn registry() -> MutexGuard<'static, BTreeMap<u64, Entry>> {
    // WHY into_inner: the map holds plain flags, so a panic elsewhere cannot leave it half-written.
    REGISTRY.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Creates the entry of token `id`. `0` is no token and is ignored.
pub fn register(id: u64) {
    if id != 0 {
        registry().entry(id).or_default();
    }
}

/// Hands the verb running under token `id` its guard; `None` for `0` or an unknown token, which
/// means the verb carries no token. A token cancelled before this call (a queued verb) starts
/// its kill polling here.
#[must_use = "dropping the guard ends the token"]
pub fn attach(id: u64) -> Option<CancelGuard> {
    let mut map = registry();
    let entry = map.get_mut(&id)?;
    entry.attached = true;
    let start = entry.cancelled_at.is_some() && !entry.polling;
    entry.polling |= start;
    drop(map);
    if start {
        spawn_poller(id);
    }
    Some(CancelGuard { id })
}

/// Cancels token `id`: sets its flag and, while its verb is attached, starts the kill polling.
/// Idempotent; an unknown or finished token is a no-op.
pub fn cancel(id: u64) {
    let mut map = registry();
    let Some(entry) = map.get_mut(&id) else {
        return;
    };
    entry.cancelled_at.get_or_insert_with(Instant::now);
    let start = entry.attached && !entry.polling;
    entry.polling |= start;
    drop(map);
    if start {
        spawn_poller(id);
    }
}

/// A verb's hold on its cancel token; dropping it removes the token and stops the kill polling.
#[derive(Debug)]
pub struct CancelGuard {
    id: u64,
}

impl CancelGuard {
    /// Whether the token was cancelled.
    #[must_use]
    pub fn is_cancelled(&self) -> bool {
        registry()
            .get(&self.id)
            .is_some_and(|entry| entry.cancelled_at.is_some())
    }

    /// A verb's checkpoint: refuses once the token was cancelled.
    ///
    /// # Errors
    ///
    /// [`Cancelled`] — the token was cancelled.
    pub fn checkpoint(&self) -> Result<(), Cancelled> {
        if self.is_cancelled() {
            Err(Cancelled)
        } else {
            Ok(())
        }
    }

    /// The `(name, value)` pair the verb's `git` processes carry: [`CANCEL_TOKEN_VAR`] and the
    /// token.
    #[must_use]
    pub fn env_pair(&self) -> (OsString, OsString) {
        (OsString::from(CANCEL_TOKEN_VAR), OsString::from(self.id.to_string()))
    }

    /// Records a git dir the verb's git processes name, for the processes whose environment is
    /// hidden.
    fn watch_git_dir(&self, dir: PathBuf) {
        if let Some(entry) = registry().get_mut(&self.id) {
            if !entry.git_dirs.contains(&dir) {
                entry.git_dirs.push(dir);
            }
        }
    }
}

impl Drop for CancelGuard {
    fn drop(&mut self) {
        registry().remove(&self.id);
    }
}

impl From<Cancelled> for crate::MutateError {
    fn from(_: Cancelled) -> Self {
        Self::Cancelled
    }
}

impl From<Cancelled> for crate::RepoError {
    fn from(_: Cancelled) -> Self {
        Self::Cancelled
    }
}

/// Whether `cancel` holds a cancelled token — what turns a `git` failure into the cancel.
pub(crate) fn is_cancelled(cancel: Option<&CancelGuard>) -> bool {
    cancel.is_some_and(CancelGuard::is_cancelled)
}

/// A verb's checkpoint for an optional token; a verb without a token never refuses.
pub(crate) fn checkpoint(cancel: Option<&CancelGuard>) -> Result<(), Cancelled> {
    cancel.map_or(Ok(()), CancelGuard::checkpoint)
}

/// Names the git dir of `store`'s Git backend as the verb's, before the verb's git work. A store
/// without a Git backend names nothing (the verb refuses as not-a-git-repo on its own).
pub(crate) fn watch_store(cancel: Option<&CancelGuard>, store: &Store) {
    if let (Some(guard), Ok(backend)) = (cancel, jj_lib::git::get_git_backend(store)) {
        guard.watch_git_dir(backend.git_repo_path().to_owned());
    }
}

/// A signal [`kill_group`] sends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GroupSignal {
    /// SIGTERM: the process may clean up.
    Terminate,
    /// SIGKILL.
    Kill,
}

/// Signals every process of the process group `group` — a `fix` tool spawned as the leader of
/// its own group, so the tool and whatever it forked go together (Story 9.9 follow-on). A group
/// that is gone makes it a no-op. Only macOS signals; elsewhere nothing is sent.
pub(crate) fn kill_group(group: u32, signal: GroupSignal) {
    process::kill_group(group, signal);
}

fn spawn_poller(id: u64) {
    let spawned = thread::Builder::new()
        .name("zanshin-cancel".to_owned())
        .spawn(move || poll(id));
    if let Err(e) = spawned {
        // The flag and the checkpoints still hold; only the kill is lost.
        tracing::warn!(error = %e, "could not start the cancel poller");
        if let Some(entry) = registry().get_mut(&id) {
            entry.polling = false;
        }
    }
}

/// The kill loop of token `id`; ends when the verb's guard is dropped.
fn poll(id: u64) {
    let pair = format!("{CANCEL_TOKEN_VAR}={id}").into_bytes();
    let mut terminated = BTreeSet::new();
    loop {
        let Some((cancelled_at, git_dirs)) = cancelled_with_own_dirs(&registry(), id) else {
            return;
        };
        let marks = Marks {
            pair: &pair,
            git_dirs: &git_dirs,
        };
        let escalate = cancelled_at.elapsed() >= KILL_GRACE;
        let marked = process::stop_marked_descendants(&marks);
        for &pid in &marked {
            if terminated.insert(pid) {
                process::terminate(pid);
            } else if escalate {
                process::kill(pid);
            }
        }
        process::resume(&marked);
        thread::sleep(POLL_INTERVAL);
    }
}

/// When token `id` was cancelled, and the git dirs its verb watches that no OTHER live token
/// watches; `None` once the token is gone or while it is not cancelled. A dir two live calls
/// watch (two handles of one repository) gets no `--git-dir` fallback: a hidden-environment
/// process naming it cannot be told apart, so it is left alone.
fn cancelled_with_own_dirs(map: &BTreeMap<u64, Entry>, id: u64) -> Option<(Instant, Vec<PathBuf>)> {
    let entry = map.get(&id)?;
    let own = entry
        .git_dirs
        .iter()
        .filter(|dir| !map.iter().any(|(other, e)| *other != id && e.git_dirs.contains(dir)))
        .cloned()
        .collect();
    Some((entry.cancelled_at?, own))
}

/// What makes a process the verb's.
struct Marks<'a> {
    /// `ZANSHIN_CANCEL_TOKEN=<token>`.
    pair: &'a [u8],
    /// The git dirs the verb's git processes name.
    git_dirs: &'a [PathBuf],
}

impl Marks<'_> {
    /// Whether the process with this `KERN_PROCARGS2` buffer is the verb's: its environment
    /// carries the pair — or, when the environment is hidden (empty), its arguments hold
    /// `--git-dir <dir>` for one of the verb's git dirs.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))] // WHY: only the macOS walk calls it
    fn matches(&self, procargs: &[u8]) -> bool {
        let (args, env) = split_procargs(procargs);
        if env.is_empty() {
            args.windows(2).any(|pair| {
                pair[0] == b"--git-dir" && self.git_dirs.iter().any(|dir| dir.as_os_str().as_bytes() == pair[1])
            })
        } else {
            env.contains(&self.pair)
        }
    }
}

/// The arguments and the environment strings of a `KERN_PROCARGS2` buffer: a native-endian
/// `argc`, the exec path, NUL padding, `argc` arguments, then the environment up to the first
/// empty string (absent when the kernel hides it).
fn split_procargs(procargs: &[u8]) -> (Vec<&[u8]>, Vec<&[u8]>) {
    let Some((count, rest)) = procargs.split_first_chunk::<4>() else {
        return (Vec::new(), Vec::new());
    };
    let count = usize::try_from(i32::from_ne_bytes(*count)).unwrap_or(0);
    let mut fields = rest.split(|byte| *byte == 0);
    // The exec path.
    fields.next();
    let mut fields = fields.skip_while(|field| field.is_empty());
    let args = fields.by_ref().take(count).collect();
    let env = fields.take_while(|field| !field.is_empty()).collect();
    (args, env)
}

#[cfg(target_os = "macos")]
mod process {
    use std::ffi::{c_int, c_void};
    use std::ptr;

    use libc::pid_t;

    use super::Marks;

    /// Room for this many children per process; a process with more is walked in part.
    const MAX_CHILDREN: usize = 4096;

    /// At most this many walks per poll (a stopped process cannot fork, so they converge fast).
    const MAX_WALKS: usize = 10;

    /// How long in-flight forks get to complete after a round of stops.
    const SETTLE: std::time::Duration = std::time::Duration::from_millis(5);

    /// Every descendant of this process that `marks` matches, and every descendant of such a
    /// process, each STOPPED (SIGSTOP). A process that vanished or cannot be read is skipped (its
    /// children still count).
    ///
    /// A stop takes effect only once a fork the process is in the middle of has completed, and a
    /// child such a fork creates after the walk listed its parent's children would escape the
    /// kill as an orphan once the parent died. So the walk is repeated, a moment after each round
    /// of stops, until it finds nothing new (bounded). The caller signals them, then [`resume`]s
    /// them.
    pub(super) fn stop_marked_descendants(marks: &Marks<'_>) -> Vec<pid_t> {
        let mut stopped: Vec<pid_t> = Vec::new();
        for _ in 0..MAX_WALKS {
            let fresh: Vec<pid_t> = marked_descendants(marks)
                .into_iter()
                .filter(|pid| !stopped.contains(pid))
                .collect();
            if fresh.is_empty() {
                break;
            }
            for &pid in &fresh {
                signal(pid, libc::SIGSTOP);
            }
            stopped.extend(fresh);
            std::thread::sleep(SETTLE);
        }
        stopped
    }

    /// One walk: every descendant `marks` matches, and every descendant of such a process.
    fn marked_descendants(marks: &Marks<'_>) -> Vec<pid_t> {
        let mut marked = Vec::new();
        let mut queue: Vec<(pid_t, bool)> = pid_t::try_from(std::process::id())
            .into_iter()
            .map(|pid| (pid, false))
            .collect();
        while let Some((parent, parent_marked)) = queue.pop() {
            for child in children(parent) {
                let is_marked = parent_marked || procargs(child).is_some_and(|args| marks.matches(&args));
                if is_marked {
                    marked.push(child);
                }
                queue.push((child, is_marked));
            }
        }
        marked
    }

    fn children(parent: pid_t) -> Vec<pid_t> {
        let mut pids: Vec<pid_t> = vec![0; MAX_CHILDREN];
        let size = c_int::try_from(MAX_CHILDREN * size_of::<pid_t>()).unwrap_or(c_int::MAX);
        // SAFETY: `pids` is a live, writable allocation of exactly `size` bytes, and libproc
        // writes at most `size` bytes of pids into it; it returns the number written, or -1.
        let count = unsafe { libc::proc_listchildpids(parent, pids.as_mut_ptr().cast::<c_void>(), size) };
        pids.truncate(usize::try_from(count).unwrap_or(0).min(MAX_CHILDREN));
        pids.retain(|pid| *pid > 0);
        pids
    }

    /// The process's `KERN_PROCARGS2` buffer; `None` when it is gone or cannot be read.
    pub(super) fn procargs(pid: pid_t) -> Option<Vec<u8>> {
        let mut arg_max = [0_u8; size_of::<c_int>()];
        sysctl(&mut [libc::CTL_KERN, libc::KERN_ARGMAX], &mut arg_max)?;
        let mut buffer = vec![0_u8; usize::try_from(c_int::from_ne_bytes(arg_max)).ok()?];
        let size = sysctl(&mut [libc::CTL_KERN, libc::KERN_PROCARGS2, pid], &mut buffer)?;
        buffer.truncate(size);
        Some(buffer)
    }

    /// Reads the `sysctl` value `mib` names into `buffer`; the byte count, or `None` on failure.
    fn sysctl(mib: &mut [c_int], buffer: &mut [u8]) -> Option<usize> {
        let mut size = buffer.len();
        let levels = u32::try_from(mib.len()).ok()?;
        // SAFETY: `mib` is a live array of `levels` names; `buffer` is a live, writable allocation
        // of `size` bytes, and sysctl writes at most that many and stores the count in `size`; no
        // new value is written.
        let read = unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                levels,
                buffer.as_mut_ptr().cast::<c_void>(),
                &raw mut size,
                ptr::null_mut(),
                0,
            )
        };
        (read == 0).then_some(size)
    }

    /// Continues the processes [`stop_marked_descendants`] stopped; a pending SIGTERM is
    /// delivered then.
    pub(super) fn resume(pids: &[pid_t]) {
        for &pid in pids {
            signal(pid, libc::SIGCONT);
        }
    }

    pub(super) fn terminate(pid: pid_t) {
        signal(pid, libc::SIGTERM);
    }

    pub(super) fn kill(pid: pid_t) {
        signal(pid, libc::SIGKILL);
    }

    fn signal(pid: pid_t, signal: c_int) {
        tracing::debug!(pid, signal, "cancel: signalling a git process of a cancelled verb");
        // SAFETY: `kill` takes plain integers and touches no memory of ours. A process that
        // exited since the scan only makes it fail with ESRCH, which is ignored.
        unsafe {
            libc::kill(pid, signal);
        }
    }

    pub(super) fn kill_group(group: u32, signal: super::GroupSignal) {
        let signal = match signal {
            super::GroupSignal::Terminate => libc::SIGTERM,
            super::GroupSignal::Kill => libc::SIGKILL,
        };
        // A group id of 0 or 1 would be ours or init's; a child's pid is neither.
        let Some(group) = pid_t::try_from(group).ok().filter(|group| *group > 1) else {
            return;
        };
        tracing::debug!(group, signal, "cancel: signalling a fix tool's process group");
        // SAFETY: `killpg` takes plain integers and touches no memory of ours. A group whose
        // processes all exited only makes it fail with ESRCH, which is ignored.
        unsafe {
            libc::killpg(group, signal);
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod process {
    use super::Marks;

    pub(super) fn stop_marked_descendants(_marks: &Marks<'_>) -> Vec<i32> {
        Vec::new()
    }

    pub(super) fn resume(_pids: &[i32]) {}

    pub(super) fn terminate(_pid: i32) {}

    pub(super) fn kill(_pid: i32) {}

    pub(super) fn kill_group(_group: u32, _signal: super::GroupSignal) {}
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, ExitStatus};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{Duration, Instant};

    use super::{attach, cancel, register, registry, split_procargs, CancelGuard, Cancelled, Marks, CANCEL_TOKEN_VAR};

    /// Ids far above anything the session counter reaches in a test run.
    fn fresh_id() -> u64 {
        static NEXT: AtomicU64 = AtomicU64::new(1 << 48);
        NEXT.fetch_add(1, Ordering::Relaxed)
    }

    fn procargs(args: &[&str], env: &[&str]) -> Vec<u8> {
        let mut buffer = i32::try_from(args.len()).unwrap().to_ne_bytes().to_vec();
        buffer.extend_from_slice(b"/usr/bin/git\0\0\0\0");
        for field in args.iter().chain(env) {
            buffer.extend_from_slice(field.as_bytes());
            buffer.push(0);
        }
        buffer.extend_from_slice(b"\0junk\0");
        buffer
    }

    #[test]
    fn a_token_lives_from_register_to_the_end_of_its_verb() {
        let id = fresh_id();
        assert!(attach(0).is_none(), "0 is no token");
        assert!(attach(id).is_none(), "an unregistered token is no token");
        register(0);
        assert!(!registry().contains_key(&0));

        register(id);
        let guard = attach(id).expect("a registered token attaches");
        assert!(!guard.is_cancelled());
        assert_eq!(guard.checkpoint(), Ok(()));
        assert_eq!(guard.env_pair(), (CANCEL_TOKEN_VAR.into(), id.to_string().into()));
        guard.watch_git_dir(PathBuf::from("/a"));
        guard.watch_git_dir(PathBuf::from("/a"));
        assert_eq!(registry()[&id].git_dirs, [PathBuf::from("/a")]);

        cancel(id);
        cancel(id);
        assert!(guard.is_cancelled());
        assert_eq!(guard.checkpoint(), Err(Cancelled));
        assert_eq!(Cancelled.to_string(), "cancelled");

        drop(guard);
        assert!(!registry().contains_key(&id), "the guard's drop removes the entry");
        cancel(id);
        assert!(!registry().contains_key(&id), "a finished token's cancel is a no-op");
        assert!(attach(id).is_none());
        // A guard whose entry is gone records nothing.
        CancelGuard { id }.watch_git_dir(PathBuf::from("/b"));
        assert!(!registry().contains_key(&id));
    }

    #[test]
    fn a_token_cancelled_before_its_verb_attaches_starts_cancelled() {
        let id = fresh_id();
        register(id);
        cancel(id);
        let guard = attach(id).expect("attaches");
        assert_eq!(guard.checkpoint(), Err(Cancelled));
        assert_eq!(super::checkpoint(Some(&guard)), Err(Cancelled));
        assert!(super::is_cancelled(Some(&guard)));
        assert_eq!(super::checkpoint(None), Ok(()));
        assert!(!super::is_cancelled(None));
    }

    #[test]
    fn the_procargs_buffer_splits_into_arguments_and_environment() {
        let buffer = procargs(&["git", "fetch"], &["A=1", "ZANSHIN_CANCEL_TOKEN=7"]);
        assert_eq!(
            split_procargs(&buffer),
            (
                vec![&b"git"[..], b"fetch"],
                vec![&b"A=1"[..], b"ZANSHIN_CANCEL_TOKEN=7"]
            )
        );
        assert_eq!(split_procargs(&[1, 2]), (Vec::new(), Vec::new()), "a truncated buffer");
    }

    #[test]
    fn a_process_is_the_verbs_by_its_environment_or_else_by_its_git_dir() {
        let dirs = [PathBuf::from("/repo/.git")];
        let marks = Marks {
            pair: b"ZANSHIN_CANCEL_TOKEN=7",
            git_dirs: &dirs,
        };
        let git = ["git", "--git-dir", "/repo/.git", "fetch"];
        assert!(marks.matches(&procargs(&git, &["ZANSHIN_CANCEL_TOKEN=7"])), "the pair");
        assert!(
            !marks.matches(&procargs(&git, &["ZANSHIN_CANCEL_TOKEN=8"])),
            "a visible environment without the pair is another verb's"
        );
        assert!(marks.matches(&procargs(&git, &[])), "a hidden environment: the git dir");
        assert!(!marks.matches(&procargs(&["git", "--git-dir", "/other/.git"], &[])));
        assert!(!marks.matches(&procargs(&["sleep", "30"], &[])));
    }

    #[cfg(target_os = "macos")]
    fn spawn_marked(id: u64, git_dir: &Path, script: &str) -> Child {
        // `sh` is a platform binary: its environment is hidden, so its `--git-dir` argument
        // (after `$0`) is what marks it; its children are marked with it.
        Command::new("/bin/sh")
            .args(["-c", script, "sh", "--git-dir"])
            .arg(git_dir)
            .env(CANCEL_TOKEN_VAR, id.to_string())
            .spawn()
            .expect("sh spawns")
    }

    #[cfg(target_os = "macos")]
    fn wait_for_exit(child: &mut Child, within: Duration) -> Option<ExitStatus> {
        let deadline = Instant::now() + within;
        while Instant::now() < deadline {
            if let Some(status) = child.try_wait().expect("try_wait") {
                return Some(status);
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        None
    }

    #[cfg(target_os = "macos")]
    fn watching(id: u64, dir: &Path) -> CancelGuard {
        let guard = attach(id).expect("attaches");
        guard.watch_git_dir(dir.to_owned());
        guard
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_cancel_terminates_only_the_verbs_processes_and_only_while_attached() {
        use std::os::unix::process::ExitStatusExt as _;

        let id = fresh_id();
        let other = fresh_id();
        let mine = PathBuf::from(format!("/zanshin-test/{id}/.git"));
        let theirs = PathBuf::from(format!("/zanshin-test/{other}/.git"));
        let mut marked = spawn_marked(id, &mine, "sleep 30; exit 0");
        let mut unmarked = spawn_marked(other, &theirs, "sleep 30; exit 0");
        register(id);
        cancel(id);
        assert!(
            wait_for_exit(&mut marked, Duration::from_millis(300)).is_none(),
            "nothing is killed while no verb is attached"
        );

        let guard = watching(id, &mine);
        let status = wait_for_exit(&mut marked, Duration::from_secs(10)).expect("the verb's process dies");
        assert_eq!(status.signal(), Some(libc::SIGTERM));
        assert!(
            unmarked.try_wait().expect("try_wait").is_none(),
            "another verb's process lives"
        );
        drop(guard);

        unmarked.kill().expect("kill");
        unmarked.wait().expect("wait");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_vanished_process_reads_as_gone() {
        let mut child = Command::new("/bin/sleep").arg("30").spawn().expect("sleep spawns");
        let pid = libc::pid_t::try_from(child.id()).expect("a pid");
        assert!(super::process::procargs(pid).is_some(), "a live child is read");
        child.kill().expect("kill");
        child.wait().expect("wait");
        assert!(super::process::procargs(pid).is_none(), "a reaped process is gone");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_git_dir_two_live_calls_watch_gets_no_fallback() {
        let id = fresh_id();
        let other = fresh_id();
        let shared = PathBuf::from(format!("/zanshin-test/{id}/shared/.git"));
        let mut child = spawn_marked(id, &shared, "sleep 30; exit 0");
        register(id);
        register(other);
        let guard = watching(id, &shared);
        let other_guard = watching(other, &shared);
        cancel(id);
        assert!(
            wait_for_exit(&mut child, Duration::from_millis(500)).is_none(),
            "a hidden-environment process naming a shared git dir is not signalled"
        );
        drop((guard, other_guard));
        child.kill().expect("kill");
        child.wait().expect("wait");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_process_ignoring_sigterm_gets_sigkill_after_the_grace_period() {
        use std::os::unix::process::ExitStatusExt as _;

        let id = fresh_id();
        let dir = PathBuf::from(format!("/zanshin-test/{id}/.git"));
        let scratch = tempfile::TempDir::new().expect("tempdir");
        let trapped = scratch.path().join("trapped");
        let script = format!("trap '' TERM; : > '{}'; sleep 30; exit 0", trapped.display());
        let mut child = spawn_marked(id, &dir, &script);
        // The cancel lands only once the shell has installed its trap.
        let deadline = Instant::now() + Duration::from_secs(10);
        while !trapped.exists() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        register(id);
        let guard = watching(id, &dir);
        let started = Instant::now();
        cancel(id);
        let status = wait_for_exit(&mut child, Duration::from_secs(10)).expect("the process dies");
        assert_eq!(status.signal(), Some(libc::SIGKILL));
        assert!(
            started.elapsed() >= Duration::from_millis(1900),
            "SIGKILL waits for the grace period"
        );
        drop(guard);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn kill_group_signals_a_whole_group_and_never_ours() {
        use std::os::unix::process::{CommandExt as _, ExitStatusExt as _};

        // Ours (0), init's (1) and an id no pid has are no-ops — this test still runs.
        super::kill_group(0, super::GroupSignal::Terminate);
        super::kill_group(1, super::GroupSignal::Terminate);
        super::kill_group(u32::MAX, super::GroupSignal::Kill);

        let scratch = tempfile::TempDir::new().expect("tempdir");
        let forked = scratch.path().join("forked");
        // The leader forks a second member, then both sleep.
        let script = format!("sleep 30 & echo $! > '{}'; wait", forked.display());
        let mut leader = Command::new("/bin/sh")
            .args(["-c", &script])
            .process_group(0)
            .spawn()
            .expect("sh spawns");
        let deadline = Instant::now() + Duration::from_secs(10);
        while std::fs::read_to_string(&forked).map_or(true, |pid| pid.trim().is_empty()) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        let member: libc::pid_t = std::fs::read_to_string(&forked)
            .expect("the member's pid")
            .trim()
            .parse()
            .expect("a pid");
        super::kill_group(leader.id(), super::GroupSignal::Terminate);
        let status = wait_for_exit(&mut leader, Duration::from_secs(10)).expect("the leader dies");
        assert_eq!(status.signal(), Some(libc::SIGTERM));
        let deadline = Instant::now() + Duration::from_secs(10);
        while super::process::procargs(member).is_some() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(super::process::procargs(member).is_none(), "the forked member dies too");
    }
}
