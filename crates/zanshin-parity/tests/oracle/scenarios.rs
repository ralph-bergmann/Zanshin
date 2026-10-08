// SPDX-License-Identifier: MIT

//! The scenarios: what both repos hold, and the one operation each side runs.

use crate::driver::Step;

/// The shared history, built by the pinned CLI in both repos: root → A (a.txt) → B (b.txt,
/// bookmark `b-mark`) → C (c.txt) = @, working copy clean.
pub const BASE: &[Step] = &[
    Step::Write("a.txt", "a\n"),
    Step::Jj(&["describe", "-m", "A"]),
    Step::Jj(&["new", "-m", "B"]),
    Step::Write("b.txt", "b\n"),
    Step::Jj(&["new", "-m", "C"]),
    Step::Write("c.txt", "c\n"),
    Step::Jj(&["bookmark", "create", "b-mark", "-r", "@-"]),
];
