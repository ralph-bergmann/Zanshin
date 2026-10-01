//! `inputs/manifest.json`: per input file its source and counts, all recomputed from the files
//! themselves (so the manifest also covers the design inputs written by the node converter).

use std::path::Path;

use serde_json::{json, Map, Value};

use crate::{DESIGN, FIXTURES, NARROW_REVSET, SYNTH};

/// Source description of every registered input file, in manifest order.
fn registry() -> Vec<(String, Value)> {
    let mut out = Vec::new();
    for d in DESIGN {
        out.push((
            d.file.to_owned(),
            json!({
                "source": "design sample: _bmad-output/implementation-artifacts/design/graph-data.js at 57f259c (tools/design-source.mjs), converted by tools/design-input.mjs (docs/graph-layout.md §7.2)",
                "revset": d.revset,
                "note": d.note,
            }),
        ));
    }
    for f in FIXTURES {
        let mut note = "zanshin_jj::Repo::graph_topology (jj log pipeline, prioritize present(@), anchors [trunk(), present(@)]); \
                        ts = committer timestamp; now_ms = newest ts + 60 s; trunk() = root() (no remotes), so priority class 0 is the root only; \
                        the history is 2001-09 (one commit per minute) while @ is the fixture's generation-time working copy (2026-06)"
            .to_owned();
        if f.revset == NARROW_REVSET {
            note.push_str("; narrowed revset so Indirect and Missing edges occur (@ is outside it)");
        }
        out.push((
            f.file.to_owned(),
            json!({
                "source": format!("test-fixtures/repos/{}.tar.zst", f.fixture),
                "revset": f.revset,
                "note": note,
            }),
        ));
    }
    for (file, p) in SYNTH {
        out.push((
            (*file).to_owned(),
            json!({
                "source": "synthetic: rust-inputs/src/synth.rs",
                "seed": format!("{:#x}", p.seed),
                "commits_created": p.commits,
                "burst_permille": p.bursts,
                "note": "reverse creation order (not TopoGroupedGraph order); now_ms = 2026-09-25T14:00Z (the design's GRAPH_NOW), newest commit 5 min before; ~1.5 % of linear commits hidden (→ indirect), 3 % of merges get a missing parent",
            }),
        ));
    }
    out
}

struct Counts {
    nodes: usize,
    direct: usize,
    indirect: usize,
    missing: usize,
    layout_roots: usize,
    merges: usize,
    max_layout_parents: usize,
    nodes_with_missing: usize,
    ts_null: usize,
    non_monotonic_edges: usize,
    priority_max: u64,
    priority_hist: [usize; 3],
    ts_min: Option<i64>,
    ts_max: Option<i64>,
}

fn count(v: &Value) -> Result<Counts, String> {
    let nodes = v["nodes"].as_array().ok_or("no nodes array")?;
    let ts: Vec<Option<i64>> = nodes.iter().map(|n| n["ts_ms"].as_i64()).collect();
    let mut c = Counts {
        nodes: nodes.len(),
        direct: 0,
        indirect: 0,
        missing: 0,
        layout_roots: 0,
        merges: 0,
        max_layout_parents: 0,
        nodes_with_missing: 0,
        ts_null: ts.iter().filter(|t| t.is_none()).count(),
        non_monotonic_edges: 0,
        priority_max: 0,
        priority_hist: [0; 3],
        ts_min: ts.iter().flatten().min().copied(),
        ts_max: ts.iter().flatten().max().copied(),
    };
    for (i, n) in nodes.iter().enumerate() {
        let prio = n["priority"].as_u64().ok_or("priority")?;
        c.priority_max = c.priority_max.max(prio);
        if let Some(slot) = c.priority_hist.get_mut(prio as usize) {
            *slot += 1;
        }
        let mut lp = 0;
        let mut has_missing = false;
        for p in n["parents"].as_array().ok_or("parents")? {
            match p["kind"].as_str() {
                Some("direct") => c.direct += 1,
                Some("indirect") => c.indirect += 1,
                Some("missing") => {
                    c.missing += 1;
                    has_missing = true;
                    continue;
                }
                k => return Err(format!("bad kind {k:?}")),
            }
            lp += 1;
            let idx = p["idx"].as_u64().ok_or("idx")? as usize;
            if let (Some(tc), Some(tp)) = (ts[i], ts[idx]) {
                if tc < tp {
                    c.non_monotonic_edges += 1;
                }
            }
        }
        c.layout_roots += usize::from(lp == 0);
        c.merges += usize::from(lp >= 2);
        c.max_layout_parents = c.max_layout_parents.max(lp);
        c.nodes_with_missing += usize::from(has_missing);
    }
    Ok(c)
}

/// Epoch ms → "YYYY-MM-DDTHH:MM:SSZ" (civil-from-days, no chrono needed).
fn iso(ms: i64) -> String {
    let secs = ms.div_euclid(1000);
    let (days, sod) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", sod / 3600, sod % 3600 / 60, sod % 60)
}

pub fn write(dir: &Path) -> Result<(), String> {
    let mut entries = Vec::new();
    let mut known: Vec<String> = Vec::new();
    let mut files: Vec<(String, Value)> = registry();
    // Anything else in the directory (e.g. an ad-hoc dump) is listed as unregistered.
    let mut others: Vec<String> = std::fs::read_dir(dir)
        .map_err(|e| format!("{}: {e}", dir.display()))?
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|f| f.ends_with(".json") && f != "manifest.json")
        .collect();
    others.sort();
    known.extend(files.iter().map(|(f, _)| f.clone()));
    for f in others {
        if !known.contains(&f) {
            files.push((f, json!({ "source": "unregistered" })));
        }
    }

    for (file, meta) in files {
        let path = dir.join(&file);
        let Ok(bytes) = std::fs::read(&path) else {
            eprintln!("  manifest: {file} not generated yet, skipped");
            continue;
        };
        let v: Value = serde_json::from_slice(&bytes).map_err(|e| format!("{file}: {e}"))?;
        let c = count(&v).map_err(|e| format!("{file}: {e}"))?;
        let mut e = Map::new();
        e.insert("file".into(), json!(file));
        for (k, val) in meta.as_object().expect("registry entries are objects") {
            e.insert(k.clone(), val.clone());
        }
        e.insert("bytes".into(), json!(bytes.len()));
        e.insert("nodes".into(), json!(c.nodes));
        e.insert(
            "edges".into(),
            json!({ "direct": c.direct, "indirect": c.indirect, "missing": c.missing, "layout": c.direct + c.indirect }),
        );
        e.insert("layout_roots".into(), json!(c.layout_roots));
        e.insert("merges".into(), json!(c.merges));
        e.insert("max_layout_parents".into(), json!(c.max_layout_parents));
        e.insert("nodes_with_missing".into(), json!(c.nodes_with_missing));
        e.insert("ts_null".into(), json!(c.ts_null));
        e.insert("non_monotonic_edges".into(), json!(c.non_monotonic_edges));
        e.insert(
            "priority".into(),
            if c.priority_max <= 2 {
                json!({ "class0": c.priority_hist[0], "class1": c.priority_hist[1], "class2": c.priority_hist[2] })
            } else {
                json!({ "max": c.priority_max })
            },
        );
        e.insert("now_ms".into(), v["now_ms"].clone());
        e.insert("now".into(), json!(v["now_ms"].as_i64().map(iso)));
        e.insert("utc_offset_min".into(), v["utc_offset_min"].clone());
        e.insert("ts_range".into(), json!([c.ts_min.map(iso), c.ts_max.map(iso)]));
        entries.push(Value::Object(e));
    }
    let doc = json!({
        "spec": "docs/graph-layout.md §2 input format; regenerate as the doc comment of rust-inputs/src/main.rs says",
        "files": entries,
    });
    let text = serde_json::to_string_pretty(&doc).map_err(|e| e.to_string())? + "\n";
    std::fs::write(dir.join("manifest.json"), text).map_err(|e| e.to_string())?;
    eprintln!("wrote {}", dir.join("manifest.json").display());
    Ok(())
}
