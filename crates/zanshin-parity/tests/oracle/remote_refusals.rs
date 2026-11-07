// SPDX-License-Identifier: MIT

//! The `jj git remote add/remove/rename/set-url` refusals against the pinned CLI (Settings ›
//! Remotes, Story 11.18): each refuses through Zanshin and through the pinned `jj` on the SAME
//! repo (a refusal writes no operation) and Zanshin's message — what the FFI carries and the
//! Settings window shows — equals the CLI's `Error: ` line verbatim, without the label.

use zanshin_jj::{MutateError, MutationResult, Repo};

use crate::driver::{fresh_repo, jj, Step};

/// `origin`, and `pushy` added with a push URL — jj-lib's own `pushurl` key makes its git config
/// nonstandard for `remove` and `rename`.
const REMOTES: &[Step] = &[
    Step::Jj(&["git", "remote", "add", "origin", "../origin.git"]),
    Step::Jj(&[
        "git",
        "remote",
        "add",
        "pushy",
        "../pushy.git",
        "--push-url",
        "../pushy-push.git",
    ]),
];

type Verb = fn(&mut Repo) -> Result<MutationResult, MutateError>;

/// The message Zanshin's FFI carries for `err`: jj-lib's reason for an invalid name, the error's
/// text (the `context`'s second line) for the three remote codes.
fn zanshin_message(err: &MutateError) -> String {
    match err {
        MutateError::InvalidInput { reason, .. } => reason.clone(),
        other => other.to_string(),
    }
}

#[test]
fn remote_refusals_are_the_cli_error_lines() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[REMOTES]);
    let cases: &[(&[&str], Verb)] = &[
        (&["git", "remote", "add", "origin", "../x.git"], |r| {
            r.git_remote_add("origin", "../x.git", None)
        }),
        (&["git", "remote", "add", "git", "../x.git"], |r| {
            r.git_remote_add("git", "../x.git", None)
        }),
        (&["git", "remote", "add", "a/b", "../x.git"], |r| {
            r.git_remote_add("a/b", "../x.git", None)
        }),
        (&["git", "remote", "remove", "nope"], |r| r.git_remote_remove("nope")),
        (&["git", "remote", "remove", "pushy"], |r| r.git_remote_remove("pushy")),
        (&["git", "remote", "rename", "nope", "other"], |r| {
            r.git_remote_rename("nope", "other")
        }),
        (&["git", "remote", "rename", "origin", "pushy"], |r| {
            r.git_remote_rename("origin", "pushy")
        }),
        (&["git", "remote", "rename", "origin", "git"], |r| {
            r.git_remote_rename("origin", "git")
        }),
        (&["git", "remote", "rename", "pushy", "other"], |r| {
            r.git_remote_rename("pushy", "other")
        }),
        (&["git", "remote", "set-url", "nope", "../x.git"], |r| {
            r.git_remote_set_url("nope", Some("../x.git"), None)
        }),
        (&["git", "remote", "set-url", "git", "../x.git"], |r| {
            r.git_remote_set_url("git", Some("../x.git"), None)
        }),
    ];
    for (args, verb) in cases {
        let run = jj(&root, args);
        assert!(!run.success, "the CLI refuses {args:?}");
        let cli = run
            .stderr
            .lines()
            .find_map(|line| line.strip_prefix("Error: "))
            .unwrap_or_else(|| panic!("no Error line for {args:?} in:\n{}", run.stderr));
        let mut repo = Repo::open(&root).expect("open");
        let err = verb(&mut repo).expect_err("Zanshin refuses too");
        assert_eq!(zanshin_message(&err), cli, "{args:?}: {err:?}");
    }
}
