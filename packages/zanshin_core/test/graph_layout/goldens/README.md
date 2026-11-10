# Layout goldens (Story 4.11, stacks Story 4.13, branch columns Story 4.17)

Generated — do not edit by hand. Regenerate from the repository root (`dart` on PATH):

```sh
node spikes/graph-layout-ab/tools/goldens.mjs
```

Every output is `docs/graph-layout.md` §3's canonical form from the product CLI
(`packages/zanshin_core/benchmark/graph_layout_cli.dart`, §13, amended 2026-11-10), for the modes
`compact` | `free`, named `<input>.<mode>.json`. The columns are §4.3's branch columns, chosen per
mode. The tool never touches the inputs or the oracles below.

- `design/`: the design sample's inputs, their outputs, and `oracle/`: the design's own
  `computeLayout` at export `57f259c` in `compact` mode (its rows, edge endpoints and edge kinds are
  what the product test compares; its lane packing is not the product's).
- `fixtures/`: the dumper's inputs (`rust-inputs/`, `Repo::graph_topology`; prioritize
  `present(@)`, short prefixes `''`, anchors `[trunk(), present(@)]`, `utc_offset_min` 120,
  `now_ms` = newest ts + 60 s) — `tiny-all` (tiny-3-commits `all()`) and `medium-narrow`
  (medium-1k-commits, the NARROW revset) in full; `hashes.json` holds every fixture case's revset,
  `now_ms` and `utc_offset_min`, and for `medium-all` and `large-all` (medium-1k-commits and
  large-10k-commits `all()`, whose inputs are `spikes/graph-layout-ab/inputs/fixture-*.json`) the
  input's and each mode's output's hash and byte length.
- `fuzz/`: `cases.jsonl` holds 100 canonical inputs, one per line (case k =
  `genInput(rng(411 * 1_000_003 + k))` of `tools/fuzz.mjs`, generated once); `expected.json` per
  case and `<mode>` the output's hash and byte length.
- `stacks/` (Story 4.13, `docs/graph-layout.md` §4.8):
  - `design-<rev>.json`: the design sample at `e243dd2` (52 commits) with stack facts;
  - `request-{default,expanded,mixed}.json`: the stack requests — `default` names nothing
    (every run collapses), `expanded` names every run's key of both revsets, `mixed` has a key in
    both lists, a kept-open middle member and keys that change nothing;
  - `design-<rev>.<request>.<mode>.json`: the outputs;
  - `oracle/design-<rev>.runs.json`: the design's own `groupStacks(all, rev, [])` as runs of input
    node indices (oldest first, ordered by newest member);
  - `fuzz/`: `cases.jsonl` holds 60 cases, one `{"input":…,"request":…}` per line, case k =
    `genStackInput(r)` then `stackRequest(r, input)` of `tools/stacks.mjs` with
    `r = rng(413 * 1_000_003 + k)` (generated once); `expected.json` per case and `<mode>` the
    output's hash and byte length.

Hashes are FNV-1a 64 (offset basis `0xcbf29ce484222325`, prime `0x100000001b3`) over the
canonical UTF-8 bytes including the trailing `\n`, as 16 lowercase hex digits.
