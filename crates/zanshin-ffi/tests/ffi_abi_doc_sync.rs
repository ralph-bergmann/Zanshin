// SPDX-License-Identifier: MIT

//! Doc-staleness guard: every `zanshin_*` function exported from the generated
//! C header must be covered by `docs/ffi-abi.md`.
//!
//! `crates/zanshin-ffi/include/zanshin_ffi.h` is the authoritative inventory of the
//! FFI surface; `docs/ffi-abi.md` is the human-facing contract. Seven stories once
//! landed on that surface without the doc moving at all, which is what this test
//! exists to make impossible.
//!
//! The check is deliberately ONE-directional (header ⊆ doc). The reverse — a doc row
//! for a symbol the header no longer exports — is a rarer drift and is not guarded.
//!
//! Both scanners are pure functions over `&str` so the parsing rules themselves are
//! testable without touching the filesystem. Parsing is plain `str` methods: there is
//! no `regex` crate in this workspace and adding one would be a `cargo deny` surface.

use std::collections::BTreeSet;
use std::path::PathBuf;

/// Repo-root-relative path of the generated C header — the export inventory.
const HEADER_PATH: &str = "crates/zanshin-ffi/include/zanshin_ffi.h";

/// Repo-root-relative path of the ABI reference — the coverage source.
const DOC_PATH: &str = "docs/ffi-abi.md";

/// The workspace root, derived from this crate's manifest directory.
///
/// `CARGO_MANIFEST_DIR` is `crates/zanshin-ffi/`, so two parents up is the root.
fn repo_root() -> PathBuf {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .parent()
        .expect("crates/zanshin-ffi has a parent")
        .parent()
        .expect("crates has a parent (workspace root)")
        .to_path_buf()
}

/// Read a repo-root-relative artifact, naming the path in the failure message.
fn read_artifact(relative: &str) -> Result<String, String> {
    let path = repo_root().join(relative);
    std::fs::read_to_string(&path).map_err(|e| format!("cannot read {}: {e}", path.display()))
}

/// True for a line that is inside (or opens) a C comment block.
///
/// The header's rustdoc blocks name other `zanshin_*` symbols in prose — "freed via
/// `zanshin_buffer_free_token`", "same handle contract as `zanshin_bookmark_create`" —
/// and none of those is a declaration.
fn is_comment_line(line: &str) -> bool {
    let t = line.trim_start();
    t.starts_with('*') || t.starts_with("/*") || t.starts_with("//")
}

/// Extract the name of the `zanshin_*` function declared on `line`, if any.
///
/// A declaration is a lowercase `zanshin_` prefix followed by identifier characters and
/// then `(`. The lowercase prefix is what excludes the type `ZanshinBuf` and the include
/// guard `ZANSHIN_FFI_H`; the `(` is what excludes anything that merely mentions a name.
fn declared_symbol(line: &str) -> Option<String> {
    let start = line.find("zanshin_")?;
    let rest = &line[start..];
    let end = rest.find(|c: char| !c.is_ascii_lowercase() && !c.is_ascii_digit() && c != '_')?;
    if rest.as_bytes().get(end) != Some(&b'(') {
        return None;
    }
    Some(rest[..end].to_owned())
}

/// Every `zanshin_*` function the header declares, sorted and deduplicated.
///
/// A declaration may wrap across several lines (`zanshin_graph_slice` does); the name
/// always sits on the first, so each is counted exactly once.
fn exported_symbols(header_src: &str) -> BTreeSet<String> {
    header_src
        .lines()
        .filter(|line| !is_comment_line(line))
        .filter_map(declared_symbol)
        .collect()
}

/// Every `zanshin_*` symbol `docs/ffi-abi.md` gives a heading or an index row to.
///
/// Two shapes count as coverage, and nothing else does:
/// * a Markdown heading whose text names the symbol, and
/// * the FIRST cell of a table row (the symbol index).
///
/// A name mentioned in a later cell — an *Error codes* cell naming another wrapper, say
/// — is a cross-reference, not documentation of that symbol, and is not counted.
fn documented_symbols(doc_src: &str) -> BTreeSet<String> {
    let mut covered = BTreeSet::new();
    for line in doc_src.lines() {
        let trimmed = line.trim();
        let cell = if trimmed.starts_with('#') {
            trimmed.trim_start_matches('#')
        } else if let Some(body) = trimmed.strip_prefix('|') {
            // First cell: everything up to the next `|`.
            match body.find('|') {
                Some(end) => &body[..end],
                None => body,
            }
        } else {
            continue;
        };
        for word in cell.split(|c: char| !c.is_ascii_alphanumeric() && c != '_') {
            if word.starts_with("zanshin_") {
                covered.insert(word.to_owned());
            }
        }
    }
    covered
}

#[test]
fn every_exported_symbol_has_a_heading_or_an_index_row_in_the_abi_doc() {
    let header = read_artifact(HEADER_PATH).expect("the generated C header is committed");
    let doc = read_artifact(DOC_PATH).expect("the ABI reference is committed");

    let exported = exported_symbols(&header);
    assert!(
        !exported.is_empty(),
        "parsed no exported symbols out of {HEADER_PATH} — the scanner is broken, not the doc"
    );
    let documented = documented_symbols(&doc);

    let missing: Vec<&str> = exported
        .iter()
        .filter(|name| !documented.contains(*name))
        .map(String::as_str)
        .collect();

    assert!(
        missing.is_empty(),
        "{} of {} symbols exported from {HEADER_PATH} are undocumented in {DOC_PATH}.\n\
         Add a row to the `## Symbol index` table (or a `###` section) for each:\n  {}",
        missing.len(),
        exported.len(),
        missing.join("\n  ")
    );
}

#[test]
fn a_symbol_named_only_in_a_header_comment_is_not_counted_as_an_export() {
    let header = "\
/**
 * The returned token must be freed via `zanshin_buffer_free_token`.
 */
ZanshinBuf *zanshin_status(uint64_t handle);
";
    let exported = exported_symbols(header);
    assert_eq!(exported, BTreeSet::from(["zanshin_status".to_owned()]));
}

#[test]
fn a_declaration_wrapped_over_several_lines_is_counted_once() {
    let header = "\
ZanshinBuf *zanshin_graph_slice(uint64_t handle,
                                const char *revset,
                                const char *prioritize,
                                bool synthetic_elided,
                                const char *short_prefixes);
";
    let exported = exported_symbols(header);
    assert_eq!(exported, BTreeSet::from(["zanshin_graph_slice".to_owned()]));
}

#[test]
fn type_names_and_the_include_guard_are_not_counted_as_exports() {
    let header = "\
#ifndef ZANSHIN_FFI_H
#define ZANSHIN_FFI_H
typedef struct { uint8_t *ptr; uintptr_t len; } ZanshinBuf;
void zanshin_events_register(void (*callback)(ZanshinBuf *event));
";
    let exported = exported_symbols(header);
    assert_eq!(exported, BTreeSet::from(["zanshin_events_register".to_owned()]));
}

#[test]
fn a_name_in_a_non_first_table_cell_is_not_counted_as_documentation() {
    let doc = "\
| Symbol | Error codes |
|--------|-------------|
| `zanshin_status` | see `zanshin_undo` |
";
    let documented = documented_symbols(doc);
    assert!(documented.contains("zanshin_status"));
    assert!(
        !documented.contains("zanshin_undo"),
        "an Error-codes cross-reference must not count as coverage"
    );
}

#[test]
fn a_symbol_present_in_the_header_and_absent_from_the_doc_is_reported_as_missing() {
    let header = "ZanshinBuf *zanshin_undo(uint64_t handle);\n";
    let doc = "### `zanshin_status`\n";
    let exported = exported_symbols(header);
    let documented = documented_symbols(doc);
    let missing: Vec<&str> = exported
        .iter()
        .filter(|n| !documented.contains(*n))
        .map(String::as_str)
        .collect();
    assert_eq!(missing, ["zanshin_undo"]);
}

#[test]
fn a_heading_counts_as_documentation() {
    let documented = documented_symbols("### `zanshin_repo_detect`\n");
    assert_eq!(documented, BTreeSet::from(["zanshin_repo_detect".to_owned()]));
}

#[test]
fn reading_a_missing_artifact_fails_with_the_path_in_the_message() {
    let err = read_artifact("docs/no-such-file.md").expect_err("the path does not exist");
    assert!(
        err.contains("docs/no-such-file.md"),
        "the failure must name the path it tried to read, got: {err}"
    );
}
