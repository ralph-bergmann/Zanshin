# Layout goldens (Story 4.11)

Generated — do not edit by hand. Regenerate from `spikes/graph-layout-ab/` after building both
references (`cargo build --release --manifest-path rust/Cargo.toml`,
`dart compile exe dart/bin/graph_layout.dart -o dart/build/graph_layout`), regenerating the
inputs and running `node tools/js_oracle.mjs` (README `## Run`):

```sh
node tools/goldens.mjs
```

Every output is `docs/graph-layout.md` §3's canonical form, for the shipped scope: modes
`compact` | `free` × lane orders `greedy` | `compact`, named `<input>.<mode>.<order>.json`.
`greedy` comes from the Rust reference (`rust/`), the `compact` order from the spike's Dart
reference (`dart/`), which is its only implementation.

- `design/`: the design sample's inputs (`tools/design-input.mjs`, export pinned at `57f259c`),
  their 8 outputs, and `oracle/`: the design's own `computeLayout` (`tools/js_oracle.mjs`) in
  `compact` mode, greedy.
- `design/<input>.<mode>.compact.budget-<N>.json`: the `compact` order at a budget N that stops its
  search mid-way (the output differs from the default budget's and from greedy's) — `design-all` compact N = 20, `design-all` free N = 90, `design-default` free N = 40. The
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

Hashes are FNV-1a 64 (offset basis `0xcbf29ce484222325`, prime `0x100000001b3`) over the
canonical UTF-8 bytes including the trailing `\n`, as 16 lowercase hex digits.
