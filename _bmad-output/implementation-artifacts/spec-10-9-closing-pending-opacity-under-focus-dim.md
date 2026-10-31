---
title: 'Story 10.9 closing run — a pending card under a focus dim paints at disabledOpacity × .4'
type: 'chore'
created: '2026-10-31'
status: 'done'
baseline_revision: '4de695d06f5c923d717029ba995f9d84de5678ec'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Item 1 of Story 10.9's deferred list: `GraphCanvas` multiplies a pending card's `disabledOpacity` by the focus-dim factor (`graph_canvas.dart:524-528`), but `graph_view_test.dart` checks the pending fade (:659) and the hover dim (:852) only one at a time, so replacing the product with either factor alone passes.

**Approach:** Test-only: one widget test next to the hover-dim test that hovers a card, starts a gated action on an off-path card, and pins that card's opacity at `disabledOpacity * .4`, an off-path non-pending card at .4 and the hovered (pending-free, on-path) card at 1.

## Boundaries & Constraints

**Always:**
- Drive the real surface: hover through the mouse gesture helper, the action through `model.run` with `_Actions..gate`, opacity read from the viewport's `opacityOf` (as the two existing tests do).
- App rules of project-context.md: SPDX first line, width 120, `dart analyze --fatal-infos --fatal-warnings` clean, no golden tests.

**Never:**
- No production-code change (`graph_canvas.dart` already computes the product); no Rust/FFI/schema change.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Pending off-path under dim | layout a→b→root, c→root; hover b fully dimmed; `GraphAbandon(['c'])` gated | `opacityOf(c)` ≈ `disabledOpacity * .4`; `opacityOf(b)` = 1 | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_canvas.dart:524-528` -- read-only: `opacityOf` = `(pending ? disabledOpacity : 1) * (focus off-path ? 1 - .6 * dim : 1)`; `disabledOpacity` from `ZsMetrics.of(context)` :486.
- `app/test/features/graph/graph_view_test.dart` -- `_Actions` :98 (`gate` Completer); `create({actions})` :158 must run before `pump` (which calls `create()` when not created); hover-dim test :852 (hand layout `a`,`b`,`c`,`root`, `hover(...)`, `pump(ZsMotion.full.durHover)`, `viewportOf`, `leaveAll`, `finish`); pending test :659 (`ZsMetrics.of(tester.element(find.byType(GraphCanvas))).disabledOpacity`, gate completion with an empty `MutationResult`).
- `app/lib/src/features/graph/graph_ports.dart:207` -- `GraphAbandon(ids)`, `pendingKeys` = ids.

## Tasks & Acceptance

**Execution:**
- `app/test/features/graph/graph_view_test.dart` -- add a test after the hover-dim test: same hand layout, `create(actions: _Actions()..gate = Completer())` before `pump`, hover `b`, wait `durHover`, `unawaited(model.run(const GraphAbandon(<String>['c'])))`, pump; expect `opacityOf(c)` closeTo `disabled * .4`, `opacityOf(b)` 1; complete the gate, settle, leave, finish -- closes deferred item 1.

**Acceptance Criteria:**
- Given the new test, when `opacityOf` is changed to drop either factor, then it fails; as written it passes.
- Given `app/`, when `flutter test`, `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` run, then all pass.

## Spec Change Log

## Review Triage Log

### 2026-10-31 — Review pass
- verdicts: 15 findings — high 0, medium 0, low 11, false 4, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind 1) The Approach's "off-path non-pending card at .4" is not in the test — the layout's only off-path card is the pending `c`; the hover-dim test :852 pins the plain .4; the fix is a spec edit.
  - `[low]` `[patch]` (blind 2) No pending card on the focus path is checked — the test now abandons `a` and `c` and expects `a` at `disabledOpacity`.
  - `[low]` `[reject]` (blind 3) Title says "hovered card stays at 1" but `a`/`root` are not checked — `a` is now pending and checked; `root`'s undimmed 1 is pinned by the hover-dim test; pending never touches it.
  - `[low]` `[patch]` (blind 4) Nothing checks the pending factor is dropped after the run while the hover stays — after `pumpAndSettle`, `c` at .4 and `a` at 1.
  - `[low]` `[reject]` (blind 5) `model.run`'s result is discarded — same pattern as the anchor-hint test :633; the opacity assertions decide, and `actions.ran` is now asserted.
  - `[false]` `[reject]` (blind 6) The dim may be incomplete after `durHover` — the hover-dim test :852 runs the identical sequence and asserts `c` exactly .4.
  - `[low]` `[patch]` (edge 1) `disabledOpacity` (.4) equals the full dim factor, so a factor used twice still gives .16 — with `a` pending on the path (expected `disabledOpacity`), a formula using the dim factor twice gives `a` = 1 and one using the pending factor twice gives `a` = .16: both now fail. Same patch as blind 2.
  - `[low]` `[patch]` (edge 2) A pending on-path card is untested — same patch as blind 2.
  - `[low]` `[patch]` (edge 3) The test never checks the run started — `expect(actions.ran, hasLength(1))` added.
  - `[low]` `[patch]` (edge 4) Opacity after the gate completes is not asserted — same patch as blind 4.
  - `[low]` `[reject]` (edge 5, claim) No off-path non-pending card asserted in the combined state — as blind 1.
  - `[false]` `[reject]` (verification-gap) No gaps found — nothing to act on.
  - `[low]` `[reject]` (verification-gap other) The spec's Approach contradicts its matrix — as blind 1; fix would edit this spec.
  - `[false]` `[reject]` (intent 1) Reading C (all factor combinations) not covered — now covered by the on-path pending `a`.
  - `[false]` `[reject]` (intent 2) `## Auto Run Result` missing — written at finalize, below.

## Verification

**Commands (gate rule of this run: no `cargo make test` / `test-full` / `coverage`):**
- `flutter test test/features/graph/graph_view_test.dart` (in `app/`) -- expected: all pass.
- `flutter test` (in `app/`) -- expected: exit 0.
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` (in `app/`) -- expected: exit 0.

**Outcomes (2026-10-31, gate rule of this run — no `cargo make test` / `test-full` / `coverage`):**
- `flutter test test/features/graph/graph_view_test.dart` (in `app/`): 36 pass, before and after the review patches.
- Mutation check (implementer, first version): dropping the pending factor, then the focus-dim factor in `graph_canvas.dart` each failed the new test; the file was restored (no production diff).
- `cargo make --allow-private test-flutter`: exit 0, 1178 tests, before and after the review patches. (A bare `flutter test` in `app/` fails 5 `worker_project_repos_test.dart` tests that require the XDG pin `cargo make` sets — unrelated to this change.)
- `dart analyze --fatal-infos --fatal-warnings`: no issues. `dart format --output=none --set-exit-if-changed .`: 0 changed.
- No Rust, FFI, schema or `zanshin_ui` change: no cargo/codegen/parity check needed.

## Auto Run Result

Status: done (2026-10-31). Blocking condition: none.

**Items.**
1. No test pins a pending card's opacity while a focus dim is active — **fixed** (commit `92e84d36292d0a33d2cca35add56c0aa98edbcfb`).

**Summary.** Verified real: `GraphCanvas`'s `opacityOf` multiplies the pending fade by the focus-dim factor, and no test held both at once. A new widget test next to the hover-dim test hovers `b`, runs a gated `GraphAbandon(['a', 'c'])` and pins `c` (pending, off the path) at `disabledOpacity * .4`, `a` (pending, on the path) at `disabledOpacity`, `b` at 1; after the run, with the hover kept, `c` is back at .4 and `a` at 1. Test-only.

**Files changed.**
- `app/test/features/graph/graph_view_test.dart` -- the new test.
- Tracking: this spec. No new deferrals, so no `deferred-work.md` section.

**Review findings.** 15 (high 0, medium 0, low 11, false 4). Patched (low): on-path pending card (also breaks the .4 = .4 factor ambiguity), run-started assertion, post-run opacity. Deferred: none. Rejected: the spec's "off-path non-pending card" wording (no such card in the layout; the hover-dim test covers it), unchecked `root`, discarded `run` result (low); incomplete dim, no-gap report, reading C, missing Auto Run Result (false).

**Follow-up review recommendation:** false — no high and no medium entry patched (patched: low 3 entries).

**Residual risks.** The mutation check was run on the first test version only; the revised one adds assertions, it removes none.
