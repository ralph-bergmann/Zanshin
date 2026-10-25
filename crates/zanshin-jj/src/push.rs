// SPDX-License-Identifier: MIT

//! `jj git push` at v0.46.0 (Story 9.20, FR-JJ-13b) — [`crate::Repo::git_push`].
//!
//! Ported from `cli/src/commands/git/push.rs` @ v0.46.0 (`cmd_git_push` `:281-662`, the
//! classification `:1132-1254`, `CommitsValidator` `:778-891`, `create_change_bookmarks`
//! `:1303-1356`, `parse_named_bookmark` `:1277-1300`, the target finders `:1358-1485`, the
//! signing `:893-1038`, the descriptions `:247-268`, `:622-655`) and `print_push_stats`
//! (`cli/src/git_util.rs:507-565`). Every `GitPushArgs` parameter is passed through.
//!
//! The push runs in ONE transaction on the operation the pre-verb snapshot left. Its planning
//! phase ([`plan_push`]) — the remotes, the `--change` / `--named` bookmarks created in the
//! transaction, the targets of the mode, the classification, the commit checks and the operation
//! description — writes nothing and is shared by the dry run and the real run: a dry run returns
//! the plan and drops the transaction.
//!
//! What the CLI prints is data here: the `Warning:` lines are registered warnings (the CLI text
//! verbatim), the hints a UI shows (a refused ref's, a rejected commit's, "Pushing to the only
//! existing remote", the push-stats hints) and the status lines ("Creating bookmark …",
//! "Bookmark … already matches …", "Nothing changed.", the signing counts) are fields of
//! [`GitPushOutcome`]. Once the push loop has started, its outcome — per remote and per ref,
//! whether the operation was recorded, the CLI's failure text — is returned as data on `Ok`;
//! only a refusal before the network is an `Err`.
//!
//! The "Rejected commit: …" hint and the commit list of the "Skipped signing … immutable
//! commits:" warning render each commit through the effective `templates.commit_summary`, over
//! the transaction's base repo, as the CLI's base workspace helper does
//! ([`Templates::commit_summary`]).
//!
//! Divergences, all deliberate:
//! - a dry run does not stop at an explicitly named ref that is refused or rejected (the CLI's
//!   dry run errors there like the real run): it returns the whole plan with that row marked
//!   [`PushPath::Abort`] and [`GitPushOutcome::failure`] set to the CLI's error — except that a
//!   `templates.commit_summary` that does not parse refuses the dry run as
//!   [`MutateError::Config`] when a rejection's hint renders it (the CLI refuses such a template
//!   at start-up);
//! - no `--no-integrate-operation` (no Zanshin counterpart).

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use futures::StreamExt as _;
use jj_lib::backend::CommitId as JjCommitId;
use jj_lib::commit::Commit;
use jj_lib::config::StackedConfig;
use jj_lib::git::{GitPushError, GitPushOptions, GitPushRefTargets, GitPushStats};
use jj_lib::id_prefix::IdPrefixContext;
use jj_lib::merge::Diff;
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::RefTarget;
use jj_lib::ref_name::{RefName, RefNameBuf, RemoteName, RemoteNameBuf, RemoteRefSymbol};
use jj_lib::refs::{classify_ref_push_action, LocalAndRemoteRef, RefPushAction};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::revset::{
    ResolvedRevsetExpression, RevsetContainingFn, RevsetExpression, RevsetStreamExt as _, UserRevsetExpression,
};
use jj_lib::settings::SignBehavior;
use jj_lib::str_util::{StringExpression, StringMatcher};
use jj_lib::transaction::Transaction;
use jj_lib::view::View;

use crate::mutate::{be, cfg, rev, MutateError};
use crate::revset::RevsetConfig;
use crate::snapshot::VerbContext;
use crate::template::{TemplateStartup, Templates};
use crate::warning::{WarningKind, Warnings};
use crate::Repo;

// ── Public types ─────────────────────────────────────────────────────────────────

/// `jj git push`'s parameters (Story 9.20) — every `GitPushArgs` field (`push.rs:120-245` @
/// v0.46.0), passed through (FR-JJ-17). Bookmark, tag and remote names are PATTERNS, as in the
/// CLI (a bare word is a glob; `exact:<name>` matches only itself); revisions are revsets.
// WHY: one field per CLI flag (`GitPushArgs`, FR-JJ-17) — the bools ARE the CLI's switches, and
// folding them into enums would re-invent clap's groups the CLI's own struct keeps flat.
#[allow(clippy::struct_excessive_bools)]
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GitPushArgs {
    /// `--remote` (repeatable); `None` = not given: `git.push` (a list or a string), else the
    /// only remote, else `origin`.
    pub remotes: Option<Vec<String>>,
    /// `-b/--bookmark` (repeatable).
    pub bookmarks: Vec<String>,
    /// `-t/--tag` (repeatable).
    pub tags: Vec<String>,
    /// `--all`: every bookmark and tag, new ones included.
    pub all: bool,
    /// `--tracked`: every tracked bookmark and tag.
    pub tracked: bool,
    /// `--deleted`: every deleted bookmark and tag.
    pub deleted: bool,
    /// `--allow-empty-description`.
    pub allow_empty_description: bool,
    /// `--allow-private` (`git.private-commits` is not checked).
    pub allow_private: bool,
    /// `--allow-conflicts`.
    pub allow_conflicts: bool,
    /// `-r/--revision` (repeatable): the bookmarks and tags pointing to these revsets.
    pub revisions: Vec<String>,
    /// `-c/--change` (repeatable): revsets whose commits get a `push-<change id>` bookmark.
    pub changes: Vec<String>,
    /// `--named NAME=REVISION` (repeatable): a new bookmark per argument.
    pub named: Vec<String>,
    /// `--dry-run`: plan only, push nothing.
    pub dry_run: bool,
    /// `-o/--option` (repeatable): git push options.
    pub options: Vec<String>,
}

/// Whether a ref is a bookmark or a tag.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushRefKind {
    /// A bookmark (`refs/heads/<name>` on the remote).
    Bookmark,
    /// A tag (`refs/tags/<name>` on the remote).
    Tag,
}

/// What the push does with a ref of its plan.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushPath {
    /// The ref is pushed.
    Push,
    /// The mode refused the ref (or a commit it would push) and skips it, with a warning — the
    /// bare push, `-r`, `--all`, `--tracked` and `--deleted`. The rest is pushed.
    Skip,
    /// An explicitly named ref (`-b`, `-t`, `--change`, `--named`) is refused or would push a
    /// rejected commit: the whole push is refused (only a dry run gets this far).
    Abort,
}

/// The CLI's message and hint for a refused ref (`push.rs:1157-1254` @ v0.46.0), verbatim.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushRefusal {
    /// The refusal, e.g. "Refusing to create new remote bookmark main@origin".
    pub message: String,
    /// The CLI's hint, e.g. "Run `jj bookmark track main@origin` and try again."; `None` where
    /// the CLI gives none.
    pub hint: Option<String>,
}

/// A commit the push refuses to send (`push.rs:778-891` @ v0.46.0).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushCommitRejection {
    /// The rejected commit (full hex).
    pub commit_id: String,
    /// Its reasons in the CLI's order: "has no description", "has no author and/or committer
    /// set", "has conflicts", "is private".
    pub reasons: Vec<String>,
    /// The CLI's text: "Won't push bookmark|tag <name>: commit <hash> <reasons>" on the skip
    /// path, "Won't push commit <hash> since it <reasons>" on the abort path.
    pub message: String,
    /// The CLI's hints: "Rejected commit: <summary>" (abort path only), then "Configured
    /// git.private-commits: '<revset>'" for a private commit.
    pub hints: Vec<String>,
}

/// What happened to a pushed ref (`GitPushStats`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushRefStatus {
    /// The remote accepted it and the remote-tracking ref was updated.
    Pushed,
    /// The remote had moved since the last fetch: the lease failed.
    LeaseRejected,
    /// The remote rejected the update.
    RemoteRejected,
    /// Pushed, but its remote-tracking ref could not be updated locally.
    Unexported,
}

/// A ref and its kind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushRefName {
    /// Bookmark or tag.
    pub kind: PushRefKind,
    /// The name (unquoted).
    pub name: String,
}

/// One ref of a remote's plan.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushRef {
    /// Bookmark or tag.
    pub kind: PushRefKind,
    /// The name (unquoted).
    pub name: String,
    /// Where the remote has it now (full commit hex); `None` = absent there, or not reported for
    /// a ref refused as conflicted (locally or on the remote) or as an untracked remote ref.
    pub before: Option<String>,
    /// Where the push moves it (full commit hex; after sign-on-push, the signed commit);
    /// `None` = deleted there, or not reported for a ref refused as conflicted or untracked.
    pub after: Option<String>,
    /// The move in jj's words — "move forward|backward|sideways from <old> to <new>", "add to
    /// <new>", "delete from <old>" (12-hex ids, `push.rs:1057-1085`); `None` for a conflicted
    /// ref.
    pub action: Option<String>,
    /// What the push does with it.
    pub path: PushPath,
    /// The mode's refusal (with [`PushPath::Skip`] or [`PushPath::Abort`]).
    pub refusal: Option<PushRefusal>,
    /// The refusal the ref would get if it were named explicitly (`-b` / `-t`: `allow_new` = not
    /// tracked on any remote, `allow_delete` on); `None` = it could be pushed explicitly.
    pub explicit_refusal: Option<PushRefusal>,
    /// The commit the push refuses to send for this ref.
    pub rejection: Option<PushCommitRejection>,
    /// After a real push: what happened to it; `None` in a plan, or when the remote was not
    /// reached.
    pub status: Option<PushRefStatus>,
    /// The remote's or the export's reason for a non-`Pushed` status, when there is one.
    pub status_reason: Option<String>,
}

/// One remote's plan and result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushRemote {
    /// The remote's name.
    pub name: String,
    /// Its refs: the ones pushed, skipped and refused, in the CLI's processing order.
    pub refs: Vec<PushRef>,
    /// Explicitly named refs that are already where the push would put them — the CLI's
    /// "Bookmark <name>@<remote> already matches <name>" / "Tag …" status lines.
    pub already_matches: Vec<PushRefName>,
    /// Whether the push to this remote ran (a real push only).
    pub finished: bool,
    /// The error that stopped the push at this remote (the CLI's `GitPushError` text).
    pub error: Option<String>,
}

/// A bookmark `--change` created — the CLI's "Creating bookmark <name> for revision <change>".
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushCreatedBookmark {
    /// The bookmark's name.
    pub name: String,
    /// The commit's change id (reverse hex).
    pub change_id: String,
}

/// What sign-on-push did (`push.rs:1023-1034` @ v0.46.0).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PushSigning {
    /// "Updated signatures of N commits."
    pub updated_signatures: usize,
    /// "Rebased N descendant commits."
    pub rebased_descendants: usize,
}

/// Why a push failed, after the planning phase.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushFailureKind {
    /// A dry run whose explicitly named ref is refused (the real run's `jj.push_ref_refused`).
    RefRefused,
    /// A dry run whose explicitly named ref would push a rejected commit (the real run's
    /// `jj.push_commit_rejected`).
    CommitRejected,
    /// Some refs were not pushed (lease, remote rejection, local export) — the CLI's "Failed to
    /// push some bookmarks". The operation may still have been recorded.
    SomeRefsFailed,
    /// The push itself failed at a remote (the network, the credentials, an invalid remote
    /// name): the CLI's `GitPushError` — earlier remotes may already have their refs, nothing is
    /// recorded. Also a step after the push loop that failed (the error's text);
    /// [`GitPushOutcome::recorded`] then says whether the operation was written.
    PushError,
    /// The push's cancel token was cancelled (Story 9.52): the push stopped before the next
    /// remote, or a git push failed after the cancel killed it. Earlier remotes may already have
    /// their refs ([`PushRemote::finished`]); nothing is recorded.
    Cancelled,
}

/// A push failure as data — the CLI's non-zero exit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushFailure {
    /// What failed.
    pub kind: PushFailureKind,
    /// The CLI's error text.
    pub message: String,
    /// The CLI's hint, when it gives one.
    pub hint: Option<String>,
}

/// The outcome of [`crate::Repo::git_push`]: the plan per remote and per ref, and — after a real
/// push — what happened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitPushOutcome {
    /// The matched remotes in sorted order.
    pub remotes: Vec<PushRemote>,
    /// The bookmarks `--change` created in the push's transaction.
    pub created_bookmarks: Vec<PushCreatedBookmark>,
    /// Hints the UI shows verbatim: "Pushing to the only existing remote: <name>", and after a
    /// push the CLI's push-stats hints.
    pub hints: Vec<String>,
    /// What sign-on-push did; `None` when it did not run (`git.sign-on-push` off, a dry run, or
    /// nothing needed signing).
    pub signing: Option<PushSigning>,
    /// Every remote's plan was empty — the CLI's "Nothing changed.": nothing pushed, nothing
    /// created, no operation.
    pub nothing_changed: bool,
    /// The outcome of a dry run: nothing was pushed or written.
    pub dry_run: bool,
    /// Whether the push's operation was written (only after a real push, when every ref
    /// succeeded or at least one was exported).
    pub recorded: bool,
    /// The operation's description as the CLI writes it (e.g. "push bookmark main to git remote
    /// origin"); in a dry run, the one the real push would write; `None` when no ref would be
    /// pushed (nothing changed, or a dry run whose every explicitly named ref aborts).
    pub description: Option<String>,
    /// The operation-log head after the call — the push's operation when recorded, else the
    /// head the push started from.
    pub new_op_id: String,
    /// The failure, when the push did not fully succeed.
    pub failure: Option<PushFailure>,
}

// ── The CLI's texts ──────────────────────────────────────────────────────────────

/// `push.rs:272`.
const TX_DESC_PUSH: &str = "push ";

/// The 12-hex short id the CLI prints (`short_commit_hash`).
fn short_hash(id: &JjCommitId) -> String {
    id.hex()[..12].to_owned()
}

impl PushRefKind {
    fn word(self) -> &'static str {
        match self {
            Self::Bookmark => "bookmark",
            Self::Tag => "tag",
        }
    }
}

/// The two classification flags of the CLI's `ClassifyParams` (`push.rs:664-668`).
#[derive(Debug, Clone, Copy)]
struct ClassifyParams {
    allow_new: bool,
    allow_delete: bool,
}

/// The CLI's `classify_bookmark_update` / `classify_tag_update` (`push.rs:1157-1254`).
fn classify(
    kind: PushRefKind,
    symbol: RemoteRefSymbol<'_>,
    targets: LocalAndRemoteRef<'_>,
    params: ClassifyParams,
) -> Result<Option<Diff<Option<JjCommitId>>>, PushRefusal> {
    let name = symbol.name.as_symbol();
    let refusal = |message: String, hint: Option<String>| Err(PushRefusal { message, hint });
    match (kind, classify_ref_push_action(targets)) {
        (_, RefPushAction::AlreadyMatches) => Ok(None),
        (PushRefKind::Bookmark, RefPushAction::LocalConflicted) => refusal(
            format!("Bookmark {name} is conflicted"),
            Some("Run `jj bookmark list` to inspect, and use `jj bookmark set` to fix it up.".to_owned()),
        ),
        (PushRefKind::Tag, RefPushAction::LocalConflicted) => refusal(
            format!("Tag {name} is conflicted"),
            Some("Run `jj tag list` to inspect, and use `jj tag set` to fix it up.".to_owned()),
        ),
        (PushRefKind::Bookmark, RefPushAction::RemoteConflicted) => refusal(
            format!("Bookmark {symbol} is conflicted"),
            Some("Run `jj git fetch` to update the conflicted remote bookmark.".to_owned()),
        ),
        (PushRefKind::Tag, RefPushAction::RemoteConflicted) => refusal(
            format!("Tag {symbol} is conflicted"),
            Some("Run `jj git fetch` to update the conflicted remote tag.".to_owned()),
        ),
        (PushRefKind::Bookmark, RefPushAction::RemoteUntracked) => refusal(
            format!("Non-tracking remote bookmark {symbol} exists"),
            Some(format!(
                "Run `jj bookmark track {symbol}` to import the remote bookmark."
            )),
        ),
        (PushRefKind::Tag, RefPushAction::RemoteUntracked) => {
            refusal(format!("Non-tracking remote tag {symbol} exists"), None)
        }
        (kind, RefPushAction::Update(_)) if !targets.remote_ref.is_tracked() && !params.allow_new => refusal(
            format!("Refusing to create new remote {} {symbol}", kind.word()),
            Some(format!("Run `jj {} track {symbol}` and try again.", kind.word())),
        ),
        (PushRefKind::Bookmark, RefPushAction::Update(update)) if update.after.is_none() && !params.allow_delete => {
            refusal(
                format!("Refusing to push deleted bookmark {name}"),
                Some(
                    "Push deleted bookmarks with --deleted or forget the bookmark to suppress this warning.".to_owned(),
                ),
            )
        }
        (PushRefKind::Tag, RefPushAction::Update(update)) if update.after.is_none() && !params.allow_delete => refusal(
            format!("Refusing to push deleted tag {name}"),
            Some("Push deleted tags with --deleted.".to_owned()),
        ),
        (_, RefPushAction::Update(update)) => Ok(Some(update)),
    }
}

/// The CLI's `has_tracked_remote_bookmarks` / `has_tracked_remote_tags` (`cli_util.rs:3478-3498`
/// @ v0.46.0): a tracked remote ref of that name on any remote but the default-ignored `git`.
fn has_tracked_remote(repo: &dyn jj_lib::repo::Repo, kind: PushRefKind, name: &RefName) -> bool {
    let remote_matcher = if jj_lib::git::get_git_backend(repo.store()).is_ok() {
        StringExpression::exact(jj_lib::git::REMOTE_NAME_FOR_LOCAL_GIT_REPO.as_str())
            .negated()
            .to_matcher()
    } else {
        StringMatcher::all()
    };
    let name_matcher = StringMatcher::exact(name.as_str());
    let tracked = match kind {
        PushRefKind::Bookmark => repo
            .view()
            .remote_bookmarks_matching(&name_matcher, &remote_matcher)
            .any(|(_, remote_ref)| remote_ref.is_tracked()),
        PushRefKind::Tag => repo
            .view()
            .remote_tags_matching(&name_matcher, &remote_matcher)
            .any(|(_, remote_ref)| remote_ref.is_tracked()),
    };
    tracked
}

/// The explicit classification of a ref (Story 9.20 item 2): as `-b` / `-t` would classify it.
fn explicit_refusal(
    repo: &dyn jj_lib::repo::Repo,
    kind: PushRefKind,
    symbol: RemoteRefSymbol<'_>,
    targets: LocalAndRemoteRef<'_>,
) -> Option<PushRefusal> {
    let params = ClassifyParams {
        allow_new: !has_tracked_remote(repo, kind, symbol.name),
        allow_delete: true,
    };
    classify(kind, symbol, targets, params).err()
}

// ── Commit checks ────────────────────────────────────────────────────────────────

/// A commit the checks reject, before it is worded for a path.
struct Rejected {
    commit: Commit,
    reasons: Vec<&'static str>,
    hint: Option<String>,
}

impl Rejected {
    fn message(&self) -> String {
        self.reasons.join(" and ")
    }

    /// The skip path's rejection (`push.rs:744-750`).
    fn skipped(&self, kind: PushRefKind, name: &RefName) -> PushCommitRejection {
        PushCommitRejection {
            commit_id: self.commit.id().hex(),
            reasons: self.reasons.iter().map(|r| (*r).to_owned()).collect(),
            message: format!(
                "Won't push {} {}: commit {} {}",
                kind.word(),
                name.as_symbol(),
                short_hash(self.commit.id()),
                self.message()
            ),
            hints: self.hint.iter().cloned().collect(),
        }
    }

    /// The abort path's rejection (`push.rs:762-775`): the "Rejected commit:" hint renders
    /// `templates.commit_summary` over `repo`.
    ///
    /// # Errors
    ///
    /// - [`MutateError::Config`] — `templates.commit_summary` is not a string or does not parse.
    fn aborted(
        &self,
        repo: &dyn jj_lib::repo::Repo,
        templates: &Templates<'_>,
    ) -> Result<PushCommitRejection, MutateError> {
        let mut hints = vec![format!(
            "Rejected commit: {}",
            templates.commit_summary(repo, &self.commit)?
        )];
        hints.extend(self.hint.iter().cloned());
        Ok(PushCommitRejection {
            commit_id: self.commit.id().hex(),
            reasons: self.reasons.iter().map(|r| (*r).to_owned()).collect(),
            message: format!(
                "Won't push commit {} since it {}",
                short_hash(self.commit.id()),
                self.message()
            ),
            hints,
        })
    }
}

/// The CLI's `CommitsValidator` (`push.rs:778-891`), built per remote — with the call's templates,
/// which render a rejection's summary hint.
struct CommitsValidator<'r, 't> {
    repo: &'r ReadonlyRepo,
    templates: Templates<'t>,
    known_heads: Vec<JjCommitId>,
    immutable_heads: Arc<ResolvedRevsetExpression>,
    private_commits: Option<(String, Box<RevsetContainingFn<'r>>)>,
    allow_empty_description: bool,
    allow_conflicts: bool,
}

impl<'r, 't> CommitsValidator<'r, 't> {
    fn new(base: &'r ReadonlyRepo, remote: &RemoteName, planner: &mut Planner<'t>) -> Result<Self, MutateError> {
        let known_heads = base
            .view()
            .remote_bookmarks(remote)
            .flat_map(|(_, old_head)| old_head.target.present_adds())
            .cloned()
            .collect();
        // The CLI resolves with a bare `.resolve()?` here, no config-error wrapping, through
        // `attach_revset_evaluator`'s id-prefix context (`cli/src/commands/git/push.rs:803-811` @
        // v0.46.0), as `git.private-commits` below.
        let immutable_heads =
            crate::revset::resolve_expression(base, planner.immutable_heads, Some(&planner.prefixes)).map_err(cfg)?;
        let private_commits = if planner.args.allow_private {
            None
        } else {
            let text = crate::config::git_private_commits(planner.config).map_err(cfg)?;
            let expression = planner.parse(&text)?;
            let set = crate::revset::evaluate_revset(base, &expression, Some(&planner.prefixes)).map_err(rev)?;
            Some((text, set.containing_fn()))
        };
        Ok(Self {
            repo: base,
            templates: Templates::new(
                planner.config,
                planner.immutable,
                planner.template_startup,
                planner.repo.workspace(),
            ),
            known_heads,
            immutable_heads,
            private_commits,
            allow_empty_description: planner.args.allow_empty_description,
            allow_conflicts: planner.args.allow_conflicts,
        })
    }

    /// The first commit of `(known | immutable_heads())..new_heads` that is not ready; on
    /// success the new heads become known (`push.rs:844-890`).
    fn validate(&mut self, new_heads: &[JjCommitId]) -> Result<Option<Rejected>, MutateError> {
        let range = RevsetExpression::commits(self.known_heads.clone())
            .union(&self.immutable_heads)
            .range(&RevsetExpression::commits(new_heads.to_vec()));
        let revset = range.evaluate(self.repo).map_err(be)?;
        let store = self.repo.store();
        let rejected = pollster::block_on(async {
            let mut commits = std::pin::pin!(revset.stream().commits(store));
            while let Some(commit) = commits.next().await {
                let commit = commit.map_err(be)?;
                let mut reasons = Vec::new();
                let mut hint = None;
                if commit.description().is_empty() && !self.allow_empty_description {
                    reasons.push("has no description");
                }
                if commit.author().name.is_empty()
                    || commit.author().email.is_empty()
                    || commit.committer().name.is_empty()
                    || commit.committer().email.is_empty()
                {
                    reasons.push("has no author and/or committer set");
                }
                if commit.has_conflict() && !self.allow_conflicts {
                    reasons.push("has conflicts");
                }
                if let Some((text, is_private)) = &self.private_commits {
                    if is_private(commit.id()).await.map_err(be)? {
                        reasons.push("is private");
                        hint = Some(format!("Configured git.private-commits: '{text}'"));
                    }
                }
                if !reasons.is_empty() {
                    return Ok::<_, MutateError>(Some(Rejected { commit, reasons, hint }));
                }
            }
            Ok(None)
        })?;
        if rejected.is_none() {
            self.known_heads.extend(new_heads.iter().cloned());
        }
        Ok(rejected)
    }
}

// ── The plan ─────────────────────────────────────────────────────────────────────

/// A ref of a remote's plan, before it is rendered.
struct Row {
    kind: PushRefKind,
    name: RefNameBuf,
    update: Option<Diff<Option<JjCommitId>>>,
    path: PushPath,
    refusal: Option<PushRefusal>,
    explicit_refusal: Option<PushRefusal>,
    rejection: Option<PushCommitRejection>,
}

/// One remote's plan: what is pushed (the CLI's `GitPushRefTargets`) and every row.
struct RemotePlan {
    remote: RemoteNameBuf,
    updates: GitPushRefTargets,
    rows: Vec<Row>,
    already_matches: Vec<PushRefName>,
}

impl RemotePlan {
    fn push(
        &mut self,
        kind: PushRefKind,
        name: &RefName,
        update: Diff<Option<JjCommitId>>,
        explicit: Option<PushRefusal>,
    ) {
        let list = match kind {
            PushRefKind::Bookmark => &mut self.updates.bookmarks,
            PushRefKind::Tag => &mut self.updates.tags,
        };
        list.push((name.to_owned(), update.clone()));
        self.rows.push(Row {
            kind,
            name: name.to_owned(),
            update: Some(update),
            path: PushPath::Push,
            refusal: None,
            explicit_refusal: explicit,
            rejection: None,
        });
    }

    fn is_empty(&self) -> bool {
        self.updates.bookmarks.is_empty() && self.updates.tags.is_empty()
    }
}

/// The planning phase's result (Story 9.20): shared by the dry run and the real run.
pub(crate) struct PushPlan {
    remotes: Vec<RemotePlan>,
    created: Vec<PushCreatedBookmark>,
    hints: Vec<String>,
    /// The first explicitly named ref that refuses the whole push — only a dry run gets here.
    abort: Option<PushFailure>,
}

impl PushPlan {
    fn nothing_changed(&self) -> bool {
        self.remotes.iter().all(RemotePlan::is_empty)
    }

    /// The operation description (`push.rs:625-652`).
    fn description(&self, args: &GitPushArgs) -> String {
        let remotes = match self.remotes.as_slice() {
            [one] => format!("git remote {}", one.remote.as_symbol()),
            many => format!(
                "git remotes {}",
                many.iter()
                    .map(|plan| plan.remote.as_symbol().to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        };
        if args.all {
            format!("{TX_DESC_PUSH}all bookmarks/tags to {remotes}")
        } else if args.tracked {
            format!("{TX_DESC_PUSH}all tracked bookmarks/tags to {remotes}")
        } else if args.deleted {
            format!("{TX_DESC_PUSH}all deleted bookmarks/tags to {remotes}")
        } else {
            format!("{TX_DESC_PUSH}{} to {remotes}", self.updates_term())
        }
    }

    /// The CLI's `make_updates_term` (`push.rs:247-268`): the names deduplicated across remotes
    /// in first-seen order, bookmarks then tags.
    fn updates_term(&self) -> String {
        let mut bookmarks: Vec<&RefName> = Vec::new();
        let mut tags: Vec<&RefName> = Vec::new();
        for plan in &self.remotes {
            for (name, _) in &plan.updates.bookmarks {
                if !bookmarks.contains(&name.as_ref()) {
                    bookmarks.push(name);
                }
            }
            for (name, _) in &plan.updates.tags {
                if !tags.contains(&name.as_ref()) {
                    tags.push(name);
                }
            }
        }
        [("bookmark", "bookmarks", bookmarks), ("tag", "tags", tags)]
            .into_iter()
            .filter_map(|(kind, kinds, refs)| match refs.as_slice() {
                [] => None,
                [one] => Some(format!("{kind} {}", one.as_symbol())),
                many => Some(format!(
                    "{kinds} {}",
                    many.iter()
                        .map(|name| name.as_symbol().to_string())
                        .collect::<Vec<_>>()
                        .join(", ")
                )),
            })
            .collect::<Vec<_>>()
            .join(", ")
    }
}

/// The planning phase's inputs.
struct Planner<'a> {
    repo: &'a Repo,
    args: &'a GitPushArgs,
    config: &'a StackedConfig,
    parse_config: RevsetConfig,
    /// The immutable set the start-up environment parsed — the template language's.
    immutable: &'a Arc<UserRevsetExpression>,
    /// The start-up environment's template half — the template language's alias map and
    /// short-prefixes expression.
    template_startup: &'a TemplateStartup,
    /// The id-prefix context every user and config revset of the call resolves through.
    prefixes: IdPrefixContext,
    immutable_heads: &'a Arc<UserRevsetExpression>,
    sink: &'a mut Warnings,
    /// Whether the plan stops at the first explicit refusal (a real push) or records it (a dry
    /// run).
    stop_on_abort: bool,
}

impl Planner<'_> {
    /// A user revset in the workspace's context, its diagnostics under "In revset expression".
    fn parse(&mut self, text: &str) -> Result<Arc<UserRevsetExpression>, MutateError> {
        crate::revset::parse_revset_with(self.repo, &self.parse_config, text, self.sink).map_err(rev)
    }

    /// A user revset's commits against `base`, in stream order.
    fn commit_ids(&mut self, base: &ReadonlyRepo, text: &str) -> Result<Vec<JjCommitId>, MutateError> {
        let expression = self.parse(text)?;
        collect_ids(base, &expression, &self.prefixes)
    }

    fn warn(&mut self, kind: WarningKind, message: String) {
        self.sink.push(kind, message);
    }
}

/// Every commit id of `expression` against `repo`, its symbols resolved through `prefixes`.
fn collect_ids(
    repo: &dyn jj_lib::repo::Repo,
    expression: &Arc<UserRevsetExpression>,
    prefixes: &IdPrefixContext,
) -> Result<Vec<JjCommitId>, MutateError> {
    let set = crate::revset::evaluate_revset(repo, expression, Some(prefixes)).map_err(rev)?;
    pollster::block_on(async {
        let mut ids = Vec::new();
        let mut stream = set.stream();
        while let Some(id) = stream.next().await {
            ids.push(id.map_err(be)?);
        }
        Ok(ids)
    })
}

/// Refuses the CLI's clap conflicts (`push.rs:121-122`, `:185`): `--all` / `--tracked` with each
/// other or with a specific ref, `--deleted` with a specific ref — before the pre-verb snapshot
/// ([`crate::Repo::git_push`]), as the CLI parses its arguments before it snapshots.
///
/// # Errors
///
/// [`MutateError::InvalidInput`] naming the conflicting flags.
pub(crate) fn check_flags(args: &GitPushArgs) -> Result<(), MutateError> {
    let specific = [
        ("--bookmark", !args.bookmarks.is_empty()),
        ("--tag", !args.tags.is_empty()),
        ("--revision", !args.revisions.is_empty()),
        ("--change", !args.changes.is_empty()),
        ("--named", !args.named.is_empty()),
    ];
    let given_specific = specific.iter().find(|(_, given)| *given).map(|(flag, _)| *flag);
    let conflict = |a: &str, b: &str| {
        Err(MutateError::invalid(format!(
            "the argument '{a}' cannot be used with '{b}'"
        )))
    };
    if args.all && args.tracked {
        return conflict("--all", "--tracked");
    }
    for (flag, given) in [
        ("--all", args.all),
        ("--tracked", args.tracked),
        ("--deleted", args.deleted),
    ] {
        if let (true, Some(specific)) = (given, given_specific) {
            return conflict(flag, specific);
        }
    }
    Ok(())
}

/// The remotes the push goes to (`push.rs:294-322`, `get_default_push_remotes` `:1107-1130`).
/// The remote expression — `--remote`'s patterns, else `git.push`'s — is built BEFORE the remotes
/// are listed, in the CLI's order (Story 9.56, as the fetch's): a malformed `git.push` or an
/// unparsable `--remote` refuses even without a Git backend.
fn resolve_remotes(
    base: &ReadonlyRepo,
    args: &GitPushArgs,
    config: &StackedConfig,
    sink: &mut Warnings,
    hints: &mut Vec<String>,
) -> Result<Vec<RemoteNameBuf>, MutateError> {
    let (given, configured) = match &args.remotes {
        Some(texts) => (Some(crate::bookmark_ops::union_expression(texts)?), None),
        None => (None, configured_remotes(config, PUSH_REMOTES)?),
    };
    let all_remotes = jj_lib::git::get_all_remote_names(base.store()).map_err(|_| MutateError::NotAGitRepo)?;
    let matching = match given {
        Some(expression) => matching_remotes(&all_remotes, &expression, PUSH_REMOTES.unmatched, sink),
        None => default_remotes(&all_remotes, configured, PUSH_REMOTES, sink, hints),
    };
    if matching.is_empty() {
        return Err(MutateError::invalid("No git remotes to push to".to_owned()));
    }
    Ok(matching)
}

/// One verb's default-remote resolution (Story 9.30): push and fetch resolve their remotes the
/// same way — `get_default_push_remotes` (`push.rs:1107-1130` @ v0.46.0) and
/// `get_default_fetch_remotes` (`fetch.rs:267-290`) differ only in the key they read, the verb in
/// their only-remote hint and the warning an unmatched name raises.
#[derive(Debug, Clone, Copy)]
pub(crate) struct RemoteDefaults {
    /// Reads the verb's `git.push` / `git.fetch`.
    configured: fn(&StackedConfig) -> Result<Option<Vec<String>>, crate::ConfigError>,
    /// The only-remote hint before the remote's name.
    only_remote_hint: &'static str,
    /// What an exact name no remote carries warns.
    pub(crate) unmatched: WarningKind,
}

/// `jj git push`'s default-remote resolution.
pub(crate) const PUSH_REMOTES: RemoteDefaults = RemoteDefaults {
    configured: crate::config::git_push_remotes,
    only_remote_hint: "Pushing to the only existing remote",
    unmatched: WarningKind::PushRemotesUnmatched,
};

/// `jj git fetch`'s default-remote resolution (Story 9.30).
pub(crate) const FETCH_REMOTES: RemoteDefaults = RemoteDefaults {
    configured: crate::config::git_fetch_remotes,
    only_remote_hint: "Fetching from the only existing remote",
    unmatched: WarningKind::FetchRemotesUnmatched,
};

/// The union of the name patterns the verb's key (`git.push` / `git.fetch`) names — a name, a
/// list or a pattern — or `None` when it is unset: the configured half of
/// [`default_remotes`]'s resolution, split off so the fetch can read it before listing the
/// remotes, in the CLI's order (`fetch.rs:142-149` @ v0.46.0).
///
/// # Errors
///
/// - [`MutateError::Config`] — the key is neither a string nor a list of strings.
/// - [`MutateError::InvalidInput`] — one of its patterns does not parse.
pub(crate) fn configured_remotes(
    config: &StackedConfig,
    defaults: RemoteDefaults,
) -> Result<Option<StringExpression>, MutateError> {
    (defaults.configured)(config)
        .map_err(cfg)?
        .map(|texts| crate::bookmark_ops::union_expression(&texts))
        .transpose()
}

/// The remotes a push or fetch WITHOUT `--remote` goes to (`push.rs:294-323`'s default arm,
/// `get_default_push_remotes` `:1107-1130`; `get_default_fetch_remotes`, `fetch.rs:267-290` @
/// v0.46.0), out of `all_remotes` in their order: the remotes `configured` (the verb's key, read
/// by [`configured_remotes`]) matches, else the single remote (with the CLI's only-remote hint
/// into `hints` unless it is `origin`), else `origin`. An exact name no remote carries warns
/// `defaults.unmatched`; matching none is `[]` — the verb refuses that, [`default_remote_names`]
/// reports it. Shared by both verbs and both queries (Stories 9.54, 9.30).
pub(crate) fn default_remotes(
    all_remotes: &[RemoteNameBuf],
    configured: Option<StringExpression>,
    defaults: RemoteDefaults,
    sink: &mut Warnings,
    hints: &mut Vec<String>,
) -> Vec<RemoteNameBuf> {
    let expression = if let Some(expression) = configured {
        expression
    } else if let [single] = all_remotes {
        if single.as_str() != "origin" {
            hints.push(format!("{}: {}", defaults.only_remote_hint, single.as_symbol()));
        }
        StringExpression::exact(single.as_str())
    } else {
        StringExpression::exact("origin")
    };
    matching_remotes(all_remotes, &expression, defaults.unmatched, sink)
}

/// The remotes of `all_remotes` `expression` matches, in their order; each exact name no remote
/// carries warns `unmatched` (`push.rs:309-321`, `fetch.rs:150-169` @ v0.46.0).
pub(crate) fn matching_remotes(
    all_remotes: &[RemoteNameBuf],
    expression: &StringExpression,
    unmatched: WarningKind,
    sink: &mut Warnings,
) -> Vec<RemoteNameBuf> {
    let matcher = expression.to_matcher();
    let matching: Vec<RemoteNameBuf> = all_remotes
        .iter()
        .filter(|remote| matcher.is_match(remote.as_str()))
        .cloned()
        .collect();
    let missing: Vec<String> = expression
        .exact_strings()
        .filter(|name| all_remotes.iter().all(|remote| remote.as_str() != *name))
        .map(|name| RemoteName::new(name).as_symbol().to_string())
        .collect();
    if !missing.is_empty() {
        sink.push(
            unmatched,
            format!("No matching remotes for names: {}", missing.join(", ")),
        );
    }
    matching
}

/// The remotes `jj git push` / `jj git fetch` without `--remote` would use (Stories 9.54, 9.30)
/// — see [`crate::Repo::git_push_remotes`] and [`crate::Repo::git_fetch_remotes`]. A non-Git
/// backend has none; the only-remote hint is dropped.
///
/// # Errors
///
/// See [`configured_remotes`].
pub(crate) fn default_remote_names(
    workspace: &jj_lib::workspace::Workspace,
    config: &StackedConfig,
    defaults: RemoteDefaults,
    sink: &mut Warnings,
) -> Result<Vec<String>, MutateError> {
    let Ok(all_remotes) = jj_lib::git::get_all_remote_names(workspace.repo_loader().store()) else {
        return Ok(Vec::new());
    };
    let configured = configured_remotes(config, defaults)?;
    let remotes = default_remotes(&all_remotes, configured, defaults, sink, &mut Vec::new());
    Ok(remotes.into_iter().map(RemoteNameBuf::into_string).collect())
}

/// The CLI's `parse_named_bookmark` (`push.rs:1277-1300`).
fn parse_named(argument: &str) -> Result<(RefNameBuf, &str), MutateError> {
    let invalid =
        |reason: String| MutateError::invalid_hinted(reason, "For example, `--named myfeature=@` is valid syntax");
    let Some((name, revision)) = argument.split_once('=') else {
        return Err(invalid(format!(
            "Argument '{argument}' must include '=' and have the form NAME=REVISION"
        )));
    };
    if name.is_empty() || revision.is_empty() {
        return Err(invalid(format!(
            "Argument '{argument}' must have the form NAME=REVISION, with both NAME and REVISION non-empty"
        )));
    }
    let parsed = jj_lib::revset::parse_symbol(name).map_err(|e| {
        invalid(format!(
            "Could not parse '{name}' as a bookmark name: Failed to parse bookmark name: {}",
            e.kind()
        ))
    })?;
    Ok((RefNameBuf::from(parsed), revision))
}

/// The CLI's `ensure_new_bookmark_name` (`push.rs:1256-1275`).
fn ensure_new_bookmark_name(repo: &dyn jj_lib::repo::Repo, name: &RefName) -> Result<(), MutateError> {
    if repo.view().get_local_bookmark(name).is_present() {
        let symbol = name.as_symbol();
        return Err(MutateError::BookmarkExists {
            name: name.as_str().to_owned(),
            hints: vec![format!(
                "Use 'jj bookmark move' to move it, and 'jj git push -b {symbol}' to push it"
            )],
        });
    }
    if has_tracked_remote(repo, PushRefKind::Bookmark, name) {
        return Err(MutateError::BookmarkTrackedRemoteExists {
            name: name.as_str().to_owned(),
        });
    }
    Ok(())
}

/// The single commit `revision` resolves to — the CLI's `resolve_single_rev`
/// (`cli_util.rs:1830-1841`, refusals `revset_util.rs:277-331` @ v0.46.0).
fn resolve_single(planner: &mut Planner<'_>, base: &ReadonlyRepo, revision: &str) -> Result<Commit, MutateError> {
    let expression = planner.parse(revision)?;
    single_commit(base, &expression, revision, &planner.prefixes)
}

/// The single commit the parsed `expression` (the text `revision`) denotes against `base`, its
/// symbols resolved through `prefixes`, with `resolve_single_rev`'s refusals
/// (`revset_util.rs:277-331` @ v0.46.0) — shared with `bookmark advance`'s default target (Story
/// 9.19).
///
/// # Errors
///
/// - [`MutateError::RevsetResolutionError`] — a symbol does not resolve, or the set holds no
///   commit or more than one.
/// - [`MutateError::Backend`] — an evaluation or store read failed.
pub(crate) fn single_commit(
    base: &ReadonlyRepo,
    expression: &Arc<UserRevsetExpression>,
    revision: &str,
    prefixes: &IdPrefixContext,
) -> Result<Commit, MutateError> {
    let ids = collect_ids(base, expression, prefixes)?;
    match ids.as_slice() {
        [id] => base.store().get_commit(id).map_err(be),
        [] => Err(MutateError::RevsetResolutionError {
            reason: format!("Revset `{revision}` didn't resolve to any revisions"),
            hints: vec![],
        }),
        _ => Err(MutateError::RevsetResolutionError {
            reason: format!("Revset `{revision}` resolved to more than one revision"),
            hints: vec![],
        }),
    }
}

/// The CLI's `create_change_bookmarks` (`push.rs:1303-1356`) — each name rendered from
/// `templates.git_push_bookmark` ([`Templates::push_bookmark_names`], Story 9.51) — then the
/// `--named` bookmarks (`:401-414`) — all set in `tx`. Returns the created names in the CLI's
/// order: the `--change` ones, then the `--named` ones.
fn create_bookmarks(
    planner: &mut Planner<'_>,
    tx: &mut Transaction,
    created: &mut Vec<PushCreatedBookmark>,
) -> Result<Vec<RefNameBuf>, MutateError> {
    let base = Arc::clone(tx.base_repo());
    let mut names = Vec::new();
    if !planner.args.changes.is_empty() {
        let mut ids: Vec<JjCommitId> = Vec::new();
        for revision in &planner.args.changes {
            for id in planner.commit_ids(&base, revision)? {
                if !ids.contains(&id) {
                    ids.push(id);
                }
            }
        }
        if ids.is_empty() {
            return Err(MutateError::invalid("Empty revision set".to_owned()));
        }
        let commits: Vec<Commit> = ids
            .iter()
            .map(|id| base.store().get_commit(id).map_err(be))
            .collect::<Result<_, _>>()?;
        let templates = Templates::new(
            planner.config,
            planner.immutable,
            planner.template_startup,
            planner.repo.workspace(),
        );
        let change_names: Vec<RefNameBuf> = templates
            .push_bookmark_names(tx.repo(), &commits, planner.sink)?
            .into_iter()
            .map(RefNameBuf::from)
            .collect();
        for (commit, name) in commits.iter().zip(&change_names) {
            let target = RefTarget::normal(commit.id().clone());
            if tx.repo().view().get_local_bookmark(name) == &target {
                continue;
            }
            ensure_new_bookmark_name(tx.repo(), name)?;
            created.push(PushCreatedBookmark {
                name: name.as_str().to_owned(),
                change_id: commit.change_id().reverse_hex(),
            });
            tx.repo_mut().set_local_bookmark_target(name, target);
        }
        names.extend(change_names);
    }
    let mut named_commits = Vec::new();
    for argument in &planner.args.named {
        let (name, revision) = parse_named(argument)?;
        let commit = resolve_single(planner, &base, revision)?;
        named_commits.push((name, commit));
    }
    for (name, commit) in named_commits {
        ensure_new_bookmark_name(tx.repo(), &name)?;
        tx.repo_mut()
            .set_local_bookmark_target(&name, RefTarget::normal(commit.id().clone()));
        names.push(name);
    }
    Ok(names)
}

/// The names of `kind` matching `patterns` that the push considers on `remote` — the CLI's
/// `find_bookmarks_to_push` / `find_tags_to_push` (`push.rs:1358-1425`), with their warning for
/// exact names that match nothing.
fn find_refs_to_push<'v>(
    planner: &mut Planner<'_>,
    view: &'v View,
    kind: PushRefKind,
    patterns: &[String],
    remote: &RemoteName,
) -> Result<Vec<(&'v RefName, LocalAndRemoteRef<'v>)>, MutateError> {
    let expression = crate::bookmark_ops::union_expression(patterns)?;
    let matcher = expression.to_matcher();
    let candidates: Vec<(&RefName, LocalAndRemoteRef<'_>)> = match kind {
        PushRefKind::Bookmark => view.local_remote_bookmarks_matching(&matcher, remote).collect(),
        PushRefKind::Tag => view.local_remote_tags_matching(&matcher, remote).collect(),
    };
    let matching = candidates
        .into_iter()
        // An untracked remote ref with no local one is not a deleted ref (`push.rs:1368-1372`).
        .filter(|(_, targets)| targets.local_target.is_present() || targets.remote_ref.is_tracked())
        .collect();
    let unmatched: Vec<String> = expression
        .exact_strings()
        .map(RefName::new)
        .filter(|name| {
            let symbol = name.to_remote_symbol(remote);
            match kind {
                PushRefKind::Bookmark => {
                    view.get_local_bookmark(name).is_absent() && !view.get_remote_bookmark(symbol).is_tracked()
                }
                PushRefKind::Tag => view.get_local_tag(name).is_absent() && !view.get_remote_tag(symbol).is_tracked(),
            }
        })
        .map(|name| name.as_symbol().to_string())
        .collect();
    if !unmatched.is_empty() {
        let (warning, noun) = match kind {
            PushRefKind::Bookmark => (WarningKind::PushBookmarksUnmatched, "bookmarks"),
            PushRefKind::Tag => (WarningKind::PushTagsUnmatched, "tags"),
        };
        planner.warn(
            warning,
            format!("No matching {noun} for names: {}", unmatched.join(", ")),
        );
    }
    Ok(matching)
}

/// `bookmarks() | tags()` — what the CLI intersects the target revsets with.
fn refs_expression() -> Arc<UserRevsetExpression> {
    RevsetExpression::bookmarks(StringExpression::all()).union(&RevsetExpression::tags(StringExpression::all()))
}

/// The CLI's `find_default_target_revisions` (`push.rs:1427-1458`): `revsets.git-push` with
/// `remote` bound, its diagnostics "In revsets.git-push", intersected with the refs.
fn default_targets(
    planner: &mut Planner<'_>,
    base: &ReadonlyRepo,
    text: &str,
    remote: &RemoteName,
) -> Result<HashSet<JjCommitId>, MutateError> {
    let expression = crate::revset::parse_diagnosed_with(
        planner.repo.workspace(),
        &planner.parse_config,
        (text, "In revsets.git-push"),
        &[("remote", remote.as_str())],
        planner.sink,
    )
    .map_err(rev)?;
    let ids = collect_ids(base, &expression.intersection(&refs_expression()), &planner.prefixes)?;
    if ids.is_empty() {
        planner.warn(
            WarningKind::PushRevsetEmpty,
            format!(
                "No bookmarks/tags found in revsets.git-push: {text} (remote={})",
                remote.as_symbol()
            ),
        );
    }
    Ok(ids.into_iter().collect())
}

/// The CLI's `find_target_revisions` (`push.rs:1460-1485`): each `-r` revset intersected with
/// the refs, warning those that hold none.
fn revision_targets(planner: &mut Planner<'_>, base: &ReadonlyRepo) -> Result<HashSet<JjCommitId>, MutateError> {
    let mut ids = HashSet::new();
    for revision in &planner.args.revisions {
        let expression = planner.parse(revision)?;
        let found = collect_ids(base, &expression.intersection(&refs_expression()), &planner.prefixes)?;
        if found.is_empty() {
            planner.warn(
                WarningKind::PushRevisionsEmpty,
                format!("No bookmarks/tags point to the specified revisions: {revision}"),
            );
        }
        ids.extend(found);
    }
    Ok(ids)
}

/// One candidate of a mode that skips: classified with the mode's `params`, its commits checked,
/// a refusal or rejection warned and skipped (`push.rs:518-553`, `:670-709`).
fn classify_skipping(
    planner: &mut Planner<'_>,
    plan: &mut RemotePlan,
    validator: &mut CommitsValidator<'_, '_>,
    (kind, name, targets): (PushRefKind, &RefName, LocalAndRemoteRef<'_>),
    params: ClassifyParams,
) -> Result<(), MutateError> {
    let symbol = name.to_remote_symbol(&plan.remote);
    let explicit = explicit_refusal(validator.repo, kind, symbol, targets);
    let update_of = |targets| match classify_ref_push_action(targets) {
        RefPushAction::Update(update) => Some(update),
        _ => None,
    };
    match classify(kind, symbol, targets, params) {
        Ok(None) => {}
        Ok(Some(update)) => match validator.validate(update.after.as_slice())? {
            None => plan.push(kind, name, update, explicit),
            Some(rejected) => {
                let rejection = rejected.skipped(kind, name);
                planner.warn(WarningKind::PushCommitSkipped, rejection.message.clone());
                plan.rows.push(Row {
                    kind,
                    name: name.to_owned(),
                    update: Some(update),
                    path: PushPath::Skip,
                    refusal: None,
                    explicit_refusal: explicit,
                    rejection: Some(rejection),
                });
            }
        },
        Err(refusal) => {
            planner.warn(WarningKind::PushRefSkipped, refusal.message.clone());
            plan.rows.push(Row {
                kind,
                name: name.to_owned(),
                update: update_of(targets),
                path: PushPath::Skip,
                refusal: Some(refusal),
                explicit_refusal: explicit,
                rejection: None,
            });
        }
    }
    Ok(())
}

/// One explicitly named ref (`--change`/`--named`, `-b`, `-t`; `push.rs:438-503`): classified
/// with `params`; a refusal aborts (recorded as a row and the plan's failure in a dry run).
fn classify_explicit(
    planner: &mut Planner<'_>,
    plan: &mut RemotePlan,
    abort: &mut Option<PushFailure>,
    (kind, name, targets): (PushRefKind, &RefName, LocalAndRemoteRef<'_>),
    params: ClassifyParams,
) -> Result<(), MutateError> {
    let symbol = name.to_remote_symbol(&plan.remote);
    match classify(kind, symbol, targets, params) {
        Ok(Some(update)) => plan.push(kind, name, update, None),
        Ok(None) => plan.already_matches.push(PushRefName {
            kind,
            name: name.as_str().to_owned(),
        }),
        Err(refusal) => {
            if planner.stop_on_abort {
                return Err(MutateError::PushRefRefused {
                    message: refusal.message,
                    hints: refusal.hint.into_iter().collect(),
                });
            }
            abort.get_or_insert_with(|| PushFailure {
                kind: PushFailureKind::RefRefused,
                message: refusal.message.clone(),
                hint: refusal.hint.clone(),
            });
            let update = match classify_ref_push_action(targets) {
                RefPushAction::Update(update) => Some(update),
                _ => None,
            };
            plan.rows.push(Row {
                kind,
                name: name.to_owned(),
                update,
                path: PushPath::Abort,
                explicit_refusal: Some(refusal.clone()),
                refusal: Some(refusal),
                rejection: None,
            });
        }
    }
    Ok(())
}

/// The explicit refs' commit check (`push.rs:505-511`): the first rejected commit of all their
/// new heads refuses the push; a dry run instead marks each explicit row whose own new head
/// reaches a rejected commit, and keeps the rest.
fn validate_explicit(
    stop_on_abort: bool,
    plan: &mut RemotePlan,
    validator: &mut CommitsValidator<'_, '_>,
    abort: &mut Option<PushFailure>,
) -> Result<(), MutateError> {
    let new_heads: Vec<JjCommitId> = plan
        .updates
        .bookmarks
        .iter()
        .chain(&plan.updates.tags)
        .filter_map(|(_, update)| update.after.clone())
        .collect();
    let Some(rejected) = validator.validate(&new_heads)? else {
        return Ok(());
    };
    let rejection = rejected.aborted(validator.repo, &validator.templates)?;
    if stop_on_abort {
        return Err(MutateError::PushCommitRejected {
            message: rejection.message,
            hints: rejection.hints,
        });
    }
    abort.get_or_insert_with(|| PushFailure {
        kind: PushFailureKind::CommitRejected,
        message: rejection.message.clone(),
        hint: (!rejection.hints.is_empty()).then(|| rejection.hints.join("\n")),
    });
    // Each explicit row checked on its own, from the heads known before the explicit check.
    let known = validator.known_heads.clone();
    let mut passed = Vec::new();
    for row in plan.rows.iter_mut().filter(|row| row.path == PushPath::Push) {
        let Some(after) = row.update.as_ref().and_then(|update| update.after.clone()) else {
            continue;
        };
        validator.known_heads.clone_from(&known);
        match validator.validate(std::slice::from_ref(&after))? {
            Some(rejected) => {
                row.path = PushPath::Abort;
                row.rejection = Some(rejected.aborted(validator.repo, &validator.templates)?);
            }
            None => passed.push(after),
        }
    }
    validator.known_heads = known;
    validator.known_heads.extend(passed);
    plan.updates = GitPushRefTargets::default();
    for row in plan.rows.iter().filter(|row| row.path == PushPath::Push) {
        if let Some(update) = &row.update {
            let list = match row.kind {
                PushRefKind::Bookmark => &mut plan.updates.bookmarks,
                PushRefKind::Tag => &mut plan.updates.tags,
            };
            list.push((row.name.clone(), update.clone()));
        }
    }
    Ok(())
}

/// The planning phase (Story 9.20): remotes, the `--change` / `--named` bookmarks created in
/// `tx`, the mode's targets, the classification and the commit checks — nothing written.
///
/// # Errors
///
/// Every refusal before the network (see [`crate::Repo::git_push`]).
pub(crate) fn plan_push(
    repo: &Repo,
    ctx: &mut VerbContext,
    tx: &mut Transaction,
    args: &GitPushArgs,
) -> Result<PushPlan, MutateError> {
    let base = Arc::clone(tx.base_repo());
    let VerbContext {
        config,
        immutable,
        template_startup,
        warnings: sink,
        ..
    } = ctx;
    let mut hints = Vec::new();
    let remotes = resolve_remotes(&base, args, config, sink, &mut hints)?;
    let parse_config = crate::revset::revset_config(config, sink).map_err(cfg)?;
    // The reason is already the CLI's "Invalid `revset-aliases.immutable_heads()`: …" text;
    // `cfg` would prepend `config error: `.
    let immutable_heads = crate::revset::immutable_heads_expression(repo.workspace(), &parse_config, sink)
        .map_err(|crate::ConfigError::Load { reason }| MutateError::Config { reason })?;
    let mut planner = Planner {
        repo,
        args,
        config,
        parse_config,
        immutable,
        prefixes: template_startup.id_prefix_context(),
        template_startup,
        immutable_heads: &immutable_heads,
        sink,
        stop_on_abort: !args.dry_run,
    };
    let mut created = Vec::new();
    let mut abort = None;
    let bulk = if args.all {
        Some(ClassifyParams {
            allow_new: true,
            allow_delete: args.deleted,
        })
    } else if args.tracked || args.deleted {
        Some(ClassifyParams {
            allow_new: true,
            allow_delete: args.deleted || !args.tracked,
        })
    } else {
        None
    };
    let remotes = if let Some(params) = bulk {
        remotes
            .into_iter()
            .map(|remote| plan_bulk_remote(&mut planner, &base, remote, params))
            .collect::<Result<_, _>>()?
    } else {
        let created_names = create_bookmarks(&mut planner, tx, &mut created)?;
        let use_default = args.bookmarks.is_empty()
            && args.tags.is_empty()
            && args.changes.is_empty()
            && args.revisions.is_empty()
            && args.named.is_empty();
        let default_text = if use_default {
            Some(crate::config::revsets_git_push(planner.config).map_err(cfg)?)
        } else {
            None
        };
        let inputs = DefaultInputs {
            base: &base,
            mutated: tx.repo(),
            created_names: &created_names,
            default_text: default_text.as_deref(),
        };
        remotes
            .iter()
            .map(|remote| plan_default_remote(&mut planner, &inputs, remote, &mut abort))
            .collect::<Result<_, _>>()?
    };
    Ok(PushPlan {
        remotes,
        created,
        hints,
        abort,
    })
}

/// A new, empty plan for `remote`.
fn remote_plan(remote: RemoteNameBuf) -> RemotePlan {
    RemotePlan {
        remote,
        updates: GitPushRefTargets::default(),
        rows: Vec::new(),
        already_matches: Vec::new(),
    }
}

/// `--all` / `--tracked` / `--deleted` on one remote (`push.rs:327-396`): every candidate of the
/// mode's predicate, classified with `params`, refused ones skipped
/// (`classify_tags_and_bookmark_updates`, `:670-709`).
fn plan_bulk_remote(
    planner: &mut Planner<'_>,
    base: &ReadonlyRepo,
    remote: RemoteNameBuf,
    params: ClassifyParams,
) -> Result<RemotePlan, MutateError> {
    let mut validator = CommitsValidator::new(base, &remote, planner)?;
    let args = planner.args;
    let predicate = |targets: &LocalAndRemoteRef<'_>| {
        if args.all {
            true
        } else if args.tracked {
            targets.remote_ref.is_tracked()
        } else {
            targets.local_target.is_absent()
        }
    };
    let view = base.view();
    let candidates: Vec<(PushRefKind, &RefName, LocalAndRemoteRef<'_>)> = view
        .local_remote_bookmarks(&remote)
        .filter(|(_, targets)| predicate(targets))
        .map(|(name, targets)| (PushRefKind::Bookmark, name, targets))
        .chain(
            view.local_remote_tags(&remote)
                .filter(|(_, targets)| predicate(targets))
                .map(|(name, targets)| (PushRefKind::Tag, name, targets)),
        )
        .collect();
    let mut plan = remote_plan(remote);
    for candidate in candidates {
        classify_skipping(planner, &mut plan, &mut validator, candidate, params)?;
    }
    Ok(plan)
}

/// What the default mode's per-remote planning reads.
struct DefaultInputs<'a> {
    /// The operation the push started from — the targets' and the commit checks' view.
    base: &'a ReadonlyRepo,
    /// The transaction's view, with the `--change` / `--named` bookmarks created.
    mutated: &'a jj_lib::repo::MutableRepo,
    /// The created names, `--change` first.
    created_names: &'a [RefNameBuf],
    /// `revsets.git-push` when no specific ref was named.
    default_text: Option<&'a str>,
}

/// The default mode on one remote (`push.rs:423-555`): the created bookmarks, `-b`, `-t` (all
/// explicit), their commit check, then the bare push's or `-r`'s targets, refused ones skipped.
fn plan_default_remote(
    planner: &mut Planner<'_>,
    inputs: &DefaultInputs<'_>,
    remote: &RemoteName,
    abort: &mut Option<PushFailure>,
) -> Result<RemotePlan, MutateError> {
    let mut plan = remote_plan(remote.to_owned());
    let mut seen_bookmarks: HashSet<RefNameBuf> = HashSet::new();
    let mut seen_tags: HashSet<RefNameBuf> = HashSet::new();
    let view = inputs.mutated.view();
    for name in inputs.created_names {
        if !seen_bookmarks.insert(name.clone()) {
            continue;
        }
        let targets = LocalAndRemoteRef {
            local_target: view.get_local_bookmark(name),
            remote_ref: view.get_remote_bookmark(name.to_remote_symbol(remote)),
        };
        let params = ClassifyParams {
            allow_new: true,
            allow_delete: false,
        };
        classify_explicit(
            planner,
            &mut plan,
            abort,
            (PushRefKind::Bookmark, name, targets),
            params,
        )?;
    }
    for kind in [PushRefKind::Bookmark, PushRefKind::Tag] {
        let patterns = match kind {
            PushRefKind::Bookmark => &planner.args.bookmarks,
            PushRefKind::Tag => &planner.args.tags,
        };
        for (name, targets) in find_refs_to_push(planner, view, kind, patterns, remote)? {
            let seen = match kind {
                PushRefKind::Bookmark => &mut seen_bookmarks,
                PushRefKind::Tag => &mut seen_tags,
            };
            if !seen.insert(name.to_owned()) {
                continue;
            }
            let params = ClassifyParams {
                allow_new: !has_tracked_remote(inputs.mutated, kind, name),
                allow_delete: true,
            };
            classify_explicit(planner, &mut plan, abort, (kind, name, targets), params)?;
        }
    }
    let mut validator = CommitsValidator::new(inputs.base, remote, planner)?;
    validate_explicit(planner.stop_on_abort, &mut plan, &mut validator, abort)?;

    let targets = match inputs.default_text {
        Some(text) => default_targets(planner, inputs.base, text, remote)?,
        None => revision_targets(planner, inputs.base)?,
    };
    let params = ClassifyParams {
        allow_new: false,
        allow_delete: false,
    };
    let base_view = inputs.base.view();
    let implicit: Vec<(PushRefKind, &RefName, LocalAndRemoteRef<'_>)> = base_view
        .local_remote_bookmarks(remote)
        .map(|(name, targets)| (PushRefKind::Bookmark, name, targets))
        .chain(
            base_view
                .local_remote_tags(remote)
                .map(|(name, targets)| (PushRefKind::Tag, name, targets)),
        )
        .collect();
    for (kind, name, refs) in implicit {
        let matches = refs.local_target.present_adds().any(|id| targets.contains(id));
        let seen = match kind {
            PushRefKind::Bookmark => &mut seen_bookmarks,
            PushRefKind::Tag => &mut seen_tags,
        };
        if !matches || !seen.insert(name.to_owned()) {
            continue;
        }
        classify_skipping(planner, &mut plan, &mut validator, (kind, name, refs), params)?;
    }
    Ok(plan)
}

// ── The push ─────────────────────────────────────────────────────────────────────

/// The CLI's `ready_to_push_revset_expression` (`push.rs:893-910`): `old heads..new heads` of a
/// remote.
fn ready_to_push(base: &ReadonlyRepo, plan: &RemotePlan) -> Arc<UserRevsetExpression> {
    let new_heads: Vec<JjCommitId> = plan
        .updates
        .bookmarks
        .iter()
        .chain(&plan.updates.tags)
        .filter_map(|(_, update)| update.after.clone())
        .collect();
    let old_heads: Vec<JjCommitId> = base
        .view()
        .remote_bookmarks(&plan.remote)
        .flat_map(|(_, old_head)| old_head.target.present_adds())
        .cloned()
        .collect();
    RevsetExpression::commits(old_heads).range(&RevsetExpression::commits(new_heads))
}

/// The CLI's `sign_commits_before_push` (`push.rs:912-1038`): the commits to push that need a
/// signature signed (`SignBehavior::Own`) and their descendants rebased, in `tx`; immutable ones
/// skipped with a warning (each listed through `templates.commit_summary` over the base repo);
/// every remote's new targets remapped. The sets resolve through `prefixes`, as the CLI's
/// `attach_revset_evaluator` (`push.rs:934`, `:959`).
fn sign_before_push(
    tx: &mut Transaction,
    (templates, prefixes): (&Templates<'_>, &IdPrefixContext),
    plans: &mut [RemotePlan],
    sink: &mut Warnings,
) -> Result<Option<PushSigning>, MutateError> {
    let base = Arc::clone(tx.base_repo());
    let to_push = RevsetExpression::union_all(&plans.iter().map(|plan| ready_to_push(&base, plan)).collect::<Vec<_>>());
    let mut sign_settings = base.settings().sign_settings();
    sign_settings.behavior = SignBehavior::Own;
    let needs_signing = |commit: &Commit| !commit.is_signed() && sign_settings.should_sign(commit.store_commit());
    let commits_of = |expression: &Arc<UserRevsetExpression>| -> Result<Vec<Commit>, MutateError> {
        collect_ids(base.as_ref(), expression, prefixes)?
            .iter()
            .map(|id| base.store().get_commit(id).map_err(be))
            .collect()
    };

    let immutable = templates.immutable();
    let skipped: Vec<String> = commits_of(&to_push.intersection(immutable))?
        .into_iter()
        .filter(|commit| needs_signing(commit))
        .take(11)
        .map(|commit| templates.commit_summary(base.as_ref(), &commit))
        .collect::<Result<_, _>>()?;
    if !skipped.is_empty() {
        sink.push(
            WarningKind::PushSigningSkippedImmutable,
            skipped_signing_message(&skipped),
        );
    }
    let mut to_sign: Vec<JjCommitId> = Vec::new();
    for commit in commits_of(&to_push.minus(immutable))? {
        if needs_signing(&commit) && !to_sign.contains(commit.id()) {
            to_sign.push(commit.id().clone());
        }
    }
    if to_sign.is_empty() {
        return Ok(None);
    }

    let mut rewritten: HashMap<JjCommitId, JjCommitId> = HashMap::new();
    let mut rebased_descendants = 0;
    let behavior = sign_settings.behavior;
    pollster::block_on(tx.repo_mut().transform_descendants(
        to_sign.clone(),
        async |rewriter: jj_lib::rewrite::CommitRewriter<'_>| {
            let old_id = rewriter.old_commit().id().clone();
            let commit = if to_sign.contains(&old_id) {
                rewriter.reparent().set_sign_behavior(behavior).write().await?
            } else {
                rebased_descendants += 1;
                rewriter.reparent().write().await?
            };
            rewritten.insert(old_id, commit.id().clone());
            Ok(())
        },
    ))
    .map_err(be)?;

    for plan in plans.iter_mut() {
        let remap = |updates: &mut Vec<(RefNameBuf, Diff<Option<JjCommitId>>)>| {
            for (_, update) in updates.iter_mut() {
                if let Some(new) = update.after.as_ref().and_then(|id| rewritten.get(id)) {
                    update.after = Some(new.clone());
                }
            }
        };
        remap(&mut plan.updates.bookmarks);
        remap(&mut plan.updates.tags);
        for row in &mut plan.rows {
            if let Some(update) = row.update.as_mut().filter(|_| row.path == PushPath::Push) {
                if let Some(new) = update.after.as_ref().and_then(|id| rewritten.get(id)) {
                    update.after = Some(new.clone());
                }
            }
        }
    }
    Ok(Some(PushSigning {
        updated_signatures: to_sign.len(),
        rebased_descendants,
    }))
}

/// The "Skipped signing N immutable commits:" warning with the commit list the CLI prints after
/// it (`push.rs:940-956` @ v0.46.0, `print_updated_commits` `cli_util.rs:3111-3125`): at most 10
/// summaries, each indented by two spaces, then "  ..." when there are more. `summaries` holds
/// up to 11 (the CLI's `take(11)`).
fn skipped_signing_message(summaries: &[String]) -> String {
    let count = if summaries.len() > 10 {
        "10+".to_owned()
    } else {
        summaries.len().to_string()
    };
    let mut lines = vec![format!("Skipped signing {count} immutable commits:")];
    lines.extend(summaries.iter().take(10).map(|summary| format!("  {summary}")));
    if summaries.len() > 10 {
        lines.push("  ...".to_owned());
    }
    lines.join("\n")
}

/// A ref's status after the push, from the push's stats.
fn status_of(row: &Row, remote: &RemoteName, stats: &GitPushStats) -> (Option<PushRefStatus>, Option<String>) {
    let qualified = match row.kind {
        PushRefKind::Bookmark => format!("refs/heads/{}", row.name.as_str()),
        PushRefKind::Tag => format!("refs/tags/{}", row.name.as_str()),
    };
    let find = |list: &[(jj_lib::ref_name::GitRefNameBuf, Option<String>)]| {
        list.iter()
            .find(|(name, _)| name.as_str() == qualified)
            .map(|(_, reason)| reason.clone())
    };
    if let Some(reason) = find(&stats.rejected) {
        return (Some(PushRefStatus::LeaseRejected), reason);
    }
    if let Some(reason) = find(&stats.remote_rejected) {
        return (Some(PushRefStatus::RemoteRejected), reason);
    }
    if !stats.pushed.iter().any(|name| name.as_str() == qualified) {
        return (None, None);
    }
    let unexported = stats
        .unexported_bookmarks
        .iter()
        .filter(|_| row.kind == PushRefKind::Bookmark)
        .find(|(symbol, _)| symbol.name == row.name && symbol.remote.as_str() == remote.as_str());
    match unexported {
        Some((_, reason)) => (
            Some(PushRefStatus::Unexported),
            Some(crate::warning::error_chain_lines(reason).join(": ")),
        ),
        None => (Some(PushRefStatus::Pushed), None),
    }
}

/// The push-stats hints (`git_util.rs:520-546`).
fn stats_hints(stats: &GitPushStats, hints: &mut Vec<String>) {
    if !stats.rejected.is_empty() {
        hints.push(
            "Try fetching from the remote, then make the bookmark point to where you want it to be, and push again."
                .to_owned(),
        );
    }
    if !stats.remote_rejected.is_empty() {
        hints.push("Try checking if you have permission to push to all the bookmarks.".to_owned());
    }
}

/// The CLI's text for a `GitPushError` (`command_error.rs:614-625` @ v0.46.0): the error and,
/// for an unusable remote name, the rename hint.
fn push_error(e: &GitPushError) -> PushFailure {
    let hint = matches!(e, GitPushError::RemoteName(_)).then(|| crate::remotes::REMOTE_RENAME_HINT.to_owned());
    PushFailure {
        kind: PushFailureKind::PushError,
        message: crate::mutate::flatten_chain(e),
        hint,
    }
}

/// A row rendered for the outcome; `action` in jj's words against `repo`'s index.
fn render_row(repo: &dyn jj_lib::repo::Repo, row: Row) -> Result<PushRef, MutateError> {
    let (before, after) = row
        .update
        .as_ref()
        .map_or((None, None), |update| (update.before.clone(), update.after.clone()));
    let action = match (&before, &after) {
        (Some(old), Some(new)) => {
            let forward = pollster::block_on(repo.index().is_ancestor(old, new)).map_err(be)?;
            let backward = !forward && pollster::block_on(repo.index().is_ancestor(new, old)).map_err(be)?;
            let direction = if forward {
                "forward"
            } else if backward {
                "backward"
            } else {
                "sideways"
            };
            Some(format!(
                "move {direction} from {} to {}",
                short_hash(old),
                short_hash(new)
            ))
        }
        (Some(old), None) => Some(format!("delete from {}", short_hash(old))),
        (None, Some(new)) => Some(format!("add to {}", short_hash(new))),
        (None, None) => None,
    };
    Ok(PushRef {
        kind: row.kind,
        name: row.name.as_str().to_owned(),
        before: before.as_ref().map(JjCommitId::hex),
        after: after.as_ref().map(JjCommitId::hex),
        action,
        path: row.path,
        refusal: row.refusal,
        explicit_refusal: row.explicit_refusal,
        rejection: row.rejection,
        status: None,
        status_reason: None,
    })
}

/// The remotes of `plans` rendered against `repo`, with the per-remote facts.
fn render(
    repo: &dyn jj_lib::repo::Repo,
    plans: Vec<RemotePlan>,
    results: &HashMap<RemoteNameBuf, Result<GitPushStats, String>>,
) -> Result<Vec<PushRemote>, MutateError> {
    plans
        .into_iter()
        .map(|plan| {
            let result = results.get(&plan.remote);
            let mut refs = Vec::with_capacity(plan.rows.len());
            for row in plan.rows {
                let (status, reason) = match (result, row.path) {
                    (Some(Ok(stats)), PushPath::Push) => status_of(&row, &plan.remote, stats),
                    _ => (None, None),
                };
                let mut rendered = render_row(repo, row)?;
                rendered.status = status;
                rendered.status_reason = reason;
                refs.push(rendered);
            }
            Ok(PushRemote {
                name: plan.remote.as_str().to_owned(),
                refs,
                already_matches: plan.already_matches,
                finished: matches!(result, Some(Ok(_))),
                error: match result {
                    Some(Err(message)) => Some(message.clone()),
                    _ => None,
                },
            })
        })
        .collect()
}

/// `jj git push` (Story 9.20): see [`crate::Repo::git_push`].
///
/// # Errors
///
/// See [`crate::Repo::git_push`].
pub(crate) fn git_push(
    repo: &mut Repo,
    ctx: &mut VerbContext,
    args: &GitPushArgs,
    progress: &crate::ProgressFn,
    cancel: Option<&crate::cancel::CancelGuard>,
) -> Result<GitPushOutcome, MutateError> {
    let readonly = crate::snapshot::reload_head(repo.workspace()).map_err(be)?;
    let base_op = readonly.op_id().hex();
    let mut tx = crate::op_support::start_repo_transaction(&readonly, repo.workspace().workspace_name());
    let mut plan = plan_push(repo, ctx, &mut tx, args)?;
    let mut outcome = GitPushOutcome {
        remotes: Vec::new(),
        created_bookmarks: std::mem::take(&mut plan.created),
        hints: std::mem::take(&mut plan.hints),
        signing: None,
        nothing_changed: false,
        dry_run: args.dry_run,
        recorded: false,
        description: None,
        new_op_id: base_op,
        failure: None,
    };
    if plan.abort.is_none() && plan.nothing_changed() {
        // "Nothing changed.": the transaction — and with it any `--change` bookmark — is dropped.
        outcome.remotes = render(tx.repo(), plan.remotes, &HashMap::new())?;
        outcome.created_bookmarks.clear();
        outcome.nothing_changed = true;
        return Ok(outcome);
    }
    let description = plan.description(args);
    // A dry run whose every explicit ref aborts has no update to describe.
    outcome.description = (!plan.nothing_changed()).then(|| description.clone());
    if args.dry_run {
        outcome.failure = plan.abort.take();
        outcome.remotes = render(tx.repo(), plan.remotes, &HashMap::new())?;
        return Ok(outcome);
    }

    if crate::config::git_sign_on_push(&ctx.config).map_err(cfg)? {
        let templates = Templates::new(&ctx.config, &ctx.immutable, &ctx.template_startup, repo.workspace());
        let prefixes = ctx.template_startup.id_prefix_context();
        outcome.signing = sign_before_push(&mut tx, (&templates, &prefixes), &mut plan.remotes, &mut ctx.warnings)?;
    }
    let pushed = push_remotes(&mut tx, &readonly, &plan.remotes, (args, progress, cancel), ctx)?;
    outcome.hints.extend(pushed.hints);
    outcome.failure = pushed.failure.or_else(|| (!pushed.all_ok).then(some_refs_failed));
    // Refs are on the remotes now: a later error is data, not an `Err` (Story 9.20).
    let mut late_error = None;
    match render(tx.repo(), plan.remotes, &pushed.results) {
        Ok(remotes) => outcome.remotes = remotes,
        Err(e) => late_error = Some(e),
    }
    if pushed.recordable {
        match record_push(repo, ctx, tx, &description) {
            Ok((op_id, committed)) => {
                outcome.recorded = committed;
                outcome.new_op_id = op_id;
            }
            Err(e) => late_error = late_error.or(Some(e)),
        }
    }
    if let Some(e) = late_error {
        outcome.failure = Some(PushFailure {
            kind: PushFailureKind::PushError,
            message: crate::mutate::flatten_chain(&e),
            hint: None,
        });
    }
    Ok(outcome)
}

/// The record step (`push.rs:622-655`): the push's operation written with `description` — the
/// shared finish rebases the descendants, as the CLI's `tx.finish`. Returns the head op id after
/// the step and whether an operation was written — `false` when the transaction changed nothing
/// (the finish's "Nothing changed." gate, Story 9.40), the id then being the pre-call head.
fn record_push(
    repo: &mut Repo,
    ctx: &mut VerbContext,
    tx: Transaction,
    description: &str,
) -> Result<(String, bool), MutateError> {
    let finish = crate::mutate::finish_verb(repo.workspace_mut(), tx, description, ctx)?;
    Ok((finish.repo.op_id().hex(), finish.committed))
}

/// What the push loop leaves behind.
struct Pushed {
    /// Per remote reached: its stats, or the error that stopped the loop there.
    results: HashMap<RemoteNameBuf, Result<GitPushStats, String>>,
    /// The push-stats hints.
    hints: Vec<String>,
    /// Every ref of every remote succeeded.
    all_ok: bool,
    /// The CLI's record rule (`push.rs:624`): no hard error, and every ref succeeded or at least
    /// one was exported.
    recordable: bool,
    /// The hard error that stopped the loop.
    failure: Option<PushFailure>,
}

/// The push loop (`push.rs:581-615`): remote by remote, `git::push_refs` in `tx`; the stats
/// warned and collected, the first hard error stops the loop.
fn push_remotes(
    tx: &mut Transaction,
    readonly: &ReadonlyRepo,
    plans: &[RemotePlan],
    (args, progress, cancel): (&GitPushArgs, &crate::ProgressFn, Option<&crate::cancel::CancelGuard>),
    ctx: &mut VerbContext,
) -> Result<Pushed, MutateError> {
    let subprocess_options = crate::environment::git_subprocess_options(readonly.settings(), cancel)
        .map_err(|e| cfg(crate::config::value_error(&e)))?;
    let options = GitPushOptions {
        remote_push_options: args.options.clone(),
    };
    let mut pushed = Pushed {
        results: HashMap::new(),
        hints: Vec::new(),
        all_ok: true,
        recordable: false,
        failure: None,
    };
    let mut some_exported = false;
    crate::cancel::watch_store(cancel, tx.repo().store());
    for plan in plans {
        // Story 9.52's checkpoint: before each remote's git push — none after the last one.
        if crate::cancel::checkpoint(cancel).is_err() {
            pushed.failure = Some(cancelled());
            return Ok(pushed);
        }
        let mut callback = crate::remotes::ProgressCallback {
            operation: "push",
            progress,
        };
        match jj_lib::git::push_refs(
            tx.repo_mut(),
            subprocess_options.clone(),
            &plan.remote,
            &plan.updates,
            &mut callback,
            &options,
        ) {
            Ok(stats) => {
                ctx.warnings.extend(crate::warning::push_stats(&stats));
                stats_hints(&stats, &mut pushed.hints);
                pushed.all_ok &= stats.all_ok();
                some_exported |= stats.some_exported();
                pushed.results.insert(plan.remote.clone(), Ok(stats));
            }
            Err(e) => {
                let failure = push_error(&e);
                pushed.results.insert(plan.remote.clone(), Err(failure.message.clone()));
                // A git push that failed after the cancel killed it is the cancel; every other
                // error passes through unchanged.
                pushed.failure = Some(
                    if matches!(e, GitPushError::Subprocess(_)) && crate::cancel::is_cancelled(cancel) {
                        cancelled()
                    } else {
                        failure
                    },
                );
                return Ok(pushed);
            }
        }
    }
    pushed.recordable = pushed.all_ok || some_exported;
    Ok(pushed)
}

/// The push stopped by its cancel token (Story 9.52).
fn cancelled() -> PushFailure {
    PushFailure {
        kind: PushFailureKind::Cancelled,
        message: "Cancelled".to_owned(),
        hint: None,
    }
}

/// The CLI's "Failed to push some bookmarks" (`push.rs:657-661`).
fn some_refs_failed() -> PushFailure {
    PushFailure {
        kind: PushFailureKind::SomeRefsFailed,
        message: "Failed to push some bookmarks".to_owned(),
        hint: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skipped_signing_lists_the_commits_like_the_cli() {
        let summaries: Vec<String> = (0..3).map(|i| format!("c{i}")).collect();
        assert_eq!(
            skipped_signing_message(&summaries),
            "Skipped signing 3 immutable commits:\n  c0\n  c1\n  c2"
        );
    }

    #[test]
    fn skipped_signing_caps_the_list_at_ten() {
        let summaries: Vec<String> = (0..11).map(|i| format!("c{i}")).collect();
        let message = skipped_signing_message(&summaries);
        let lines: Vec<&str> = message.lines().collect();
        assert_eq!(lines[0], "Skipped signing 10+ immutable commits:");
        assert_eq!(lines.len(), 12, "the heading, ten summaries and the overflow line");
        assert_eq!(lines[10], "  c9");
        assert_eq!(lines[11], "  ...");
    }
}
