---
title: 'Story 11.19 — Edit the config file: the GUI split of `jj config edit`, and a resizable Settings window'
type: 'feature'
created: '2026-11-06'
status: 'done'
baseline_revision: '3fd9234e2d68e5fda528fcea8785730058b43a07'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The Config file page and the resizable Settings window were not checked in the running app (Marionette vs the DS card, a real resize/zoom).
    evidence: |-
      The window binding in settings_window.dart (_bindWindow/_windowChanged, minimum after the first frame, following, fill after a user resize, setConstraints without a maximum) and the runner's userSized handling in WindowFrameStore.swift have no automated test; the unattended run could not hold a flutter run. Only SettingsHeightFollower and NaturalHeight are unit-tested.
    location: >-
      app/lib/src/features/settings/settings_window.dart, app/macos/Runner/WindowFrameStore.swift
    severity: medium
---

<intent-contract>

## Intent

**Problem:** 9.28's `configFileRead` / `configFileWrite` (the GUI's `jj config edit`) have no consumer (deferred-work I1 "Raw config editing has no surface"), and the Settings window cannot be resized, so a long config file or long line has no room.

**Approach:** Build the DS `ConfigFilePage` (sync #20) as a page in each Settings tab, opened from "Edit…" in the scope line (General → `--user`, Project → `--repo`): the file's exact text in a monospaced, line-numbered, non-wrapping editor; Save ⌘S / Revert; jj's parse error marked from its span; a Discard-edits sheet when leaving with edits; a changed-on-disk notice with Reload. Make the Settings window resizable (minimum 620 × 420, zoom), its height following the tab until the user resizes it.

## Boundaries & Constraints

**Always:**
- Build to the DS: `design_system/components/settings/ConfigFilePage.{jsx,prompt.md}`, `settings.css:92-120` (`.zs-cfg-*`), card `remotes-config.card.html` (column 3), `components/window/Window.prompt.md` (Settings window paragraph). DS wins over `design/config-file.jsx`. Tokens / Zs controls from `zanshin_ui`; the editor is an undecorated `TextField` (as `ZsTextField` builds one).
- Reads/writes through 9.28 only: read = `configFileRead(ConfigScopeTarget(scope), workspaceRoot:)` (the scope's first file, created when absent — the CLI's), write = `configFileWrite(path, text, workspaceRoot:)` with the path the read returned. jj validates before writing; a refusal writes nothing.
- `jj.config_parse_error`'s `context` is `"<start>..<end>\n<message>"` (UTF-8 byte span) or just the message: the span maps to the draft's character range (byte → UTF-16 offset), line/column count from it (column = characters before it on its line + 1); the message shows verbatim in mono (`// l10n-ignore: jj's text`). Without a span: "Not saved" + message, nothing marked. Any other write failure: "Not saved" + `settingsErrorText(error)`.
- Save and Revert are off while draft == saved text. A landed save: "✓ Saved" for 1.6 s, error cleared, `ProjectsEnvironment.configWrites` fires (other windows re-read), Settings re-reads both tabs' rows (incl. the Project tab's remotes, trunk, Immutable page) and `graph.value?.model.configChanged()`.
- Leaving the page with edits — Back / ⌘[, the other tab, an entry point that switches the tab, closing the window, closing the project / quitting (an `AppWindows` close guard) — asks with a destructive `ZsConfirmDialog` sheet on the Settings window: "Discard your edits to <file name>?" · "The file stays as you last saved it." · "Discard edits"; Cancel stays. Leaving without edits just leaves; a left config page closes (coming back shows the tab).
- Changed on disk (a watch on the file's folder, filtered to the file): re-read; differing text with edits → `--warn-bg` notice "The file changed on disk while you edited it." + Reload (replaces the draft); differing text without edits → the page shows the new text. Save still writes the draft.
- Settings window: `resizable: true`, minimum 620 × 420 (set once its content-sized first frame is up — a content-sized window takes no minimum at creation), no maximum after that; until the user resizes or zooms it, its content height follows the shown tab (capped at 740; the config page takes 740); once the user resized it, it keeps its size, the body fills it (footer at the bottom) and scrolls. The runner stops re-anchoring the top edge for a window the user resized (live resize or zoom).
- All new strings in `app/lib/l10n/app_en.arb` + `flutter gen-l10n`. Semantics: the editor labelled "Contents of <path>" (identifier `settings-config-editor`), the error a live region (`settings-config-error`), the notice a status (`settings-config-stale`); identifiers `settings-config-edit` (scope link), `settings-config-save`, `settings-config-revert`, `settings-config-reload`, `settings-config-show`, `settings-config-discard`.

**Never:**
- No Rust, FFI, schema or `zanshin_core` change (verbs and exports exist). No syntax highlighting, no key catalogue, no tab characters typed (Tab moves focus). No density/zoom work (Story 11.20). No remembered Settings size across launches (position-only frame stays).
- Never parse jj's message text; never write without jj's validation.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Open | General › Edit… | page "Config file", path + exact text of `configFileRead(user)`; window title "Config file"; scope line without Edit… | read fails → `settingsErrorText` in the page, no editor |
| Save | draft edited, ⌘S | `configFileWrite(path, draft)`; "Saved"; rows re-read; `configWrites` fired | — |
| Parse error | `pager = less` (span 8..12) | nothing written; gutter line + span marked; "Not saved: line N, column 9", message, help, Show | stays until next Save/Revert |
| Non-ASCII before span | `name = "Rälph"\nx = y` | span offsets mapped from bytes to characters | — |
| Revert | edited | draft = saved text, error cleared | — |
| Leave dirty | Back / other tab / close | Discard sheet; Discard → leaves; Cancel → stays with edits | — |
| Disk change, dirty | file changes | notice + Reload | — |
| Disk change, clean | file changes | editor shows new text | — |
| Saved alias | save `[revset-aliases]\n"immutable_heads()" = "…"` in Project | Immutable page reads the new alias | — |
| Window | tab switch, not resized | height = tab's content (≥ 420, ≤ 740) | — |
| Window | user resized | size kept; body fills; tab switch keeps size | — |

</intent-contract>

## Code Map

- `app/lib/src/features/settings/settings_window.dart` -- content: `_ScopeLine:238` (add " · Edit…" `ZsLink` after the path, hidden on the config page), body `Column:179` (`Flexible` scroll; page `KeyedSubtree:195`), Remove sheet pattern `:206, :216-235` (`ZsConfirmDialog` in `Positioned.fill`, `closing`/`onClosed`), `close():117`, title `:133-137`.
- `app/lib/src/features/settings/settings_window_state.dart` -- tab + `_page` (Project only today); `show/selectTab/openPage/closePage/windowClosed`.
- `app/lib/src/features/window/app_window_coordinator.dart:142-160` -- `openSettings` title switch on `(tab, page)`.
- `app/lib/src/features/settings/settings_view_model.dart:458-531` -- `_load`, `_readGeneral`, `_readProject` (re-read targets after a save), `root`, `userPath`/`repoPath`, `settingsErrorText`.
- `app/lib/src/features/settings/settings_widgets.dart:363-474` -- `SettingsPage` (back button, ⌘[ via `CallbackShortcuts`, title, intro).
- `app/lib/src/features/projects/projects_environment.dart:17-170` -- `ProjectsEnvironment` port (+ `ConfigWrites`), `DesktopProjectsEnvironment` over the worker (`configFileRead/Write` exist on `ZanshinWorker`, `packages/zanshin_core/lib/src/worker/isolate.dart:3599-3635`; `ConfigFileText{path,text,warnings}`, `ConfigScopeTarget` exported).
- `app/lib/src/features/window/app_windows.dart:97-104` -- `settingsWindowSpec` (content-sized, `resizable: false`, max 620 × 740, frame `position`); `controllerOf(key)`, `addCloseGuard`.
- Flutter engine (read-only): a resizable dialog without a size is sized to its content on the FIRST frame only, then its sizing delegate is dropped (`FlutterWindowController.mm:200-214`); `setConstraints` on a non-content-sized window sets the NSWindow content min/max (`:52-62, :256-262`); `windowDidResize` → controller `notifyListeners` (`:117-119`); `DialogWindowController.setSize/setConstraints/contentSize` (`_window.dart:693-705`).
- `app/macos/Runner/WindowFrameStore.swift:211-220` -- `didResize` re-anchors a position-only window's top edge (fights a user's top-edge drag / zoom).
- `packages/zanshin_ui/lib/src/controls/zs_text_field.dart:35-80, 473-510` -- controller `buildTextSpan` error-range pattern and the undecorated `TextField` setup to mirror. `ZsLink`, `ZsButton` (primary = gold), `ZsConfirmDialog`, `ZsScrollArea`, `ZanshinIcon(ZI.check|ZI.conflict)`, `ZsType` (mono family, `fsMd` 12), `ZsColors` (`codeBg`, `rem`, `remBg`, `warn`, `warnBg`, `accentRing`, `gold`, `textFaint`, `flBorder`).
- Tests: `app/test/helpers/settings_rig.dart` (`SettingsRig`), `fake_projects_environment.dart`, `app/test/features/settings/settings_window_test.dart`, `app/test/features/projects/projects_environment_test.dart` (`_ConfigWorker`), `app/test/features/window/app_windows_test.dart` (spec pins). Widgetbook: `app/widgetbook/demo_projects_fakes.dart:167` (`DemoProjectsEnvironment`).

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/projects/projects_environment.dart` -- port: `configFileRead(ConfigScope, {workspaceRoot})` → `ConfigFileText`; `configFileWrite(String path, String text, {workspaceRoot})` (fires `configWrites` on success); `Stream<void> fileChanges(String path)` (Desktop: the parent folder's `watch()` filtered to the file name, incl. a move's destination). Update the test fake (scripted text per scope, a write log, scripted failure, an `onWrite` hook, a `StreamController` per path) and the widgetbook demo (in-memory text per scope; a value without quotes refused with a span, as the DS card does).
- `app/lib/src/features/settings/config_file_page.dart` (new) -- `ConfigParseFailure.of(ZanshinFfiException, String draft)` (span bytes → characters, line/column) ; `SettingsConfigFilePage` (StatefulWidget over vm, scope, onBack, `onEditing(bool)`): loads the file, the well (bar: path + Edited/✓ Saved; notice; gutter 44 px + editor, mono 12/19.5, no wrap, horizontal + vertical scroll, error span wavy-underlined over `--rem-bg`, gutter line in `--rem`, border `--rem`/focus `--accent-ring`), the error block (line/column, message, help, Show), the footer (⌘S saves · Revert · Save), ⌘S shortcut, file watch, then `vm.configFileSaved()`.
- `app/lib/src/features/settings/settings_window_state.dart` -- `SettingsPage.configFile` on both tabs (a page per tab), `editing` flag, `confirmDiscard` hook, `mayLeave()`; every change that leaves a config page with edits asks first; a left config page closes.
- `app/lib/src/features/settings/settings_window.dart` -- Edit… in the scope line; the config page (title "Config file", no scroll, page fills); the Discard sheet; `close()` asks; an `AppWindows` close guard; the height follower + the filling body.
- `app/lib/src/features/settings/settings_window_sizer.dart` (new) -- `SettingsHeightFollower` (pure: content height in, `setSize`/`setConstraints` out, user resize detected from a window size it did not ask for) and `NaturalHeight` (a render box that measures its child's natural height under its width and max 740, reports it, then lays it out to the incoming constraints).
- `app/lib/src/features/settings/settings_view_model.dart` -- `configFileSaved()`: re-read both tabs (same generation) + `configChanged()`.
- `app/lib/src/features/window/app_windows.dart` -- `settingsWindowSpec` `resizable: true`; `settingsWindowMinimum` 620 × 420.
- `app/lib/src/features/window/app_window_coordinator.dart` -- title for `SettingsPage.configFile`.
- `app/macos/Runner/WindowFrameStore.swift` -- a position-only window the user resized (`willStartLiveResize`, or zoomed) is no longer re-anchored.
- `app/lib/l10n/app_en.arb` -- strings; `flutter gen-l10n`.
- Tests: `app/test/features/settings/config_file_page_test.dart` (new: open per scope, save, parse error incl. non-ASCII span and no-span, Revert, Show, ⌘S, discard on back/tab/close + cancel, disk change dirty/clean, saved alias on the Immutable page, configChanged), `settings_window_sizer_test.dart` (new: follower + NaturalHeight), `settings_window_state` cases, `projects_environment_test.dart` (read/write pass-through, `configWrites` once on success), `app_windows_test.dart` (spec).

**Acceptance Criteria:**
- Given Settings › General, when Edit… is pressed, then the Config file page shows the user file's exact text with line numbers and no wrapping, Save/Revert off.
- Given an edited draft jj refuses, when saved, then the file is unchanged and jj's message, line and column show with the span marked; given a valid draft, then it is written and the rows and the Immutable page show the new values.
- Given edits, when the user goes back, switches tab or closes the window, then the Discard-edits sheet asks first.
- Given the Settings window not yet resized, when the tab changes, then its height follows the tab; given it was resized, then it keeps its size; it never gets smaller than 620 × 420.

## Spec Change Log

## Review Triage Log

### 2026-11-06 — Review pass
- verdicts: 37 findings — high 0, medium 9, low 23, false 5, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) a watch event for a removed file re-reads through `configFileRead`, which recreates it — `fileChanges` now fires only while the file exists.
  - `[medium]` `[patch]` (blind) a page disposed with edits (project switch) never resets `state.editing` → needless Discard questions — `dispose` reports `onEditing(false)`; test added.
  - `[low]` `[reject]` (blind) the close guard also asks on a project close for General's draft — the guard cannot tell a project close from a quit; asking is the safe side, a fix needs a reason parameter on `mayClose`.
  - `[low]` `[patch]` (blind) the error mark / red gutter line / Show drift while typing — shown only while the text equals the refused draft; message stays until Save/Revert (DS); test added.
  - `[false]` `[reject]` (blind) `setConstraints` drops the 620 width cap — the DS card wants a wider window for long lines ("a wider one the long lines and URLs"); only the minimum is specified.
  - `[low]` `[reject]` (blind) a screen clamp reads as a user resize — needs a screen shorter than the 740 cap plus chrome; fix adds screen geometry to the follower.
  - `[low]` `[reject]` (blind) the user's size is lost on close — the spec keeps the position-only frame; fix is a spec edit.
  - `[medium]` `[patch]` (blind) the longest-line `TextPainter` ignores the text scale (density scales text) → long lines cut — the painter takes `MediaQuery.textScalerOf`.
  - `[low]` `[reject]` (blind) no context menu in the editor — ⌘C/⌘V/⌘X work; the Zs text menu is private to `zanshin_ui` (new public surface).
  - `[false]` `[reject]` (blind) a parse error without context shows the code — the bridge always sends a context for `jj.config_parse_error` (docs/rust-error-codes.md:63).
  - `[low]` `[reject]` (blind) watch errors swallowed — a failed watch only loses the notice; the next Save still writes; logging/retry adds branches.
  - `[low]` `[reject]` (blind) untested paths (4-byte runes, guard, mark rendering, equal-text branch, project switch) — guard and project switch now tested; the rest are the same code paths as tested ones.
  - `[low]` `[reject]` (blind) every keystroke re-measures the file — config files are small; caching adds state.
  - `[medium]` `[patch]` (edge) a non-FFI write failure leaves `_saving` true (Save dead) — reset in `finally`.
  - `[low]` `[reject]` (edge) a non-FFI read failure leaves the page loading — only on worker death, where every surface is dead; catch-all adds a branch.
  - `[low]` `[reject]` (edge) `configFileSaved` throwing escapes — its reads catch `ZanshinFfiException`, the only error they raise.
  - `[low]` `[patch]` (edge) removal recreates the file — same fix as the blind finding.
  - `[low]` `[reject]` (edge) overlapping disk reads resolve out of order — the next event corrects it; a sequence guard for a rare race.
  - `[low]` `[patch]` (edge) Zanshin's own save's watch event raises a spurious notice while the user typed on — `_diskChanged` ignores events while saving.
  - `[low]` `[patch]` (edge) the mark points at the wrong spot after typing during a refused save — same fix as the blind drift finding.
  - `[low]` `[reject]` (edge) ⌘W twice while the sheet shows runs close twice — both join one answer; the second close finds no controller; harmless.
  - `[low]` `[reject]` (edge) project close asks for General's draft — same as the blind guard finding.
  - `[low]` `[reject]` (edge) a stale `_go` after the project closes during a pending ask — the project close itself asks through the same sheet first.
  - `[medium]` `[patch]` (edge) project switch keeps `editing` true — same fix as the blind dispose finding.
  - `[false]` `[reject]` (edge) `openPage(configFile)` on a dirty config page resets `editing` — Edit… is hidden on the config page, nothing else opens it there.
  - `[false]` `[reject]` (edge) `controllerOf` null at the first post-frame callback — `AppWindows` records the controller before it registers the window, so the content builds after it exists.
  - `[low]` `[reject]` (edge) AppKit clamp misread as a resize — same as the blind screen-clamp finding.
  - `[low]` `[reject]` (edge) `isZoomed` after a programmatic resize stops anchoring — needs the content height to equal the screen's standard frame; rare.
  - `[low]` `[reject]` (edge) empty path → "Discard your edits to ?" — `jj config path` never answers an empty path.
  - `[low]` `[reject]` (edge) no minimum before activation — Settings opens key; the minimum lands on its first activation.
  - `[medium]` `[patch]` (edge) non-FFI write failure claim vs spec — same `finally` fix.
  - `[medium]` `[patch]` (verification-gap) the Settings close guard (project close / quit) untested — rig exposes `windows`; test: no edits → true, no sheet; edits → sheet, Cancel false, Discard true.
  - `[medium]` `[defer]` (verification-gap) the height follower is never wired to a window in a test — needs the running app (deferred item).
  - `[medium]` `[defer]` (verification-gap) the runner's `userSized` handling has no check — no Swift harness; app-level check (deferred item).
  - `[false]` `[reject]` (intent) witnesses run on a fake, not jj — app tests never call a jj config verb for real (project rule); 9.28's Rust tests cover validation and the untouched file.
  - `[low]` `[reject]` (intent) no workspace scope — the DS defines the page for General (user) and Project (repo) only.
  - `[medium]` `[defer]` (intent) no native/visual verification of the window and page — merged into the deferred item.

## Design Notes

Height follower: the engine sizes a resizable content-sized window only on its first frame. Afterwards the Settings content measures its natural height (a second layout pass under its width and max 740) and asks the controller for that content size; a resize notification whose size differs from the last size it asked for (or the first-frame content size) is the user → stop following, fill. The minimum is applied after the first frame (content-sized creation refuses one) and every requested size is clamped to it, so the clamp never reads as a user resize.

Pages per tab: the config page exists in both tabs, so the state keeps one page per tab; a config page closes when left (its draft lives in the page).

## Verification

**Commands:**
- `flutter gen-l10n` (in `app/`) -- regenerated, committed.
- `cargo make test-app test/features/settings test/features/window test/features/projects test/l10n` -- all pass.
- `dart analyze .` (in `app/`) -- no issues. `dart format --set-exit-if-changed lib test widgetbook` -- exit 0.
- `xcrun swiftc -parse app/macos/Runner/WindowFrameStore.swift` -- parses.

**Manual checks:**
- Marionette over the running Settings window / widgetbook vs DS card `remotes-config.card.html` column 3, and a real resize/zoom of the Settings window.

## Auto Run Result

Status: done

**Summary.** Each Settings tab's scope line ends in " · Edit…", which opens the Config file page (DS `ConfigFilePage`, sync #20): General edits the user file, Project the repo file, both via 9.28's `configFileRead` / `configFileWrite`. The page shows the file's exact text, mono 12/19.5, 44 px line-number gutter, no wrapping (both-way scroll), Edited / ✓ Saved in the bar, Save (gold, ⌘S) and Revert off while nothing changed. jj's `jj.config_parse_error` span (UTF-8 bytes → characters) is wavy-underlined, its gutter line red, "Not saved: line N, column M", jj's message verbatim, help sentence and Show; a landed save fires `configWrites` and re-reads both tabs (Immutable page included) and the graph config. Leaving with edits (Back/⌘[, other tab, a switching entry point, closing the window, closing the project / quitting via an `AppWindows` close guard) asks with a destructive Discard sheet. A watch on the file's folder re-reads changes: clean draft follows, dirty draft gets the notice with Reload. The Settings window is resizable (zoom), minimum 620 × 420 after its first frame; its height follows the tab until the user resizes or zooms it, then the body fills it; the runner stops re-anchoring the top edge of a user-resized window. No Rust/FFI/zanshin_core change.

**Files changed** (under `app/`):
- `lib/src/features/settings/config_file_page.dart` (new) — `ConfigParseFailure`, `SettingsConfigFilePage`.
- `lib/src/features/settings/settings_window_sizer.dart` (new) — `SettingsHeightFollower`, `NaturalHeight`.
- `lib/src/features/settings/settings_window.dart` — Edit… link, config page, Discard sheet, close guard, window binding + filling body.
- `lib/src/features/settings/settings_window_state.dart` — a page per tab, `SettingsPage.configFile`, `editing` / `confirmDiscard` / `mayLeave`.
- `lib/src/features/settings/settings_view_model.dart` — `configFileSaved()`.
- `lib/src/features/settings/settings_widgets.dart` — `SettingsPage.spacing`.
- `lib/src/features/projects/projects_environment.dart` — `configFileRead`, `configFileWrite`, `fileChanges`.
- `lib/src/features/window/app_windows.dart`, `app_window_coordinator.dart` — resizable spec, `settingsWindowMinimum`, "Config file" title.
- `macos/Runner/WindowFrameStore.swift` — `userSized`.
- `lib/l10n/app_en.arb` + regenerated `app_localizations*.dart`.
- `widgetbook/demo_projects_fakes.dart` — demo env file read/write (refuses an unquoted value with a span).
- Tests: `test/features/settings/config_file_page_test.dart` (new), `settings_window_sizer_test.dart` (new), `test/features/projects/projects_environment_test.dart`, `test/features/window/app_windows_test.dart`, `app_window_coordinator_test.dart`, `test/helpers/fake_projects_environment.dart`, `settings_rig.dart`.
- Also: `sprint-status.yaml` 11-19 → done; `deferred-work.md` one Medium item.

**Review findings.** 37 findings — 13 patched rows (5 medium, 8 low; grouped: page dispose resets `editing`, text-scaled line measure, `_saving` in `finally`, close-guard test as the medium entries; removal not recreating the file, stale error mark, own-save watch event as the low ones), 3 deferred rows merged into one Medium item (running-app check of the window binding, the runner's `userSized`, DS visual), 16 rejected low and 5 false with reasons in the Review Triage Log. Deviations kept: `NaturalHeight` lays the child out once at its natural height while measuring (a second tight layout made it a relayout boundary); the deleted-file check sits in `fileChanges` (environment), not in the page; a non-parse write failure shows no help sentence and no Show.

**Follow-up review recommendation:** false — patched: high 0, medium 4 entries, low 3 entries; every patched entry carries a test or is a one-line correction verified by the targeted run; no named unverified risk in the patched code (the unverified native window behaviour is the deferred item, not a patch).

**Deferred-work item I1** ("Raw config editing has no surface"): fixed — Edit… in each Settings tab opens the Config file page over `configFileRead` / `configFileWrite` (commit 14fade2c83fc60052cd484e9e8698cafc21045bd).

**Commits:** 14fade2c83fc60052cd484e9e8698cafc21045bd (the story), plus this record's docs commit.

**Verification** (gate rule of this run: no full gate):
- `flutter gen-l10n` (app/) — ran, output committed.
- `cargo make test-app test/features/settings test/features/window test/features/projects test/l10n` — 387 passed (after the review patches).
- `dart analyze .` (app/, widgetbook included) — No issues found.
- `dart format --set-exit-if-changed lib test widgetbook` (app/) — 0 changed.
- `xcrun swiftc -parse app/macos/Runner/WindowFrameStore.swift` — parses (no type check, no app build).
- Not run: Marionette vs the DS card and a real resize/zoom (deferred), the full gate (the loop runs it), no Rust touched.

**Residual risks.** The native side is unproven: when the follower binds (first activation), `setConstraints` with an infinite maximum, `setSize` vs the user-resize detection, the Swift `userSized`/zoom handling; a tab shorter than 420 leaves an unpainted strip under the footer while following; the editor has no right-click menu (keyboard copy/paste works); the file-watch test relies on real FSEvents timing.
