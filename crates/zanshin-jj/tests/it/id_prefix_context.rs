// SPDX-License-Identifier: MIT

//! Story 9.25 closing run — every user revset resolves with the id-prefix context of the
//! effective `revsets.short-prefixes` (the CLI's `default_symbol_resolver`, `cli_util.rs:1905-1921`
//! @ v0.46.0), one witness per surface: the reads, the topology (its own `short_prefixes`) and the
//! verbs.
//!
//! The medium fixture's one-char change-id prefix `P` of bookmark `tip`'s commit is ambiguous in
//! the full index; within `short-prefixes = "tip"` it is unique.

use std::fs;
use std::ops::ControlFlow;

use test_helpers::{extract_fixture, FixtureHandle};
use zanshin_jj::{
    resolve_revset, BookmarkError, BookmarkListOptions, BookmarkMoveOptions, ChangeId, CommitViewError, MutateError,
    Repo, RevsetError, RevsetErrorKind, SparseInheritance, DEFAULT_GRAPH_PRIORITIZE,
};

struct Fx {
    fixture: FixtureHandle,
    repo: Repo,
    tip: ChangeId,
    prefix: String,
}

/// The medium fixture with `config` (`{P}` replaced by the prefix) as its repo config.
fn medium(config: &str) -> Fx {
    test_helpers::pin_test_env();
    let fixture = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fixture.path).unwrap();
    let tip = resolve_revset(&repo, "tip").unwrap().remove(0);
    let prefix = tip.0[..1].to_owned();
    fs::write(
        fixture.path.join(".jj").join("repo").join("config.toml"),
        config.replace("{P}", &prefix),
    )
    .unwrap();
    let repo = Repo::open(&fixture.path).unwrap();
    Fx {
        fixture,
        repo,
        tip,
        prefix,
    }
}

const SHORT_TIP: &str = "[revsets]\nshort-prefixes = \"tip\"\n";
/// An EMPTY `revsets.short-prefixes` disables disambiguation; an absent one falls back to
/// `revsets.log`, which would still disambiguate.
const NO_SHORT: &str = "[revsets]\nshort-prefixes = \"\"\n";

/// The call refused the ambiguous prefix.
fn refused_ambiguous<T: std::fmt::Debug>(result: &Result<T, MutateError>) -> bool {
    matches!(result, Err(MutateError::RevsetResolutionError { reason, .. }) if reason.contains("ambiguous"))
}

fn ambiguous(e: &RevsetError) -> bool {
    matches!(e, RevsetError::ResolutionError { detail, .. } if detail.kind == RevsetErrorKind::AmbiguousChangeIdPrefix)
}

fn eval(repo: &mut Repo, revset: &str) -> Result<Vec<ChangeId>, RevsetError> {
    let mut ids = Vec::new();
    _ = repo.eval_revset(revset, |change| {
        ids.push(change.id);
        ControlFlow::Continue(())
    })?;
    Ok(ids)
}

fn revisions(prefix: &str) -> BookmarkListOptions {
    BookmarkListOptions {
        revisions: vec![prefix.to_owned()],
        ..Default::default()
    }
}

#[test]
fn reads_without_short_prefixes_refuse_the_ambiguous_prefix() {
    let Fx {
        fixture: _fixture,
        mut repo,
        prefix,
        ..
    } = medium(NO_SHORT);
    let p = prefix.as_str();

    assert!(eval(&mut repo, p).is_err_and(|e| ambiguous(&e)), "eval_revset");
    assert!(resolve_revset(&repo, p).is_err_and(|e| ambiguous(&e)), "resolve_revset");
    let show = repo.show(Some(p), None).unwrap_err();
    assert!(
        matches!(&show, CommitViewError::RevsetResolutionError { reason, .. } if reason.contains("ambiguous")),
        "{show:?}"
    );
    let evolog = repo.evolog(Some(p), None).unwrap_err();
    assert!(
        matches!(&evolog, CommitViewError::RevsetResolutionError { reason, .. } if reason.contains("ambiguous")),
        "{evolog:?}"
    );
    let list = repo.list_bookmarks(&revisions(p)).unwrap_err();
    assert!(
        matches!(&list, BookmarkError::RevsetResolutionError { reason, .. } if reason.contains("ambiguous")),
        "{list:?}"
    );
}

#[test]
fn reads_resolve_the_prefix_within_the_effective_short_prefixes() {
    let Fx {
        fixture: _fixture,
        mut repo,
        tip,
        prefix,
    } = medium(SHORT_TIP);
    let p = prefix.as_str();

    let only_tip = std::slice::from_ref(&tip);
    assert_eq!(eval(&mut repo, p).unwrap(), only_tip, "eval_revset");
    assert_eq!(resolve_revset(&repo, p).unwrap(), only_tip, "resolve_revset");
    let shown: Vec<_> = repo
        .show(Some(p), None)
        .unwrap()
        .into_iter()
        .map(|e| e.change.id)
        .collect();
    assert_eq!(shown, only_tip, "show");
    let evolog = repo.evolog(Some(p), Some(1)).unwrap();
    assert_eq!(evolog[0].change.id, tip, "evolog");
    let listed = repo.list_bookmarks(&revisions(p)).unwrap();
    assert!(listed.iter().any(|b| b.name == "tip"), "{listed:?}");
    assert!(listed.iter().all(|b| b.target.as_ref() == Some(&tip)), "{listed:?}");
}

/// A short-prefixes set that does not resolve fails to populate: only an id-prefix-shaped symbol
/// refuses (jj-lib's `RevsetResolutionError::Other`), every other symbol still resolves.
#[test]
fn an_unresolvable_short_prefixes_refuses_only_id_prefix_symbols() {
    let Fx {
        fixture: _fixture,
        mut repo,
        tip,
        prefix,
    } = medium("[revsets]\nshort-prefixes = \"missing\"\n");

    assert_eq!(eval(&mut repo, "tip").unwrap(), [tip]);
    let err = eval(&mut repo, &prefix).unwrap_err();
    assert!(
        matches!(&err, RevsetError::ResolutionError { detail, .. } if detail.kind == RevsetErrorKind::Other),
        "{err:?}"
    );
}

#[test]
fn the_topology_resolves_revset_and_anchors_within_its_short_prefixes() {
    let Fx {
        fixture: _fixture,
        mut repo,
        tip,
        prefix,
    } = medium(NO_SHORT);
    let anchor = [prefix.clone()];

    let err = repo
        .graph_topology(&prefix, DEFAULT_GRAPH_PRIORITIZE, "", &[], false)
        .unwrap_err();
    assert!(ambiguous(&err), "{err:?}");
    let err = repo
        .graph_topology("all()", DEFAULT_GRAPH_PRIORITIZE, "", &anchor, false)
        .unwrap_err();
    assert!(ambiguous(&err), "an anchor: {err:?}");
    let err = repo.graph_topology("all()", &prefix, "", &[], false).unwrap_err();
    assert!(ambiguous(&err), "prioritize: {err:?}");
    repo.graph_topology("all()", &prefix, "tip", &[], false)
        .expect("prioritize resolves within the context");

    let topology = repo
        .graph_topology(&prefix, DEFAULT_GRAPH_PRIORITIZE, "tip", &[], false)
        .unwrap();
    let ids: Vec<_> = topology.nodes.iter().map(|n| n.meta.change_id.clone()).collect();
    assert_eq!(ids, std::slice::from_ref(&tip.0));
    let topology = repo
        .graph_topology("all()", DEFAULT_GRAPH_PRIORITIZE, "tip", &anchor, false)
        .unwrap();
    let anchored: Vec<_> = topology.anchors[0]
        .iter()
        .map(|&i| topology.nodes[i].meta.change_id.clone())
        .collect();
    assert_eq!(anchored, [tip.0]);
}

/// `bookmark move --from P`: refused without the context, the bookmarks at `tip` moved with it.
#[test]
fn bookmark_move_from_resolves_within_the_short_prefixes() {
    let options = |prefix: &str, to: &ChangeId| BookmarkMoveOptions {
        from: vec![prefix.to_owned()],
        to: Some(to.clone()),
        allow_backwards: true,
        ..Default::default()
    };

    let Fx {
        fixture: _fixture,
        mut repo,
        prefix,
        ..
    } = medium(NO_SHORT);
    let parent = resolve_revset(&repo, "tip-").unwrap().remove(0);
    let err = repo.bookmark_move(&options(&prefix, &parent)).unwrap_err();
    assert!(
        matches!(&err, MutateError::RevsetResolutionError { reason, .. } if reason.contains("ambiguous")),
        "{err:?}"
    );

    let Fx {
        fixture: _fixture,
        mut repo,
        prefix,
        ..
    } = medium(SHORT_TIP);
    repo.bookmark_move(&options(&prefix, &parent)).unwrap();
    assert_eq!(resolve_revset(&repo, "tip").unwrap(), [parent]);
}

/// `bookmark advance` to `revsets.bookmark-advance-to = P`.
#[test]
fn bookmark_advance_to_resolves_within_the_short_prefixes() {
    let advance_to = "[revsets]\nshort-prefixes = \"\"\nbookmark-advance-to = \"{P}\"\n";
    let behind = || vec!["behind".to_owned()];

    let Fx {
        fixture: _fixture,
        mut repo,
        ..
    } = medium(advance_to);
    let parent = resolve_revset(&repo, "tip-").unwrap().remove(0);
    repo.bookmark_create(&behind(), Some(&parent)).unwrap();
    let err = repo.bookmark_advance(&behind(), None).unwrap_err();
    assert!(
        matches!(&err, MutateError::RevsetResolutionError { reason, .. } if reason.contains("ambiguous")),
        "{err:?}"
    );

    let Fx {
        fixture: _fixture,
        mut repo,
        tip,
        ..
    } = medium(&format!("{SHORT_TIP}bookmark-advance-to = \"{{P}}\"\n"));
    repo.bookmark_create(&behind(), Some(&parent)).unwrap();
    repo.bookmark_advance(&behind(), None).unwrap();
    assert_eq!(resolve_revset(&repo, "behind").unwrap(), [tip]);
}

/// `absorb --into P`, `bookmark advance` from `revsets.bookmark-advance-from = P` and `arrange`'s
/// default `revsets.arrange = P`: refused without the context, not refused that way with it.
#[test]
fn absorb_advance_from_and_arrange_resolve_within_the_short_prefixes() {
    let config = "bookmark-advance-from = \"{P}\"\narrange = \"{P}\"\n";
    // (verb, refused the ambiguous prefix, the result for the message)
    let run = |repo: &mut Repo, prefix: &str, tip: &ChangeId| {
        let absorb = repo.absorb(None, Some(prefix), &[]);
        let advance = repo.bookmark_advance(&[], Some(tip));
        let arrange = repo.arrange(&zanshin_jj::ArrangeOptions::default());
        [
            ("absorb", refused_ambiguous(&absorb), format!("{absorb:?}")),
            ("advance-from", refused_ambiguous(&advance), format!("{advance:?}")),
            ("arrange", refused_ambiguous(&arrange), format!("{arrange:?}")),
        ]
    };

    let Fx {
        fixture: _fixture,
        mut repo,
        tip,
        prefix,
    } = medium(&format!("{NO_SHORT}{config}"));
    for (verb, refused, result) in run(&mut repo, &prefix, &tip) {
        assert!(refused, "{verb} without the context: {result}");
    }

    let Fx {
        fixture: _fixture,
        mut repo,
        tip,
        prefix,
    } = medium(&format!("{SHORT_TIP}{config}"));
    for (verb, refused, result) in run(&mut repo, &prefix, &tip) {
        assert!(!refused, "{verb} within the context: {result}");
    }
}

/// `workspace add -r P`, into a temp dir of its own (the fixture root sits directly in the
/// system temp dir, so `../ws2` would be shared).
#[test]
fn workspace_add_revisions_resolve_within_the_short_prefixes() {
    let add = |repo: &mut Repo, prefix: &str| {
        let tmp = tempfile::TempDir::new().unwrap();
        let destination = tmp.path().join("ws2");
        let result = repo.workspace_add(
            destination.to_str().unwrap(),
            None,
            &[prefix.to_owned()],
            &[],
            None,
            SparseInheritance::Copy,
        );
        (tmp, result)
    };

    let Fx {
        fixture: _fixture,
        mut repo,
        prefix,
        ..
    } = medium(NO_SHORT);
    let (_tmp, result) = add(&mut repo, &prefix);
    let err = result.unwrap_err();
    assert!(
        matches!(&err, MutateError::RevsetResolutionError { reason, .. } if reason.contains("ambiguous")),
        "{err:?}"
    );

    let Fx {
        fixture: _fixture,
        mut repo,
        tip,
        prefix,
    } = medium(SHORT_TIP);
    let (_tmp, result) = add(&mut repo, &prefix);
    result.unwrap();
    assert_eq!(resolve_revset(&repo, "ws2@-").unwrap(), [tip]);
}
