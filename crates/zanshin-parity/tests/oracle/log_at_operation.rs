// SPDX-License-Identifier: MIT

//! `jj log`'s graph order for `at_operation()` revsets against the pinned CLI (Story 9.42):
//! Zanshin's `walk_graph` and the pinned `jj log` run on the SAME repo (a log writes no
//! operation), and Zanshin's rows (commit id, `hidden`, `empty`) must equal the CLI's, in its
//! order — `graph_topology`'s commit-id order too. The CLI's text is read only for that
//! comparison.

use std::ops::ControlFlow;
use std::path::Path;

use zanshin_jj::{Repo, DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET};

use crate::driver::{fresh_repo, jj, Step};
use crate::scenarios::BASE;

/// jj's `test_log_graph_prioritize_hidden_commits` setup: `@` described "1", then "2".
const DESCRIBED_TWICE: &[Step] = &[Step::Jj(&["describe", "-m1"]), Step::Jj(&["describe", "-m2"])];

/// One row: commit id, `hidden`, `empty` (`None`: the CLI's inline template error).
type Row = (String, bool, Option<bool>);

/// The rows of the pinned `jj log -r <revset>` graph, in row order, with
/// `revsets.log-graph-prioritize = <prioritize>`. An `empty` that renders as a template error
/// (`<Error: …>`, a merge outside the head's index) is `None`, as Zanshin reports it.
#[track_caller]
fn cli_rows(root: &Path, revset: &str, prioritize: &str) -> Vec<Row> {
    let config = format!("--config=revsets.log-graph-prioritize={prioritize}");
    let run = jj(
        root,
        &[
            "log",
            "--ignore-working-copy",
            &config,
            "-r",
            revset,
            "-T",
            r#"commit_id ++ " " ++ hidden ++ " " ++ empty ++ "\n""#,
        ],
    )
    .ok();
    run.stdout
        .lines()
        .filter_map(|line| {
            let tokens: Vec<&str> = line.split_whitespace().collect();
            let at = tokens
                .iter()
                .position(|token| token.len() == 40 && token.bytes().all(|b| b.is_ascii_hexdigit()))?;
            let empty = match tokens.get(at + 2).copied() {
                Some("true") => Some(true),
                Some("false") => Some(false),
                other => {
                    assert!(other.is_some_and(|t| t.starts_with("<Error")), "{line}");
                    None
                }
            };
            Some((tokens[at].to_owned(), tokens.get(at + 1) == Some(&"true"), empty))
        })
        .collect()
}

/// Zanshin's `walk_graph` rows for the same pass-throughs, after asserting that
/// `graph_topology` yields the same commit-id order.
fn zanshin_rows(root: &Path, revset: &str, prioritize: &str) -> Vec<Row> {
    let mut repo = Repo::open(root).expect("open");
    let mut rows = Vec::new();
    let flow = repo
        .walk_graph(revset, prioritize, DEFAULT_LOG_REVSET, |node| {
            rows.push((node.id.0, node.meta.hidden, node.meta.empty));
            ControlFlow::Continue(())
        })
        .expect("walk_graph");
    assert_eq!(flow, ControlFlow::Continue(()));
    let topology = repo
        .graph_topology(revset, prioritize, DEFAULT_LOG_REVSET, &[], false)
        .expect("graph_topology");
    let topology_ids: Vec<&str> = topology.nodes.iter().map(|n| n.commit_id.0.as_str()).collect();
    let walk_ids: Vec<&str> = rows.iter().map(|row| row.0.as_str()).collect();
    assert_eq!(topology_ids, walk_ids, "graph_topology order = walk_graph order");
    rows
}

/// Zanshin's rows equal the CLI's; returns the CLI's commit ids.
#[track_caller]
fn assert_same_order(root: &Path, revset: &str, prioritize: &str) -> Vec<String> {
    let cli = cli_rows(root, revset, prioritize);
    assert_eq!(zanshin_rows(root, revset, prioritize), cli, "{revset} / {prioritize}");
    cli.into_iter().map(|row| row.0).collect()
}

/// An operation no head descends from (written after the CLI steps, never published): its
/// commits are in no head index, and `jj log` evaluates `at_operation()` of it anyway.
#[test]
fn sibling_operation_revset_rows_match_the_cli() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[BASE]);
    let (op, sibling) = test_helpers::add_unpublished_op(&root, "sibling");

    let rows = assert_same_order(&root, &format!("at_operation({op}, all())"), DEFAULT_GRAPH_PRIORITIZE);
    assert!(sibling.iter().all(|id| rows.contains(id)), "{rows:?}");
}

/// `prioritize` selects a sibling-op commit (its left root child — a hex id resolves only inside
/// that operation's scope, so `at_operation()` names it there).
#[test]
fn prioritize_of_a_sibling_operation_commit_matches_the_cli() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[BASE]);
    let (op, sibling) = test_helpers::add_unpublished_op(&root, "sibling");

    let rows = assert_same_order(
        &root,
        &format!("at_operation({op}, all())"),
        &format!("at_operation({op}, {})", sibling[0]),
    );
    assert!(rows.contains(&sibling[0]), "{rows:?}");
}

/// Case 1: the hidden "1" is in the query, so it is prioritised.
#[test]
fn prioritize_of_a_hidden_commit_in_the_query_matches_the_cli() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[DESCRIBED_TWICE]);
    let rows = assert_same_order(&root, "::(@|at_operation(@-, @))", "at_operation(@-, @)");
    assert_eq!(rows.len(), 3, "1, 2 and root: {rows:?}");
}

/// Case 2: the hidden "1" the prioritize text names is not in the query (`all()`), so it is
/// neither prioritised nor emitted.
#[test]
fn prioritize_outside_the_query_matches_the_cli() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[DESCRIBED_TWICE]);
    let rows = assert_same_order(&root, "all()", "at_operation(@-, @ | subject(1))");
    assert_eq!(rows.len(), 2, "2 and root: {rows:?}");
}

/// Case 3: the query is `all()` at the previous operation, so "2" is not in it.
#[test]
fn query_at_an_older_operation_matches_the_cli() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[DESCRIBED_TWICE]);
    let rows = assert_same_order(&root, "at_operation(@-, all())", "@ | subject(2)");
    assert_eq!(rows.len(), 2, "1 and root: {rows:?}");
}
