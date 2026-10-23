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
use zanshin_jj::BookmarkMoveOptions;
use zanshin_jj::CommitOptions;
use zanshin_jj::ConfigScope;
use zanshin_jj::ConfigTarget;
use zanshin_jj::DuplicateOptions;
use zanshin_jj::FixOptions;
use zanshin_jj::MetaeditOptions;
use zanshin_jj::RebaseOptions;
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

/// An `immutable_heads()` alias naming no revision: it parses, but does not resolve (Story 9.56).
const UNRESOLVABLE_IMMUTABLE: &[Step] = &[Step::Jj(&[
    "config",
    "set",
    "--repo",
    "revset-aliases.'immutable_heads()'",
    "nonexistent_symbol_xyz",
])];

/// A `trunk()` alias naming a remote bookmark that does not exist: the start-up fallback sets it
/// to `root()` for the call, with a warning (Story 9.56).
const UNRESOLVABLE_TRUNK: &[Step] = &[Step::Jj(&[
    "config",
    "set",
    "--repo",
    "revset-aliases.'trunk()'",
    "main@origin",
])];

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

/// A `template-aliases` that is not a table (Story 9.51 closing run) — refused at the start-up
/// environment of every workspace command.
const BROKEN_TEMPLATE_ALIASES: &[Step] = &[Step::Jj(&["config", "set", "--repo", "template-aliases", "1"])];

/// A `revsets.short-prefixes` that does not parse (Story 9.51 closing run) — refused at the
/// start-up environment of every workspace command.
const BROKEN_SHORT_PREFIXES: &[Step] = &[Step::Jj(&["config", "set", "--repo", "revsets.short-prefixes", "("])];

/// A `[template-aliases]` entry whose declaration does not parse (Story 9.51 closing run) — warned
/// about, once, at the start-up environment of every workspace command.
const BAD_TEMPLATE_ALIAS_ENTRY: &[Step] = &[Step::Jj(&["config", "set", "--repo", "template-aliases.'x('", "'1'"])];

/// A `revsets.short-prefixes` with a parse diagnostic (`diff_contains` is deprecated; Story 9.51
/// closing run) — warned about, once, at the start-up environment of every workspace command.
const DIAGNOSED_SHORT_PREFIXES: &[Step] = &[Step::Jj(&[
    "config",
    "set",
    "--repo",
    "revsets.short-prefixes",
    "diff_contains(\"x\")",
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

/// `ui.editor` = a script deleting every `Signed-off-by` line of the buffer (Story 9.54) — the
/// CLI's editor run by a user who deletes the trailer; the bulk editor's `JJ: describe` headers
/// stay, so no hidden-commit hash need be known.
const DELETE_TRAILER_EDITOR_STEP: Step = Step::Jj(&[
    "config",
    "set",
    "--repo",
    "ui.editor",
    r#"["sh", "-c", "grep -v Signed-off-by \"$1\" > \"$1.t\"; mv \"$1.t\" \"$1\"", "sh", "$path"]"#,
]);

/// [`TRAILERS_STEP`] plus [`DELETE_TRAILER_EDITOR_STEP`].
const TRAILERS_DELETE_TRAILER_EDITOR: &[Step] = &[TRAILERS_STEP, DELETE_TRAILER_EDITOR_STEP];

/// `ui.editor` = a script that saves exactly `E` (Story 9.54 review) — the CLI's editor run by a
/// user who replaces the whole buffer.
const WRITE_E_EDITOR_STEP: Step = Step::Jj(&[
    "config",
    "set",
    "--repo",
    "ui.editor",
    r#"["sh", "-c", "echo E > \"$1\"", "sh", "$path"]"#,
]);

/// [`TRAILERS_STEP`] plus [`WRITE_E_EDITOR_STEP`].
const TRAILERS_WRITE_E_EDITOR: &[Step] = &[TRAILERS_STEP, WRITE_E_EDITOR_STEP];

/// B and C undescribed, [`TRAILERS_STEP`] and [`WRITE_E_EDITOR_STEP`] (Story 9.54 review).
const UNDESCRIBED_B_C_TRAILERS_WRITE_E_EDITOR: &[Step] = &[
    Step::Jj(&["describe", "-m", ""]),
    Step::Jj(&["describe", "-r", "@-", "-m", ""]),
    TRAILERS_STEP,
    WRITE_E_EDITOR_STEP,
];

/// [`C2_TRAILERS`] plus [`DELETE_TRAILER_EDITOR_STEP`].
const C2_DELETE_TRAILER_EDITOR_TRAILERS: &[Step] = &[
    Step::Write("c2.txt", "c2\n"),
    Step::Jj(&["util", "snapshot"]),
    DELETE_TRAILER_EDITOR_STEP,
    TRAILERS_STEP,
];

/// The pinned identity's `format_signed_off_by_trailer(self)` (`test_helpers::TEST_ENV`).
const SOB: &str = "Signed-off-by: Zanshin <zanshin@localhost>";

/// `templates.new_description = 'config("ui.color")'` (Story 9.54) — a jj-cli default no verb
/// reads, rendered through a template's `config()`.
const NEW_DESCRIPTION_CONFIG_UI_COLOR: &[Step] = &[Step::Jj(&[
    "config",
    "set",
    "--repo",
    "templates.new_description",
    "'config(\"ui.color\")'",
])];

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

/// `C` undescribed, then [`TRAILERS_STEP`]: squashing `@` into B leaves ONE non-empty description
/// (Story 9.51 review).
const UNDESCRIBED_C_TRAILERS: &[Step] = &[Step::Jj(&["describe", "-m", ""]), TRAILERS_STEP];

/// An undescribed `@` on C holding `x.txt` and `y.txt`, [`TRAILERS_STEP`] and [`EDITOR_STEP`]
/// (Story 9.51 review).
const UNDESCRIBED_TRAILERS_EDITOR: &[Step] = &[
    Step::Jj(&["new"]),
    Step::Write("x.txt", "x\n"),
    Step::Write("y.txt", "y\n"),
    Step::Jj(&["util", "snapshot"]),
    TRAILERS_STEP,
    EDITOR_STEP,
];

/// A `templates.commit_trailers` built from the template ENVIRONMENT — the immutable set and the
/// working copy (Story 9.51 review).
const ENVIRONMENT_TRAILERS: &[Step] = &[Step::Jj(&[
    "config",
    "set",
    "--repo",
    "templates.commit_trailers",
    "concat(\"Imm: \", if(immutable, \"y\", \"n\"), \"\\nWc: \", if(current_working_copy, \"y\", \"n\"), \"\\n\")",
])];

/// A `templates.draft_commit_description` that does not parse, plus [`EDITOR_STEP`] (Story 9.51
/// review).
const BROKEN_DRAFT_EDITOR: &[Step] = &[
    Step::Jj(&["config", "set", "--repo", "templates.draft_commit_description", "nope("]),
    EDITOR_STEP,
];

/// `Repo::squash` with `options`.
fn squash_outcome(repo: &mut zanshin_jj::Repo, options: &SquashOptions) -> Outcome {
    let result = repo.squash(options);
    zanshin_outcome(repo, &result)
}

/// `squash_plan`'s text through `edit`, sent back as the edited description (Story 9.54).
fn squash_plan_edited(repo: &mut zanshin_jj::Repo, edit: fn(&str) -> String) -> Outcome {
    let plan = repo.squash_plan(&SquashOptions::default()).expect("plan");
    let _ = repo.take_warnings();
    // WHY `expect`: without the plan's text the scenario would not test the round trip.
    let text = plan.combined_description.expect("the plan names the editor text");
    let options = SquashOptions {
        edited_description: Some(edit(&text)),
        ..SquashOptions::default()
    };
    squash_outcome(repo, &options)
}

/// `split c.txt` with both edited descriptions set to `text` (Story 9.54).
fn split_edited(repo: &mut zanshin_jj::Repo, text: &str) -> Outcome {
    let options = SplitOptions {
        message: None,
        edited_selected_description: Some(text.to_owned()),
        edited_remaining_description: Some(text.to_owned()),
        ..split_first(&["c.txt"])
    };
    split_outcome(repo, &options)
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
        // Story 9.56: the shared finish resolves the immutable set for every write with changes,
        // as the CLI's `tx.finish` does — so verbs without a rewritability guard refuse an
        // unresolvable alias too, with no operation.
        Scenario {
            setup: UNRESOLVABLE_IMMUTABLE,
            ..simple(
                "new_unresolvable_immutable",
                |repo, _, s| {
                    let result = repo.new_change(&[s.change("@")], &[], &[]);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["new"]),
            )
        },
        Scenario {
            setup: UNRESOLVABLE_IMMUTABLE,
            ..simple(
                "bookmark_create_unresolvable_immutable",
                |repo, _, _| {
                    let result = repo.bookmark_create(&["feature".to_owned()], None);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["bookmark", "create", "feature"]),
            )
        },
        Scenario {
            setup: UNRESOLVABLE_IMMUTABLE,
            ..simple(
                "undo_unresolvable_immutable",
                |repo, _, _| {
                    let result = repo.undo(false);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["undo"]),
            )
        },
        Scenario {
            setup: UNRESOLVABLE_TRUNK,
            ..simple(
                "new_unresolvable_trunk",
                |repo, _, s| {
                    let result = repo.new_change(&[s.change("@")], &[], &[]);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["new"]),
            )
        },
        Scenario {
            setup: UNRESOLVABLE_TRUNK,
            ..simple(
                "bookmark_create_unresolvable_trunk",
                |repo, _, _| {
                    let result = repo.bookmark_create(&["feature".to_owned()], None);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["bookmark", "create", "feature"]),
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
        // Story 9.40: Git HEAD made unborn behind jj's back, so the start-up import writes
        // `import git head` (only `git_head` changes); undoing it restores an equal view — the
        // CLI's "Nothing changed.", no operation.
        Scenario {
            setup: &[Step::Git(&["symbolic-ref", "HEAD", "refs/heads/nowhere"])],
            ..simple(
                "undo_no_change",
                |repo, _, _| {
                    let result = repo.undo(false);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["undo"]),
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
        // ── Story 9.31: a Git merge with the root refuses (up front in Zanshin) ─────────
        simple(
            "new_merge_with_root",
            |repo, _, s| {
                let result = repo.new_change(&[s.change("B"), s.change("root")], &[], &[]);
                zanshin_outcome(repo, &result)
            },
            |s| vec!["new".to_owned(), s.change_arg("B"), "root()".to_owned()],
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
        // ── Story 9.51 review: the remaining trailer branches, the environment, refusals ──
        Scenario {
            setup: TRAILERS,
            ..simple(
                "squash_use_destination_trailers",
                |repo, _, _| {
                    let options = SquashOptions {
                        use_destination_message: true,
                        ..SquashOptions::default()
                    };
                    squash_outcome(repo, &options)
                },
                |_| args(&["squash", "-u"]),
            )
        },
        Scenario {
            setup: UNDESCRIBED_C_TRAILERS,
            ..simple(
                "squash_single_description_trailers",
                |repo, _, _| squash_outcome(repo, &SquashOptions::default()),
                |_| args(&["squash"]),
            )
        },
        Scenario {
            setup: UNDESCRIBED_TRAILERS_EDITOR,
            ..simple(
                "split_editor_undescribed_trailers",
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
        Scenario {
            setup: C2_EDITOR_TRAILERS,
            ..simple(
                "split_parallel_editor_trailers",
                |repo, _, _| {
                    let options = SplitOptions {
                        message: None,
                        ..split_parallel()
                    };
                    split_outcome(repo, &options)
                },
                |_| args(&["split", "--parallel", "c.txt"]),
            )
        },
        Scenario {
            setup: TRAILERS,
            ..simple(
                "commit_empty_message_trailers",
                |repo, _, _| commit_outcome(repo, &[], &[""]),
                |_| args(&["commit", "-m", ""]),
            )
        },
        Scenario {
            init: NO_COLOCATE,
            setup: TRAILERS,
            extra: Some(ws2_read_back),
            ..simple(
                "workspace_add_no_message_trailers",
                |repo, _, _| add_outcome(repo, None, &[], &[], None, SparseInheritance::Copy),
                |_| args(&["workspace", "add", "../ws2"]),
            )
        },
        Scenario {
            setup: ENVIRONMENT_TRAILERS,
            ..simple(
                "describe_environment_trailers",
                |repo, _, s| {
                    let result = repo.describe(s.change("B"), "T\n");
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["describe", "@-", "-m", "T"]),
            )
        },
        Scenario {
            setup: BROKEN_DRAFT_EDITOR,
            ..simple(
                "squash_broken_draft_template",
                |repo, _, _| squash_outcome(repo, &SquashOptions::default()),
                |_| args(&["squash"]),
            )
        },
        // ── Story 9.51 closing run: the template half of the start-up environment ──
        Scenario {
            setup: BROKEN_TEMPLATE_ALIASES,
            ..simple(
                "abandon_broken_template_aliases",
                |repo, _, s| {
                    let result = repo.abandon(&[s.change("@")]);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["abandon"]),
            )
        },
        Scenario {
            setup: BROKEN_SHORT_PREFIXES,
            ..simple(
                "abandon_broken_short_prefixes",
                |repo, _, s| {
                    let result = repo.abandon(&[s.change("@")]);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["abandon"]),
            )
        },
        Scenario {
            setup: BAD_TEMPLATE_ALIAS_ENTRY,
            ..simple(
                "abandon_bad_template_alias_entry",
                |repo, _, s| {
                    let result = repo.abandon(&[s.change("@")]);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["abandon"]),
            )
        },
        Scenario {
            setup: DIAGNOSED_SHORT_PREFIXES,
            ..simple(
                "abandon_diagnosed_short_prefixes",
                |repo, _, s| {
                    let result = repo.abandon(&[s.change("@")]);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["abandon"]),
            )
        },
        // ── Story 9.54: the edited editor text, `config()`, workspace add's environment ──
        Scenario {
            // The plan's text minus its trailer line against the CLI's editor deleting it.
            setup: TRAILERS_DELETE_TRAILER_EDITOR,
            ..simple(
                "squash_plan_edited_trailer_deleted",
                |repo, _, _| {
                    squash_plan_edited(repo, |text| {
                        text.lines()
                            .filter(|line| !line.starts_with("Signed-off-by"))
                            .flat_map(|line| [line, "\n"])
                            .collect()
                    })
                },
                |_| args(&["squash"]),
            )
        },
        Scenario {
            // The plan's text unchanged against the CLI's editor saved unchanged: ONE trailer.
            setup: TRAILERS_EDITOR,
            ..simple(
                "squash_plan_edited_unchanged",
                |repo, _, _| squash_plan_edited(repo, ToOwned::to_owned),
                |_| args(&["squash"]),
            )
        },
        Scenario {
            // The single arm: `-u` with an edited text against `jj squash -u --editor`.
            setup: TRAILERS_WRITE_E_EDITOR,
            ..simple(
                "squash_use_destination_edited",
                |repo, _, _| {
                    let options = SquashOptions {
                        use_destination_message: true,
                        edited_description: Some("E\n".to_owned()),
                        ..SquashOptions::default()
                    };
                    squash_outcome(repo, &options)
                },
                |_| args(&["squash", "-u", "--editor"]),
            )
        },
        Scenario {
            // The single arm with no description at all: the editor still opens.
            setup: UNDESCRIBED_B_C_TRAILERS_WRITE_E_EDITOR,
            ..simple(
                "squash_undescribed_edited",
                |repo, _, _| {
                    let options = SquashOptions {
                        edited_description: Some("E\n".to_owned()),
                        ..SquashOptions::default()
                    };
                    squash_outcome(repo, &options)
                },
                |_| args(&["squash", "--editor"]),
            )
        },
        Scenario {
            setup: C2_DELETE_TRAILER_EDITOR_TRAILERS,
            ..simple(
                "split_edited_trailer_deleted",
                |repo, _, _| split_edited(repo, "C\n"),
                |_| args(&["split", "c.txt"]),
            )
        },
        Scenario {
            setup: C2_EDITOR_TRAILERS,
            ..simple(
                "split_edited_unchanged",
                |repo, _, _| split_edited(repo, &format!("C\n\n{SOB}\n")),
                |_| args(&["split", "c.txt"]),
            )
        },
        Scenario {
            setup: NEW_DESCRIPTION_CONFIG_UI_COLOR,
            ..simple(
                "new_description_config_ui_color",
                |repo, _, s| {
                    let result = repo.new_change(&[s.change("@")], &[], &[]);
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["new"]),
            )
        },
        Scenario {
            init: NO_COLOCATE,
            setup: BAD_TEMPLATE_ALIAS_ENTRY,
            extra: Some(ws2_read_back),
            ..simple(
                "workspace_add_bad_template_alias",
                |repo, _, _| add_outcome(repo, None, &[], &[], None, SparseInheritance::Copy),
                |_| args(&["workspace", "add", "../ws2"]),
            )
        },
        Scenario {
            init: NO_COLOCATE,
            setup: DIAGNOSED_SHORT_PREFIXES,
            extra: Some(ws2_read_back),
            ..simple(
                "workspace_add_diagnosed_short_prefixes",
                |repo, _, _| add_outcome(repo, None, &[], &[], None, SparseInheritance::Copy),
                |_| args(&["workspace", "add", "../ws2"]),
            )
        },
        Scenario {
            // The finish uses the NEW workspace's immutable set (Story 9.54 review): with `@` in
            // `immutable_heads()`, the new workspace's `@` is immutable there, so the finish puts
            // a new `@` on top of it — the old workspace's set would name the default `@` instead.
            init: NO_COLOCATE,
            setup: &[Step::Jj(&[
                "config",
                "set",
                "--repo",
                "revset-aliases.'immutable_heads()'",
                "'builtin_immutable_heads() | @'",
            ])],
            extra: Some(ws2_read_back),
            ..simple(
                "workspace_add_immutable_at",
                |repo, _, _| add_outcome(repo, None, &[], &[], None, SparseInheritance::Copy),
                |_| args(&["workspace", "add", "../ws2"]),
            )
        },
    ]
    .into_iter()
    .chain(rebase_scenarios())
    .chain(rebase_default_and_refusal_scenarios())
    .chain(rebase_flag_and_parallelize_scenarios())
    .chain(rebase_i1_and_immutable_scenarios())
    .chain(rebase_repeated_and_refusal_scenarios())
    .chain(clap_refusal_scenarios())
    .chain(metaedit_scenarios())
    .chain(metaedit_author_and_refusal_scenarios())
    .chain(duplicate_scenarios())
    .chain(fix_scenarios())
    .chain(bookmark_move_scenarios())
    .chain(bookmark_rename_scenarios())
    .chain(crate::git_scenarios::push_scenarios())
    .chain(crate::git_scenarios::bookmark_auto_track_scenarios())
    .chain(crate::git_scenarios::bookmark_rename_tracked_scenarios())
    .chain(crate::git_scenarios::fetch_scenarios())
    .collect()
}

// ── Story 9.19: bookmark move / advance / rename ──────────────────────────────────

/// `Repo::bookmark_move` of `names` (EXACT) to `to`.
fn move_outcome(
    repo: &mut zanshin_jj::Repo,
    names: &[&str],
    to: Option<zanshin_jj::ChangeId>,
    allow_backwards: bool,
) -> Outcome {
    let options = BookmarkMoveOptions {
        names: args(names),
        to,
        allow_backwards,
        ..Default::default()
    };
    let result = repo.bookmark_move(&options);
    zanshin_outcome(repo, &result)
}

/// `Repo::bookmark_advance` of `names` to `to`.
fn advance_outcome(repo: &mut zanshin_jj::Repo, names: &[&str], to: Option<&zanshin_jj::ChangeId>) -> Outcome {
    let result = repo.bookmark_advance(&args(names), to);
    zanshin_outcome(repo, &result)
}

/// `Repo::bookmark_rename`.
fn rename_outcome(repo: &mut zanshin_jj::Repo, old: &str, new: &str, overwrite_existing: bool) -> Outcome {
    let result = repo.bookmark_rename(old, new, overwrite_existing);
    zanshin_outcome(repo, &result)
}

/// `bookmark move` and `advance` on BASE (`b-mark` on B, `@` = C): forward, backwards refused and
/// allowed, `--from`, the no-op, an unknown name, an empty target; advance by default, by name,
/// and backwards refused.
#[allow(clippy::too_many_lines)] // WHY: one flat table reads better than fourteen helper fns
fn bookmark_move_scenarios() -> Vec<Scenario> {
    vec![
        simple(
            "bookmark_move_forward",
            |repo, _, s| move_outcome(repo, &["b-mark"], Some(s.change("C")), false),
            |s| {
                vec![
                    "bookmark".into(),
                    "move".into(),
                    "b-mark".into(),
                    "--to".into(),
                    s.change_arg("C"),
                ]
            },
        ),
        simple(
            "bookmark_move_backwards_refused",
            |repo, _, s| move_outcome(repo, &["b-mark"], Some(s.change("A")), false),
            |s| {
                vec![
                    "bookmark".into(),
                    "move".into(),
                    "b-mark".into(),
                    "--to".into(),
                    s.change_arg("A"),
                ]
            },
        ),
        simple(
            "bookmark_move_backwards_allowed",
            |repo, _, s| move_outcome(repo, &["b-mark"], Some(s.change("A")), true),
            |s| {
                vec![
                    "bookmark".into(),
                    "move".into(),
                    "b-mark".into(),
                    "--to".into(),
                    s.change_arg("A"),
                    "--allow-backwards".into(),
                ]
            },
        ),
        Scenario {
            setup: &[
                Step::Jj(&["bookmark", "create", "z-mark", "-r", "@-"]),
                Step::Jj(&["bookmark", "create", "a-mark", "-r", "@--"]),
            ],
            ..simple(
                "bookmark_move_from",
                |repo, _, s| {
                    let options = BookmarkMoveOptions {
                        from: vec![s.change_arg("B")],
                        to: Some(s.change("C")),
                        ..Default::default()
                    };
                    let result = repo.bookmark_move(&options);
                    zanshin_outcome(repo, &result)
                },
                |s| {
                    vec![
                        "bookmark".into(),
                        "move".into(),
                        "--from".into(),
                        s.change_arg("B"),
                        "--to".into(),
                        s.change_arg("C"),
                    ]
                },
            )
        },
        // Names AND `--from`: `a-mark` is named but not on B, so only `b-mark` moves.
        Scenario {
            setup: &[
                Step::Jj(&["bookmark", "create", "a-mark", "-r", "@--"]),
                Step::Jj(&["bookmark", "create", "z-mark", "-r", "@-"]),
            ],
            ..simple(
                "bookmark_move_names_and_from",
                |repo, _, s| {
                    let options = BookmarkMoveOptions {
                        names: args(&["a-mark", "b-mark"]),
                        from: vec![s.change_arg("B")],
                        to: Some(s.change("C")),
                        allow_backwards: false,
                    };
                    let result = repo.bookmark_move(&options);
                    zanshin_outcome(repo, &result)
                },
                |s| {
                    vec![
                        "bookmark".into(),
                        "move".into(),
                        "a-mark".into(),
                        "b-mark".into(),
                        "--from".into(),
                        s.change_arg("B"),
                        "--to".into(),
                        s.change_arg("C"),
                    ]
                },
            )
        },
        // I1: `b-mark` conflicted by two concurrent `bookmark set` (sides D and A), moved to `@` =
        // C, a descendant of side A: a fast-forward that leaves a normal target.
        Scenario {
            setup: &[
                Step::Jj(&["new", "--no-edit", "-m", "D", "b-mark"]),
                Step::Jj(&["bookmark", "set", "b-mark", "-r", "description(substring:\"D\")"]),
                Step::Jj(&[
                    "bookmark",
                    "set",
                    "b-mark",
                    "-r",
                    "description(substring:\"A\")",
                    "--allow-backwards",
                    "--at-op",
                    "@-",
                ]),
            ],
            ..simple(
                "bookmark_move_conflicted_to_descendant",
                |repo, _, _| move_outcome(repo, &["b-mark"], None, false),
                |_| args(&["bookmark", "move", "b-mark"]),
            )
        },
        simple(
            "bookmark_move_noop",
            |repo, _, s| move_outcome(repo, &["b-mark"], Some(s.change("B")), false),
            |s| {
                vec![
                    "bookmark".into(),
                    "move".into(),
                    "b-mark".into(),
                    "--to".into(),
                    s.change_arg("B"),
                ]
            },
        ),
        simple(
            "bookmark_move_unknown_name",
            |repo, _, _| move_outcome(repo, &["nope"], None, false),
            |_| args(&["bookmark", "move", "nope"]),
        ),
        Scenario {
            setup: &[Step::Jj(&["new"])],
            ..simple(
                "bookmark_move_empty_target",
                |repo, _, _| move_outcome(repo, &["b-mark"], None, false),
                |_| args(&["bookmark", "move", "b-mark"]),
            )
        },
        simple(
            "bookmark_advance_default",
            |repo, _, _| advance_outcome(repo, &[], None),
            |_| args(&["bookmark", "advance"]),
        ),
        // `revsets.bookmark-advance-from` with the injected `to`: `a-mark` becomes a candidate.
        Scenario {
            setup: &[
                Step::Jj(&["bookmark", "create", "a-mark", "-r", "@--"]),
                Step::Jj(&[
                    "config",
                    "set",
                    "--repo",
                    "revsets.bookmark-advance-from",
                    "::to & bookmarks()",
                ]),
            ],
            ..simple(
                "bookmark_advance_from_config",
                |repo, _, _| advance_outcome(repo, &[], None),
                |_| args(&["bookmark", "advance"]),
            )
        },
        simple(
            "bookmark_advance_named",
            |repo, _, _| advance_outcome(repo, &["b-mark"], None),
            |_| args(&["bookmark", "advance", "b-mark"]),
        ),
        simple(
            "bookmark_advance_backwards_refused",
            |repo, _, s| advance_outcome(repo, &["b-mark"], Some(&s.change("A"))),
            |s| {
                vec![
                    "bookmark".into(),
                    "advance".into(),
                    "b-mark".into(),
                    "--to".into(),
                    s.change_arg("A"),
                ]
            },
        ),
    ]
}

/// `bookmark rename` on BASE: the rename, onto an existing name refused and overwritten, a
/// missing name, and the same name refused and (with overwrite) a no-op.
fn bookmark_rename_scenarios() -> Vec<Scenario> {
    const OTHER: &[Step] = &[Step::Jj(&["bookmark", "create", "other"])];
    vec![
        simple(
            "bookmark_rename",
            |repo, _, _| rename_outcome(repo, "b-mark", "renamed", false),
            |_| args(&["bookmark", "rename", "b-mark", "renamed"]),
        ),
        Scenario {
            setup: OTHER,
            ..simple(
                "bookmark_rename_onto_existing_refused",
                |repo, _, _| rename_outcome(repo, "b-mark", "other", false),
                |_| args(&["bookmark", "rename", "b-mark", "other"]),
            )
        },
        Scenario {
            setup: OTHER,
            ..simple(
                "bookmark_rename_overwrite",
                |repo, _, _| rename_outcome(repo, "b-mark", "other", true),
                |_| args(&["bookmark", "rename", "b-mark", "other", "--overwrite-existing"]),
            )
        },
        simple(
            "bookmark_rename_missing",
            |repo, _, _| rename_outcome(repo, "nope", "x", false),
            |_| args(&["bookmark", "rename", "nope", "x"]),
        ),
        simple(
            "bookmark_rename_same_refused",
            |repo, _, _| rename_outcome(repo, "b-mark", "b-mark", false),
            |_| args(&["bookmark", "rename", "b-mark", "b-mark"]),
        ),
        simple(
            "bookmark_rename_same_overwrite",
            |repo, _, _| rename_outcome(repo, "b-mark", "b-mark", true),
            |_| args(&["bookmark", "rename", "b-mark", "b-mark", "--overwrite-existing"]),
        ),
    ]
}

// ── Story 9.16: rebase, parallelize ──────────────────────────────────────────────
//
// `jj arrange` has no scenario: the CLI's arrange is TUI-only (crossterm raw mode), so the pinned
// CLI cannot run it headless. Its port rests on the CLI's own `State` / `RewritePlan` unit tests
// (ported in `crates/zanshin-jj/src/arrange.rs`) and the jj-level tests
// (`crates/zanshin-jj/tests/it/parallelize_arrange.rs`).

/// `Repo::rebase` with `options`.
fn rebase_outcome(repo: &mut zanshin_jj::Repo, options: &RebaseOptions) -> Outcome {
    let result = repo.rebase(options);
    zanshin_outcome(repo, &result)
}

/// `Repo::parallelize` of the commits labelled `labels`.
fn parallelize_outcome(repo: &mut zanshin_jj::Repo, s: &State, labels: &[&str]) -> Outcome {
    let ids: Vec<zanshin_jj::ChangeId> = labels.iter().map(|label| s.change(label)).collect();
    let result = repo.parallelize(&ids);
    zanshin_outcome(repo, &result)
}

/// The labels' change ids as the CLI's arguments.
fn change_args(s: &State, labels: &[&str]) -> Vec<String> {
    labels.iter().map(|label| s.change_arg(label)).collect()
}

/// `jj rebase <what> <what label> <where> <where label> [flags]`, the labels as change ids
/// (`root` as `root()`).
fn rebase_argv(s: &State, what: (&str, &str), location: (&str, &str), flags: &[&str]) -> Vec<String> {
    let arg = |label: &str| {
        if label == "root" {
            "root()".to_owned()
        } else {
            s.change_arg(label)
        }
    };
    let mut argv = vec![
        "rebase".to_owned(),
        what.0.to_owned(),
        arg(what.1),
        location.0.to_owned(),
        arg(location.1),
    ];
    argv.extend(flags.iter().map(|flag| (*flag).to_owned()));
    argv
}

/// D on A re-adding B's `b.txt`: onto B it is emptied.
const D_REPEATS_B: &[Step] = &[
    Step::Jj(&["new", "-m", "D", "@--"]),
    Step::Write("b.txt", "b\n"),
    Step::Jj(&["util", "snapshot"]),
];

/// M = merge(C, B) and X on the root.
const MERGE_AND_X: &[Step] = &[
    Step::Jj(&["new", "-m", "M", "@", "@-"]),
    Step::Jj(&["new", "-m", "X", "root()"]),
];

/// The rebase scenarios of the four drop-menu forms and `-r` onto a descendant.
fn rebase_scenarios() -> Vec<Scenario> {
    vec![
        simple(
            "rebase_source_onto",
            |repo, _, s| {
                let options = RebaseOptions {
                    source: vec![s.change("C")],
                    onto: vec![s.change("A")],
                    ..RebaseOptions::default()
                };
                rebase_outcome(repo, &options)
            },
            |s| rebase_argv(s, ("-s", "C"), ("-o", "A"), &[]),
        ),
        simple(
            "rebase_revision_onto_root",
            |repo, _, s| {
                let options = RebaseOptions {
                    revisions: vec![s.change("B")],
                    onto: vec![s.change("root")],
                    ..RebaseOptions::default()
                };
                rebase_outcome(repo, &options)
            },
            |s| rebase_argv(s, ("-r", "B"), ("-o", "root"), &[]),
        ),
        simple(
            "rebase_revision_onto_descendant",
            |repo, _, s| {
                let options = RebaseOptions {
                    revisions: vec![s.change("B")],
                    onto: vec![s.change("C")],
                    ..RebaseOptions::default()
                };
                rebase_outcome(repo, &options)
            },
            |s| rebase_argv(s, ("-r", "B"), ("-o", "C"), &[]),
        ),
        simple(
            "rebase_revision_insert_after",
            |repo, _, s| {
                let options = RebaseOptions {
                    revisions: vec![s.change("C")],
                    insert_after: vec![s.change("A")],
                    ..RebaseOptions::default()
                };
                rebase_outcome(repo, &options)
            },
            |s| rebase_argv(s, ("-r", "C"), ("-A", "A"), &[]),
        ),
        simple(
            "rebase_revision_insert_before",
            |repo, _, s| {
                let options = RebaseOptions {
                    revisions: vec![s.change("C")],
                    insert_before: vec![s.change("B")],
                    ..RebaseOptions::default()
                };
                rebase_outcome(repo, &options)
            },
            |s| rebase_argv(s, ("-r", "C"), ("-B", "B"), &[]),
        ),
    ]
}

/// The rebase scenarios of the `-b @` default, a branch already in place, and the two refusals.
fn rebase_default_and_refusal_scenarios() -> Vec<Scenario> {
    vec![
        simple(
            "rebase_default_branch",
            |repo, _, s| {
                let options = RebaseOptions {
                    onto: vec![s.change("A")],
                    ..RebaseOptions::default()
                };
                rebase_outcome(repo, &options)
            },
            |s| vec!["rebase".to_owned(), "-o".to_owned(), s.change_arg("A")],
        ),
        Scenario {
            // `-b @` with `@` on X off the root: roots(A..@) is X — it moves.
            setup: &[Step::Jj(&["new", "-m", "X", "root()"])],
            ..simple(
                "rebase_default_branch_moves",
                |repo, _, s| {
                    let options = RebaseOptions {
                        onto: vec![s.change("A")],
                        ..RebaseOptions::default()
                    };
                    rebase_outcome(repo, &options)
                },
                |s| vec!["rebase".to_owned(), "-o".to_owned(), s.change_arg("A")],
            )
        },
        simple(
            "rebase_branch_noop",
            |repo, _, s| {
                let options = RebaseOptions {
                    branch: vec![s.change("A")],
                    onto: vec![s.change("B")],
                    ..RebaseOptions::default()
                };
                rebase_outcome(repo, &options)
            },
            |s| rebase_argv(s, ("-b", "A"), ("-o", "B"), &[]),
        ),
        simple(
            "rebase_source_onto_descendant_refused",
            |repo, _, s| {
                let options = RebaseOptions {
                    source: vec![s.change("A")],
                    onto: vec![s.change("B")],
                    ..RebaseOptions::default()
                };
                rebase_outcome(repo, &options)
            },
            |s| rebase_argv(s, ("-s", "A"), ("-o", "B"), &[]),
        ),
        simple(
            "rebase_revision_onto_itself_refused",
            |repo, _, s| {
                let options = RebaseOptions {
                    revisions: vec![s.change("A")],
                    onto: vec![s.change("A")],
                    ..RebaseOptions::default()
                };
                rebase_outcome(repo, &options)
            },
            |s| rebase_argv(s, ("-r", "A"), ("-o", "A"), &[]),
        ),
    ]
}

/// The rebase scenarios with a refusal, a flag or the I1 corner, and parallelize's.
fn rebase_flag_and_parallelize_scenarios() -> Vec<Scenario> {
    vec![
        Scenario {
            setup: D_REPEATS_B,
            ..simple(
                "rebase_skip_emptied",
                |repo, _, s| {
                    let options = RebaseOptions {
                        revisions: vec![s.change("D")],
                        onto: vec![s.change("B")],
                        skip_emptied: true,
                        ..RebaseOptions::default()
                    };
                    rebase_outcome(repo, &options)
                },
                |s| rebase_argv(s, ("-r", "D"), ("-o", "B"), &["--skip-emptied"]),
            )
        },
        Scenario {
            setup: MERGE_AND_X,
            ..simple(
                "rebase_simplify_parents",
                |repo, _, s| {
                    let options = RebaseOptions {
                        source: vec![s.change("A")],
                        onto: vec![s.change("X")],
                        simplify_parents: true,
                        ..RebaseOptions::default()
                    };
                    rebase_outcome(repo, &options)
                },
                |s| rebase_argv(s, ("-s", "A"), ("-o", "X"), &["--simplify-parents"]),
            )
        },
        // Deferred-work I1: `-s` with `-A`/`-B` whose target lies inside the moved set.
        simple(
            "rebase_i1_source_insert_after",
            |repo, _, s| {
                let options = RebaseOptions {
                    source: vec![s.change("A")],
                    insert_after: vec![s.change("B")],
                    ..RebaseOptions::default()
                };
                rebase_outcome(repo, &options)
            },
            |s| rebase_argv(s, ("-s", "A"), ("-A", "B"), &[]),
        ),
        simple(
            "rebase_i1_source_insert_before",
            |repo, _, s| {
                let options = RebaseOptions {
                    source: vec![s.change("A")],
                    insert_before: vec![s.change("C")],
                    ..RebaseOptions::default()
                };
                rebase_outcome(repo, &options)
            },
            |s| rebase_argv(s, ("-s", "A"), ("-B", "C"), &[]),
        ),
        simple(
            "parallelize_two",
            |repo, _, s| parallelize_outcome(repo, s, &["B", "C"]),
            |s| {
                let mut argv = vec!["parallelize".to_owned()];
                argv.extend(change_args(s, &["B", "C"]));
                argv
            },
        ),
        simple(
            "parallelize_one_noop",
            |repo, _, s| parallelize_outcome(repo, s, &["B"]),
            |s| {
                let mut argv = vec!["parallelize".to_owned()];
                argv.extend(change_args(s, &["B"]));
                argv
            },
        ),
    ]
}

/// X on A, then M = merge(C, X): M is inside `B::` with a parent outside it.
const X_AND_MERGE: &[Step] = &[
    Step::Jj(&["new", "-m", "X", "@--"]),
    Step::Jj(&["new", "-m", "M", "b-mark+", "@"]),
];

/// `immutable_heads()` = B (through its bookmark): A and B are immutable.
const B_IMMUTABLE: &[Step] = &[Step::Jj(&[
    "config",
    "set",
    "--repo",
    "revset-aliases.'immutable_heads()'",
    "b-mark",
])];

/// Deferred-work I1 where the move relocates and `-b`'s two I1 cases, an immutable refusal, and
/// parallelize's outside-child branch.
fn rebase_i1_and_immutable_scenarios() -> Vec<Scenario> {
    vec![
        Scenario {
            // jj-lib replaces M by its parents' external ancestors (A for C, X itself): B onto
            // merge(A, X).
            setup: X_AND_MERGE,
            ..simple(
                "rebase_i1_source_insert_after_merge",
                |repo, _, s| {
                    let options = RebaseOptions {
                        source: vec![s.change("B")],
                        insert_after: vec![s.change("M")],
                        ..RebaseOptions::default()
                    };
                    rebase_outcome(repo, &options)
                },
                |s| rebase_argv(s, ("-s", "B"), ("-A", "M"), &[]),
            )
        },
        simple(
            "rebase_i1_branch_insert_after",
            |repo, _, s| {
                let options = RebaseOptions {
                    branch: vec![s.change("C")],
                    insert_after: vec![s.change("B")],
                    ..RebaseOptions::default()
                };
                rebase_outcome(repo, &options)
            },
            |s| rebase_argv(s, ("-b", "C"), ("-A", "B"), &[]),
        ),
        simple(
            "rebase_i1_branch_insert_before",
            |repo, _, s| {
                let options = RebaseOptions {
                    branch: vec![s.change("A")],
                    insert_before: vec![s.change("C")],
                    ..RebaseOptions::default()
                };
                rebase_outcome(repo, &options)
            },
            |s| rebase_argv(s, ("-b", "A"), ("-B", "C"), &[]),
        ),
        Scenario {
            setup: B_IMMUTABLE,
            ..simple(
                "rebase_immutable_refused",
                |repo, _, s| {
                    let options = RebaseOptions {
                        revisions: vec![s.change("B")],
                        onto: vec![s.change("root")],
                        ..RebaseOptions::default()
                    };
                    rebase_outcome(repo, &options)
                },
                |s| rebase_argv(s, ("-r", "B"), ("-o", "root"), &[]),
            )
        },
        simple(
            "parallelize_child_becomes_a_merge",
            |repo, _, s| parallelize_outcome(repo, s, &["A", "B"]),
            |s| {
                let mut argv = vec!["parallelize".to_owned()];
                argv.extend(change_args(s, &["A", "B"]));
                argv
            },
        ),
        Scenario {
            // M = merge(C, X) is outside the set: C's place takes B and C, X stays.
            setup: X_AND_MERGE,
            ..simple(
                "parallelize_merge_child_keeps_outside_parent",
                |repo, _, s| parallelize_outcome(repo, s, &["B", "C"]),
                |s| {
                    let mut argv = vec!["parallelize".to_owned()];
                    argv.extend(change_args(s, &["B", "C"]));
                    argv
                },
            )
        },
    ]
}

/// X on the root; `@` ends on it.
const X_ON_ROOT: &[Step] = &[Step::Jj(&["new", "-m", "X", "root()"])];

/// `jj rebase` with repeated flags: each `(flag, label)` pair in order, labels as change ids
/// (`root` as `root()`).
fn rebase_argv_repeated(s: &State, pairs: &[(&str, &str)]) -> Vec<String> {
    let mut argv = vec!["rebase".to_owned()];
    for (flag, label) in pairs {
        argv.push((*flag).to_owned());
        argv.push(if *label == "root" {
            "root()".to_owned()
        } else {
            s.change_arg(label)
        });
    }
    argv
}

/// I1's `-B` relocation, `-s` onto itself, repeated flags (the plural operation descriptions and a
/// rebase that creates a merge) and a location that would create a loop.
fn rebase_repeated_and_refusal_scenarios() -> Vec<Scenario> {
    vec![
        Scenario {
            // jj-lib replaces the new child M by its external descendants (none) and keeps M's
            // outside parent X: B onto merge(A, X), as with `-A M`.
            setup: X_AND_MERGE,
            ..simple(
                "rebase_i1_source_insert_before_merge",
                |repo, _, s| {
                    let options = RebaseOptions {
                        source: vec![s.change("B")],
                        insert_before: vec![s.change("M")],
                        ..RebaseOptions::default()
                    };
                    rebase_outcome(repo, &options)
                },
                |s| rebase_argv(s, ("-s", "B"), ("-B", "M"), &[]),
            )
        },
        simple(
            "rebase_source_onto_itself_refused",
            |repo, _, s| {
                let options = RebaseOptions {
                    source: vec![s.change("A")],
                    onto: vec![s.change("A")],
                    ..RebaseOptions::default()
                };
                rebase_outcome(repo, &options)
            },
            |s| rebase_argv(s, ("-s", "A"), ("-o", "A"), &[]),
        ),
        simple(
            "rebase_several_revisions",
            |repo, _, s| {
                let options = RebaseOptions {
                    revisions: vec![s.change("B"), s.change("C")],
                    onto: vec![s.change("root")],
                    ..RebaseOptions::default()
                };
                rebase_outcome(repo, &options)
            },
            |s| rebase_argv_repeated(s, &[("-r", "B"), ("-r", "C"), ("-o", "root")]),
        ),
        Scenario {
            setup: X_ON_ROOT,
            ..simple(
                "rebase_several_sources",
                |repo, _, s| {
                    let options = RebaseOptions {
                        source: vec![s.change("C"), s.change("X")],
                        onto: vec![s.change("A")],
                        ..RebaseOptions::default()
                    };
                    rebase_outcome(repo, &options)
                },
                |s| rebase_argv_repeated(s, &[("-s", "C"), ("-s", "X"), ("-o", "A")]),
            )
        },
        Scenario {
            setup: X_ON_ROOT,
            ..simple(
                "rebase_onto_two_parents",
                |repo, _, s| {
                    let options = RebaseOptions {
                        source: vec![s.change("C")],
                        onto: vec![s.change("B"), s.change("X")],
                        ..RebaseOptions::default()
                    };
                    rebase_outcome(repo, &options)
                },
                |s| rebase_argv_repeated(s, &[("-s", "C"), ("-o", "B"), ("-o", "X")]),
            )
        },
        simple(
            "rebase_insert_loop_refused",
            |repo, _, s| {
                let options = RebaseOptions {
                    revisions: vec![s.change("C")],
                    insert_after: vec![s.change("B")],
                    insert_before: vec![s.change("A")],
                    ..RebaseOptions::default()
                };
                rebase_outcome(repo, &options)
            },
            |s| rebase_argv_repeated(s, &[("-r", "C"), ("-A", "B"), ("-B", "A")]),
        ),
    ]
}

/// The edit every clap-refusal scenario leaves in the working copy: a snapshot would record it.
const DIRTY_C: &[(&str, &str)] = &[("c.txt", "c, edited before a clap refusal\n")];

/// Clap refusals on a dirty working copy: the CLI parses its arguments before the command body
/// snapshots, so it refuses without a `snapshot working copy` operation — and so must Zanshin.
fn clap_refusal_scenarios() -> Vec<Scenario> {
    vec![
        Scenario {
            files: DIRTY_C,
            ..simple(
                "rebase_clap_conflict_dirty_wc",
                |repo, _, s| {
                    let options = RebaseOptions {
                        revisions: vec![s.change("B")],
                        source: vec![s.change("B")],
                        onto: vec![s.change("A")],
                        ..RebaseOptions::default()
                    };
                    rebase_outcome(repo, &options)
                },
                |s| rebase_argv_repeated(s, &[("-r", "B"), ("-s", "B"), ("-o", "A")]),
            )
        },
        Scenario {
            files: DIRTY_C,
            ..simple(
                "squash_clap_conflict_dirty_wc",
                |repo, _, s| {
                    let options = SquashOptions {
                        revision: Some(s.change("B")),
                        into: Some(s.change("A")),
                        ..SquashOptions::default()
                    };
                    squash_outcome(repo, &options)
                },
                |s| {
                    vec![
                        "squash".to_owned(),
                        "-r".to_owned(),
                        s.change_arg("B"),
                        "--into".to_owned(),
                        s.change_arg("A"),
                    ]
                },
            )
        },
        Scenario {
            files: DIRTY_C,
            ..simple(
                "split_clap_conflict_dirty_wc",
                |repo, _, s| {
                    let options = SplitOptions {
                        paths: vec!["c.txt".to_owned()],
                        parallel: true,
                        onto: Some(vec![s.change("A")]),
                        ..SplitOptions::default()
                    };
                    split_outcome(repo, &options)
                },
                |s| {
                    vec![
                        "split".to_owned(),
                        "--parallel".to_owned(),
                        "-o".to_owned(),
                        s.change_arg("A"),
                        "c.txt".to_owned(),
                    ]
                },
            )
        },
        Scenario {
            files: DIRTY_C,
            ..simple(
                "new_clap_conflict_dirty_wc",
                |repo, _, s| {
                    let result = repo.new_change(&[s.change("A")], &[s.change("B")], &[]);
                    zanshin_outcome(repo, &result)
                },
                |s| vec!["new".to_owned(), s.change_arg("A"), "-A".to_owned(), s.change_arg("B")],
            )
        },
        Scenario {
            files: DIRTY_C,
            ..simple(
                "restore_clap_conflict_dirty_wc",
                |repo, _, s| {
                    let result = repo.restore(Some(s.change("A")), None, Some(s.change("B")), &[], false);
                    zanshin_outcome(repo, &result)
                },
                |s| {
                    vec![
                        "restore".to_owned(),
                        "--from".to_owned(),
                        s.change_arg("A"),
                        "--changes-in".to_owned(),
                        s.change_arg("B"),
                    ]
                },
            )
        },
    ]
}

// ── Story 9.9: metaedit, duplicate, fix ──────────────────────────────────────────

/// `Repo::metaedit` with `options`.
fn metaedit_outcome(repo: &mut zanshin_jj::Repo, options: &MetaeditOptions) -> Outcome {
    let result = repo.metaedit(options);
    zanshin_outcome(repo, &result)
}

/// `Repo::duplicate` with `options`.
fn duplicate_outcome(repo: &mut zanshin_jj::Repo, options: &DuplicateOptions) -> Outcome {
    let result = repo.duplicate(options);
    zanshin_outcome(repo, &result)
}

/// `Repo::fix` with `options`.
fn fix_outcome(repo: &mut zanshin_jj::Repo, options: &FixOptions) -> Outcome {
    let result = repo.fix(options);
    zanshin_outcome(repo, &result)
}

/// `jj <verb>`, each `(flag, label)` pair as the flag and the label's change id (`root` as
/// `root()`), then the plain `tail` arguments.
fn verb_argv(s: &State, verb: &str, pairs: &[(&str, &str)], tail: &[&str]) -> Vec<String> {
    let mut argv = rebase_argv_repeated(s, pairs);
    argv.splice(..1, [verb.to_owned()]);
    argv.extend(tail.iter().map(|arg| (*arg).to_owned()));
    argv
}

/// Every visible commit's author timestamp: a fixed one (before 2001-09-09) as epoch millis and
/// offset, else `recent` — the timestamps the steps write differ between the two repos.
fn author_timestamps(root: &Path) -> String {
    let (_workspace, repo) = load_workspace(root);
    let mut stack: Vec<CommitId> = repo.view().heads().iter().cloned().collect();
    let mut seen = std::collections::HashSet::new();
    let mut lines = Vec::new();
    while let Some(id) = stack.pop() {
        if !seen.insert(id.clone()) || &id == repo.store().root_commit_id() {
            continue;
        }
        let commit = repo.store().get_commit(&id).expect("a visible commit");
        stack.extend(commit.parent_ids().iter().cloned());
        let timestamp = &commit.author().timestamp;
        let when = if timestamp.timestamp.0 < 1_000_000_000_000 {
            format!("{}{:+}", timestamp.timestamp.0, timestamp.tz_offset)
        } else {
            "recent".to_owned()
        };
        lines.push(format!("{}={when}", first_line(commit.description())));
    }
    lines.sort();
    lines.join("  ")
}

/// metaedit: the message forms and a new change id.
fn metaedit_scenarios() -> Vec<Scenario> {
    vec![
        simple(
            "metaedit_message",
            |repo, _, _| {
                let options = MetaeditOptions {
                    message: Some(vec!["X".to_owned()]),
                    ..MetaeditOptions::default()
                };
                metaedit_outcome(repo, &options)
            },
            |_| args(&["metaedit", "-m", "X"]),
        ),
        simple(
            "metaedit_revision_message",
            |repo, _, s| {
                let options = MetaeditOptions {
                    revisions: vec![s.change("B")],
                    message: Some(vec!["X".to_owned()]),
                    ..MetaeditOptions::default()
                };
                metaedit_outcome(repo, &options)
            },
            |s| verb_argv(s, "metaedit", &[("-r", "B")], &["-m", "X"]),
        ),
        simple(
            "metaedit_empty_message",
            |repo, _, s| {
                let options = MetaeditOptions {
                    revisions: vec![s.change("B")],
                    message: Some(Vec::new()),
                    ..MetaeditOptions::default()
                };
                metaedit_outcome(repo, &options)
            },
            |s| verb_argv(s, "metaedit", &[("-r", "B")], &["-m", ""]),
        ),
        simple(
            "metaedit_update_change_id",
            |repo, _, s| {
                let options = MetaeditOptions {
                    revisions: vec![s.change("B")],
                    update_change_id: true,
                    ..MetaeditOptions::default()
                };
                metaedit_outcome(repo, &options)
            },
            |s| verb_argv(s, "metaedit", &[("-r", "B")], &["--update-change-id"]),
        ),
        // Two targets: "edit commit metadata for commit <C> and 1 more".
        simple(
            "metaedit_two_revisions_message",
            |repo, _, s| {
                let options = MetaeditOptions {
                    revisions: vec![s.change("B"), s.change("C")],
                    message: Some(vec!["X".to_owned()]),
                    ..MetaeditOptions::default()
                };
                metaedit_outcome(repo, &options)
            },
            |s| verb_argv(s, "metaedit", &[("-r", "B"), ("-r", "C")], &["-m", "X"]),
        ),
        simple(
            "metaedit_two_paragraphs",
            |repo, _, _| {
                let options = MetaeditOptions {
                    message: Some(vec!["P1".to_owned(), "P2".to_owned()]),
                    ..MetaeditOptions::default()
                };
                metaedit_outcome(repo, &options)
            },
            |_| args(&["metaedit", "-m", "P1", "-m", "P2"]),
        ),
        Scenario {
            extra: Some(author_timestamps),
            ..simple(
                "metaedit_update_author_timestamp",
                |repo, _, _| {
                    let options = MetaeditOptions {
                        update_author_timestamp: true,
                        ..MetaeditOptions::default()
                    };
                    metaedit_outcome(repo, &options)
                },
                |_| args(&["metaedit", "--update-author-timestamp"]),
            )
        },
    ]
}

/// metaedit: author and timestamp, the no-op gates, the root refusal and a clap refusal on a dirty
/// working copy.
fn metaedit_author_and_refusal_scenarios() -> Vec<Scenario> {
    vec![
        Scenario {
            extra: Some(author_timestamps),
            ..simple(
                "metaedit_author",
                |repo, _, _| {
                    let options = MetaeditOptions {
                        author: Some("Foo <foo@bar>".to_owned()),
                        ..MetaeditOptions::default()
                    };
                    metaedit_outcome(repo, &options)
                },
                |_| args(&["metaedit", "--author", "Foo <foo@bar>"]),
            )
        },
        Scenario {
            extra: Some(author_timestamps),
            ..simple(
                "metaedit_author_timestamp",
                |repo, _, _| {
                    let options = MetaeditOptions {
                        author_timestamp: Some("2000-01-23T01:23:45-08:00".to_owned()),
                        ..MetaeditOptions::default()
                    };
                    metaedit_outcome(repo, &options)
                },
                |_| args(&["metaedit", "--author-timestamp", "2000-01-23T01:23:45-08:00"]),
            )
        },
        // The configured identity is the one BASE was written with: nothing to rewrite, no op.
        simple(
            "metaedit_update_author_noop",
            |repo, _, _| {
                let options = MetaeditOptions {
                    update_author: true,
                    ..MetaeditOptions::default()
                };
                metaedit_outcome(repo, &options)
            },
            |_| args(&["metaedit", "--update-author"]),
        ),
        simple(
            "metaedit_force_rewrite",
            |repo, _, _| {
                let options = MetaeditOptions {
                    force_rewrite: true,
                    ..MetaeditOptions::default()
                };
                metaedit_outcome(repo, &options)
            },
            |_| args(&["metaedit", "--force-rewrite"]),
        ),
        simple(
            "metaedit_root_refused",
            |repo, _, s| {
                let options = MetaeditOptions {
                    revisions: vec![s.change("root")],
                    message: Some(vec!["X".to_owned()]),
                    ..MetaeditOptions::default()
                };
                metaedit_outcome(repo, &options)
            },
            |_| args(&["metaedit", "-r", "root()", "-m", "X"]),
        ),
        simple(
            "metaedit_unchanged_message_noop",
            |repo, _, _| {
                let options = MetaeditOptions {
                    message: Some(vec!["C".to_owned()]),
                    ..MetaeditOptions::default()
                };
                metaedit_outcome(repo, &options)
            },
            |_| args(&["metaedit", "-m", "C"]),
        ),
        Scenario {
            files: DIRTY_C,
            extra: Some(author_timestamps),
            ..simple(
                "metaedit_clap_conflict_dirty_wc",
                |repo, _, _| {
                    let options = MetaeditOptions {
                        author: Some("Foo <foo@bar>".to_owned()),
                        update_author: true,
                        ..MetaeditOptions::default()
                    };
                    metaedit_outcome(repo, &options)
                },
                |_| args(&["metaedit", "--author", "Foo <foo@bar>", "--update-author"]),
            )
        },
    ]
}

/// `templates.duplicate_description` prefixing every duplicate's description.
const DUPLICATE_DESCRIPTION: &[Step] = &[Step::Jj(&[
    "config",
    "set",
    "--repo",
    "templates.duplicate_description",
    "'\"dup \" ++ description'",
])];

/// duplicate: the default, each location flag, the two self-relation warnings, several
/// revisions, the root refusal and the description template.
fn duplicate_scenarios() -> Vec<Scenario> {
    vec![
        simple(
            "duplicate_default",
            |repo, _, _| duplicate_outcome(repo, &DuplicateOptions::default()),
            |_| args(&["duplicate"]),
        ),
        simple(
            "duplicate_revision",
            |repo, _, s| duplicate_outcome(repo, &dup(s, &["B"], "", &[])),
            |s| verb_argv(s, "duplicate", &[("-r", "B")], &[]),
        ),
        simple(
            "duplicate_onto_root",
            |repo, _, s| duplicate_outcome(repo, &dup(s, &["B"], "-o", &["root"])),
            |s| verb_argv(s, "duplicate", &[("-r", "B"), ("-o", "root")], &[]),
        ),
        simple(
            "duplicate_insert_after",
            |repo, _, s| duplicate_outcome(repo, &dup(s, &["C"], "-A", &["A"])),
            |s| verb_argv(s, "duplicate", &[("-r", "C"), ("-A", "A")], &[]),
        ),
        simple(
            "duplicate_insert_before",
            |repo, _, s| duplicate_outcome(repo, &dup(s, &["B"], "-B", &["C"])),
            |s| verb_argv(s, "duplicate", &[("-r", "B"), ("-B", "C")], &[]),
        ),
        Scenario {
            setup: X_ON_ROOT,
            ..simple(
                "duplicate_onto_two_parents",
                |repo, _, s| duplicate_outcome(repo, &dup(s, &["C"], "-o", &["A", "X"])),
                |s| verb_argv(s, "duplicate", &[("-r", "C"), ("-o", "A"), ("-o", "X")], &[]),
            )
        },
        simple(
            "duplicate_as_own_descendant",
            |repo, _, s| duplicate_outcome(repo, &dup(s, &["A"], "-o", &["C"])),
            |s| verb_argv(s, "duplicate", &[("-r", "A"), ("-o", "C")], &[]),
        ),
        simple(
            "duplicate_as_own_ancestor",
            |repo, _, s| duplicate_outcome(repo, &dup(s, &["C"], "-B", &["B"])),
            |s| verb_argv(s, "duplicate", &[("-r", "C"), ("-B", "B")], &[]),
        ),
        simple(
            "duplicate_two_revisions",
            |repo, _, s| duplicate_outcome(repo, &dup(s, &["B", "C"], "", &[])),
            |s| verb_argv(s, "duplicate", &[("-r", "B"), ("-r", "C")], &[]),
        ),
        simple(
            "duplicate_root_refused",
            |repo, _, s| duplicate_outcome(repo, &dup(s, &["root"], "", &[])),
            |_| args(&["duplicate", "root()"]),
        ),
        Scenario {
            setup: DUPLICATE_DESCRIPTION,
            ..simple(
                "duplicate_description_template",
                |repo, _, s| duplicate_outcome(repo, &dup(s, &["B"], "", &[])),
                |s| verb_argv(s, "duplicate", &[("-r", "B")], &[]),
            )
        },
    ]
}

/// `DuplicateOptions` of the commits labelled `revisions` at the location `flag` (`-o`, `-A`,
/// `-B`, or `""` for none) of the commits labelled `labels`.
fn dup(s: &State, revisions: &[&str], flag: &str, labels: &[&str]) -> DuplicateOptions {
    let ids = |labels: &[&str]| labels.iter().map(|label| s.change(label)).collect::<Vec<_>>();
    let mut options = DuplicateOptions {
        revisions: ids(revisions),
        ..DuplicateOptions::default()
    };
    match flag {
        "-o" => options.onto = ids(labels),
        "-A" => options.insert_after = ids(labels),
        "-B" => options.insert_before = ids(labels),
        _ => {}
    }
    options
}

/// The `fix.tools.up.patterns` step every fix scenario's tool shares.
const FIX_PATTERNS_STEP: Step = Step::Jj(&[
    "config",
    "set",
    "--repo",
    "fix.tools.up.patterns",
    r#"["glob:'*.txt'"]"#,
]);

/// A tool uppercasing every `*.txt` file.
const FIX_TOOL: &[Step] = &[
    Step::Jj(&[
        "config",
        "set",
        "--repo",
        "fix.tools.up.command",
        r#"["tr", "a-z", "A-Z"]"#,
    ]),
    FIX_PATTERNS_STEP,
];

/// [`FIX_TOOL`], already applied: a second fix has nothing left to change.
const FIX_TOOL_APPLIED: &[Step] = &[
    Step::Jj(&[
        "config",
        "set",
        "--repo",
        "fix.tools.up.command",
        r#"["tr", "a-z", "A-Z"]"#,
    ]),
    FIX_PATTERNS_STEP,
    Step::Jj(&["fix"]),
];

/// A tool that always fails (`false`): each file it is run on warns.
const FIX_TOOL_FAILING: &[Step] = &[
    Step::Jj(&["config", "set", "--repo", "fix.tools.up.command", r#"["false"]"#]),
    FIX_PATTERNS_STEP,
];

/// A tool configured with the deprecated `line-range-arg`: it uppercases and appends its extra
/// arguments, so the migrated `line-range-args` shows in the fixed trees.
const FIX_TOOL_DEPRECATED: &[Step] = &[
    Step::Jj(&[
        "config",
        "set",
        "--repo",
        "fix.tools.up.command",
        r#"["sh", "-c", 'tr a-z A-Z; printf "%s\n" "$@"', "sh"]"#,
    ]),
    FIX_PATTERNS_STEP,
    Step::Jj(&[
        "config",
        "set",
        "--repo",
        "fix.tools.up.line-range-arg",
        "\"--l=$first\"",
    ]),
];

/// A scenario on BASE plus [`FIX_TOOL`].
fn fix_tool(
    id: &'static str,
    zanshin: fn(&mut zanshin_jj::Repo, &Path, &State) -> Outcome,
    cli: fn(&State) -> Vec<String>,
) -> Scenario {
    Scenario {
        setup: FIX_TOOL,
        ..simple(id, zanshin, cli)
    }
}

/// fix: the default source, `-s`, a path, `--include-unchanged-files`, nothing to fix, a failing
/// tool, no tools, and the deprecated `line-range-arg` on `fix` and on another verb.
fn fix_scenarios() -> Vec<Scenario> {
    vec![
        fix_tool(
            "fix_default",
            |repo, _, _| fix_outcome(repo, &FixOptions::default()),
            |_| args(&["fix"]),
        ),
        fix_tool(
            "fix_source",
            |repo, _, s| {
                let options = FixOptions {
                    source: vec![s.change("B")],
                    ..FixOptions::default()
                };
                fix_outcome(repo, &options)
            },
            |s| verb_argv(s, "fix", &[("-s", "B")], &[]),
        ),
        fix_tool(
            "fix_path",
            |repo, _, _| {
                let options = FixOptions {
                    paths: vec!["b.txt".to_owned()],
                    ..FixOptions::default()
                };
                fix_outcome(repo, &options)
            },
            |_| args(&["fix", "b.txt"]),
        ),
        // `-s C`: without the flag only C's own `c.txt` is fixed; with it `a.txt` and `b.txt` too
        // (from the source alone every descendant inherits its ancestors' fixes anyway).
        fix_tool(
            "fix_include_unchanged_files",
            |repo, _, s| {
                let options = FixOptions {
                    source: vec![s.change("C")],
                    include_unchanged_files: true,
                    ..FixOptions::default()
                };
                fix_outcome(repo, &options)
            },
            |s| verb_argv(s, "fix", &[("-s", "C")], &["--include-unchanged-files"]),
        ),
        Scenario {
            setup: FIX_TOOL_APPLIED,
            ..simple(
                "fix_nothing_to_fix",
                |repo, _, _| fix_outcome(repo, &FixOptions::default()),
                |_| args(&["fix"]),
            )
        },
        Scenario {
            setup: FIX_TOOL_FAILING,
            ..simple(
                "fix_failing_tool",
                |repo, _, _| fix_outcome(repo, &FixOptions::default()),
                |_| args(&["fix"]),
            )
        },
        simple(
            "fix_no_tools_refused",
            |repo, _, _| fix_outcome(repo, &FixOptions::default()),
            |_| args(&["fix"]),
        ),
        Scenario {
            setup: FIX_TOOL_DEPRECATED,
            ..simple(
                "fix_deprecated_line_range_arg",
                |repo, _, _| fix_outcome(repo, &FixOptions::default()),
                |_| args(&["fix"]),
            )
        },
        Scenario {
            setup: FIX_TOOL_DEPRECATED,
            ..simple(
                "snapshot_deprecated_line_range_arg",
                |repo, _, _| {
                    let result = repo.snapshot();
                    zanshin_outcome(repo, &result)
                },
                |_| args(&["util", "snapshot"]),
            )
        },
    ]
}
