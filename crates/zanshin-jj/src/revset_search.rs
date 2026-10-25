// SPDX-License-Identifier: MIT

//! The op-pinned revset searches behind the graph search (Story 9.25): [`revset_counts`] counts a
//! batch of revsets, [`find_changes`] lists the changes one revset finds — both at the operation
//! the shown topology was read at, beyond the shown view.
//!
//! Both are pinned reads like [`crate::commit_content`]: the repo is loaded with
//! `load_operation` + `load_at` (never `load_at_head`), so they take no pre-verb snapshot, write
//! no operation, touch no op head and leave [`Repo::take_precondition`] untouched. Expressions
//! parse exactly as every Zanshin revset (the effective `[revset-aliases]`, `user.email` for
//! `mine()`, the workspace root for `files()`, `@` as the handle's workspace), and symbols resolve
//! with the id-prefix context as the CLI's `default_symbol_resolver`
//! (`cli/src/revset_util.rs:197-203` @ v0.46.0). Counting iterates the evaluated stream; it never
//! trusts `count_estimate`.

use futures::{StreamExt as _, TryStreamExt as _};
use jj_lib::backend::{ChangeId as JjChangeId, CommitId as JjCommitId};
use jj_lib::id_prefix::IdPrefixContext;
use jj_lib::object_id::ObjectId as _;

use crate::commit_content::load_pinned;
use crate::commit_meta::prefix_len;
use crate::config::ConfigError;
use crate::graph::{prefix_context, short_prefix_index};
use crate::revset::{
    parse_diagnosed, resolve_for_evaluation, revset_config, RevsetConfig, IN_REVSET_EXPRESSION, IN_SHORT_PREFIXES,
};
use crate::warning::{Warning, Warnings};
use crate::{ChangeId, CommitContentError, CommitId, OperationId, Repo, RevsetError};

/// One expression's count in [`RevsetCounts`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RevsetCount {
    /// How many commits the revset denotes, at most the call's `cap`.
    pub n: u64,
    /// The revset denotes more than `cap` commits.
    pub capped: bool,
}

/// The answer of [`crate::Repo::revset_counts`].
#[derive(Debug)]
pub struct RevsetCounts {
    /// One entry per requested expression, in request order: its count, or its own parse or
    /// resolution error.
    pub counts: Vec<Result<RevsetCount, RevsetError>>,
    /// The call's warnings — the alias load's and each expression's parse diagnostics (under "In
    /// revset expression"), in expression order.
    pub warnings: Vec<Warning>,
}

/// One change [`crate::Repo::find_changes`] found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoundChange {
    /// The commit's full hex id.
    pub commit_id: CommitId,
    /// The commit's change id (reverse hex).
    pub change_id: ChangeId,
    /// The shortest unique commit id prefix length within the call's `short_prefixes`.
    pub commit_prefix_len: u32,
    /// The shortest unique change id prefix length within the call's `short_prefixes`.
    pub change_prefix_len: u32,
}

/// The answer of [`crate::Repo::find_changes`].
#[derive(Debug)]
pub struct FoundChanges {
    /// At most `limit` entries, in the revset's iteration order (`jj log --no-graph`'s).
    pub entries: Vec<FoundChange>,
    /// The revset denotes more than `limit` commits.
    pub truncated: bool,
    /// The call's warnings — the alias load's, the parse diagnostics of `short_prefixes` and the
    /// expression, and `jj.short_prefixes_failed` when the prefix index fails to load (the lengths
    /// then fall back to the full index, as in the topology).
    pub warnings: Vec<Warning>,
}

/// The call-level faults of [`crate::Repo::revset_counts`] and [`crate::Repo::find_changes`].
#[derive(Debug, thiserror::Error)]
pub enum RevsetSearchError {
    /// The operation id is not a full hex id — the texts of
    /// [`crate::CommitContentError::InvalidInput`].
    #[error("{0}")]
    InvalidInput(String),
    /// The operation is not in the operation store — the CLI's `No operation ID matching "<id>"`.
    /// Carries the caller's id.
    #[error(r#"No operation ID matching "{0}""#)]
    OperationNotFound(String),
    /// The repo's effective jj config is malformed or unreadable, or its
    /// `revsets.short-prefixes` is not a string or does not parse.
    #[error(transparent)]
    Config(#[from] ConfigError),
    /// An underlying jj-lib failure — loading, evaluating, iterating or a prefix lookup.
    #[error("jj-lib error: {0}")]
    Backend(String),
    /// [`crate::Repo::find_changes`]'s `expression` or `short_prefixes` does not parse, or the
    /// expression does not resolve: [`RevsetError::ParseError`] / [`RevsetError::ResolutionError`].
    #[error(transparent)]
    Revset(RevsetError),
}

impl From<CommitContentError> for RevsetSearchError {
    fn from(e: CommitContentError) -> Self {
        match e {
            CommitContentError::InvalidInput(text) => Self::InvalidInput(text),
            CommitContentError::OperationNotFound(id) => Self::OperationNotFound(id),
            other => Self::Backend(other.to_string()),
        }
    }
}

/// Classifies a [`RevsetError`] of the call: an expression's parse or resolution error stays a
/// revset error, the rest are call-level faults.
fn call_level(e: RevsetError) -> RevsetSearchError {
    match e {
        e @ (RevsetError::ParseError { .. } | RevsetError::ResolutionError { .. }) => RevsetSearchError::Revset(e),
        RevsetError::Config(e) => RevsetSearchError::Config(e),
        RevsetError::JjLibError(reason) => RevsetSearchError::Backend(reason),
        // Unreachable here: no snapshot runs, no graph is walked.
        e @ (RevsetError::Precondition(_) | RevsetError::DanglingEdge { .. }) => {
            RevsetSearchError::Backend(e.to_string())
        }
    }
}

/// Converts any jj-lib error to [`RevsetError::JjLibError`].
fn jj<E: std::fmt::Display>(e: E) -> RevsetError {
    RevsetError::JjLibError(e.to_string())
}

/// `cap + 1` as an iterator bound: one entry past the cap tells whether it was exceeded.
fn past(cap: u64) -> usize {
    usize::try_from(cap.saturating_add(1)).unwrap_or(usize::MAX)
}

/// What one call parses its expressions with.
struct Search<'a> {
    repo: &'a Repo,
    parse_config: RevsetConfig,
    prefixes: IdPrefixContext,
}

impl Search<'_> {
    /// Counts `expr` at the pinned `repo_dyn`: parse, resolve and — unless `cap` is `0` — evaluate
    /// and iterate at most `cap + 1` entries.
    fn count(
        &self,
        repo_dyn: &dyn jj_lib::repo::Repo,
        expr: &str,
        cap: u64,
        sink: &mut Warnings,
    ) -> Result<RevsetCount, RevsetError> {
        let parsed = parse_diagnosed(
            self.repo.workspace(),
            &self.parse_config,
            (expr, IN_REVSET_EXPRESSION),
            sink,
        )?;
        let resolved = resolve_for_evaluation(repo_dyn, &parsed, Some(&self.prefixes))?;
        if cap == 0 {
            return Ok(RevsetCount { n: 0, capped: false });
        }
        let set = resolved.evaluate().map_err(jj)?;
        let len = pollster::block_on(
            set.stream()
                .take(past(cap))
                .try_fold(0u64, |n, _| async move { Ok(n + 1) }),
        )
        .map_err(jj)?;
        Ok(RevsetCount {
            n: len.min(cap),
            capped: len > cap,
        })
    }
}

/// [`crate::Repo::revset_counts`]: loads the pinned operation, then the effective config and its
/// `revsets.short-prefixes`, then counts each expression in order.
///
/// # Errors
///
/// See [`crate::Repo::revset_counts`].
pub(crate) fn revset_counts(
    repo: &Repo,
    operation_id: &OperationId,
    expressions: &[String],
    cap: u64,
) -> Result<RevsetCounts, RevsetSearchError> {
    let readonly = load_pinned(repo.workspace(), operation_id)?;
    let mut sink = Warnings::default();
    let result = (|| -> Result<Vec<_>, RevsetSearchError> {
        let config = crate::config::load(repo)?;
        let parse_config = revset_config(&config, &mut sink)?;
        let workspace = repo.workspace();
        let short = crate::template::load_short_prefixes(
            (workspace.workspace_root(), workspace.workspace_name()),
            &parse_config,
            &config,
            &mut sink,
        )?;
        let search = Search {
            repo,
            parse_config,
            prefixes: prefix_context(short.as_ref()),
        };
        expressions
            .iter()
            .map(|expr| match search.count(readonly.as_ref(), expr, cap, &mut sink) {
                Err(e @ (RevsetError::ParseError { .. } | RevsetError::ResolutionError { .. })) => Ok(Err(e)),
                Err(e) => Err(call_level(e)),
                Ok(count) => Ok(Ok(count)),
            })
            .collect()
    })();
    finish(result, sink, |counts, warnings| RevsetCounts { counts, warnings })
}

/// [`crate::Repo::find_changes`]: loads the pinned operation, then parses `short_prefixes` and the
/// expression, resolves it within the prefix context and reads at most `limit + 1` entries.
///
/// # Errors
///
/// See [`crate::Repo::find_changes`].
pub(crate) fn find_changes(
    repo: &Repo,
    operation_id: &OperationId,
    expression: &str,
    limit: u64,
    short_prefixes: &str,
) -> Result<FoundChanges, RevsetSearchError> {
    let readonly = load_pinned(repo.workspace(), operation_id)?;
    let repo_dyn: &dyn jj_lib::repo::Repo = readonly.as_ref();
    let mut sink = Warnings::default();
    let result = (|| -> Result<_, RevsetSearchError> {
        let config = crate::config::load(repo)?;
        let parse_config = revset_config(&config, &mut sink)?;
        let workspace = repo.workspace();
        // The CLI parses `revsets.short-prefixes` in its start-up environment, before the command's
        // own revset; an empty text disables disambiguation.
        let short = (!short_prefixes.is_empty())
            .then(|| parse_diagnosed(workspace, &parse_config, (short_prefixes, IN_SHORT_PREFIXES), &mut sink))
            .transpose()
            .map_err(|e| call_level(e.without_span()))?;
        let parsed = parse_diagnosed(workspace, &parse_config, (expression, IN_REVSET_EXPRESSION), &mut sink)
            .map_err(call_level)?;
        let prefixes = prefix_context(short.as_ref());
        let set = resolve_for_evaluation(repo_dyn, &parsed, Some(&prefixes))
            .map_err(call_level)?
            .evaluate()
            .map_err(|e| RevsetSearchError::Backend(e.to_string()))?;
        let ids: Vec<(JjCommitId, JjChangeId)> =
            pollster::block_on(set.commit_change_ids().take(past(limit)).try_collect())
                .map_err(|e| RevsetSearchError::Backend(e.to_string()))?;
        let truncated = u64::try_from(ids.len()).unwrap_or(u64::MAX) > limit;
        // The same index resolved the symbols; a load failure warns and degrades, as the topology.
        let index = short_prefix_index(&prefixes, repo_dyn, &mut sink);
        let entries = ids
            .iter()
            .take(usize::try_from(limit).unwrap_or(usize::MAX))
            .map(|(commit_id, change_id)| {
                Ok(FoundChange {
                    commit_id: CommitId(commit_id.hex()),
                    change_id: ChangeId(change_id.reverse_hex()),
                    commit_prefix_len: prefix_len(index.shortest_commit_prefix_len(repo_dyn, commit_id))?,
                    change_prefix_len: prefix_len(pollster::block_on(
                        index.shortest_change_prefix_len(repo_dyn, change_id),
                    ))?,
                })
            })
            .collect::<Result<Vec<_>, RevsetError>>()
            .map_err(call_level)?;
        Ok((entries, truncated))
    })();
    finish(result, sink, |(entries, truncated), warnings| FoundChanges {
        entries,
        truncated,
        warnings,
    })
}

/// Hands the collected warnings to the answer; a failed call has no warning channel, so they are
/// logged and dropped.
fn finish<T, R>(
    result: Result<T, RevsetSearchError>,
    mut sink: Warnings,
    build: impl FnOnce(T, Vec<Warning>) -> R,
) -> Result<R, RevsetSearchError> {
    match result {
        Ok(value) => Ok(build(value, sink.take())),
        Err(e) => {
            crate::warning::log_dropped("revset_search", sink.take());
            Err(e)
        }
    }
}
