---
title: "Story 11.29 — A refused fetch, push or project open shows jj's hints"
type: 'feature'
created: '2026-11-16'
status: 'done'
baseline_revision: '102262fd2bdc244c9e6bb5b86a6f4c635da862f7'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The Widgetbook state "Push sheet › Refused with hints" and the hint tooltips on the error toasts were not checked in the running catalogue against the DS in Paper and Night.
    evidence: |-
      The unattended run allows only synchronous commands, so the catalogue was not launched; widget tests pin the text, the order and the tooltips only.
    location: >-
      app/widgetbook/folders/sync.dart (_Sheet.refused); app/lib/src/features/sync/sync_model.dart, app/lib/src/features/home/home_page.dart (toast tooltip)
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** jj's hints on a refused fetch, push or project open reach Dart on `ZanshinFfiException.hints`, but the sync surfaces and the Projects window show only `error.context ?? error.code`. The user never sees what jj says to do next — for example the commit check's "Did you mean" hint, or the path of a config file that does not parse (deferred-work I1, I2).

**Approach:** Wherever these surfaces show a `ZanshinFfiException` to the user, show its hints under the context, one per line, verbatim — the house pattern of the push sheet's rejection rows (`[message, ...hints].join('\n')`). `ProjectOpenFailed` carries the hints so the Projects window's open-failure notice can show them.

## Boundaries & Constraints

**Always:**
- Hint text is jj's, verbatim, not localized, each on its own line under the context (or the code when there is no context), in jj's order.
- An error with no hints renders exactly as today.
- `ProjectOpenFailed` gets a `hints` field (default empty) filled from `ZanshinFfiException.hints` in `ProjectSession._failed`; the Projects window's notice lists context, then hints, then warnings.

**Never:** other error surfaces (inspector, undo timeline, Settings, bookmarks panel); changing hint text; a new Zs control or a new note style; touching the Rust side or the FFI.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Push plan refused with hints | dry-run plan throws `context: "Invalid revset"`, `hints: ["Did you mean …"]` | `push-plan-error` note reads `Invalid revset\nDid you mean …` | — |
| Push refused with hints | `push()` throws with hints | `push-error` note shows context then each hint | — |
| Refusal without hints | `ZanshinFfiException('jj.network_error', 'x')` | note/toast text is `x`, as today | — |
| No context | `context == null`, hints present | code, then the hints | — |
| Fetch failed | `fetch()` throws with hints | error toast: context, then hints; Retry stays | — |
| pushNow failed | `pushNow` throws with hints (not stale) | "The push failed: …" toast includes the hints | stale still shows no toast |
| Project open fails | open throws `jj.config_error` with the "Check the config file" hint | `ProjectOpenFailed.hints` holds it; Projects notice shows title, context, hint, warnings | — |

</intent-contract>

## Code Map

- `app/lib/src/features/sync/push_sheet.dart:261-264` -- `_Note` for `model.planError` (`push-plan-error`) and `model.pushError` (`push-error`), text `error.context ?? error.code`. House pattern at :504 (`<String>[rejection.message, ...rejection.hints].join('\n')`). `_Note` (:1105) renders one `Text`, so `\n` gives one line per hint.
- `app/lib/src/features/sync/sync_model.dart:222-240` -- `_fetchFailedEntry`, `TextSpan(text: error.context ?? error.code)`; :332 `pushNow`'s `_pushFailedEntry((_) => error.context ?? error.code)` (the builder returns a string; failure path at :328 already joins `failure.message` + `failure.hint`).
- `app/lib/src/features/sync/push_sheet_model.dart` -- three user-visible `context ?? code`: :408 `changeRefusal` (shown at `push_sheet.dart:556`), :473 the fix-it error (`fixErrorOf`, shown at `push_sheet.dart:377`), :568 the commit check's `checkError` (shown at `push_sheet.dart:607,747`).
- `app/lib/src/features/projects/project_session.dart:88-99` -- `ProjectOpenFailed(code, context, {warnings})`; built only at :506 in `_failed`.
- `app/lib/src/features/projects/projects_window.dart:446-456` -- the only open-failure display: `_note(title, <String?>[context, ...warnings])` (`_note` at :379 drops null/empty lines). Every failed open (direct, Recent row, launch reopen via `reportFailedOpen` → `_failedOpen` :212) reaches this switch.
- `app/lib/src/features/home/home_page.dart:213-228` -- the epic's "`home_page.dart:217`" is not an open failure: it is the post-conversion Track toast (`_track`, `project-toast-track-error`), also `context ?? code`. It is named in the story's scope, so it gets the same one-line treatment.
- Read-only: `packages/zanshin_core/lib/src/worker/responses.dart:102-160` -- `ZanshinFfiException(code, [context])` (no hints) and `.withReport(code, context, precondition:, warnings:, hints:)` for tests.
- Read-only: `app/lib/src/features/graph/graph_toasts.dart:218-232` -- the graph toast's hint rendering (`\n$hint` spans), the precedent for toasts.
- Tests: `app/test/features/sync/push_sheet_test.dart`, `app/test/features/sync/push_sheet_model_test.dart` (fake throws at :286, :297, :346, :419), `app/test/features/sync/sync_model_test.dart` (fetch failure :144, pushNow refusal :517, `_toastText` helper), `app/test/features/projects/project_session_test.dart` (open failure :206), `app/test/features/projects/projects_window_test.dart` (failed-open notice :806).
- Catalogue: `app/widgetbook/folders/sync.dart` -- `_Sheet` enum (:55), `_DemoSync.push` (:265), `_SheetHost` (:455).

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/sync/push_sheet.dart` -- the two `_Note`s show `[context ?? code, ...hints].join('\n')`.
- `app/lib/src/features/sync/push_sheet_model.dart` -- `changeRefusal`, the fix-it error and `checkError` include the hints the same way.
- `app/lib/src/features/sync/sync_model.dart` -- `_fetchFailedEntry` and `pushNow`'s thrown-refusal toast include the hints.
- `app/lib/src/features/projects/project_session.dart` -- `ProjectOpenFailed` gains `final List<String> hints` (named, default `const <String>[]`); `_failed` passes `error.hints`.
- `app/lib/src/features/projects/projects_window.dart` -- the open-failure notice lines: context, hints, warnings.
- `app/lib/src/features/home/home_page.dart` -- the Track error toast includes the hints.
- `app/widgetbook/folders/sync.dart` -- a `_Sheet.refused` ("Refused with hints") state whose dry-run plan throws a `ZanshinFfiException.withReport` with a context and two hints.
- Tests (see AC).

**Acceptance Criteria:**
- Given a push plan or a push that throws with hints, when the sheet shows it, then `push-plan-error` / `push-error` show the context then each hint on its own line; given one without hints, the text equals the context (widget test, `push_sheet_test.dart`).
- Given a fetch or a `pushNow` that throws with hints, when the toast shows, then its text is the context followed by the hints (`sync_model_test.dart`).
- Given a change refusal, a fix-it failure or a commit-check failure thrown with hints, then `changeRefusal` / `fixErrorOf` / `checkError` include them (`push_sheet_model_test.dart`).
- Given an open that throws with hints, then `ProjectOpenFailed.hints` holds them (`project_session_test.dart`), and the Projects window's failed-open notice shows each hint (`projects_window_test.dart`).
- Given the catalogue, when "Push sheet › Refused with hints" opens, then the plan-error note shows the context and both hints, readable in Paper and Night against the DS's error note.

## Spec Change Log

## Review Triage Log

### 2026-11-16 — Review pass
- verdicts: 21 findings — high 0, medium 5, low 11, false 2, maybe-false 3 (layers: blind 8, edge-case 6, verification-gap 0, intent 7)
- note: patches applied by the parent run, not the step-03 subagent (a resumed subagent would answer asynchronously, which this unattended run cannot wait for).
- findings:
  - `[low]` `[reject]` (blind) The context+hints join is copied at 8 sites; one extension getter would keep the rule in one place — matches the house pattern (`push_sheet.dart:504`, `sync_model.dart` failure path); the fix adds new API surface for a one-line expression.
  - `[low]` `[reject]` (blind) `pushNow`'s hints sit inside the localized "The push failed: {detail}" placeholder — the app is English-only, `detail` stays jj's verbatim text; splitting it needs restructured spans for no visible gain.
  - `[low]` `[patch]` (blind) The Projects notice drops the code when the context is null but hints exist, against the spec's "or the code" rule — the notice now puts `code` above the hints when context is null and hints exist; with no hints it stays as before; new widget test.
  - `[low]` `[patch]` (blind) `sprint-status.yaml` still says `ready-for-dev` — set to `done` in the finalizing commit. (The two ledger items stay untouched on purpose: the loop annotates them from the Auto Run Result.)
  - `[low]` `[reject]` (blind) No-hints / no-context cases only partly tested — every site uses the same one expression, already pinned for both cases at other sites; no defect shown.
  - `[low]` `[patch]` (blind) One shared exception drives three model assertions, so a leak between paths would pass — each path now refuses with its own context and hints.
  - `[low]` `[patch]` (blind) The catalogue's demo refusal pairs `jj.config_error` with a revset parse message — code changed to `jj.invalid_input`.
  - `[low]` `[reject]` (blind) Convert/init/clone failures are not widget-tested with hints — they share the one `case ProjectOpenFailed` arm the tested path runs.
  - `[medium]` `[patch]` (edge) The fetch-failed toast draws one ellipsized line (`ZsToast` `maxLines: 1`), so hints after `\n` never show — the toast now carries the full text as its tooltip when there are hints (the open-report toast's pattern for several lines); test asserts the tooltip.
  - `[medium]` `[patch]` (edge) Same for the `pushNow` push-failed toast — grouped with the row above; `_pushFailedEntry` sets the tooltip whenever its text has several lines (this also surfaces the pre-existing `failure.hint` line); tests assert tooltip set / null.
  - `[medium]` `[patch]` (edge) Same for the Track error toast in `home_page.dart` — grouped; tooltip set when the text has several lines; test asserts it.
  - `[medium]` `[patch]` (edge) The toast tests check `toPlainText()`, not what the one-line toast shows — grouped; the tests now also assert the tooltip.
  - `[low]` `[patch]` (edge) Projects notice with null context shows hints without the code — duplicate of the blind row; same patch.
  - `[medium]` `[patch]` (edge, claim) The toast AC holds only in the semantics/plain text, not visually — grouped with the one-line toast entry; same patch.
  - `[false]` `[reject]` (intent) "The home page shows a failed open's hints" has no home-page surface — every failed open (direct, Recent row, launch reopen) reaches the Projects window notice (`project_session.dart:620`, `:273`), which now shows the hints; nothing is lost.
  - `[low]` `[reject]` (intent) Changing the Track error toast touches "bookmarks", a non-goal — the story's scope names `home_page.dart:217` literally; the change is one line and only adds jj's text.
  - `[low]` `[reject]` (intent) `push-error` without hints is not tested — the same expression as `push-plan-error`, whose no-hints case is tested.
  - `[false]` `[reject]` (intent) Toasts join with `\n` instead of `graph_toasts.dart`'s spans — the plain text is identical; the span shape changes nothing a user sees.
  - `[maybe-false]` `[reject]` (intent) `push_sheet_model` texts are tested at model level only — their display sites (`push_sheet.dart:377,556,607,747`) render the string unchanged; a widget test would settle it, but if true it is only low.
  - `[maybe-false]` `[reject]` (intent) Only the outside-open Projects path is widget-tested — the shared case arm makes a divergence unlikely; if true, low.
  - `[maybe-false]` `[defer]` (intent) The Widgetbook DS check in Paper and Night is unconfirmed — medium if true; settled by a Marionette check in a console session (deferred).

## Verification

**Commands (gate rule for this run: targeted checks only):**
- In `app/`, with the gate's pinned env: `flutter test test/features/sync test/features/projects test/features/home` -- expected: all pass.
- `dart analyze app` -- expected: no issues.
- `dart format --set-exit-if-changed` on the touched files -- expected: exit 0.

**Manual checks:**
- Widgetbook via Marionette: "Push sheet › Refused with hints" in Paper and Night, compared with the DS error note.

**Verification notes (2026-11-16, gate rule: targeted checks only):**
- `flutter test test/features/sync test/features/projects test/features/home test/l10n test/architecture` in `app/`, pinned env (`JJ_CONFIG="" GIT_CONFIG_GLOBAL="" JJ_USER/JJ_EMAIL/JJ_OP_* ZANSHIN_LOG_DIR XDG_CONFIG_HOME=<repo>/target/test-xdg-config`) -- 373 passed, after the review patches.
- `dart analyze` in `app/` -- no issues.
- `dart format` on every touched file -- formatted; `--set-exit-if-changed` exit 0 before the patches, re-formatted after them.
- Not run (gate rule): `cargo make test` / `test-full` / `coverage`. No Rust, FFI or schema change, so no cargo checks, codegen or parity oracle.
- Not done: the Marionette check in the running catalogue (Paper and Night, against the DS). The unattended run cannot launch and drive the long-running catalogue; deferred (see `deferred`).
- After the patches: `dart format --set-exit-if-changed lib/src/features test/features widgetbook/folders/sync.dart` -- 0 changed.

## Auto Run Result

Status: done
Blocking condition: none
Code commit: `d6c10ef624d7219be92018cea47db0d3da85b205`

**Summary.** Every surface the story names shows jj's hints under the context (or the code when there is no context), verbatim, one per line, with the push sheet's rejection-row pattern. An error without hints looks as before. `ProjectOpenFailed` carries the hints. Review found that `ZsToast` draws one ellipsized line, so the error toasts (fetch failed, push failed, Track) also carry the full text as their tooltip when it has several lines — the open-report toast's pattern.

**Files changed.**
- `app/lib/src/features/sync/push_sheet.dart` -- the two error notes show the hints.
- `app/lib/src/features/sync/push_sheet_model.dart` -- change refusal, fix-it error, commit-check error include the hints.
- `app/lib/src/features/sync/sync_model.dart` -- fetch-failed and push-failed toasts include the hints; tooltip for several lines.
- `app/lib/src/features/projects/project_session.dart` -- `ProjectOpenFailed.hints`, filled in `_failed`.
- `app/lib/src/features/projects/projects_window.dart` -- notice lines: context (else the code when hints exist), hints, warnings.
- `app/lib/src/features/home/home_page.dart` -- the Track error toast includes the hints; tooltip for several lines.
- `app/widgetbook/folders/sync.dart` -- "Push sheet › Refused with hints".
- Tests: `push_sheet_test.dart`, `push_sheet_model_test.dart`, `sync_model_test.dart`, `project_session_test.dart`, `projects_window_test.dart`, `home_page_test.dart`.

**Inbound items.**
- I1 -- fixed (`d6c10ef624d7219be92018cea47db0d3da85b205`): `push-plan-error` / `push-error` show the context then each hint; the commit check's error (`checkError`), the change refusal and the fix-it error do too.
- I2 -- fixed (`d6c10ef624d7219be92018cea47db0d3da85b205`): `ProjectOpenFailed` keeps the hints and the Projects window's open-failure notice (`projects_window.dart`, the one place every failed open is shown) lists them, so a config parse fault names its file again. The cited `home_page.dart:217` is not an open-failure note but the post-conversion Track toast; it shows its hints too.

**Review.** 21 findings (high 0, medium 5, low 11, false 2, maybe-false 3). Patched: 1 medium entry (the one-line toasts hid the hints: 5 medium rows grouped) and 4 low (null context in the Projects notice, distinct texts per path in the model test, the demo code, sprint-status). Deferred: 1 (the Marionette check, medium unverified). Rejected: the shared helper (house pattern, new API), hints inside the localized push sentence (English-only, verbatim), partial no-hint tests (same expression pinned elsewhere), untested convert/init/clone arms (same case arm), the home-page substitution (false: every failed open reaches the Projects notice), Track toast vs. the bookmarks non-goal (named in scope), `push-error` without hints (same expression), `\n` vs spans (false: same text), model-level tests for sheet texts and one tested Projects path (maybe-false, low if true).

**Follow-up review recommended: false.** One medium entry and no high were patched on this first pass.

**Verification.** See the verification notes above: targeted Flutter tests (373 passed), `dart analyze` clean, `dart format` clean; the full gate is left to the story loop.

**Residual risks.** The Marionette check in Paper and Night is owed (deferred). Hints in the error toasts show only on hover (the tooltip), since the toast stays one line by design; graph_toasts' pre-existing refusal toast has the same limit (outside this story).
