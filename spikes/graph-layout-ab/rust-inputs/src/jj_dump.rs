//! jj → layout input (docs/graph-layout.md §2 "What the dumper writes", amended 2026-10-01):
//! extracts a committed fixture and runs the product's own `zanshin_jj::Repo::graph_topology`
//! (Story 4.10), i.e. the `jj log` pipeline (revset at head, `TopoGroupedGraph` with
//! `prioritize = present(@)`, edges exactly as jj-lib yields them: Direct / Indirect / Missing,
//! repeated targets included), and — for the `dump` sidecar only — `Repo::commit_contents` at the
//! topology's operation for each node's object half.

use std::path::Path;

use zanshin_jj::{CommitContent, CommitId, GraphEdgeKind, Repo, TopologyMeta, DEFAULT_GRAPH_PRIORITIZE};

use crate::input::{assign_priorities, dedupe_parents, Input, Kind, Node, Parent};

/// The anchors every dump passes: the product's `defaultGraphAnchors` pre-fill, from which the
/// §11.2 rule derives the priority classes (0 trunk chain, 1 @ chain, 2 the rest).
const ANCHORS: [&str; 2] = ["trunk()", "present(@)"];

pub struct Dump {
    pub input: Input,
    /// The commit id of anchor 0 (`trunk()`) when it is in the dumped graph; `None` when it is
    /// not — the topology reports an anchor's nodes inside the revset only.
    pub trunk: Option<String>,
    /// Whether `@` (anchor 1) is in the dumped graph.
    pub wc_in_graph: bool,
    /// The topology's view half, index-aligned with `input.nodes` (the `dump` sidecar).
    pub metas: Vec<TopologyMeta>,
    /// The object half at the topology's operation, index-aligned with `input.nodes`; loaded only
    /// when the caller asks for it (the `dump` sidecar), empty otherwise.
    pub contents: Vec<CommitContent>,
    /// Per node, the edges dropped as repeated targets (§2's repeated-target rule),
    /// index-aligned with `input.nodes`.
    pub dropped_duplicates: Vec<Vec<Parent>>,
}

/// Dumps `revset` of the jj workspace at `workspace` into a layout input.
///
/// `now_ms` is pinned to the newest non-null `ts_ms` plus `now_after_newest_ms` (docs/graph-layout.md
/// §2 allows pinning; the wall clock would make the files differ per run and put a 2001 fixture
/// entirely into day buckets). `short_prefixes` only scopes the metadata's prefix lengths
/// (`""` = full index, as the fixture dumps use). `with_contents` loads every node's object half
/// for the sidecar (one commit load per node).
pub fn dump(
    workspace: &Path,
    revset: &str,
    short_prefixes: &str,
    now_after_newest_ms: i64,
    utc_offset_min: i64,
    with_contents: bool,
) -> Result<Dump, String> {
    let mut repo = Repo::open(workspace).map_err(|e| format!("open {}: {e}", workspace.display()))?;
    let anchors: Vec<String> = ANCHORS.iter().map(|&a| a.to_owned()).collect();
    let topo = repo
        .graph_topology(revset, DEFAULT_GRAPH_PRIORITIZE, short_prefixes, &anchors, true)
        .map_err(|e| format!("graph_topology({revset}): {e}"))?;
    for w in repo.take_warnings() {
        eprintln!("  jj warning: {w:?}");
    }

    let mut nodes = Vec::with_capacity(topo.nodes.len());
    let mut dropped_duplicates = Vec::with_capacity(topo.nodes.len());
    for t in &topo.nodes {
        let parents = t
            .edges
            .iter()
            .map(|e| match (e.kind, e.target) {
                (GraphEdgeKind::Missing, None) => Ok(Parent { idx: None, kind: Kind::Missing }),
                (GraphEdgeKind::Direct, Some(idx)) => Ok(Parent { idx: Some(idx), kind: Kind::Direct }),
                (GraphEdgeKind::Indirect, Some(idx)) => Ok(Parent { idx: Some(idx), kind: Kind::Indirect }),
                (kind, target) => Err(format!("edge of {}: kind {kind:?} with target {target:?}", t.commit_id.0)),
            })
            .collect::<Result<Vec<_>, String>>()?;
        // WHY: jj-lib 0.44 CAN yield two edges to one target — a merge whose parent P is in the
        // revset and whose other, hidden parent reaches P again gets Direct(P) + Indirect(P)
        // (`revset_graph_iterator.rs` new_edges_from_internal_commit: direct edges never mark
        // `known_ancestors`, and remove_transitive_edges keeps initial targets). The CLI draws
        // both; §2 keeps one per target (first position, `direct` if any is) and V3 forbids the
        // rest, which are reported in the sidecar.
        let (parents, dropped) = dedupe_parents(parents);
        dropped_duplicates.push(dropped);
        nodes.push(Node {
            id: t.commit_id.0.clone(),
            ts_ms: t.committer_timestamp_ms,
            is_root: t.meta.root,
            priority: 0,
            parents,
        });
    }
    assign_priorities(&mut nodes, &topo.anchors);

    let trunk = topo.anchors.first().and_then(|a| a.first()).map(|&i| topo.nodes[i].commit_id.0.clone());
    let wc_in_graph = topo.anchors.get(1).is_some_and(|a| !a.is_empty());
    let now_ms = nodes.iter().filter_map(|n| n.ts_ms).max().unwrap_or(0) + now_after_newest_ms;
    let contents = if with_contents {
        let ids: Vec<CommitId> = topo.nodes.iter().map(|t| t.commit_id.clone()).collect();
        repo.commit_contents(&topo.operation_id, &ids).map_err(|e| format!("commit_contents: {e}"))?
    } else {
        Vec::new()
    };
    let metas = topo.nodes.into_iter().map(|t| t.meta).collect();

    Ok(Dump {
        input: Input { now_ms, utc_offset_min, nodes },
        trunk,
        wc_in_graph,
        metas,
        contents,
        dropped_duplicates,
    })
}

/// The `dump` sidecar: per input index, the `jj log` fields a local viewer needs — the view half
/// from the topology, the object half from `commit_contents` (`d` must be dumped with contents).
/// Short ids are 12 hex digits (jj's `.short()`), longer when the shortest unique prefix is longer.
pub fn meta_json(revset: &str, short_prefixes: &str, d: &Dump) -> serde_json::Value {
    use serde_json::json;
    let short = |id: &str, prefix_len: u32| id[..id.len().min(12.max(prefix_len as usize))].to_owned();
    let refs = |rs: &[zanshin_jj::CommitRef]| -> Vec<serde_json::Value> {
        rs.iter()
            .map(|r| json!({"name": r.name, "remote": r.remote, "synced": r.synced, "conflicted": r.conflicted}))
            .collect()
    };
    let nodes: Vec<serde_json::Value> = d
        .metas
        .iter()
        .zip(&d.contents)
        .zip(&d.input.nodes)
        .zip(&d.dropped_duplicates)
        .enumerate()
        .map(|(idx, (((m, c), node), dropped))| {
            let dropped: Vec<serde_json::Value> =
                dropped.iter().map(|p| json!({"idx": p.idx, "kind": p.kind.as_str()})).collect();
            json!({
                "idx": idx,
                "dropped_duplicate_parents": dropped,
                "change_id": short(&m.change_id, m.change_id_prefix_len),
                "change_id_prefix_len": m.change_id_prefix_len,
                "change_offset": m.change_offset,
                "commit_id": short(&node.id, m.commit_id_prefix_len),
                "commit_id_prefix_len": m.commit_id_prefix_len,
                "description": c.description.lines().next().unwrap_or_default(),
                "author": c.author_name,
                "committer_ts_ms": c.committer_timestamp.millis_since_epoch,
                "committer_tz_min": c.committer_timestamp.tz_offset_minutes,
                "bookmarks": refs(&m.bookmarks),
                "tags": refs(&m.tags),
                "working_copy": m.working_copy,
                "working_copies": m.working_copies,
                "immutable": m.immutable,
                "empty": c.empty,
                "conflict": c.conflict,
                "hidden": m.hidden,
                "divergent": m.divergent,
                "root": m.root,
            })
        })
        .collect();
    json!({"revset": revset, "short_prefixes": short_prefixes, "nodes": nodes})
}
