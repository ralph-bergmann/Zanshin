// App — repository state and jj operations (new · edit · describe · squash · revert · abandon · commit · split · rebase by drag · undo),
// direct manipulation (drag a change, bookmark, file or hunk onto a change), calm scrolling, and the floating composition.
(() => {
const { AtPill, Menu, DropMenu, DragGhost, Toast, ChangeId, RevsetDialog, PushDialog, ResizeEdge, HatchSwatch, ImmutablePage } = window.ZanshinDesignSystem_a33847;
const Swatch = HatchSwatch || (() => null);
// Settings › Project › Immutable commits starts at jj's default: builtin_immutable_heads()
const IMM0 = { ...((ImmutablePage && ImmutablePage.defaults) || { trunk: true, tags: true, remoteBookmarks: true, remoteTags: true, others: false, bookmarks: [], custom: "" }) };
// TOP = --chrome-top on the macOS 27 reference geometry (bar centred on the traffic lights at y 26: 26 + 22 + 12)
const EDGE = 12, TOP = 60, RAIL_R = 76, PANEL_W = 300, DETAIL_W = 460, MINI = 146;
const s8 = (id) => id.slice(0, 8);
const short = (name) => { const m = name.match(/[A-Z][A-Z0-9]+-\d+/); return m ? m[0] : name.split("/").pop(); };

function zkNewId(taken) { const a = "kmnopqrstuvwxyz"; let s; do { s = ""; for (let i = 0; i < 8; i++) s += a[Math.floor(Math.random() * a.length)]; } while (taken.has(s)); return s; }
const hex = () => Math.floor(Math.random() * 0xffffffff).toString(16).padStart(8, "0");

// ---------- pure graph operations ----------
const P = (c) => [...c.parents, ...c.gapParents];
const O = {
  desc(cs, id) { const s = new Set(), st = [id]; while (st.length) { const x = st.pop(); cs.forEach((c) => { if (P(c).includes(x) && !s.has(c.id)) { s.add(c.id); st.push(c.id); } }); } return s; },
  anc(cs, id) { const by = new Map(cs.map((c) => [c.id, c])), s = new Set(), st = [id]; while (st.length) { const c = by.get(st.pop()); if (!c) continue; P(c).forEach((p) => { if (!s.has(p)) { s.add(p); st.push(p); } }); } return s; },
  // take A out of its chain: its children inherit its parents
  lift(cs, id) {
    const A = cs.find((c) => c.id === id);
    return cs.map((c) => {
      if (c.id === id) return c;
      if (c.parents.includes(id)) return { ...c, parents: [...new Set(c.parents.flatMap((p) => p === id ? A.parents : [p]))], gapParents: [...new Set([...c.gapParents, ...A.gapParents])] };
      if (c.gapParents.includes(id)) return { ...c, gapParents: [...new Set(c.gapParents.flatMap((p) => p === id ? P(A) : [p]))] };
      return c;
    });
  },
  set: (cs, id, patch) => cs.map((c) => c.id === id ? { ...c, ...patch } : c),
  takeHunks(files, ids) { const set = new Set(ids); return files.map((f) => ({ ...f, hunks: f.hunks.filter((h) => !set.has(h.id)) })).filter((f) => f.hunks.length); },
  pickHunks(files, ids) { const set = new Set(ids); return files.map((f) => ({ ...f, hunks: f.hunks.filter((h) => set.has(h.id)) })).filter((f) => f.hunks.length); },
  mergeFiles(a, b) { const out = a.map((f) => ({ ...f, hunks: f.hunks.slice() })); b.forEach((f) => { const t = out.find((x) => x.path === f.path); if (t) t.hunks = [...t.hunks, ...f.hunks]; else out.push({ ...f, hunks: f.hunks.slice() }); }); return out; },
};

// the inverse of a diff (jj revert): + and − swap, added and deleted files swap; within a run removals stay ahead of additions
const zkInvLines = (lines) => {
  const out = []; let run = [];
  const flush = () => { out.push(...run.filter((l) => l[0] === "-"), ...run.filter((l) => l[0] === "+")); run = []; };
  lines.forEach((l) => { const s = l[0] === "+" ? "-" + l.slice(1) : l[0] === "-" ? "+" + l.slice(1) : l; if (s[0] === "+" || s[0] === "-") run.push(s); else { flush(); out.push(s); } });
  flush(); return out;
};
const zkInvert = (files, tag) => files.map((f) => ({ ...f, status: f.status === "A" ? "D" : f.status === "D" ? "A" : f.status,
  hunks: f.hunks.map((h) => ({ ...h, id: h.id + tag, oldStart: h.newStart, newStart: h.oldStart, lines: zkInvLines(h.lines) })) }));

// what can happen when something is dropped on a change — only what makes sense, most likely first
function zkDropActions(p, tid, cs) {
  const M = new Map(cs.map((c) => [c.id, c])), T = M.get(tid);
  if (!T) return [];
  const b = s8(tid);
  if (p.kind === "change") {
    const A = M.get(p.id); if (!A || A.id === tid) return [];
    const a = s8(A.id), desc = O.desc(cs, A.id), anc = O.anc(cs, A.id), isDesc = desc.has(tid), isAnc = anc.has(tid);
    const onParent = A.parents.length === 1 && A.parents[0] === tid, onChild = T.parents.length === 1 && T.parents[0] === A.id;
    const mutA = !A.immutable, mutT = !T.immutable, kidsMut = cs.every((c) => !P(c).includes(tid) || c.id === A.id || !c.immutable);
    const out = [];
    if (mutA && !isDesc && !onParent) out.push({ id: "onto", group: "move", icon: "move-onto", label: "Move here", hint: "rebase -s", cmd: `jj rebase -s ${a} -o ${b}` });
    if (mutA && desc.size && !isDesc && !onParent) out.push({ id: "only", group: "move", icon: "move-only", label: "Move only this change", hint: "rebase -r", cmd: `jj rebase -r ${a} -o ${b}` });
    if (mutA && kidsMut && !onParent) out.push({ id: "after", group: "place", icon: "insert-after", label: "Insert after", hint: "rebase -A", cmd: `jj rebase -r ${a} -A ${b}` });
    if (mutA && mutT && !onChild) out.push({ id: "before", group: "place", icon: "insert-before", label: "Insert before", hint: "rebase -B", cmd: `jj rebase -r ${a} -B ${b}` });
    if (mutA && mutT) out.push({ id: "squash", group: "combine", icon: "squash-into", label: "Squash into this change", hint: "squash", cmd: `jj squash --from ${a} --into ${b}` });
    if (!isDesc && !isAnc) out.push({ id: "merge", group: "combine", icon: "merge-new", label: "New merge change", hint: "new", cmd: `jj new ${b} ${a}` });
    out.push({ id: "dup", group: "copy", icon: "duplicate", label: "Duplicate here", hint: "duplicate", cmd: `jj duplicate ${a} -o ${b}` });
    return out;
  }
  if (p.kind === "bookmark") {
    if (tid === p.from) return [];
    const fwd = O.desc(cs, p.from).has(tid);
    return [{ id: "bm", group: "move", icon: "bookmark", label: "Move " + short(p.name) + " here", hint: fwd ? "bookmark move" : undefined, note: fwd ? undefined : "backwards", cmd: `jj bookmark move ${p.name} --to ${b}${fwd ? "" : " --allow-backwards"}` }];
  }
  if (p.kind === "diff") {
    if (tid === p.from || T.immutable) return [];
    const a = s8(p.from), paths = p.whole ? " " + p.files.map((f) => f.path).join(" ") : " -i";
    const out = [{ id: "into", group: "move", icon: "squash-into", label: "Move into this change", hint: "squash", cmd: `jj squash --from ${a} --into ${b}${paths}` }];
    if (cs.every((c) => !P(c).includes(tid) || !c.immutable)) out.push({ id: "after", group: "place", icon: "insert-after", label: "Into a new change after", hint: "split -A", cmd: `jj split -r ${a} -A ${b}${paths}` });
    out.push({ id: "before", group: "place", icon: "insert-before", label: "Into a new change before", hint: "split -B", cmd: `jj split -r ${a} -B ${b}${paths}` });
    return out;
  }
  return [];
}

function ZKToastText({ text }) {
  return <>{text.map((s, i) => typeof s === "string" ? <React.Fragment key={i}>{s}</React.Fragment> : s.id ? <ChangeId key={i} id={s.id} length={8}/> : <code key={i}>{s.mono}</code>)}</>;
}

function ZKApp() {
  const D = window.ZK_DATA;
  const URLQ = new URLSearchParams(location.search);
  // what is immutable comes from Settings › Project (History › Trunk, Immutable commits) — immutable.js evaluates it, the cards re-hatch at once
  const [imm, setImm] = React.useState(IMM0);
  const [trunk, setTrunk] = React.useState("main");
  const [repo, setRepo] = React.useState(() => ({ changes: window.ZK_IMM.apply(D.changes, IMM0, "main", D.me), wc: D.wc, ops: D.OPS, opCount: D.opCount }));
  const [hist, setHist] = React.useState([]), [fut, setFut] = React.useState([]);
  const [sel, setSel] = React.useState(null);
  const [editing, setEditing] = React.useState(false);
  const [hover, setHover] = React.useState(null), [peek, setPeek] = React.useState(null);
  const [expanded, setExpanded] = React.useState([]);
  const [opts, setOpts] = React.useState({ layout: "free", detailed: true, stacks: true, cardW: 240 });
  const [prefs, setPrefs] = React.useState({ theme: ({ light: "paper", dark: "night" })[URLQ.get("theme")] || URLQ.get("theme") || "night", density: "compact", autoHide: true, diffMode: "unified", accent: URLQ.get("accentMode") || "macos" });
  // the macOS choice (System Settings › Appearance › Color) — the kit simulates it with ?accent=blue|purple|pink|red|orange|yellow|green|graphite (default: Multicolour)
  const SYS_ACCENT = URLQ.get("accent") || "multicolor";
  const [menu, setMenu] = React.useState(null);
  const [pinned, setPinned] = React.useState(null);
  // the inspector's and the panels' widths — resizable at their edge toward the graph (ResizeEdge), remembered app-wide
  const zkLS = (k, d) => { try { const v = +localStorage.getItem(k); return v > 0 ? v : d; } catch (e) { return d; } };
  const [insW, setInsW0] = React.useState(() => zkLS("zk-inspector-w", DETAIL_W)), [panW, setPanW0] = React.useState(() => zkLS("zk-panel-w", PANEL_W));
  const setInsW = (v) => { setInsW0(v); try { localStorage.setItem("zk-inspector-w", String(v)); } catch (e) { /* storage off */ } };
  const setPanW = (v) => { setPanW0(v); try { localStorage.setItem("zk-panel-w", String(v)); } catch (e) { /* storage off */ } };
  const [vw, setVw] = React.useState(window.innerWidth);
  React.useEffect(() => { const r = () => setVw(window.innerWidth); window.addEventListener("resize", r); return () => window.removeEventListener("resize", r); }, []);
  const [revset, setRevset] = React.useState("default");
  const [home, setHome] = React.useState("default");          // the default search — first in the search menu, ✕ returns to it
  const [configs, setConfigs] = React.useState(D.CONFIGS);
  const [cfgDlg, setCfgDlg] = React.useState(null);            // { draft, sel, home } while "jj log Configurations" is open
  const [goPend, setGoPend] = React.useState(null);
  const [tree, setTree] = React.useState(D.HOME_TREE);
  const [activeId, setActiveId] = React.useState(D.activeProjectId);
  // Settings and Projects are windows of their own; `key` is the key window — the others are inactive (tokens/inactive.css)
  const [projectsOpen, setProjectsOpen] = React.useState(URLQ.has("projects"));
  const [settingsOpen, setSettingsOpen] = React.useState(URLQ.has("settings"));
  const [setTab, setSetTab] = React.useState(/^(project|immutable)$/.test(URLQ.get("settings") || "") ? "project" : "general");
  const [setPage, setSetPage] = React.useState(URLQ.get("settings") === "immutable" ? "immutable" : null);   // a page inside the Project tab
  const [key, setKey] = React.useState(URLQ.has("settings") ? "settings" : URLQ.has("projects") ? "projects" : "project");
  const [push, setPush] = React.useState(null);
  // every row that shows ⌘, (Zanshin menu, project menu, the Projects sidebar) and ⌘, itself → the tab shown last, never switched ·
  // "Project Settings…" → Project · "Appearance, diffs and more" → General (those two show no ⌘,) · no project + Project last → General
  // page: open a page of the tab (the card menu's Immutable commits…); undefined leaves the window as it is
  const openSettings = (tab, page) => { if (tab === "general" || tab === "project") setSetTab(tab); if (page !== undefined) setSetPage(page); setSettingsOpen(true); setKey("settings"); };
  // ⌘W / the red button on the key window. Configurations asks first when dirty; the project window closes the project and shows Projects
  // (the start window — the kit keeps the graph behind it); Settings and Projects just close
  const closeWindow = (w) => {
    if (w === "configs") { setCfgDlg((d) => (d && (d.draft !== configs || d.home !== home) ? { ...d, ask: true } : null)); if (!(cfgDlg && (cfgDlg.draft !== configs || cfgDlg.home !== home))) setKey("project"); return; }
    if (w === "project") { setCfgDlg(null); setProjectsOpen(true); setKey("projects"); return; }
    if (w === "settings") { setSettingsOpen(false); setSetPage(null); } if (w === "projects") setProjectsOpen(false); setKey(w === "settings" && projectsOpen ? "projects" : "project");
  };
  const [cfgPos, setCfgPos] = React.useState({ x: 150, y: 96 });   // remembered while the kit runs, like the window's frame
  const dragWin = (e, pos, set) => {
    if (!e.target.closest('[data-drag="window"]') || e.target.closest("button,input")) return;
    const sx = e.clientX - pos.x, sy = e.clientY - pos.y;
    const mv = (ev) => set({ x: ev.clientX - sx, y: Math.max(0, ev.clientY - sy) });
    const up = () => { window.removeEventListener("mousemove", mv); window.removeEventListener("mouseup", up); };
    window.addEventListener("mousemove", mv); window.addEventListener("mouseup", up);
  };
  const [toast, setToast] = React.useState(null);
  const [born, setBorn] = React.useState(null), [flash, setFlash] = React.useState([]);
  const [moving, setMoving] = React.useState(false), [calm, setCalm] = React.useState(false);
  const [drag, setDrag] = React.useState(null), [panning, setPanning] = React.useState(false);
  const [view, setView] = React.useState({ top: 0, bottom: 800, left: 0, right: 1280, w: 1280, h: 800 });
  const scRef = React.useRef(null), clickT = React.useRef(0), moveT = React.useRef(0), peekT = React.useRef(0), toastT = React.useRef(0), calmT = React.useRef(0), quiet = React.useRef(0), first = React.useRef(true), justDragged = React.useRef(false);
  const setOpt = (k, v) => setOpts((o) => ({ ...o, [k]: v }));
  const setPref = (k, v) => setPrefs((o) => ({ ...o, [k]: v }));
  React.useEffect(() => { setRepo((r) => { const n = window.ZK_IMM.apply(r.changes, imm, trunk, D.me); return n === r.changes ? r : { ...r, changes: n }; }); }, [repo.changes, imm, trunk]);
  const immInfo = React.useMemo(() => {
    const cs = repo.changes, ev = window.ZK_IMM.evaluate(cs, imm, trunk, D.me);
    return { count: ev.count, heads: ev.heads, unknown: ev.unknown, tags: cs.flatMap((c) => c.tags || []),
      remoteBookmarks: cs.flatMap((c) => c.bookmarks.filter((b) => b.state === "remote").map((b) => b.name)), bookmarks: [...new Set(cs.flatMap((c) => c.bookmarks.map((b) => b.name)))].sort() };
  }, [repo.changes, imm, trunk]);

  // ---- derived graph ----
  const W = opts.cardW, H = opts.detailed ? 62 : 40;
  const visibleChanges = React.useMemo(() => {
    if (revset === "default" || revset === "all") return repo.changes;
    const keep = window.zkRevsetMatch(revset, configs, D.me);
    const ids = new Set(repo.changes.filter(keep).map((c) => c.id));
    const by = new Map(repo.changes.map((c) => [c.id, c]));
    const near = (id, seen = new Set()) => { const out = []; const c = by.get(id); if (!c) return out; P(c).forEach((p) => { if (seen.has(p)) return; seen.add(p); if (ids.has(p)) out.push(p); else out.push(...near(p, seen)); }); return out; };
    return repo.changes.filter((c) => ids.has(c.id)).map((c) => { const direct = c.parents.filter((p) => ids.has(p)); const hidden = [...new Set(near(c.id))].filter((p) => !direct.includes(p)); return { ...c, parents: direct, gapParents: hidden, realParents: P(c).length, endBelow: c.endBelow || (!direct.length && !hidden.length && P(c).length > 0) }; });
  }, [repo.changes, revset, configs]);
  const nodes = React.useMemo(() => window.zkFold(visibleChanges, repo.wc, opts.stacks, expanded), [visibleChanges, repo.wc, opts.stacks, expanded]);
  const L = React.useMemo(() => window.zkLayout(nodes, W, H, opts.layout), [nodes, W, H, opts.layout]);
  const byId = (id) => repo.changes.find((c) => c.id === id);
  const selected = sel ? byId(sel) : null;
  const project = window.zkFlatten(tree, 0, true).map((x) => x.node).find((n) => n.id === activeId) || { name: "—", path: "" };
  const recent = window.zkFlatten(tree, 0, true).map((x) => x.node).filter((n) => n.kind === "project" && n.status !== "missing")
    .sort((a, b) => (a.id === activeId ? -1 : b.id === activeId ? 1 : 0)).slice(0, 5);
  const gaps = nodes.reduce((s, n) => s + n.gapParents.length + (n.endBelow ? 1 : 0), 0);

  React.useEffect(() => { if (first.current) { first.current = false; return; } setMoving(true); clearTimeout(moveT.current); moveT.current = setTimeout(() => setMoving(false), 470); }, [L]);
  React.useEffect(() => {
    const root = document.documentElement;
    if (prefs.theme === "system") { const m = matchMedia("(prefers-color-scheme: dark)"); const f = () => { root.dataset.theme = m.matches ? "night" : "paper"; }; f(); m.addEventListener("change", f); return () => m.removeEventListener("change", f); }
    root.dataset.theme = prefs.theme;
  }, [prefs.theme]);
  React.useEffect(() => { document.documentElement.dataset.density = prefs.density; }, [prefs.density]);
  React.useEffect(() => {
    const root = document.documentElement;
    if (prefs.accent === "macos" && SYS_ACCENT !== "multicolor") root.dataset.accent = SYS_ACCENT; else delete root.dataset.accent;
  }, [prefs.accent]);

  // ---- viewport, calm scrolling, @ locator ----
  const insets = { left: pinned ? RAIL_R + panW + EDGE : RAIL_R, right: sel ? insW + EDGE * 2 : MINI + EDGE };
  const measure = () => { const el = scRef.current; if (!el) return; setView({ top: el.scrollTop + TOP, bottom: el.scrollTop + el.clientHeight - EDGE, left: el.scrollLeft + insets.left, right: el.scrollLeft + el.clientWidth - insets.right, w: el.clientWidth, h: el.clientHeight }); };
  React.useEffect(() => { measure(); const ro = new ResizeObserver(measure); ro.observe(scRef.current); return () => ro.disconnect(); }, [sel, pinned]);
  const onScroll = () => {
    measure(); setPeek(null);
    if (!prefs.autoHide || drag || Date.now() < quiet.current) return;
    setCalm(true); clearTimeout(calmT.current); calmT.current = setTimeout(() => setCalm(false), window.zkMs("--delay-calm-return", 650));
  };
  const scrollTo = (id) => {
    const p = L.pos.get(id), el = scRef.current; if (!p || !el) return;
    quiet.current = Date.now() + 700;
    el.scrollTo({ top: Math.max(0, p.y + H / 2 - (TOP + el.clientHeight) / 2), left: Math.max(0, p.x + W / 2 - (insets.left + el.clientWidth - insets.right) / 2), behavior: "smooth" });
  };
  const goTo = (id) => { if (!visibleChanges.some((c) => c.id === id)) setRevset("all"); setGoPend(id); };
  React.useEffect(() => {
    if (!goPend) return;
    if (L.pos.get(goPend)) { setSel(goPend); scrollTo(goPend); setGoPend(null); return; }
    const run = nodes.find((n) => n.stack && n.members.some((m) => m.id === goPend));
    if (run) setExpanded((x) => x.includes(run.members[0].id) ? x : [...x, run.members[0].id]);
  }, [goPend, L]);
  // Edit Configurations… / ⌥⌘L: opens the window or brings it forward with its edits as they are
  const openConfigs = (id) => { setKey("configs"); setCfgDlg((d) => d || { draft: configs, sel: id === "default" || id === "all" || configs.some((c) => c.id === id) ? id : home, home }); };
  const applyConfigs = (d) => { setConfigs(d.draft); setHome(d.home); if (!d.draft.some((c) => c.id === revset) && !(revset === "default" || revset === "all") && !window.zkParseSearch(revset)) setRevset(d.home); };
  const wcPos = L.pos.get(repo.wc);
  const wcDir = !wcPos ? null : wcPos.y + H < view.top + 8 ? "up" : wcPos.y > view.bottom - 8 ? "down" : wcPos.x + W < view.left + 8 ? "left" : wcPos.x > view.right - 8 ? "right" : null;
  React.useEffect(() => { // keep the selected card clear of the inspector
    if (!sel) return; const p = L.pos.get(sel), el = scRef.current; if (!p || !el) return;
    const right = el.scrollLeft + el.clientWidth - insW - EDGE * 2;
    if (p.x + W > right) { quiet.current = Date.now() + 700; el.scrollTo({ left: p.x + W - el.clientWidth + insW + EDGE * 3, behavior: "smooth" }); }
  }, [sel]);

  // ---- operations: every one lands in the op log and can be undone ----
  const commitRepo = (cmd, next, extra = {}) => {
    setHist((h) => [...h.slice(-40), repo]); setFut([]);
    setRepo({ ...next, ops: [{ cmd, when: "just now" }, ...repo.ops], opCount: repo.opCount + 1 });
    if (extra.toast) showToast({ text: extra.toast });
    if (extra.flash) { setFlash(extra.flash); setTimeout(() => setFlash([]), window.zkMs("--dur-flash", 2400)); }
    if (extra.born) { setBorn(extra.born); setTimeout(() => setBorn(null), 700); }
    if (extra.select !== undefined) setSel(extra.select);
  };
  const taken = () => new Set(repo.changes.map((c) => c.id));
  const blank = (id, parents, lane) => ({ id, commit: hex(), parents, gapParents: [], bookmarks: [], author: D.me, description: "", subject: "", date: "now", t: 0, lane, files: [] });
  // moving @ away from an empty, undescribed change abandons it — as jj does
  const dropEmptyWc = (cs, wc, nextWc) => { const w = cs.find((c) => c.id === wc); if (!w || w.id === nextWc || w.files.length || w.subject || w.description || cs.some((c) => P(c).includes(w.id))) return cs; return O.lift(cs, w.id).filter((c) => c.id !== w.id); };

  const newChange = (on = repo.wc, mode = "new") => {
    const p = byId(on); if (!p || (mode !== "new" && mode !== "after" && p.immutable)) return;
    const id = zkNewId(taken()), n = blank(id, mode === "before" ? p.parents.slice() : [on], p.lane);
    let cs = repo.changes;
    if (mode === "after") cs = cs.map((c) => c.parents.includes(on) ? { ...c, parents: c.parents.map((x) => x === on ? id : x) } : c);
    if (mode === "before") { n.gapParents = p.gapParents.slice(); cs = O.set(cs, on, { parents: [id], gapParents: [] }); }
    cs = dropEmptyWc([n, ...cs], repo.wc, id);
    commitRepo("new " + (mode === "new" ? "" : mode === "after" ? "-A " : "-B ") + s8(on), { ...repo, changes: cs, wc: id }, { born: id, select: sel ? id : undefined });
  };
  const edit = (id) => { const c = byId(id); if (!c || c.immutable || id === repo.wc) return; commitRepo("edit " + s8(id), { ...repo, changes: dropEmptyWc(repo.changes, repo.wc, id), wc: id }, { flash: [id] }); };
  const describe = (id, s, b) => commitRepo('describe -m "' + s.trim().slice(0, 28) + (s.trim().length > 28 ? "…" : "") + '"', { ...repo, changes: O.set(repo.changes, id, { subject: s.trim(), description: b.trim() }) });
  const abandon = (id) => {
    const c = byId(id); if (!c || c.immutable) return;
    let cs = O.lift(repo.changes, id).filter((x) => x.id !== id), wc = repo.wc, born;
    if (id === repo.wc) { wc = born = zkNewId(taken()); cs = [blank(wc, c.parents.slice(0, 1), c.lane), ...cs]; }
    commitRepo("abandon " + s8(id), { ...repo, changes: cs, wc }, { toast: ["Abandoned ", { id }], select: null, born });
  };
  // jj revert -r <change> -B @ — for a change in @'s history that changes something, immutable ones included (pushed history can't be
  // abandoned): a new change with the inverse diff slots in between @ and its parents; @ keeps its own diff on top and stays @
  const revertWhy = (id) => {
    if (id === repo.wc) return "The revert lands below @ — @ itself can’t be reverted";
    if (!O.anc(repo.changes, repo.wc).has(id)) return "The revert lands below @ — only changes in @’s history";
    const c = byId(id); if (!c || !c.files.length) return "Nothing to revert — the change is empty";
    return null;
  };
  const revert = (id) => {
    if (revertWhy(id)) return;
    const s = byId(id), w = byId(repo.wc), nid = zkNewId(taken());
    const n = { ...blank(nid, w.parents.slice(), w.lane), gapParents: w.gapParents.slice(), subject: 'Revert "' + (s.subject || "") + '"', description: "This reverts commit " + s.commit + ".", files: zkInvert(s.files, "r" + nid.slice(0, 3)) };
    const cs = O.set([n, ...repo.changes], repo.wc, { parents: [nid], gapParents: [] });
    commitRepo("revert -r " + s8(id) + " -B @", { ...repo, changes: cs }, { born: nid, toast: ["Reverted ", { id }, " — ", { id: nid }, " undoes it"], select: sel ? nid : undefined });
  };
  const squashInto = (id, tid, cmd) => {
    const c = byId(id), t = byId(tid); if (!c || !t || c.immutable || t.immutable) return;
    let cs = O.set(repo.changes, tid, { files: O.mergeFiles(t.files, c.files) });
    if (id === repo.wc) cs = O.set(cs, id, { files: [] }); else cs = O.lift(cs, id).filter((x) => x.id !== id);
    commitRepo(cmd || "squash -r " + s8(id), { ...repo, changes: cs }, { toast: ["Squashed ", { id }, " into ", { id: tid }], flash: [tid], select: sel === id && id !== repo.wc ? tid : sel });
  };
  const commitWc = (ids, msg) => {
    const c = byId(repo.wc), nid = zkNewId(taken());
    const [subject, ...rest] = (msg || "").split("\n");
    let cs = O.set(repo.changes, c.id, { files: O.pickHunks(c.files, ids), subject: msg ? subject.trim() : c.subject, description: msg ? rest.join("\n").trim() : c.description, date: "now" });
    cs = [blank(nid, [c.id], c.lane), ...cs]; cs = O.set(cs, nid, { files: O.takeHunks(c.files, ids) });
    commitRepo("commit" + (msg ? ' -m "' + subject.trim() + '"' : ""), { ...repo, changes: cs, wc: nid }, { born: nid, select: nid, toast: ["Committed ", { id: c.id }, msg ? " · “" + subject.trim() + "”" : ""] });
  };
  const split = (id, ids, msg) => {
    const c = byId(id), nid = zkNewId(taken());
    const [subject, ...rest] = (msg || "").split("\n");
    let cs = repo.changes.map((x) => x.parents.includes(id) ? { ...x, parents: x.parents.map((p) => p === id ? nid : p) } : x);
    cs = O.set(cs, id, { files: O.pickHunks(c.files, ids), subject: msg ? subject.trim() : c.subject, description: msg ? rest.join("\n").trim() : c.description });
    cs = [{ ...blank(nid, [id], c.lane), author: c.author, subject: c.subject, description: c.description, date: c.date, t: c.t, files: O.takeHunks(c.files, ids) }, ...cs];
    commitRepo("split -r " + s8(id), { ...repo, changes: cs }, { born: nid, select: id, toast: ["Split ", { id }, " — the rest is now ", { id: nid }] });
  };
  const applyDrop = (p, tid, act) => {
    const cs0 = repo.changes, T = byId(tid);
    if (p.kind === "change") {
      const A = byId(p.id), id = A.id;
      if (act.id === "squash") return squashInto(id, tid, act.cmd.slice(3));
      let cs = cs0, extra = { flash: [id] }, wc = repo.wc;
      const moved = (verb, how) => ({ toast: [verb + " ", { id }, how, { id: tid }] });
      if (act.id === "onto") { cs = O.set(cs, id, { parents: [tid], gapParents: [], lane: T.lane }); extra = { ...extra, ...moved("Moved", " onto ") }; }
      if (act.id === "only") { cs = O.set(O.lift(cs, id), id, { parents: [tid], gapParents: [], lane: T.lane }); extra = { ...extra, ...moved("Moved", " onto ") }; }
      if (act.id === "after") { cs = O.lift(cs, id).map((c) => c.id !== id && c.parents.includes(tid) ? { ...c, parents: c.parents.map((x) => x === tid ? id : x) } : c); cs = O.set(cs, id, { parents: [tid], gapParents: [], lane: T.lane }); extra = { ...extra, ...moved("Inserted", " after ") }; }
      if (act.id === "before") { cs = O.lift(cs, id); const t2 = cs.find((c) => c.id === tid); cs = O.set(O.set(cs, id, { parents: t2.parents.slice(), gapParents: t2.gapParents.slice(), lane: T.lane }), tid, { parents: [id], gapParents: [] }); extra = { ...extra, ...moved("Inserted", " before ") }; }
      if (act.id === "merge") { const nid = zkNewId(taken()); cs = [{ ...blank(nid, [tid, id], T.lane), merge: true }, ...dropEmptyWc(cs, repo.wc, nid)]; wc = nid; extra = { born: nid, toast: ["Merged ", { id }, " and ", { id: tid }, " in a new change"] }; }
      if (act.id === "dup") { const nid = zkNewId(taken()); cs = [{ ...A, id: nid, commit: hex(), parents: [tid], gapParents: [], bookmarks: [], lane: T.lane, files: A.files.map((f) => ({ ...f, hunks: f.hunks.map((h) => ({ ...h, id: h.id + "d" + nid.slice(0, 3) })) })) }, ...cs]; extra = { born: nid, toast: ["Duplicated ", { id }, " onto ", { id: tid }] }; }
      return commitRepo(act.cmd.slice(3), { ...repo, changes: cs, wc }, extra);
    }
    if (p.kind === "bookmark") {
      const bm = byId(p.from).bookmarks.find((b) => b.name === p.name);
      let cs = O.set(cs0, p.from, { bookmarks: byId(p.from).bookmarks.filter((b) => b.name !== p.name) });
      cs = O.set(cs, tid, { bookmarks: [...T.bookmarks, { ...bm, state: bm.state === "synced" ? "ahead" : bm.state }] });
      return commitRepo(act.cmd.slice(3), { ...repo, changes: cs }, { flash: [tid], toast: ["Moved ", { mono: short(p.name) }, " to ", { id: tid }] });
    }
    if (p.kind === "diff") {
      const A = byId(p.from), part = O.pickHunks(A.files, p.hunkIds);
      let cs = O.set(cs0, A.id, { files: O.takeHunks(A.files, p.hunkIds) });
      if (act.id === "into") { cs = O.set(cs, tid, { files: O.mergeFiles(T.files, part) }); return commitRepo(act.cmd.slice(3), { ...repo, changes: cs }, { flash: [tid], toast: ["Moved " + p.label + " into ", { id: tid }] }); }
      const nid = zkNewId(taken()), n = { ...blank(nid, act.id === "after" ? [tid] : T.parents.slice(), T.lane), files: part };
      if (act.id === "after") cs = cs.map((c) => c.parents.includes(tid) ? { ...c, parents: c.parents.map((x) => x === tid ? nid : x) } : c);
      else { n.gapParents = T.gapParents.slice(); cs = O.set(cs, tid, { parents: [nid], gapParents: [] }); }
      return commitRepo(act.cmd.slice(3), { ...repo, changes: [n, ...cs] }, { born: nid, toast: ["Moved " + p.label + " into a new change " + (act.id === "after" ? "after " : "before "), { id: tid }] });
    }
  };
  // one toast at a time; success and warn hide after --dur-toast-hold (errors stay)
  const showToast = (t) => { clearTimeout(toastT.current); setToast({ ...t, n: Date.now() }); if (t.tone !== "error") toastT.current = setTimeout(() => setToast(null), window.zkMs("--dur-toast-hold", 6500)); };
  // ⌘Z / Edit › Undo ‹action›: only Zanshin's own last operation, only while it is still the current one; a toast offers Redo (⇧⌘Z).
  // Undoing a push warns as the CLI does. Anything older is the Undo Timeline's job.
  const undo = () => {
    if (!hist.length) return;
    const prev = hist[hist.length - 1], last = repo.ops[0] ? repo.ops[0].cmd : "";
    setHist(hist.slice(0, -1)); setFut((f) => [...f, repo]);
    setRepo({ ...prev, ops: [{ cmd: "jj undo", when: "just now" }, ...repo.ops], opCount: repo.opCount + 1 });
    if (sel && !prev.changes.some((c) => c.id === sel)) setSel(null);
    showToast(last.startsWith("jj git push") ? { tone: "warn", redo: true, text: ["Undoing a push operation often leads to conflicted bookmarks."] } : { redo: true, text: ["Undid ", { mono: last }] });
  };
  const redo = () => {
    if (!fut.length) return;
    const next = fut[fut.length - 1];
    setFut(fut.slice(0, -1)); setHist((h) => [...h, repo]);
    setRepo({ ...next, ops: [{ cmd: "jj redo", when: "just now" }, ...repo.ops], opCount: repo.opCount + 1 });
    showToast({ text: ["Redid ", { mono: next.ops[0] ? next.ops[0].cmd : "the operation" }] });
  };
  // Push… — the sheet shows what jj git push would send; the kit maps each bookmark's sync state to the --dry-run kind
  const pushRows = () => repo.changes.flatMap((c) => c.bookmarks.map((b) => {
    const kind = { ahead: "forward", local: "new", diverged: "sideways", behind: "backward", remote: "delete" }[b.state] || "none";
    return { name: b.name, tracked: b.state !== "local", kind, inDefault: kind === "forward", from: kind === "new" ? null : c.parents[0] || null, to: kind === "delete" ? null : c.id,
      refused: !c.subject && kind !== "delete" ? "empty-description" : undefined, refusedAt: c.id };
  }));
  const openPush = () => setPush({ rows: pushRows(), remote: ["origin"], selected: null, bulk: null, change: { id: repo.wc, generated: "push-" + repo.wc.slice(0, 8), refused: (repo.changes.find((c) => c.id === repo.wc) || {}).subject ? undefined : "empty-description" }, allow: {}, state: "ready", error: null });
  const runPush = (cmd) => {
    setPush((p) => ({ ...p, state: "pushing", progress: 0 }));
    let k = 0; const iv = setInterval(() => { k += 1; setPush((p) => p && { ...p, progress: Math.min(1, k / 8) }); if (k >= 8) { clearInterval(iv); finishPush(cmd); } }, 140);
  };
  const finishPush = (cmd) => {
    setPush((p) => {
      if (!p) return p;
      const names = new Set((p.selected || p.rows.filter((r) => r.inDefault).map((r) => r.name)));
      const n = names.size + (p.change.on ? 1 : 0);
      const changes = repo.changes.map((c) => ({ ...c, bookmarks: c.bookmarks.map((b) => names.has(b.name) ? { ...b, state: "synced" } : b) }));
      commitRepo(cmd, { ...repo, changes }, { toast: ["Pushed " + n + (n === 1 ? " bookmark" : " bookmarks") + " to " + p.remote.join(", ")] });
      return null;
    });
  };

  // ---- direct manipulation ----
  const beginDrag = (e, payload) => {
    if (e.button !== 0) return;
    const x0 = e.clientX, y0 = e.clientY;
    let d = null, restT = 0;
    const find = (x, y) => { const el = document.elementFromPoint(x, y); if (!el) return {}; const menuEl = el.closest(".zs-drop"); const card = el.closest("[data-change]"); return { overMenu: !!menuEl, target: card && !card.dataset.change.startsWith("s:") ? card.dataset.change : null, card }; };
    const move = (ev) => {
      if (!d) { if (Math.hypot(ev.clientX - x0, ev.clientY - y0) < 5) return; d = { payload, src: payload.kind === "change" ? payload.id : null, from: payload.kind !== "change" ? payload.from : null, target: null, actions: [], sel: 0, menu: null }; setPeek(null); setMenu(null); }
      const f = find(ev.clientX, ev.clientY);
      let next = { ...d, x: ev.clientX, y: ev.clientY, overMenu: f.overMenu };
      if (!f.overMenu && f.target !== d.target) {
        clearTimeout(restT);
        const actions = f.target ? zkDropActions(payload, f.target, repo.changes) : [];
        next = { ...next, target: actions.length ? f.target : null, actions, sel: 0, menu: null };
        if (actions.length) {
          const r = f.card.getBoundingClientRect(), below = window.innerHeight - r.bottom > 60 + actions.length * 31;
          restT = setTimeout(() => { d = { ...d, menu: { x: r.left + r.width / 2, y: below ? r.bottom + 8 : r.top - 8, place: below ? "below" : "above" } }; setDrag(d); }, window.zkMs("--delay-drop-menu", 520));
        }
      }
      d = next; setDrag(d);
    };
    const end = (ev, cancel) => {
      window.removeEventListener("pointermove", move); window.removeEventListener("pointerup", up); window.removeEventListener("keydown", key, true);
      clearTimeout(restT);
      if (d) {
        justDragged.current = true; setTimeout(() => { justDragged.current = false; }, 60);
        const act = d.actions[d.sel];
        if (!cancel && d.target && act && (!d.menu || d.overMenu || ev.target.closest("[data-change]"))) applyDrop(payload, d.target, act);
      }
      d = null; setDrag(null);
    };
    const up = (ev) => end(ev, false);
    const key = (ev) => { if (ev.key === "Escape") { ev.stopPropagation(); end(ev, true); } };
    window.addEventListener("pointermove", move); window.addEventListener("pointerup", up); window.addEventListener("keydown", key, true);
  };
  const setDropSel = (i) => setDrag((d) => d && { ...d, sel: i });
  const onCanvasDown = (e) => {
    if (e.button !== 0 || e.target.closest("[data-change],.zk-peek,.zk-stackpop")) return;
    const el = scRef.current, x0 = e.clientX, y0 = e.clientY, sl = el.scrollLeft, st = el.scrollTop;
    setPanning(true);
    const mv = (ev) => { el.scrollLeft = sl - (ev.clientX - x0); el.scrollTop = st - (ev.clientY - y0); };
    const up = () => { setPanning(false); window.removeEventListener("pointermove", mv); window.removeEventListener("pointerup", up); };
    window.addEventListener("pointermove", mv); window.addEventListener("pointerup", up);
  };

  React.useEffect(() => { if (URLQ.has("push")) openPush(); }, []);
  // ---- keyboard: ⌘, Settings (last tab) · ⌘W closes the key window · ⇧⌘O All Projects… · ⌘Z / ⇧⌘Z undo / redo · Esc ----
  React.useEffect(() => {
    const k = (e) => {
      const cmd = e.metaKey || e.ctrlKey;
      if (cmd && e.key === ",") { e.preventDefault(); openSettings(); return; }
      if (cmd && e.key.toLowerCase() === "w") { e.preventDefault(); closeWindow(key); return; }
      if (cmd && e.shiftKey && e.key.toLowerCase() === "o") { e.preventDefault(); setProjectsOpen(true); setKey("projects"); return; }
      if (key !== "project" || push) return;
      if (cmd && e.key.toLowerCase() === "z" && !/TEXTAREA|INPUT/.test(e.target.tagName)) { e.preventDefault(); if (e.shiftKey) redo(); else undo(); return; }
      // ⌘J scrolls to the selected change (the HIG's "scroll to a selection") · ⇧⌘J to the working copy (Go › Working Copy (@))
      if (cmd && e.key.toLowerCase() === "j") { e.preventDefault(); if (e.shiftKey) scrollTo(repo.wc); else if (sel) scrollTo(sel); return; }
      if (e.key === "Escape") { if (menu) setMenu(null); else if (editing) setEditing(false); else setSel(null); }
    };
    window.addEventListener("keydown", k); return () => window.removeEventListener("keydown", k);
  }, [menu, editing, key, projectsOpen, settingsOpen, hist, fut, push, cfgDlg, repo]);

  const onSelect = (id, now) => { if (justDragged.current) return; clearTimeout(clickT.current); const go = () => { setSel(id); setEditing(false); setMenu(null); }; if (now) go(); else clickT.current = setTimeout(go, 200); };
  const onDouble = (id) => { clearTimeout(clickT.current); edit(id); };
  const onHover = (id) => { setHover(id); clearTimeout(peekT.current); if (!id) { setPeek(null); return; } const isStack = id.startsWith("s:"); peekT.current = setTimeout(() => setPeek(id), isStack ? window.zkMs("--delay-stack-list", 380) : window.zkMs("--delay-peek", 450)); };
  const onMenu = (id, e, fromButton) => {
    const r = fromButton ? e.currentTarget.getBoundingClientRect() : null;
    setPeek(null);
    setMenu(menu && menu.id === id && fromButton ? null : { id, x: Math.max(8, Math.min(fromButton ? r.right - 250 : e.clientX, window.innerWidth - 268)), y: Math.min(fromButton ? r.bottom + 6 : e.clientY, window.innerHeight - 300) });
  };
  const menuAct = (a) => {
    const id = menu.id; setMenu(null);
    if (a === "new" || a === "after" || a === "before") newChange(id, a);
    else if (a === "edit") edit(id);
    else if (a === "describe") { setSel(id); setEditing(true); }
    else if (a === "squash") { const c = byId(id); squashInto(id, c.parents[0]); }
    else if (a === "abandon") abandon(id);
    else if (a === "revert") revert(id);
    else if (a === "immutable") openSettings("project", "immutable");
  };
  const mc = menu && byId(menu.id), isWCm = mc && mc.id === repo.wc;
  const canSquash = (c) => c && !c.immutable && c.parents.length === 1 && byId(c.parents[0]) && !byId(c.parents[0]).immutable;
  // the card menu — Revert · Abandon in the last group. An immutable change keeps only what leaves it as it is (New change on top, Insert after
  // while its children are mutable, Revert), then why and where to change that; the rest is left out, not greyed
  const menuItems = !mc ? [] : (() => {
    const rw = revertWhy(mc.id);
    const NEW = { id: "new", label: "New change on top", icon: "new-on-top", cmd: "jj new" }, AFTER = { id: "after", label: "Insert after", icon: "insert-after", cmd: "jj new -A" };
    const REVERT = { id: "revert", label: "Revert", icon: "revert", cmd: "jj revert -B @", disabled: !!rw, title: rw || undefined };
    if (mc.immutable) return [NEW, ...(repo.changes.some((x) => P(x).includes(mc.id) && x.immutable) ? [] : [AFTER]), "sep", REVERT, "sep",
      { note: "Immutable · " + (mc.immWhy || "part of trunk() history"), icon: <Swatch/> }, { id: "immutable", label: "Immutable commits…", icon: "settings" }];
    return [NEW, AFTER, { id: "before", label: "Insert before", icon: "insert-before", cmd: "jj new -B" }, "sep",
      { id: "edit", label: "Edit", icon: "working-copy-at", cmd: "jj edit", disabled: isWCm },
      { id: "describe", label: "Describe…", icon: "describe", cmd: "jj describe" },
      { id: "squash", label: "Squash into parent", icon: "squash", cmd: "jj squash", disabled: !canSquash(mc) },
      "sep", REVERT, { id: "abandon", label: "Abandon", icon: "abandon", cmd: "jj abandon", danger: true }];
  })();
  const atR = sel ? insW + EDGE * 2 : MINI + EDGE;
  const dragAct = drag && drag.actions[drag.sel];
  const visibleSet = new Set(nodes.flatMap((n) => n.stack ? n.members.map((m) => m.id) : [n.id]));
  const lift = drag && drag.payload.kind === "diff" ? drag.payload.hunkIds : null;

  return (
    <>
    <div className={"zk-win" + (calm ? " is-calm" : "") + (drag ? " is-dragging" : "") + (panning ? " is-panning" : "")} data-window={key === "project" ? undefined : "inactive"} style={{ "--inspector-w": insW + "px", "--panel-w": panW + "px" }}
      onMouseDown={() => key !== "project" && setKey("project")} onClick={() => menu && setMenu(null)}>
      <div className="zk-scroll" ref={scRef} onScroll={onScroll} onPointerDown={onCanvasDown}>
        <window.ZKPlane nodes={nodes} L={L} W={W} H={H} axisLeft={insets.left} detailed={opts.detailed} wcId={repo.wc} selId={sel} hoverId={hover} menuId={menu && menu.id} peekId={calm ? null : peek}
          dnd={drag} bornId={born} flashIds={flash} moving={moving} view={view}
          onSelect={onSelect} onDouble={onDouble} onMenu={onMenu} onHover={onHover} onCardDown={(e, n) => !n.stack && beginDrag(e, { kind: "change", id: n.id })}
          onToggleStack={(mid) => setExpanded((x) => x.includes(mid) ? x.filter((y) => y !== mid) : [...x, mid])}/>
      </div>
      <window.ZKMinimap nodes={nodes} L={L} W={W} H={H} wcId={repo.wc} selId={sel} view={view} scrollH={Math.max(L.height, view.h)} hidden={!!sel && !calm}
        onJump={(y) => { const el = scRef.current; quiet.current = Date.now() + 300; el.scrollTop = y - (TOP + (view.h - TOP - EDGE) / 2); }}/>
      <div className="zk-fl">
        <window.ZKTopBar D={D} project={project} recent={recent} activeId={activeId} onPickProject={setActiveId} onAllProjects={() => { setProjectsOpen(true); setKey("projects"); }} onSettings={openSettings} onPush={openPush}
          revset={revset} setRevset={setRevset} home={home} configs={configs} changes={repo.changes} visible={visibleSet} onGoTo={goTo} onEditConfigs={openConfigs}
          shown={visibleChanges.length} total={repo.changes.length} gaps={gaps} opts={opts} setOpt={setOpt} onNew={() => newChange(repo.wc)}/>
        <window.ZKRail pinned={pinned} setPinned={setPinned} changes={repo.changes} visible={visibleSet} ops={repo.ops} opCount={repo.opCount} onPick={(id) => { setSel(id); scrollTo(id); }}/>
        {pinned && ResizeEdge && <ResizeEdge side="right" at={RAIL_R + panW} top={TOP} bottom={EDGE} value={panW} min={240} max={440} defaultValue={PANEL_W}
          limit={vw - RAIL_R - EDGE - 320 - (selected ? insW + EDGE * 2 : MINI + EDGE)} label="Panel width" onChange={setPanW}/>}
        {selected && ResizeEdge && <ResizeEdge side="left" at={EDGE + insW} top={TOP} bottom={EDGE} value={insW} min={380} max={720} defaultValue={DETAIL_W}
          limit={vw - (pinned ? RAIL_R + panW + EDGE : RAIL_R) - EDGE * 2 - 320} label="Inspector width" onChange={setInsW}/>}
        {selected && (
          <window.ZKInspector key={selected.id + ":" + (selected.id === repo.wc)} c={selected} isWC={selected.id === repo.wc} canSquash={canSquash(selected)}
            diffMode={prefs.diffMode} setDiffMode={(v) => setPref("diffMode", v)} editing={editing} setEditing={setEditing} lift={lift} beginDrag={beginDrag}
            onClose={() => setSel(null)} onEdit={() => edit(selected.id)} onNew={(id) => newChange(id)} onDescribe={(s, b) => describe(selected.id, s, b)}
            onSquash={() => squashInto(selected.id, selected.parents[0])} onAbandon={() => abandon(selected.id)}
            onCommit={(ids, msg) => commitWc(ids, msg)} onSplit={(ids, msg) => split(selected.id, ids, msg)}/>
        )}
        <div className={"zk-at" + (wcDir && !toast ? " is-on" : "")} style={{ left: (insets.left + view.w - atR) / 2 }}>
          <AtPill direction={wcDir || "down"} onClick={() => scrollTo(repo.wc)} tabIndex={wcDir ? 0 : -1} aria-hidden={!wcDir}/>
        </div>
        {toast && (
          <div className="zk-toast" key={toast.n} style={{ left: (insets.left + view.w - atR) / 2 }}>
            <Toast tone={toast.tone} onUndo={toast.redo ? redo : undo} undoLabel={toast.redo ? "Redo" : "Undo"} onClose={() => { clearTimeout(toastT.current); setToast(null); }}><ZKToastText text={toast.text}/></Toast>
          </div>
        )}
      </div>
      {menu && mc && (
        <div className="zk-menu" style={{ left: menu.x, top: menu.y }} onClick={(e) => e.stopPropagation()} onContextMenu={(e) => e.preventDefault()}>
          <Menu id={mc.id} subject={mc.subject || "(no description set)"} workingCopy={isWCm} onSelect={menuAct} items={menuItems}/>
        </div>
      )}
      {drag && drag.menu && (
        <div className={"zk-dropwrap is-" + drag.menu.place} style={{ left: drag.menu.x, top: drag.menu.y }}>
          <DropMenu items={drag.actions} active={drag.sel} place={drag.menu.place} onActive={setDropSel}/>
        </div>
      )}
      {drag && (
        <div className="zk-ghost" style={{ left: drag.x, top: drag.y }}>
          <DragGhost className={drag.overMenu ? "is-muted" : ""}
            {...(drag.payload.kind === "change" ? (() => { const c = byId(drag.payload.id); return { kind: "change", id: c.id, subject: c.subject, workingCopy: c.id === repo.wc }; })()
              : drag.payload.kind === "bookmark" ? (() => { const m = drag.payload.name.match(/[A-Z][A-Z0-9]+-\d+/); return { kind: "bookmark", bookmark: short(drag.payload.name), rest: m ? drag.payload.name.slice(m.index + m[0].length).replace(/^[_\-/.]+/, "") : "" }; })()
              : { kind: "diff", status: drag.payload.files.length === 1 ? drag.payload.files[0].status : null, label: drag.payload.label, added: drag.payload.a, removed: drag.payload.r })}
            command={drag.menu ? undefined : dragAct && dragAct.cmd}
            hint={drag.menu ? undefined : drag.payload.kind === "change" ? "Drop on a change" : drag.payload.kind === "bookmark" ? "Drop on the change it should point to" : "Drop on the change it belongs to"}/>
        </div>
      )}
      {push && PushDialog && (
        <PushDialog remotes={["origin", "upstream"]} defaultRemotes={["origin"]} bookmarks={push.rows} remote={push.remote} onRemote={(r) => setPush({ ...push, remote: r })}
          selected={push.selected} onSelect={(s) => setPush((p) => ({ ...p, selected: s }))} bulk={push.bulk} onBulk={(b) => setPush((p) => ({ ...p, bulk: b }))}
          change={push.change} onChange={(c) => setPush({ ...push, change: c })} allow={push.allow} onAllow={(a) => setPush({ ...push, allow: a })}
          state={push.state} progress={push.progress} error={push.error} onFetch={() => setPush({ ...push, error: null })} onRetry={() => setPush({ ...push, error: null })}
          onPush={runPush} onCancel={() => setPush(null)}/>
      )}
    </div>
    {/* windows of their own, above the project window — the last one clicked is key */}
    <div className="zk-winlayer">
      {cfgDlg && (() => {
        const d = cfgDlg, cnt = (id) => { const m = id === "default" || id === "all" ? () => true : window.zkRevsetMatch(id, d.draft, D.me); return repo.changes.filter(m).length; };
        const done = () => { setCfgDlg(null); setKey("project"); };
        return <div onMouseDown={(e) => { setKey("configs"); dragWin(e, cfgPos, setCfgPos); }} style={{ left: cfgPos.x, top: cfgPos.y, zIndex: key === "configs" ? 3 : 1 }}>
          <RevsetDialog active={key === "configs"} project={project.name} configs={d.draft} selected={d.sel} defaultId={d.home} me={D.me} matchCount={d.sel ? cnt(d.sel) : undefined} total={repo.changes.length}
            dirty={d.draft !== configs || d.home !== home} discarding={!!d.ask} onDiscarding={(v) => setCfgDlg((x) => x && { ...x, ask: v })}
            onSelect={(sel) => setCfgDlg((x) => ({ ...x, sel }))} onDefaultChange={(h) => setCfgDlg((x) => ({ ...x, home: h }))} onChange={(draft) => setCfgDlg((x) => ({ ...x, draft }))}
            onCancel={done} onApply={() => applyConfigs(d)}
            onOk={() => { applyConfigs(d); if (d.sel) setRevset(d.sel); done(); }}/>
        </div>;
      })()}
      {projectsOpen && window.ZanshinDesignSystem_a33847.Window && <window.ZKProjects tree={tree} setTree={setTree} activeId={activeId} active={key === "projects"} onFocus={() => setKey("projects")}
        style={{ left: settingsOpen ? 24 : "calc(50% - 450px)", top: 56, zIndex: key === "projects" ? 2 : 1 }}
        onOpen={(id) => { setActiveId(id); closeWindow("projects"); }} onClose={() => closeWindow("projects")} onSettings={() => openSettings()}/>}
      {settingsOpen && window.ZanshinDesignSystem_a33847.Window && <window.ZKSettings tab={setTab} setTab={setSetTab} page={setPage} setPage={setSetPage} imm={imm} setImm={setImm} trunk={trunk} setTrunk={setTrunk} immInfo={immInfo} active={key === "settings"} onFocus={() => setKey("settings")}
        style={{ left: projectsOpen ? "auto" : "calc(50% - 310px)", right: projectsOpen ? 24 : "auto", top: 40, zIndex: key === "settings" ? 2 : 1 }}
        onClose={() => closeWindow("settings")} prefs={prefs} setPref={setPref} project={project}/>}
    </div>
    </>
  );
}

Object.assign(window, { ZKApp });
})();
