// SPDX-License-Identifier: MIT

//! `coverage-check` — per-file Rust coverage **ratchet** gate.
//!
//! Reads the unified LCOV tracefile (the union of the FFI-path coverage and the
//! cargo-test coverage — see [`super::lcov_union`] and `Makefile.toml
//! [tasks.coverage]`), computes per-file line coverage, and gates it against a
//! committed baseline:
//!
//!   * a tracked file's coverage may not DROP (beyond `epsilon_pct`) — regression;
//!   * a NEW file must meet `new_file_floor_pct` — so no untested code slips in;
//!   * when coverage RISES (beyond `epsilon_pct`) the baseline is raised in place
//!     (the ratchet only ever tightens) and must be committed alongside the change.
//!
//! Scope: only workspace source under `crates/` is considered. Non-workspace
//! paths (stdlib under `.rustup`, the cargo registry) are dropped by the
//! `--workspace-root` relativisation, and `exclude_prefix` entries (xtask,
//! test-helpers) are filtered out. **Coverage here is Rust-only** — the union is
//! built from the cdylib (FFI path) and the cargo test binaries; Dart-side lines
//! are not measured by this gate.
//!
//! The baseline format is a small hand-rolled text file (no serde dependency, in
//! keeping with [`super::lcov_union`]'s hand-rolled LCOV parsing). It carries a
//! config header (`epsilon_pct`, `new_file_floor_pct`, `exclude_prefix`) followed
//! by one `path = pct` line per tracked file. The first run (baseline missing)
//! seeds it from the current measurement without enforcing the floor — the
//! ratchet tightens from "wherever we are today" upward.
//!
//! Note (Rule of Three): this is the second consumer of LCOV parsing after
//! `lcov_union.rs`, but the two parse different subsets (this one needs only
//! `SF`/`DA`), so the parsing is kept local rather than prematurely extracted
//! into a shared module — revisit if a third consumer appears.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::fs;
use std::path::PathBuf;

type DynError = Box<dyn std::error::Error + Send + Sync + 'static>;

/// Default tolerance (percentage points) absorbing measurement jitter: a change
/// within ±epsilon neither fails the gate nor churns the baseline.
const DEFAULT_EPSILON_PCT: f64 = 0.10;
/// Default minimum line coverage a brand-new file must reach.
const DEFAULT_NEW_FILE_FLOOR_PCT: f64 = 80.0;
/// Default exclusions (build tooling + test-only helper crate): not product code.
const DEFAULT_EXCLUDE_PREFIXES: &[&str] = &["crates/xtask/", "crates/test-helpers/"];

#[derive(clap::Args)]
pub struct CoverageCheckArgs {
    /// Unified LCOV tracefile to gate on (the `lcov-union` output).
    lcov: PathBuf,
    /// Baseline file. Created (seeded) on the first run if it does not exist.
    #[arg(short, long)]
    baseline: PathBuf,
    /// Workspace root. Absolute `SF:` paths under it are normalised to
    /// repo-relative; paths outside it (stdlib, registry) are dropped from scope.
    #[arg(long)]
    workspace_root: PathBuf,
}

/// The committed ratchet baseline: config knobs plus per-file coverage floors.
struct Baseline {
    epsilon_pct: f64,
    new_file_floor_pct: f64,
    exclude_prefixes: Vec<String>,
    /// `repo-relative path` → line coverage percentage (rounded to 2 decimals).
    files: BTreeMap<String, f64>,
}

impl Baseline {
    /// Parse a baseline file. Config keys are reserved names; every other
    /// `key = value` line is a `path = pct` entry (paths contain `/`, so they
    /// never collide with the config keys). Blank lines and `#` comments skipped.
    fn parse(text: &str) -> Result<Self, DynError> {
        let mut b = Baseline {
            epsilon_pct: DEFAULT_EPSILON_PCT,
            new_file_floor_pct: DEFAULT_NEW_FILE_FLOOR_PCT,
            exclude_prefixes: Vec::new(),
            files: BTreeMap::new(),
        };
        for raw in text.lines() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                return Err(format!("malformed baseline line (no `=`): {raw}").into());
            };
            let (key, value) = (key.trim(), value.trim());
            match key {
                "epsilon_pct" => {
                    b.epsilon_pct = value.parse().map_err(|e| format!("epsilon_pct: {value:?}: {e}"))?;
                }
                "new_file_floor_pct" => {
                    b.new_file_floor_pct = value
                        .parse()
                        .map_err(|e| format!("new_file_floor_pct: {value:?}: {e}"))?;
                }
                "exclude_prefix" => b.exclude_prefixes.push(value.to_owned()),
                path => {
                    let pct = value
                        .parse()
                        .map_err(|e| format!("coverage for {path:?}: {value:?}: {e}"))?;
                    b.files.insert(path.to_owned(), pct);
                }
            }
        }
        if b.exclude_prefixes.is_empty() {
            b.exclude_prefixes = DEFAULT_EXCLUDE_PREFIXES.iter().map(|s| (*s).to_owned()).collect();
        }
        Ok(b)
    }

    /// Render the baseline back to its committed text form (deterministic order).
    fn render(&self) -> String {
        let mut out = String::new();
        out.push_str(
            "# Zanshin Rust coverage ratchet baseline.\n\
             #\n\
             # Per-file line coverage (percent). AUTO-RAISED by `cargo make coverage`; never\n\
             # lowered. When a run raises a value, this file changes — commit it with the code\n\
             # that earned the coverage. A drop beyond epsilon_pct fails the gate; add tests.\n\
             # Rust-only (cdylib FFI path + cargo tests, unioned). See docs/coverage.md.\n\
             #\n",
        );
        let _ = writeln!(out, "epsilon_pct = {:.2}", self.epsilon_pct);
        let _ = writeln!(out, "new_file_floor_pct = {:.2}", self.new_file_floor_pct);
        for p in &self.exclude_prefixes {
            let _ = writeln!(out, "exclude_prefix = {p}");
        }
        out.push_str("#\n# path = pct\n");
        for (path, pct) in &self.files {
            let _ = writeln!(out, "{path} = {pct:.2}");
        }
        out
    }
}

/// Round to 2 decimals so storage, comparison, and rendering all agree.
fn round2(x: f64) -> f64 {
    (x * 100.0).round() / 100.0
}

/// Line coverage percentage for a `(covered, total)` pair, or `None` when the
/// file has no instrumentable lines (nothing to ratchet).
fn pct(covered: u64, total: u64) -> Option<f64> {
    if total == 0 {
        return None;
    }
    // WHY (clippy::cast_precision_loss): coverage line counts are tiny (far below
    // 2^53), so the u64→f64 cast is exact; precision loss is impossible here.
    #[allow(clippy::cast_precision_loss)]
    Some(round2(100.0 * covered as f64 / total as f64))
}

/// Parse an LCOV tracefile into per-file `(covered, total)` line counts, keeping
/// only in-scope workspace files: `SF:` paths under `root` are relativised, then
/// anything outside `crates/` or matching an exclude prefix is dropped.
fn parse_lcov_scoped(text: &str, root: &str, exclude_prefixes: &[String]) -> BTreeMap<String, (u64, u64)> {
    let mut files: BTreeMap<String, (u64, u64)> = BTreeMap::new();
    let mut current: Option<String> = None;
    for line in text.lines() {
        if let Some(sf) = line.strip_prefix("SF:") {
            current = relativise(sf, root).filter(|rel| in_scope(rel, exclude_prefixes));
            if let Some(rel) = &current {
                files.entry(rel.clone()).or_default();
            }
        } else if line == "end_of_record" {
            current = None;
        } else if let (Some(rel), Some(rest)) = (current.as_deref(), line.strip_prefix("DA:")) {
            // DA:<line>,<count>[,<checksum>] — total counts every instrumented line,
            // covered counts those with a non-zero hit count.
            if let Some((_, count)) = rest.split_once(',') {
                let count = count.split(',').next().unwrap_or("0");
                if let Ok(c) = count.parse::<u64>() {
                    let e = files.get_mut(rel).expect("SF entry precedes its DA records");
                    e.1 += 1;
                    if c > 0 {
                        e.0 += 1;
                    }
                }
            }
        }
    }
    files
}

/// Strip the `root/` prefix from an absolute `SF:` path, yielding a repo-relative
/// path. Returns `None` for paths outside the workspace (stdlib, registry).
fn relativise(sf: &str, root: &str) -> Option<String> {
    sf.strip_prefix(root)
        .map(|rest| rest.trim_start_matches('/').to_owned())
        .filter(|rel| !rel.is_empty())
}

/// A relativised path is in scope when it lives under `crates/` and matches no
/// exclude prefix.
fn in_scope(rel: &str, exclude_prefixes: &[String]) -> bool {
    rel.starts_with("crates/") && !exclude_prefixes.iter().any(|p| rel.starts_with(p.as_str()))
}

/// The outcome of comparing the current measurement against the baseline.
struct Evaluation {
    /// `(path, baseline_pct, current_pct)` — coverage dropped beyond epsilon.
    regressions: Vec<(String, f64, f64)>,
    /// `(path, current_pct, floor_pct)` — a new file below the floor.
    below_floor: Vec<(String, f64, f64)>,
    /// `(path, previous_pct_or_none, current_pct)` — a raised or newly added file.
    raised: Vec<(String, Option<f64>, f64)>,
    /// Files present in the baseline but absent from the current measurement.
    removed: Vec<String>,
    /// The baseline to write when the gate passes (existing raised, new added,
    /// removed dropped, stable kept at the old value to avoid jitter churn).
    next_files: BTreeMap<String, f64>,
}

impl Evaluation {
    fn passed(&self) -> bool {
        self.regressions.is_empty() && self.below_floor.is_empty()
    }

    fn baseline_changed(&self, previous: &BTreeMap<String, f64>) -> bool {
        &self.next_files != previous
    }
}

/// Compare current per-file coverage against the baseline floors.
fn evaluate(
    current: &BTreeMap<String, (u64, u64)>,
    epsilon: f64,
    floor: f64,
    baseline: &BTreeMap<String, f64>,
) -> Evaluation {
    let mut ev = Evaluation {
        regressions: Vec::new(),
        below_floor: Vec::new(),
        raised: Vec::new(),
        removed: Vec::new(),
        next_files: BTreeMap::new(),
    };
    for (path, &(covered, total)) in current {
        let Some(cur) = pct(covered, total) else { continue };
        match baseline.get(path) {
            Some(&base) => {
                if cur < base - epsilon {
                    ev.regressions.push((path.clone(), base, cur));
                    ev.next_files.insert(path.clone(), base); // keep floor; gate fails anyway
                } else if cur > base + epsilon {
                    ev.raised.push((path.clone(), Some(base), cur));
                    ev.next_files.insert(path.clone(), cur);
                } else {
                    ev.next_files.insert(path.clone(), base); // stable: no jitter churn
                }
            }
            None => {
                if cur + epsilon < floor {
                    ev.below_floor.push((path.clone(), cur, floor));
                    ev.next_files.insert(path.clone(), cur);
                } else {
                    ev.raised.push((path.clone(), None, cur));
                    ev.next_files.insert(path.clone(), cur);
                }
            }
        }
    }
    for path in baseline.keys() {
        if !current.contains_key(path) {
            ev.removed.push(path.clone());
        }
    }
    ev
}

/// Aggregate covered/total across all in-scope files, for the overall summary.
fn overall(current: &BTreeMap<String, (u64, u64)>) -> (u64, u64) {
    current.values().fold((0, 0), |(c, t), &(fc, ft)| (c + fc, t + ft))
}

/// Run `xtask coverage-check`: parse the unified LCOV, gate it against the
/// baseline, raise the baseline on improvement, and exit non-zero on regression.
///
/// # Errors
/// Returns an error if the LCOV or baseline cannot be read/parsed, or the
/// baseline cannot be written. A coverage regression is reported via
/// [`std::process::exit`] (exit code 1), not an `Err`.
pub fn run(args: &CoverageCheckArgs) -> Result<(), DynError> {
    let lcov_text = fs::read_to_string(&args.lcov).map_err(|e| format!("reading {}: {e}", args.lcov.display()))?;
    let root = args.workspace_root.to_string_lossy().trim_end_matches('/').to_owned();

    let existing = if args.baseline.exists() {
        Some(Baseline::parse(
            &fs::read_to_string(&args.baseline).map_err(|e| format!("reading {}: {e}", args.baseline.display()))?,
        )?)
    } else {
        None
    };

    let (epsilon, floor, excludes) = existing.as_ref().map_or_else(
        || {
            (
                DEFAULT_EPSILON_PCT,
                DEFAULT_NEW_FILE_FLOOR_PCT,
                DEFAULT_EXCLUDE_PREFIXES
                    .iter()
                    .map(|s| (*s).to_owned())
                    .collect::<Vec<_>>(),
            )
        },
        |b| (b.epsilon_pct, b.new_file_floor_pct, b.exclude_prefixes.clone()),
    );

    let current = parse_lcov_scoped(&lcov_text, &root, &excludes);
    if current.is_empty() {
        return Err(format!(
            "no in-scope coverage found in {} — wrong --workspace-root ({root}) or empty lcov?",
            args.lcov.display()
        )
        .into());
    }

    let (cov, tot) = overall(&current);
    let overall_pct = pct(cov, tot).unwrap_or(0.0);

    // First run: seed the baseline from the current measurement without enforcing
    // the floor. The ratchet tightens upward from today's state.
    let Some(existing) = existing else {
        let seeded = Baseline {
            epsilon_pct: epsilon,
            new_file_floor_pct: floor,
            exclude_prefixes: excludes,
            files: current
                .iter()
                .filter_map(|(p, &(c, t))| pct(c, t).map(|v| (p.clone(), v)))
                .collect(),
        };
        fs::write(&args.baseline, seeded.render()).map_err(|e| format!("writing {}: {e}", args.baseline.display()))?;
        println!(
            "coverage-check: seeded baseline {} from {} files (overall {overall_pct:.2}% = {cov}/{tot} lines).",
            args.baseline.display(),
            seeded.files.len(),
        );
        println!("  Commit it. Future runs gate that no file's coverage drops and new files reach {floor:.2}%.");
        return Ok(());
    };

    let ev = evaluate(&current, epsilon, floor, &existing.files);
    print_report(&current, &existing.files, &ev, overall_pct, cov, tot);

    if !ev.passed() {
        std::process::exit(1);
    }

    if ev.baseline_changed(&existing.files) {
        let next = Baseline {
            epsilon_pct: epsilon,
            new_file_floor_pct: floor,
            exclude_prefixes: existing.exclude_prefixes.clone(),
            files: ev.next_files.clone(),
        };
        fs::write(&args.baseline, next.render()).map_err(|e| format!("writing {}: {e}", args.baseline.display()))?;
        println!(
            "\ncoverage-check: baseline RAISED ({} file(s) up, {} new, {} removed) — commit {}.",
            ev.raised.iter().filter(|(_, old, _)| old.is_some()).count(),
            ev.raised.iter().filter(|(_, old, _)| old.is_none()).count(),
            ev.removed.len(),
            args.baseline.display(),
        );
    } else {
        println!("\ncoverage-check: OK — coverage held at {overall_pct:.2}% ({cov}/{tot} lines).");
    }
    Ok(())
}

/// Print the human-facing report: regressions and floor violations first (the
/// actionable failures), then the improvements, then the overall figure.
fn print_report(
    current: &BTreeMap<String, (u64, u64)>,
    baseline: &BTreeMap<String, f64>,
    ev: &Evaluation,
    overall_pct: f64,
    cov: u64,
    tot: u64,
) {
    for (path, base, cur) in &ev.regressions {
        println!("REGRESSION  {path}: {cur:.2}% < baseline {base:.2}% (add tests or revert)");
    }
    for (path, cur, floor) in &ev.below_floor {
        println!("BELOW FLOOR {path}: new file at {cur:.2}% < required {floor:.2}%");
    }
    for (path, old, cur) in &ev.raised {
        match old {
            Some(o) => println!("raised      {path}: {o:.2}% -> {cur:.2}%"),
            None => println!("new         {path}: {cur:.2}%"),
        }
    }
    for path in &ev.removed {
        let was = baseline.get(path).copied().unwrap_or(0.0);
        println!("removed     {path}: was {was:.2}% (dropped from baseline)");
    }
    let _ = current; // reserved for a future full per-file dump; counts come from overall()
    println!("---");
    println!(
        "overall: {overall_pct:.2}% ({cov}/{tot} lines over {} files)",
        current.len()
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn counts(pairs: &[(&str, u64, u64)]) -> BTreeMap<String, (u64, u64)> {
        pairs.iter().map(|(p, c, t)| ((*p).to_owned(), (*c, *t))).collect()
    }

    fn base(pairs: &[(&str, f64)]) -> BTreeMap<String, f64> {
        pairs.iter().map(|(p, v)| ((*p).to_owned(), *v)).collect()
    }

    // Float equality with a tiny tolerance: the values under test are exact 2-decimal
    // percentages, but `clippy::float_cmp` (pedantic) rejects bare `==`/`assert_eq!`.
    fn approx(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    #[test]
    fn drop_beyond_epsilon_is_a_regression() {
        // 8/10 = 80% against a 90% baseline -> regression.
        let cur = counts(&[("crates/a/src/x.rs", 8, 10)]);
        let ev = evaluate(&cur, 0.10, 80.0, &base(&[("crates/a/src/x.rs", 90.0)]));
        assert!(!ev.passed());
        assert_eq!(ev.regressions.len(), 1);
        // Gate fails -> baseline is held at the old floor, not lowered.
        assert!(approx(ev.next_files["crates/a/src/x.rs"], 90.0));
    }

    #[test]
    fn jitter_within_epsilon_neither_fails_nor_churns() {
        // 89.95% vs 90.00% baseline, epsilon 0.10 -> stable, baseline unchanged.
        let cur = counts(&[("crates/a/src/x.rs", 1799, 2000)]); // 89.95%
        let prev = base(&[("crates/a/src/x.rs", 90.0)]);
        let ev = evaluate(&cur, 0.10, 80.0, &prev);
        assert!(ev.passed());
        assert!(!ev.baseline_changed(&prev), "within epsilon must not rewrite");
        assert!(approx(ev.next_files["crates/a/src/x.rs"], 90.0));
    }

    #[test]
    fn rise_beyond_epsilon_raises_the_baseline() {
        let cur = counts(&[("crates/a/src/x.rs", 10, 10)]); // 100%
        let prev = base(&[("crates/a/src/x.rs", 90.0)]);
        let ev = evaluate(&cur, 0.10, 80.0, &prev);
        assert!(ev.passed());
        assert!(ev.baseline_changed(&prev));
        assert!(approx(ev.next_files["crates/a/src/x.rs"], 100.0));
        assert_eq!(ev.raised, vec![("crates/a/src/x.rs".to_owned(), Some(90.0), 100.0)]);
    }

    #[test]
    fn new_file_below_floor_fails() {
        let cur = counts(&[("crates/a/src/new.rs", 1, 10)]); // 10%
        let ev = evaluate(&cur, 0.10, 80.0, &BTreeMap::new());
        assert!(!ev.passed());
        assert_eq!(ev.below_floor.len(), 1);
    }

    #[test]
    fn new_file_meeting_floor_is_added() {
        let cur = counts(&[("crates/a/src/new.rs", 9, 10)]); // 90%
        let ev = evaluate(&cur, 0.10, 80.0, &BTreeMap::new());
        assert!(ev.passed());
        assert!(approx(ev.next_files["crates/a/src/new.rs"], 90.0));
        assert_eq!(ev.raised, vec![("crates/a/src/new.rs".to_owned(), None, 90.0)]);
    }

    #[test]
    fn removed_file_is_dropped_not_failed() {
        let cur = counts(&[("crates/a/src/x.rs", 10, 10)]);
        let prev = base(&[("crates/a/src/x.rs", 100.0), ("crates/a/src/gone.rs", 100.0)]);
        let ev = evaluate(&cur, 0.10, 80.0, &prev);
        assert!(ev.passed());
        assert_eq!(ev.removed, vec!["crates/a/src/gone.rs".to_owned()]);
        assert!(!ev.next_files.contains_key("crates/a/src/gone.rs"));
        assert!(ev.baseline_changed(&prev));
    }

    #[test]
    fn parse_lcov_relativises_and_scopes() {
        let root = "/work/repo";
        let text = "\
SF:/work/repo/crates/zanshin-ffi/src/repo.rs\nDA:1,1\nDA:2,0\nend_of_record\n\
SF:/work/repo/crates/xtask/src/main.rs\nDA:1,1\nend_of_record\n\
SF:/home/u/.rustup/toolchains/x/lib/std.rs\nDA:1,1\nend_of_record\n";
        let scoped = parse_lcov_scoped(text, root, &["crates/xtask/".to_owned()]);
        // Only the in-scope ffi file survives: xtask excluded, stdlib out of workspace.
        assert_eq!(scoped.len(), 1);
        assert_eq!(scoped["crates/zanshin-ffi/src/repo.rs"], (1, 2));
    }

    #[test]
    fn baseline_round_trips_through_parse_and_render() {
        let mut b = Baseline {
            epsilon_pct: 0.10,
            new_file_floor_pct: 80.0,
            exclude_prefixes: vec!["crates/xtask/".to_owned()],
            files: base(&[("crates/a/src/x.rs", 92.31), ("crates/a/src/y.rs", 100.0)]),
        };
        let parsed = Baseline::parse(&b.render()).expect("render output parses");
        assert!(approx(parsed.epsilon_pct, b.epsilon_pct));
        assert!(approx(parsed.new_file_floor_pct, b.new_file_floor_pct));
        assert_eq!(parsed.exclude_prefixes, b.exclude_prefixes);
        assert_eq!(parsed.files, b.files);
        // Empty exclude list falls back to the documented defaults.
        b.exclude_prefixes.clear();
        let reparsed = Baseline::parse(&b.render()).expect("parses");
        assert_eq!(reparsed.exclude_prefixes.len(), DEFAULT_EXCLUDE_PREFIXES.len());
    }
}
