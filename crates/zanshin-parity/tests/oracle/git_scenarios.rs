// SPDX-License-Identifier: MIT

//! Story 9.20's scenarios: `jj git init` / `jj git clone` — creation scenarios, where the call
//! creates the repo, so there is no shared history — and `jj git push`, table scenarios on the
//! BASE history against a bare remote beside the repo.

use std::path::Path;
use std::path::PathBuf;

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
    zanshin_jj::Repo::clone(options, &|_: ProgressEvent| {})
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
    },
    CreationScenario {
        id: "init_no_colocate",
        prep: &[],
        target: "",
        cli: &["git", "init", "--no-colocate"],
        zanshin: |dir| init(dir.to_owned(), Some(false)),
    },
    CreationScenario {
        id: "init_missing_destination",
        prep: &[],
        target: "sub",
        cli: &["git", "init", "sub"],
        zanshin: |dir| init(dir.join("sub"), None),
    },
    CreationScenario {
        id: "init_over_git_colocate",
        prep: GIT_HERE,
        target: "",
        cli: &["git", "init"],
        zanshin: |dir| init(dir.to_owned(), None),
    },
    CreationScenario {
        id: "init_over_git_no_colocate",
        prep: GIT_HERE,
        target: "",
        cli: &["git", "init", "--no-colocate"],
        zanshin: |dir| init(dir.to_owned(), Some(false)),
    },
    CreationScenario {
        id: "clone_default",
        prep: SOURCE,
        target: "dest",
        cli: &["git", "clone", "src", "dest"],
        zanshin: |dir| clone(&clone_options(dir, "src")),
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
    },
    CreationScenario {
        id: "clone_empty_source",
        prep: &[Prep::Git(&["init", "-q", "-b", "main", "src"])],
        target: "dest",
        cli: &["git", "clone", "src", "dest"],
        zanshin: |dir| clone(&clone_options(dir, "src")),
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
    },
];

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
    let result = repo.git_push(args, &|_: ProgressEvent| {});
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
#[allow(clippy::too_many_lines)] // WHY: one flat table reads better than 15 helper fns
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
    ]
}
