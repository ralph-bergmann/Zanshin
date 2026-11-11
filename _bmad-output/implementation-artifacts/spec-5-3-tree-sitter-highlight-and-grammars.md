---
title: 'Story 5.3 (with 5.4) — tree-sitter syntax classes on every diff segment; Rust, Dart and Markdown grammars'
type: 'feature'
created: '2026-11-11'
status: 'done'
baseline_revision: 'd8502832f4feabba67dffd2898371cccc1c03e50'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Story 5.2's segments say only whether a run is equal, added or removed. Nothing marks keywords, strings or comments, so no consumer can render a syntax-highlighted diff (FR-DF-2), and no tree-sitter grammar is bundled (FR-DF-5, shrunk to Rust, Dart, Markdown). The highlighter needs Story 5.4's grammars, queries and detection, and its tests need real grammars (sprint-status: 5.3 "gehört mit 5.4 zusammen"), so this run delivers 5.3 and 5.4 together.

**Approach:** `zanshin-diff` gains `grammars.rs` (`Language`, `detect_language`, one tree-sitter-highlight configuration per bundled grammar, built once) and `highlight.rs` (`SyntaxClass`, `highlight_line` — one line at a time — and `merge_highlight`, which splits 5.2's segments at token boundaries). `diff_to_envelope` writes each file's `language` and each segment's `syntax_class`; Dart decodes both.

## Boundaries & Constraints

**Always:**
- Highlighting runs tree-sitter-highlight over ONE line (its text, `\n` included), best effort: invalid syntax yields whatever classes tree-sitter's error recovery gives, never an error. `PlainText`, a line over 131,072 characters (5.2's cap, now shared as the crate's one long-line rule) and a highlighter error yield one unclassified token.
- `highlight_line`'s tokens are byte ranges on char boundaries, non-empty, contiguous from 0 to the line's length; adjacent tokens differ in class; uncaptured text (whitespace included) is unclassified (`None`).
- `merge_highlight(segments, tokens)` splits each segment at token boundaries: every output segment has one kind and one class, none is empty, the texts concatenate to the line, adjacent segments differ in kind or class. Dropping the classes and joining adjacent same-kind runs gives 5.2's segments back; a plain-text line keeps 5.2's segments exactly, each with `None`. It never panics, whatever tokens it gets.
- One fixed `SyntaxClass` set: `Keyword, String, Escape, Comment, Function, Type, Variable, Property, Number, Constant, Operator, Punctuation, Attribute, Heading, Emphasis, Strong, Link, Code`. Captures map through the Design Notes table with tree-sitter-highlight's `configure` rule (most matching name parts; on a tie the earlier entry). Every capture of the bundled queries maps to a class, except `injection.*` and Markdown's `none`.
- Detection: the final extension, ASCII case-insensitive (`Path::extension`): `rs` → Rust, `dart` → Dart, `md` / `markdown` → Markdown; everything else → `PlainText` (no extension, a dotfile, `Cargo.toml`, `pubspec.yaml`, `Dockerfile`, `README`). One language per file, from `FileDiff.path` (a copy's target); the description block (`JJ-COMMIT-DESCRIPTION`) is plain text; a binary file still carries its path's language.
- Queries are the grammar crates' embedded ones (Rust's macro-body injection as shipped), except Markdown's block injection: one own pattern injecting `markdown_inline` with `injection.include-children`. Configurations are built once per process (`LazyLock`, a failed build = no classes for that language); the `Highlighter` is reused per thread.
- Wire, append-only: `enum SyntaxClass : ubyte { Unclassified, Keyword, …, Code }` (0 = no class) as `Segment.syntax_class`; `enum DiffLanguage : ubyte { PlainText, Rust, Dart, Markdown }` as `FileDiff.language`. Dart: `Segment.syntaxClass` (`SyntaxClass?`, null = none) and `FileDiff.language` (`DiffLanguage`, default `plainText`) as optional named parameters, both enums exported from `zanshin_core.dart`.
- Dependencies exact-pinned in `[workspace.dependencies]` with a `# WHY:`, all MIT, each published at least 7 days ago (`.cargo/config.toml`'s `global-min-publish-age`): `tree-sitter =0.27.1`, `tree-sitter-highlight =0.27.1`, `tree-sitter-rust =0.24.2`, `tree-sitter-dart =0.3.0`, `tree-sitter-md =0.5.4`.

**Never:** No change to `zanshin-jj` or its tests. No jj-lib in `zanshin-diff`. No fallback parsers, retries, incremental or whole-file highlighting. No UI rendering. No new extern, request field, error code or cache. No grammar beyond the three. No `tree_sitter` type in `zanshin-diff`'s public API. No panic on any input.

## I/O & Edge-Case Matrix

Notation: `text:Class`; a bare `text` is unclassified; `=`/`-`/`+` prefix a segment's kind.

| Scenario | Input | Expected | Error Handling |
|----------|-------|----------|----------------|
| AC Rust line | `fn foo(x: i32) -> i32` (Rust) | `fn:Keyword`, ` `, `foo:Function`, `(:Punctuation`, `x:Variable`, `::Punctuation`, ` `, `i32:Type`, `):Punctuation`, ` -> `, `i32:Type` | — |
| Rust literals | `let s = "a\nb"; // c` + newline (`\n` in the string is backslash, `n`) | `let:Keyword`, ` s = `, `"a:String`, backslash-`n`:Escape, `b":String`, `;:Punctuation`, ` `, `// c:Comment`, newline | — |
| Rust macro (injection) | `    println!("{}", x);` | `println!:Function`, `"{}":String` among the tokens | — |
| Invalid Rust | `fn foo(` | `fn:Keyword`, ` foo`, `(:Punctuation` | partial, no error |
| Dart class | `class Foo extends Bar {}` | `class:Keyword`, ` `, `Foo:Type`, ` `, `extends:Keyword`, ` `, `Bar:Type`, ` `, `{}:Punctuation` | — |
| Dart field | `  final int x = 42; // c` + `\n` | `final:Keyword`, `int:Type`, `x:Variable`, `=:Operator`, `42:Number`, `;:Punctuation`, `// c:Comment` | — |
| Markdown heading | `# Title\n` | `#:Punctuation`, ` `, `Title:Heading`, `\n` | — |
| Markdown inline | `see [a](b) and **x**\n` | `see `, `[:Punctuation`, `a:Link`, `](:Punctuation`, `b:Link`, `):Punctuation`, ` and `, `**:Punctuation`, `x:Strong`, `**:Punctuation`, `\n` | — |
| Plain text | any line, `PlainText` | one token, `None`; an empty line none | — |
| Robustness | `a\0b é 🎉\n` in each language | tokens on char boundaries, concatenating to the line | no panic |
| Long line | ~100k-character Rust line; a 131,073-character line | classified, completes; one unclassified token | — |
| Merge | segments `=fn foo(`, `-x`, `=: i32) -> `, `-i32` + the AC Rust tokens | `=fn:Keyword`, `= `, `=foo:Function`, `=(:Punctuation`, `-x:Variable`, `=::Punctuation`, `= `, `=i32:Type`, `=):Punctuation`, `= -> `, `-i32:Type` | — |
| Detection | `src/lib.rs`, `a.DART`, `README.MD`, `x.markdown`, `file.test.rs` / `README`, `.md`, `a.rs.bak`, `Cargo.toml`, `Dockerfile` | Rust, Dart, Markdown, Markdown, Rust / PlainText for all five | — |
| Real repo (FFI + Dart) | `lib.rs` `fn a() {}` → `fn b() {}`; `f.txt` as 5.2 | `FileDiff.language` Rust; removed line `=fn:Keyword`, `= `, `-a:Function`, `=():Punctuation`, `= `, `={}:Punctuation`, `=\n`; `f.txt` PlainText, 5.2's segments, no class | — |

</intent-contract>

## Code Map

- `crates/zanshin-diff/src/lib.rs:1-8` -- crate doc + re-exports; add `mod grammars; mod highlight;` and their public items.
- `crates/zanshin-diff/src/word_diff.rs:24-26,86` -- `MAX_PAIRED_LINE_CHARS` (131,072) becomes the crate's shared long-line cap (`pub(crate)`, renamed `MAX_LINE_CHARS`); `Segment` / `SegmentKind` are the merge input. No behaviour change.
- `crates/zanshin-diff/Cargo.toml:12-17`, `Cargo.toml:27-68` -- dependencies; every workspace entry carries a `# WHY:` (deny.toml forbids wildcards).
- tree-sitter-highlight 0.27.1 (`$CARGO_HOME/registry/src/index.crates.io-1949cf8c6b5b557f/tree-sitter-highlight-0.27.1/src/highlight.rs`) -- `HighlightConfiguration::new(language, name, highlights, injections, locals) -> Result<_, QueryError>` (:352), `configure(&names)` (:471, the part-matching rule), `Highlighter::highlight(config, bytes, None, None, injection_callback) -> Result<impl Iterator<Item = Result<HighlightEvent, Error>>, Error>` (:294); `HighlightEvent::{Source{start,end}, HighlightStart(Highlight(index)), HighlightEnd}` — `Source` events are non-empty and cover `0..len` (:824-842, :913-923). `HighlightConfiguration` is immutable and shareable across threads; a `Highlighter` is per thread.
- Grammar crates (same registry): `tree_sitter_rust::{LANGUAGE, HIGHLIGHTS_QUERY, INJECTIONS_QUERY}`; `tree_sitter_dart::{LANGUAGE, HIGHLIGHTS_QUERY}` (no injections); `tree_sitter_md::{LANGUAGE, INLINE_LANGUAGE, HIGHLIGHT_QUERY_BLOCK, HIGHLIGHT_QUERY_INLINE}`. `LanguageFn.into()` gives `tree_sitter::Language`. All grammars are ABI 15 (tree-sitter 0.27 accepts 13–15).
- `crates/zanshin-ffi/src/diff.rs:179-272` -- `file_offset` / `hunk_offset` / `line_offset` / `segment_offset`: detect the language per file, highlight and merge per line, write `language` and `syntax_class`. `:566-627` -- the segment unit test whose `src/a.rs` lines now carry classes; `:435-503` -- `sample()`.
- `crates/zanshin-ffi/tests/it/diff_ffi.rs:37-80,102-220` -- `computed()`, `segments_of`, `wire_segments`, `assert_wire_is` (compares segments to `line_segments` today).
- `schemas/envelope.fbs:3172-3251` -- `SegmentKind` / `Segment` / `HunkLine` / `FileDiff`; the new enums go before `Segment`.
- `packages/zanshin_core/lib/src/ffi/diff.dart:58-103,143-199,326-372` -- `SegmentKind` / `Segment` / `HunkLine` / `FileDiff` models, `_file` / `_line` decoders; `lib/zanshin_core.dart:34` -- exports. `FileDiff(` is constructed in app code and tests (`app/lib/src/features/graph/inspector_diff.dart`, fakes), hence the optional parameter.
- `packages/zanshin_core/lib/src/worker/handle.dart:1628-1630` -- `RepoHandle.diff`'s doc names the segments.
- `packages/zanshin_core/test/ffi/diff_test.dart:133-178` (synthetic decode), `test/worker/diff_test.dart:92-122` (real cdylib; its setUp files are listed by other tests, so the `.rs` witness writes its own file).
- `docs/ffi-abi.md:2464-2532` -- the `Diff` payload section.
- `_bmad-output/planning-artifacts/epics.md:4753-4905` -- Stories 5.3 and 5.4 (notes go under each heading); `sprint-status.yaml:30-43,66-71`; `deferred-work.md:1075-1079` ("Word-level and syntax marks have no consumer story"); `epic-5-context.md`.
- Probe evidence (scratch, release build, M-series Mac): per line 14 µs Rust / 8 µs Dart / 22 µs Markdown; a 100k-character line 21 / 44 / 59 ms (debug ~6x). Every matrix row's classes above are the probe's output.

## Tasks & Acceptance

**Execution:**
- `Cargo.toml`, `crates/zanshin-diff/Cargo.toml` -- the five tree-sitter dependencies with `# WHY:` (licence, pin reason, the 7-day rule for 0.27.1 over 0.27.2); `Cargo.lock` follows.
- `crates/zanshin-diff/src/word_diff.rs` -- rename the cap to `pub(crate) const MAX_LINE_CHARS`, its `shortcut:` comment naming both uses.
- `crates/zanshin-diff/src/grammars.rs` (new) -- `Language { PlainText, Rust, Dart, Markdown }`, `detect_language(&Path)`, the module doc (detection rule, why no file-name registry, per-line limits), `pub(crate) fn config(self) -> Option<&'static HighlightConfiguration>`, the injection lookup (`rust`, `markdown_inline`), the Markdown block injection const with its WHY; inline unit test: every bundled configuration builds and every capture name maps.
- `crates/zanshin-diff/src/highlight.rs` (new) -- `SyntaxClass`, `HighlightedToken { range, class }`, `HighlightedSegment { text, kind, syntax_class }`, the capture table, `highlight_line(&str, Language)` (thread-local `Highlighter`), `merge_highlight(&[Segment], &[HighlightedToken])`; module doc with the best-effort, one-line-at-a-time limitation.
- `crates/zanshin-diff/src/lib.rs` -- modules, re-exports, crate doc.
- `crates/zanshin-diff/tests/highlight.rs`, `tests/grammars.rs` (new) -- every non-FFI matrix row plus the token and merge invariants over all rows × languages, the injection paths, the cap boundary.
- `schemas/envelope.fbs` -- `SyntaxClass`, `DiffLanguage`, `Segment.syntax_class`, `FileDiff.language` with doc comments (and the `HunkLine` comment's "adjacent runs differ in kind or class"); then `cargo make codegen`, commit the regenerated files.
- `crates/zanshin-ffi/src/diff.rs` -- write both fields; module, builder and `zanshin_diff` docs; unit tests: wire segments equal `merge_highlight(line_segments, highlight_line)` with literal values for a paired `.rs` line, wire `language` per file, every `SyntaxClass` / `Language` wire mapping.
- `crates/zanshin-ffi/tests/it/diff_ffi.rs` -- `computed()` adds `lib.rs`; `assert_wire_is` checks `language` and the classed segments; literal real-repo witness.
- `packages/zanshin_core/lib/src/ffi/diff.dart`, `lib/zanshin_core.dart`, `lib/src/worker/handle.dart` -- `SyntaxClass`, `DiffLanguage`, the two fields, decoders, exports, docs.
- `packages/zanshin_core/test/ffi/diff_test.dart`, `test/worker/diff_test.dart` -- synthetic decode (present and absent class / language); the real-repo row through `RepoHandle.diff`.
- `docs/ffi-abi.md` -- the language and syntax-class contract and the new Dart exports.
- Ledgers: epics.md notes under Stories 5.3 and 5.4, sprint-status (5-3 and 5-4 done, epic-5 done, the backlog comment), deferred-work.md (a 5.3 line under "Word-level and syntax marks have no consumer story"), epic-5-context.md.

**Acceptance Criteria:**
- Given any `zanshin_diff` call that returns hunks, when Dart decodes it, then every `FileDiff.language` is `detect_language(path)`'s, every line's segment texts concatenate to its text, and its segments with classes equal `merge_highlight(line_segments(hunk)[i], highlight_line(text, language))`.
- Given a file in a bundled language, when its diff crosses the FFI, then its code lines carry classed segments split at token boundaries, and dropping the classes and joining adjacent same-kind runs gives 5.2's `line_segments` unchanged.
- Given a plain-text file, the description block or summary mode, when the diff crosses, then the wire carries 5.2's segments and none carries a class.
- Given this change, when `zanshin-jj`'s and `zanshin-diff`'s 5.2 suites run, then they pass unchanged.

## Spec Change Log

## Review Triage Log

### 2026-11-11 — Review pass
- verdicts: 30 findings — high 0, medium 7, low 15, false 8, maybe-false 0
- findings:
  - `[false]` `reject` (intent) The run delivers 5.4, the wire and Dart, and marks 5-4 and epic-5 done, though the intent names only 5.3. — The auditor itself lists this reading (R3) as defensible: 5.3's own tests need 5.4's Dart and Markdown grammars and its detection, sprint-status pairs the two ("gehört mit 5.4 zusammen"), epic-5-context says they need each other, and 5.5's delivered note hands `language` and `syntax_class` on the wire to 5.2–5.4. With 5.3 and 5.4 done, every Epic 5 story is done (5.7 deleted). The Design Notes and the Auto Run Result say so for the story loop.
  - `[false]` `reject` (intent) The literal ACs are not met: the 11-variant `Language`, JSON and Python tests, `Vec` and by-reference parameters, `schemas/diff.v1.schema.json`, nine dependencies, `tree_sitter_language()`, `OnceCell`. — Superseded: 5.4's WIP-rework shrinks the set to three grammars, epic-5-context says the nine-language lists predate the shrink, ADR-0001 replaces the JSON schema, and the rest are reconciled in the epics.md notes under 5.3 and 5.4 (clippy pedantic, no FFI-reachable panic).
  - `[false]` `reject` (intent) Lines over 131,072 characters get no classes, though the AC asks long lines to complete. — The AC asks that highlighting "completes": a ~100k-character line is classified (`a_100k_character_line_is_classified_in_every_language`), and the cap only bounds the cost above that; the intent-contract states the cap.
  - `[low]` `patch` (intent) The documented one-line limits (`fn main() {`, Dart's `if (x is int)`) are asserted by no test, and the FFI unit test's literal `fn main() {\n` check was removed. — Same root cause as the blind "wrong classes" row: new test `a_line_out_of_context_can_get_missing_or_wrong_classes` pins every example the module doc names (`fn main() {`, Dart `widget.onTap();`, a four-space-indented Markdown line, a heading that begins with markup); the docs now use those examples.
  - `[false]` `reject` (intent) 5.4's file-name registry is dropped and epic-5-context's requirement is rewritten. — After the shrink, every name the registry listed resolves to plain text by the extension rule, and `every_other_path_is_plain_text` pins all five; the epics.md 5.4 note records the reconciliation, and epic-5-context is recompiled to the delivered state as in 5.2.
  - `[false]` `reject` (intent) No consumer renders the classes. — No 5.3 or 5.4 AC asks for UI, CLAUDE.md allows UI code only inside a story that asks for it, and deferred-work.md tracks it ("Word-level and syntax marks have no consumer story", annotated by this run).
  - `[low]` `patch` (intent) Every non-summary call now highlights every line, no request field turns it off, the payload grows, and the open 5.2 cost decision is not told. — Same root cause as the edge-case and blind payload rows: the "Surfaced in the follow-up review of Story 5.2" cost bullet gains a dated sub-bullet with highlighting's per-line cost (release: Dart 8 µs, Rust 14 µs, Markdown 22 µs), its caps and its segment growth, so Ralph's options (a) and (b) weigh both; bounding the call stays that decision. A 5k-line file stays inside the soft target (about 70 ms of highlighting in release).
  - `[low]` `reject` (intent) Two language tables disagree: zanshin-jj's hunk-symbol table is case-sensitive and knows `mdown`, `detect_language` is case-insensitive without it. — Real but rare: only `.mdown` files and upper-case extensions differ. The symbol table is a verbatim CLI port (parity), the detection follows 5.4's AC, and the intent-contract fixes `md` / `markdown` with everything else plain text, so adding `mdown` changes the contract for an uncommon extension.
  - `[medium]` `patch` (intent) The class expectations are probe-derived, the wire and Dart tests recompute them with the production functions, and Constant, Property, Attribute, Emphasis and Code have no literal check. — Same root cause as the verification-gap class-mapping row (patched below). The recomputing wire tests are carriage tests by design (as in 5.2), with literal witnesses at the Rust wire (`lib.rs`) and in Dart (real cdylib).
  - `[low]` `patch` (intent) The capture-mapping test checks a test-side copy of tree-sitter-highlight's `configure` rule. — Same root cause: the new exact-token rows check the mapping through the real highlighter; the copy stays as the name-coverage guard.
  - `[false]` `reject` (intent) Deferred mirroring: no "Surfaced in Story 5.3" section, and the project-context drift note sits under a 5.2 bullet. — The run rule mirrors items added to the spec's `deferred:` list; this run defers none. The drift note extends the open 5.2 bullet with the same follow-up (Ralph edits project-context.md), which the loop already tracks.
  - `[low]` `reject` (intent) The spec's Verification section records no outcomes. — Its fix is an edit of this spec: finalize records every check and its outcome under Verification.
  - `[medium]` `patch` (verification-gap) The macro-injection test passes without Rust's injection. — Verified with a probe (no injection: same two tokens). Patched: `a_rust_macro_body_is_highlighted_through_the_injection` also asserts `foo` is Function in `println!("{}", foo(x));`, a class only the injected layer gives; the matrix row's own assertions stay.
  - `[medium]` `patch` (verification-gap) Nine `CAPTURES` entries and five classes are never asserted through the highlighter. — Patched: `every_capture_class_is_reached_by_a_bundled_grammar` pins three exact lines (Rust attribute, constructor, lifetime, number literal, property, boolean; Dart annotation, escape, `is`, `null`, `true`; Markdown emphasis, code span, backslash escape), reaching all 23 entries and all 18 classes.
  - `[low]` `patch` (verification-gap, other) `SyntaxClass::Constant`'s doc promises upper-case names. — Same root cause as the blind docs row: Rust's upper-case names are `@constructor` (its all-caps rule never matches) and Dart's are variables; the Rust and Dart docs of Keyword, Type, Variable and Constant now say what the grammars give.
  - `[medium]` `patch` (edge-case) Nested Rust macros cost the cube of their depth (8 KB line: 83 s, 2.7 GB). — Verified with a probe: 500 nested macros (2,002 characters) 1.39 s in release, 16 ms with a budget. Patched: `classify` passes an injection callback that injects at most 16 layers per line (`MAX_INJECTIONS`); `a_line_gets_at_most_16_injected_layers` pins 16 vs 17 levels and runs 500 levels, and fails with the budget raised.
  - `[low]` `reject` (edge-case) A Markdown heading that begins with inline markup (`` # `code` title ``, `### **Bold**`) gets wrong classes: at one offset tree-sitter-highlight opens the injected layer's highlights before the heading's. — Verified with a probe. Nothing renders classes yet, and every fix is more than a direct correction: a rewritten block query that also changes the intent-contract's pinned `# Title\n` row (space and newline become Heading), or a heading-specific stack rule in `classify`. Documented in the module doc, ffi-abi.md and the renderer notes in deferred-work.md, and pinned by `a_line_out_of_context_can_get_missing_or_wrong_classes`.
  - `[low]` `reject` (edge-case) A rename or copy that changes the extension highlights the removed lines in the new language. — Real but rare (an extension-changing rename with edits), and the fix adds a second language per file against the intent-contract's one-language rule; documented in ffi-abi.md.
  - `[low]` `patch` (edge-case) A large code file's payload grows several times (about two segments per token, each with its own string); the 2 GiB limit or the Dart heap comes sooner. — Verified from `line_offset`'s layout: a table, a vector slot and a string per segment make a highlighted code line roughly ten times a plain one's bytes; reaching 2 GiB still needs millions of highlighted lines in one call. Same root cause and patch as the intent cost row (the 5.2 cost decision now carries it).
  - `[medium]` `patch` (blind) Nested Rust macros make one short line cost seconds and hundreds of MB. — Same entry as the edge-case nested-macro row (the 16-layer budget).
  - `[medium]` `patch` (blind) The Rust injection test passes without the injection. — Same entry as the verification-gap macro row.
  - `[low]` `patch` (blind) `SyntaxClass` docs promise classes the grammars do not give (`this`, upper-case names, lifetimes). — Verified with a probe (Dart `this` is Keyword, upper-case names are Type in Rust and Variable in Dart, a lifetime's `'` is Operator and its name Type). Patched with the verification-gap docs row.
  - `[low]` `reject` (blind) Rust's number literals are Constant and its constants Type, unlike Dart's; two appended query patterns would align them. — Real and cosmetic; the intent-contract keeps the crates' highlight queries as shipped (only Markdown's injection is Zanshin's), and the docs name both captures; nothing renders classes yet.
  - `[medium]` `patch` (blind) 5 of the 18 classes appear in no test; the mapping claims are checked only against a copy of the rule. — Same entry as the verification-gap class-mapping row.
  - `[low]` `patch` (blind) The docs describe the one-line limit as missing classes, but common lines get wrong ones (Dart method-body statements, indented Markdown, lines in comments or fenced code). — Verified with a probe. Patched: the module doc, ffi-abi.md, the Dart `HunkLine.segments` doc, epic-5-context and the renderer notes in deferred-work.md list the cases (with the whole-hunk-side alternative as Ralph's option); the new characterization test pins them.
  - `[low]` `patch` (blind) `libzanshin_ffi.dylib` now exports 12 tree-sitter-highlight C functions, undocumented. — Verified with `nm -gU` on the release dylib (`_ts_highlighter_*`, `_ts_highlight_buffer_*`; before, only `_zanshin_*`). Patched: ffi-abi.md says they are tree-sitter-highlight's always-compiled `c_lib`, outside Zanshin's ABI and uncalled; hiding them needs linker flags, more than this finding's harm.
  - `[false]` `reject` (blind) FR-DF-5's remaining grammars are tracked nowhere. — prd.md:395 ("remaining OD-9 grammars deferred"), the epics.md 5.4 rework note ("added on demand later") and epic-5-context ("More languages come later") record them.
  - `[low]` `reject` (blind) The two language tables disagree (`mdown`, case). — Same entry as the intent row on the two tables.
  - `[false]` `reject` (blind) The description block is plain text only because of its pseudo-path. — `detect_language("JJ-COMMIT-DESCRIPTION")` is `PlainText`, and two tests pin that name (`every_file_carries_its_language`, `every_other_path_is_plain_text`), so a registry entry that changed it would fail them first.
  - `[low]` `patch` (blind) The payload and decode cost of the split segments is not measured, and `create_shared_string` is not considered. — Same entry as the intent cost row; deduplicating strings would trim the text bytes but not the per-segment tables, so it is left to the cost decision.

## Design Notes

**Why 5.3 and 5.4 in one run.** 5.3's ACs test Dart and Markdown lines and name 5.4's detection; 5.4's queries only matter to 5.3; the outermost surface (`FileDiff.language`, classed segments) needs both. Ralph's sprint-status note pairs them, and epic-5-context.md says they need each other.

**Capture table** (recognized name → class, in `configure` order): `keyword`→Keyword (before `operator`, so Dart's `keyword.operator` is a keyword); `string.escape`, `escape`→Escape; `string`→String; `comment`→Comment; `function`→Function; `type`, `constructor`, `label`→Type (Rust's lifetimes are type-level parameters; constructors are the uppercase-identifier heuristic); `variable`→Variable; `property`→Property; `number`→Number; `constant`, `boolean`→Constant (Rust captures its number literals as `constant.builtin`); `operator`→Operator; `punctuation`→Punctuation; `attribute`→Attribute; `text.title`→Heading; `text.emphasis`→Emphasis; `text.strong`→Strong; `text.uri`, `text.reference`→Link; `text.literal`→Code.

**One line at a time** is the epic's rule: the diff is per line, so a construct spanning lines is classified from its line alone (`fn main() {` leaves `main` unclassified; out of context Dart's `if (x is int)` mislabels `x`). The module doc states it.

**Markdown's injection.** The shipped block query injects `markdown_inline` without `include-children`, so the inline layer misses the delimiters (`*`, `` ` ``, `[`) that are children of the `inline` node and never sees emphasis, code or links. Its other injections (fenced code, HTML, front matter) never apply to one line. Probe: with the own pattern, 1M characters highlight in 0.8 s instead of 3.7 s.

**No file-name registry.** After the shrink, every name in 5.4's registry (`Cargo.toml`, `Cargo.lock`, `pubspec.yaml`, `pubspec.lock`, `Dockerfile`) resolves to plain text by the extension rule already; the registry arrives with the first grammar that needs one.

**AC reconciliations** (epics.md notes): `highlight_line` takes `Language` by value and `merge_highlight` slices (clippy `trivially_copy_pass_by_ref` / `needless_pass_by_value`); `schemas/diff.v1.schema.json` → `schemas/envelope.fbs` (ADR-0001); the nine-language enum and its tests (TypeScript, JSON, Python whitespace) → the three grammars; `Language::tree_sitter_language` (panics on `PlainText`) → a private `Option`-returning lookup (no FFI-reachable panic); 5.7's perf test is deleted, so long lines witness completion; `file.test.ts` → `file.test.rs`; the OnceCell is std's `LazyLock`.

**Wire cost.** A highlighted line splits into roughly two segments per token, each with its own text, so a code file's payload grows; plain-text lines keep 5.2's size.

## Verification

**Commands:**
- `cargo test -p zanshin-diff` -- expected: pass (5.2's suite unchanged)
- `cargo test -p zanshin-ffi --lib diff` and `cargo test -p zanshin-ffi --test it -- diff_ffi:: ffi_abi_doc_sync::` -- expected: pass
- `cargo test -p zanshin-jj --test it -- hunks:: diff::` -- expected: pass (no `zanshin-jj` change)
- `cargo clippy -p zanshin-diff -p zanshin-ffi --all-targets -- -D warnings` and `cargo fmt --all --check` -- expected: clean
- `cargo make codegen` -- expected: only the new enums, fields and doc comments change; a re-run changes nothing
- `cargo deny --workspace check advisories bans` -- expected: no error
- `cargo make --allow-private test-core`; in `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --output=none --set-exit-if-changed .`; `dart analyze app` -- expected: pass / clean

**Manual checks:**
- A release build of `libzanshin_ffi.dylib` (`cargo build --release -p zanshin-ffi`) still loads through `DynamicLibrary.open` and answers `zanshin_ffi_version` (deny.toml records a release-only load failure once caused by new native code).

**Results (story run, 2026-11-11; the full gate is left to the story loop's end):**
- `cargo test -p zanshin-diff` -- 41 passed: `grammars.rs` unit tests 3, `tests/grammars.rs` 3, `tests/highlight.rs` 16, Story 5.2's `tests/word_diff.rs` 19 (unchanged).
- `cargo test -p zanshin-ffi --lib diff` -- 13 passed; `--test it -- diff_ffi:: ffi_abi_doc_sync::` -- 24 passed.
- `cargo test -p zanshin-jj --test it -- hunks:: diff::` -- 59 passed (no `zanshin-jj` file changed).
- `cargo clippy -p zanshin-diff -p zanshin-ffi --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean.
- `cargo make codegen` -- only the new enums, fields and doc comments changed; a re-run changed nothing (`shasum` of the two FlatBuffers accessor files, `zanshin_ffi.h` and `bindings.dart` identical before and after).
- `cargo deny --workspace check advisories bans` -- advisories ok, bans ok; the duplicate-crate warnings are pre-existing (the lock gains only six tree-sitter crates — the five pinned ones plus `tree-sitter-language` — and `streaming-iterator`).
- `cargo make --allow-private test-core` -- 1188 passed (the three new tests among them); in `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` -- no issues, `dart format --output=none --set-exit-if-changed` -- 0 changed; `dart analyze app` -- no issues.
- Manual check: the release `libzanshin_ffi.dylib` (34 MB) loads through `DynamicLibrary.open` and answers `0.1.0 (d8502832f4fe)`; `nm` shows the three grammars inside, and 12 exported `ts_highlight*` functions beside the 115 `zanshin_*` ones.
- Matrix test audit: every row is covered by a test that ran and passed (`tests/highlight.rs` rows 1–12, `tests/grammars.rs` detection, `diff_ffi.rs::the_wire_carries_the_diff_keys_flags_lines_and_pins` and the Dart worker test `a_rust_file_carries_its_language_and_its_lines_their_syntax_classes` for the real-repo row).

**Results after the review patches (2026-11-11; supersede the counts above):**
- `cargo test -p zanshin-diff` -- 44 passed (`tests/highlight.rs` 19: adds `a_line_gets_at_most_16_injected_layers`, `every_capture_class_is_reached_by_a_bundled_grammar`, `a_line_out_of_context_can_get_missing_or_wrong_classes`).
- Mutation check: with `MAX_INJECTIONS` raised to 1000, `a_line_gets_at_most_16_injected_layers` fails ("the 17th layer is not injected"); restored to 16, it passes.
- `cargo test -p zanshin-ffi --lib diff` -- 13 passed; `--test it -- diff_ffi:: ffi_abi_doc_sync::` -- 24 passed (ffi-abi.md changed).
- `cargo clippy -p zanshin-diff -p zanshin-ffi --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean after reformatting one new assertion.
- `cargo make --allow-private test-core` -- 1188 passed; `dart analyze` / `dart format` in `packages/zanshin_core` -- clean; `dart analyze app` -- no issues.
- Not re-run after the patches, because nothing they touch reaches them: `cargo test -p zanshin-jj` (it does not depend on `zanshin-diff`), `cargo make codegen` (no schema or extern change), `cargo deny` (no manifest change), the release dylib load (only `classify`'s injection callback changed).
- Not run, by the run's gate rule: `cargo make test` / `test-full` / `coverage` (the story loop's end gate measures the two new files' coverage), and the parity oracle (no jj verb changed).

## Auto Run Result

Status: done. Code commit `0dcbe1ab324a74dd3b2c4abf52930d9a6682bd9c`.

**Story 5.4 is delivered here too.** Story 5.3's highlighter needs Story 5.4's grammars, queries and detection, and its own tests need real Dart and Markdown grammars, so this run built both (sprint-status: 5-3 and 5-4 done, and epic-5 done, since every Epic 5 story is now done or deleted). A later dispatch of Story 5.4 has nothing left to build.

**Summary.** Every segment of a diff line is split at its syntax tokens and carries their class, and every file carries its language, from Rust through the FFI into Dart.
- `zanshin_diff::detect_language(&Path)` reads the final extension, ASCII case-insensitive: `rs` Rust, `dart` Dart, `md` / `markdown` Markdown, every other path plain text. No file-name registry is needed: every name 5.4 listed is plain text by that rule.
- `zanshin_diff::highlight_line(line, language)` runs tree-sitter-highlight over one line, best effort, and returns contiguous byte-range tokens with an optional `SyntaxClass`. The classes are a fixed set of 18: Keyword, String, Escape, Comment, Function, Type, Variable, Property, Number, Constant, Operator, Punctuation, Attribute, Heading, Emphasis, Strong, Link and Code.
- `merge_highlight(segments, tokens)` splits Story 5.2's segments at the token boundaries.
- Plain text, a line over 131,072 characters (5.2's cap, now shared) and a highlighter error give no classes; a line gets at most 16 injected layers.
- Queries are the grammar crates' own, except Markdown's block injection: Zanshin's own pattern with `include-children`, so emphasis, code spans and links are seen.
- Wire: `FileDiff.language` (`DiffLanguage`) and `Segment.syntax_class` (`SyntaxClass`, `Unclassified` = none). Dart: `FileDiff.language`, `Segment.syntaxClass`, both enums exported. `zanshin_jj` is unchanged.

**Files changed.**
- `Cargo.toml`, `Cargo.lock`: `tree-sitter`, `tree-sitter-highlight` (both `=0.27.1`; 0.27.2 is younger than `.cargo/config.toml`'s 7-day `global-min-publish-age`), `tree-sitter-rust =0.24.2`, `tree-sitter-dart =0.3.0`, `tree-sitter-md =0.5.4`, all MIT, with `# WHY:`.
- `crates/zanshin-diff/src/grammars.rs` (new): `Language`, `detect_language`, the four configurations (`LazyLock`), the injection lookup, Markdown's block injection; unit tests for the configurations and the capture coverage.
- `crates/zanshin-diff/src/highlight.rs` (new): `SyntaxClass`, `HighlightedToken`, `HighlightedSegment`, `CAPTURES`, `highlight_line` (per-thread `Highlighter`, 16-layer injection budget), `merge_highlight` (never panics).
- `crates/zanshin-diff/src/word_diff.rs`: the cap renamed to the shared `MAX_LINE_CHARS`, no behaviour change; `src/lib.rs`, `Cargo.toml`: modules, re-exports, dependencies.
- `crates/zanshin-diff/tests/grammars.rs`, `tests/highlight.rs` (new): every non-FFI matrix row, the token and merge invariants over every row in every language, the injection paths and budget, every capture class, the documented wrong classes, the cap boundary, garbage tokens.
- `schemas/envelope.fbs`: `SyntaxClass`, `DiffLanguage`, `Segment.syntax_class`, `FileDiff.language`; `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`, `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart`: `cargo make codegen` output.
- `crates/zanshin-ffi/src/diff.rs`: writes both fields; unit tests for the classed segments, the language per file and every wire mapping. `tests/it/diff_ffi.rs`: a real `lib.rs` change, language and classed segments of every file.
- `packages/zanshin_core/lib/src/ffi/diff.dart`, `lib/zanshin_core.dart`, `lib/src/worker/handle.dart`: models, decoders, exports, docs. `test/ffi/diff_test.dart`, `test/worker/diff_test.dart`: synthetic decode of every wire value; the real-repo `lib.rs` row.
- `docs/ffi-abi.md`: the language and syntax-class contract, the out-of-context cases, the 16-layer budget, the tree-sitter-highlight exports.
- Ledgers: `epics.md` (notes under Stories 5.3 and 5.4), `sprint-status.yaml` (5-3, 5-4 and epic-5 done; backlog comment trimmed), `deferred-work.md` (a 5.3/5.4 line with the renderer notes under "Word-level and syntax marks have no consumer story"; highlighting's cost on the open 5.2 cost decision; the tree-sitter pins on the open project-context.md item), `epic-5-context.md` (the delivered state).

**Review.** 30 findings: 0 high, 7 medium, 15 low, 8 false. Patched entries: 7.
- 3 medium:
  - a 16-layer injection budget per line (nested Rust macros cost the cube of their depth: a 2,000-character line took 1.4 s);
  - an injection-only witness in the macro test;
  - exact-token tests that reach every capture entry and every class.
- 4 low:
  - the `SyntaxClass` docs (Rust and Dart) now say what the grammars give;
  - the out-of-context limit documented with its wrong-class cases, plus a characterization test;
  - highlighting's per-call cost added to the open 5.2 cost decision;
  - an ffi-abi.md note on the 12 exported tree-sitter-highlight functions.

Deferred: none.

Rejected, with reasons in the Review Triage Log:
- A Markdown heading that begins with inline markup gets wrong classes. tree-sitter-highlight opens the injected layer's highlights first at a shared offset. Every fix rewrites a query or the stack rule and changes the pinned `# Title\n` row, and nothing renders classes yet. It is documented and pinned.
- A rename that changes the extension highlights its removed lines in the new language. This is rare, and the fix adds a second language per file.
- Rust's numbers are `Constant` and its constants `Type`. The crates' queries are kept as shipped, and the docs say so.
- `.mdown` and case differ from zanshin-jj's hunk-symbol table. The CLI port keeps its table, and the intent-contract fixes `md` / `markdown`.
- The Verification outcomes were missing. They are recorded above.
- The rest are false:
  - scope beyond 5.3, which is a defensible reading, justified above;
  - the superseded nine-language ACs;
  - the cap versus "completes";
  - the dropped registry;
  - no renderer;
  - the deferral mirroring;
  - FR-DF-5's other grammars, which prd.md:395 and epics.md record;
  - the description block's pseudo-path, which two tests pin.

**Follow-up review recommended: true.** This first pass patched 3 medium entries (0 high, 4 low). The unverified risks:
- **The injection budget.** Its value of 16 rests on probe timings and one test.
- **Grammar-pinned tests.** The exact-token and characterization tests pin grammar output that the next tree-sitter pin bump can shift.
- **The review patches went in by hand.** The implementation agent could only be resumed asynchronously, which this unattended run cannot wait for.
- **Coverage.** The per-file coverage of the two new files is measured only by the story loop's end gate.

**Verification.** See "Results after the review patches" above; every targeted command passed.

**Residual risks and open questions for Ralph.**
- Lines are highlighted one at a time and out of context, so classes can be missing or wrong. Dart statements from method bodies are the common case. The renderer story decides whether that is good enough. The option is to highlight each hunk side as one text, which changes Epic 5's one-line rule.
- Highlighting runs on every line of every call, and a highlighted line costs about ten times a plain one's bytes. This adds to the open 5.2 cost decision ("Surfaced in the follow-up review of Story 5.2"), which now records it.
- cargo ignores `global-min-publish-age` without `-Zmin-publish-age`. Only the exact pins keep tree-sitter at 0.27.1.
- The cdylib exports tree-sitter-highlight's 12 C functions. Hiding them needs linker flags.
- project-context.md's stack list does not show the tree-sitter pins (annotated on the open 5.2 item).
- No UI renders word or syntax marks yet ("Word-level and syntax marks have no consumer story").
