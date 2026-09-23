// SPDX-License-Identifier: MIT

//! End-to-end tests for `collect_lanes` (Story 4.4): the return-all wrapper over the 4.3
//! lane stream, exercised on the committed fixtures through the public API only.

use std::collections::HashSet;
use std::env;
use std::ops::ControlFlow;
use std::sync::LazyLock;

mod common;

use common::assert_active_lanes_invariant;
use test_helpers::extract_fixture;
use zanshin_graph::{collect_lanes, stream_lanes, EdgeKind, LaneStreamError, Row, RowEdge, PALETTE_SIZE};
use zanshin_jj::{resolve_revset, Repo, RevsetError, DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET};

/// The CLI's `revsets.short-prefixes` default (it falls back to `revsets.log`).
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
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

/// The reference collection: `stream_lanes` driven to exhaustion by a hand-written sink.
fn collect_rows(repo: &mut Repo, revset: &str, prioritize: &str) -> Vec<Row> {
    let mut rows = Vec::new();
    let flow = stream_lanes(repo, revset, prioritize, SHORT, false, |row| {
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
fn commit_id_of(repo: &mut Repo, revset: &str) -> String {
    let ids = resolve_revset(repo, revset).unwrap();
    assert_eq!(ids.len(), 1, "{revset} must resolve to exactly one change");
    repo.get_change(&ids[0]).unwrap().commit_id.0
}

/// Compares a row against a compact `(target, target_lane, kind)` edge list plus its
/// expected pass-through lanes, ignoring the opaque metadata payload (`zanshin-jj` owns
/// its content — `crates/zanshin-jj/tests/graph.rs` asserts it).
fn assert_row(actual: &Row, commit_id: &str, lane: u32, edges: &[(&str, Option<u32>, EdgeKind)], active_lanes: &[u32]) {
    let expected_edges: Vec<RowEdge> = edges
        .iter()
        .map(|(target, target_lane, kind)| RowEdge {
            target: (*target).to_string(),
            target_lane: *target_lane,
            kind: *kind,
        })
        .collect();
    assert_eq!(actual.commit_id, commit_id);
    assert_eq!(actual.lane, lane, "{commit_id} lane");
    assert_eq!(actual.color_idx, lane % PALETTE_SIZE, "{commit_id} color_idx");
    assert_eq!(actual.edges, expected_edges, "{commit_id} edges");
    assert_eq!(
        actual.active_lanes.iter().map(|l| l.lane).collect::<Vec<_>>(),
        active_lanes,
        "{commit_id} active_lanes"
    );
    assert!(!actual.synthetic_elided, "{commit_id} is a real commit row");
    assert!(actual.meta.is_some(), "{commit_id} carries its metadata");
}

// ── Tiny: exact rows + equality with the stream ─────────────────────────────

#[test]
fn collect_lanes_tiny_all_with_default_prioritize_yields_hand_traced_rows_in_log_order() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&mut repo, "@");
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");
    let c2 = commit_id_of(&mut repo, "description(\"Commit 2\")");
    let c1 = commit_id_of(&mut repo, "description(\"Commit 1\")");
    let root = commit_id_of(&mut repo, "root()");

    let rows = collect_lanes(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, false).unwrap();

    assert_eq!(rows.len(), 5);
    assert_row(&rows[0], &wc, 0, &[(&root, Some(0), EdgeKind::Direct)], &[]);
    assert_row(&rows[1], &c3, 1, &[(&c2, Some(1), EdgeKind::Direct)], &[0]);
    assert_row(&rows[2], &c2, 1, &[(&c1, Some(1), EdgeKind::Direct)], &[0]);
    assert_row(&rows[3], &c1, 1, &[(&root, Some(1), EdgeKind::Direct)], &[0]);
    assert_row(&rows[4], &root, 0, &[], &[]);
    assert_eq!(
        rows,
        collect_rows(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE),
        "collect_lanes returns exactly what stream_lanes pushes, in the same order"
    );
}

#[test]
fn collect_lanes_tiny_all_without_prioritize_honours_the_parameter() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&mut repo, "@");
    let c3 = commit_id_of(&mut repo, "description(\"Commit 3\")");

    let prioritized = collect_lanes(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, false).unwrap();
    let natural = collect_lanes(&mut repo, "all()", "none()", SHORT, false).unwrap();

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
        collect_rows(&mut repo, "all()", "none()"),
        "collect_lanes equals the stream_lanes collection for the non-default prioritize too"
    );
}

// ── Medium: invariants + determinism (no retained state) ────────────────────

#[test]
fn collect_lanes_medium_all_satisfies_structural_invariants_and_is_deterministic() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&mut repo, "@");

    let rows = collect_lanes(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, false).unwrap();
    let rows_again = collect_lanes(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, false).unwrap();
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

// ── Story 4.8 (CAP-2): self-containment on the octopus fixture ──────────────

#[test]
fn collect_lanes_medium_rows_are_self_contained_renderable() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let rows = collect_lanes(&mut repo, "all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, true).unwrap();

    // Every routed edge's lane is listed on every row it crosses; no row lists its own
    // lane; the sets are ascending and duplicate-free. No assertion reads a neighbour.
    assert_active_lanes_invariant(&rows);
    assert!(
        rows.iter().any(|r| !r.active_lanes.is_empty()),
        "the fixture must actually exercise pass-through lanes"
    );
    assert!(
        rows.iter().all(|r| !r.synthetic_elided && r.meta.is_some()),
        "all() elides nothing, so every row is a commit row with metadata"
    );
}

#[test]
fn collect_lanes_medium_elided_rows_keep_the_invariant_and_only_add_synthetic_rows() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let eliding = "bookmarks() | root() | @";

    let off = collect_lanes(&mut repo, eliding, DEFAULT_GRAPH_PRIORITIZE, SHORT, false).unwrap();
    let on = collect_lanes(&mut repo, eliding, DEFAULT_GRAPH_PRIORITIZE, SHORT, true).unwrap();

    assert!(
        off.iter().any(|r| r.edges.iter().any(|e| e.kind == EdgeKind::Indirect)),
        "the revset must actually elide ancestry"
    );
    assert!(off.iter().all(|r| !r.synthetic_elided), "no synthetic rows when off");
    assert!(
        on.iter().all(|r| r.edges.iter().all(|e| e.kind != EdgeKind::Indirect)),
        "with the toggle on every Indirect edge became Direct"
    );
    assert_eq!(
        on.iter().filter(|r| !r.synthetic_elided).count(),
        off.len(),
        "splicing only ADDS rows; the real ones are unchanged in number"
    );
    assert_active_lanes_invariant(&on);
}

// ── Empty set ───────────────────────────────────────────────────────────────

#[test]
fn collect_lanes_empty_revset_yields_an_empty_vec() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let rows = collect_lanes(&mut repo, "none()", DEFAULT_GRAPH_PRIORITIZE, SHORT, false).unwrap();

    assert!(rows.is_empty());
}

// ── Errors are propagated as LaneStreamError::Revset, no partial rows ───────

#[test]
fn collect_lanes_bogus_revset_returns_revset_parse_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = collect_lanes(&mut repo, "bogus_function()", DEFAULT_GRAPH_PRIORITIZE, SHORT, false);
    assert!(
        matches!(result, Err(LaneStreamError::Revset(RevsetError::ParseError { .. }))),
        "bogus_function() must surface as LaneStreamError::Revset(ParseError), got: {result:?}"
    );
}

#[test]
fn collect_lanes_bogus_prioritize_returns_revset_parse_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = collect_lanes(&mut repo, "all()", "(", SHORT, false);
    assert!(
        matches!(result, Err(LaneStreamError::Revset(RevsetError::ParseError { .. }))),
        "an unbalanced prioritize must surface as LaneStreamError::Revset(ParseError), got: {result:?}"
    );
}

#[test]
fn collect_lanes_blank_prioritize_returns_revset_parse_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    // The documented contract: `none()` is the canonical no-prioritization value; an
    // empty/blank expression is a ParseError.
    for prioritize in ["", "   "] {
        let result = collect_lanes(&mut repo, "all()", prioritize, SHORT, false);
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
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = collect_lanes(&mut repo, "all()", "nonexistent-bookmark-xyz", SHORT, false);
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
    let mut repo = Repo::open(&fx.path).unwrap();

    let result = collect_lanes(
        &mut repo,
        "nonexistent-bookmark-xyz",
        DEFAULT_GRAPH_PRIORITIZE,
        SHORT,
        false,
    );
    assert!(
        matches!(
            result,
            Err(LaneStreamError::Revset(RevsetError::ResolutionError { .. }))
        ),
        "an unknown symbol must surface as LaneStreamError::Revset(ResolutionError), got: {result:?}"
    );
}
