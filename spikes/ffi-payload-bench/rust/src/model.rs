// SPDX-License-Identifier: Apache-2.0
//
// Synthetic, deterministically-seeded data models shaped like real Zanshin
// payloads. Field names are snake_case to match the project's JSON wire
// convention. Determinism (fixed seed) means the artifacts the Dart side reads
// are byte-identical to what the Rust criterion bench timed.

use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use serde::Serialize;

const CHANGE_ALPHA: &[u8] = b"klmnopqrstuvwxyz"; // jj-style reverse-hex (16 letters)
const HEX_ALPHA: &[u8] = b"0123456789abcdef";

const WORDS: &[&str] = &[
    "fix", "add", "refactor", "update", "remove", "graph", "diff", "lane", "commit", "parse",
    "render", "cache", "handle", "buffer", "isolate", "schema", "envelope", "watcher", "repo",
    "status", "change", "bookmark", "operation", "rebase", "squash", "resolve", "conflict",
    "snapshot", "tree", "index", "value", "result", "context", "boundary",
];

// ---------------------------------------------------------------- Graph slice

#[derive(Serialize)]
pub struct GraphNode {
    pub row: u32,
    pub lane: u32,
    pub color: u32,
    pub change_id: String,
    pub commit_id: String,
    pub parents: Vec<u32>,
    pub is_working_copy: bool,
    pub is_immutable: bool,
    pub summary: String,
}

#[derive(Serialize)]
pub struct GraphSlice {
    pub nodes: Vec<GraphNode>,
}

// ---------------------------------------------------------------------- Diff

#[derive(Serialize)]
pub struct DiffLine {
    pub origin: u8, // 0 context, 1 add, 2 remove (matches LineOrigin enum)
    pub old_lineno: u32,
    pub new_lineno: u32,
    pub content: String,
}

#[derive(Serialize)]
pub struct DiffHunk {
    pub old_start: u32,
    pub old_lines: u32,
    pub new_start: u32,
    pub new_lines: u32,
    pub header: String,
    pub lines: Vec<DiffLine>,
}

#[derive(Serialize)]
pub struct DiffFile {
    pub path: String,
    pub old_path: String,
    pub status: u8, // 0 added, 1 modified, 2 deleted, 3 renamed (matches FileStatus)
    pub hunks: Vec<DiffHunk>,
}

#[derive(Serialize)]
pub struct Diff {
    pub files: Vec<DiffFile>,
}

// --------------------------------------------------------------- Generators

fn rand_string(rng: &mut StdRng, len: usize, alphabet: &[u8]) -> String {
    (0..len)
        .map(|_| alphabet[rng.gen_range(0..alphabet.len())] as char)
        .collect()
}

fn rand_words(rng: &mut StdRng, max_words: usize) -> String {
    let n = rng.gen_range(0..=max_words);
    let mut s = String::new();
    for i in 0..n {
        if i > 0 {
            s.push(' ');
        }
        s.push_str(WORDS[rng.gen_range(0..WORDS.len())]);
    }
    s
}

fn rand_code_line(rng: &mut StdRng) -> String {
    let indent = rng.gen_range(0..4) * 4;
    let mut s = " ".repeat(indent);
    s.push_str(&rand_words(rng, 11));
    s
}

fn rand_path(rng: &mut StdRng) -> String {
    let depth = rng.gen_range(1..4);
    let mut parts = vec!["src".to_string()];
    for _ in 0..depth {
        parts.push(WORDS[rng.gen_range(0..WORDS.len())].to_string());
    }
    parts.push(format!(
        "{}_{}.rs",
        WORDS[rng.gen_range(0..WORDS.len())],
        WORDS[rng.gen_range(0..WORDS.len())]
    ));
    parts.join("/")
}

/// Generate a graph render slice of `node_count` nodes. Mostly linear history
/// with ~10% merge nodes (two parents), like a real jj log.
#[must_use]
pub fn gen_graph(node_count: usize) -> GraphSlice {
    let mut rng = StdRng::seed_from_u64(0x5a_4e_53_48); // "ZNSH"
    let mut nodes = Vec::with_capacity(node_count);
    for i in 0..node_count {
        let parents = if i == 0 {
            Vec::new()
        } else if i > 5 && rng.gen_bool(0.10) {
            vec![(i - 1) as u32, (i - rng.gen_range(2..=5)) as u32]
        } else {
            vec![(i - 1) as u32]
        };
        nodes.push(GraphNode {
            row: i as u32,
            lane: rng.gen_range(0..8),
            color: rng.gen_range(0..8),
            change_id: rand_string(&mut rng, 32, CHANGE_ALPHA),
            commit_id: rand_string(&mut rng, 40, HEX_ALPHA),
            parents,
            is_working_copy: i + 1 == node_count,
            is_immutable: rng.gen_bool(0.70),
            summary: rand_words(&mut rng, 10),
        });
    }
    GraphSlice { nodes }
}

/// Generate a diff over `file_count` files. Each file gets 1..=5 hunks, each
/// hunk 3..=30 lines, mostly context with ~20% add/remove.
#[must_use]
pub fn gen_diff(file_count: usize) -> Diff {
    let mut rng = StdRng::seed_from_u64(0x44_49_46_46); // "DIFF"
    let mut files = Vec::with_capacity(file_count);
    for _ in 0..file_count {
        let status = rng.gen_range(0..4) as u8;
        let hunk_count = rng.gen_range(1..=5);
        let mut hunks = Vec::with_capacity(hunk_count);
        let mut old_cursor = 1u32;
        let mut new_cursor = 1u32;
        for _ in 0..hunk_count {
            let line_count = rng.gen_range(3..=30);
            let mut lines = Vec::with_capacity(line_count);
            let (old_start, new_start) = (old_cursor, new_cursor);
            for _ in 0..line_count {
                let origin = match rng.gen_range(0..10) {
                    0 | 1 => 1u8, // add
                    2 => 2u8,     // remove
                    _ => 0u8,     // context
                };
                if origin != 1 {
                    old_cursor += 1;
                }
                if origin != 2 {
                    new_cursor += 1;
                }
                lines.push(DiffLine {
                    origin,
                    old_lineno: old_cursor,
                    new_lineno: new_cursor,
                    content: rand_code_line(&mut rng),
                });
            }
            hunks.push(DiffHunk {
                old_start,
                old_lines: old_cursor - old_start,
                new_start,
                new_lines: new_cursor - new_start,
                header: rand_words(&mut rng, 4),
                lines,
            });
            old_cursor += rng.gen_range(3..20);
            new_cursor = old_cursor;
        }
        files.push(DiffFile {
            path: rand_path(&mut rng),
            old_path: if status == 3 { rand_path(&mut rng) } else { String::new() },
            status,
            hunks,
        });
    }
    Diff { files }
}
