// SPDX-License-Identifier: MIT

use std::path::PathBuf;

use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;

use crate::ChangeId;

/// Git-backend commit hash (changes on rebase, unlike [`ChangeId`]).
///
/// `commit_id.0` holds the hex string (e.g. `"1a2b3c…"`). This is the Git-SHA
/// that changes every time the commit is rebased; by contrast, [`ChangeId`]
/// (`id.0`) is the stable reverse-hex identifier that follows the commit through
/// rewrites.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitId(pub String);

/// Who authored or committed a change, and when.
///
/// jj allows empty `name` and `email` strings — do not assume they are non-empty.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Signature {
    /// Author or committer name (may be empty).
    pub name: String,
    /// Author or committer email address (may be empty).
    pub email: String,
    /// Timestamp of this signature.
    pub timestamp: Timestamp,
}

/// A raw jj timestamp: milliseconds since the Unix epoch plus a timezone offset
/// in minutes east of UTC (jj-lib's `tz_offset` convention).
///
/// Stored raw (Decision D2) — infallible, FlatBuffers-friendly, no `chrono`
/// coupling in the public API.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Timestamp {
    /// Milliseconds since the Unix epoch (UTC).
    pub millis_since_epoch: i64,
    /// Timezone offset in minutes east of UTC (jj-lib `tz_offset` convention).
    pub tz_offset_minutes: i32,
}

/// Authored/committed timestamp pair.
///
/// `authored_at` mirrors `author.timestamp`; `committed_at` mirrors
/// `committer.timestamp`. The overlap with the nested `Signature` timestamps
/// is intentional — FR-JJ-6 lists both the `Signature` fields and the
/// `Timestamps` struct as exhaustive requirements.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Timestamps {
    /// When the change was first authored.
    pub authored_at: Timestamp,
    /// When the change was last committed (rebases update this).
    pub committed_at: Timestamp,
}

/// Whether a change is conflict-free.
///
/// `Conflicted { paths }` lists the conflicted file paths (consumed by Epic 6's
/// conflict-resolution flow).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConflictState {
    /// No conflicts — the working tree is clean.
    Clean,
    /// One or more files have unresolved conflicts.
    Conflicted {
        /// Repository-relative paths of the conflicted files.
        paths: Vec<PathBuf>,
    },
}

/// Full metadata for one change (FR-JJ-6).
///
/// `id` is stable across rebases (`ChangeId` — reverse-hex form); `commit_id`
/// is the Git-backend SHA that changes on every rebase (`CommitId`).
#[derive(Debug)]
pub struct Change {
    /// Stable jj change identifier in reverse-hex form (e.g. `"qpvuntsm…"`).
    pub id: ChangeId,
    /// Git-backend commit hash in hex form (changes on rebase).
    pub commit_id: CommitId,
    /// Parent change ids in jj order; empty for the root change.
    pub parents: Vec<ChangeId>,
    /// Commit description; always present but may be empty (jj convention).
    pub description: String,
    /// Who authored this change (name, email, timestamp).
    pub author: Signature,
    /// Who last committed this change (may differ from `author` after a rebase).
    pub committer: Signature,
    /// Canonical authored/committed timestamp pair (mirrors `author.timestamp`
    /// and `committer.timestamp` respectively).
    pub timestamps: Timestamps,
    /// `true` if a cryptographic (GPG/SSH) signature is present (presence-only —
    /// Decision D3; validation via `Commit::verification()` is never performed).
    pub is_signed: bool,
    /// Whether the change tree has unresolved conflicts.
    pub conflict: ConflictState,
    /// `true` when the description is empty **and** no local bookmark targets this
    /// commit (Decision D5 — local bookmarks only).
    pub is_anonymous: bool,
    /// `true` when this change id resolves to more than one visible commit
    /// (divergent change, Decision D4). `get_change` returns the index-first
    /// visible target (jj-lib *prefers* newer-first but does not guarantee the
    /// order) and sets this flag so the UI can decide.
    pub divergent: bool,
}

/// Errors returned by [`crate::Repo::get_change`].
#[derive(Debug, thiserror::Error)]
pub enum ChangeError {
    /// The pre-verb snapshot failed (Story 9.26), so the read never ran — see
    /// [`crate::PreconditionError`].
    #[error(transparent)]
    Precondition(#[from] crate::PreconditionError),
    /// No change exists for the given id — either the id is empty or malformed
    /// (not valid reverse-hex), absent from the index, or only points to
    /// hidden/abandoned commits. These cases are indistinguishable to callers
    /// (Decision D6); `id` is the reverse-hex string that was passed in.
    #[error("change not found: {id}")]
    NotFound {
        /// The reverse-hex change id that could not be resolved.
        id: String,
    },
    /// The id does not resolve the way the CLI's `ChangePrefixResolver` refuses it: an
    /// AMBIGUOUS change-id prefix, or a `revsets.short-prefixes` set that fails to load.
    /// `reason` is jj-lib's own `RevsetResolutionError` text. (A DIVERGENT change is no error
    /// here — Decision D4, [`Change::divergent`].)
    #[error("revset resolution error: {reason}")]
    RevsetResolutionError {
        /// jj-lib's resolution error text.
        reason: String,
        /// The CLI's hints for it; empty for both cases.
        hints: Vec<String>,
    },
    /// An underlying jj-lib failure (index, backend, or loader error),
    /// opaque-string-wrapped so no `jj_lib` type escapes the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Flattens any jj-lib error to its opaque reason string — the single failure mode of
/// [`change_from_commit`], which each caller wraps in its own error type.
fn reason<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

/// Converts any jj-lib error to [`ChangeError::Backend`].
fn be<E: std::fmt::Display>(e: E) -> ChangeError {
    ChangeError::Backend(reason(e))
}

/// Converts a jj-lib `Signature` to our crate's [`Signature`].
fn to_signature(sig: &jj_lib::backend::Signature) -> Signature {
    Signature {
        name: sig.name.clone(),
        email: sig.email.clone(),
        timestamp: Timestamp {
            millis_since_epoch: sig.timestamp.timestamp.0,
            tz_offset_minutes: sig.timestamp.tz_offset,
        },
    }
}

/// Returns full metadata for the change identified by the change-id prefix `id` (reverse-hex
/// form), resolved through `prefixes` — the call's `revsets.short-prefixes` context — by the
/// change-id currency every verb shares ([`crate::op_support::resolve_change`]).
///
/// Re-resolves to head on every call (ADR-0002). Read-only. A DIVERGENT change is no refusal
/// here (D4: this is no CLI `-r`): the index-first visible target is returned, flagged
/// [`Change::divergent`].
///
/// # Errors
///
/// - [`ChangeError::NotFound`] — `id` is malformed, absent, or only-hidden (D6).
/// - [`ChangeError::RevsetResolutionError`] — an ambiguous prefix, or a failed
///   `revsets.short-prefixes` load.
/// - [`ChangeError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn get_change(
    workspace: &Workspace,
    prefixes: &jj_lib::id_prefix::IdPrefixContext,
    id: &ChangeId,
) -> Result<Change, ChangeError> {
    // 1. Reload to head (ADR-0002; sync via pollster — mirrors status.rs:85).
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let repo_dyn: &dyn jj_lib::repo::Repo = readonly.as_ref();

    // 2. Resolve → visible commit(s), divergence-aware (D4): the index-first visible target
    //    (jj prefers newer-first; not guaranteed).
    let visible = crate::op_support::resolve_change(repo_dyn, prefixes, id).map_err(|e| res(e, id))?;
    // `resolve_change` returns at least one visible target.
    let (_, commit_id) = &visible[0];

    // 3. Load the chosen commit (sync; mirrors status.rs:92).
    let commit = readonly.store().get_commit(commit_id).map_err(be)?;

    // 4-8. Shared with `eval_revset` — one construction site for `Change`.
    change_from_commit(repo_dyn, &commit).map_err(ChangeError::Backend)
}

/// Converts a shared [`crate::op_support::ResolveError`] for `id` to this module's taxonomy: an
/// id that does not resolve is `NotFound` with the id echoed, a resolution refusal keeps its
/// reason and hints, an index failure is `Backend`. `NoWorkingCopy` is never raised for an
/// id-carrying resolve and folds into `NotFound` like any other miss.
fn res(e: crate::op_support::ResolveError, id: &ChangeId) -> ChangeError {
    use crate::op_support::ResolveError;
    match e {
        ResolveError::NotFound | ResolveError::NoWorkingCopy(_) => ChangeError::NotFound { id: id.0.clone() },
        ResolveError::Resolution { reason, hints } => ChangeError::RevsetResolutionError { reason, hints },
        ResolveError::Backend(reason) => ChangeError::Backend(reason),
    }
}

/// Builds the crate-owned [`Change`] for an already-loaded jj-lib `commit`.
///
/// The single construction site for [`Change`]: [`get_change`] reaches it after resolving a
/// change id, [`crate::revset::eval_revset`] after pulling a commit off a revset stream. Every
/// jj-lib failure (a parent read, the divergence probe) is flattened to its opaque reason
/// string, which each caller wraps in its own error type.
///
/// `divergent` is re-derived here from `commit`'s own change id rather than passed in, so that a
/// caller holding only a commit — the stream — reaches the same D4 answer as [`get_change`]
/// without duplicating the rule. The cost is that [`get_change`], which already resolved the id
/// to find this commit, pays a SECOND `resolve_change_id`. That probe is index-only (no store
/// read), and one construction site for [`Change`] is worth it; the alternative — passing
/// `divergent` in — would put the D4 rule back at every call site.
///
/// `store` and `view` are taken from `repo_dyn` rather than as parameters, so they cannot come
/// from a different head resolution than the repo the divergence probe runs against.
///
/// # Errors
///
/// Returns the jj-lib reason string when a parent commit read or the change-id resolution
/// fails.
pub(crate) fn change_from_commit(
    repo_dyn: &dyn jj_lib::repo::Repo,
    commit: &jj_lib::commit::Commit,
) -> Result<Change, String> {
    let store = repo_dyn.store();
    let view = repo_dyn.view();

    // 4. Parents: CommitIds → reverse-hex ChangeIds (mirrors status.rs:105-107).
    let mut parents = Vec::with_capacity(commit.parent_ids().len());
    for pid in commit.parent_ids() {
        let parent = store.get_commit(pid).map_err(reason)?;
        parents.push(ChangeId(parent.change_id().reverse_hex()));
    }

    // 5. Signatures + timestamps (raw — D2). Timestamp is Copy so author.timestamp
    //    copies into `timestamps` while `author` continues to exist.
    let author = to_signature(commit.author());
    let committer = to_signature(commit.committer());
    let timestamps = Timestamps {
        authored_at: author.timestamp,
        committed_at: committer.timestamp,
    };

    // 6. Conflict state (D7): path-list only; per-path value errors are dropped.
    let conflict = if commit.has_conflict() {
        let paths = commit
            .tree()
            .conflicts()
            .map(|(p, _value)| PathBuf::from(p.as_internal_file_string()))
            .collect();
        ConflictState::Conflicted { paths }
    } else {
        ConflictState::Clean
    };

    // 7. Anonymity (D5): empty description AND no local bookmark targets this commit.
    let is_anonymous = commit.description().is_empty() && view.local_bookmarks_for_commit(commit.id()).next().is_none();

    // 8. Divergence (D4): more than one VISIBLE commit carries this change id. A complete
    //    change id is unambiguous, so `resolve_change_id` cannot hit its ambiguity panic.
    let divergent = pollster::block_on(repo_dyn.resolve_change_id(commit.change_id()))
        .map_err(reason)?
        .as_ref()
        .is_some_and(jj_lib::index::ResolvedChangeTargets::is_divergent);

    Ok(Change {
        id: ChangeId(commit.change_id().reverse_hex()),
        commit_id: CommitId(commit.id().hex()),
        parents,
        description: commit.description().to_owned(),
        author,
        committer,
        timestamps,
        is_signed: commit.is_signed(), // presence-only (D3) — NOT verification()
        conflict,
        is_anonymous,
        divergent,
    })
}

#[cfg(test)]
mod tests {
    use super::{get_change, res, ChangeError, ChangeId};
    use crate::op_support::ResolveError;

    /// Every shared resolver outcome lands on its own variant with its fields — pinned directly,
    /// because `Backend` needs an index read failure the public API cannot provoke.
    #[test]
    fn res_maps_every_resolve_error() {
        let id = ChangeId("zk".to_owned());
        assert!(matches!(
            res(ResolveError::NotFound, &id),
            ChangeError::NotFound { id: echoed } if echoed == "zk"
        ));
        assert!(matches!(
            res(ResolveError::NoWorkingCopy("no @".to_owned()), &id),
            ChangeError::NotFound { id: echoed } if echoed == "zk"
        ));
        let e = ResolveError::Resolution {
            reason: "Change ID `zk` is divergent".to_owned(),
            hints: vec!["h".to_owned()],
        };
        assert!(matches!(
            res(e, &id),
            ChangeError::RevsetResolutionError { reason, hints } if reason == "Change ID `zk` is divergent" && hints == ["h"]
        ));
        assert!(matches!(
            res(ResolveError::Backend("index read failed".to_owned()), &id),
            ChangeError::Backend(reason) if reason == "index read failed"
        ));
    }

    /// A head that no longer loads is this module's own `Backend` failure. Through
    /// [`crate::Repo`] the pre-verb snapshot (Story 9.26) hits it first, so the module function
    /// is called directly.
    #[test]
    fn a_head_that_no_longer_loads_is_a_backend_error() {
        let (_tmp, repo) = crate::test_support::repo_with_a_broken_head();
        let result = get_change(
            repo.workspace(),
            &jj_lib::id_prefix::IdPrefixContext::default(),
            &ChangeId("zzzzzzzzzzzz".to_owned()),
        );
        assert!(matches!(result, Err(ChangeError::Backend(_))), "{result:?}");
    }
}
