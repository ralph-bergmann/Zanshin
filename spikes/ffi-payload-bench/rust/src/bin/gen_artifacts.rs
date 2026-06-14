// SPDX-License-Identifier: Apache-2.0
//
// Writes the JSON and FlatBuffers encodings of every swept payload to
// ../artifacts/ plus a manifest.json, so the Dart side reads byte-identical
// data to what the Rust criterion bench timed.

use std::fs;
use std::path::Path;

use ffi_payload_bench::{
    gen_diff, gen_graph, to_fb_diff, to_fb_graph, to_json_diff, to_json_graph, DIFF_SIZES,
    GRAPH_SIZES,
};

fn main() {
    // WHY: resolve relative to the crate, not the (variable) invocation CWD.
    let out = Path::new(env!("CARGO_MANIFEST_DIR")).join("../artifacts");
    let out = out.as_path();
    fs::create_dir_all(out).expect("create artifacts dir");

    let mut entries = Vec::new();

    for &n in GRAPH_SIZES {
        let model = gen_graph(n);
        let json = to_json_graph(&model);
        let fb = to_fb_graph(&model);
        fs::write(out.join(format!("graph_{n}.json")), &json).unwrap();
        fs::write(out.join(format!("graph_{n}.fb")), &fb).unwrap();
        entries.push(entry("graph", n, json.len(), fb.len()));
        println!(
            "graph nodes={n:>6}: json={:>9} B  fb={:>9} B  (fb/json={:.2})",
            json.len(),
            fb.len(),
            fb.len() as f64 / json.len() as f64
        );
    }

    for &n in DIFF_SIZES {
        let model = gen_diff(n);
        let json = to_json_diff(&model);
        let fb = to_fb_diff(&model);
        fs::write(out.join(format!("diff_{n}.json")), &json).unwrap();
        fs::write(out.join(format!("diff_{n}.fb")), &fb).unwrap();
        entries.push(entry("diff", n, json.len(), fb.len()));
        println!(
            "diff  files={n:>6}: json={:>9} B  fb={:>9} B  (fb/json={:.2})",
            json.len(),
            fb.len(),
            fb.len() as f64 / json.len() as f64
        );
    }

    let manifest = format!("{{\n  \"entries\": [\n{}\n  ]\n}}\n", entries.join(",\n"));
    fs::write(out.join("manifest.json"), manifest).expect("write manifest");
    println!("\nwrote {} artifacts + manifest.json to {}", 2 * (GRAPH_SIZES.len() + DIFF_SIZES.len()), out.display());
}

fn entry(kind: &str, param: usize, json_bytes: usize, fb_bytes: usize) -> String {
    format!(
        "    {{ \"kind\": \"{kind}\", \"param\": {param}, \"json\": \"{kind}_{param}.json\", \"fb\": \"{kind}_{param}.fb\", \"json_bytes\": {json_bytes}, \"fb_bytes\": {fb_bytes} }}"
    )
}
