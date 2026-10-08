// SPDX-License-Identifier: MIT

//! The scenarios: what both repos hold, and the one operation each side runs.
//!
//! Each scenario names the `zanshin-jj` call (repo A) and the CLI argv (repo B) that mean the
//! same thing. A new verb story adds its scenarios here — they are its executable acceptance
//! criteria against the real CLI (Story 9.47).

use std::path::Path;

use zanshin_jj::ConfigScope;
use zanshin_jj::ConfigTarget;

use crate::compare::config_outcome;
use crate::compare::zanshin_outcome;
use crate::compare::Outcome;
use crate::driver::jj;
use crate::driver::Step;
use crate::state::State;

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

/// How both repos are created; the CLI's default is colocated.
const GIT_INIT: &[&str] = &["git", "init"];

/// `Repo::init` against `jj <argv>` on an empty directory: no shared history.
pub const INIT_SCENARIOS: &[(&str, &[&str])] = &[
    ("init_colocated", &["git", "init"]),
    ("init_no_colocate", &["git", "init", "--no-colocate"]),
];

/// One operation, run through Zanshin in repo A and through the CLI in repo B.
pub struct Scenario {
    pub id: &'static str,
    /// The CLI command that creates both repos.
    pub init: &'static [&'static str],
    /// CLI steps after [`BASE`], identical in both repos.
    pub setup: &'static [Step],
    /// Files written into both working copies right before the operation (not snapshotted).
    pub files: &'static [(&'static str, &'static str)],
    pub zanshin: fn(&mut zanshin_jj::Repo, &Path, &State) -> Outcome,
    pub cli: fn(&State) -> Vec<String>,
    /// A scenario-specific read of both repos after the operation, compared as `extra`.
    pub extra: Option<fn(&Path) -> String>,
}

fn args(items: &[&str]) -> Vec<String> {
    items.iter().map(|item| (*item).to_owned()).collect()
}

/// A plain scenario on the BASE history: no extra setup, files or read-back.
fn simple(
    id: &'static str,
    zanshin: fn(&mut zanshin_jj::Repo, &Path, &State) -> Outcome,
    cli: fn(&State) -> Vec<String>,
) -> Scenario {
    Scenario {
        id,
        init: GIT_INIT,
        setup: &[],
        files: &[],
        zanshin,
        cli,
        extra: None,
    }
}

/// `jj config get` / `config path --repo` / the file's text, read back through the CLI.
fn config_read_back(root: &Path) -> String {
    let value = jj(root, &["config", "get", "ui.conflict-marker-style"]).ok().stdout;
    let path = jj(root, &["config", "path", "--repo"]).ok().stdout;
    let text = std::fs::read_to_string(path.trim_end()).unwrap_or_else(|err| format!("<{err}>"));
    format!("cli get={:?} file={text:?}", value.trim_end())
}

/// The scenario table (Story 9.47's initial set).
#[allow(clippy::too_many_lines)] // WHY: one flat table reads better than 24 helper fns
pub fn scenarios() -> Vec<Scenario> {
    vec![
        simple(
            "describe_gui_text",
            |repo, _, s| {
                let result = repo.describe(s.change("@"), "C described");
                zanshin_outcome(repo, &result)
            },
            |_| args(&["describe", "-m", "C described"]),
        ),
        simple(
            "describe_cli_text",
            |repo, _, s| {
                let result = repo.describe(s.change("@"), "C described\n");
                zanshin_outcome(repo, &result)
            },
            |_| args(&["describe", "-m", "C described"]),
        ),
        simple(
            "new_on_wc",
            |repo, _, s| {
                let result = repo.new_change(&[s.change("@")]);
                zanshin_outcome(repo, &result)
            },
            |_| args(&["new"]),
        ),
        Scenario {
            setup: &[Step::Jj(&["new", "@--", "-m", "D"]), Step::Write("d.txt", "d\n")],
            ..simple(
                "new_merge",
                |repo, _, s| {
                    let result = repo.new_change(&[s.change("C"), s.change("D")]);
                    zanshin_outcome(repo, &result)
                },
                |s| vec!["new".to_owned(), s.change_arg("C"), s.change_arg("D")],
            )
        },
        Scenario {
            // C and D both add c.txt with different content.
            setup: &[Step::Jj(&["new", "@--", "-m", "D"]), Step::Write("c.txt", "c from D\n")],
            ..simple(
                "new_conflicting_merge",
                |repo, _, s| {
                    let result = repo.new_change(&[s.change("C"), s.change("D")]);
                    zanshin_outcome(repo, &result)
                },
                |s| vec!["new".to_owned(), s.change_arg("C"), s.change_arg("D")],
            )
        },
        simple(
            "abandon_middle",
            |repo, _, s| {
                let result = repo.abandon(&[s.change("B")]);
                zanshin_outcome(repo, &result)
            },
            |s| vec!["abandon".to_owned(), s.change_arg("B")],
        ),
        simple(
            "abandon_wc",
            |repo, _, s| {
                let result = repo.abandon(&[s.change("@")]);
                zanshin_outcome(repo, &result)
            },
            |_| args(&["abandon"]),
        ),
        simple(
            "edit_parent",
            |repo, _, s| {
                let result = repo.edit(s.change("B"));
                zanshin_outcome(repo, &result)
            },
            |s| vec!["edit".to_owned(), s.change_arg("B")],
        ),
        Scenario {
            setup: &[Step::Jj(&["describe", "-m", "to be undone"])],
            ..simple(
                "undo_after_describe",
                |repo, _, _| {
                    let result = repo.undo(false);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["undo"]),
            )
        },
        simple(
            "bookmark_create",
            |repo, _, _| {
                let result = repo.bookmark_create(&["feature".to_owned()], None);
                zanshin_outcome(repo, &result)
            },
            |_| args(&["bookmark", "create", "feature"]),
        ),
        simple(
            "bookmark_create_existing",
            |repo, _, _| {
                let result = repo.bookmark_create(&["b-mark".to_owned()], None);
                zanshin_outcome(repo, &result)
            },
            |_| args(&["bookmark", "create", "b-mark"]),
        ),
        simple(
            "bookmark_delete",
            |repo, _, _| {
                let result = repo.bookmark_delete(&["b-mark".to_owned()]);
                zanshin_outcome(repo, &result)
            },
            |_| args(&["bookmark", "delete", "b-mark"]),
        ),
        Scenario {
            extra: Some(config_read_back),
            ..simple(
                "config_set_repo",
                |_, root, _| {
                    config_outcome(&zanshin_jj::config_set(
                        Some(root),
                        &ConfigTarget::Scope(ConfigScope::Repo),
                        "ui.conflict-marker-style",
                        "git",
                    ))
                },
                |_| args(&["config", "set", "--repo", "ui.conflict-marker-style", "git"]),
            )
        },
        Scenario {
            files: &[("c.txt", "c, edited before config set\n")],
            ..simple(
                "config_set_with_dirty_wc",
                |_, root, _| {
                    config_outcome(&zanshin_jj::config_set(
                        Some(root),
                        &ConfigTarget::Scope(ConfigScope::Repo),
                        "user.email",
                        "other@example.invalid",
                    ))
                },
                |_| args(&["config", "set", "--repo", "user.email", "other@example.invalid"]),
            )
        },
        Scenario {
            files: &[("c.txt", "c modified\n")],
            ..simple(
                "snapshot_modified_file",
                |repo, _, _| {
                    let result = repo.snapshot();
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["util", "snapshot"]),
            )
        },
        Scenario {
            files: &[("c.txt", "c modified\n")],
            ..simple(
                "snapshot_then_describe",
                |repo, _, s| {
                    let result = repo.describe(s.change("@"), "C modified\n");
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["describe", "-m", "C modified"]),
            )
        },
        Scenario {
            setup: &[Step::Jj(&[
                "config",
                "set",
                "--repo",
                "revset-aliases.'immutable_heads()'",
                "b-mark",
            ])],
            ..simple(
                "describe_immutable",
                |repo, _, s| {
                    let result = repo.describe(s.change("B"), "nope\n");
                    zanshin_outcome(repo, &result)
                },
                |s| {
                    vec![
                        "describe".to_owned(),
                        s.change_arg("B"),
                        "-m".to_owned(),
                        "nope".to_owned(),
                    ]
                },
            )
        },
        simple(
            "describe_root",
            |repo, _, s| {
                let result = repo.describe(s.change("root"), "nope\n");
                zanshin_outcome(repo, &result)
            },
            |_| args(&["describe", "root()", "-m", "nope"]),
        ),
        simple(
            "describe_no_change",
            |repo, _, s| {
                // The exact stored description, so only the no-change gate can differ.
                let result = repo.describe(s.change("@"), "C\n");
                zanshin_outcome(repo, &result)
            },
            |_| args(&["describe", "-m", "C"]),
        ),
        Scenario {
            setup: &[Step::Jj(&[
                "config",
                "set",
                "--repo",
                "templates.commit_trailers",
                "format_signed_off_by_trailer(self)",
            ])],
            ..simple(
                "describe_commit_trailers",
                |repo, _, s| {
                    let result = repo.describe(s.change("@"), "T\n");
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["describe", "-m", "T"]),
            )
        },
        simple(
            "restore_from",
            |repo, _, s| {
                let result = repo.restore(Some(s.change("A")), None, None, &["c.txt".to_owned()], false);
                zanshin_outcome(repo, &result)
            },
            |s| {
                vec![
                    "restore".to_owned(),
                    "--from".to_owned(),
                    s.change_arg("A"),
                    "c.txt".to_owned(),
                ]
            },
        ),
        simple(
            "restore_no_args",
            |repo, _, _| {
                let result = repo.restore(None, None, None, &[], false);
                zanshin_outcome(repo, &result)
            },
            |_| args(&["restore"]),
        ),
        Scenario {
            files: &[("b.txt", "b changed\n")],
            ..simple(
                "absorb",
                |repo, _, _| {
                    let result = repo.absorb(None, None, &[]);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["absorb"]),
            )
        },
        Scenario {
            // jj 0.46 refuses this without --allow-cross-workspace (`cli/src/commands/undo.rs`
            // @ v0.46.0); Zanshin ported that in Story 9.39. Non-colocated, so `workspace add`
            // creates no Git worktree.
            init: &["git", "init", "--no-colocate"],
            setup: &[
                Step::Jj(&["workspace", "add", "../ws2"]),
                Step::JjAt("../ws2", &["describe", "-m", "from ws2"]),
            ],
            ..simple(
                "undo_cross_workspace",
                |repo, _, _| {
                    let result = repo.undo(false);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["undo"]),
            )
        },
    ]
}
