---
title: 'Story 9.51: jj templates — `commit_trailers`, `draft_commit_description`, `git_push_bookmark`'
type: 'feature'
created: '2026-10-20'
status: 'done'
baseline_revision: '455b34d1472e2daf05ca9e6f90ba80247afaea92'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: [oversized]
deferred:
  - summary: >-
      Zanshin loads `[template-aliases]` and `revsets.short-prefixes` only when a verb parses a template, while the CLI loads both at the start of every workspace command, so a broken `template-aliases` table or short-prefixes revset refuses every CLI command but only Zanshin's template-rendering verbs.
    evidence: |-
      cli/src/cli_util.rs `WorkspaceCommandEnvironment::new` loads `load_template_aliases` (:3518) and `reload_revset_expressions` → `load_short_prefixes_expression` (:1084, :1115-1136) @ v0.46.0 for every workspace command; Story 9.51 builds its template environment lazily (crates/zanshin-jj/src/template.rs). docs/rust-error-codes.md :179 recorded the template-aliases load as "not ported".
    location: >-
      crates/zanshin-jj/src/template.rs; crates/zanshin-jj/src/snapshot.rs CommandEnv::load
    severity: low
  - summary: >-
      A `jj.template_diagnostic` carries the CLI's context line, the diagnostic and its source chain, but not the CLI's template-position rendering (the `-->` span over the template text) — the same deviation `jj.short_prefixes_failed` documents.
    evidence: |-
      cli/src/command_error.rs `print_parse_diagnostics` renders each `TemplateParseError` with its pest span @ v0.46.0; crates/zanshin-jj/src/warning.rs `parse_diagnostics` writes `error_chain_lines` only.
    location: >-
      crates/zanshin-jj/src/template.rs Templates::parse_commit; crates/zanshin-jj/src/warning.rs parse_diagnostics
    severity: low
  - summary: >-
      The template function `config("<name>")` reads the repo's settings, which hold Zanshin's stack — jj-lib's defaults, Zanshin's builtin layer and the jj-cli template defaults — not every jj-cli default, so `config("ui.color")` (and any other key only jj-cli's `misc.toml` / `colors.toml` / … define) renders empty where the CLI renders its default.
    evidence: |-
      cli/src/template_builder.rs `config` function (:2645-2676) reads `language.settings()` @ v0.46.0; crates/zanshin-jj/src/config.rs `template_defaults_layer` copies only `[template-aliases]`, `[diff.color-words]`, `[diff.git]` and four `templates.*` keys.
    location: >-
      crates/zanshin-jj/src/config.rs template_defaults_layer
    severity: low
  - summary: >-
      The GUI round trip "show `squash_plan`'s text, pass the edited text back as `message`" re-applies `templates.commit_trailers` (the `-m` arm), so with trailers configured a trailer the user deleted comes back, and an unchanged plan text whose last paragraph is no trailer block (destination trailered, source not) gains a second trailer — where the CLI's editor flow writes the edited text as is.
    evidence: |-
      crates/zanshin-jj/src/squash_split.rs `squashed_description` (Exact arm → `Templates::add_trailers`) and `squash_plan`; CLI squash.rs:358-400 @ v0.46.0 adds trailers to `-m` text but never to the text the editor returns. Example: B = "B\n\nSOB\n", C = "C\n": plan "B\n\nSOB\n\nC\n", round trip writes "B\n\nSOB\n\nC\n\nSOB\n", `squash` without message writes the plan text. Review of Story 9.51 (blind + edge layers).
    location: >-
      crates/zanshin-jj/src/squash_split.rs squashed_description; crates/zanshin-jj/src/repo.rs Repo::squash / squash_plan docs
    severity: medium
---

<intent-contract>

## Intent

**Problem:** Zanshin renders no jj templates. With a user template the CLI writes something else than Zanshin, silently: `templates.commit_trailers` is never applied (`describe`, `new`, `commit`, `squash`, `split`, `workspace add`), the "editor saved unchanged" text of `squash`/`split`/`squash_plan` ignores `templates.draft_commit_description` and `template-aliases.default_commit_description`, and `git push --change` refuses any `templates.git_push_bookmark` other than the builtin default (deferred-work I1–I4).

**Approach:** Spike done in planning (2026-10-20, see Design Notes): jj-cli 0.46.0's own engine (`CommitTemplateLanguage`, `template_builder::parse`, `TemplateRenderer`) builds and renders from Zanshin's start-up environment. So `zanshin-jj` takes `jj-cli` as a dependency, a new `template` module owns one commit-template renderer with the CLI's language, aliases, id-prefix context and errors, and each verb applies the three templates at the CLI's step with the CLI's rules. `templates.new_description` comes along as the one-liner the epic allows.

## Boundaries & Constraints

**Always:**
- The CLI at v0.46.0 is the spec (registry copy `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-cli-0.46.0/src`; `../jj` sits at v0.44): `description_util.rs` `parse_trailers_template` :433, `add_trailers_with_template` :449, `add_trailers` :480, `description_template` :494, `combine_messages_for_editing` :~356-405 (trailers block), `cleanup_description_lines` :164; `cli_util.rs` `commit_template_language` :1199-1215, `parse_template` :1180-1195, `revset_parse_context` :1048-1070, `new_id_prefix_context` :1072-1079, `load_short_prefixes_expression` :1115-1136; `command_error.rs` `From<TemplateParseError>` :708-716, `From<TrailerParseError>` :530.
- **The renderer:** `CommitTemplateLanguage::new(repo, path_converter, workspace_name, revset_parse_context, id_prefix_context, immutable_expression, conflict_marker_style, &[] /* no extensions, like stock jj */)` + `template_builder::parse(.., text, &template_aliases)`. Inputs: path converter `Fs { cwd: root, base: root }` (Zanshin's GUI convention, as `revset.rs:347`); the verb's workspace name (for `workspace add`: the NEW workspace's name and root); revset aliases + `user.email` from `revset::revset_config`; `ctx.immutable` (`::(immutable_heads()|root())`, same as `immutable_expression()`); `ui.conflict-marker-style` via the existing config accessor (`config.rs:1261-1278`); id-prefix context = `IdPrefixContext::new(extensions)` disambiguated within `revsets.short-prefixes` (fallback `revsets.log`; empty = none), parsed like the CLI; template aliases = `[template-aliases]` of the effective stack through `revset::build_aliases_map::<TemplateAliasParser>` (CLI's per-entry "Failed to load `template-aliases.<decl>`" warnings, `ConfigAliasInvalid`, recorded once per call via a new `Load::TemplateAliases`). The repo passed is the transaction's `tx.repo()` (MutableRepo), like `WorkspaceCommandTransaction::commit_template_language`.
- **Builtin defaults come from jj-cli itself:** the `[template-aliases]` table and the `templates.{commit_trailers, draft_commit_description, git_push_bookmark, new_description}` keys are taken from `jj_cli::config::default_config_layers()` into a `ConfigSource::Default` layer right after `BUILTIN_CONFIG_TOML` in `config::load_raw`, so they are verbatim by construction and move with the pin. `templates.git_push_bookmark` leaves `BUILTIN_CONFIG_TOML`. No other `[templates]` key is copied.
- **When each template applies (CLI rule per verb, every verb here passes `-m` or none; `--editor` does not exist):**
  - `commit_trailers` is parsed only when the key is non-empty (`parse_trailers_template`); trailers are added via `write_hidden` of the detached builder → render → `jj_lib::trailer::parse_trailers` → existing `op_support::apply_trailers` (dedup against the description's own trailers).
  - `describe`: when the given description is non-empty (describe.rs:151-163; `use_editor` is false). An empty description gets none.
  - `new_change`: no `-m` in Zanshin, so the description is `templates.new_description` rendered on the hidden new commit + `text_util::complete_newline` (empty key → `""`, no parse); then trailers when non-empty (new.rs:214-236).
  - `commit`: trailers when the joined `-m` text is non-empty (commit.rs:148-153).
  - `workspace add`: trailers when the joined `-m` text is non-empty (add.rs:257-265).
  - `squash`: after `squash_commits`, on its detached builder (squash.rs:356-400). Exact (`-m`) / use-destination / single combined description: empty → as is; else trailers. Editor arm (`try_combine_messages` = None): `combine_messages_for_editing` WITH the CLI's "JJ: Trailers not found in the squashed commits:" block (trailers of the abandoned sources + destination filtered out), set on the builder, `write_hidden`, then the editor-saved-unchanged text = `cleanup_description_lines(render(draft_commit_description, temp_commit))` (the CLI's intro line is a `JJ:` line and vanishes in cleanup).
  - `squash_plan`: returns exactly the text `squash` writes in the editor arm — so it runs `squash_commits` and the same description step on its throwaway transaction (dropped: no operation; hidden commit objects may reach the store, as the CLI's do).
  - `split` (split.rs:302-385): first commit — description = joined `-m` or the target's; trailers when non-empty. With `-m` the second keeps the target's description, no trailers. Without `-m` (the editor arm): first gets trailers if still empty; first `write_hidden`; second `set_parents` (first's hidden id), trailers, `write_hidden`; each final description = `cleanup_description_lines(render(draft_commit_description, temp))`.
  - `git push --change` (push.rs:1316-1345): each commit's bookmark name = `render(git_push_bookmark, commit)`; invalid UTF-8 → "Invalid character in bookmark name", empty → "Empty bookmark name generated"; the same name in the dry-run plan and the push. The customised-template refusal and `BUILTIN_PUSH_BOOKMARK_TEMPLATE` go.
- **Errors:** every template fault refuses before anything is written, as `MutateError::Config` → `jj.config_error`, with the CLI's text verbatim: parse error `Failed to parse template: {kind}`; `Trailers should be valid utf-8`; the `TrailerParseError` text; the two push texts above; `Invalid `revsets.short-prefixes`: …`; a non-string key / non-table alias layer (existing accessor errors). No new error code. Template parse diagnostics become warnings with context "In template expression" under a NEW 9.32 warning kind `TemplateDiagnostic` (`jj.template_diagnostic`); short-prefixes parse diagnostics use context "In `revsets.short-prefixes`" (existing `RevsetDiagnostic`).
- Default templates leave every existing oracle scenario and test result unchanged.

**Never:**
- No display templates (`log`, `op_log`, `show`, `evolog`, …), no editor, no `--editor`, no multi-revision `describe`, no `-m` for `new`; no `duplicate_description`/`revert_description` (their verbs do not exist yet — the renderer is reusable for them).
- No re-port of the template language; no template extensions; no new error code; no UI code; no MCP tool.
- Never regenerate fixtures; never lower the coverage baseline or add an `exclude_prefix`.

## I/O & Edge-Case Matrix

`T = format_signed_off_by_trailer(self)` as `templates.commit_trailers`; `SOB` = `Signed-off-by: Zanshin <zanshin@localhost>` (oracle identity).

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| describe + trailers | T; `describe(@, "T\n")` | `"T\n\nSOB\n"` | — |
| describe empty | T; `describe(@, "")` | `""` (no trailer) | — |
| trailer already present | T; `describe(@, "T\n\nSOB\n")` | unchanged text, no duplicate | — |
| new_description | `templates.new_description = '"N"'`; `new_change` | new `@` description `"N\n"`; with T also: `"N\n\nSOB\n"` | — |
| new default | defaults (+T) | `""` (no trailer) | — |
| commit + trailers | T; `commit -m T` | committed `"T\n\nSOB\n"`, new `@` `""` | — |
| workspace add | T; `workspace add -m W` | new ws `@` `"W\n\nSOB\n"` | — |
| squash -m | T; `squash -m S` | `"S\n\nSOB\n"` | — |
| squash editor arm | T; squash `@` (C) into B, no `-m` | `"B\n\nC\n\nSOB\n"`; `squash_plan` returns the same text | — |
| custom draft | `templates.draft_commit_description = 'concat("pre\n", description)'`; squash editor arm | `"pre\nB\n\nC\n"`; plan identical | — |
| split -m | T; `split -m first c.txt` | first `"first\n\nSOB\n"`, second `"C\n"` | — |
| split editor arm | T; `split c.txt`, no `-m` | first and second `"C\n\nSOB\n"` | — |
| default_commit_description | `template-aliases.default_commit_description = '"DEF\n"'`; undescribed `@`; `split x.txt`, no `-m` | both commits `"DEF\n"` (default config: both `""`) | — |
| push custom name | `git_push_bookmark = '"mine-" ++ change_id.short()'`; `push -c @` | bookmark `mine-<12 hex>` created and pushed; dry run names it | — |
| push empty name | `git_push_bookmark = '""'` | refusal, nothing written | `jj.config_error` "Empty bookmark name generated" |
| broken template | `commit_trailers = 'nope('`; describe/commit/squash/split/new(with new_description)/workspace add/push -c | refusal before any write; op head unchanged | `jj.config_error` "Failed to parse template: …" |
| bad alias entry | `template-aliases.'x(' = '1'` and a template in use | verb runs; one `ConfigAliasInvalid` warning "Failed to load `template-aliases.x(`: …" | — |

</intent-contract>

## Code Map

CLI anchors at `jj-cli-0.46.0/src` (registry); jj-lib in vendored `jj-lib-0.46.0/src`; Zanshin anchors at baseline `f546983`.

**Prior art (read-only)**
- `commands/describe.rs:140-199`, `new.rs:205-236`, `commit.rs:136-170`, `squash.rs:347-400`, `split.rs:290-390`, `workspace/add.rs:250-266`, `git/push.rs:1310-1345`; `description_util.rs` (see Always); `config/templates.toml:18-30` (template keys), `:96-114` (`builtin_draft_commit_description`), `:311` (`default_commit_description = '""'`), `:649` (`format_signed_off_by_trailer`); `config.rs:860-878` `default_config_layers`; `template_parser.rs:671-674` `TemplateAliasesMap`/`TemplateAliasParser`; `templater.rs:1149-1165` `format`/`format_plain_text`; `commit_templater.rs:139-196` language struct + `new`, `:2280-2292` the only template diagnostic ("Failed to load short-prefixes index").
- jj-lib: `commit_builder.rs:440` `DetachedCommitBuilder::write_hidden`; `trailer.rs` `parse_trailers` / `parse_description_trailers`.

**Change — `crates/zanshin-jj`**
- `Cargo.toml` + root `Cargo.toml:41-46` — add `jj-cli = { workspace = true }` to zanshin-jj `[dependencies]` with a WHY (template engine only; never `CliRunner`/`Ui`); root WHY comment no longer "test-only".
- `src/template.rs` (new) — the template environment (owned inputs listed in Always; built lazily on first parse per call), `parse_commit(repo, text, sink) -> TemplateRenderer` with diagnostics → `TemplateDiagnostic` warnings, and the ports: `add_trailers(builder…)`, `editor_text(draft render → cleanup)`, `new_description(…)`, `trailers_not_in(…)` for the squash block, `push_bookmark_name(…)`. Inline unit tests.
- `src/config.rs` — `load_raw` :880-914 adds the jj-cli-derived default layer after `BUILTIN_CONFIG_TOML` (:885-888); drop `[templates] git_push_bookmark` (:195-196) and rewrite the doc (:150-188, "Zanshin renders no template"); accessors for `templates.commit_trailers` / `draft_commit_description` / `new_description` beside `templates_git_push_bookmark` :1448-1457; test `builtin_config_layer_is_valid_toml` :1979 + a test that the derived layer holds `template-aliases.builtin_draft_commit_description` and the four keys.
- `src/warning.rs` — `WarningKind` :32-171 append `TemplateDiagnostic`; `Load` :198-205 add `TemplateAliases`; `parse_diagnostics` :308-321 takes the kind (revset callers pass `RevsetDiagnostic`).
- `src/revset.rs` — `RevsetConfig` :222-225 needs crate accessors (aliases map, user email) for the template's `RevsetParseContext`; `build_aliases_map` :494 is reused as is.
- `src/mutate.rs` — `describe` :803-835 (detach + trailers at :825-831), `new_change` :949-1012 (detach + new_description + trailers at :976-977).
- `src/commit.rs` — trailers between :176 and :177; module doc :22-24.
- `src/workspace_add.rs` — :195-201 detach + trailers (new workspace's name/root for the language).
- `src/squash_split.rs` — `plan_squash` :194-290 (decision now keeps the mode; the text is finished after `squash_commits`), `squash` :340-395 (description step at :371), `squash_plan` :404-420 (runs `squash_commits` + the same step on its dropped tx), `split` :519-550 and `split_builders` :570-620 (CLI order above); module doc :13-28.
- `src/op_support.rs` — `combine_messages_for_editing` :332 (+ its doc :329-331), `combined_editor_text` :377 (callers change), `apply_trailers` :438 becomes wired (module doc :34-36), `cleanup_description_lines` :351 reused.
- `src/push.rs` — `BUILTIN_PUSH_BOOKMARK_TEMPLATE` :316 and the refusal :905-912 go; name at :918-921 from the template; module doc :26-28.
- `src/repo.rs` — doc blocks of `describe` :997, `new_change` :1051, `git_push` :1180-1199, `workspace_add` :1868, `squash` :2129-2160, `squash_plan` :2171, `split` :2179-2200, `commit`: `# Errors` gets the `Config` template bullet; `src/lib.rs` module list.

**Change — FFI / Dart / docs**
- `crates/zanshin-ffi/src/envelope.rs` — warning const `JJ_TEMPLATE_DIAGNOSTIC = "jj.template_diagnostic"`, `warning_code()` arm, `every_warning_kind_has_its_registered_code` rows; `crates/zanshin-ffi/src/push.rs:309` doc (custom template refusal gone) → `cargo make codegen` regenerates `zanshin_ffi.h` (:2033).
- `packages/zanshin_core/lib/src/ffi/warning.dart` — `ZanshinWarningCode.templateDiagnostic` + `values`; `test/ffi/warning_test.dart` list + `hasLength`.
- `docs/rust-error-codes.md` — warning row; `jj.config_error` :57 "also emitted — Story 9.51" (template faults, verbs listed); `jj.invalid_input` :65 drop the git_push_bookmark clause; :179 template-aliases load now ported (lazily).
- `_bmad-output/project-context.md` § zanshin-jj — zanshin-jj also depends on jj-cli (template engine only); pin bump moves it with jj-lib.

**Tests / oracle**
- `crates/zanshin-jj/tests/push.rs:763-775` `a_customised_push_bookmark_template_refuses` → becomes the custom-name witness; `tests/squash_split.rs` editor-arm tests (:185, :211-290, :594) stay green; new `tests/templates.rs` for the matrix against jj-lib state; `tests/api_stability.rs` 9.32 warning pin (`TemplateDiagnostic`).
- `crates/zanshin-parity/tests/oracle/` — `ledger.rs` :111-126 drop `describe_commit_trailers` and `commit_trailers`; `main.rs` `a_ledgered_aspect_with_other_values_fails` :211-219 re-pointed at another ledgered scenario (e.g. `describe_no_change`); `parity!` list :38-176 + pin `SCENARIO_IDS.len() == 130` :183; `scenarios.rs` (`EDITOR` :225, `C2_EDITOR` :231, `describe_commit_trailers` :639-654, `commit_trailers` :1276-1289, `split_paths_editor` :1047-1059, `squash_plan_as_message` :943-959), `git_scenarios.rs` (`push` helper :258-273, `push_change` :356-369). Config is set with `Step::Jj(&["config","set","--repo",key,value])`.
- `coverage-baseline.txt` — new `template.rs` ≥ 80; touched files must not drop.

## Tasks & Acceptance

**Execution:**
- `Cargo.toml`, `crates/zanshin-jj/Cargo.toml` -- add the jj-cli dependency with WHY comments -- the engine is jj-cli's.
- `crates/zanshin-jj/src/config.rs` -- jj-cli-derived default layer (aliases + four template keys), drop the hand-copied `git_push_bookmark`, accessors, doc, tests -- defaults verbatim by construction.
- `crates/zanshin-jj/src/warning.rs`, `src/revset.rs` -- `TemplateDiagnostic`, `Load::TemplateAliases`, `parse_diagnostics(kind)`, `RevsetConfig` accessors -- the renderer's inputs and warnings.
- `crates/zanshin-jj/src/template.rs` (new) + `src/lib.rs` -- environment, parse, the five ports; module doc with parity tag v0.46.0, ported anchors and the lazy-load divergence; inline unit tests (empty trailers key → no parse, dedup, editor text cleanup, parse error text, empty/invalid push name) -- one renderer for every verb.
- `crates/zanshin-jj/src/{mutate,commit,workspace_add,squash_split,op_support,push,repo}.rs` -- apply the templates per verb exactly as **Always** orders them; update docs and `# Errors` -- the four gaps.
- `crates/zanshin-ffi/src/{envelope,push}.rs` + `cargo make codegen` -- warning code; doc; regenerated header committed -- FFI registry.
- `packages/zanshin_core/lib/src/ffi/warning.dart` + `test/ffi/warning_test.dart` -- the Dart warning code -- every Rust warning has a Dart twin.
- `crates/zanshin-jj/tests/templates.rs` (new), `tests/push.rs`, `tests/api_stability.rs` -- every matrix row against jj-lib state (descriptions, bookmark names, op head unchanged on refusal, warnings) -- witnesses at the crate surface.
- `crates/zanshin-parity/tests/oracle/{scenarios,git_scenarios,main,ledger}.rs` -- scenarios: `describe_commit_trailers` and `commit_trailers` now match (ledger rows deleted); new `describe_empty_trailers`, `new_description`, `new_description_trailers`, `workspace_add_trailers`, `squash_message_trailers`, `squash_editor_trailers`, `squash_custom_draft`, `squash_plan_custom_draft_as_message`, `split_message_trailers`, `split_editor_trailers`, `split_editor_default_description`, `describe_broken_template` (both refuse), `push_change_custom_template`, `push_change_empty_template` (both refuse); bump the pin; re-point the ledger self-test -- the CLI comparison is the acceptance.
- `docs/rust-error-codes.md`, `docs/ffi-abi.md` (warning list if it enumerates codes), `_bmad-output/project-context.md` -- codes, clauses, the jj-cli dependency rule.
- `_bmad-output/implementation-artifacts/{sprint-status.yaml,deferred-work.md}` -- at finalisation flip `9-51-jj-templates-trailers-draft-push-bookmark` to `done` (sibling style, bump `last_updated`); mark the four ledger items I1–I4 resolved in deferred-work.md with the commit; the `## Surfaced in Story 9.51` section mirrors this spec's `deferred:` (written with the spec).

**Acceptance Criteria:**
- Given every oracle scenario (old and new), when the oracle runs, then each matches the pinned CLI on every compared aspect, the two trailers ledger rows are gone, and no new ledger row is added.
- Given the default config, when the full existing test suites run, then no expected value changes (the templates are no-ops by default).
- Given any template refusal, when the op head and the store's visible heads are compared before and after, then nothing changed (zanshin-jj layer) and the FFI envelope carries `jj.config_error` with the CLI text.
- Given `cargo make test` on the final tree, then it exits 0 (clippy pedantic, fmt, doctests, Dart analyze/format/tests, cargo deny, coverage ratchet with `template.rs` ≥ 80 %, no baseline lowered) and the raised `coverage-baseline.txt` is committed with the code.
- Given the end of the run, then `git status --porcelain` is clean and every commit ends with the required co-author trailer and was made with `--no-gpg-sign`.

## Spec Change Log

- **2026-10-20, implementation — the jj-cli default layer also takes `[diff.color-words]` and `[diff.git]`.** The template engine reads them off the repo's settings whenever a template calls `diff.git()` / `diff.color_words()` (`commit_templater.rs:2490`, `:2534` @ v0.46.0, `UnifiedDiffOptions` / `ColorWordsDiffOptions::from_settings`); without them such a template — e.g. the CLI's own `builtin_draft_commit_description_with_diff` — refused with "Failed to parse template: Failed to load diff settings" where the CLI renders it. They ride the same `ConfigSource::Default` layer as the aliases and the four `templates.*` keys (`config.rs` `TEMPLATE_TABLES`); still no other `[templates]` key is copied.
- **2026-10-20, implementation — the "broken template / workspace add" matrix row follows the CLI, not "op head unchanged".** `add.rs:257-265` adds the trailers after `Workspace::init_workspace_with_existing_repo`, so the CLI refuses with jj-lib's `add workspace '<name>'` operation (and the directory) already written; Zanshin refuses at the same step, before the initial working-copy commit's transaction (`tests/templates.rs` `a_broken_trailers_template_refuses_workspace_add_before_its_transaction`). Every other verb of that row refuses with the op head unchanged.
- **2026-10-20, implementation — the template `RevsetParseContext` also carries the effective `[fileset-aliases]`.** The CLI's `revset_parse_context` (`cli_util.rs:1048-1070`) passes the loaded fileset aliases; Zanshin's own revset parses pass an empty map, the template one passes the loaded table (its warnings record once per call, as the start-up environment's).

## Review Triage Log

### 2026-10-20 — Review pass
- verdicts: 33 findings — high 0, medium 3, low 22, false 8, maybe-false 0
- findings:
  - `[false]` `[reject]` (intent) no `## Auto Run Result`, spec `in-review` vs sprint-status `done` — the review ran mid-run; finalisation writes the section and sets `done`.
  - `[low]` `[reject]` (intent) template refusals witnessed at zanshin-jj and in the oracle, not through FFI/Dart — `map_mutate_err`'s `Config` → `jj.config_error` arm is unit-tested (crates/zanshin-ffi/src/repo.rs); the sibling stories rejected the same gap for the same reason.
  - `[false]` `[reject]` (intent) scope beyond I1–I4 (new_description, squash/split/workspace add trailers, diff tables, the warning code) — epics.md Story 9.51 items 1–6 require them; new_description is the allowed one-liner; the diff tables are logged in the Spec Change Log.
  - `[false]` `[reject]` (intent) existing behaviour changed (squash_plan writes hidden objects, push error kind, workspace add op) — each is the intended CLI behaviour and documented in code and the Spec Change Log.
  - `[false]` `[reject]` (intent) squash not oracle-checked with a custom `default_commit_description` — unreachable for Zanshin's squash: the alias is only read when the description is empty, and the combined editor text always carries its `JJ:` header lines; the single-description arm has no editor in Zanshin.
  - `[low]` `[reject]` (intent) dry-run name equality not oracle-checked — the oracle compares repo state and a dry run writes none; `a_customised_push_bookmark_template_names_the_change_bookmark` (tests/push.rs) asserts the dry-run and push names.
  - `[false]` `[reject]` (intent) `new` reaches trailers only via `new_description` — Zanshin's `new` has no `-m` by design; the CLI applies trailers only to a non-empty description, so this IS the CLI's rule.
  - `[false]` `[reject]` (intent) three low deviations deferred rather than closed — recorded deferrals, not defects.
  - `[false]` `[reject]` (intent) ledger self-test re-pointed — its fixture row was deleted by this story; the test checks the same property.
  - `[medium]` `[patch]` (verification-gap) `squash -u` and the single-description `Combine` arm add trailers with no witness — added oracle scenarios (see Auto Run Result).
  - `[low]` `[patch]` (verification-gap) split editor arm's "first still empty" trailer branch never runs — added an oracle scenario on an undescribed `@` with trailers.
  - `[low]` `[patch]` (verification-gap) empty-message guards of `commit` and `workspace add` unwitnessed — added `commit -m ""` and `workspace add` without `-m` oracle scenarios with trailers.
  - `[low]` `[patch]` (blind) `jj.config_error` docs of describe/new/commit/squash/squash_plan/split/workspace add FFI entry points omit template faults — clause added, codegen re-run.
  - `[low]` `[patch]` (blind) `SplitOptions.message` doc and `SplitRequest.message` schema comment still say "both keep the original description" — rewritten, codegen re-run.
  - `[low]` `[patch]` (blind) template parse refusals drop the CLI's source chain — grouped with the two edge rows below; the reason now carries the chain lines.
  - `[medium]` `[defer]` (blind) the `squash_plan` → `message` round trip re-adds trailers (`-m` arm) — verified: with B = "B\n\nSOB\n" and an untrailered C, the plan text "B\n\nSOB\n\nC\n" passed back as `message` becomes "B\n\nSOB\n\nC\n\nSOB\n" while `squash` without `message` writes the plan text, and a trailer the user deletes in the GUI editor comes back. Every spec rule holds (squash_plan = the editor text; `-m` gets trailers, as the CLI's `-m`); the fix needs a public way to pass "edited editor text" apart from `-m` (a SquashOptions/FFI field) — an API decision for Ralph, deferred per the run's rule (spec `deferred:` item 4, mirrored).
  - `[low]` `[patch]` (blind) the oracle never exercises the ported environment (id-prefix context, immutable set, working-copy keywords) — added `push -c` with `change_id.shortest()` + custom `revsets.short-prefixes`, and a describe trailer template using `immutable` / `current_working_copy`.
  - `[low]` `[patch]` (blind) refusal coverage only for a broken commit_trailers and an empty push name — added both-sides-refuse scenarios for a broken `draft_commit_description` (squash) and a broken `git_push_bookmark` (push -c).
  - `[low]` `[patch]` (blind) `squash -u` / `split --parallel` editor arm unwitnessed — same tests as the verification-gap rows (scenarios added, incl. `split --parallel` without `-m`).
  - `[low]` `[reject]` (blind) the template `RevsetParseContext` uses `Local::now()` and `Some("git")` instead of `debug.commit-timestamp` / the store's ignored remote — the same choice as Zanshin's existing revset context (revset.rs); only a date pattern inside a template under a pinned debug timestamp, or a non-git backend, differs; the fix adds branching.
  - `[low]` `[patch]` (blind) `template_defaults_layer` re-parses jj-cli's default TOML on every config load — built once (LazyLock) and cloned.
  - `[low]` `[reject]` (blind) `config list --include-defaults` now shows the template defaults — intended and closer to the CLI (Design Notes); plain `config list` is unchanged.
  - `[low]` `[reject]` (blind) `describe -m T` on an already-trailered "T\n\nSOB\n" writes an operation where the CLI writes none — the missing no-change gate is Story 9.40's (ledger row `describe_no_change`); trailers only add one more way to reach it.
  - `[low]` `[reject]` (blind) workspace add renders with the old workspace's immutable set — differs only when `immutable_heads()` names a workspace-relative symbol such as `@`; the fix re-parses the start-up environment for the new workspace.
  - `[low]` `[reject]` (blind) `squash_plan` now writes unreferenced objects to the store per call — required to render on the CLI's temp commit; the objects are unreachable and collected by `jj util gc`; no operation is written.
  - `[low]` `[reject]` (blind) no end-to-end witness of `jj.template_diagnostic` — the only template diagnostic jj-cli 0.46 emits is "Failed to load short-prefixes index", which needs a corrupt index; the kind → code mapping is pinned in Rust, FFI and Dart.
  - `[low]` `[reject]` (blind) oracle fixture constants duplicated (`EDITOR_STEP`, `C2_TRAILERS`) — Rust cannot concatenate const slices without a macro; cosmetic.
  - `[low]` `[patch]` (edge) parse error inside an alias/parameter expansion reads only "In alias `x`" — same root as the blind chain row; fixed there with a unit test.
  - `[medium]` `[defer]` (edge) squash_plan text passed back as message doubles trailers — same root as the blind round-trip row; deferred with it.
  - `[low]` `[reject]` (edge) workspace add's immutable set parsed for the old workspace — same as the blind row; rejected there.
  - `[low]` `[reject]` (edge) `debug.commit-timestamp` ignored by the template's date patterns — same as the blind revset-context row.
  - `[false]` `[reject]` (edge, claim) AC "op head unchanged" vs workspace add's refusal after `add workspace` — the Spec Change Log records the CLI-faithful behaviour; the fix would be a spec edit.
  - `[low]` `[patch]` (edge, claim) refusal context lacks the CLI's source chain — same root as the chain row; patched there (hints are presentation, not ported).

## Design Notes

- **Spike (planning, 2026-10-20) — passed.** A throwaway test in `crates/zanshin-jj/tests` with `jj-cli` added to zanshin-jj built `CommitTemplateLanguage` from a `Workspace`, a `StackedConfig` (jj-cli default layers + user layer), an `Fs` path converter, a `RevsetParseContext`, an `IdPrefixContext` and `RevsetExpression::root()` as the immutable set, and rendered on the working-copy commit: `format_signed_off_by_trailer(self)` → `Signed-off-by: Test User <test@example.com>`; `builtin_draft_commit_description` with `default_commit_description = "custom default\n"` → `custom default\n\nJJ: Change ID: zpqtwmox\n`; `"push-" ++ change_id.short()` → `push-zpqtwmoxwrzw`; `nope(` → `Failed to parse template: Syntax error`. jj-cli's artifacts were already built for zanshin-parity, so the incremental build took 2 s; `mimalloc` is only jj-cli's `main.rs` allocator, not the lib's. Every input exists per call: `ctx.config`, `ctx.immutable` (`CommandEnv`), `revset_config`, the workspace. The spike was removed after planning.
- **Why `jj.config_error`:** every template refused here comes from the user's config, and the GUI's remedy is a config edit; the CLI's text travels verbatim as the reason (the CLI exits as a user error, but the code is the contract and the story allowed either).
- **Why derive the defaults from jj-cli:** the alias table is ~650 lines and changes per release; copying it would rot at every pin bump. Only the aliases and the four keys the verbs read are taken, so `config list --include-defaults` grows by exactly what Zanshin honours.
- **Editor-saved-unchanged formula:** the CLI's buffer is `description_template` (+ `edit_description`'s `JJ:` footer); `true` as the editor saves it as is and `cleanup_description_lines` strips every `JJ:` line and the blank edges. So Zanshin's text is `cleanup(render(draft_commit_description, temp_commit))`; with the default template that equals today's `combined_editor_text` (B\n\nC\n), and with an undescribed target it is `""` unless `default_commit_description` says otherwise.

**Golden example** (BASE `A→B→C=@`, `templates.commit_trailers = 'format_signed_off_by_trailer(self)'`, `squash` with no `-m`): `try_combine_messages(["C\n"], "B\n")` is None (both non-empty), so the editor arm runs. Combined = `JJ: Description from the destination commit:\nB\n\nJJ: Description from source commit:\nC\n\nJJ: Trailers not found in the squashed commits:\nSigned-off-by: Zanshin <zanshin@localhost>\n`; rendered with the default draft template and cleaned → `B\n\nC\n\nSigned-off-by: Zanshin <zanshin@localhost>\n`. `squash_plan` returns this text; the squash writes it.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test templates --test push --test squash_split` -- expected: all pass.
- `cargo test -p zanshin-parity --test oracle` -- expected: all pass, no trailers ledger rows.
- `cargo make codegen` -- expected: regenerated files committed, no further diff.
- `cargo make test` (unpiped, synchronous, long timeout) -- expected: exit 0.

## Auto Run Result

Status: done

**Summary.** The planning spike passed: jj-cli 0.46.0's template engine (`CommitTemplateLanguage`, `template_builder::parse`, `TemplateRenderer`) builds from Zanshin's per-call environment, so `zanshin-jj` now links the jj-cli library for the template engine only. A new `template.rs` builds the CLI's template environment lazily per call: revset, fileset and `[template-aliases]` maps, an id-prefix context within `revsets.short-prefixes`, the immutable set, `ui.conflict-marker-style`, and the workspace name and root. It ports `parse_trailers_template`, `add_trailers(_with_template)`, `description_template` with the saved-unchanged cleanup, the trailer block of `combine_messages_for_editing`, `new_description` and the `git_push_bookmark` names. Where the templates apply:
- `templates.commit_trailers` in `describe`, `new`, `commit`, `squash` (and `squash_plan`), `split` and `workspace add`, at the CLI's step and with its empty-description rules.
- `templates.draft_commit_description` for the editor-saved-unchanged text of `squash`, `squash_plan` and `split` (`default_commit_description` is honoured).
- `templates.new_description` for `new`.
- `templates.git_push_bookmark` for `push --change`, in the dry run and the real push.

The defaults are taken verbatim from `jj_cli::config::default_config_layers`, built once per process: `[template-aliases]`, `[diff.color-words]`, `[diff.git]` and the four `templates.*` keys. Template faults refuse as `jj.config_error` with the CLI's text and its cause chain. Template parse diagnostics arrive as a new warning, `jj.template_diagnostic`, in Rust, FFI and Dart.

**Deferred-work items.**
- **I1 (`describe` and `new` never apply `templates.commit_trailers`)** — fixed (74338d0). `describe` adds trailers to a non-empty description. `new` has no `-m` in Zanshin, so it renders `templates.new_description` and adds trailers when that is non-empty (the CLI's rule). The oracle scenarios `describe_commit_trailers`, `describe_empty_trailers`, `new_description` and `new_description_trailers` match the CLI, and the ledger row is gone. `squash`, `split` and `workspace add` apply trailers too (review witnesses in 732247b).
- **I2 (the "editor saved unchanged" rule ignores user templates)** — fixed (74338d0). The text is `cleanup(render(templates.draft_commit_description, temp commit))`. Matching oracle scenarios: `split_editor_default_description` (a custom `default_commit_description`), `squash_custom_draft` and `squash_plan_custom_draft_as_message`.
- **I3 (`commit` does not apply `templates.commit_trailers`)** — fixed (74338d0). A non-empty `-m` gets the trailers, and the oracle's `commit_trailers` ledger row is gone. `commit_empty_message_trailers` (732247b) witnesses the empty guard.
- **I4 (`git push --change` refuses a customised `templates.git_push_bookmark`)** — fixed (74338d0). Names are rendered from the template, with the CLI's refusals for an empty or non-UTF-8 name. Matching oracle scenarios: `push_change_custom_template`, `push_change_empty_template`, `push_change_shortest_template` and `push_change_broken_template`.

**Commits.**
- 455b34d — spec, with its deferral mirrored.
- 74338d0 — feature.
- 17c96df — first planning-file update.
- 732247b — review patches.
- The finalisation commit of this spec, deferred-work.md and sprint-status.yaml.

**Files changed.**
- `crates/zanshin-jj/src/template.rs` (new): the template environment and the CLI's description and push-name rules.
- `crates/zanshin-jj/src/{config,warning,revset,mutate,commit,workspace_add,squash_split,op_support,push,repo,lib}.rs`:
  - the jj-cli defaults layer and the template-key accessors;
  - `TemplateDiagnostic` and `Load::TemplateAliases`;
  - the `RevsetConfig` accessors;
  - the template steps in each verb;
  - `combine_messages_for_editing` gains the CLI's trailer block, and `combined_editor_text` is removed;
  - the push refusal is gone;
  - docs.
- `Cargo.toml` and `crates/zanshin-jj/Cargo.toml`: the jj-cli dependency, with WHY comments.
- `crates/zanshin-ffi/src/{envelope,push,repo,commit,squash_split,workspace}.rs`, `schemas/envelope.fbs`, plus the regenerated `zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart` and `envelope_zanshin.ffi_generated.dart`: the warning code, and the `jj.config_error` and split docs.
- `packages/zanshin_core/lib/src/ffi/warning.dart` and `test/ffi/warning_test.dart`: `ZanshinWarningCode.templateDiagnostic`.
- Tests: `crates/zanshin-jj/tests/templates.rs` (new, 17 tests), `tests/push.rs` (custom-name and empty-name witnesses), `tests/api_stability.rs`, the inline unit tests in `template.rs` and `config.rs`.
- Parity oracle: 24 new scenarios (130 → 154), with the two trailer ledger rows removed and no row added.
- Docs and planning: `docs/rust-error-codes.md`, `_bmad-output/project-context.md` (the jj-cli dependency rule), `coverage-baseline.txt` (`template.rs` = 99.32), `sprint-status.yaml`, `deferred-work.md`.

**Review.** 33 findings: high 0, medium 3, low 22, false 8.
- **Patched (732247b), 1 medium and 9 low entries:**
  - six trailer-branch witnesses (`squash -u`, the single-description squash, the undescribed split's editor arm, `split --parallel` without `-m`, `commit -m ""`, `workspace add` without `-m`);
  - template-environment scenarios (`immutable` / `current_working_copy` in a trailer, `change_id.shortest(8)` within `revsets.short-prefixes`);
  - refusal scenarios for a broken draft template and a broken push template;
  - the `jj.config_error` FFI docs of every template-rendering entry point;
  - the stale split `-m` docs (Rust and `envelope.fbs`);
  - the parse refusal now keeps the cause chain (an alias case names the inner fault);
  - the jj-cli defaults layer is built once.
- **Deferred (medium, the spec's `deferred:` item 4, mirrored):** the `squash_plan` → `message` GUI round trip re-applies trailers, because the `-m` arm adds them. A trailer the user deleted comes back, and an unchanged plan can gain a second trailer when the destination is trailered and the source is not. The fix needs a public way to pass edited editor text apart from `-m`, which is an API decision for Ralph.
- **Rejected,** each with its reason in the triage log:
  - the revset context's timestamp and ignored remote (same as Zanshin's existing revset context; only a debug timestamp or a non-git backend differs);
  - the `config list --include-defaults` growth (intended, and closer to the CLI);
  - the describe no-change op (Story 9.40's gate);
  - workspace add's old-workspace immutable set (only an `immutable_heads()` naming `@` differs);
  - `squash_plan`'s unreferenced store objects (needed to render on the CLI's temp commit);
  - no end-to-end `jj.template_diagnostic` witness (its only source needs a corrupt index);
  - the fixture const duplication;
  - FFI-level refusal tests (the mapping is unit-tested);
  - the dry-run name in the oracle (witnessed in `tests/push.rs`);
  - eight false findings (artifact state mid-run, intended scope, documented behaviour changes, the unreachable squash `default_commit_description` case, `new` without `-m`, the recorded deferrals, the re-pointed self-test, and an AC claim whose fix would edit the spec).

**Follow-up review recommendation:** false. The pass patched one medium entry and no high one (patched counts: high 0, medium 1, low 9 entries).

**Verification.**
- `cargo test -p zanshin-jj --test templates --test push --test squash_split`: all 73 tests pass.
- `cargo test -p zanshin-parity --test oracle`: 163 pass (154 scenarios plus the self-tests), with no trailer ledger rows and no new row.
- `cargo make codegen`: no further diff.
- `cargo make test` (unpiped, synchronous): exit 0 after the review patches (980 s, including the coverage ratchet and the extern-fn guard; baseline unchanged).
- Matrix audit: every row has a passing test in `tests/templates.rs`, `tests/push.rs` or the oracle. The "broken template → push -c" part of that row is witnessed with a broken `git_push_bookmark` (`push_change_broken_template`), since push does not read `commit_trailers`. The workspace-add part refuses after jj-lib's `add workspace` operation, as the CLI does (Spec Change Log).

**Residual risks.**
- `zanshin-jj` (and so the shipped cdylib) now links jj-cli. The pin bump moves it together with jj-lib, and the defaults are copied programmatically, so a pin that renames a table or key would silently leave that part of the layer empty. The `config.rs` tests pin the draft alias and the four keys.
- Four low deferrals are open:
  - the lazy loading of the aliases and short-prefixes versus the CLI's start-up load;
  - no span rendering for `jj.template_diagnostic`;
  - `config()` inside a template sees only part of jj-cli's defaults;
  - the medium `squash_plan` round trip above.
- A disk-space incident during implementation: the implementer deleted `target/debug/incremental` (a regenerable cache) after "No space left on device".
