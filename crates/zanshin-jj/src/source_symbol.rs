// SPDX-License-Identifier: MIT AND Apache-2.0

//! `source_symbol.rs` — the source symbol a hunk header names (Story 5.1), jj 0.46's hunk-header
//! "funcname".
//!
//! A verbatim port of `cli/src/source_symbol.rs` @ v0.46.0 (the languages, their patterns and the
//! scanner) plus `trim_source_symbol` from `cli/src/diff_util.rs:1849-1861`. That code is
//! Copyright 2020-2026 The Jujutsu Authors, licensed under the Apache License, Version 2.0
//! (<https://www.apache.org/licenses/LICENSE-2.0>); the jj CLI is not a library dependency for
//! it (`source_symbol` is `pub(crate)` there), so it is ported. Changes: std `&[u8]` helpers
//! instead of `bstr`, and a pattern that fails to compile matches nothing instead of panicking.
//! A file whose name has no pattern — Dart among them — gets no symbol.

use std::ops::Range;
use std::sync::LazyLock;

use regex::bytes::Regex;

/// A language with a hunk-header pattern, picked from the file name.
#[derive(Clone, Copy, Debug)]
pub(crate) enum SourceLanguage {
    BibTeX,
    CLike,
    CSharp,
    Dts,
    Elixir,
    Go,
    Html,
    Ini,
    Java,
    JavaScript,
    Kotlin,
    Markdown,
    Matlab,
    MatlabOrObjC,
    ObjC,
    CLikeOrObjC,
    Pascal,
    Perl,
    Php,
    Python,
    R,
    Ruby,
    Rust,
    Scheme,
    Shell,
    Tex,
}

/// A pattern compiled once; `None` when it does not compile (never, for the ported patterns).
type Pattern = LazyLock<Option<Regex>>;

/// Whether `pattern` matches `line`.
fn is_match(pattern: &Pattern, line: &[u8]) -> bool {
    pattern.as_ref().is_some_and(|re| re.is_match(line))
}

static BIBTEX_FUNCTION_RE: Pattern =
    LazyLock::new(|| Regex::new(r#"^@[A-Za-z]+[ \t]*\{?[ \t]*[^ \t"@',\\#}{~%]*"#).ok());
static C_LIKE_FUNCTION_RE: Pattern =
    LazyLock::new(|| Regex::new(r"^(?:[A-Za-z_][\w:<>,~]*|[*&]|\[[^\]]*\]|\s+)+[A-Za-z_~][\w:~]*\s*\([^;{}]*").ok());
static CSHARP_FUNCTION_RE: Pattern = LazyLock::new(|| {
    Regex::new(
        r"^(?:(?:[\w@_.]+(?:<[\w@_, \t<>]+>)?)(?:\s+[\w@_.]+(?:<[\w@_, \t<>]+>)?)+\s*\([^;]*|(?:(?:static|public|internal|private|protected|new|unsafe|sealed|abstract|partial)\s+)*(?:class|enum|interface|struct|record)\s+.*|namespace\s+.*)$",
    )
    .ok()
});
static DTS_FUNCTION_RE: Pattern = LazyLock::new(|| Regex::new(r"^(?:/[ \t]*\{|&?[A-Za-z_].*)").ok());
static ELIXIR_FUNCTION_RE: Pattern =
    LazyLock::new(|| Regex::new(r"^(?:def(?:macro|module|impl|protocol|p)?|test)\s+.*").ok());
static GO_FUNCTION_RE: Pattern =
    LazyLock::new(|| Regex::new(r"^(?:func\s*.*(?:\{\s*)?|type\s+.*(?:struct|interface)\s*(?:\{\s*)?)$").ok());
static HTML_FUNCTION_RE: Pattern = LazyLock::new(|| Regex::new(r"^<[Hh][1-6](?:\s.*)?>.*").ok());
static INI_FUNCTION_RE: Pattern = LazyLock::new(|| Regex::new(r"^\[[^]]+\]").ok());
static JAVA_FUNCTION_RE: Pattern = LazyLock::new(|| {
    Regex::new(
        r"^(?:(?:[a-z-]+\s+)*(?:class|enum|interface|record)\s+.*|(?:[A-Za-z_<>&][\]?&<>.,A-Za-z_0-9]*\s+)+[A-Za-z_][A-Za-z_0-9]*\s*\([^;]*)$",
    )
    .ok()
});
static JAVASCRIPT_FUNCTION_RE: Pattern = LazyLock::new(|| {
    Regex::new(
        r"^(?:(?:export|default|async|static|get|set)\s+)*(?:function\b|class\b|[A-Za-z_$][\w$]*\s*\([^)]*\)\s*\{|[A-Za-z_$][\w$]*\s*[:=]\s*(?:async\s*)?(?:function\b|\([^)]*\)\s*=>))",
    )
    .ok()
});
static KOTLIN_FUNCTION_RE: Pattern = LazyLock::new(|| Regex::new(r"^(?:[a-z]+\s+)*(?:fun|class|interface)\s+.*").ok());
static MARKDOWN_FUNCTION_RE: Pattern = LazyLock::new(|| Regex::new(r"^#{1,6}\s+.*").ok());
static MATLAB_FUNCTION_RE: Pattern =
    LazyLock::new(|| Regex::new(r"^(?:(?:classdef|function)\s+.*|(?:%%%?|##)\s+.*)$").ok());
static OBJC_FUNCTION_RE: Pattern = LazyLock::new(|| {
    Regex::new(
        r"^(?:[-+]\s*\(\s*[A-Za-z_][A-Za-z_0-9* \t]*\)\s*[A-Za-z_].*|(?:[A-Za-z_][A-Za-z_0-9]*\s+)+[A-Za-z_][A-Za-z_0-9]*\s*\([^;]*|@(?:implementation|interface|protocol)\s+.*)$",
    )
    .ok()
});
static PASCAL_FUNCTION_RE: Pattern = LazyLock::new(|| {
    Regex::new(
        r"^(?:(?:(?:class\s+)?(?:procedure|function)|constructor|destructor|interface|implementation|initialization|finalization)\s*.*|.*=\s*(?:class|record).*)$",
    )
    .ok()
});
static PERL_FUNCTION_RE: Pattern = LazyLock::new(|| {
    Regex::new(
        r"^(?:package .*|sub [[:alnum:]_':]+[ \t]*(?:\([^)]*\)[ \t]*)?(?::[^;#]*)?(?:\{[ \t]*)?(?:#.*)?|(?:BEGIN|END|INIT|CHECK|UNITCHECK|AUTOLOAD|DESTROY)[ \t]*(?:\{[ \t]*)?(?:#.*)?|=head[0-9] .*)$",
    )
    .ok()
});
static PHP_FUNCTION_RE: Pattern = LazyLock::new(|| {
    Regex::new(
        r"^(?:(?:(?:public|protected|private|static|abstract|final)\s+)*function.*|(?:(?:(?:final|abstract)\s+)?class|enum|interface|trait).*)$",
    )
    .ok()
});
static PYTHON_FUNCTION_RE: Pattern = LazyLock::new(|| Regex::new(r"^(?:async\s+def|def|class)\s+\w+").ok());
static R_FUNCTION_RE: Pattern = LazyLock::new(|| Regex::new(r"^[A-Za-z][A-Za-z0-9_.]*\s*(?:<-|=)\s*function.*$").ok());
static RUBY_FUNCTION_RE: Pattern = LazyLock::new(|| Regex::new(r"^(?:class|module|def)\s+.*").ok());
static RUST_FUNCTION_RE: Pattern = LazyLock::new(|| {
    Regex::new(
        r#"^(?:(?:pub(?:\([^)]*\))?|const|async|unsafe|extern(?:\s+"[^"]+")?)\s+)*(?:(?:fn|struct|enum|impl|trait|mod|type|union)\b|macro_rules!\s*)"#,
    )
    .ok()
});
static SCHEME_FUNCTION_RE: Pattern = LazyLock::new(|| {
    Regex::new(
        r"^(?:\((?:(?:define|def(?:struct|syntax|class|method|rules|record|proto|alias)?)[-*/ \t]|(?:library|module|struct|class)[*+ \t]).*|[Dd][Ee][Ff].*)$",
    )
    .ok()
});
static SHELL_FUNCTION_RE: Pattern = LazyLock::new(|| {
    Regex::new(r"^(?:[A-Za-z_][A-Za-z0-9_]*\s*\(\s*\)|function\s+[A-Za-z_][A-Za-z0-9_]*(?:(?:\s*\(\s*\))|\s+)).*$").ok()
});
static TEX_FUNCTION_RE: Pattern = LazyLock::new(|| Regex::new(r"^\\(?:(?:sub)*section|chapter|part)\*?\{.*").ok());

impl SourceLanguage {
    /// The language of a file named `file_name` (its last path component), if it has a pattern.
    pub(crate) fn from_file_name(file_name: &str) -> Option<Self> {
        let extension = file_name.rsplit_once('.').map(|(_, extension)| extension);
        match extension {
            Some("bib") => Some(Self::BibTeX),
            Some("c" | "cc" | "cpp" | "cxx" | "hh" | "hpp" | "hxx") => Some(Self::CLike),
            Some("h" | "mm") => Some(Self::CLikeOrObjC),
            Some("cs") => Some(Self::CSharp),
            Some("dts" | "dtsi") => Some(Self::Dts),
            Some("ex" | "exs") => Some(Self::Elixir),
            Some("go") => Some(Self::Go),
            Some("htm" | "html" | "xhtml") => Some(Self::Html),
            Some("cfg" | "conf" | "config" | "ini") => Some(Self::Ini),
            Some("java") => Some(Self::Java),
            Some("js" | "jsx" | "mjs" | "cjs" | "ts" | "tsx") => Some(Self::JavaScript),
            Some("kt" | "kts") => Some(Self::Kotlin),
            Some("markdown" | "md" | "mdown") => Some(Self::Markdown),
            // `.m` is shared by MATLAB and Objective-C.
            Some("m") => Some(Self::MatlabOrObjC),
            Some("matlab") => Some(Self::Matlab),
            Some("p" | "pas") => Some(Self::Pascal),
            Some("pl" | "pm" | "pod" | "psgi" | "t") => Some(Self::Perl),
            Some("php" | "php3" | "php4" | "php5" | "phtml") => Some(Self::Php),
            Some("py" | "pyw") => Some(Self::Python),
            Some("r" | "R") => Some(Self::R),
            Some("rb" | "rake" | "gemspec") => Some(Self::Ruby),
            Some("rs") => Some(Self::Rust),
            Some("scm" | "scheme" | "ss" | "lisp" | "lsp") => Some(Self::Scheme),
            Some("sh" | "bash" | "zsh" | "fish") => Some(Self::Shell),
            Some("tex" | "ltx" | "latex") => Some(Self::Tex),
            _ => match file_name {
                "Gemfile" | "Rakefile" => Some(Self::Ruby),
                _ => None,
            },
        }
    }

    fn is_source_symbol(self, line: &[u8]) -> bool {
        match self {
            Self::BibTeX => is_match(&BIBTEX_FUNCTION_RE, line),
            Self::CLike => {
                let before_paren = line.split(|byte| *byte == b'(').next().unwrap_or(line);
                !line.first().is_some_and(u8::is_ascii_whitespace)
                    && !before_paren.windows(2).any(|pair| pair == b": ")
                    && !starts_with_keyword(line, &["do", "for", "if", "switch", "while"])
                    && is_match(&C_LIKE_FUNCTION_RE, line)
            }
            Self::CSharp => {
                !starts_with_keyword(
                    line,
                    &[
                        "do", "while", "for", "foreach", "if", "else", "new", "default", "return", "switch", "case",
                        "throw", "catch", "using", "lock", "fixed",
                    ],
                ) && is_match(&CSHARP_FUNCTION_RE, line)
            }
            Self::Dts => !line.contains(&b';') && !line.contains(&b'=') && is_match(&DTS_FUNCTION_RE, line),
            Self::Elixir => is_match(&ELIXIR_FUNCTION_RE, line),
            Self::Go => is_match(&GO_FUNCTION_RE, line),
            Self::Html => is_match(&HTML_FUNCTION_RE, line),
            Self::Ini => is_match(&INI_FUNCTION_RE, line),
            Self::Java => {
                !starts_with_keyword(
                    line,
                    &[
                        "catch",
                        "do",
                        "for",
                        "if",
                        "instanceof",
                        "new",
                        "return",
                        "switch",
                        "throw",
                        "while",
                    ],
                ) && is_match(&JAVA_FUNCTION_RE, line)
            }
            Self::JavaScript => {
                !starts_with_keyword(line, &["catch", "for", "if", "switch", "while", "with"])
                    && is_match(&JAVASCRIPT_FUNCTION_RE, line)
            }
            Self::Kotlin => is_match(&KOTLIN_FUNCTION_RE, line),
            Self::Markdown => is_match(&MARKDOWN_FUNCTION_RE, line),
            Self::Matlab => is_match(&MATLAB_FUNCTION_RE, line),
            Self::MatlabOrObjC => Self::Matlab.is_source_symbol(line) || Self::ObjC.is_source_symbol(line),
            Self::ObjC => {
                !starts_with_keyword(line, &["do", "for", "if", "else", "return", "switch", "while"])
                    && is_match(&OBJC_FUNCTION_RE, line)
            }
            Self::CLikeOrObjC => Self::CLike.is_source_symbol(line) || Self::ObjC.is_source_symbol(trim_line(line)),
            Self::Pascal => is_match(&PASCAL_FUNCTION_RE, line),
            Self::Perl => is_match(&PERL_FUNCTION_RE, line),
            Self::Php => is_match(&PHP_FUNCTION_RE, line),
            Self::Python => is_match(&PYTHON_FUNCTION_RE, line),
            Self::R => is_match(&R_FUNCTION_RE, line),
            Self::Ruby => is_match(&RUBY_FUNCTION_RE, line),
            Self::Rust => is_match(&RUST_FUNCTION_RE, line),
            Self::Scheme => is_match(&SCHEME_FUNCTION_RE, line),
            Self::Shell => is_match(&SHELL_FUNCTION_RE, line),
            Self::Tex => is_match(&TEX_FUNCTION_RE, line),
        }
    }
}

fn starts_with_keyword(line: &[u8], keywords: &[&str]) -> bool {
    keywords.iter().any(|keyword| {
        line.strip_prefix(keyword.as_bytes()).is_some_and(|rest| {
            rest.first()
                .is_none_or(|byte| byte.is_ascii_whitespace() || matches!(byte, b'(' | b'{' | b';'))
        })
    })
}

fn strip_line_ending(line: &[u8]) -> &[u8] {
    let line = line.strip_suffix(b"\n").unwrap_or(line);
    line.strip_suffix(b"\r").unwrap_or(line)
}

fn trim_line(line: &[u8]) -> &[u8] {
    strip_line_ending(line).trim_ascii()
}

fn is_c_style_comment_line(line: &[u8]) -> bool {
    // A leading `*` can also belong to a pointer-returning function declaration.
    line.starts_with(b"/*") || line.starts_with(b"//")
}

fn is_comment_line(language: SourceLanguage, line: &[u8]) -> bool {
    match language {
        SourceLanguage::CLike
        | SourceLanguage::CLikeOrObjC
        | SourceLanguage::CSharp
        | SourceLanguage::Go
        | SourceLanguage::Java
        | SourceLanguage::JavaScript
        | SourceLanguage::Kotlin
        | SourceLanguage::ObjC
        | SourceLanguage::Php
        | SourceLanguage::Rust
        | SourceLanguage::MatlabOrObjC => is_c_style_comment_line(line),
        SourceLanguage::Elixir
        | SourceLanguage::Perl
        | SourceLanguage::Python
        | SourceLanguage::R
        | SourceLanguage::Ruby
        | SourceLanguage::Shell => line.starts_with(b"#"),
        SourceLanguage::Tex => line.starts_with(b"%"),
        SourceLanguage::BibTeX
        | SourceLanguage::Dts
        | SourceLanguage::Html
        | SourceLanguage::Ini
        | SourceLanguage::Markdown
        | SourceLanguage::Matlab
        | SourceLanguage::Pascal
        | SourceLanguage::Scheme => false,
    }
}

/// The symbol `line` declares in `language`, if any — the line without its ending and outer
/// whitespace.
fn source_symbol_from_line(language: SourceLanguage, line: &[u8]) -> Option<&[u8]> {
    let line = strip_line_ending(line);
    let trimmed_line = trim_line(line);
    let line_to_match = match language {
        // Keep leading whitespace so the C-like matcher excludes indented calls/control flow
        // inside a function (and, deliberately, indented C++ class methods and namespace members).
        SourceLanguage::CLike | SourceLanguage::CLikeOrObjC => line,
        _ => trimmed_line,
    };
    (!is_comment_line(language, trimmed_line) && language.is_source_symbol(line_to_match)).then_some(trimmed_line)
}

/// Finds source symbols near line ranges in one version of a file.
pub(crate) struct SourceSymbolScanner<'a> {
    /// Each symbol's 0-based line and text, in line order.
    symbols: Vec<(usize, &'a [u8])>,
}

impl<'a> SourceSymbolScanner<'a> {
    /// The symbols of `content` in `language`.
    pub(crate) fn new(language: SourceLanguage, content: &'a [u8]) -> Self {
        Self {
            symbols: content
                .split_inclusive(|byte| *byte == b'\n')
                .enumerate()
                .filter_map(|(line_number, line)| Some((line_number, source_symbol_from_line(language, line)?)))
                .collect(),
        }
    }

    /// A symbol on the first line of a nonempty range, or the closest symbol strictly before the
    /// range; with no preceding symbol, the first symbol in the range (a newly added section).
    pub(crate) fn find(&self, line_range: &Range<usize>) -> Option<&'a [u8]> {
        let preceding_end = self.symbols.partition_point(|(line, _)| *line < line_range.start);
        let first_in_range = self
            .symbols
            .get(preceding_end)
            .filter(|(line, _)| *line < line_range.end);
        if let Some(&(_, symbol)) = first_in_range.filter(|(line, _)| *line == line_range.start) {
            return Some(symbol);
        }
        self.symbols[..preceding_end]
            .last()
            .or(first_in_range)
            .map(|(_, symbol)| *symbol)
    }
}

/// `trim_source_symbol` (`cli/src/diff_util.rs:1849-1861` @ v0.46.0): Git's 80-byte limit; a run of
/// non-ASCII bytes the limit splits is dropped whole.
pub(crate) fn trim_source_symbol(source_symbol: &[u8]) -> &[u8] {
    const MAX_SOURCE_SYMBOL_LEN: usize = 80;
    let mut end = source_symbol.len().min(MAX_SOURCE_SYMBOL_LEN);
    if source_symbol.get(end).is_some_and(|byte| *byte >= 0x80) {
        while end > 0 && source_symbol[end - 1] >= 0x80 {
            end -= 1;
        }
    }
    &source_symbol[..end]
}

#[cfg(test)]
mod tests {
    use super::{source_symbol_from_line, trim_source_symbol, SourceLanguage, SourceSymbolScanner};

    fn symbols(language: SourceLanguage, content: &[u8]) -> Vec<(usize, &[u8])> {
        SourceSymbolScanner::new(language, content).symbols
    }

    /// The CLI's `test_source_symbol_patterns` table, as plain asserts.
    #[test]
    #[allow(clippy::too_many_lines)] // WHY: the CLI's table, one flat line per sample
    fn source_symbol_patterns_match_the_clis_table() {
        use SourceLanguage::{
            BibTeX, CLike, CSharp, Dts, Elixir, Go, Html, Ini, Java, JavaScript, Kotlin, Markdown, Matlab, ObjC,
            Pascal, Perl, Php, Python, Ruby, Scheme, Shell, Tex, R,
        };
        let samples: &[(SourceLanguage, &str, bool)] = &[
            (BibTeX, "@article{example,", true),
            (BibTeX, "@string { name = value }", true),
            (BibTeX, "plain text", false),
            (CLike, "static int example(int value)", true),
            (CLike, "void *pointer(void)", true),
            (CLike, "    call(value)", false),
            (CLike, "if (condition)", false),
            (CLike, "label: call()", false),
            (CSharp, "public class Example", true),
            (CSharp, "namespace Example.Core", true),
            (CSharp, "public async Task<int> Run(int value)", true),
            (CSharp, "if (condition)", false),
            (Dts, "/ {", true),
            (Dts, "device_node {", true),
            (Dts, "property = <1>;", false),
            (Elixir, "defmodule Example do", true),
            (Elixir, "defp run(value) do", true),
            (Elixir, "if ready do", false),
            (Go, "func Example(value int) int {", true),
            (Go, "type Example struct {", true),
            (Go, "var example = func() {}", false),
            (Html, "<h2 class=\"title\">Example</h2>", true),
            (Html, "<H1>Title</H1>", true),
            (Html, "<p>text</p>", false),
            (Ini, "[section]", true),
            (Ini, "[section.subsection] value", true),
            (Ini, "key = value", false),
            (Java, "public class Example", true),
            (Java, "public static String run(int value)", true),
            (Java, "if (condition)", false),
            (JavaScript, "export async function example() {", true),
            (JavaScript, "class Example {", true),
            (JavaScript, "handler = async (event) => {", true),
            (JavaScript, "if (condition) {", false),
            (Kotlin, "public fun example(value: Int)", true),
            (Kotlin, "data class Example", true),
            (Kotlin, "if (condition)", false),
            (Markdown, "# Title", true),
            (Markdown, "###### Detail", true),
            (Markdown, "plain text", false),
            (Markdown, "#missing-space", false),
            (Matlab, "function y = example(x)", true),
            (Matlab, "classdef Example", true),
            (Matlab, "%% Section", true),
            (Matlab, "y = x + 1;", false),
            (ObjC, "- (void)example:(id)value", true),
            (ObjC, "@interface Example : NSObject", true),
            (ObjC, "if (condition)", false),
            (Pascal, "function Example(Value: Integer): Integer;", true),
            (Pascal, "TExample = class(TObject)", true),
            (Pascal, "var Value: Integer;", false),
            (Perl, "package Example;", true),
            (Perl, "sub example : prototype($) {", true),
            (Perl, "BEGIN {", true),
            (Perl, "=head1 Documentation", true),
            (Perl, "my $value = 1;", false),
            (Php, "public static function example($value) {", true),
            (Php, "final class Example {", true),
            (Php, "if ($condition) {", false),
            (Python, "async def example(value):", true),
            (Python, "class Example:", true),
            (Python, "if condition:", false),
            (R, "example <- function(value) {", true),
            (R, "example.name = function(value) {", true),
            (R, "if (condition) {", false),
            (Ruby, "module Example", true),
            (Ruby, "def example(value)", true),
            (Ruby, "if condition", false),
            (
                SourceLanguage::Rust,
                "pub(crate) async fn example(value: i32) -> i32 {",
                true,
            ),
            (SourceLanguage::Rust, "impl<T> Example<T> {", true),
            (SourceLanguage::Rust, "macro_rules! example {", true),
            (SourceLanguage::Rust, "if condition {", false),
            (Scheme, "(define (example value)", true),
            (Scheme, "(module example scheme", true),
            (Scheme, "(display value)", false),
            (Scheme, "display value", false),
            (Shell, "example() {", true),
            (Shell, "function example {", true),
            (Shell, "if condition; then", false),
            (Tex, "\\section{Example}", true),
            (Tex, "\\subsubsection*{Detail}", true),
            (Tex, "plain text", false),
        ];
        for &(language, line, expected) in samples {
            assert_eq!(
                language.is_source_symbol(line.as_bytes()),
                expected,
                "{language:?}: {line:?}"
            );
        }
    }

    /// `test_collect_source_symbols_ignores_c_comments_and_indentation`.
    #[test]
    fn c_comments_and_indented_lines_are_not_symbols() {
        let content =
            b"void outer(void)\n/*\n * misleading(comment)\n */\n    call(value);\nextern int actual(int value);\n";
        assert_eq!(
            symbols(SourceLanguage::CLike, content),
            [
                (0, &b"void outer(void)"[..]),
                (5, &b"extern int actual(int value);"[..])
            ]
        );
    }

    /// `test_source_symbol_scanner_finds_pointer_returning_c_function`.
    #[test]
    fn the_scanner_finds_a_pointer_returning_c_function() {
        let content = b"int\n*foo(void) {\n    return 0;\n}\n";
        for language in [SourceLanguage::CLike, SourceLanguage::CLikeOrObjC] {
            let scanner = SourceSymbolScanner::new(language, content);
            assert_eq!(scanner.find(&(2..3)), Some(&b"*foo(void) {"[..]));
        }
    }

    /// `test_source_symbol_scanner_uses_first_symbol_in_range`.
    #[test]
    fn the_scanner_uses_the_first_symbol_in_the_range() {
        let scanner = SourceSymbolScanner::new(
            SourceLanguage::Rust,
            b"preamble\n\nfn first() {\n}\n\nfn second() {\n}\n",
        );
        assert_eq!(scanner.find(&(1..7)), Some(&b"fn first() {"[..]));
        assert_eq!(scanner.find(&(1..2)), None);
    }

    /// `test_source_symbol_scanner_range_start`.
    #[test]
    fn the_scanner_prefers_the_range_start_then_the_preceding_symbol() {
        let scanner = SourceSymbolScanner::new(SourceLanguage::Rust, b"fn first() {\n}\n\nfn second() {\n}\n");
        // An exact match takes precedence over the preceding symbol.
        assert_eq!(scanner.find(&(3..4)), Some(&b"fn second() {"[..]));
        // Empty ranges exclude the symbol at their start.
        assert_eq!(scanner.find(&(3..3)), Some(&b"fn first() {"[..]));
        assert_eq!(scanner.find(&(0..0)), None);
        // A preceding symbol takes precedence over a later symbol in the range.
        assert_eq!(scanner.find(&(2..5)), Some(&b"fn first() {"[..]));
    }

    /// `test_source_symbol_scanner_handles_ambiguous_objc_extension`.
    #[test]
    fn the_scanner_handles_the_ambiguous_m_extension() {
        let objc = SourceSymbolScanner::new(
            SourceLanguage::MatlabOrObjC,
            b"@implementation Example\n- (void)method {\n    value++;\n}\n@end\n",
        );
        assert_eq!(objc.find(&(2..3)), Some(&b"- (void)method {"[..]));
        let matlab = SourceSymbolScanner::new(
            SourceLanguage::MatlabOrObjC,
            b"%% Section\nfunction y = example(x)\ny = x + 1;\nend\n",
        );
        assert_eq!(matlab.find(&(0..1)), Some(&b"%% Section"[..]));
        assert_eq!(matlab.find(&(2..3)), Some(&b"function y = example(x)"[..]));
    }

    /// Languages come from the last path component; Dart has none.
    #[test]
    fn the_language_comes_from_the_file_name() {
        assert!(matches!(
            SourceLanguage::from_file_name("lib.rs"),
            Some(SourceLanguage::Rust)
        ));
        assert!(matches!(
            SourceLanguage::from_file_name("x.h"),
            Some(SourceLanguage::CLikeOrObjC)
        ));
        assert!(matches!(
            SourceLanguage::from_file_name("x.mm"),
            Some(SourceLanguage::CLikeOrObjC)
        ));
        assert!(matches!(
            SourceLanguage::from_file_name("Gemfile"),
            Some(SourceLanguage::Ruby)
        ));
        assert!(matches!(SourceLanguage::from_file_name("x.R"), Some(SourceLanguage::R)));
        assert!(SourceLanguage::from_file_name("main.dart").is_none());
        assert!(SourceLanguage::from_file_name("Makefile").is_none());
    }

    /// A symbol is the line without its ending and outer whitespace; comments are none.
    #[test]
    fn a_symbol_is_the_trimmed_line() {
        assert_eq!(
            source_symbol_from_line(SourceLanguage::Rust, b"  fn main() {\r\n"),
            Some(&b"fn main() {"[..])
        );
        assert_eq!(source_symbol_from_line(SourceLanguage::Rust, b"// fn main() {\n"), None);
        assert_eq!(source_symbol_from_line(SourceLanguage::Python, b"# def x(y):\n"), None);
        assert_eq!(source_symbol_from_line(SourceLanguage::Tex, b"% \\section{x}\n"), None);
        assert_eq!(
            source_symbol_from_line(SourceLanguage::Markdown, b"# Title\n"),
            Some(&b"# Title"[..])
        );
    }

    /// Git's 80-byte limit; a non-ASCII run the limit splits is dropped whole.
    #[test]
    fn trimming_keeps_80_bytes_and_whole_non_ascii_runs() {
        assert_eq!(trim_source_symbol(b"fn main() {"), b"fn main() {");
        let long = [b'a'; 100];
        assert_eq!(trim_source_symbol(&long), &long[..80]);
        let mut split = vec![b'a'; 78];
        split.extend_from_slice("äö".as_bytes());
        assert_eq!(trim_source_symbol(&split), &split[..78]);
        let mut exact = vec![b'a'; 79];
        exact.extend_from_slice(b"\xc3");
        assert_eq!(trim_source_symbol(&exact), &exact[..80]);
        assert_eq!(trim_source_symbol("ä".repeat(41).as_bytes()), b"");
    }
}
