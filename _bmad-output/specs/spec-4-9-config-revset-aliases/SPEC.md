---
id: SPEC-4-9-config-revset-aliases
companions:
  - 'jj-config-reference.md'
  - '../../project-context.md'
  - '../spec-4-8-log-rows-cli-parity/SPEC.md'
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# Story 4.9: Honor jj config revset aliases

## Why

Story 4.8 hardcodes jj's *builtin* revset aliases (`trunk()`, `immutable_heads()`, …), but jj lets every user override them and define their own in `[revset-aliases]` of the jj config (user-wide or per repo). Those aliases are not display sugar: `immutable_heads()` decides the ◆/immutable flag, the default log view's contents, and (Epic 9) the rewrite guard; `trunk()` anchors fork workflows; custom aliases (`wip()`, `mine()`) appear in the revsets users type. A user with a customized config therefore sees the jj CLI and Zanshin disagree — in exactly the recognizability dimension Story 4.8 exists for — and gets parse errors for aliases their CLI accepts. This story closes spec-4-8's open question so the gap is not forgotten. **Depends on 4-8** (its builtin-alias table is the seam this story makes config-fed).

## Capabilities

- **CAP-1**
  - **intent:** Every revset `zanshin-jj` parses (graph slice incl. immutable containment, `prioritize`, `short_prefixes`, plain revset resolution) resolves `[revset-aliases]` from the repo's effective jj config — overridden builtins and user-defined aliases behave exactly as the jj CLI resolves them.
  - **success:** Tests with an injected config (via the `JJ_CONFIG` pin) show a `trunk()` override flipping the `immutable` flag and default-view contents, and a custom alias (`wip()`) evaluating instead of erroring — CLI-equal resolution.

- **CAP-2**
  - **intent:** The config-resolved values of `revsets.log`, `revsets.log-graph-prioritize`, `revsets.short-prefixes`, and `ui.log-synthetic-elided-nodes` are readable per repo handle, so the UI pre-fills the defaults the user's CLI would actually apply instead of builtin constants (FR-JJ-17: pre-filled, still editable).
  - **success:** A repo-config override of `revsets.log` is what the read returns; absent overrides return the builtin defaults 4-8 ships.

## Constraints

- **CLI precedence and error behavior, mirrored at the pin (v0.42.0):** layer order builtin defaults < user config (file discovery / `JJ_CONFIG` override) < repo config (`.jj/repo/config.toml` indirection); no `--config` CLI-arg layer (Zanshin has no CLI args). A malformed config or alias surfaces an error the way the CLI does — never a silent fall-back to builtins.
- **Coherency over caching:** config is re-read per operation — config files change externally and the op-heads watcher does not cover them. If measured cost forces per-handle caching, design and document the invalidation; don't imply it.
- **One resolution path:** config loading lives entirely in `zanshin-jj` (sole `jj_lib` importer); the 4-8 builtin table in `build_aliases_map` ([revset.rs:146](../../../crates/zanshin-jj/src/revset.rs)) becomes the default layer that config layers override — every parse site goes through it, no second code path. `zanshin-mcp` inherits the behavior for free.
- **Tests keep pinning `JJ_CONFIG`/`GIT_CONFIG_GLOBAL`** (existing suite property) — the pin is also the injection lever for test configs.

## Non-goals

- Template aliases / custom log templates — the GUI replaces the CLI's template UX; 4-8's row catalog is the fixed content contract.
- A general settings surface beyond CAP-2's four values; config writing/editing from Zanshin.
- The `--config`/`--config-file` command-line layer; fileset aliases.
- New FFI surface beyond CAP-2 — alias resolution acts inside existing calls, it does not cross the wire.

## Success signal

A user who has customized `trunk()` or `immutable_heads()` — or defined their own aliases — sees Zanshin's graph agree with their `jj log`: same ◆ set, same default view, their aliases accepted; proven by injected-config tests asserting CLI-equal resolution and by the effective-defaults read returning what their CLI would use.

## Assumptions

- jj-lib 0.42 exposes the needed machinery without porting CLI code wholesale: `StackedConfig`/`ConfigLayer`/`ConfigSource` (`lib/src/config.rs`, verified in the vendored crate) and `RevsetAliasesMap` injection into `RevsetParseContext` (already in use). The CLI-side file-discovery order (`ConfigEnv`, `cli/src/config.rs` @ v0.42.0) is replicated as observable behavior, not linked.
