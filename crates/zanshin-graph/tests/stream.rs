// SPDX-License-Identifier: MIT

//! End-to-end tests for `stream_lanes` (Story 4.3): real fixtures through `zanshin_jj`'s
//! revset graph stream into the 4.1 `LaneAssigner`, one final `Row` per node.

use std::collections::HashSet;
use std::env;
use std::ops::ControlFlow;
use std::sync::LazyLock;

use test_helpers::extract_fixture;
use zanshin_graph::{stream_lanes, EdgeKind, LaneStreamError, Row, RowEdge, PALETTE_SIZE};
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

/// Collects every row (the stream must be exhausted → `Continue`, `finish` ran Ok).
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

// ── Tiny: exact rows (hand-traced against the 4.1 rules) ────────────────────

#[test]
fn stream_lanes_tiny_all_with_default_prioritize_yields_hand_traced_rows() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&repo, "@");
    let c3 = commit_id_of(&repo, "description(\"Commit 3\")");
    let c2 = commit_id_of(&repo, "description(\"Commit 2\")");
    let c1 = commit_id_of(&repo, "description(\"Commit 1\")");
    let root = commit_id_of(&repo, "root()");

    let rows = collect_rows(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

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
}

#[test]
fn stream_lanes_tiny_all_without_prioritize_honours_the_parameter() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&repo, "@");

    let prioritized = collect_rows(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE);
    let natural = collect_rows(&repo, "all()", "none()");

    let as_set = |rows: &[Row]| -> HashSet<String> { rows.iter().map(|r| r.commit_id.clone()).collect() };
    assert_eq!(as_set(&natural), as_set(&prioritized), "same rows as a set");
    assert_eq!(natural.len(), 5);
    assert_ne!(
        natural[0].commit_id, wc,
        "without present(@) the working copy is not first"
    );
}

// ── Edge kinds through the assigner ─────────────────────────────────────────

#[test]
fn stream_lanes_heads_only_yields_missing_stubs_that_free_their_lane() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&repo, "@");

    let rows = collect_rows(&repo, "heads(all())", DEFAULT_GRAPH_PRIORITIZE);

    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].commit_id, wc);
    for r in &rows {
        assert_eq!(r.edges.len(), 1, "{} has exactly one edge", r.commit_id);
        assert_eq!(r.edges[0].kind, EdgeKind::Missing);
        assert_eq!(r.edges[0].target_lane, None, "a Missing edge never gets a lane");
        assert_eq!(r.lane, 0, "a stub frees its lane, so both heads sit on lane 0");
        assert_eq!(r.color_idx, 0);
    }
}

#[test]
fn stream_lanes_elided_parent_yields_indirect_edge_on_the_childs_lane() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let c3 = commit_id_of(&repo, "description(\"Commit 3\")");
    let c2 = commit_id_of(&repo, "description(\"Commit 2\")");
    let c1 = commit_id_of(&repo, "description(\"Commit 1\")");

    let rows = collect_rows(&repo, "all() ~ description(\"Commit 2\")", DEFAULT_GRAPH_PRIORITIZE);

    assert_eq!(rows.len(), 4);
    assert!(rows.iter().all(|r| r.commit_id != c2), "c2 is absent");
    let c3_row = rows.iter().find(|r| r.commit_id == c3).expect("c3 present");
    assert_eq!(c3_row.edges.len(), 1);
    assert_eq!(c3_row.edges[0].kind, EdgeKind::Indirect);
    assert_eq!(c3_row.edges[0].target, c1);
    assert_eq!(
        c3_row.edges[0].target_lane,
        Some(c3_row.lane),
        "the continuation edge keeps c3's lane"
    );
}

// ── Medium: invariants + determinism + finish Ok on a real stream ───────────

#[test]
fn stream_lanes_medium_all_satisfies_structural_invariants_and_is_deterministic() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&repo, "@");

    let rows = collect_rows(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE);
    let rows_again = collect_rows(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE);
    assert_eq!(rows, rows_again, "stream_lanes must be deterministic");

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

// ── Streaming shape: early exit, empty set ──────────────────────────────────

#[test]
fn stream_lanes_sink_break_stops_after_the_row_and_skips_finish() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let mut observed = 0usize;
    let result = stream_lanes(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE, |_row| {
        observed += 1;
        if observed == 2 {
            ControlFlow::Break(())
        } else {
            ControlFlow::Continue(())
        }
    });

    // Two rows in, reservations for their parents still open — a Break must NOT run
    // finish() (which would report them as DanglingEdge).
    assert!(matches!(result, Ok(ControlFlow::Break(()))), "got: {result:?}");
    assert_eq!(observed, 2, "exactly two rows observed");
}

#[test]
fn stream_lanes_empty_revset_yields_no_rows_and_continue() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let rows = collect_rows(&repo, "none()", DEFAULT_GRAPH_PRIORITIZE);

    assert!(rows.is_empty());
}

// ── Errors are propagated as LaneStreamError::Revset ────────────────────────

#[test]
fn stream_lanes_bogus_revset_returns_revset_parse_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let result = stream_lanes(&repo, "bogus_function()", DEFAULT_GRAPH_PRIORITIZE, |_| {
        ControlFlow::Continue(())
    });
    assert!(
        matches!(result, Err(LaneStreamError::Revset(RevsetError::ParseError { .. }))),
        "bogus_function() must surface as LaneStreamError::Revset(ParseError), got: {result:?}"
    );
}

#[test]
fn stream_lanes_bogus_prioritize_returns_revset_parse_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let result = stream_lanes(&repo, "all()", "(", |_| ControlFlow::Continue(()));
    assert!(
        matches!(result, Err(LaneStreamError::Revset(RevsetError::ParseError { .. }))),
        "an unbalanced prioritize must surface as LaneStreamError::Revset(ParseError), got: {result:?}"
    );
}

#[test]
fn stream_lanes_nonexistent_bookmark_returns_revset_resolution_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let result = stream_lanes(&repo, "nonexistent-bookmark-xyz", DEFAULT_GRAPH_PRIORITIZE, |_| {
        ControlFlow::Continue(())
    });
    assert!(
        matches!(
            result,
            Err(LaneStreamError::Revset(RevsetError::ResolutionError { .. }))
        ),
        "an unknown symbol must surface as LaneStreamError::Revset(ResolutionError), got: {result:?}"
    );
}
