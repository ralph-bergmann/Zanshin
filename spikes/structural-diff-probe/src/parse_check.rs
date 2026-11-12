// SPDX-License-Identifier: MIT
//! `parse-check`: how the grammars of the reverted Stories 5.3 / 5.4 (tree-sitter 0.27.1 with
//! tree-sitter-rust 0.24.2, tree-sitter-dart 0.3.0, tree-sitter-md 0.5.4) and difft's own grammars
//! (`difft --dump-ts`) parse the `.rs`, `.dart` and `.md` files of the repository at `--rev`, two
//! known-bad samples (positive controls) and a set of newer Dart syntax samples.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use tree_sitter::{Parser, Point, Tree};

use crate::marks;
use crate::{git, ms, option, out_dir, repo_root};

/// Known-bad samples: every grammar must report an ERROR node on them.
const CONTROLS: &[(&str, &str, &str)] = &[
    ("Rust", "rs", "fn main() {\n    let = ;\n}\n"),
    ("Dart", "dart", "void f() {\n  final = ;\n}\n"),
];

/// Newer Dart syntax, oldest first.
const DART_SAMPLES: &[(&str, &str)] = &[
    (
        "records and patterns (3.0)",
        "void f() {\n  var (a, b) = (1, 2);\n  final {'k': v} = {'k': 1};\n}\n",
    ),
    (
        "switch expression (3.0)",
        "int f(Object o) => switch (o) {\n  int i when i > 0 => i,\n  (int a, int b) => a + b,\n  _ => 0,\n};\n",
    ),
    (
        "class modifiers (3.0)",
        "sealed class S {}\nfinal class F {}\nbase class B {}\ninterface class I {}\nmixin class M {}\n",
    ),
    ("extension type (3.3)", "extension type Id(int value) {}\n"),
    ("digit separators (3.6)", "void f() {\n  final n = 1_000_000;\n}\n"),
    (
        "wildcard variables (3.7)",
        "void f(void Function(int, int) g) {\n  final h = (_, _) => 0;\n}\n",
    ),
    (
        "null-aware elements (3.8)",
        "void f(int? a) {\n  final l = [?a, 1];\n}\n",
    ),
    ("dot shorthands (3.10)", "void f() {\n  Alignment a = .center;\n}\n"),
    ("primary constructor", "class Point(final int x, final int y);\n"),
];

/// Error counts of one parse.
#[derive(Default)]
struct Errors {
    error_nodes: usize,
    missing_nodes: usize,
    first: Option<Point>,
}

/// Per-language totals.
#[derive(Default)]
struct Tally {
    files: usize,
    bytes: usize,
    with_error: usize,
    with_missing_only: usize,
    error_nodes: usize,
    time: Duration,
    slowest: Duration,
    examples: Vec<String>,
    difft_files: usize,
    difft_with_error: usize,
    difft_examples: Vec<String>,
}

pub fn run(args: &[String]) -> Result<(), String> {
    let version = marks::require_difft()?;
    let repo = option(args, "--repo").map_or_else(repo_root, PathBuf::from);
    let rev = option(args, "--rev").unwrap_or("main");
    let head = String::from_utf8_lossy(&git(&repo, &["rev-parse", rev])?)
        .trim()
        .to_owned();
    let listed = git(&repo, &["ls-tree", "-r", "-z", "--name-only", &head])?;
    let work = out_dir("work-parse-check")?;
    let mut tallies = [
        ("Rust", Tally::default()),
        ("Dart", Tally::default()),
        ("Markdown", Tally::default()),
    ];
    for path in listed.split(|byte| *byte == 0).filter(|path| !path.is_empty()) {
        let path = String::from_utf8_lossy(path).into_owned();
        let (slot, extension) = match path.rsplit_once('.').map(|(_, extension)| extension) {
            Some("rs") => (0, "rs"),
            Some("dart") => (1, "dart"),
            Some("md") => (2, "md"),
            _ => continue,
        };
        let text = git(&repo, &["show", &format!("{head}:{path}")])?;
        let tally = &mut tallies[slot].1;
        let start = Instant::now();
        let errors = match slot {
            0 => tree_errors(&parse(&tree_sitter_rust::LANGUAGE.into(), &text)?),
            1 => tree_errors(&parse(&tree_sitter_dart::LANGUAGE.into(), &text)?),
            _ => markdown_errors(&text)?,
        };
        let elapsed = start.elapsed();
        tally.files += 1;
        tally.bytes += text.len();
        tally.time += elapsed;
        tally.slowest = tally.slowest.max(elapsed);
        tally.error_nodes += errors.error_nodes;
        if errors.error_nodes > 0 {
            tally.with_error += 1;
        } else if errors.missing_nodes > 0 {
            tally.with_missing_only += 1;
        }
        if let Some(point) = errors.first.filter(|_| tally.examples.len() < 12) {
            tally.examples.push(excerpt(&path, &text, point));
        }
        if slot < 2 {
            // difft picks its parser by file name, so the copy keeps the extension.
            let copy = work.join(format!("file.{extension}"));
            std::fs::write(&copy, &text).map_err(|error| format!("{}: {error}", copy.display()))?;
            tally.difft_files += 1;
            if let Some(point) = difft_first_error(&copy)? {
                tally.difft_with_error += 1;
                if tally.difft_examples.len() < 12 {
                    tally.difft_examples.push(excerpt(&path, &text, point));
                }
            }
        }
    }

    println!("difft: {version}\n");
    println!("#### Repository files at `{head}` (tracked, read with `git show`)\n");
    println!("| language | files | MB | tree-sitter 0.27.1 + 5.4 grammar: files with ERROR nodes | files with only MISSING nodes | ERROR nodes | parse time sum | slowest file | difft 0.72.0 grammar: files with ERROR nodes |");
    println!("|---|---:|---:|---:|---:|---:|---:|---:|---:|");
    for (language, tally) in &tallies {
        let difft = if tally.difft_files == 0 {
            "no parser".to_owned()
        } else {
            format!("{} of {}", tally.difft_with_error, tally.difft_files)
        };
        println!(
            "| {language} | {} | {:.1} | {} | {} | {} | {} ms | {} ms | {difft} |",
            tally.files,
            tally.bytes as f64 / 1_000_000.0,
            tally.with_error,
            tally.with_missing_only,
            tally.error_nodes,
            ms(tally.time),
            ms(tally.slowest),
        );
    }
    for (language, tally) in &tallies {
        if !tally.examples.is_empty() {
            println!(
                "\nFirst error per file, {language}, 5.4 grammar (up to 12):\n\n```text\n{}\n```",
                tally.examples.join("\n")
            );
        }
        if !tally.difft_examples.is_empty() {
            println!(
                "\nFirst ERROR per file, {language}, difft's grammar (up to 12):\n\n```text\n{}\n```",
                tally.difft_examples.join("\n")
            );
        }
    }

    println!("\n#### Positive controls (known-bad samples)\n");
    println!(
        "| sample | tree-sitter 0.27.1 + 5.4 grammar (ERROR / MISSING nodes) | difft 0.72.0's grammar (ERROR nodes) |"
    );
    println!("|---|---|---|");
    for (language, extension, code) in CONTROLS {
        let grammar: tree_sitter::Language = if *extension == "rs" {
            tree_sitter_rust::LANGUAGE.into()
        } else {
            tree_sitter_dart::LANGUAGE.into()
        };
        let errors = tree_errors(&parse(&grammar, code.as_bytes())?);
        let path = work.join(format!("control.{extension}"));
        std::fs::write(&path, code).map_err(|error| format!("{}: {error}", path.display()))?;
        let difft = if difft_first_error(&path)?.is_some() {
            "error"
        } else {
            "ok"
        };
        println!(
            "| {language} `{}` | {} | {difft} |",
            code.lines().nth(1).unwrap_or_default().trim(),
            found(&errors)
        );
    }

    println!("\n#### Newer Dart syntax\n");
    println!("| sample | tree-sitter-dart 0.3.0 (ERROR / MISSING nodes) | difft 0.72.0's Dart grammar (ERROR nodes) |");
    println!("|---|---|---|");
    for (name, code) in DART_SAMPLES {
        let errors = tree_errors(&parse(&tree_sitter_dart::LANGUAGE.into(), code.as_bytes())?);
        let path = work.join("sample.dart");
        std::fs::write(&path, code).map_err(|error| format!("{}: {error}", path.display()))?;
        let difft = if difft_first_error(&path)?.is_some() {
            "error"
        } else {
            "ok"
        };
        println!("| {name} | {} | {difft} |", found(&errors));
    }
    Ok(())
}

/// `ok`, or `error (<ERROR nodes> / <MISSING nodes>)`.
fn found(errors: &Errors) -> String {
    if errors.error_nodes + errors.missing_nodes == 0 {
        "ok".to_owned()
    } else {
        format!("error ({} / {})", errors.error_nodes, errors.missing_nodes)
    }
}

fn parse(language: &tree_sitter::Language, text: &[u8]) -> Result<Tree, String> {
    let mut parser = Parser::new();
    parser
        .set_language(language)
        .map_err(|error| format!("set_language: {error}"))?;
    parser
        .parse(text, None)
        .ok_or_else(|| "tree-sitter returned no tree".to_owned())
}

/// Counts the tree's ERROR and MISSING nodes, descending only into subtrees that hold one.
fn tree_errors(tree: &Tree) -> Errors {
    let mut errors = Errors::default();
    let mut cursor = tree.walk();
    loop {
        let node = cursor.node();
        if node.is_error() {
            errors.error_nodes += 1;
        }
        if node.is_missing() {
            errors.missing_nodes += 1;
        }
        if (node.is_error() || node.is_missing()) && errors.first.is_none() {
            errors.first = Some(node.start_position());
        }
        if node.has_error() && cursor.goto_first_child() {
            continue;
        }
        while !cursor.goto_next_sibling() {
            if !cursor.goto_parent() {
                return errors;
            }
        }
    }
}

/// tree-sitter-md's block tree and every inline tree, as its `MarkdownParser` builds them.
fn markdown_errors(text: &[u8]) -> Result<Errors, String> {
    let tree = tree_sitter_md::MarkdownParser::default()
        .parse(text, None)
        .ok_or_else(|| "tree-sitter-md returned no tree".to_owned())?;
    let mut errors = tree_errors(tree.block_tree());
    for inline in tree.inline_trees() {
        let more = tree_errors(inline);
        errors.error_nodes += more.error_nodes;
        errors.missing_nodes += more.missing_nodes;
        errors.first = errors.first.or(more.first);
    }
    Ok(errors)
}

/// The position of the first ERROR node in `difft --dump-ts`, which prints each node as
/// `<kind> (row, column) - (row, column)`.
fn difft_first_error(path: &Path) -> Result<Option<Point>, String> {
    let output = marks::difft()
        .arg("--dump-ts")
        .arg(path)
        .output()
        .map_err(|error| format!("difft --dump-ts: {error}"))?;
    // A failed dump would otherwise read as "no ERROR node".
    if !output.status.success() {
        return Err(format!(
            "difft --dump-ts {} failed: {}",
            path.display(),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    let dump = String::from_utf8_lossy(&output.stdout);
    Ok(dump
        .lines()
        .find(|line| line.trim_start().starts_with("ERROR ("))
        .and_then(|line| {
            let (row, column) = line.split_once('(')?.1.split_once(')')?.0.split_once(", ")?;
            Some(Point::new(row.trim().parse().ok()?, column.trim().parse().ok()?))
        }))
}

/// `path:line:column` and the line's text, cut at 100 characters.
fn excerpt(path: &str, text: &[u8], point: Point) -> String {
    let line = text.split(|byte| *byte == b'\n').nth(point.row).unwrap_or_default();
    let line: String = String::from_utf8_lossy(line).trim().chars().take(100).collect();
    format!("{path}:{}:{}  {line}", point.row + 1, point.column + 1)
}
