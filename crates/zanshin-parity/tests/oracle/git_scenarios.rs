// SPDX-License-Identifier: MIT

//! Story 9.20's scenarios: `jj git init` / `jj git clone` — creation scenarios, where the call
//! creates the repo, so there is no shared history — and `jj git push`, table scenarios on the
//! BASE history against a bare remote beside the repo; Story 9.30 adds `jj git fetch` on the same
//! remotes.

use std::path::Path;
use std::path::PathBuf;

use zanshin_jj::FetchRefs;
use zanshin_jj::FetchRemotes;
use zanshin_jj::GitFetchArgs;
use zanshin_jj::GitPushArgs;
use zanshin_jj::ProgressEvent;

use crate::compare::Outcome;
use crate::driver::git;
use crate::driver::jj;
use crate::driver::Step;
use crate::scenarios::Scenario;
use crate::scenarios::GIT_INIT;

/// One step in the empty temp dir before a creation, identical on both sides.
pub enum Prep {
    /// `git <args>` in the temp dir.
    Git(&'static [&'static str]),
    /// Writes a file (relative to the temp dir), creating its parent directories.
    Write(&'static str, &'static str),
}

/// A creation through Zanshin (temp dir A) against `jj <cli>` (temp dir B, run there).
pub struct CreationScenario {
    pub id: &'static str,
    pub prep: &'static [Prep],
    /// Where the workspace lands, relative to the temp dir (`""` = the temp dir itself).
    pub target: &'static str,
    pub cli: &'static [&'static str],
    /// The Zanshin call, given the temp dir.
    pub zanshin: fn(&Path) -> zanshin_jj::CreationOutcome,
    /// A user config file both calls run under (`JJ_CONFIG`, Story 9.57), or `None` for the
    /// pinned empty one. A scenario with one changes the process environment, so it runs in a
    /// process of its own (`main.rs`'s `own_process` list); the read-back runs without it.
    pub user_config: Option<&'static str>,
}

/// Runs `prep` in `dir`.
pub fn prepare(dir: &Path, prep: &[Prep]) {
    for step in prep {
        match step {
            Prep::Git(args) => {
                git(dir, args);
            }
            Prep::Write(path, text) => {
                let path = dir.join(path);
                std::fs::create_dir_all(path.parent().expect("a parent")).expect("parent dirs");
                std::fs::write(path, text).expect("write a prep file");
            }
        }
    }
}

/// A Git repository `src` with one commit `A` on `main` and a second branch `other`.
const SOURCE: &[Prep] = &[
    Prep::Git(&["init", "-q", "-b", "main", "src"]),
    Prep::Write("src/a.txt", "a\n"),
    Prep::Git(&["-C", "src", "add", "."]),
    Prep::Git(&["-C", "src", "commit", "-q", "-m", "A"]),
    Prep::Git(&["-C", "src", "branch", "other"]),
];

/// A Git repository in the temp dir itself, with one commit `A` on `main`.
const GIT_HERE: &[Prep] = &[
    Prep::Git(&["init", "-q", "-b", "main"]),
    Prep::Write("a.txt", "a\n"),
    Prep::Git(&["add", "."]),
    Prep::Git(&["commit", "-q", "-m", "A"]),
];

fn init(path: PathBuf, colocate: Option<bool>) -> zanshin_jj::CreationOutcome {
    zanshin_jj::Repo::init(&zanshin_jj::InitOptions {
        path,
        backend: Some(zanshin_jj::Backend::Git),
        colocate,
        ..Default::default()
    })
}

fn clone(options: &zanshin_jj::CloneOptions) -> zanshin_jj::CreationOutcome {
    zanshin_jj::Repo::clone(options, &|_: ProgressEvent| {}, None)
}

/// `jj git clone <dir>/<source> <dir>/dest` with the rest of `options`.
fn clone_options(dir: &Path, source: &str) -> zanshin_jj::CloneOptions {
    zanshin_jj::CloneOptions {
        source: dir.join(source).to_str().expect("UTF-8 temp dir").to_owned(),
        destination: dir.join("dest"),
        ..Default::default()
    }
}

/// Every creation scenario.
pub const CREATION_SCENARIOS: &[CreationScenario] = &[
    CreationScenario {
        id: "init_colocated",
        prep: &[],
        target: "",
        cli: &["git", "init"],
        zanshin: |dir| init(dir.to_owned(), None),
        user_config: None,
    },
    CreationScenario {
        id: "init_no_colocate",
        prep: &[],
        target: "",
        cli: &["git", "init", "--no-colocate"],
        zanshin: |dir| init(dir.to_owned(), Some(false)),
        user_config: None,
    },
    CreationScenario {
        id: "init_missing_destination",
        prep: &[],
        target: "sub",
        cli: &["git", "init", "sub"],
        zanshin: |dir| init(dir.join("sub"), None),
        user_config: None,
    },
    CreationScenario {
        id: "init_over_git_colocate",
        prep: GIT_HERE,
        target: "",
        cli: &["git", "init"],
        zanshin: |dir| init(dir.to_owned(), None),
        user_config: None,
    },
    CreationScenario {
        id: "init_over_git_no_colocate",
        prep: GIT_HERE,
        target: "",
        cli: &["git", "init", "--no-colocate"],
        zanshin: |dir| init(dir.to_owned(), Some(false)),
        user_config: None,
    },
    CreationScenario {
        id: "clone_default",
        prep: SOURCE,
        target: "dest",
        cli: &["git", "clone", "src", "dest"],
        zanshin: |dir| clone(&clone_options(dir, "src")),
        user_config: None,
    },
    CreationScenario {
        id: "clone_no_colocate",
        prep: SOURCE,
        target: "dest",
        cli: &["git", "clone", "--no-colocate", "src", "dest"],
        zanshin: |dir| {
            clone(&zanshin_jj::CloneOptions {
                colocate: Some(false),
                ..clone_options(dir, "src")
            })
        },
        user_config: None,
    },
    CreationScenario {
        id: "clone_remote_name",
        prep: SOURCE,
        target: "dest",
        cli: &["git", "clone", "--remote", "up", "src", "dest"],
        zanshin: |dir| {
            clone(&zanshin_jj::CloneOptions {
                remote_name: Some("up".to_owned()),
                ..clone_options(dir, "src")
            })
        },
        user_config: None,
    },
    CreationScenario {
        id: "clone_branch",
        prep: SOURCE,
        target: "dest",
        cli: &["git", "clone", "-b", "main", "src", "dest"],
        zanshin: |dir| {
            clone(&zanshin_jj::CloneOptions {
                branches: Some(vec!["main".to_owned()]),
                ..clone_options(dir, "src")
            })
        },
        user_config: None,
    },
    CreationScenario {
        id: "clone_empty_source",
        prep: &[Prep::Git(&["init", "-q", "-b", "main", "src"])],
        target: "dest",
        cli: &["git", "clone", "src", "dest"],
        zanshin: |dir| clone(&clone_options(dir, "src")),
        user_config: None,
    },
    CreationScenario {
        id: "clone_non_empty_destination",
        prep: &[
            Prep::Git(&["init", "-q", "-b", "main", "src"]),
            Prep::Write("dest/keep.txt", "keep\n"),
        ],
        target: "dest",
        cli: &["git", "clone", "src", "dest"],
        zanshin: |dir| clone(&clone_options(dir, "src")),
        user_config: None,
    },
    // ── Story 9.57: `convert` leaves on disk what `jj git init` leaves ──────────
    CreationScenario {
        id: "convert_colocated_default",
        prep: GIT_HERE,
        target: "",
        cli: &["git", "init", "--colocate"],
        zanshin: |dir| zanshin_jj::convert_colocated(dir),
        user_config: None,
    },
    CreationScenario {
        id: "convert_import_default",
        prep: SOURCE,
        target: "dest",
        cli: &["git", "init", "--git-repo", "src", "dest"],
        zanshin: |dir| zanshin_jj::convert_import(&dir.join("src"), &dir.join("dest")),
        user_config: None,
    },
    // A `src/.git` without objects: `init_external_git` fails, jj-lib removes the `.jj` it
    // started, and the destination the call created stays — on both sides.
    CreationScenario {
        id: "convert_import_invalid_source",
        prep: &[Prep::Write("src/.git/description", "no objects\n")],
        target: "dest",
        cli: &["git", "init", "--git-repo", "src", "dest"],
        zanshin: |dir| zanshin_jj::convert_import(&dir.join("src"), &dir.join("dest")),
        user_config: None,
    },
    // ── Story 9.58: the destination is created one level deep ───────────────────
    // A missing parent: both refuse "Failed to create workspace" and create nothing — the target
    // is the parent, so a created parent would diverge.
    CreationScenario {
        id: "convert_import_missing_parent",
        prep: SOURCE,
        target: "missing",
        cli: &["git", "init", "--git-repo", "src", "missing/dest"],
        zanshin: |dir| zanshin_jj::convert_import(&dir.join("src"), &dir.join("missing").join("dest")),
        user_config: None,
    },
    // An `immutable_heads()` that parses but does not resolve: the non-colocated `import git
    // head` finish (`tx.finish`) refuses `Config error` after `.jj/` exists, on both sides.
    CreationScenario {
        id: "convert_import_unresolvable_immutable",
        prep: SOURCE,
        target: "dest",
        cli: &["git", "init", "--git-repo", "src", "dest"],
        zanshin: |dir| zanshin_jj::convert_import(&dir.join("src"), &dir.join("dest")),
        user_config: Some(UNRESOLVABLE_IMMUTABLE),
    },
    // The colocated flow runs no `tx.finish`: the same alias does not refuse it.
    CreationScenario {
        id: "convert_colocated_unresolvable_immutable",
        prep: GIT_HERE,
        target: "",
        cli: &["git", "init", "--colocate"],
        zanshin: |dir| zanshin_jj::convert_colocated(dir),
        user_config: Some(UNRESOLVABLE_IMMUTABLE),
    },
    // The refs step cannot load its import options (`init_git_refs`): both refuse after
    // `init_external_git` succeeded, and the `.jj/` stays.
    CreationScenario {
        id: "convert_import_refs_step_config_fault",
        prep: SOURCE,
        target: "dest",
        cli: &["git", "init", "--git-repo", "src", "dest"],
        zanshin: |dir| zanshin_jj::convert_import(&dir.join("src"), &dir.join("dest")),
        user_config: Some(BROKEN_AUTO_TRACK),
    },
    // The same refs-step fault in the colocated flow — the only conversion the FFI exposes.
    CreationScenario {
        id: "convert_colocated_refs_step_config_fault",
        prep: GIT_HERE,
        target: "",
        cli: &["git", "init", "--colocate"],
        zanshin: |dir| zanshin_jj::convert_colocated(dir),
        user_config: Some(BROKEN_AUTO_TRACK),
    },
    // ── Story 9.57 closing run: the clone's finish refuses an unresolvable alias ──
    // The first finish with changes (`add git remote origin`) refuses `Config error` inside the
    // clean-up scope, which removes the destination the clone created — on both sides.
    CreationScenario {
        id: "clone_unresolvable_immutable",
        prep: SOURCE,
        target: "dest",
        cli: &["git", "clone", "src", "dest"],
        zanshin: |dir| clone(&clone_options(dir, "src")),
        user_config: Some(UNRESOLVABLE_IMMUTABLE),
    },
];

/// A user config whose `remotes.origin.auto-track-bookmarks` does not parse.
const BROKEN_AUTO_TRACK: &str = "[remotes.origin]\nauto-track-bookmarks = \"glob:(\"\n";

/// A user config whose `immutable_heads()` parses but names a symbol that does not exist.
const UNRESOLVABLE_IMMUTABLE: &str = "[revset-aliases]\n'immutable_heads()' = 'nonexistent_symbol_xyz'\n";

/// The created repo's own config (`jj config list --repo`, the repo presets) and its bookmarks
/// with their remotes, read back through the CLI; the temp dir is replaced by `<tmp>` (the two
/// sides live in different temp dirs).
pub fn creation_read_back(dir: &Path, target: &Path) -> String {
    let config = jj(target, &["config", "list", "--repo"]);
    let bookmarks = jj(target, &["bookmark", "list", "--all-remotes", "-T", BOOKMARK_TEMPLATE]);
    let text = format!(
        "config={:?} bookmarks={:?}",
        if config.success { config.stdout } else { config.stderr },
        bookmarks.stdout
    );
    text.replace(dir.to_str().expect("UTF-8 temp dir"), "<tmp>")
}

/// One line per bookmark: `name[@remote] [tracked] -> first line of its description`.
const BOOKMARK_TEMPLATE: &str = r#"name ++ if(remote, "@" ++ remote) ++ if(tracked, " tracked") ++ " -> " ++ normal_target.description().first_line() ++ "\n""#;

// ── jj git push ──────────────────────────────────────────────────────────────

/// A bare remote `origin` beside the repo (`../remote.git`).
const REMOTE: &[Step] = &[
    Step::Git(&["init", "-q", "--bare", "../remote.git"]),
    Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
];

/// [`REMOTE`] with `b-mark` pushed (and so tracked).
const PUSHED: &[Step] = &[
    Step::Git(&["init", "-q", "--bare", "../remote.git"]),
    Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
    Step::Jj(&["git", "push", "-b", "b-mark"]),
];

/// The remote side after the push: the repo's bookmarks with their remotes, and every ref of
/// each bare remote by the subject of the commit it points at (commit ids differ between the
/// two sides: BASE is built per side).
fn push_read_back(root: &Path) -> String {
    let bookmarks = jj(root, &["bookmark", "list", "--all-remotes", "-T", BOOKMARK_TEMPLATE])
        .ok()
        .stdout;
    let mut text = format!("bookmarks={bookmarks:?}");
    for remote in ["remote.git", "remote2.git"] {
        let dir = root.join("..").join(remote);
        if dir.is_dir() {
            let refs = git(&dir, &["for-each-ref", "--format=%(refname) %(subject)"]);
            text = format!("{text} {remote}={refs:?}");
        }
    }
    text
}

/// `Repo::git_push` with `args`; a push that failed once the network was involved (failure as
/// data) is a refusal, as the CLI's non-zero exit.
fn push_outcome(repo: &mut zanshin_jj::Repo, args: &GitPushArgs) -> Outcome {
    let result = repo.git_push(args, &|_: ProgressEvent| {}, None);
    Outcome {
        refused: result.as_ref().map_or(true, |outcome| outcome.failure.is_some()),
        warnings: repo.take_warnings().len(),
    }
}

fn strings(items: &[&str]) -> Vec<String> {
    items.iter().map(|item| (*item).to_owned()).collect()
}

/// A push scenario on BASE + `setup`, compared with [`push_read_back`].
fn push(
    id: &'static str,
    setup: &'static [Step],
    zanshin: fn(&mut zanshin_jj::Repo, &Path, &crate::state::State) -> Outcome,
    cli: fn(&crate::state::State) -> Vec<String>,
) -> Scenario {
    Scenario {
        id,
        init: GIT_INIT,
        setup,
        files: &[],
        zanshin,
        cli,
        extra: Some(push_read_back),
    }
}

/// Every push scenario.
#[allow(clippy::too_many_lines)] // WHY: one flat table reads better than 21 helper fns
pub fn push_scenarios() -> Vec<Scenario> {
    vec![
        push(
            "push_bare",
            REMOTE,
            |repo, _, _| push_outcome(repo, &GitPushArgs::default()),
            |_| strings(&["git", "push"]),
        ),
        push(
            "push_bookmark",
            REMOTE,
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        bookmarks: strings(&["b-mark"]),
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "-b", "b-mark"]),
        ),
        push(
            "push_all",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&["bookmark", "create", "c-mark", "-r", "@"]),
            ],
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        all: true,
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "--all"]),
        ),
        push(
            "push_tracked",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&["git", "push", "-b", "b-mark"]),
                Step::Jj(&["bookmark", "set", "b-mark", "-r", "@"]),
                Step::Jj(&["bookmark", "create", "c-mark", "-r", "@"]),
            ],
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        tracked: true,
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "--tracked"]),
        ),
        push(
            "push_deleted",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&["git", "push", "-b", "b-mark"]),
                Step::Jj(&["bookmark", "delete", "b-mark"]),
            ],
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        deleted: true,
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "--deleted"]),
        ),
        push(
            "push_change",
            REMOTE,
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        changes: strings(&["@"]),
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "-c", "@"]),
        ),
        push(
            "push_named",
            REMOTE,
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        named: strings(&["feat=@"]),
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "--named", "feat=@"]),
        ),
        push(
            "push_dry_run",
            REMOTE,
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        bookmarks: strings(&["b-mark"]),
                        dry_run: true,
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "--dry-run", "-b", "b-mark"]),
        ),
        push(
            "push_nothing_changed",
            PUSHED,
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        bookmarks: strings(&["b-mark"]),
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "-b", "b-mark"]),
        ),
        push(
            "push_unmatched_remote",
            REMOTE,
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        remotes: Some(strings(&["origin", "nope"])),
                        bookmarks: strings(&["b-mark"]),
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "--remote", "origin", "--remote", "nope", "-b", "b-mark"]),
        ),
        push(
            "push_no_matching_remote",
            REMOTE,
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        remotes: Some(strings(&["nope"])),
                        bookmarks: strings(&["b-mark"]),
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "--remote", "nope", "-b", "b-mark"]),
        ),
        push(
            "push_skip_undescribed",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&["new"]),
                Step::Jj(&["bookmark", "create", "d-mark", "-r", "@"]),
            ],
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        all: true,
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "--all"]),
        ),
        push(
            "push_abort_undescribed",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&["new"]),
                Step::Jj(&["bookmark", "create", "d-mark", "-r", "@"]),
            ],
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        bookmarks: strings(&["b-mark", "d-mark"]),
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "-b", "b-mark", "-b", "d-mark"]),
        ),
        push(
            "push_tag",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&["tag", "set", "v1", "-r", "@-"]),
            ],
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        tags: strings(&["v1"]),
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "-t", "v1"]),
        ),
        push(
            "push_two_remotes",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Git(&["init", "-q", "--bare", "../remote2.git"]),
                Step::Jj(&["git", "remote", "add", "up", "../remote2.git"]),
            ],
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        remotes: Some(strings(&["*"])),
                        bookmarks: strings(&["b-mark"]),
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "--remote", "*", "-b", "b-mark"]),
        ),
        // The default revset `remote_bookmarks(remote=origin)..@` = {C, D}: tracked `b-mark` on
        // the described C is pushed, tracked `d-mark` on the undescribed D is skipped with a
        // warning (the skip path; only tracked bookmarks get past the bare push's
        // `allow_new: false`, `push.rs:518-538` @ v0.46.0).
        push(
            "push_bare_skip_undescribed",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&["bookmark", "create", "d-mark", "-r", "@-"]),
                Step::Jj(&["git", "push", "-b", "b-mark", "-b", "d-mark"]),
                Step::Jj(&["bookmark", "set", "b-mark", "-r", "@"]),
                Step::Jj(&["new"]),
                Step::Jj(&["bookmark", "set", "d-mark", "-r", "@"]),
            ],
            |repo, _, _| push_outcome(repo, &GitPushArgs::default()),
            |_| strings(&["git", "push"]),
        ),
        // The default revset holds C with tracked `b-mark` (pushed) and the new tag `v1`, which
        // the bare push refuses: "Refusing to create new remote tag v1@origin" (`push.rs:1236`).
        push(
            "push_bare_new_tag",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&["git", "push", "-b", "b-mark"]),
                Step::Jj(&["bookmark", "set", "b-mark", "-r", "@"]),
                Step::Jj(&["tag", "set", "v1", "-r", "@"]),
            ],
            |repo, _, _| push_outcome(repo, &GitPushArgs::default()),
            |_| strings(&["git", "push"]),
        ),
        // `-r @`: tracked `b-mark` on C is pushed, the untracked `c-mark` on C is refused as a
        // new remote bookmark (`-r` classifies with `allow_new: false`).
        push(
            "push_revision",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&["git", "push", "-b", "b-mark"]),
                Step::Jj(&["bookmark", "set", "b-mark", "-r", "@"]),
                Step::Jj(&["bookmark", "create", "c-mark", "-r", "@"]),
            ],
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        revisions: strings(&["@"]),
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "-r", "@"]),
        ),
        // `--all` to both remotes: `origin` receives `b-mark` and `c-mark`, `up` refuses
        // `b-mark` with a warning — its `b-mark@up` exists but is not tracked ("Non-tracking
        // remote bookmark … exists") — and receives `c-mark`.
        push(
            "push_all_two_remotes_one_refuses",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Git(&["init", "-q", "--bare", "../remote2.git"]),
                Step::Jj(&["git", "remote", "add", "up", "../remote2.git"]),
                Step::Jj(&["git", "push", "--remote", "up", "-b", "b-mark"]),
                Step::Jj(&["bookmark", "untrack", "b-mark@up"]),
                Step::Jj(&["bookmark", "create", "c-mark", "-r", "@"]),
            ],
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        remotes: Some(strings(&["*"])),
                        all: true,
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "--remote", "*", "--all"]),
        ),
        // As above without `c-mark`: nothing is left for `up`, yet the CLI still runs
        // `git push` for it with no refspecs (`push.rs:588-615` has no empty check), which git
        // fails ("You are not currently on a branch") — after `origin` already received
        // `b-mark`, so the push is refused and no operation is written.
        push(
            "push_all_one_remote_left_empty",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Git(&["init", "-q", "--bare", "../remote2.git"]),
                Step::Jj(&["git", "remote", "add", "up", "../remote2.git"]),
                Step::Jj(&["git", "push", "--remote", "up", "-b", "b-mark"]),
                Step::Jj(&["bookmark", "untrack", "b-mark@up"]),
            ],
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        remotes: Some(strings(&["*"])),
                        all: true,
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "--remote", "*", "--all"]),
        ),
        // `--all` with `-b`: clap's group conflict (`push.rs:121-122`), refused before any work.
        push(
            "push_all_with_bookmark_refused",
            REMOTE,
            |repo, _, _| {
                push_outcome(
                    repo,
                    &GitPushArgs {
                        all: true,
                        bookmarks: strings(&["b-mark"]),
                        ..GitPushArgs::default()
                    },
                )
            },
            |_| strings(&["git", "push", "--all", "-b", "b-mark"]),
        ),
        // ── Story 9.51: `templates.git_push_bookmark` ───────────────────────
        // A customised template names the `--change` bookmark.
        push(
            "push_change_custom_template",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&[
                    "config",
                    "set",
                    "--repo",
                    "templates.git_push_bookmark",
                    "'\"mine-\" ++ change_id.short()'",
                ]),
            ],
            |repo, _, _| push_change_at(repo),
            |_| strings(&["git", "push", "-c", "@"]),
        ),
        // A template that renders nothing refuses ("Empty bookmark name generated").
        push(
            "push_change_empty_template",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&["config", "set", "--repo", "templates.git_push_bookmark", "'\"\"'"]),
            ],
            |repo, _, _| push_change_at(repo),
            |_| strings(&["git", "push", "-c", "@"]),
        ),
        // The template environment's id-prefix context: `shortest(8)` disambiguated within a custom
        // `revsets.short-prefixes` (8 characters at least, so the two sides' random change ids
        // compare by label).
        push(
            "push_change_shortest_template",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&[
                    "config",
                    "set",
                    "--repo",
                    "templates.git_push_bookmark",
                    "'\"push-\" ++ change_id.shortest(8)'",
                ]),
                Step::Jj(&["config", "set", "--repo", "revsets.short-prefixes", "@"]),
            ],
            |repo, _, _| push_change_at(repo),
            |_| strings(&["git", "push", "-c", "@"]),
        ),
        // A template that does not parse refuses.
        push(
            "push_change_broken_template",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&["config", "set", "--repo", "templates.git_push_bookmark", "nope("]),
            ],
            |repo, _, _| push_change_at(repo),
            |_| strings(&["git", "push", "-c", "@"]),
        ),
    ]
}

/// `git push -c @` through Zanshin.
fn push_change_at(repo: &mut zanshin_jj::Repo) -> Outcome {
    push_outcome(
        repo,
        &GitPushArgs {
            changes: strings(&["@"]),
            ..GitPushArgs::default()
        },
    )
}

// ── jj bookmark create: auto-tracking (Story 9.54's closing run) ─────────────

/// `bookmark create feature` through Zanshin, at `revision` (`None` = the CLI's `-r @`).
fn create_feature(repo: &mut zanshin_jj::Repo, revision: Option<&zanshin_jj::ChangeId>) -> Outcome {
    let result = repo.bookmark_create(&strings(&["feature"]), revision);
    crate::compare::zanshin_outcome(repo, &result)
}

/// `bookmark create` against a bare `origin` whose remote view `git remote add` made (and
/// `remotes.origin.*` auto-track config), read back with [`push_read_back`]: every bookmark with
/// its remotes and tracked state — a tracked, not-yet-created `feature@origin` included — and
/// the bare remote's refs.
pub fn bookmark_auto_track_scenarios() -> Vec<Scenario> {
    vec![
        // `auto-track-created-bookmarks` alone: `feature@origin` becomes a tracked row without a
        // target; nothing warns.
        push(
            "bookmark_create_auto_track_created",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&[
                    "config",
                    "set",
                    "--repo",
                    "remotes.origin.auto-track-created-bookmarks",
                    "\"*\"",
                ]),
            ],
            |repo, _, _| create_feature(repo, None),
            |_| strings(&["bookmark", "create", "feature"]),
        ),
        // An untracked `feature@origin` at B already exists (pushed, then the local bookmark
        // forgotten): creating `feature` at B warns "Auto-tracking bookmark that exists on the
        // remote: feature@origin" and tracks it; the merged local target stays B.
        push(
            "bookmark_create_auto_track_existing",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&["git", "push", "--named", "feature=@-"]),
                Step::Jj(&["bookmark", "forget", "feature"]),
                Step::Jj(&[
                    "config",
                    "set",
                    "--repo",
                    "remotes.origin.auto-track-created-bookmarks",
                    "\"*\"",
                ]),
            ],
            |repo, _, s| create_feature(repo, Some(&s.change("B"))),
            |_| strings(&["bookmark", "create", "feature", "-r", "@-"]),
        ),
        // Both fields unioned on `origin` (`feature` by `auto-track-bookmarks`, `other` by
        // `auto-track-created-bookmarks`), everything on `upstream`, and a matching `ghost` that
        // has no remote view: `feature` and `other` on both remotes, `third` on `upstream` only.
        push(
            "bookmark_create_auto_track_union",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Git(&["init", "-q", "--bare", "../remote2.git"]),
                Step::Jj(&["git", "remote", "add", "upstream", "../remote2.git"]),
                Step::Jj(&[
                    "config",
                    "set",
                    "--repo",
                    "remotes.origin.auto-track-bookmarks",
                    "\"glob:feat*\"",
                ]),
                Step::Jj(&[
                    "config",
                    "set",
                    "--repo",
                    "remotes.origin.auto-track-created-bookmarks",
                    "\"exact:other\"",
                ]),
                Step::Jj(&[
                    "config",
                    "set",
                    "--repo",
                    "remotes.upstream.auto-track-created-bookmarks",
                    "\"*\"",
                ]),
                Step::Jj(&[
                    "config",
                    "set",
                    "--repo",
                    "remotes.ghost.auto-track-created-bookmarks",
                    "\"*\"",
                ]),
            ],
            |repo, _, _| {
                let result = repo.bookmark_create(&strings(&["feature", "other", "third"]), None);
                crate::compare::zanshin_outcome(repo, &result)
            },
            |_| strings(&["bookmark", "create", "feature", "other", "third"]),
        ),
        // A pattern that does not parse refuses the whole call ("Invalid
        // `remotes.origin.auto-track-created-bookmarks`: …"); nothing is created.
        push(
            "bookmark_create_auto_track_broken",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&[
                    "config",
                    "set",
                    "--repo",
                    "remotes.origin.auto-track-created-bookmarks",
                    "\"(\"",
                ]),
            ],
            |repo, _, _| create_feature(repo, None),
            |_| strings(&["bookmark", "create", "feature"]),
        ),
    ]
}

// ── jj git fetch (Story 9.30) ────────────────────────────────────────────────

// Every fetch below but `fetch_nothing_new` brings something new: `git --git-dir <remote> branch
// <name> b-mark` adds a branch on the bare remote at the pushed `b-mark`. `fetch_nothing_new`
// fetches what the push already recorded — the CLI's "Nothing changed.", no operation (Story 9.40).

/// [`PUSHED`] plus `n-mark` and `x-mark` new on `origin`.
const FETCH_PUSHED: &[Step] = &[
    Step::Git(&["init", "-q", "--bare", "../remote.git"]),
    Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
    Step::Jj(&["git", "push", "-b", "b-mark"]),
    Step::Git(&["--git-dir", "../remote.git", "branch", "n-mark", "b-mark"]),
    Step::Git(&["--git-dir", "../remote.git", "branch", "x-mark", "b-mark"]),
];

/// Two remotes, `origin` and `up`, each with `b-mark` pushed and `n-mark` new upstream.
const FETCH_TWO_REMOTES: &[Step] = &[
    Step::Git(&["init", "-q", "--bare", "../remote.git"]),
    Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
    Step::Git(&["init", "-q", "--bare", "../remote2.git"]),
    Step::Jj(&["git", "remote", "add", "up", "../remote2.git"]),
    Step::Jj(&["git", "push", "--remote", "*", "-b", "b-mark"]),
    Step::Git(&["--git-dir", "../remote.git", "branch", "n-mark", "b-mark"]),
    Step::Git(&["--git-dir", "../remote2.git", "branch", "n-mark", "b-mark"]),
];

/// `Repo::git_fetch` with `args`: a refusal is an error, as the CLI's non-zero exit.
fn fetch_outcome(repo: &mut zanshin_jj::Repo, args: &GitFetchArgs) -> Outcome {
    let result = repo.git_fetch(args, &|_: ProgressEvent| {}, None);
    crate::compare::zanshin_outcome(repo, &result)
}

/// Every fetch scenario (Story 9.30): the default remotes (`origin`, the only remote, none),
/// `--remote` with a name no remote carries, `--all-remotes`, `-b`, `--tracked`, `git.fetch` and
/// `remotes.origin.fetch-bookmarks`. Built like the push scenarios ([`push`]) and read back the
/// same way ([`push_read_back`]: the bookmarks with their remotes, and the bare remotes' refs).
#[allow(clippy::too_many_lines)] // WHY: one flat table reads better than nine helper fns
pub fn fetch_scenarios() -> Vec<Scenario> {
    vec![
        push(
            "fetch_default",
            FETCH_PUSHED,
            |repo, _, _| fetch_outcome(repo, &GitFetchArgs::default()),
            |_| strings(&["git", "fetch"]),
        ),
        // The only remote `up`: the CLI hints "Fetching from the only existing remote: up" (a
        // hint, no warning).
        push(
            "fetch_only_remote",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "up", "../remote.git"]),
                Step::Jj(&["git", "push", "-b", "b-mark"]),
                Step::Git(&["--git-dir", "../remote.git", "branch", "n-mark", "b-mark"]),
            ],
            |repo, _, _| fetch_outcome(repo, &GitFetchArgs::default()),
            |_| strings(&["git", "fetch"]),
        ),
        // No remote at all: "No matching remotes for names: origin", then "No git remotes to
        // fetch from" — a refusal that writes nothing.
        push(
            "fetch_no_remote",
            &[],
            |repo, _, _| fetch_outcome(repo, &GitFetchArgs::default()),
            |_| strings(&["git", "fetch"]),
        ),
        push(
            "fetch_unmatched_remote",
            FETCH_PUSHED,
            |repo, _, _| {
                fetch_outcome(
                    repo,
                    &GitFetchArgs {
                        remotes: FetchRemotes::Named(strings(&["origin", "nope"])),
                        refs: FetchRefs::Default,
                    },
                )
            },
            |_| strings(&["git", "fetch", "--remote", "origin", "--remote", "nope"]),
        ),
        push(
            "fetch_all_remotes",
            FETCH_TWO_REMOTES,
            |repo, _, _| {
                fetch_outcome(
                    repo,
                    &GitFetchArgs {
                        remotes: FetchRemotes::All,
                        refs: FetchRefs::Default,
                    },
                )
            },
            |_| strings(&["git", "fetch", "--all-remotes"]),
        ),
        // `-b n*` fetches `n-mark`, not `x-mark`; `-b nope` warns that no remote has it.
        push(
            "fetch_branch_pattern",
            FETCH_PUSHED,
            |repo, _, _| {
                fetch_outcome(
                    repo,
                    &GitFetchArgs {
                        remotes: FetchRemotes::Default,
                        refs: FetchRefs::Patterns {
                            branches: strings(&["n*", "nope"]),
                            tags: Vec::new(),
                        },
                    },
                )
            },
            |_| strings(&["git", "fetch", "-b", "n*", "-b", "nope"]),
        ),
        // `b-mark@origin` (tracked) moved back to A upstream, `n-mark` (untracked, new) appeared:
        // `--tracked` fetches only `b-mark`.
        push(
            "fetch_tracked",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&["git", "push", "-b", "b-mark"]),
                Step::Git(&["--git-dir", "../remote.git", "branch", "n-mark", "b-mark"]),
                Step::Git(&[
                    "--git-dir",
                    "../remote.git",
                    "update-ref",
                    "refs/heads/b-mark",
                    "b-mark~1",
                ]),
            ],
            |repo, _, _| {
                fetch_outcome(
                    repo,
                    &GitFetchArgs {
                        remotes: FetchRemotes::Default,
                        refs: FetchRefs::Tracked,
                    },
                )
            },
            |_| strings(&["git", "fetch", "--tracked"]),
        ),
        // `git.fetch = "up"` (set through the CLI's repo config): only `up` is fetched.
        push(
            "fetch_git_fetch_config",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Git(&["init", "-q", "--bare", "../remote2.git"]),
                Step::Jj(&["git", "remote", "add", "up", "../remote2.git"]),
                Step::Jj(&["git", "push", "--remote", "*", "-b", "b-mark"]),
                Step::Git(&["--git-dir", "../remote.git", "branch", "n-mark", "b-mark"]),
                Step::Git(&["--git-dir", "../remote2.git", "branch", "n-mark", "b-mark"]),
                Step::Jj(&["config", "set", "--repo", "git.fetch", "up"]),
            ],
            |repo, _, _| fetch_outcome(repo, &GitFetchArgs::default()),
            |_| strings(&["git", "fetch"]),
        ),
        // `remotes.origin.fetch-bookmarks = "n-mark"`: the bare fetch brings `n-mark`, not
        // `x-mark`.
        push(
            "fetch_remote_fetch_bookmarks",
            &[
                Step::Git(&["init", "-q", "--bare", "../remote.git"]),
                Step::Jj(&["git", "remote", "add", "origin", "../remote.git"]),
                Step::Jj(&["git", "push", "-b", "b-mark"]),
                Step::Git(&["--git-dir", "../remote.git", "branch", "n-mark", "b-mark"]),
                Step::Git(&["--git-dir", "../remote.git", "branch", "x-mark", "b-mark"]),
                Step::Jj(&["config", "set", "--repo", "remotes.origin.fetch-bookmarks", "n-mark"]),
            ],
            |repo, _, _| fetch_outcome(repo, &GitFetchArgs::default()),
            |_| strings(&["git", "fetch"]),
        ),
        // Story 9.40: the push already recorded `b-mark@origin`, so the fetch brings nothing new —
        // the CLI's "Nothing changed.", no operation.
        push(
            "fetch_nothing_new",
            PUSHED,
            |repo, _, _| fetch_outcome(repo, &GitFetchArgs::default()),
            |_| strings(&["git", "fetch"]),
        ),
    ]
}
