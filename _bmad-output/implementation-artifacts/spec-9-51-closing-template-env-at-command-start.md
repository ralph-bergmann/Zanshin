---
title: 'Story 9.51 closing run — `[template-aliases]` and `revsets.short-prefixes` load at every command start'
type: 'bugfix'
created: '2026-10-20'
status: 'done'
baseline_revision: '3da131d43152ea2cc992199027fd3cc563fc6876'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      `workspace add` builds no second start-up environment for the new workspace, so the CLI prints the alias-table, `immutable_heads()` and short-prefixes warnings twice and Zanshin once.
    evidence: |-
      CLI commands/workspace/add.rs:193 @ v0.46.0 calls `for_workable_repo` unconditionally (cli_util.rs:836-847 builds a full WorkspaceCommandEnvironment for the new workspace); crates/zanshin-jj/src/workspace_add.rs `add_trailers_for` re-parses only `revsets.short-prefixes`, only for a non-empty `-m`, recorded once per call (Load::ShortPrefixes). Pre-existing since Story 9.23 (its workspace add never built the second environment); review of this closing run (blind, edge, intent layers). Mirrored into deferred-work.md.
    location: >-
      crates/zanshin-jj/src/workspace_add.rs add / add_trailers_for
    severity: low
---

<intent-contract>

## Intent

**Problem:** Ledger item 1 handed to this closing run (Story 9.51's `deferred:` item 1), verified against the code at `3da131d`: the CLI's `WorkspaceCommandEnvironment::new` (`cli/src/cli_util.rs:962-991` in the registry copy `jj-cli-0.46.0`) loads `[template-aliases]` (`load_template_aliases` :3518) and parses `revsets.short-prefixes` (`reload_revset_expressions` :1083 → `load_short_prefixes_expression` :1120-1141, falling back to `revsets.log`) for EVERY workspace command, so a non-table `template-aliases` layer, a non-string `revsets.short-prefixes` or one that does not parse refuses every CLI command, and the alias-entry warnings and short-prefixes diagnostics print on every command. Zanshin's `snapshot::CommandEnv::load` (`crates/zanshin-jj/src/snapshot.rs:339-348`) loads neither; `template::Templates` loads both lazily with the first template a verb parses (`template.rs:124-169`), so only the template-rendering verbs refuse or warn.

**Approach:** `CommandEnv::load` builds the template half of the start-up environment in the CLI's order and refuses there, before any lock; the loaded alias map and the parsed short-prefixes expression travel in the call's context into `Templates`, which stops loading them itself. Every verb that runs the start-up environment (the precondition verbs, `update-stale`, the creation paths, the conversion) then refuses and warns as the CLI does.

## Boundaries & Constraints

**Always:**
- CLI order inside `CommandEnv::load` (`cli_util.rs:964-990`): `[fileset-aliases]` → `[revset-aliases]` (with builtin redefinitions) → `[template-aliases]` → `immutable_heads()` parse → `revsets.short-prefixes` parse. Each load's warnings recorded once per call (`Warnings::record_load`); the first fault in that order refuses.
- Refusals are the existing texts: a non-table layer — `build_aliases_map`'s "<path>: template-aliases: Expected a table, but is <type>"; a non-string key — `config::revsets_short_prefixes`'s value error; a parse failure — "Invalid `revsets.short-prefixes`: <parse reason>" (today's text from `template.rs:152-154`). All are `PreconditionError::Config` → FFI `jj.config_error` (`envelope.rs::map_precondition_err`), with op head unchanged.
- Warnings: bad alias entries → `ConfigAliasInvalid` "Failed to load `template-aliases.<decl>`: …" (`Load::TemplateAliases`); short-prefixes parse diagnostics → `RevsetDiagnostic` under "In `revsets.short-prefixes`", recorded once per call under a new `Load::ShortPrefixes` — the graph walk's own parse of its `short_prefixes` argument (`graph.rs:211-219`) records under the same load when its text equals the effective `revsets.short-prefixes` text (the GUI passes `log_defaults`' value: the CLI's `jj log` prints the diagnostic once), and as today otherwise.
- `Templates` renders exactly as today with the start-up map and expression: id-prefix context = `IdPrefixContext::new(ext)` disambiguated within the start-up expression (none when the text is empty). `workspace add` keeps rendering for the NEW workspace: it re-parses `revsets.short-prefixes` for the new workspace's name and root when it renders trailers (today's behavior; the CLI's `for_workable_repo` env, `add.rs:193`), its diagnostics under the same once-per-call load.
- Default config: no new warning, no refusal, no expected value changes in any existing test or oracle scenario.

**Never:**
- No other start-up item (`ui.conflict-marker-style` is already refused by jj-lib's working-copy load — Story 9.27; the `trunk()` fallback stays its own ledgered deferral); no start-up environment for verbs that build none today (`workspace_root`, `log_defaults`, `commit_contents`, …).
- No new error or warning code; no FFI schema change; no UI or MCP code.
- No change to Story 9.51's spec, `epics.md`, `epic-9-context.md`, `sprint-status.yaml` or existing deferred-work.md bullets beyond marking this item resolved; never regenerate fixtures; never lower `coverage-baseline.txt`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Broken alias table, non-template verb | repo config `template-aliases = 1`; `abandon(@)` | refused, op head unchanged | `PreconditionError::Config` "…template-aliases: Expected a table, but is integer" |
| Unparsable short-prefixes, non-template verb | `revsets.short-prefixes = '('`; `abandon(@)` | refused, op head unchanged | `PreconditionError::Config` starting "Invalid `revsets.short-prefixes`: " |
| Non-string short-prefixes | `revsets.short-prefixes = 1`; `abandon(@)` | refused, op head unchanged | `PreconditionError::Config` naming `revsets.short-prefixes` |
| Bad alias entry, non-template verb | `template-aliases.'x(' = '1'`; `abandon(@)` | succeeds; exactly one `ConfigAliasInvalid` "Failed to load `template-aliases.x(`: …" | — |
| Diagnosed short-prefixes, non-template verb | `revsets.short-prefixes = 'diff_contains("x")'`; `abandon(@)` | succeeds; exactly one `RevsetDiagnostic` starting "In `revsets.short-prefixes`\n" | — |
| Same, graph walk | same config; `walk_graph` with `short_prefixes` = that text | exactly one such `RevsetDiagnostic` | — |
| Template verb with bad alias entry | `TRAILERS` + `'x('`; `describe` | one `ConfigAliasInvalid` (existing test `tests/templates.rs:390`) | — |

</intent-contract>

## Code Map

CLI anchors in `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-cli-0.46.0/src` (`../jj` sits behind the pin).

- `cli_util.rs` -- `WorkspaceCommandEnvironment::new` :961-991 (order); `reload_revset_expressions` :1083-1087; `load_short_prefixes_expression` :1120-1141; `load_template_aliases` :3518-3524; `workspace_helper_with_stats` :473-478 (env before the lock); `for_workable_repo` :836-847.
- `crates/zanshin-jj/src/snapshot.rs` -- `CommandEnv` :311-349 (struct, doc, `load`); `VerbContext` :354-385 (add the template startup next to `immutable`, `new` moves it from the env); `PreconditionError::Config` doc :191-197 (names the start-up loads); inline test using `CommandEnv::load` :941.
- `crates/zanshin-jj/src/template.rs` -- module doc :31-34 (the lazy divergence paragraph goes); `Templates` :66-169 (`Env` drops `aliases` and the short-prefixes parse; `new`/`at` take the start-up data); the alias load :137-139 and short-prefixes parse :142-156 move into new `pub(crate)` loaders called by `CommandEnv::load`; `parse_commit` :212 uses the start-up alias map; inline tests :425-754 (`Fixture` :434-471 builds the start-up data; `the_environment_warns_once_and_diagnostics_are_template_warnings` :708 and `a_broken_short_prefixes_revset_refuses` :744 re-aimed at the loaders).
- `crates/zanshin-jj/src/revset.rs` -- `revset_config` :249-257 (records `Load::RevsetAliases`); `parse_diagnosed_at` :350-365 (extends the sink directly — parse into a local `Warnings` and `record_load` it); `immutable_expression` (called today via `op_support::immutable_user_expression` :90-97; `CommandEnv::load` calls `revset_config` and `immutable_expression` itself to fit the template-alias load in between).
- `crates/zanshin-jj/src/warning.rs` -- `Load` :198-212 (add `ShortPrefixes`; reword `TemplateAliases`' doc); `record_load` :233.
- `crates/zanshin-jj/src/graph.rs` -- `LogParse::new` :201-230 (short-prefixes parse :211-219 — record-once when the text equals `config::revsets_short_prefixes(&config)`).
- Callers to re-wire (pass the start-up data instead of letting `Templates` load): `mutate.rs:831`, `:990`; `commit.rs:180`; `squash_split.rs:355`, `:428`, `:601`; `push.rs:907` (`Planner` :700-713, built :1222 — add a field); `workspace_add.rs:200-205` (`Templates::at` with a short-prefixes re-parse for the new workspace).
- Other `CommandEnv::load` callers (behavior follows; docs only): `repo.rs:372` `start_call`; `creation.rs:141` `workable_env` (module doc :18 "not the template and short-prefixes parses" becomes wrong); `convert.rs:616`.
- Docs: `crates/zanshin-jj/src/repo.rs:995`, `:1204` (template-verb `# Errors` bullets: the table/short-prefixes clause now applies at start-up to every verb); `docs/rust-error-codes.md` :57 (last clause of `jj.config_error`: every start-up-environment verb), :133 (`jj.revset_diagnostic` where-column: the start-up short-prefixes parse), :180, :182, :191 (deviation bullets — remove/rewrite: ported for every start-up-environment verb).
- Tests: `crates/zanshin-jj/tests/templates.rs` -- `base`/`Fx::set` :48-150 helpers (repo-config set via `zanshin_jj::config_set`); `assert_config_refusal` :80-89 matches `MutateError::Config` only — the start-up refusals arrive as `MutateError::Precondition(PreconditionError::Config)`. `crates/zanshin-jj/tests/warnings.rs:315-350` -- prior art for once-per-call diagnostics (`diff_contains` is deprecated → a diagnostic).
- Oracle: `crates/zanshin-parity/tests/oracle/scenarios.rs` (setup consts :236-262, Story 9.51 block from :1676, `abandon_wc` :556-563), `main.rs` `parity!` list :38-195 + pin `SCENARIO_IDS.len() == 154` :207.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/warning.rs` -- add `Load::ShortPrefixes`; update `TemplateAliases` doc -- once-per-call recording of the start-up parse.
- `crates/zanshin-jj/src/template.rs` -- a start-up struct (alias map + optional short-prefixes expression) with two `pub(crate)` loaders (aliases; short-prefixes for a workspace name/root); `Templates` takes it, `Env` no longer loads either; module doc + inline tests updated -- one load per call, at start-up.
- `crates/zanshin-jj/src/snapshot.rs` -- `CommandEnv::load` in the CLI order, holding the start-up struct; `VerbContext` carries it; docs -- every start-up-environment verb refuses and warns like the CLI.
- `crates/zanshin-jj/src/graph.rs` -- record-once of the graph's short-prefixes diagnostics when its text is the effective one -- no doubled warning on `walk_graph` / `graph_topology`.
- `crates/zanshin-jj/src/{mutate,commit,squash_split,push,workspace_add,creation,repo}.rs` -- re-wire `Templates` construction; `workspace_add` re-parses short-prefixes for the new workspace; doc fixes -- unchanged rendering.
- `crates/zanshin-jj/tests/templates.rs` -- one test per I/O row 1-6 (non-template verb `abandon`; op head unchanged on refusals; exact warning counts) -- the ledger's witness.
- `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` -- scenarios `abandon_broken_template_aliases` (`config set --repo template-aliases 1`) and `abandon_broken_short_prefixes` (`config set --repo revsets.short-prefixes '('`), both sides refuse; pin 154 → 156 -- CLI comparison.
- `docs/rust-error-codes.md` -- the lines in the Code Map -- the deviation is closed.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- at finalisation mark the `## Surfaced in Story 9.51` bullet for this item resolved with the fix commit (no new bullet unless a NEW finding is deferred) -- ledger hygiene.

**Acceptance Criteria:**
- Given every existing zanshin-jj, zanshin-ffi, zanshin_core and oracle test, when they run on the final tree, then each passes with no expected value changed.
- Given the two new oracle scenarios, when the oracle runs, then both match the pinned CLI (both refuse, repo state identical) and no ledger row is added.
- Given `cargo make test` on the final tree, then it exits 0 (clippy pedantic, fmt, doctests, Dart steps, cargo deny, coverage ratchet with no baseline lowered) and any raised `coverage-baseline.txt` is committed with the code.
- Given the end of the run, then `git status --porcelain` is clean and every commit ends with the required co-author trailer and was made with `--no-gpg-sign`.

## Spec Change Log

- **2026-10-20 (implementation) — one existing expected value changed, CLI-verified.** `tests/warnings.rs` `immutable_heads_diagnostics_warn_once_per_call` (`immutable_heads()` = `diff_contains("zzz") & none()`, `walk_graph("@", …, "")`) now sees TWO `jj.revset_diagnostic`s, not one: the start-up `revsets.short-prefixes` parse falls back to the default `revsets.log` = `builtin_log()`, which expands `immutable_heads()`, so its deprecation diagnostic is reported again under "In `revsets.short-prefixes`". The pinned CLI (`crates/zanshin-parity`'s `jj log -r @` on the same config) prints exactly these two warnings in this order, so the AC "no expected value changed" yields to CLI parity for this one test; the assertion pins both context lines. No default-config expectation changed. Also: `op_support::immutable_user_expression` lost its last production caller (`CommandEnv::load` now calls `revset_config` / `immutable_expression` itself) and was removed; its three test callers use `CommandEnv::load(..).immutable`.

## Review Triage Log

### 2026-10-20 — Review pass
- verdicts: 24 findings — high 0, medium 0, low 15, false 7, maybe-false 2
- findings:
  - `[low]` `[patch]` (verification-gap) the graph walk's "override differs from the effective short-prefixes" branch is untested — added `the_graph_walk_with_a_different_short_prefixes_override_warns` (tests/templates.rs).
  - `[low]` `[patch]` (verification-gap) the CLI start-up order (template aliases between revset aliases and `immutable_heads()`) is unpinned — added `the_start_up_warnings_come_in_the_clis_order` and the precedence test `a_broken_template_alias_table_refuses_before_immutable_heads`.
  - `[low]` `[reject]` (verification-gap) no test distinguishes `workspace add`'s short-prefixes re-parse for the new workspace — only a trailers template rendering `shortest()` of a commit inside exactly one workspace's `@`-based set differs; the code keeps the pre-change behaviour and the test fixture would be contrived.
  - `[low]` `[patch]` (blind) two older deferred-work.md bullets (start-up steps :438, clone/init :446-447) and the resolved bullet's follow-up are now stale — annotated with the d8e4c60 resolution at finalisation (they record this same item).
  - `[low]` `[patch]` (blind) `walk_graph` / `graph_topology` `# Errors` and the `jj.revset_parse_error` row do not say the effective short-prefixes now refuses at start-up — Precondition bullets and the registry sentence added.
  - `[low]` `[reject]` (blind) the graph walk re-parses the text the start-up parsed (dead error arm, `.ok()` on the accessor) — a cheap parse; reusing the start-up expression means threading `VerbContext` into `LogParse`, more plumbing than the duplicate parse costs.
  - `[low]` `[defer]` (blind) `workspace add` builds no second start-up environment, so its warnings print once where the CLI prints them twice — pre-existing since Story 9.23 (it never built `for_workable_repo`'s environment); deferred, mirrored.
  - `[low]` `[patch]` (blind) a broken `revsets.log` (short-prefixes unset) now refuses every verb, unwitnessed — added `an_unparsable_revsets_log_fallback_refuses_every_verb`; the "Invalid `revsets.short-prefixes`" text is the CLI's for the fallback too (`cli_util.rs:1133-1137`).
  - `[low]` `[reject]` (blind) only `abandon` witnesses the start-up refusal; creation paths, conversion, update-stale, graph_topology are not — all reach the same `CommandEnv::load`; per-path tests would only re-test the shared function.
  - `[low]` `[patch]` (blind) the oracle never compares I/O rows 4 and 5 (warnings) against the CLI — added `abandon_bad_template_alias_entry` and `abandon_diagnosed_short_prefixes` (both match the pinned CLI incl. the warning count; pin 158).
  - `[false]` `[reject]` (blind) the spec's `cargo test -p zanshin-jj --lib template snapshot` command is invalid — the fix would edit this build's spec; the run used `cargo test -p zanshin-jj --lib -- template snapshot` (24 passed).
  - `[false]` `[reject]` (blind) Change Log incomplete; inline tests now probe an unreachable `ui.conflict-marker-style = 1` — the tests still witness the property they pin (an empty key builds no environment: a broken key the environment reads does not refuse); the Change Log fix would edit the spec.
  - `[low]` `[reject]` (blind) `Templates` still rebuilds `[revset-aliases]` / `[fileset-aliases]` lazily — pre-existing Story 9.51 design, warnings deduped by `record_load`; carrying them too is plumbing beyond the item.
  - `[false]` `[reject]` (blind) line citations wrong (`:961` vs `:962`, `IN_SHORT_PREFIXES` `:1139`) — checked: `fn new` is at :961 and the context line at :1139 in jj-cli-0.46.0; the one stale v0.44 range (`jj.config_alias_invalid`, `cu:936-966`) was patched to `cu:961-991`.
  - `[low]` `[reject]` (edge) the start-up `revset_config` fault now converts via `From<ConfigError>`, dropping the doubled "config error: " prefix from the reason — the same conversion the fileset-alias load in that function already used; the context text gets cleaner, no consumer or test pins the prefix.
  - `[maybe-false]` `[reject]` (edge) config edited between `start_call` and `LogParse::new`'s reload could swallow an override's diagnostics — needs a concurrent config write inside one call (the worker serializes calls); if true only low.
  - `[low]` `[defer]` (edge) `workspace add` vs `for_workable_repo` double warnings — same root as the blind row; deferred there.
  - `[false]` `[reject]` (edge) AC "no expected value changed" vs the changed `immutable_heads_diagnostics_warn_once_per_call` — the Spec Change Log records it with the pinned CLI's output; the fix would edit the spec.
  - `[low]` `[reject]` (edge) template verbs' broken-table / short-prefixes refusal moved from `MutateError::Config` to `Precondition(Config)` — the spec's Always mandates it; FFI maps both to `jj.config_error` with the reason in `context`.
  - `[false]` `[reject]` (intent) no `## Auto Run Result` — written at finalisation.
  - `[low]` `[reject]` (intent) tests reach the change through two verbs only, not FFI — same as the blind "only abandon" row; `map_precondition_err` is the existing, tested mapping.
  - `[maybe-false]` `[reject]` (intent) warning rows not compared with the CLI — patched via the two oracle scenarios above (they match); the remaining CLI comparison of warning TEXT is outside the oracle's design (count only).
  - `[false]` `[reject]` (intent) changed `warnings.rs` expectation contradicts the AC — same as the edge row.
  - `[false]` `[reject]` (intent) scope beyond the item (orphan removal, graph dedup, helper extraction, fixture swaps, doc rewrites) — each follows from the fix (orphaned fn, doubled warnings, clippy line limit, the start-up now refusing the old fixture input).

## Design Notes

- **Why the start-up data travels instead of `Templates` re-loading it:** a second load would re-emit the short-prefixes diagnostics (parse warnings are not record-once today) and double the work; carrying the parsed expression is what the CLI does (`env.short_prefixes_expression` feeds `new_id_prefix_context`).
- **`workspace add`:** the CLI builds a second environment for the new workspace (`for_workable_repo`), whose `@` in `revsets.short-prefixes` names the new workspace. Today's Zanshin already parses it for the new workspace at render time; this run keeps that, so no rendering changes (the immutable set stays the old workspace's — Story 9.51's rejected review row).
- **Graph dedup rule:** the immutable-heads parse already shows the pattern (`Load::ImmutableHeads`, `tests/warnings.rs` `immutable_heads_diagnostics_warn_once_per_call`); comparing texts keeps the warnings of a caller-supplied override that differs from the config.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test templates --test warnings --test graph --test graph_topology` -- expected: all pass.
- `cargo test -p zanshin-jj --lib template snapshot` -- expected: all pass.
- `cargo test -p zanshin-parity --test oracle` -- expected: all pass, 156 scenarios, no new ledger row.
- `cargo make test` (unpiped, synchronous, long timeout) -- expected: exit 0.

## Auto Run Result

Status: done

**Items.**
- **Item 1 (`[template-aliases]` and `revsets.short-prefixes` loaded only by template-rendering verbs)** — fixed (d8e4c60; review witnesses 1f173fd). Verified real at `3da131d`: `CommandEnv::load` loaded neither, `Templates` loaded both lazily. Now `CommandEnv::load` runs the CLI's start-up order (fileset → revset → template aliases → `immutable_heads()` → `revsets.short-prefixes`, falling back to `revsets.log`) before any lock, for every verb that builds the start-up environment (every pre-verb-snapshot verb, `update-stale`, `init`/`clone`, the conversion). A non-table `template-aliases`, a non-string or unparsable short-prefixes refuses as `PreconditionError::Config` → `jj.config_error`, nothing written; alias-entry warnings and short-prefixes diagnostics arrive once per call. The ledger's witness: `a_broken_template_alias_table_refuses_every_verb` (`abandon`), plus the oracle scenarios `abandon_broken_template_aliases` / `abandon_broken_short_prefixes`.

**Summary.** The template half of the start-up environment (`template::TemplateStartup`: alias map + parsed short-prefixes expression) is built by `CommandEnv::load`, travels in `VerbContext` into `Templates`, which no longer loads either. A new once-per-call `Load::ShortPrefixes` dedups the graph walk's parse of the same text (an override that differs still warns) and `workspace add`'s re-parse for the new workspace. `op_support::immutable_user_expression` lost its last caller and was removed. One existing expectation changed, CLI-verified (Spec Change Log).

**Files changed.**
- `crates/zanshin-jj/src/snapshot.rs` — `CommandEnv::load` in the CLI order; `CommandEnv` / `VerbContext` carry `template_startup`; docs.
- `crates/zanshin-jj/src/template.rs` — `TemplateStartup`, `load_aliases`, `load_short_prefixes`; `Templates::new`/`at` take the start-up data; module doc; inline tests.
- `crates/zanshin-jj/src/revset.rs` — `parse_short_prefixes` (record-once), `IN_SHORT_PREFIXES`.
- `crates/zanshin-jj/src/warning.rs` — `Load::ShortPrefixes`.
- `crates/zanshin-jj/src/graph.rs` — record-once when the walk's text is the effective one.
- `crates/zanshin-jj/src/{mutate,commit,squash_split,push,workspace_add,op_support,creation,repo}.rs` — re-wiring, `add_trailers_for` helper (new-workspace short-prefixes re-parse), orphan removal, docs.
- `crates/zanshin-jj/tests/templates.rs` — 9 start-up tests (refusals, warnings once, order, precedence, `revsets.log` fallback, graph equal/override); `tests/warnings.rs` — one CLI-verified expectation.
- `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` — 4 `abandon_*` scenarios (two refusals, two warning-count), pin 154 → 158.
- `docs/rust-error-codes.md` — `jj.config_error`, `jj.revset_parse_error`, `jj.config_alias_invalid`, `jj.revset_diagnostic` rows; three deviation bullets removed.
- `coverage-baseline.txt` — `template.rs` 99.61, `workspace_add.rs` 98.58 (raised).
- `deferred-work.md` — item resolved; the two older bullets recording the same gap annotated; new section with this run's one deferral.

**Review.** 24 findings: high 0, medium 0, low 15, false 7, maybe-false 2 (triage log above).
- Patched (1f173fd, 6 low entries): graph override-branch witness; start-up order + precedence witnesses; `revsets.log` fallback refusal witness; oracle warning-count scenarios for I/O rows 4-5; `walk_graph`/`graph_topology` `# Errors` and the `jj.revset_parse_error` row; the stale v0.44 citation; plus the stale ledger bullets annotated at finalisation.
- Deferred (low, mirrored): `workspace add` builds no second start-up environment for the new workspace (the CLI's `for_workable_repo`), so its warnings print once where the CLI prints them twice — pre-existing since Story 9.23.
- Rejected, reasons in the triage log: the workspace-add re-parse witness (contrived), the graph's duplicate parse (cheap vs plumbing), per-path refusal tests (one shared function), the lazy revset/fileset rebuild in `Templates` (pre-existing design), the dropped "config error: " prefix (matches the sibling fileset load), the refusal-variant move (spec-mandated), the concurrent-config-edit race (calls are serialized), and the false claims (spec-edit fixes, correct citations, artifact state mid-run, follow-on scope).

**Follow-up review recommendation:** false — this first pass patched 0 high and 0 medium entries (patched counts: high 0, medium 0, low 6).

**Verification.**
- `cargo test -p zanshin-jj --test templates --test warnings --test graph --test graph_topology`: all pass before the review patches; `--test templates` passes after them (implementer run), and the whole suite again inside the gate below.
- `cargo test -p zanshin-jj --lib -- template snapshot`: 24 passed.
- `cargo test -p zanshin-parity --test oracle`: 165 passed before the review patches (156 scenarios); the four `abandon_*` scenarios and the 158 pin pass after.
- `cargo make test` (unpiped, synchronous): exit 0 after the implementation (implementer run) and exit 0 after the review patches (932 s, coverage ratchet included, baseline not lowered).
- Matrix audit: rows 1-6 by the `abandon` / `walk_graph` tests in `tests/templates.rs`, row 7 by the existing `tests/templates.rs` bad-alias-entry test; all ran and passed.

**Residual risks.**
- Every start-up-environment verb now parses one more revset (`revsets.log` by default); a broken `revsets.log` now refuses every such verb, as the CLI does — GUI reads (`status`, `walk_graph`) included.
- `crates/zanshin-ffi/src/repo.rs:1043` (lifted into `bindings.dart`) still describes the broken-table / short-prefixes refusal on the template verbs only; true, but now it applies to every verb (left: the change needs `cargo make codegen`).
- The implementer's manual CLI check created `~/.config/jj/repos/40cd734bca24f37d9d0c` (jj's repo-config location) and reports having deleted it afterwards.

**Commits.** ee0b90e (spec), d8e4c60 (fix), 601c03e (ledger resolved), 1f173fd (review patches), and the finalisation commit of this spec and deferred-work.md.

