// SPDX-License-Identifier: MIT

//! The op-pinned batch content lookup (Story 4.10) — the object half of a `jj log` row.
//!
//! [`commit_contents`] is the CONTINUATION of [`crate::Repo::graph_topology`]'s `jj log`: the
//! CLI's per-row `get_commit_async` (`cli/src/commands/log.rs` @ v0.44.0), run at the operation
//! the topology call returned. It therefore runs no precondition, no snapshot, no import, no
//! config load and no secure-config fix-up, and it writes no operation and no op head: the repo
//! is loaded with `load_operation` + `load_at`, never `load_at_head` (which prunes ancestor op
//! heads and reconciles divergent ones). Like any load, `load_at` may write the operation's
//! index files when they are missing. The values are commit-intrinsic (a commit is
//! content-addressed), so a head that moved since the topology call changes nothing
//! (docs/adr/0002 Addendum 2026-09-30).

use jj_lib::backend::CommitId as JjCommitId;
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::{OpStoreError, OperationId as JjOperationId};
use jj_lib::repo::Repo as _;
use jj_lib::workspace::Workspace;

use crate::commit_meta::object_half;
use crate::{CommitId, OperationId, Timestamp};

/// The object half of one `jj log` row (Story 4.10): what only the loaded commit answers.
///
/// Commit-intrinsic — a commit is content-addressed and its parents are part of it — so a
/// caller may cache it by [`Self::commit_id`] across operations. The view half (change id,
/// refs, flags) is [`crate::TopologyMeta`].
///
/// The root commit's entry carries jj-lib's fabricated values, exactly as `jj log` shows them:
/// empty author name and email, an empty description, and a committer timestamp of `0` (the
/// epoch) with offset `0` — unlike the topology, which gives the root no timestamp at all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitContent {
    /// The commit's full hex id (lowercase, as jj prints it), so a row describes itself even
    /// though the list comes back in request order.
    pub commit_id: CommitId,
    /// Author name; may be empty (jj allows it).
    pub author_name: String,
    /// Author email; may be empty (jj allows it).
    pub author_email: String,
    /// The **committer** timestamp — what `jj log`'s compact template shows.
    pub committer_timestamp: Timestamp,
    /// The FULL description; `""` when it is empty (the "(no description set)" placeholder is
    /// UI text). A card derives the first line itself.
    pub description: String,
    /// The commit's tree has unresolved conflicts.
    pub conflict: bool,
    /// The tree equals the merged parent trees (description is not considered).
    pub empty: bool,
}

/// Errors returned by [`crate::Repo::commit_contents`], in check order.
#[derive(Debug, thiserror::Error)]
pub enum CommitContentError {
    /// An operation id or a commit id is not a full hex id: empty, a non-hex character, or not
    /// the store's full length (prefixes are not resolved — the caller got the full ids from the
    /// topology call). The text names the offending id.
    #[error("{0}")]
    InvalidInput(String),
    /// The operation is not in the operation store (abandoned and garbage-collected) — the CLI's
    /// `No operation ID matching "<id>"`. Carries the caller's id.
    #[error(r#"No operation ID matching "{0}""#)]
    OperationNotFound(String),
    /// A well-formed commit id the pinned operation's index does not carry. Carries the
    /// caller's hex.
    #[error("commit {0} is not in the operation's index")]
    CommitNotFound(String),
    /// An underlying jj-lib failure — loading the operation or its repo, reading the index, or
    /// loading an indexed commit (or, for `empty`, its parents) — opaque-string-wrapped so no
    /// `jj_lib` type escapes the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Converts any jj-lib error to [`CommitContentError::Backend`].
fn be<E: std::fmt::Display>(e: E) -> CommitContentError {
    CommitContentError::Backend(e.to_string())
}

/// Why a caller-supplied id string is not a full hex id.
#[derive(Debug, PartialEq, Eq)]
enum IdFault {
    /// Empty, or a character outside `[0-9a-fA-F]`.
    NotHex,
    /// All hex, but not `hex_len` digits long.
    NotFull,
}

/// Classifies `id` against a full id of `hex_len` hex digits. Uppercase is accepted, as
/// jj-lib's decoder accepts it.
fn classify(id: &str, hex_len: usize) -> Result<(), IdFault> {
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(IdFault::NotHex);
    }
    if id.len() != hex_len {
        return Err(IdFault::NotFull);
    }
    Ok(())
}

/// Parses a full operation id; the empty/non-hex text is the CLI's
/// `OpsetResolutionError::InvalidIdPrefix` (jj-lib `op_walk.rs:79-81` @ v0.44.0).
fn parse_operation_id(id: &str, hex_len: usize) -> Result<JjOperationId, CommitContentError> {
    let not_hex =
        || CommitContentError::InvalidInput(format!(r#"Operation ID "{id}" is not a valid hexadecimal prefix"#));
    match classify(id, hex_len) {
        Err(IdFault::NotHex) => Err(not_hex()),
        Err(IdFault::NotFull) => Err(CommitContentError::InvalidInput(format!(
            r#"Operation ID "{id}" is not a full operation ID"#
        ))),
        Ok(()) => JjOperationId::try_from_hex(id).ok_or_else(not_hex),
    }
}

/// Parses a full commit id, with the same two texts as [`parse_operation_id`].
fn parse_commit_id(id: &str, hex_len: usize) -> Result<JjCommitId, CommitContentError> {
    let not_hex = || CommitContentError::InvalidInput(format!(r#"Commit ID "{id}" is not a valid hexadecimal prefix"#));
    match classify(id, hex_len) {
        Err(IdFault::NotHex) => Err(not_hex()),
        Err(IdFault::NotFull) => Err(CommitContentError::InvalidInput(format!(
            r#"Commit ID "{id}" is not a full commit ID"#
        ))),
        Ok(()) => JjCommitId::try_from_hex(id).ok_or_else(not_hex),
    }
}

/// Reads the object half of every commit in `commit_ids`, in request order, at the pinned
/// `operation_id` (see the module doc for the framing).
///
/// Check order: (a) the operation id's format; (b) the operation's load; (c) EVERY commit id's
/// format, then EVERY commit id's presence in the pinned index; (d) the commit loads. Validating
/// all ids before the first load makes the ladder deterministic — a malformed id is
/// [`CommitContentError::InvalidInput`] wherever it sits — and the index check is the only thing
/// that separates an unknown id ([`CommitContentError::CommitNotFound`]) from an indexed but
/// unloadable one ([`CommitContentError::Backend`]): `get_commit_async` answers `ObjectNotFound`
/// for both. An empty list is `Ok(vec![])`.
///
/// # Errors
///
/// - [`CommitContentError::InvalidInput`] — the operation id or a commit id is not a full hex id.
/// - [`CommitContentError::OperationNotFound`] — the operation is not in the operation store.
/// - [`CommitContentError::CommitNotFound`] — a commit id is not in the pinned operation's index.
/// - [`CommitContentError::Backend`] — any jj-lib failure while loading.
pub(crate) fn commit_contents(
    workspace: &Workspace,
    operation_id: &OperationId,
    commit_ids: &[CommitId],
) -> Result<Vec<CommitContent>, CommitContentError> {
    let loader = workspace.repo_loader();

    // (a) + (b): the pinned operation and its repo.
    let op_hex_len = loader.op_store().root_operation_id().as_bytes().len() * 2;
    let op_id = parse_operation_id(&operation_id.0, op_hex_len)?;
    let operation = pollster::block_on(loader.load_operation(&op_id)).map_err(|e| match e {
        OpStoreError::ObjectNotFound { .. } => CommitContentError::OperationNotFound(operation_id.0.clone()),
        other => be(other),
    })?;
    let repo = pollster::block_on(loader.load_at(&operation)).map_err(be)?;
    let store = repo.store();

    // (c) FIRST pass: every id's format, then every id's presence in the pinned index.
    let id_hex_len = store.commit_id_length() * 2;
    let ids = commit_ids
        .iter()
        .map(|id| parse_commit_id(&id.0, id_hex_len))
        .collect::<Result<Vec<_>, _>>()?;
    for (id, requested) in ids.iter().zip(commit_ids) {
        if !pollster::block_on(repo.index().has_id(id)).map_err(be)? {
            return Err(CommitContentError::CommitNotFound(requested.0.clone()));
        }
    }

    // (d) SECOND pass: the loads, in request order.
    let repo_dyn: &dyn jj_lib::repo::Repo = repo.as_ref();
    ids.iter()
        .map(|id| {
            let commit = pollster::block_on(store.get_commit_async(id)).map_err(be)?;
            object_half(repo_dyn, &commit).map_err(be)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{classify, parse_commit_id, parse_operation_id, CommitContentError, IdFault};

    #[test]
    fn classify_rejects_empty_and_non_hex_before_length() {
        assert_eq!(classify("", 4), Err(IdFault::NotHex));
        assert_eq!(classify("zz", 4), Err(IdFault::NotHex));
        assert_eq!(classify("ab\0c", 4), Err(IdFault::NotHex), "an interior NUL is not hex");
        assert_eq!(
            classify("abcg", 4),
            Err(IdFault::NotHex),
            "non-hex wins over a correct length"
        );
    }

    #[test]
    fn classify_rejects_prefixes_and_odd_lengths_as_not_full() {
        assert_eq!(classify("abc", 4), Err(IdFault::NotFull));
        assert_eq!(classify("ab", 4), Err(IdFault::NotFull));
        assert_eq!(classify("abcdef", 4), Err(IdFault::NotFull));
    }

    #[test]
    fn classify_accepts_full_ids_in_either_case() {
        assert_eq!(classify("abcd", 4), Ok(()));
        assert_eq!(classify("ABCD", 4), Ok(()));
    }

    #[test]
    fn operation_id_errors_carry_the_cli_and_the_not_full_texts() {
        let text = |r: Result<_, CommitContentError>| match r {
            Err(CommitContentError::InvalidInput(text)) => text,
            other => panic!("expected InvalidInput, got {other:?}"),
        };
        assert_eq!(
            text(parse_operation_id("xyz", 4)),
            r#"Operation ID "xyz" is not a valid hexadecimal prefix"#
        );
        assert_eq!(
            text(parse_operation_id("", 4)),
            r#"Operation ID "" is not a valid hexadecimal prefix"#
        );
        assert_eq!(
            text(parse_operation_id("abc", 4)),
            r#"Operation ID "abc" is not a full operation ID"#
        );
        assert!(parse_operation_id("ABcd", 4).is_ok(), "uppercase hex is accepted");
    }

    #[test]
    fn commit_id_errors_name_the_commit_id() {
        let text = |r: Result<_, CommitContentError>| match r {
            Err(CommitContentError::InvalidInput(text)) => text,
            other => panic!("expected InvalidInput, got {other:?}"),
        };
        assert_eq!(
            text(parse_commit_id("zz", 4)),
            r#"Commit ID "zz" is not a valid hexadecimal prefix"#
        );
        assert_eq!(
            text(parse_commit_id("ab", 4)),
            r#"Commit ID "ab" is not a full commit ID"#
        );
        assert!(parse_commit_id("abcd", 4).is_ok());
    }

    #[test]
    fn operation_not_found_displays_the_cli_text() {
        assert_eq!(
            CommitContentError::OperationNotFound("ab".to_owned()).to_string(),
            r#"No operation ID matching "ab""#
        );
    }
}
