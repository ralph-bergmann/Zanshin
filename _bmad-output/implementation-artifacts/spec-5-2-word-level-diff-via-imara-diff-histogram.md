---
title: 'Story 5.2 — Word-level diff via imara-diff Histogram (segments on every diff line)'
type: 'feature'
created: '2026-11-11'
status: 'done'
baseline_revision: '8cd7d12c1daecef4a6d699ca76adb5cffa1a2b03'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      Zanshin's word-level segments differ from the words `jj diff --git` marks.
    evidence: |-
      jj word-diffs each changed region as one text, with no line pairing (jj-lib 0.47.0 src/diff_presentation/unified.rs:230; crates/zanshin-jj/src/hunks.rs:709 hunk_line drops its DiffTokenType): on `fn foo(x: i32) -> i32` → `fn foo(y: i32) -> u32` it marks `x`, both `i32` and `y`, `i32`, `u32`; Zanshin's imara-diff line pairs mark `x`, the second `i32` and `y`, `u32`. A product decision for Ralph; Claude's proposal: leave it — FR-DF-1 names imara-diff, and jj's underlines are terminal presentation that Zanshin replaces. Mirrored into deferred-work.md "Surfaced in Story 5.2".
    location: >-
      crates/zanshin-diff/src/word_diff.rs compute_word_diff; crates/zanshin-jj/src/hunks.rs:709 hunk_line
    severity: low
  - summary: >-
      project-context.md's stack list still names imara-diff `=*` and does not list unicode-segmentation.
    evidence: |-
      _bmad-output/project-context.md:43 says "`imara-diff` `=*` (pin exact — Histogram algorithm)", while the root Cargo.toml now pins `imara-diff = "=0.2.0"` and adds `unicode-segmentation = "=1.13.3"`; the new `zanshin-diff` → `zanshin-jj` dependency is not recorded either. project-context.md is an agent-context file, so the run does not edit it (review finding, routed defer). Mirrored into deferred-work.md "Surfaced in Story 5.2".
    location: >-
      _bmad-output/project-context.md:43
    severity: low
---

<intent-contract>

## Intent

**Problem:** A diff line reaches Dart only as whole-line text. Nothing marks which words of a changed line changed, so the UI cannot render a Delta-class diff (FR-DF-1 enrichment).

**Approach:** Add `compute_word_diff` to `crates/zanshin-diff` (imara-diff Histogram over Unicode word-bound tokens) plus `line_segments`, which pairs a hunk's removed and added lines and gives every line its segments. `zanshin_ffi::diff::diff_to_envelope` writes them as `HunkLine.segments` on the wire, and Dart decodes them into `HunkLine.segments`.

## Boundaries & Constraints

**Always:**
- Word diff = `imara_diff::Diff::compute(Algorithm::Histogram, …)` + `postprocess_no_heuristic`, over the tokens of `unicode_segmentation::UnicodeSegmentation::split_word_bounds` (UAX #29: a run of horizontal whitespace is one token, `\n` is one token, an emoji or a base with its combining marks is one token).
- A line's segments concatenate exactly to its text (the `\n` included). No empty segment. Adjacent tokens of one kind form one segment.
- Pairing (the default Delta-class behaviour): a run of removed lines directly followed by a run of added lines; the i-th removed line is word-diffed with the i-th added line. A line without a partner is one segment of its own kind (`Removed` / `Added`); a context line is one `Equal` segment. `compute_word_diff` runs only on pairs.
- `zanshin-diff` depends on `zanshin-jj` (for `HunkLine` only) and never on jj-lib; `zanshin-ffi` depends on `zanshin-diff`. The line-level data (`zanshin_jj::Hunk` / `HunkLine`, fingerprints, sections) stays unchanged.
- The wire: `HunkLine.segments: [Segment]` appended, always written; `table Segment { kind: SegmentKind; text: string; }`, `enum SegmentKind : ubyte { Equal, Added, Removed }` (append-only).
- Dart: `HunkLine.segments` is an optional named parameter (default `const []`), so the app's `HunkLine(kind:, text:)` calls keep compiling.
- New dependencies exact-pinned with a `# WHY:` in `[workspace.dependencies]`: `imara-diff = "=0.2.0"` (Apache-2.0), `unicode-segmentation = "=1.13.3"` (MIT/Apache-2.0, already a jj-cli transitive).

**Never:** No jj-lib word tokens (see Design Notes). No change to `zanshin-jj`. No syntax classes or file language (5.3/5.4). No UI rendering (no story asks; tracked in deferred-work "Word-level and syntax marks have no consumer story"). No edit-distance pairing heuristic, no caching, no perf gate (5.7 deleted), no new error code.

## I/O & Edge-Case Matrix

Notation: `=` Equal, `-` Removed, `+` Added segment, followed by its exact text.

| Scenario | Input (removed / added) | Expected segments | Error Handling |
|----------|------------------------|-------------------|----------------|
| AC example | `fn foo(x: i32) -> i32` / `fn foo(y: i32) -> u32` | `[=fn foo(, -x, =: i32) -> , -i32]` / `[=fn foo(, +y, =: i32) -> , +u32]` | — |
| No shared token | `alpha` / `omega` | `[-alpha]` / `[+omega]` | — |
| Shared space only | `foo bar` / `baz qux` | `[-foo, = , -bar]` / `[+baz, = , +qux]` | — |
| Several changes | `let a = b + c;` / `let x = b * c;` | `[=let , -a, = = b , -+, = c;]` / `[=let , +x, = = b , +*, = c;]` | — |
| Unicode | `café ☕ naïve 🎉` / `cafe ☕ naive 🎉` | `[-café, = ☕ , -naïve, = 🎉]` / `[+cafe, = ☕ , +naive, = 🎉]` | — |
| Whitespace | `a b` / `a  b`; `x` / `x ` | `[=a, - , =b]` / `[=a, +  , =b]`; `[=x]` / `[=x, + ]` | — |
| NUL byte | `a\0b` / `a\0c` | `[=a\0, -b]` / `[=a\0, +c]` | no panic |
| Long line | 100k-char lines, one token changed | one `-` and one `+` segment, rest `=` | completes |
| Pairing 5/3 | 5 removed lines, then 3 added | removed 1–3 ↔ added 1–3 word-diffed; removed 4–5 `[-whole line]` | — |
| Other lines | context `b\n`; lone added `n\n` | `[=b\n]`; `[+n\n]` | — |
| Real repo (FFI + Dart) | `f.txt` `a`→`A`, `w.txt` `x y`→`x  y` | `a\n`: `[-a, =\n]`; `b\n`: `[=b\n]`; `x y\n`: `[=x, - , =y\n]` | — |

</intent-contract>

## Code Map

- `crates/zanshin-diff/src/lib.rs:1-3`, `Cargo.toml:12` -- placeholder crate; gets `mod word_diff`, re-exports and its first dependencies.
- `Cargo.toml:27-65` -- `[workspace.dependencies]`; every entry carries a `# WHY:`. Add `imara-diff`, `unicode-segmentation`, `zanshin-diff = { path = "crates/zanshin-diff", version = "0.1.0" }` (deny.toml forbids wildcards).
- `crates/zanshin-jj/src/hunks.rs:240-251` -- `HunkLine` (`Context`/`Removed`/`Added`, text with `\n`); read-only input. `:675-717` -- jj-lib emits each changed region as all its removed lines, then all its added lines: the runs the pairing walks.
- imara-diff 0.2.0 (`$CARGO_HOME/registry/src/index.crates.io-1949cf8c6b5b557f/imara-diff-0.2.0/src/lib.rs`, `intern.rs`) -- `InternedInput::default()` + `update_before` / `update_after(iter of &str)`, `Diff::compute`, `postprocess_no_heuristic`, `is_removed(i)` / `is_added(i)`.
- `crates/zanshin-ffi/src/diff.rs:197-226` -- `hunk_offset` / `line_offset`: write the segments. `:249-486` -- unit tests (`diff_from_wire`, `sample()`).
- `crates/zanshin-ffi/tests/it/diff_ffi.rs:91-170` -- `kind_and_text`, `assert_wire_is` (real repo, per-line wire check).
- `crates/zanshin-ffi/Cargo.toml:31` -- add the `zanshin-diff` dependency.
- `schemas/envelope.fbs:3171-3180` -- `HunkLineKind` / `HunkLine`; add `SegmentKind` / `Segment` before them and append `segments`.
- `packages/zanshin_core/lib/src/ffi/diff.dart:45-68,304-322` -- `HunkLineKind` / `HunkLine` models, `_hunk` decoder; `lib/zanshin_core.dart:34` -- exports.
- `packages/zanshin_core/test/ffi/diff_test.dart:18-128` (synthetic decode), `test/worker/diff_test.dart:45-90` (real cdylib; `f.txt` / `w.txt` fixture).
- `crates/xtask/src/tasks/gate_plan.rs:207-217,932-938` -- `crates/zanshin-diff/` is "Rust outside the cdylib"; it now links into it.
- `docs/ffi-abi.md:2464-2512` -- the `Diff` payload section.
- `_bmad-output/planning-artifacts/epics.md:4685-4748` -- Story 5.2's ACs (reconciliation note goes under the heading).

## Tasks & Acceptance

**Execution:**
- `Cargo.toml`, `crates/zanshin-diff/Cargo.toml`, `crates/zanshin-ffi/Cargo.toml` -- the three dependencies (with `# WHY:`), zanshin-diff → `imara-diff`, `unicode-segmentation`, `zanshin-jj`; zanshin-ffi → `zanshin-diff`.
- `crates/zanshin-diff/src/word_diff.rs` (new) + `src/lib.rs` -- `Segment { text, kind }`, `SegmentKind { Equal, Added, Removed }`, `compute_word_diff(removed_line, added_line) -> (Vec<Segment>, Vec<Segment>)`, `line_segments(&[HunkLine]) -> Vec<Vec<Segment>>` (index-aligned with the lines), module doc naming the pairing rule.
- `crates/zanshin-diff/tests/word_diff.rs` (new) -- every non-FFI matrix row, plus: segments concatenate to the line, no empty segment, a removed run followed by context is not paired, a lone added run, an empty slice.
- `schemas/envelope.fbs` -- `SegmentKind`, `Segment`, `HunkLine.segments` with doc comments; then `cargo make codegen` (commit the regenerated Rust + Dart accessors).
- `crates/zanshin-ffi/src/diff.rs` -- write `line_segments` per hunk in `hunk_offset` / `line_offset`; module + builder docs; unit test: every wire line's segments equal `line_segments`, with explicit values for a paired, an unpaired and a context line.
- `crates/zanshin-ffi/tests/it/diff_ffi.rs` -- `assert_wire_is` compares each line's segments too; explicit real-repo witness (`a\n` → `[-a, =\n]`).
- `packages/zanshin_core/lib/src/ffi/diff.dart` + `lib/zanshin_core.dart` -- `SegmentKind`, `Segment`, `HunkLine.segments`, decoder; export both types.
- `packages/zanshin_core/test/ffi/diff_test.dart`, `test/worker/diff_test.dart` -- synthetic decode (present and absent vector) and the real-repo rows of the matrix through `RepoHandle.diff`.
- `crates/xtask/src/tasks/gate_plan.rs` -- move `crates/zanshin-diff/` to "Rust in the cdylib"; extend the cdylib test.
- `docs/ffi-abi.md` -- the segments contract and the Dart exports.
- Ledgers: `epics.md` Story 5.2 note, `sprint-status.yaml` (5-2 done), `deferred-work.md` (5.2 line under "Word-level and syntax marks have no consumer story"; a "Surfaced in Story 5.2" section mirroring the spec's `deferred:`).

**Acceptance Criteria:**
- Given any `zanshin_diff` call that returns hunks, when Dart decodes it, then every `HunkLine.segments` is non-empty and its texts concatenate to `HunkLine.text`, and they equal `zanshin_diff::line_segments` over `Repo::diff`'s lines for the same request.
- Given a summary-mode request, when `zanshin_diff` answers it, then its files carry no hunks, so no word diff runs.
- Given this change, when `zanshin-jj`'s suites run, then they pass unchanged: `Repo::diff` / `compute_hunks` results, fingerprints and sections are what they were.

## Spec Change Log

## Review Triage Log

### 2026-11-11 — Review pass
- verdicts: 29 findings — high 0, medium 4, low 18, false 7, maybe-false 0
- findings:
  - `[low]` `reject` (intent) The AC's literal values are pinned only on strings without `\n`; on real lines a shared `\n` or space stays `Equal`, so a "complete rewrite" is never all `Removed` / `Added` on the wire. — Same root cause as the blind "complete rewrite" row: reconciliation (2) reads "share no words" as "share no token". The effect is cosmetic (whitespace, punctuation or the line ending left unmarked between marked words of a rewritten line) and no UI renders segments yet; the other reading needs a new notion of "word" plus a branch, and would contradict the intent-contract's matrix row "Shared space only". Recorded in the epics.md note and the Auto Run Result for Ralph.
  - `[false]` `reject` (intent) Segments exist only on the wire and in Dart, and most wire assertions compare the wire with `line_segments` itself. — By design (Design Notes: enrichment at the wire). The values are pinned literally in `crates/zanshin-diff/tests/word_diff.rs` (17 tests, now including the Histogram/postprocess row) and at literal points in `diff.rs`, `diff_ffi.rs` and `worker/diff_test.dart`; the wire tests' job is carriage.
  - `[false]` `reject` (intent) The app does not render the segments. — No Story 5.2 AC asks for UI, CLAUDE.md allows UI code only inside a story that asks for it, and the rendering gap is tracked in deferred-work.md ("Word-level and syntax marks have no consumer story", annotated by this change).
  - `[low]` `patch` (intent) The jj comparison in the ledgers named only the removed line and not jj's region-level word diff. — Patched: the deferred-work bullet, the spec's `deferred:` evidence and the epics.md note give both lines (`x`, `i32`, `i32` / `y`, `i32`, `u32`), the structural difference and `crates/zanshin-jj/src/hunks.rs:709` / jj-lib `unified.rs:230`, framed as a product decision with Claude's proposal (leave it). The sub-claim that the deferral breaks project-context.md:729-731 is the blind row below (false); the recompiled epic context's "line level matches the jj CLI" matches the planning docs (FR-DF-1 names imara-diff for the word level).
  - `[false]` `reject` (intent) `zanshin-diff` has jj-lib in its dependency graph. — The binding rule is "only `zanshin-jj` imports `jj_lib`" (project-context.md § zanshin-jj); `zanshin-diff` imports no jj-lib item, only `zanshin_jj::HunkLine`.
  - `[low]` `patch` (intent) The deferred-work evidence bullet had no file:line and carried rationale. — Patched with the jj-comparison row: one evidence line citing `hunks.rs:709` and `unified.rs:230`; the rationale moved to the Follow-up line.
  - `[false]` `reject` (intent) sprint-status says 5-2 `done` while the spec is in review. — Both are committed together at finalize with `status: done`, as for 4.17 and 4.18 in this loop; no commit carries the mismatch.
  - `[false]` `reject` (intent) The recompiled epic-5-context.md drops the test-placement rule. — The rule lives in CLAUDE.md (§ Coverage ratchet, test placement), which every run loads; the compile keeps the context to epic-specific facts.
  - `[medium]` `patch` (verification-gap) No test pins `Algorithm::Histogram` or `postprocess_no_heuristic`. — Patched: `a_reordered_call_is_marked_whole` (`foo(a).bar(b).baz(c)` → `foo(a).baz(c).bar(b)`), checked to fail without the postprocess call and under `Algorithm::Myers`.
  - `[low]` `patch` (verification-gap, other) Tabs and no-break spaces are one-character tokens, but the docs said a run of horizontal whitespace is one token. — Patched with the blind and edge whitespace rows: the module doc and ffi-abi.md § Segments say a run of spaces (`WSegSpace`) is one token and each tab or no-break space its own; the same parenthetical stays in the spec's `<intent-contract>` (read-only).
  - `[low]` `patch` (verification-gap, other) The `ShowEntry` comment (`schemas/envelope.fbs:2651`) still said Epic 5 would extend that payload. — Patched: it points at the separate `Diff` payload and `HunkLine.segments`; `cargo make codegen` carried it into both accessor files.
  - `[medium]` `patch` (blind) A changed line pair is word-diffed however long it is (1 MB minified, 1 % edited: 2.4 s in release). — Patched with the edge row on the same cause: `line_segments` leaves a pair unpaired (each line one whole-line segment) when either line exceeds 128 KiB (`MAX_PAIRED_LINE_BYTES`, `shortcut:` comment); tests cover both directions and a ~100k pair that is still word-diffed; module doc, ffi-abi.md, the `HunkLine` schema comment, the Dart doc, the epics.md note and epic-5-context.md name the cap. This refines the intent-contract's pairing bullet for lines over 128 KiB; no matrix row changes (the long-line row is ~100k characters).
  - `[low]` `reject` (blind) The "complete rewrite" AC is redefined (shared spaces stay `Equal`) and the positional pairing is labelled Delta's. — The marks differ only in whitespace or punctuation tokens left unmarked between the changed words of a rewritten line: cosmetic, and nothing renders segments yet. The fix adds a "word" rule and a branch and would contradict the intent-contract's matrix row "Shared space only"; "the default Delta-class behaviour" is the AC's own label. Reconciliation (2) is recorded in epics.md for Ralph.
  - `[low]` `reject` (blind) UAX #29 keeps `self.foo`, `x:y` and `it's` as one token, so marks are coarse for code. — Out of scope by the intent: Story 5.2 says it "tokenizes by Unicode word boundaries (`unicode-segmentation` crate …)"; re-splitting at punctuation would replace the tokenizer the intent names.
  - `[low]` `patch` (blind) "A run of horizontal whitespace is one token" is false for tabs and no-break spaces. — Patched (same entry as the verification-gap whitespace row).
  - `[false]` `reject` (blind) The story throws jj's tokens away and defers a "like the CLI or not?" question, contrary to project-context.md:729-731. — project-context.md:249-252 lists coloured, templated stdout as terminal UX that Zanshin replaces, and :731 sends product and UI decisions to Ralph; Story 5.2 and FR-DF-1 name imara-diff, so reusing jj's tokens would contradict the intent. The deferred item is a product question with a proposal (leave it).
  - `[low]` `reject` (blind) `zanshin-diff` depends on `zanshin-jj` (and so on jj-lib) just to read `HunkLine`, and the cycle rule keeps `zanshin-jj` from calling it. — The dependency is the spec's contract (Always: "`zanshin-diff` depends on `zanshin-jj` (for `HunkLine` only)"); jj-lib is built for every workspace test run anyway, and no story needs `zanshin-jj` to call `zanshin-diff`. Changing the public `line_segments` signature is more than a direct correction.
  - `[medium]` `patch` (blind) Every line's text crosses the FFI twice, though nothing reads segments yet. — Patched with the edge row on the same cause: a line with exactly one segment gives it the line's own `text` string offset (`crates/zanshin-ffi/src/diff.rs` `line_offset`); the unit test asserts the shared address. Only paired lines still carry their segment texts.
  - `[false]` `reject` (blind) 5.2 is marked `done` before its review and gate, and `coverage-baseline.txt` has no line for `word_diff.rs`. — The ledgers are committed with the done spec at finalize; under this run's gate rule the loop's end gate runs coverage, and the ratchet adds the new file's line there.
  - `[low]` `patch` (blind) epic-5-context.md still describes 5.2 as open. — Patched: 5.2 is marked done; the Goal and "Enrichment home" record the decision (segments built in `hunk_offset` through `line_segments`, `zanshin-diff` → `zanshin-jj`, wire field `HunkLine.segments`, `hunk_offset` gets no file path).
  - `[low]` `patch` (blind) The segment shapes a renderer must handle are neither tested nor documented. — Patched: `a_changed_line_can_carry_no_changed_segment` (`"\n"` / `"foo\n"`) and `a_changed_segment_can_be_only_a_line_ending` (`"a\n"` / `"a"`, `"a\r\n"` / `"a\n"`); ffi-abi.md § Segments names both shapes.
  - `[low]` `reject` (blind) `unicode-segmentation` is exact-pinned though it is a stable crate. — It follows the workspace's practice for crates already in Cargo.lock as transitives (`regex`, `serde`, `shlex`, each with the same WHY) and the spec's contract; a resolution conflict at a jj pin bump fails loudly and is a one-line fix.
  - `[low]` `defer` (blind) project-context.md's stack list still says imara-diff `=*` and does not list unicode-segmentation. — Deferred: project-context.md is an agent-context file; added to `deferred:` and mirrored into deferred-work.md "Surfaced in Story 5.2".
  - `[medium]` `patch` (edge-case) Histogram cost explodes on long, heavily edited lines (0.2 s at 100k characters, 14 s at 0.9 MB in release). — Patched (same entry as the blind long-line row: the 128 KiB cap).
  - `[low]` `reject` (edge-case) Paired lines that differ only in invalid UTF-8 bytes decode to identical lossy text and get no marks. — The marks match the text the line carries (5.1 decodes lossily, and its review kept that); non-UTF-8 text files are rare, and the fix adds a branch.
  - `[low]` `patch` (edge-case) The duplicated text halves the 2 GiB FlatBuffers headroom (an `internal.panic` near 1 GB of hunk text). — Patched with the blind duplicate-text row: single-segment lines, which are every line of a huge added or removed file, no longer copy their text.
  - `[low]` `reject` (edge-case) An empty-text `HunkLine` passed to `line_segments` yields one empty segment. — jj never emits an empty hunk line (`split_inclusive` yields non-empty lines), so only a synthetic caller reaches it, and the fix adds a guard.
  - `[low]` `patch` (edge-case) Tab and no-break-space runs are not one token, so the docs mispredict. — Patched (same entry as the verification-gap whitespace row).
  - `[low]` `patch` (edge-case) The segment test's `zip` of wire files against `diff.files` truncates silently. — Patched: the two counts are asserted equal before the zip.

## Design Notes

**Why imara-diff and not jj's own tokens.** jj-lib's `unified_diff_hunks` (which `hunks.rs` already calls) word-diffs each changed region itself (`ContentDiff::by_word`, `DiffTokenType`); `jj diff --git` underlines those tokens. They differ from this story's: on the AC example jj marks both `i32` of the removed line, because its histogram only matches words that occur equally often on both sides. Story 5.2, FR-DF-1, the architecture and project-context all name imara-diff Histogram, and the CLI-parity rule binds behaviour, not the terminal presentation it replaces. So 5.2 follows the documents; the divergence goes to Ralph as a deferred item.

**Why `zanshin-diff` enriches at the wire.** The research's layering: jj-lib gives line-level hunks, `zanshin-diff` enriches them. Keeping segments out of `zanshin_jj::HunkLine` leaves the CLI data (and its 40-odd test sites) untouched, and 5.3 can add syntax classes the same way.

**Segments on every line.** The epic's output shape (5.5's line → segments mapping) gives every line segments, and 5.3 will attach a syntax class to each. A consumer tells "no word-level detail" by a single segment of the line's own kind.

**AC reconciliations.** (1) The AC example's trailing `Equal("")` is dropped: no empty segments; a line's `\n` is a token and rides on its last segment. (2) "Share no words" means no shared token: whitespace or punctuation both lines share stays `Equal` (matrix row "Shared space only"). (3) The AC's location `crates/zanshin-diff/src/word_diff.rs` and its tests `crates/zanshin-diff/tests/word_diff.rs` hold. (4) Story 5.7's perf test is deleted, so the long-line row witnesses completion only.

## Verification

**Commands:**
- `cargo test -p zanshin-diff` -- expected: pass
- `cargo test -p zanshin-ffi --lib diff` and `cargo test -p zanshin-ffi --test it diff_ffi::` -- expected: pass
- `cargo test -p xtask gate_plan` -- expected: pass
- `cargo clippy -p zanshin-diff -p zanshin-ffi -p xtask --all-targets -- -D warnings` -- expected: clean
- `cargo fmt --all --check` -- expected: clean
- `cargo make codegen` -- expected: only the schema's new types and field change the generated files
- `cargo deny --workspace check advisories bans` -- expected: no error for the new crates
- `cargo make --allow-private test-core`; in `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --output=none --set-exit-if-changed .` -- expected: pass/clean
- `dart analyze app` -- expected: no new issue (the exports reach the app)

**Results (story run, 2026-11-11; the full gate is left to the story loop's end):**
- `cargo test -p zanshin-diff` -- 13 passed (every non-FFI matrix row + the invariants).
- `cargo test -p zanshin-ffi --lib diff` -- 11 passed; `--test it diff_ffi::` -- 7 passed; `--test it ffi_abi_doc_sync::` -- 17 passed.
- `cargo test -p zanshin-jj --test it hunks::` -- 15 passed (AC 3 witness; no `zanshin-jj` file changed).
- `cargo test -p xtask gate_plan` -- 16 passed.
- `cargo clippy -p zanshin-diff -p zanshin-ffi -p xtask --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean.
- `cargo make codegen` -- only the two FlatBuffers accessor files changed (the new enum, table and field); `zanshin_ffi.h` and `bindings.dart` unchanged.
- `cargo deny --workspace check advisories bans` -- advisories ok, bans ok.
- `cargo make --allow-private test-core` -- 1185 passed (both new tests ran); `dart analyze` / `dart format` in `packages/zanshin_core` -- clean; `dart analyze app` -- no issues.
- Verify step (same day): every command above re-run with the same results; `cargo make codegen` re-run changed no generated file. The Unicode test now also asserts the matrix's literal row (precomposed `café`), next to its combining-mark variant: `cargo test -p zanshin-diff --test word_diff` -- 13 passed. `dart test -r expanded test/ffi/diff_test.dart test/worker/diff_test.dart` (the test-core environment) -- 20 passed, among them `a line decodes its word-level segments, an absent vector as none` and `every_line_carries_its_word_level_segments`.

**Results after the review patches (2026-11-11; supersede the counts above):**
- `cargo test -p zanshin-diff` -- 17 passed (adds the reordered-call, renderer-shape and 128 KiB-cap tests).
- `cargo test -p zanshin-ffi --lib diff` -- 11 passed; `--test it -- diff_ffi:: ffi_abi_doc_sync::` -- 24 passed.
- `cargo test -p zanshin-jj --test it -- hunks:: diff::` -- 59 passed (AC 3: no `zanshin-jj` file changed).
- `cargo test -p xtask gate_plan` -- 16 passed.
- `cargo clippy -p zanshin-diff -p zanshin-ffi -p xtask --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean.
- `cargo make codegen` -- re-run after the patches changed no generated file (`shasum -c` on both accessor files, `zanshin_ffi.h` and `bindings.dart`).
- `cargo deny --workspace check advisories bans` -- advisories ok, bans ok.
- `cargo make --allow-private test-core` -- 1185 passed, both segment tests among them; `dart analyze --fatal-infos --fatal-warnings` and `dart format --set-exit-if-changed` in `packages/zanshin_core` -- clean; `dart analyze app` -- no issues.
- Not run, by the run's gate rule: `cargo make test` / `test-full` / `coverage` (the story loop's end gate), and the parity oracle (no jj verb changed).

## Auto Run Result

Status: done. Code commit `11750c7975a2f4f39e07bc37f3b6860af7142102`.

**Summary.** Every diff line now carries its word-level segments, from Rust through the FFI wire into Dart.
- `zanshin_diff::compute_word_diff(removed, added)` runs imara-diff's `Algorithm::Histogram` plus `postprocess_no_heuristic` over the lines' Unicode word-bound tokens (`split_word_bounds`, UAX #29). It returns each side's `Segment { text, kind }` (`Equal`, `Removed` or `Added`).
- `zanshin_diff::line_segments(&[HunkLine])` applies the AC's positional pairing: a run of removed lines directly followed by a run of added lines, the i-th with the i-th. A line without a partner, a pair with a line over 128 KiB (added by the review) and a context line are one segment of their own kind.
- `zanshin_ffi::diff::diff_to_envelope` writes them as `HunkLine.segments` on every line (a single-segment line shares the line's string). Dart decodes `HunkLine.segments`; `Segment` and `SegmentKind` are exported from `zanshin_core.dart`. `zanshin_jj` is unchanged.
- AC reconciliations (epics.md note): no empty trailing `Equal("")`; "share no words" is read as "share no token"; the long-line test witnesses completion only (Story 5.7 is deleted); pairs over 128 KiB are not word-diffed.

**Files changed.**
- `crates/zanshin-diff/src/word_diff.rs` (new): `Segment`, `SegmentKind`, `compute_word_diff`, `line_segments` with the 128 KiB cap.
- `crates/zanshin-diff/src/lib.rs`, `Cargo.toml`: the module, re-exports and dependencies (`imara-diff`, `unicode-segmentation`, `zanshin-jj`).
- `crates/zanshin-diff/tests/word_diff.rs` (new): 17 tests — the matrix rows, the invariants, the pairing, the cap, the renderer shapes and the Histogram/postprocess pin.
- `Cargo.toml`, `Cargo.lock`: workspace dependencies `imara-diff =0.2.0`, `unicode-segmentation =1.13.3` and `zanshin-diff`, each with a `# WHY:`; the lock gains imara-diff only.
- `schemas/envelope.fbs`: `SegmentKind`, `Segment`, `HunkLine.segments`; the `ShowEntry` comment points at the `Diff` payload.
- `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`: `cargo make codegen` output (`zanshin_ffi.h` and `bindings.dart` unchanged).
- `crates/zanshin-ffi/Cargo.toml`, `src/diff.rs`: the builder writes the segments; unit test with literal values and the shared string.
- `crates/zanshin-ffi/tests/it/diff_ffi.rs`: on a real repo the wire's segments equal `line_segments`, plus a literal witness.
- `packages/zanshin_core/lib/src/ffi/diff.dart`, `lib/zanshin_core.dart`: `Segment`, `SegmentKind`, `HunkLine.segments` (optional, default `[]`), decoder and exports.
- `packages/zanshin_core/test/ffi/diff_test.dart`, `test/worker/diff_test.dart`: synthetic decode; real-cdylib segments through `RepoHandle.diff`.
- `crates/xtask/src/tasks/gate_plan.rs`: `crates/zanshin-diff/` now counts as Rust in the cdylib.
- `docs/ffi-abi.md`: the segments contract and the new exports.
- Ledgers: `epics.md` (Story 5.2 reconciliation note), `sprint-status.yaml` (5-2 done), `deferred-work.md` (a 5.2 line under "Word-level and syntax marks have no consumer story"; "Surfaced in Story 5.2" with the spec's 2 deferred items), `epic-5-context.md` (compiled this run; 5.2 done and its decisions).

**Review.** 29 findings: 0 high, 4 medium, 18 low, 7 false. Patched entries: 9 — 3 medium (the 128 KiB cap for long lines; the shared string for single-segment lines; the Histogram/postprocess regression test) and 6 low (the whitespace wording; the `ShowEntry` comment; epic-5-context.md; the renderer-shape tests and doc; the test's count guard; the jj comparison in the ledgers). Deferred: 1 (project-context.md's stack list). Rejected, with reasons in the Review Triage Log:
- the "complete rewrite" reading (blind and intent rows): low and cosmetic, nothing renders segments yet, and the other reading would contradict the intent-contract's "Shared space only" row;
- UAX #29's coarse tokens for code (`self.foo`): out of scope, the intent names Unicode word boundaries;
- the `zanshin-diff` → `zanshin-jj` dependency: the spec's contract, and no story needs the other direction;
- the exact `unicode-segmentation` pin: the workspace's pattern for crates already locked as transitives;
- paired lines that differ only in invalid UTF-8: the marks match the lossy text 5.1 kept;
- an empty-text line giving an empty segment: unreachable from jj's hunks;
- false: segments only at the wire (by design); the app does not render them (no AC asks; tracked); jj-lib in the dependency graph (no import); `done` before review (committed with the done spec); the dropped test-placement rule (it is in CLAUDE.md); the jj-token deferral (word marks are terminal presentation, so it is a product question).

**Follow-up review recommended: true.** This first pass patched 3 medium entries (0 high, 6 low). The unverified risks: the 128 KiB cap departs from the intent-contract's pairing bullet for lines over the cap, and its value rests on probe timings alone (about 0.3 s per pair in release at the cap, seconds above it); the shared string changes the wire layout of every single-segment line. Both are covered by targeted tests only, and the per-file coverage of the new `crates/zanshin-diff/src/word_diff.rs` is measured only by the story loop's end gate.

**Verification.** See "Results after the review patches" above; every targeted command passed.

**Residual risks and open questions for Ralph.**
- Zanshin's word marks differ from `jj diff --git`'s underlines (deferred; Claude's proposal: leave it, FR-DF-1 names imara-diff).
- A complete rewrite keeps shared spaces, punctuation and the line ending `Equal` (reconciliation (2)). If the AC's other reading is wanted, `line_segments` can leave a pair with no shared word token unpaired — a few lines plus the matrix row (Claude's proposal: leave it until a renderer shows whether it matters).
- UAX #29 keeps member access such as `self.foo` as one token, so code marks are coarser than Delta's (`\w+`).
- No UI renders the segments yet (deferred-work.md, "Word-level and syntax marks have no consumer story").
- project-context.md's stack list is stale (deferred).
