//! `gen-inputs`: writes the layout INPUT files of the graph-layout A/B spike (SPEC.md §2)
//! into `../inputs/`.
//!
//! ```text
//! gen-inputs all        # fixtures + synth + manifest
//! gen-inputs fixtures   # jj dumps of the committed test fixtures
//! gen-inputs synth      # seeded synthetic repos
//! gen-inputs manifest   # re-count every inputs/*.json into inputs/manifest.json
//! gen-inputs dump --repo <path> --revset <expr> --out <file.json> [--now-ms <ms>]
//! ```
//!
//! `dump` writes ONE input from an arbitrary jj workspace (not into `inputs/`, not into the
//! manifest), plus a `<file>.meta.json` sidecar with each node's `CommitMeta` for a local viewer.
//! `now_ms` defaults to the wall clock and `utc_offset_min` is the local offset at `now_ms`
//! (SPEC.md §2). It runs under the same pinned environment as `fixtures` (no user jj/git config,
//! a throw-away `$XDG_CONFIG_HOME`), so user `[revset-aliases]` do not apply. NOTE: like every
//! Zanshin verb, the walk runs the pre-verb snapshot, which may write an operation to the repo.
//!
//! The design-sample inputs come from `node tools/design-input.mjs`; run it before
//! `manifest` (or `all`) so the manifest lists them too. Full regeneration, from the spike root
//! (every file is deterministic: the fixture dumps pin `now_ms`, the synth runs are seeded):
//!
//! ```text
//! node tools/design-input.mjs
//! CARGO_TARGET_DIR=rust-inputs/target cargo run --release --manifest-path rust-inputs/Cargo.toml -- all
//! ```

mod input;
mod jj_dump;
mod manifest;
mod synth;

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Instant;

pub struct FixtureDump {
    pub file: &'static str,
    pub fixture: &'static str,
    pub revset: &'static str,
}

pub struct DesignInput {
    pub file: &'static str,
    pub revset: &'static str,
    pub note: &'static str,
}

/// Over the medium fixture: branches A and B plus everything from the octopus merge up, minus
/// every commit whose description ends in 3 or 7. That yields Indirect edges (over the hidden
/// commits), Missing edges (BranchA-0 and BranchB-0 reach no member; the merge's third parent,
/// branch C, is entirely outside) and a merge whose Direct edges sit beside a Missing one.
pub const NARROW_REVSET: &str = r#"(description(glob:"Branch[AB]-*") | merge::) ~ description(glob:"*[37]")"#;

/// No default-revset (`zanshin_jj::DEFAULT_LOG_REVSET`) dumps: on these fixtures it equals
/// `all()` byte for byte (checked 2026-09-26). They have no remotes, so `trunk()` and
/// `immutable_heads()` are `root()`, and `ancestors(immutable_heads().., 2)` is every commit.
pub const FIXTURES: &[FixtureDump] = &[
    FixtureDump { file: "fixture-medium-all.json", fixture: "medium-1k-commits", revset: "all()" },
    FixtureDump { file: "fixture-medium-narrow.json", fixture: "medium-1k-commits", revset: NARROW_REVSET },
    FixtureDump { file: "fixture-large-all.json", fixture: "large-10k-commits", revset: "all()" },
];

/// The fixtures' fixed offset for calendar days (SPEC.md D7): Europe/Berlin summer time, which
/// is what the fixtures' 2001-09 timestamps and the synthetic runs would see there.
const UTC_OFFSET_MIN: i64 = 120;

pub const SYNTH: &[(&str, synth::Params)] = &[
    ("synth-10k.json", synth::Params { commits: 10_000, seed: 0x5EED_0010, utc_offset_min: UTC_OFFSET_MIN, bursts: &[(400, 500)] }),
    ("synth-50k.json", synth::Params { commits: 50_000, seed: 0x5EED_0050, utc_offset_min: UTC_OFFSET_MIN, bursts: &[(450, 520)] }),
    (
        "synth-100k.json",
        synth::Params { commits: 100_000, seed: 0x5EED_0100, utc_offset_min: UTC_OFFSET_MIN, bursts: &[(300, 360), (700, 740)] },
    ),
];

pub const DESIGN: &[DesignInput] = &[
    DesignInput {
        file: "design-default.json",
        revset: "default (the mock's inDefault flags)",
        note: "faithful to the mock: 14 of 22 commits incl. wqnwkozp, whose inDefault flag is wrong for the stated revset (jj would show 13 commits, the elided stub under vruxwmqv)",
    },
    DesignInput { file: "design-all.json", revset: "all", note: "all 22 commits incl. root()" },
];

fn inputs_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("inputs")
}

/// Keeps the dump off the developer's jj/git config, exactly like the test suites: no user
/// config, a fixed identity, and a throw-away `$XDG_CONFIG_HOME` for the secure config store
/// that opening a repo may write (Story 9.37).
fn pin_env() -> tempfile::TempDir {
    let xdg = tempfile::TempDir::new().expect("xdg tempdir");
    for (name, value) in test_helpers::TEST_ENV {
        std::env::set_var(name, value);
    }
    std::env::set_var("XDG_CONFIG_HOME", xdg.path());
    xdg
}

fn fixtures(dir: &Path) -> Result<(), String> {
    let _xdg = pin_env();
    let mut names: Vec<&str> = FIXTURES.iter().map(|f| f.fixture).collect();
    names.dedup();
    for name in names {
        let t = Instant::now();
        let fixture = test_helpers::extract_fixture(name).map_err(|e| format!("{name}: {e}"))?;
        eprintln!("extracted {name} in {:?}", t.elapsed());
        for f in FIXTURES.iter().filter(|f| f.fixture == name) {
            let t = Instant::now();
            let d = jj_dump::dump(&fixture.path, f.revset, "", 60_000, UTC_OFFSET_MIN)?;
            d.input.write(&dir.join(f.file))?;
            eprintln!(
                "  {} ← {:?}: {} nodes in {:?} (trunk() = {:?}, @ in graph: {})",
                f.file,
                f.revset,
                d.input.nodes.len(),
                t.elapsed(),
                d.trunk,
                d.wc_in_graph
            );
        }
    }
    Ok(())
}

fn synth(dir: &Path) -> Result<(), String> {
    for (file, p) in SYNTH {
        let t = Instant::now();
        let (input, stats) = synth::generate(p);
        input.write(&dir.join(file))?;
        eprintln!("  {file}: {} nodes in {:?} ({stats:?})", input.nodes.len(), t.elapsed());
    }
    Ok(())
}

/// `dump --repo <path> --revset <expr> --out <file.json> [--now-ms <ms>]` (see the module doc).
fn dump(args: &[String]) -> Result<(), String> {
    let (mut repo, mut revset, mut out, mut now_ms) = (None, None, None, None);
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let value = it.next().ok_or_else(|| format!("{flag} needs a value"))?;
        let slot = match flag.as_str() {
            "--repo" => &mut repo,
            "--revset" => &mut revset,
            "--out" => &mut out,
            "--now-ms" => &mut now_ms,
            _ => return Err(format!("unknown flag {flag}")),
        };
        if slot.replace(value.clone()).is_some() {
            return Err(format!("repeated flag {flag}"));
        }
    }
    let (Some(repo), Some(revset), Some(out)) = (repo, revset, out) else {
        return Err("usage: gen-inputs dump --repo <path> --revset <expr> --out <file.json> [--now-ms <ms>]".to_owned());
    };
    let out = PathBuf::from(out);
    let meta_path = out.with_extension("meta.json");
    let now_ms = match now_ms {
        Some(v) => v.parse::<i64>().map_err(|e| format!("--now-ms {v}: {e}"))?,
        None => i64::try_from(
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(|e| e.to_string())?.as_millis(),
        )
        .map_err(|e| e.to_string())?,
    };
    let utc_offset_min = {
        use chrono::{Offset as _, TimeZone as _};
        let local = chrono::Local.timestamp_millis_opt(now_ms).single().ok_or("now_ms is not a local instant")?;
        i64::from(local.offset().fix().local_minus_utc()) / 60
    };

    let _xdg = pin_env();
    let short_prefixes = zanshin_jj::DEFAULT_LOG_REVSET; // the CLI's `revsets.short-prefixes` default
    let t = Instant::now();
    let mut d = jj_dump::dump(Path::new(&repo), &revset, short_prefixes, 0, utc_offset_min)?;
    d.input.now_ms = now_ms;
    d.input.write(&out)?;
    let meta = jj_dump::meta_json(&revset, short_prefixes, &d);
    std::fs::write(&meta_path, format!("{meta}\n")).map_err(|e| format!("{}: {e}", meta_path.display()))?;
    let edges = d.input.nodes.iter().flat_map(|n| &n.parents).fold([0usize; 3], |mut c, p| {
        c[p.kind as usize] += 1;
        c
    });
    let dropped: usize = d.dropped_duplicates.iter().map(Vec::len).sum();
    eprintln!(
        "  {} ← {revset:?}: {} nodes, edges direct/indirect/missing = {edges:?}, dropped duplicate-target \
         edges {dropped}, in {:?} (trunk() in graph: {:?}, @ in graph: {}, now_ms {now_ms}, utc_offset_min \
         {utc_offset_min})",
        out.display(),
        d.input.nodes.len(),
        t.elapsed(),
        d.trunk.as_ref().map(|(_, in_graph)| *in_graph),
        d.wc_in_graph
    );
    Ok(())
}

fn main() -> ExitCode {
    let dir = inputs_dir();
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).cloned().unwrap_or_default();
    if cmd == "dump" {
        return match dump(&args[2..]) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("error: {e}");
                ExitCode::from(2)
            }
        };
    }
    if let Err(e) = std::fs::create_dir_all(&dir) {
        eprintln!("{}: {e}", dir.display());
        return ExitCode::from(2);
    }
    let result = match cmd.as_str() {
        "all" => fixtures(&dir).and_then(|()| synth(&dir)).and_then(|()| manifest::write(&dir)),
        "fixtures" => fixtures(&dir),
        "synth" => synth(&dir),
        "manifest" => manifest::write(&dir),
        _ => Err("usage: gen-inputs all|fixtures|synth|manifest|dump".to_owned()),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::from(2)
        }
    }
}
