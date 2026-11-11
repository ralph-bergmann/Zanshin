// SPDX-License-Identifier: MIT

//! Syntax classes of diff lines (Story 5.3, FR-DF-2): which kind of token each run of a line is.
//!
//! **One line at a time, best effort.** [`highlight_line`] runs tree-sitter-highlight over one line
//! of a file (its text, `\n` included) in the file's [`Language`]. The diff is per line, so the
//! highlighter sees every line out of context, and a line can get wrong classes as well as missing
//! ones: `fn main() {` leaves `main` unclassified; a Dart statement from a method body is not valid
//! on its own (`widget.onTap();` makes both names types); a Markdown line indented by four spaces
//! is a code block; a line inside a block comment or a fenced code block is read as code or
//! Markdown of its own; and a Markdown heading that begins with inline markup (`` # `code` ``) gets
//! wrong classes, because tree-sitter-highlight opens the inline layer's highlights there before
//! the heading's. Invalid syntax yields whatever classes tree-sitter's error recovery gives, never
//! an error. Plain text, a line over 131,072 characters and a highlighter error yield one
//! unclassified token. A line gets at most 16 injected layers: Rust macro bodies nested deeper are
//! not highlighted as Rust.
//!
//! **Classes.** A tree-sitter capture maps to one [`SyntaxClass`] by tree-sitter-highlight's
//! `configure` rule over `CAPTURES`: the recognized name whose parts all occur in the capture's,
//! the most parts first, the earlier name on a tie. A token inside another takes the inner
//! capture's class (an escape inside a string). Text no capture covers, whitespace included, has
//! no class.
//!
//! **Merge.** [`merge_highlight`] splits a line's word-level segments (Story 5.2) at its token
//! boundaries, so every resulting segment has one kind and one class.

use std::cell::RefCell;
use std::ops::Range;

use tree_sitter_highlight::{Highlight, HighlightConfiguration, HighlightEvent, Highlighter};

use crate::grammars::{injected, Language};
use crate::word_diff::{Segment, SegmentKind, MAX_LINE_CHARS};

/// What kind of token a run of a line is: one fixed set of standard categories.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyntaxClass {
    /// A keyword: `fn`, `class`, `final`, Dart's `this`, `is` and `as`.
    Keyword,
    /// A string or character literal.
    String,
    /// An escape sequence: `\n` in a string, a Markdown backslash escape.
    Escape,
    /// A comment, doc comments included.
    Comment,
    /// A function or method name where it is defined or called; a Rust macro's name.
    Function,
    /// A type or a constructor; Rust's upper-case names (its constants too) and a lifetime's name.
    Type,
    /// A variable or a parameter; Rust's `self`.
    Variable,
    /// A field or a property.
    Property,
    /// A number literal; Rust's are [`SyntaxClass::Constant`].
    Number,
    /// A constant: `true`, `false`, `null`, a Dart enum value where it is declared, a Rust number
    /// literal.
    Constant,
    /// An operator.
    Operator,
    /// Punctuation: brackets, delimiters, Markdown's markers.
    Punctuation,
    /// An attribute or an annotation.
    Attribute,
    /// A Markdown heading's text.
    Heading,
    /// Markdown emphasis.
    Emphasis,
    /// Markdown strong emphasis.
    Strong,
    /// A Markdown link's text, label or destination.
    Link,
    /// Markdown code: a code span, a code block, a link title.
    Code,
}

/// One token of a highlighted line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HighlightedToken {
    /// Its bytes of the line: on char boundaries, never empty.
    pub range: Range<usize>,
    /// Its class; `None` for text no capture covers.
    pub class: Option<SyntaxClass>,
}

/// A run of a line's text with one kind and one class: part of a [`Segment`], split at token
/// boundaries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HighlightedSegment {
    /// The run's text, never empty.
    pub text: String,
    /// The kind of the segment it is part of.
    pub kind: SegmentKind,
    /// The class of the token it is part of; `None` for no class.
    pub syntax_class: Option<SyntaxClass>,
}

/// The recognized capture names and their classes, in `configure` order: `keyword` comes before
/// `operator`, so Dart's `keyword.operator` is a keyword.
pub(crate) const CAPTURES: [(&str, SyntaxClass); 23] = [
    ("keyword", SyntaxClass::Keyword),
    ("string.escape", SyntaxClass::Escape),
    ("escape", SyntaxClass::Escape),
    ("string", SyntaxClass::String),
    ("comment", SyntaxClass::Comment),
    ("function", SyntaxClass::Function),
    ("type", SyntaxClass::Type),
    // A constructor is the grammars' upper-case-identifier guess; a Rust lifetime is a type-level
    // parameter.
    ("constructor", SyntaxClass::Type),
    ("label", SyntaxClass::Type),
    ("variable", SyntaxClass::Variable),
    ("property", SyntaxClass::Property),
    ("number", SyntaxClass::Number),
    // Rust captures its number literals as `constant.builtin`.
    ("constant", SyntaxClass::Constant),
    ("boolean", SyntaxClass::Constant),
    ("operator", SyntaxClass::Operator),
    ("punctuation", SyntaxClass::Punctuation),
    ("attribute", SyntaxClass::Attribute),
    ("text.title", SyntaxClass::Heading),
    ("text.emphasis", SyntaxClass::Emphasis),
    ("text.strong", SyntaxClass::Strong),
    ("text.uri", SyntaxClass::Link),
    ("text.reference", SyntaxClass::Link),
    ("text.literal", SyntaxClass::Code),
];

thread_local! {
    // A highlighter owns a parser and query cursors, so each thread reuses one.
    static HIGHLIGHTER: RefCell<Highlighter> = RefCell::new(Highlighter::new());
}

// Each injected layer parses its content again, so nested Rust macros cost about the cube of their
// depth (a 2,000-character line of 500 nested macros took 1.4 s); a line gets at most this many.
const MAX_INJECTIONS: u32 = 16;

/// The tokens of one `line` of a file in `language`: byte ranges on char boundaries, none empty,
/// contiguous from 0 to the line's length, adjacent ones differing in class. An empty line has
/// none. Best effort, one line at a time (see the module documentation).
#[must_use]
pub fn highlight_line(line: &str, language: Language) -> Vec<HighlightedToken> {
    if line.is_empty() {
        return Vec::new();
    }
    language
        .config()
        .filter(|_| line.chars().count() <= MAX_LINE_CHARS)
        .and_then(|config| classify(line, config))
        .unwrap_or_else(|| {
            vec![HighlightedToken {
                range: 0..line.len(),
                class: None,
            }]
        })
}

/// tree-sitter-highlight's events over `line` as tokens; `None` on a highlighter error and on
/// events that do not cover the line exactly once.
fn classify(line: &str, config: &HighlightConfiguration) -> Option<Vec<HighlightedToken>> {
    HIGHLIGHTER.with_borrow_mut(|highlighter| {
        let mut budget = MAX_INJECTIONS;
        let inject = move |name: &str| {
            budget = budget.checked_sub(1)?;
            injected(name)
        };
        let events = highlighter
            .highlight(config, line.as_bytes(), None, None, inject)
            .ok()?;
        let mut tokens: Vec<HighlightedToken> = Vec::new();
        // The classes of the captures open at this point, the innermost last.
        let mut open: Vec<Option<SyntaxClass>> = Vec::new();
        let mut at = 0;
        for event in events {
            match event.ok()? {
                HighlightEvent::HighlightStart(Highlight(index)) => {
                    open.push(CAPTURES.get(index).map(|&(_, class)| class));
                }
                HighlightEvent::HighlightEnd => {
                    open.pop();
                }
                HighlightEvent::Source { start, end } => {
                    line.get(at..end).filter(|text| start == at && !text.is_empty())?;
                    let class = open.last().copied().flatten();
                    match tokens.last_mut() {
                        Some(last) if last.class == class => last.range.end = end,
                        _ => tokens.push(HighlightedToken {
                            range: start..end,
                            class,
                        }),
                    }
                    at = end;
                }
            }
        }
        (at == line.len()).then_some(tokens)
    })
}

/// One line's `segments` (Story 5.2) split at the boundaries of its `tokens` ([`highlight_line`]):
/// every resulting segment has one kind and one class, none is empty, their texts concatenate to
/// the line, and adjacent ones differ in kind or class. Dropping the classes and joining adjacent
/// runs of one kind gives `segments` back; plain-text tokens leave `segments` as they are, each
/// with no class. Text no token covers has no class, and a token boundary inside a character moves
/// to that character's end, so it never panics, whatever tokens it gets.
#[must_use]
pub fn merge_highlight(segments: &[Segment], tokens: &[HighlightedToken]) -> Vec<HighlightedSegment> {
    let mut merged: Vec<HighlightedSegment> = Vec::new();
    let mut tokens = tokens.iter().peekable();
    // The line offset `rest` starts at.
    let mut at = 0;
    for segment in segments {
        let mut rest = segment.text.as_str();
        while !rest.is_empty() {
            while tokens.next_if(|token| token.range.end <= at).is_some() {}
            // `until` is past `at`: the peeked token ends after it.
            let (class, until) = match tokens.peek() {
                Some(token) if token.range.start <= at => (token.class, token.range.end),
                Some(token) => (None, token.range.start),
                None => (None, usize::MAX),
            };
            let (text, tail) = rest.split_at(rest.ceil_char_boundary(until - at));
            match merged.last_mut() {
                Some(last) if last.kind == segment.kind && last.syntax_class == class => last.text.push_str(text),
                _ => merged.push(HighlightedSegment {
                    text: text.to_owned(),
                    kind: segment.kind,
                    syntax_class: class,
                }),
            }
            at += text.len();
            rest = tail;
        }
    }
    merged
}
