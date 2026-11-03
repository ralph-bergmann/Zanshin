// SPDX-License-Identifier: MIT

//! Story 10.10: every command the graph's drop menu and drag ghost show
//! (`test-fixtures/commands/drop-menu.txt`, which the app's `graph_drag_test.dart` asserts line
//! for line) runs through `sh` with the pinned `jj` — `--allow-backwards` and an `exact:` name
//! included — so the pinned CLI parses and accepts the text the UI shows.

use std::path::Path;

use crate::card_menu_commands::run_line;
use crate::driver;
use crate::scenarios::BASE;

/// The dragged change's short id in the command file: `C` (`@`).
const SOURCE: &str = "kmnvxoqp";

/// The target's short id in the command file: `A`.
const TARGET: &str = "vruxwmqv";

/// A bookmark whose name holds a glob character (a valid Git ref name), on `B` next to `b-mark`.
const GLOB_BOOKMARK: &str = "\"feat{x}\"";

#[test]
fn drop_menu_commands_run_with_the_pinned_jj() {
    test_helpers::pin_test_env();
    let file = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-fixtures/commands/drop-menu.txt");
    let text = std::fs::read_to_string(&file).expect("the drop menu's command file");
    let mut failed = Vec::new();
    let mut count = 0;
    for line in text.lines().filter(|line| !line.trim().is_empty()) {
        count += 1;
        let (_dir, root) = driver::fresh_repo(&["git", "init"], &[BASE]);
        driver::jj(&root, &["bookmark", "create", GLOB_BOOKMARK, "-r", "@-"]).ok();
        let id = |revset: &str| {
            let out = driver::jj(&root, &["log", "--no-graph", "-r", revset, "-T", "change_id"]).ok();
            out.stdout.trim().to_owned()
        };
        let command = line
            .replace(SOURCE, &id("@"))
            .replace(TARGET, &id("subject(exact:\"A\")"));
        let output = run_line(&root, &command);
        if !output.status.success() {
            failed.push(format!("{command}\n{}", String::from_utf8_lossy(&output.stderr)));
        }
    }
    assert!(count > 0, "the command file is empty");
    assert!(failed.is_empty(), "the pinned jj refused:\n{}", failed.join("\n"));
}
