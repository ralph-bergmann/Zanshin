---
title: 'Story 5.10 — The diff is jj''s default format (color-words)'
type: 'feature'
created: '2026-11-12'
status: 'done'
baseline_revision: 'd14faaffb132c49c1bfc05abafaeb9f611fd28a7'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      Decision for Ralph: on a changed line the removed and added word marks differ by hue only, which the DS contrast checklist warns against.
    evidence: |-
      DS design_system/readme.md checklist: "Colors that must be told apart differ in lightness, not hue alone; blue/orange beats red/green". On a changed line --rem-word-bg / --add-word-bg (both under --text glyphs) differ by hue only, the left / right numbers by hue and column. No extra cue was added (Story 5.10 Always rule). Options: leave it, a lightness step between the two word tints, or a cue beyond colour.
    location: >-
      app/lib/src/features/graph/inspector_diff.dart (_lineText)
    severity: medium
  - summary: >-
      Each file side is still read the way jj diff --git does (git_diff_part), not the way color-words does (diff_content_as_merge).
    evidence: |-
      Review pass 2026-11-12 (blind hunter, edge-case hunter): an unreadable side fails the whole Repo::diff (the CLI prints "Access denied to <path>: ..." and goes on); a Git submodule side is empty (the CLI diffs "Git submodule checked out at <id>"); a mode-only change of a binary file is not binary (the CLI prints "(binary)"). Pre-existing reading code the story kept ("binary and mode-only rules unchanged"); the access-denied case needs a wire marker for a skipped file.
    location: >-
      crates/zanshin-jj/src/hunks.rs (DiffReader::file)
    severity: medium
---

<intent-contract>

## Intent

**Problem:** Zanshin's diff is `jj diff --git`'s line layout with Zanshin's own line pairing (Story 5.9's E2, `crates/zanshin-jj/src/line_pairs.rs`) deciding which words are marked. Ralph chose (2026-11-12, epics.md Story 5.10, DECIDED) what `jj diff` prints with no `ui.diff-formatter`: the `:color-words` format, so the diff equals the CLI's default again and no rule of Zanshin's own marks words.

**Approach:** Port the CLI's color-words walk (`git -C ../jj show v0.47.0:cli/src/diff_util.rs`, lines 751–1400) into `crates/zanshin-jj/src/hunks.rs` on top of jj-lib's exported pieces, emit its lines as data (kind, left/right line number, segments), carry them over the FlatBuffers wire to `zanshin_core`, and draw them in the inspector diff (unified with two number columns, side by side rebuilt from the same lines), the design system and the catalogue. Delete `line_pairs.rs`. A new parity-oracle module compares Zanshin's lines with the pinned `jj diff --color=debug`.

## Boundaries & Constraints

**Always:**
- The lines, their kinds, left/right numbers, segment kinds and texts equal what the pinned CLI prints in colour (`formatter.maybe_color()` true — Zanshin draws colour, so it always takes the inline-capable path).
- Reuse jj-lib 0.47.0: `diff_presentation::diff_by_line`, `diff_presentation::unzip_diff_hunks_to_lines`, `files::DiffLineIterator::with_line_number` / `next_line_number`, `files::DiffLineHunkSide`, `files::DiffLineNumber`, `files::conflict_diff_hunks`, `files::merge`, `ContentDiff::by_word`. Port only the CLI-only parts: `count_diff_alternation`, `split_diff_hunks_by_matching_newline`, `show_color_words_context_lines`' context rule (including the source-symbol line of a skipped range and the "one line more is shown whole" rule), `show_color_words_conflict_hunks` / `show_color_words_unresolved_hunk` / `describe_conflict_term`. Each ported function names its CLI origin (`cli/src/diff_util.rs` @ v0.47.0) in its doc.
- Options come from the effective config like the CLI's `ColorWordsDiffOptions::from_settings`: `diff.color-words.context` (`HunksOptions::context` / `DiffOptions::context` `None` = this key; `Some` overrides like `--context`), `diff.color-words.max-inline-alternation` (`-1` = unlimited, other negatives are a config error), `diff.color-words.conflict` (`materialize` | `pair`, anything else a config error); `-w` / `-b` via the existing `Whitespace`.
- Source symbols: the CLI's language rule `SourceLanguage::from_file_name(..).or(Some(Generic))` — port jj 0.47.0's `Generic` language into `crates/zanshin-jj/src/source_symbol.rs` (the v0.46→v0.47 diff of `cli/src/source_symbol.rs`: the enum member, its `is_source_symbol` arm, `is_comment_line`, `source_symbol_from_line`'s untrimmed match, the test-table rows) and update the module doc's tag to v0.47.0. The description block (`JJ-COMMIT-DESCRIPTION`) is Generic too, as in `show_diff_bytes`.
- Unchanged in meaning: file kinds, binary and mode-only rules, copy/rename reading, `FileDiff::sections`, the description block's presence rules, summary mode, `compute_hunks` (same lines as `Repo::diff`). `FileDiff::fingerprint` keeps its exact VALUES (persisted Viewed keys, Story 10.24): it hashes, per changed line-diff block, the left lines `-`-tagged then the right lines `+`-tagged — compute it from `diff_by_line`'s `Different` hunks so the pinned-hash test in `hunks.rs` passes unchanged.
- Segment invariants: never empty, adjacent segments differ in kind, a line's segments concatenate to its text.
- UI: no underline, no strikethrough; existing tokens only (`--rem`, `--rem-bg`, `--rem-word-bg`, `--add*` alike, `--text`, `--text-muted`, `--text-faint`, `--text-dim`). If DS contrast guidance asks for a cue beyond hue on a changed line, do not add one: record it in `deferred:` as a decision for Ralph.
- Tests never read a file under `spikes/` or outside their own package: copy witness text into the test.

**Never:**
- No reading of `ui.diff-formatter`; no `:git` layout kept; no word-mark rules of Zanshin's own; no move detection; no syntax colours; no ignore-whitespace UI (10.33); no settings UI for `diff.color-words.*`.
- No full gate (`cargo make test` / `test-full` / `coverage`) — targeted checks only (story-loop gate rule).
- No `jj` outside temp dirs you create; with the stock `jj`, set `JJ_CONFIG` to an empty file. Never touch `~/development/projects/Kunden/`. Never a bare `cd`.
- No edit of epics.md, Story 5.9's specs, or the existing deferred-work.md bullets.

## I/O & Edge-Case Matrix

Expected lines are what the pinned CLI prints; `L R` = left / right number (blank = none).

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Ralph's jj example | jj `671e4eaca` `lib/src/git.rs` `write_locked_index` (fixture text; old 2451–2459 → new 2451–2466, padded so numbers match) | `2454 2454` `        .map_err(\|err\| ` Equal + `{` Added; `2455`–`2458` right only (Added); `2454 2459` `        .map_err(` Added, `GitResetHeadError::from_git` Equal, `(err.into_error())` Removed, `)?;` Equal; `2456 2461` `        .map_err(\|err\| ` Equal + `err.error)` Added; `2462` right only `        .context(index.path())`; `2456 2463` like 2459 with `(err.error)` Removed | — |
| Three small edits (stepper.dart) | `isLastStep ? s.functionWizard_save` → `saveLabel`; `Expanded(child: …)),` → 3 lines; comment inserted above `spacing8` → `spacing2` | one Changed line with the removed and the added word; the split call is one old line (same left number) over three lines; the inserted comment line shares its old line's left number with the Changed line below | — |
| Block over the limit | Ralph's widget-test block: 3 removed, 16 added | not inlined: 3 Removed lines then 16 Added lines, word marks as `unzip_diff_hunks_to_lines` spreads them over the block | — |
| `max-inline-alternation = 0` | jj example | 2 Removed + 9 Added lines with word marks | — |
| `max-inline-alternation = -1` | widget-test block | inlined | — |
| Context rule | context 3, two one-line changes 7 / 8 unchanged lines apart | 7 apart: one hunk showing all 7; 8 apart: two hunks | — |
| Skipped-range label | Rust file, change far from the top | hunk `symbol` = the CLI's `    ...    ` line text (raw line, no line break); plain `...` → `None` | — |
| `-b` | a context line whose indentation changed between two changes | kind Context, its numbers and marks as the CLI's context-labelled diff lines | — |
| `--context 1` | jj example | the CLI's lines | — |
| Conflict, `materialize` | a side with a file conflict | the marker texts diffed like any text | — |
| Conflict, `pair` | `diff.color-words.conflict = "pair"` | ConflictHeader lines `<<<<<<< Created conflict` / `Resolved conflict` / `Modified conflict`, `+++++++ left… to right…` / `------- …`, `>>>>>>> Conflict ends`; under `-------` removed/added roles (line kinds and segment kinds) swap | — |
| Bad config | `max-inline-alternation = -2` or `conflict = "x"` | config error, as `ConfigGetError` in the CLI | `MutateError` config error |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/hunks.rs` -- the diff read. `HunksOptions` / `DiffOptions` docs (`diff.git.context` → `diff.color-words.context`) :79-81, :144-146. `Hunk` :223-245 (drop `segments`, keep the rest), `Segment` doc :247-257, `HunkLine` enum :277-288 → struct. `DiffReader::new` :520-544 reads `diff_git_context` → read the color-words options. `DiffReader::description` :575 and `file` :598-645 call `hunks_of` :714-743 (rewrite: the color-words walk; `unified_diff_hunks`, `line_pairs`, `hunk_line`, `symbol`, `hunk_sections` go). `fingerprint` :670-689 (recompute from the line diff). `file` reads sides via `git_diff_part` (materialized text, binary flag) — keep for `materialize`; `pair` needs each side's `Merge<BString>` + labels (`MaterializedTreeValue::FileConflict { contents, labels, .. }`, else resolved) and `files::merge(side, &store.merge_options())`. Inline tests :839-1241: keep fingerprint/totals/sections/symbol/whitespace tests (adapted), replace the E2 tests with the matrix rows.
- `crates/zanshin-jj/src/line_pairs.rs` -- delete; `crates/zanshin-jj/src/lib.rs:55` `mod line_pairs;` and :121 exports (`HunkLine`, `Segment`, `SegmentKind`; add the new kind enum).
- `crates/zanshin-jj/src/source_symbol.rs` -- add `Generic` (see Always); `SourceSymbolScanner` (:310-343) and `trim_source_symbol` (:345-357) become unused once `hunks.rs` stops using them: delete them and their tests. `source_symbol_from_line` :297 is what the context rule needs.
- `crates/zanshin-jj/src/config.rs:1534-1553` -- `diff_git_context` → `diff_color_words(config)` returning context, max inline alternation (`Option<usize>`), conflict method, using `config.get(..).map_err(|e| value_error(&e))` (:342); defaults come from `CLI_DEFAULTS` (:268, asserted against jj-cli's layers at :2593 — check the three keys are there). Its test near :2623.
- `crates/zanshin-jj/src/repo.rs:4408-4479` -- `compute_hunks` / `diff` docs naming `jj diff --git` / `diff.git.context`.
- `crates/zanshin-jj/tests/it/hunks.rs` -- `assert_counts` :180-197 assumes `before_range.len() == context + removed` (rewrite for the new counts); line-text asserts :262-267, :309-317, :373-375, conflicted merge :458-475, :518-521; config-key tests :578-605 (`diff.git.context` → `diff.color-words.context`).
- `crates/zanshin-jj/tests/it/diff.rs` -- line asserts :242-250, :391-393, :646-647, :752-756, :823-839.
- `crates/zanshin-jj/tests/it/api_stability.rs:1785-1849` -- public-surface test listing `HunkLine` variants and `Hunk.segments`.
- `schemas/envelope.fbs` -- `SegmentKind` :3174, `Segment` :3177, `HunkLineKind` :3184 (APPEND `Changed`, `ConflictHeader`), `HunkLine` :3198 (APPEND `left_line: uint; right_line: uint;`, 1-based, 0 = no number; `text` = all segments joined), `Hunk` :3212 docs, `DiffRequest` doc :376. Then `cargo make codegen` (`crates/zanshin-ffi/src/envelope_generated.rs`, `include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`, bindings).
- `crates/zanshin-ffi/src/diff.rs` -- `hunk_offset` :203-227 (zips `lines` with `segments`), `line_offset` :229-258 (3-arm match; single-segment string sharing), docs :28-31, :102, :125; inline tests :295-834 (`line_from_wire` :330, `sample()` :436-520, segment tests :584-660).
- `crates/zanshin-ffi/tests/it/diff_ffi.rs` -- `kind_and_text` :93-99, segments :101-158, `assert_wire_is` :161-224, :531.
- `packages/zanshin_core/lib/src/ffi/diff.dart` -- `HunkLineKind` :46-56, `SegmentKind` :58-68, `HunkLine` :83-110 (add `int? left`, `int? right`; docs), `Hunk` :112-148, `zanshinDiff` doc :259, decoder `_line` :356-379 (exhaustive switch). Docs `lib/src/worker/handle.dart:1629,1642`, `lib/src/worker/commands.dart:2350`. Tests `test/ffi/diff_test.dart` (:18-21, :108-119, :145-177), `test/worker/diff_test.dart` (:79, :94-115, :150, :206).
- `app/lib/src/features/graph/inspector_diff.dart` -- `hunkHeader` :15-23 (doc), `pairSideBySide` :25-49 (rebuild), `diffWordMarks` :56-75 (a Changed line always marks), `_lineText` :165-201 (mark colour per segment kind, not per line kind), `noNewlineMarker` :154-163, `_look` :655-659 (exhaustive), `_unified` :661-714 with the sigil column :678-699 (→ two number columns), `_sideBySide` :716-762. Users: `graph_inspector.dart:2266`, `undo_timeline/operation_changes.dart:673,698`. Tokens in `packages/zanshin_ui/lib/src/design/zs_colors.dart`.
- App tests: `app/test/features/graph/inspector_diff_test.dart` (builders :16-41, groups :91-170, widget tests :203-450), `graph_real_repo_test.dart:127-215` (real-worker word-mark witness keyed by line text), `graph_inspector_test.dart` (:102-124, :302-311, :1161-1190, :1361-1375, :1463, :1885-1947), `graph_ports_test.dart:173-175,369-370`, `undo_timeline/operation_changes_test.dart`, `test/helpers/fake_undo_timeline.dart:199-201`.
- `app/widgetbook/folders/graph.dart:924-1161` -- `_DemoDetails`, `_words` parser, `_diffOf` demo hunks; `app/widgetbook/folders/undo_timeline.dart:249-252`.
- `_bmad-output/implementation-artifacts/design_system/components/content/` -- `DiffView.jsx` (`zsDiffLine` :11-19 parses git sigils, `.sg` sigil :54), `DiffHunk.jsx` (unified sigils :16, split pairing :19-26), `.d.ts`, `.prompt.md`, `content.css:22-65`, `content.card.html:17,44-59`; also `guidelines/colors-accents.html:95,158-168`, `ui_kits/desktop/inspector.jsx:219-226`; hand-kept bundle copy `design_system/_ds_bundle.js:1331-1522`, `_ds_manifest.json`, sync log `readme.md:46-47`; build + publish per `.claude/skills/design-artifacts/SKILL.md` (`build_ds.py`).
- `crates/zanshin-parity/tests/oracle/` -- `main.rs` (module list), `driver.rs` (`fresh_repo`, `jj()`, `Step::{Jj, Write, …}`), `diff_revisions.rs` (a `Repo::diff`-vs-CLI module to model on). Use `jj config set --repo …` as a fixture step so both sides read the same `diff.color-words.*` (no process env change).
- `docs/ffi-abi.md:2464-2534,2558` -- `Diff` payload shape, segments text, `diff.git.context`.
- `_bmad-output/project-context.md:863-871` -- the "Word diffs are jj-lib's, on paired lines" rule.
- `coverage-baseline.txt:81` -- the `line_pairs.rs` line goes.
- `spikes/structural-diff-probe/src/main.rs:8-9` -- `#[path = "../../../crates/zanshin-jj/src/line_pairs.rs"]`; detached crate (not a workspace member), also used at `marks.rs:125`, `limits.rs:109,374`, `history.rs:502`.
- Fixture sources (read, copy text into tests): `git -C ../jj show 671e4eaca^:lib/src/git.rs` / `671e4eaca:lib/src/git.rs`; `spikes/structural-diff-probe/inputs/witness/stepper/{before,after}.dart`, `.../widget-test-rename/{before,after}.dart`; the widget-test hunk is also in `hunks.rs` test `rewritten_comments_and_a_renamed_test_mark_only_the_rename` :1086-1144.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/hunks.rs` -- new line model: `pub struct HunkLine { pub kind: HunkLineKind, pub left: Option<u32>, pub right: Option<u32>, pub segments: Vec<Segment> }` + `fn text(&self) -> String`; `pub enum HunkLineKind { Context, Removed, Added, Changed, ConflictHeader }`; `Hunk` loses `segments`. The walk: per file, `show_color_words_diff_hunks`' branches (resolved / materialize / pair) → `show_color_words_resolved_hunks` / `show_color_words_conflict_hunks` emitting lines into a sink; a skipped range (`...`) closes the current hunk and opens the next with that range's symbol. Kinds: context path → Context (both numbers; under `-w`/`-b` the context-labelled diff lines keep kind Context); changed block inline → per `DiffLine`: both sides' content → Changed, left only → Removed, right only → Added; not inlined → Removed lines then Added lines; header lines → ConflictHeader (one Equal segment, no numbers). Segments: `Both`/`Matching` → Equal, left-side token → Removed, right-side → Added; under a `-------` conflict term swap Removed↔Added for both line kinds and segment kinds (numbers stay on their sides). `before_range` / `after_range`: 0-based, from the line-number counters at the hunk's first and past its last line. `removed` / `added`: the number of distinct left / right numbers on its non-Context, non-header lines. `sections`: the file sections whose old range holds such a line's left number − 1 or whose new range holds its right number − 1. Fingerprint from the line diff (see Always). Docs: module + types describe the CLI rule. -- the CLI's color-words output as data.
- `crates/zanshin-jj/src/config.rs`, `crates/zanshin-jj/src/source_symbol.rs`, `crates/zanshin-jj/src/lib.rs`, `crates/zanshin-jj/src/repo.rs` -- options reader, Generic language, exports, docs; delete `line_pairs.rs`, now-unused helpers and the coverage-baseline line. -- supporting code; no orphans.
- `crates/zanshin-jj/src/hunks.rs` inline tests -- one test per matrix row that needs no repo (jj example inline, at limit 0 and −1, `--context 1`; stepper edits; widget-test block; 7/8-apart context rule; skipped-range symbol incl. Generic; `-b` context line; one-line-more shown whole; no-newline last line; option parsing errors) plus the pinned fingerprint test unchanged. -- matrix coverage.
- `crates/zanshin-jj/tests/it/{hunks,diff,api_stability}.rs` -- adapt to the new model; conflict `materialize` and `pair` through a real conflicted repo (a `pair` test sets the key via the repo config). -- integration witnesses.
- `schemas/envelope.fbs`, `cargo make codegen`, `crates/zanshin-ffi/src/diff.rs` (+ inline tests), `crates/zanshin-ffi/tests/it/diff_ffi.rs`, `docs/ffi-abi.md` -- wire the new kinds and numbers; commit generated output. -- FFI.
- `packages/zanshin_core/lib/src/ffi/diff.dart` (+ docs in `worker/handle.dart`, `worker/commands.dart`) and its tests -- decode kinds `changed` / `conflictHeader` and `left` / `right` (`null` when 0). -- bridge.
- `app/lib/src/features/graph/inspector_diff.dart` -- unified: per row left number, right number (right-aligned, wide enough for the hunk's largest number, `SelectionContainer.disabled`), then the text; looks: Context faint numbers (`textFaint`) + muted text; Removed left number in `rem`, `remBg` fill, Removed words on `remWordBg`; Added likewise green; Changed both numbers in colour (left `rem`, right `add`), no fill, `text` ink, removed words on `remWordBg`, added on `addWordBg`; ConflictHeader mono `textDim`, no numbers. Word marks: Removed/Added keep 10.32's "no visible unchanged text → fill only" rule; Changed always marks. Side by side: walk the hunk; a Context line is one row (left cell = its Equal+Removed segments with its left number, right cell = Equal+Added with its right number); a run of Removed/Added/Changed lines up to the next Context or header: left cells = for each distinct left number in order, the joined Equal+Removed segments of the lines carrying it; right cells likewise with right numbers and Equal+Added; pair row by row, `null` cells on the shorter side; a header line is a full-width row. Each cell shows its number. Hunk header, picking checkbox, no-newline marker unchanged in behaviour; docs say color-words. -- the UI.
- App tests listed in the Code Map -- new builders (kind + numbers + segments), tests for the number columns, the Changed look (no fill, both numbers coloured, both mark colours), side-by-side rebuild (the jj example shows old line 2454 once, whole), a picked hunk, night and paper; `graph_real_repo_test.dart` witnesses re-derived from the real worker's color-words output. -- UI checks.
- `app/widgetbook/folders/graph.dart`, `app/widgetbook/folders/undo_timeline.dart` -- demo data in the new model: a simple inlined block (the jj example or stepper edits), a block over the limit (widget-test), context lines. -- catalogue.
- Design system (`design_system/components/content/` DiffView, DiffHunk, CSS, `.d.ts`, `.prompt.md`, `content.card.html`, `_ds_bundle.js`, other users above, sync log) -- show two number columns and the Changed line instead of sigils; the demo shows a simple block and a block over the limit. Then build and republish per the `design-artifacts` skill; if this run cannot publish, say so in the report. -- DS follows the product.
- `crates/zanshin-parity/tests/oracle/diff_color_words.rs` (+ `main.rs`) -- for each witness repo: parse the pinned `jj diff --color=debug` output (per output line: the `removed`/`added` `line_number` labels, `token` labels → segment kinds, `context` label, `    ...    ` symbol lines, `hunk_header` conflict lines; skip the file header) and compare with Zanshin's `Repo::diff` lines (kinds, numbers, segment kinds and texts, hunk symbols). Witnesses: jj example (padded), stepper edits, widget-test block, limit `0` and `-1`, `--context 1`, `-w`, `-b`, 7/8-apart, conflict `materialize` and `pair`. -- CLI parity.
- `spikes/structural-diff-probe/` -- copy the current `line_pairs.rs` into the spike's `src/` and point its `#[path]`/`mod` at the copy, with one README line saying it is the frozen Story 5.9 E2 code. -- keeps the detached probe buildable.
- `_bmad-output/project-context.md`, every doc saying `jj diff --git` / `diff.git.context` (Code Map) -- the rule becomes "the diff is `jj diff`'s default color-words output (jj-lib's line and word diff, the CLI's inline rule)". -- canonical rules follow the decision.

**Acceptance Criteria:**
- Given any witness repo, when `Repo::diff` runs under the same options and config as `jj diff --color=debug`, then every line's kind, left/right number, segment kinds and texts and every hunk's skipped-range symbol equal the CLI's.
- Given a diff with Changed lines, when it crosses the FFI and is decoded by `zanshin_core`, then each line keeps its kind, numbers (`null` for none) and segments.
- Given the inspector or the Undo Timeline's operation view, when a hunk is drawn unified, then each row shows the left and right number instead of a sigil, a Changed line has no fill, both numbers in colour and both mark colours; side by side shows each old line once, whole, with its number.
- Given a file's diff, when its fingerprint is computed, then the value equals the pre-5.10 value for the same change (pinned test).

## Spec Change Log

## Review Triage Log

### 2026-11-12 — Review pass
- verdicts: 24 findings — high 0, medium 8, low 11, false 5, maybe-false 0
- findings:
  - `[medium]` `[defer]` (blind) An unreadable side fails the whole call; color-words prints `Access denied …` and goes on — real (`git_diff_part` returns `UnifiedDiffError::AccessDenied`), pre-existing reading code the story kept; needs a wire marker; deferred with the reading-rules entry.
  - `[medium]` `[defer]` (blind) Binary/conflict reading follows the git path: a mode-only change of a binary file is not `(binary)`, a NUL in conflict terms flags binary — real, pre-existing reading rule the story kept unchanged; deferred (same entry).
  - `[medium]` `[patch]` (blind) Under `pair`, `sections` / ranges map term-coordinate numbers onto materialized-text sections — real; patched: the pair walk gives its hunks no sections, with a test.
  - `[low]` `[reject]` (blind) Under `pair`, `removed` / `added` undercount because terms reuse numbers — real but only with the opt-in `pair` method, and counting lines instead would break the split-call rule (one old line over several rows); not worth the extra branching.
  - `[low]` `[reject]` (blind) Side by side gives each `-w` / `-b` context line its own row — real in the model, but the app never sets `-w` / `-b` (Story 10.33 is backlog), so no user meets it today.
  - `[low]` `[reject]` (blind) Side by side colours a `-------` term's left cells red while unified shows them green — real, only with the opt-in `pair` method; the fix adds per-cell role tracking.
  - `[low]` `[patch]` (blind) The no-newline marker sits under the number columns — real (`EdgeInsets.symmetric(horizontal: 10)`); patched to start at the text. Its presence is kept by the story ("the marker stays"), so the "not color-words output" part is false.
  - `[low]` `[reject]` (blind) The oracle parser assumes 4-digit numbers — real for files over 9,999 lines, but no witness reaches it and the oracle is test-only.
  - `[false]` `[reject]` (blind) Several witnesses only unit-tested / missing — the oracle covers every matrix row (jj example, `--context 1`, limits 0 / −1, stepper, widget test, `-w` / `-b`, context rule, both conflict methods); parse errors are tested in `config.rs` and `tests/it/hunks.rs`; the description gap is the verification-gap finding below.
  - `[low]` `[patch]` (blind) The symbol keeps `\r` on CRLF files — real; patched: a trailing `\r\n` is stripped, with a test. The missing 80-byte cut is CLI parity (the CLI prints the whole line), so that part is false.
  - `[low]` `[reject]` (blind) The line diff runs twice per file, conflict terms are copied under `materialize` — real but cheap (`diff_by_line` is linear-ish; terms only for conflicted files); no measured cost.
  - `[low]` `[reject]` (blind) A whitespace-only change under `-w` / `-b` can show a hunk of context lines with `+0 −0` — CLI parity (the CLI prints those lines); the app never sets `-w` / `-b` yet (Story 10.33 decides the UI).
  - `[false]` `[reject]` (blind) DS users not updated and publish unverified — `inspector.jsx` / guidelines still parse (the DS keeps the git-sigil input as a fallback, checked in the bundle); the implementation run republished the DS artifact and canvas (its report, version 1794513640-0c5d).
  - `[low]` `[reject]` (edge-case) A hunk that starts mid `-------` term resets the swap in `pairSideBySide` — real only with `pair` plus a skipped range inside a term; same root as the rejected pair colour finding.
  - `[medium]` `[patch]` (edge-case) `pair` hunks name wrong `select_tree` sections — same root as the blind `pair` sections finding; patched there.
  - `[medium]` `[defer]` (edge-case) A Git submodule side is empty where color-words diffs `Git submodule checked out at <id>` — real (`git_diff_part` gives empty content); deferred with the reading-rules entry.
  - `[medium]` `[defer]` (edge-case) Access denied fails the whole diff — duplicate of the blind finding; deferred.
  - `[low]` `[reject]` (edge-case) Side-by-side `-------` cells red with green marks — duplicate of the blind finding; rejected there.
  - `[low]` `[reject]` (edge-case) `-w` / `-b` context lines with a repeated number show twice side by side — duplicate of the blind finding; unreachable in the app today.
  - `[medium]` `[patch]` (verification-gap) A multi-line block's fingerprint is not pinned — real; patched: the pinned test adds two blocks (one 2 removed + 3 added) against the explicit block-wise hash.
  - `[medium]` `[patch]` (verification-gap) The description block's context override and Generic language are untested — real; patched: `tests/it/diff.rs` asserts context 0 skips lines and the skipped range's symbol is the Generic symbol line.
  - `[false]` `[reject]` (intent) I1–I3 have no per-number outcome — the Auto Run Result below lists each (it is written at finalize, after the review).
  - `[false]` `[reject]` (intent) The oracle's Changed kind is a parser convention — the CLI marks a changed line by printing both numbers outside the `context` label; that is what the parser reads, and numbers, token sides and texts are compared directly.
  - `[false]` `[reject]` (intent) No Marionette check or DS republish stated — the DS was republished; the Marionette check is stated as not done under the Auto Run Result (allowed by the intent).

## Design Notes

- **One old line over several rows.** `DiffLineIterator` gives every row that holds left content the current left number, so a split call repeats its left number (`2454 2454`, `2454 2459` in the jj example). That is why `removed` counts distinct numbers and why side by side joins rows by number.
- **Hunk boundaries.** The CLI has no `@@` headers; `...` lines split the output. A file's first hunk may start without a skipped range (change near the top) — its `symbol` is `None` then.
- **Line numbers on the wire.** `uint` with 0 = none, not optional scalars: `flatc --dart` has no optional scalars (`DiffContext` doc in `envelope.fbs`), and the CLI's numbers start at 1.
- **Open items I1–I3** (deferred-work.md, Story 5.9 sections) all concern E2's pairing; deleting `line_pairs.rs` settles them.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib -- hunks:: source_symbol:: config::` -- expected: pass.
- `cargo test -p zanshin-jj --test it hunks::` and `cargo test -p zanshin-jj --test it diff::` and `cargo test -p zanshin-jj --test it api_stability::` -- expected: pass.
- `cargo test -p zanshin-ffi --lib diff::` and `cargo test -p zanshin-ffi --test it diff_ffi::` and `cargo test -p zanshin-ffi --test it ffi_abi_doc_sync::` -- expected: pass.
- `cargo test -p zanshin-parity --test oracle diff_color_words::` and `cargo test -p zanshin-parity --test oracle diff_revisions::` -- expected: pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean.
- `cargo make codegen` -- expected: generated files committed, a rerun leaves no diff.
- In `packages/zanshin_core`: `flutter test` (or `dart test`), `dart analyze`, `dart format --set-exit-if-changed .` -- expected: pass.
- In `app`: `flutter test test/features/graph test/features/undo_timeline`, `dart analyze`, `dart format --set-exit-if-changed lib test widgetbook` -- expected: pass.

**Manual checks (if no CLI):**
- `rg -n "diff.git.context|jj diff --git|line_pairs" crates packages app docs schemas _bmad-output/project-context.md` -- only historical mentions remain (none in code docs).
- Catalogue in Marionette (inspector demo, night and paper) against the DS card, if a running app can be held; otherwise say so.

**Verification notes (2026-11-12, after the review patches; story-loop gate rule, no full gate):**
- `cargo test -p zanshin-jj --lib -- hunks:: source_symbol:: config::` — 116 passed.
- `cargo test -p zanshin-jj --test it -- hunks:: diff:: api_stability::` — 101 passed.
- `cargo test -p zanshin-ffi --lib diff::` — 8 passed; `cargo test -p zanshin-ffi --test it -- diff_ffi:: ffi_abi_doc_sync::` — 24 passed.
- `cargo test -p zanshin-parity --test oracle -- diff_color_words:: diff_revisions::` — 13 passed (9 color-words witnesses against the pinned CLI).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean.
- `cargo make codegen` — run by the implementation run twice, second run no diff; generated files in this change.
- `packages/zanshin_core`: `dart analyze` clean, `dart format --set-exit-if-changed .` 0 changed, `flutter test test/ffi/diff_test.dart test/worker/diff_test.dart` — 21 passed. (The full package suite has files that need `cargo make`'s pinned `XDG_CONFIG_HOME`; left to the loop's gate.)
- `app`: `dart analyze` clean, `dart format --set-exit-if-changed lib test widgetbook` 0 changed, `flutter test test/features/graph test/features/undo_timeline test/widgetbook` — 1377 passed.
- Spike `spikes/structural-diff-probe` builds against its frozen `line_pairs.rs` copy (implementation run).
- Stale-mention search: one historical wording mention only (the no-newline marker's "jj's own words").
- Marionette check of the catalogue: not done — this unattended run cannot hold a running app.

## Auto Run Result

Status: done

**Summary.** Zanshin's diff is now what `jj diff` prints without a `ui.diff-formatter` (`:color-words`). `crates/zanshin-jj/src/hunks.rs` ports the CLI's walk (`cli/src/diff_util.rs` @ v0.47.0) on jj-lib's line and word diff: context rule with skipped-range symbols, the inline rule (`max-inline-alternation`), `-w` / `-b` context lines, conflicts `materialize` and `pair`. Lines carry a kind (context, removed, added, changed, conflict header), left/right numbers and segments; the fingerprint keeps its values. E2's `line_pairs.rs` is gone. The wire, `zanshin_core`, the inspector (number columns, changed line, side by side rebuilt by line number), the DS and the catalogue follow; a parity-oracle module checks the lines against `jj diff --color=debug`.

**Files changed** (main ones):
- `crates/zanshin-jj/src/hunks.rs` — the color-words walk as data; new `HunkLine` model.
- `crates/zanshin-jj/src/config.rs` — `diff.color-words.*` reader (`diff_git_context` gone).
- `crates/zanshin-jj/src/source_symbol.rs` — jj 0.47's `Generic` language; unused scanner / trim removed.
- `crates/zanshin-jj/src/line_pairs.rs` — deleted (frozen copy at `spikes/structural-diff-probe/src/line_pairs.rs`); `coverage-baseline.txt` line removed.
- `schemas/envelope.fbs` + generated code — `HunkLineKind` gains `Changed`, `ConflictHeader`; `HunkLine` gains `left_line` / `right_line` (0 = none).
- `crates/zanshin-ffi/src/diff.rs`, `packages/zanshin_core/lib/src/ffi/diff.dart`, `docs/ffi-abi.md` — wire and bridge.
- `app/lib/src/features/graph/inspector_diff.dart` — unified number columns, changed-line look, side by side rebuilt; app tests and widgetbook demos.
- `crates/zanshin-parity/tests/oracle/diff_color_words.rs` — 9 witnesses against the pinned CLI.
- `_bmad-output/implementation-artifacts/design_system/components/content/*`, `_ds_bundle.js`, `readme.md` — DiffView / DiffHunk with numbers and the changed line.
- `_bmad-output/project-context.md` — the diff rule is jj's color-words output.

**Review.** One pass, 24 findings (medium 8, low 11, false 5). Patched: `pair` hunks name no sections (medium), CRLF symbol (low), fingerprint pinned for multi-line blocks (medium), description block context + Generic symbol test (medium), no-newline marker aligned with the text (low). Deferred: hue-only marks on a changed line (decision for Ralph), file sides still read like `git_diff_part` (access denied, submodule, binary mode-only) — both mirrored to deferred-work.md "Surfaced in Story 5.10". Rejected: `pair` counts and side-by-side colours (opt-in `pair` only), `-w` / `-b` side-by-side and context-only hunks (the app never sets `-w` / `-b` yet), oracle 4-digit parser (no witness reaches it), double line diff (cheap), and the false findings — reasons in the triage log.

**Follow-up review:** recommended (`true`): 3 medium entries patched. Named risk: the `pair` conflict path is checked against the CLI on one witness ("Created conflict") only; its side-by-side drawing and counts are not.

**Design system / Marionette.** The implementation run republished the DS artifact (version 1794513640-0c5d) and updated the Zanshin canvas. The Marionette check of the running catalogue was not done (no running app can be held in this run).

**Open items handed to this run:**
- I1 (E2 vs difftastic on real diffs; Ralph decided "go back"): fixed — `line_pairs.rs` is removed and the word marks are jj's color-words marks (commit ab40178370cc7a91d03e56d3ac02747497063373).
- I2 (E2 unmeasured on reflowed prose): fixed — no longer applies; the line pairing it concerns is removed, prose gets the CLI's own marks (commit ab40178370cc7a91d03e56d3ac02747497063373).
- I3 (`true,` → `false,` loses its word marks under E2): fixed — with jj's color-words the one-line block is one Changed line marking only `true` / `false` (commit ab40178370cc7a91d03e56d3ac02747497063373).

**Residual risks.** Coverage was not measured (`hunks.rs`, `source_symbol.rs`, `zanshin-ffi/src/diff.rs` sit at 100 % in the baseline); the loop's final gate checks it. Behaviour changes that follow the CLI: a gap one line longer than the context is shown whole, a first hunk without a skipped range has no symbol.
