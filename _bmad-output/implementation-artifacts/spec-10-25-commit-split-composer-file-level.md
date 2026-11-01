---
title: 'Story 10.25 — Commit/split composer, file level — and Squash into parent with the combined-message flow'
type: 'feature'
created: '2026-11-01'
status: 'done'
baseline_revision: 'b523942365ffd20d388f3fcb547621fd8a2f47f1'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The composer, its checkboxes and the squash form were not checked in the running catalogue against the DS inspector; the Widgetbook has no composer use case of its own.
    evidence: |-
      Unattended run: no Marionette / Playwright check; only widget tests check the look. The composer shows in the catalogue only through the inspector demo.
    location: >-
      app/lib/src/features/graph/graph_inspector.dart (_Composer); app/widgetbook/folders/graph.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** The inspector shows a change's files and diff but cannot shape it: no file checkboxes, no composer for `jj commit` (on @) / `jj split -r` (elsewhere), and "Squash into parent" is disabled ("Comes with the commit composer"). The runner (`GraphAction`) has no commit/split verbs, so `_plan`/`_succeeded` give them no anchor, flash, born or selection rule (deferred I1, I2 — commit and split parts).

**Approach:** Add `GraphCommit` and `GraphSplit` to the sealed `GraphAction` (command, pending keys, `RepoGraphActions` mapping, `_plan`/`_succeeded` rules, toasts, menu names); give the inspector model a per-change file selection and composer drafts; draw file checkboxes, select-all and a composer island-bottom section (fields, result preview, command preview, Cancel / Commit|Split); enable Squash into parent through `squashPlan` → the describe form pre-filled with the combined text, sent as `editedDescription`.

## Boundaries & Constraints

**Always:**
- Paths go to the backend as repo-relative prefixes (`RepoHandle.commit(paths:)` / `split(paths:)`), shown in the command exactly as `GraphSquash` shows them: `root:<fileset string>` (`_filesetString`, shell-quoted) — the preview string IS `action.command` of the action that runs.
- Commit: `GraphCommit(id, message: paragraphs, paths)`; `paths` empty when every listed file is selected; command `jj commit -m S [-m D] [root:p …]` (no id: the CLI commits @). Split: `GraphSplit(id, message: paragraphs, paths)`, always with the selected paths; command `jj split -r <short> -m S [-m D] root:p …`. Paragraphs = `InspectorViewModel.paragraphsOf(draft)` (summary always, so an empty summary sends `-m ''`; details only when non-empty). The handle joins them (CLI `join_message_paragraphs`).
- `RepoGraphActions`: commit → `handle.commit(message:, paths:)`; split → `handle.split(revision: id, paths:, message:)`, returning a `MutationResult` that copies `SplitResult.mutation`'s fields and carries `SplitResult.warnings` (the nested result has none).
- Runner rules: commit — anchor = id, flash = [id], born = new @ (`newChangeIds.first`), selection moves to the born change when id was selected, and it is revealed when covered (as `GraphNew`); split — anchor = id, flash = [id], born = the remaining change, selection stays. `pendingKeys` = {id}.
- Selection (per inspector key, only on mutable non-root changes with files): @ starts with every listed file, any other change with none; it is reset when the selected key changes; a reload keeps it filtered to the still-listed paths. Select-all checks every file, or unchecks all when all are checked. Two-state boxes (`ZsCheckbox`, size sm, accent tone) in the rows (the row click still focuses the diff; the box toggles) and in the Changes header.
- Composer shows on a mutable change when (@ and it has files) or (not @ and ≥1 file selected); it sits below the scroll area, at the island's bottom (DS kit.css:129-144: padding 14 16, gap 10, top border `--fl-border`, `--fl-sheen`), enters rising 12 px × `--motion` + fade on `durSlide`/`easeGlide`, leaves with a fade on `durExitLg`/`easeExit` (`ZsPresence`); reduce motion keeps only the fades (`ZsMotion.motion`).
- Composer fields: Summary (placeholder "Summary of what you did" on @, "Summary of the selected changes" elsewhere) and Details (`inspectorDetails`), md size; drafts per change key for the session; ↩ in Summary and ⌘↩ run; Esc while typing in a non-empty composer draft only leaves the field (panel stays).
- Result preview (two rows, child on top, DS zk-comp-node): @ — "@ New working copy · <n files ±> · stays here to keep working" (empty → "empty"); else "Rest · <n files ±> · keeps “<subject>”". Below "Selected · <n files ±> · “<first line of summary>”" or "nothing yet" / "no description yet". ± = sums of the 10.24 summary's `added`/`removed` per file (omitted when no summary).
- Buttons: Cancel only on split (clears the selection, keeps the draft); gold Commit/Split. Commit disabled with nothing selected; Split runs with everything selected and then shows jj's hint "All changes have been selected, so the original revision will become empty." (`../jj` v0.46.0 cli/src/commands/split.rs:588) under the footer. Both disabled with `graphBlockedReason`.
- Run: through `graph.run`. Done → the draft and selection of that key clear. Refused → draft and selection stay; the composer shows `error.context ?? error.code` in a warn line; `graphOutcomeEntry` shows NO toast for a refused commit/split (composer refusals stay in the composer).
- Toasts: "Committed {change} · “{subject}”" (first line of the first `-m`; without it just "Committed {change}") and "Split {change} — the rest is now {rest}" (rest = `born.first`), with Undo as other verbs. App menu names: "Commit {target}", "Split {target}".
- Squash into parent (inspector action row, the card menu's row, Change › Squash — all via `InspectorViewModel.squash(id)`, which selects `id`): the inspector button is enabled unless `changeActions.squashIntoParent` is refused (then disabled with its `context ?? code`). Click → `GraphDetails.squashPlan(id)` (`RepoHandle.squashPlan(revision: id)`); a non-null `combinedDescription` opens the describe form in squash mode pre-filled with `draftFrom(combined)`, title of the Save button "Squash", command `jj squash -r <short>` (the CLI opens its editor there); Save runs `GraphSquash(revision: id, editedDescription: joinMessageParagraphs(paragraphsOf(draft)))`; Cancel / Esc closes it with no call. A null description runs `GraphSquash(revision: id)` at once; a refused plan runs `GraphSquash(revision: id)` too so the runner reports jj's refusal (it refuses identically). `-u`/`-k` keep their CLI defaults (off).
- Strings in `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`); jj's own sentences, commands and symbols are literals with `// l10n-ignore: <reason>`. Controls only from `zanshin_ui`.

**Never:** hunk checkboxes or a mixed state (10.26), a tree selection or `-i` (10.26), drags (10.27), `split --parallel`/`-o`/`-A`/`-B` from the composer, a composer on an empty @, a squash `-m` from the combined form (it goes as `editedDescription`, Note 2026-10-20), rebase/duplicate actions (10.10), Rust/FFI/schema changes.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| @ opens | @ with a.txt, b.txt | both checked, composer shows, preview `jj commit -m ''` | — |
| Commit all | S="Fix", D="Body", all checked | one `commit(message:['Fix','Body'], paths:[])`; selection → new @ | — |
| Commit subset | only a.txt | `commit(paths:['a.txt'])`, preview `jj commit -m Fix root:a.txt` | — |
| Nothing selected on @ | none checked | Commit disabled | — |
| Other change | x with 2 files | none checked, no composer; check one → composer "Split" | — |
| Split | x, a.txt checked, S="Part" | `split(revision:x, paths:['a.txt'], message:['Part'])`; selection stays on x; toast "Split x — the rest is now y" | — |
| Split everything | all checked | hint shows jj's sentence; Split runs | — |
| Refusal | runner refuses | draft + selection stay, warn line shows jj's text, no toast | — |
| Draft survives | type, select another change, come back; or reload | draft text still there | — |
| Path with `[` | `a[1].txt` | command `root:"a[1].txt"`, call `paths:['a[1].txt']` | — |
| Squash, two descriptions | plan returns "A\n\nB\n" | form pre-filled (Summary A, Details B); Save → `GraphSquash(revision:x, editedDescription:'A\n\nB\n')` | Esc/Cancel: no call |
| Squash, one description | plan null | `GraphSquash(revision:x)` at once | refused plan → same run, runner reports |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_ports.dart:174-338` -- sealed `GraphAction`; `GraphSquash` (paths as `root:${_filesetString}`) is the pattern for `GraphCommit` / `GraphSplit`; `_message`, `_jj`, `_shellQuote` helpers at :549-597. `RepoGraphActions.run` :702-743 (exhaustive switch). `GraphDetails`/`RepoGraphDetails` :762-790 — add `squashPlan(String changeId)`.
- `packages/zanshin_core/lib/src/worker/handle.dart:1104` `squashPlan`, `:1160` `split` (returns `SplitResult{mutation, selectedChangeId, remainingChangeId, warnings}`), `:1580` `commit(message:, paths:)`; `MutationResult` const ctor public (`ffi/mutate.dart:184`); `SquashPlan`, `SplitResult` already exported (`zanshin_core.dart:110`). No bridge change needed.
- `app/lib/src/features/graph/graph_view_model.dart:766-852` -- `_plan` / `_succeeded`: add the commit/split rules; `:824` the covered reveal for born changes.
- `app/lib/src/features/graph/graph_toasts.dart:133-296` -- `graphOutcomeEntry` (skip refused commit/split) and `_text` (exhaustive switch: add commit/split).
- `app/lib/src/features/shell/app_menu.dart:187-212` -- `actionName` exhaustive switch.
- `app/lib/src/features/graph/graph_inspector.dart` -- `InspectorViewModel` (:42-432; drafts :247-324, `_graphChanged` :326, `_fetch` :366): add selection, composer drafts, `runComposer`, `composerError`, squash flow (`squash(key)`, squash-form state, `saveSquash`). Widget: `_panel` :529 (Column → add the composer below `Expanded`), `_onKey` :485 (Esc rules), `_DescribeForm` :863 (reuse for squash mode: Save label/command/onSave), `_Actions` :1165 (Squash enablement :1207-1246), `_Changes` :1279 header (select-all) and rows :1461 / `_FileRow` :1503 (checkbox).
- `app/lib/src/features/graph/graph_card_menu.dart:104, :203-213, :606-650` -- add `onSquash` like `onDescribe`; host passes `inspector?.squash`.
- DS (read-only): `_bmad-output/implementation-artifacts/design_system/ui_kits/desktop/inspector.jsx:40-79, :171, :184-188, :203`; `kit.css:128-144`.
- Zs: `ZsCheckbox` (`packages/zanshin_ui/lib/src/controls/zs_checkbox.dart:72`), `ZsPresence` (`zs_presence.dart`; usage pattern `app/lib/src/features/graph/at_pill.dart:133-190`), `ZsMotion` (`durSlide`, `easeGlide`, `durExitLg`, `easeExit`, `motion`), `ZsTextField`, `ZsButton`, `ZsTooltip`, `ZanshinIcon(ZI.workingCopyAt)`.
- l10n: `app/lib/l10n/app_en.arb` (`inspectorSquashLater` :586 goes; add composer, toast, menu strings).
- Fakes implementing `GraphDetails`/`GraphActions`: `app/test/features/graph/{graph_inspector_test,graph_card_menu_test,graph_toasts_test,graph_view_model_test,graph_view_test,graph_controls_test}.dart`, `app/test/features/shell/app_menu_test.dart`, `app/widgetbook/folders/graph.dart`.
- Real-cdylib tests: `app/test/features/graph/graph_ports_test.dart:207-320` (`setUpRepo`, `openRepo`).

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphCommit`, `GraphSplit`; `RepoGraphActions` mapping (split warnings carried); `GraphDetails.squashPlan` -- I1.
- `app/lib/src/features/graph/graph_view_model.dart` -- `_plan`/`_succeeded` commit/split rules (anchor, flash, born selection/reveal) -- I1, I2.
- `app/lib/src/features/graph/graph_toasts.dart`, `app/lib/src/features/shell/app_menu.dart` -- texts and names; no toast for a refused commit/split.
- `app/lib/src/features/graph/graph_inspector.dart` -- model selection/drafts/composer run/squash flow; checkboxes, select-all, composer widget (new private `_Composer`), squash-mode describe form, Squash enablement, Esc rules.
- `app/lib/src/features/graph/graph_card_menu.dart` -- `onSquash` routed through the inspector.
- `app/lib/src/features/shell/app_menu.dart` (`GraphMenuBinding.squash`, Change › Squash), `app/lib/src/features/home/project_graph_host.dart:142` (pass `inspector.squash`) -- the third trigger.
- `app/lib/l10n/app_en.arb` -- strings; `flutter gen-l10n`.
- Fakes and widgetbook demo -- `squashPlan`.
- Tests: `graph_ports_test.dart` (commands of commit/split incl. `[` path and `-m ''`; real cdylib: committing one of two files leaves the other in the new @; split through the runner), `graph_view_model_test.dart` (commit/split selection, anchor, flash, born), `graph_toasts_test.dart` (texts; refused commit no toast), `graph_inspector_test.dart` (every I/O matrix row; select-all; Cancel; Esc; drafts survive selection change and reload; composer exit/reduce-motion entry; squash both cases), `graph_card_menu_test.dart` (squash row calls the inspector).

**Acceptance Criteria:**
- Given @ selected with two changed files, when the inspector loads, then both boxes are checked and the composer shows "Commit" with the command `jj commit -m ''`.
- Given a non-@ mutable change, when one file is checked and Split pressed, then exactly one `GraphSplit` runs whose `command` equals the composer's shown command.
- Given reduce motion, when the composer appears, then it does not move (only its opacity animates).
- Given Squash on a change whose plan reports a combined description, when the user saves the pre-filled form, then the squash carries `editedDescription` and no `message`.

## Spec Change Log

- 2026-11-01 (build): the composer's split runs `GraphSplit(fullKey, shown: shortId)` so the preview equals `command` with the short id while jj gets the full one (the inspector's other buttons build a second short-id action for their tooltip instead). The squash form closes on a selection change (no per-change squash drafts). Marionette visual check not run (unattended) — deferred.

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 36 findings — high 0, medium 3, low 25, false 8, maybe-false 0
- findings:
  - (verification-gap) `[low]` `[patch]` Undo/Redo menu names of commit/split unpinned — `actionName` cases added to `app_menu_test.dart`.
  - (verification-gap) `[low]` `[patch]` `RepoGraphDetails.squashPlan` and host wiring unexercised — real-repo `squashPlan` case added to `graph_ports_test.dart`; the host-level wiring check rejected (one line beside the binding's other fields, as 10.24 decided for its store).
  - (verification-gap) `[low]` `[patch]` split warnings forwarding unverified — the real-repo split-everything case asserts jj's split-all-selected warning on the outcome.
  - (blind) `[medium]` `[patch]` the composer starts empty, so untouched fields send `-m ''` and erase a described change's text, where the CLI's editor starts with the description — the composer's initial draft is `draftFrom(<current description>)` when none exists (an undescribed @ still previews `jj commit -m ''`).
  - (blind) `[false]` `[reject]` no composer on an empty @ — the intent lists it as a non-goal (epics.md 10.25 Non-goals).
  - (blind) `[low]` `[patch]` with nothing checked on @ the command line shows `jj commit` (commit everything) — no command text while `composerAction` is null.
  - (blind) `[false]` `[reject]` the split-all hint is a hard-coded English literal and may show twice — jj's own sentence is a literal marked `l10n-ignore` by the project rule; after a successful split the composer goes, so the toast's warn clause is the only other place.
  - (blind) `[low]` `[reject]` every file checkbox shares one identifier — the rows' other elements (`inspector-file-viewed`) do the same; per-row ids are a convention change, not a correction.
  - (blind) `[low]` `[reject]` squash races (selection moved during the plan; double click) — moving away drops the request on purpose; a second click's run meets the runner's busy guard.
  - (blind) `[medium]` `[patch]` the squash form keeps a stale combined description across a reload of the same key — `_squashForm` clears on a new operation and while stale.
  - (blind) `[low]` `[patch]` the composer's refusal stays after edits — cleared on check and text changes.
  - (blind) `[low]` `[patch]` checkboxes and composer stay live while stale — `_mutableNode` is null while stale.
  - (blind) `[low]` `[reject]` `_split` copies `MutationResult` field by field — there is no copyWith; no field is lost today and a new one would be added there with its decoder.
  - (blind) `[low]` `[reject]` text typed while a run is in flight is cleared — the run takes well under a second; not everyday use.
  - (blind) `[low]` `[reject]` `GraphCommit` does not pin @ — the CLI's `jj commit` commits whatever @ is too; any op reloads the layout first.
  - (blind) `[low]` `[reject]` untested paths (refused squash save, menu squash with a combined text, a reload dropping a checked path) — each covered by the shared code a tested path runs; more tests than a correction.
  - (blind) `[low]` `[defer]` no Widgetbook composer use case — part of the deferred Marionette catalogue check.
  - (edge) `[low]` `[reject]` a refusal after the selection moved during the run is shown nowhere — needs a move during a sub-second run.
  - (edge) `[low]` `[reject]` `GraphActionDisabled` from a busy race gives no feedback — the button is disabled while busy; the race window is one frame.
  - (edge) `[low]` `[reject]` selection change during `squashPlan` drops the request — dup of the blind race row.
  - (edge) `[false]` `[reject]` a non-`ZanshinFfiException` from `squashPlan` escapes — a closed handle is a programming error that must be loud (10.24's rule for the same port).
  - (edge) `[low]` `[reject]` the menu's squash bypasses `_run`'s catchError — only programming errors escape (`graph.run` catches every refusal); same as the row above.
  - (edge) `[medium]` `[patch]` stale combined description after a reload — dup of the blind row; same fix.
  - (edge) `[low]` `[patch]` Esc closes a hidden squash form while stale — the form clears while stale.
  - (edge) `[low]` `[patch]` `_mutableNode` ignores stale — dup; same fix.
  - (edge) `[low]` `[patch]` wrong command with nothing checked — dup; same fix.
  - (edge) `[false]` `[reject]` the widgetbook demo's `squashPlan` crashes on an absent id — the demo only calls it for the selected card, which is in the layout.
  - (intent) `[false]` `[reject]` the squash form's command lacks `-m` — the 2026-10-20 note (newer) sends the edit as `edited_description`, never `-m`; the command shows what the CLI runs before its editor.
  - (intent) `[false]` `[reject]` paths as `root:` instead of `file:` — `root:` is exactly the backend's repo-relative prefix semantics (`RepoHandle.commit/split` paths) and the form `GraphSquash` already shows, so the preview equals the call.
  - (intent) `[low]` `[patch]` the composer's exit has no drift — the closing offset now drifts 12 × `--motion` as it fades.
  - (intent) `[false]` `[reject]` "S\n\nD\n" asserted as paragraphs — the real-cdylib test asserts the stored `Fix\n\nBody\n`; the fake tests assert what the port receives.
  - (intent) `[false]` `[reject]` the split-all hint is static — item 6: the CLI's warning is the hint shown with everything selected, before the run.
  - (intent) `[low]` `[reject]` card menu and Change › Squash routed through the inspector — the CLI asks for the combined text whatever triggers squash; behaving like the CLI is required.
  - (intent) `[low]` `[reject]` the runner toast is suppressed for commit/split refusals — the epic's 10.9 note: composer refusals stay in the composer.
  - (intent) `[low]` `[reject]` I1/I2 tested at the view-model level — the rules live there; the composer tests cover the UI path.
  - (intent) `[low]` `[reject]` the remaining items match — no divergence reported.

## Design Notes

- Squash's combined text goes as `editedDescription` (Note 2026-10-20 supersedes the 2026-10-16 "shows -m" line): the form's command is `jj squash -r <id>`, what the CLI runs before its editor opens.
- The composer uses the CLI's `-m` arm for commit/split (the fields are new text, not an editor round-trip), so jj adds `templates.commit_trailers` exactly as `jj commit -m` does.
- Always calling `squashPlan` before a squash (instead of trusting the preview's `combinedDescriptionNeeded`) keeps one path for both triggers and costs one read.
- Every Squash-into-parent trigger (inspector row, card menu row, Change › Squash) goes through `InspectorViewModel.squash(id)`, which selects `id` first (the form lives in the inspector): `GraphMenuBinding` gains an optional `squash` callback the project window fills with `inspector.squash`; without it the menu runs `GraphSquash` as before.

## Verification

**Commands:**
- `cd app && flutter gen-l10n` then `flutter test test/features/graph test/features/shell test/l10n test/widgetbook` (Makefile.toml test env for the real-worker tests) -- expected: green.
- `cd app && dart analyze --fatal-infos . && dart format --set-exit-if-changed .` -- expected: no issues, 0 changed.
- Not run (gate rule): `cargo make test`/`test-full`/`coverage`; no Rust/FFI/schema change, so no cargo checks, codegen or parity oracle.

**Manual checks (if no CLI):**
- Marionette check of the composer in the catalogue against DS inspector — not possible unattended; deferred if skipped.

**Verification notes (2026-11-01, this run):**
- `app`: `flutter gen-l10n` ran. `flutter test test/features/graph test/features/shell test/l10n test/widgetbook` (Makefile.toml test-flutter env) — before the review patches 1285 passed, 1 failed: `revset_configs_window_test.dart` "saved configurations and the default survive a restart…", a file this story does not touch, the flake 10.24 recorded; it passed alone (18/18). After the review patches: 1291 passed, 0 failed. `dart analyze --fatal-infos .` no issues; `dart format --set-exit-if-changed .` 0 changed.
- Real cdylib (in that run): commit of one of two files leaves the other in the new @ (description `Fix\n\nBody\n`); split through the runner, incl. jj's split-all-selected warning on the outcome; `RepoGraphDetails.squashPlan` null / combined.
- Not run: cargo checks, `cargo make codegen`, parity oracle (no Rust/FFI/schema/jj-verb change); full gate and coverage (gate rule); Marionette check (unattended; deferred).

## Auto Run Result

Status: done. Commit c56d3af73b7f54dcfd49aa3959cd9c50d823f96c (code); spec, ledger and sprint-status in the following commit.

**Summary.** The runner gained `GraphCommit` (`jj commit -m … [root:<path>…]`, no paths when every file is checked) and `GraphSplit` (`jj split -r <id> -m … root:<path>…`), mapped to `RepoHandle.commit` / `split` (split's warnings carried onto the result), with their runner rules: both anchor on and flash the change; commit's new @ is born, selected and revealed when covered; split's rest is born and the selection stays. The inspector draws two-state checkboxes on a mutable change's files and a select-all (@ starts with all, others with none; reset per selection, kept across reloads), and the composer at the island's bottom: Summary/Details pre-filled from the change's description (as the CLI's editor), a result preview with ±, the command that runs, Cancel on split, gold Commit/Split (⌘↩, ↩ in Summary), jj's all-selected hint, refusals in its warn line (no toast); drafts per change; rise + fade in, drift + fade out, only fades under reduce motion. Squash into parent is enabled unless jj refuses it; every trigger (inspector, card menu, Change › Squash) asks `squashPlan` and opens a pre-filled form sent as `editedDescription` (command `jj squash -r <id>`), or runs at once. Toasts "Committed … · “…”" / "Split … — the rest is now …"; menu names "Commit …" / "Split …".

**Files.**
- `app/lib/src/features/graph/graph_ports.dart` — `GraphCommit`, `GraphSplit`, `RepoGraphActions` mapping, `GraphDetails.squashPlan`.
- `app/lib/src/features/graph/graph_view_model.dart` — commit/split anchor, flash, born, selection, reveal.
- `app/lib/src/features/graph/graph_inspector.dart` — selection, composer drafts/run, squash flow; checkboxes, `_Composer`, `_ComposerMotion`, squash-mode describe form, Squash enablement, Esc rules.
- `app/lib/src/features/graph/graph_toasts.dart`, `app/lib/src/features/shell/app_menu.dart`, `app/lib/src/features/graph/graph_card_menu.dart`, `app/lib/src/features/home/project_graph_host.dart` — toasts, menu names, `GraphMenuBinding.squash`, card menu `onSquash`.
- `app/lib/l10n/app_en.arb` (+ generated) — strings (`inspectorSquashLater` removed); `app/widgetbook/folders/graph.dart` — demo `squashPlan`.
- Tests: `app/test/features/graph/{graph_inspector_test,graph_ports_test,graph_view_model_test,graph_toasts_test,graph_card_menu_test}.dart`, `app/test/features/shell/app_menu_test.dart` (+ fakes in graph_view_test, graph_controls_test).

**Review.** 36 findings (high 0, medium 3, low 25, false 8). Patched: composer pre-filled from the description (medium), stale squash form cleared on a new op / stale (medium, with its dup), refusal cleared on edits, no checkboxes/composer while stale, no command text with nothing checked, exit drift, tests for menu names, real-repo `squashPlan` and split warnings (low). Deferred (1): the catalogue/Marionette check. Rejected: every other row, with its reason in the triage log.

**Follow-up review recommendation:** false — two medium entries were patched (the description pre-fill and the stale squash form), each a small, tested change; no unverified risk remains that a second pass would settle beyond the deferred visual check. Patched by verdict: medium 2, low 7.

**Items.**
- **I1** — fixed (c56d3af7): `GraphCommit` / `GraphSplit` subtypes, the `RepoGraphActions` mapping and their selection/anchor rules (commit → the new @, split → stays; both anchored on the source). Rebase and duplicate stay with 10.10.
- **I2** — fixed (c56d3af7): `_plan`/`_succeeded` give commit and split their anchor (the source), flash (the source) and born key (the new @ / the rest). The ghost rect, rebase, insert and duplicate stay with 10.10.

**Residual risks.** The composer was not checked in the running catalogue. A refusal that lands after the selection moved away shows nowhere. `GraphSplit.shown` prints the short id in the split's Undo/Redo toast commands. One flaky pre-existing test (`revset_configs_window_test.dart`) failed once and passed on rerun.
