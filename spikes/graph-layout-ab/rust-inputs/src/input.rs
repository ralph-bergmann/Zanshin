//! The layout INPUT of SPEC.md §2: model, validation (V1-V4), the §2 `priority` stand-in, and
//! the canonical writer (keys in spec order, no whitespace, one trailing `\n`).

use std::fmt::Write as _;
use std::path::Path;

/// Every integer in a file must survive a JS double (SPEC.md §1).
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
    /// V1-V4 of SPEC.md §2. V3 is read as "no two NON-NULL idx": jj can yield several Missing
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

    /// The canonical form (SPEC.md §2 "Producers write the canonical form of §3").
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

/// The first layout parent: the first non-missing edge (SPEC.md §4.1 fp).
pub fn first_layout_parent(node: &Node) -> Option<usize> {
    node.parents.iter().find(|p| p.kind != Kind::Missing).and_then(|p| p.idx)
}

/// SPEC.md §2 priority stand-in: 0 = `trunk` and its first-parent chain; 1 = `wc` (@) and its
/// first-parent chain up to the first class-0 node; 2 = everything else. An anchor that is
/// not in the graph (`None`) leaves its class empty.
pub fn assign_priorities(nodes: &mut [Node], trunk: Option<usize>, wc: Option<usize>) {
    let mut class = vec![2u32; nodes.len()];
    let mut cur = trunk;
    while let Some(c) = cur {
        class[c] = 0;
        cur = first_layout_parent(&nodes[c]);
    }
    let mut cur = wc;
    while let Some(c) = cur {
        if class[c] == 0 {
            break;
        }
        class[c] = 1;
        cur = first_layout_parent(&nodes[c]);
    }
    for (node, c) in nodes.iter_mut().zip(class) {
        node.priority = c;
    }
}
