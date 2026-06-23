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
    pub name: String,
    pub email: String,
    pub timestamp: Timestamp,
}

/// A raw jj timestamp: milliseconds since the Unix epoch plus a timezone offset
/// in minutes east of UTC (jj-lib's `tz_offset` convention).
///
/// Stored raw (Decision D2) — infallible, FlatBuffers-friendly, no `chrono`
/// coupling in the public API.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Timestamp {
    pub millis_since_epoch: i64,
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
    pub authored_at: Timestamp,
    pub committed_at: Timestamp,
}

/// Whether a change is conflict-free.
///
/// `Conflicted { paths }` lists the conflicted file paths (consumed by Epic 6's
/// conflict-resolution flow).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConflictState {
    Clean,
    Conflicted { paths: Vec<PathBuf> },
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
    pub author: Signature,
    pub committer: Signature,
    /// Canonical authored/committed timestamp pair (mirrors `author.timestamp`
    /// and `committer.timestamp` respectively).
    pub timestamps: Timestamps,
    /// `true` if a cryptographic (GPG/SSH) signature is present (presence-only —
    /// Decision D3; validation via `Commit::verification()` is never performed).
    pub is_signed: bool,
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
    /// No change exists for the given id — either the id is empty or malformed
    /// (not valid reverse-hex), absent from the index, or only points to
    /// hidden/abandoned commits. These cases are indistinguishable to callers
    /// (Decision D6); `id` is the reverse-hex string that was passed in.
    #[error("change not found: {id}")]
    NotFound { id: String },
    /// An underlying jj-lib failure (index, backend, or loader error),
    /// opaque-string-wrapped so no `jj_lib` type escapes the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Converts any jj-lib error to [`ChangeError::Backend`].
fn be<E: std::fmt::Display>(e: E) -> ChangeError {
    ChangeError::Backend(e.to_string())
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

/// Returns full metadata for the change identified by `id` (reverse-hex form).
///
/// Re-resolves to head on every call (ADR-0002). Read-only.
///
/// # Errors
///
/// - [`ChangeError::NotFound`] — `id` is malformed, absent, or only-hidden (D6).
/// - [`ChangeError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn get_change(workspace: &Workspace, id: &ChangeId) -> Result<Change, ChangeError> {
    // 1. Reload to head (ADR-0002; sync via pollster — mirrors status.rs:85).
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let repo_dyn: &dyn jj_lib::repo::Repo = readonly.as_ref();
    let store = readonly.store();
    let view = readonly.view();

    // 2. Public reverse-hex string → jj ChangeId. Empty or malformed ⇒ NotFound (D6).
    //    `try_from_reverse_hex("")` returns `Some(ChangeId([]))` (0 is even-length), and an
    //    empty `HexPrefix` matches every commit — `resolve_change_id` would then hit
    //    `AmbiguousMatch` and panic. Guard the empty id explicitly so it collapses to
    //    NotFound like every other miss, never reaching that panic.
    if id.0.is_empty() {
        return Err(ChangeError::NotFound { id: id.0.clone() });
    }
    let jj_id = jj_lib::backend::ChangeId::try_from_reverse_hex(&id.0)
        .ok_or_else(|| ChangeError::NotFound { id: id.0.clone() })?;

    // 3. Resolve → visible commit(s), divergence-aware (D4).
    //    resolve_change_id is a Repo-trait method; `as _` import above brings it in scope.
    let targets = repo_dyn
        .resolve_change_id(&jj_id)
        .map_err(be)? // IndexError → Backend
        .ok_or_else(|| ChangeError::NotFound { id: id.0.clone() })?; // absent id
    let divergent = targets.is_divergent();
    // into_visible() consumes targets; call is_divergent() first.
    let commit_id = targets
        .into_visible()
        .and_then(|v| v.into_iter().next()) // index-first visible target (jj prefers newer-first; not guaranteed)
        .ok_or_else(|| ChangeError::NotFound { id: id.0.clone() })?; // only hidden/abandoned

    // 4. Load the chosen commit (sync; mirrors status.rs:92).
    let commit = store.get_commit(&commit_id).map_err(be)?;

    // 5. Parents: CommitIds → reverse-hex ChangeIds (mirrors status.rs:105-107).
    let mut parents = Vec::with_capacity(commit.parent_ids().len());
    for pid in commit.parent_ids() {
        let parent = store.get_commit(pid).map_err(be)?;
        parents.push(ChangeId(parent.change_id().reverse_hex()));
    }

    // 6. Signatures + timestamps (raw — D2). Timestamp is Copy so author.timestamp
    //    copies into `timestamps` while `author` continues to exist.
    let author = to_signature(commit.author());
    let committer = to_signature(commit.committer());
    let timestamps = Timestamps {
        authored_at: author.timestamp,
        committed_at: committer.timestamp,
    };

    // 7. Conflict state (D7): path-list only; per-path value errors are dropped.
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

    // 8. Anonymity (D5): empty description AND no local bookmark targets this commit.
    let is_anonymous = commit.description().is_empty() && view.local_bookmarks_for_commit(commit.id()).next().is_none();

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
