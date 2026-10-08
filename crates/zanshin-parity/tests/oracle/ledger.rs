// SPDX-License-Identifier: MIT

//! The divergences the oracle expects, each with its reason and where it is tracked.
//!
//! A scenario fails on a divergence not listed here AND on a listed one that no longer happens
//! (stale — the gap was closed or the CLI changed; remove the entry). Add an entry only with a
//! reason and a reference (a story, an ADR, a `deferred-work.md` entry); a new divergence after
//! a pin bump is triaged first: port it, ledger it, or open a story.

use crate::compare::Divergence;

/// Fails unless `found` is exactly the ledgered divergences of `scenario`: every unledgered one
/// is UNEXPECTED (with both values), every ledgered one that did not happen is STALE.
pub fn assert_matches_ledger(scenario: &str, found: &[Divergence]) {
    let expected: Vec<&Expected> = LEDGER.iter().filter(|entry| entry.scenario == scenario).collect();
    let mut problems = Vec::new();
    for divergence in found {
        if !expected.iter().any(|entry| entry.aspect == divergence.aspect) {
            problems.push(format!(
                "UNEXPECTED {}\n  zanshin: {}\n  cli    : {}",
                divergence.aspect, divergence.zanshin, divergence.cli
            ));
        }
    }
    for entry in &expected {
        if !found.iter().any(|divergence| divergence.aspect == entry.aspect) {
            problems.push(format!(
                "STALE {} ({}; {}): no longer diverges — remove it from LEDGER",
                entry.aspect, entry.reason, entry.reference
            ));
        }
    }
    assert!(
        problems.is_empty(),
        "parity oracle, scenario {scenario}:\n{}",
        problems.join("\n")
    );
}

/// One expected divergence of one scenario.
pub struct Expected {
    pub scenario: &'static str,
    pub aspect: &'static str,
    pub reason: &'static str,
    pub reference: &'static str,
}

/// Every expected divergence (CLI at the pinned tag, v0.46.0).
pub const LEDGER: &[Expected] = &[
    Expected {
        scenario: "describe_gui_text",
        aspect: "descriptions",
        reason: "Repo::describe stores the caller's text verbatim; the CLI's -m ends it with a newline",
        reference: "Story 10.15 design question (c)",
    },
    Expected {
        scenario: "describe_no_change",
        aspect: "ops written",
        reason: "mutate::finish_verb has no has_changes() gate, so an unchanged describe writes an operation",
        reference: "Story 9.40",
    },
    Expected {
        scenario: "describe_no_change",
        aspect: "op descriptions",
        reason: "the operation the missing has_changes() gate writes",
        reference: "Story 9.40",
    },
    Expected {
        scenario: "describe_no_change",
        aspect: "op attributes (except args)",
        reason: "the operation the missing has_changes() gate writes",
        reference: "Story 9.40",
    },
    Expected {
        scenario: "describe_no_change",
        aspect: "op is_snapshot/workspace_name",
        reason: "the operation the missing has_changes() gate writes",
        reference: "Story 9.40",
    },
    Expected {
        scenario: "describe_commit_trailers",
        aspect: "descriptions",
        reason: "templates.commit_trailers is never applied",
        reference: "deferred-work.md \"Surfaced 2026-10-08 while analysing 'fork jj instead of re-porting the CLI'\"",
    },
    Expected {
        scenario: "new_conflicting_merge",
        aspect: "warnings",
        reason: "the CLI's \"There are unresolved conflicts\" status line has no Zanshin warning code",
        reference: "docs/rust-error-codes.md",
    },
    Expected {
        scenario: "init_colocated",
        aspect: "colocated (.git dir)",
        reason: "Repo::init(Git) never colocates; `jj git init` does by default",
        reference: "Story 9.20",
    },
];
