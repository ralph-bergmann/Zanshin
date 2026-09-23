// SPDX-License-Identifier: MIT

//! End-to-end tests for `stream_lanes` (Story 4.3): real fixtures through `zanshin_jj`'s
//! revset graph stream into the 4.1 `LaneAssigner`, one final `Row` per node.

use std::collections::HashSet;
use std::env;
use std::ops::ControlFlow;
use std::sync::LazyLock;

use test_helpers::extract_fixture;
use zanshin_graph::{stream_lanes, EdgeKind, LaneStreamError, Row, RowEdge, PALETTE_SIZE};
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

/// Collects every row (the stream must be exhausted → `Continue`, `finish` ran Ok), with
/// elided-row splicing OFF — the pre-4.8 stream every legacy assertion below describes.
fn collect_rows(repo: &Repo, revset: &str, prioritize: &str) -> Vec<Row> {
    collect_rows_with(repo, revset, prioritize, false)
}

/// [`collect_rows`] with an explicit `synthetic_elided` toggle.
fn collect_rows_with(repo: &Repo, revset: &str, prioritize: &str, synthetic_elided: bool) -> Vec<Row> {
    let mut rows = Vec::new();
    let flow = stream_lanes(repo, revset, prioritize, SHORT, synthetic_elided, |row| {
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

/// Compares a row against a compact `(target, target_lane, kind)` edge list, ignoring the
/// metadata payload (`zanshin_jj` owns its content — `crates/zanshin-jj/tests/graph.rs`
/// asserts it) but pinning the topology fields this crate produces.
fn assert_row(actual: &Row, commit_id: &str, lane: u32, edges: &[(&str, Option<u32>, EdgeKind)]) {
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
    assert!(!actual.synthetic_elided, "{commit_id} is a real commit row");
    assert!(actual.meta.is_some(), "{commit_id} carries its metadata");
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

    assert_eq!(rows.len(), 5);
    assert_row(&rows[0], &wc, 0, &[(&root, Some(0), EdgeKind::Direct)]);
    assert_row(&rows[1], &c3, 1, &[(&c2, Some(1), EdgeKind::Direct)]);
    assert_row(&rows[2], &c2, 1, &[(&c1, Some(1), EdgeKind::Direct)]);
    assert_row(&rows[3], &c1, 1, &[(&root, Some(1), EdgeKind::Direct)]);
    assert_row(&rows[4], &root, 0, &[]);
    // @'s edge to root runs down lane 0 through the whole c3..c1 branch.
    assert!(rows[0].active_lanes.is_empty());
    for crossed in &rows[1..4] {
        assert_eq!(
            crossed.active_lanes.iter().map(|l| l.lane).collect::<Vec<_>>(),
            vec![0],
            "{} is crossed by @ → root on lane 0",
            crossed.commit_id
        );
    }
    assert!(rows[4].active_lanes.is_empty(), "both branches land on root");
}

#[test]
fn stream_lanes_tiny_all_without_prioritize_honours_the_parameter() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let wc = commit_id_of(&repo, "@");
    let c3 = commit_id_of(&repo, "description(\"Commit 3\")");

    let prioritized = collect_rows(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE);
    let natural = collect_rows(&repo, "all()", "none()");

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
}

// ── Story 4.8: metadata pass-through + elided splice ────────────────────────

#[test]
fn stream_lanes_carries_the_upstream_metadata_onto_the_row_it_produced() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let c3 = commit_id_of(&repo, "description(\"Commit 3\")");

    let rows = collect_rows(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE);

    let c3_row = rows.iter().find(|r| r.commit_id == c3).expect("c3 present");
    let meta = c3_row.meta.as_ref().expect("a commit row carries metadata");
    assert_eq!(
        meta.description_first_line, "Commit 3",
        "the payload lands on the row its own node produced"
    );
    assert!(rows.iter().all(|r| r.meta.is_some()), "no commit row loses its payload");
}

#[test]
fn stream_lanes_splices_a_synthetic_row_after_each_child_that_elides_an_ancestor() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let c3 = commit_id_of(&repo, "description(\"Commit 3\")");
    let c1 = commit_id_of(&repo, "description(\"Commit 1\")");
    let eliding = "all() ~ description(\"Commit 2\")";

    let off = collect_rows_with(&repo, eliding, DEFAULT_GRAPH_PRIORITIZE, false);
    let on = collect_rows_with(&repo, eliding, DEFAULT_GRAPH_PRIORITIZE, true);

    // OFF: the pre-4.8 stream — a plain Indirect edge, no extra row.
    assert_eq!(off.len(), 4);
    let off_c3 = off.iter().find(|r| r.commit_id == c3).expect("c3 present");
    assert_eq!(off_c3.edges[0].kind, EdgeKind::Indirect);
    assert!(off.iter().all(|r| !r.synthetic_elided));

    // ON: the Indirect edge becomes Direct and a synthetic row follows c3 immediately.
    assert_eq!(on.len(), 5, "one synthetic row per elided target");
    let c3_index = on.iter().position(|r| r.commit_id == c3).expect("c3 present");
    assert_eq!(on[c3_index].edges[0].kind, EdgeKind::Direct, "no Indirect edge is left");
    assert_eq!(on[c3_index].edges[0].target, c1, "the edge still names the real target");

    let synthetic = &on[c3_index + 1];
    assert!(synthetic.synthetic_elided, "the synthetic row follows its child");
    assert_eq!(synthetic.commit_id, c1, "it is keyed by the ELIDED TARGET's id");
    assert!(synthetic.meta.is_none(), "a synthetic row has no metadata");
    assert_eq!(synthetic.edges.len(), 1);
    assert_eq!(synthetic.edges[0].kind, EdgeKind::Direct);
    assert_eq!(synthetic.edges[0].target, c1);
    assert_eq!(
        synthetic.lane,
        on[c3_index].edges[0].target_lane.unwrap(),
        "the synthetic row occupies the lane its child routed to"
    );
    assert!(
        on.iter().filter(|r| !r.synthetic_elided).count() == 4,
        "the real rows are unchanged"
    );
}

#[test]
fn stream_lanes_emits_one_synthetic_row_per_child_without_deduplicating_targets() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let root = commit_id_of(&repo, "root()");
    let tip_a = commit_id_of(&repo, "bookmarks(exact:\"branch-a\")");
    let tip_b = commit_id_of(&repo, "bookmarks(exact:\"branch-b\")");

    // Two branch tips whose whole ancestry is elided down to the SAME target (root).
    let selected = "bookmarks(exact:\"branch-a\") | bookmarks(exact:\"branch-b\") | root()";
    let rows = collect_rows_with(&repo, selected, "none()", true);

    let synthetic: Vec<&Row> = rows.iter().filter(|r| r.synthetic_elided).collect();
    assert_eq!(synthetic.len(), 2, "the CLI does not dedup duplicate elided targets");
    assert!(
        synthetic.iter().all(|r| r.commit_id == root),
        "both stand in for the same target"
    );
    // Each synthetic row sits directly behind its own child, and the stream terminates
    // cleanly (collect_rows_with asserts finish() ran without a dangling reservation).
    for child in [&tip_a, &tip_b] {
        let index = rows.iter().position(|r| r.commit_id == *child).expect("child present");
        assert!(rows[index + 1].synthetic_elided, "{child}'s elided row follows it");
        assert_eq!(
            rows[index + 1].lane,
            rows[index].edges[0].target_lane.unwrap(),
            "each synthetic row consumes exactly the lane its own child reserved"
        );
    }
    assert_eq!(rows.last().map(|r| r.commit_id.as_str()), Some(root.as_str()));
}

/// A synthetic row is a first-class row for the assigner: it reports the lanes crossing it
/// exactly like a commit row does, so a renderer needs nothing extra to paint it.
#[test]
fn stream_lanes_synthetic_row_reports_its_own_pass_through_lanes() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    let root = commit_id_of(&repo, "root()");

    // Two tips each elide to root. Every synthetic row sits directly behind its own child,
    // so the walk is tip_a, synthetic, tip_b, synthetic, root. At the FIRST synthetic row
    // the walk has not reached tip_b yet — a branch that has not been reached cannot cross
    // a row above it, so nothing passes through. The SECOND synthetic row is the one with a
    // genuine pass-through: the first synthetic row routed its own edge to root, and that
    // segment is still open when the second synthetic row lands in a different lane.
    let selected = "bookmarks(exact:\"branch-a\") | bookmarks(exact:\"branch-b\") | root()";
    let rows = collect_rows_with(&repo, selected, "none()", true);

    let synthetic: Vec<usize> = rows
        .iter()
        .enumerate()
        .filter(|(_, r)| r.synthetic_elided)
        .map(|(i, _)| i)
        .collect();
    assert_eq!(synthetic.len(), 2, "both tips elide to root");
    let (first, second) = (&rows[synthetic[0]], &rows[synthetic[1]]);

    assert!(
        first.active_lanes.is_empty(),
        "nothing crosses the first synthetic row: the second tip is not reached yet"
    );
    assert_eq!(
        second.active_lanes.iter().map(|l| l.lane).collect::<Vec<_>>(),
        vec![first.edges[0].target_lane.expect("the elided row routes to root")],
        "the first synthetic row's still-open edge to root crosses the second synthetic row"
    );
    assert_eq!(second.commit_id, root);
    assert!(
        rows.last().is_some_and(|r| r.active_lanes.is_empty()),
        "everything has landed by the root row"
    );
}

/// Breaking ON a synthetic row abandons the assigner mid-splice — the child's reservation is
/// already consumed and later synthetic rows are still pending. The stream must report
/// `Break` and skip `finish()` (which would otherwise flag the open reservations).
#[test]
fn stream_lanes_sink_break_on_a_synthetic_row_stops_mid_splice() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let mut seen = Vec::new();
    let result = stream_lanes(
        &repo,
        "all() ~ description(\"Commit 2\")",
        DEFAULT_GRAPH_PRIORITIZE,
        SHORT,
        true,
        |row| {
            let synthetic = row.synthetic_elided;
            seen.push((row.commit_id, synthetic));
            if synthetic {
                ControlFlow::Break(())
            } else {
                ControlFlow::Continue(())
            }
        },
    );

    assert!(matches!(result, Ok(ControlFlow::Break(()))), "got: {result:?}");
    assert!(
        seen.last().is_some_and(|(_, synthetic)| *synthetic),
        "the break happened ON the synthetic row: {seen:?}"
    );
    assert_eq!(
        seen.iter().filter(|(_, synthetic)| *synthetic).count(),
        1,
        "no row is emitted after the break"
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
    let result = stream_lanes(&repo, "all()", DEFAULT_GRAPH_PRIORITIZE, SHORT, true, |_row| {
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

    let result = stream_lanes(&repo, "bogus_function()", DEFAULT_GRAPH_PRIORITIZE, SHORT, true, |_| {
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

    let result = stream_lanes(&repo, "all()", "(", SHORT, true, |_| ControlFlow::Continue(()));
    assert!(
        matches!(result, Err(LaneStreamError::Revset(RevsetError::ParseError { .. }))),
        "an unbalanced prioritize must surface as LaneStreamError::Revset(ParseError), got: {result:?}"
    );
}

#[test]
fn stream_lanes_blank_prioritize_returns_revset_parse_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    // The documented contract: `none()` is the canonical no-prioritization value; an
    // empty/blank expression is a ParseError.
    for prioritize in ["", "   "] {
        let result = stream_lanes(&repo, "all()", prioritize, SHORT, true, |_| ControlFlow::Continue(()));
        assert!(
            matches!(result, Err(LaneStreamError::Revset(RevsetError::ParseError { .. }))),
            "a blank prioritize ({prioritize:?}) must surface as LaneStreamError::Revset(ParseError), got: {result:?}"
        );
    }
}

#[test]
fn stream_lanes_nonexistent_bookmark_returns_revset_resolution_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let result = stream_lanes(
        &repo,
        "nonexistent-bookmark-xyz",
        DEFAULT_GRAPH_PRIORITIZE,
        SHORT,
        true,
        |_| ControlFlow::Continue(()),
    );
    assert!(
        matches!(
            result,
            Err(LaneStreamError::Revset(RevsetError::ResolutionError { .. }))
        ),
        "an unknown symbol must surface as LaneStreamError::Revset(ResolutionError), got: {result:?}"
    );
}

#[test]
fn stream_lanes_unresolvable_prioritize_returns_revset_resolution_error() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();

    let result = stream_lanes(&repo, "all()", "nonexistent-bookmark-xyz", SHORT, true, |_| {
        ControlFlow::Continue(())
    });
    assert!(
        matches!(
            result,
            Err(LaneStreamError::Revset(RevsetError::ResolutionError { .. }))
        ),
        "an unknown prioritize symbol must surface as LaneStreamError::Revset(ResolutionError), got: {result:?}"
    );
}
