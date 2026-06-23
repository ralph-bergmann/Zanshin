// SPDX-License-Identifier: MIT

use std::io;
use std::path::{Path, PathBuf};

use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::git::{
    expand_fetch_refspecs, GitFetch, GitFetchRefExpression, GitImportOptions, GitProgress, GitSidebandLineTerminator,
    GitSubprocessCallback, GitSubprocessOptions,
};
use jj_lib::ref_name::{RemoteName, RemoteNameBuf};
use jj_lib::repo::{Repo as _, StoreFactories};
use jj_lib::settings::UserSettings;
use jj_lib::str_util::{StringExpression, StringPattern};
use jj_lib::workspace::{default_working_copy_factories, Workspace};

#[derive(Debug, thiserror::Error)]
pub enum RepoError {
    #[error("path not found: {path}")]
    PathNotFound { path: PathBuf },
    #[error("not a jj repository: {path}")]
    NotARepo { path: PathBuf },
    #[error("init failed: {reason}")]
    InitFailed { reason: String },
    #[error("clone failed: {reason}")]
    CloneFailed { reason: String },
    /// Underlying `jj_lib` failure, flattened to its Display so no `jj_lib` type escapes the public API.
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Selects the jj backend for a new workspace.
#[derive(Clone, Copy)]
pub enum Backend {
    /// Git-backed workspace (`init --git`).
    Git,
}

pub struct Repo {
    workspace: Workspace,
    settings: UserSettings,
}

impl std::fmt::Debug for Repo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Repo")
            .field("workspace_root", &self.workspace.workspace_root())
            .finish_non_exhaustive()
    }
}

impl Repo {
    /// Returns the workspace root path.
    #[must_use]
    pub fn workspace_root(&self) -> &Path {
        self.workspace.workspace_root()
    }

    /// Returns a reference to the underlying jj workspace (crate-internal use only).
    pub(crate) fn workspace(&self) -> &Workspace {
        &self.workspace
    }

    /// Returns the user settings used to open this workspace (crate-internal use only).
    pub(crate) fn settings(&self) -> &UserSettings {
        &self.settings
    }

    /// Returns the working-copy status: files changed between `@` and `@-`.
    ///
    /// Re-resolves to head on every call (ADR-0002). Read-only — does not snapshot
    /// the working copy.
    ///
    /// # Errors
    ///
    /// Returns [`crate::StatusError::NoWorkingCopy`] if the workspace has no
    /// working-copy commit, or [`crate::StatusError::Backend`] on jj-lib failure.
    pub fn status(&self) -> Result<crate::Status, crate::StatusError> {
        crate::status::working_copy_status(&self.workspace)
    }

    /// Opens an existing jj workspace rooted at `path`.
    ///
    /// # Errors
    ///
    /// Returns [`RepoError::PathNotFound`] if `path` does not exist,
    /// [`RepoError::NotARepo`] if `.jj` is absent, or [`RepoError::Backend`] on jj-lib failure.
    pub fn open(path: &Path) -> Result<Self, RepoError> {
        if !path.exists() {
            return Err(RepoError::PathNotFound { path: path.to_owned() });
        }
        if !path.join(".jj").is_dir() {
            return Err(RepoError::NotARepo { path: path.to_owned() });
        }
        let settings = make_settings()?;
        let workspace = Workspace::load(
            &settings,
            path,
            &StoreFactories::default(),
            &default_working_copy_factories(),
        )
        .map_err(|e| RepoError::Backend(e.to_string()))?;
        Ok(Self { workspace, settings })
    }

    /// Initialises a new jj workspace at `path`.
    ///
    /// `backend = Some(Backend::Git)` creates a git-backed workspace;
    /// `backend = None` uses jj's native backend.
    ///
    /// # Errors
    ///
    /// Returns [`RepoError::InitFailed`] on jj-lib workspace initialisation failure.
    pub fn init(path: &Path, backend: Option<Backend>) -> Result<Self, RepoError> {
        let settings = make_settings()?;
        let (workspace, _repo) = match backend {
            Some(Backend::Git) => pollster::block_on(Workspace::init_internal_git(&settings, path))
                .map_err(|e| RepoError::InitFailed { reason: e.to_string() })?,
            None => pollster::block_on(Workspace::init_simple(&settings, path))
                .map_err(|e| RepoError::InitFailed { reason: e.to_string() })?,
        };
        Ok(Self { workspace, settings })
    }

    /// Clones a remote Git repository into a new jj workspace at `target_path`.
    ///
    /// Composes: `init_internal_git` → `add_remote("origin")` → `GitFetch::fetch` → `import_refs`,
    /// then points the working copy at the fetched default branch (a fresh `@` commit on its tip).
    ///
    /// On failure, any partial workspace created under `target_path` is rolled back so a
    /// retry into the same path starts clean.
    ///
    /// # Errors
    ///
    /// Returns [`RepoError::CloneFailed`] if init, remote registration, fetch, or import fails.
    pub fn clone(url: &str, target_path: &Path) -> Result<Self, RepoError> {
        let settings = make_settings()?;
        let created_dir = !target_path.exists();

        match Self::clone_into(&settings, url, target_path) {
            Ok(workspace) => Ok(Self { workspace, settings }),
            Err(e) => {
                // Roll back only what clone created: the whole dir if we created it,
                // otherwise just the `.jj/` that init_internal_git wrote.
                if created_dir {
                    let _ = std::fs::remove_dir_all(target_path);
                } else {
                    let _ = std::fs::remove_dir_all(target_path.join(".jj"));
                }
                Err(e)
            }
        }
    }

    /// Composes the clone steps, returning the workspace reloaded at the committed head.
    fn clone_into(settings: &UserSettings, url: &str, target_path: &Path) -> Result<Workspace, RepoError> {
        // Step 1: Create git-backed jj workspace.
        let (_workspace_init, repo) = pollster::block_on(Workspace::init_internal_git(settings, target_path))
            .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        let remote_name_buf: RemoteNameBuf = "origin".into();
        let remote_name: &RemoteName = &remote_name_buf;

        // Step 2: Write remote to disk via a throwaway transaction.
        // add_remote calls save_git_config() which writes to disk immediately but
        // does NOT update the gix::ThreadSafeRepository's in-memory config cache.
        // We therefore drop this transaction without committing — its only purpose
        // is the disk side-effect. Step 3 reloads from disk to pick it up.
        {
            let mut tx = repo.start_transaction();
            jj_lib::git::add_remote(tx.repo_mut(), remote_name, url, None, gix::remote::fetch::Tags::All)
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
            // tx is intentionally dropped without commit.
        }

        // Step 3: Reload workspace so Workspace::load constructs a fresh Store /
        // GitBackend that reads the git config from disk (now containing "origin").
        let mut workspace = Workspace::load(
            settings,
            target_path,
            &StoreFactories::default(),
            &default_working_copy_factories(),
        )
        .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
        let workspace_name = workspace.workspace_name().to_owned();

        let fresh_repo = pollster::block_on(workspace.repo_loader().load_at_head())
            .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        // Step 4: Fetch + import refs using the fresh repo whose GitBackend sees "origin".
        let subprocess_options = GitSubprocessOptions::from_settings(settings)
            .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        let import_options = GitImportOptions {
            auto_local_bookmark: false,
            abandon_unreachable_commits: true,
            remote_auto_track_bookmarks: std::collections::HashMap::new(),
        };

        let fetch_expr = GitFetchRefExpression {
            bookmark: StringExpression::Pattern(Box::new(
                // WHY: glob("*") selects all remote branches for a full clone.
                StringPattern::glob("*").map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?,
            )),
            tag: StringExpression::Pattern(Box::new(
                // WHY: glob("*") selects all remote tags for a full clone.
                StringPattern::glob("*").map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?,
            )),
        };
        let refspecs = expand_fetch_refspecs(remote_name, fetch_expr)
            .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        let import_stats;
        let default_branch;
        let mut tx = fresh_repo.start_transaction();
        {
            let mut_repo = tx.repo_mut();
            let mut fetcher = GitFetch::new(mut_repo, subprocess_options, &import_options)
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
            // TODO(FR-JJ-13, Epic 6 Story 6.4a): wire NativeCallable progress callback
            fetcher
                .fetch(remote_name, refspecs, &mut NoopCallback, None, None)
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
            import_stats = pollster::block_on(fetcher.import_refs())
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
            default_branch = fetcher
                .get_default_branch(remote_name)
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
        }

        // Point `@` at the fetched default branch: create a fresh working-copy commit
        // on its tip so the cloned workspace shows the default branch's files.
        let target_commit_id = default_branch.as_ref().and_then(|branch| {
            import_stats
                .changed_remote_bookmarks
                .iter()
                .find_map(|(symbol, (_old_ref, new_target))| {
                    if &symbol.name == branch && symbol.remote == remote_name_buf {
                        new_target.as_normal()
                    } else {
                        None
                    }
                })
        });

        let new_wc_commit = match target_commit_id {
            Some(commit_id) => {
                let mut_repo = tx.repo_mut();
                let commit = mut_repo
                    .store()
                    .get_commit(commit_id)
                    .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
                let wc_commit = pollster::block_on(mut_repo.check_out(workspace_name.clone(), &commit))
                    .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
                // check_out rewrites the working-copy commit; jj requires descendants to be
                // rebased before the transaction can commit.
                pollster::block_on(mut_repo.rebase_descendants())
                    .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
                Some(wc_commit)
            }
            None => None,
        };

        let new_repo =
            pollster::block_on(tx.commit("clone")).map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        // Materialise the working copy on disk to match the new `@` commit.
        if let Some(wc_commit) = &new_wc_commit {
            pollster::block_on(workspace.check_out(new_repo.op_id().clone(), None, wc_commit))
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
        }

        // Reload so the returned handle reflects the committed clone + checked-out working copy.
        let workspace = Workspace::load(
            settings,
            target_path,
            &StoreFactories::default(),
            &default_working_copy_factories(),
        )
        .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        Ok(workspace)
    }
}

/// No-op subprocess callback — discards all progress and sideband output.
/// Replaced by a `NativeCallable` in Epic 6 Story 6.4a (FR-JJ-13).
struct NoopCallback;

impl GitSubprocessCallback for NoopCallback {
    fn needs_progress(&self) -> bool {
        false
    }

    fn progress(&mut self, _progress: &GitProgress) -> io::Result<()> {
        Ok(())
    }

    fn local_sideband(&mut self, _message: &[u8], _term: Option<GitSidebandLineTerminator>) -> io::Result<()> {
        Ok(())
    }

    fn remote_sideband(&mut self, _message: &[u8], _term: Option<GitSidebandLineTerminator>) -> io::Result<()> {
        Ok(())
    }
}

fn make_settings() -> Result<UserSettings, RepoError> {
    let mut config = StackedConfig::with_defaults();
    config.add_layer(
        ConfigLayer::parse(
            ConfigSource::User,
            r#"
                    [user]
                    name = "Zanshin"
                    email = "zanshin@localhost"
                    [operation]
                    username = "zanshin"
                    hostname = "localhost"
                "#,
        )
        .map_err(|e| RepoError::Backend(e.to_string()))?,
    );
    UserSettings::from_config(config).map_err(|e| RepoError::Backend(e.to_string()))
}

// ── Decision-input benchmark (ADR-0002 / Story 3.11) ──────────────────────────
//
// NOT a CI gate (perf-gates stay deferred while WIP). These `#[ignore]`d tests
// measure the two numbers the warm-loader-vs-held-cache decision rests on:
//   1. `Workspace::load` (the warm-load cost paid once when a repo becomes active)
//   2. `repo_loader().load_at_head()` (the per-read re-resolution cost — the number
//      that decides whether reload-per-operation is cheap enough; ADR-0002).
// The working-copy SNAPSHOT cost is deliberately NOT measured here: it is paid
// whether you hold or reload (orthogonal to the decision) and needs the
// working-copy mutation path; it is addressed by fsmonitor/Watchman separately.
//
// Run (release, single-threaded, show output):
//   cargo test -p zanshin-jj --release bench_repo_state -- --ignored --nocapture --test-threads=1
#[cfg(test)]
mod bench {
    use std::sync::{Arc, LazyLock};
    use std::time::{Duration, Instant};
    use std::{env, hint};

    use futures::executor::block_on;
    use futures::StreamExt as _;
    use jj_lib::backend::CommitId;
    use jj_lib::graph::TopoGroupedGraph;
    use jj_lib::repo::{ReadonlyRepo, Repo as JjRepo};
    use jj_lib::revset::ResolvedRevsetExpression;
    use test_helpers::extract_fixture;

    use super::Repo;

    static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
        // SAFETY: set once before any repo load, mirroring `tests/repo.rs`; empty
        // values pin jj-lib/git off the developer's globals for reproducible timing.
        unsafe {
            env::set_var("JJ_CONFIG", "");
            env::set_var("GIT_CONFIG_GLOBAL", "");
        }
    });

    fn pin_env() {
        LazyLock::force(&ENV_GUARD);
    }

    /// Returns `(min, median)` over `iters` timed runs after `warmup` untimed runs.
    /// `min` is the least-noisy floor (no scheduler interference / page faults);
    /// `median` is robust to a single outlier. Per-fixture warmup neutralises the
    /// cross-test process warmup, so the result is independent of test-run order.
    fn measure<F: FnMut()>(warmup: u32, iters: u32, mut f: F) -> (Duration, Duration) {
        for _ in 0..warmup {
            f();
        }
        let mut samples: Vec<Duration> = (0..iters)
            .map(|_| {
                let t = Instant::now();
                f();
                t.elapsed()
            })
            .collect();
        samples.sort_unstable();
        (samples[0], samples[samples.len() / 2])
    }

    fn bench_fixture(name: &str) {
        pin_env();
        let fixture = extract_fixture(name).expect("fixture must extract");
        let path = &fixture.path;

        // 1. Workspace::load — fresh open each iteration (the warm-load cost).
        let (load_min, load_med) = measure(5, 51, || {
            let repo = Repo::open(path).expect("open must succeed");
            hint::black_box(&repo);
        });

        // 2. load_at_head() — re-resolve the head operation on an already-open
        //    workspace (the per-read cost under reload-per-operation).
        let repo = Repo::open(path).expect("open must succeed");
        let (res_min, res_med) = measure(5, 51, || {
            let resolved =
                pollster::block_on(repo.workspace.repo_loader().load_at_head()).expect("load_at_head must succeed");
            hint::black_box(&resolved);
        });

        eprintln!("[bench {name}] load: min {load_min:?} / med {load_med:?}  |  load_at_head: min {res_min:?} / med {res_med:?}");
    }

    #[test]
    #[ignore = "decision-input benchmark; run with --ignored --nocapture in --release"]
    fn bench_repo_state_tiny() {
        bench_fixture("tiny-3-commits");
    }

    #[test]
    #[ignore = "decision-input benchmark; run with --ignored --nocapture in --release"]
    fn bench_repo_state_medium() {
        bench_fixture("medium-1k-commits");
    }

    #[test]
    #[ignore = "decision-input benchmark; requires `cargo xtask gen-fixture --size large` first; run with --ignored --nocapture in --release"]
    fn bench_repo_state_large() {
        bench_fixture("large-10k-commits");
    }

    // ── Graph build/derive cost (ADR-0002 AC-4: materialized lane cache vs. lazy stream) ──
    // Walks the whole commit graph in topological order (children-before-parents — the
    // lane-drawable order GG consumes) via jj-lib's Stream-based revset graph API. This is
    // the derive cost a materialized lane cache OR a stream must pay on an op_heads change;
    // `first-100` is the streamed initial-render-slice cost (the GG `QuerySession` page).
    type BenchErr = Box<dyn std::error::Error>;

    fn walk_graph(repo: &Arc<ReadonlyRepo>, limit: Option<usize>) -> Result<usize, BenchErr> {
        // `all()` carries no symbols, so it needs no resolver/extensions/prefix-context.
        let expr = ResolvedRevsetExpression::all();
        let repo_dyn: &dyn JjRepo = repo.as_ref();
        let revset = expr.evaluate(repo_dyn)?;
        // identity id-mapper, annotated for HRTB inference (mirrors GG's commit_id_identity).
        let as_id: for<'a> fn(&'a CommitId) -> &'a CommitId = |id| id;
        let mut stream = Box::pin(TopoGroupedGraph::new(revset.stream_graph(), as_id).stream());
        let mut count = 0usize;
        while let Some(item) = block_on(stream.next()) {
            item?; // GraphNode<CommitId> = (CommitId, Vec<GraphEdge<CommitId>>)
            count += 1;
            if limit.is_some_and(|n| count >= n) {
                break;
            }
        }
        Ok(count)
    }

    fn bench_graph(name: &str) {
        pin_env();
        let fixture = extract_fixture(name).expect("fixture must extract");
        let handle = Repo::open(&fixture.path).expect("open must succeed");
        let repo = pollster::block_on(handle.workspace.repo_loader().load_at_head()).expect("load_at_head");

        let nodes = walk_graph(&repo, None).expect("walk must succeed");
        let (full_min, full_med) = measure(2, 7, || {
            hint::black_box(walk_graph(&repo, None).expect("walk must succeed"));
        });
        let (page_min, page_med) = measure(3, 21, || {
            hint::black_box(walk_graph(&repo, Some(100)).expect("walk must succeed"));
        });

        eprintln!("[graph {name}] nodes={nodes} | full-walk: min {full_min:?} / med {full_med:?} | first-100: min {page_min:?} / med {page_med:?}");
    }

    #[test]
    #[ignore = "decision-input benchmark (AC-4); requires `cargo xtask gen-fixture --size large`; run with --ignored --nocapture in --release"]
    fn bench_graph_large() {
        bench_graph("large-10k-commits");
    }

    #[test]
    #[ignore = "decision-input benchmark (AC-4); run with --ignored --nocapture in --release"]
    fn bench_graph_medium() {
        bench_graph("medium-1k-commits");
    }
}
