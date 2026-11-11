// SPDX-License-Identifier: MIT

//! Story 5.2's word diff: `compute_word_diff` on every row of the spec's I/O matrix that needs no
//! repository, and `line_segments`' pairing. Every result is also checked against the invariants:
//! a line's segments concatenate exactly to its text, none is empty, adjacent segments differ in
//! kind, and a segment is `Equal` or the line's own kind.

use zanshin_diff::{compute_word_diff, line_segments, Segment, SegmentKind};
use zanshin_jj::HunkLine;

/// Segments in the spec's notation: `=` Equal, `-` Removed or `+` Added, then the exact text.
fn segments(notation: &[&str]) -> Vec<Segment> {
    notation
        .iter()
        .map(|segment| {
            let (marker, text) = segment.split_at(1);
            let kind = match marker {
                "=" => SegmentKind::Equal,
                "-" => SegmentKind::Removed,
                _ => SegmentKind::Added,
            };
            Segment {
                text: text.to_owned(),
                kind,
            }
        })
        .collect()
}

/// `segments` concatenate exactly to `text`, none is empty, adjacent ones differ in kind, and each
/// is `Equal` or `own`.
fn assert_invariants(segments: &[Segment], text: &str, own: SegmentKind) {
    let joined: String = segments.iter().map(|s| s.text.as_str()).collect();
    assert_eq!(joined, text);
    assert!(segments.iter().all(|s| !s.text.is_empty()), "{segments:?}");
    assert!(segments.windows(2).all(|w| w[0].kind != w[1].kind), "{segments:?}");
    assert!(
        segments.iter().all(|s| s.kind == SegmentKind::Equal || s.kind == own),
        "{segments:?}"
    );
}

/// `compute_word_diff`, both sides checked against the invariants.
fn word_diff(removed: &str, added: &str) -> (Vec<Segment>, Vec<Segment>) {
    let (removed_segments, added_segments) = compute_word_diff(removed, added);
    assert_invariants(&removed_segments, removed, SegmentKind::Removed);
    assert_invariants(&added_segments, added, SegmentKind::Added);
    (removed_segments, added_segments)
}

/// `line_segments`, every line checked against the invariants.
fn checked_line_segments(lines: &[HunkLine]) -> Vec<Vec<Segment>> {
    let all = line_segments(lines);
    assert_eq!(all.len(), lines.len());
    for (line, segments) in lines.iter().zip(&all) {
        let (text, own) = match line {
            HunkLine::Context(text) => (text, SegmentKind::Equal),
            HunkLine::Removed(text) => (text, SegmentKind::Removed),
            HunkLine::Added(text) => (text, SegmentKind::Added),
        };
        assert!(!segments.is_empty(), "{line:?}");
        assert_invariants(segments, text, own);
    }
    all
}

#[test]
fn the_ac_example_marks_only_the_changed_words() {
    assert_eq!(
        word_diff("fn foo(x: i32) -> i32", "fn foo(y: i32) -> u32"),
        (
            segments(&["=fn foo(", "-x", "=: i32) -> ", "-i32"]),
            segments(&["=fn foo(", "+y", "=: i32) -> ", "+u32"])
        )
    );
}

#[test]
fn lines_sharing_no_token_are_wholly_removed_and_added() {
    assert_eq!(
        word_diff("alpha", "omega"),
        (segments(&["-alpha"]), segments(&["+omega"]))
    );
}

#[test]
fn a_space_both_lines_share_stays_equal() {
    assert_eq!(
        word_diff("foo bar", "baz qux"),
        (segments(&["-foo", "= ", "-bar"]), segments(&["+baz", "= ", "+qux"]))
    );
}

#[test]
fn several_changes_in_one_line_are_separate_segments() {
    assert_eq!(
        word_diff("let a = b + c;", "let x = b * c;"),
        (
            segments(&["=let ", "-a", "= = b ", "-+", "= c;"]),
            segments(&["=let ", "+x", "= = b ", "+*", "= c;"])
        )
    );
}

#[test]
fn accents_combining_marks_and_emoji_stay_whole_tokens() {
    assert_eq!(
        word_diff("caf\u{e9} ☕ naïve 🎉", "cafe ☕ naive 🎉"),
        (
            segments(&["-caf\u{e9}", "= ☕ ", "-naïve", "= 🎉"]),
            segments(&["+cafe", "= ☕ ", "+naive", "= 🎉"])
        )
    );
    // Here the removed `é` of `café` is `e` plus a combining acute: one token with its base.
    assert_eq!(
        word_diff("cafe\u{301} ☕ naïve 🎉", "cafe ☕ naive 🎉"),
        (
            segments(&["-cafe\u{301}", "= ☕ ", "-naïve", "= 🎉"]),
            segments(&["+cafe", "= ☕ ", "+naive", "= 🎉"])
        )
    );
}

#[test]
fn whitespace_changes_are_small_segments() {
    assert_eq!(
        word_diff("a b", "a  b"),
        (segments(&["=a", "- ", "=b"]), segments(&["=a", "+  ", "=b"]))
    );
    assert_eq!(word_diff("x", "x "), (segments(&["=x"]), segments(&["=x", "+ "])));
}

#[test]
fn a_nul_byte_is_part_of_the_text() {
    assert_eq!(
        word_diff("a\0b", "a\0c"),
        (segments(&["=a\0", "-b"]), segments(&["=a\0", "+c"]))
    );
}

#[test]
fn a_reordered_call_is_marked_whole() {
    // Pins `Algorithm::Histogram` and `postprocess_no_heuristic`: Myers, or no postprocessing,
    // cut this pair differently.
    assert_eq!(
        word_diff("foo(a).bar(b).baz(c)", "foo(a).baz(c).bar(b)"),
        (
            segments(&["=foo(a).", "-bar(b).", "=baz(c)"]),
            segments(&["=foo(a).baz(c)", "+.bar(b)"])
        )
    );
}

#[test]
fn a_changed_line_can_carry_no_changed_segment() {
    // A removed blank line paired with `foo`: its `\n` equals the added line's.
    assert_eq!(
        word_diff("\n", "foo\n"),
        (segments(&["=\n"]), segments(&["+foo", "=\n"]))
    );
}

#[test]
fn a_changed_segment_can_be_only_a_line_ending() {
    assert_eq!(word_diff("a\n", "a"), (segments(&["=a", "-\n"]), segments(&["=a"])));
    assert_eq!(
        word_diff("a\r\n", "a\n"),
        (segments(&["=a", "-\r\n"]), segments(&["=a", "+\n"]))
    );
}

#[test]
fn a_100k_character_line_with_one_changed_token_completes() {
    let half = "lorem ".repeat(8_333);
    let removed = format!("{half}alpha {half}\n");
    let added = format!("{half}omega {half}\n");
    assert!(removed.chars().count() > 100_000);
    let (head, tail) = (format!("={half}"), format!("= {half}\n"));
    let expected = (
        segments(&[head.as_str(), "-alpha", tail.as_str()]),
        segments(&[head.as_str(), "+omega", tail.as_str()]),
    );
    assert_eq!(word_diff(&removed, &added), expected);
    // Under the 128 KiB cap, `line_segments` word-diffs the pair too.
    let lines = [HunkLine::Removed(removed), HunkLine::Added(added)];
    assert_eq!(checked_line_segments(&lines), [expected.0, expected.1]);
}

#[test]
fn a_pair_with_a_line_over_128_kib_gets_whole_line_segments() {
    let long = format!("{}alpha\n", "lorem ".repeat(22_000));
    assert!(long.len() > 128 * 1024);
    // Each pair shares `lorem `, so a word diff would show `Equal` segments.
    let lines = [
        HunkLine::Removed(long.clone()),
        HunkLine::Added("lorem omega\n".into()),
        HunkLine::Context("b\n".into()),
        HunkLine::Removed("lorem alpha\n".into()),
        HunkLine::Added(long.clone()),
    ];
    let (removed, added) = (format!("-{long}"), format!("+{long}"));
    assert_eq!(
        checked_line_segments(&lines),
        [
            segments(&[removed.as_str()]),
            segments(&["+lorem omega\n"]),
            segments(&["=b\n"]),
            segments(&["-lorem alpha\n"]),
            segments(&[added.as_str()])
        ]
    );
}

#[test]
fn five_removed_then_three_added_pair_the_first_three() {
    let mut lines: Vec<HunkLine> = (1..=5).map(|i| HunkLine::Removed(format!("old{i} = x;\n"))).collect();
    lines.extend((1..=3).map(|i| HunkLine::Added(format!("new{i} = x;\n"))));
    let all = checked_line_segments(&lines);
    for i in 1..=3_usize {
        let (old, new) = (format!("-old{i}"), format!("+new{i}"));
        assert_eq!(all[i - 1], segments(&[old.as_str(), "= = x;\n"]), "removed line {i}");
        assert_eq!(all[i + 4], segments(&[new.as_str(), "= = x;\n"]), "added line {i}");
    }
    assert_eq!(all[3], segments(&["-old4 = x;\n"]));
    assert_eq!(all[4], segments(&["-old5 = x;\n"]));
}

#[test]
fn context_and_lone_added_lines_are_one_segment_of_their_kind() {
    let lines = [HunkLine::Context("b\n".into()), HunkLine::Added("n\n".into())];
    assert_eq!(
        checked_line_segments(&lines),
        [segments(&["=b\n"]), segments(&["+n\n"])]
    );
}

#[test]
fn a_removed_run_followed_by_context_is_not_paired() {
    // `x y` and `x z` share tokens, so a pairing would show as `Equal` segments.
    let lines = [
        HunkLine::Removed("x y\n".into()),
        HunkLine::Context("b\n".into()),
        HunkLine::Added("x z\n".into()),
        HunkLine::Added("n\n".into()),
    ];
    assert_eq!(
        checked_line_segments(&lines),
        [
            segments(&["-x y\n"]),
            segments(&["=b\n"]),
            segments(&["+x z\n"]),
            segments(&["+n\n"])
        ]
    );
}

#[test]
fn each_changed_region_of_a_hunk_pairs_on_its_own() {
    // The shape `jj diff` gives `a b c` → `A b C`: one removed and one added line per region.
    let lines = [
        HunkLine::Removed("a\n".into()),
        HunkLine::Added("A\n".into()),
        HunkLine::Context("b\n".into()),
        HunkLine::Removed("c\n".into()),
        HunkLine::Added("C\n".into()),
    ];
    assert_eq!(
        checked_line_segments(&lines),
        [
            segments(&["-a", "=\n"]),
            segments(&["+A", "=\n"]),
            segments(&["=b\n"]),
            segments(&["-c", "=\n"]),
            segments(&["+C", "=\n"])
        ]
    );
}

#[test]
fn an_empty_slice_has_no_segments() {
    assert!(line_segments(&[]).is_empty());
}
