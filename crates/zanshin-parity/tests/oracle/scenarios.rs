// SPDX-License-Identifier: MIT

//! The scenarios: what both repos hold, and the one operation each side runs.
//!
//! Each scenario names the `zanshin-jj` call (repo A) and the CLI argv (repo B) that mean the
//! same thing. A new verb story adds its scenarios here — they are its executable acceptance
//! criteria against the real CLI (Story 9.47).

use std::path::Path;

use jj_lib::backend::CommitId;
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;
use zanshin_jj::CommitOptions;
use zanshin_jj::ConfigScope;
use zanshin_jj::ConfigTarget;
use zanshin_jj::SparseInheritance;
use zanshin_jj::SplitOptions;
use zanshin_jj::SquashOptions;

use crate::compare::config_outcome;
use crate::compare::zanshin_outcome;
use crate::compare::Outcome;
use crate::driver::jj;
use crate::driver::Step;
use crate::state::disk_files;
use crate::state::first_line;
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
pub const GIT_INIT: &[&str] = &["git", "init"];

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

/// Loads the workspace at `dir` and its repo at the head operation.
fn load_workspace(dir: &Path) -> (Workspace, std::sync::Arc<jj_lib::repo::ReadonlyRepo>) {
    let workspace = Workspace::load(
        &test_helpers::test_settings(),
        dir,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &jj_lib::default_backend_factories::default_working_copy_factories(),
    )
    .expect("load the workspace");
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("load the head");
    (workspace, repo)
}

/// The commit `hex` by its description's first line (`root` for the root commit).
fn commit_label(repo: &jj_lib::repo::ReadonlyRepo, id: &CommitId) -> String {
    if id == repo.store().root_commit_id() {
        return "root".to_owned();
    }
    repo.store().get_commit(id).map_or_else(
        |_| "<not in store>".to_owned(),
        |commit| first_line(commit.description()),
    )
}

/// The operation `workspace`'s working copy is recorded at, by its description, and whether it
/// is the head (Story 9.23: `update-stale` records the working copy at the head WITHOUT an
/// operation of its own).
fn wc_op_label(workspace: &Workspace, repo: &jj_lib::repo::ReadonlyRepo) -> String {
    let wc_op = workspace.working_copy().operation_id();
    let description = pollster::block_on(repo.loader().load_operation(wc_op))
        .map_or_else(|_| "<missing>".to_owned(), |op| op.metadata().description.clone());
    // Ids differ between the two repos; the description's words around them do not.
    let description: Vec<&str> = description
        .split(' ')
        .map(|word| {
            if word.len() >= 12 && word.chars().all(|c| c.is_ascii_hexdigit()) {
                "<id>"
            } else {
                word
            }
        })
        .collect();
    format!("{:?} at_head={}", description.join(" "), wc_op == repo.op_id())
}

/// The second workspace `workspace add ../ws2` created beside the repo (Story 9.23): its name,
/// `@` and `@`'s parents, the `.jj/repo` pointer, `.jj/.gitignore`, the `.git` gitlink and the
/// Git HEAD of its worktree, its sparse patterns, the operation its working copy is recorded at,
/// and its files on disk — the state the default workspace's aspects do not cover.
fn ws2_read_back(root: &Path) -> String {
    let ws2 = root.join("..").join("ws2");
    if !ws2.join(".jj").exists() {
        return format!("no workspace (dir exists={})", ws2.exists());
    }
    let (workspace, repo) = load_workspace(&ws2);
    let name = workspace.workspace_name().to_owned();
    let at = repo.view().get_wc_commit_id(&name).map_or_else(
        || "<none>".to_owned(),
        |id| {
            let commit = repo.store().get_commit(id).expect("ws2's @");
            let parents: Vec<String> = commit.parent_ids().iter().map(|p| commit_label(&repo, p)).collect();
            format!("{:?} parents={parents:?}", commit.description())
        },
    );
    let repo_file = std::fs::read_to_string(ws2.join(".jj").join("repo")).unwrap_or_else(|err| format!("<{err}>"));
    let gitignore = std::fs::read_to_string(ws2.join(".jj").join(".gitignore")).ok();
    let gitlink = match std::fs::metadata(ws2.join(".git")) {
        Ok(meta) if meta.is_file() => "file",
        Ok(_) => "dir",
        Err(_) => "none",
    };
    let git_head = std::process::Command::new("git")
        .args(["rev-parse", "-q", "--verify", "HEAD"])
        .current_dir(&ws2)
        .output()
        .ok()
        .filter(|out| out.status.success())
        .and_then(|out| CommitId::try_from_hex(String::from_utf8_lossy(&out.stdout).trim()))
        .map_or_else(|| "<unborn or none>".to_owned(), |id| commit_label(&repo, &id));
    let sparse: Vec<String> = workspace
        .working_copy()
        .sparse_patterns()
        .expect("sparse patterns")
        .iter()
        .map(|p| p.as_internal_file_string().to_owned())
        .collect();
    format!(
        "name={} @={at} .jj/repo={repo_file:?} .gitignore={gitignore:?} .git={gitlink} git_head={git_head} \
         sparse={sparse:?} wc_op={} files={}",
        name.as_str(),
        wc_op_label(&workspace, &repo),
        disk_files(&ws2)
    )
}

/// The operation the default workspace's working copy is recorded at (Story 9.23).
fn wc_op_read_back(root: &Path) -> String {
    let (workspace, repo) = load_workspace(root);
    wc_op_label(&workspace, &repo)
}

/// `../ws2` restores its `@` (which lacks `c.txt`) INTO the default workspace's `@`: `default@`'s
/// TREE changes without a checkout there, so the default working copy is stale (a
/// description-only rewrite would leave it `Fresh`).
const STALE_FROM_WS2: &[Step] = &[
    Step::Jj(&["workspace", "add", "../ws2"]),
    Step::JjAt("../ws2", &["restore", "--into", "default@"]),
];

/// `workspace add` with every argument passed through — the Zanshin side of the CLI argv
/// `workspace add <destination> [--name] [-r]… [-m]… [--colocate|--no-colocate]
/// [--sparse-patterns]`.
fn add_outcome(
    repo: &mut zanshin_jj::Repo,
    name: Option<&str>,
    revisions: &[String],
    message_paragraphs: &[String],
    colocate: Option<bool>,
    sparse: SparseInheritance,
) -> Outcome {
    let result = repo.workspace_add("../ws2", name, revisions, message_paragraphs, colocate, sparse);
    zanshin_outcome(repo, &result)
}

/// `jj workspace update-stale` through Zanshin.
fn update_stale(repo: &mut zanshin_jj::Repo, _: &Path, _: &State) -> Outcome {
    let result = repo.workspace_update_stale();
    zanshin_outcome(repo, &result)
}

/// A non-colocated repo, where `workspace add` creates no Git worktree by default.
const NO_COLOCATE: &[&str] = &["git", "init", "--no-colocate"];

/// `ui.editor = "true"` on both sides (Story 9.15): where the CLI opens its editor, `true` saves
/// the buffer unchanged — what Zanshin writes without `-m`. Zanshin does not read the key. Quoted:
/// `config set` parses a bare `true` as a TOML boolean, which `ui.editor` refuses.
const EDITOR: &[Step] = &[Step::Jj(&["config", "set", "--repo", "ui.editor", "\"true\""])];

/// `C` holds a second file, `c2.txt`, so a path selects PART of it (Story 9.15).
const C2: &[Step] = &[Step::Write("c2.txt", "c2\n"), Step::Jj(&["util", "snapshot"])];

/// [`C2`] plus [`EDITOR`].
const C2_EDITOR: &[Step] = &[
    Step::Write("c2.txt", "c2\n"),
    Step::Jj(&["util", "snapshot"]),
    Step::Jj(&["config", "set", "--repo", "ui.editor", "\"true\""]),
];

/// `templates.commit_trailers = format_signed_off_by_trailer(self)` (Story 9.51) — the
/// `config set` step every trailers scenario starts with.
const TRAILERS_STEP: Step = Step::Jj(&[
    "config",
    "set",
    "--repo",
    "templates.commit_trailers",
    "format_signed_off_by_trailer(self)",
]);

/// [`TRAILERS_STEP`] alone.
const TRAILERS: &[Step] = &[TRAILERS_STEP];

/// A `templates.commit_trailers` that does not parse (Story 9.51).
const BROKEN_TRAILERS: &[Step] = &[Step::Jj(&[
    "config",
    "set",
    "--repo",
    "templates.commit_trailers",
    "nope(",
])];

/// `templates.new_description = '"N"'` — a template string literal (Story 9.51).
const NEW_DESCRIPTION_STEP: Step = Step::Jj(&["config", "set", "--repo", "templates.new_description", "'\"N\"'"]);

/// [`NEW_DESCRIPTION_STEP`] alone.
const NEW_DESCRIPTION: &[Step] = &[NEW_DESCRIPTION_STEP];

/// [`NEW_DESCRIPTION_STEP`] plus [`TRAILERS_STEP`].
const NEW_DESCRIPTION_TRAILERS: &[Step] = &[NEW_DESCRIPTION_STEP, TRAILERS_STEP];

/// The `ui.editor = "true"` step of [`EDITOR`].
const EDITOR_STEP: Step = Step::Jj(&["config", "set", "--repo", "ui.editor", "\"true\""]);

/// [`TRAILERS_STEP`] plus [`EDITOR_STEP`].
const TRAILERS_EDITOR: &[Step] = &[TRAILERS_STEP, EDITOR_STEP];

/// A custom `templates.draft_commit_description` (Story 9.51) plus [`EDITOR_STEP`].
const CUSTOM_DRAFT_EDITOR: &[Step] = &[
    Step::Jj(&[
        "config",
        "set",
        "--repo",
        "templates.draft_commit_description",
        "concat(\"pre\\n\", description)",
    ]),
    EDITOR_STEP,
];

/// [`C2`] plus [`TRAILERS_STEP`].
const C2_TRAILERS: &[Step] = &[
    Step::Write("c2.txt", "c2\n"),
    Step::Jj(&["util", "snapshot"]),
    TRAILERS_STEP,
];

/// [`C2_EDITOR`] plus [`TRAILERS_STEP`].
const C2_EDITOR_TRAILERS: &[Step] = &[
    Step::Write("c2.txt", "c2\n"),
    Step::Jj(&["util", "snapshot"]),
    EDITOR_STEP,
    TRAILERS_STEP,
];

/// An undescribed `@` on C holding `x.txt` and `y.txt`, `template-aliases.default_commit_description
/// = '"DEF\n"'` and [`EDITOR_STEP`] (Story 9.51).
const UNDESCRIBED_DEFAULT_DESCRIPTION_EDITOR: &[Step] = &[
    Step::Jj(&["new"]),
    Step::Write("x.txt", "x\n"),
    Step::Write("y.txt", "y\n"),
    Step::Jj(&["util", "snapshot"]),
    Step::Jj(&[
        "config",
        "set",
        "--repo",
        "template-aliases.default_commit_description",
        "'\"DEF\\n\"'",
    ]),
    EDITOR_STEP,
];

/// `Repo::squash` with `options`.
fn squash_outcome(repo: &mut zanshin_jj::Repo, options: &SquashOptions) -> Outcome {
    let result = repo.squash(options);
    zanshin_outcome(repo, &result)
}

/// `Repo::split` with `options`.
fn split_outcome(repo: &mut zanshin_jj::Repo, options: &SplitOptions) -> Outcome {
    let result = repo.split(options);
    zanshin_outcome(repo, &result)
}

/// `split -m first --parallel c.txt`.
fn split_parallel() -> SplitOptions {
    SplitOptions {
        parallel: true,
        ..split_first(&["c.txt"])
    }
}

/// The split options every split scenario starts from: `-m first` over `paths`.
fn split_first(paths: &[&str]) -> SplitOptions {
    SplitOptions {
        paths: paths.iter().map(|p| (*p).to_owned()).collect(),
        message: Some(vec!["first".to_owned()]),
        ..SplitOptions::default()
    }
}

/// `Repo::commit` with `paths` and `message`.
fn commit_outcome(repo: &mut zanshin_jj::Repo, paths: &[&str], message: &[&str]) -> Outcome {
    let options = CommitOptions {
        paths: paths.iter().map(|p| (*p).to_owned()).collect(),
        message: message.iter().map(|m| (*m).to_owned()).collect(),
    };
    let result = repo.commit(&options);
    zanshin_outcome(repo, &result)
}

/// `experimental-advance-branches.enabled-branches = ["*"]` in the repo config (Story 9.49).
const ADVANCE_ALL: &[Step] = &[Step::Jj(&[
    "config",
    "set",
    "--repo",
    "experimental-advance-branches.enabled-branches",
    "[\"*\"]",
])];

/// [`ADVANCE_ALL`] minus `b-mark` (Story 9.49).
const ADVANCE_ALL_BUT_B_MARK: &[Step] = &[
    Step::Jj(&[
        "config",
        "set",
        "--repo",
        "experimental-advance-branches.enabled-branches",
        "[\"*\"]",
    ]),
    Step::Jj(&[
        "config",
        "set",
        "--repo",
        "experimental-advance-branches.disabled-branches",
        "[\"b-mark\"]",
    ]),
];

/// A merge `@` of C (`c-mark`) and its sibling S (`s-mark`) on B, with every bookmark
/// advanceable (Story 9.49).
const ADVANCE_MERGE: &[Step] = &[
    Step::Jj(&[
        "config",
        "set",
        "--repo",
        "experimental-advance-branches.enabled-branches",
        "[\"*\"]",
    ]),
    Step::Jj(&["bookmark", "create", "c-mark", "-r", "@"]),
    Step::Jj(&["new", "-m", "S", "b-mark"]),
    Step::Jj(&["bookmark", "create", "s-mark", "-r", "@"]),
    Step::Jj(&["new", "c-mark", "s-mark"]),
];

/// An `experimental-advance-branches.enabled-branches` pattern that does not parse (Story 9.49
/// closing run).
const BAD_PATTERN: &[Step] = &[Step::Jj(&[
    "config",
    "set",
    "--repo",
    "experimental-advance-branches.enabled-branches",
    "[\"glob:[\"]",
])];

/// [`ADVANCE_ALL`] plus `a-mark` on A, so `new B` advances it (Story 9.49 closing run).
const ADVANCE_ALL_A_MARK: &[Step] = &[
    Step::Jj(&[
        "config",
        "set",
        "--repo",
        "experimental-advance-branches.enabled-branches",
        "[\"*\"]",
    ]),
    Step::Jj(&["bookmark", "create", "a-mark", "-r", "@--"]),
];

/// [`ADVANCE_ALL`] plus a described sibling D (d.txt) of B on A as `@`: `new C D` is a merge
/// (Story 9.49 closing run).
const ADVANCE_ALL_SIBLING_D: &[Step] = &[
    Step::Jj(&[
        "config",
        "set",
        "--repo",
        "experimental-advance-branches.enabled-branches",
        "[\"*\"]",
    ]),
    Step::Jj(&["new", "@--", "-m", "D"]),
    Step::Write("d.txt", "d\n"),
];

/// A described sibling D (d.txt) of B on A as `@`, THEN [`BAD_PATTERN`] — a one-parent `new`
/// under it would be refused (Story 9.49 closing run).
const SIBLING_D_BAD_PATTERN: &[Step] = &[
    Step::Jj(&["new", "@--", "-m", "D"]),
    Step::Write("d.txt", "d\n"),
    Step::Jj(&[
        "config",
        "set",
        "--repo",
        "experimental-advance-branches.enabled-branches",
        "[\"glob:[\"]",
    ]),
];

/// `@` = C with a described child D that `immutable_heads()` makes immutable — so `@` is
/// immutable too, and `commit` (no rewritability guard) rewrites it while the finish leaves
/// the immutable D in place (Story 9.49).
const IMMUTABLE_WC_WITH_CHILD: &[Step] = &[
    Step::Jj(&["new", "-m", "D"]),
    Step::Jj(&["edit", "@-"]),
    Step::Jj(&[
        "config",
        "set",
        "--repo",
        "revset-aliases.\"immutable_heads()\"",
        "description(substring:\"D\")",
    ]),
];

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
                let result = repo.new_change(&[s.change("@")], &[], &[]);
                zanshin_outcome(repo, &result)
            },
            |_| args(&["new"]),
        ),
        Scenario {
            setup: &[Step::Jj(&["new", "@--", "-m", "D"]), Step::Write("d.txt", "d\n")],
            ..simple(
                "new_merge",
                |repo, _, s| {
                    let result = repo.new_change(&[s.change("C"), s.change("D")], &[], &[]);
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
                    let result = repo.new_change(&[s.change("C"), s.change("D")], &[], &[]);
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
            // M merges C and D, which both add c.txt with different content; `@` is M's empty
            // child, so `edit` checks out the conflicted M (Story 9.53: "There are unresolved
            // conflicts at these paths:").
            setup: &[
                Step::Jj(&["new", "@--", "-m", "D"]),
                Step::Write("c.txt", "c from D\n"),
                Step::Jj(&["new", "-m", "M", "description(substring:\"C\")", "@"]),
                Step::Jj(&["new"]),
            ],
            ..simple(
                "edit_conflicted_merge",
                |repo, _, s| {
                    let result = repo.edit(s.change("M"));
                    zanshin_outcome(repo, &result)
                },
                |s| vec!["edit".to_owned(), s.change_arg("M")],
            )
        },
        Scenario {
            // `@` is the conflicted M itself: rewriting it is a new commit, so the CLI warns
            // again (`Some(new) != old`, Story 9.53).
            setup: &[
                Step::Jj(&["new", "@--", "-m", "D"]),
                Step::Write("c.txt", "c from D\n"),
                Step::Jj(&["new", "-m", "M", "description(substring:\"C\")", "@"]),
            ],
            ..simple(
                "describe_conflicted_at",
                |repo, _, s| {
                    let result = repo.describe(s.change("@"), "M described\n");
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["describe", "-m", "M described"]),
            )
        },
        Scenario {
            // `@` is the conflicted M and stays where it is: no conflict warning (Story 9.53).
            setup: &[
                Step::Jj(&["new", "@--", "-m", "D"]),
                Step::Write("c.txt", "c from D\n"),
                Step::Jj(&["new", "-m", "M", "description(substring:\"C\")", "@"]),
            ],
            ..simple(
                "bookmark_create_on_conflicted_at",
                |repo, _, _| {
                    let result = repo.bookmark_create(&["feature".to_owned()], None);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["bookmark", "create", "feature"]),
            )
        },
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
        // ── Story 9.23: workspace add ────────────────────────────────────────
        Scenario {
            init: NO_COLOCATE,
            extra: Some(ws2_read_back),
            ..simple(
                "workspace_add_default",
                |repo, _, _| add_outcome(repo, None, &[], &[], None, SparseInheritance::Copy),
                |_| args(&["workspace", "add", "../ws2"]),
            )
        },
        Scenario {
            init: NO_COLOCATE,
            extra: Some(ws2_read_back),
            ..simple(
                "workspace_add_name_revisions_message",
                |repo, _, s| {
                    let revisions = [s.change_arg("A"), format!("b-mark|{}", s.change_arg("A"))];
                    let paragraphs = ["T".to_owned(), "U".to_owned()];
                    add_outcome(repo, Some("x"), &revisions, &paragraphs, None, SparseInheritance::Copy)
                },
                |s| {
                    let mut argv = args(&["workspace", "add", "../ws2", "--name", "x", "-r"]);
                    argv.extend([
                        s.change_arg("A"),
                        "-r".to_owned(),
                        format!("b-mark|{}", s.change_arg("A")),
                    ]);
                    argv.extend(args(&["-m", "T", "-m", "U"]));
                    argv
                },
            )
        },
        Scenario {
            init: NO_COLOCATE,
            extra: Some(ws2_read_back),
            ..simple(
                "workspace_add_sparse_empty",
                |repo, _, _| add_outcome(repo, None, &[], &[], None, SparseInheritance::Empty),
                |_| args(&["workspace", "add", "../ws2", "--sparse-patterns", "empty"]),
            )
        },
        Scenario {
            extra: Some(ws2_read_back),
            ..simple(
                "workspace_add_colocated",
                |repo, _, _| add_outcome(repo, None, &[], &[], None, SparseInheritance::Copy),
                |_| args(&["workspace", "add", "../ws2"]),
            )
        },
        Scenario {
            extra: Some(ws2_read_back),
            ..simple(
                "workspace_add_no_colocate",
                |repo, _, _| add_outcome(repo, None, &[], &[], Some(false), SparseInheritance::Copy),
                |_| args(&["workspace", "add", "../ws2", "--no-colocate"]),
            )
        },
        // ── Story 9.23: workspace update-stale and the auto arm ──────────────
        Scenario {
            init: NO_COLOCATE,
            setup: STALE_FROM_WS2,
            extra: Some(wc_op_read_back),
            ..simple("update_stale_clean", update_stale, |_| {
                args(&["workspace", "update-stale"])
            })
        },
        Scenario {
            init: NO_COLOCATE,
            extra: Some(wc_op_read_back),
            ..simple("update_stale_not_stale", update_stale, |_| {
                args(&["workspace", "update-stale"])
            })
        },
        Scenario {
            init: NO_COLOCATE,
            setup: STALE_FROM_WS2,
            files: &[("d.txt", "dirty\n")],
            extra: Some(wc_op_read_back),
            ..simple("update_stale_dirty", update_stale, |_| {
                args(&["workspace", "update-stale"])
            })
        },
        Scenario {
            // `default@`'s first parent moves to root, so Git HEAD must be reset first.
            setup: &[
                Step::Jj(&["workspace", "add", "../ws2"]),
                Step::JjAt("../ws2", &["rebase", "-r", "default@", "-o", "root()"]),
            ],
            extra: Some(wc_op_read_back),
            ..simple("update_stale_colocated", update_stale, |_| {
                args(&["workspace", "update-stale"])
            })
        },
        Scenario {
            init: NO_COLOCATE,
            setup: &[
                Step::Jj(&["config", "set", "--repo", "snapshot.auto-update-stale", "true"]),
                Step::Jj(&["workspace", "add", "../ws2"]),
                Step::JjAt("../ws2", &["restore", "--into", "default@"]),
            ],
            extra: Some(wc_op_read_back),
            ..simple(
                "auto_update_stale_snapshot",
                |repo, _, _| {
                    let result = repo.snapshot();
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["util", "snapshot"]),
            )
        },
        // ── Story 9.15: squash ───────────────────────────────────────────────
        Scenario {
            setup: EDITOR,
            ..simple(
                "squash_wc_into_parent",
                |repo, _, _| squash_outcome(repo, &SquashOptions::default()),
                |_| args(&["squash"]),
            )
        },
        Scenario {
            setup: EDITOR,
            ..simple(
                "squash_revision",
                |repo, _, s| {
                    let options = SquashOptions {
                        revision: Some(s.change("B")),
                        ..SquashOptions::default()
                    };
                    squash_outcome(repo, &options)
                },
                |s| vec!["squash".to_owned(), "-r".to_owned(), s.change_arg("B")],
            )
        },
        Scenario {
            setup: &[Step::Jj(&["new", "-m", "M", "@-", "@--"])],
            ..simple(
                "squash_merge_refused",
                |repo, _, _| squash_outcome(repo, &SquashOptions::default()),
                |_| args(&["squash"]),
            )
        },
        Scenario {
            setup: EDITOR,
            ..simple(
                "squash_from_into",
                |repo, _, s| {
                    let options = SquashOptions {
                        from: vec![s.change("C")],
                        into: Some(s.change("A")),
                        ..SquashOptions::default()
                    };
                    squash_outcome(repo, &options)
                },
                |s| {
                    vec![
                        "squash".to_owned(),
                        "--from".to_owned(),
                        s.change_arg("C"),
                        "--into".to_owned(),
                        s.change_arg("A"),
                    ]
                },
            )
        },
        simple(
            "squash_into_wc_noop",
            |repo, _, s| {
                let options = SquashOptions {
                    into: Some(s.change("@")),
                    ..SquashOptions::default()
                };
                squash_outcome(repo, &options)
            },
            |_| args(&["squash", "--into", "@"]),
        ),
        Scenario {
            setup: C2,
            ..simple(
                "squash_path_with_revision",
                |repo, _, s| {
                    let options = SquashOptions {
                        revision: Some(s.change("C")),
                        paths: vec!["c.txt".to_owned()],
                        ..SquashOptions::default()
                    };
                    squash_outcome(repo, &options)
                },
                |s| {
                    vec![
                        "squash".to_owned(),
                        "-r".to_owned(),
                        s.change_arg("C"),
                        "c.txt".to_owned(),
                    ]
                },
            )
        },
        Scenario {
            setup: EDITOR,
            ..simple(
                "squash_keep_emptied",
                |repo, _, _| {
                    let options = SquashOptions {
                        keep_emptied: true,
                        ..SquashOptions::default()
                    };
                    squash_outcome(repo, &options)
                },
                |_| args(&["squash", "-k"]),
            )
        },
        simple(
            "squash_use_destination_message",
            |repo, _, _| {
                let options = SquashOptions {
                    use_destination_message: true,
                    ..SquashOptions::default()
                };
                squash_outcome(repo, &options)
            },
            |_| args(&["squash", "-u"]),
        ),
        simple(
            "squash_message",
            |repo, _, _| {
                let options = SquashOptions {
                    message: Some(vec!["T".to_owned(), "U".to_owned()]),
                    ..SquashOptions::default()
                };
                squash_outcome(repo, &options)
            },
            |_| args(&["squash", "-m", "T", "-m", "U"]),
        ),
        Scenario {
            // The plan's text passed back as `-m` against the CLI's editor saved unchanged.
            setup: EDITOR,
            ..simple(
                "squash_plan_as_message",
                |repo, _, _| {
                    let plan = repo.squash_plan(&SquashOptions::default()).expect("plan");
                    let _ = repo.take_warnings();
                    // WHY `expect`: without the plan's text the verb would write the same
                    // combined description, and the scenario would pass on a `None` plan.
                    let text = plan.combined_description.expect("the plan names the editor text");
                    let options = SquashOptions {
                        message: Some(vec![text]),
                        ..SquashOptions::default()
                    };
                    squash_outcome(repo, &options)
                },
                |_| args(&["squash"]),
            )
        },
        Scenario {
            // Into a DESCENDANT: jj-lib rebases the destination onto the rewritten source first.
            setup: EDITOR,
            ..simple(
                "squash_from_into_descendant",
                |repo, _, s| {
                    let options = SquashOptions {
                        from: vec![s.change("B")],
                        into: Some(s.change("C")),
                        ..SquashOptions::default()
                    };
                    squash_outcome(repo, &options)
                },
                |s| {
                    vec![
                        "squash".to_owned(),
                        "--from".to_owned(),
                        s.change_arg("B"),
                        "--into".to_owned(),
                        s.change_arg("C"),
                    ]
                },
            )
        },
        Scenario {
            // Two sources given oldest first: the CLI combines them in revset order, reversed.
            setup: EDITOR,
            ..simple(
                "squash_from_two_into",
                |repo, _, s| {
                    let options = SquashOptions {
                        from: vec![s.change("B"), s.change("C")],
                        into: Some(s.change("A")),
                        ..SquashOptions::default()
                    };
                    squash_outcome(repo, &options)
                },
                |s| {
                    vec![
                        "squash".to_owned(),
                        "--from".to_owned(),
                        s.change_arg("B"),
                        "--from".to_owned(),
                        s.change_arg("C"),
                        "--into".to_owned(),
                        s.change_arg("A"),
                    ]
                },
            )
        },
        Scenario {
            // 10.27's "Move into this change": one path of C into A; C keeps c2.txt.
            setup: C2,
            ..simple(
                "squash_from_into_path",
                |repo, _, s| {
                    let options = SquashOptions {
                        from: vec![s.change("C")],
                        into: Some(s.change("A")),
                        paths: vec!["c.txt".to_owned()],
                        ..SquashOptions::default()
                    };
                    squash_outcome(repo, &options)
                },
                |s| {
                    vec![
                        "squash".to_owned(),
                        "--from".to_owned(),
                        s.change_arg("C"),
                        "--into".to_owned(),
                        s.change_arg("A"),
                        "c.txt".to_owned(),
                    ]
                },
            )
        },
        // ── Story 9.15: split ────────────────────────────────────────────────
        Scenario {
            setup: C2,
            ..simple(
                "split_paths_message",
                |repo, _, _| split_outcome(repo, &split_first(&["c.txt"])),
                |_| args(&["split", "-m", "first", "c.txt"]),
            )
        },
        Scenario {
            setup: C2_EDITOR,
            ..simple(
                "split_paths_editor",
                |repo, _, _| {
                    let options = SplitOptions {
                        message: None,
                        ..split_first(&["c.txt"])
                    };
                    split_outcome(repo, &options)
                },
                |_| args(&["split", "c.txt"]),
            )
        },
        Scenario {
            setup: C2,
            ..simple(
                "split_all_selected",
                |repo, _, _| split_outcome(repo, &split_first(&["c.txt", "c2.txt"])),
                |_| args(&["split", "-m", "first", "c.txt", "c2.txt"]),
            )
        },
        Scenario {
            setup: C2,
            ..simple(
                "split_none_selected",
                |repo, _, _| split_outcome(repo, &split_first(&["nope.txt"])),
                |_| args(&["split", "-m", "first", "nope.txt"]),
            )
        },
        Scenario {
            setup: &[
                Step::Write("c2.txt", "c2\n"),
                Step::Jj(&["util", "snapshot"]),
                Step::Jj(&["new", "-m", "D"]),
            ],
            ..simple(
                "split_parallel",
                |repo, _, s| {
                    let options = SplitOptions {
                        revision: Some(s.change("C")),
                        parallel: true,
                        ..split_first(&["c.txt"])
                    };
                    split_outcome(repo, &options)
                },
                |s| {
                    let mut argv = args(&["split", "-m", "first", "--parallel", "-r"]);
                    argv.extend([s.change_arg("C"), "c.txt".to_owned()]);
                    argv
                },
            )
        },
        Scenario {
            setup: C2,
            ..simple(
                "split_insert_after",
                |repo, _, s| {
                    let options = SplitOptions {
                        insert_after: Some(vec![s.change("A")]),
                        ..split_first(&["c.txt"])
                    };
                    split_outcome(repo, &options)
                },
                |s| {
                    let mut argv = args(&["split", "-m", "first", "-A"]);
                    argv.extend([s.change_arg("A"), "c.txt".to_owned()]);
                    argv
                },
            )
        },
        Scenario {
            setup: C2,
            ..simple(
                "split_insert_before",
                |repo, _, s| {
                    let options = SplitOptions {
                        insert_before: Some(vec![s.change("B")]),
                        ..split_first(&["c.txt"])
                    };
                    split_outcome(repo, &options)
                },
                |s| {
                    let mut argv = args(&["split", "-m", "first", "-B"]);
                    argv.extend([s.change_arg("B"), "c.txt".to_owned()]);
                    argv
                },
            )
        },
        Scenario {
            setup: C2,
            ..simple(
                "split_onto",
                |repo, _, s| {
                    let options = SplitOptions {
                        onto: Some(vec![s.change("A")]),
                        ..split_first(&["c.txt"])
                    };
                    split_outcome(repo, &options)
                },
                |s| {
                    let mut argv = args(&["split", "-m", "first", "-o"]);
                    argv.extend([s.change_arg("A"), "c.txt".to_owned()]);
                    argv
                },
            )
        },
        Scenario {
            setup: &[
                Step::Write("c2.txt", "c2\n"),
                Step::Jj(&["util", "snapshot"]),
                Step::Jj(&["bookmark", "create", "c-mark"]),
                Step::Jj(&["config", "set", "--repo", "split.legacy-bookmark-behavior", "false"]),
            ],
            ..simple(
                "split_legacy_bookmarks_off",
                |repo, _, _| split_outcome(repo, &split_first(&["c.txt"])),
                |_| args(&["split", "-m", "first", "c.txt"]),
            )
        },
        Scenario {
            setup: &[
                Step::Write("c2.txt", "c2\n"),
                Step::Jj(&["util", "snapshot"]),
                Step::Jj(&["bookmark", "create", "c-mark"]),
            ],
            ..simple(
                "split_parallel_bookmark",
                |repo, _, _| split_outcome(repo, &split_parallel()),
                |_| args(&["split", "-m", "first", "--parallel", "c.txt"]),
            )
        },
        Scenario {
            setup: &[
                Step::Write("c2.txt", "c2\n"),
                Step::Jj(&["util", "snapshot"]),
                Step::Jj(&["bookmark", "create", "c-mark"]),
                Step::Jj(&["config", "set", "--repo", "split.legacy-bookmark-behavior", "false"]),
            ],
            ..simple(
                "split_parallel_bookmark_legacy_off",
                |repo, _, _| split_outcome(repo, &split_parallel()),
                |_| args(&["split", "-m", "first", "--parallel", "c.txt"]),
            )
        },
        // ── Story 9.49: commit ───────────────────────────────────────────────
        simple(
            "commit_everything",
            |repo, _, _| commit_outcome(repo, &[], &["first"]),
            |_| args(&["commit", "-m", "first"]),
        ),
        Scenario {
            files: &[("x.txt", "x\n"), ("y.txt", "y\n"), ("z.txt", "z\n")],
            ..simple(
                "commit_two_of_three_paths",
                |repo, _, _| commit_outcome(repo, &["x.txt", "y.txt"], &["first"]),
                |_| args(&["commit", "-m", "first", "x.txt", "y.txt"]),
            )
        },
        Scenario {
            setup: &[Step::Jj(&["new"])],
            ..simple(
                "commit_empty_wc_empty_message",
                |repo, _, _| commit_outcome(repo, &[], &[""]),
                |_| args(&["commit", "-m", ""]),
            )
        },
        simple(
            "commit_unmatched_path",
            |repo, _, _| commit_outcome(repo, &["nope.txt"], &["first"]),
            |_| args(&["commit", "-m", "first", "nope.txt"]),
        ),
        simple(
            "commit_unchanged_path",
            |repo, _, _| commit_outcome(repo, &["a.txt"], &["first"]),
            |_| args(&["commit", "-m", "first", "a.txt"]),
        ),
        Scenario {
            setup: &[Step::Jj(&["bookmark", "create", "c-mark"])],
            ..simple(
                "commit_bookmark_on_wc",
                |repo, _, _| commit_outcome(repo, &[], &["first"]),
                |_| args(&["commit", "-m", "first"]),
            )
        },
        Scenario {
            setup: ADVANCE_ALL,
            ..simple(
                "commit_advance_bookmarks",
                |repo, _, _| commit_outcome(repo, &[], &["first"]),
                |_| args(&["commit", "-m", "first"]),
            )
        },
        Scenario {
            setup: ADVANCE_ALL_BUT_B_MARK,
            ..simple(
                "commit_advance_bookmarks_disabled",
                |repo, _, _| commit_outcome(repo, &[], &["first"]),
                |_| args(&["commit", "-m", "first"]),
            )
        },
        Scenario {
            // A described child, so `edit @-` keeps it.
            setup: &[Step::Jj(&["new", "-m", "D"]), Step::Jj(&["edit", "@-"])],
            ..simple(
                "commit_wc_with_child",
                |repo, _, _| commit_outcome(repo, &[], &["first"]),
                |_| args(&["commit", "-m", "first"]),
            )
        },
        Scenario {
            init: NO_COLOCATE,
            setup: &[
                Step::Jj(&["workspace", "add", "../ws2"]),
                Step::JjAt("../ws2", &["edit", "default@"]),
            ],
            ..simple(
                "commit_two_workspaces_on_wc",
                |repo, _, _| commit_outcome(repo, &[], &["first"]),
                |_| args(&["commit", "-m", "first"]),
            )
        },
        Scenario {
            setup: &[Step::Jj(&["workspace", "forget"])],
            ..simple(
                "commit_without_working_copy",
                |repo, _, _| commit_outcome(repo, &[], &["first"]),
                |_| args(&["commit", "-m", "first"]),
            )
        },
        Scenario {
            setup: &[Step::Jj(&[
                "config",
                "set",
                "--repo",
                "templates.commit_trailers",
                "format_signed_off_by_trailer(self)",
            ])],
            ..simple(
                "commit_trailers",
                |repo, _, _| commit_outcome(repo, &[], &["T"]),
                |_| args(&["commit", "-m", "T"]),
            )
        },
        Scenario {
            setup: ADVANCE_MERGE,
            files: &[("m.txt", "m\n")],
            ..simple(
                "commit_advance_merge_parents",
                |repo, _, _| commit_outcome(repo, &["m.txt"], &["merge"]),
                |_| args(&["commit", "-m", "merge", "m.txt"]),
            )
        },
        Scenario {
            setup: IMMUTABLE_WC_WITH_CHILD,
            ..simple(
                "commit_immutable_wc_with_child",
                |repo, _, _| commit_outcome(repo, &[], &["first"]),
                |_| args(&["commit", "-m", "first"]),
            )
        },
        simple(
            "commit_path_outside_repo",
            |repo, _, _| commit_outcome(repo, &["/x"], &["first"]),
            |_| args(&["commit", "-m", "first", "/x"]),
        ),
        Scenario {
            setup: &[Step::Jj(&[
                "config",
                "set",
                "--repo",
                "experimental-advance-branches.enabled-branches",
                "[\"glob:[\"]",
            ])],
            ..simple(
                "commit_advance_bad_pattern",
                |repo, _, _| commit_outcome(repo, &[], &["first"]),
                |_| args(&["commit", "-m", "first"]),
            )
        },
        Scenario {
            setup: &[Step::Jj(&[
                "config",
                "set",
                "--repo",
                "experimental-advance-branches.enabled-branches",
                "\"*\"",
            ])],
            ..simple(
                "commit_advance_not_a_list",
                |repo, _, _| commit_outcome(repo, &[], &["first"]),
                |_| args(&["commit", "-m", "first"]),
            )
        },
        // ── Story 9.49 closing run: `new` advances bookmarks ────────────────────────
        Scenario {
            setup: ADVANCE_ALL,
            ..simple(
                "new_advance_bookmarks",
                |repo, _, s| {
                    let result = repo.new_change(&[s.change("@")], &[], &[]);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["new"]),
            )
        },
        Scenario {
            setup: ADVANCE_ALL_BUT_B_MARK,
            ..simple(
                "new_advance_bookmarks_disabled",
                |repo, _, s| {
                    let result = repo.new_change(&[s.change("@")], &[], &[]);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["new"]),
            )
        },
        Scenario {
            setup: ADVANCE_ALL_A_MARK,
            ..simple(
                "new_advance_interior",
                |repo, _, s| {
                    let result = repo.new_change(&[s.change("B")], &[], &[]);
                    zanshin_outcome(repo, &result)
                },
                |s| vec!["new".to_owned(), s.change_arg("B")],
            )
        },
        Scenario {
            setup: ADVANCE_ALL_SIBLING_D,
            ..simple(
                "new_merge_advance_none",
                |repo, _, s| {
                    let result = repo.new_change(&[s.change("C"), s.change("D")], &[], &[]);
                    zanshin_outcome(repo, &result)
                },
                |s| vec!["new".to_owned(), s.change_arg("C"), s.change_arg("D")],
            )
        },
        Scenario {
            setup: BAD_PATTERN,
            ..simple(
                "new_advance_bad_pattern",
                |repo, _, s| {
                    let result = repo.new_change(&[s.change("@")], &[], &[]);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["new"]),
            )
        },
        Scenario {
            setup: SIBLING_D_BAD_PATTERN,
            ..simple(
                "new_merge_ignores_bad_pattern",
                |repo, _, s| {
                    let result = repo.new_change(&[s.change("C"), s.change("D")], &[], &[]);
                    zanshin_outcome(repo, &result)
                },
                |s| vec!["new".to_owned(), s.change_arg("C"), s.change_arg("D")],
            )
        },
        // ── Story 9.48: `new -A` / `-B`, parents deduplicated ────────────────────────
        Scenario {
            // S on B, as `@`: B has the two children C and S.
            setup: &[Step::Jj(&["new", "-m", "S", "b-mark"])],
            ..simple(
                "new_insert_after_two_children",
                |repo, _, s| {
                    let result = repo.new_change(&[], &[s.change("B")], &[]);
                    zanshin_outcome(repo, &result)
                },
                |s| vec!["new".to_owned(), "-A".to_owned(), s.change_arg("B")],
            )
        },
        simple(
            "new_insert_before",
            |repo, _, s| {
                let result = repo.new_change(&[], &[], &[s.change("C")]);
                zanshin_outcome(repo, &result)
            },
            |s| vec!["new".to_owned(), "-B".to_owned(), s.change_arg("C")],
        ),
        Scenario {
            // `@` an empty, undescribed child of C — the GUI's common `-B @`.
            setup: &[Step::Jj(&["new"])],
            ..simple(
                "new_insert_before_empty_wc",
                |repo, _, s| {
                    let result = repo.new_change(&[], &[], &[s.change("@")]);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["new", "-B", "@"]),
            )
        },
        Scenario {
            setup: &[Step::Jj(&["new", "-m", "D"])],
            ..simple(
                "new_insert_after_and_before",
                |repo, _, s| {
                    let result = repo.new_change(&[], &[s.change("A")], &[s.change("D")]);
                    zanshin_outcome(repo, &result)
                },
                |s| {
                    vec![
                        "new".to_owned(),
                        "-A".to_owned(),
                        s.change_arg("A"),
                        "-B".to_owned(),
                        s.change_arg("D"),
                    ]
                },
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
                "new_insert_after_immutable_child",
                |repo, _, s| {
                    let result = repo.new_change(&[], &[s.change("A")], &[]);
                    zanshin_outcome(repo, &result)
                },
                |s| vec!["new".to_owned(), "-A".to_owned(), s.change_arg("A")],
            )
        },
        Scenario {
            setup: ADVANCE_ALL_A_MARK,
            ..simple(
                "new_insert_after_no_advance",
                |repo, _, s| {
                    let result = repo.new_change(&[], &[s.change("B")], &[]);
                    zanshin_outcome(repo, &result)
                },
                |s| vec!["new".to_owned(), "-A".to_owned(), s.change_arg("B")],
            )
        },
        simple(
            "new_insert_loop",
            |repo, _, s| {
                let result = repo.new_change(&[], &[s.change("C")], &[s.change("A")]);
                zanshin_outcome(repo, &result)
            },
            |s| {
                vec![
                    "new".to_owned(),
                    "-A".to_owned(),
                    s.change_arg("C"),
                    "-B".to_owned(),
                    s.change_arg("A"),
                ]
            },
        ),
        Scenario {
            setup: ADVANCE_ALL,
            ..simple(
                "new_duplicate_parents",
                |repo, _, s| {
                    let result = repo.new_change(&[s.change("C"), s.change("C")], &[], &[]);
                    zanshin_outcome(repo, &result)
                },
                |s| vec!["new".to_owned(), s.change_arg("C"), s.change_arg("C")],
            )
        },
        // ── Story 9.49 closing run: `.`/`..` in path prefixes ────────────────────────
        simple(
            "commit_path_escapes_repo",
            |repo, _, _| commit_outcome(repo, &["../x"], &["first"]),
            |_| args(&["commit", "-m", "first", "../x"]),
        ),
        simple(
            "restore_path_escapes_repo",
            |repo, _, _| {
                let result = repo.restore(None, None, None, &["../x".to_owned()], false);
                zanshin_outcome(repo, &result)
            },
            |_| args(&["restore", "../x"]),
        ),
        Scenario {
            setup: EDITOR,
            ..simple(
                "squash_path_escapes_repo",
                |repo, _, _| {
                    let options = SquashOptions {
                        paths: vec!["../x".to_owned()],
                        ..SquashOptions::default()
                    };
                    squash_outcome(repo, &options)
                },
                |_| args(&["squash", "../x"]),
            )
        },
        simple(
            "split_path_escapes_repo",
            |repo, _, _| split_outcome(repo, &split_first(&["../x"])),
            |_| args(&["split", "-m", "first", "../x"]),
        ),
        simple(
            "absorb_path_escapes_repo",
            |repo, _, _| {
                let result = repo.absorb(None, None, &["../x".to_owned()]);
                zanshin_outcome(repo, &result)
            },
            |_| args(&["absorb", "../x"]),
        ),
        Scenario {
            files: &[("x.txt", "x\n"), ("y.txt", "y\n"), ("z.txt", "z\n")],
            ..simple(
                "commit_path_dot_components",
                |repo, _, _| commit_outcome(repo, &["./x.txt", "q/../y.txt"], &["first"]),
                |_| args(&["commit", "-m", "first", "./x.txt", "q/../y.txt"]),
            )
        },
        // ── Story 9.51: templates ────────────────────────────────────────────
        Scenario {
            setup: TRAILERS,
            ..simple(
                "describe_empty_trailers",
                |repo, _, s| {
                    let result = repo.describe(s.change("@"), "");
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["describe", "-m", ""]),
            )
        },
        Scenario {
            setup: BROKEN_TRAILERS,
            ..simple(
                "describe_broken_template",
                |repo, _, s| {
                    let result = repo.describe(s.change("@"), "T\n");
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["describe", "-m", "T"]),
            )
        },
        Scenario {
            setup: NEW_DESCRIPTION,
            ..simple(
                "new_description",
                |repo, _, s| {
                    let result = repo.new_change(&[s.change("@")], &[], &[]);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["new"]),
            )
        },
        Scenario {
            setup: NEW_DESCRIPTION_TRAILERS,
            ..simple(
                "new_description_trailers",
                |repo, _, s| {
                    let result = repo.new_change(&[s.change("@")], &[], &[]);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["new"]),
            )
        },
        Scenario {
            init: NO_COLOCATE,
            setup: TRAILERS,
            extra: Some(ws2_read_back),
            ..simple(
                "workspace_add_trailers",
                |repo, _, _| add_outcome(repo, None, &[], &["W".to_owned()], None, SparseInheritance::Copy),
                |_| args(&["workspace", "add", "../ws2", "-m", "W"]),
            )
        },
        Scenario {
            setup: TRAILERS,
            ..simple(
                "squash_message_trailers",
                |repo, _, _| {
                    let options = SquashOptions {
                        message: Some(vec!["S".to_owned()]),
                        ..SquashOptions::default()
                    };
                    squash_outcome(repo, &options)
                },
                |_| args(&["squash", "-m", "S"]),
            )
        },
        Scenario {
            setup: TRAILERS_EDITOR,
            ..simple(
                "squash_editor_trailers",
                |repo, _, _| squash_outcome(repo, &SquashOptions::default()),
                |_| args(&["squash"]),
            )
        },
        Scenario {
            setup: CUSTOM_DRAFT_EDITOR,
            ..simple(
                "squash_custom_draft",
                |repo, _, _| squash_outcome(repo, &SquashOptions::default()),
                |_| args(&["squash"]),
            )
        },
        Scenario {
            // The plan's text passed back as `-m` against the CLI's editor saved unchanged.
            setup: CUSTOM_DRAFT_EDITOR,
            ..simple(
                "squash_plan_custom_draft_as_message",
                |repo, _, _| {
                    let plan = repo.squash_plan(&SquashOptions::default()).expect("plan");
                    let _ = repo.take_warnings();
                    // WHY `expect`: without the plan's text the verb would write the same
                    // description, and the scenario would pass on a `None` plan.
                    let text = plan.combined_description.expect("the plan names the editor text");
                    let options = SquashOptions {
                        message: Some(vec![text]),
                        ..SquashOptions::default()
                    };
                    squash_outcome(repo, &options)
                },
                |_| args(&["squash"]),
            )
        },
        Scenario {
            setup: C2_TRAILERS,
            ..simple(
                "split_message_trailers",
                |repo, _, _| split_outcome(repo, &split_first(&["c.txt"])),
                |_| args(&["split", "-m", "first", "c.txt"]),
            )
        },
        Scenario {
            setup: C2_EDITOR_TRAILERS,
            ..simple(
                "split_editor_trailers",
                |repo, _, _| {
                    let options = SplitOptions {
                        message: None,
                        ..split_first(&["c.txt"])
                    };
                    split_outcome(repo, &options)
                },
                |_| args(&["split", "c.txt"]),
            )
        },
        Scenario {
            setup: UNDESCRIBED_DEFAULT_DESCRIPTION_EDITOR,
            ..simple(
                "split_editor_default_description",
                |repo, _, _| {
                    let options = SplitOptions {
                        message: None,
                        ..split_first(&["x.txt"])
                    };
                    split_outcome(repo, &options)
                },
                |_| args(&["split", "x.txt"]),
            )
        },
    ]
    .into_iter()
    .chain(crate::git_scenarios::push_scenarios())
    .collect()
}
