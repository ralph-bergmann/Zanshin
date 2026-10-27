# Layout goldens (Story 4.11, stacks Story 4.13, joint columns Story 4.14)

Generated — do not edit by hand. Regenerate from `spikes/graph-layout-ab/` after building the
Dart reference (`dart compile exe dart/bin/graph_layout.dart -o dart/build/graph_layout`),
regenerating the inputs and running `node tools/js_oracle.mjs`, `node tools/design-layout.mjs`
and `node tools/stacks.mjs` (README `## Run`):

```sh
node tools/goldens.mjs
```

Every output is `docs/graph-layout.md` §3's canonical form, for the shipped scope: modes
`compact` | `free` × lane orders `greedy` | `compact`, named `<input>.<mode>.<order>.json`.
The product always lays out joint columns (§4.3 / §4.7, amended 2026-10-27): one lane packing and
one column order for both modes, so `lane`, `col` and `lanes` are the same in a compact and a free
output (I8). Every output therefore comes from the spike's Dart reference (`dart/`) with
`--columns joint`, both orders; the Rust reference (`rust/`) keeps the per-mode packing.

- `design/`: the design sample's inputs (`tools/design-input.mjs`, export pinned at `57f259c`),
  their 8 outputs, and `oracle/`: the design's own `computeLayout` (`tools/js_oracle.mjs`) in
  `compact` mode, greedy, with the per-mode lanes of that export (the product test compares rows
  and edges only); and `joint-design-<rev>.lanes.json`: the lane counts of the export `e74ced3`'s
  `graph-layout.jsx` (`tools/design-layout.mjs`) on the `e243dd2` sample (`stacks/design-<rev>.json`
  without its stack facts) — `gl_greedy_lanes` (exact colouring off: the fewer of its two greedy
  packings), `gl_exact_lanes` and the Dart reference's `joint_greedy_lanes`.
- `design/<input>.<mode>.compact.budget-<N>.json`: the `compact` order at a budget N that stops its
  search mid-way (the output differs from the default budget's and from greedy's) — `design-default` compact N = 20, `design-default` free N = 10. The
  committed fixtures cannot show a cut: their `compact` order equals greedy's or is final after the
  first window, which even budget 0 evaluates.
- `fixtures/`: the dumper's inputs (`rust-inputs/`, `Repo::graph_topology`; prioritize
  `present(@)`, short prefixes `''`, anchors `[trunk(), present(@)]`, `utc_offset_min` 120,
  `now_ms` = newest ts + 60 s) — `tiny-all` (tiny-3-commits `all()`) and `medium-narrow`
  (medium-1k-commits, the NARROW revset) in full; `hashes.json` holds every fixture case's revset,
  `now_ms` and `utc_offset_min`, and for `medium-all` and `large-all` (medium-1k-commits and
  large-10k-commits `all()`) the input's and each output's hash and byte length.
- `fuzz/`: `cases.jsonl` holds 100 canonical inputs, one per line, case k =
  `genInput(rng(411 * 1_000_003 + k))` of `tools/fuzz.mjs`; `expected.json` per case and
  `<mode>.<order>` the output's hash and byte length.
- `stacks/` (Story 4.13, `docs/graph-layout.md` §4.8; every output from the spike's Dart binary
  with `--stacks`, for both orders — stacks are Dart-only; run `node tools/stacks.mjs` first):
  - `design-<rev>.json`: the design sample at `e243dd2` (52 commits) with stack facts;
  - `request-{default,expanded,mixed}.json`: the stack requests — `default` names nothing
    (every run collapses), `expanded` names every run's key of both revsets, `mixed` has a key in
    both lists, a kept-open middle member and keys that change nothing;
  - `design-<rev>.<request>.<mode>.<order>.json`: the outputs;
  - `oracle/design-<rev>.runs.json`: the design's own `groupStacks(all, rev, [])` as runs of
    input node indices (oldest first, ordered by newest member), after `tools/stacks.mjs` checked
    that the design's gap walk yields jj-lib 0.44's edges on this sample;
  - `fuzz/`: `cases.jsonl` holds 60 cases, one `{"input":…,"request":…}` per line, case k
    = `genStackInput(r)` then `stackRequest(r, input)` of `tools/stacks.mjs` with
    `r = rng(413 * 1_000_003 + k)`; `expected.json` per case and `<mode>.<order>` the output's
    hash and byte length.

Hashes are FNV-1a 64 (offset basis `0xcbf29ce484222325`, prime `0x100000001b3`) over the
canonical UTF-8 bytes including the trailing `\n`, as 16 lowercase hex digits.
