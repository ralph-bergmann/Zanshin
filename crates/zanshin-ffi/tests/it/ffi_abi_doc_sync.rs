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

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

/// Repo-root-relative path of the generated C header — the export inventory.
const HEADER_PATH: &str = "crates/zanshin-ffi/include/zanshin_ffi.h";

/// Repo-root-relative path of the ABI reference — the coverage source.
const DOC_PATH: &str = "docs/ffi-abi.md";

/// Repo-root-relative path of the error-code registry.
const REGISTRY_PATH: &str = "docs/rust-error-codes.md";

/// How many `zanshin_*` functions the header is expected to declare.
///
/// Pinned so the subset check cannot pass vacuously: if a scanner regression shrank the
/// export set, every remaining symbol would still be documented and the guard would stay
/// green. Same reasoning as the expected-file-count assertion in `Makefile.toml`'s
/// `test-cargo-hygiene`. Bumping it is a deliberate edit that rides with the doc's own
/// prose counts.
const EXPECTED_EXPORTS: usize = 107;

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

/// Every `zanshin_*` function declared on `line`.
///
/// A declaration is a lowercase `zanshin_` prefix followed by identifier characters and
/// then `(`. The lowercase prefix is what excludes the type `ZanshinBuf` and the include
/// guard `ZANSHIN_FFI_H`; the `(` is what excludes anything that merely mentions a name.
///
/// EVERY occurrence on the line is examined, not just the first. Bailing after one miss
/// would silently drop the declaration on a line whose return type also starts with
/// `zanshin_` — and a symbol the scanner drops is a symbol the doc is never asked for,
/// which is the one way this guard could pass while stale.
fn declared_symbols(line: &str) -> Vec<String> {
    let mut found = Vec::new();
    for (start, _) in line.match_indices("zanshin_") {
        let rest = &line[start..];
        let Some(end) = rest.find(|c: char| !c.is_ascii_lowercase() && !c.is_ascii_digit() && c != '_') else {
            continue;
        };
        if rest.as_bytes().get(end) == Some(&b'(') {
            found.push(rest[..end].to_owned());
        }
    }
    found
}

/// Every `zanshin_*` function the header declares, sorted and deduplicated.
///
/// A declaration may wrap across several lines (`zanshin_git_remote_set_url` does); the name
/// always sits on the first, so each is counted exactly once.
fn exported_symbols(header_src: &str) -> BTreeSet<String> {
    header_src
        .lines()
        .filter(|line| !is_comment_line(line))
        .flat_map(declared_symbols)
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
///
/// Fenced code blocks are skipped: the document carries ```` ```c ```` and ```` ```dart ````
/// samples, and a `#`-comment or pipe-prefixed line inside one is a sample, not a heading
/// or a row. This mirrors [`is_comment_line`] on the header side.
fn documented_symbols(doc_src: &str) -> BTreeSet<String> {
    let mut covered = BTreeSet::new();
    let mut in_fence = false;
    for line in doc_src.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("```") {
            in_fence = !in_fence;
            continue;
        }
        if in_fence {
            continue;
        }
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

/// Exported symbols with no heading and no index row, sorted.
///
/// Factored out so the failure the guard reports is produced by the same code the
/// fixture test drives.
fn missing_symbols(header_src: &str, doc_src: &str) -> Vec<String> {
    let documented = documented_symbols(doc_src);
    exported_symbols(header_src)
        .into_iter()
        .filter(|name| !documented.contains(name))
        .collect()
}

#[test]
fn every_exported_symbol_has_a_heading_or_an_index_row_in_the_abi_doc() {
    let header = read_artifact(HEADER_PATH).expect("the generated C header is committed");
    let doc = read_artifact(DOC_PATH).expect("the ABI reference is committed");

    let exported = exported_symbols(&header);
    assert_eq!(
        exported.len(),
        EXPECTED_EXPORTS,
        "the header now declares {} exported symbols, not {EXPECTED_EXPORTS}.\n\
         If a symbol really landed or left, bump EXPECTED_EXPORTS and update the counts \
         `docs/ffi-abi.md` states in prose. If it did not, the scanner is broken — a symbol \
         it silently drops is a symbol the doc is never asked for.",
        exported.len()
    );

    let missing = missing_symbols(&header, &doc);
    assert!(
        missing.is_empty(),
        "{} of {} symbols exported from {HEADER_PATH} are undocumented in {DOC_PATH}.\n\
         Add a row to the `## Symbol index` table (or a `###` section) for each:\n  {}",
        missing.len(),
        exported.len(),
        missing.join("\n  ")
    );
}

/// Every dotted `<domain>.<reason>` code named inside backticks on `text`.
fn backticked_codes(text: &str) -> BTreeSet<String> {
    text.split('`')
        .skip(1)
        .step_by(2)
        .filter(|token| {
            let mut halves = token.splitn(2, '.');
            let (Some(domain), Some(reason)) = (halves.next(), halves.next()) else {
                return false;
            };
            let ok = |s: &str| {
                !s.is_empty()
                    && s.bytes()
                        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
            };
            ok(domain) && ok(reason)
        })
        .map(ToOwned::to_owned)
        .collect()
}

/// Each exported symbol paired with the codes bulleted under its `# Errors` rustdoc.
///
/// Only bullet-START lines contribute: a continuation line may quote an argument name or
/// another identifier in backticks, and only the bullet itself names a code.
fn header_error_codes(header_src: &str) -> BTreeMap<String, BTreeSet<String>> {
    let mut map = BTreeMap::new();
    let mut in_errors = false;
    let mut codes = BTreeSet::new();
    for line in header_src.lines() {
        if is_comment_line(line) {
            let body = line.trim_start().trim_start_matches(['*', '/']).trim();
            if let Some(section) = body.strip_prefix("# ") {
                in_errors = section.trim() == "Errors";
            } else if in_errors {
                if let Some(bullet) = body.strip_prefix("- ") {
                    codes.extend(backticked_codes(bullet));
                }
            }
            continue;
        }
        for name in declared_symbols(line) {
            map.insert(name, std::mem::take(&mut codes));
            in_errors = false;
        }
    }
    map
}

/// Each symbol-index row paired with the codes its *Error codes* cell names.
///
/// Rows are the six-column `| Symbol | Args | Request table | Success payload | Error codes
/// | Story |` shape; anything shorter is some other table and is skipped.
fn index_error_codes(doc_src: &str) -> BTreeMap<String, BTreeSet<String>> {
    let mut map = BTreeMap::new();
    let mut in_fence = false;
    for line in doc_src.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("```") {
            in_fence = !in_fence;
            continue;
        }
        let Some(body) = (if in_fence { None } else { trimmed.strip_prefix('|') }) else {
            continue;
        };
        let cells: Vec<&str> = body.split('|').collect();
        if cells.len() < 6 {
            continue;
        }
        let names = backticked_names(cells[0]);
        let [name] = names.as_slice() else { continue };
        map.insert((*name).to_owned(), backticked_codes(cells[4]));
    }
    map
}

/// The `zanshin_*` names quoted in backticks in `text`.
fn backticked_names(text: &str) -> Vec<&str> {
    text.split('`')
        .skip(1)
        .step_by(2)
        .filter(|t| t.starts_with("zanshin_"))
        .collect()
}

#[test]
fn every_index_row_names_exactly_the_error_codes_its_rustdoc_bullets_do() {
    let header = read_artifact(HEADER_PATH).expect("the generated C header is committed");
    let doc = read_artifact(DOC_PATH).expect("the ABI reference is committed");

    let from_header = header_error_codes(&header);
    let from_index = index_error_codes(&doc);

    let mut problems = Vec::new();
    for (name, want) in &from_header {
        let Some(got) = from_index.get(name) else {
            problems.push(format!("{name}: no index row"));
            continue;
        };
        if want != got {
            let only_header: Vec<&str> = want.difference(got).map(String::as_str).collect();
            let only_doc: Vec<&str> = got.difference(want).map(String::as_str).collect();
            problems.push(format!(
                "{name}: missing from the row {only_header:?}, not in the rustdoc {only_doc:?}"
            ));
        }
    }
    assert!(
        problems.is_empty(),
        "the symbol index disagrees with {HEADER_PATH}'s `# Errors` bullets:\n  {}",
        problems.join("\n  ")
    );
}

#[test]
fn every_error_code_named_in_the_symbol_index_is_registered() {
    let doc = read_artifact(DOC_PATH).expect("the ABI reference is committed");
    let registry = read_artifact(REGISTRY_PATH).expect("the error-code registry is committed");

    let registered: BTreeSet<String> = registry
        .lines()
        .filter_map(|line| line.trim().strip_prefix('|'))
        .flat_map(|body| backticked_codes(body.split('|').next().unwrap_or("")))
        .collect();

    let named: BTreeSet<String> = index_error_codes(&doc).into_values().flatten().collect();
    let unregistered: Vec<&str> = named.difference(&registered).map(String::as_str).collect();

    assert!(
        !registered.is_empty(),
        "parsed no codes out of {REGISTRY_PATH} — the scanner is broken, not the doc"
    );
    assert!(
        unregistered.is_empty(),
        "the symbol index names codes that {REGISTRY_PATH} does not register: {unregistered:?}"
    );
}

#[test]
fn internal_panic_is_documented_once_and_named_in_no_index_row() {
    let doc = read_artifact(DOC_PATH).expect("the ABI reference is committed");
    let rows_naming_it: Vec<String> = index_error_codes(&doc)
        .into_iter()
        .filter(|(_, codes)| codes.contains("internal.panic"))
        .map(|(name, _)| name)
        .collect();
    assert!(
        rows_naming_it.is_empty(),
        "`internal.panic` is the universal backstop and belongs only in the prose, \
         but these rows name it: {rows_naming_it:?}"
    );
    assert!(
        doc.contains("`internal.panic`"),
        "the universal backstop must still be documented in the prose"
    );
}

#[test]
fn a_rustdoc_errors_block_is_read_per_symbol_and_stops_at_the_next_section() {
    let header = "\
/**
 * Do a thing.
 *
 * # Errors
 * - `ffi.null_pointer` / `ffi.utf8_error` — invalid `path` pointer.
 * - `jj.repo_not_found` — `path` is not a jj repo; the `context` names it.
 *
 * # Safety
 * The caller must not pass `jj.jj_lib_error` here — prose, not a bullet.
 */
ZanshinBuf *zanshin_repo_open(const char *path);

/**
 * # Errors
 * - `ffi.invalid_handle` — handle is 0.
 */
ZanshinBuf *zanshin_status(uint64_t handle);
";
    let map = header_error_codes(header);
    assert_eq!(
        map["zanshin_repo_open"],
        BTreeSet::from([
            "ffi.null_pointer".to_owned(),
            "ffi.utf8_error".to_owned(),
            "jj.repo_not_found".to_owned(),
        ]),
        "two codes on one bullet must both count; a `# Safety` mention must not"
    );
    assert_eq!(
        map["zanshin_status"],
        BTreeSet::from(["ffi.invalid_handle".to_owned()]),
        "each symbol's block must start empty, not inherit the previous symbol's codes"
    );
}

#[test]
fn an_index_row_whose_codes_disagree_with_the_rustdoc_is_detected() {
    let header = "\
/**
 * # Errors
 * - `ffi.invalid_handle` — handle is 0.
 * - `jj.jj_lib_error` — backend failure.
 */
ZanshinBuf *zanshin_status(uint64_t handle);
";
    let doc = "\
| Symbol | Args | Request table | Success payload | Error codes | Story |
|---|---|---|---|---|---|
| `zanshin_status` | `(uint64_t handle)` | — | `Status` | `ffi.invalid_handle` | 3.4b |
";
    let want = &header_error_codes(header)["zanshin_status"];
    let got = &index_error_codes(doc)["zanshin_status"];
    assert_ne!(want, got, "a dropped code must not compare equal");
    assert_eq!(
        want.difference(got).map(String::as_str).collect::<Vec<_>>(),
        ["jj.jj_lib_error"]
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
ZanshinBuf *zanshin_wrapped_example(uint64_t handle,
                                    const char *first,
                                    const char *second,
                                    bool flag,
                                    const char *third);
";
    let exported = exported_symbols(header);
    assert_eq!(exported, BTreeSet::from(["zanshin_wrapped_example".to_owned()]));
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
    assert_eq!(missing_symbols(header, doc), ["zanshin_undo"]);
}

#[test]
fn a_declaration_whose_return_type_also_starts_with_zanshin_is_still_found() {
    let header = "zanshin_result_t zanshin_future_verb(uint64_t handle);\n";
    assert_eq!(
        exported_symbols(header),
        BTreeSet::from(["zanshin_future_verb".to_owned()]),
        "bailing after the first `zanshin_` on the line would drop this symbol silently"
    );
}

#[test]
fn a_symbol_named_inside_a_fenced_code_block_is_not_counted_as_documentation() {
    let doc = "\
```c
| `zanshin_undo` | a sample row, not the index |
```
### `zanshin_status`
";
    let documented = documented_symbols(doc);
    assert!(documented.contains("zanshin_status"));
    assert!(
        !documented.contains("zanshin_undo"),
        "a code sample must not satisfy coverage"
    );
}

#[test]
fn a_heading_counts_as_documentation() {
    let documented = documented_symbols("### `zanshin_repo_detect`\n");
    assert_eq!(documented, BTreeSet::from(["zanshin_repo_detect".to_owned()]));
}

/// The header's include guard — the one `#define` it is allowed to carry.
const INCLUDE_GUARD: &str = "ZANSHIN_FFI_H";

/// Every macro name `#define`d in `header_src` other than the include guard.
///
/// The `FlatBuffers` internals (`<Table>_VT_*`, `ENUM_MIN_*`/`ENUM_MAX_*`) are the macros that
/// once leaked here from the flatc-generated module; `cbindgen:ignore` on that module keeps
/// them out, and this is what notices if a new generated module lacks the annotation.
fn stray_defines(header_src: &str) -> Vec<&str> {
    header_src
        .lines()
        .filter_map(|line| line.trim_start().strip_prefix("#define"))
        .filter_map(|rest| rest.split_whitespace().next())
        .filter(|name| *name != INCLUDE_GUARD)
        .collect()
}

#[test]
fn the_header_defines_no_macro_but_its_include_guard() {
    let header = read_artifact(HEADER_PATH).expect("the generated C header is committed");
    assert!(
        header.contains(&format!("#define {INCLUDE_GUARD}")),
        "the include guard is missing — the scanner would pass vacuously"
    );
    let stray = stray_defines(&header);
    assert!(
        stray.is_empty(),
        "{HEADER_PATH} defines {} macro(s) besides its include guard — either a generated \
         module without `/// cbindgen:ignore` leaks its FlatBuffers internals, or a new public \
         constant reached the C surface and needs an explicit decision:\n  {}",
        stray.len(),
        stray.join("\n  ")
    );
}

#[test]
fn a_flatbuffers_vtable_define_is_reported_as_stray() {
    let header = "\
#ifndef ZANSHIN_FFI_H
#define ZANSHIN_FFI_H
#define Envelope_VT_OK 4
#define ENUM_MAX_PAYLOAD 42
void zanshin_events_register(void (*callback)(ZanshinBuf *event));
";
    assert_eq!(stray_defines(header), ["Envelope_VT_OK", "ENUM_MAX_PAYLOAD"]);
}

#[test]
fn reading_a_missing_artifact_fails_with_the_path_in_the_message() {
    let err = read_artifact("docs/no-such-file.md").expect_err("the path does not exist");
    assert!(
        err.contains("docs/no-such-file.md"),
        "the failure must name the path it tried to read, got: {err}"
    );
}
