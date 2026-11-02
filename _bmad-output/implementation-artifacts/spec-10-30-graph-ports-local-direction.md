---
title: 'Story 10.30 follow-up — graph ports by local direction, revset without_span coverage'
type: 'bugfix'
created: '2026-11-02'
status: 'done'
baseline_revision: 'e9979c25e13aee9bb7ea15f0fd8bf988b18abb5a'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      A card edge's only line leaves the centre when it loses the column tie-break (20 of 8710 lone exits on the 10k free layout).
    evidence: |-
      The literal per-edge rule gave 342 collinear overlaps; the intent's "fix it in the tie-breaking" was read as carrying the longest-vertical tie-break to the column. Whether Ralph accepts lone lines off-centre in that case (vs. another resolution) is his call; unverified against his intent.
    location: >-
      packages/zanshin_core/lib/src/graph_layout/router.dart _banCollisions
    severity: medium (unverified)
  - summary: >-
      The rtvlvrzr wrong-side mechanism is not reproduced: the old exits' side (c.sides) already equals the side of the turn target in every shape the classifier produces.
    evidence: |-
      The witness ports_by_local_direction_merge_ups_leave_on_the_side_they_turn_to fails on the old code only for the centre/+4 shift; the real layout around rtvlvrzr (rows, columns, kinds) would settle whether the new rule fixes what Ralph saw.
    location: >-
      packages/zanshin_core/test/graph_layout/router_test.dart ports_by_local_direction_merge_ups_leave_on_the_side_they_turn_to
    severity: medium (unverified)
  - summary: >-
      The settle loop stops at 8 passes without reporting leftover collisions.
    evidence: |-
      build() ends the loop on _settlePasses silently; only the app's 10k collinear check would notice (it reports 0 today).
    location: >-
      packages/zanshin_core/lib/src/graph_layout/router.dart build
    severity: low
  - summary: >-
      No router unit test drives the extra-fan-slot branch of the tie-break or a free-layout reach between 0 and gapY.
    evidence: |-
      The four witnesses reach only the centre-ban branch; the 10k free layout exercises both (19 → 0) but no small case pins them.
    location: >-
      packages/zanshin_core/test/graph_layout/router_test.dart
    severity: low
  - summary: >-
      No running check compares the JS port routers (layout.js, graph-layout.jsx) with router.dart.
    evidence: |-
      Only a scratch harness ran graph-layout.jsx on six router-test layouts; spikes/graph-layout-ab/tools/router-oracle.mjs targets the e74ced3 export and the gate never runs it.
    location: >-
      _bmad-output/implementation-artifacts/design_system/ui_kits/desktop/layout.js route
    severity: low
---

<intent-contract>

## Intent

**Problem:** Story 10.30's port rules decide "centre vs fan" by route kind (`kindStraight`) and carry a merge-up exception (`_mergeUpShift`: never centre, 4 px outside the slot). In the running app a card whose only leaving line is a merge-up to a child up-right gets it at +28 instead of the centre (nuwmzrpz, lwyyw…motlm), and rtvlvrzr shows two merge lines leaving left of centre that then run right. Separately, the coverage ratchet fails on `crates/zanshin-jj/src/revset.rs` line 109 (99.89% < 100%): `RevsetError::without_span`'s fall-through for a message without a `<kind> at N: ` head is untested.

**Approach:** Ralph's rule (2026-11-02, decided): only the short stretch right at a card edge decides centre vs fan, whatever the commit or line kind. A line is *vertical* at a port when it runs straight through the band next to that card edge, else it *turns* there and has the side it turns to. One line → centre; several → the vertical line that stays straight longest takes the centre, other vertical lines fan to the side they later turn to, turning lines fan to the side they turn to; no vertical line → centre free. The merge-up exception goes. Item 2: one inline unit test.

## Boundaries & Constraints

**Always:**
- Card placement (rows, columns, left/right) is unchanged; route kinds stay for routing (runs, gutters, bridges, gap markers, detours); only port selection changes. Fan offsets unchanged: 24 out, 16 apart, squeezed to 8, inset 18, overflow shares the outermost.
- "Vertical at the port" is geometric: reach = distance from the card edge to the near side of the band the line first turns in; vertical iff reach ≥ gapY (the turn band does not overlap the band next to that edge); straight = infinite reach. At a parent's top a merge-up's turn band is the one right below its child; fork / merge-adjacent / gutter turn in the band right above the parent. At a child's bottom a fork's turn band is the one right above its parent; merge-adjacent / merge-up / gutter turn in the band right below the child. Side = the x the line turns toward (gutter x for a gutter line, else the entry x at the top / the parent's cx at the bottom); never the opposite side.
- Fan order per side: vertical lines innermost (longest first), then turning lines by distance to their turn target (entries: then the parent's row).
- Two vertical lines never share an x, also across card edges of one column: where the straight stretches (edge through its first turn band) of lines of different card edges overlap on one x, the line that stays straight longer keeps its port (tie: the earlier edge), the other leaves the centre or moves one fan slot outward; two lines that both turn at their edges are left to the tracks. The ports are re-placed until stable (at most 8 passes).
- The 10k synthetic free layout keeps 0 collinear overlaps (app `layout_invariants_test.dart`); recordings, goldens and the router gate tests stay green.
- Every place that states the old rule is brought along in the same change (Code Map). `_ds_bundle.js`'s `// components/graph/GraphEdge.jsx` block is hand-edited to match the new `GraphEdge.jsx` (compiled `React.createElement` style like its neighbours; never a literal `</script` or `<!--`), then `node --check` passes. DESIGN-SYSTEM-SYNC gets entry `#17 · 2026-11-02`.
- Item 2: an inline test in `revset.rs`'s `#[cfg(test)] mod tests`; never lower the coverage baseline.
- Gate rule of this run: targeted checks only — no `cargo make test` / `test-full` / `coverage`.

**Never:** a per-kind exception for ports; changing card placement or fan constants; republishing any artifact; running jj outside own temp dirs; editing `coverage-baseline.txt` downward.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Lone merge-up up-right | parent (col 0, row 0) is the 2nd parent of a child (col 1, row 2) | exit at the parent's centre (was +28) | — |
| Two merge-ups + fork | parent col 1: merge-ups up-right to rows 2 and 3, fork left | longer merge-up at centre, other at +24, fork at −24 | — |
| Straight + merge-up | parent → same-column child row 3 (straight), merge-up into col 1 row 2 | straight at centre, merge-up at +24, no shared x | — |
| Single fork entry | fork (col 0, row 0) → child (col 1, row 2) | entry at the child's centre | — |
| Vertical fork + merge-adjacent entry | child (col 1, row 2), fork from row 0, merge-adjacent from col 2 | fork at centre, merge line at +24 | — |
| Line climbing past a port | merge-up climbing column 0 past a card whose lone fork entry runs down column 0's centre | the longer stays at centre, the other moves to its side | — |
| Spanless parse message | `ParseError` whose message has no `<kind> at N: ` head | `without_span` keeps the message unchanged, span `None` | — |

</intent-contract>

## Code Map

- `packages/zanshin_core/lib/src/graph_layout/router.dart` — **already rewritten in the working tree during planning (keep it, review it, finish its docs):** `_mergeUpShift` removed; `_GeometryBuilder.build()` loops `_entries()` / `_exits()` while `_banCollisions()` moves a line (cap `_settlePasses = 8`), then `_ports()`; `_reaches()` (reach/toward per end), `_place()` (the rule per card edge, with `noCentre*` / `extra*` from the tie-break), `_banCollisions()` (column tie-break). The header comment on `_entryFirst` (`:28-33`) still says "since Story 10.30 the exits' too" — fine; check every doc comment states the new rule. Measured on the 10k synthetic free layout: literal per-edge rule 342 collinear (339 fork-entry vs merge-up-exit in one column, 3 merge-up vs merge-up stub); centre-only tie-break 19; tie-break over all slots incl. turning stubs 0. Lone exits off-centre 567 → 20 (tie-break losers). Router time unchanged (~35 ms JIT both).
- `packages/zanshin_core/test/graph_layout/router_test.dart` — **already updated in the working tree:** `story_10_30_ports…` (lone merge-up up-right at centre), `ports_by_local_direction_*` (vertical entry / single fork / adjacent fork; straight + merge-up; rtvlvrzr sides; climbing past a port), `a_mixed_side_exits_the_longest_merge_up_at_the_centre…` (0 / 24 / 40). All 32 pass.
- `app/test/features/graph/layout_invariants_test.dart:147` — the 10k free collinear check (passes with the working tree).
- `docs/graph-layout.md:1594-1598` — **Ports** paragraph (old rule + `_mergeUpShift` exception) and the **Entries** / **Exits** paragraphs after it (ordering: verticals first).
- `_bmad-output/implementation-artifacts/design/graph-layout.jsx:12-16` (`MERGE_UP_SHIFT`, rule comment), `:199-250` (entries / exits in `routeLines`, `:242`, `:246`) — port the same rule (reach, vertical, side by turn target, column tie-break); no `MERGE_UP_SHIFT`.
- DS `_bmad-output/implementation-artifacts/design_system/`: `components/graph/GraphEdge.jsx:7-24` (`ZS_MERGE_UP_SHIFT`, `GraphPorts.MERGE_UP_SHIFT`, comments), `GraphEdge.d.ts:37-38`, `GraphEdge.prompt.md:15`; `components/graph/fanout.card.html:42`, `lines.card.html:20-45` (rule text; check `graph.card.html`, `days.card.html` for the rule too); `ui_kits/desktop/layout.js:179-191` (`upL`, `GP.MERGE_UP_SHIFT`) → the new rule; `_ds_bundle.js:2269-2509` (the GraphEdge block: `ZS_MERGE_UP_SHIFT` at `:2276`, `GraphPorts` at `:2288-2299`).
- `_bmad-output/implementation-artifacts/design/DESIGN-SYSTEM-SYNC.md:145` — #16 is the last entry; add `#17 · 2026-11-02 · Graph ports by local direction (Story 10.30 follow-up)` in its style (rule, files, "→ Design system: republish" line).
- `crates/zanshin-jj/src/revset.rs:98-111` `without_span`; `:50` `ParseError { reason, detail: Box<RevsetErrorDetail> }`; `:168` `RevsetErrorDetail::bare(kind)` (test helper, `message` empty); tests module at `:1199`.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_core/lib/src/graph_layout/router.dart` -- review the working-tree rewrite against the rules; tidy doc comments; keep behaviour -- item 1 core.
- `packages/zanshin_core/test/graph_layout/router_test.dart` -- keep the witnesses; add one asserting a straight + merge-up pair have different exit x if not already explicit -- item 1 witnesses.
- `docs/graph-layout.md` -- restate Ports / Entries / Exits by local direction, the column tie-break and its numbers; drop `_mergeUpShift` -- doc.
- `_bmad-output/implementation-artifacts/design/graph-layout.jsx` -- same rule in `routeLines`; drop `MERGE_UP_SHIFT` -- prototype.
- DS files (Code Map) incl. `ui_kits/desktop/layout.js` and the hand-edited `_ds_bundle.js` block; `node --check` on `_ds_bundle.js` and `layout.js` -- DS.
- `_bmad-output/implementation-artifacts/design/DESIGN-SYSTEM-SYNC.md` -- entry #17 -- record.
- `crates/zanshin-jj/src/revset.rs` -- inline test: `RevsetError::ParseError` with `message` lacking `" at "` in its head (e.g. `"Syntax error: expected x"` and one with no `": "`) → `without_span()` leaves `message` unchanged and `span == None` -- item 2.

**Acceptance Criteria:**
- Given the matrix shapes, when the router places ports, then each row's x holds (router tests).
- Given the 10k synthetic free layout, when routed, then the route report shows 0 collinear overlaps and passes.
- Given the repo, when grepping for `MERGE_UP_SHIFT` / `_mergeUpShift` / "never takes the centre" outside historical spec/deferred/sync entries, then nothing is found.
- Given `_ds_bundle.js`, when `node --check` runs, then it passes, and its GraphEdge block matches `GraphEdge.jsx`'s `GraphPorts` API.
- Given `cargo test -p zanshin-jj --lib revset`, then the new `without_span` test passes.

## Spec Change Log

## Review Triage Log

### 2026-11-02 — Review pass
- verdicts: 24 findings — high 0, medium 2, low 10, false 8, maybe-false 4
- findings:
  - `[false]` `[reject]` (blind) no regression guard for 0 collinear — `app/test/features/graph/layout_invariants_test.dart:147` asserts `report.passes` (collinear == 0) on the 10k free layout.
  - `[low]` `[defer]` (blind) the extra-fan-slot branch is untested — true for unit tests; the 10k layout exercises it. Deferred (test gaps).
  - `[false]` `[reject]` (blind) stale GL line references — GL cites the `e74ced3` export the router was ported from (router.dart header), not the current prototype.
  - `[low]` `[defer]` (blind) the pass cap is not reported — real; the 10k check would notice. Deferred.
  - `[low]` `[patch]` (blind) bans never reset between passes — deliberate (termination); documented in `_banCollisions`' doc.
  - `[false]` `[reject]` (blind) exact float equality misses lines 1–2 px apart — fan slots are ≥ 8 px apart from one arithmetic path; the invariant itself is exact collinearity.
  - `[false]` `[reject]` (blind) a straight line could lose and draw diagonally — two straight claims on one x never overlap (a straight needs its column free; chained straights touch at a card).
  - `[maybe-false]` `[reject]` (blind) jsx bus mode clashes with the tie-break — study variant C only, not used by the app or the kit; if true only low.
  - `[false]` `[reject]` (blind) a centre-banned vertical with toward == mid always fans right — toward == mid needs parent and child in one column, which only a straight line has, and a straight line never loses.
  - `[low]` `[reject]` (blind) per-pass allocations / `tieOut` zeros — router time measured unchanged (~35 ms JIT for 10k before and after); not worth a refactor.
  - `[false]` `[reject]` (blind) generated bundle edited by hand — the intent requires the hand edit (no build tool).
  - `[false]` `[reject]` (blind) review content incomplete / revset test unrelated — by design: the spec is withheld from blind layers, and item 2 is part of the intent.
  - `[low]` `[patch]` (blind) vague "earlier edge" and a double colon in `lines.card.html` — now "the lower edge index" everywhere; legend reworded.
  - `[maybe-false]` `[defer]` (intent) a lone line leaves the centre when it loses the column tie-break — the intent's "fix it in the tie-breaking" was read as the column tie-break; whether Ralph accepts the 20/8710 cost is his call. Deferred, medium (unverified).
  - `[maybe-false]` `[defer]` (intent) tie-break across edges instead of per-edge-or-defer — same root as above; numbers reported, deferred together.
  - `[false]` `[reject]` (intent) the kind → turn-band table may differ from the routed points — `_Runs._collect` places each kind's runs in exactly those bands.
  - `[maybe-false]` `[defer]` (intent) the rtvlvrzr witness does not reproduce the wrong-side mechanism — confirmed that old `c.sides` equals the turn side for every classifier shape; the real layout would settle it. Deferred, medium (unverified).
  - `[low]` `[reject]` (intent) tests are synthetic, not the running app — router-only change; the app consumes the router and its graph suite (828) incl. the 10k invariants passes; a live check is part of the rtvlvrzr deferral.
  - `[low]` `[defer]` (verification-gap) no running JS↔Dart port parity check — filed disposition defer; a scratch harness matched six layouts. Deferred.
  - `[medium]` `[patch]` (edge) the "both turn" exemption checks reach == 0, not < gapY — fixed to `< gapY` in router.dart, graph-layout.jsx and layout.js; 10k still 0 collinear.
  - `[low]` `[defer]` (edge) the pass cap exits silently — grouped with the blind cap finding; deferred.
  - `[low]` `[patch]` (edge) stale bans after the winner moves — grouped with the reset finding; documented as deliberate.
  - `[low]` `[defer]` (edge) no free-layout fractional-reach witness — grouped with the test-gap finding; deferred.
  - `[medium]` `[patch]` (edge) claim mismatch: spec says turning lines are left to the tracks — grouped with the exemption fix.

## Design Notes

The literal rule alone gives 342 collinear overlaps: a merge-up climbing its parent's column and a fork entering a card higher up in that column run down the same column centre (both are the sole vertical line at their own card edge). That is two vertical lines on one x — exactly what "the longest vertical takes the centre" settles within one card edge — so the same tie-break is carried to the column, kind-agnostic. A tie-break loser that is a card edge's only line is the one remaining case where a lone line is not centred (20 of 8710 lone exits on the 10k layout).

## Verification

**Commands:**
- `flutter test test/graph_layout/router_test.dart` (in `packages/zanshin_core`) -- pass
- `cargo make --allow-private test-core` -- zanshin_core suite passes (real-cdylib worker tests need its setup)
- `flutter test test/features/graph` (in `app`) -- pass, incl. the 10k collinear check
- `dart analyze --fatal-infos` and `dart format --set-exit-if-changed .` in `packages/zanshin_core` and `app` -- clean
- `cargo test -p zanshin-jj --lib revset`, `cargo clippy -p zanshin-jj --all-targets -- -D warnings`, `cargo fmt --all --check` -- pass / clean
- `node --check _bmad-output/implementation-artifacts/design_system/_ds_bundle.js` and `…/ui_kits/desktop/layout.js` -- pass

**Verification notes (run 2026-11-02; gate rule: no `cargo make test` / `test-full` / `coverage`):**
- `packages/zanshin_core`: `flutter test test/graph_layout/router_test.dart` 32 pass; `cargo make --allow-private test-core` 1196 pass (after the review patches); `dart analyze --fatal-infos` clean; `dart format --set-exit-if-changed .` clean.
- `app`: `flutter test test/features/graph` 828 pass (after the review patches), incl. the 10k free-layout route report with 0 collinear; `dart analyze --fatal-infos` clean; `dart format --set-exit-if-changed .` clean.
- `cargo test -p zanshin-jj --lib revset` 28 pass (incl. `without_span_keeps_a_message_without_a_column_head`); `cargo clippy -p zanshin-jj --all-targets -- -D warnings` clean; `cargo fmt --all --check` clean.
- `node --check` on `_ds_bundle.js`, `ui_kits/desktop/layout.js` and (via a scratch copy) `graph-layout.jsx` pass; `_ds_bundle.js` has no `</script` / `<!--`. A scratch harness ran the prototype's `routeLines` on six router-test layouts: all match the Dart results.
- Measured during planning (10k synthetic free layout): collinear 342 (literal rule) → 19 (centre-only tie-break) → 0; lone exits off-centre 567 (old) → 20; router time ~35 ms JIT before and after.
- No codegen (no FFI / schema change), no parity oracle (no jj verb changed), no Marionette check (router-only).

## Auto Run Result

Status: done

**Summary.** (1) Graph ports by local direction in `router.dart`: a line is vertical at a card edge when it runs straight through the band next to it (reach ≥ gapY), else it turns there toward its side; one line → centre, several → the longest vertical one, the rest fan to the side they turn to (vertical innermost); no vertical → centre free. `_mergeUpShift` is gone. The literal rule gave 342 collinear overlaps on the 10k free layout, so the longest-vertical tie-break is carried to the column (a line climbing past another card's port on its x keeps it only if longer; the loser leaves the centre or moves one slot out): 0 overlaps. Witnesses (all pass): lone merge-up up-right at the centre (nuwmzrpz, was +28); rtvlvrzr shape — two merge-ups at 0 / +24, the fork at −24; straight + merge-up both vertical at 0 / +24 (no shared x); single fork into a child's bottom at the centre; vertical fork + merge-adjacent entry at 0 / +24; same-column second parent leaves the centre free; a merge-up climbing past a lone fork entry keeps the centre, the fork moves to +24; mixed exits 0 / 24 / 40; 10k free layout 0 collinear. Docs, prototype, DS (GraphPorts without `MERGE_UP_SHIFT`, cards, UI kit, hand-edited bundle block) and DESIGN-SYSTEM-SYNC #17 brought along — **fixed, commit cbcd74924e274a89a7ab1bd29d5c3f843d4c7e93**. (2) `revset.rs` inline test `without_span_keeps_a_message_without_a_column_head` covers line 109's fall-through — **fixed, commit cbcd74924e274a89a7ab1bd29d5c3f843d4c7e93** (ratchet not run here; the loop's final gate confirms).

**Files.**
- `packages/zanshin_core/lib/src/graph_layout/router.dart` — reaches, `_place`, entries/exits, `_banCollisions`, settle loop, `_ports`.
- `packages/zanshin_core/test/graph_layout/router_test.dart` — witnesses.
- `crates/zanshin-jj/src/revset.rs` — inline test.
- `docs/graph-layout.md` — §14.3 Ports / Entries / Exits.
- `_bmad-output/implementation-artifacts/design/{graph-layout.jsx,DESIGN-SYSTEM-SYNC.md}` — prototype rule, entry #17.
- `_bmad-output/implementation-artifacts/design_system/` — `components/graph/GraphEdge.{jsx,d.ts,prompt.md}`, `fanout.card.html`, `lines.card.html`, `ui_kits/desktop/layout.js`, `_ds_bundle.js` (GraphEdge block).
- `_bmad-output/implementation-artifacts/epic-10-context.md` — the port rule line.

**Review.** 24 findings: patches — medium 1 (turning-line exemption `< gapY`, 3 files), low 2 (accumulating bans documented; tie wording / legend); deferred 5 (lone lines off-centre by the tie-break for Ralph, rtvlvrzr mechanism unconfirmed, silent pass cap, tie-break test gaps, JS↔Dart parity) — mirrored in deferred-work.md; rejected rows carry their reasons in the triage log. Follow-up review recommendation: false (patched: high 0, medium 1, low 2).

**Residual risks.** 20 of 8710 lone exits on the 10k layout sit off-centre (tie-break losers) — Ralph's call; rtvlvrzr's reported wrong side is not reproduced by a test, check in the running app; the DS bundle's manifest hash for GraphEdge.jsx is stale until the republish; coverage ratchet not run here.
