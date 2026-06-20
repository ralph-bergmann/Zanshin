// SPDX-License-Identifier: MIT
//
// criterion bench: serialize time of serde_json vs FlatBuffers for both
// payloads across the size sweep. Wire sizes are printed once up front so the
// time numbers can be read alongside the byte counts.

use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use ffi_payload_bench::{
    gen_diff, gen_graph, to_fb_diff, to_fb_graph, to_json_diff, to_json_graph, DIFF_SIZES,
    GRAPH_SIZES,
};

fn bench_graph(c: &mut Criterion) {
    let mut group = c.benchmark_group("graph_serialize");
    for &n in GRAPH_SIZES {
        let model = gen_graph(n);
        let json = to_json_graph(&model);
        let fb = to_fb_graph(&model);
        eprintln!(
            "[size] graph nodes={n}: json={} B, fb={} B (fb/json={:.2})",
            json.len(),
            fb.len(),
            fb.len() as f64 / json.len() as f64
        );
        group.throughput(Throughput::Elements(n as u64));
        group.bench_with_input(BenchmarkId::new("json", n), &model, |b, m| {
            b.iter(|| to_json_graph(m));
        });
        group.bench_with_input(BenchmarkId::new("flatbuffers", n), &model, |b, m| {
            b.iter(|| to_fb_graph(m));
        });
    }
    group.finish();
}

fn bench_diff(c: &mut Criterion) {
    let mut group = c.benchmark_group("diff_serialize");
    for &n in DIFF_SIZES {
        let model = gen_diff(n);
        let json = to_json_diff(&model);
        let fb = to_fb_diff(&model);
        eprintln!(
            "[size] diff files={n}: json={} B, fb={} B (fb/json={:.2})",
            json.len(),
            fb.len(),
            fb.len() as f64 / json.len() as f64
        );
        group.throughput(Throughput::Elements(n as u64));
        group.bench_with_input(BenchmarkId::new("json", n), &model, |b, m| {
            b.iter(|| to_json_diff(m));
        });
        group.bench_with_input(BenchmarkId::new("flatbuffers", n), &model, |b, m| {
            b.iter(|| to_fb_diff(m));
        });
    }
    group.finish();
}

criterion_group!(benches, bench_graph, bench_diff);
criterion_main!(benches);
