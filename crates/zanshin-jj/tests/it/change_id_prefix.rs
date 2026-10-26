// SPDX-License-Identifier: MIT

//! Leftover run C after the story loop 9.25–9.46 — the change-id currency (every mutation verb,
//! the file reads, `select_tree`, `resolve_list`, `interdiff`, the drop/change-actions rows and
//! `get_change`) resolves a change-id PREFIX the way the CLI's `ChangePrefixResolver` does
//! (`lib/src/revset.rs:2881-2948` @ v0.46.0): through the call's `revsets.short-prefixes`
//! context, odd lengths too, an ambiguous prefix refused with jj-lib's own text (never jj-lib's
//! `resolve_change_id` panic), a divergent change refused as `DivergentChangeId` with the CLI's
//! hints.

use std::collections::BTreeMap;
use std::fs;
use std::ops::ControlFlow;

use test_helpers::{add_commit_off_root, add_divergent_twin, extract_fixture, FixtureHandle};
use zanshin_jj::{
    resolve_revset, ActionStatus, ChangeError, ChangeId, CommitId, CommitViewError, FileError, MutateError, Repo,
    ResolveListOptions, RevisionRef,
};

/// The medium fixture with `config` as its repo config.
fn medium(config: &str) -> (FixtureHandle, Repo) {
    test_helpers::pin_test_env();
    let fixture = extract_fixture("medium-1k-commits").unwrap();
    fs::write(fixture.path.join(".jj").join("repo").join("config.toml"), config).unwrap();
    let repo = Repo::open(&fixture.path).unwrap();
    (fixture, repo)
}

const NO_SHORT: &str = "[revsets]\nshort-prefixes = \"\"\n";
const SHORT_TIP: &str = "[revsets]\nshort-prefixes = \"tip\"\n";
const BROKEN_SHORT: &str = "[revsets]\nshort-prefixes = \"missing\"\n";

/// Every visible change id of the repo.
fn all_changes(repo: &mut Repo) -> Vec<ChangeId> {
    let mut ids = Vec::new();
    _ = repo
        .eval_revset("all()", |change| {
            ids.push(change.id);
            ControlFlow::Continue(())
        })
        .unwrap();
    ids
}

/// The visible changes by their `len`-char prefix.
fn by_prefix(repo: &mut Repo, len: usize) -> BTreeMap<String, Vec<ChangeId>> {
    let mut by_prefix: BTreeMap<String, Vec<ChangeId>> = BTreeMap::new();
    for id in all_changes(repo) {
        by_prefix.entry(id.0[..len].to_owned()).or_default().push(id);
    }
    by_prefix
}

/// A `len`-char change-id prefix two visible changes share (the 1k-commit fixture has more changes
/// than there are 2-char prefixes, so one exists by pigeonhole).
fn shared_prefix(repo: &mut Repo, len: usize) -> String {
    by_prefix(repo, len)
        .into_iter()
        .find(|(_, ids)| ids.len() > 1)
        .map(|(p, _)| p)
        .expect("a shared prefix")
}

fn head_op(repo: &mut Repo) -> zanshin_jj::OperationId {
    repo.op_log(Some(1)).unwrap().remove(0).id
}

fn describe_of(repo: &mut Repo, id: &ChangeId) -> String {
    repo.get_change(id).unwrap().description
}

/// The panic: a 2-char (even-length) prefix two changes share decodes to a `ChangeId` that
/// jj-lib's `resolve_change_id` treats as complete, and its `AmbiguousMatch` arm panics
/// (`jj-lib 0.46.0 src/repo.rs:140-150`). The CLI refuses it as `AmbiguousChangeIdPrefix`.
#[test]
fn an_even_length_ambiguous_prefix_is_refused_not_a_panic() {
    let (_fixture, mut repo) = medium(NO_SHORT);
    let prefix = shared_prefix(&mut repo, 2);
    let before = head_op(&mut repo);
    let expected = format!("Change ID prefix `{prefix}` is ambiguous");

    let err = repo.describe(ChangeId(prefix.clone()), "x").unwrap_err();
    assert!(
        matches!(&err, MutateError::RevsetResolutionError { reason, .. } if *reason == expected),
        "{err:?}"
    );
    let err = repo.get_change(&ChangeId(prefix)).unwrap_err();
    assert!(
        matches!(&err, ChangeError::RevsetResolutionError { reason, .. } if *reason == expected),
        "{err:?}"
    );
    assert_eq!(head_op(&mut repo), before, "nothing written");
}

/// An odd-length prefix ambiguous repo-wide but unique within `revsets.short-prefixes` resolves
/// to the in-set change on every surface of the currency.
#[test]
fn an_odd_prefix_resolves_within_the_short_prefixes() {
    let (_fixture, mut repo) = medium(SHORT_TIP);
    let tip = resolve_revset(&repo, "tip").unwrap().remove(0);
    let prefix = ChangeId(tip.0[..1].to_owned());
    assert!(
        by_prefix(&mut repo, 1)[&prefix.0].len() > 1,
        "the prefix is ambiguous in the full index"
    );

    assert_eq!(repo.get_change(&prefix).unwrap().id, tip, "get_change");
    repo.file_list(Some(prefix.clone()), &[]).expect("a file read");
    let listed = repo.resolve_list(&ResolveListOptions {
        revision: Some(prefix.clone()),
        paths: Vec::new(),
    });
    assert!(
        matches!(listed, Err(MutateError::NoConflicts { .. })),
        "resolve_list: {listed:?}"
    );
    let to = RevisionRef::ChangeId(tip.clone());
    repo.interdiff(Some(RevisionRef::ChangeId(prefix.clone())), Some(to), &[])
        .expect("interdiff");
    let actions = repo.change_actions(&prefix).unwrap();
    assert_eq!(
        actions.describe.status,
        ActionStatus::Available,
        "{:?}",
        actions.describe
    );
    repo.describe(prefix, "described by prefix").expect("describe");
    assert_eq!(describe_of(&mut repo, &tip), "described by prefix");
}

/// With `revsets.short-prefixes = ""` an odd-length prefix unique repo-wide resolves (the old
/// `try_from_reverse_hex` refused every odd length).
#[test]
fn a_unique_odd_prefix_resolves_without_short_prefixes() {
    let (_fixture, mut repo) = medium(NO_SHORT);
    let (prefix, target) = by_prefix(&mut repo, 3)
        .into_iter()
        .find_map(|(p, ids)| (ids.len() == 1).then(|| (ChangeId(p), ids[0].clone())))
        .expect("a unique 3-char prefix");

    assert_eq!(repo.get_change(&prefix).unwrap().id, target);
    repo.file_list(Some(prefix.clone()), &[]).expect("a file read");
    repo.describe(prefix, "odd").expect("describe");
    assert_eq!(describe_of(&mut repo, &target), "odd");
}

/// A short-prefixes set that does not resolve: a malformed id is not found BEFORE the set is
/// loaded (the CLI validates the reverse hex first), a valid id is refused with jj-lib's load
/// error and its chain, and an omitted revision (`@`) never loads it.
#[test]
fn a_broken_short_prefixes_refuses_only_a_valid_id() {
    let (_fixture, mut repo) = medium(BROKEN_SHORT);
    let tip = resolve_revset(&repo, "tip").unwrap().remove(0);

    for malformed in ["xyz!", ""] {
        let id = ChangeId(malformed.to_owned());
        let err = repo.describe(id.clone(), "x").unwrap_err();
        assert!(
            matches!(&err, MutateError::ChangeNotFound { id: echoed } if echoed == malformed),
            "{err:?}"
        );
        let err = repo.file_list(Some(id.clone()), &[]).unwrap_err();
        assert!(matches!(&err, FileError::ChangeNotFound { .. }), "{err:?}");
        let err = repo.get_change(&id).unwrap_err();
        assert!(matches!(&err, ChangeError::NotFound { .. }), "{err:?}");
    }

    let failed = "Failed to resolve short-prefixes disambiguation revset";
    let err = repo.describe(tip.clone(), "x").unwrap_err();
    assert!(
        matches!(&err, MutateError::RevsetResolutionError { reason, hints }
            if reason.starts_with(failed) && reason.contains("missing") && hints.is_empty()),
        "{err:?}"
    );
    let err = repo.file_list(Some(tip.clone()), &[]).unwrap_err();
    assert!(
        matches!(&err, FileError::RevsetResolutionError { reason, .. } if reason.starts_with(failed)),
        "{err:?}"
    );
    let err = repo.get_change(&tip).unwrap_err();
    assert!(
        matches!(&err, ChangeError::RevsetResolutionError { reason, .. } if reason.starts_with(failed)),
        "{err:?}"
    );

    repo.file_list(None, &[]).expect("`@` loads no short-prefixes set");

    // The commit arm validates its hex before loading the set too (the CLI's `CommitPrefixResolver`).
    let from = RevisionRef::CommitId(CommitId("xyz!".to_owned()));
    let err = repo.interdiff(Some(from), None, &[]).unwrap_err();
    assert!(matches!(&err, CommitViewError::InvalidInput { .. }), "{err:?}");
}

/// The DEFAULT `revsets.short-prefixes` is `revsets.log`, which names `immutable_heads()`: with
/// that alias unresolvable, a change-id argument refuses loading the set — before the immutable
/// set's own `Config` refusal. The stock CLI at v0.46.0 answers `jj describe <change id> -m x`
/// with exactly "Failed to resolve short-prefixes disambiguation revset" caused by the alias's
/// symbol.
#[test]
fn an_unresolvable_immutable_heads_alias_refuses_a_change_id_through_the_default_short_prefixes() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    fs::write(
        fx.path.join(".jj").join("repo").join("config.toml"),
        "[revset-aliases]\n'immutable_heads()' = 'nonexistent_symbol_xyz'\n",
    )
    .unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let at = resolve_revset(&repo, "@").unwrap().remove(0);

    let err = repo.describe(at, "x").unwrap_err();
    assert!(
        matches!(&err, MutateError::RevsetResolutionError { reason, .. } if reason
            == "Failed to resolve short-prefixes disambiguation revset: Revision `nonexistent_symbol_xyz` doesn't exist"),
        "{err:?}"
    );
}

/// A divergent change is the CLI's `DivergentChangeId` refusal with its three hints on every
/// surface that takes a single revision — the file reads, `resolve_list`, the card rows — while
/// `get_change` keeps Decision D4 (first visible commit, flagged divergent).
#[test]
fn a_divergent_change_is_refused_with_the_cli_hints() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let original = add_commit_off_root(&fx.path, "original");
    let mut repo = Repo::open(&fx.path).unwrap();
    let id = resolve_revset(&repo, &original).unwrap().remove(0);
    _ = add_divergent_twin(&fx.path, &original, "twin");
    let before = head_op(&mut repo);

    let reason = format!("Change ID `{}` is divergent", id.0);
    let divergent = |actual_reason: &str, hints: &[String]| {
        actual_reason == reason
            && hints.len() == 3
            && hints[0].starts_with(&format!("Use change offset to select single revision: {}/", id.0))
            && hints[1] == format!("Use `change_id({})` to select all revisions", id.0)
            && hints[2] == "To abandon unneeded revisions, run `jj abandon <commit_id>`"
    };

    let err = repo.describe(id.clone(), "x").unwrap_err();
    assert!(
        matches!(&err, MutateError::RevsetResolutionError { reason, hints } if divergent(reason, hints)),
        "{err:?}"
    );
    let err = repo.file_list(Some(id.clone()), &[]).unwrap_err();
    assert!(
        matches!(&err, FileError::RevsetResolutionError { reason, hints } if divergent(reason, hints)),
        "{err:?}"
    );
    let err = repo
        .resolve_list(&ResolveListOptions {
            revision: Some(id.clone()),
            paths: Vec::new(),
        })
        .unwrap_err();
    assert!(
        matches!(&err, MutateError::RevsetResolutionError { reason, hints } if divergent(reason, hints)),
        "{err:?}"
    );
    let actions = repo.change_actions(&id).unwrap();
    assert_eq!(actions.describe.status, ActionStatus::Refused);
    assert!(
        matches!(&actions.describe.refusal, Some(MutateError::RevsetResolutionError { reason, hints })
            if divergent(reason, hints)),
        "{:?}",
        actions.describe
    );
    let change = repo.get_change(&id).expect("D4: a divergent change is no refusal here");
    assert!(change.divergent);
    assert_eq!(head_op(&mut repo), before, "nothing written");
}
