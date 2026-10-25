// SPDX-License-Identifier: MIT

//! Fixture tests for `Repo::commit_contents` (Story 4.10): the op-pinned object half of a
//! `jj log` row — request order, the error ladder in check order, and the pinned read's
//! write-nothing contract (no operation, no op head, no precondition, no warnings).

use std::ops::ControlFlow;
use std::path::Path;

use test_helpers::{add_commit_off_root, extract_fixture};
use zanshin_jj::{
    resolve_revset, CommitContentError, CommitId, CommitMeta, GraphNode, OperationId, Repo, DEFAULT_GRAPH_PRIORITIZE,
    DEFAULT_LOG_REVSET,
};

/// Hex commit id of the single commit `revset` resolves to — through the public API only.
fn commit_id_of(repo: &mut Repo, revset: &str) -> CommitId {
    let ids = resolve_revset(repo, revset).unwrap();
    assert_eq!(ids.len(), 1, "{revset} must resolve to exactly one change");
    repo.get_change(&ids[0]).unwrap().commit_id
}

/// The file names in `.jj/repo/<dir>`, sorted.
fn listing(root: &Path, dir: &[&str]) -> Vec<String> {
    let mut path = root.join(".jj").join("repo");
    for part in dir {
        path = path.join(part);
    }
    let mut names: Vec<String> = std::fs::read_dir(path)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

fn op_heads(root: &Path) -> Vec<String> {
    listing(root, &["op_heads", "heads"])
}

/// The single current op head, read off disk (no snapshot).
fn head(root: &Path) -> OperationId {
    let heads = op_heads(root);
    assert_eq!(heads.len(), 1, "one op head");
    OperationId(heads[0].clone())
}

/// `walk_graph`'s rows for `all()` — the oracle of every object-half value but the full
/// description.
fn walked_meta(repo: &mut Repo) -> Vec<(String, CommitMeta)> {
    let mut rows: Vec<GraphNode> = Vec::new();
    let flow = repo
        .walk_graph("all()", DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET, |node| {
            rows.push(node);
            ControlFlow::Continue(())
        })
        .unwrap();
    assert_eq!(flow, ControlFlow::Continue(()));
    rows.into_iter().map(|n| (n.id.0, n.meta)).collect()
}

fn invalid_input(result: Result<Vec<zanshin_jj::CommitContent>, CommitContentError>) -> String {
    match result {
        Err(CommitContentError::InvalidInput(text)) => text,
        other => panic!("expected InvalidInput, got {other:?}"),
    }
}

// ── Happy path ────────────────────────────────────────────────────────────────

#[test]
fn commit_contents_answers_in_request_order_with_the_full_description() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");
    let root = commit_id_of(&mut repo, "root()");
    let wc = commit_id_of(&mut repo, "@");
    let rows = walked_meta(&mut repo);
    let c3_description = repo
        .get_change(&resolve_revset(&repo, &c3.0).unwrap()[0])
        .unwrap()
        .description;
    let op = head(&fx.path);

    let contents = repo
        .commit_contents(&op, &[c3.clone(), root.clone(), wc.clone()])
        .unwrap();

    let ids: Vec<&CommitId> = contents.iter().map(|c| &c.commit_id).collect();
    assert_eq!(ids, vec![&c3, &root, &wc], "request order, not jj log order");
    for content in &contents {
        let meta = &rows.iter().find(|(id, _)| *id == content.commit_id.0).unwrap().1;
        assert_eq!(content.author_name, meta.author_name);
        assert_eq!(content.author_email, meta.author_email);
        assert_eq!(content.committer_timestamp, meta.committer_timestamp);
        assert_eq!(content.conflict, meta.conflict);
        assert_eq!(content.empty, meta.empty);
        assert_eq!(
            content.description.lines().next().unwrap_or_default(),
            meta.description_first_line
        );
    }
    assert_eq!(contents[0].description, c3_description, "the FULL description");
    assert_eq!(contents[1].description, "", "the root has no description");
    // jj-lib's fabricated root commit, as `jj log` shows it: an empty author, the epoch.
    assert_eq!(contents[1].author_name, "");
    assert_eq!(contents[1].author_email, "");
    assert_eq!(
        contents[1].committer_timestamp,
        zanshin_jj::Timestamp {
            millis_since_epoch: 0,
            tz_offset_minutes: 0
        },
        "the root's committer timestamp is the epoch, not an absence"
    );
}

#[test]
fn commit_contents_of_an_empty_list_is_empty() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    assert!(repo.commit_contents(&head(&fx.path), &[]).unwrap().is_empty());
}

// ── Error ladder ──────────────────────────────────────────────────────────────

#[test]
fn commit_contents_refuses_an_empty_or_non_hex_operation_id_with_the_cli_text() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    assert_eq!(
        invalid_input(repo.commit_contents(&OperationId(String::new()), &[])),
        r#"Operation ID "" is not a valid hexadecimal prefix"#
    );
    assert_eq!(
        invalid_input(repo.commit_contents(&OperationId("xyz".to_owned()), &[])),
        r#"Operation ID "xyz" is not a valid hexadecimal prefix"#
    );
}

#[test]
fn commit_contents_refuses_an_operation_id_prefix_without_resolving_it() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let op = head(&fx.path).0;

    let prefix = &op[..12];
    assert_eq!(
        invalid_input(repo.commit_contents(&OperationId(prefix.to_owned()), &[])),
        format!(r#"Operation ID "{prefix}" is not a full operation ID"#)
    );
    let odd = &op[..op.len() - 1];
    assert_eq!(
        invalid_input(repo.commit_contents(&OperationId(odd.to_owned()), &[])),
        format!(r#"Operation ID "{odd}" is not a full operation ID"#)
    );
}

#[test]
fn commit_contents_reports_an_unknown_operation_as_not_found() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let unknown = "ab".repeat(64);

    let err = repo.commit_contents(&OperationId(unknown.clone()), &[]).unwrap_err();

    assert!(
        matches!(err, CommitContentError::OperationNotFound(ref id) if *id == unknown),
        "got {err:?}"
    );
    assert_eq!(err.to_string(), format!(r#"No operation ID matching "{unknown}""#));
}

#[test]
fn commit_contents_reports_a_vanished_older_operation_as_not_found() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let older = head(&fx.path);
    let _external = add_commit_off_root(&fx.path, "moves head");
    assert_ne!(head(&fx.path), older, "the external commit wrote a new head");
    // `jj op abandon` + `jj util gc`, reduced to its effect: the operation file is gone.
    std::fs::remove_file(
        fx.path
            .join(".jj")
            .join("repo")
            .join("op_store")
            .join("operations")
            .join(&older.0),
    )
    .unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let err = repo.commit_contents(&older, &[]).unwrap_err();

    assert!(
        matches!(err, CommitContentError::OperationNotFound(ref id) if *id == older.0),
        "got {err:?}"
    );
}

#[test]
fn commit_contents_refuses_malformed_commit_ids() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");
    let op = head(&fx.path);

    assert_eq!(
        invalid_input(repo.commit_contents(&op, &[CommitId(String::new())])),
        r#"Commit ID "" is not a valid hexadecimal prefix"#
    );
    assert_eq!(
        invalid_input(repo.commit_contents(&op, &[CommitId("zz".to_owned())])),
        r#"Commit ID "zz" is not a valid hexadecimal prefix"#
    );
    let prefix = &c3.0[..12];
    assert_eq!(
        invalid_input(repo.commit_contents(&op, &[CommitId(prefix.to_owned())])),
        format!(r#"Commit ID "{prefix}" is not a full commit ID"#)
    );
}

#[test]
fn commit_contents_accepts_an_uppercase_commit_id_and_answers_in_lowercase() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");

    let contents = repo
        .commit_contents(&head(&fx.path), &[CommitId(c3.0.to_uppercase())])
        .unwrap();

    assert_eq!(contents[0].commit_id, c3);
}

#[test]
fn commit_contents_reports_an_unindexed_commit_id_as_not_found() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let pinned = head(&fx.path);
    let later = add_commit_off_root(&fx.path, "created after the pinned operation");
    let absent = "0123456789abcdef0123456789abcdef01234567".to_owned();

    for id in [absent, later] {
        let err = repo.commit_contents(&pinned, &[CommitId(id.clone())]).unwrap_err();
        assert!(
            matches!(err, CommitContentError::CommitNotFound(ref hex) if *hex == id),
            "{id} is not in the pinned index: {err:?}"
        );
    }
}

#[test]
fn commit_contents_checks_the_operation_first_and_every_id_format_before_the_index() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let absent = CommitId("0123456789abcdef0123456789abcdef01234567".to_owned());
    let malformed = CommitId("zz".to_owned());

    let op_first =
        invalid_input(repo.commit_contents(&OperationId("xyz".to_owned()), std::slice::from_ref(&malformed)));
    assert!(op_first.starts_with("Operation ID"), "the op-id error wins: {op_first}");

    let format_first = invalid_input(repo.commit_contents(&head(&fx.path), &[absent, malformed]));
    assert_eq!(
        format_first, r#"Commit ID "zz" is not a valid hexadecimal prefix"#,
        "a later malformed id wins over an earlier unindexed one"
    );
}

#[test]
fn commit_contents_reports_an_unloadable_indexed_commit_and_its_child_as_backend_errors() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let (c2, c3) = {
        let mut oracle_repo = Repo::open(&fx.path).unwrap();
        (
            commit_id_of(&mut oracle_repo, "description(\"Commit 2\")"),
            commit_id_of(&mut oracle_repo, "description(\"Commit 3\")"),
        )
    };
    // A fresh handle: its store has never read c2, so the deletion is observable.
    let mut repo = Repo::open(&fx.path).unwrap();
    let objects = fx
        .path
        .join(".jj")
        .join("repo")
        .join("store")
        .join("git")
        .join("objects");
    std::fs::remove_file(objects.join(&c2.0[..2]).join(&c2.0[2..])).expect("c2 is a loose object");
    let op = head(&fx.path);

    let own = repo.commit_contents(&op, &[c2]).unwrap_err();
    assert!(
        matches!(own, CommitContentError::Backend(_)),
        "indexed but unloadable: {own:?}"
    );
    // c3 itself loads, but `empty` loads its parent c2.
    let child = repo.commit_contents(&op, &[c3]).unwrap_err();
    assert!(
        matches!(child, CommitContentError::Backend(_)),
        "the parent load fails: {child:?}"
    );
}

// ── The pinned read writes nothing ─────────────────────────────────────────────

#[test]
fn commit_contents_at_an_old_operation_writes_nothing_and_answers_unchanged() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let topology = repo
        .graph_topology("all()", DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET, &[], false)
        .unwrap();
    _ = repo.take_precondition();
    _ = repo.take_warnings();
    let ids: Vec<CommitId> = topology.nodes.iter().map(|n| n.commit_id.clone()).collect();
    let before = repo.commit_contents(&topology.operation_id, &ids).unwrap();

    // A working-copy edit and an external commit that moves head.
    std::fs::write(fx.path.join("edited.txt"), "not yet snapshotted").unwrap();
    let external = add_commit_off_root(&fx.path, "external");
    let heads = op_heads(&fx.path);
    let operations = listing(&fx.path, &["op_store", "operations"]);

    let after = repo.commit_contents(&topology.operation_id, &ids).unwrap();

    assert_eq!(after, before, "commit-intrinsic values at the pinned operation");
    assert_eq!(op_heads(&fx.path), heads, "no op head written or pruned");
    assert_eq!(
        listing(&fx.path, &["op_store", "operations"]),
        operations,
        "no operation written"
    );
    assert!(repo.take_precondition().is_none(), "no precondition ran");
    assert!(repo.take_warnings().is_empty(), "no warning recorded");

    // The next topology call snapshots and sees both changes.
    let next = repo
        .graph_topology("all()", DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET, &[], false)
        .unwrap();
    assert!(repo.take_precondition().is_some_and(|p| p.was_snapshot_taken));
    assert!(
        next.nodes.iter().any(|n| n.commit_id.0 == external),
        "the external commit"
    );
    let wc_before = topology.nodes.iter().find(|n| n.meta.working_copy).unwrap();
    let wc_after = next.nodes.iter().find(|n| n.meta.working_copy).unwrap();
    assert_ne!(wc_after.commit_id, wc_before.commit_id, "the snapshot rewrote @");
}

#[test]
fn commit_contents_leaves_the_previous_verbs_side_channels_untouched() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let topology = repo
        .graph_topology("all()", DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET, &[], false)
        .unwrap();

    let ids = [topology.nodes[0].commit_id.clone()];
    repo.commit_contents(&topology.operation_id, &ids).unwrap();

    assert!(
        repo.take_precondition().is_some(),
        "the topology call's report is still there — the content call neither resets nor replaces it"
    );
}

#[test]
fn commit_contents_leaves_divergent_op_heads_unreconciled() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let heads_dir = fx.path.join(".jj").join("repo").join("op_heads").join("heads");
    // Two SIBLING op heads — two external operations on the same parent h0 — by the marker
    // choreography of `tests/it/op_log.rs::undo_on_merge_op_returns_invalid_input`: rewind the
    // heads dir to h0 between the two writes, then put h1's marker back. `load_at_head` would
    // publish a "reconcile divergent operations" merge here; a pinned read must not.
    let h0 = head(&fx.path);
    let a = add_commit_off_root(&fx.path, "sibling A");
    let h1 = head(&fx.path);
    std::fs::remove_file(heads_dir.join(&h1.0)).unwrap();
    std::fs::write(heads_dir.join(&h0.0), "").unwrap();
    let b = add_commit_off_root(&fx.path, "sibling B");
    let h2 = head(&fx.path);
    std::fs::write(heads_dir.join(&h1.0), "").unwrap();
    let mut expected = vec![h1.0.clone(), h2.0.clone()];
    expected.sort();
    assert_eq!(op_heads(&fx.path), expected, "two sibling op heads");
    let operations = listing(&fx.path, &["op_store", "operations"]);
    let mut repo = Repo::open(&fx.path).unwrap();

    let at_h1 = repo.commit_contents(&h1, &[CommitId(a.clone())]).unwrap();
    let at_h2 = repo.commit_contents(&h2, &[CommitId(b.clone())]).unwrap();

    assert_eq!(at_h1[0].commit_id.0, a);
    assert_eq!(at_h1[0].description, "sibling A");
    assert_eq!(at_h2[0].commit_id.0, b);
    assert_eq!(at_h2[0].description, "sibling B");
    assert_eq!(op_heads(&fx.path), expected, "both markers stay: no reconcile merge");
    assert_eq!(
        listing(&fx.path, &["op_store", "operations"]),
        operations,
        "no operation written"
    );
}
