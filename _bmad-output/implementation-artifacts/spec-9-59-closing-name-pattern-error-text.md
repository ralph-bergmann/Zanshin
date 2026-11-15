---
title: 'Story 9.59 closing run — a bad name pattern refuses with the CLI''s text and hint; bookmark helper citations at v0.47.0'
type: 'bugfix'
created: '2026-11-16'
status: 'done'
baseline_revision: 'ce39d7de0ee0f16ff97fe19f69ef3873df0dfefb'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      A `remotes.<r>.auto-track-bookmarks` / `fetch-bookmarks` / `fetch-tags` pattern that does not
      parse refuses `jj.config_error` with only "Invalid `remotes.<r>.<field>`: <kind>" — no
      `Caused by:` lines and no hint, while the CLI's `parse_remote_string_expression` adds both.
    evidence: |-
      `crates/zanshin-jj/src/config.rs:1714-1724` and the clone `preset` closure at
      `crates/zanshin-jj/src/creation.rs:541-550` render `e.kind()` only; CLI @ v0.47.0
      `cli/src/revset_util.rs:463-488` raises `config_error_with_message(message, err)` plus
      `revset_parse_error_hint`. `ConfigError::Load` / `RepoError::Config` carry no hints, so the
      hint needs a hints channel on `jj.config_error`. Pre-existing; a sibling of this run's item 1
      (a different parser and code), found in review.
    location: >-
      crates/zanshin-jj/src/config.rs:1714
    severity: medium
---

<intent-contract>

## Intent

**Problem:** Story 9.59's deferred items, verified at `ce39d7d`. (1) `bookmark_ops::describe_pattern_parse_error` (`crates/zanshin-jj/src/bookmark_ops.rs:177`) renders a name-pattern parse failure as "failed to parse name pattern: <kind>: <flattened source>" with no hint, while the CLI (`parse_union_name_patterns` / `parse_name_patterns_or_remote_symbols`, `cli/src/revset_util.rs:323-343` / `:345-375` @ v0.47.0) raises `user_error_with_message("Failed to parse name pattern[ or remote symbol]: {kind}", err)` — `Caused by:` lines from the error itself (pest caret diagram included) — plus `revset_parse_error_hint`. Every Zanshin caller of the shared helpers maps to one of those two CLI functions (bookmark delete/forget/move/advance/track/untrack/list, tag delete/track/untrack, git fetch/push/clone patterns, `git.fetch`/`git.push` config, `experimental-advance-branches`). `bookmark list` and `clone` also lose the hint because `BookmarkError::InvalidInput` / `RepoError::InvalidInput` carry none, and clone wraps the reason with `invalid input: `. (2) `bookmark_ops.rs` and `bookmarks.rs` cite the CLI at v0.46.0 (some ranges already off there); at v0.47.0 `default_ignored_remote_name` moved to `frontend/src/revset_util.rs:36-45` and `revset_util.rs` lost 41 lines before the pattern parsers.

**Approach:** One renderer, like `fix.rs::fileset_parse_error`: reason = `["Failed to parse {what}: {kind}"] + warning::caused_by(Some(err))` joined by `\n`, hints = `revset::parse_hint(err)` (made `pub(crate)`). `union_patterns` returns `(reason, hints)`; `BookmarkError::InvalidInput` and `RepoError::InvalidInput` gain `hints: Vec<String>`, passed to `FfiError.hints`. Then re-read every CLI citation in the two files at v0.47.0 and rewrite it (`@ v0.47.0`, correct range).

## Boundaries & Constraints

**Always:**
- The refusal's `reason` / `context` equals the CLI's `Error:` text without the `Error: ` label (all lines up to the `Hint:` line), and `hints` equals the CLI's `Hint:` line(s) without the label — for both heads ("name pattern", "name pattern or remote symbol").
- Codes, refusal points (after the pre-verb snapshot where the CLI parses there; clone after creating the destination) and the no-operation rule unchanged.
- `RepoError::hints()` and `MutateError::hints()` return the new hints; FFI mappers (`map_repo_err`, `map_bookmarks_err`) forward them.
- `docs/rust-error-codes.md` `jj.invalid_input` "Hints" list names the name-pattern hint; diagnostics note re-checked at jj-lib 0.47.
- Every changed line gets a test witness; an oracle witness compares message and hint with the pinned `jj`.

**Never:**
- No `.fbs`, codegen, Dart or UI change (`FfiError.hints` / `ZanshinFfiException.hints` already exist).
- No citation edits outside `bookmark_ops.rs` / `bookmarks.rs` (jj-lib citations like `view.rs:197-213` stay); no behavior change from item 2.
- Never regenerate fixtures; never lower `coverage-baseline.txt`; do not touch Story 9.59's spec, `epics.md`, `epic-9-context.md`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Unknown kind | `tag_delete(["bogus:x"])` | reason `Failed to parse name pattern: Invalid string pattern\nCaused by:\n1:  --> 1:1 …\n2: Invalid string pattern kind \`bogus:\``; hint "Try prefixing with one of `exact:`, …" | `jj.invalid_input`, after snapshot, no op |
| Syntax error | `bookmark_forget(["a b"])` | reason `Failed to parse name pattern: Syntax error\nCaused by:  --> 1:3 …`; revsets syntax hint | same |
| Track head | `tag_track(["glob:\"[\""])` | reason starts `Failed to parse name pattern or remote symbol: Invalid string pattern`; no hint (glob error) | same |
| List | `list_bookmarks(names=["bogus:x"])` | `BookmarkError::InvalidInput { reason, hints }` as row 1 | `jj.invalid_input` with hints |
| Clone | `clone(branches=["bogus:x"])` | `RepoError::InvalidInput` reason without `invalid input: `, hints as row 1 | `jj.invalid_input` with hints |
| Valid pattern | `v1.*` | unchanged | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/bookmark_ops.rs:164-211` -- `describe_pattern_parse_error`, `union_expression`, `union_patterns` (item 1); `:1097-1117` `parse_names_or_symbols` (track head); module doc `:74-79` says the hint is dropped — rewrite; unit tests `:1414-1460` (`union_matcher_forwards_jj_libs_own_reason…`, asserts the diagram does NOT survive — flip), `:1562-1590` (`parse_names_or_symbols_refuses_with_the_track_head`). All `@ v0.46.0` citations (item 2).
- `crates/zanshin-jj/src/fix.rs:403-412` -- `fileset_parse_error`: the shape to copy.
- `crates/zanshin-jj/src/revset.rs:839-860` -- `parse_hint` (private, port of `revset_parse_error_hint`) → `pub(crate)`; its v0.46.0 citation is outside item 2's files, leave.
- `crates/zanshin-jj/src/warning.rs:436-452` -- `caused_by` (reuse).
- `crates/zanshin-jj/src/bookmarks.rs:192-230` -- `BookmarkError::InvalidInput` + `hints`; `:510-536` list maps `union_patterns`; `:270` clap conflict constructs it (hints empty); inline test `:728`; v0.46.0 citations (item 2).
- `crates/zanshin-jj/src/repo.rs:72-78,111-125` -- `RepoError::InvalidInput` + `hints`, `hints()` arm.
- `crates/zanshin-jj/src/creation.rs:314,384,427-429,873` -- constructions; `:429` clone patterns → `union_patterns` directly.
- `crates/zanshin-ffi/src/repo.rs:110-115,2084` and `crates/zanshin-ffi/src/bookmarks.rs:31,351` -- mappers + their tests.
- `crates/zanshin-jj/tests/it/api_stability.rs:1082,2718` -- constructions.
- Text-pinning tests: `crates/zanshin-jj/tests/it/bookmark_tracking.rs:283`, `tests/it/tag_ops.rs:268`, `tests/it/bookmarks.rs:1056-1074`, `tests/it/clone_init.rs:353,374,854`.
- Oracle: `crates/zanshin-parity/tests/oracle/hints.rs` (CLI-vs-Zanshin message/hint witnesses, `jj()` + stderr), `git_scenarios.rs:1295 tag_scenarios` (state scenario `tag_delete_bad_pattern`).
- `docs/rust-error-codes.md:66` (`jj.invalid_input` Hints list), `:223` (diagnostics note).
- CLI @ v0.47.0: `cli/src/revset_util.rs:323-375`; `frontend/src/revset_util.rs:34-45`; `cli/src/cli_util.rs:3557-3567` `has_tracked_remote_bookmarks`; `bookmark/{create,set,move,advance}.rs` gained one import line (+1 below ~line 20); `{forget,list,rename,track,untrack}.rs` swapped an import (body lines unchanged); `bookmark/mod.rs`, `delete.rs`, `commit_ref_list.rs` unchanged — but several old ranges were already off (e.g. `cmd_bookmark_list` is `list.rs:124-249`).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/revset.rs` -- `parse_hint` `pub(crate)` -- reuse the ported hint.
- `crates/zanshin-jj/src/bookmark_ops.rs` -- renderer returns `(reason, hints)` per the Approach; `union_patterns` returns it; `union_expression` and `parse_names_or_symbols` build `MutateError::InvalidInput { reason, hints }`; docs; unit tests assert the exact CLI text and hints -- item 1.
- `crates/zanshin-jj/src/bookmarks.rs`, `repo.rs`, `creation.rs` -- `hints` field, list/clone mapping (clone: reason without `invalid input: `), `hints()` -- item 1.
- `crates/zanshin-ffi/src/{repo,bookmarks}.rs` -- forward hints; tests -- item 1.
- Tests listed in the Code Map -- update the pinned text; add hint assertions (list and clone included) -- item 1.
- `crates/zanshin-parity/tests/oracle/hints.rs` -- witnesses: `tag_delete(["bogus:x"])` vs `jj tag delete bogus:x`, `bookmark_track(["a b"])` vs `jj bookmark track "a b"`: reason == CLI error lines, hints == CLI hint lines; `git_scenarios.rs` -- `tag_delete_bad_pattern` state scenario -- item 1.
- `docs/rust-error-codes.md` -- hints sentence + diagnostics note -- item 1/2.
- `crates/zanshin-jj/src/{bookmark_ops,bookmarks}.rs` -- every CLI citation re-read at v0.47.0 and rewritten -- item 2.

**Acceptance Criteria:**
- Given a name pattern that does not parse, when any verb or read refuses it, then `jj.invalid_input`'s context is the CLI's error text verbatim and `hints` the CLI's hint lines, checked against the pinned `jj` by the oracle.
- Given the two files, when grepped for `v0.46.0`, then no CLI citation remains and each cited range names the cited item at v0.47.0.
- Given valid patterns, when the suites run, then behavior is unchanged.

## Spec Change Log

## Review Triage Log

### 2026-11-16 — Review pass
- verdicts: 17 findings — high 0, medium 1, low 11, false 5, maybe-false 0
- findings:
  - `[medium]` `[defer]` (blind) `remotes.<r>.*` config patterns still refuse with only the kind, no `Caused by:` and no hint (CLI `parse_remote_string_expression`) — verified at `config.rs:1714-1724` / `creation.rs:541-550`; pre-existing, a different parser and code (`jj.config_error`, no hints channel); added to `deferred:` and mirrored into deferred-work.md.
  - `[low]` `[patch]` (blind) `docs/rust-error-codes.md` Story 9.8 sentence still said "jj-lib's own reason verbatim" and the name-pattern diagnostics bullet still said v0.46.0 only — reworded to the CLI's error text and "v0.46.0 and v0.47.0".
  - `[low]` `[reject]` (blind) the pest caret diagram now reaches `error.context` without an ADR note — Ralph decided "behave like the CLI" for this item (2026-10-23) and the intent names `fix.rs`'s fileset port, which already ships the diagram; the new `pattern_parse_error` doc states it explicitly, so a reader sees it is deliberate.
  - `[low]` `[reject]` (blind) no structured detail (which entry failed, span) for a pattern failure — a new feature beyond the CLI's text; adds public surface nobody asked for.
  - `[low]` `[reject]` (blind) `list_bookmarks`' `revisions` arm renders a revset parse failure differently from the pattern arm — pre-existing, a separate code (`jj.revset_parse_error`) with Story 9.25's structured detail; aligning it reworks every revset error text, far beyond this item.
  - `[low]` `[reject]` (blind) stale v0.46.0 citations on `revset::parse_hint`, `RepoError::hints`, `RevsetError::hints` — outside item 2's two files; the auditor confirmed `revset_parse_error_hint`'s logic is unchanged at v0.47.0 (`command_error.rs:1059`).
  - `[false]` `[reject]` (blind) `default_ignored_remote_name` cited as `:34-45` though the fn starts at `:36` — the range covers its doc comment and body, which is a valid citation.
  - `[low]` `[reject]` (blind) clone / list texts are pinned against hand-written strings, not the CLI — all go through the one `pattern_parse_error`, whose output the oracle compares verbatim with the pinned `jj` for both heads; a clone oracle witness would need a reachable source for little gain.
  - `[low]` `[reject]` (blind) forget's bad-glob case became a syntax error; glob cases use `starts_with`/`ends_with` — the glob shape is pinned exactly by the `union_matcher` unit test and the bookmark track/untrack integration test (`bad_glob_reason`).
  - `[low]` `[reject]` (blind) three test helpers strip `"invalid input: "` from `Display` — test style, no named harm.
  - `[low]` `[reject]` (blind) `InvalidInput { reason, hints }` built from the tuple at three sites — three one-line literals; a constructor adds surface for no named harm.
  - `[low]` `[patch]` (blind) edited doc comments ran past 120 columns and `ignored_remote_matcher`'s doc had an orphaned break — reflowed (bookmark_ops.rs, repo.rs), no wording change.
  - `[low]` `[patch]` (edge) `hints.rs` indexed `cli.1[0]`, an index panic when the CLI prints no hint — now `first().is_some_and(..)`.
  - `[false]` `[reject]` (intent) the change reaches every caller of the shared helper (list, fetch, push, clone, advance-branches), wider than the per-verb wording — the CLI shares `parse_union_name_patterns` across exactly these callers, so the CLI's behavior is per helper; item 1 says behave like the CLI.
  - `[false]` `[reject]` (intent) R2c: `revset::parse_hint` keeps its v0.46.0 citation — same as the blind citation row; outside item 2's files, behavior unchanged.
  - `[false]` `[reject]` (intent) the GUI-adapted reading (drop the caret diagram) — same as the blind diagram row; the intent cites `fix.rs:405-411`, which keeps it.
  - `[false]` `[reject]` (intent) only two cases are compared with the CLI's text; the `parity!` scenario compares no text — the intent asks for "an oracle refusal scenario", which `tag_delete_bad_pattern` is; the two `hints.rs` witnesses cover both heads and both hint kinds (string-pattern and syntax) through the one renderer.

## Verification

**Commands (targeted; the story loop runs the full gate — do NOT run `cargo make test`, `cargo make test-full` or `cargo make coverage`):**
- `cargo test -p zanshin-jj` -- expected: green.
- `cargo test -p zanshin-ffi` -- expected: green.
- `cargo test -p zanshin-parity --test oracle` -- expected: green, no UNEXPECTED / CHANGED / STALE.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean.

**Verification notes (run 2026-11-16; no `cargo make test` / `test-full` / `coverage` per the loop's gate rule):**
- `cargo fmt --all --check` — clean (also after the review patches).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean (also after the review patches).
- `cargo test -p zanshin-jj` — 455 lib + 1561 `it` passed (1 pre-existing ignored perf benchmark); after the added `tag_ops::track_refusals` glob case, `--test it tag_ops::` — 19 passed.
- `cargo test -p zanshin-ffi` — 245 lib + 411 `it` passed.
- `cargo test -p zanshin-parity --test oracle` — 552 passed, no UNEXPECTED / CHANGED / STALE (499 scenarios incl. the new `tag_delete_bad_pattern`); after the review patch, `hints::` — 12 passed.
- CLI text checked by hand too: `jj bookmark delete` / `track` with `[`, `bogus:x`, `a b`, `foo(`, `x &` in a scratch repo (jj 0.47.1) — the shapes the tests pin.
- No `cargo make codegen` (no FFI schema change), no Dart package touched (`FfiError.hints` already reaches `ZanshinFfiException.hints`).
- Matrix audit: row 1 `tag_ops::delete_refusals` + oracle `bad_name_pattern_refuses_with_the_cli_error_text_and_hint`; row 2 `bookmark_tracking::forget_refuses_no_patterns_before_and_a_bad_one_after_the_snapshot`; row 3 `tag_ops::track_refusals` (added in verify) + oracle `bad_track_pattern_…`; row 4 `bookmarks::list_refusals`; row 5 `clone_init::an_unparsable_branch_pattern_is_refused`; row 6 the existing suites. All ran and passed.
- Coverage not measured (loop gate rule); every changed line is hit by the tests above (FFI mappers by their unit tests).

## Auto Run Result

Status: done

**Items:**
- **1 — fixed (d8b4c8b4b87e43447b631f3603f295e2b1583419).** Verified real at `ce39d7d`: `describe_pattern_parse_error` rendered "failed to parse name pattern: <kind>: <flattened source>" with no hint. Now one `pattern_parse_error` builds the CLI's text — "Failed to parse name pattern[ or remote symbol]: <kind>" plus the error's own `Caused by:` lines (`warning::caused_by`, pest diagram included, as `fix.rs` does for filesets) — and `revset::parse_hint` (the `revset_parse_error_hint` port). It reaches every caller of the shared helpers, as the CLI shares `parse_union_name_patterns` / `parse_name_patterns_or_remote_symbols`: bookmark and tag verbs, `bookmark list`, fetch/push/clone patterns, `git.fetch`/`git.push`, `experimental-advance-branches`. `BookmarkError::InvalidInput` and `RepoError::InvalidInput` gained `hints` (forwarded by the FFI); clone's reason lost its doubled `invalid input: ` prefix. Oracle: two text witnesses in `hints.rs` (both heads, both hint kinds) and the state scenario `tag_delete_bad_pattern`.
- **2 — fixed (d8b4c8b4b87e43447b631f3603f295e2b1583419).** Verified real: every CLI citation in `bookmark_ops.rs` and `bookmarks.rs` now cites v0.47.0 with re-read ranges (several were already off at v0.46.0; `default_ignored_remote_name` moved to `frontend/src/revset_util.rs:34-45`; `has_tracked_remote_bookmarks` is `cli_util.rs:3557-3567`). No behavior differs.

**New finding (deferred, mirrored into deferred-work.md):** `remotes.<r>.*` config patterns refuse `jj.config_error` without the CLI's `Caused by:` lines and hint (`parse_remote_string_expression`); needs a hints channel on `jj.config_error` — see `deferred:`.

**Files changed (d8b4c8b):**
- `crates/zanshin-jj/src/bookmark_ops.rs` — `pattern_parse_error`, `union_patterns` returns `(reason, hints)`, citations at v0.47.0, unit tests pin the CLI text.
- `crates/zanshin-jj/src/bookmarks.rs` — `BookmarkError::InvalidInput.hints`, list mapping, citations at v0.47.0.
- `crates/zanshin-jj/src/repo.rs`, `creation.rs` — `RepoError::InvalidInput.hints`, `hints()`, clone mapping.
- `crates/zanshin-jj/src/revset.rs` — `parse_hint` `pub(crate)`.
- `crates/zanshin-ffi/src/{bookmarks,repo}.rs` — hints forwarded; mapper tests.
- `crates/zanshin-jj/tests/it/{api_stability,bookmark_ops,bookmark_tracking,bookmarks,clone_init,tag_ops}.rs` — CLI text and hints asserted.
- `crates/zanshin-parity/tests/oracle/{hints,git_scenarios,main}.rs` — CLI witnesses and the new scenario.
- `docs/rust-error-codes.md` — `jj.invalid_input` hints paragraph, Story 9.8 sentence, diagnostics notes at 0.47.
- Spec commit: this spec and `deferred-work.md` (both items resolved; the new finding mirrored).

**Review:** 17 findings (medium 1, low 11, false 5). Patched (all low): registry wording, comment reflow, an index panic in an oracle witness. Deferred: the `remotes.<r>.*` config pattern text/hint (medium, pre-existing). Rejected: ADR note for the caret diagram (Ralph's decision, doc states it), structured pattern detail (new surface), the revset arm's text (pre-existing, other code), citations outside the two files, hand-written clone/list texts (one renderer, oracle-pinned), weakened glob inputs (pinned elsewhere), test helper style, the tuple literal, plus the false rows in the triage log.

**Follow-up review recommended:** false — patched counts high 0, medium 0, low 3.

**Verification:** see Verification notes — fmt, clippy, `zanshin-jj`, `zanshin-ffi`, parity oracle all green; no full gate per the loop's rule.

**Residual risks:** coverage ratchet not run (loop gate at the end); tests pin pest's caret diagram verbatim, so a jj-lib/pest change at the next pin bump will move those strings (the oracle witnesses show the CLI's new text); `error.context` is now multi-line with an ASCII diagram, which the UI must show in a monospace font to read well.
