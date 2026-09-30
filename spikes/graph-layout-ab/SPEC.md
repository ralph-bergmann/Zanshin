# Graph-layout A/B — algorithm spec (v1, 2026-09-26)

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
| `utc_offset_min` | the viewer's fixed UTC offset for calendar days; `time` only (D7) |
| `nodes` | in jj log order: children before parents |
| `id` | hex commit id; for debugging only, the layout never reads it |
| `ts_ms` | committer timestamp in epoch ms; `null` for the root |
| `is_root` | true for the `root()` commit |
| `priority` | ordering class ≥ 0; need not be unique (ties fall to the index) |
| `parents` | jj's graph edges in stream order. `direct` and `indirect` carry `idx`, the target's node index; `missing` carries `idx: null` |

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
- `buckets`: filled in `time` only (otherwise `[]`), ascending by bucket key.
  - `kind` is one of `root`, `age`, `day`.
  - `value` is 0 for `root`, the ladder minutes 10…720 for `age`, and the local-midnight
    instant in epoch ms for `day`.
  - `start` / `end` are the bucket's first and last row.
  - Labels ("10m", "Yesterday", "Sep 23") are the painter's.

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
rule is unchanged.)*

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

In a row gap, branch-off buses sit at 0.4 of the gap above the lower card and merges at 0.6, so
the two never collide.

**Kept design defect (D9).** A blocked merge becomes a `branch_off` whose vertical runs up the
child's lane. It may pass behind that lane's cards, collinear with its chain.

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
- I6: in `free`, y never decreases in (T asc, i desc) order.

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

**Planned change: every edge leaves the parent's top at the centre.** Every edge already enters
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
