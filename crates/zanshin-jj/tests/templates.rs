// SPDX-License-Identifier: MIT

//! Story 9.51 — `templates.commit_trailers`, `templates.draft_commit_description`,
//! `template-aliases.default_commit_description` and `templates.new_description` in the describing
//! verbs, one witness per row of the I/O matrix, read back through jj-lib. The `git push --change`
//! rows (`templates.git_push_bookmark`) live in `tests/push.rs`; the CLI comparison of every row in
//! the parity oracle (`crates/zanshin-parity`).
//!
//! Every repo is built in-test with Zanshin's own verbs on a non-colocated internal-git repo:
//! `A (a.txt) → B (b.txt) → C (c.txt, c2.txt) = @`, descriptions `A\n`, `B\n`, `C\n` — then the
//! row's templates are set in the repo config (`config set --repo`), so the base itself carries no
//! trailer.

use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock};
use std::{env, fs};

use jj_lib::commit::Commit;
use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{
    Backend, ChangeId, CommitOptions, ConfigScope, ConfigTarget, MutateError, PreconditionError, Repo,
    SparseInheritance, SplitOptions, SquashOptions, WarningKind,
};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // SAFETY: every test calls `pin_env()` FIRST; the `LazyLock` blocks them all until this
    // initialiser returns, so no test body has read the environment yet.
    unsafe {
        for (name, value) in test_helpers::TEST_ENV {
            env::set_var(name, value);
        }
        env::set_var("XDG_CONFIG_HOME", test_helpers::leaked_xdg_config_home());
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

/// The pinned identity's `format_signed_off_by_trailer(self)`.
const SOB: &str = "Signed-off-by: Zanshin <zanshin@localhost>";

/// `templates.commit_trailers = format_signed_off_by_trailer(self)`.
const TRAILERS: (&str, &str) = ("templates.commit_trailers", "format_signed_off_by_trailer(self)");

struct Fx {
    _tmp: TempDir,
    root: PathBuf,
    repo: Repo,
    b: ChangeId,
    c: ChangeId,
}

impl Fx {
    /// `config set --repo <key> <value>`, the value parsed like the CLI's.
    fn set(&self, (key, value): (&str, &str)) {
        zanshin_jj::config_set(Some(&self.root), &ConfigTarget::Scope(ConfigScope::Repo), key, value)
            .result
            .expect("config set");
    }

    fn description(&self, id: &ChangeId) -> String {
        commit(&self.root, id).description().to_owned()
    }

    fn wc(&self) -> Commit {
        wc_of(&self.root, "default")
    }

    fn head_op(&self) -> (String, String) {
        let (_workspace, repo) = load(&self.root);
        (repo.op_id().hex(), repo.operation().metadata().description.clone())
    }

    /// Runs `verb`, which must refuse with `jj.config_error`'s CLI text `reason` and write nothing.
    fn assert_config_refusal(&mut self, reason: &str, verb: impl FnOnce(&mut Repo) -> Result<(), MutateError>) {
        let before = self.head_op();
        let err = verb(&mut self.repo).expect_err("refused");
        assert!(
            matches!(&err, MutateError::Config { reason: r } if r.lines().next() == Some(reason)),
            "{err:?}"
        );
        assert_eq!(self.head_op(), before, "a refusal writes no operation");
    }
}

fn load(root: &Path) -> (Workspace, Arc<ReadonlyRepo>) {
    let workspace = Workspace::load(
        &test_helpers::test_settings(),
        root,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &jj_lib::default_backend_factories::default_working_copy_factories(),
    )
    .expect("load workspace");
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("load head");
    (workspace, repo)
}

fn wc_of(root: &Path, name: &str) -> Commit {
    let (_workspace, repo) = load(root);
    let id = repo
        .view()
        .get_wc_commit_id(WorkspaceName::new(name))
        .expect("workspace has an @")
        .clone();
    repo.store().get_commit(&id).expect("@ commit")
}

fn change_id(commit: &Commit) -> ChangeId {
    ChangeId(commit.change_id().reverse_hex())
}

fn commit(root: &Path, id: &ChangeId) -> Commit {
    let (_workspace, repo) = load(root);
    let jj_id = jj_lib::backend::ChangeId::try_from_reverse_hex(&id.0).expect("reverse hex");
    let targets = pollster::block_on(repo.resolve_change_id(&jj_id))
        .expect("index")
        .expect("known");
    let visible = targets.into_visible().expect("visible");
    let [commit_id] = visible.as_slice() else {
        panic!("divergent {id:?}");
    };
    repo.store().get_commit(commit_id).expect("commit")
}

/// The base history, then `config` set in the repo config.
fn base(config: &[(&str, &str)]) -> Fx {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let main = tmp.path().join("main");
    fs::create_dir(&main).expect("main dir");
    let mut repo = Repo::init(&zanshin_jj::InitOptions {
        path: main,
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("init");
    let root = repo.workspace_root().to_owned();
    let step = |repo: &mut Repo, files: &[(&str, &str)], description: &str| -> ChangeId {
        for (path, text) in files {
            fs::write(root.join(path), text).expect("write");
        }
        let at = change_id(&wc_of(&root, "default"));
        repo.describe(at.clone(), description).expect("describe");
        at
    };
    let a = step(&mut repo, &[("a.txt", "a\n")], "A\n");
    repo.new_change(std::slice::from_ref(&a), &[], &[]).expect("new");
    let b = step(&mut repo, &[("b.txt", "b\n")], "B\n");
    repo.new_change(std::slice::from_ref(&b), &[], &[]).expect("new");
    let c = step(&mut repo, &[("c.txt", "c\n"), ("c2.txt", "c2\n")], "C\n");
    let _ = repo.take_warnings();
    let fx = Fx {
        _tmp: tmp,
        root,
        repo,
        b,
        c,
    };
    for entry in config {
        fx.set(*entry);
    }
    fx
}

fn sob(text: &str) -> String {
    format!("{text}\n\n{SOB}\n")
}

// ── describe ─────────────────────────────────────────────────────────────────────

#[test]
fn describe_adds_the_trailers_to_a_non_empty_description() {
    let mut fx = base(&[TRAILERS]);
    let at = fx.c.clone();
    fx.repo.describe(at.clone(), "T\n").expect("describe");
    assert_eq!(fx.description(&at), sob("T"));
}

#[test]
fn describe_with_an_empty_description_adds_no_trailer() {
    let mut fx = base(&[TRAILERS]);
    let at = fx.c.clone();
    fx.repo.describe(at.clone(), "").expect("describe");
    assert_eq!(fx.description(&at), "");
}

#[test]
fn a_trailer_already_present_is_not_added_again() {
    let mut fx = base(&[TRAILERS]);
    let at = fx.c.clone();
    fx.repo.describe(at.clone(), &sob("T")).expect("describe");
    assert_eq!(fx.description(&at), sob("T"));
}

// ── new ──────────────────────────────────────────────────────────────────────────

#[test]
fn new_renders_new_description_and_adds_the_trailers() {
    let mut fx = base(&[("templates.new_description", "'\"N\"'")]);
    let parent = fx.c.clone();
    fx.repo
        .new_change(std::slice::from_ref(&parent), &[], &[])
        .expect("new");
    assert_eq!(fx.wc().description(), "N\n");
    fx.set(TRAILERS);
    fx.repo
        .new_change(std::slice::from_ref(&parent), &[], &[])
        .expect("new");
    assert_eq!(fx.wc().description(), sob("N"));
}

#[test]
fn new_with_the_defaults_stays_undescribed() {
    let mut fx = base(&[TRAILERS]);
    let parent = fx.c.clone();
    fx.repo
        .new_change(std::slice::from_ref(&parent), &[], &[])
        .expect("new");
    assert_eq!(fx.wc().description(), "");
}

// ── commit / workspace add ───────────────────────────────────────────────────────

#[test]
fn commit_adds_the_trailers_to_the_committed_description() {
    let mut fx = base(&[TRAILERS]);
    let committed = fx.c.clone();
    fx.repo
        .commit(&CommitOptions {
            paths: Vec::new(),
            message: vec!["T".to_owned()],
        })
        .expect("commit");
    assert_eq!(fx.description(&committed), sob("T"));
    assert_eq!(fx.wc().description(), "");
}

#[test]
fn workspace_add_adds_the_trailers_to_the_new_workspaces_at() {
    let mut fx = base(&[TRAILERS]);
    let result = fx
        .repo
        .workspace_add("../ws2", None, &[], &["W".to_owned()], None, SparseInheritance::Copy)
        .expect("workspace add");
    assert_eq!(wc_of(&fx.root, &result.workspace_name).description(), sob("W"));
}

// ── squash ───────────────────────────────────────────────────────────────────────

#[test]
fn squash_with_a_message_adds_the_trailers() {
    let mut fx = base(&[TRAILERS]);
    fx.repo
        .squash(&SquashOptions {
            message: Some(vec!["S".to_owned()]),
            ..SquashOptions::default()
        })
        .expect("squash");
    let b = fx.b.clone();
    assert_eq!(fx.description(&b), sob("S"));
}

#[test]
fn squash_editor_arm_writes_the_combined_text_with_the_missing_trailers() {
    let mut fx = base(&[TRAILERS]);
    let plan = fx.repo.squash_plan(&SquashOptions::default()).expect("plan");
    let expected = format!("B\n\nC\n\n{SOB}\n");
    assert_eq!(plan.combined_description.as_deref(), Some(expected.as_str()));
    fx.repo.squash(&SquashOptions::default()).expect("squash");
    let b = fx.b.clone();
    assert_eq!(fx.description(&b), expected);
}

#[test]
fn a_custom_draft_template_shapes_the_editor_text() {
    let mut fx = base(&[("templates.draft_commit_description", "concat(\"pre\\n\", description)")]);
    let plan = fx.repo.squash_plan(&SquashOptions::default()).expect("plan");
    assert_eq!(plan.combined_description.as_deref(), Some("pre\nB\n\nC\n"));
    fx.repo.squash(&SquashOptions::default()).expect("squash");
    let b = fx.b.clone();
    assert_eq!(fx.description(&b), "pre\nB\n\nC\n");
}

// ── split ────────────────────────────────────────────────────────────────────────

fn split_c(message: Option<&str>) -> SplitOptions {
    SplitOptions {
        paths: vec!["c.txt".to_owned()],
        message: message.map(|m| vec![m.to_owned()]),
        ..SplitOptions::default()
    }
}

#[test]
fn split_with_a_message_adds_the_trailers_to_the_first_commit_only() {
    let mut fx = base(&[TRAILERS]);
    let result = fx.repo.split(&split_c(Some("first"))).expect("split");
    assert_eq!(fx.description(&result.selected_change_id), sob("first"));
    assert_eq!(fx.description(&result.remaining_change_id), "C\n");
}

#[test]
fn split_editor_arm_adds_the_trailers_to_both_commits() {
    let mut fx = base(&[TRAILERS]);
    let result = fx.repo.split(&split_c(None)).expect("split");
    assert_eq!(fx.description(&result.selected_change_id), sob("C"));
    assert_eq!(fx.description(&result.remaining_change_id), sob("C"));
}

#[test]
fn split_editor_arm_of_an_undescribed_commit_uses_default_commit_description() {
    for (config, expected) in [
        (&[][..], ""),
        (
            &[("template-aliases.default_commit_description", "'\"DEF\\n\"'")][..],
            "DEF\n",
        ),
    ] {
        let mut fx = base(config);
        let at = fx.c.clone();
        fx.repo.new_change(std::slice::from_ref(&at), &[], &[]).expect("new");
        fs::write(fx.root.join("x.txt"), "x\n").expect("write");
        fs::write(fx.root.join("y.txt"), "y\n").expect("write");
        let result = fx
            .repo
            .split(&SplitOptions {
                paths: vec!["x.txt".to_owned()],
                ..SplitOptions::default()
            })
            .expect("split");
        assert_eq!(fx.description(&result.selected_change_id), expected);
        assert_eq!(fx.description(&result.remaining_change_id), expected);
    }
}

// ── refusals and warnings ────────────────────────────────────────────────────────

/// A `templates.commit_trailers` that does not parse refuses every describing verb with the CLI's
/// text before anything is written.
#[test]
fn a_broken_trailers_template_refuses_before_any_write() {
    const REASON: &str = "Failed to parse template: Syntax error";
    let mut fx = base(&[
        ("templates.commit_trailers", "nope("),
        ("templates.new_description", "'\"N\"'"),
    ]);
    let (b, c) = (fx.b.clone(), fx.c.clone());
    fx.assert_config_refusal(REASON, |repo| repo.describe(c.clone(), "").map(drop));
    fx.assert_config_refusal(REASON, |repo| {
        repo.commit(&CommitOptions {
            paths: Vec::new(),
            message: vec!["T".to_owned()],
        })
        .map(drop)
    });
    fx.assert_config_refusal(REASON, |repo| repo.squash(&SquashOptions::default()).map(drop));
    fx.assert_config_refusal(REASON, |repo| repo.squash_plan(&SquashOptions::default()).map(drop));
    fx.assert_config_refusal(REASON, |repo| repo.split(&split_c(Some("first"))).map(drop));
    fx.assert_config_refusal(REASON, |repo| {
        repo.new_change(std::slice::from_ref(&b), &[], &[]).map(drop)
    });
}

/// `workspace add` refuses where the CLI refuses: after jj-lib's `add workspace` operation, before
/// the initial working-copy commit's.
#[test]
fn a_broken_trailers_template_refuses_workspace_add_before_its_transaction() {
    let mut fx = base(&[("templates.commit_trailers", "nope(")]);
    let err = fx
        .repo
        .workspace_add("../ws2", None, &[], &["W".to_owned()], None, SparseInheritance::Copy)
        .expect_err("refused");
    assert!(
        matches!(&err, MutateError::Config { reason } if reason.starts_with("Failed to parse template: Syntax error\n")),
        "{err:?}"
    );
    assert_eq!(fx.head_op().1, "add workspace 'ws2'");
}

/// A template alias entry that does not load warns once and the verb runs.
#[test]
fn a_bad_template_alias_entry_warns_and_the_verb_runs() {
    let mut fx = base(&[TRAILERS, ("template-aliases.'x('", "'1'")]);
    let at = fx.c.clone();
    fx.repo.describe(at.clone(), "T\n").expect("describe");
    assert_eq!(fx.description(&at), sob("T"));
    let invalid: Vec<String> = fx
        .repo
        .take_warnings()
        .into_iter()
        .filter(|w| w.kind == WarningKind::ConfigAliasInvalid)
        .map(|w| w.message)
        .collect();
    assert_eq!(invalid.len(), 1, "{invalid:?}");
    assert!(
        invalid[0].starts_with("Failed to load `template-aliases.x(`: "),
        "{invalid:?}"
    );
}

/// An empty single description is written as it is — no trailer (`squash.rs:365-367`).
#[test]
fn squash_with_an_empty_message_adds_no_trailer() {
    let mut fx = base(&[TRAILERS]);
    let options = SquashOptions {
        message: Some(vec![String::new()]),
        ..SquashOptions::default()
    };
    let plan = fx.repo.squash_plan(&options).expect("plan");
    assert_eq!(plan.combined_description, None);
    fx.repo.squash(&options).expect("squash");
    let b = fx.b.clone();
    assert_eq!(fx.description(&b), "");
}

// ── The template half of the start-up environment (Story 9.51 closing run) ──────────
//
// The CLI loads `[template-aliases]` and parses `revsets.short-prefixes` at the start of EVERY
// workspace command (`WorkspaceCommandEnvironment::new`, `cli_util.rs:961-991` @ v0.46.0), so a
// verb that renders no template — `abandon` here — refuses and warns on them too.

/// `revsets.short-prefixes = diff_contains("x")` — parses, with a deprecation diagnostic.
const DIAGNOSED_SHORT_PREFIXES: &str = "diff_contains(\"x\")";

impl Fx {
    /// Runs `abandon(@)`, which must refuse at the start-up environment with a
    /// `PreconditionError::Config` whose reason satisfies `check`, and write nothing.
    fn assert_start_up_refusal(&mut self, check: impl Fn(&str) -> bool) {
        let before = self.head_op();
        let at = self.c.clone();
        let err = self.repo.abandon(&[at]).expect_err("refused");
        assert!(
            matches!(&err, MutateError::Precondition(PreconditionError::Config { reason }) if check(reason)),
            "{err:?}"
        );
        assert_eq!(self.head_op(), before, "a refusal writes no operation");
    }
}

/// The warnings of `kind` whose message starts with `prefix`.
fn warnings_of(warnings: &[zanshin_jj::Warning], kind: WarningKind, prefix: &str) -> usize {
    warnings
        .iter()
        .filter(|w| w.kind == kind && w.message.starts_with(prefix))
        .count()
}

/// A `template-aliases` layer that is not a table refuses a verb that renders no template.
#[test]
fn a_broken_template_alias_table_refuses_every_verb() {
    let mut fx = base(&[("template-aliases", "1")]);
    fx.assert_start_up_refusal(|reason| reason.ends_with("template-aliases: Expected a table, but is integer"));
}

/// A `revsets.short-prefixes` that does not parse refuses a verb that renders no template.
#[test]
fn an_unparsable_short_prefixes_refuses_every_verb() {
    let mut fx = base(&[("revsets.short-prefixes", "'('")]);
    fx.assert_start_up_refusal(|reason| reason.starts_with("Invalid `revsets.short-prefixes`: "));
}

/// A `revsets.short-prefixes` that is not a string refuses, naming the key.
#[test]
fn a_non_string_short_prefixes_refuses_every_verb() {
    let mut fx = base(&[("revsets.short-prefixes", "1")]);
    fx.assert_start_up_refusal(|reason| reason.contains("revsets.short-prefixes"));
}

/// A bad template alias entry warns exactly once on a verb that renders no template, and the
/// verb runs.
#[test]
fn a_bad_template_alias_entry_warns_once_on_every_verb() {
    let mut fx = base(&[("template-aliases.'x('", "'1'")]);
    let at = fx.c.clone();
    fx.repo.abandon(&[at]).expect("abandon");
    let warnings = fx.repo.take_warnings();
    assert_eq!(
        warnings_of(
            &warnings,
            WarningKind::ConfigAliasInvalid,
            "Failed to load `template-aliases.x(`: "
        ),
        1,
        "{warnings:?}"
    );
}

/// A diagnosed `revsets.short-prefixes` warns exactly once on a verb that renders no template.
#[test]
fn short_prefixes_diagnostics_warn_once_on_every_verb() {
    let mut fx = base(&[("revsets.short-prefixes", &format!("'{DIAGNOSED_SHORT_PREFIXES}'"))]);
    let at = fx.c.clone();
    fx.repo.abandon(&[at]).expect("abandon");
    let warnings = fx.repo.take_warnings();
    assert_eq!(
        warnings_of(
            &warnings,
            WarningKind::RevsetDiagnostic,
            "In `revsets.short-prefixes`\n"
        ),
        1,
        "{warnings:?}"
    );
}

/// The graph walk passed the effective short-prefixes text (what `log_defaults` returns) warns
/// once, as `jj log` does — its own parse of the same text is the start-up's.
#[test]
fn the_graph_walk_with_the_effective_short_prefixes_warns_once() {
    let mut fx = base(&[("revsets.short-prefixes", &format!("'{DIAGNOSED_SHORT_PREFIXES}'"))]);
    let flow = fx
        .repo
        .walk_graph(
            "all()",
            zanshin_jj::DEFAULT_GRAPH_PRIORITIZE,
            DIAGNOSED_SHORT_PREFIXES,
            |_| std::ops::ControlFlow::Continue(()),
        )
        .expect("graph");
    assert_eq!(flow, std::ops::ControlFlow::Continue(()));
    let warnings = fx.repo.take_warnings();
    assert_eq!(
        warnings_of(
            &warnings,
            WarningKind::RevsetDiagnostic,
            "In `revsets.short-prefixes`\n"
        ),
        1,
        "{warnings:?}"
    );
}
