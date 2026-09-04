// SPDX-License-Identifier: MIT

//! `bookmark_ops.rs` — the two cheapest bookmark MUTATIONS (Story 9.8): `bookmark create`
//! and `bookmark delete`.
//!
//! Split from [`crate::bookmarks`], which stays the pure FR-JJ-8 *read* with its own minimal
//! [`crate::BookmarkError`]; these two return [`MutationResult`]/[`MutateError`], and mixing
//! the two taxonomies into one module would give it two error vocabularies. The git domain
//! is already split exactly this way — `remotes.rs` reads, `git.rs` mutates.
//!
//! Both verbs open one jj-lib transaction via [`crate::mutate::finish_or_no_op`] and commit
//! with the CLI's own op-log description (NFR-R-2) — jj-lib only, never shells to `jj`
//! (AR-AP-1). Re-resolves to the head operation per call (ADR-0002). `delete` can
//! legitimately finish WITHOUT writing an operation (its patterns matched nothing), and then
//! [`MutationResult::new_op_id`] is the PRE-CALL op-log head — the machine-readable form of
//! the CLI's "No bookmarks to delete."
//!
//! Ports `cli/src/commands/bookmark/create.rs`, `.../delete.rs` and the
//! `has_tracked_remote_bookmarks` helper from `cli/src/cli_util.rs:3385-3393`, all @ v0.44.0.
//!
//! # Deliberate divergences from the CLI at v0.44.0
//!
//! - **No auto-tracking on create.** The CLI honours `remotes.<r>.auto-track-bookmarks` /
//!   `auto-track-created-bookmarks` by calling `track_remote_bookmark` for every matching
//!   remote (`create.rs:89-111`). That verb is Story 9.11's; until it lands, a created
//!   bookmark is never auto-tracked here. Deliberately deferred, not overlooked.
//! - **Names are DECODED values, not CLI argument text.** The CLI validates a create name
//!   with `revset_util::parse_bookmark_name` = `revset::parse_symbol`, i.e. the user must
//!   type `'foo bar'` to name a bookmark `foo bar`. That quoting is terminal input syntax the
//!   GUI replaces (ADR-0003), so the name crosses verbatim. The one behavioural residue kept
//!   is the refusal `parse_symbol` makes in every spelling: an EMPTY name is rejected. jj-lib
//!   itself validates nothing.
//! - **Delete patterns are pass-through STRINGS.** There the `glob:`/`exact:`/`regex:`/
//!   `substring:` prefix IS the parameter's meaning, not its spelling (FR-JJ-17), so the text
//!   reaches `jj_lib::revset::parse_string_expression` unchanged. Consequence worth saying
//!   loudly: a BARE pattern is a GLOB, so deleting a bookmark whose name contains `*`, `?` or
//!   `[` needs `exact:"…"`.
//! - **No terminal UX.** "Target revision is empty.", "Created N bookmarks pointing to …",
//!   "Deleted N bookmarks.", "No bookmarks to delete." and
//!   `warn_unmatched_local_bookmarks`' "No matching bookmarks for names: …"
//!   (`bookmark/mod.rs:185-203`) are all stdout/stderr chatter. The machine-readable
//!   equivalent of the last two is already in the contract: an unchanged `new_op_id` means
//!   nothing happened.

use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::RefTarget;
use jj_lib::ref_name::{RefName, RefNameBuf};
use jj_lib::repo::Repo as _;
use jj_lib::revset::{parse_string_expression, RevsetDiagnostics};
use jj_lib::str_util::{StringExpression, StringMatcher};
use jj_lib::workspace::Workspace;

use crate::mutate::{self, finish_or_no_op, MutateError, MutationResult};
use crate::ChangeId;

/// Turns caller-supplied names into jj-lib `RefNameBuf`s, refusing the two arities the CLI
/// refuses: no names at all (clap's `required = true`) and an EMPTY name (`parse_symbol`'s
/// `Expected non-empty string`, which no spelling of the CLI argument can get around).
fn validate_names(names: &[String]) -> Result<Vec<RefNameBuf>, MutateError> {
    if names.is_empty() {
        return Err(MutateError::InvalidInput {
            reason: "bookmark create requires at least one name".to_owned(),
        });
    }
    if names.iter().any(String::is_empty) {
        return Err(MutateError::InvalidInput {
            reason: "bookmark name must not be empty".to_owned(),
        });
    }
    Ok(names.iter().map(RefNameBuf::from).collect())
}

/// Whether `bookmark` has any TRACKED remote bookmark — the CLI's
/// `cli_util.rs:3385-3393` `has_tracked_remote_bookmarks`.
///
/// The default-ignored remote is excluded, which for a git-backed repo is jj-lib's reserved
/// `git` (`cli_util.rs:3372-3381` `default_ignored_remote_name`). That is why a colocated
/// `foo@git` does NOT block `create foo`.
fn has_tracked_remote_bookmarks(repo: &dyn jj_lib::repo::Repo, bookmark: &RefName) -> bool {
    let remote_matcher = if jj_lib::git::get_git_backend(repo.store()).is_ok() {
        StringExpression::exact(jj_lib::git::REMOTE_NAME_FOR_LOCAL_GIT_REPO.as_str())
            .negated()
            .to_matcher()
    } else {
        StringMatcher::all()
    };
    // Bound to a local so the returned iterator — which borrows `remote_matcher` — is dropped
    // before the matcher is, rather than at the end of the block.
    let tracked = repo
        .view()
        .remote_bookmarks_matching(&StringMatcher::exact(bookmark.as_str()), &remote_matcher)
        .any(|(_, remote_ref)| remote_ref.is_tracked());
    tracked
}

/// Parses each pattern and UNIONS them — the CLI's `revset_util.rs:317-337`
/// `parse_union_name_patterns`, minus its `ui` diagnostics printing.
///
/// A bare word is a GLOB, not an exact name (`jj_lib::revset`'s `expect_string_expression`
/// lowers an identifier or quoted string to `StringPattern::glob`).
fn union_matcher(patterns: &[String]) -> Result<StringMatcher, MutateError> {
    let mut diagnostics = RevsetDiagnostics::new();
    let mut expressions = Vec::with_capacity(patterns.len());
    for pattern in patterns {
        let expression = parse_string_expression(&mut diagnostics, pattern).map_err(|e| MutateError::InvalidInput {
            // The CLI's own wording (`Failed to parse name pattern: {kind}`), lower-cased to
            // match this crate's message style.
            reason: format!("failed to parse name pattern: {}", e.kind()),
        })?;
        expressions.push(expression);
    }
    Ok(StringExpression::union_all(expressions).to_matcher())
}

/// Renders `names` the way the CLI's op-log descriptions do: `RefName::as_symbol()`, joined
/// by `", "`.
///
/// `as_symbol` is the QUOTED revset rendering, and this is the ONE place it is right — the
/// description is a rendering, so byte-level op-log parity (NFR-R-2) requires it. Every
/// PAYLOAD name still crosses as `as_str` (`git.rs`'s `project_updates`).
fn join_symbols(names: &[RefNameBuf]) -> String {
    names
        .iter()
        .map(|name| name.as_symbol().to_string())
        .collect::<Vec<_>>()
        .join(", ")
}

/// Creates local bookmarks pointing at one revision (Story 9.8) — the CLI's
/// `jj bookmark create`.
///
/// `revision` is the CLI's `-r/--revision`, whose clap `default_value` is the literal `"@"`
/// (not a config key), so `None` resolves the workspace's working-copy commit — the
/// LAST-SNAPSHOTTED one, since Zanshin never snapshots (D2).
///
/// Both per-name preconditions run in ARGUMENT order and are FAIL-FAST, exactly as the CLI's
/// loop is (`create.rs:64-83` returns on the first offender, before its transaction opens):
/// a run whose second name already exists creates nothing at all, not even the first.
///
/// Description: `create bookmark {names} pointing to commit {id}` with `names` joined `", "`
/// in argument order and `id` the FULL commit hex (`create.rs:123-131`).
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — `names` is empty, or a name is the empty string.
/// - [`MutateError::ChangeNotFound`] — `revision` is malformed, absent, only-hidden, or
///   divergent.
/// - [`MutateError::BookmarkExists`] — a name is already a local bookmark.
/// - [`MutateError::BookmarkTrackedRemoteExists`] — a name's local bookmark is absent but it
///   still has a tracked remote bookmark.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn create(
    workspace: &mut Workspace,
    names: &[String],
    revision: Option<&ChangeId>,
) -> Result<MutationResult, MutateError> {
    let ref_names = validate_names(names)?;

    // CLI order (`create.rs:57-60`): the revision resolves FIRST, before any per-name
    // precondition. It is resolved here — against its own head load, rather than inside the
    // transaction below — because the op-log description embeds the target's full commit
    // hex, and `finish_or_no_op` needs that description up front. `delete` reads its head
    // view before the transaction for the same reason.
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let target_id = crate::op_support::resolve_or_wc(readonly.as_ref(), &workspace_name, revision)
        .map_err(|e| mutate::res(e, revision))?
        .id()
        .clone();
    drop(readonly);

    let description = format!(
        "create bookmark {names} pointing to commit {id}",
        names = join_symbols(&ref_names),
        id = target_id.hex(),
    );
    let finished = finish_or_no_op(workspace, &description, |tx| {
        // Both guards for every name before ANY write, which is what makes the refusal
        // fail-fast: the CLI runs this loop entirely before it opens its transaction.
        for name in &ref_names {
            let repo = tx.repo();
            if repo.view().get_local_bookmark(name).is_present() {
                return Err(MutateError::BookmarkExists {
                    name: name.as_str().to_owned(),
                });
            }
            if has_tracked_remote_bookmarks(repo, name) {
                return Err(MutateError::BookmarkTrackedRemoteExists {
                    name: name.as_str().to_owned(),
                });
            }
        }
        for name in &ref_names {
            tx.repo_mut()
                .set_local_bookmark_target(name, RefTarget::normal(target_id.clone()));
        }
        // NO explicit rebase/normalize pass: `set_local_bookmark_target` calls
        // `View::add_head` (clearing the head-normalized bit) but records no REWRITE, and
        // `MutableRepo::consume()` normalizes heads on its own inside `Transaction::write`.
        Ok(())
    })?;
    Ok(finished.mutation)
}

/// Deletes the local bookmarks matching `patterns` (Story 9.8) — the CLI's
/// `jj bookmark delete`.
///
/// Each pattern is jj's own string-pattern syntax, unioned across the list. A BARE pattern is
/// a GLOB (`glob:`, `exact:`, `regex:` and `substring:` all work, as do the `~`/`&`/`|`
/// operators), so a bookmark whose name contains `*`, `?` or `[` needs `exact:"…"`.
///
/// Matching NOTHING is a SUCCESS, never a refusal: no operation is written and the returned
/// `new_op_id` is the PRE-CALL op-log head (`delete.rs:63-67` likewise returns before opening
/// a transaction). A CONFLICTED local bookmark is deleted like any other —
/// `RefTarget::absent()` removes it regardless.
///
/// A TRACKED `name@remote` SURVIVES the delete by design (`jj-lib view.rs:197-213` prunes
/// only remote rows that are themselves absent), which is the "deleted bookmark, propagates
/// on the next push" state [`crate::Repo::list_bookmarks`] keeps reporting. `jj bookmark
/// forget` (Story 9.11) is the verb that does not.
///
/// Description: `delete bookmark {names}` with the MATCHED names joined `", "` in VIEW
/// (lexicographic) order (`delete.rs:79-89`).
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — `patterns` is empty, or a pattern does not parse.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn delete(workspace: &mut Workspace, patterns: &[String]) -> Result<MutationResult, MutateError> {
    if patterns.is_empty() {
        return Err(MutateError::InvalidInput {
            reason: "bookmark delete requires at least one name pattern".to_owned(),
        });
    }
    let matcher = union_matcher(patterns)?;

    // The description names the MATCHED bookmarks, so the view has to be read before the
    // transaction opens — see `create`'s note. `local_bookmarks_matching` is sorted by name,
    // which is the CLI's own ordering here.
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
    let doomed: Vec<RefNameBuf> = readonly
        .view()
        .local_bookmarks_matching(&matcher)
        .map(|(name, _)| name.to_owned())
        .collect();
    drop(readonly);

    let description = format!("delete bookmark {}", join_symbols(&doomed));
    let finished = finish_or_no_op(workspace, &description, |tx| {
        for name in &doomed {
            tx.repo_mut().set_local_bookmark_target(name, RefTarget::absent());
        }
        Ok(())
    })?;
    Ok(finished.mutation)
}

#[cfg(test)]
mod tests {
    use super::{join_symbols, union_matcher, validate_names};
    use crate::MutateError;

    /// The two arity refusals the CLI makes at clap level, which have to become wire-level
    /// refusals here (a GUI has no clap): no names at all, and an empty name.
    #[test]
    fn validate_names_refuses_the_two_clap_level_arities() {
        let empty_list = validate_names(&[]).expect_err("clap's required = true");
        assert!(
            matches!(&empty_list, MutateError::InvalidInput { reason } if reason.contains("at least one name")),
            "unexpected error: {empty_list:?}"
        );
        let empty_name = validate_names(&["ok".to_owned(), String::new()]).expect_err("parse_symbol rejects it");
        assert!(
            matches!(&empty_name, MutateError::InvalidInput { reason } if reason.contains("must not be empty")),
            "unexpected error: {empty_name:?}"
        );
        let ok = validate_names(&["a".to_owned(), "b".to_owned()]).expect("two ordinary names");
        assert_eq!(ok.len(), 2);
    }

    /// A name needing revset QUOTING is accepted verbatim — the quoting is terminal syntax
    /// the GUI replaces — but the op-log description still renders it quoted, because that
    /// string is what NFR-R-2 pins byte-for-byte.
    #[test]
    fn join_symbols_renders_the_quoted_revset_form_in_argument_order() {
        let names = validate_names(&["b".to_owned(), "a b".to_owned()]).expect("valid names");
        assert_eq!(join_symbols(&names), r#"b, "a b""#);
        assert_eq!(join_symbols(&[]), "");
    }

    /// A malformed pattern is the caller's problem, and jj-lib's own reason is forwarded.
    #[test]
    fn union_matcher_refuses_a_malformed_pattern() {
        let err = union_matcher(&["glob:\"[\"".to_owned()]).expect_err("an unterminated glob class");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason } if reason.contains("failed to parse name pattern")),
            "unexpected error: {err:?}"
        );
    }

    /// The trap worth pinning: a BARE pattern is a glob, so `foo*` matches a bookmark
    /// literally named `foo*` AND one named `foo1`, while `exact:"foo*"` matches only the
    /// literal. Asserted on the matcher itself so it holds independently of any fixture.
    #[test]
    fn union_matcher_treats_a_bare_pattern_as_a_glob() {
        let glob = union_matcher(&["foo*".to_owned()]).expect("a bare pattern parses");
        assert!(glob.is_match("foo*"), "the literal name matches its own glob");
        assert!(glob.is_match("foo1"), "a bare pattern is a GLOB, not an exact name");

        let exact = union_matcher(&["exact:\"foo*\"".to_owned()]).expect("an exact pattern parses");
        assert!(exact.is_match("foo*"));
        assert!(!exact.is_match("foo1"), "exact: matches only the literal name");

        // Patterns are UNIONED, not intersected.
        let union = union_matcher(&["exact:a".to_owned(), "exact:b".to_owned()]).expect("both parse");
        assert!(union.is_match("a") && union.is_match("b"));
        assert!(!union.is_match("c"));
    }
}
