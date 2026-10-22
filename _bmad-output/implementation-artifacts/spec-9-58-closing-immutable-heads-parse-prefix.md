---
title: 'Story 9.58 closing run — an unparseable `immutable_heads()` refuses with the CLI''s "Invalid `revset-aliases.immutable_heads()`" text'
type: 'bugfix'
created: '2026-10-22'
status: 'done'
baseline_revision: 'e8af7e869153829af6a2c93e0243d21b62f4172f'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      Every revset parse error Zanshin reports drops jj-lib's source chain (e.g. an
      `immutable_heads()` whose definition calls a broken user alias loses the "In alias …" cause),
      while the CLI prints that chain as "Caused by:".
    evidence: |-
      `crates/zanshin-jj/src/revset.rs:464` `parse_revset_in` maps with `e.to_string()`; jj-lib 0.46.0
      `RevsetParseError` is `#[error("{pest_error}")]` with a separate `source` (`revset_parser.rs:155-161`).
      The CLI's `config_error_with_message(…, e)` / `print_parse_diagnostics` render the whole chain.
      Pre-existing, shared by every revset parse in the crate; found in this run's review.
    location: >-
      crates/zanshin-jj/src/revset.rs:464
    severity: low
---

<intent-contract>

## Intent

**Problem:** Story 9.58's deferred item 1, verified at `e8af7e8`: `revset::immutable_heads_expression` (`crates/zanshin-jj/src/revset.rs:670-695`) returns `parse_revset_in`'s `RevsetError::ParseError` as is; the start-up environment (`snapshot.rs:380`, `CommandEnv::load`) and `git push`'s planner (`push.rs:1343`) wrap it with `mutate::cfg`, so the refusal reads `invalid revset: <jj-lib parse error>`. The CLI parses the alias once per command at start-up (`reload_revset_expressions` → `load_immutable_heads_expression`, `cli_util.rs:1083-1117` @ v0.46.0) and raises `config_error_with_message("Invalid `revset-aliases.immutable_heads()`", e)` — for every command, `jj git push` included (its commit check only RESOLVES the already-parsed expression, `push.rs:803-805`). Story 9.58 gave the resolve failure that text (`op_support::resolve_immutable`); the parse failure still lacks it.

**Approach:** `immutable_heads_expression` (and so `immutable_expression`) returns a `ConfigError::Load` whose reason is "Invalid `revset-aliases.immutable_heads()`: " + jj-lib's parse reason — the same shape `template::load_short_prefixes` uses for "Invalid `revsets.short-prefixes`: …". The callers pass that reason through unchanged (no `config error: ` / `invalid revset: ` prefix).

## Boundaries & Constraints

**Always:**
- Every refusal of an unparseable `immutable_heads()` — every verb's pre-verb start-up environment, the creation paths (`init`, `clone`, `convert`), a read's pre-verb snapshot — has `context`/`reason` starting with "Invalid `revset-aliases.immutable_heads()`: " and still naming the offending text (jj-lib's parse error). Error CODE and refusal point unchanged (`jj.config_error` / `PreconditionError::Config` / `RepoError::Config`, before any lock, nothing written).
- `git push`'s planner (unreachable for a parse failure in practice — the start-up environment parses the same alias first) maps the new error to `MutateError::Config` with the reason verbatim.
- `graph.rs` `LogParse::new` (also preceded by the pre-verb snapshot) takes the `ConfigError` through `RevsetError::Config`'s existing `From`.
- Docs: the two revset.rs `# Errors`, `docs/rust-error-codes.md`'s `jj.config_error` "Since Story 9.58" sentence name the parse case too.

**Never:**
- No change to `resolve_immutable`, push's commit-check resolution (stays jj-lib's bare text, as the CLI), the diagnostics recording, any error variant, `.fbs`, FFI, Dart or UI.
- Never regenerate fixtures; never lower `coverage-baseline.txt`; do not touch Story 9.58's spec, `epics.md` or `epic-9-context.md`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Unparseable alias, a verb | repo config `'immutable_heads()' = 'bogus_function('`; `describe` | `MutateError::Precondition(PreconditionError::Config { reason })`, reason starts with "Invalid `revset-aliases.immutable_heads()`: ", no op | `jj.config_error` |
| Unknown function, snapshot | `'immutable_heads()' = 'bogus_function()'`; `snapshot()` | `PreconditionError::Config`, prefixed reason containing `bogus_function` | `jj.config_error` |
| Unparseable alias, conversion / init | user config `bogus_function()`; `convert_colocated` / colocated `Repo::init` | `RepoError::Config`, prefixed reason | `jj.config_error` |
| Unit: function | `immutable_heads_expression` / `immutable_expression` on an unparseable definition | `Err(ConfigError::Load { reason })` prefixed, no `invalid revset: ` inside | — |
| Parses | builtin alias | `Ok`, diagnostics recorded as today | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/revset.rs:609-695` -- `immutable_expression` (`# Errors` :625-627) and `immutable_heads_expression` (`# Errors` :667-669, the `parse_revset_in(..)?` at :679-685) — the one place to change; return type `RevsetError` → `ConfigError` (imported at :23). Inline `mod tests` at the bottom of the file.
- `crates/zanshin-jj/src/template.rs:457-463 parse_reason` -- strips `RevsetError`'s own `invalid revset: ` prefix; private → `pub(crate)` and reuse (pattern: `load_short_prefixes` :103-118).
- `crates/zanshin-jj/src/snapshot.rs:380` -- `immutable_expression(..).map_err(cfg)?` → plain `?` (`From<ConfigError> for PreconditionError`, :252-257, passes the reason verbatim); `CommandEnv::load` `# Errors` :366-368.
- `crates/zanshin-jj/src/push.rs:1342-1343` -- `immutable_heads_expression(..).map_err(cfg)` → map `ConfigError::Load { reason }` to `MutateError::Config { reason }` (cfg would prepend `config error: `).
- `crates/zanshin-jj/src/graph.rs:210` -- `immutable_expression(..)?` keeps compiling via `RevsetError::Config(#[from] ConfigError)`; `LogParse::new` `# Errors` unchanged in substance.
- `crates/zanshin-jj/src/mutate.rs:159-166` -- `MutateError::Config` doc already says "does not parse or resolve" and cites the CLI text; leave.
- Witnesses to tighten (they assert only the variant / `contains("bogus_function")`): `crates/zanshin-jj/tests/it/op_support.rs:302 an_unparseable_immutable_heads_alias_is_a_config_error`, `tests/it/snapshot_colocated.rs:545 a_bad_immutable_heads_alias_is_refused_before_the_lock`, `tests/it/creation_warnings.rs:611/:634` (const `IMMUTABLE_HEADS_INVALID` at :98 already holds the prefix), `src/convert.rs:864-870`.
- `docs/rust-error-codes.md:58` -- `jj.config_error` row, "**Since Story 9.58** every refusal of an `immutable_heads()` that parses but does not resolve …" — extend to the parse failure (Story 9.58 closing run).
- `_bmad-output/implementation-artifacts/deferred-work.md:1843-1845` -- strike the item, `RESOLVED 2026-10-22 (spec-9-58-closing-immutable-heads-parse-prefix, commit …)`.
- `_bmad-output/implementation-artifacts/spec-9-58-init-left-behind-one-level-immutable-text.md` `deferred:` -- READ-ONLY (do not edit).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/template.rs` -- `parse_reason` `pub(crate)` -- reuse.
- `crates/zanshin-jj/src/revset.rs` -- both functions return `ConfigError`; the parse failure becomes `ConfigError::Load { reason: format!("Invalid `revset-aliases.immutable_heads()`: {}", parse_reason(e)) }`, doc cites `cli_util.rs:1106-1117` @ v0.46.0; inline unit test: an unparseable definition yields the prefixed reason without `invalid revset: `, the builtin parses -- item 1.
- `crates/zanshin-jj/src/snapshot.rs`, `crates/zanshin-jj/src/push.rs`, `crates/zanshin-jj/src/graph.rs` -- caller mapping as in the Code Map; docs -- item 1.
- `crates/zanshin-jj/tests/it/{op_support,snapshot_colocated,creation_warnings}.rs`, `crates/zanshin-jj/src/convert.rs` tests -- assert the prefix -- witnesses.
- `docs/rust-error-codes.md` -- registry sentence.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- resolve the item (spec commit).

**Acceptance Criteria:**
- Given an `immutable_heads()` alias that does not parse, when any verb, read, creation path or conversion refuses at its start-up environment, then the error code is unchanged and its reason starts with "Invalid `revset-aliases.immutable_heads()`: " followed by jj-lib's parse error.
- Given a parseable alias, when the expression is built, then behavior, diagnostics and warnings are unchanged (existing suites green).
- Given the registry, when read, then the `jj.config_error` row states the prefix for both the parse and the resolve failure, with push's commit check the documented exception.

## Spec Change Log

## Review Triage Log

### 2026-10-22 — Review pass
- verdicts: 17 findings — high 0, medium 0, low 14, false 3, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) the deferred-work.md item is struck but its follow-up bullet still reads as open work, and the hash is a placeholder — follow-up now "Done (spec-9-58-closing-immutable-heads-parse-prefix)"; the hash is filled at finalize.
  - `[low]` `[patch]` (blind) the registry row still says a malformed alias definition surfaces "only where the alias is used", contradicting the new parse sentence for `immutable_heads()` — the sentence now excepts `immutable_heads()` (parsed by the start-up environment). The stale Story 9.1 citation `cli_util.rs:1139` is pre-existing history of that story (v0.44.0 line) and left as is.
  - `[low]` `[reject]` (blind) `plan_push`'s adjacent `revset_config(..).map_err(cfg)` still prepends `config error: ` — pre-existing, outside the item, and unreachable for a broken alias table (the start-up environment's `revset_config` refuses first, verbatim through `From<ConfigError> for PreconditionError`).
  - `[low]` `[reject]` (blind) the push planner's new mapping is unreachable and untested; `CommandEnv` could carry the heads expression instead of re-parsing — the mapping keeps the same text should it ever run; carrying the parsed heads through `VerbContext` is a refactor of Story 9.20's planner the item does not need.
  - `[false]` `[reject]` (blind) `LogParse::new`'s doc names the wrong variant and the public graph docs are stale — `LogParse::new` does return `RevsetError::Config` for this case (its doc is about that function); the public `walk_graph`/`graph_topology` callers see the start-up environment's refusal first, which their `RevsetError::Precondition` bullet already documents ("its start-up environment included").
  - `[low]` `[reject]` (blind) `parse_reason` lives in `template.rs` but is now used by `revset.rs` — cosmetic module placement; moving it is churn with no named harm.
  - `[low]` `[defer]` (blind) the parse error's source chain (e.g. "In alias …") is dropped, unlike the CLI's "Caused by:" — pre-existing in `parse_revset_in` for every revset parse (`revset.rs:464`, `e.to_string()`), not caused by this change; added to `deferred:` and mirrored into deferred-work.md.
  - `[low]` `[patch]` (blind) the inline syntax-error test only checked `reason.len() > PREFIX.len()` — now asserts the reason contains `bogus_function` (jj-lib's error echoes the text). Placement rejected: `immutable_heads_expression` is `pub(crate)`, unreachable from `tests/it`, so its unit test belongs inline (CLAUDE.md test placement); the shared sink in the builtin test checks nothing about diagnostics by design.
  - `[low]` `[reject]` (blind) no FFI / parity witness of the new `context` text — every FFI mapper passes the `Config` reason through verbatim (`map_repo_err` / `map_mutate_err`, mapping tests pinned); the oracle compares refusals and disk state, not message text, and the CLI renders a "Caused by:" chain the Zanshin envelope does not have.
  - `[low]` `[reject]` (edge) `LogParse::new`'s own parse now classifies as `jj.config_error` instead of `jj.revset_parse_error` — reachable only if the alias is broken between the start-up environment and the reload in the same call; `jj.config_error` is the CLI's classification for it.
  - `[low]` `[patch]` (edge) the new registry sentence claimed "before any lock, nothing written" for the creation paths, but a new colocated init and the conversion refuse after `.jj/` exists — split: verbs/reads refuse before any lock with nothing written; creation paths refuse at their own start-up environment with what they created in `left_behind`.
  - `[low]` `[reject]` (intent) expectations live at CLI text, tests assert Rust error values — same as the blind FFI/parity row; rejected with it.
  - `[low]` `[reject]` (intent) push's call-site parse is not exercised — same as the blind unreachable-mapping row; the CLI comparison per call site (push parses at start-up, `push.rs:803-805` only resolves) is what settles the text, and it holds.
  - `[low]` `[reject]` (intent) graph/topology reclassification and their public docs — same as the edge reclassification row and the blind docs row.
  - `[low]` `[reject]` (intent) `content_ops.rs` restore/absorb witnesses still assert only the variant — they never asserted the text (nothing to adjust); the same start-up path's text is pinned by `op_support.rs`, `snapshot_colocated.rs`, `creation_warnings.rs` and `convert.rs`.
  - `[false]` `[reject]` (intent) "in one place" needed caller edits — the prefix is applied in one place (`immutable_heads_expression`); the caller edits only remove the wrappers that would re-prefix it.
  - `[false]` `[reject]` (intent) `## Auto Run Result` and the commit hash are missing — written at finalize.

## Verification

**Commands (targeted; the story loop runs the full gate — do NOT run `cargo make test`, `cargo make test-full` or `cargo make coverage`):**
- `cargo test -p zanshin-jj` -- expected: green.
- `cargo test -p zanshin-ffi` -- expected: green (dependent).
- `cargo test -p zanshin-parity --test oracle` -- expected: green, no UNEXPECTED / CHANGED / STALE (no verb's observable effect changes; a sanity witness).
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean.

**Verification notes (run 2026-10-22, after the review patches; no `cargo make test` / `test-full` / `coverage` per the loop's gate rule):**
- `cargo fmt --all --check` — clean.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` — clean.
- `cargo test -p zanshin-jj` — 310 lib + 1021 `it` passed (1 pre-existing ignored perf benchmark); incl. `revset::tests::{an_unparseable_alias_is_the_clis_config_error, the_builtin_alias_parses}`, `op_support::an_unparseable_immutable_heads_alias_is_a_config_error`, `snapshot_colocated::a_bad_immutable_heads_alias_is_refused_before_the_lock`, `creation_warnings::creation_paths_report_what_the_cli_prints` (conversion + new colocated init phases), `convert::tests` start-up refusal.
- `cargo test -p zanshin-ffi` — 196 lib + 310 `it` passed (dependent; no FFI change).
- `cargo test -p zanshin-parity --test oracle` — 210 passed, no UNEXPECTED / CHANGED / STALE.
- No `cargo make codegen` (no FFI / schema change), no Dart package touched.
- Matrix audit: rows 1–3 covered by the four tightened integration/unit witnesses above, rows 4–5 by the two new `revset::tests`; all ran and passed.
- Coverage not measured (loop gate rule); the new lines in `immutable_heads_expression` are hit by the unit tests; `push.rs`'s mapping closure shares its statement with the call that runs and is unreachable for a parse failure (the start-up environment refuses first).

## Auto Run Result

Status: done

**Items:**
- **1 — fixed (593f6c907e046bf1d02e74e8e48099406f3d09b2).** Verified real at `e8af7e8`: `revset::immutable_heads_expression` returned `RevsetError::ParseError` unprefixed; the start-up environment (`snapshot.rs` `CommandEnv::load`) and `git push`'s planner wrapped it with `cfg`, so the refusal read `invalid revset: <jj-lib parse error>`. The CLI parses the alias once per command at start-up (`reload_revset_expressions` → `load_immutable_heads_expression`, `cli_util.rs:1083-1117` @ v0.46.0, `config_error_with_message("Invalid `revset-aliases.immutable_heads()`", e)`); `jj git push`'s commit check only resolves the already-parsed expression (`push.rs:803-805`), so the parse carries the prefix at every call site, push included. Now `immutable_heads_expression` / `immutable_expression` return `ConfigError::Load` "Invalid `revset-aliases.immutable_heads()`: <jj-lib parse error>", in one place; the callers pass the reason through unchanged. Error codes and refusal points unchanged; push's commit-check resolve keeps jj-lib's bare text (Story 9.58).

**New finding (deferred, mirrored into deferred-work.md):** every revset parse error drops jj-lib's source chain ("In alias …"), unlike the CLI's "Caused by:" — see `deferred:`.

**Files changed (593f6c9):**
- `crates/zanshin-jj/src/revset.rs` — both functions return `ConfigError` with the CLI's prefix; two inline unit tests.
- `crates/zanshin-jj/src/template.rs` — `parse_reason` `pub(crate)` (reused).
- `crates/zanshin-jj/src/snapshot.rs` — start-up environment passes the reason through (`?`), unused `cfg` import removed, `# Errors` doc.
- `crates/zanshin-jj/src/push.rs` — planner maps `ConfigError::Load` to `MutateError::Config` verbatim.
- `crates/zanshin-jj/src/graph.rs` — `LogParse::new` `# Errors` doc.
- `crates/zanshin-jj/tests/it/{op_support,snapshot_colocated,creation_warnings}.rs`, `crates/zanshin-jj/src/convert.rs` tests — witnesses assert the prefix.
- `docs/rust-error-codes.md` — `jj.config_error` row: the parse case, the `immutable_heads()` exception to "only where the alias is used", creation paths vs verbs/reads.
- `_bmad-output/implementation-artifacts/deferred-work.md` — item resolved; the new finding mirrored (spec commit).

**Review:** 17 findings (low 14, false 3). Patched (all low): ledger follow-up bullet; registry contradiction for `immutable_heads()`; registry "nothing written" claim split for creation paths; inline test asserts jj-lib's text follows. Deferred: the dropped parse-error source chain (new, pre-existing). Rejected: push's adjacent `revset_config` `cfg` prefix (pre-existing, unreachable), the unreachable push mapping / carrying parsed heads (refactor), `parse_reason` placement (cosmetic), no FFI/parity text witness (verbatim mappers; oracle compares no text), graph reclassification under a mid-call config edit (now the CLI's class), `content_ops` witnesses (never asserted text), plus the false rows in the triage log.

**Follow-up review recommended:** false — patched counts high 0, medium 0, low 4 entries.

**Verification:** see Verification notes (fmt, clippy, `cargo test -p zanshin-jj`, `-p zanshin-ffi`, parity oracle — all green; no full gate per the loop's rule).

**Residual risks:** coverage ratchet not run (loop gate at the end); `push.rs`'s mapping closure is unreachable for a parse failure; the `context` text is "prefix: cause" rather than the CLI's two-line "Caused by:" rendering (Story 9.58's established shape).
