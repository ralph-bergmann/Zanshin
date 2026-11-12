---
title: 'Story 10.34 — Word marks differ in lightness: removed darker, added lighter'
type: 'feature'
created: '2026-11-12'
status: 'done'
baseline_revision: 'e44b7c42e9984924484ce49643daaf0420c803fa'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Since Story 5.10 one changed line holds removed and added words side by side, and their fills `--rem-word-bg` / `--add-word-bg` differ by hue only (paper L* 88.2 / 88.1, night 25.6 / 31.4). A reader who sees red and green alike cannot tell them apart; the DS asks colours that must be told apart to differ in lightness.

**Approach:** Change only the two tokens' values in night and paper (DS `tokens/colors.css` and `ZsColors`) so the removed fill is darker and the added fill lighter, and pin the three lightness and contrast rules in one token test.

## Boundaries & Constraints

**Always:**
- Removed fill darker, added fill lighter, in both themes. Starting values (may be tuned inside the rules): night rem `rgba(248,113,113,.24)`, add `rgba(74,222,128,.38)`; paper rem `rgba(194,58,58,.40)`, add `rgba(26,127,69,.18)`.
- Rules, each fill composited as the inspector draws it (`--code-bg` over `--fl-bg-solid`; on its own line also over `--rem-bg` / `--add-bg`): (R1) on a changed line the two fills differ by at least 12 in CIE L*; (R2) `--text` on a fill keeps at least 4.5:1 on a changed line and on its own line; (R3) each fill differs from the surface under it by at least 8 in L*, on a changed line and on its own line.
- CSS and Dart values stay equal (`ds_parity_test`). DS is republished with the `design-artifacts` skill.

**Never:** underline, strikethrough or any other cue; new or renamed tokens; changes to line fills, inks or line-number colours; colour-vision simulation; starting the app.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Old values | paper rem .20 / add .22 | R1 fails (ΔL* 0.1) | test fails |
| New values | values above | R1–R3 hold in night and paper, in every appearance | test passes |

</intent-contract>

## Code Map

- `packages/zanshin_ui/lib/src/design/zs_colors.dart:423-424` (night), `:609-610` (paper) -- `addWordBg` / `remWordBg` values; doc comments at ~`:1000-1006` name the DS lines.
- `_bmad-output/implementation-artifacts/design_system/tokens/colors.css:71` (night), `:107` (paper) -- the CSS tokens and a comment naming measured contrasts.
- `packages/zanshin_ui/test/design/zs_tokens_test.dart:111-151` -- existing word-fill test (data colour in all 144 appearances, `--text` ≥ 4.5:1 on own line); extend with R1–R3.
- `packages/zanshin_ui/test/design/ds_parity_test.dart` -- reads colors.css against `ZsColors`; keeps CSS and Dart in step.
- `_bmad-output/implementation-artifacts/design_system/readme.md:96` (Semantic colours), change log near `:48`; `components/content/DiffView.prompt.md:13`, `DiffHunk.prompt.md` -- docs.
- `_bmad-output/implementation-artifacts/design_system/_ds_manifest.json` -- carries token values; refreshed by the `design-artifacts` skill.
- `app/lib/src/features/graph/inspector_diff.dart`, `app/test/helpers/word_marks.dart` -- read the tokens symbolically; no change.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/test/design/zs_tokens_test.dart` -- add R1–R3 (CIE L* from `computeLuminance`) to the word-fill test over all appearances -- pins the rules.
- `packages/zanshin_ui/lib/src/design/zs_colors.dart` -- new values, both themes.
- `design_system/tokens/colors.css` -- same values; update the measured-contrast comments.
- `design_system/readme.md`, `DiffView.prompt.md`, `DiffHunk.prompt.md` -- say the fills differ in lightness and why; change-log entry.
- Republish the DS with `design-artifacts`.

**Acceptance Criteria:**
- Given the old values, when the token test runs, then R1 fails in paper.
- Given the new values, when `flutter test` runs in `packages/zanshin_ui` and `app`, then all pass.
- Given the DS, when read, then colors.css and `ZsColors` hold the same values and the docs state the lightness step.

## Spec Change Log

## Review Triage Log

### 2026-11-12 — Review pass
- verdicts: 15 findings — high 0, medium 0, low 7, false 7, maybe-false 1
- findings:
  - `[low]` `[patch]` (blind) `_ds_manifest.json` keeps the old word-fill values and the DS is not republished — fixed: the four values set in the manifest; DS (version 1794519825-5a20) and canvas (1794519877-52c8) republished with the `design-artifacts` skill.
  - `[false]` `[reject]` (blind) no `DESIGN-SYSTEM-SYNC.md` entry — that log numbers changes coming from the design prototype; app-born DS changes (10.32, 5.10) are logged in the DS readme only, which this change does.
  - `[low]` `[reject]` (blind) status bookkeeping missing — sprint-status is set to done at finalization; deferred-work.md is left to the loop by the run's rules; the rest is the spec itself.
  - `[false]` `[reject]` (blind) the old-values AC has no evidence — the implementation run ran the test on the old values: R1 failed (night first, paper 0.1 L*); recorded under Auto Run Result.
  - `[false]` `[reject]` (blind) docs overclaim (line fills still hue-only) — the new sentences are about the two word fills on a changed line; removed and added lines also differ by their number column (left vs right) and the line fills are out of scope by the story.
  - `[low]` `[reject]` (blind) thin margins (night added word on its own line 4.76:1, paper R3 8.6) — the test pins every rule, so a later tweak that breaks one fails; no fix needed.
  - `[low]` `[reject]` (blind) R1 only on a changed line — the story scopes R1 to a changed line; own-line ΔL* is ≥ 12.0 today but not a rule.
  - `[false]` `[reject]` (blind) paper ΔL* 13.6 may be 13.4 — the edge-case reviewer's independent recomputation and the measuring script both give 13.6 with unrounded compositing.
  - `[low]` `[patch]` (blind) DiffHunk.prompt.md "darker"/"lighter" without a referent — fixed: "the removed tint is darker than the added one".
  - `[low]` `[reject]` (edge) R1 not asserted for marks on their own lines — same as the blind finding above.
  - `[maybe-false]` `[reject]` (edge) rules assume the solid ground, not translucent glass — the story defines the rules on `--fl-bg-solid`, as the inspector's diff well and 10.32's test do; if true it would be low.
  - `[false]` `[reject]` (edge) manifest stale — duplicate of the first row, fixed there.
  - `[false]` `[reject]` (verification-gap) manifest stale, no test — duplicate of the first row, fixed there.
  - `[low]` `[reject]` (intent) the rendered witnesses (catalogue, Marionette vs DS Content card) are unchecked — by the run's rules the console session does them.
  - `[false]` `[reject]` (intent) deferred-work and sprint-status bookkeeping absent from the diff — sprint-status is updated at finalization; deferred-work is the loop's.

## Verification

**Commands:**
- `flutter test` in `packages/zanshin_ui` -- all pass.
- `flutter test test/features/graph/inspector_diff_test.dart` in `app` -- pass.
- `dart analyze` and `dart format --set-exit-if-changed` on touched packages -- clean.

**Manual checks (if no CLI):**
- Console session: Marionette check of the catalogue changed line in night and paper against the DS Content card.

## Auto Run Result

Status: done

**Summary.** The two word fills now differ in lightness: removed darker, added lighter, in night and paper, with the story's starting values (night rem `rgba(248,113,113,.24)`, add `rgba(74,222,128,.38)`; paper rem `rgba(194,58,58,.40)`, add `rgba(26,127,69,.18)`). The token test pins R1–R3 over all 144 appearances. Code commit `362ff81a766e62070a32fa280021e48c1e2213f5`.

**Measured (Flutter compositing).** Night: ΔL* 15.2 on a changed line; `--text` 5.9 / 10.2:1 (add / rem) on a changed line, 4.76 / 8.3:1 on the fill's own line; smallest step off the surface 12.4 L*. Paper: ΔL* 13.6; `--text` 11.9 / 8.2:1, own line 10.6 / 7.4:1; smallest step 8.6 L*.

**Files changed.**
- `packages/zanshin_ui/lib/src/design/zs_colors.dart` -- new values, doc comments name the lightness step.
- `packages/zanshin_ui/test/design/zs_tokens_test.dart` -- the word-fill test checks R1–R3 in every appearance.
- `design_system/tokens/colors.css` -- new values and measured contrasts in the comments.
- `design_system/_ds_manifest.json` -- the four token values.
- `design_system/readme.md`, `components/content/DiffView.prompt.md`, `DiffHunk.prompt.md` -- the lightness step and why; change-log entry.

**Deferred-work items.**
- I1 -- fixed (`362ff81a766e62070a32fa280021e48c1e2213f5`): the removed and added word fills now differ by 15.2 (night) and 13.6 (paper) in CIE L* on a changed line; no other cue, as Ralph decided.

**Review.** 15 findings: 2 patches (manifest values + DS/canvas republish; DiffHunk wording), 0 deferred, 13 rejected (reasons in the Review Triage Log). Patched by verdict: high 0, medium 0, low 2. Follow-up review: not recommended.

**Verification performed (targeted; full gate left to the story loop).**
- Old values: the new test fails R1 (night ΔL* 5.7 first; paper 0.1) -- red as required.
- `flutter test test/design/zs_tokens_test.dart test/design/ds_parity_test.dart` in `packages/zanshin_ui` -- 41 passed; the implementation run's full `flutter test` there -- 460 passed.
- `flutter test test/features/graph/inspector_diff_test.dart` in `app` -- 26 passed.
- `flutter test test/widgetbook/ds_manifest_parity_test.dart` in `app` -- passed (after the manifest edit).
- `dart analyze` in `packages/zanshin_ui` -- no issues; `dart format --set-exit-if-changed` on its `lib` and `test` -- 0 changed.
- DS republished: Design System artifact version 1794519825-5a20; canvas 6sAzL5mDcVpWXevbTcempu version 1794519877-52c8.
- Not run: `cargo make test` (gate rule of this run); the Marionette catalogue check (console session).

**Residual risks.** Night added words on their own added line sit at 4.76:1, close to the 4.5:1 floor; the test fails if a later token change pushes them under it.
