// SPDX-License-Identifier: MIT

//! Story 4.12: the graph topology wire, per store kind.
//!
//! Part 1 — the two layout comparisons the schema was decided by, each built with the raw
//! `flatbuffers` API over `Repo::graph_topology`'s output (so neither depends on the chosen
//! schema): OQ 2, the commit/change id columns as `[string]` display strings (option (a)) vs
//! fixed-stride `[ubyte]` raw id bytes (option (b)); and the node flags as one packed `[ubyte]`
//! vs six `[bool]` vectors. Each row prints the finished bytes and the build time.
//!
//! Part 2 — the chosen wire: the finished `Envelope<GraphTopology>` bytes and bytes/node,
//! `TopologyIds::encode` + `graph_topology_to_envelope` (the builder), timestamps off and on;
//! and, per repo store, the whole `zanshin_graph_topology` extern call (request encode, the
//! pre-verb snapshot, the topology walk, the encode and the token round trip).
//!
//! Stores: `medium-1k-commits` and `large-10k-commits` as committed (every object LOOSE), a
//! `git gc`-PACKED copy of `large-10k-commits` (packed in the bench's own extracted temp copy,
//! fixture-setup style), and a 100k-node synthetic `GraphTopology` (exploratory; no repo, so
//! no extern row).
//!
//! Prints sizes and min / median only; asserts nothing about wall-clock. Not run by
//! `cargo make test` / coverage (benches are excluded; see docs/coverage.md):
//!
//! ```sh
//! cargo bench -p zanshin-ffi --bench graph_wire
//! ```

use std::ffi::CString;
use std::path::Path;
use std::process::Command;
use std::sync::LazyLock;
use std::time::{Duration, Instant};
use std::{env, hint};

use flatbuffers::FlatBufferBuilder;
use test_helpers::extract_fixture;
use zanshin_ffi::envelope::CallReport;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::graph::{graph_topology_to_envelope, zanshin_graph_topology, TopologyIds};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_jj::{
    CommitId, CommitRef, GraphEdgeKind, GraphTopology, OperationId, Repo, TopologyEdge, TopologyMeta, TopologyNode,
    DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET,
};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // SAFETY: set once before any workspace load; pins jj-lib/git off the developer's
    // globals for reproducible timing (mirrors the test suites).
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
        env::set_var("JJ_USER", "Zanshin");
        env::set_var("JJ_EMAIL", "zanshin@localhost");
        env::set_var("JJ_OP_HOSTNAME", "localhost");
        env::set_var("JJ_OP_USERNAME", "zanshin");
        env::set_var("XDG_CONFIG_HOME", test_helpers::leaked_xdg_config_home());
    }
});

const WARMUP: u32 = 3;
const ITERS: u32 = 25;
const SYNTHETIC_NODES: usize = 100_000;

fn main() {
    LazyLock::force(&ENV_GUARD);
    for (name, packed) in [
        ("medium-1k-commits", false),
        ("large-10k-commits", false),
        ("large-10k-commits", true),
    ] {
        let fixture = extract_fixture(name).expect("fixture must extract");
        let root = fixture.path.as_path();
        if packed {
            let git_dir = root.join(".jj").join("repo").join("store").join("git");
            let status = Command::new("git")
                .arg(format!("--git-dir={}", git_dir.display()))
                .args(["-c", "gc.pruneExpire=never", "gc", "--quiet"])
                .status()
                .expect("git gc runs");
            assert!(status.success(), "git gc");
        }
        let store = format!("{name} {}", if packed { "packed" } else { "loose" });
        let mut repo = Repo::open(root).expect("open");
        let topology = repo
            .graph_topology(
                "all()",
                DEFAULT_GRAPH_PRIORITIZE,
                DEFAULT_LOG_REVSET,
                &["trunk()".to_owned(), "present(@)".to_owned()],
                true,
            )
            .expect("topology");
        eprintln!("[{store}] nodes={}", topology.nodes.len());
        bench_layouts(&store, &topology);
        bench_builder(&store, &topology);
        drop(repo);
        bench_extern(&store, root);
    }
    let synthetic = synthetic_topology(SYNTHETIC_NODES);
    let store = format!("synthetic {SYNTHETIC_NODES}");
    eprintln!("[{store}] nodes={}", synthetic.nodes.len());
    bench_layouts(&store, &synthetic);
    bench_builder(&store, &synthetic);
}

/// Returns `(min, median)` over `ITERS` timed runs after `WARMUP` untimed runs.
fn measure(mut f: impl FnMut()) -> (Duration, Duration) {
    for _ in 0..WARMUP {
        f();
    }
    let mut samples: Vec<Duration> = (0..ITERS)
        .map(|_| {
            let t = Instant::now();
            f();
            t.elapsed()
        })
        .collect();
    samples.sort_unstable();
    (samples[0], samples[samples.len() / 2])
}

fn report(store: &str, what: &str, (min, med): (Duration, Duration)) {
    eprintln!("[{store}] {what}: min {min:?} / med {med:?}");
}

fn report_bytes(store: &str, what: &str, bytes: usize, nodes: usize) {
    let per_node = bytes.checked_div(nodes).unwrap_or(0);
    eprintln!("[{store}] {what}: {bytes} B ({per_node} B/node)");
}

// ── Part 2: the chosen wire ──────────────────────────────────────────────────

/// The id encoding plus the payload builder — the encode half of the extern call.
fn encode(t: &GraphTopology, with_timestamps: bool) -> Vec<u8> {
    let ids = TopologyIds::encode(t).expect("well-formed ids");
    graph_topology_to_envelope(t, &ids, with_timestamps, &CallReport::default())
}

fn bench_builder(store: &str, t: &GraphTopology) {
    for with_timestamps in [false, true] {
        let label = if with_timestamps {
            "timestamps on"
        } else {
            "timestamps off"
        };
        report_bytes(
            store,
            &format!("GraphTopology envelope, {label}"),
            encode(t, with_timestamps).len(),
            t.nodes.len(),
        );
        report(
            store,
            &format!("TopologyIds::encode + graph_topology_to_envelope, {label}"),
            measure(|| {
                hint::black_box(encode(t, with_timestamps));
            }),
        );
    }
}

/// # Safety
/// `token` must be a fresh, non-null token from a `zanshin_*` function.
unsafe fn read_and_free(token: *mut ZanshinBuf) -> Vec<u8> {
    let bytes = unsafe {
        let t = &*token;
        std::slice::from_raw_parts(t.ptr.cast_const(), t.len).to_vec()
    };
    unsafe { zanshin_buffer_free_token(token) };
    bytes
}

/// A `GraphTopologyRequest` for `all()` with the CLI defaults and the default anchors.
fn topology_request(with_timestamps: bool) -> Vec<u8> {
    let mut b = FlatBufferBuilder::new();
    let revset = b.create_string("all()");
    let prioritize = b.create_string(DEFAULT_GRAPH_PRIORITIZE);
    let short_prefixes = b.create_string(DEFAULT_LOG_REVSET);
    let anchors: Vec<_> = ["trunk()", "present(@)"].iter().map(|s| b.create_string(s)).collect();
    let anchors = b.create_vector(&anchors);
    let req = fbs::GraphTopologyRequest::create(
        &mut b,
        &fbs::GraphTopologyRequestArgs {
            kind: fbs::RequestKind::GraphTopology,
            revset: Some(revset),
            prioritize: Some(prioritize),
            short_prefixes: Some(short_prefixes),
            anchors: Some(anchors),
            with_timestamps,
        },
    );
    b.finish(req, None);
    b.finished_data().to_vec()
}

/// The whole extern call on one reused handle, timestamps off and on.
fn bench_extern(store: &str, root: &Path) {
    let path = CString::new(root.to_str().expect("UTF-8 path")).expect("no NUL");
    // SAFETY: `path` is a valid NUL-terminated C string alive for the call.
    let bytes = unsafe { read_and_free(zanshin_repo_open(path.as_ptr())) };
    let env = flatbuffers::root::<fbs::Envelope>(&bytes).expect("envelope");
    assert!(env.ok(), "open");
    let handle = env.data_as_repo_handle().expect("handle").handle();
    for with_timestamps in [false, true] {
        let label = if with_timestamps {
            "timestamps on"
        } else {
            "timestamps off"
        };
        report(
            store,
            &format!("zanshin_graph_topology extern call, {label}"),
            measure(|| {
                let request = topology_request(with_timestamps);
                // SAFETY: the handle is live; `request` outlives the call.
                let reply = unsafe { read_and_free(zanshin_graph_topology(handle, request.as_ptr(), request.len())) };
                assert!(
                    flatbuffers::root::<fbs::Envelope>(&reply).expect("envelope").ok(),
                    "topology call"
                );
                hint::black_box(reply);
            }),
        );
    }
    // SAFETY: the handle came from `zanshin_repo_open` above and is closed once.
    let bytes = unsafe { read_and_free(zanshin_repo_close(handle)) };
    assert!(
        flatbuffers::root::<fbs::Envelope>(&bytes).expect("envelope").ok(),
        "close"
    );
}

// ── Part 1: the layout comparisons ───────────────────────────────────────────

fn bench_layouts(store: &str, t: &GraphTopology) {
    let n = t.nodes.len();
    report_bytes(store, "OQ 2 (a) ids as [string]", ids_as_strings(t).len(), n);
    report_bytes(store, "OQ 2 (b) ids as stride [ubyte]", ids_as_stride_bytes(t).len(), n);
    report(
        store,
        "OQ 2 (a) ids as [string] build",
        measure(|| {
            hint::black_box(ids_as_strings(t));
        }),
    );
    report(
        store,
        "OQ 2 (b) ids as stride [ubyte] build",
        measure(|| {
            hint::black_box(ids_as_stride_bytes(t));
        }),
    );
    report_bytes(store, "flags packed [ubyte]", flags_packed(t).len(), n);
    report_bytes(store, "flags six [bool]", flags_as_bools(t).len(), n);
    report(
        store,
        "flags packed [ubyte] build",
        measure(|| {
            hint::black_box(flags_packed(t));
        }),
    );
    report(
        store,
        "flags six [bool] build",
        measure(|| {
            hint::black_box(flags_as_bools(t));
        }),
    );
}

/// Finishes a root table whose fields are `vectors`, in order (field `i` at vtable slot
/// `4 + 2 i`), and returns the finished bytes.
fn finish_columns(
    mut b: FlatBufferBuilder<'_>,
    vectors: &[flatbuffers::WIPOffset<flatbuffers::UnionWIPOffset>],
    trailing_u8: &[u8],
) -> Vec<u8> {
    let start = b.start_table();
    let mut slot: flatbuffers::VOffsetT = 4;
    for v in vectors {
        b.push_slot_always(slot, *v);
        slot += 2;
    }
    for &byte in trailing_u8 {
        b.push_slot::<u8>(slot, byte, 0);
        slot += 2;
    }
    let root = b.end_table(start);
    b.finish_minimal(root);
    b.finished_data().to_vec()
}

/// Option (a): two `[string]` columns, the display strings as `zanshin-jj` returns them.
fn ids_as_strings(t: &GraphTopology) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(64 + t.nodes.len() * 100);
    let commit: Vec<_> = t.nodes.iter().map(|n| b.create_string(&n.commit_id.0)).collect();
    let commit = b.create_vector(&commit).as_union_value();
    let change: Vec<_> = t.nodes.iter().map(|n| b.create_string(&n.meta.change_id)).collect();
    let change = b.create_vector(&change).as_union_value();
    finish_columns(b, &[commit, change], &[])
}

/// Forward hex digit → nibble; bit 4 set marks a non-digit. Branch-free so the per-id loop
/// vectorises.
fn hex_nibble(c: u8) -> u8 {
    let digit = c.wrapping_sub(b'0');
    let letter = c.wrapping_sub(b'a');
    if digit < 10 {
        digit
    } else if letter < 6 {
        letter + 10
    } else {
        0x10
    }
}

/// jj reverse-hex digit (`z` = 0 … `k` = 15) → nibble; bit 4 set marks a non-digit.
fn reverse_hex_nibble(c: u8) -> u8 {
    let v = b'z'.wrapping_sub(c);
    if v < 16 {
        v
    } else {
        0x10
    }
}

/// Decodes every id of one column into `n × stride` bytes, validating each digit — the
/// encoder's work. Returns `(bytes, stride)`.
fn decode_column<'s>(mut ids: impl Iterator<Item = &'s str>, nibble: fn(u8) -> u8, n: usize) -> (Vec<u8>, u8) {
    let Some(first) = ids.next() else {
        return (Vec::new(), 0);
    };
    let stride = first.len() / 2;
    let mut out = vec![0u8; n * stride];
    let mut bad = 0u8;
    for (id, dst) in std::iter::once(first).chain(ids).zip(out.chunks_exact_mut(stride)) {
        let raw = id.as_bytes();
        assert_eq!(raw.len(), 2 * stride, "one even stride per column");
        for (byte, pair) in dst.iter_mut().zip(raw.chunks_exact(2)) {
            let hi = nibble(pair[0]);
            let lo = nibble(pair[1]);
            bad |= hi | lo;
            *byte = hi << 4 | lo & 0x0f;
        }
    }
    assert_eq!(bad & 0xf0, 0, "every digit valid");
    (out, u8::try_from(stride).expect("stride fits u8"))
}

/// Option (b): two `n × stride` `[ubyte]` columns plus the two strides.
fn ids_as_stride_bytes(t: &GraphTopology) -> Vec<u8> {
    let n = t.nodes.len();
    let (commit, commit_stride) = decode_column(t.nodes.iter().map(|n| n.commit_id.0.as_str()), hex_nibble, n);
    let (change, change_stride) =
        decode_column(t.nodes.iter().map(|n| n.meta.change_id.as_str()), reverse_hex_nibble, n);
    let mut b = FlatBufferBuilder::with_capacity(64 + commit.len() + change.len());
    let commit = b.create_vector(&commit).as_union_value();
    let change = b.create_vector(&change).as_union_value();
    finish_columns(b, &[commit, change], &[commit_stride, change_stride])
}

/// The six node flags packed into one byte per node.
fn flags_packed(t: &GraphTopology) -> Vec<u8> {
    let flags: Vec<u8> = t
        .nodes
        .iter()
        .map(|n| {
            let m = &n.meta;
            u8::from(m.working_copy)
                | u8::from(m.immutable) << 1
                | u8::from(m.hidden) << 2
                | u8::from(m.divergent) << 3
                | u8::from(m.root) << 4
                | u8::from(m.change_offset.is_some()) << 5
        })
        .collect();
    let mut b = FlatBufferBuilder::with_capacity(64 + flags.len());
    let v = b.create_vector(&flags).as_union_value();
    finish_columns(b, &[v], &[])
}

/// The six node flags as six `[bool]` vectors.
fn flags_as_bools(t: &GraphTopology) -> Vec<u8> {
    let columns: [fn(&TopologyMeta) -> bool; 6] = [
        |m| m.working_copy,
        |m| m.immutable,
        |m| m.hidden,
        |m| m.divergent,
        |m| m.root,
        |m| m.change_offset.is_some(),
    ];
    let mut b = FlatBufferBuilder::with_capacity(64 + 6 * t.nodes.len());
    let vectors: Vec<_> = columns
        .iter()
        .map(|column| {
            let values: Vec<bool> = t.nodes.iter().map(|n| column(&n.meta)).collect();
            b.create_vector(&values).as_union_value()
        })
        .collect();
    finish_columns(b, &vectors, &[])
}

// ── The 100k synthetic topology ──────────────────────────────────────────────

/// A deterministic xorshift64 stream — no dependency, reproducible ids.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn id(&mut self, bytes: usize, digits: &[u8; 16]) -> String {
        (0..bytes)
            .flat_map(|_| {
                let byte = self.next().to_le_bytes()[0];
                [digits[usize::from(byte >> 4)], digits[usize::from(byte & 0xf)]]
            })
            .map(char::from)
            .collect()
    }
}

/// A `jj log`-shaped synthetic topology: one chain to the root, a merge every 50 nodes, a
/// bookmark every 100, a timestamp on every non-root node.
fn synthetic_topology(n: usize) -> GraphTopology {
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
    let nodes = (0..n)
        .map(|i| {
            let is_root = i + 1 == n;
            let mut edges = Vec::new();
            if !is_root {
                edges.push(TopologyEdge {
                    target: Some(i + 1),
                    kind: GraphEdgeKind::Direct,
                });
            }
            if i % 50 == 0 && i + 7 < n {
                edges.push(TopologyEdge {
                    target: Some(i + 7),
                    kind: GraphEdgeKind::Indirect,
                });
            }
            let bookmarks = if i % 100 == 0 {
                vec![CommitRef {
                    name: format!("feature-{i}"),
                    remote: None,
                    synced: true,
                    conflicted: false,
                }]
            } else {
                Vec::new()
            };
            TopologyNode {
                commit_id: CommitId(rng.id(20, b"0123456789abcdef")),
                meta: TopologyMeta {
                    change_id: rng.id(16, b"zyxwvutsrqponmlk"),
                    change_id_prefix_len: 4,
                    commit_id_prefix_len: 5,
                    change_offset: None,
                    bookmarks,
                    tags: Vec::new(),
                    working_copies: Vec::new(),
                    working_copy: i == 0,
                    immutable: i > n / 2,
                    hidden: false,
                    divergent: false,
                    root: is_root,
                    parent_count: u32::try_from(edges.len()).expect("small"),
                },
                edges,
                committer_timestamp_ms: (!is_root).then(|| 1_700_000_000_000 - i64::try_from(i).expect("fits") * 1000),
            }
        })
        .collect();
    GraphTopology {
        operation_id: OperationId("ab".repeat(64)),
        nodes,
        anchors: vec![vec![n - 1], vec![0]],
        all_count: n,
        extra_operation_ids: vec![],
    }
}
