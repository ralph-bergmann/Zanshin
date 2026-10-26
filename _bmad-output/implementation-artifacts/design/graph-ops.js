// Pure graph operations for the prototype. Each mirrors one jj command; none mutates its input.
// all = commit list (parents by id) · diffs = { [changeId]: [{ path, status, hunks: [{ id, oldStart, newStart, ctx, lines: [{ k, s }] }] }] }
(function () {
  const uniq = (a) => [...new Set(a)];
  const undescribed = (c) => !c.description && /^\(no description/.test(c.subject || "");
  const rnd = () => Math.floor(Math.random() * 0xffffffff).toString(16).padStart(8, "0");

  function descendants(all, id) {
    const out = new Set(), st = [id];
    while (st.length) { const x = st.pop(); all.forEach(k => { if (k.parents.includes(x) && !out.has(k.id)) { out.add(k.id); st.push(k.id); } }); }
    return out;
  }
  function ancestors(all, id) {
    const M = new Map(all.map(c => [c.id, c])), out = new Set(), st = [...((M.get(id) || {}).parents || [])];
    while (st.length) { const x = st.pop(); if (out.has(x)) continue; out.add(x); const c = M.get(x); if (c) st.push(...c.parents); }
    return out;
  }
  // take a change out of its place: its children move onto its parents
  function detach(all, id) {
    const src = all.find(c => c.id === id);
    return all.map(c => c.parents.includes(id) ? { ...c, parents: uniq(c.parents.flatMap(x => x === id ? src.parents : [x])) } : c);
  }
  const setParents = (all, id, parents) => all.map(c => c.id === id ? { ...c, parents, isMerge: parents.length > 1 } : c);
  const blank = (id, parents, base = {}) => ({
    id, changeId: id, commitId: rnd(), parents, subject: "(no description set)", description: "", author: "Ralph Stein", date: "now",
    ts: window.GRAPH_NOW, priority: base.priority || 0, bookmarks: [], files: [], immutable: false, inDefault: true, isEmpty: true,
    isWorkingCopy: false, hasConflict: false, isMerge: parents.length > 1, stats: { added: 0, removed: 0, files: 0 },
  });

  // ---------- diffs ----------
  function count(files) {
    let a = 0, r = 0;
    files.forEach(f => f.hunks.forEach(h => h.lines.forEach(l => { if (l.k === "+") a++; else if (l.k === "-") r++; })));
    return { added: a, removed: r, files: files.length };
  }
  const hunkStat = (h) => h.lines.reduce((s, l) => (l.k === "+" ? s.a++ : l.k === "-" ? s.r++ : 0, s), { a: 0, r: 0 });
  function restat(all, diffs, ids) {
    return all.map(c => ids.includes(c.id) && diffs[c.id] ? { ...c, stats: count(diffs[c.id]), isEmpty: !diffs[c.id].length && !c.isMerge } : c);
  }
  function take(files, ids) {
    const set = new Set(ids), taken = [], rest = [];
    files.forEach(f => {
      const tk = f.hunks.filter(h => set.has(h.id)), keep = f.hunks.filter(h => !set.has(h.id));
      if (tk.length) taken.push({ ...f, hunks: tk, status: keep.length && f.status === "A" ? "M" : f.status });
      if (keep.length) rest.push({ ...f, hunks: keep });
    });
    return { taken, rest };
  }
  function give(files, add) {
    const out = files.map(f => ({ ...f, hunks: [...f.hunks] }));
    add.forEach(a => {
      const f = out.find(x => x.path === a.path);
      if (f) { f.hunks.push(...a.hunks); f.hunks.sort((p, q) => p.newStart - q.newStart); if (f.status === "D" || a.status === "M") f.status = "M"; }
      else out.push({ ...a, hunks: [...a.hunks] });
    });
    return out;
  }
  const allHunks = (files) => files.flatMap(f => f.hunks.map(h => h.id));
  // the inverse of a diff (jj revert): + and − swap, added and deleted files swap; within a run, removals stay ahead of additions
  const FLIP = { A: "D", D: "A" };
  function invert(files) {
    return files.map(f => ({ ...f, status: FLIP[f.status] || f.status, hunks: f.hunks.map(h => {
      const lines = [], run = [], out = () => { lines.push(...run.filter(l => l.k === "-"), ...run.filter(l => l.k === "+")); run.length = 0; };
      h.lines.forEach(l => { if (l.k === "+" || l.k === "-") run.push({ ...l, k: l.k === "+" ? "-" : "+" }); else { out(); lines.push(l); } });
      out();
      return { ...h, id: window.newHunkId(), oldStart: h.newStart, newStart: h.oldStart, lines };
    }) }));
  }

  // ---------- jj commands ----------
  const Ops = {
    descendants, ancestors, detach, blank, count, hunkStat, allHunks, undescribed, invert,

    // jj rebase -s id -o dest (descendants follow) · -r: only id, its children close the gap
    rebase(all, id, dest, mode) { return setParents(mode === "r" ? detach(all, id) : all, id, [dest]); },
    // jj rebase -r id -A dest — id goes between dest and dest's children
    insertAfter(all, id, dest) {
      const next = detach(all, id).map(c => c.id !== id && c.parents.includes(dest) ? { ...c, parents: uniq(c.parents.map(x => x === dest ? id : x)) } : c);
      return setParents(next, id, [dest]);
    },
    // jj rebase -r id -B dest — id goes between dest and dest's parents
    insertBefore(all, id, dest) {
      let next = detach(all, id);
      const d = next.find(c => c.id === dest);
      next = setParents(next, id, [...d.parents]);
      return setParents(next, dest, [id]);
    },
    // jj squash --from id --into dest [hunks] — an emptied, undescribed source is abandoned; @ stays as an empty change
    squash(all, diffs, id, dest, hunkIds) {
      const src = all.find(c => c.id === id), into = all.find(c => c.id === dest);
      const ids = hunkIds || allHunks(diffs[id] || []);
      const { taken, rest } = take(diffs[id] || [], ids);
      const D = { ...diffs, [id]: rest, [dest]: give(diffs[dest] || [], taken) };
      let next = restat(all, D, [id, dest]);
      const whole = !hunkIds;
      if (whole && undescribed(into) && !undescribed(src)) next = next.map(c => c.id === dest ? { ...c, subject: src.subject, description: src.description } : c);
      const gone = !rest.length && !src.isWorkingCopy && (whole || undescribed(src));
      if (gone) {
        next = detach(next, id).filter(c => c.id !== id);
        if (src.bookmarks.length) next = next.map(c => c.id === dest ? { ...c, bookmarks: [...c.bookmarks, ...src.bookmarks] } : c);
        delete D[id];
      }
      return { all: next, diffs: D, gone };
    },
    // jj duplicate id -o dest
    duplicate(all, diffs, id, dest, nid) {
      const s = all.find(c => c.id === id), d = all.find(c => c.id === dest);
      const n = { ...s, id: nid, changeId: nid, commitId: rnd(), parents: [dest], bookmarks: [], isWorkingCopy: false, immutable: false, inDefault: true, isMerge: false, priority: d.priority || s.priority, ts: window.GRAPH_NOW, date: "now" };
      const files = (diffs[id] || []).map(f => ({ ...f, hunks: f.hunks.map(h => ({ ...h, id: window.newHunkId() })) }));
      return { all: [...all, n], diffs: { ...diffs, [nid]: files } };
    },
    // jj new a b — a new, empty merge change; it becomes @
    mergeNew(all, diffs, a, b, nid) {
      const pa = all.find(c => c.id === a);
      return { all: [...all, blank(nid, [a, b], pa)], diffs: { ...diffs, [nid]: [] } };
    },
    // jj bookmark move name --to dest [--allow-backwards]
    moveBookmark(all, name, from, to) {
      const bm = (all.find(c => c.id === from) || { bookmarks: [] }).bookmarks.find(b => b.name === name);
      if (!bm) return all;
      const fwd = descendants(all, from).has(to), back = ancestors(all, from).has(to);
      const tracked = bm.state !== "local";
      const state = !tracked ? "local" : bm.state === "synced" ? (fwd ? "ahead" : back ? "behind" : "diverged") : (fwd && bm.state === "ahead" ? "ahead" : "diverged");
      const moved = { ...bm, state, ahead: fwd ? (bm.ahead || 0) + 1 : undefined };
      return all.map(c => c.id === from ? { ...c, bookmarks: c.bookmarks.filter(b => b.name !== name) } : c)
        .map(c => c.id === to ? { ...c, bookmarks: [...c.bookmarks, moved] } : c);
    },
    // jj split -r id (-A|-B|-o) dest [-m msg] — the selection becomes a new change at that place; the rest stays put
    splitTo(all, diffs, id, hunkIds, where, dest, nid, msg) {
      const s = all.find(c => c.id === id), d = all.find(c => c.id === dest);
      const { taken, rest } = take(diffs[id] || [], hunkIds);
      const n = { ...blank(nid, where === "B" ? [...d.parents] : [dest], d), isEmpty: false };
      if (msg) { n.subject = msg.split("\n")[0]; n.description = msg.split("\n").slice(1).join("\n").trim(); }
      let next = [...all, n];
      if (where === "A") next = next.map(c => c.id !== nid && c.parents.includes(dest) ? { ...c, parents: c.parents.map(x => x === dest ? nid : x) } : c);
      if (where === "B") next = setParents(next, dest, [nid]);
      const D = { ...diffs, [id]: rest, [nid]: taken };
      next = restat(next, D, [id, nid]);
      if (!rest.length && !s.isWorkingCopy && undescribed(s)) { next = detach(next, id).filter(c => c.id !== id); delete D[id]; }
      return { all: next, diffs: D };
    },
    // jj split -r id [-m msg] — selected stay in id (and get msg); the rest moves to a new child that keeps the old description.
    // bookmarks and @ move forward to the child
    split(all, diffs, id, hunkIds, nid, msg) {
      const s = all.find(c => c.id === id);
      const { taken, rest } = take(diffs[id] || [], hunkIds);
      const kid = { ...blank(nid, [id], s), subject: s.subject, description: s.description, bookmarks: s.bookmarks, isEmpty: !rest.length, isWorkingCopy: s.isWorkingCopy };
      let next = all.map(c => c.parents.includes(id) ? { ...c, parents: c.parents.map(x => x === id ? nid : x) } : c)
        .map(c => c.id === id ? { ...c, bookmarks: [], isWorkingCopy: false, ...(msg != null ? { subject: msg.split("\n")[0] || "(no description set)", description: msg.split("\n").slice(1).join("\n").trim() } : {}) } : c);
      next = [...next, kid];
      const D = { ...diffs, [id]: taken, [nid]: rest };
      return { all: restat(next, D, [id, nid]), diffs: D, wc: s.isWorkingCopy ? nid : undefined };
    },
    // jj commit -m msg [paths] — selected stay in @ with the description, the rest moves to a new @ on top; bookmarks stay
    commit(all, diffs, id, hunkIds, nid, msg) {
      const s = all.find(c => c.id === id);
      const { taken, rest } = take(diffs[id] || [], hunkIds);
      const wc = { ...blank(nid, [id], s), isEmpty: !rest.length };
      let next = all.map(c => c.parents.includes(id) ? { ...c, parents: c.parents.map(x => x === id ? nid : x) } : c)
        .map(c => c.id === id ? { ...c, subject: (msg || "").split("\n")[0] || "(no description set)", description: (msg || "").split("\n").slice(1).join("\n").trim(), date: "now", ts: window.GRAPH_NOW } : c);
      next = [...next, wc];
      const D = { ...diffs, [id]: taken, [nid]: rest };
      return { all: restat(next, D, [id, nid]), diffs: D, wc: nid };
    },
    // jj describe id -m msg
    describe(all, id, subject, description) {
      return all.map(c => c.id === id ? { ...c, subject: subject.trim() || "(no description set)", description: (description || "").trim() } : c);
    },
    // jj abandon id — children move onto its parents, its bookmarks are deleted; abandoning @ leaves a fresh empty @ behind
    abandon(all, diffs, id, nid) {
      const s = all.find(c => c.id === id);
      let next = detach(all, id).filter(c => c.id !== id);
      const D = { ...diffs }; delete D[id];
      if (s.isWorkingCopy) { next = [...next, blank(nid, [...s.parents], s)]; D[nid] = []; return { all: next, diffs: D, wc: nid }; }
      return { all: next, diffs: D };
    },
    // jj revert -r id -B wc — a new change with id's inverse diff slots in between @ and its parents; @ keeps its own diff on top
    revert(all, diffs, id, wc, nid) {
      const s = all.find(c => c.id === id), w = all.find(c => c.id === wc);
      const n = { ...blank(nid, [...w.parents], w), subject: 'Revert "' + (undescribed(s) ? "" : s.subject) + '"', description: "This reverts commit " + (s.commitId || s.id) + "." };
      const D = { ...diffs, [nid]: invert(diffs[id] || []) };
      return { all: restat(setParents([...all, n], wc, [nid]), D, [nid]), diffs: D };
    },
  };
  window.GraphOps = Ops;
})();
