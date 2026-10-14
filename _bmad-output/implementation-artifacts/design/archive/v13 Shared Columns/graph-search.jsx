/* global React, ReactDOM */
// Graph search — the top-centre capsule as one field: [menu ▾ | query | ✕].
// One menu: the default search, the other jj log variants (built-ins + configurations), Go to / Filter by, Edit Configurations….
// The field holds one thing: nothing (= the default search, so you can type straight away), a typed search, or the name of the
// variant the graph shows. ✕ always returns to the default search. Go-to scopes (Change, Bookmark) select a change and leave
// the graph as it is; filter scopes (Author, File, Description) redraw it — a typed search runs in all(). There is no Save:
// configurations are made and edited in the dialog only, which also sets the default search.
// Explored in "Search Study.html" (model "One menu"; search-study.jsx / search-one.jsx keep the variants for experiments).
(() => {
const { useState, useEffect, useRef, useMemo } = React;
const Ic = (p) => <window.Icon {...p}/>;
const RS = window.RevsetStore;

// the mock graph only carries stats — give every change the paths the inspector shows, so files() and the suggestions agree
(() => {
  const all = window.GRAPH_COMMITS || [];
  if (!window.buildDiffs) return;
  const D = window.buildDiffs(all);
  all.forEach(c => { if (!c.files || !c.files.length) c.files = (D[c.id] || []).map(f => ({ path: f.path, status: f.status })); });
})();

// ---------- recent searches ----------
const RKEY = "zanshin.graph.recentSearches", EMBED = new URLSearchParams(location.search).has("embed");
let recents = [
  { k: "author", m: "exact", v: "Lena König" },
  { k: "change", v: "plkmnvxo" },
  { k: "files", m: "prefix", v: "lib/features/settings/" },
  { k: "description", m: "substring", ci: true, v: "cache" },
];
if (!EMBED) try { const s = localStorage.getItem(RKEY); if (s) recents = JSON.parse(s); } catch {}
const rsubs = new Set();
const setRecents = (n) => { recents = n; if (!EMBED) try { localStorage.setItem(RKEY, JSON.stringify(n)); } catch {} rsubs.forEach(f => f()); };
const same = (a, b) => !!a && !!b && a.k === b.k && (a.m || "") === (b.m || "") && a.v === b.v && !!a.ci === !!b.ci;
const pushRecent = (r) => setRecents([{ k: r.k, m: r.m, v: r.v, ci: r.ci || undefined }, ...recents.filter(x => !same(x, r))].slice(0, 10));
function useRecents() {
  const [, f] = useState(0);
  useEffect(() => { const g = () => f(x => x + 1); rsubs.add(g); return () => rsubs.delete(g); }, []);
  return recents;
}

// ---------- scopes ----------
const SCOPES = {
  any: { label: "Any", ph: "Search changes, bookmarks, authors, files…", short: "Search…" },
  change: { label: "Change", go: true, pre: "c:", desc: "change ID · commit ID · description", ph: "Change ID, commit ID or description", short: "Change ID or hash" },
  bookmark: { label: "Bookmark", go: true, pre: "b:", desc: "name", ph: "Bookmark name" },
  author: { label: "Author", pre: "a:", desc: "author()", ph: "Author name" },
  file: { label: "File", pre: "f:", desc: "files()", ph: "Path, folder or glob", short: "Path or glob" },
  description: { label: "Description", pre: "d:", desc: "description()", ph: "Text in descriptions", short: "Text" },
};
const GO = ["change", "bookmark"], FILTER = ["author", "file", "description"];
const PRE = { c: "change", change: "change", commit: "change", b: "bookmark", bookmark: "bookmark", a: "author", author: "author", f: "file", file: "file", files: "file", d: "description", desc: "description", description: "description" };
const PRE_RE = /^(c|change|commit|b|bookmark|a|author|f|files?|d|desc|description):\s*/i;
const scopeOf = (s) => s.k === "files" ? "file" : s.k === "description" ? "description" : "author";
const textOf = (s) => s.k === "mine" ? RS.ME : s.v;
const labelOf = (s) => s.k === "mine" ? RS.ME + " (you)" : s.k === "description" ? "“" + s.v + "”" : s.v;
const iconOf = (s) => s.k === "files" ? (s.m === "prefix" ? "dir" : "file") : s.k === "description" ? "description" : "author";
const nLabel = (n) => n === 1 ? "1 change" : n + " changes";
// which recent searches a scope lists while its field is still empty
const FITS = { any: () => true, change: (r) => r.k === "change", bookmark: () => false, author: (r) => r.k === "author" || r.k === "mine", file: (r) => r.k === "files", description: (r) => r.k === "description" };

// ---------- jj log variants ----------
const BNAME = { default: "jj log", all: "all()" };
const BDESC = { default: "Your mutable changes plus trunk context", all: "Every visible commit, incl. immutable history" };
const isB = (id) => RS.BUILTIN.some(b => b.id === id);
// $ marks a variant that draws the graph
const Dollar = () => <span className="gs-dollar" aria-hidden="true">$</span>;

const svg = (size, kids) => <svg width={size} height={size} viewBox="0 0 16 16" aria-hidden="true" style={{ flexShrink: 0 }}>{kids}</svg>;
function SIcon({ id, size = 14 }) {
  if (id === "change") return svg(size, <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round"><circle cx="8" cy="8" r="2.6"/><path d="M1.5 8h3.9M10.6 8h3.9"/></g>);
  if (id === "description") return svg(size, <path d="M3 4.5h10M3 8h10M3 11.5h6" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round"/>);
  if (id === "bookmark") return <window.BookmarkGlyph size={size}/>;
  return <Ic name={{ any: "search", author: "user", file: "file", dir: "folder" }[id] || "search"} size={size}/>;
}

// ---------- matching ----------
const lc = (s) => (s || "").toLowerCase();
const at = (text, q, from = 0) => { const i = lc(text).indexOf(q, from); return i < 0 ? null : [i, i + q.length]; };
const wordAt = (s, i) => i === 0 || /[^a-z0-9]/i.test(s[i - 1]);
// dim everything before `split`, underline the match
function Hl({ text, r, split = 0 }) {
  const s = r ? r[0] : -1, e = r ? r[1] : -1;
  const cuts = [...new Set([0, split, s, e, text.length])].filter(x => x >= 0 && x <= text.length).sort((a, b) => a - b);
  const out = [];
  for (let i = 0; i < cuts.length - 1; i++) {
    const a = cuts[i], b = cuts[i + 1];
    if (a === b) continue;
    const cls = [a < split && "gs-d", r && a >= s && b <= e && "gs-m"].filter(Boolean).join(" ");
    out.push(cls ? <span key={a} className={cls}>{text.slice(a, b)}</span> : <React.Fragment key={a}>{text.slice(a, b)}</React.Fragment>);
  }
  return out;
}

function buildIndex(all) {
  const commits = all.filter(c => !c.isRoot && !c.isGroup);
  const authors = new Set(), paths = new Set(), dirs = new Set(), bms = [];
  commits.forEach(c => {
    if (c.author) authors.add(c.author);
    (c.files || []).forEach(({ path }) => {
      paths.add(path);
      const seg = path.split("/");
      for (let i = 1; i < seg.length; i++) dirs.add(seg.slice(0, i).join("/") + "/");
    });
    (c.bookmarks || []).forEach(b => bms.push({ name: b.name, c }));
  });
  return { commits, authors, paths, dirs, bms };
}

// rows either select a change (go) or are a search (s); score orders rows and, in Any, the groups
function suggest(ix, scope, raw) {
  const q = lc(raw.trim()), v = raw.trim();
  const G = { change: [], bookmark: [], author: [], file: [], description: [] };
  if (!q) return G;
  const want = (x) => scope === "any" || scope === x;
  const idLike = /^[k-z]{3,}$/.test(q), hashLike = /^[0-9a-f]{4,}$/.test(q), pathLike = /[/*?]|\.\w+$/.test(q);
  if (want("change") || scope === "description") {
    ix.commits.forEach(c => {
      let r = null, score = 0, how;
      if (c.id.startsWith(q)) { score = 100; how = "id"; }
      else if (q.length >= 3 && (c.commitId || "").startsWith(q)) { score = 96; how = "hash"; }
      else if ((r = at(c.subject, q))) { score = wordAt(c.subject, r[0]) ? 58 : 46; how = "subject"; }
      else if (at(c.description, q)) { score = 36; how = "body"; }
      if (score) G.change.push({ key: "c:" + c.id, kind: "change", c, how, r, q, go: c.id, score: score + (idLike || hashLike ? 20 : 0) });
    });
    G.change.sort((a, b) => b.score - a.score || (b.c.ts || "").localeCompare(a.c.ts || ""));
  }
  if (want("bookmark")) {
    ix.bms.forEach(({ name, c }) => { const r = at(name, q); if (r) G.bookmark.push({ key: "b:" + name, kind: "bookmark", name, c, r, go: c.id, score: r[0] === 0 ? 86 : wordAt(name, r[0]) ? 74 : 60 }); });
    G.bookmark.sort((a, b) => b.score - a.score || a.name.length - b.name.length);
  }
  if (want("author")) {
    ix.authors.forEach(name => {
      const r = at(name, q);
      if (r) G.author.push({ key: "a:" + name, kind: "author", name, me: name === RS.ME, r, s: name === RS.ME ? { k: "mine" } : { k: "author", m: "exact", v: name }, score: wordAt(name, r[0]) ? 84 : 62 });
    });
    G.author.sort((a, b) => b.score - a.score);
    if (scope === "author" && G.author.length !== 1) G.author.push({ key: "a~" + q, kind: "contains", v, s: { k: "author", m: "substring", ci: true, v }, score: 10 });
  }
  if (want("file")) {
    if (/[*?]/.test(q)) G.file.push({ key: "g:" + q, kind: "glob", v, s: { k: "files", m: "glob", v }, score: 90 });
    else {
      const add = (p, dir) => {
        const base = p.replace(/\/$/, "").lastIndexOf("/") + 1, r = at(p, q, base) || at(p, q);
        if (!r) return;
        let score = r[0] >= base ? (r[0] === base ? 82 : 64) : wordAt(p, r[0]) ? 60 : 48;
        if (dir && r[0] >= base) score += 4;
        G.file.push({ key: "f:" + p, kind: dir ? "dir" : "path", p, r, split: base, s: { k: "files", m: dir ? "prefix" : "file", v: p }, score: score + (pathLike ? 20 : 0) - p.length / 400 });
      };
      ix.dirs.forEach(d => add(d, true));
      ix.paths.forEach(p => add(p, false));
      G.file.sort((a, b) => b.score - a.score);
    }
  }
  if (want("description")) G.description.push({ key: "d:" + q, kind: "desc", v, s: { k: "description", m: "substring", ci: true, v }, score: 24 });
  return G;
}
const LIMIT = { change: 3, bookmark: 2, author: 2, file: 3, description: 1 };
const GLABEL = { change: "Changes", bookmark: "Bookmarks", author: "Authors", file: "Files", description: "Descriptions" };
function compose(G, scope, count) {
  const n = (rows) => rows.map(r => r.s ? { ...r, n: count(r.s) } : r).filter(r => !r.s || r.n > 0);
  if (scope === "any") return Object.keys(G).map(k => {
    const rows = n(G[k].slice(0, LIMIT[k])), more = G[k].length - LIMIT[k];
    if (rows.length && more > 0) rows.push({ key: "more:" + k, kind: "more", scope: k, n: more, score: 0 });
    return { id: k, label: GLABEL[k], rows };
  }).filter(g => g.rows.length).sort((a, b) => b.rows[0].score - a.rows[0].score);
  if (scope === "description") {
    const ch = G.change.filter(r => r.how === "subject" || r.how === "body").slice(0, 6);
    return [{ id: "description", rows: n(G.description) }, { id: "change", label: "Changes", rows: ch }].filter(g => g.rows.length);
  }
  const rows = n(G[scope].slice(0, 8));
  return rows.length ? [{ id: scope, rows }] : [];
}

// ============================================================
// GRAPH SEARCH
// ============================================================
function GraphSearch({ api }) {
  const configs = RS.useStore();
  const rec = useRecents();
  const home = RS.getHome();
  const active = RS.parseSearch(api.revset);
  const view = active ? null : api.revset;
  const atHome = !active && api.revset === home;
  const viewName = (id) => BNAME[id] || (configs.find(c => c.id === id) || {}).name || "Unnamed";
  const [scope, setScope] = useState(() => active ? scopeOf(active) : "any");
  const [text, setText] = useState(() => active ? textOf(active) : "");
  const [focus, setFocus] = useState(false);
  const [pop, setPop] = useState(null);           // sugg · menu
  const [hi, setHi] = useState(0);
  const [editing, setEditing] = useState(false);  // configurations dialog
  const [, tick] = useState(0);
  const rootRef = useRef(null), inRef = useRef(null), listRef = useRef(null), menuRef = useRef(null);
  const focusRef = useRef(false), leaving = useRef(false), quiet = useRef(false), justFocused = useRef(false), pend = useRef(null);
  const ix = useMemo(() => buildIndex(api.all), [api.all]);
  const inView = useMemo(() => window.revsetMatch(api.revset), [api.revset, configs]);
  // a typed search replaces what the graph shows: it runs in all()
  const mk = (s) => ({ k: s.k, m: s.m, v: s.v, ci: s.ci });
  const count = (s) => { const m = window.revsetMatch(RS.encodeSearch(mk(s))); return ix.commits.filter(m).length; };
  const savedExprs = useMemo(() => new Set(configs.map(c => RS.exprOf(c))), [configs]);
  const unsaved = (r) => !savedExprs.has(RS.searchExpr(mk(r)));
  const [narrow, setNarrow] = useState(() => window.matchMedia("(max-width: 980px)").matches);
  useEffect(() => { const m = window.matchMedia("(max-width: 980px)"), h = () => setNarrow(m.matches); m.addEventListener("change", h); return () => m.removeEventListener("change", h); }, []);
  const focusQuiet = () => { const i = inRef.current; if (!i) return; quiet.current = true; i.focus(); quiet.current = false; const n = i.value.length; i.setSelectionRange(n, n); };
  const revert = () => { setText(active ? textOf(active) : ""); setScope(active ? scopeOf(active) : "any"); };

  // the field follows the graph: a typed search shows as scope + text; a variant leaves the text empty
  useEffect(() => {
    const s = RS.parseSearch(api.revset);
    if (s) { setScope(scopeOf(s)); if (!focusRef.current) setText(textOf(s)); }
    else if (!focusRef.current) { setText(""); setScope("any"); }
  }, [api.revset]);
  // a search kept from the earlier model (narrowing a variant) becomes a plain one; a configuration that is gone falls back to the default search
  useEffect(() => {
    if (active) { const n = RS.encodeSearch(mk(active)); if (n !== api.revset) api.setRevset(n); }
    else if (!isB(api.revset) && !configs.some(c => c.id === api.revset)) api.setRevset(home);
  }, [api.revset, configs, home]);
  // ⌘F, or / outside a text field
  useEffect(() => {
    const k = (e) => {
      const el = e.target, typing = el && (/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) || el.isContentEditable);
      const cmdF = (e.metaKey || e.ctrlKey) && !e.shiftKey && !e.altKey && e.key.toLowerCase() === "f";
      if (cmdF || (e.key === "/" && !typing && !e.metaKey && !e.ctrlKey && !e.altKey)) { e.preventDefault(); const i = inRef.current; if (i) { i.focus(); i.select(); } }
    };
    window.addEventListener("keydown", k);
    return () => window.removeEventListener("keydown", k);
  }, []);
  // a click outside closes what is open and drops an unapplied draft; Esc closes the menu (the field handles its own Esc)
  useEffect(() => {
    if (!pop) return;
    const down = (e) => { if (rootRef.current && !rootRef.current.contains(e.target)) { setPop(null); if (!focusRef.current) revert(); } };
    const key = (e) => {
      if (e.key !== "Escape" || pop !== "menu") return;
      e.stopPropagation(); e.preventDefault(); setPop(null); revert();
      const b = rootRef.current && rootRef.current.querySelector(".gs-scope"); if (b) b.focus();
    };
    window.addEventListener("pointerdown", down, true); window.addEventListener("keydown", key, true);
    return () => { window.removeEventListener("pointerdown", down, true); window.removeEventListener("keydown", key, true); };
  }, [pop, api.revset]);
  useEffect(() => { if (pop !== "menu" || !menuRef.current) return; const b = menuRef.current.querySelector(".gs-srow.on") || menuRef.current.querySelector(".gs-srow"); if (b) b.focus({ preventScroll: true }); }, [pop]);
  // go-to: select the change; a view that hides it falls back to all() (as the bookmark list does), a collapsed stack opens
  useEffect(() => {
    const p = pend.current;
    if (!p) return;
    if (api.visibleSet.has(p.id) || p.tries > 2) { pend.current = null; api.pickBookmark(p.id); return; }
    const run = api.stacks && window.groupStacks(api.all, api.revset, []).runs.find(r => r.members.some(m => m.id === p.id));
    const el = run && document.querySelector('.gstack[data-change="' + run.id + '"]');
    if (el) { p.tries++; el.click(); } else { pend.current = null; api.pickBookmark(p.id); }
  });
  useEffect(() => {
    const l = listRef.current, el = l && l.querySelector('[data-i="' + hi + '"]');
    if (!el) return;
    if (el.offsetTop < l.scrollTop) l.scrollTop = el.offsetTop - 6;
    else if (el.offsetTop + el.offsetHeight > l.scrollTop + l.clientHeight) l.scrollTop = el.offsetTop + el.offsetHeight - l.clientHeight + 6;
  }, [hi]);

  const q = text.trim();
  // recent searches (go-tos and filters) while the field is empty; a filter that became a configuration lives in the menu instead
  const recentRows = pop === "sugg" && !q ? rec.filter(r => FITS[scope](r) && (r.k === "change" ? ix.commits.some(c => c.id === r.v) : unsaved(r))).slice(0, 6).map(r => r.k === "change"
    ? { key: "r:c:" + r.v, kind: "change", c: ix.commits.find(c => c.id === r.v), go: r.v }
    : { key: "r:" + RS.encodeSearch(r), kind: "recent", r, s: r, n: count(r) }) : [];
  const groups = useMemo(() => {
    if (pop !== "sugg" || !q) return null;
    let gs = compose(suggest(ix, scope, q), scope, count), other = false;
    if (!gs.length && scope !== "any") { gs = compose(suggest(ix, "any", q), "any", count); other = gs.length > 0; }
    return { gs, other };
  }, [pop, q, scope, ix]);
  const nav = groups ? groups.gs.flatMap(g => g.rows) : recentRows;
  const hiN = Math.min(hi, Math.max(0, nav.length - 1)), cur = nav[hiN];

  // ---------- actions ----------
  const close = () => setPop(null);
  const leave = () => { close(); leaving.current = true; if (inRef.current) inRef.current.blur(); leaving.current = false; };
  const apply = (s) => { pushRecent(s); api.setRevset(RS.encodeSearch(mk(s))); setScope(scopeOf(s)); setText(textOf(s)); leave(); };
  const goTo = (id) => {
    const c = ix.commits.find(x => x.id === id);
    if (!c) return;
    pushRecent({ k: "change", v: id });
    revert(); leave();
    if (api.visibleSet.has(id)) { api.pickBookmark(id); return; }
    pend.current = { id, tries: 0 };
    if (!inView(c)) api.setRevset("all"); else tick(x => x + 1);
  };
  const pick = (row) => {
    if (row.kind === "more") { setScope(row.scope); setHi(0); return; }
    if (row.go) goTo(row.go); else if (row.s) apply(row.s);
  };
  const clear = () => {
    setText(""); setScope("any"); if (api.revset !== home) api.setRevset(home);
    if (focusRef.current) { setHi(0); setPop("sugg"); } else close();
  };
  const pickView = (id) => { close(); setText(""); setScope("any"); api.setRevset(id); };
  // a scope keeps what you were typing; the value of the active search makes room for a new one
  const pickScope = (id) => {
    const draft = text !== (active ? textOf(active) : "");
    setScope(id); setHi(0); if (!draft) setText("");
    focusQuiet(); setPop("sugg");
  };

  // ---------- field ----------
  const onChange = (e) => {
    let v = e.target.value;
    const m = v.match(PRE_RE);
    if (m) { setScope(PRE[m[1].toLowerCase()]); v = v.slice(m[0].length); }
    setText(v); setHi(0); setPop("sugg");
  };
  const onKey = (e) => {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      if (pop !== "sugg") { setPop("sugg"); setHi(0); return; }
      if (nav.length) setHi((hiN + (e.key === "ArrowDown" ? 1 : -1) + nav.length) % nav.length);
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (pop === "sugg" && cur) pick(cur); else if (q) setPop("sugg");
    } else if (e.key === "Escape") {
      e.preventDefault(); e.stopPropagation();
      if (pop) close(); else { revert(); leave(); }
    } else if (e.key === "Backspace" && !text && scope !== "any") {
      e.preventDefault(); setScope("any"); setHi(0);
    }
  };
  const onFocus = (e) => {
    focusRef.current = true; setFocus(true);
    if (!quiet.current) { justFocused.current = true; e.target.select(); }
    setPop("sugg"); setHi(0);
  };
  const onMouseUp = (e) => { if (justFocused.current) { justFocused.current = false; e.preventDefault(); } };
  const onBlur = (e) => {
    focusRef.current = false; setFocus(false); justFocused.current = false;
    if (leaving.current || (rootRef.current && rootRef.current.contains(e.relatedTarget))) return;
    if (pop === "sugg") close();
    revert();
  };

  // ---------- suggestion rows ----------
  const renderRow = (r, i) => {
    const on = i === hiN;
    let ic, main, meta = null;
    if (r.kind === "change") {
      const c = r.c, n = r.how === "id" ? r.q.length : 2;
      ic = <SIcon id="change"/>;
      main = <>
        {c.isWorkingCopy && <span className="gat">@</span>}
        <span className="gcid"><b>{c.id.slice(0, n)}</b>{c.id.slice(n, 8)}</span>
        {r.how === "hash" && <span className="gcid gs-hash"><b>{c.commitId.slice(0, r.q.length)}</b>{c.commitId.slice(r.q.length, 8)}</span>}
        <span className={"gs-subj" + (/^\(no description/.test(c.subject) ? " is-dim" : "")}>{r.how === "subject" ? <Hl text={c.subject} r={r.r}/> : c.subject}</span>
      </>;
      meta = <>{!inView(c) && <span className="gs-tag">not in view</span>}<span>{(c.author || "").split(" ")[0]}{c.date ? " · " + c.date : ""}</span></>;
    } else if (r.kind === "bookmark") {
      ic = <SIcon id="bookmark"/>;
      main = <span className="gs-nm"><Hl text={r.name} r={r.r}/></span>;
      meta = <>{!inView(r.c) && <span className="gs-tag">not in view</span>}<span className="gcid"><b>{r.c.id.slice(0, 2)}</b>{r.c.id.slice(2, 8)}</span></>;
    } else if (r.kind === "author") {
      ic = <span className="gs-av">{r.name.trim()[0]}</span>;
      main = <><span className="gs-nm"><Hl text={r.name} r={r.r}/></span>{r.me && <span className="gs-tag">you · mine()</span>}</>;
      meta = nLabel(r.n);
    } else if (r.kind === "contains") {
      ic = <SIcon id="author"/>;
      main = <span className="gs-nm">Authors containing <span className="gs-qt">“{r.v}”</span></span>;
      meta = nLabel(r.n);
    } else if (r.kind === "dir" || r.kind === "path") {
      ic = <SIcon id={r.kind === "dir" ? "dir" : "file"}/>;
      main = <span className="gs-path"><Hl text={r.p} r={r.r} split={r.split}/></span>;
      meta = nLabel(r.n);
    } else if (r.kind === "glob") {
      ic = <SIcon id="file"/>;
      main = <><span className="gs-path">{r.v}</span><span className="gs-tag">glob</span></>;
      meta = nLabel(r.n);
    } else if (r.kind === "desc") {
      ic = <SIcon id="description"/>;
      main = <span className="gs-nm">Descriptions containing <span className="gs-qt">“{r.v}”</span></span>;
      meta = nLabel(r.n);
    } else if (r.kind === "recent") {
      ic = <SIcon id={iconOf(r.r)}/>;
      main = <><span className="gs-nm">{labelOf(r.r)}</span><code className="gs-sub">{RS.searchExpr(mk(r.r))}</code></>;
      meta = nLabel(r.n);
    } else if (r.kind === "more") {
      ic = null;
      main = <span className="gs-more">{r.n} more in {SCOPES[r.scope].label}</span>;
      meta = <Ic name="chevronRight" size={12}/>;
    }
    return (
      <div key={r.key} data-i={i} id={"gs-o-" + i} role="option" aria-selected={on} className={"gs-row" + (on ? " on" : "") + (r.kind === "more" ? " is-more" : "")}
        onClick={() => pick(r)} onMouseMove={() => { if (!on) setHi(i); }}>
        <span className="gs-ic">{ic}</span><span className="gs-main">{main}</span><span className="gs-meta">{meta}</span>
      </div>
    );
  };
  const foot = (r) => {
    if (r.kind === "more") return <><span className="gs-ft-t">Narrows the search to {SCOPES[r.scope].label.toLowerCase()}s</span><span className="gs-ft-k">Show<kbd>↵</kbd></span></>;
    if (r.go) {
      const c = r.c || ix.commits.find(x => x.id === r.go), hidden = c && !inView(c);
      return <><span className="gs-ft-t">{hidden ? <>Not in this view — switches to <code>all()</code> and selects it</> : "Selects the change — the graph stays as it is"}</span><span className="gs-ft-k">{hidden ? "Show" : "Select"}<kbd>↵</kbd></span></>;
    }
    const cmd = RS.searchCmd(mk(r.s));
    return <><span className="gs-ft-t" title={cmd}><code>{cmd}</code></span><span className="gs-ft-k">Filter<kbd>↵</kbd></span></>;
  };
  const recentLabel = scope === "any" ? "Recent" : "Recent " + (scope === "change" ? "changes" : SCOPES[scope].label.toLowerCase() + "s");
  const suggPop = () => (
    <div className="gs-pop" onMouseDown={(e) => { if (!e.target.closest("input")) e.preventDefault(); }}>
      <div className="gs-list" id="gs-list" role="listbox" aria-label="Suggestions" ref={listRef}>
        {groups ? <>
          {groups.other && <div className="gs-note">No {SCOPES[scope].label.toLowerCase()} matches “{q}” — found elsewhere:</div>}
          {groups.gs.map(g => (
            <React.Fragment key={g.id}>
              {g.label && (scope === "any" || groups.other || scope === "description") && <div className="gs-gh"><span>{g.label}</span></div>}
              {g.rows.map(r => renderRow(r, nav.indexOf(r)))}
            </React.Fragment>
          ))}
          {!groups.gs.length && <div className="gs-empty">Nothing matches “{q}”{scope !== "any" ? " — in any scope" : ""}.</div>}
        </> : <>
          <div className="gs-gh"><span>{recentLabel}</span><button onClick={() => setRecents([])}>Clear</button></div>
          {recentRows.map((r, i) => renderRow(r, i))}
        </>}
      </div>
      {cur && <div className="gs-ft">{foot(cur)}</div>}
    </div>
  );

  // ---------- the one menu: default search · other variants · go to / filter by · edit ----------
  const arrows = (e) => {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    e.preventDefault();
    const bs = [...e.currentTarget.querySelectorAll("button")], i = bs.indexOf(document.activeElement);
    const n = bs[(i + (e.key === "ArrowDown" ? 1 : -1) + bs.length) % bs.length];
    if (n) n.focus();
  };
  const onScope = active ? scopeOf(active) : null;
  const sRow = (id) => {
    const on = onScope === id;
    return (
      <button key={id} role="option" aria-selected={on} className={"gs-srow" + (on ? " on" : "")} onClick={() => pickScope(id)}>
        <span className="gs-ic"><SIcon id={id}/></span>
        <span className="gs-sl">{SCOPES[id].label}</span>
        <span className={"gs-sd" + (on ? " is-val" : FILTER.includes(id) ? " mono" : "")}>{on ? textOf(active) : SCOPES[id].desc}</span>
        <kbd>{SCOPES[id].pre}</kbd>
      </button>
    );
  };
  const vRow = (id, first) => {
    const b = RS.BUILTIN.find(x => x.id === id), c = !b && configs.find(x => x.id === id);
    if (!b && !c) return null;
    const on = !active && api.revset === id;
    return (
      <button key={"v:" + id} role="option" aria-selected={on} className={"gs-srow gs-vrow" + (on ? " on" : "")} onClick={() => pickView(id)} title={b ? b.cmd : RS.cmdOf(c)}>
        <span className="gs-ic"><Dollar/></span>
        <span className="gs-sl">{b ? <code>{BNAME[id]}</code> : c.name || "Unnamed"}</span>
        <span className={"gs-sd" + (b ? "" : " mono")}>{b ? BDESC[id] : RS.exprOf(c)}</span>
        {first ? <span className="gs-tag">Default</span> : <span></span>}
      </button>
    );
  };
  const rest = [...RS.BUILTIN.map(b => b.id), ...configs.map(c => c.id)].filter(id => id !== home);
  const menu = () => (
    <div className="gs-scopes" role="listbox" aria-label="Search menu" onKeyDown={arrows} ref={menuRef}>
      {vRow(home, true)}
      {rest.map(id => vRow(id))}
      <div className="gs-msep"></div>
      <div className="gs-gh"><span>Go to</span><em>selects a change · graph stays</em></div>
      {GO.map(sRow)}
      <div className="gs-gh"><span>Filter by</span><em>redraws the graph</em></div>
      {FILTER.map(sRow)}
      <div className="gs-msep"></div>
      <button className="gs-srow gs-edit" onClick={() => { close(); setEditing(true); }}>
        <span className="gs-ic"><Ic name="settings" size={13}/></span>
        <span className="gs-sl">Edit Configurations…</span>
      </button>
    </div>
  );

  // ---------- render ----------
  const sc = SCOPES[scope];
  const showView = !focus && !active && !atHome;   // at rest on another variant: its name stands in the field
  const homeName = viewName(home);
  const pillTitle = focus || active ? "Search in: " + sc.label + (sc.go ? " — selects a change" : scope === "any" ? "" : " — filters the graph") : atHome ? "Default search: " + homeName : "Showing " + viewName(view);
  return (
    <div className={"gs" + (focus ? " is-focus" : "") + (!atHome ? " has-q" : "")} ref={rootRef}>
      <button className={"gs-scope" + (showView || scope === "any" ? " is-any" : "") + (pop === "menu" ? " open" : "")} onClick={() => setPop(p => p === "menu" ? null : "menu")}
        aria-haspopup="listbox" aria-expanded={pop === "menu"} aria-label="Search menu" title={pillTitle}>
        {showView ? <Dollar/> : <><SIcon id={scope}/>{scope !== "any" && <span>{sc.label}</span>}</>}<Ic name="chevronDown" size={12}/>
      </button>
      <input ref={inRef} className={"gs-in" + (showView ? " is-val" + (isB(view) ? " mono" : "") : scope === "change" || scope === "file" ? " mono" : "")} value={text}
        placeholder={showView ? viewName(view) : narrow ? sc.short || sc.ph : sc.ph} spellCheck="false" autoComplete="off"
        role="combobox" aria-label="Search the graph" aria-expanded={pop === "sugg" && nav.length > 0} aria-controls="gs-list" aria-activedescendant={pop === "sugg" && cur ? "gs-o-" + hiN : undefined}
        onChange={onChange} onKeyDown={onKey} onFocus={onFocus} onBlur={onBlur} onMouseUp={onMouseUp}/>
      {!text && !focus && atHome && <kbd className="gs-k" aria-hidden="true">⌘F</kbd>}
      {(text || !atHome) && <button className="gs-x" onMouseDown={(e) => { if (focus) e.preventDefault(); }} onClick={clear} aria-label={atHome ? "Clear" : "Back to the default search"} title={atHome ? "Clear" : "Back to the default search — " + homeName}><Ic name="close" size={10}/></button>}
      {pop === "sugg" && (groups || recentRows.length > 0) && suggPop()}
      {pop === "menu" && menu()}
      {editing && ReactDOM.createPortal(<window.RevsetDialog withHome initial={view || home} onClose={() => setEditing(false)} onApply={(id) => { if (id) api.setRevset(id); }}/>, document.querySelector(".fwin") || document.body)}
    </div>
  );
}

Object.assign(window, { GraphSearch });
})();
