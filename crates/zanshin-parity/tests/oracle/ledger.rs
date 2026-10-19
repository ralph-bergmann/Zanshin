// SPDX-License-Identifier: MIT

//! The divergences the oracle expects, each with its reason, where it is tracked, and the exact
//! values both sides produce today.
//!
//! A scenario fails on a divergence not listed here (UNEXPECTED), on a listed one that now
//! diverges with other values (CHANGED — a wrong fix, a new regression in the same aspect, or a
//! CLI change at a pin bump), and on a listed one that no longer happens (STALE — the gap was
//! closed or the CLI changed; remove the entry). Add an entry only with a reason and a reference
//! (a story, an ADR, a `deferred-work.md` entry); a new divergence after a pin bump is triaged
//! first: port it, ledger it, or open a story. The values are deterministic (labels, Git tree
//! hashes, counts), so copy them from the CHANGED / UNEXPECTED message.

use crate::compare::Divergence;

/// Fails unless `found` is exactly the ledgered divergences of `scenario`, with the ledgered
/// values: UNEXPECTED (unledgered), CHANGED (ledgered, other values), STALE (ledgered, gone).
pub fn assert_matches_ledger(scenario: &str, found: &[Divergence]) {
    let expected: Vec<&Expected> = LEDGER.iter().filter(|entry| entry.scenario == scenario).collect();
    let mut problems = Vec::new();
    for divergence in found {
        match expected.iter().find(|entry| entry.aspect == divergence.aspect) {
            None => problems.push(format!(
                "UNEXPECTED {}\n  zanshin: {}\n  cli    : {}",
                divergence.aspect, divergence.zanshin, divergence.cli
            )),
            Some(entry) if entry.zanshin != divergence.zanshin || entry.cli != divergence.cli => {
                problems.push(format!(
                    "CHANGED {} ({}; {})\n  ledger zanshin: {}\n  now    zanshin: {}\n  ledger cli    : {}\n  now    cli    : {}",
                    divergence.aspect,
                    entry.reason,
                    entry.reference,
                    entry.zanshin,
                    divergence.zanshin,
                    entry.cli,
                    divergence.cli
                ));
            }
            Some(_) => {}
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

/// One expected divergence of one scenario, with the values each side produces.
pub struct Expected {
    pub scenario: &'static str,
    pub aspect: &'static str,
    pub reason: &'static str,
    pub reference: &'static str,
    /// The aspect's value in Zanshin's repo (A).
    pub zanshin: &'static str,
    /// The aspect's value in the CLI's repo (B).
    pub cli: &'static str,
}

/// Every expected divergence (CLI at the pinned tag, v0.46.0).
pub const LEDGER: &[Expected] = &[
    Expected {
        scenario: "describe_gui_text",
        aspect: "descriptions",
        reason: "Repo::describe stores the caller's text verbatim; the CLI's -m ends it with a newline",
        reference: "Story 10.15 design question (c)",
        zanshin: r#"A="A\n"  B="B\n"  C described="C described""#,
        cli: r#"A="A\n"  B="B\n"  C described="C described\n""#,
    },
    Expected {
        scenario: "describe_no_change",
        aspect: "ops written",
        reason: "mutate::finish_verb has no has_changes() gate, so an unchanged describe writes an operation",
        reference: "Story 9.40",
        zanshin: "1",
        cli: "0",
    },
    Expected {
        scenario: "describe_no_change",
        aspect: "op descriptions",
        reason: "the operation the missing has_changes() gate writes",
        reference: "Story 9.40",
        zanshin: "describe commit commit:C",
        cli: "<none>",
    },
    Expected {
        scenario: "describe_no_change",
        aspect: "op attributes (except args)",
        reason: "the operation the missing has_changes() gate writes",
        reference: "Story 9.40",
        zanshin: "{}",
        cli: "<none>",
    },
    Expected {
        scenario: "describe_no_change",
        aspect: "op is_snapshot/workspace_name",
        reason: "the operation the missing has_changes() gate writes",
        reference: "Story 9.40",
        zanshin: "snapshot=false workspace=default",
        cli: "<none>",
    },
    Expected {
        scenario: "describe_commit_trailers",
        aspect: "descriptions",
        reason: "templates.commit_trailers is never applied",
        reference: "deferred-work.md \"Surfaced 2026-10-08 while analysing 'fork jj instead of re-porting the CLI'\"",
        zanshin: r#"A="A\n"  B="B\n"  T="T\n""#,
        cli: r#"A="A\n"  B="B\n"  T="T\n\nSigned-off-by: Zanshin <zanshin@localhost>\n""#,
    },
    Expected {
        scenario: "commit_trailers",
        aspect: "descriptions",
        reason: "templates.commit_trailers is never applied (commit.rs:144-153 @ v0.46.0 adds them to a non-empty -m)",
        reference: "deferred-work.md \"Surfaced 2026-10-08 while analysing 'fork jj instead of re-porting the CLI'\"; Story 9.49",
        zanshin: r#"A="A\n"  B="B\n"  T="T\n"  (empty)="""#,
        cli: r#"A="A\n"  B="B\n"  T="T\n\nSigned-off-by: Zanshin <zanshin@localhost>\n"  (empty)="""#,
    },
    Expected {
        scenario: "new_conflicting_merge",
        aspect: "warnings",
        reason: "the CLI's \"There are unresolved conflicts\" status line has no Zanshin warning code",
        reference: "docs/rust-error-codes.md",
        zanshin: "0",
        cli: "1",
    },
];
