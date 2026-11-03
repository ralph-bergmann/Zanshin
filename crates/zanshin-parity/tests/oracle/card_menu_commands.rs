// SPDX-License-Identifier: MIT

//! Story 10.15: every command the graph's card menu, bookmark popover and name sheet show
//! (`test-fixtures/commands/card-menu.txt`, which the app's `graph_card_menu_test.dart` asserts
//! line for line) runs through `sh` with the pinned `jj` — so the pinned CLI parses and accepts
//! the text the UI shows, shell quoting included (deferred I1, I2).

use std::path::Path;
use std::process::Command;
use std::process::Stdio;

use crate::driver;
use crate::git_scenarios::PUSHED;
use crate::scenarios::BASE;

/// The fixture card's short change id in the command file; each line gets `b-mark`'s.
const CARD: &str = "kmnvxoqp";

/// Runs `line` through `sh -c` in `root` with the pinned `jj` first on `PATH`, the CLI's hermetic
/// environment and `JJ_EDITOR=true` (describe and squash open the editor; `true` keeps the text).
pub(crate) fn run_line(root: &Path, line: &str) -> std::process::Output {
    let jj = Path::new(env!("CARGO_BIN_EXE_jj"))
        .parent()
        .expect("the jj binary's directory");
    let path = std::env::var_os("PATH").unwrap_or_default();
    let mut paths = vec![jj.to_path_buf()];
    paths.extend(std::env::split_paths(&path));
    let mut sh = Command::new("sh");
    sh.arg("-c").arg(line).current_dir(root).stdin(Stdio::null());
    for (name, value) in driver::command(root, &[]).get_envs() {
        match value {
            Some(value) => sh.env(name, value),
            None => sh.env_remove(name),
        };
    }
    sh.env("PATH", std::env::join_paths(paths).expect("a joinable PATH"))
        .env("JJ_EDITOR", "true");
    sh.output().expect("spawn sh")
}

#[test]
fn card_menu_commands_run_with_the_pinned_jj() {
    test_helpers::pin_test_env();
    let file = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-fixtures/commands/card-menu.txt");
    let text = std::fs::read_to_string(&file).expect("the card menu's command file");
    let mut failed = Vec::new();
    let mut count = 0;
    for line in text.lines().filter(|line| !line.trim().is_empty()) {
        count += 1;
        let (_dir, root) = driver::fresh_repo(&["git", "init"], &[BASE, PUSHED]);
        let id = driver::jj(&root, &["log", "--no-graph", "-r", "b-mark", "-T", "change_id"]).ok();
        let command = line.replace(CARD, id.stdout.trim());
        if line.starts_with("jj bookmark track ") {
            // The push left `b-mark@origin` tracked: Track needs it untracked.
            driver::jj(&root, &["bookmark", "untrack", "b-mark@origin"]).ok();
        }
        let output = run_line(&root, &command);
        if !output.status.success() {
            failed.push(format!("{command}\n{}", String::from_utf8_lossy(&output.stderr)));
        }
    }
    assert!(count > 0, "the command file is empty");
    assert!(failed.is_empty(), "the pinned jj refused:\n{}", failed.join("\n"));
}
