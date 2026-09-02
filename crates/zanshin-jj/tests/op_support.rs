// SPDX-License-Identifier: MIT

//! Story 9.1 — the immutable-commit rewritability guard, observed through the three
//! shipped rewriting verbs (`describe`, `edit`, `abandon`).
//!
//! `op_support` itself is `pub(crate)`, so its unwired helpers are covered by that module's
//! own inline tests; what an integration test CAN observe — and what CLI parity is actually
//! about (NFR-R-2) — is the public behaviour: which calls refuse, with which error, and
//! whether an operation was written.
//!
//! **Fixture caveat.** `tiny-3-commits` has no remote bookmarks and no tags, so `trunk()`
//! degenerates to `root()` and the builtin immutable set is exactly `::root()`. A non-root
//! immutable commit therefore has to be constructed in-test; `tags()` is a term of
//! `builtin_immutable_heads()`, so `test_helpers::set_tag` is the lever. The fixtures are
//! never regenerated (that would shift every revset oracle in the suite).

use std::collections::HashMap;
use std::path::Path;
use std::sync::LazyLock;
use std::{env, fs};

use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::Repo as _;
use jj_lib::settings::UserSettings;
use jj_lib::workspace::Workspace;
use test_helpers::{extract_fixture, set_tag};
use zanshin_jj::{ChangeId, MutateError, Repo};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| unsafe {
    env::set_var("JJ_CONFIG", "");
    env::set_var("GIT_CONFIG_GLOBAL", "");
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

fn make_test_settings() -> UserSettings {
    let mut config = StackedConfig::with_defaults();
    config.add_layer(
        ConfigLayer::parse(
            ConfigSource::User,
            r#"
                [user]
                name = "Zanshin"
                email = "zanshin@localhost"
                [operation]
                username = "zanshin"
                hostname = "localhost"
            "#,
        )
        .expect("valid config literal"),
    );
    UserSettings::from_config(config).expect("valid settings")
}

/// `tiny-3-commits`' `Commit 1 -> Commit 2 -> Commit 3` chain, discovered by description
/// (same approach as `tests/mutate.rs`, so a fixture regen cannot silently break this).
struct Layout {
    commit1_change_id: String,
    commit2_change_id: String,
    commit2_commit_hex: String,
    commit3_change_id: String,
    commit3_commit_hex: String,
    root_change_id: String,
    root_commit_hex: String,
}

fn oracle_layout(workspace_root: &Path) -> Layout {
    let settings = make_test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("oracle load_at_head");
    let store = repo.store();

    let mut by_desc: HashMap<String, (String, String)> = HashMap::new();
    for head in repo.view().heads() {
        let mut cur = store.get_commit(head).unwrap();
        loop {
            by_desc.insert(
                cur.description().to_owned(),
                (cur.change_id().reverse_hex(), cur.id().hex()),
            );
            let Some(parent_id) = cur.parent_ids().first() else {
                break;
            };
            if parent_id == store.root_commit_id() {
                break;
            }
            cur = store.get_commit(parent_id).unwrap();
        }
    }
    let (commit1_change_id, _) = by_desc.get("Commit 1").expect("fixture has Commit 1").clone();
    let (commit2_change_id, commit2_commit_hex) = by_desc.get("Commit 2").expect("fixture has Commit 2").clone();
    let (commit3_change_id, commit3_commit_hex) = by_desc.get("Commit 3").expect("fixture has Commit 3").clone();

    Layout {
        commit1_change_id,
        commit2_change_id,
        commit2_commit_hex,
        commit3_change_id,
        commit3_commit_hex,
        root_change_id: store.root_commit().change_id().reverse_hex(),
        root_commit_hex: store.root_commit_id().hex(),
    }
}

/// Writes `.jj/repo/config.toml` — the repo config layer of an extracted fixture.
fn write_repo_config(workspace_root: &Path, toml: &str) {
    fs::write(workspace_root.join(".jj").join("repo").join("config.toml"), toml).unwrap();
}

/// The head operation's id, so a test can assert that a refusal wrote nothing.
fn head_op_id(repo: &Repo) -> String {
    repo.op_log(Some(1)).unwrap()[0].id.0.clone()
}

fn assert_immutable(err: &MutateError, expected_commit_hex: &str) {
    assert!(
        matches!(err, MutateError::Immutable { commit_id } if commit_id == expected_commit_hex),
        "expected Immutable({expected_commit_hex}), got {err:?}"
    );
}

// ── The guard refuses ─────────────────────────────────────────────────────────────

#[test]
fn describe_on_a_tagged_commit_is_refused_and_writes_no_operation() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    set_tag(&fx.path, "v1", &[&layout.commit3_commit_hex]);

    let mut repo = Repo::open(&fx.path).unwrap();
    let before_op = head_op_id(&repo);

    let err = repo
        .describe(ChangeId(layout.commit3_change_id.clone()), "nope")
        .expect_err("a tagged commit is immutable");
    assert_immutable(&err, &layout.commit3_commit_hex);

    assert_eq!(before_op, head_op_id(&repo), "a refusal must not commit an operation");
    let change = repo.get_change(&ChangeId(layout.commit3_change_id)).unwrap();
    assert_eq!(change.description, "Commit 3", "the description must be untouched");
}

#[test]
fn edit_on_a_tagged_commit_is_refused_and_writes_no_operation() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    set_tag(&fx.path, "v1", &[&layout.commit3_commit_hex]);

    let mut repo = Repo::open(&fx.path).unwrap();
    let before_op = head_op_id(&repo);

    let err = repo
        .edit(ChangeId(layout.commit3_change_id))
        .expect_err("a tagged commit is immutable");
    assert_immutable(&err, &layout.commit3_commit_hex);
    assert_eq!(before_op, head_op_id(&repo), "a refusal must not commit an operation");
}

#[test]
fn abandon_on_a_tagged_commit_is_refused_and_writes_no_operation() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    set_tag(&fx.path, "v1", &[&layout.commit3_commit_hex]);

    let mut repo = Repo::open(&fx.path).unwrap();
    let before_op = head_op_id(&repo);

    let err = repo
        .abandon(&[ChangeId(layout.commit3_change_id.clone())])
        .expect_err("a tagged commit is immutable");
    assert_immutable(&err, &layout.commit3_commit_hex);

    assert_eq!(before_op, head_op_id(&repo), "a refusal must not commit an operation");
    repo.get_change(&ChangeId(layout.commit3_change_id))
        .expect("the commit must still be visible");
}

#[test]
fn the_guard_is_ancestor_closed_so_a_tagged_head_protects_its_ancestors() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    // Tagging the chain head makes `::(immutable_heads() | root())` cover the whole chain.
    set_tag(&fx.path, "v1", &[&layout.commit3_commit_hex]);

    let mut repo = Repo::open(&fx.path).unwrap();
    let err = repo
        .describe(ChangeId(layout.commit2_change_id), "nope")
        .expect_err("Commit 2 is an ancestor of the tagged Commit 3");
    assert_immutable(&err, &layout.commit2_commit_hex);
}

#[test]
fn abandon_names_exactly_one_immutable_target_when_several_are() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    set_tag(&fx.path, "v1", &[&layout.commit3_commit_hex]);

    let mut repo = Repo::open(&fx.path).unwrap();
    let err = repo
        .abandon(&[ChangeId(layout.commit2_change_id), ChangeId(layout.commit3_change_id)])
        .expect_err("both targets are immutable");
    // The CLI takes `try_next` over the intersection, so EXACTLY ONE offender is named.
    // WHY this asserts membership rather than a specific commit: which one arrives first is
    // jj-lib's revset stream order, which is not a promised contract — pinning `Commit 3`
    // here would turn an upstream index change into a red test with no behaviour regression.
    // The contract is "one of the immutable targets, and only one".
    let MutateError::Immutable { commit_id } = &err else {
        panic!("expected Immutable, got {err:?}");
    };
    assert!(
        [&layout.commit2_commit_hex, &layout.commit3_commit_hex].contains(&commit_id),
        "named offender {commit_id} is not one of the two immutable targets"
    );
}

#[test]
fn edit_root_commit_returns_immutable() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);

    let mut repo = Repo::open(&fx.path).unwrap();
    let before_op = head_op_id(&repo);

    // WHY this test exists: Story 9.1 deliberately CHANGED this shipped error code.
    // `describe`/`abandon` guard the root commit explicitly (pre-empting jj-lib's internal
    // `assert!`) and keep refusing it as `InvalidInput` — see `tests/mutate.rs`'s
    // `describe_root_commit_returns_invalid_input_not_a_panic` and its `abandon` twin.
    // `edit` needs no such guard (jj-lib is graceful about editing root), so the new
    // immutability guard now catches root first and reports `Immutable` — which is what
    // the jj CLI reports for `jj edit root()` (NFR-R-2).
    let err = repo
        .edit(ChangeId(layout.root_change_id))
        .expect_err("the root commit is immutable");
    assert_immutable(&err, &layout.root_commit_hex);
    assert_eq!(before_op, head_op_id(&repo), "a refusal must not commit an operation");
}

// ── A config fault is a config error, not an unclassified backend failure ─────────

#[test]
fn a_malformed_repo_config_makes_describe_fail_with_config_not_backend() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    // The rewriting verbs read the effective config to build the guard's set, so a broken
    // config now reaches them — as the same fault the READ side reports (`RevsetError::
    // Config` / `jj.config_error`), never the unclassified backend bucket, and never a
    // silent fall-back to the builtin immutable set.
    write_repo_config(&fx.path, "not = = toml");

    let mut repo = Repo::open(&fx.path).unwrap();
    let before_op = head_op_id(&repo);
    let err = repo
        .describe(ChangeId(layout.commit1_change_id), "nope")
        .expect_err("a malformed config must not be silently ignored");

    let MutateError::Config { reason } = &err else {
        panic!("expected Config, got {err:?}");
    };
    assert!(
        reason.contains("config.toml"),
        "the reason must name the file: {reason}"
    );
    assert_eq!(before_op, head_op_id(&repo), "a refusal must not commit an operation");
}

#[test]
fn an_unresolvable_immutable_heads_alias_is_a_config_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    // Parses fine, but names a bookmark that does not exist — the CLI reports this through
    // the same "Invalid `revset-aliases.immutable_heads()`" path as a parse failure
    // (`cli_util.rs:1139`), because the ALIAS is what is wrong, not the caller's argument.
    write_repo_config(&fx.path, "[revset-aliases]\n'immutable_heads()' = 'no-such-bookmark'\n");

    let mut repo = Repo::open(&fx.path).unwrap();
    let err = repo
        .describe(ChangeId(layout.commit1_change_id), "nope")
        .expect_err("an unresolvable alias must not be silently ignored");
    assert!(matches!(err, MutateError::Config { .. }), "unexpected error: {err:?}");
}

#[test]
fn an_unparseable_immutable_heads_alias_is_a_config_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    // The PARSE half of the same contract (the sibling above is the RESOLVE half): a
    // syntactically broken alias travels a different code path, and an implementation
    // could easily classify only one of the two.
    write_repo_config(&fx.path, "[revset-aliases]\n'immutable_heads()' = 'bogus_function('\n");

    let mut repo = Repo::open(&fx.path).unwrap();
    let err = repo
        .describe(ChangeId(layout.commit3_change_id), "nope")
        .expect_err("a guard that cannot determine what is protected must refuse");
    assert!(
        matches!(err, MutateError::Config { .. }),
        "expected Config, got {err:?}"
    );
}

// ── The guard lets mutable commits through ────────────────────────────────────────

#[test]
fn describe_outside_the_immutable_set_still_succeeds() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    // Tag `Commit 1`: the immutable set is `::Commit 1`, so its DESCENDANTS stay mutable.
    let commit1_hex = {
        let repo = Repo::open(&fx.path).unwrap();
        repo.get_change(&ChangeId(layout.commit1_change_id.clone()))
            .unwrap()
            .commit_id
            .0
    };
    set_tag(&fx.path, "v1", &[&commit1_hex]);

    let mut repo = Repo::open(&fx.path).unwrap();
    repo.describe(ChangeId(layout.commit3_change_id.clone()), "still mutable")
        .expect("a descendant of an immutable commit is mutable");

    let change = repo.get_change(&ChangeId(layout.commit3_change_id)).unwrap();
    assert_eq!(change.description, "still mutable");
}

#[test]
fn describe_in_an_untagged_repo_is_unaffected_by_the_guard() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);

    let mut repo = Repo::open(&fx.path).unwrap();
    repo.describe(ChangeId(layout.commit1_change_id.clone()), "New description")
        .expect("nothing is immutable but root in this fixture");

    let change = repo.get_change(&ChangeId(layout.commit1_change_id)).unwrap();
    assert_eq!(change.description, "New description");
}

// ── The guard reads the EFFECTIVE config, not a Rust constant ─────────────────────

#[test]
fn a_config_override_of_immutable_heads_decides_the_set() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);

    // No tag anywhere — under the BUILTIN aliases this repo's immutable set is `::root()`
    // and `Commit 2` is freely rewritable. The override REPLACES the builtin by
    // (name, arity), which is the whole point of Story 4.9's alias layering.
    write_repo_config(
        &fx.path,
        &format!(
            "[revset-aliases]\n'immutable_heads()' = '{}'\n",
            layout.commit2_commit_hex
        ),
    );

    let mut repo = Repo::open(&fx.path).unwrap();
    let err = repo
        .describe(ChangeId(layout.commit2_change_id), "nope")
        .expect_err("the override makes Commit 2 immutable");
    assert_immutable(&err, &layout.commit2_commit_hex);

    // And the override's descendants remain mutable — proof the set really is the
    // override's ancestry, not the builtin's.
    repo.describe(ChangeId(layout.commit3_change_id.clone()), "mutable")
        .expect("Commit 3 is outside `::Commit 2`");
}

#[test]
fn a_config_override_can_widen_the_immutable_set_to_everything() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let layout = oracle_layout(&fx.path);
    write_repo_config(&fx.path, "[revset-aliases]\n'immutable_heads()' = 'all()'\n");

    let mut repo = Repo::open(&fx.path).unwrap();
    let before_op = head_op_id(&repo);
    let err = repo
        .describe(ChangeId(layout.commit3_change_id), "nope")
        .expect_err("everything is immutable under this override");
    assert!(
        matches!(err, MutateError::Immutable { .. }),
        "unexpected error: {err:?}"
    );
    assert_eq!(before_op, head_op_id(&repo));
}
