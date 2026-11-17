---
title: 'Story 10.49 — File masks: hide files you do not care about from the inspector''s file list'
type: 'feature'
created: '2026-11-17'
status: 'done'
baseline_revision: '2c699a2af2be9a033bcb58c551abc3224d7332de'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/.claude/skills/design-artifacts/SKILL.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Generated files (`*.g.dart`, `*.freezed.dart`, generated localizations, lock files) crowd the inspector's file list in every review, and there is no way to hide them (deferred-work I1).

**Approach:** Build `design/Inspector Extras Study.html` §4: one app-wide list of IntelliJ-style file masks with ticks, stored in `packages/zanshin_settings`, matched in Dart only. Ticked masks hide matching rows from the inspector's and the operation view's file lists; the files stay part of the change and its picks. A funnel in the files header opens the masks popover; a hint row at the bottom says how many files are hidden and offers Show and Masks…. DS synced through #31, plus a new #32.

## Boundaries & Constraints

**Always:**
- **Storage:** `GeneralSettings.fileMasks` (`List<FileMask>`, `FileMask {String mask, bool active}`, freezed + json in `general_settings.dart`, run `dart run build_runner build` in `packages/zanshin_settings`, commit the generated files). Default (a fresh install and any file without the key): `[FileMask(mask: '*.g.dart, *.freezed.dart'), FileMask(mask: '*.lock')]`, both inactive, so nothing is hidden until a tick. An empty saved list stays empty. One list for the app, never per project.
- **Matcher** (new `app/lib/src/features/graph/file_masks.dart`, pure Dart, no FFI, no new dependency — `package:glob` is not a dependency): an entry splits at commas into trimmed, non-empty masks; a path matches an entry when any mask matches. A mask without `/` matches the file name (the part after the last `/`); a mask with `/` matches the whole repo path (a leading `/` is dropped). `**/` matches zero or more whole folders, any other `**` any characters including `/`, `*` any characters except `/`, `?` one character except `/`; everything else literal; anchored at both ends; case-sensitive. Compiled once per settings value, not per row.
- **Mask edits** (shared by both views, on the `SettingsStore`; a failed write is swallowed like `setFileList`): add (trim; empty does nothing; the entry goes to the top, active; an equal entry already in the list moves to the top and becomes active instead of doubling), toggle active, remove.
- **Inspector model** (`InspectorViewModel`): follows `general.fileMasks` in `_settingsChanged`. Exposes the masked paths of the selection (active masks over `_listed`), the shown files (all files while Show is on, else the unmasked ones, jj's order), and a Show flag that is per change: off again when the selected key changes. Initial focus is the first shown file; when the focused file becomes hidden (a tick, Hide, a reload) the focus moves to the next shown file in jj's order, else the previous one, else none. `allPicked`, `pickAll`, `allState`, the picks, Viewed counts, `markAll` and the composer keep using every file — hidden files keep their picks and a commit or split takes a picked hidden file.
- **Files pane** (`_ChangesState`): flat and tree rows come from the shown files only (a folder of only hidden files disappears; a folder's box then covers its shown files); ↑/↓ follow the rows. The header's file count stays the total. Funnel button between the viewed counter and the tree/flat switch: `filter` glyph 13 + the number of active entries while at least one is active; 24 high, padding 0 6, radius 7, `--text-dim`, `--accent` while any entry is active, hover or open `--fl-hover` + `--text`; tooltip "Hide files by name" / "Hiding files matching N masks" (ICU plural); identifier `inspector-file-masks`.
- **Hint row** at the bottom of the files pane, below the scroll, only while the change has masked files: 30 high, 6 above, 1 px `--fl-border` top line, 11.5 `--text-dim`. On a selectable change its checkbox in the 22 px gutter, always visible (not on demand): the hidden files' pick state (all / some / none → true / null / false) and a click picks or unpicks all of them (`togglePicks`); label "Pick the N hidden files". Text "N files hidden" (Show on: "N files match your masks") + " · all picked" / " · some picked" / " · none picked" (pick part only on a selectable change), ellipsis. Then text buttons Show (on: Hide) and Masks… (`InspectorTextButton`). Identifiers `inspector-masked-hint`, `inspector-masked-check`, `inspector-masked-show`, `inspector-masked-masks`.
- **Masked rows while shown:** `InspectorFileRow.masked` — the row at opacity .55 and the `eye-off` glyph 12 px `--text-faint` right after the name (inside the name's note, before the folder), tooltip "<path> · hidden by a file mask", semantics label adds "hidden by a file mask".
- **Popover** (`FileMasksPopover` in `file_masks.dart`, a `ZsPopover`-styled surface ~360 wide, hosted like `GraphViewOptionsButton`: `RawMenuAnchor`, `consumeOutsideTaps`, Esc and a click outside close it, focus returns to the opener on Esc): placed 6 below its anchor, left edges aligned, kept 8 inside the window. Content: title "Hide files matching" (11.5 600 `--text-dim`); a mono `ZsTextField` with autofocus, placeholder "Add a mask, e.g. *.g.dart  ↵", label "New file mask", ↩ adds and clears the field; one 28-high row per entry (radius 6, hover `--fl-hover`): `ZsCheckbox` (label "Stop hiding <mask>" / "Hide <mask>"), the entry in mono 11.5 `--text` with ellipsis, how many files of the shown change it matches (mono 11 `--text-faint`, empty for 0), and a × (`close` 11, 20×20) visible only on row hover or keyboard focus in the row, label "Remove <mask>", tooltip "Remove from the list"; a click on the row or its box toggles; the footer (1 px `--fl-border` above, 11 `--text-faint`): "* and ? match inside a name, ** across folders. A mask with “/” matches the path. Separate several with commas." The funnel and the hint row's Masks… open the same popover under the funnel (one `MenuController`). Identifiers `file-masks-popover`, `file-masks-field`, `file-mask-<index>`, `file-mask-<index>-remove`.
- **Operation view** (`operation_changes.dart`): `OperationChangesModel` follows the masks the same way (shown files, a Show flag per selected commit, first shown file focused, focus moves off a newly hidden file); `_Files` lists only shown rows (masked rows dimmed while shown) and adds the hint row without a checkbox and without the pick part; its Masks… is itself the popover's anchor.
- **Glyphs** `filter` (the study's funnel: `M2.5 3.5h11l-4.3 5v4.5l-2.4-1.3V8.5z`) and `eye-off` (the study's `eyeOff`), drawn like the other glyphs (16 grid, `stroke-width="1.5"`, round caps/joins, `fill="none"`, one-line file in the existing format): `packages/zanshin_ui/assets/icons/svg/` and DS `assets/icons/ui/` byte-identical, `glyphs.json`, `ZI.filter` / `ZI.eyeOff` + `ZI.all`.
- Strings in `app/lib/l10n/app_en.arb` (ICU plurals for counts) + `flutter gen-l10n` (output committed); mask texts are user data, not localized.
- **DS** via `design-artifacts` C + E (no publish): the two glyphs (`assets/icons/ui/*.svg`, `glyphs.json`, `components/brand/Icon.jsx` map, `Icon.d.ts` / `.prompt.md` glyph count); `FileRow` gains `masked` (`.jsx`, `.d.ts`, `.prompt.md`, `content.css`: .55 + eye-off after the name); `_ds_bundle.js` Icon and FileRow blocks by hand; `readme.md` "Synced through #32" + a dated line; a new entry `### #32 · 2026-11-17 · File masks …` at the end of `design/DESIGN-SYSTEM-SYNC.md` (masks, syntax, funnel, popover, hint row, masked row; app-side follow-up line). Never touch the study files.

**Never:** hiding files in the graph or changing a card's file count; masks per project; negated masks; jj's fileset language; an FFI, Rust or schema change; a Settings window row for the masks; leaving hidden files out of picks, "pick all" or the composer's paths; publishing the DS or the Marionette check (console session); the full gate (`cargo make test` / `test-full` / `coverage`).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| generated code | study's 24 files, `*.g.dart, *.freezed.dart` active | `app_routes.g.dart`, `automation.freezed.dart`, `automation.g.dart`, `automations_provider.g.dart` gone; hint "4 files hidden · all picked" on @; funnel shows 1 | — |
| path mask | `docs/*.png` | hides `docs/packages.png`, not `a/docs/x.png` nor `img.png` | — |
| name glob | `core_localizations*.dart` | hides `core_localizations.dart`, `_de.dart`, `_en.dart` | — |
| `**` | `packages/**/*.g.dart` | hides `packages/x/lib/a.g.dart` and `packages/a.g.dart`, not `app/a.g.dart` | — |
| case | `*.G.dart` | hides nothing of `a.g.dart` | — |
| add | type `*.arb` + ↩ | entry at the top, active, count 2; field empty | blank input: nothing |
| re-add | `*.lock` (inactive, 2nd) + ↩ | moves to the top, active; one entry | — |
| remove | × on `*.arb` | entry gone, its files listed again | — |
| hidden pick | @, a hidden file picked, `jj commit` | runs with that file (no paths when all picked) | — |
| hint box | click the hint's box while all hidden picked | hidden files unpicked, shown picks unchanged; composer command lists only the shown paths | — |
| show | Show | hidden rows back, dimmed + eye-off; hint "N files match your masks", button Hide | — |
| focus | focused file gets masked | focus moves to the next shown file (else previous, else none) | — |
| all hidden | every file masked | empty list, hint row only, no diff | — |
| new change | Show on, select another change | Show off | — |
| restart | masks edited, new store loaded from the file | same masks and ticks | corrupt file: store's existing recovery |

</intent-contract>

## Code Map

- `packages/zanshin_settings/lib/src/model/general_settings.dart` -- `GeneralSettings` (add `fileMasks`, the pattern `diffFileList` `:63-66`); add `FileMask` here; regenerate `.freezed.dart` / `.g.dart` (`build.yaml` sets `checked`, `explicit_to_json`, the width header). Tests `packages/zanshin_settings/test/model/app_settings_test.dart` (defaults, round trip, missing key → seeds, empty list kept).
- `app/lib/src/features/graph/graph_inspector.dart` -- `InspectorViewModel` ctor `:91-113`, fields `:128-177`, `_listed` `:330`, `setFileList` `:371` (write pattern), `picksState`/`togglePicks` `:393-415`, `_settingsChanged` `:441-478`, `allPicked`/`pickAll` `:708, 825` (unchanged, all files), `_graphChanged` (key change → reset Show) near `:1120-1151`, `_fetch` focus `:1189-1210`. `_ChangesState` `:2773-3381`: `_rowsOf` `:2840`, `_settle` `:2899` (uses `entry.fileChanges`; switch to shown files), header row `:3119-3219` (funnel before the `ZsSegmented` `:3198`), list `:3220-3266` (hint row after the `Expanded`). `InspectorFileRow` `:3400-3545` (add `masked`; note span `:3468`, label `:3478`, tooltip `:3540`). `_CheckGutter` `:3556`.
- `app/lib/src/features/graph/inspector_file_tree.dart` -- `inspectorFlatRows` / `inspectorTreeRows` take the shown files (unchanged code).
- `app/lib/src/features/graph/inspector_diff.dart:1405` -- `InspectorTextButton` (Show, Hide, Masks…).
- `app/lib/src/features/graph/graph_controls.dart:183-308, 408-434` -- popover host pattern (`RawMenuAnchor`, `TapRegion`, `FocusScope`, Esc, `_PopoverLayout`); `packages/zanshin_ui/lib/src/controls/zs_popover.dart` -- `ZsPopover` (menu material, padding, transition).
- `packages/zanshin_ui/lib/src/controls/zs_text_field.dart:300-378` -- `ZsTextField(mono, placeholder, label, onSubmitted, controller, focusNode, identifier)`; `ZsCheckbox`; `ZsIconButton` (`zs_button.dart:380`, `size`); `ZsControlCore` for the funnel.
- `app/lib/src/features/undo_timeline/operation_changes.dart` -- `OperationChangesModel` ctor `:161-169`, `_settingsChanged` `:299`, `_read` (first file focus `:520`), `focus` `:534`; `_Files` `:888-958` (rows `:926-927`), `_FileRow` `:960-982`.
- `packages/zanshin_ui/lib/src/icons/zanshin_icon.dart:149-280` -- `ZI` constants and `ZI.all`; `packages/zanshin_ui/assets/icons/svg/close.svg` (file format); parity test `packages/zanshin_ui/test/design/ds_parity_test.dart:67-110`, `test/icons/zanshin_icon_test.dart:28`.
- `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n` in `app`) -- new strings next to `inspectorFileList*`.
- Tests: `app/test/features/graph/graph_inspector_test.dart` -- `_Details` `:98` (`files` per key, `fileDiffs`), helpers `_id` `:483`, `_fileRow` `:492`, `_button` `:494`; file-list tests near `:3627`, `:4771`. `app/test/features/undo_timeline/operation_changes_test.dart`. New `app/test/features/graph/file_masks_test.dart` (matcher + edits).
- Catalogue: `app/widgetbook/folders/graph.dart` -- `Inspector` use cases `:350-375`, `_InspectorAt` `:2400-2450`, `_DemoDetails` `:1085` (paths) — add a "File masks" use case with the study's files and `*.g.dart, *.freezed.dart` active; `app/test/widgetbook/catalogue_smoke_test.dart` must pass.
- DS: `_bmad-output/implementation-artifacts/design_system/assets/icons/{glyphs.json,ui/}`, `components/brand/Icon.{jsx,d.ts,prompt.md}`, `components/content/FileRow.{jsx,d.ts,prompt.md}`, `components/content/content.css`, `_ds_bundle.js`, `readme.md:22` + dated list; `design/DESIGN-SYSTEM-SYNC.md` (append #32). Reference only: `design/extras-study.jsx:257-403`, `design/extras-study.css:74-99`, its icons `:16, :21`.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_settings/lib/src/model/general_settings.dart` (+ generated files, test) -- `FileMask`, `fileMasks` with the two inactive seeds.
- `app/lib/src/features/graph/file_masks.dart` -- matcher (compiled set, per-entry counts), mask edits on `SettingsStore`, `FileMasksPopover` + its anchor host, the funnel button, the shared hint row widget (checkbox optional).
- `app/test/features/graph/file_masks_test.dart` -- every matcher row of the matrix, add / re-add / blank / toggle / remove, popover: ↩ adds, × removes, row click toggles, Esc closes.
- `packages/zanshin_ui` -- `filter.svg`, `eye-off.svg`, `ZI.filter`, `ZI.eyeOff`, `ZI.all`.
- `app/lib/src/features/graph/graph_inspector.dart` -- model (masks, shown files, Show, focus), files pane (shown rows, funnel, hint row), `InspectorFileRow.masked`.
- `app/lib/src/features/undo_timeline/operation_changes.dart` -- model and `_Files` (shown rows, hint row without checkbox, Masks… anchor).
- `app/lib/l10n/app_en.arb` + `flutter gen-l10n` -- the new strings.
- `app/test/features/graph/graph_inspector_test.dart` -- matrix rows for the inspector: hidden rows (flat and tree, folder gone), hint text and pick state, hint box toggles only hidden files, hidden pick reaches `GraphCommit` paths, Show/Hide dimming, focus move, all hidden, Show resets on a new change, funnel count, ↓ skips hidden.
- `app/test/features/undo_timeline/operation_changes_test.dart` -- hidden rows, hint without checkbox, Show, first shown file focused.
- `app/widgetbook/folders/graph.dart` -- "File masks" use case.
- DS -- glyphs, FileRow `masked`, bundle blocks, readme, DESIGN-SYSTEM-SYNC #32.

**Acceptance Criteria:**
- Given the study's 24 files on @ and `*.g.dart, *.freezed.dart` ticked, when the inspector shows them, then the four generated files are not listed, the hint row reads "4 files hidden · all picked", the funnel shows 1, and Commit without other changes runs `jj commit` with no paths.
- Given that state, when the hint row's box is clicked, then the four files are unpicked, the composer shows Split with only the 20 shown paths, and the hint reads "· none picked".
- Given masks edited in one window's popover, when another inspector (a second model on the same `SettingsStore`) or a store loaded again from the same file reads them, then it hides the same files.
- Given the operation view of a commit with a masked file, when it shows the files, then the masked file is not listed and the hint row has no checkbox.
- Given the DS files, when `ds_parity_test.dart` runs, then `filter` and `eye-off` are one set across DS, `glyphs.json`, app assets and `ZI`.

## Spec Change Log

## Review Triage Log

### 2026-11-17 — Review pass
- verdicts: 30 findings — high 0, medium 3, low 23, false 4, maybe-false 0
- findings:
  - `[medium]` `[patch]` (blind) the popover's entry list cannot scroll; many masks or a short window overflow — the entry list now scrolls inside the popover, header, field and footer fixed.
  - `[low]` `[patch]` (blind) duplicate entries from a hand-edited settings.json give duplicate row keys — rows keyed by index and mask.
  - `[low]` `[reject]` (blind) toggle/remove by index can hit the wrong entry if another window edits between build and click — the popover rebuilds synchronously on every store change (`ListenableBuilder`), so the window between build and click is one frame; matching by value adds API surface for a race nobody meets.
  - `[medium]` `[patch]` (blind) the operation view's popover unmounts itself when the last hiding mask is unticked (its anchor lives in the hint row) — the anchor stays mounted while the commit has files (it is now the whole hint row, a zero-size box while nothing is hidden, so the popover opens under the hint row rather than under Masks…); test added.
  - `[low]` `[patch]` (blind) `,` is stored as a ticked entry that hides nothing but lights the funnel — `addFileMask` refuses text without a usable mask; `_compile` skips masks empty after the leading `/`.
  - `[low]` `[reject]` (blind) duplicate detection compares raw text (`*.a,*.b` vs `*.a, *.b`) — two equal-meaning entries are harmless and visible; normalizing the user's text adds rules the spec does not have.
  - `[low]` `[patch]` (blind) a masked renamed file loses its `old → new` tooltip — the suffix is added to the rename text.
  - `[low]` `[reject]` (blind) DS `FileRow.jsx` eye-off `span` has `aria-label` without a role — the jsx is an illustration; VoiceOver is the Flutter row's (10.36/10.48 triage rule).
  - `[low]` `[patch]` (blind) the DS content card has no masked row — one masked row added to the card.
  - `[false]` `[reject]` (blind) the funnel tooltip says "masks" but counts entries — the study's own tooltip counts ticked entries with the same words (`extras-study.jsx:364`); an entry is what the user ticks.
  - `[low]` `[reject]` (blind) the hint box drops a hidden file's part picks — the same rule as a folder's box (10.39 `togglePicks`); the hint row says "some picked" before the click, so the loss is not silent.
  - `[low]` `[reject]` (blind) matching repeats on every build — the regexes are compiled once per settings value; a few passes over a change's paths per build are microseconds at real file counts.
  - `[low]` `[patch]` (blind) spec'd behaviours without tests (Esc focus return, click outside, placement, operation view per-commit Show, funnel colours) — tests added for Esc focus return and the per-commit Show reset (shared with the verification-gap rows); click outside, placement and colours rejected: the host is the View options pattern, colours are not unit-tested in the app.
  - `[low]` `[patch]` (blind) operation-view row identifiers count in the shown files and move with Show or a mask — the identifier is the index in the commit's full file list.
  - `[low]` `[patch]` (edge) duplicate row keys — same root cause and fix as the blind row.
  - `[medium]` `[patch]` (edge) the operation view's popover vanishes mid-edit — same root cause and fix as the blind row.
  - `[low]` `[patch]` (edge) the popover overflows a short window — same fix as the blind row (graded with it, medium).
  - `[low]` `[reject]` (edge) a mask ending in `/` (`build/`) never matches — the spec's syntax names no folder masks; the popover shows the entry's count as empty, so the user sees it matches nothing; `build/**` does what was meant.
  - `[low]` `[patch]` (edge) a ticked entry with zero masks counts in the funnel — same root cause as the blind `,` row; the add refuses it and `_compile` skips the empty mask.
  - `[low]` `[patch]` (verification-gap) Hide never shown to move the focus off a hidden file — tests in both views: Show, focus the hidden file, Hide, focus on the next shown file.
  - `[low]` `[patch]` (verification-gap) the operation view's per-commit Show reset untested — two-commit test added.
  - `[low]` `[patch]` (verification-gap) the popover's match counts as the views feed them untested — the inspector popover test asserts the ticked entry's count.
  - `[low]` `[patch]` (verification-gap) the empty-list key guard and Esc's focus return untested — arrowDown on the all-hidden list and focus-after-Esc assertions added.
  - `[low]` `[patch]` (verification-gap, other) duplicate keys from a hand-edited file — same root cause and fix as the blind row.
  - `[false]` `[reject]` (intent) the epic's witnesses are judged in the running app, the tests use fakes — the intent leaves the running-app check (Marionette) to the console session; the backend verbs are unchanged.
  - `[low]` `[reject]` (intent) click outside, ↑ and the header pick-all over hidden files are untested — pick-all's code is unchanged and already reads every file (AC1 commits with no paths after all, hidden included, are picked); ↑ uses the same rows as ↓.
  - `[low]` `[reject]` (intent) the study's header label "Pick all, hidden files included" is not adopted — cosmetic; the existing Select all label stays true, and the hint row names the hidden files' own box.
  - `[false]` `[reject]` (intent) the funnel sits after the viewed counter, not right after the file count — the viewed counter stands between the count and the switch; the funnel is between them as the epic says.
  - `[false]` `[reject]` (intent) the operation view has no funnel — the epic's item 5 gives the operation view only the hint row.
  - `[low]` `[reject]` (intent) the Auto Run Result, verification outcomes and deferred mirroring are not yet in the spec — written at finalization, as the workflow orders.

### 2026-11-17 — Review pass (follow-up)
- verdicts: 29 findings — high 0, medium 0, low 26, false 3, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind) the Viewed counter counts hidden files, so viewing every shown file never reads "All viewed" — the intent keeps Viewed counts and `markAll` on every file; changing that edits the intent; Show or Mark all viewed reaches it.
  - `[low]` `[reject]` (blind) a mask ending in `/` passes `usable` but never matches — carried: the code still reads as the first pass's edge row (no folder masks in the syntax; the popover shows no count; `build/**` works).
  - `[low]` `[reject]` (blind) the hint text and the masked row's label join translated pieces — the app ships one locale (`app_en.arb` only); a translator's word order is not met today.
  - `[low]` `[reject]` (blind) the hint box's label stays "Pick the N hidden files" while all are picked — the intent fixes that label; changing it edits the intent.
  - `[false]` `[reject]` (blind) the operation view has no funnel, so a first mask cannot be added there — carried: the intent gives the operation view only the hint row.
  - `[low]` `[reject]` (blind) ↩ with unusable text (`,`, `/`) clears the field silently — only text of separators alone; nobody types that as a mask, and keeping it needs a new branch in `_add`.
  - `[low]` `[reject]` (blind) masks are evaluated per build, and the operation view's `indexOf` per row is O(n²) — carried: the regexes compile once per settings value; a pass over a commit's paths per build is microseconds at real file counts.
  - `[low]` `[reject]` (blind) toggle and remove use the list index, not the entry — carried: the popover rebuilds on every store change.
  - `[low]` `[reject]` (blind) `?` and `*` work on UTF-16 code units — a `?` mask over an emoji file name is not met in practice; the fix needs a rune-based pattern builder, not just `unicode: true`.
  - `[low]` `[patch]` (blind) promised behaviours without tests (root-only `/pubspec.lock`, `**` inside a name, trailing `/`, header pick-all, folder box, Viewed, click outside) — matcher tests added for `/pubspec.lock` (root only) and `a**b` / `src/a**b` (`file_masks_test.dart`); trailing `/`, header pick-all and click outside carried as rejected; Viewed per the Viewed row above; the folder box is covered by the tree test's `InspectorFolderRow` assertion.
  - `[false]` `[reject]` (blind) the story is done before the running-app check, and deferred-work keeps no open entry for it — the intent's Never list leaves the Marionette check and the DS publish to the console session; the spec's residual risks name both.
  - `[low]` `[reject]` (blind) a failed mask write is swallowed with no log — the intent says "a failed write is swallowed like `setFileList`", which logs nothing either.
  - `[low]` `[patch]` (blind) `GeneralSettings.fileMasks` is documented as "the inspector's" though the operation view reads it too — doc comment now names both views; `general_settings.freezed.dart` regenerated with `build_runner`.
  - `[low]` `[patch]` (edge) inspector: after every file was hidden, Show or an unticked mask lists the rows again with no focus and no diff — `_focusShown` now focuses the first shown file when the focus is empty (`graph_inspector.dart`); the "else none" test goes on with Show → `a.g.dart` focused and its diff shown, Hide → none.
  - `[low]` `[patch]` (edge) the same in the operation view — same root cause and fix (`operation_changes.dart`); the "newly masked focused file" test ends with Show → `a.txt`'s diff.
  - `[low]` `[reject]` (edge) a mask ending in `/` matches nothing — carried (see the blind row).
  - `[low]` `[reject]` (edge) a hand-edited untrimmed entry is doubled by a re-add — the app writes trimmed text; only a hand edit with stray spaces meets it, and the result is a visible, harmless duplicate.
  - `[low]` `[reject]` (edge) a jj config write while the operation view's popover is open unmounts it (`_read` sets `_files = null`) — the popover consumes outside taps, so this window cannot write config while it is open; a write from another window mid-edit is rare, and the fix (keep the old diff during a re-read) changes the pre-existing re-read flow.
  - `[low]` `[patch]` (verification-gap) Show and the focus on a shown hidden file are not pinned across a re-read of the same selection — tests added: a jj config write in the operation view (`operation_changes_test.dart`) and a reload of the same change in the inspector (`graph_inspector_test.dart`) keep Show on and the focus on the hidden file.
  - `[low]` `[reject]` (intent) the funnel glyph is 14, the spec says 13 — `ZanshinIcon` takes the DS icon-size tokens (10/12/14/16…); 13 has none, `md` is the nearest; a new token is more than a direct correction for 1 px.
  - `[low]` `[reject]` (intent) the popover's × is 12, the spec says 11 — same reason, `sm` is the nearest token.
  - `[low]` `[reject]` (intent) the operation view's popover anchors on the whole hint row, not on Masks… — the first pass chose it so the popover survives unticking the last hiding mask (Masks… leaves with the hint row); aligning under the button needs a second rect channel; the placement is left to the console session's check (residual risk).
  - `[false]` `[reject]` (intent) the invisible × stays clickable and in the semantics tree — a mouse click needs the pointer over the row, which shows the ×; keyboard focus shows it too; keeping it in semantics is what VoiceOver needs.
  - `[low]` `[reject]` (intent) DESIGN-SYSTEM-SYNC #32 calls the hint box "the only way to pick a hidden file" though pick-all picks them too — the design notes forbid editing sync entries (`design/CLAUDE.md`); the code and the hint row are right, the slip is prose only.
  - `[low]` `[reject]` (intent) the tests check the composer's paths, not a real jj run, and no test checks glyph sizes, popover placement, row geometry or the × on hover — carried: the first pass rejected placement, colours and the running-app witnesses (console session); the backend verbs are unchanged.
  - `[low]` `[reject]` (intent) the corrupt-file recovery is not tested for `fileMasks` — the store's recovery is generic and unchanged; `settings_store_test.dart` covers a malformed `fileMasks` value.
  - `[low]` `[reject]` (intent) the DS `FileRow` / CSS / bundle changes are checked only by the glyph parity test — the DS is an illustration; `node --check` passed; the visual check is the console session's.
  - `[low]` `[reject]` (intent) the DS `FileRow` shows the plain path in a masked rename's tooltip, the app `old → new` — DS illustration only; the app row is the one users meet (10.36/10.48 triage rule).
  - `[low]` `[reject]` (intent) `**/` has no folder boundary, so `foo**/bar` also matches `foobar` — nobody writes `foo**/bar`; a boundary check adds a branch to the pattern builder.

## Design Notes

The study's `**` rule (`**/?` → `(?:.*/)?`) makes `docs/**` match nothing below `docs/`; the spec keeps `**/` as "zero or more folders" and lets a lone `**` cross folders, which is IntelliJ's meaning. Hidden files leave only the rows: picks and the composer read every file, so ticking a mask can never drop a file from a commit unnoticed — the hint row shows their pick state and owns their checkbox. The Show flag is per change because the study calls it "for this change"; it is session state, never stored. Folder boxes cover only their shown files (the study builds the tree from the shown files); the hint row's box is the way to pick hidden ones.

## Verification

**Commands:**
- `flutter test` in `packages/zanshin_settings` and `packages/zanshin_ui` -- expected: pass (incl. `ds_parity_test`, `zanshin_icon_test`).
- `cargo make test-app test/features/graph test/features/undo_timeline test/features/settings test/widgetbook test/l10n` in `app` (or `flutter test` with the gate's env) -- expected: pass.
- `dart analyze` + `dart format --set-exit-if-changed lib test` (app also `widgetbook integration_test`) in each touched package -- expected: clean.
- `node --check` on `_ds_bundle.js` -- expected: passes.

**Manual checks (if no CLI):**
- Marionette vs the study §4 in Paper and Night: left to the console session.

**Checks run (targeted; the full gate is the story loop's):**
- `flutter test` in `packages/zanshin_settings` — 63 passed; in `packages/zanshin_ui` — 488 passed (incl. `ds_parity_test`, `zanshin_icon_test`); both before and after the review patches.
- `cargo make test-app test/features/graph test/features/undo_timeline test/features/settings test/widgetbook test/l10n` (repo root, the gate's pinned env) — 1870 passed before the review patches, 1877 after.
- `dart analyze` in `app`, `packages/zanshin_ui`, `packages/zanshin_settings` — no issues; `dart format --set-exit-if-changed` (`app`: lib test widgetbook integration_test; packages: lib test) — 0 changed.
- `node --check _ds_bundle.js` — passes.
- Not run: Rust checks (no Rust, FFI or schema change), `cargo make test` / `test-full` / `coverage` (this run's gate rule), Marionette (console session).

**Checks run in the follow-up review (targeted; same gate rule):**
- `dart run build_runner build` in `packages/zanshin_settings` — the doc comment reached `general_settings.freezed.dart`.
- `flutter test` in `packages/zanshin_settings` — 63 passed.
- `cargo make test-app test/features/graph test/features/undo_timeline test/features/settings test/widgetbook test/l10n` (repo root) — 1879 passed (1877 + 2 new tests).
- `dart analyze` in `app` and `packages/zanshin_settings` — no issues; `dart format --set-exit-if-changed` (`app`: lib test widgetbook integration_test; `zanshin_settings`: lib test) — 0 changed.
- Not run: Rust checks (no Rust change), the full gate (this run's gate rule), Marionette (console session).

## Auto Run Result

Status: done

**Summary.** Story 10.49 builds the approved Inspector Extras Study §4:
- **Storage.** `GeneralSettings.fileMasks` (`FileMask {mask, active}`), one app-wide list; a file without the key gets the two unticked seeds `*.g.dart, *.freezed.dart` and `*.lock`; an empty saved list stays empty.
- **Matcher.** `FileMaskMatcher` (Dart only): comma lists, name vs path (`/`), `**/` zero or more folders, a lone `**` crosses folders, `*` / `?` inside a name, anchored, case-sensitive; compiled once per settings value. Text without a usable mask (`,`, `/`) is not stored.
- **Inspector.** Masked rows leave the flat and tree lists (a folder of only hidden files disappears; ↑/↓ follow); the focus starts on the first shown file and moves off a file that gets hidden. Picks, pick-all, Viewed and the composer keep every file. Funnel before the flat/tree switch (accent + ticked count); popover with field ↩, ticks, match counts, × on hover/focus, scrolling list and syntax footer; hint row with the hidden files' pick box, "N files hidden · all/some/none picked", Show/Hide (per change; masked rows at .55 with eye-off) and Masks….
- **Operation view.** Hides by the same masks; hint row without a checkbox; Show per selected commit; Masks… opens the popover anchored on the hint row.
- **DS.** Glyphs `filter`, `eye-off`; FileRow `masked` (+ a masked row on the content card); bundle blocks; readme "Synced through #32"; DESIGN-SYSTEM-SYNC #32. Not published (console session).

**Deferred-work items.**
- **I1** (generated files crowd the inspector's file list; no way to hide them) — fixed in 1febd66de4a053e9683e05fa4a7fa54c5d512e92: app-wide IntelliJ-style masks with ticks, hidden files stay in the change, hint row with their pick state, Show and Masks….

**Files changed (1febd66d).**
- `packages/zanshin_settings/lib/src/model/general_settings.dart` (+ generated) — `FileMask`, `fileMasks`, `defaultFileMasks`; tests `app_settings_test.dart`, `settings_store_test.dart`.
- `app/lib/src/features/graph/file_masks.dart` (new) — matcher, mask edits on `SettingsStore`, funnel, hint row, popover and its anchor host.
- `app/lib/src/features/graph/graph_inspector.dart` — model (masks, shown files, Show, focus), files pane (shown rows, funnel, hint), `InspectorFileRow.masked`.
- `app/lib/src/features/undo_timeline/operation_changes.dart` — model and `_Files` (shown rows, hint without box, anchor).
- `app/lib/l10n/*` — the `fileMasks*` strings.
- `packages/zanshin_ui` — `filter.svg`, `eye-off.svg`, `ZI.filter`, `ZI.eyeOff`; parity test count.
- Tests: `app/test/features/graph/file_masks_test.dart` (new), `graph_inspector_test.dart` (group "Story 10.49"), `operation_changes_test.dart`; catalogue `app/widgetbook/folders/graph.dart` (Inspector › File masks).
- DS: `assets/icons/{glyphs.json,ui/filter.svg,ui/eye-off.svg}`, `components/brand/Icon.*`, `components/content/FileRow.*`, `content.css`, `content.card.html`, `_ds_bundle.js`, `readme.md`; `design/DESIGN-SYSTEM-SYNC.md` #32.
- Planning (docs commit): this spec, `epic-10-context.md`, `sprint-status.yaml`.

**Review.** One pass, 30 findings (high 0, medium 3, low 23, false 4):
- **Patched: 17 rows in 11 entries** (medium 2 — the popover's list could not scroll; the operation view's popover unmounted itself when the last hiding mask was unticked; low 9 — duplicate row keys, unusable entries, the masked rename tooltip, the DS card's masked row, operation-view row identifiers, and the missing tests for Hide's focus move, the per-commit Show reset, the popover's counts, the empty-list key guard and Esc's focus return).
- **Deferred: 0.**
- **Rejected: 13** (9 low, 4 false) — each reason in the Review Triage Log.
- **Follow-up review:** recommended (two medium entries patched). Unverified risk: the operation view's anchor is now the whole hint row (a zero-size box while nothing is hidden), so its popover sits under the hint row, not under Masks…; and the popover's scrolling layout was checked only in a widget test, not against the study.

**Residual risks.**
- Not checked in the running app or against the study and DS card (console session's Marionette check); the DS is not published.
- The extra masked row on the DS content card may not fit the card's viewport in `_ds_manifest.json`.
- A mask ending in `/` (`build/`) matches nothing (the popover shows no count); `build/**` is the working form.
- The operation view offers the popover only while a ticked mask hides a file of the shown commit (no funnel there, as the epic scopes it).
- No test for the masked-rename tooltip.

### Follow-up review (2026-11-17)

**Summary.** A fresh review of the whole change (four layers, 29 findings). One behaviour fix: when every file of a change or commit was hidden and Show or an unticked mask lists files again, the first shown file now takes the focus and its diff shows (both views' `_focusShown`). The rest is tests and a doc comment.

**Files changed.**
- `app/lib/src/features/graph/graph_inspector.dart` — `_focusShown` focuses the first shown file when the focus is empty.
- `app/lib/src/features/undo_timeline/operation_changes.dart` — the same in `OperationChangesModel._focusShown`.
- `packages/zanshin_settings/lib/src/model/general_settings.dart` (+ `general_settings.freezed.dart`) — the `fileMasks` doc names both views.
- `app/test/features/graph/graph_inspector_test.dart` — Show after all hidden focuses the first file; a reload of the same change keeps Show and the focus on a hidden file.
- `app/test/features/undo_timeline/operation_changes_test.dart` — Show after all hidden shows the first file's diff; a jj config write keeps Show and the focus.
- `app/test/features/graph/file_masks_test.dart` — root-only `/pubspec.lock`; `**` inside a name.

**Review.** 29 findings (high 0, medium 0, low 26, false 3):
- **Patched: 5 rows in 4 entries, all low** — the empty focus after all files were hidden (both views), the re-read tests for Show and focus, the matcher tests, the `fileMasks` doc comment.
- **Deferred: 0.**
- **Rejected: 24** (21 low, 3 false) — each reason in the follow-up triage entry; 6 of them carried from the first pass.
- **Follow-up review:** not recommended — this follow-up pass patched no high finding; the work has converged.

**Residual risks.**
- Still not checked in the running app or against the study and the DS card (console session); the DS is not published.
- The operation view's popover opens under the hint row's left edge, not under Masks…; the funnel and × glyphs use the nearest DS icon tokens (14 and 12, not 13 and 11).
- DESIGN-SYSTEM-SYNC #32 says the hint box is "the only way to pick a hidden file"; pick-all picks them too. Sync entries are never edited, so the DS side should read the code, not that phrase.
