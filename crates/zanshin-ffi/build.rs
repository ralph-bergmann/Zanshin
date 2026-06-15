// SPDX-License-Identifier: Apache-2.0
use std::process::Command;

fn main() {
    let sha = Command::new("git")
        .args(["rev-parse", "--short=12", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_owned());
    println!("cargo:rustc-env=ZANSHIN_GIT_SHA={sha}");

    // Refresh the stamp when HEAD moves. The crate root is crates/zanshin-ffi/; the repo
    // .git is two levels up. `.git/logs/HEAD` (the reflog) appends on every commit,
    // checkout, or reset — a single reliable trigger. `.git/HEAD` does NOT change on a
    // new commit to the same branch, so is not used here. Path is package-root-relative.
    println!("cargo:rerun-if-changed=../../.git/logs/HEAD");
}
