// SPDX-License-Identifier: MIT

//! Where the CLI prompts, Zanshin returns the candidates and takes the choice (Story 9.10): `jj
//! next` with two children answered at its prompt (forced interactive, the index on stdin) and
//! Zanshin's `movement_targets` + `move_working_copy` with the same candidate leave the same repo.

use std::io::Write as _;
use std::process::Stdio;

use zanshin_jj::{MovementOptions, Repo};

use crate::compare::compare;
use crate::driver::{command, fresh_repo, Step};
use crate::scenarios::BASE;
use crate::state::capture;

/// `X` (x.txt) beside B on A, then an empty `@` on A: `next` has two candidates.
const TWO_CHILDREN_OF_A: &[Step] = &[
    Step::Jj(&["new", "b-mark-", "-m", "X"]),
    Step::Write("x.txt", "x\n"),
    Step::Jj(&["new", "b-mark-"]),
];

/// The CLI's `jj next`, answering its prompt with `index` (1-based, its list's numbering).
fn cli_next_choosing(root: &std::path::Path, index: usize) {
    let mut child = command(root, &["next"])
        .env("JJ_INTERACTIVE", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn the pinned jj");
    child
        .stdin
        .take()
        .expect("stdin")
        .write_all(format!("{index}\n").as_bytes())
        .expect("answer the prompt");
    let output = child.wait_with_output().expect("wait for jj");
    assert!(
        output.status.success(),
        "jj next failed:\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn a_chosen_candidate_moves_where_the_clis_prompt_answer_moves() {
    test_helpers::pin_test_env();
    for index in [1, 2] {
        let (_dir_a, root_a) = fresh_repo(&["git", "init"], &[BASE, TWO_CHILDREN_OF_A]);
        let (_dir_b, root_b) = fresh_repo(&["git", "init"], &[BASE, TWO_CHILDREN_OF_A]);
        let before_a = capture(&root_a, None);
        let before_b = capture(&root_b, None);

        let mut repo = Repo::open(&root_a).expect("open");
        let plan = repo.movement_targets(&MovementOptions::default()).expect("targets");
        assert_eq!(plan.targets.len(), 2);
        let chosen = MovementOptions {
            target: Some(plan.targets[index - 1].commit_id.clone()),
            ..MovementOptions::default()
        };
        repo.move_working_copy(&chosen).expect("move to the chosen candidate");
        cli_next_choosing(&root_b, index);

        let found = compare(
            &capture(&root_a, Some(&before_a)).aspects,
            &capture(&root_b, Some(&before_b)).aspects,
        );
        assert!(
            found.is_empty(),
            "index {index}: {:?}",
            found
                .iter()
                .map(|d| format!("{}: {} | {}", d.aspect, d.zanshin, d.cli))
                .collect::<Vec<_>>()
        );
    }
}
