// SPDX-License-Identifier: MIT

//! `tag_ops.rs` — the tag MUTATIONS (Story 9.59): `tag set`, `delete`, `track` and `untrack`,
//! ports of `cli/src/commands/tag/{mod,set,delete,track,untrack}.rs` @ v0.47.0.
//!
//! The verbs have the shape of the bookmark verbs ([`crate::bookmark_ops`]) and share their
//! argument parsing: `set` takes DECODED names, `delete` pass-through string patterns (a bare one a
//! GLOB), `track` / `untrack` the CLI's `TAG[@REMOTE]` texts and `--remote` patterns. They differ
//! where the CLI's tag commands differ: `set` has no auto-tracking, no fast-forward rule and no
//! tracked-remote guard, and there is no `tag forget` in jj 0.47.
//!
//! Each verb opens one jj-lib transaction through [`finish_or_no_op_at`] and commits with the
//! CLI's op-log description; a verb that changes nothing writes no operation and returns the
//! pre-call head.
//!
//! # Deliberate divergences from the CLI
//!
//! - **No terminal UX.** "Created/Moved N tags …", "No tags to delete.", "Deleted N tags." and
//!   "Started/Stopped tracking N remote tags." are dropped (an unchanged `new_op_id` says nothing
//!   happened; [`crate::Repo::list_tags`] re-reads the rows). The warnings ride the call's
//!   warnings: `jj.tag_target_empty`, `jj.tag_names_unmatched`, `jj.remote_tags_unmatched`,
//!   `jj.tag_remotes_unmatched`, `jj.tag_already_tracked`, `jj.tag_git_tracking_untrack` and
//!   `jj.tag_not_tracked`.

use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::RefTarget;
use jj_lib::ref_name::{RefName, RefNameBuf, RemoteRefSymbolBuf};
use jj_lib::repo::Repo as _;
use jj_lib::str_util::{StringExpression, StringMatcher};
use jj_lib::view::View;
use jj_lib::workspace::Workspace;

use crate::bookmark_ops::{
    check_names_given, default_ignored_remote, join_symbols, parse_names_or_symbols, refuse_mixed_syntax,
    union_expression, validate_names, warn_unmatched_remotes, MatchedRemote, Tracking,
};
use crate::mutate::{self, finish_or_no_op_at, MutateError, MutationResult};
use crate::snapshot::VerbContext;
use crate::warning::{WarningKind, Warnings};
use crate::ChangeId;

/// Refuses clap's `required = true` and an EMPTY name of `tag set` (its `value_parser` is
/// `parse_tag_name` = `parse_symbol`, `tag/set.rs:48-50` @ v0.47.0) — before the pre-verb snapshot.
///
/// # Errors
///
/// [`MutateError::InvalidInput`] when `names` is empty or a name is the empty string.
pub(crate) fn check_set_args(names: &[String]) -> Result<(), MutateError> {
    validate_names("tag", "set", names).map(drop)
}

/// Refuses clap's `required = true` of `tag delete`, `track` and `untrack` (`verb`) — before the
/// pre-verb snapshot.
///
/// # Errors
///
/// [`MutateError::InvalidInput`] when `names` is empty.
pub(crate) fn check_names(verb: &str, names: &[String]) -> Result<(), MutateError> {
    check_names_given("tag", verb, names)
}

/// Creates or moves local tags to one revision by name — the CLI's `jj tag set`
/// (`tag/set.rs:54-117` @ v0.47.0). `names` are DECODED names.
///
/// `revision` is the CLI's `-r` (`None` = its default `@`). Per name in ARGUMENT order, fail-fast:
/// a present local tag without `allow_move` refuses before anything is written. Then an empty,
/// undescribed target warns `jj.tag_target_empty`, and every name gets the target as a NORMAL
/// target. The CLI does not auto-track tags. A run that changes nothing writes NO operation.
///
/// Description: `set tag {names} to commit {id}`, names in argument order, full hex.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — `names` is empty or holds an empty name; or a name is a local
///   tag already and `allow_move` is off ("Refusing to move tag: {name}", hint "Use --allow-move to
///   update existing tags.").
/// - [`MutateError::ChangeNotFound`] / [`MutateError::RevsetResolutionError`] — `revision` does not
///   resolve, or there is no `@` for its default.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn set(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    names: &[String],
    revision: Option<&ChangeId>,
    allow_move: bool,
) -> Result<MutationResult, MutateError> {
    let ref_names = validate_names("tag", "set", names)?;
    let readonly = crate::snapshot::reload_head(workspace).map_err(mutate::be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let target = crate::op_support::resolve_or_wc(
        readonly.as_ref(),
        &workspace_name,
        &ctx.template_startup.id_prefix_context(),
        revision,
    )
    .map_err(|e| mutate::res(e, revision))?;
    let target_id = target.id().clone();
    for name in &ref_names {
        if readonly.view().get_local_tag(name).is_present() && !allow_move {
            return Err(MutateError::invalid_hinted(
                format!("Refusing to move tag: {}", name.as_symbol()),
                "Use --allow-move to update existing tags.",
            ));
        }
    }
    if pollster::block_on(target.is_discardable(readonly.index())).map_err(mutate::be)? {
        ctx.warnings
            .push(WarningKind::TagTargetEmpty, "Target revision is empty.");
    }
    let description = format!(
        "set tag {names} to commit {id}",
        names = join_symbols(&ref_names),
        id = target_id.hex(),
    );
    let finished = finish_or_no_op_at(workspace, readonly, &description, ctx, |tx, _sink| {
        for name in &ref_names {
            tx.repo_mut()
                .set_local_tag_target(name, RefTarget::normal(target_id.clone()));
        }
        Ok(())
    })?;
    Ok(finished.mutation)
}

/// Deletes the local tags matching `patterns` — the CLI's `jj tag delete` (`tag/delete.rs:43-75` @
/// v0.47.0).
///
/// `patterns` are pass-through string patterns, unioned, a bare one a GLOB. An exact name with no
/// local tag warns `jj.tag_names_unmatched`; matching nothing writes NO operation. A tracked
/// `name@remote` stays: the local tag becomes absent, the "deleted" state a push sends.
///
/// Description: `delete tag {names}`, the matched names in view order.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — a pattern does not parse.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn delete(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    patterns: &[String],
) -> Result<MutationResult, MutateError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(mutate::be)?;
    let expression = union_expression(patterns)?;
    let doomed: Vec<RefNameBuf> = readonly
        .view()
        .local_tags_matching(&expression.to_matcher())
        .map(|(name, _)| name.to_owned())
        .collect();
    warn_unmatched_local(&mut ctx.warnings, readonly.view(), &expression);

    let description = format!("delete tag {}", join_symbols(&doomed));
    let finished = finish_or_no_op_at(workspace, readonly, &description, ctx, |tx, _sink| {
        for name in &doomed {
            tx.repo_mut().set_local_tag_target(name, RefTarget::absent());
        }
        Ok(())
    })?;
    Ok(finished.mutation)
}

/// The CLI's `warn_unmatched_local_tags` (`tag/mod.rs:122-138` @ v0.47.0): one warning naming every
/// exact name with no local tag.
fn warn_unmatched_local(sink: &mut Warnings, view: &View, expression: &StringExpression) {
    warn_unmatched_names(sink, expression, |name| view.get_local_tag(name).is_absent());
}

/// The CLI's `warn_unmatched_local_or_remote_tags` (`tag/mod.rs:140-164` @ v0.47.0): one warning
/// naming every exact name with neither a local tag nor a tag on any remote.
fn warn_unmatched_local_or_remote(sink: &mut Warnings, view: &View, expression: &StringExpression) {
    warn_unmatched_names(sink, expression, |name| {
        view.get_local_tag(name).is_absent()
            && view
                .remote_views()
                .all(|(_, remote_view)| !remote_view.tags.contains_key(name))
    });
}

/// One `jj.tag_names_unmatched` warning naming every exact name of `expression` `unmatched` keeps.
fn warn_unmatched_names(sink: &mut Warnings, expression: &StringExpression, unmatched: impl Fn(&RefName) -> bool) {
    let names: Vec<String> = expression
        .exact_strings()
        .map(RefName::new)
        .filter(|name| unmatched(name))
        .map(|name| name.as_symbol().to_string())
        .collect();
    if !names.is_empty() {
        sink.push(
            WarningKind::TagNamesUnmatched,
            format!("No matching tags for names: {}", names.join(", ")),
        );
    }
}

/// The CLI's `resolve_trackable_remote_tags` (`tag/mod.rs:75-104` @ v0.47.0): a symbol is trackable
/// when its remote tag is present, or its local tag is present and its remote has a view; sorted
/// and deduplicated. The others warn `jj.remote_tags_unmatched`.
fn resolve_trackable(sink: &mut Warnings, view: &View, symbols: &[RemoteRefSymbolBuf]) -> Vec<MatchedRemote> {
    let mut trackable = Vec::new();
    let mut unmatched = Vec::new();
    for symbol in symbols {
        let symbol = symbol.as_ref();
        let remote_ref = view.get_remote_tag(symbol);
        if remote_ref.is_present()
            || (view.get_local_tag(symbol.name).is_present() && view.get_remote_view(symbol.remote).is_some())
        {
            trackable.push((symbol.to_owned(), remote_ref.is_tracked()));
        } else {
            unmatched.push(symbol.to_string());
        }
    }
    trackable.sort_unstable_by(|(a, _), (b, _)| a.cmp(b));
    trackable.dedup_by(|(a, _), (b, _)| a == b);
    if !unmatched.is_empty() {
        sink.push(
            WarningKind::RemoteTagsUnmatched,
            format!("No matching remote tags for names: {}", unmatched.join(", ")),
        );
    }
    trackable
}

/// The CLI's `trackable_remote_tags_matching` (`tag/mod.rs:106-121` @ v0.47.0): the present-or-
/// tracked remote tags matching both matchers, then — per matching remote view — every matching
/// LOCAL name that view lacks, as an absent (so untracked) `ABSENT_REMOTE_REF`.
fn trackable_matching(view: &View, tags: &StringMatcher, remotes: &StringMatcher) -> Vec<MatchedRemote> {
    let present = view
        .remote_tags_matching(tags, remotes)
        .map(|(symbol, remote_ref)| (symbol.to_owned(), remote_ref.is_tracked()));
    let absent = view.remote_views_matching(remotes).flat_map(|(remote, remote_view)| {
        view.local_tags_matching(tags)
            .filter(|(name, _)| !remote_view.tags.contains_key(*name))
            .map(move |(name, _)| (name.to_remote_symbol(remote).to_owned(), false))
    });
    present.chain(absent).collect()
}

/// Starts or stops tracking remote tags — the CLI's `jj tag track` / `untrack`
/// (`tag/track.rs:68-135`, `tag/untrack.rs:68-142` @ v0.47.0), by `tracking`.
///
/// `names` are `TAG[@REMOTE]` texts passed through: a `name@remote` symbol names one remote tag
/// exactly, anything else is a string pattern (a bare one a GLOB). `remotes` are remote-name
/// patterns (the CLI's `--remote`; empty = not given). Patterns and symbols do not mix, and
/// `remotes` do not go with symbols.
///
/// Symbols resolve to the trackable remote tags (unmatched ones warn `jj.remote_tags_unmatched`);
/// patterns match every remote tag of the `remotes` (by default every remote but `git` on a
/// Git-backed repo where `git` has a view) plus the matching local names a remote lacks, then warn
/// unmatched exact names (`jj.tag_names_unmatched`) and remotes (`jj.tag_remotes_unmatched`).
/// `Track` warns already-tracked refs (`jj.tag_already_tracked`) and tracks the rest; `Untrack`
/// warns the ignored remote's refs (`jj.tag_git_tracking_untrack`) and untracked ones
/// (`jj.tag_not_tracked`) and untracks the rest. Nothing left writes NO operation.
///
/// Description: `track remote tag {symbols}` / `untrack remote tag {symbols}`.
///
/// # Errors
///
/// - [`MutateError::InvalidInput`] — a name or remote does not parse, or patterns and symbols are
///   mixed, or `remotes` come with symbols.
/// - [`MutateError::Backend`] — an underlying jj-lib failure.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn track_or_untrack(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    names: &[String],
    remotes: &[String],
    tracking: Tracking,
) -> Result<MutationResult, MutateError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(mutate::be)?;
    let view = readonly.view();
    // Suppresses the unmatched-remotes warning for the default-ignored remote.
    let ignored = default_ignored_remote(readonly.store()).filter(|remote| view.get_remote_view(remote).is_some());
    let (patterns, symbols) = parse_names_or_symbols(names)?;
    refuse_mixed_syntax("tag", &patterns, &symbols, remotes)?;
    let matched = if symbols.is_empty() {
        let tag_expr = StringExpression::union_all(patterns);
        let remote_expr = if !remotes.is_empty() {
            union_expression(remotes)?
        } else if let Some(remote) = ignored {
            StringExpression::exact(remote.as_str()).negated()
        } else {
            StringExpression::all()
        };
        let matched = trackable_matching(view, &tag_expr.to_matcher(), &remote_expr.to_matcher());
        warn_unmatched_local_or_remote(&mut ctx.warnings, view, &tag_expr);
        warn_unmatched_remotes(WarningKind::TagRemotesUnmatched, &mut ctx.warnings, view, &remote_expr);
        matched
    } else {
        resolve_trackable(&mut ctx.warnings, view, &symbols)
    };

    let mut chosen = Vec::new();
    for (symbol, tracked) in matched {
        let skip = match tracking {
            Tracking::Track if tracked => Some((WarningKind::TagAlreadyTracked, "Remote tag already tracked")),
            Tracking::Untrack if ignored == Some(symbol.as_ref().remote) => Some((
                WarningKind::TagGitTrackingUntrack,
                "Git-tracking tag cannot be untracked",
            )),
            Tracking::Untrack if !tracked => Some((WarningKind::TagNotTracked, "Remote tag not tracked yet")),
            Tracking::Track | Tracking::Untrack => None,
        };
        match skip {
            Some((kind, text)) => ctx.warnings.push(kind, format!("{text}: {symbol}")),
            None => chosen.push(symbol),
        }
    }
    let verb = match tracking {
        Tracking::Track => "track",
        Tracking::Untrack => "untrack",
    };
    let joined: Vec<String> = chosen.iter().map(ToString::to_string).collect();
    let description = format!("{verb} remote tag {}", joined.join(", "));
    let finished = finish_or_no_op_at(workspace, readonly, &description, ctx, |tx, _sink| {
        for symbol in &chosen {
            match tracking {
                Tracking::Track => {
                    pollster::block_on(tx.repo_mut().track_remote_tag(symbol.as_ref())).map_err(mutate::be)?;
                }
                Tracking::Untrack => tx.repo_mut().untrack_remote_tag(symbol.as_ref()),
            }
        }
        Ok(())
    })?;
    Ok(finished.mutation)
}

#[cfg(test)]
mod tests {
    use super::{check_names, check_set_args};

    /// clap's refusals of the four tag verbs name `tag <verb>`; `set` also refuses an empty name.
    #[test]
    fn clap_checks_name_the_tag_verb() {
        let none = check_set_args(&[]).expect_err("required = true");
        assert!(
            none.to_string().contains("tag set requires at least one name"),
            "{none}"
        );
        let empty = check_set_args(&[String::new()]).expect_err("parse_tag_name");
        assert!(empty.to_string().contains("tag name must not be empty"), "{empty}");
        check_set_args(&["v1".to_owned()]).expect("one name");
        for verb in ["delete", "track", "untrack"] {
            let refused = check_names(verb, &[]).expect_err("required = true");
            assert!(
                refused
                    .to_string()
                    .contains(&format!("tag {verb} requires at least one name")),
                "{refused}"
            );
            check_names(verb, &["v*".to_owned()]).expect("a pattern");
        }
    }
}
