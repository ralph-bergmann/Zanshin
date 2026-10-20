---
title: 'Story 9.51 closing run — `[template-aliases]` and `revsets.short-prefixes` load at every command start'
type: 'bugfix'
created: '2026-10-20'
status: 'in-progress'
baseline_revision: '3da131d43152ea2cc992199027fd3cc563fc6876'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred: []
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

## Review Triage Log

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
