// SPDX-License-Identifier: MIT

//! `metaedit.rs` — `jj metaedit` (Story 9.9), ported step for step from `cmd_metaedit`
//! (`cli/src/commands/metaedit.rs` @ v0.46.0): the targets checked rewritable, one
//! `transform_descendants` over them that rewrites a target only when one of its metadata
//! changes (or `--force-rewrite`) and reparents every other descendant, then the finish with the
//! CLI's `edit commit metadata for commit <hex>[ and <n> more]`.
//!
//! The revisions are change ids (ADR-0003); an empty list is the CLI's default `@`, resolved by
//! commit id. `author` and `author_timestamp` arrive as the CLI's own argument strings and are
//! parsed with the CLI's value parsers (`parse_author`, `jj_lib::time_util::parse_datetime`), so
//! a malformed value is refused as clap refuses it — before the pre-verb snapshot, with the other
//! clap rules ([`check_metaedit_args`]).
//!
//! Divergence, deliberate: the status lines (`Modified N commits:`, `Rebased N descendant
//! commits.`) are terminal UX and not ported; the change ids `update_change_id` minted are the
//! result's `new_change_ids`.

use std::collections::HashSet;
use std::sync::LazyLock;

use futures::TryStreamExt as _;
use jj_lib::backend::{CommitId, Timestamp};
use jj_lib::commit::Commit;
use jj_lib::object_id::ObjectId;
use jj_lib::revset::RevsetExpression;
use jj_lib::workspace::Workspace;
use regex::Regex;

use crate::mutate::{
    be, finish_verb, guard_rewritable, mutation_result, no_op_result, resolve_or_wc, MutateError, MutationResult,
};
use crate::op_support::{join_message_paragraphs, resolve_ordered, start_repo_transaction};
use crate::snapshot::VerbContext;
use crate::ChangeId;

/// [`crate::Repo::metaedit`]'s arguments — the CLI's `jj metaedit` flags, one field each (Story
/// 9.9).
// WHY: one field per CLI flag (`MetaeditArgs`, FR-JJ-17) — the bools ARE the CLI's independent
// switches, and folding them into enums would re-invent clap's rules the CLI's own struct keeps flat.
#[allow(clippy::struct_excessive_bools)]
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MetaeditOptions {
    /// The revisions to modify (`REVSETS` / `-r`). Empty is the CLI's default, `@`.
    pub revisions: Vec<ChangeId>,
    /// `--update-change-id`: give each modified revision a new change id.
    pub update_change_id: bool,
    /// `-m/--message`, repeatable: the new description, the paragraphs joined as the CLI joins
    /// them. `None` leaves the description alone; `Some(vec![])` joins to `""` and so equals `-m
    /// ""`: it clears every target's description.
    pub message: Option<Vec<String>>,
    /// `--update-author-timestamp`: set the author timestamp to the committer timestamp (now).
    /// Excludes `author_timestamp`.
    pub update_author_timestamp: bool,
    /// `--update-author`: set the author name and email to the configured user's. Excludes
    /// `author`.
    pub update_author: bool,
    /// `--author`: the CLI's argument, `Name <email>` (e.g. `"Foo Bar <foo@bar.com>"`); the
    /// author timestamp stays.
    pub author: Option<String>,
    /// `--author-timestamp`: the CLI's argument, RFC 2822 (`"Sun, 23 Jan 2000 01:23:45 PST"`) or
    /// RFC 3339 (`"2000-01-23T01:23:45-08:00"`).
    pub author_timestamp: Option<String>,
    /// `--force-rewrite`: rewrite every revision even when nothing else changed — a new committer
    /// timestamp and identity.
    pub force_rewrite: bool,
}

/// The values `--author` and `--author-timestamp` parse to.
struct ParsedArgs {
    author: Option<(String, String)>,
    author_timestamp: Option<Timestamp>,
}

/// The CLI's `parse_author` (`cli/src/text_util.rs:664-668` @ v0.46.0), its regular expression
/// verbatim.
static AUTHOR: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(r"(?<name>.*?)\s*<(?<email>.+)>$").ok());

/// `Name <email>` as the CLI's `parse_author` splits it.
fn parse_author(author: &str) -> Result<(String, String), &'static str> {
    let captures = AUTHOR
        .as_ref()
        .and_then(|re| re.captures(author))
        .ok_or("Invalid author string")?;
    Ok((captures["name"].to_owned(), captures["email"].to_owned()))
}

/// clap's value parsers for `--author` and `--author-timestamp`, in the flags' order, with
/// clap's "invalid value" text.
fn parse_args(options: &MetaeditOptions) -> Result<ParsedArgs, MutateError> {
    let author = options
        .author
        .as_deref()
        .map(|value| {
            parse_author(value)
                .map_err(|e| MutateError::invalid(format!("invalid value '{value}' for '--author <AUTHOR>': {e}")))
        })
        .transpose()?;
    let author_timestamp = options
        .author_timestamp
        .as_deref()
        .map(|value| {
            jj_lib::time_util::parse_datetime(value).map_err(|e| {
                MutateError::invalid(format!(
                    "invalid value '{value}' for '--author-timestamp <AUTHOR_TIMESTAMP>': {e}"
                ))
            })
        })
        .transpose()?;
    Ok(ParsedArgs {
        author,
        author_timestamp,
    })
}

/// Refuses what clap refuses, before the pre-verb snapshot ([`crate::Repo::metaedit`]): a value
/// `parse_author` or `parse_datetime` rejects (values are parsed as clap reads them, so they come
/// first), then `author` with `update_author` and `author_timestamp` with
/// `update_author_timestamp` (`conflicts_with`).
///
/// # Errors
///
/// [`MutateError::InvalidInput`] — `invalid value '<v>' for '--author <AUTHOR>': Invalid author
/// string`, `invalid value '<v>' for '--author-timestamp <AUTHOR_TIMESTAMP>': <reason>`,
/// `--author cannot be used with --update-author`, `--author-timestamp cannot be used with
/// --update-author-timestamp`.
pub(crate) fn check_metaedit_args(options: &MetaeditOptions) -> Result<(), MutateError> {
    parse_args(options)?;
    if options.author.is_some() && options.update_author {
        return Err(MutateError::invalid("--author cannot be used with --update-author"));
    }
    if options.author_timestamp.is_some() && options.update_author_timestamp {
        return Err(MutateError::invalid(
            "--author-timestamp cannot be used with --update-author-timestamp",
        ));
    }
    Ok(())
}

/// The operation description (`metaedit.rs:153-164` @ v0.46.0), full hex ids; `commit_ids` is
/// never empty.
fn tx_description(commit_ids: &[CommitId]) -> String {
    let first = commit_ids.first().map(ObjectId::hex).unwrap_or_default();
    match commit_ids.len().saturating_sub(1) {
        0 => format!("edit commit metadata for commit {first}"),
        more => format!("edit commit metadata for commit {first} and {more} more"),
    }
}

/// `jj metaedit` (Story 9.9) — see [`crate::Repo::metaedit`], which ran [`check_metaedit_args`]
/// before the snapshot.
///
/// # Errors
///
/// See [`crate::Repo::metaedit`].
pub(crate) fn metaedit(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    options: &MetaeditOptions,
) -> Result<MutationResult, MutateError> {
    let args = parse_args(options)?;
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let mut tx = start_repo_transaction(&readonly, &workspace_name);

    let ids = if options.revisions.is_empty() {
        vec![resolve_or_wc(tx.repo(), &workspace_name, None)?.id().clone()]
    } else {
        resolve_ordered(&tx, Some(&options.revisions))?.unwrap_or_default()
    };
    guard_rewritable(&tx, &ctx.templates(workspace), &ids)?;
    // The revset's own order — reverse topological (`metaedit.rs:144-149`).
    let set = RevsetExpression::commits(ids)
        .evaluate(tx.base_repo().as_ref())
        .map_err(be)?;
    let commit_ids: Vec<CommitId> = pollster::block_on(set.stream().try_collect()).map_err(be)?;
    let description = tx_description(&commit_ids);

    let new_description = options.message.as_deref().map(join_message_paragraphs);
    let targets: HashSet<CommitId> = commit_ids.iter().cloned().collect();
    let mut modified: Vec<Commit> = Vec::new();
    pollster::block_on(tx.repo_mut().transform_descendants(commit_ids, async |rewriter| {
        if !targets.contains(rewriter.old_commit().id()) {
            if rewriter.parents_changed() {
                rewriter.reparent().write().await?;
            }
            return Ok(());
        }
        let mut rewrite = options.force_rewrite || rewriter.parents_changed();
        let old_author = rewriter.old_commit().author().clone();
        let mut builder = rewriter.reparent();
        let mut new_author = builder.author().clone();
        if let Some((name, email)) = args.author.clone() {
            new_author.name = name;
            new_author.email = email;
        } else if options.update_author {
            new_author.name.clone_from(&builder.committer().name);
            new_author.email.clone_from(&builder.committer().email);
        }
        if options.update_author_timestamp {
            new_author.timestamp = builder.committer().timestamp;
        }
        if let Some(timestamp) = args.author_timestamp {
            new_author.timestamp = timestamp;
        }
        // The builder may already carry the configured author for a commit whose author was
        // unset, so the change is detected against the OLD commit's author (`:200-212`).
        if new_author.name != old_author.name
            || new_author.email != old_author.email
            || (new_author.timestamp != builder.author().timestamp && new_author.timestamp != old_author.timestamp)
        {
            builder = builder.set_author(new_author);
            rewrite = true;
        }
        if let Some(description) = &new_description {
            if description != builder.description() {
                builder = builder.set_description(description);
                rewrite = true;
            }
        }
        if options.update_change_id {
            builder = builder.generate_new_change_id();
            rewrite = true;
        }
        if rewrite {
            modified.push(builder.write().await?);
        }
        Ok(())
    }))
    .map_err(be)?;

    // `WorkspaceCommandTransaction::finish`'s "Nothing changed." guard (`cli_util.rs:2852`).
    if !tx.repo().has_changes() {
        drop(tx);
        return no_op_result(&workspace_name, &readonly);
    }
    let finish = finish_verb(workspace, tx, &description, ctx)?;
    let new_change_ids = if options.update_change_id {
        modified
            .iter()
            .map(|commit| ChangeId(commit.change_id().reverse_hex()))
            .collect()
    } else {
        Vec::new()
    };
    Ok(mutation_result(&finish, new_change_ids, Vec::new()))
}

#[cfg(test)]
mod tests {
    use jj_lib::backend::CommitId;

    use super::{check_metaedit_args, parse_author, tx_description, MetaeditOptions};
    use crate::mutate::MutateError;

    fn reason(options: &MetaeditOptions) -> Option<String> {
        check_metaedit_args(options).err().map(|e| {
            assert!(matches!(&e, MutateError::InvalidInput { hints, .. } if hints.is_empty()));
            e.to_string().replacen("invalid input: ", "", 1)
        })
    }

    /// The CLI's `parse_author`: the name is everything before the last ` <`, trimmed; the email
    /// is between the angle brackets at the end.
    #[test]
    fn parse_author_splits_name_and_email_as_the_cli_does() {
        assert_eq!(
            parse_author("Foo Bar <foo@bar.com>"),
            Ok(("Foo Bar".to_owned(), "foo@bar.com".to_owned()))
        );
        assert_eq!(parse_author("<foo@bar>"), Ok((String::new(), "foo@bar".to_owned())));
        assert_eq!(
            parse_author("Foo   <a <b>>"),
            Ok(("Foo".to_owned(), "a <b>".to_owned()))
        );
        assert_eq!(parse_author("Foo"), Err("Invalid author string"));
        assert_eq!(parse_author("Foo <foo@bar> x"), Err("Invalid author string"));
        assert_eq!(parse_author("Foo <>"), Err("Invalid author string"));
    }

    #[test]
    fn tx_description_names_the_first_commit_and_counts_the_rest() {
        let a = CommitId::from_hex("aa");
        let b = CommitId::from_hex("bb");
        let c = CommitId::from_hex("cc");
        assert_eq!(
            tx_description(std::slice::from_ref(&a)),
            "edit commit metadata for commit aa"
        );
        assert_eq!(
            tx_description(&[a, b, c]),
            "edit commit metadata for commit aa and 2 more"
        );
    }

    /// clap's rules, value parsers first — the ids need not exist.
    #[test]
    fn check_metaedit_args_refuses_what_clap_refuses() {
        assert_eq!(reason(&MetaeditOptions::default()), None);
        let author = |value: &str| MetaeditOptions {
            author: Some(value.to_owned()),
            ..MetaeditOptions::default()
        };
        assert_eq!(reason(&author("Foo <foo@bar>")), None);
        assert_eq!(
            reason(&author("Foo")).as_deref(),
            Some("invalid value 'Foo' for '--author <AUTHOR>': Invalid author string")
        );
        let stamp = |value: &str| MetaeditOptions {
            author_timestamp: Some(value.to_owned()),
            ..MetaeditOptions::default()
        };
        assert_eq!(reason(&stamp("2000-01-23T01:23:45-08:00")), None);
        assert_eq!(reason(&stamp("Sun, 23 Jan 2000 01:23:45 PST")), None);
        let bad = reason(&stamp("yesterday")).expect("refused");
        assert!(
            bad.starts_with("invalid value 'yesterday' for '--author-timestamp <AUTHOR_TIMESTAMP>': "),
            "{bad}"
        );
        assert_eq!(
            reason(&MetaeditOptions {
                update_author: true,
                ..author("Foo <foo@bar>")
            })
            .as_deref(),
            Some("--author cannot be used with --update-author")
        );
        assert_eq!(
            reason(&MetaeditOptions {
                update_author_timestamp: true,
                ..stamp("2000-01-23T01:23:45-08:00")
            })
            .as_deref(),
            Some("--author-timestamp cannot be used with --update-author-timestamp")
        );
        assert_eq!(
            reason(&MetaeditOptions {
                update_author: true,
                ..author("Foo")
            })
            .as_deref(),
            Some("invalid value 'Foo' for '--author <AUTHOR>': Invalid author string"),
            "a value clap cannot parse refuses before the conflict"
        );
    }
}
