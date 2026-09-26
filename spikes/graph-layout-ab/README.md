# Graph-layout spike: Rust vs Dart

A throwaway, **detached** spike (not part of the Zanshin Cargo or Dart workspaces) answering one
question:

> Where should the commit-graph **layout** of the 2026-09-26 UI design run: in **Rust** (a
> zanshin-graph-style module, called over FFI from the Dart worker isolate) or in **pure Dart**
> (inside the worker isolate)?

**What is compared.**
- In both variants, Rust supplies the jj data: topology, edge kinds and timestamps.
- The layout is the design's algorithm (rows, greedy interval lane packing, edge routing,
  lane-order optimisation). It is made scalable and deterministic in [SPEC.md](SPEC.md).
- Both implementations follow SPEC.md, must produce byte-identical output, and are timed per
  phase on the same inputs.

**The row model is still open** (Ralph, 2026-09-26; *decided 2026-09-27: `free` and `compact`,
see [Product decisions 2026-09-27](#product-decisions-2026-09-27)*): fixed rows, or a "free" layout whose
vertical spacing follows time. So the spike implements three modes: `compact`, `time` and
`free`. The verdict has to hold whichever one is chosen.

**Short answer:** Rust is about 3× faster, but at realistic sizes both are far below anything
a user can notice. Put the layout in **Dart**, in the worker isolate. Its decisive advantage
is iteration: a Dart layout change hot-reloads into the running app. A Rust change means a
~6 s cdylib rebuild plus a full app restart. Details in [Recommendation](#recommendation).

## Layout

```
SPEC.md       the contract: algorithm, input/output formats, CLI, verification, benchmark protocol
rust/         Rust implementation (own workspace root: empty [workspace] table), bin `graph-layout`
dart/         Dart implementation (standalone package, not in the root workspace), bin/graph_layout.dart
rust-inputs/  input generator (detached crate, bin `gen-inputs`): jj fixture dumps + synthetic inputs
tools/        node scripts, no npm dependencies:
  design-input.mjs, js_oracle.mjs   design sample → input; the design as oracle (§7.2)
  compare.mjs, fuzz.mjs             Rust ≡ Dart + invariants (§7.1, §7.3); probes + random inputs
  bench.mjs                         the benchmark (§8) and its tables
  payload.mjs                       FFI payload sizes per variant
  friction.mjs                      edit → result times (works on a copy, never edits the spike)
  loc.mjs                           lines of code, tests excluded
  viewer-bundle.mjs                 input + outputs of every mode × order → one viewer bundle
  lane-metrics.mjs                  lane-order quality: crossings as drawn, run length, width, holes
inputs/       generated layout inputs (gitignored)
outputs/      generated outputs, bench lines, memory probes (gitignored)
viewer/       throwaway HTML viewer (index.html, viewer.js, viewer.css); viewer/data/ is gitignored
```

## Status

1. **Done:** the spec (SPEC.md) and this skeleton.
2. **Done:** the inputs (8 files, see `inputs/manifest.json`).
3. **Done:** the Rust and Dart implementations and their verification (below).
4. **Done:** the benchmark, the results and the recommendation (2026-09-26).
5. **Done:** an adversarial review of fairness and conclusions, with control runs and one tool
   fix. See [Review 2026-09-26](#review-2026-09-26).
6. **Done:** a lane-order review after Ralph's viewer feedback: the diagnosis, a metrics tool and
   a Dart-only `compact` order (SPEC §4.7). See
   [Lane order review 2026-09-26](#lane-order-review-2026-09-26).
7. **Done:** the viewer shows `compact` as a third lane order (bundle v2), with every order's
   whole-graph metrics in the info bar. See
   [§7 of the lane order review](#7-in-the-viewer-2026-09-26).
8. **Done:** Ralph's product decisions after using the viewer (2026-09-27). See
   [Product decisions 2026-09-27](#product-decisions-2026-09-27).

## Run

From the spike root, with `cargo`, `dart` and `node` on PATH:

```
# inputs (≈ 75 s; the node step first, the manifest recounts every file)
node tools/design-input.mjs
CARGO_TARGET_DIR=rust-inputs/target cargo run --release --manifest-path rust-inputs/Cargo.toml -- all

# build
cargo build --release --manifest-path rust/Cargo.toml
dart compile exe dart/bin/graph_layout.dart -o dart/build/graph_layout

# unit tests
cargo test --release --manifest-path rust/Cargo.toml
(cd dart && dart run test/layout_test.dart)

# verification (SPEC.md §7)
node tools/compare.mjs --digest     # Rust ≡ Dart + invariants I1–I6 + bench digests, all 48 combinations
node tools/js_oracle.mjs --fuzz 300 # the design as oracle: the sample, then random design graphs
node tools/fuzz.mjs --cases 300     # input/CLI probes, then random inputs vs a naive JS reading of §4

# benchmark and report (stage 4)
node tools/bench.mjs                # ≈ 3 min: 144 bench processes → outputs/bench/bench-<stamp>.jsonl + tables
node tools/bench.mjs --report outputs/bench/<file>.jsonl
node tools/payload.mjs              # needs outputs/rust/* from compare.mjs
node tools/friction.mjs             # ≈ 1 min; copies rust/ + dart/ to $TMPDIR/graph-layout-friction
node tools/loc.mjs
/usr/bin/time -l rust/target/release/graph-layout layout --mode time --order optimized inputs/synth-100k.json /tmp/o.json

# lane orders (`compact` is Dart-only, SPEC §4.7) and their quality
dart/build/graph_layout layout --mode free --order compact inputs/synth-10k.json outputs/o.json
node tools/lane-metrics.mjs [--node IDX] outputs/o.json …
```

## Viewer

A throwaway HTML page (plain JS, no build step) for comparing the modes on real data before any
Flutter work. It paints the layout outputs the way the 2026-09-26 design draws them.

**Controls:**
- Layout: Compact | Time | Free | Time+gaps. Time+gaps is Time's rows plus inter-bucket gaps sized
  by elapsed time. The viewer computes them from the Time output's buckets, as prefix sums: extra
  gap = max(0, gap(Δkey) − 1 pitch), with gap = the free mode's curve (§4.2).
- Lane order: Greedy | Optimized | Compact. Compact is the Dart-only `compact` order (SPEC §4.7),
  not the Compact layout mode; `?order=compact` selects it. Also the detailed/compact cards switch,
  card width 160–400, a dataset picker and crossing gaps on/off.
- Free has a day gutter, like Time: "Today", "Yesterday", then "Sep 24", with the year when it
  is not the current one. Days count from the bundle's `now_ms`, so screenshots are
  reproducible. The words and the date format come from `Intl`, so `?lang=de` gives "Heute",
  "Gestern", "24. Sept." without a string table. (Ralph asked in German; the design is
  English, so English is the default.)
- Go to commit (⌘F / Ctrl+F): a change-id or commit-id prefix, else a description substring.
  It lists up to 50 hits with a total count. Enter or a click jumps; Enter again goes to the
  next hit, Shift+Enter to the previous one; ↑/↓ reopen the list and move in it. Esc closes the
  list and keeps the query (not the search input's native clear); a second Esc leaves the box.
- Minimap on/off (right strip, 112 px): click or drag to jump.
- Test: Jumps | Scroll run the benchmarks below. URL parameters: `?jumptest=N[&seed=S]`,
  `?scrolltest=N` (frames), and `?dataset=&mode=&order=&minimap=0|1`, which override the stored
  UI state.

**How it paints:**
- Cards follow the design: description, bold jj prefix + dim rest, author, relative time, @ gold,
  ◆ immutable, bookmark pill, merge/conflict flags. They need a `.meta.json` sidecar; without
  one they show ids only.
- Edges follow the design's `routeEdges` geometry: straight / merge / branch-off, rounded r = 10,
  dashed when indirect.
- Crossing gaps are computed only for the edges that intersect the viewport.
- The time gutter shows the bucket labels, and hovering a card highlights its ancestors and
  descendants.
- Virtualised: a canvas paints the background and the viewport's edges. DOM cards exist only for
  the viewport ± 360 px, found by binary search over the nodes sorted by y. The scroll extents
  are computed from the data.
- The info bar shows counts, the crossings in view and the Dart AOT layout time from the bundle.
  A "lane orders" line puts the three orders side by side for the current mode, the selected one
  in bold: whole-graph crossings, mean/max width in columns and holes %. These are
  `tools/lane-metrics.mjs` numbers (cards 240×62), computed by the bundler, so they cost the
  viewer nothing; Time+gaps shows Time's.
- Free day gutter: each node's day is taken from the layout's clamped time
  T(i) = max(ts, T(parents)) (SPEC §4.2 free, step 2), not from its raw ts. y is monotone in
  T (I6), so walking the cards top-down meets the days newest first. Each day's label sits on
  its top card, and a dotted guide runs through the middle of the gap above that card, as in
  Time+gaps. Raw ts would open a day early wherever the clamp lifts a child that is older than
  its parent. synth-100k has 1,976 such nodes, and raw ts would put 418 of its 2,951 day labels
  out of order; with the clamped time its gutter has 2,883 days, all in order. The real
  1.4k-commit repo has none (143 days). Labels closer than 22 px are pushed down;
  no dataset triggers that. The day at the top edge of the viewport stays pinned at the top of
  the gutter until the next label pushes it out, like a list section header. One day can span
  several screens, and without the pin the gutter would be empty there. The design has no pin.
- Jump: the scroll offset is assigned directly (never smooth). The card is centred vertically;
  horizontally the view scrolls only as far as needed to show the card clear of the gutter.
  The card is then selected and pulses three times.
- Minimap: rendered once per geometry (dataset, mode, lane order, card size) and on a strip
  resize. It is a raster, not a canvas drawing:
  - Every node adds its card's rectangle to a 2-D difference array (4 corner updates).
  - Every edge adds its vertical and horizontal runs to 1-D difference arrays.
  - One prefix-sum pass turns them into per-pixel counts. A log LUT maps the counts to alpha:
    edges faint, cards bright, bookmarked cards blue.
  - @ gets a gold line across the strip.

  The cost is O(n + E + pixels) however long the runs are, and nothing is drawn per node. The
  result goes into the strip's canvas once with `putImageData`. On scroll, only two DOM
  overlays move by `transform`: the viewport rectangle and a full-width band, because on a
  long graph the rectangle alone is a few pixels tall.

**Bundle, then serve.** Bundles may hold customer-derived data (descriptions, authors,
bookmarks), so `viewer/data/` is gitignored. Never commit it or move it elsewhere.

```
# from the spike root; each input's <name>.meta.json sidecar is picked up when it sits next to it
node tools/viewer-bundle.mjs inputs/design-all.json inputs/design-default.json \
  inputs/fixture-medium-all.json inputs/synth-10k.json inputs/synth-100k.json
node tools/viewer-bundle.mjs --outputs <scratch>/outputs/dart <scratch>/<private>-all.json   # outputs of a private dump stay in scratch

python3 -m http.server 8766 --bind 127.0.0.1 --directory viewer   # then open http://127.0.0.1:8766/
```

**What the bundler does:**
- It reuses `<outputs>/<name>.<mode>.<order>.json` (default `outputs/dart`) for the orders
  greedy, optimized and compact. A missing output, or one older than its input or than the
  binary, is rewritten by `dart/build/graph_layout`, which is compiled first if absent.
- It times each mode × order with one `bench` process (`--runs 11 --warmup 3`; `--no-bench`
  skips this), and runs `tools/lane-metrics.mjs` over each mode's three outputs.
- It checks that greedy and optimized differ only in `col = π(lane)`, and that the edge order
  matches the topology. For compact it checks SPEC §4.7's claims against greedy: the same rows,
  buckets and edges, the same route on every edge, col = lane, the trunk lane unchanged, and no
  more lanes. It fails loudly otherwise.
- Bundle v2 stores greedy's lanes and route string once per mode, π for greedy and optimized,
  and compact's own lane array; compact's route string only if a branch-off's `blocked` flag
  differs (no input has one). The viewer refuses a v1 bundle and asks for a re-bundle.

As a `.claude/launch.json` entry (not added to the repo):

```json
{ "name": "graph-layout-viewer", "runtimeExecutable": "python3",
  "runtimeArgs": ["-m", "http.server", "8766", "--bind", "127.0.0.1", "--directory", "spikes/graph-layout-ab/viewer"],
  "port": 8766 }
```

**Checked on 2026-09-26:**
- On the design sample, node positions, edge polylines, extents, bucket labels and guides, and
  crossing counts equal the design's own `computeLayout`. That covers default/all ×
  compact/time, at 240×62 and 310×40.
- synth-100k scrolls at 60 fps in every mode: ≤ 2 ms of JS per frame, extents up to
  51 k × 5.6 M px.

**Jumps, minimap and day gutter: measured on 2026-09-26.**

Setup: the built-in Chromium browser pane, emulated 1440×900 viewport (scroll area 1318×763),
DPR 2, 60 Hz, free mode, optimized order, detailed 240 px cards, minimap on. Another agent's
Dart work was running on the same machine, so expect ±0.5 ms of noise. Timer resolution is
0.1 ms.

*Jump test.* 200 jumps to uniformly random nodes (seed 1). Each jump starts from a plain task
(like a keydown handler) after two idle frames. The columns:
- **next frame:** from the scroll assignment to the rAF after the frame that painted it (two
  rAFs). This is what the user waits for.
- **frame work:** the main-thread time of that frame, from its rAF timestamp to a task queued
  behind its rendering. It covers our paint JS plus style, layout and paint of the new cards.
- **idle frame:** the same measurement for an idle frame, as a floor.

| med / p95 / max | real 1.4k-commit repo | synth-100k |
|---|---|---|
| jump distance | 46.9 k / 124 k / 146 k px | 1.64 M / 4.56 M / 5.40 M px |
| next frame | 32.9 / 33.2 / 33.9 ms | 32.9 / 33.3 / 34.3 ms |
| frame work | 3.8 / 6.7 / 7.4 ms | 3.4 / 5.7 / 7.0 ms |
| idle frame | 0.5 / 1.2 / 1.4 ms | 0.7 / 1.3 / 2.0 ms |
| paint JS | 0.9 / 1.6 / 1.9 ms | 0.9 / 1.6 / 2.0 ms |
| DOM cards created (= removed) | 13 / 15 / 17 | 8 / 15 / 18 |
| Pearson r(distance, frame work) | −0.05 | 0.05 |

The "next frame" value of about 33 ms is vsync, not work. The task that starts a jump runs just
after a frame, so the first rAF is the next vsync, about 16.7 ms later, and the second rAF
comes one frame after that. The jump is on screen in the first frame after the key press.

The frame after a jump costs the same at every distance: r ≈ ±0.05 over distances up to
5.4 M px, and 1.4 k nodes cost the same as 99 k.
- The frame is a pure function of the scroll offset. Binary search over the nodes sorted by y
  finds the first card (O(log n)); then only the visible cards are built.
- The edge query uses the index sorted by upper end. It checks the block maxima from the start,
  which is O(E/32) comparisons (3.3 k for synth-100k). That is also independent of the
  distance. An interval tree would make it O(log E + k), but paint JS is ~1 ms without one.
- Nothing carries over from the previous position: the old cards go and the new ones are made.
- A smooth scroll over the same distance would instead build and discard every card along the
  way. Over 1.6 M px that is ~2,000 viewports.

In Flutter this is `ScrollController.jumpTo` (not `animateTo`) on a render object that finds
its first child by binary search over the precomputed y.

*Minimap raster.* Median of 9 warm renders, 222×1546 device px (111×773 CSS px), in ms. The
`putImageData` call takes ≤ 0.1 ms on top of these.

| dataset | n | E | compact | time | free | time+gaps |
|---|---|---|---|---|---|---|
| synth-100k | 98,842 | 106,996 | 3.7 | 3.6 | 3.6 | 3.9 |
| synth-10k | 9,890 | 10,684 | 1.8 | 1.8 | 2.1 | 1.8 |
| real 1.4k-commit repo | 1,415 | 1,561 | 3.5* | 2.2 | 2.3 | 1.9 |
| fixture-medium-all | 1,002 | 1,003 | 1.5 | 1.6 | 1.5 | 1.4 |
| design-all | 22 | 23 | 1.7 | 1.6 | 1.6 | 1.9 |

\* The first mode measured after a dataset load; probably JIT warm-up, not the mode.

The floor, about 1.5 ms, is the per-pixel pass over 343 k pixels. Nodes and edges add about
1 ms per 100 k each. A strip rendered at CSS resolution (DPR 1) would have a quarter of the
pixels; not measured.

A rerun later the same evening (21 renders each, free mode) was about twice as slow: fixture
1.9 ms, synth-100k 4.1 ms (another series 5.7–7.9 ms), the real repo 4.3–5.0 ms in every mode,
single renders up to 11 ms. The one render right after a strip resize took 18 ms. The browser
pane's speed varied that evening (the jump and scroll numbers moved much less), and every render
allocates about 6.6 MB of typed arrays, so GC adds to the spread. The real repo costs more than
synth-100k: its graph is only 12 lanes wide, so its cards and edges cover far more of the strip's
pixels, and only covered pixels get the compositing step. Either way the raster stays a few ms,
once per layout, and belongs in the worker.

*Scrolling with and without the minimap.* 240 frames of 64 px per frame, from the same offset,
6 runs per dataset with the order alternated. The values are the mean of the per-run medians
of main-thread frame work.

| | real 1.4k-commit repo | synth-100k |
|---|---|---|
| with minimap (first series / with band) | 1.87 / 2.71 ms | 1.75 / 1.76 ms |
| without minimap (first series / with band) | 1.62 / 2.29 ms | 1.48 / 1.77 ms |
| paint JS with / without | 0.13–0.20 / 0.10–0.20 ms | 0.17–0.18 / 0.15–0.20 ms |
| overlay update, 20 k-call loop | 1.7–2.7 µs | 1.0–1.1 µs |
| frame interval p95, with / without | 17.1–18.6 / 16.9–18.6 ms | 17.3–18.6 / 17.4–18.5 ms |

The second series ran after the full-width band was added, under heavier background load.

The rerun gave the same picture. Two runs per dataset, one per order: synth-100k 1.83–2.0 ms
with the minimap and 1.6–1.8 ms without; the real repo 1.2–1.33 ms with and 1.2 ms without.
The frame interval median was 16.67 ms in every run. The jump test repeated within noise:
frame work 4.3 / 7.1 / 10.8 ms on the real repo and 3.95 / 6.5 / 8.1 ms on synth-100k, with
r(distance, work) at −0.08 and 0.01.

Verdict: the minimap costs at most about 0.3–0.4 ms of main thread per scrolling frame, the
browser's style and compositing update for the moved overlay. That is within the noise
between runs, and no frame was dropped. The JS part is a few µs. The one real cost is the
~2–4 ms raster per layout change, and that belongs in the worker, next to the layout.

*Search.* A linear scan, including rendering the list: 0.3 ms for "fix" on the real repo
(262 hits); 0.6–2.7 ms on synth-100k (ids only; the maximum is for "a", 6,225 hits).

**Mapping to Flutter:**
- The minimap is rendered in the worker isolate right after the layout, at the strip's device
  size. It produces an RGBA `Uint8List`, sent back as `TransferableTypedData`.
- On the UI isolate, `ui.decodeImageFromPixels` (or `ui.ImageDescriptor.raw`) turns it into a
  `ui.Image` once per layout. That image is painted inside its own `RepaintBoundary`.
- The viewport rectangle is a separate `CustomPainter` with
  `repaint: Listenable.merge([vertical, horizontal])` scroll controllers, so scrolling repaints
  only that tiny layer. Click or drag calls `jumpTo`.
- A strip resize needs a new raster (debounced), since the worker needs the target size.
- Free day gutter: the worker returns the sorted (y, day) pairs. Labels come from
  `DateFormat.MMMd(locale)` / `yMMMd`, and "Today"/"Yesterday" from the ARB files. The pinned
  label is a binary search on the scroll offset, the same as here.

**Limits:**
- Dark theme only. There is no detail panel, bookmark popover, quick actions or "+" chips; a
  click only selects.
- Mode switches keep the card nearest the centre in place; the design re-centres on @ instead.
- Day labels add the year when it is not the current one, which the design does not do.
- Elided parents show a bare "~", because counts are out of scope.
- The merge glyph means "≥ 2 graph edges", a proxy: neither input nor sidecar carries the real
  parent count. A merge whose parents collapse into one Indirect edge (or lose a duplicate edge
  in the dump) shows no glyph.
- Search sees only what the bundle carries: 12-character id prefixes (change and commit) and
  the first description line. There is no revset, author or bookmark search.
- ⌘F is intercepted by the built-in browser pane and never reaches the page there; Ctrl+F was
  verified. In a normal browser, the page's `preventDefault` takes ⌘F.
- The minimap does not show day labels, @'s ancestry, hover or selection.
- `?lang=` localises only the Free day gutter. Time's bucket labels and the cards' dates keep
  the older fixed English formatter.
- The time labels show a node's clamped day. A child whose own timestamp is older than its
  parent's shows its own date on the card but sits in its parent's day region.

## Verification (stage 3, 2026-09-26)

- **Rust ≡ Dart.** All 48 combinations (8 inputs × compact/time/free × greedy/optimized) are
  byte-identical. They satisfy I1–I6, and both `bench` digests match the digest recomputed from
  the output.
- **Design oracle.** The design's own `computeLayout` (greedy) and both implementations are
  byte-identical on all 4 sample runs (default/all × compact/time).
- **Design oracle on 1,300 random design graphs** (seeds 1–3, each graph run as default and all;
  with hidden commits, priority ties and clock skew):
  - compact is identical every time;
  - every time-mode difference is D1: it vanishes when the design runs on D1-clamped
    timestamps.
  - 92 of 2,600 runs were skipped because of the design's duplicate-parent defect (V3).
- **Fuzz.** On 1,140 random inputs (seeds 1–3), Rust, Dart and a naive JS reading of §4 agree on
  every mode × order (6,840 runs). The input and CLI probes agree after the fixes listed in
  SPEC.md ("Clarified during diff").
- **Stage 4 re-check.** In the benchmark run, all three builds (Rust, Dart AOT, Dart JIT)
  reported the same nodes, edges, rows, lanes and digest for every one of the 48 combinations.

## Results (2026-09-26, Apple M4 Pro, 14 cores, 24 GB, macOS 27.0 (26A428), on AC power)

rustc 1.95.0 (LLVM 22.1.2), default release profile. Dart SDK 3.14.0-258.0.dev: AOT via
`dart compile exe`, JIT via `dart run`. Per SPEC §8.2, each bench process parses the input and
runs the whole layout from scratch 10 + 31 times. It reports the median of the 31 timed runs;
the minima, all 144 lines and the phase splits are in `outputs/bench/bench-2026-09-26.jsonl`. A
repeat of the synth-100k row matched within 2 %.

**Inputs:**
- `fixture-*`: dumped from Zanshin's jj test fixtures (1k and 10k commits). They are real jj
  repos, but their histories are generated (one commit per minute, one merge in 10k), so
  2–4 lanes. The review added a real-history data point (jj's own history: 15–16 lanes).
- `synth-*`: synthetic and branchy, with 134–173 lanes and ≈ 2 % non-monotonic timestamps.
- `design-*`: the 14- and 22-node design sample. It is too small to time meaningfully and is
  listed for completeness.

### Layout time: Rust `--release` vs Dart AOT (primary)

Total layout (all five phases, parse excluded), median.

| input | n | mode | lanes | greedy: Rust | Dart AOT | AOT/Rust | optimized: Rust | Dart AOT | AOT/Rust |
|---|---|---|---|---|---|---|---|---|---|
| design-default | 14 | compact | 3 | 0.8 µs | 1.3 µs | 1.6× | 1.3 µs | 3.3 µs | 2.5× |
| design-default | 14 | time | 4 | 1.1 µs | 2.9 µs | 2.6× | 2.1 µs | 4.8 µs | 2.3× |
| design-default | 14 | free | 4 | 1.0 µs | 2.1 µs | 2.1× | 1.6 µs | 5.7 µs | 3.6× |
| design-all | 22 | compact | 4 | 1.1 µs | 3.5 µs | 3.1× | 1.8 µs | 7.2 µs | 4.1× |
| design-all | 22 | time | 4 | 1.5 µs | 6.5 µs | 4.4× | 2.4 µs | 11 µs | 4.7× |
| design-all | 22 | free | 4 | 1.3 µs | 4.0 µs | 3.0× | 2.3 µs | 9.2 µs | 4.1× |
| fixture-medium-narrow | 588 | compact | 2 | 23 µs | 43 µs | 1.8× | 33 µs | 114 µs | 3.4× |
| fixture-medium-narrow | 588 | time | 2 | 29 µs | 75 µs | 2.6× | 40 µs | 142 µs | 3.5× |
| fixture-medium-narrow | 588 | free | 2 | 18 µs | 62 µs | 3.4× | 26 µs | 127 µs | 5.0× |
| fixture-medium-all | 1 002 | compact | 3 | 43 µs | 82 µs | 1.9× | 57 µs | 193 µs | 3.4× |
| fixture-medium-all | 1 002 | time | 4 | 47 µs | 99 µs | 2.1× | 60 µs | 205 µs | 3.4× |
| fixture-medium-all | 1 002 | free | 4 | 31 µs | 114 µs | 3.7× | 46 µs | 219 µs | 4.8× |
| fixture-large-all | 10 002 | compact | 3 | 470 µs | 940 µs | 2.0× | 597 µs | 2.08 ms | 3.5× |
| fixture-large-all | 10 002 | time | 4 | 565 µs | 1.35 ms | 2.4× | 684 µs | 2.49 ms | 3.6× |
| fixture-large-all | 10 002 | free | 4 | 344 µs | 1.29 ms | 3.8× | 463 µs | 2.45 ms | 5.3× |
| synth-10k | 9 890 | compact | 134 | 530 µs | 1.76 ms | 3.3× | 3.81 ms | 11.3 ms | 3.0× |
| synth-10k | 9 890 | time | 168 | 636 µs | 2.31 ms | 3.6× | 3.67 ms | 12.3 ms | 3.4× |
| synth-10k | 9 890 | free | 168 | 657 µs | 1.61 ms | 2.5× | 3.53 ms | 10.8 ms | 3.1× |
| synth-50k | 49 442 | compact | 138 | 3.35 ms | 9.32 ms | 2.8× | 24.8 ms | 74.2 ms | 3.0× |
| synth-50k | 49 442 | time | 166 | 4.25 ms | 13.6 ms | 3.2× | 25.6 ms | 90.6 ms | 3.5× |
| synth-50k | 49 442 | free | 168 | 3.87 ms | 8.83 ms | 2.3× | 25.3 ms | 86.2 ms | 3.4× |
| synth-100k | 98 842 | compact | 147 | 7.35 ms | 19.6 ms | 2.7× | 34.2 ms | 105.9 ms | 3.1× |
| synth-100k | 98 842 | time | 173 | 9.25 ms | 28.2 ms | 3.0× | 36.2 ms | 125.3 ms | 3.5× |
| synth-100k | 98 842 | free | 173 | 8.27 ms | 19.5 ms | 2.4× | 35.4 ms | 120.6 ms | 3.4× |

**Summary:**
- **Ratio.** Dart AOT takes 1.6–5.3× as long as Rust, typically about 3×. The three modes
  behave alike.
- **Where the time goes.** Two phases dominate at scale: lane packing, and the `optimized`
  ordering once there are many lanes. On the real 3–4-lane fixtures, `optimized` is almost free
  for Rust (+0.1 ms at 10k) and costs Dart AOT about +1.1 ms.
- **The budget.** `optimized` hits its fixed work budget (SPEC §4.6, BUDGET = 2 000 000) on
  synth-50k and synth-100k. Those times are therefore capped, not open-ended.

### Phases, `time` mode (median)

| input | order | impl | layering | lanes | blocked | routing | ordering | total |
|---|---|---|---|---|---|---|---|---|
| fixture-large-all | greedy | rust | 145 µs | 388 µs | 19 µs | 11 µs | 3.7 µs | 565 µs |
| fixture-large-all | greedy | dart-aot | 552 µs | 763 µs | 14 µs | 14 µs | 1.0 µs | 1.35 ms |
| fixture-large-all | optimized | rust | 145 µs | 386 µs | 19 µs | 11 µs | 130 µs | 684 µs |
| fixture-large-all | optimized | dart-aot | 555 µs | 773 µs | 13 µs | 14 µs | 1.13 ms | 2.49 ms |
| synth-10k | greedy | rust | 192 µs | 401 µs | 28 µs | 12 µs | 3.7 µs | 636 µs |
| synth-10k | greedy | dart-aot | 940 µs | 1.27 ms | 69 µs | 28 µs | 1.2 µs | 2.31 ms |
| synth-10k | optimized | rust | 203 µs | 475 µs | 38 µs | 16 µs | 2.94 ms | 3.67 ms |
| synth-10k | optimized | dart-aot | 978 µs | 1.35 ms | 82 µs | 34 µs | 9.91 ms | 12.3 ms |
| synth-100k | greedy | rust | 2.40 ms | 6.15 ms | 438 µs | 170 µs | 36 µs | 9.25 ms |
| synth-100k | greedy | dart-aot | 12.0 ms | 14.8 ms | 928 µs | 341 µs | 28 µs | 28.2 ms |
| synth-100k | optimized | rust | 2.45 ms | 6.21 ms | 446 µs | 173 µs | 27.0 ms | 36.2 ms |
| synth-100k | optimized | dart-aot | 11.9 ms | 14.7 ms | 950 µs | 348 µs | 97.5 ms | 125.3 ms |

**Why Dart is slower here.**
- **Sorting, most likely.** Dart's layering in `time` and `free` is 3–5× slower than Rust's,
  while in `compact`, which does not sort, it is only 1.3–1.9× slower. So the gap is most
  likely the sorts: Dart's `Int64List.sort()` and comparator sorts, against Rust's
  `sort_unstable` on primitives. This was inferred, not profiled.
- **Ordering precomputation.** On few lanes, Dart's ordering is 9× slower than Rust's
  (1.13 ms vs 130 µs). That phase is mostly precomputation there, including per-lane sorts.
- **Headroom.** If sorting is the cause, these are Dart-library costs, not algorithm costs, and
  there is headroom: for example packed keys with a radix sort. Per SPEC §8.3 that would have
  to go into Rust too, so it was not tried.
- **Review 2026-09-26: confirmed and measured.** Plain monomorphic sorts alone halve the gap in
  most rows; see the review.

### Dart JIT (`dart run`, secondary) vs Dart AOT

Debug builds of the app run the worker isolate in JIT, release builds in AOT.

| input | mode | greedy: AOT | JIT | JIT/AOT | optimized: AOT | JIT | JIT/AOT |
|---|---|---|---|---|---|---|---|
| design-all | time | 6.5 µs | 49 µs | 7.4× | 11 µs | 70 µs | 6.2× |
| fixture-medium-narrow | time | 75 µs | 132 µs | 1.8× | 142 µs | 205 µs | 1.4× |
| fixture-medium-all | time | 99 µs | 122 µs | 1.2× | 205 µs | 242 µs | 1.2× |
| fixture-large-all | time | 1.35 ms | 1.35 ms | 1.0× | 2.49 ms | 2.30 ms | 0.9× |
| synth-10k | time | 2.31 ms | 2.30 ms | 1.0× | 12.3 ms | 12.5 ms | 1.0× |
| synth-50k | time | 13.6 ms | 12.0 ms | 0.9× | 90.6 ms | 93.1 ms | 1.0× |
| synth-100k | time | 28.2 ms | 25.0 ms | 0.9× | 125.3 ms | 124.0 ms | 1.0× |

**Warm JIT.**
- From ≈ 600 nodes up, warm JIT runs at 0.8–1.8× the AOT time; from 10k up, at 0.8–1.1×.
  `compact` and `free` behave the same.
- On the 14- and 22-node samples, 10 warm-up runs are too few for the JIT to optimise. It runs
  5–12× slower there, which is still ≤ 70 µs.

**Cold start.** The first layout in a fresh process runs cold, with no warm-up. That is what a
debug build pays after start, or after a hot reload of the layout library (median of 3
processes, `time` mode):

| input | order | Rust | Dart AOT | Dart JIT |
|---|---|---|---|---|
| fixture-large-all | greedy | 662 µs | 1.40 ms | 21.2 ms |
| fixture-large-all | optimized | 795 µs | 2.75 ms | 30.8 ms |
| synth-10k | greedy | 964 µs | 2.66 ms | 25.9 ms |
| synth-10k | optimized | 4.17 ms | 13.3 ms | 51.5 ms |
| synth-100k | greedy | 9.62 ms | 27.1 ms | 81.3 ms |
| synth-100k | optimized | 36.8 ms | 119.3 ms | 218.4 ms |

### Parse + validation (JSON, not the product path)

Median, from the `compact`/`greedy` runs. This is the spike's JSON input, parsed with serde_json
and dart:convert. In the product the topology arrives as FlatBuffers scalar vectors, so these
numbers say little about production. Parsing is excluded from every total above.

| input | bytes | Rust | Dart AOT | AOT/Rust | Dart JIT |
|---|---|---|---|---|---|
| fixture-medium-narrow | 83 210 | 108 µs | 312 µs | 2.9× | 390 µs |
| fixture-medium-all | 141 254 | 176 µs | 466 µs | 2.6× | 580 µs |
| fixture-large-all | 1 419 259 | 1.65 ms | 4.87 ms | 3.0× | 5.60 ms |
| synth-10k | 1 427 115 | 1.68 ms | 5.18 ms | 3.1× | 5.57 ms |
| synth-50k | 7 183 505 | 8.28 ms | 39.3 ms | 4.8× | 43.8 ms |
| synth-100k | 14 376 692 | 17.1 ms | 82.4 ms | 4.8× | 96.7 ms |

### Memory

One `layout --mode time --order optimized` run per process, measured with `/usr/bin/time -l`.
Sizes are in decimal MB.

| | Rust | Dart AOT | Dart JIT (`dart run`) |
|---|---|---|---|
| max RSS, design-default (process baseline) | 2.1 MB | 15.0 MB | 375.7 MB |
| max RSS, synth-10k | 7.0 MB | 36.1 MB | – |
| max RSS, synth-100k | 59.6 MB | 216.2 MB | 448.7 MB |
| peak memory footprint, synth-100k | 58.9 MB | 206.7 MB | 395.5 MB |

**These process numbers are mostly JSON and VM.**
- Dart AOT: `jsonDecode` builds a map per node and per parent from the 14 MB file.
- Dart JIT: most of the footprint is the `dart run` tool and its kernel compiler.
- In the app the worker isolate lives inside the Flutter process anyway.

**The layout's own heap.** A counting global allocator around the Rust library (a scratch
probe, not committed) measured, at the same sizes in greedy and optimized:

| | 10k | 100k |
|---|---|---|
| input arrays after parse | 0.23 MB | 2.3 MB |
| layout peak above that | 1.0 MB | 9.4–9.5 MB |
| retained result | 0.52 MB | 5.2 MB |

That is ≈ 95 B per node. SPEC §8.3 prescribes the same flat typed arrays for Dart, so the Dart
layout's working set is the same order of magnitude. That was not measured separately in Dart,
because the JSON tree hides it. Memory does not separate the two variants.

### FFI payload

`tools/payload.mjs` gives exact byte counts in a compact fixed-width binary layout, the one
FlatBuffers scalar vectors or vectors of structs have:
- **Topology**, needed in both variants: per node ts i64 + priority u32 + flags u8 + a CSR offset
  u32, and per jj edge target u32 + kind u8. That is ≈ 22 B per node.
- **Layout result**, extra in the Rust variant: per node row u32 + lane u16 + col u16, per
  layout edge route + blocked in one u8, per time bucket 17 B. That is ≈ 9 B per node. `from`
  and `to` need not be sent: they follow from the topology's edge order (SPEC §3).

| input | n | topology (Dart layout) | + layout (Rust layout), compact/free | + layout, time | layout share of the Rust payload (time) |
|---|---|---|---|---|---|
| fixture-medium-all | 1 002 | 22.1 KB | +9.0 KB | +9.1 KB | 29 % |
| fixture-large-all | 10 002 | 220.1 KB | +90.0 KB | +90.2 KB | 29 % |
| synth-10k | 9 890 | 221.7 KB | +89.8 KB | +94.9 KB (297 buckets) | 30 % |
| synth-50k | 49 442 | 1.11 MB | +449.0 KB | +473.5 KB | 30 % |
| synth-100k | 98 842 | 2.22 MB | +897.7 KB | +946.9 KB (2 889 buckets) | 30 % |

**Payload in context** (`spikes/ffi-payload-bench`). The FlatBuffers GraphSlice there is
1.75 MB at 10k nodes, about 175 B per node, most of it id and summary strings. Rust encodes it
in 0.82 ms and Dart reads it all in 1.54 ms: ≈ 0.47 and 0.88 ns per byte.
- **The extra cost of shipping the layout, scaled by bytes:** ≤ 0.04 + 0.08 ms at 10k, and
  ≤ 0.4 + 0.8 ms at 100k.
- **That is an upper bound.** Scalar vectors are cheaper than string tables, and they can be
  read zero-copy as typed-data views.
- **Where it could still matter:** the only place the Rust variant pays extra is the payload,
  and it is ≤ 1.2 ms at 100k. That is 1–2 orders of magnitude below the compute gap in Dart's
  disfavour (11–89 ms at 100k). Payload does not decide.
- In the Rust variant, `priority` could be dropped from the payload, saving 4 B per node,
  because only the layout reads it.

### Iteration friction

Wall time from a one-line edit to the result, median of 3–5 edits (`tools/friction.mjs`, plus
a scratch copy of the Rust workspace for the product row). The edited line is the `free` gap
function, or a line of zanshin-graph's lane code for the product row. It is toggled between two
equivalent spellings, so every test stays green.

| step after the edit | time |
|---|---|
| **spike** Rust: `cargo build --release` (crate + serde deps; cold: 4.25 s) | 1.00 s |
| **spike** Rust: `cargo build` (dev, incremental) | 0.72 s |
| **spike** Rust: `cargo test --release` (compile + 31 tests) | 1.47 s |
| **spike** Rust: build + run `layout` on synth-10k | 1.16 s |
| **spike** Dart: `dart compile exe` | 0.99 s |
| **spike** Dart: `dart run` → layout written (JIT, synth-10k) | 0.59 s |
| **spike** Dart: `dart run test/layout_test.dart` (30 tests) | 0.98 s |
| **product** Rust: edit in `crates/zanshin-graph`, then the native-assets hook's exact command: `cargo build --release --package zanshin-ffi --target aarch64-apple-darwin` (cold: 42 s; no-op: 0.4 s) | **5.85 s**, then a full app restart |
| **product** Dart: layout in the worker isolate | **hot reload**: the code swap took 32 ms in the probe, without restarting the app |

**Standalone, the two are equal.** Each takes about 1 s.

**In the product, they are not.**
- **Rust always builds in release.** `native_toolchain_rust` defaults to `--release`, even for
  Flutter debug builds. A layout edit recompiles zanshin-graph and zanshin-ffi, including its
  staticlib and cdylib.
- **Then the app has to restart.** The Flutter docs say native code changes need a full restart.
  The cdylib is loaded once per process, and only `flutter run` re-runs the build hook. The
  macOS app rebuild, relaunch and boot (with its splash) come on top, unmeasured here. The open
  repo, scroll position and selection are lost.

**The worker-isolate claim, checked.** "A Dart layout change in the worker isolate only takes
effect on hot *restart*" is **false** for Zanshin's worker.
- **The worker is in the UI isolate's group.** `ZanshinWorker` is started with `Isolate.spawn`
  (`packages/zanshin_core/lib/src/worker/isolate.dart`). Such isolates share the spawner's code
  and isolate group. On spawn, the SDK's `Isolate.spawn` doc says "shares the same code"; the
  [Dart docs](https://dart.dev/language/concurrency) say "the same isolate group".
- **A reload covers the whole group.** `package:vm_service`'s `reloadSources` doc says it
  reloads "all isolates in the same isolate group". flutter_tools also sends the reload to every
  isolate, not just the UI ones
  ([flutter#52149](https://github.com/flutter/flutter/pull/52149), relanded as #52479).
- **Checked here with a probe** (a scratch program, not committed):
  - a main isolate plus an `Isolate.spawn` worker that answers requests with `layoutVersion()`;
  - run with the VM service on, the library edited, then `reloadSources` called for the main
    isolate only;
  - the worker's next answer used the new code, and the VM reload took 32 ms.
  - Flutter's own hot reload adds its incremental kernel compile and reassemble; that was not
    measured here.

**What hot reload does not do.**
- **It changes code, not state.** The worker only recomputes when it is asked. To see a layout
  edit without any other interaction, the view needs a debug hook that asks for a relayout on
  `reassemble`.
- **Some edits still need a hot restart:** static initializers, `main()`, and the message
  classes' shape. flutter_tools then kills view-less isolates and the app's boot spawns the
  worker again.
- **An isolate started with `Isolate.spawnUri`** (another group) would not be reloaded.
  Zanshin's worker is not one.
- **The first layout after a reload runs cold JIT code.** At 10k that is 21–52 ms, from the
  cold-start table.

### Code size and tests

`tools/loc.mjs`. "code" counts non-blank lines that are not only comments. Both sides allow
120 columns: Rust through the repo's `rustfmt.toml`, which rustfmt finds by walking up, and
Dart through its `analysis_options.yaml`.

| | Rust | Dart |
|---|---|---|
| layout (§4): layout + lane order | 955 lines / 796 code | 886 / 760 |
| input parse + validation (§2) | 229 / 171 | 179 / 137 |
| output + digest | 88 / 78 | 77 / 73 |
| crate/library root | 27 / 8 | 7 / 5 |
| CLI + bench | 207 / 185 | 178 / 161 |
| **total, tests excluded** | **1 506 / 1 238** | **1 327 / 1 136** |
| unit tests | 31 tests: 901 lines inline + 200 lines `checks.rs` | 30 tests: 940 lines (SDK-only harness) |

Shared by both: the differential tools (compare, fuzz, the JS oracle). Their probe inputs are
what surfaced the stage-3 bugs.

## Caveats

- **CLI processes, not the app.** Everything was measured in single-threaded CLI processes, not
  inside the Flutter engine's worker isolate. Flutter's release AOT is the same compiler as
  `dart compile exe`, but GC and the engine's VM flags may differ a little.
- **Shared heap and GC.** `Isolate.spawn` isolates share one heap. Blocking GC operations, such
  as new-space collections, "affect all isolates" of the group
  ([dart-lang/sdk#46754](https://github.com/dart-lang/sdk/issues/46754)). So a Dart layout's
  allocations can add GC pauses to the UI isolate. The layout allocates a few dozen large typed
  arrays (≈ 10 MB at 100k) and no per-node objects, so the risk is small. A Rust layout would
  allocate outside the Dart heap. The review measured it: no stall above the baseline noise at
  realistic relayout rates.
- **Synthetic lane counts.** The 134–173-lane shapes, and therefore the expensive `optimized`
  runs, are synthetic. The real 10k fixture has 3–4 lanes. A real large repo with many live
  branches in `all()` lies somewhere in between.
- **Not included in any timing:**
  - FFI transport: in both variants, the topology has to cross first;
  - the worker → UI-isolate hop, the same few MB in both variants;
  - jj's own topology walk: ≈ 3.3 ms at 10k (the virtualization research, §3);
  - the painter.
- **The Rust product rebuild ran on a scratch copy** of `Cargo.toml`, `Cargo.lock`,
  `rust-toolchain.toml` and `crates/`, with its own target dir. Ralph's `target/` was not
  touched. The machine runs Microsoft Defender real-time scanning, which slows every build a
  little.
- **Hot reload was verified with the plain Dart VM and a probe program,** not with `flutter
  run` on Zanshin itself.

## Recommendation

**Run the layout in Dart, in the worker isolate.** Rust keeps supplying the jj data:
topology, edge kinds and timestamps, as FlatBuffers scalar vectors that Dart can view as typed
arrays. It is the same data both variants need anyway.

### 1. Absolute times vs the UI budget

**The layout never runs on the UI thread,** so it cannot drop frames; it only adds latency
between a jj operation and the updated graph.
- **The budget that matters is that response latency.** About 100 ms still feels instant, the
  classic limit for "the system reacted".
- **The layout should use a small share of that,** about one 60 Hz frame (16.7 ms; 8.3 ms at
  120 Hz ProMotion). The rest is left to jj, the FFI and paint.

Against that:
- **Realistic default revset** (mutable work: tens to a few hundred commits): ≤ 0.25 ms in Dart
  for every mode and order. **The difference is irrelevant.**
- **`all()` at 10k:**
  - greedy: Dart 0.9–2.3 ms, Rust 0.34–0.66 ms;
  - optimized: Dart 2.1–2.5 ms on the real fixture, and 11–12 ms at 134–168 synthetic lanes.
  - Dart stays inside one frame every time, and adds at most ≈ 9 ms over Rust. That is
    comparable to jj's 3.3 ms topology walk; next to today's 1.2 s commit-load path it is
    nothing. **Still irrelevant.**
- **`all()` at 50k–100k:**
  - **greedy:** Dart 9–28 ms against Rust 3–9 ms. That is one to two frames of extra latency,
    probably not noticeable in a reload.
  - **optimized:** Dart 74–125 ms against Rust 25–36 ms. This is the one place where Dart alone
    exceeds 100 ms. But both miss a one-frame budget here, and the cost is set by the ordering
    phase's fixed work budget.
  - So either variant needs the same treatment at that size: lay out greedy at once, then run
    `optimized` afterwards or with a smaller budget.

### 2. Rust/Dart ratio

About 3× in AOT, ranging 1.6–5.3×. Warm JIT runs at 0.8–1.1× the AOT time from 10k up, and
within 1.8× from ≈ 600 nodes, so debug builds show about the same numbers. A real ratio, but it only matters in the 100k-optimized corner,
and the budget knob covers that corner in both variants.

### 3. Memory

The Rust layout needs ≈ 95 B per node: ≈ 1 MB at 10k and ≈ 10 MB at 100k. The Dart layout uses
the same flat arrays (plus an extra edge-child array), so it is the same order; that was
inferred, not measured. The process-level differences in the table come from JSON and the VM.
**Memory does not decide.**

### 4. Payload

The Rust variant ships ≈ 9 B per node more: +90 KB at 10k, +0.9 MB at 100k. That costs ≤ 1.2 ms
at 100k in FlatBuffers terms, against an 11–89 ms compute gap in the other direction.
**Payload does not decide.**

### 5. Iteration speed during the Time-layout experiments

**This decides it.** The row model (compact / time / free), the bucket ladder, the gap curve and
the ordering are all still open.
- **In Dart**, every experiment is an edit plus a hot reload into the running app, against a
  real repo. The worker is in the UI isolate's group, and that was verified above. It costs
  seconds, and the app state survives.
- **In Rust**, every experiment costs a ~6 s release rebuild of zanshin-graph and zanshin-ffi,
  plus a full app restart, and loses the open repo and scroll position.

Over dozens of tuning rounds, that gap matters far more than a 3× speed difference measured in
milliseconds.

### 6. Testability

**Rust is ahead here:**
- the coverage ratchet (per file ≥ 80 %, never dropping), clippy pedantic and inline tests;
- direct access to the jj fixtures through zanshin-jj.

**Dart has no coverage floor.** Its unit tests run in the gate (`dart test` in
`packages/zanshin_core`), but the ratchet is Rust-only, so a Dart layout has no enforced
coverage.

**Two things narrow the gap:**
- **The differential harness.** This spike shows that the strongest checks for a layout are
  differential: an oracle, invariants and a fuzzer, not line coverage. That harness works the
  same against a Dart implementation.
- **The FFI cost of a Rust layout.** A Rust layout adds FFI surface: the layout tables in the
  schema. Any new `extern fn` also needs a zanshin_core coverage test, the ratchet's rule for
  every extern fn.

**So Rust wins on enforced rigour, but not by enough to outweigh item 5.**

### 7. Not an argument

Reuse by the MCP server. Ralph tends to drop it.

### Guardrails for the Dart variant

- **Keep SPEC.md and the tools as the contract.** The spike shows a port is mechanical and can
  be checked byte for byte: the two implementations are about the same size, 1 238 vs 1 136
  lines of code. If the layout ever has to move to Rust, that is a day of work, not a rewrite.
- **Bound `optimized` by time or work, and show greedy first.** This is needed in either
  language at ≥ 50k rows with many lanes.
- **Allocate flat typed arrays in the layout, no per-node objects.** Isolates in one group
  share the heap and its GC pauses with the UI isolate.
- **Do not use `List.sort` / `Int64List.sort` on hot paths** (added by the review). The SDK
  sorts typed lists through a generic quicksort with a closure per comparison. Small
  monomorphic sorts cut the Dart layout by 35–65 %, or by 17–20 % where the many-lane sifting
  dominates.
- **Add a debug-only "relayout on reassemble" hook,** so a hot reload shows a layout edit at
  once.
- **Revisit once the row model is final and stops changing.** The iteration argument then
  weakens. A port to Rust (≈ 3×) is worth it only if real repos show 50k+ rows with many lanes
  in a view that people actually open.

## Review 2026-09-26

An adversarial pass over fairness and conclusions, before Ralph decides. The control runs used
scratch copies of the two implementations and scratch probes (not committed, like the stage-4
probes). Same machine and toolchains as the results above.

**Verdict: the recommendation stands, and the review strengthens it.** Dart in the worker
isolate. Two corrections do not touch the verdict: time and free need every commit object
(item 6), and the lane-order heuristic is close to the design's optimiser but not equal to it
(item 7).

### What changed in the spike

- **`tools/friction.mjs`: pinned toolchain.** The tool copies `rust/` to a work dir outside the
  repo, so rustup silently fell back to the default toolchain (1.96.1 here). The benchmarked
  binary was built with the pinned 1.95.0. The tool now copies the repo's `rust-toolchain.toml`
  into the work dir. Re-run: the same within noise; the friction table above holds the new
  numbers.
- **README.** The fixture description, the memory wording (Recommendation §3), the GC caveat
  and one new guardrail (monomorphic sorts), each pointing here.

No change to `rust/`, `dart/`, the SPEC or the benchmark data.

### 1. Same algorithm, same data layout: yes

- Both implementations use flat typed arrays (Rust `Vec<u32/i32/i64>`, Dart
  `Int32List`/`Int64List`), CSR adjacency, the same segment tree and top-2 trick in lane packing,
  and the same incremental sifting with the same work accounting. There are no hash maps and no
  per-node objects on either side.
- **Extra work.** Dart keeps an edge-child array and builds the sifter's incidence lists in a
  second O(E) pass. That is negligible.
- **Outputs.** All 162 re-run bench lines and the 48 stage-3 outputs agree on the digest.
- **Timing scope.** `total` is the same span in both: graph prep and layering through ordering.
  Parse and output building are excluded. Both keep the result alive, so nothing is optimised
  away.

### 2. The one real asymmetry: Dart's library sort

**Where it comes from.** Dart's `Int64List.sort()` / `Int32List.sort(cmp)` is the SDK's generic
`Sort.sort(this, compare ?? Comparable.compare)` (`lib/_internal/vm/lib/typed_data_patch.dart`).
It is a `List<int>` quicksort with one closure call per comparison, which AOT cannot inline.
Rust's `sort_unstable(_by)` is monomorphised. The stage-4 hypothesis ("inferred, not profiled")
is therefore right.

**Control.** A scratch copy of the Dart layout replaced the 5 sort call sites with plain
monomorphic quicksorts (≈ 150 lines, no packing, no `unsafe`): distinct bucket keys, the free
walk order, the packing visit order, and the per-lane `lo[]`/`hi[]`. Its output is
byte-identical on all 48 combinations.

**Nothing to port back.** SPEC §8.3's "apply it to both" does not bite here: Rust's std sort
already is what the hand-written Dart sort does.

Median of 3 bench processes each (W = 10, N = 31):

| input | mode / order | Rust | Dart AOT | AOT/Rust | Dart AOT, monomorphic sorts | /Rust |
|---|---|---|---|---|---|---|
| fixture-medium-all | time / greedy | 47 µs | 102 µs | 2.2× | 66 µs | 1.4× |
| fixture-large-all | compact / greedy | 470 µs | 939 µs | 2.0× | 614 µs | 1.3× |
| fixture-large-all | time / greedy | 556 µs | 1.36 ms | 2.4× | 759 µs | 1.4× |
| fixture-large-all | time / optimized | 697 µs | 2.50 ms | 3.6× | 921 µs | 1.3× |
| synth-10k | time / greedy | 643 µs | 2.37 ms | 3.7× | 1.25 ms | 1.9× |
| synth-10k | time / optimized | 3.68 ms | 12.06 ms | 3.3× | 10.05 ms | 2.7× |
| synth-100k | compact / greedy | 7.19 ms | 19.35 ms | 2.7× | 12.49 ms | 1.7× |
| synth-100k | time / greedy | 9.10 ms | 27.00 ms | 3.0× | 14.96 ms | 1.6× |
| synth-100k | time / optimized | 35.29 ms | 122.62 ms | 3.5× | 98.23 ms | 2.8× |

- **The gap on few lanes was the sorts.** On few lanes, Dart's `ordering` phase drops from
  1.14 ms to 0.15 ms (Rust 0.13 ms). It was the per-lane sorts, not the search.
- **What is left:** lane packing at 1.1–1.9×, and the sifting inner loop at many lanes at about
  3×. The latter is binary searches, probably their bounds checks: Rust's `partition_point`
  skips them internally. Not profiled.
- **Consequence.** The headline "≈ 3×" is about half a library artifact. The language gap is
  ≈ 1.2–1.9× outside many-lane `optimized`, including the real repo (item 5). That favours the
  Dart recommendation; it does not threaten it. It became a guardrail.
- **Corroboration.** Warm JIT beats AOT at 100k greedy (0.9×), likely because the JIT can
  inline the comparator into the generic sort after warm-up and AOT cannot.

### 3. Noise, warm-up, GC

- **Reproducible.** 3 re-runs of 9 combinations match the stage-4 medians within ±5 % (e.g.
  synth-100k time/optimized: Rust 35.3 ms [34.4–35.7] vs 36.2; Dart AOT 122.6 ms [119.7–124.7]
  vs 125.3). The min–max spread of the re-runs is ≤ 10 % at ≥ 10k nodes.
- **Sub-100 µs numbers are soft.** At 1k nodes a single process was occasionally 2× off, in both
  languages (CPU ramp-up in short processes). Take the design-sample and 1k rows as orders of
  magnitude, not ratios.
- **No GC bias from the benchmark's JSON.** Each iteration re-parses the JSON, and in Dart that
  garbage could trigger GC inside the timed layout. Control: parse once, outside the loop. Dart
  AOT totals moved by −3…+7 % at ≥ 10k (parse-once vs per-iteration: e.g. 12.46 vs 12.06 ms,
  26.86 vs 27.00 ms). There is no systematic effect.
- **Warm-up.** Irrelevant for Rust and AOT. JIT gets 10 warm-up runs, and cold numbers are
  reported separately.

### 4. Shared-heap GC stalls on the spawning isolate: measured, negligible

**Probe.** An AOT program with the pure Dart library:
- the main isolate spins on the clock for 4 s and records every gap (a stop-the-world GC of the
  group has to stop it at a safepoint);
- an `Isolate.spawn` worker runs the layout back to back on a pre-parsed input;
- baseline: the worker spins without allocating. 2 repetitions each.

| worker | layouts in 4.5 s | longest main-isolate gap | gaps > 1 ms |
|---|---|---|---|
| spins, no allocation (baseline) | – | 0.12 / 1.10 ms | 0 / 1 |
| synth-100k time/optimized | 35 | 0.19 / 1.02 ms | 0 / 1 |
| synth-100k time/greedy | 160 | 0.35 / 0.48 ms | 0 / 0 |
| synth-10k time/greedy | ≈ 1 950 | 0.54 / 0.52 ms | 0 / 0 |
| fixture-large-all compact/greedy | ≈ 4 600 | 0.73 / 3.03 ms | 0 / 7 |

- Only the last row, about one full layout per millisecond (on the order of 1 GB/s of typed
  arrays), shows stalls above the baseline noise: up to 3 ms, 7 times in 4 s.
- A real relayout happens per jj operation, orders of magnitude less often. Flutter's engine may
  tune the GC differently; the probe ran on the plain Dart VM.

### 5. Inputs: a real-history data point

**The fixtures are not organic history** (item 1 of the inputs list, corrected above). As a
real one, the review converted jj's own git history into a layout input:
- `git log --all --topo-order` of `../jj` at ede0888b, read-only: 15,482 commits, of which
  ≈ 3,900 are on PR and remote branches, with 11 merges;
- a virtual `root()` below the parentless commits;
- priority 0 on HEAD's first-parent chain, 2 elsewhere.

Rust and Dart are byte-identical in all 6 mode × order combinations. One bench process each:

| mode | lanes | greedy: Rust | Dart AOT | mono-sort Dart | optimized: Rust | Dart AOT | mono-sort Dart |
|---|---|---|---|---|---|---|---|
| compact | 16 | 0.82 ms | 1.54 ms | 0.96 ms | 1.16 ms | 3.84 ms | 1.44 ms |
| time | 15 | 1.11 ms | 3.73 ms | 1.62 ms | 1.39 ms | 5.94 ms | 2.14 ms |
| free | 15 | 0.99 ms | 3.12 ms | 1.54 ms | 1.33 ms | 5.53 ms | 2.07 ms |

- **A busy real repo's `all()` stays within one 60 Hz frame in stock Dart:** 1.5–5.9 ms. The
  ratio there is 1.9–4.3×, and 1.2–1.6× with monomorphic sorts.
- **15–16 lanes, not 134–173.** jj merges by rebase; a merge-heavy project would have more
  lanes. The synthetic 134–173-lane inputs stay the stress case, not the typical one.

### 6. Time and free need every commit object (both variants)

- **Timestamps are not in jj's index.** jj-lib 0.44 keeps committer timestamps in the commit
  objects, not in its index (its revset engine reads `commit.committer().timestamp`). So `time`
  and `free` cannot compute geometry from the index alone.
- **The cost is the commit load.** The virtualization research measured ≈ 3.3 ms for an
  index-only topology walk at 10k, but ≈ 1.17 s once every commit is loaded.
- **Consequences:**
  - The comparison "Dart adds ≈ 9 ms, comparable to jj's 3.3 ms topology walk"
    (Recommendation §1) holds for `compact` only.
  - In `time` and `free`, a ≈ 1.2 s load precedes the layout, which makes the Rust/Dart
    difference even less relevant.
  - It also breaks the research's "geometry from the index, content lazily" split for those two
    modes: the geometry itself needs every commit. That is a product question for the row-model
    decision, not a Rust/Dart one.

### 7. The scalable lane order against the design's optimiser

- **On the design sample:** the same design cost as the design's own optimiser on all 4 runs,
  with 0 crossings. default/time picks the equal-cost [0, 2, 3, 1] where the design picks
  [0, 3, 2, 1]. (`node tools/js_oracle.mjs`.)
- **On 569 random design-shaped graphs** (≤ 40 commits, 3–16 lanes, merge rates 15–50 %,
  monotone timestamps), scored with the design's own cost (`analyzeEdges`: crossings +
  collinear overlaps):
  - greedy: 17,192;
  - the design's optimiser: 8,406, −51 %;
  - SPEC §4.6 sifting: 8,702, −49 %.
  - Sifting ends with more crossings + overlaps than the design in 140 of 569 runs; by the
    design's total cost it is better / equal / worse in 83 / 311 / 175.
- **Where the gap is.** It sits at 3–8 lanes, +7 % in sum, where the design searches
  exhaustively. At 9–16 lanes, where the design hill-climbs, it is +2 % in sum.
- **So the heuristic keeps the design's intent at ≈ 96 % of its reduction.** If the default
  revset (typically ≤ 8 lanes) should match the design exactly, add an exact search for
  L ≤ 8 on top. That is the same work in either language.

### 8. Measured or guessed

| claim | status |
|---|---|
| layout times, ratios, phases | measured; reproduced by the review |
| parse times | measured; JSON, not the product path (as stated) |
| Rust layout heap ≈ 95 B/node | measured (counting allocator) |
| Dart layout heap | inferred from the code, not measured |
| FFI payload bytes | computed exactly from the outputs |
| FFI payload time | estimated, by scaling ffi-payload-bench rates; an upper bound |
| product Rust rebuild 5.85 s | measured on a scratch copy of the workspace |
| hot reload reaches the worker | the SDK docs plus a plain-VM probe; Flutter's own reload cycle on Zanshin not measured |
| GC coupling to the UI isolate | measured by the review (item 4) |

### 9. Does the recommendation follow from the numbers?

- **Speed does not decide.** Both variants are far below the budgets at realistic sizes: the
  default revset, a real 15k-commit `all()`, and the 10k fixtures. The one corner where Dart
  exceeds 100 ms (optimized, 100k, ≈ 170 lanes) needs the same budget fix in both languages.
- **The review makes Dart look better, not worse.** The Dart gap is half a library artifact,
  and GC coupling is negligible.
- **Iteration decides, and testability stays Rust's point;** both arguments are unchanged. One
  asymmetry is acknowledged: a standalone Rust harness with a viewer would iterate in ≈ 1.2 s
  per edit. That loop would run outside the app, without the real painter and the live repo,
  and the open questions are visual.
- **So:** Dart in the worker isolate, with the guardrails above, including monomorphic sorts.

## Lane order review 2026-09-26

**Trigger.** Ralph used the viewer on the real 1.4k-commit repo in `free` mode: "Optimized" does
not look optimised, it sprawls, and greedy is more compact. His screenshot marks a card that sits
one column further right than necessary, with the column to its left empty over a long vertical
stretch. Without a better order he leans to greedy.

This section is Dart-only work: the new order lives in `dart/` (SPEC §4.7); `rust/` and the
greedy/optimized semantics are unchanged. After the change, `tools/compare.mjs --digest` still
reports all 48 greedy/optimized combinations byte-identical (Rust ≡ Dart), and
`tools/fuzz.mjs --cases 150` agrees on all 900 runs. The Dart unit tests (34) pass.

### 1. Diagnosis: `optimized` moves whole lanes, and greedy's lanes are containers

- **Greedy reuses a lane for many unrelated branches.** First-fit packing (§4.3) puts every
  new branch into the leftmost lane that is free at that time. One greedy lane is therefore a
  sequence of unrelated occupants.
- **`optimized` permutes those lanes as wholes** (§4.6): one column per lane, for the entire
  history. A permutation that pays off in one busy period is applied to every other period too.
- **Its cost has no width term.** Disp = Σ |π(ℓ) − ℓ| counts columns per lane, not per occupied
  pitch. Moving a lane that is occupied 94 % of the time nine columns to the right costs 9, less
  than 1/40 of one crossing (400).

Measured on the real repo, `all()`, `free` mode (a throwaway analysis script, not committed;
occupancy = nodes plus vertical edge runs, as in `tools/lane-metrics.mjs`):

| greedy lane | occupied (share of 1,383 pitches) | separate runs | column under `optimized` |
|---|---|---|---|
| 0 (trunk) | 99.9 % | 1 | 0 |
| 1 | 94.2 % | 25 | **10** |
| 2 | 78.2 % | 29 | 4 |
| 3 (the marked card's lane) | 60.8 % | 34 | 2 |
| 4 | 36.4 % | 15 | 7 |
| 5 | 45.8 % | 1 | **11** |
| 6 | 25.4 % | 9 | 3 |
| 7 | 26.5 % | 3 | 8 |
| 8 | 7.2 % | 2 | 6 |
| 9 | 21.4 % | 1 | 9 |
| 10 | 6.7 % | 2 | **1** |
| 11 | 5.1 % | 1 | 5 |

- Lanes 8–11 exist only in one busy period (pitches 846–1,155 of 1,383), the only time greedy
  needs all 12 lanes. That is where the crossings are, and the sifting optimises that period.
- The result: column 1 holds lane 10, which is occupied for 6.7 % of the history. For the other
  93 % column 1 is empty. The two busiest non-trunk lanes (94 % and 46 %) sit in columns 10 and
  11.
- **The marked card** (node 15; a branch-off from the trunk with a 10.8-pitch run) sits in
  column 2. Column 1 is empty over its entire run, and lanes 1 and 5 are busy in columns 10 and
  11. So the row there is 12 columns wide, against 6.33 under greedy. The visible symptom is one
  column; the real loss is the six columns to the right of it.
- **Whole graph:** `optimized` halves the crossings (382 → 190) and nearly doubles the mean
  width (6.01 → 11.15 columns). Empty cells go from 15 % to 55 % of the occupied width. The same
  holds in `compact` and `time` mode and on synth-10k (tables below).
- **Control experiment.** The new windowed search (§3) with the width term switched off
  (κ = 0) gives 91 crossings, a mean width of 7.89 and a 12-column row at the marked card. So a
  crossings-only objective spreads the graph by itself, and the whole-lane permutation spreads it
  over all of history. Both halves of the fix are needed: a width term and a finer unit than the
  lane.

### 2. Metrics: `tools/lane-metrics.mjs`

`node tools/lane-metrics.mjs [--json] [--node IDX]… <output.json>…` works on output files alone:
- **cross:** H×V crossings of the routed edges, drawn the way the viewer (the design's
  `routeEdges`) draws them, at the viewer defaults (card 240×62, gaps 56/48). Pairs of edges
  that share an endpoint node are skipped, like the design's `analyzeEdges`. This is not the
  §4.6 tick model, which counts those pairs.
- **hlen:** total horizontal run length, Σ |col(p) − col(i)| over the non-straight edges.
- **maxW / meanW:** the rightmost occupied column + 1, maximal and averaged over the row units
  that hold a node or a vertical edge segment. maxW equals `lanes` for every order here.
- **holes / holes %:** per row unit, the empty columns left of the rightmost occupied one,
  summed and expressed in column × row pitches; and as a share of the occupied width.
- **lanes**, and with `--node`, a node's column and its left slack (the leftmost column whose
  cells over the node's incoming run are free).

### 3. The new order: `compact` (SPEC §4.7, Dart-only)

**What it does.** Greedy's packing stays the starting point. Its continuation chains (segments)
stay intact, so every straight edge, i.e. every first-parent continuation, stays straight. The
search exchanges the segments of two columns inside one time window at a time: a window is a
connected group of overlapping reservations of the two columns. An exchange stays when it lowers
U·(400·X + 4·Len) + κ·Σ column × reserved length, with κ = 24. The trunk column never moves.
Exchanges reach 8 columns, run up to 16 rounds and stop at a 2,000,000-unit budget. Columns left
empty are dropped at the end. (The name clashes with the `compact` row mode; the CLI keeps them
apart as `--order compact` and `--mode compact`.)

**Why this and not the three candidates alone** (reasoning, not measured separately):
- *(c) a width term in the whole-lane sifting* weights a lane by its total occupancy, but the
  lane still gets one column for all of history. A lane that is busy in one period and idle in
  another cannot be left in one and out of the way in the other.
- *(b) left-compaction after the permutation* keeps the permutation's order in the busy period,
  and checking each move's crossings is the windowed search anyway.
- *(a) choosing among the free columns while packing* sees only what is already packed; the
  merges and branch-offs that decide the crossings of an interval arrive later.
- *So:* (a)'s granularity (per segment and time window), run as a local search after packing,
  with (c)'s cost (crossings + run length + a width term). Every kept exchange lowers the cost, so
  the model cost is never above greedy's (a unit test checks it on random graphs, together with
  the invariants, determinism, lane 0 and unchanged routes).

**Constants.** Real repo, `all()`, each κ at reach 8:

| κ | free: crossings / mean width / holes % | time: the same | compact: the same | free: row width at the marked card |
|---|---|---|---|---|
| 0 | 91 / 7.89 / 35.6 | 97 / 7.75 / 37.4 | 40 / 6.07 / 32.9 | 12.00 |
| 8 | 128 / 6.32 / 19.6 | 129 / 6.03 / 19.5 | 61 / 5.54 / 26.4 | 7.00 |
| 16 | 171 / 5.83 / 12.9 | 171 / 5.73 / 15.3 | 80 / 5.33 / 23.5 | 7.00 |
| **24** | **213 / 5.66 / 10.3** | **203 / 5.60 / 13.3** | **70 / 5.15 / 21.0** | **6.00** |
| 32 | 247 / 5.52 / 8.0 | 256 / 5.41 / 10.3 | 80 / 5.15 / 21.0 | 6.00 |
| 48 | 273 / 5.49 / 7.5 | 275 / 5.30 / 8.4 | 117 / 4.66 / 12.6 | 6.00 |
| greedy | 382 / 6.01 / 15.4 | 425 / 5.75 / 15.6 | 185 / 5.96 / 31.7 | 6.33 |

- κ = 24 is the smallest tested gravity that is narrower than greedy at the marked card; larger
  κ trade crossings for little width.
- Reach (free, κ = 24): 1 → 229 crossings, 2 → 223, 4 → 205, 8 and 12 → 213. The mean width is
  best at 8 and 12 (5.66; 5.73–5.91 at 1–4).
- On the real repo the search converges before the round and work limits: an unbounded run ends
  at the same cost in all three modes.

### 4. Results (2026-09-26)

Dart AOT on the same machine as [Results](#results-2026-09-26-apple-m4-pro-14-cores-24-gb-macos-270-26a428-on-ac-power).
Per cell the orders greedy / optimized / **compact**; the percentage is `compact` against greedy.

| input | mode | lanes = max width | crossings | h-run | mean width | holes % |
|---|---|---|---|---|---|---|
| real repo, `all()` | compact | 10 / 10 / 10 | 185 / 97 / **70** (−62 %) | 703 / 836 / 505 | 5.96 / 8.27 / **5.15** | 31.7 / 50.7 / 21.0 |
| real repo, `all()` | time | 12 / 12 / 12 | 425 / 206 / **203** (−52 %) | 852 / 1414 / 629 | 5.75 / 11.10 / **5.60** | 15.6 / 56.2 / 13.3 |
| real repo, `all()` | free | 12 / 12 / 12 | 382 / 190 / **213** (−44 %) | 806 / 1368 / 639 | 6.01 / 11.15 / **5.66** | 15.4 / 54.5 / 10.3 |
| real repo, default | compact | 5 / 5 / 5 | 3 / 0 / **0** | 12 / 14 / 15 | 2.83 / 3.50 / **3.67** | 23.5 / 38.1 / 40.9 |
| real repo, default | time | 3 / 3 / 3 | 1 / 0 / **0** | 8 / 9 / 8 | 2.27 / 2.09 / **2.00** | 24.0 / 17.4 / 13.6 |
| real repo, default | free | 3 / 3 / 3 | 1 / 0 / **0** | 8 / 9 / 8 | 2.28 / 2.21 / **2.13** | 20.9 / 18.4 / 15.0 |
| fixture-medium-all | compact | 3 / 3 / 3 | 0 / 0 / **0** | 6 / 6 / 7 | 2.77 / 2.77 / **2.31** | 58.3 / 58.3 / 50.0 |
| fixture-medium-all | time | 4 / 4 / 4 | 0 / 0 / **0** | 7 / 6 / 7 | 3.53 / 2.84 / **2.38** | 39.2 / 24.4 / 9.7 |
| fixture-medium-all | free | 4 / 4 / 4 | 0 / 0 / **0** | 6 / 6 / 7 | 2.99 / 2.99 / **2.59** | 20.1 / 20.1 / 7.7 |
| synth-10k | compact | 134 / 134 / 134 | 23355 / 11382 / **15105** (−35 %) | 30698 / 31947 / 26286 | 50.19 / 74.20 / **52.97** | 37.6 / 57.8 / 40.9 |
| synth-10k | time | 168 / 168 / 168 | 32766 / 23611 / **29134** (−11 %) | 44374 / 46828 / 39902 | 66.58 / 93.31 / **64.11** | 45.4 / 61.1 / 43.3 |
| synth-10k | free | 168 / 168 / 168 | 29251 / 17358 / **21705** (−26 %) | 39907 / 46356 / 33117 | 60.93 / 98.13 / **60.09** | 38.0 / 61.5 / 37.2 |
| design-all | compact | 4 / 4 / 4 | 0 / 0 / **0** | 10 / 10 / 10 | 2.08 / 2.08 / **2.00** | 14.8 / 14.8 / 11.5 |
| design-all | time | 4 / 4 / 4 | 2 / 0 / **0** | 10 / 13 / 10 | 2.32 / 2.68 / **2.53** | 2.3 / 15.7 / 10.4 |
| design-all | free | 4 / 4 / 4 | 1 / 0 / **0** | 10 / 13 / 11 | 2.32 / 2.90 / **2.62** | 0.0 / 20.2 / 11.4 |
| design-default | compact | 3 / 3 / 3 | 0 / 0 / **0** | 5 / 5 / 5 | 2.14 / 2.14 / **2.14** | 6.7 / 6.7 / 6.7 |
| design-default | time | 4 / 4 / 4 | 2 / 0 / **0** | 7 / 7 / 7 | 2.83 / 3.17 / **3.17** | 2.9 / 13.2 / 13.2 |
| design-default | free | 4 / 4 / 4 | 1 / 0 / **0** | 7 / 7 / 8 | 2.92 / 3.47 / **3.47** | 0.0 / 16.0 / 16.0 |

All 54 outputs pass the invariants I1–I6 (`tools/compare.mjs`'s check).

**The marked card** (real repo, `all()`, node 15):

| mode: measure | greedy | optimized | compact |
|---|---|---|---|
| free: column (leftmost free column over its run) | 3 (3) | 2 (1) | 3 (3) |
| free: row width / empty cells over its run | 6.33 / 1.79 | 12.00 / 7.46 | **6.00 / 1.46** |
| time: column (leftmost free column over its run) | 7 (3) | 2 (1) | 3 (3) |
| time: row width / empty cells over its run | 8.00 / 3.78 | 12.00 / 7.78 | **6.00 / 1.78** |
| compact: column | 0 | 0 | 0 |

Under the `compact` order the card keeps greedy's column 3 in `free` mode. Column 1 is busy for
9.7 and column 2 for 4.7 of the 10.8 pitches of its run, so no column further left is free over
the whole run.
The hole to its left (Ralph's screenshot) and the six columns to its right are gone. In `time`,
greedy's own four-column slack at this card disappears too.

**Timings.** Dart AOT `bench`, median of 31 runs after 10 warm-ups, one process per
combination:

| input | mode | total layout: greedy / optimized / compact | ordering phase: optimized / compact |
|---|---|---|---|
| real repo, `all()` | compact | 155 µs / 608 µs / 2.51 ms | 451 µs / 2.34 ms |
| real repo, `all()` | time | 272 µs / 577 µs / 3.47 ms | 322 µs / 3.19 ms |
| real repo, `all()` | free | 241 µs / 598 µs / 3.04 ms | 370 µs / 2.80 ms |
| real repo, default | all | ≤ 3.3 µs / ≤ 4.1 µs / ≤ 12 µs | ≤ 1.9 µs / ≤ 11 µs |
| fixture-medium-all | all | 86–113 µs / 186–204 µs / 199–232 µs | 94–104 µs / 118–126 µs |
| synth-10k | compact | 1.57 ms / 10.40 ms / 31.45 ms | 8.74 ms / 29.85 ms |
| synth-10k | time | 2.14 ms / 11.53 ms / 33.52 ms | 9.31 ms / 31.25 ms |
| synth-10k | free | 1.68 ms / 10.45 ms / 32.29 ms | 8.86 ms / 30.73 ms |
| design-all / -default | all | ≤ 7.0 µs / ≤ 11 µs / ≤ 16 µs | ≤ 4.6 µs / ≤ 10 µs |
| synth-100k (3 runs) | all | — / — / 72–86 ms | — / 53–58 ms |

On the real repo, `compact` costs about 3 ms per layout (greedy 0.2 ms). On synth-10k (134–168
lanes) the budget binds at ≈ 30 ms: an unbounded run (`free`, 620 ms) would reach 19,707
crossings and a mean width of 46.4 (18.7 % holes), against 21,705 / 60.09 at the budget.

### 5. Recommendation

- **`compact` beats greedy on the real repo's `all()` in every mode and on every metric:**
  44–62 % fewer crossings, 21–28 % less horizontal run, a slightly narrower graph (−3 to −14 %
  mean width), fewer holes, the same lane count. It also has fewer crossings than `optimized` in
  `compact` and `time` mode (70 vs 97, 203 vs 206) and 12 % more in `free` (213 vs 190), at
  50–62 % of its mean width.
- **`optimized` has no remaining case** on the real `all()`: it is the widest in every mode
  (50–56 % holes), and its one lead, 23 fewer crossings in `free`, costs twice the width. Drop it.
- **Default: `compact`, with greedy as the cheap fallback**, if ≈ 3 ms per layout at 1.4k
  commits and ≈ 30 ms at 10k are acceptable in the worker. Otherwise greedy; the gap is mostly
  crossings, not width.
- **Before deciding, look at it.** The viewer shows `compact` now (Lane order → Compact; §7).
  Small graphs are where it can disappoint: on the default
  revset in `compact` mode it removes the last 3 crossings and widens from 2.83 to 3.67 columns
  (`optimized` does the same). κ is the knob for that trade.
- **Open:** stability under edits (SPEC §11.6; a new commit can re-cut a window), and for
  histories with 100+ lanes a larger or time-based budget, or painting greedy first and swapping
  in `compact` when the worker finishes.

### 6. Adversarial review (2026-09-26)

A second pass over `compact`, with the final binary. Throwaway scripts, not committed.

**Holds.**
- Deterministic: two runs byte-identical for all 63 outputs (7 inputs × 3 modes × 3 orders) and
  for synth-100k in all modes. The search uses no hash-ordered collection.
- I1–I6 (`tools/compare.mjs`'s check) pass on all 63 outputs and on synth-100k.
- Against greedy on every input: routes are equal, `blocked` is equal on every edge (first-parent
  branch-offs included), and lane-0 nodes are exactly the column-0 nodes. No two cards overlap.
- Edges through a card they do not belong to (viewer geometry): equal for all three orders in the
  row modes; these are blocked-merge verticals passing behind a card (D9). In `free` the counts are
  horizontals crossing a card (buses do not sit in row gaps there): real repo greedy 11 / optimized
  15 / compact 13; design 1 / 0 / 2; synth-10k 534 / 464 / 474.
- Rust ≡ Dart for 48 of 48 greedy/optimized combinations (`--digest`); fuzz 900 of 900.
- synth-100k: ordering 50–54 ms, total 68–79 ms (Dart AOT, median of 3).
- `tools/lane-metrics.mjs`: its crossing count is the viewer's `crossings()` (same segments, 1 px
  tolerance, shared-endpoint skip) over the whole graph.

**Fixed.** The skip rule (SPEC §4.7, "Skipping") was unsound for blocked merges. A window's
span started at 10·min a − 3U, but a blocked merge's horizontal lies below its child segment's
clipped vertical. On random graphs, 18 of 9,000 unbounded searches then ended at a different cost
than the search without skipping. The span now also covers incident horizontals, and all 9,000
agree; a unit test pins this. No spike input's output changed, so §4's numbers stand.

**Caveats the aggregates hide.**
- **Local regressions, `free`, real repo.** Per row unit, `compact` is wider than greedy in 7.8 %
  of the history (by ≥ 3 columns in 3.1 %) and narrower in 31.3 %. Per 8-pitch viewport (step 2):
  wider in 43 of 692 windows, narrower in 200; more crossings in 31, fewer in 204. In `time`: wider
  in 22 % of the rows, narrower in 39 %.
- **The worst spot has the screenshot's pattern.** About 40 pitches, roughly 645–685 counted from
  the newest row, are 7 columns wide instead of 4, with columns 3–5 empty. The cause is one
  segment: a 5-commit branch that lives 573 pitches (41 % of the history) and keeps receiving
  merges from the trunk. A segment cannot be split, so any exchange that moves it moves everything
  that overlaps it in the partner column. Exchanges that pay off elsewhere in its life (pitches
  ≈ 240–380 get 3 columns narrower) carry it from column 1 to column 6 for its whole life. That
  includes a quiet stretch where it alone sets the width. The linear gravity κ·Σ col·length
  accepts that trade; the viewer would show the screenshot's pattern. This is `optimized`'s
  whole-lane problem at segment scale: rarer, and on 3 % of the history instead of all of it.
- **The budget truncates the first sweep at scale.** On synth-10k in `compact` mode the search
  stops inside the first sweep of adjacent pairs (d = 1), at column pair 59/60 of 134. In `free`
  it stops in that sweep's last pair (166/167), and in `time` it reaches d = 5. On synth-100k
  it stops at d = 1 with columns 9–11 of 147–173, so only the leftmost dozen columns ever move.
  A window costs up to 103k units: every incident horizontal is charged each column it crosses,
  and every member enumerates each horizontal in its vertical extent. The truncation is why
  synth-10k in `compact` mode ends wider than greedy: 15,105 crossings and a mean width of 52.97
  (40.9 % holes), against greedy's 23,355 / 50.19 (37.6 %). Unbounded (484 ms) it reaches
  11,548 / 43.23 (27.5 %). At 10k commits the ≈ 30 ms buy a partial pass that favours the left
  columns, not a converged order.

**Verdict for `free`.** On the real repo `compact` is better than greedy in aggregate and at the
marked card. It is not uniformly better: it has one visible stretch of the kind Ralph complained
about. So the recommendation stands, with its condition made explicit: look at the stretch above in
the viewer before making `compact` the default; greedy stays a defensible default.

### 7. In the viewer (2026-09-26)

The viewer now has Lane order → **Compact** (bundle v2; see [Viewer](#viewer)). Its info bar lists
the three orders' whole-graph metrics for the current mode, the selected one in bold. They are the
same numbers as in §4.

**At the marked card** (real repo, `all()`, `free`, detailed 240 px cards): go to commit, then the
scroll area 1318×1588 px, with the card about 240 px below the top edge, as in Ralph's screenshot.
Headless Chrome, driven over CDP by a throwaway script. The screenshots stay outside the repo
because they show the real repo's commit titles. "Run" is the card's incoming run, 10.8 pitches.

| | greedy | optimized | compact |
|---|---|---|---|
| column of the marked card | 3 | 2 | 3 |
| columns empty over its run | 7–11 | **1**, 5, 6, 8, 9 | 6–11 |
| stretch width (rightmost used column + 1) | 7 | 12 | **6** |
| crossings in the frame (columns 0–3 visible) | **5** | 10 | 8 |

- **Optimized** reproduces the screenshot: column 1 is empty over the whole run, and the stretch
  reaches column 11.
- **Compact** keeps the card in greedy's column 3 and leaves no fully empty column left of the
  rightmost one. In this frame it moves exactly two cards: a one-commit branch from greedy's
  column 6 to column 2, and the card that sat in column 2 to column 3. Everything else keeps its
  greedy column.
- **The trade is visible here.** That branch's long incoming vertical now crosses three trunk
  merge buses, so the frame has 8 crossings against greedy's 5, while the stretch is one column
  narrower. Column 4 stays about 85 % empty over the run under both greedy and compact.
- **Checked:** every dataset × mode (Time+gaps included) × order loads without a page error.
  For all 84 combinations, the columns equal the bundle's, the rightmost column is `lanes − 1`,
  no two cards overlap, and the info bar bolds the selected order. The bundler's compact checks
  hold on all 7 inputs, and its metrics equal the table in §4.

## Product decisions 2026-09-27

Ralph used the viewer on a copy of a real 1.4k-commit repo and decided what the product keeps
(console session). They are recorded in `_bmad-output/planning-artifacts/epics.md` (the Epic 10
header's "Product decisions 2026-09-27", and Stories 4.10, 4.11, 10.2, 10.4, 10.5, 10.7 and
10.13). The spike keeps its experimental modes, orders, code and sections as its reference and
history.

- **Layout modes:** `free` is the default, `compact` the only other. `time` and Time+gaps are
  dropped. The row-model question at the top of this README is answered: free y.
- **Lane orders:** `compact` (SPEC §4.7) is the default, greedy the alternative and the fallback.
  `optimized`, the design's default ("Min. crossings"), is dropped, as
  [§5 of the lane order review](#5-recommendation) recommended.
  `compact`'s limits stay recorded (§6: in `free`, wider than greedy in 7.8 % of the real history's
  row units; the budget binds from about 10k commits).
- **Labels:** the viewer's localisable labels stay for now: English by default, as in the design,
  and `?lang=de` for German. Whether the app is English-only or translated is open.
- **Intended deviations from the design** that Ralph wants kept from the viewer:
  - crossing gaps are the only option: always on, no plain variant, no toggle;
  - content fades as it scrolls under the sticky gutter (the design's Time gutter gradient,
    GC:57, kept in Free's day gutter);
  - the current date is pinned: the day at the top of the viewport stays in the gutter until
    the next day's label pushes it out.
- **Edges leave a card's top at the centre** (recorded only; the viewer is not updated). Every
  edge already enters its child from below at the centre (Ralph noticed it at merge commits), and
  `straight` and `merge` already leave the parent's top at the centre; only a branch-off leaves at
  ±0.28·W. Ralph wants every edge to leave at the centre too. That is painter geometry: route
  classes, `blocked` and every output stay unchanged, so no golden changes. The planned SPEC
  change is [SPEC §12](SPEC.md#12-product-decisions-2026-09-27). The viewer, and
  `tools/lane-metrics.mjs`'s crossings as drawn, keep the side exit, so their numbers above are
  side-exit numbers.
- **Not decided:** `free`'s constants and whether buses may pass behind cards (SPEC §11.1, D8),
  blocked-merge routing (§11.4, D9), the source of free's day buckets (the viewer computes the
  days itself; Story 4.11 open question 9), and `compact`'s stability under edits (§11.6) and
  its budget at 10k+ commits. Story 4.11's port drops `time` and `optimized` (decided
  2026-09-27, Ralph: "the rest can go"); the spike keeps them as reference and history.
