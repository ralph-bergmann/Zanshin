---
title: 'Story 10.17 — Commit stacks: the stack card, its popover and member callouts, the bracket, expand and collapse, persistence'
type: 'feature'
created: '2026-10-31'
status: 'done'
baseline_revision: '9ebb2d436ef93a83dd60b1abc7077824a2443224'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The stack card, its offset layers, hatch, member list and bracket have not been compared against the DS cards in the running catalogue; only widget tests check them.
    evidence: |-
      The verification notes record that the Widgetbook/Marionette visual check was not run; the DS measurements are checked only as rects, texts and semantics in graph_stacks_test.dart. Settled by a Marionette / Playwright check of the catalogue's stack states against the DS cards.
    location: >-
      app/lib/src/features/graph/graph_stack_card.dart, graph_stack_popover.dart, graph_canvas.dart
    severity: medium (unverified)
  - summary: >-
      A pending action on a member folded into a collapsed stack should dim the stack card, but no test renders that.
    evidence: |-
      GraphCanvas.build maps pendingKeys through layout.placeOfKey; no canvas test renders a pending key (the pending look had no render test before this story either).
    location: >-
      app/lib/src/features/graph/graph_canvas.dart
    severity: low
    resolved: >-
      RESOLVED 2026-11-01 (spec-fix-story-loop-leftovers-2026-11-01, commit cc4065b): a canvas test in graph_stacks_test.dart renders pendingKeys {a folded member} and pins its stack card at disabledOpacity.
---

<intent-contract>

## Intent

**Problem:** 4.13's engine collapses linear runs into stack nodes (GraphGridView format 4: n + S nodes, hidden members, `runs`), but the view has no notion of runs: `GraphLayout` cannot carry them, recordings reject n + S outputs, and there is no stack card, popover, bracket, toggle or persisted stack state (epics.md Story 10.17 with its 2026-09-30 / 10-14 / 10-16 / 10-26 notes).

**Approach:** Add run accessors to `GraphLayout` (folded members stay in the node index with no position, as the engine emits them), teach `RecordedGraphLayout` the engine's stack output, record design-sample stack states with the engine CLI, and build the view side: a slotted stack-card `RenderBox`, a hover popover with member rows and member callouts, a bracket painted with the edges plus a hit-testable collapse button, model-owned toggles sent as `expandedKeys` / `collapsedKeys` with an anchored relayout and a member fade-in, and toggles persisted per repository.

## Boundaries & Constraints

**Always:**
- **Layout contract.** `GraphLayout` gains `runCount`, `runMembersOf(run)` (node indices, oldest first, as the engine), `stackNodeOf(run)` (null when expanded), `runOf(node)` (a member's or a stack node's run), all with no-run defaults in the abstract class; derived concrete helpers `isStackNode`, `isFolded` (member of a collapsed run: `rowOf`/`colOf` = −1, never laid out), `placeOfKey(key)` (the node, or a folded member's stack node). A stack node's key is `graphStackKey(oldestMemberKey)` = `stack:<key>` (never a jj id). `shownCount` excludes stack nodes, so collapsed members count as shown.
- **Recordings** (item 8): `spikes/graph-layout-ab/tools/record-graph.mjs` also writes `app/widgetbook/graph/graph_stack_recordings.g.dart` from the engine CLI's `--stacks` for `design-default` and `design-all`, `free` and `compact` (order `compact`): the default state, all expanded, and each run flipped alone from the default. `stackRecordingFor(sample, request)` picks the recording whose run states match what the engine would compute for the request (keepOpen → expanded, else the oldest key in expanded / collapsed, else the recording's default), else the fewest mismatches (`shortcut:` comment — 10.12 brings the engine). `!request.stacks` → the existing ungrouped recording. Every stack recording passes `checkGraphLayout`'s hard invariants (folded nodes skipped) and I7 (every visible node and every expanded member keeps its ungrouped column; a stack node takes its newest member's).
- **Folded nodes** are skipped by `UniformRows` / `PerNodeTops` (never in `visibleNodes`) and by `checkGraphLayout`; the viewport's anchor, reveal, pinned keys, `cardRectOf`, the pulse and the peek resolve keys through `placeOfKey`.
- **Stack card** (detailed 62 / compact 40, the card's width): two offset layers (DS graph.css:27-28: `0 7 0 −4` fill / `0 7 0 −3` border, `0 14 0 −7` / `0 14 0 −6`; hover → `cardFillHover` / `cardBorderHover`), the count badge (graph.css:29: 18 px pill, min-width 18, pad 0 5, mono 600 `fsXs`), the newest member's subject (empty → `(no description set)` italic). Detailed line 2: id range newest‥oldest, each `max(prefix, 5)` with the prefix bold, one `Text.rich`-style paragraph; the members' distinct author first names joined by ", "; the date range oldest – newest (one date when equal); ⚠ when any member conflicts. Compact: badge, range, subject, ⚠ on one line. Immutable stack (every member immutable): 10.3's hatch on the card and both layers. Hover border, dim, z-order and focus ring as cards. A primary click (within `graphDragThreshold`) expands; no selection, no double-click, no bookmark control, no •••, no menu. Semantics: one button node, label `N changes, <newest subject>, <range>`, `onTap` and `onExpand` expand. Stacks are neither drag sources nor drop targets.
- **Popover** (item 2): after `delayStackList` (380 ms) of rest on a stack body, below the card (12 px gap) or above it when it does not fit below the unobscured area; width clamp(card width, 280, 380), x clamped into the unobscured area; the one menu material (radius 13, `--fl-sheen` over `--fl-bg-solid`, 1 px `--fl-border`, `--shadow-menu`, as the house menu surface). Rows newest first: id `max(prefix, 8)` prefix bold, subject, relative date; then the hint "Click to expand N changes". Height capped at 8 rows; beyond, it scrolls and builds only visible rows (`ListView.builder`). A row hovered for 180 ms opens 10.6's `GraphPeek` for that member beside the row (`graphPeekPosition`, flipping left). Card → popover → row callout keeps all open (the controller's `holdHover` / `leave`); leaving closes them. Exit: the generic fade with a small mirrored vertical drift × `--motion` on `--dur-exit-lg` / `--ease-exit`. The normal peek never opens on a stack node. Not announced (ExcludeSemantics), as the peek.
- **Bracket** (item 3): per expanded run with a laid-out member, 7 px wide, 1.5 px stroke, open on the right, radius 7 on the left, x = leftmost member x − 16, from the newest member's top + 6 to the oldest member's bottom − 6; `cardBorder`, `cardBorderHover` while a member or the bracket is hovered; painted in the edges hook after the edges, never dimmed. A 20 px collapse button (the `stack-collapse` icon, `ZI.stackCollapse`) centred on the bracket's left edge appears while the run is hot; tooltip "Collapse N changes into a stack". Bracket hover regions (the strip inflated 12 left / 8 right) are translucent overlays (pans still start there); the button is opaque, so a press on it never pans.
- **Toggle** (item 4): `GraphViewModel.expandStack(key)` / `collapseStack(key)` (key = the run's oldest member, or the stack key) update the expanded / collapsed sets (`add` to one, `remove` from the other), persist them, set `anchorHint` to the anchor member (compact: the oldest; free: the newest) and issue exactly one layout request; the stack keeps its viewport position through the existing viewport anchor via `placeOfKey`. A collapse clears a selection inside the run (closing the inspector). On expand, the layout's entering keys (the run's members except the anchor) fade in once: opacity 0→1 on `durSlide`, a 6 px rise and scale .98→1 on `durMove`, both `easeGlide`, distances × `--motion`; one canvas ticker, paint-only, no extra card built. A collapse is instant.
- **Default and persistence** (item 5): the engine's default state (expanded only for runs of mutable ancestors of @) comes from the source; the model sends `expandedKeys` / `collapsedKeys` with `keepOpenKeys` = selection + pending explicit reveal. Toggles persist per repository through a `GraphStackStore` port (`init(stackStore:)`); `ProjectStackStore` stores them on the repository's `ProjectEntry` (`expandedStacks`, `collapsedStacks`, default empty) and keeps them in memory for a path not in the registry. A run whose oldest member changed no longer matches its key and falls back to the default (engine rule).
- **Interplay** (item 6): `goTo` / `revealKey` onto a folded member issue a new layout request carrying it in `keepOpenKeys` and reveal it when it lands. Content: a visible stack node loads its members' content (`GraphContent.load` expands a stack node to its members). The counter needs no change (shownCount).
- **Keyboard:** Enter / Space on a focused stack card expands it.
- Strings through `app_en.arb` (ICU plurals); jj's literals marked `// l10n-ignore`.

**Never:** Rust or FFI changes; exporting zanshin_core's engine or calling `RepoHandle.graphLayout` (10.12); run rules, rows or columns in the view (4.13); dragging stacks; a stack in the inspector or ever selected; the global `zanshin.graph.expanded` list; a collapse keeping the selection; centring the middle member; a minimap (10.16); fading on collapse; committing 10k–100k scale recordings.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Expand by click | collapsed stack S (oldest k) | one request, `expandedKeys ∋ k`, `collapsedKeys ∌ k`; S's anchor member keeps S's viewport rect; members except the anchor fade in | — |
| Collapse by bracket | expanded run with the selection inside | selection null, one request with `collapsedKeys ∋ k`, stack card at the anchor's rect | — |
| Go-to folded member | `goTo(m)`, m folded | request with `keepOpenKeys ∋ m`; on land m selected, revealed, pulsed | — |
| Persisted | toggles saved for repo A, B has none | a model for A sends A's sets; one for B sends empty sets | path absent from registry: in memory only |
| Changed oldest | stored key no longer an oldest member | the run shows its default state | — |
| Huge stack | 500-member collapsed run | popover height capped, scrolls, builds only visible rows | — |
| Group stacks off | `stacks: false` | no stack nodes, no brackets | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_layout.dart` -- `GraphLayout` (:179-315): add run accessors + helpers + `graphStackKey`; update the "no synthetic keys" doc.
- `app/lib/src/features/graph/recorded_graph_layout.dart` -- ctor (:15-111) gains `runs`; `fromSpec` (:117-216) accepts n+S `nodes` (null = folded, −1/−1), appends stack nodes (key `stack:<oldest>`, newest member's timestamp, immutable when members are, parent count 1), parses `runs` (`members` oldest first, `state`, `node`); `shownCount` (:351) = input node count.
- `packages/zanshin_core/test/graph_layout/goldens/stacks/*.json` -- engine goldens and request format (`{"expanded":[],"collapsed":[],"keep_open":[]}`), read-only reference; `docs/graph-layout.md:253-262, :761-865` -- format 4 and I7.
- `spikes/graph-layout-ab/tools/record-graph.mjs` -- add the stack pass (CLI `--stacks <request>`; `dart run benchmark/graph_layout_cli.dart layout --mode M --order compact --stacks R in out` in `packages/zanshin_core`); writes `app/widgetbook/graph/graph_stack_recordings.g.dart` (map name → (input, output, request) + per-sample default name).
- `app/widgetbook/graph/stack_recordings.dart` (new) -- `stackRecordingFor`; `app/widgetbook/graph/fake_graph_source.dart` + `app/widgetbook/folders/graph.dart` (:327, :417 call `layoutOf`) -- honour `request.stacks` for the design samples.
- `app/lib/src/features/graph/vertical_layout.dart` -- skip `rowOf < 0` in both index builders (:81-88, :118-125, `_byRow` :143).
- `app/lib/src/features/graph/layout_invariants.dart` -- skip folded nodes (:54-105).
- `app/lib/src/features/graph/graph_viewport_render.dart` -- `cardRectOf` (:79), `_layoutNode` pinned (:459-463), `_applyAnchor` (:486-500), `_recordAnchor` (:502-521: record the anchor key with its place's rect), `_revealTarget` (:529) via `placeOfKey`.
- `app/lib/src/features/graph/graph_canvas.dart` -- `_card` (:505) builds `GraphStackCard` for stack nodes and wraps entering keys in the fade; `_syncPeek` (:323-364) uses `delayStackList` and opens the popover for a stack node; `_peekLayer` (:649) branches to the popover; bracket painting after `edges.paint` (:616-618) and a bracket overlay layer in the `Stack` (:573); `_paintPulse` (:461) via `placeOfKey`; new params `entering`, `onExpandStack`, `onCollapseStack`.
- `app/lib/src/features/graph/graph_stack_card.dart` (new) -- `GraphStackCard` widget + `RenderGraphStackCard` (pattern: `graph_card.dart:474-691`, `graph_card_render.dart`: `_paragraph`, `_weight`, `_paintIcon`, hatch :850, border/fill :836-870, focus ring :893-902, tap recognizer :145-152, MouseTrackerAnnotation :1147-1165, semantics :1173-1193). Hover through `GraphCardController.enter/leave`.
- `app/lib/src/features/graph/graph_stack_popover.dart` (new) -- popover + rows + row callout; reuse `GraphPeek` (`graph_peek.dart`), `graphPeekPosition` (:23), `GraphCardData.of`, `graphRelativeDate`.
- `app/lib/src/features/graph/graph_card.dart` -- `GraphCardController` gains `onExpandStack` (like `onEdit` :65) used by the stack card.
- `app/lib/src/features/graph/graph_content.dart` -- `load` expands stack nodes to their members.
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphRequest` already has `expandedKeys`/`collapsedKeys`/`keepOpenKeys` (:51-60); add `GraphStackStore` + `GraphStackToggles`.
- `app/lib/src/features/graph/graph_stack_store.dart` (new) -- `ProjectStackStore` over `SettingsStore` (`update` at settings_store.dart:81).
- `packages/zanshin_settings/lib/src/model/projects_settings.dart` -- `ProjectEntry` gains `expandedStacks`, `collapsedStacks` (`@Default(<String>[])`); regenerate with `dart run build_runner build` in that package.
- `app/lib/src/features/graph/graph_view_model.dart` -- `init(stackStore:)`, `_expanded`/`_collapsed`, `expandStack`/`collapseStack`, `entering`, `_build` (:728) sends the sets, `_revealExplicit` (:663) / `goTo` (:290) re-request for a folded key, `_land` (:740) sets `entering` once.
- `app/lib/src/features/graph/graph_view.dart` -- wire `onExpandStack`/`onCollapseStack`/`entering` into `GraphCanvas` (:254); `_onKey` (:171-201) Enter/Space on a stack key expands.
- `app/lib/src/features/graph/graph_preferences.dart` -- `init` (:56) passes `stackStore` through.
- `app/lib/l10n/app_en.arb` -- new strings near `graphGroupStacks` (:386).
- `app/test/features/graph/graph_harness.dart` (:20 `recording`), `app/test/helpers/scripted_graph_source.dart` -- helpers for stack recordings and a constructed 500-member stack.

## Tasks & Acceptance

**Execution:**
- `graph_layout.dart`, `recorded_graph_layout.dart` -- run accessors and the format-4 parse -- the view's run contract (item 7).
- `record-graph.mjs` → `graph_stack_recordings.g.dart`; `stack_recordings.dart`; `fake_graph_source.dart`, `folders/graph.dart` -- recordings and fakes (item 8).
- `vertical_layout.dart`, `layout_invariants.dart`, `graph_viewport_render.dart` -- folded nodes never laid out; keys resolve through `placeOfKey`.
- `graph_stack_card.dart`, `graph_card.dart` -- the stack card (item 1).
- `graph_stack_popover.dart`, `graph_canvas.dart` -- popover, member callouts, bracket and button, entering fade (items 2–4).
- `projects_settings.dart` (+ generated), `graph_ports.dart`, `graph_stack_store.dart`, `graph_view_model.dart`, `graph_preferences.dart`, `graph_view.dart`, `graph_content.dart` -- toggles, persistence, reveal, keyboard, content (items 4–6).
- `app_en.arb` -- strings.
- Tests: `app/test/features/graph/graph_stacks_test.dart` (new) for the matrix and the ACs; `recorded_graph_layout_test.dart` (format 4 parse, I7 on every stack recording); `vertical_layout_test.dart` (folded skipped); `packages/zanshin_settings/test` (ProjectEntry round-trip with stacks).

**Acceptance Criteria:**
- Given the `design-default free` default stack recording, when the view shows it, then each stack card shows its count, the newest‥oldest range, the newest subject, the authors, the date range and ⚠ as its members' content says, and no folded member is built.
- Given a collapsed stack, when it is clicked (or Enter/Space when focused, or VoiceOver's tap), then exactly one layout request is issued, the anchor member's viewport rect after landing equals the stack card's before (both axes), and no visible node changes column.
- Given an expanded run, when the pointer rests on a member, then the bracket lights and its collapse button shows; clicking the button collapses with one request and the stack card takes the anchor's viewport rect; a press on the button starts no pan.
- Given the pointer rests on a stack card, then after 380 ms the popover opens below it (above near the bottom of the unobscured area); a row rested on for 180 ms opens its member's callout; moving card → popover → callout keeps all three open, leaving closes them.
- Given an expand lands, then the entering members fade in over 260 ms with a 6 px rise and .98 scale, and under reduce motion (`ZsMotion` with motion 0) they fade with no rise and no scale.
- Given a store holding toggles for repository A, when a model for A initialises, then its first request carries A's sets; a model for repository B carries none.
- Given a selection inside an expanded run, when "Group stacks" is switched on or a reload lands, then the run stays expanded (keepOpen); when the user collapses it, then the selection clears.
- Given the counter, then collapsed members count as shown.

## Spec Change Log

## Review Triage Log

### 2026-10-31 — Review pass
- verdicts: 31 findings — high 0, medium 4, low 22, false 5, maybe-false 0 (blind 12, intent-alignment 5, verification-gap 2, edge-case 12)
- findings:
  - `[medium]` `[patch]` blind: collapse is pointer-only; a keyboard / VoiceOver user can expand but never collapse — members of an expanded run get a VoiceOver custom action "Collapse N changes into a stack" through a new `GraphCardController.onCollapseStack`; test added.
  - `[low]` `[reject]` blind: stored toggles are never pruned — growth is one key per user toggle; pruning to the shown layout would drop toggles of runs outside the current revset (the keys are per repository, not per revset); unlikely to matter, and the fix adds policy.
  - `[low]` `[reject]` blind: a toggle equal to the engine default stays recorded — the spec's rule (a toggle is the user's explicit state, `add` / `remove`); no named harm beyond the default never re-applying, which is the point of a toggle.
  - `[low]` `[reject]` blind: a visible stack loads every member's content — the story's own item 6 ("a visible stack card loads its members' content"); the card's authors and ⚠ need every member.
  - `[low]` `[reject]` blind: a stack card recomputes all members on every content notification — O(members) per page landing for the few visible stacks; no everyday cost, and gating adds a member-set diff.
  - `[low]` `[reject]` blind: only `FileSystemException` is swallowed on save — the house pattern (`GraphPreferences._write`); any other error is a programming error that should surface.
  - `[low]` `[reject]` blind: clicking a member row does nothing — the design's rows are inert (design/graph.css:277 `cursor:default`); the hint names the card click.
  - `[low]` `[patch]` blind: `_PopoverLayout.shouldRelayout` ignores `factor` — added. (The `+ 1` border offset and the callout outliving the row exit are rejected: cosmetic, and closing on row exit needs callout-hover tracking.)
  - `[low]` `[reject]` blind: thin coverage (compact bracket collapse, flip-left callout, design-all recordings, stale `entering`, double toggle in flight) — the core paths are pinned in both modes for expand and collapse; the rest are breadth additions without a named defect.
  - `[low]` `[reject]` blind: a collapse can be overridden by another keep-open source — keepOpen holds only the selection (cleared by the collapse) and a pending explicit reveal (transient); @ and bookmarked commits are never members.
  - `[low]` `[reject]` blind: the stack inputs are embedded in both generated files — one generator writes both deterministically, so they cannot drift independently.
  - `[false]` `[reject]` blind: visible `(no description set)` vs spoken `cardNoDescription` differ — the commit card does exactly the same (graph_card_render.dart:562-564 vs graph_card.dart:442): jj's literal on screen, the localized phrase spoken; LTR is the house pattern.
  - `[false]` `[reject]` intent: per-repository persistence is not reachable from `app/lib` — `GraphView` has no production mount yet (10.12 mounts it in the project window); the port and `ProjectStackStore` are what that wiring plugs in.
  - `[low]` `[patch]` intent: Space on a focused stack is untested — the Enter test now also covers Space.
  - `[low]` `[reject]` intent: the immutable hatch on the stack card has no test — painting is verified by the Marionette check, not widget tests (no goldens); low.
  - `[low]` `[reject]` intent: popover rows only read the cache instead of loading as they become visible — the stack card already loads every member (item 6), so the rows have their content; same root as the "loads every member" row.
  - `[low]` `[reject]` intent: no engine recordings of the scale inputs — Design Notes: the repo never commits 10k–100k engine outputs (record-graph.mjs:21-23); the 500-member witness uses a constructed layout.
  - `[medium]` `[patch]` verification-gap: `GraphPreferences.init`'s `stackStore` forwarding is untested — added a graph_controls_test case asserting the first request carries the store's toggles.
  - `[medium]` `[patch]` verification-gap (other): after a collapse the keyboard focus can stay on a folded member, which shows no ring and whose Enter selection reopens the run — `_focusChanged` moves a folded focus key to its stack's key; test added.
  - `[medium]` `[patch]` edge: `goTo` on a folded key while a request is in flight only set `_explicit`; the in-flight request lacked the key in keepOpenKeys and the stack never opened — the in-flight branch now also queues a request for a folded key; test added.
  - `[low]` `[reject]` edge: the pulse can land on a still-folded key — only when the queued expand was superseded; the pulse then rings the stack card via `placeOfKey`, which is where the key is shown.
  - `[low]` `[patch]` edge: a collapse during an in-flight request cleared the selection without notifying — `_notify()` added.
  - `[low]` `[reject]` edge: toggles are never pruned — same as the blind row.
  - `[false]` `[reject]` edge: popover state reused for another stack keeps a stale callout — each popover is mounted under `ZsPresence(key: ValueKey(key))` (graph_canvas.dart:838), so another stack gets a new State.
  - `[low]` `[patch]` edge: a list that fits neither below nor above is placed above `area.top` — y is now clamped to the area's top.
  - `[low]` `[reject]` edge: a callout whose row scrolls out stays beside the list — it follows the row's offset; scrolling under an open callout is rare and harmless.
  - `[low]` `[reject]` edge: malformed `runs` data is not fully validated — recordings are generated by the engine CLI; malformed data already throws a FormatException or RangeError, loudly.
  - `[low]` `[patch]` edge: a pending folded member gives its stack card no pending look — the pending set resolves through `placeOfKey`.
  - `[false]` `[reject]` edge: `holdAnchor` before the viewport has size loses the anchor — a toggle comes from a clicked or focused stack card, so the viewport is laid out; the method guards `hasSize`.
  - `[low]` `[reject]` edge: record-graph.mjs may throw a TypeError instead of `fail()` — a dev tool that still exits non-zero.
  - `[false]` `[reject]` edge (claim): `ProjectStackStore` is never constructed in `app/lib` — same as the intent row: no production mount of `GraphView` exists until 10.12.

### 2026-10-31 — Review pass (follow-up)
- verdicts: 34 findings — high 0, medium 2, low 22, false 8, maybe-false 2 (intent-alignment 6, verification-gap 4, blind 12, edge-case 12)
- findings:
  - `[false]` `[reject]` intent: per-repository persistence is unmounted in `app/lib` — carried: no production mount of `GraphView` exists until 10.12.
  - `[low]` `[reject]` intent: "changed oldest → default" is witnessed through the fake `stackRecordingFor`, not the engine — the intent itself says the view runs on recordings until 10.12 (`shortcut:` comment); the engine rule is 4.13's.
  - `[false]` `[reject]` intent: the rise and scale run on `durSlide`, not `durMove` — both tokens are 260 ms in full motion (zs_motion.dart:30, :38); under reduce motion `durMove` is zero and the rise and scale are already × `motion` = 0 (graph_canvas.dart `_Entering`), so the observable result is the same.
  - `[maybe-false]` `[defer]` intent: visual fidelity to the DS cards is checked only by widget tests (no Marionette check) — would be medium if a measurement deviates; settled by the catalogue check against the DS cards. Deferred (spec `deferred`, deferred-work.md).
  - `[low]` `[reject]` intent: "Group stacks off: no brackets" is implied by `runCount == 0`, not asserted — `_brackets` iterates `runCount`, so no bracket can exist; a test would restate the loop bound.
  - `[false]` `[reject]` intent: `_brackets` builds a bracket per expanded run without checking a member is laid out — an expanded run's members always have cells (only collapsed runs fold); viewport culling handles the rest.
  - `[medium]` `[patch]` verification-gap: the collapse's immediate `_notify()` during an in-flight request is untested — added "a collapse while a request is in flight notifies at once: the inspector closes".
  - `[low]` `[defer]` verification-gap: a pending folded member's stack card pending look is never rendered in a test — filed disposition `defer`; the pending look had no render test before. Deferred (spec `deferred`, deferred-work.md).
  - `[low]` `[patch]` verification-gap: `ProjectStackStore.save`'s failed-write path is untested — added "a failed write keeps the toggles in memory and throws nothing" (blocker-file pattern of graph_controls_test).
  - `[false]` `[reject]` verification-gap (other): `ProjectStackStore` is not constructed in `app/lib` — carried: no production mount until 10.12.
  - `[false]` `[reject]` blind: the pulse fires on the still-folded stack when a go-to lands behind an in-flight request — a request queued while one is in flight discards the in-flight result (`!_queued`, graph_view_model.dart:788), so only the queued, keep-open layout lands and pulses.
  - `[false]` `[reject]` blind: a toggle's fade and anchor are consumed by an in-flight reload's stale layout — same refutation: the in-flight result is dropped when a toggle queues a request.
  - `[false]` `[reject]` blind: production never wires `ProjectStackStore` — carried: no production mount until 10.12; listed under residual risks.
  - `[maybe-false]` `[defer]` blind: done without the Marionette check — same root as the intent visual-fidelity row; deferred there.
  - `[low]` `[reject]` blind: stored toggles grow without limit — carried from the first pass.
  - `[low]` `[reject]` blind: the stack card's VoiceOver label omits conflict, authors, dates — the label is the intent's exact wording (`N changes, <newest subject>, <range>`); the empty subject while content loads is transient.
  - `[low]` `[reject]` blind: the ⚠ glyph can be clipped on narrow cards — the card width is the view's card width (min well above badge + two 5-char ids + icon); unreachable in everyday use and the fix adds a yield rule.
  - `[low]` `[reject]` blind: collapsing is not reachable from the plain keyboard — the intent's keyboard item covers only Enter/Space expand; VoiceOver has the collapse action; a shortcut is a new key binding the intent does not name (question for Ralph in the run report).
  - `[low]` `[reject]` blind: format-4 validation holes in `RecordedGraphLayout.fromSpec` — carried ("malformed `runs` data").
  - `[low]` `[reject]` blind: the callout drifts when the list scrolls; `_pad + 1` — carried.
  - `[low]` `[reject]` blind: `GraphStackData` has no `==`, every rebuild re-lays out; `_brackets` walks all expanded members — carried ("per-notification recompute"); the walk covers expanded runs only.
  - `[low]` `[reject]` blind: missing tests (drag slop, hover reset on detach, hatch, save failure, popover `nowMs`) — the save failure shares the verification-gap row's root and is patched there; the rest are breadth with no named defect (hatch carried).
  - `[low]` `[patch]` edge: `_fail` leaves `_enteringNext` / `_pulseOnLand` set, so a later unrelated layout fades in stale keys or pulses an old go-to target — `_fail` now clears both; test "a failed expand leaves no fade for a later layout" (fails without the fix).
  - `[low]` `[reject]` edge: a toggle is saved before its request succeeds — the toggle is the user's explicit state; the next successful layout applies it.
  - `[low]` `[reject]` edge: toggles never pruned — carried.
  - `[low]` `[reject]` edge: pulse on a landed layout that keeps the run collapsed — carried ("the pulse can land on a still-folded key").
  - `[low]` `[reject]` edge: only `FileSystemException` swallowed on save — carried (house pattern).
  - `[medium]` `[patch]` edge: an expanded run taller than the view puts its collapse button at the bracket's centre, off-screen, while a visible member is hovered — the button is now centred on the strip's visible part (`strip.intersect(view)`, graph_canvas.dart `_bracketLayer`); test "a run taller than the view shows its collapse button on the visible part of the bracket" (fails without the fix).
  - `[low]` `[reject]` edge: callout drift on scroll — carried.
  - `[low]` `[reject]` edge: a relayout under an open popover keeps the callout's row index — the callout shows the member now in the row the pointer rests on; rare and harmless.
  - `[low]` `[reject]` edge: runs with empty / out-of-range / duplicate members — carried (run validation).
  - `[low]` `[reject]` edge: a null cell for a non-member node becomes row −1 — carried (same root).
  - `[low]` `[reject]` edge: an unknown run state is read as collapsed — carried (same root).
  - `[false]` `[reject]` edge: Enter/Space is swallowed while `onExpandStack` is null — `GraphCanvas` installs `_expandStack` on the controller while mounted (graph_canvas.dart:288) and `GraphView` always passes `model.expandStack`.

## Design Notes

- **Folded members stay in the node index** (Claude's proposal) because the engine's format 4 does, router B already skips row −1 nodes (`router.dart:110-165`), and the popover needs each member's id, timestamp and content through the existing accessors. The stack node gets its own `stack:<oldest>` key so selection, z-order and hover never confuse it with a member; the anchor survives a toggle because the viewport resolves the anchor member's key to its stack's place.
- **Recordings by state, not an engine in the view** (story: "runs on the spike's stack recordings until 10.12"): the fakes pick the matching precomputed state, so one toggle from any recorded state works in the catalogue; deeper combinations take the nearest state (shortcut). The scale witness (500 members) uses a constructed layout, not a committed engine output — the repo never commits 10k–100k outputs (record-graph.mjs:21-23).
- **No skeleton on the stack card** (Claude's proposal): its texts arrive with its members' content; the card rect never moves.
- Popover row height 28 px, cap 8 rows (Claude's proposal for the design status's open point on large stacks).

## Verification

**Commands:**
- `node spikes/graph-layout-ab/tools/record-graph.mjs` (repo root) -- regenerates both recording files deterministically.
- `flutter test test/features/graph test/widgetbook test/l10n` in `app` -- expected: all pass.
- `flutter test` in `packages/zanshin_settings` -- expected: all pass.
- `dart analyze --fatal-infos` and `dart format --set-exit-if-changed .` in `app` and `packages/zanshin_settings` -- expected: clean.
- Gate rule: no `cargo make test`; no Rust touched.

**Verification notes (2026-10-31, gate rule: targeted checks only):**
- `node spikes/graph-layout-ab/tools/record-graph.mjs` — 16 + 34 recordings; a second run leaves both files unchanged.
- `flutter test test/features/graph test/widgetbook test/l10n` (app) — 798 passed (after the review patches).
- `dart analyze --fatal-infos`, `dart format --set-exit-if-changed .` (app, packages/zanshin_settings) — clean.
- `flutter test` (packages/zanshin_settings) — 38 passed.
- Whole-app `flutter test` — 1299 passed, 5 failed, all in `test/features/projects/worker_project_repos_test.dart` (real-worker bookmark-tracking reads, a file and a feature this story does not touch; it runs against the cdylib the gate builds). Left for the loop's final gate.
- No Rust, FFI or schema change: no cargo, codegen or parity checks apply.
- Not done: the Widgetbook/Marionette visual check against the DS cards.

**Verification notes (follow-up review, 2026-10-31, gate rule: targeted checks only):**
- `flutter test test/features/graph/graph_stacks_test.dart` (app) — 31 passed; with the two code fixes reverted, the two new regression tests fail (checked), then pass again with them restored.
- `flutter test test/features/graph test/widgetbook test/l10n` (app) — 802 passed.
- `dart analyze --fatal-infos`, `dart format --set-exit-if-changed .` (app) — clean.
- No Rust, FFI, schema or zanshin_settings change: no cargo, codegen, parity or zanshin_settings checks apply.

## Auto Run Result

Status: done

**Summary.** The view side of 4.13's stacks. `GraphLayout` gains run accessors (folded members stay in the node index with no position; a stack node is keyed `stack:<oldest>`; `placeOfKey` maps a folded key to its stack). `RecordedGraphLayout` reads the engine's format 4, and record-graph.mjs records 34 stack states of the design samples, which `stackRecordingFor` picks per request until 10.12. The stack card is a slotted RenderBox (offset layers, badge, newest subject, id range, authors, date range, ⚠, hatch, focus ring, semantics with tap/expand). The hover list opens after 380 ms below or above the card (8-row cap, lazy rows) with member callouts after 180 ms. The bracket is painted with the edges, with a translucent hover strip and an opaque collapse button. A toggle is one request with the anchor member kept in place, and the members fade in on expand. Toggles persist per repository on `ProjectEntry` through `GraphStackStore` / `ProjectStackStore`. Go-to on a folded member reopens its run; Enter/Space expand; members of an expanded run carry a VoiceOver collapse action.

**Files** (commit 873274ce6d289205829728b4729f9ac4e58635fc).
- `app/lib/src/features/graph/graph_layout.dart` — run accessors, `graphStackKey`, `graphStackAnchorKey`.
- `app/lib/src/features/graph/recorded_graph_layout.dart` — format-4 parse, stack nodes, runs.
- `app/lib/src/features/graph/vertical_layout.dart`, `layout_invariants.dart` — folded nodes skipped.
- `app/lib/src/features/graph/graph_viewport_render.dart` — `placeOfKey` for rects, pins, anchor, reveal; `holdAnchor`.
- `app/lib/src/features/graph/graph_stack_card.dart` (new) — the stack card.
- `app/lib/src/features/graph/graph_stack_popover.dart` (new) — member list and callouts.
- `app/lib/src/features/graph/graph_canvas.dart` — stack cards, list, bracket and button, entering fade, pending/pulse via `placeOfKey`.
- `app/lib/src/features/graph/graph_card.dart`, `graph_card_render.dart` — `onExpandStack` / `onCollapseStack`, the members' collapse action.
- `app/lib/src/features/graph/graph_view_model.dart`, `graph_view.dart`, `graph_preferences.dart`, `graph_ports.dart`, `graph_content.dart`, `graph_stack_store.dart` (new) — toggles, persistence, reveal, keyboard, member content.
- `packages/zanshin_settings/lib/src/model/projects_settings.dart` (+ generated) — `expandedStacks`, `collapsedStacks`.
- `app/lib/l10n/app_en.arb` (+ generated) — three strings.
- `spikes/graph-layout-ab/tools/record-graph.mjs`, `app/widgetbook/graph/graph_stack_recordings.g.dart`, `stack_recordings.dart`, `app/widgetbook/folders/graph.dart` — recordings and catalogue fakes.
- Tests: `graph_stacks_test.dart` (new), `recorded_graph_layout_test.dart`, `vertical_layout_test.dart`, `graph_controls_test.dart`, `graph_harness.dart`, zanshin_settings `projects_settings_test.dart`.

**Review.** 31 findings (high 0, medium 4, low 22, false 5). Patched: 4 medium (VoiceOver collapse action, `GraphPreferences.init` store-forwarding test, focus moved off a folded member, go-to on a folded key during an in-flight request) and 5 low (notify on collapse, popover y clamp, `shouldRelayout` factor, pending look via `placeOfKey`, Space test). Deferred: none. Rejected with reasons in the triage log: unpruned and default-equal toggles, all-member content loading (the story's item 6), per-notification recompute, the house error pattern, inert rows (design), coverage breadth, other keep-open sources, duplicated generated inputs, still-folded pulse, scrolled callout, run validation, the dev-tool TypeError, the hatch test, scale recordings (Design Notes), and 5 false (localised spoken text, no production mount until 10.12 ×2, popover state per key, `holdAnchor` before size).

**Follow-up review:** recommended `true` — four medium entries were patched in one pass (patched counts: high 0, medium 4, low 5); the unverified risk is the keyboard-focus and in-flight go-to paths, which the patches changed after the review read them.

**Residual risks.** No production mount yet (10.12 wires `GraphView`, the real engine and `ProjectStackStore`); the catalogue's stack states are recorded only (deeper toggle combinations take the nearest state); a toggle's anchor is clamped at the scroll range's edges; keyboard collapse exists only through VoiceOver actions (no shortcut); the Marionette visual check was not run; 5 real-worker tests in `worker_project_repos_test.dart` failed in the whole-app run (untouched by this story; for the loop's gate).

### Follow-up review pass (2026-10-31)

Status: done

**Summary.** A fresh four-layer review of the whole story diff (34 findings). Two fixes and three tests.
- `app/lib/src/features/graph/graph_view_model.dart` — `_fail` clears `_enteringNext` and `_pulseOnLand`, so a failed expand or go-to no longer fades or pulses with a later layout.
- `app/lib/src/features/graph/graph_canvas.dart` — the collapse button sits at the centre of the bracket strip's visible part, so a run taller than the view keeps it reachable.
- `app/test/features/graph/graph_stacks_test.dart` — tests: collapse during an in-flight request notifies at once; a failed expand leaves no fade; `ProjectStackStore`'s failed write keeps the toggles; a tall run's button is on screen.
- `_bmad-output/implementation-artifacts/deferred-work.md` — the two deferred items mirrored.

**Review.** high 0, medium 2, low 22, false 8, maybe-false 2. Patched: 2 medium (tall-run button, in-flight collapse notify test) and 2 low (`_fail` clearing, save-failure test). Deferred: the DS visual check not run (medium, unverified) and the pending-folded-member render test (low). Rejected with reasons in the triage log, many carried from the first pass.

**Follow-up review:** `false` — a follow-up pass that patched no high (patched counts: high 0, medium 2, low 2).

**Residual risks.** Unchanged from the first pass, plus: plain-keyboard collapse is still VoiceOver-only (open question for Ralph); the DS visual check is still not done.

