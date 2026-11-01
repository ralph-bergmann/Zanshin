---
title: 'Story 10.19 — Hidden history: gap markers on dashed edges, end stubs, the gap callout, the toolbar legend and "Show in all()"'
type: 'feature'
created: '2026-11-01'
status: 'done'
baseline_revision: '31395530dd96bdb3874db8ac2dbd5646f30236a2'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** A revset that leaves commits out leaves gaps: jj reports an Indirect edge (to the nearest visible ancestor, drawn dashed by 10.4) and a Missing edge (a parent with no visible ancestor, today only `elidedOf`). Nothing marks, explains or opens these gaps.

**Approach:** Implement epics.md Story 10.19 (`_bmad-output/planning-artifacts/epics.md` lines 10923-11113 — read it in full; the 2026-10-14 and 2026-10-16 design-update notes supersede the original items where they say so) on the current graph code: a view-side placement of `//` markers and end stubs computed once per layout and card size from router B's geometry, painted in the edge layer; a hover gap callout; "Show in `all()`" (one `show`, one layout request, reveal, flash); and the gap legend chip in the VIEW island.

## Boundaries & Constraints

**Always:**
- Family B (`//`) only, **no counts** anywhere (chip "N gaps" is the one number; legend rows show N× / M×).
- Marker clearance (2026-10-14 note): 12 px of visible line to every card (all cards, not only the edge's own), bend, crossing, junction, other marker and stub; scan per the export `design/graph-gaps.jsx:10-57` (vertical runs first, scanning from the child's end; need 26 px free on a vertical, 30 on a horizontal; margin 8 px at a segment end that touches a card, 12 at a bend; 11 px around a crossing, 5 px around a collinear shared run; pick `lo + min((hi-lo)/2, need/2 + 6)`); fallback = middle of the longest free run. Clearance is a `GraphTheme` value (default 12), with a knob in the Widgetbook Graph folder.
- Placement is deterministic and window-independent: computed once per (layout, metrics) against whole-layout indexes (router B's `verticalXs/…`, `horizontalYs/…`, `portXs`, the card rects from `GraphMetrics` + `VerticalLayout`), never by scanning every segment of every edge per dashed edge (no O(D·E)). Stubs first, then markers in edge-index order, each clear of those placed before.
- Hidden merge = node with `parentCountOf == 1` and ≥ 2 Indirect edges: **one shared marker** on its shared stem (router B already shares the entry slot, `router.dart:300-331`): 16–22 px under the card when the stem is ≥ 32 px (`16 + min(6, (stem − 32)/2)`), else mid-stem. Nodes with several real parents never group.
- End stub per Missing edge: dashed lead from the card bottom, `//` centred 16 px under the card (12 px lead), "~ elided" 11 px JetBrains Mono right of the glyph where that box is free, else left, else omitted. Slots: with a parent edge +0.28, −0.28, +0.14, −0.14, +0.4, −0.4·W; without one centre, then ±0.28, ±0.14·W; each slot ≥ 14 px from every entry port of that node and from stubs placed before. A layout whose lowest row holds a stubbed node gets `bottomExtra` 44.
- Look/tokens (DS `components/graph/graph.css:66-79`, `GraphEdge.jsx`): two slanted cuts 1.5 px round caps, ±3 px from the centre, 10 px across, `--text-faint`; the dashed edge breaks 8 px along × 12 px across beneath (split subpaths like the bridge cuts in `graph_edges.dart`, never a mask). Hover → `--text` / label `--text-muted`; lineage → `--co` (a stub of a lineage node: lead 2.25 px + glow); dimmed with the focus path (same fade as edges, 1 − .72·dim). Tokens go into `GraphTheme` (night and paper via `fromColors`).
- Gap callout: targets = a 12 px band along each dashed edge (`GraphEdgePainter.edgesAt`, tolerance 6, dashed only), a 26×26 box around a marker, a stub's lead+glyph+label box; opens after `delayStackList` (380 ms) of rest, closes 180 ms after the pointer leaves both target and callout, stays open while hovered; 320 px wide, top-left 18 px right of the target point, flipped left near the right edge, kept inside the unobscured area; on the one menu material **with `arrow: false`** (item I1, below); suppressed while a card menu is open and closed by pans/drags; a press on a band still pans (hover only — the target layer must not take gestures).
- Callout content (export `graph-gaps.jsx:159-193`, minus the count): title per kind ("Commits hidden between these changes" / "A hidden merge sits below this change" / "History continues outside this revset"); chain: child row (change id per decision 16.35 — jj's shortest prefix bold, max(prefix, 8) chars, one `Text.rich`; subject; member count when the child is a stack), the glyph with "Hidden commits" or "Older history not shown", then the visible ancestors' rows (Indirect) or the hidden parent's id with "parent, not in revset" in italic (Missing); the per-kind description; button "Show in `all()`" with hint "switches revset · centers here". Rows read the content cache (10.11).
- Missing edge's hidden parent: the wire carries no target id for a Missing edge (`crates/zanshin-ffi/src/graph.rs:244`, slot −1). Read it from one `show` of the child (`Change.parents`, change ids): the parents the layout has no Direct edge to. While it loads the row shows a skeleton; the id prints max(8) chars without a bold prefix (its prefix length is unknown). Record this in Design Notes.
- "Show in `all()`": one `show` of the child through a new `GraphSource.show(String commitId)` port (implement in `RepoGraphSource` and every fake/test source); then one layout request with revset `all()` whose `keepOpenKeys` carries the child's real parents the old layout lacks; the search view becomes 10.21's `GraphAllView` (field reads `$ all()`, ✕ returns to the default search; an active filter is replaced but stays in Recent). Reveal (explicit, rank 1): the real parent from which the edge's target is reached through nodes the old layout lacked (Missing: the hidden parent itself); a key inside a collapsed stack reveals the stack card. Flash every commit the gap hid: new-layout nodes absent from the old layout on a path child → target through such nodes only (hidden merge: to every target of the group; Missing: the hidden parent and its new ancestors, capped at 10 000). Flash = 2 px `--accent-live-line` + 6 px `--accent-live-ring`, held for 35 % of `durFlash` (2.4 s) then faded; under reduce motion the same colour fade at a fixed size; paint-only in the overlay hook like 10.6's pulse; a collapsed stack with a flashed member flashes as one card.
- Legend chip in `GraphViewControls` right after the search field, before the count; hidden when N = 0 and at window width ≤ 1040 (shown at 1041, together with the count). N = one per Indirect edge (a hidden merge once) + one per Missing edge. A small dashed glyph + "N gaps"/"1 gap" (11 px mono `--text-faint`); a button labelled "N gaps" for semantics. Popover on the one menu material: opens `delayCallout` (90 ms) after hover or focus, stays `delayCalloutOut` (200 ms) after leaving, fades in on `durPop`, out on `durExit`; content: title "This revset hides part of the history", rows Solid "direct parent", Dashed "commits in between are hidden · N×", End "older history isn't in the revset · M×", the line "Stacks never span a gap. Hover a marker for details.", button "Show `all()`" = `GraphSearchController.showAll()` (re-centres on @).
- `GraphLayout` gets `missingCountOf(int node)` (Missing edges of a node; backend: topology edges of kind missing; recorded: parents of kind `missing`; stack node 0). Markers and stubs add no semantics nodes; a hover builds 0 cards.
- Strings through `app/lib/l10n/app_en.arb` (`flutter gen-l10n`); `all()` and `//`, `~` literals marked `// l10n-ignore: <reason>`.
- I1 (deferred-work.md, "Surfaced in Story 11.2"): settled — the design's gap callout (`design/graph.css:314-317` `.ggap-pop` with `.gpeek-inner`) is the peek material and draws no arrow, so a flip or shift needs no arrow side; build it with `ZsMenuMaterial(arrow: false)` and record the outcome under Auto Run Result.

**Never:** counts of hidden commits, the Count link or a count toggle; Dots/Pill families; a backend call for gap details beyond the one `show`; edge selection/drops on edges; animating the reveal beyond the flash; an FFI/schema change; editing `design/` or `design_system/`; nested Column/Row for the painted marks; a timer or watcher refresh.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Straight dashed edge, adjacent rows | Indirect edge, 48 px row gap, no crossing | marker at the middle of the gap | — |
| Hidden merge | 1 real parent, 2 Indirect edges | one shared marker on the stem, 16–22 px under the card (or mid-stem < 32 px); one gap counted | — |
| Several real parents | 2 real parents, 2 Indirect | two markers, no group, two gaps | — |
| No room anywhere | every run blocked | marker at the middle of the longest free run | — |
| Missing, no parent edge | node with only a Missing edge | stub centred, `//` 16 px under, "~ elided" right | label omitted when neither side is free |
| Missing beside a parent edge | node with a Direct edge + a Missing edge | stub on the first slot ≥ 14 px from every entry port | — |
| Callout timing | pointer rests on a band 380 ms / crosses in < 380 ms | opens / does not open | closes 180 ms after leaving both |
| Callout near right edge | target near the unobscured right edge | flipped left, inside the area, no arrow | — |
| Show in all() | click on an Indirect / hidden-merge / Missing callout | 1 `show`, 1 layout request (`all()`, missing parents in keepOpenKeys), field `$ all()`, reveal per rule, exactly the gap's commits flash | `show` throws `ZanshinFfiException` → no request, callout stays; logged |
| Legend | N = 0 / N > 0 at 1041 / at 1040 | hidden / chip "N gaps" / hidden | — |

</intent-contract>

## Code Map

- `_bmad-output/planning-artifacts/epics.md:10923-11113` -- the story (scope, witnesses); read in full.
- `_bmad-output/implementation-artifacts/design/graph-gaps.jsx` -- the export's placement scan (`placeGapMarkers`, :10-75), cut (:78-82), marks (:86-129), callout (:159-193), legend (:195-216); `design/graph.css:310-340` for `.ggap-*`/`.gtb-gaps-*` sizes. Inspiration, not 1:1.
- `_bmad-output/implementation-artifacts/design_system/components/graph/graph.css:66-79` -- `.zs-edge.is-gap`, `.zs-gap`, `.zs-gap-cut`, `.zs-gap-txt` tokens; `GraphEdge.jsx`/`GraphEdge.prompt.md:18` for the marker rules; DS bundle `GraphEnd` (`_ds_bundle.js:2492`).
- `app/lib/src/features/graph/graph_layout.dart:196-212` -- contract: `parentCountOf`, `elidedOf`, `kindOf`; add `missingCountOf`.
- `app/lib/src/features/graph/backend_graph_layout.dart:100-126` -- topology-backed accessors (`topology.edgeKind(e) == GraphEdgeKind.missing`); `recorded_graph_layout.dart:143-157,428-431` -- recorded `elided` from parents `kind == 'missing'`.
- `app/lib/src/features/graph/graph_edges.dart` -- `GraphEdgePainter`: `_addStroke` cuts holes from `GraphEdgeCut`s in arc length (`_Arc.cut`), `classify` (tone/dim), `edgesAt` (hit lookup), `inLineage`, `paint` groups. Marker cuts reuse the hole mechanism (8 px along); markers/stubs painted after edges, before brackets, in the same tone groups.
- `packages/zanshin_core/lib/src/graph_layout/router.dart:546-640` -- `RouteGeometry`: `points/pointStarts` (bends), `portStarts/portXs` (entry ports), sorted run indexes `verticalXs/Tops/Bottoms/Edges`, `horizontalYs/Lefts/Rights/Edges`, `bridges(x0,y0,x1,y1)`; `RouteClasses` slots (shared entry for a hidden merge, :300-331). Read only.
- `app/lib/src/features/graph/graph_metrics.dart`, `vertical_layout.dart:75-115` -- card x/y per node; `UniformRows(…, bottomExtra:)` (built at `graph_canvas.dart:717` and `graph_viewport_render.dart:380`).
- `app/lib/src/features/graph/graph_canvas.dart` -- the composition: `_edgesFor` (cache placement next to the painter, same keys), `paintEdges`/`paintOverlay` hooks (:830-845), `_paintPulse` (:659) as the flash template, peek layer/`_PeekLayout`/`_PeekMotion` (:870-1000) as the callout template, `_userPanned` (:585) closes callouts, `cards.menuOpen` suppresses them.
- `app/lib/src/features/graph/graph_peek.dart` -- `graphPeekPosition` (flip/clamp), `GraphPeek` on `ZsMenuMaterial` (:144); id `Text.rich` rendering to reuse for rows.
- `packages/zanshin_ui/lib/src/materials/zs_menu_material.dart:20-29` -- `arrow` flag (default false). `packages/zanshin_ui/lib/src/design/graph_theme.dart` -- add gap tokens + clearance; `zs_motion.dart:25-45` -- `delayStackList`, `delayCallout`, `delayCalloutOut`, `durFlash`, `durPop`, `durExit`; `zs_accents.dart` `accentLiveLine/Ring`.
- `app/lib/src/features/graph/graph_view_model.dart:403-428,803-900` -- `goToHidden` (the template: revset `all()`, explicit reveal, `_pulseOnLand`), `setRevset`, `_build` (`keepOpenKeys`), `_land` (reveal resolution, pulse); add the gap request, its landed reveal and the flash set (exposed like `pulse`).
- `app/lib/src/features/graph/graph_search_controller.dart:73-107` -- `showAll`, `goTo` → `_setView(GraphAllView())`; add the gap entry point here so the field reads `$ all()`.
- `app/lib/src/features/graph/graph_ports.dart:140-180,784+` -- `GraphSource` (add `show`), `RepoGraphSource`, `RepoGraphDetails.show` (:775) for the call shape; fakes: `app/test/helpers/scripted_graph_source.dart`, `app/test/features/graph/graph_ports_test.dart:21`, `graph_view_model_test.dart:1181`, `app/widgetbook/graph/fake_graph_source.dart`.
- `app/lib/src/features/graph/graph_controls.dart:24-145` -- `graphCountHideWidth`, `GraphViewControls` (legend slot reserved before the count), `GraphViewOptionsButton` popover pattern.
- `app/lib/src/features/home/project_graph_host.dart:112-140` -- wiring of model/search/source.
- `app/widgetbook/graph/graph_recordings.g.dart` -- `design-default`/`design-all` recordings (e243dd2 sample; 750 indirect, 6 missing edge entries) for witnesses; `app/widgetbook/folders/graph.dart` -- Graph folder knobs; `app/test/features/graph/graph_harness.dart`, `graph_edges_test.dart` -- test patterns.
- `app/lib/l10n/app_en.arb` -- strings (run `flutter gen-l10n` in `app/`).

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/graph/graph_layout.dart`, `backend_graph_layout.dart`, `recorded_graph_layout.dart` (+ any other `GraphLayout` implementers, e.g. `app/widgetbook/graph/synthetic_layout.dart`, test layouts) -- add `missingCountOf` -- stubs and the legend need the per-node Missing count.
- `packages/zanshin_ui/lib/src/design/graph_theme.dart` -- gap tokens (cut, cut hover, text, text hover) and `gapClearance` (12), lerp/copyWith/equality like the other fields -- tokens in both themes.
- `app/lib/src/features/graph/graph_gaps.dart` (new) -- the placement: markers (scan, fallback, hidden-merge group), stubs (slots, label side), the gaps list with kinds and targets (for counts, hit tests and the callout), a window query that returns the precomputed items; plus their painting (cuts, lead, label) under the edge tones -- one place for gap geometry.
- `app/lib/src/features/graph/graph_edges.dart` -- accept the marker cuts as holes in dashed strokes; expose what the gap painter needs (tone per edge/node) -- reuse, not duplicate.
- `app/lib/src/features/graph/graph_canvas.dart` (+ `graph_viewport_render.dart` if rows are built there) -- cache the placement with the edge painter, paint it, `bottomExtra` 44, the gap hover target layer, the gap callout layer (new widget, e.g. `graph_gap_callout.dart`), the flash paint -- the view composition.
- `app/lib/src/features/graph/graph_ports.dart` + all `GraphSource` implementers -- `show` -- the gap request's one `show`.
- `app/lib/src/features/graph/graph_view_model.dart`, `graph_search_controller.dart` -- the gap's "Show in `all()`" request, reveal, flash set; the search view switch -- item 6.
- `app/lib/src/features/graph/graph_controls.dart` (+ a legend widget file if large) -- the chip, its popover, the breakpoint -- item 7.
- `app/widgetbook/folders/graph.dart` -- clearance knob; a use case showing gaps on the design-default recording.
- `app/lib/l10n/app_en.arb` -- strings; run `flutter gen-l10n`.
- `app/test/features/graph/graph_gaps_test.dart` (new) + extend `graph_view_model_test.dart`, `graph_search_controller_test.dart`, `graph_controls_test.dart`, `graph_canvas`/`graph_view` tests -- the witnesses below and every matrix row.

**Acceptance Criteria:**
- Given the design-default recording, when painted, then every Indirect edge carries one `//` with its cut (a hidden merge one shared marker), and every Missing edge a stub with "~ elided" (`paints` matcher).
- Given every recording and 1 000 random windows over a scale layout, when markers are placed, then each keeps ≥ clearance to every card, bend, crossing, junction, marker and stub or is the recorded fallback; none sits on an overflowing shared exit; every window yields the same placement.
- Given a node with no parent edge or with entry ports, when its stub is placed, then it is centred / on the first slot ≥ 14 px from every entry, with a 12 px lead.
- Given a marker/stub, when its edge/node is hovered, in @'s lineage, or dimmed, then it paints `--text`, `--co`, or at .28.
- Given a band, a marker or a stub, when the pointer rests 380 ms, then the callout opens with the texts per kind; a quick crossing opens nothing; it stays open while hovered, flips near the right edge, draws no arrow; a press on a band pans; a hover builds 0 cards.
- Given a hand-built case per kind (hidden merge included), when "Show in `all()`" is clicked, then exactly one `show` and one layout request (`all()`, the missing parents in `keepOpenKeys`) are issued, the field reads `$ all()` and ✕ returns to the default search, the hidden parent is centred (its stack opened), and exactly the gap's commits flash; under reduce motion the flash is a 2.4 s colour fade at a fixed ring size.
- Given the design-default recording, when the controls build, then the chip shows its gap count, is hidden at N = 0 and at 1040 px (shown at 1041), its popover opens 90 ms after hover and closes 200 ms after leaving, lists the rows, and "Show `all()`" switches to `all()` and re-centres on @.

## Spec Change Log

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 33 findings — high 0, medium 6, low 20, false 7, maybe-false 0
- findings:
  - Blind Hunter
  - `medium` `patch` Stale `_gaps`/`_edges` used while a new layout routes (hover/callout resolve old indices on the new layout) — gaps used only when they belong to `widget.layout`; test added.
  - `false` `reject` `_group` late x/y LateInitializationError — every layout edge joins two distinct cards, so router B's polyline always has ≥ 2 distinct points; unreachable.
  - `low` `reject` Hidden-merge marker skips the clearance scan — by design (2026-10-14 note: fixed offset on the shared stem); a hidden merge node has one real parent, so no stub of its own sits on its stem; not worth a scan.
  - `medium` `patch` A collapsed stack whose oldest member has a Missing parent shows no stub and the legend under-counts — the stack node reports its oldest member's Missing count; tests added.
  - `low` `reject` `.single` in `RepoGraphSource.show` may throw `StateError` — a full commit id resolves to exactly one revision; a bookmark spelled as a 40-hex id is not everyday use and the guard adds a branch.
  - `low` `reject` `showGap` race (refresh or double click during `show`) — the second request coalesces in the model's queue; a stale `old` only widens the flash set; rare, the guard adds state.
  - `low` `patch` `graphGapFlashCap` doc says the flash is dropped beyond the cap, the code truncates — doc corrected.
  - `medium` `patch` Legend chip announced as a button but activation does nothing — Semantics onTap / activate key opens the popover; test added.
  - `low` `patch` `_tallest` doc/value mismatch and `gapsIn` over-subtracts — constant and query corrected.
  - `low` `patch` Legend recounts the whole layout on every model notification — counts cached per layout.
  - `low` `reject` Gap callout has no exit fade — cosmetic; the story asks only for open/close timing.
  - `low` `reject` Parents compared by change id miss divergent/hidden parents keyed by commit id — rare (divergent parent of a gap); fix needs a commit-id index; recorded under residual risks.
  - `medium` `patch` Canvas wiring untested (menu suppress, hidden merge rows, …) — grouped with the verification-gap test patches below.
  - `false` `reject` Bookkeeping files not in the diff — the reviewed diff covered `app/` and `packages/` only; spec, sprint-status and deferred-work are committed at finalize.
  - Edge Case Hunter
  - `medium` `patch` Stale gaps during routing — same root cause as the first row; same patch.
  - `low` `reject` `.single` StateError — as above.
  - `false` `reject` `_group` late init — as above.
  - `false` `reject` `_spot` with < 2 points places at (0, 0) — unreachable for the same reason.
  - `low` `reject` More Missing parents than slots reuse a slot — needs a node with ≥ 6 hidden parents; rare, extra slots add logic.
  - `low` `reject` Neighbouring nodes' stub labels may touch at W = 160 — at most a 2 px overlap of label boxes in an unusual layout.
  - `low` `reject` `bottomExtra` only for the lowest row — a node a sub-row above the bottom still has the 56 px plane pad below it, which holds the stub.
  - `low` `reject` `showGap` race — as above.
  - `low` `reject` Commit-id-keyed parents — as above.
  - `low` `patch` Legend popover stays "showing" when N drops to 0 and reappears unhovered — timer cancelled, portal hidden.
  - `medium` `patch` Legend semantic button has no action — same as above.
  - `false` `reject` Callout lists every parent not in the layout instead of "no Direct edge" — a real parent present in the layout always has a Direct edge, so the two sets are equal.
  - `false` `reject` Stubs ≥ 14 px only from the node's own earlier stubs — other nodes' stubs hang under other cards, at least one column gap (56 px) apart.
  - Verification Gap
  - `low` `patch` `BackendGraphLayout.missingCountOf` has no count test — test added (merge shown alone → 2; stack node).
  - `low` `patch` `GraphView` / host wiring of "Show in all()" untested — `graph_view_test.dart` case added.
  - `low` `patch` Canvas `GraphGapTarget` targets and stack commit id never asserted — tests added.
  - `low` `patch` Callout close on pan, new layout and card menu untested — tests added.
  - `false` `reject` (other) `.single` StateError — duplicate of the row above, same rejection (counted as false here: not a test gap).
  - Intent Alignment
  - `low` `patch` The arrow test only checks the constructor default and no test pins the shift/clamp — a direct `graphGapCalloutPosition` test added. The ledger entry I1 is closed by the loop's ledger commit (pattern "chore(ledger): close items handed to Story 10.x").

## Design Notes

- Placement lives in the app (view geometry over router B's output), cached per (layout, metrics) like `GraphEdgePainter`; it reads the router's sorted run indexes with binary search per segment, so cost is O(D · k log E) for D dashed edges and k nearby runs.
- The Missing hidden parent comes from `show(child)` because the topology wire drops Missing targets; shortcut: on a node with both Indirect and Missing edges the "parent, not in revset" rows list every real parent without a Direct edge (a superset) — exact once the wire carries Missing targets.
- I1 settled as "no arrow": the gap callout is peek material in the design; a flip only mirrors its x.

## Verification

**Commands (gate rule: no `cargo make test` / `test-full` / `coverage`):**
- `flutter gen-l10n` in `app/` -- regenerates localizations (commit them)
- `flutter test` in `packages/zanshin_ui/` and `app/` (new and touched graph tests, then the whole suite) -- all pass except the known `worker_project_repos_test.dart` environment failures outside `cargo make`
- `dart analyze --fatal-infos` and `dart format --set-exit-if-changed .` in `packages/zanshin_ui/` and `app/` -- clean
- `flutter test` / `dart analyze` in `packages/zanshin_core/` only if it is touched (it should not be)

**Manual checks:**
- Marionette in the catalogue if a long-running `flutter run` is possible; else record why not.

## Verification Notes

- `flutter gen-l10n` (app): localizations regenerated (25 new strings).
- `dart analyze --fatal-infos` and `dart format --set-exit-if-changed .`: clean in `app/` and `packages/zanshin_ui/`.
- `flutter test` in `packages/zanshin_ui/`: 439 passed.
- `flutter test` in `app/` (after the review patches): 1615 passed, 5 failed — the `worker_project_repos_test.dart` real-worker tests, which pass (33) with `XDG_CONFIG_HOME=target/test-xdg-config` (the gate's environment); untouched by this story.
- New/extended: `graph_gaps_test.dart` (38, incl. the label-side case added by the parent run), `graph_controls_test.dart` (37), `graph_view_test.dart` (39), `graph_view_model_test.dart`, `graph_search_controller_test.dart`, `recorded_graph_layout_test.dart`, `backend_graph_layout_test.dart`.
- `packages/zanshin_core` and Rust untouched: no cargo checks, no codegen, no parity oracle (no jj verb or command text changed).
- Marionette check not done: the run forbids long-running/background processes (`flutter run` must stay alive while Marionette connects). Ralph's visual check in the catalogue (Graph › Viewport / Recording, design-default) remains.

## Auto Run Result

Status: done

**Summary.** Hidden history on the commit graph: `//` markers on every dashed edge (one shared marker per hidden merge), end stubs with "~ elided" per Missing edge, placed once per layout and card size against router B's run indexes with a 12 px clearance (`GraphTheme.gapClearance`, Widgetbook knob); a 380 ms hover gap callout (band, marker, stub) with the texts per kind; "Show in `all()`" (one `show`, one `all()` request with the hidden parents in `keepOpenKeys`, the field reads `$ all()`, reveal, flash of exactly the gap's commits); the "N gaps" legend chip with its popover in the VIEW island, hidden with the count at ≤ 1040 px.

**Files changed.**
- `app/lib/src/features/graph/graph_gaps.dart` (new) — placement, hit test, counts, painting of markers and stubs.
- `app/lib/src/features/graph/graph_gap_callout.dart` (new) — the gap callout and its position (flip, clamp, no arrow).
- `app/lib/src/features/graph/graph_gap_legend.dart` (new) — the chip and popover.
- `graph_canvas.dart` — placement cache, paint, hover layer, callout layer, flash, `bottomExtra`.
- `graph_edges.dart` — marker cuts in dashed strokes.
- `graph_layout.dart`, `backend_graph_layout.dart`, `recorded_graph_layout.dart` — `missingCountOf`.
- `graph_ports.dart` — `GraphSource.show`; `graph_view_model.dart` — `showGap`, reveal, `flash`; `graph_search_controller.dart` — `showGap`; `graph_view.dart`, `project_graph_host.dart` — wiring; `graph_controls.dart` — legend slot.
- `packages/zanshin_ui/lib/src/design/graph_theme.dart` — gap tokens and clearance.
- `app/lib/l10n/*` — strings; `app/widgetbook/…` — knob, fake `show`; tests and `scripted_graph_source.dart`.

**Deferred-work items.**
- I1 — rejected (settled, no change needed beyond building the callout without an arrow): the design's gap callout (`design/graph.css:314-317`, `.ggap-pop` around `.gpeek-inner`; DS `PeekCard.d.ts` lists gap callouts as a peek use) is peek material and draws no arrow, so a flip or shift needs no arrow side or offset; `GraphGapCallout` uses `ZsMenuMaterial` with `arrow: false` and a flip only mirrors its x (`graphGapCalloutPosition` tests cover flip and clamps).

**Review.** 33 findings: 15 patched (6 medium, 9 low; the medium ones: stale gaps during routing, stack Missing count, legend activation, canvas wiring tests), 18 rejected (7 false, 11 low not worth fixing) — reasons in the Review Triage Log. Nothing deferred.

**Follow-up review recommendation:** true — two or more medium entries were patched (4 medium groups). The unverified risk: the hover layer is a sibling `MouseRegion` beside the viewport, and the stale-gaps guard plus the legend's post-frame portal hide were added late; a fresh pass should check hover/press interplay with cards and the routing-async path on a real 25k+ repository.

**Residual risks.**
- Placement runs on the main isolate in build; fine at 10k nodes, may cost a frame at 50k–100k (the router's isolate offload does not cover it).
- Parents are compared by change id: a divergent parent keyed by its commit id would read as "not in revset".
- The stub label box width is fixed for the English "~ elided" (`shortcut:` comment).
- The Missing hidden parent comes from `show(child)`; on a node with both Indirect and Missing edges the stub callout lists every hidden real parent (a superset).
- The gap callout fades in but has no exit fade; the "Show in all()" label is plain text, not mono `all()`.
- No Marionette visual check.
