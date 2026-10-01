//! The layout INPUT of docs/graph-layout.md §2: model, validation (V1-V4), the repeated-target
//! rule (§2), the anchors priority rule (§11.2), and the canonical writer (keys in spec order, no
//! whitespace, one trailing `\n`).

use std::fmt::Write as _;
use std::path::Path;

/// Every integer in a file must survive a JS double (docs/graph-layout.md §1).
const MAX_SAFE: i64 = 1 << 53;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Direct,
    Indirect,
    Missing,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Direct => "direct",
            Kind::Indirect => "indirect",
            Kind::Missing => "missing",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Parent {
    /// Target node index; `None` iff `kind == Missing` (V1).
    pub idx: Option<usize>,
    pub kind: Kind,
}

#[derive(Debug, Clone)]
pub struct Node {
    pub id: String,
    pub ts_ms: Option<i64>,
    pub is_root: bool,
    pub priority: u32,
    pub parents: Vec<Parent>,
}

#[derive(Debug, Clone)]
pub struct Input {
    pub now_ms: i64,
    pub utc_offset_min: i64,
    pub nodes: Vec<Node>,
}

impl Input {
    /// V1-V4 of docs/graph-layout.md §2. V3 is read as "no two NON-NULL idx": jj can yield several Missing
    /// edges for one node (e.g. a merge whose parents are both outside the revset).
    pub fn validate(&self) -> Result<(), String> {
        let n = self.nodes.len();
        for v in [self.now_ms, self.utc_offset_min] {
            if v.abs() > MAX_SAFE {
                return Err(format!("V4: header integer {v} out of ±2^53"));
            }
        }
        for (i, node) in self.nodes.iter().enumerate() {
            if node.ts_ms.is_some_and(|t| t.abs() > MAX_SAFE) {
                return Err(format!("V4: node {i} ts out of ±2^53"));
            }
            if node.priority >= 1 << 31 {
                return Err(format!("V4: node {i} priority {} ≥ 2^31", node.priority));
            }
            let mut seen: Vec<usize> = Vec::with_capacity(node.parents.len());
            for p in &node.parents {
                match (p.idx, p.kind) {
                    (None, Kind::Missing) => {}
                    (Some(idx), Kind::Direct | Kind::Indirect) => {
                        if idx <= i || idx >= n {
                            return Err(format!("V2: node {i} has parent idx {idx} (n = {n})"));
                        }
                        if seen.contains(&idx) {
                            return Err(format!("V3: node {i} lists parent {idx} twice"));
                        }
                        seen.push(idx);
                    }
                    _ => return Err(format!("V1: node {i} has idx {:?} with kind {:?}", p.idx, p.kind)),
                }
            }
        }
        Ok(())
    }

    /// The canonical form (docs/graph-layout.md §2 "Producers write the canonical form of §3").
    pub fn to_canonical(&self) -> String {
        let mut s = String::with_capacity(64 + self.nodes.len() * 120);
        write!(s, "{{\"now_ms\":{},\"utc_offset_min\":{},\"nodes\":[", self.now_ms, self.utc_offset_min).unwrap();
        for (i, node) in self.nodes.iter().enumerate() {
            if i > 0 {
                s.push(',');
            }
            s.push_str("{\"id\":");
            push_json_string(&mut s, &node.id);
            s.push_str(",\"ts_ms\":");
            match node.ts_ms {
                Some(t) => write!(s, "{t}").unwrap(),
                None => s.push_str("null"),
            }
            write!(s, ",\"is_root\":{},\"priority\":{},\"parents\":[", node.is_root, node.priority).unwrap();
            for (j, p) in node.parents.iter().enumerate() {
                if j > 0 {
                    s.push(',');
                }
                match p.idx {
                    Some(idx) => write!(s, "{{\"idx\":{idx},\"kind\":\"{}\"}}", p.kind.as_str()).unwrap(),
                    None => write!(s, "{{\"idx\":null,\"kind\":\"{}\"}}", p.kind.as_str()).unwrap(),
                }
            }
            s.push_str("]}");
        }
        s.push_str("]}\n");
        s
    }

    /// Validates, then writes the canonical form to `path`.
    pub fn write(&self, path: &Path) -> Result<(), String> {
        self.validate().map_err(|e| format!("{}: {e}", path.display()))?;
        std::fs::write(path, self.to_canonical()).map_err(|e| format!("{}: {e}", path.display()))
    }
}

/// Minimal JSON string escaping (ids are hex / ASCII, but stay correct for anything).
fn push_json_string(s: &mut String, v: &str) {
    s.push('"');
    for c in v.chars() {
        match c {
            '"' => s.push_str("\\\""),
            '\\' => s.push_str("\\\\"),
            c if (c as u32) < 0x20 => write!(s, "\\u{:04x}", c as u32).unwrap(),
            c => s.push(c),
        }
    }
    s.push('"');
}

/// The first layout parent: the first non-missing edge (docs/graph-layout.md §4.1 fp).
pub fn first_layout_parent(node: &Node) -> Option<usize> {
    node.parents.iter().find(|p| p.kind != Kind::Missing).and_then(|p| p.idx)
}

/// docs/graph-layout.md §2's repeated-target rule (amended 2026-10-01): one parent per target,
/// at the position of its first occurrence, `direct` if any of the repeated edges is direct;
/// Missing parents are kept as they are. Returns the kept parents and the dropped repeats.
pub fn dedupe_parents(parents: Vec<Parent>) -> (Vec<Parent>, Vec<Parent>) {
    let mut kept: Vec<Parent> = Vec::with_capacity(parents.len());
    let mut dropped = Vec::new();
    for p in parents {
        match p.idx.and_then(|idx| kept.iter().position(|k| k.idx == Some(idx))) {
            Some(first) => {
                if p.kind == Kind::Direct {
                    kept[first].kind = Kind::Direct;
                }
                dropped.push(p);
            }
            None => kept.push(p),
        }
    }
    (kept, dropped)
}

/// docs/graph-layout.md §11.2's anchors rule (normative since 2026-10-01): with A anchors every
/// node starts in class A; for k = 0 … A − 1, each node of anchor k (ascending) and its
/// first-parent chain take class k, up to the first node already in a class ≤ k. With the
/// anchors `[trunk(), present(@)]` that is 0 = the trunk chain, 1 = the @ chain up to the first
/// class-0 node, 2 = everything else; an anchor with no node in the graph leaves its class empty.
pub fn assign_priorities(nodes: &mut [Node], anchors: &[Vec<usize>]) {
    let a = u32::try_from(anchors.len()).expect("fewer than 2^32 anchors");
    let mut class = vec![a; nodes.len()];
    for (k, anchor) in (0u32..).zip(anchors) {
        for &start in anchor {
            let mut cur = Some(start);
            while let Some(c) = cur {
                if class[c] <= k {
                    break;
                }
                class[c] = k;
                cur = first_layout_parent(&nodes[c]);
            }
        }
    }
    for (node, c) in nodes.iter_mut().zip(class) {
        node.priority = c;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const D: Kind = Kind::Direct;
    const I: Kind = Kind::Indirect;
    const M: Kind = Kind::Missing;

    fn p(idx: Option<usize>, kind: Kind) -> Parent {
        Parent { idx, kind }
    }

    fn shape(parents: &[Parent]) -> Vec<(Option<usize>, Kind)> {
        parents.iter().map(|p| (p.idx, p.kind)).collect()
    }

    /// The Dart input builder's repeated-target cases (`input_builder_test.dart`), A = 1, B = 2.
    #[test]
    fn dedupe_keeps_the_first_position_and_direct_if_any_is_direct() {
        let (a, b) = (Some(1), Some(2));
        let (kept, dropped) = dedupe_parents(vec![p(a, I), p(b, D), p(a, D)]);
        assert_eq!(shape(&kept), vec![(a, D), (b, D)]);
        assert_eq!(shape(&dropped), vec![(a, D)]);
        let (kept, _) = dedupe_parents(vec![p(a, D), p(a, I)]);
        assert_eq!(shape(&kept), vec![(a, D)]);
        let (kept, _) = dedupe_parents(vec![p(a, I), p(a, I)]);
        assert_eq!(shape(&kept), vec![(a, I)]);
        let (kept, dropped) = dedupe_parents(vec![p(None, M), p(a, D), p(None, M)]);
        assert_eq!(shape(&kept), vec![(None, M), (a, D), (None, M)]);
        assert!(dropped.is_empty());
    }

    fn chain(parents: &[&[(Option<usize>, Kind)]]) -> Vec<Node> {
        parents
            .iter()
            .enumerate()
            .map(|(i, ps)| Node {
                id: format!("n{i}"),
                ts_ms: None,
                is_root: false,
                priority: 9,
                parents: ps.iter().map(|&(idx, kind)| p(idx, kind)).collect(),
            })
            .collect()
    }

    fn classes(nodes: &[Node]) -> Vec<u32> {
        nodes.iter().map(|n| n.priority).collect()
    }

    /// The Dart input builder's priority cases (`input_builder_test.dart`).
    #[test]
    fn anchors_rule_classes() {
        // tiny-3-commits `all()`: [@, c3, c2, c1, root]; @ → root, c3 → c2 → c1 → root.
        let tiny: &[&[(Option<usize>, Kind)]] = &[&[(Some(4), D)], &[(Some(2), D)], &[(Some(3), D)], &[(Some(4), D)], &[]];
        let mut nodes = chain(tiny);
        assign_priorities(&mut nodes, &[vec![4], vec![0]]);
        assert_eq!(classes(&nodes), vec![1, 2, 2, 2, 0]);
        assign_priorities(&mut nodes, &[]);
        assert_eq!(classes(&nodes), vec![0; 5], "no anchor: every node class 0");
        assign_priorities(&mut nodes, &[vec![], vec![0]]);
        assert_eq!(classes(&nodes), vec![1, 2, 2, 2, 1], "an empty anchor 0: @'s chain is class 1");
        // Three anchors: c2's chain is class 0, @'s class 1 up to the root (class 0), c3 class 2.
        assign_priorities(&mut nodes, &[vec![2], vec![0], vec![1]]);
        assert_eq!(classes(&nodes), vec![1, 2, 0, 0, 0]);
        // An anchor-1 node already in class 0 stays class 0, and its chain is not walked.
        assign_priorities(&mut nodes, &[vec![2], vec![3, 0]]);
        assert_eq!(classes(&nodes), vec![1, 2, 0, 0, 0]);
        // The chain follows the first non-missing parent, Indirect included: 0 → [missing, 2 (ind)].
        let mut nodes = chain(&[&[(None, M), (Some(2), I)], &[(Some(2), D)], &[]]);
        assign_priorities(&mut nodes, &[vec![], vec![0]]);
        assert_eq!(classes(&nodes), vec![1, 2, 1]);
    }
}
