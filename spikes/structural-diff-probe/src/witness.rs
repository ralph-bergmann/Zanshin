// SPDX-License-Identifier: MIT
//! `witness`: jj's, difft's and E2's marks side by side on the witness cases — `inputs/witness/<case>/`
//! holds `before.<ext>` and `after.<ext>`; one more case, with carriage returns and a tab, is built
//! here because its bytes are hard to keep in a text file.

use std::path::{Path, PathBuf};

use crate::marks::{self, Class, Kind};
use crate::{crate_dir, ms, option, out_dir};

struct Case {
    name: String,
    extension: String,
    before: Vec<u8>,
    after: Vec<u8>,
}

pub fn run(args: &[String]) -> Result<(), String> {
    println!("difft: {}\n", marks::require_difft()?);
    let inputs = option(args, "--inputs").map_or_else(|| crate_dir().join("inputs/witness"), PathBuf::from);
    let work = out_dir("work-witness")?;
    let mut cases = read_cases(&inputs)?;
    cases.push(Case {
        name: "edge-cr-tab".to_owned(),
        extension: "rs".to_owned(),
        before: b"fn main() {\r\n\tlet s = \"a\rb\"; f(x);\r\n}\r\n".to_vec(),
        after: b"fn main() {\r\n\tlet s = \"a\rb\"; f(y);\r\n}\r\n".to_vec(),
    });
    for case in &cases {
        print_case(case, &work)?;
    }
    Ok(())
}

fn read_cases(inputs: &Path) -> Result<Vec<Case>, String> {
    let read_dir = |dir: &Path| std::fs::read_dir(dir).map_err(|error| format!("{}: {error}", dir.display()));
    let mut dirs: Vec<PathBuf> = read_dir(inputs)?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .collect();
    dirs.sort();
    let mut cases = Vec::new();
    for dir in dirs {
        let mut before = None;
        let mut after = None;
        for entry in read_dir(&dir)?.filter_map(Result::ok) {
            let path = entry.path();
            let (Some(stem), Some(extension)) = (path.file_stem(), path.extension()) else {
                continue;
            };
            let slot = match stem.to_str() {
                Some("before") => &mut before,
                Some("after") => &mut after,
                _ => continue,
            };
            let bytes = std::fs::read(&path).map_err(|error| format!("{}: {error}", path.display()))?;
            *slot = Some((extension.to_string_lossy().into_owned(), bytes));
        }
        let (Some((extension, before)), Some((_, after))) = (before, after) else {
            return Err(format!("{}: needs before.<ext> and after.<ext>", dir.display()));
        };
        let name = dir.file_name().unwrap_or_default().to_string_lossy().into_owned();
        cases.push(Case {
            name,
            extension,
            before,
            after,
        });
    }
    Ok(cases)
}

fn print_case(case: &Case, work: &Path) -> Result<(), String> {
    let jj = marks::jj_diff(&case.before, &case.after);
    let difft = marks::difft_diff(
        work,
        &format!("{}.{}", case.name, case.extension),
        &case.before,
        &case.after,
        &[],
    )?;
    println!("#### {} (.{})\n", case.name, case.extension);
    println!(
        "jj: {} hunk(s), {} changed line(s), {} ms in-process, E2 {} ms more · difft: language `{}`, status `{}`, {} ms wall",
        jj.hunks.len(),
        jj.changed_lines().count(),
        ms(jj.elapsed),
        ms(jj.e2_elapsed),
        difft.language,
        difft.status,
        ms(difft.elapsed),
    );
    println!("\n```text");
    let (mut jj_ink, mut difft_ink, mut same, mut drawn_same) = (0, 0, 0, 0);
    let (mut e2_ink, mut e2_same, mut e2_drawn_same) = (0, 0, 0);
    for (index, hunk) in jj.hunks.iter().enumerate() {
        println!("@@ hunk {} @@", index + 1);
        for line in hunk {
            match line.kind {
                Kind::Context => println!("  ctx   |{}", marks::render(&line.text, &[], Kind::Context)),
                Kind::Removed | Kind::Added => {
                    let sign = if line.kind == Kind::Removed { '-' } else { '+' };
                    let structural = if difft.fell_back() {
                        line.jj.clone()
                    } else {
                        difft.marks_for(line)
                    };
                    let (class, drawn) = if difft.fell_back() {
                        (Class::Fallback, Class::Fallback)
                    } else {
                        let drawn = marks::classify_drawn(
                            &marks::drawn(&line.text, &line.jj),
                            &marks::drawn(&line.text, &structural),
                        );
                        (marks::classify(&line.text, &line.jj, &structural), drawn)
                    };
                    jj_ink += marks::ink(&line.text, &line.jj).len();
                    difft_ink += marks::ink(&line.text, &structural).len();
                    same += usize::from(class == Class::Same);
                    drawn_same += usize::from(matches!(drawn, Class::Same | Class::Fallback));
                    println!("{sign} jj    |{}", marks::render(&line.text, &line.jj, line.kind));
                    println!(
                        "{sign} difft |{}   <- {}; drawn: {}",
                        marks::render(&line.text, &structural, line.kind),
                        class.label(),
                        drawn.label()
                    );
                    let raw = difft.raw_marks_for(line);
                    if !difft.fell_back() && raw != structural {
                        println!(
                            "{sign} 1st   |{}   <- the first rule: {}",
                            marks::render(&line.text, &raw, line.kind),
                            marks::classify(&line.text, &line.jj, &raw).label()
                        );
                    }
                    // E2 against difft: the same classes, with E2 in jj's place (also inside
                    // comments and strings).
                    let e2_structural = difft.e2_marks_for(line);
                    let (e2_class, e2_drawn) = if difft.fell_back() {
                        (Class::Fallback, Class::Fallback)
                    } else {
                        let drawn = marks::classify_drawn(
                            &marks::drawn(&line.text, &line.e2),
                            &marks::drawn(&line.text, &e2_structural),
                        );
                        (marks::classify(&line.text, &line.e2, &e2_structural), drawn)
                    };
                    if !difft.fell_back() && e2_structural != structural {
                        println!(
                            "{sign} d(e2) |{}   <- difft with E2's marks inside comments and strings",
                            marks::render(&line.text, &e2_structural, line.kind)
                        );
                    }
                    e2_ink += marks::ink(&line.text, &line.e2).len();
                    e2_same += usize::from(e2_class == Class::Same);
                    e2_drawn_same += usize::from(matches!(e2_drawn, Class::Same | Class::Fallback));
                    println!(
                        "{sign} e2    |{}   <- against difft: {}; drawn: {}",
                        marks::render(&line.text, &line.e2, line.kind),
                        e2_class.label(),
                        e2_drawn.label()
                    );
                }
            }
        }
    }
    println!("```\n");
    let verdict = if difft.fell_back() {
        "difft fell back, so a build keeps jj's marks"
    } else if difft_ink < jj_ink {
        "difft marks less"
    } else if difft_ink > jj_ink {
        "jj marks less"
    } else {
        "both mark the same amount"
    };
    let dropped = marks::dropped(&jj, &difft);
    println!(
        "Marked non-whitespace bytes on changed lines: jj {jj_ink}, difft {difft_ink} — {verdict}; same marks on {same} of {changed} changed line(s); drawn the same by 10.32 (whitespace fills counted) on {drawn_same} of {changed}.",
        changed = jj.changed_lines().count()
    );
    println!(
        "E2: {e2_ink} marked non-whitespace bytes; the same marks as difft on {e2_same} of {changed} changed line(s), drawn the same on {e2_drawn_same} of {changed}.",
        changed = jj.changed_lines().count()
    );
    println!(
        "difft marks the mapping drops: {} on jj context lines, {} outside jj's hunks. Spans moved by a carriage return: {}. Content mismatches: {}.\n",
        dropped.on_context, dropped.outside, difft.cr_shifted_spans, difft.content_mismatches
    );
    Ok(())
}
