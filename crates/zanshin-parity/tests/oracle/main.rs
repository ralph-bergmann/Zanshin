// SPDX-License-Identifier: MIT

//! The differential parity oracle (Story 9.47): the same operation through `zanshin-jj`
//! (repo A) and through the stock jj CLI at the pin (repo B), compared by meaning.
//!
//! Every scenario is its own test. It fails when the two repos differ in an aspect the ledger
//! (`ledger.rs`) does not list for it, or when a ledgered divergence no longer happens.

use std::collections::BTreeMap;
use std::collections::BTreeSet;
use std::ffi::OsStr;
use std::path::Path;

mod compare;
mod driver;
mod harness;
mod ledger;
mod scenarios;
mod state;

/// One `#[test]` per scenario id, so they run in parallel and fail individually. The same id
/// list also yields `SCENARIO_IDS`, so a table entry without a test cannot slip through.
macro_rules! parity {
    ($($id:ident),* $(,)?) => {
        const SCENARIO_IDS: &[&str] = &[$(stringify!($id)),*];
        $(
            #[test]
            fn $id() {
                test_helpers::pin_test_env();
                let found = harness::run(stringify!($id));
                ledger::assert_matches_ledger(stringify!($id), &found);
            }
        )*
    };
}

parity!(
    describe_gui_text,
    describe_cli_text,
    new_on_wc,
    new_merge,
    new_conflicting_merge,
    abandon_middle,
    abandon_wc,
    edit_parent,
    undo_after_describe,
    bookmark_create,
    bookmark_create_existing,
    bookmark_delete,
    config_set_repo,
    config_set_with_dirty_wc,
    snapshot_modified_file,
    snapshot_then_describe,
    describe_immutable,
    describe_root,
    describe_no_change,
    describe_commit_trailers,
    restore_from,
    restore_no_args,
    absorb,
    undo_cross_workspace,
    init_colocated,
    init_no_colocate,
);

/// Every scenario id the table and the init list define.
fn defined_ids() -> BTreeSet<&'static str> {
    scenarios::scenarios()
        .iter()
        .map(|scenario| scenario.id)
        .chain(scenarios::INIT_SCENARIOS.iter().map(|(id, _)| *id))
        .collect()
}

#[test]
fn every_scenario_has_a_test() {
    assert_eq!(SCENARIO_IDS.iter().copied().collect::<BTreeSet<_>>(), defined_ids());
    assert_eq!(SCENARIO_IDS.len(), 26);
}

#[test]
fn ledger_names_only_known_scenarios_and_aspects() {
    let ids = defined_ids();
    let aspects: BTreeSet<&str> = state::STATE_ASPECTS
        .iter()
        .chain(compare::OUTCOME_ASPECTS)
        .copied()
        .collect();
    for expected in ledger::LEDGER {
        assert!(
            ids.contains(expected.scenario),
            "ledger names unknown scenario {}",
            expected.scenario
        );
        assert!(
            aspects.contains(expected.aspect),
            "ledger names unknown aspect {}",
            expected.aspect
        );
    }
}

#[test]
fn identical_cli_built_repos_capture_equal() {
    test_helpers::pin_test_env();
    let (_a, a) = driver::fresh_repo(&["git", "init"], &[scenarios::BASE]);
    let (_b, b) = driver::fresh_repo(&["git", "init"], &[scenarios::BASE]);
    let found = compare::compare(&state::capture(&a, None).aspects, &state::capture(&b, None).aspects);
    assert!(
        found.is_empty(),
        "{:?}",
        found.iter().map(|d| &d.aspect).collect::<Vec<_>>()
    );
}

#[test]
fn a_description_difference_shows_in_descriptions_without_ids() {
    test_helpers::pin_test_env();
    let (_a, a) = driver::fresh_repo(&["git", "init"], &[scenarios::BASE]);
    let (_b, b) = driver::fresh_repo(&["git", "init"], &[scenarios::BASE]);
    let before_a = state::capture(&a, None);
    let before_b = state::capture(&b, None);
    driver::jj(&a, &["describe", "-m", "C one"]).ok();
    driver::jj(&b, &["describe", "-m", "C two"]).ok();
    let found = compare::compare(
        &state::capture(&a, Some(&before_a)).aspects,
        &state::capture(&b, Some(&before_b)).aspects,
    );
    // The label is the description's first line, so other aspects differ by label text too;
    // what matters is that `descriptions` is among them and no aspect leaks a commit id.
    assert!(found.iter().any(|d| d.aspect == "descriptions"));
    let has_commit_id = |s: &str| s.split(|c: char| !c.is_ascii_hexdigit()).any(|t| t.len() == 40);
    assert!(found
        .iter()
        .all(|d| !has_commit_id(&d.zanshin) && !has_commit_id(&d.cli)));
}

#[test]
fn every_captured_aspect_is_listed() {
    test_helpers::pin_test_env();
    let (_a, a) = driver::fresh_repo(&["git", "init"], &[scenarios::BASE]);
    let keys: BTreeSet<_> = state::capture(&a, None).aspects.into_keys().collect();
    assert_eq!(keys, state::STATE_ASPECTS.iter().copied().collect());
}

#[test]
fn pinned_jj_builds_a_repo_zanshin_opens() {
    test_helpers::pin_test_env();
    let (_dir, root) = driver::fresh_repo(&["git", "init"], &[]);
    zanshin_jj::Repo::open(&root).expect("Zanshin opens a repo the pinned jj created");
}

#[test]
fn pinned_jj_keeps_its_secure_config_in_the_test_xdg_dir() {
    test_helpers::pin_test_env();
    // WHY the config write: a plain `jj git init` without a remote writes no repo config, so it
    // creates no secure config entry at all; the first `config set --repo` does.
    let (_dir, root) = driver::fresh_repo(
        &["git", "init"],
        &[&[driver::Step::Jj(&[
            "config",
            "set",
            "--repo",
            "ui.conflict-marker-style",
            "git",
        ])]],
    );
    let id = std::fs::read_to_string(root.join(".jj/repo/config-id")).expect("config-id");
    let xdg = std::env::var_os("XDG_CONFIG_HOME").expect("pinned by pin_test_env");
    assert!(
        Path::new(&xdg).join("jj/repos").join(id.trim()).is_dir(),
        "the CLI's secure per-repo config must land in the test's XDG_CONFIG_HOME"
    );
}

#[test]
fn pinned_jj_command_carries_the_hermetic_env() {
    test_helpers::pin_test_env();
    let command = driver::command(Path::new("/"), &["log"]);
    let envs: BTreeMap<_, _> = command.get_envs().collect();
    let get = |name: &str| envs.get(OsStr::new(name)).copied().flatten();
    assert_eq!(get("LLVM_PROFILE_FILE"), Some(OsStr::new("/dev/null")));
    assert_eq!(get("XDG_CONFIG_HOME"), std::env::var_os("XDG_CONFIG_HOME").as_deref());
    for (name, value) in test_helpers::TEST_ENV {
        assert_eq!(get(name), Some(OsStr::new(value)), "{name}");
    }
}
