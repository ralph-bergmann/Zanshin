---
title: 'Graph search DS check fixes (2026-11-01)'
type: 'bugfix'
created: '2026-11-01'
status: 'done'
baseline_revision: '08be1816b8402309cfc0a0a4000e193ddb863787'
review_loop_iteration: 0
followup_review_recommended: false
context: ['{project-root}/_bmad-output/project-context.md']
warnings: ['oversized']
deferred:
  - summary: >-
      The search's counts and lookups need a layout with an operation id; the production layout 10.12 adopts must carry the topology's.
    evidence: |-
      GraphSearchController.wantCounts/lookup/countOf return early on a null operationId; RecordedGraphLayout is the only GraphLayout in app/lib and RepoGraphSource takes its layout from outside until 10.12, so the production path cannot be checked yet.
    location: >-
      app/lib/src/features/graph/graph_search_controller.dart:241
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** The visual check of Story 10.21's graph search in the catalogue (`graph/floating-shell/controls`, night) against the DS cards found four deviations: (1) the suggestions popover and the search menu always take their max height; (2) filter rows never show their "N changes" count in the catalogue; (3) change rows show only the author's first name, without the relative date; (4) author rows draw the `ZI.user` glyph instead of the DS initial avatar (and the "Authors containing" row's rule needed checking).

**Approach:** Fix each at its cause: `ZsScrollArea` sizes like its scrollable (not to its max); the catalogue's recorded layouts carry an operation id (the counts and lookups are pinned to one); change rows add `graphRelativeDate` after the first name; author rows get an initial avatar through a new `leading` slot on `ZsFieldListRow`.

## Boundaries & Constraints

**Always:** Follow the DS (search.css, SearchPopover.jsx, search-suggestions.card.html) where DS and epics.md disagree, and note it. Reuse `graphRelativeDate` (graph_card.dart). Each item gets a test.

**Never:** No other search changes; Story 10.21's spec is not touched. No new date formatter. No full gate (`cargo make test`/`test-full`/`coverage`) — targeted checks only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| One suggestion | popover with one row | popover height = row + footer, below max | — |
| Many suggestions | rows beyond max | popover at max, list scrolls | — |
| Tight parent | `ZsScrollArea` under tight constraints | fills as before | — |
| Change row, no timestamp | `timestampMs == null` | first name only | — |
| Change row, no author | `authorName` empty, ts set | relative date only | — |
| Author scope, exactly one match | `a:ch` → "Charlie Davis" | no "Authors containing" row (design prototype rule `G.author.length !== 1`) | — |
| Author scope, two matches | `a:li` → Alice, Charlie Davis | both + "Authors containing “li”" | — |

</intent-contract>

## Code Map

- `packages/zanshin_ui/lib/src/controls/zs_scroll_area.dart:281-329` -- the `Stack` has only `Positioned` children (`Positioned.fill` content + bars), so it sizes to the biggest constraint: the cause of item 1 (both popover and menu go through `_scrolling` → `Flexible` → `ZsScrollArea` under a loose `maxHeight`). `:275` hover uses `box.biggest` for the gutter.
- `packages/zanshin_ui/lib/src/controls/zs_field_list.dart:130-259` -- `ZsFieldListRow`; `icon` is a `ZI` glyph only, drawn in a 20 px column with `look.icon` color.
- `app/lib/src/features/graph/graph_search_field.dart:776-814` -- overlay `maxHeight`, `_scrolling`; `:1063-1100` change-row meta (`authorName.split(' ').first`); `:1110-1122` author/contains rows (`icon = ZI.user`); `:1161` `countOf`.
- `app/lib/src/features/graph/graph_search_controller.dart:241-263` -- `countOf`/`wantCounts` return early when `model.layout?.operationId == null`; `lookup`/`finds` too.
- `app/lib/src/features/graph/recorded_graph_layout.dart:136-280` -- `RecordedGraphLayout.fromSpec` never sets `operationId` → every catalogue layout has none: the cause of item 2. Production layouts carry the worker topology's op (`packages/zanshin_core/lib/src/ffi/commit_views.dart:373`), so production is not affected.
- `app/widgetbook/folders/graph.dart:234-258` -- `recordedLayout`/`requestedLayout`, the fixtures the Controls demo's `FakeGraphSource` and `FakeGraphSearchSource` answer.
- `app/lib/src/features/graph/graph_card.dart:341` -- `graphRelativeDate(strings, ts, nowMs:, utcOffsetMinutes:)`; `GraphViewModel.now` (`graph_view_model.dart:289`), `GraphLayout.utcOffsetMinutes`.
- `app/lib/src/features/graph/graph_search_index.dart:450` -- contains-row rule `scope == author && rows.length != 1`, identical to the design prototype `design/graph-search.jsx:137`.
- DS: `design_system/components/search/search.css:73-74` (`.zs-gs-av`: 18 px circle, `--fs-xs` 600, `--text-muted` on `--fl-on`; keyboard row: `--accent-text`, transparent, inset 1 px `--accent-ring`).
- Tests: `app/test/features/graph/graph_search_field_test.dart`, `packages/zanshin_ui/test/` (scroll area / field list), `app/test/widgetbook/`.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/controls/zs_scroll_area.dart` -- make the content a non-positioned Stack child with `fit: StackFit.passthrough` (tight → fills as before, loose → hugs its scrollable); gutter hover reads the laid-out size -- item 1 at its cause.
- `packages/zanshin_ui/lib/src/controls/zs_field_list.dart` -- add a `Widget? leading` slot (the caller knows `active`) drawn in the icon column instead of `icon` -- item 4 avatar.
- `app/lib/src/features/graph/recorded_graph_layout.dart` -- `fromSpec` takes an optional `operationId` -- item 2.
- `app/widgetbook/folders/graph.dart` -- `recordedLayout`/`requestedLayout` pass one fixed catalogue operation id -- item 2.
- `app/lib/src/features/graph/graph_search_field.dart` -- change rows: "First · 2d" via `graphRelativeDate` (item 3); author rows: a private initial avatar per DS css (item 4).
- Tests: zanshin_ui test that `ZsScrollArea` over a short `SingleChildScrollView` under loose constraints is as tall as its content and fills under tight ones; field test that a one-row popover is shorter than its max; field test for the change-row date and the author avatar initial; a catalogue/widgetbook test that `requestedLayout` carries an operation id (or that the Controls demo's author row shows a count).

**Acceptance Criteria:**
- Given the search field with one suggestion row, when the popover opens, then its height is less than `min(window*.66, 560)`; the menu likewise ends after "Edit Configurations…".
- Given the catalogue Controls demo, when typing an author, then the author row shows "N changes" after the fake's latency.
- Given a change row with author "Lena Moreau" and a timestamp 2 days old, then its meta reads "Lena · 2d".
- Given an author row "Charlie Davis", then its icon column shows the initial "C" in an 18 px circle (accent text + ring on the keyboard row).

## Spec Change Log

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 25 findings — high 0, medium 1, low 14, false 10, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind) change-row byline has no spoken form for VoiceOver — the row reads its text ("Lena · 2d") as before it read "Lena"; a spoken variant adds a semantics branch for a cosmetic gain.
  - `[low]` `[reject]` (blind) relative date can go stale while the popover stays open — popovers are short-lived and redraw on every keystroke/model change; listening to `now` adds a builder for a minute-granularity drift.
  - `[false]` `[reject]` (blind) missing layout falls back to UTC — change rows only exist with a layout (the index is built from it; found changes need its operation), so `?? 0` never applies to a shown row.
  - `[false]` `[reject]` (blind) avatar initial not uppercased / empty — DS `SearchAvatar` takes `slice(0,1)` without uppercasing; author rows come only from non-empty `authorName` (`graph_search_index.dart:127`), and the row text is the name, not the query.
  - `[low]` `[patch]` (blind) resting avatar look untested — grouped with the verification-gap row below; test added.
  - `[low]` `[reject]` (blind) height thresholds are loose (`< 560` / `< 640`) — they fail on the reported symptom (popover/menu at exactly max); a tighter geometry assertion is polish.
  - `[false]` `[reject]` (blind) other `ZsScrollArea` callers may now shrink — `pinned_panel`/`graph_inspector` sit in `Expanded` (tight), `projects_tree` wraps a `CustomScrollView` (fills); shell/projects/graph suites pass.
  - `[low]` `[reject]` (blind) no hover test of the gutter on a shrunk area — every caller has a tight width (the popover's `Positioned(width:)`), so `context.size` and the old `box.biggest` agree on the vertical gutter.
  - `[false]` `[reject]` (blind) `leading` ignores danger/shown/disabled — `shown`'s check is drawn independently, no caller combines `leading` with `danger`; the doc says it styles itself.
  - `[false]` `[reject]` (blind) `recordedLayout` op untested — `requestedLayout` without stacks returns `recordedLayout(...)`, which the catalogue test asserts.
  - `[false]` `[reject]` (blind) spec missing from the patch — by design the spec goes only to the edge-case layer.
  - `[low]` `[reject]` (edge) whitespace-led author name gives an empty first token — pre-existing (`split(' ').first` unchanged), jj names are trimmed in practice.
  - `[low]` `[reject]` (edge) stale `now` — duplicate of the blind row above.
  - `[false]` `[reject]` (edge) `now == 0` before init makes every row "now" — the model's `now` is set in `init`, and no layout (hence no change row) exists before `init`'s first request.
  - `[false]` `[reject]` (edge) empty author text gives an empty circle — authors are filtered to non-empty names.
  - `[low]` `[reject]` (edge) Recent author-filter rows keep the scope glyph — the brief names the typed Author rows; Recent rows draw the scope icon per the 10.21 design; changing them adds a branch.
  - `[false]` `[reject]` (edge) passthrough hugs the width under loose width — the popover's width is tight (`Positioned(width:)`), other callers tight.
  - `[low]` `[reject]` (edge) empty scrollable collapses the area to 0 — an empty suggestion list renders its empty text outside the area; a 0-height area paints nothing.
  - `[low]` `[reject]` (edge) menu test does not prove it ends after its last row — duplicate of the loose-threshold row.
  - `[low]` `[reject]` (edge) catalogue test checks the operation id, not a rendered count — the cause is pinned; the count rendering given an operation is covered by the existing field tests (`countCalls` with `op1`).
  - `[low]` `[patch]` (verification-gap) `_Avatar`'s resting style untested — added "two authors: the "Authors containing" row; a resting avatar is flOn without a ring" (`a:l`: contains row present, Ralph's avatar `flOn`, no border, `textMuted`).
  - `[low]` `[reject]` (verification-gap) gutter hover on a shrunk area untested — duplicate reasoning of the blind row (tight widths everywhere).
  - `[medium]` `[defer]` (intent) the spec's production claim cites `commit_views.dart:373`, which is evolog decoding; `RecordedGraphLayout` is the only `GraphLayout` and production has no layout builder until 10.12 — so the "production has the same flaw" branch is not yet reachable; deferred to 10.12 (deferred-work.md, "Surfaced in the graph-search DS check").
  - `[false]` `[reject]` (intent) menu has no dedicated test — false premise: "the menu ends after its last row, below its max height" exists.
  - `[low]` `[reject]` (intent) meta style (tabular, `--text-dim`) not asserted — the byline reuses the existing `meta` style (`textDim` + `tabularFigures`, unchanged).

## Design Notes

- The brief said a 22 px avatar with the selected one "in moon"; DS search.css:73-74 says 18 px, `--fl-on` fill, keyboard row `--accent-text` with an inset `--accent-ring`. DS css wins.
- Contains row: the brief saw only "Charlie Davis" for `a:ch`. The design prototype's rule (`graph-search.jsx:137`, `G.author.length !== 1`) adds the contains row only when not exactly one name matches; the DS card shows the two-match case (`li`). The app already matches the design — no change, noted under Auto Run Result.

## Verification

**Commands:**
- `flutter test` in `packages/zanshin_ui` and `app` (touched tests + widgetbook tests) -- pass
- `dart analyze` and `dart format --set-exit-if-changed` on both packages -- clean

**Verification notes (run 2026-11-01; gate rule: no full gate):**
- `flutter test` (packages/zanshin_ui, all) — 437 passed.
- `flutter test test/features/graph test/widgetbook` (app) — 878 passed.
- `XDG_CONFIG_HOME=…/target/test-xdg-config flutter test test/features/shell test/features/projects` (app, the other `ZsScrollArea` callers) — 334 passed.
- `dart analyze` — no issues (app, zanshin_ui); `dart format --set-exit-if-changed` — 0 changed (both).
- Not run: `cargo make test` / `coverage` (gate rule); no Rust touched. No Marionette check in the running catalogue (unattended run).

## Auto Run Result

Status: done. Code commit `651b0f564a00e9a1c5da868a32a574618adbcd42`.

1. **Popover/menu always at max height — fixed** (651b0f56). Cause: `ZsScrollArea`'s `Stack` had only `Positioned` children and so took its biggest constraint; it now lays its content out as the one non-positioned child with `StackFit.passthrough` (fills tight, hugs loose), gutter hover reads the laid-out size. Tests: one-row popover `< 560`, menu `< 640`, scroll area hugs / caps-and-scrolls / fills.
2. **No counts in the catalogue — fixed** (651b0f56). Cause: `RecordedGraphLayout.fromSpec` never set `operationId`, so `wantCounts`/`lookup` returned early for every catalogue layout; `fromSpec` takes `operationId` and the catalogue fixtures pass `catalogueOperationId`. Production: no production layout builder exists until 10.12 (the spec's `commit_views.dart:373` pointer was evolog decoding, not a layout) — deferred to 10.12 in deferred-work.md. Test: catalogue smoke test asserts the op on `requestedLayout` with and without stacks.
3. **Change rows without the date — fixed** (651b0f56). "Lena · 2d" via the cards' `graphRelativeDate` (first name / date alone when the other is missing). Test included.
4. **Author avatar — fixed** (651b0f56); contains row — **no change, matches the design**. Avatar per DS search.css:73-74 (18 px, `--fl-on`, `--fs-xs` 600 `--text-muted`; keyboard row `--accent-text` + 1 px `--accent-ring`) through a new `ZsFieldListRow.leading` — the brief's "22 px … in moon" differs from the DS css; DS followed. The "Authors containing" row follows the design prototype's rule (`design/graph-search.jsx:137`: shown unless exactly one name matches); the DS card shows the two-match `li` case, epics.md has no rule — so `a:ch` (one match) correctly shows none. Tests: single-match avatar (active), two-match contains row + resting avatar.

Files changed: `zs_scroll_area.dart` (hugging), `zs_field_list.dart` (`leading`), `recorded_graph_layout.dart` (`operationId`), `widgetbook/folders/graph.dart` (fixture op), `graph_search_field.dart` (byline, `_Avatar`), tests in `zs_scroll_area_test.dart`, `zs_field_list_test.dart`, `graph_search_field_test.dart`, `catalogue_smoke_test.dart`.

Review: 25 findings — 1 patch (resting avatar test, low), 1 deferred (production layout op, medium unverified), 23 rejected (reasons in the triage log). Follow-up review recommended: false (patched: 0 high, 0 medium, 1 low).

Residual risks: not checked in the running catalogue with Marionette; the `ZsScrollArea` sizing change reaches every caller under loose constraints (all current callers are tight or fill).
