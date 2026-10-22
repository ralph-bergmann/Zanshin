// SPDX-License-Identifier: MIT

//! Runs one scenario end to end: two identical repos, the operation on each side, the diff.

use crate::compare::cli_outcome;
use crate::compare::compare;
use crate::compare::init_outcome;
use crate::compare::outcome_aspects;
use crate::compare::Divergence;
use crate::driver::fresh_repo;
use crate::driver::jj;
use crate::git_scenarios::creation_read_back;
use crate::git_scenarios::prepare;
use crate::git_scenarios::CreationScenario;
use crate::git_scenarios::CREATION_SCENARIOS;
use crate::scenarios::scenarios;
use crate::scenarios::Scenario;
use crate::scenarios::BASE;
use crate::state::capture;

/// The divergences of the scenario `id` (a table scenario or a creation scenario).
///
/// # Panics
/// Panics on an unknown id, and when the two CLI-built repos already differ before the
/// operation ("setup differs") — the scenario would then blame Zanshin for fixture drift.
pub fn run(id: &str) -> Vec<Divergence> {
    on_big_stack(|| {
        if let Some(creation) = CREATION_SCENARIOS.iter().find(|creation| creation.id == id) {
            return run_creation(creation);
        }
        let scenario = scenarios()
            .into_iter()
            .find(|scenario| scenario.id == id)
            .unwrap_or_else(|| panic!("unknown scenario {id}"));
        run_scenario(&scenario)
    })
}

fn run_scenario(scenario: &Scenario) -> Vec<Divergence> {
    let steps = [BASE, scenario.setup];
    let (_dir_a, root_a) = fresh_repo(scenario.init, &steps);
    let (_dir_b, root_b) = fresh_repo(scenario.init, &steps);
    let mut repo_a = zanshin_jj::Repo::open(&root_a).expect("Zanshin opens the CLI-built repo");

    let before_a = capture(&root_a, None);
    let before_b = capture(&root_b, None);
    if let Some(drift) = compare(&before_a.aspects, &before_b.aspects).first() {
        panic!("setup differs in {}: {} | {}", drift.aspect, drift.zanshin, drift.cli);
    }
    for (path, text) in scenario.files {
        std::fs::write(root_a.join(path), text).expect("write into repo A");
        std::fs::write(root_b.join(path), text).expect("write into repo B");
    }

    let zanshin = (scenario.zanshin)(&mut repo_a, &root_a, &before_a);
    let argv = (scenario.cli)(&before_b);
    let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
    let cli = cli_outcome(&jj(&root_b, &argv));

    let after_a = capture(&root_a, Some(&before_a));
    let after_b = capture(&root_b, Some(&before_b));
    let mut aspects_a = after_a.aspects.clone();
    let mut aspects_b = after_b.aspects.clone();
    aspects_a.extend(outcome_aspects(&zanshin));
    aspects_b.extend(outcome_aspects(&cli));
    if let Some(extra) = scenario.extra {
        aspects_a.insert("extra", extra(&root_a));
        aspects_b.insert("extra", extra(&root_b));
    }
    // A name derived from a change id (`jj git push -c`'s `push-<change id>`, Story 9.20) differs
    // between the sides only because change ids are random: compare it by the commit's label.
    let aspects_a = aspects_a
        .into_iter()
        .map(|(k, v)| (k, after_a.normalize_ids(&v)))
        .collect();
    let aspects_b = aspects_b
        .into_iter()
        .map(|(k, v)| (k, after_b.normalize_ids(&v)))
        .collect();
    compare(&aspects_a, &aspects_b)
}

/// A creation (`jj git init` / `jj git clone`, Story 9.20; the conversions, Story 9.57) through
/// Zanshin in one temp dir against the CLI in another, both prepared alike — under the
/// scenario's user config when it has one. A side whose call created no workspace contributes
/// only its outcome and its files — there is no repo to capture.
fn run_creation(scenario: &CreationScenario) -> Vec<Divergence> {
    let (dir_a, dir_b) = (empty_dir(), empty_dir());
    // WHY canonical: macOS's temp dir is a symlink (`/var` → `/private/var`); both sides must
    // name the same kind of path, and the CLI resolves its cwd.
    let (dir_a, dir_b) = (
        (dir_a.path().canonicalize().expect("temp dir A"), dir_a),
        (dir_b.path().canonicalize().expect("temp dir B"), dir_b),
    );
    prepare(&dir_a.0, scenario.prep);
    prepare(&dir_b.0, scenario.prep);
    let config_dir = empty_dir();
    if let Some(text) = scenario.user_config {
        set_user_config(&config_dir.path().join("user.toml"), text);
    }
    let zanshin = init_outcome(&(scenario.zanshin)(&dir_a.0));
    let cli = cli_outcome(&jj(&dir_b.0, scenario.cli));
    if scenario.user_config.is_some() {
        // The read-back runs under the pinned empty config, as every other scenario's.
        set_jj_config(std::ffi::OsStr::new(""));
    }
    let mut aspects_a = created(&dir_a.0, scenario.target);
    let mut aspects_b = created(&dir_b.0, scenario.target);
    aspects_a.extend(outcome_aspects(&zanshin));
    aspects_b.extend(outcome_aspects(&cli));
    compare(&aspects_a, &aspects_b)
}

/// The created workspace's aspects plus the `extra` read-back, or only `extra` (its files, or
/// that the target is gone — a clone's clean-up removes a destination it created) when no
/// workspace was created.
fn created(dir: &std::path::Path, target: &str) -> std::collections::BTreeMap<&'static str, String> {
    let target = dir.join(target);
    if !target.exists() {
        return std::collections::BTreeMap::from([("extra", "no target".to_owned())]);
    }
    if !target.join(".jj").is_dir() {
        let files = crate::state::disk_files(&target);
        return std::collections::BTreeMap::from([("extra", format!("no workspace; files={files}"))]);
    }
    let mut aspects = capture(&target, None).aspects;
    aspects.insert("extra", creation_read_back(dir, &target));
    aspects
}

/// Writes `text` to `path` and points `JJ_CONFIG` at it, for both sides (the driver passes the
/// process's `JJ_CONFIG` through).
///
/// # Panics
/// Panics outside a process of its own (`main.rs`'s `own_process` list): changing the
/// environment of the shared process would race every other scenario.
fn set_user_config(path: &std::path::Path, text: &str) {
    assert!(
        std::env::var_os(test_helpers::OWN_PROCESS_VAR).is_some(),
        "a scenario with a user config runs in a process of its own"
    );
    std::fs::write(path, text).expect("write the user config");
    set_jj_config(path.as_os_str());
}

fn set_jj_config(value: &std::ffi::OsStr) {
    // SAFETY: only in a process of its own (`set_user_config` asserts it), which runs this one
    // scenario on one thread at a time — nothing else reads the environment concurrently.
    unsafe { std::env::set_var("JJ_CONFIG", value) };
}

fn empty_dir() -> tempfile::TempDir {
    tempfile::Builder::new()
        .prefix("zanshin-parity-")
        .tempdir()
        .expect("temp dir")
}

/// Runs `f` on a thread with a 16 MiB stack: a debug build's jj-lib call trees need more than
/// libtest's default 2 MiB.
fn on_big_stack<T: Send>(f: impl FnOnce() -> T + Send) -> T {
    std::thread::scope(|scope| {
        std::thread::Builder::new()
            .stack_size(16 * 1024 * 1024)
            .spawn_scoped(scope, f)
            .expect("spawn the scenario thread")
            .join()
            .unwrap_or_else(|panic| std::panic::resume_unwind(panic))
    })
}
