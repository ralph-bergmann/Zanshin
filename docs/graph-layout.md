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
   - Two days can share a y value (two unrelated commits less than a minute apart across a local
     midnight), so neighbouring ranges may meet: end of one = start of the next.

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
  continuation child.

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
  the rounds and the budget are unchanged; column 0 stays fixed; empty columns are dropped.
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
run is **split** iff col(m_1) ≠ col(m_k). That can happen only between m_1 and m_2: m_1 may continue
its parent's lane beside the parent's own merge reservation (§4.3 excepts only fp's own interval),
and then m_2, which may not, takes another lane; every later member continues its predecessor,
whose only child it is, so the chain m_2 … m_k shares one lane and lies there without a gap.

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
  consecutive u, v in W′: y′(v) ≥ y′(u) + X(v) − X(u).
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
  greedy's.

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
  edge climb the stack's column but gives it a gutter, so in Compact no line passes behind the lower
  card unless the gutter holds more than 9 lines (the reported `overfullGutters`, whose outer lines
  may reach into cards); the route report's Compact gate and a D11 hand case witness it. In Free a
  gutter route whose every gutter is blocked is the router's reported fallback (`fallbackEdges`) and
  may still pass behind a card.

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

## 14. Routing (Story 4.15)

*(Added 2026-10-27.)* The painter's line geometry: router B of the floating-client export
`e74ced3` (`graph-layout.jsx` = GL; `routeLines` GL:148-299, the bridges GL:57-82), decision (a1).
One line per parent → child layout edge, with its own exit on the parent's top edge and its own
entry on the child's bottom edge; horizontal runs nest on tracks instead of crossing; a line whose
column is taken climbs a gutter between columns. It supersedes §4.5's symbolic geometry, D9 and
§12's planned exit. It is no layout output: the engine's `route`, `blocked`, grid and goldens are
unchanged, and the router does not read `route` or `blocked`.

### 14.1 Home and input

`packages/zanshin_core/lib/src/graph_layout/router.dart`, engine core (§13's import rule: only
`dart:typed_data`, `package:meta` and engine files; no isolate). Exported from
`lib/zanshin_core.dart` (`RouteClasses`, `RouteMetrics`, `RouteGeometry`, `RouteBridges`,
`routeSyncNodeLimit`; no other engine type).

Input = raw typed arrays as `GraphGridView` exposes them: per node row and col, U, the mode (free
or not), per layout edge from, to and kind (§3's order: by child, then the parent's position; a
child's first edge is its first parent, i = 0), plus the topology's `parentCount` per topology node
(Story 4.10). A node with row −1 (a hidden stack member) is skipped; an edge touching one is bad
input. A node index ≥ `parentCount`'s length (a stack node) counts as not single-parent. Bad
input — array lengths that disagree, U ≤ 0, an edge index out of range or at a hidden node, a
visible node with a negative column — throws `ArgumentError`.

Notation: y(i) = row(i) in units (U per pitch; `free` U = 16, `compact` U = 1); a column is
**free** between rows a < b iff no visible node of that column has a < y < b (GL:160). Doubled
column positions: column c's centre is 2c, the gutter between c and c + 1 is 2c + 1.

### 14.2 Class stage (per layout; units only)

Per edge (p, i) with side s = sign(col(i) − col(p)) (GL:178-192):
- s = 0: `straight` iff i is the first parent and the column is free between y(p) and y(i), else
  `gutter`; s becomes 1 (the gutter on the right).
- first parent: `fork` iff col(i) is free between them, else `gutter`;
- non-first: `merge-adjacent` iff y(i) = y(p) + U, else `merge-up` iff col(p) is free, else
  `gutter`.

**Gutters.** Edge gutter j (j = 0 nearest the child) of an edge with k = |col(i) − col(p)| ≥ 1 is
2·col(i) − s·(2j + 1), j < k; with k = 0 the one gutter is 2·col(i) + 1. Its two runs: from the
parent to the gutter in the band above the parent, and from the gutter to the child in the band
below the child.

**Free detours, the unit rule** (`free` only; GL's pixel test GL:162-177, :186-190 replaced). A run
between doubled positions A and B is blocked iff a visible node in a column c with 2c strictly
between A and B sits 1–12 units above the parent (a run in the band above the parent: 1 ≤ y(o) −
y(p) ≤ 12) or 1–12 units below the child (a run in the band below the child: 1 ≤ y(i) − y(o) ≤ 12).
`fork` and `merge-adjacent` check their run above the parent, `merge-up` its run below the child.
If that run is blocked, or for every `gutter`, the edge takes the first gutter (from j = 0) whose
two runs are free; a `gutter` with none takes j = 0; a blocked direct kind with none stays direct
and is **reported** (`directFallbacks`). Both cases may pass behind a card and are flagged per
edge (`fallbackEdges`; the count covers the direct kinds only). In `compact` nothing is blocked and a `gutter` takes j = 0.
The end columns need no check: nodes of one column are ≥ one pitch apart (I2), and `fork` /
`merge-up` need their column free.

*Derivation (why 12).* GL blocks a run when the band's inner part [band + 12, band − 12] has no room
left after removing each card's [y − 10, y + H + 10] over the run's x-range. A card d units above
the parent (pitch P = H + 48) leaves room below it iff d·P/16 ≥ H + 22 and above it iff
d·P/16 ≤ 26, so GL blocks d ∈ 4 … 12 at H 62 and d ∈ 5 … 11 at H 40. The unit rule blocks 1 … 12:
it detours more for d ∈ 1 … 3 (H 62) and d ∈ 1 … 4 and 12 (H 40), and never runs direct where GL
blocks: cards at d ≤ 0 reach no higher than the band's inner bottom, and cards at d ≥ 13 leave
GL's room just above it, so GL can only block when some card sits at 1 … 12. That last step holds
while a card 13 units off clears the band, 13·(H + gapY)/16 ≥ H + 22, i.e. H ≤ (13·gapY − 352)/3
(≈ 90 px at gapY 48); with taller cards a direct run may pass a card 13 units off.

**Gutter steps.** Lines on one gutter, counted in edge order, step 0, +6, −6, +12, −12, … px
(k-th line: (k odd ? +6 : −6)·⌈k/2⌉; GL:193-197). A gutter with more than 9 lines is **reported**
(`overfullGutters`): its outer lines may reach into the neighbouring cards.

**Shared entries.** An Indirect edge into a node with `parentCount` = 1 that has ≥ 2 Indirect
edges shares that node's one entry slot and is **deep** (its cluster sits as far from the child
as it can, GL:117): all those edges go through the one hidden parent. Every other edge has its own
slot. (GL groups dashed edges by its own gap walk's `via`, GL:212; jj reports no `via`.)

Output, per edge: kind, side, gutter (doubled position) and step, slot (the slot's first edge),
deep, first parent; per column its visible nodes by row; the two reports (counts, and per edge
whether the unit rule left it no free route).

### 14.3 Geometry stage (per metrics)

Metrics: W, H, gapX 56, gapY 48, pad 56; pitch = H + gapY, colW = W + gapX. Doubles, the same
formulas and evaluation order as GL. x(i) = pad + col(i)·colW, y(i) = pad + (maxRow − row(i)) / U ·
pitch, cx = x + W / 2. Gutter x: n.cx − s·colW·(j + 0.5) (k ≥ 1) or n.cx + colW / 2 (k = 0), plus
its step.

**Entries** (GL:206-221). The first parent's slot sits at the child's centre. The other slots, per
side of the centre by their approach (the gutter x for a `gutter`, else the parent's cx; an approach
equal to cx counts as the right side), ordered by |approach − cx| then the parent's row, sit at
cx ± fan(m, 24, 16, 8, W/2 − 18), where fan(m, first, step, min, max) = first + k·st with
st = min(step, max(0, max − first)/(m − 1)) while st ≥ min, else first + min(k, ⌊span/min⌋)·min
(the overflow shares the outermost port). A node's ports are its distinct entry x's, in edge order.

**Exits** (GL:222-250; variant B only). A `straight` line leaves at the centre. Per side, the other
lines — `merge-up` first (child row descending, then |entry − cx|), then the rest by |turn − cx|
(turn = the gutter x, else the entry) — sit at cx ± exitFan(m): one line at
max(18, min(0.28·W, W/2 − 18)); m lines st = min(12, (W/2 − 36)/(m − 1)) apart, centred on 0.28·W
inside [18, W/2 − 18] while st ≥ 7, else fan(m, 18, 12, 7, W/2 − 18). Nine lines: 12 px apart at
W 400, 10.5 at 240, 7 at 160 with the outer three on one exit.

**Runs and tracks** (GL:251-290). Bands: above the parent [y(p) − gapY, y(p)], below the child
[y(i) + H, y(i) + H + gapY]. Runs: `merge-up` one below the child (exit → entry); `gutter` one above
the parent (exit → gutter) and one below the child (gutter → entry, deep if the edge is); `fork` /
`merge-adjacent` one above the parent (exit → entry; deep only for a deep `merge-adjacent`). A run's
room is its band's inner part [band + 12, band − 12], in `free` minus every card [y − 10, y + H + 10]
whose x-range [x, x + W] comes within 4 px of the run's; the run's free part is the room's interval
nearest the band's middle (the middle itself if none). Runs whose bands overlap and whose x-ranges
come within 10 px are one cluster (transitively). Per cluster GL's `assignTracks` (a run must lie
above another if it spans that one's down-x, or that one spans its up-x; mutual pairs are dropped
and **counted**, `unavoidableCrossings`; a topological order by open predecessors then length;
first free track) and `placeTracks` (3.5–6 px apart, 24/(count − 1) clamped, retried at 3.5, each
track inside its free part, the block at the free part's middle, or as far from the child as it can
when the cluster holds a deep run). An overfull cluster keeps its order and spacing, centred on the
mean middle of its runs' free parts, and is **reported** (`overfullClusters`).

**Polylines** (GL:291-297). `straight`: 2 points; `gutter`: 6 points (exit, track above the parent,
gutter, track below the child, entry); the other kinds: 4 points. Each starts on the parent's top
edge and ends on the child's bottom edge.

**Output** (typed arrays only): the polylines as a CSR (`pointStarts`, `points` as x, y pairs; the
points are the bends); per node its entry ports as a CSR (`portStarts`, `portXs`); the vertical
runs sorted by x and the horizontal runs sorted by y (zero-length segments dropped, ties in
polyline order); the reports (`overfullClusters` with a per-edge flag, `unavoidableCrossings`).

### 14.4 Bridges (a per-window query)

`bridges(x0, y0, x1, y1)` returns every crossing whose point lies in [x0, x1) × [y0, y1), between
two edges that share no node (GL:62), strict by 1 px: the vertical's x lies more than 1 px inside
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

Both stages run on the UI side, never as a worker request: the class stage once per layout (the
grid), the geometry stage per metrics (a card-size change re-runs only the geometry). The library
has no isolate dependency. The caller (Story 10.4) runs both synchronously for a layout of at most
`routeSyncNodeLimit` visible nodes and in `Isolate.run` above it. The limit is the largest n whose
measured class + geometry time (AOT, warm) stays ≤ 8 ms, linear between the measured sizes, rounded
down to a thousand (spec-4-15 § Measurements). Measured 2026-10-27 (M4 Pro, W 240): the slowest
series is `free` on the synth inputs — 3.8 ms at 9,890 nodes, 19.5 ms at 49,442, 40.7 ms at 98,842
(`compact`: 2.4, 15.3, 27.9 ms; fixture-large-all 1.5 ms) — so **`routeSyncNodeLimit` = 20,000**.
A 1200 × 800 bridge window at the plane's left edge, vertically centred, measured ≤ 20 µs on these
inputs (fixture-medium/large `all()`, synth-10k / 50k / 100k); it is not bounded in general (§14.4).

### 14.6 Differences from GL

- Free detours use the unit rule (§14.2), not GL's pixel test.
- Shared entries group by `parentCount` = 1, not by GL's `via`.
- Variant B only: no bus (variant C), no `routeLegacy` (A), no gap markers or end stubs (Story
  10.19), no rounded corners, dashes or styles (Story 10.4).
- An entry approach exactly at the child's centre (GL: on neither side, no port) counts as the
  right side.
- Clusters, room and bridges are computed with indexes instead of GL's all-pairs loops; the results
  are GL's.
