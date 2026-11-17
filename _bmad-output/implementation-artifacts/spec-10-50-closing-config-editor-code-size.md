---
title: 'Story 10.50 closing run — the design system''s config file editor follows Settings › Code size'
type: 'chore'
created: '2026-11-17'
status: 'done'
baseline_revision: '1f13e02a6af8e5c733c6fc930e1f02b52680674c'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
  - '{project-root}/.claude/skills/design-artifacts/SKILL.md'
warnings: []
deferred:
  - summary: >-
      The design system has no Code font and Code size rows in Settings › General › Diffs: no sync entry covers the Inspector Extras Study's section 5, so the DS card shows Layout, Changed words, Inline changes and Context lines only.
    evidence: |-
      `design_system/components/settings/settings.card.html:43` lists the Diffs rows without Code font / Code size; sync #31 covers the study's sections 1–3 and #32 section 4; Story 10.50 built the rows in the app (`app/lib/src/features/settings/general_tab.dart`) under "no DS change". Pre-existing; this run's item names only the config editor.
    location: >-
      _bmad-output/implementation-artifacts/design_system/components/settings/settings.card.html:43
    severity: low
---

<intent-contract>

## Intent

**Problem:** Story 10.50's deferred item 1, verified at `1f13e02`. The app's config file editor draws in the code style (`CodeStyleScope`, default 11 px × 1.65, Settings › Code size; gutter `max(44, digits + 20)`, `app/lib/src/features/settings/config_file_page.dart:507-534`), while the design system still gives it `--fs-md` on a 19.5px line (`design_system/components/settings/settings.css:104`) and says so in `ConfigFilePage.prompt.md:11`.

**Approach:** A design-system-only sync through the `design-artifacts` skill (section C): the editor takes `--type-code` (the DS token the app's `ZsType.code` mirrors: 400 11px/1.65 mono), the gutter keeps its 44px least width and widens to fit its numbers with 10px each side, the prompt says the editor follows Settings › Code size; a dated line in the readme's Sync section and entry #33 in `design/DESIGN-SYSTEM-SYNC.md`. No app change.

## Boundaries & Constraints

**Always:**
- The DS default equals the app's default: `--type-code` (11px / 1.65, `--font-mono`) for the editor, its gutter and its mirror (they inherit the editor's font).
- The gutter: at least 44px, else its numbers' width + 10px each side (the app's `max(44, digits + 20)`); right-aligned numbers.
- Readme: "Synced through #33" and a dated line; sync log #33 in the shape of #29–#32 (what changed, "→ Design system: done in this entry …", "Not published (waits for a console session).", then the app line).

**Never:**
- No publish (sections A/B wait for a console session); no app, Dart or Rust change; no `ConfigFilePage.jsx` / `_ds_bundle.js` change (the component's code does not change, only its CSS and prompt).
- No new token; no change to other `.zs-cfg-*` rules (bar path, error message keep their sizes — they are UI text, not code).
- Do not edit old sync entries or Story 10.50's spec.

</intent-contract>

## Code Map

- `_bmad-output/implementation-artifacts/design_system/components/settings/settings.css:104-106` -- `.zs-cfg-ed` font (`var(--fs-md)/19.5px var(--font-mono)` → `var(--type-code)`), `.zs-cfg-gut` (`width:44px` → `min-width:44px`), `.zs-cfg-gut span` (`padding-right:10px` → `padding:0 10px`); the comment at `:92` names the code size.
- `_bmad-output/implementation-artifacts/design_system/tokens/typography.css:38` -- `--type-code: 400 11px/1.65 var(--font-mono)` (read only; `packages/zanshin_ui/lib/src/design/zs_type.dart:255` mirrors it).
- `_bmad-output/implementation-artifacts/design_system/components/settings/ConfigFilePage.prompt.md:11` -- "mono `--fs-md` on a 19.5px line, line numbers in a 44px gutter" → the code style, Settings › Code size, the widening gutter.
- `_bmad-output/implementation-artifacts/design_system/components/settings/ConfigFilePage.jsx:60-61` -- uses only the classes; unchanged, so `_ds_bundle.js` stays as is.
- `_bmad-output/implementation-artifacts/design_system/readme.md:22` -- "Synced through #32 (…)" → #33; dated lines end at `:76`.
- `_bmad-output/implementation-artifacts/design/DESIGN-SYSTEM-SYNC.md:325-335` -- #32 is the pattern for #33.
- `app/lib/src/features/settings/config_file_page.dart:196, 507-534` -- the app's behavior the DS follows (read only).
- `packages/zanshin_ui/test/design/` -- the token tests that read `design_system/` (the gate maps `design_system/` to them); no test reads `settings.css`.

## Tasks & Acceptance

**Execution:**
- `design_system/components/settings/settings.css` -- editor font `var(--type-code)`, gutter `min-width:44px` with numbers padded 10px each side, comment -- the DS draws what the app draws.
- `design_system/components/settings/ConfigFilePage.prompt.md` -- editor line: the Settings code style (`--type-code` by default, Settings › General › Diffs › Code font / Code size, the app zoom multiplies it), the gutter at least 44px and wider for large sizes.
- `design_system/readme.md` -- "Synced through #33" and a dated line (2026-11-17, from the app, sync #33, Story 10.50).
- `design/DESIGN-SYSTEM-SYNC.md` -- entry #33 and the app line.

**Acceptance Criteria:**
- Given the DS `ConfigFilePage`, when its editor renders, then it uses `--type-code` (11px / 1.65 mono) and `settings.css` no longer contains `19.5px`.
- Given a long file, when its gutter renders, then it is at least 44px and grows with the numbers' width, keeping 10px on each side.
- Given the readme and the sync log, when read, then both name #33 (the config editor follows Settings › Code size) and "not published".

## Spec Change Log

## Review Triage Log

### 2026-11-17 — Review pass
- verdicts: 8 findings — high 0, medium 0, low 6, false 2, maybe-false 0
- findings:
  - `[low]` `[defer]` (blind) the DS has no Code font / Code size rows, while #33, the readme and the prompt point to them — verified: `settings.card.html:43` lists the Diffs rows without them and no sync entry covers the study's section 5; pre-existing since Story 10.50 ("no DS change"), not caused by this run; added to `deferred:` and mirrored into deferred-work.md.
  - `[low]` `[patch]` (blind) the #33 heading, the readme's bold lead and the CSS comment name only Code size, though the editor follows Code font too — patched: all three read "Code font and Code size".
  - `[false]` `[reject]` (blind) the bar's path and jj's error message stay in the fixed mono font without a recorded decision — the entry records it with its reason ("UI text, not code"), and the DS matches the app: `config_file_page.dart:450, 672` draw both in `ZsType.id`, as Story 10.50 keeps other mono UI text.
  - `[low]` `[patch]` (blind) nothing shows or checks the new gutter, and #33 does not say what is unchecked — patched: #33's app line says the card is not yet rendered and compared with the running app (console session). A card for a long file or other sizes is not added: the DS has no code-size setting to show.
  - `[low]` `[reject]` (blind) the DS gutter's 1px border sits outside its 44px (text at 45) while the app overlays the divider (text at 44) — pre-existing (the old `width:44px` was content-box too); a 1px difference no reader meets in a static card.
  - `[low]` `[reject]` (blind) `ConfigFilePage.jsx`'s header comment does not mention #33 — the component's code did not change; the CSS, its comment and the prompt carry #33, and a comment edit would also force a hand edit of `_ds_bundle.js`.
  - `[low]` `[reject]` (intent) the click-dummy (`design/settings.css:177-179` `.gcfg-ed` 12/19.5, `design/config-file.jsx:129` `lh = 19.5`) keeps the old size — the intent names the design system (`settings.css:104`); the click-dummy is a prototype that does not follow every app change (design/CLAUDE.md: the floating client still shows the old inspector).
  - `[low]` `[patch]` (intent) the change is shown by source inspection only, with no render — same root cause as the blind "unchecked" row; patched with it (#33 names the open visual check).

## Design Notes

`--type-code` already is the DS's code role and the source of `ZsType.code`, which the app's code style starts from; using it keeps the DS default and the app default the same without a new token. A user's Code font / Code size is an app setting the static DS cannot show; the prompt names it.

## Verification

**Commands (targeted; the story loop runs the full gate — no `cargo make test`, `test-full` or `coverage`):**
- `flutter test test/design` in `packages/zanshin_ui` -- expected: pass (the token tests read `design_system/`).
- `rg -n "19\.5px" design_system/components/settings/settings.css` -- expected: no match.

**Verification notes (run 2026-11-17; no `cargo make test` / `test-full` / `coverage` per the loop's gate rule):**
- `flutter test test/design` in `packages/zanshin_ui` — 79 passed, after the implementation and again after the review patches.
- `rg "19\.5px"` on `settings.css` — no match (exit 1).
- No Rust, FFI, schema, jj verb or Dart source touched: no cargo, codegen, oracle, `dart analyze` or `dart format` step applies. `_ds_bundle.js` untouched (the component's JSX did not change; the bundle holds no CSS).
- Not done: the DS card was not rendered in a browser and not compared with the running app (console session).

## Auto Run Result

Status: done

**Items:**
- **1 — fixed (c0298ae604078a913ae9b050521a75983077810d).** Verified real at `1f13e02`: the app's `ConfigFilePage._editor` reads `CodeStyleScope` (default 11 px × 1.65, gutter `max(44, digits + 20)`, `config_file_page.dart:507-534`) while the DS's `.zs-cfg-ed` still read `--fs-md`/19.5px (`settings.css:104`). DS sync #33 through the `design-artifacts` skill (section C, no publish): the editor, its gutter and mirror take `--type-code`; the gutter is at least 44px and widens with its numbers, 10px on each side; `ConfigFilePage.prompt.md`, the readme's Sync section ("Synced through #33" and a dated line) and `design/DESIGN-SYSTEM-SYNC.md` #33 say the editor follows Settings › Code font and Code size. No app change was needed.

**New finding (deferred, mirrored into deferred-work.md):** the DS has no Code font / Code size rows in Settings › Diffs (the study's section 5 has no sync entry) — low, pre-existing since Story 10.50.

**Files changed (c0298ae6):**
- `design_system/components/settings/settings.css` — `.zs-cfg-ed` font `var(--type-code)`, `.zs-cfg-gut` `min-width:44px`, numbers padded `0 10px`, comment.
- `design_system/components/settings/ConfigFilePage.prompt.md` — the editor line: code style, Settings › Code font and Code size, the widening gutter.
- `design_system/readme.md` — "Synced through #33" and its dated line.
- `design/DESIGN-SYSTEM-SYNC.md` — entry #33 and its app line (with the open visual check).
- Spec commit: this spec, `deferred-work.md` (item resolved, the new finding), `epic-10-context.md` (#33 is current).

**Review:** 8 findings (low 6, false 2). Patched (low): "Code font and Code size" in the #33 heading, the readme lead and the CSS comment; #33's app line names the open visual check. Deferred: the missing DS Settings rows (pre-existing). Rejected: the path and error message in UI mono (false — recorded with its reason, matches the app's `ZsType.id`), the 1px border placement (pre-existing, negligible), the JSX header comment (code unchanged; would force a bundle edit), the click-dummy's 12/19.5 (the intent names the DS; the prototype does not track every app change).

**Follow-up review recommended:** false — patched counts high 0, medium 0, low 2 entries.

**Verification:** see Verification notes — the DS token tests and the grep; no full gate per the loop's rule.

**Residual risks:** the DS card is not rendered or compared with the running app; the publish (sections A/B) waits for a console session.
