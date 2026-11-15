// SPDX-License-Identifier: MIT

//! `Repo::list_tags` against the pinned `jj tag list --all-remotes` (Story 9.59): row order,
//! `tracked`, `synced`, `conflicted`, the target-less row of a deleted local tag, the
//! `ui.tag-list-sort-keys` order and the dropped `@git` rows. Each witness reads the SAME repo
//! through Zanshin and the CLI (a list writes no operation on a clean working copy).

use std::path::Path;

use zanshin_jj::{Repo, TagKind};

use crate::driver::{fresh_repo, jj, Step};
use crate::scenarios::BASE;

/// A Git-backed repo with no colocated `.git` (the CLI's `git.colocate` default is `true`).
const NOT_COLOCATED: &[&str] = &["git", "init", "--no-colocate"];

/// One row per line: `name|remote|tracked|synced|conflict|added target change ids`.
const ROW: &str = r#"name ++ "|" ++ if(remote, remote) ++ "|" ++ if(tracked, "tracked") ++ "|" ++ if(synced, "synced") ++ "|" ++ if(conflict, "conflict") ++ "|" ++ if(present, added_targets.map(|c| c.change_id()).join(",")) ++ "\n""#;

/// Remotes `origin` and `remote2`, and one tag per row kind: `a0` local only; `v1` pushed to both,
/// untracked on `remote2`; `v2` pushed, then moved locally (unsynced); `v3` pushed, then untracked;
/// `v4` pushed, then deleted (the target-less local row); `v5` pushed, deleted and untracked (a
/// remote-only untracked row).
const MIXED: &[Step] = &[
    Step::Git(&["init", "-q", "--bare", "../remote.git"]),
    Step::Git(&["init", "-q", "--bare", "../remote2.git"]),
    Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
    Step::Jj(&["git", "remote", "add", "remote2", "../remote2.git"]),
    Step::Jj(&["tag", "set", "a0", "v1", "v2", "v3", "v4", "v5", "-r", "@-"]),
    Step::Jj(&[
        "git", "push", "-t", "v1", "-t", "v2", "-t", "v3", "-t", "v4", "-t", "v5",
    ]),
    Step::Jj(&["tag", "track", "v1@remote2"]),
    Step::Jj(&["git", "push", "--remote", "remote2", "-t", "v1"]),
    Step::Jj(&["tag", "untrack", "v1@remote2", "v3@origin"]),
    Step::Jj(&["tag", "set", "v2", "-r", "@--", "--allow-move"]),
    Step::Jj(&["tag", "delete", "v4", "v5"]),
    Step::Jj(&["tag", "untrack", "v5@origin"]),
];

/// `c` set on B and, from the operation before, on a commit S beside it: the merged operations
/// leave `c` conflicted (an ancestor and its descendant would merge to the descendant instead).
const CONFLICTED: &[Step] = &[
    Step::Jj(&["new", "root()", "-m", "S"]),
    Step::Jj(&["new", "-m", "T"]),
    Step::Jj(&["tag", "set", "c", "-r", "b-mark"]),
    Step::Jj(&["--at-op", "@-", "tag", "set", "c", "-r", "@-"]),
    Step::Jj(&["tag", "set", "d", "-r", "b-mark"]),
];

/// Zanshin's rows in [`ROW`]'s shape (the first added target only, as `Tag::target` keeps it).
fn zanshin_rows(root: &Path) -> Vec<String> {
    let tags = Repo::open(root).expect("open").list_tags().expect("list_tags");
    tags.iter()
        .map(|tag| {
            let (remote, tracked) = match &tag.kind {
                TagKind::Local => ("", false),
                TagKind::Remote { remote_name, tracked } => (remote_name.as_str(), *tracked),
            };
            format!(
                "{}|{remote}|{}|{}|{}|{}",
                tag.name,
                if tracked { "tracked" } else { "" },
                if tag.synced { "synced" } else { "" },
                if tag.conflicted { "conflict" } else { "" },
                tag.target.as_ref().map_or("", |change| change.0.as_str()),
            )
        })
        .collect()
}

/// The CLI's rows, each target list cut to its first change id, and whether it printed an `@git`
/// row; the `@git` rows are left out, as `list_tags` leaves them out.
fn cli_rows(root: &Path) -> (Vec<String>, bool) {
    let out = jj(root, &["tag", "list", "--all-remotes", "-T", ROW]).ok().stdout;
    let mut saw_git = false;
    let rows = out
        .lines()
        .filter(|line| {
            let git = line.split('|').nth(1) == Some("git");
            saw_git |= git;
            !git
        })
        .map(|line| {
            let (head, targets) = line.rsplit_once('|').expect("six fields");
            format!("{head}|{}", targets.split(',').next().unwrap_or_default())
        })
        .collect();
    (rows, saw_git)
}

/// Asserts Zanshin's rows equal the CLI's on a repo made by `init` + BASE + `steps`; returns the
/// rows and whether the CLI printed an `@git` row.
fn assert_rows_match(init: &[&str], steps: &[&[Step]]) -> (Vec<String>, bool) {
    test_helpers::pin_test_env();
    let mut all = vec![BASE];
    all.extend_from_slice(steps);
    let (_dir, root) = fresh_repo(init, &all);
    let (cli, saw_git) = cli_rows(&root);
    assert_eq!(zanshin_rows(&root), cli);
    (cli, saw_git)
}

#[test]
fn rows_of_every_kind_list_like_the_cli() {
    let (rows, _) = assert_rows_match(NOT_COLOCATED, &[MIXED]);
    let names: Vec<_> = rows
        .iter()
        .map(|row| row.split('|').take(2).collect::<Vec<_>>().join("@"))
        .collect();
    assert_eq!(
        names,
        [
            "a0@",
            "v1@",
            "v1@origin",
            "v1@remote2",
            "v2@",
            "v2@origin",
            "v3@",
            "v3@origin",
            "v4@",
            "v4@origin",
            "v5@origin"
        ]
    );
    assert!(rows.iter().any(|row| row.starts_with("v4||||")), "{rows:?}");
}

#[test]
fn a_descending_sort_key_orders_like_the_cli() {
    let config: &[Step] = &[Step::Jj(&[
        "config",
        "set",
        "--repo",
        "ui.tag-list-sort-keys",
        r#"["name-"]"#,
    ])];
    let (rows, _) = assert_rows_match(NOT_COLOCATED, &[MIXED, config]);
    assert!(rows[0].starts_with("v5|origin"), "{rows:?}");
}

#[test]
fn a_conflicted_tag_lists_like_the_cli() {
    let (rows, _) = assert_rows_match(NOT_COLOCATED, &[CONFLICTED]);
    assert!(
        rows.iter().any(|row| row.starts_with("c|||synced|conflict|")),
        "{rows:?}"
    );
}

/// A tag deleted before an export: the CLI lists the target-less local row beside `v1@git`; the
/// local row stays without it.
#[test]
fn a_tag_deleted_before_an_export_keeps_its_local_row_like_the_cli() {
    let deleted: &[Step] = &[
        Step::Jj(&["tag", "set", "v1", "-r", "@-"]),
        Step::Jj(&["git", "export"]),
        Step::Jj(&["tag", "delete", "v1"]),
    ];
    let (rows, saw_git) = assert_rows_match(NOT_COLOCATED, &[deleted]);
    assert_eq!((rows, saw_git), (vec!["v1|||||".to_owned()], true));
}

#[test]
fn a_colocated_repo_drops_the_git_rows_the_cli_prints() {
    let (rows, saw_git) = assert_rows_match(&["git", "init", "--colocate"], &[MIXED]);
    assert!(saw_git, "the CLI prints @git rows on a colocated repo: {rows:?}");
}
