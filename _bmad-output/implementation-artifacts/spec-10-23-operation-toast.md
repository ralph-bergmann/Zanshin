---
title: 'Story 10.23 — Operation toast: what an operation did, with Undo / Redo; refusal, warning and failure variants'
type: 'feature'
created: '2026-11-01'
status: 'done'
baseline_revision: 'ec2d953b905b2d4867dc69a775ed31801db56866'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The graph's toasts (GraphToasts: every outcome text, Undo/Redo, the stale-recovery result and failure with Retry of I3) reach no production surface until 10.12 mounts the graph in the project window.
    evidence: |-
      GraphToasts( is built only in app/widgetbook/folders/graph.dart and the tests; HomePage's FloatingShell has no graph slot yet. The binding is tested in app/test/features/graph/graph_toasts_test.dart against a ShellToastView.
    location: >-
      app/lib/src/features/graph/graph_toasts.dart
    severity: medium
  - summary: >-
      The toast's look, motion and the backdrop blur during its fade (I1) have not been checked in the running catalogue against the DS Toast card; only widget tests check them.
    evidence: |-
      Unattended run: the Widgetbook catalogue cannot be run in the background, so the Marionette / Playwright check was not done. shell_toast_test.dart asserts ZsFade under the motion and no Opacity/FadeTransition above the glass, not the rendered blur.
    location: >-
      app/lib/src/features/shell/shell_toast.dart
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** 10.9's runner publishes every outcome (`GraphViewModel.outcome`, `undoable`/`redoable`) and 9.23's stale recovery keeps `lastStaleRecovery`/`staleUpdateError`, but nothing shows them; the shell's bottom slot (11.3) waits for a toast, and the Projects window stays open after a creation with warnings only because no toast exists (11.12 interim).

**Approach:** One DS Toast component in `zanshin_ui` (`ZsToast`, look only), one toast host in the shell (`ShellToasts` queue + `ShellToastView`: one at a time, hold 6.5 s paused on hover, rise-and-fade motion, replacement fade, F6 reach), owned by `FloatingShellViewModel`; a graph binding (`GraphToasts`) that turns the model's outcomes and stale results into toasts; and the project window (`HomePage`) showing a creation's warnings from `ProjectSession`, so Projects always closes after an open (I2). Epics.md Story 10.23 incl. its design updates 2026-10-16 and 2026-10-26 is the scope; DS synced through #13.

## Boundaries & Constraints

**Always:**
- Look per DS Toast (Toast.prompt.md, overlays.css:4-22): 36 px (`--control-lg`) glass pill `ZsGlass(fill: strong, blur: regular, radius: radiusPill)`, padding 0 5 0 15, gap 8, text `ZsType.control` `--text` one line ellipsized; warn = `ZI.conflict` in `--warn`, error = `ZI.alert` in `--rem` (icon margin-left −3); action buttons 26 px (`--control-sm`) pills, padding 0 13, margin-left 4, 500 weight `--text`, fill `--fl-hover` → hover `--fl-on` → pressed `--fl-press`, tooltip = the jj command; × a 26 px circle, `ZI.close` xs in `--text-dim`, hover `--fl-hover`/`--text`, pressed `--fl-on`, labelled "Dismiss". Focus ring `--focus-ring` through `ZsControlCore`.
- Motion: in = 10 px rise × `--motion` + fade on `--dur-slide`/`--ease-glide`; out = 8 px down × `--motion` + fade on `--dur-exit-lg`/`--ease-exit`; a replaced toast fades in place on `--dur-exit` while the new one enters. Glass fades only through `ZsFade` (I1) — never an `Opacity`/`FadeTransition` ancestor of the glass.
- Lifetime: one at a time (a new entry replaces the current and the hold restarts); success and warn hide after `--dur-toast-hold` (6.5 s), the hold paused while the pointer is over the toast or focus is inside it; error stays until × or its action; × hides at once. The slot is non-null while a toast shows or exits, so 11.3's @ pill hides and returns after it.
- Texts come from the outcome's structured data (action fields, `MutationResult`), never parsed from CLI output. Past tense, verb first; change ids mono, jj's shortest prefix bold, max(prefix, 8) characters (decision 16.35; prefix from the current layout's `changeIdPrefixLengthOf`, 2 when the layout lacks the id, as the search does); bookmark names mono. jj's words and commands are literals `// l10n-ignore`; the rest goes through the ARBs.
- Undo shows only while `model.undoable` is identical to the toast's outcome, Redo only while `model.redoable` is; the button goes when the head moves, the text stays. Pressing one dismisses the toast and calls `undoLast()`/`redoLast()` once.
- Semantics: success/warn a live region (polite, announced when it appears), error `SemanticsRole.alert`; label = the plain text. Buttons are skipped by Tab while focus is outside the toast; F6 (in the shell) moves focus to the toast's first button, then Tab moves between its buttons.

**Never:**
- No history or stack of toasts; no ⌘Z/⇧⌘Z binding (11.13 binds them to `undoLast`/`redoLast`); no Undo Timeline (11.9); no identity remedy.
- No texts for verbs that have no `GraphAction` yet (drops 10.10, commit/split 10.25, file drops 10.27, duplicate, push 11.8 incl. "Undoing a push…", `op abandon`): their stories add their case to the mapping.
- No toast for a `jj.stale_working_copy` refusal (the stale notice is that surface).
- No change to `GraphViewModel`'s runner semantics, nothing under `design/` or `design_system/`, no Material widgets.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Abandon | `GraphAbandon([a])` done, wrote | "Abandoned ‹a›" + Undo (`jj undo`) | — |
| Abandon several | `GraphAbandon([a, b, c])` | "Abandoned ‹a›, ‹b› and ‹c›" (localized list) + Undo | — |
| Revert | `GraphRevert(x)`, born y | "Reverted ‹x› — ‹y› undoes it" + Undo | — |
| Squash | `GraphSquash(revision: s)` / `from: [s], into: t`, destination = `outcome.flash.first` | "Squashed ‹s› into ‹t›" + Undo; source falls back to `result.abandonedChangeIds.first`, else "@" | — |
| Bookmarks | create / delete / move / rename | "Created ‹N› on ‹X›" (X = revision, else @'s change before the run from the result's `workingCopyChangeId`), "Deleted ‹N›", "Moved ‹N› to ‹T›", "Renamed ‹N› to ‹M›" + Undo | several names joined as a list |
| Silent verbs | new / edit / describe, no warnings | no toast | — |
| Silent verb with warnings | same, with 9.32 warnings | warn tone, the warnings' messages joined " · ", no Undo | — |
| Success with warnings | any toasting verb + warnings | its text + " · " + warning message(s) in `--warn` | — |
| Undo / redo | `GraphUndo(of)` / `GraphRedo(of)` done | "Undid `‹of.command›`" + Redo (`jj redo`) / "Redid `‹of.command›`" + Undo | — |
| Foreign op | head moved after the toast | Undo/Redo button gone, text stays; an undo that still meets `foreignOperation` shows warn "Nothing undone — another operation came after it" | — |
| Refusal | `GraphOutcome(error:)` | warn tone, `error.context ?? error.code` verbatim, no Undo, hides after 6.5 s | `jj.stale_working_copy`: no toast |
| Stale recovery | `updateStale()` result | notStale: "Attempted recovery, but the working copy is not stale."; updated: "Updated the working copy to ‹commit 12›"; recovered: "Created and checked out recovery commit ‹commit 12›" (jj's texts); never Undo | warnings → clause |
| Stale failure | `staleUpdateError` set | error tone "Updating the working copy failed — ‹context ?? code›" + Retry (tooltip `jj workspace update-stale`, runs `updateStale()`); stays | — |
| Creation report (I2) | `ProjectOpened` with warnings | Projects closes; the project window shows "Opened ‹name›" + warn clause(s), tooltip with every line, no Undo | report consumed once |

</intent-contract>

## Code Map

- `app/lib/src/features/shell/floating_shell.dart` -- `toast` slot (:118, :287 `widget.toast ?? _bottomPill`), bottom `Positioned` between `insets.left/right` at `bottomSlot` 20 (:416-423); `_key` (:211) handles Esc only — F6 goes here; `_viewFocus` pattern for a region node.
- `app/lib/src/features/shell/floating_shell_view_model.dart` -- owns `shell`; add `toasts` (dispose).
- `app/lib/src/features/graph/graph_view_model.dart` -- `outcome` (:383), `undoable`/`redoable` (:386-389, identity), `undoLast`/`redoLast` (:518-535, return `GraphActionDisabled(foreignOperation)`), `updateStale` (:492, `lastStaleRecovery`/`staleUpdateError`), `layout` for prefixes, `_succeeded` (:630) sets flash = squash destination / bookmark-move target.
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphAction` subclasses (:167-455, each `command`), `GraphOutcome` (:557; `warnings`, `born`), `GraphActionDisabled`.
- `app/lib/src/features/graph/at_pill.dart` -- reference for rise/fade through `ZsFade` (`_PillMotion` :158-209).
- `app/lib/src/features/graph/graph_search_field.dart:1336-1356` -- the change-id span recipe (bold prefix, max(prefix, 8)).
- `app/lib/src/features/graph/graph_view.dart` -- static slot builders (`staleNotice`, `atPill`); add `GraphView`-independent binding file instead.
- `app/lib/src/features/home/home_page.dart` -- the project window's `FloatingShell`; add `toast:` + the report listener.
- `app/lib/src/features/projects/project_session.dart` -- `_switchTo` (:346) returns `ProjectOpened(warnings)`; add the report.
- `app/lib/src/features/window/app_window_coordinator.dart` -- `_afterOpenInProjects` (:199-219) keeps Projects for warnings, doc :40-42; `_firstFocusTimeout` used only there.
- `app/lib/src/features/projects/projects_window.dart:63-64` -- doc on keeping Projects with warnings.
- `packages/zanshin_ui/lib/src/materials/zs_glass.dart:45` -- the toast's glass recipe; `zs_fade.dart`; `controls/zs_control_core.dart` (states, ring, semantics, `focusNode`); `controls/zs_tooltip.dart`; `design/zs_motion.dart` (`durToastHold`, `motion`, reduced); `lib/zanshin_ui.dart` exports; `lib/l10n/zs_en.arb` (+ `flutter gen-l10n` in `packages/zanshin_ui`).
- `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n` in `app`) -- toast copy.
- `app/widgetbook/folders/graph.dart` (`_StaleNotices` :989 pattern) -- catalogue use case; `app/test/widgetbook/catalogue_smoke_test.dart`.
- Tests: `app/test/features/shell/floating_shell_test.dart`, `app/test/features/home/home_page_test.dart`, `app/test/features/window/app_window_coordinator_test.dart`, `app/test/features/projects/` session tests, `app/test/helpers/scripted_graph_source.dart`, `app/test/features/graph/graph_view_model_test.dart` (fake actions recipe), `packages/zanshin_ui/test/controls/`.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/controls/zs_toast.dart` -- `ZsToastTone {success, warn, error}`, `ZsToastAction(label, tooltip, onPressed, identifier)`, `ZsToast(tone, message: InlineSpan, actions, onDismiss, tooltip?, actionFocusSkip)`: the look above; export it; `toastDismiss` "Dismiss" in `zs_en.arb` + regenerated localizations -- the DS component, look only.
- `packages/zanshin_ui/test/controls/zs_toast_test.dart` -- height 36, tones' glyphs/colours, buttons 26 with tooltips, × label, semantics (live region vs alert).
- `app/lib/src/features/shell/shell_toast.dart` -- `ShellToastEntry(tone, build(context, dismiss) → ZsToast, listenable?)`; `ShellToasts` (ChangeNotifier: `current`, `show`, `dismiss`, view's `exited`); `ShellToastView` (motion, hold timer paused on hover/focus, replacement layer, focus region whose buttons skip traversal until focus is inside) -- the one host.
- `app/lib/src/features/shell/floating_shell.dart` + `floating_shell_view_model.dart` -- F6 focuses the first focusable node in the toast region (wrap the bottom slot in a region `Focus`); the view model owns and disposes `ShellToasts toasts`.
- `app/lib/src/features/graph/graph_toasts.dart` -- `GraphToasts(model, toasts)` listens to `model.outcome` and to the model for new stale results/errors; `graphOutcomeEntry(...)` per the matrix; Undo/Redo wiring and the foreign-operation warn; `dispose`.
- `app/lib/src/features/projects/project_session.dart` -- `ProjectOpenReport(name, warnings)`; `openReport` `ValueListenable` set by `_switchTo` when warnings are not empty; `takeOpenReport()` clears it.
- `app/lib/src/features/home/home_page.dart` -- `toast:` slot from `vm.toasts` (null while `current` is null); a listener shows the session's report (at mount and on change) and takes it.
- `app/lib/src/features/window/app_window_coordinator.dart` + `projects_window.dart` docs -- Projects always closes after an open; drop the warnings branch and its timeout; update docs.
- `app/lib/l10n/app_en.arb` (+ generated) -- the copy (Abandoned, Reverted…undoes it, Squashed…into, Created…on, Deleted, Moved…to, Renamed…to, Undid, Redid, Undo, Redo, Retry, nothing undone, stale texts, update failed, Opened).
- `app/widgetbook/folders/graph.dart` -- a "Toast" use case with every tone and a live `ShellToastView` replay button.
- Tests: `app/test/features/shell/shell_toast_test.dart` (hold 6.5 s, hover pause, error stays, × hides, replacement, exit then pill returns in a `FloatingShell`, reduce motion = no offset, F6 reaches Undo and ×, glass under `ZsFade` not `Opacity`), `app/test/features/graph/graph_toasts_test.dart` (every matrix row with fake actions/source; Undo once → "Undid … · Redo", Redo once; button gone after a foreign op; prefix length from the layout), `home_page_test.dart` (report → toast), `app_window_coordinator_test.dart` (Projects closes with warnings), session test (report set/taken).

**Acceptance Criteria:**
- Given a toasting outcome, when it is published, then the shell's bottom slot shows its text with Undo while it is the model's `undoable`, and the @ pill is hidden until the toast's exit ends.
- Given a toast showing, when another outcome arrives, then the old one fades in place and the new one enters; when 6.5 s pass without hover, it hides; while hovered, it stays; an error toast stays until × or Retry.
- Given the toast's Undo, when pressed, then `undoLast()` is called exactly once, the toast hides, and the outcome toast "Undid `jj …`" with Redo follows; its Redo calls `redoLast()` once.
- Given reduce motion, when a toast enters and leaves, then it only fades (no translation).
- Given focus in the graph, when F6 is pressed with a toast showing, then focus lands on its first button and Tab reaches ×.
- Given a creation with warnings in Projects, when the project opens, then Projects closes and the project window's toast shows the warnings.

## Spec Change Log

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 40 findings — high 0, medium 9, low 21, false 10, maybe-false 0 (the intent-alignment divergences counted as findings)
- findings:
  - (verification-gap) `[medium]` `[patch]` the creation report already pending when the project window mounts (the main I2 path) is untested — added a home_page_test case with the report set before `pumpHome`; the at-mount show moved to a post-frame callback.
  - (verification-gap) `[low]` `[patch]` `GraphToasts` seeding from an existing stale result/error is untested — added a test building the binding on a model with a prior result.
  - (verification-gap, other) `[false]` `[reject]` the matrix's "Updated the working copy to …" differs from the code — the code uses jj's own sentence (`cli_util.rs:723` @ v0.46.0, "Updated working copy to fresh commit"), which the matrix row itself calls for ("jj's texts"); a spec-only edit.
  - (blind) `[low]` `[patch]` the stale-sentence comment cites `cli_util.rs:684`/`:1560` — corrected to `:678`/`:1557` @ v0.46.0 (the matrix-text part rejected as above).
  - (blind) `[medium]` `[patch]` duplicate of the at-mount gap — same fix.
  - (blind) `[low]` `[patch]` `toasts.show` from `initState` notifies during the parent's build — moved to a post-frame callback.
  - (blind) `[low]` `[reject]` `_OpenReportToast` lacks `didUpdateWidget` — `session` and `vm.toasts` are fixed for a HomePage's life (one view model per page); unlikely and the fix adds a branch.
  - (blind) `[low]` `[reject]` Projects still builds its warnings notice — it stays the surface when Projects does not close (the project window failed to open, the catch in `_afterOpenInProjects`); the window's content goes with the window, so it never reappears stale.
  - (blind) `[false]` `[reject]` squash ignores `into` — `_plan` sets the destination (and so `flash`) to `into` whenever it is given (`graph_view_model.dart:611`).
  - (blind) `[low]` `[patch]` Redo has no foreign-operation feedback — mirrored `_undo`: "Nothing redone — another operation came after it", with a test.
  - (blind) `[medium]` `[patch]` the hover pause sticks when a hovered toast is replaced (the keyed `MouseRegion` unmounts without `onExit`) — `_hovered` resets when a new entry shows, with a test.
  - (blind) `[medium]` `[patch]` focus is not handed back after F6 and a dismiss — `FloatingShell` remembers the node focused before F6 and restores it when the region loses focus to a scope, with a test.
  - (blind) `[low]` `[reject]` `withActionFocusSkip` hand-copies fields — a later field added to `ZsToast` would need adding there too; developer-only, the fix is a refactor (a scope widget) for no current harm.
  - (blind) `[false]` `[reject]` a stale result without a commit id renders an empty id — `StaleRecovery.commitId` is null only for `notStale` (`workspace.dart:219-221`), whose text has no id.
  - (blind) `[false]` `[reject]` the `l10n-ignore` comment sits on the wrong line — `app/test/l10n/hard_coded_strings_test.dart` passes on the tree.
  - (blind) `[low]` `[reject]` the catalogue samples hand-build ids without the weight variation and use a literal warning code — catalogue-only, cosmetic.
  - (blind) `[low]` `[patch]` badly reflowed doc comments (`floating_shell.dart` orphan line, `projects_window.dart:64` overlong) — rewrapped.
  - (blind) `[low]` `[reject]` HomePage rebuilds the whole shell on each toast change — a few rebuilds per operation; no measurable cost, the narrower builder adds code.
  - (edge) `[medium]` `[patch]` hover stuck after replacement — same as above.
  - (edge) `[medium]` `[patch]` focus not restored — same as above.
  - (edge) `[low]` `[reject]` an Undo that meets busy/stale/nothing-to-undo shows nothing — the button shows only while the outcome is `undoable` and an action is not running; pressing it exactly while another starts is rare and a per-reason text adds branches.
  - (edge) `[low]` `[patch]` Redo foreign op — same as above.
  - (edge) `[low]` `[patch]` a toasting verb that wrote no operation still claims it acted — it now reads jj's own "Nothing changed." (as the CLI prints for a no-op), warn clauses kept, with a test.
  - (edge) `[low]` `[reject]` a squash whose destination the layout could not name says "into @" — only when the parent is not in the shown layout and no `--into` was given; rare, and naming it needs a new read.
  - (edge) `[false]` `[reject]` empty id for a null commit id — as above.
  - (edge) `[low]` `[reject]` a refusal with an empty-string context shows an empty pill — the wire gives a null context, never an empty one, for jj's errors; unlikely.
  - (edge) `[low]` `[patch]` a new toast during the exit snaps the half-faded old one back to full opacity — a closing toast is dropped instead of kept as the replaced layer.
  - (edge) `[low]` `[reject]` `_OpenReportToast` didUpdateWidget — as above.
  - (edge) `[low]` `[patch]` a pending report survives a later open without warnings — `_switchTo` clears it then, with a test.
  - (intent) `[medium]` `[defer]` graph outcome toasts and I3's stale toasts reach no production surface until 10.12 mounts the graph in the project window — recorded in `deferred`.
  - (intent) `[medium]` `[defer]` (grouped with the above) I3's result and failure toasts exist only in the binding and the catalogue.
  - (intent) `[medium]` `[defer]` I1 is witnessed at the widget tree (`ZsFade`, no `Opacity` ancestor), not in a render — the Marionette check is not possible unattended; recorded in `deferred` (unverified).
  - (intent) `[false]` `[reject]` ⌘Z/⇧⌘Z not bound — the story's 2026-10-16 note gives the keys to 11.13 ("11.13 … binds ⌘Z and ⇧⌘Z to this story's undo and redo"); `undoLast`/`redoLast` are the entry points.
  - (intent) `[false]` `[reject]` no texts or witnesses for drops, split, commit, duplicate, push and `op abandon` — those verbs have no `GraphAction` yet; the story says their outcomes come from 10.10, 10.15, 10.25, 10.27 (and 11.8).
  - (intent) `[low]` `[reject]` every graph error takes the warn tone, none the error tone with Retry — the graph's local verbs end in jj's refusals; an operation that genuinely fails (I/O, unreachable remote) first comes with 11.8's fetch, which adds the error-tone case; classifying codes now adds policy for a case users rarely meet.
  - (intent) `[false]` `[reject]` the position witness is not in the new tests — 11.3's `floating_shell_test.dart:548` already checks the bottom slot between the insets, and `shell_toast_test.dart` checks the pill yielding.
  - (intent) `[false]` `[reject]` "Undid ‹action›" filled with the command — the DS kit does the same (`design_system/ui_kits/desktop/app.jsx:331`, "Undid " + the command in mono).
  - (intent) `[low]` `[reject]` I2 diverges nowhere — informational (the production flow is wired and tested).
  - (intent) `[false]` `[reject]` the matrix's stale text vs the code — as the first false row.
  - (intent) `[low]` `[reject]` the readings of item 6 / "Undid" are informational — settled by the rows above.

## Design Notes

- Why a host in the shell, not in the graph: the project window's slot takes toasts from several sources (graph outcomes, stale recovery, a creation's report, later 11.8's fetch/push and 11.9's timeline); `ShellToasts` is the one queue, sources only `show`. 10.12 wires `GraphToasts(model, vm.toasts)` when it mounts the graph; until then the catalogue mounts it.
- Entries build their `ZsToast` at each build (`build(context, dismiss)`, rebuilt when `listenable` notifies), so prefix lengths and Undo visibility follow the model without re-showing.
- Claude's proposals (no design): the warn text for a silent verb's warnings; the foreign-operation warn; the stale result and failure copy (jj's own sentences where it prints one); "Opened ‹name›" for the creation report; the hold also pauses while focus is inside the toast; no toast for a stale refusal.

## Verification

**Commands:**
- `flutter test` in `packages/zanshin_ui` and in `app` -- expected: all green.
- `dart analyze --fatal-infos` in `packages/zanshin_ui` and `app` -- expected: no issues.
- `dart format --set-exit-if-changed .` in both -- expected: exit 0.

**Manual checks (if no CLI):**
- Marionette visual check of the catalogue's Toast use case against the DS Toast card (not possible unattended; recorded as deferred if skipped).

**Verification notes (2026-11-01, gate rule of the story loop: no `cargo make test`/`test-full`/`coverage`):**
- `flutter test` in `packages/zanshin_ui` -- 435 passed.
- `flutter test` in `app` -- all passed except the 5 real-worker tests in `worker_project_repos_test.dart`, which refuse to run without `cargo make`'s pinned `XDG_CONFIG_HOME`; rerun with the Makefile.toml test env (`JJ_CONFIG`, `GIT_CONFIG_GLOBAL`, `JJ_USER`, `JJ_EMAIL`, `JJ_OP_*`, `ZANSHIN_LOG_DIR`, `XDG_CONFIG_HOME=target/test-xdg-config`) -- 33 passed. Includes `test/l10n/hard_coded_strings_test.dart` and `test/widgetbook/catalogue_smoke_test.dart`.
- `dart analyze --fatal-infos` in both packages -- no issues. `dart format --set-exit-if-changed .` in both -- 0 changed.
- Not run: cargo checks (no Rust changed), `cargo make codegen` (no FFI/schema change), the parity oracle (no jj verb changed), the full gate and coverage (the loop runs them), the Marionette visual check (deferred).

## Auto Run Result

Status: done. Commits: `e2da414d42f5d8c56d0c26e1e8cc1a0b2575a517` (code), plus the spec/ledger commit that carries this section.

**Summary.** The operation toast per epics.md Story 10.23 (design updates 2026-10-16, 2026-10-26; DS synced through #13): `ZsToast` in `zanshin_ui` (success / warn / error, Undo/Redo/Retry pills with the jj command as tooltip, × "Dismiss", live region or alert role); `ShellToasts` + `ShellToastView` in the shell (one at a time, 6.5 s hold paused on hover and focus, 10 px rise in, 8 px drop out, in-place fade on replacement, glass faded only through `ZsFade`, F6 into the toast and focus handed back after it), owned by `FloatingShellViewModel`; `GraphToasts` mapping `GraphViewModel` outcomes (abandon, revert, squash, bookmark create/delete/move/rename, "Undid/Redid jj …" with Redo/Undo while current, warn clauses, refusals verbatim in the warn tone, jj's "Nothing changed." for a verb that wrote nothing, "Nothing undone/redone" after a foreign operation) and the stale recovery (jj's sentences, never Undo; the failure in the error tone with Retry); the creation report as the project window's toast with Projects always closing after an open.

**Files changed.**
- `packages/zanshin_ui/lib/src/controls/zs_toast.dart` (+ export, `toastDismiss` ARB) -- the DS Toast look.
- `app/lib/src/features/shell/shell_toast.dart` -- the queue, the host, the span helpers.
- `app/lib/src/features/shell/floating_shell.dart`, `floating_shell_view_model.dart` -- F6 + focus return; the view model owns the toasts.
- `app/lib/src/features/graph/graph_toasts.dart` -- outcome and stale toasts.
- `app/lib/src/features/projects/project_session.dart` -- `ProjectOpenReport` / `openReport` / `takeOpenReport`.
- `app/lib/src/features/home/home_page.dart` -- the toast slot and the report.
- `app/lib/src/features/window/app_window_coordinator.dart`, `projects_window.dart` -- Projects always closes; docs.
- `app/lib/l10n/app_en.arb` (+ generated) -- the copy.
- `app/widgetbook/folders/graph.dart` -- Graph › Toast › Tones; the floating-shell demo mounts `GraphToasts`.
- Tests: `zs_toast_test.dart`, `shell_toast_test.dart`, `graph_toasts_test.dart`, `home_page_test.dart`, `project_session_test.dart`, `app_window_coordinator_test.dart`.

**Review.** 40 findings: 13 rows patched (10 distinct fixes: report at mount + post-frame show, binding seed test, comment line numbers, Redo foreign-op warn, "Nothing changed.", hover reset on replacement, no replaced layer for a closing toast, focus return after F6, doc rewraps, stale report cleared), 3 rows deferred (2 entries: production wiring until 10.12, catalogue visual check), the rest rejected with reasons in the triage log. Patched by verdict: medium 4 entries (report at mount, hover, focus; plus their duplicates), low 6.

**Follow-up review recommendation:** true — two or more medium entries were patched; the specific unverified risk is the focus return after F6 (it restores only when focus fell back to a scope node, checked by one widget test) and the hover reset, neither seen in a running window.

**Deferred-work items handed to this story:**
- **I1** -- fixed (`e2da414d`): the toast fades its glass through `ZsFade` only (`ShellToastView`; test "the glass fades through ZsFade, never an Opacity above it"); the rendered blur mid-fade is unchecked in a running window (deferred: catalogue visual check).
- **I2** -- fixed (`e2da414d`): `ProjectSession.openReport` carries a creation's warnings, the project window shows "Opened ‹name›" with warn clauses (at mount or on arrival, once), and the coordinator always closes Projects (the keep-and-bring-forward branch and its 2 s timeout are gone).
- **I3** -- partly done (`e2da414d`): the result toast (jj's three sentences, no Undo) and the failure's error toast with Retry (`jj workspace update-stale`) are built and tested in `GraphToasts`; left: they reach the running app only when 10.12 mounts the graph and creates `GraphToasts` in the project window (deferred, Surfaced in Story 10.23).

**Residual risks.** No production caller of `GraphToasts` until 10.12; ⌘Z/⇧⌘Z are 11.13's; texts for drops, split, commit, duplicate, push ("Undoing a push…") and `op abandon` come with those verbs' stories; every graph error is a warn-tone refusal (the error tone first appears with 11.8's fetch).
