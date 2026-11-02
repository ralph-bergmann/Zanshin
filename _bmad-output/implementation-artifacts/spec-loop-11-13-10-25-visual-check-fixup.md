---
title: 'Visual-check fix-up of the story loop 11.13 … 10.25: catalogue compile, card-menu width, hunk scroll bar, catalogue windows, undo current row'
type: 'bugfix'
created: '2026-11-02'
status: 'done'
baseline_revision: 'ecb1090e45765a10f541c6936a9b62d5f6bd7e48'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['multiple-goals']
deferred: []
---

<intent-contract>

## Intent

**Problem:** A Marionette check of the Widgetbook catalogue against the DS (2026-11-02) reported nine findings. Verified against the code: (1) `app/widgetbook/folders/graph.dart:895` still passes `commitId:` to `Diff` (now `commitIds`), so `dart analyze app` fails; (2) the card menu caps its commands at 170 and its panel at 320 (`graph_card_menu.dart:27`, `ZsMenuPanel.defaultMaxWidth`), so Revert's `jj revert -r <id> -B @` ends in "…" and "Squash into parent" sits tight against its command; (3) the unified hunk does scroll horizontally (`inspector_diff.dart:413`) but draws no scroll bar even while scrolling, so a cut line gives no hint; (5) the catalogue's Configurations demo has no project, so its preview never shows "N of M changes match"; (6) a catalogue window follows macOS's appearance, not the use case's Appearance addon, so it opens night over a paper use case; (7) the Undo Timeline's current row has no fill, where the prototype marks it (`design/float.css:175`, `.side-row.active{background:var(--accent-soft)}`).

**Approach:** (1) `commitIds: <String>[commitId]`. (2) `ZsMenuAnchor` gets a `maxWidth` (default the DS 320); the card and bookmark menus pass 360 and a command limit of 200. (3) The unified hunk's horizontal scroll view sits in a `ZsScrollArea` with a horizontal controller, which gives the DS overlay bar while scrolling or hovered and ←/→ keys. (5) The demo binds a `GraphMenuBinding` over the widgetbook's fake graph source and fake search source. (6) `_open` hands the use case's `ZsTheme` to `CatalogueWindowRoot`, which installs it as a `ZsAppearanceOverride`; `catalogueAppBuilder` takes the override's brightness for Material's theme mode. (7) The newest row's fill is `--accent-soft` (hover still `--fl-hover` over others).

## Boundaries & Constraints

**Always:** DS tokens for every colour; widget tests for each changed app/zanshin_ui widget behaviour; targeted checks only (gate rule of this run): `flutter test` / `dart analyze` / `dart format --set-exit-if-changed` per touched Dart package; check the changed views in the running catalogue (Marionette) before done.

**Never:** Rust/FFI/schema changes; the select-all mixed state (item 4, Story 10.26); a stale notice inside the panel (item 8); a header divider on the pinned panels (item 7); token value changes (item 9); side-by-side horizontal scrolling (DS clips side cells).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Card menu, 8-char id | Revert row `jj revert -r kxwsnptm -B @` | whole command shown, menu ≤ 360 wide | — |
| Card menu, long bookmark | command wider than 200 | ends in "…" | — |
| Other menus | no `maxWidth` passed | 250–320 as before | — |
| Unified hunk, long line | line wider than the hunk | overlay bar along the bottom while scrolling/hovered; ←/→ scroll when focused | — |
| Unified hunk, short lines | nothing to scroll | no bar, no Tab stop | — |
| Catalogue window | use case on paper, macOS dark | window opens paper | — |
| Configurations demo | default config `mine()`… | "N of M changes match" in the preview | — |
| Undo Timeline | newest row | `--accent-soft` fill | — |

</intent-contract>

## Code Map

- `app/widgetbook/folders/graph.dart:895` -- fake `diff`: `commitId:` → `commitIds: <String>[commitId]` (`Diff.commitIds` is `List<String>`, `packages/zanshin_core/lib/src/ffi/diff.dart:185`).
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart:190-216, 351-353` -- `ZsMenuAnchor` (`width`, `cmdMaxWidth`); add `maxWidth` beside `width`, used at :352 instead of `ZsMenuPanel.defaultMaxWidth`. Tests: `packages/zanshin_ui/test/controls/zs_menu_test.dart`.
- `app/lib/src/features/graph/graph_card_menu.dart:26-27, 596` -- `_cmdMaxWidth` 170 → 200, pass `maxWidth: 360` (one anchor serves card and bookmark menus). Tests: `app/test/features/graph/graph_card_menu_test.dart`.
- `app/lib/src/features/graph/inspector_diff.dart:353-461` -- `InspectorDiffHunk` (stateless) → stateful to own the controllers; `_unified` wraps its `SingleChildScrollView(horizontal)` in `ZsScrollArea(controller: <never attached>, horizontalController: h)`. `ZsScrollArea` tolerates an unattached vertical controller (`_scrolls`/`_jump` check `hasClients`, `zs_scroll_area.dart:176-198`). Tests: `app/test/features/graph/inspector_diff_test.dart`.
- `app/widgetbook/folders/windows.dart:168-194` (`_open`), `:57-99` (`CatalogueWindowRoot`), `:490-570` (`_DemoRevsetConfigsWindow`); `app/widgetbook/catalogue.dart:165-195` (`catalogueAppBuilder`). Fake sources: `app/widgetbook/graph/fake_graph_search_source.dart` (counts by hash), graph demo wiring to copy: `app/widgetbook/folders/graph.dart:646-700` (`FakeGraphSource`, `GraphPreferences(store)..init`, `GraphSearchController`). Test: `app/test/widgetbook/catalogue_windows_test.dart`.
- `app/lib/src/features/undo_timeline/undo_timeline_view.dart:233-237` -- row fill: `_newest ? colors.accentSoft : (_hovered && !inactive ? colors.flHover : null)`. Tests: `app/test/features/undo_timeline/undo_timeline_view_test.dart`.
- Read-only evidence for rejections: `planning-artifacts/epics.md:11721, :11795` (mixed and select-all three-state are 10.26); `design_system/ui_kits/desktop/kit.css:84` (`.zk-panel-hd` no border) and `:89` ("no boxes in boxes"); `design_system/components/overlays/StaleNotice.prompt.md:8` (one notice, top-centre over the graph; the project window shows it); `design_system/tokens/colors.css:64` = `zs_colors.dart:403` (`--hunk-bg` night `rgba(174,188,236,.14)`); `design_system/components/content/content.css:34` (side cells `overflow:hidden`).
- Ledger: `_bmad-output/implementation-artifacts/deferred-work.md:2550-2554` (item 1's bullet → RESOLVED), `spec-loop-11-13-10-25-leftovers.md` `deferred:` (add `resolved:`).

## Tasks & Acceptance

**Execution:**
- `app/widgetbook/folders/graph.dart` -- item 1.
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart` + test -- `maxWidth` param; a test that a row wider than 320 grows the panel up to the given `maxWidth`.
- `app/lib/src/features/graph/graph_card_menu.dart` + test -- 360 / 200; a test that Revert's command shows whole (no ellipsis: `TextPainter.didExceedMaxLines` or the rendered width) in the card menu.
- `app/lib/src/features/graph/inspector_diff.dart` + test -- hunk scroll area; test: a long line gives a `ZsScrollArea` whose horizontal controller has `maxScrollExtent > 0`, a short hunk none.
- `app/widgetbook/folders/windows.dart`, `app/widgetbook/catalogue.dart` + catalogue test -- items 5, 6.
- `app/lib/src/features/undo_timeline/undo_timeline_view.dart` + test -- item 7's fill.
- Ledger: strike item 1 in `deferred-work.md`, `resolved:` in the leftovers spec.

**Acceptance Criteria:**
- Given the catalogue, when `dart analyze` runs in `app/`, then it reports no errors.
- Given the floating-shell use case on night, when a card's menu opens, then Revert's command reads in full and every label keeps a gap of at least 10 to its command.
- Given a hunk with a line wider than the inspector, when the user scrolls it sideways or hovers its bottom edge, then the DS scroll bar shows along the hunk's bottom.
- Given the catalogue on paper, when the Configurations window opens, then it is paper and its preview shows "N of M changes match".
- Given the Undo Timeline panel, then its newest row has the `--accent-soft` fill.

## Spec Change Log

## Review Triage Log

### 2026-11-02 — Review pass
- verdicts: 19 findings — high 0, medium 3, low 12, false 4, maybe-false 0
- findings:
  - `[medium]` `[patch]` blind: a focused wide hunk swallows ↑/↓/Page/Space/Home/End (its vertical controller is unattached, `_handleKey` returned handled anyway), so the inspector stops scrolling — `_jump`/`_jumpTo` report whether they moved, `_handleKey` returns ignored otherwise; test in `zs_scroll_area_test.dart`.
  - `[low]` `[reject]` blind: every wide hunk becomes a Tab stop — the DS ScrollArea's rule (a scrolling viewport with nothing focusable is a Tab stop, r4out a11y KVS-1); the keyboard path to a cut line.
  - `[low]` `[reject]` blind: the hunk test checks the extent, not the bar or keys — keys are now tested in `zs_scroll_area_test.dart`, the bar is ZsScrollArea's own tested behaviour and was seen in the running catalogue.
  - `[low]` `[patch]` blind: `ZsMenuAnchor.width` doc still says 250–320; `maxWidth` unvalidated — doc reworded to "250 up to [maxWidth]"; validation rejected (the one caller passes 360).
  - `[low]` `[reject]` blind: the real-font test leaves Inter/JetBrains Mono loaded for later tests in the file — they pass; isolating it means a new test file for no observed failure.
  - `[false]` `[reject]` blind: `didExceedMaxLines` may miss an ellipsis — the menu's command `Text` has `maxLines: 1` (`zs_menu.dart` `_Row`), so it reports the overflow; the test fails at the old 170.
  - `[false]` `[reject]` blind: `_graph.value = null` in `dispose` notifies a torn-down subtree — children unmount first and the window removes its listener in its own dispose; the catalogue window tests open and close it cleanly.
  - `[low]` `[reject]` blind: the demo force-unwraps a recording key from `graph.dart` — catalogue-only; a renamed recording fails the catalogue window test at once.
  - `[low]` `[reject]` blind: the new catalogue test is timing-based and checks only "changes match" — it follows the file's existing pattern; the count was seen ("0 of 52") in the running catalogue.
  - `[low]` `[reject]` blind: the override now also sets Material's theme mode for the use cases themselves — they already took their Zs theme from the addon's override; Material now agrees with it.
  - `[low]` `[reject]` blind: `RecordedGraphLayout.fromSpec(totalCount:)` has no unit test — a one-line pass-through, exercised by the catalogue window test.
  - `[low]` `[reject]` blind: the newest-row fill is tested in night only — the token is per theme; paper was seen in the catalogue.
  - `[medium]` `[patch]` edge: same as the first row (swallowed vertical keys) — same fix.
  - `[medium]` `[patch]` edge: the spec's "tolerates an unattached controller" holds for no crash but not for key routing — same fix.
  - `[low]` `[reject]` edge: `maxWidth` below 250 gives min > max — no caller passes one; a guard adds surface for an impossible input today.
  - `[low]` `[reject]` edge: a catalogue window keeps the theme of the moment it opened — as it kept the shell theme before; reopening picks up the new one.
  - `[false]` `[reject]` edge: the newest row keeps an accent fill in an inactive window — the accent tokens turn grey in an inactive window (seen in the catalogue while the Configurations window was key).
  - `[false]` `[reject]` intent: the Bookmarks panel's current-row background is not addressed — the prototype's Bookmarks panel has no current-row fill (proto-bookmarks.png), only the divider, which is rejected per the DS kit.
  - `[low]` `[reject]` intent: "in <repo>" in the Configurations footer is neither added nor rejected — epics.md 10.22 and `app_en.arb:1223` say "N of M changes match"; the repo name is only in the DS card's sample text.
  - intent-alignment notes (descriptive): bookkeeping (Auto Run Result, ledger) and the Marionette check land in Finalize below.

## Design Notes

- Item 2: the DS menu's 320 fits its card-menu commands without ids (`jj revert -B @`); Story 10.15 shows full commands with the short id (`menus.css:6` vs `graph_card_menu.dart:124`), so the card menu needs more room. 360 fits Revert's 26 mono characters (≈172 px at 11 px) plus the longest label; the 200 limit still ellipsizes long bookmark names.
- Item 3: "no scroll" is false for unified (`SingleChildScrollView(scrollDirection: Axis.horizontal)`); the missing part is the hint. DS `.zs-diff-body{overflow:auto}` gives a browser bar; `ZsScrollArea` is the DS ScrollArea. Side by side clips per DS (`content.css:34`), rejected already in 10.24's review.
- Item 7: the DS kit's panel header has no divider (`kit.css:84`, and the inspector's neither, "no boxes in boxes" `:89`); the prototype's divider is the older `app.css:1171` rule — the DS wins. The current row's fill is the prototype's and the DS says nothing against it.

## Verification

**Commands:**
- `flutter test` in `packages/zanshin_ui` (menu, scroll area) and `app` (`test/features/graph`, `test/features/undo_timeline`, `test/widgetbook`) -- pass
- `dart analyze` and `dart format --set-exit-if-changed .` in `packages/zanshin_ui` and `app` -- clean

**Manual checks:**
- Running catalogue via Marionette: floating-shell controls (night) card menu; inspector unified hunk scrolled; Windows › Configurations window on paper; Undo Timeline panel.

## Auto Run Result

Status: done. Code commit `acdf36ed781d380b95c2732b194bed33d78a6afc` (incl. the two review patches); this spec and the ledger in the following commit.

**Items:**
1. **Fixed** (acdf36ed) — `app/widgetbook/folders/graph.dart` fake diff passes `commitIds: <String>[commitId]`; `dart analyze` in `app/` clean. deferred-work.md bullet struck RESOLVED, `resolved:` added in `spec-loop-11-13-10-25-leftovers.md`.
2. **Fixed** (acdf36ed) — `ZsMenuAnchor.maxWidth` (default the DS 320); the card and bookmark menus grow to 360 with commands up to 200, so Revert's `jj revert -r <id> -B @` reads in full (seen in the catalogue, night). The label-to-command gap is the DS's 10 (`menus.css:19`); "Squash into parent" sits at exactly that gap when its row is the widest — DS behaviour, not changed.
3. **Fixed in part, rest rejected** (acdf36ed) — "no scroll" was false for unified (it already scrolled sideways); the missing hint is fixed: the unified lines sit in a `ZsScrollArea`, which draws the DS overlay bar along the hunk while scrolling or hovered and scrolls on ←/→ (seen in the catalogue). Side by side keeps clipping: the DS clips side cells (`content.css:34`), as 10.24's review already decided.
4. **Rejected** — the select-all mixed state belongs to 10.26: epics.md 10.25 "Two states at file level; 'mixed' comes with 10.26" (:11721) and 10.26 "File checkboxes become three-state … and so does select-all" (:11795).
5. **Fixed** (acdf36ed) — the window shows "N of M changes match" whenever it has a project graph (`revset_configs_window.dart` `_previewBlock`); the catalogue demo had none. It now binds a `GraphMenuBinding` over the widgetbook's fake graph and search sources (`RecordedGraphLayout.fromSpec` gained `totalCount` for M); seen as "0 of 52 changes match" (the fake's hashed count). "in <repo>" is not added: epics.md and the app string say "N of M changes match".
6. **Fixed** (acdf36ed) — real, catalogue-only: a catalogue window followed macOS's appearance, not the use case's Appearance addon. `_open` hands the use case's theme to `CatalogueWindowRoot` (a `ZsAppearanceOverride`); `catalogueAppBuilder` takes its brightness for Material. The Configurations window opens paper over a paper use case under a dark macOS (seen, and tested).
7. **Fixed in part, rest rejected** (acdf36ed) — the Undo Timeline's newest row is filled `--accent-soft` (the prototype's `.side-row.active`, `design/float.css:175`). The header divider on both panels is rejected: the DS kit's panel header has none (`ui_kits/desktop/kit.css:84`; the inspector's neither, "no boxes in boxes" :89) and the DS wins over the older prototype rule (`design/app.css:1171`). The prototype's Bookmarks panel has no current-row fill.
8. **Rejected** — the StaleNotice is the window's one notice, top-centre over the graph (`StaleNotice.prompt.md:8`: not in a menu, not a toast), and the project window already shows it while stale; a second 44 px pill in a 300 px panel would duplicate it. The panel's line is the decision-16.28 placeholder.
9. **Rejected** — night `--hunk-bg` is `rgba(174,188,236,.14)` in both the DS (`tokens/colors.css:64`) and `zs_colors.dart:403`; the band is drawn as the DS draws it.

**Files changed:** `app/widgetbook/folders/graph.dart` (item 1); `packages/zanshin_ui/lib/src/controls/zs_menu.dart` + test (`maxWidth`); `app/lib/src/features/graph/graph_card_menu.dart` + test (360 / 200, real-font witness); `app/lib/src/features/graph/inspector_diff.dart` + test (hunk scroll area); `packages/zanshin_ui/lib/src/controls/zs_scroll_area.dart` + test (keys it cannot act on pass through — review patch); `app/widgetbook/folders/windows.dart`, `app/widgetbook/catalogue.dart`, `app/lib/src/features/graph/recorded_graph_layout.dart`, `app/test/widgetbook/catalogue_windows_test.dart` (items 5, 6; an existing assertion now expects the use case's night instead of macOS's paper); `app/lib/src/features/undo_timeline/undo_timeline_view.dart` + test (item 7); ledger `deferred-work.md`, `spec-loop-11-13-10-25-leftovers.md`.

**Review:** 19 findings — patched: medium 1 entry (swallowed keys; three rows), low 1 (menu doc); 0 deferred; 13 rejected with reasons in the triage log (4 of them false). No new deferrals, so no new deferred-work.md section. Follow-up review: not recommended (one medium entry patched, no high).

**Verification run (targeted, no full gate per the run's gate rule):**
- `packages/zanshin_ui`: `dart analyze` clean, `dart format --set-exit-if-changed .` clean, `flutter test` 441 passed (`test/controls` 245).
- `app`: `dart analyze` clean (the catalogue included), `dart format --set-exit-if-changed .` clean, `flutter test test/features/graph test/features/undo_timeline test/widgetbook` 1199 passed. The whole `flutter test` run: 1774 passed, 6 failed — all in `test/features/projects/worker_project_repos_test.dart` (real worker), failing with "XDG_CONFIG_HOME is not pinned to target/test-xdg-config — run via cargo make"; they need the gate's environment and fail the same on the stashed baseline.
- Running catalogue (Marionette, `flutter run -d macos -t widgetbook/main.dart`, frames via `ext.ui.window.scheduleFrame`): floating-shell controls on night — the hunk's bar shows along a cut line, the card menu of kxwsnptm shows Revert's command whole; Windows › Configurations window on paper — opens paper, "0 of 52 changes match"; Undo Timeline › Panel on paper — newest row filled. Catalogue stopped afterwards.

**Residual risks:** the demo's count is the fake's hash (here 0 for `jj log`), not a realistic number. The card menu is wider than the DS 320 by design. The full gate (coverage untouched: Dart-only change) runs at the loop's end.
