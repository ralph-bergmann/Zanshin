// SPDX-License-Identifier: MIT

//! Shared assertions for the `zanshin-graph` integration tests.

use std::collections::BTreeSet;

use zanshin_graph::Row;

/// Asserts CAP-2's self-containment invariant as a set EQUALITY: a row's `active_lanes` is
/// exactly the set of lanes carrying a routed edge that crosses it — every crossing lane is
/// listed (nothing missing) AND every listed lane genuinely crosses (nothing spurious). A
/// renderer can therefore paint any row's complete cross-section from that row's own fields.
///
/// Also pins the ordering contract (ascending, duplicate-free) and that a row never lists
/// its own lane.
///
/// # Panics
/// Panics when a routed edge never lands, or when a row's `active_lanes` differs from the
/// independently computed crossing set.
pub fn assert_active_lanes_invariant(rows: &[Row]) {
    // Independently reconstruct, per row index, the lanes crossing it.
    let mut crossing: Vec<BTreeSet<u32>> = vec![BTreeSet::new(); rows.len()];
    for (index, row) in rows.iter().enumerate() {
        for edge in &row.edges {
            let Some(lane) = edge.target_lane else {
                continue; // a Missing edge occupies no lane
            };
            let landing = landing_row(rows, index, &edge.target);
            for crossed in &mut crossing[index + 1..landing] {
                crossed.insert(lane);
            }
        }
    }

    for (row, expected) in rows.iter().zip(&crossing) {
        let listed: Vec<u32> = row.active_lanes.iter().map(|l| l.lane).collect();
        let mut ascending = listed.clone();
        ascending.sort_unstable();
        ascending.dedup();
        assert_eq!(
            listed, ascending,
            "{}: active_lanes must be ascending and duplicate-free",
            row.commit_id
        );
        assert!(
            !listed.contains(&row.lane),
            "{} lists its own lane {} as a pass-through",
            row.commit_id,
            row.lane
        );
        assert_eq!(
            listed,
            expected.iter().copied().collect::<Vec<u32>>(),
            "{}: active_lanes must equal the lanes crossing it — no missing segment, no \
             spurious one",
            row.commit_id
        );
    }
}

/// Index of the row an edge from `child_index` to `target` lands on.
///
/// `commit_id` alone is ambiguous once synthetic elided rows are spliced (a synthetic row
/// carries its TARGET's id, so two rows share it). The CLI's splice rule disambiguates it
/// exactly: a synthetic row sits IMMEDIATELY after the child that elided to it, so an edge
/// lands on the very next row when that row is the synthetic stand-in for its target, and
/// otherwise on the next NON-synthetic row carrying the id.
fn landing_row(rows: &[Row], child_index: usize, target: &str) -> usize {
    let next = child_index + 1;
    if rows
        .get(next)
        .is_some_and(|r| r.synthetic_elided && r.commit_id == target)
    {
        return next;
    }
    let Some(offset) = rows[next..]
        .iter()
        .position(|r| !r.synthetic_elided && r.commit_id == target)
    else {
        panic!("{} -> {target} never lands on a real row", rows[child_index].commit_id);
    };
    next + offset
}
