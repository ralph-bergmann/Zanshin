//! Seeded, deterministic synthetic repo generator (docs/graph-layout.md §8.1: fills the scale points, the
//! branchy shape of ≥ 100 lanes and the ≥ 1 % non-monotonic edges the fixtures lack).
//!
//! It simulates a repo commit by commit (integer arithmetic only, own splitmix64 PRNG, no hash
//! iteration, so a seed gives the same bytes on every machine):
//! - a trunk with direct commits and merges;
//! - feature branches of 1-40 commits that fork from trunk (sometimes from an older trunk
//!   commit or stacked on another feature), occasionally merge trunk in, and end merged back
//!   (62 %), in an octopus merge of 3-5 tips (6 %), or open (32 %);
//! - bursts in which ~160 features are in flight at once (the branchy shape);
//! - a long-lived `develop` that merges trunk in and is merged into trunk now and then;
//! - release branches that fork off trunk, get backports for a long while, and stay open;
//! - a few extra roots (independent histories: one off `root()`, the others with a Missing
//!   edge, as if their bottom were outside the revset), one of them merged into trunk;
//! - timestamps from a global clock with realistic gaps (minutes .. nights .. holidays); 2 % of
//!   commits get a committer time BELOW all their parents (clock skew) to exercise the clamp.
//!
//! The graph is then filtered like a revset would: ~1.5 % of the plain linear commits are
//! hidden, so their child gets an `indirect` edge to the nearest visible ancestor, and 3 % of
//! merges get an extra `missing` parent (first or last). Output order is reverse creation
//! order (children first; a valid topological order, but NOT jj's `TopoGroupedGraph` order).

use std::collections::VecDeque;

use crate::input::{assign_priorities, Input, Kind, Node, Parent};

pub struct Params {
    /// Commits to create (the output is ~1.5 % smaller after hiding).
    pub commits: usize,
    pub seed: u64,
    pub utc_offset_min: i64,
    /// Permille ranges of the run in which ~160 features are in flight.
    pub bursts: &'static [(usize, usize)],
}

#[derive(Default, Debug)]
pub struct Stats {
    pub max_in_flight: usize,
    pub hidden: usize,
    pub releases: usize,
    pub octopus_merges: usize,
}

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
    /// Uniform in `lo..=hi`.
    fn range(&mut self, lo: i64, hi: i64) -> i64 {
        lo + (self.next() % (hi - lo + 1) as u64) as i64
    }
    fn permille(&mut self, p: usize) -> bool {
        self.below(1000) < p
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum P {
    C(usize),
    Missing,
}

struct Commit {
    parents: Vec<P>,
    ts: Option<i64>,
}

#[derive(Clone, Copy)]
enum Fate {
    Merge,
    Octopus,
    Open,
}

struct Feature {
    tip: usize,
    remaining: u32,
    fate: Fate,
}

struct Side {
    tip: usize,
    until: usize,
    merge_back: bool,
}

/// `now_ms` of every synthetic input: 2026-09-25T14:00:00Z, the design's `GRAPH_NOW`. The clock
/// starts at 0 and all timestamps are shifted at the end so the newest commit lies 5 min
/// before it (a run spans ~1 year per 10k commits).
const NOW: i64 = 1_790_344_800_000;
const MIN: i64 = 60_000;
const HOUR: i64 = 60 * MIN;
const DAY: i64 = 24 * HOUR;

struct Sim {
    rng: Rng,
    commits: Vec<Commit>,
    clock: i64,
    trunk: usize,
    trunk_recent: VecDeque<usize>,
    features: Vec<Feature>,
    octopus: Vec<usize>,
    octopus_goal: usize,
    develop: Option<usize>,
    releases: Vec<Side>,
    orphans: Vec<Side>,
    stats: Stats,
}

impl Sim {
    /// Global clock gap before the next commit: mean ~45 min.
    fn gap(&mut self) -> i64 {
        let r = self.rng.below(1000);
        let ms = match r {
            0..600 => self.rng.range(0, 10 * MIN),
            600..900 => self.rng.range(10 * MIN, HOUR),
            900..980 => self.rng.range(HOUR, 4 * HOUR),
            980..998 => self.rng.range(8 * HOUR, 16 * HOUR),
            _ => self.rng.range(DAY, 4 * DAY),
        };
        ms + self.rng.range(0, 999)
    }

    fn commit(&mut self, mut parents: Vec<P>) -> usize {
        self.clock += self.gap();
        let mut ts = self.clock;
        let oldest_parent = parents
            .iter()
            .filter_map(|p| match p {
                P::C(i) => self.commits[*i].ts,
                P::Missing => None,
            })
            .min();
        if let Some(pt) = oldest_parent {
            if self.rng.permille(20) {
                ts = pt - self.rng.range(1_000, 2 * DAY);
            }
        }
        if parents.len() >= 2 && self.rng.permille(30) {
            if self.rng.permille(500) {
                parents.insert(0, P::Missing);
            } else {
                parents.push(P::Missing);
            }
        }
        self.commits.push(Commit { parents, ts: Some(ts) });
        self.commits.len() - 1
    }

    fn trunk_commit(&mut self, mut parents: Vec<P>) {
        parents.insert(0, P::C(self.trunk));
        self.trunk = self.commit(parents);
        self.trunk_recent.push_back(self.trunk);
        if self.trunk_recent.len() > 64 {
            self.trunk_recent.pop_front();
        }
    }

    fn start_feature(&mut self) {
        let r = self.rng.below(100);
        let base = if r < 80 {
            self.trunk
        } else if r < 95 {
            self.trunk_recent[self.rng.below(self.trunk_recent.len())]
        } else if !self.features.is_empty() {
            self.features[self.rng.below(self.features.len())].tip
        } else {
            self.trunk
        };
        let len = if self.rng.permille(300) { self.rng.range(1, 40) } else { self.rng.range(1, 8) };
        let fate = match self.rng.below(100) {
            0..62 => Fate::Merge,
            62..68 => Fate::Octopus,
            _ => Fate::Open,
        };
        let tip = self.commit(vec![P::C(base)]);
        self.features.push(Feature { tip, remaining: len as u32 - 1, fate });
        self.stats.max_in_flight = self.stats.max_in_flight.max(self.features.len());
    }

    fn advance_feature(&mut self) {
        let k = self.rng.below(self.features.len());
        if self.features[k].remaining == 0 {
            let f = self.features.swap_remove(k);
            match f.fate {
                Fate::Merge => self.trunk_commit(vec![P::C(f.tip)]),
                Fate::Octopus => {
                    if self.octopus.is_empty() {
                        self.octopus_goal = self.rng.range(3, 5) as usize;
                    }
                    self.octopus.push(f.tip);
                    if self.octopus.len() >= self.octopus_goal {
                        let tips: Vec<P> = self.octopus.drain(..).map(P::C).collect();
                        self.trunk_commit(tips);
                        self.stats.octopus_merges += 1;
                    }
                }
                Fate::Open => {}
            }
            return;
        }
        let tip = self.features[k].tip;
        let parents = if self.rng.permille(30) { vec![P::C(tip), P::C(self.trunk)] } else { vec![P::C(tip)] };
        let new_tip = self.commit(parents);
        let f = &mut self.features[k];
        f.tip = new_tip;
        f.remaining -= 1;
    }

    fn develop_step(&mut self) {
        let Some(d) = self.develop else {
            self.trunk_commit(vec![]);
            return;
        };
        match self.rng.below(100) {
            0..8 => self.develop = Some(self.commit(vec![P::C(d), P::C(self.trunk)])),
            8..12 => self.trunk_commit(vec![P::C(d)]),
            _ => self.develop = Some(self.commit(vec![P::C(d)])),
        }
    }

    /// One commit on a random still-live side branch (release or orphan history).
    fn side_step(&mut self, orphan: bool) {
        let now = self.commits.len();
        let list = if orphan { &self.orphans } else { &self.releases };
        let live: Vec<usize> = (0..list.len()).filter(|&i| list[i].until > now).collect();
        if live.is_empty() {
            self.trunk_commit(vec![]);
            return;
        }
        let k = live[self.rng.below(live.len())];
        let tip = if orphan { self.orphans[k].tip } else { self.releases[k].tip };
        let new_tip = self.commit(vec![P::C(tip)]);
        if orphan {
            self.orphans[k].tip = new_tip;
        } else {
            self.releases[k].tip = new_tip;
        }
    }
}

pub fn generate(p: &Params) -> (Input, Stats) {
    let mut sim = Sim {
        rng: Rng(p.seed),
        commits: vec![Commit { parents: vec![], ts: None }], // 0 = root()
        clock: 0,
        trunk: 0,
        trunk_recent: VecDeque::new(),
        features: Vec::new(),
        octopus: Vec::new(),
        octopus_goal: 3,
        develop: None,
        releases: Vec::new(),
        orphans: Vec::new(),
        stats: Stats::default(),
    };
    sim.trunk_commit(vec![]); // the first commit, off root()
    let target = p.commits;
    let mut next_release = 100usize; // permille
    let mut orphan_at: VecDeque<usize> = VecDeque::from([150, 500, 850]);

    while sim.commits.len() < target - 1 {
        let permille = sim.commits.len() * 1000 / target;
        let now = sim.commits.len();

        // Scheduled structure.
        if sim.develop.is_none() && permille >= 20 {
            sim.develop = Some(sim.commit(vec![P::C(sim.trunk)]));
            continue;
        }
        if permille >= next_release {
            let tip = sim.commit(vec![P::C(sim.trunk)]);
            let until = now + sim.rng.range(target as i64 / 20, target as i64 / 8) as usize;
            sim.releases.push(Side { tip, until, merge_back: false });
            sim.stats.releases += 1;
            next_release += sim.rng.range(90, 130) as usize;
            continue;
        }
        if orphan_at.front().is_some_and(|&at| permille >= at) {
            orphan_at.pop_front();
            let first = sim.orphans.is_empty();
            let parent = if first { P::C(0) } else { P::Missing };
            let tip = sim.commit(vec![parent]);
            let until = now + sim.rng.range(target as i64 / 200, target as i64 / 50) as usize;
            sim.orphans.push(Side { tip, until, merge_back: first });
            continue;
        }
        if let Some(k) = sim.orphans.iter().position(|o| o.merge_back && o.until <= now) {
            let tip = sim.orphans[k].tip;
            sim.orphans[k].merge_back = false;
            sim.trunk_commit(vec![P::C(tip)]);
            continue;
        }

        let in_burst = p.bursts.iter().any(|&(a, b)| (a..b).contains(&permille));
        let in_flight_target = if in_burst { 160 } else { 12 };
        match sim.rng.below(1000) {
            0..300 if sim.features.len() < in_flight_target => sim.start_feature(),
            300..400 => sim.trunk_commit(vec![]),
            400..430 => sim.develop_step(),
            430..440 => sim.side_step(false),
            440..450 => sim.side_step(true),
            _ if sim.features.is_empty() => sim.trunk_commit(vec![]),
            _ => sim.advance_feature(),
        }
    }

    // @: an empty change on top of the most recently touched open feature (else on trunk).
    let wc_base = sim.features.iter().map(|f| f.tip).max().unwrap_or(sim.trunk);
    let wc = sim.commit(vec![P::C(wc_base)]);
    // `commit` may attach a Missing parent only to merges, so @ keeps exactly one parent.

    let (input, hidden) = emit(&mut sim, p, wc);
    sim.stats.hidden = hidden;
    (input, sim.stats)
}

/// Hides ~1.5 % of the plain linear commits, then writes the visible ones children-first.
fn emit(sim: &mut Sim, p: &Params, wc: usize) -> (Input, usize) {
    let n = sim.commits.len();
    let mut child_count = vec![0u32; n];
    let mut only_child = vec![usize::MAX; n];
    for (i, c) in sim.commits.iter().enumerate() {
        for par in &c.parents {
            if let P::C(q) = *par {
                child_count[q] += 1;
                only_child[q] = i;
            }
        }
    }
    // Eligible: one parent entry (a real commit), one child, and that child has one parent
    // entry — so hiding creates exactly one indirect edge and never a transitive duplicate.
    let mut hidden = vec![false; n];
    for i in 1..n {
        let c = &sim.commits[i];
        let eligible = i != sim.trunk
            && i != wc
            && matches!(c.parents.as_slice(), [P::C(_)])
            && child_count[i] == 1
            && sim.commits[only_child[i]].parents.len() == 1;
        if eligible && sim.rng.permille(15) {
            hidden[i] = true;
        }
    }

    let mut new_idx = vec![usize::MAX; n];
    let mut next = 0;
    for i in (0..n).rev() {
        if !hidden[i] {
            new_idx[i] = next;
            next += 1;
        }
    }
    let shift = NOW - 5 * MIN - sim.commits.iter().filter_map(|c| c.ts).max().expect("commits have ts");
    let mut nodes = Vec::with_capacity(next);
    for i in (0..n).rev() {
        if hidden[i] {
            continue;
        }
        let c = &sim.commits[i];
        let parents = c
            .parents
            .iter()
            .map(|par| match *par {
                P::Missing => Parent { idx: None, kind: Kind::Missing },
                P::C(q) if !hidden[q] => Parent { idx: Some(new_idx[q]), kind: Kind::Direct },
                P::C(mut q) => {
                    while hidden[q] {
                        let P::C(down) = sim.commits[q].parents[0] else { unreachable!("hidden has a real parent") };
                        q = down;
                    }
                    Parent { idx: Some(new_idx[q]), kind: Kind::Indirect }
                }
            })
            .collect();
        nodes.push(Node {
            id: synth_id(p.seed, i),
            ts_ms: c.ts.map(|t| t + shift),
            is_root: i == 0,
            priority: 2,
            parents,
        });
    }
    assign_priorities(&mut nodes, &[vec![new_idx[sim.trunk]], vec![new_idx[wc]]]);
    let hidden_count = hidden.iter().filter(|&&h| h).count();
    (Input { now_ms: NOW, utc_offset_min: p.utc_offset_min, nodes }, hidden_count)
}

/// A 40-hex fake commit id; the root gets jj's all-zero id.
fn synth_id(seed: u64, i: usize) -> String {
    if i == 0 {
        return "0".repeat(40);
    }
    let mut r = Rng(seed ^ (i as u64).wrapping_mul(0xD6E8_FEB8_6659_FD93));
    format!("{:016x}{:016x}{:08x}", r.next(), r.next(), r.next() as u32)
}
