//! The layout phases of SPEC §4.1–§4.5 (graph prep, layering, lane packing, blocked,
//! routing). Lane order (§4.6) lives in [`crate::order`].

use std::cmp::{max, min};

use crate::input::{Input, Kind};
use crate::order;

/// Vertical model (SPEC §0).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Longest-path depth rows.
    Compact,
    /// The design's age/day bucket rows plus the topological clamp (D1).
    Time,
    /// Continuous, compressed commit time (D8).
    Free,
}

impl Mode {
    /// Parses a CLI flag value.
    #[must_use]
    pub fn parse(s: &str) -> Option<Mode> {
        match s {
            "compact" => Some(Mode::Compact),
            "time" => Some(Mode::Time),
            "free" => Some(Mode::Free),
            _ => None,
        }
    }

    /// The canonical string.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Compact => "compact",
            Mode::Time => "time",
            Mode::Free => "free",
        }
    }

    /// U, the units per row pitch.
    #[must_use]
    pub fn unit(self) -> i64 {
        match self {
            Mode::Compact | Mode::Time => 1,
            Mode::Free => 16,
        }
    }
}

/// Lane order (SPEC §4.6).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Order {
    /// π = identity.
    Greedy,
    /// Windowed sifting on 400·X + 4·Len + Disp.
    Optimized,
}

impl Order {
    /// Parses a CLI flag value.
    #[must_use]
    pub fn parse(s: &str) -> Option<Order> {
        match s {
            "greedy" => Some(Order::Greedy),
            "optimized" => Some(Order::Optimized),
            _ => None,
        }
    }

    /// The canonical string.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Order::Greedy => "greedy",
            Order::Optimized => "optimized",
        }
    }
}

/// Edge route class (SPEC §4.5).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
    /// Same lane: a first-parent continuation.
    Straight,
    /// A non-first parent in another lane, not blocked.
    Merge,
    /// A first parent in another lane, or a blocked merge (D9).
    BranchOff,
}

impl Route {
    /// The canonical string.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Route::Straight => "straight",
            Route::Merge => "merge",
            Route::BranchOff => "branch_off",
        }
    }

    /// The digest code r (SPEC §8.4).
    #[must_use]
    pub fn code(self) -> i64 {
        match self {
            Route::Straight => 0,
            Route::Merge => 1,
            Route::BranchOff => 2,
        }
    }
}

/// Time bucket kind (SPEC §3).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BucketKind {
    /// The root / null-timestamp sentinel bucket.
    Root,
    /// A ladder bucket (10m … 12h).
    Age,
    /// A calendar day at the fixed UTC offset (D7).
    Day,
}

impl BucketKind {
    /// The canonical string.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            BucketKind::Root => "root",
            BucketKind::Age => "age",
            BucketKind::Day => "day",
        }
    }
}

/// One time bucket: its kind, value and row range (`time`; `free` emits `day` buckets only,
/// with y ranges in 1/U pitch units, amended 2026-10-01).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Bucket {
    /// Kind.
    pub kind: BucketKind,
    /// 0 for root, ladder minutes for age, local-midnight epoch ms for day.
    pub value: i64,
    /// First row.
    pub start: i64,
    /// Last row.
    pub end: i64,
}

/// §4.1 graph prep: layout parents (CSR), first parents, children (CSR).
#[derive(Debug, Default)]
pub struct Graph {
    /// CSR offsets of LP, length n + 1. Layout edge `e` of child `i` is `lp_off[i] <= e < lp_off[i+1]`,
    /// which is exactly the output edge order (§3).
    pub lp_off: Vec<u32>,
    /// Layout parent (edge source) per layout edge.
    pub lp: Vec<u32>,
    /// Edge kind (direct / indirect) per layout edge.
    pub lp_kind: Vec<Kind>,
    /// fp(i), or -1.
    pub fp: Vec<i32>,
    /// CSR offsets of C, length n + 1.
    pub ch_off: Vec<u32>,
    /// Children, ascending per parent.
    pub ch: Vec<u32>,
    /// pos(parent, child) per child entry.
    pub ch_pos: Vec<u32>,
}

impl Graph {
    /// Number of nodes.
    #[must_use]
    pub fn len(&self) -> usize {
        self.fp.len()
    }

    /// True when there are no nodes.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.fp.is_empty()
    }

    /// Number of layout edges E.
    #[must_use]
    pub fn edge_count(&self) -> usize {
        self.lp.len()
    }

    #[inline]
    fn parents(&self, i: usize) -> &[u32] {
        &self.lp[self.lp_off[i] as usize..self.lp_off[i + 1] as usize]
    }
}

/// Builds LP, fp and C (SPEC §4.1).
#[must_use]
pub fn prep(input: &Input) -> Graph {
    let n = input.len();
    let mut lp_off = Vec::with_capacity(n + 1);
    let mut lp = Vec::with_capacity(input.par_idx.len());
    let mut lp_kind = Vec::with_capacity(input.par_idx.len());
    let mut fp = vec![-1i32; n];
    let mut ch_count = vec![0u32; n + 1];
    lp_off.push(0u32);
    for i in 0..n {
        let first = lp.len();
        for k in input.par_off[i] as usize..input.par_off[i + 1] as usize {
            let p = input.par_idx[k];
            if p < 0 {
                continue;
            }
            if lp.len() == first {
                fp[i] = p;
            }
            lp.push(p as u32);
            lp_kind.push(input.par_kind[k]);
            ch_count[p as usize + 1] += 1;
        }
        lp_off.push(lp.len() as u32);
    }
    // Prefix sums → C offsets; filling by scanning i ascending keeps each C(j) ascending.
    for j in 0..n {
        ch_count[j + 1] += ch_count[j];
    }
    let ch_off = ch_count;
    let mut cursor: Vec<u32> = ch_off[..n].to_vec();
    let mut ch = vec![0u32; lp.len()];
    let mut ch_pos = vec![0u32; lp.len()];
    for i in 0..n {
        let start = lp_off[i] as usize;
        for e in start..lp_off[i + 1] as usize {
            let p = lp[e] as usize;
            let slot = cursor[p] as usize;
            ch[slot] = i as u32;
            ch_pos[slot] = (e - start) as u32;
            cursor[p] += 1;
        }
    }
    Graph {
        lp_off,
        lp,
        lp_kind,
        fp,
        ch_off,
        ch,
        ch_pos,
    }
}

/// §4.2 result: y(i) per node, U, and the time buckets.
#[derive(Debug, Default)]
pub struct Rows {
    /// U.
    pub unit: i64,
    /// y(i) (rows, or 1/U pitch units in `free`).
    pub y: Vec<i64>,
    /// `time` buckets and `free` day buckets (amended 2026-10-01), ascending by key; empty in
    /// `compact`.
    pub buckets: Vec<Bucket>,
}

const MINUTE_MS: i64 = 60_000;
const DAY_MS: i64 = 86_400_000;
const LADDER_MIN: [i64; 8] = [10, 20, 40, 60, 120, 240, 480, 720];
/// The ROOT bucket key: below every other key (all real keys are ≥ −2^53 − 1 day).
const ROOT_KEY: i64 = i64::MIN;

/// Bucket key b(i) (SPEC §4.2 time, step 1).
#[must_use]
pub fn bucket_key(ts: Option<i64>, is_root: bool, now_ms: i64, utc_offset_min: i64) -> i64 {
    let Some(ts) = ts.filter(|_| !is_root) else {
        return ROOT_KEY;
    };
    let age = now_ms - ts;
    for m in LADDER_MIN {
        if age <= m * MINUTE_MS {
            return now_ms - m * MINUTE_MS;
        }
    }
    day_key(ts, utc_offset_min)
}

/// The local-midnight instant (epoch ms) of the calendar day holding `t` at the fixed offset
/// (D7): `((t + off) div 86400000)·86400000 − off`. Shared by `time` (step 1) and `free`'s day
/// buckets (step 4), which must not go through [`bucket_key`]'s `now_ms` ladder.
#[must_use]
pub fn day_key(t: i64, utc_offset_min: i64) -> i64 {
    let off = utc_offset_min * MINUTE_MS;
    (t + off).div_euclid(DAY_MS) * DAY_MS - off
}

/// The bucket a key stands for: keys map 1:1 to buckets and the kind follows from the key.
#[must_use]
pub fn bucket_of_key(key: i64, now_ms: i64) -> (BucketKind, i64) {
    if key == ROOT_KEY {
        (BucketKind::Root, 0)
    } else if key >= now_ms - LADDER_MIN[LADDER_MIN.len() - 1] * MINUTE_MS {
        (BucketKind::Age, (now_ms - key) / MINUTE_MS)
    } else {
        (BucketKind::Day, key)
    }
}

/// L2(x): piecewise-linear fixed-point log2, ×256 (x ≥ 1).
#[must_use]
pub fn l2(x: i64) -> i64 {
    debug_assert!(x >= 1);
    let k = i64::from(63 - x.leading_zeros());
    256 * k + ((x - (1i64 << k)) * 256).div_euclid(1i64 << k)
}

/// gap(g) in units (16 = one pitch), for elapsed ms g ≥ 0 (SPEC §4.2 free).
#[must_use]
pub fn gap(g: i64) -> i64 {
    min(48, (2 * l2(1 + g.div_euclid(MINUTE_MS))).div_euclid(256))
}

/// §4.2 layering → y(i).
#[must_use]
pub fn layering(input: &Input, g: &Graph, mode: Mode) -> Rows {
    match mode {
        Mode::Compact => layer_compact(g),
        Mode::Time => layer_time(input, g),
        Mode::Free => layer_free(input, g),
    }
}

fn layer_compact(g: &Graph) -> Rows {
    let n = g.len();
    let mut y = vec![0i64; n];
    for i in (0..n).rev() {
        let mut yi = 0;
        for &p in g.parents(i) {
            yi = max(yi, y[p as usize] + 1);
        }
        y[i] = yi;
    }
    Rows {
        unit: 1,
        y,
        buckets: Vec::new(),
    }
}

fn layer_time(input: &Input, g: &Graph) -> Rows {
    let n = g.len();
    // Steps 1 + 2: bucket key and topological clamp, parents first.
    let mut eb = vec![0i64; n];
    for i in (0..n).rev() {
        let ts = if input.has_ts[i] { Some(input.ts[i]) } else { None };
        let mut k = bucket_key(ts, input.is_root[i], input.now_ms, input.utc_offset_min);
        for &p in g.parents(i) {
            k = max(k, eb[p as usize]);
        }
        eb[i] = k;
    }
    // Step 3: the distinct keys ascending are the buckets (sort + dedup) …
    let mut keys = eb.clone();
    keys.sort_unstable();
    keys.dedup();
    // … with their members in descending index (parents first): a counting sort over bucket ids.
    let mut bucket_of = vec![0u32; n];
    let mut member_off = vec![0u32; keys.len() + 1];
    for i in 0..n {
        let b = keys.partition_point(|&k| k < eb[i]);
        bucket_of[i] = b as u32;
        member_off[b + 1] += 1;
    }
    for b in 0..keys.len() {
        member_off[b + 1] += member_off[b];
    }
    let mut cursor: Vec<u32> = member_off[..keys.len()].to_vec();
    let mut members = vec![0u32; n];
    for i in (0..n).rev() {
        let b = bucket_of[i] as usize;
        members[cursor[b] as usize] = i as u32;
        cursor[b] += 1;
    }
    let mut y = vec![0i64; n];
    let mut buckets = Vec::with_capacity(keys.len());
    let mut next = 0i64;
    for (b, &key) in keys.iter().enumerate() {
        let start = next;
        let mut end = start;
        for &i in &members[member_off[b] as usize..member_off[b + 1] as usize] {
            let i = i as usize;
            let mut yi = start;
            for &p in g.parents(i) {
                yi = max(yi, y[p as usize] + 1);
            }
            y[i] = yi;
            end = max(end, yi);
        }
        let (kind, value) = bucket_of_key(key, input.now_ms);
        buckets.push(Bucket {
            kind,
            value,
            start,
            end,
        });
        next = end + 1;
    }
    Rows { unit: 1, y, buckets }
}

fn layer_free(input: &Input, g: &Graph) -> Rows {
    const U: i64 = 16;
    let n = g.len();
    // Step 1: tmin over every non-null ts (is_root nodes included; see SPEC_NOTES_RUST.md).
    let tmin = (0..n)
        .filter(|&i| input.has_ts[i])
        .map(|i| input.ts[i])
        .min()
        .unwrap_or(0);
    // Step 2: clamp, parents first.
    let mut t = vec![0i64; n];
    for i in (0..n).rev() {
        let mut ti = if input.is_root[i] || !input.has_ts[i] {
            tmin
        } else {
            input.ts[i]
        };
        for &p in g.parents(i) {
            ti = max(ti, t[p as usize]);
        }
        t[i] = ti;
    }
    // Step 3: walk by (T asc, i desc).
    let mut ord: Vec<u32> = (0..n as u32).collect();
    ord.sort_unstable_by(|&a, &b| t[a as usize].cmp(&t[b as usize]).then(b.cmp(&a)));
    let mut y = vec![0i64; n];
    let mut prev: Option<usize> = None;
    for &i in &ord {
        let i = i as usize;
        let mut yi = match prev {
            None => 0,
            Some(v) => y[v] + gap(t[i] - t[v]),
        };
        for &p in g.parents(i) {
            yi = max(yi, y[p as usize] + U);
        }
        y[i] = yi;
        prev = Some(i);
    }
    let buckets = free_day_buckets(input, &ord, &t, &y);
    Rows { unit: U, y, buckets }
}

/// Step 4 of SPEC §4.2 free (amended 2026-10-01): one `day` bucket per local day of the clamped
/// T of every non-root node. T and y never decrease in the walk order `ord`, so the members of a
/// bucket are consecutive there (roots skipped) and one pass emits the buckets ascending.
fn free_day_buckets(input: &Input, ord: &[u32], t: &[i64], y: &[i64]) -> Vec<Bucket> {
    let mut buckets: Vec<Bucket> = Vec::new();
    for &i in ord {
        let i = i as usize;
        if input.is_root[i] {
            continue;
        }
        let key = day_key(t[i], input.utc_offset_min);
        match buckets.last_mut() {
            Some(b) if b.value == key => b.end = y[i],
            _ => buckets.push(Bucket {
                kind: BucketKind::Day,
                value: key,
                start: y[i],
                end: y[i],
            }),
        }
    }
    buckets
}

/// §4.3 result: lane per node, lane count, and each lane's y-list (CSR, ascending).
#[derive(Debug, Default)]
pub struct Lanes {
    /// lane(i).
    pub lane: Vec<u32>,
    /// L = max lane + 1 (0 when n = 0).
    pub count: usize,
    /// CSR offsets of the per-lane y-lists, length L + 1.
    pub lane_off: Vec<u32>,
    /// y values per lane, ascending.
    pub lane_ys: Vec<i64>,
}

/// A min segment tree over lane indices holding each lane's largest b′ (unused: −∞).
struct FirstFit {
    size: usize,
    tree: Vec<i64>,
}

impl FirstFit {
    fn new(lanes: usize) -> Self {
        let size = lanes.max(1).next_power_of_two();
        FirstFit {
            size,
            tree: vec![i64::MIN; 2 * size],
        }
    }

    fn set(&mut self, lane: usize, max_b: i64) {
        let mut p = self.size + lane;
        self.tree[p] = max_b;
        while p > 1 {
            p /= 2;
            self.tree[p] = min(self.tree[2 * p], self.tree[2 * p + 1]);
        }
    }

    /// The least lane whose largest b′ ≤ a.
    fn first_fit(&self, a: i64) -> usize {
        debug_assert!(self.tree[1] <= a, "an unused lane always fits");
        let mut p = 1;
        while p < self.size {
            p = if self.tree[2 * p] <= a { 2 * p } else { 2 * p + 1 };
        }
        p - self.size
    }
}

/// §4.3 lane packing, O(n log n).
#[must_use]
pub fn lanes(input: &Input, g: &Graph, rows: &Rows) -> Lanes {
    let n = g.len();
    let u = rows.unit;
    let y = &rows.y;
    let pr = &input.priority;
    // cont(j): the child with fp = j and the least key (priority, i).
    let mut cont = vec![-1i32; n];
    for i in 0..n {
        let f = g.fp[i];
        if f >= 0 {
            let c = cont[f as usize];
            if c < 0 || (pr[i], i) < (pr[c as usize], c as usize) {
                cont[f as usize] = i as i32;
            }
        }
    }
    // Visit order (y, priority, i).
    let mut ord: Vec<u32> = (0..n as u32).collect();
    ord.sort_unstable_by(|&a, &b| {
        let (a, b) = (a as usize, b as usize);
        y[a].cmp(&y[b]).then(pr[a].cmp(&pr[b])).then(a.cmp(&b))
    });
    // Per lane: largest b′ with its owner, and second-largest b′.
    let mut top1_b = vec![i64::MIN; n];
    let mut top1_owner = vec![-1i32; n];
    let mut top2_b = vec![i64::MIN; n];
    let mut free = FirstFit::new(n);
    let mut lane = vec![0u32; n];
    let mut count = 0usize;
    for &i in &ord {
        let i = i as usize;
        let yi = y[i];
        let mut ey: Option<i64> = None;
        let c = cont[i];
        if c >= 0 {
            ey = Some(y[c as usize]);
        }
        for k in g.ch_off[i] as usize..g.ch_off[i + 1] as usize {
            if g.ch_pos[k] >= 1 {
                let yc = y[g.ch[k] as usize];
                ey = Some(ey.map_or(yc, |e| max(e, yc)));
            }
        }
        let end = ey.map_or(yi, |e| max(yi, e - u));
        let f = g.fp[i];
        let a = if f >= 0 { y[f as usize] + u } else { yi };
        let b = end + 2 * u;
        let mut chosen: Option<usize> = None;
        if f >= 0 && cont[f as usize] == i as i32 {
            let fl = lane[f as usize] as usize;
            let max_b = if top1_owner[fl] == f { top2_b[fl] } else { top1_b[fl] };
            if max_b <= a {
                chosen = Some(fl);
            }
        }
        let l = chosen.unwrap_or_else(|| free.first_fit(a));
        if b > top1_b[l] {
            top2_b[l] = top1_b[l];
            top1_b[l] = b;
            top1_owner[l] = i as i32;
            free.set(l, b);
        } else if b > top2_b[l] {
            top2_b[l] = b;
        }
        lane[i] = l as u32;
        count = max(count, l + 1);
    }
    // Per-lane y-lists: a counting sort of the (y-ascending) visit order by lane.
    let mut lane_off = vec![0u32; count + 1];
    for &l in &lane {
        lane_off[l as usize + 1] += 1;
    }
    for l in 0..count {
        lane_off[l + 1] += lane_off[l];
    }
    let mut cursor: Vec<u32> = lane_off[..count].to_vec();
    let mut lane_ys = vec![0i64; n];
    for &i in &ord {
        let l = lane[i as usize] as usize;
        lane_ys[cursor[l] as usize] = y[i as usize];
        cursor[l] += 1;
    }
    Lanes {
        lane,
        count,
        lane_off,
        lane_ys,
    }
}

/// §4.4 blocked per layout edge (output edge order), O(E log n).
#[must_use]
pub fn blocked(g: &Graph, rows: &Rows, lanes: &Lanes) -> Vec<bool> {
    let y = &rows.y;
    let mut out = Vec::with_capacity(g.edge_count());
    for i in 0..g.len() {
        for &p in g.parents(i) {
            let p = p as usize;
            let lp = lanes.lane[p] as usize;
            if lanes.lane[i] as usize == lp {
                out.push(false);
                continue;
            }
            let ys = &lanes.lane_ys[lanes.lane_off[lp] as usize..lanes.lane_off[lp + 1] as usize];
            let k = ys.partition_point(|&v| v <= y[p]);
            out.push(k < ys.len() && ys[k] <= y[i]);
        }
    }
    out
}

/// §4.5 route per layout edge (output edge order).
#[must_use]
pub fn routing(g: &Graph, lanes: &Lanes, blocked: &[bool]) -> Vec<Route> {
    let mut out = Vec::with_capacity(g.edge_count());
    for i in 0..g.len() {
        let start = g.lp_off[i] as usize;
        for e in start..g.lp_off[i + 1] as usize {
            let p = g.lp[e] as usize;
            out.push(if lanes.lane[p] == lanes.lane[i] {
                Route::Straight
            } else if e > start && !blocked[e] {
                Route::Merge
            } else {
                Route::BranchOff
            });
        }
    }
    out
}

/// The complete layout result.
#[derive(Debug)]
pub struct Layout {
    /// Echoed mode.
    pub mode: Mode,
    /// Echoed order.
    pub order: Order,
    /// Graph prep.
    pub graph: Graph,
    /// Layering.
    pub rows: Rows,
    /// Lane packing.
    pub lanes: Lanes,
    /// Blocked per layout edge.
    pub blocked: Vec<bool>,
    /// Route per layout edge.
    pub routes: Vec<Route>,
    /// π: lane → column.
    pub pi: Vec<u32>,
    /// col(i) = π(lane(i)).
    pub col: Vec<u32>,
}

impl Layout {
    /// Output `rows`: max row + U (0 when n = 0).
    #[must_use]
    pub fn rows_field(&self) -> i64 {
        self.rows.y.iter().copied().max().map_or(0, |m| m + self.rows.unit)
    }

    /// Output `lanes`: max lane + 1 (0 when n = 0).
    #[must_use]
    pub fn lanes_field(&self) -> usize {
        self.lanes.count
    }
}

/// Runs every phase (SPEC §4).
#[must_use]
pub fn layout(input: &Input, mode: Mode, ord: Order) -> Layout {
    let graph = prep(input);
    let rows = layering(input, &graph, mode);
    let lanes = lanes(input, &graph, &rows);
    let blocked = blocked(&graph, &rows, &lanes);
    let routes = routing(&graph, &lanes, &blocked);
    let (pi, col) = order::ordering(&graph, &rows, &lanes, &routes, ord);
    Layout {
        mode,
        order: ord,
        graph,
        rows,
        lanes,
        blocked,
        routes,
        pi,
        col,
    }
}

#[cfg(test)]
#[allow(clippy::type_complexity)] // inline tuple rows keep the hand-traced graphs readable
pub(crate) mod tests {
    use super::*;
    use crate::input::parse_input;

    /// Builds an input from `(ts, is_root, priority, parents)` rows; `parents` are
    /// `(Some(idx), kind)` or `(None, Missing)`.
    pub(crate) fn mk(now_ms: i64, off_min: i64, nodes: &[(Option<i64>, bool, i32, &[(Option<u32>, Kind)])]) -> Input {
        let mut s = format!("{{\"now_ms\":{now_ms},\"utc_offset_min\":{off_min},\"nodes\":[");
        for (k, (ts, root, prio, parents)) in nodes.iter().enumerate() {
            if k > 0 {
                s.push(',');
            }
            let ts = ts.map_or("null".to_owned(), |t| t.to_string());
            s.push_str(&format!(
                "{{\"id\":\"n{k}\",\"ts_ms\":{ts},\"is_root\":{root},\"priority\":{prio},\"parents\":["
            ));
            for (j, (idx, kind)) in parents.iter().enumerate() {
                if j > 0 {
                    s.push(',');
                }
                let idx = idx.map_or("null".to_owned(), |v| v.to_string());
                s.push_str(&format!("{{\"idx\":{idx},\"kind\":\"{}\"}}", kind.as_str()));
            }
            s.push_str("]}");
        }
        s.push_str("]}");
        parse_input(s.as_bytes()).unwrap()
    }

    const D: Kind = Kind::Direct;
    const I: Kind = Kind::Indirect;
    const M: Kind = Kind::Missing;

    #[test]
    fn prep_builds_lp_fp_children_and_positions() {
        // 0: [missing, 2 (indirect), 1]; 1: [2]; 2: root.
        let input = mk(
            0,
            0,
            &[
                (Some(3), false, 0, &[(None, M), (Some(2), I), (Some(1), D)]),
                (Some(2), false, 0, &[(Some(2), D)]),
                (None, true, 0, &[]),
            ],
        );
        let g = prep(&input);
        assert_eq!(g.lp_off, vec![0, 2, 3, 3]);
        assert_eq!(g.lp, vec![2, 1, 2]);
        assert_eq!(g.lp_kind, vec![I, D, D]);
        assert_eq!(g.fp, vec![2, 2, -1]);
        assert_eq!(g.ch_off, vec![0, 0, 1, 3]);
        assert_eq!(g.ch, vec![0, 0, 1]);
        assert_eq!(g.ch_pos, vec![1, 0, 0]);
    }

    /// The design's blocked-merge repro (design spec §12 defect 2), children first:
    /// m=0 [x4, p], g=1 ←c, x4=2 ←x3, x3=3 ←x2, c=4 ←p, x2=5 ←x1, p=6 ←r, x1=7 ←r, r=8.
    /// Trunk (r, p, c, g) priority 0, the x chain and m priority 1.
    pub(crate) fn blocked_merge_repro() -> Input {
        mk(
            0,
            0,
            &[
                (Some(9), false, 1, &[(Some(2), D), (Some(6), D)]),
                (Some(8), false, 0, &[(Some(4), D)]),
                (Some(7), false, 1, &[(Some(3), D)]),
                (Some(6), false, 1, &[(Some(5), D)]),
                (Some(5), false, 0, &[(Some(6), D)]),
                (Some(4), false, 1, &[(Some(7), D)]),
                (Some(3), false, 0, &[(Some(8), D)]),
                (Some(2), false, 1, &[(Some(8), D)]),
                (None, true, 0, &[]),
            ],
        )
    }

    #[test]
    fn compact_layering_is_longest_path() {
        let input = blocked_merge_repro();
        let g = prep(&input);
        let rows = layering(&input, &g, Mode::Compact);
        //                m  g  x4 x3 c  x2 p  x1 r
        assert_eq!(rows.y, vec![5, 3, 4, 3, 2, 2, 1, 1, 0]);
        assert!(rows.buckets.is_empty());
    }

    #[test]
    fn lane_packing_continuation_buffer_and_first_fit() {
        let input = blocked_merge_repro();
        let g = prep(&input);
        let rows = layering(&input, &g, Mode::Compact);
        let l = lanes(&input, &g, &rows);
        // Hand trace (SPEC §4.3): p reserves lane 0 up to m's row − 1 plus the buffer
        // ([1, 6)), so c continues (fits except p) but g — c's continuation — does not:
        // lane 0 holds p's b′ = 6 > a = 3, lane 1 the x chain's b′ = 4 > 3 → lane 2.
        //                         m  g  x4 x3 c  x2 p  x1 r
        assert_eq!(l.lane, vec![1, 2, 1, 1, 0, 1, 0, 1, 0]);
        assert_eq!(l.count, 3);
        assert_eq!(l.lane_off, vec![0, 3, 8, 9]);
        assert_eq!(l.lane_ys, vec![0, 1, 2, 1, 2, 3, 4, 5, 3]);
        let bl = blocked(&g, &rows, &l);
        let routes = routing(&g, &l, &bl);
        // Edges: m←x4, m←p, g←c, x4←x3, x3←x2, c←p, x2←x1, p←r, x1←r.
        assert_eq!(bl, vec![false, true, false, false, false, false, false, false, true]);
        use Route::{BranchOff as B, Straight as S};
        assert_eq!(routes, vec![S, B, B, S, S, S, S, S, B]);
    }

    #[test]
    fn continuation_ties_fall_to_the_index() {
        // 0: x ← w;  1: y ← r;  2: w ← r;  3: r. y and w tie on priority: y (index 1) continues r.
        let input = mk(
            0,
            0,
            &[
                (Some(4), false, 0, &[(Some(2), D)]),
                (Some(3), false, 0, &[(Some(3), D)]),
                (Some(3), false, 0, &[(Some(3), D)]),
                (None, true, 0, &[]),
            ],
        );
        let g = prep(&input);
        let rows = layering(&input, &g, Mode::Compact);
        assert_eq!(rows.y, vec![2, 1, 1, 0]);
        let l = lanes(&input, &g, &rows);
        // r: [0, 2) lane 0. y: leaf, [1, 3), continues lane 0 (fits except r).
        // w: not r's continuation → first fit: lane 0 max b′ 3 > a = 1 → lane 1, [1, 3).
        // x: w's continuation, [2, 4), fits lane 1 except w.
        assert_eq!(l.lane, vec![1, 0, 1, 0]);
    }

    #[test]
    fn leaf_reserves_a_one_row_buffer() {
        // 0: t2 ← t1; 1: n ← t1; 2: t1 ← r; 3: leaf ← r; 4: r.
        // Priorities: trunk (r, t1, t2) 0, leaf 1, n 2.
        let input = mk(
            0,
            0,
            &[
                (Some(5), false, 0, &[(Some(2), D)]),
                (Some(4), false, 2, &[(Some(2), D)]),
                (Some(3), false, 0, &[(Some(4), D)]),
                (Some(2), false, 1, &[(Some(4), D)]),
                (None, true, 0, &[]),
            ],
        );
        let g = prep(&input);
        let rows = layering(&input, &g, Mode::Compact);
        assert_eq!(rows.y, vec![2, 2, 1, 1, 0]);
        let l = lanes(&input, &g, &rows);
        // leaf (row 1) holds [1, 3) in lane 1: the one-row buffer above it. n (a = 2) does
        // not fit lane 0 (t2's [2, 4)) nor lane 1 (b′ = 3 > 2) → lane 2. Without the buffer
        // (b′ = 2) it would have taken lane 1.
        assert_eq!(l.lane, vec![0, 2, 0, 1, 0]);
    }

    #[test]
    fn time_bucket_keys_ladder_and_days() {
        let now = 1_790_344_800_000; // 2026-09-25T14:00Z
        let min = 60_000;
        assert_eq!(bucket_key(None, false, now, 0), ROOT_KEY);
        assert_eq!(bucket_key(Some(now), true, now, 0), ROOT_KEY);
        assert_eq!(bucket_key(Some(now + 5 * min), false, now, 0), now - 10 * min); // future → 10m
        assert_eq!(bucket_key(Some(now - 10 * min), false, now, 0), now - 10 * min);
        assert_eq!(bucket_key(Some(now - 10 * min - 1), false, now, 0), now - 20 * min);
        assert_eq!(bucket_key(Some(now - 720 * min), false, now, 0), now - 720 * min);
        // Older than 12h → calendar day at the fixed offset.
        let day0 = 1_790_294_400_000; // 2026-09-25T00:00Z
        assert_eq!(bucket_key(Some(now - 720 * min - 1), false, now, 0), day0);
        assert_eq!(bucket_key(Some(day0 - 1), false, now, 0), day0 - 86_400_000);
        // UTC+2: 23:59:59.999Z is 01:59:59.999 local on the 25th → local midnight = 22:00Z on the 24th.
        assert_eq!(bucket_key(Some(day0 - 1), false, now, 120), day0 - 7_200_000);
        // UTC−5: 03:00Z on the 24th is 22:00 local on the 23rd → local midnight = 05:00Z on the 23rd.
        let d = 86_400_000;
        assert_eq!(
            bucket_key(Some(day0 - d + 3 * 3_600_000), false, now, -300),
            day0 - 2 * d + 5 * 3_600_000
        );
        // 03:00Z on the 25th is only 11h old: still the 12h ladder bucket, whatever the offset.
        assert_eq!(
            bucket_key(Some(day0 + 3 * 3_600_000), false, now, -300),
            now - 720 * min
        );
        assert_eq!(bucket_of_key(ROOT_KEY, now), (BucketKind::Root, 0));
        assert_eq!(bucket_of_key(now - 720 * min, now), (BucketKind::Age, 720));
        assert_eq!(bucket_of_key(now - 10 * min, now), (BucketKind::Age, 10));
        assert_eq!(bucket_of_key(day0, now), (BucketKind::Day, day0));
    }

    #[test]
    fn time_rows_clamp_non_monotonic_timestamps() {
        let now = 1_790_344_800_000;
        let min = 60_000;
        let day = 86_400_000;
        // 0: a (3 days old) ← 1: b (5 min old) ← 2: r (root). 3: z (3 days old, unrelated root-less).
        let input = mk(
            now,
            0,
            &[
                (Some(now - 3 * day), false, 0, &[(Some(1), D)]),
                (Some(now - 5 * min), false, 0, &[(Some(2), D)]),
                (None, true, 0, &[]),
                (Some(now - 3 * day), false, 0, &[]),
            ],
        );
        let g = prep(&input);
        let rows = layering(&input, &g, Mode::Time);
        // Buckets ascending: ROOT {r}, day(now − 3d) {z}, age 10 {b, a (clamped up from its day)}.
        // Inside age 10 the descending index visits b before a: b = start, a = b + 1.
        assert_eq!(rows.y, vec![3, 2, 0, 1]);
        let d3 = (now - 3 * day).div_euclid(day) * day;
        assert_eq!(
            rows.buckets,
            vec![
                Bucket {
                    kind: BucketKind::Root,
                    value: 0,
                    start: 0,
                    end: 0
                },
                Bucket {
                    kind: BucketKind::Day,
                    value: d3,
                    start: 1,
                    end: 1
                },
                Bucket {
                    kind: BucketKind::Age,
                    value: 10,
                    start: 2,
                    end: 3
                },
            ]
        );
    }

    #[test]
    fn time_rows_share_a_bucket_start_for_independent_commits() {
        let now = 1_000_000_000_000;
        let min = 60_000;
        // Two parentless commits (one with a child) in the same 1h bucket share its start row.
        let input = mk(
            now,
            0,
            &[
                (Some(now - 45 * min), false, 0, &[(Some(1), D)]),
                (Some(now - 50 * min), false, 0, &[]),
                (Some(now - 59 * min), false, 0, &[]),
            ],
        );
        let g = prep(&input);
        let rows = layering(&input, &g, Mode::Time);
        assert_eq!(rows.y, vec![1, 0, 0]);
        assert_eq!(
            rows.buckets,
            vec![Bucket {
                kind: BucketKind::Age,
                value: 60,
                start: 0,
                end: 1
            }]
        );
    }

    #[test]
    fn gap_matches_the_spec_table() {
        let min = 60_000;
        let hour = 60 * min;
        let day = 24 * hour;
        assert_eq!(gap(0), 0);
        assert_eq!(gap(min - 1), 0);
        assert_eq!(gap(min), 2);
        assert_eq!(gap(hour), 11);
        assert_eq!(gap(day), 20);
        assert_eq!(gap(7 * day), 26);
        assert_eq!(gap(365 * day), 38);
        assert_eq!(gap(1 << 53), 48);
        assert_eq!(l2(1), 0);
        assert_eq!(l2(2), 256);
        assert_eq!(l2(3), 384);
        assert_eq!(l2(61), 1512);
    }

    #[test]
    fn free_rows_follow_compressed_time_and_push_chains() {
        let t0 = 1_000_000_000_000;
        let hour = 3_600_000;
        // 0: d (t0 + 1 day, no parents); 1: b (t0 + 1h) ← 2: a (t0) ← 3: r (root, null).
        let input = mk(
            0,
            0,
            &[
                (Some(t0 + 24 * hour), false, 0, &[]),
                (Some(t0 + hour), false, 0, &[(Some(2), D)]),
                (Some(t0), false, 0, &[(Some(3), D)]),
                (None, true, 0, &[]),
            ],
        );
        let g = prep(&input);
        let rows = layering(&input, &g, Mode::Free);
        assert_eq!(rows.unit, 16);
        // Walk (T asc, i desc): r (T = tmin = t0) → 0; a (T t0) → max(0 + gap 0, 0 + 16) = 16;
        // b: max(16 + gap(1h) = 27, 16 + 16) = 32; d: 32 + gap(23h) = 32 + 20 = 52.
        assert_eq!(rows.y, vec![52, 32, 16, 0]);
        // Day buckets (amended 2026-10-01): t0 is 2001-09-09T01:46:40Z, so a and b share that
        // UTC day, d is on the next; the root is in none.
        let day = 86_400_000;
        let d0 = t0.div_euclid(day) * day;
        assert_eq!(
            rows.buckets,
            vec![
                Bucket {
                    kind: BucketKind::Day,
                    value: d0,
                    start: 16,
                    end: 32
                },
                Bucket {
                    kind: BucketKind::Day,
                    value: d0 + day,
                    start: 52,
                    end: 52
                },
            ]
        );
    }

    #[test]
    fn free_day_buckets_can_share_one_row_across_local_midnight() {
        // Two unrelated commits 30 s apart across a local midnight at UTC+2, plus the root.
        let midnight = 1_000_072_800_000; // 2001-09-10T00:00 at UTC+2
        let input = mk(
            0,
            120,
            &[
                (Some(midnight + 10_000), false, 0, &[]),
                (Some(midnight - 20_000), false, 0, &[]),
                (None, true, 0, &[]),
            ],
        );
        let g = prep(&input);
        let rows = layering(&input, &g, Mode::Free);
        // Walk: r (T = tmin = midnight − 20 s, index 2 first) → 0; 1 → 0 + gap(0) = 0;
        // 0 → 0 + gap(30 s) = 0. One y value, two days: end of the first = start of the second.
        assert_eq!(rows.y, vec![0, 0, 0]);
        assert_eq!(day_key(midnight - 20_000, 120), midnight - 86_400_000);
        assert_eq!(
            rows.buckets,
            vec![
                Bucket {
                    kind: BucketKind::Day,
                    value: midnight - 86_400_000,
                    start: 0,
                    end: 0
                },
                Bucket {
                    kind: BucketKind::Day,
                    value: midnight,
                    start: 0,
                    end: 0
                },
            ]
        );
    }

    #[test]
    fn free_clamps_a_child_older_than_its_parent() {
        let t0 = 1_000_000_000_000;
        // 0: c (t0 − 1 day) ← 1: p (t0) ← 2: r (null).
        let input = mk(
            0,
            0,
            &[
                (Some(t0 - 86_400_000), false, 0, &[(Some(1), D)]),
                (Some(t0), false, 0, &[(Some(2), D)]),
                (None, true, 0, &[]),
            ],
        );
        let g = prep(&input);
        let rows = layering(&input, &g, Mode::Free);
        // tmin = t0 − 1 day (c's own ts). r: T = tmin; p: T = t0; c: T clamped to t0.
        // r → 0; p: base 0 + gap(1 day) = 20, parent r + 16 → 20; c (T = t0, visited after p):
        // base 20 + gap(0) = 20, parent p + 16 = 36.
        assert_eq!(rows.y, vec![36, 20, 0]);
        // c counts by its clamped T (p's day), not by its own ts a day earlier.
        let day = 86_400_000;
        assert_eq!(
            rows.buckets,
            vec![Bucket {
                kind: BucketKind::Day,
                value: t0.div_euclid(day) * day,
                start: 20,
                end: 36
            }]
        );
    }

    #[test]
    fn empty_input_gives_empty_layout() {
        let input = mk(0, 0, &[]);
        for mode in [Mode::Compact, Mode::Time, Mode::Free] {
            for ord in [Order::Greedy, Order::Optimized] {
                let out = layout(&input, mode, ord);
                assert_eq!(out.rows_field(), 0);
                assert_eq!(out.lanes_field(), 0);
                assert!(out.rows.buckets.is_empty());
            }
        }
    }

    #[test]
    fn missing_only_parents_make_a_node_a_layout_root() {
        let input = mk(
            0,
            0,
            &[(Some(1), false, 0, &[(None, M)]), (Some(0), false, 0, &[(None, M)])],
        );
        let out = layout(&input, Mode::Compact, Order::Greedy);
        assert_eq!(out.rows.y, vec![0, 0]);
        assert_eq!(out.graph.edge_count(), 0);
        // Two independent leaves on row 0: [0, 2) each → lanes 0 and 1.
        assert_eq!(out.lanes.lane, vec![0, 1]);
    }
}
