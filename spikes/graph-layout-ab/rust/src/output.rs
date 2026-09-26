//! Canonical output JSON (SPEC §3) and the bench digest (SPEC §8.4).

use std::fmt::Write as _;

use crate::layout::Layout;

/// Serialises a layout in the canonical form: keys in spec order, no whitespace, one
/// trailing `\n`.
#[must_use]
pub fn to_canonical_json(out: &Layout) -> String {
    let g = &out.graph;
    let n = g.len();
    let mut s = String::with_capacity(64 + 40 * n + 80 * g.edge_count());
    let _ = write!(
        s,
        "{{\"mode\":\"{}\",\"order\":\"{}\",\"unit\":{},\"rows\":{},\"lanes\":{},\"nodes\":[",
        out.mode.as_str(),
        out.order.as_str(),
        out.rows.unit,
        out.rows_field(),
        out.lanes_field()
    );
    for i in 0..n {
        if i > 0 {
            s.push(',');
        }
        let _ = write!(
            s,
            "{{\"row\":{},\"lane\":{},\"col\":{}}}",
            out.rows.y[i], out.lanes.lane[i], out.col[i]
        );
    }
    s.push_str("],\"edges\":[");
    let mut first = true;
    for i in 0..n {
        for e in g.lp_off[i] as usize..g.lp_off[i + 1] as usize {
            if !first {
                s.push(',');
            }
            first = false;
            let _ = write!(
                s,
                "{{\"from\":{},\"to\":{},\"kind\":\"{}\",\"route\":\"{}\",\"blocked\":{}}}",
                g.lp[e],
                i,
                g.lp_kind[e].as_str(),
                out.routes[e].as_str(),
                out.blocked[e]
            );
        }
    }
    s.push_str("],\"buckets\":[");
    for (k, b) in out.rows.buckets.iter().enumerate() {
        if k > 0 {
            s.push(',');
        }
        let _ = write!(
            s,
            "{{\"kind\":\"{}\",\"value\":{},\"start\":{},\"end\":{}}}",
            b.kind.as_str(),
            b.value,
            b.start,
            b.end
        );
    }
    s.push_str("]}\n");
    s
}

const P: i64 = 1_000_000_007;

/// The §8.4 digest over nodes (index order), edges (output order) and buckets.
#[must_use]
pub fn digest(out: &Layout) -> i64 {
    let mut d = 0i64;
    for i in 0..out.graph.len() {
        let v = 7 * out.rows.y[i] + 3 * i64::from(out.col[i]) + i64::from(out.lanes.lane[i]);
        d = (31 * d + v).rem_euclid(P);
    }
    for (route, &blocked) in out.routes.iter().zip(&out.blocked) {
        d = (31 * d + route.code() + 4 * i64::from(blocked)).rem_euclid(P);
    }
    for b in &out.rows.buckets {
        d = (31 * d + b.start + 3 * b.end).rem_euclid(P);
    }
    d
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::input::Kind;
    use crate::layout::tests::{blocked_merge_repro, mk};
    use crate::layout::{layout, Mode, Order};

    #[test]
    fn canonical_json_of_the_blocked_merge_repro() {
        let out = layout(&blocked_merge_repro(), Mode::Compact, Order::Greedy);
        let expected = concat!(
            r#"{"mode":"compact","order":"greedy","unit":1,"rows":6,"lanes":3,"nodes":["#,
            r#"{"row":5,"lane":1,"col":1},{"row":3,"lane":2,"col":2},{"row":4,"lane":1,"col":1},"#,
            r#"{"row":3,"lane":1,"col":1},{"row":2,"lane":0,"col":0},{"row":2,"lane":1,"col":1},"#,
            r#"{"row":1,"lane":0,"col":0},{"row":1,"lane":1,"col":1},{"row":0,"lane":0,"col":0}],"edges":["#,
            r#"{"from":2,"to":0,"kind":"direct","route":"straight","blocked":false},"#,
            r#"{"from":6,"to":0,"kind":"direct","route":"branch_off","blocked":true},"#,
            r#"{"from":4,"to":1,"kind":"direct","route":"branch_off","blocked":false},"#,
            r#"{"from":3,"to":2,"kind":"direct","route":"straight","blocked":false},"#,
            r#"{"from":5,"to":3,"kind":"direct","route":"straight","blocked":false},"#,
            r#"{"from":6,"to":4,"kind":"direct","route":"straight","blocked":false},"#,
            r#"{"from":7,"to":5,"kind":"direct","route":"straight","blocked":false},"#,
            r#"{"from":8,"to":6,"kind":"direct","route":"straight","blocked":false},"#,
            r#"{"from":8,"to":7,"kind":"direct","route":"branch_off","blocked":true}],"buckets":[]}"#,
            "\n"
        );
        assert_eq!(to_canonical_json(&out), expected);
    }

    #[test]
    fn canonical_json_time_buckets_and_empty() {
        let now = 1_790_344_800_000i64;
        let input = mk(
            now,
            0,
            &[
                (
                    Some(now - 90_000_000),
                    false,
                    0,
                    &[(Some(1), Kind::Indirect), (None, Kind::Missing)],
                ),
                (None, true, 0, &[]),
            ],
        );
        let out = layout(&input, Mode::Time, Order::Optimized);
        assert_eq!(
            to_canonical_json(&out),
            concat!(
                r#"{"mode":"time","order":"optimized","unit":1,"rows":2,"lanes":1,"nodes":["#,
                r#"{"row":1,"lane":0,"col":0},{"row":0,"lane":0,"col":0}],"edges":["#,
                r#"{"from":1,"to":0,"kind":"indirect","route":"straight","blocked":false}],"buckets":["#,
                r#"{"kind":"root","value":0,"start":0,"end":0},{"kind":"day","value":1790208000000,"start":1,"end":1}]}"#,
                "\n"
            )
        );
        let empty = layout(&mk(0, 0, &[]), Mode::Free, Order::Greedy);
        assert_eq!(
            to_canonical_json(&empty),
            "{\"mode\":\"free\",\"order\":\"greedy\",\"unit\":16,\"rows\":0,\"lanes\":0,\"nodes\":[],\"edges\":[],\"buckets\":[]}\n"
        );
    }

    #[test]
    fn digest_follows_the_formula() {
        let now = 1_790_344_800_000i64;
        let input = mk(
            now,
            0,
            &[
                (Some(now - 90_000_000), false, 0, &[(Some(1), Kind::Direct)]),
                (None, true, 0, &[]),
            ],
        );
        let out = layout(&input, Mode::Time, Order::Greedy);
        // Nodes (row, col, lane) = (1, 0, 0), (0, 0, 0); one straight edge; buckets (0, 0), (1, 1).
        let mut d = 0i64;
        d = (31 * d + 7) % P;
        d = (31 * d) % P;
        d = (31 * d) % P;
        d = (31 * d) % P;
        d = (31 * d + 1 + 3) % P;
        assert_eq!(digest(&out), d);
        assert_eq!(digest(&layout(&mk(0, 0, &[]), Mode::Compact, Order::Greedy)), 0);
    }
}
