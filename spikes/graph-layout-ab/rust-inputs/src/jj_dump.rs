//! jj → layout input (SPEC.md §2 "What the dumper writes"): extracts a committed fixture and
//! runs the product's own `zanshin_jj::Repo::walk_graph`, i.e. the `jj log` pipeline
//! (revset at head, `TopoGroupedGraph` with `prioritize = present(@)`, edges exactly as jj-lib
//! yields them: Direct / Indirect / Missing).

use std::collections::HashMap;
use std::ops::ControlFlow;
use std::path::Path;

use zanshin_jj::{CommitMeta, GraphEdgeKind, Repo, DEFAULT_GRAPH_PRIORITIZE};

use crate::input::{assign_priorities, Input, Kind, Node, Parent};

pub struct Dump {
    pub input: Input,
    /// The commit `trunk()` resolved to, and whether it is in the dumped graph.
    pub trunk: Option<(String, bool)>,
    /// Whether `@` is in the dumped graph.
    pub wc_in_graph: bool,
    /// `walk_graph`'s display metadata, index-aligned with `input.nodes` (the `dump` sidecar).
    pub metas: Vec<CommitMeta>,
    /// Per node, the edges dropped as repeated targets (SPEC V3), index-aligned with `input.nodes`.
    pub dropped_duplicates: Vec<Vec<Parent>>,
}

/// One node as `walk_graph` yields it, before ids become indices.
struct Raw {
    id: String,
    parents: Vec<(String, GraphEdgeKind)>,
    ts_ms: i64,
    root: bool,
    wc: bool,
    meta: CommitMeta,
}

fn walk(repo: &mut Repo, revset: &str, prioritize: &str, short_prefixes: &str) -> Result<Vec<Raw>, String> {
    let mut out = Vec::new();
    let flow = repo
        .walk_graph(revset, prioritize, short_prefixes, |node| {
            out.push(Raw {
                id: node.id.0,
                parents: node.parents.into_iter().map(|e| (e.target.0, e.kind)).collect(),
                ts_ms: node.meta.committer_timestamp.millis_since_epoch,
                root: node.meta.root,
                wc: node.meta.working_copy,
                meta: node.meta,
            });
            ControlFlow::Continue(())
        })
        .map_err(|e| format!("walk_graph({revset}): {e}"))?;
    debug_assert!(flow.is_continue());
    for w in repo.take_warnings() {
        eprintln!("  jj warning: {w:?}");
    }
    Ok(out)
}

/// Dumps `revset` of the jj workspace at `workspace` into a layout input.
///
/// `now_ms` is pinned to the newest non-null `ts_ms` plus `now_after_newest_ms` (SPEC.md §2
/// allows pinning; the wall clock would make the files differ per run and put a 2001 fixture
/// entirely into day buckets). `short_prefixes` only scopes the metadata's prefix lengths
/// (`""` = full index, as the fixture dumps use).
pub fn dump(
    workspace: &Path,
    revset: &str,
    short_prefixes: &str,
    now_after_newest_ms: i64,
    utc_offset_min: i64,
) -> Result<Dump, String> {
    let mut repo = Repo::open(workspace).map_err(|e| format!("open {}: {e}", workspace.display()))?;

    // `trunk()` as the user's config resolves it (a one-commit revset; no prioritisation).
    let trunk_ids: Vec<String> = walk(&mut repo, "trunk()", "none()", "")?.into_iter().map(|r| r.id).collect();
    let raw = walk(&mut repo, revset, DEFAULT_GRAPH_PRIORITIZE, short_prefixes)?;

    let index: HashMap<&str, usize> = raw.iter().enumerate().map(|(i, r)| (r.id.as_str(), i)).collect();
    let mut nodes = Vec::with_capacity(raw.len());
    let mut dropped_duplicates = Vec::with_capacity(raw.len());
    for r in &raw {
        let mut parents = r
            .parents
            .iter()
            .map(|(target, kind)| match kind {
                GraphEdgeKind::Missing => Ok(Parent { idx: None, kind: Kind::Missing }),
                GraphEdgeKind::Direct | GraphEdgeKind::Indirect => {
                    let idx = *index
                        .get(target.as_str())
                        .ok_or_else(|| format!("edge {} -> {target} points outside the stream", r.id))?;
                    let kind = if *kind == GraphEdgeKind::Direct { Kind::Direct } else { Kind::Indirect };
                    Ok(Parent { idx: Some(idx), kind })
                }
            })
            .collect::<Result<Vec<_>, String>>()?;
        // WHY: jj-lib 0.44 CAN yield two edges to one target — a merge whose parent P is in the
        // revset and whose other, hidden parent reaches P again gets Direct(P) + Indirect(P)
        // (`revset_graph_iterator.rs` new_edges_from_internal_commit: direct edges never mark
        // `known_ancestors`, and remove_transitive_edges keeps initial targets). The CLI draws
        // both. SPEC V3 forbids it, so keep the FIRST edge per target and report the rest.
        let mut dropped = Vec::new();
        let mut kept: Vec<usize> = Vec::with_capacity(parents.len());
        parents.retain(|p| match p.idx {
            Some(idx) if kept.contains(&idx) => {
                dropped.push(p.clone());
                false
            }
            Some(idx) => {
                kept.push(idx);
                true
            }
            None => true,
        });
        dropped_duplicates.push(dropped);
        nodes.push(Node {
            id: r.id.clone(),
            ts_ms: (!r.root).then_some(r.ts_ms),
            is_root: r.root,
            priority: 2,
            parents,
        });
    }

    let trunk = trunk_ids.first().map(|id| (id.clone(), index.contains_key(id.as_str())));
    let trunk_idx = trunk_ids.first().and_then(|id| index.get(id.as_str()).copied());
    let wc_idx = raw.iter().position(|r| r.wc);
    assign_priorities(&mut nodes, trunk_idx, wc_idx);

    let now_ms = nodes.iter().filter_map(|n| n.ts_ms).max().unwrap_or(0) + now_after_newest_ms;
    drop(index);
    let metas = raw.into_iter().map(|r| r.meta).collect();

    Ok(Dump {
        input: Input { now_ms, utc_offset_min, nodes },
        trunk,
        wc_in_graph: wc_idx.is_some(),
        metas,
        dropped_duplicates,
    })
}

/// The `dump` sidecar: per input index, the `CommitMeta` fields a local viewer needs. Short ids
/// are 12 hex digits (jj's `.short()`), longer when the shortest unique prefix is longer.
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
        .zip(&d.input.nodes)
        .zip(&d.dropped_duplicates)
        .enumerate()
        .map(|(idx, ((m, node), dropped))| {
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
                "description": m.description_first_line,
                "author": m.author_name,
                "committer_ts_ms": m.committer_timestamp.millis_since_epoch,
                "committer_tz_min": m.committer_timestamp.tz_offset_minutes,
                "bookmarks": refs(&m.bookmarks),
                "tags": refs(&m.tags),
                "working_copy": m.working_copy,
                "working_copies": m.working_copies,
                "immutable": m.immutable,
                "empty": m.empty,
                "conflict": m.conflict,
                "hidden": m.hidden,
                "divergent": m.divergent,
                "root": m.root,
            })
        })
        .collect();
    json!({"revset": revset, "short_prefixes": short_prefixes, "nodes": nodes})
}
