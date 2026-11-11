// SPDX-License-Identifier: MIT

//! The bundled grammars and language detection (Story 5.4, FR-DF-5): which language a diff's file
//! is highlighted in, and one tree-sitter-highlight configuration per bundled grammar.
//!
//! **Detection.** [`detect_language`] reads the path's final extension (`Path::extension`), ASCII
//! case-insensitive: `rs` is Rust, `dart` is Dart, `md` and `markdown` are Markdown. Every other
//! path is plain text: no extension, a dotfile (`.md`), `a.rs.bak`. There is no registry of known
//! file names: every name the plan listed (`Cargo.toml`, `Cargo.lock`, `pubspec.yaml`,
//! `pubspec.lock`, `Dockerfile`) is plain text by the extension rule already, so the registry
//! arrives with the first grammar that needs one. A new grammar is one dependency, one variant, its
//! extensions and its configuration.
//!
//! **Queries.** Each grammar uses its crate's embedded highlight query. Rust keeps its shipped
//! injection, which highlights macro bodies as Rust; Markdown's block grammar injects its inline
//! grammar through its own pattern (`MARKDOWN_BLOCK_INJECTION`). Each configuration is built once
//! per process, on first use; one that fails to build gives its language no classes.
//!
//! **Per-line limits.** The highlighter sees one diff line at a time ([`crate::highlight_line`]),
//! so a construct that spans lines is classified from its line alone, Markdown's fenced code, HTML
//! blocks and front matter never apply, and a line over 131,072 characters gets no classes.

use std::path::Path;
use std::sync::LazyLock;

use tree_sitter_highlight::HighlightConfiguration;

use crate::highlight::CAPTURES;

/// The language a diff's file is highlighted in: a bundled grammar, or plain text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Language {
    /// No grammar: the file's lines get no syntax classes.
    PlainText,
    /// `.rs`
    Rust,
    /// `.dart`
    Dart,
    /// `.md`, `.markdown`
    Markdown,
}

impl Language {
    /// The language's highlight configuration: `None` for plain text, and for a grammar whose
    /// configuration failed to build.
    pub(crate) fn config(self) -> Option<&'static HighlightConfiguration> {
        match self {
            Self::PlainText => None,
            Self::Rust => RUST.as_ref(),
            Self::Dart => DART.as_ref(),
            Self::Markdown => MARKDOWN.as_ref(),
        }
    }
}

/// The language of the file at `path`, by the detection rule in the module documentation.
#[must_use]
pub fn detect_language(path: &Path) -> Language {
    path.extension()
        .and_then(|extension| {
            EXTENSIONS
                .iter()
                .find(|(known, _)| extension.eq_ignore_ascii_case(known))
        })
        .map_or(Language::PlainText, |&(_, language)| language)
}

const EXTENSIONS: [(&str, Language); 4] = [
    ("rs", Language::Rust),
    ("dart", Language::Dart),
    ("md", Language::Markdown),
    ("markdown", Language::Markdown),
];

/// The configuration a highlight query injects by name: Rust into a macro body, Markdown's inline
/// grammar into a block's inline content. Any other name injects nothing.
// WHY `'a`: tree-sitter-highlight's injection callback must return the highlight call's lifetime,
// so a `'static` return type would pin that call to `'static`.
pub(crate) fn injected<'a>(name: &str) -> Option<&'a HighlightConfiguration> {
    match name {
        "rust" => RUST.as_ref(),
        "markdown_inline" => MARKDOWN_INLINE.as_ref(),
        _ => None,
    }
}

// WHY: the shipped block injection query injects `markdown_inline` without
// `injection.include-children`, so the inline layer misses the delimiters (`*`, `` ` ``, `[`) that
// are children of the `inline` node and never sees emphasis, code or links. Its other injections
// (fenced code, HTML, front matter) never apply to one line.
const MARKDOWN_BLOCK_INJECTION: &str = r#"((inline) @injection.content
 (#set! injection.language "markdown_inline")
 (#set! injection.include-children))"#;

static RUST: LazyLock<Option<HighlightConfiguration>> = LazyLock::new(|| {
    build(
        tree_sitter_rust::LANGUAGE.into(),
        "rust",
        tree_sitter_rust::HIGHLIGHTS_QUERY,
        tree_sitter_rust::INJECTIONS_QUERY,
    )
});

static DART: LazyLock<Option<HighlightConfiguration>> = LazyLock::new(|| {
    build(
        tree_sitter_dart::LANGUAGE.into(),
        "dart",
        tree_sitter_dart::HIGHLIGHTS_QUERY,
        "",
    )
});

static MARKDOWN: LazyLock<Option<HighlightConfiguration>> = LazyLock::new(|| {
    build(
        tree_sitter_md::LANGUAGE.into(),
        "markdown",
        tree_sitter_md::HIGHLIGHT_QUERY_BLOCK,
        MARKDOWN_BLOCK_INJECTION,
    )
});

// The inline grammar's own injections (HTML, LaTeX) name grammars Zanshin does not bundle.
static MARKDOWN_INLINE: LazyLock<Option<HighlightConfiguration>> = LazyLock::new(|| {
    build(
        tree_sitter_md::INLINE_LANGUAGE.into(),
        "markdown_inline",
        tree_sitter_md::HIGHLIGHT_QUERY_INLINE,
        "",
    )
});

/// A configuration whose captures map to `CAPTURES`' names by tree-sitter-highlight's `configure`
/// rule.
fn build(
    language: tree_sitter::Language,
    name: &str,
    highlights: &str,
    injections: &str,
) -> Option<HighlightConfiguration> {
    let mut config = HighlightConfiguration::new(language, name, highlights, injections, "").ok()?;
    config.configure(&CAPTURES.map(|(name, _)| name));
    Some(config)
}

#[cfg(test)]
mod tests {
    use super::{injected, Language};
    use crate::highlight::CAPTURES;

    /// The name in `CAPTURES` tree-sitter-highlight's `configure` picks for `capture`: the one
    /// whose parts all occur in the capture's, the most parts first, the earlier one on a tie.
    fn recognized(capture: &str) -> Option<&'static str> {
        let parts: Vec<&str> = capture.split('.').collect();
        let mut best: Option<(&str, usize)> = None;
        for (name, _) in CAPTURES {
            let len = name.split('.').count();
            if name.split('.').all(|part| parts.contains(&part)) && best.is_none_or(|(_, most)| len > most) {
                best = Some((name, len));
            }
        }
        best.map(|(name, _)| name)
    }

    #[test]
    fn every_bundled_configuration_builds_and_every_capture_maps() {
        let configs = [
            Language::Rust.config(),
            Language::Dart.config(),
            Language::Markdown.config(),
            injected("markdown_inline"),
        ];
        for config in configs {
            let config = config.expect("the configuration builds");
            let unmapped: Vec<&str> = config
                .names()
                .iter()
                .copied()
                .filter(|&capture| !capture.starts_with("injection.") && capture != "none")
                .filter(|&capture| recognized(capture).is_none())
                .collect();
            assert!(unmapped.is_empty(), "{}: {unmapped:?}", config.language_name);
        }
    }

    #[test]
    fn the_capture_rule_takes_the_most_parts_then_the_earlier_name() {
        assert_eq!(recognized("string.escape"), Some("string.escape"));
        assert_eq!(recognized("string.special.symbol"), Some("string"));
        assert_eq!(recognized("keyword.operator"), Some("keyword"));
        assert_eq!(recognized("constant.builtin"), Some("constant"));
        assert_eq!(recognized("text.title"), Some("text.title"));
        assert_eq!(recognized("none"), None);
    }

    #[test]
    fn plain_text_has_no_configuration_and_an_unbundled_injection_injects_nothing() {
        assert!(Language::PlainText.config().is_none());
        assert!(injected("rust").is_some());
        assert!(injected("html").is_none());
    }
}
