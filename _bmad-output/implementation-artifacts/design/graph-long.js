// A long history for the long-history design (sync #22, Story 10.31): ?history=long puts seven years of an older,
// mostly linear project below the sample graph — busy phases with release bookmarks (they break stacks) and quiet
// phases with no ref at all (they collapse into long stacks, like the 486-change stack of dart-intellij-third-party),
// plus one side branch merged back. Deterministic; every commit immutable and in the default view.
(function () {
  if (new URLSearchParams(location.search).get("history") !== "long") return;
  let seed = 20131;
  const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  const taken = new Set(window.GRAPH_COMMITS.map(c => c.id));
  const newId = () => { const a = "kmnopqrstuvwxyz"; let s; do { s = ""; for (let i = 0; i < 8; i++) s += a[Math.floor(rnd() * a.length)]; } while (taken.has(s)); taken.add(s); return s; };
  const hex = () => Math.floor(rnd() * 0xffffffff).toString(16).padStart(8, "0");
  const AUTHORS = ["Alice", "Bob", "Charlie", "Lena König", "Ralph Stein"];
  const WHAT = ["fix(sync): retry on 409", "refactor(api): split the client", "perf: cache page cursors", "docs: update the README",
    "feat(settings): remember the last tab", "chore(deps): bump the SDK", "fix(ios): account for the safe area", "test: cover the parser",
    "feat(search): match change ids", "chore: format", "fix(graph): a stale lane", "build: drop the old target"];
  const iso = (t) => new Date(t).toISOString().slice(0, 16);
  const out = [];
  const make = (t, parents, extra) => {
    const added = Math.floor(rnd() * 120), removed = Math.floor(rnd() * 60), files = 1 + Math.floor(rnd() * 6);
    const c = {
      id: newId(), commitId: hex(), parents, subject: WHAT[Math.floor(rnd() * WHAT.length)], author: AUTHORS[Math.floor(rnd() * AUTHORS.length)],
      ts: iso(t), date: new Date(t).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }),
      bookmarks: [], files: [], description: "", priority: 0, immutable: true, inDefault: true, isEmpty: false, isWorkingCopy: false,
      hasConflict: false, stats: { added, removed, files }, ...extra,
    };
    c.changeId = c.id; c.isMerge = c.parents.length > 1;
    out.push(c);
    return c;
  };
  // phases: [from, to, commits, a release bookmark every n commits (0: none — one long stack)]
  const PHASES = [["2019-03-04", "2019-12-18", 70, 18], ["2020-01-13", "2021-01-29", 60, 0], ["2021-02-15", "2025-02-27", 240, 0],
    ["2025-03-10", "2025-11-20", 80, 20], ["2025-12-01", "2026-08-28", 70, 0]];
  let head = "zzzzzzzz", rel = 0;
  PHASES.forEach(([from, to, n, every], p) => {
    const t0 = Date.parse(from + "T09:00"), t1 = Date.parse(to + "T18:00");
    const ts = Array.from({ length: n }, () => t0 + rnd() * (t1 - t0)).sort((a, b) => a - b);
    ts.forEach((t, i) => {
      const bm = every && (i + 1) % every === 0 ? [{ name: "v1." + rel++, state: "local" }] : [];
      head = make(t, [head], { bookmarks: bm }).id;
      // the first busy phase forks a side branch that merges back a few weeks later
      if (p === 0 && i === 30) {
        const fork = head;
        let side = fork;
        for (let k = 1; k <= 5; k++) side = make(t + k * 2.6e8, [side], { subject: "feat(sync): offline queue, part " + k }).id;
        window.__longMerge = { fork, side };
      }
      if (p === 0 && i === 42 && window.__longMerge) head = make(t + 3.6e6, [head, window.__longMerge.side], { subject: "merge: offline queue" }).id;
    });
  });
  const first = window.GRAPH_COMMITS.find(c => c.id === "qpvuntsm");
  if (first) first.parents = [head];
  window.GRAPH_COMMITS = [window.GRAPH_COMMITS[0], ...out, ...window.GRAPH_COMMITS.slice(1)];
})();
