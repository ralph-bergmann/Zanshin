---
title: 'Story 4.15 closing run — gutter routes get GL parity in the router oracle'
type: 'chore'
created: '2026-10-27'
status: 'done'
baseline_revision: 'bf1cbdfaf8d2ceed0506d35ba02d7d754223da68'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
  - '{project-root}/docs/graph-layout.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Ledger item 1 handed to this closing run (Story 4.15's `deferred:`), verified against the current code: `spikes/graph-layout-ab/tools/router-oracle.mjs` builds its 132 cases only from GL's own column choices (the sample with `optimize: false`, the Lines Study with `optimize: true`), and GL's packing and optimizer avoid every `gutter` line there (GLD §7.2 :1059-1060 says so), so router B's gutter x, its ±6 px steps, gutter exit/entry ordering and the deep placement on a gutter's lower run are never compared with GL.

**Approach:** As the ledger proposes: a third oracle category `gutter` — GL's own `computeLayout` with frozen `opts.cols` (GL:548-557) that move one sample node into another column, so GL itself routes lane-blocked (and, in Free, detoured) lines through gutters; those grids go through the existing comparison unchanged, and the oracle fails if the category does not witness gutter lines, stepped gutter lines and deep gutter lines.

## Boundaries & Constraints

**Always:**
- **Case generation (deterministic):** for the sample revsets `default` and `all`, the base columns are GL's own (`computeLayout(GRAPH_COMMITS, rev, 240, 62, "compact", {optimize: false})`); every single-node move (node in GL's node order, target column 0 … colCount, skipping its own) becomes `opts.cols` (a `Map` id → col). A move counts only if GL froze it — every routed node's `col` equals the requested one (GL silently re-packs otherwise, GL:555-558). Each frozen move × the 12 metrics (W 160/240/400 × H 40/62 × free/compact, `optimize: false`) is a case iff GL's routed edges hold ≥ 1 `gutter`; name `gutter-<rev>-<node>-c<col>-<mode>-W<W>-H<H>`, category `gutter`.
- **Comparison unchanged:** the same grid → router input, `decide` cross-check, unit-rule / shared-entry explanations, polyline (±1e-6) and bridge comparison as the other categories; per-category summary lines as before.
- **Coverage witness:** over the `gutter` category the oracle counts gutter lines, stepped gutter lines (GL's gutter vertical x ≠ the gutter's position, i.e. a ±6 px step), deep gutter lines (dashed, sharing a `via` with another dashed edge into the same child — GL's `grouped`, GL:252-256), and both sides; it prints the counts and exits 1 if any is 0, so the witness cannot come out empty by construction. Counts go into `router-report.json`.
- **Router code unchanged** unless the oracle finds an unexplained difference; then fix `router.dart` (GL's behaviour is the reference, as in 4.15) and pin it with a `router_test.dart` case.
- Dated GLD §7.2 amendment (no edit of the accepted 4.15 text) and README item 12 / `## Run` updated; SPDX, `outputs/` stays untracked; no new npm dependency; `loadLayout` unchanged.
- **Gate rule of this run:** no `cargo make test` / `test-full` / `coverage`; targeted checks only, recorded.

**Never:**
- No change to the existing 132 cases, `tools/design-layout.mjs`, the engine, goldens, `crates/`, `schemas/`, `app/`, `coverage-baseline.txt`; no live design folder read; no `jj` in this repo; no edit of `epics.md`, `sprint-status.yaml`, `epic-4-context.md` or Story 4.15's spec; no re-mirroring of item 1 into deferred-work.md.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Frozen move with gutters | node moved into a column that blocks a merge | GL routes `gutter`; router equal (or explained) | — |
| Move GL rejects | requested cols invalid in either model | case skipped (not counted) | — |
| Move without gutters | frozen, no `gutter` edge at a metric | that metric's case skipped | — |
| Coverage | gutter category | gutter, stepped, deep, left- and right-side counts > 0 | exit 1 naming the empty count |
| Unexplained difference | router ≠ GL with no unit-rule / shared-entry reason | `FAIL` line, exit 1 → fix the router | — |

</intent-contract>

## Code Map

- `spikes/graph-layout-ab/tools/router-oracle.mjs` -- header comment :4-23 (case list), cases :46-67 (add the `gutter` category after the study loop), grid → input :69-92 (unchanged), compare :148-220 (unchanged; add the coverage counts per gutter case), summary :221-227 (print counts, fail on 0).
- GL at `e74ced3` (`git show e74ced3:_bmad-output/implementation-artifacts/design/graph-layout.jsx`): `opts.cols` freeze :548-557 (`okIn` per model: no two nodes of one column < U apart, no same-column parent → child with a node between), memo key incl. cols :570-575, gutter kinds :178-190, steps :193-197 (`e.xg` = `e.gx` ± 6·⌈k/2⌉), `grouped`/deep :252-262, polylines :291-297 (gutter vertical x = `pts[2][0]`).
- Probe (this planning run): 115 (`default`) / 269 (`all`) frozen moves at W 240 / H 62, of which 50 / 76 route gutters; stepped gutters appear in 5 / 4 moves, dashed gutter lines in 7 / 0.
- `docs/graph-layout.md` §7.2 :1042-1060 -- append a dated "closing run" paragraph after the 4.15 amendment.
- `spikes/graph-layout-ab/README.md` :91-97 (item 12), :142-145 (`## Run` comment) -- mention the `gutter` category.
- `packages/zanshin_core/lib/src/graph_layout/router.dart`, `test/graph_layout/router_test.dart` -- only if the oracle finds an unexplained difference.
- `packages/zanshin_core/benchmark/router_cli.dart` -- the oracle's Dart side, rebuilt AOT to `spikes/graph-layout-ab/outputs/bin/router_cli` before the run.

## Tasks & Acceptance

**Execution:**
- [x] `spikes/graph-layout-ab/tools/router-oracle.mjs` -- the `gutter` category, the coverage witness, header comment -- closes item 1.
- [x] rebuild `router_cli`, run the oracle; fix `router.dart` + pin in `router_test.dart` only on an unexplained difference.
- [x] `docs/graph-layout.md` §7.2, `spikes/graph-layout-ab/README.md` -- dated note with the measured counts.
- [x] this spec's § Verification record and `## Auto Run Result`; any NEW deferral also in deferred-work.md § "Surfaced in the closing run of Story 4.15 (bmad-build-auto, 2026-10-27)".

**Acceptance Criteria:**
- Given the oracle, when `node tools/router-oracle.mjs` runs from the spike root, then it exits 0, its output has `gutter free H40/H62` and `gutter compact H40/H62` summary lines with only equal or explained cases, and the gutter-coverage line shows non-zero gutter, stepped, deep, left and right counts.
- Given the 132 original cases, when the oracle runs, then they are still all equal.
- Given the finished tree, when `git status` / `git diff --stat` are read, then only the files in the Code Map (and tracking/spec files) changed.

## Spec Change Log

- 2026-10-27 (review) — **Study presets as further gutter bases.** The case-generation bullet names only the sample revsets; the review's exit/entry-ordering finding showed the sample has no child with several non-first parents on one side, so no gutter entry is ever ordered (shared-entry-side count 0 once first-parent lines are excluded). The Study's PRESETS 1 / 2 / 3 at FAN 0 (GL's own optimized columns; octopus merge) are added as bases, moves keyed like GL's `opts.cols` (a stack by its first member) and run with `optimize: false`. KEEP: the sample bases, the freeze test at all 12 metrics, the comparison unchanged.

## Review Triage Log

### 2026-10-27 — Review pass
- verdicts: 18 findings — high 0, medium 0, low 14, false 4, maybe-false 0
- findings:
  - `low` `patch` [blind] The witness counts gutter lines of `explained` cases, whose geometry differences are excused. — Coverage now counts only cases with status `equal`.
  - `low` `patch` [blind] `stepped` only tests "different", not a ±6 px step. — Offset must be a positive multiple of 6 px (±EPS) to count; any other non-zero offset throws with case and edge.
  - `low` `patch` [blind] The gate is only "> 0"; the measured numbers are not pinned. — Generation counts (frozen moves per base, gutter case count) pinned; they depend only on the GL export.
  - `low` `patch` [blind] The per-revset frozen-move split is not in the report. — `gutter_coverage.frozen_moves` is per base.
  - `false` `reject` [blind] The base columns may depend on the metrics. — Without the optimizer GL's columns come from `pack` over unit rows only (GL:476-491, 567), W/H-free; the freeze check also runs at all 12 metrics.
  - `low` `reject` [blind] §7.2's earlier 4.15 paragraph still says GL's grids hold no gutter line. — Accepted GLD text is amended by dated paragraphs only; the amendment follows it directly.
  - `low` `patch` [blind] The script header names only the old exit condition and one line is unwrapped. — Header lists the coverage / generation failures, rewrapped.
  - `low` `reject` [blind] The gutter loop does wasted work (12 layouts before the freeze check, decide() twice). — Dev tool outside the gate, ≈ 47 s; the second decide() was removed with the stepped patch.
  - `low` `patch` [edge-case] Coverage counts lines whose geometry was excused. — Same patch as the first blind row.
  - `low` `patch` [edge-case] The stepped test trusts decide()'s gutter index. — Same patch as the second blind row (non-multiples throw).
  - `low` `patch` [verification-gap] A collapse of case generation passes while one line of each kind survives. — Same patch as the pinning row.
  - `low` `reject` [verification-gap] "Explained" excuses every geometry difference of a case. — Pre-existing rule of the 4.15 oracle; the witness now counts equal cases only; a per-edge explanation needs a model of which edges a unit-rule change may move, more than a direct correction; the 18 cases are one documented run.
  - `false` `reject` [intent-alignment] The intent names `router_test.dart`; the gated surface gained nothing. — The ledger follow-up asks for oracle cases compared like the rest; the oracle is a dev tool outside the gate by the epic's rule, and `router_test.dart` changes only on a router difference (none).
  - `low` `patch` [intent-alignment] Gutter exit/entry ordering has no witness. — `exit_shared` / `entry_shared` counts (non-first lines only for entries), failing on 0; entry ordering needed the Study presets as bases (Spec Change Log).
  - `low` `patch` [intent-alignment] The witness counts lines of explained cases. — Same patch as the first blind row.
  - `false` `reject` [intent-alignment] `stepped` relies on the oracle's decide() replica. — decide() is cross-checked against GL's kind on every edge and its gutter index is GL's own formula; equal cases also match the router's polylines; non-multiple offsets now throw.
  - `low` `patch` [intent-alignment] Lane-blocked and detoured gutters are not told apart. — `compact` count (no pixel detours in Compact), failing on 0.
  - `false` `reject` [intent-alignment] `## Auto Run Result` lacks the per-item outcome and commit. — Written at finalization (this pass).

## Design Notes

Single-node moves are the smallest perturbation GL accepts that still yields lane-blocked merges (a node moved into a merge parent's column between parent and child), the source of the export's defect 2; in Free the shifted x-positions also make GL's pixel test detour direct runs through gutters, so both gutter origins are covered. Stepped lines need two gutter lines on one gutter, and deep gutter lines need a hidden parent feeding ≥ 2 dashed edges into one child — the probe found both among the moves, and the coverage witness keeps it so.

## Verification

**Commands:**
- from `packages/zanshin_core`: `dart compile exe benchmark/router_cli.dart -o ../../spikes/graph-layout-ab/outputs/bin/router_cli` -- expected: exit 0.
- from `spikes/graph-layout-ab`: `node tools/router-oracle.mjs` -- expected: exit 0, counts as in the ACs.
- if `router.dart`/tests change: from `packages/zanshin_core` with the `test-core` env: `cargo make --allow-private test-core`, `test-core-analyze`, `test-core-format` -- expected: green.

**Record (2026-10-27; final state after the review patches):**
- from `packages/zanshin_core`: `dart compile exe benchmark/router_cli.dart -o ../../spikes/graph-layout-ab/outputs/bin/router_cli` -- exit 0 (rebuilt from the current `router.dart`).
- from `spikes/graph-layout-ab`: `node tools/router-oracle.mjs` -- exit 0, ≈ 47 s, 1,617 cases: sample
  24 and study 108 all equal (unchanged); `gutter free H40` 585 equal / 18 explained, `gutter free
  H62` 636 equal, `gutter compact H40` 123 equal, `gutter compact H62` 123 equal, 0 unexplained;
  pinned generation counts: frozen moves 115 `default` / 269 `all` / 67 / 87 / 91 (PRESETS 1 / 2 / 3
  at FAN 0), 1,485 gutter cases; coverage over the equal gutter cases: gutter lines 1,815, stepped
  108 (offsets checked as positive multiples of 6 px), deep 132, left 1,170, right 645, shared exit
  side 399, shared entry side 12, compact 294.
- The 18 explained cases: all Free at H 40, W 160 / 240 / 400, one run — the line from `xrlpkvqm`
  (in the Study its stack `grp:tqwmlnxz`) into `mxnztwqp` with the card `lvqrnkmw` 12 units above
  the parent: GL's pixel test leaves room at d = 12 for H 40 (Story 4.15's Design Notes derivation)
  and keeps the run direct (fork) or takes another gutter, the unit rule blocks it (unit-rule edges
  18, run verdicts that differ 15, consequential edges 21). Documented unit-rule difference →
  `router.dart` and `router_test.dart` unchanged, so the `test-core` steps did not apply.
- `git status`: only `router-oracle.mjs`, `docs/graph-layout.md`, the spike README and this spec.
- Not run (gate rule of this run): `cargo make test` / `test-full` / `coverage`; no Rust or gated
  Dart file changed.

## Auto Run Result

Status: done
Blocking condition: none

**Items:**
- **1 — fixed** (`f0fc69b3e951effa035742eb3d185f5d7aa27c9f`): the router oracle has
  a `gutter` category — GL's own columns of the sample and of the Study's PRESETS 1–3 at FAN 0 with
  one node moved and frozen through GL's `opts.cols`, kept where GL routes gutter lines. GL itself now
  routes 1,815 compared gutter lines (108 stepped by ±6 px multiples, 132 deep, both sides, 399 with
  a shared exit side, 12 with ordered entries, 294 lane-blocked in Compact); router B equals GL on
  1,467 of 1,485 gutter cases, the other 18 are the unit rule's documented H 40 / d = 12 difference.
  The oracle fails if a witness count is 0 or a pinned generation count changes. No router change,
  no new deferral.

**Files:**
- `spikes/graph-layout-ab/tools/router-oracle.mjs`: the `gutter` category, coverage witness, pinned generation counts, header.
- `docs/graph-layout.md` §7.2: dated closing-run amendment with the measured counts.
- `spikes/graph-layout-ab/README.md`: item 12 and the `## Run` comment.

**Review findings** (one pass, 18 findings: high 0, medium 0, low 14, false 4; § Review Triage Log):
- **Patched (all low):** witness counts only equal cases; stepped offsets must be positive multiples
  of 6 px (else throw); generation counts pinned per base; per-base frozen-move counts in the report;
  header exit conditions; exit-side / entry-side / compact counts, with the Study presets added as
  bases so ordered gutter entries exist (the sample has none — the entry-side count was 0 on it once
  first-parent lines were excluded).
- **Deferred:** none.
- **Rejected:** the accepted 4.15 §7.2 sentences (amended by the dated paragraph below them, never
  edited); the oracle's runtime (dev tool, ≈ 47 s); the case-wide "explained" rule (pre-existing, the
  witness now counts equal cases only, per-edge explanation is more than a direct correction); false:
  metric-dependent base columns, a gated product test as the expectation, decide()'s gutter index as
  unchecked, the Auto Run Result format.

**Follow-up review recommended:** false — patched: 0 high, 0 medium, 14 low-verdict rows in 6 entries.

**Residual risks:** the oracle stays outside the gate (as before, a dev tool run by hand); inside the
18 explained cases geometry differences are excused case-wide; shared-entry-side coverage is thin
(12 lines, all in the Study bases).
