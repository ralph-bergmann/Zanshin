// SPDX-License-Identifier: MIT

//! Story 5.4's language detection: the final extension, ASCII case-insensitive, decides; every
//! other path is plain text.

use std::path::Path;

use zanshin_diff::{detect_language, Language};

fn detected(path: &str) -> Language {
    detect_language(Path::new(path))
}

#[test]
fn the_bundled_extensions_are_detected_case_insensitively() {
    for (path, language) in [
        ("src/lib.rs", Language::Rust),
        ("a.DART", Language::Dart),
        ("lib/main.dart", Language::Dart),
        ("README.MD", Language::Markdown),
        ("x.markdown", Language::Markdown),
        ("docs/Guide.MarkDown", Language::Markdown),
    ] {
        assert_eq!(detected(path), language, "{path}");
    }
}

#[test]
fn the_final_extension_decides() {
    assert_eq!(detected("file.test.rs"), Language::Rust);
    assert_eq!(detected("a.rs.bak"), Language::PlainText);
    assert_eq!(detected("notes.md.txt"), Language::PlainText);
}

#[test]
fn every_other_path_is_plain_text() {
    // The names 5.4's registry once listed are plain text by the extension rule alone.
    for path in [
        "README",
        ".md",
        "dir/.rs",
        "Cargo.toml",
        "Cargo.lock",
        "pubspec.yaml",
        "pubspec.lock",
        "Dockerfile",
        "JJ-COMMIT-DESCRIPTION",
        "src/a.ts",
        "",
    ] {
        assert_eq!(detected(path), Language::PlainText, "{path:?}");
    }
}
