---
title: 'Story 10.46 — Ref names and the move picker'
type: 'feature'
created: '2026-11-16'
status: 'done'
baseline_revision: '0321a91178cae6d991dd25ee6bb9909c64e109b9'
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

**Problem:** The name sheet takes any text as a bookmark or tag name, so names git refuses fail only later at git export; and "Move existing here…" (bookmark and tag popovers) is a free-text field that does not show which refs exist, where they are, or whether the move goes backwards.

**Approach:** Build sections 6 and 7 of the approved `design/Refs Study.html`: the name field replaces characters git refuses with `_` and shows whole-name rule errors that disable Create; "Move existing here…" opens a picker sheet (autocomplete field, rows like the top search, a backwards/sideways pill from the backend's `dropActions` preview, the `--allow-backwards` switch, the live command, the published-tag warning). DS synced through #26 plus the Refs Study.

## Boundaries & Constraints

**Always:**
- **Name rules** in a new `app/lib/src/features/graph/graph_ref_name.dart`: `graphCleanRefName(String)` replaces every whitespace character, `~ ^ : ? * [ \`, U+0000–U+001F and U+007F with `_` (length-preserving, so the selection stays valid); `graphRefNameError(AppLocalizations, String)` returns the first failing rule or null for empty/valid text, in this order: a lone `@`; starts with `/`; ends with `/`; starts with `.`; ends with `.lock`; ends with `.`; contains `..`; contains `//`; contains `@{`. `@` elsewhere stays allowed (the story's default).
- **Name field** (`GraphNameSheet`): `GraphNameRequest` gains `refName` (default `true`); only "Move to…" (a revision) sets it `false` and keeps today's free field. With `refName`, the field applies a `TextInputFormatter` with `graphCleanRefName` (typing and paste take the same path); after any replacement a quiet note "Spaces and ~ ^ : ? * [ \ become _" shows under the field (`--fs-sm`, `textDim`) until the field is emptied; a rule error shows as the field's `error` (red edge + message, the note hidden) and disables the confirm button and ↩. Applies to every sheet using it: Create bookmark/tag here… (card menu, popovers), Rename… (bookmark popover and the Bookmarks view, `bookmark_list_view.dart`).
- **`ZsTextField.inputFormatters`** (`packages/zanshin_ui`): a pass-through to its single-line/multiline `TextField`; nothing else changes.
- **Sheet requests:** a `sealed class GraphSheetRequest` in `graph_card_menu.dart`; `GraphNameRequest` and a new `GraphMoveRequest({required bool tag})` extend it. The `ask` callbacks of `graphCardMenuEntries`, `graphBookmarkMenuEntries`, `graphTagMenuEntries` and `_RefMenuState` take `GraphSheetRequest`. "Move existing here…" in both popovers asks `GraphMoveRequest` (titles stay `nameSheetMoveHereTitle` / `nameSheetMoveTagHereTitle`). `_NameSheetHost` shows `GraphNameSheet` for a name request and `GraphMoveSheet` for a move request; it gets the popover's `read` (null for the card menu).
- **Move picker** `GraphMoveSheet` in a new `app/lib/src/features/graph/graph_move_sheet.dart`, a `ZsSheet` 500 wide: a mono `ZsTextField` (label and placeholder `nameSheetNameLabel` / `nameSheetTagNameLabel`) with a `ZsFieldListController`; below it a scrolling list (max 200 high) of `ZsFieldListRow`s; the keyboard row starts on the first row after every query change; a click makes a row the keyboard row; ↩ confirms.
  - Rows: the read's local rows (`LocalBookmark` kind) with a non-null target that is not this change's change id, in the read's order, filtered by a case-insensitive substring of the query. Each row: `ZI.bookmark` / `ZI.tag` icon, the mono name with the match bold-underlined (the search's highlight, made public as `graphSearchHighlight` in `graph_search_field.dart`), a pill for the direction (bookmarks only; warn colours `warn`/`warnBg`, tooltip "Moving it there needs --allow-backwards") and the faint "now on <id> <subject>" (`<id>` = `graphShortId` when the target is in the layout, else its first 8 characters; the subject from content when known, else nothing).
  - Read pending: "Reading bookmarks…" / "Reading tags…"; failed: the popover's failure text; nothing to move: `moveSheetNothing` ("No bookmark to move" / "No tag to move" via `select`); no match: `bookmarksNoMatch(q)` / `tagsNoMatch(q)`.
  - Bookmarks: a `ZsSwitch` "Allow moving backwards or sideways" with the mono `--allow-backwards` beside it; the picked row's check (below) decides: refused → the refusal (context ?? code) in `rem` beside the buttons, Move off; backwards/sideways while the switch is off → "This move goes <direction>: turn on the switch to allow it." in warn, Move off; check pending → Move off; no check (no drops) → Move on.
  - Tags: under the list the note "A tag that already exists moves only with --allow-move."; when the picked tag has a remote row (not `git`) with a target, instead the warning "<name> is on <remote> — moving it changes a published tag. Anyone who fetched it keeps the old one; your next push of the tag moves it on <remote> too." in warn (first such remote).
  - The command line under the list (mono, `textMuted`): `GraphBookmarkMove([name], to: short, allowBackwards: needed && switch)` or `GraphTagSet([name], revision: short, allowMove: true)`; a blank line while nothing is picked. Confirm runs the same action with the node key through the model's runner, then closes.
- **Check** `graphBookmarkMoveCheck(GraphDrops drops, GraphLayout? layout, {name, from, to})` in `graph_card_menu.dart` (beside `_isAncestor`): one `dropActions(BookmarkDropSource(name), [DropLocation(onto: [to])])`; the `DropVerb.bookmarkMove` outcome → refused: `(direction: forward, refusal: context ?? code)`; not `allowBackwardsNeeded`: forward; else backwards when `to` is an ancestor of `from` in the layout (`_isAncestor`), sideways when both are in the layout and it is not, backwards when `from` is not in the layout (the flag's own word). A thrown call → null (unknown). The sheet asks it lazily per built row and caches it per name for the sheet's life.
- Strings in `app_en.arb` + `flutter gen-l10n` (output committed); jj's flags and commands stay literals marked `// l10n-ignore`. Zs controls and DS tokens only. The architecture test stays green (`graph` imports nothing from `bookmarks`).
- `test-fixtures/commands/card-menu.txt` gains `jj bookmark move b-mark --to kmnvxoqp --allow-backwards`; the card-menu fixture test builds the move-here commands from the picker's action builder.
- **DS** via `design-artifacts` (C, then F's sync line), no publish: a new card `components/menus/ref-sheets.card.html` (name field: replaced note, rule error; move picker: bookmark with a backwards row and the switch, tag with the published warning) from existing components/classes; `readme.md` Sync line (Refs Study sections 6–7 with Story 10.46); one dated line `- 2026-11-16 (Story 10.46) — …` at the end of `design/DESIGN-SYSTEM-SYNC.md`; register the card wherever the DS lists cards. Do not touch the study files.

**Never:**
- Rust, FFI or schema changes (the preview and verbs exist); changes to drag; tag search hits (10.47).
- Replacing `@` (the open design question keeps the default).
- A picker for "Move to…" (revision field) or the Bookmarks view (not in the story).
- Publishing the DS, the Marionette check (both for the console session).
- The full gate (`cargo make test` / `test-full` / `coverage`) — targeted checks only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Typed | `feature/my new:idea?` | field `feature/my_new_idea_`, note shows | — |
| Pasted | `fix/login ~ crash` | `fix/login___crash`, note shows | — |
| Rule | `release/1.5.` | error "Must not end with “.”", Create off, ↩ ignored | — |
| Lone @ | `@` | error "Must not be “@” alone" | `a@b` stays valid |
| Move to… | `@-` in the revision field | kept as typed, no note, no error | — |
| Picker filter | rows `feature/auth-flow`, `feature/onboarding/pager`, `main`; query `feat` | two rows, "feat" highlighted, "now on …" | read pending/failed → reading/failure row |
| Backwards | picked row needs `--allow-backwards`, `to` ancestor of `from` | pill "backwards"; Move off with the reason; switch on → `jj bookmark move <n> --to <id> --allow-backwards` | refused → reason, Move off |
| Tag on origin | `v1.5.0-rc1` with an origin row | warning; runs `jj tag set v1.5.0-rc1 -r <key> --allow-move` | local-only tag → the `--allow-move` note |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_card_menu.dart` -- `GraphNameRequest` `:42` (add `refName`, extend the sealed base), `_isAncestor` `:61`, `graphCardMenuEntries` `ask` `:120`, bookmark popover rows `:306-474` (Move to… `:386-397` sets `refName: false`; Move existing here… `:461-472`), tag popover `:482-618` (Move existing here… `:605-616`), `_NameSheetHost` `:826-883` (switch on the request; pass `read`, `model.drag.drops`, layout/content), `_RefMenuState`/`_RefMenuHost` `:1048-1156`, `GraphNameSheet` `:1161-1286` (formatter, note, error, confirm gating).
- `app/lib/src/features/bookmarks/bookmark_list_view.dart:182-197` -- Rename… sheet (gets the rules through `GraphNameSheet`; no change expected).
- `app/lib/src/features/graph/graph_drag.dart:230-305` -- how a `DropActions` bookmark outcome is read (`allowBackwardsNeeded`, refusal context ?? code); `GraphDrops` port `graph_ports.dart:1150-1165`; `GraphViewModel.drag.drops` (`graph_view_model.dart:311`).
- `packages/zanshin_core/lib/src/ffi/drop_actions.dart` -- `BookmarkDropSource`, `DropLocation`, `DropVerb.bookmarkMove`, `ActionStatus`, `ActionOutcome`.
- `app/lib/src/features/graph/graph_search_field.dart:1455-1491` -- `_highlight` (make public `graphSearchHighlight`, replace its call sites), `_Tag` `:1617` (the pill pattern), `_suggestionRow` `:1179-1356` (row layout).
- `packages/zanshin_ui/lib/src/controls/zs_text_field.dart:300-370,493-510` -- add `inputFormatters`; `zs_field_list.dart` (`ZsFieldListController.attach`, `ZsFieldListRow`); `zs_switch.dart:35`.
- `app/lib/src/features/graph/graph_ports.dart:503-566,657-715` -- `GraphBookmarkMove` (`allowBackwards`), `GraphTagSet` (`allowMove`) commands.
- `app/lib/src/features/bookmarks/bookmark_list_model.dart:89` -- `tagRow` (tag rows are `Bookmark`-shaped; target = change id).
- `app/lib/l10n/app_en.arb:1620-1680` -- name-sheet and popover strings (add the rule, note, picker strings).
- Tests: `app/test/features/graph/graph_card_menu_test.dart` (`ask` typed `GraphNameRequest` `:110,142,159-178,377,514,572,628-659`; tag Move existing here… test `:627-637`; fixture test `:647-673`; "in the graph" sheet tests `:1020-1090`), `app/test/features/bookmarks/` (rename sheet), `app/test/architecture/layers_test.dart`, `packages/zanshin_ui/test/controls/` (text field tests).
- Widgetbook: `app/widgetbook/folders/graph.dart` -- add use cases: name sheet (replaced note, rule error) and the move picker (bookmark, tag).
- DS: `_bmad-output/implementation-artifacts/design_system/components/menus/` (card pattern: `card-menu.card.html`), `components/forms/TextField.jsx` (has `message` and `error` already), `components/search/search.css` (row classes), `readme.md:22-24`, `_ds_manifest.json` (card list, if it lists cards); `design/DESIGN-SYSTEM-SYNC.md` (append). Reference only: `design/refs-study.jsx:331-432`, `design/refs-study.css:102-115`.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/controls/zs_text_field.dart` -- `inputFormatters` pass-through -- a widget test that a formatter rewrites entered text.
- `app/lib/src/features/graph/graph_ref_name.dart` -- `graphCleanRefName`, `graphRefNameError` -- unit tests for every rule, the witnesses, `@` inside a name, control characters.
- `app/lib/src/features/graph/graph_card_menu.dart` -- sealed request, `refName`, name-sheet formatter/note/error/gating, `GraphMoveRequest` for both Move existing here…, host switch, `graphBookmarkMoveCheck` -- tests: entries ask a `GraphMoveRequest` (bookmark and tag); the check over a fake `GraphDrops` and a recorded layout (forward, backwards, sideways, unknown `from`, refused, thrown); sheet witnesses (typed, pasted via the clipboard and ⌘V, `release/1.5.`, lone `@`, Move to… untouched).
- `app/lib/src/features/graph/graph_move_sheet.dart` -- the picker -- widget tests: "feat" filter rows with highlight and "now on"; reading/failed/empty/no-match rows; this change's own bookmark left out; backwards row blocks Move until the switch, then confirm runs `GraphBookmarkMove(…, allowBackwards: true)` with the key; refused row shows the reason; tag picker shows the note or the published warning and runs `GraphTagSet(…, allowMove: true)`; ↑/↓/↩ drive the rows.
- `app/lib/src/features/graph/graph_search_field.dart` -- `graphSearchHighlight` public -- existing search tests stay green.
- `app/lib/l10n/app_en.arb` + `flutter gen-l10n`; `test-fixtures/commands/card-menu.txt` + its test; widgetbook use cases.
- DS card, readme Sync line, DESIGN-SYSTEM-SYNC line.

**Acceptance Criteria:**
- Given the Create bookmark here… sheet, when `feature/my new:idea?` is typed, then the field shows `feature/my_new_idea_` with the note; when `fix/login ~ crash` is pasted, then `fix/login___crash`; when `release/1.5.` is typed, then "Must not end with “.”" shows and Create stays disabled.
- Given the bookmark popover's "Move existing here…", when "feat" is typed, then only the matching bookmarks list, each with its current change; a backwards one needs the switch and then runs `jj bookmark move <name> --to <id> --allow-backwards`.
- Given the tag popover's "Move existing here…" and `v1.5.0-rc1` on origin, when it is picked, then the published-tag warning shows and Move runs `jj tag set v1.5.0-rc1 -r <id> --allow-move`.
- Given "Move to…", when a revision like `@-` is typed, then nothing is replaced and no rule applies.
- Given the architecture test, when it runs, then `graph` still imports nothing from `bookmarks`.

## Spec Change Log

## Review Triage Log

### 2026-11-16 — Review pass
- verdicts: 26 findings — high 0, medium 2, low 19, false 3, maybe-false 2
- findings:
  - `[medium]` `[patch]` (verification) The bookmark popover's "Move existing here…" is never opened through the real view and the view harness passes no `drops`, so a lost `model.drag.drops` or a wrong `read` would ship backwards moves without `--allow-backwards` unnoticed — patched: the view harness takes `drops`, and a view-level test opens the bookmark picker with a fake preview and checks the pill, the blocked Move, the switch and the `--allow-backwards` command.
  - `[low]` `[reject]` (intent) Rename… (popover, Bookmarks view) and Create tag here… are checked only as `refName == true` on the request — every one renders the same `GraphNameSheet`, whose behaviour the name-field widget tests drive; a per-sheet repeat adds tests, not coverage of new code.
  - `[medium]` `[patch]` (intent) The host's construction of the bookmark picker runs in no test — same root cause as the first row; same patch.
  - `[low]` `[reject]` (intent) The DS card adds `--allow-backwards` from the switch alone, the app only for a row that needs it — the card's demo row is a backwards move, so both show the same; the card is a demo.
  - `[low]` `[reject]` (blind) git's per-component rules (`a/.b`, `a.lock/b`) are not checked — the story lists exactly the whole-name rules; recorded in Design Notes; such names are rare and still meet jj's refusal toast; a new rule set is more than a direct correction.
  - `[low]` `[patch]` (blind) The cleaner's doc says "characters git refuses" while `\s` also takes Unicode whitespace git allows — doc comment reworded: any whitespace, stricter than git on purpose (the Refs Study's rule).
  - `[low]` `[reject]` (blind) A divergent or hidden target (layout key = commit id) misses the layout lookups: raw id, no subject, "backwards" for a sideways move, the other divergent copy's ref left out — divergent changes are rare; handling them adds commit-id lookups for a label.
  - `[low]` `[reject]` (blind) The published-tag warning shows for an untracked remote tag too — the story says "a tag that is on a remote shows the warning"; 10.45's popover counts any remote the same way.
  - `[low]` `[reject]` (blind) A failed preview leaves Move on without `--allow-backwards` — the spec's rule (unknown = no check, like no drops); a backwards move then meets jj's refusal toast; preview failures are rare.
  - `[low]` `[reject]` (blind) Esc can call `onCancel` twice (field-list detach and the sheet) — the host's `_close` only sets `_closing`, so a second call changes nothing.
  - `[low]` `[reject]` (blind) The Bookmarks view's Rename… has no test of its own — it renders `GraphNameSheet` with the default `refName`; the name-field tests cover the sheet.
  - `[low]` `[reject]` (blind) `graph_card_menu.dart` and `graph_move_sheet.dart` import each other — Dart allows it, both sit in `features/graph`, and the architecture test checks folders; moving the check means making `_isAncestor` public for no user-visible gain.
  - `[low]` `[patch]` (blind) The switch's visible text is not part of the control (a click does nothing; VoiceOver reads the label twice) — the text toggles the switch on tap and is excluded from semantics.
  - `[low]` `[reject]` (blind) The DS card shows the blocked reason under the switch, not in the footer, and lacks the refused and pending states — the card is a demo; the app follows the study (`gconf-ft`).
  - `[low]` `[patch]` (blind) The formatter sets `_replaced` without a rebuild, so an edit that leaves the text unchanged keeps the note hidden — the formatter now sets it through `setState`.
  - `[low]` `[reject]` (blind) Previews start from `build()` — bounded by the rows the 200-high list builds and cached per name for the sheet's life.
  - `[low]` `[reject]` (blind) The catalogue's picker shows no sideways, refused or pending state — the sheet tests drive them; the console session can check them in the app.
  - `[false]` `[reject]` (blind) Changed files are missing from the review diff — left out on purpose (generated l10n, a one-line manifest entry, the spec); `flutter gen-l10n`, analyze and the l10n tests ran green.
  - `[false]` `[reject]` (edge) A refused outcome with a null refusal enables Move — `ActionOutcome.refusal` is non-null exactly when the status is refused (`drop_actions.dart` doc).
  - `[low]` `[reject]` (edge) A failed preview enables Move without a warning — grouped with the failed-preview row above.
  - `[maybe-false]` `[reject]` (edge) A hung `dropActions` keeps Move off forever with an empty reason — a hung worker would stall every other read too; would be low if true.
  - `[low]` `[reject]` (edge) A sheet without `read` shows "Reading…" forever — the popovers show the same without a read (10.45's pattern); production always wires it.
  - `[low]` `[reject]` (edge) A path component starting with `.` or ending in `.lock` passes the field — same root cause and verdict as the blind per-component row.
  - `[low]` `[patch]` (edge) `_replaced` is set without a rebuild — same root cause as the blind note row; same patch.
  - `[maybe-false]` `[reject]` (edge) `toLowerCase` changing the UTF-16 length (`İ`) misplaces the highlight — whether such names occur in jj repos is unknown; cosmetic if true.
  - `[false]` `[reject]` (edge-claim) The spec claims names git refuses are blocked — the spec's Design Notes say the per-component rules still reach jj; the claim is not made.

## Design Notes

- **`@` inside a name — default taken, Ralph decides later:** `@` stays allowed; only `@{` and a lone `@` are errors (the story's default). In jj `name@remote` is a remote symbol, so such a name works only quoted; the app already refuses to drag such names. Decided (Ralph, 2026-11-16): keep `@` allowed.
- **Rules are the story's list, not all of git's:** git also refuses a path component starting with `.` or ending in `.lock` (`a/.b`, `a.lock/b`); those still reach jj and fail at export with jj's refusal toast. Stricter than the CLI by Ralph's 2026-11-15 decision.
- **Direction word:** the backend preview says only "not a fast-forward" (`allowBackwardsNeeded`); backwards vs sideways comes from the layout's ancestry (indirect edges keep ancestry through hidden commits). With the current target outside the layout the pill says "backwards", the flag's own word.
- **Titles stay** "Move a bookmark here" / "Move a tag here" (the study says "Move a bookmark to <id>"; the id is in the command line already) — Claude's proposal.
- **Own ref left out:** a ref already on this change is not offered (the move would change nothing).
- **Marionette and DS publish** against `design/Refs Study.html` sections 6–7 are left to the console session.

## Verification

**Commands:**
- `flutter gen-l10n` (in `app/`) -- output committed.
- `flutter test test/features/graph test/features/bookmarks test/features/home test/app/menu test/architecture test/l10n test/widgetbook` in `app/` -- expected: pass.
- `flutter test` in `packages/zanshin_ui` (controls + design) -- expected: pass.
- `dart analyze` and `dart format --set-exit-if-changed .` in `app/` and `packages/zanshin_ui` -- expected: clean.
- `cargo test -p zanshin-parity --test oracle card_menu` -- expected: the pinned jj accepts every fixture line, including the new `--allow-backwards` one.
- `node --check _bmad-output/implementation-artifacts/design_system/_ds_bundle.js` only if the bundle changes.

**Manual checks:**
- Marionette against `design/Refs Study.html` sections 6–7 and the DS publish — by the console session, not this run.

**Verification notes (2026-11-16, targeted checks per the story loop's gate rule):**
- `flutter gen-l10n` in `app/` — output committed.
- `flutter test test/features/graph test/features/bookmarks test/features/home test/app/menu test/architecture test/l10n test/widgetbook` in `app/` — 1766 pass; after the review patches 1768 pass, `dart analyze` and `dart format` clean again.
- `flutter test` in `packages/zanshin_ui` — 476 pass.
- `dart analyze` — no issues; `dart format --set-exit-if-changed .` — 0 changed (both `app/` and `packages/zanshin_ui`).
- `cargo test -p zanshin-parity --test oracle card_menu` — passes, including the new `--allow-backwards` line.
- `_ds_bundle.js` unchanged, so no `node --check`. Not run (gate rule): `cargo make test` / `test-full` / `coverage`. No Rust, FFI or schema change.
- Matrix audit: every row has a passing test (`graph_ref_name_test`, `graph_move_sheet_test`, `graph_card_menu_test` name-field group).

## Auto Run Result

Status: done

**Summary.** The name sheet for bookmark and tag names (Create bookmark/tag here…, Rename… in the popover and the Bookmarks view) cleans every edit: any whitespace, `~ ^ : ? * [ \` and control characters become `_` (typing and paste go through one `ZsTextField.inputFormatters` formatter), with the quiet note "Spaces and ~ ^ : ? * [ \ become _"; a broken whole-name rule (lone `@`, leading/trailing `/` or `.`, `.lock` ending, `..`, `//`, `@{`) is the field's error and turns Create and ↩ off. `@` elsewhere stays allowed (the story's default). Move to… (a revision) is untouched. "Move existing here…" in both popovers opens a picker (`GraphMoveSheet`): a filter field over the local refs (own change and target-less rows left out) with the match highlighted, "now on <id> <subject>", a backwards/sideways pill from the `dropActions` preview plus layout ancestry, the `--allow-backwards` switch (its text toggles it), the blocked reason, and the live command; tags show the `--allow-move` note or the published-tag warning and run `jj tag set <name> -r <id> --allow-move`. DS: a new card *Ref sheets*, not published.

**Files changed.**
- `app/lib/src/features/graph/graph_ref_name.dart` (new) — `graphCleanRefName`, `graphRefNameError`.
- `app/lib/src/features/graph/graph_move_sheet.dart` (new) — `GraphMoveSheet`, `graphMoveAction`.
- `app/lib/src/features/graph/graph_card_menu.dart` — sealed `GraphSheetRequest`, `GraphNameRequest.refName`, `GraphMoveRequest`, `graphBookmarkMoveCheck`, sheet host switch, name-field formatter/note/error.
- `app/lib/src/features/graph/graph_search_field.dart` — the highlight made public (`graphSearchHighlight`).
- `packages/zanshin_ui/lib/src/controls/zs_text_field.dart` — `inputFormatters`.
- `app/lib/l10n/*` — strings; `app/widgetbook/folders/graph.dart` — "Ref sheets" use cases.
- `test-fixtures/commands/card-menu.txt` — the `--allow-backwards` line.
- Tests: `graph_ref_name_test` (new), `graph_move_sheet_test` (new), `graph_card_menu_test`, `zs_text_field_test`.
- DS: `components/menus/ref-sheets.card.html` (new), `_ds_manifest.json`, `readme.md`; `design/DESIGN-SYSTEM-SYNC.md` line.

**Review.** 26 findings (high 0, medium 2, low 19, false 3, maybe-false 2). Patched: the bookmark picker through the real view with drops (medium, two rows, one root cause); the cleaner's doc wording; the switch text as part of the control; the note after an unchanged replacement (low). Deferred: none. Rejected: per-component git rules (low, outside the story's list, recorded), per-sheet tests for Rename/Create tag (low, same sheet), DS card flag wording (low, demo), divergent targets (low, rare), published warning for untracked tags (low, story wording), failed preview leaves Move on (low ×2, the spec's rule), double Esc cancel (low, harmless), Bookmarks view rename test (low, same sheet), mutual import of two graph files (low, same folder), DS card reason placement (low, demo), previews from build (low, bounded and cached), catalogue states (low), missing files in the review diff (false, on purpose), refused with null refusal (false, the type's contract), spec claim (false), hung preview (maybe-false, low if true), `İ` highlight (maybe-false, cosmetic).

**Follow-up review:** not recommended — this pass patched 0 high and 1 medium entry.

**Residual risks.** No visual check against the Refs Study and the DS card (the card was never rendered; Marionette and DS publish belong to the console session). The direction word is a layout guess when the ref's change is outside the layout. The full gate (incl. coverage) runs at the end of the story loop.
