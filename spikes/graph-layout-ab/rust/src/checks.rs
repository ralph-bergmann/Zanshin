//! Test-only cross-checks: the §7.3 invariants on random graphs, and literal (quadratic)
//! re-implementations of lane packing and `blocked` against the O(n log n) ones.

use crate::input::Input;
use crate::layout::{bucket_key, bucket_of_key, layout, BucketKind, Layout, Mode, Order, Route};
use crate::order::tests::random_input;

/// The design's packer, literally: closed-interval overlap test over every stored interval.
fn naive_lanes(input: &Input, out: &Layout) -> Vec<u32> {
    let g = &out.graph;
    let (y, u, pr) = (&out.rows.y, out.rows.unit, &input.priority);
    let n = g.len();
    let fp = |i: usize| (g.fp[i] >= 0).then(|| g.fp[i] as usize);
    let parents = |i: usize| g.lp[g.lp_off[i] as usize..g.lp_off[i + 1] as usize].to_vec();
    let children = |j: usize| (0..n).filter(|&c| parents(c).contains(&(j as u32))).collect::<Vec<_>>();
    let cont = |j: usize| {
        children(j)
            .into_iter()
            .filter(|&c| fp(c) == Some(j))
            .min_by_key(|&c| (pr[c], c))
    };
    let mut order: Vec<usize> = (0..n).collect();
    order.sort_by_key(|&i| (y[i], pr[i], i));
    let mut intervals: Vec<(usize, i64, i64, usize)> = Vec::new(); // (lane, a, b, owner), half-open
    let mut lane = vec![u32::MAX; n];
    for &i in &order {
        let mut ey: Vec<i64> = cont(i).map(|c| y[c]).into_iter().collect();
        for c in children(i) {
            if parents(c).iter().position(|&p| p as usize == i).unwrap() >= 1 {
                ey.push(y[c]);
            }
        }
        let end = ey.iter().max().map_or(y[i], |&m| y[i].max(m - u));
        let a = fp(i).map_or(y[i], |f| y[f] + u);
        let b = end + 2 * u;
        let free = |l: usize, allow: Option<usize>| {
            !intervals
                .iter()
                .any(|&(il, ia, ib, owner)| il == l && ia < b && a < ib && Some(owner) != allow)
        };
        let l = match fp(i) {
            Some(f) if cont(f) == Some(i) && free(lane[f] as usize, Some(f)) => lane[f] as usize,
            _ => (0..).find(|&l| free(l, None)).unwrap(),
        };
        intervals.push((l, a, b, i));
        lane[i] = l as u32;
    }
    lane
}

fn check_invariants(input: &Input, out: &Layout) {
    let g = &out.graph;
    let (y, u, lane, col) = (&out.rows.y, out.rows.unit, &out.lanes.lane, &out.col);
    let n = g.len();
    // Cross-checks against the literal definitions.
    assert_eq!(*lane, naive_lanes(input, out), "lane packing");
    let mut e = 0;
    for i in 0..n {
        for k in g.lp_off[i] as usize..g.lp_off[i + 1] as usize {
            let p = g.lp[k] as usize;
            let naive = lane[i] != lane[p] && (0..n).any(|o| lane[o] == lane[p] && y[p] < y[o] && y[o] <= y[i]);
            assert_eq!(out.blocked[e], naive, "blocked");
            // I1
            assert!(y[i] >= y[p] + u, "I1");
            // I3
            let pos = k - g.lp_off[i] as usize;
            match out.routes[e] {
                Route::Straight => assert!(lane[p] == lane[i] && g.fp[i] == p as i32, "I3 straight"),
                Route::Merge => assert!(lane[p] != lane[i] && pos >= 1 && !out.blocked[e], "I3 merge"),
                Route::BranchOff => assert!(lane[p] != lane[i], "I3 branch_off"),
            }
            if out.blocked[e] {
                assert_ne!(lane[p], lane[i], "I3 blocked");
            }
            e += 1;
        }
    }
    // I2: per lane, consecutive by y.
    let mut by_lane: Vec<Vec<usize>> = vec![Vec::new(); out.lanes.count];
    for i in 0..n {
        by_lane[lane[i] as usize].push(i);
    }
    for members in &mut by_lane {
        members.sort_by_key(|&i| y[i]);
        for w in members.windows(2) {
            let (lo, hi) = (w[0], w[1]);
            let straight = g.fp[hi] == lo as i32 && lane[lo] == lane[hi];
            assert!(y[hi] - y[lo] >= if straight { u } else { 2 * u }, "I2");
        }
    }
    // I4
    let l_count = out.lanes.count;
    let mut seen = vec![false; l_count];
    for &c in &out.pi {
        assert!(!seen[c as usize], "I4 permutation");
        seen[c as usize] = true;
    }
    assert!(l_count == 0 || out.pi[0] == 0, "I4 lane 0 fixed");
    for i in 0..n {
        assert_eq!(col[i], out.pi[lane[i] as usize], "I4 col");
        if out.order == Order::Greedy {
            assert_eq!(col[i], lane[i], "I4 greedy");
        }
    }
    // I5 / I6
    match out.mode {
        Mode::Time => {
            let mut eb = vec![0i64; n];
            for i in (0..n).rev() {
                let ts = input.has_ts[i].then_some(input.ts[i]);
                eb[i] = bucket_key(ts, input.is_root[i], input.now_ms, input.utc_offset_min);
                for k in g.lp_off[i] as usize..g.lp_off[i + 1] as usize {
                    eb[i] = eb[i].max(eb[g.lp[k] as usize]);
                }
            }
            let key = |kind: BucketKind, value: i64| match kind {
                BucketKind::Root => i64::MIN,
                BucketKind::Age => input.now_ms - value * 60_000,
                BucketKind::Day => value,
            };
            let mut next = 0;
            for w in out.rows.buckets.windows(2) {
                assert!(key(w[0].kind, w[0].value) < key(w[1].kind, w[1].value), "I5 ascending");
            }
            for b in &out.rows.buckets {
                assert_eq!(b.start, next, "I5 contiguous");
                assert!(b.end >= b.start);
                next = b.end + 1;
            }
            assert_eq!(next, out.rows_field(), "I5 covers rows");
            for i in 0..n {
                let (kind, value) = bucket_of_key(eb[i], input.now_ms);
                let b = out
                    .rows
                    .buckets
                    .iter()
                    .find(|b| b.kind == kind && b.value == value)
                    .expect("I5 bucket");
                assert!(b.start <= y[i] && y[i] <= b.end, "I5 inside");
            }
        }
        Mode::Free => {
            assert!(out.rows.buckets.is_empty());
            let tmin = (0..n)
                .filter(|&i| input.has_ts[i])
                .map(|i| input.ts[i])
                .min()
                .unwrap_or(0);
            let mut t = vec![0i64; n];
            for i in (0..n).rev() {
                t[i] = if input.is_root[i] || !input.has_ts[i] {
                    tmin
                } else {
                    input.ts[i]
                };
                for k in g.lp_off[i] as usize..g.lp_off[i + 1] as usize {
                    t[i] = t[i].max(t[g.lp[k] as usize]);
                }
            }
            let mut ord: Vec<usize> = (0..n).collect();
            ord.sort_by_key(|&i| (t[i], std::cmp::Reverse(i)));
            for w in ord.windows(2) {
                assert!(y[w[1]] >= y[w[0]], "I6");
            }
        }
        Mode::Compact => assert!(out.rows.buckets.is_empty()),
    }
}

#[test]
fn invariants_hold_on_random_graphs() {
    let (mut merges, mut blocked, mut blocked_merges, mut max_lanes, mut moved) = (0, 0, 0, 0, 0);
    for seed in 0..80u64 {
        let n = 1 + (seed as usize * 13) % 150;
        let input = random_input(seed, n);
        for mode in [Mode::Compact, Mode::Time, Mode::Free] {
            for order in [Order::Greedy, Order::Optimized] {
                let out = layout(&input, mode, order);
                check_invariants(&input, &out);
                merges += out.routes.iter().filter(|&&r| r == Route::Merge).count();
                blocked += out.blocked.iter().filter(|&&b| b).count();
                max_lanes = max_lanes.max(out.lanes.count);
                moved += usize::from(out.pi.iter().enumerate().any(|(l, &c)| l != c as usize));
                let g = &out.graph;
                for i in 0..g.len() {
                    for e in g.lp_off[i] as usize + 1..g.lp_off[i + 1] as usize {
                        blocked_merges += usize::from(out.blocked[e]);
                    }
                }
            }
        }
    }
    // The random graphs must exercise the interesting paths, not just chains.
    assert!(
        merges > 100 && blocked > 100 && blocked_merges > 20,
        "{merges} {blocked} {blocked_merges}"
    );
    assert!(max_lanes > 2 * crate::order::K + 1, "max lanes {max_lanes}");
    assert!(moved > 50, "optimized moved lanes in {moved} layouts");
}
