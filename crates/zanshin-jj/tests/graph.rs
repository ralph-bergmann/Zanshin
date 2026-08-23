// SPDX-License-Identifier: MIT

//! Fixture tests for `Repo::walk_graph` (Story 4.3): the revset graph stream contract
//! `zanshin-graph`'s lane assigner relies on — children before parents, every node once,
//! edge kinds as jj-lib classifies them, `jj log` order, re-resolved to head per call.

use std::collections::HashSet;
use std::env;
use std::ops::ControlFlow;
use std::sync::LazyLock;

use test_helpers::{
    abandon_commit, add_commit_off_root, add_conflicted_merge_off_root, add_divergent_twin, add_workspace,
    describe_commit, extract_fixture, set_local_bookmark, set_remote_bookmark, set_tag,
};
use zanshin_jj::{
    resolve_revset, CommitRef, GraphEdgeKind, GraphNode, Repo, RevsetError, DEFAULT_GRAPH_PRIORITIZE,
    DEFAULT_LOG_REVSET,
};

/// The CLI's `revsets.short-prefixes` default (it falls back to `revsets.log`) — what the
/// Dart side pre-fills, so it is what most tests pass.
const SHORT: &str = DEFAULT_LOG_REVSET;

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

/// Collects the whole stream into a Vec (the stream must be exhausted → `Continue`).
fn collect_nodes(repo: &Repo, revset: &str, prioritize: &str) -> Vec<GraphNode> {
    collect_nodes_with(repo, revset, prioritize, SHORT)
}

/// [`collect_nodes`] with an explicit `short_prefixes` expression.
fn collect_nodes_with(repo: &Repo, revset: &str, prioritize: &str, short_prefixes: &str) -> Vec<GraphNode> {
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

/// Hex commit id of the single commit `revset` resolves to — through the public API only.
fn commit_id_of(repo: &Repo, revset: &str) -> String {
    let ids = resolve_revset(repo, revset).unwrap();
    assert_eq!(ids.len(), 1, "{revset} must resolve to exactly one change");
    repo.get_change(&ids[0]).unwrap().commit_id.0
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

fn node_position(nodes: &[GraphNode], id: &str) -> usize {
    nodes.iter().position(|n| n.id.0 == id).unwrap()
}

#[test]
fn walk_graph_prioritize_under_a_merge_cannot_reorder_the_merges_parent_branches() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let tip_a = commit_id_of(&repo, "bookmarks(exact:\"branch-a\")");
    let tip_b = commit_id_of(&repo, "bookmarks(exact:\"branch-b\")");
    let tip_c = commit_id_of(&repo, "bookmarks(exact:\"branch-c\")");

    // Natural order (TopoGroupedGraph): "at merge point, the second (or the last) ancestor
    // branch will be visited first" — the octopus merge's parents are (A, B, C), so C's
    // branch comes first, then B, then A.
    let natural = collect_nodes(&repo, "all()", "none()");
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
    let merged = collect_nodes(&repo, "all()", "bookmarks(exact:\"branch-b\")");
    assert_eq!(
        merged.iter().map(|n| &n.id.0).collect::<Vec<_>>(),
        natural.iter().map(|n| &n.id.0).collect::<Vec<_>>(),
        "a prioritised node under a merge cannot reorder the merge's parent branches"
    );
}

#[test]
fn walk_graph_prioritize_of_a_non_working_copy_head_emits_that_branch_first() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let tip_a = commit_id_of(&repo, "bookmarks(exact:\"branch-a\")");
    let tip_b = commit_id_of(&repo, "bookmarks(exact:\"branch-b\")");
    let tip_c = commit_id_of(&repo, "bookmarks(exact:\"branch-c\")");

    // With the three branch tips as heads (no merge), prioritising branch-b puts B's tip
    // first — before both A's and C's — whereas the natural order starts with C (the first
    // input commit, newest index position).
    let three_heads = "::bookmarks(exact:\"branch-a\") | ::bookmarks(exact:\"branch-b\") \
                       | ::bookmarks(exact:\"branch-c\")";
    let natural = collect_nodes(&repo, three_heads, "none()");
    assert_eq!(natural[0].id.0, tip_c, "natural: C's branch first");
    let prioritized = collect_nodes(&repo, three_heads, "bookmarks(exact:\"branch-b\")");
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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

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
    let wc = commit_id_of(&repo, "@");
    let c3 = commit_id_of(&repo, "description(\"Commit 3\")");

    let nodes = collect_nodes(&repo, "heads(all())", "root()");

    assert_eq!(nodes.len(), 2, "root() ∩ heads(all()) is empty → plain heads walk");
    assert_eq!(nodes[0].id.0, c3, "natural order: the first input commit (c3) leads");
    assert_eq!(nodes[1].id.0, wc, "@ is not forced first without present(@)");
}

// ── Errors: either parameter; no panic ──────────────────────────────────────

#[test]
fn walk_graph_bogus_revset_returns_parse_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let result = repo.walk_graph("all()", "(", SHORT, |_| ControlFlow::Continue(()));
    assert!(
        matches!(result, Err(RevsetError::ParseError { .. })),
        "an unbalanced prioritize expression must return ParseError, got: {result:?}"
    );
}

#[test]
fn walk_graph_blank_prioritize_returns_parse_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    // Corrupt AFTER open: walk_graph re-resolves to head on every call (ADR-0002), so
    // removing op_heads makes load_at_head() fail → RevsetError::JjLibError.
    let op_heads = fx.path.join(".jj").join("repo").join("op_heads");
    std::fs::remove_dir_all(&op_heads).unwrap();

    let result = repo.walk_graph("all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, |_| ControlFlow::Continue(()));
    assert!(
        matches!(result, Err(RevsetError::JjLibError(_))),
        "corrupt op_heads must yield RevsetError::JjLibError, got: {result:?}"
    );
}

#[test]
fn walk_graph_unresolvable_prioritize_returns_resolution_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

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

#[test]
fn walk_graph_mid_stream_store_failure_returns_jj_lib_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    // No commit is read through the handle before the corruption (the store caches commits).
    let repo = Repo::open(&fx.path).unwrap();

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
    std::fs::remove_dir_all(&objects).unwrap();

    let mut visited = 0usize;
    let result = repo.walk_graph("all()", "none()", SHORT, |_| {
        visited += 1;
        ControlFlow::Continue(())
    });
    assert!(
        matches!(result, Err(RevsetError::JjLibError(_))),
        "a commit read failing mid-stream must yield RevsetError::JjLibError, got: {result:?}"
    );
    assert_eq!(visited, 0, "the first item already fails; nothing is visited");
}

// ── Story 4.8: `jj log`-parity metadata on every node ───────────────────────

#[test]
fn walk_graph_metadata_matches_get_change_for_the_same_commit() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let c3 = commit_id_of(&repo, "description(\"Commit 3\")");

    let nodes = collect_nodes(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let root = commit_id_of(&repo, "root()");

    let nodes = collect_nodes(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&repo, "@");

    let nodes = collect_nodes(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    // Parses only because build_aliases_map defines the CLI's builtin [revset-aliases].
    let nodes = collect_nodes(&repo, DEFAULT_LOG_REVSET, DEFAULT_GRAPH_PRIORITIZE);

    assert!(!nodes.is_empty(), "the CLI default log revset selects rows");
}

#[test]
fn walk_graph_shortest_prefix_lengths_are_unique_within_the_fixture() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let nodes = collect_nodes(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

    for node in &nodes {
        let len = usize::try_from(node.meta.commit_id_prefix_len).unwrap();
        assert!(len >= 1 && len <= node.id.0.len(), "1 <= len <= full id, got {len}");
        let prefix = &node.id.0[..len];
        let matches = nodes.iter().filter(|n| n.id.0.starts_with(prefix)).count();
        assert_eq!(matches, 1, "{prefix} must be unique among the fixture's commit ids");

        let change_len = usize::try_from(node.meta.change_id_prefix_len).unwrap();
        assert!(change_len >= 1 && change_len <= node.meta.change_id.len());
    }
}

#[test]
fn walk_graph_empty_short_prefixes_disables_disambiguation_and_never_shortens() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    // "" = disabled (full-index prefixes), NOT a parse error like a blank prioritize.
    let disabled = collect_nodes_with(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE, "");
    // A one-commit disambiguation set is the strongest possible narrowing.
    let narrow = collect_nodes_with(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE, "@");

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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let result = repo.walk_graph("all()", DEFAULT_GRAPH_PRIORITIZE, "bogus_function()", |_| {
        ControlFlow::Continue(())
    });
    assert!(
        matches!(result, Err(RevsetError::ParseError { .. })),
        "a bogus short_prefixes function must return ParseError, got: {result:?}"
    );
}

#[test]
fn walk_graph_unresolvable_short_prefixes_returns_resolution_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    // The CLI hard-errors on a user-typed expression it cannot resolve; only a failure
    // while LOADING the index degrades to a warning (next test).
    let result = repo.walk_graph("all()", DEFAULT_GRAPH_PRIORITIZE, "nonexistent-bookmark-xyz", |_| {
        ControlFlow::Continue(())
    });
    assert!(
        matches!(result, Err(RevsetError::ResolutionError { .. })),
        "an unknown short_prefixes symbol must return ResolutionError, got: {result:?}"
    );
}

#[test]
fn walk_graph_short_prefixes_index_load_failure_degrades_instead_of_erroring() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

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
    std::fs::remove_dir_all(&objects).unwrap();

    let nodes = collect_nodes_with(&repo, "none()", "none()", "description(\"Commit\")");

    assert!(nodes.is_empty(), "the call succeeds; the index load only warned");
}

// ── Story 4.8: edge states, constructed in-test (fixtures are never regenerated) ──

#[test]
fn walk_graph_flags_both_commits_of_a_divergent_change_and_a_hidden_one() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let c1 = commit_id_of(&repo, "description(\"Commit 1\")");
    let twin = add_divergent_twin(&fx.path, &c1, "divergent twin");

    let nodes = collect_nodes(&repo, "all()", "none()");

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
    let hidden_nodes = collect_nodes(&repo, &twin, "none()");
    let hidden = node_of(&hidden_nodes, &twin);
    assert!(hidden.meta.hidden, "an abandoned commit is hidden");
    assert!(!hidden.meta.divergent, "only one visible commit is left");
}

#[test]
fn walk_graph_flags_conflict_and_empty_on_the_right_rows_only() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&repo, "@");
    let c3 = commit_id_of(&repo, "description(\"Commit 3\")");
    let merge = add_conflicted_merge_off_root(&fx.path);

    let nodes = collect_nodes(&repo, "all()", "none()");

    assert!(node_of(&nodes, &merge).meta.conflict, "the merge tree is conflicted");
    assert!(!node_of(&nodes, &c3).meta.conflict, "a plain commit is not");
    assert!(node_of(&nodes, &wc).meta.empty, "@ has no changes of its own");
    assert!(!node_of(&nodes, &c3).meta.empty, "c3 adds a file");
}

#[test]
fn walk_graph_ref_visibility_follows_the_cli_collect_distinct_refs_rule() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let c1 = commit_id_of(&repo, "description(\"Commit 1\")");
    let c2 = commit_id_of(&repo, "description(\"Commit 2\")");
    let c3 = commit_id_of(&repo, "description(\"Commit 3\")");

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

    let nodes = collect_nodes(&repo, "all()", "none()");
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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let default_wc = commit_id_of(&repo, "@");

    let (_second_root, second_wc) = add_workspace(&fx.path, "second");

    let nodes = collect_nodes(&repo, "all()", "none()");

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
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let c3 = commit_id_of(&repo, "description(\"Commit 3\")");
    let before = collect_nodes(&repo, "all()", "none()");
    assert_eq!(node_of(&before, &c3).meta.description_first_line, "Commit 3");

    let rewritten = describe_commit(&fx.path, &c3, "Rewritten by an external op\nsecond line");

    // Same `Repo` handle — no reopen, no cache.
    let after = collect_nodes(&repo, "all()", "none()");
    assert_eq!(
        node_of(&after, &rewritten).meta.description_first_line,
        "Rewritten by an external op",
        "only the FIRST line rides the log row (get_change owns the full text)"
    );
}
