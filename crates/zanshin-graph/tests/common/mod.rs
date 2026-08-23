// SPDX-License-Identifier: MIT

//! Shared assertions for the `zanshin-graph` integration tests.

use zanshin_graph::Row;

/// Asserts CAP-2's self-containment invariant: for every routed edge on lane `L` from a
/// child row to its landing row, every row STRICTLY BETWEEN the two lists `L` in its
/// `active_lanes` — so a renderer can paint any row's complete cross-section from that
/// row's own fields.
///
/// The landing row is the first later row carrying the edge's target commit id. When a
/// synthetic elided row is spliced in front of a real commit both rows share that id, so
/// for a duplicated elided target the window stops at the nearer of the two — a narrower
/// but still sound check (the wire carries no synthetic flag on an edge target).
///
/// # Panics
/// Panics when a routed edge never lands, or when a crossed row omits the lane.
pub fn assert_active_lanes_invariant(rows: &[Row]) {
    for (index, row) in rows.iter().enumerate() {
        for edge in &row.edges {
            let Some(lane) = edge.target_lane else {
                continue; // a Missing edge occupies no lane
            };
            let Some(offset) = rows[index + 1..].iter().position(|r| r.commit_id == edge.target) else {
                panic!("{} -> {} never lands", row.commit_id, edge.target);
            };
            let landing = index + 1 + offset;
            for crossed in &rows[index + 1..landing] {
                assert!(
                    crossed.active_lanes.iter().any(|l| l.lane == lane),
                    "lane {lane} carries {} -> {} through {}, so it must be in that row's \
                     active_lanes (got {:?})",
                    row.commit_id,
                    edge.target,
                    crossed.commit_id,
                    crossed.active_lanes
                );
            }
        }
    }
    // The converse guard: a row never lists its OWN lane as a pass-through.
    for row in rows {
        assert!(
            !row.active_lanes.iter().any(|l| l.lane == row.lane),
            "{} lists its own lane {} as a pass-through",
            row.commit_id,
            row.lane
        );
        let lanes: Vec<u32> = row.active_lanes.iter().map(|l| l.lane).collect();
        let mut sorted = lanes.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(lanes, sorted, "active_lanes must be ascending and duplicate-free");
    }
}
