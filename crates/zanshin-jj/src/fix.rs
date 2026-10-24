// SPDX-License-Identifier: MIT

//! `fix.rs` — `jj fix` (Story 9.9), ported step for step from `cmd_fix`
//! (`cli/src/commands/fix.rs` @ v0.46.0): the `fix.tools` config first ([`get_tools_config`]),
//! then the source revisions (`revsets.fix` by default) checked rewritable, their descendants'
//! files run through the matching tools by jj-lib's `fix_files` with a `ParallelFileFixer`, and
//! the finish with the CLI's `fixed <n> commits`.
//!
//! The tool runner is the CLI's (`fix_one_file`, `run_tool`, `compute_regions_to_format`), and so
//! is the tool config's shape: `RawToolConfig` and `CommandNameAndArgs` (`cli/src/config.rs:1053-1152`
//! @ v0.46.0, with `split_name_and_args` and the `$variable` interpolation) are ported privately —
//! jj-cli's library is linked for its template engine only. A tool runs with the workspace root as
//! its working directory, `$path` = the file's repo path and `$root` = the workspace root, the
//! file's content on stdin and the login shell's environment when the app adopted one
//! ([`crate::environment::apply_to_tool`]); a tool that cannot start or exits non-zero is
//! skipped for that file, as in the CLI, and warns.
//!
//! Divergences, deliberate:
//!
//! - `paths` are the house's prefix paths ([`crate::mutate::build_matcher`]), not filesets;
//! - what a tool writes to stderr is data — [`FixResult::tool_stderr`] — where the CLI copies it
//!   to the terminal under `<path>:`;
//! - the per-file warnings and the stderr records arrive from rayon's threads and are sorted (by
//!   message; by path, then text) — the CLI's interleaving is rayon's;
//! - the status line `Fixed N commits of M checked.` is the result's two counts.

use std::borrow::Cow;
use std::collections::HashMap;
use std::ffi::OsString;
use std::io::Write as _;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{LazyLock, Mutex, PoisonError};

use futures::AsyncReadExt as _;
use jj_lib::backend::FileId;
use jj_lib::config::StackedConfig;
use jj_lib::fileset::{
    self, FilePatternParseError, FilesetAliasesMap, FilesetDiagnostics, FilesetExpression, FilesetParseContext,
    FilesetParseError, FilesetParseErrorKind,
};
use jj_lib::fix::{
    compute_changed_ranges, compute_file_line_count, fix_files, FileToFix, FixError, LineRange, ParallelFileFixer,
    RegionsToFormat,
};
use jj_lib::matchers::Matcher;
use jj_lib::repo_path::RepoPathBuf;
use jj_lib::store::Store;
use jj_lib::ui_path::{RepoPathUiConverter, UiPathParseError};
use jj_lib::workspace::Workspace;
use regex::Regex;

use crate::arrange::{commits_of, target_expression};
use crate::mutate::{
    be, build_matcher, cfg, finish_verb, guard_rewritable, mutation_result, no_op_result, warn_unmatched, MutateError,
    MutationResult,
};
use crate::op_support::start_repo_transaction;
use crate::snapshot::VerbContext;
use crate::warning::{self, Load, Warning, WarningKind, Warnings};
use crate::ChangeId;

/// [`crate::Repo::fix`]'s arguments — the CLI's `jj fix` flags, one field each (Story 9.9).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FixOptions {
    /// `-s/--source`, repeatable: fix these revisions and their descendants. Empty is the CLI's
    /// default, the `revsets.fix` setting (jj's default `reachable(@, mutable())`).
    pub source: Vec<ChangeId>,
    /// Fix only these paths — repo-relative PREFIXES as for [`crate::Repo::restore`]; empty is
    /// every path, `""` the root. A path absent from the tree of every source and descendant
    /// (fixed or not) warns [`WarningKind::PathsUnmatched`].
    pub paths: Vec<String>,
    /// `--include-unchanged-files`: fix the files a revision did not change too.
    pub include_unchanged_files: bool,
    /// `-a/--all-lines`: hand the tools every line, not only the changed ones.
    pub all_lines: bool,
}

/// Outcome of a successful [`crate::Repo::fix`] (Story 9.9).
#[derive(Debug)]
pub struct FixResult {
    /// The shared mutation contract; `new_op_id` is the pre-call head when nothing was fixed.
    pub mutation: MutationResult,
    /// Commits rewritten because a tool changed a file — the operation's `fixed <n> commits`.
    /// Saturates at `u32::MAX`.
    pub num_fixed_commits: u32,
    /// Commits visited: every source and descendant, whether or not a file of it matched a
    /// tool's patterns. Saturates at `u32::MAX`.
    pub num_checked_commits: u32,
    /// What the tools wrote to stderr, one entry per tool run that wrote any, sorted by path
    /// (then text).
    pub tool_stderr: Vec<FixToolStderr>,
}

/// What one tool run wrote to stderr (Story 9.9) — the CLI copies it to the terminal under
/// `<path>:`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FixToolStderr {
    /// The file the tool ran on, as the CLI renders it from the workspace root.
    pub path: String,
    /// The tool's stderr, lossy UTF-8.
    pub stderr: String,
}

// ── The tool config (`cli/src/commands/fix.rs`, `cli/src/config.rs` @ v0.46.0) ──────────────

/// Command name and arguments specified by config — the CLI's `CommandNameAndArgs`
/// (`cli/src/config.rs:1053-1135` @ v0.46.0): a string (split at spaces, or shell-like when it
/// holds a quote), a non-empty array, or `{ env, command }`.
#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize)]
#[serde(untagged)]
enum CommandNameAndArgs {
    String(String),
    Vec(NonEmptyCommandArgsVec),
    Structured {
        env: HashMap<String, String>,
        command: NonEmptyCommandArgsVec,
    },
}

/// An array with a command name — the CLI's `NonEmptyCommandArgsVec` (`config.rs:1238-1252`).
#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize)]
#[serde(try_from = "Vec<String>")]
struct NonEmptyCommandArgsVec(Vec<String>);

impl TryFrom<Vec<String>> for NonEmptyCommandArgsVec {
    type Error = &'static str;

    fn try_from(args: Vec<String>) -> Result<Self, Self::Error> {
        if args.is_empty() {
            Err("command arguments should not be empty")
        } else {
            Ok(Self(args))
        }
    }
}

/// The CLI's `$variable` pattern (`config.rs:1213`) — not interested in `$UPPER_CASE`.
static VARIABLE: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(r"\$[a-z0-9_]+\b").ok());

impl CommandNameAndArgs {
    /// The command name without arguments.
    fn split_name(&self) -> Cow<'_, str> {
        self.split_name_and_args().0
    }

    /// The command name and arguments (`config.rs:1074-1095`); each may be empty.
    fn split_name_and_args(&self) -> (Cow<'_, str>, Cow<'_, [String]>) {
        match self {
            Self::String(s) => {
                if s.contains('"') || s.contains('\'') {
                    let mut parts = shlex::Shlex::new(s);
                    let res = (parts.next().unwrap_or_default().into(), parts.by_ref().collect());
                    if !parts.had_error {
                        return res;
                    }
                }
                let mut args = s.split(' ').map(ToOwned::to_owned);
                (args.next().unwrap_or_default().into(), args.collect())
            }
            Self::Vec(NonEmptyCommandArgsVec(a)) => (Cow::Borrowed(&a[0]), Cow::Borrowed(&a[1..])),
            Self::Structured { command, .. } => (Cow::Borrowed(&command.0[0]), Cow::Borrowed(&command.0[1..])),
        }
    }

    /// The process builder with `variables` interpolated (`config.rs:1112-1125`), plus the
    /// adopted environment under the command's own `env`.
    fn to_command_with_variables(&self, variables: &HashMap<&str, &str>) -> Command {
        let (name, args) = self.split_name_and_args();
        let mut command = Command::new(interpolate(&name, variables));
        crate::environment::apply_to_tool(&mut command);
        if let Self::Structured { env, .. } = self {
            command.envs(env);
        }
        command.args(args.iter().map(|arg| interpolate(arg, variables)));
        command
    }
}

/// `interpolate_variables_single` (`config.rs:1226-1242`): every known `$name` replaced, an
/// unknown one kept.
fn interpolate(arg: &str, variables: &HashMap<&str, &str>) -> OsString {
    let mut buf = OsString::new();
    let mut end = 0;
    for m in VARIABLE.iter().flat_map(|re| re.find_iter(arg)) {
        if let Some(value) = variables.get(&m.as_str()[1..]) {
            buf.push(&arg[end..m.start()]);
            buf.push(value);
            end = m.end();
        }
    }
    buf.push(&arg[end..]);
    buf
}

/// One `fix.tools` entry as configured — the CLI's `RawToolConfig`.
#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
struct RawToolConfig {
    command: CommandNameAndArgs,
    patterns: Vec<String>,
    #[serde(default = "default_tool_enabled")]
    enabled: bool,
    #[serde(default)]
    line_range_args: Vec<String>,
    #[serde(default)]
    run_tool_if_zero_line_ranges: bool,
}

fn default_tool_enabled() -> bool {
    true
}

/// One usable `fix.tools` entry — the CLI's `ToolConfig`.
#[derive(Debug)]
struct ToolConfig {
    command: CommandNameAndArgs,
    matcher: Box<dyn Matcher>,
    enabled: bool,
    line_range_args: Vec<String>,
    run_tool_if_zero_line_ranges: bool,
}

/// The `fix.tools` table — the CLI's `get_tools_config`: the entries in key order (so errors are
/// deterministic), each deserialized, its patterns parsed with the config fileset context (the
/// `[fileset-aliases]`, paths relative to the root — `fileset_parse_context_for_config`), its
/// diagnostics warned "In `fix.tools.<name>`"; then the disabled ones dropped.
///
/// # Errors
///
/// - [`MutateError::Config`] — an entry does not deserialize, sets `run-tool-if-zero-line-ranges`
///   without `line-range-args`, no entry is configured ("No `fix.tools` are configured"), or none
///   is enabled ("At least one entry of `fix.tools` must be enabled."); the `[fileset-aliases]`
///   table does not read.
/// - [`MutateError::InvalidInput`] — a pattern does not parse: "Failed to parse fileset: <kind>",
///   the CLI's `Caused by:` lines, its hint.
fn get_tools_config(config: &StackedConfig, sink: &mut Warnings) -> Result<Vec<ToolConfig>, MutateError> {
    let (aliases_map, warnings): (FilesetAliasesMap, _) =
        crate::revset::build_aliases_map(config, "fileset-aliases").map_err(cfg)?;
    sink.record_load(Load::FilesetAliases, warnings);
    let path_converter = RepoPathUiConverter::Fs {
        cwd: std::path::PathBuf::new(),
        base: std::path::PathBuf::new(),
    };
    let context = FilesetParseContext {
        aliases_map: &aliases_map,
        path_converter: &path_converter,
    };
    let mut names: Vec<&str> = config.table_keys("fix.tools").collect();
    names.sort_unstable();
    let mut tools = Vec::with_capacity(names.len());
    for name in names {
        let mut diagnostics = FilesetDiagnostics::new();
        let tool: RawToolConfig = config
            .get(["fix", "tools", name])
            .map_err(|e| cfg(crate::config::value_error(&e)))?;
        let expressions = tool
            .patterns
            .iter()
            .map(|pattern| fileset::parse(&mut diagnostics, pattern, &context))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| fileset_parse_error(&e))?;
        if tool.line_range_args.is_empty() && tool.run_tool_if_zero_line_ranges {
            return Err(cfg(
                "run-tool-if-zero-line-ranges can only be set when line-range-args is set",
            ));
        }
        sink.extend(warning::parse_diagnostics(
            WarningKind::FilesetDiagnostic,
            &format!("In `fix.tools.{name}`"),
            &diagnostics,
        ));
        tools.push(ToolConfig {
            command: tool.command,
            matcher: FilesetExpression::union_all(expressions).to_matcher(),
            enabled: tool.enabled,
            line_range_args: tool.line_range_args,
            run_tool_if_zero_line_ranges: tool.run_tool_if_zero_line_ranges,
        });
    }
    if tools.is_empty() {
        return Err(cfg("No `fix.tools` are configured"));
    }
    tools.retain(|tool| tool.enabled);
    if tools.is_empty() {
        return Err(cfg("At least one entry of `fix.tools` must be enabled."));
    }
    Ok(tools)
}

/// The CLI's `From<FilesetParseError>` (`command_error.rs:658-666` @ v0.46.0): a user error
/// "Failed to parse fileset: <kind>", its `Caused by:` lines, and `fileset_parse_error_hint`.
fn fileset_parse_error(err: &FilesetParseError) -> MutateError {
    let mut lines = vec![format!("Failed to parse fileset: {}", err.kind())];
    lines.extend(warning::caused_by(Some(err)));
    MutateError::InvalidInput {
        reason: lines.join("\n"),
        hints: fileset_parse_error_hint(err).into_iter().collect(),
    }
}

/// `fileset_parse_error_hint` (`command_error.rs:857-874` @ v0.46.0).
fn fileset_parse_error_hint(err: &FilesetParseError) -> Option<String> {
    match err.kind() {
        FilesetParseErrorKind::SyntaxError => Some(
            "See https://docs.jj-vcs.dev/latest/filesets/ or use `jj help -k filesets` for filesets syntax and how \
             to match file paths."
                .to_owned(),
        ),
        FilesetParseErrorKind::NoSuchFunction { candidates, .. } => similarity_hint(candidates),
        FilesetParseErrorKind::InvalidArguments { .. } | FilesetParseErrorKind::Expression(_) => {
            source_parse_error_hint(err)
        }
        FilesetParseErrorKind::RedefinedFunctionParameter
        | FilesetParseErrorKind::InAliasExpansion(_)
        | FilesetParseErrorKind::InParameterExpansion(_)
        | FilesetParseErrorKind::RecursiveAlias(_) => None,
    }
}

/// `format_similarity_hint` (`command_error.rs:229-237` @ v0.46.0).
fn similarity_hint(candidates: &[String]) -> Option<String> {
    if candidates.is_empty() {
        return None;
    }
    let quoted: Vec<String> = candidates.iter().map(|name| format!("`{name}`")).collect();
    Some(format!("Did you mean {}?", quoted.join(", ")))
}

/// `find_source_parse_error_hint` (`command_error.rs:789-816` @ v0.46.0) for the sources a fileset
/// error carries: a file pattern's, or a nested fileset error's.
fn source_parse_error_hint(err: &dyn std::error::Error) -> Option<String> {
    let source = err.source()?;
    if let Some(source) = source.downcast_ref::<FilePatternParseError>() {
        file_pattern_parse_error_hint(source)
    } else {
        source
            .downcast_ref::<FilesetParseError>()
            .and_then(fileset_parse_error_hint)
    }
}

/// `file_pattern_parse_error_hint` (`command_error.rs:840-855` @ v0.46.0).
fn file_pattern_parse_error_hint(err: &FilePatternParseError) -> Option<String> {
    match err {
        FilePatternParseError::InvalidKind(_) => Some(
            "See https://docs.jj-vcs.dev/latest/filesets/#file-patterns or `jj help -k filesets` for valid prefixes."
                .to_owned(),
        ),
        FilePatternParseError::UiPath(UiPathParseError::Fs(e)) => RepoPathBuf::from_relative_path(&e.input)
            .ok()
            .map(|path| format!(r"Consider using root:{path:?} to specify repo-relative path")),
        FilePatternParseError::RelativePath(_) | FilePatternParseError::GlobPattern(_) => None,
    }
}

// ── The tool runner (`cli/src/commands/fix.rs` @ v0.46.0) ─────────────────────────────────

/// What every file fix shares: the tools, the flags, and the collectors the rayon threads write
/// their warnings and stderr records to.
struct Runner<'a> {
    workspace_root: &'a Path,
    tools: &'a [ToolConfig],
    all_lines: bool,
    warnings: Mutex<Vec<Warning>>,
    tool_stderr: Mutex<Vec<FixToolStderr>>,
}

impl Runner<'_> {
    fn warn(&self, kind: WarningKind, message: String) {
        self.warnings
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(warning::local(kind, message));
    }

    /// The file's path as the CLI renders it from the workspace root.
    fn ui_path(&self, file: &FileToFix) -> String {
        warning::ui_path(self.workspace_root, &file.repo_path)
    }

    /// `fix_one_file`: the matching tools run in order, each on the previous one's output; the
    /// new content written when it changed. A failing tool is skipped. Empty files and files no
    /// tool matches are left alone.
    async fn fix_one_file(&self, store: &Store, file: &FileToFix) -> Result<Option<FileId>, FixError> {
        let matching: Vec<&ToolConfig> = self
            .tools
            .iter()
            .filter(|tool| tool.matcher.matches(&file.repo_path))
            .collect();
        if matching.is_empty() {
            return Ok(None);
        }
        let old_content = read_file(store, file, &file.file_id).await?;
        if old_content.is_empty() {
            return Ok(None);
        }
        let base_content = match &file.base_file_id {
            Some(base) if !self.all_lines && matching.iter().any(|tool| !tool.line_range_args.is_empty()) => {
                Some(read_file(store, file, base).await?)
            }
            _ => None,
        };
        let new_content = matching.iter().fold(old_content.clone(), |previous, tool| {
            let mut extra_args = Vec::new();
            if !tool.line_range_args.is_empty() {
                let RegionsToFormat::LineRanges(ranges) = compute_regions_to_format(base_content.as_deref(), &previous);
                if ranges.is_empty() && !tool.run_tool_if_zero_line_ranges {
                    return previous;
                }
                for range in ranges {
                    for arg in &tool.line_range_args {
                        extra_args.push(
                            arg.replace("$first", &range.first.to_string())
                                .replace("$last", &range.last.to_string()),
                        );
                    }
                }
            }
            self.run_tool(&tool.command, file, &previous, &extra_args)
                .unwrap_or(previous)
        });
        if new_content == old_content {
            return Ok(None);
        }
        let id = store.write_file(&file.repo_path, &mut new_content.as_slice()).await?;
        Ok(Some(id))
    }

    /// `run_tool`: the tool on `content`, its stdout the new content — `None` when it could not
    /// start or exited non-zero (both warned). What it wrote to stderr is recorded either way.
    fn run_tool(
        &self,
        tool: &CommandNameAndArgs,
        file: &FileToFix,
        content: &[u8],
        extra_args: &[String],
    ) -> Option<Vec<u8>> {
        let mut variables: HashMap<&str, &str> = HashMap::new();
        variables.insert("path", file.repo_path.as_internal_file_string());
        // A non-UTF-8 workspace root leaves `$root` unset, as in the CLI.
        if let Some(root) = self.workspace_root.to_str() {
            variables.insert("root", root);
        }
        let mut command = tool.to_command_with_variables(&variables);
        command.args(extra_args);
        tracing::debug!(?command, path = ?file.repo_path, "spawning fix tool");
        let spawned = command
            .current_dir(self.workspace_root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn();
        let Ok(mut child) = spawned else {
            self.warn(
                WarningKind::FixToolStartFailed,
                format!("Failed to start `{}`.", tool.split_name()),
            );
            return None;
        };
        let stdin = child.stdin.take();
        let waited = std::thread::scope(|s| {
            s.spawn(move || stdin.map(|mut stdin| stdin.write_all(content)));
            child.wait_with_output()
        });
        let output = match waited {
            Ok(output) => output,
            // The CLI keeps the old content without a warning. Logged so a silent no-op can be told
            // from "nothing to fix": under a Dart host the VM may reap the child first (`ECHILD`).
            // The path is user data, so it is logged at debug only.
            Err(e) => {
                tracing::warn!(tool = %tool.split_name(), error = %e, "fix tool's exit status lost; old content kept");
                tracing::debug!(tool = %tool.split_name(), path = ?file.repo_path, "fix tool's exit status lost");
                return None;
            }
        };
        tracing::debug!(?command, status = ?output.status, "fix tool exited");
        if !output.stderr.is_empty() {
            self.tool_stderr
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(FixToolStderr {
                    path: self.ui_path(file),
                    stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
                });
        }
        if output.status.success() {
            return Some(output.stdout);
        }
        self.warn(
            WarningKind::FixToolFailed,
            format!(
                "Fix tool `{}` exited with non-zero exit code for `{}`",
                tool.split_name(),
                self.ui_path(file)
            ),
        );
        None
    }
}

/// A file's content at `id`.
async fn read_file(store: &Store, file: &FileToFix, id: &FileId) -> Result<Vec<u8>, FixError> {
    let mut content = Vec::new();
    store
        .read_file(&file.repo_path, id)
        .await?
        .read_to_end(&mut content)
        .await?;
    Ok(content)
}

/// The modified line ranges between the base and the current file — the CLI's
/// `compute_regions_to_format`: none for an empty file, the changed ranges against a base, else
/// the whole file.
fn compute_regions_to_format(base_content: Option<&[u8]>, current_content: &[u8]) -> RegionsToFormat {
    if current_content.is_empty() {
        RegionsToFormat::LineRanges(vec![])
    } else if let Some(base) = base_content {
        compute_changed_ranges(base, current_content)
    } else {
        RegionsToFormat::LineRanges(vec![LineRange {
            first: 1,
            last: compute_file_line_count(current_content),
        }])
    }
}

/// An `i32` count of jj-lib's as the result's `u32`, saturating.
fn count(n: i32) -> u32 {
    u32::try_from(n.max(0)).unwrap_or(u32::MAX)
}

/// `jj fix` (Story 9.9) — see [`crate::Repo::fix`].
///
/// # Errors
///
/// See [`crate::Repo::fix`].
pub(crate) fn fix(
    workspace: &mut Workspace,
    ctx: &mut VerbContext,
    options: &FixOptions,
) -> Result<FixResult, MutateError> {
    let tools = get_tools_config(&ctx.config, &mut ctx.warnings)?;
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let workspace_name = workspace.workspace_name().to_owned();
    let mut tx = start_repo_transaction(&readonly, &workspace_name);
    let repo = readonly.as_ref();

    let target = target_expression(&tx, workspace, ctx, &options.source, "revsets.fix")?;
    let roots: Vec<_> = commits_of(repo, &target)?.iter().map(|c| c.id().clone()).collect();
    guard_rewritable(&tx, &ctx.templates(workspace), &roots)?;
    let commits = commits_of(repo, &target.descendants())?;
    let commit_ids = commits.iter().map(|c| c.id().clone()).collect();
    let trees: Vec<_> = commits.iter().map(jj_lib::commit::Commit::tree).collect();

    let matcher = build_matcher(&options.paths)?;
    warn_unmatched(
        workspace,
        &mut ctx.warnings,
        &options.paths,
        &trees.iter().collect::<Vec<_>>(),
    )?;

    let runner = Runner {
        workspace_root: workspace.workspace_root(),
        tools: &tools,
        all_lines: options.all_lines,
        warnings: Mutex::default(),
        tool_stderr: Mutex::default(),
    };
    let mut fixer =
        ParallelFileFixer::new(|store: &Store, file: &FileToFix| pollster::block_on(runner.fix_one_file(store, file)));
    let outcome = pollster::block_on(fix_files(
        commit_ids,
        matcher.as_ref(),
        options.include_unchanged_files,
        tx.repo_mut(),
        &mut fixer,
    ));
    // The tools' warnings are the call's on a failure too: the CLI printed them as they ran.
    let mut warnings = runner.warnings.into_inner().unwrap_or_else(PoisonError::into_inner);
    warnings.sort_by(|a, b| a.message.cmp(&b.message));
    ctx.warnings.extend(warnings);
    let summary = outcome.map_err(be)?;
    let mut tool_stderr = runner.tool_stderr.into_inner().unwrap_or_else(PoisonError::into_inner);
    tool_stderr.sort_by(|a, b| (&a.path, &a.stderr).cmp(&(&b.path, &b.stderr)));

    let num_fixed_commits = count(summary.num_fixed_commits);
    let num_checked_commits = count(summary.num_checked_commits);
    // `WorkspaceCommandTransaction::finish`'s "Nothing changed." guard (`cli_util.rs:2852`).
    let mutation = if tx.repo().has_changes() {
        let description = format!("fixed {} commits", summary.num_fixed_commits);
        let finish = finish_verb(workspace, tx, &description, ctx)?;
        mutation_result(&finish, Vec::new(), Vec::new())
    } else {
        drop(tx);
        no_op_result(&workspace_name, &readonly)?
    };
    Ok(FixResult {
        mutation,
        num_fixed_commits,
        num_checked_commits,
        tool_stderr,
    })
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
    use jj_lib::fix::{LineRange, RegionsToFormat};

    use super::{compute_regions_to_format, count, get_tools_config, interpolate, CommandNameAndArgs};
    use crate::mutate::MutateError;
    use crate::warning::Warnings;

    fn line_range(first: usize, last: usize) -> LineRange {
        LineRange::new(first, last)
    }

    /// The CLI's own `test_compute_regions_to_format_default` (`fix.rs` @ v0.46.0).
    #[test]
    fn compute_regions_to_format_default() {
        assert_eq!(
            compute_regions_to_format(None, b"a\nb\nc\n"),
            RegionsToFormat::LineRanges(vec![line_range(1, 3)])
        );
        assert_eq!(
            compute_regions_to_format(Some(b""), b"a\nb\nc\n"),
            RegionsToFormat::LineRanges(vec![line_range(1, 3)])
        );
        assert_eq!(
            compute_regions_to_format(Some(b"a\nB\nc\n"), b"a\nb\nc\n"),
            RegionsToFormat::LineRanges(vec![line_range(2, 2)])
        );
        assert_eq!(
            compute_regions_to_format(Some(b"a\nb\nc\nd\n"), b"a\nb\nc\n"),
            RegionsToFormat::LineRanges(vec![])
        );
        assert_eq!(
            compute_regions_to_format(Some(b"A\nb\nC\n"), b"a\nb\nc\n"),
            RegionsToFormat::LineRanges(vec![line_range(1, 1), line_range(3, 3)])
        );
        assert_eq!(
            compute_regions_to_format(Some(b"a\nb\nc\n"), b""),
            RegionsToFormat::LineRanges(vec![])
        );
    }

    fn command(toml: &str) -> CommandNameAndArgs {
        let layer = ConfigLayer::parse(ConfigSource::User, toml).expect("toml");
        let mut config = StackedConfig::empty();
        config.add_layer(layer);
        config.get("command").expect("a command")
    }

    fn split(command: &CommandNameAndArgs) -> (String, Vec<String>) {
        let (name, args) = command.split_name_and_args();
        (name.into_owned(), args.into_owned())
    }

    /// `split_name_and_args`' three shapes, as the CLI's tests pin them.
    #[test]
    fn command_name_and_args_split_as_the_cli_splits_them() {
        let words = |list: &[&str]| list.iter().map(|w| (*w).to_owned()).collect::<Vec<_>>();
        assert_eq!(
            split(&command("command = 'tr a-z A-Z'")),
            ("tr".to_owned(), words(&["a-z", "A-Z"]))
        );
        assert_eq!(
            split(&command(r#"command = "sed 's/a b/c/'""#)),
            ("sed".to_owned(), words(&["s/a b/c/"])),
            "a quote splits shell-like"
        );
        assert_eq!(
            split(&command(r#"command = "echo 'unterminated""#)),
            ("echo".to_owned(), words(&["'unterminated"])),
            "a shell-like split that fails falls back to spaces"
        );
        assert_eq!(
            split(&command("command = ['a b', 'c']")),
            ("a b".to_owned(), words(&["c"]))
        );
        let structured = command("command = { env = { X = '1' }, command = ['x', '-y'] }");
        assert_eq!(split(&structured), ("x".to_owned(), words(&["-y"])));
        assert_eq!(structured.split_name(), "x");
        let built = structured.to_command_with_variables(&HashMap::new());
        assert!(built.get_envs().any(|(k, v)| k == "X" && v == Some("1".as_ref())));

        let layer = ConfigLayer::parse(ConfigSource::User, "command = []").expect("toml");
        let mut config = StackedConfig::empty();
        config.add_layer(layer);
        assert!(
            config.get::<CommandNameAndArgs>("command").is_err(),
            "an empty array is refused"
        );
    }

    #[test]
    fn interpolate_replaces_known_lowercase_variables_only() {
        let vars = HashMap::from([("path", "a/b.txt"), ("root", "/w")]);
        assert_eq!(interpolate("--file=$path", &vars), "--file=a/b.txt");
        assert_eq!(interpolate("$root/$path $nope $PATH", &vars), "/w/a/b.txt $nope $PATH");
        let built = command("command = ['$root/fmt', '$path']").to_command_with_variables(&vars);
        assert_eq!(built.get_program(), "/w/fmt");
        assert_eq!(built.get_args().collect::<Vec<_>>(), ["a/b.txt"]);
    }

    #[test]
    fn count_saturates() {
        assert_eq!(count(3), 3);
        assert_eq!(count(-1), 0);
    }

    fn tools(toml: &str) -> (Result<usize, MutateError>, Warnings) {
        let mut config = StackedConfig::empty();
        config.add_layer(ConfigLayer::parse(ConfigSource::User, toml).expect("toml"));
        let mut sink = Warnings::default();
        (get_tools_config(&config, &mut sink).map(|t| t.len()), sink)
    }

    fn refusal(toml: &str) -> MutateError {
        tools(toml).0.expect_err("refused")
    }

    /// `get_tools_config`'s refusals and its disabled-entry filter, with the CLI's texts.
    #[test]
    fn get_tools_config_refuses_as_the_cli_does() {
        assert!(matches!(
            refusal(""),
            MutateError::Config { reason } if reason == "No `fix.tools` are configured"
        ));
        assert!(matches!(
            refusal("fix.tools.a = { command = ['x'], patterns = ['all()'], enabled = false }"),
            MutateError::Config { reason } if reason == "At least one entry of `fix.tools` must be enabled."
        ));
        assert!(matches!(
            refusal("fix.tools.a = { command = ['x'], patterns = ['all()'], run-tool-if-zero-line-ranges = true }"),
            MutateError::Config { reason }
                if reason == "run-tool-if-zero-line-ranges can only be set when line-range-args is set"
        ));
        assert!(matches!(
            refusal("fix.tools.a = { command = ['x'] }"),
            MutateError::Config { reason } if reason.contains("fix.tools.a")
        ));
        let (enabled, _) = tools(
            "fix.tools.a = { command = ['x'], patterns = ['all()'] }\n\
             fix.tools.b = { command = ['x'], patterns = ['all()'], enabled = false }\n",
        );
        assert_eq!(enabled.expect("a usable entry"), 1);
    }

    /// A pattern that does not parse is the CLI's user error, its `Caused by:` lines and hint.
    #[test]
    fn get_tools_config_reports_a_bad_pattern_with_the_clis_hints() {
        let syntax = refusal("fix.tools.a = { command = ['x'], patterns = ['('] }");
        assert!(matches!(syntax, MutateError::InvalidInput { .. }), "{syntax:?}");
        assert!(
            syntax
                .to_string()
                .starts_with("invalid input: Failed to parse fileset: Syntax error\nCaused by:"),
            "{syntax}"
        );
        assert_eq!(
            syntax.hints(),
            ["See https://docs.jj-vcs.dev/latest/filesets/ or use `jj help -k filesets` for filesets syntax and how to match file paths."]
        );
        let kind = refusal("fix.tools.a = { command = ['x'], patterns = ['bogus:x'] }");
        assert!(kind.hints()[0].contains("#file-patterns"), "{kind:?}");
        let function = refusal("fix.tools.a = { command = ['x'], patterns = ['al()'] }");
        assert_eq!(function.hints(), ["Did you mean `all`?"], "{function:?}");
        let unknown = refusal("fix.tools.a = { command = ['x'], patterns = ['zzzzzzzz()'] }");
        assert!(unknown.hints().is_empty(), "{unknown:?}");
        let arguments = refusal("fix.tools.a = { command = ['x'], patterns = ['all(x)'] }");
        assert!(arguments.hints().is_empty(), "{arguments:?}");
    }
}
