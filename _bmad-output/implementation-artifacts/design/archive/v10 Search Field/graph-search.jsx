/* global React, ReactDOM */
// Graph search — the top-centre capsule as one field: [scope ▾ | query | jj log variant ▾].
// Go-to scopes (Change, Bookmark) select a change and leave the graph as it is.
// Filter scopes (Author, File, Description) narrow the selected variant (base & search); the variant then reads "in …",
// and its menu hides variants that can't match together with the search. Recent searches and Save live in the field.
// Explored in "Search Study.html" (search-study.jsx keeps every variant for further experiments).
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
const dropRecent = (r) => setRecents(recents.filter(x => !same(x, r)));
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
const nameOf = (s) => s.k === "mine" ? "My changes" : s.k === "files" ? s.v.replace(/\/$/, "").split("/").pop() + (s.m === "prefix" ? "/" : "") : s.k === "description" ? "“" + s.v + "”" : s.v;
const labelOf = (s) => s.k === "mine" ? RS.ME + " (you)" : s.k === "description" ? "“" + s.v + "”" : s.v;
const iconOf = (s) => s.k === "files" ? (s.m === "prefix" ? "dir" : "file") : s.k === "description" ? "description" : "author";
const fieldOf = (s) => s.k === "mine" || s.k === "author" ? "author" : s.k === "files" ? "files" : "description";
const nLabel = (n) => n === 1 ? "1 change" : n + " changes";

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

// ---------- small forms ----------
function SaveInline({ icon, name, onSave, onCancel }) {
  const [v, setV] = useState(name);
  const ref = useRef(null);
  useEffect(() => { const i = ref.current; if (i) { i.focus(); i.select(); } }, []);
  return (
    <form className="gs-rform" onSubmit={(e) => { e.preventDefault(); onSave(v); }} onKeyDown={(e) => { if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); onCancel(); } }}>
      <span className="chk">{icon}</span>
      <input ref={ref} className="gs-name" value={v} onChange={(e) => setV(e.target.value)} aria-label="Name for the filter" spellCheck="false"/>
      <button type="submit" className="gs-btn primary">Save</button>
    </form>
  );
}
function SavePop({ name, cmd, onSave, onCancel }) {
  const [v, setV] = useState(name);
  const ref = useRef(null);
  useEffect(() => { const i = ref.current; if (i) { i.focus(); i.select(); } }, []);
  return (
    <form className="gs-savepop" role="dialog" aria-label="Save as filter" onSubmit={(e) => { e.preventDefault(); onSave(v); }}>
      <div className="gs-sp-h">Save as filter</div>
      <input ref={ref} className="gs-name" value={v} onChange={(e) => setV(e.target.value)} aria-label="Name for the filter" spellCheck="false"/>
      <code className="gs-sp-cmd" title={cmd}>{cmd}</code>
      <div className="gs-btns"><button type="button" className="gs-btn" onClick={onCancel}>Cancel</button><button type="submit" className="gs-btn primary">Save</button></div>
    </form>
  );
}

// ============================================================
// GRAPH SEARCH
// ============================================================
function GraphSearch({ api }) {
  const configs = RS.useStore();
  const rec = useRecents();
  const active = RS.parseSearch(api.revset);
  const baseId = active ? active.b || "default" : api.revset;
  const [scope, setScope] = useState(() => active ? scopeOf(active) : "any");
  const [text, setText] = useState(() => active ? textOf(active) : "");
  const [focus, setFocus] = useState(false);
  const [pop, setPop] = useState(null);           // sugg · scope · rev · save
  const [hi, setHi] = useState(0);
  const [saving, setSaving] = useState(null);     // key of the recent being named in place
  const [editing, setEditing] = useState(false);  // configurations dialog
  const [flash, setFlash] = useState(false);
  const [, tick] = useState(0);
  const rootRef = useRef(null), inRef = useRef(null), listRef = useRef(null), scopeRef = useRef(null);
  const focusRef = useRef(false), leaving = useRef(false), quiet = useRef(false), justFocused = useRef(false), pend = useRef(null), flashT = useRef(0);
  const ix = useMemo(() => buildIndex(api.all), [api.all]);
  const inView = useMemo(() => window.revsetMatch(api.revset), [api.revset, configs]);
  const mk = (s) => ({ ...s, b: baseId, w: true });
  const count = (s) => { const m = window.revsetMatch(RS.encodeSearch(mk(s))); return ix.commits.filter(m).length; };
  const savedExprs = useMemo(() => new Set(configs.map(c => RS.exprOf(c))), [configs]);
  const unsaved = (r) => !savedExprs.has(RS.searchExpr(mk(r)));
  const [narrow, setNarrow] = useState(() => window.matchMedia("(max-width: 980px)").matches);
  useEffect(() => { const m = window.matchMedia("(max-width: 980px)"), h = () => setNarrow(m.matches); m.addEventListener("change", h); return () => m.removeEventListener("change", h); }, []);
  const focusQuiet = () => { const i = inRef.current; if (!i) return; quiet.current = true; i.focus(); quiet.current = false; const n = i.value.length; i.setSelectionRange(n, n); };

  // the field follows the graph: a search revset shows as scope + text, any other variant empties it
  useEffect(() => {
    const s = RS.parseSearch(api.revset);
    if (s && !s.w) { api.setRevset(RS.encodeSearch({ ...s, w: true })); return; }   // a search always narrows its variant
    if (s) { setScope(scopeOf(s)); if (!focusRef.current) setText(textOf(s)); }
    else if (!focusRef.current) { setText(""); setScope("any"); }
  }, [api.revset]);
  useEffect(() => { if (!active && !RS.BUILTIN.some(b => b.id === api.revset) && !configs.some(c => c.id === api.revset)) api.setRevset("default"); }, [api.revset, configs]);
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
  // a click outside closes what is open; Esc closes menus (the field handles its own Esc)
  useEffect(() => {
    if (!pop) return;
    const down = (e) => { if (rootRef.current && !rootRef.current.contains(e.target)) { setPop(null); setSaving(null); } };
    const key = (e) => {
      if (e.key !== "Escape" || (pop === "sugg" && !saving)) return;
      e.stopPropagation(); e.preventDefault();
      if (saving) { setSaving(null); if (pop === "sugg") focusQuiet(); } else setPop(null);
    };
    window.addEventListener("pointerdown", down, true); window.addEventListener("keydown", key, true);
    return () => { window.removeEventListener("pointerdown", down, true); window.removeEventListener("keydown", key, true); };
  }, [pop, saving]);
  useEffect(() => { if (pop === "scope" && scopeRef.current) { const b = scopeRef.current.querySelector(".gs-srow.on"); if (b) b.focus({ preventScroll: true }); } }, [pop]);
  // go-to: select the change; a variant that hides it falls back to all() (as the bookmark list does), a collapsed stack opens
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
  const recent = rec.filter(r => r.k === "change" ? ix.commits.some(c => c.id === r.v) : unsaved(r)).slice(0, 5);
  const groups = useMemo(() => {
    if (pop !== "sugg" || !q) return null;
    let gs = compose(suggest(ix, scope, q), scope, count), other = false;
    if (!gs.length && scope !== "any") { gs = compose(suggest(ix, "any", q), "any", count); other = gs.length > 0; }
    return { gs, other };
  }, [pop, q, scope, ix, baseId, configs]);
  const recentRows = pop === "sugg" && !q ? recent.map(r => r.k === "change"
    ? { key: "r:c:" + r.v, kind: "change", c: ix.commits.find(c => c.id === r.v), go: r.v, recent: r }
    : { key: "r:" + RS.encodeSearch(r), kind: "recent", r, s: r, recent: r }) : [];
  const nav = groups ? groups.gs.flatMap(g => g.rows) : recentRows;
  const hiN = Math.min(hi, Math.max(0, nav.length - 1)), cur = nav[hiN];

  // ---------- actions ----------
  const close = () => { setPop(null); setSaving(null); };
  const leave = () => { close(); leaving.current = true; if (inRef.current) inRef.current.blur(); leaving.current = false; };
  const revert = () => { setText(active ? textOf(active) : ""); if (active) setScope(scopeOf(active)); };
  const apply = (s) => {
    pushRecent(s);
    api.setRevset(RS.encodeSearch(mk(s)));
    setScope(scopeOf(s)); setText(textOf(s)); leave();
  };
  const goTo = (id) => {
    const c = ix.commits.find(x => x.id === id);
    if (!c) return;
    pushRecent({ k: "change", v: id });
    setText(active ? textOf(active) : ""); leave();
    if (api.visibleSet.has(id)) { api.pickBookmark(id); return; }
    pend.current = { id, tries: 0 };
    if (!inView(c)) api.setRevset("all"); else tick(x => x + 1);
  };
  const pick = (row) => {
    if (row.kind === "more") { setScope(row.scope); setHi(0); return; }
    if (row.go) goTo(row.go); else if (row.s) apply(row.s);
  };
  const clear = () => { if (active) api.setRevset(active.b || "default"); setText(""); setScope("any"); close(); };
  const pickVariant = (id) => { close(); api.setRevset(active ? RS.encodeSearch({ ...active, b: id }) : id); };
  const defName = (s) => { const bc = configs.find(c => c.id === baseId); return (bc ? bc.name + " · " : "") + nameOf(s); };
  const save = (s, name) => {
    const cfg = { id: RS.newId(), name: (name || "").trim() || defName(s), op: "&", rules: [RS.searchRule(s)] };
    if (baseId !== "all") cfg.base = baseId;
    RS.setConfigs([...RS.getConfigs(), cfg]);
    dropRecent(s);
    if (same(active, s)) api.setRevset(cfg.id);   // the search became a filter
    close();
    setFlash(false); clearTimeout(flashT.current);
    requestAnimationFrame(() => { setFlash(true); flashT.current = setTimeout(() => setFlash(false), 1400); });
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

  // ---------- rows ----------
  const renderRow = (r, i) => {
    const on = i === hiN;
    if (r.recent && saving === r.key) return <SaveInline key={r.key} icon={<SIcon id={iconOf(r.r)}/>} name={defName(r.r)} onSave={(n) => save(r.r, n)} onCancel={() => { setSaving(null); focusQuiet(); }}/>;
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
      meta = <button className="gs-rsave" onClick={(e) => { e.stopPropagation(); setSaving(r.key); }} title="Save as filter">Save</button>;
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
    return <><span className="gs-ft-t" title={cmd}><code>{cmd}</code></span><span className="gs-ft-k">{baseId !== "all" ? "Narrow" : "Filter"}<kbd>↵</kbd></span></>;
  };

  // ---------- popovers ----------
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
          <div className="gs-gh"><span>Recent</span><button onClick={() => setRecents([])}>Clear</button></div>
          {recentRows.map((r, i) => renderRow(r, i))}
        </>}
      </div>
      {cur && !saving && <div className="gs-ft">{foot(cur)}</div>}
    </div>
  );
  const arrows = (e) => {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    e.preventDefault();
    const bs = [...e.currentTarget.querySelectorAll("button")], i = bs.indexOf(document.activeElement);
    const n = bs[(i + (e.key === "ArrowDown" ? 1 : -1) + bs.length) % bs.length];
    if (n) n.focus();
  };
  const scopeMenu = () => {
    const opt = (id) => (
      <button key={id} role="option" aria-selected={scope === id} className={"gs-srow" + (scope === id ? " on" : "")}
        onClick={() => { setScope(id); setHi(0); setPop(q ? "sugg" : null); focusQuiet(); }}>
        <span className="gs-ic"><SIcon id={id}/></span>
        <span className="gs-sl">{SCOPES[id].label}</span>
        <span className={"gs-sd" + (FILTER.includes(id) ? " mono" : "")}>{SCOPES[id].desc}</span>
        {SCOPES[id].pre ? <kbd>{SCOPES[id].pre}</kbd> : <span></span>}
      </button>
    );
    return (
      <div className="gs-scopes" role="listbox" aria-label="Search in" onKeyDown={arrows} ref={scopeRef}>
        {opt("any")}
        <div className="gs-gh"><span>Go to</span><em>selects a change · graph stays</em></div>
        {GO.map(opt)}
        <div className="gs-gh"><span>Filter by</span><em>redraws the graph</em></div>
        {FILTER.map(opt)}
      </div>
    );
  };
  const sel = baseId;
  // while searching, hide variants that can't match together with the search (logic only, no data); the selected one always stays
  const menuCfgs = active ? configs.filter(c => c.id === sel || RS.canRefine(active, c.id)) : configs;
  const hiddenN = configs.length - menuCfgs.length;
  const revMenu = () => (
    <div className="gtb-menu gs-menu" role="listbox" aria-label="jj log variants">
      {active && <div className="gs-mh">Search within</div>}
      {RS.BUILTIN.map(r => (
        <button key={r.id} role="option" aria-selected={r.id === sel} className={"gtb-opt " + (r.id === sel ? "active" : "")} onClick={() => pickVariant(r.id)}>
          <span className="chk">{r.id === sel && <Ic name="check" size={12}/>}</span>
          <code>{r.cmd}</code>
          <span className="desc">{r.desc}</span>
        </button>
      ))}
      {menuCfgs.length > 0 && <div className="gtb-menu-sep"></div>}
      {menuCfgs.map(c => (
        <button key={c.id} role="option" aria-selected={c.id === sel} className={"gtb-opt is-custom " + (c.id === sel ? "active" : "")} onClick={() => pickVariant(c.id)} title={RS.cmdOf(c)}>
          <span className="chk">{c.id === sel && <Ic name="check" size={12}/>}</span>
          <span className="nm">{c.name || "Unnamed"}</span>
          <code className="sub">{RS.exprOf(c)}</code>
        </button>
      ))}
      {hiddenN > 0 && <div className="gs-mnote">{hiddenN === 1 ? "1 filter" : hiddenN + " filters"} hidden — {hiddenN === 1 ? "it" : "they"} can’t match {fieldOf(active)} “{textOf(active)}”.</div>}
      <div className="gtb-menu-sep"></div>
      <button className="gtb-opt is-edit" onClick={() => { close(); setEditing(true); }}>
        <span className="chk"><Ic name="settings" size={13}/></span>
        <span className="nm">Edit Configurations…</span>
      </button>
    </div>
  );

  // ---------- render ----------
  const sc = SCOPES[scope];
  const shownCfg = configs.find(c => c.id === sel);
  const shownB = RS.BUILTIN.find(b => b.id === sel) || RS.BUILTIN[0];
  const effCmd = active ? RS.searchCmd(active) : shownCfg ? RS.cmdOf(shownCfg) : shownB.cmd;
  // while a search narrows it, the variant is no longer "the filter" but where the search runs: "$ jj log" → "in jj log"
  const baseShort = shownCfg ? shownCfg.name || "Unnamed" : sel === "all" ? "all()" : "jj log";
  return (
    <div className={"gs" + (focus ? " is-focus" : "") + (active ? " has-q" : "")} ref={rootRef}>
      <button className={"gs-scope" + (scope === "any" ? " is-any" : "") + (pop === "scope" ? " open" : "")} onClick={() => setPop(p => p === "scope" ? null : "scope")}
        aria-haspopup="listbox" aria-expanded={pop === "scope"} aria-label={"Search in: " + sc.label} title={"Search in: " + sc.label + (sc.go ? " — selects a change" : scope === "any" ? "" : " — filters the graph")}>
        <SIcon id={scope}/>{scope !== "any" && <span>{sc.label}</span>}<Ic name="chevronDown" size={12}/>
      </button>
      <input ref={inRef} className={"gs-in" + (scope === "change" || scope === "file" ? " mono" : "")} value={text} placeholder={narrow ? sc.short || sc.ph : sc.ph} spellCheck="false" autoComplete="off"
        role="combobox" aria-label="Search the graph" aria-expanded={pop === "sugg" && nav.length > 0} aria-controls="gs-list" aria-activedescendant={pop === "sugg" && cur ? "gs-o-" + hiN : undefined}
        onChange={onChange} onKeyDown={onKey} onFocus={onFocus} onBlur={onBlur} onMouseUp={onMouseUp}/>
      {!text && !focus && <kbd className="gs-k" aria-hidden="true">⌘F</kbd>}
      {active && !focus && (
        <span className="gs-savew">
          <button className={"gs-save" + (pop === "save" ? " open" : "")} onClick={() => setPop(p => p === "save" ? null : "save")} aria-haspopup="dialog" aria-expanded={pop === "save"} title="Save this search as a filter">Save</button>
          {pop === "save" && <SavePop name={defName(active)} cmd={RS.searchCmd(active)} onSave={(n) => save(active, n)} onCancel={close}/>}
        </span>
      )}
      {(text || active) && <button className="gs-x" onMouseDown={(e) => { if (focus) e.preventDefault(); }} onClick={clear} aria-label="Clear search" title={active ? "Clear search — back to " + (shownCfg ? shownCfg.name : shownB.cmd) : "Clear"}><Ic name="close" size={10}/></button>}
      <span className="gs-div"></span>
      <button className={"gs-rev" + (active ? " is-base" : "") + (pop === "rev" ? " open" : "") + (flash ? " is-flash" : "")} onClick={() => setPop(p => p === "rev" ? null : "rev")}
        aria-haspopup="listbox" aria-expanded={pop === "rev"} aria-label={active ? "Search within: " + baseShort : undefined} title={active ? "Search within " + baseShort + " — the graph shows " + effCmd : effCmd}>
        {active ? <><span className="gs-in-l">in</span>{shownCfg ? <span className="gs-rev-nm">{baseShort}</span> : <code>{baseShort}</code>}</>
          : <><span className="gtb-prompt">$</span>{shownCfg ? <span className="gs-rev-nm">{shownCfg.name || "Unnamed"}</span> : <code>{shownB.cmd}</code>}</>}
        <Ic name="chevronDown" size={13}/>
      </button>
      {pop === "sugg" && (groups || recentRows.length > 0) && suggPop()}
      {pop === "scope" && scopeMenu()}
      {pop === "rev" && revMenu()}
      {editing && ReactDOM.createPortal(<window.RevsetDialog initial={shownCfg ? shownCfg.id : null} onClose={() => setEditing(false)} onApply={(id) => { if (id) api.setRevset(id); }}/>, document.querySelector(".fwin") || document.body)}
    </div>
  );
}

Object.assign(window, { GraphSearch });
})();
