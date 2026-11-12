// SPDX-License-Identifier: MIT

//! Story 5.10: `Repo::diff`'s color-words lines against the pinned `jj diff --color=debug`. Each
//! witness runs through Zanshin and the pinned `jj` on the SAME repo (a diff writes no operation on
//! a snapshotted working copy, so both see one state, and both read the same repo-level
//! `diff.color-words.*`). The CLI's debug output names every colour label, so each printed line
//! gives its kind, left / right number and token sides; `    ...` lines split the hunks and carry
//! the skipped range's symbol line.

use std::fs;
use std::path::Path;

use zanshin_jj::{DiffOptions, DiffRevisions, HunkLine, HunkLineKind, Repo, SegmentKind, Whitespace};

use crate::driver::{fresh_repo, jj};

/// One printed line: kind (` ` context, `-` removed, `+` added, `~` changed, `#` conflict header),
/// left and right numbers, and runs (`=` equal, `-` removed, `+` added) without the line break.
type Line = (char, Option<u32>, Option<u32>, Vec<(char, String)>);

/// A hunk: the skipped range's symbol before it, then its lines.
type Hunk = (Option<String>, Vec<Line>);

/// `text` without its ANSI colour sequences.
fn strip_ansi(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            for c in chars.by_ref() {
                if c == 'm' {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// A debug-output line's `<<labels::text>>` chunks. A chunk ends at the `>>` that ends the line or
/// starts the next chunk, so a text holding `>>` (a conflict marker) stays whole.
fn chunks(line: &str) -> Vec<(Vec<&str>, &str)> {
    let mut out = Vec::new();
    let mut rest = line;
    while let Some(start) = rest.strip_prefix("<<") {
        let colons = start.find("::").expect("a label separator");
        let labels = start[..colons].split(' ').collect();
        let text = &start[colons + 2..];
        let end = (0..text.len())
            .find(|&at| text[at..].starts_with(">>") && (at + 2 == text.len() || text[at + 2..].starts_with("<<")))
            .expect("a chunk end");
        out.push((labels, &text[..end]));
        rest = &text[end + 2..];
    }
    assert!(rest.is_empty(), "an unparsed rest: {rest:?} in {line:?}");
    out
}

/// Runs: adjacent ones of one side joined, empty ones dropped.
fn join(runs: impl IntoIterator<Item = (char, String)>) -> Vec<(char, String)> {
    let mut out: Vec<(char, String)> = Vec::new();
    for (side, text) in runs.into_iter().filter(|(_, text)| !text.is_empty()) {
        match out.last_mut() {
            Some((last, joined)) if *last == side => joined.push_str(&text),
            _ => out.push((side, text)),
        }
    }
    out
}

/// The CLI's hunks of one file, parsed from `jj diff --color=debug`.
fn cli_hunks(stdout: &str) -> Vec<Hunk> {
    let mut hunks: Vec<Hunk> = Vec::new();
    let mut current: Hunk = (None, Vec::new());
    for raw in strip_ansi(stdout).lines().filter(|line| !line.is_empty()) {
        let parts = chunks(raw);
        let full: String = parts.iter().map(|(_, text)| *text).collect();
        if parts[0].0.contains(&"header") {
            continue;
        }
        if parts.iter().any(|(labels, _)| labels.contains(&"hunk_header")) {
            current.1.push(('#', None, None, vec![('=', full)]));
            continue;
        }
        if let Some(skip) = full.strip_prefix("    ...") {
            let symbol = skip.strip_prefix("    ").map(ToOwned::to_owned);
            let done = std::mem::replace(&mut current, (symbol, Vec::new()));
            if !done.1.is_empty() {
                hunks.push(done);
            }
            continue;
        }
        let number = |digits: &str| digits.trim().parse::<u32>().ok();
        let (left, right) = (number(&full[0..4]), number(&full[5..9]));
        let mut runs = Vec::new();
        let mut at = 0;
        let mut context = false;
        let mut number_sides = Vec::new();
        for (labels, text) in &parts {
            if labels.contains(&"line_number") {
                number_sides.push(if labels.contains(&"removed") { '-' } else { '+' });
            }
            // An empty context line has no text chunk: its numbers carry the label too.
            context |= labels.contains(&"context");
            let end = at + text.len();
            if end > 11 {
                let own = &text[11usize.saturating_sub(at)..];
                let side = match (labels.contains(&"token"), labels.contains(&"removed")) {
                    (false, _) => '=',
                    (true, true) => '-',
                    (true, false) => '+',
                };
                runs.push((side, own.to_owned()));
            }
            at = end;
        }
        let kind = match (left, right) {
            _ if context => ' ',
            (Some(_), Some(_)) => '~',
            _ => number_sides[0],
        };
        current.1.push((kind, left, right, join(runs)));
    }
    if !current.1.is_empty() {
        hunks.push(current);
    }
    hunks
}

/// One Zanshin line in the parsed CLI's shape: the line's last `\n` dropped, as the CLI prints it.
fn zanshin_line(line: &HunkLine) -> Line {
    let kind = match line.kind {
        HunkLineKind::Context => ' ',
        HunkLineKind::Removed => '-',
        HunkLineKind::Added => '+',
        HunkLineKind::Changed => '~',
        HunkLineKind::ConflictHeader => '#',
    };
    let count = line.segments.len();
    let runs = line.segments.iter().enumerate().map(|(index, segment)| {
        let text = if index + 1 == count {
            segment.text.strip_suffix('\n').unwrap_or(&segment.text)
        } else {
            &segment.text
        };
        let side = match segment.kind {
            SegmentKind::Equal => '=',
            SegmentKind::Removed => '-',
            SegmentKind::Added => '+',
        };
        (side, text.to_owned())
    });
    (kind, line.left, line.right, join(runs))
}

/// What a witness diffs: the repo-level config it sets, `jj diff`'s extra arguments and the same
/// options for Zanshin.
#[derive(Default)]
struct Witness<'a> {
    config: &'a [(&'a str, &'a str)],
    args: &'a [&'a str],
    options: DiffOptions,
}

/// `path` = `old` in `@-`, `new` in `@`: the CLI's and Zanshin's hunks of `jj diff` for
/// `witness`, which must be equal. Returns them.
#[track_caller]
fn assert_witness(path: &str, old: &str, new: &str, witness: &Witness<'_>) -> Vec<Hunk> {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[]);
    for (name, value) in witness.config {
        // `--` lets a value like `-1` through.
        jj(&root, &["config", "set", "--repo", "--", name, value]).ok();
    }
    fs::write(root.join(path), old).expect("write the old side");
    jj(&root, &["new"]).ok();
    fs::write(root.join(path), new).expect("write the new side");
    assert_same(&root, witness)
}

/// The CLI's and Zanshin's hunks of the single changed file of `witness` in `root`.
#[track_caller]
fn assert_same(root: &Path, witness: &Witness<'_>) -> Vec<Hunk> {
    let mut args = vec!["diff", "--color=debug"];
    args.extend(witness.args);
    let cli = cli_hunks(&jj(root, &args).ok().stdout);
    let diff = Repo::open(root).expect("open").diff(&witness.options).expect("diff");
    assert_eq!(diff.files.len(), 1, "one changed file");
    let zanshin: Vec<Hunk> = diff.files[0]
        .hunks
        .iter()
        .map(|hunk| (hunk.symbol.clone(), hunk.lines.iter().map(zanshin_line).collect()))
        .collect();
    assert_eq!(zanshin, cli);
    assert!(!cli.is_empty(), "the witness changes lines");
    cli
}

/// Ralph's jj example (commit `671e4eaca`, `lib/src/git.rs` `write_locked_index`), padded so its
/// line numbers are the file's.
fn jj_example() -> (String, String) {
    let pad = "\n".repeat(2440);
    let head = "/// Writes `index` to the lock file and atomically replaces the Git index with\n/// it.\n\
        fn write_locked_index(\n    index: &gix::index::File,\n    lock: gix::lock::File,\n\
        ) -> Result<(), GitResetHeadError> {\n    debug_assert_eq!(lock.resource_path(), index.path());\n    \
        let mut out = std::io::BufWriter::new(lock);\n    index\n        \
        .write_to(&mut out, gix::index::write::Options::default())\n        \
        .map_err(GitResetHeadError::from_git)?;\n    let lock = out\n        .into_inner()\n";
    let tail = "    Ok(())\n}\n\n/// Reads the Git index from disk, or returns an empty index if there's none.\n///\n\
        /// Unlike `gix::Repository::index_or_empty()`, this bypasses the index cache\n";
    let old = "        .map_err(|err| GitResetHeadError::from_git(err.into_error()))?;\n    lock.commit()\n        \
        .map_err(|err| GitResetHeadError::from_git(err.error))?;\n";
    let new = "        .map_err(|err| {\n            let (source, out) = err.into_parts();\n            \
        let path = out.get_ref().lock_path().to_owned();\n            PathError { path, source }\n        \
        })\n        .map_err(GitResetHeadError::from_git)?;\n    lock.commit()\n        \
        .map_err(|err| err.error)\n        .context(index.path())\n        \
        .map_err(GitResetHeadError::from_git)?;\n";
    (format!("{pad}{head}{old}{tail}"), format!("{pad}{head}{new}{tail}"))
}

#[test]
fn ralphs_jj_example_matches_the_cli() {
    let (old, new) = jj_example();
    let hunks = assert_witness("git.rs", &old, &new, &Witness::default());
    assert_eq!(hunks[0].0.as_deref(), Some("fn write_locked_index("));
    assert!(hunks[0].1.contains(&(
        '~',
        Some(2454),
        Some(2459),
        vec![
            ('+', "        .map_err(".to_owned()),
            ('=', "GitResetHeadError::from_git".to_owned()),
            ('-', "(err.into_error())".to_owned()),
            ('=', ")?;".to_owned()),
        ]
    )));
}

#[test]
fn the_jj_example_with_context_one_matches_the_cli() {
    let (old, new) = jj_example();
    let witness = Witness {
        args: &["--context", "1"],
        options: DiffOptions {
            context: Some(1),
            ..DiffOptions::default()
        },
        ..Witness::default()
    };
    assert_witness("git.rs", &old, &new, &witness);
}

/// `max-inline-alternation = 0` never inlines; `-1` always does.
#[test]
fn the_inline_limit_from_the_repo_config_matches_the_cli() {
    let (old, new) = jj_example();
    let never = Witness {
        config: &[("diff.color-words.max-inline-alternation", "0")],
        ..Witness::default()
    };
    let hunks = assert_witness("git.rs", &old, &new, &never);
    assert!(hunks[0].1.iter().all(|line| line.0 != '~'));
    let (left, right) = widget_test();
    let always = Witness {
        config: &[("diff.color-words.max-inline-alternation", "-1")],
        ..Witness::default()
    };
    let hunks = assert_witness("w.dart", left, right, &always);
    assert!(hunks[0].1.iter().any(|line| line.0 == '~'));
}

/// The stepper.dart edits (10.32's demo data).
#[test]
fn the_stepper_edits_match_the_cli() {
    let old = "import 'package:flutter/widgets.dart';\n\nclass StepperButton extends StatelessWidget {\n  \
        const StepperButton({super.key, required this.isLastStep, required this.s});\n\n  \
        final bool isLastStep;\n  final Strings s;\n\n  @override\n  \
        Widget build(BuildContext context) => FilledButton(\n    \
        child: Text(isLastStep ? s.functionWizard_save : s.functionWizard_next),\n  );\n}\n\n\
        class StepperLine extends StatelessWidget {\n  \
        const StepperLine({super.key, required this.isFirst, required this.lineColor});\n\n  \
        final bool isFirst;\n  final Color lineColor;\n\n  @override\n  \
        Widget build(BuildContext context) => Row(children: [\n    \
        Expanded(child: _Line(color: isFirst ? null : lineColor)),\n    DecoratedBox(\n      \
        decoration: BoxDecoration(color: lineColor),\n      child: const SizedBox(width: 8, height: 8),\n    \
        ),\n  ]);\n}\n\nclass _Line extends StatelessWidget {\n  const _Line({required this.color});\n\n  \
        final Color? color;\n\n  @override\n  \
        Widget build(BuildContext context) => ColoredBox(color: color ?? const Color(0x00000000));\n}\n\n\
        Widget stepLabel(Widget label) => Padding(\n  padding: Spacing.spacing8,\n  child: label,\n);\n";
    let new = old
        .replace("s.functionWizard_save :", "saveLabel :")
        .replace(
            "Expanded(child: _Line(color: isFirst ? null : lineColor)),",
            "Expanded(\n      child: _Line(color: isFirst ? null : lineColor),\n    ),",
        )
        .replace(
            "  padding: Spacing.spacing8,",
            "  // Small side padding.\n  padding: Spacing.spacing2,",
        );
    let hunks = assert_witness("stepper.dart", old, &new, &Witness::default());
    assert_eq!(hunks.len(), 3);
}

/// Ralph's widget-test block: 3 removed and 16 added lines, over the default inline limit.
fn widget_test() -> (&'static str, &'static str) {
    let left = "void main() {\n  void prepare() {\n    run(() {\n    });\n  }\n\n  \
        // Tablet only: the wide test font overflows the compact app bar, which holds the buttons on a phone.\n  \
        // The phone layout is checked on a device.\n  \
        testWidgets('shows Funktion speichern instead of Weiter on the last step', (tester) async {\n    \
        await openWizard(tester, size: tablet);\n    await fillGeneralStep(tester);\n  });\n}\n";
    let right = "void main() {\n  void prepare() {\n    run(() {\n    });\n  }\n\n  \
        // The tablet shows the long label. The phone app bar has little room and shows the short one.\n  \
        testWidgets('shows Speichern instead of Weiter on the last step on a phone', (tester) async {\n    \
        await openWizard(tester, size: phone);\n    await fillGeneralStep(tester);\n\n    \
        for (var i = 0; i < 3; i++) {\n      \
        await tester.tap(withIdentifier(SemanticsIdentifiers.functionWizard_next));\n      \
        await tester.pumpAndSettle();\n    }\n\n    \
        expect(find.text('Speichern'), findsWidgets);\n    \
        expect(find.text('Funktion speichern'), findsNothing);\n    \
        expect(find.text('Weiter'), findsNothing);\n  });\n\n  \
        testWidgets('shows Funktion speichern instead of Weiter on the last step on a tablet', (tester) async {\n    \
        await openWizard(tester, size: tablet);\n    await fillGeneralStep(tester);\n  });\n}\n";
    (left, right)
}

#[test]
fn a_block_over_the_limit_matches_the_cli() {
    let (left, right) = widget_test();
    let hunks = assert_witness("w.dart", left, right, &Witness::default());
    assert!(hunks[0].1.iter().all(|line| line.0 != '~'));
}

/// `-w` and `-b`: context lines whose sides differ in whitespace take the changed-block path,
/// still context.
#[test]
fn ignoring_whitespace_matches_the_cli() {
    let old = "fn f() {\n    let a = 1;\n  let b = 2;\n    let c = 3;\n}\n";
    let new = "fn f() {\n    let a = 10;\n    let b = 2;\n    let c = 30;\n}\n";
    for (flag, whitespace) in [
        ("-w", Whitespace::IgnoreAllSpace),
        ("-b", Whitespace::IgnoreSpaceChange),
    ] {
        let witness = Witness {
            args: &[flag],
            options: DiffOptions {
                whitespace,
                ..DiffOptions::default()
            },
            ..Witness::default()
        };
        assert_witness("b.rs", old, new, &witness);
    }
    let witness = Witness {
        args: &["-w"],
        options: DiffOptions {
            whitespace: Whitespace::IgnoreAllSpace,
            ..DiffOptions::default()
        },
        ..Witness::default()
    };
    assert_witness("s.txt", "a b\n", "ab\n", &witness);
}

/// Context 3 between two one-line changes: 7 unchanged lines are one hunk, 8 are two.
#[test]
fn the_context_rule_matches_the_cli() {
    for (gap, count) in [(7, 1), (8, 2)] {
        let mut lines = vec!["a".to_owned()];
        lines.extend((0..gap).map(|i| format!("x{i}")));
        lines.push("b".to_owned());
        let old = lines.join("\n") + "\n";
        let new = old.replace("a\n", "A\n").replace("\nb\n", "\nB\n");
        let hunks = assert_witness("gap.txt", &old, &new, &Witness::default());
        assert_eq!(hunks.len(), count, "{gap} apart");
    }
}

/// `X` (`c.txt` = `x`) against the X / Y merge left conflicted, under `conflict` (`None` = the
/// default `materialize`).
fn assert_conflict(conflict: Option<&str>) -> Vec<Hunk> {
    test_helpers::pin_test_env();
    let (_dir, root) = fresh_repo(&["git", "init"], &[]);
    if let Some(method) = conflict {
        jj(&root, &["config", "set", "--repo", "diff.color-words.conflict", method]).ok();
    }
    fs::write(root.join("c.txt"), "base\nkeep\n").expect("write");
    jj(&root, &["bookmark", "create", "base-mark", "-r", "@"]).ok();
    jj(&root, &["new", "base-mark"]).ok();
    fs::write(root.join("c.txt"), "x\nkeep\n").expect("write");
    jj(&root, &["bookmark", "create", "x-mark", "-r", "@"]).ok();
    jj(&root, &["new", "base-mark"]).ok();
    fs::write(root.join("c.txt"), "y\nkeep\n").expect("write");
    jj(&root, &["bookmark", "create", "y-mark", "-r", "@"]).ok();
    jj(&root, &["new", "x-mark", "y-mark"]).ok();
    let witness = Witness {
        args: &["--from", "x-mark"],
        options: DiffOptions {
            revisions: DiffRevisions::FromTo {
                from: Some("x-mark".to_owned()),
                to: None,
            },
            ..DiffOptions::default()
        },
        ..Witness::default()
    };
    assert_same(&root, &witness)
}

#[test]
fn a_materialized_conflict_matches_the_cli() {
    let hunks = assert_conflict(None);
    assert!(hunks.iter().flat_map(|hunk| &hunk.1).all(|line| line.0 != '#'));
}

#[test]
fn a_paired_conflict_matches_the_cli() {
    let hunks = assert_conflict(Some("pair"));
    let headers: Vec<&str> = hunks
        .iter()
        .flat_map(|hunk| &hunk.1)
        .filter(|line| line.0 == '#')
        .map(|line| line.3[0].1.as_str())
        .collect();
    assert_eq!(headers.first(), Some(&"<<<<<<< Created conflict"));
    assert_eq!(headers.last(), Some(&">>>>>>> Conflict ends"));
}
