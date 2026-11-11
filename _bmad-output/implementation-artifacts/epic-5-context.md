# Epic 5 Context: `zanshin-diff` — Word-Diff + Syntax Highlight

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Epic 5 gives Zanshin a structured diff between any two revisions: files → hunks → lines → segments, computed in Rust and sent to Dart as a FlatBuffers payload. It feeds the inspector's diff view, hunk selection and the selection-to-tree path, so its line level matches the jj CLI. Everything is delivered: the line-level path (hunks, payload, revision API, FFI extern and worker command), the word-level segments inside changed lines (`imara-diff` Histogram, 5.2), and their tree-sitter syntax classes for the first three grammars, Rust, Dart and Markdown (5.3 with 5.4). No UI renders segments or classes yet.

## Stories

- Story 5.1: Line-level hunks via jj-lib (done)
- Story 5.2: Word-level diff via `imara-diff` Histogram (done)
- Story 5.3: tree-sitter-highlight integration (done, with 5.4)
- Story 5.4: Bundle initial 3 grammars — Rust / Dart / Markdown (done, with 5.3)
- Story 5.5: Diff FlatBuffers payload (done, line-level only)
- Story 5.6: Diff between two revisions API (done)
- Story 5.7: 5k-line performance test (deleted)
- Story 5.8: FFI wrapper `zanshin-ffi/src/diff.rs` (done)

## Requirements & Constraints

- **Word diff (5.2).** Only inside changed lines, with `imara-diff`'s Histogram algorithm. Do not swap in `similar`: it is far slower on large diffs. Tokens follow Unicode word boundaries. A run of removed lines pairs in order with the run of added lines after it; leftover lines get no word diff and become one whole-line segment, and so does a pair with a line longer than 131,072 characters. Context lines are never word-diffed. Whitespace-only and trailing-whitespace changes show as small segments.
- **Highlighting (5.3).** `tree-sitter-highlight`, one line at a time (its text, `\n` included), by the file's language. Best effort: invalid syntax yields whatever classes tree-sitter's error recovery gives, never an error; a line is classified out of context, so its classes can be missing or wrong (a Dart statement from a method body, a line inside a block comment; `docs/ffi-abi.md` lists the cases). Plain text, a line over 131,072 characters (5.2's cap, now the crate's one long-line rule) and a highlighter error yield no classes. No fallback parsers, no retries, no incremental or whole-file highlighting.
- **Grammars (5.4).** Bundle only Rust, Dart and Markdown. Detect the language from the final extension, ASCII case-insensitive: `rs`, `dart`, `md` / `markdown`. Everything else is plain text. There is no file-name registry: every name the plan listed (`Cargo.toml`, `Cargo.lock`, `pubspec.yaml`, `pubspec.lock`, `Dockerfile`) is plain text by the extension rule; the registry arrives with the first grammar that needs one. More languages come later, one small additive change each. The nine-language lists in 5.3's and 5.4's ACs (TypeScript, Python, TOML, YAML, JSON, HTML, …) predate the shrink.
- **Output shape.** A segment has its text, a `kind` (Equal / Added / Removed) and an optional `syntax_class`. Segments split at syntax-token boundaries, so each has one class; adjacent segments differ in kind or class. Classes come from one fixed set: Keyword, String, Escape, Comment, Function, Type, Variable, Property, Number, Constant, Operator, Punctuation, Attribute, Heading, Emphasis, Strong, Link, Code. Each file carries its language (a binary file too; the description block is plain text). Binary files carry no lines.
- **Robustness.** Very long lines (minified code, 100k characters) must finish in reasonable time. NUL bytes, emoji and accented text must not panic.
- **Rust computes, Dart decodes.** The UI computes nothing about the diff.
- **Performance.** A 5k-line changed file in under 500 ms is a soft target. There is no perf test and no CI gate.
- **Non-goal:** AST-level structural diffs (difftastic class).

## Technical Decisions

- **Delivered code.** Only `zanshin-jj` imports jj-lib, so the line-level read lives there: `crates/zanshin-jj/src/hunks.rs` with `Repo::compute_hunks` (two trees in) and `Repo::diff(&DiffOptions) -> RevisionDiff`. The payload builder is `zanshin_ffi::diff::diff_to_envelope` in `crates/zanshin-ffi/src/diff.rs`. The epic's older names (`crates/zanshin-diff/src/{hunks,output}.rs`, `compute_diff`, `DiffOutput`, `DiffError`, change-id inputs) are superseded.
- **Enrichment home.** Word diff and highlighting are pure text algorithms in the plain `lib` crate `zanshin-diff`: no jj-lib, no `extern "C"`, no `tree_sitter` type in its public API. `zanshin-diff` depends on `zanshin-jj` (for `HunkLine` only), and `zanshin-ffi` on `zanshin-diff`. `word_diff.rs` (5.2): `compute_word_diff`, `line_segments`. `grammars.rs` (5.4): `Language`, `detect_language`, one tree-sitter-highlight configuration per grammar (built once per process, `LazyLock`; a failed build = no classes). `highlight.rs` (5.3): `SyntaxClass`, `highlight_line` (a per-thread `Highlighter`), `merge_highlight` (splits 5.2's segments at token boundaries). `diff_to_envelope` detects each file's language from `FileDiff.path` and builds each line's segments as `merge_highlight(line_segments(hunk)[i], highlight_line(text, language))`; `Repo::diff`'s data stays line-level.
- **Captures and queries.** Captures map to the class set by tree-sitter-highlight's `configure` rule (most matching name parts, the earlier name on a tie): `keyword` before `operator` (Dart's `keyword.operator` is a keyword); constructors, Rust's upper-case names and its lifetimes' names are Type, Rust's number literals (`constant.builtin`) Constant. Each grammar uses its crate's embedded highlight query; Rust keeps its macro-body injection, at most 16 injected layers per line (each nesting level parses its content again); Markdown's block grammar injects the inline grammar through Zanshin's own pattern with `injection.include-children` (the shipped one misses emphasis, code and links).
- **Line facts to build on.** A hunk line is `Context`, `Removed` or `Added` and keeps its trailing `\n`; a missing one marks the end-of-file state. A conflicted file is diffed with its conflict materialized, as `jj diff` does. Summary mode returns files without hunks.
- **Transport.** FlatBuffers (ADR-0001), not JSON: no serde, no JSON Schema, no `schema_version`. `schemas/envelope.fbs` holds `Diff` → `FileDiff` (+ `language: DiffLanguage`, 5.4) → `Hunk` → `HunkLine` (+ `HunkLineKind`) → `Segment` (+ `SegmentKind`, 5.2; `syntax_class: SyntaxClass`, 5.3, `Unclassified` = none). Dart decodes them in `packages/zanshin_core/lib/src/ffi/diff.dart` (`FileDiff.language`, `Segment.syntaxClass`, `DiffLanguage`, `SyntaxClass`). Tests read through the typed accessors and the `Verifier`. Dart calls `RepoHandle.diff` → `Future<Diff>` (extern `zanshin_diff`, a `DiffRequest` buffer in). No caching. A highlighted line costs roughly two segments per token on the wire.
- **Dependencies.** Exact pins (`=x.y.z`), permissive licences: `imara-diff =0.2.0` (Apache-2.0), `unicode-segmentation =1.13.3`, `tree-sitter =0.27.1`, `tree-sitter-highlight =0.27.1`, `tree-sitter-rust =0.24.2`, `tree-sitter-dart =0.3.0`, `tree-sitter-md =0.5.4` (all MIT; 0.27.1 rather than 0.27.2 because of `.cargo/config.toml`'s 7-day `global-min-publish-age`). `default-features = false` needs a `# WHY:` comment.
- **Existing language table.** 5.1's source-symbol port already maps file names to languages, as the CLI does; Dart has no symbol pattern there.

## UX & Interaction Patterns

- The design shows no word-level or syntax marks yet. The inspector's diff view renders line-level only. Drawing word and syntax marks there is deferred UI work, not part of the diff view story (10.24).
- The inspector's side-by-side layout pairs runs of removed and added lines row by row and leaves unpaired cells empty. This is the same pairing 5.2 uses.

## Cross-Story Dependencies

- 5.3 builds on 5.2: it lays token classes over 5.2's segments. 5.3 and 5.4 were delivered together: the highlighter needs 5.4's grammars, queries and detection, and its tests need real grammars.
- The delivered line-level path (5.1 → 5.5 → 5.6 → 5.8) feeds the inspector diff view (10.24), hunk selection (10.26), hunk drags (10.27) and selection-to-tree (9.50, keyed by 5.1's sections; results pinned to an operation and commit id expose stale selections).
- A renderer for word and syntax marks has no story yet (deferred-work.md, "Word-level and syntax marks have no consumer story").
