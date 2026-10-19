---
title: 'Story 9.49 closing run — `new` advances bookmarks; path prefixes resolve `.`/`..` like the CLI'
type: 'bugfix'
created: '2026-10-19'
status: 'ready-for-dev'
baseline_revision: '114cb67d1d166c64390d9c799ee76be66511779a'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      `file show` with a single path and `file annotate` parse their path with `file.rs`'s own `parse_path` (`RepoPathBuf::from_internal_string`), so `./x` and `a/../x` are looked up literally and refused as `jj.path_not_found`, and `../x` is refused as `jj.path_not_found` where the CLI resolves the first two and refuses the last with "Path is not in the repo".
    evidence: |-
      crates/zanshin-jj/src/file.rs:254-258 (`parse_path`), used at :485 (single-entry `file show` fast path) and :545 (`file_annotate`); the CLI parses both through `parse_file_path` (cwd-relative, `ui_path.rs:156-169` @ jj-lib 0.46.0). Outside this run's items (Story 9.4 code); every outcome is already a refusal or a CLI-equal answer except the `./x` / `a/../x` forms.
    location: >-
      crates/zanshin-jj/src/file.rs parse_path
    severity: low
---

<intent-contract>

## Intent

**Problem:** Two items Story 9.49's run deferred, both verified against the current code. (1) `jj new` with one parent and no `-A`/`-B` advances the `experimental-advance-branches` bookmarks on that parent's parents to the parent (`cli/src/commands/new.rs:194-204`, `:279-281` @ v0.46.0); Zanshin's `new_change` (`crates/zanshin-jj/src/mutate.rs`) has no advance step. (2) `op_support::parse_prefixes` uses `RepoPathBuf::from_internal_string`, which keeps `.`/`..` as literal components, so `../x` (a path outside the repo) is taken as a prefix and `commit`/`restore`/`squash`/`split`/`absorb` warn and run where the CLI refuses `Path "../x" is not in the repo "."`; `./x` and `a/../x` select nothing where the CLI selects `x`.

**Approach:** (1) `new_change` reuses Story 9.49's advance helpers in `commit.rs` (made `pub(crate)`): with exactly one resolved parent it reads the advance config before the transaction and, after `edit`, merges each advanceable bookmark from the parent's parent to the parent — the CLI's order. (2) `parse_prefixes` keeps its existing validity check and then resolves each entry through jj-lib's `ui_path::parse_fs_path` with a synthetic `"."` cwd and base (the 9.22 parser's function, purely lexical): `.` drops, `..` pops, a `..` that leaves the repo is refused with jj-lib's text.

## Boundaries & Constraints

**Always:**
- The CLI at v0.46.0 is the spec: `git -C ../jj show v0.46.0:cli/src/commands/new.rs` (`cmd_new` `:160-291`), `cli/src/cli_util.rs` `load_advance_bookmarks_matcher` `:921-940`, `get_advanceable_bookmarks` `:2678-2701`, `advance_bookmarks` `:2880-2898`; jj-lib 0.46.0 `ui_path.rs` `parse_fs_path` `:156-169`, jj-core 0.46.0 `file_util.rs` `normalize_path` `:177`, `relative_path` `:142`, `repo_path.rs` `from_relative_path` `:262`.
- `new_change` refusal order = the CLI's: parents resolve first (`jj.change_not_found`), then — only when exactly one parent — the advance config (`jj.invalid_input` for a bad pattern, `jj.config_error` for an unreadable key), all before anything is written. Two or more parents never read the config.
- Advanceable bookmarks: local bookmarks on the single parent's `parent_ids()` matching enabled ∩ ¬disabled, taken from the head repo the verb loads (after the 9.26 snapshot), moved with `merge_local_bookmark(old → parent)` after `edit`, before the finish; default config (`enabled-branches = []`) moves nothing. The op description stays `new empty commit`.
- `parse_prefixes`: `""` stays the root, `/x`, `x/`, `a//b` stay refused as today (the `from_internal_string` check runs first); `.` → root, `./x` → `x`, `a/../b` → `b`, `a/..` → root, `..`/`../x`/`a/../../x` → refused with the reason `invalid path: Path "../x" is not in the repo "."` (jj-lib's `FsPathParseError` Display). Every `build_matcher` / `parse_prefixes` caller (commit, restore, squash, split, absorb, the file reads, the commit views, 9.32's unmatched-path warnings) gets the same rule; the unmatched-path warnings name the resolved path, as the CLI's do. `commit`'s own `jj.commit_paths_unmatched` text keeps the raw `paths` (the CLI joins `args.paths`).
- Rust: clippy pedantic `-D warnings`, rustfmt, rustdoc updated where it states the rules (`build_matcher`, `parse_prefixes`, `mutate::build_matcher`, `new_change`, `Repo::new_change`, `zanshin_new_change`); coverage never drops.

**Never:**
- No new error code, no new warning code, no FFI/schema/Dart API change, no MCP change, no UI code; no `-A`/`-B`/`-m`/`--no-edit` for `new` (Story 9.48).
- No change to `file.rs`'s single-path `parse_path`, 9.22's `wc_ops::parse_paths`, or the accepted/refused status of `""`, `/x`, `x/`, `a//b`; no absolute-path-inside-the-workspace acceptance.
- No change to Story 9.49's spec, `epics.md`, `epic-9-context.md`, `sprint-status.yaml`, `project-context.md` or existing deferred-work.md bullets; never regenerate fixtures; never lower `coverage-baseline.txt`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Advance on | BASE, `enabled-branches = ["*"]`, `new_change([@ = C])` | `b-mark` (on B = C's parent) moves to C; new `@` on C | — |
| Advance minus disabled | as above + `disabled-branches = ["b-mark"]` | `b-mark` stays on B | — |
| Interior parent | `["*"]`, `a-mark` on A, `new_change([B])` | `a-mark` moves to B; `b-mark` stays on B | — |
| Merge | `["*"]`, `new_change([C, D])` | no bookmark moves | — |
| Bad pattern, one parent | `enabled-branches = ["glob:["]`, `new_change([C])` | refused, op head unchanged | `jj.invalid_input` |
| Bad pattern, merge | same config, `new_change([C, D])` | merge created, config never read | — |
| Default config | no advance config, one parent | nothing moves (existing `new_on_wc`) | — |
| Escaping path | `commit`/`restore`/`squash`/`split`/`absorb` with `["../x"]` | refused before any write, op head unchanged | `jj.invalid_input` |
| Dot components | `commit(paths: ["./x.txt", "q/../y.txt"])`, `@` adds x, y, z | committed `@` = x, y; no warning | — |
| Unchanged forms | `""`, `/x`, `x/` | root / refused / refused, as before | `jj.invalid_input` for the two refusals |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/commit.rs` -- `AdvanceableBookmark` :57, `advance_bookmarks_matcher` :69, `advanceable_bookmarks` :80, `advance_bookmarks` :108 (private → `pub(crate)`, docs say "`commit` and `new`"); the config read idiom :145-147 (`crate::config::advance_branches(&ctx.config).map_err(cfg)?`); module doc :3-23.
- `crates/zanshin-jj/src/mutate.rs` -- `new_change` :812-846 (doc :800-811): parents resolved inside the tx :826-829; insert the one-parent advance read after resolution, before the first write, and `advance_bookmarks(tx.repo_mut(), advanceable, &parent_id)` after `edit` :839 and before the trailing `rebase_descendants` :845; `cfg` :406, `be` :399; `build_matcher` wrapper :438-448 (doc names the escape rule); tests :1660-1690 (`build_matcher_*`, `/absolute.txt` refusal :1683).
- `crates/zanshin-jj/src/op_support.rs` -- `build_matcher` :698-727 (doc), `parse_prefixes` :729-740 (the fix; add inline unit tests in this file's `mod tests`).
- `crates/zanshin-jj/src/repo.rs` -- `Repo::new_change` doc :972-985 (`# Errors`: `InvalidInput` bad advance pattern, `Config` unreadable advance key; the advance rule).
- `crates/zanshin-ffi/src/repo.rs` -- `zanshin_new_change` rustdoc :830-866 (`jj.invalid_input` / `jj.config_error` bullets gain the advance-config cause). `docs/ffi-abi.md:500` already lists both codes for it.
- `docs/rust-error-codes.md` -- rows `jj.invalid_input` :65 and `jj.config_error` :57: append an "also emitted — Story 9.49 closing run" clause (`zanshin_new_change`, one parent, advance config); `jj.invalid_input` also names the escaping-path refusal of the path verbs.
- jj-lib reuse -- `jj_lib::ui_path::parse_fs_path` (already used by `crates/zanshin-jj/src/wc_ops.rs:395` — import style reference), `FsPathParseError` Display `Path "{input}" is not in the repo "{base}"`.
- Tests -- `crates/zanshin-jj/tests/commit.rs` (harness: `base_with(repo_config)` :136, `assert_refused_without_an_operation` :413, `bookmark` :117, `head_op` :112; existing `/x` refusal :441; advance tests :341, :533); `crates/zanshin-jj/tests/mutate.rs` (`new_change` tests). `crates/zanshin-jj/tests/content_ops.rs` (restore/absorb), `tests/squash_split.rs` (squash/split) for one `../x` refusal each if cheaper than the oracle alone.
- Oracle -- `crates/zanshin-parity/tests/oracle/scenarios.rs`: `BASE` :32-40, `ADVANCE_ALL` :283, `ADVANCE_ALL_BUT_B_MARK` :292, `new_on_wc` :360-367, `new_merge` :368-378 (D on A), `restore_no_args` :575, `absorb` :583, `EDITOR` :231, `squash_outcome`/`split_outcome`/`split_first` :244-270, `commit_outcome` :273, `commit_path_outside_repo` :1211-1215, `commit_advance_bad_pattern` :1216-1229; `main.rs` `parity!` list :37-…, `SCENARIO_IDS.len() == 77` :129. Outcome compares `refused` + warning count.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/op_support.rs` -- `parse_prefixes`: after `from_internal_string` succeeds, return `parse_fs_path(Path::new("."), Path::new("."), entry)` mapped to `invalid path: {e}`; rewrite `build_matcher`'s and `parse_prefixes`' docs (the `.`/`..` rule, the CLI anchors, why a synthetic `"."` root: the entry is repo-relative and the check is lexical); inline tests: `.`→root, `./x`→`x`, `a/../b`→`b`, `a/..`→root, `x/./y`→`x/y`, `..`/`../x`/`a/../../x` refused with the jj-lib text, `""`→root, `/x` and `x/` still refused -- item 2.
- `crates/zanshin-jj/src/mutate.rs` -- `build_matcher` wrapper doc names the escape refusal; `new_change`: one-parent advance (read before the tx after resolving parents — restructure so parents resolve on `readonly` before `start_repo_transaction` or read the config right after the resolve loop, either way before the first write), `advance_bookmarks` after `edit`; doc names the rule and the two new error causes -- item 1.
- `crates/zanshin-jj/src/commit.rs` -- the four advance items `pub(crate)`; their docs and the module doc say `new` shares them -- item 1.
- `crates/zanshin-jj/src/repo.rs`, `crates/zanshin-ffi/src/repo.rs`, `docs/rust-error-codes.md` -- doc bullets/clauses as in the Code Map -- items 1 and 2.
- `crates/zanshin-jj/tests/mutate.rs` (or `tests/commit.rs`, whichever hosts `base_with`-style config fixtures more cheaply) -- `new_change` matrix rows 1-6 against jj-lib state (bookmark targets, refusal keeps the op head, the merge with a bad pattern succeeds); `tests/commit.rs` -- `../x` refused without an operation, the dot-components row -- items 1 and 2.
- `crates/zanshin-parity/tests/oracle/scenarios.rs` + `main.rs` -- new scenarios: `new_advance_bookmarks` (ADVANCE_ALL, `new`), `new_advance_bookmarks_disabled` (ADVANCE_ALL_BUT_B_MARK), `new_advance_interior` (ADVANCE_ALL + `bookmark create a-mark -r @--`, `new <B>`), `new_merge_advance_none` (ADVANCE_ALL + D on A, `new C D`), `new_advance_bad_pattern` (`["glob:["]`, `new`), `new_merge_ignores_bad_pattern` (bad pattern + D, `new C D`), `commit_path_escapes_repo`, `restore_path_escapes_repo`, `squash_path_escapes_repo` (setup `EDITOR`), `split_path_escapes_repo`, `absorb_path_escapes_repo` (all `../x`), `commit_path_dot_components` (files x, y, z; `./x.txt q/../y.txt`); add to `parity!`; bump the count 77 → 89 -- items 1 and 2.
- `coverage-baseline.txt` -- commit an auto-raise if the gate raises it; never lower.

**Acceptance Criteria:**
- Given every new oracle scenario, when `cargo test -p zanshin-parity --test oracle` runs, then each matches the pinned CLI on every compared aspect with no new ledger entry.
- Given any refusal above, when the op head is compared before and after the call, then it is unchanged.
- Given `cargo make test` on the final tree (unpiped, from the repo root), then it exits 0 and `coverage-baseline.txt` is not lowered (an auto-raise is committed with the code).
- Given the end of the run, then `git status --porcelain` is clean and every commit ends with the required co-author trailer and was made with `--no-gpg-sign`.

## Spec Change Log

## Review Triage Log

## Design Notes

**Item 2: resolve rather than refuse `.`.** The ledger's follow-up offers "refuse `.`/`..` components" or "reuse 9.22's parser". Refusing `./x` and `a/../b` would trade one CLI divergence for another (the CLI accepts both, resolving to `x` and `b`). jj-lib's `parse_fs_path` — the function 9.22's parser calls — is purely lexical (`normalize_path` + `relative_path` + `from_relative_path`), so calling it with `cwd = base = "."` resolves the entry exactly as the CLI does from the workspace root, with no workspace handle (the 14 callers of `build_matcher` keep their signature) and with the CLI's own refusal text. The existing `from_internal_string` check runs first so `/x`, `x/` and `a//b` keep their current (documented, tested) refusals and `""` stays the root — widening those is not this item's.

Golden: `parse_fs_path(".", ".", "a/../b")` → `"./a/../b"` normalises to `b` → `b`; `"../x"` → `../x` → `InvalidComponent("..")` → `Path "../x" is not in the repo "."`; `"."` → `"."` → root.

**Item 1: duplicates.** The advance condition counts `parents` as resolved (one entry ⇒ advance). Duplicate parent ids are pre-existing `new_change` behaviour, untouched here.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib op_support` and `cargo test -p zanshin-jj --test commit --test mutate` -- expected: green, new tests included.
- `cargo test -p zanshin-parity --test oracle` -- expected: all 89 pass (the existing ledgered divergences only).
- `cargo make test` (repo root, unpiped, synchronous, long timeout; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0; coverage held or raised.
