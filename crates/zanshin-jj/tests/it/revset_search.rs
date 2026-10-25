// SPDX-License-Identifier: MIT

//! Fixture tests for `Repo::revset_counts` / `Repo::find_changes` (Story 9.25): counts that match
//! the topology, the cap, per-entry errors, the op-pinned write-nothing contract, find's order and
//! truncation, prefix resolution, and the structured revset error detail.

use std::ops::ControlFlow;
use std::path::Path;

use test_helpers::extract_fixture;
use zanshin_jj::{
    OperationId, Repo, RevsetCount, RevsetError, RevsetErrorKind, RevsetSearchError, RevsetSpan, WarningKind,
    DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET,
};

const CAP: u64 = 10_000;

fn medium() -> (test_helpers::FixtureHandle, Repo) {
    test_helpers::pin_test_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let repo = Repo::open(&fx.path).unwrap();
    (fx, repo)
}

/// The topology of `revset` with the CLI's short prefixes; its precondition and warnings are
/// taken off the handle.
fn topology(repo: &mut Repo, revset: &str, short_prefixes: &str) -> zanshin_jj::GraphTopology {
    let topology = repo
        .graph_topology(revset, DEFAULT_GRAPH_PRIORITIZE, short_prefixes, &[], false)
        .unwrap();
    _ = repo.take_precondition();
    _ = repo.take_warnings();
    topology
}

fn counts(repo: &mut Repo, op: &OperationId, expressions: &[&str], cap: u64) -> Vec<Result<RevsetCount, RevsetError>> {
    let expressions: Vec<String> = expressions.iter().map(|&e| e.to_owned()).collect();
    repo.revset_counts(op, &expressions, cap).unwrap().counts
}

/// The detail of a parse or resolution error.
fn detail(e: &RevsetError) -> &zanshin_jj::RevsetErrorDetail {
    let (RevsetError::ParseError { detail, .. } | RevsetError::ResolutionError { detail, .. }) = e else {
        panic!("not a revset error: {e:?}");
    };
    detail
}

/// The file names in `.jj/repo/<dir>`, sorted.
fn listing(root: &Path, dir: &[&str]) -> Vec<String> {
    let mut path = root.join(".jj").join("repo");
    for part in dir {
        path = path.join(part);
    }
    let mut names: Vec<String> = std::fs::read_dir(path)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

// ── revset_counts ──────────────────────────────────────────────────────────────

#[test]
fn every_count_matches_the_topology_at_that_operation() {
    let (fx, _) = medium();
    // `mine()` matches the pinned `user.email`, which no fixture commit has: add one that does.
    _ = test_helpers::add_commit_off_root(&fx.path, "mine");
    let mut repo = Repo::open(&fx.path).unwrap();
    for expr in [
        r#"author(exact:"Fixture")"#,
        r#"author(substring-i:"fixture")"#,
        "mine()",
        r#"description(substring-i:"brancha")"#,
        r#"subject(glob:"Linear-1*")"#,
        r#"files(cwd:"commit-5.txt")"#,
        r#"files(file:"commit-7.txt")"#,
        r#"files(glob:"commit-1?.txt")"#,
    ] {
        let topology = topology(&mut repo, expr, DEFAULT_LOG_REVSET);
        let counts = counts(&mut repo, &topology.operation_id, &[expr], CAP);
        assert!(!topology.nodes.is_empty(), "{expr} must match something");
        assert_eq!(
            counts[0].as_ref().unwrap(),
            &RevsetCount {
                n: u64::try_from(topology.nodes.len()).unwrap(),
                capped: false
            },
            "{expr}"
        );
    }
}

#[test]
fn a_cap_stops_the_count_and_a_zero_cap_only_parses_and_resolves() {
    let (_fx, mut repo) = medium();
    let op = topology(&mut repo, "@", DEFAULT_LOG_REVSET).operation_id;

    assert_eq!(
        counts(&mut repo, &op, &["all()"], 5)[0].as_ref().unwrap(),
        &RevsetCount { n: 5, capped: true }
    );
    let zero = counts(&mut repo, &op, &["all()", "bogus(", "nonexistent_bookmark"], 0);
    assert_eq!(zero[0].as_ref().unwrap(), &RevsetCount { n: 0, capped: false });
    assert!(matches!(zero[1], Err(RevsetError::ParseError { .. })), "{:?}", zero[1]);
    assert!(
        matches!(zero[2], Err(RevsetError::ResolutionError { .. })),
        "{:?}",
        zero[2]
    );
}

#[test]
fn a_failing_entry_fails_only_itself() {
    let (_fx, mut repo) = medium();
    let all = topology(&mut repo, "all()", DEFAULT_LOG_REVSET);

    let counts = counts(
        &mut repo,
        &all.operation_id,
        &["all()", "nonexistent_bookmark", r#"description(regex:"(")"#],
        CAP,
    );

    assert_eq!(
        counts[0].as_ref().unwrap(),
        &RevsetCount {
            n: u64::try_from(all.nodes.len()).unwrap(),
            capped: false
        }
    );
    let resolution = counts[1].as_ref().unwrap_err();
    assert!(
        matches!(resolution, RevsetError::ResolutionError { .. }),
        "{resolution:?}"
    );
    assert_eq!(detail(resolution).kind, RevsetErrorKind::NoSuchRevision);
    assert_eq!(detail(resolution).symbol.as_deref(), Some("nonexistent_bookmark"));
    let parse = counts[2].as_ref().unwrap_err();
    assert!(matches!(parse, RevsetError::ParseError { .. }), "{parse:?}");
    assert_eq!(detail(parse).kind, RevsetErrorKind::Expression);
}

#[test]
fn counts_resolve_with_the_effective_short_prefixes_context() {
    // A one-commit `revsets.short-prefixes` disambiguates a one-char prefix of that commit's
    // change id, as the CLI does: within the context it is unique, in the full index ambiguous.
    let (fx, mut repo) = medium();
    let op = topology(&mut repo, "@", DEFAULT_LOG_REVSET).operation_id;
    let tip = repo.find_changes(&op, "tip", 1, "").unwrap().entries.remove(0);
    let prefix = &tip.change_id.0[..1];
    let ambiguous = counts(&mut repo, &op, &[prefix], CAP);
    assert!(
        matches!(&ambiguous[0], Err(e) if detail(e).kind == RevsetErrorKind::AmbiguousChangeIdPrefix),
        "{ambiguous:?}"
    );

    std::fs::write(
        fx.path.join(".jj").join("repo").join("config.toml"),
        "[revsets]\nshort-prefixes = \"tip\"\n",
    )
    .unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    assert_eq!(
        counts(&mut repo, &op, &[prefix], CAP)[0].as_ref().unwrap(),
        &RevsetCount { n: 1, capped: false }
    );
}

#[test]
fn counts_report_parse_diagnostics_as_warnings_in_expression_order() {
    let (_fx, mut repo) = medium();
    let op = topology(&mut repo, "@", DEFAULT_LOG_REVSET).operation_id;

    let answer = repo
        .revset_counts(
            &op,
            &[
                r#"diff_contains("a")"#.to_owned(),
                "all()".to_owned(),
                r#"diff_contains("b")"#.to_owned(),
            ],
            0,
        )
        .unwrap();

    let kinds: Vec<WarningKind> = answer.warnings.iter().map(|w| w.kind).collect();
    assert_eq!(kinds, [WarningKind::RevsetDiagnostic, WarningKind::RevsetDiagnostic]);
    assert!(answer.warnings[0].message.starts_with("In revset expression\n"));
    assert!(answer.warnings[0].message.contains(r#"diff_contains("a")"#));
    assert!(answer.warnings[1].message.contains(r#"diff_contains("b")"#));
}

/// The call-level fault keeps the warnings collected before it — the alias load's here — as the
/// CLI prints them before it fails (Story 9.25 closing run).
#[test]
fn a_bad_effective_short_prefixes_is_a_call_level_config_error() {
    let (fx, mut repo) = medium();
    let op = topology(&mut repo, "@", DEFAULT_LOG_REVSET).operation_id;
    std::fs::write(
        fx.path.join(".jj").join("repo").join("config.toml"),
        "[revset-aliases]\n'bad(' = 'x'\n[revsets]\nshort-prefixes = \"bogus(\"\n",
    )
    .unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();

    let err = repo.revset_counts(&op, &["all()".to_owned()], CAP).unwrap_err();

    assert!(
        matches!(&err.value, RevsetSearchError::Config(e) if e.to_string().contains("Invalid `revsets.short-prefixes`")),
        "{err:?}"
    );
    let kinds: Vec<WarningKind> = err.warnings.iter().map(|w| w.kind).collect();
    assert_eq!(kinds, [WarningKind::ConfigAliasInvalid], "{err:?}");
}

// ── The pinned reads write nothing ────────────────────────────────────────────

#[test]
fn both_searches_on_a_dirty_working_copy_write_nothing() {
    let (fx, mut repo) = medium();
    let all = topology(&mut repo, "all()", DEFAULT_LOG_REVSET);
    let op = all.operation_id;
    std::fs::write(fx.path.join("edited.txt"), "not yet snapshotted").unwrap();
    let heads = listing(&fx.path, &["op_heads", "heads"]);
    let operations = listing(&fx.path, &["op_store", "operations"]);

    let counted = repo.revset_counts(&op, &["all()".to_owned()], CAP).unwrap();
    let found = repo.find_changes(&op, "@", 10, DEFAULT_LOG_REVSET).unwrap();

    assert_eq!(
        counted.counts[0].as_ref().unwrap().n,
        u64::try_from(all.nodes.len()).unwrap()
    );
    assert_eq!(found.entries.len(), 1);
    assert_eq!(listing(&fx.path, &["op_heads", "heads"]), heads, "no op head written");
    assert_eq!(
        listing(&fx.path, &["op_store", "operations"]),
        operations,
        "no operation written"
    );
    assert!(repo.take_precondition().is_none(), "no precondition ran");
    assert!(repo.take_warnings().is_empty(), "nothing left on the handle");

    // The next topology call still snapshots.
    repo.graph_topology("all()", DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET, &[], false)
        .unwrap();
    assert!(repo.take_precondition().is_some_and(|p| p.was_snapshot_taken));
}

#[test]
fn an_unknown_or_malformed_operation_is_a_call_level_fault() {
    let (_fx, mut repo) = medium();
    // All zeros is the root operation; all `f`s is in no store.
    let unknown = OperationId("f".repeat(128));

    let err = repo.revset_counts(&unknown, &[], CAP).unwrap_err();
    assert!(err.warnings.is_empty(), "nothing ran before the load");
    let err = err.value;
    assert!(
        matches!(&err, RevsetSearchError::OperationNotFound(id) if *id == unknown.0),
        "{err:?}"
    );
    assert_eq!(err.to_string(), format!(r#"No operation ID matching "{}""#, unknown.0));
    let err = repo.find_changes(&unknown, "all()", 1, "").unwrap_err().value;
    assert!(matches!(err, RevsetSearchError::OperationNotFound(_)), "{err:?}");

    let err = repo
        .revset_counts(&OperationId("xyz".to_owned()), &[], CAP)
        .unwrap_err()
        .value;
    assert!(
        matches!(&err, RevsetSearchError::InvalidInput(text) if text == r#"Operation ID "xyz" is not a valid hexadecimal prefix"#),
        "{err:?}"
    );
    let err = repo
        .find_changes(&OperationId("abc".to_owned()), "all()", 1, "")
        .unwrap_err()
        .value;
    assert!(matches!(err, RevsetSearchError::InvalidInput(_)), "{err:?}");
}

// ── find_changes ───────────────────────────────────────────────────────────────

#[test]
fn find_keeps_the_iteration_order_truncates_and_matches_the_topology() {
    let (_fx, mut repo) = medium();
    let topology = topology(&mut repo, "all()", DEFAULT_LOG_REVSET);
    let mut order = Vec::new();
    let flow = repo
        .eval_revset("all()", |change| {
            order.push(change.commit_id);
            ControlFlow::Continue(())
        })
        .unwrap();
    assert_eq!(flow, ControlFlow::Continue(()));

    let found = repo
        .find_changes(&topology.operation_id, "all()", 3, DEFAULT_LOG_REVSET)
        .unwrap();

    assert!(found.truncated);
    assert!(found.warnings.is_empty());
    let ids: Vec<_> = found.entries.iter().map(|e| e.commit_id.clone()).collect();
    assert_eq!(ids, order[..3], "jj log --no-graph's order");
    for entry in &found.entries {
        let node = topology.nodes.iter().find(|n| n.commit_id == entry.commit_id).unwrap();
        assert_eq!(entry.change_id.0, node.meta.change_id);
        assert_eq!(entry.commit_prefix_len, node.meta.commit_id_prefix_len);
        assert_eq!(entry.change_prefix_len, node.meta.change_id_prefix_len);
    }

    let whole = repo
        .find_changes(&topology.operation_id, "all()", CAP, DEFAULT_LOG_REVSET)
        .unwrap();
    assert!(!whole.truncated);
    assert_eq!(whole.entries.len(), topology.nodes.len());
}

#[test]
fn find_without_short_prefixes_uses_the_full_index() {
    let (_fx, mut repo) = medium();
    let topology = topology(&mut repo, "all()", "");

    let found = repo.find_changes(&topology.operation_id, "tip", 1, "").unwrap();

    let node = topology
        .nodes
        .iter()
        .find(|n| n.commit_id == found.entries[0].commit_id)
        .unwrap();
    assert_eq!(found.entries[0].change_prefix_len, node.meta.change_id_prefix_len);
    assert_eq!(found.entries[0].commit_prefix_len, node.meta.commit_id_prefix_len);
}

/// `find_changes`' own `short_prefixes` disambiguates its symbols: a one-char change-id prefix
/// of `tip`, ambiguous in the full index, resolves to exactly `tip` within `short_prefixes = tip`.
#[test]
fn find_resolves_a_prefix_within_its_short_prefixes() {
    let (_fx, mut repo) = medium();
    let op = topology(&mut repo, "@", DEFAULT_LOG_REVSET).operation_id;
    let tip = repo.find_changes(&op, "tip", 1, "").unwrap().entries.remove(0);
    let prefix = &tip.change_id.0[..1];

    let err = repo.find_changes(&op, prefix, 10, "").unwrap_err().value;
    assert!(
        matches!(&err, RevsetSearchError::Revset(e) if detail(e).kind == RevsetErrorKind::AmbiguousChangeIdPrefix),
        "{err:?}"
    );
    let found = repo.find_changes(&op, prefix, 10, "tip").unwrap();
    assert_eq!(found.entries.len(), 1);
    assert_eq!(found.entries[0].commit_id, tip.commit_id);
    assert_eq!(found.entries[0].change_prefix_len, 1, "unique within the context");
}

/// The topology's error in `prioritize` or `short_prefixes` keeps kind and hints but no span —
/// only `revset` is the text a span points into.
#[test]
fn a_topology_error_outside_the_revset_has_no_span() {
    let (_fx, mut repo) = medium();
    for (prioritize, short) in [("bogus(", DEFAULT_LOG_REVSET), (DEFAULT_GRAPH_PRIORITIZE, "bogus(")] {
        let err = repo.graph_topology("all()", prioritize, short, &[], false).unwrap_err();
        assert!(matches!(err, RevsetError::ParseError { .. }), "{err:?}");
        assert_eq!(detail(&err).kind, RevsetErrorKind::SyntaxError);
        assert!(detail(&err).span.is_none(), "{prioritize} / {short}");
        assert!(!detail(&err).hints.is_empty());
    }
    let err = repo
        .graph_topology(
            "all()",
            DEFAULT_GRAPH_PRIORITIZE,
            DEFAULT_LOG_REVSET,
            &["bogus(".to_owned()],
            false,
        )
        .unwrap_err();
    assert!(detail(&err).span.is_none(), "an anchor");
    let err = repo
        .graph_topology("bogus(", DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET, &[], false)
        .unwrap_err();
    assert!(detail(&err).span.is_some(), "the revset itself");
}

#[test]
fn an_ambiguous_prefix_is_a_resolution_error_and_an_unmatched_one_finds_nothing() {
    let (_fx, mut repo) = medium();
    let op = topology(&mut repo, "@", DEFAULT_LOG_REVSET).operation_id;

    let err = repo.find_changes(&op, "change_id(k)", 10, "").unwrap_err().value;
    let RevsetSearchError::Revset(e @ RevsetError::ResolutionError { reason, .. }) = &err else {
        panic!("{err:?}");
    };
    assert_eq!(reason, "Change ID prefix `k` is ambiguous");
    assert_eq!(detail(e).kind, RevsetErrorKind::AmbiguousChangeIdPrefix);
    assert_eq!(detail(e).symbol.as_deref(), Some("k"));
    assert!(detail(e).span.is_none());

    let found = repo
        .find_changes(&op, "commit_id(0123456789abcdef0123456789abcdef)", 10, "")
        .unwrap();
    assert!(found.entries.is_empty());
    assert!(!found.truncated);
}

#[test]
fn find_reports_a_bad_short_prefixes_or_expression_as_its_revset_error() {
    let (_fx, mut repo) = medium();
    let op = topology(&mut repo, "@", DEFAULT_LOG_REVSET).operation_id;

    // Only the expression's own error carries a span: one in `short_prefixes` would point into
    // the other text.
    for (expression, short, has_span) in [("all()", "bogus(", false), ("bogus(", "", true)] {
        let err = repo.find_changes(&op, expression, 1, short).unwrap_err().value;
        let RevsetSearchError::Revset(e @ RevsetError::ParseError { .. }) = &err else {
            panic!("{err:?}");
        };
        assert_eq!(detail(e).span.is_some(), has_span, "{expression} / {short}");
        assert_eq!(detail(e).kind, RevsetErrorKind::SyntaxError);
    }
    let found = repo.find_changes(&op, "all()", 1, r#"diff_contains("x")"#).unwrap();
    assert_eq!(found.warnings.len(), 1);
    assert!(
        found.warnings[0].message.starts_with("In `revsets.short-prefixes`\n"),
        "{}",
        found.warnings[0].message
    );

    // A bad expression after a warning keeps it on the error (Story 9.25 closing run).
    let err = repo
        .find_changes(&op, "bogus(", 1, r#"diff_contains("x")"#)
        .unwrap_err();
    assert!(
        matches!(err.value, RevsetSearchError::Revset(RevsetError::ParseError { .. })),
        "{err:?}"
    );
    assert_eq!(err.warnings, found.warnings);
}

// ── Structured revset errors ───────────────────────────────────────────────────

/// The parse error of `expr` from find, counts and the topology — the three must agree.
fn parse_detail(repo: &mut Repo, op: &OperationId, expr: &str) -> zanshin_jj::RevsetErrorDetail {
    let RevsetSearchError::Revset(found) = repo.find_changes(op, expr, 1, "").unwrap_err().value else {
        panic!("find: not a revset error");
    };
    let counted = repo
        .revset_counts(op, &[expr.to_owned()], CAP)
        .unwrap()
        .counts
        .remove(0)
        .unwrap_err();
    let shown = repo
        .graph_topology(expr, DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET, &[], false)
        .unwrap_err();
    assert_eq!(detail(&found), detail(&counted), "{expr}");
    assert_eq!(detail(&found), detail(&shown), "{expr}");
    detail(&found).clone()
}

#[test]
fn parse_errors_carry_kind_span_symbol_candidates_and_hints() {
    let (_fx, mut repo) = medium();
    let op = topology(&mut repo, "@", DEFAULT_LOG_REVSET).operation_id;

    let unknown = parse_detail(&mut repo, &op, "fooo()");
    assert_eq!(unknown.kind, RevsetErrorKind::NoSuchFunction);
    assert_eq!(unknown.symbol.as_deref(), Some("fooo"));
    assert_eq!(
        unknown.span,
        Some(RevsetSpan {
            offset: 0,
            length: Some(4)
        })
    );
    assert!(unknown.candidates.is_empty(), "nothing is similar to `fooo`");
    assert!(unknown.hints.is_empty(), "the CLI's hint needs candidates");

    let similar = parse_detail(&mut repo, &op, "descripton(x)");
    assert_eq!(similar.kind, RevsetErrorKind::NoSuchFunction);
    assert!(similar.candidates.iter().any(|c| c == "description"), "{similar:?}");
    let quoted: Vec<String> = similar.candidates.iter().map(|c| format!("`{c}`")).collect();
    assert_eq!(similar.hints, [format!("Did you mean {}?", quoted.join(", "))]);

    let unclosed = parse_detail(&mut repo, &op, r#"description("x"#);
    assert_eq!(unclosed.kind, RevsetErrorKind::SyntaxError);
    assert_eq!(
        unclosed.span,
        Some(RevsetSpan {
            offset: 14,
            length: Some(0)
        }),
        "a position, where jj-lib reports it"
    );
    assert_eq!(unclosed.hints.len(), 1);
    assert!(unclosed.hints[0].contains("revsets syntax"), "{:?}", unclosed.hints);

    let regex = parse_detail(&mut repo, &op, r#"description(regex:"(")"#);
    assert_eq!(regex.kind, RevsetErrorKind::Expression);
    assert_eq!(
        regex.span,
        Some(RevsetSpan {
            offset: 12,
            length: Some(9)
        }),
        "the pattern argument"
    );
    assert!(regex.hints.is_empty(), "the CLI gives a bad regex no hint");
}

#[test]
fn an_error_inside_an_alias_reports_the_call_site_and_the_bottom_errors_hint() {
    let (fx, mut repo) = medium();
    std::fs::write(
        fx.path.join(".jj").join("repo").join("config.toml"),
        "[revset-aliases]\n'broken()' = 'descripton(x)'\n",
    )
    .unwrap();
    let mut repo2 = Repo::open(&fx.path).unwrap();
    let op = topology(&mut repo, "@", DEFAULT_LOG_REVSET).operation_id;

    let alias = parse_detail(&mut repo2, &op, "all() & broken()");

    assert_eq!(alias.kind, RevsetErrorKind::InAliasExpansion);
    assert_eq!(alias.symbol.as_deref(), Some("broken()"));
    assert_eq!(
        alias.span,
        Some(RevsetSpan {
            offset: 8,
            length: Some(8)
        })
    );
    assert!(
        alias.hints.len() == 1 && alias.hints[0].starts_with("Did you mean "),
        "{:?}",
        alias.hints
    );
}
