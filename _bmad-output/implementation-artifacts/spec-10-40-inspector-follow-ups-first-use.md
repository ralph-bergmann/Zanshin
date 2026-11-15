---
title: "Story 10.40 — Inspector follow-ups from Ralph's first use of 10.33–10.39"
type: 'bugfix'
created: '2026-11-15'
status: 'done'
baseline_revision: '26878f824b7e5ccb6aecfa89ffa63558a4f63932'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/.claude/skills/design-artifacts/SKILL.md'
warnings: ['oversized', 'multiple-goals']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Ralph's first use of the rebuilt inspector (10.33–10.39) found seven faults: see-through pinned line numbers, context menus that do not close on a click beside them, a crash on a right-click without a line menu, an editable Split composer that cannot run, Open in Editor at a line the file on disk lacks, a context-lines menu that ignores the repo config, and a DS `MenuButton` that never opens above.

**Approach:** Fix each in place (epics.md Story 10.40, items 1–7; Ralph accepted every proposal). No new look: each item restores the mock-up `design/Inspector Study.html`, the DS, or settles behaviour. DS synced through #26.

## Boundaries & Constraints

**Always:**
1. **Opaque pinned backings** (unified only): every pinned backing — line numbers and part gutter (`row()` in `_unified`), the fold row's pin, the no-newline row's pin and the pinned hunk header — paints `Color.alphaBlend(<its colour>, Color.alphaBlend(colors.codeBg, colors.flBgSolid))`, so its alpha is 1 in both themes. Side by side does not pin and stays as is.
2. **Menus close on any click outside the panel:** in `ZsMenuAnchor`, a pointer-down anywhere outside the menu panel (and its submenus) closes the menu and is consumed (`consumeOutsideTaps`), including a click inside the area the anchor's builder draws (the whole file list, the whole diff). A `ZsMenuButton` click on its own button while its menu is open closes it (toggle). Submenu clicks stay inside.
3. **No crash on an unhandled right-click:** the line-menu branch's `SelectionArea` gets `contextMenuBuilder: (_, _) => const SizedBox.shrink()` (never `null`); a right-click on a hunk header, a gap, a fold row, a no-newline row or a conflict header throws nothing and opens nothing.
4. **Split with every change picked** (`splitsEverything`): the composer shows only the hint `inspectorSplitAllHint` and Cancel — no Summary/Details fields, no Rest/Selected preview, no command line, no Split button. The draft (controllers and `composerFields`) is kept and shows again, as typed, when a pick is removed. `inspectorSplitAllReason` goes from the ARB if nothing uses it any more.
5. **Open at a line the file on disk lacks:** `ProjectFiles.lineCount(path)` counts the file's lines on disk (`\n` count, plus 1 when the non-empty file does not end in `\n`; null when it is not a readable file). In `inspectorPathMenu` with a `line` and `onDisk`, when `line > lineCount`, the Open row reads "Open in <editor>" (no line), its hint is `editorHint(editor)` without a line, it runs `openInEditor(path)` without a line (a custom `{line}` becomes 1, as `editorCommand` already does), and a `ZsMenuNote` right below it says "Line N is not in the file on disk — opens at its start". A missing file stays disabled with its reason. Without an editor ("Choose editor…") nothing changes.
6. **Effective context lines:** the inspector and the operation view read `diff.color-words.context` from the workspace's stack (`configList(name:, workspaceRoot: root)` → `effectiveConfigEntry`), as `jj diff` uses it; the read also says whether the effective entry's source is `ConfigValueSource.repo` or `.workspace`. The menu checks that value; when the repo or workspace sets it, a `ZsMenuNote` under the Context lines rows says "Set in this repository's config, which wins". A pick still writes `--user` (`writeDiffContext`). Settings › General › Diffs keeps its user-level `readDiffContext`.
7. **DS `MenuButton`** (skill `design-artifacts` § E): `components/actions/MenuButton.jsx` and its block in `_ds_bundle.js` (by hand, keep `sourceHashes` consistent the way the skill says) open the menu above the button when there is no room below, as `ZsMenuButton` does; `.d.ts` / `.prompt.md` say so; a dated "(Story 10.40)" line under the latest DESIGN-SYSTEM-SYNC entry. No publish (waits for a console session).
- Strings through `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`, output committed); Zs controls and DS tokens only; tests in temp dirs, never a real editor or Ralph's settings.

**Never:** a menu on the hunk header; a `{root}` placeholder for the editor command; opening a change's own version of a file; changes to the whitespace-only rule of 10.33 or the IntelliJ launcher form; Rust/FFI changes; a full gate run (story-loop gate rule).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Pinned backing | unified, scrolled fully right; context, added, fold row; dark and light | pin backing colour `.a == 1` | — |
| File menu, click a row | file-row menu open, tap another file row | menu closes; current row unchanged | — |
| Line menu, click a line | line menu open, tap another diff line | menu closes | — |
| Button toggle | `ZsMenuButton` open, tap the button | menu closes | — |
| Unhandled right-click | right-click hunk header / fold row / no-newline row | no exception, no menu | — |
| Split all picked | change ≠ @, every file picked, draft typed | no text field, no Split button; hint + Cancel | unpick one → fields back with the draft |
| Line past end | file on disk 10 lines, line menu for 40, editor `idea` | Open row + note; fake start gets `[<abs>]` without `--line` | missing file: disabled as today |
| Line inside | file 50 lines, line 40 | as today (`--line 40`) | — |
| Repo sets context | repo config `diff.color-words.context = 7`, user 3 | 7 checked, note shown; pick 5 → `configSet(user, …, '5')` | read refused: none checked (as today) |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/inspector_diff.dart:1621-1735` -- `_unified`: `row()` pin `color: Color.alphaBlend(fill, colors.codeBg)` (`:1656`), fold rows (`:1677-1690`, `fill: none`), no-newline row (`:1731`). `:1399-1455` hunk header colours (`accentSoftHi`, accent-12% over `codeBg`, `hunkBg`) — pinned via `_Pinned` when unified. `:1269-1280` line-menu branch: `SelectionArea(contextMenuBuilder: null, …)`. `:1329-1338` `_menuOn` (the only secondary-tap handler). `:566-603` `diffOptionsEntries` (add a `contextFromRepo` flag → note); `:690-760` `InspectorDiffView` params (`contextLines`), `:920-935` passes them.
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart:258-378` -- `_ZsMenuAnchorState.build`: `RawMenuAnchor(consumeOutsideTaps: true, builder: … widget.builder(...))`. Flutter's `RawMenuAnchor.buildAnchor` (`flutter/packages/flutter/lib/src/widgets/raw_menu_anchor.dart:850-864`) wraps the builder's child in `TapRegion(groupId: root.menuController)`, the panel's group too (`info.tapRegionGroupId`), so a tap anywhere in that child counts as inside. Submenus (`:923-948`) use the same group. `:145-157` `ZsMenuController`.
- `packages/zanshin_ui/lib/src/controls/zs_menu_button.dart:71-80` -- `ZsMenuAnchor` + `onPressed: controller.open`.
- Other `ZsMenuAnchor` users to keep green: `app/lib/src/features/graph/graph_card_menu.dart`, `graph_inspector.dart`, `app/lib/src/features/projects/{projects_tree,project_capsule}.dart`, `app/lib/src/features/settings/{remotes_group,immutable_page}.dart`.
- `app/lib/src/features/graph/graph_inspector.dart:3714-4043` -- `_Composer` / `_ComposerState` (fields `:3973-3991`, `result` `:3893`, command row `:3994-4023`, hint `:4024-4029`, `reason` `:3938`); `:868` `splitsEverything`.
- `graph_inspector.dart:3550-3625` -- `inspectorPathMenu` (line branch `:3607-3615`); called for the diff line menu at `:3155-3165`.
- `graph_inspector.dart:212-247` -- `contextLines`, `setContextLines`, `_readContext` via `details.diffContext()`.
- `app/lib/src/features/graph/project_files.dart:177-275` -- `ProjectFiles` (`absolute`, `exists`, `openInEditor`); `:54-101` `editorCommand`, `editorHint`.
- `app/lib/src/features/graph/graph_ports.dart:1056-1076` -- `GraphDetails.diffContext()` / `RepoGraphDetails(this._repo, this._environment)` (add `root`); constructed at `app/lib/src/features/home/project_scope.dart:136` (root is in scope, as `:215` shows), `app/test/features/graph/graph_ports_test.dart:174,203,530,795`, `graph_real_repo_test.dart:166`.
- `app/lib/src/features/undo_timeline/operation_changes.dart:54-82, 153, 209, 230-247, 870` -- `OperationChangesSource.diffContext`, `RepoOperationChangesSource` (has `root`), model `_readContext`, view passes `contextLines`.
- `app/lib/src/features/projects/projects_environment.dart:73-99` -- `effectiveConfigEntry`, `readDiffContext` (user stack), `writeDiffContext`; add the workspace-stack read beside them (`ConfigEntry.source`, `ConfigValueSource.repo/.workspace`, as `settings_view_model.dart:459-462` uses).
- Fakes implementing `diffContext()`: `app/test/helpers/fake_undo_timeline.dart`, `app/test/features/graph/{graph_inspector_test,graph_card_menu_test,graph_ports_test}.dart`, `app/widgetbook/folders/{graph,undo_timeline}.dart`.
- DS: `_bmad-output/implementation-artifacts/design_system/components/actions/MenuButton.{jsx,d.ts,prompt.md}`, `menubutton.card.html`, `_ds_bundle.js:3641-3728` (+ the `sourceHashes` header line 1); `design/DESIGN-SYSTEM-SYNC.md` (latest #26).
- Tests: `app/test/features/graph/inspector_diff_test.dart`, `graph_inspector_test.dart`, `project_files_test.dart`, `app/test/features/undo_timeline/operation_changes_test.dart`, `graph_ports_test.dart`, `packages/zanshin_ui/test/controls/zs_menu_test.dart`, `zs_menu_button_test.dart`.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart` -- make a click inside the anchor's built area count as outside (Design Notes) -- item 2; tests in `zs_menu_test.dart` (tap in the anchor area closes and is consumed; submenu click stays open) and `zs_menu_button_test.dart` (button tap toggles).
- `app/lib/src/features/graph/inspector_diff.dart` -- opaque pin base for unified rows, fold, no-newline and hunk header; empty `contextMenuBuilder`; `diffOptionsEntries` repo note; `InspectorDiffView` takes the flag -- items 1, 3, 6.
- `app/lib/src/features/projects/projects_environment.dart` -- the workspace-stack read returning lines and whether repo/workspace sets it -- item 6.
- `app/lib/src/features/graph/graph_ports.dart`, `graph_inspector.dart` (model), `undo_timeline/operation_changes.dart`, `home/project_scope.dart`, fakes and catalogue -- carry the effective value and the flag; `RepoGraphDetails` gets the root -- item 6.
- `app/lib/src/features/graph/graph_inspector.dart` (`_Composer`, `inspectorPathMenu`) -- the reduced composer; the past-end Open row and note -- items 4, 5.
- `app/lib/src/features/graph/project_files.dart` -- `lineCount` -- item 5; unit test with temp files (10 lines with and without a final newline, empty file, missing file, a folder).
- `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`) -- the two new notes; drop `inspectorSplitAllReason` if unused.
- `design_system/…/MenuButton.*`, `_ds_bundle.js`, `DESIGN-SYSTEM-SYNC.md` -- item 7.
- Tests in `app/test/features/graph/`, `undo_timeline/` -- one per I/O row.

**Acceptance Criteria:**
- Given the unified diff scrolled fully right in the dark and the light theme, when the pinned numbers of a context line, an added line and a fold row paint, then each backing colour has alpha 1.
- Given the file-row menu open, when the user clicks another file row, then the menu closes and the current row does not change; given the line menu open, a click on another diff line closes it; a `ZsMenuButton` click on its open button closes its menu.
- Given the line menu wired, when the user right-clicks a hunk header, a fold row or a no-newline row, then no exception is thrown and no menu opens.
- Given a change other than @ with every file picked and a typed draft, when the composer shows, then no text field, preview, command line or Split button is shown, only the hint and Cancel; when one file is unpicked, the fields show the draft as typed.
- Given a 10-line file on disk, editor `idea` and a fake launcher, when the user picks Open on the line menu for line 40, then the menu shows the past-end note and the fake gets `idea` with `[<absolute path>]`.
- Given a repo config `diff.color-words.context = 7`, when the diff options menu opens, then 7 is checked and the repo note shows; picking 5 writes `5` at user scope.

## Spec Change Log

## Review Triage Log

### 2026-11-15 — Review pass
- verdicts: 28 findings — high 0, medium 2, low 23, false 3, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) the DS kit's composer (`ui_kits/desktop/inspector.jsx:104-106`) still shows the disabled Split with the removed reason while every change is picked — the kit now shows only the hint and Cancel (bundle block and `sourceHashes` updated).
  - `[low]` `[reject]` (blind) the DS `DiffView` options menu has no repo-config note — the DS card shows no repo-config state; the app's note is a plain `ZsMenuNote` of the existing look, and the sync line describes the app.
  - `[low]` `[patch]` (blind) `diffOptionsNote` says Context lines "is … in your user config", false when the repo config sets it — reworded: a pick writes `diff.color-words.context` to the user config.
  - `[low]` `[reject]` (blind) a repo-set context offers no "write to this repository" action — the intent decides it: a pick writes the user config, the note explains.
  - `[low]` `[reject]` (blind) a flipped menu grows from its top-left corner — the app's `ZsMenuButton` flip predates this story and grows the same way; cosmetic, the fix adds origin logic in two places.
  - `[low]` `[reject]` (blind) the DS flip measures once per open and does not clamp sideways like the app — DS previews rarely meet a window edge; the fix adds layout code to a preview.
  - `[low]` `[reject]` (blind) a right-click elsewhere while a context menu is open only closes it — the intent asks that every click outside the panel closes the menu and is consumed; `TapRegion` treats every pointer-down alike.
  - `[low]` `[reject]` (blind) the anchor rewrite changes every `ZsMenuAnchor` user — no content uses `MenuController.maybeOf` (searched `app/lib`, `packages/*/lib`); card and row anchors already sat outside other cards' areas, so their clicks were consumed before; all suites of those users pass.
  - `[low]` `[reject]` (blind) no test for the past-end row with a custom command or without an editor — both run code this story did not change (`editorCommand`'s `{line}` → 1, the "Choose editor…" branch).
  - `[low]` `[reject]` (blind) Copy path:line keeps a line past the end — the intent changes only the Open row; a copied reference names the diff's line, and a branch there adds complexity for a rare case.
  - `[low]` `[reject]` (blind) focus is lost when the composer collapses while a field has focus — picking a file moves focus to the list or a checkbox first; only a pointer-only path could reach it, and the fix adds focus management.
  - `[low]` `[reject]` (blind) `DiffContext` lives in `projects_environment.dart`, so fakes import it from there — no caller breaks; it sits beside the read that builds it, like `ConfigEntry`.
  - `[false]` `[reject]` (blind) the reviewed diff leaves out the generated localizations — they were left out of the review file on purpose; `flutter gen-l10n` ran, `dart analyze` passes and they are committed with the change.
  - `[low]` `[reject]` (blind) no test for an invalid repo value (`(lines: null, fromRepo: true)`) — the parser is shared with the tested user-level path; none checked plus the note is a sensible result for a rare hand edit.
  - `[medium]` `[patch]` (edge) a removed line at the end of a file maps to last new + 1, so the past-end note fires and the editor opens at the start — line = lines + 1 now opens at the file's last line with no note; test added.
  - `[low]` `[reject]` (edge) a symlink to `/dev/zero` or a huge file blocks the synchronous count — repo symlinks to such targets are rare; the `shortcut:` comment names the upgrade path.
  - `[medium]` `[patch]` (edge) an outside click in the anchor's own area closes with `refocus: false`, so keyboard focus is lost (the file list stops taking ↑ ↓) — such a click now refocuses the opener; test added.
  - `[low]` `[reject]` (edge) a right-click on a hunk header may select a word through the selection area — cosmetic; the next click clears it, and blocking it needs a handler per row type.
  - `[low]` `[patch]` (edge) `readDiffContext` lost its last caller — deleted (Settings never used it; the spec's premise was wrong).
  - `[low]` `[reject]` (edge) the DS `MenuButton` claims to place "as the app's ZsMenuButton" without the horizontal clamp — same as the blind row on the DS flip.
  - `[low]` `[patch]` (verification gap) `RepoOperationChangesSource.diffContext()` (the real workspace read) is untested; the operation-view test uses a fake source — test added for the repo and workspace layers.
  - `[low]` `[reject]` (intent) item 2 changes every menu, not only menus opened at a position — the spec's design note chose it; for a button menu the anchor area is the button, which gives the toggle the witness asks for.
  - `[low]` `[reject]` (intent) the note also fires for a workspace-layer value while its text says "this repository's config" — the workspace config belongs to the repository's checkout; both win over the user config as the note says.
  - `[low]` `[reject]` (intent) the alpha test does not scroll sideways — the backing colour does not depend on the scroll offset.
  - `[false]` `[reject]` (intent) the part gutter is not in the alpha test — the gutter is a child of the same measured pin container, whose colour the test reads.
  - `[low]` `[reject]` (intent) the `ZsMenuButton` toggle is tested only in `zanshin_ui` — the app's buttons are the same control.
  - `[low]` `[reject]` (intent) gaps and conflict headers are not right-clicked in a test — the fix is the one builder all of them reach.
  - `[false]` `[reject]` (intent) the spec, deferred-work and epic context are missing from the diff — left out of the review file on purpose; they are committed with the change, and nothing was deferred.

### 2026-11-15 — Review pass (follow-up)
- verdicts: 30 findings — high 0, medium 0, low 19, false 10, maybe-false 1
- findings:
  - `[low]` `[patch]` (blind) the opaque fold-row pin hides the row's 135° hatch over the gutter and number columns — the pin now paints the hatch itself (`row(hatch: true)`: a `CustomPaint` with `_FoldHatchPainter` between the opaque colour and the numbers, `inspector_diff.dart`); the alpha test also checks that only the fold row's pin is hatched.
  - `[low]` `[patch]` (blind) `@inspectorSplitAllHint` still describes "the note under the buttons" — reworded to the only text beside Cancel; `flutter gen-l10n` rerun.
  - `[low]` `[reject]` (blind) `lineCount` reads the whole file on the UI isolate — carried: same as the logged symlink/huge-file row; the `shortcut:` comment names the upgrade.
  - `[false]` `[reject]` (blind) an empty file on disk with line 1 gets the past-end note while a removed last line elsewhere does not — the note is true (an empty file has no line 1) and the editor opens at the only position there is.
  - `[low]` `[reject]` (blind) Copy path:line can disagree with Open — carried: same as the logged Copy path:line row.
  - `[low]` `[reject]` (blind) Settings › General › Diffs shows the user value while the menu shows the workspace value — intent item 6 keeps Settings at user level; the menu's note explains the repo layer.
  - `[false]` `[reject]` (blind) `fromRepo` misses the `envOverrides` layer — that layer carries only jj's environment variables (`JJ_USER`, `JJ_EMAIL`, …); `diff.color-words.context` cannot come from it.
  - `[false]` `[reject]` (blind) nested anchors lose their parent/child menu link — no `ZsMenuAnchor` sits in another anchor's content: the graph card menu's content is an empty box, the diff options button is in the diff header outside the line menu's body, the file list and the diff are siblings.
  - `[low]` `[reject]` (blind) a right-click on another row only closes the open menu — carried: same as the logged right-click row.
  - `[maybe-false]` `[reject]` (blind) the empty `contextMenuBuilder` overlay may swallow the next click — needs a widget test with a left click after a header right-click; if true only low (one extra click), so rejected with this note.
  - `[low]` `[reject]` (blind) focus is lost when the composer collapses — carried: same as the logged composer-focus row.
  - `[low]` `[reject]` (blind) the DS flip measures once and does not clamp sideways — carried: same as the logged DS flip rows.
  - `[low]` `[reject]` (blind) `DiffContext` lives in the projects feature — carried: same as the logged `DiffContext` row.
  - `[false]` `[reject]` (blind) nothing tracks the unpublished DS change — `deferred-work.md` tracks it (the Story 10.38 item: Ralph publishes 10.35–10.40 together after this story).
  - `[low]` `[reject]` (blind) the open-button close test does not check focus — the toggle runs the same anchor-area close as `zs_menu_test.dart`'s refocus test, which checks focus.
  - `[low]` `[reject]` (edge) a right-click on another row is consumed, so it needs two right-clicks — carried: same as the logged right-click row.
  - `[false]` `[reject]` (edge) `anchorRect` is in overlay space and the pointer position global — no nested `Overlay` exists in `app/lib` or `packages`; each window's root overlay sits at its view origin, so both share coordinates.
  - `[low]` `[patch]` (edge) the `_open` comment names a second click or right-click on the anchor, which now only closes the menu — comment reworded to a caller's `open` while the menu shows (`zs_menu.dart`).
  - `[false]` `[reject]` (edge) the anchor content left `RawMenuAnchor`'s `Shortcuts` (arrows, Esc) — `WidgetsApp`'s default shortcuts map the same keys to the same intents, so nothing changes for the content.
  - `[low]` `[patch]` (edge) the fold-row hatch is no longer full width — same root cause as the blind fold-hatch row; fixed by it.
  - `[low]` `[reject]` (edge) an added or context line at lines + 1 (a later change shortened the file by exactly one line) opens silently at the last line — rare, and the fix needs the line kind passed into `inspectorPathMenu`.
  - `[low]` `[reject]` (edge) the DS `MenuButton` claims parity without the horizontal clamp — carried: same as the logged DS clamp row.
  - `[false]` `[reject]` (verification gap) the `refocus: false` side of the outside close is untested — the proposed assertion (`button.hasPrimaryFocus` false after a click outside) fails: focus returns to the opener through the focus scope's history either way, so the branch has no distinct outcome; assertion reverted.
  - `[low]` `[patch]` (verification gap) no test reads the side-by-side hunk header colour — the picked-hunk test now also pumps side by side and expects the raw `accentSoftHi` band.
  - `[low]` `[patch]` (intent) the `splitsEverything` docstring still says "Split stays disabled" — reworded: the composer shows only its hint and Cancel.
  - `[low]` `[reject]` (intent) line N + 1 opens at the last line with no note, beyond the literal item 5 — the previous pass's deliberate fix: a removed last line maps to lines + 1 (`diffNewLineAt`).
  - `[false]` `[reject]` (intent) `readDiffContext` was deleted though Settings "keeps" it — Settings never called it (`settings_view_model.dart` reads through `configList` without a root); its user-level read is unchanged.
  - `[false]` `[reject]` (intent) DS changes reach beyond `MenuButton` — the kit composer follows item 4 so the DS matches the app; no bad outcome.
  - `[low]` `[reject]` (intent) tests check widget properties and fakes, not the running app — the Marionette check is the console session's manual check, as the spec says.
  - `[false]` `[reject]` (intent) the hand-written `sourceHashes` were not checked — the sha256 prefixes of `MenuButton.jsx` and `ui_kits/desktop/inspector.jsx` match the bundle header.

## Design Notes

- **Item 2, why the anchor area must leave the menu's tap group:** Flutter's `RawMenuAnchor` puts the builder's child in the menu's tap-region group, and nested `TapRegion`s cannot take a child out of it. Proposal: `ZsMenuAnchor.build` returns `Stack(fit: StackFit.passthrough, children: [widget.builder(context, _controller), Positioned.fill(child: RawMenuAnchor(…, builder: (_, _, _) => const SizedBox.expand()))])`. The anchor's `TapRegion` then wraps an empty, never-hit box of the same rect (so `anchorRect` and placement are unchanged), the content is outside the group, the panel's `onTapOutside` closes the menu and the anchor region's `consumeOutsideTaps` consumes the click; submenus keep the shared group. This applies to every `ZsMenuAnchor`: for a button-anchored menu the area is the button, so the click toggles it (the `ZsMenuButton` witness). Verify the consumption actually stops `ZsButton.onPressed` and the file rows' tap (a test per case); if `ZsButton` reacts to raw pointer events instead of the gesture arena, stop the reopen in `ZsMenuButton` instead.
- **Item 5, why a visible note and not a tooltip:** a row tooltip shows only on hover; the note is read at once and by VoiceOver in order. Counting reads the file synchronously when the menu opens, like `exists()`. Add the comment `shortcut: reads the whole file on the UI isolate, move to an isolate if large files make the menu lag`.
- **Item 6:** `jj diff` in a workspace uses the whole config stack, so the menu shows the same; the note explains why a user-level pick may not change the diff.

## Verification

**Commands:**
- `flutter gen-l10n` in `app` -- output committed.
- `flutter test` in `packages/zanshin_ui` -- pass.
- `cargo make test-app test/features/graph test/features/undo_timeline test/features/home test/features/settings test/features/projects test/widgetbook test/l10n test/architecture` -- pass.
- `dart analyze app packages/zanshin_ui` -- no issues.
- `dart format --set-exit-if-changed -o none` on the touched `lib`/`test`/`widgetbook` dirs -- 0 changed.
- `node --check _bmad-output/implementation-artifacts/design_system/_ds_bundle.js` -- passes.
- Not run (story-loop gate rule): `cargo make test` / `test-full` / `coverage`; no Rust change, so no cargo checks.

**Manual checks:**
- Marionette in the running catalogue (pinned numbers, both menus, Split hint) is the console session's, after the run.

**Verification notes (2026-11-15, gate rule of the story loop: no full gate):**
- `flutter gen-l10n` in `app` -- run by the implementation (and after the `diffOptionsNote` rewording); output committed.
- `flutter test` in `packages/zanshin_ui` -- 475 passed (before and after the review patches).
- `cargo make test-app test/features/graph test/features/undo_timeline test/features/home test/features/settings test/features/projects test/widgetbook test/l10n test/architecture` -- 1943 passed before the review patches, 1945 after them.
- `dart analyze app packages/zanshin_ui` -- No issues found (before and after).
- `dart format --set-exit-if-changed -o none` on `app/lib`, `app/test`, `app/widgetbook`, `app/integration_test`, `packages/zanshin_ui/lib`, `packages/zanshin_ui/test` -- 0 changed (before and after).
- `node --check design_system/_ds_bundle.js` -- passes (before and after).
- Not run: `cargo make test` / `test-full` / `coverage` (the loop's gate rule); no Rust or FFI changed, so no cargo checks, codegen or parity oracle. Not done: Marionette check and the DS publish (console session).

**Verification notes, follow-up review (2026-11-15, same gate rule):**
- `flutter gen-l10n` in `app` -- run after the `@inspectorSplitAllHint` rewording; output committed.
- `flutter test` in `packages/zanshin_ui` -- 475 passed (one run failed on the reverted focus assertion, see the triage log).
- `cargo make test-app test/features/graph test/features/undo_timeline test/features/home test/features/settings test/features/projects test/widgetbook test/l10n test/architecture` -- 1945 passed (a first run failed on the new hatch finder, which matched the fold checkbox's painter too; narrowed to `_FoldHatchPainter`).
- `dart analyze app packages/zanshin_ui` -- No issues found.
- `dart format --set-exit-if-changed -o none` on `app/lib`, `app/test`, `app/widgetbook`, `app/integration_test`, `packages/zanshin_ui/lib`, `packages/zanshin_ui/test` -- 0 changed.
- `shasum -a 256` of `MenuButton.jsx` and `ui_kits/desktop/inspector.jsx` -- prefixes match `_ds_bundle.js`'s `sourceHashes`.
- Not run: the full gate (loop rule); no Rust, FFI or DS file changed in this pass.

## Auto Run Result

Status: done

**Summary.** The unified diff's pinned backings (numbers, part gutter, fold and no-newline pins, hunk header) paint on an opaque base, `codeBg` over `flBgSolid`, in both themes. `ZsMenuAnchor` draws `RawMenuAnchor` over an empty box of its content's size, so any click outside a menu panel — the whole file list or diff included — closes the menu and is consumed; a `ZsMenuButton` click on its open button closes it, and a click in the anchor's area gives focus back to the opener. The line menu's `SelectionArea` gets an empty `contextMenuBuilder`, so right-clicks no line answers no longer crash. With every change picked, the Split composer shows only its hint and Cancel and keeps the draft. `ProjectFiles.lineCount` lets the line menu open a line past the file's end at the start, with a note (a removed last line opens at the last line). The diff options menu, in the inspector and the operation view, checks the workspace's effective `diff.color-words.context` and notes when the repo or workspace config sets it; picks still write `--user`. DS: `MenuButton` flips above without room; the kit composer follows the new Split rule; not published. DS synced through #26.

**Commits.** The code commit (code, tests, DS, DESIGN-SYSTEM-SYNC line) and the docs commit (this spec, sprint status, epic 10 context) follow this write-up; their hashes are in the run report.

**Files changed.**
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart` -- anchor over an empty box; outside clicks close, are consumed, refocus the opener in the anchor area.
- `app/lib/src/features/graph/inspector_diff.dart` -- opaque pin base; empty `contextMenuBuilder`; repo note in `diffOptionsEntries`, `InspectorDiffView.contextFromRepo`.
- `app/lib/src/features/graph/graph_inspector.dart` -- reduced Split composer; past-end Open row and note; model `contextFromRepo`.
- `app/lib/src/features/graph/project_files.dart` -- `lineCount`.
- `app/lib/src/features/projects/projects_environment.dart` -- `DiffContext`, `readWorkspaceDiffContext`; the orphaned `readDiffContext` deleted.
- `app/lib/src/features/graph/graph_ports.dart`, `undo_timeline/operation_changes.dart`, `home/project_scope.dart` -- the workspace read with its root.
- `app/lib/l10n/*` -- `filesLinePastEnd`, `diffContextFromRepo`, reworded `diffOptionsNote`, removed `inspectorSplitAllReason`.
- Fakes and catalogue: `app/test/helpers/fake_undo_timeline.dart`, `app/integration_test/glass_profile.dart`, `app/widgetbook/folders/{graph,undo_timeline}.dart`.
- Tests: `zs_menu_test.dart`, `zs_menu_button_test.dart`, `inspector_diff_test.dart`, `graph_inspector_test.dart`, `project_files_test.dart`, `graph_ports_test.dart`, `graph_real_repo_test.dart`, `graph_card_menu_test.dart`, `operation_changes_test.dart`.
- DS: `components/actions/MenuButton.{jsx,d.ts,prompt.md}`, `ui_kits/desktop/inspector.jsx`, `_ds_bundle.js` (blocks and `sourceHashes`), `readme.md`; `design/DESIGN-SYSTEM-SYNC.md` dated line under #26.

**Review findings.** 28 findings: high 0, medium 2, low 23, false 3. Patched: 2 medium (a removed last line got the past-end note; a click in the anchor area lost keyboard focus) and 4 low (DS kit composer, `diffOptionsNote` wording, orphaned `readDiffContext`, an untested `RepoOperationChangesSource.diffContext`). Deferred: none. Rejected 19 low and 3 false, each with its reason in the triage log: DS `DiffView` note, repo-scope write action, flipped-menu origin, DS horizontal clamp (twice), right-click re-open, other `ZsMenuAnchor` users, custom-command and no-editor past-end tests, Copy path:line past the end, focus when the composer collapses, `DiffContext` location, invalid repo value test, symlinked huge files, word selection on a header right-click, all-menus scope, workspace-scope note, unscrolled alpha test, app-level toggle test, gaps and conflict headers; false: review file left out generated files, the gutter missing from the alpha test, the spec missing from the diff.

**Follow-up review recommendation: true.** Patched this pass: high 0, medium 2, low 4. Two medium patches reach the threshold. The specific unverified risk: the `ZsMenuAnchor` rewrite changes every menu in the app (graph card menu, Projects tree, capsule, Settings remotes and immutable pages): the anchor's content left `RawMenuAnchor`'s shortcuts scope, a right-click on another row now only closes the open menu, and the focus return compares the overlay-space anchor rect with the global click position. Widget suites pass; none of it was tried in the running app.

**Residual risks.**
- No Marionette check of the pinned numbers, both menus or the Split hint (left to the console session, as the story says).
- The DS `MenuButton` flip and the kit composer were not opened in a browser; the DS `DiffView` demo note still carries the old `diffOptionsNote` sentence.
- `lineCount` reads the whole file on the UI isolate when the line menu opens (`shortcut:` comment).

### Follow-up review pass (2026-11-15)

Status: done

**Summary.** A fresh four-layer review of the finished story. It found one visible regression: the opaque fold-row pin hid the 135° hatch over the gutter and number columns. The pin now paints the hatch itself, between its opaque colour and the numbers. The rest were small corrections: a stale ARB description, two stale comments, and a side-by-side test for the hunk header band.

**Files changed.**
- `app/lib/src/features/graph/inspector_diff.dart` -- `row(hatch:)`: the fold row's pin paints `_FoldHatchPainter` over its opaque backing.
- `app/lib/src/features/graph/graph_inspector.dart` -- `splitsEverything` docstring.
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart` -- `_open` comment.
- `app/lib/l10n/app_en.arb`, `app_localizations.dart` -- `@inspectorSplitAllHint` description.
- `app/test/features/graph/inspector_diff_test.dart` -- hatch check in the alpha test; side-by-side header band check.

**Review findings.** 30 findings: high 0, medium 0, low 19, false 10, maybe-false 1. Patched: 5 low entries (fold hatch, two layers reporting it; ARB description; `_open` comment; side-by-side header test; `splitsEverything` docstring). Deferred: none. Rejected, each with its reason in the triage log: 13 low (9 carried from the first pass: `lineCount` on the UI isolate, Copy path:line, right-click twice ×2, composer focus, DS flip and clamp ×2, `DiffContext` location; plus Settings showing the user value, the open-button focus test, a context line at lines + 1, line N + 1 opening at the last line, no Marionette check), 1 maybe-false (an empty context-menu overlay swallowing a click; low if true), and 10 false (empty file note, `envOverrides`, nested anchors, untracked DS publish, overlay coordinates, lost `Shortcuts`, the `refocus: false` test, `readDiffContext` deletion, DS scope, `sourceHashes`).

**Follow-up review recommendation: false.** Follow-up pass: patched high 0, medium 0, low 5. No high patch, so the work has converged.

**Verification.** See "Verification notes, follow-up review" above: zanshin_ui 475 passed, targeted app suites 1945 passed, analyze and format clean, l10n regenerated, `sourceHashes` checked.

**Residual risks.**
- Still no Marionette check of the pinned numbers (now with the fold hatch), the menus or the Split hint; left to the console session.
- The fold-row hatch in the pin is drawn from the pin's own origin, so its lines may not line up exactly with the row's hatch at the pin's edge while scrolled sideways (cosmetic).
