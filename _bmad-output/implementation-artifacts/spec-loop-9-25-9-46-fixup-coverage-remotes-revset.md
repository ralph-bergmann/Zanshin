---
title: 'Fix-up after the story loop 9.25…9.46 — coverage regressions in remotes.rs and revset.rs'
type: 'chore'
created: '2026-10-26'
status: 'done'
baseline_revision: '5c913094866cef3922ce0111dbb840194e75629e'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/coverage.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** `cargo make test` at 5c91309 fails only in its coverage step (failure 1): `crates/zanshin-jj/src/remotes.rs` 99.73% < 100.00% (line 104) and `crates/zanshin-jj/src/revset.rs` 97.55% < 100.00% (lines 273, 667-669, 672-673, 699-700, 783, 804, 815-818, 831, 834, 1305). The lines are Story 9.46's `find_remote` no-URL branch, Story 9.25's per-kind parse/resolution detail and hint arms, the closing run's short-prefixes `?` in `parse_with_prefixes`, and a never-run `panic!` in the inline test helper `parse_detail`.

**Approach:** Add tests that run each uncovered line; rewrite the test helper so no never-run line remains. Kinds that `parse_revset_in` cannot produce (no-workspace kinds, a redefined parameter, chain levels below the top) are reached by calling the private mappers with jj-lib errors built through jj-lib's own public API.

## Boundaries & Constraints

**Always:** Tests only (inline `#[cfg(test)] mod tests` for private items, `tests/it/` for the public `resolve_revset` path); assertions pin the CLI-ported values (kind, symbol, hint), not just execution; the `coverage-baseline.txt` the green gate auto-raises is committed with the fix.

**Never:** No production-code change, no lowered baseline entry, no `exclude_prefix`, no edits to unrelated files; no test-helper `match`/`let-else` whose fallback arm never runs (project-context.md testing rules).

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/remotes.rs:100-117` -- `find_remote`; line 104 `return Ok(None)` is unreachable from `list_remotes` (jj-lib's `iter_remote_names` already drops URL-less sections), so an inline test calls `find_remote` with an empty `[remote "e"]` section. Helper `git_repo_with_config` exists in the inline tests (~:676).
- `crates/zanshin-jj/src/revset.rs:259-276` -- `parse_with_prefixes`; line 273 is the `?` of `template::load_short_prefixes` (`template.rs:112-127`). Reached by `resolve_revset` with an unparseable `revsets.short-prefixes` → `RevsetError::Config`. `tests/it/id_prefix_context.rs` has `medium(config)`.
- `crates/zanshin-jj/src/revset.rs:656-683` -- `parse_detail`; 667/668 (no-workspace kinds) need a `RevsetParseContext { workspace: None, .. }`; 669 from `RevsetAliasesMap::insert("g(x, x)", ..)`'s error; 672/673 are lower chain levels (`origin()`) of `f(bogus())` with alias `f(x) = x` and of alias `rec = rec`.
- `crates/zanshin-jj/src/revset.rs:686-710` -- `resolution_detail`; 699/700 `ConflictedRef`, `Backend`.
- `crates/zanshin-jj/src/revset.rs:761-806` -- `parse_hint` `_ => None` (783, bottom `RecursiveAlias`); `source_hint` final `None` (804, a date-pattern source: `author_date(...)` with a bad date).
- `crates/zanshin-jj/src/revset.rs:809-836` -- `file_pattern_hint` 815-818 (`UiPath(Fs)` built from `FsPathParseError`'s pub fields; `files(glob:"[")`), `fileset_hint` 831 (`files(bogus())`), 834 (fileset `Expression` with a source).
- `crates/zanshin-jj/src/revset.rs:1295-1308` -- test helper `parse_detail`; line 1305 never-run `panic!`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/revset.rs` -- add inline tests for the detail/hint arms above; rewrite helper `parse_detail` without a never-run line.
- `crates/zanshin-jj/src/remotes.rs` -- add an inline test: `find_remote` over an empty remote section is `Ok(None)`.
- `crates/zanshin-jj/tests/it/id_prefix_context.rs` -- add a test: an unparseable `revsets.short-prefixes` makes `resolve_revset` refuse with `RevsetError::Config` naming it.

**Acceptance Criteria:**
- Given the change, when `cargo test -p zanshin-jj --lib -- revset::tests remotes::tests` and the `id_prefix_context` integration tests run, then all pass.
- Given the change, when `cargo make test` runs, then every step passes with `remotes.rs` and `revset.rs` at 100.00% and no file regressing, and the auto-raised `coverage-baseline.txt` is committed with the fix.

## Spec Change Log

## Review Triage Log

### 2026-10-26 — Review pass
- verdicts: 11 findings — high 0, medium 0, low 8, false 3, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind) the rewritten `parse_detail` helper parses with a hand-built context (no `Some("git")`, empty email, default workspace name) instead of `parse_revset_in` — the mapped logic under test (`super::parse_detail`, the hints) is the same function production calls; the differing fields touch resolution / `mine()`, not the parse errors these tests make; `parse_revset_in`'s `map_err` stays pinned end to end by `tests/it/revset_search.rs:443-536`. Going back through `parse_revset_in` reintroduces the never-run fallback arm the project rule forbids.
  - `[false]` `[reject]` (blind) `a_remote_without_any_url_is_none` never checks `list_remotes` omits the URL-less remote — `tests/it/remotes.rs` `a_push_only_remote_is_listed_without_a_fetch_url` already lists over an empty `[remote "e"]` and asserts it is absent.
  - `[low]` `[reject]` (blind) the `root:` hint test builds its `FsPathParseError` by hand, negative `.ok()` branch unpinned — production sets cwd == base, so no real parse produces this error; the arm is the CLI port and is now run; another hand-built case adds nothing a user meets.
  - `[low]` `[reject]` (blind) the `ConflictedRef` detail case uses empty targets and asserts no hints — the hint lines for `ConflictedRef` are pinned in `resolution_hints_follow_the_clis_per_kind_rules`; `detail.hints = resolution_hints(e)` is one covered line.
  - `[low]` `[reject]` (blind) the chain-level test pins the top level's kind but not its symbol — `a_parse_error_in_a_nested_alias_keeps_its_cause_chain` and the integration tests pin the top level; the new test targets the lower levels.
  - `[low]` `[reject]` (blind) no span asserted in the new detail tests — spans have their own tests (`jj_lib_parse_errors_read_back_their_spans` and the render tests); these pin kind/symbol/hints.
  - `[low]` `[reject]` (blind) the baseline's extra entries and raises are unattributed — they are the gate's own auto-raises/first entries; fix is a spec/commit-message edit (c067b19's message and the Auto Run Result name them).
  - `[false]` `[reject]` (blind) the short-prefixes integration test adds little — it is the only test that runs `parse_with_prefixes`'s `?` (old line 273) through `resolve_revset`; without it the file drops below 100%.
  - `[low]` `[reject]` (edge) the helper rewrite leaves `parse_revset_in`'s context unpinned inline — same root as the first row; pinned end to end in `tests/it/revset_search.rs`.
  - `[false]` `[reject]` (intent) the change is uncommitted, no hash for the Auto Run Result — committed at finalize (c067b19), the spec with it.
  - `[low]` `[reject]` (intent) several lines (no-workspace kinds, redefined parameter, `root:` hint, remotes 104) are reached through unit surfaces production cannot produce — they are exhaustive-match arms and a defensive branch the public entry points never reach; the intent asks for tests, not reverts, and only a unit surface reaches them.
  - (verification-gap layer: no gaps.)

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib -- revset::tests remotes::tests` -- expected: all pass
- `cargo test -p zanshin-jj --test it -- id_prefix_context` -- expected: all pass
- `cargo make test` -- expected: green, both files at 100.00%

## Auto Run Result

Status: done

**Failures (from the loop's final `cargo make test` at 5c91309):**
1. coverage (`remotes.rs` 99.73% < 100.00%, `revset.rs` 97.55% < 100.00%) — FIXED by c067b1906f3a47df9de55c9985a274e47400581f (tests only, no production change). `remotes.rs:104` — inline `a_remote_without_any_url_is_none` calls `find_remote` over an empty `[remote "e"]` → `Ok(None)` (`list_remotes` never reaches it: jj-lib's name list drops URL-less sections). `revset.rs:273` — `tests/it/id_prefix_context.rs` `an_unparseable_short_prefixes_refuses_with_a_config_error` (`resolve_revset` → `RevsetError::Config`, "Invalid `revsets.short-prefixes`: …"). `revset.rs` 667-669/672-673/783/804/815-818/831/834 — new inline tests over jj-lib errors: no-workspace `files(a)` / `@`, `RevsetAliasesMap::insert("g(x, x)")`, the `origin()` levels of `f(descripton(y))` (alias `f(x) = x`) and `rec = rec`, `author_date(after:"bogus")`, `files(glob:"[")`, `files(alll())`, a hand-built `UiPath(Fs)` error, a fileset redefined-parameter error; 699/700 — `resolution_detail` of `ConflictedRef` and `Backend`. 1305 — the test helper `parse_detail` no longer has a let-else fallback: it parses through a test-built jj-lib context with `expect_err` and calls the production `super::parse_detail`. Both files back at 100.00%. The same commit carries the gate-written `coverage-baseline.txt`: raises `commit_content.rs` 97.17→97.32, `commit_views.rs` 98.67→98.87, `repo.rs` 99.42→99.59, `wc_ops.rs` 98.27→98.60, and first entries for the loop's new files (`zanshin-jj` `cli_command.rs` 100.00, `colocation.rs` 99.50, `revset_search.rs` 93.29; `zanshin-ffi` `revset_search.rs` 100.00). No entry lowered, no `exclude_prefix`.

**Files changed:** `crates/zanshin-jj/src/revset.rs` (inline tests + helper rewrite), `crates/zanshin-jj/src/remotes.rs` (one inline test), `crates/zanshin-jj/tests/it/id_prefix_context.rs` (one integration test), `coverage-baseline.txt` (gate-written), this spec.

**Review:** 0 patches, 0 deferred, 11 rejected with reasons in the triage log (8 low, 3 false). Follow-up review: false (patched: 0 high, 0 medium, 0 low).

**Verification:** `cargo test -p zanshin-jj --lib -- revset::tests remotes::tests` 27 passed and `cargo test -p zanshin-jj --test it -- id_prefix_context` 9 passed (implementer); full `cargo make test` run from this process exit 0 on the tree committed as c067b19 (no REGRESSION / BELOW FLOOR; parity oracle 491 passed; gate stamp written).

**Residual risk:** the inline parse-detail tests now use a test-built parse context; `parse_revset_in`'s own mapping is pinned end to end only by `tests/it/revset_search.rs`.
