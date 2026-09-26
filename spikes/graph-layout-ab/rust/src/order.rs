//! §4.6 lane order → col(i): `greedy` (identity) or `optimized` (budgeted windowed
//! sifting on the incremental integer cost 400·X + 4·Len + Disp).

use std::cmp::{max, min};

use crate::layout::{Graph, Lanes, Order, Route, Rows};

/// Sifting window half-width.
pub const K: usize = 8;
/// Maximum sifting rounds.
pub const R: usize = 4;
/// Work budget in swap-units (horizontal-endpoint visits).
pub const BUDGET: i64 = 2_000_000;

/// Computes π (lane → column) and col(i) = π(lane(i)).
#[must_use]
pub fn ordering(g: &Graph, rows: &Rows, lanes: &Lanes, routes: &[Route], order: Order) -> (Vec<u32>, Vec<u32>) {
    let pi = match order {
        Order::Greedy => (0..lanes.count as u32).collect(),
        Order::Optimized => sift(&Model::build(g, rows, lanes, routes), K, R, BUDGET),
    };
    let col = lanes.lane.iter().map(|&l| pi[l as usize]).collect();
    (pi, col)
}

/// The integer geometry model (ticks, 10 per unit, bottom-up): per lane the sorted lo[] and
/// hi[] of its verticals, and the horizontals incident to it (other endpoint lane + level).
#[derive(Debug)]
pub struct Model {
    /// L.
    pub lanes: usize,
    v_off: Vec<u32>,
    v_lo: Vec<i64>,
    v_hi: Vec<i64>,
    inc_off: Vec<u32>,
    inc_other: Vec<u32>,
    inc_level: Vec<i64>,
}

impl Model {
    /// Builds the per-lane vertical and horizontal indexes, O(E log E).
    #[must_use]
    pub fn build(g: &Graph, rows: &Rows, lanes: &Lanes, routes: &[Route]) -> Model {
        let l_count = lanes.count;
        let u = rows.unit;
        let y = &rows.y;
        let lane = &lanes.lane;
        let bot = |v: usize| 10 * y[v];
        let mut v_count = vec![0u32; l_count + 1];
        let mut h_count = vec![0u32; l_count + 1];
        for i in 0..g.len() {
            for e in g.lp_off[i] as usize..g.lp_off[i + 1] as usize {
                let lp = lane[g.lp[e] as usize] as usize;
                let li = lane[i] as usize;
                match routes[e] {
                    Route::Straight => v_count[lp + 1] += 1,
                    Route::Merge => {
                        v_count[lp + 1] += 1;
                        v_count[li + 1] += 1;
                        h_count[lp + 1] += 1;
                        h_count[li + 1] += 1;
                    }
                    Route::BranchOff => {
                        v_count[li + 1] += 1;
                        h_count[lp + 1] += 1;
                        h_count[li + 1] += 1;
                    }
                }
            }
        }
        for l in 0..l_count {
            v_count[l + 1] += v_count[l];
            h_count[l + 1] += h_count[l];
        }
        let (v_off, inc_off) = (v_count, h_count);
        let mut v_cur: Vec<u32> = v_off[..l_count].to_vec();
        let mut h_cur: Vec<u32> = inc_off[..l_count].to_vec();
        let mut v_lo = vec![0i64; v_off[l_count] as usize];
        let mut v_hi = vec![0i64; v_off[l_count] as usize];
        let mut inc_other = vec![0u32; inc_off[l_count] as usize];
        let mut inc_level = vec![0i64; inc_off[l_count] as usize];
        let mut vertical = |l: usize, lo: i64, hi: i64| {
            let s = v_cur[l] as usize;
            v_lo[s] = lo;
            v_hi[s] = hi;
            v_cur[l] += 1;
        };
        let mut horizontal = |a: usize, b: usize, level: i64| {
            for (at, other) in [(a, b), (b, a)] {
                let s = h_cur[at] as usize;
                inc_other[s] = other as u32;
                inc_level[s] = level;
                h_cur[at] += 1;
            }
        };
        for i in 0..g.len() {
            for e in g.lp_off[i] as usize..g.lp_off[i + 1] as usize {
                let p = g.lp[e] as usize;
                let (lp, li) = (lane[p] as usize, lane[i] as usize);
                let top_p = bot(p) + 5 * u;
                match routes[e] {
                    Route::Straight => vertical(lp, top_p, bot(i)),
                    Route::Merge => {
                        let dn_i = bot(i) - 2 * u;
                        vertical(lp, top_p, dn_i);
                        vertical(li, dn_i, bot(i));
                        horizontal(lp, li, dn_i);
                    }
                    Route::BranchOff => {
                        let up_p = bot(p) + 7 * u;
                        vertical(li, up_p, bot(i));
                        horizontal(lp, li, up_p);
                    }
                }
            }
        }
        for l in 0..l_count {
            let r = v_off[l] as usize..v_off[l + 1] as usize;
            v_lo[r.clone()].sort_unstable();
            v_hi[r].sort_unstable();
        }
        Model {
            lanes: l_count,
            v_off,
            v_lo,
            v_hi,
            inc_off,
            inc_other,
            inc_level,
        }
    }

    /// h(ℓ): horizontals with an endpoint in lane ℓ.
    #[inline]
    #[must_use]
    pub fn h(&self, l: usize) -> usize {
        (self.inc_off[l + 1] - self.inc_off[l]) as usize
    }

    /// m(ℓ, λ): verticals in lane ℓ with lo < λ < hi, as #{lo < λ} − #{hi ≤ λ}.
    #[inline]
    #[must_use]
    pub fn m(&self, l: usize, level: i64) -> i64 {
        let r = self.v_off[l] as usize..self.v_off[l + 1] as usize;
        let below = self.v_lo[r.clone()].partition_point(|&v| v < level);
        let ended = self.v_hi[r].partition_point(|&v| v <= level);
        below as i64 - ended as i64
    }

    /// Cost change of swapping columns k (lane P) and k + 1 (lane Q), before the swap.
    fn swap_delta(&self, pi: &[u32], sigma: &[u32], k: usize) -> i64 {
        let p = sigma[k] as usize;
        let q = sigma[k + 1] as usize;
        let (k0, k1) = (k as i64, k as i64 + 1);
        let (mut dx, mut dlen) = (0i64, 0i64);
        for j in self.inc_off[p] as usize..self.inc_off[p + 1] as usize {
            let other = self.inc_other[j] as usize;
            if other == q {
                continue;
            }
            let yc = i64::from(pi[other]);
            if yc > k1 {
                dx -= self.m(q, self.inc_level[j]);
                dlen -= 1;
            } else if yc < k0 {
                dx += self.m(q, self.inc_level[j]);
                dlen += 1;
            }
        }
        for j in self.inc_off[q] as usize..self.inc_off[q + 1] as usize {
            let other = self.inc_other[j] as usize;
            if other == p {
                continue;
            }
            let yc = i64::from(pi[other]);
            if yc < k0 {
                dx -= self.m(p, self.inc_level[j]);
                dlen -= 1;
            } else if yc > k1 {
                dx += self.m(p, self.inc_level[j]);
                dlen += 1;
            }
        }
        let (pl, ql) = (p as i64, q as i64);
        let ddisp = (k1 - pl).abs() + (k0 - ql).abs() - (k0 - pl).abs() - (k1 - ql).abs();
        400 * dx + 4 * dlen + ddisp
    }
}

/// Swaps the lanes in columns k and k + 1.
#[inline]
fn swap(pi: &mut [u32], sigma: &mut [u32], k: usize) {
    let (p, q) = (sigma[k], sigma[k + 1]);
    sigma[k] = q;
    sigma[k + 1] = p;
    pi[p as usize] = k as u32 + 1;
    pi[q as usize] = k as u32;
}

/// Windowed sifting (SPEC §4.6 "Search") with explicit constants, for tests.
#[must_use]
pub fn sift(model: &Model, k_win: usize, rounds: usize, budget: i64) -> Vec<u32> {
    let l_count = model.lanes;
    let mut pi: Vec<u32> = (0..l_count as u32).collect();
    let mut sigma: Vec<u32> = pi.clone();
    let mut order: Vec<usize> = (1..l_count).collect();
    order.sort_unstable_by(|&a, &b| model.h(b).cmp(&model.h(a)).then(a.cmp(&b)));
    let mut spent = 0i64;
    'phase: for _ in 0..rounds {
        let mut moved = false;
        for &a in &order {
            let c = pi[a] as usize;
            let lo = max(1, c.saturating_sub(k_win));
            let hi = min(l_count - 1, c + k_win);
            let ha = model.h(a) as i64;
            let mut work = 0i64;
            for col in lo..=hi {
                if col != c {
                    work += ha + model.h(sigma[col] as usize) as i64;
                }
            }
            if spent + work > budget {
                break 'phase;
            }
            spent += work;
            // d* minimises (D(d), |d − c|, d); D(c) = 0.
            let mut best = (0i64, 0usize, c);
            let mut consider = |d: usize, delta: i64| {
                let cand = (delta, d.abs_diff(c), d);
                if cand < best {
                    best = cand;
                }
            };
            let mut acc = 0i64;
            for k in c..hi {
                acc += model.swap_delta(&pi, &sigma, k);
                swap(&mut pi, &mut sigma, k);
                consider(k + 1, acc);
            }
            for k in (c..hi).rev() {
                swap(&mut pi, &mut sigma, k);
            }
            acc = 0;
            for k in (lo..c).rev() {
                acc += model.swap_delta(&pi, &sigma, k);
                swap(&mut pi, &mut sigma, k);
                consider(k, acc);
            }
            for k in lo..c {
                swap(&mut pi, &mut sigma, k);
            }
            let (delta, _, d) = best;
            if delta < 0 {
                if d > c {
                    for k in c..d {
                        swap(&mut pi, &mut sigma, k);
                    }
                } else {
                    for k in (d..c).rev() {
                        swap(&mut pi, &mut sigma, k);
                    }
                }
                moved = true;
            }
        }
        if !moved {
            break;
        }
    }
    pi
}

#[cfg(test)]
#[allow(clippy::type_complexity)] // tuple geometry mirrors the §4.6 table literally
pub(crate) mod tests {
    use super::*;
    use crate::input::{Input, Kind};
    use crate::layout::tests::mk;
    use crate::layout::{layout, Layout, Mode};

    /// Naive geometry straight from the §4.6 table: verticals (lane, lo, hi) and
    /// horizontals (lane a, lane b, level).
    fn naive_geometry(out: &Layout) -> (Vec<(usize, i64, i64)>, Vec<(usize, usize, i64)>) {
        let (g, y, u, lane) = (&out.graph, &out.rows.y, out.rows.unit, &out.lanes.lane);
        let (mut vs, mut hs) = (Vec::new(), Vec::new());
        for i in 0..g.len() {
            for e in g.lp_off[i] as usize..g.lp_off[i + 1] as usize {
                let p = g.lp[e] as usize;
                let (lp, li) = (lane[p] as usize, lane[i] as usize);
                let (bot_p, bot_i) = (10 * y[p], 10 * y[i]);
                match out.routes[e] {
                    Route::Straight => vs.push((lp, bot_p + 5 * u, bot_i)),
                    Route::Merge => {
                        vs.push((lp, bot_p + 5 * u, bot_i - 2 * u));
                        vs.push((li, bot_i - 2 * u, bot_i));
                        hs.push((lp, li, bot_i - 2 * u));
                    }
                    Route::BranchOff => {
                        vs.push((li, bot_p + 7 * u, bot_i));
                        hs.push((lp, li, bot_p + 7 * u));
                    }
                }
            }
        }
        (vs, hs)
    }

    /// cost(π) = (X, Len, Disp), from the definition.
    fn naive_cost(vs: &[(usize, i64, i64)], hs: &[(usize, usize, i64)], pi: &[usize]) -> (i64, i64, i64) {
        let mut by_lane: Vec<Vec<(i64, i64)>> = vec![Vec::new(); pi.len()];
        for &(l, lo, hi) in vs {
            by_lane[l].push((lo, hi));
        }
        naive_cost_by_lane(&by_lane, hs, pi)
    }

    fn naive_cost_by_lane(by_lane: &[Vec<(i64, i64)>], hs: &[(usize, usize, i64)], pi: &[usize]) -> (i64, i64, i64) {
        let (mut x, mut len) = (0i64, 0i64);
        for &(a, b, level) in hs {
            let (lo, hi) = (pi[a].min(pi[b]), pi[a].max(pi[b]));
            len += (hi - lo) as i64;
            for (l, &c) in pi.iter().enumerate() {
                if lo < c && c < hi {
                    x += by_lane[l]
                        .iter()
                        .filter(|&&(vlo, vhi)| vlo < level && level < vhi)
                        .count() as i64;
                }
            }
        }
        let disp: i64 = pi.iter().enumerate().map(|(l, &c)| (c as i64 - l as i64).abs()).sum();
        (x, len, disp)
    }

    fn total(c: (i64, i64, i64)) -> i64 {
        400 * c.0 + 4 * c.1 + c.2
    }

    /// The §4.6 search pseudocode taken literally, with a full cost recomputation per candidate.
    fn naive_sift(out: &Layout, k_win: usize, rounds: usize, budget: i64) -> Vec<usize> {
        let (vs, hs) = naive_geometry(out);
        let l_count = out.lanes.count;
        let mut by_lane: Vec<Vec<(i64, i64)>> = vec![Vec::new(); l_count];
        for &(l, lo, hi) in &vs {
            by_lane[l].push((lo, hi));
        }
        let cost = |pi: &[usize]| total(naive_cost_by_lane(&by_lane, &hs, pi));
        let h = |l: usize| hs.iter().filter(|&&(a, b, _)| a == l || b == l).count() as i64;
        let mut sigma: Vec<usize> = (0..l_count).collect();
        let pi_of = |s: &[usize]| {
            let mut pi = vec![0; s.len()];
            for (c, &l) in s.iter().enumerate() {
                pi[l] = c;
            }
            pi
        };
        let mut order: Vec<usize> = (1..l_count).collect();
        order.sort_by(|&a, &b| h(b).cmp(&h(a)).then(a.cmp(&b)));
        let mut spent = 0;
        'phase: for _ in 0..rounds {
            let mut moved = false;
            for &a in &order {
                let pi = pi_of(&sigma);
                let c = pi[a];
                let (lo, hi) = (max(1, c.saturating_sub(k_win)), min(l_count - 1, c + k_win));
                let work: i64 = (0..l_count)
                    .filter(|&b| b != a && (lo..=hi).contains(&pi[b]))
                    .map(|b| h(a) + h(b))
                    .sum();
                if spent + work > budget {
                    break 'phase;
                }
                spent += work;
                let base = cost(&pi);
                let mut best = (0i64, 0usize, c, sigma.clone());
                for d in lo..=hi {
                    let mut s = sigma.clone();
                    let lane_a = s.remove(c);
                    s.insert(d, lane_a);
                    let delta = cost(&pi_of(&s)) - base;
                    if (delta, d.abs_diff(c), d) < (best.0, best.1, best.2) {
                        best = (delta, d.abs_diff(c), d, s);
                    }
                }
                if best.0 < 0 {
                    sigma = best.3;
                    moved = true;
                }
            }
            if !moved {
                break;
            }
        }
        pi_of(&sigma)
    }

    /// Deterministic xorshift for test graphs.
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0
        }
        fn below(&mut self, n: u64) -> u64 {
            self.next() % n
        }
    }

    /// A random children-first DAG: branchy, some merges, indirect and missing edges,
    /// null timestamps and ~10 % non-monotonic timestamps.
    pub(crate) fn random_input(seed: u64, n: usize) -> Input {
        let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
        let now = 1_790_344_800_000i64;
        let mut ts = vec![0i64; n];
        let mut nodes: Vec<(Option<i64>, bool, i32, Vec<(Option<u32>, Kind)>)> = Vec::with_capacity(n);
        for i in (0..n).rev() {
            let mut parents = Vec::new();
            if i + 1 < n {
                let want = match rng.below(10) {
                    0 => 0,
                    1 | 2 => 2,
                    3 => 3,
                    _ => 1,
                };
                for _ in 0..want {
                    // Prefer near parents so chains form; sometimes reach far back.
                    let span = if rng.below(4) == 0 {
                        (n - i - 1) as u64
                    } else {
                        min(6, (n - i - 1) as u64)
                    };
                    let p = i + 1 + rng.below(span) as usize;
                    if parents.iter().any(|&(q, _)| q == Some(p as u32)) {
                        continue;
                    }
                    let kind = if rng.below(8) == 0 {
                        Kind::Indirect
                    } else {
                        Kind::Direct
                    };
                    parents.push((Some(p as u32), kind));
                }
                if rng.below(12) == 0 {
                    parents.insert(rng.below(parents.len() as u64 + 1) as usize, (None, Kind::Missing));
                }
            }
            let base = parents
                .iter()
                .filter_map(|&(p, _)| p)
                .map(|p| ts[p as usize])
                .max()
                .unwrap_or(now - 400 * 86_400_000);
            let step = rng.below(3 * 86_400_000) as i64;
            ts[i] = if rng.below(10) == 0 {
                base - step
            } else {
                base + step / 20
            };
            let is_root = i + 1 == n;
            let t = if is_root || rng.below(40) == 0 {
                None
            } else {
                Some(ts[i])
            };
            nodes.push((t, is_root, rng.below(4) as i32, parents));
        }
        nodes.reverse();
        let borrowed: Vec<(Option<i64>, bool, i32, &[(Option<u32>, Kind)])> =
            nodes.iter().map(|(t, r, p, ps)| (*t, *r, *p, ps.as_slice())).collect();
        mk(now, 120, &borrowed)
    }

    /// The crossing example: trunk r ← t1 ← t2 (t2 merges c1), a long branch b1..b4 in lane 1,
    /// and c1 in lane 2, whose merge into t2 crosses b2's vertical.
    fn crossing_example() -> Input {
        use Kind::Direct as D;
        //   0: b4 ← b3, 1: b3 ← b2, 2: t2 ← [t1, c1], 3: b2 ← b1, 4: b1 ← r, 5: t1 ← r, 6: c1 ← r, 7: r.
        mk(
            0,
            0,
            &[
                (Some(9), false, 1, &[(Some(1), D)]),
                (Some(8), false, 1, &[(Some(3), D)]),
                (Some(7), false, 0, &[(Some(5), D), (Some(6), D)]),
                (Some(6), false, 1, &[(Some(4), D)]),
                (Some(5), false, 1, &[(Some(7), D)]),
                (Some(4), false, 0, &[(Some(7), D)]),
                (Some(3), false, 2, &[(Some(7), D)]),
                (None, true, 0, &[]),
            ],
        )
    }

    #[test]
    fn optimized_removes_the_hand_traced_crossing() {
        let input = crossing_example();
        let greedy = layout(&input, Mode::Compact, Order::Greedy);
        //                                  b4 b3 t2 b2 b1 t1 c1 r
        assert_eq!(greedy.lanes.lane, vec![1, 1, 0, 1, 1, 0, 2, 0]);
        assert_eq!(greedy.col, greedy.lanes.lane.clone());
        let (vs, hs) = naive_geometry(&greedy);
        // H1 b1←r (0–1 @ 7), H2 c1←r (0–2 @ 7), H3 t2←c1 merge (2–0 @ 18) crossing b2←b1's (15, 20).
        assert_eq!(naive_cost(&vs, &hs, &[0, 1, 2]), (1, 5, 0));
        let opt = layout(&input, Mode::Compact, Order::Optimized);
        // Sift lane 2 (h = 2) first: D(1) = 400·(−1) + 4·(−1) + 2 = −402 → π = [0, 2, 1]; then stable.
        assert_eq!(opt.pi, vec![0, 2, 1]);
        assert_eq!(opt.col, vec![2, 2, 0, 2, 2, 0, 1, 0]);
        assert_eq!(naive_cost(&vs, &hs, &[0, 2, 1]), (0, 4, 2));
    }

    #[test]
    fn m_counts_open_verticals_only() {
        let input = crossing_example();
        let out = layout(&input, Mode::Compact, Order::Greedy);
        let model = Model::build(&out.graph, &out.rows, &out.lanes, &out.routes);
        // Lane 1 verticals: (7, 10), (15, 20), (25, 30), (35, 40).
        assert_eq!(model.m(1, 7), 0);
        assert_eq!(model.m(1, 8), 1);
        assert_eq!(model.m(1, 10), 0);
        assert_eq!(model.m(1, 18), 1);
        assert_eq!(model.m(1, 50), 0);
        assert_eq!((model.h(0), model.h(1), model.h(2)), (3, 1, 2));
    }

    #[test]
    fn at_most_two_lanes_is_the_identity() {
        for seed in 0..40 {
            let input = random_input(seed, 12);
            let out = layout(&input, Mode::Compact, Order::Optimized);
            if out.lanes.count <= 2 {
                assert_eq!(out.pi, (0..out.lanes.count as u32).collect::<Vec<_>>());
            }
        }
        let chain = mk(
            0,
            0,
            &[(Some(1), false, 0, &[(Some(1), Kind::Direct)]), (None, true, 0, &[])],
        );
        assert_eq!(layout(&chain, Mode::Time, Order::Optimized).pi, vec![0]);
    }

    #[test]
    fn incremental_search_equals_the_literal_search() {
        let mut exercised = 0;
        for seed in 0..40u64 {
            let n = 8 + (seed as usize * 7) % 60;
            let input = random_input(seed, n);
            for mode in [Mode::Compact, Mode::Time, Mode::Free] {
                let out = layout(&input, mode, Order::Greedy);
                let model = Model::build(&out.graph, &out.rows, &out.lanes, &out.routes);
                for (k_win, budget) in [(K, BUDGET), (2, BUDGET), (3, 40)] {
                    let fast: Vec<usize> = sift(&model, k_win, R, budget).into_iter().map(|c| c as usize).collect();
                    assert_eq!(
                        fast,
                        naive_sift(&out, k_win, R, budget),
                        "seed {seed} n {n} {mode:?} K {k_win}"
                    );
                    if fast.iter().enumerate().any(|(l, &c)| l != c) {
                        exercised += 1;
                    }
                }
            }
        }
        assert!(
            exercised > 20,
            "the random graphs must actually move lanes ({exercised})"
        );
    }

    #[test]
    fn optimized_never_raises_the_cost_and_is_deterministic() {
        for seed in 100..130u64 {
            let input = random_input(seed, 120);
            for mode in [Mode::Compact, Mode::Time, Mode::Free] {
                let a = layout(&input, mode, Order::Optimized);
                let b = layout(&input, mode, Order::Optimized);
                assert_eq!(a.pi, b.pi);
                assert_eq!(a.pi.first().copied(), Some(0));
                let (vs, hs) = naive_geometry(&a);
                let ident: Vec<usize> = (0..a.lanes.count).collect();
                let opt: Vec<usize> = a.pi.iter().map(|&c| c as usize).collect();
                assert!(total(naive_cost(&vs, &hs, &opt)) <= total(naive_cost(&vs, &hs, &ident)));
            }
        }
    }
}
