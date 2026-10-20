// SPDX-License-Identifier: MIT

//! `template.rs` — the commit templates the describing verbs and `git push --change` render
//! (Story 9.51), through jj-cli's OWN engine at v0.46.0: `CommitTemplateLanguage`,
//! `template_builder::parse` and `TemplateRenderer`. Nothing of the template language is
//! re-ported; what is ported is the environment the CLI builds it in and the description rules
//! around it.
//!
//! Ported anchors (`cli/src` @ v0.46.0):
//!
//! - the environment — `cli_util.rs` `commit_template_language` `:1199-1215`, `parse_template`
//!   `:1180-1195`, `revset_parse_context` `:1048-1070`, `new_id_prefix_context` `:1072-1079`,
//!   `load_short_prefixes_expression` `:1115-1136`, `load_template_aliases`;
//! - the description rules — `description_util.rs` `parse_trailers_template` `:433`,
//!   `add_trailers_with_template` `:449`, `add_trailers` `:480`, `description_template` `:494`
//!   (rendered and then cleaned up the way a buffer saved unchanged is), the trailer block of
//!   `combine_messages_for_editing` `:~385-404`; `new.rs:214-230` (`templates.new_description`);
//!   `git/push.rs:1322-1337` (`templates.git_push_bookmark`);
//! - the errors — `command_error.rs` `From<TemplateParseError>` `:708-716` ("Failed to parse
//!   template: {kind}") and `From<TrailerParseError>` `:530`, each a [`MutateError::Config`] with
//!   the CLI's text: every template here comes from the user's config, and its remedy is a config
//!   edit.
//!
//! The language is built exactly as the CLI's transaction builds it: over the transaction's repo,
//! with the verb's workspace name, a path converter rooted at the workspace root (Zanshin's GUI
//! convention: there is no cwd), the effective `[revset-aliases]` and `user.email`, the immutable
//! set the start-up environment parsed, `ui.conflict-marker-style`, an id-prefix context
//! disambiguated within `revsets.short-prefixes` (else `revsets.log`; empty = none) and no
//! template extensions — stock jj registers none.
//!
//! One divergence, ledgered in the spec's `deferred:`: the CLI loads `[template-aliases]` and
//! parses `revsets.short-prefixes` at the start of EVERY workspace command, so a broken table or
//! short-prefixes revset refuses every command; Zanshin loads both lazily, with the first
//! template a verb parses ([`Templates`]), so only the template-rendering verbs refuse.

use std::cell::OnceCell;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use jj_cli::commit_templater::CommitTemplateLanguage;
use jj_cli::template_builder;
use jj_cli::template_parser::{TemplateAliasParser, TemplateAliasesMap, TemplateDiagnostics};
use jj_cli::templater::TemplateRenderer;
use jj_lib::commit::Commit;
use jj_lib::commit_builder::DetachedCommitBuilder;
use jj_lib::config::StackedConfig;
use jj_lib::conflicts::ConflictMarkerStyle;
use jj_lib::fileset::FilesetAliasesMap;
use jj_lib::id_prefix::IdPrefixContext;
use jj_lib::ref_name::{WorkspaceName, WorkspaceNameBuf};
use jj_lib::repo::Repo as JjRepo;
use jj_lib::revset::{RevsetExtensions, RevsetParseContext, RevsetWorkspaceContext, UserRevsetExpression};
use jj_lib::trailer::{parse_description_trailers, parse_trailers, Trailer};
use jj_lib::ui_path::RepoPathUiConverter;
use jj_lib::workspace::Workspace;

use crate::mutate::{be, cfg, MutateError};
use crate::op_support::{apply_trailers, cleanup_description_lines, complete_newline};
use crate::revset::RevsetConfig;
use crate::warning::{self, Load, WarningKind, Warnings};

/// The context line the CLI prints above a template's parse diagnostics
/// (`cli/src/cli_util.rs:1193` @ v0.46.0).
const IN_TEMPLATE_EXPRESSION: &str = "In template expression";

/// The commit templates of ONE verb call: the config they are read from, the workspace they are
/// rendered for, and the environment the CLI builds the template language in — loaded with the
/// first template parsed, then kept for the call.
pub(crate) struct Templates<'c> {
    config: &'c StackedConfig,
    immutable: &'c Arc<UserRevsetExpression>,
    workspace_name: WorkspaceNameBuf,
    workspace_root: PathBuf,
    env: OnceCell<Env>,
}

/// What the template language borrows, owned for the call.
struct Env {
    path_converter: RepoPathUiConverter,
    revset: RevsetConfig,
    fileset_aliases: FilesetAliasesMap,
    extensions: Arc<RevsetExtensions>,
    conflict_marker_style: ConflictMarkerStyle,
    aliases: TemplateAliasesMap,
    id_prefix_context: IdPrefixContext,
}

impl<'c> Templates<'c> {
    /// The templates of a call in `workspace`, read off `config`; `immutable` is the immutable set
    /// the start-up environment parsed (`::(immutable_heads() | root())`).
    pub(crate) fn new(
        config: &'c StackedConfig,
        immutable: &'c Arc<UserRevsetExpression>,
        workspace: &Workspace,
    ) -> Self {
        Self::at(
            config,
            immutable,
            workspace.workspace_name(),
            workspace.workspace_root(),
        )
    }

    /// [`Templates::new`] for a workspace given by its name and root — `workspace add` renders
    /// for the NEW workspace (`add.rs:222` @ v0.46.0: the new workspace's transaction).
    pub(crate) fn at(
        config: &'c StackedConfig,
        immutable: &'c Arc<UserRevsetExpression>,
        workspace_name: &WorkspaceName,
        workspace_root: &Path,
    ) -> Self {
        Self {
            config,
            immutable,
            workspace_name: workspace_name.to_owned(),
            workspace_root: workspace_root.to_owned(),
            env: OnceCell::new(),
        }
    }

    /// The environment, loaded on first use: the `[revset-aliases]`, `[fileset-aliases]` and
    /// `[template-aliases]` tables (each table's warnings recorded once per call),
    /// `ui.conflict-marker-style`, and the `revsets.short-prefixes` parse with its diagnostics.
    fn env(&self, sink: &mut Warnings) -> Result<&Env, MutateError> {
        if let Some(env) = self.env.get() {
            return Ok(env);
        }
        let env = self.load(sink)?;
        Ok(self.env.get_or_init(|| env))
    }

    fn load(&self, sink: &mut Warnings) -> Result<Env, MutateError> {
        let revset = crate::revset::revset_config(self.config, sink).map_err(cfg)?;
        let (fileset_aliases, warnings): (FilesetAliasesMap, _) =
            crate::revset::build_aliases_map(self.config, "fileset-aliases").map_err(cfg)?;
        sink.record_load(Load::FilesetAliases, warnings);
        let (aliases, warnings): (TemplateAliasesMap, _) =
            crate::revset::build_aliases_map::<TemplateAliasParser>(self.config, "template-aliases").map_err(cfg)?;
        sink.record_load(Load::TemplateAliases, warnings);
        let conflict_marker_style = crate::config::conflict_marker_style(self.config).map_err(cfg)?;
        let extensions = Arc::new(RevsetExtensions::default());
        let short_prefixes = crate::config::revsets_short_prefixes(self.config).map_err(cfg)?;
        let mut id_prefix_context = IdPrefixContext::new(Arc::clone(&extensions));
        if !short_prefixes.is_empty() {
            let expression = crate::revset::parse_diagnosed_at(
                (&self.workspace_root, &self.workspace_name),
                &revset,
                (&short_prefixes, "In `revsets.short-prefixes`"),
                &[],
                sink,
            )
            .map_err(|e| MutateError::Config {
                reason: format!("Invalid `revsets.short-prefixes`: {}", parse_reason(e)),
            })?;
            id_prefix_context = id_prefix_context.disambiguate_within(expression);
        }
        Ok(Env {
            path_converter: RepoPathUiConverter::Fs {
                cwd: self.workspace_root.clone(),
                base: self.workspace_root.clone(),
            },
            revset,
            fileset_aliases,
            extensions,
            conflict_marker_style,
            aliases,
            id_prefix_context,
        })
    }

    /// Parses `text` as a commit template over `repo` — the CLI's
    /// `WorkspaceCommandTransaction::parse_commit_template`. Its diagnostics land in `sink` as
    /// [`WarningKind::TemplateDiagnostic`] under "In template expression".
    ///
    /// # Errors
    ///
    /// - [`MutateError::Config`] — the environment does not load (see [`Templates::env`]), or
    ///   the template does not parse: "Failed to parse template: {kind}".
    pub(crate) fn parse_commit<'a>(
        &'a self,
        repo: &'a dyn JjRepo,
        text: &str,
        sink: &mut Warnings,
    ) -> Result<TemplateRenderer<'a, Commit>, MutateError> {
        let env = self.env(sink)?;
        let revset_parse_context = RevsetParseContext {
            aliases_map: env.revset.aliases_map(),
            local_variables: std::collections::HashMap::new(),
            user_email: env.revset.user_email(),
            date_pattern_context: chrono::Local::now().into(),
            default_ignored_remote: Some("git".as_ref()),
            fileset_aliases_map: &env.fileset_aliases,
            extensions: &env.extensions,
            workspace: Some(RevsetWorkspaceContext {
                path_converter: &env.path_converter,
                workspace_name: &self.workspace_name,
            }),
        };
        let language = CommitTemplateLanguage::new(
            repo,
            &env.path_converter,
            &self.workspace_name,
            revset_parse_context,
            &env.id_prefix_context,
            Arc::clone(self.immutable),
            env.conflict_marker_style,
            &[] as &[Box<dyn jj_cli::commit_templater::CommitTemplateLanguageExtension>],
        );
        let mut diagnostics = TemplateDiagnostics::new();
        let renderer = template_builder::parse(&language, &mut diagnostics, text, &env.aliases).map_err(|e| {
            MutateError::Config {
                reason: format!("Failed to parse template: {}", e.kind()),
            }
        })?;
        sink.extend(warning::parse_diagnostics(
            WarningKind::TemplateDiagnostic,
            IN_TEMPLATE_EXPRESSION,
            &diagnostics,
        ));
        Ok(renderer)
    }

    /// `parse_trailers_template` (`description_util.rs:433-446`): `templates.commit_trailers`
    /// parsed, or `None` when the key is empty — then nothing is parsed at all.
    ///
    /// # Errors
    ///
    /// - [`MutateError::Config`] — the key is not a string, or see [`Templates::parse_commit`].
    pub(crate) fn trailers<'a>(
        &'a self,
        repo: &'a dyn JjRepo,
        sink: &mut Warnings,
    ) -> Result<Option<TemplateRenderer<'a, Commit>>, MutateError> {
        let text = crate::config::templates_commit_trailers(self.config).map_err(cfg)?;
        if text.is_empty() {
            return Ok(None);
        }
        self.parse_commit(repo, &text, sink).map(Some)
    }

    /// `add_trailers` (`description_util.rs:480-491`): with a `templates.commit_trailers`,
    /// `builder`'s description with the rendered trailers added ([`add_trailers_with`]) on a hidden
    /// write of `builder`; without one, `builder`'s description as it is.
    ///
    /// # Errors
    ///
    /// - [`MutateError::Config`] — see [`Templates::trailers`] and [`add_trailers_with`].
    /// - [`MutateError::Backend`] — the hidden write failed.
    pub(crate) fn add_trailers(
        &self,
        repo: &dyn JjRepo,
        builder: &DetachedCommitBuilder,
        sink: &mut Warnings,
    ) -> Result<String, MutateError> {
        match self.trailers(repo, sink)? {
            Some(renderer) => add_trailers_with(&renderer, &write_hidden(builder)?),
            None => Ok(builder.description().to_owned()),
        }
    }

    /// The trailer block of `combine_messages_for_editing` (`description_util.rs:~385-404`): the
    /// trailers `templates.commit_trailers` renders on a hidden write of `builder` that none of
    /// `old_descriptions` (the squashed commits') carries, in rendered order. Empty without a
    /// trailers template.
    ///
    /// # Errors
    ///
    /// - [`MutateError::Config`] — see [`Templates::trailers`] and [`add_trailers_with`].
    /// - [`MutateError::Backend`] — the hidden write failed.
    pub(crate) fn trailers_not_in(
        &self,
        repo: &dyn JjRepo,
        builder: &DetachedCommitBuilder,
        old_descriptions: &[&str],
        sink: &mut Warnings,
    ) -> Result<Vec<Trailer>, MutateError> {
        let Some(renderer) = self.trailers(repo, sink)? else {
            return Ok(Vec::new());
        };
        let old: Vec<Trailer> = old_descriptions
            .iter()
            .flat_map(|description| parse_description_trailers(description))
            .collect();
        let new = rendered_trailers(&renderer, &write_hidden(builder)?)?;
        Ok(new.into_iter().filter(|t| !old.contains(t)).collect())
    }

    /// The text the CLI's editor holds for `commit` when it saves it UNCHANGED:
    /// `description_template` (`description_util.rs:494-514`) — `templates.draft_commit_description`
    /// rendered on `commit` — through `cleanup_description_lines`, which drops the intro and every
    /// other `JJ:` line and the blank edges. `commit` is the hidden temp commit the CLI renders.
    ///
    /// # Errors
    ///
    /// - [`MutateError::Config`] — the key is not a string, or see [`Templates::parse_commit`].
    pub(crate) fn editor_text(
        &self,
        repo: &dyn JjRepo,
        commit: &Commit,
        sink: &mut Warnings,
    ) -> Result<String, MutateError> {
        let text = crate::config::templates_draft_commit_description(self.config).map_err(cfg)?;
        let template = self.parse_commit(repo, &text, sink)?;
        // "Template output is usually UTF-8, but it can contain file content." — lossy, as the CLI.
        let buffer = String::from_utf8_lossy(&template.format_plain_text(commit)).into_owned();
        Ok(cleanup_description_lines(buffer.lines()))
    }

    /// `jj new`'s description without `-m` (`new.rs:214-230`): `templates.new_description`
    /// rendered on a hidden write of `builder`, newline-completed; `""` when the key is empty — then
    /// nothing is parsed.
    ///
    /// # Errors
    ///
    /// - [`MutateError::Config`] — the key is not a string, or see [`Templates::parse_commit`].
    /// - [`MutateError::Backend`] — the hidden write failed.
    pub(crate) fn new_description(
        &self,
        repo: &dyn JjRepo,
        builder: &DetachedCommitBuilder,
        sink: &mut Warnings,
    ) -> Result<String, MutateError> {
        let text = crate::config::templates_new_description(self.config).map_err(cfg)?;
        if text.is_empty() {
            return Ok(String::new());
        }
        let renderer = self.parse_commit(repo, &text, sink)?;
        let temp = write_hidden(builder)?;
        Ok(complete_newline(&String::from_utf8_lossy(
            &renderer.format_plain_text(&temp),
        )))
    }

    /// `jj git push --change`'s bookmark names (`push.rs:1322-1337`): `templates.git_push_bookmark`
    /// parsed once and rendered on each of `commits`, in order.
    ///
    /// # Errors
    ///
    /// - [`MutateError::Config`] — the key is not a string, the template does not parse (see
    ///   [`Templates::parse_commit`]), or a name is not UTF-8 ("Invalid character in bookmark
    ///   name") or empty ("Empty bookmark name generated").
    pub(crate) fn push_bookmark_names(
        &self,
        repo: &dyn JjRepo,
        commits: &[Commit],
        sink: &mut Warnings,
    ) -> Result<Vec<String>, MutateError> {
        let text = crate::config::templates_git_push_bookmark(self.config).map_err(cfg)?;
        let renderer = self.parse_commit(repo, &text, sink)?;
        commits
            .iter()
            .map(|commit| push_bookmark_name(&renderer, commit))
            .collect()
    }
}

/// `add_trailers_with_template` (`description_util.rs:449-476`): `commit`'s description with the
/// trailers `renderer` renders on `commit` added to its last paragraph, duplicates skipped
/// ([`apply_trailers`]).
///
/// # Errors
///
/// - [`MutateError::Config`] — the rendered text is not UTF-8 ("Trailers should be valid utf-8")
///   or not a trailer block (jj-lib's `TrailerParseError` text).
pub(crate) fn add_trailers_with(
    renderer: &TemplateRenderer<'_, Commit>,
    commit: &Commit,
) -> Result<String, MutateError> {
    let new_trailers = rendered_trailers(renderer, commit)?;
    Ok(apply_trailers(commit.description(), &new_trailers))
}

/// The trailers `renderer` renders on `commit`, strictly parsed (`parse_trailers`).
fn rendered_trailers(renderer: &TemplateRenderer<'_, Commit>, commit: &Commit) -> Result<Vec<Trailer>, MutateError> {
    let lines = String::from_utf8(renderer.format_plain_text(commit)).map_err(|_| MutateError::Config {
        reason: "Trailers should be valid utf-8".to_owned(),
    })?;
    parse_trailers(&lines).map_err(cfg)
}

/// One `--change` bookmark name (`push.rs:1328-1335`).
fn push_bookmark_name(renderer: &TemplateRenderer<'_, Commit>, commit: &Commit) -> Result<String, MutateError> {
    let name = String::from_utf8(renderer.format_plain_text(commit)).map_err(|_| MutateError::Config {
        reason: "Invalid character in bookmark name".to_owned(),
    })?;
    if name.is_empty() {
        return Err(MutateError::Config {
            reason: "Empty bookmark name generated".to_owned(),
        });
    }
    Ok(name)
}

/// `DetachedCommitBuilder::write_hidden` — the temp commit the CLI renders a template on. It
/// reaches the store, never the view.
pub(crate) fn write_hidden(builder: &DetachedCommitBuilder) -> Result<Commit, MutateError> {
    pollster::block_on(builder.write_hidden()).map_err(be)
}

/// The reason of a failed revset parse, without [`crate::RevsetError`]'s own prefix.
fn parse_reason(error: crate::RevsetError) -> String {
    match error {
        crate::RevsetError::ParseError { reason } => reason,
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use jj_lib::commit::Commit;
    use jj_lib::commit_builder::DetachedCommitBuilder;
    use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
    use jj_lib::repo::{ReadonlyRepo, Repo as _};
    use jj_lib::revset::UserRevsetExpression;
    use jj_lib::transaction::Transaction;

    use super::Templates;
    use crate::mutate::MutateError;
    use crate::op_support::start_repo_transaction;
    use crate::warning::{WarningKind, Warnings};

    const SOB: &str = "Signed-off-by: Zanshin <zanshin@localhost>";

    /// A fresh repo, its effective config with `toml` as a user layer on top, and the immutable
    /// set parsed off it.
    struct Fixture {
        _tmp: tempfile::TempDir,
        repo: crate::Repo,
        config: StackedConfig,
        immutable: Arc<UserRevsetExpression>,
    }

    fn fixture(toml: &str) -> Fixture {
        test_helpers::pin_test_env();
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let repo = crate::Repo::init(&crate::InitOptions {
            path: tmp.path().to_owned(),
            ..Default::default()
        })
        .result
        .expect("init");
        let mut config = crate::config::load(&repo).expect("config");
        config.add_layer(ConfigLayer::parse(ConfigSource::User, toml).expect("toml"));
        let immutable =
            crate::op_support::immutable_user_expression(repo.workspace(), &config, &mut Warnings::default())
                .expect("immutable");
        Fixture {
            _tmp: tmp,
            repo,
            config,
            immutable,
        }
    }

    impl Fixture {
        fn templates(&self) -> Templates<'_> {
            Templates::new(&self.config, &self.immutable, self.repo.workspace())
        }

        fn head(&self) -> Arc<ReadonlyRepo> {
            pollster::block_on(self.repo.workspace().repo_loader().load_at_head()).expect("head")
        }
    }

    /// A transaction on `head` and a detached new commit on the root with `description`.
    fn detached(head: &Arc<ReadonlyRepo>, description: &str) -> (Transaction, DetachedCommitBuilder) {
        let mut tx = start_repo_transaction(head, jj_lib::ref_name::WorkspaceName::DEFAULT);
        let store = tx.repo().store().clone();
        let mut builder = tx
            .repo_mut()
            .new_commit(vec![store.root_commit_id().clone()], store.empty_merged_tree())
            .detach();
        builder.set_description(description);
        (tx, builder)
    }

    fn config_reason(result: Result<impl std::fmt::Debug, MutateError>) -> String {
        match result {
            Err(MutateError::Config { reason }) => reason,
            other => panic!("expected a config error, got {other:?}"),
        }
    }

    /// An empty `templates.commit_trailers` parses nothing — not even the environment, so a broken
    /// alias table does not refuse — and leaves the description as it is.
    #[test]
    fn an_empty_trailers_key_parses_nothing() {
        let f = fixture("template-aliases = 1\n");
        let head = f.head();
        let (tx, builder) = detached(&head, "T\n");
        let templates = f.templates();
        let mut sink = Warnings::default();
        assert!(templates.trailers(tx.repo(), &mut sink).expect("no parse").is_none());
        assert_eq!(
            templates.add_trailers(tx.repo(), &builder, &mut sink).expect("as is"),
            "T\n"
        );
        assert!(templates
            .trailers_not_in(tx.repo(), &builder, &[], &mut sink)
            .expect("none")
            .is_empty());
        assert!(sink.take().is_empty());
    }

    /// The trailers land in a new paragraph, and a trailer the description already carries is not
    /// added again.
    #[test]
    fn trailers_are_added_once() {
        let f = fixture("templates.commit_trailers = 'format_signed_off_by_trailer(self)'\n");
        let head = f.head();
        let templates = f.templates();
        let mut sink = Warnings::default();
        let (tx, builder) = detached(&head, "T\n");
        assert_eq!(
            templates
                .add_trailers(tx.repo(), &builder, &mut sink)
                .expect("trailers"),
            format!("T\n\n{SOB}\n")
        );
        let (tx, builder) = detached(&head, &format!("T\n\n{SOB}\n"));
        assert_eq!(
            templates
                .add_trailers(tx.repo(), &builder, &mut sink)
                .expect("trailers"),
            format!("T\n\n{SOB}\n")
        );
    }

    /// The squash block lists only the rendered trailers no squashed commit carries.
    #[test]
    fn trailers_not_in_drops_the_ones_already_there() {
        let f = fixture("templates.commit_trailers = 'format_signed_off_by_trailer(self) ++ \"Reviewed-by: R\\n\"'\n");
        let head = f.head();
        let (tx, builder) = detached(&head, "B\n");
        let missing = f
            .templates()
            .trailers_not_in(
                tx.repo(),
                &builder,
                &["C\n\nReviewed-by: R\n", "B\n"],
                &mut Warnings::default(),
            )
            .expect("trailers");
        let lines: Vec<String> = missing.iter().map(|t| format!("{}: {}", t.key, t.value)).collect();
        assert_eq!(lines, [SOB]);
    }

    /// The editor's text saved unchanged: the default draft template's `JJ:` lines are dropped;
    /// an undescribed commit falls back to `default_commit_description`.
    #[test]
    fn the_editor_text_is_the_rendered_draft_cleaned_up() {
        let f = fixture("");
        let head = f.head();
        let mut sink = Warnings::default();
        let (tx, builder) = detached(&head, "B\n\nC\n");
        let temp = super::write_hidden(&builder).expect("hidden");
        let templates = f.templates();
        assert_eq!(
            templates.editor_text(tx.repo(), &temp, &mut sink).expect("text"),
            "B\n\nC\n"
        );
        let (tx, builder) = detached(&head, "");
        let temp = super::write_hidden(&builder).expect("hidden");
        assert_eq!(templates.editor_text(tx.repo(), &temp, &mut sink).expect("text"), "");

        let f = fixture("template-aliases.default_commit_description = '\"DEF\\n\"'\n");
        let head = f.head();
        let (tx, builder) = detached(&head, "");
        let temp = super::write_hidden(&builder).expect("hidden");
        assert_eq!(
            f.templates().editor_text(tx.repo(), &temp, &mut sink).expect("text"),
            "DEF\n"
        );
    }

    /// `templates.new_description`: empty is `""` without a parse, a text is newline-completed.
    #[test]
    fn the_new_description_is_rendered_and_completed() {
        let f = fixture("template-aliases = 1\n");
        let head = f.head();
        let (tx, builder) = detached(&head, "");
        let mut sink = Warnings::default();
        assert_eq!(
            f.templates()
                .new_description(tx.repo(), &builder, &mut sink)
                .expect("empty"),
            ""
        );
        let f = fixture("templates.new_description = '\"N\"'\n");
        let head = f.head();
        let (tx, builder) = detached(&head, "");
        assert_eq!(
            f.templates()
                .new_description(tx.repo(), &builder, &mut sink)
                .expect("text"),
            "N\n"
        );
    }

    /// A template that does not parse refuses with the CLI's text.
    #[test]
    fn a_broken_template_refuses_with_the_clis_text() {
        let f = fixture("templates.commit_trailers = 'nope('\n");
        let head = f.head();
        let (tx, _) = detached(&head, "");
        let reason = config_reason(
            f.templates()
                .trailers(tx.repo(), &mut Warnings::default())
                .map(|r| r.is_some()),
        );
        assert_eq!(reason, "Failed to parse template: Syntax error");
    }

    /// Trailers that are no trailer block refuse with jj-lib's text.
    #[test]
    fn a_non_trailer_rendering_refuses() {
        let f = fixture("templates.commit_trailers = '\"not a trailer\\n\"'\n");
        let head = f.head();
        let (tx, builder) = detached(&head, "T\n");
        let reason = config_reason(
            f.templates()
                .add_trailers(tx.repo(), &builder, &mut Warnings::default()),
        );
        assert_eq!(reason, "Invalid trailer line: not a trailer");
    }

    /// Push names: the template's text per commit; an empty name refuses.
    #[test]
    fn push_names_are_rendered_and_an_empty_one_refuses() {
        let f = fixture("templates.git_push_bookmark = '\"mine-\" ++ description.first_line()'\n");
        let head = f.head();
        let (_tx, builder) = detached(&head, "x\n");
        let commit: Commit = super::write_hidden(&builder).expect("hidden");
        let names = f
            .templates()
            .push_bookmark_names(head.as_ref(), std::slice::from_ref(&commit), &mut Warnings::default())
            .expect("names");
        assert_eq!(names, ["mine-x"]);
        let f = fixture("templates.git_push_bookmark = '\"\"'\n");
        let reason = config_reason(f.templates().push_bookmark_names(
            head.as_ref(),
            std::slice::from_ref(&commit),
            &mut Warnings::default(),
        ));
        assert_eq!(reason, "Empty bookmark name generated");
    }

    /// Output that is not UTF-8 (a file's bytes in a git diff) refuses as trailers and as a push
    /// name, with the CLI's texts.
    #[test]
    fn non_utf8_output_refuses() {
        let f = fixture(
            "templates.commit_trailers = 'self.diff().git()'\ntemplates.git_push_bookmark = 'self.diff().git()'\n",
        );
        std::fs::write(f.repo.workspace_root().join("bin.txt"), b"\xff\xfe\n").expect("write");
        let mut repo = crate::Repo::open(f.repo.workspace_root()).expect("open");
        repo.snapshot().expect("snapshot");
        let head = f.head();
        let wc_id = head
            .view()
            .get_wc_commit_id(jj_lib::ref_name::WorkspaceName::DEFAULT)
            .expect("@");
        let wc = head.store().get_commit(wc_id).expect("@ commit");
        let templates = f.templates();
        let mut sink = Warnings::default();
        let renderer = templates
            .trailers(head.as_ref(), &mut sink)
            .expect("parses")
            .expect("set");
        assert_eq!(
            config_reason(super::add_trailers_with(&renderer, &wc)),
            "Trailers should be valid utf-8"
        );
        assert_eq!(
            config_reason(templates.push_bookmark_names(head.as_ref(), &[wc], &mut sink)),
            "Invalid character in bookmark name"
        );
    }

    /// The environment's warnings: a bad alias entry warns once per call, however many templates
    /// are parsed; a short-prefixes index that does not load is a template diagnostic.
    #[test]
    fn the_environment_warns_once_and_diagnostics_are_template_warnings() {
        let f = fixture("[template-aliases]\n'x(' = '1'\n\n[revsets]\nshort-prefixes = 'missing'\n");
        let head = f.head();
        let templates = f.templates();
        let mut sink = Warnings::default();
        templates
            .parse_commit(head.as_ref(), "change_id.shortest()", &mut sink)
            .expect("parses");
        templates
            .parse_commit(head.as_ref(), "description", &mut sink)
            .expect("parses");
        let warnings = sink.take();
        let aliases: Vec<&str> = warnings
            .iter()
            .filter(|w| w.kind == WarningKind::ConfigAliasInvalid)
            .map(|w| w.message.as_str())
            .collect();
        assert_eq!(aliases.len(), 1, "{warnings:?}");
        assert!(
            aliases[0].starts_with("Failed to load `template-aliases.x(`: "),
            "{aliases:?}"
        );
        let diagnostics: Vec<&str> = warnings
            .iter()
            .filter(|w| w.kind == WarningKind::TemplateDiagnostic)
            .map(|w| w.message.as_str())
            .collect();
        assert_eq!(diagnostics.len(), 1, "{warnings:?}");
        assert!(
            diagnostics[0].starts_with("In template expression\n"),
            "{diagnostics:?}"
        );
    }

    /// A `revsets.short-prefixes` that does not parse refuses with the CLI's text.
    #[test]
    fn a_broken_short_prefixes_revset_refuses() {
        let f = fixture("revsets.short-prefixes = '('\n");
        let head = f.head();
        let reason = config_reason(
            f.templates()
                .parse_commit(head.as_ref(), "description", &mut Warnings::default())
                .map(|_| ()),
        );
        assert!(reason.starts_with("Invalid `revsets.short-prefixes`: "), "{reason}");
    }
}
