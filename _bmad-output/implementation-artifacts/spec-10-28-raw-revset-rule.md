---
title: 'Story 10.28 — A raw revset rule in the jj log Configurations window'
type: 'feature'
created: '2026-11-02'
status: 'done'
baseline_revision: 'b910ab2f260cddc98ee6f806076cd7ab08ded301'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
  - '{project-root}/_bmad-output/project-context.md'
warnings: []
deferred:
  - summary: >-
      The raw revset rule row and its two-line jj error have not been compared against the DS RevsetDialog cards in the running catalogue; only widget tests check them.
    evidence: |-
      Unattended run: no Marionette / Playwright check. The catalogue's "My stack, no conflicts" configuration shows the raw rows, but the Widgetbook has no error state for a raw row.
    location: >-
      app/lib/src/features/graph/revset_configs/revset_configs_window.dart (_rule)
    severity: low
---

<intent-contract>

## Intent

**Problem:** The six rule functions of 10.22 cannot express `trunk()..@`, `bookmarks()`, `conflicts()` or a user's own `[revset-aliases]` (deferred I1 "No raw revset in the floating client"); only `revsets.log`, set outside Zanshin, reaches such a revset.

**Approach:** Add a seventh rule function `revset` whose value is free revset text, joined with the other rules through `zanshin_core`'s builders; the backend already parses/resolves every count like `jj log -r` (effective `[revset-aliases]` included, 9.25), so the work is the settings enum, the term builder, the rule row (no mode, no `Aa`) and jj's error text + "did you mean" candidates at the row.

## Boundaries & Constraints

**Always:**
- Settings: `RevsetRuleFunction.revset` appended (JSON `"revset"`); `mode`/`ci` are ignored for it; a blank (whitespace-only) value drops the rule like any text rule.
- Term: the value verbatim when it is the configuration's only kept term and not negated; otherwise grouped `(<value>)` (new `revsetGroup` in `zanshin_core/revset_text.dart`) so jj's precedence cannot leak across the join; negated → `~(<value>)`. The per-rule range covers the grouped term, so a span inside it marks the row.
- Row: `is`/`~ not` chip, function select (label `revset`, not `revset()`), one mono value field (placeholder `trunk()..@`), remove; no mode select, no `Aa`. A dashed add chip `revset` beside the others.
- Error at the row: when the count error's span marks a `revset` row, its value field shows jj's text (`error.context`, else the code) and, when `revsetError.candidates` is non-empty, a second line "Did you mean `a`, `b`?" (jj's own wording/format). Structured rows keep 10.22's mark-only behaviour; the preview keeps showing the message.
- Preview, list detail, search menu and default search use `revsetConfigText` unchanged, so they show/send the raw text inside the joined `-r` and treat the configuration like any other.
- Strings via `app_en.arb`; jj text and revset symbols `// l10n-ignore:`.

**Never:** syntax highlighting, completion, editing `[revset-aliases]`, any Rust/FFI change, client-side revset validation.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Alone | one rule `revset "trunk()..@"` | `trunk()..@` | — |
| Joined | `revset "trunk()..@"`, `author contains "lena"`, `&` | `(trunk()..@) & author(substring:"lena")` | — |
| Negated | `~ revset "conflicts()"` alone | `~(conflicts())` | — |
| Blank | `revset "  "` + author | `author(substring:"lena")` | rule dropped |
| Typo | `revset "trunkk()"` | count error at that row with jj's text + "Did you mean `trunk`?" | preview shows the message too |
| Alias | repo `[revset-aliases] 'mine_lena()' = 'author(…)'`, rule `mine_lena()` | counts without error (real cdylib) | — |
| Persist | config with a revset rule saved | JSON round trip keeps `fn: revset`, value | — |

</intent-contract>

## Code Map

- `packages/zanshin_settings/lib/src/model/graph_settings.dart` -- `RevsetRuleFunction` :73; append `revset`; regenerate `.g.dart` with `dart run build_runner build` (build.yaml header); round trip test `test/model/app_settings_test.dart:147`.
- `packages/zanshin_core/lib/src/revset_text.dart` -- `revsetNot` :90, `revsetJoin` :93; add `revsetGroup`; export via `lib/zanshin_core.dart` (check how `revsetNot` is exported); unit test `test/revset_text_test.dart`; real-cdylib witness in `test/worker/revset_search_test.dart` (pattern :209 writes `.jj/repo/config.toml`; :225 builder witness).
- Backend evidence (read-only): `crates/zanshin-jj/src/revset_search.rs:10` parses with the effective `[revset-aliases]`; `crates/zanshin-jj/src/revset.rs:665` maps `NoSuchFunction { candidates }`; Dart `RevsetErrorDetail.candidates` `packages/zanshin_core/lib/src/ffi/revset_search.dart:135`.
- `app/lib/src/features/graph/revset_configs/revset_config_expression.dart` -- `revsetConfigExpression` :9 (ranges), `revsetRuleTerm` :35 switch; the grouping needs the kept-term count, so decide grouping in `revsetConfigExpression` (count kept rules first).
- `app/lib/src/features/graph/revset_configs/revset_configs_draft.dart` -- `newRevsetRule` :197, `setRuleFunction` :179 (keeps value; no change expected beyond the enum).
- `app/lib/src/features/graph/revset_configs/revset_configs_window.dart` -- `build` marks a rule :385-399 (`error` available there); `_filters` add chips :779; `_rule` :805 (mode select :842, value field :859 with `error: marked ? '' : null`, `Aa` :869, function select labels :918).
- `packages/zanshin_ui/lib/src/controls/zs_text_field.dart:525` -- a non-empty `error` renders under the field (multi-line ok) and becomes the semantics hint.
- `app/lib/l10n/app_en.arb:1211` -- `revsetConfigsHint` select: add a `revset` arm; add `revsetConfigsDidYouMean`; regenerate with `flutter gen-l10n` (in `app`).
- `app/widgetbook/folders/windows.dart:537` -- catalogue configurations; add one revset rule configuration.
- Tests: `app/test/features/graph/revset_configs/revset_config_expression_test.dart`, `revset_configs_window_test.dart` (count error pattern :225-249, `rig.control<ZsTextField>`), `revset_configs_draft_test.dart`.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_settings/lib/src/model/graph_settings.dart` (+ generated, test) -- append `revset`; round trip test with a revset rule.
- `packages/zanshin_core/lib/src/revset_text.dart` (+ export, `test/revset_text_test.dart`, `test/worker/revset_search_test.dart`) -- `revsetGroup`; real-cdylib witness: user alias in a joined raw term counts without error, `trunkk()` reports `noSuchFunction` with `trunk` among candidates.
- `app/lib/src/features/graph/revset_configs/revset_config_expression.dart` -- the `revset` term and grouping rule; tests for the matrix rows Alone/Joined/Negated/Blank and ranges.
- `app/lib/src/features/graph/revset_configs/revset_configs_window.dart` -- revset row (no mode, no `Aa`, `revset` label, placeholder), add chip, error text + candidates at a marked revset row.
- `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`) -- hint arm, "Did you mean" string.
- `app/widgetbook/folders/windows.dart` -- a configuration with a revset rule.
- `app/test/features/graph/revset_configs/revset_configs_window_test.dart` -- witnesses below.

**Acceptance Criteria:**
- Given the add chips, when `revset` is tapped and `trunk()..@` typed, then the command preview reads `❯ jj log -r 'trunk()..@'` and the row has no mode select and no `Aa`.
- Given a revset rule joined with an author rule, then the preview shows `(trunk()..@) & author(substring:"lena")` inside the shell-quoted `-r`.
- Given a fake count error `jj.revset_parse_error` with a span inside the revset rule's term and candidates `[trunk]`, then that row's value field shows jj's text and "Did you mean `trunk`?"; a structured rule's error stays mark-only.
- Given a configuration with a revset rule saved and the settings reloaded, then the rule (function, value, not) is read back and the search menu lists it with its raw expression.

## Spec Change Log

## Review Triage Log

### 2026-11-02 — Review pass
- verdicts: 26 findings — high 0, medium 3, low 18, false 5, maybe-false 0 (Intent Alignment's divergences a–h are logged as rows; g is a confirmation, not a defect)
- findings:
  - Blind Hunter:
  - `[medium]` `[patch]` errors without a span (every `jj.revset_resolution_error`, e.g. raw `trunk()..nosuch`) mark no row, so jj's text never reaches the raw row — a spanless error now marks the first kept raw rule whose value holds `revsetError.symbol`, else the only kept raw rule; window test.
  - `[low]` `[patch]` `revsetGroup`'s doc overclaims: unbalanced parentheses (`a) | (b`) escape the group — doc now states the limit (no client-side validation, per the spec's Never).
  - `[low]` `[reject]` an older build reading a `revset` rule fails to decode — a change in this build cannot make an older build tolerant; downgrades are not an everyday path (10.22 rejected unknown-enum policy the same way).
  - `[low]` `[reject]` switching a rule's function keeps its value and the hidden mode/ci — 10.22's deliberate `setRuleFunction` behaviour (value kept, mine cleared); the ignored mode/ci are harmless in JSON.
  - `[low]` `[patch]` no test marks an error inside an alone (verbatim) raw term — the end-of-input fix comes with an alone-term witness (`foo(`, span at the end).
  - `[low]` `[reject]` only the `&` join is tested for raw rules — grouping is op-independent (`alone` counts kept rules), and `revsetJoin(any: true)` is tested in zanshin_core.
  - `[low]` `[patch]` the `@revsetConfigsHint` description says it is always the value's placeholder — description corrected (files and revset show an example).
  - `[low]` `[reject]` candidate quoting/separator joined in code — deliberately jj's own format (`format_similarity_hint`, cli/src/command_error.rs @ v0.46.0); a localized list adds an ARB plural for an English-only app.
  - `[low]` `[defer]` no Widgetbook error state / visual check of the two-line row error — the visual check is not possible unattended (deferred below).
  - `[low]` `[reject]` the real-cdylib alias witness builds its expression by hand, not through `revsetConfigExpression` — the app builder is unit-tested against the same `revsetGroup`/`revsetJoin`; the witness proves the backend half.
  - Edge Case Hunter:
  - `[low]` `[patch]` an end-of-input parse error on an alone raw term (`foo(`, span start == text length) marks no row — a position at the very end now belongs to the range ending there; window test.
  - `[medium]` `[patch]` a spanless error never reaches a raw row — same root cause as the Blind Hunter spanless row; fixed with it.
  - `[false]` `[reject]` an error inside a user alias's body points the span into the alias definition — jj reports the call site (`crates/zanshin-jj/tests/it/revset_search.rs:512` "an_error_inside_an_alias_reports_the_call_site…"), which lies in the user's text.
  - `[low]` `[reject]` unbalanced parentheses let a raw `|` bind across the join — user-authored malformed text; a paren-balance check is client-side validation the spec's Never excludes; doc patched (Blind Hunter row).
  - `[low]` `[reject]` downgrade decoding — same as the Blind Hunter downgrade row.
  - `[low]` `[patch]` `revsetGroup` claim — same as the Blind Hunter doc row; fixed with it.
  - Verification Gap:
  - `[low]` `[patch]` a raw-row error without candidates is untested — the spanless witness asserts exactly jj's context, one line, no "Did you mean".
  - `[low]` `[patch]` the function select's `revset` label (no `()`) is untested — window test asserts the option labels.
  - Intent Alignment:
  - `[medium]` `[patch]` (a) resolution errors never reach the row — same root cause as the Blind Hunter spanless row; fixed with it.
  - `[false]` `[reject]` (b) grouping deviates from "verbatim" — the raw text is unaltered inside the joined `-r`; grouping is what keeps it one operand as `jj log -r` would read it, and alone it is byte-for-byte.
  - `[low]` `[reject]` (c) the typo witness is split across a real-cdylib test and a fake-port window test — the project's window tests run on fake ports by convention; both halves agree on the span (offset 1 in the group).
  - `[low]` `[reject]` (d) the alias witness uses the repo config layer only — the effective config stack (9.27) is shared by every layer; the alias map is built from it (`revset.rs:964`).
  - `[false]` `[reject]` (e) no parity-oracle witness — no jj verb changed; the count path is 9.25's, already parity-checked.
  - `[low]` `[reject]` (f) the default search is checked as the controller's expression with a fake source — the controller sends that string verbatim (10.22's tested path).
  - `[false]` `[reject]` (g) persistence — covered at both surfaces; not a defect.
  - `[false]` `[reject]` (h) no Auto Run Result in the diff — it is written at finalize, in this spec.

## Design Notes

- Grouping only when needed keeps the witness `trunk()..@` alone verbatim and is still correct when joined: jj binds `..`/`::` tighter than `&` but `|` looser, so `a | b` joined with `&` must be grouped.
- The row hint uses `revsetError.candidates` (structured) rather than parsing `hints`, matching the story's "9.25's `NoSuchFunction` candidates become the row's hint"; the text mirrors jj's `similarity_hint` ("Did you mean `a`, `b`?").

## Verification

**Commands:**
- `dart test` in `packages/zanshin_core` (revset_text + worker witness, env pinned as `cargo make` does) -- pass.
- `flutter test` in `packages/zanshin_settings` -- pass.
- `flutter test test/features/graph test/widgetbook test/l10n` in `app` -- pass.
- `dart analyze --fatal-infos` and `dart format --set-exit-if-changed -o none` in app, zanshin_core, zanshin_settings -- clean.
- No Rust change: no cargo checks, codegen or parity oracle; no full gate (story-loop gate rule).

**Manual checks (if no CLI):**
- Marionette/Playwright visual check of the revset row is not possible unattended; record as deferred if not done.

**Verification notes (run 2026-11-02, story-loop gate rule: no full gate; env pinned as `cargo make` does: JJ_*, GIT_CONFIG_GLOBAL, ZANSHIN_LOG_DIR, XDG_CONFIG_HOME=target/test-xdg-config):**
- `dart test` (packages/zanshin_core, real cdylib, whole suite incl. the new alias/typo witness) -- 1189 passed.
- `flutter test` (packages/zanshin_settings) -- 41 passed.
- `flutter test test/features test/widgetbook test/l10n test/app` (app) -- 1776 passed, twice in a row after the review patches. Before that, 10.22's "saved configurations and the default survive a restart…" failed in 2 of 3 full runs (passes alone): its fixed 10 × 10 ms wait lost the settings write under load (default read `log`, not `c1`). Fixed in this run: `_Rig.reloadSaved` polls until the file holds the in-memory graph settings; the new 10.28 reload test uses it too.
- `dart analyze --fatal-infos` -- no issues in app (incl. widgetbook), zanshin_core, zanshin_settings; `dart format --set-exit-if-changed -o none` -- 0 changed.
- Not run: cargo test/clippy/fmt (no Rust changed), `cargo make codegen` (no FFI or schema change), the parity oracle (no jj verb changed), the full gate and coverage (the loop runs them once at its end), the Marionette visual check (deferred).

## Auto Run Result

Status: done (commit: see the closing commit below this run's code commit; hashes listed in Deferred work items).

**Summary.** The jj log Configurations window has a seventh rule function, `revset`: free revset text, joined with the structured rules through `zanshin_core`'s builders (new `revsetGroup`; verbatim when it is the only kept term and not negated, else `(…)` / `~(…)`). Its row has the not chip, the function select (`revset`, no `()`), one mono value field (placeholder `trunk()..@`) and remove — no mode, no `Aa`. The backend already checks every count like `jj log -r` with the effective `[revset-aliases]` (9.25); a parse error whose span lies in a raw rule, an end-of-input error after an alone raw term, and a spanless resolution error (the raw rule naming jj's symbol, else the only raw rule) show jj's text at that row, plus "Did you mean `a`, `b`?" from jj's candidates. The preview, list detail, search menu and default search show/send the raw text inside the joined `-r` unchanged.

**Files.**
- `packages/zanshin_settings/lib/src/model/graph_settings.dart` (+ `.g.dart`, test) -- `RevsetRuleFunction.revset`.
- `packages/zanshin_core/lib/src/revset_text.dart` (+ export, tests) -- `revsetGroup`; real-cdylib witness: a user alias in a grouped joined term counts, `trunkk()` gives `noSuchFunction` with `trunk`.
- `app/lib/src/features/graph/revset_configs/revset_config_expression.dart` -- the raw term and its grouping rule.
- `app/lib/src/features/graph/revset_configs/revset_configs_window.dart` -- the raw row, error text + candidates at it, spanless / end-of-input marking.
- `app/lib/l10n/app_en.arb` (+ generated) -- the `revset` hint arm, `revsetConfigsDidYouMean`.
- `app/widgetbook/folders/windows.dart` -- "My stack, no conflicts" (`trunk()..@`, `~ conflicts()`).
- Tests: `revset_config_expression_test.dart`, `revset_configs_window_test.dart` (incl. `_Rig.reloadSaved`), `graph_search_field_test.dart`, `app_settings_test.dart`.

**Deferred work items given to this story.**
- **I1 — fixed** (code commit in the list below). A raw `revset` rule expresses `trunk()..@`, `bookmarks()`, `conflicts()` and the user's `[revset-aliases]`; 9.25's `NoSuchFunction` candidates are its row's "did you mean" hint.

**Review.** One pass, 26 findings: 0 high, 3 medium, 18 low, 5 false, 0 maybe-false. Patched entries by verdict: 1 medium (spanless errors never reached the raw row — 3 rows of one root cause), 5 low (end-of-input marking with an alone-term witness, the `revsetGroup` doc's unbalanced-parentheses limit, the ARB description, a no-candidates witness, the `revset` label witness). Deferred: 1 low (the visual check). Rejected rows and their reasons are in the triage log (downgrade decoding, function switch keeps the value, `|`-join test, jj's candidate format, hand-built alias witness, paren balancing as client-side validation, fake-port window tests, repo-layer alias, controller-level default-search check; false: alias span, grouping vs verbatim, parity oracle, persistence, Auto Run Result).

**Follow-up review: not recommended.** One medium entry patched, no high.

**Residual risks.**
- No visual check of the raw row against the DS RevsetDialog cards (deferred).
- A raw value with unbalanced parentheses escapes its group (documented; jj parses what it gets, no client-side validation).
- Two raw rules and a spanless error naming a symbol neither contains mark no row (jj's text stays in the preview).
- An older build reading a settings file with a `revset` rule fails to decode it (pre-existing decoding policy).
