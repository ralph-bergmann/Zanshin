// SPDX-License-Identifier: MIT

//! Fixture tests for `Repo::graph_topology` (Story 4.10): the index-only topology equals
//! `walk_graph`'s stream verbatim (ids, order, edges), its view half plus the op-pinned
//! `commit_contents` object half recompose `walk_graph`'s `CommitMeta`, and only the
//! timestamp option loads commits.
//!
//! A separate binary from `tests/graph.rs` on purpose: the slice path's tests must pass
//! without edits (the story's `git diff` check).

use std::env;
use std::ops::ControlFlow;
use std::path::Path;
use std::sync::LazyLock;

use test_helpers::{add_commit_with_files, extract_fixture};
use zanshin_jj::{
    resolve_revset, Change, CommitContent, CommitMeta, GraphEdgeKind, GraphNode, GraphTopology, Repo, RevsetError,
    TopologyMeta, WarningKind, DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET,
};

/// The CLI's `revsets.short-prefixes` default.
const SHORT: &str = DEFAULT_LOG_REVSET;

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: empty string pins jj-lib/git off the developer's globals for reproducibility.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
        env::set_var("JJ_USER", "Zanshin");
        env::set_var("JJ_EMAIL", "zanshin@localhost");
        env::set_var("JJ_OP_HOSTNAME", "localhost");
        env::set_var("JJ_OP_USERNAME", "zanshin");
        // Story 9.37: the start-up fix-up migrates the legacy repo configs written here.
        env::set_var("XDG_CONFIG_HOME", test_helpers::leaked_xdg_config_home());
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

/// The `zanshin_core` pre-fill `['trunk()', 'present(@)']`.
fn default_anchors() -> Vec<String> {
    vec!["trunk()".to_owned(), "present(@)".to_owned()]
}

/// `walk_graph`'s whole stream for the same pass-throughs.
fn walk(repo: &mut Repo, revset: &str, prioritize: &str) -> Vec<GraphNode> {
    walk_with(repo, revset, prioritize, SHORT)
}

/// [`walk`] with an explicit `short_prefixes`.
fn walk_with(repo: &mut Repo, revset: &str, prioritize: &str, short_prefixes: &str) -> Vec<GraphNode> {
    let mut nodes = Vec::new();
    let flow = repo
        .walk_graph(revset, prioritize, short_prefixes, |node| {
            nodes.push(node);
            ControlFlow::Continue(())
        })
        .unwrap();
    assert_eq!(flow, ControlFlow::Continue(()));
    nodes
}

/// The independent `eval_revset` oracle: every commit of `revset` as a `Change`.
fn oracle(repo: &mut Repo, revset: &str) -> Vec<Change> {
    let mut changes = Vec::new();
    let flow = repo
        .eval_revset(revset, |change| {
            changes.push(change);
            ControlFlow::Continue(())
        })
        .unwrap();
    assert_eq!(flow, ControlFlow::Continue(()));
    changes
}

/// Hex commit id of the single commit `revset` resolves to — through the public API only.
fn commit_id_of(repo: &mut Repo, revset: &str) -> String {
    let ids = resolve_revset(repo, revset).unwrap();
    assert_eq!(ids.len(), 1, "{revset} must resolve to exactly one change");
    repo.get_change(&ids[0]).unwrap().commit_id.0
}

/// The operation ids whose head markers are in `.jj/repo/op_heads/heads/`, sorted.
fn op_heads(root: &Path) -> Vec<String> {
    let mut heads: Vec<String> = std::fs::read_dir(root.join(".jj").join("repo").join("op_heads").join("heads"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    heads.sort();
    heads
}

/// Every target of every node as the commit id it names (`None` for a Missing edge).
fn edges_by_id(topology: &GraphTopology) -> Vec<Vec<(Option<String>, GraphEdgeKind)>> {
    topology
        .nodes
        .iter()
        .map(|node| {
            node.edges
                .iter()
                .map(|edge| (edge.target.map(|i| topology.nodes[i].commit_id.0.clone()), edge.kind))
                .collect()
        })
        .collect()
}

/// `walk_graph`'s edges in the same shape: a Missing edge's target is dropped, as the
/// topology drops it.
fn walk_edges(nodes: &[GraphNode]) -> Vec<Vec<(Option<String>, GraphEdgeKind)>> {
    nodes
        .iter()
        .map(|node| {
            node.parents
                .iter()
                .map(|edge| {
                    let target = (edge.kind != GraphEdgeKind::Missing).then(|| edge.target.0.clone());
                    (target, edge.kind)
                })
                .collect()
        })
        .collect()
}

/// Composes the `jj log` row from the two halves — the recomposition the story's first AC
/// states (`description_first_line` = first line of the full description).
fn recompose(view: &TopologyMeta, object: &CommitContent) -> CommitMeta {
    CommitMeta {
        change_id: view.change_id.clone(),
        change_id_prefix_len: view.change_id_prefix_len,
        commit_id_prefix_len: view.commit_id_prefix_len,
        change_offset: view.change_offset,
        author_name: object.author_name.clone(),
        author_email: object.author_email.clone(),
        committer_timestamp: object.committer_timestamp,
        bookmarks: view.bookmarks.clone(),
        tags: view.tags.clone(),
        working_copies: view.working_copies.clone(),
        working_copy: view.working_copy,
        immutable: view.immutable,
        conflict: object.conflict,
        empty: object.empty,
        hidden: view.hidden,
        divergent: view.divergent,
        root: view.root,
        description_first_line: object.description.lines().next().unwrap_or_default().to_owned(),
    }
}

/// The split-equivalence oracle over `all()` on one fixture: node order and edges equal
/// `walk_graph`'s, view + object half recompose every `CommitMeta`, and the independent
/// `eval_revset` `Change` agrees on the object half and the parent count.
fn assert_split_equivalence(fixture: &str) {
    let fx = extract_fixture(fixture).unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let walked = walk(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE);
    let topology = repo
        .graph_topology("all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, &default_anchors(), false)
        .unwrap();

    let ids: Vec<&str> = topology.nodes.iter().map(|n| n.commit_id.0.as_str()).collect();
    let walked_ids: Vec<&str> = walked.iter().map(|n| n.id.0.as_str()).collect();
    assert_eq!(ids, walked_ids, "{fixture}: node ids and order equal walk_graph's");
    assert_eq!(edges_by_id(&topology), walk_edges(&walked), "{fixture}: edges verbatim");

    let requested: Vec<zanshin_jj::CommitId> = topology.nodes.iter().map(|n| n.commit_id.clone()).collect();
    let contents = repo.commit_contents(&topology.operation_id, &requested).unwrap();
    assert_eq!(contents.len(), topology.nodes.len());
    for ((node, content), row) in topology.nodes.iter().zip(&contents).zip(&walked) {
        assert_eq!(content.commit_id, node.commit_id, "{fixture}: request order");
        assert_eq!(
            recompose(&node.meta, content),
            row.meta,
            "{fixture}: {} recomposes",
            node.commit_id.0
        );
    }

    let changes = oracle(&mut repo, "all()");
    assert_eq!(changes.len(), topology.nodes.len());
    for change in changes {
        let i = topology
            .nodes
            .iter()
            .position(|n| n.commit_id == change.commit_id)
            .expect("every oracle commit is a node");
        let content = &contents[i];
        assert_eq!(content.author_email, change.author.email);
        assert_eq!(content.author_name, change.author.name);
        assert_eq!(content.committer_timestamp, change.timestamps.committed_at);
        assert_eq!(content.description, change.description, "the FULL description");
        assert_eq!(
            topology.nodes[i].meta.parent_count as usize,
            change.parents.len(),
            "{fixture}: parent_count of {}",
            change.commit_id.0
        );
    }
}

// ── Happy path + counts ───────────────────────────────────────────────────────

#[test]
fn graph_topology_tiny_all_equals_walk_graph_and_reports_counts_anchors_and_op_id() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let walked = walk(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

    let topology = repo
        .graph_topology("all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, &default_anchors(), false)
        .unwrap();

    let ids: Vec<&str> = topology.nodes.iter().map(|n| n.commit_id.0.as_str()).collect();
    let walked_ids: Vec<&str> = walked.iter().map(|n| n.id.0.as_str()).collect();
    assert_eq!(ids, walked_ids, "@, c3, c2, c1, root — walk_graph's order");
    assert_eq!(edges_by_id(&topology), walk_edges(&walked));
    let counts: Vec<u32> = topology.nodes.iter().map(|n| n.meta.parent_count).collect();
    assert_eq!(counts, vec![1, 1, 1, 1, 0], "@ and c1..c3 have one parent, root none");
    assert_eq!(
        topology.anchors,
        vec![vec![4], vec![0]],
        "trunk() = root, present(@) = @"
    );
    assert_eq!(topology.all_count, 5);
    assert!(topology.nodes.iter().all(|n| n.committer_timestamp_ms.is_none()));
    assert!(topology.nodes[4].meta.root);
    assert!(topology.nodes[0].meta.working_copy);
    assert_eq!(
        op_heads(&fx.path),
        vec![topology.operation_id.0.clone()],
        "the operation id is the single op head after the call"
    );
}

#[test]
fn graph_topology_with_timestamps_carries_every_non_root_committer_timestamp() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let changes = oracle(&mut repo, "all()");

    let topology = repo
        .graph_topology("all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, &default_anchors(), true)
        .unwrap();

    for node in &topology.nodes {
        if node.meta.root {
            assert_eq!(node.committer_timestamp_ms, None, "the root carries no timestamp");
            continue;
        }
        let change = changes.iter().find(|c| c.commit_id == node.commit_id).unwrap();
        assert_eq!(
            node.committer_timestamp_ms,
            Some(change.committer.timestamp.millis_since_epoch),
            "{} carries its COMMITTER timestamp",
            node.commit_id.0
        );
    }
}

#[test]
fn graph_topology_medium_counts_the_octopus_merges_three_parents_and_every_node() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let topology = repo
        .graph_topology("all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, &default_anchors(), false)
        .unwrap();

    assert_eq!(topology.nodes.len(), 1002);
    assert_eq!(topology.all_count, 1002);
    let merges: Vec<u32> = topology
        .nodes
        .iter()
        .map(|n| n.meta.parent_count)
        .filter(|&count| count > 1)
        .collect();
    assert_eq!(merges, vec![3], "exactly one octopus merge, with three parents");
    assert!(
        topology
            .nodes
            .iter()
            .flat_map(|n| &n.edges)
            .all(|e| e.kind == GraphEdgeKind::Direct && e.target.is_some()),
        "every all() edge is Direct"
    );
}

#[test]
fn graph_topology_split_recomposes_walk_graph_meta_on_tiny() {
    pin_env();
    assert_split_equivalence("tiny-3-commits");
}

#[test]
fn graph_topology_split_recomposes_walk_graph_meta_on_medium() {
    pin_env();
    assert_split_equivalence("medium-1k-commits");
}

// ── Narrowed / empty inputs ───────────────────────────────────────────────────

#[test]
fn graph_topology_narrowed_revset_keeps_the_all_count_and_empties_outside_anchors() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&mut repo, "@");

    let topology = repo
        .graph_topology("@", DEFAULT_GRAPH_PRIORITIZE, SHORT, &default_anchors(), false)
        .unwrap();

    assert_eq!(topology.nodes.len(), 1);
    assert_eq!(topology.nodes[0].commit_id.0, wc);
    assert_eq!(topology.all_count, 5, "|all()| is independent of the revset");
    assert_eq!(
        topology.anchors,
        vec![Vec::<usize>::new(), vec![0]],
        "trunk() is outside the revset, so it selects nothing"
    );
    assert_eq!(topology.nodes[0].edges.len(), 1);
    assert_eq!(topology.nodes[0].edges[0].kind, GraphEdgeKind::Missing);
    assert_eq!(topology.nodes[0].edges[0].target, None, "a Missing edge has no target");
    assert_eq!(
        topology.nodes[0].meta.parent_count, 1,
        "the Missing parent still counts"
    );
}

#[test]
fn graph_topology_empty_anchor_list_and_empty_revset_are_valid() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let no_anchors = repo
        .graph_topology("all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, &[], false)
        .unwrap();
    assert!(no_anchors.anchors.is_empty());
    assert_eq!(no_anchors.nodes.len(), 5);

    let empty = repo
        .graph_topology("none()", DEFAULT_GRAPH_PRIORITIZE, SHORT, &default_anchors(), false)
        .unwrap();
    assert!(empty.nodes.is_empty());
    assert_eq!(empty.all_count, 5);
    assert_eq!(empty.anchors, vec![Vec::<usize>::new(), Vec::new()]);
}

#[test]
fn graph_topology_bad_anchor_fails_like_the_revset_does() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let parse = repo.graph_topology("all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, &["(".to_owned()], false);
    assert!(matches!(parse, Err(RevsetError::ParseError { .. })), "got {parse:?}");

    let resolve = repo.graph_topology(
        "all()",
        DEFAULT_GRAPH_PRIORITIZE,
        SHORT,
        &["trunk()".to_owned(), "nosuchbookmark".to_owned()],
        false,
    );
    assert!(
        matches!(resolve, Err(RevsetError::ResolutionError { .. })),
        "got {resolve:?}"
    );
}

// ── Edges ─────────────────────────────────────────────────────────────────────

#[test]
fn graph_topology_keeps_a_merges_direct_and_indirect_edge_to_one_parent() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    // M(A, B) with B a child of A: excluding B turns M's second edge into an Indirect edge to A,
    // next to M's Direct edge to A — a repeated target jj keeps.
    let a = add_commit_with_files(&fx.path, &[], &[("a.txt", "a")], "A");
    let b = add_commit_with_files(&fx.path, &[&a], &[("b.txt", "b")], "B");
    let m = add_commit_with_files(&fx.path, &[&a, &b], &[("m.txt", "m")], "M");
    let mut repo = Repo::open(&fx.path).unwrap();
    let revset = format!("all() ~ {b}");
    let walked = walk(&mut repo, &revset, DEFAULT_GRAPH_PRIORITIZE);

    let topology = repo
        .graph_topology(&revset, DEFAULT_GRAPH_PRIORITIZE, SHORT, &default_anchors(), false)
        .unwrap();

    assert_eq!(
        edges_by_id(&topology),
        walk_edges(&walked),
        "edges verbatim, repeats included"
    );
    let merge = topology.nodes.iter().find(|n| n.commit_id.0 == m).unwrap();
    let a_index = topology.nodes.iter().position(|n| n.commit_id.0 == a).unwrap();
    let mut kinds: Vec<GraphEdgeKind> = merge
        .edges
        .iter()
        .filter(|e| e.target == Some(a_index))
        .map(|e| e.kind)
        .collect();
    kinds.sort_by_key(|k| format!("{k:?}"));
    assert_eq!(kinds, vec![GraphEdgeKind::Direct, GraphEdgeKind::Indirect]);
    assert_eq!(merge.meta.parent_count, 2);
}

// ── Precondition + which calls load commits ───────────────────────────────────

#[test]
fn graph_topology_snapshots_once_and_returns_the_head_after_its_snapshot() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let before = op_heads(&fx.path);
    assert_eq!(before.len(), 1);

    std::fs::write(fx.path.join("edited.txt"), "a working-copy edit").unwrap();
    let topology = repo
        .graph_topology("all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, &default_anchors(), false)
        .unwrap();

    let precondition = repo.take_precondition().expect("the precondition ran");
    assert!(precondition.was_snapshot_taken, "the edit was snapshotted");
    assert_ne!(topology.operation_id.0, before[0], "the snapshot wrote a new operation");
    assert_eq!(op_heads(&fx.path), vec![topology.operation_id.0.clone()]);
}

#[test]
fn graph_topology_loads_commits_only_for_timestamps() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    // The oracle handle has its own commit cache; the handle under test never reads c2.
    let c2 = {
        let mut oracle_repo = Repo::open(&fx.path).unwrap();
        commit_id_of(&mut oracle_repo, "description(\"Commit 2\")")
    };
    let mut repo = Repo::open(&fx.path).unwrap();
    let objects = fx
        .path
        .join(".jj")
        .join("repo")
        .join("store")
        .join("git")
        .join("objects");
    std::fs::remove_file(objects.join(&c2[..2]).join(&c2[2..])).expect("c2 is a loose object");

    let index_only = repo.graph_topology("all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, &default_anchors(), false);
    assert!(
        index_only.is_ok(),
        "no node is loaded without timestamps: {index_only:?}"
    );

    let with_timestamps = repo.graph_topology("all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, &default_anchors(), true);
    assert!(
        matches!(with_timestamps, Err(RevsetError::JjLibError(_))),
        "timestamps load every non-root node: {with_timestamps:?}"
    );
}

// ── Pass-throughs + side channels ─────────────────────────────────────────────

/// `prioritize = none()` and an EMPTY `short_prefixes` reach the topology path exactly as
/// they reach `walk_graph`: no prioritisation (c3 first, not @ — as in `tests/graph.rs`), and
/// full-index prefix lengths. A hidden default on either would change the order or the lengths.
#[test]
fn graph_topology_passes_prioritize_and_short_prefixes_through_without_a_default() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");
    let walked = walk_with(&mut repo, "all()", "none()", "");

    let topology = repo.graph_topology("all()", "none()", "", &[], false).unwrap();

    let ids: Vec<&str> = topology.nodes.iter().map(|n| n.commit_id.0.as_str()).collect();
    let walked_ids: Vec<&str> = walked.iter().map(|n| n.id.0.as_str()).collect();
    assert_eq!(ids, walked_ids);
    assert_eq!(ids[0], c3, "no prioritisation: c3 first, not @");
    let requested: Vec<zanshin_jj::CommitId> = topology.nodes.iter().map(|n| n.commit_id.clone()).collect();
    let contents = repo.commit_contents(&topology.operation_id, &requested).unwrap();
    for ((node, content), row) in topology.nodes.iter().zip(&contents).zip(&walked) {
        assert_eq!(
            recompose(&node.meta, content),
            row.meta,
            "{} recomposes",
            node.commit_id.0
        );
    }
}

/// An anchor's parse diagnostics reach `take_warnings()` under the CLI's context line, like the
/// revset's own (`tests/warnings.rs::revset_parse_diagnostics_warn_under_the_clis_context_line`).
#[test]
fn graph_topology_records_an_anchors_parse_diagnostics_as_warnings() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    repo.graph_topology(
        "all()",
        DEFAULT_GRAPH_PRIORITIZE,
        SHORT,
        &["diff_contains(\"x\")".to_owned()],
        false,
    )
    .unwrap();

    let warnings = repo.take_warnings();
    let kinds: Vec<WarningKind> = warnings.iter().map(|w| w.kind).collect();
    assert_eq!(kinds, [WarningKind::RevsetDiagnostic]);
    assert!(
        warnings[0].message.starts_with("In revset expression\n")
            && warnings[0]
                .message
                .contains("diff_contains() is deprecated; use diff_lines() instead"),
        "{}",
        warnings[0].message
    );
}
