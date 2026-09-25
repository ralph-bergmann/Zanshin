// SPDX-License-Identifier: MIT

//! `environment.rs` — the environment every CLI-parity read in this crate sees (Story 9.36).
//!
//! A Zanshin started from Finder or the Dock inherits launchd's minimal environment, not the one a
//! terminal `jj` gets from the user's login shell: `JJ_CONFIG`, `XDG_CONFIG_HOME`, `JJ_USER` /
//! `JJ_EMAIL` / `JJ_OP_*`, `VISUAL` / `EDITOR`, `NO_COLOR` set in a shell rc file never reach the
//! config stack, and jj-lib's `git` subprocess misses the shell's `PATH`, `SSH_AUTH_SOCK` and
//! `GIT_*`. The app reads the login shell's environment at start-up (`zanshin_core`'s
//! `readLoginShellEnvironment` — this crate spawns no process) and hands it over ONCE through
//! [`adopt_environment`], which keeps it as a write-once, process-wide map. Every reader here goes
//! through [`snapshot`] / [`var_os`] (the config stack, `detect.rs`'s `$HOME`, `wc_ops.rs`'s
//! `$XDG_CONFIG_HOME`) or [`git_subprocess_options`] (fetch and clone): they see the adopted map
//! when there is one and the live process environment otherwise — so until an adoption happens
//! (tests, MCP, a login shell that could not be read) everything behaves exactly as before.
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
use std::hash::BuildHasher;
use std::sync::OnceLock;

use jj_lib::config::ConfigGetError;
use jj_lib::git::GitSubprocessOptions;
use jj_lib::settings::UserSettings;

// `JJ_CONFIG`'s path-list splitter, re-exported so `std::env` stays in this module.
pub(crate) use std::env::split_paths;

/// An environment: raw bytes on both sides, so non-UTF-8 values survive.
pub(crate) type EnvMap = HashMap<OsString, OsString>;

// WHY a process-wide static (the crate's first): the login shell's environment is a property of
// the PROCESS, exactly like the environment it stands in for — every reader needs it and none
// owns it. It is written at most once and never mutated afterwards, so readers need no lock;
// AD-2's no-lock rule is about repo handles, which this is not.
static ADOPTED: OnceLock<EnvMap> = OnceLock::new();

/// The locale variables jj-lib strips (`LC_ALL`, `LANGUAGE`) or pins (`LC_MESSAGES=C`) on its
/// `git` subprocess so it can parse git's output (`git_subprocess.rs:131-136` @ 0.44.0), BEFORE
/// it applies `GitSubprocessOptions::environment` — a shell map carrying them would undo that.
const GIT_LOCALE: [&str; 3] = ["LC_ALL", "LANGUAGE", "LC_MESSAGES"];

/// Adopts `environment` — the login shell's, as the app read it at start-up (Story 9.36) — for
/// every environment read in this crate. Meant to run once, before any repo is opened.
///
/// From then on the config stack (`JJ_CONFIG`, `XDG_CONFIG_HOME`, `JJ_*`, `VISUAL`/`EDITOR`, …)
/// and the `git` subprocess of a fetch or clone see this map — the WHOLE environment, never
/// merged with the process's — instead of the process environment, which itself is never
/// changed. An adoption after a repo was opened costs that repo one settings reload (its stack
/// fingerprint hashes the environment).
///
/// Write-once: when a map was already adopted, this is a no-op and the first map stays (a Flutter
/// hot restart re-runs the bootstrap against the same library).
pub fn adopt_environment<S: BuildHasher>(environment: HashMap<OsString, OsString, S>) {
    adopt_into(&ADOPTED, environment.into_iter().collect());
}

/// [`adopt_environment`] into an explicit `store` — so the tests use their own stores, never the
/// process-wide one.
fn adopt_into(store: &OnceLock<EnvMap>, environment: EnvMap) {
    let variables = environment.len();
    if store.set(environment).is_ok() {
        tracing::info!(variables, "adopted the login-shell environment");
    } else {
        tracing::debug!("a login-shell environment was already adopted; the new one is ignored");
    }
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
    use std::os::unix::ffi::OsStringExt as _;
    use std::sync::OnceLock;

    use super::{adopt_into, git_environment, snapshot_in, var_os_in, EnvMap};

    fn map(entries: &[(&str, &str)]) -> EnvMap {
        entries
            .iter()
            .map(|(name, value)| (OsString::from(name), OsString::from(value)))
            .collect()
    }

    #[test]
    fn the_first_adopted_environment_stays() {
        let store = OnceLock::new();
        let raw = OsString::from_vec(vec![b'x', 0xff, b'y']);
        let mut first = map(&[("ONLY", "1")]);
        first.insert(OsString::from("RAW"), raw.clone());
        adopt_into(&store, first.clone());
        assert_eq!(store.get(), Some(&first), "adopted as given, raw bytes included");
        assert_eq!(var_os_in(&store, "RAW"), Some(raw));

        // A second adoption is a no-op: the first map stays.
        adopt_into(&store, map(&[("ONLY", "2")]));
        assert_eq!(store.get(), Some(&first));
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
        let only = map(&[("ONLY", "1")]);
        adopt_into(&adopted, only.clone());
        assert_eq!(var_os_in(&adopted, "ONLY"), Some(OsString::from("1")));
        assert_eq!(
            var_os_in(&adopted, "PATH"),
            None,
            "never merged with the process environment"
        );
        assert_eq!(snapshot_in(&adopted), only);
    }

    #[test]
    fn the_git_environment_is_the_adopted_map_minus_the_locale_jj_lib_pins() {
        assert!(
            git_environment(None).is_empty(),
            "nothing adopted: git inherits the process"
        );
        let raw = OsString::from_vec(vec![0xff]);
        let mut adopted = map(&[
            ("LC_ALL", "de_DE.UTF-8"),
            ("LANGUAGE", "de"),
            ("LC_MESSAGES", "de_DE.UTF-8"),
            ("PATH", "/opt/bin"),
        ]);
        adopted.insert(OsString::from("RAW"), raw.clone());
        let mut want = map(&[("PATH", "/opt/bin")]);
        want.insert(OsString::from("RAW"), raw);
        assert_eq!(git_environment(Some(&adopted)), want);
    }
}
