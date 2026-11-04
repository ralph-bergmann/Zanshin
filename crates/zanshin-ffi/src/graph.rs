// SPDX-License-Identifier: MIT

//! `zanshin_graph_topology` — the whole revset's index-only graph topology on the wire
//! (Story 4.12).
//!
//! Calls `zanshin_jj::Repo::graph_topology` (Story 4.10) and serialises its answer into a
//! `FlatBuffers` `Envelope<GraphTopology>`: scalar vectors indexed by node plus CSR offset
//! vectors for the edges and the anchors — no table per node, so the Dart side reads it through
//! typed-data views with O(1) access per node. The ids cross as raw bytes at one fixed stride per
//! column (OQ 2 (b), decided by measurement — spec-4-12 § Measurements) and Dart formats them.
//!
//! The arguments cross as a `GraphTopologyRequest` request buffer (ADR-0001 composite-input
//! pattern: `anchors` is a list). Same reader discipline as `commit_contents.rs`: `data`/`len`
//! describe a caller-owned buffer Dart builds and frees itself; Rust borrows it for the call only,
//! the reader returns an OWNED struct, and the request is read BEFORE the handle is borrowed.
//! Interior-NUL guards live Dart-side (`docs/ffi-abi.md` § Interior NUL). The verb runs the
//! pre-verb snapshot exactly once, so its envelope carries `precondition` and `warnings` on the ok
//! arm and on every error arm after the snapshot ran.

use flatbuffers::{FlatBufferBuilder, VerifierOptions, WIPOffset};
use tracing::debug;
use zanshin_jj::{ConfigError, GraphEdgeKind, GraphTopology, RevsetError, TopologyMeta};

use crate::envelope::{
    catch, expect_request_kind, finish_envelope, invalid_request, map_precondition_err, missing_field,
    precondition_envelope, reject_null_request, session_from_handle, CallReport, FfiErrorObj, GRAPH_DANGLING_EDGE,
    JJ_CONFIG_ERROR, JJ_JJ_LIB_ERROR, JJ_REVSET_PARSE_ERROR, JJ_REVSET_RESOLUTION_ERROR,
};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};

// ── Error mapping ─────────────────────────────────────────────────────────────

/// Maps a [`RevsetError`] onto its AR-P-4 code; the reason (or the dangling target) rides in
/// `context`. A parse or resolution error also carries the CLI's hints and its structured detail
/// (Story 9.25, `FfiError.revset`). A failed pre-verb snapshot goes through the shared
/// [`map_precondition_err`]. Shared with `revset_search.rs`.
pub(crate) fn map_topology_err(e: RevsetError) -> FfiErrorObj {
    let hints = e.hints();
    let (code, context, revset) = match e {
        RevsetError::Precondition(e) => return map_precondition_err(e),
        RevsetError::ParseError { reason, detail } => (JJ_REVSET_PARSE_ERROR, reason, Some(*detail)),
        RevsetError::ResolutionError { reason, detail } => (JJ_REVSET_RESOLUTION_ERROR, reason, Some(*detail)),
        RevsetError::JjLibError(reason) => (JJ_JJ_LIB_ERROR, reason, None),
        RevsetError::Config(ConfigError::Load { reason }) => (JJ_CONFIG_ERROR, reason, None),
        RevsetError::DanglingEdge { target } => (GRAPH_DANGLING_EDGE, target, None),
    };
    FfiErrorObj {
        report: revset.map(|detail| Box::new(CallReport::revset(detail))),
        hints,
        code: code.to_owned(),
        context: Some(context),
    }
}

// ── Request-buffer reader ────────────────────────────────────────────────────

/// Owned Rust form of a `GraphTopologyRequest` buffer.
#[derive(Debug)]
struct GraphTopologyRequestOwned {
    revset: String,
    prioritize: String,
    short_prefixes: String,
    anchors: Vec<String>,
    with_timestamps: bool,
}

/// Parse a `GraphTopologyRequest` buffer into an owned [`GraphTopologyRequestOwned`].
///
/// # Errors
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `GraphTopologyRequest` buffer, or its
///   `kind` is not `GraphTopology`.
/// - `jj.invalid_input` — `revset`, `prioritize` or `short_prefixes` is absent
///   (`<field> is required`).
fn read_graph_topology_request(data: *const u8, len: usize) -> Result<GraphTopologyRequestOwned, FfiErrorObj> {
    reject_null_request(data)?;
    // SAFETY: caller-owned, borrowed for this call only (see the module comment above).
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let req = flatbuffers::root_with_opts::<fbs::GraphTopologyRequest>(&VerifierOptions::default(), bytes)
        .map_err(|e| invalid_request(&e))?;
    expect_request_kind(req.kind(), fbs::RequestKind::GraphTopology)?;
    let revset = req.revset().ok_or_else(|| missing_field("revset"))?;
    let prioritize = req.prioritize().ok_or_else(|| missing_field("prioritize"))?;
    let short_prefixes = req.short_prefixes().ok_or_else(|| missing_field("short_prefixes"))?;
    Ok(GraphTopologyRequestOwned {
        revset: revset.to_owned(),
        prioritize: prioritize.to_owned(),
        short_prefixes: short_prefixes.to_owned(),
        anchors: req.anchors().into_iter().flatten().map(ToOwned::to_owned).collect(),
        with_timestamps: req.with_timestamps(),
    })
}

// ── Id encoder ───────────────────────────────────────────────────────────────

/// The two id columns of a [`GraphTopology`] as raw bytes, one fixed stride per column
/// (Story 4.12, OQ 2 (b)): node `i`'s id is `[i × stride, (i + 1) × stride)`. Both strides are 0
/// iff the topology has no node.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TopologyIds {
    commit_ids: Vec<u8>,
    commit_id_stride: u8,
    change_ids: Vec<u8>,
    change_id_stride: u8,
}

impl TopologyIds {
    /// Decodes every node's commit id (lowercase hex) and change id (jj reverse-hex, `z` = 0 …
    /// `k` = 15) into bytes. The stride of a column is node 0's id length.
    ///
    /// # Errors
    /// - [`RevsetError::JjLibError`] — an id is empty, of odd length, longer than 255 bytes, not
    ///   of its column's stride, or holds a digit outside its alphabet. `zanshin-jj` only
    ///   produces well-formed ids, so this is a contract breach, not a user error.
    pub fn encode(topology: &GraphTopology) -> Result<Self, RevsetError> {
        let n = topology.nodes.len();
        let (commit_ids, commit_id_stride) = decode_column(
            topology.nodes.iter().map(|node| node.commit_id.0.as_str()),
            n,
            hex_nibble,
            "commit",
        )?;
        let (change_ids, change_id_stride) = decode_column(
            topology.nodes.iter().map(|node| node.meta.change_id.as_str()),
            n,
            reverse_hex_nibble,
            "change",
        )?;
        Ok(Self {
            commit_ids,
            commit_id_stride,
            change_ids,
            change_id_stride,
        })
    }
}

/// Bit 4 of a decoded digit marks a character outside the alphabet.
const NOT_A_DIGIT: u8 = 0x10;

/// Forward hex digit (`0-9a-f`) → nibble. Branch-free per character so the per-id loop
/// vectorises — the decoder the § Measurements build times were taken with.
fn hex_nibble(c: u8) -> u8 {
    let digit = c.wrapping_sub(b'0');
    let letter = c.wrapping_sub(b'a');
    if digit < 10 {
        digit
    } else if letter < 6 {
        letter + 10
    } else {
        NOT_A_DIGIT
    }
}

/// jj reverse-hex digit (`z` = 0 … `k` = 15; jj-lib `hex_util.rs`) → nibble.
fn reverse_hex_nibble(c: u8) -> u8 {
    let value = b'z'.wrapping_sub(c);
    if value < 16 {
        value
    } else {
        NOT_A_DIGIT
    }
}

/// Decodes one id column of `n` ids into `n × stride` bytes; see [`TopologyIds::encode`].
///
/// # Errors
/// - [`RevsetError::JjLibError`] — see [`TopologyIds::encode`]; the offending id and `column`
///   are named.
fn decode_column<'s>(
    ids: impl Iterator<Item = &'s str>,
    n: usize,
    nibble: fn(u8) -> u8,
    column: &str,
) -> Result<(Vec<u8>, u8), RevsetError> {
    let mut ids = ids.peekable();
    let Some(&first) = ids.peek() else {
        return Ok((Vec::new(), 0));
    };
    let malformed = |id: &str, why: &str| RevsetError::JjLibError(format!("{column} id \"{id}\" {why}"));
    if first.is_empty() || !first.len().is_multiple_of(2) {
        return Err(malformed(first, "is not an even, non-zero number of hex digits"));
    }
    let stride = u8::try_from(first.len() / 2).map_err(|_| malformed(first, "is longer than 255 bytes"))?;
    let mut out = vec![0u8; n * usize::from(stride)];
    for (id, dst) in ids.zip(out.chunks_exact_mut(usize::from(stride))) {
        let raw = id.as_bytes();
        if raw.len() != 2 * dst.len() {
            return Err(malformed(
                id,
                &format!("does not have the column's stride of {stride} bytes"),
            ));
        }
        let mut bad = 0u8;
        for (byte, &[hi, lo]) in dst.iter_mut().zip(raw.as_chunks::<2>().0) {
            let hi = nibble(hi);
            let lo = nibble(lo);
            bad |= hi | lo;
            *byte = (hi << 4) | (lo & 0x0f);
        }
        if bad & NOT_A_DIGIT != 0 {
            return Err(malformed(id, "holds a character outside its alphabet"));
        }
    }
    Ok((out, stride))
}

// ── Payload builder ──────────────────────────────────────────────────────────

const FLAG_WORKING_COPY: u8 = 1;
const FLAG_IMMUTABLE: u8 = 1 << 1;
const FLAG_HIDDEN: u8 = 1 << 2;
const FLAG_DIVERGENT: u8 = 1 << 3;
const FLAG_ROOT: u8 = 1 << 4;
const FLAG_HAS_CHANGE_OFFSET: u8 = 1 << 5;

/// A node's flags byte (`schemas/envelope.fbs` § `GraphTopology`: bits 0-5, 6-7 zero).
fn node_flags(meta: &TopologyMeta) -> u8 {
    let bit = |set: bool, flag: u8| if set { flag } else { 0 };
    bit(meta.working_copy, FLAG_WORKING_COPY)
        | bit(meta.immutable, FLAG_IMMUTABLE)
        | bit(meta.hidden, FLAG_HIDDEN)
        | bit(meta.divergent, FLAG_DIVERGENT)
        | bit(meta.root, FLAG_ROOT)
        | bit(meta.change_offset.is_some(), FLAG_HAS_CHANGE_OFFSET)
}

/// A node index, edge index or count as the wire's `uint`.
fn wire_u32(value: usize) -> u32 {
    // WHY saturate: a FlatBuffer is smaller than 2 GiB, so it cannot hold more than u32::MAX
    // nodes, edges or anchor entries; the saturation is unreachable for any buffer that exists.
    u32::try_from(value).unwrap_or(u32::MAX)
}

/// A shortest-prefix length as the wire's `ubyte`.
fn wire_prefix_len(len: u32) -> u8 {
    // WHY saturate: a prefix is at most the id's hex length, 2 × its byte length — 40 for a Git
    // commit id, 32 for a change id, 128 for the native backend's 64-byte commit id — so a real
    // id never reaches the saturation.
    u8::try_from(len).unwrap_or(u8::MAX)
}

/// An edge's target slot: the node index, or -1 for a Missing edge (no target).
fn wire_edge_target(target: Option<usize>) -> i32 {
    // WHY saturate: as in `wire_u32` — a node index past i32::MAX cannot be in a buffer.
    target.map_or(-1, |index| i32::try_from(index).unwrap_or(i32::MAX))
}

/// Map `zanshin_jj::GraphEdgeKind` onto the wire enum (order-identical by contract).
fn edge_kind(kind: GraphEdgeKind) -> fbs::GraphEdgeKind {
    match kind {
        GraphEdgeKind::Direct => fbs::GraphEdgeKind::Direct,
        GraphEdgeKind::Indirect => fbs::GraphEdgeKind::Indirect,
        GraphEdgeKind::Missing => fbs::GraphEdgeKind::Missing,
    }
}

type WireVector<'a, T> = WIPOffset<flatbuffers::Vector<'a, T>>;

/// The edges' CSR: `(edge_start, edge_target, edge_kind)`.
fn edge_columns<'a>(
    b: &mut FlatBufferBuilder<'a>,
    topology: &GraphTopology,
) -> (
    WireVector<'a, u32>,
    WireVector<'a, i32>,
    WireVector<'a, fbs::GraphEdgeKind>,
) {
    let mut starts = Vec::with_capacity(topology.nodes.len() + 1);
    let mut targets = Vec::new();
    let mut kinds = Vec::new();
    starts.push(0);
    for node in &topology.nodes {
        for edge in &node.edges {
            targets.push(wire_edge_target(edge.target));
            kinds.push(edge_kind(edge.kind));
        }
        starts.push(wire_u32(targets.len()));
    }
    (
        b.create_vector(&starts),
        b.create_vector(&targets),
        b.create_vector(&kinds),
    )
}

/// Every node's bookmarks then tags, sorted by node.
fn ref_tables<'a>(
    b: &mut FlatBufferBuilder<'a>,
    topology: &GraphTopology,
) -> WireVector<'a, flatbuffers::ForwardsUOffset<fbs::TopologyRef<'a>>> {
    let mut offsets = Vec::new();
    for (index, node) in topology.nodes.iter().enumerate() {
        let bookmarks = node.meta.bookmarks.iter().map(|r| (fbs::TopologyRefKind::Bookmark, r));
        let refs = bookmarks.chain(node.meta.tags.iter().map(|r| (fbs::TopologyRefKind::Tag, r)));
        for (kind, r) in refs {
            let name = b.create_string(&r.name);
            // `remote` stays absent for the local entry (null-for-absence in Dart).
            let remote = r.remote.as_deref().map(|s| b.create_string(s));
            offsets.push(fbs::TopologyRef::create(
                b,
                &fbs::TopologyRefArgs {
                    node: wire_u32(index),
                    kind,
                    name: Some(name),
                    remote,
                    synced: r.synced,
                    conflicted: r.conflicted,
                    tracked: r.tracked,
                },
            ));
        }
    }
    b.create_vector(&offsets)
}

/// Every node's workspace names, sorted by node.
fn working_copy_tables<'a>(
    b: &mut FlatBufferBuilder<'a>,
    topology: &GraphTopology,
) -> WireVector<'a, flatbuffers::ForwardsUOffset<fbs::TopologyWorkingCopy<'a>>> {
    let mut offsets = Vec::new();
    for (index, node) in topology.nodes.iter().enumerate() {
        for name in &node.meta.working_copies {
            let workspace = b.create_string(name);
            offsets.push(fbs::TopologyWorkingCopy::create(
                b,
                &fbs::TopologyWorkingCopyArgs {
                    node: wire_u32(index),
                    workspace: Some(workspace),
                },
            ));
        }
    }
    b.create_vector(&offsets)
}

/// The anchors' CSR: `(anchor_start, anchor_node)`.
fn anchor_columns<'a>(
    b: &mut FlatBufferBuilder<'a>,
    topology: &GraphTopology,
) -> (WireVector<'a, u32>, WireVector<'a, u32>) {
    let mut starts = Vec::with_capacity(topology.anchors.len() + 1);
    let mut nodes = Vec::new();
    starts.push(0);
    for anchor in &topology.anchors {
        nodes.extend(anchor.iter().map(|&index| wire_u32(index)));
        starts.push(wire_u32(nodes.len()));
    }
    (b.create_vector(&starts), b.create_vector(&nodes))
}

/// Serialise a topology and its encoded ids into a finished `Envelope<GraphTopology>` buffer.
///
/// Infallible: every value is representable. `timestamps` is written iff `with_timestamps` (the
/// caller's request flag), with the root's slot 0; every other vector is always written, empty
/// when the topology has no node. `report` is written as `Envelope.precondition` / `.warnings`.
/// `pub` for the `graph_wire` bench.
#[must_use]
pub fn graph_topology_to_envelope(
    topology: &GraphTopology,
    ids: &TopologyIds,
    with_timestamps: bool,
    report: &CallReport,
) -> Vec<u8> {
    let nodes = &topology.nodes;
    let mut b = FlatBufferBuilder::with_capacity(256 + ids.commit_ids.len() + ids.change_ids.len() + nodes.len() * 24);
    let operation_id = b.create_string(&topology.operation_id.0);
    let commit_ids = b.create_vector(&ids.commit_ids);
    let change_ids = b.create_vector(&ids.change_ids);
    let flags: Vec<u8> = nodes.iter().map(|node| node_flags(&node.meta)).collect();
    let flags = b.create_vector(&flags);
    let change_offset: Vec<u32> = nodes.iter().map(|node| node.meta.change_offset.unwrap_or(0)).collect();
    let change_offset = b.create_vector(&change_offset);
    let change_id_prefix_len: Vec<u8> = nodes
        .iter()
        .map(|node| wire_prefix_len(node.meta.change_id_prefix_len))
        .collect();
    let change_id_prefix_len = b.create_vector(&change_id_prefix_len);
    let commit_id_prefix_len: Vec<u8> = nodes
        .iter()
        .map(|node| wire_prefix_len(node.meta.commit_id_prefix_len))
        .collect();
    let commit_id_prefix_len = b.create_vector(&commit_id_prefix_len);
    let parent_count: Vec<u32> = nodes.iter().map(|node| node.meta.parent_count).collect();
    let parent_count = b.create_vector(&parent_count);
    let (edge_start, edge_target, edge_kind) = edge_columns(&mut b, topology);
    let timestamps = with_timestamps.then(|| {
        let values: Vec<i64> = nodes
            .iter()
            .map(|node| node.committer_timestamp_ms.unwrap_or(0))
            .collect();
        b.create_vector(&values)
    });
    let refs = ref_tables(&mut b, topology);
    let working_copies = working_copy_tables(&mut b, topology);
    let (anchor_start, anchor_node) = anchor_columns(&mut b, topology);
    let extra_operation_ids: Vec<_> = topology
        .extra_operation_ids
        .iter()
        .map(|id| b.create_string(&id.0))
        .collect();
    let extra_operation_ids = b.create_vector(&extra_operation_ids);
    let payload = fbs::GraphTopology::create(
        &mut b,
        &fbs::GraphTopologyArgs {
            operation_id: Some(operation_id),
            // WHY saturate: usize is 64 bits on every supported target, so this never triggers.
            all_count: u64::try_from(topology.all_count).unwrap_or(u64::MAX),
            commit_ids: Some(commit_ids),
            change_ids: Some(change_ids),
            commit_id_stride: ids.commit_id_stride,
            change_id_stride: ids.change_id_stride,
            flags: Some(flags),
            change_offset: Some(change_offset),
            change_id_prefix_len: Some(change_id_prefix_len),
            commit_id_prefix_len: Some(commit_id_prefix_len),
            parent_count: Some(parent_count),
            edge_start: Some(edge_start),
            edge_target: Some(edge_target),
            edge_kind: Some(edge_kind),
            timestamps,
            refs: Some(refs),
            working_copies: Some(working_copies),
            anchor_start: Some(anchor_start),
            anchor_node: Some(anchor_node),
            extra_operation_ids: Some(extra_operation_ids),
        },
    );
    finish_envelope(b, fbs::Payload::GraphTopology, Some(payload.as_union_value()), report)
}

// ── extern "C" ────────────────────────────────────────────────────────────────

/// Return the whole revset's index-only graph topology in the repo referenced by `handle`
/// (Story 4.12; the verb is Story 4.10's `Repo::graph_topology`): every node in `jj log` order
/// with its ids, flags, prefix lengths, change offset, parent count, jj's edges verbatim (CSR),
/// bookmarks / tags / working copies, optionally its committer timestamp, plus the node indices
/// each anchor selects, `|all()|` and the operation the call loaded.
///
/// Every argument is a caller pass-through (FR-JJ-17); Rust bakes in no default: `revset`
/// selects the nodes, `prioritize` is `jj log`'s `revsets.log-graph-prioritize` (CLI default
/// `present(@)`, `none()` = none; a blank expression is a parse error), `short_prefixes` the
/// shortest-prefix disambiguation set (an EMPTY string disables it — the CLI's toggle), `anchors`
/// an ordered revset list intersected with `revset`, and `with_timestamps` loads each non-root
/// node's committer timestamp. The call runs the pre-verb snapshot exactly once and re-derives
/// from the head operation; nothing is retained Rust-side (ADR-0002). The card content of a node
/// is `zanshin_commit_contents` at the returned `operation_id`, with the returned
/// `extra_operation_ids` (the operations the revset's `at_operation()`s brought in).
///
/// The arguments cross as a `GraphTopologyRequest` `FlatBuffers` request buffer. Returns a
/// `FlatBuffers` `Envelope` carrying a `GraphTopology` payload on success; the envelope carries
/// `precondition` and `warnings` on the ok arm and on an error arm after the snapshot ran.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `data` is a null pointer.
/// - `ffi.invalid_argument` — `data` does not verify as a `GraphTopologyRequest` buffer, or its
///   `kind` is not `GraphTopology`, i.e. the buffer was built for a different wrapper.
/// - `jj.invalid_input` — `revset`, `prioritize` or `short_prefixes` is absent
///   (`<field> is required`).
/// - `jj.revset_parse_error` — an expression (an anchor included) is syntactically invalid or
///   names an unknown function; jj-lib's reason in `context`.
/// - `jj.revset_resolution_error` — an expression names a symbol that cannot be resolved
///   (unknown bookmark/tag, missing `@`, ambiguous id); reason in `context`.
/// - `jj.stale_working_copy` — the pre-verb snapshot found the working copy stale (Story 9.26);
///   the cause and both operation ids in `context`, nothing is written.
/// - `jj.config_error` — the repo's effective jj config is unreadable, not valid TOML, has a
///   malformed `config-id`, or holds a wrong-typed value; the file path or key in `context`.
/// - `jj.jj_lib_error` — a jj-lib load, evaluation, index or commit-load failure; detail in
///   `context`.
/// - `graph.dangling_edge` — a Direct/Indirect edge names a target outside the node set (jj-lib's
///   stream contract rules it out); the target id in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`, `zanshin_repo_init`,
/// `zanshin_repo_clone`, or `zanshin_repo_convert` that has not been closed. `0` is detected and
/// returned as `ffi.invalid_handle`. A stale non-zero handle is undefined behaviour; the Dart
/// worker's Model-A handle table (Story 3.9) makes a stale handle unreachable.
/// `data` must be null or point to `len` bytes of a caller-owned buffer built and owned/freed by
/// Dart (`fbs.GraphTopologyRequestObjectBuilder(...).toBytes()`); Rust only borrows it for the
/// duration of the call. The request is read BEFORE the handle is borrowed.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_graph_topology(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_graph_topology", handle);
    let buf = catch(|| {
        let req = read_graph_topology_request(data, len)?;
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        let result = session
            .repo
            .graph_topology(
                &req.revset,
                &req.prioritize,
                &req.short_prefixes,
                &req.anchors,
                req.with_timestamps,
            )
            .and_then(|topology| TopologyIds::encode(&topology).map(|ids| (topology, ids)));
        precondition_envelope(
            &mut session.repo,
            result,
            map_topology_err,
            |(topology, ids), report| graph_topology_to_envelope(topology, ids, req.with_timestamps, report),
        )
    });
    vec_into_token(buf)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use flatbuffers::{root, FlatBufferBuilder};
    use zanshin_jj::{
        CommitId, CommitRef, ConfigError, GraphEdgeKind, GraphTopology, OperationId, Precondition, PreconditionError,
        RevsetError, TopologyEdge, TopologyMeta, TopologyNode, Warning, WarningKind,
    };

    use super::{
        graph_topology_to_envelope, map_topology_err, read_graph_topology_request, wire_edge_target, wire_prefix_len,
        wire_u32, TopologyIds,
    };
    use crate::envelope::{
        CallReport, FFI_INVALID_ARGUMENT, FFI_NULL_POINTER, GRAPH_DANGLING_EDGE, JJ_CONFIG_ERROR, JJ_INVALID_INPUT,
        JJ_JJ_LIB_ERROR, JJ_REVSET_PARSE_ERROR, JJ_REVSET_RESOLUTION_ERROR,
    };
    use crate::fbs;

    const COMMIT_A: &str = "00112233445566778899aabbccddeeff01234567";
    const COMMIT_B: &str = "ffeeddccbbaa99887766554433221100fedcba98";
    const COMMIT_ROOT: &str = "0000000000000000000000000000000000000000";
    const CHANGE_A: &str = "zyxwvutsrqponmlkzyxwvutsrqponmlk";
    const CHANGE_B: &str = "klmnopqrstuvwxyzklmnopqrstuvwxyz";
    const CHANGE_ROOT: &str = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz";

    fn meta(change_id: &str) -> TopologyMeta {
        TopologyMeta {
            change_id: change_id.to_owned(),
            change_id_prefix_len: 0,
            commit_id_prefix_len: 0,
            change_offset: None,
            bookmarks: vec![],
            tags: vec![],
            working_copies: vec![],
            working_copy: false,
            immutable: false,
            hidden: false,
            divergent: false,
            root: false,
            parent_count: 1,
        }
    }

    fn local_ref(name: &str) -> CommitRef {
        CommitRef {
            name: name.to_owned(),
            remote: None,
            synced: true,
            conflicted: false,
            tracked: false,
        }
    }

    /// `[@ = A, B, root]`: A is a merge with a Direct and an Indirect edge to B (a repeated
    /// target) and a Missing edge; B has a Missing edge and a Direct edge to the root. Every
    /// per-node field differs between nodes so a cross-wired slot shows.
    fn topology() -> GraphTopology {
        GraphTopology {
            operation_id: OperationId("ab".repeat(64)),
            nodes: vec![
                TopologyNode {
                    commit_id: CommitId(COMMIT_A.to_owned()),
                    edges: vec![
                        TopologyEdge {
                            target: Some(1),
                            kind: GraphEdgeKind::Direct,
                        },
                        TopologyEdge {
                            target: Some(1),
                            kind: GraphEdgeKind::Indirect,
                        },
                        TopologyEdge {
                            target: None,
                            kind: GraphEdgeKind::Missing,
                        },
                    ],
                    meta: TopologyMeta {
                        change_id_prefix_len: 3,
                        commit_id_prefix_len: 4,
                        change_offset: Some(7),
                        bookmarks: vec![
                            local_ref("feature"),
                            CommitRef {
                                name: "feature".to_owned(),
                                remote: Some("origin".to_owned()),
                                synced: false,
                                conflicted: true,
                                tracked: true,
                            },
                        ],
                        tags: vec![local_ref("v1")],
                        working_copies: vec!["default".to_owned(), "second".to_owned()],
                        working_copy: true,
                        divergent: true,
                        parent_count: 3,
                        ..meta(CHANGE_A)
                    },
                    committer_timestamp_ms: Some(1_700_000_000_123),
                },
                TopologyNode {
                    commit_id: CommitId(COMMIT_B.to_owned()),
                    edges: vec![
                        TopologyEdge {
                            target: None,
                            kind: GraphEdgeKind::Missing,
                        },
                        TopologyEdge {
                            target: Some(2),
                            kind: GraphEdgeKind::Direct,
                        },
                    ],
                    meta: TopologyMeta {
                        change_id_prefix_len: 5,
                        commit_id_prefix_len: 6,
                        tags: vec![local_ref("v0")],
                        immutable: true,
                        hidden: true,
                        parent_count: 2,
                        ..meta(CHANGE_B)
                    },
                    committer_timestamp_ms: Some(-5),
                },
                TopologyNode {
                    commit_id: CommitId(COMMIT_ROOT.to_owned()),
                    edges: vec![],
                    meta: TopologyMeta {
                        change_id_prefix_len: 1,
                        commit_id_prefix_len: 2,
                        immutable: true,
                        root: true,
                        parent_count: 0,
                        ..meta(CHANGE_ROOT)
                    },
                    committer_timestamp_ms: None,
                },
            ],
            anchors: vec![vec![2], vec![], vec![0, 1]],
            all_count: 9,
            extra_operation_ids: vec![OperationId("12".repeat(64)), OperationId("34".repeat(64))],
        }
    }

    fn envelope(topology: &GraphTopology, with_timestamps: bool, report: &CallReport) -> Vec<u8> {
        let ids = TopologyIds::encode(topology).expect("well-formed ids");
        graph_topology_to_envelope(topology, &ids, with_timestamps, report)
    }

    /// Verify the buffer and read the `GraphTopology` payload through the typed accessors.
    fn verified(buf: &[u8]) -> (fbs::Envelope<'_>, fbs::GraphTopology<'_>) {
        let env = root::<fbs::Envelope>(buf).expect("FlatBuffers Verifier must pass");
        assert!(env.ok(), "envelope must be ok");
        assert_eq!(env.data_type(), fbs::Payload::GraphTopology);
        let payload = env.data_as_graph_topology().expect("GraphTopology payload");
        (env, payload)
    }

    fn vec_u8(v: Option<flatbuffers::Vector<'_, u8>>) -> Vec<u8> {
        v.expect("vector present").iter().collect()
    }

    fn vec_u32(v: Option<flatbuffers::Vector<'_, u32>>) -> Vec<u32> {
        v.expect("vector present").iter().collect()
    }

    #[test]
    fn topology_roundtrips_every_vector_through_the_typed_accessors() {
        let buf = envelope(&topology(), false, &CallReport::default());
        let (env, t) = verified(&buf);
        assert!(env.precondition().is_none() && env.warnings().is_none(), "empty report");
        assert_eq!(t.operation_id(), Some("ab".repeat(64).as_str()));
        let extras: Vec<&str> = t.extra_operation_ids().expect("written").iter().collect();
        assert_eq!(extras, ["12".repeat(64), "34".repeat(64)], "in order");
        assert_eq!(t.all_count(), 9);
        assert_eq!(t.commit_id_stride(), 20);
        assert_eq!(t.change_id_stride(), 16);
        let commit_ids = vec_u8(t.commit_ids());
        assert_eq!(&commit_ids[..4], &[0x00, 0x11, 0x22, 0x33]);
        assert_eq!(&commit_ids[20..24], &[0xff, 0xee, 0xdd, 0xcc]);
        assert_eq!(commit_ids.len(), 60);
        let change_ids = vec_u8(t.change_ids());
        assert_eq!(&change_ids[..8], &[0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]);
        assert_eq!(&change_ids[16..24], &[0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10]);
        assert_eq!(&change_ids[32..], &[0; 16]);
        // bit 0 working_copy, 1 immutable, 2 hidden, 3 divergent, 4 root, 5 has_change_offset
        assert_eq!(vec_u8(t.flags()), vec![0b10_1001, 0b00_0110, 0b01_0010]);
        assert_eq!(
            vec_u32(t.change_offset()),
            vec![7, 0, 0],
            "0 when the presence bit is clear"
        );
        assert_eq!(vec_u8(t.change_id_prefix_len()), vec![3, 5, 1]);
        assert_eq!(vec_u8(t.commit_id_prefix_len()), vec![4, 6, 2]);
        assert_eq!(vec_u32(t.parent_count()), vec![3, 2, 0]);
        assert_eq!(vec_u32(t.edge_start()), vec![0, 3, 5, 5]);
        assert_eq!(
            t.edge_target().expect("edge_target").iter().collect::<Vec<_>>(),
            vec![1, 1, -1, -1, 2],
            "a Missing edge's slot is -1; the repeated target is kept"
        );
        assert_eq!(
            t.edge_kind().expect("edge_kind").iter().collect::<Vec<_>>(),
            vec![
                fbs::GraphEdgeKind::Direct,
                fbs::GraphEdgeKind::Indirect,
                fbs::GraphEdgeKind::Missing,
                fbs::GraphEdgeKind::Missing,
                fbs::GraphEdgeKind::Direct,
            ]
        );
        assert!(t.timestamps().is_none(), "absent when not requested");
        assert_eq!(
            vec_u32(t.anchor_start()),
            vec![0, 1, 1, 3],
            "an empty anchor is an empty range"
        );
        assert_eq!(vec_u32(t.anchor_node()), vec![2, 0, 1]);
    }

    #[test]
    fn refs_are_sorted_by_node_with_bookmarks_before_tags_and_a_local_remote_absent() {
        let buf = envelope(&topology(), false, &CallReport::default());
        let (_, t) = verified(&buf);
        let refs: Vec<_> = t
            .refs()
            .expect("refs")
            .iter()
            .map(|r| {
                (
                    r.node(),
                    r.kind(),
                    r.name().expect("name").to_owned(),
                    r.remote().map(ToOwned::to_owned),
                    r.synced(),
                    r.conflicted(),
                    r.tracked(),
                )
            })
            .collect();
        assert_eq!(
            refs,
            vec![
                (
                    0,
                    fbs::TopologyRefKind::Bookmark,
                    "feature".to_owned(),
                    None,
                    true,
                    false,
                    false
                ),
                (
                    0,
                    fbs::TopologyRefKind::Bookmark,
                    "feature".to_owned(),
                    Some("origin".to_owned()),
                    false,
                    true,
                    true
                ),
                (0, fbs::TopologyRefKind::Tag, "v1".to_owned(), None, true, false, false),
                (1, fbs::TopologyRefKind::Tag, "v0".to_owned(), None, true, false, false),
            ]
        );
        let wcs: Vec<_> = t
            .working_copies()
            .expect("working_copies")
            .iter()
            .map(|w| (w.node(), w.workspace().expect("workspace").to_owned()))
            .collect();
        assert_eq!(wcs, vec![(0, "default".to_owned()), (0, "second".to_owned())]);
    }

    #[test]
    fn requested_timestamps_are_written_with_the_root_slot_zero() {
        let buf = envelope(&topology(), true, &CallReport::default());
        let (_, t) = verified(&buf);
        assert_eq!(
            t.timestamps()
                .expect("present when requested")
                .iter()
                .collect::<Vec<_>>(),
            vec![1_700_000_000_123, -5, 0]
        );
    }

    #[test]
    fn an_empty_topology_writes_every_vector_present_and_empty() {
        let empty = GraphTopology {
            operation_id: OperationId("cd".repeat(64)),
            nodes: vec![],
            anchors: vec![vec![], vec![]],
            all_count: 1,
            extra_operation_ids: vec![],
        };
        let buf = envelope(&empty, true, &CallReport::default());
        let (_, t) = verified(&buf);
        assert_eq!(t.extra_operation_ids().map(|v| v.len()), Some(0), "always written");
        assert_eq!(t.commit_id_stride(), 0);
        assert_eq!(t.change_id_stride(), 0);
        for v in [
            vec_u8(t.commit_ids()),
            vec_u8(t.change_ids()),
            vec_u8(t.flags()),
            vec_u8(t.change_id_prefix_len()),
            vec_u8(t.commit_id_prefix_len()),
        ] {
            assert!(v.is_empty());
        }
        for v in [
            vec_u32(t.change_offset()),
            vec_u32(t.parent_count()),
            vec_u32(t.anchor_node()),
        ] {
            assert!(v.is_empty());
        }
        assert_eq!(vec_u32(t.edge_start()), vec![0]);
        assert_eq!(t.edge_target().map(|v| v.len()), Some(0));
        assert_eq!(t.edge_kind().map(|v| v.len()), Some(0));
        assert_eq!(t.timestamps().map(|v| v.len()), Some(0), "requested: present, empty");
        assert_eq!(t.refs().map(|v| v.len()), Some(0));
        assert_eq!(t.working_copies().map(|v| v.len()), Some(0));
        assert_eq!(
            vec_u32(t.anchor_start()),
            vec![0, 0, 0],
            "anchors + 1 entries, all zero"
        );
    }

    #[test]
    fn the_report_rides_the_ok_envelope() {
        let report = CallReport {
            precondition: Some(Precondition {
                was_snapshot_taken: true,
                ..Precondition::default()
            }),
            warnings: vec![Warning {
                kind: WarningKind::ShortPrefixesFailed,
                message: "index".to_owned(),
            }],
            left_behind: Vec::new(),
            revset: None,
        };
        let buf = envelope(&topology(), false, &report);
        let (env, _) = verified(&buf);
        assert!(env.precondition().is_some_and(|p| p.was_snapshot_taken()));
        let warning = env.warnings().expect("warnings").get(0);
        assert_eq!(warning.code(), Some("jj.short_prefixes_failed"));
        assert_eq!(warning.message(), Some("index"));
    }

    #[test]
    fn the_id_encoder_decodes_hex_and_reverse_hex_extremes() {
        let ids = TopologyIds::encode(&topology()).expect("encode");
        assert_eq!(ids.commit_id_stride, 20);
        assert_eq!(ids.change_id_stride, 16);
        // Reverse-hex: z = 0 … k = 15.
        assert_eq!(ids.change_ids[0], 0x01, "zy");
        assert_eq!(ids.change_ids[16], 0xfe, "kl");
        assert_eq!(&ids.change_ids[32..48], &[0; 16], "all z");
        assert_eq!(ids.commit_ids[59], 0x00);
    }

    #[test]
    fn the_id_encoder_of_an_empty_topology_has_zero_strides() {
        let ids = TopologyIds::encode(&GraphTopology {
            operation_id: OperationId(String::new()),
            nodes: vec![],
            anchors: vec![],
            all_count: 0,
            extra_operation_ids: vec![],
        })
        .expect("encode");
        assert_eq!(
            ids,
            TopologyIds {
                commit_ids: vec![],
                commit_id_stride: 0,
                change_ids: vec![],
                change_id_stride: 0,
            }
        );
    }

    fn encode_err(edit: impl FnOnce(&mut GraphTopology)) -> String {
        let mut t = topology();
        edit(&mut t);
        match TopologyIds::encode(&t) {
            Err(RevsetError::JjLibError(reason)) => reason,
            other => panic!("expected JjLibError, got {other:?}"),
        }
    }

    #[test]
    fn the_id_encoder_refuses_a_malformed_digit_in_either_alphabet() {
        let reason = encode_err(|t| t.nodes[1].commit_id.0.replace_range(0..1, "g"));
        assert!(reason.starts_with("commit id \"gfeedd"), "{reason}");
        assert!(reason.ends_with("holds a character outside its alphabet"), "{reason}");
        // A forward-hex digit is not a reverse-hex one.
        let reason = encode_err(|t| t.nodes[2].meta.change_id.replace_range(0..1, "a"));
        assert!(reason.starts_with("change id \"azzz"), "{reason}");
    }

    #[test]
    fn the_id_encoder_refuses_an_odd_or_empty_first_id() {
        let reason = encode_err(|t| t.nodes[0].commit_id.0.push('0'));
        assert!(
            reason.ends_with("is not an even, non-zero number of hex digits"),
            "{reason}"
        );
        let reason = encode_err(|t| t.nodes[0].meta.change_id.clear());
        assert!(reason.starts_with("change id \"\""), "{reason}");
    }

    #[test]
    fn the_id_encoder_refuses_a_stride_mismatch_and_an_overlong_id() {
        let reason = encode_err(|t| t.nodes[2].commit_id.0.push_str("00"));
        assert!(
            reason.ends_with("does not have the column's stride of 20 bytes"),
            "{reason}"
        );
        let reason = encode_err(|t| t.nodes[1].commit_id.0.push('0'));
        assert!(
            reason.contains("stride of 20 bytes"),
            "an odd later id is a stride mismatch: {reason}"
        );
        let reason = encode_err(|t| t.nodes[0].commit_id.0 = "ab".repeat(256));
        assert!(reason.ends_with("is longer than 255 bytes"), "{reason}");
    }

    #[test]
    fn wire_casts_pass_values_through_and_saturate() {
        assert_eq!(wire_u32(5), 5);
        assert_eq!(wire_u32(usize::MAX), u32::MAX);
        assert_eq!(wire_prefix_len(40), 40);
        assert_eq!(wire_prefix_len(300), u8::MAX);
        assert_eq!(wire_edge_target(None), -1);
        assert_eq!(wire_edge_target(Some(3)), 3);
        assert_eq!(wire_edge_target(Some(usize::MAX)), i32::MAX);
    }

    /// Every `RevsetError` variant lands on its registry code with the reason / target as
    /// `context`. `graph.dangling_edge` is unreachable through jj-lib, so this pins that arm.
    #[test]
    fn map_topology_err_maps_every_variant() {
        let detail = |kind| zanshin_jj::RevsetErrorDetail {
            kind,
            span: None,
            symbol: Some("x".to_owned()),
            candidates: Vec::new(),
            hints: vec!["hint".to_owned()],
            message: String::new(),
        };
        for (error, code, kind) in [
            (
                RevsetError::ParseError {
                    reason: "bad syntax".to_owned(),
                    detail: Box::new(detail(zanshin_jj::RevsetErrorKind::SyntaxError)),
                },
                JJ_REVSET_PARSE_ERROR,
                zanshin_jj::RevsetErrorKind::SyntaxError,
            ),
            (
                RevsetError::ResolutionError {
                    reason: "no such bookmark".to_owned(),
                    detail: Box::new(detail(zanshin_jj::RevsetErrorKind::NoSuchRevision)),
                },
                JJ_REVSET_RESOLUTION_ERROR,
                zanshin_jj::RevsetErrorKind::NoSuchRevision,
            ),
        ] {
            let mapped = map_topology_err(error);
            assert_eq!(mapped.code, code);
            assert_eq!(mapped.hints, ["hint"], "the CLI's hints");
            let report = mapped.report.expect("the detail rides the report");
            assert_eq!(report.revset, Some(detail(kind)));
            assert!(report.precondition.is_none() && report.warnings.is_empty());
        }
        let cases = [
            (RevsetError::JjLibError("boom".to_owned()), JJ_JJ_LIB_ERROR, "boom"),
            (
                RevsetError::Config(ConfigError::Load {
                    reason: "/r/.jj/repo/config.toml: bad TOML".to_owned(),
                }),
                JJ_CONFIG_ERROR,
                "/r/.jj/repo/config.toml: bad TOML",
            ),
            (
                RevsetError::DanglingEdge {
                    target: "cafe".to_owned(),
                },
                GRAPH_DANGLING_EDGE,
                "cafe",
            ),
            (
                RevsetError::Precondition(PreconditionError::Backend("op heads".to_owned())),
                JJ_JJ_LIB_ERROR,
                "op heads",
            ),
        ];
        for (error, code, context) in cases {
            let mapped = map_topology_err(error);
            assert_eq!(mapped.code, code);
            assert_eq!(mapped.context.as_deref(), Some(context));
            assert!(
                mapped.report.is_none(),
                "the report is attached by precondition_envelope"
            );
        }
    }

    // ── Request reader ladder ────────────────────────────────────────────────

    struct RequestSpec<'s> {
        kind: fbs::RequestKind,
        revset: Option<&'s str>,
        prioritize: Option<&'s str>,
        short_prefixes: Option<&'s str>,
        anchors: Option<&'s [&'s str]>,
        with_timestamps: bool,
    }

    const FULL: RequestSpec<'static> = RequestSpec {
        kind: fbs::RequestKind::GraphTopology,
        revset: Some("all()"),
        prioritize: Some("present(@)"),
        short_prefixes: Some(""),
        anchors: Some(&["trunk()", "present(@)"]),
        with_timestamps: true,
    };

    fn request(spec: &RequestSpec<'_>) -> Vec<u8> {
        let mut b = FlatBufferBuilder::new();
        let revset = spec.revset.map(|s| b.create_string(s));
        let prioritize = spec.prioritize.map(|s| b.create_string(s));
        let short_prefixes = spec.short_prefixes.map(|s| b.create_string(s));
        let anchors = spec.anchors.map(|list| {
            let offsets: Vec<_> = list.iter().map(|s| b.create_string(s)).collect();
            b.create_vector(&offsets)
        });
        let req = fbs::GraphTopologyRequest::create(
            &mut b,
            &fbs::GraphTopologyRequestArgs {
                kind: spec.kind,
                revset,
                prioritize,
                short_prefixes,
                anchors,
                with_timestamps: spec.with_timestamps,
            },
        );
        b.finish(req, None);
        b.finished_data().to_vec()
    }

    fn read_err(bytes: &[u8]) -> (String, Option<String>) {
        let e = read_graph_topology_request(bytes.as_ptr(), bytes.len()).expect_err("must refuse");
        (e.code, e.context)
    }

    #[test]
    fn the_request_reader_passes_every_field_through() {
        let bytes = request(&FULL);
        let req = read_graph_topology_request(bytes.as_ptr(), bytes.len()).expect("valid request");
        assert_eq!(req.revset, "all()");
        assert_eq!(req.prioritize, "present(@)");
        assert_eq!(req.short_prefixes, "", "an empty string is a value, not an absence");
        assert_eq!(req.anchors, vec!["trunk()".to_owned(), "present(@)".to_owned()]);
        assert!(req.with_timestamps);
    }

    #[test]
    fn the_request_reader_treats_absent_anchors_as_empty_and_timestamps_as_false() {
        let bytes = request(&RequestSpec {
            anchors: None,
            with_timestamps: false,
            ..FULL
        });
        let req = read_graph_topology_request(bytes.as_ptr(), bytes.len()).expect("valid request");
        assert!(req.anchors.is_empty());
        assert!(!req.with_timestamps);
    }

    #[test]
    fn the_request_reader_refuses_null_unverifiable_and_mis_routed_buffers() {
        let e = read_graph_topology_request(std::ptr::null(), 0).expect_err("null");
        assert_eq!(e.code, FFI_NULL_POINTER);
        let (code, _) = read_err(&[1, 2, 3]);
        assert_eq!(code, FFI_INVALID_ARGUMENT);
        let (code, context) = read_err(&request(&RequestSpec {
            kind: fbs::RequestKind::CommitContents,
            ..FULL
        }));
        assert_eq!(code, FFI_INVALID_ARGUMENT);
        assert_eq!(
            context.as_deref(),
            Some("request kind mismatch: expected GraphTopology, got CommitContents")
        );
    }

    #[test]
    fn the_request_reader_names_each_absent_required_field() {
        for (spec, field) in [
            (RequestSpec { revset: None, ..FULL }, "revset"),
            (
                RequestSpec {
                    prioritize: None,
                    ..FULL
                },
                "prioritize",
            ),
            (
                RequestSpec {
                    short_prefixes: None,
                    ..FULL
                },
                "short_prefixes",
            ),
        ] {
            let (code, context) = read_err(&request(&spec));
            assert_eq!(code, JJ_INVALID_INPUT);
            assert_eq!(context, Some(format!("{field} is required")));
        }
    }
}
