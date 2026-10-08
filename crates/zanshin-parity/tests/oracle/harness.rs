// SPDX-License-Identifier: MIT

//! Runs one scenario end to end: two identical repos, the operation on each side, the diff.

use crate::compare::cli_outcome;
use crate::compare::compare;
use crate::compare::init_outcome;
use crate::compare::outcome_aspects;
use crate::compare::Divergence;
use crate::driver::fresh_repo;
use crate::driver::jj;
use crate::scenarios::scenarios;
use crate::scenarios::Scenario;
use crate::scenarios::BASE;
use crate::scenarios::INIT_SCENARIOS;
use crate::state::capture;

/// The divergences of the scenario `id` (a table scenario or an init scenario).
///
/// # Panics
/// Panics on an unknown id, and when the two CLI-built repos already differ before the
/// operation ("setup differs") — the scenario would then blame Zanshin for fixture drift.
pub fn run(id: &str) -> Vec<Divergence> {
    on_big_stack(|| {
        if let Some((_, argv)) = INIT_SCENARIOS.iter().find(|(init_id, _)| *init_id == id) {
            return run_init(argv);
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

    let mut aspects_a = capture(&root_a, Some(&before_a)).aspects;
    let mut aspects_b = capture(&root_b, Some(&before_b)).aspects;
    aspects_a.extend(outcome_aspects(&zanshin));
    aspects_b.extend(outcome_aspects(&cli));
    if let Some(extra) = scenario.extra {
        aspects_a.insert("extra", extra(&root_a));
        aspects_b.insert("extra", extra(&root_b));
    }
    compare(&aspects_a, &aspects_b)
}

/// `Repo::init` (Git backend) in one empty directory against `jj <argv>` in another.
fn run_init(argv: &[&str]) -> Vec<Divergence> {
    let (dir_a, dir_b) = (empty_dir(), empty_dir());
    let zanshin = init_outcome(&zanshin_jj::Repo::init(dir_a.path(), Some(zanshin_jj::Backend::Git)));
    let cli = cli_outcome(&jj(dir_b.path(), argv));
    let mut aspects_a = capture(dir_a.path(), None).aspects;
    let mut aspects_b = capture(dir_b.path(), None).aspects;
    aspects_a.extend(outcome_aspects(&zanshin));
    aspects_b.extend(outcome_aspects(&cli));
    compare(&aspects_a, &aspects_b)
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
