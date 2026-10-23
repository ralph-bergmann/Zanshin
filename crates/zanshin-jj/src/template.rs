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
//! The `[template-aliases]` table and the `revsets.short-prefixes` parse are the template half of
//! the start-up environment ([`TemplateStartup`]): the CLI loads both at the start of EVERY
//! workspace command (`WorkspaceCommandEnvironment::new`, `cli_util.rs:961-991`), so
//! [`crate::snapshot::CommandEnv::load`] does too — a broken table or short-prefixes revset
//! refuses every verb that builds the start-up environment, and their warnings are recorded once
//! per call. [`Templates`] renders with what it loaded.

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
use crate::ConfigError;

/// The context line the CLI prints above a template's parse diagnostics
/// (`cli/src/cli_util.rs:1193` @ v0.46.0).
const IN_TEMPLATE_EXPRESSION: &str = "In template expression";

/// The template half of the CLI's start-up environment (`WorkspaceCommandEnvironment::new`,
/// `cli_util.rs:961-991` @ v0.46.0): the `[template-aliases]` map and the parsed
/// `revsets.short-prefixes` expression. [`crate::snapshot::CommandEnv::load`] builds it with
/// [`load_aliases`] and [`load_short_prefixes`], in the CLI's order; it travels in the call's
/// context into [`Templates`], which never loads either itself.
pub(crate) struct TemplateStartup {
    /// The `[template-aliases]` map every template of the call expands.
    pub(crate) aliases: TemplateAliasesMap,
    /// The expression the id-prefix context disambiguates within; `None` when the effective text
    /// is empty.
    pub(crate) short_prefixes: Option<Arc<UserRevsetExpression>>,
}

/// The CLI's `load_template_aliases` (`cli_util.rs:3518-3524` @ v0.46.0): the
/// `[template-aliases]` map, its entry warnings recorded once per call ([`Load::TemplateAliases`]).
///
/// # Errors
///
/// - [`ConfigError::Load`] — a layer's `template-aliases` is not a table.
pub(crate) fn load_aliases(config: &StackedConfig, sink: &mut Warnings) -> Result<TemplateAliasesMap, ConfigError> {
    let (aliases, warnings) = crate::revset::build_aliases_map::<TemplateAliasParser>(config, "template-aliases")?;
    sink.record_load(Load::TemplateAliases, warnings);
    Ok(aliases)
}

/// The CLI's `load_short_prefixes_expression` (`cli_util.rs:1120-1141` @ v0.46.0) for the
/// workspace given by its root and name: the effective `revsets.short-prefixes` text (else
/// `revsets.log`) parsed, its diagnostics recorded once per call ([`Load::ShortPrefixes`]);
/// `None` for an empty text.
///
/// # Errors
///
/// - [`ConfigError::Load`] — a value is not a string (the key is named), or the text does not
///   parse: "Invalid `revsets.short-prefixes`: {reason}".
pub(crate) fn load_short_prefixes(
    workspace: (&Path, &WorkspaceName),
    revset: &RevsetConfig,
    config: &StackedConfig,
    sink: &mut Warnings,
) -> Result<Option<Arc<UserRevsetExpression>>, ConfigError> {
    let text = crate::config::revsets_short_prefixes(config)?;
    if text.is_empty() {
        return Ok(None);
    }
    crate::revset::parse_short_prefixes(workspace, revset, &text, sink)
        .map(Some)
        .map_err(|e| ConfigError::Load {
            reason: format!("Invalid `revsets.short-prefixes`: {}", parse_reason(e)),
        })
}

/// The commit templates of ONE verb call: the config they are read from, the start-up
/// environment's alias map and short-prefixes expression, the workspace they are rendered for,
/// and the rest of the environment the CLI builds the template language in — loaded with the
/// first template parsed, then kept for the call.
pub(crate) struct Templates<'c> {
    config: &'c StackedConfig,
    immutable: &'c Arc<UserRevsetExpression>,
    aliases: &'c TemplateAliasesMap,
    short_prefixes: Option<Arc<UserRevsetExpression>>,
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
    id_prefix_context: IdPrefixContext,
}

impl<'c> Templates<'c> {
    /// The templates of a call in `workspace`, read off `config`; `immutable` is the immutable set
    /// the start-up environment parsed (`::(immutable_heads() | root())`), `startup` its template
    /// half.
    pub(crate) fn new(
        config: &'c StackedConfig,
        immutable: &'c Arc<UserRevsetExpression>,
        startup: &'c TemplateStartup,
        workspace: &Workspace,
    ) -> Self {
        Self {
            config,
            immutable,
            aliases: &startup.aliases,
            short_prefixes: startup.short_prefixes.clone(),
            workspace_name: workspace.workspace_name().to_owned(),
            workspace_root: workspace.workspace_root().to_owned(),
            env: OnceCell::new(),
        }
    }

    /// The immutable set the start-up environment parsed (`::(immutable_heads() | root())`) —
    /// what the rewritability guard resolves.
    pub(crate) fn immutable(&self) -> &Arc<UserRevsetExpression> {
        self.immutable
    }

    /// The environment, loaded on first use: the `[revset-aliases]` and `[fileset-aliases]`
    /// tables (each table's warnings recorded once per call), `ui.conflict-marker-style`, and the
    /// id-prefix context disambiguated within the short-prefixes expression.
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
        let conflict_marker_style = crate::config::conflict_marker_style(self.config).map_err(cfg)?;
        let extensions = Arc::new(RevsetExtensions::default());
        let mut id_prefix_context = IdPrefixContext::new(Arc::clone(&extensions));
        if let Some(expression) = &self.short_prefixes {
            id_prefix_context = id_prefix_context.disambiguate_within(Arc::clone(expression));
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
    ///   the template does not parse: "Failed to parse template: {kind}", then the CLI's
    ///   `Caused by:` chain one entry per line (the error with its position, then every source —
    ///   e.g. the fault inside an alias expansion).
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
        let renderer = template_builder::parse(&language, &mut diagnostics, text, self.aliases).map_err(|e| {
            // The CLI's headline, then its `Caused by:` chain — the error (with its position) and
            // every source below it, so the fault inside an alias expansion is named.
            let mut lines = vec![format!("Failed to parse template: {}", e.kind())];
            lines.extend(warning::error_chain_lines(&e));
            MutateError::Config {
                reason: lines.join("\n"),
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

    /// `jj duplicate`'s descriptions (`duplicate.rs:167-182` @ v0.46.0): `templates.duplicate_description`
    /// parsed once over `repo` and rendered on each of `commits` — the originals — newline-completed,
    /// in order.
    ///
    /// # Errors
    ///
    /// - [`MutateError::Config`] — the key is not a string, or see [`Templates::parse_commit`].
    pub(crate) fn duplicate_descriptions(
        &self,
        repo: &dyn JjRepo,
        commits: &[Commit],
        sink: &mut Warnings,
    ) -> Result<Vec<String>, MutateError> {
        let text = crate::config::templates_duplicate_description(self.config).map_err(cfg)?;
        let renderer = self.parse_commit(repo, &text, sink)?;
        Ok(commits
            .iter()
            .map(|commit| complete_newline(&String::from_utf8_lossy(&renderer.format_plain_text(commit))))
            .collect())
    }

    /// The CLI's `write_commit_summary` (`cli_util.rs:1995-2033` @ v0.46.0) as plain text:
    /// `templates.commit_summary` rendered on `commit` over `repo` — the summary the
    /// "Could not modify commit:" / "Rejected commit:" hints and push's skipped-signing list show.
    /// Its diagnostics are dropped, as the CLI's `reparse_valid_template` drops them (they come from
    /// its start-up parse, which Zanshin does not port).
    ///
    /// # Errors
    ///
    /// - [`MutateError::Config`] — the key is not a string, or see [`Templates::parse_commit`]:
    ///   the CLI refuses such a template at start-up, before any verb runs.
    pub(crate) fn commit_summary(&self, repo: &dyn JjRepo, commit: &Commit) -> Result<String, MutateError> {
        let text = crate::config::templates_commit_summary(self.config).map_err(cfg)?;
        let renderer = self.parse_commit(repo, &text, &mut Warnings::default())?;
        Ok(String::from_utf8_lossy(&renderer.format_plain_text(commit)).into_owned())
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
pub(crate) fn parse_reason(error: crate::RevsetError) -> String {
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
    use jj_lib::transaction::Transaction;

    use super::Templates;
    use crate::mutate::MutateError;
    use crate::op_support::start_repo_transaction;
    use crate::snapshot::CommandEnv;
    use crate::warning::{WarningKind, Warnings};

    const SOB: &str = "Signed-off-by: Zanshin <zanshin@localhost>";

    /// A fresh repo, its effective config with `toml` as a user layer on top, and the start-up
    /// environment built off it (the immutable set and the template start-up).
    struct Fixture {
        _tmp: tempfile::TempDir,
        repo: crate::Repo,
        config: StackedConfig,
        env: CommandEnv,
    }

    fn fixture(toml: &str) -> Fixture {
        let (tmp, repo, config) = repo_with(toml);
        let env = CommandEnv::load(repo.workspace(), &config, &mut Warnings::default()).expect("start-up");
        Fixture {
            _tmp: tmp,
            repo,
            config,
            env,
        }
    }

    /// A fresh repo and its effective config with `toml` as a user layer on top.
    fn repo_with(toml: &str) -> (tempfile::TempDir, crate::Repo, StackedConfig) {
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
        (tmp, repo, config)
    }

    impl Fixture {
        fn templates(&self) -> Templates<'_> {
            Templates::new(
                &self.config,
                &self.env.immutable,
                &self.env.template_startup,
                self.repo.workspace(),
            )
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
    /// `ui.conflict-marker-style` does not refuse — and leaves the description as it is.
    #[test]
    fn an_empty_trailers_key_parses_nothing() {
        let f = fixture("ui.conflict-marker-style = 1\n");
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
        let f = fixture("ui.conflict-marker-style = 1\n");
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
        assert_eq!(reason.lines().next(), Some("Failed to parse template: Syntax error"));

        // A fault inside an alias expansion: the headline names the alias, the cause the fault.
        let f = fixture("templates.commit_trailers = 'broken'\n[template-aliases]\nbroken = 'nope('\n");
        let head = f.head();
        let (tx, _) = detached(&head, "");
        let reason = config_reason(
            f.templates()
                .trailers(tx.repo(), &mut Warnings::default())
                .map(|r| r.is_some()),
        );
        assert_eq!(
            reason.lines().next(),
            Some("Failed to parse template: In alias `broken`")
        );
        // The inner fault, with its position in the alias definition.
        assert!(reason.contains("1 | nope("), "{reason}");
        assert!(reason.contains("expected <identifier> or <expression>"), "{reason}");
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

    /// `templates.commit_summary`: the default renders a bookmarked commit with its refs
    /// ("<bookmark> | <subject>"), a custom template its own text, and an unparsable one refuses as
    /// config — its diagnostics never reach the call's warnings.
    #[test]
    fn the_commit_summary_renders_the_template() {
        let f = fixture("");
        let head = f.head();
        let (mut tx, builder) = detached(&head, "B\n");
        let commit = pollster::block_on(builder.write(tx.repo_mut())).expect("write");
        tx.repo_mut().set_local_bookmark_target(
            "b-mark".as_ref(),
            jj_lib::op_store::RefTarget::normal(commit.id().clone()),
        );
        let summary = f.templates().commit_summary(tx.repo(), &commit).expect("summary");
        assert!(summary.ends_with(" b-mark | (empty) B"), "{summary}");

        let f = fixture("templates.commit_summary = 'commit_id.short() ++ \" custom\"'\n");
        let summary = f.templates().commit_summary(tx.repo(), &commit).expect("summary");
        assert_eq!(
            summary,
            format!("{} custom", &jj_lib::object_id::ObjectId::hex(commit.id())[..12])
        );

        let f = fixture("templates.commit_summary = 'nope('\n");
        let reason = config_reason(f.templates().commit_summary(tx.repo(), &commit));
        assert_eq!(reason.lines().next(), Some("Failed to parse template: Syntax error"));

        let f = fixture("templates.commit_summary = 1\n");
        let reason = config_reason(f.templates().commit_summary(tx.repo(), &commit));
        assert!(reason.contains("templates.commit_summary"), "{reason}");
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

    /// The start-up environment's warnings: a bad alias entry warns once per call, however often
    /// the table is loaded and however many templates are parsed; a short-prefixes index that does
    /// not load is a template diagnostic.
    #[test]
    fn the_start_up_warns_once_and_diagnostics_are_template_warnings() {
        let (_tmp, repo, config) =
            repo_with("[template-aliases]\n'x(' = '1'\n\n[revsets]\nshort-prefixes = 'missing'\n");
        let mut sink = Warnings::default();
        let env = CommandEnv::load(repo.workspace(), &config, &mut sink).expect("start-up");
        super::load_aliases(&config, &mut sink).expect("loads again");
        let head = pollster::block_on(repo.workspace().repo_loader().load_at_head()).expect("head");
        let templates = Templates::new(&config, &env.immutable, &env.template_startup, repo.workspace());
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

    /// An empty `revsets.short-prefixes` is no expression: the id-prefix context disambiguates
    /// within every commit, and a template using it still parses and renders.
    #[test]
    fn an_empty_short_prefixes_text_renders_without_an_expression() {
        let f = fixture("revsets.short-prefixes = ''\n");
        assert!(f.env.template_startup.short_prefixes.is_none());
        let head = f.head();
        let (_tx, builder) = detached(&head, "x\n");
        let commit = super::write_hidden(&builder).expect("hidden");
        let templates = f.templates();
        let renderer = templates
            .parse_commit(head.as_ref(), "change_id.shortest()", &mut Warnings::default())
            .expect("parses");
        assert!(!renderer.format_plain_text(&commit).is_empty());
    }

    /// The short-prefixes loader: a text that does not parse refuses with the CLI's text, a
    /// non-string value names the key, an empty text is no expression, and a diagnosed text warns
    /// once per call however often it is parsed.
    #[test]
    fn the_short_prefixes_loader_refuses_and_warns_once() {
        let load = |toml: &str, sink: &mut Warnings| {
            let (_tmp, repo, config) = repo_with(toml);
            let revset = crate::revset::revset_config(&config, sink).expect("revset config");
            let workspace = (repo.workspace().workspace_root(), repo.workspace().workspace_name());
            let first = super::load_short_prefixes(workspace, &revset, &config, sink);
            let second = super::load_short_prefixes(workspace, &revset, &config, sink);
            first.map(|e| (e.is_some(), second.expect("same text").is_some()))
        };
        let reason = |result: Result<(bool, bool), crate::ConfigError>| {
            let crate::ConfigError::Load { reason } = result.expect_err("refused");
            reason
        };

        let broken = reason(load("revsets.short-prefixes = '('\n", &mut Warnings::default()));
        assert!(broken.starts_with("Invalid `revsets.short-prefixes`: "), "{broken}");
        let typed = reason(load("revsets.short-prefixes = 1\n", &mut Warnings::default()));
        assert!(typed.contains("revsets.short-prefixes"), "{typed}");

        let mut sink = Warnings::default();
        assert_eq!(
            load("revsets.short-prefixes = ''\n", &mut sink).expect("empty"),
            (false, false)
        );
        assert!(sink.take().is_empty());

        assert_eq!(
            load("revsets.short-prefixes = 'diff_contains(\"x\")'\n", &mut sink).expect("parses"),
            (true, true)
        );
        let warnings = sink.take();
        assert_eq!(warnings.len(), 1, "{warnings:?}");
        assert_eq!(warnings[0].kind, WarningKind::RevsetDiagnostic);
        assert!(
            warnings[0].message.starts_with("In `revsets.short-prefixes`\n"),
            "{warnings:?}"
        );
    }
}
