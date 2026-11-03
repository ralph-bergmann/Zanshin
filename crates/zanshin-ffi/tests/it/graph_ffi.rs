// SPDX-License-Identifier: MIT

//! Integration tests for the `zanshin_graph_topology` FFI wrapper (Story 4.12).
//!
//! Every buffer is read through the `FlatBuffers` generated typed accessors and the Verifier —
//! a wrong-shape payload is a compile error, not a runtime assert. The wire is mapped back to a
//! `zanshin_jj::GraphTopology` (ids re-hexed from the stride columns, edges and anchors from
//! their CSR, refs and working copies regrouped by node) and compared against the oracle: the
//! same call through `zanshin_jj::Repo::open` on a second handle of the same fixture. The mapper
//! also checks every wire invariant (lengths, CSR bounds, −1 Missing slots, sort orders, zero
//! flag bits 6-7). Every token is freed via `zanshin_buffer_free_token` and every handle is
//! closed, so the suite is leak-clean.

use std::ffi::CString;
use std::path::Path;

use flatbuffers::root as fb_root;
use test_helpers::{
    abandon_commit, add_commit_off_root, add_commit_with_files, add_divergent_twin, add_workspace, extract_fixture,
    set_local_bookmark, set_remote_bookmark, set_tag, FixtureHandle,
};
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::{
    graph::zanshin_graph_topology,
    repo::{zanshin_repo_close, zanshin_repo_open},
    FFI_INVALID_ARGUMENT, FFI_INVALID_HANDLE, FFI_NULL_POINTER, JJ_CONFIG_ERROR, JJ_INVALID_INPUT, JJ_JJ_LIB_ERROR,
    JJ_REVSET_PARSE_ERROR, JJ_REVSET_RESOLUTION_ERROR,
};
use zanshin_jj::{
    CommitId, CommitRef, GraphEdgeKind, GraphTopology, OperationId, Repo, TopologyEdge, TopologyMeta, TopologyNode,
    DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET,
};

/// The CLI's `revsets.short-prefixes` default (it falls back to `revsets.log`).
const SHORT: &str = DEFAULT_LOG_REVSET;

/// The `zanshin_core` pre-fill for `anchors`.
const ANCHORS: [&str; 2] = ["trunk()", "present(@)"];

// ── Env pin ───────────────────────────────────────────────────────────────────

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Copy bytes out of a `ZanshinBuf` token and free the token.
///
/// # Safety
/// `token` must be a valid, non-null `ZanshinBuf` produced by one of the
/// `zanshin_*` functions and not yet freed.
unsafe fn read_and_free(token: *mut ZanshinBuf) -> Vec<u8> {
    assert!(!token.is_null(), "token must not be null");
    let bytes = unsafe {
        let t = &*token;
        std::slice::from_raw_parts(t.ptr.cast_const(), t.len).to_vec()
    };
    unsafe { zanshin_buffer_free_token(token) };
    bytes
}

/// Parse bytes into a verified `fbs::Envelope`.
fn parse_envelope(bytes: &[u8]) -> fbs::Envelope<'_> {
    fb_root::<fbs::Envelope>(bytes).expect("FlatBuffers Verifier must pass for a well-formed Envelope")
}

/// Extract `name` and open it through the FFI; returns the live fixture + raw handle.
///
/// The caller closes the handle via `zanshin_repo_close`; dropping the `FixtureHandle`
/// deletes the extracted repo.
unsafe fn open_fixture(name: &str) -> (FixtureHandle, u64) {
    let fixture = extract_fixture(name).expect("fixture must extract");
    let path = CString::new(fixture.path.to_str().expect("fixture path must be valid UTF-8")).expect("no NUL");
    let open_bytes = unsafe { read_and_free(zanshin_repo_open(path.as_ptr())) };
    let open_env = parse_envelope(&open_bytes);
    assert!(open_env.ok(), "repo open must succeed");
    let handle = open_env
        .data_as_repo_handle()
        .expect("data_as_repo_handle must succeed")
        .handle();
    (fixture, handle)
}

unsafe fn close(handle: u64) {
    let close_bytes = unsafe { read_and_free(zanshin_repo_close(handle)) };
    assert!(parse_envelope(&close_bytes).ok(), "repo close must succeed");
}

/// The arguments of one call; `None` leaves the field absent on the wire.
#[derive(Clone)]
struct Req<'a> {
    kind: fbs::RequestKind,
    revset: Option<&'a str>,
    prioritize: Option<&'a str>,
    short_prefixes: Option<&'a str>,
    anchors: Option<Vec<&'a str>>,
    with_timestamps: bool,
}

/// `revset` with the CLI-default prioritize and short prefixes, the default anchors, no
/// timestamps.
fn req(revset: &str) -> Req<'_> {
    Req {
        kind: fbs::RequestKind::GraphTopology,
        revset: Some(revset),
        prioritize: Some(DEFAULT_GRAPH_PRIORITIZE),
        short_prefixes: Some(SHORT),
        anchors: Some(ANCHORS.to_vec()),
        with_timestamps: false,
    }
}

impl Req<'_> {
    fn bytes(&self) -> Vec<u8> {
        let mut b = flatbuffers::FlatBufferBuilder::new();
        let revset = self.revset.map(|s| b.create_string(s));
        let prioritize = self.prioritize.map(|s| b.create_string(s));
        let short_prefixes = self.short_prefixes.map(|s| b.create_string(s));
        let anchors = self.anchors.as_ref().map(|list| {
            let offsets: Vec<_> = list.iter().map(|s| b.create_string(s)).collect();
            b.create_vector(&offsets)
        });
        let req = fbs::GraphTopologyRequest::create(
            &mut b,
            &fbs::GraphTopologyRequestArgs {
                kind: self.kind,
                revset,
                prioritize,
                short_prefixes,
                anchors,
                with_timestamps: self.with_timestamps,
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    }

    /// The same call through `zanshin_jj` on a second handle of `root`.
    fn oracle(&self, root: &Path) -> GraphTopology {
        let mut repo = Repo::open(root).expect("oracle repo must open");
        let anchors: Vec<String> = self.anchors.iter().flatten().map(|&anchor| anchor.to_owned()).collect();
        repo.graph_topology(
            self.revset.expect("revset"),
            self.prioritize.expect("prioritize"),
            self.short_prefixes.expect("short_prefixes"),
            &anchors,
            self.with_timestamps,
        )
        .expect("oracle graph_topology must succeed")
    }
}

/// Call `zanshin_graph_topology` with `req`; return the envelope bytes.
unsafe fn call(handle: u64, req: &Req<'_>) -> Vec<u8> {
    let request = req.bytes();
    unsafe { read_and_free(zanshin_graph_topology(handle, request.as_ptr(), request.len())) }
}

const HEX: &[u8; 16] = b"0123456789abcdef";
const REVERSE_HEX: &[u8; 16] = b"zyxwvutsrqponmlk";

/// Formats raw id bytes: lowercase hex, or jj reverse-hex (nibble v → 'z' − v).
fn format_id(bytes: &[u8], digits: &[u8; 16]) -> String {
    bytes
        .iter()
        .flat_map(|b| [digits[usize::from(b >> 4)], digits[usize::from(b & 0x0f)]])
        .map(char::from)
        .collect()
}

fn index(value: u32) -> usize {
    usize::try_from(value).expect("u32 fits usize")
}

fn kind_from_wire(kind: fbs::GraphEdgeKind) -> GraphEdgeKind {
    match kind {
        fbs::GraphEdgeKind::Direct => GraphEdgeKind::Direct,
        fbs::GraphEdgeKind::Indirect => GraphEdgeKind::Indirect,
        fbs::GraphEdgeKind::Missing => GraphEdgeKind::Missing,
        other => panic!("unexpected wire GraphEdgeKind {other:?}"),
    }
}

/// One node's bookmarks and tags from the `refs` table, asserting the per-node order
/// (bookmarks before tags).
fn refs_of(refs: &[(usize, fbs::TopologyRef<'_>)], node: usize) -> (Vec<CommitRef>, Vec<CommitRef>) {
    let mine: Vec<_> = refs.iter().filter(|(n, _)| *n == node).map(|(_, r)| *r).collect();
    let first_tag = mine
        .iter()
        .position(|r| r.kind() == fbs::TopologyRefKind::Tag)
        .unwrap_or(mine.len());
    assert!(
        mine[first_tag..].iter().all(|r| r.kind() == fbs::TopologyRefKind::Tag),
        "node {node}: bookmarks come before tags"
    );
    let to_ref = |r: &fbs::TopologyRef<'_>| CommitRef {
        name: r.name().expect("name must be present").to_owned(),
        remote: r.remote().map(ToOwned::to_owned),
        synced: r.synced(),
        conflicted: r.conflicted(),
        tracked: r.tracked(),
    };
    (
        mine[..first_tag].iter().map(to_ref).collect(),
        mine[first_tag..].iter().map(to_ref).collect(),
    )
}

/// Map the wire payload back to a `zanshin_jj::GraphTopology`, asserting every structural
/// invariant the schema documents on the way.
// WHY: one linear decode of every column; splitting it would only pass the columns around.
#[allow(clippy::too_many_lines)]
fn topology_from_wire(t: fbs::GraphTopology<'_>) -> GraphTopology {
    let flags = t.flags().expect("flags must be present").bytes();
    let n = flags.len();
    assert!(flags.iter().all(|f| f & 0b1100_0000 == 0), "flag bits 6-7 are zero");
    let commit_stride = usize::from(t.commit_id_stride());
    let change_stride = usize::from(t.change_id_stride());
    assert_eq!(commit_stride == 0, n == 0, "a stride is 0 iff n = 0");
    assert_eq!(change_stride == 0, n == 0, "a stride is 0 iff n = 0");
    let commit_ids = t.commit_ids().expect("commit_ids").bytes();
    let change_ids = t.change_ids().expect("change_ids").bytes();
    assert_eq!(commit_ids.len(), n * commit_stride);
    assert_eq!(change_ids.len(), n * change_stride);
    let change_offset: Vec<u32> = t.change_offset().expect("change_offset").iter().collect();
    let change_prefix = t.change_id_prefix_len().expect("change_id_prefix_len").bytes();
    let commit_prefix = t.commit_id_prefix_len().expect("commit_id_prefix_len").bytes();
    let parent_count: Vec<u32> = t.parent_count().expect("parent_count").iter().collect();
    for len in [
        change_offset.len(),
        change_prefix.len(),
        commit_prefix.len(),
        parent_count.len(),
    ] {
        assert_eq!(len, n, "every per-node vector has n entries");
    }
    let edge_start: Vec<u32> = t.edge_start().expect("edge_start").iter().collect();
    let edge_target: Vec<i32> = t.edge_target().expect("edge_target").iter().collect();
    let edge_kind: Vec<fbs::GraphEdgeKind> = t.edge_kind().expect("edge_kind").iter().collect();
    assert_eq!(edge_start.len(), n + 1, "edge_start has n + 1 entries");
    assert_eq!(edge_start[0], 0);
    assert_eq!(index(edge_start[n]), edge_target.len(), "edge_start[n] == E");
    assert_eq!(edge_kind.len(), edge_target.len());
    let timestamps: Option<Vec<i64>> = t.timestamps().map(|v| v.iter().collect());
    if let Some(ts) = &timestamps {
        assert_eq!(ts.len(), n, "timestamps, when present, have n entries");
    }
    let refs: Vec<(usize, fbs::TopologyRef<'_>)> =
        t.refs().expect("refs").iter().map(|r| (index(r.node()), r)).collect();
    assert!(refs.windows(2).all(|w| w[0].0 <= w[1].0), "refs sorted by node");
    let working_copies: Vec<(usize, String)> = t
        .working_copies()
        .expect("working_copies")
        .iter()
        .map(|w| (index(w.node()), w.workspace().expect("workspace").to_owned()))
        .collect();
    assert!(
        working_copies.windows(2).all(|w| w[0].0 <= w[1].0),
        "working copies sorted by node"
    );

    let nodes = (0..n)
        .map(|i| {
            let flag = |bit: u8| flags[i] & (1 << bit) != 0;
            let edges = (index(edge_start[i])..index(edge_start[i + 1]))
                .map(|e| {
                    let kind = kind_from_wire(edge_kind[e]);
                    let target = if kind == GraphEdgeKind::Missing {
                        assert_eq!(edge_target[e], -1, "a Missing edge's slot holds -1");
                        None
                    } else {
                        Some(usize::try_from(edge_target[e]).expect("a target is a node index"))
                    };
                    TopologyEdge { target, kind }
                })
                .collect();
            if !flag(5) {
                assert_eq!(change_offset[i], 0, "0 when the presence bit is clear");
            }
            let (bookmarks, tags) = refs_of(&refs, i);
            TopologyNode {
                commit_id: CommitId(format_id(&commit_ids[i * commit_stride..(i + 1) * commit_stride], HEX)),
                edges,
                meta: TopologyMeta {
                    change_id: format_id(&change_ids[i * change_stride..(i + 1) * change_stride], REVERSE_HEX),
                    change_id_prefix_len: u32::from(change_prefix[i]),
                    commit_id_prefix_len: u32::from(commit_prefix[i]),
                    change_offset: flag(5).then_some(change_offset[i]),
                    bookmarks,
                    tags,
                    working_copies: working_copies
                        .iter()
                        .filter(|(node, _)| *node == i)
                        .map(|(_, name)| name.clone())
                        .collect(),
                    working_copy: flag(0),
                    immutable: flag(1),
                    hidden: flag(2),
                    divergent: flag(3),
                    root: flag(4),
                    parent_count: parent_count[i],
                },
                // The root's slot is 0 and stands for "none".
                committer_timestamp_ms: timestamps.as_ref().and_then(|ts| (!flag(4)).then_some(ts[i])),
            }
        })
        .collect();

    let anchor_start: Vec<u32> = t.anchor_start().expect("anchor_start").iter().collect();
    let anchor_node: Vec<u32> = t.anchor_node().expect("anchor_node").iter().collect();
    assert_eq!(anchor_start.first(), Some(&0));
    assert_eq!(anchor_start.last().map(|&s| index(s)), Some(anchor_node.len()));
    let anchors = anchor_start
        .windows(2)
        .map(|w| {
            anchor_node[index(w[0])..index(w[1])]
                .iter()
                .map(|&i| index(i))
                .collect()
        })
        .collect();

    GraphTopology {
        operation_id: OperationId(t.operation_id().expect("operation_id").to_owned()),
        nodes,
        anchors,
        all_count: usize::try_from(t.all_count()).expect("fits"),
        extra_operation_ids: t
            .extra_operation_ids()
            .expect("extra_operation_ids")
            .iter()
            .map(|id| OperationId(id.to_owned()))
            .collect(),
    }
}

/// Assert an `ok` `GraphTopology` envelope and map it back.
fn ok_topology(bytes: &[u8]) -> GraphTopology {
    let env = parse_envelope(bytes);
    assert!(
        env.ok(),
        "zanshin_graph_topology must succeed, got {:?}: {:?}",
        env.error().and_then(|e| e.code()),
        env.error().and_then(|e| e.context())
    );
    assert_eq!(env.data_type(), fbs::Payload::GraphTopology);
    topology_from_wire(env.data_as_graph_topology().expect("GraphTopology payload"))
}

/// Assert an error envelope with the given code and no payload at the union level.
fn assert_error(bytes: &[u8], code: &str) {
    let env = parse_envelope(bytes);
    assert!(!env.ok(), "must produce an error envelope (expected {code})");
    assert_eq!(
        env.error().and_then(|e| e.code()),
        Some(code),
        "error.code must be {code}"
    );
    assert_eq!(
        env.data_type(),
        fbs::Payload::NONE,
        "an error envelope never carries a partial payload"
    );
}

/// [`assert_error`] plus a non-empty `error.context`.
fn assert_error_with_context(bytes: &[u8], code: &str) {
    assert_error(bytes, code);
    assert!(
        parse_envelope(bytes)
            .error()
            .and_then(|e| e.context())
            .is_some_and(|c| !c.is_empty()),
        "context must carry the reason for {code}"
    );
}

/// [`assert_error_with_context`] on an error the verb raised after its pre-verb snapshot ran:
/// the envelope carries the snapshot's report.
fn assert_error_after_snapshot(bytes: &[u8], code: &str) {
    assert_error_with_context(bytes, code);
    assert!(
        parse_envelope(bytes).precondition().is_some(),
        "{code}: the snapshot ran, so its report rides the error envelope"
    );
}

/// Writes `.jj/repo/config.toml` — the repo config layer of an extracted fixture, which
/// carries no `config-id`, so this legacy path IS the repo layer.
fn write_repo_config(workspace_root: &Path, toml: &str) {
    std::fs::write(workspace_root.join(".jj").join("repo").join("config.toml"), toml).unwrap();
}

// ── Wire == oracle ────────────────────────────────────────────────────────────

#[test]
fn graph_topology_tiny_all_equals_the_oracle_on_a_second_handle() {
    test_helpers::pin_test_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };
    let all = req("all()");

    let bytes = unsafe { call(handle, &all) };
    let wire = ok_topology(&bytes);

    assert_eq!(wire, all.oracle(&fx.path), "every vector decodes to the oracle's value");
    assert_eq!(wire.nodes.len(), 5, "@, c3, c2, c1, root");
    assert_eq!(wire.anchors, vec![vec![4], vec![0]], "trunk() = root, present(@) = @");
    assert_eq!(wire.all_count, 5);
    assert!(
        parse_envelope(&bytes)
            .data_as_graph_topology()
            .expect("payload")
            .timestamps()
            .is_none(),
        "timestamps are absent when not requested"
    );

    unsafe { close(handle) };
}

#[test]
fn graph_topology_medium_all_equals_the_oracle_with_the_octopus_merge() {
    test_helpers::pin_test_env();
    let (fx, handle) = unsafe { open_fixture("medium-1k-commits") };
    let all = req("all()");

    let wire = ok_topology(&unsafe { call(handle, &all) });

    assert_eq!(wire, all.oracle(&fx.path));
    assert_eq!(wire.nodes.len(), 1002);
    let merges: Vec<u32> = wire
        .nodes
        .iter()
        .map(|n| n.meta.parent_count)
        .filter(|&c| c > 1)
        .collect();
    assert_eq!(merges, vec![3], "one octopus merge with three parents");
    assert!(
        wire.nodes
            .iter()
            .flat_map(|n| &n.edges)
            .all(|e| e.kind == GraphEdgeKind::Direct),
        "every all() edge is Direct"
    );

    unsafe { close(handle) };
}

#[test]
fn graph_topology_with_timestamps_writes_n_entries_and_the_root_slot_zero() {
    test_helpers::pin_test_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };
    let timed = Req {
        with_timestamps: true,
        ..req("all()")
    };

    let bytes = unsafe { call(handle, &timed) };
    let wire = ok_topology(&bytes);

    assert_eq!(wire, timed.oracle(&fx.path), "non-root timestamps equal the oracle");
    let raw: Vec<i64> = parse_envelope(&bytes)
        .data_as_graph_topology()
        .expect("payload")
        .timestamps()
        .expect("present when requested")
        .iter()
        .collect();
    assert_eq!(raw.len(), 5);
    assert_eq!(raw[4], 0, "the root's slot is 0");
    assert!(raw[..4].iter().all(|&ms| ms > 0));

    unsafe { close(handle) };
}

#[test]
fn graph_topology_narrowed_revset_keeps_indirect_and_missing_edges_and_the_all_count() {
    test_helpers::pin_test_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };
    let all = ok_topology(&unsafe { call(handle, &req("all()")) });
    let (c3, c1) = (&all.nodes[1].commit_id.0, &all.nodes[3].commit_id.0);
    let revset = format!("{c3} | {c1}");
    let narrowed = req(&revset);

    let bytes = unsafe { call(handle, &narrowed) };
    let wire = ok_topology(&bytes);

    assert_eq!(wire, narrowed.oracle(&fx.path));
    assert_eq!(wire.nodes.len(), 2);
    assert_eq!(wire.all_count, 5, "|all()| is independent of the revset");
    assert_eq!(
        wire.nodes[0].edges,
        vec![TopologyEdge {
            target: Some(1),
            kind: GraphEdgeKind::Indirect
        }],
        "c3 → c1 is Indirect (c2 elided)"
    );
    assert_eq!(
        wire.nodes[1].edges,
        vec![TopologyEdge {
            target: None,
            kind: GraphEdgeKind::Missing
        }],
        "c1's root parent is outside the revset"
    );
    let raw: Vec<i32> = parse_envelope(&bytes)
        .data_as_graph_topology()
        .expect("payload")
        .edge_target()
        .expect("edge_target")
        .iter()
        .collect();
    assert_eq!(raw, vec![1, -1], "the Missing edge's slot holds -1");

    unsafe { close(handle) };
}

#[test]
fn graph_topology_keeps_a_merges_direct_and_indirect_edge_to_one_parent() {
    test_helpers::pin_test_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };
    let a = add_commit_with_files(&fx.path, &[], &[("a.txt", "a")], "A");
    let b = add_commit_with_files(&fx.path, &[&a], &[("b.txt", "b")], "B");
    let m = add_commit_with_files(&fx.path, &[&a, &b], &[("m.txt", "m")], "M");
    let revset = format!("all() ~ {b}");
    let without_b = req(&revset);

    let wire = ok_topology(&unsafe { call(handle, &without_b) });

    assert_eq!(wire, without_b.oracle(&fx.path), "edges verbatim, order included");
    let merge = wire.nodes.iter().find(|n| n.commit_id.0 == m).expect("M is a node");
    let a_index = wire.nodes.iter().position(|n| n.commit_id.0 == a).expect("A is a node");
    let kinds: Vec<GraphEdgeKind> = merge
        .edges
        .iter()
        .filter(|e| e.target == Some(a_index))
        .map(|e| e.kind)
        .collect();
    assert_eq!(kinds.len(), 2, "a repeated target is kept");
    assert!(kinds.contains(&GraphEdgeKind::Direct) && kinds.contains(&GraphEdgeKind::Indirect));

    unsafe { close(handle) };
}

#[test]
fn graph_topology_empty_revset_writes_present_empty_vectors() {
    test_helpers::pin_test_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let bytes = unsafe { call(handle, &req("none()")) };
    let wire = ok_topology(&bytes);

    assert!(wire.nodes.is_empty());
    assert_eq!(wire.all_count, 5);
    assert_eq!(wire.anchors, vec![Vec::<usize>::new(), Vec::new()]);
    let t = parse_envelope(&bytes).data_as_graph_topology().expect("payload");
    assert_eq!(t.edge_start().map(|v| v.iter().collect::<Vec<_>>()), Some(vec![0]));
    assert_eq!(
        t.anchor_start().map(|v| v.iter().collect::<Vec<_>>()),
        Some(vec![0, 0, 0]),
        "anchors + 1 entries, all zero"
    );
    assert_eq!(t.flags().map(|v| v.len()), Some(0), "present and empty");
    assert_eq!(t.commit_ids().map(|v| v.len()), Some(0));

    unsafe { close(handle) };
}

#[test]
fn graph_topology_carries_refs_working_copies_divergence_and_a_hidden_commit() {
    test_helpers::pin_test_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };
    let all = ok_topology(&unsafe { call(handle, &req("all()")) });
    let (c3, c2, c1) = (
        all.nodes[1].commit_id.0.clone(),
        all.nodes[2].commit_id.0.clone(),
        all.nodes[3].commit_id.0.clone(),
    );
    set_local_bookmark(&fx.path, "feature", &[&c2]);
    set_remote_bookmark(&fx.path, "feature", "origin", &c3, true);
    set_tag(&fx.path, "v1", &[&c2]);
    let (_second_root, second_wc) = add_workspace(&fx.path, "second");
    let twin = add_divergent_twin(&fx.path, &c1, "divergent twin");
    let doomed = add_commit_off_root(&fx.path, "doomed");
    abandon_commit(&fx.path, &doomed);
    let revset = format!("all() | {doomed}");
    let rich = req(&revset);

    let wire = ok_topology(&unsafe { call(handle, &rich) });

    assert_eq!(wire, rich.oracle(&fx.path));
    let node = |id: &str| wire.nodes.iter().find(|n| n.commit_id.0 == id).expect("a node");
    let feature = &node(&c2).meta;
    assert_eq!(feature.bookmarks.len(), 1);
    assert_eq!(feature.bookmarks[0].remote, None, "the local entry has no remote");
    assert_eq!(feature.tags.len(), 1);
    assert_eq!(
        node(&c3).meta.bookmarks[0].remote.as_deref(),
        Some("origin"),
        "a tracked-but-unsynced remote entry"
    );
    assert_eq!(node(&second_wc).meta.working_copies, vec!["second".to_owned()]);
    for id in [&c1, &twin] {
        let meta = &node(id).meta;
        assert!(meta.divergent && meta.change_offset.is_some(), "{id} is divergent");
    }
    assert!(node(&doomed).meta.hidden, "the abandoned commit is hidden");

    unsafe { close(handle) };
}

// ── jj errors: no partial payload ─────────────────────────────────────────────

#[test]
fn graph_topology_bogus_expressions_return_jj_revset_parse_error() {
    test_helpers::pin_test_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    for bogus in [
        req("bogus_function()"),
        Req {
            prioritize: Some("("),
            ..req("all()")
        },
        Req {
            prioritize: Some(""),
            ..req("all()")
        },
        Req {
            short_prefixes: Some("bogus_function()"),
            ..req("all()")
        },
        Req {
            anchors: Some(vec!["trunk()", "("]),
            ..req("all()")
        },
        // Rust does not re-check for an interior NUL (Dart guards it); the parser refuses it.
        Req {
            anchors: Some(vec!["trunk()\0"]),
            ..req("all()")
        },
    ] {
        let bytes = unsafe { call(handle, &bogus) };
        assert_error_after_snapshot(&bytes, JJ_REVSET_PARSE_ERROR);
    }

    unsafe { close(handle) };
}

/// Story 9.25: the parse error carries its structured detail as `FfiError.revset`, beside the
/// precondition the snapshot left.
#[test]
fn graph_topology_parse_error_carries_the_revset_detail() {
    test_helpers::pin_test_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let bytes = unsafe { call(handle, &req("fooo()")) };

    assert_error_after_snapshot(&bytes, JJ_REVSET_PARSE_ERROR);
    let revset = parse_envelope(&bytes)
        .error()
        .and_then(|e| e.revset())
        .expect("the revset detail");
    assert_eq!(revset.kind(), fbs::RevsetErrorKind::NoSuchFunction);
    assert_eq!(revset.symbol(), Some("fooo"));
    let span = revset.span().expect("span");
    assert_eq!(
        (span.offset(), span.length().map(fbs::RevsetSpanLength::value)),
        (0, Some(4))
    );
    unsafe { close(handle) };
}

#[test]
fn graph_topology_unknown_bookmark_returns_jj_revset_resolution_error() {
    test_helpers::pin_test_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    for unknown in [
        req("nonexistent-bookmark-xyz"),
        Req {
            prioritize: Some("nonexistent-bookmark-xyz"),
            ..req("all()")
        },
        Req {
            anchors: Some(vec!["nonexistent-bookmark-xyz"]),
            ..req("all()")
        },
    ] {
        let bytes = unsafe { call(handle, &unknown) };
        assert_error_after_snapshot(&bytes, JJ_REVSET_RESOLUTION_ERROR);
    }

    unsafe { close(handle) };
}

#[test]
fn graph_topology_on_malformed_repo_config_returns_jj_config_error() {
    test_helpers::pin_test_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };
    write_repo_config(&fx.path, "not = = toml");

    let bytes = unsafe { call(handle, &req("all()")) };
    assert_error_with_context(&bytes, JJ_CONFIG_ERROR);
    assert!(
        parse_envelope(&bytes)
            .error()
            .and_then(|e| e.context())
            .is_some_and(|c| c.contains("config.toml")),
        "the context must name the offending file"
    );

    unsafe { close(handle) };
}

#[test]
fn graph_topology_on_corrupt_op_heads_returns_jj_jj_lib_error() {
    test_helpers::pin_test_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };
    std::fs::remove_dir_all(fx.path.join(".jj").join("repo").join("op_heads")).expect("op_heads must be removable");

    let bytes = unsafe { call(handle, &req("all()")) };
    assert_error_with_context(&bytes, JJ_JJ_LIB_ERROR);

    unsafe { close(handle) };
}

#[test]
fn graph_topology_timestamps_of_a_deleted_commit_object_return_jj_jj_lib_error() {
    test_helpers::pin_test_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };
    let c2 = all_ids(&fx.path)[2].clone();
    let objects = fx
        .path
        .join(".jj")
        .join("repo")
        .join("store")
        .join("git")
        .join("objects");
    std::fs::remove_file(objects.join(&c2[..2]).join(&c2[2..])).expect("c2 is a loose object");

    let index_only = unsafe { call(handle, &req("all()")) };
    assert!(
        parse_envelope(&index_only).ok(),
        "no commit is loaded without timestamps"
    );
    let timed = unsafe {
        call(
            handle,
            &Req {
                with_timestamps: true,
                ..req("all()")
            },
        )
    };
    assert_error_after_snapshot(&timed, JJ_JJ_LIB_ERROR);

    unsafe { close(handle) };
}

/// The tiny fixture's `all()` commit ids in `jj log` order, read through `zanshin_jj`.
fn all_ids(root: &Path) -> Vec<String> {
    req("all()")
        .oracle(root)
        .nodes
        .into_iter()
        .map(|n| n.commit_id.0)
        .collect()
}

// ── FFI ladder ────────────────────────────────────────────────────────────────

#[test]
fn graph_topology_refuses_a_null_unverifiable_or_mis_routed_buffer_before_the_handle() {
    test_helpers::pin_test_env();

    let null = unsafe { read_and_free(zanshin_graph_topology(0, std::ptr::null(), 0)) };
    assert_error(&null, FFI_NULL_POINTER);

    let garbage = [1u8, 2, 3];
    let unverifiable = unsafe { read_and_free(zanshin_graph_topology(0, garbage.as_ptr(), garbage.len())) };
    assert_error(&unverifiable, FFI_INVALID_ARGUMENT);

    // Handle 0 too: the kind is refused on its own merits, before the handle rung.
    let mis_routed = unsafe {
        call(
            0,
            &Req {
                kind: fbs::RequestKind::CommitContents,
                ..req("all()")
            },
        )
    };
    assert_error_with_context(&mis_routed, FFI_INVALID_ARGUMENT);
}

#[test]
fn graph_topology_zero_handle_with_a_valid_buffer_returns_ffi_invalid_handle() {
    test_helpers::pin_test_env();

    let bytes = unsafe { call(0, &req("all()")) };
    assert_error(&bytes, FFI_INVALID_HANDLE);
    assert!(
        parse_envelope(&bytes).error().and_then(|e| e.context()).is_none(),
        "ffi.invalid_handle carries no context; this wrapper must not decorate it"
    );
    assert!(
        parse_envelope(&bytes).precondition().is_none(),
        "refused before the verb: no report"
    );
}

#[test]
fn graph_topology_names_each_absent_required_field_and_accepts_absent_anchors() {
    test_helpers::pin_test_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    for (absent, field) in [
        (
            Req {
                revset: None,
                ..req("all()")
            },
            "revset",
        ),
        (
            Req {
                prioritize: None,
                ..req("all()")
            },
            "prioritize",
        ),
        (
            Req {
                short_prefixes: None,
                ..req("all()")
            },
            "short_prefixes",
        ),
    ] {
        let bytes = unsafe { call(handle, &absent) };
        assert_error(&bytes, JJ_INVALID_INPUT);
        assert_eq!(
            parse_envelope(&bytes).error().and_then(|e| e.context()),
            Some(format!("{field} is required").as_str())
        );
    }

    let no_anchors = ok_topology(&unsafe {
        call(
            handle,
            &Req {
                anchors: None,
                ..req("all()")
            },
        )
    });
    assert!(
        no_anchors.anchors.is_empty(),
        "an absent anchors vector is the empty list"
    );
    assert_eq!(no_anchors.nodes.len(), 5);

    unsafe { close(handle) };
}

// ── Precondition, warnings, pass-throughs ─────────────────────────────────────

#[test]
fn graph_topology_reports_the_snapshot_of_a_working_copy_edit() {
    test_helpers::pin_test_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };
    std::fs::write(fx.path.join("edited.txt"), "a working-copy edit").unwrap();

    let bytes = unsafe { call(handle, &req("all()")) };
    let wire = ok_topology(&bytes);

    assert!(
        parse_envelope(&bytes)
            .precondition()
            .is_some_and(|p| p.was_snapshot_taken()),
        "the edit was snapshotted"
    );
    assert_eq!(
        wire,
        req("all()").oracle(&fx.path),
        "the topology answers after the snapshot"
    );

    unsafe { close(handle) };
}

/// An unresolvable `short_prefixes` is NOT an error: the CLI degrades it with a warning and
/// full-index prefix lengths (jj `cli/tests/test_log_command.rs::test_log_bad_short_prefixes`).
#[test]
fn graph_topology_unknown_short_prefixes_degrades_with_a_warning() {
    test_helpers::pin_test_env();
    let (_fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let degraded_bytes = unsafe {
        call(
            handle,
            &Req {
                short_prefixes: Some("nonexistent-bookmark-xyz"),
                ..req("all()")
            },
        )
    };
    let degraded = ok_topology(&degraded_bytes);
    let disabled = ok_topology(&unsafe {
        call(
            handle,
            &Req {
                short_prefixes: Some(""),
                ..req("all()")
            },
        )
    });

    let codes: Vec<String> = parse_envelope(&degraded_bytes)
        .warnings()
        .expect("warnings")
        .iter()
        .map(|w| w.code().expect("code").to_owned())
        .collect();
    assert_eq!(codes, vec!["jj.short_prefixes_failed".to_owned()]);
    assert_eq!(
        degraded, disabled,
        "degrading falls back to exactly the full-index prefix lengths"
    );

    unsafe { close(handle) };
}

#[test]
fn graph_topology_empty_short_prefixes_disables_disambiguation_instead_of_erroring() {
    test_helpers::pin_test_env();
    let (_fx, handle) = unsafe { open_fixture("medium-1k-commits") };

    let disabled = ok_topology(&unsafe {
        call(
            handle,
            &Req {
                short_prefixes: Some(""),
                ..req("all()")
            },
        )
    });
    let narrow = ok_topology(&unsafe {
        call(
            handle,
            &Req {
                short_prefixes: Some("@"),
                ..req("all()")
            },
        )
    });

    assert_eq!(disabled.nodes.len(), narrow.nodes.len());
    assert!(
        disabled
            .nodes
            .iter()
            .zip(&narrow.nodes)
            .all(|(off, on)| off.meta.commit_id_prefix_len >= on.meta.commit_id_prefix_len),
        "the full index can never give a SHORTER prefix than a narrowed set"
    );
    assert!(
        disabled
            .nodes
            .iter()
            .zip(&narrow.nodes)
            .any(|(off, on)| off.meta.commit_id_prefix_len > on.meta.commit_id_prefix_len),
        "a 1k-commit full index needs longer prefixes somewhere"
    );

    unsafe { close(handle) };
}

#[test]
fn graph_topology_resolves_repo_config_aliases_written_after_open_on_the_next_call() {
    test_helpers::pin_test_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };
    let wip = Req {
        prioritize: Some("none()"),
        ..req("wip()")
    };

    let before = unsafe { call(handle, &wip) };
    assert_error_with_context(&before, JJ_REVSET_PARSE_ERROR);

    write_repo_config(&fx.path, "[revset-aliases]\n'wip()' = 'description(\"Commit 2\")'\n");

    let after = ok_topology(&unsafe { call(handle, &wip) });
    assert_eq!(after.nodes.len(), 1, "wip() selects exactly one node");
    assert_eq!(after.nodes[0].commit_id.0, all_ids(&fx.path)[2], "it is c2");

    unsafe { close(handle) };
}

#[test]
fn graph_topology_rederives_from_head_so_an_external_commit_appears_on_the_next_call() {
    test_helpers::pin_test_env();
    let (fx, handle) = unsafe { open_fixture("tiny-3-commits") };

    let before = ok_topology(&unsafe { call(handle, &req("all()")) });
    let new_id = add_commit_off_root(&fx.path, "external op");
    // Same handle — no reopen, no cache.
    let after = ok_topology(&unsafe { call(handle, &req("all()")) });

    assert_eq!(before.nodes.len(), 5);
    assert_eq!(after.nodes.len(), 6, "the external commit is a new node");
    assert!(after.nodes.iter().any(|n| n.commit_id.0 == new_id));
    assert!(before.nodes.iter().all(|n| n.commit_id.0 != new_id));
    assert_ne!(before.operation_id, after.operation_id, "a new head operation");

    unsafe { close(handle) };
}
