// SPDX-License-Identifier: MIT

//! Fixture tests for `Repo::walk_graph` (Story 4.3): the revset graph stream contract
//! `zanshin-graph`'s lane assigner relies on — children before parents, every node once,
//! edge kinds as jj-lib classifies them, `jj log` order, re-resolved to head per call.

use std::collections::HashSet;
use std::env;
use std::ops::ControlFlow;
use std::path::Path;
use std::sync::LazyLock;

use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::Repo as _;
use jj_lib::settings::UserSettings;
use jj_lib::workspace::{default_working_copy_factories, Workspace};
use test_helpers::extract_fixture;
use zanshin_jj::{resolve_revset, GraphEdgeKind, GraphNode, Repo, RevsetError, DEFAULT_GRAPH_PRIORITIZE};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // WHY: empty string pins jj-lib/git off the developer's globals for reproducibility.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
    }
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

/// Collects the whole stream into a Vec (the stream must be exhausted → `Continue`).
fn collect_nodes(repo: &Repo, revset: &str, prioritize: &str) -> Vec<GraphNode> {
    let mut nodes = Vec::new();
    let flow = repo
        .walk_graph(revset, prioritize, |node| {
            nodes.push(node);
            ControlFlow::Continue(())
        })
        .unwrap();
    assert_eq!(flow, ControlFlow::Continue(()), "an unbroken walk must report Continue");
    nodes
}

/// Hex commit id of the single commit `revset` resolves to — through the public API only.
fn commit_id_of(repo: &Repo, revset: &str) -> String {
    let ids = resolve_revset(repo, revset).unwrap();
    assert_eq!(ids.len(), 1, "{revset} must resolve to exactly one change");
    repo.get_change(&ids[0]).unwrap().commit_id.0
}

/// Adds a visible commit off root via an external jj-lib transaction (a new operation),
/// returning its hex commit id — simulates an external `jj` mutating the repo.
fn add_commit_off_root(workspace_root: &Path, description: &str) -> String {
    let settings = make_test_settings();
    let workspace = Workspace::load(
        &settings,
        workspace_root,
        &jj_lib::repo::StoreFactories::default(),
        &default_working_copy_factories(),
    )
    .unwrap();
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).unwrap();
    let root_commit = repo.store().root_commit();
    let root_id = root_commit.id().clone();

    let mut tx = repo.start_transaction();
    let commit = pollster::block_on(
        tx.repo_mut()
            .new_commit(vec![root_id], root_commit.tree())
            .set_description(description)
            .write(),
    )
    .unwrap();
    pollster::block_on(tx.repo_mut().add_head(&commit)).unwrap();
    pollster::block_on(tx.commit("test: add external commit")).unwrap();
    commit.id().hex()
}

// ── Tiny: node set + CLI-default order (`present(@)` first) ─────────────────

#[test]
fn walk_graph_tiny_all_with_default_prioritize_emits_wc_branch_first_in_log_order() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&repo, "@");
    let c3 = commit_id_of(&repo, "description(\"Commit 3\")");
    let c2 = commit_id_of(&repo, "description(\"Commit 2\")");
    let c1 = commit_id_of(&repo, "description(\"Commit 1\")");
    let root = commit_id_of(&repo, "root()");

    let nodes = collect_nodes(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

    let ids: Vec<&str> = nodes.iter().map(|n| n.id.0.as_str()).collect();
    assert_eq!(
        ids,
        vec![&wc, &c3, &c2, &c1, &root],
        "jj log order: @ first, then c3..c1, root last"
    );
    // Every edge is Direct and points at the parent that arrives later; root has none.
    for node in &nodes[..4] {
        assert_eq!(node.parents.len(), 1, "{} has one parent", node.id.0);
        assert_eq!(node.parents[0].kind, GraphEdgeKind::Direct);
    }
    assert_eq!(nodes[0].parents[0].target.0, root, "@ → root");
    assert_eq!(nodes[1].parents[0].target.0, c2, "c3 → c2");
    assert_eq!(nodes[2].parents[0].target.0, c1, "c2 → c1");
    assert_eq!(nodes[3].parents[0].target.0, root, "c1 → root");
    assert!(nodes[4].parents.is_empty(), "root has no parents");
}

#[test]
fn walk_graph_tiny_all_without_prioritize_emits_natural_topo_grouped_order() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&repo, "@");
    let c3 = commit_id_of(&repo, "description(\"Commit 3\")");

    let prioritized = collect_nodes(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE);
    let natural = collect_nodes(&repo, "all()", "none()");

    let as_set = |nodes: &[GraphNode]| -> HashSet<String> { nodes.iter().map(|n| n.id.0.clone()).collect() };
    assert_eq!(as_set(&natural), as_set(&prioritized), "same node set either way");
    assert_eq!(natural.len(), 5);
    assert_ne!(
        natural[0].id.0, wc,
        "without present(@) the working-copy branch is not forced first"
    );
    assert_eq!(
        natural[0].id.0, c3,
        "the branch of the first input commit (c3) is emitted first"
    );
}

// ── Edge kinds ──────────────────────────────────────────────────────────────

#[test]
fn walk_graph_heads_only_yields_missing_edges_for_out_of_set_parents() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&repo, "@");

    let nodes = collect_nodes(&repo, "heads(all())", DEFAULT_GRAPH_PRIORITIZE);

    assert_eq!(nodes.len(), 2, "tiny has two heads: @ and c3");
    assert_eq!(nodes[0].id.0, wc, "@ is prioritised first");
    for node in &nodes {
        assert_eq!(node.parents.len(), 1, "{} has exactly one edge", node.id.0);
        assert_eq!(
            node.parents[0].kind,
            GraphEdgeKind::Missing,
            "{} → out-of-set parent",
            node.id.0
        );
    }
}

#[test]
fn walk_graph_elided_parent_yields_indirect_edge_to_closest_in_set_ancestor() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let c3 = commit_id_of(&repo, "description(\"Commit 3\")");
    let c2 = commit_id_of(&repo, "description(\"Commit 2\")");
    let c1 = commit_id_of(&repo, "description(\"Commit 1\")");

    let nodes = collect_nodes(&repo, "all() ~ description(\"Commit 2\")", DEFAULT_GRAPH_PRIORITIZE);

    assert_eq!(nodes.len(), 4);
    assert!(nodes.iter().all(|n| n.id.0 != c2), "c2 is absent from the stream");
    let c3_node = nodes.iter().find(|n| n.id.0 == c3).expect("c3 present");
    assert_eq!(c3_node.parents.len(), 1);
    assert_eq!(c3_node.parents[0].kind, GraphEdgeKind::Indirect);
    assert_eq!(c3_node.parents[0].target.0, c1, "c3's edge skips the elided c2 to c1");
}

// ── Medium: structural invariants of the stream contract ────────────────────

#[test]
fn walk_graph_medium_all_visits_every_node_once_children_before_parents() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&repo, "@");

    let nodes = collect_nodes(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

    assert_eq!(nodes.len(), 1002, "root + @ + 1000 fixture commits");
    assert_eq!(nodes[0].id.0, wc, "present(@) puts the working copy first");
    let unique: HashSet<&str> = nodes.iter().map(|n| n.id.0.as_str()).collect();
    assert_eq!(unique.len(), nodes.len(), "every node is emitted exactly once");

    let merges = nodes.iter().filter(|n| n.parents.len() == 3).count();
    assert_eq!(merges, 1, "exactly one octopus merge (A, B, C)");
    assert!(
        nodes
            .iter()
            .flat_map(|n| &n.parents)
            .all(|e| e.kind == GraphEdgeKind::Direct),
        "all() elides nothing: every edge is Direct"
    );

    // Children before parents: every edge target is emitted at a LATER position.
    let mut seen: HashSet<&str> = HashSet::new();
    for node in &nodes {
        for edge in &node.parents {
            assert!(
                !seen.contains(edge.target.0.as_str()),
                "{} → {} points backwards",
                node.id.0,
                edge.target.0
            );
        }
        seen.insert(node.id.0.as_str());
    }
    for node in &nodes {
        for edge in &node.parents {
            assert!(
                seen.contains(edge.target.0.as_str()),
                "target {} never arrived",
                edge.target.0
            );
        }
    }
}

// ── Streaming shape: early exit, empty set ──────────────────────────────────

#[test]
fn walk_graph_visitor_break_stops_the_stream_and_reports_break() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let mut visited = 0usize;
    let flow = repo
        .walk_graph("all()", DEFAULT_GRAPH_PRIORITIZE, |_node| {
            visited += 1;
            if visited == 2 {
                ControlFlow::Break(())
            } else {
                ControlFlow::Continue(())
            }
        })
        .unwrap();

    assert_eq!(flow, ControlFlow::Break(()));
    assert_eq!(visited, 2, "no node is visited after the visitor broke");
}

#[test]
fn walk_graph_empty_revset_visits_nothing_and_reports_continue() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let nodes = collect_nodes(&repo, "none()", DEFAULT_GRAPH_PRIORITIZE);

    assert!(nodes.is_empty());
}

// ── Re-derive per call (ADR-0002): same handle sees an external operation ───

#[test]
fn walk_graph_rederives_from_head_so_an_external_commit_appears_on_the_next_call() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let before = collect_nodes(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

    let new_id = add_commit_off_root(&fx.path, "external op");

    // Same `Repo` handle — no reopen, no cache.
    let after = collect_nodes(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE);
    assert_eq!(after.len(), before.len() + 1, "the new commit is a new node");
    assert!(
        after.iter().any(|n| n.id.0 == new_id),
        "the new commit id is in the stream"
    );
    assert!(before.iter().all(|n| n.id.0 != new_id), "it was not there before");
}

// ── Prioritize outside the revset: intersection prevents the TopoGroupedGraph panic ──

#[test]
fn walk_graph_prioritize_outside_revset_falls_back_to_natural_order_without_panic() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let nodes = collect_nodes(&repo, "heads(all())", "root()");

    assert_eq!(nodes.len(), 2, "root() ∩ heads(all()) is empty → plain heads walk");
}

// ── Errors: either parameter; no panic ──────────────────────────────────────

#[test]
fn walk_graph_bogus_revset_returns_parse_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let result = repo.walk_graph("bogus_function()", DEFAULT_GRAPH_PRIORITIZE, |_| {
        ControlFlow::Continue(())
    });
    assert!(
        matches!(result, Err(RevsetError::ParseError { .. })),
        "bogus_function() must return ParseError, got: {result:?}"
    );
}

#[test]
fn walk_graph_bogus_prioritize_returns_parse_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let result = repo.walk_graph("all()", "(", |_| ControlFlow::Continue(()));
    assert!(
        matches!(result, Err(RevsetError::ParseError { .. })),
        "an unbalanced prioritize expression must return ParseError, got: {result:?}"
    );
}

#[test]
fn walk_graph_nonexistent_bookmark_returns_resolution_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let result = repo.walk_graph("nonexistent-bookmark-xyz", DEFAULT_GRAPH_PRIORITIZE, |_| {
        ControlFlow::Continue(())
    });
    assert!(
        matches!(result, Err(RevsetError::ResolutionError { .. })),
        "an unknown symbol must return ResolutionError, got: {result:?}"
    );
}

#[test]
fn walk_graph_on_corrupt_repo_returns_jj_lib_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    // Corrupt AFTER open: walk_graph re-resolves to head on every call (ADR-0002), so
    // removing op_heads makes load_at_head() fail → RevsetError::JjLibError.
    let op_heads = fx.path.join(".jj").join("repo").join("op_heads");
    std::fs::remove_dir_all(&op_heads).unwrap();

    let result = repo.walk_graph("all()", DEFAULT_GRAPH_PRIORITIZE, |_| ControlFlow::Continue(()));
    assert!(
        matches!(result, Err(RevsetError::JjLibError(_))),
        "corrupt op_heads must yield RevsetError::JjLibError, got: {result:?}"
    );
}
