// SPDX-License-Identifier: MIT

use std::collections::{BTreeSet, HashMap};

use zanshin_graph::{
    assign_lanes, EdgeKind, GraphEdge, GraphError, GraphNode, LaneAssigner, Row, RowEdge, PALETTE_SIZE,
};

/// Builds a `GraphNode` from a compact `(target, kind)` parent list.
fn node(id: &str, parents: &[(&str, EdgeKind)]) -> GraphNode {
    GraphNode {
        id: id.to_string(),
        parents: parents
            .iter()
            .map(|(target, kind)| GraphEdge {
                target: (*target).to_string(),
                kind: *kind,
            })
            .collect(),
    }
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

// --- Scenario matrix (AC-6..AC-13) ---

#[test]
fn linear_chain_all_on_lane_zero() {
    let nodes = vec![
        node("c1", &[("c2", EdgeKind::Direct)]),
        node("c2", &[("c3", EdgeKind::Direct)]),
        node("c3", &[]),
    ];
    let rows = assign_lanes(nodes).unwrap();
    assert_eq!(
        rows,
        vec![
            row("c1", 0, &[("c2", Some(0), EdgeKind::Direct)]),
            row("c2", 0, &[("c3", Some(0), EdgeKind::Direct)]),
            row("c3", 0, &[]),
        ]
    );
}

#[test]
fn two_heads_converge_at_shared_parent() {
    let nodes = vec![
        node("h1", &[("base", EdgeKind::Direct)]),
        node("h2", &[("base", EdgeKind::Direct)]),
        node("base", &[]),
    ];
    let rows = assign_lanes(nodes).unwrap();
    assert_eq!(
        rows,
        vec![
            row("h1", 0, &[("base", Some(0), EdgeKind::Direct)]),
            row("h2", 1, &[("base", Some(1), EdgeKind::Direct)]),
            row("base", 0, &[]),
        ]
    );
}

/// The dev-notes worked example (fork-then-merge), extended with an
/// unrelated root `h` pushed right after `f` to prove `b`'s temporary lane 1
/// is reclaimed rather than a fresh lane 2 being allocated.
#[test]
fn fork_then_merge_reclaims_temporary_lane() {
    let nodes = vec![
        node("m", &[("a", EdgeKind::Direct), ("b", EdgeKind::Direct)]),
        node("a", &[("f", EdgeKind::Direct)]),
        node("b", &[("f", EdgeKind::Direct)]),
        node("f", &[("root", EdgeKind::Direct)]),
        node("h", &[]),
        node("root", &[]),
    ];
    let rows = assign_lanes(nodes).unwrap();
    assert_eq!(
        rows,
        vec![
            row(
                "m",
                0,
                &[("a", Some(0), EdgeKind::Direct), ("b", Some(1), EdgeKind::Direct)]
            ),
            row("a", 0, &[("f", Some(0), EdgeKind::Direct)]),
            row("b", 1, &[("f", Some(1), EdgeKind::Direct)]),
            row("f", 0, &[("root", Some(0), EdgeKind::Direct)]),
            row("h", 1, &[]),
            row("root", 0, &[]),
        ]
    );
}

/// A fork inside a fork: `m` forks into `x`/`y`, `x` itself forks into
/// `p`/`q`, and all three of `y`, `p`, `q` converge on `z`. Three lanes are
/// concurrently active at once.
#[test]
fn nested_forks_stay_on_distinct_lanes_until_convergence() {
    let nodes = vec![
        node("m", &[("x", EdgeKind::Direct), ("y", EdgeKind::Direct)]),
        node("x", &[("p", EdgeKind::Direct), ("q", EdgeKind::Direct)]),
        node("y", &[("z", EdgeKind::Direct)]),
        node("p", &[("z", EdgeKind::Direct)]),
        node("q", &[("z", EdgeKind::Direct)]),
        node("z", &[]),
    ];
    let rows = assign_lanes(nodes).unwrap();
    assert_eq!(
        rows,
        vec![
            row(
                "m",
                0,
                &[("x", Some(0), EdgeKind::Direct), ("y", Some(1), EdgeKind::Direct)]
            ),
            row(
                "x",
                0,
                &[("p", Some(0), EdgeKind::Direct), ("q", Some(2), EdgeKind::Direct)]
            ),
            row("y", 1, &[("z", Some(1), EdgeKind::Direct)]),
            row("p", 0, &[("z", Some(0), EdgeKind::Direct)]),
            row("q", 2, &[("z", Some(2), EdgeKind::Direct)]),
            row("z", 0, &[]),
        ]
    );
}

/// Two independent chains, interleaved in the stream, each holding its own
/// lane end to end (AC-8: straight branches never get reassigned mid-branch).
#[test]
fn parallel_branches_hold_their_lane_when_interleaved() {
    let nodes = vec![
        node("a1", &[("a2", EdgeKind::Direct)]),
        node("b1", &[("b2", EdgeKind::Direct)]),
        node("a2", &[("a3", EdgeKind::Direct)]),
        node("b2", &[("b3", EdgeKind::Direct)]),
        node("a3", &[]),
        node("b3", &[]),
    ];
    let rows = assign_lanes(nodes).unwrap();
    assert_eq!(
        rows,
        vec![
            row("a1", 0, &[("a2", Some(0), EdgeKind::Direct)]),
            row("b1", 1, &[("b2", Some(1), EdgeKind::Direct)]),
            row("a2", 0, &[("a3", Some(0), EdgeKind::Direct)]),
            row("b2", 1, &[("b3", Some(1), EdgeKind::Direct)]),
            row("a3", 0, &[]),
            row("b3", 1, &[]),
        ]
    );
}

#[test]
fn octopus_merge_routes_every_parent_edge() {
    let nodes = vec![
        node(
            "m",
            &[
                ("a", EdgeKind::Direct),
                ("b", EdgeKind::Direct),
                ("c", EdgeKind::Direct),
            ],
        ),
        node("a", &[]),
        node("b", &[]),
        node("c", &[]),
    ];
    let rows = assign_lanes(nodes).unwrap();
    assert_eq!(
        rows,
        vec![
            row(
                "m",
                0,
                &[
                    ("a", Some(0), EdgeKind::Direct),
                    ("b", Some(1), EdgeKind::Direct),
                    ("c", Some(2), EdgeKind::Direct),
                ]
            ),
            row("a", 0, &[]),
            row("b", 1, &[]),
            row("c", 2, &[]),
        ]
    );
}

/// `r1` opens a fresh lane because `x1`'s chain still occupies lane 0; `r2`
/// then reuses the leftmost free lane (`r1`'s, already closed) rather than
/// opening a third one.
#[test]
fn many_roots_reuse_freed_lanes() {
    let nodes = vec![
        node("x1", &[("x2", EdgeKind::Direct)]),
        node("r1", &[]),
        node("r2", &[]),
        node("x2", &[]),
    ];
    let rows = assign_lanes(nodes).unwrap();
    assert_eq!(
        rows,
        vec![
            row("x1", 0, &[("x2", Some(0), EdgeKind::Direct)]),
            row("r1", 1, &[]),
            row("r2", 1, &[]),
            row("x2", 0, &[]),
        ]
    );
}

#[test]
fn color_idx_wraps_at_palette_size() {
    let heads: Vec<GraphNode> = (0..9)
        .map(|i| node(&format!("h{i}"), &[(&format!("t{i}"), EdgeKind::Direct)]))
        .collect();
    let tails: Vec<GraphNode> = (0..9).map(|i| node(&format!("t{i}"), &[])).collect();
    let rows = assign_lanes(heads.into_iter().chain(tails)).unwrap();
    assert_eq!(rows[0].lane, 0);
    assert_eq!(rows[0].color_idx, 0);
    assert_eq!(rows[7].lane, 7);
    assert_eq!(rows[7].color_idx, 7);
    assert_eq!(rows[8].lane, 8);
    assert_eq!(rows[8].color_idx, 0, "lane 8 must wrap to the same color as lane 0");
}

/// `y`'s first-parent edge reserves a lane for `q` before `x` arrives; `x`'s
/// merge edge to the same not-yet-arrived `q` must reuse that reservation
/// rather than allocating a fresh lane.
#[test]
fn merge_edge_reuses_an_existing_reservation_for_its_target() {
    let nodes = vec![
        node("y", &[("q", EdgeKind::Direct)]),
        node("x", &[("p", EdgeKind::Direct), ("q", EdgeKind::Direct)]),
        node("q", &[]),
        node("p", &[]),
    ];
    let rows = assign_lanes(nodes).unwrap();
    assert_eq!(
        rows,
        vec![
            row("y", 0, &[("q", Some(0), EdgeKind::Direct)]),
            row(
                "x",
                1,
                &[("p", Some(1), EdgeKind::Direct), ("q", Some(0), EdgeKind::Direct)]
            ),
            row("q", 0, &[]),
            row("p", 1, &[]),
        ]
    );
}

#[test]
fn assign_lanes_is_deterministic_across_runs() {
    let nodes = vec![
        node("m", &[("x", EdgeKind::Direct), ("y", EdgeKind::Direct)]),
        node("x", &[("p", EdgeKind::Direct), ("q", EdgeKind::Direct)]),
        node("y", &[("z", EdgeKind::Direct)]),
        node("p", &[("z", EdgeKind::Direct)]),
        node("q", &[("z", EdgeKind::Direct)]),
        node("z", &[]),
    ];
    let first = assign_lanes(nodes.clone()).unwrap();
    let second = assign_lanes(nodes).unwrap();
    assert_eq!(first, second);
}

// --- Contract edge cases (AC-14) ---

/// A node whose only edge is `Missing` ends its lane as a stub: nothing is
/// reserved, so the very next head reuses lane 0.
#[test]
fn missing_edge_has_no_target_lane_and_frees_the_lane() {
    let nodes = vec![node("c", &[("ghost", EdgeKind::Missing)]), node("h", &[])];
    let rows = assign_lanes(nodes).unwrap();
    assert_eq!(
        rows,
        vec![row("c", 0, &[("ghost", None, EdgeKind::Missing)]), row("h", 0, &[])]
    );
}

/// `c`'s first edge is `Missing` (its first parent lies outside the revset);
/// the first non-`Missing` edge therefore continues `c`'s own lane — even
/// though `p` already holds a reservation on lane 0 from `x` — and the two
/// reservations converge at `p`'s row. `r` proves `c`'s lane stayed occupied.
#[test]
fn missing_first_edge_lets_the_next_edge_continue_the_lane() {
    let nodes = vec![
        node("x", &[("p", EdgeKind::Direct)]),
        node("c", &[("g", EdgeKind::Missing), ("p", EdgeKind::Direct)]),
        node("r", &[]),
        node("p", &[]),
    ];
    let rows = assign_lanes(nodes).unwrap();
    assert_eq!(
        rows,
        vec![
            row("x", 0, &[("p", Some(0), EdgeKind::Direct)]),
            row(
                "c",
                1,
                &[("g", None, EdgeKind::Missing), ("p", Some(1), EdgeKind::Direct)]
            ),
            row("r", 2, &[]),
            row("p", 0, &[]),
        ]
    );
}

#[test]
fn indirect_edge_gets_a_lane_like_direct_but_keeps_its_kind() {
    let nodes = vec![node("c", &[("p", EdgeKind::Indirect)]), node("p", &[])];
    let rows = assign_lanes(nodes).unwrap();
    assert_eq!(
        rows,
        vec![row("c", 0, &[("p", Some(0), EdgeKind::Indirect)]), row("p", 0, &[]),]
    );
}

#[test]
fn dangling_direct_edge_returns_error() {
    let nodes = vec![node("c", &[("ghost", EdgeKind::Direct)])];
    assert_eq!(
        assign_lanes(nodes),
        Err(GraphError::DanglingEdge {
            target: "ghost".to_string()
        })
    );
}

#[test]
fn dangling_indirect_edge_returns_error() {
    let nodes = vec![node("c", &[("ghost", EdgeKind::Indirect)])];
    assert_eq!(
        assign_lanes(nodes),
        Err(GraphError::DanglingEdge {
            target: "ghost".to_string()
        })
    );
}

/// A parent emitted before its child violates the children-before-parents
/// contract; the child's reservation for it is then never consumed, so it
/// surfaces through the same `DanglingEdge` check (there is no separate
/// out-of-order variant — honoring the contract is the upstream stream's job).
#[test]
fn parent_before_child_surfaces_as_dangling_edge() {
    let nodes = vec![node("p", &[]), node("c", &[("p", EdgeKind::Direct)])];
    assert_eq!(
        assign_lanes(nodes),
        Err(GraphError::DanglingEdge {
            target: "p".to_string()
        })
    );
}

#[test]
fn empty_input_returns_zero_rows() {
    assert_eq!(assign_lanes(Vec::<GraphNode>::new()), Ok(vec![]));
}

// --- Streaming API (AC-4) ---

/// Rows are final at emit time: each `push` returns the complete row before
/// the next node is seen; `finish` only checks for dangling reservations.
#[test]
fn lane_assigner_emits_final_rows_one_push_at_a_time() {
    let mut assigner = LaneAssigner::new();
    assert_eq!(
        assigner.push(node("m", &[("a", EdgeKind::Direct), ("b", EdgeKind::Direct)])),
        row(
            "m",
            0,
            &[("a", Some(0), EdgeKind::Direct), ("b", Some(1), EdgeKind::Direct)]
        )
    );
    assert_eq!(assigner.push(node("a", &[])), row("a", 0, &[]));
    assert_eq!(assigner.push(node("b", &[])), row("b", 1, &[]));
    assert_eq!(assigner.finish(), Ok(()));
}

#[test]
fn finish_on_a_fresh_assigner_is_ok() {
    assert_eq!(LaneAssigner::new().finish(), Ok(()));
}

// --- ~100-node algorithmic-correctness sub-test (AC-15) ---

/// Builds a DAG by creating commits oldest-first — each commit names its
/// already-created parents — then reverses to the emission order the
/// algorithm requires (children before parents).
struct DagBuilder {
    nodes: Vec<GraphNode>,
    next_id: usize,
}

impl DagBuilder {
    fn new() -> Self {
        Self {
            nodes: Vec::new(),
            next_id: 0,
        }
    }

    fn commit(&mut self, parents: &[(&str, EdgeKind)]) -> String {
        let id = format!("c{}", self.next_id);
        self.next_id += 1;
        self.nodes.push(node(&id, parents));
        id
    }

    fn finish(mut self) -> Vec<GraphNode> {
        self.nodes.reverse();
        self.nodes
    }
}

/// A deterministic ~100-node DAG: a long trunk; five branches forked at
/// different trunk depths and merged back one after another at the tip; a
/// merge whose first parent lies outside the revset (`Missing`), so only its
/// second edge is in-set; a second disjoint root reached through an
/// `Indirect` (elided) edge; and one octopus merge joining everything.
fn build_large_dag() -> Vec<GraphNode> {
    let mut b = DagBuilder::new();

    let mut trunk = b.commit(&[]);
    let mut fork_points = Vec::new();
    for i in 0..70 {
        trunk = b.commit(&[(trunk.as_str(), EdgeKind::Direct)]);
        if i % 15 == 5 {
            fork_points.push(trunk.clone());
        }
    }
    for fork_point in &fork_points {
        let mut branch = b.commit(&[(fork_point.as_str(), EdgeKind::Direct)]);
        branch = b.commit(&[(branch.as_str(), EdgeKind::Direct)]);
        branch = b.commit(&[(branch.as_str(), EdgeKind::Direct)]);
        trunk = b.commit(&[(trunk.as_str(), EdgeKind::Direct), (branch.as_str(), EdgeKind::Direct)]);
    }
    let sideline = b.commit(&[
        ("outside-the-revset", EdgeKind::Missing),
        (trunk.as_str(), EdgeKind::Direct),
    ]);

    let mut second_root = b.commit(&[]);
    second_root = b.commit(&[(second_root.as_str(), EdgeKind::Indirect)]);
    for _ in 0..7 {
        second_root = b.commit(&[(second_root.as_str(), EdgeKind::Direct)]);
    }

    let mut octopus_branch = b.commit(&[(sideline.as_str(), EdgeKind::Direct)]);
    octopus_branch = b.commit(&[(octopus_branch.as_str(), EdgeKind::Direct)]);
    b.commit(&[
        (trunk.as_str(), EdgeKind::Direct),
        (second_root.as_str(), EdgeKind::Direct),
        (octopus_branch.as_str(), EdgeKind::Direct),
    ]);

    b.finish()
}

#[test]
fn about_100_node_dag_satisfies_structural_invariants() {
    let dag = build_large_dag();
    assert!(
        dag.len() >= 100,
        "the DAG must stay roughly 100 nodes, got {}",
        dag.len()
    );
    let rows = assign_lanes(dag.clone()).expect("generated DAG satisfies the input contract");
    let rows_again = assign_lanes(dag.clone()).expect("generated DAG satisfies the input contract");
    assert_eq!(rows, rows_again, "assign_lanes must be deterministic");

    assert_eq!(rows.len(), dag.len(), "one row per input node");
    for (actual, expected) in rows.iter().zip(dag.iter()) {
        assert_eq!(actual.commit_id, expected.id, "rows stay in input order");
    }

    // Lanes are allocated densely (leftmost-free reuse, append-only growth):
    // every lane number ever referenced — as a row's lane or an edge's target —
    // lies in 0..n with no gaps.
    let used: BTreeSet<u32> = rows
        .iter()
        .flat_map(|r| std::iter::once(r.lane).chain(r.edges.iter().filter_map(|e| e.target_lane)))
        .collect();
    let lane_count = u32::try_from(used.len()).expect("lane count fits in u32");
    assert!(
        used.iter().copied().eq(0..lane_count),
        "lane numbers have gaps: {used:?}"
    );

    // Reconstructed independently from the output stream: `lane_promised_to[lane]`
    // is the id the next arrival on that lane must match, catching any lane
    // silently double-booked to two different not-yet-arrived commits.
    // `id_promised_lanes[id]` tracks every lane currently promised to `id` —
    // an id can hold more than one (see the fork-then-merge worked example),
    // and `place()` frees ALL of them the moment `id` arrives, not just the
    // leftmost one it is placed on, so both maps must be kept in step.
    let mut lane_promised_to: HashMap<u32, &str> = HashMap::new();
    let mut id_promised_lanes: HashMap<&str, Vec<u32>> = HashMap::new();
    for r in &rows {
        if let Some(first) = r.edges.iter().find(|e| e.kind != EdgeKind::Missing) {
            assert_eq!(
                first.target_lane,
                Some(r.lane),
                "the first non-Missing edge must continue the child's own lane"
            );
        }
        for e in r.edges.iter().filter(|e| e.kind == EdgeKind::Missing) {
            assert_eq!(e.target_lane, None, "Missing edges never get a lane");
        }
        if let Some(lanes) = id_promised_lanes.remove(r.commit_id.as_str()) {
            assert!(
                lanes.contains(&r.lane),
                "{} was placed on lane {} but was never promised it",
                r.commit_id,
                r.lane
            );
            for lane in lanes {
                lane_promised_to.remove(&lane);
            }
        }
        for e in &r.edges {
            let Some(lane) = e.target_lane else {
                continue;
            };
            if let Some(&existing) = lane_promised_to.get(&lane) {
                assert_eq!(
                    existing,
                    e.target.as_str(),
                    "lane {lane} double-promised to {existing} and {}",
                    e.target
                );
            }
            lane_promised_to.insert(lane, e.target.as_str());
            id_promised_lanes.entry(e.target.as_str()).or_default().push(lane);
        }
    }
    assert!(
        id_promised_lanes.is_empty(),
        "targets promised a lane but never emitted: {id_promised_lanes:?}"
    );
    assert!(
        lane_promised_to.is_empty(),
        "lanes still promised after the last row: {lane_promised_to:?}"
    );
}
