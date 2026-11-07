# Free Layout Without a Tear — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the Free layout's tear (DS `GraphBreak`) from app, prototype and DS. Shorten every card-free stretch
taller than 3 pitches to 1½ pitches without a mark, and keep its day and year labels. The stack card always shows its
period.

**Architecture:** The app keeps its one row mapping (`BackendGraphLayout` reads its rows through the cut map). The map
loses its break data and cuts from 3 pitches. Day axis, canvas and minimap lose every break path. The stack card gets a
short date form and a stricter yield rule. The DS and the prototype follow: both are edited in place, and the DS is
republished with the `design-artifacts` skill.

**Tech Stack:** Flutter/Dart (`app/`, `intl` `DateFormat`, flutter_test); the DS and the prototype in JSX + CSS;
Marionette MCP; `cargo make test`.

**Spec:** `docs/superpowers/specs/2026-11-07-graph-no-tear-design.md`

## Global Constraints

- **Cut rule.** A step between consecutive distinct node rows taller than `3 * unit` (48 units at U = 16) becomes
  `3 * unit ~/ 2` (24 units). Nothing marks it.
- **Stack dates.**
  - The full form when it fits, else the narrower of full and short, cut with "…" when even that does not fit.
  - The authors show only beside the full form.
  - Short forms: "Sep 2019 – May 2025" · "Apr – Dec 2025" · "Jun 3 – 24" · "Jun 3".
- **Unchanged:** `zanshin_core` and Compact.
- **Copy.** UI text is English. The range separator stays a hard-coded `'$from – $to'` with
  `// l10n-ignore: a range of two dates`, as `GraphStackData.dates` has it.
- **Tools.**
  - Read/Edit/Write for files.
  - jj only read-only (`--ignore-working-copy`, absolute `-R`) on Ralph's repos.
  - No bare `cd` (zoxide): `builtin cd` to absolute paths, and Flutter commands run from `app/`.
- **Commits.** None. Ralph is asked once at the end.
- **Done.** The Marionette check against the DS card, then `cargo make test` green from the repo root in the main
  session, unpiped.

## Review Focus

1. **The boundary.** A stretch of exactly 3 pitches (Free's longest real pause) stays as it is; one unit more is cut.
   Task 1, `graph_cuts_test`.
2. **A year boundary in a shortened stretch.** Its day label, divider and canvas year show, and the minimap lists the
   year. Task 1, `day_axis_test` and `layout_invariants_test`.
3. **A member without a time.** The short form reads the other member's time. No time at all: no date. Task 2,
   `shortDates` test.
4. **The range fills line 2.** No dates slot, no negative width, no exception. Task 2, the narrowest width of the sweep.
5. **The relative full form is narrower** than the short form ("6d – 2h" vs "Nov 1 – 7"). The narrower one wins.
   Task 2, the sweep assertion.

---

### Task 1: The tear is gone from the app; cuts start above 3 pitches

**Files:**
- Rename (`git mv`):
  - `app/lib/src/features/graph/graph_breaks.dart` → `graph_cuts.dart`
  - `app/test/features/graph/graph_breaks_test.dart` → `graph_cuts_test.dart`
- Modify, layout:
  - `app/lib/src/features/graph/backend_graph_layout.dart:45-50`
  - `app/lib/src/features/graph/graph_layout.dart:8,312`
  - `app/lib/src/features/graph/recorded_graph_layout.dart:49,266`
- Modify, drawing:
  - `app/lib/src/features/graph/day_axis.dart`
  - `app/lib/src/features/graph/graph_canvas.dart:1532-1550`
  - `app/lib/src/features/graph/graph_minimap.dart`: `MinimapLabels`, `minimapLabels`, lines 1217-1234 and 1274
- Modify, strings: `app/lib/l10n/app_en.arb:291-302`, then regenerate `app_localizations.dart` and
  `app_localizations_en.dart`.
- Modify, catalogue:
  - `app/widgetbook/graph/synthetic_layout.dart:6,23-25,181-195`
  - `app/widgetbook/folders/graph.dart:209-210` (comment)
- Test: `graph_cuts_test.dart`, `backend_graph_layout_test.dart:52-65`, `layout_invariants_test.dart:46-56`,
  `day_axis_test.dart:124-273`, `graph_minimap_test.dart`, and `graph_harness.dart` (delete `BrokenLayout`).

**Interfaces:**

- Produces `GraphCuts` in `graph_cuts.dart`:
  - `GraphCuts.compute(List<int> rawRows, int unit)`, a factory.
  - `static const none`.
  - `int map(int row)`, unchanged.
  - No `GraphBreak`, no `breaks`, no `timestampOf`.
- Produces `GraphAxisYear({required double y, required int year, int? below})`.
- Removed from `GraphDayAxis`: `breaks`, `droppedValues`, `droppedYs`. `canvasYears` keeps the years with a `below`.
- Removed elsewhere: `GraphDayAxisPainter.paintBreaks`, `MinimapLabels.breaks` and `.silent`, `GraphLayout.breaks`,
  `RecordedGraphLayout(breaks:)`, `graphBreakLabel`, `GraphAxisBreak` and `graphZigzag`.

- [ ] **Step 1: Write the failing tests.**

  **`graph_cuts_test.dart`.** Switch to `GraphCuts.compute(rows, 16)`, drop every `breaks`/time expectation and
  delete the test "the times: …". The new boundary test:
  ```dart
  test('a stretch of exactly 3 pitches stays; one unit more is cut to 1½ pitches', () {
    expect(GraphCuts.compute(const <int>[0, 48, 64], 16).map(64), 64);
    expect(GraphCuts.compute(const <int>[0, 49], 16).map(49), 24);
  });
  ```
  The other tests keep their mapped rows: `[0, 16, 40, 64, 80]`, `[0, 24, 40, 64, 80]`, and 8 / 23 / 24 / 40 / −1.
  "No cuts" becomes `expect(GraphCuts.compute(const <int>[], 16).map(7), 7)`.

  **`layout_invariants_test.dart`.** Rename the test to "the catalogue's long history: shortened like the worker's,
  every day and year labelled". On `syntheticLayout(1500, free: true, lanes: 6, longGapEvery: 75)` assert:
  - the invariants are empty;
  - every step between consecutive distinct `rowOf` values is ≤ 48, and at least one is 24;
  - `GraphDayAxis.of(layout, UniformRows(layout, GraphMetrics())).length == layout.bucketCount`;
  - its `canvasYears` are not empty.

  Drop the `syntheticLayout(10000, free: true).breaks` line.

  **`backend_graph_layout_test.dart`.** In `_expectMirrors`, use `cuts = GraphCuts.compute(g.nodeRows, g.unit)`
  (Free) / `GraphCuts.none`. Replace the `breaks` block (lines 55-65) with: in Free, every step between consecutive
  distinct `layout.rowOf` values is ≤ 48. Keep the `layout.rows` check.

  **`day_axis_test.dart`.**
  - Delete the group `graphBreakLabel (Story 10.31)`; its range cases move to Task 2.
  - Delete the testWidgets "the strip paints over the edges …".
  - Rename the group to `years (Story 10.31)`, drop `broken`, and replace "the band runs …" with a test on `inner`:
  ```dart
  test('a shortened stretch keeps its day and year: May 10 between the cards, 2025 at its label', () {
    final rows = UniformRows(inner, metrics);
    final axis = GraphDayAxis.of(inner, rows);
    expect(axis.values, <int>[day(2019, 8, 20), day(2019, 9, 1), day(2025, 5, 10), day(2025, 5, 12)]);
    expect(axis.guideYs, hasLength(3));
    expect(axis.guideYs[1], (rows.topOfRow(40) + rows.topOfRow(64) + h) / 2);
    expect(axis.years.map((y) => (y.year, y.below)), <(int, int?)>[(2019, null), (2025, 2019)]);
    expect(axis.canvasYears.single.y, axis.labelYs[2]);
  });
  ```

  **`graph_minimap_test.dart`.**
  - `_history` returns `inner` in both cases.
  - The test "Free: the year boundaries top-down, the breaks' centres; …" becomes "Free: the year boundaries top-down;
    Compact: …". It builds `free` with `handLayout` directly and loses the `labels.breaks`, `silent`, `may2`,
    "below the break" and `c.breaks` lines. Keep `minimapDayAt(labels, card) == day(at(2025, 5, 2))`.
  - Delete "the canvas paints a break's strip …".
  - In "the minimap over years and a break …", drop "and a break" and the zigzag expectation.

- [ ] **Step 2: Run them; they fail.**
  - `builtin cd /Users/ralph.bergmann/development/projects/privat/Zanshin/app`
  - `flutter test test/features/graph/graph_cuts_test.dart test/features/graph/layout_invariants_test.dart test/features/graph/day_axis_test.dart test/features/graph/graph_minimap_test.dart test/features/graph/backend_graph_layout_test.dart`
  - Expected: compile errors (`GraphCuts` is missing).

- [ ] **Step 3: Implement.**
  - **`GraphCuts`:** `limit = 3 * unit`, `target = 3 * unit ~/ 2`, without the time scan. Its doc says that only
    folded members leave a stretch taller than Free's longest real pause, and that nothing marks a cut (2026-11-07,
    Ralph: no tear).
  - **`BackendGraphLayout`:** `GraphCuts.compute(grid.nodeRows, unit)`.
  - **`day_axis.dart`:** every bucket adds its value, label y and (b > 0) divider. A year sits at its label y. Delete
    `bandAt` and every break path in `GraphDayAxis.of`, `paintLabels` and `dispose`. The doc comments lose the
    breaks; `colors` is "the token colours of the years".
  - **`graph_canvas.dart`:** drop `&& axis.axis.breaks.isEmpty` and the `paintBreaks` call with its comment.
  - **`graph_minimap.dart`:** Free labels are the axis days in ascending y. Delete the zigzag block and
    `labels.silent.contains(i) ||`.
  - **ARB:** delete `graphBreakYears/Months/Weeks/Days/Range/Label` with their `@` entries, then run
    `flutter gen-l10n` in `app/`.
  - **Synthetic layout:** `GraphCuts`, no `breaks:`. Its doc: "the rows come back shortened as the worker's layout
    shortens them ([GraphCuts])".
  - **Catalogue comment:** "nine years with a 400-day quiet stretch every 75 rows, each shortened to 1½ pitches with
    its day and year labels in it; a minimap sized by its columns and scrolled past its minimum density (DS card
    *Long history*)".
  - **Imports:** remove the ones the deletions orphan.

- [ ] **Step 4: Run the tests from Step 2; they pass.** Then run `dart analyze app` from the repo root: no issues.

---

### Task 2: The stack card always shows its period

**Files:**
- Modify: `app/lib/src/features/graph/graph_stack_card.dart` (`GraphStackData` 99-111, `performLayout` 537-583)
- Test: `app/test/features/graph/graph_stacks_test.dart`

**Interfaces:**
- Produces, top-level in `graph_stack_card.dart`:
  `String graphShortDateRange(AppLocalizations strings, int first, int second, {required int utcOffsetMinutes})`. It
  reads the pair oldest first, at the fixed offset. The rest of the old `graphBreakLabel` range becomes:
  - years differ: `yMMM – yMMM`;
  - months differ: `MMM – yMMM`;
  - days differ: `MMMd – d`;
  - one day: `MMMd`.
- Produces `String? GraphStackData.shortDates(AppLocalizations strings)`. It is `graphShortDateRange` of the oldest
  and newest member. A missing time takes the other member's; with no times it returns null.

- [ ] **Step 1: Write the failing tests** in `graph_stacks_test.dart`.

  **`group('graphShortDateRange (2026-11-07)')`.** With `AppLocalizationsEn()` and offset 0:

  | Pair | Expected |
  |---|---|
  | (2019-09-02, 2025-05-20) | `'Sep 2019 – May 2025'` |
  | (2025-04-10, 2025-12-02) | `'Apr – Dec 2025'` |
  | (2025-06-03, 2025-06-24) | `'Jun 3 – 24'` |
  | (2025-06-03 09:00, 2025-06-03 10:00) | `'Jun 3'` |
  | (2025-05-20, 2019-09-02), reversed | `'Sep 2019 – May 2025'` |

  At offset 60, (2024-12-31 23:30Z, 2025-01-30) gives `'Jan 1 – 30'`.

  **`shortDates`.** Build two `GraphStackData`: one whose newest member has `timestampMs: null` (expect the oldest
  member's single day), and one where both are null (expect null).

  **The sweep.** A testWidgets "narrowing a card: the authors go, then the dates take the narrower form and end in
  '…'". It uses `stackRecording('design-default free default')`, and `GraphViewOptions(cardWidth:)` runs from 400 down
  to the narrowest width the options allow, in steps small enough to pass through full, short and cut dates. For every
  stack card, from `debugSlots` against the full string (as the existing test builds it) and the
  `graphShortDateRange` string:
  - the dates text is the full or the short one;
  - an authors slot appears only with the full one;
  - the short one appears only when it is narrower than the full one;
  - the dates rect ends left of the conflict slot, or by `cardRect.right − cardPadX + .5`;
  - no slot has a negative width.

  Across the sweep: every card shows the full form at 400, at least one card shows the short form, and at least one
  dates rect is narrower than its text laid out unbounded (cut with "…").

- [ ] **Step 2: Run them; they fail.** `flutter test test/features/graph/graph_stacks_test.dart` from `app/`.
  Expected: `graphShortDateRange` is missing.

- [ ] **Step 3: Implement.**
  - Add the two functions.
  - In the detailed branch, lay out `full = dates()` and `short = shortDates()`.
  - `room = avail − fixed − _metaGap`.
  - The dates use `full` when `full.width ≤ room`, else the narrower painter, placed at `min(width, room)` (the
    paragraph's ellipsis cuts it) and only when `room > 0`.
  - The authors get `room − datesW − _metaGap` only beside `full`, or when there are no dates, and are gone below one
    character as now.
  - The comment over the yield: "the authors shrink (gone below one character), then the dates take months and end
    in '…' — they never go while there is room".

- [ ] **Step 4: Run `graph_stacks_test.dart`; it passes.** Then run `dart analyze app`: no issues.

---

### Task 3: The DS and the prototype follow (DESIGN-SYSTEM-SYNC #23)

**Files** under `_bmad-output/implementation-artifacts/`:
- **Prototype `design/`:**
  - `graph-layout.jsx`: lines 455-482 (`BREAK_MIN` = `3 * U`, no `spanLabel`, `shortenFree` only shifts), 541, and
    667-690 (no `bands`/`inBand`, no dropped day, years without `inBand`).
  - `graph-view.jsx`: 440-455 (`BreakBand`), 514-525 and 576 (minimap bands), 1211-1212, 1233.
  - `graph.css:63-65`, `float.css:49`.
  - `DESIGN-SYSTEM-SYNC.md`: append #23.
- **DS `design_system/`:**
  - Delete `components/graph/GraphBreak.{jsx,d.ts,prompt.md}`.
  - `components/graph/graph.css:106-112`.
  - `DayAxis.{jsx:13,d.ts:24,prompt.md:18}`: drop "none inside a GraphBreak".
  - `StackCard.prompt.md`: the date rule.
  - `components/graph/long-history.card.html`.
  - `_ds_bundle.js`: the `GraphBreak` block, the header `components` entry, the DayAxis comment (skill § E).
  - `_ds_manifest.json`: the component and the card subtitle.
  - `readme.md:40,124,197,401`, plus a Sync #23 line and "Synced through #23".
- **App:** `app/test/widgetbook/ds_manifest_parity_test.dart:99` (delete `'GraphBreak': '10.31'`).

**Interfaces:** consumes Task 1's cut rule and Task 2's date rule (the Global Constraints).

- [ ] **Step 1: Prototype.** Make the edits above.
  - `preview_start design-preview`, then open `JJ Desktop Client Floating.html?history=long`.
  - Expected: under the long stack, no strip and no zigzag; a 1½-pitch gap with its day label and the year label; no
    console errors.
  - Check that `gapUnits` caps at 48 like `freeGap`. If it does not, note it in #23; do not change it.
- [ ] **Step 2: DS.** Make the edits above. In `long-history.card.html`:
  - Delete `GraphBreak`, `brk`, the `breaks` prop, the `.m-brk` style and the polyline.
  - Add day `{key:"dec11", label:"Dec 11", y: mid(2,3), guide: mid(2,3)}` and year
    `{key:"y2025", year: 2025, y: mid(2,3)}`.
  - Minimap caption: "Years head their sections (2025, 2019)".
  - The foot's "GraphBreak." paragraph becomes "Stacks.": a stack keeps its members' time below it; a card-free
    stretch taller than 3 pitches (only folded members make one) shrinks to 1½ pitches card to card, with no mark; its
    day and year labels stay; the stack card names its period (full, then months, then "…").
  - The `@dsCard` subtitle drops GraphBreak.

  `StackCard.prompt.md` gets one line: the date's full form, then months ("Sep 2019 – Dec 2025"), then "…"; the author
  goes first; the date never goes.
- [ ] **Step 3: Run the parity test.** `flutter test test/widgetbook/ds_manifest_parity_test.dart` from `app/`: PASS.
- [ ] **Step 4: Sync entry #23** in `DESIGN-SYSTEM-SYNC.md`, in #22's form:
  - Title: "Long histories without a tear: stacks give their room back, the stack card names its period".
  - Why (Ralph's screenshot, B over A), the Files, the rules, "→ Design system: done in place …; republished".
  - A dated "the app follows #23" line naming `graph_cuts.dart` and the stack card.
- [ ] **Step 5: Publish.** Follow the `design-artifacts` skill: § A (read the index, `build_ds.py`, `lastChange`, one
  publish), then § B for canvas `6sAzL5mDcVpWXevbTcempu`.
  - Expected: both publishes succeed.
  - The DS page's *Long history* card shows no strip.

---

### Task 4: Records

**Files:**
- `_bmad-output/planning-artifacts/epics.md`, Story 10.31 (line 11954)
- `_bmad-output/implementation-artifacts/deferred-work.md`, "Surfaced in Story 10.31" (2805-2818)
- `_bmad-output/implementation-artifacts/sprint-status.yaml:39,181`, plus `last_updated`

- [ ] **Step 1: epics.md.** A dated note under Story 10.31: "CHANGED 2026-11-07 (Ralph): no tear …" (the five spec
  points, a pointer to sync #23 and the spec).
- [ ] **Step 2: deferred-work.md.** A struck-through, RESOLVED bullet in the 10.31 section, in the section's style.
  It says what Ralph saw, why it happened (the cut took the stack's newest time and the strip claimed years without
  changes), what was decided (B), what changed, and the witnesses.
- [ ] **Step 3: sprint-status.yaml.**
  - Line 39's summary: no "Abrisskante".
  - Line 181's comment gets "CHANGED 2026-11-07 (Ralph): no tear; cuts > 3 pitches to 1.5 unmarked; labels stay;
    stack card always shows its period (DESIGN-SYSTEM-SYNC #23)".
  - Bump `last_updated`.

---

### Task 5: Verify in the running app, then run the gate

- [ ] **Step 1: The app.**
  - Connect Marionette to the running app: the VM service URI from its `flutter run` output. When none runs, start it
    in a terminal tab.
  - `hot_restart`, then open `dart-intellij-third-party`.
  - Scroll to the 486-stack (`ynswl…wtnxw`) and the 441-stack (`ommqn…soqsr`) from Ralph's screenshot.
  - Expected: no strip and no span label; 1½ pitches to the next card; that card's day label, and the 2021/2019 year
    labels; each stack card shows its period.
- [ ] **Step 2: The catalogue.** In "Graph › Minimap › Long history":
  - the shortened stretches have no strip, and carry day and year labels;
  - the minimap has no zigzag;
  - compare with the DS card *Long history*, rendered via Playwright (`scale: "device"`).
- [ ] **Step 3: The gate.** `cargo make test` from the repo root, unpiped, in the main session. Expected: green, and
  the coverage baseline is not lowered.
- [ ] **Step 4: Report.** Tell Ralph what changed and what was checked, then ask whether to commit.
