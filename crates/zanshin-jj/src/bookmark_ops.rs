// SPDX-License-Identifier: MIT

//! `bookmark_ops.rs` — the bookmark MUTATIONS: `bookmark create` and `bookmark delete` (Story
//! 9.8), `bookmark move`, `advance` and `rename` (Story 9.19).
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
//! `create` auto-tracks like the CLI (`create.rs:88-111` @ v0.46.0, Story 9.54's closing run):
//! every created name a remote's `remotes.<r>.auto-track-bookmarks` ∪
//! `auto-track-created-bookmarks` matcher accepts is tracked on that remote, if the remote has a
//! view.
//!
//! # Deliberate divergences from the CLI at v0.44.0
//!
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
//! - **No terminal UX.** "Created N bookmarks pointing to …", "Deleted N bookmarks." and
//!   "No bookmarks to delete." are stdout chatter; the machine-readable equivalent of the last
//!   one is already in the contract: an unchanged `new_op_id` means nothing happened. The
//!   WARNINGS — "Target revision is empty.", `warn_unmatched_local_bookmarks`' "No matching
//!   bookmarks for names: …" (`bookmark/mod.rs:185-203`) and "Auto-tracking bookmark that exists
//!   on the remote: …" (`create.rs:104-108` @ v0.46.0) — ride the call's warnings as
//!   `jj.bookmark_target_empty` / `jj.bookmark_names_unmatched` (Story 9.32) /
//!   `jj.bookmark_auto_track_existing`.
//!
//! # Move, advance and rename (Story 9.19, ports of `bookmark/{move,advance,rename}.rs` @ v0.46.0)
//!
//! - **Move and advance address bookmarks by EXACT name** — the CLI's `exact:"…"` pattern, never
//!   its default glob (the epic's 2026-10-14 decision): a GUI names the bookmark it moves, and a
//!   hidden glob default would move others. `--from` stays REVSET text, `--to` a change id.
//! - **Both decide fast-forward through [`plan_bookmark_move`]**, the fn `drop_actions`' bookmark
//!   row calls, so a row and the verb cannot disagree.
//! - **No terminal UX.** "Moved/Advanced N bookmarks to …", "No bookmarks to update." (an unchanged
//!   `new_op_id` says it) and the success hint "Specify bookmark by name to update just one of the
//!   bookmarks." (it only advises a CLI user typing `--from`; the GUI names what it moves, and
//!   [`MutationResult`] has no hints) are dropped.
//! - **Rename's four warnings ride the call's warnings** as `jj.bookmark_rename_remote_exists`,
//!   `jj.bookmark_tracking_dropped`, `jj.bookmark_remotes_not_renamed` and
//!   `jj.bookmark_tracked_remotes_exist`, each with the CLI's message; the hint line the CLI prints
//!   under each is dropped (warnings carry code and message only).

use std::sync::Arc;

use jj_lib::commit::Commit;
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::RefTarget;
use jj_lib::ref_name::{RefName, RefNameBuf};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::revset::{parse_string_expression, Revset, RevsetDiagnostics, RevsetParseError};
use jj_lib::str_util::{StringExpression, StringMatcher};
use jj_lib::workspace::Workspace;

use crate::mutate::{self, finish_or_no_op_at, flatten_chain, MutateError, MutationResult};
use crate::snapshot::VerbContext;
use crate::warning::{WarningKind, Warnings};
use crate::ChangeId;

/// Turns caller-supplied names into jj-lib `RefNameBuf`s, refusing the two arities the CLI
/// refuses: no names at all (clap's `required = true`) and an EMPTY name (`parse_symbol`'s
/// `Expected non-empty string`, which no spelling of the CLI argument can get around).
fn validate_names(names: &[String]) -> Result<Vec<RefNameBuf>, MutateError> {
    if names.is_empty() {
        return Err(MutateError::invalid(
            "bookmark create requires at least one name".to_owned(),
        ));
    }
    if names.iter().any(String::is_empty) {
        return Err(MutateError::invalid("bookmark name must not be empty".to_owned()));
    }
    Ok(names.iter().map(RefNameBuf::from).collect())
}

/// Whether `bookmark` has any TRACKED remote bookmark — the CLI's
/// `cli_util.rs:3385-3393` `has_tracked_remote_bookmarks`.
///
/// On a GIT-backed repo the default-ignored remote is excluded — jj-lib's reserved `git`
/// (`cli_util.rs:3372-3381` `default_ignored_remote_name`) — which is why a colocated `foo@git`
/// does NOT block `create foo` there. The exclusion is git-specific: on any other backend the
/// matcher is `StringMatcher::all()`, so nothing is ignored and a tracked `foo@git` DOES block.
fn has_tracked_remote_bookmarks(repo: &dyn jj_lib::repo::Repo, bookmark: &RefName) -> bool {
    let remote_matcher = ignored_remote_matcher(repo.store());
    // Bound to a local rather than returned as the tail expression: in edition 2021 a tail
    // expression's temporaries (here the iterator borrowing `remote_matcher`) are dropped
    // AFTER the block's locals, so `remote_matcher` would go first and the borrow check
    // would fail. The `let` ends those temporaries at the semicolon instead.
    let tracked = repo
        .view()
        .remote_bookmarks_matching(&StringMatcher::exact(bookmark.as_str()), &remote_matcher)
        .any(|(_, remote_ref)| remote_ref.is_tracked());
    tracked
}

/// The remotes a bookmark verb considers: all but the default-ignored one — jj-lib's reserved `git`
/// on a GIT-backed repo (`cli_util.rs:3465-3474` `default_ignored_remote_name` @ v0.46.0), every
/// remote otherwise. Shared by [`has_tracked_remote_bookmarks`] and [`rename`].
fn ignored_remote_matcher(store: &jj_lib::store::Store) -> StringMatcher {
    if jj_lib::git::get_git_backend(store).is_ok() {
        StringExpression::exact(jj_lib::git::REMOTE_NAME_FOR_LOCAL_GIT_REPO.as_str())
            .negated()
            .to_matcher()
    } else {
        StringMatcher::all()
    }
}

/// Renders a pattern parse failure the way the CLI's two lines do — its message plus its
/// `Caused by:` — as one string, and WITHOUT the terminal rendering in between.
///
/// `RevsetParseError`'s own `Display` is a multi-line pest caret diagram pointing into the
/// pattern text, which is terminal presentation the GUI replaces (ADR-0003) — flattening the
/// whole error would ship an ASCII drawing into `error.context`. But the kind ALONE is
/// useless: every malformed glob, regex and unknown prefix renders as the same "Invalid
/// string pattern". jj-lib keeps the part a user can act on — "error parsing glob '[':
/// unclosed character class; missing ']'", "Invalid string pattern kind bogus:" — behind
/// `#[source]`. So: the kind as the head, then the flattened `source()` chain.
fn describe_pattern_parse_error(e: &RevsetParseError) -> String {
    let mut reason = format!("failed to parse name pattern: {}", e.kind());
    if let Some(source) = std::error::Error::source(e) {
        reason.push_str(": ");
        reason.push_str(&flatten_chain(source));
    }
    reason
}

/// Parses each pattern and UNIONS them — the CLI's `revset_util.rs:364-384` @ v0.46.0
/// `parse_union_name_patterns`, minus its `ui` diagnostics printing.
///
/// A bare word is a GLOB, not an exact name (`jj_lib::revset`'s `expect_string_expression`
/// lowers an identifier or quoted string to `StringPattern::glob`) — though a glob without
/// metacharacters IS exact, which is what [`StringExpression::exact_strings`] then reports.
pub(crate) fn union_expression(patterns: &[String]) -> Result<StringExpression, MutateError> {
    union_patterns(patterns).map_err(MutateError::invalid)
}

/// [`union_expression`] with the refusal as its plain reason — `bookmark list`'s name and remote
/// patterns map it into [`crate::BookmarkError::InvalidInput`] (Story 9.19).
pub(crate) fn union_patterns(patterns: &[String]) -> Result<StringExpression, String> {
    // The CLI prints this sink's DIAGNOSTICS through `print_parse_diagnostics`
    // (`revset_util.rs:364-384` @ v0.46.0), a `ui.warning_*` site. Dropped here because jj-lib
    // 0.46 still emits no diagnostic for string patterns, so the sink always stays empty (the "Not
    // ported / out of scope" entry of `docs/rust-error-codes.md` § Warning Codes).
    let mut diagnostics = RevsetDiagnostics::new();
    let mut expressions = Vec::with_capacity(patterns.len());
    for pattern in patterns {
        let expression =
            parse_string_expression(&mut diagnostics, pattern).map_err(|e| describe_pattern_parse_error(&e))?;
        expressions.push(expression);
    }
    Ok(StringExpression::union_all(expressions))
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
/// (not a config key), so `None` resolves the workspace's working-copy commit, which the
/// pre-verb snapshot has just brought up to date (Story 9.26).
///
/// Both per-name preconditions run in ARGUMENT order and are FAIL-FAST, exactly as the CLI's
/// loop is (`create.rs:64-83` returns on the first offender, before its transaction opens):
/// a run whose second name already exists creates nothing at all, not even the first.
///
/// Description: `create bookmark {names} pointing to commit {id}` with `names` joined `", "`
/// in argument order and `id` the FULL commit hex (`create.rs:123-131`).
///
/// A target that is empty and undescribed (`Commit::is_discardable`) warns
/// `jj.bookmark_target_empty` after both guards passed (`create.rs:84-86`, Story 9.32).
///
/// Auto-tracking (`create.rs:88-111` @ v0.46.0): after that warning every remote's
/// `remotes.<r>.auto-track-bookmarks` ∪ `auto-track-created-bookmarks` matcher is parsed — all of
/// them, even when no name matches — and then, per name in argument order, the local target is
/// set and the name is tracked (`MutableRepo::track_remote_bookmark`, which merges the remote
/// target into the local one) on every remote, in name order, whose matcher accepts it and that
/// has a remote view in the pre-call view. When that view already holds the name, the call warns
/// `jj.bookmark_auto_track_existing` ("Auto-tracking bookmark that exists on the remote:
/// `name@remote`") first.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — `names` is empty, or a name is the empty string.
/// - [`MutateError::ChangeNotFound`] — `revision` is malformed, carried by no VISIBLE
///   commit (unknown or only-hidden), or divergent. Not to be confused with an ABSENT
///   `revision`, which is not an error at all: it applies the CLI's `-r` default `@`.
/// - [`MutateError::BookmarkExists`] — a name is already a local bookmark.
/// - [`MutateError::BookmarkTrackedRemoteExists`] — a name's local bookmark is absent but it
///   still has a tracked remote bookmark.
/// - [`MutateError::Config`] — a `remotes.<r>` entry is not a table of the known keys, or an
///   `auto-track-bookmarks` / `auto-track-created-bookmarks` value does not parse (the CLI's
///   ``Invalid `remotes.<r>.<field>`: …``); refused after both guards, nothing written.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn create(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    names: &[String],
    revision: Option<&ChangeId>,
) -> Result<MutationResult, MutateError> {
    let ref_names = validate_names(names)?;

    // ONE head load for the whole verb, as the CLI has. The revision has to resolve before
    // the transaction opens (CLI order, `create.rs:57-60`) because the op-log description
    // embeds the target's full commit hex — so this repo is resolved here and then handed
    // to `finish_or_no_op_at`, which starts its transaction from THIS view rather than
    // loading the head again. See that function's doc for why a second load would be wrong.
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let target = crate::op_support::resolve_or_wc(readonly.as_ref(), &workspace_name, revision)
        .map_err(|e| mutate::res(e, revision))?;
    let target_id = target.id().clone();

    let description = format!(
        "create bookmark {names} pointing to commit {id}",
        names = join_symbols(&ref_names),
        id = target_id.hex(),
    );
    // Read here, while `ctx` is not yet lent to the transaction, but refused only where the CLI
    // parses (`create.rs:89-91`): after both guards and the empty-target warning.
    let auto_track = crate::config::remote_auto_track_bookmarks_for_new_bookmarks(&ctx.config);
    let finished = finish_or_no_op_at(workspace, readonly, &description, ctx, |tx, sink| {
        // Both guards for EVERY name run before ANY write, and returning `Err` from here
        // drops the transaction unwritten — so a refusal creates nothing, not even the
        // names that precede the offender. The CLI reaches the same observable outcome by
        // running its loop before it opens a transaction at all (`create.rs:64-83`); the
        // difference is invisible from outside, and checking inside the transaction is what
        // lets both the guards and the writes see the single view loaded above.
        for name in &ref_names {
            let repo = tx.repo();
            if repo.view().get_local_bookmark(name).is_present() {
                return Err(MutateError::BookmarkExists {
                    name: name.as_str().to_owned(),
                    hints: vec!["Use `jj bookmark set` to update it.".to_owned()],
                });
            }
            if has_tracked_remote_bookmarks(repo, name) {
                return Err(MutateError::BookmarkTrackedRemoteExists {
                    name: name.as_str().to_owned(),
                });
            }
        }
        if pollster::block_on(target.is_discardable(tx.repo())).map_err(mutate::be)? {
            sink.push(WarningKind::BookmarkTargetEmpty, "Target revision is empty.");
        }
        let auto_track = auto_track.map_err(mutate::cfg)?;
        // The CLI reads "has a view" and "already on the remote" off the view BEFORE any write
        // (`create.rs:92`, `readonly_repo`), which is also the view the guards read.
        let base = tx.base_repo().clone();
        for name in &ref_names {
            tx.repo_mut()
                .set_local_bookmark_target(name, RefTarget::normal(target_id.clone()));
            for (remote, matcher) in &auto_track {
                if !matcher.is_match(name.as_str()) {
                    continue;
                }
                let Some(remote_view) = base.view().get_remote_view(remote) else {
                    continue;
                };
                let symbol = name.to_remote_symbol(remote);
                if remote_view.bookmarks.contains_key(name) {
                    sink.push(
                        WarningKind::BookmarkAutoTrackExisting,
                        format!("Auto-tracking bookmark that exists on the remote: {symbol}"),
                    );
                }
                pollster::block_on(tx.repo_mut().track_remote_bookmark(symbol)).map_err(mutate::be)?;
            }
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
/// An EXACT pattern — a bare name without glob metacharacters included — that names no local
/// bookmark warns `jj.bookmark_names_unmatched`, before the no-op check, exactly where the CLI
/// warns (`delete.rs:63`, Story 9.32).
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — `patterns` is empty, or a pattern does not parse.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn delete(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    patterns: &[String],
) -> Result<MutationResult, MutateError> {
    if patterns.is_empty() {
        return Err(MutateError::invalid(
            "bookmark delete requires at least one name pattern".to_owned(),
        ));
    }
    let expression = union_expression(patterns)?;
    let matcher = expression.to_matcher();

    // ONE head load, as in `create`: the description names the MATCHED bookmarks, so the
    // view has to be read before the transaction opens, and the transaction then starts
    // from THAT view — otherwise the description could name rows a second load no longer
    // has. `local_bookmarks_matching` iterates a `BTreeMap`, so the names come out
    // lexicographically, which is the CLI's own ordering here.
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
    let doomed: Vec<RefNameBuf> = readonly
        .view()
        .local_bookmarks_matching(&matcher)
        .map(|(name, _)| name.to_owned())
        .collect();
    // `warn_unmatched_local_bookmarks` (`bookmark/mod.rs:185-203`).
    let unmatched: Vec<String> = expression
        .exact_strings()
        .map(RefName::new)
        .filter(|name| readonly.view().get_local_bookmark(name).is_absent())
        .map(|name| name.as_symbol().to_string())
        .collect();
    if !unmatched.is_empty() {
        ctx.warnings.push(
            WarningKind::BookmarkNamesUnmatched,
            format!("No matching bookmarks for names: {}", unmatched.join(", ")),
        );
    }

    let description = format!("delete bookmark {}", join_symbols(&doomed));
    let finished = finish_or_no_op_at(workspace, readonly, &description, ctx, |tx, _sink| {
        for name in &doomed {
            tx.repo_mut().set_local_bookmark_target(name, RefTarget::absent());
        }
        Ok(())
    })?;
    Ok(finished.mutation)
}

/// The arguments of [`crate::Repo::bookmark_move`] (Story 9.19) — the CLI's `BookmarkMoveArgs`
/// (`bookmark/move.rs:44-70` @ v0.46.0).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct BookmarkMoveOptions {
    /// The local bookmarks to move, by EXACT name (the CLI's `exact:"…"` pattern, never its
    /// default glob). Empty means every local bookmark `from` selects.
    pub names: Vec<String>,
    /// The CLI's `--from`: revset TEXTS, unioned; only bookmarks with a target in them move.
    /// At least one of `names` and `from` must be given.
    pub from: Vec<String>,
    /// The CLI's `--to`; `None` is its default `@`.
    pub to: Option<ChangeId>,
    /// The CLI's `--allow-backwards`: also move a bookmark backwards or sideways.
    pub allow_backwards: bool,
}

/// The backwards refusal of one verb: `move`'s or `advance`'s text and hint.
struct BackwardsRefusal {
    /// The verb in "Refusing to {verb} bookmark backwards or sideways: {name}".
    verb: &'static str,
    /// The CLI's hint line, if any.
    hint: Option<&'static str>,
}

/// The local bookmarks a verb matched, in view order, with the target they would move to.
struct Matched {
    /// The target commit.
    target: Commit,
    /// The matched local bookmarks, in view (lexicographic) order.
    names: Vec<RefNameBuf>,
}

/// The exact-name expression of `names` — a union of `StringExpression::exact`, or every name
/// when `names` is empty.
fn exact_names(names: &[String]) -> StringExpression {
    if names.is_empty() {
        StringExpression::all()
    } else {
        StringExpression::union_all(
            names
                .iter()
                .map(|name| StringExpression::exact(name.as_str()))
                .collect(),
        )
    }
}

/// `warn_unmatched_local_bookmarks` (`bookmark/mod.rs:185-203` @ v0.46.0): one warning naming
/// every exact name with no local bookmark.
fn warn_unmatched_local(sink: &mut Warnings, view: &jj_lib::view::View, expression: &StringExpression) {
    let unmatched: Vec<String> = expression
        .exact_strings()
        .map(RefName::new)
        .filter(|name| view.get_local_bookmark(name).is_absent())
        .map(|name| name.as_symbol().to_string())
        .collect();
    if !unmatched.is_empty() {
        sink.push(
            WarningKind::BookmarkNamesUnmatched,
            format!("No matching bookmarks for names: {}", unmatched.join(", ")),
        );
    }
}

/// Whether any present add of `target` is in `revset` — the CLI's `is_source_ref`.
fn any_add_in(revset: &dyn Revset, target: &RefTarget) -> Result<bool, MutateError> {
    let contains = revset.containing_fn();
    for id in target.present_adds() {
        if pollster::block_on(contains(id)).map_err(mutate::be)? {
            return Ok(true);
        }
    }
    Ok(false)
}

/// The local bookmarks matching `matcher` whose target has a present add in `source` (all of
/// them when `source` is `None`), in view order.
fn matching_locals(
    repo: &ReadonlyRepo,
    matcher: &StringMatcher,
    source: Option<&dyn Revset>,
) -> Result<Vec<RefNameBuf>, MutateError> {
    let mut names = Vec::new();
    for (name, target) in repo.view().local_bookmarks_matching(matcher) {
        if source.map_or(Ok(true), |revset| any_add_in(revset, target))? {
            names.push(name.to_owned());
        }
    }
    Ok(names)
}

/// The shared tail of `move` and `advance` (`move.rs:114-178`, `advance.rs:149-198` @ v0.46.0):
/// drop the no-ops, finish without an operation when none is left, refuse the first backwards
/// move unless `backwards` is `None`, warn an empty target, then point every bookmark at it.
fn point_bookmarks(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    readonly: Arc<ReadonlyRepo>,
    matched: Matched,
    backwards: Option<&BackwardsRefusal>,
) -> Result<MutationResult, MutateError> {
    let Matched { target, names } = matched;
    let target_id = target.id().clone();
    let mut moves = Vec::with_capacity(names.len());
    for name in names {
        let plan = plan_bookmark_move(readonly.as_ref(), name.as_str(), &target_id)?;
        if plan != BookmarkMovePlan::NoOp {
            moves.push((name, plan));
        }
    }
    if let Some(refusal) = backwards {
        if let Some((name, _)) = moves.iter().find(|(_, plan)| *plan == BookmarkMovePlan::Backwards) {
            let reason = format!(
                "Refusing to {verb} bookmark backwards or sideways: {name}",
                verb = refusal.verb,
                name = name.as_symbol()
            );
            return Err(match refusal.hint {
                Some(hint) => MutateError::invalid_hinted(reason, hint),
                None => MutateError::invalid(reason),
            });
        }
    }
    let names: Vec<RefNameBuf> = moves.into_iter().map(|(name, _)| name).collect();
    let description = format!(
        "point bookmark {names} to commit {id}",
        names = join_symbols(&names),
        id = target_id.hex(),
    );
    let finished = finish_or_no_op_at(workspace, readonly, &description, ctx, |tx, sink| {
        if names.is_empty() {
            return Ok(());
        }
        if pollster::block_on(target.is_discardable(tx.repo())).map_err(mutate::be)? {
            sink.push(WarningKind::BookmarkTargetEmpty, "Target revision is empty.");
        }
        for name in &names {
            tx.repo_mut()
                .set_local_bookmark_target(name, RefTarget::normal(target_id.clone()));
        }
        Ok(())
    })?;
    Ok(finished.mutation)
}

/// Refuses clap's required `source` group of `bookmark move` (`move.rs:45` @ v0.46.0): at least
/// one of `names` and `from` — before the pre-verb snapshot ([`crate::Repo::bookmark_move`]), as
/// the CLI parses its arguments first.
///
/// # Errors
///
/// [`MutateError::InvalidInput`] when both are empty.
pub(crate) fn check_move_args(options: &BookmarkMoveOptions) -> Result<(), MutateError> {
    if options.names.is_empty() && options.from.is_empty() {
        return Err(MutateError::invalid(
            "bookmark move requires at least one name or --from revision".to_owned(),
        ));
    }
    Ok(())
}

/// Moves existing local bookmarks to one revision (Story 9.19) — the CLI's `jj bookmark move`
/// (`bookmark/move.rs:72-179` @ v0.46.0), names given EXACTLY.
///
/// The checks run in the CLI's order: at least one of `names`/`from` (clap's required group,
/// [`check_move_args`], before the snapshot), resolve `to` (default `@`), evaluate `from` (unioned, its diagnostics under "In revset
/// expression"), match the local bookmarks whose name is in `names` AND (with `from`) whose target
/// has a present add in it, warn the names that matched none (`jj.bookmark_names_unmatched`), drop
/// those already at the target — nothing left is a success writing NO operation (`new_op_id` is the
/// pre-call head, the CLI's "No bookmarks to update.") — refuse the first backwards or sideways move
/// in view order unless `allow_backwards`, warn an empty target (`jj.bookmark_target_empty`), and
/// point every matched bookmark at the target as a NORMAL target, so a conflicted one is resolved.
///
/// Description: `point bookmark {names} to commit {id}` with the moved names in view order and the
/// full commit hex (`move.rs:164-176`).
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — neither `names` nor `from` is given; or a backwards move
///   without `allow_backwards` ("Refusing to move bookmark backwards or sideways: {name}", hint
///   "Use --allow-backwards to allow it.").
/// - [`MutateError::ChangeNotFound`] / [`MutateError::RevsetResolutionError`] — `to` does not
///   resolve (as [`create`]'s `revision`), or there is no `@` for its default.
/// - [`MutateError::RevsetParseError`] / [`MutateError::RevsetResolutionError`] — a `from` text.
/// - [`MutateError::Config`] — the revset aliases do not load.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn r#move(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    options: &BookmarkMoveOptions,
) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let to = options.to.as_ref();
    let target =
        crate::op_support::resolve_or_wc(readonly.as_ref(), &workspace_name, to).map_err(|e| mutate::res(e, to))?;
    let source = if options.from.is_empty() {
        None
    } else {
        let parse_config = crate::revset::revset_config(&ctx.config, &mut ctx.warnings).map_err(mutate::cfg)?;
        let expression =
            crate::revset::parse_union_diagnosed(workspace, &parse_config, &options.from, &mut ctx.warnings)
                .map_err(mutate::rev)?;
        Some(crate::revset::evaluate_revset(readonly.as_ref(), &expression).map_err(mutate::rev)?)
    };
    let expression = exact_names(&options.names);
    let names = matching_locals(&readonly, &expression.to_matcher(), source.as_deref())?;
    drop(source);
    warn_unmatched_local(&mut ctx.warnings, readonly.view(), &expression);
    let refusal = BackwardsRefusal {
        verb: "move",
        hint: Some("Use --allow-backwards to allow it."),
    };
    let backwards = (!options.allow_backwards).then_some(&refusal);
    point_bookmarks(workspace, ctx, readonly, Matched { target, names }, backwards)
}

/// The hint the CLI puts on every failure to resolve `bookmark advance`'s DEFAULT target
/// (`bookmark/advance.rs:90-99` @ v0.46.0).
const ADVANCE_TO_HINT: &str =
    "`revsets.bookmark-advance-to` controls the default target. You can also specify a specific target with `--to`.";

/// Adds [`ADVANCE_TO_HINT`] to a parse or resolution refusal of the default target.
fn with_advance_hint(mut e: MutateError) -> MutateError {
    if let MutateError::RevsetParseError { hints, .. } | MutateError::RevsetResolutionError { hints, .. } = &mut e {
        hints.push(ADVANCE_TO_HINT.to_owned());
    }
    e
}

/// `bookmark advance`'s target: `to`, or `revsets.bookmark-advance-to` resolved to exactly one
/// commit, every parse or resolution refusal of the latter carrying [`ADVANCE_TO_HINT`].
fn advance_target(
    workspace: &Workspace,
    ctx: &mut VerbContext,
    readonly: &ReadonlyRepo,
    to: Option<&ChangeId>,
) -> Result<Commit, MutateError> {
    if to.is_some() {
        return crate::op_support::resolve_or_wc(readonly, workspace.workspace_name(), to)
            .map_err(|e| mutate::res(e, to));
    }
    let text = crate::config::revsets_bookmark_advance_to(&ctx.config).map_err(mutate::cfg)?;
    let parse_config = crate::revset::revset_config(&ctx.config, &mut ctx.warnings).map_err(mutate::cfg)?;
    let expression = crate::revset::parse_diagnosed(
        workspace,
        &parse_config,
        (&text, crate::revset::IN_REVSET_EXPRESSION),
        &mut ctx.warnings,
    )
    .map_err(mutate::rev)
    .map_err(with_advance_hint)?;
    crate::push::single_commit(readonly, &expression, &text).map_err(with_advance_hint)
}

/// Advances the closest bookmarks to a revision (Story 9.19) — the CLI's `jj bookmark advance`
/// (`bookmark/advance.rs:68-199` @ v0.46.0), names given EXACTLY.
///
/// The target is `to`, or `revsets.bookmark-advance-to` (default `@`) resolved to exactly one
/// commit. With `names`, those local bookmarks are the candidates (unmatched names warn
/// `jj.bookmark_names_unmatched`); without, every local bookmark with a present add in
/// `revsets.bookmark-advance-from` (default `heads(::to & bookmarks())`, parsed with `to` bound to
/// the target's commit hex, its diagnostics under "In revsets.bookmark-advance-from"). Then as
/// [`r#move`] without `allow_backwards`: no-ops dropped (none left = no operation), the first
/// backwards candidate refused, an empty target warned, every candidate pointed at the target.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — a backwards or sideways candidate ("Refusing to advance
///   bookmark backwards or sideways: {name}", no hint).
/// - [`MutateError::ChangeNotFound`] — `to` does not resolve.
/// - [`MutateError::RevsetParseError`] / [`MutateError::RevsetResolutionError`] — the default
///   target does not parse, or does not resolve to exactly one commit (both with the CLI's hint
///   "`revsets.bookmark-advance-to` controls the default target. …"); or the from revset.
/// - [`MutateError::Config`] — a `revsets.bookmark-advance-*` value is not a string, or the revset
///   aliases do not load.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn advance(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    names: &[String],
    to: Option<&ChangeId>,
) -> Result<MutationResult, MutateError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
    let target = advance_target(workspace, ctx, &readonly, to)?;
    let names = if names.is_empty() {
        let text = crate::config::revsets_bookmark_advance_from(&ctx.config).map_err(mutate::cfg)?;
        let parse_config = crate::revset::revset_config(&ctx.config, &mut ctx.warnings).map_err(mutate::cfg)?;
        let hex = target.id().hex();
        let expression = crate::revset::parse_diagnosed_with(
            workspace,
            &parse_config,
            (&text, "In revsets.bookmark-advance-from"),
            &[("to", &hex)],
            &mut ctx.warnings,
        )
        .map_err(mutate::rev)?;
        let source = crate::revset::evaluate_revset(readonly.as_ref(), &expression).map_err(mutate::rev)?;
        matching_locals(&readonly, &StringMatcher::all(), Some(source.as_ref()))?
    } else {
        let expression = exact_names(names);
        let matched = matching_locals(&readonly, &expression.to_matcher(), None)?;
        warn_unmatched_local(&mut ctx.warnings, readonly.view(), &expression);
        matched
    };
    let refusal = BackwardsRefusal {
        verb: "advance",
        hint: None,
    };
    point_bookmarks(workspace, ctx, readonly, Matched { target, names }, Some(&refusal))
}

/// Refuses an EMPTY rename name — the one refusal `parse_bookmark_name` (`rename.rs:37-43` @
/// v0.46.0, clap's `value_parser`) makes in every spelling — before the pre-verb snapshot
/// ([`crate::Repo::bookmark_rename`]), as the CLI parses its arguments first.
///
/// # Errors
///
/// [`MutateError::InvalidInput`] when `old` or `new` is empty.
pub(crate) fn check_rename_args(old: &str, new: &str) -> Result<(), MutateError> {
    if old.is_empty() || new.is_empty() {
        return Err(MutateError::invalid("bookmark name must not be empty".to_owned()));
    }
    Ok(())
}

/// What a rename transaction found that the CLI warns about only after its finish.
struct RenameFacts {
    /// The old name had a present, tracked remote bookmark (`rename.rs:96-98`).
    tracked_present_old_remotes: bool,
}

/// Renames a local bookmark (Story 9.19) — the CLI's `jj bookmark rename` (`bookmark/rename.rs:
/// 49-201` @ v0.46.0). `old` and `new` are DECODED names, as [`create`]'s are.
///
/// The checks run in the CLI's order: "No such bookmark: {old}"; without `overwrite_existing` a
/// present `new` refuses — so `old == new` without it refuses too; `old == new` is then a success
/// writing NO operation. The rename untracks the overwritten name's tracked remotes (with
/// `overwrite_existing`), points `new` at `old`'s target, makes `old` absent, and moves the
/// tracking per remote: a tracked `old@r` makes `new@r` tracked (jj-lib merges its target), unless
/// `new@r` exists untracked — then the tracking is dropped with `jj.bookmark_rename_remote_exists`.
/// With `overwrite_existing`, a present tracked `new@r` whose `old@r` was untracked warns
/// `jj.bookmark_tracking_dropped`. After the finish, present tracked remotes of `old` warn
/// `jj.bookmark_remotes_not_renamed`, and (without `overwrite_existing`) present tracked remotes
/// of `new` warn `jj.bookmark_tracked_remotes_exist`. On a GIT-backed repo the remote `git` is
/// left out of all of it, as in the CLI.
///
/// Description: `rename bookmark {old} to {new}`, both as revset symbols (`rename.rs:156-163`).
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — `old` is not a local bookmark ("No such
///   bookmark: {old}").
/// - [`MutateError::BookmarkExists`] — `new` is a local bookmark and `overwrite_existing` is off.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn rename(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    old: &str,
    new: &str,
    overwrite_existing: bool,
) -> Result<MutationResult, MutateError> {
    let (old, new) = (RefName::new(old), RefName::new(new));
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
    let base = Arc::clone(&readonly);
    let base_view = base.view();
    let ref_target = base_view.get_local_bookmark(old).clone();
    if ref_target.is_absent() {
        return Err(MutateError::invalid(format!("No such bookmark: {}", old.as_symbol())));
    }
    if !overwrite_existing && base_view.get_local_bookmark(new).is_present() {
        return Err(MutateError::BookmarkExists {
            name: new.as_str().to_owned(),
            hints: vec![],
        });
    }
    let description = format!("rename bookmark {} to {}", old.as_symbol(), new.as_symbol());
    if old == new {
        return Ok(finish_or_no_op_at(workspace, readonly, &description, ctx, |_, _| Ok(()))?.mutation);
    }
    let remote_matcher = ignored_remote_matcher(base.store());
    let finished = finish_or_no_op_at(workspace, readonly, &description, ctx, |tx, sink| {
        if overwrite_existing {
            for (symbol, remote_ref) in base_view.remote_bookmarks_matching(&StringMatcher::exact(new), &remote_matcher)
            {
                if remote_ref.is_tracked() {
                    tx.repo_mut()
                        .untrack_remote_bookmark(new.to_remote_symbol(symbol.remote));
                }
            }
        }
        tx.repo_mut().set_local_bookmark_target(new, ref_target);
        tx.repo_mut().set_local_bookmark_target(old, RefTarget::absent());
        let mut facts = RenameFacts {
            tracked_present_old_remotes: false,
        };
        for (symbol, remote_ref) in base_view.remote_bookmarks_matching(&StringMatcher::exact(old), &remote_matcher) {
            if !remote_ref.is_tracked() {
                continue;
            }
            facts.tracked_present_old_remotes |= remote_ref.is_present();
            let new_remote = new.to_remote_symbol(symbol.remote);
            let existing = tx.repo().view().get_remote_bookmark(new_remote);
            if existing.is_present() && !existing.is_tracked() {
                sink.push(
                    WarningKind::BookmarkRenameRemoteExists,
                    format!(
                        "The renamed bookmark already exists on the remote '{}', tracking state was dropped.",
                        new_remote.remote.as_symbol()
                    ),
                );
                continue;
            }
            pollster::block_on(tx.repo_mut().track_remote_bookmark(new_remote)).map_err(mutate::be)?;
        }
        if overwrite_existing {
            for (symbol, remote_ref) in base_view.remote_bookmarks_matching(&StringMatcher::exact(new), &remote_matcher)
            {
                if !remote_ref.is_tracked() || !remote_ref.is_present() {
                    continue;
                }
                if base_view
                    .get_remote_bookmark(old.to_remote_symbol(symbol.remote))
                    .is_tracked()
                {
                    continue;
                }
                sink.push(
                    WarningKind::BookmarkTrackingDropped,
                    format!(
                        "Tracking of remote bookmark {}@{} was dropped.",
                        new.as_symbol(),
                        symbol.remote.as_symbol()
                    ),
                );
            }
        }
        Ok(facts)
    })?;
    if finished.value.tracked_present_old_remotes {
        ctx.warnings.push(
            WarningKind::BookmarkRemotesNotRenamed,
            format!(
                "Tracked remote bookmarks for bookmark {} were not renamed.",
                old.as_symbol()
            ),
        );
    }
    if !overwrite_existing
        && base_view
            .remote_bookmarks_matching(&StringMatcher::exact(new), &remote_matcher)
            .any(|(_, remote_ref)| remote_ref.is_tracked() && remote_ref.is_present())
    {
        ctx.warnings.push(
            WarningKind::BookmarkTrackedRemotesExist,
            format!("Tracked remote bookmarks for bookmark {} exist.", new.as_symbol()),
        );
    }
    Ok(finished.mutation)
}

/// What `jj bookmark move <name> --to <target>` would do to the one LOCAL bookmark named exactly
/// `name` (Story 9.31) — the plan of `cmd_bookmark_move` (`cli/src/commands/bookmark/move.rs` @
/// v0.46.0) for an exact name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BookmarkMovePlan {
    /// Nothing to move: no local bookmark has that name, or it already points at the target (the
    /// CLI excludes such no-op matches, then says "No bookmarks to update.").
    NoOp,
    /// The move is a fast-forward: allowed as is.
    FastForward,
    /// The move goes backwards or sideways: the CLI refuses it ("Refusing to move bookmark
    /// backwards or sideways: <name>") unless `--allow-backwards` is given.
    Backwards,
}

/// Plans moving the local bookmark `name` to `target`, an already-resolved commit — the CLI
/// resolves `--to` before it matches names. A bookmark already at `target`, or no local bookmark
/// of that exact name, is [`BookmarkMovePlan::NoOp`]; otherwise the CLI's `is_fast_forward`
/// (`bookmark/mod.rs:165-182`) decides between [`BookmarkMovePlan::FastForward`] and
/// [`BookmarkMovePlan::Backwards`]. Reads the view of `repo` only. `drop_actions`' bookmark row
/// and the `bookmark move` / `advance` verbs ([`r#move`], [`advance`], Story 9.19) call this one
/// fn, so a row and the verb agree by construction.
///
/// # Errors
///
/// - [`MutateError::Backend`] — an index read failed.
pub(crate) fn plan_bookmark_move(
    repo: &dyn jj_lib::repo::Repo,
    name: &str,
    target: &jj_lib::backend::CommitId,
) -> Result<BookmarkMovePlan, MutateError> {
    let old = repo.view().get_local_bookmark(RefName::new(name));
    if old.is_absent() || old.as_normal() == Some(target) {
        return Ok(BookmarkMovePlan::NoOp);
    }
    Ok(if is_fast_forward(repo, old, target)? {
        BookmarkMovePlan::FastForward
    } else {
        BookmarkMovePlan::Backwards
    })
}

/// The CLI's `is_fast_forward` (`bookmark/mod.rs:165-182` @ v0.46.0): some present add of the old
/// target is an ancestor of the new one — "any", not "all", so a conflicted bookmark can be
/// resolved by moving it to a descendant of one side. An absent old target is a fast-forward.
fn is_fast_forward(
    repo: &dyn jj_lib::repo::Repo,
    old_target: &RefTarget,
    new_target_id: &jj_lib::backend::CommitId,
) -> Result<bool, MutateError> {
    if !old_target.is_present() {
        return Ok(true);
    }
    for old in old_target.present_adds() {
        if pollster::block_on(repo.index().is_ancestor(old, new_target_id)).map_err(mutate::be)? {
            return Ok(true);
        }
    }
    Ok(false)
}

#[cfg(test)]
mod tests {
    use jj_lib::str_util::StringMatcher;

    use super::{join_symbols, union_expression, validate_names};

    /// The matcher `delete` filters with.
    fn union_matcher(patterns: &[String]) -> Result<StringMatcher, MutateError> {
        union_expression(patterns).map(|expression| expression.to_matcher())
    }
    use crate::MutateError;

    /// The two arity refusals the CLI makes at clap level, which have to become wire-level
    /// refusals here (a GUI has no clap): no names at all, and an empty name.
    #[test]
    fn validate_names_refuses_the_two_clap_level_arities() {
        let empty_list = validate_names(&[]).expect_err("clap's required = true");
        assert!(
            matches!(&empty_list, MutateError::InvalidInput { reason, .. } if reason.contains("at least one name")),
            "unexpected error: {empty_list:?}"
        );
        let empty_name = validate_names(&["ok".to_owned(), String::new()]).expect_err("parse_symbol rejects it");
        assert!(
            matches!(&empty_name, MutateError::InvalidInput { reason, .. } if reason.contains("must not be empty")),
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

    /// A malformed pattern is the caller's problem, and jj-lib's ACTIONABLE reason is
    /// forwarded — not merely its kind, which is the same opaque "Invalid string pattern"
    /// for every bad glob, bad regex and unknown prefix. The detail lives behind
    /// `#[source]`, so these assertions name the offending construct: a `kind()`-only
    /// rendering, or one that dropped the chain, would fail here.
    #[test]
    fn union_matcher_forwards_jj_libs_own_reason_for_a_malformed_pattern() {
        let bad_glob = union_matcher(&["glob:\"[\"".to_owned()]).expect_err("an unterminated glob class");
        assert!(
            matches!(
                &bad_glob,
                MutateError::InvalidInput { reason, .. }
                    if reason == "failed to parse name pattern: Invalid string pattern: \
                                  error parsing glob '[': unclosed character class; missing ']'"
            ),
            "unexpected error: {bad_glob:?}"
        );

        let bad_kind = union_matcher(&["bogus:foo".to_owned()]).expect_err("no such pattern kind");
        assert!(
            matches!(
                &bad_kind,
                MutateError::InvalidInput { reason, .. }
                    if reason == "failed to parse name pattern: Invalid string pattern: \
                                  Invalid string pattern kind `bogus:`"
            ),
            "unexpected error: {bad_kind:?}"
        );

        // A SYNTAX error carries no source, so the kind is the whole reason — and the
        // renderer must not append a stray separator for an absent chain.
        let bad_syntax = union_matcher(&["foo bar baz".to_owned()]).expect_err("trailing garbage");
        assert!(
            matches!(
                &bad_syntax,
                MutateError::InvalidInput { reason, .. } if reason == "failed to parse name pattern: Syntax error"
            ),
            "unexpected error: {bad_syntax:?}"
        );

        // What must NOT survive: jj-lib's pest caret diagram, which is terminal rendering.
        assert!(
            !bad_glob.to_string().contains("-->"),
            "the pest caret diagram is terminal UX and must not reach error.context"
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

    /// The `~` / `&` / `|` operators are advertised on every doc surface this story
    /// touches (the schema, the C header, `Repo::bookmark_delete`, and three Dart files),
    /// so they need a witness: they work because a pattern is a jj string EXPRESSION, not
    /// a bare `StringPattern`, and losing that would break the advertised syntax silently
    /// while every bare-glob test stayed green.
    #[test]
    fn union_matcher_supports_the_advertised_pattern_operators() {
        let negated = union_matcher(&["glob:\"foo-*\" ~ exact:\"foo-skip\"".to_owned()]).expect("a negation parses");
        assert!(negated.is_match("foo-1"));
        assert!(!negated.is_match("foo-skip"), "`~` must subtract the right operand");
        assert!(!negated.is_match("bar"));

        let intersected = union_matcher(&["glob:\"foo-*\" & substring:\"1\"".to_owned()]).expect("an `&` parses");
        assert!(intersected.is_match("foo-1"));
        assert!(!intersected.is_match("foo-2"), "`&` must require BOTH operands");

        let alternation = union_matcher(&["exact:\"a\" | exact:\"b\"".to_owned()]).expect("a `|` parses");
        assert!(alternation.is_match("a") && alternation.is_match("b"));
        assert!(!alternation.is_match("c"));
    }

    /// Story 9.31: the CLI's `is_fast_forward` counts an ABSENT old target as a fast-forward —
    /// unreachable through `plan_bookmark_move`, which answers no-op for a missing bookmark first,
    /// so witnessed here directly — and a commit as its own ancestor.
    #[test]
    fn is_fast_forward_counts_an_absent_old_target_as_a_fast_forward() {
        use jj_lib::op_store::RefTarget;
        test_helpers::pin_test_env();
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let repo = crate::Repo::init(&crate::InitOptions {
            path: tmp.path().to_owned(),
            ..Default::default()
        })
        .result
        .expect("init");
        let head = pollster::block_on(repo.workspace().repo_loader().load_at_head()).expect("head");
        let root = jj_lib::repo::Repo::store(head.as_ref()).root_commit_id().clone();
        assert!(super::is_fast_forward(head.as_ref(), &RefTarget::absent(), &root).expect("absent"));
        assert!(super::is_fast_forward(head.as_ref(), &RefTarget::normal(root.clone()), &root).expect("itself"));
    }
}
