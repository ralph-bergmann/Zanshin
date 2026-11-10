# Graph-layout A/B — algorithm spec (v1, 2026-09-26)

*(Amended 2026-10-01, Story 4.11: this file moved here from `spikes/graph-layout-ab/SPEC.md`,
which is now a pointer. Paths below that start with `rust/`, `dart/`, `tools/`, `inputs/`,
`outputs/`, `rust-inputs/` or `viewer/` mean `spikes/graph-layout-ab/…`. The product engine,
`packages/zanshin_core/lib/src/graph_layout/`, is a third implementation, of the shipped scope
only (§12, §13). The dated amendments of Story 4.11 are §2, §3, §4.2, §4.3, §4.5, §7.3, §11.2,
§12 and the new §13.)*

*(Amended 2026-10-01, Story 4.13: the dated amendments of Story 4.13 are §2, §3, §4.8 (new), §6,
§7.3, §9 and §13.)*

*(Amended 2026-10-27, Story 4.14: joint columns — one lane packing and one column order shared by
`compact` and `free`, as the floating-client export `e74ced3` lays them out. The dated amendments
of Story 4.14 are §2, §3, §4.2, §4.3, §4.7, §4.8, §6, §7.2, §7.3 and §13.)*

*(Amended 2026-10-27, Story 4.15: line router B — one line per parent → child pair, as a
`zanshin_core` library. Its rules are the new §14; the dated amendments of Story 4.15 are §4.5,
§7.2 and §12. No layout output changes: `route`, `blocked`, the grid format and every golden stay.)*

*(Amended 2026-10-31, Story 4.16: free's day band — with joint columns no card sits in the band
around a day divider. The dated amendments of Story 4.16 are §4.2, §4.8, §6, §7.3, §9 (new D12) and §13.)*

*(Amended 2026-11-10, Story 4.17: columns by branch, per mode — the graph layout lab's column rule
(`spikes/graph-layout-lab`, Ralph 2026-11-10) replaces the joint packing, the short-piece return, the
lane orders and the closing pass in the product. The dated amendments of Story 4.17 are §2, §3, §4.2,
§4.3, §4.6, §4.7, §4.8, §5, §6, §7.2, §7.3, §8.2, §9 (new D15), §12 and §13. Ungrouped rows do not
change. Grouped rows can, because §4.8's constraint (C) is restated for branch columns.)*

*(Amended 2026-11-10, Story 4.18: lines by the lab's rules — the graph layout lab's line rules
(`spikes/graph-layout-lab/lib/lines.dart`, Ralph 2026-11-10) replace router B's classes, gutter budget,
unit rule and hooks. The dated amendments of Story 4.18 are §4.3, §4.8, §7.2, §9, §12 and §14 (§14.2
and §14.3 rewritten). No layout output changes.)*

The contract for both implementations (`rust/`, `dart/`). Each one is written from this
document alone and MUST produce **byte-identical output** for every input × mode × order.
Where this spec and the design differ, the spec wins; every deliberate difference is listed
in §9. Points the stage-3 differential check settled are marked *Clarified during diff*.

Design sources: `_bmad-output/implementation-artifacts/design/graph-view.jsx` (GV:
`timeBucket` :10-17, `routeEdges` :52-69, `analyzeEdges` :72-96, `optimizeLanes` :99-138,
`computeLayout` :140-225) and `graph-data.js` (GD), read together with the verified design
extraction of 2026-09-26 (session notes, not committed); its verifier corrections are applied
here.

## 0. Scope

The layout maps a revset-induced commit DAG, supplied by Rust from jj, onto an abstract grid:
per node `(row, lane, col)`, per edge `(route, blocked)`, per time bucket a row range. The output
holds integers and enums only. Card width W and height H are not inputs, and they cannot matter:
the verifier confirmed that W and H never change rows, lanes or columns in the design, even under
its optimiser. The painter maps the grid to pixels (§4.5).

**The row model is undecided** (Ralph, 2026-09-26: a fixed row-based layout, or a "free" one
whose vertical spacing follows the time line). So that the Rust-vs-Dart verdict does not hinge
on that decision, the spike has three modes (*decided 2026-09-27: the product keeps `free`, the
default, and `compact`; §12*):

| mode | vertical position | source |
|---|---|---|
| `compact` | longest-path depth (rows) | design "Compact" |
| `time` | the design's age/day buckets (rows) + a topological clamp (D1) | design "Time" |
| `free` | continuous: compressed commit time, each child ≥ 1 pitch above its parents | new (D8), provisional constants |

The hybrid also discussed for the design (time rows, with the gaps between buckets sized by
elapsed time) is a painter-side prefix sum over `buckets`, O(#buckets). It needs no layout mode.

**Not part of the layout:**
- pixel geometry and rounded corners;
- crossing gaps (the "bridges", or line hops): the UI painter computes them for the *visible*
  edges only, so nothing here replaces the design's O(E²) `analyzeEdges`;
- elided counts ("~ N elided"), which need an index walk per Missing parent;
- highlight sets (@ ancestors, hover focus);
- lane stability across reloads;
- the FFI transfer itself.

## 1. Conventions

- **Integers only.** All arithmetic is signed 64-bit; no floating point in any decision or
  output. Every integer in input and output lies in [−2^53, 2^53], because the JS tools read
  numbers as doubles.

  *Clarified during diff (2026-09-26):* one exception is accepted rather than validated away. A
  `day` bucket's `value` lies up to one day below its members' ts, so for a ts within a day of
  −2^53 (some 285 million years BC) it falls just below −2^53. Both implementations compute it
  exactly in 64 bits; only a JS reader would round it.
- **Floor division.** `a div b` and `a mod b` (b > 0) are floor division and its non-negative
  remainder. Rust: `div_euclid` / `rem_euclid`. Dart's `~/` truncates toward zero, so use
  `(a - a % b) ~/ b`; Dart's `%` is already non-negative.
- **Determinism.** Every sort key below is total, so ties are impossible. No result may depend
  on hash-map or hash-set iteration order: use index-addressed arrays.
- **Notation.**
  - n = nodes, indexed 0..n−1 in input order;
  - E = layout edges (§4.1), H = non-straight edges, L = lanes;
  - U = units per row pitch: 1 in `compact` and `time`, 16 in `free`.
- **Ordering key.** `key(i) = (priority(i), i)`, compared lexicographically. Lower packs
  further left and wins lane continuation.

## 2. Input

```json
{"now_ms":1790344800000,"utc_offset_min":0,"nodes":[{"id":"9f3a…","ts_ms":1790344500000,"is_root":false,"priority":1,"parents":[{"idx":4,"kind":"direct"},{"idx":null,"kind":"missing"}]}]}
```

| field | meaning |
|---|---|
| `now_ms` | the fixed "now"; used by `time` only |
| `utc_offset_min` | the viewer's fixed UTC offset for calendar days; `time` and `free` (D7). *(Amended 2026-10-01, Story 4.11: was "`time` only"; `free` now emits day buckets, §4.2.)* |
| `nodes` | in jj log order: children before parents |
| `id` | hex commit id; for debugging only, the layout never reads it |
| `ts_ms` | committer timestamp in epoch ms; `null` for the root |
| `is_root` | true for the `root()` commit |
| `priority` | ordering class ≥ 0; need not be unique (ties fall to the index) |
| `parents` | jj's graph edges in stream order. `direct` and `indirect` carry `idx`, the target's node index; `missing` carries `idx: null` |

*Amended 2026-10-27, Story 4.14:* with joint columns (`--columns joint`, §6; the product always,
§13) every layout computes both vertical models (§4.3), so `ts_ms` is read in `compact` too (by the
`free` model the packing uses), and the product reads `utc_offset_min` in both modes (every node's
day key, §4.2 free step 4). Without joint columns nothing changes.

*Amended 2026-11-10, Story 4.17:* a product layout request has a mode and, optionally, a stack
request; it has neither a lane order nor a budget. The product still reads `ts_ms` and
`utc_offset_min` in both modes, because every node's day key needs the clamped T (§4.2 free step 4).
`layering()` also keeps computing both vertical models, because the lab's `same-columns` variant
reads them. The product's columns use only the requested mode's rows (§4.3, Branch columns).

**Validation.** A violation exits with code 2, prints a message on stderr and writes no output
file.
- V1: `idx` is null ⇔ `kind` = `missing`.
- V2: a non-null `idx` of node i satisfies i < idx < n.
- V3: no two parents of one node share an `idx`.
- V4: `priority` < 2^31, and every integer is within ±2^53.

Parsers accept any valid JSON (any whitespace, any key order). Producers write the canonical
form of §3.

*Clarified during diff (2026-09-26).* The stage-3 probes (`tools/fuzz.mjs`) and the
implementers' notes turned up these gaps, most of which Rust and Dart read differently. Both now
follow the rules below.
- **V4, extended.** 0 ≤ `priority` < 2^31 (the table's "≥ 0"; both already did this) and
  |`utc_offset_min`| ≤ 1440. Without that bound `utc_offset_min · 60000` overflowed int64:
  release Rust and Dart wrapped silently, debug Rust panicked.
- **Required fields.** Every field in the table except `id` is required. The nullable ones
  (`ts_ms`, `idx`) need an explicit `null`; an absent key is invalid. (Rust's serde read an absent
  key as null, Dart rejected it.) `id` may be absent and may hold any JSON value.
- **"Any valid JSON"** means:
  - any whitespace and any key order;
  - unknown keys are ignored, whatever their value or nesting depth;
  - a duplicate key keeps its last value, as in `JSON.parse` and `dart:convert`;
  - the text is UTF-8 throughout, including strings the layout ignores (Rust skipped `id`
    unchecked, Dart's decoder rejected it); with both checking, parse costs stay comparable (§8.3);
  - no byte-order mark (RFC 8259 §8.1 allows either choice; Dart's decoder skipped it, serde_json
    and `JSON.parse` reject it).
- **Integers.** An integer field takes a JSON number without fraction or exponent. `-0` is the
  integer 0: serde_json reads it as the float −0.0, so Rust used to reject it, while dart:convert
  reads the int 0. `-0.0`, `1.0` and `1e3` are invalid.
- **Known residual, left as is.** One document shape still splits the two: a duplicate key AND
  nesting deeper than 128 levels. Rust rejects it, because its duplicate-key retry goes through
  `serde_json::Value`, which has a recursion limit of 128. Dart accepts it. No producer writes
  either.

**What the dumper (stage 2) writes.**
- **Nodes and edges:** the `jj log` pipeline, exactly as `zanshin-jj`'s `walk_graph` runs it:
  - the revset is evaluated at head;
  - `TopoGroupedGraph` gets `prioritize` passed through (pre-filled with `present(@)`);
  - edges are kept as jj-lib yields them: Direct / Indirect / Missing, deduplicated, with
    transitive indirect edges pruned. jj never yields duplicate targets, so V3 holds.
- **`ts_ms`:** the committer timestamp, which is what `jj log` shows (committer vs author is an
  open design question). The root gets `null`.
- **`now_ms`:** the time of the dump, unless a flag pins it. **`utc_offset_min`:** the local
  offset at `now_ms`.
- **`priority`:** a stand-in, because the real source is an open question.
  - 0: `trunk()` and its first-parent chain inside the dumped graph, following each node's
    first non-missing edge;
  - 1: `@` and its first-parent chain, up to the first class-0 node;
  - 2: everything else.

  Ties fall to jj log order: the earlier-printed commit packs left and continues its parent's
  lane, as in `jj log`'s column assignment. A class whose anchor is not in the revset is empty.

*Amended 2026-10-01, Story 4.11.* The dumper (`rust-inputs/`) now reads `zanshin_jj`'s
`Repo::graph_topology` (Story 4.10) instead of `walk_graph`, and its viewer sidecar's object half
from `Repo::commit_contents` at the topology's operation. Three of the rules above change:
- **Nodes and edges.** The topology call runs the same `jj log` pipeline (revset at head,
  `TopoGroupedGraph` with `prioritize`), and its edges are jj's verbatim. The sentence "jj never
  yields duplicate targets, so V3 holds" was wrong: jj-lib 0.44 does yield repeated targets (a
  merge whose parent P is in the revset and whose other, hidden parent reaches P again gets
  Direct(P) and Indirect(P)). **Repeated targets:** a producer keeps ONE parent per
  (child, target), at the position of its first occurrence, with kind `direct` if any of the
  repeated edges is direct, else `indirect`. Missing parents are never merged or dropped. V3 stays
  the engine's check: an input with a repeated `idx` is still invalid.
- **`ts_ms`:** the topology's committer timestamp (`with_timestamps`); `null` for the root, as
  before.
- **`priority`:** no longer a stand-in. It is §11.2's anchors rule, normative since 2026-10-01;
  the dumper passes the anchors `[trunk(), present(@)]`, which yields exactly the three classes
  listed above.

*Amended 2026-10-01, Story 4.13: stack facts.* A node may carry five more fields, the facts §4.8's
run rule reads:

| field | meaning |
|---|---|
| `key` | the node's key (a string): its change id, or its commit id when it is hidden or divergent (Story 10.1's key rule); request keys resolve against it |
| `immutable` | bool: the commit is in `::(immutable_heads() \| root())` |
| `parent_count` | int ≥ 0: the commit's real parent count, Missing parents included (Story 4.10's `parent_count`; it can exceed the number of `parents` entries) |
| `has_ref` | bool: a bookmark (local or remote) or a tag points at it |
| `working_copy` | `"this"` for this workspace's `@`, `"other"` for another workspace's working copy, `null` for none |

- They are read only with a stack request (`--stacks`, §6). Then all five are required on every
  node (an absent key is invalid; `working_copy` needs an explicit `null`), the keys are pairwise
  distinct, and at most one node is `"this"`; a violation is invalid input (V5, exit 2). Without
  `--stacks` they are unknown keys and ignored, as before.
- Producers write them after `parents`, in the table's order.
- **V5** (the engine's check, §13): the fact arrays have one entry per node, `parent_count` ≥ 0,
  `working_copy` is one of the three values with at most one `"this"`, and every resolved request
  node lies in [0, n).

**The stack request** is its own file, `{"expanded":[…],"collapsed":[…],"keep_open":[…]}`: three
required arrays of strings. Each key resolves to the node whose `key` equals it; a key no node
carries is dropped (§4.8 step 3). Unknown fields are ignored, as in the input.

§7.2 describes how the design sample is converted to this format.

## 3. Output

```json
{"mode":"time","order":"greedy","unit":1,"rows":12,"lanes":4,"nodes":[{"row":6,"lane":0,"col":0}],"edges":[{"from":5,"to":2,"kind":"direct","route":"branch_off","blocked":false}],"buckets":[{"kind":"day","value":1789430400000,"start":0,"end":0}]}
```

**Canonical form.**
- UTF-8, with the keys exactly in the order shown and no whitespace.
- Plain decimal integers, `true` / `false`, and the enum strings as listed.
- One trailing `\n`.

Two conforming files are compared with `cmp`.

**Fields.**
- `mode`, `order`: echo the CLI flags. `unit`: U.
- `rows`: max row + U, which is the row count in the row modes. `lanes`: max lane + 1. Both are
  0 when n = 0.
- `nodes`: index-aligned with the input.
  - `row` = y(i) (§4.2); in `free` it is in units of 1/U pitch;
  - `lane` (§4.3);
  - `col` (§4.6).
- `edges`: one per layout edge (§4.1).
  - `missing` edges are not output; the painter draws their stub from the input.
  - Order: by child index ascending, then by the parent's position in that child's `parents`
    list.
  - `from` = parent index, `to` = child index; `kind` echoes the input.
  - `route` is one of `straight`, `merge`, `branch_off`; `blocked` is defined in §4.4.
- `buckets`: filled in `time` only (otherwise `[]`), ascending by bucket key. *(Amended
  2026-10-01, Story 4.11: filled in `time` and `free`, `[]` in `compact`. `free` emits `day`
  buckets only (§4.2 free, step 4); their `start` / `end` are y values in 1/U pitch units, and
  their ranges need not be contiguous.)*
  - `kind` is one of `root`, `age`, `day`.
  - `value` is 0 for `root`, the ladder minutes 10…720 for `age`, and the local-midnight
    instant in epoch ms for `day`.
  - `start` / `end` are the bucket's first and last row.
  - Labels ("10m", "Yesterday", "Sep 23") are the painter's.

*Amended 2026-10-27, Story 4.14: joint columns.* With joint columns `lane`, `col` and `lanes` do
not depend on the mode: a `compact` and a `free` output of one input, order and stack request
differ only in `mode`, `unit`, `rows`, the nodes' `row`, the edges' `route` and `blocked`, and
`buckets` (I8, §7.3). The per-node day key of §4.2 free step 4 is a field of the product's grid
(§13), not of this JSON, so no golden carries it.

*Amended 2026-11-10, Story 4.17: columns per mode.* The note above no longer holds for the product:
each mode chooses its own columns (§4.3, Branch columns), so `lane`, `col` and `lanes` may differ
between a `compact` and a `free` output of one input. `lane` = `col` for every node. The product's
§3 output has no `order` key: the object starts `{"mode":…,"unit":…`. The examples above and below
keep the key as history.

*Amended 2026-10-01, Story 4.13: the output with stacks (§4.8).* Without a stack request nothing
changes: there is no `runs` key. With one:
- `rows` is the grouped rows′ (§4.8 step 7); `lanes` stays the ungrouped value.
- `nodes` has n + S entries: the n input nodes, index-aligned as before, then the S stack nodes in
  run order. A hidden member (a member of a collapsed run) is `null`: it has no position.
- `edges` are the grouped graph's (§4.8 step 5), in the same order rule: by child ascending — the
  input nodes, then the stack nodes — then by position. `from` / `to` may be stack node indices.
  A stack node's edge is `direct`. Index order is then no topological order: an edge into a stack
  node has a parent index below its child's (p < n ≤ s).
- `buckets` as before, over the grouped nodes.
- After `buckets`, `"runs":[{"members":[…],"state":"collapsed","node":12}]`: one entry per run, in
  run order (by newest member index ascending); `members` are input node indices, oldest first;
  `state` is `collapsed` or `expanded`; `node` is the run's stack node, or `null` when expanded.

```json
{"mode":"compact","order":"greedy","unit":1,"rows":3,"lanes":1,"nodes":[{"row":2,"lane":0,"col":0},null,null,{"row":0,"lane":0,"col":0},{"row":1,"lane":0,"col":0}],"edges":[{"from":4,"to":0,"kind":"direct","route":"straight","blocked":false},{"from":3,"to":4,"kind":"direct","route":"straight","blocked":false}],"buckets":[],"runs":[{"members":[2,1],"state":"collapsed","node":4}]}
```

## 4. Algorithm

The bracketed names are the benchmark phases (§8).

### 4.1 Graph prep [layering]

- **Layout parents.** LP(i) = the non-missing parents of i, in input order; these are the
  design's `parents`.
  - fp(i) = LP(i)[0] when LP(i) is non-empty: the first parent. It may be indirect, like the
    design's `parents[0]`.
  - pos(p, i) = the position of p in LP(i).
- **Children.** C(j) = every i with j ∈ LP(i), in ascending i. Build it by scanning
  i = 0..n−1.
- **Layout edges.** A layout edge is a pair (p ∈ LP(i), i); E = Σ |LP(i)|.

### 4.2 Layering → y(i) [layering]

Every rule below guarantees **y(i) ≥ y(p) + U for every layout edge**. Parents have larger
indices than their children (V2), so a loop "for i = n−1 down to 0" visits parents first and
needs no recursion. (The design's recursive `rowOf` overflows the stack at a depth of about 8k
on head-first input.)

**compact** (U = 1). For i = n−1..0:
- y(i) = 0 if LP(i) = ∅;
- otherwise y(i) = 1 + max over p ∈ LP(i) of y(p).

**time** (U = 1).
1. **Bucket key b(i).**
   - If `is_root`, or `ts_ms` is null: ROOT, a sentinel below every other key.
   - Otherwise let age = now − ts. The first m in (10, 20, 40, 60, 120, 240, 480, 720) with
     age ≤ m·60000 gives the key now − m·60000 (kind `age`, value m). A future timestamp
     (age < 0) lands in 10m, as in the design.
   - Otherwise let off = utc_offset_min·60000. The key is
     ((ts + off) div 86400000)·86400000 − off (kind `day`, value = key).

   A day key is ≤ ts < now − 43200000, so it lies below every age key. Keys therefore map 1:1
   to buckets, and the kind follows from the key.
2. **Topological clamp** (D1). For i = n−1..0: eb(i) = max(b(i), max over p ∈ LP(i) of eb(p)).
3. **Rows.** Sort the distinct eb values ascending; each is one bucket. Set next = 0, then for
   each bucket in turn:
   - start = next;
   - for each member i in **descending index**: y(i) = max(start, max over p ∈ LP(i) of y(p) + 1);
   - end = the largest y in the bucket; emit {kind, value, start, end};
   - next = end + 1.

   Equivalently, y(i) = max(start of eb(i), 1 + max y(p)). The order inside a bucket only has
   to visit parents first. The result equals the design's whenever ts never decreases along an
   edge (null counts as −∞). Otherwise the design stacks parent and child on the same cell, or
   draws the parent above the child.

**free** (U = 16; provisional, D8).
1. Let tmin = the least non-null ts, or 0 if there is none. t(i) = tmin if `is_root` or ts is
   null, otherwise ts.

   *Clarified during diff (2026-09-26):* tmin counts every non-null ts, including an `is_root`
   node's own. Both implementations already read it that way; it matters only when a root has a
   ts, and the dumper writes `null` for `root()`.
2. **Clamp.** For i = n−1..0: T(i) = max(t(i), max over p ∈ LP(i) of T(p)).
3. **Walk.** Visit all nodes by (T ascending, i descending), so parents come first on equal T.
   With v′ the previously visited node:
   - y(i) = max(base, max over p ∈ LP(i) of y(p) + U);
   - base = y(v′) + gap(T(i) − T(v′)), or 0 for the first node.

   **gap(g)** = min(48, (2·L2(1 + g div 60000)) div 256), where
   L2(x) = 256·k + ((x − 2^k)·256) div 2^k and k = bitlen(x) − 1 (x ≥ 1). L2 is a
   piecewise-linear fixed-point log2: in Rust, k = `63 - x.leading_zeros()`; in Dart,
   k = `x.bitLength - 1`.

   gap in units (16 units = one pitch):

   | elapsed | < 1 min | 1 min | 1 h | 1 day | 1 week | 1 year | cap |
   |---|---|---|---|---|---|---|---|
   | units | 0 | 2 | 11 | 20 | 26 | 38 | 48 |

   y never decreases in visit order. It is a time axis, stretched locally where a chain needs
   one pitch per commit. `now_ms` is not used, so `free` never relayouts on a clock tick.

   *Amended 2026-10-31, Story 4.16: the day step.* With joint columns (`--columns joint`, §6; the
   product always, §13) the base becomes y(v′) + step(v′, i), where step = gap(T(i) − T(v′)) when
   dk(T(v′)) = dk(T(i)) (dk of step 4, at `utc_offset_min`, for every node incl. the `is_root` one,
   whose T is tmin) and max(gap(T(i) − T(v′)), U) when they differ. T and y never decrease in the
   walk, so the older day's newest node is the walk predecessor of the newer day's oldest; the newer
   day's oldest node therefore sits ≥ U above every older-day node in every column, and nodes above
   shift up with it. `rows` grows only at such boundaries, and only where gap < U (ΔT < ~255 min):
   a boundary already a pitch apart, by its gap or by a parent edge, is unchanged. The free model
   is laid out with the step in both request modes (it feeds the joint packing, §4.3), so I8 holds.
   Without joint columns (`--columns mode`, the Rust reference) step = gap, as before.

   *Amended 2026-11-10, Story 4.17:* the step stays in every product layout, in both request modes.
   The reason "it feeds the joint packing, so I8 holds" no longer applies: the free model no longer
   feeds any column of a `compact` request (§4.3, Branch columns) and I8 is gone (§7.3).
4. **Day buckets.** *(Added 2026-10-01, Story 4.11.)* After the walk, every node i with
   `is_root` false belongs to the calendar day of its clamped T(i) at the fixed offset (D7); a
   non-root node with a null ts counts by its T(i) too. With off = utc_offset_min·60000:
   dk(i) = ((T(i) + off) div 86400000)·86400000 − off.
   - One bucket per distinct dk, ascending: `kind` `day`, `value` dk, `start` / `end` the least
     and the largest y over its members (in 1/U units).
   - In visit order both T and y never decrease, so one pass over the visit order emits the
     buckets in order, with no sort.
   - The `is_root` node is in no bucket. `free` emits no `root` or `age` bucket, and no bucket at
     all when every node is `is_root` (or n = 0).
   - Without joint columns two days can share a y value (two unrelated commits less than a minute
     apart across a local midnight), so neighbouring ranges may meet: end of one = start of the
     next. *(Amended 2026-10-31, Story 4.16:)* with joint columns (the product) the day step of
     step 3 keeps them a pitch apart: end of one + U ≤ start of the next.

   `now_ms` stays unused.

   *Amended 2026-10-27, Story 4.14: the day key per node.* The product's grid (§13) carries dk(i)
   for every node in **both** modes: the clamped T(i) of steps 1–2 at `utc_offset_min`, which the
   `free` model computes in either mode (§4.3, amended). The `is_root` node has none (the grid's
   `noDay`, −2^63); a non-root node with a null ts counts by its T(i), as above. With stacks (§4.8) a
   stack node has its newest member's dk(m_k), a hidden member keeps its own. The buckets keep their
   definition (in `free` only; their value is the dk of their members). Compact's day labels
   (Story 10.16) read it.

### 4.3 Lane packing → lane(i) [lanes]

**Continuation child.** cont(j) = the child i ∈ C(j) with fp(i) = j and the least key(i), or
none if no child qualifies. It is the one child expected to continue j's lane.

Visit the nodes by (y, priority, i) ascending. For node i:
```
Ey  = { y(cont(i)) } ∪ { y(c) : c ∈ C(i), pos(i, c) ≥ 1 }      // continuation + merge children
end = Ey = ∅ ? y(i) : max(y(i), max(Ey) − U)
a   = fp(i) exists ? y(fp(i)) + U : y(i)
b   = end + 2U                                                // half-open [a, b)
```
In units, [a, b) is the design's closed [a, end + 1] in rows: the one-row buffer. Other
first-parent children leave from the card's side and do not extend the reservation. *(Planned
change 2026-09-27, §12: they leave through the stub above the card's centre; the reservation
rule is unchanged.)* *(Amended 2026-10-01, Story 4.11, the change §12 planned: other
first-parent children leave through the stub above the card's centre (§4.5) instead of "from the
card's side", and do not extend the reservation. The reservation rule is unchanged.)*

- **Continuation.** If fp(i) exists, cont(fp(i)) = i and fits(lane(fp(i)), a, except fp(i)),
  then lane(i) = lane(fp(i)).
- **First fit.** Otherwise lane(i) = the least ℓ ≥ 0 with fits(ℓ, a, none). An unused lane
  always fits.
- **fits(ℓ, a, x)** ⇔ every interval [a′, b′) already in lane ℓ, except the one owned by x, has
  b′ ≤ a.
- Store [a, b), owned by i, in lane(i), and append y(i) to lane(i)'s y-list.

**Why this equals the design's overlap test** (`iv.a ≤ b ∧ a ≤ iv.b ∧ owner ≠ allow`): every
stored interval of an earlier node m has a′ ≤ y(m) ≤ y(i) < b, so the overlap reduces to
a < b′.

**Required implementation, O(n log n).**
- Per lane, keep the largest and second-largest b′. Each node owns exactly one interval, so
  "except fp" is O(1).
- A segment tree (or an equivalent structure) over lane indices holds each lane's largest b′
  (unused lanes: −∞). It answers "the least lane whose largest b′ ≤ a" in O(log n).
- Each lane's y-list comes out sorted.

**Consequences.**
- A same-lane edge is always a first-parent continuation (i = cont(p)).
- A child never shares a merge parent's lane.
- In the row modes a (row, lane) cell holds at most one card. With the clamp this now also
  holds in `time`.

**Joint packing** *(amended 2026-10-27, Story 4.14; `--columns joint` in the spike's Dart
reference, the product always).* The export `e74ced3` shares one set of columns between its Free
and Compact layouts, so a switch only moves cards up and down. Every layout then lays out both
vertical models, k ∈ {c, f}: `compact` (U_c = 1, y_c of §4.2 compact) and `free` (U_f = 16, y_f of
§4.2 free, steps 1–3), whichever mode is requested. cont is model-independent; Ey, end, a and b
above are computed in each model in that model's y and U, giving every node two intervals
[a_c, b_c) and [a_f, b_f).
- **fits(ℓ, i, x)** ⇔ for k = c and k = f, no interval of lane ℓ other than x's overlaps
  [a_k(i), b_k(i)) in model k (overlap: a′ < b ∧ a < b′). The continuation rule and first fit are
  the ones above with this fits: continuation iff fp(i) exists, cont(fp(i)) = i and fits(lane(fp(i)),
  i, fp(i)); else first fit, the least lane fitting in both models (an unused lane always fits).
- **Packing P_k** visits the nodes by (y_k, priority, i). Pack twice, P_c and P_f, and keep the one
  with fewer lanes; **P_c on a tie**. The packing therefore does not depend on the requested mode,
  and neither do lane, col (§4.6, §4.7) and `lanes`. One-chain inputs (intervals nested alike in both
  models) pack exactly as the single-model packing above.
- **Implementation.** In the visited model v every stored interval of an earlier node m has
  a′ ≤ y_v(m) ≤ y_v(i) < b, so the overlap there still reduces to a < b′: the per-lane top-two b′
  and the segment tree answer it, and first fit walks "the least lane ≥ s whose largest b′ ≤ a",
  re-checking the other model w and continuing at s = ℓ + 1 on a reject. Model w needs a general
  test: per lane its w-intervals ordered by start, each with the prefix's largest end (and its
  owner) and second-largest end; [a, b) overlaps an interval other than x's iff, among the intervals
  starting before b, the largest end other than x's exceeds a. (A lane's intervals overlap only for
  a node and its continuation child, so the last interval's end alone is not enough.)
- **Bound.** O(n log n) per visit for the visited model, plus O(log n) per probe of model w times
  the first-fit probes per node (≤ L), plus the insertion into w's ordered list, O(lane size) as a
  sorted array (shift and prefix update) — an array-backed balanced tree would make it O(log n) if
  a measurement ever shows the shift; spec-4-14 § Measurements did not (`lanes` phase 43 ms at
  100k nodes, Dart AOT).
- The one-pitch buffer, the merge-children term and the stub exception stay as stated above. I2
  (§7.3) holds in both models: a lane's intervals are disjoint in both, apart from a node and its
  continuation child, and the nodes of one chain after a piece returned (below).

**Short pieces return** *(amended 2026-11-09, Ralph: on a real repo a commit and its parent sat in
different columns with a free column between them)*. After the joint packing is chosen, one pass
runs in that packing's visit order over every node i with cont(fp(i)) = i and lane(i) ≠ lane(fp(i)):
- A **chain** is a first-parent line in one lane. The **piece** is i and its continuations in lane(i).
- The piece moves to lane(fp(i)) iff it has at most 8 cards, none of its nodes has a merge parent
  (pos ≥ 1) in that lane, and in both models none of its intervals overlaps an interval of another
  chain there. The intervals of fp(i)'s own chain do not count.
- Every other card stays, so nothing cascades. Lanes left empty are dropped, the others keep their
  order.
- **Cause.** An earlier chain node p with a merge child above p's continuation keeps its reservation
  up to that child's row. That pushes the chain's next node out, in `compact` even when the `free`
  layout on screen has room, although p's merge line cannot climb past the chain's cards anyway
  (§14.2).
- **Why not in the packing.** Letting every continuation ignore its chain's reservations removes
  every break, but doubles the crossings on that repo (142 → 280 bridges).
- **Why 8.** Without a limit long pieces leave the left columns empty: synth-100k's mean width grows
  from 43 to 104. With 8 it stays at 43.
- Measured on that 1,621-commit repository (`free`, order `compact`, router B): 7 → 5 broken chains,
  143 → 142 crossings, 716 → 712 bends, 11 columns before and after. The 5 left are longer than 8
  cards or blocked by another chain's card.

**Branch columns** *(amended 2026-11-10, Story 4.17; the rule of the graph layout lab, which Ralph
approved that day: `spikes/graph-layout-lab/README.md`, rule log, and `lib/columns.dart`)*. This
supersedes the lane packing above, the joint packing and "Short pieces return"; they stay as history.
The product has no other column rule and no request parameter that chooses one.

All rows below are the requested mode's y, and U is one pitch in that mode's units. Free and Compact
each run the rule on their own rows, so a card may change its column on a mode switch. `lane` = `col`
for every node (§4.6). `cont` is the continuation child defined above.

- **Branch.** A first-parent chain. A node continues its first parent's branch iff it is that
  parent's continuation child (cont(fp(i)) = i); else it starts a branch.
- **Main branch.** The branch of the node with the least (priority, y); of several such nodes, the
  one with the highest index. It is in column 0, and no other branch is.
- **Reserved rows.** A branch takes the rows [lo, hi] of its column, from its bottom card to its top
  card, with two extensions:
  - lo reaches down to one pitch above its fork, the bottom card's first parent: lo = y(fp(bottom)) +
    U. A branch whose bottom card has no first parent has lo = y(bottom).
  - hi reaches up to one pitch below the child of each of its merge edges, an edge from one of its
    cards that is not the child's first-parent edge: hi = max(y(top), y(c) − U over those children c).
- **Free.** A column is free for a branch iff every branch o in it keeps one pitch from it:
  lo(o) ≥ hi + U or lo ≥ hi(o) + U.
- **Dock.** A branch docks to the main branch (column 0) if it forks from the main branch (a branch
  with no first parent counts as forking from it), or if it merges into a branch other than the one
  it forks from; its depth is then 1. Every other branch docks to the column of the branch it forks
  from; its depth is that branch's depth + 1. The main branch has depth 0.
- **Order.** The main branch first; then by depth; then the branch that ends first (the lower hi),
  then the shorter one (the lower hi − lo), then the one with the older bottom card (the lower
  (y(bottom), priority(bottom), bottom)).
- **Place.** A branch takes the free column nearest to its dock: for d = 0, 1, 2, … first dock − d
  (never below column 1), then dock + d (d > 0). A new column index never exceeds the highest used
  so far + 1, so no column is empty and nothing is renumbered.

**Consequences.**
- A branch has one column for its whole life; lane(fp(i)) = lane(i) along a branch.
- A branch never shares a column with the branch it forks from: the fork's continuation child keeps
  that branch's reservation at or above the new branch's lo.
- A merge child can share its merge parent's column: the reservation ends one pitch below the child,
  so a branch starting at that child may take the column. Such an edge is `straight` in §4.5, because
  lane(p) = lane(i). Router B does not read `route` (§14) and classes it `gutter` by its column-free
  test (§14.2, s = 0, not the first parent). *(Amended 2026-11-10, Story 4.18: the router of §14 no
  longer classes such an edge. A same-column line with no card between its ends is straight, also
  for a non-first parent; with a card in between it takes the gutter, §14.3.)*
- `straight` now means only lane(p) = lane(i). Cards of the parent's branch can lie between p and i
  in that column, because the branch's reservation ends one pitch below the child, not at p.
- A merge with lane(p) ≠ lane(i) is `blocked` (§4.4) when a card sits in the parent's column at
  y(p) < y(o) ≤ y(i): a card of the parent's own branch above p, or the first card of a branch that
  starts on the child's row.

**I2, restated** (§7.3). In one column, consecutive cards keep at least U, and two branches keep one
pitch between their reserved rows.

**Bound.** O(n + E) for the branches and their spans, O(C log C) for the order of the C branches, and
per branch at most K + 1 binary-searched probes of the K columns used so far, plus one insert that
shifts the tail of its column's interval list. Each column keeps its reservations as disjoint
half-open intervals [lo, hi + U) ordered by start, so a branch overlaps a column iff the last
interval starting before hi + U ends after lo. The insert is O(column size): an array-backed balanced
tree would make it O(log n) if a measurement ever shows the shift (spec-4-17 § Measurements).

### 4.4 Blocked [blocked]

For each layout edge (p, i):
- if lane(i) = lane(p), blocked is false (D4);
- otherwise blocked ⇔ some node o with lane(o) = lane(p) has y(p) < y(o) ≤ y(i).

Find it with one binary search in lane(p)'s y-list for the first y > y(p), then compare that
y with y(i). This is O(E log n); the design scans every node per edge, O(E·n).

### 4.5 Routing [routing]

route(p, i) (GV:58-65):
- `straight` if lane(p) = lane(i);
- otherwise `merge` if pos(p, i) ≥ 1 and the edge is not blocked;
- otherwise `branch_off`.

**Symbolic geometry for the painter.** This is not output; W, H and the gaps are the painter's.
Pixel y grows downward and "up" means towards the child. pcx and ncx are the lane centres of the
parent's and the child's columns.
- `straight`: from the parent's top, straight up the lane to the child's bottom.
- `merge`: up the parent's lane to 0.4·gapY below the child's bottom, across to ncx, then up
  into the child.
- `branch_off`: leaves the parent's top at pcx + s·0.28·W, with s = sign(col(i) − col(p)); goes
  up 0.4·gapY, across to ncx, then up the child's lane into the child. Siblings share this
  bus. *Planned change 2026-09-27 (§12): it leaves the parent's top at pcx, like every other
  edge.*

  *Amended 2026-10-01, Story 4.11 (the change §12 planned; it replaces the rule "leaves the
  parent's top at pcx + s·0.28·W, with s = sign(col(i) − col(p))"):* `branch_off` leaves the
  parent's top at pcx, goes up 0.4·gapY, across to ncx, then up the child's lane into the child.
  It shares the exit, and the stub up to the bus, with the parent's `straight` continuation and
  with a `merge` that leaves up the parent's lane: a T-junction at the bus. Siblings on one side
  share the bus, as before; both sides now share the stub. No output changes: `route`,
  `blocked`, rows, lanes and columns stay as they were, and so does every golden.

In a row gap, branch-off buses sit at 0.4 of the gap above the lower card and merges at 0.6, so
the two never collide.

**Kept design defect (D9).** A blocked merge becomes a `branch_off` whose vertical runs up the
child's lane. It may pass behind that lane's cards, collinear with its chain.

*Amended 2026-10-27, Story 4.15:* the painter's geometry is §14's router. The text "Symbolic
geometry for the painter" above (with the bus heights 0.4 / 0.6 of the gap) and D9 are superseded
by §14: every parent → child pair is its own line, and a lane-blocked merge climbs a gutter between
columns instead of the child's lane. `route` and `blocked` stay as output: they serve the
invariants (§7.3) and the goldens, and the router does not read them.

### 4.6 Lane order → col(i) [ordering]

*(Amended 2026-11-10, Story 4.17: the product has no lane order and no `ordering` phase. Every
product layout has col(i) = lane(i), as §4.3's Branch columns give it. §4.6 and §4.7 stay as the
spike's history.)*

π maps lane → column. It is a permutation with π(0) = 0: lane 0, the trunk, never moves.
col(i) = π(lane(i)).

**greedy:** π = identity. This is the design's "Lane order = Greedy".

**optimized** replaces the design's exhaustive / hill-climbing search over an O(E²) crossing
count with a bounded sifting heuristic on an incremental integer cost. It keeps the design's
goals in the same order of importance: fewer crossings, then shorter horizontal runs, then
little displacement from the greedy order.

**Geometry model** (integers; independent of W and H). Per node v, in ticks (10 per unit,
counted bottom-up):
- bot(v) = 10·y(v);
- top(v) = bot(v) + 5U;
- up(v) = bot(v) + 7U, the branch-off bus above v;
- dn(v) = bot(v) − 2U, the merge bus below v.

With U = 1 this puts, in every gap, the branch-off buses at 0.4 and the merge buses at 0.6 of
the gap, as the design does. In `free` it fixes a card at half a pitch, an approximation.

Per layout edge (p, i):

| route | verticals (lane: lo, hi) | horizontal (lanes, level) |
|---|---|---|
| straight | lane(p): top(p), bot(i) | — |
| merge | lane(p): top(p), dn(i) and lane(i): dn(i), bot(i) | lane(p)–lane(i) at dn(i) |
| branch_off | lane(i): up(p), bot(i) | lane(p)–lane(i) at up(p) |

The branch-off's short side stub is not modelled; with U = 1 nothing can cross it.
- **m(ℓ, λ)** = the number of verticals in lane ℓ with lo < λ < hi, i.e. #{lo < λ} − #{hi ≤ λ}
  over the lane's sorted lo[] and hi[] arrays (two binary searches).
- **h(ℓ)** = the number of horizontals with an endpoint in lane ℓ.

**Cost.** cost(π) = 400·X + 4·Len + Disp, where:
- X = the sum, over the horizontals, of m(ℓ, level) for every lane ℓ whose column π(ℓ) lies
  strictly between the horizontal's endpoint columns;
- Len = the sum, over the horizontals, of |π(a) − π(b)| for endpoint lanes a and b;
- Disp = Σ over ℓ of |π(ℓ) − ℓ|.

This is the design's 100·crossings + run length + 0.25·displacement (GV:110), multiplied by 4.
Three parts of the design's cost are handled differently:
- the W-dependent part of its length (−0.28·W/step per branch-off) is the same for every π, so
  it is dropped;
- its collinear-overlap term is not modelled;
- crossings between edges that share an endpoint ARE counted; the design skipped them (GV:87).

**Search:** windowed sifting, with the constants K = 8, R = 4 and BUDGET = 2 000 000.
```
π = identity; spent = 0
sift order = lanes 1..L−1 by (h desc, lane asc)          // fixed for the whole phase
repeat up to R rounds:
  for A in sift order:
    c = π(A); window = [max(1, c−K), min(L−1, c+K)]
    work = Σ over lanes B ≠ A with π(B) ∈ window of (h(A) + h(B))
    if spent + work > BUDGET: stop the phase
    spent += work
    for d in window: π_d = π with A removed and re-inserted at column d; D(d) = cost(π_d) − cost(π)
    d* = the d minimising (D(d), |d − c|, d)
    if D(d*) < 0: π = π_d*
  if the round moved nothing: stop
```
With L ≤ 9 the window covers every column, so each sift is an exact best insertion. With
L ≤ 2 the result is the identity.

*Clarified during diff (2026-09-26):* "stop the phase" ends the whole search at once. No later
lane of that round is tried, no further round runs, and the current π stands. Both
implementations read it this way; the budget binds on `synth-50k` and `synth-100k`.

**Incremental evaluation** (required; this is exactly what `work` counts). Moving A by one
column swaps the adjacent columns k (lane P) and k + 1 (lane Q). Only the horizontals with
exactly one endpoint in {P, Q} change. Let y be the column of such a horizontal's other
endpoint:
- endpoint P: if y > k + 1, then X −= m(Q, level) and Len −= 1; if y < k, then X += m(Q, level)
  and Len += 1;
- endpoint Q: if y < k, then X −= m(P, level) and Len −= 1; if y > k + 1, then X += m(P, level)
  and Len += 1;
- Disp changes by |k+1 − P| + |k − Q| − |k − P| − |k+1 − Q|.

One step costs O((h(P) + h(Q))·log n). D(d) accumulates the steps from c to d.

**Complexity.** Precomputation is O(E log E). The search spends at most BUDGET swap-units, each
O(log n), so the phase is O(E log E + BUDGET·log n) whatever L is. (The design's search is
O((L−1)!·E²) up to 8 lanes and O(passes·L²·E²) beyond.) The phase should stay well under 100 ms
at 10k commits in a compiled language.

### 4.7 Lane order `compact` [ordering] — Dart-only (not in the Rust A/B reference), 2026-09-26

*(Amended 2026-11-10, Story 4.17: §4.7, its joint form and its closing pass are removed from the
product, and `compact_order` is gone. The text stays as history. D5 and D14 are superseded.)*

Added after Ralph's review of the viewer on the real 1.4k-commit repo (2026-09-26): `optimized`
sprawls, greedy is more compact. The cause (measured in README, "Lane order review"):
`optimized` permutes **whole lanes**, but greedy reuses a lane for many unrelated branches over
time. A permutation that pays off in one busy period leaves columns empty in every other period.
`compact` keeps greedy's packing and exchanges columns **inside time windows** only. Only
`dart/` implements it; `rust/`, `tools/compare.mjs` and `tools/fuzz.mjs` cover greedy and
optimized only, and the Rust binary rejects `--order compact` with exit code 2.

**What changes against §4.6.**
- `lane(i)` is the new column and `col(i) = lane(i)`: π is the identity. `lanes` ≤ greedy's,
  because columns left empty are dropped.
- §4.4 and §4.5 run again on the new lanes. Every `route` equals greedy's, and so does `blocked`
  on every edge with pos ≥ 1. Only a first-parent branch-off's `blocked` flag may change, which
  does not affect its route. I1–I6 hold (I4 trivially).
- So greedy and `compact` differ in `lane` too, not only in `col`.

**Segments.** A segment is a maximal chain of straight edges of the greedy packing: a node and its
continuation child, in one lane. Its head is its lowest node. Its reservation R = [a, b) is the
union of its nodes' §4.3 intervals: a is the head's a, b the largest b. Segments in one column
must have disjoint reservations; greedy's lanes satisfy that.

**Geometry.** §4.6's tick model, with verticals and horizontals attached to segments instead of
lanes:
- straight verticals and a merge's parent-side vertical belong to seg(p); a branch-off's vertical
  and a merge's child-side vertical belong to seg(i); a horizontal joins seg(p) and seg(i);
- one change: a blocked merge's vertical (D9) is clipped below at 10·a(seg(i)) − 3U.

Every vertical of a segment then lies in [10·a − 3U, 10·(b − U)]. At any level λ, at most one
segment per column holds a vertical: the last one with 10·a − 3U < λ.

**Cost.** cost = U·(400·X + 4·Len) + κ·Σ over segments of col·(b − a), with X and Len as in §4.6
(every pair, shared endpoints included) and the gravity κ = 24. Scaling X and Len by U makes κ a
cost per column per row pitch in every mode: one crossing is worth 400 / 24 ≈ 17 column·pitches
of occupied area. There is no displacement term. (κ = 16 removes more crossings but is wider than
greedy at the spot Ralph marked; README, "Lane order review".)

**Search** (constants κ = 24, reach D = 8, R = 16 rounds, BUDGET = 2 000 000):
```
columns = greedy's lanes; each column's segments ascending by a
repeat up to R rounds:
  for d = 1 … D, then c = 1, 2, … while c + d < #columns:
    walk the segments of columns c and c + d by a, cut into windows: a window grows while
    the next segment starts before the window's largest b
    for each window W, in time order:
      if spent > BUDGET: stop the search
      after the first round: skip W if its level span meets no exchange kept since the
      previous round began
      exchange W's segments between c and c + d; keep it iff cost(W) drops, else undo
  if the round kept nothing: stop
drop the empty columns (keeping the order of the others); lane(i) = column of seg(i)
```
- **cost(W)** is the part of the cost that involves a segment of W: horizontals incident to W
  against every vertical between their ends, horizontals not incident to W against W's
  verticals, the runs of W's horizontals, W's gravity. It counts each crossing once, so
  after − before is the exact change of the total cost. The total strictly falls with every kept
  exchange, so the search terminates. Ties keep the current state.
- **Feasibility.** A window is a connected group of the two columns' reservations, so both
  columns stay disjoint after the exchange. Column 0 (greedy lane 0, the trunk) never moves.
- **Skipping.** A segment's span is [lo(s), 10·b), with lo(s) = 10·a − 3U, lowered to the level
  of any horizontal incident to s: a blocked merge's horizontal lies at up(p), below its child
  segment's clipped vertical. W's span is [min lo, 10·max b) over its segments. cost(W) only
  involves levels in W's span, and every horizontal at such a level has both end segments' spans
  containing it. A window whose span meets no kept exchange since its last evaluation would
  repeat that rejection, so skipping it does not change the result.

  *Corrected in review (2026-09-26):* the first version used lo(s) = 10·a − 3U. That missed the
  blocked-merge case: on random graphs, 18 of 9,000 unbounded searches ended at a different cost
  than the search without skipping (17 higher, 1 lower). With the lowered lo(s) all 9,000 agree
  (`dart/test`, "skipping unchanged windows"). No spike input's output changed.
- **Work.** One unit per column crossed by an incident horizontal and one per horizontal
  enumerated in a member's vertical extent, each O(log n). One unit per kept span compared in
  the skip test and one per list entry an exchange shifts, each O(1).
- Dropping empty columns keeps the order of the rest, so no crossing or run can grow.

**Complexity.** Segments and geometry O((n + E) log E). Walking the windows is O(R·D·n), with
R·D = 128 fixed; everything else in the search is charged to the budget. In total
O((n + E) log E + R·D·n + BUDGET·log n). On the real 1.4k-commit repo it converges within the
budget; on synth-10k the budget binds.

**Known limits.**
- A local optimum: exchanges of two columns at a time, reach 8.
- On a handful of commits a removed crossing can outweigh width: on the real repo's default
  revset in `compact` mode, 3 crossings go away and the mean width grows from 2.83 to 3.67
  columns. `optimized` does the same there.
- A segment is atomic. A long-lived one makes its windows as long as its life, so a crossing gain
  in a busy period can move it right through quiet stretches too (README, "Lane order review",
  §6).
- At 10k+ commits the budget ends the search inside the first sweeps, so only the left columns
  move (README, "Lane order review", §6).
- The viewer shows it since bundle v2 (2026-09-26), which stores `compact`'s own lane array per
  mode (README, Viewer).

**Joint `compact` order** *(amended 2026-10-27, Story 4.14; `--columns joint`, the product
always).* On the joint packing (§4.3, amended) the order runs once for both models; its result does
not depend on the requested mode.
- **Segments** are the maximal straight chains of the joint packing (lane(fp(i)) = lane(i)). Each
  has a reservation per model, R_k(s) = the union of its nodes' model-k intervals, and each model
  keeps the tick geometry above in its own y, U, routes and `blocked` (§4.4 / §4.5 over model k's y
  on the current lanes; D9's clip at 10·a_k − 3U_k). Columns are disjoint in each model (the packing
  guarantees it, exchanges keep it); every column keeps one segment list per model, ascending by
  a_k (the two orders may differ).
- **Windows** of the column pair (c, c + d): the segments of both columns, joined when their
  reservations overlap in **either** model. Per model the sweep above ("grows while the next starts
  before the window's largest b") gives that model's windows; a union-find joins the model-c
  windows that share a segment with one model-f window. A window is a connected component: disjoint
  from the others in both models and independent of which column a segment sits in, so the
  components are computed once per pair visit and visited ascending by their least a_c (unique: two
  segments with one a_c overlap).
- **Exchange:** every member moves to the other column; each column's list in each model is
  rebuilt in that model's order.
- **Cost:** cost(W) = 16·cost_c(W) + cost_f(W), each the local cost above in its own model (U_c = 1,
  U_f = 16, gravity κ·col·(b_k − a_k)). Both are per-pitch costs, `free`'s in 1/16-pitch units, so
  the weight 16 keeps the sum integer. An exchange stays iff the joint cost falls. κ, the reach,
  the rounds and the budget are unchanged; column 0 stays fixed (until the closing pass below); empty
  columns are dropped.
- **Skipping:** per model k a window's span is [min lo_k, 10·max b_k); kept spans are recorded per
  model. After the first round a window is skipped iff in **both** models its span meets no span
  kept since the previous round began (tested model c then f, each against the previous round's
  spans, then the current round's; the first hit evaluates the window).
- **Work units** (identical in the spike and the product): each model's local cost charges as
  above; the skip test charges, per model, half the length of each span list it scans; an exchange
  and its undo charge, per model and per column, the list's length before the rebuild minus the
  index of its first changed entry. "If spent > budget: stop the search" is checked before each
  window, as before.
- **One model.** With a single model every rule above is §4.7's, work units included (the spike's
  `JointCompactOrder(single: true)` equals `CompactOrder` at every budget, `dart/test`).

**Closing pass** *(amended 2026-11-09, Ralph: short branches left an empty column between themselves
and the trunk; amended again the same day: a branch of 11 cards sat in column 0, two columns left of
the trunk)*. After the joint search the same rounds, reach and window walk run once more, with a
fresh budget and these changes:
- the gravity term is 0;
- column 0 takes part: c starts at 0, and a column the pass empties is dropped, column 0 included;
- only a window that is one segment is tried;
- an exchange stays iff 400·X + 4·Len falls in the joint cost and, for a segment of more than 8
  cards, Len falls too.

Why:
- **Cause.** Gravity pulls toward column 0, but the trunk can sit further right, because it can lose
  its lane to its own merge reservations (§4.3). "Left" then means away from the trunk. For a card,
  one column of gravity costs about six times what the shorter lines gain.
- **Why column 0.** The search keeps greedy lane 0 in column 0, for the trunk. On a real 1,622-commit
  repository the trunk has 8 of its 158 cards there; the other segments of lane 0 are side branches.
  All 12 segments with a free column between themselves and their lines sat in column 0.
- **Why not every window.** Without the window limit the crossings halve on that repository
  (142 → 69), but its empty cells grow from 16.5 % to 37.4 %: the sprawl that ruled out
  `optimized`. Keeping the trunk in column 0 instead costs 240 crossings.
- **Why 8.** A crossing weighs 100 run columns, so a segment leaves its lines to remove one. Without
  a card limit the crossings fall to 97 on that repository, but the empty cells grow to 26.7 %. (With
  column 0 pinned, 3 cards gave 137 crossings, 8 and 16 gave 134, 32 gave 119 and 20.9 % empty cells.)
- **Why Len for longer segments.** A longer segment moves only toward the lines it connects to, so
  it cannot sprawl. Without this rule the branch of 11 cards stayed where the packing put it.
- **Measured** on that repository (`free`, order `compact`, router B): 142 → 128 crossings, 712 → 710
  bends, 16.5 % → 18.5 % empty cells, 11 columns before and after. No segment has a free column
  between itself and its lines; with the first version of this pass (pinned column 0, at most 8 cards)
  12 segments with 138 cards had one, at 134 crossings and 19.1 % empty cells. The ordering phase
  takes 14.6 instead of 12.2 ms, on synth-100k 104 instead of 68 ms.

The pass can raise the gravity term, never 400·X + 4·Len. The search before it keeps the claim that the
joint cost is never above joint greedy's.

### 4.8 Stacks [stacks] — Dart-only (not in the Rust A/B reference), 2026-10-01

*(Added 2026-10-01, Story 4.13.)* With a stack request (§2, §6 `--stacks`, §13), linear runs of
commits collapse into one card each. Ralph's rule (2026-09-28): neither a toggle nor the request
as a whole ever changes a column; the graph may only compact vertically. So the engine first lays
out the ungrouped graph exactly as §4.1–§4.7 do, and then groups the runs and computes new rows
for the fixed columns. Only `dart/` and the product engine implement it; the Rust binary rejects
`--stacks` as an unknown flag (exit 2). Without a stack request nothing here runs, and the output
is the ungrouped one byte for byte.

Notation: LP, fp, C and pos are §4.1's; y, lane, col and the packing's visit order (y, priority, i)
are those of the finished ungrouped layout (after §4.7 when the order is `compact`); the facts
`key`, `immutable`, `parent_count`, `has_ref` and `working_copy` are §2's.

**1. Candidates.** cand(i) ⇔ all of:
- `is_root` is false and `working_copy` is null (no workspace's working copy);
- `has_ref` is false;
- `parent_count` = 1;
- i's §2 parent list has exactly one entry, and it is `direct` (so LP(i) = [fp(i)]);
- |C(i)| = 1: exactly one layout edge, Direct or Indirect, has i as its parent.

A conflict does not matter. A node whose one edge is Indirect or Missing, or that has several
Indirect edges (a hidden merge parent), is no candidate; neither is a node with one Direct and one
Indirect child edge (a fork).

**2. Runs.** link(i) = c, where C(i) = {c}, iff cand(i), cand(c) and immutable(c) = immutable(i);
cand(c) makes i the only layout parent of c. A **run** is a maximal chain m_1 → m_2 → … → m_k with
link(m_j) = m_{j+1} and k ≥ 2: m_1 is its oldest member (largest index), m_k its newest. A node is
in at most one run, and the immutable boundary splits a chain into two runs. Runs are numbered by
m_k ascending; a run's key is key(m_1).

**3. State.** The request's three key lists resolve to node sets (§2: a key resolves to the node
whose `key` equals it, an unresolved key is dropped): EX (`expanded`), CO (`collapsed`) and KO
(`keep_open`). Let A be the node whose `working_copy` is `"this"`, if there is one, together with
every node reached from it by repeatedly stepping to an LP parent whose `immutable` is false. A run
is **expanded** iff
- one of its members is in KO; else
- m_1 is in EX; else
- m_1 is not in CO, and m_k is in A.

So a run of mutable ancestors of this workspace's `@` starts expanded, every other run collapsed;
an explicit key wins over that default (EX over CO when both name m_1), and KO wins over all. A key
in EX or CO that is no run's m_1, and a key in KO that is no member, changes nothing. The S
collapsed runs get the **stack nodes** n, n + 1, …, n + S − 1, in run order; their members are
**hidden**. img(v) is v for a visible node and the stack node of v's run for a hidden one.

**4. Columns.** Every visible node keeps its lane and col; a stack node takes lane(m_k) and
col(m_k), so the edge into the run's child stays where it was; `lanes` is the ungrouped value. A
run is **split** iff col(m_1) ≠ col(m_k). The packing can split it between m_1 and m_2: m_1 may
continue its parent's lane beside the parent's own merge reservation (§4.3 excepts only fp's own
interval), and then m_2, which may not, takes another lane. *(Amended 2026-11-09:)* that piece returns
unless it is longer than 8 cards or another chain's card is in the way (§4.3, "Short pieces return").
With joint columns a member can also lose its lane to another chain in the model the packing does not
visit. A split run's members then lie in more than one lane; the stack node stays in m_k's.

*Amended 2026-11-10, Story 4.17:* no run is split. The columns come from the requested mode's
ungrouped layout (§4.3, Branch columns). A run's links are node → its only child, which continues it
(cont), so a run lies on one branch and its members share a column. "Split" and D11 no longer apply.

**5. The grouped graph G′.** Its nodes are the visible nodes and the stack nodes. Its edges, in
§3's order (by child ascending — the input nodes, then the stack nodes — then by position):
- a visible child v keeps every layout edge (p, v) as (img(p), v), with its kind and its pos;
- a stack node s has one edge (img(fp(m_1)), s), `direct`, pos 0.

fp′(v) is v's first grouped parent. A hidden node with a visible child is always some m_k (every
other member's only child is a member), so Y below gives Y(img(p)) = y(p) for every parent p of a
visible child. The newest member's child edge keeps its kind, so a stack node's child edge can be
`indirect`; its parent edge is always `direct`.

**6. Rows.** Y(v) = y(v) for a visible node, Y(s) = y(m_k) for a stack node. The grouped rows y′
are the **least** solution with y′ ≥ 0 of these constraints, each y′(target) ≥ y′(source) + δ with
δ ≥ 0:
- **(E)** y′(v) ≥ y′(p) + U for every grouped edge (p, v).
- **(F)**, `free` only. W is §4.2's walk (T ascending, i descending); X(w_0) = 0 and X(w_j) =
  X(w_{j−1}) + gap(T(w_j) − T(w_{j−1})), the ungrouped walk's gaps summed. W′ is W without the
  hidden nodes, each m_k replaced by its stack node, which takes X(m_k) and T(m_k). For
  consecutive u, v in W′: y′(v) ≥ y′(u) + X(v) − X(u). *(Amended 2026-10-31, Story 4.16:)* with
  joint columns X sums the walk's day-aware steps (§4.2 free.3, amended), so a sum across a day
  change holds a step ≥ U and consecutive W′ buckets stay a pitch apart.
- **(C)** Per column, take the grouped nodes of that column by ascending Y (distinct there). A
  **segment** is a maximal stretch of consecutive nodes in which every node's fp′ is the node right
  before it. For each two adjacent segments, S below with its top node u and T above with its
  lowest node h:
  - if h is the stack node of a split run, or h has no grouped parent: t = h, δ₁ = 2U, δ₂ = U;
  - otherwise: t = fp′(h), δ₁ = U, δ₂ = 0;

  and then y′(t) ≥ y′(u) + δ₁, and y′(t) ≥ y′(c) + δ₂ for every grouped edge (x, c) with x in S
  and pos ≥ 1.

  This is §4.3's packing rule restated on the grouped rows: T's interval [a, b) starts at or above
  the end of S's, which counts S's cards and the merges routed up S's column. Two of §4.3's terms
  are dropped: a continuation child in another column (it leaves through the stub, §4.5), and, for a
  split run's stack node, the start one pitch above its parent: it reserves its column from its
  own card (D11).

  *Amended 2026-11-10, Story 4.17: (C) restated for branch columns.* A segment is a branch's grouped
  nodes in that column. Branch columns give lo(T) ≥ hi(S) + U, with lo(T) = y(fp(h)) + U (or y(h) if
  h has no first parent) and hi(S) = max(y(u), y(c) − U over S's merge edges to c). On the grouped
  rows that is, for u and h as above and every grouped edge (x, c) with x in S and pos ≥ 1:
  - h has a grouped first parent t = fp′(h): y′(t) ≥ y′(u) (δ₁ = 0) and y′(t) ≥ y′(c) − U (δ₂ = −U);
  - h has none: y′(h) ≥ y′(u) + U (δ₁ = U) and y′(h) ≥ y′(c) (δ₂ = 0).

  These values are one pitch less than the old 2U / U and U / 0. No case depends on a split run any
  more. A constraint may have a negative δ, and its source may lie above its target.

**Procedure.** Visit the grouped nodes in the ungrouped visit order (y, priority, i) — hidden nodes
dropped, each m_k replaced by its stack node, so ascending in Y — in groups of equal Y. Every y′
starts unset. For one group, repeat a pass over its nodes, y′(v) = the maximum of 0 and of
y′(source) + δ over every constraint on v whose source is set, until a pass changes no value; then
take the next group. (The order of a pass changes only the number of passes, never the result; the
implementations alternate the direction.)

**Termination, and why rows never grow.** Y satisfies every constraint:
- (E): a visible child has y(v) ≥ y(p) + U = Y(img(p)) + U; a stack node has Y(s) = y(m_k) ≥
  y(m_1) ≥ y(fp(m_1)) + U = Y(img(fp(m_1))) + U.
- (F): along W, y(w_j) ≥ y(w_{j−1}) + gap(T(w_j) − T(w_{j−1})) (§4.2 step 3); summing gives
  y(v) − y(u) ≥ X(v) − X(u) for every u before v in W.
- (C): let ĥ be h itself, or m_1 for a non-split stack node, or m_2 for a split one. ĥ heads a
  chain of straight edges (a §4.7 segment) in its ungrouped column: had it continued the node below
  it, that node (or its image) would be fp′(h) and right before h, and h would not head T. In the
  final columns the reservations of such chains are disjoint (§4.3's first fit; §4.7's exchanges
  keep them so), so every interval [a′, b′) of a node below ĥ in that column ends at or below ĥ's
  start a. Every node x of S lies below the run's members in that column, so b(x) ≤ a, where
  b(x) ≥ Y(x) + 2U and b(x) ≥ Y(c) + U for each merge child c of x (§4.3). Now a = Y(t) + U when
  t = fp′(h) (a = y(fp(ĥ)) + U), a = Y(h) when h has no parent, and a = y(m_1) + U ≤ y(m_2) ≤ Y(h)
  for a split stack node. Each case gives Y(t) ≥ Y(u) + δ₁ and Y(t) ≥ Y(c) + δ₂.

So every constraint has Y(target) ≥ Y(source) + δ ≥ Y(source): its source lies in the same group or
an earlier one, and inside a group only constraints with δ = 0 occur. After a group's first pass
every node of it is set, and each later pass only copies values along δ = 0 constraints, so the
loop ends after at most |group| + 1 passes. Values only rise from below, so the result is the least
solution; and since Y is a solution, **y′ ≤ Y** for every grouped node. Collapsing never raises a
node's y, and `rows` never grows. With nothing collapsed, G′ is the ungrouped graph, whose y is the
least solution of (E) and (F) (§4.2) and satisfies (C), so y′ = y exactly.

*Amended 2026-11-10, Story 4.17: the procedure and the termination for the restated (C).*
- **Procedure.** One sweep is the level-by-level loop above; its first run ignores unset sources, as
  before. δ₂ = −U can have a source above its target (Y(c) ≤ Y(t) + U), and a sweep has already
  passed t when c is set. So the sweeps repeat until every (C) constraint holds, each starting from
  the last sweep's values. (E) and (F) hold after every sweep: their sources lie in the same or an
  earlier group.
- **Y satisfies every constraint.** (E) and (F) as above. (C): let S be below T in one column, u the
  top node of S and h the lowest of T. In the ungrouped layout their branches keep one pitch:
  lo(T) ≥ hi(S) + U. With t = fp′(h), lo(T) = Y(t) + U, so Y(t) ≥ hi(S) ≥ Y(u) and
  Y(t) ≥ Y(c) − U. Without a first parent lo(T) = Y(h), so Y(h) ≥ hi(S) + U ≥ Y(u) + U and
  Y(h) ≥ Y(c).
- **Termination and least solution.** Every value is a lower bound of the least solution, because it
  is the maximum of constraints over values that are; so values only rise, stay ≤ Y and the loop
  ends. It ends at a solution, hence at the least solution, and **y′ ≤ Y**. With every run expanded
  y′ = y, as before. A pass of one group still needs at most |group| + 1 passes: constraints inside
  a group have δ ≤ 0, and Y rules out a cycle with a positive sum.
- **Bound.** The constraints have no cycle with a positive sum, so the sweeps work like Bellman–Ford
  passes: at most n + 1 of them run. A value above Y means the columns are not branch columns, and
  the sweeps might not end; the product throws `StateError` instead of sweeping on.
- **Measured.** One sweep on each of the lab's three repositories. A mean of 1.0004 sweeps, at most
  2, on 24,012 layouts of small seeded stack graphs (the lab's columns × states × modes). On seeded
  stack graphs of 600–3,600 nodes with every run collapsed (14,318 layouts): 85 % one sweep, 12 %
  two, at most five.

**7. Then.** §4.4 and §4.5 run on G′ with the fixed lanes: `blocked` over per-lane y′ lists (built in
the visit order above, which is ascending in y′ within a lane), routes with the grouped pos. In
`free`, the day buckets are §4.2 step 4 over W′: the visible nodes whose `is_root` is false and the
stack nodes, a stack node in the day of T(m_k). rows′ = max y′ + U; `lanes` stays the ungrouped
value.

**Output** (§3, amended). The node arrays hold n + S entries: the input nodes, a hidden member with
no position (−1, JSON `null`), then the stack nodes in run order. The edges are G′'s in §3's order
and may reference stack nodes; the buckets are step 7's. Then the runs, ordered by newest member:
each one's members (input node indices, oldest first), its state (`collapsed` / `expanded`) and its
stack node (or none). `rows` is rows′, `lanes` the ungrouped value. Without a stack request there
are no runs and the output is §3's ungrouped one, byte for byte.

**V5** (§2, amended). The stack facts have one entry per node; `parent_count` ≥ 0; `working_copy` is
none, other or this, with at most one this; every resolved request node lies in [0, n). The JSON
layer also requires all five facts on every node, pairwise distinct keys and three arrays of
strings in the request file. A violation is invalid input (exit 2; the product's
`LayoutContractException('V5', …)`), checked before anything is laid out.

**Consequences.**
- In `compact`, a stack node sits one row above its parent, where m_1 was, unless a column
  constraint pushes it up; everything above moves down by the members it no longer stacks.
- In `free`, a stack node keeps y(m_k) unless the run had stretched the time axis to one pitch per
  commit (§4.2 step 3); only then do its descendants move down. A run whose commits lie a day apart
  (m_1 a day after its parent too: the gap, 20 units, exceeds U) loses its member cards and keeps
  every other y.
- I1–I6 hold on the grouped layout, a stack node counting as (T(m_k), m_k) in I6; I7 holds (§7.3).

**Known limit (D11).** A split run's stack node reserves its column from its own card, so its parent
edge, which branches off m_1's parent in another column, rises in the stack's column below the card
without a reservation and may pass behind a lower card there. §4.3's start one pitch above the
parent would avoid that, but would let collapsing grow `rows`. *(2026-10-30, Story 10.4, I2:)* the
painted line never climbs the stack's column: router B (§14.2) gives such an edge a gutter, so in
Compact no line passes behind the lower card (unless the gutter holds more than 9 lines, the reported
`overfullGutters`, whose outer lines may reach into cards); in Free a gutter route whose every gutter is blocked is
the router's reported fallback (`fallbackEdges`) and may still pass behind a card.

*Amended 2026-11-10, Story 4.17:* D11 no longer applies: no run is split (step 4, amended).

*Amended 2026-11-10, Story 4.18:* the kinds, `overfullGutters` and `fallbackEdges` named above went
with router B. §14.3 lists what the router reports now.

**The design sample, by hand.** `e243dd2` (52 commits, §7.2), `compact`, greedy, the default
request: no run lies in A (the onboarding chain under `@` has no run), so every run collapses.
- `all` (7 runs): `rows` 19 → 15. The longest chain, root → … → vruxwmqv → the qmsvtlkr run →
  sxmtvqno → lvqrnkmw → potwkszn → ompktvxr → yxlnqwmk → srkvzmop, passes three runs:
  mzvwutvl–zsuskuln and nvkqlxsp–rtmswzvk below vruxwmqv save one row each (vruxwmqv 9 → 7), and
  qmsvtlkr–wrnxqpsz–ynkplrtv saves two (sxmtvqno 13 → 9): srkvzmop 18 → 14. No column constraint
  binds on it (in ntvrqkzo's column the segment below ends at romwxqkn, row 5, and its merge child
  wlmpxokt, row 8, both below sxmtvqno's 9).
- `default` (6 runs): `rows` 9 → 8. srkvzmop (row 8) has two Indirect parents. kxwsnptm drops
  from 6 to 4 (the mwoqxlpn run, four members, becomes one card at 2; vtxnbqrs stays at 3).
  The qmsvtlkr run becomes one card at 2, which alone would put sxmtvqno at 3 — but a column
  constraint binds: in zqklmwts's column, the nqxwrptl run's card (2) and mrplxqwv (3) form the
  segment below zqklmwts, whose first parent is sxmtvqno, so y′(sxmtvqno) ≥ y′(mrplxqwv) + 1 = 4
  (in the ungrouped layout, zqklmwts's reservation starts one row above sxmtvqno and mrplxqwv's
  ends two above mrplxqwv). So potwkszn 7 → 6 and srkvzmop 8 → 7. *(The story's planning estimate,
  9 → 7, missed this constraint.)*

With the `compact` order the columns differ, and so do the constraints: `all` 19 → 16, `default`
9 → 8 (measured, not derived by hand). `golden_test.dart` asserts the greedy counts. If the engine
disagrees, re-derive by hand before changing a number.

*Amended 2026-10-27, Story 4.14: joint columns.* §4.8 runs unchanged on the joint ungrouped
columns (§4.3 / §4.7, amended) with the requested mode's rows; (F) and the day buckets stay
`free`-only. The termination argument's "the reservations of such chains are disjoint" holds in
each model, so it holds for the requested one. Every stack node takes lane(m_k) and col(m_k), which
are the same in both modes, so I8 holds with stacks for every stack state. The design sample,
re-derived by hand with joint columns (compact, greedy, every run collapsed):
- `all`: the joint packing equals the per-mode one here (9 lanes), so 19 → 15 as above.
- `default`: 9 → **7**. The joint packing has 8 lanes (the per-mode compact one 7): zqklmwts no
  longer shares column 4 with the nqxwrptl run and mrplxqwv but has column 7 to itself, so the (C)
  constraint that held sxmtvqno at 4 is gone. The qmsvtlkr run's card is at row 2, so sxmtvqno is
  at row 3, lvqrnkmw at row 4 and potwkszn at row 5. kxwsnptm stays at row 4 (the mwoqxlpn run's
  card is at row 2, vtxnbqrs at row 3). srkvzmop is at row 6, so `rows` is 7. zqklmwts, whose only
  parent is sxmtvqno (row 3), is at row 4.

With the joint `compact` order: `all` 19 → 15, `default` 9 → 7 (measured).

*Amended 2026-11-10, Story 4.17:* the columns of this sample are now branch columns, and the hand
counts above stay: `all` 19 → 15, `default` 9 → 7 (`golden_test.dart` re-checks them, in `compact`).
If the engine disagrees, re-derive by hand before changing a number.

## 5. Complexity: design step → spike

| step (GV) | design | spike | spike cost |
|---|---|---|---|
| visible set + hidden-parent DFS (:141-158) | O(N) + O(k·h) | not in the layout: typed edges come from jj's graph iterator | — |
| compact rows, recursive `rowOf` (:173-176) | O(n+E), stack depth = longest chain | reverse-index loop | O(n+E) |
| time buckets + per-bucket ts sort (:161-172) | O(n log n) + a Date/Intl call per node | integer keys, clamp, sort of distinct keys | O(n log n + E) |
| free rows | — | clamp, sort by T, one walk | O(n log n + E) |
| packing order (:178) | O(n log n) | same | O(n log n) |
| lane packing (:179-196) | O(n²) interval scans | top-2 b′ per lane + segment tree | O(n log n) |
| blocked (:204-207) | O(E·n) | per-lane y-list + binary search | O(E log n) |
| optimizeLanes (:99-138) | O((L−1)!·E²) / O(passes·L²·E²) | windowed sifting, budgeted | O(E log E + BUDGET·log n) |
| routeEdges (:52-69) | O(E) | route enum | O(E) |
| analyzeEdges + gaps (:72-96, :216-217) | O(E²) + O(E·C) | none; painter, visible edges only | — |
| positions, paths, extents (:198-224) | O(n+E) | painter | — |

Every phase is O((n + E) log n), except the ordering search, which the budget bounds.

*Amended 2026-11-10, Story 4.17:* the ordering search and its budget are gone. The column phase is
the exception now: O(C·K·log C) for C branches over K columns (§4.3, Branch columns, Bound). Measured
6 ms at synth-100k (202 columns) and about 2.5 s (JIT) on an artificial star of 40,000 parallel
branches.

## 6. CLI (both implementations)

```
layout --mode compact|time|free --order greedy|optimized <input.json> <output.json>
bench  --mode compact|time|free --order greedy|optimized --runs N [--warmup W] <input.json>
```
- **Exit codes:** 0 on success. 2 on a usage error or invalid input (§2), with a message on
  stderr and no output file.
- **`bench`** prints exactly one JSON line to stdout (§8.4).
- **Binaries:**
  - Rust: `rust/target/release/graph-layout`;
  - Dart: `dart/bin/graph_layout.dart`, run as JIT via `dart run`, or compiled AOT via
    `dart compile exe … -o dart/build/graph_layout`.

*Clarified during diff (2026-09-26).* Both implementations already agreed on all of these;
`tools/fuzz.mjs` probes each one.
- **Defaults.** `--runs` defaults to 31 and must be ≥ 1; `--warmup` defaults to 10 and must be
  ≥ 0.
- **Flag syntax.** `--flag value` and `--flag=value` are both accepted.
- **Exit 2** for all of these:
  - an unknown or repeated flag;
  - `--runs` / `--warmup` given to `layout`;
  - an unreadable input file;
  - an unwritable output file.
- **Dart-only (2026-09-26):** `--order compact` (§4.7), in `layout` and `bench`.
- **Dart-only (2026-10-01, Story 4.11):** `--budget B` (an integer ≥ 0, default 2,000,000), in
  `layout` and `bench`: the `compact` order's search budget (§4.7; the other orders ignore it).
  `tools/goldens.mjs` uses it for the budget-cut goldens. The Rust binary has no `--budget` (an
  unknown flag, exit 2); the product engine's CLI (§13) always runs the default.
- **Dart-only (2026-10-01, Story 4.13):** `--stacks <request.json>`, in `layout` and `bench`, with
  `--mode compact` or `free` (with `time` it is a usage error, exit 2): the
  stack request of §2 (amended), which also makes the input's stack facts required; the layout
  then runs §4.8 and writes §3's output with stacks. `bench` times it as one more phase, `stacks`,
  after `ordering` (the request is parsed in `parse`; `total` still spans layering … the last
  phase), and its digest (§8.4) runs over the n + S node entries and the grouped edges, a hidden
  member counting as row = col = lane = −1 (d stays in [0, P): the mod is the non-negative
  remainder). An unreadable or malformed request file is exit 2, as is a stack-fact violation of the
  input. The Rust binary has no `--stacks` (an unknown flag, exit 2). The product engine's CLI
  (§13, `packages/zanshin_core/benchmark/graph_layout_cli.dart`) takes it too.
- **Dart-only (2026-10-27, Story 4.14):** `--columns mode|joint`, in `layout` and `bench`; default
  `mode` (the per-mode packing and order, as before, so Rust ≡ Dart, `tools/fuzz.mjs`,
  `tools/bench.mjs` and `tools/js_oracle.mjs` run unchanged). `joint` lays out joint columns
  (§4.3 / §4.7, amended) and takes only `--mode compact|free` with `--order greedy|compact`; any
  other combination, or another value, is exit 2. `bench` then echoes `"columns":"joint"` after
  `"order"`. The Rust binary has no `--columns` (an unknown flag, exit 2); the product engine's CLI
  always lays out joint columns and has no flag for it.
  *Amended 2026-10-31, Story 4.16:* `joint` also turns on `free`'s day step (§4.2 free.3, amended),
  so `mode`'s rows stay the Rust reference's.
- **Product CLI (2026-11-10, Story 4.17):** `packages/zanshin_core/benchmark/graph_layout_cli.dart`
  has neither `--order` nor `--budget`: both are unknown flags (exit 2). It takes
  `layout --mode compact|free [--stacks R] <input.json> <output.json>` and
  `bench --mode compact|free [--stacks R] [--runs N] [--warmup W] <input.json>`; `bench` has no
  `"order"` field. `router_cli.dart` has no `--order` either.

## 7. Verification

The tools (plain node, run from the spike root after building both binaries):
- `tools/compare.mjs [--digest]`: §7.1 and §7.3 over every input × mode × order.
- `tools/js_oracle.mjs [--fuzz N]`: §7.2. With `--fuzz`, random design graphs as well.
- `tools/fuzz.mjs [--cases N]`: input and CLI probes, then random small inputs checked against
  a naive, literal JS reading of §4.
- `tools/lane-metrics.mjs [--node IDX] <output.json>…` (2026-09-26): not a check. It measures a
  lane order: crossings as the viewer draws them, run length, width and holes (README, "Lane
  order review").

### 7.1 Rust ≡ Dart

For every input × mode × order, the two `layout` outputs must pass `cmp`, and the `bench`
digests must be equal.

### 7.2 JS oracle (the design)

**How it runs.** `tools/` extracts these declarations from graph-view.jsx **by name**: `G`,
`LADDER`, `timeBucket`, `roundedPath`, `routeEdges`, `analyzeEdges`, `optimizeLanes`,
`computeLayout`. The file's JSX parts are not evaluated. It evaluates the declarations after
graph-data.js with `window = globalThis`, under `TZ=UTC`, and runs
`computeLayout(GRAPH_COMMITS, rev, 240, 62, mode, {optimize: false})` for
rev ∈ {default, all} × mode ∈ {compact, time}.

*(2026-09-30: both files are read from git at the pinned export `57f259c`, the 22-commit sample
this section was derived from (`tools/design-source.mjs`), never from the live export folder,
which Ralph replaces on every re-download. `node tools/design-input.mjs --rev <commit>` converts
another export into `inputs/design-<commit>-<rev>.json`, with one `missing` entry per Missing
parent where that export records them. A no-op stands in for `window.placeGapMarkers`, which
computeLayout calls from `e243dd2` on; its markers are drawing only.)*

**What each run writes.**
- The input, `inputs/design-<rev>.json`:
  - the nodes: the design's visible nodes in reverse design order (children first);
  - `parents`: the design's `n.parents` (`skipped` → `indirect`, otherwise `direct`), plus one
    `missing` entry if `elided > 0`;
  - `id`: the change id; `ts_ms`: `Date.parse(ts)`, or null; `is_root`;
  - `priority`: the 0-based rank of (`c.priority`, design index). This folds the design's float
    priority and its root-first `idx` into one integer;
  - `now_ms` = `Date.parse(GRAPH_NOW)`; `utc_offset_min` = 0.
- The expected output:
  - rows, lanes and cols from the design's nodes;
  - edges re-ordered as in §3, with the route taken from the design's classification and
    `blocked` normalised (D4);
  - buckets from the design's `{label, start, end}`, with kind and value recomputed via
    `timeBucket` of a member.

**What must match.** Both implementations must match these files byte for byte for `greedy` ×
{compact, time}: 4 files. The sample has monotone timestamps and no indirect edges, so it does
not exercise D1; §7.3 covers that.

**Expected results on the sample for what the oracle cannot check.** These come from this spec,
not from the design: hand-computed, then confirmed on 2026-09-26 with a throwaway, naive JS
reference of §4, not committed. That reference also reproduced the 4 greedy oracle files byte
for byte.
- `optimized`, `compact` → the identity, as in the design.
- `optimized`, `time` → π = [0, 2, 3, 1] on both revsets, with X going from 2 (greedy) to 0.
  The design also reaches 0 crossings; on the default revset its exhaustive search picked the
  equal-cost [0, 3, 2, 1].
- `free` → `rows` = 209 on the default sample and 377 on `all`, with 4 lanes. These are not
  authoritative; Rust ≡ Dart is the real check.

If an implementation disagrees, re-derive by hand before "fixing" code.

*Amended 2026-10-27, Story 4.14: the `e74ced3` export and the joint oracle.* From `e74ced3` on,
the export keeps its layout in `graph-layout.jsx` (GL), plain JS: one IIFE that sets
`window.computeLayout`. `tools/design-layout.mjs`'s `loadLayout(commit, {exact})` evaluates
`graph-data.js` and `graph-layout.jsx` **whole** in a fresh `vm` context (read with `git show`,
`window` = the context's global, `TZ=UTC`), with the Graph Lines Study's `revsetMatch` stub
(`(id) => id === "all" ? () => true : (c) => !!c.inDefault`) and a no-op `placeGapMarkers`.
`exact: false` removes GL's one exact-colouring candidate line by a checked substitution (it throws
if the line is not there exactly once). `tools/design-input.mjs` uses it when `graph-view.jsx` has no
top-level `computeLayout`, so `--rev e74ced3` writes `inputs/design-e74ced3-{default,all}.json`,
byte-identical to the `e243dd2` inputs (`graph-data.js` is unchanged).

**The joint oracle.** `node tools/design-layout.mjs [--rev e74ced3]` runs GL's
`computeLayout(GRAPH_COMMITS, rev, 240, 62, "compact", {optimize: false})` per revset, with exact
colouring off (GL keeps the fewer of its two greedy packings, by Free and by Compact order — the
rule of §4.3, amended) and on, and compares GL's greedy lane count with the Dart binary's
`layout --mode compact --order greedy --columns joint` on `inputs/design-e243dd2-<rev>.json`; it
writes `outputs/oracle/joint-design-<rev>.lanes.json` and exits 1 on a mismatch. Measured
2026-10-27: `default` 8 lanes (GL greedy 8, GL exact 8, joint 8), `all` 9 (9, 9, 9). The product's
`golden_test.dart` checks the joint greedy lanes against these files. Only the lane count is
compared: GL's whole-lane optimizer, router-judged packing choice and W/H-dependent rows are not
ported (spec-4-14, Design Notes: exact colouring returns only past a measured threshold, which it
did not meet). On a mismatch, re-derive by hand before changing code.

*Amended 2026-11-10, Story 4.17:* the joint oracle retires, with the joint packing. Its
`joint-design-*.lanes.json` goldens are deleted, and the product is no longer compared with GL's lane
counts. The reference for the product's columns is the lab: `bin/lab_check.dart` compares them with
`chooseColumns` (`spikes/graph-layout-lab/lib/columns.dart`).

*Amended 2026-10-27, Story 4.15: the router oracle.* `node tools/router-oracle.mjs` (from the spike
root) checks §14's router against GL's own `routeAll` on GL's own grids, so differences in lane
order never leak in. It loads GL through `loadLayout` with one checked substitution (GL's
`routeLines` output gains `kind: e.kind`) and evaluates the Lines Study's `PRESETS` / `FAN`
declarations (`graph-lines-study.jsx`, read with `git show` at `e74ced3`) in the same context.
Cases: the sample (`default`, `all`; `optimize: false`) and the Study's PRESETS 1 / 2 / 3 × FAN
0 / 4 / 8 (`groupStacks(…, "default", []).list`, `optimize: true`), each at W 160 / 240 / 400 ×
H 40 / 62 × `free` / `compact`. Per case it feeds GL's grid — node order, `col`, row = `u` in
`free` (U 16) or `u` / 16 in `compact` (U 1), the parents in order with their kind, `parentCount`
= the design commit's `parents.length` — to the product's `benchmark/router_cli.dart oracle`, and
compares per edge the kind, the exit and entry offsets, the polyline (±1e-6) and the bridges. A
case is equal, or every kind and slot difference is explained — by the unit rule (§14.2; listed
with the blocking card's unit distance and GL's pixel verdict) or by shared-entry grouping
(GL groups by its own `via`, §14 by `parentCount`) — and the remaining geometry differences of
that case count as consequential. It writes `outputs/oracle/router-*.json` and exits 1 on an
unexplained difference. Measured 2026-10-27: all 132 cases equal (4,692 edges, 198 bridges, 72
overfull clusters), with no run that the unit rule and GL's pixel test judge differently and no
shared-entry grouping difference. GL's grids hold no `gutter` line (its optimizer avoids them), so
gutter routes are witnessed by the product's hand-built tests and the scale checks, not by GL.

*Amended 2026-11-10, Story 4.18: the router oracle retires, with router B.* The `oracle` command of
`benchmark/router_cli.dart` is gone, and `tools/router-oracle.mjs` stays in the spike as history. The
reference for the lines is the lab: `bin/lab_check.dart` runs its line rules on the product's lines,
and `bin/lab_metrics.dart` prints the product's metrics next to the lab's
(`spikes/graph-layout-lab`). The two paragraphs on the oracle here and below describe what it was.

*Amended 2026-10-27, closing run of Story 4.15: gutter routes in the router oracle.* The oracle gains
a third category, `gutter`, so GL itself routes gutter lines. The bases are the sample revsets
`default` and `all` (GL's own columns, `computeLayout(GRAPH_COMMITS, rev, 240, 62, "compact",
{optimize: false})`) and the Study's PRESETS 1 / 2 / 3 at FAN 0 (GL's own optimized columns; their
octopus merge gives a child several non-first parents on one side, which the sample lacks); every
single-node move (each node in GL's node order into each column 0 …
colCount other than its own) is passed as GL's `opts.cols`, which freezes the columns when they are
valid in both vertical models and silently re-packs otherwise (keyed like GL: a stack by its
first member; a move never runs the optimizer). A move counts only if GL froze it
(every node's `col` is the requested one, at all 12 metrics); each frozen move × the 12 metrics is a
case iff GL routes ≥ 1 `gutter` line, named `gutter-<rev>-<node>-c<col>-<mode>-W<W>-H<H>`. These
grids go through the same comparison as the other categories. Over the category's equal cases the
oracle counts gutter lines, stepped gutter lines (GL's gutter vertical x off the gutter's own x by a
positive multiple of 6 px; any other offset throws), deep gutter lines (dashed, sharing a `via` with
another dashed edge into the same child), lines whose gutter lies left or right of the child, lines
whose parent has another non-straight line leaving on the same side (shared exit side), lines into a
child with another non-first-parent line approaching on the same side of its centre (shared entry
side) and lines in `compact` cases (lane-blocked by construction); it writes them to
`router-report.json` (`gutter_coverage`) and exits 1 if any count is 0. It also pins the
generation counts, which move only with a new GL export: frozen moves 115 (`default`), 269
(`all`), 67 / 87 / 91 (PRESETS 1 / 2 / 3), 1,485 gutter cases. Measured 2026-10-27: those counts,
1,467 gutter cases equal and 18 explained, none unexplained, the 132 original cases still equal;
over the equal cases 1,815 gutter lines, 108 stepped, 132 deep, 1,170 left, 645 right, 399 with a
shared exit side, 12 with a shared entry side, 294 in `compact`. The 18 explained cases are all
Free at H 40 (W 160 / 240 / 400 each) and all one run: the line from `xrlpkvqm` (or its stack
`grp:tqwmlnxz`) into `mxnztwqp`, with the card `lvqrnkmw` 12 units above the parent — GL's pixel
test finds the band above the parent clear and keeps the run direct (or, where the line is a
gutter line anyway, takes a different gutter), §14.2's unit rule blocks that run: the unit rule's documented
difference at H 40 (d = 12, Story 4.15's derivation). The router was not changed.

### 7.3 Invariants

`tools/` checks these on every output against its input:
- I1: y(i) ≥ y(p) + U for every layout edge.
- I2: per lane, for consecutive nodes u, v by y, y(v) − y(u) ≥ 2U, or ≥ U when (u, v) is a
  `straight` edge. In the row modes this means at most one card per cell.
- I3: `straight` ⇔ lane(p) = lane(i), and then p = fp(i). `merge` ⇒ pos(p, i) ≥ 1 and not
  blocked. blocked ⇒ lane(p) ≠ lane(i).
- I4: col = π(lane) for a single permutation π with π(0) = 0. `greedy` ⇒ col = lane.
- I5: in `time`, the buckets are strictly ascending by key; their row ranges are contiguous from
  0 to rows − 1; each node lies inside the bucket of eb(i). In the other modes, `buckets` is
  `[]`.

  *Amended 2026-10-01, Story 4.11 (it replaces "In the other modes, `buckets` is `[]`"):* in
  `compact`, `buckets` is `[]`. In `free` (§4.2 free, step 4):
  - every bucket's kind is `day`, and the values are strictly ascending;
  - start ≤ end for every bucket, and end of one ≤ start of the next (a y value can hold two
    days; the ranges need not be contiguous, start at 0 or end at rows − U);
  - every node with `is_root` false lies in the bucket of dk(i), start ≤ y(i) ≤ end;
  - each bucket's start and end are the least and the largest y of its members;
  - there is no bucket iff there is no node with `is_root` false.

  *Amended 2026-10-31, Story 4.16:* with joint columns (the product) consecutive `free` buckets
  keep one pitch: end_k + U ≤ start_{k+1} (the band around a day divider holds no card), with
  stacks too. The core checkers (`invariants.dart`, `stack_invariants.dart`) and the app's
  `checkLayoutInvariants` (`dayBandClear`, row model only) enforce it.
- I6: in `free`, y never decreases in (T asc, i desc) order.

*Amended 2026-10-01, Story 4.13: with stacks (§4.8).*
- I1–I6 hold on the grouped layout: over the visible nodes and the stack nodes and the grouped
  edges, with the grouped pos and fp′; in I5 a stack node lies in the day of T(m_k); in I6 a stack
  node sorts as (T(m_k), m_k).
- I7 (columns): every visible node keeps its ungrouped lane and col, so do the members of an
  expanded run, a stack node sits in its newest member's lane and col, and `lanes` is the ungrouped
  value — for every stack state (all collapsed, all expanded, any subset) and without stacks.
- Compaction: y′ ≤ the ungrouped y for every visible node, y′(s) ≤ y(m_k) for every stack node, and
  `rows` ≤ the ungrouped `rows`. With every run expanded, the nodes, edges, buckets and `rows` equal
  the ungrouped output.

*Amended 2026-10-27, Story 4.14: joint columns.*
- I8 (columns across modes): for one input, order and stack request (or none), the `compact` and
  the `free` output have the same `lanes` and every node — stack nodes included, a hidden member −1
  in both — the same `lane` and `col`. The product's grids carry the same day keys in both modes too.
- I1–I7 hold in both modes on the joint columns, I2 included in the model that did not drive the
  packing; the joint `compact` order's joint cost (16·cost_c + cost_f) is never above joint
  greedy's before the closing pass (§4.7), which only lowers the crossings and runs.

*Amended 2026-11-10, Story 4.17: branch columns (§4.3).* For every product layout, per mode, without
stacks and over the grouped rows with stacks (each stack state):
- I1, I5, I6 and I7 hold as before.
- **I2 (restated).** In one column, consecutive cards keep at least U, and two branches keep one
  pitch between their reserved rows.
- **I3 (restated).** `straight` ⇔ lane(p) = lane(i) (a merge child may sit in its merge parent's
  column, so `straight` no longer implies a first parent). `merge` ⇒ pos ≥ 1 and not blocked.
  Blocked ⇒ lanes differ.
- **I4 (restated).** col = lane. The main branch is alone in column 0, and a branch has one column.
- **I8 is removed.** A `compact` and a `free` grid of one input may differ in `lane`, `col` and
  `lanes`. The day keys stay equal in both.
- The columns equal the rule read literally (`naiveBranchColumns`, `invariants.dart`) on every golden
  input and on ≥ 1,000 seeded DAGs × both modes, and the stack checks hold on the stack states
  collapsed, expanded, default and random.

## 8. Benchmark protocol

### 8.1 Inputs

- **Scale points:** about 1k, 10k and 50k nodes (100k if available), for `all()` and for the
  default revset, dumped from real repos.
- **Synthetic inputs:** deterministic, generated by `tools/` from fixed seeds. They fill in
  where real repos lack one of:
  - a scale point;
  - a branchy shape (≥ 100 lanes);
  - non-monotonic timestamps (on ≥ 1 % of edges).
- The design sample is for the oracle only; it is too small to time.

### 8.2 Procedure

Run one `bench` process for each impl ∈ {rust, dart-aot, dart-jit} × input × mode × order, with
W = 10 and N = 31 (the defaults).
1. Read the file into memory once (untimed).
2. Run W warm-up iterations, then N timed iterations. Each iteration parses the in-memory bytes
   into fresh input arrays, then runs the layout from scratch; nothing is reused across
   iterations.
3. Take timestamps t0 … t6 around parse, layering, lanes, blocked, routing and ordering.
   - `total` = t6 − t1: one span, NOT a sum of per-phase medians. Parse is excluded.
   - Building and serialising the output is not timed.
4. Per phase, report the median (the sorted sample at index N div 2) and the minimum, in ns.
   Use a monotonic clock: Rust `Instant`; Dart `Stopwatch` ticks × 10^9 div
   `Stopwatch.frequency`.

**Which numbers count.**
- Primary: Rust `--release` (the default release profile, like the production cdylib) against
  Dart AOT (`dart compile exe`).
- Secondary: Dart JIT (`dart run`).

**Conditions.** One machine, on AC power and otherwise idle, with all runs in one session.
Record the CPU, the OS, and the rustc and Dart versions.

*Amended 2026-11-10, Story 4.17:* the product CLI times `layering`, `lanes`, `blocked` and `routing`
(and `stacks` with a stack request); it has no `ordering` phase, and `total` spans layering … the
last phase. `lanes` is the branch column choice of §4.3.

### 8.3 Fairness

- Both implementations use the same algorithm and the same data layout:
  - flat index arrays (Rust `Vec<i32>` / `Vec<i64>`, Dart `Int32List` / `Int64List`);
  - CSR adjacency;
  - no per-node heap objects or maps on hot paths;
  - single-threaded, with no `unsafe` or FFI tricks.
- Parsing may use each language's standard JSON library: serde_json, dart:convert.
- An optimisation applied in one implementation (for example packing a composite sort key into
  one int64) is applied in the other too.

### 8.4 The `bench` output line

```json
{"impl":"rust","input":"synth-10k.json","mode":"time","order":"optimized","nodes":10000,"edges":10840,"rows":…,"lanes":…,"digest":…,"warmup":10,"runs":31,"phases":{"parse":{"median_ns":…,"min_ns":…},"layering":{…},"lanes":{…},"blocked":{…},"routing":{…},"ordering":{…},"total":{…}}}
```
- **`impl`** is one of `rust`, `dart-aot`, `dart-jit`. The Dart binary is AOT ⇔
  `bool.fromEnvironment('dart.vm.product')`.
- *Clarified during diff (2026-09-26):*
  - `edges` is E, the layout edges (missing parents excluded);
  - `input` is the basename of the input path;
  - the `parse` phase includes V1–V4 validation;
  - `layering` includes the §4.1 graph prep.

  Both implementations already did this.
- **`digest`** is taken from the last iteration, with P = 1 000 000 007. Start with d = 0, then:
  - per node, in index order: d = (31·d + 7·row + 3·col + lane) mod P;
  - per edge, in output order: d = (31·d + r + 4·blocked) mod P, with r = 0 / 1 / 2 for
    straight / merge / branch_off;
  - per bucket: d = (31·d + start + 3·end) mod P.

## 9. Deviations from the design

- **D1 — time: topological clamp.** A child's bucket is at least its parents' (eb). Rows are
  longest paths from the bucket start, independent of the ts order inside a bucket. This fixes
  two verified defects: the same-cell overlap (a child older than its parent inside one bucket)
  and upside-down edges (a child in an older bucket). It is identical to the design whenever ts
  never decreases along an edge.
- **D2 — edges are jj facts.** Direct / Indirect / Missing come from jj's graph iterator, which
  prunes transitive edges, walks Missing edges only a bounded distance, and keeps Missing edges
  beside Indirect ones. The design derives them with its own hidden-parent DFS per parent. The
  layout ignores Missing edges, as the design ignores elided parents. Elided counts are out of
  scope.
- **D3 — ordering key.** The design's (float `c.priority`, root-first `idx`) becomes (int
  `priority`, input index). jj input is children-first, so the index tie-break favours the
  earlier-printed commit, which is jj log's leftmost-column rule. The jj derivation of
  `priority` (§2) is a stand-in.
- **D4 — `blocked` is false on straight edges.** There the design's formula counts the child
  itself, so it is always true, and the design ignores it.
- **D5 — lane order.** Windowed sifting on 400·X + 4·Len + Disp replaces the design's
  exhaustive search / hill climbing on 100·(crossings + overlaps) + len + 0.25·disp:
  - there is no collinear-overlap term;
  - crossings of edges that share an endpoint are counted;
  - the branch-off side stubs are not modelled;
  - the W term is dropped (it is the same for every permutation).

  Only `greedy` is checked against the oracle.

  *Amended 2026-11-10, Story 4.17: superseded by D15; the product has no lane order.*
- **D6 — no pixels.** x/y, paths, rounded corners, gaps, extents, `offX` and `botExtra` are the
  painter's. The output is free of W and H by construction.
- **D7 — time zone.** Calendar days use a fixed `utc_offset_min` instead of the viewer's
  DST-aware local midnight. This keeps the result deterministic across languages, but a commit
  on the other side of a DST switch may land one hour off its day boundary.
- **D8 — `free` mode is new.** Its constants are provisional: U = 16, the gap curve, a cap of 3
  pitches. Known issue: a bus can pass behind a card in an intermediate lane. That cannot happen
  in the row modes, where every bus lies in a row gap; the layout does not prevent it here.
- **D9 — a design defect is kept:** blocked-merge routing (§4.5).
- **D10 — recursion and Intl calls are removed** (§5). For n = 0, rows = lanes = 0; the design
  reports 1 lane.
- **D11 — a split run's stack node is unprotected below its card** *(added 2026-10-01, Story
  4.13)*. The design re-runs its whole layout on the grouped commit list, so its columns re-pack on
  every toggle; §4.8 keeps the ungrouped columns (Ralph, 2026-09-28) and compacts only rows. A split
  run's stack node reserves its column from its own card, so its parent edge (a branch-off from
  m_1's parent) rises in the stack's column below the card without a reservation and may pass
  behind a lower card there. Reserving from one pitch above the parent, as §4.3 does, would let
  collapsing grow `rows`. *(2026-10-30, Story 10.4, I2:)* router B (§14.2) never lets such an
  edge climb the stack's column but gives it a gutter (since 2026-11-09 a `merge-up` first where the
  parent's column is free), so in Compact no line passes behind the lower
  card unless the gutter holds more than 9 lines (the reported `overfullGutters`, whose outer lines
  may reach into cards); the route report's Compact gate and a D11 hand case witness it. In Free a
  gutter route whose every gutter is blocked is the router's reported fallback (`fallbackEdges`) and
  may still pass behind a card.

  *Amended 2026-11-10, Story 4.17: D11 no longer applies; no run is split (§4.8 step 4, amended).*

  *Amended 2026-11-10, Story 4.18: the kinds, `overfullGutters` and `fallbackEdges` named above went
  with router B (§14.3 lists what the router reports now).*
- **D12 — `free`'s day band** *(added 2026-10-31, Story 4.16)*. The design places y by time
  alone, so two commits on either side of local midnight less than ~25 min apart in different
  columns overlap vertically, and the painter's day divider (Story 10.2, midway between the older
  day's newest and the newer day's oldest card) runs behind both cards (prototype defect 45). With
  joint columns the walk's step across a day change is at least one pitch (§4.2 free.3, amended),
  so the band around a divider is card-free (I5, amended). This closes the known midnight overlap;
  `rows` grows by at most U − gap per close boundary. Compact's rows and the painter are unchanged; compact's lanes and columns can
  move, since the free model feeds the joint packing (§4.3), and I8 still holds.
- **D13 — short chain pieces return to their parent's lane** *(added 2026-11-09, Ralph)*. The design
  excepts only the first parent's interval, so a merge child above the continuation pushes the
  chain's next node into another column, and the design leaves it there. After the joint packing a
  piece of at most 8 cards returns (§4.3). The non-joint Rust and Dart reference paths keep the
  design's result. *Amended 2026-11-10, Story 4.17: superseded by D15.*
- **D14 — a closing pass without gravity** *(added 2026-11-09, Ralph)*. The design has no `compact`
  order at all, and §4.7's gravity leaves a branch far from a trunk that sits right of it. A closing
  pass lets a segment alone in its window move toward its lines, out of column 0 too (§4.7).
  *Amended 2026-11-10, Story 4.17: superseded by D15.*
- **D15 — columns by branch, per mode, from the lab** *(added 2026-11-10, Story 4.17; Ralph approved
  the lab's rules that day)*. The product's columns come from the graph layout lab
  (`spikes/graph-layout-lab/lib/columns.dart`), not from the design: the main branch is alone in
  column 0, a branch keeps one column, and Free and Compact each choose their own columns. The design's
  shared columns (`DESIGN-SYSTEM-SYNC.md` #8, §13's joint columns) are no longer followed. This
  supersedes D5, D13 and D14; D11 no longer applies, because no run is split.

## 10. Project layout and detaching

Modelled on `spikes/ffi-payload-bench`:
- **`rust/Cargo.toml`:**
  - an empty `[workspace]` table, which makes it its own workspace root: the parent's
    `crates/*` glob, `cargo test --workspace`, clippy, deny and the coverage gate never see it;
  - `publish = false`; dependencies `serde` and `serde_json` only; bin `graph-layout`;
  - `Cargo.lock` committed.

  The layout itself is a library module with no jj-lib dependency, in the zanshin-graph shape,
  so the winner can move into the product almost verbatim. If the stage-2 dumper needs jj-lib,
  keep it out of this crate's dependency graph (for example as its own detached crate).
- **`dart/pubspec.yaml`:** standalone, with no `resolution: workspace` (the root workspace lists
  only `app` and `packages/*`) and no dependencies beyond the SDK. `pubspec.lock` is ignored.
- **`tools/`:** plain node scripts with no npm dependencies.
- **`inputs/`, `outputs/`:** generated and gitignored.

Nothing outside `spikes/graph-layout-ab/` is modified.

## 11. Open for Ralph

None of these blocks the spike.
1. The row model: compact, time or free (*decided 2026-09-27: `free`, the default, and `compact`;
   §12*). For free, also the gap curve and whether buses may
   pass behind cards.
2. The real source of `priority`: log order, `log-graph-prioritize`, bookmarks, or the trunk/@
   chains.

   *Decided 2026-10-01, Story 4.11 (decisions-review 4.11 OQ 1): the anchors rule, normative
   from now on.* The caller passes an ordered list of anchors (revsets); each selects the nodes it
   shares with the revset. With A the number of anchors:
   ```
   class(i) = A for every node
   for k = 0 … A − 1:
     for each node a of anchor k, ascending:
       cur = a
       while cur exists and class(cur) > k:
         class(cur) = k
         cur = fp(cur)        // the first non-missing parent, after §2's repeated-target rule;
                              // it may be indirect
   priority(i) = class(i)
   ```
   So class k holds anchor k's nodes and their first-parent chains, each up to the first node of
   a lower class; everything else is class A. The result does not depend on the order in which
   one anchor's nodes are visited. Ties fall to the index (D3). With the pre-fill
   `[trunk(), present(@)]` it yields exactly §2's three classes (0 the trunk chain, 1 `@`'s chain
   up to the first class-0 node, 2 the rest); with no anchor every node is class 0. The
   dumper's `assign_priorities` (`rust-inputs/src/input.rs`) and the product's input builder
   (§13) implement it.
3. Committer vs author timestamp, and DST-exact day boundaries.
4. Blocked-merge routing (D9).
5. `optimized` is global: one operation can reshuffle columns (*moot for the product since
   2026-09-27: `optimized` is dropped; §12*). A stability rule (seeding π from
   the previous layout) is out of scope here.
6. (2026-09-26) The default lane order: greedy or `compact` (§4.7) (*decided 2026-09-27: `compact`,
   with greedy as the alternative; `optimized` is dropped from the product; §12*). `compact` is local in time,
   but a new commit can still re-cut a window and move columns there.

## 12. Product decisions 2026-09-27

Ralph's decisions after using the viewer on a real 1.4k-commit repo (console session; recorded in
`_bmad-output/planning-artifacts/epics.md`, Epic 10 and Stories 4.11 and 10.4; README "Product
decisions 2026-09-27"). Nothing above is deleted: the spike keeps every mode and order as its
reference and history.

**What the product keeps.**
- Modes: `free` (the default) and `compact`. `time` is dropped, and so is the painter-side
  Time+gaps hybrid (§0). §11.1's row-model question is answered; `free`'s constants (D8) and
  whether buses may pass behind cards stay open.
- Orders: `compact` (§4.7, the default) and `greedy`. `optimized` (§4.6) is dropped, so §11.5 (a
  seeded π for `optimized`) no longer applies; §11.6 (the stability of `compact`) stays open.
- Decided for Story 4.11 (2026-09-27, Ralph: "the rest can go"): port only these,
  the modes `compact` | `free` and the orders greedy | `compact`. `now_ms` is then unused.

**Intended deviations from the design** (painter-side; no layout output changes): crossing gaps
always on, with no plain variant; content fading under the sticky gutter; the pinned current date
in the gutter.

**Planned change: every edge leaves the parent's top at the centre.** *(Made 2026-10-01, Story
4.11: §4.3 and §4.5 carry the dated amendments; the text below is the record of the plan.)* Every edge already enters
its child from below at the centre, and `straight` and `merge` already leave the parent's top at
the centre (§4.5); only `branch_off` leaves at pcx + s·0.28·W. The amendment of §4.5 is made with
Story 4.11's SPEC amendments, wherever SPEC lives (4.11 open question 5):
- `branch_off` leaves the parent's top at pcx, goes up 0.4·gapY, across to ncx, then up the
  child's lane into the child. It shares the exit, and the stub up to the bus, with the parent's
  `straight` continuation and with a `merge` that leaves up the parent's lane: a T-junction at
  the bus. Siblings on one side share the bus, as before; both sides now share the stub.
- §4.3's "leave from the card's side" becomes "leave through the stub above the card". The
  reservation rule is unchanged: the stub stays inside the gap above the parent (0.4·gapY), and
  the next card in the parent's lane is at least one pitch above (I2).
- §4.6's tick model and D5 do not model the stub, as they did not model the side stub. In the row
  modes nothing crosses it strictly inside: merge buses sit at 0.6 of the gap, and other
  branch-off buses of that row meet it at its end. In `free` a bus can cross the stub strictly
  inside; the painter hops it like any crossing.
- `route`, `blocked`, rows, lanes and columns are unchanged, so every output and golden stays
  byte-identical. D9 is unchanged too: a blocked merge's exit moves to the centre, but its
  vertical still runs up the child's lane (§11.4 stays open).
- The painter (Story 10.4) cuts no hop at the junction, which is an endpoint of the horizontal,
  and exempts the shared stub from its collinear-overlap report, like every overlap of edges that
  share a node (a shared bus, the parent's exit column). The design's bookmark legend pill no
  longer covers a rightward exit.
- The viewer and `tools/lane-metrics.mjs` keep the side exit (Ralph: record only); their drawn
  crossing counts are side-exit numbers.

*Amended 2026-10-27, Story 4.15:* the planned top-centre exit above is replaced by §14's exits:
a `straight` line leaves at the centre, every other line at its own port on the parent's top edge
(§14.3). The T-junction and the shared stub no longer exist.

*Amended 2026-11-10, Story 4.18:* §14's exits are now the lab's: the ports stay as §14.3 has them,
and a line's first bend decides how it leaves.

*Amended 2026-11-10, Story 4.17:* the product has one column rule and no lane orders: §4.3's Branch
columns. `greedy`, `compact` and the budget are gone from the product, and each mode chooses its own
columns (Ralph, 2026-11-10). §11.6 no longer applies.

## 13. Product engine (Story 4.11)

*(Added 2026-10-01.)* The layout the commit-graph view draws (Epic 10) is computed in Dart on
`zanshin_core`'s worker isolate. This section records where that third implementation lives and
what it adds around §2–§4; the algorithm itself is §4, unchanged.

**Location and scope.**
- `packages/zanshin_core/lib/src/graph_layout/`. The engine core (`layout_request`,
  `layout_input`, `layout_engine`, `compact_order`, `sort`, `graph_grid_view`) imports only
  `dart:typed_data`, `package:meta` and itself: no `dart:ffi`, `dart:io`, `dart:convert`,
  `dart:isolate`, no Flutter. Only the worker and the tests and benchmarks import it.
- The shipped scope of §12: the modes `compact` and `free` (default `free`), the lane orders
  `greedy` and `compact` (default `compact`). `time`, `optimized` and `now_ms` stay in the spike as
  its reference and are not ported. The ordering budget (§4.7's BUDGET) is a request parameter,
  default 2,000,000; κ, the reach, the rounds and the `free` gap curve are `const`.
- Behaviour is this document, byte for byte: §3's canonical form of the engine's result equals
  `rust/`'s output for `greedy` in both modes and `dart/`'s for the `compact` order (which has no
  Rust reference). The goldens in `packages/zanshin_core/test/graph_layout/goldens/` are
  generated from the two references by `tools/goldens.mjs`; `tools/compare.mjs --core <binary>`
  runs the product engine's CLI (`packages/zanshin_core/benchmark/graph_layout_cli.dart`, the
  §6 subset of the shipped scope) as a third implementation over every input.
- Data layout as §8.3: flat typed arrays, CSR, no per-node objects or maps; every sort is a
  hand-written monomorphic sort with a total key, so the result never depends on a library sort.

**Input builder** (`input_builder.dart`): the topology of `zanshin_graph_topology` (Story 4.10,
read through Story 4.12's `GraphTopologyView`) → the engine input of §2, in O(n + E):
- nodes in the topology's order (`jj log` order); `id` is not carried;
- each node's edges in stream order. A Missing edge stays a `missing` parent; Direct and
  Indirect edges follow §2's repeated-target rule (one parent per target, at its first position,
  `direct` if any repeated edge is direct);
- `ts` from the topology's committer timestamps, which the request loads iff the mode is `free`;
  a node has a ts iff timestamps were loaded and it is not the root; `is_root` is the topology's
  root flag;
- `priority` from the topology's anchors by §11.2's rule;
- `utc_offset_min` from the request (read by `free` only).

The builder copies values verbatim: it neither repairs nor rejects. The engine validates V1–V4
of §2 before it lays anything out (V4 over the engine input: every ts within ±2^53,
0 ≤ priority < 2^31, |utc_offset_min| ≤ 1440) and throws `LayoutContractException(rule,
message)` with `rule` `V1` … `V4`: never a partial or silently repaired layout.

**Result.** One little-endian buffer per layout, read through `GraphGridView`
(`graph_grid_view.dart`, whose doc comment is the format's contract): a header of int32 slots
(format version, mode, order, U, rows, lanes, n, E, the bucket count, then a byte offset and an
element count per array) and twelve 8-aligned arrays — per node row, lane and col; per layout
edge (§3's order) from, to, kind, route and blocked; per bucket kind, value, start and end. The
route codes are §8.4's r (0 straight, 1 merge, 2 branch_off); the edge-kind codes (0 direct,
1 indirect) and the bucket-kind code (2 `day`) are `GraphGridView`'s. Rows fit an int32: in `free`, y ≤ 48·(n − 1).

**Worker command.** `RepoHandle.graphLayout(revset, anchors, utcOffsetMin, …)` re-runs the
topology call on every request (ADR-0002; timestamps iff `free`), builds the input and lays it out
in the worker, and replies with the topology and the grid as two `TransferableTypedData` (one
copy each). A contract violation crosses as the `LayoutContractException` itself, after the
topology, whose own errors (and its precondition and warnings) reach the caller first.

*Amended 2026-10-01, Story 4.13: stacks (§4.8).*
- **Engine.** `stacks.dart` joins the engine core (same imports rule). `computeGraphGrid` takes an
  optional `StackInput` (`layout_input.dart`): per node `immutable`, `parentCount`, `hasRef` and a
  `workingCopy` code (0 none, 1 another workspace's, 2 this workspace's `@`), plus the request as
  three node-index lists (`expandedNodes`, `collapsedNodes`, `keepOpenNodes`); the engine never
  sees a key. It validates V1–V4, then V5 (§2, amended: four fact arrays of length n, codes 0–2
  with at most one 2, `parentCount` ≥ 0, every request index in [0, n)), throwing
  `LayoutContractException('V5', …)` before anything is laid out; it runs §4.8 after the lane
  order. Without a `StackInput` it is 4.11's engine, byte for byte, grid format version 1 included.
- **Input builder** (`buildStackInput`): the facts from the topology — `immutable` from its
  immutable flag, `parentCount` from `parent_count`, `hasRef` iff a bookmark entry (local or
  remote) or a tag points at the node, `workingCopy` 2 for this workspace's `@` (its flag), else
  1 if any other workspace's working copy is the node, else 0. Request keys resolve by Story 10.1's
  key rule through the topology's id lookups: a key that is a change id names its one node that is
  neither hidden nor divergent; a key that is a commit id names its node only when that node is
  hidden or divergent; anything else is dropped.
- **Result.** With stacks the grid is format version 2: version 1's header and twelve arrays (the
  node arrays with n + S entries, −1 for a hidden member; edges and buckets of the grouped layout),
  then header slots 33–45 — S, R (runs), M (members), and the byte offset and count of five more
  arrays: node run (int32 × n, the run index or −1), run state (uint8 × R; 0 expanded, 1
  collapsed), run node (int32 × R; the stack node or −1), run start (int32 × R + 1) and run members
  (int32 × M, oldest first). The header is 184 bytes; every array starts 8-aligned after it.
  `GraphGridView` reads both versions; its doc comment is the contract. With stack nodes the index
  order is no topological order: an edge into a stack node has a parent index below its child's
  (p < n ≤ s).
- **Request.** `RepoHandle.graphLayout` gains `stacks` (default `false`) and the key lists
  `expandedKeys`, `collapsedKeys` and `keepOpenKeys` (default empty); with `stacks` false the lists
  are ignored and the result is 4.11's.

*Amended 2026-10-27, Story 4.14: joint columns.*
- **Engine.** The product engine always lays out joint columns (§4.3 / §4.7, amended): it lays out
  both vertical models in every request, packs once for both, runs the lane order on that packing
  and outputs the requested mode's rows, routes, `blocked` and buckets with lane, col and `lanes`
  identical in both modes (I8). Its §3 output is the spike's Dart reference with `--columns joint`,
  byte for byte; the goldens all come from that binary (`tools/goldens.mjs`), and
  `tools/compare.mjs --core <binary>` compares the product CLI with it for both orders. The input
  builder's "which the request loads iff the mode is `free`" and the worker command's "timestamps
  iff `free`" above no longer hold: see the worker below.
- **Day key.** Every node's dk (§4.2 free step 4, amended) is computed in both modes from the free
  model's clamped T; the root's is `GraphGridView.noDay` (−2^63); with stacks a stack node has
  dk(m_k) and a hidden member its own.
- **Result.** Grid format version **3** (without stacks) = version 1's header and twelve arrays
  plus a thirteenth, node day (int64 × n), in a 35-slot header (140 bytes; the arrays start at byte
  144); version **4** (with stacks) = version 3's 35 slots and thirteen arrays (node day int64 ×
  (n + S)) plus S, R and M at slots 35–37 and the five stack arrays at slots 38–47 (48 slots, 192
  bytes). `GraphGridView` reads only versions 3 and 4 (`formatVersion` 3, `stackFormatVersion` 4)
  and exposes `nodeDays`; versions 1 and 2 are retired (no grid is ever persisted) and refused like
  any other version.
- **Worker command.** `RepoHandle.graphLayout` loads the committer timestamps for **every**
  request (both models are laid out, and every node has a day key); `utc_offset_min` is read in
  both modes. `compact` therefore pays the timestamp load too (Story 4.10: ~59 ms packed, ~1.24 s
  loose at 10k).

*Amended 2026-10-31, Story 4.16: the day band.* Being always joint, the product engine always
applies `free`'s day step (§4.2 free.3, amended; `freeStep` in `layout_engine.dart`, used by the
walk and by §4.8's (F)), in both request modes, byte for byte with the spike's `--columns joint`.
I5 (amended) holds on every product grid; D12.

*Amended 2026-11-10, Story 4.17: branch columns, per mode.*
- **Scope.** The modes `compact` and `free` (default `free`). There are no lane orders and no budget.
  The engine core no longer has `compact_order`. Rows are unchanged (§4.2, both models, the day keys
  in both modes, Story 4.16's day band), and timestamps are loaded for every request.
- **Columns.** `chooseColumns` (§4.3, Branch columns) runs on the requested mode's rows; `lane` =
  `col`. A stack toggle and "Group stacks" never move a column (I7).
- **Reference.** The reference for the columns is the lab (`spikes/graph-layout-lab`); the product's
  columns equal `chooseColumns` there, which `bin/lab_check.dart` checks. The spike's Rust and Dart
  references no longer match the product and stay as history; `tools/compare.mjs --core` no longer
  applies.
- **Goldens.** Written by `tools/goldens.mjs` from the product CLI
  (`packages/zanshin_core/benchmark/graph_layout_cli.dart`) over the committed inputs, one file per
  mode, `<input>.<mode>.json`. §3's canonical JSON has no `order` key.
- **Grid format.** Versions 3 and 4 stay. Header slot 2 holds 0 (`greedy`'s value), and
  `GraphGridView.fromBytes` refuses any other value; `GraphGridView.order` is gone.
- **Worker command.** `RepoHandle.graphLayout` has neither `order` nor `budget`.
- **CLI.** See §6 (amended 2026-11-10).

## 14. Routing (Story 4.15)

*(Added 2026-10-27.)* The painter's line geometry: router B of the floating-client export
`e74ced3` (`graph-layout.jsx` = GL; `routeLines` GL:148-299, the bridges GL:57-82), decision (a1).
One line per parent → child layout edge, with its own exit on the parent's top edge and its own
entry on the child's bottom edge; horizontal runs nest on tracks instead of crossing; a line whose
column is taken climbs a gutter between columns. It supersedes §4.5's symbolic geometry, D9 and
§12's planned exit. It is no layout output: the engine's `route`, `blocked`, grid and goldens are
unchanged, and the router does not read `route` or `blocked`.

*Amended 2026-11-10, Story 4.18: lines by the lab's rules.* The rules below are the graph layout
lab's (`labLines` in `spikes/graph-layout-lab/lib/lines.dart`, every switch on, Ralph 2026-11-10), with
the differences §14.6 lists. A line runs in its branch's column, turns into a gutter before a card in
its way, and sits on a level that passes no card. Router B's classes, gutter budget, unit rule and
hooks are gone. §14.2 and §14.3 are rewritten; the previous text is in git history. §14.4 is
unchanged. Where a sentence of §14 still names GL, the export is that sentence's origin.

### 14.1 Home and input

`packages/zanshin_core/lib/src/graph_layout/router.dart`, engine core (§13's import rule: only
`dart:typed_data`, `package:meta` and engine files; no isolate). Exported from
`lib/zanshin_core.dart` (`RouteClasses`, `RouteMetrics`, `RouteGeometry`, `RouteBridges`,
`routeSyncNodeLimit`; no other engine type).

Input = raw typed arrays as `GraphGridView` exposes them: per node row and col, U, per layout edge
from, to and kind (§3's order: by child, then the parent's position; a child's first edge is its
first parent, i = 0), plus the topology's `parentCount` per topology node (Story 4.10). A node with
row −1 (a hidden stack member) is skipped; an edge touching one is bad input. A node index ≥
`parentCount`'s length (a stack node) counts as not single-parent. Bad input — array lengths that
disagree, U ≤ 0, an edge index out of range or at a hidden node, a visible node with a negative
column — throws `ArgumentError`.

*Amended 2026-11-10, Story 4.18:* the input no longer names the mode (`free` is gone; the rules are
the same in both modes, in pixels). Doubled column positions are §14.3's.

### 14.2 Per-layout stage (per layout; units only)

*Rewritten 2026-11-10, Story 4.18: router B's kinds, gutter steps, unit rule and hooks are gone.*

`RouteClasses` keeps its name: a card-size change must not redo this stage, which a measurement
confirms (§14.5). It checks the input (§14.1) and holds:

- per column its visible nodes by row (`columnStarts`, `columnNodes`), so a column's card tops
  descend; per node its place in that list (`columnPos`), so a card's neighbours in its column are one
  step away;
- per node `goesOn`: a first-parent child sits in the node's column, so the node's branch goes on;
- per layout edge its entry slot, its `deep` flag and whether it is its child's first parent;
- the in- and out-edges per node.

**Shared entries.** An Indirect edge into a node with `parentCount` = 1 that has ≥ 2 Indirect
edges shares that node's one entry slot and is **deep**: all those edges go through the one hidden
parent. Every other edge has its own slot. (GL groups dashed edges by its own gap walk's `via`,
GL:212; jj reports no `via`.)

### 14.3 Geometry stage (per metrics)

*Rewritten 2026-11-10, Story 4.18, from `labLines` with every switch on.*

Metrics: W, H, gapX 56, gapY 48, pad 56; pitch = H + gapY, colW = W + gapX. y(i) = pad + (maxRow −
row(i)) / U · pitch, cx = pad + col(i)·colW + W / 2. Constants: lift = 0.4·gapY (how far a run sits
from the card it belongs to), clear = 8 (how far a run stays from any card), track = 6 (the distance
of runs of one fan and of lines in one gutter).

A **doubled column position** q is 2c for column c's centre and 2c + 1 for the gutter right of column
c. Until the ports are placed every x is such a position, and the rules compare positions as
integers. A gutter's x is pad + W/2 + q·colW/2, plus its slot's offset.

**Phases, in order.**
1. Positions: y and cx per node.
2. Shapes: per edge its shape and levels, and for some merge lines a detour.
3. Detours: taken where they save crossings, then for the column order.
4. Tracks: the runs of the final shapes get their levels.
5. Monotone levels.
6. Ports, from the final levels.
7. Gutter slots, from the final levels.
8. Polylines, run indexes, reports.

**Searches.** For one line, with ay the parent's top and by the child's bottom; its own two cards
never count.
- *blocker*(c, from, to): the first card of column c that a line climbing from y `from` meets; none if
  that card's bottom is at or above `to`.
- *under*: the next card below the child in the child's column.
- *seek*(c0…c1, wish, upper, lower, direction): a level between upper + clear and lower − clear at
  least clear from every card of the columns c0…c1, nearest to wish in `direction`, else nearest on
  the other side; none if neither has one.
- *band*(c0…c1, level, lo, hi): from the nearest card edge above the level to the nearest card edge
  below it over the columns c0…c1, no further than lo and hi.

Columns are read through `columnNodes` with a binary search (a column's tops descend), and own cards
are skipped by stepping to the neighbour.

**Shapes.** A line runs in its branch's column. above = ay − lift, below = by + lift.
- *Same column.* blocker(col, ay, by): none → 2 points. A card → 6 points through the gutter right of
  the column, the first run on T = card bottom + lift.
- *First parent, another column (fork).* The horizontal run sits right above the parent; it turns
  right above the parent and climbs the child's column. upper = the bottom of the parent column's
  next card if that lies below by, else by. The columns c0…c1 reach from next to the parent up to
  the child's column. L = seek(c0…c1, above, upper, ay, up), or above if there is none. card =
  blocker(col(child), L, by): none → 4 points; card bottom + lift > L → 6 points (the line cannot
  enter the child's column: gutter next to it, parent side); else 8 points (the line enters the child's
  column and dodges the card through that gutter).
- *Not the first parent, another column (merge).* card = blocker(col(parent), ay, below). upper = card
  bottom, or by without a card. lower = the smallest of under's top and ay. The columns c0…c1 lie
  strictly between the two columns. The line bends **at its parent** where `goesOn`(parent) holds and
  under is none or below the parent: L = seek(c0…c1, lower − lift, upper, lower, up); else at its
  child: L = seek(c0…c1, upper + lift, upper, lower, down). If L < below and blocker(col(parent), ay,
  L) exists, the line has no L. With L → 4 points. Without L and without card → 4 points on below.
  Without L and with card → 6 points through the gutter next to the parent's column, on the child's
  side.
- *Its detour.* A merge line whose parent's branch goes on and which does not bend at its parent:
  at = seek(c0…c1, ay − lift, upper, ay, up). If at exists and at − below ≥ H + gapY the line has a
  detour: it bends at the parent and climbs the gutter next to the child's column.

**Runs of a shape.** ax, bx the two columns, gx the gutter, xo, xi the ports. Every run takes part in
the tracks; `merge` decides where it wishes to sit.

| Points | Polyline | Runs from the parent's end: band | merge | down → up |
|---|---|---|---|---|
| 2 | (xo,ay)(xo,by) | none | — | — |
| 4, fork | (xo,ay)(xo,L)(xi,L)(xi,by) | L: band(c0…c1, L, upper, ay) | false | ax → bx |
| 4, merge at child | same | L: band(c0…c1, L, upper, lower) | true | ax → bx |
| 4, merge at parent | same | L: band(c0…c1, L, upper, lower) | false | ax → bx |
| 4, merge fallback | same | L = below: band(c0…c1, below, by, lower) | true | ax → bx |
| 6, same column or a card in the parent's column | (xo,ay)(xo,T)(gx,T)(gx,B)(xi,B)(xi,by) | T: [card bottom, ay]; B | true, true | ax → gx; gx → bx |
| 6, fork that cannot enter | (xo,ay)(xo,L)(gx,L)(gx,B)(xi,B)(xi,by) | L: as the fork's; B | false, true | ax → gx; gx → bx |
| 6, detour | (xo,ay)(xo,at)(gx,at)(gx,B)(xi,B)(xi,by) | at: band(c0…c1, at, upper, ay), its top at least below + clear; B | false, true | ax → gx; gx → bx |
| 8, fork that dodges | (xo,ay)(xo,L)(bx,L)(bx,T)(gx,T)(gx,B)(xi,B)(xi,by) | L: as the fork's; T: [card bottom, ay]; B | false, true, true | ax → bx; bx → gx; gx → bx |

B is the run below the child: level below, band(the columns strictly between the gutter and the child,
below, by, hi), with hi the smallest of under's top, the card's bottom when the shape has a blocking
card, and ay. T is card bottom + lift. A run's *wish* is lo + min(lift, (hi − lo)/2) for `merge`, hi −
min(lift, (hi − lo)/2) otherwise. A **deep** edge's `merge` run that ends at the child wishes max(lo +
(hi − lo)/2, min(hi, lo + gapY) − 12), so a shared stem keeps its length.

**Detours.** Two passes over the detours, in edge order, on the shapes before tracks and ports. First
a detour is taken if the line then crosses fewer other lines; on a tie the line keeps its usual
shape, which has two bends less. Then a detour is taken wherever a line of its parent's top edge to
the same side goes to a nearer column but turns nearer to the card, whatever the detour crosses;
that changes where it turns, so this pass repeats until nothing moves. Crossings are counted with an
index built once from the first shapes: per doubled position the sorted y's of the horizontal runs
that strictly pass it and the sorted tops and bottoms of the vertical runs on it. A query counts by
binary search, subtracts the line's own first shape and applies the taken detours (few) as an overlay.

**Tracks.** Two runs are one cluster, transitively, when their x-ranges overlap and the band of one
holds the level of the other (a sweep by band top with an active list). Within a cluster:
- *above*(a, b) for two runs of different lines: a spans b's parent end, or b spans a's child end, or
  a.up = b.down at a column centre (an even position; gutters are separated by slots, not by levels).
  Two runs of one line: the run nearer to the child lies above. Pairs with above in both directions
  are counted, `unavoidableCrossings`.
- *Order*: by wish, then edge and run order; repeatedly the first run that no other remaining run must
  lie above (of a pair that crosses either way, neither counts); in a cycle the first remaining run.
- *Siblings*: two runs in one direction of one parent or one child. *Meet*: x-ranges and bands
  overlap. *Share*: a run's band over the runs it meets that are not siblings, plus two, at most
  lift. *Tight*: track, or for a fan that does not fit (share + 6 px per earlier sibling exceeds the
  room from the lowest band top of the fan to the run's band bottom, less 2 px) room / members. Then
  share = min(tight, share), so two runs that are not of one fan keep at most 6 px.
- *Levels*: every run sits at max(wish, lo + share) or pushed below the earlier runs it meets; then,
  from the last run back, at most hi − share or pushed above the later runs it meets. A run never
  leaves its band (it stays 2 px inside a band wider than 4 px). Siblings keep min(tight), others
  min(share).

`tightFans` counts the fans with tight < 2, once per fan per cluster.

**Monotone levels.** Each line's levels are walked from the parent's end (level = min(level,
previous), starting at ay) and from the child's end (level = max(level, next), starting at by), so the
line climbs without retracing, whatever pushes did.

**Ports** (Story 10.30, top and bottom alike, by local direction since its follow-up of 2026-11-02):
only the stretch right at a card edge decides, whatever the line's shape. A line's *reach* at an edge is
the exact distance from the edge to the line's first bend there (2 points: infinite); it is *vertical*
there when reach ≥ gapY, else it *turns* there. A line's *side* is the x it turns toward: at the exit
the x of its third point (a 4-point line's usual target is its entry), at the entry the x of the point
before its last vertical (a gutter, or a 4-point line's parent's cx). Equal to cx counts as the right
side. One line sits at the centre; of several, the vertical line that stays straight longest does; with
none vertical the centre stays free. The rest fan to their side: vertical lines innermost (longest
first), then the turning lines by |side − cx| (entries: then the parent's row). At an entry the lines
are the slot owners.

*Column tie-break.* Two lines of different card edges never share an upright stretch at their card edges:
where the straight stretches (card edge to first bend, exactly) of two lines overlap on one x, the line that
stays straight longer keeps its port (tie: the lower edge index), the other leaves the centre or sits one
fan slot further out. Every line of a shared slot claims its own stretch and a loss moves the slot's owner,
so the slot moves as one; a slot with a 2-point line claims nothing at its entry, because that line's x is
the slot's port. Bans and extra slots only accumulate. The ports are placed again until stable (at most 8
passes, `_settlePasses`); the pairs still sharing an x after the last pass are counted,
`unsettledPorts`. A tie-break loser is the one case where a card edge's only line is not centred.

**Fans.** Slots as under Ports, at cx ± fan(m, 24, 16, 8, W/2 − 18), where fan(m, first, step, min, max)
= first + k·st with st = min(step, max(0, max − first)/(m − 1)) while st ≥ min, else first + min(k,
⌊span/min⌋)·min (the overflow shares the outermost port). Nine lines: 16 px apart at W 400, 9.75 at 240, 8
at 160 with the outer five on one exit. A node's ports are its distinct entry x's, in edge order.

**Gutter slots.** Per line through a gutter the interval between its two levels there. Sorted by
gutter, then top, then edge: a line takes the first slot free over its interval; slot s sits (s odd ?
+6 : −6)·⌈s/2⌉ px from the gutter's centre.

**Polylines.** 2, 4, 6 or 8 points, from the parent's top edge to the child's bottom edge; y never
rises along a line.

**Output** (typed arrays only): the polylines as a CSR (`pointStarts`, `points` as x, y pairs; the
points are the bends); per node its entry ports as a CSR (`portStarts`, `portXs`); the vertical
runs sorted by x and the horizontal runs sorted by y (zero-length segments dropped, ties in
polyline order); the reports:
- `behindCards` and `behindEdges`: the lines that still pass behind a card: a vertical run inside a
  card's x-range or a horizontal run across a card's y-range (inset 0.5 px), the card being neither end
  of the line.
- `sharedStretches` and `sharedEdges`: two lines that share a stretch of more than 1 px on one x or
  one y, not counting two lines of one slot or two lines on one port of one card edge.
- `tightFans`, `unavoidableCrossings` and `unsettledPorts`, as above.

*Limits.* The reports count only what they name. The order of a card edge's ports and "two lines of one
card do not cross" are checked, not counted: the gate holds them on every recording and `bin/lab_check.dart`
on the lab's repositories. On dense random graphs a line without a detour can break them (lab README, step
12); the fuzz test of `router_test.dart` pins how many.

### 14.4 Bridges (a per-window query)

`bridges(x0, y0, x1, y1)` returns every crossing whose point lies in [x0, x1) × [y0, y1), between
two edges, also two that share a node (since 2026-11-07, Ralph: a hook crossed its sibling's line
unbridged on `jj`; GL:62 skips such pairs), strict by 1 px: the vertical's x lies more than 1 px inside
the horizontal and the horizontal's y more than 1 px inside the vertical. Per crossing, with room =
the distance to the run's ends minus 6: the horizontal breaks 12 × 10 (x − 6, y − 5) unless its room
is < 12 and the vertical's room is larger, then the vertical breaks 10 × 12 (x − 5, y − 6)
(GL:74-82). The query takes the horizontals with y in range (binary search) and the verticals with
x in range that overlap the window's y-range, tests those pairs, and returns them by horizontal run
index, then vertical run index. No all-pairs pass; a crossing's result does not depend on the
window beyond the filter. A break reaches 6 px around its point, so a caller that paints tiles
grows each tile's window by 6 px on every side and drops crossings it already painted. Cost: the
verticals of the window's x-strip are scanned over the whole plane height (binary search on x
only), so a long linear history with many verticals at one x makes even a small window scan them
all (`shortcut:` in the code; the upgrade is per-x runs sorted by y).

### 14.5 Where it runs (item 4)

Both stages run on the UI side, never as a worker request: the per-layout stage once per layout (the
grid), the geometry stage per metrics (a card-size change re-runs only the geometry). The library
has no isolate dependency. The caller (Story 10.4) runs both synchronously for a layout of at most
`routeSyncNodeLimit` visible nodes and in `Isolate.run` above it. The limit is the largest n whose
measured per-layout + geometry time (AOT, warm) stays ≤ 8 ms, linear between the measured sizes (and
through the origin below the smallest one), rounded down to a thousand.

*Amended 2026-11-10, Story 4.18: new measurements and a new limit.* Measured 2026-11-10 (M4 Pro, W 240,
H 62): the slowest series is `free` on the synth inputs — 10.8 ms at 9,890 nodes, 54.2 ms at 49,442,
120.1 ms at 98,842 (`compact`: 9.9, 50.5, 108.0 ms; fixture-large-all 2.8 ms) — so
**`routeSyncNodeLimit` = 7,000** (it was 20,000 with router B, spec-4-15 § Measurements; spec-4-18 §
Measurements has every series). The geometry stage is the rule stage now, and the per-layout stage is
7–8 % of the sum on the synth inputs and 24 % on fixture-large-all: a card-size change keeps that share
and costs no layout request. The rules work on pixels (W scales x, H changes the room), so the stage split
stays by measurement. The limit counts nodes and assumes small clusters of runs (at most 17 on synth-100k):
the work inside a cluster is quadratic, so a fan of thousands of lines of one card takes longer than the
limit allows (the `shortcut:` of `_placeCluster` names the upgrade).

A 1200 × 800 bridge window at the plane's left edge, vertically centred, measured ≤ 42 µs on these
inputs (fixture-large-all, synth-10k / 50k / 100k); it is not bounded in general (§14.4).

### 14.6 Differences from the lab

*Rewritten 2026-11-10, Story 4.18: the router no longer follows GL (the list of differences from GL went
with router B and is in git history). The reference is `labLines`, every switch on.*

- Every run takes part in the tracks, also a turn into a gutter and a run right below a child; the lab
  keeps those on fixed levels. That removes the lab's last shared stretch (TWMS, Compact, without
  stacks; the two lines cross instead).
- *above*(a, b) counts a.up = b.down only at a column centre: gutters are separated by slots, not by
  levels. Two runs of one line: the run nearer to the child lies above.
- Deep runs of shared entries; the lab has no shared entries.
- Ports are the engine's rules (§14.3, Ports) fed by the final levels, with the full column tie-break:
  a loser at a fan slot moves one slot further out (the lab only moves a line off the centre). A
  2-point line's reach is infinite, so it never gives up its port to a line that bends.
- Gutter slots are chosen after the tracks, from the final levels.
- Monotone levels: the lab's pushes can leave a run below the previous one of its line.
- Reports: the lab's metrics live in the lab; the router reports `behindCards`, `sharedStretches`,
  `tightFans`, `unavoidableCrossings` and `unsettledPorts` (§14.3).
- Indexes replace the lab's scans (a column's cards, run clusters, detour crossings); the results are
  the lab's. Within a cluster the lab's all-pairs loops stay (`shortcut:` in the code; clusters are
  small).
- Crossings of two edges that share a node bridge too (§14.4), as before.
- A polyline has at most 8 points (a fork that dodges a card in its child's column). Consumers read
  the CSR, no fixed count.

