---
title: 'Story 5.9 — Structural diff, difftastic class: research (library or program, cost and fallbacks, grammars, mapping onto HunkLine.segments) and the options for Ralph'
type: 'chore'
created: '2026-11-12'
status: 'done'
baseline_revision: '5ba5f5d43b21d45c24c099092384f9d9610fe009'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      Story 5.9's build (item 2) waits for Ralph's choice between the research report's options.
    evidence: |-
      Item 1 is delivered: _bmad-output/planning-artifacts/research/technical-structural-diff-difftastic-class-research-2026-11-12.md (sections 7 and 8), probe spikes/structural-diff-probe/. Options: A leave it (jj's word marks only), B difft as an opt-in external program with a time budget, C difftastic's code vendored as a library, D an own diff over tree-sitter. Claude's recommendation: A. On the witnesses difftastic sets the same word marks as jj (it detects no moves); on the modified .rs / .dart files of the last 200 commits it falls back on 16.6 % of the changed lines and draws different strong marks on 11.2 % of the rest (whitespace fills counted), at a median of 60-63 ms per file as a process (jj 0.2-0.3 ms). Any build lifts 5.2's rule (segments = what jj diff --git underlines). The intent forbids a build decision in this run. Mirrored into deferred-work.md "Surfaced in Story 5.9".
    location: >-
      _bmad-output/planning-artifacts/epics.md Story 5.9; _bmad-output/implementation-artifacts/sprint-status.yaml 5-9-structural-diff-difftastic-class
    severity: low
---

<intent-contract>

## Intent

**Problem:** Zanshin's diff marks are jj's word diff (Story 5.2), drawn in the inspector since Story 10.32. Story 5.9 asks whether a structural diff of the difftastic class — it marks only the changed syntax node, ignores pure reformatting, and handles reordered arguments and changed nesting — is worth building. Nobody has checked whether difftastic can be embedded, what it costs on large files, which grammars it needs, or how its marks would fit the `HunkLine.segments` wire.

**Approach:** Answer the story's four research questions with sources pinned to a version and with measurements from a detached, throwaway probe that puts jj-lib's word marks and the installed `difft` 0.72.0's marks side by side on the same inputs. Write the result as a research report that ends with a recommendation and the options Ralph chooses between, record it in the ledgers, and leave the build (the story's item 2) to Ralph.

## Boundaries & Constraints

**Always:**
- Item 1 only. The report is in German, in the house format of `_bmad-output/planning-artifacts/research/` (Datum / Anlass / Fragen / Methode / Status, then "Kurz"). It answers each question with evidence — a source at a named version, tag or commit, or a probe measurement (command, input, numbers):
  1. Library or program? Including the alternatives diffsitter and an own tree diff over tree-sitter.
  2. Cost on large files, and difftastic's fallbacks `DFT_BYTE_LIMIT`, `DFT_GRAPH_LIMIT`, `DFT_PARSE_ERROR_LIMIT`.
  3. The grammars it needs: Rust, Dart and Markdown first; 5.4's reverted setup.
  4. The mapping onto `HunkLine.segments`: the same wire, structural segments where available, jj's otherwise.
- The probe is a detached crate in `spikes/structural-diff-probe/`: an empty `[workspace]` table, its own `Cargo.lock`, a `.gitignore` for `target/` and generated outputs, and an English README with the method, the rerun commands and the results. It builds offline from crates already in `$CARGO_HOME`'s registry cache: jj-lib `=0.47.0`, serde_json, and for the parse checks tree-sitter `=0.27.1` with tree-sitter-rust `=0.24.2`, tree-sitter-dart `=0.3.0` and tree-sitter-md `=0.5.4`.
- The probe's jj marks come from jj-lib's `unified_diff_hunks` (context 3, `LineCompareMode::Exact`) with the token-to-segment rule of `hunks.rs`'s `hunk_line`, so they equal what the inspector draws. Its difftastic marks come from `DFT_UNSTABLE=yes difft --display json`, mapped onto the same hunk lines by the mapping the report proposes.
- Inputs:
  - the witness cases: Ralph's three stepper.dart examples (from `_DemoDetails`, embedded in one synthetic Dart file), `f(a, b)` → `f(b, a)` in Rust and in Dart, a changed nesting, a moved block and a reformat-only change;
  - real diffs: every `.rs` and `.dart` file modified in the 200 most recent non-merge commits of this repository's `main` that modify one, generated files excluded;
  - inputs that trip each difftastic fallback.
  Each input records wall time for jj and for difft, and peak memory for the fallback inputs.
- The report ends with one recommendation and the options. Each option states: what it marks better or worse on the witness cases, the effort, the new dependencies with their licences (permissive only: MIT, BSD, Apache-2.0, MPL-2.0, Unlicense, CC0), the build and binary-size impact where measured, the fallback behaviour and the risks. "Leave it" (jj's word marks only) is one of the options.
- Ledgers:
  - `epics.md` Story 5.9 gets a dated "Research delivered" note with the summary, the report and probe paths and the options. Its Design status stays open.
  - `sprint-status.yaml` `5-9-…` stays `backlog` with a "RESEARCH DONE 2026-11-12 … BUILD: DECISION PENDING (Ralph)" note (the 10-18 precedent), and the German "Nächster Schritt" lines say the research is done.
  - Every `deferred:` item is mirrored into `deferred-work.md` under `## Surfaced in Story 5.9 (bmad-build-auto, 2026-11-12)` in the dispatch's shape, in the same commit as the spec.
- Absolute paths and `builtin cd` only; jj runs only inside temp dirs this run creates; Plain Language.

**Never:**
- No new dependency in the workspace crates or the Dart packages. No change to product code, the schema, FFI or generated files, the Dart packages or the app. The probe never joins the workspace.
- No build of item 2 and no build decision.
- Nothing under `~/development/projects/Kunden/` is opened, read or run.
- No new download or install: no `cargo install`, no Homebrew, no crate outside the registry cache. A fact that would need one is taken from the source at a named version and marked as not measured.
- No full gate (`cargo make test`, `test-full`, `coverage`).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Witness marks | each witness case, before and after | per changed line, jj's and difft's marks in `[-…-]` / `{+…+}` notation; per case, which marks less | — |
| Real history | the history corpus | per changed line one class: same marks, difft marks fewer bytes, more bytes, different bytes, or difft fell back; counts plus examples | a file difft cannot parse counts as a fallback |
| Byte limit | a side over 1,000,000 bytes | difft's fallback, how its JSON shows it, time and peak memory | recorded, not an error |
| Graph limit | many scattered changes in a large file | same | recorded |
| Parse error | a syntax error; newer Dart syntax the grammar lacks | same, plus tree-sitter-dart 0.3.0's error nodes over this repository's Dart files | recorded |
| Mapping edges | non-ASCII text, a token over several lines (string, comment), a novel span on a jj context line, a line jj changes but difft calls unchanged | the rule each case gets, shown on a probe input | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/hunks.rs:218-277` -- `Hunk` (`lines` with index-aligned `segments`), `Segment` (segments concatenate to the line, none is empty, adjacent ones differ in kind), `SegmentKind` (Equal / Added / Removed), `HunkLine` (Context / Removed / Added, keeps its `\n`): the contract a build keeps.
- `crates/zanshin-jj/src/hunks.rs:587-634` -- `DiffReader::file`: both full sides (`texts`) and the file's language (`SourceLanguage::from_file_name`, `:614-618`) are at hand once per file — where a build would compute structural ranges.
- `crates/zanshin-jj/src/hunks.rs:703-767` -- `hunks_of` / `hunk_line`: jj-lib's tokens become `Segment`s; the probe copies this rule.
- `crates/zanshin-jj/src/source_symbol.rs:137-167` -- the CLI's file-name-to-language table (it has no Dart entry).
- `schemas/envelope.fbs:3174-3198` -- wire `SegmentKind`, `Segment`, `HunkLine.segments`; `packages/zanshin_core/lib/src/ffi/diff.dart:59-72` -- Dart `SegmentKind`, `Segment`.
- `app/lib/src/features/graph/inspector_diff.dart:56-70` -- 10.32's mark rule: a line whose equal segments hold no visible text gets no strong marks.
- `app/widgetbook/folders/graph.dart:1086-1133` -- Ralph's three stepper.dart examples with jj's marks (`_DemoDetails._diffOf`).
- `git show e8e8297f` -- 5.4's reverted grammar setup: tree-sitter and tree-sitter-highlight `=0.27.1`, tree-sitter-rust `=0.24.2`, tree-sitter-dart `=0.3.0`, tree-sitter-md `=0.5.4`, all MIT; `.cargo/config.toml:6` `global-min-publish-age = "7 days"`.
- `_bmad-output/implementation-artifacts/spec-5-3-tree-sitter-highlight-and-grammars.md:154-165,208,224-225` -- measured tree-sitter facts: the release cdylib grew from 29.8 to 33.7 MB with three grammars; tree-sitter 0.27 has no parse timeout; the Dart parser takes 23 s on 131,000 characters of `[`; tree-sitter-md's inline parser overflows a 1 MiB stack at about 48,000 characters (a Dart isolate thread has 1,060,864 bytes).
- `/opt/homebrew/bin/difft` -- difftastic 0.72.0. Rust and Dart are supported, Markdown is not (`--list-languages`). Defaults: `DFT_BYTE_LIMIT` 1,000,000, `DFT_GRAPH_LIMIT` 3,000,000, `DFT_PARSE_ERROR_LIMIT` 0. `--display json` needs `DFT_UNSTABLE=yes` ("its format may change"). First check, `f(a, b)` → `f(b, a)` in Rust: lhs `a` and `,` novel, rhs `,` and `a` novel; 0-based `line_number`, `start` / `end` columns.
- `$CARGO_HOME` (`~/development/sdks/cargo`) registry cache -- jj-lib 0.47.0, serde_json, tree-sitter 0.27.1, tree-sitter-rust 0.24.2, tree-sitter-dart 0.3.0, tree-sitter-md 0.5.4, streaming-iterator.
- `spikes/graph-layout-ab/rust/Cargo.toml`, `spikes/graph-layout-ab/.gitignore` -- the detached-spike pattern; `crates/xtask/src/tasks/gate_plan.rs:151` -- `spikes/` needs nothing in the gate; `Makefile.toml:316-320` -- the hygiene check skips spikes.
- `_bmad-output/planning-artifacts/research/technical-parallel-agents-one-working-copy-research-2026-09-30.md:1-12` -- the report's house format.
- `_bmad-output/planning-artifacts/epics.md:5182-5208` -- Story 5.9; `prd.md:172` -- the PRD non-goal (AST-level diff) a build would lift.
- `_bmad-output/implementation-artifacts/sprint-status.yaml:30-44,66-70,96` -- the header, the 5-2 and 5-9 entries, the 10-18 precedent; `deferred-work.md:2951-2958` -- the last section (append after it).

## Tasks & Acceptance

**Execution:**
- `spikes/structural-diff-probe/` (`Cargo.toml`, `Cargo.lock`, `.gitignore`, `src/`, `inputs/witness/`, `README.md`) -- build the probe: jj marks, difft JSON mapped onto the same hunk lines, side-by-side output and timing, with witness, history, limit and parse-check modes -- the measurements the report cites.
- `_bmad-output/planning-artifacts/research/technical-structural-diff-difftastic-class-research-2026-11-12.md` -- the four answers with evidence, an options table, the recommendation and the open decisions for Ralph -- the story's item 1.
- `_bmad-output/planning-artifacts/epics.md` -- a dated "Research delivered" note under Story 5.9 -- the epic's record.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- the 5-9 note, the header lines, 5-2's stale "no UI renders them yet", `last_updated` -- the ledger Ralph reads.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- the 5.9 section mirroring the spec's `deferred:` items, at least the build decision -- the run rule.

**Acceptance Criteria:**
- Given the report, when Ralph reads it, then each of the four questions has an answer backed by at least one source at a named version or one probe measurement, and the "Kurz" summary names the recommendation.
- Given the probe README, when its commands are rerun with difft 0.72.0 installed and the registry cache present, then they reproduce the report's tables: the witness marks, the history counts and the limit timings.
- Given the witness cases, when the report shows them, then each shows jj's and difft's marks, and the build part's three witnesses (the stepper.dart examples, `f(a, b)` → `f(b, a)`, the fallback cases) say what a difftastic-class build would mark.
- Given the options, when Ralph compares them, then each lists effort, dependencies with licences, build and size impact, fallback behaviour and risks, "leave it" is one of them, and no build decision is taken.
- Given `git status` after the run, when the changed paths are listed, then only the spike, the report, this spec, `epic-5-context.md` and the three ledgers changed — no workspace crate, schema, generated file, Dart package or app file.

## Spec Change Log

## Review Triage Log

### 2026-11-12 — Review pass
- verdicts: 49 findings — high 0, medium 6, low 34, false 9, maybe-false 0 (verification-gap layer: no gaps, 3 other findings)
- findings:
  - `[low]` `patch` (vg) The probe runs whatever `difft` is on PATH, though its labels say 0.72.0 and the JSON is unstable. — `require_difft()` accepts only `Difftastic 0.72.0`; every mode prints the version.
  - `[low]` `patch` (vg) `parse-check` reads the working tree, so after this commit the probe's own files join the 281 / 628 / 420 counts. — New `--rev`: files listed with `git ls-tree -r -z` and read with `git show`; the README command pins `5ba5f5d4`; the rerun reproduces the counts.
  - `[low]` `patch` (vg) The `limits` "jj in-process" column is the last run's time, not the median the note claims. — jj's time and RSS are now the medians of the three runs.
  - `[false]` `reject` (intent) The probe never calls zanshin-jj and nothing compares its jj marks with the product's. — The probe calls the product's function the same way: jj-lib's `unified_diff_hunks`, context 3, `LineCompareMode::Exact`, with `hunk_line`'s token rule (`hunks.rs:703-767` vs `marks.rs` `jj_diff`), and its stepper marks equal the widgetbook's `_words` lines. Client repositories are off-limits by the intent, and the look in the app is Ralph's step per the story. The ASCII-whitespace point is the edge layer's NBSP row.
  - `[medium]` `patch` (intent) "Same marks" counts only non-whitespace bytes, though 10.32 fills whitespace; the headlines carry no qualifier. — Same root cause as the blind whitespace row; same patch.
  - `[false]` `reject` (intent) The mapping's segment invariants (rule 9) are stated but never run. — They are the existing `Segment` contract (`hunks.rs:242-246`), and the probe's `merged()` / `push_range` join touching and overlapping ranges, so a split at merged bounds gives non-empty, alternating segments by construction.
  - `[low]` `patch` (intent) All measurements are `difft`; the alternatives are read, not measured; D2's benefit has no frequency data and C's cost is unmeasured. — §8 now says how often moves occur is not measured (open decision 4) and marks C's in-process cost as not measured; measuring diffsitter would need a download the spec excludes, and its v0.9.0 `Cargo.toml` / README show no Dart or Markdown grammar.
  - `[false]` `reject` (intent) The witnesses become predictions, the stepper lines sit in an invented file, and the "marks the move" witness is unchanged. — The intent says to take the stepper examples from the widgetbook demo, so a synthetic file around those lines is the only way to give `difft` a whole file; rewording the story's witness is Ralph's call, recorded as open decision 5 and in the deferred item.
  - `[low]` `reject` (intent) No clippy run and no tests in the probe. — The gate rule's targeted checks address the product crates; the probe is detached (own `[workspace]`, `gate_plan.rs:151` maps `spikes/` to nothing) and checks its own parser at run time (span-content mismatches and CR shifts, 0 over 2,536 files in every run). A test suite for a throwaway probe is more than a direct correction, and nobody runs the probe in everyday work.
  - `[low]` `patch` (intent) Ledgers: the mirror cites §7–8, "same commit" is unchecked, and changes reach beyond 5.9 (the 5-2 note, a stale `epic-5-context.md`). — Same root cause as the blind epic-context row for the stale part; same patch. The §7–8 citation is a file plus section, which the shape allows; the same-commit rule is met at finalize; the 5-2 fix is a spec task.
  - `[false]` `reject` (intent) Under a "nothing new committed" reading, the probe commits tree-sitter, three grammars, jj-lib and a lockfile. — The intent forbids new dependencies in the product crates and packages and allows a probe under `spikes/`; the probe is its own workspace outside the gate (`gate_plan.rs:151`, `Makefile.toml:316-320`), like the committed spikes `graph-layout-ab` and `ffi-payload-bench` with their own `Cargo.lock`.
  - `[medium]` `patch` (intent) "Falls doch" pre-scopes B1, and §2.1's "whole revision" contradicts its "only the shown file". — Same root cause as the blind inspector row; same patch. The B1 parameters describe an option; budget, limit and opt-in stay Ralph's open decision 2.
  - `[medium]` `patch` (blind) The comparison ignores whitespace, but 10.32 fills it: 3 of 9 stepper lines and 3 of 5 "same" reformat lines are drawn differently, and "3,8 %" undercounts. — Verified against `diffWordMarks` (`inspector_diff.dart:60-75`). `classify_drawn()` compares the filled bytes with whitespace; rerun: drawn differently on 11.2 % of the compared lines (word marks: 4.9 %), in 1,454 files; the stepper witness reads "6 of 9 drawn the same"; report, README, ledgers and the deferred item updated.
  - `[medium]` `patch` (blind) §2.2 says the graph limit applies "after the work is done"; a lower limit was never measured. — Verified: `shortest_vertex_path` (`src/diff/shortest_path.rs` @ 0.72.0) checks `seen.len() > graph_limit` inside the search loop. §2.2 corrected; `limits` adds `--graph-limit 300000` runs (0.93 s / 328 MB and 3.77 s / 199 MB, against 1.56 s / 1,074 MB and 4.11 s / 620 MB at the default); option B names the knob.
  - `[low]` `patch` (blind) The "every word marked" problem is the JSON's, not the diff's; C would get real word marks, B could via an upstream JSON change. — Verified: `is_novel()` includes `UnchangedPartOfNovelItem` (`src/parse/syntax.rs`) and `Highlight::from_match` drops the variant (`src/display/json.rs`). §1, §4 and §7 now say so.
  - `[medium]` `patch` (blind) The inspector does not load a whole revision, so the per-commit sums are not what a user waits for. — Verified: `graph_inspector.dart:281` reads a summary, `:259` one file; the Undo Timeline likewise (`operation_changes.dart:268-275`). Per-file cost is now the user-facing number in the report, the epics note, sprint-status and the deferred item; per-commit sums are a side note.
  - `[low]` `patch` (blind) The corpus scope (status `M` only, one repository, generated files skipped) is unstated, and B should skip files without a parser. — §6 states the scope, the ledgers say it in short, and option B starts `difft` only for languages it parses.
  - `[low]` `patch` (blind) "Up to 1.1 GB" comes from synthetic inputs; real-diff memory is unmeasured. — `history` now measures `difft`'s peak RSS per file: median 20.8 MB, p99 946 MB, max 986 MB, fallback files 870–986 MB; the 1.1 GB is marked synthetic.
  - `[low]` `patch` (blind) The ledgers still say difftastic sees moves, and §6 explains "fewer" with "verschoben". — The Motivation in `epics.md`, the sprint-status 5-9 comment and `epic-5-context.md` are annotated (Ralph's text kept); §6 reworded.
  - `[low]` `patch` (blind) `epic-5-context.md` has a stale title and still lists 5.9's research as open. — It now marks the research done with the facts a build needs. The title is kept: it is the epics file's Epic 5 heading, which the compile format requires, and the Goal says it is historical.
  - `[low]` `patch` (blind) No Dart reformat witness, and the reformat gain is unqualified. — The `stepper` hunk 2 already is a Dart reformat (a call split over three lines with a trailing comma); Kurz and §8 now limit the quiet reformat to Rust and name the Dart commas.
  - `[low]` `patch` (blind) Licences of difft's parsers and difftastic's crates are unchecked, and B2 needs an x86_64 or universal `difft`. — Verified: `rust-toolchain.toml` targets `aarch64-apple-darwin` and `x86_64-apple-darwin`. Both are open decisions 2 and 3 in §8 and in the deferred item.
  - `[medium]` `patch` (blind) The options leave out CLI parity: 5.2's rule, and jj's own `ui.diff-formatter` as B's switch. — §7 has a CLI-parity row; §8, the epics note, sprint-status and the deferred item say any build lifts 5.2's rule; B's opt-in may follow `ui.diff-formatter`.
  - `[low]` `patch` (blind) Option A's risk ignores the existing `-w` / `-b`. — Option A names `DiffOptions.whitespace` / `RepoHandle.diff(whitespace:)` as its mitigation and as D1's baseline.
  - `[low]` `patch` (blind) "200- bis 300-fache" compares a whole process with in-process compute and overstates C. — §8 marks the ratio (now 200–320) as B's process cost and C's in-process cost as not measured.
  - `[low]` `patch` (blind) Conflicted files are missing from the inputs. — `limits` adds a jj `diff`-style and a Git-style conflicted input; both fall back on parse errors, so jj's marks stay (§2.2, §4, §5).
  - `[low]` `patch` (blind) `difft_first_error` ignores the exit status, and Rust has no positive control. — A failed `difft --dump-ts` now returns an error; known-bad Rust and Dart samples are positive controls. Before the fix all 909 `--dump-ts` runs exited 0 with empty stderr (checked), so the old table was right.
  - `[low]` `patch` (blind) The probe never checks `difft --version`. — Same root cause as the vg version row; same patch.
  - `[low]` `patch` (blind) §1 cites an `"äöü"` input the probe does not have. — §1 now cites `edge-non-ascii` and `edge-cr-tab`.
  - `[low]` `patch` (blind) The README's history block was edited by hand, and the full history rerun is unchecked. — All four modes were rerun with the patched code; the README blocks are their stdout verbatim (step-04 verification).
  - `[low]` `patch` (edge) The dropped-mark counters include the fallback files' text-diff spans. — Verified: 207 and 130 of 1,833 and 1,012 came from the 56 fallback files; the counters now skip them (1,626 and 882).
  - `[low]` `patch` (edge) A different `difft` with another JSON shape would read as structural with no marks. — Same root cause as the vg version row; same patch.
  - `[false]` `reject` (edge) Status `created` / `deleted` or language `Binary` would be read as structural with no spans. — The corpus takes only `M` files with no NUL byte in either side; all 2,536 TSV rows have status `changed`, and no witness or limits input is created, deleted or binary.
  - `[low]` `reject` (edge) Neither `difft` nor the probe has a timeout, so a run could hang. — No run hung (the full history takes about 7 minutes); a kill-on-budget needs a reader thread and a kill path, more than a direct correction, for a case the probe's inputs do not contain.
  - `[low]` `reject` (edge) One `difft` failure aborts the history run and loses its rows. — No failure occurred in any full run; resumable rows need restructuring, more than a direct correction.
  - `[false]` `reject` (edge) A quoted path would make `git show` fail and abort the history run. — That is a loud failure, not a wrong result, and the corpus has no such path: both full runs completed.
  - `[false]` `reject` (edge) A mode-only change is listed as `M` and skews the totals. — `difft` would report `unchanged` for it; all 2,536 TSV rows are `changed`, so no mode-only file entered the counts.
  - `[false]` `reject` (edge) `parse-check` silently drops quoted or unreadable files. — The counts 281 / 628 / 420 equal `git ls-files` for `*.rs`, `*.dart`, `*.md` at that state, so none was dropped; files are now read with `git show` at `--rev`.
  - `[low]` `patch` (edge) A failed `difft --dump-ts` reads as "no ERROR node". — Same root cause as the blind `difft_first_error` row; same patch.
  - `[low]` `reject` (edge) A tree-sitter worst case could stall `parse-check`. — The repository's files parse in at most 555 ms; a progress-callback budget adds code for a case the corpus does not contain.
  - `[low]` `patch` (edge) After this commit, `parse-check` counts the probe's own files. — Same root cause as the vg working-tree row; same patch.
  - `[low]` `patch` (edge) `drawn()` uses ASCII whitespace where Dart's `trim()` uses Unicode whitespace. — `drawn()` now decodes the unmarked text and tests `char::is_whitespace`.
  - `[low]` `patch` (edge) The `limits` jj column is the last run, not the median. — Same root cause as the vg median row; same patch.
  - `[low]` `patch` (edge) `limits` never prints span mismatches or CR shifts. — It prints one summary line (0 mismatches, 0 CR shifts).
  - `[low]` `reject` (edge) A missing flag value or a misspelled flag silently runs the defaults. — A typo on a throwaway probe's command line; validation adds code beyond a direct correction, and the README gives the exact commands.
  - `[false]` `reject` (edge) A case directory with mismatched extensions picks the wrong grammar. — All nine committed cases hold exactly one `before.*` and one `after.*` with the same extension.
  - `[low]` `patch` (edge) The recompiled `epic-5-context.md` dropped "Dart has no symbol pattern there". — Restored (`SourceLanguage::from_file_name` has no Dart entry, `source_symbol.rs:137-167`).
  - `[low]` `patch` (edge) The recompiled `epic-5-context.md` dropped 10.32's no-strong-marks exception. — Restored in its UX section (`inspector_diff.dart:58-63`).
  - `[low]` `patch` (edge) Option C lists difftastic's other crates and B2 ships ~60 parsers without a licence check. — Same root cause as the blind licence row; same patch.

## Design Notes

Starting hypothesis for the mapping, which the probe tests and the report confirms or corrects: per file, one structural diff over both full sides gives novel byte ranges per side. A Removed line takes the left side's ranges and an Added line the right side's; the line splits at the range bounds — inside is Removed / Added, outside Equal. Context lines keep one Equal segment, because jj's line hunks stay the CLI's. A Removed or Added line with no novel range becomes all Equal, which 10.32 draws as the faint line fill only. Every fallback (difft missing, a limit, a parse error, an unsupported language, a time budget) keeps jj's segments unchanged. difft's `start` / `end` units (bytes or characters) and its CR stripping must be checked before the columns are trusted.

## Verification

**Commands:**
- `cargo build --release --offline` in `spikes/structural-diff-probe` -- expected: builds with no download.
- the README's probe commands -- expected: print the tables the report cites.
- `cargo fmt --all --check` at the repository root -- expected: clean (no workspace file changed).
- `git -C /Users/ralph.bergmann/development/projects/privat/Zanshin status --porcelain` -- expected: only the paths the last acceptance criterion names.

**Results (story run, 2026-11-12):**
- `cargo build --release --offline` in `spikes/structural-diff-probe` -- builds, no download, no warning. The lock pins the jj crates to the workspace's 0.47.0 (an offline resolve first picked jj-core 0.47.1; `cargo update --offline --precise 0.47.0` moved jj-core, jj-core-proc-macros, jj-default-index, jj-dsl and jj-local-util back).
- `witness`, `history --rev 5ba5f5d43b21d45c24c099092384f9d9610fe009` (about 25 min), `limits`, `parse-check` -- all exit 0; their outputs are in the probe README and back the report. Two history runs gave identical classes and counts; timings moved by a few percent (the README and the report carry the second run). 0 span-content mismatches in every run.
- The starting hypothesis holds with one correction: inside a novel comment or string, jj's marks stand, because difft's JSON lists every word of such an atom (8,801 "more" lines under the first rule, 1,211 under the corrected one). Columns are confirmed as byte offsets of the line without `\r`; a lone `\r` moves spans, which the probe maps back (`edge-cr-tab`). Empty spans end each line of a multi-line atom and are skipped.
- `cargo fmt --all --check` at the repository root -- clean. `cargo fmt` formatted the probe's own files.
- `dart analyze spikes/structural-diff-probe` -- no issues: the probe's `analysis_options.yaml` excludes its Dart fixtures (`inputs/`) and temp copies (`out/`), which are no Dart package.
- `git status --porcelain` -- only `spikes/structural-diff-probe/`, the report, this spec, `epic-5-context.md` (changed before this run) and the three ledgers.
- Not run, as the intent says: `cargo make test`, `test-full`, `coverage`; no jj command ran.
- Environment: the disk was full when the first build started (143 MiB free); the build failed with "No space left on device", then passed once about 2 GB were free again. Nothing outside this run's own files was deleted.

**Results (step-03 verification, 2026-11-12, judged against the diff):**
- `cargo build --release --offline` in the probe -- finished, no download (cargo prints its usual `global-min-publish-age` notice).
- `witness` rerun -- exit 0; every mark line (151) is identical to the README's witness block; 0 content mismatches, 2 CR-shifted spans in `edge-cr-tab`.
- `limits` rerun -- exit 0; the same `language` values, fallbacks and peak memory as the README table, wall times within a few percent.
- `parse-check` rerun -- exit 0; the same counts (0 ERROR nodes; Rust 281, Dart 628, Markdown 420 files) and the same newer-Dart table.
- `history` -- the full run (about 25 min) does not fit one 10-minute foreground call, so it was checked two ways: the full run's `out/history.tsv` sums to the report's numbers (115,515 changed lines; 91,540 / 2,706 / 1,211 / 838 / 19,220 per class; 1,833 and 1,012 dropped marks — 1,626 and 882 since the review fixes, which count files without a fallback only; 0 mismatches), and a rerun with `--commits 20` gives rows identical to the full run's first 280 rows in every column but the two timings.
- `cargo fmt --all --check` at the root and `cargo fmt --check` in the probe -- clean.
- `git status --porcelain` -- only the paths the last acceptance criterion names.
- Matrix audit: every row is covered by a probe mode that ran and passed above — witness marks and mapping edges by `witness`, real history by `history`, byte limit, graph limit and parse errors by `limits`, the grammar's error nodes by `parse-check`.

**Results (review fixes, 2026-11-12; these numbers supersede the ones above where they differ):**
- Probe changes: every mode checks `difft --version` (0.72.0 only) and prints it; the drawn view compares the bytes 10.32 fills, whitespace included, and tests visibility with Unicode whitespace; dropped marks count files without a fallback only; `history` measures difft's peak memory per file (TSV column, median / p90 / p99 / max, the fallback files' range); `limits` takes jj's median time of three runs, prints span mismatches and CR shifts, and adds `--graph-limit 300000` runs, a `--parse-error-limit 10` run and two conflicted inputs (jj's `diff` style and `git` style); `parse-check` reads the files at `--rev` with `git show`, fails on a failed `difft --dump-ts`, and adds two known-bad samples as positive controls; the outputs print headings that paste into the README unchanged.
- `cargo build --release --offline` and `cargo fmt --check` in the probe -- clean; `cargo fmt --all --check` at the root -- clean.
- `witness` -- exit 0; same word marks as before; drawn the same on 6 of 9 stepper lines, 0 of 2 per `f(a, b)` case, 2 of 6 reformat lines.
- `history --rev 5ba5f5d43b21d45c24c099092384f9d9610fe009` -- exit 0; word-mark classes unchanged (91,540 / 2,706 / 1,211 / 838 / 19,220); drawn view 85,483 / 8,586 / 1,123 / 1,103 / 19,220 (11.2 % of the compared lines differ, in 1,454 files); dropped marks 1,626 and 882; difft median 63.4 ms (Dart) and 60.4 ms (Rust) per file, 66 files over 1 s (55 of them fallbacks); peak memory median 20.8 MB, max 986 MB, fallback files 870-986 MB; 0 mismatches.
- `limits` -- exit 0; 0 mismatches, 0 CR shifts; the graph limit at 300,000 falls back after 0.93 s / 328 MB and 3.77 s / 199 MB (3,000,000: 1.56 s / 1,074 MB and 4.11 s / 620 MB); both conflicted inputs fall back on parse errors.
- `parse-check --rev 5ba5f5d43b21d45c24c099092384f9d9610fe009` -- exit 0; 281 / 628 / 420 files, 0 ERROR nodes; both positive controls report errors in both grammar sets.
- The README's four result blocks equal the four outputs (`diff` against `out/*.md`: no difference).
- `dart analyze spikes/structural-diff-probe` -- no issues.

**Results (step-04 verification after the review fixes, 2026-11-12, judged against the diff):**
- `cargo build --release --offline` in the probe -- finished, no download.
- `witness` rerun -- exit 0; identical to the README's witness block except the per-case timing lines (both views, all 10 cases).
- `limits` rerun -- exit 0; every non-table line identical to the README block; the table's input, bytes, arguments, `language` and jj changed-line columns identical; times and memory within a few percent.
- `parse-check --rev 5ba5f5d43b21d45c24c099092384f9d9610fe009` rerun -- exit 0; identical to the README block except the three parse-time cells (281 / 628 / 420 files, 0 ERROR nodes, positive controls, newer-Dart table).
- `history` -- a foreground call is moved to the background after 180 s, so the full run (about 7 minutes on an idle machine, 10:16–10:23) was checked like this: the README's history block equals `out/history.md` of that run byte for byte; `out/history.tsv` sums to the reported numbers (115,515 changed lines; 91,540 / 2,706 / 1,211 / 838 / 19,220; dropped 1,626 and 882; 0 mismatches; max peak RSS 986,005,504 bytes; all 2,536 statuses `changed`); and a rerun with `--commits 20` gives rows identical to the full run's first 280 rows in every column but the two timings and the peak memory.
- `cargo fmt --all --check` at the root and `cargo fmt --check` in the probe -- clean. `dart analyze spikes/structural-diff-probe` -- no issues.
- `git status --porcelain` -- only the paths the last acceptance criterion names.
- Outside facts spot-checked against the sources: difftastic 0.72.0 `Cargo.toml` (no `[lib]`, tree-sitter 0.26.10, the two orchard grammars, jemalloc, MIT), `CHANGELOG.md` (0.69 trailing punctuation, 0.72 removed Verilog and F# for size, release months), `README.md` (order always matters; vendored parsers MIT or Apache), `src/diff/shortest_path.rs`, `src/display/json.rs`, `src/parse/syntax.rs`; issue #12 (closed 2021-07-18), PR #231 (open since 2022-04-03); diffsitter v0.9.0 `Cargo.toml` and README (no Dart or Markdown); crates.io for `mergiraf` 0.20.0 (GPL-3.0-only), `difftastic-lib` 0.0.2 (MIT, 2023-02-17), `baz-difftastic` 0.53.4 (GPL-2.0); `difft` is 90,371,936 bytes; jj-core 0.47.0 `src/diff.rs:165,620`. Two corrections applied: the report's appendix attributed "program only" to the README (it comes from `Cargo.toml`), and the probe README said `history` takes 25 minutes (about 7 on an idle machine).
- Matrix audit: every row is covered by a probe mode that ran and passed above — witness marks and mapping edges by `witness`, real history by `history`, byte limit, graph limit and parse errors (now also conflict markers and lowered limits) by `limits`, the grammar's error nodes by `parse-check`.

## Auto Run Result

Status: done.

**Summary.** Story 5.9's item 1, the research, is delivered; the build (item 2) stays Ralph's decision. The report answers the four questions with sources pinned to a version and with measurements from a detached probe that puts jj-lib 0.47.0's word marks and `difft` 0.72.0's JSON marks on the same hunk lines:
- **Library or program:** a program only. difftastic 0.72.0 has no `[lib]` (PR #231 open since 2022), its JSON needs `DFT_UNSTABLE=yes` and may change, and the JSON drops difftastic's own word marks inside comments and strings. diffsitter 0.9.0 has no Dart or Markdown grammar; mergiraf is GPL-3.0-only.
- **Cost and fallbacks:** per file (what a user waits for) a median of 60–63 ms for `difft` as a process against 0.2–0.3 ms for jj; 66 of 2,536 files over 1 s; peak memory median 20.8 MB, at most 986 MB. The graph limit stops the search once it has seen more vertices than the limit, so a lower limit falls back sooner; `difft` has no timeout.
- **Grammars:** `difft` bundles its own (90 MB arm64; Rust and Dart, no Markdown; its Dart grammar lacks primary constructors). 5.4's grammars parse every `.rs`, `.dart` and `.md` file at `5ba5f5d4` without an ERROR node.
- **Mapping:** the same wire; a removed or added line takes difft's spans on its line, with jj's marks inside comments and strings; every fallback (limits, parse errors, no parser, conflict markers) keeps jj's segments.
- **Witnesses and real diffs:** the stepper.dart examples and `f(a, b)` → `f(b, a)` get the same word marks (difftastic detects no moves; jj also fills new indentation). On the modified `.rs` / `.dart` files of the last 200 commits, `difft` falls back on 16.6 % of the changed lines and would draw different strong marks on 11.2 % of the rest (different word marks: 4.9 %).
- **Recommendation:** A, leave it (jj's word marks = the CLI's). Options B (`difft` as an opt-in program), C (fork as a library), D (own diff over tree-sitter); any build lifts 5.2's rule. Deferred to Ralph in the spec's `deferred:` list and in deferred-work.md "Surfaced in Story 5.9".

**Files changed.**
- `spikes/structural-diff-probe/` -- the detached probe: `Cargo.toml` / `Cargo.lock` (own workspace, offline crates), `.gitignore`, `analysis_options.yaml` (keeps the Dart analyzer off the fixtures), `src/` (`main`, `marks`, `witness`, `history`, `limits`, `parse_check`), nine witness cases in `inputs/witness/`, `README.md` (method, rerun commands, the four outputs verbatim).
- `_bmad-output/planning-artifacts/research/technical-structural-diff-difftastic-class-research-2026-11-12.md` -- the report (German, house format).
- `_bmad-output/planning-artifacts/epics.md` -- Story 5.9: the Motivation's move claim annotated, a dated "Research delivered" note.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- 5-9 stays `backlog` with "RESEARCH DONE … BUILD: DECISION PENDING (Ralph)", the move claim annotated, the "Nächster Schritt" lines, 5-2's stale "no UI renders them yet".
- `_bmad-output/implementation-artifacts/deferred-work.md` -- "Surfaced in Story 5.9" with the build decision.
- `_bmad-output/implementation-artifacts/epic-5-context.md` -- recompiled in step-01 (epics.md was newer); in review: research done with the facts a build needs, two dropped caveats restored.
- `_bmad-output/implementation-artifacts/spec-5-9-structural-diff-difftastic-class-research.md` -- this spec.

**Review.** 49 findings: 0 high, 6 medium, 34 low, 9 false, 0 maybe-false (the verification-gap layer found no gaps).
- Patched, 4 medium entries: whitespace fills now counted in the drawn view (11.2 % instead of 3.8 %); the graph limit's mechanism corrected and a lowered limit measured; per-file cost as the user-facing number (the inspector and the Undo Timeline read one file at a time); a CLI-parity row and 5.2's rule in the options.
- Patched, 21 low entries: the JSON's lost word marks; corpus scope; real-diff memory measured; the move claims annotated; `epic-5-context.md` updated and its two caveats restored; the Dart reformat qualifier; licences and the x86_64 `difft` as open points; `-w` / `-b` as A's mitigation; the cost ratio for C; two conflicted inputs; `--dump-ts` failures and positive controls; the `difft --version` gate; the `edge-non-ascii` citation; README blocks regenerated verbatim; `parse-check --rev`; median jj times in `limits`; dropped marks without fallback files; Unicode whitespace in `drawn()`; mismatch lines in `limits`; move frequency named as unmeasured.
- Deferred: none in this pass (the build decision was deferred in step 3).
- Rejected: the probe's jj marks never compared with the product's (false: same function, options and token rule); segment invariants never run (false: the `Segment` contract, met by `merged()` by construction); witnesses as predictions in an invented file (false: the intent's own source; the witness change is Ralph's open decision 5); dependencies committed in the spike (false: the intent allows a probe under `spikes/`, outside the gate); `created` / `deleted` / `Binary` statuses, quoted paths, mode-only changes, dropped parse-check files and mismatched case extensions (false: none occurs in the recorded inputs, checked against the TSV, `git ls-files` and the nine cases); no clippy or tests in the probe, no `difft` timeout, no resume after a failure, no tree-sitter time budget in `parse-check`, no flag validation (low: never met in the recorded runs, and each fix adds more than a direct correction to a throwaway probe).

**Follow-up review recommended: true.** Four medium entries were patched on a first pass (patched: 0 high, 4 medium, 21 low). The unverified risk: the drawn-view numbers (11.2 %, 1,454 files) and the real-diff memory figures rest on probe code added in this review (`classify_drawn`, the Unicode visibility test in `drawn()`, per-file `/usr/bin/time -l` in `history`), which is checked only by rerun consistency, not by a reviewer.

**Verification.** See the verification notes above: the offline build, reruns of `witness`, `limits` and `parse-check` against the README, the full `history` output against the README and its TSV sums plus a 20-commit rerun, `cargo fmt` at the root and in the probe, `dart analyze` on the spike folder, `git status`, and spot checks of the outside facts. Not run, by the gate rule: `cargo make test`, `test-full`, `coverage`; no product crate or Dart package changed, so no targeted crate test applies.

**Residual risks.**
- The corpus is this repository only (Ralph's client repositories are off-limits); timings and memory are this M4 Pro's, with `difft` 0.72.0 (version-gated).
- The licences of the parsers bundled in `difft` and of difftastic's other crates are unchecked (open decision 3 in the report).
- The disk ran full once during the run (143 MiB free); the probe's `target/` (about 470 MB) is cleaned after the commit, and `cargo build --release --offline` rebuilds it.
