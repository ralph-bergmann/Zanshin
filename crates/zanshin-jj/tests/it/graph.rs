// SPDX-License-Identifier: MIT

//! Fixture tests for `Repo::walk_graph` (Story 4.3): the revset graph stream contract —
//! children before parents, every node once, edge kinds as jj-lib classifies them, `jj log`
//! order, re-resolved to head per call. *(2026-10-01, Story 4.12: the lane crate that relied on
//! this contract is gone; `walk_graph` stays as the `jj log`-faithful read and the oracle of
//! `Repo::graph_topology`.)*

use std::collections::HashSet;
use std::ops::ControlFlow;

use test_helpers::{
    abandon_commit, add_commit_off_root, add_conflicted_merge_off_root, add_divergent_twin, add_unpublished_op,
    add_workspace, describe_commit, extract_fixture, set_local_bookmark, set_remote_bookmark, set_tag,
};
use zanshin_jj::{
    resolve_revset, CommitMeta, CommitRef, GraphEdgeKind, GraphNode, Repo, RevsetError, DEFAULT_GRAPH_PRIORITIZE,
    DEFAULT_LOG_REVSET,
};

/// The CLI's `revsets.short-prefixes` default (it falls back to `revsets.log`) — what the
/// Dart side pre-fills, so it is what most tests pass.
const SHORT: &str = DEFAULT_LOG_REVSET;

/// Collects the whole stream into a Vec (the stream must be exhausted → `Continue`).
fn collect_nodes(repo: &mut Repo, revset: &str, prioritize: &str) -> Vec<GraphNode> {
    collect_nodes_with(repo, revset, prioritize, SHORT)
}

/// [`collect_nodes`] with an explicit `short_prefixes` expression.
fn collect_nodes_with(repo: &mut Repo, revset: &str, prioritize: &str, short_prefixes: &str) -> Vec<GraphNode> {
    let mut nodes = Vec::new();
    let flow = repo
        .walk_graph(revset, prioritize, short_prefixes, |node| {
            nodes.push(node);
            ControlFlow::Continue(())
        })
        .unwrap();
    assert_eq!(flow, ControlFlow::Continue(()), "an unbroken walk must report Continue");
    nodes
}

/// The single node whose commit id is `id`.
fn node_of<'n>(nodes: &'n [GraphNode], id: &str) -> &'n GraphNode {
    nodes.iter().find(|n| n.id.0 == id).expect("node must be in the stream")
}

/// Writes `.jj/repo/config.toml` — the repo config layer of an extracted fixture, which
/// carries no `config-id`, so this legacy path IS the repo layer (Story 4.9).
fn write_repo_config(workspace_root: &std::path::Path, toml: &str) {
    std::fs::write(workspace_root.join(".jj").join("repo").join("config.toml"), toml).unwrap();
}

/// Hex commit id of the single commit `revset` resolves to — through the public API only.
fn commit_id_of(repo: &mut Repo, revset: &str) -> String {
    let ids = resolve_revset(repo, revset).unwrap();
    assert_eq!(ids.len(), 1, "{revset} must resolve to exactly one change");
    repo.get_change(&ids[0]).unwrap().commit_id.0
}

// ── Tiny: node set + CLI-default order (`present(@)` first) ─────────────────

#[test]
fn walk_graph_tiny_all_with_default_prioritize_emits_wc_branch_first_in_log_order() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&mut repo, "@");
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");
    let c2 = commit_id_of(&mut repo, "description(\"Commit 2\")");
    let c1 = commit_id_of(&mut repo, "description(\"Commit 1\")");
    let root = commit_id_of(&mut repo, "root()");

    let nodes = collect_nodes(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

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
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&mut repo, "@");
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");

    let prioritized = collect_nodes(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE);
    let natural = collect_nodes(&mut repo, "all()", "none()");

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
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&mut repo, "@");

    let nodes = collect_nodes(&mut repo, "heads(all())", DEFAULT_GRAPH_PRIORITIZE);

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
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");
    let c2 = commit_id_of(&mut repo, "description(\"Commit 2\")");
    let c1 = commit_id_of(&mut repo, "description(\"Commit 1\")");

    let nodes = collect_nodes(&mut repo, "all() ~ description(\"Commit 2\")", DEFAULT_GRAPH_PRIORITIZE);

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
    test_helpers::pin_test_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&mut repo, "@");

    let nodes = collect_nodes(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

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

fn node_position(nodes: &[GraphNode], id: &str) -> usize {
    nodes.iter().position(|n| n.id.0 == id).unwrap()
}

#[test]
fn walk_graph_prioritize_under_a_merge_cannot_reorder_the_merges_parent_branches() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let tip_a = commit_id_of(&mut repo, "bookmarks(exact:\"branch-a\")");
    let tip_b = commit_id_of(&mut repo, "bookmarks(exact:\"branch-b\")");
    let tip_c = commit_id_of(&mut repo, "bookmarks(exact:\"branch-c\")");

    // Natural order (TopoGroupedGraph): "at merge point, the second (or the last) ancestor
    // branch will be visited first" — the octopus merge's parents are (A, B, C), so C's
    // branch comes first, then B, then A.
    let natural = collect_nodes(&mut repo, "all()", "none()");
    assert!(
        node_position(&natural, &tip_c) < node_position(&natural, &tip_b),
        "C before B"
    );
    assert!(
        node_position(&natural, &tip_b) < node_position(&natural, &tip_a),
        "B before A"
    );

    // Prioritising a non-head node queues its descendants first (jj-lib: "if the specified
    // node isn't a head, all preceding nodes will be queued") — here the trunk above the
    // merge, which is emitted first anyway; below the merge the parent order still rules,
    // so C's tip precedes B's tip exactly as without prioritisation.
    let merged = collect_nodes(&mut repo, "all()", "bookmarks(exact:\"branch-b\")");
    assert_eq!(
        merged.iter().map(|n| &n.id.0).collect::<Vec<_>>(),
        natural.iter().map(|n| &n.id.0).collect::<Vec<_>>(),
        "a prioritised node under a merge cannot reorder the merge's parent branches"
    );
}

#[test]
fn walk_graph_prioritize_of_a_non_working_copy_head_emits_that_branch_first() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let tip_a = commit_id_of(&mut repo, "bookmarks(exact:\"branch-a\")");
    let tip_b = commit_id_of(&mut repo, "bookmarks(exact:\"branch-b\")");
    let tip_c = commit_id_of(&mut repo, "bookmarks(exact:\"branch-c\")");

    // With the three branch tips as heads (no merge), prioritising branch-b puts B's tip
    // first — before both A's and C's — whereas the natural order starts with C (the first
    // input commit, newest index position).
    let three_heads = "::bookmarks(exact:\"branch-a\") | ::bookmarks(exact:\"branch-b\") \
                       | ::bookmarks(exact:\"branch-c\")";
    let natural = collect_nodes(&mut repo, three_heads, "none()");
    assert_eq!(natural[0].id.0, tip_c, "natural: C's branch first");
    let prioritized = collect_nodes(&mut repo, three_heads, "bookmarks(exact:\"branch-b\")");
    assert_eq!(prioritized[0].id.0, tip_b, "prioritised: B's tip is the first node");
    assert!(
        node_position(&prioritized, &tip_b) < node_position(&prioritized, &tip_a),
        "B before A"
    );
    assert!(
        node_position(&prioritized, &tip_b) < node_position(&prioritized, &tip_c),
        "B before C"
    );
}

// ── Streaming shape: early exit, empty set ──────────────────────────────────

#[test]
fn walk_graph_visitor_break_stops_the_stream_and_reports_break() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let mut visited = 0usize;
    let flow = repo
        .walk_graph("all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, |_node| {
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
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let nodes = collect_nodes(&mut repo, "none()", DEFAULT_GRAPH_PRIORITIZE);

    assert!(nodes.is_empty());
}

// ── Re-derive per call (ADR-0002): same handle sees an external operation ───

#[test]
fn walk_graph_rederives_from_head_so_an_external_commit_appears_on_the_next_call() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let before = collect_nodes(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

    let new_id = add_commit_off_root(&fx.path, "external op");

    // Same `Repo` handle — no reopen, no cache.
    let after = collect_nodes(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE);
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
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&mut repo, "@");
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");

    let nodes = collect_nodes(&mut repo, "heads(all())", "root()");

    assert_eq!(nodes.len(), 2, "root() ∩ heads(all()) is empty → plain heads walk");
    assert_eq!(nodes[0].id.0, c3, "natural order: the first input commit (c3) leads");
    assert_eq!(nodes[1].id.0, wc, "@ is not forced first without present(@)");
}

// ── Errors: either parameter; no panic ──────────────────────────────────────

#[test]
fn walk_graph_bogus_revset_returns_parse_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.walk_graph("bogus_function()", DEFAULT_GRAPH_PRIORITIZE, SHORT, |_| {
        ControlFlow::Continue(())
    });
    assert!(
        matches!(result, Err(RevsetError::ParseError { .. })),
        "bogus_function() must return ParseError, got: {result:?}"
    );
}

#[test]
fn walk_graph_bogus_prioritize_returns_parse_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.walk_graph("all()", "(", SHORT, |_| ControlFlow::Continue(()));
    assert!(
        matches!(result, Err(RevsetError::ParseError { .. })),
        "an unbalanced prioritize expression must return ParseError, got: {result:?}"
    );
}

#[test]
fn walk_graph_blank_prioritize_returns_parse_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    // The documented contract: `none()` is the canonical no-prioritization value; an
    // empty/blank expression is a ParseError (as the CLI fails on an empty config value).
    for prioritize in ["", "   "] {
        let result = repo.walk_graph("all()", prioritize, SHORT, |_| ControlFlow::Continue(()));
        assert!(
            matches!(result, Err(RevsetError::ParseError { .. })),
            "a blank prioritize ({prioritize:?}) must return ParseError, got: {result:?}"
        );
    }
}

#[test]
fn walk_graph_nonexistent_bookmark_returns_resolution_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.walk_graph("nonexistent-bookmark-xyz", DEFAULT_GRAPH_PRIORITIZE, SHORT, |_| {
        ControlFlow::Continue(())
    });
    assert!(
        matches!(result, Err(RevsetError::ResolutionError { .. })),
        "an unknown symbol must return ResolutionError, got: {result:?}"
    );
}

#[test]
fn walk_graph_on_corrupt_repo_returns_jj_lib_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    // Corrupt AFTER open: walk_graph re-resolves to head on every call (ADR-0002), so
    // removing op_heads makes load_at_head() fail → RevsetError::JjLibError.
    let op_heads = fx.path.join(".jj").join("repo").join("op_heads");
    std::fs::remove_dir_all(&op_heads).unwrap();

    let result = repo.walk_graph("all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, |_| ControlFlow::Continue(()));
    assert!(
        matches!(result, Err(RevsetError::Precondition(zanshin_jj::PreconditionError::Backend(_)))),
        "the pre-verb snapshot fails first (Story 9.26, as the CLI would): corrupt op_heads must yield RevsetError::JjLibError, got: {result:?}"
    );
}

#[test]
fn walk_graph_unresolvable_prioritize_returns_resolution_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.walk_graph(
        "all()",
        "nonexistent-bookmark-xyz",
        SHORT,
        |_| ControlFlow::Continue(()),
    );
    assert!(
        matches!(result, Err(RevsetError::ResolutionError { .. })),
        "an unknown prioritize symbol must return ResolutionError, got: {result:?}"
    );
}

/// Empties the git object store under an OPEN handle, keeping the directory itself.
///
/// The pre-verb snapshot (Story 9.26) reads `@` and re-opens the git repository (its ignore
/// chain), so a first `status()` warms the store's commit cache with `@` and the `objects`
/// directory survives for the re-open — exactly the shape a CLI command would find on a repo
/// that lost some objects but can still be opened. Every OTHER commit read then fails.
fn empty_object_store(repo: &mut Repo, objects: &std::path::Path) {
    repo.status().expect("the healthy repo snapshots and reads @");
    std::fs::remove_dir_all(objects).unwrap();
    std::fs::create_dir_all(objects).unwrap();
}

#[test]
fn walk_graph_mid_stream_store_failure_returns_jj_lib_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    // No commit is read through the handle before the corruption (the store caches commits).
    let mut repo = Repo::open(&fx.path).unwrap();

    // Corrupt the git object store AFTER open: the index still answers `all()`, but since
    // Story 4.8 every emitted node is loaded (`store.get_commit_async`) to extract its
    // metadata — the CLI's render loop does the same — so the first commit read fails and
    // the walk surfaces it as a per-item stream error. `prioritize = none()` keeps the
    // prioritised-id materialisation from reading `@` first. jj-lib 0.42.0 internals; a pin
    // bump may move where the failure surfaces — re-verify this test then.
    let objects = fx
        .path
        .join(".jj")
        .join("repo")
        .join("store")
        .join("git")
        .join("objects");
    empty_object_store(&mut repo, &objects);

    let mut visited = 0usize;
    let result = repo.walk_graph("all()", "none()", SHORT, |_| {
        visited += 1;
        ControlFlow::Continue(())
    });
    assert!(
        matches!(result, Err(RevsetError::JjLibError(_))),
        "a commit read failing mid-stream must yield RevsetError::JjLibError, got: {result:?}"
    );
    assert!(
        visited < 4,
        "the walk stops at the first unreadable commit, before the fixture's four rows"
    );
}

// ── Story 4.8: `jj log`-parity metadata on every node ───────────────────────

#[test]
fn walk_graph_metadata_matches_get_change_for_the_same_commit() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");

    let nodes = collect_nodes(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

    let node = node_of(&nodes, &c3);
    let change = repo
        .get_change(&zanshin_jj::ChangeId(node.meta.change_id.clone()))
        .expect("the change id the row reports must resolve");
    assert_eq!(
        change.commit_id.0, c3,
        "the row's change id resolves back to the row's commit"
    );
    assert_eq!(node.meta.description_first_line, "Commit 3");
    assert_eq!(node.meta.author_email, change.author.email);
    assert_eq!(node.meta.author_name, change.author.name);
    assert_eq!(
        node.meta.committer_timestamp, change.timestamps.committed_at,
        "the log row shows the COMMITTER timestamp"
    );
    assert!(!node.meta.conflict);
    assert!(!node.meta.hidden);
    assert!(!node.meta.divergent);
}

#[test]
fn walk_graph_root_row_is_root_immutable_and_empty_with_a_fully_populated_payload() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let root = commit_id_of(&mut repo, "root()");

    let nodes = collect_nodes(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

    let node = node_of(&nodes, &root);
    assert!(node.meta.root, "root() is flagged");
    assert!(node.meta.immutable, "root() is always in the immutable set");
    assert!(node.meta.empty, "the root commit has an empty tree");
    assert!(node.meta.description_first_line.is_empty());
    // Uniform payload: the special rendering is the UI's, so the ids are populated here too.
    assert!(!node.meta.change_id.is_empty());
    assert!(node.meta.change_id_prefix_len >= 1);
    assert!(
        nodes.iter().filter(|n| n.meta.root).count() == 1,
        "exactly one root row"
    );
}

#[test]
fn walk_graph_flags_exactly_one_working_copy_and_leaves_it_mutable() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&mut repo, "@");

    let nodes = collect_nodes(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

    let wc_nodes: Vec<&GraphNode> = nodes.iter().filter(|n| n.meta.working_copy).collect();
    assert_eq!(wc_nodes.len(), 1, "exactly one row is this workspace's @");
    assert_eq!(wc_nodes[0].id.0, wc);
    assert!(!wc_nodes[0].meta.immutable, "@ is mutable");
    assert!(
        wc_nodes[0].meta.working_copies.is_empty(),
        "a single-workspace repo shows no workspace markers (the CLI's guard)"
    );
}

#[test]
fn walk_graph_accepts_the_cli_default_log_revset() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    // Parses only because build_aliases_map defines the CLI's builtin [revset-aliases].
    let nodes = collect_nodes(&mut repo, DEFAULT_LOG_REVSET, DEFAULT_GRAPH_PRIORITIZE);

    assert!(!nodes.is_empty(), "the CLI default log revset selects rows");
}

#[test]
fn walk_graph_shortest_prefix_lengths_are_unique_within_the_fixture() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let nodes = collect_nodes(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

    for node in &nodes {
        let len = usize::try_from(node.meta.commit_id_prefix_len).unwrap();
        assert!(len >= 1 && len <= node.id.0.len(), "1 <= len <= full id, got {len}");
        let prefix = &node.id.0[..len];
        let matches = nodes.iter().filter(|n| n.id.0.starts_with(prefix)).count();
        assert_eq!(matches, 1, "{prefix} must be unique among the fixture's commit ids");

        let change_len = usize::try_from(node.meta.change_id_prefix_len).unwrap();
        assert!(change_len >= 1 && change_len <= node.meta.change_id.len());
        // The change id needs the SAME uniqueness proof as the commit id: a bounds check
        // alone cannot tell `shortest_change_prefix_len` apart from the commit-id call it
        // sits next to, nor from a constant.
        let change_prefix = &node.meta.change_id[..change_len];
        let change_matches = nodes
            .iter()
            .filter(|n| n.meta.change_id.starts_with(change_prefix))
            .count();
        assert_eq!(
            change_matches, 1,
            "{change_prefix} must be unique among the fixture's change ids"
        );
    }
}

#[test]
fn walk_graph_empty_short_prefixes_disables_disambiguation_and_never_shortens() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    // "" = disabled (full-index prefixes), NOT a parse error like a blank prioritize.
    let disabled = collect_nodes_with(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE, "");
    // A one-commit disambiguation set is the strongest possible narrowing.
    let narrow = collect_nodes_with(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE, "@");

    assert_eq!(disabled.len(), narrow.len());
    for (off, on) in disabled.iter().zip(&narrow) {
        assert_eq!(off.id.0, on.id.0, "same rows in the same order either way");
        assert!(
            off.meta.commit_id_prefix_len >= on.meta.commit_id_prefix_len,
            "the full index can never give a SHORTER prefix than a narrowed set"
        );
    }
    assert!(
        disabled
            .iter()
            .zip(&narrow)
            .any(|(off, on)| off.meta.commit_id_prefix_len > on.meta.commit_id_prefix_len),
        "on a 1k-commit fixture at least one id must shorten inside the narrowed set"
    );
}

#[test]
fn walk_graph_bogus_short_prefixes_returns_parse_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.walk_graph("all()", DEFAULT_GRAPH_PRIORITIZE, "bogus_function()", |_| {
        ControlFlow::Continue(())
    });
    assert!(
        matches!(result, Err(RevsetError::ParseError { .. })),
        "a bogus short_prefixes function must return ParseError, got: {result:?}"
    );
}

#[test]
fn walk_graph_unresolvable_short_prefixes_degrades_to_full_index_prefixes() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    // Symbol resolution of short_prefixes happens while LOADING the disambiguation index,
    // so — unlike revset/prioritize — an unknown symbol only warns and degrades. Pinned by
    // jj's own cli/tests/test_log_command.rs::test_log_bad_short_prefixes @ v0.42.0:
    // `revsets.short-prefixes = 'missing'` warns and still renders the whole log at exit 0.
    let degraded = collect_nodes_with(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE, "nonexistent-bookmark-xyz");
    // Story 9.32: the CLI's warning, with the resolution failure as its source chain.
    let warnings = repo.take_warnings();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, zanshin_jj::WarningKind::ShortPrefixesFailed);
    assert!(
        warnings[0]
            .message
            .starts_with("In template expression\nFailed to load short-prefixes index\n")
            && warnings[0].message.contains("nonexistent-bookmark-xyz"),
        "{}",
        warnings[0].message
    );
    let disabled = collect_nodes_with(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE, "");
    assert!(
        repo.take_warnings().is_empty(),
        "disabled disambiguation warns about nothing"
    );

    assert_eq!(degraded.len(), 5, "the call succeeds with the full row set");
    assert_eq!(degraded.len(), disabled.len());
    for (warned, full_index) in degraded.iter().zip(&disabled) {
        assert_eq!(warned.id.0, full_index.id.0, "same rows in the same order");
        assert_eq!(
            (warned.meta.commit_id_prefix_len, warned.meta.change_id_prefix_len),
            (
                full_index.meta.commit_id_prefix_len,
                full_index.meta.change_id_prefix_len
            ),
            "degrading falls back to exactly the full-index lengths"
        );
    }
}

#[test]
fn walk_graph_short_prefixes_index_load_failure_degrades_instead_of_erroring() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    // A `description()` filter reads every commit while the disambiguation index is
    // collected, so a corrupt object store makes `populate()` fail. The CLI warns and falls
    // back to full-index prefixes rather than failing the command — an empty `revset` keeps
    // the walk itself off the corrupt objects so only the degradation is observed.
    let objects = fx
        .path
        .join(".jj")
        .join("repo")
        .join("store")
        .join("git")
        .join("objects");
    empty_object_store(&mut repo, &objects);

    let nodes = collect_nodes_with(&mut repo, "none()", "none()", "description(\"Commit\")");

    assert!(nodes.is_empty(), "the call succeeds; the index load only warned");
}

// ── Story 4.8 (CAP-1): committed CLI golden parity ─────────────────────────

/// Reconstructs the jj CLI's `builtin_log_compact` row for one commit from `CommitMeta`
/// ALONE — the proof that the payload carries everything `jj log` prints.
///
/// Mirrors `cli/src/config/templates.toml` @ v0.42.0 verbatim:
/// `builtin_log_compact` → `format_root_commit` for the root, otherwise
/// `format_short_commit_header ++ "\n"` then
/// `separate(" ", if(empty) empty_commit_marker, description.first_line() or
/// description_placeholder)`. `separate(" ", …)` drops empty items, which is why the
/// absent refs contribute nothing.
fn cli_row(meta: &CommitMeta, commit_id: &str) -> String {
    // 'format_short_id(id)' = 'id.shortest(8)' — at least 8 chars, more only when the
    // unique prefix is longer. NOTE: because of that 8-char floor this rendering is
    // INSENSITIVE to any prefix length <= 8, which is every length both fixtures produce.
    // It proves the row layout and the fields around the ids; the prefix lengths
    // themselves are pinned by walk_graph_shortest_prefix_lengths_are_unique_within_the_fixture.
    let short = |id: &str, prefix_len: u32| -> String {
        let len = usize::try_from(prefix_len).unwrap().max(8).min(id.len());
        id[..len].to_owned()
    };
    let short_change = short(&meta.change_id, meta.change_id_prefix_len);
    let short_commit = short(commit_id, meta.commit_id_prefix_len);
    let refs = |entries: &[CommitRef]| -> Vec<String> { entries.iter().map(cli_ref).collect() };

    if meta.root {
        // 'format_root_commit(root)' = separate(" ", change id, "root()", commit id, bookmarks)
        let mut parts = vec![short_change, "root()".to_owned(), short_commit];
        parts.extend(refs(&meta.bookmarks));
        return separate(&parts);
    }

    // 'format_short_change_id_with_change_offset': hidden overrides divergent; the offset
    // rides along only for those two.
    let change_field = if meta.hidden || meta.divergent {
        match meta.change_offset {
            Some(offset) => format!("{short_change}/{offset}"),
            None => short_change,
        }
    } else {
        short_change
    };
    // 'format_short_signature(signature)' = 'coalesce(signature.email(), email_placeholder)'
    let author = if meta.author_email.is_empty() {
        "(no email set)".to_owned()
    } else {
        meta.author_email.clone()
    };
    // 'format_commit_labels(commit)' — hidden overrides divergent, then conflict.
    let mut labels: Vec<String> = Vec::new();
    if meta.hidden {
        labels.push("(hidden)".to_owned());
    } else if meta.divergent {
        labels.push("(divergent)".to_owned());
    }
    if meta.conflict {
        labels.push("(conflict)".to_owned());
    }

    let mut header = vec![change_field, author, cli_timestamp(meta)];
    header.extend(refs(&meta.bookmarks));
    header.extend(refs(&meta.tags));
    // 'impl Template for WorkspaceRef' writes "{name}@".
    header.extend(meta.working_copies.iter().map(|name| format!("{name}@")));
    header.push(short_commit);
    header.extend(labels);

    let mut second = Vec::new();
    if meta.empty {
        second.push("(empty)".to_owned()); // empty_commit_marker
    }
    second.push(if meta.description_first_line.is_empty() {
        "(no description set)".to_owned() // description_placeholder
    } else {
        meta.description_first_line.clone()
    });

    format!("{}\n{}", separate(&header), separate(&second))
}

/// `impl Template for Rc<CommitRef>` (`cli/src/commit_templater.rs:1733-1748`): name, then
/// `@remote` for a remote entry, then `??` when conflicted or `*` when a local entry is not
/// synced ("Don't show both conflict and unsynced sigils").
fn cli_ref(r: &CommitRef) -> String {
    let mut out = r.name.clone();
    if let Some(remote) = &r.remote {
        out.push('@');
        out.push_str(remote);
    }
    if r.conflicted {
        out.push_str("??");
    } else if r.remote.is_none() && !r.synced {
        out.push('*');
    }
    out
}

/// `'format_timestamp(timestamp)' = 'timestamp.local().format("%Y-%m-%d %H:%M:%S")'`, with
/// the ONE deliberate difference recorded on the golden test below: we render in the
/// commit's OWN stored offset, not the viewer's local zone.
fn cli_timestamp(meta: &CommitMeta) -> String {
    let offset = chrono::FixedOffset::east_opt(meta.committer_timestamp.tz_offset_minutes * 60)
        .expect("a jj tz_offset is within a day");
    chrono::DateTime::from_timestamp_millis(meta.committer_timestamp.millis_since_epoch)
        .expect("a jj timestamp is representable")
        .with_timezone(&offset)
        .format("%Y-%m-%d %H:%M:%S")
        .to_string()
}

/// `separate(" ", …)` — joins with a space, skipping empty items.
fn separate(parts: &[String]) -> String {
    parts
        .iter()
        .filter(|p| !p.is_empty())
        .cloned()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Golden CLI parity: every row of `tiny-3-commits`, reconstructed from `CommitMeta` alone,
/// equals what `jj log` prints (`builtin_log_compact`, the `templates.log` default).
///
/// **Oracle provenance.** The expected strings were captured at authoring time by running
/// the locally installed `jj` binary against an EXTRACTED COPY of the fixture in a temp dir
/// (never the committed archive), with `JJ_CONFIG=""`, `GIT_CONFIG_GLOBAL=""` and `TZ=UTC`:
///
/// ```text
/// @  sryyqqkq fixture@zanshin.test 2026-06-14 18:24:47 6bfb7ef5
/// │  (empty) (no description set)
/// │ ○  xtozqkmp fixture@zanshin.test 2001-09-09 01:49:40 c606753c
/// │ │  Commit 3
/// │ ○  vwqqlvkw fixture@zanshin.test 2001-09-09 01:48:40 32bf1527
/// │ │  Commit 2
/// │ ○  pxnqtknr fixture@zanshin.test 2001-09-09 01:47:40 2eb4ea06
/// ├─╯  Commit 1
/// ◆  zzzzzzzz root() 00000000
/// ```
///
/// The local binary is **0.44.0**, which as of Story 9.0a MATCHES the pinned `jj-lib =0.44.0`,
/// so it is a directly sound oracle — no cross-version argument is needed. (Before that bump the
/// pin was 0.42.0 and this note carried one, scoped to the LOG-RENDERING surface these
/// expectations depend on: across `git -C ../jj diff v0.42.0 v0.44.0 --
/// cli/src/config/templates.toml cli/src/commit_templater.rs`, `builtin_log_compact`,
/// `format_short_commit_header`, `format_root_commit`,
/// `format_short_change_id_with_change_offset`, `format_commit_labels` and every
/// `commit_templater` parity function were byte-identical, `templates.toml` differing only in
/// `workspace_list`. That argument never covered `revsets.toml` / `misc.toml`, which DID change
/// across the pair — see the revset-language deltas documented in `src/revset.rs` — but those
/// files drive revset resolution, not row rendering.) If the pin moves again, re-anchor that diff
/// to the new tag pair and re-confirm before trusting a locally-generated expectation.
///
/// **The one deliberate difference: the timestamp zone.** The CLI's `format_timestamp` is
/// `timestamp.local()` — the VIEWER's zone — so its rendering is machine-dependent (the same
/// fixture prints `03:49:40` on a UTC+2 machine and `01:49:40` under `TZ=UTC`). We ship
/// millis + the commit's stored `tz_offset` and let the UI localise
/// (`cli-log-parity.md` § Row model), so this reconstruction renders in the commit's OWN
/// stored zone. For the four offset-0 commits that is byte-identical to the `TZ=UTC` capture
/// above; for `@` (stored offset +120) it is `20:24:47`, which is what the CLI prints for a
/// viewer in the commit's own zone.
///
/// The graph glyphs (`@`/`○`/`◆`/`│`/`├─╯`) are NOT part of the payload — the backend ships
/// flags, the UI picks glyphs (`cli-log-parity.md` § Node-flag priority).
#[test]
fn golden_cli_log_compact_rows_reconstruct_from_metadata_alone() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let nodes = collect_nodes(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

    let rendered: Vec<String> = nodes.iter().map(|n| cli_row(&n.meta, &n.id.0)).collect();
    assert_eq!(
        rendered,
        vec![
            "sryyqqkq fixture@zanshin.test 2026-06-14 20:24:47 6bfb7ef5\n(empty) (no description set)",
            "xtozqkmp fixture@zanshin.test 2001-09-09 01:49:40 c606753c\nCommit 3",
            "vwqqlvkw fixture@zanshin.test 2001-09-09 01:48:40 32bf1527\nCommit 2",
            "pxnqtknr fixture@zanshin.test 2001-09-09 01:47:40 2eb4ea06\nCommit 1",
            "zzzzzzzz root() 00000000",
        ],
        "the reconstructed rows must equal jj v0.42.0's builtin_log_compact output"
    );
}

/// Golden CLI parity for the ref sigils, over the in-test ref states (the fixtures carry no
/// remote bookmarks at all).
///
/// **Oracle provenance.** Captured at authoring time by driving the real `jj` binary on a
/// throwaway colocated repo with a local bare remote (`git init --bare`; no network), where
/// `synced` is pushed and left alone, `unsynced`'s local is moved ahead of its tracked
/// remote, and `untracked@origin` is untracked and its local deleted:
///
/// ```text
/// @  quxkmrsu t@e … unsynced* 3fefb9aa
/// │  (empty) ahead
/// ○  pktkwwos t@e … 900c96bb
/// │  (empty) (no description set)
/// ◆  wrozztrv t@e … synced unsynced@origin untracked@origin e10302bd
/// │  (empty) base
/// ◆  zzzzzzzz root() 00000000
/// ```
///
/// That pins four of the five rules directly: `name*` on the local ahead of its tracked
/// remote, `name@remote` for the tracked-but-unsynced remote entry, `name@remote` for the
/// untracked one, and a tracked-AND-synced remote entry rendered NOWHERE (`synced` appears
/// once, bare). The fifth — `name??` for a conflicted local, which suppresses the `*` —
/// comes from `impl Template for Rc<CommitRef>` (`cli/src/commit_templater.rs:1733-1748`
/// @ v0.42.0, "Don't show both conflict and unsynced sigils"); a conflicted bookmark cannot
/// be produced through the CLI without a real divergent fetch.
#[test]
fn golden_cli_ref_sigils_render_from_the_shipped_commit_refs() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c1 = commit_id_of(&mut repo, "description(\"Commit 1\")");
    let c2 = commit_id_of(&mut repo, "description(\"Commit 2\")");
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");

    set_local_bookmark(&fx.path, "synced", &[&c1]);
    set_remote_bookmark(&fx.path, "synced", "origin", &c1, true);
    set_local_bookmark(&fx.path, "unsynced", &[&c2]);
    set_remote_bookmark(&fx.path, "unsynced", "origin", &c3, true);
    set_remote_bookmark(&fx.path, "untracked", "origin", &c3, false);
    set_local_bookmark(&fx.path, "conflicted", &[&c2, &c3]);
    set_tag(&fx.path, "v1", &[&c1]);

    let nodes = collect_nodes(&mut repo, "all()", "none()");
    let header = |id: &str| -> String {
        cli_row(&node_of(&nodes, id).meta, id)
            .lines()
            .next()
            .expect("a commit row has a header line")
            .to_owned()
    };

    assert_eq!(
        header(&c1),
        "pxnqtknr fixture@zanshin.test 2001-09-09 01:47:40 synced v1 2eb4ea06",
        "a tracked-AND-synced remote entry is suppressed; the tag follows the bookmarks"
    );
    assert_eq!(
        header(&c2),
        "vwqqlvkw fixture@zanshin.test 2001-09-09 01:48:40 conflicted?? unsynced* 32bf1527",
        "?? for the conflicted local, * for the local that is ahead of its tracked remote"
    );
    assert_eq!(
        header(&c3),
        "xtozqkmp fixture@zanshin.test 2001-09-09 01:49:40 conflicted?? unsynced@origin \
         untracked@origin c606753c",
        "the tracked-but-unsynced and the untracked remote entries both render"
    );
}

// ── Story 4.8 (CAP-4): the builtin aliases beyond their degenerate fallback ──

/// The fixtures carry no remote bookmarks, so `trunk()` collapses to its `root()` fallback
/// everywhere else in the suite — which would keep passing if the six
/// `remote_bookmarks(exact:<name>, exact:<remote>)` terms were wrong. Construct the real
/// case in-test: only `origin` and `upstream` count, and the argument order is
/// (bookmark, remote).
#[test]
fn trunk_alias_resolves_a_main_bookmark_on_origin_and_ignores_other_remotes() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c2 = commit_id_of(&mut repo, "description(\"Commit 2\")");
    let root_change = resolve_revset(&repo, "root()").unwrap();

    // A remote that is neither origin nor upstream must NOT satisfy trunk().
    set_remote_bookmark(&fx.path, "main", "fork", &c2, false);
    assert_eq!(
        resolve_revset(&repo, "trunk()").unwrap(),
        root_change,
        "main@fork is not one of the six builtin terms; trunk() stays at its root() fallback"
    );

    // main@origin is, and latest() picks it over the root commit.
    set_remote_bookmark(&fx.path, "main", "origin", &c2, true);
    let trunk = resolve_revset(&repo, "trunk()").unwrap();
    assert_eq!(trunk.len(), 1);
    assert_eq!(
        repo.get_change(&trunk[0]).unwrap().commit_id.0,
        c2,
        "trunk() resolves to main@origin"
    );
}

/// `builtin_immutable_heads()` = `trunk() | tags() | untracked_remote_bookmarks() |
/// untracked_remote_tags()` degenerates to `root()` on both fixtures, so every other `immutable == true` assertion is
/// on the root commit and would survive dropping `.ancestors()` — or `immutable_heads()`
/// itself. A tag makes the set non-degenerate and pins the ancestry semantics Story 4.9's
/// config layer must preserve.
#[test]
fn walk_graph_immutable_covers_the_ancestry_of_every_immutable_head() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&mut repo, "@");
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");
    let c2 = commit_id_of(&mut repo, "description(\"Commit 2\")");
    let c1 = commit_id_of(&mut repo, "description(\"Commit 1\")");
    let root = commit_id_of(&mut repo, "root()");

    // Before: nothing but the root is immutable (the degenerate case).
    let before = collect_nodes(&mut repo, "all()", "none()");
    assert_eq!(
        before.iter().filter(|n| n.meta.immutable).count(),
        1,
        "only root() is immutable while immutable_heads() degenerates"
    );

    set_tag(&fx.path, "v1", &[&c2]);

    let after = collect_nodes(&mut repo, "all()", "none()");
    for id in [&c2, &c1, &root] {
        assert!(
            node_of(&after, id).meta.immutable,
            "{id} is the tagged head or one of its ancestors"
        );
    }
    for id in [&c3, &wc] {
        assert!(
            !node_of(&after, id).meta.immutable,
            "{id} is outside ::(immutable_heads() | root())"
        );
    }
}

/// Story 4.9: an `immutable_heads()` override in the repo config moves the ◆ set, with no
/// plumbing beyond the config-fed alias map — that is exactly why Story 4.8 built the
/// immutable expression in code (`parse("immutable_heads()") | root()` then `.ancestors()`)
/// instead of from the `immutable()` alias.
///
/// It also re-proves the no-caching rule: all three reads use the SAME handle.
#[test]
fn an_immutable_heads_override_in_the_repo_config_moves_the_immutable_set() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let root = commit_id_of(&mut repo, "root()");

    let before = collect_nodes(&mut repo, "all()", "none()");
    assert_eq!(
        before.iter().filter(|n| n.meta.immutable).count(),
        1,
        "only root() is immutable while immutable_heads() degenerates"
    );

    write_repo_config(&fx.path, "[revset-aliases]\n'immutable_heads()' = 'all()'\n");
    let all_immutable = collect_nodes(&mut repo, "all()", "none()");
    assert_eq!(all_immutable.len(), before.len(), "the row set itself is unchanged");
    assert!(
        all_immutable.iter().all(|n| n.meta.immutable),
        "immutable_heads() = all() must flip every row to immutable"
    );

    write_repo_config(&fx.path, "[revset-aliases]\n'immutable_heads()' = 'none()'\n");
    let only_root = collect_nodes(&mut repo, "all()", "none()");
    let immutable: Vec<&str> = only_root
        .iter()
        .filter(|n| n.meta.immutable)
        .map(|n| n.id.0.as_str())
        .collect();
    assert_eq!(
        immutable,
        vec![root.as_str()],
        "immutable_heads() = none() leaves only root(), which the in-code `| root()` union pins"
    );
}

/// Story 4.9 / CAP-1: an alias override changes the DEFAULT VIEW's contents, not just the
/// ◆ flag.
///
/// `DEFAULT_LOG_REVSET` is `present(@) | ancestors(immutable_heads().., 2) | trunk()`, so
/// `immutable_heads()` decides where the two-generation window starts. Moving it off
/// `root()` drops the rows that fall outside that window — the row set a user would
/// actually see in `jj log`, which the `all()`-based ◆ test deliberately holds constant.
#[test]
fn an_alias_override_changes_the_default_log_views_row_set() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c1 = commit_id_of(&mut repo, "description(\"Commit 1\")");
    let c2 = commit_id_of(&mut repo, "description(\"Commit 2\")");
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");

    let ids = |nodes: &[GraphNode]| -> HashSet<String> { nodes.iter().map(|n| n.id.0.clone()).collect() };

    // Builtin: immutable_heads() degenerates to root(), so the window spans everything.
    let before = ids(&collect_nodes(&mut repo, DEFAULT_LOG_REVSET, DEFAULT_GRAPH_PRIORITIZE));
    assert!(before.contains(&c1), "the default view starts out showing Commit 1");

    // Override: the window now starts at Commit 2, so Commit 1 falls out of it.
    write_repo_config(
        &fx.path,
        "[revset-aliases]\n'immutable_heads()' = 'description(\"Commit 2\")'\n",
    );
    let after = ids(&collect_nodes(&mut repo, DEFAULT_LOG_REVSET, DEFAULT_GRAPH_PRIORITIZE));

    assert!(
        !after.contains(&c1),
        "Commit 1 is outside ancestors(immutable_heads().., 2) once the alias moves"
    );
    assert!(
        after.contains(&c2) && after.contains(&c3),
        "the window itself still shows"
    );
    assert!(
        after.len() < before.len(),
        "the default view's row set must actually shrink: {} -> {}",
        before.len(),
        after.len()
    );
}

/// Story 4.9: a repo-config alias override reaches the graph walk's own expressions —
/// `revset`, `prioritize` and `short_prefixes` all parse against the same config-fed map.
#[test]
fn walk_graph_expressions_resolve_repo_config_aliases() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c2 = commit_id_of(&mut repo, "description(\"Commit 2\")");

    // Before the override `wip()` is an unknown function in every position.
    assert!(matches!(
        repo.walk_graph("wip()", "none()", "", |_| ControlFlow::Continue(())),
        Err(RevsetError::ParseError { .. })
    ));

    write_repo_config(&fx.path, "[revset-aliases]\n'wip()' = 'description(\"Commit 2\")'\n");

    let rows = collect_nodes_with(&mut repo, "wip()", "wip()", "wip()");
    assert_eq!(rows.len(), 1, "wip() selects exactly one row");
    assert_eq!(rows[0].id.0, c2);
}

// ── Story 4.8: edge states, constructed in-test (fixtures are never regenerated) ──

#[test]
fn walk_graph_flags_both_commits_of_a_divergent_change_and_a_hidden_one() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c1 = commit_id_of(&mut repo, "description(\"Commit 1\")");
    let twin = add_divergent_twin(&fx.path, &c1, "divergent twin");

    let nodes = collect_nodes(&mut repo, "all()", "none()");

    for id in [&c1, &twin] {
        let node = node_of(&nodes, id);
        assert!(node.meta.divergent, "{id} is one of two visible commits of its change");
        assert!(!node.meta.hidden);
        assert!(
            node.meta.change_offset.is_some(),
            "jj-lib yields an offset for a change with several targets"
        );
    }
    assert_eq!(
        node_of(&nodes, &c1).meta.change_id,
        node_of(&nodes, &twin).meta.change_id,
        "a divergent change shares one change id across two commit rows"
    );

    // Abandoning the twin hides it: it is only reachable by naming its id explicitly.
    abandon_commit(&fx.path, &twin);
    let hidden_nodes = collect_nodes(&mut repo, &twin, "none()");
    let hidden = node_of(&hidden_nodes, &twin);
    assert!(hidden.meta.hidden, "an abandoned commit is hidden");
    assert!(!hidden.meta.divergent, "only one visible commit is left");
}

#[test]
fn walk_graph_flags_conflict_and_empty_on_the_right_rows_only() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&mut repo, "@");
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");
    let merge = add_conflicted_merge_off_root(&fx.path);

    let nodes = collect_nodes(&mut repo, "all()", "none()");

    assert!(node_of(&nodes, &merge).meta.conflict, "the merge tree is conflicted");
    assert!(!node_of(&nodes, &c3).meta.conflict, "a plain commit is not");
    assert!(node_of(&nodes, &wc).meta.empty, "@ has no changes of its own");
    assert!(!node_of(&nodes, &c3).meta.empty, "c3 adds a file");
}

#[test]
fn walk_graph_ref_visibility_follows_the_cli_collect_distinct_refs_rule() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c1 = commit_id_of(&mut repo, "description(\"Commit 1\")");
    let c2 = commit_id_of(&mut repo, "description(\"Commit 2\")");
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");

    // synced: local and tracked remote agree → the remote entry is suppressed.
    set_local_bookmark(&fx.path, "synced", &[&c1]);
    set_remote_bookmark(&fx.path, "synced", "origin", &c1, true);
    // unsynced: tracked remote disagrees with the local → both entries show.
    set_local_bookmark(&fx.path, "unsynced", &[&c2]);
    set_remote_bookmark(&fx.path, "unsynced", "origin", &c3, true);
    // untracked: no local counterpart → the remote entry shows.
    set_remote_bookmark(&fx.path, "untracked", "origin", &c3, false);
    // conflicted local bookmark (two added targets).
    set_local_bookmark(&fx.path, "conflicted", &[&c2, &c3]);
    set_tag(&fx.path, "v1", &[&c1]);

    let nodes = collect_nodes(&mut repo, "all()", "none()");
    let named = |id: &str, name: &str| -> Vec<CommitRef> {
        node_of(&nodes, id)
            .meta
            .bookmarks
            .iter()
            .filter(|b| b.name == name)
            .cloned()
            .collect()
    };

    let synced = named(&c1, "synced");
    assert_eq!(synced.len(), 1, "the tracked-and-synced remote entry is suppressed");
    assert_eq!(synced[0].remote, None);
    assert!(synced[0].synced, "the local entry is in sync with its remote");

    let unsynced_local = named(&c2, "unsynced");
    assert_eq!(unsynced_local.len(), 1);
    assert!(!unsynced_local[0].synced, "the local entry renders the `*` sigil");
    let unsynced_remote = named(&c3, "unsynced");
    assert_eq!(unsynced_remote.len(), 1, "a tracked-but-unsynced remote entry shows");
    assert_eq!(unsynced_remote[0].remote.as_deref(), Some("origin"));

    let untracked = named(&c3, "untracked");
    assert_eq!(untracked.len(), 1, "an untracked remote entry shows");
    assert_eq!(untracked[0].remote.as_deref(), Some("origin"));

    // A conflicted local bookmark lands on every added target and is flagged.
    for id in [&c2, &c3] {
        let conflicted = named(id, "conflicted");
        assert_eq!(conflicted.len(), 1, "the conflicted bookmark is listed on {id}");
        assert!(conflicted[0].conflicted, "the `??` sigil comes from this flag");
    }

    let tags = &node_of(&nodes, &c1).meta.tags;
    assert_eq!(tags.len(), 1);
    assert_eq!(tags[0].name, "v1");
    assert_eq!(tags[0].remote, None);
    assert!(
        node_of(&nodes, &c2).meta.tags.is_empty(),
        "tags only land on their target"
    );
}

#[test]
fn walk_graph_lists_every_workspace_working_copy_in_a_multi_workspace_repo() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let default_wc = commit_id_of(&mut repo, "@");

    let (_second_root, second_wc) = add_workspace(&fx.path, "second");

    let nodes = collect_nodes(&mut repo, "all()", "none()");

    assert_eq!(
        node_of(&nodes, &default_wc).meta.working_copies,
        vec!["default".to_string()],
        "the guard lifts once a second workspace exists — including for this workspace"
    );
    assert_eq!(
        node_of(&nodes, &second_wc).meta.working_copies,
        vec!["second".to_string()]
    );
    assert!(
        node_of(&nodes, &default_wc).meta.working_copy,
        "only the CURRENT workspace's @ carries the working_copy flag"
    );
    assert!(!node_of(&nodes, &second_wc).meta.working_copy);
}

#[test]
fn walk_graph_rederives_metadata_so_an_external_describe_is_visible_on_the_next_call() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");
    let before = collect_nodes(&mut repo, "all()", "none()");
    assert_eq!(node_of(&before, &c3).meta.description_first_line, "Commit 3");

    let rewritten = describe_commit(&fx.path, &c3, "Rewritten by an external op\nsecond line");

    // Same `Repo` handle — no reopen, no cache.
    let after = collect_nodes(&mut repo, "all()", "none()");
    assert_eq!(
        node_of(&after, &rewritten).meta.description_first_line,
        "Rewritten by an external op",
        "only the FIRST line rides the log row (get_change owns the full text)"
    );
}

// ── at_operation() over a sibling operation (Story 9.42) ─────────────────────

/// `at_operation()` of an operation that is no ancestor of the head: its commits are in no head
/// index, so the set is evaluated against the merged index as `jj log` does — every row of that
/// operation's `all()`, its own commits hidden at the head, the merge's two edges intact.
#[test]
fn walk_graph_at_operation_of_a_sibling_op_returns_its_rows_with_its_commits_hidden() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let head_all: HashSet<String> = collect_nodes(&mut repo, "all()", "none()")
        .into_iter()
        .map(|n| n.id.0)
        .collect();
    let (op, sibling) = add_unpublished_op(&fx.path, "sibling");

    let nodes = collect_nodes(
        &mut repo,
        &format!("at_operation({op}, all())"),
        DEFAULT_GRAPH_PRIORITIZE,
    );

    let ids: HashSet<String> = nodes.iter().map(|n| n.id.0.clone()).collect();
    let expected: HashSet<String> = head_all.iter().chain(&sibling).cloned().collect();
    assert_eq!(
        ids, expected,
        "the sibling op's all() = the head's commits + its own three"
    );
    assert_eq!(nodes.len(), expected.len(), "every node once");
    for node in &nodes {
        assert_eq!(
            node.meta.hidden,
            sibling.contains(&node.id.0),
            "{} is hidden iff it exists only at the sibling op",
            node.id.0
        );
    }
    let merge = node_of(&nodes, &sibling[2]);
    let targets: HashSet<&str> = merge.parents.iter().map(|e| e.target.0.as_str()).collect();
    assert_eq!(targets, HashSet::from([sibling[0].as_str(), sibling[1].as_str()]));
    assert!(merge.parents.iter().all(|e| e.kind == GraphEdgeKind::Direct));
    // The CLI prints "(empty)" for the two root children, and for the merge — whose emptiness
    // jj-lib cannot compute in the head's index — an inline template error instead.
    assert!(node_of(&nodes, &sibling[0]).meta.empty && node_of(&nodes, &sibling[1]).meta.empty);
    assert!(!merge.meta.empty);
}

#[test]
fn walk_graph_at_operation_of_an_unknown_op_returns_resolution_error() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = repo.walk_graph(
        "at_operation(ffffffffffff, all())",
        DEFAULT_GRAPH_PRIORITIZE,
        SHORT,
        |_| ControlFlow::Continue(()),
    );
    assert!(
        matches!(result, Err(RevsetError::ResolutionError { .. })),
        "an unknown operation must return ResolutionError, got: {result:?}"
    );
}
