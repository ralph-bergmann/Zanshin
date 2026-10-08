// SPDX-License-Identifier: MIT

//! Aspect-by-aspect comparison of the two repos, and what each side's call returned.

use std::collections::BTreeMap;
use std::collections::BTreeSet;

use crate::driver::CliRun;

/// The aspects a scenario adds beyond the repo state: how the call ended, and the scenario's
/// own read-back (`Scenario::extra`).
pub const OUTCOME_ASPECTS: &[&str] = &["outcome", "warnings", "extra"];

/// How one side's call ended. Refusal and warnings are compared as facts, not texts: the CLI's
/// are terminal text, Zanshin's are typed (Story 9.47 compares only refused/warned).
pub struct Outcome {
    pub refused: bool,
    pub warnings: usize,
}

/// A `zanshin-jj` verb's result plus the warnings it left on the handle.
pub fn zanshin_outcome<T, E>(repo: &mut zanshin_jj::Repo, result: &Result<T, E>) -> Outcome {
    Outcome {
        refused: result.is_err(),
        warnings: repo.take_warnings().len(),
    }
}

/// `zanshin_jj::config_set`'s outcome (a free function: it carries its warnings itself).
pub fn config_outcome(outcome: &zanshin_jj::ConfigSetOutcome) -> Outcome {
    Outcome {
        refused: outcome.result.is_err(),
        warnings: outcome.warnings.len(),
    }
}

/// `Repo::init`'s outcome.
pub fn init_outcome(outcome: &zanshin_jj::CreationOutcome) -> Outcome {
    Outcome {
        refused: outcome.result.is_err(),
        warnings: outcome.warnings.len(),
    }
}

/// The CLI's outcome: a failed exit is a refusal; each `Warning: ` line on stderr is a warning.
pub fn cli_outcome(run: &CliRun) -> Outcome {
    Outcome {
        refused: !run.success,
        warnings: run.stderr.lines().filter(|line| line.starts_with("Warning: ")).count(),
    }
}

/// `outcome` (`ok` / `refused`) and `warnings` (a count) as aspects.
pub fn outcome_aspects(outcome: &Outcome) -> BTreeMap<&'static str, String> {
    BTreeMap::from([
        ("outcome", if outcome.refused { "refused" } else { "ok" }.to_owned()),
        ("warnings", outcome.warnings.to_string()),
    ])
}

/// One aspect where Zanshin's repo (A) and the CLI's repo (B) differ.
pub struct Divergence {
    pub aspect: String,
    pub zanshin: String,
    pub cli: String,
}

/// Every aspect whose value differs between `a` (Zanshin) and `b` (CLI), a missing key included.
pub fn compare(a: &BTreeMap<&'static str, String>, b: &BTreeMap<&'static str, String>) -> Vec<Divergence> {
    let keys: BTreeSet<&&str> = a.keys().chain(b.keys()).collect();
    keys.into_iter()
        .filter(|key| a.get(**key) != b.get(**key))
        .map(|key| Divergence {
            aspect: (*key).to_owned(),
            zanshin: a.get(*key).cloned().unwrap_or_default(),
            cli: b.get(*key).cloned().unwrap_or_default(),
        })
        .collect()
}
