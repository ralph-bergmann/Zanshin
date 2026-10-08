// SPDX-License-Identifier: MIT

//! Aspect-by-aspect comparison of the two repos.

use std::collections::BTreeMap;
use std::collections::BTreeSet;

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
