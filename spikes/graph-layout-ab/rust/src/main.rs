#![forbid(unsafe_code)]

//! `graph-layout` CLI (SPEC §6):
//!
//! ```text
//! layout --mode compact|time|free --order greedy|optimized <input.json> <output.json>
//! bench  --mode compact|time|free --order greedy|optimized --runs N [--warmup W] <input.json>
//! ```
//! Exit 0 on success; 2 on a usage error, invalid input, or an unreadable input / unwritable
//! output file (message on stderr, no output file). SPEC §6 knows only 0 and 2.

use std::hint::black_box;
use std::path::Path;
use std::process::ExitCode;
use std::time::Instant;

use graph_layout::layout::{self, Layout, Mode, Order};
use graph_layout::{order, output, parse_input};

const USAGE: &str = "usage:
  graph-layout layout --mode compact|time|free --order greedy|optimized <input.json> <output.json>
  graph-layout bench  --mode compact|time|free --order greedy|optimized [--runs N] [--warmup W] <input.json>
                      (--runs defaults to 31, --warmup to 10; SPEC §8.2)";

enum Fail {
    Usage(String),
    Input(String),
    Write(String),
}

struct Args {
    mode: Mode,
    order: Order,
    runs: usize,
    warmup: usize,
    positional: Vec<String>,
}

fn set<T>(slot: &mut Option<T>, name: &str, value: Option<T>, raw: &str) -> Result<(), Fail> {
    if slot.is_some() {
        return Err(Fail::Usage(format!("--{name} given twice")));
    }
    *slot = Some(value.ok_or_else(|| Fail::Usage(format!("invalid --{name} value: {raw:?}")))?);
    Ok(())
}

fn parse_args(cmd: &str, rest: &[String]) -> Result<Args, Fail> {
    let (mut mode, mut order, mut runs, mut warmup) = (None, None, None, None);
    let mut positional = Vec::new();
    let mut it = rest.iter();
    while let Some(arg) = it.next() {
        let Some(flag) = arg.strip_prefix("--") else {
            positional.push(arg.clone());
            continue;
        };
        let (name, value) = match flag.split_once('=') {
            Some((name, value)) => (name, value.to_owned()),
            None => {
                let value = it
                    .next()
                    .ok_or_else(|| Fail::Usage(format!("--{flag} needs a value")))?;
                (flag, value.clone())
            }
        };
        let count = |v: &str| v.parse::<usize>().ok();
        match name {
            "mode" => set(&mut mode, name, Mode::parse(&value), &value)?,
            "order" => set(&mut order, name, Order::parse(&value), &value)?,
            "runs" if cmd == "bench" => set(&mut runs, name, count(&value).filter(|&r| r >= 1), &value)?,
            "warmup" if cmd == "bench" => set(&mut warmup, name, count(&value), &value)?,
            _ => return Err(Fail::Usage(format!("unknown option --{name} for {cmd}"))),
        }
    }
    let want = if cmd == "layout" { 2 } else { 1 };
    if positional.len() != want {
        return Err(Fail::Usage(format!(
            "{cmd} takes {want} file argument(s), got {}",
            positional.len()
        )));
    }
    Ok(Args {
        mode: mode.ok_or_else(|| Fail::Usage("--mode is required".to_owned()))?,
        order: order.ok_or_else(|| Fail::Usage("--order is required".to_owned()))?,
        runs: runs.unwrap_or(31),
        warmup: warmup.unwrap_or(10),
        positional,
    })
}

fn read(path: &str) -> Result<Vec<u8>, Fail> {
    std::fs::read(path).map_err(|e| Fail::Usage(format!("cannot read {path}: {e}")))
}

fn run_layout(args: &Args) -> Result<(), Fail> {
    let bytes = read(&args.positional[0])?;
    let input = parse_input(&bytes).map_err(Fail::Input)?;
    let out = layout::layout(&input, args.mode, args.order);
    let json = output::to_canonical_json(&out);
    let dest = &args.positional[1];
    std::fs::write(dest, json).map_err(|e| Fail::Write(format!("cannot write {dest}: {e}")))
}

const PHASES: [&str; 7] = ["parse", "layering", "lanes", "blocked", "routing", "ordering", "total"];

fn nanos(from: Instant, to: Instant) -> u64 {
    u64::try_from(to.duration_since(from).as_nanos()).unwrap_or(u64::MAX)
}

fn run_bench(args: &Args) -> Result<(), Fail> {
    let path = &args.positional[0];
    let bytes = read(path)?;
    let name = Path::new(path)
        .file_name()
        .map_or_else(|| path.clone(), |f| f.to_string_lossy().into_owned());
    let mut samples: [Vec<u64>; 7] = Default::default();
    let mut last: Option<Layout> = None;
    for iter in 0..args.warmup + args.runs {
        let t0 = Instant::now();
        let input = parse_input(black_box(&bytes)).map_err(Fail::Input)?;
        let t1 = Instant::now();
        let graph = layout::prep(&input);
        let rows = layout::layering(&input, &graph, args.mode);
        let t2 = Instant::now();
        let lanes = layout::lanes(&input, &graph, &rows);
        let t3 = Instant::now();
        let blocked = layout::blocked(&graph, &rows, &lanes);
        let t4 = Instant::now();
        let routes = layout::routing(&graph, &lanes, &blocked);
        let t5 = Instant::now();
        let (pi, col) = order::ordering(&graph, &rows, &lanes, &routes, args.order);
        let t6 = Instant::now();
        if iter >= args.warmup {
            let spans = [(t0, t1), (t1, t2), (t2, t3), (t3, t4), (t4, t5), (t5, t6), (t1, t6)];
            for (sample, (from, to)) in samples.iter_mut().zip(spans) {
                sample.push(nanos(from, to));
            }
        }
        last = Some(black_box(Layout {
            mode: args.mode,
            order: args.order,
            graph,
            rows,
            lanes,
            blocked,
            routes,
            pi,
            col,
        }));
    }
    let out = last.expect("runs >= 1");
    let mut phases = String::new();
    for (k, (phase, sample)) in PHASES.iter().zip(samples.iter_mut()).enumerate() {
        sample.sort_unstable();
        if k > 0 {
            phases.push(',');
        }
        phases.push_str(&format!(
            "\"{phase}\":{{\"median_ns\":{},\"min_ns\":{}}}",
            sample[sample.len() / 2],
            sample[0]
        ));
    }
    println!(
        "{{\"impl\":\"rust\",\"input\":{},\"mode\":\"{}\",\"order\":\"{}\",\"nodes\":{},\"edges\":{},\"rows\":{},\"lanes\":{},\"digest\":{},\"warmup\":{},\"runs\":{},\"phases\":{{{phases}}}}}",
        serde_json::to_string(&name).expect("a string serialises"),
        args.mode.as_str(),
        args.order.as_str(),
        out.graph.len(),
        out.graph.edge_count(),
        out.rows_field(),
        out.lanes_field(),
        output::digest(&out),
        args.warmup,
        args.runs
    );
    Ok(())
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let result = match argv.first().map(String::as_str) {
        Some(cmd @ ("layout" | "bench")) => parse_args(cmd, &argv[1..]).and_then(|args| {
            if cmd == "layout" {
                run_layout(&args)
            } else {
                run_bench(&args)
            }
        }),
        Some(other) => Err(Fail::Usage(format!("unknown command {other:?}"))),
        None => Err(Fail::Usage("missing command".to_owned())),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(Fail::Usage(msg)) => {
            eprintln!("graph-layout: {msg}\n{USAGE}");
            ExitCode::from(2)
        }
        Err(Fail::Input(msg)) => {
            eprintln!("graph-layout: invalid input: {msg}");
            ExitCode::from(2)
        }
        Err(Fail::Write(msg)) => {
            eprintln!("graph-layout: {msg}");
            ExitCode::from(2)
        }
    }
}
