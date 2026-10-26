// Immutable commits — the kit's mock of revset-aliases."immutable_heads()" (the floating client's immutable.jsx). The page itself is the design
// system's ImmutablePage; this file only evaluates a config over the sample repo: the heads, each change's reason (a head names itself, what
// lies below it says "below …"; the first term wins), the heads by name for the Result line, and the custom terms the preview can't read.
(() => {
  const P = (c) => [...c.parents, ...(c.gapParents || [])];
  function ancestorsOf(M, id) {
    const out = new Set(), st = [...P(M.get(id) || { parents: [] })];
    while (st.length) { const x = st.pop(); if (out.has(x)) continue; out.add(x); const c = M.get(x); if (c) st.push(...P(c)); }
    return out;
  }
  // bookmark / tag names, change ids, author(), description(), mine() are previewed; jj evaluates the rest
  function customHeads(all, text, me) {
    const list = [], unknown = [];
    const val = (s) => s.replace(/^(substring|exact|glob):/, "").replace(/^["']|["']$/g, "");
    String(text || "").split("|").map((s) => s.trim().replace(/^\((.*)\)$/, "$1").trim()).filter(Boolean).forEach((t) => {
      let m, hit = null;
      if ((m = t.match(/^(author|description)\((.*)\)$/))) {
        const raw = m[2].trim(), v = val(raw).toLowerCase(), glob = /^glob:/.test(raw);
        const re = glob && new RegExp("^" + v.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$", "s");
        const test = (s) => { s = (s || "").toLowerCase(); return re ? re.test(s) : s.includes(v); };
        hit = all.filter((x) => test(m[1] === "author" ? x.author : x.subject + (x.description ? "\n" + x.description : "")));
      } else if (t === "mine()") hit = all.filter((x) => x.author === me);
      else {
        const n = val(t), named = all.filter((x) => x.bookmarks.some((b) => b.name === n) || (x.tags || []).includes(n));
        if (named.length) hit = named;
        else if (/^[k-z]{3,}$/.test(n)) { const p = all.filter((x) => x.id.startsWith(n)); if (p.length === 1) hit = p; }
      }
      if (hit) list.push(...hit); else unknown.push(t);
    });
    return { list, unknown };
  }
  function evaluate(all, c, trunkName, me) {
    const M = new Map(all.map((x) => [x.id, x])), heads = [], names = [];
    const head = (x, at, below, name) => { heads.push({ id: x.id, at, below }); if (name && !names.includes(name)) names.push(name); };
    const trunkC = all.find((x) => x.bookmarks.some((b) => b.name === trunkName));
    if (c.trunk && trunkC) head(trunkC, "trunk() · " + trunkName, "below trunk() · " + trunkName, trunkName);
    if (c.tags) all.forEach((x) => (x.tags || []).forEach((t) => head(x, "tag " + t, "below tag " + t, t)));
    if (c.remoteBookmarks) all.forEach((x) => x.bookmarks.forEach((b) => { if (b.state === "remote") head(x, b.name + ", not tracked", "below " + b.name + ", not tracked", b.name); }));
    (c.bookmarks || []).forEach((n) => all.forEach((x) => { if (x.bookmarks.some((b) => b.name === n)) head(x, n, "below " + n, n); }));
    let others = 0;
    if (c.others) {
      const inTrunk = trunkC ? new Set([trunkC.id, ...ancestorsOf(M, trunkC.id)]) : new Set();
      all.forEach((x) => { if (x.author && x.author !== me && !inTrunk.has(x.id)) { others++; head(x, "by " + x.author + ", not you", "below a change by " + x.author); } });
    }
    const cu = customHeads(all, c.custom, me);
    cu.list.forEach((x) => head(x, "your custom revset", "below your custom revset"));
    if (cu.list.length) names.push("custom revset");
    if (others) names.push(others + (others === 1 ? " change" : " changes") + " by others");
    const why = new Map();
    heads.forEach((h) => { if (!why.has(h.id)) why.set(h.id, h.at); });
    heads.forEach((h) => ancestorsOf(M, h.id).forEach((a) => { if (!why.has(a) && M.has(a)) why.set(a, h.below); }));
    return { why, count: why.size, heads: names, unknown: cu.unknown };
  }
  // the changes with `immutable` / `immWhy` per the config — the same array when nothing changes
  function apply(all, c, trunkName, me) {
    const { why } = evaluate(all, c, trunkName, me);
    let changed = false;
    const next = all.map((x) => {
      const imm = why.has(x.id), w = why.get(x.id);
      if (!!x.immutable === imm && x.immWhy === w) return x;
      changed = true;
      return { ...x, immutable: imm, immWhy: w };
    });
    return changed ? next : all;
  }
  window.ZK_IMM = { evaluate, apply };
})();
