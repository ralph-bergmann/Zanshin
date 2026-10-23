// SPDX-License-Identifier: MIT

//! Story 9.9 — `Repo::fix`, one witness per row of the I/O matrix, read back through the repo,
//! plus the CLI's deprecated `fix.tools.<name>.line-range-arg` migration.
//!
//! The history is `rebase.rs`'s: `A (a.txt) → B (b.txt, bookmark b-mark) → C (c.txt) = @`, each
//! file holding its lower-case letter. The tools are stock macOS binaries (`tr`, `sh`, `false`),
//! standing in for the CLI tests' fake formatter. The CLI comparison of the same rows lives in the
//! parity oracle (`crates/zanshin-parity`).

use zanshin_jj::{ChangeId, FixOptions, FixResult, MutateError, WarningKind};

use crate::rebase::{add, assert_op, base, head_op, reconfigure, Fx};

/// `tr a-z A-Z` on every `*.txt`.
const UPPER: &str = "[fix.tools.upper]\ncommand = ['tr', 'a-z', 'A-Z']\npatterns = [\"glob:'*.txt'\"]\n";

/// `id`'s version of `path`.
fn file(fx: &mut Fx, id: &ChangeId, path: &str) -> String {
    let shown = fx
        .repo
        .file_show(Some(id.clone()), &[path.to_owned()])
        .expect("file show");
    let _ = fx.repo.take_warnings();
    String::from_utf8(shown.files[0].content.clone()).expect("utf-8")
}

fn configured(config: &str) -> Fx {
    let mut fx = base();
    reconfigure(&mut fx, config);
    fx
}

fn fix(fx: &mut Fx, options: &FixOptions) -> FixResult {
    fx.repo.fix(options).expect("fix")
}

/// [`fix`] with options built from the fixture's ids.
fn fix_with(fx: &mut Fx, options: impl FnOnce(&Fx) -> FixOptions) -> FixResult {
    let options = options(fx);
    fix(fx, &options)
}

/// Asserts `result` wrote no operation.
fn assert_no_op(fx: &Fx, before: &(String, String), result: &FixResult) {
    assert_eq!(&head_op(&fx.root), before, "no operation");
    assert_eq!(result.mutation.new_op_id.0, before.0, "new_op_id is the pre-call head");
    assert_eq!(result.num_fixed_commits, 0);
}

#[test]
fn the_default_fixes_every_mutable_revision_reachable_from_the_working_copy() {
    let mut fx = configured(UPPER);
    let result = fix(&mut fx, &FixOptions::default());
    assert_op(&fx, &result.mutation, "fixed 3 commits");
    assert_eq!((result.num_fixed_commits, result.num_checked_commits), (3, 3));
    assert!(result.tool_stderr.is_empty());
    assert_eq!(result.mutation.working_copy_change_id, fx.c);
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    assert_eq!(file(&mut fx, &a, "a.txt"), "A\n");
    assert_eq!(file(&mut fx, &b, "b.txt"), "B\n");
    assert_eq!(file(&mut fx, &c, "a.txt"), "A\n", "a descendant keeps the fix");
    assert_eq!(file(&mut fx, &c, "c.txt"), "C\n");
    assert_eq!(
        std::fs::read_to_string(fx.root.join("c.txt")).expect("c.txt"),
        "C\n",
        "the working copy is updated"
    );
}

#[test]
fn a_source_fixes_it_and_its_descendants_only() {
    let mut fx = configured(UPPER);
    let result = fix_with(&mut fx, |fx| FixOptions {
        source: vec![fx.b.clone()],
        ..FixOptions::default()
    });
    assert_op(&fx, &result.mutation, "fixed 2 commits");
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    assert_eq!(file(&mut fx, &a, "a.txt"), "a\n");
    assert_eq!(file(&mut fx, &b, "b.txt"), "B\n");
    assert_eq!(file(&mut fx, &c, "a.txt"), "a\n", "a.txt changed in no source");
    assert_eq!(file(&mut fx, &c, "c.txt"), "C\n");
}

#[test]
fn paths_restrict_the_fix_and_an_unmatched_one_warns() {
    let mut fx = configured(UPPER);
    let result = fix_with(&mut fx, |_| FixOptions {
        paths: vec!["b.txt".to_owned(), "nope.txt".to_owned()],
        ..FixOptions::default()
    });
    assert_op(&fx, &result.mutation, "fixed 2 commits");
    let warnings = fx.repo.take_warnings();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::PathsUnmatched);
    assert_eq!(warnings[0].message, "No matching entries for paths: nope.txt");
    let (a, c) = (fx.a.clone(), fx.c.clone());
    assert_eq!(file(&mut fx, &a, "a.txt"), "a\n");
    assert_eq!(file(&mut fx, &c, "b.txt"), "B\n");
    assert_eq!(file(&mut fx, &c, "c.txt"), "c\n");
}

#[test]
fn include_unchanged_files_fixes_what_the_revision_did_not_change() {
    let mut fx = configured(UPPER);
    let result = fix_with(&mut fx, |fx| FixOptions {
        source: vec![fx.c.clone()],
        include_unchanged_files: true,
        ..FixOptions::default()
    });
    assert_op(&fx, &result.mutation, "fixed 1 commits");
    let (b, c) = (fx.b.clone(), fx.c.clone());
    assert_eq!(file(&mut fx, &c, "a.txt"), "A\n");
    assert_eq!(file(&mut fx, &b, "b.txt"), "b\n");
}

#[test]
fn nothing_to_fix_writes_no_operation() {
    let mut fx = configured(UPPER);
    fix(&mut fx, &FixOptions::default());
    let before = head_op(&fx.root);
    let again = fix(&mut fx, &FixOptions::default());
    assert_no_op(&fx, &before, &again);
    assert_eq!(again.num_checked_commits, 3);
}

#[test]
fn a_failing_tool_is_skipped_warns_and_reports_its_stderr() {
    let mut fx =
        configured("[fix.tools.fail]\ncommand = ['sh', '-c', 'echo oops >&2; exit 1']\npatterns = ['a.txt']\n");
    let before = head_op(&fx.root);
    let result = fix(&mut fx, &FixOptions::default());
    assert_no_op(&fx, &before, &result);
    assert_eq!(
        result.tool_stderr,
        [zanshin_jj::FixToolStderr {
            path: "a.txt".to_owned(),
            stderr: "oops\n".to_owned(),
        }]
    );
    let warnings = fx.repo.take_warnings();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::FixToolFailed);
    assert_eq!(
        warnings[0].message,
        "Fix tool `sh` exited with non-zero exit code for `a.txt`"
    );

    let mut fx = configured("[fix.tools.fail]\ncommand = 'false'\npatterns = [\"glob:'*.txt'\"]\n");
    let before = head_op(&fx.root);
    let result = fix(&mut fx, &FixOptions::default());
    assert_no_op(&fx, &before, &result);
    assert!(result.tool_stderr.is_empty(), "false writes nothing");
    let warnings = fx.repo.take_warnings();
    let messages: Vec<&str> = warnings.iter().map(|w| w.message.as_str()).collect();
    assert_eq!(
        messages,
        [
            "Fix tool `false` exited with non-zero exit code for `a.txt`",
            "Fix tool `false` exited with non-zero exit code for `b.txt`",
            "Fix tool `false` exited with non-zero exit code for `c.txt`",
        ],
        "one per file, sorted"
    );
}

#[test]
fn a_tool_that_cannot_start_warns_and_fixes_nothing() {
    let mut fx = configured("[fix.tools.gone]\ncommand = ['/nonexistent']\npatterns = ['a.txt']\n");
    let before = head_op(&fx.root);
    let result = fix(&mut fx, &FixOptions::default());
    assert_no_op(&fx, &before, &result);
    let warnings = fx.repo.take_warnings();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::FixToolStartFailed);
    assert_eq!(warnings[0].message, "Failed to start `/nonexistent`.");
}

#[test]
fn tools_see_path_root_and_the_changed_line_ranges() {
    let mut fx = configured(
        "[fix.tools.args]\ncommand = ['sh', '-c', 'cat; echo \"$@\"', 'sh', '$path', '$root']\n\
         patterns = ['a.txt']\nline-range-args = ['--l=$first-$last']\n",
    );
    let root = fx.root.to_str().expect("utf-8 root").to_owned();
    let result = fix_with(&mut fx, |fx| FixOptions {
        source: vec![fx.a.clone()],
        ..FixOptions::default()
    });
    assert_eq!(result.num_fixed_commits, 3, "a.txt is fixed in A and its descendants");
    let a = fx.a.clone();
    assert_eq!(file(&mut fx, &a, "a.txt"), format!("a\na.txt {root} --l=1-1\n"));
}

/// The CLI's deprecated `line-range-arg` is migrated at the start of every call: any verb warns,
/// and `fix` runs with the migrated `line-range-args`.
#[test]
fn a_deprecated_line_range_arg_warns_on_any_verb_and_is_migrated() {
    let deprecated = "Deprecated repo-level config: fix.tools.t.line-range-arg is updated to \
                      fix.tools.t.line-range-args = [\"--l=$first\"]";
    let mut fx = configured(
        "[fix.tools.t]\ncommand = ['sh', '-c', 'cat; echo \"$@\"', 'sh']\npatterns = ['a.txt']\n\
         line-range-arg = \"--l=$first\"\n",
    );
    fx.repo.snapshot().expect("snapshot");
    let warnings = fx.repo.take_warnings();
    let found: Vec<&str> = warnings
        .iter()
        .filter(|w| w.kind == WarningKind::ConfigDeprecated)
        .map(|w| w.message.as_str())
        .collect();
    assert_eq!(found, [deprecated], "{warnings:?}");

    let result = fix_with(&mut fx, |fx| FixOptions {
        source: vec![fx.a.clone()],
        ..FixOptions::default()
    });
    assert_eq!(result.num_fixed_commits, 3);
    let warnings = fx.repo.take_warnings();
    assert!(
        warnings
            .iter()
            .any(|w| w.kind == WarningKind::ConfigDeprecated && w.message == deprecated),
        "{warnings:?}"
    );
    let a = fx.a.clone();
    assert_eq!(file(&mut fx, &a, "a.txt"), "a\n--l=1\n");
}

#[test]
fn a_broken_tools_config_is_refused_before_anything() {
    let config_refusal = |config: &str| {
        let mut fx = configured(config);
        let before = head_op(&fx.root);
        let err = fx.repo.fix(&FixOptions::default()).expect_err("refused");
        assert_eq!(head_op(&fx.root), before);
        err
    };
    for (config, reason) in [
        ("", "No `fix.tools` are configured"),
        (
            "fix.tools.t = { command = ['x'], patterns = ['a.txt'], enabled = false }\n",
            "At least one entry of `fix.tools` must be enabled.",
        ),
        (
            "fix.tools.t = { command = ['x'], patterns = ['a.txt'], run-tool-if-zero-line-ranges = true }\n",
            "run-tool-if-zero-line-ranges can only be set when line-range-args is set",
        ),
    ] {
        let err = config_refusal(config);
        assert!(
            matches!(&err, MutateError::Config { reason: r } if r == reason),
            "{config}: {err:?}"
        );
    }
    let err = config_refusal("fix.tools.t = { command = ['x'], patterns = ['('] }\n");
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    assert!(
        err.to_string().contains("Failed to parse fileset: Syntax error"),
        "{err}"
    );
    assert_eq!(err.hints().len(), 1);
}

#[test]
fn an_immutable_source_is_refused() {
    let mut fx = base();
    let config = format!("{UPPER}{}", crate::rebase::immutable(&fx.b));
    reconfigure(&mut fx, &config);
    let a = fx.a.clone();
    let before = head_op(&fx.root);
    let err = fx
        .repo
        .fix(&FixOptions {
            source: vec![a],
            ..FixOptions::default()
        })
        .expect_err("refused");
    assert!(matches!(err, MutateError::Immutable { .. }), "{err:?}");
    assert_eq!(head_op(&fx.root), before);
}

#[test]
fn revsets_fix_is_the_default_source() {
    let mut fx = configured(&format!("{UPPER}[revsets]\nfix = '@'\n"));
    let result = fix(&mut fx, &FixOptions::default());
    assert_op(&fx, &result.mutation, "fixed 1 commits");
    assert_eq!((result.num_fixed_commits, result.num_checked_commits), (1, 1));
    let (a, c) = (fx.a.clone(), fx.c.clone());
    assert_eq!(file(&mut fx, &a, "a.txt"), "a\n", "A is outside `@`");
    assert_eq!(file(&mut fx, &c, "c.txt"), "C\n");
    assert_eq!(file(&mut fx, &c, "a.txt"), "a\n", "C did not change a.txt");
}

/// A tool appending its arguments: the line-range arguments become the file's last line.
const ARGS_TOOL: &str = "command = ['sh', '-c', 'cat; echo \"$@\"', 'sh']\nline-range-args = ['--l=$first-$last']\n";

/// `M` adds `lines.txt` (three lines) on C, `N` changes its second line; returns `(M, N)`.
fn modified_line(fx: &mut Fx) -> (ChangeId, ChangeId) {
    let c = fx.c.clone();
    let m = add(fx, &[c], &[("lines.txt", "1\n2\n3\n")], "M\n");
    let n = add(fx, std::slice::from_ref(&m), &[("lines.txt", "1\ntwo\n3\n")], "N\n");
    (m, n)
}

#[test]
fn line_range_args_get_the_changed_lines_or_every_line() {
    let config = format!("[fix.tools.args]\n{ARGS_TOOL}patterns = ['lines.txt']\n");
    for (all_lines, range) in [(false, "--l=2-2"), (true, "--l=1-3")] {
        let mut fx = configured(&config);
        let (_, n) = modified_line(&mut fx);
        let source = n.clone();
        let result = fix_with(&mut fx, |_| FixOptions {
            source: vec![source],
            all_lines,
            ..FixOptions::default()
        });
        assert_eq!(result.num_fixed_commits, 1, "all_lines {all_lines}");
        assert_eq!(
            file(&mut fx, &n, "lines.txt"),
            format!("1\ntwo\n3\n{range}\n"),
            "all_lines {all_lines}"
        );
    }
}

#[test]
fn an_unchanged_file_with_no_line_ranges_is_skipped_unless_configured() {
    for (run_if_zero, a_txt) in [(false, "a\n"), (true, "a\n\n")] {
        let config = format!(
            "[fix.tools.args]\n{ARGS_TOOL}patterns = ['a.txt']\nrun-tool-if-zero-line-ranges = {run_if_zero}\n"
        );
        let mut fx = configured(&config);
        let (_, n) = modified_line(&mut fx);
        let source = n.clone();
        fix_with(&mut fx, |_| FixOptions {
            source: vec![source],
            include_unchanged_files: true,
            ..FixOptions::default()
        });
        assert_eq!(
            file(&mut fx, &n, "a.txt"),
            a_txt,
            "run-tool-if-zero-line-ranges {run_if_zero}"
        );
    }
}

#[test]
fn tools_chain_in_name_order_and_a_disabled_one_is_dropped() {
    let mut fx = configured(
        "[fix.tools.b-second]\ncommand = ['sh', '-c', 'cat; echo second']\npatterns = ['a.txt']\n\
         [fix.tools.a-first]\ncommand = ['sh', '-c', 'cat; echo first']\npatterns = ['a.txt']\n\
         [fix.tools.0-off]\ncommand = ['sh', '-c', 'echo off']\npatterns = ['a.txt']\nenabled = false\n",
    );
    let result = fix_with(&mut fx, |fx| FixOptions {
        source: vec![fx.a.clone()],
        ..FixOptions::default()
    });
    assert_eq!(result.num_fixed_commits, 3);
    let a = fx.a.clone();
    assert_eq!(file(&mut fx, &a, "a.txt"), "a\nfirst\nsecond\n");
}
