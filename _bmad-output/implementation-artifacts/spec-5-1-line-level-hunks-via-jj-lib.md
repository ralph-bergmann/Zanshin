---
title: 'Story 5.1 — Line-level hunks via jj-lib (Repo::compute_hunks)'
type: 'feature'
created: '2026-10-27'
status: 'done'
baseline_revision: 'f04191e6bddd4ab9f197380c2ad3a89f6cc80e71'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      ShowEntry::parent_tree_labels / tree_labels are Rust-only; the FFI ShowView does not carry them.
    evidence: |-
      crates/zanshin-ffi/src/commit_views.rs ignores the two new fields; a Dart caller can name a conflicted
      merged parent tree only by ids, so its markers would be unlabeled. Story 5.8 (diff FFI wrapper) adds
      them to schemas/envelope.fbs' ShowEntry together with the diff payload. Mirrored into deferred-work.md
      ("Surfaced in Story 5.1").
    location: >-
      crates/zanshin-ffi/src/commit_views.rs
    severity: medium
    resolved: >-
      2026-11-01 — fixed (spec-5-8-ffi-wrapper-zanshin-ffi-src-diff-rs, commit b96036d): the wire and the Dart `ShowEntry` carry `parent_tree_labels` / `tree_labels`, checked against `Repo::show` on a conflicted merge.
  - summary: >-
      The repo ships Apache-2.0 code (the source_symbol port) without the Apache-2.0 licence text, and the manifests still say license = "MIT".
    evidence: |-
      crates/zanshin-jj/src/source_symbol.rs is SPDX "MIT AND Apache-2.0", but the root has only an MIT LICENSE
      and Cargo.toml:19 sets license = "MIT" (zanshin-jj inherits it). Apache-2.0 4(a) asks for a copy of the
      licence with redistributions; the linked jj-lib / jj-cli dependencies raise the same question for a shipped
      binary, so it is a project-wide notice decision for Ralph. Mirrored into deferred-work.md ("Surfaced in the
      follow-up review of Story 5.1").
    location: >-
      crates/zanshin-jj/src/source_symbol.rs:1, Cargo.toml:19, LICENSE
    severity: medium
---

<intent-contract>

## Intent

**Problem:** Nothing reads a file diff as hunks yet. The inspector (10.24/10.26) needs the CLI's `jj diff --git` hunks, and `select_tree` (9.50) needs the section keys a selection names. Today the tests hard-code those keys (deferred I1). No read gives a conflicted side's materialized text or the mode toggle either, and a merge's parent tree belongs to no revision (I2).

**Approach:** Add `Repo::compute_hunks` in `zanshin-jj`. It takes two trees (ids plus labels) and returns, per changed path, the CLI's unified hunks. Each hunk carries jj-lib's `unified_diff_hunks` lines and ranges, counts, the ported source symbol and the builtin-editor sections it contains (`select_tree::sections`, the one place keys are cut). Each file also gets its sections, a binary flag and a mode-toggle flag. `ShowEntry` reports both trees' labels so a caller can name a merged parent tree completely.

## Boundaries & Constraints

**Always:**
- The code lives in `zanshin-jj`, the only crate that imports jj-lib. `crates/zanshin-diff` stays a skeleton (5.2–5.4 later); the AC's `crates/zanshin-diff/src/hunks.rs` is reconciled to `crates/zanshin-jj/src/hunks.rs`.
- Hunks are jj-lib's `diff_presentation::unified::unified_diff_hunks`, the function the CLI's `show_git_diff` calls (`cli/src/diff_util.rs:1767-1972` @ v0.46.0). Sides are read with jj-lib's `git_diff_part`. The binary rule is the CLI's: either side has a NUL byte in its first 8000 bytes, so the file is marked binary and gets no hunks. Equal contents, such as a mode-only change, get no hunks. `AccessDenied` on a side is an error, as in the CLI.
- Sections and keys come from `select_tree::sections` over the same texts. A file has sections only when both sides are file-like (a regular file or a file conflict) and text (UTF-8, no NUL), which is `select_tree`'s rule. `mode_change` = both sides file-like with different executable bits. The keys a read returns are therefore exactly the keys `select_tree` accepts.
- A hunk's `sections` are the file's sections that one of its Removed lines falls in (old side) or one of its Added lines falls in (new side). At `Exact` that is exactly the sections the hunk shows.
- Parameters pass through: `context: Option<usize>` (`None` = the effective `diff.git.context`, which is 3 in jj-cli's defaults) and `whitespace` (Exact / `-w` IgnoreAllSpace / `-b` IgnoreSpaceChange). Config resolves for the CLI command `diff` (a new `cli_command::DIFF`), via `with_verb`, like every read. `ui.conflict-marker-style` is honoured.
- The source symbol is a verbatim port of `cli/src/source_symbol.rs` (all languages; none for Dart) plus `trim_source_symbol` (80 bytes) and the CLI's preference: the new side unless the hunk has no added lines. The language comes from the right path's file name. The port names jj's copyright and the Apache-2.0 origin in its module doc. Regex init must not panic (`LazyLock<Option<Regex>>`).
- A line's text is its bytes including `\n`, decoded `from_utf8_lossy`. A last line without `\n` keeps that state.

**Never:** No copy/rename records, path filesets, unmatched-paths warning, file kinds, summary mode or (operation, commit) pinning (all Story 5.6). No FlatBuffers schema, FFI or Dart (5.5/5.8). No word-level segments or highlighting (5.2–5.4). No shelling to `jj`. No new error codes: errors are `MutateError` (InvalidInput, Backend, Config, Precondition), as for `select_tree`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Three sections, context 3 | `f.txt` `a b c d e` → `A b C d E` | 1 hunk `0..5`/`0..5`, sections [S1,S2,S3], removed 3, added 3; file sections [S1,S2,S3] | — |
| Same, context 0 | as above | 3 hunks, one section each; the file's sections are unchanged | — |
| Added / removed file | `new.txt` absent→`n\n`; `gone.txt` `g\n`→absent | `0..0`/`0..1` all Added; `0..1`/`0..0` all Removed; no sections, mode_change false | — |
| Mode-only change | `mode.sh` 644→755, same text | no hunks, mode_change true, no sections | — |
| Binary | `bin.dat` `x\0y`→`x\0z` | binary true, no hunks | — |
| No EOF newline | `a\nb` → `a\nc` | last Removed `b`, Added `c`, no `\n` in either | — |
| from == to | the same tree twice | `Ok(vec![])` | — |
| Conflicted merge parent | `@` = merge of X/Y (conflicted `c.txt`), resolved in `@` | sections over the materialized markers; feeding them to `select_tree(@, left = parent tree)` gives `@`'s `c.txt` | — |
| Rust / Dart symbol | change inside `fn main() {` in `lib.rs`; same text in `main.dart` | `Some("fn main() {")`; `None` | — |
| Bad tree | even id count / non-hex / unknown id | — | InvalidInput / InvalidInput / Backend |
| Bad config | `diff.git.context = "x"` | — | Config |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/select_tree.rs` -- `sections` (l.581) is the single key cutter, `is_text` (l.555) the text test, `HunkKey`, `SelectedTreeId` (ids + labels). Make `is_text` `pub(crate)`.
- `crates/zanshin-jj/src/op_support.rs:576` -- `SelectedTree::from_tree_id(store, &SelectedTreeId)` parses ids and labels, verifies each tree exists, and builds the `MergedTree`. Reuse it for both sides.
- `crates/zanshin-jj/src/file.rs:386-432` -- `conflict_text` / `materialize_file_like`. `git_diff_part` produces the same conflict text (`materialize_merge_result_to_bytes`, same options), so the file-like and executable facts can be read from the `MaterializedTreeValue` before `git_diff_part` takes it.
- jj-lib 0.46 `~/.cargo/registry/src/*/jj-lib-0.46.0/src/diff_presentation/{mod,unified}.rs` -- `LineCompareMode`, `unified_diff_hunks(Diff<&BStr>, context, mode)`, `UnifiedDiffHunk { left_line_range, right_line_range, lines: Vec<(DiffLineType, tokens)> }`, `git_diff_part`. `jj_lib::conflicts::materialize_tree_value(store, path, value, labels)`.
- `../jj` v0.46.0 `cli/src/diff_util.rs:1767-1861` (hunk loop, symbol choice, trim), `:1876-1972` (`show_git_diff`) and `cli/src/source_symbol.rs` (port, with its test table).
- `crates/zanshin-jj/src/select_tree.rs:306-335` -- the model for materialize options (`conflict_marker_style`, `marker_len: None`, `store.merge_options()`).
- `crates/zanshin-jj/src/repo.rs:579` `with_verb`; `:2522` `show` (method pattern); `:5294` `every_verb_resolves_for_its_cli_command` (add a `DIFF` line).
- `crates/zanshin-jj/src/cli_command.rs:37` -- the table; add `DIFF = "diff";` before `DIFFEDIT` (the audit test walks clap).
- `crates/zanshin-jj/src/commit_views.rs:102-117,494-503` -- `ShowEntry` gets `parent_tree_labels` and `tree_labels` (empty = unlabeled), filled from the same trees.
- `crates/zanshin-ffi/src/commit_views.rs:~607` -- a test builds `ShowEntry` literally; add the two fields there (the wire is unchanged).
- `crates/zanshin-jj/tests/it/select_tree.rs` -- fixture helpers to mirror (`base()`, `conflicted_merge`, `add_repo_config`, `write`, `set_executable`). New tests go in `tests/it/hunks.rs`, declared in `tests/it/main.rs`.
- `crates/zanshin-jj/Cargo.toml` -- `regex` is already a dependency; extend its `# WHY:` comment.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/source_symbol.rs` -- new: port `SourceLanguage`, `is_source_symbol`, `source_symbol_from_line`, `SourceSymbolScanner`, plus `trim_source_symbol` from `diff_util.rs`. Use std `&[u8]` helpers instead of `bstr`. Inline tests port the CLI's tests (the pattern table as plain asserts, the scanner cases, the trim cases).
- `crates/zanshin-jj/src/hunks.rs` -- new: `HunksOptions { from: SelectedTreeId, to: SelectedTreeId, context: Option<usize>, whitespace: Whitespace }`, `Whitespace`, `FileDiff { path, binary, mode_change, sections, hunks }`, `Hunk { before_range: Range<u32>, after_range: Range<u32>, symbol: Option<String>, sections: Vec<HunkKey>, removed: u32, added: u32, lines: Vec<HunkLine> }` and `enum HunkLine { Context(String), Removed(String), Added(String) }`. `pub(crate) fn compute_hunks(store, config, options)` streams `from.diff_stream(to, &EverythingMatcher)` in jj-lib's order. Inline unit tests cover the pure parts: the hunk-to-sections match, counts, the symbol choice and the EOF line text.
- `crates/zanshin-jj/src/select_tree.rs` -- `is_text` → `pub(crate)`; update the module doc to say the diff read is the other user of `sections`.
- `crates/zanshin-jj/src/cli_command.rs` -- add `DIFF`.
- `crates/zanshin-jj/src/repo.rs` -- `pub fn compute_hunks(&mut self, options: &crate::HunksOptions) -> Result<Vec<crate::FileDiff>, crate::MutateError>` via `with_verb(cli_command::DIFF, …)`, with a doc that lists its errors; add the `records!` line.
- `crates/zanshin-jj/src/lib.rs` -- `mod hunks; mod source_symbol;`, re-export `FileDiff, Hunk, HunkLine, HunksOptions, Whitespace`.
- `crates/zanshin-jj/src/commit_views.rs` + `crates/zanshin-ffi/src/commit_views.rs` -- the `ShowEntry` labels (Rust only; the wire waits for 5.8 → deferred).
- `crates/zanshin-jj/tests/it/hunks.rs` + `tests/it/main.rs` -- integration tests for every matrix row against a real repo, including the conflicted-merge round trip through `select_tree` and the `-w` whitespace case (a whitespace-only change shows no hunk at `-w` but a section at the file level).

**Acceptance Criteria:**
- Given `show(@)`'s `parent_tree_ids` + `parent_tree_labels` and `tree_ids` + `tree_labels`, when `compute_hunks` runs and every file's `sections` are passed to `select_tree` as `Hunks`, then the selected tree's files equal `@`'s for every sectioned file. The keys round-trip (I1/I2).
- Given any result, then every hunk's `removed`/`added` equal its Removed/Added line counts, and `before_range.len()` / `after_range.len()` equal its Context+Removed / Context+Added counts.
- Given the call, then it records `cli_command::DIFF` and writes no operation beyond the pre-verb snapshot's.

## Spec Change Log

## Review Triage Log

### 2026-10-27 — Review pass
- verdicts: 27 findings — high 0, medium 6, low 12, false 9, maybe-false 0
- findings:
  - `[false]` `reject` (blind) Renames/copies are lost and `FileDiff` has no kind. — Copy records, `renamed`/`copied` kinds and `from_path` are Story 5.6's scope (epics.md Story 5.6 design note; sprint-status 5-6); the 5.1 intent asks for neither.
  - `[false]` `reject` (blind) There is no path/fileset argument. — Filesets plus the unmatched-paths warning are Story 5.6's (epics.md 5.6 note); 5.1's pass-through list is context and `-w`/`-b`.
  - `[false]` `reject` (blind) Word-level tokens are thrown away. — Word-level diff is Story 5.2 (decision (g): line-level first); 5.1 is line-level.
  - `[low]` `patch` (blind) The compute_hunks doc overstates the round-trip: it depends on the same trees/labels and the same per-command marker style. — Doc now states the conditions (same trees + `show`'s labels, same effective `ui.conflict-marker-style`).
  - `[low]` `patch` (blind) At `-w`/`-b` a file can keep sections no hunk shows, and this is undocumented. — Documented on `FileDiff::sections` and `Hunk::sections`.
  - `[low]` `patch` (blind) `HunkLine::Context` claims "both sides" but carries the right text. — Doc corrected (the right side's text, which can differ at `-w`/`-b`).
  - `[low]` `reject` (blind) Lossy UTF-8 decoding has no indicator. — A non-UTF-8 file already reports no sections (whole-only), so the GUI can tell it is not hunk-selectable; a separate flag adds surface for a rare case.
  - `[medium]` `patch` (blind) Integration tests are missing for several rows. — Added: the marker-style loop, a `show-path-prefix` case and a mode-only `ModeAndHunks` round trip. Rejected: symlink and access-denied, which are jj-lib's `git_diff_part` arms taken over unchanged (access denied needs the dev-only `SecretBackend`), and a right-side conflict, which the conflict round trip's materialization path already exercises.
  - `[medium]` `patch` (blind) The SPDX line says MIT on a verbatim Apache-2.0 port. — Now `MIT AND Apache-2.0`; the module doc keeps jj's copyright and the license URL.
  - `[low]` `patch` (blind) The added count is computed twice. — Counted once; `added > 0` drives the symbol choice.
  - `[low]` `patch` (blind) The private struct `Read` reads like `std::io::Read`. — Renamed `DiffReader`.
  - `[medium]` `patch` (verification-gap) A configured `diff.git.context` is never shown to take effect. — Test added: `diff.git.context = 0` with `context: None` gives one hunk per section.
  - `[medium]` `patch` (verification-gap) The public `Whitespace` mapping can't tell `-w` from `-b`. — Test added through `compute_hunks`: `a b` → `ab` has a hunk at `-b` and none at `-w`.
  - `[medium]` `patch` (verification-gap) The marker style reaching compute_hunks is unverified. — The conflicted-merge round trip now runs under the default and the `git` style.
  - `[medium]` `patch` (verification-gap) The merge parent's labels never show in the hunk text. — The test asserts a parent label in a Removed marker line.
  - `[low]` `patch` (verification-gap) The `diff.git.show-path-prefix` read is untested. — Second case added to the malformed-config test.
  - `[false]` `reject` (verification-gap, other) "Labels don't affect keys, so the doc's reason is wrong." — When both sides carry markers, the label text decides which marker lines match, so it changes the sections; the ShowEntry doc's reason stands. The deferred-work wording now names both effects (printed text and keys).
  - `[false]` `reject` (intent) I1/I2 are not closed at the Dart/GUI surface. — Stories 5.5 (schema) and 5.8 (FFI wrapper) already own the wire; the item outcomes record "partly done", and the one new wire gap (labels) is deferred.
  - `[low]` `patch` (intent) The keys depend on the labels the caller passes, and only "empty = unlabeled" says so. — Folded into the compute_hunks doc patch (the labels must be the ones `show` reports).
  - `[false]` `reject` (intent) The read does not yield the whole materialized conflict text (R5). — I2's own follow-up asks for sections plus a mode flag; the hunk lines carry the materialized text of every changed region.
  - `[false]` `reject` (intent) No test runs the stock CLI. — The hunks are jj-lib's `unified_diff_hunks` / `git_diff_part`, the functions the CLI's `show_git_diff` calls; the symbol port is verbatim and checked against the CLI's own test table. The parity oracle compares repo state, not diff text (project-context § zanshin-jj).
  - `[low]` `patch` (intent) The R1 structural ACs are reconciled only in the spec, and the 1000-line AC has no test. — epics.md Story 5.1 gains a reconciliation note; a 1000-line unit test was added.
  - `[false]` `reject` (intent) Access denied fails the whole call. — That is the CLI's behavior (`git_diff_part` → `UnifiedDiffError::AccessDenied`, `jj diff --git` aborts).
  - `[false]` `reject` (intent) There is no `## Auto Run Result` yet. — It is written in step-04 Finalize, as in every run.
  - `[low]` `patch` (edge-case) The marker style is resolved per command, so `--when.commands` can make the keys differ. — Same root cause as the blind finding; same doc patch. The CLI itself shows `jj diff` and the builtin editor under their own commands' config.
  - `[low]` `patch` (edge-case) `diff_git_context` reads the two keys in the reverse of the CLI's order. — Now `diff.git.context` first, then `show-path-prefix`.
  - `[low]` `reject` (edge-case) At `-w`, a hunk with changed lines can list no section. — It only happens when the `-w` alignment pairs lines that the exact diff matched. The GUI can switch to Exact to select by hunk. The fallback branch would add complexity, and the case is now documented on `Hunk::sections`.

### 2026-10-27 — Review pass
- verdicts: 28 findings — high 0, medium 6, low 9, false 13, maybe-false 0
- findings:
  - `[false]` `reject` (blind) `FileDiff` has no kind or modes, so empty add/delete, file↔symlink and submodule changes look alike. — The intent's Never clause gives file kinds to Story 5.6; carried with the first pass's "no kind" row. The path is still listed, so the change is not lost.
  - `[false]` `reject` (blind) Renames/copies are not tracked. — carried: Story 5.6's scope (first pass, same claim).
  - `[medium]` `patch` (blind) `binary` is set even when the contents are equal, unlike `show_git_diff`, which skips equal contents first. — Verified at `cli/src/diff_util.rs` @ v0.46.0 (`if left == right { continue }` before the binary check). Fixed in `hunks.rs` (`binary = contents differ && either side binary`, docs updated); new test `a_mode_only_change_of_a_binary_file_is_not_binary` (`binmode.dat` 644→755).
  - `[false]` `reject` (blind) Lossy decoding without an indicator; non-UTF-8 files get hunks but no sections. — carried: first pass's lossy-UTF-8 row (no sections already marks whole-only).
  - `[low]` `reject` (blind) At `-w`/`-b`, `Context` keeps only the right side's text, which a side-by-side view would need. — It is jj-lib's `unified_diff_hunks` output, which the CLI prints the same way; the doc says so. Carrying both texts adds surface for a non-default mode; 10.24 can ask again at Exact.
  - `[false]` `reject` (blind) `Hunk` has no key of its own. — A hunk is identified by its file's `path` plus `before_range`/`after_range`, unique within one result; that is the "path + ranges" key sprint-status names.
  - `[false]` `reject` (blind) No test compares against the real CLI. — carried: first pass's stock-CLI row.
  - `[low]` `patch` (blind) The documented `InvalidInput` for a zero id count and a mismatched label count is untested in `compute_hunks`. — `bad_trees_are_refused` now asserts both.
  - `[medium]` `patch` (blind) No conflicted right side (both sides carry markers). — Grouped with the verification-gap finding below; same test.
  - `[low]` `patch` (blind) A mode change together with a content change (`ModeAndHunks` with sections) is never round-tripped. — `both.sh` (`m`→`n`, 644→755) added to the fixture and to the mode round trip.
  - `[false]` `reject` (blind) Symlink sides are untested. — carried: first pass rejected symlinks as jj-lib's `git_diff_part` arm taken over unchanged.
  - `[low]` `patch` (blind) The `git`-style conflict round trip skips the label assertion. — The guard is removed; the left-label assertion now runs in both styles and passes.
  - `[low]` `reject` (blind) `hunk_sections` is quadratic. — The work is sections × changed lines of one file; a 5k-line file with hundreds of sections is still well under a million comparisons. Not worth a two-pointer rewrite.
  - `[medium]` `defer` (blind) Apache-2.0 code ships without the licence text, and the crate metadata says MIT. — Real for redistribution, but the same holds for the linked jj-lib/jj-cli Apache dependencies, so it is a project-wide notice decision. The "2020-2026" year is right (it covers `diff_util.rs`'s `trim_source_symbol` too). Deferred and mirrored into deferred-work.md.
  - `[low]` `reject` (blind) deferred-work.md records only the labels-on-the-wire gap. — The other items are Story 5.6's scope or were rejected with reasons; deferred-work mirrors deferrals, not rejections.
  - `[low]` `reject` (blind) sprint-status 5-1 still carries the old "NEEDS DESIGN" text. — It is history in the sibling style (DONE summary first, design notes after); cosmetic.
  - `[low]` `reject` (blind) The epics.md reconciliation note omits the inline unit tests and the 5.6 fields. — Cosmetic; the note's purpose (the crate location) is met, and 5.6 owns its fields in its own story text.
  - `[medium]` `patch` (edge-case) Mode-only change on a binary file is reported binary. — Same root cause as the blind binary finding; same fix and test.
  - `[false]` `reject` (edge-case) A symlink/file swap, submodule or other-conflict change with equal text has no flag and is invisible. — File kinds are Story 5.6 by the intent's Never clause; the path is still listed.
  - `[medium]` `patch` (verification-gap) A conflicted right side (`ShowEntry::tree_labels` into `compute_hunks`) has no witness. — New test `a_conflicted_revision_round_trips_through_select_tree`: the X/Y merge kept conflicted in `@` with a line above the markers; asserts `@`'s tree has 3 ids and 3 labels, a right-side line names one of them, and the keys round-trip through `select_tree`, in the default and the `git` marker style.
  - `[false]` `reject` (intent) No test compares with stock `jj diff --git` output. — carried: first pass's stock-CLI row.
  - `[false]` `reject` (intent) The problem's GUI consumers (I1, inspector) cannot reach the read. — carried: first pass's GUI-surface row (5.5/5.8).
  - `[false]` `reject` (intent) Per-key / subset acceptance is not exercised. — The keys are cut by the same `select_tree::sections` over the same texts, and `select_tree` accepts any subset of its keys by its own contract (9.50 tests); the full-set round trip proves the two cuts agree.
  - `[medium]` `patch` (intent) Binary is reported on a mode-only change of a binary file. — Same root cause as the blind binary finding; same fix.
  - `[false]` `reject` (intent) `AccessDenied` on a side is untested. — carried: first pass (dev-only `SecretBackend`, jj-lib's arm unchanged).
  - `[low]` `patch` (intent) The label-in-markers assertion runs only for the default style. — Same as the blind `git`-style finding; same fix.
  - `[false]` `reject` (intent) The missing-EOF-newline case is tested only with text files. — Binary files get no hunks, so there is no line text to keep; the rule only applies to text.
  - `[false]` `reject` (intent) The `-w`/`-b` section behavior is only partly tested. — `ignoring_whitespace_drops_the_hunk_but_keeps_the_section` covers the documented case; the empty-section hunk was rejected in the first pass.

## Design Notes

Hunk-to-section matching: walk the hunk's lines with `l = before_range.start` and `r = after_range.start`. Context advances both, Removed records `l` and then advances it, Added records `r` and then advances it. A section is listed when a recorded `l` lies in `old_start..old_start+old_count` or a recorded `r` lies in `new_start..new_start+new_count`. At `-w` a hunk may then list a whole exact section of which it shows only part. That is deliberate: a selection always takes whole sections (9.50).

`ShowEntry` labels: jj-lib labels a merged parent tree per commit (`merge_commit_trees_no_resolve_without_repo`, `conflict_label()`). Those labels sit inside the conflict markers, so without them a caller cannot reproduce the text `select_tree` keys.

## Verification

**Verification notes (run on 2026-10-27; full gate deferred to the story loop by its gate rule):**
- `cargo test -p zanshin-jj --lib -- hunks:: source_symbol:: select_tree:: cli_command:: every_verb config::` -- 117 passed.
- `cargo test -p zanshin-jj --test it -- hunks:: select_tree:: commit_views:: api_stability::` -- 114 passed.
- `cargo test -p zanshin-ffi --lib commit_views` -- 6 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` -- clean.
- `cargo fmt --all --check` -- clean.
- Not run: `cargo make codegen` (no FFI or schema change), the parity oracle (no jj verb changed), and Dart checks (no Dart touched). Coverage was not measured.

**Verification notes, follow-up review (run on 2026-10-27; full gate deferred to the story loop by its gate rule):**
- `cargo test -p zanshin-jj --test it -- hunks::` -- 15 passed (incl. the new binary mode-only and conflicted-revision tests).
- `cargo test -p zanshin-jj --lib -- hunks:: source_symbol:: select_tree::` -- 23 passed.
- `cargo test -p zanshin-jj --test it -- select_tree:: commit_views:: api_stability::` -- 101 passed.
- `cargo clippy -p zanshin-jj --all-targets -- -D warnings` -- clean.
- `cargo fmt --all --check` -- clean.
- Not run: `zanshin-ffi` tests (untouched this pass), codegen, the parity oracle, Dart checks. Coverage was not measured.

**Commands:**
- `cargo test -p zanshin-jj --lib -- hunks:: source_symbol:: select_tree:: cli_command:: every_verb` -- expected: pass
- `cargo test -p zanshin-jj --test it -- hunks:: select_tree:: commit_views::` -- expected: pass
- `cargo test -p zanshin-ffi --lib commit_views` -- expected: pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` -- expected: clean
- `cargo fmt --all --check` -- expected: clean

## Auto Run Result

Status: done. Code commit `87d963acb680813c45cd6b67a7fad85be27af6a5`.

**Summary.** `zanshin_jj::Repo::compute_hunks(&HunksOptions) -> Result<Vec<FileDiff>, MutateError>` is the CLI's `jj diff --git` between two trees, returned as data.
- Input: two trees, each as ids plus labels.
- Hunks: jj-lib's `unified_diff_hunks` over `git_diff_part`'s texts, with the CLI's binary and equal-content rules.
- Per hunk: 0-based ranges, the ported source symbol, removed/added counts, and its lines (`Context`/`Removed`/`Added`, each keeping its `\n`).
- Sections: `select_tree::sections` cuts them, so a key this read returns is a key `select_tree` accepts. Each hunk lists the sections it shows, and each file lists all of its own.
- Per file: `binary` and `mode_change` flags.
- `--context` (default `diff.git.context`) and `-w`/`-b` pass through, and config resolves for the CLI command `diff`.
- `ShowEntry` now reports `parent_tree_labels` and `tree_labels`.
- The story's AC location `crates/zanshin-diff` is reconciled to `zanshin-jj`, since only `zanshin-jj` imports jj-lib. epics.md Story 5.1 has a note about it.

**Files changed.**
- `crates/zanshin-jj/src/hunks.rs` (new): the read, its types and unit tests.
- `crates/zanshin-jj/src/source_symbol.rs` (new): a verbatim port of the CLI's hunk-header symbol, with its test table (`MIT AND Apache-2.0`).
- `crates/zanshin-jj/src/config.rs`: `diff_git_context`, which reads the keys in the CLI's order.
- `crates/zanshin-jj/src/repo.rs`: `Repo::compute_hunks` and its `records!` witness.
- `crates/zanshin-jj/src/cli_command.rs`: `DIFF`.
- `crates/zanshin-jj/src/commit_views.rs`: the `ShowEntry` labels.
- `crates/zanshin-jj/src/select_tree.rs`: `is_text` is now `pub(crate)`, and the doc is updated.
- `crates/zanshin-jj/src/lib.rs`: modules and re-exports.
- `crates/zanshin-jj/Cargo.toml`: the regex WHY comment.
- `crates/zanshin-jj/tests/it/hunks.rs` (new) and `tests/it/main.rs`: an integration test per matrix row, plus `select_tree` round trips covering sections, the mode toggle, and a conflicted merge parent in two marker styles.
- `crates/zanshin-jj/tests/it/api_stability.rs`: the surface check.
- `crates/zanshin-ffi/src/commit_views.rs`: a test literal.
- Ledger and planning files: `_bmad-output/planning-artifacts/epics.md` (reconciliation note), `_bmad-output/implementation-artifacts/deferred-work.md` ("Surfaced in Story 5.1"), `_bmad-output/implementation-artifacts/sprint-status.yaml` (5-1 done, epic-5 in-progress), and `epic-5-context.md` (compiled this run).

**Review.** 27 findings: 0 high, 6 medium, 12 low, 9 false. 16 rows were routed `patch` and applied: 6 medium (the test gaps for configured context, `-w`/`-b`, marker style, labels and the mode round trip; the SPDX line) and 10 low (docs, the config read order, the `show-path-prefix` test, counting once, the `DiffReader` rename, the 1000-line test and the epics note). Deferred: 1 item (the `ShowEntry` labels on the wire, for 5.8). Rejected, with reasons in the Review Triage Log:
- copies/kinds and filesets (Story 5.6);
- word tokens (Story 5.2);
- the lossy-UTF-8 flag;
- the `-w` empty-section fallback;
- GUI surface (5.5/5.8);
- R5 (whole conflict text);
- the stock-CLI test;
- the access-denied behavior;
- the "labels don't affect keys" claim;
- the missing Auto Run Result.

**Deferred items handed to this story:**
- **I1** (no read yields sections/`HunkKey`s): partly done, in `87d963acb680813c45cd6b67a7fad85be27af6a5`.
  - Done: `compute_hunks` emits every file's and every hunk's keys from `select_tree::sections`. `tests/it/hunks.rs` feeds them back into `select_tree` and gets the revision's files.
  - Left: the wire. The `Diff` FlatBuffers payload (Story 5.5) and the FFI/Dart read (Story 5.8) are already planned stories, so the item is not mirrored again.
- **I2** (no read yields `select_tree`'s inputs from trees): partly done, in `87d963acb680813c45cd6b67a7fad85be27af6a5`.
  - Done: the read takes trees, not revisions, and `ShowEntry` now reports both trees' labels, so a merge's parent tree (held by no revision) is nameable. Per file it emits the sections cut over the materialized conflict text (`ui.conflict-marker-style` + the tree's labels) and `mode_change`, the toggle flag. The conflicted-merge round trip passes in the default and the `git` marker style.
  - Left: the same wire as I1 (5.5/5.8), plus the labels on the FFI `ShowView`. That last part is deferred to 5.8 and is the new "Surfaced in Story 5.1" entry.

**Follow-up review recommended: true.** This first pass patched 6 medium entries and 0 high ones. The unverified risks: the per-file coverage of the two new source files (`hunks.rs`, `source_symbol.rs`) against the 80% floor is measured only by the story loop's final gate, and the review's test additions were checked by targeted runs only.

**Verification.** See "Verification notes" above. Every targeted command passed after the patches.

**Residual risks.**
- The hunk text is CLI-equal by construction (the same jj-lib functions), not by an oracle comparison with the stock `jj diff --git`.
- Renames show as delete plus add until 5.6 adds copy records.
- `-w`/`-b` can leave a hunk without a selectable section; this is documented.

### Follow-up review (2026-10-27)

**Summary.** A second review pass over the whole Story 5.1 diff; code commit `6eddcd27f41f30189f4cef9330cc7931930947f4`. One behavior fix: `FileDiff::binary` now follows the CLI's order (`show_git_diff` skips equal contents before its binary check), so a mode-only change of a binary file is no longer reported binary. Four test gaps were closed, including the case the new `ShowEntry::tree_labels` exist for: a conflicted revision whose own tree carries markers.

**Files changed.**
- `crates/zanshin-jj/src/hunks.rs`: the binary rule and its docs (module doc, `FileDiff::binary`).
- `crates/zanshin-jj/tests/it/hunks.rs`: fixture files `binmode.dat` and `both.sh`; new tests `a_mode_only_change_of_a_binary_file_is_not_binary` and `a_conflicted_revision_round_trips_through_select_tree` (default + `git` style); the mode round trip now includes a mode+content change; the `git`-style label assertion; zero-id and label-count refusals.
- `_bmad-output/implementation-artifacts/deferred-work.md`: "Surfaced in the follow-up review of Story 5.1" (the licence notice).

**Review.** 28 findings: 0 high, 6 medium, 9 low, 13 false. Patched entries: 2 medium (the binary rule, reported by three layers; the conflicted right side, reported by two) and 3 low (the error-path asserts, the mode+content round trip, the `git`-style label assertion). Deferred: 1 medium (the Apache-2.0 licence notice and crate metadata, a project-wide decision). Rejected, with reasons in the Review Triage Log: file kinds/modes and renames (5.6), lossy decoding, the hunk key (path + ranges already identify it), the stock-CLI oracle, symlinks, access denied, GUI surface, subset acceptance, the EOF and `-w` test-scope claims (all carried or false); right-only context text at `-w`/`-b`, the quadratic section match, the deferred-work/sprint-status/epics wording (low, not worth the change).

**Follow-up review recommended: false.** This follow-up pass patched no high entry (2 medium, 3 low), so the work has converged.

**Verification.** See the follow-up verification notes above; every targeted command passed.

**Residual risks.** Unchanged from the first pass, plus: per-file coverage of `hunks.rs` is measured only by the story loop's final gate; the licence notice is open for Ralph.
