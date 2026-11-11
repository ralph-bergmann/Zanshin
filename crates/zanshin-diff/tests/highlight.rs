// SPDX-License-Identifier: MIT

//! Story 5.3's syntax classes: `highlight_line` and `merge_highlight` on every row of the spec's
//! I/O matrix that needs no repository. Every token list is checked against the token invariants
//! (non-empty byte ranges on char boundaries, contiguous from 0 to the line's length, adjacent
//! ones differing in class) and every merge against the merge invariants (one kind and one class
//! per segment, none empty, the texts concatenate to the line, adjacent ones differ in kind or
//! class, a segment never crosses a token boundary and takes its token's class, and dropping the
//! classes gives Story 5.2's segments back) — over every row in every language.

use zanshin_diff::{
    compute_word_diff, highlight_line, merge_highlight, HighlightedSegment, HighlightedToken, Language, Segment,
    SegmentKind, SyntaxClass as C,
};

const LANGUAGES: [Language; 4] = [Language::PlainText, Language::Rust, Language::Dart, Language::Markdown];

/// Every row's line.
const ROWS: [&str; 10] = [
    "fn foo(x: i32) -> i32",
    "let s = \"a\\nb\"; // c\n",
    "    println!(\"{}\", x);",
    "fn foo(",
    "class Foo extends Bar {}",
    "  final int x = 42; // c\n",
    "# Title\n",
    "see [a](b) and **x**\n",
    "a\0b é 🎉\n",
    "",
];

/// `highlight_line`, checked against the token invariants.
fn checked_tokens(line: &str, language: Language) -> Vec<HighlightedToken> {
    let tokens = highlight_line(line, language);
    let mut at = 0;
    for token in &tokens {
        assert_eq!(token.range.start, at, "{language:?} {line:?}: {tokens:?}");
        assert!(token.range.start < token.range.end, "{language:?} {line:?}: {tokens:?}");
        assert!(
            line.get(token.range.clone()).is_some(),
            "{language:?} {line:?}: {tokens:?}"
        );
        at = token.range.end;
    }
    assert_eq!(at, line.len(), "{language:?} {line:?}: {tokens:?}");
    assert!(
        tokens.windows(2).all(|w| w[0].class != w[1].class),
        "{language:?} {line:?}: {tokens:?}"
    );
    tokens
}

/// `line`'s tokens in `language` as texts with their classes.
fn tokens(line: &str, language: Language) -> Vec<(&str, Option<C>)> {
    checked_tokens(line, language)
        .into_iter()
        .map(|token| (&line[token.range], token.class))
        .collect()
}

/// Only the classed tokens.
fn classed(line: &str, language: Language) -> Vec<(&str, C)> {
    tokens(line, language)
        .into_iter()
        .filter_map(|(text, class)| class.map(|class| (text, class)))
        .collect()
}

/// Segments in Story 5.2's notation: `=` Equal, `-` Removed or `+` Added, then the exact text.
fn segments(notation: &[&str]) -> Vec<Segment> {
    notation
        .iter()
        .map(|segment| {
            let (marker, text) = segment.split_at(1);
            Segment {
                text: text.to_owned(),
                kind: kind(marker),
            }
        })
        .collect()
}

fn kind(marker: &str) -> SegmentKind {
    match marker {
        "=" => SegmentKind::Equal,
        "-" => SegmentKind::Removed,
        _ => SegmentKind::Added,
    }
}

/// A highlighted segment in the same notation, with its class.
fn seg(notation: &str, syntax_class: Option<C>) -> HighlightedSegment {
    let (marker, text) = notation.split_at(1);
    HighlightedSegment {
        text: text.to_owned(),
        kind: kind(marker),
        syntax_class,
    }
}

/// `merged` with its classes dropped and adjacent runs of one kind joined.
fn unclassed(merged: &[HighlightedSegment]) -> Vec<Segment> {
    let mut joined: Vec<Segment> = Vec::new();
    for segment in merged {
        match joined.last_mut() {
            Some(last) if last.kind == segment.kind => last.text.push_str(&segment.text),
            _ => joined.push(Segment {
                text: segment.text.clone(),
                kind: segment.kind,
            }),
        }
    }
    joined
}

/// `merge_highlight`, checked against the merge invariants for `tokens` from `highlight_line`.
fn checked_merge(segments: &[Segment], tokens: &[HighlightedToken]) -> Vec<HighlightedSegment> {
    let merged = merge_highlight(segments, tokens);
    let line: String = segments.iter().map(|s| s.text.as_str()).collect();
    let joined: String = merged.iter().map(|s| s.text.as_str()).collect();
    assert_eq!(joined, line);
    assert!(merged.iter().all(|s| !s.text.is_empty()), "{merged:?}");
    assert!(
        merged
            .windows(2)
            .all(|w| (w[0].kind, w[0].syntax_class) != (w[1].kind, w[1].syntax_class)),
        "{merged:?}"
    );
    assert_eq!(unclassed(&merged), segments);
    let mut at = 0;
    for segment in &merged {
        let end = at + segment.text.len();
        let token = tokens
            .iter()
            .find(|token| token.range.contains(&at))
            .expect("a token covers every byte");
        assert!(
            end <= token.range.end,
            "{segment:?} crosses a token boundary: {tokens:?}"
        );
        assert_eq!(segment.syntax_class, token.class, "{segment:?}: {tokens:?}");
        at = end;
    }
    merged
}

#[test]
fn the_ac_rust_line_classifies_keyword_function_variable_punctuation_and_type() {
    assert_eq!(
        tokens("fn foo(x: i32) -> i32", Language::Rust),
        [
            ("fn", Some(C::Keyword)),
            (" ", None),
            ("foo", Some(C::Function)),
            ("(", Some(C::Punctuation)),
            ("x", Some(C::Variable)),
            (":", Some(C::Punctuation)),
            (" ", None),
            ("i32", Some(C::Type)),
            (")", Some(C::Punctuation)),
            (" -> ", None),
            ("i32", Some(C::Type)),
        ]
    );
}

#[test]
fn rust_literals_classify_a_string_its_escape_and_a_comment() {
    assert_eq!(
        tokens("let s = \"a\\nb\"; // c\n", Language::Rust),
        [
            ("let", Some(C::Keyword)),
            (" s = ", None),
            ("\"a", Some(C::String)),
            ("\\n", Some(C::Escape)),
            ("b\"", Some(C::String)),
            (";", Some(C::Punctuation)),
            (" ", None),
            ("// c", Some(C::Comment)),
            ("\n", None),
        ]
    );
}

#[test]
fn a_rust_macro_body_is_highlighted_through_the_injection() {
    let outer = classed("    println!(\"{}\", x);", Language::Rust);
    assert!(outer.contains(&("println!", C::Function)), "{outer:?}");
    assert!(outer.contains(&("\"{}\"", C::String)), "{outer:?}");
    // The outer layer classifies the two above as well; a call is a function only in the layer
    // the injection parses the macro body into.
    let injected = classed("    println!(\"{}\", foo(x));", Language::Rust);
    assert!(injected.contains(&("foo", C::Function)), "{injected:?}");
}

#[test]
fn a_line_gets_at_most_16_injected_layers() {
    // `f` is a function only inside an injected layer; each nested macro injects one more.
    let nested = |depth: usize| format!("{}f(x){};\n", "a!(".repeat(depth), ")".repeat(depth));
    let function_at = |depth: usize| classed(&nested(depth), Language::Rust).contains(&("f", C::Function));
    assert!(function_at(16), "16 nested macros are still highlighted");
    assert!(!function_at(17), "the 17th layer is not injected");
    // 500 nested macros: unbounded, the injections took seconds; bounded, the line still keeps
    // the token invariants.
    checked_tokens(&nested(500), Language::Rust);
}

#[test]
fn every_capture_class_is_reached_by_a_bundled_grammar() {
    assert_eq!(
        tokens("#[derive(Debug)] let n: &'a u8 = 42; s.f = true; Foo\n", Language::Rust),
        [
            ("#", Some(C::Attribute)),
            ("[", Some(C::Punctuation)),
            ("derive", Some(C::Attribute)),
            ("(", Some(C::Punctuation)),
            ("Debug", Some(C::Type)),
            (")]", Some(C::Punctuation)),
            (" ", None),
            ("let", Some(C::Keyword)),
            (" n", None),
            (":", Some(C::Punctuation)),
            (" ", None),
            ("&'", Some(C::Operator)),
            ("a", Some(C::Type)),
            (" ", None),
            ("u8", Some(C::Type)),
            (" = ", None),
            ("42", Some(C::Constant)),
            (";", Some(C::Punctuation)),
            (" s", None),
            (".", Some(C::Punctuation)),
            ("f", Some(C::Property)),
            (" = ", None),
            ("true", Some(C::Constant)),
            (";", Some(C::Punctuation)),
            (" ", None),
            ("Foo", Some(C::Type)),
            ("\n", None),
        ]
    );
    assert_eq!(
        classed("@override var s = '\\n' is A ? null : true;\n", Language::Dart),
        [
            ("@override", C::Attribute),
            ("var", C::Keyword),
            ("s", C::Variable),
            ("=", C::Operator),
            ("'", C::String),
            ("\\n", C::Escape),
            ("'", C::String),
            ("is", C::Keyword),
            ("A", C::Type),
            ("null", C::Constant),
            (":", C::Punctuation),
            ("true", C::Constant),
            (";", C::Punctuation),
        ]
    );
    assert_eq!(
        tokens("a *e* `c` \\* x\n", Language::Markdown),
        [
            ("a ", None),
            ("*", Some(C::Punctuation)),
            ("e", Some(C::Emphasis)),
            ("*", Some(C::Punctuation)),
            (" ", None),
            ("`", Some(C::Punctuation)),
            ("c", Some(C::Code)),
            ("`", Some(C::Punctuation)),
            (" ", None),
            ("\\*", Some(C::Escape)),
            (" x\n", None),
        ]
    );
}

#[test]
fn a_line_out_of_context_can_get_missing_or_wrong_classes() {
    // The module documentation's examples of missing and wrong classes; a fix that changes one
    // changes that documentation too.
    let classed_main = classed("fn main() {\n", Language::Rust);
    assert!(
        !classed_main.iter().any(|&(text, _)| text.contains("main")),
        "{classed_main:?}"
    );
    assert_eq!(
        classed("  widget.onTap();\n", Language::Dart),
        [
            ("widget", C::Type),
            (".", C::Punctuation),
            ("onTap", C::Type),
            ("();", C::Punctuation)
        ]
    );
    assert_eq!(
        tokens("    - item\n", Language::Markdown),
        [("    - item\n", Some(C::Code))]
    );
    assert_eq!(
        tokens("# `code` title\n", Language::Markdown),
        [
            ("#", Some(C::Punctuation)),
            (" ", None),
            ("`", Some(C::Heading)),
            ("code`", Some(C::Punctuation)),
            (" title", Some(C::Code)),
            ("\n", None),
        ]
    );
}

#[test]
fn invalid_rust_yields_the_classes_error_recovery_gives() {
    assert_eq!(
        tokens("fn foo(", Language::Rust),
        [("fn", Some(C::Keyword)), (" foo", None), ("(", Some(C::Punctuation))]
    );
}

#[test]
fn a_dart_class_declaration_classifies_keywords_and_types() {
    assert_eq!(
        tokens("class Foo extends Bar {}", Language::Dart),
        [
            ("class", Some(C::Keyword)),
            (" ", None),
            ("Foo", Some(C::Type)),
            (" ", None),
            ("extends", Some(C::Keyword)),
            (" ", None),
            ("Bar", Some(C::Type)),
            (" ", None),
            ("{}", Some(C::Punctuation)),
        ]
    );
}

#[test]
fn a_dart_field_classifies_type_variable_operator_number_and_comment() {
    assert_eq!(
        classed("  final int x = 42; // c\n", Language::Dart),
        [
            ("final", C::Keyword),
            ("int", C::Type),
            ("x", C::Variable),
            ("=", C::Operator),
            ("42", C::Number),
            (";", C::Punctuation),
            ("// c", C::Comment),
        ]
    );
}

#[test]
fn a_markdown_heading_classifies_its_marker_and_its_text() {
    assert_eq!(
        tokens("# Title\n", Language::Markdown),
        [
            ("#", Some(C::Punctuation)),
            (" ", None),
            ("Title", Some(C::Heading)),
            ("\n", None),
        ]
    );
}

#[test]
fn markdown_inline_content_is_highlighted_through_the_injection() {
    assert_eq!(
        tokens("see [a](b) and **x**\n", Language::Markdown),
        [
            ("see ", None),
            ("[", Some(C::Punctuation)),
            ("a", Some(C::Link)),
            ("](", Some(C::Punctuation)),
            ("b", Some(C::Link)),
            (")", Some(C::Punctuation)),
            (" and ", None),
            ("**", Some(C::Punctuation)),
            ("x", Some(C::Strong)),
            ("**", Some(C::Punctuation)),
            ("\n", None),
        ]
    );
}

#[test]
fn plain_text_is_one_unclassified_token_and_an_empty_line_none() {
    for line in ROWS.into_iter().filter(|line| !line.is_empty()) {
        assert_eq!(tokens(line, Language::PlainText), [(line, None)], "{line:?}");
    }
    for language in LANGUAGES {
        assert!(highlight_line("", language).is_empty(), "{language:?}");
    }
}

#[test]
fn every_row_in_every_language_keeps_the_token_and_merge_invariants() {
    for line in ROWS {
        // Story 5.2's segments of the line as one whole-line run (none for the empty line: no
        // segment is empty) and as a word diff.
        let whole: Vec<Segment> = (!line.is_empty())
            .then(|| Segment {
                text: line.to_owned(),
                kind: SegmentKind::Equal,
            })
            .into_iter()
            .collect();
        let (word_diffed, _) = compute_word_diff(line, "fn foo(y) 🎉\n");
        for language in LANGUAGES {
            let tokens = checked_tokens(line, language);
            for segments in [&whole, &word_diffed] {
                let merged = checked_merge(segments, &tokens);
                if language == Language::PlainText {
                    let plain: Vec<_> = segments
                        .iter()
                        .map(|s| HighlightedSegment {
                            text: s.text.clone(),
                            kind: s.kind,
                            syntax_class: None,
                        })
                        .collect();
                    assert_eq!(merged, plain, "{line:?}");
                }
            }
        }
    }
}

#[test]
fn nul_bytes_accents_and_emoji_keep_tokens_on_char_boundaries_in_every_language() {
    for language in LANGUAGES {
        for line in [
            "a\0b é 🎉\n",
            "é",
            "🎉🎉",
            "\0",
            "// é 🎉\n",
            "\"🎉\\n\"",
            "# é *🎉* `\0`\n",
        ] {
            checked_tokens(line, language);
        }
    }
}

#[test]
fn a_100k_character_line_is_classified_in_every_language() {
    let line = format!("let x = [{}];\n", "1, ".repeat(33_400));
    assert!(line.chars().count() > 100_000);
    for language in [Language::Rust, Language::Dart, Language::Markdown] {
        assert!(checked_tokens(&line, language).len() > 1, "{language:?}");
    }
    let rust = tokens(&line, Language::Rust);
    assert_eq!(rust[0], ("let", Some(C::Keyword)));
}

#[test]
fn a_line_over_131_072_characters_is_one_unclassified_token() {
    // `é` is two bytes: the cap counts characters.
    let line = |length: usize| format!("fn {}\n", "é".repeat(length - 4));
    let at_cap = line(131_072);
    assert_eq!(at_cap.chars().count(), 131_072);
    assert_eq!(tokens(&at_cap, Language::Rust)[0], ("fn", Some(C::Keyword)));
    let over = line(131_073);
    assert_eq!(tokens(&over, Language::Rust), [(over.as_str(), None)]);
}

#[test]
fn the_ac_merge_splits_word_diff_segments_at_token_boundaries() {
    let segments = segments(&["=fn foo(", "-x", "=: i32) -> ", "-i32"]);
    let tokens = checked_tokens("fn foo(x: i32) -> i32", Language::Rust);
    assert_eq!(
        checked_merge(&segments, &tokens),
        [
            seg("=fn", Some(C::Keyword)),
            seg("= ", None),
            seg("=foo", Some(C::Function)),
            seg("=(", Some(C::Punctuation)),
            seg("-x", Some(C::Variable)),
            seg("=:", Some(C::Punctuation)),
            seg("= ", None),
            seg("=i32", Some(C::Type)),
            seg("=)", Some(C::Punctuation)),
            seg("= -> ", None),
            seg("-i32", Some(C::Type)),
        ]
    );
}

#[test]
fn a_token_spanning_segments_is_cut_and_adjacent_runs_of_one_kind_and_class_join() {
    // `"ab"` is one string token over three segments; `ab` and `"` join across the segment cut.
    let segments = segments(&["=\"a", "+b", "=\"x"]);
    let tokens = [
        HighlightedToken {
            range: 0..4,
            class: Some(C::String),
        },
        HighlightedToken {
            range: 4..5,
            class: None,
        },
    ];
    assert_eq!(
        checked_merge(&segments, &tokens),
        [
            seg("=\"a", Some(C::String)),
            seg("+b", Some(C::String)),
            seg("=\"", Some(C::String)),
            seg("=x", None),
        ]
    );
}

#[test]
fn merge_never_panics_whatever_tokens_it_gets() {
    let segments = segments(&["=é🎉", "-ab", "=c\n"]);
    let garbage = [
        // Unsorted, overlapping, reversed, empty, past the line, and inside a character.
        HighlightedToken {
            range: 5..9,
            class: Some(C::Keyword),
        },
        HighlightedToken {
            range: 1..3,
            class: Some(C::String),
        },
        HighlightedToken {
            range: std::ops::Range { start: 8, end: 2 },
            class: Some(C::Comment),
        },
        HighlightedToken {
            range: 4..4,
            class: Some(C::Type),
        },
        HighlightedToken {
            range: 10..usize::MAX,
            class: Some(C::Number),
        },
    ];
    for tokens in [&garbage[..], &garbage[..1], &garbage[1..], &[]] {
        let merged = merge_highlight(&segments, tokens);
        let joined: String = merged.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(joined, "é🎉abc\n");
        assert!(merged.iter().all(|s| !s.text.is_empty()), "{merged:?}");
        assert_eq!(unclassed(&merged), segments);
    }
    // No token at all: the segments themselves, unclassified.
    assert_eq!(
        merge_highlight(&segments, &[]),
        [seg("=é🎉", None), seg("-ab", None), seg("=c\n", None)]
    );
    assert!(merge_highlight(&[], &garbage).is_empty());
}
