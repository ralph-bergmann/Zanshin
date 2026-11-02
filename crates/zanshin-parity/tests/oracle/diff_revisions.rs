// SPDX-License-Identifier: MIT

//! `jj diff -r` over a set and the multiple-revisions hint against the pinned CLI: a set with gaps
//! refuses with the CLI's message and hint, a range diffs the paths `--summary` prints, and a
//! single-revision argument resolving to several commits carries the CLI's summary hint block
//! verbatim. Each witness runs through Zanshin and the pinned `jj` on the SAME repo (a diff and a
//! refusal write no operation on a clean working copy, so both see one state).

use std::path::Path;

use zanshin_jj::{ChangeKind, DiffOptions, DiffRevisions, MutateError, Repo};

use crate::driver::{fresh_repo, jj, Step};
use crate::scenarios::BASE;

/// Three more empty commits on C: `all()` holds seven commits.
const THREE_MORE: &[Step] = &[
    Step::Jj(&["new", "-m", "D"]),
    Step::Jj(&["new", "-m", "E"]),
    Step::Jj(&["new", "-m", "F"]),
];

fn revision(text: &str) -> DiffOptions {
    DiffOptions {
        revisions: DiffRevisions::Revision(Some(text.to_owned())),
        ..DiffOptions::default()
    }
}

fn from(text: &str) -> DiffOptions {
    DiffOptions {
        revisions: DiffRevisions::FromTo {
            from: Some(text.to_owned()),
            to: None,
        },
        ..DiffOptions::default()
    }
}

/// The CLI's refusal of `args`: its `Error: ` line and its hint blocks (each `Hint: ` line with
/// the lines that continue it, the label stripped, joined with `\n`).
#[track_caller]
fn cli_refusal(root: &Path, args: &[&str]) -> (String, Vec<String>) {
    let run = jj(root, args);
    assert!(!run.success, "the CLI refuses {args:?}");
    let mut error = None;
    let mut hints: Vec<String> = Vec::new();
    for line in run.stderr.lines() {
        if let Some(message) = line.strip_prefix("Error: ") {
            error = Some(message.to_owned());
        } else if let Some(hint) = line.strip_prefix("Hint: ") {
            hints.push(hint.to_owned());
        } else if let Some(last) = hints.last_mut() {
            last.push('\n');
            last.push_str(line);
        }
    }
    let error = error.unwrap_or_else(|| panic!("no Error line in:\n{}", run.stderr));
    (error, hints)
}

#[test]
fn a_gap_refuses_like_the_cli() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[BASE]);
    let set = "b-mark- | @";
    let cli = cli_refusal(&root, &["diff", "-r", set]);
    let err = Repo::open(&root)
        .expect("open")
        .diff(&revision(set))
        .expect_err("a gap");
    let MutateError::InvalidInput { reason, hints } = err else {
        unreachable!("a gap is invalid input: {err:?}")
    };
    assert_eq!((reason, hints), cli);
}

#[test]
fn a_range_diffs_the_paths_the_cli_summarizes() {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[BASE]);
    let set = "b-mark::@";
    let cli = jj(&root, &["diff", "-r", set, "--summary"]).ok().stdout;
    let diff = Repo::open(&root).expect("open").diff(&revision(set)).expect("range");
    let zanshin: Vec<String> = diff
        .files
        .iter()
        .map(|file| {
            let letter = match file.kind {
                ChangeKind::Added => 'A',
                ChangeKind::Removed => 'D',
                _ => 'M',
            };
            format!("{letter} {}", file.path)
        })
        .collect();
    assert_eq!(zanshin, cli.lines().collect::<Vec<_>>());
    assert_eq!(cli, "A b.txt\nA c.txt\n");
}

/// `jj diff --from 'all()'` and Zanshin's refuse with the same message and hints, which are
/// returned.
fn assert_several_match(steps: &[&[Step]]) -> (String, Vec<String>) {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], steps);
    let cli = cli_refusal(&root, &["diff", "--from", "all()"]);
    let err = Repo::open(&root)
        .expect("open")
        .diff(&from("all()"))
        .expect_err("several");
    let MutateError::RevsetResolutionError { reason, hints } = err else {
        unreachable!("several commits do not resolve: {err:?}")
    };
    assert_eq!((reason, hints), cli);
    cli
}

/// Four commits: the CLI's message and summary hint verbatim.
#[test]
fn several_revisions_carry_the_cli_summary_hint() {
    let (_, hints) = assert_several_match(&[BASE]);
    assert!(hints[0].contains(" b-mark | B"), "{hints:?}");
}

/// Past five commits the CLI lists five, then `  ...`; so does Zanshin.
#[test]
fn several_revisions_past_five_elide_like_the_cli() {
    let (_, hints) = assert_several_match(&[BASE, THREE_MORE]);
    assert!(hints[0].ends_with("\n  ..."), "{hints:?}");
}
