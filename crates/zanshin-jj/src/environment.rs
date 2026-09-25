// SPDX-License-Identifier: MIT

//! `environment.rs` — the environment every CLI-parity read in this crate sees (Story 9.36).
//!
//! A Zanshin started from Finder or the Dock inherits launchd's minimal environment, not the one a
//! terminal `jj` gets from the user's login shell: `JJ_CONFIG`, `XDG_CONFIG_HOME`, `JJ_USER` /
//! `JJ_EMAIL` / `JJ_OP_*`, `VISUAL` / `EDITOR`, `NO_COLOR` set in a shell rc file never reach the
//! config stack, and jj-lib's `git` subprocess misses the shell's `PATH`, `SSH_AUTH_SOCK` and
//! `GIT_*`. [`adopt_login_shell_environment`] runs the login shell ONCE at start-up and adopts its
//! environment as a write-once, process-wide map. Every reader here goes through [`snapshot`] /
//! [`var_os`] (the config stack, `detect.rs`'s `$HOME`, `wc_ops.rs`'s `$XDG_CONFIG_HOME`) or
//! [`git_subprocess_options`] (fetch and clone): they see the adopted map when there is one and
//! the live process environment otherwise — so until an adoption succeeds (tests, MCP, a failed
//! read) everything behaves exactly as before.
//!
//! The map is never written into the process environment: setting a process variable is unsound
//! while other threads run, and the process keeps the environment it was started with. This module is
//! the only one in the crate that touches `std::env`.
//!
//! Not reached by the adopted map (no hook exists): jj-lib's signing subprocesses (`gpg`,
//! `ssh-keygen`), its `git gc`, and gix's in-process config reads — they see the process
//! environment.

use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::io::{ErrorKind, Read as _};
use std::os::unix::ffi::OsStringExt as _;
use std::process::{Child, ChildStdout, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, Instant};

use jj_lib::config::ConfigGetError;
use jj_lib::git::GitSubprocessOptions;
use jj_lib::settings::UserSettings;

use crate::warning::{self, Warning, WarningKind};

// `JJ_CONFIG`'s path-list splitter, re-exported so `std::env` stays in this module.
pub(crate) use std::env::split_paths;

/// An environment: raw bytes on both sides, so non-UTF-8 values survive.
pub(crate) type EnvMap = HashMap<OsString, OsString>;

// WHY a process-wide static (the crate's first): the login shell's environment is a property of
// the PROCESS, exactly like the environment it stands in for — every reader needs it and none
// owns it. It is written at most once and never mutated afterwards, so readers need no lock;
// AD-2's no-lock rule is about repo handles, which this is not.
static ADOPTED: OnceLock<EnvMap> = OnceLock::new();

/// Printed before the environment dump — opaque; only this module reads it.
const BEGIN: &str = "__ZANSHIN_LOGIN_ENV_BEGIN__";
/// Printed after the environment dump. Reading it — not EOF — is what makes a read succeed: a
/// background job the rc file started may keep the pipe open long after the shell is done.
const END: &str = "__ZANSHIN_LOGIN_ENV_END__";

/// How often an exit is polled for while the deadline has not passed.
const EXIT_POLL: Duration = Duration::from_millis(10);

/// The locale variables jj-lib strips (`LC_ALL`, `LANGUAGE`) or pins (`LC_MESSAGES=C`) on its
/// `git` subprocess so it can parse git's output (`git_subprocess.rs:131-136` @ 0.44.0), BEFORE
/// it applies `GitSubprocessOptions::environment` — a shell map carrying them would undo that.
const GIT_LOCALE: [&str; 3] = ["LC_ALL", "LANGUAGE", "LC_MESSAGES"];

/// The second sentence of every [`WarningKind::LoginShellUnresolved`] message.
const FALLBACK: &str = "Using the environment Zanshin was started with.";

/// Adopts the login shell's environment for every environment read in this crate (Story 9.36) —
/// meant to run once at start-up, before any repo is opened.
///
/// Runs `<shell> -l -i -c` (`shell` absent: the process's `$SHELL`) with the inherited
/// environment, stdin and stderr null, and reads the `env -0` dump it prints within `timeout`.
/// From then on the config stack (`JJ_CONFIG`, `XDG_CONFIG_HOME`, `JJ_*`, `VISUAL`/`EDITOR`, …)
/// and the `git` subprocess of a fetch or clone see that map instead of the process environment,
/// which itself is never changed. An adoption after a repo was opened costs that repo one
/// settings reload (its stack fingerprint hashes the environment).
///
/// Returns no warnings when the environment was adopted — or already had been, in which case
/// nothing is spawned (a Flutter hot restart re-runs the bootstrap against the same library).
/// On any failure nothing is adopted, the process environment stays in effect, a later call may
/// try again, and the result is exactly one [`WarningKind::LoginShellUnresolved`].
#[must_use = "the warnings say whether the environment was adopted"]
pub fn adopt_login_shell_environment(shell: Option<&OsStr>, timeout: Duration) -> Vec<Warning> {
    adopt_into(&ADOPTED, resolve_shell(shell), timeout)
}

/// The shell to run: the caller's, else the process's `$SHELL`.
fn resolve_shell(shell: Option<&OsStr>) -> Option<OsString> {
    shell.map(OsStr::to_owned).or_else(|| std::env::var_os("SHELL"))
}

/// [`adopt_login_shell_environment`] into an explicit `store`, with the shell already resolved
/// (`None`: there is none) — so the tests use their own stores, never the process-wide one.
fn adopt_into(store: &OnceLock<EnvMap>, shell: Option<OsString>, timeout: Duration) -> Vec<Warning> {
    if store.get().is_some() {
        return Vec::new();
    }
    let Some(shell) = shell else {
        return vec![warning::local(
            WarningKind::LoginShellUnresolved,
            format!("Could not read the login-shell environment: SHELL is not set. {FALLBACK}"),
        )];
    };
    match read_login_environment(&shell, timeout) {
        Ok(map) => {
            tracing::info!(variables = map.len(), "adopted the login-shell environment");
            // A concurrent adoption that got there first wins; its map is as good as this one.
            let _ = store.set(map);
            Vec::new()
        }
        Err(reason) => vec![warning::local(
            WarningKind::LoginShellUnresolved,
            format!(
                "Could not read the login-shell environment from {}: {reason}. {FALLBACK}",
                shell.to_string_lossy()
            ),
        )],
    }
}

/// Runs the login shell and reads its environment dump; `Err` is the warning's reason. The child
/// is always reaped (killed first when it outlives the deadline) before this returns.
fn read_login_environment(shell: &OsStr, timeout: Duration) -> Result<EnvMap, String> {
    let deadline = Instant::now().checked_add(timeout);
    let command = format!("printf '%s' '{BEGIN}'; /usr/bin/env -0; printf '%s' '{END}'");
    let mut child = Command::new(shell)
        .args(["-l", "-i", "-c", &command])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| format!("could not start it: {e}"))?;
    let (tx, rx) = mpsc::channel();
    let stdout = child.stdout.take();
    // WHY a thread: the only way to bound a blocking pipe read in safe std. It owns nothing but
    // the pipe; after a timeout its receiver is gone and it ends with the pipe's last writer.
    thread::Builder::new()
        .name("zanshin-login-env".to_owned())
        .spawn(move || {
            let _ = tx.send(read_dump(stdout));
        })
        .map_err(|e| {
            reap(&mut child);
            format!("could not start it: {e}")
        })?;
    match rx.recv_timeout(timeout) {
        Ok(Some(dump)) => {
            // Let the shell exit on its own (killed only if it outlives the deadline): an
            // interactive shell started under a controlling terminal took over the terminal's
            // foreground process group and hands it back only on a normal exit — a kill here
            // would leave the terminal's own process stopped by SIGTTIN.
            wait_until(&mut child, deadline);
            Ok(parse_dump(&dump))
        }
        Ok(None) | Err(RecvTimeoutError::Disconnected) => Err(match wait_until(&mut child, deadline) {
            Ended::Exited(status) if !status.success() => format!("it exited with {status}"),
            Ended::Killed => timed_out(timeout),
            // A success status, or an unknown one (`Reaped`): the output ended before the end
            // marker — the one fact that is certain.
            Ended::Exited(_) | Ended::Reaped => "it printed no environment".to_owned(),
        }),
        Err(RecvTimeoutError::Timeout) => {
            reap(&mut child);
            Err(timed_out(timeout))
        }
    }
}

fn timed_out(timeout: Duration) -> String {
    format!("timed out after {} ms", timeout.as_millis())
}

/// Waits for `child` to exit until `deadline` (`None`: no deadline); kills and reaps it when the
/// deadline passes first.
fn wait_until(child: &mut Child, deadline: Option<Instant>) -> Ended {
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ended::Exited(status),
            Ok(None) if deadline.is_none_or(|d| Instant::now() < d) => thread::sleep(EXIT_POLL),
            Ok(None) => {
                reap(child);
                return Ended::Killed;
            }
            // WHY no kill: the pid is no longer ours — killing it could hit a recycled pid.
            Err(_) => return Ended::Reaped,
        }
    }
}

/// How [`wait_until`]'s child ended.
enum Ended {
    /// It exited with this status.
    Exited(ExitStatus),
    /// It exited, but something else in the process reaped it first, so its status is unknown:
    /// the Dart VM does exactly that (`wait()` for ANY child) while one of its own `Process`es
    /// runs — always under `dart test`.
    Reaped,
    /// It outlived the deadline and was killed.
    Killed,
}

fn reap(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

/// Reads `stdout` until the end marker follows the begin marker: `Some(the bytes between them)`;
/// `None` when the output ends (or fails) first.
fn read_dump(stdout: Option<ChildStdout>) -> Option<Vec<u8>> {
    let mut stdout = stdout?;
    let mut out = Vec::new();
    let mut chunk = [0_u8; 8192];
    loop {
        if let Some(dump) = between_markers(&out) {
            return Some(dump.to_vec());
        }
        match stdout.read(&mut chunk) {
            Ok(0) => return None,
            Ok(n) => out.extend_from_slice(chunk.get(..n)?),
            Err(e) if e.kind() == ErrorKind::Interrupted => {}
            Err(_) => return None,
        }
    }
}

/// The bytes between the first begin marker and the end marker after it — anything an rc file
/// printed before the begin marker is skipped.
fn between_markers(out: &[u8]) -> Option<&[u8]> {
    let start = find(out, BEGIN.as_bytes())? + BEGIN.len();
    let rest = out.get(start..)?;
    rest.get(..find(rest, END.as_bytes())?)
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

/// Parses `env -0` output: NUL-separated `KEY=VALUE` entries, kept as raw bytes. An entry splits
/// at the first `=` after its first byte and is skipped without one — the rule
/// `std::env::vars_os` applies to the process's own environment block.
fn parse_dump(dump: &[u8]) -> EnvMap {
    dump.split(|&b| b == 0)
        .filter_map(|entry| {
            let eq = entry.iter().skip(1).position(|&b| b == b'=')? + 1;
            let key = entry.get(..eq)?;
            let value = entry.get(eq + 1..)?;
            Some((OsString::from_vec(key.to_vec()), OsString::from_vec(value.to_vec())))
        })
        .collect()
}

/// The whole environment every CLI-parity read sees: the adopted map, else the process
/// environment.
pub(crate) fn snapshot() -> EnvMap {
    snapshot_in(&ADOPTED)
}

fn snapshot_in(store: &OnceLock<EnvMap>) -> EnvMap {
    store.get().cloned().unwrap_or_else(|| std::env::vars_os().collect())
}

/// One variable of the environment [`snapshot`] returns.
pub(crate) fn var_os(name: &str) -> Option<OsString> {
    var_os_in(&ADOPTED, name)
}

fn var_os_in(store: &OnceLock<EnvMap>, name: &str) -> Option<OsString> {
    match store.get() {
        Some(map) => map.get(OsStr::new(name)).cloned(),
        None => std::env::var_os(name),
    }
}

/// jj-lib's own git-subprocess options (`git.executable-path`) plus the adopted environment — the
/// options every `git` subprocess of a fetch or clone runs with. With nothing adopted the
/// environment map is empty and git inherits the process environment, as in the CLI (which
/// passes an empty map, `cli/src/commands/git/fetch.rs:238` @ v0.44.0). jj-lib applies the map
/// LAST and never clears the inherited environment, so the adopted `PATH` also selects which
/// `git` runs.
///
/// # Errors
///
/// `git.executable-path` does not read (`GitSubprocessOptions::from_settings`).
pub(crate) fn git_subprocess_options(settings: &UserSettings) -> Result<GitSubprocessOptions, ConfigGetError> {
    let mut options = GitSubprocessOptions::from_settings(settings)?;
    options.environment = git_environment(ADOPTED.get());
    Ok(options)
}

/// `adopted` minus [`GIT_LOCALE`]; empty when nothing was adopted.
fn git_environment(adopted: Option<&EnvMap>) -> EnvMap {
    adopted.map_or_else(EnvMap::new, |map| {
        map.iter()
            .filter(|(name, _)| !GIT_LOCALE.iter().any(|locale| name.as_os_str() == OsStr::new(locale)))
            .map(|(name, value)| (name.clone(), value.clone()))
            .collect()
    })
}

#[cfg(test)]
mod tests {
    use std::ffi::{OsStr, OsString};
    use std::fs;
    use std::os::unix::ffi::OsStringExt as _;
    use std::os::unix::fs::PermissionsExt as _;
    use std::path::Path;
    use std::process::{Command, Stdio};
    use std::sync::OnceLock;
    use std::time::{Duration, Instant};

    use super::{adopt_into, git_environment, parse_dump, resolve_shell, snapshot_in, var_os_in, EnvMap, BEGIN, END};
    use crate::WarningKind;

    const FIVE_SECONDS: Duration = Duration::from_secs(5);

    /// A fake login shell: a `#!/bin/sh` script, invoked as `<script> -l -i -c <cmd>` — so `$4`
    /// is the command Zanshin asks the shell to run.
    fn fake_shell(dir: &Path, name: &str, body: &str) -> OsString {
        let path = dir.join(name);
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).expect("write the fake shell");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).expect("chmod the fake shell");
        path.into_os_string()
    }

    /// The one `LoginShellUnresolved` message a failed adoption returns.
    fn only_message(warnings: Vec<crate::Warning>) -> String {
        assert_eq!(warnings.len(), 1, "exactly one warning: {warnings:?}");
        assert_eq!(warnings[0].kind, WarningKind::LoginShellUnresolved);
        warnings.into_iter().next().map(|w| w.message).unwrap_or_default()
    }

    fn expected(shell: &OsStr, reason: &str) -> String {
        format!(
            "Could not read the login-shell environment from {}: {reason}. Using the environment Zanshin was \
             started with.",
            shell.to_string_lossy()
        )
    }

    fn var<'a>(map: &'a EnvMap, name: &str) -> Option<&'a OsStr> {
        map.get(OsStr::new(name)).map(OsString::as_os_str)
    }

    #[test]
    fn a_login_shell_that_prints_its_environment_is_adopted_once_despite_rc_noise_and_a_background_job() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let store = OnceLock::new();
        // A failed attempt adopts nothing and leaves the next call free to try again.
        let failed = only_message(adopt_into(
            &store,
            Some("/nonexistent/zanshin-shell".into()),
            FIVE_SECONDS,
        ));
        assert!(failed.contains("could not start it"), "{failed}");
        assert!(store.get().is_none());

        let shell = fake_shell(
            tmp.path(),
            "noisy",
            "echo welcome\nsleep 30 >&1 &\nZANSHIN_TEST_MARK=present\nODD_VALUE='a=b\nc'\n\
             RAW_VALUE=$(printf 'x\\377y')\nexport ZANSHIN_TEST_MARK ODD_VALUE RAW_VALUE\nexec /bin/sh -c \"$4\"",
        );
        let started = Instant::now();
        assert!(adopt_into(&store, Some(shell), FIVE_SECONDS).is_empty());
        assert!(
            started.elapsed() < FIVE_SECONDS,
            "the end marker, not EOF, ends the read"
        );
        let map = store.get().expect("adopted");
        assert_eq!(var(map, "ZANSHIN_TEST_MARK"), Some(OsStr::new("present")));
        assert_eq!(var(map, "ODD_VALUE"), Some(OsStr::new("a=b\nc")));
        assert_eq!(
            map.get(OsStr::new("RAW_VALUE")),
            Some(&OsString::from_vec(vec![b'x', 0xff, b'y'])),
            "a non-UTF-8 value is kept as raw bytes"
        );

        // A map already adopted: a no-op — no spawn, no warning, the map unchanged.
        let before = map.clone();
        assert!(adopt_into(&store, Some("/nonexistent/shell".into()), FIVE_SECONDS).is_empty());
        assert_eq!(store.get(), Some(&before));
    }

    #[test]
    fn a_shell_that_never_prints_the_end_marker_times_out_and_is_killed() {
        let tmp = tempfile::tempdir().expect("tempdir");
        // A sleep only THIS test process starts: its duration carries our pid, so `pgrep`
        // cannot mistake a concurrent test's sleeper for ours.
        let sleep = format!("sleep 30.{}", std::process::id());
        let shell = fake_shell(tmp.path(), "sleeper", &format!("exec {sleep}"));
        let store = OnceLock::new();
        let started = Instant::now();
        let message = only_message(adopt_into(&store, Some(shell.clone()), Duration::from_millis(200)));
        // A child left running would have kept `wait` blocked for 30 s.
        assert!(started.elapsed() < FIVE_SECONDS);
        assert_eq!(message, expected(&shell, "timed out after 200 ms"));
        assert!(store.get().is_none(), "nothing adopted");
        let found = Command::new("pgrep")
            .args(["-f", &sleep])
            .stdout(Stdio::null())
            .status()
            .expect("pgrep runs");
        assert!(!found.success(), "the timed-out child was killed and reaped");
    }

    #[test]
    fn a_shell_that_closes_its_output_but_keeps_running_times_out_too() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let shell = fake_shell(tmp.path(), "closer", "exec >&-\nexec sleep 30");
        let started = Instant::now();
        let message = only_message(adopt_into(
            &OnceLock::new(),
            Some(shell.clone()),
            Duration::from_millis(200),
        ));
        assert!(started.elapsed() < FIVE_SECONDS);
        assert_eq!(message, expected(&shell, "timed out after 200 ms"));
    }

    #[test]
    fn every_failure_names_its_reason_and_adopts_nothing() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let store = OnceLock::new();

        let message = only_message(adopt_into(
            &store,
            Some("/nonexistent/zanshin-shell".into()),
            FIVE_SECONDS,
        ));
        assert!(
            message.starts_with(
                "Could not read the login-shell environment from /nonexistent/zanshin-shell: could not start it: "
            ),
            "{message}"
        );
        assert!(
            message.ends_with(". Using the environment Zanshin was started with."),
            "{message}"
        );

        let failing = fake_shell(tmp.path(), "failing", "exit 3");
        let message = only_message(adopt_into(&store, Some(failing.clone()), FIVE_SECONDS));
        assert_eq!(message, expected(&failing, "it exited with exit status: 3"));

        let quiet = fake_shell(tmp.path(), "quiet", "echo hello");
        let message = only_message(adopt_into(&store, Some(quiet.clone()), FIVE_SECONDS));
        assert_eq!(message, expected(&quiet, "it printed no environment"));

        let message = only_message(adopt_into(&store, None, FIVE_SECONDS));
        assert_eq!(
            message,
            "Could not read the login-shell environment: SHELL is not set. Using the environment Zanshin was \
             started with."
        );
        assert!(store.get().is_none(), "no failure adopts anything");
    }

    #[test]
    fn the_caller_shell_wins_over_the_process_shell() {
        assert_eq!(
            resolve_shell(Some(OsStr::new("/bin/zsh"))),
            Some(OsString::from("/bin/zsh"))
        );
        assert_eq!(resolve_shell(None), std::env::var_os("SHELL"));
    }

    /// The `vars_os` rule: split at the first `=` after the first byte, skip an entry without one;
    /// rc noise before the begin marker and anything after the end marker is not the dump.
    #[test]
    fn the_dump_parser_keeps_raw_values_and_skips_malformed_entries() {
        let mut out = b"welcome\n".to_vec();
        out.extend_from_slice(BEGIN.as_bytes());
        out.extend_from_slice(b"A=b=c\0NL=x\ny\0RAW=\xff\0NOEQ\0=lead\0EMPTY=\0");
        out.extend_from_slice(END.as_bytes());
        out.extend_from_slice(b"TRAILING=1\0");
        let dump = super::between_markers(&out).expect("both markers");
        let map = parse_dump(dump);
        assert_eq!(var(&map, "A"), Some(OsStr::new("b=c")));
        assert_eq!(var(&map, "NL"), Some(OsStr::new("x\ny")));
        assert_eq!(map.get(OsStr::new("RAW")), Some(&OsString::from_vec(vec![0xff])));
        assert_eq!(var(&map, "EMPTY"), Some(OsStr::new("")));
        assert_eq!(
            map.len(),
            4,
            "`NOEQ` and `=lead` are skipped, `TRAILING` is not in the dump: {map:?}"
        );
        assert!(super::between_markers(END.as_bytes()).is_none(), "no begin marker");
        assert!(super::between_markers(BEGIN.as_bytes()).is_none(), "no end marker yet");
    }

    #[test]
    fn readers_see_the_adopted_map_else_the_process_environment() {
        let empty = OnceLock::new();
        assert_eq!(var_os_in(&empty, "PATH"), std::env::var_os("PATH"));
        assert_eq!(
            snapshot_in(&empty).get(OsStr::new("PATH")).cloned(),
            std::env::var_os("PATH")
        );

        let adopted = OnceLock::new();
        let map: EnvMap = [(OsString::from("ONLY"), OsString::from("1"))].into_iter().collect();
        adopted.set(map.clone()).expect("a fresh store");
        assert_eq!(var_os_in(&adopted, "ONLY"), Some(OsString::from("1")));
        assert_eq!(
            var_os_in(&adopted, "PATH"),
            None,
            "never merged with the process environment"
        );
        assert_eq!(snapshot_in(&adopted), map);
    }

    #[test]
    fn the_git_environment_is_the_adopted_map_minus_the_locale_jj_lib_pins() {
        assert!(
            git_environment(None).is_empty(),
            "nothing adopted: git inherits the process"
        );
        let raw = OsString::from_vec(vec![0xff]);
        let map: EnvMap = [
            ("LC_ALL", OsString::from("de_DE.UTF-8")),
            ("LANGUAGE", OsString::from("de")),
            ("LC_MESSAGES", OsString::from("de_DE.UTF-8")),
            ("PATH", OsString::from("/opt/bin")),
            ("RAW", raw.clone()),
        ]
        .into_iter()
        .map(|(k, v)| (OsString::from(k), v))
        .collect();
        let want: EnvMap = [
            (OsString::from("PATH"), OsString::from("/opt/bin")),
            (OsString::from("RAW"), raw),
        ]
        .into_iter()
        .collect();
        assert_eq!(git_environment(Some(&map)), want);
    }
}
