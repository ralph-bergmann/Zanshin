// SPDX-License-Identifier: MIT

//! End-to-end tests for `collect_lanes` (Story 4.4): the return-all wrapper over the 4.3
//! lane stream, exercised on the committed fixtures through the public API only.

use std::collections::HashSet;
use std::env;
use std::ops::ControlFlow;
use std::sync::LazyLock;

use test_helpers::extract_fixture;
use zanshin_graph::{collect_lanes, stream_lanes, EdgeKind, LaneStreamError, Row, RowEdge, PALETTE_SIZE};
use zanshin_jj::{resolve_revset, Repo, RevsetError, DEFAULT_GRAPH_PRIORITIZE};

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

/// The reference collection: `stream_lanes` driven to exhaustion by a hand-written sink.
fn collect_rows(repo: &Repo, revset: &str, prioritize: &str) -> Vec<Row> {
    let mut rows = Vec::new();
    let flow = stream_lanes(repo, revset, prioritize, |row| {
        rows.push(row);
        ControlFlow::Continue(())
    })
    .unwrap();
    assert_eq!(
        flow,
        ControlFlow::Continue(()),
        "an unbroken stream must report Continue"
    );
    rows
}

/// Hex commit id of the single commit `revset` resolves to — through the public API only.
fn commit_id_of(repo: &Repo, revset: &str) -> String {
    let ids = resolve_revset(repo, revset).unwrap();
    assert_eq!(ids.len(), 1, "{revset} must resolve to exactly one change");
    repo.get_change(&ids[0]).unwrap().commit_id.0
}

/// Builds the expected `Row` from a compact `(target, target_lane, kind)` edge list.
fn row(commit_id: &str, lane: u32, edges: &[(&str, Option<u32>, EdgeKind)]) -> Row {
    Row {
        commit_id: commit_id.to_string(),
        lane,
        color_idx: lane % PALETTE_SIZE,
        edges: edges
            .iter()
            .map(|(target, target_lane, kind)| RowEdge {
                target: (*target).to_string(),
                target_lane: *target_lane,
                kind: *kind,
            })
            .collect(),
    }
}

// ── Tiny: exact rows + equality with the stream ─────────────────────────────

#[test]
fn collect_lanes_tiny_all_with_default_prioritize_yields_hand_traced_rows_in_log_order() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&repo, "@");
    let c3 = commit_id_of(&repo, "description(\"Commit 3\")");
    let c2 = commit_id_of(&repo, "description(\"Commit 2\")");
    let c1 = commit_id_of(&repo, "description(\"Commit 1\")");
    let root = commit_id_of(&repo, "root()");

    let rows = collect_lanes(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE).unwrap();

    assert_eq!(
        rows,
        vec![
            row(&wc, 0, &[(&root, Some(0), EdgeKind::Direct)]),
            row(&c3, 1, &[(&c2, Some(1), EdgeKind::Direct)]),
            row(&c2, 1, &[(&c1, Some(1), EdgeKind::Direct)]),
            row(&c1, 1, &[(&root, Some(1), EdgeKind::Direct)]),
            row(&root, 0, &[]),
        ]
    );
    assert_eq!(
        rows,
        collect_rows(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE),
        "collect_lanes returns exactly what stream_lanes pushes, in the same order"
    );
}

#[test]
fn collect_lanes_tiny_all_without_prioritize_honours_the_parameter() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&repo, "@");
    let c3 = commit_id_of(&repo, "description(\"Commit 3\")");

    let prioritized = collect_lanes(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE).unwrap();
    let natural = collect_lanes(&repo, "all()", "none()").unwrap();

    let as_set = |rows: &[Row]| -> HashSet<String> { rows.iter().map(|r| r.commit_id.clone()).collect() };
    assert_eq!(as_set(&natural), as_set(&prioritized), "same rows as a set");
    assert_eq!(natural.len(), 5);
    assert_ne!(
        natural[0].commit_id, wc,
        "without present(@) the working copy is not first"
    );
    assert_eq!(
        natural[0].commit_id, c3,
        "the branch of the first input commit (c3) is emitted first"
    );
    assert_eq!(
        natural,
        collect_rows(&repo, "all()", "none()"),
        "collect_lanes equals the stream_lanes collection for the non-default prioritize too"
    );
}

// ── Medium: invariants + determinism (no retained state) ────────────────────

#[test]
fn collect_lanes_medium_all_satisfies_structural_invariants_and_is_deterministic() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&repo, "@");

    let rows = collect_lanes(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE).unwrap();
    let rows_again = collect_lanes(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE).unwrap();
    assert_eq!(
        rows, rows_again,
        "a second call on the same handle returns an equal Vec"
    );

    assert_eq!(rows.len(), 1002, "root + @ + 1000 fixture commits");
    assert_eq!(rows[0].commit_id, wc, "present(@) puts the working copy first");
    assert_eq!(
        rows.iter().filter(|r| r.edges.len() == 3).count(),
        1,
        "one octopus merge"
    );
    assert!(
        rows.iter().flat_map(|r| &r.edges).all(|e| e.kind == EdgeKind::Direct),
        "all() elides nothing"
    );
    assert_eq!(
        rows.iter().map(|r| r.lane).max(),
        Some(3),
        "@ + trunk + three branches = lanes 0..=3"
    );
    for r in &rows {
        assert_eq!(r.color_idx, r.lane % PALETTE_SIZE);
    }

    // Children before parents: every edge target appears in a LATER row.
    let mut seen: HashSet<&str> = HashSet::new();
    for r in &rows {
        for e in &r.edges {
            assert!(
                !seen.contains(e.target.as_str()),
                "{} → {} points backwards",
                r.commit_id,
                e.target
            );
        }
        seen.insert(r.commit_id.as_str());
    }
    for r in &rows {
        for e in &r.edges {
            assert!(seen.contains(e.target.as_str()), "target {} never arrived", e.target);
        }
    }
}

// ── Empty set ───────────────────────────────────────────────────────────────

#[test]
fn collect_lanes_empty_revset_yields_an_empty_vec() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let rows = collect_lanes(&repo, "none()", DEFAULT_GRAPH_PRIORITIZE).unwrap();

    assert!(rows.is_empty());
}

// ── Errors are propagated as LaneStreamError::Revset, no partial rows ───────

#[test]
fn collect_lanes_bogus_revset_returns_revset_parse_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let result = collect_lanes(&repo, "bogus_function()", DEFAULT_GRAPH_PRIORITIZE);
    assert!(
        matches!(result, Err(LaneStreamError::Revset(RevsetError::ParseError { .. }))),
        "bogus_function() must surface as LaneStreamError::Revset(ParseError), got: {result:?}"
    );
}

#[test]
fn collect_lanes_bogus_prioritize_returns_revset_parse_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let result = collect_lanes(&repo, "all()", "(");
    assert!(
        matches!(result, Err(LaneStreamError::Revset(RevsetError::ParseError { .. }))),
        "an unbalanced prioritize must surface as LaneStreamError::Revset(ParseError), got: {result:?}"
    );
}

#[test]
fn collect_lanes_blank_prioritize_returns_revset_parse_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    // The documented contract: `none()` is the canonical no-prioritization value; an
    // empty/blank expression is a ParseError.
    for prioritize in ["", "   "] {
        let result = collect_lanes(&repo, "all()", prioritize);
        assert!(
            matches!(result, Err(LaneStreamError::Revset(RevsetError::ParseError { .. }))),
            "a blank prioritize ({prioritize:?}) must surface as LaneStreamError::Revset(ParseError), got: {result:?}"
        );
    }
}

#[test]
fn collect_lanes_unresolvable_prioritize_returns_revset_resolution_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let result = collect_lanes(&repo, "all()", "nonexistent-bookmark-xyz");
    assert!(
        matches!(
            result,
            Err(LaneStreamError::Revset(RevsetError::ResolutionError { .. }))
        ),
        "an unknown prioritize symbol must surface as LaneStreamError::Revset(ResolutionError), got: {result:?}"
    );
}

#[test]
fn collect_lanes_nonexistent_bookmark_returns_revset_resolution_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let result = collect_lanes(&repo, "nonexistent-bookmark-xyz", DEFAULT_GRAPH_PRIORITIZE);
    assert!(
        matches!(
            result,
            Err(LaneStreamError::Revset(RevsetError::ResolutionError { .. }))
        ),
        "an unknown symbol must surface as LaneStreamError::Revset(ResolutionError), got: {result:?}"
    );
}
