// Search — the View capsule's field (DS GraphSearch + SearchMenu + SearchPopover) with the client's behaviour (graph-search.jsx):
// one menu (default search · other jj log variants · Go to · Filter by · Edit Configurations…), suggestions while typing, recent
// searches while empty. Go-to scopes select a change and leave the graph alone; filter scopes redraw it — a typed search runs in all().
// Also the kit's revset evaluation: built-ins, rule-based configurations and typed searches ("q:{…}").
(() => {
const { GraphSearch, SearchMenu, SearchPopover, SearchGroup, SearchRow, SearchMatch, SearchTag, SearchAvatar, AtBadge, ChangeId, RevsetDialog } = window.ZanshinDesignSystem_a33847;

// ---------- revsets ----------
const zkGlob = (p, path) => new RegExp("^" + String(p).replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*\*/g, "\u0000").replace(/\*/g, path ? "[^/]*" : ".*").replace(/\u0000/g, ".*").replace(/\?/g, ".") + "$");
function zkText(mode, ci, val, s) {
  let a = s || "", b = val || "";
  if (mode === "regex") { try { return new RegExp(b, ci ? "i" : "").test(a); } catch (e) { return false; } }
  if (ci) { a = a.toLowerCase(); b = b.toLowerCase(); }
  return mode === "exact" ? a === b : mode === "glob" ? zkGlob(b).test(a) : a.includes(b);
}
function zkRule(r, c, me) {
  let ok;
  if (r.fn === "mine") ok = c.author === me;
  else if (r.fn === "files") ok = (c.files || []).some((f) => (r.mode === "file" ? f.path === r.value : r.mode === "glob" ? zkGlob(r.value, true).test(f.path) : f.path.startsWith(r.value)));
  else ok = zkText(r.mode, r.ci, r.value, r.fn === "subject" ? c.subject : r.fn === "description" ? c.subject + "\n" + (c.description || "") : c.author);
  return r.not ? !ok : ok;
}
const zkSearchRule = (s) => (s.k === "mine" ? { fn: "mine", not: false } : s.k === "files" ? { fn: "files", mode: s.m || "prefix", value: s.v, not: false } : { fn: s.k, mode: s.m || "substring", ci: !!s.ci, value: s.v, not: false });
const zkSearchExpr = (s) => RevsetDialog.ruleExpr(zkSearchRule(s));
const zkSearchCmd = (s) => "jj log -r '" + zkSearchExpr(s) + "'";
const zkEncode = (s) => "q:" + JSON.stringify({ k: s.k, m: s.m, v: s.v, ci: s.ci || undefined });
const zkParse = (id) => { if (typeof id !== "string" || !id.startsWith("q:")) return null; try { return JSON.parse(id.slice(2)); } catch (e) { return null; } };
// what a revset id shows: built-ins show everything the kit has; configurations combine their filters; a typed search runs in all()
function zkRevsetMatch(id, configs, me) {
  const s = zkParse(id);
  if (s) { const r = zkSearchRule(s); return (c) => zkRule(r, c, me); }
  const cfg = configs.find((c) => c.id === id);
  if (!cfg) return () => true;
  const rs = (cfg.rules || []).filter((r) => r.fn === "mine" || String(r.value || "").trim());
  if (!rs.length) return () => true;
  return cfg.op === "|" ? (c) => rs.some((r) => zkRule(r, c, me)) : (c) => rs.every((r) => zkRule(r, c, me));
}

// ---------- scopes, recents ----------
const scopeOf = (s) => (s.k === "files" ? "file" : s.k === "description" ? "description" : "author");
const textOf = (s, me) => (s.k === "mine" ? me : s.v);
const labelOf = (s, me) => (s.k === "mine" ? me + " (you)" : s.k === "description" ? "“" + s.v + "”" : s.v);
const iconOf = (s) => (s.k === "files" ? (s.m === "prefix" ? "folder" : "file") : s.k === "description" ? "description" : "user");
const nLabel = (n) => (n === 1 ? "1 change" : n + " changes");
const FITS = { any: () => true, change: (r) => r.k === "change", bookmark: () => false, author: (r) => r.k === "author" || r.k === "mine", file: (r) => r.k === "files", description: (r) => r.k === "description" };
const same = (a, b) => !!a && !!b && a.k === b.k && (a.m || "") === (b.m || "") && a.v === b.v && !!a.ci === !!b.ci;
let zkRecents = [
  { k: "author", m: "exact", v: "Lena König" },
  { k: "change", v: "plkmnvxo" },
  { k: "files", m: "prefix", v: "lib/settings/" },
  { k: "description", m: "substring", ci: true, v: "cache" },
];
const pushRecent = (r) => { zkRecents = [{ k: r.k, m: r.m, v: r.v, ci: r.ci || undefined }, ...zkRecents.filter((x) => !same(x, r))].slice(0, 10); };

// ---------- matching ----------
const lc = (s) => (s || "").toLowerCase();
const at = (text, q, from = 0) => { const i = lc(text).indexOf(q, from); return i < 0 ? null : [i, i + q.length]; };
const wordAt = (s, i) => i === 0 || /[^a-z0-9]/i.test(s[i - 1]);
function buildIndex(all) {
  const authors = new Set(), paths = new Set(), dirs = new Set(), bms = [];
  all.forEach((c) => {
    if (c.author) authors.add(c.author);
    (c.files || []).forEach(({ path }) => { paths.add(path); const seg = path.split("/"); for (let i = 1; i < seg.length; i++) dirs.add(seg.slice(0, i).join("/") + "/"); });
    (c.bookmarks || []).forEach((b) => bms.push({ name: b.name, c }));
  });
  return { commits: all, authors, paths, dirs, bms };
}
function suggest(ix, scope, raw, me) {
  const q = lc(raw.trim()), v = raw.trim();
  const G = { change: [], bookmark: [], author: [], file: [], description: [] };
  if (!q) return G;
  const want = (x) => scope === "any" || scope === x;
  const idLike = /^[k-z]{3,}$/.test(q), hashLike = /^[0-9a-f]{4,}$/.test(q), pathLike = /[/*?]|\.\w+$/.test(q);
  if (want("change") || scope === "description") {
    ix.commits.forEach((c) => {
      let r = null, score = 0, how;
      if (c.id.startsWith(q)) { score = 100; how = "id"; }
      else if (q.length >= 3 && (c.commit || "").startsWith(q)) { score = 96; how = "hash"; }
      else if ((r = at(c.subject, q))) { score = wordAt(c.subject, r[0]) ? 58 : 46; how = "subject"; }
      else if (at(c.description, q)) { score = 36; how = "body"; }
      if (score) G.change.push({ key: "c:" + c.id, kind: "change", c, how, r, q, go: c.id, score: score + (idLike || hashLike ? 20 : 0) });
    });
    G.change.sort((a, b) => b.score - a.score || a.c.t - b.c.t);
  }
  if (want("bookmark")) {
    ix.bms.forEach(({ name, c }) => { const r = at(name, q); if (r) G.bookmark.push({ key: "b:" + name, kind: "bookmark", name, c, r, go: c.id, score: r[0] === 0 ? 86 : wordAt(name, r[0]) ? 74 : 60 }); });
    G.bookmark.sort((a, b) => b.score - a.score || a.name.length - b.name.length);
  }
  if (want("author")) {
    ix.authors.forEach((name) => { const r = at(name, q); if (r) G.author.push({ key: "a:" + name, kind: "author", name, me: name === me, r, s: name === me ? { k: "mine" } : { k: "author", m: "exact", v: name }, score: wordAt(name, r[0]) ? 84 : 62 }); });
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
      ix.dirs.forEach((d) => add(d, true)); ix.paths.forEach((p) => add(p, false));
      G.file.sort((a, b) => b.score - a.score);
    }
  }
  if (want("description")) G.description.push({ key: "d:" + q, kind: "desc", v, s: { k: "description", m: "substring", ci: true, v }, score: 24 });
  return G;
}
const LIMIT = { change: 3, bookmark: 2, author: 2, file: 3, description: 1 };
const GLABEL = { change: "Changes", bookmark: "Bookmarks", author: "Authors", file: "Files", description: "Descriptions" };
const SLABEL = { change: "Change", bookmark: "Bookmark", author: "Author", file: "File", description: "Description" };
function compose(G, scope, count) {
  const n = (rows) => rows.map((r) => (r.s ? { ...r, n: count(r.s) } : r)).filter((r) => !r.s || r.n > 0);
  if (scope === "any") return Object.keys(G).map((k) => {
    const rows = n(G[k].slice(0, LIMIT[k])), more = G[k].length - LIMIT[k];
    if (rows.length && more > 0) rows.push({ key: "more:" + k, kind: "more", scope: k, n: more, score: 0 });
    return { id: k, label: GLABEL[k], rows };
  }).filter((g) => g.rows.length).sort((a, b) => b.rows[0].score - a.rows[0].score);
  if (scope === "description") {
    const ch = G.change.filter((r) => r.how === "subject" || r.how === "body").slice(0, 6);
    return [{ id: "description", rows: n(G.description) }, { id: "change", label: "Changes", rows: ch }].filter((g) => g.rows.length);
  }
  const rows = n(G[scope].slice(0, 8));
  return rows.length ? [{ id: scope, rows }] : [];
}

// ============================================================
function ZKSearch({ D, revset, setRevset, home, configs, changes, visible, size, onGoTo, onEdit }) {
  const me = D.me;
  const active = zkParse(revset), atHome = !active && revset === home;
  const [scope, setScope] = React.useState(() => (active ? scopeOf(active) : "any"));
  const [text, setText] = React.useState(() => (active ? textOf(active, me) : ""));
  const [focus, setFocus] = React.useState(false);
  const [pop, setPop] = React.useState(null);
  const [hi, setHi] = React.useState(0);
  const [, tick] = React.useState(0);
  const rootRef = React.useRef(null), inRef = React.useRef(null), listRef = React.useRef(null);
  const focusRef = React.useRef(false), leaving = React.useRef(false), quiet = React.useRef(false), justFocused = React.useRef(false);
  const ix = React.useMemo(() => buildIndex(changes), [changes]);
  const count = (s) => { const m = zkRevsetMatch(zkEncode(s), configs, me); return changes.filter(m).length; };
  const saved = React.useMemo(() => new Set(configs.map((c) => RevsetDialog.exprOf(c))), [configs]);
  const builtin = (id) => id === "default" || id === "all";
  const variants = [...SearchMenu.builtins.map((b) => ({ ...b })), ...configs.map((c) => ({ id: c.id, name: c.name || "Unnamed", expr: RevsetDialog.exprOf(c), cmd: "jj log -r '" + RevsetDialog.exprOf(c) + "'" }))];
  const homeV = variants.find((v) => v.id === home) || variants[0];
  const menuVariants = [homeV, ...variants.filter((v) => v !== homeV)];
  const viewName = (id) => (variants.find((v) => v.id === id) || {}).name || "Unnamed";
  const revert = () => { setText(active ? textOf(active, me) : ""); setScope(active ? scopeOf(active) : "any"); };
  const focusQuiet = () => { const i = inRef.current; if (!i) return; quiet.current = true; i.focus(); quiet.current = false; const n = i.value.length; i.setSelectionRange(n, n); };

  React.useEffect(() => {
    const s = zkParse(revset);
    if (s) { setScope(scopeOf(s)); if (!focusRef.current) setText(textOf(s, me)); }
    else if (!focusRef.current) { setText(""); setScope("any"); }
  }, [revset]);
  React.useEffect(() => {
    if (!pop) return undefined;
    const down = (e) => { if (rootRef.current && !rootRef.current.contains(e.target)) { setPop(null); if (!focusRef.current) revert(); } };
    const key = (e) => {
      if (e.key !== "Escape" || pop !== "menu") return;
      e.stopPropagation(); e.preventDefault(); setPop(null); revert();
      const b = rootRef.current && rootRef.current.querySelector(".zs-gs-scope"); if (b) b.focus();
    };
    window.addEventListener("pointerdown", down, true); window.addEventListener("keydown", key, true);
    return () => { window.removeEventListener("pointerdown", down, true); window.removeEventListener("keydown", key, true); };
  }, [pop, revset]);
  React.useEffect(() => {
    const l = listRef.current, el = l && l.querySelector('[data-i="' + hi + '"]');
    if (!el) return;
    if (el.offsetTop < l.scrollTop) l.scrollTop = el.offsetTop - 6;
    else if (el.offsetTop + el.offsetHeight > l.scrollTop + l.clientHeight) l.scrollTop = el.offsetTop + el.offsetHeight - l.clientHeight + 6;
  }, [hi]);

  const q = text.trim();
  const recentRows = pop === "sugg" && !q ? zkRecents.filter((r) => FITS[scope](r) && (r.k === "change" ? changes.some((c) => c.id === r.v) : !saved.has(zkSearchExpr(r)))).slice(0, 6)
    .map((r) => (r.k === "change" ? { key: "r:c:" + r.v, kind: "change", c: changes.find((c) => c.id === r.v), go: r.v } : { key: "r:" + zkEncode(r), kind: "recent", r, s: r, n: count(r) })) : [];
  let groups = null;
  if (pop === "sugg" && q) {
    let gs = compose(suggest(ix, scope, q, me), scope, count), other = false;
    if (!gs.length && scope !== "any") { gs = compose(suggest(ix, "any", q, me), "any", count); other = gs.length > 0; }
    groups = { gs, other };
  }
  const nav = groups ? groups.gs.flatMap((g) => g.rows) : recentRows;
  const hiN = Math.min(hi, Math.max(0, nav.length - 1)), cur = nav[hiN];

  const close = () => setPop(null);
  const leave = () => { close(); leaving.current = true; if (inRef.current) inRef.current.blur(); leaving.current = false; };
  const mk = (s) => ({ k: s.k, m: s.m, v: s.v, ci: s.ci });
  const apply = (s) => { pushRecent(s); setRevset(zkEncode(mk(s))); setScope(scopeOf(s)); setText(textOf(s, me)); leave(); };
  const goTo = (id) => { pushRecent({ k: "change", v: id }); revert(); leave(); onGoTo(id); };
  const pick = (row) => { if (row.kind === "more") { setScope(row.scope); setHi(0); return; } if (row.go) goTo(row.go); else if (row.s) apply(row.s); };
  const clear = () => { setText(""); setScope("any"); if (revset !== home) setRevset(home); if (focusRef.current) { setHi(0); setPop("sugg"); } else close(); };
  const pickView = (id) => { close(); setText(""); setScope("any"); setRevset(id); };
  const pickScope = (id) => { const draft = text !== (active ? textOf(active, me) : ""); setScope(id); setHi(0); if (!draft) setText(""); focusQuiet(); setPop("sugg"); };

  const onKey = (e) => {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      if (pop !== "sugg") { setPop("sugg"); setHi(0); return; }
      if (nav.length) setHi((hiN + (e.key === "ArrowDown" ? 1 : -1) + nav.length) % nav.length);
    } else if (e.key === "Enter") { e.preventDefault(); if (pop === "sugg" && cur) pick(cur); else if (q) setPop("sugg"); }
    else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); if (pop) close(); else { revert(); leave(); } }
  };
  const onFocus = (e) => { focusRef.current = true; setFocus(true); if (!quiet.current) { justFocused.current = true; e.target.select(); } setPop("sugg"); setHi(0); };
  const onMouseUp = (e) => { if (justFocused.current) { justFocused.current = false; e.preventDefault(); } };
  const onBlur = (e) => {
    focusRef.current = false; setFocus(false); justFocused.current = false;
    if (leaving.current || (rootRef.current && rootRef.current.contains(e.relatedTarget))) return;
    if (pop === "sugg") close();
    revert();
  };

  const notInView = (c) => c && !visible.has(c.id) && <SearchTag>not in view</SearchTag>;
  const row = (r, i) => {
    const p = { key: r.key, "data-i": i, highlighted: i === hiN, onClick: () => pick(r), onMouseMove: () => { if (i !== hiN) setHi(i); } };
    if (r.kind === "change") {
      const c = r.c, n = r.how === "id" ? r.q.length : 2;
      return <SearchRow {...p} icon="change" dim={!c.subject}
        before={<>{c.id === D.wc && <AtBadge/>}<ChangeId id={c.id} length={8} prefix={n}/>{r.how === "hash" && <span className="zs-cid zs-gs-hash"><b>{c.commit.slice(0, r.q.length)}</b>{c.commit.slice(r.q.length, 8)}</span>}</>}
        label={r.how === "subject" ? <SearchMatch text={c.subject} match={r.r}/> : c.subject || "(no description set)"}
        meta={<>{notInView(c)}<span>{(c.author || "").split(" ")[0]}{c.date ? " · " + c.date : ""}</span></>}/>;
    }
    if (r.kind === "bookmark") return <SearchRow {...p} icon="bookmark" label={<SearchMatch text={r.name} match={r.r}/>} meta={<>{notInView(r.c)}<ChangeId id={r.c.id} length={8}/></>}/>;
    if (r.kind === "author") return <SearchRow {...p} icon={<SearchAvatar name={r.name}/>} label={<SearchMatch text={r.name} match={r.r}/>} after={r.me && <SearchTag>you · mine()</SearchTag>} meta={nLabel(r.n)}/>;
    if (r.kind === "contains") return <SearchRow {...p} icon="user" label="Authors containing" quote={r.v} meta={nLabel(r.n)}/>;
    if (r.kind === "dir" || r.kind === "path") return <SearchRow {...p} icon={r.kind === "dir" ? "folder" : "file"} mono label={<SearchMatch text={r.p} match={r.r} split={r.split}/>} meta={nLabel(r.n)}/>;
    if (r.kind === "glob") return <SearchRow {...p} icon="file" mono label={r.v} after={<SearchTag>glob</SearchTag>} meta={nLabel(r.n)}/>;
    if (r.kind === "desc") return <SearchRow {...p} icon="description" label="Descriptions containing" quote={r.v} meta={nLabel(r.n)}/>;
    if (r.kind === "recent") return <SearchRow {...p} icon={iconOf(r.r)} label={labelOf(r.r, me)} sub={zkSearchExpr(mk(r.r))} meta={nLabel(r.n)}/>;
    return <SearchRow {...p} more label={r.n + " more in " + GLABEL[r.scope]}/>;
  };
  const footer = (r) => {
    if (!r) return null;
    if (r.kind === "more") return { text: "Narrows the search to " + SLABEL[r.scope].toLowerCase() + "s", verb: "Show" };
    if (r.go) { const c = r.c || changes.find((x) => x.id === r.go), hidden = c && !visible.has(c.id); return hidden ? { text: <>Not in this view — switches to <code>all()</code> and selects it</>, verb: "Show" } : { text: "Selects the change — the graph stays as it is", verb: "Select" }; }
    return { text: <code>{zkSearchCmd(mk(r.s))}</code>, verb: "Filter" };
  };
  const recentLabel = scope === "any" ? "Recent" : "Recent " + (scope === "change" ? "changes" : SLABEL[scope].toLowerCase() + "s");
  return (
    <div ref={rootRef} className="zk-search">
      <GraphSearch inputRef={inRef} size={size} scope={scope} value={text} view={active ? "search" : atHome ? "default" : "variant"} variantName={viewName(revset)} variantMono={builtin(revset)}
        defaultName={homeV.name} menuOpen={pop === "menu"} expanded={pop === "sugg" && nav.length > 0}
        onChange={(v) => { setText(v); setHi(0); setPop("sugg"); }} onScopeChange={(s) => { setScope(s); setHi(0); }} onMenu={() => setPop((x) => (x === "menu" ? null : "menu"))} onClear={clear}
        onKeyDown={onKey} onFocus={onFocus} onBlur={onBlur} onMouseUp={onMouseUp}>
        {pop === "sugg" && (groups || recentRows.length > 0) && (
          <SearchPopover listRef={listRef} footer={footer(cur)} note={groups && groups.other ? "No " + SLABEL[scope].toLowerCase() + " matches “" + q + "” — found elsewhere:" : null}
            empty={groups && !groups.gs.length ? "Nothing matches “" + q + "”" + (scope !== "any" ? " — in any scope." : ".") : null}>
            {groups ? groups.gs.map((g) => (
              <React.Fragment key={g.id}>
                {g.label && (scope === "any" || groups.other || scope === "description") && <SearchGroup label={g.label}/>}
                {g.rows.map((r) => row(r, nav.indexOf(r)))}
              </React.Fragment>
            )) : <>
              <SearchGroup label={recentLabel} action="Clear" onAction={() => { zkRecents = []; tick((x) => x + 1); }}/>
              {recentRows.map((r, i) => row(r, i))}
            </>}
          </SearchPopover>
        )}
        {pop === "menu" && <SearchMenu autoFocus variants={menuVariants} current={active ? null : revset} scope={active ? scopeOf(active) : null} value={active ? textOf(active, me) : ""}
          onPickVariant={pickView} onPickScope={pickScope} onEdit={() => { close(); onEdit(active ? home : revset); }}/>}
      </GraphSearch>
    </div>
  );
}

Object.assign(window, { ZKSearch, zkRevsetMatch, zkParseSearch: zkParse });
})();
