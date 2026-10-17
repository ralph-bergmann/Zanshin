// SPDX-License-Identifier: MIT

//! `gate-plan` / `gate-stamp` — make `cargo make test` run only the steps a change needs.
//!
//! `gate-plan` snapshots the working tree (tracked and untracked files, `.gitignore` respected) as a
//! git tree object, diffs it against the tree of the last green gate run (`target/gate/last-green`)
//! and writes the `gate-<step>` wrapper tasks to run into `target/gate/plan`, which the `gate-step`
//! condition in `Makefile.toml` reads. Every changed path maps to step groups through [`RULES`]: the
//! package it belongs to plus every package that depends on it. A path no rule knows, a missing or
//! undiffable stamp, or a changed toolchain plans every step; so does `cargo make test-full`.
//!
//! `gate-stamp` is the flow's last task, so only a green run moves the stamp. The stamp records the
//! tree the run STARTED from: a change made while the gate ran stays in the next plan. Diffing
//! against the last green tree rather than against `HEAD` keeps a change that was committed before
//! the gate ran in the plan too.
//!
//! A test that reads a file outside its own package (a doc, a design export, a fixture) needs that
//! path in [`RULES`] — otherwise a change to it plans no step.

use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

type DynError = Box<dyn std::error::Error + Send + Sync + 'static>;

/// Where the gate keeps its state, relative to the workspace root (inside the git-ignored `target/`).
const GATE_DIR: &str = "target/gate";
/// The stamp of the last green run.
const LAST_GREEN: &str = "last-green";
/// The stamp of the run in progress; `gate-stamp` turns it into [`LAST_GREEN`].
const PENDING: &str = "pending";
/// The wrapper tasks the run in progress executes, one per line.
const PLAN: &str = "plan";
/// The ratchet raises this file in place during a green run; see [`run_stamp`].
const BASELINE: &str = "coverage-baseline.txt";

/// Every gate step in `cargo make test` order. Each runs through its `gate-<step>` wrapper task.
const ALL_STEPS: &[&str] = &[
    "test-clippy",
    "test-fmt",
    "test-cargo-doc",
    "test-flutter",
    "test-dart-analyze",
    "test-dart-format",
    "test-core-analyze",
    "test-core-format",
    "test-shell",
    "test-shell-analyze",
    "test-shell-format",
    "test-shell-pi",
    "test-shell-pi-analyze",
    "test-shell-pi-format",
    "test-shell-macos",
    "test-shell-macos-analyze",
    "test-shell-macos-format",
    "test-settings",
    "test-settings-analyze",
    "test-settings-format",
    "test-ui",
    "test-ui-analyze",
    "test-ui-format",
    "test-cargo-deny",
    "test-cargo-hygiene",
    "test-jj-adapter-hygiene",
    "coverage",
];

/// The Rust workspace. `coverage` runs every Rust test (cargo llvm-cov) and the `zanshin_core`
/// suite against the instrumented cdylib, so it carries the Rust and the FFI-path tests.
const RUST: &[&str] = &[
    "test-clippy",
    "test-fmt",
    "test-cargo-doc",
    "test-cargo-hygiene",
    "test-jj-adapter-hygiene",
    "coverage",
];
/// `app/`; its tests load the real cdylib.
const APP: &[&str] = &["test-flutter", "test-dart-analyze", "test-dart-format"];
/// `packages/zanshin_core`; its tests run inside `coverage`, whose ratchet they feed.
const CORE: &[&str] = &["test-core-analyze", "test-core-format", "coverage"];
const SETTINGS: &[&str] = &["test-settings", "test-settings-analyze", "test-settings-format"];
const SHELL: &[&str] = &["test-shell", "test-shell-analyze", "test-shell-format"];
const SHELL_MACOS: &[&str] = &[
    "test-shell-macos",
    "test-shell-macos-analyze",
    "test-shell-macos-format",
];
const SHELL_PI: &[&str] = &["test-shell-pi", "test-shell-pi-analyze", "test-shell-pi-format"];
const UI: &[&str] = &["test-ui", "test-ui-analyze", "test-ui-format"];

/// What one changed path needs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Need {
    /// No gate step reads it.
    Nothing,
    /// The steps of these groups.
    Groups(&'static [&'static [&'static str]]),
    /// Every step.
    Everything,
}

#[derive(Clone, Copy)]
enum Pattern {
    Exact(&'static str),
    Prefix(&'static str),
    Suffix(&'static str),
    /// `crates/<name>/Cargo.toml`.
    CrateManifest,
}

impl Pattern {
    fn matches(self, path: &str) -> bool {
        match self {
            Self::Exact(p) => path == p,
            Self::Prefix(p) => path.starts_with(p),
            Self::Suffix(s) => path.ends_with(s),
            Self::CrateManifest => {
                path.starts_with("crates/") && path.ends_with("/Cargo.toml") && path.matches('/').count() == 2
            }
        }
    }
}

/// Path rules, first match wins; a path no rule matches needs every step.
const RULES: &[(Pattern, &str, Need)] = &[
    // Read by tests although they look like docs or planning.
    (
        Pattern::Exact("docs/ffi-abi.md"),
        "read by zanshin-ffi's doc-sync test",
        Need::Groups(&[RUST]),
    ),
    (
        Pattern::Exact("docs/rust-error-codes.md"),
        "read by zanshin-ffi's doc-sync test",
        Need::Groups(&[RUST]),
    ),
    (
        Pattern::Prefix("_bmad-output/implementation-artifacts/design_system/"),
        "read by zanshin_ui's DS parity test",
        Need::Groups(&[UI]),
    ),
    // Docs, planning and agent files.
    (Pattern::Suffix(".md"), "docs", Need::Nothing),
    (Pattern::Suffix(".DS_Store"), "Finder metadata", Need::Nothing),
    (Pattern::Prefix("_bmad-output/"), "planning", Need::Nothing),
    (Pattern::Prefix("_bmad/"), "planning", Need::Nothing),
    (Pattern::Prefix("docs/"), "docs", Need::Nothing),
    (Pattern::Prefix("spikes/"), "spikes", Need::Nothing),
    (Pattern::Prefix("stuff/"), "notes", Need::Nothing),
    (Pattern::Prefix(".claude/"), "agent config", Need::Nothing),
    (Pattern::Exact("LICENSE"), "license", Need::Nothing),
    (Pattern::Exact(".gitignore"), "git config", Need::Nothing),
    (Pattern::Exact(".gitattributes"), "git config", Need::Nothing),
    (Pattern::Exact(".editorconfig"), "editor config", Need::Nothing),
    // Toolchains, dependencies, the gate itself.
    (Pattern::Exact("Makefile.toml"), "the gate", Need::Everything),
    (Pattern::Prefix("crates/xtask/"), "the gate's tooling", Need::Everything),
    (Pattern::Exact(BASELINE), "the coverage baseline", Need::Everything),
    (
        Pattern::Exact("Cargo.toml"),
        "Rust workspace manifest",
        Need::Everything,
    ),
    (Pattern::CrateManifest, "Rust dependencies", Need::Everything),
    (Pattern::Exact("Cargo.lock"), "Rust dependencies", Need::Everything),
    (Pattern::Exact("deny.toml"), "cargo deny", Need::Everything),
    (
        Pattern::Exact("rust-toolchain.toml"),
        "Rust toolchain",
        Need::Everything,
    ),
    (Pattern::Exact("rustfmt.toml"), "Rust formatting", Need::Everything),
    (Pattern::Prefix(".cargo/"), "cargo config", Need::Everything),
    (Pattern::Exact("pubspec.yaml"), "Dart workspace", Need::Everything),
    (Pattern::Exact("pubspec.lock"), "Dart dependencies", Need::Everything),
    (
        Pattern::Suffix("/pubspec.yaml"),
        "a Dart package's dependencies, read by the dependents test",
        Need::Everything,
    ),
    (Pattern::Prefix("linter/"), "Dart lint rules", Need::Everything),
    // Linked into the zanshin-ffi cdylib, which the zanshin_core suite and the app tests load.
    (
        Pattern::Prefix("crates/zanshin-jj/"),
        "Rust in the cdylib",
        Need::Groups(&[RUST, APP]),
    ),
    (
        Pattern::Prefix("crates/zanshin-ffi/"),
        "Rust in the cdylib",
        Need::Groups(&[RUST, APP]),
    ),
    (
        Pattern::Exact("cbindgen.toml"),
        "FFI codegen",
        Need::Groups(&[RUST, APP]),
    ),
    (Pattern::Prefix("schemas/"), "FFI schema", Need::Groups(&[RUST, APP])),
    (
        Pattern::Prefix("test-fixtures/"),
        "test fixtures",
        Need::Groups(&[RUST, APP]),
    ),
    // Rust outside the cdylib.
    (
        Pattern::Prefix("crates/zanshin-mcp/"),
        "Rust outside the cdylib",
        Need::Groups(&[RUST]),
    ),
    (
        Pattern::Prefix("crates/zanshin-diff/"),
        "Rust outside the cdylib",
        Need::Groups(&[RUST]),
    ),
    (
        Pattern::Prefix("crates/zanshin-parity/"),
        "Rust outside the cdylib",
        Need::Groups(&[RUST]),
    ),
    (
        Pattern::Prefix("crates/test-helpers/"),
        "Rust test helpers",
        Need::Groups(&[RUST]),
    ),
    // Dart packages: the package plus every package depending on it (by name in a pubspec's
    // `dependencies:` or `dev_dependencies:`, whatever the source — pub resolves a workspace member's
    // name to the member). `a_flutter_package_plans_itself_and_every_package_depending_on_it` checks
    // these entries against the pubspecs.
    (
        Pattern::Prefix("packages/zanshin_core/"),
        "zanshin_core",
        Need::Groups(&[CORE, APP]),
    ),
    (
        Pattern::Prefix("packages/zanshin_settings/"),
        "zanshin_settings",
        Need::Groups(&[SETTINGS, UI, APP]),
    ),
    (
        Pattern::Prefix("packages/zanshin_shell_platform_interface/"),
        "zanshin_shell_platform_interface",
        Need::Groups(&[SHELL_PI, SHELL_MACOS, SHELL, UI, APP]),
    ),
    (
        Pattern::Prefix("packages/zanshin_shell_macos/"),
        "zanshin_shell_macos",
        Need::Groups(&[SHELL_MACOS, SHELL, UI, APP]),
    ),
    (
        Pattern::Prefix("packages/zanshin_shell/"),
        "zanshin_shell",
        Need::Groups(&[SHELL, UI, APP]),
    ),
    (
        Pattern::Prefix("packages/zanshin_ui/"),
        "zanshin_ui",
        Need::Groups(&[UI, APP]),
    ),
    (Pattern::Prefix("app/"), "app", Need::Groups(&[APP])),
];

/// The label and need of the first rule matching `path`.
fn classify(path: &str) -> (&'static str, Need) {
    RULES
        .iter()
        .find(|(pattern, _, _)| pattern.matches(path))
        .map_or(("no rule knows it", Need::Everything), |&(_, label, need)| {
            (label, need)
        })
}

#[derive(Debug, PartialEq, Eq)]
enum Plan {
    /// Every step, for this reason.
    Full(String),
    /// These steps in gate order; `changed` explains each changed path.
    Steps {
        steps: Vec<&'static str>,
        changed: Vec<String>,
    },
}

/// The steps a set of changed paths needs.
fn plan_for(paths: &[String]) -> Plan {
    let mut needed = BTreeSet::new();
    let mut changed = Vec::new();
    for path in paths {
        let (label, need) = classify(path);
        match need {
            Need::Everything => return Plan::Full(format!("{path} changed ({label})")),
            Need::Nothing => {}
            Need::Groups(groups) => needed.extend(groups.iter().flat_map(|group| group.iter().copied())),
        }
        changed.push(format!("{path} ({label})"));
    }
    let steps = ALL_STEPS.iter().copied().filter(|step| needed.contains(step)).collect();
    Plan::Steps { steps, changed }
}

/// A run's record: the working-tree snapshot it verifies and the toolchains it runs with.
#[derive(Debug, PartialEq, Eq)]
struct Stamp {
    tree: String,
    toolchains: String,
}

impl Stamp {
    fn render(&self) -> String {
        format!("tree {}\ntoolchains {}\n", self.tree, self.toolchains)
    }

    fn parse(text: &str) -> Option<Self> {
        let mut tree = None;
        let mut toolchains = None;
        for line in text.lines() {
            if let Some(value) = line.strip_prefix("tree ") {
                tree = Some(value.to_owned());
            } else if let Some(value) = line.strip_prefix("toolchains ") {
                toolchains = Some(value.to_owned());
            }
        }
        Some(Self {
            tree: tree?,
            toolchains: toolchains?,
        })
    }

    fn read(path: &Path) -> Option<Self> {
        fs::read_to_string(path).ok().as_deref().and_then(Self::parse)
    }
}

#[derive(clap::Args)]
pub struct GatePlanArgs {
    /// The repository root (cargo-make's workspace directory).
    #[arg(long)]
    workspace_root: PathBuf,
    /// Plan every step, whatever changed (`cargo make test-full`).
    #[arg(long)]
    full: bool,
}

#[derive(clap::Args)]
pub struct GateStampArgs {
    /// The repository root (cargo-make's workspace directory).
    #[arg(long)]
    workspace_root: PathBuf,
}

/// Run `xtask gate-plan`: write this run's plan and pending stamp, and print what runs and why.
///
/// # Errors
/// Returns an error if the working tree cannot be snapshotted or the plan cannot be written.
pub fn run_plan(args: &GatePlanArgs) -> Result<(), DynError> {
    let root = &args.workspace_root;
    let dir = root.join(GATE_DIR);
    fs::create_dir_all(&dir).map_err(|e| format!("creating {}: {e}", dir.display()))?;
    let current = Stamp {
        tree: snapshot_tree(root)?,
        toolchains: toolchains(root),
    };

    let plan = if args.full {
        Plan::Full("`cargo make test-full`".to_owned())
    } else {
        match Stamp::read(&dir.join(LAST_GREEN)) {
            None => Plan::Full(format!("no green run recorded yet ({GATE_DIR}/{LAST_GREEN})")),
            Some(green) if green.toolchains != current.toolchains => {
                Plan::Full("the Rust or Dart toolchain changed since the last green run".to_owned())
            }
            Some(green) => match changed_paths(root, &green.tree, &current.tree) {
                Ok(paths) => plan_for(&paths),
                Err(e) => Plan::Full(format!("the last green tree cannot be diffed ({e})")),
            },
        }
    };

    let steps = match &plan {
        Plan::Full(reason) => {
            println!("gate: every step — {reason}");
            ALL_STEPS.to_vec()
        }
        Plan::Steps { steps, changed } => {
            println!("gate: {} path(s) changed since the last green run", changed.len());
            for line in changed.iter().take(15) {
                println!("  {line}");
            }
            if changed.len() > 15 {
                println!("  … and {} more", changed.len() - 15);
            }
            if steps.is_empty() {
                println!("gate: no step needed");
            } else {
                println!(
                    "gate: {} of {} steps: {}",
                    steps.len(),
                    ALL_STEPS.len(),
                    steps.join(" ")
                );
            }
            steps.clone()
        }
    };

    let plan_text = steps.iter().fold(String::new(), |mut text, step| {
        let _ = writeln!(text, "gate-{step}");
        text
    });
    fs::write(dir.join(PLAN), plan_text).map_err(|e| format!("writing the plan: {e}"))?;
    fs::write(dir.join(PENDING), current.render()).map_err(|e| format!("writing the pending stamp: {e}"))?;
    Ok(())
}

/// Run `xtask gate-stamp` after a green run: record the tree it verified as the last green one.
///
/// The ratchet may raise `coverage-baseline.txt` in place during the run; when that is the only
/// difference, the stamp takes the tree as it is now, so the raise does not trigger a full run.
///
/// # Errors
/// Returns an error if no plan is pending or the stamp cannot be written.
pub fn run_stamp(args: &GateStampArgs) -> Result<(), DynError> {
    let root = &args.workspace_root;
    let dir = root.join(GATE_DIR);
    let pending = Stamp::read(&dir.join(PENDING))
        .ok_or_else(|| format!("no pending gate run ({GATE_DIR}/{PENDING}); run `cargo make test`"))?;
    let now = snapshot_tree(root)?;
    let tree = if now == pending.tree {
        now
    } else {
        let during = changed_paths(root, &pending.tree, &now)?;
        if during.iter().all(|path| path == BASELINE) {
            now
        } else {
            println!(
                "gate: {} path(s) changed while the gate ran and stay in the next plan: {}",
                during.len(),
                during.join(" ")
            );
            pending.tree
        }
    };
    let stamp = Stamp {
        tree,
        toolchains: pending.toolchains,
    };
    fs::write(dir.join(LAST_GREEN), stamp.render()).map_err(|e| format!("writing the stamp: {e}"))?;
    fs::remove_file(dir.join(PENDING)).map_err(|e| format!("removing the pending stamp: {e}"))?;
    Ok(())
}

/// Variables that change which files git ignores or which repository it reads. cargo-make keeps a
/// task's `env` for the tasks after it, so `test-flutter`'s `GIT_CONFIG_GLOBAL = ""` would reach
/// `gate-stamp`, drop the user's global excludes and make ignored files (`.DS_Store`) look new.
const GIT_ENV_OVERRIDES: &[&str] = &[
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_SYSTEM",
    "GIT_CONFIG_NOSYSTEM",
    "XDG_CONFIG_HOME",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
];

/// Run git in `root`, optionally against another index file, and return its stdout.
fn git(root: &Path, index: Option<&Path>, args: &[&str]) -> Result<String, DynError> {
    let mut command = Command::new("git");
    command.current_dir(root).args(args);
    for name in GIT_ENV_OVERRIDES {
        command.env_remove(name);
    }
    if let Some(index) = index {
        command.env("GIT_INDEX_FILE", index);
    }
    let output = command
        .output()
        .map_err(|e| format!("running git {}: {e}", args.join(" ")))?;
    if !output.status.success() {
        return Err(format!(
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        )
        .into());
    }
    Ok(String::from_utf8(output.stdout)?)
}

/// The working tree — tracked and untracked files, `.gitignore` respected — as a git tree object id.
///
/// A throwaway index seeded from the real one keeps `git add` fast and leaves the real index
/// untouched. It writes only loose objects, which `git gc` prunes once nothing refers to them; a
/// stamp whose tree was pruned fails to diff, which plans every step.
fn snapshot_tree(root: &Path) -> Result<String, DynError> {
    let real_index = root.join(git(root, None, &["rev-parse", "--git-path", "index"])?.trim());
    let scratch = tempfile::tempdir()?;
    let index = scratch.path().join("index");
    if real_index.exists() {
        fs::copy(&real_index, &index).map_err(|e| format!("copying {}: {e}", real_index.display()))?;
    }
    git(root, Some(&index), &["add", "--all"])?;
    Ok(git(root, Some(&index), &["write-tree"])?.trim().to_owned())
}

/// The paths that differ between two tree objects, renames split into both sides.
fn changed_paths(root: &Path, from: &str, to: &str) -> Result<Vec<String>, DynError> {
    let output = git(root, None, &["diff", "--name-only", "--no-renames", "-z", from, to])?;
    Ok(output
        .split('\0')
        .filter(|path| !path.is_empty())
        .map(str::to_owned)
        .collect())
}

/// The versions of the Rust and Dart toolchains the gate runs with, on one line.
fn toolchains(root: &Path) -> String {
    [("rustc", "-vV"), ("dart", "--version")]
        .iter()
        .map(|(program, arg)| {
            let text = Command::new(program).arg(arg).current_dir(root).output().map_or_else(
                |e| format!("{program}: {e}"),
                |output| {
                    format!(
                        "{}{}",
                        String::from_utf8_lossy(&output.stdout),
                        String::from_utf8_lossy(&output.stderr)
                    )
                },
            );
            text.split_whitespace().collect::<Vec<_>>().join(" ")
        })
        .collect::<Vec<_>>()
        .join(" | ")
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;

    fn steps(need: Need) -> Vec<&'static str> {
        match need {
            Need::Groups(groups) => {
                let set: BTreeSet<_> = groups.iter().flat_map(|group| group.iter().copied()).collect();
                ALL_STEPS.iter().copied().filter(|step| set.contains(step)).collect()
            }
            other => panic!("expected groups, got {other:?}"),
        }
    }

    /// Each Dart workspace member's own gate steps.
    const OWN_STEPS: &[(&str, &[&str])] = &[
        ("app", APP),
        ("packages/zanshin_core", CORE),
        ("packages/zanshin_settings", SETTINGS),
        ("packages/zanshin_shell", SHELL),
        ("packages/zanshin_shell_macos", SHELL_MACOS),
        ("packages/zanshin_shell_platform_interface", SHELL_PI),
        ("packages/zanshin_ui", UI),
    ];

    /// `line` without its comment.
    fn code(line: &str) -> &str {
        line.split_once('#').map_or(line, |(code, _)| code)
    }

    /// The Dart workspace members the root `pubspec.yaml`'s `workspace:` list names, repo-relative.
    /// An entry ending in `/*` names every subdirectory holding a `pubspec.yaml`.
    fn dart_members(root: &Path) -> BTreeSet<String> {
        let pubspec = fs::read_to_string(root.join("pubspec.yaml")).expect("the root pubspec.yaml");
        pubspec
            .lines()
            .map(|line| code(line).trim_end())
            .skip_while(|line| *line != "workspace:")
            .skip(1)
            .filter(|line| !line.is_empty())
            .map_while(|line| line.trim_start().strip_prefix("- "))
            .map(|entry| entry.trim().trim_matches(['\'', '"']))
            .flat_map(|entry| match entry.strip_suffix("/*") {
                Some(parent) => fs::read_dir(root.join(parent))
                    .expect("a workspace glob's directory")
                    .map(|dir| {
                        format!(
                            "{parent}/{}",
                            dir.expect("a directory entry").file_name().to_string_lossy()
                        )
                    })
                    .collect(),
                None => vec![entry.to_owned()],
            })
            .filter(|member| root.join(member).join("pubspec.yaml").is_file())
            .collect()
    }

    /// The package name a pubspec declares.
    fn package_name(pubspec: &str) -> Option<&str> {
        pubspec
            .lines()
            .find_map(|line| code(line).strip_prefix("name:"))
            .map(|name| name.trim().trim_matches(['\'', '"']))
    }

    /// The members a pubspec depends on, by section.
    #[derive(Debug, Default, PartialEq, Eq)]
    struct Dependencies {
        regular: BTreeSet<String>,
        dev: BTreeSet<String>,
    }

    /// The members `pubspec` depends on: the first-level keys of its top-level `dependencies:` and
    /// `dev_dependencies:` sections that name a member (`members_by_name`: package name → member),
    /// whatever their source — pub resolves a workspace member's name to the member.
    fn dependencies(pubspec: &str, members_by_name: &BTreeMap<String, String>) -> Dependencies {
        let mut found = Dependencies::default();
        let mut section = None;
        let mut key_indent = None;
        for line in pubspec
            .lines()
            .map(|line| code(line).trim_end())
            .filter(|line| !line.is_empty())
        {
            let text = line.trim_start();
            let indent = line.len() - text.len();
            if indent == 0 {
                section = match line {
                    "dependencies:" => Some(&mut found.regular),
                    "dev_dependencies:" => Some(&mut found.dev),
                    _ => None,
                };
                key_indent = None;
                continue;
            }
            let Some(set) = section.as_deref_mut() else {
                continue;
            };
            if indent != *key_indent.get_or_insert(indent) || text.starts_with('-') {
                continue;
            }
            let key = text.split_once(':').map_or(text, |(key, _)| key);
            if let Some(member) = members_by_name.get(key.trim().trim_matches(['\'', '"'])) {
                set.insert(member.clone());
            }
        }
        found
    }

    /// The members whose code `member`'s tests run: its regular and dev dependencies, then their
    /// regular dependencies transitively (a dependency's dev dependencies are not part of it).
    fn reached(deps: &BTreeMap<String, Dependencies>, member: &str) -> BTreeSet<String> {
        let mut seen: BTreeSet<String> = deps[member].regular.union(&deps[member].dev).cloned().collect();
        let mut todo: Vec<String> = seen.iter().cloned().collect();
        while let Some(next) = todo.pop() {
            for dep in &deps[&next].regular {
                if seen.insert(dep.clone()) {
                    todo.push(dep.clone());
                }
            }
        }
        seen
    }

    /// What is wrong with the package rules for the Dart workspace under `root`, one line per
    /// problem: each member's rule must plan exactly its own steps and those of every member whose
    /// tests run its code by the pubspecs ([`reached`]).
    fn package_rule_problems(root: &Path) -> Vec<String> {
        let members = dart_members(root);
        let mut problems = Vec::new();
        for (entry, _) in OWN_STEPS {
            if !members.contains(*entry) {
                problems.push(format!(
                    "{entry} in OWN_STEPS is no Dart workspace member (no {entry}/pubspec.yaml): remove its entry"
                ));
            }
        }
        let own = |member: &str| -> &'static [&'static str] {
            OWN_STEPS
                .iter()
                .find(|(entry, _)| *entry == member)
                .map_or(&[], |&(_, steps)| steps)
        };
        let pubspecs: BTreeMap<&str, String> = members
            .iter()
            .map(|member| {
                let pubspec = fs::read_to_string(root.join(member).join("pubspec.yaml")).expect("a member's pubspec");
                (member.as_str(), pubspec)
            })
            .collect();
        let members_by_name: BTreeMap<String, String> = pubspecs
            .iter()
            .filter_map(|(member, pubspec)| Some((package_name(pubspec)?.to_owned(), (*member).to_owned())))
            .collect();
        let deps: BTreeMap<String, Dependencies> = pubspecs
            .iter()
            .map(|(member, pubspec)| ((*member).to_owned(), dependencies(pubspec, &members_by_name)))
            .collect();

        for member in &members {
            if own(member).is_empty() {
                problems.push(format!(
                    "{member} is a Dart workspace member without gate steps: add its steps to \
                     Makefile.toml and ALL_STEPS, a RULES entry and an OWN_STEPS entry"
                ));
            }
            let dependents: BTreeSet<&str> = members
                .iter()
                .filter(|other| *other != member && reached(&deps, other).contains(member))
                .map(String::as_str)
                .collect();
            let wanted: BTreeSet<&str> = std::iter::once(member.as_str())
                .chain(dependents.iter().copied())
                .flat_map(|package| own(package).iter().copied())
                .collect();
            let expected: Vec<&str> = ALL_STEPS.iter().copied().filter(|step| wanted.contains(step)).collect();

            let need = classify(&format!("{member}/lib/a.dart")).1;
            if !matches!(need, Need::Groups(_)) {
                problems.push(format!(
                    "{member} has no package rule in RULES: add one planning its own steps and those of \
                     every package depending on it"
                ));
                continue;
            }
            let planned = steps(need);
            let missing: Vec<_> = expected.iter().filter(|step| !planned.contains(step)).collect();
            let unexpected: Vec<_> = planned.iter().filter(|step| !expected.contains(step)).collect();
            if !missing.is_empty() || !unexpected.is_empty() {
                problems.push(format!(
                    "the RULES entry of {member} must plan its own steps and those of every package \
                     depending on it ({dependents:?}): missing {missing:?}, unexpected {unexpected:?}"
                ));
            }
        }
        problems
    }

    /// A temp dir holding a copy of the real workspace's root and member pubspecs.
    fn copy_of_the_workspace_pubspecs() -> tempfile::TempDir {
        let real = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let copy = tempfile::tempdir().expect("tempdir");
        fs::copy(real.join("pubspec.yaml"), copy.path().join("pubspec.yaml")).expect("copy the root pubspec");
        for member in dart_members(&real) {
            fs::create_dir_all(copy.path().join(&member)).expect("create the member dir");
            fs::copy(
                real.join(&member).join("pubspec.yaml"),
                copy.path().join(&member).join("pubspec.yaml"),
            )
            .expect("copy the pubspec");
        }
        copy
    }

    #[test]
    fn a_flutter_package_plans_itself_and_every_package_depending_on_it() {
        let problems = package_rule_problems(&Path::new(env!("CARGO_MANIFEST_DIR")).join("../.."));
        assert!(problems.is_empty(), "{}", problems.join("\n"));
    }

    #[test]
    fn a_dependency_the_rules_miss_or_invent_and_an_unknown_or_stale_member_are_problems() {
        let workspace = copy_of_the_workspace_pubspecs();
        let edit = |member: &str, from: &str, to: &str| {
            let path = workspace.path().join(member).join("pubspec.yaml");
            let pubspec = fs::read_to_string(&path).expect("read the pubspec");
            let edited = pubspec.replacen(from, to, 1);
            assert_ne!(edited, pubspec, "{member}'s pubspec holds {from:?}");
            fs::write(&path, edited).expect("write the pubspec");
        };
        // A version-only dependency on a member resolves to the member (never legitimate here:
        // zanshin_core is pure Dart).
        edit(
            "packages/zanshin_core",
            "\ndependencies:\n",
            "\ndependencies:\n  zanshin_ui: any\n",
        );
        edit(
            "packages/zanshin_ui",
            "  zanshin_settings:\n    path: ../zanshin_settings\n",
            "",
        );
        fs::remove_file(
            workspace
                .path()
                .join("packages/zanshin_shell_platform_interface/pubspec.yaml"),
        )
        .expect("delete a member's pubspec");
        fs::create_dir_all(workspace.path().join("packages/zanshin_new")).expect("create a new package");
        fs::write(
            workspace.path().join("packages/zanshin_new/pubspec.yaml"),
            "name: zanshin_new\n",
        )
        .expect("write its pubspec");

        let problems = package_rule_problems(workspace.path());
        let found = |start: &str, part: &str| problems.iter().any(|p| p.starts_with(start) && p.contains(part));
        assert!(
            found(
                "the RULES entry of packages/zanshin_ui",
                r#"missing ["test-core-analyze", "test-core-format", "coverage"]"#
            ),
            "{problems:#?}"
        );
        assert!(
            found(
                "the RULES entry of packages/zanshin_settings",
                r#"missing [], unexpected ["test-ui", "test-ui-analyze", "test-ui-format"]"#
            ),
            "{problems:#?}"
        );
        assert!(
            found(
                "packages/zanshin_shell_platform_interface in OWN_STEPS is no Dart workspace member",
                ""
            ),
            "{problems:#?}"
        );
        assert!(
            found("packages/zanshin_new is a Dart workspace member without gate steps", ""),
            "{problems:#?}"
        );
        assert!(found("packages/zanshin_new has no package rule", ""), "{problems:#?}");
    }

    #[test]
    fn dependencies_are_first_level_member_keys_whatever_their_source() {
        let pubspec = [
            "name: a",
            "dependencies:",
            "  b:",
            "    path: ../b",
            "  c: any",
            "  d: {path: '../d', }",
            "  # e: any",
            "  hosted_dep:",
            "    g: any",
            "dev_dependencies:",
            "  f: ^1.0.0",
            "flutter:",
            "  assets:",
            "    - path: assets/icons/",
            "  plugin:",
            "    platforms:",
            "      macos:",
            "        default_package: h",
        ]
        .join("\n");
        let members_by_name: BTreeMap<String, String> = ["b", "c", "d", "e", "f", "g", "h", "path"]
            .map(|name| (name.to_owned(), format!("packages/{name}")))
            .into();
        assert_eq!(
            dependencies(&pubspec, &members_by_name),
            Dependencies {
                regular: ["packages/b", "packages/c", "packages/d"].map(str::to_owned).into(),
                dev: ["packages/f"].map(str::to_owned).into(),
            }
        );
    }

    #[test]
    fn the_members_are_the_workspace_entries_holding_a_pubspec() {
        let workspace = tempfile::tempdir().expect("tempdir");
        let root = workspace.path();
        fs::write(
            root.join("pubspec.yaml"),
            "name: w\nworkspace:\n  - app\n  - packages/*\n  # - old\n  - tools/gen\n\ndev_dependencies:\n  melos: any\n",
        )
        .expect("write the root pubspec");
        for member in ["app", "packages/a", "packages/b", "tools/gen", "tools/other"] {
            fs::create_dir_all(root.join(member)).expect("create a package");
            fs::write(root.join(member).join("pubspec.yaml"), "name: x\n").expect("write its pubspec");
        }
        fs::create_dir_all(root.join("packages/no_pubspec")).expect("create a dir");
        fs::write(root.join("packages/.DS_Store"), "").expect("write a file");
        assert_eq!(
            dart_members(root),
            ["app", "packages/a", "packages/b", "tools/gen"]
                .map(str::to_owned)
                .into()
        );
    }

    #[test]
    fn zanshin_ui_plans_itself_and_the_app_and_the_app_plans_only_itself() {
        let plan = |path: &str| match plan_for(&[path.to_owned()]) {
            Plan::Steps { steps, .. } => steps,
            Plan::Full(reason) => panic!("expected steps for {path}, got every step: {reason}"),
        };
        assert_eq!(
            plan("packages/zanshin_ui/lib/a.dart"),
            [
                "test-flutter",
                "test-dart-analyze",
                "test-dart-format",
                "test-ui",
                "test-ui-analyze",
                "test-ui-format"
            ]
        );
        assert_eq!(plan("app/lib/a.dart"), APP);
    }

    #[test]
    fn zanshin_shell_prefix_does_not_swallow_its_siblings() {
        assert_eq!(classify("packages/zanshin_shell/lib/a.dart").0, "zanshin_shell");
        assert_eq!(
            classify("packages/zanshin_shell_macos/lib/a.dart").0,
            "zanshin_shell_macos"
        );
    }

    #[test]
    fn zanshin_core_needs_coverage_and_the_app() {
        let core = steps(classify("packages/zanshin_core/lib/src/worker.dart").1);
        assert!(core.contains(&"coverage") && core.contains(&"test-flutter"), "{core:?}");
        assert!(!core.contains(&"test-clippy"), "{core:?}");
    }

    #[test]
    fn rust_in_the_cdylib_reaches_the_app_and_rust_outside_does_not() {
        let jj = steps(classify("crates/zanshin-jj/src/repo.rs").1);
        assert!(jj.contains(&"coverage") && jj.contains(&"test-flutter"), "{jj:?}");
        let mcp = steps(classify("crates/zanshin-mcp/src/main.rs").1);
        assert!(mcp.contains(&"coverage") && !mcp.contains(&"test-flutter"), "{mcp:?}");
    }

    #[test]
    fn manifests_toolchains_and_the_gate_itself_plan_everything() {
        for path in [
            "Makefile.toml",
            "Cargo.lock",
            "crates/zanshin-jj/Cargo.toml",
            "crates/xtask/src/main.rs",
            "pubspec.lock",
            "app/pubspec.yaml",
            "packages/zanshin_ui/pubspec.yaml",
            "coverage-baseline.txt",
            "rust-toolchain.toml",
        ] {
            assert_eq!(classify(path).1, Need::Everything, "{path}");
        }
        assert_eq!(
            classify("somewhere/new.txt").1,
            Need::Everything,
            "unknown paths fail safe"
        );
    }

    #[test]
    fn docs_need_nothing_except_the_ones_tests_read() {
        assert_eq!(classify("docs/coverage.md").1, Need::Nothing);
        assert_eq!(
            classify("_bmad-output/implementation-artifacts/sprint-status.yaml").1,
            Need::Nothing
        );
        assert_eq!(classify("crates/zanshin-jj/README.md").1, Need::Nothing);
        assert_eq!(
            classify("spikes/ffi-payload-bench/dart/pubspec.yaml").1,
            Need::Nothing,
            "a spike's pubspec is no workspace member"
        );
        assert_eq!(
            classify("packages/.DS_Store").1,
            Need::Nothing,
            "Finder metadata never plans a step"
        );
        assert_eq!(steps(classify("docs/ffi-abi.md").1), RUST);
        let ds = "_bmad-output/implementation-artifacts/design_system/tokens/colors.css";
        assert_eq!(steps(classify(ds).1), UI);
        assert_eq!(
            steps(classify("_bmad-output/implementation-artifacts/design_system/readme.md").1),
            UI
        );
    }

    #[test]
    fn plan_for_unions_the_groups_in_gate_order_and_lists_every_path() {
        let paths = vec![
            "app/lib/a.dart".to_owned(),
            "packages/zanshin_core/lib/b.dart".to_owned(),
            "docs/x.md".to_owned(),
        ];
        let Plan::Steps { steps, changed } = plan_for(&paths) else {
            panic!("expected steps")
        };
        assert_eq!(
            steps,
            [
                "test-flutter",
                "test-dart-analyze",
                "test-dart-format",
                "test-core-analyze",
                "test-core-format",
                "coverage"
            ]
        );
        assert_eq!(changed.len(), 3);
    }

    #[test]
    fn plan_for_docs_only_plans_no_step_and_one_unknown_path_plans_all() {
        assert_eq!(
            plan_for(&["docs/a.md".to_owned()]),
            Plan::Steps {
                steps: vec![],
                changed: vec!["docs/a.md (docs)".to_owned()]
            }
        );
        assert!(matches!(
            plan_for(&["app/a.dart".to_owned(), "Cargo.lock".to_owned()]),
            Plan::Full(_)
        ));
    }

    #[test]
    fn every_grouped_step_is_a_gate_step_with_a_wrapper_in_the_test_flow() {
        let makefile = fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Makefile.toml"))
            .expect("Makefile.toml at the workspace root");
        let flow = makefile
            .split("[tasks.test]")
            .nth(1)
            .and_then(|rest| rest.split("\n[").next())
            .expect("[tasks.test]");
        for step in ALL_STEPS {
            assert!(
                makefile.contains(&format!("[tasks.gate-{step}]")),
                "no [tasks.gate-{step}] wrapper"
            );
            assert!(
                flow.contains(&format!("\"gate-{step}\"")),
                "gate-{step} missing from [tasks.test]"
            );
        }
        for (_, _, need) in RULES {
            if let Need::Groups(groups) = need {
                for step in groups.iter().flat_map(|group| group.iter()) {
                    assert!(ALL_STEPS.contains(step), "{step} is not in ALL_STEPS");
                }
            }
        }
    }

    #[test]
    fn stamp_round_trips_and_rejects_a_partial_file() {
        let stamp = Stamp {
            tree: "abc".to_owned(),
            toolchains: "rustc 1 | dart 3".to_owned(),
        };
        assert_eq!(Stamp::parse(&stamp.render()), Some(stamp));
        assert_eq!(Stamp::parse("tree abc\n"), None);
    }

    #[test]
    fn snapshot_sees_untracked_files_skips_ignored_ones_and_leaves_the_index_alone() {
        let repo = tempfile::tempdir().expect("tempdir");
        let root = repo.path();
        git(root, None, &["init", "-q"]).expect("git init");
        fs::write(root.join(".gitignore"), "ignored.txt\n").expect("write");
        fs::write(root.join("a.txt"), "a").expect("write");
        git(root, None, &["add", "--all"]).expect("git add");
        let before = snapshot_tree(root).expect("snapshot");

        fs::write(root.join("b.txt"), "b").expect("write");
        fs::write(root.join("ignored.txt"), "x").expect("write");
        let after = snapshot_tree(root).expect("snapshot");

        assert_eq!(changed_paths(root, &before, &after).expect("diff"), ["b.txt"]);
        let status = git(root, None, &["status", "--porcelain"]).expect("status");
        assert!(
            status.contains("?? b.txt"),
            "b.txt must stay untracked in the real index: {status}"
        );
    }
}
