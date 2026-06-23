// SPDX-License-Identifier: MIT

//! `lcov-union` — merge two or more LCOV tracefiles by taking, per source file and per
//! line / function / branch, the MAXIMUM hit count across inputs. A line is covered if
//! it is covered in ANY input.
//!
//! Why this exists: Zanshin's unified coverage combines the dart-test FFI-path lcov
//! (exported from the `--release` cdylib the worker loads) with the cargo-test lcov
//! (from cargo-llvm-cov's `debug` test binaries — which, unlike a hand-rolled `-object`
//! list, correctly enumerates the integration-test binaries named after their test file,
//! e.g. `revset-<hash>`). Those are DIFFERENT instrumented objects with different function
//! hashes, so a single `llvm-cov export` over one merged profdata cannot attribute one to
//! the other. Unioning the two lcovs at the source level is the correct combine.
//! See `Makefile.toml [tasks.coverage]`.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::fs;
use std::path::PathBuf;

type DynError = Box<dyn std::error::Error + Send + Sync + 'static>;

#[derive(clap::Args)]
pub struct LcovUnionArgs {
    /// Two or more input LCOV tracefiles to union.
    #[arg(required = true, num_args = 2..)]
    inputs: Vec<PathBuf>,
    /// Output tracefile path.
    #[arg(short, long)]
    output: PathBuf,
}

/// Accumulated coverage for one source file, keyed for deterministic output.
#[derive(Default)]
struct FileCov {
    /// `DA:line,count` — line → max count.
    lines: BTreeMap<u32, u64>,
    /// `FN:line,name` — function name → definition line.
    fn_def: BTreeMap<String, u32>,
    /// `FNDA:count,name` — function name → max count.
    fn_hits: BTreeMap<String, u64>,
    /// `BRDA:line,block,branch,count` — (line, block, branch) → max count
    /// (`None` means seen but never taken, rendered as `-`).
    branches: BTreeMap<(u32, u32, String), Option<u64>>,
}

/// Run `xtask lcov-union`: parse every input tracefile, union them, write the result.
///
/// # Errors
/// Returns an error if any input cannot be read or the output cannot be written.
pub fn run(args: &LcovUnionArgs) -> Result<(), DynError> {
    let mut files: BTreeMap<String, FileCov> = BTreeMap::new();
    for input in &args.inputs {
        let text = fs::read_to_string(input).map_err(|e| format!("reading {}: {e}", input.display()))?;
        parse_into(&text, &mut files);
    }
    fs::write(&args.output, render(&files)).map_err(|e| format!("writing {}: {e}", args.output.display()))?;
    Ok(())
}

/// Fold one tracefile's records into `files`, taking the max hit count for any
/// line / function / branch already seen.
fn parse_into(text: &str, files: &mut BTreeMap<String, FileCov>) {
    let mut current: Option<String> = None;
    for line in text.lines() {
        if let Some(path) = line.strip_prefix("SF:") {
            current = Some(path.to_owned());
            files.entry(path.to_owned()).or_default();
        } else if line == "end_of_record" {
            current = None;
        } else if let Some(name) = current.as_deref() {
            let cov = files
                .get_mut(name)
                .expect("SF record precedes its body, so the entry exists");
            fold_record(line, cov);
        }
    }
}

fn fold_record(line: &str, cov: &mut FileCov) {
    if let Some(rest) = line.strip_prefix("DA:") {
        // DA:<line>,<count>[,<checksum>]
        let mut it = rest.split(',');
        if let (Some(Ok(l)), Some(Ok(c))) = (it.next().map(str::parse::<u32>), it.next().map(str::parse::<u64>)) {
            let e = cov.lines.entry(l).or_insert(0);
            *e = (*e).max(c);
        }
    } else if let Some(rest) = line.strip_prefix("FN:") {
        // FN:<line>,<name>
        if let Some((l, name)) = rest.split_once(',') {
            if let Ok(l) = l.parse::<u32>() {
                cov.fn_def.insert(name.to_owned(), l);
            }
        }
    } else if let Some(rest) = line.strip_prefix("FNDA:") {
        // FNDA:<count>,<name>
        if let Some((c, name)) = rest.split_once(',') {
            if let Ok(c) = c.parse::<u64>() {
                let e = cov.fn_hits.entry(name.to_owned()).or_insert(0);
                *e = (*e).max(c);
            }
        }
    } else if let Some(rest) = line.strip_prefix("BRDA:") {
        // BRDA:<line>,<block>,<branch>,<count|->
        let parts: Vec<&str> = rest.splitn(4, ',').collect();
        if let [l, b, br, c] = parts[..] {
            if let (Ok(l), Ok(b)) = (l.parse::<u32>(), b.parse::<u32>()) {
                let count = if c == "-" { None } else { c.parse::<u64>().ok() };
                let e = cov.branches.entry((l, b, br.to_owned())).or_insert(None);
                *e = match (*e, count) {
                    (Some(a), Some(b)) => Some(a.max(b)),
                    (Some(a), None) => Some(a),
                    (None, x) => x,
                };
            }
        }
    }
    // SF/TN/LF/LH/FNF/FNH/BRF/BRH are recomputed on render; everything else is ignored.
}

/// Render the unioned coverage as an LCOV tracefile, recomputing all summary counters.
fn render(files: &BTreeMap<String, FileCov>) -> String {
    let mut out = String::new();
    for (sf, cov) in files {
        out.push_str("TN:\n");
        let _ = writeln!(out, "SF:{sf}");

        for (name, line) in &cov.fn_def {
            let _ = writeln!(out, "FN:{line},{name}");
        }
        for (name, count) in &cov.fn_hits {
            let _ = writeln!(out, "FNDA:{count},{name}");
        }
        let fnh = cov.fn_hits.values().filter(|c| **c > 0).count();
        let _ = writeln!(out, "FNF:{}", cov.fn_def.len());
        let _ = writeln!(out, "FNH:{fnh}");

        for ((line, block, branch), count) in &cov.branches {
            let rendered = count.map_or_else(|| "-".to_owned(), |c| c.to_string());
            let _ = writeln!(out, "BRDA:{line},{block},{branch},{rendered}");
        }
        if !cov.branches.is_empty() {
            let brh = cov.branches.values().filter(|c| matches!(c, Some(n) if *n > 0)).count();
            let _ = writeln!(out, "BRF:{}", cov.branches.len());
            let _ = writeln!(out, "BRH:{brh}");
        }

        for (line, count) in &cov.lines {
            let _ = writeln!(out, "DA:{line},{count}");
        }
        let lh = cov.lines.values().filter(|c| **c > 0).count();
        let _ = writeln!(out, "LF:{}", cov.lines.len());
        let _ = writeln!(out, "LH:{lh}");
        out.push_str("end_of_record\n");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn union_takes_max_count_per_line_and_recomputes_summaries() {
        // foo.rs: A covers line 1 (×2), misses 2; B misses 1, covers 2 (×5) and 3 (×1).
        // Union must cover all three lines with the max counts. bar.rs only in B.
        let a = "TN:\nSF:/x/foo.rs\nFN:1,fa\nFNDA:2,fa\nDA:1,2\nDA:2,0\nLF:2\nLH:1\nend_of_record\n";
        let b = "TN:\nSF:/x/foo.rs\nFN:1,fa\nFNDA:0,fa\nDA:1,0\nDA:2,5\nDA:3,1\nLF:3\nLH:2\nend_of_record\n\
                 SF:/x/bar.rs\nDA:7,4\nLF:1\nLH:1\nend_of_record\n";

        let mut files = BTreeMap::new();
        parse_into(a, &mut files);
        parse_into(b, &mut files);
        let out = render(&files);

        // foo.rs: every line covered, counts are the per-line max.
        assert!(out.contains("SF:/x/foo.rs\n"));
        assert!(out.contains("DA:1,2\n"), "line 1 max(2,0)=2\n{out}");
        assert!(out.contains("DA:2,5\n"), "line 2 max(0,5)=5\n{out}");
        assert!(out.contains("DA:3,1\n"), "line 3 only in B\n{out}");
        assert!(out.contains("FNDA:2,fa\n"), "fn hit count max(2,0)=2");
        // foo.rs has 3 lines, all hit after union.
        assert!(
            out.contains("LF:3\n") && out.contains("LH:3\n"),
            "recomputed LF/LH\n{out}"
        );
        assert!(out.contains("FNF:1\n") && out.contains("FNH:1\n"));
        // bar.rs carried through from B.
        assert!(out.contains("SF:/x/bar.rs\n") && out.contains("DA:7,4\n"));
    }

    #[test]
    fn union_recovers_a_line_each_input_misses_but_the_other_hits() {
        // The real-world case: cargo.lcov hits revset lines the ffi.lcov misses, and vice versa.
        let ffi = "SF:/r.rs\nDA:10,0\nDA:11,3\nend_of_record\n";
        let cargo = "SF:/r.rs\nDA:10,7\nDA:11,0\nend_of_record\n";
        let mut files = BTreeMap::new();
        parse_into(ffi, &mut files);
        parse_into(cargo, &mut files);
        let out = render(&files);
        assert!(
            out.contains("DA:10,7\n") && out.contains("DA:11,3\n"),
            "both lines recovered\n{out}"
        );
        assert!(out.contains("LH:2\n"), "both hit after union");
    }
}
